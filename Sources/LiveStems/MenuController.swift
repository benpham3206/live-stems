import AppKit
import OSLog

/// The app has no menu bar to carry Cmd+W (close), Cmd+Q (quit), Cmd+1-4
/// (cycle a stem) and Cmd+5 (cycle the spectrum), so the panel handles them itself.
final class PanelWindow: NSWindow {
  var quit: () -> Void = {}
  var cycleStem: (Int) -> Void = { _ in }
  var cycleSpectrum: () -> Void = {}
  var changeTrack: (Bool) -> Void = { _ in }
  var seekRelative: (Bool) -> Void = { _ in }
  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
    if event.type == .keyDown, modifiers == [.command, .shift], [123, 124].contains(event.keyCode) {
      seekRelative(event.keyCode == 124)
      return true
    }
    guard event.type == .keyDown, modifiers == .command else {
      return super.performKeyEquivalent(with: event)
    }
    if [123, 124].contains(event.keyCode) {
      if !event.isARepeat { changeTrack(event.keyCode == 124) }
      return true
    }
    switch event.charactersIgnoringModifiers {
    case "w": windowToClose.performClose(nil)
    case "q": quit()
    case "1", "2", "3", "4": cycleStem(Int(event.charactersIgnoringModifiers!)! - 1)
    case "5": cycleSpectrum()
    default: return super.performKeyEquivalent(with: event)
    }
    return true
  }
  /// Cmd+W closes the focused window. With none focused, another open window
  /// (the Spectrum Analyzer) closes before the panel.
  var windowToClose: NSWindow {
    if let key = NSApp.keyWindow, key.isVisible { return key }
    return NSApp.windows.first { $0 !== self && $0.isVisible && $0.styleMask.contains(.closable) } ?? self
  }
}

final class MenuController: NSObject, NSWindowDelegate, NSMenuDelegate, NSMenuItemValidation {
  private var item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
  private let session: SessionController
  private var relaying = false
  /// True once the quit relay has finished; only then may the app really terminate.
  private(set) var canTerminate = false
  private let activatesOnStatusClick: Bool
  private let terminate: () -> Void
  private let setPolicy: (NSApplication.ActivationPolicy) -> Void
  private let window = PanelWindow(
    contentRect: NSRect(origin: .zero, size: ControlsPanel.size),
    styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered,
    defer: false)
  private let windowLog = Logger(subsystem: "com.benpham.livestems", category: "Windowing")
  private let panel = ControlsPanel()
  private lazy var spectrum: SpectrumWindowController = {
    let spectrum = SpectrumWindowController(read: { [weak self] done in
      self?.session.takeScope(frames: SpectrumAnalyzer.size, done)
    }, settings: { [weak self] in self?.modelMenu() ?? NSMenu() })
    spectrum.window.quit = window.quit
    spectrum.window.cycleStem = window.cycleStem
    spectrum.window.cycleSpectrum = window.cycleSpectrum
    spectrum.window.seekRelative = window.seekRelative
    spectrum.window.changeTrack = window.changeTrack
    return spectrum
  }()
  private var sourcePicker: NSPopUpButton { panel.sourcePicker }
  private var active = false, panelRequested = true, controls = StemControls()
  private var meterTimer: Timer?
  private var followTimer: Timer?
  private var follower = SourceFollower()
  private let sourceActivity = SourceActivity()
  /// What the worker loaded last; Automatic's pick shows next to it in the Model menu.
  private var runningModel: StemModel?
  private var seeking = false, seekSource: AudioSource = .spotify
  override convenience init() {
    self.init(activateOnStatusClick: true)
  }
  private let startOverride: (() -> Void)?
  /// `start` replaces the session start; the menu E2E counts starts without capturing audio.
  init(activateOnStatusClick: Bool, terminate: @escaping () -> Void = { NSApp.terminate(nil) },
    start: (() -> Void)? = nil,
    setPolicy: @escaping (NSApplication.ActivationPolicy) -> Void = { NSApp.setActivationPolicy($0) },
    session: SessionController = SessionController()) {
    self.session = session
    self.setPolicy = setPolicy
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
    window.cycleStem = { [weak self] in self?.cycleStem($0) }
    window.cycleSpectrum = { [weak self] in self?.spectrum.cycle() }
    window.seekRelative = { [weak self] forward in
      guard let self else { return }
      self.seek(forward ? self.panel.forward : self.panel.rewind)
    }
    window.changeTrack = { [weak self] in self?.session.changeTrack(forward: $0) }
    window.level = .floating
    window.titlebarAppearsTransparent = true
    window.titleVisibility = .hidden
    window.isMovableByWindowBackground = true
    window.isOpaque = false
    window.backgroundColor = .clear
    let frame = NSRect(origin: .zero, size: ControlsPanel.size)
    if #available(macOS 26.0, *) {
      let glass = NSGlassEffectView(frame: frame)
      glass.contentView = panel
      window.contentView = glass
    } else {
      // Before Liquid Glass: the same panel on HUD vibrancy.
      let blur = NSVisualEffectView(frame: frame)
      blur.material = .hudWindow
      blur.blendingMode = .behindWindow
      blur.state = .active
      blur.wantsLayer = true
      blur.layer?.cornerRadius = 16
      blur.layer?.masksToBounds = true
      panel.frame = frame
      panel.autoresizingMask = [.width, .height]
      blur.addSubview(panel)
      window.contentView = blur
    }
    // Any open app can be the source; the list refreshes each time it opens.
    sourcePicker.menu?.delegate = self
    sourcePicker.target = self
    sourcePicker.action = #selector(pickSource)
    panel.statusLabel.stringValue = "\(session.source.name) · direct"
    fillSources()
    let actions: [(NSControl, Selector)] = [(panel.resetButton, #selector(resetButton)), (panel.spectrumButton, #selector(showSpectrum)),
      (panel.quitButton, #selector(quitApp)), (panel.muteAllButton, #selector(muteAll(_:))),
      (panel.clearSoloButton, #selector(clearSolos)), (panel.pitchPicker, #selector(transpose)),
      (panel.pitchReset, #selector(resetPitch)), (panel.seekStep, #selector(changeSeekStep)),
      (panel.rewind, #selector(seek(_:))), (panel.forward, #selector(seek(_:)))]
    for (control, action) in actions {
      control.target = self
      control.action = action
    }
    for (index, strip) in panel.strips.enumerated() {
      for (control, tag, action) in [(strip.fader, index, #selector(slide(_:))),
        (strip.mute, index, #selector(check(_:))), (strip.solo, index + 6, #selector(check(_:)))] as [(NSControl, Int, Selector)] {
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
    session.onModel = { [weak self] model in
      guard let self else { return }
      self.runningModel = model
      self.controls.resize(to: model.sources.count)
      for (index, strip) in self.panel.strips.enumerated() {
        strip.fader.floatValue = index < self.controls.gains.count ? self.controls.gains[index] : 1
        strip.mute.state = self.controls.mute & (1 << UInt32(index)) != 0 ? .on : .off
        strip.solo.state = self.controls.solo & (1 << UInt32(index)) != 0 ? .on : .off
        if index < self.controls.gains.count {
          strip.show(silent: self.controls.effectiveGains[index] == 0, soloed: strip.solo.state == .on)
        }
      }
      self.panel.setSourceCount(model.sources.count)
      self.panel.window?.setContentSize(self.panel.frame.size)
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
    // E2E controllers (start override) never follow, so a test cannot change the saved source.
    if start == nil {
      followTimer = Timer.scheduledTimer(withTimeInterval: SourceActivity.pollInterval, repeats: true) { [weak self] _ in self?.follow() }
    }
    // The first launch shows the controls without making the app frontmost.
    presentWindow(reason: "launch", userInitiated: false)
  }
  var e2eStatusButton: NSStatusBarButton? { item.button }
  var e2eWindow: NSWindow? { window }
  var e2eControls: StemControls { controls }
  var e2eSeeking: Bool { seeking }
  func e2eApplyStatusForTest(enabled: Bool) {
    applyStatus(text: "E2E", output: "E2E", enabled: enabled, stems: true)
  }
  func e2eNotifyReadyForTest() { session.onReady?() }
  func e2eApplyModelForTest(_ model: StemModel) { session.onModel?(model) }
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
    seekSource = current
    updateSeekControls()
  }
  /// On by default; kept across launches.
  private static var followsPlaying: Bool {
    get { LocalSettings.defaults.object(forKey: "followPlaying") as? Bool ?? true }
    set { LocalSettings.defaults.set(newValue, forKey: "followPlaying") }
  }
  @objc private func toggleFollow() {
    Self.followsPlaying.toggle()
    if !Self.followsPlaying { sourceActivity.clear() }
  }
  private func follow() {
    guard Self.followsPlaying else { return }
    let playing = sourceActivity.playing(candidates: SourceFollower.playingApps())
    guard let id = follower.next(current: session.source.bundleID, playing: Set(playing.keys), now: stemClock()),
      let name = playing[id] else { return }
    let source = AudioSource(bundleID: id, name: name)
    AudioSource.saved = source
    session.setSource(source)
    fillSources(current: source)
  }
  @objc private func pickSource() {
    guard let item = sourcePicker.selectedItem, let id = item.representedObject as? String else { return }
    let source = AudioSource(bundleID: id, name: item.title)
    follower.picked(at: stemClock())
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
    panel.pitchPicker.selectItem(withTag: 0)
    session.setTranspose(0)
    controls = StemControls(gains: Array(repeating: 1, count: runningModel?.sources.count ?? 4))
    for strip in panel.strips {
      strip.fader.floatValue = 1
      strip.mute.state = .off
      strip.solo.state = .off
    }
    applyControls()
  }
  @objc private func transpose() {
    let value = panel.pitchPicker.selectedItem?.tag ?? 0
    session.setTranspose(value)
    if !active && value != 0 { (startOverride ?? session.start)() }
  }
  @objc private func resetPitch() {
    panel.pitchPicker.selectItem(withTag: 0)
    session.setTranspose(0)
  }
  @objc private func changeSeekStep() { updateSeekControls() }
  private func updateSeekControls() {
    let seconds = panel.seekStep.selectedItem?.tag ?? 10
    panel.rewind.title = "−\(seconds) s"
    panel.forward.title = "+\(seconds) s"
    panel.rewind.setAccessibilityLabel("Rewind \(seconds) seconds")
    panel.forward.setAccessibilityLabel("Forward \(seconds) seconds")
    for button in [panel.rewind, panel.forward] { button.isEnabled = seekSource.isSpotify }
    panel.seekStep.isEnabled = seekSource.isSpotify
    if !seeking {
      panel.transportLabel.stringValue = seekSource.isSpotify ? "Spotify seeking" : "Seeking is available for Spotify only"
      panel.transportLabel.toolTip = panel.transportLabel.stringValue
    }
  }
  @objc private func seek(_ sender: NSButton) {
    guard !seeking, seekSource.isSpotify else { return }
    seeking = true
    sender.highlight(true)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { sender.highlight(false) }
    updateSeekControls()
    panel.transportLabel.stringValue = "Seeking…"
    let seconds = panel.seekStep.selectedItem?.tag ?? 10
    session.seek(by: sender === panel.rewind ? -seconds : seconds) { [weak self] result in
      guard let self else { return }
      self.seeking = false
      self.updateSeekControls()
      switch result {
      case .success(let value):
        self.panel.transportLabel.stringValue = String(format: "Spotify · %d:%02d%@", Int(value.position) / 60,
          Int(value.position) % 60, value.isPlaying ? "" : " · paused")
      case .failure(let error): self.panel.transportLabel.stringValue = error.localizedDescription
      }
      self.panel.transportLabel.toolTip = self.panel.transportLabel.stringValue
    }
  }
  @objc private func slide(_ sender: NSSlider) {
    controls.gains[sender.tag] = sender.floatValue
    applyControls()
  }
  @objc private func check(_ sender: NSButton) {
    let mask: UInt32 = 1 << UInt32(sender.tag % 6)
    if sender.tag < 6 {
      if sender.state == .on { controls.mute |= mask } else { controls.mute &= ~mask }
    } else {
      if sender.state == .on { controls.solo |= mask } else { controls.solo &= ~mask }
    }
    applyControls()
  }
  /// Cmd+1-4: default, then muted, then soloed, then default again.
  private func cycleStem(_ index: Int) {
    let strip = panel.strips[index], mask: UInt32 = 1 << UInt32(index)
    if strip.mute.state == .on {
      strip.mute.state = .off
      strip.solo.state = .on
      controls.mute &= ~mask
      controls.solo |= mask
    } else if strip.solo.state == .on {
      strip.solo.state = .off
      controls.solo &= ~mask
    } else {
      strip.mute.state = .on
      controls.mute |= mask
    }
    applyControls()
  }
  @objc private func muteAll(_ sender: NSButton) {
    controls.mute = sender.state == .on ? ((1 << UInt32(controls.gains.count)) - 1) : 0
    for strip in panel.strips { strip.mute.state = sender.state }
    applyControls()
  }
  @objc private func clearSolos() {
    controls.solo = 0
    for strip in panel.strips { strip.solo.state = .off }
    applyControls()
  }
  private func applyControls() {
    panel.muteAllButton.state = controls.mute == ((1 << UInt32(controls.gains.count)) - 1) ? .on : .off
    panel.clearSoloButton.state = controls.solo != 0 ? .on : .off
    for (index, (strip, gain)) in zip(panel.strips, controls.effectiveGains).enumerated() {
      strip.show(silent: gain == 0, soloed: controls.solo & (1 << UInt32(index)) != 0)
    }
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
  /// A plain click opens the panel; right-click or control-click offers the visibility toggles and Quit.
  @objc private func statusClicked() {
    let event = NSApp.currentEvent
    guard event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true else { return showPanel() }
    // A Dock (regular) app's menus never present on another app's full-screen
    // Space; an accessory app's do. Be accessory while the menu is open (popUp
    // blocks until it closes), then restore the Dock setting.
    guard let button = item.button else { return }
    if Visibility.dock { setPolicy(.accessory) }
    statusMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.maxY + 4), in: button)
    if Visibility.dock { setPolicy(.regular) }
  }
  /// The right-click menu: dockMenu items, a separator, then Quit last.
  func statusMenu() -> NSMenu {
    let menu = dockMenu()
    menu.addItem(.separator())
    let quit = NSMenuItem(title: "Quit Live Stems", action: #selector(quitApp), keyEquivalent: "")
    quit.target = self
    menu.addItem(quit)
    return menu
  }
  // MARK: Dock and menu bar visibility
  /// Applies the saved choice. E2E controllers skip the policy so tests never change the app.
  func applyVisibility() {
    item.isVisible = Visibility.menuBar
    setPolicy(Visibility.dock ? .regular : .accessory)
    guard activatesOnStatusClick else { return }
    NSApp.mainMenu = appMenu()
  }
  /// Menu for the status item and the Dock icon.
  func dockMenu() -> NSMenu {
    let menu = NSMenu()
    for (title, action) in [("Show in Dock", #selector(toggleDock)), ("Show in Menu Bar", #selector(toggleMenuBar)),
      ("Hide When Switching Apps", #selector(toggleHideWhenInactive)),
      ("Follow What's Playing", #selector(toggleFollow))] {
      let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
      entry.target = self
      menu.addItem(entry)
    }
    let modelItem = NSMenuItem(title: "Model", action: nil, keyEquivalent: "")
    modelItem.submenu = modelMenu()
    menu.addItem(.separator())
    menu.addItem(modelItem)
    return menu
  }
  @objc private func showSpectrum() { spectrum.show() }
  /// All model choices, including optional six stems, in the Dock, status menu, and analyzer gear.
  func modelMenu() -> NSMenu {
    let models = NSMenu(title: "Model")
    for model in StemModel.allCases {
      let entry = NSMenuItem(title: model.title, action: #selector(pickModel(_:)), keyEquivalent: "")
      entry.target = self
      entry.representedObject = model.rawValue
      models.addItem(entry)
    }
    return models
  }
  @objc private func pickModel(_ sender: NSMenuItem) {
    guard let model = StemModel(rawValue: sender.representedObject as? String ?? "") else { return }
    session.setModel(model)
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
    case #selector(toggleFollow):
      entry.state = Self.followsPlaying ? .on : .off
      return true
    case #selector(pickModel(_:)):
      let model = StemModel(rawValue: entry.representedObject as? String ?? "") ?? .automatic
      entry.state = model == StemModel.saved ? .on : .off
      var title = model.title
      if model == .automatic, let runningModel { title += " · using " + (runningModel == .standard ? "Standard" : "Fine-tuned") }
      if !model.isDownloaded { title += " · not downloaded" }
      entry.title = title
      return model.isDownloaded
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
    // The relay can wait for the next pause while music plays; the app must look gone meanwhile.
    setPolicy(.accessory)
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
      applyVisibility()
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
