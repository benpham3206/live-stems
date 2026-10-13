import Accelerate
import AppKit

/// Turns the newest 16384 mix samples into band levels in dB, full-scale sine = 0 dB. As
/// multi-resolution analyzers do, bands under 300 Hz read all 16384 (370 ms), so low notes stay
/// narrow on the log axis, and the rest read the newest 8192 (186 ms), so the highs keep up.
/// A Blackman-Harris window keeps each note's leakage 92 dB down: valleys stay deep.
struct SpectrumAnalyzer {
  static let size = 16384, bands = 400, rate: Float = 44100, crossover: Float = 300
  static let minFrequency: Float = 20, maxFrequency: Float = 20000
  private let long = Resolution(log2n: 14), short = Resolution(log2n: 13)

  /// One FFT size: magnitudes of the newest samples, a full-scale sine peaking at 1.
  private struct Resolution {
    static let terms: [Float] = [0.35875, -0.48829, 0.14128, -0.01168]
    let size: Int, fft: vDSP.FFT<DSPSplitComplex>, window: [Float]
    init(log2n: Int) {
      size = 1 << log2n
      fft = vDSP.FFT(log2n: vDSP_Length(log2n), radix: .radix2, ofType: DSPSplitComplex.self)!
      window = (0..<size).map { [size] n in
        Self.terms.enumerated().reduce(0) { $0 + $1.element * cos(2 * .pi * Float($1.offset * n) / Float(size)) }
      }
    }
    var binWidth: Float { SpectrumAnalyzer.rate / Float(size) }
    func magnitudes(_ samples: [Float]) -> [Float] {
      let windowed = vDSP.multiply(samples.suffix(size), window)
      var real = [Float](repeating: 0, count: size / 2), imag = real, magnitudes = real
      real.withUnsafeMutableBufferPointer { re in
        imag.withUnsafeMutableBufferPointer { im in
          var split = DSPSplitComplex(realp: re.baseAddress!, imagp: im.baseAddress!)
          windowed.withUnsafeBytes { vDSP_ctoz($0.bindMemory(to: DSPComplex.self).baseAddress!, 2, &split, 1, vDSP_Length(size / 2)) }
          fft.forward(input: split, output: &split)
          split.imagp[0] = 0  // zrip packs Nyquist there; DC and Nyquist are below and above the axis anyway
          vDSP.absolute(split, result: &magnitudes)
        }
      }
      // zrip doubles, the window scales by its mean: a full-scale sine peaks at size * mean.
      return vDSP.multiply(1 / (Float(size) * Self.terms[0]), magnitudes)
    }
  }

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
    let spectra = [long, short].map { ($0.binWidth, $0.magnitudes(samples)) }
    let centres = Self.frequencies(log: log), ratio = log ? pow(Self.maxFrequency / Self.minFrequency, 0.5 / Float(Self.bands - 1)) : 1
    let half = log ? 0 : (Self.maxFrequency - Self.minFrequency) / Float(Self.bands - 1) / 2
    return centres.map { f in
      let (binWidth, magnitudes) = spectra[f < Self.crossover ? 0 : 1]
      let lo = (log ? f / ratio : f - half) / binWidth, hi = (log ? f * ratio : f + half) / binWidth
      var peak: Float
      if hi - lo < 1 {  // narrower than a bin: interpolate between the two nearest
        let x = min(Float(magnitudes.count - 2), f / binWidth), k = Int(x)
        peak = magnitudes[k] + (magnitudes[k + 1] - magnitudes[k]) * (x - Float(k))
      } else {
        peak = magnitudes[max(1, Int(lo.rounded(.up)))...min(magnitudes.count - 1, Int(hi))].max() ?? 0
      }
      return 20 * log10(max(peak, 1e-7))
    }
  }
}

/// The mix as heard and the original song, over the same moments.
struct Scope {
  var mix: [Float]
  var original: [Float]
}

/// MiniMeters-style spectrum (colour-mapped bars for what you hear, a white outline for
/// the original song) drawn as a rolling 3D waterfall, or flat with a vertical spectrogram.
final class SpectrumView: NSView {
  static let rowsPerSecond = 30
  // MiniMeters' spectrum settings: a 4.8 dB/octave tilt around 1 kHz and a 60 dB window centred on -50 dB.
  static let tilt: Float = 4.8, top: Float = -20, bottom: Float = -80
  var threeD = true { didSet { needsDisplay = true } }
  var logFrequency = true { didSet { history.removeAll(); rows.removeAll(); heard = []; original = []; rendered = nil; needsDisplay = true } }
  var seconds = 5 { didSet { trim(); rendered = nil; needsDisplay = true } }
  var linearAmplitude = false { didSet { rendered = nil; needsDisplay = true } }
  var hint: String? { didSet { needsDisplay = oldValue != hint || needsDisplay } }
  /// Tilted band levels of the mix, oldest first, for the spectrogram.
  private(set) var history = [[Float]]()
  /// Tilted and smoothed, for the curves: what you hear, and the original song.
  private(set) var heard = [Float](), original = [Float]()
  /// What you hear in dB, averaged, oldest first, for the 3D rows, and those rows drawn.
  private var rows = [[Float]](), rendered: CGImage?, pushed = 0
  /// The floor and walls, keyed by pixel size, seconds and amplitude scale.
  private var grid: (key: [Int], image: CGImage)?
  private lazy var waterfall = try? Waterfall()

  func push(heard newHeard: [Float], original newOriginal: [Float]) {
    let tilts = SpectrumAnalyzer.frequencies(log: logFrequency).map { Self.tilt * log2($0 / 1000) }
    let mix = zip(newHeard, tilts).map(+), song = zip(newOriginal, tilts).map(+)
    history.append(mix)
    // Rows average the last few in power, so noise settles into a smooth floor under the peaks.
    rows.append(rows.last.map { last in
      last.count == newHeard.count ? zip(last, newHeard).map { 10 * log10(0.3 * pow(10, $0 / 10) + 0.7 * pow(10, $1 / 10)) } : newHeard
    } ?? newHeard)
    pushed += 1
    trim()
    // Fast rise, slow fall, like MiniMeters' smoothing.
    func smooth(_ old: [Float], _ new: [Float]) -> [Float] {
      old.count == new.count ? zip(old, new).map { max($1, $0 * 0.75 + $1 * 0.25) } : new
    }
    heard = smooth(heard, mix)
    original = smooth(original, song)
    rendered = nil
    needsDisplay = true
  }
  override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    rendered = nil
  }
  private func trim() {
    let keep = seconds * Self.rowsPerSecond
    if history.count > keep { history.removeFirst(history.count - keep) }
    if rows.count > keep { rows.removeFirst(rows.count - keep) }
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
    guard let context = NSGraphicsContext.current?.cgContext else { return }
    // 2D is MiniMeters' black; 3D floats on the window's tinted glass, as the reference.
    if !threeD {
      NSColor.black.setFill()
      NSBezierPath(roundedRect: bounds, xRadius: 12, yRadius: 12).fill()
    }
    if threeD { drawWaterfall(context) } else { drawFlat(context) }
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

  /// The reference's perspective box. The floor is a homography of (frequency, time), each
  /// 0 to 1, onto the view as fractions of its size: it takes the corners (0, 0), (1, 0),
  /// (1, 1), (0, 1) to (0.066, 0.376), (0.788, 0.045), (0.924, 0.495), (0.317, 0.652).
  /// Heights stand straight up: 0 dB is 0.429 of the view high at the front, a fifth less at the back.
  private struct Box {
    static let ground: [SIMD3<Float>] = [[0.4874, 0.3325, 0.0656], [-0.3446, 0.4433, 0.3759], [-0.2978, 0.2563, 1]]
    static let lift: CGFloat = 0.429, shrink: CGFloat = 0.21
    let size: CGSize
    func point(_ f: CGFloat, _ t: CGFloat, _ v: CGFloat) -> CGPoint {
      let p = SIMD3(Float(f), Float(t), 1), g = Self.ground, w = CGFloat((g[2] * p).sum())
      return CGPoint(x: CGFloat((g[0] * p).sum()) / w * size.width,
        y: (CGFloat((g[1] * p).sum()) / w + v * Self.lift * (1 - Self.shrink * t)) * size.height)
    }
    /// The same box for the GPU, in pixels.
    func stage(scale: CGFloat, rows: Int, bands: Int) -> Waterfall.Stage {
      let g = Self.ground.map { SIMD4($0, 0) }
      return .init(x: g[0], y: g[1], w: g[2],
        shape: [Float(size.width * scale), Float(size.height * scale), Float(Self.lift), Float(Self.shrink)],
        counts: [Float(rows), Float(bands), 0, Float(scale)])
    }
  }
  /// Height in the 3D box: 0 to -120 dB, or linear amplitude 0 to 1.
  private func height(_ db: Float) -> CGFloat {
    linearAmplitude ? CGFloat(min(1, pow(10, db / 20))) : CGFloat(max(0, min(1, (db + 120) / 120)))
  }
  /// Colour by frequency, as the reference: violet subs, orange and gold lows, pink and
  /// magenta mids, violet and blue highs. The shader keeps quiet parts blue whatever their frequency.
  private static let hues: [(CGFloat, (CGFloat, CGFloat, CGFloat))] = [
    (0, (0.70, 0.25, 1.00)), (0.20, (1.00, 0.42, 0.18)), (0.33, (1.00, 0.68, 0.22)), (0.48, (1.00, 0.38, 0.45)),
    (0.60, (0.95, 0.28, 0.85)), (0.75, (0.58, 0.30, 1.00)), (1, (0.25, 0.38, 1.00)),
  ]
  private static func hue(_ x: CGFloat) -> SIMD4<Float> {
    let hi = hues.firstIndex { $0.0 >= x } ?? hues.count - 1, lo = max(0, hi - 1)
    let a = hues[lo], b = hues[hi], f = b.0 > a.0 ? (x - a.0) / (b.0 - a.0) : 0
    return SIMD4(Float(a.1.0 + (b.1.0 - a.1.0) * f), Float(a.1.1 + (b.1.1 - a.1.1) * f), Float(a.1.2 + (b.1.2 - a.1.2) * f), 1)
  }

  /// Every other row in the box, as the reference's ridges are spaced, on the GPU; nil without Metal.
  private func renderRows(scale: CGFloat) -> CGImage? {
    let bands = SpectrumAnalyzer.bands, capacity = Float(seconds * Self.rowsPerSecond)
    // Chosen by their place in the whole stream, so a row keeps being drawn as it recedes.
    let shown = rows.indices.filter { (pushed - rows.count + $0) % 2 == 0 && rows[$0].count == bands }
    // Every other band carries the loudest of it and its neighbours: a peak keeps its height
    // and reads as one spike, not a comb, as the reference draws them.
    let points = Array(stride(from: 0, through: bands - 1, by: 2))
    let frequencies = SpectrumAnalyzer.frequencies(log: logFrequency)
    // Each point's hue by where its frequency sits on the log axis, even when the axis is linear.
    let hues = points.map { Self.hue(SpectrumAnalyzer.position(frequencies[$0], log: true)) }
    let heights = shown.flatMap { row in points.map { Float(height(rows[row][max(0, $0 - 1)...min(bands - 1, $0 + 1)].max()!)) } }
    return waterfall?.render(heights, depths: shown.map { Float(rows.count - 1 - $0) / capacity }, hues: hues,
      stage: Box(size: bounds.size).stage(scale: scale, rows: shown.count, bands: points.count),
      width: Int(bounds.width * scale), height: Int(bounds.height * scale))
  }

  private static let axisText = NSColor(srgbRed: 0.88, green: 0.90, blue: 0.97, alpha: 0.88)
  private func text(_ string: String, at point: CGPoint, size: CGFloat = 13, align: CGFloat = 0.5, angle: CGFloat = 0) {
    let value = NSAttributedString(string: string, attributes: [.font: NSFont.systemFont(ofSize: size), .foregroundColor: Self.axisText])
    let extent = value.size()
    guard let context = NSGraphicsContext.current?.cgContext else { return }
    context.saveGState()
    context.translateBy(x: point.x, y: point.y)
    context.rotate(by: angle)
    value.draw(at: CGPoint(x: -extent.width * align, y: -extent.height / 2))
    context.restoreGState()
  }

  private func drawWaterfall(_ context: CGContext) {
    let box = Box(size: bounds.size)
    func stroke(_ points: CGPoint...) { context.strokeLineSegments(between: points) }
    let levels: [(Float, String)] = linearAmplitude
      ? stride(from: 1.0, through: 0, by: -0.2).map { (20 * log10(max(Float($0), 1e-7)), String(format: "%.1f", $0)) }
      : stride(from: 0, through: -120, by: -20).map { (Float($0), "\($0)") }
    // A faint blue floor, a fine grid on it and a coarser one on the two far walls, drawn once
    // per size and setting: stroked each frame they cost 7 ms at Retina scale.
    let scale = context.convertToDeviceSpace(CGRect(x: 0, y: 0, width: 1, height: 1)).width
    let key = [Int(bounds.width * scale), Int(bounds.height * scale), seconds, linearAmplitude ? 1 : 0]
    if grid?.key != key, let g = CGContext(data: nil, width: key[0], height: key[1], bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) {
      g.scaleBy(x: scale, y: scale)
      g.addLines(between: [box.point(0, 0, 0), box.point(1, 0, 0), box.point(1, 1, 0), box.point(0, 1, 0)])
      g.setFillColor(CGColor(srgbRed: 0.05, green: 0.10, blue: 0.34, alpha: 0.25))
      g.fillPath()
      let quarters = CGFloat(seconds * 4), walls = CGFloat(seconds)
      var floor = [CGPoint](), wall = [box.point(1, 1, 0), box.point(1, 1, 1)]
      for i in 0...26 { floor += [box.point(CGFloat(i) / 26, 0, 0), box.point(CGFloat(i) / 26, 1, 0)] }
      for i in 0...(seconds * 4) { floor += [box.point(0, CGFloat(i) / quarters, 0), box.point(1, CGFloat(i) / quarters, 0)] }
      for i in 0...13 { wall += [box.point(CGFloat(i) / 13, 1, 0), box.point(CGFloat(i) / 13, 1, 1)] }
      for s in 1...seconds { wall += [box.point(0, CGFloat(s) / walls, 0), box.point(0, CGFloat(s) / walls, 1)] }
      for (db, _) in levels {
        let v = height(db)
        wall += [box.point(0, 0, v), box.point(0, 1, v), box.point(0, 1, v), box.point(1, 1, v)]
      }
      g.setLineWidth(0.75)
      g.setStrokeColor(CGColor(srgbRed: 0.55, green: 0.65, blue: 1, alpha: 0.12))
      g.strokeLineSegments(between: floor)
      g.setStrokeColor(CGColor(srgbRed: 0.75, green: 0.80, blue: 1, alpha: 0.16))
      g.strokeLineSegments(between: wall)
      grid = g.makeImage().map { (key, $0) }
    }
    grid.map { context.draw($0.image, in: bounds) }
    // The rows, rendered once per new row at the pixel scale of what they draw into.
    if rendered?.width != Int(bounds.width * scale) { rendered = renderRows(scale: scale) }
    rendered.map { context.draw($0, in: bounds) }
    // Axes with arrows, ticks and labels.
    func arrow(_ tip: CGPoint, from: CGPoint) {
      let d = CGVector(dx: tip.x - from.x, dy: tip.y - from.y), l = hypot(d.dx, d.dy), u = CGVector(dx: d.dx / l * 7, dy: d.dy / l * 7)
      context.beginPath()
      context.addLines(between: [tip - u + CGVector(dx: -u.dy * 0.5, dy: u.dx * 0.5), tip, tip - u + CGVector(dx: u.dy * 0.5, dy: -u.dx * 0.5)])
      context.strokePath()
    }
    context.setLineWidth(1.1)
    context.setStrokeColor(CGColor(srgbRed: 0.78, green: 0.83, blue: 1, alpha: 0.72))
    let origin = box.point(0, 0, 0), top = box.point(0, 0, 1.04), front = box.point(1, 0, 0), back = box.point(1, 1.02, 0)
    stroke(origin, top, origin, front, front, back)
    arrow(top, from: origin)
    arrow(back, from: front)
    context.setLineWidth(1)
    for (db, label) in levels {
      let p = box.point(0, 0, height(db))
      stroke(p, p - CGVector(dx: 4, dy: 0))
      text(label, at: p - CGVector(dx: 15, dy: 0), align: 1)
    }
    let ticks: [(Float, String)] = [(20, "20"), (50, "50"), (100, "100"), (200, "200"), (500, "500"), (1000, "1k"), (2000, "2k"),
      (5000, "5k"), (10000, "10k"), (20000, "20k")]
    for (f, label) in ticks {
      let p = box.point(SpectrumAnalyzer.position(f, log: logFrequency), 0, 0)
      stroke(p, p + CGVector(dx: -3, dy: -6))
      text(label, at: p + CGVector(dx: -9, dy: -23), size: 15)
    }
    for s in 0...seconds where seconds <= 5 || s % 2 == 0 {
      let p = box.point(1, CGFloat(s) / CGFloat(seconds), 0)
      stroke(p, p - CGVector(dx: 6, dy: 0))
      text("\(s)", at: p + CGVector(dx: 18, dy: -4), size: 14, align: 0)
    }
    text(linearAmplitude ? "Amplitude" : "Amplitude (dB)", at: box.point(0, 0, 1) + CGVector(dx: -63, dy: 53), size: 15, align: 0)
    let slant = atan2(front.y - origin.y, front.x - origin.x)
    text("Frequency (Hz)", at: CGPoint(x: origin.x + (front.x - origin.x) * 0.426, y: origin.y + (front.y - origin.y) * 0.426 - 65),
      size: 17, angle: slant * 0.8)
    text("Time (s)", at: box.point(1, 0.5, 0) + CGVector(dx: 73, dy: -24), size: 16, align: 0)
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

private func - (p: CGPoint, v: CGVector) -> CGPoint { CGPoint(x: p.x - v.dx, y: p.y - v.dy) }
private func + (p: CGPoint, v: CGVector) -> CGPoint { CGPoint(x: p.x + v.dx, y: p.y + v.dy) }

/// The Spectrum Analyzer window: a toolbar row like the panel's, and the plot.
final class SpectrumWindowController: NSObject, NSWindowDelegate {
  let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 724),
    styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
  let view = SpectrumView()
  private let analyzer = SpectrumAnalyzer()
  private var timer: Timer?
  /// Supplies the newest samples as heard now, or nil when nothing plays through Live Stems.
  private let read: (@escaping (Scope?) -> Void) -> Void
  private let mode = Choice(["3D", "2D"])
  private let scale = NSPopUpButton(), amplitude = NSPopUpButton(), span = NSPopUpButton()
  private let settings = NSButton()
  /// The gear's menu: the model choice.
  private let settingsMenu: () -> NSMenu

  init(read: @escaping (@escaping (Scope?) -> Void) -> Void, settings settingsMenu: @escaping () -> NSMenu = { NSMenu() }) {
    self.read = read
    self.settingsMenu = settingsMenu
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

    // The reference's tint over the glass, then one rounded bar: icon tile and name, the
    // view switch in the middle, the scale menus and settings at the right.
    content.wantsLayer = true
    content.layer?.backgroundColor = CGColor(srgbRed: 0.05, green: 0.07, blue: 0.15, alpha: 0.25)
    let bar = Backdrop(), tile = Backdrop(), gear = Backdrop()
    bar.radius = 14
    tile.radius = 11
    tile.fill = NSColor(srgbRed: 0.45, green: 0.62, blue: 1, alpha: 0.16)
    gear.radius = 19.5
    gear.fill = NSColor.white.withAlphaComponent(0.09)
    let icon = NSImageView(image: NSImage(size: NSSize(width: 20, height: 18), flipped: false) { _ in
      NSColor.white.withAlphaComponent(0.9).setFill()
      for (i, h) in [9, 16, 11, 14, 7].enumerated() {  // a level meter's bars
        NSBezierPath(roundedRect: NSRect(x: CGFloat(i) * 4.2, y: 0, width: 2.4, height: CGFloat(h)), xRadius: 1.2, yRadius: 1.2).fill()
      }
      return true
    })
    let name = NSTextField(labelWithString: "Spectrum Analyzer")
    name.font = .systemFont(ofSize: 16)
    name.textColor = NSColor.white.withAlphaComponent(0.92)
    mode.setAccessibilityLabel("View")
    mode.changed = { [weak self] _ in self?.changeMode() }
    scale.addItems(withTitles: ["Log Frequency", "Linear Frequency"])
    scale.setAccessibilityLabel("Frequency scale")
    amplitude.addItems(withTitles: ["dB", "Linear"])
    amplitude.setAccessibilityLabel("Amplitude scale")
    span.addItems(withTitles: ["2 s", "5 s", "10 s"])
    span.selectItem(at: 1)
    span.setAccessibilityLabel("Time span")
    settings.isBordered = false
    settings.image = symbol(["gearshape"])
    settings.symbolConfiguration = .init(pointSize: 17, weight: .regular)
    settings.contentTintColor = NSColor.white.withAlphaComponent(0.9)
    settings.imagePosition = .imageOnly
    settings.toolTip = "Model"
    settings.setAccessibilityLabel("Settings")
    for (control, action) in [(scale, #selector(changeScale)), (amplitude, #selector(changeAmplitude)),
      (span, #selector(changeSpan)), (settings, #selector(openSettings))] as [(NSControl, Selector)] {
      control.target = self
      control.action = action
    }
    let trays = [scale, amplitude, span].map(tray)
    view.setAccessibilityLabel("Spectrum of the mix you hear")
    for item in [bar, tile, icon, name, mode, gear, settings, view] + trays as [NSView] {
      item.translatesAutoresizingMaskIntoConstraints = false
      content.addSubview(item)
    }
    // Sizes and places measured off the reference at this window's size.
    func size(_ item: NSView, _ width: CGFloat, _ height: CGFloat) -> [NSLayoutConstraint] {
      [item.widthAnchor.constraint(equalToConstant: width), item.heightAnchor.constraint(equalToConstant: height),
       item.centerYAnchor.constraint(equalTo: bar.centerYAnchor)]
    }
    NSLayoutConstraint.activate([
      bar.topAnchor.constraint(equalTo: content.topAnchor, constant: 28),
      bar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
      bar.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10),
      bar.heightAnchor.constraint(equalToConstant: 82),
      tile.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 11),
      icon.centerXAnchor.constraint(equalTo: tile.centerXAnchor),
      icon.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
      name.leadingAnchor.constraint(equalTo: tile.trailingAnchor, constant: 14),
      name.centerYAnchor.constraint(equalTo: bar.centerYAnchor, constant: -6),
      mode.centerXAnchor.constraint(equalTo: content.centerXAnchor),
      gear.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -13),
      settings.centerXAnchor.constraint(equalTo: gear.centerXAnchor),
      settings.centerYAnchor.constraint(equalTo: gear.centerYAnchor),
      trays[2].trailingAnchor.constraint(equalTo: gear.leadingAnchor, constant: -13),
      trays[1].trailingAnchor.constraint(equalTo: trays[2].leadingAnchor, constant: -14),
      trays[0].trailingAnchor.constraint(equalTo: trays[1].leadingAnchor, constant: -13),
      view.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 8),
      view.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
      view.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
      view.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
    ] + size(tile, 46, 46) + size(mode, 162, 37) + size(gear, 39, 39) + size(trays[0], 140, 37) + size(trays[1], 75, 37)
      + size(trays[2], 93, 37))
  }

  /// A borderless pull-down on a tray with one down chevron, as the reference's menus.
  private func tray(_ popup: NSPopUpButton) -> Backdrop {
    let tray = Backdrop(), chevron = NSImageView(image: symbol(["chevron.down"]))
    tray.fill = NSColor.white.withAlphaComponent(0.09)
    chevron.symbolConfiguration = .init(pointSize: 12, weight: .medium)
    chevron.contentTintColor = NSColor.white.withAlphaComponent(0.9)
    let titles = popup.itemTitles, chosen = popup.indexOfSelectedItem
    popup.pullsDown = true
    popup.isBordered = false
    (popup.cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
    popup.font = .systemFont(ofSize: 14)
    popup.removeAllItems()
    // A pull-down's first item is its title; menu items directly, as addItems(withTitles:) drops the duplicate.
    for title in [titles[chosen]] + titles { popup.menu?.addItem(withTitle: title, action: nil, keyEquivalent: "") }
    for item in [chevron, popup] as [NSView] {
      item.translatesAutoresizingMaskIntoConstraints = false
      tray.addSubview(item)
    }
    NSLayoutConstraint.activate([
      popup.leadingAnchor.constraint(equalTo: tray.leadingAnchor, constant: 8),
      popup.trailingAnchor.constraint(equalTo: tray.trailingAnchor),
      popup.centerYAnchor.constraint(equalTo: tray.centerYAnchor),
      chevron.centerXAnchor.constraint(equalTo: tray.trailingAnchor, constant: -19),
      chevron.centerYAnchor.constraint(equalTo: tray.centerYAnchor),
    ])
    return tray
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
    read { [weak self] scope in
      guard let self else { return }
      self.view.hint = scope == nil ? "Shows what Live Stems plays. Press M or S on a stem to start." : nil
      let silence = [Float](repeating: 0, count: SpectrumAnalyzer.size), log = self.view.logFrequency
      self.view.push(heard: self.analyzer.levels(scope?.mix ?? silence, log: log),
        original: self.analyzer.levels(scope?.original ?? silence, log: log))
    }
  }
  @objc private func changeMode() {
    view.threeD = mode.selected == 0
    amplitude.isEnabled = view.threeD  // 2D is MiniMeters' tilted dB view
  }
  /// The chosen choice of a pull-down, shown as its title.
  private func choice(_ popup: NSPopUpButton) -> Int {
    popup.setTitle(popup.titleOfSelectedItem ?? "")
    return popup.indexOfSelectedItem - 1
  }
  @objc private func changeAmplitude() { view.linearAmplitude = choice(amplitude) == 1 }
  @objc private func openSettings() {
    settingsMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: settings.bounds.maxY + 4), in: settings)
  }
  @objc private func changeScale() { view.logFrequency = choice(scale) == 0 }
  @objc private func changeSpan() { view.seconds = [2, 5, 10][choice(span)] }
}

/// Two choices on a tray, the chosen one on a blue pill, as the reference's 3D and 2D.
final class Choice: Backdrop {
  private(set) var selected = 0
  var changed: (Int) -> Void = { _ in }
  private var buttons = [NSButton]()
  init(_ titles: [String]) {
    super.init(frame: .zero)
    fill = NSColor.white.withAlphaComponent(0.07)
    buttons = titles.enumerated().map { index, title in
      let button = NSButton(title: title, target: nil, action: #selector(pick))
      button.setButtonType(.pushOnPushOff)
      button.isBordered = false
      button.font = .systemFont(ofSize: 14)
      button.tag = index
      button.target = self
      button.state = index == 0 ? .on : .off
      addSubview(button)
      return button
    }
  }
  required init?(coder: NSCoder) { fatalError() }
  override func layout() {
    super.layout()
    let width = bounds.width / CGFloat(buttons.count)
    for (i, button) in buttons.enumerated() { button.frame = NSRect(x: CGFloat(i) * width, y: 0, width: width, height: bounds.height) }
  }
  @objc private func pick(_ sender: NSButton) {
    selected = sender.tag
    for button in buttons { button.state = button.tag == selected ? .on : .off }
    needsDisplay = true
    changed(selected)
  }
  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    let width = bounds.width / CGFloat(buttons.count)
    NSColor(srgbRed: 0.36, green: 0.48, blue: 0.82, alpha: 0.62).setFill()
    NSBezierPath(roundedRect: NSRect(x: CGFloat(selected) * width, y: 0, width: width, height: bounds.height).insetBy(dx: 1.5, dy: 1.5),
      xRadius: 9, yRadius: 9).fill()
  }
}
