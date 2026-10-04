import AppKit
import OSLog

final class MenuController: NSObject, NSWindowDelegate {
  private var item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
  private let session = SessionController()
  private var relaying = false
  private let activatesOnStatusClick: Bool
  private let terminate: () -> Void
  private let window = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 330, height: 460),
    styleMask: [.titled, .closable], backing: .buffered,
    defer: false)
  private let windowLog = Logger(subsystem: "com.benpham.livestems", category: "Windowing")
  private let statusLabel = NSTextField(labelWithString: "Live Spotify · original"),
    outputLabel = NSTextField(labelWithString: ""),
    startButton = NSButton(title: "Enable live stems", target: nil, action: nil),
    liveButton = NSButton(title: "Return to live Spotify", target: nil, action: nil)
  private var active = false, panelRequested = true, controls = StemControls()
  private var muteButtons: [NSButton] = [], waveforms: [StemWaveform] = []
  private var muteAllButton: NSButton!
  private var meterTimer: Timer?
  private static let muteColor = NSColor(srgbRed: 0.29, green: 0.62, blue: 1, alpha: 1)
  private static let soloColor = NSColor(srgbRed: 1, green: 0.82, blue: 0.2, alpha: 1)
  override convenience init() {
    self.init(activateOnStatusClick: true)
  }
  init(activateOnStatusClick: Bool, terminate: @escaping () -> Void = { NSApp.terminate(nil) }) {
    self.activatesOnStatusClick = activateOnStatusClick
    self.terminate = terminate
    super.init()
    configureStatusItem()
    window.title = "Live Stems"
    window.isReleasedWhenClosed = false
    window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    window.delegate = self
    window.level = .floating
    let content = NSView(frame: NSRect(x: 0, y: 0, width: 330, height: 460))
    window.contentView = content
    statusLabel.frame = NSRect(x: 16, y: 427, width: 298, height: 20)
    content.addSubview(statusLabel)
    outputLabel.frame = NSRect(x: 16, y: 405, width: 298, height: 18)
    outputLabel.font = .systemFont(ofSize: 11)
    content.addSubview(outputLabel)
    startButton.frame = NSRect(x: 12, y: 367, width: 306, height: 30)
    startButton.target = self
    startButton.action = #selector(toggle)
    startButton.bezelStyle = .rounded
    content.addSubview(startButton)
    let stemColors: [NSColor] = [.systemPink, .systemOrange, .systemPurple, .systemGreen]
    for (index, name) in ["Vocals", "Drums", "Bass", "Other"].enumerated() {
      let row = NSView(frame: NSRect(x: 0, y: 303 - index * 64, width: 330, height: 64))
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
      for (offset, title) in ["Mute", "Solo"].enumerated() {
        let button = LogicToggle(
          letter: String(title.prefix(1)), lit: offset == 0 ? Self.muteColor : Self.soloColor,
          target: self, action: #selector(check(_:)))
        button.tag = index + offset * 4
        button.frame = NSRect(x: 262 + offset * 28, y: 36, width: 24, height: 22)
        button.setAccessibilityLabel(name + " " + title)
        button.toolTip = title
        row.addSubview(button)
        if offset == 0 { muteButtons.append(button) }
      }
      content.addSubview(row)
    }
    let allLabel = NSTextField(labelWithString: "All stems")
    allLabel.frame = NSRect(x: 16, y: 85, width: 100, height: 20)
    content.addSubview(allLabel)
    muteAllButton = LogicToggle(
      letter: "M", lit: Self.muteColor, target: self, action: #selector(muteAll(_:)))
    muteAllButton.frame = NSRect(x: 262, y: 84, width: 24, height: 22)
    muteAllButton.setAccessibilityLabel("Mute all")
    muteAllButton.toolTip = "Mute all stems"
    content.addSubview(muteAllButton)
    liveButton.frame = NSRect(x: 12, y: 42, width: 306, height: 30)
    liveButton.bezelStyle = .rounded
    liveButton.target = self
    liveButton.action = #selector(returnToLive)
    liveButton.isEnabled = false
    content.addSubview(liveButton)
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
    startButton.title = enabled ? (stems ? "Use original mix" : "Use stems") : "Enable live stems"
    liveButton.isEnabled = enabled
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
  @objc private func toggle() { if active { session.toggleMix() } else { session.start() } }
  @objc private func returnToLive() { session.useLiveSpotify() }
  @objc private func slide(_ sender: NSSlider) {
    controls.gains[sender.tag] = sender.floatValue
    session.setControls(controls)
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
  private func applyControls() {
    muteAllButton.state = controls.mute == 0b1111 ? .on : .off
    for (index, waveform) in waveforms.enumerated() {
      let bit: UInt32 = 1 << UInt32(index)
      waveform.dimmed = controls.mute & bit != 0 || (controls.solo != 0 && controls.solo & bit == 0)
    }
    session.setControls(controls)
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
