import AppKit

/// The analyzer reads a sine at its frequency and level; the window draws in both
/// views to PNG within a frame budget. No audio session runs.
enum SpectrumE2E {
  static func run(_ out: URL) throws {
    let analyzer = SpectrumAnalyzer(), frequencies = SpectrumAnalyzer.frequencies(log: true)
    for (hz, amplitude) in [(1000, 1.0), (110, 0.1), (8000, 0.5)] as [(Float, Float)] {
      let sine = (0..<SpectrumAnalyzer.size).map { amplitude * sin(2 * .pi * hz * Float($0) / SpectrumAnalyzer.rate) }
      let levels = analyzer.levels(sine, log: true)
      let peak = levels.indices.max { levels[$0] < levels[$1] }!
      let expected = 20 * log10(amplitude)
      guard abs(log2(frequencies[peak] / hz)) < 0.1, abs(levels[peak] - expected) < 1.5 else {
        throw StemError("Sine \(hz) Hz at \(expected) dB read as \(frequencies[peak]) Hz at \(levels[peak]) dB")
      }
      guard levels.min()! < expected - 60 else { throw StemError("Sine \(hz) Hz leaks across the spectrum") }
    }
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
        let t = Float(n) / SpectrumAnalyzer.rate + time, noise = Float.random(in: -1...1, using: &generator)
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
    for (name, threeD) in [("3d", true), ("2d", false)] {
      view.threeD = threeD
      // At Retina scale, as on screen, and each draw after a new row, as in real time.
      let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(view.bounds.width) * 2, pixelsHigh: Int(view.bounds.height) * 2,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
      rep.size = view.bounds.size
      var drawn: Double = 0
      NSGraphicsContext.saveGraphicsState()
      NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
      for _ in 0..<5 {
        view.push(heard: last.0, original: last.1)
        let began = stemClock()
        view.draw(view.bounds)
        NSGraphicsContext.current?.flushGraphics()
        drawn += stemClock() - began
      }
      NSGraphicsContext.restoreGraphicsState()
      timings[name] = drawn / 5
      // The window shows dark glass behind the plot; stand in for it so the PNG reads true.
      let image = NSImage(size: view.bounds.size)
      image.addRepresentation(rep)
      image.lockFocus()
      NSColor(srgbRed: 0.10, green: 0.11, blue: 0.16, alpha: 1).setFill()
      view.bounds.fill(using: .destinationOver)
      image.unlockFocus()
      try NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
        .write(to: out.appendingPathComponent("spectrum-\(name).png"))
    }
    // The whole window, toolbar included, over a dusk-blue stand-in for the desktop behind the glass.
    // The content inside the glass: the glass itself renders opaque grey off screen.
    view.threeD = true
    if let content = view.superview {
      let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds)!
      content.cacheDisplay(in: content.bounds, to: rep)
      let image = NSImage(size: content.bounds.size)
      image.addRepresentation(rep)
      image.lockFocus()
      NSGradient(starting: NSColor(srgbRed: 0.22, green: 0.25, blue: 0.37, alpha: 1),
        ending: NSColor(srgbRed: 0.13, green: 0.15, blue: 0.20, alpha: 1))!.draw(in: content.bounds, angle: -90)
      rep.draw(in: content.bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
      image.unlockFocus()
      try NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
        .write(to: out.appendingPathComponent("spectrum-window.png"))
    }
    // A row and a draw must fit well inside the 33 ms row period.
    guard timings["push"]! + timings["3d"]! < 0.020, timings["2d"]! < 0.020 else { throw StemError("Spectrum draw too slow: \(timings)") }
    print("PASS spectrum · sines read true, ms p95 push \(Int(timings["push"]! * 1000)), draw 3D \(Int(timings["3d"]! * 1000)) 2D \(Int(timings["2d"]! * 1000)), spectrum-3d.png, spectrum-2d.png")
  }
}
