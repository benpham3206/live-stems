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
  private let mode = Choice(["3D", "2D"])
  private let scale = NSPopUpButton(), amplitude = NSPopUpButton(), span = NSPopUpButton()
  private let settings = NSButton()
  /// The gear's menu: the model choice.
  private let settingsMenu: () -> NSMenu

  init(read: @escaping (@escaping (Scope?) -> Void) -> Void, settings settingsMenu: @escaping () -> NSMenu = { NSMenu() }) {
    self.read = read
    self.settingsMenu = settingsMenu
    super.init()
    window.title = "Spectrum Analyzer"
    window.titlebarAppearsTransparent = true
    window.titleVisibility = .hidden
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

    // The reference's tint over the glass, then one rounded bar: icon tile and name, the
    // view switch in the middle, the scale menus and settings at the right.
    content.wantsLayer = true
    content.layer?.backgroundColor = CGColor(srgbRed: 0.05, green: 0.07, blue: 0.15, alpha: 0.25)
    let bar = Backdrop(), tile = Backdrop(), gear = Backdrop()
    bar.radius = 14
    tile.radius = 11
    tile.fill = NSColor(srgbRed: 0.45, green: 0.62, blue: 1, alpha: 0.16)
    gear.radius = 19.5
    gear.fill = NSColor.white.withAlphaComponent(0.09)
    let icon = NSImageView(image: NSImage(size: NSSize(width: 20, height: 18), flipped: false) { _ in
      NSColor.white.withAlphaComponent(0.9).setFill()
      for (i, h) in [9, 16, 11, 14, 7].enumerated() {  // a level meter's bars
        NSBezierPath(roundedRect: NSRect(x: CGFloat(i) * 4.2, y: 0, width: 2.4, height: CGFloat(h)), xRadius: 1.2, yRadius: 1.2).fill()
      }
      return true
    })
    let name = NSTextField(labelWithString: "Spectrum Analyzer")
    name.font = .systemFont(ofSize: 16)
    name.textColor = NSColor.white.withAlphaComponent(0.92)
    mode.setAccessibilityLabel("View")
    mode.changed = { [weak self] _ in self?.changeMode() }
    scale.addItems(withTitles: ["Log Frequency", "Linear Frequency"])
    scale.setAccessibilityLabel("Frequency scale")
    amplitude.addItems(withTitles: ["dB", "Linear"])
    amplitude.setAccessibilityLabel("Amplitude scale")
    span.addItems(withTitles: ["2 s", "5 s", "10 s"])
    span.selectItem(at: 1)
    span.setAccessibilityLabel("Time span")
    settings.isBordered = false
    settings.image = symbol(["gearshape"])
    settings.symbolConfiguration = .init(pointSize: 17, weight: .regular)
    settings.contentTintColor = NSColor.white.withAlphaComponent(0.9)
    settings.imagePosition = .imageOnly
    settings.toolTip = "Model"
    settings.setAccessibilityLabel("Settings")
    for (control, action) in [(scale, #selector(changeScale)), (amplitude, #selector(changeAmplitude)),
      (span, #selector(changeSpan)), (settings, #selector(openSettings))] as [(NSControl, Selector)] {
      control.target = self
      control.action = action
    }
    let trays = [scale, amplitude, span].map(tray)
    view.setAccessibilityLabel("Spectrum of the mix you hear")
    for item in [bar, tile, icon, name, mode, gear, settings, view] + trays as [NSView] {
      item.translatesAutoresizingMaskIntoConstraints = false
      content.addSubview(item)
    }
    // Sizes and places measured off the reference at this window's size.
    func size(_ item: NSView, _ width: CGFloat, _ height: CGFloat) -> [NSLayoutConstraint] {
      [item.widthAnchor.constraint(equalToConstant: width), item.heightAnchor.constraint(equalToConstant: height),
       item.centerYAnchor.constraint(equalTo: bar.centerYAnchor)]
    }
    NSLayoutConstraint.activate([
      bar.topAnchor.constraint(equalTo: content.topAnchor, constant: 28),
      bar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
      bar.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10),
      bar.heightAnchor.constraint(equalToConstant: 82),
      tile.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 11),
      icon.centerXAnchor.constraint(equalTo: tile.centerXAnchor),
      icon.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
      name.leadingAnchor.constraint(equalTo: tile.trailingAnchor, constant: 14),
      name.centerYAnchor.constraint(equalTo: bar.centerYAnchor, constant: -6),
      mode.centerXAnchor.constraint(equalTo: content.centerXAnchor),
      gear.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -13),
      settings.centerXAnchor.constraint(equalTo: gear.centerXAnchor),
      settings.centerYAnchor.constraint(equalTo: gear.centerYAnchor),
      trays[2].trailingAnchor.constraint(equalTo: gear.leadingAnchor, constant: -13),
      trays[1].trailingAnchor.constraint(equalTo: trays[2].leadingAnchor, constant: -14),
      trays[0].trailingAnchor.constraint(equalTo: trays[1].leadingAnchor, constant: -13),
      view.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 8),
      view.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
      view.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
      view.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
    ] + size(tile, 46, 46) + size(mode, 162, 37) + size(gear, 39, 39) + size(trays[0], 140, 37) + size(trays[1], 75, 37)
      + size(trays[2], 93, 37))
  }

  /// A borderless pull-down on a tray with one down chevron, as the reference's menus.
  private func tray(_ popup: NSPopUpButton) -> Backdrop {
    let tray = Backdrop(), chevron = NSImageView(image: symbol(["chevron.down"]))
    tray.fill = NSColor.white.withAlphaComponent(0.09)
    chevron.symbolConfiguration = .init(pointSize: 12, weight: .medium)
    chevron.contentTintColor = NSColor.white.withAlphaComponent(0.9)
    let titles = popup.itemTitles, chosen = popup.indexOfSelectedItem
    popup.pullsDown = true
    popup.isBordered = false
    (popup.cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
    popup.font = .systemFont(ofSize: 14)
    popup.removeAllItems()
    // A pull-down's first item is its title; menu items directly, as addItems(withTitles:) drops the duplicate.
    for title in [titles[chosen]] + titles { popup.menu?.addItem(withTitle: title, action: nil, keyEquivalent: "") }
    for item in [chevron, popup] as [NSView] {
      item.translatesAutoresizingMaskIntoConstraints = false
      tray.addSubview(item)
    }
    NSLayoutConstraint.activate([
      popup.leadingAnchor.constraint(equalTo: tray.leadingAnchor, constant: 8),
      popup.trailingAnchor.constraint(equalTo: tray.trailingAnchor),
      popup.centerYAnchor.constraint(equalTo: tray.centerYAnchor),
      chevron.centerXAnchor.constraint(equalTo: tray.trailingAnchor, constant: -19),
      chevron.centerYAnchor.constraint(equalTo: tray.centerYAnchor),
    ])
    return tray
  }

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
    view.threeD = mode.selected == 0
    amplitude.isEnabled = view.threeD  // 2D is MiniMeters' tilted dB view
  }
  /// The chosen choice of a pull-down, shown as its title.
  private func choice(_ popup: NSPopUpButton) -> Int {
    popup.setTitle(popup.titleOfSelectedItem ?? "")
    return popup.indexOfSelectedItem - 1
  }
  @objc private func changeAmplitude() { view.linearAmplitude = choice(amplitude) == 1 }
  @objc private func openSettings() {
    settingsMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: settings.bounds.maxY + 4), in: settings)
  }
  @objc private func changeScale() { view.logFrequency = choice(scale) == 0 }
  @objc private func changeSpan() { view.seconds = [2, 5, 10][choice(span)] }
}

/// Two choices on a tray, the chosen one on a blue pill, as the reference's 3D and 2D.
final class Choice: Backdrop {
  private(set) var selected = 0
  var changed: (Int) -> Void = { _ in }
  private var buttons = [NSButton]()
  init(_ titles: [String]) {
    super.init(frame: .zero)
    fill = NSColor.white.withAlphaComponent(0.07)
    buttons = titles.enumerated().map { index, title in
      let button = NSButton(title: title, target: nil, action: #selector(pick))
      button.setButtonType(.pushOnPushOff)
      button.isBordered = false
      button.font = .systemFont(ofSize: 14)
      button.tag = index
      button.target = self
      button.state = index == 0 ? .on : .off
      addSubview(button)
      return button
    }
  }
  required init?(coder: NSCoder) { fatalError() }
  override func layout() {
    super.layout()
    let width = bounds.width / CGFloat(buttons.count)
    for (i, button) in buttons.enumerated() { button.frame = NSRect(x: CGFloat(i) * width, y: 0, width: width, height: bounds.height) }
  }
  @objc private func pick(_ sender: NSButton) {
    selected = sender.tag
    for button in buttons { button.state = button.tag == selected ? .on : .off }
    needsDisplay = true
    changed(selected)
  }
  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    let width = bounds.width / CGFloat(buttons.count)
    NSColor(srgbRed: 0.36, green: 0.48, blue: 0.82, alpha: 0.62).setFill()
    NSBezierPath(roundedRect: NSRect(x: CGFloat(selected) * width, y: 0, width: width, height: bounds.height).insetBy(dx: 1.5, dy: 1.5),
      xRadius: 9, yRadius: 9).fill()
  }
}
