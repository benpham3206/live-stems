import AppKit
import OSLog

final class MenuController: NSObject, NSWindowDelegate {
  private var item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
  private let session = SessionController()
  private var relaying = false
  private let activatesOnStatusClick: Bool
  private let terminate: () -> Void
  private let window = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 330, height: 426),
    styleMask: [.titled, .closable], backing: .buffered,
    defer: false)
  private let windowLog = Logger(subsystem: "com.benpham.livestems", category: "Windowing")
  private let statusLabel = NSTextField(labelWithString: "Live Spotify · original"),
    outputLabel = NSTextField(labelWithString: ""),
    startButton = NSButton(title: "Reset", target: nil, action: nil)
  private var active = false, panelRequested = true, controls = StemControls()
  private var muteButtons: [NSButton] = [], soloButtons: [NSButton] = [], sliders: [NSSlider] = []
  private var waveforms: [StemWaveform] = []
  private var muteAllButton: NSButton!, clearSoloButton: NSButton!
  private var meterTimer: Timer?
  private static let muteColor = NSColor(srgbRed: 0.29, green: 0.62, blue: 1, alpha: 1)
  private static let soloColor = NSColor(srgbRed: 1, green: 0.82, blue: 0.2, alpha: 1)
  override convenience init() {
    self.init(activateOnStatusClick: true)
  }
  private let startOverride: (() -> Void)?
  /// `start` replaces the session start; the menu E2E counts starts without capturing audio.
  init(activateOnStatusClick: Bool, terminate: @escaping () -> Void = { NSApp.terminate(nil) },
    start: (() -> Void)? = nil) {
    self.activatesOnStatusClick = activateOnStatusClick
    self.terminate = terminate
    self.startOverride = start
    super.init()
    configureStatusItem()
    window.title = "Live Stems"
    window.isReleasedWhenClosed = false
    window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    window.delegate = self
    window.level = .floating
    let content = NSView(frame: NSRect(x: 0, y: 0, width: 330, height: 426))
    window.contentView = content
    statusLabel.frame = NSRect(x: 16, y: 393, width: 298, height: 20)
    content.addSubview(statusLabel)
    outputLabel.frame = NSRect(x: 16, y: 371, width: 298, height: 18)
    outputLabel.font = .systemFont(ofSize: 11)
    content.addSubview(outputLabel)
    startButton.frame = NSRect(x: 12, y: 333, width: 306, height: 30)
    startButton.target = self
    startButton.action = #selector(resetButton)
    startButton.bezelStyle = .rounded
    content.addSubview(startButton)
    let stemColors: [NSColor] = [.systemPink, .systemOrange, .systemPurple, .systemGreen]
    for (index, name) in ["Vocals", "Drums", "Bass", "Other"].enumerated() {
      let row = NSView(frame: NSRect(x: 0, y: 269 - index * 64, width: 330, height: 64))
      let label = NSTextField(labelWithString: name)
      label.frame = NSRect(x: 16, y: 38, width: 64, height: 20)
      row.addSubview(label)
      let waveform = StemWaveform(color: stemColors[index])
      waveform.frame = NSRect(x: 84, y: 36, width: 170, height: 22)
      waveform.setAccessibilityLabel(name + " waveform")
      row.addSubview(waveform)
      waveforms.append(waveform)
      let slider = NSSlider(
        value: 1, minValue: 0, maxValue: 1, target: self, action: #selector(slide(_:)))
      slider.tag = index
      slider.isContinuous = true
      slider.frame = NSRect(x: 16, y: 9, width: 298, height: 22)
      slider.setAccessibilityLabel(name + " volume")
      row.addSubview(slider)
      sliders.append(slider)
      for (offset, title) in ["Mute", "Solo"].enumerated() {
        let button = LogicToggle(
          letter: String(title.prefix(1)), lit: offset == 0 ? Self.muteColor : Self.soloColor,
          target: self, action: #selector(check(_:)))
        button.tag = index + offset * 4
        button.frame = NSRect(x: 262 + offset * 28, y: 36, width: 24, height: 22)
        button.setAccessibilityLabel(name + " " + title)
        button.toolTip = title
        row.addSubview(button)
        if offset == 0 { muteButtons.append(button) } else { soloButtons.append(button) }
      }
      content.addSubview(row)
    }
    let allLabel = NSTextField(labelWithString: "All stems")
    allLabel.frame = NSRect(x: 16, y: 51, width: 100, height: 20)
    content.addSubview(allLabel)
    muteAllButton = LogicToggle(
      letter: "M", lit: Self.muteColor, target: self, action: #selector(muteAll(_:)))
    muteAllButton.frame = NSRect(x: 262, y: 50, width: 24, height: 22)
    muteAllButton.setAccessibilityLabel("Mute all")
    muteAllButton.toolTip = "Mute all stems"
    content.addSubview(muteAllButton)
    // Logic-style global solo: lit while any stem is soloed; a click clears them all.
    clearSoloButton = LogicToggle(
      letter: "S", lit: Self.soloColor, target: self, action: #selector(clearSolos))
    clearSoloButton.frame = NSRect(x: 290, y: 50, width: 24, height: 22)
    clearSoloButton.setAccessibilityLabel("Clear all solos")
    clearSoloButton.toolTip = "Clear all solos"
    content.addSubview(clearSoloButton)
    let quit = NSButton(title: "Quit Live Stems", target: self, action: #selector(quitApp))
    quit.frame = NSRect(x: 12, y: 8, width: 306, height: 30)
    quit.bezelStyle = .rounded
    content.addSubview(quit)
    outputLabel.stringValue = "Output: " + outputName(defaultOutput())
    session.onReady = { [weak self] in
      guard let self else { return }
      guard self.panelRequested else {
        self.windowLog.info("Windowing readiness suppressed after user close")
        return
      }
      self.presentWindow(reason: "readiness", userInitiated: false)
    }
    session.onStatus = { [weak self] text, output, enabled, stems in
      self?.applyStatus(text: text, output: output, enabled: enabled, stems: stems)
    }
    // 30 Hz meter pull; it reads nothing while the controls are hidden.
    meterTimer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
      guard let self, self.window.isVisible else { return }
      self.session.takeMeters { peaks in
        for (waveform, peak) in zip(self.waveforms, peaks) { waveform.push(peak) }
      }
    }
    RunLoop.main.add(meterTimer!, forMode: .common)
    // The first launch shows the controls without making the app frontmost.
    presentWindow(reason: "launch", userInitiated: false)
  }
  var e2eStatusButton: NSStatusBarButton? { item.button }
  var e2eWindow: NSWindow? { window }
  func e2eApplyStatusForTest(enabled: Bool) {
    applyStatus(text: "E2E", output: "E2E", enabled: enabled, stems: true)
  }
  func e2eNotifyReadyForTest() { session.onReady?() }
  private func applyStatus(text: String, output: String, enabled: Bool, stems: Bool) {
    active = enabled
    statusLabel.stringValue = text
    statusLabel.toolTip = text
    outputLabel.stringValue = "Output: " + output
    item.button?.title = "Stems"
  }
  private func positionWindow() {
    guard let screen = item.button?.window?.screen ?? NSScreen.main else { return }
    let bounds = screen.visibleFrame
    window.setFrameTopLeftPoint(NSPoint(x: bounds.maxX - window.frame.width - 12, y: bounds.maxY - 8))
  }
  private func presentWindow(reason: String, userInitiated: Bool) {
    guard !relaying else { return }
    positionWindow()
    let shouldActivate = userInitiated && activatesOnStatusClick
    if shouldActivate {
      NSApp.activate(ignoringOtherApps: true)
      window.makeKeyAndOrderFront(nil)
    } else {
      window.orderFront(nil)
    }
    windowLog.info(
      "Windowing show reason=\(reason, privacy: .public) userInitiated=\(userInitiated, privacy: .public) activate=\(shouldActivate, privacy: .public) visible=\(self.window.isVisible, privacy: .public) appActive=\(NSApp.isActive, privacy: .public)"
    )
  }
  @objc private func showPanel() {
    panelRequested = true
    presentWindow(reason: "status-item", userInitiated: true)
  }
  func windowWillClose(_ notification: Notification) {
    panelRequested = false
    windowLog.info(
      "Windowing close event=windowWillClose visible=\(self.window.isVisible, privacy: .public) appActive=\(NSApp.isActive, privacy: .public)"
    )
  }
  /// Neutral controls and a live stem splitter again, whatever state it was in.
  @objc private func resetButton() {
    resetControls()
    session.restoreStems()
  }
  /// Full volume, no mute or solo: Original, so the model sleeps.
  private func resetControls() {
    controls = StemControls()
    for slider in sliders { slider.floatValue = 1 }
    for button in muteButtons + soloButtons { button.state = .off }
    applyControls()
  }
  @objc private func slide(_ sender: NSSlider) {
    controls.gains[sender.tag] = sender.floatValue
    applyControls()
  }
  @objc private func check(_ sender: NSButton) {
    let mask: UInt32 = 1 << UInt32(sender.tag % 4)
    if sender.tag < 4 {
      if sender.state == .on { controls.mute |= mask } else { controls.mute &= ~mask }
    } else {
      if sender.state == .on { controls.solo |= mask } else { controls.solo &= ~mask }
    }
    applyControls()
  }
  @objc private func muteAll(_ sender: NSButton) {
    controls.mute = sender.state == .on ? 0b1111 : 0
    for button in muteButtons { button.state = sender.state }
    applyControls()
  }
  @objc private func clearSolos() {
    controls.solo = 0
    for button in soloButtons { button.state = .off }
    applyControls()
  }
  private func applyControls() {
    muteAllButton.state = controls.mute == 0b1111 ? .on : .off
    clearSoloButton.state = controls.solo != 0 ? .on : .off
    for (waveform, gain) in zip(waveforms, controls.effectiveGains) { waveform.dimmed = gain == 0 }
    session.setControls(controls)
    // No enable step: the first mix that needs stems starts Live Stems.
    if !active, Set(controls.effectiveGains).count > 1 { (startOverride ?? session.start)() }
  }
  private func configureStatusItem() {
    item.button?.title = "Stems"
    item.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Live Stems")
    item.button?.imagePosition = .imageLeading
    item.button?.setAccessibilityLabel("Live Stems")
    item.button?.target = self
    item.button?.action = #selector(showPanel)
  }
  @objc private func quitApp() {
    relaying = true
    panelRequested = false
    window.orderOut(nil)
    NSStatusBar.system.removeStatusItem(item)
    resetControls()  // a reopen starts from Original with the model asleep
    session.quit(completion: terminate)
  }
  func reopen() {
    if relaying {
      relaying = false
      item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
      configureStatusItem()
      session.cancelQuit()
    }
    showPanel()
  }
  func enable() { session.start() }
  func shutdown() { session.shutdownSync() }
}
