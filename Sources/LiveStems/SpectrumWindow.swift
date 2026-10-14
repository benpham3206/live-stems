import AppKit

/// The Spectrum Analyzer window: a toolbar row like the panel's, and the plot.
final class SpectrumWindowController: NSObject, NSWindowDelegate {
  let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 724),
    styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
  let view = SpectrumView()
  private var analyzer = SpectrumAnalyzer()
  private var timer: Timer?, silentRows = 0
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
    if let saved = UserDefaults.standard.object(forKey: Self.glowKey) as? Int, Tuning.glowLooks.indices.contains(saved) {
      view.glowLook = saved
    }
    // A native unified toolbar over the glass: the title at the leading edge, the view switch in the
    // middle, the scale menus and settings at the trailing edge. On macOS 26 it draws as Liquid Glass;
    // when the window is too narrow, items move to its overflow menu instead of overlapping.
    let toolbar = NSToolbar(identifier: "SpectrumAnalyzer")
    toolbar.delegate = self
    toolbar.displayMode = .iconOnly
    toolbar.allowsUserCustomization = false
    toolbar.centeredItemIdentifier = Self.modeItem
    window.toolbar = toolbar
    window.toolbarStyle = .unified
    window.titlebarAppearsTransparent = true
    window.isMovableByWindowBackground = true
    window.isReleasedWhenClosed = false
    window.appearance = NSAppearance(named: .darkAqua)
    window.minSize = NSSize(width: 720, height: 460)  // the 3D labels stay inside the view (checked)
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
    // The reference's navy tint over the glass.
    content.wantsLayer = true
    content.layer?.backgroundColor = CGColor(srgbRed: 0.05, green: 0.07, blue: 0.15, alpha: 0.25)

    mode.selectedSegment = 0
    mode.segmentDistribution = .fillEqually
    mode.setWidth(52, forSegment: 0)
    mode.setWidth(52, forSegment: 1)
    mode.setAccessibilityLabel("View")
    scale.addItems(withTitles: ["Log Frequency", "Linear Frequency"])
    scale.setAccessibilityLabel("Frequency scale")
    amplitude.addItems(withTitles: ["dB", "Linear"])
    amplitude.setAccessibilityLabel("Amplitude scale")
    span.addItems(withTitles: ["2 s", "5 s", "10 s"])
    span.selectItem(at: 1)
    span.setAccessibilityLabel("Time span")
    settings.bezelStyle = .texturedRounded
    settings.image = symbol(["gearshape"])
    settings.imagePosition = .imageOnly
    settings.toolTip = "Model and glow"
    settings.setAccessibilityLabel("Settings")
    for (control, action) in [(mode, #selector(changeMode)), (scale, #selector(changeScale)), (amplitude, #selector(changeAmplitude)),
      (span, #selector(changeSpan)), (settings, #selector(openSettings))] as [(NSControl, Selector)] {
      control.target = self
      control.action = action
    }
    view.setAccessibilityLabel("Spectrum of the mix you hear")
    view.translatesAutoresizingMaskIntoConstraints = false
    content.addSubview(view)
    // The plot under the toolbar, inset as the window's corners are round.
    NSLayoutConstraint.activate([
      view.topAnchor.constraint(equalTo: content.safeAreaLayoutGuide.topAnchor, constant: 8),
      view.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
      view.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
      view.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
    ])
  }

  private static let modeItem = NSToolbarItem.Identifier("mode"), scaleItem = NSToolbarItem.Identifier("scale"),
    amplitudeItem = NSToolbarItem.Identifier("amplitude"), spanItem = NSToolbarItem.Identifier("span"),
    settingsItem = NSToolbarItem.Identifier("settings")

  func show() {
    if !window.isVisible { window.center() }
    window.makeKeyAndOrderFront(nil)
    view.redraw()  // the last rows, even while silence holds them
    guard timer == nil else { return }
    // 30 rows a second while open; nothing runs while closed.
    timer = Timer(timeInterval: 1.0 / Double(SpectrumView.rowsPerSecond), repeats: true) { [weak self] _ in self?.tick() }
    RunLoop.main.add(timer!, forMode: .common)
  }
  func windowWillClose(_ notification: Notification) {
    timer?.invalidate()
    timer = nil
  }
  private func tick() { read { [weak self] in self?.feed($0) } }
  /// One row from the newest samples. When nothing plays, or the mix has stayed under -90 dB
  /// for 150 ms, empty rows scroll in until the whole span sits at the floor; then no row and
  /// no redraw: the view stands still until sound comes back. Returns whether sound made a row.
  @discardableResult func feed(_ scope: Scope?) -> Bool {
    view.hint = scope == nil ? "Shows what Live Stems plays. Press M or S on a stem to start." : nil
    guard let scope, scope.mix.suffix(Int(0.15 * scope.rate)).contains(where: { abs($0) > 3.2e-5 }) else {
      if silentRows < view.seconds * SpectrumView.rowsPerSecond { view.hush() }
      silentRows += 1
      return false
    }
    silentRows = 0
    analyzer.rate = scope.rate
    view.push(heard: analyzer.levels(scope.mix, log: view.logFrequency), original: analyzer.levels(scope.original, log: view.logFrequency))
    return true
  }
  @objc private func changeMode() {
    view.threeD = mode.selectedSegment == 0
    amplitude.isEnabled = view.threeD  // 2D is MiniMeters' tilted dB view
  }
  private func choice(_ popup: NSPopUpButton) -> Int { popup.indexOfSelectedItem }
  @objc private func changeAmplitude() { view.linearAmplitude = choice(amplitude) == 1 }
  @objc private func openSettings() {
    gearMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: settings.bounds.maxY + 4), in: settings)
  }
  /// The model choice, then the glow curves to compare, the one in use ticked.
  func gearMenu() -> NSMenu {
    let menu = settingsMenu()
    menu.addItem(.separator())
    menu.addItem(.sectionHeader(title: "Glow"))
    for (i, look) in Tuning.glowLooks.enumerated() {
      let item = NSMenuItem(title: look.name, action: #selector(pickGlow(_:)), keyEquivalent: "")
      item.target = self
      item.tag = i
      item.state = i == view.glowLook ? .on : .off
      menu.addItem(item)
    }
    return menu
  }
  @objc func pickGlow(_ item: NSMenuItem) {
    view.glowLook = item.tag
    UserDefaults.standard.set(item.tag, forKey: Self.glowKey)
  }
  private static let glowKey = "SpectrumGlowLook"
  @objc private func changeScale() { view.logFrequency = choice(scale) == 0 }
  @objc private func changeSpan() { view.seconds = [2, 5, 10][choice(span)] }
}

extension SpectrumWindowController: NSToolbarDelegate {
  func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    [.flexibleSpace, Self.modeItem, .flexibleSpace, Self.scaleItem, Self.amplitudeItem, Self.spanItem, Self.settingsItem]
  }
  func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { toolbarDefaultItemIdentifiers(toolbar) }
  func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
    let controls: [NSToolbarItem.Identifier: (NSControl, String)] = [Self.modeItem: (mode, "View"), Self.scaleItem: (scale, "Frequency"),
      Self.amplitudeItem: (amplitude, "Amplitude"), Self.spanItem: (span, "Span"), Self.settingsItem: (settings, "Settings")]
    guard let (control, label) = controls[id] else { return nil }
    let item = NSToolbarItem(itemIdentifier: id)
    item.view = control
    item.label = label
    return item
  }
}
