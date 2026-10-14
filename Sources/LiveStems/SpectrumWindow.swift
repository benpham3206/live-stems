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
  // System toolbar items, so they draw as the system's (Liquid Glass on macOS 26) and cannot overlap.
  private let mode = NSToolbarItemGroup(itemIdentifier: SpectrumWindowController.modeItem, titles: ["3D", "2D"],
    selectionMode: .selectOne, labels: ["3D", "2D"], target: nil, action: nil)
  private let scale = NSMenuToolbarItem(itemIdentifier: SpectrumWindowController.scaleItem),
    amplitude = NSMenuToolbarItem(itemIdentifier: SpectrumWindowController.amplitudeItem),
    span = NSMenuToolbarItem(itemIdentifier: SpectrumWindowController.spanItem),
    settings = NSMenuToolbarItem(itemIdentifier: SpectrumWindowController.settingsItem)
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

    mode.selectedIndex = 0
    mode.label = "View"
    mode.target = self
    mode.action = #selector(changeMode)
    for (item, label, titles, chosen, action) in [
      (scale, "Frequency", ["Log Frequency", "Linear Frequency"], 0, #selector(changeScale(_:))),
      (amplitude, "Amplitude", ["dB", "Linear"], 0, #selector(changeAmplitude(_:))),
      (span, "Span", ["2 s", "5 s", "10 s"], 1, #selector(changeSpan(_:))),
    ] as [(NSMenuToolbarItem, String, [String], Int, Selector)] {
      item.label = label
      item.title = titles[chosen]
      item.autovalidates = false
      item.menu = NSMenu()
      for (i, title) in titles.enumerated() {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
        entry.target = self
        entry.tag = i
        entry.state = i == chosen ? .on : .off
        item.menu.addItem(entry)
      }
    }
    // The gear: the model and the glow curves, rebuilt each time it opens.
    settings.label = "Settings"
    settings.image = symbol(["gearshape"])
    settings.showsIndicator = false
    settings.toolTip = "Model and glow"
    settings.menu = NSMenu()
    settings.menu.delegate = self
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

  fileprivate static let modeItem = NSToolbarItem.Identifier("mode"), scaleItem = NSToolbarItem.Identifier("scale"),
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
    view.threeD = mode.selectedIndex == 0
    amplitude.isEnabled = view.threeD  // 2D is MiniMeters' tilted dB view
  }
  /// Ticks the picked entry, shows it as the item's title, and returns its index.
  private func choose(_ entry: NSMenuItem, in item: NSMenuToolbarItem) -> Int {
    for other in item.menu.items { other.state = other === entry ? .on : .off }
    item.title = entry.title
    return entry.tag
  }
  @objc private func changeAmplitude(_ entry: NSMenuItem) { view.linearAmplitude = choose(entry, in: amplitude) == 1 }
  @objc private func changeScale(_ entry: NSMenuItem) { view.logFrequency = choose(entry, in: scale) == 0 }
  @objc private func changeSpan(_ entry: NSMenuItem) { view.seconds = [2, 5, 10][choose(entry, in: span)] }
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
}

extension SpectrumWindowController: NSToolbarDelegate {
  func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    [.flexibleSpace, Self.modeItem, .flexibleSpace, Self.scaleItem, Self.amplitudeItem, Self.spanItem, Self.settingsItem]
  }
  func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { toolbarDefaultItemIdentifiers(toolbar) }
  func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
    [Self.modeItem: mode, Self.scaleItem: scale, Self.amplitudeItem: amplitude, Self.spanItem: span, Self.settingsItem: settings][id]
  }
}

extension SpectrumWindowController: NSMenuDelegate {
  /// The gear's menu, fresh as it opens: the glow tick follows the current choice.
  func menuNeedsUpdate(_ menu: NSMenu) {
    let fresh = gearMenu(), items = fresh.items
    fresh.removeAllItems()
    menu.removeAllItems()
    for item in items { menu.addItem(item) }
  }
}
