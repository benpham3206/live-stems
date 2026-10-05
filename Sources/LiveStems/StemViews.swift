import AppKit

/// Logic Pro style M / S track button: a small square that lights when on.
final class LogicToggle: NSButton {
  private let litColor: NSColor
  init(letter: String, lit: NSColor, target: AnyObject?, action: Selector) {
    litColor = lit
    super.init(frame: .zero)
    title = letter
    setButtonType(.pushOnPushOff)
    isBordered = false
    self.target = target
    self.action = action
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
  override func draw(_ dirtyRect: NSRect) {
    let on = state == .on
    (on ? litColor : NSColor.quaternaryLabelColor).setFill()
    NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 3, yRadius: 3).fill()
    let text = NSAttributedString(string: title, attributes: [
      .font: NSFont.systemFont(ofSize: 11, weight: .bold),
      .foregroundColor: on ? NSColor.black : NSColor.secondaryLabelColor,
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
    NSColor.quaternaryLabelColor.withAlphaComponent(0.25).setFill()
    NSBezierPath(roundedRect: bounds, xRadius: 3, yRadius: 3).fill()
    color.withAlphaComponent(dimmed ? 0.3 : 1).setFill()
    let step = bounds.width / CGFloat(peaks.count)
    for (index, peak) in peaks.enumerated() {
      // -48 dB to 0 dB maps to empty to full height.
      let level = peak > 0 ? max(0, min(1, (20 * log10(peak) + 48) / 48)) : 0
      let height = max(1, CGFloat(level) * (bounds.height - 2))
      NSRect(x: CGFloat(index) * step, y: bounds.midY - height / 2,
        width: max(1, step - 0.5), height: height).fill()
    }
  }
}
