import AppKit

/// A dark recess behind waveforms and meters, lighter in light mode.
let insetColor = NSColor(name: nil) { appearance in
  NSColor.black.withAlphaComponent(appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? 0.28 : 0.08)
}

/// Logic Pro style M / S track button: a small square that lights when on.
final class LogicToggle: NSButton {
  private let litColor: NSColor
  init(letter: String, lit: NSColor) {
    litColor = lit
    super.init(frame: .zero)
    title = letter
    setButtonType(.pushOnPushOff)
    isBordered = false
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
  override func draw(_ dirtyRect: NSRect) {
    let on = state == .on
    let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 5, yRadius: 5)
    (on ? litColor : NSColor.labelColor.withAlphaComponent(0.08)).setFill()
    shape.fill()
    NSColor.labelColor.withAlphaComponent(on ? 0.25 : 0.12).setStroke()
    shape.stroke()
    // White on the blue mute, black on the yellow solo.
    let rgb = litColor.usingColorSpace(.sRGB)!
    let dark = 0.2126 * rgb.redComponent + 0.7152 * rgb.greenComponent + 0.0722 * rgb.blueComponent < 0.6
    let text = NSAttributedString(string: title, attributes: [
      .font: NSFont.systemFont(ofSize: 12, weight: .bold),
      .foregroundColor: on ? (dark ? NSColor.white : NSColor.black) : NSColor.secondaryLabelColor,
    ])
    let size = text.size()
    text.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2))
  }
}

/// Scrolling pre-fader peak history for one stem, drawn like a region waveform.
final class StemWaveform: NSView {
  private var peaks = [Float](repeating: 0, count: 96)
  private let color: NSColor
  var dimmed = false { didSet { needsDisplay = true } }
  init(color: NSColor) {
    self.color = color
    super.init(frame: .zero)
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
  func push(_ peak: Float) {
    peaks.removeFirst()
    peaks.append(peak)
    needsDisplay = true
  }
  override func draw(_ dirtyRect: NSRect) {
    insetColor.setFill()
    NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()
    color.withAlphaComponent(dimmed ? 0.3 : 1).setFill()
    let step = bounds.width / CGFloat(peaks.count)
    for (index, peak) in peaks.enumerated() {
      // -48 dB to 0 dB maps to empty to full height.
      let level = peak > 0 ? max(0, min(1, (20 * log10(peak) + 48) / 48)) : 0
      let height = max(1, CGFloat(level) * (bounds.height - 4))
      NSRect(x: CGFloat(index) * step, y: bounds.midY - height / 2,
        width: max(1, step - 0.5), height: height).fill()
    }
  }
}

/// Segmented vertical level meter, -48 dB to 0 dB, with a short fall-off.
final class LevelMeter: NSView {
  private var level: Float = 0
  private let color: NSColor
  init(color: NSColor) {
    self.color = color
    super.init(frame: .zero)
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
  func push(_ peak: Float) {
    let next = max(peak, level * 0.85)
    guard next != level else { return }
    level = next
    needsDisplay = true
  }
  override func draw(_ dirtyRect: NSRect) {
    insetColor.setFill()
    NSBezierPath(roundedRect: bounds, xRadius: 3, yRadius: 3).fill()
    let db = level > 0 ? 20 * log10(level) : -.infinity
    let segments = 24, area = bounds.insetBy(dx: 2, dy: 2)
    let pitch = area.height / CGFloat(segments)
    for index in 0..<segments {
      let lit = db > -48 + 48 * Float(index) / Float(segments)
      (lit ? color : NSColor.labelColor.withAlphaComponent(0.07)).setFill()
      NSBezierPath(roundedRect: NSRect(x: area.minX, y: area.minY + CGFloat(index) * pitch,
        width: area.width, height: pitch - 1.5), xRadius: 1, yRadius: 1).fill()
    }
  }
}

/// Logic-style fader: a groove, a dB scale, and a metal cap. The value stays
/// linear gain 0–1; the scale only marks where each dB value sits.
final class FaderCell: NSSliderCell {
  static let scaleWidth: CGFloat = 22
  private static let marks: [(String, Double)] = [("0", 0), ("-3", -3), ("-6", -6), ("-10", -10), ("-20", -20), ("-∞", -.infinity)]
  override var knobThickness: CGFloat { 26 }
  private var grooveX: CGFloat { (controlView?.bounds.maxX ?? 0) - 12 }
  // The cap and its shadow are larger than the knob rect AppKit repaints while
  // dragging, which left ghost caps behind. Repaint the whole fader instead.
  override func continueTracking(last lastPoint: NSPoint, current currentPoint: NSPoint, in controlView: NSView) -> Bool {
    defer { controlView.setNeedsDisplay(controlView.bounds) }
    return super.continueTracking(last: lastPoint, current: currentPoint, in: controlView)
  }
  override func drawBar(inside rect: NSRect, flipped: Bool) {
    let track = trackRect
    let groove = NSRect(x: grooveX - 2.5, y: track.minY + 4, width: 5, height: track.height - 8)
    insetColor.setFill()
    NSBezierPath(roundedRect: groove.insetBy(dx: -1, dy: -1), xRadius: 3.5, yRadius: 3.5).fill()
    NSColor.black.withAlphaComponent(0.55).setFill()
    NSBezierPath(roundedRect: groove, xRadius: 2.5, yRadius: 2.5).fill()
    let travel = track.height - knobThickness
    let font = NSFont.monospacedDigitSystemFont(ofSize: 8.5, weight: .medium)
    for (label, db) in Self.marks {
      let value = db.isFinite ? pow(10, db / 20) : 0
      let y = track.minY + knobThickness / 2 + CGFloat(flipped ? 1 - value : value) * travel
      NSColor.tertiaryLabelColor.setFill()
      NSRect(x: Self.scaleWidth - 4, y: y - 0.5, width: 4, height: 1).fill()
      let text = NSAttributedString(string: label, attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor])
      let size = text.size()
      text.draw(at: NSPoint(x: Self.scaleWidth - 6 - size.width, y: y - size.height / 2))
    }
  }
  override func drawKnob(_ knobRect: NSRect) {
    let cap = NSRect(x: grooveX - 11, y: knobRect.midY - 13, width: 22, height: 26)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
    shadow.shadowBlurRadius = 3
    shadow.shadowOffset = NSSize(width: 0, height: -1.5)
    shadow.set()
    let shape = NSBezierPath(roundedRect: cap, xRadius: 3, yRadius: 3)
    NSColor(white: 0.78, alpha: 1).setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(colors: [NSColor(white: 0.97, alpha: 1), NSColor(white: 0.80, alpha: 1), NSColor(white: 0.66, alpha: 1)])!
      .draw(in: shape, angle: controlView!.isFlipped ? 90 : -90)
    NSColor.black.withAlphaComponent(0.35).setStroke()
    shape.lineWidth = 0.5
    shape.stroke()
    NSColor.black.withAlphaComponent(0.6).setFill()
    NSRect(x: cap.minX + 2, y: cap.midY - 0.75, width: cap.width - 4, height: 1.5).fill()
  }
}
