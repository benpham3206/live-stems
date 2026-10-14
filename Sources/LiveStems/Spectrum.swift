import AppKit
import MetalKit

/// MiniMeters-style spectrum (colour-mapped bars for what you hear, a white outline for
/// the original song) drawn as a rolling 3D waterfall, or flat with a vertical spectrogram.
final class SpectrumView: NSView {
  static let rowsPerSecond = 30
  // MiniMeters' spectrum settings: a 4.8 dB/octave tilt around 1 kHz and a 60 dB window centred on -50 dB.
  static let tilt: Float = 4.8, top: Float = -20, bottom: Float = -80
  var threeD = true { didSet { mesh.isHidden = !threeD; overlay.isHidden = !threeD; needsDisplay = true; redraw() } }
  var logFrequency = true {
    didSet { history.removeAll(); lastRow = nil; waterfall?.clear(); heard = []; original = []; settingsChanged() }
  }
  var seconds = 5 { didSet { trim(); settingsChanged() } }
  var linearAmplitude = false { didSet { settingsChanged() } }
  var hint: String? { didSet { if oldValue != hint { needsDisplay = true; overlay.needsDisplay = true } } }
  /// Tilted band levels of the mix, oldest first, for the spectrogram.
  private(set) var history = [[Float]]()
  /// Tilted and smoothed, for the curves: what you hear, and the original song.
  private(set) var heard = [Float](), original = [Float]()
  /// The newest 3D row: what you hear in dB, averaged.
  private var lastRow: [Float]?

  func push(heard newHeard: [Float], original newOriginal: [Float]) {
    let tilts = SpectrumAnalyzer.frequencies(log: logFrequency).map { Self.tilt * log2($0 / 1000) }
    let mix = zip(newHeard, tilts).map(+), song = zip(newOriginal, tilts).map(+)
    history.append(mix)
    // Rows rise at once, as the 2D bars do, and fall through a power average of the last few,
    // so noise settles into a smooth floor under the peaks.
    let row = lastRow.map { last in
      last.count == newHeard.count ? zip(last, newHeard).map { max($1, 10 * log10(0.3 * pow(10, $0 / 10) + 0.7 * pow(10, $1 / 10))) } : newHeard
    } ?? newHeard
    lastRow = row
    waterfall?.push(row)
    trim()
    // Fast rise, slow fall, like MiniMeters' smoothing.
    func smooth(_ old: [Float], _ new: [Float]) -> [Float] {
      old.count == new.count ? zip(old, new).map { max($1, $0 * 0.75 + $1 * 0.25) } : new
    }
    heard = smooth(heard, mix)
    original = smooth(original, song)
    rowsPushed += 1
    if threeD { redraw() } else { needsDisplay = true }
  }
  /// Silence: every level drops to nothing, with one empty row at the front.
  func hush() {
    let floor = [Float](repeating: -200, count: SpectrumAnalyzer.bands)
    lastRow = nil
    push(heard: floor, original: floor)
    heard = floor
    original = floor
    if !threeD { needsDisplay = true }
  }
  /// Rows taken so far, and whether a redraw waits: for the checks.
  private(set) var rowsPushed = 0, framesDrawn = 0
  var redrawPending: Bool { needsDisplay || overlay.needsDisplay }
  /// Draws the 3D rows now. A needsDisplay-driven MTKView stopped drawing once its window closed and
  /// opened again (checked), so it draws only when told.
  func redraw() { if threeD, window?.isVisible == true { mesh.draw() } }
  private func trim() {
    let keep = seconds * Self.rowsPerSecond
    if history.count > keep { history.removeFirst(history.count - keep) }
  }
  static func normalized(_ db: Float) -> CGFloat { CGFloat(max(0, min(1, (db - bottom) / (top - bottom)))) }

  /// MiniMeters' Default colour map: clear, purple, magenta, orange-red, yellow.
  private static let stops: [(CGFloat, CGFloat, CGFloat, CGFloat, CGFloat)] = [
    (0, 0, 0, 255, 0), (0.50, 104, 3, 255, 54), (0.70, 237, 2, 155, 255), (0.74, 252, 57, 2, 255),
    (0.78, 255, 67, 28, 255), (0.94, 255, 221, 0, 255), (1, 255, 221, 0, 255),
  ]
  /// 256 steps of the colour map as (r, g, b, a), 0 to 1.
  private static let colormap: [(CGFloat, CGFloat, CGFloat, CGFloat)] = (0..<256).map { i in
    let t = CGFloat(i) / 255
    let hi = stops.firstIndex { $0.0 >= t } ?? stops.count - 1, lo = max(0, hi - 1)
    let a = stops[lo], b = stops[hi], f = b.0 > a.0 ? (t - a.0) / (b.0 - a.0) : 0
    func mix(_ x: CGFloat, _ y: CGFloat) -> CGFloat { (x + (y - x) * f) / 255 }
    return (mix(a.1, b.1), mix(a.2, b.2), mix(a.3, b.3), mix(a.4, b.4))
  }
  private static let barColors: [CGColor] = colormap.map { CGColor(srgbRed: $0.0, green: $0.1, blue: $0.2, alpha: $0.3) }
  /// Spectrogram pixels: the colour map over black, premultiplied RGBA.
  private static let pixelColors: [UInt32] = colormap.map { c in
    let r = UInt32(c.0 * c.3 * 255), g = UInt32(c.1 * c.3 * 255), b = UInt32(c.2 * c.3 * 255)
    return 0xFF00_0000 | b << 16 | g << 8 | r
  }
  private static func color(_ db: Float) -> Int { Int(normalized(db) * 255) }
  private static let lineColor = CGColor(srgbRed: 86 / 255, green: 96 / 255, blue: 111 / 255, alpha: 1)

  /// Frequency lines at every 1-9 x 10^n in log, every kHz in linear; labels at 100 Hz, 1 kHz, 10 kHz.
  private var frequencyLines: [(Float, String?)] {
    if !logFrequency {
      return stride(from: 0, through: 20000, by: 1000).map { (Float(max(20, $0)), $0 % 5000 == 0 ? "\($0 / 1000)kHz" : nil) }
    }
    let names: [Int: String] = [100: "100Hz", 1000: "1kHz", 10000: "10kHz"]
    var lines: [(Float, String?)] = []
    for decade in [10, 100, 1000, 10000] {
      for step in 1...9 where decade * step >= 20 && decade * step <= 20000 {
        lines.append((Float(decade * step), names[decade * step]))
      }
    }
    return lines
  }
  private let labelFont = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular)
  private func label(_ text: String, at point: CGPoint, align: CGFloat = 0.5, color: NSColor = NSColor(cgColor: lineColor)!) {
    let string = NSAttributedString(string: text, attributes: [.font: labelFont, .foregroundColor: color])
    let size = string.size()
    string.draw(at: CGPoint(x: point.x - size.width * align, y: point.y - size.height / 2))
  }

  override func draw(_ dirtyRect: NSRect) {
    // 2D is MiniMeters' black; 3D is its own views over the window's tinted glass, as the reference.
    guard !threeD, let context = NSGraphicsContext.current?.cgContext else { return }
    NSColor.black.setFill()
    NSBezierPath(roundedRect: bounds, xRadius: 12, yRadius: 12).fill()
    drawFlat(context)
    if let hint { label(hint, at: CGPoint(x: bounds.midX, y: bounds.midY), color: .secondaryLabelColor) }
  }

  /// Bars from the floor to each band's level, then the original's outline over them.
  private func drawSpectrum(_ heard: [Float], _ original: [Float], in context: CGContext,
    point: (CGFloat, CGFloat) -> CGPoint, outline: CGFloat) {
    let n = heard.count
    guard n > 1, original.count == n else { return }
    for (i, db) in heard.enumerated() {
      let v = Self.normalized(db)
      guard v > 0 else { continue }
      let lo = (CGFloat(i) - 0.5) / CGFloat(n - 1), hi = (CGFloat(i) + 0.5) / CGFloat(n - 1)
      context.setFillColor(Self.barColors[Self.color(db)])
      context.beginPath()
      context.addLines(between: [point(max(0, lo), 0), point(min(1, hi), 0), point(min(1, hi), v), point(max(0, lo), v)])
      context.fillPath()
    }
    context.beginPath()
    context.addLines(between: original.enumerated().map { point(CGFloat($0.offset) / CGFloat(n - 1), Self.normalized($0.element)) })
    context.setStrokeColor(.white)
    context.setLineWidth(outline)
    context.setLineJoin(.round)
    context.strokePath()
  }

  // MARK: 3D waterfall

  /// The rows on the GPU under an overlay of axes and labels, both through one camera. A
  /// right-drag turns the view, a double-click puts it back, a left-drag moves the window.
  private let waterfall: Waterfall? = {
    do { return try Waterfall() } catch {
      NSLog("Live Stems: the 3D view is off: %@", "\(error)")
      return nil
    }
  }()
  private let mesh = MTKView(), overlay = Overlay()
  var camera = Camera.reference { didSet { waterfall?.camera = camera; overlay.needsDisplay = true; redraw() } }
  private var turning: NSPoint?

  override init(frame: NSRect) {
    super.init(frame: frame)
    mesh.device = waterfall?.device
    mesh.delegate = self
    // Drawn on demand: after a new row or a turn, never on a timer.
    mesh.isPaused = true
    mesh.enableSetNeedsDisplay = false
    mesh.colorPixelFormat = .bgra8Unorm
    mesh.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
    mesh.layer?.isOpaque = false
    (mesh.layer as? CAMetalLayer)?.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
    overlay.paint = { [unowned self] in self.drawAxes($0) }
    overlay.layerContentsRedrawPolicy = .duringViewResize
    for view in [mesh, overlay] as [NSView] {
      view.frame = bounds
      view.autoresizingMask = [.width, .height]
      addSubview(view)
    }
    settingsChanged()
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

  /// The grid, colours and labels for the current scales and span.
  private func settingsChanged() {
    waterfall?.seconds = seconds
    waterfall?.linear = linearAmplitude
    // Each band's colour by where its frequency sits on the log axis, even when the axis is linear.
    waterfall?.hues = SpectrumAnalyzer.frequencies(log: logFrequency).map { Self.hue(SpectrumAnalyzer.position($0, log: true)) }
    // A fine grid on the floor, a coarser one on the two far walls.
    func line(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ alpha: Float, _ white: Float) -> Waterfall.Segment {
      .init(a: SIMD4(a, 1), b: SIMD4(b, 1), color: SIMD4(SIMD3(0.55 + white * 0.2, 0.65 + white * 0.15, 1) * alpha, alpha))
    }
    let quarters = Float(seconds * 4), walls = Float(seconds)
    var grid = (0...26).map { line([Float($0) / 26, 0, 0], [Float($0) / 26, 1, 0], 0.12, 0) }
    grid += (0...(seconds * 4)).map { line([0, Float($0) / quarters, 0], [1, Float($0) / quarters, 0], 0.12, 0) }
    grid += (0...13).map { line([Float($0) / 13, 1, 0], [Float($0) / 13, 1, 1], 0.16, 1) }
    grid += (1...seconds).map { line([0, Float($0) / walls, 0], [0, Float($0) / walls, 1], 0.16, 1) }
    for (db, _) in levels {
      let v = Float(height(db))
      grid += [line([0, 0, v], [0, 1, v], 0.16, 1), line([0, 1, v], [1, 1, v], 0.16, 1)]
    }
    waterfall?.grid = grid + [line([1, 1, 0], [1, 1, 1], 0.16, 1)]
    overlay.needsDisplay = true
    if threeD { redraw() } else { needsDisplay = true }
  }

  override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }
  override var mouseDownCanMoveWindow: Bool { true }
  override func mouseDown(with event: NSEvent) {
    if threeD && event.clickCount == 2 { camera = .reference } else { window?.performDrag(with: event) }
  }
  override func rightMouseDown(with event: NSEvent) { turning = event.locationInWindow }
  override func rightMouseDragged(with event: NSEvent) {
    guard threeD, let from = turning else { return }
    let to = event.locationInWindow
    camera.turn(dx: Float(to.x - from.x) * 0.01, dy: Float(to.y - from.y) * 0.01)  // drag up to look from below
    turning = to
  }
  override func rightMouseUp(with event: NSEvent) { turning = nil }
  /// Scroll up (as the hand moves, whatever natural scrolling says) to zoom in.
  override func scrollWheel(with event: NSEvent) {
    guard threeD else { return super.scrollWheel(with: event) }
    let up = Float(event.scrollingDeltaY) * (event.isDirectionInvertedFromDevice ? -1 : 1)
    camera.magnify(up * (event.hasPreciseScrollingDeltas ? 0.01 : 0.1))
  }
  override func menu(for event: NSEvent) -> NSMenu? { nil }

  /// The 3D view drawn off screen, rows and overlay, for checks and pictures.
  func picture(scale: CGFloat) -> CGImage? {
    let width = Int(bounds.width * scale), height = Int(bounds.height * scale)
    guard let rows = waterfall?.snapshot(width: width, height: height, scale: Float(scale)),
      let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
    else { return nil }
    context.draw(rows, in: CGRect(x: 0, y: 0, width: width, height: height))
    context.scaleBy(x: scale, y: scale)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    drawAxes(context)
    NSGraphicsContext.restoreGraphicsState()
    return context.makeImage()
  }
  /// The rows rendered off screen at this scale without reading them back: a frame's GPU work.
  func renderRows(scale: CGFloat) {
    _ = waterfall?.snapshot(width: Int(bounds.width * scale), height: Int(bounds.height * scale), scale: Float(scale), read: false)
  }

  /// Height in the 3D box: 0 to -120 dB, or linear amplitude 0 to 1.
  private func height(_ db: Float) -> CGFloat {
    linearAmplitude ? CGFloat(min(1, pow(10, db / 20))) : CGFloat(max(0, min(1, (db + 120) / 120)))
  }
  private var levels: [(Float, String)] {
    linearAmplitude
      ? stride(from: 1.0, through: 0, by: -0.2).map { (20 * log10(max(Float($0), 1e-7)), String(format: "%.1f", $0)) }
      : stride(from: 0, through: -120, by: -20).map { (Float($0), "\($0)") }
  }
  /// Colour by frequency, as the reference: violet subs, orange and gold lows, pink and
  /// magenta mids, violet and blue highs. The shader keeps quiet parts blue whatever their frequency.
  private static let hues: [(CGFloat, (CGFloat, CGFloat, CGFloat))] = [
    (0, (0.70, 0.25, 1.00)), (0.20, (1.00, 0.42, 0.18)), (0.33, (1.00, 0.68, 0.22)), (0.48, (1.00, 0.38, 0.45)),
    (0.60, (0.95, 0.28, 0.85)), (0.75, (0.58, 0.30, 1.00)), (1, (0.25, 0.38, 1.00)),
  ]
  static func hue(_ x: CGFloat) -> SIMD4<Float> {
    let hi = hues.firstIndex { $0.0 >= x } ?? hues.count - 1, lo = max(0, hi - 1)
    let a = hues[lo], b = hues[hi], f = b.0 > a.0 ? (x - a.0) / (b.0 - a.0) : 0
    return SIMD4(Float(a.1.0 + (b.1.0 - a.1.0) * f), Float(a.1.1 + (b.1.1 - a.1.1) * f), Float(a.1.2 + (b.1.2 - a.1.2) * f), 1)
  }

  /// One axis title or tick label: where it goes, its size, which part of it sits there.
  struct Label {
    var text: String, at: CGPoint, size: CGFloat, align: CGFloat = 0.5, angle: CGFloat = 0
    var string: NSAttributedString {
      NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: size), .foregroundColor: SpectrumView.axisText])
    }
    /// The rect it covers in the view, turned with it.
    var frame: CGRect {
      let extent = string.size(), box = CGRect(x: -extent.width * align, y: -extent.height / 2, width: extent.width, height: extent.height)
      return box.applying(CGAffineTransform(rotationAngle: angle)).offsetBy(dx: at.x, dy: at.y)
    }
  }
  private static let axisText = NSColor(srgbRed: 0.88, green: 0.90, blue: 0.97, alpha: 0.88)
  /// Every label at this camera, in a view this size; none for a point behind the eye.
  func labels(in size: CGSize) -> [Label] {
    // Text and its offsets grow and shrink with the zoom, within a readable range.
    let z = CGFloat(min(1.6, max(0.6, camera.zoom)))
    func at(_ f: CGFloat, _ t: CGFloat, _ v: CGFloat) -> CGPoint? { camera.point(SIMD3(Float(f), Float(t), Float(v)), in: size) }
    guard let origin = at(0, 0, 0), let front = at(1, 0, 0), let top = at(0, 0, 1), let back = at(1, 1, 0) else { return [] }
    // An axis title lies level, a fixed distance straight under the middle of its axis.
    func title(_ text: String, _ from: CGPoint, _ to: CGPoint, size: CGFloat) -> Label {
      Label(text: text, at: CGPoint(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2 - 52 * z), size: size)
    }
    let titles = [
      Label(text: linearAmplitude ? "Amplitude" : "Amplitude (dB)", at: top + CGVector(dx: -63 * z, dy: 53 * z), size: 15 * z, align: 0),
      title("Frequency (Hz)", origin, front, size: 17 * z),
      title("Time (s)", front, back, size: 16 * z),
    ]
    var labels = levels.compactMap { db, text in at(0, 0, height(db)).map { Label(text: text, at: $0 - CGVector(dx: 15 * z, dy: 0), size: 13 * z, align: 1) } }
    let ticks: [(Float, String)] = [(20, "20"), (50, "50"), (100, "100"), (200, "200"), (500, "500"), (1000, "1k"), (2000, "2k"),
      (5000, "5k"), (10000, "10k"), (20000, "20k")]
    labels += ticks.compactMap { f, text in
      at(SpectrumAnalyzer.position(f, log: logFrequency), 0, 0).map { Label(text: text, at: $0 + CGVector(dx: -9 * z, dy: -23 * z), size: 15 * z) }
    }
    labels += (0...seconds).filter { seconds <= 5 || $0 % 2 == 0 }.compactMap { s in
      at(1, CGFloat(s) / CGFloat(seconds), 0).map { Label(text: "\(s)", at: $0 + CGVector(dx: 18 * z, dy: -4 * z), size: 14 * z, align: 0) }
    }
    // Seen edge on, an axis bunches its ticks: keep the titles, then each tick that clears all kept so far.
    return (titles + labels).reduce(into: [Label]()) { kept, label in
      if !kept.contains(where: { $0.frame.insetBy(dx: -2, dy: -1).intersects(label.frame) }) { kept.append(label) }
    }
  }

  /// Axes with arrows and ticks, the labels, and the hint, over the rows.
  func drawAxes(_ context: CGContext) {
    let size = bounds.size
    func at(_ f: CGFloat, _ t: CGFloat, _ v: CGFloat) -> CGPoint? { camera.point(SIMD3(Float(f), Float(t), Float(v)), in: size) }
    func stroke(_ points: CGPoint...) { context.strokeLineSegments(between: points) }
    func arrow(_ tip: CGPoint, from: CGPoint) {
      let d = CGVector(dx: tip.x - from.x, dy: tip.y - from.y), l = max(1e-3, hypot(d.dx, d.dy)), u = CGVector(dx: d.dx / l * 7, dy: d.dy / l * 7)
      context.beginPath()
      context.addLines(between: [tip - u + CGVector(dx: -u.dy * 0.5, dy: u.dx * 0.5), tip, tip - u + CGVector(dx: u.dy * 0.5, dy: -u.dx * 0.5)])
      context.strokePath()
    }
    if let origin = at(0, 0, 0), let top = at(0, 0, 1.04), let front = at(1, 0, 0), let back = at(1, 1.02, 0) {
      context.setLineWidth(1.1)
      context.setStrokeColor(CGColor(srgbRed: 0.78, green: 0.83, blue: 1, alpha: 0.72))
      stroke(origin, top, origin, front, front, back)
      arrow(top, from: origin)
      arrow(back, from: front)
      context.setLineWidth(1)
      for (db, _) in levels { if let p = at(0, 0, height(db)) { stroke(p, p - CGVector(dx: 4, dy: 0)) } }
      for f: Float in [20, 50, 100, 200, 500, 1000, 2000, 5000, 10000, 20000] {
        if let p = at(SpectrumAnalyzer.position(f, log: logFrequency), 0, 0) { stroke(p, p + CGVector(dx: -3, dy: -6)) }
      }
      for s in 0...seconds where seconds <= 5 || s % 2 == 0 {
        if let p = at(1, CGFloat(s) / CGFloat(seconds), 0) { stroke(p, p - CGVector(dx: 6, dy: 0)) }
      }
    }
    for label in labels(in: size) {
      let extent = label.string.size()
      context.saveGState()
      context.translateBy(x: label.at.x, y: label.at.y)
      context.rotate(by: label.angle)
      label.string.draw(at: CGPoint(x: -extent.width * label.align, y: -extent.height / 2))
      context.restoreGState()
    }
    if let text = waterfall == nil ? "3D needs Metal" : hint {
      label(text, at: CGPoint(x: bounds.midX, y: bounds.midY), color: .secondaryLabelColor)
    }
  }

  // MARK: Flat: spectrum over a vertical spectrogram

  private func drawFlat(_ context: CGContext) {
    let plot = bounds.insetBy(dx: 12, dy: 12)
    let top = NSRect(x: plot.minX, y: plot.maxY - plot.height * 0.4, width: plot.width, height: plot.height * 0.4)
    let below = NSRect(x: plot.minX, y: plot.minY, width: plot.width, height: plot.height * 0.6 - 6)
    // Spectrogram: frequency across, newest at the top.
    let width = SpectrumAnalyzer.bands, height = seconds * Self.rowsPerSecond
    var pixels = [UInt32](repeating: 0xFF00_0000, count: width * height)
    for (age, row) in history.reversed().enumerated() where row.count == width {
      for (band, db) in row.enumerated() { pixels[age * width + band] = Self.pixelColors[Self.color(db)] }
    }
    let image = pixels.withUnsafeMutableBytes { bytes in
      CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
    }
    if let image {
      context.interpolationQuality = .medium
      context.draw(image, in: below)
    }
    // Frequency lines through both, labels at the top like MiniMeters.
    context.setLineWidth(1)
    context.setStrokeColor(Self.lineColor.copy(alpha: 0.45)!)
    for (f, text) in frequencyLines {
      let x = (plot.minX + plot.width * SpectrumAnalyzer.position(f, log: logFrequency)).rounded() + 0.5
      context.strokeLineSegments(between: [CGPoint(x: x, y: top.minY), CGPoint(x: x, y: top.maxY)])
      if let text { label(text, at: CGPoint(x: x + 4, y: top.maxY - 9), align: 0) }
    }
    drawSpectrum(heard, original, in: context, point: { CGPoint(x: top.minX + top.width * $0, y: top.minY + top.height * $1) }, outline: 1.5)
    label("now", at: CGPoint(x: below.minX + 4, y: below.maxY - 9), align: 0)
    label("-\(seconds)s", at: CGPoint(x: below.minX + 4, y: below.minY + 9), align: 0)
  }
}

extension SpectrumView: MTKViewDelegate {
  func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { DispatchQueue.main.async { self.redraw() } }
  func draw(in view: MTKView) { framesDrawn += 1; waterfall?.draw(in: view) }
}

/// A transparent view that draws what it is given: the 3D view's axes and labels, over its rows.
final class Overlay: NSView {
  var paint: (CGContext) -> Void = { _ in }
  override func draw(_ dirtyRect: NSRect) { NSGraphicsContext.current.map { paint($0.cgContext) } }
}

private func - (p: CGPoint, v: CGVector) -> CGPoint { CGPoint(x: p.x - v.dx, y: p.y - v.dy) }
private func + (p: CGPoint, v: CGVector) -> CGPoint { CGPoint(x: p.x + v.dx, y: p.y + v.dy) }
