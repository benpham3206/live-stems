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
    let silent = analyzer.levels([Float](repeating: 0, count: SpectrumAnalyzer.size), log: true)
    guard silent.allSatisfy({ $0 <= -120 }) else { throw StemError("Silence is not at the floor") }

    // Music-like test signal: a bass line, a chord with rich harmonics and vibrato,
    // a kick every half second and hi-hat noise, through the real analyzer.
    let controller = SpectrumWindowController { $0(nil) }
    let view = controller.view
    controller.window.setContentSize(NSSize(width: 1240, height: 760))
    controller.window.contentView?.layoutSubtreeIfNeeded()
    var generator = SystemRandomNumberGenerator()
    var pushSeconds = [Double]()
    let progression: [[Float]] = [[0, 4, 7, 11], [5, 9, 12, 16], [7, 11, 14, 17], [-3, 0, 4, 7]]
    for frame in 0..<(view.seconds * SpectrumView.rowsPerSecond) {
      let time = Float(frame) / Float(SpectrumView.rowsPerSecond)
      let chord = progression[Int(time / 1.25) % 4], beat = time.truncatingRemainder(dividingBy: 0.5)
      let kick = beat < 0.12 ? exp(-beat * 30) : 0, hat = beat > 0.25 && beat < 0.32 ? Float(0.25) : 0.001
      // The original has a sung line; what you hear has it muted, as with Vocals muted.
      var heard = [Float](), song = [Float]()
      let note = 392 * pow(2, Float([0, 2, 4, 7, 4, 2][Int(time / 0.4) % 6]) / 12)
      for n in 0..<SpectrumAnalyzer.size {
        let t = Float(n) / SpectrumAnalyzer.rate + time
        var x = Float.random(in: -1...1, using: &generator) * hat * 0.2
        x += kick * 0.8 * sin(2 * .pi * (50 + 60 * kick) * t)
        x += 0.25 * sin(2 * .pi * 55 * pow(2, chord[0] / 12) * t)
        for (k, step) in chord.enumerated() {
          let f = 220 * pow(2, step / 12) * (1 + 0.004 * sin(2 * .pi * 5 * t + Float(k)))
          for h in 1...16 where f * Float(h) < 18000 { x += 0.03 / pow(Float(h), 1.3) * sin(2 * .pi * f * Float(h) * t) }
        }
        var voice: Float = 0
        let sung = note * (1 + 0.01 * sin(2 * .pi * 5.5 * t))
        for h in 1...20 where sung * Float(h) < 16000 { voice += 0.12 / Float(h) * sin(2 * .pi * sung * Float(h) * t) }
        heard.append(x)
        song.append(x + voice)
      }
      let levels = (analyzer.levels(heard, log: true), analyzer.levels(song, log: true)), began = stemClock()
      view.push(heard: levels.0, original: levels.1)
      pushSeconds.append(stemClock() - began)
    }
    var timings = ["push": pushSeconds.sorted()[pushSeconds.count * 95 / 100]]
    for (name, threeD) in [("3d", true), ("2d", false)] {
      view.threeD = threeD
      let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
      let began = stemClock()
      for _ in 0..<5 { view.cacheDisplay(in: view.bounds, to: rep) }
      timings[name] = (stemClock() - began) / 5
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
    view.threeD = true
    if let content = controller.window.contentView {
      let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds)!
      content.cacheDisplay(in: content.bounds, to: rep)
      let image = NSImage(size: content.bounds.size)
      image.addRepresentation(rep)
      image.lockFocus()
      NSGradient(starting: NSColor(srgbRed: 0.16, green: 0.18, blue: 0.27, alpha: 1),
        ending: NSColor(srgbRed: 0.09, green: 0.10, blue: 0.16, alpha: 1))!.draw(in: content.bounds, angle: -90)
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
