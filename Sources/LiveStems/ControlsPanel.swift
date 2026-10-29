import AppKit

/// First symbol name this macOS has, so newer SF Symbols fall back on older systems.
func symbol(_ names: [String]) -> NSImage {
  names.lazy.compactMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }.first ?? NSImage()
}

/// A faint rounded tray that groups controls on the glass.
class Backdrop: NSView {
  var radius: CGFloat = 10, fill = NSColor.labelColor.withAlphaComponent(0.05)
  override func draw(_ dirtyRect: NSRect) {
    let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
    fill.setFill()
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
  let fader = Fader(value: 1, minValue: 0, maxValue: 1, target: nil, action: nil)
  let mute = LogicToggle(letter: "M", lit: ControlsPanel.muteColor)
  let solo = LogicToggle(letter: "S", lit: ControlsPanel.soloColor)
  /// A silent strip (muted, or not soloed while another is) fades; a soloed one glows in its color.
  private var silent = false, soloed = false
  func show(silent: Bool, soloed: Bool) {
    self.silent = silent
    self.soloed = soloed
    waveform.dimmed = silent
    for view in [fader, meter] as [NSView] { view.alphaValue = silent ? 0.35 : 1 }
    needsDisplay = true
  }
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
    if soloed {
      let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 10, yRadius: 10)
      color.withAlphaComponent(0.14).setFill()
      ring.fill()
      color.setStroke()
      ring.lineWidth = 2
      ring.stroke()
    }
    NSGraphicsContext.current?.cgContext.setAlpha(silent ? 0.35 : 1)
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

/// The controls panel content: source and Reset, status, four or six channel strips,
/// the All stems row, seek and pitch controls, and Quit. Layout only; MenuController wires the actions.
final class ControlsPanel: NSView {
  func setSourceCount(_ count: Int) {
    setFrameSize(NSSize(width: count == 6 ? 528 : 360, height: 612))
    for (index, strip) in strips.enumerated() { strip.isHidden = index >= count }
    let right = frame.width - 14, width = right - 14
    sourcePicker.frame.size.width = width - 200
    spectrumButton.frame.origin.x = right - 192
    resetButton.frame.origin.x = right - 92
    statusLabel.frame.size.width = width
    outputLabel.frame.size.width = width - 21
    allRow.frame.size.width = width
    muteAllButton.frame.origin.x = width - 86
    clearSoloButton.frame.origin.x = width - 44
    let seekWidth = (width - 124) / 2
    rewind.frame.size.width = seekWidth
    seekStep.frame.origin.x = 14 + seekWidth + 8
    forward.frame.origin.x = right - seekWidth
    forward.frame.size.width = seekWidth
    pitchPicker.frame.size.width = width - 128
    pitchReset.frame.origin.x = right - 80
    quitButton.frame.size.width = width - 168
    modelPicker.frame = NSRect(x: right - 160, y: 14, width: 160, height: 32)
  }
  static let size = NSSize(width: 360, height: 612)
  static let muteColor = NSColor.systemBlue
  static let soloColor = NSColor(srgbRed: 1, green: 0.82, blue: 0.2, alpha: 1)
  let sourcePicker = NSPopUpButton(frame: NSRect(x: 14, y: 550, width: 196, height: 28), pullsDown: true)
  let allRow = Backdrop()
  let modelPicker = NSPopUpButton(frame: .zero, pullsDown: true)
  let spectrumButton = NSButton(frame: NSRect(x: 214, y: 550, width: 36, height: 28))
  let resetButton = NSButton(title: "Reset", target: nil, action: nil)
  let statusLabel = NSTextField(labelWithString: ""), outputLabel = NSTextField(labelWithString: "")
  let muteAllButton = LogicToggle(letter: "M", lit: muteColor)
  let clearSoloButton = LogicToggle(letter: "S", lit: soloColor)
  let quitButton = NSButton(title: "Quit Live Stems", target: nil, action: nil)
  let pitchPicker = NSPopUpButton(), pitchReset = NSButton(title: "Zero", target: nil, action: nil)
  let seekStep = NSPopUpButton(), rewind = NSButton(title: "−10 s", target: nil, action: nil)
  let forward = NSButton(title: "+10 s", target: nil, action: nil)
  let transportLabel = NSTextField(labelWithString: "Spotify seeking")
  let strips: [ChannelStrip]
  init() {
    let colors: [NSColor] = [.systemPink, .systemOrange, .systemPurple, .systemGreen]
    // SF Symbols has no drum; a transient waveform stands in. The stand mic is new in SF Symbols 8.
    let symbols = [["microphone.dynamic.on.stand", "microphone.fill", "mic.fill"], ["waveform.path"],
      ["guitars.fill"], ["sparkles"], ["guitars.fill"], ["pianokeys"]]
    strips = ["Vocals", "Drums", "Bass", "Other", "Guitar", "Piano"].enumerated().map { index, name in
      ChannelStrip(name: name, color: colors[index % colors.count], icon: symbol(symbols[index]))
    }
    super.init(frame: NSRect(origin: .zero, size: Self.size))
    sourcePicker.setAccessibilityLabel("Audio source")
    sourcePicker.controlSize = .large
    resetButton.frame = NSRect(x: 254, y: 550, width: 92, height: 28)
    quitButton.frame = NSRect(x: 14, y: 14, width: 332, height: 32)
    for (button, name) in [(resetButton, "arrow.counterclockwise"), (quitButton, "power")] {
      button.bezelStyle = .push
      button.controlSize = .large
      button.image = symbol([name])
      button.imagePosition = .imageLeading
    }
    spectrumButton.bezelStyle = .push
    spectrumButton.controlSize = .large
    spectrumButton.image = symbol(["chart.bar.xaxis", "waveform"]).withSymbolConfiguration(.init(scale: .large))
    if #available(macOS 26.0, *) { spectrumButton.borderShape = .capsule }
    spectrumButton.title = "Spectrum"
    spectrumButton.imagePosition = .imageLeading
    spectrumButton.toolTip = "Spectrum Analyzer (⌘`)"
    spectrumButton.setAccessibilityLabel("Spectrum Analyzer")
    statusLabel.frame = NSRect(x: 16, y: 524, width: 328, height: 18)
    statusLabel.font = .systemFont(ofSize: 13, weight: .semibold)
    statusLabel.lineBreakMode = .byTruncatingTail
    let headphones = NSImageView(image: symbol(["headphones"]))
    headphones.frame = NSRect(x: 15, y: 504, width: 16, height: 16)
    headphones.contentTintColor = .secondaryLabelColor
    outputLabel.frame = NSRect(x: 35, y: 504, width: 309, height: 16)
    outputLabel.font = .systemFont(ofSize: 11)
    outputLabel.textColor = .secondaryLabelColor
    outputLabel.lineBreakMode = .byTruncatingTail
    for (index, strip) in strips.enumerated() {
      strip.setFrameOrigin(NSPoint(x: 14 + CGFloat(index) * 84, y: 178))
    }
    allRow.frame = NSRect(x: 14, y: 128, width: 332, height: 40)
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
    for view in [sourcePicker, spectrumButton, resetButton, statusLabel, headphones, outputLabel, allRow, quitButton, modelPicker] + strips as [NSView] {
      addSubview(view)
    }
    let keyLabel = NSTextField(labelWithString: "Key")
    keyLabel.frame = NSRect(x: 16, y: 57, width: 34, height: 18)
    pitchPicker.frame = NSRect(x: 52, y: 50, width: 204, height: 30)
    for value in -12...12 {
      pitchPicker.addItem(withTitle: value == 0 ? "Original pitch" : String(format: "%+d semitone%@", value, abs(value) == 1 ? "" : "s"))
      pitchPicker.lastItem?.tag = value
    }
    pitchPicker.selectItem(withTag: 0)
    pitchPicker.setAccessibilityLabel("Transpose in semitones")
    pitchPicker.toolTip = "Change musical key without changing playback speed"
    pitchReset.frame = NSRect(x: 266, y: 50, width: 80, height: 30)
    pitchReset.setAccessibilityLabel("Reset pitch")
    seekStep.frame = NSRect(x: 126, y: 88, width: 108, height: 30)
    for seconds in [5, 10, 15, 30] {
      seekStep.addItem(withTitle: "\(seconds) seconds")
      seekStep.lastItem?.tag = seconds
    }
    seekStep.selectItem(withTag: 10)
    seekStep.setAccessibilityLabel("Seek interval")
    rewind.frame = NSRect(x: 14, y: 88, width: 104, height: 30)
    forward.frame = NSRect(x: 242, y: 88, width: 104, height: 30)
    modelPicker.setAccessibilityLabel("Separation model")
    modelPicker.toolTip = "Choose the stem separation model"
    transportLabel.isHidden = true
    transportLabel.frame = NSRect(x: 16, y: 499, width: 328, height: 17)
    transportLabel.font = .systemFont(ofSize: 11)
    transportLabel.textColor = .secondaryLabelColor
    transportLabel.lineBreakMode = .byTruncatingTail
    for view in [keyLabel, pitchPicker, pitchReset, seekStep, rewind, forward, transportLabel] { addSubview(view) }
    spectrumButton.frame.size.width = 96
    setSourceCount(4)
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}
