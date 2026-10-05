import AppKit

/// First symbol name this macOS has, so newer SF Symbols fall back on older systems.
func symbol(_ names: [String]) -> NSImage {
  names.lazy.compactMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }.first ?? NSImage()
}

/// A faint rounded tray that groups controls on the glass.
class Backdrop: NSView {
  override func draw(_ dirtyRect: NSRect) {
    let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10)
    NSColor.labelColor.withAlphaComponent(0.05).setFill()
    shape.fill()
    NSColor.labelColor.withAlphaComponent(0.09).setStroke()
    shape.stroke()
  }
}

/// One Logic-style channel strip: name plate, waveform, fader with dB scale,
/// level meter, and M / S.
final class ChannelStrip: Backdrop {
  static let size = NSSize(width: 80, height: 316)
  let name: String, color: NSColor, icon: NSImage
  let waveform: StemWaveform, meter: LevelMeter
  let fader = NSSlider(value: 1, minValue: 0, maxValue: 1, target: nil, action: nil)
  let mute = LogicToggle(letter: "M", lit: ControlsPanel.muteColor)
  let solo = LogicToggle(letter: "S", lit: ControlsPanel.soloColor)
  init(name: String, color: NSColor, icon: NSImage) {
    self.name = name
    self.color = color
    self.icon = icon
    waveform = StemWaveform(color: color)
    meter = LevelMeter(color: color)
    super.init(frame: NSRect(origin: .zero, size: Self.size))
    waveform.frame = NSRect(x: 4, y: 246, width: 72, height: 34)
    waveform.setAccessibilityLabel(name + " waveform")
    fader.cell = FaderCell()
    fader.minValue = 0
    fader.maxValue = 1
    fader.floatValue = 1
    fader.isVertical = true
    fader.isContinuous = true
    fader.frame = NSRect(x: 9, y: 44, width: 46, height: 196)
    fader.setAccessibilityLabel(name + " volume")
    meter.frame = NSRect(x: 61, y: 48, width: 10, height: 188)
    meter.setAccessibilityElement(false)
    for (button, x, title) in [(mute, 6, "Mute"), (solo, 42, "Solo")] {
      button.frame = NSRect(x: x, y: 10, width: 32, height: 26)
      button.setAccessibilityLabel(name + " " + title)
      button.toolTip = title
    }
    for view in [waveform, fader, meter, mute, solo] as [NSView] { addSubview(view) }
    setAccessibilityElement(true)
    setAccessibilityRole(.group)
    setAccessibilityLabel(name)
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    let plate = NSRect(x: 4, y: 286, width: 72, height: 26)
    let shape = NSBezierPath(roundedRect: plate, xRadius: 7, yRadius: 7)
    NSGradient(starting: color.blended(withFraction: 0.12, of: .white)!,
      ending: color.blended(withFraction: 0.18, of: .black)!)!.draw(in: shape, angle: -90)
    let text = NSAttributedString(string: name, attributes: [
      .font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.white,
    ])
    let glyph = icon.withSymbolConfiguration(
      .init(pointSize: 12, weight: .semibold).applying(.init(paletteColors: [.white])))!
    let textSize = text.size(), width = glyph.size.width + 4 + textSize.width
    let x = plate.midX - width / 2
    glyph.draw(in: NSRect(x: x, y: plate.midY - glyph.size.height / 2, width: glyph.size.width, height: glyph.size.height))
    text.draw(at: NSPoint(x: x + glyph.size.width + 4, y: plate.midY - textSize.height / 2))
  }
}

/// The controls panel content: source and Reset, status, four channel strips,
/// the All stems row, and Quit. Layout only; MenuController wires the actions.
final class ControlsPanel: NSView {
  static let size = NSSize(width: 360, height: 540)
  static let muteColor = NSColor.systemBlue
  static let soloColor = NSColor(srgbRed: 1, green: 0.82, blue: 0.2, alpha: 1)
  let sourcePicker = NSPopUpButton(frame: NSRect(x: 14, y: 478, width: 236, height: 28), pullsDown: false)
  let resetButton = NSButton(title: "Reset", target: nil, action: nil)
  let statusLabel = NSTextField(labelWithString: ""), outputLabel = NSTextField(labelWithString: "")
  let muteAllButton = LogicToggle(letter: "M", lit: muteColor)
  let clearSoloButton = LogicToggle(letter: "S", lit: soloColor)
  let quitButton = NSButton(title: "Quit Live Stems", target: nil, action: nil)
  let strips: [ChannelStrip]
  init() {
    let colors: [NSColor] = [.systemPink, .systemOrange, .systemPurple, .systemGreen]
    // SF Symbols has no drum; a transient waveform stands in. The stand mic is new in SF Symbols 8.
    let symbols = [["microphone.dynamic.on.stand", "microphone.fill"], ["waveform.path"],
      ["guitars.fill"], ["sparkles"]]
    strips = ["Vocals", "Drums", "Bass", "Other"].enumerated().map { index, name in
      ChannelStrip(name: name, color: colors[index], icon: symbol(symbols[index]))
    }
    super.init(frame: NSRect(origin: .zero, size: Self.size))
    sourcePicker.setAccessibilityLabel("Audio source")
    sourcePicker.controlSize = .large
    resetButton.frame = NSRect(x: 254, y: 478, width: 92, height: 28)
    quitButton.frame = NSRect(x: 14, y: 14, width: 332, height: 32)
    for (button, name) in [(resetButton, "arrow.counterclockwise"), (quitButton, "power")] {
      button.bezelStyle = .push
      button.controlSize = .large
      button.image = symbol([name])
      button.imagePosition = .imageLeading
    }
    statusLabel.frame = NSRect(x: 16, y: 452, width: 328, height: 18)
    statusLabel.font = .systemFont(ofSize: 13, weight: .semibold)
    statusLabel.lineBreakMode = .byTruncatingTail
    let headphones = NSImageView(image: symbol(["headphones"]))
    headphones.frame = NSRect(x: 15, y: 432, width: 16, height: 16)
    headphones.contentTintColor = .secondaryLabelColor
    outputLabel.frame = NSRect(x: 35, y: 432, width: 309, height: 16)
    outputLabel.font = .systemFont(ofSize: 11)
    outputLabel.textColor = .secondaryLabelColor
    outputLabel.lineBreakMode = .byTruncatingTail
    for (index, strip) in strips.enumerated() {
      strip.setFrameOrigin(NSPoint(x: 14 + CGFloat(index) * 84, y: 106))
    }
    let allRow = Backdrop(frame: NSRect(x: 14, y: 56, width: 332, height: 40))
    let allLabel = NSTextField(labelWithString: "All stems")
    allLabel.font = .systemFont(ofSize: 13, weight: .medium)
    allLabel.frame = NSRect(x: 12, y: 11, width: 120, height: 18)
    muteAllButton.frame = NSRect(x: 246, y: 7, width: 36, height: 26)
    muteAllButton.setAccessibilityLabel("Mute all")
    muteAllButton.toolTip = "Mute all stems"
    // Logic-style global solo: lit while any stem is soloed; a click clears them all.
    clearSoloButton.frame = NSRect(x: 288, y: 7, width: 36, height: 26)
    clearSoloButton.setAccessibilityLabel("Clear all solos")
    clearSoloButton.toolTip = "Clear all solos"
    for view in [allLabel, muteAllButton, clearSoloButton] { allRow.addSubview(view) }
    for view in [sourcePicker, resetButton, statusLabel, headphones, outputLabel, allRow, quitButton] + strips as [NSView] {
      addSubview(view)
    }
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}
