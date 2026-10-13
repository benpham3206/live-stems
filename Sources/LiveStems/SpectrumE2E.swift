import AppKit

/// The analyzer reads a sine at its frequency and level; the window draws in both
/// views to PNG within a frame budget. No audio session runs.
enum SpectrumE2E {
  static func run(_ out: URL) throws {
    var analyzer = SpectrumAnalyzer()
    let frequencies = SpectrumAnalyzer.frequencies(log: true)
    // At the output's rate, whichever it is.
    for rate: Float in [48000, 44100] {
      analyzer.rate = rate
      for (hz, amplitude) in [(1000, 1.0), (110, 0.1), (8000, 0.5)] as [(Float, Float)] {
        let sine = (0..<SpectrumAnalyzer.size).map { amplitude * sin(2 * .pi * hz * Float($0) / rate) }
        let levels = analyzer.levels(sine, log: true)
        let peak = levels.indices.max { levels[$0] < levels[$1] }!
        let expected = 20 * log10(amplitude)
        guard abs(log2(frequencies[peak] / hz)) < 0.1, abs(levels[peak] - expected) < 1.5 else {
          throw StemError("Sine \(hz) Hz at \(expected) dB, \(rate) Hz rate, read as \(frequencies[peak]) Hz at \(levels[peak]) dB")
        }
        guard levels.min()! < expected - 60 else { throw StemError("Sine \(hz) Hz leaks across the spectrum") }
      }
    }
    let lag = try clickLag(analyzer)
    _ = try Waterfall()  // the 3D rows need the GPU and their shader to build
    let silent = analyzer.levels([Float](repeating: 0, count: SpectrumAnalyzer.size), log: true)
    guard silent.allSatisfy({ $0 <= -120 }) else { throw StemError("Silence is not at the floor") }

    // Music-like test signal, loud and peaky like a mastered track: a bass line, two-note pad
    // stabs rich in harmonics with vibrato, a plucked arpeggio, a kick every half second,
    // hi-hat hiss and room noise, through the real analyzer.
    let controller = SpectrumWindowController { $0(nil) }
    let view = controller.view
    controller.window.setContentSize(NSSize(width: 1240, height: 724))
    controller.window.contentView?.layoutSubtreeIfNeeded()
    var generator = SystemRandomNumberGenerator()
    var pushSeconds = [Double](), last = ([Float](), [Float]())
    let progression: [[Float]] = [[0, 4, 7, 11], [5, 9, 12, 16], [7, 11, 14, 17], [-3, 0, 4, 7]]
    for frame in 0..<(view.seconds * SpectrumView.rowsPerSecond) {
      let time = Float(frame) / Float(SpectrumView.rowsPerSecond)
      let chord = progression[Int(time / 1.25) % 4], beat = time.truncatingRemainder(dividingBy: 0.5)
      // The last second is a breakdown: no kick, the pad drops back, as songs breathe.
      let breakdown: Float = time > 4 ? 0.3 : 1, kick = beat < 0.15 && time <= 4 ? exp(-beat * 25) : 0, hat: Float = beat > 0.25 && beat < 0.31 ? 0.006 : 0.0002
      let bass = 82.4 * pow(2, chord[0] / 12), arp = 880 * pow(2, chord[Int(time / 0.25) % 4] / 12)
      // Pad stabs and arpeggio plucks that ring down: some rows spike, the rows between settle.
      let stab = 0.6 * breakdown * exp(-time.truncatingRemainder(dividingBy: 0.625) * 12), pluck = 0.08 * exp(-time.truncatingRemainder(dividingBy: 0.25) * 25)
      let swell = 0.06 + 0.04 * sin(time * 2.3)  // the room swells and settles
      // The original has a sung line; what you hear has it muted, as with Vocals muted.
      var heard = [Float](), song = [Float](), hiss: Float = 0, warm: Float = 0, dark: Float = 0, rumble: Float = 0
      let note = 392 * pow(2, Float([0, 2, 4, 7, 4, 2][Int(time / 0.4) % 6]) / 12)
      for n in 0..<SpectrumAnalyzer.size {
        let t = Float(n) / analyzer.rate + time, noise = Float.random(in: -1...1, using: &generator)
        // The room: noise between 80 Hz and 1 kHz, falling away on both sides, under the notes.
        warm += 0.13 * (noise - warm)
        dark += 0.13 * (warm - dark)
        rumble += 0.011 * (dark - rumble)
        var x = (noise - hiss) * hat + (dark - rumble) * swell  // and differenced noise: hiss in the highs only
        hiss = noise
        x += kick * 0.25 * sin(2 * .pi * (50 + 60 * kick) * t)
        x += breakdown * exp(-beat * 6) * (0.08 * sin(2 * .pi * bass * t) + 0.03 * sin(4 * .pi * bass * t))
        for (k, step) in [chord[0], chord[2]].enumerated() {
          // 0.4% vibrato at 5 Hz: the phase of a frequency that wobbles.
          let f = 220 * pow(2, step / 12), phase = 2 * .pi * f * t - 0.004 * f / 5 * cos(2 * .pi * 5 * t + Float(k))
          // Harmonics fall off by h^-2.5 and darken further above 2 kHz, as a mastered mix does.
          for h in 1...30 where f * Float(h) < 16000 { x += stab / pow(Float(h), 2.5) * exp(-f * Float(h) / 2000) * sin(phase * Float(h)) }
        }
        for h in 1...8 { x += pluck / Float(h * h * h) * sin(2 * .pi * arp * Float(h) * t) }
        var voice: Float = 0
        let sung = 2 * .pi * note * t - 0.01 * note / 5.5 * cos(2 * .pi * 5.5 * t)
        for h in 1...20 where note * Float(h) < 16000 { voice += 0.12 / Float(h) * sin(sung * Float(h)) }
        heard.append(x)
        song.append(x + voice)
      }
      let levels = (analyzer.levels(heard, log: true), analyzer.levels(song, log: true)), began = stemClock()
      view.push(heard: levels.0, original: levels.1)
      pushSeconds.append(stemClock() - began)
      last = levels
    }
    var timings = ["push": pushSeconds.sorted()[pushSeconds.count * 95 / 100]]
    func png(_ image: CGImage, _ name: String) throws {
      try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent(name))
    }
    func bitmap(_ size: CGSize, scale: CGFloat) -> CGContext {
      let context = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
      context.scaleBy(x: scale, y: scale)
      return context
    }
    // At Retina scale, as on screen, each frame after a new row, as in real time. 3D: the GPU's
    // work for the rows, waited for. Its axes and labels redraw only when the view turns or resizes.
    view.threeD = true
    var drawn: Double = 0
    for _ in 0..<5 {
      view.push(heard: last.0, original: last.1)
      let began = stemClock()
      view.renderRows(scale: 2)
      drawn += stemClock() - began
    }
    timings["3d"] = drawn / 5
    let labels = bitmap(view.bounds.size, scale: 2), labelsBegan = stemClock()
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: labels, flipped: false)
    view.drawAxes(labels)
    NSGraphicsContext.restoreGraphicsState()
    timings["labels"] = stemClock() - labelsBegan
    guard let picture = view.picture(scale: 2) else { throw StemError("The 3D view did not render") }
    // The window shows dark glass behind the plot; stand in for it so the PNG reads true.
    let glass = bitmap(view.bounds.size, scale: 2)
    glass.setFillColor(CGColor(srgbRed: 0.10, green: 0.11, blue: 0.16, alpha: 1))
    glass.fill(view.bounds)
    glass.draw(picture, in: view.bounds)
    try png(glass.makeImage()!, "spectrum-3d.png")
    view.threeD = false
    let flat = bitmap(view.bounds.size, scale: 2)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: flat, flipped: false)
    drawn = 0
    for _ in 0..<5 {
      view.push(heard: last.0, original: last.1)
      let began = stemClock()
      view.draw(view.bounds)
      flat.flush()
      drawn += stemClock() - began
    }
    NSGraphicsContext.restoreGraphicsState()
    timings["2d"] = drawn / 5
    try png(flat.makeImage()!, "spectrum-2d.png")
    // The whole window, toolbar included, over a dusk-blue stand-in for the desktop behind the
    // glass, which renders opaque grey off screen; the 3D view drawn off screen in its place.
    view.threeD = true
    if let content = view.superview {
      view.isHidden = true
      let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds)!
      content.cacheDisplay(in: content.bounds, to: rep)
      view.isHidden = false
      let window = bitmap(content.bounds.size, scale: 1)
      window.drawLinearGradient(CGGradient(colorsSpace: nil, colors: [CGColor(srgbRed: 0.13, green: 0.15, blue: 0.20, alpha: 1),
        CGColor(srgbRed: 0.22, green: 0.25, blue: 0.37, alpha: 1)] as CFArray, locations: nil)!,
        start: .zero, end: CGPoint(x: 0, y: content.bounds.height), options: [])
      window.draw(rep.cgImage!, in: content.bounds)
      if let picture = view.picture(scale: 1) { window.draw(picture, in: view.frame) }
      try png(window.makeImage()!, "spectrum-window.png")
    }
    try orbit(view, out: out)
    try pause(controller)
    try labelsInside(controller)
    try reopen()
    // A row and a frame must fit well inside the 33 ms row period.
    guard timings["push"]! + timings["3d"]! < 0.020, timings["2d"]! < 0.020 else { throw StemError("Spectrum draw too slow: \(timings)") }
    let ms = timings.mapValues { String(format: "%.1f", $0 * 1000) }
    print("PASS spectrum · sines read true at 44.1 and 48 kHz, ms at 2x: p95 push \(ms["push"]!), 3D rows \(ms["3d"]!)"
      + " (labels \(ms["labels"]!) on turn or resize), 2D \(ms["2d"]!) · click to peak \(lag)")
  }

  /// How long after a click is heard its peak shows in the levels: a 5 kHz band, read the way
  /// the scope is, with the lookahead the output allows, here all of it. Fails over 30 ms.
  /// The frame that shows it adds up to one display refresh.
  private static func clickLag(_ analyzer: SpectrumAnalyzer) throws -> String {
    let rate = analyzer.rate, click = 20000, step = Int(rate / 1000), frequencies = SpectrumAnalyzer.frequencies(log: true)
    var samples = [Float](repeating: 0, count: 40000)
    samples[click] = 1
    func peak(_ hz: Float, ahead: Int) -> Float {
      let band = frequencies.indices.min { abs(frequencies[$0] - hz) < abs(frequencies[$1] - hz) }!
      let heard = stride(from: click - 6000, through: click + 6000, by: step).max { a, b in
        func level(_ at: Int) -> Float { analyzer.levels(Array(samples[(at + ahead - SpectrumAnalyzer.size)..<(at + ahead)]), log: true)[band] }
        return level(a) < level(b)
      }!
      return Float(heard - click) / rate * 1000
    }
    let high = peak(5000, ahead: SpectrumAnalyzer.ahead), low = peak(100, ahead: SpectrumAnalyzer.ahead), late = peak(5000, ahead: 0)
    guard high <= 30 else { throw StemError("A click peaks \(high) ms after it is heard") }
    return String(format: "%.1f ms highs, %.1f ms lows (%.1f ms highs with no lookahead)", high, low, late)
  }

  /// At the reset angle every label lies inside the view, in a very wide window, a very tall
  /// one and the smallest allowed.
  private static func labelsInside(_ controller: SpectrumWindowController) throws {
    let window = controller.window, view = controller.view, before = window.frame.size
    defer { window.setContentSize(before); window.contentView?.layoutSubtreeIfNeeded() }
    for size in [NSSize(width: 3000, height: 700), NSSize(width: 700, height: 1400), window.minSize] {
      window.setContentSize(size)
      window.contentView?.layoutSubtreeIfNeeded()
      for label in view.labels(in: view.bounds.size) where !view.bounds.contains(label.frame) {
        throw StemError("At \(Int(size.width))×\(Int(size.height)) \"\(label.text)\" leaves the view: \(label.frame) in \(view.bounds)")
      }
    }
  }

  /// Closing the window and opening it again keeps the rows coming, from the window's own timer.
  private static func reopen() throws {
    let mix = (0..<SpectrumAnalyzer.size).map { 0.1 * sin(Float($0) * 0.1) }
    let controller = SpectrumWindowController { $0(Scope(mix: mix, original: mix, rate: 44100)) }
    func rows(after seconds: TimeInterval) -> (rows: Int, frames: Int) {
      let before = (controller.view.rowsPushed, controller.view.framesDrawn)
      RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds))
      return (controller.view.rowsPushed - before.0, controller.view.framesDrawn - before.1)
    }
    controller.show()
    let first = rows(after: 0.3)
    controller.window.performClose(nil)
    controller.show()
    let second = rows(after: 0.3)
    controller.window.close()
    guard first.rows > 3, second.rows > 3, first.frames > 3, second.frames > 3 else { throw StemError("Rows stopped after the window reopened: \(first) then \(second)") }
  }
  /// Silence and no session add no rows and leave nothing to redraw; sound starts it again.
  private static func pause(_ controller: SpectrumWindowController) throws {
    let rate: Float = 44100, view = controller.view
    func scope(silentFor seconds: Float) -> Scope {
      let quiet = Int(seconds * rate)
      // Silence as a room has it: a hum 100 dB down, under the -90 dB line.
      let mix = (0..<SpectrumAnalyzer.size).map { ($0 < SpectrumAnalyzer.size - quiet ? 0.1 : 1e-5) * sin(Float($0) * 0.1) }
      return Scope(mix: mix, original: mix, rate: rate)
    }
    guard controller.feed(scope(silentFor: 0.1)) else { throw StemError("100 ms of silence paused the view") }
    view.window?.displayIfNeeded()
    let rows = view.rowsPushed, frames = view.framesDrawn
    for _ in 0..<(SpectrumView.rowsPerSecond) {  // a second of silence, then of no session
      guard !controller.feed(scope(silentFor: 0.16)) else { throw StemError("Silence added a row") }
    }
    guard view.rowsPushed == rows, view.framesDrawn == frames, !view.redrawPending else { throw StemError("The view drew during silence") }
    guard !controller.feed(nil), view.rowsPushed == rows, view.hint != nil else { throw StemError("No session added a row") }
    guard controller.feed(scope(silentFor: 0)), view.rowsPushed == rows + 1 else { throw StemError("Sound did not start the view again") }
  }

  /// A right-drag turns the 3D view and stops looking straight down or up; a left-drag and a
  /// right-click leave it; a double-click puts it back. Writes the view from below.
  private static func orbit(_ view: SpectrumView, out: URL) throws {
    func event(_ type: NSEvent.EventType, _ x: CGFloat, _ y: CGFloat, clicks: Int = 1) -> NSEvent {
      NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: y), modifierFlags: [], timestamp: 0,
        windowNumber: view.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)!
    }
    let start = view.camera
    guard start == .reference, view.mouseDownCanMoveWindow, view.menu(for: event(.rightMouseDown, 300, 300)) == nil else {
      throw StemError("The 3D view starts turned, keeps the window from moving, or shows a menu")
    }
    view.mouseDragged(with: event(.leftMouseDragged, 400, 300))
    guard view.camera == start else { throw StemError("A left-drag turned the 3D view") }
    view.rightMouseDown(with: event(.rightMouseDown, 300, 300))
    view.rightMouseDragged(with: event(.rightMouseDragged, 400, 300))
    guard abs(view.camera.yaw - (start.yaw - 1)) < 1e-4, view.camera.pitch == start.pitch else {
      throw StemError("A right-drag across did not turn the view around: \(view.camera)")
    }
    // A drag right lowers the yaw (above); a drag up lowers the pitch, to look from below.
    for (y, limit) in [(20000, Float(-89)), (-20000, 89)] as [(CGFloat, Float)] {
      view.rightMouseDragged(with: event(.rightMouseDragged, 400, y))
      guard abs(view.camera.pitch - limit * .pi / 180) < 1e-5 else { throw StemError("Pitch went past \(limit)°: \(view.camera)") }
    }
    view.rightMouseUp(with: event(.rightMouseUp, 400, -20000))
    view.camera = Camera(yaw: start.yaw, pitch: -0.45)
    if let below = view.picture(scale: 1), let glass = CGContext(data: nil, width: below.width, height: below.height, bitsPerComponent: 8,
      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) {
      let all = CGRect(x: 0, y: 0, width: below.width, height: below.height)
      glass.setFillColor(CGColor(srgbRed: 0.10, green: 0.11, blue: 0.16, alpha: 1))
      glass.fill(all)
      glass.draw(below, in: all)
      try NSBitmapImageRep(cgImage: glass.makeImage()!).representation(using: .png, properties: [:])!
        .write(to: out.appendingPathComponent("spectrum-below.png"))
    }
    // Scrolling up zooms in, down zooms out, within half size to 4×.
    func scroll(_ lines: Int32) -> NSEvent {
      NSEvent(cgEvent: CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: lines, wheel2: 0, wheel3: 0)!)!
    }
    // All the way around, the frequency title stays level, moves smoothly (a flip moves it about 100 pt),
    // and no two labels overlap.
    for pitch in [start.pitch, 0.05, -0.4] {  // the reference, nearly side on, and from below
      var last: CGPoint?
      for degree in 0..<360 {
        view.camera = Camera(yaw: Float(degree) * .pi / 180, pitch: pitch)
        if let at = view.labels(in: view.bounds.size).first(where: { $0.text == "Frequency (Hz)" })?.at {
          if let last, hypot(at.x - last.x, at.y - last.y) > 30 { throw StemError("The frequency title jumped at yaw \(degree)°") }
          last = at
        }
      }
    }
    for step in 0..<36 {
      view.camera = Camera(yaw: Float(step) * .pi / 18, pitch: start.pitch)
      let labels = view.labels(in: view.bounds.size)
      guard let title = labels.first(where: { $0.text == "Frequency (Hz)" && $0.angle == 0 }),
        let a = view.camera.point([0, 0, 0], in: view.bounds.size), let b = view.camera.point([1, 0, 0], in: view.bounds.size) else {
        throw StemError("The frequency title is missing or tilted at yaw \(step * 10)°")
      }
      // Underneath its axis, unless the axis stands nearly upright on screen.
      let upright = abs(b.y - a.y) > 2 * abs(b.x - a.x)
      guard upright || title.at.y < (a.y + b.y) / 2 else { throw StemError("The frequency title sits above its axis at yaw \(step * 10)°") }
      for (i, a) in labels.enumerated() where labels[(i + 1)...].contains(where: { $0.frame.intersects(a.frame) }) {
        throw StemError("\"\(a.text)\" overlaps another label at yaw \(step * 10)°")
      }
    }
    // Label text zooms with the plot, head on to the frequency axis too.
    func titleSize(_ zoom: Float) -> CGFloat? {
      view.camera = Camera(yaw: 0, pitch: 0.05, zoom: zoom)
      return view.labels(in: view.bounds.size).first(where: { $0.text == "Frequency (Hz)" })?.size
    }
    guard let small = titleSize(1), let large = titleSize(1.5), abs(large / small - 1.5) < 0.01 else {
      throw StemError("Label text did not zoom with the plot")
    }
    view.camera = .reference
    view.scrollWheel(with: scroll(3))
    guard view.camera.zoom > 1.2, view.camera.yaw == start.yaw else { throw StemError("Scrolling up did not zoom in: \(view.camera)") }
    for _ in 0..<40 { view.scrollWheel(with: scroll(3)) }
    guard view.camera.zoom == 4 else { throw StemError("Zoom went past 4×: \(view.camera.zoom)") }
    for _ in 0..<80 { view.scrollWheel(with: scroll(-3)) }
    guard view.camera.zoom == 0.5 else { throw StemError("Zoom went past half size: \(view.camera.zoom)") }
    view.mouseDown(with: event(.leftMouseDown, 300, 300, clicks: 2))
    guard view.camera == .reference else { throw StemError("A double-click did not put the view back") }
  }
}
