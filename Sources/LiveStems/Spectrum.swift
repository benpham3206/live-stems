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
  var logFrequency = true { didSet { history.removeAll(); heard = []; original = []; trail = nil; needsDisplay = true } }
  var seconds = 5 { didSet { trim(); trail = nil; needsDisplay = true } }
  var hint: String? { didSet { needsDisplay = oldValue != hint || needsDisplay } }
  /// Tilted band levels of the mix, oldest first, for the spectrogram.
  private(set) var history = [[Float]]()
  /// Tilted and smoothed, for the curves: what you hear, and the original song.
  private(set) var heard = [Float](), original = [Float]()
  /// The 3D rows already drawn, in device pixels. Each new row shifts it one step back
  /// and fades it, then draws only itself in front: painter's order for free, one row per frame.
  private var trail: CGContext?, trailCarry = CGPoint.zero

  func push(heard newHeard: [Float], original newOriginal: [Float]) {
    let tilts = SpectrumAnalyzer.frequencies(log: logFrequency).map { Self.tilt * log2($0 / 1000) }
    let mix = zip(newHeard, tilts).map(+), song = zip(newOriginal, tilts).map(+)
    history.append(mix)
    trim()
    // Fast rise, slow fall, like MiniMeters' smoothing.
    func smooth(_ old: [Float], _ new: [Float]) -> [Float] {
      old.count == new.count ? zip(old, new).map { max($1, $0 * 0.75 + $1 * 0.25) } : new
    }
    heard = smooth(heard, mix)
    original = smooth(original, song)
    if threeD { advanceTrail(newHeard) } else { trail = nil }
    needsDisplay = true
  }
  override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    trail = nil
  }
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
    guard let context = NSGraphicsContext.current?.cgContext else { return }
    // 2D is MiniMeters' black; 3D sits on a deep navy tint so the glow keeps its contrast on any wallpaper.
    (threeD ? NSColor(srgbRed: 0.04, green: 0.05, blue: 0.11, alpha: 0.78) : .black).setFill()
    NSBezierPath(roundedRect: bounds, xRadius: 12, yRadius: 12).fill()
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

  /// Oblique axes: frequency runs down to the right, time recedes up to the right.
  private struct Box {
    let origin: CGPoint, along: CGVector, back: CGVector, up: CGVector
    init(_ size: CGSize) {
      origin = CGPoint(x: 0.09 * size.width, y: 0.24 * size.height)
      along = CGVector(dx: 0.66 * size.width, dy: -0.20 * size.height)
      back = CGVector(dx: 0.13 * size.width, dy: 0.32 * size.height)
      up = CGVector(dx: 0, dy: 0.44 * size.height)
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
    /// Maps (frequency, height) in 0-1 onto the front slice.
    var shear: CGAffineTransform { CGAffineTransform(a: along.dx, b: along.dy, c: up.dx, d: up.dy, tx: origin.x, ty: origin.y) }
  }
  var linearAmplitude = false { didSet { trail = nil; needsDisplay = true } }
  /// Height in the 3D box: 0 to -120 dB, or linear amplitude 0 to 1.
  private func height(_ db: Float) -> CGFloat {
    linearAmplitude ? CGFloat(min(1, pow(10, db / 20))) : CGFloat(max(0, min(1, (db + 120) / 120)))
  }
  /// Colour by frequency, as the reference: violet subs, orange and gold lows, pink and
  /// magenta mids, violet and blue highs. Quiet parts stay blue whatever their frequency.
  private static let hues: [(CGFloat, (CGFloat, CGFloat, CGFloat))] = [
    (0, (0.70, 0.25, 1.00)), (0.20, (1.00, 0.42, 0.18)), (0.33, (1.00, 0.68, 0.22)), (0.48, (1.00, 0.38, 0.45)),
    (0.60, (0.95, 0.28, 0.85)), (0.75, (0.58, 0.30, 1.00)), (1, (0.25, 0.38, 1.00)),
  ]
  private static func hue(_ x: CGFloat) -> (CGFloat, CGFloat, CGFloat) {
    let hi = hues.firstIndex { $0.0 >= x } ?? hues.count - 1, lo = max(0, hi - 1)
    let a = hues[lo], b = hues[hi], f = b.0 > a.0 ? (x - a.0) / (b.0 - a.0) : 0
    return (a.1.0 + (b.1.0 - a.1.0) * f, a.1.1 + (b.1.1 - a.1.1) * f, a.1.2 + (b.1.2 - a.1.2) * f)
  }
  private static let quiet: (CGFloat, CGFloat, CGFloat) = (0.16, 0.26, 0.95)
  /// Each band's hue, by where its frequency sits on the log axis even when the axis is linear.
  private var bandHues: [(CGFloat, CGFloat, CGFloat)] {
    SpectrumAnalyzer.frequencies(log: logFrequency).map { Self.hue(SpectrumAnalyzer.position($0, log: true)) }
  }
  private lazy var sheet = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
    colors: Self.hues.map { CGColor(srgbRed: $0.1.0, green: $0.1.1, blue: $0.1.2, alpha: 1) } as CFArray,
    locations: Self.hues.map(\.0))!

  private func advanceTrail(_ levels: [Float]) {
    let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
    let width = Int(bounds.width * scale), height = Int(bounds.height * scale)
    guard width > 0, height > 0 else { return }
    let box = Box(bounds.size)
    let previous = trail?.makeImage()
    if trail == nil || trail!.width != width || trail!.height != height {
      // Opaque black so light adds up across rows; drawn with plus-lighter, black adds nothing.
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
      context.setAlpha(pow(0.35, 1 / capacity))  // dimmed to 35% by the back of the box
      context.draw(previous, in: all.offsetBy(dx: shift.x, dy: shift.y))
      // and cooled: red and green fade faster than blue, so older rows recede into blue.
      context.setBlendMode(.multiply)
      context.setAlpha(1)
      context.setFillColor(CGColor(srgbRed: pow(0.25, 1 / capacity), green: pow(0.4, 1 / capacity), blue: 1, alpha: 1))
      context.fill(all)
      context.restoreGState()
    }
    context.saveGState()
    context.scaleBy(x: scale, y: scale)
    drawGlowRow(levels, in: context, box: box)
    context.restoreGState()
  }

  /// One slice in front: a veil that dims the rows behind it, a faint sheet in the
  /// frequency colours, then glowing lines, brighter and warmer where louder.
  private func drawGlowRow(_ levels: [Float], in context: CGContext, box: Box) {
    let n = levels.count
    guard n > 1 else { return }
    let v = levels.map(height), hueAngles = bandHues.map { NSColor(srgbRed: $0.0, green: $0.1, blue: $0.2, alpha: 1).hueComponent }
    let points = (0..<n).map { box.point(CGFloat($0) / CGFloat(n - 1), 0, v[$0]) }
    let area = CGMutablePath()
    area.addLines(between: points + [box.point(1, 0, 0), box.origin])
    area.closeSubpath()
    context.addPath(area)
    context.setFillColor(CGColor(gray: 0, alpha: 0.8))
    context.fillPath()
    context.saveGState()
    context.addPath(area)
    context.clip()
    context.setBlendMode(.plusLighter)
    context.setAlpha(0.09)
    context.concatenate(box.shear)
    context.drawLinearGradient(sheet, start: .zero, end: CGPoint(x: 1, y: 0), options: [])
    context.restoreGState()
    let colors = (1..<n).map { i -> CGColor in
      let level = max(v[i - 1], v[i]), warm = max(0, min(1, (level - 0.3) / 0.35))
      let bright = 0.18 + 0.82 * max(0, min(1, (level - 0.3) / 0.5))
      // Blend around the hue wheel, blue through violet and magenta to the band's colour,
      // never through grey as a straight RGB mix of blue and orange would.
      let target = hueAngles[i], quiet: CGFloat = 0.63
      let angle = quiet + ((target < quiet ? target + 1 : target) - quiet) * warm
      let saturation = 0.9 - max(0, level - 0.82) * 2.5  // the tallest peaks burn toward white
      return NSColor(hue: angle.truncatingRemainder(dividingBy: 1), saturation: max(0.35, saturation), brightness: bright, alpha: 1).cgColor
    }
    context.saveGState()
    context.setBlendMode(.plusLighter)
    context.setLineCap(.round)
    // A soft halo adds light; the thin core line keeps its true colour, so overlapping rows never wash to white.
    for (width, alpha) in [(4.5, 0.05), (2.0, 0.10), (0.8, 0.9)] as [(CGFloat, CGFloat)] {
      context.setBlendMode(width < 1 ? .normal : .plusLighter)
      context.setLineWidth(width)
      context.setAlpha(alpha)
      for i in 1..<n {
        context.setStrokeColor(colors[i - 1])
        context.strokeLineSegments(between: [points[i - 1], points[i]])
      }
    }
    context.restoreGState()
  }

  private static let axisText = NSColor.white.withAlphaComponent(0.78)
  private func text(_ string: String, at point: CGPoint, size: CGFloat = 12, align: CGFloat = 0.5, angle: CGFloat = 0) {
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
    let box = Box(bounds.size)
    // A dim blue floor, brighter at the front, and a faint back wall.
    for (corners, from, to) in [
      ([box.point(0, 0, 0), box.point(1, 0, 0), box.point(1, 1, 0), box.point(0, 1, 0)], box.point(0, 0, 0), box.point(0, 1, 0)),
      ([box.point(0, 1, 0), box.point(1, 1, 0), box.point(1, 1, 1), box.point(0, 1, 1)], box.point(0, 1, 0), box.point(0, 1, 1)),
    ] {
      context.saveGState()
      context.addLines(between: corners)
      context.closePath()
      context.clip()
      let glow = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [
        CGColor(srgbRed: 0.10, green: 0.18, blue: 0.60, alpha: 0.24), CGColor(srgbRed: 0.05, green: 0.08, blue: 0.30, alpha: 0.08),
      ] as CFArray, locations: [0, 1])!
      context.drawLinearGradient(glow, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
      context.restoreGState()
    }
    context.setLineWidth(0.75)
    context.setStrokeColor(CGColor(srgbRed: 0.55, green: 0.65, blue: 1, alpha: 0.13))
    let ticks: [(Float, String)] = [(20, "20"), (50, "50"), (100, "100"), (200, "200"), (500, "500"), (1000, "1k"), (2000, "2k"),
      (5000, "5k"), (10000, "10k"), (20000, "20k")]
    let levels: [(Float, String)] = linearAmplitude
      ? stride(from: 1.0, through: 0, by: -0.2).map { (20 * log10(max(Float($0), 1e-7)), String(format: "%.1f", $0)) }
      : stride(from: 0, through: -120, by: -20).map { (Float($0), "\($0)") }
    for (f, _) in ticks where f >= 20 {
      let x = SpectrumAnalyzer.position(f, log: logFrequency)
      context.strokeLineSegments(between: [box.point(x, 0, 0), box.point(x, 1, 0), box.point(x, 1, 0), box.point(x, 1, 1)])
    }
    for (db, _) in levels {
      let v = height(db)
      context.strokeLineSegments(between: [box.point(0, 0, v), box.point(0, 1, v), box.point(0, 1, v), box.point(1, 1, v)])
    }
    for step in 0...(seconds * 4) {  // floor, every quarter second
      let t = CGFloat(step) / CGFloat(seconds * 4)
      context.strokeLineSegments(between: [box.point(0, t, 0), box.point(1, t, 0)])
    }
    if let image = trail?.makeImage() {
      context.saveGState()
      context.setBlendMode(.plusLighter)
      context.draw(image, in: bounds)
      context.restoreGState()
    }
    // Axes, ticks and labels.
    context.setLineWidth(1)
    context.setStrokeColor(CGColor(srgbRed: 0.75, green: 0.82, blue: 1, alpha: 0.55))
    let top = box.point(0, 0, 1.06)
    context.strokeLineSegments(between: [box.point(0, 0, 0), top, box.point(0, 0, 0), box.point(1, 0, 0), box.point(1, 0, 0), box.point(1, 1, 0)])
    context.beginPath()
    context.addLines(between: [top + CGVector(dx: -3.5, dy: -7), top, top + CGVector(dx: 3.5, dy: -7)])
    context.strokePath()
    let slant = atan2(box.along.dy, box.along.dx)
    for (db, label) in levels {
      let p = box.point(0, 0, height(db))
      context.strokeLineSegments(between: [p, p - CGVector(dx: 5, dy: 0)])
      text(label, at: p - CGVector(dx: 14, dy: 0), align: 1)
    }
    let normal = CGVector(dx: sin(slant) * 22, dy: -cos(slant) * 22)  // below the frequency edge
    for (f, label) in ticks {
      let p = box.point(SpectrumAnalyzer.position(f, log: logFrequency), 0, 0)
      context.strokeLineSegments(between: [p, p + CGVector(dx: normal.dx * 0.25, dy: normal.dy * 0.25)])
      text(label, at: p + normal, size: 13, angle: slant)
    }
    for s in 0...seconds where seconds <= 5 || s % 2 == 0 {
      let p = box.point(1, CGFloat(s) / CGFloat(seconds), 0)
      context.strokeLineSegments(between: [p, p + CGVector(dx: 6, dy: 0)])
      text("\(s)", at: p + CGVector(dx: 16, dy: 0), size: 13, align: 0)
    }
    text(linearAmplitude ? "Amplitude" : "Amplitude (dB)", at: top + CGVector(dx: -70, dy: 34), size: 13.5, align: 0)
    text("Frequency (Hz)", at: box.point(0.4, 0, 0) + CGVector(dx: normal.dx * 2.6, dy: normal.dy * 2.6), size: 15, angle: slant)
    text("Time (s)", at: box.point(1, 0.55, 0) + CGVector(dx: 60, dy: 0), size: 15, align: 0)
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
  let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 760),
    styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
  let view = SpectrumView()
  private let analyzer = SpectrumAnalyzer()
  private var timer: Timer?
  /// Supplies the newest samples as heard now, or nil when nothing plays through Live Stems.
  private let read: (@escaping (Scope?) -> Void) -> Void
  private let mode = NSSegmentedControl(labels: ["3D", "2D"], trackingMode: .selectOne, target: nil, action: nil)
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

    // Icon tile and name, the view switch in the middle, the scale menus and settings at the right.
    let tile = Backdrop(frame: NSRect(x: 0, y: 0, width: 46, height: 46))
    let icon = NSImageView(image: symbol(["chart.bar.fill", "chart.bar.xaxis"]))
    icon.symbolConfiguration = .init(pointSize: 18, weight: .semibold)
    icon.contentTintColor = .labelColor
    icon.frame = tile.bounds
    tile.addSubview(icon)
    let name = NSTextField(labelWithString: "Spectrum Analyzer")
    name.font = .systemFont(ofSize: 16)
    mode.selectedSegment = 0
    mode.segmentStyle = .rounded
    mode.setWidth(84, forSegment: 0)
    mode.setWidth(84, forSegment: 1)
    mode.setAccessibilityLabel("View")
    scale.addItems(withTitles: ["Log Frequency", "Linear Frequency"])
    scale.setAccessibilityLabel("Frequency scale")
    amplitude.addItems(withTitles: ["dB", "Linear"])
    amplitude.setAccessibilityLabel("Amplitude scale")
    span.addItems(withTitles: ["2 s", "5 s", "10 s"])
    span.selectItem(at: 1)
    span.setAccessibilityLabel("Time span")
    settings.bezelStyle = .circular
    settings.image = symbol(["gearshape"])
    settings.imagePosition = .imageOnly
    settings.toolTip = "Model"
    settings.setAccessibilityLabel("Settings")
    for (control, action) in [(mode, #selector(changeMode)), (scale, #selector(changeScale)), (amplitude, #selector(changeAmplitude)),
      (span, #selector(changeSpan)), (settings, #selector(openSettings))] as [(NSControl, Selector)] {
      control.target = self
      control.action = action
      control.controlSize = .large
      (control as? NSPopUpButton)?.isBordered = true
    }
    for popup in [scale, amplitude, span] { downChevron(popup) }
    mode.selectedSegmentBezelColor = .controlAccentColor
    let toolbar = NSStackView()
    toolbar.spacing = 12
    toolbar.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
    let bar = Backdrop()
    for item in [tile, name] as [NSView] { toolbar.addView(item, in: .leading) }
    toolbar.addView(mode, in: .center)
    for item in [scale, amplitude, span, settings] as [NSView] { toolbar.addView(item, in: .trailing) }
    tile.widthAnchor.constraint(equalToConstant: 46).isActive = true
    tile.heightAnchor.constraint(equalToConstant: 46).isActive = true
    view.setAccessibilityLabel("Spectrum of the mix you hear")
    for item in [bar, toolbar, view] as [NSView] {
      item.translatesAutoresizingMaskIntoConstraints = false
      content.addSubview(item)
    }
    NSLayoutConstraint.activate([
      toolbar.topAnchor.constraint(equalTo: content.topAnchor, constant: 32),
      toolbar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
      toolbar.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
      bar.topAnchor.constraint(equalTo: toolbar.topAnchor),
      bar.bottomAnchor.constraint(equalTo: toolbar.bottomAnchor),
      bar.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor),
      bar.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor),
      view.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 10),
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
    read { [weak self] scope in
      guard let self else { return }
      self.view.hint = scope == nil ? "Shows what Live Stems plays. Press M or S on a stem to start." : nil
      let silence = [Float](repeating: 0, count: SpectrumAnalyzer.size), log = self.view.logFrequency
      self.view.push(heard: self.analyzer.levels(scope?.mix ?? silence, log: log),
        original: self.analyzer.levels(scope?.original ?? silence, log: log))
    }
  }
  @objc private func changeMode() {
    view.threeD = mode.selectedSegment == 0
    amplitude.isEnabled = view.threeD  // 2D is MiniMeters' tilted dB view
  }
  /// A pull-down shows one down chevron, like the reference; its first item is the title.
  private func downChevron(_ popup: NSPopUpButton) {
    let titles = popup.itemTitles, chosen = popup.indexOfSelectedItem
    popup.pullsDown = true
    popup.removeAllItems()
    // Menu items directly: addItems(withTitles:) drops the duplicate title.
    for title in [titles[chosen]] + titles { popup.menu?.addItem(withTitle: title, action: nil, keyEquivalent: "") }
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
