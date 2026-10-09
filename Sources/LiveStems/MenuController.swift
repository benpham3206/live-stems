import AppKit
import OSLog

/// The app has no menu bar to carry Cmd+W (close) and Cmd+Q (quit), so the
/// panel handles them itself.
final class PanelWindow: NSWindow {
  var quit: () -> Void = {}
  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    guard event.type == .keyDown, event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command else {
      return super.performKeyEquivalent(with: event)
    }
    switch event.charactersIgnoringModifiers {
    case "w": performClose(nil)
    case "q": quit()
    default: return super.performKeyEquivalent(with: event)
    }
    return true
  }
}

final class MenuController: NSObject, NSWindowDelegate, NSMenuDelegate, NSMenuItemValidation {
  private var item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
  private let session = SessionController()
  private var relaying = false
  /// True once the quit relay has finished; only then may the app really terminate.
  private(set) var canTerminate = false
  private let activatesOnStatusClick: Bool
  private let terminate: () -> Void
  private let window = PanelWindow(
    contentRect: NSRect(origin: .zero, size: ControlsPanel.size),
    styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered,
    defer: false)
  private let windowLog = Logger(subsystem: "com.benpham.livestems", category: "Windowing")
  private let panel = ControlsPanel()
  private var sourcePicker: NSPopUpButton { panel.sourcePicker }
  private var active = false, panelRequested = true, controls = StemControls()
  private var meterTimer: Timer?
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
    window.quit = { [weak self] in self?.quitApp() }
    window.level = .floating
    window.titlebarAppearsTransparent = true
    window.titleVisibility = .hidden
    window.isMovableByWindowBackground = true
    window.isOpaque = false
    window.backgroundColor = .clear
    let glass = NSGlassEffectView(frame: NSRect(origin: .zero, size: ControlsPanel.size))
    glass.contentView = panel
    window.contentView = glass
    // Any open app can be the source; the list refreshes each time it opens.
    sourcePicker.menu?.delegate = self
    sourcePicker.target = self
    sourcePicker.action = #selector(pickSource)
    panel.statusLabel.stringValue = "\(session.source.name) · direct"
    fillSources()
    let actions: [(NSControl, Selector)] = [(panel.resetButton, #selector(resetButton)),
      (panel.quitButton, #selector(quitApp)), (panel.muteAllButton, #selector(muteAll(_:))),
      (panel.clearSoloButton, #selector(clearSolos))]
    for (control, action) in actions {
      control.target = self
      control.action = action
    }
    for (index, strip) in panel.strips.enumerated() {
      for (control, tag, action) in [(strip.fader, index, #selector(slide(_:))),
        (strip.mute, index, #selector(check(_:))), (strip.solo, index + 4, #selector(check(_:)))] as [(NSControl, Int, Selector)] {
        control.tag = tag
        control.target = self
        control.action = action
      }
    }
    panel.outputLabel.stringValue = "Output: " + outputName(defaultOutput())
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
        // Waveforms show the stem pre-fader; meters show it after the mix.
        for (strip, (peak, gain)) in zip(self.panel.strips, zip(peaks, self.controls.effectiveGains)) {
          strip.waveform.push(peak)
          strip.meter.push(peak * gain)
        }
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
    panel.statusLabel.stringValue = text
    panel.statusLabel.toolTip = text
    panel.outputLabel.stringValue = "Output: " + output
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
  func menuNeedsUpdate(_ menu: NSMenu) { fillSources() }
  /// Open regular apps (not Live Stems), plus the saved source if it is closed.
  /// It is a pull-down so it always opens below the panel's top edge; item 0 is
  /// the button title, so it repeats the current source.
  private func fillSources(current: AudioSource? = nil) {
    let current = current ?? session.source
    var apps = NSWorkspace.shared.runningApplications
      .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
      .compactMap { app -> (AudioSource, NSImage?)? in
        guard let id = app.bundleIdentifier, let name = app.localizedName else { return nil }
        return (AudioSource(bundleID: id, name: name), app.icon)
      }
      .sorted { $0.0.name.localizedCaseInsensitiveCompare($1.0.name) == .orderedAscending }
    if !apps.contains(where: { $0.0 == current }) { apps.insert((current, nil), at: 0) }
    sourcePicker.removeAllItems()
    for (index, (source, icon)) in ([apps.first { $0.0 == current }!] + apps).enumerated() {
      // Not addItem(withTitle:): it drops an existing item with the same title.
      let item = NSMenuItem(title: source.name, action: nil, keyEquivalent: "")
      sourcePicker.menu!.addItem(item)
      item.representedObject = source.bundleID
      icon?.size = NSSize(width: 16, height: 16)
      item.image = icon
      item.state = index > 0 && source == current ? .on : .off
    }
    sourcePicker.selectItem(at: 0)
  }
  @objc private func pickSource() {
    guard let item = sourcePicker.selectedItem, let id = item.representedObject as? String else { return }
    let source = AudioSource(bundleID: id, name: item.title)
    AudioSource.saved = source
    session.setSource(source)
    fillSources(current: source)  // setSource is async; show the pick now
  }
  /// Neutral controls and a live stem splitter again, whatever state it was in.
  @objc private func resetButton() {
    resetControls()
    session.restoreStems()
  }
  /// Full volume, no mute or solo: Original, so the model sleeps.
  private func resetControls() {
    controls = StemControls()
    for strip in panel.strips {
      strip.fader.floatValue = 1
      strip.mute.state = .off
      strip.solo.state = .off
    }
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
    for strip in panel.strips { strip.mute.state = sender.state }
    applyControls()
  }
  @objc private func clearSolos() {
    controls.solo = 0
    for strip in panel.strips { strip.solo.state = .off }
    applyControls()
  }
  private func applyControls() {
    panel.muteAllButton.state = controls.mute == 0b1111 ? .on : .off
    panel.clearSoloButton.state = controls.solo != 0 ? .on : .off
    for (strip, gain) in zip(panel.strips, controls.effectiveGains) { strip.waveform.dimmed = gain == 0 }
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
    item.button?.action = #selector(statusClicked)
    item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
    item.isVisible = Visibility.menuBar
  }
  /// A plain click opens the panel; right-click or control-click offers the visibility toggles.
  @objc private func statusClicked() {
    let event = NSApp.currentEvent
    guard event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true else { return showPanel() }
    item.menu = dockMenu()
    item.button?.performClick(nil)
    item.menu = nil
  }
  // MARK: Dock and menu bar visibility
  /// Applies the saved choice. E2E controllers skip the policy so tests never change the app.
  func applyVisibility() {
    item.isVisible = Visibility.menuBar
    guard activatesOnStatusClick else { return }
    NSApp.setActivationPolicy(Visibility.dock ? .regular : .accessory)
    NSApp.mainMenu = appMenu()
  }
  /// Menu for the status item and the Dock icon.
  func dockMenu() -> NSMenu {
    let menu = NSMenu()
    for (title, action) in [("Show in Dock", #selector(toggleDock)), ("Show in Menu Bar", #selector(toggleMenuBar)),
      ("Hide When Switching Apps", #selector(toggleHideWhenInactive))] {
      let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
      entry.target = self
      menu.addItem(entry)
    }
    return menu
  }
  /// The menu bar shown while the Dock icon is on; carries Cmd+W and Cmd+Q.
  private func appMenu() -> NSMenu {
    let bar = NSMenu(), holder = NSMenuItem(), menu = dockMenu()
    menu.title = "Live Stems"
    menu.addItem(.separator())
    menu.addItem(NSMenuItem(title: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
    menu.addItem(NSMenuItem(title: "Quit Live Stems", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    holder.submenu = menu
    bar.addItem(holder)
    return bar
  }
  @objc private func toggleDock() {
    Visibility.setDock(!Visibility.dock)
    applyVisibility()
  }
  @objc private func toggleMenuBar() {
    Visibility.setMenuBar(!Visibility.menuBar)
    applyVisibility()
  }
  @objc private func toggleHideWhenInactive() { Visibility.hideWhenInactive.toggle() }
  func validateMenuItem(_ entry: NSMenuItem) -> Bool {
    switch entry.action {
    case #selector(toggleHideWhenInactive):
      entry.state = Visibility.hideWhenInactive ? .on : .off
      return true
    case #selector(toggleDock):
      entry.state = Visibility.dock ? .on : .off
      return !Visibility.dock || Visibility.menuBar
    case #selector(toggleMenuBar):
      entry.state = Visibility.menuBar ? .on : .off
      return !Visibility.menuBar || Visibility.dock
    default: return true
    }
  }
  @objc private func quitApp() {
    relaying = true
    panelRequested = false
    window.orderOut(nil)
    NSStatusBar.system.removeStatusItem(item)
    resetControls()  // a reopen starts from Original with the model asleep
    session.quit { [weak self] in
      self?.canTerminate = true
      self?.terminate()
    }
  }
  /// Quit as the Quit button does: relay the audio back, then terminate.
  func requestQuit() { quitApp() }
  func reopen() {
    if relaying {
      relaying = false
      canTerminate = false
      item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
      configureStatusItem()
      session.cancelQuit()
    }
    showPanel()
  }
  /// Cmd+Tab only activates the app; a closed panel must come back with it.
  func appActivated() {
    guard !relaying else { return }
    if window.isVisible { window.makeKeyAndOrderFront(nil) } else { showPanel() }
  }
  /// Another app came forward: tuck the panel away, as a menu bar popover would.
  func appResigned() {
    guard Visibility.hideWhenInactive, !relaying, window.isVisible else { return }
    window.orderOut(nil)
  }
  func enable() { session.start() }
  func shutdown() { session.shutdownSync() }
}
