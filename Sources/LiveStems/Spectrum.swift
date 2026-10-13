import Accelerate
import AppKit

/// Turns the newest 4096 mix samples into band levels in dB, full-scale sine = 0 dB.
struct SpectrumAnalyzer {
  static let size = 4096, bands = 400, rate: Float = 44100
  static let minFrequency: Float = 20, maxFrequency: Float = 20000
  private let fft = vDSP.FFT(log2n: 12, radix: .radix2, ofType: DSPSplitComplex.self)!
  private let window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: size, isHalfWindow: false)

  /// Band centre frequencies, log or linearly spaced.
  static func frequencies(log: Bool) -> [Float] {
    (0..<bands).map { i in
      let t = Float(i) / Float(bands - 1)
      return log ? minFrequency * pow(maxFrequency / minFrequency, t) : minFrequency + (maxFrequency - minFrequency) * t
    }
  }
  /// Where a frequency sits across the axis, 0 to 1.
  static func position(_ frequency: Float, log: Bool) -> CGFloat {
    CGFloat(log ? Foundation.log(frequency / minFrequency) / Foundation.log(maxFrequency / minFrequency)
      : (frequency - minFrequency) / (maxFrequency - minFrequency))
  }

  func levels(_ samples: [Float], log: Bool) -> [Float] {
    precondition(samples.count == Self.size)
    let windowed = vDSP.multiply(samples, window)
    var real = [Float](repeating: 0, count: Self.size / 2), imag = real
    var magnitudes = [Float](repeating: 0, count: Self.size / 2)
    real.withUnsafeMutableBufferPointer { re in
      imag.withUnsafeMutableBufferPointer { im in
        var split = DSPSplitComplex(realp: re.baseAddress!, imagp: im.baseAddress!)
        windowed.withUnsafeBytes { vDSP_ctoz($0.bindMemory(to: DSPComplex.self).baseAddress!, 2, &split, 1, vDSP_Length(Self.size / 2)) }
        fft.forward(input: split, output: &split)
        split.imagp[0] = 0  // zrip packs Nyquist there; DC and Nyquist are below and above the axis anyway
        vDSP.absolute(split, result: &magnitudes)
      }
    }
    // zrip doubles, the Hann window halves: a full-scale sine peaks at size / 2.
    let binWidth = Self.rate / Float(Self.size), scale = 2 / Float(Self.size)
    let centres = Self.frequencies(log: log), ratio = log ? pow(Self.maxFrequency / Self.minFrequency, 0.5 / Float(Self.bands - 1)) : 1
    let half = log ? 0 : (Self.maxFrequency - Self.minFrequency) / Float(Self.bands - 1) / 2
    return centres.map { f in
      let lo = (log ? f / ratio : f - half) / binWidth, hi = (log ? f * ratio : f + half) / binWidth
      var peak: Float
      if hi - lo < 1 {  // narrower than a bin: interpolate between the two nearest
        let x = min(Float(magnitudes.count - 2), f / binWidth), k = Int(x)
        peak = magnitudes[k] + (magnitudes[k + 1] - magnitudes[k]) * (x - Float(k))
      } else {
        peak = magnitudes[max(1, Int(lo.rounded(.up)))...min(magnitudes.count - 1, Int(hi))].max() ?? 0
      }
      return 20 * log10(max(peak * scale, 1e-7))
    }
  }
}

/// Rolling spectrum history drawn as a 3D waterfall (newest in front) or a 2D spectrogram.
final class SpectrumView: NSView {
  static let floor: Float = -120, rowsPerSecond = 30
  var threeD = true { didSet { needsDisplay = true } }
  var logFrequency = true { didSet { rows.removeAll(); trail = nil; needsDisplay = true } }
  var seconds = 5 { didSet { trim(); trail = nil; needsDisplay = true } }
  var hint: String? { didSet { needsDisplay = oldValue != hint || needsDisplay } }
  /// Oldest first; each row holds band levels in dB.
  private(set) var rows = [[Float]]()
  /// The 3D rows already drawn, in device pixels. Each new row shifts it one step back
  /// and fades it, then draws only itself in front: painter's order for free, one row per frame.
  private var trail: CGContext?, trailCarry = CGPoint.zero

  func push(_ levels: [Float]) {
    rows.append(levels)
    trim()
    if threeD { advanceTrail(levels) } else { trail = nil }
    needsDisplay = true
  }
  override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    trail = nil
  }
  private func trim() {
    let keep = seconds * Self.rowsPerSecond
    if rows.count > keep { rows.removeFirst(rows.count - keep) }
  }
  private static func normalized(_ db: Float) -> CGFloat { CGFloat(max(0, min(1, (db - floor) / -floor))) }

  /// Deep blue for quiet, through violet and magenta, to orange and gold for the loudest.
  static let palette: [(CGFloat, NSColor)] = [
    (0, NSColor(srgbRed: 0.10, green: 0.16, blue: 0.75, alpha: 1)),
    (0.35, NSColor(srgbRed: 0.27, green: 0.30, blue: 1.00, alpha: 1)),
    (0.55, NSColor(srgbRed: 0.55, green: 0.25, blue: 1.00, alpha: 1)),
    (0.70, NSColor(srgbRed: 0.90, green: 0.25, blue: 0.85, alpha: 1)),
    (0.85, NSColor(srgbRed: 1.00, green: 0.50, blue: 0.25, alpha: 1)),
    (1, NSColor(srgbRed: 1.00, green: 0.85, blue: 0.40, alpha: 1)),
  ]
  private let gradient = NSGradient(colors: palette.map(\.1), atLocations: palette.map(\.0), colorSpace: .sRGB)!
  private let glow = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
    colors: palette.map(\.1.cgColor) as CFArray, locations: palette.map(\.0))!
  private lazy var lookup: [UInt32] = (0..<256).map { i in
    let c = gradient.interpolatedColor(atLocation: CGFloat(i) / 255).usingColorSpace(.sRGB)!
    let fade = min(1, CGFloat(i) / 255 * 1.6)  // quiet cells sink into the background
    let r = UInt32(c.redComponent * fade * 255), g = UInt32(c.greenComponent * fade * 255), b = UInt32(c.blueComponent * fade * 255)
    return 0xFF00_0000 | b << 16 | g << 8 | r
  }

  private var frequencyTicks: [(Float, String)] {
    logFrequency
      ? [(20, "20"), (50, "50"), (100, "100"), (200, "200"), (500, "500"), (1000, "1k"), (2000, "2k"), (5000, "5k"), (10000, "10k"), (20000, "20k")]
      : [(20, "0"), (5000, "5k"), (10000, "10k"), (15000, "15k"), (20000, "20k")]
  }
  private let labelFont = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
  private func label(_ text: String, at point: CGPoint, align: CGFloat = 0.5, color: NSColor = .secondaryLabelColor) {
    let string = NSAttributedString(string: text, attributes: [.font: labelFont, .foregroundColor: color])
    let size = string.size()
    string.draw(at: CGPoint(x: point.x - size.width * align, y: point.y - size.height / 2))
  }
  private func title(_ text: String, at point: CGPoint, rotated: Bool = false) {
    let string = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 11.5, weight: .medium), .foregroundColor: NSColor.labelColor])
    let size = string.size()
    guard rotated, let context = NSGraphicsContext.current?.cgContext else {
      return string.draw(at: CGPoint(x: point.x - size.width / 2, y: point.y - size.height / 2))
    }
    context.saveGState()
    context.translateBy(x: point.x, y: point.y)
    context.rotate(by: .pi / 2)
    string.draw(at: CGPoint(x: -size.width / 2, y: -size.height / 2))
    context.restoreGState()
  }

  override func draw(_ dirtyRect: NSRect) {
    guard let context = NSGraphicsContext.current?.cgContext else { return }
    let plate = NSBezierPath(roundedRect: bounds, xRadius: 12, yRadius: 12)
    NSColor.black.withAlphaComponent(0.42).setFill()
    plate.fill()
    if threeD { drawWaterfall(context) } else { drawSpectrogram(context) }
    if let hint {
      label(hint, at: CGPoint(x: bounds.midX, y: bounds.midY), color: .secondaryLabelColor)
    }
  }

  // MARK: 3D waterfall

  /// Oblique axes: frequency runs down to the right, time recedes up to the right.
  private struct Box {
    let origin: CGPoint, along: CGVector, back: CGVector, up: CGVector
    init(_ size: CGSize) {
      origin = CGPoint(x: 0.10 * size.width, y: 0.22 * size.height)
      along = CGVector(dx: 0.64 * size.width, dy: -0.12 * size.height)
      back = CGVector(dx: 0.20 * size.width, dy: 0.30 * size.height)
      up = CGVector(dx: 0, dy: 0.38 * size.height)
    }
    func point(_ f: CGFloat, _ t: CGFloat, _ v: CGFloat) -> CGPoint {
      CGPoint(x: origin.x + along.dx * f + back.dx * t + up.dx * v, y: origin.y + along.dy * f + back.dy * t + up.dy * v)
    }
    /// The box outline seen from the front: nothing is drawn outside it.
    var silhouette: CGPath {
      let path = CGMutablePath()
      path.addLines(between: [point(0, 0, 0), point(1, 0, 0), point(1, 1, 0), point(1, 1, 1.05), point(0, 1, 1.05), point(0, 0, 1.05)])
      path.closeSubpath()
      return path
    }
  }
  /// 256 colours from quiet to loud, for one stroke per segment.
  private lazy var strokeColors: [CGColor] = (0..<256).map {
    gradient.interpolatedColor(atLocation: CGFloat($0) / 255).cgColor
  }

  private func advanceTrail(_ levels: [Float]) {
    let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
    let width = Int(bounds.width * scale), height = Int(bounds.height * scale)
    guard width > 0, height > 0 else { return }
    let box = Box(bounds.size)
    let previous = trail?.makeImage()
    if trail == nil || trail!.width != width || trail!.height != height {
      // Opaque black: light adds up across rows (glow), and black adds nothing over the grid.
      trail = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)
      trailCarry = .zero
    }
    guard let context = trail else { return }
    let all = CGRect(x: 0, y: 0, width: width, height: height)
    context.setFillColor(.black)
    context.fill(all)
    // Shift by whole pixels so the image never resamples into a blur; carry the rest.
    let capacity = CGFloat(seconds * Self.rowsPerSecond)
    trailCarry.x += box.back.dx * scale / capacity
    trailCarry.y += box.back.dy * scale / capacity
    let shift = CGPoint(x: trailCarry.x.rounded(), y: trailCarry.y.rounded())
    trailCarry.x -= shift.x
    trailCarry.y -= shift.y
    if let previous {
      context.saveGState()
      context.addPath(box.silhouette.copy(using: [CGAffineTransform(scaleX: scale, y: scale)])!)
      context.clip()
      // Dimmed to 25% by the back of the box.
      context.setAlpha(pow(0.25, 1 / capacity))
      context.draw(previous, in: all.offsetBy(dx: shift.x, dy: shift.y))
      context.restoreGState()
    }
    context.saveGState()
    context.scaleBy(x: scale, y: scale)
    drawRow(levels, in: context, box: box)
    context.restoreGState()
  }

  /// One slice in front: a dark veil that dims the rows behind it, a faint coloured
  /// sheet, then a glowing edge. Each segment takes the colour of its height and
  /// frequency: gold lows, magenta mids, blue highs, brighter when louder.
  private func drawRow(_ levels: [Float], in context: CGContext, box: Box) {
    let n = levels.count
    let points = levels.enumerated().map { box.point(CGFloat($0.offset) / CGFloat(n - 1), 0, Self.normalized($0.element)) }
    let tone = levels.enumerated().map { i, db -> Int in
      let level = Self.normalized(db), low = 1 - CGFloat(i) / CGFloat(n - 1)
      return Int(max(0, min(1, 0.7 * level + 0.5 * low * level)) * 255)
    }
    let curve = CGMutablePath()
    curve.addLines(between: points)
    let area = curve.mutableCopy()!
    area.addLine(to: box.point(1, 0, 0))
    area.addLine(to: box.origin)
    area.closeSubpath()
    context.addPath(area)
    context.setFillColor(CGColor(gray: 0, alpha: 0.5))
    context.fillPath()
    context.saveGState()
    context.addPath(area)
    context.clip()
    context.setBlendMode(.plusLighter)
    context.setAlpha(0.07)
    context.concatenate(CGAffineTransform(a: box.along.dx, b: box.along.dy, c: box.up.dx, d: box.up.dy, tx: box.origin.x, ty: box.origin.y))
    context.drawLinearGradient(glow, start: .zero, end: CGPoint(x: 0, y: 1), options: [.drawsAfterEndLocation])
    context.restoreGState()
    context.saveGState()
    context.setBlendMode(.plusLighter)
    context.setLineCap(.round)
    for (width, alpha) in [(4.0, 0.05), (2.0, 0.10), (0.8, 0.55)] as [(CGFloat, CGFloat)] {
      context.setLineWidth(width)
      context.setAlpha(alpha)
      for i in 1..<n {
        context.setStrokeColor(strokeColors[max(tone[i - 1], tone[i])])
        context.strokeLineSegments(between: [points[i - 1], points[i]])
      }
    }
    context.restoreGState()
  }

  private func drawWaterfall(_ context: CGContext) {
    let box = Box(bounds.size)
    context.setLineWidth(1)
    context.setStrokeColor(NSColor.white.withAlphaComponent(0.08).cgColor)
    let dbTicks: [Float] = [0, -20, -40, -60, -80, -100, -120]
    for (f, _) in frequencyTicks {  // floor and back wall, per frequency
      let x = SpectrumAnalyzer.position(f, log: logFrequency)
      context.strokeLineSegments(between: [box.point(x, 0, 0), box.point(x, 1, 0), box.point(x, 1, 0), box.point(x, 1, 1)])
    }
    for db in dbTicks {  // left and back walls, per level
      let v = Self.normalized(db)
      context.strokeLineSegments(between: [box.point(0, 0, v), box.point(0, 1, v), box.point(0, 1, v), box.point(1, 1, v)])
    }
    for s in 0...seconds {  // floor, per second
      let t = CGFloat(s) / CGFloat(seconds)
      context.strokeLineSegments(between: [box.point(0, t, 0), box.point(1, t, 0)])
    }
    if let image = trail?.makeImage() {
      context.saveGState()
      context.setBlendMode(.plusLighter)
      context.draw(image, in: bounds)
      context.restoreGState()
    }
    context.setStrokeColor(NSColor.white.withAlphaComponent(0.35).cgColor)
    context.strokeLineSegments(between: [box.point(0, 0, 0), box.point(0, 0, 1), box.point(0, 0, 0), box.point(1, 0, 0),
      box.point(1, 0, 0), box.point(1, 1, 0)])
    for db in dbTicks {
      label("\(Int(db))", at: box.point(0, 0, Self.normalized(db)) - CGVector(dx: 8, dy: 0), align: 1)
    }
    for (f, text) in frequencyTicks {
      label(text, at: box.point(SpectrumAnalyzer.position(f, log: logFrequency), 0, 0) - CGVector(dx: 0, dy: 14))
    }
    for s in 0...seconds where seconds <= 5 || s % 2 == 0 {
      label("\(s)", at: box.point(1, CGFloat(s) / CGFloat(seconds), 0) + CGVector(dx: 10, dy: 0), align: 0)
    }
    title("Amplitude (dB)", at: box.point(0, 0, 1) + CGVector(dx: 0, dy: 22))
    title("Frequency (Hz)", at: box.point(0.42, 0, 0) - CGVector(dx: 0, dy: 40))
    title("Time (s)", at: box.point(1, 0.5, 0) + CGVector(dx: 52, dy: 0))
  }

  // MARK: 2D spectrogram

  private func drawSpectrogram(_ context: CGContext) {
    let plot = NSRect(x: 64, y: 44, width: bounds.width - 88, height: bounds.height - 70)
    let width = seconds * Self.rowsPerSecond, height = SpectrumAnalyzer.bands
    var pixels = [UInt32](repeating: 0xFF00_0000, count: width * height)
    let offset = width - rows.count
    for (index, row) in rows.enumerated() {
      for (band, db) in row.enumerated() {
        pixels[(height - 1 - band) * width + offset + index] = lookup[Int(Self.normalized(db) * 255)]
      }
    }
    let image = pixels.withUnsafeMutableBytes { bytes in
      CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
    }
    context.saveGState()
    context.addPath(CGPath(roundedRect: plot, cornerWidth: 6, cornerHeight: 6, transform: nil))
    context.clip()
    context.interpolationQuality = .medium
    if let image { context.draw(image, in: plot) }
    context.restoreGState()
    context.setStrokeColor(NSColor.white.withAlphaComponent(0.08).cgColor)
    for (f, text) in frequencyTicks {
      let y = plot.minY + plot.height * SpectrumAnalyzer.position(f, log: logFrequency)
      context.strokeLineSegments(between: [CGPoint(x: plot.minX, y: y), CGPoint(x: plot.maxX, y: y)])
      label(text, at: CGPoint(x: plot.minX - 8, y: y), align: 1)
    }
    for s in 0...seconds where seconds <= 5 || s % 2 == 0 {
      let x = plot.maxX - plot.width * CGFloat(s) / CGFloat(seconds)
      label(s == 0 ? "now" : "-\(s)", at: CGPoint(x: x, y: plot.minY - 12))
    }
    title("Frequency (Hz)", at: CGPoint(x: 16, y: plot.midY), rotated: true)
    title("Time (s)", at: CGPoint(x: plot.midX, y: 14))
  }
}

private func - (p: CGPoint, v: CGVector) -> CGPoint { CGPoint(x: p.x - v.dx, y: p.y - v.dy) }
private func + (p: CGPoint, v: CGVector) -> CGPoint { CGPoint(x: p.x + v.dx, y: p.y + v.dy) }

/// The Spectrum Analyzer window: a toolbar row like the panel's, and the plot.
final class SpectrumWindowController: NSObject, NSWindowDelegate {
  let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 600),
    styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
  let view = SpectrumView()
  private let analyzer = SpectrumAnalyzer()
  private var timer: Timer?
  /// Supplies the newest mix samples as heard now, or nil when nothing plays through Live Stems.
  private let read: (@escaping ([Float]?) -> Void) -> Void
  private let mode = NSSegmentedControl(labels: ["3D", "2D"], trackingMode: .selectOne, target: nil, action: nil)
  private let scale = NSPopUpButton(), span = NSPopUpButton()

  init(read: @escaping (@escaping ([Float]?) -> Void) -> Void) {
    self.read = read
    super.init()
    window.title = "Spectrum Analyzer"
    window.titlebarAppearsTransparent = true
    window.titleVisibility = .hidden
    window.isMovableByWindowBackground = true
    window.isReleasedWhenClosed = false
    window.appearance = NSAppearance(named: .darkAqua)
    window.minSize = NSSize(width: 620, height: 420)
    window.isOpaque = false
    window.backgroundColor = .clear
    window.delegate = self
    let content = NSView()
    let backing: NSView
    if #available(macOS 26.0, *) {
      let glass = NSGlassEffectView()
      glass.contentView = content
      backing = glass
    } else {
      let blur = NSVisualEffectView()
      blur.material = .hudWindow
      blur.blendingMode = .behindWindow
      blur.state = .active
      blur.addSubview(content)
      content.autoresizingMask = [.width, .height]
      backing = blur
    }
    window.contentView = backing
    content.frame = backing.bounds

    let icon = NSImageView(image: symbol(["chart.bar.xaxis", "waveform"]))
    icon.symbolConfiguration = .init(pointSize: 15, weight: .semibold)
    icon.contentTintColor = .labelColor
    let name = NSTextField(labelWithString: "Spectrum Analyzer")
    name.font = .systemFont(ofSize: 14, weight: .semibold)
    mode.selectedSegment = 0
    mode.setAccessibilityLabel("View")
    scale.addItems(withTitles: ["Log Frequency", "Linear Frequency"])
    scale.setAccessibilityLabel("Frequency scale")
    span.addItems(withTitles: ["2 s", "5 s", "10 s"])
    span.selectItem(at: 1)
    span.setAccessibilityLabel("Time span")
    for (control, action) in [(mode, #selector(changeMode)), (scale, #selector(changeScale)), (span, #selector(changeSpan))] as [(NSControl, Selector)] {
      control.target = self
      control.action = action
      control.controlSize = .large
    }
    let toolbar = NSStackView(views: [icon, name, NSView(), mode, scale, span])
    toolbar.spacing = 10
    toolbar.setHuggingPriority(.defaultLow, for: .horizontal)
    view.setAccessibilityLabel("Spectrum of the mix you hear")
    for item in [toolbar, view] as [NSView] {
      item.translatesAutoresizingMaskIntoConstraints = false
      content.addSubview(item)
    }
    NSLayoutConstraint.activate([
      toolbar.topAnchor.constraint(equalTo: content.topAnchor, constant: 34),
      toolbar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
      toolbar.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
      view.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 14),
      view.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
      view.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
      view.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
    ])
  }

  func show() {
    if !window.isVisible { window.center() }
    window.makeKeyAndOrderFront(nil)
    guard timer == nil else { return }
    // 30 rows a second while open; nothing runs while closed.
    timer = Timer(timeInterval: 1.0 / Double(SpectrumView.rowsPerSecond), repeats: true) { [weak self] _ in self?.tick() }
    RunLoop.main.add(timer!, forMode: .common)
  }
  func windowWillClose(_ notification: Notification) {
    timer?.invalidate()
    timer = nil
  }
  private func tick() {
    read { [weak self] samples in
      guard let self else { return }
      self.view.hint = samples == nil ? "Shows what Live Stems plays. Press M or S on a stem to start." : nil
      self.view.push(self.analyzer.levels(samples ?? [Float](repeating: 0, count: SpectrumAnalyzer.size), log: self.view.logFrequency))
    }
  }
  @objc private func changeMode() { view.threeD = mode.selectedSegment == 0 }
  @objc private func changeScale() { view.logFrequency = scale.indexOfSelectedItem == 0 }
  @objc private func changeSpan() { view.seconds = [2, 5, 10][span.indexOfSelectedItem] }
}
