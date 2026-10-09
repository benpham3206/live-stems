import AppKit
import Foundation

/// Native AppKit action-path checks for the menu-bar controls window.
///
/// This runs without CUA, AppleScript, Spotify, or an audio session. The
/// status button and controls still go through their AppKit target/actions.
enum MenuE2E {
  private static func pump(_ seconds: Double = 0.05) {
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
  }

  private static func require(
    _ condition: @autoclosure () -> Bool, _ message: String
  ) throws {
    guard condition() else { throw StemError(message) }
  }

  private static func descendants(of view: NSView) -> [NSView] {
    [view] + view.subviews.flatMap { descendants(of: $0) }
  }

  private static func control(
    named label: String, in window: NSWindow
  ) throws -> NSButton {
    guard let content = window.contentView,
      let button = descendants(of: content).compactMap({ $0 as? NSButton })
        .first(where: { $0.accessibilityLabel() == label })
    else { throw StemError("Menu E2E could not find \(label)") }
    return button
  }

  private static func write(
    _ report: [String: Any], to out: URL
  ) throws {
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: out.appendingPathComponent("menu.json"), options: .atomic)
  }

  static func run(_ out: URL) throws {
    var report: [String: Any] = [
      "status": "fail",
      "scope": "native AppKit target/action path; no CUA, AppleScript, Spotify, or audio session",
      "checks": [],
    ]
    do {
      let result = try execute()
      report["status"] = "pass"
      report["checks"] = result
      try write(report, to: out)
      print("PASS menu · \(result.count) AppKit checks")
    } catch {
      report["reason"] = error.localizedDescription
      try? write(report, to: out)
      throw error
    }
  }

  private static func execute() throws -> [[String: Any]] {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let launchActive = app.isActive
    // Synthetic target/action clicks must not steal the user's foreground app.
    // The normal product initializer keeps activation enabled for real clicks.
    var quitCompletions = 0
    var starts = 0
    let controller = MenuController(
      activateOnStatusClick: false, terminate: { quitCompletions += 1 }, start: { starts += 1 })
    guard let status = controller.e2eStatusButton,
      let window = controller.e2eWindow
    else { throw StemError("Menu E2E could not access the AppKit controls") }
    var checks = [[String: Any]]()
    defer { window.orderOut(nil) }

    let requiredMask: NSWindow.StyleMask = [.titled, .closable]
    try require(window.styleMask.isSuperset(of: requiredMask), "Controls window is missing titled/closable style")
    try require(!window.styleMask.contains(.utilityWindow), "Controls window still uses utility style")
    try require(!window.styleMask.contains(.nonactivatingPanel), "Controls window still uses nonactivating panel style")
    try require(window.level == .floating, "Controls window is not floating")
    try require(status.title == "Stems", "Status title is not the constant Stems label")
    checks.append([
      "name": "window_style",
      "style": "titled.closable.floating",
      "status_title": status.title,
    ])

    try require(window.isVisible, "Launch did not present the controls window")
    try require(app.isActive == launchActive, "Launch presentation activated the app")
    controller.e2eApplyStatusForTest(enabled: true)
    try require(status.title == "Stems", "Active status changed the status title width")
    try require(app.isActive == launchActive, "Status update activated the app")
    checks.append([
      "name": "background_launch_and_status",
      "visible": window.isVisible,
      "app_active_before": launchActive,
      "app_active_after": app.isActive,
    ])

    window.performClose(nil)
    pump()
    try require(!window.isVisible, "Close action did not hide the controls window")
    let closedActive = app.isActive
    try require(closedActive == launchActive, "Close action activated the app")
    controller.e2eNotifyReadyForTest()
    pump()
    try require(!window.isVisible, "Readiness reopened a user-closed controls window")
    try require(app.isActive == closedActive, "Readiness activated the app")
    checks.append([
      "name": "close_persists_through_readiness",
      "visible_after_close": false,
      "visible_after_readiness": window.isVisible,
      "app_active": app.isActive,
    ])

    status.performClick(nil)
    pump()
    try require(window.isVisible, "First status-item click did not show controls")
    try require(app.isActive == closedActive, "Native E2E status-item action stole app focus")
    let firstClickTitle = status.title
    status.performClick(nil)
    pump()
    try require(window.isVisible, "Repeated status-item click closed the controls")
    try require(status.title == firstClickTitle, "Repeated status-item click changed status title")
    checks.append([
      "name": "first_and_repeated_status_click",
      "visible_after_first": true,
      "visible_after_repeat": window.isVisible,
      "app_active_after_click": app.isActive,
    ])

    let picker = try control(named: "Audio source", in: window)
    guard let popup = picker as? NSPopUpButton, popup.numberOfItems >= 1,
      popup.titleOfSelectedItem == AudioSource.saved.name else {
      throw StemError("Audio source picker missing, empty, or not showing the saved source")
    }
    checks.append(["name": "source_picker", "items": popup.numberOfItems])
    controller.e2eApplyStatusForTest(enabled: false)  // as after launch: nothing running yet
    try require(starts == 0, "Live Stems started before any control needed stems")
    for label in ["Vocals Mute", "Vocals Solo"] {
      let button = try control(named: label, in: window)
      button.performClick(nil)
      pump()
      try require(window.isVisible, "\(label) closed the controls window")
      try require(button.state == .on, "\(label) action did not remain selected")
      checks.append([
        "name": "control_stays_open",
        "control": label,
        "visible": window.isVisible,
        "state": button.state == .on,
      ])
    }

    try require(starts > 0, "The first Mute did not start Live Stems")
    checks.append(["name": "first_control_starts", "starts": starts])
    let bassSolo = try control(named: "Bass Solo", in: window)
    bassSolo.performClick(nil)
    pump()
    let clearSolo = try control(named: "Clear all solos", in: window)
    try require(clearSolo.state == .on, "Global solo did not light while stems were soloed")
    clearSolo.performClick(nil)
    pump()
    let vocalsSolo = try control(named: "Vocals Solo", in: window)
    try require(vocalsSolo.state == .off && bassSolo.state == .off && clearSolo.state == .off,
      "Global solo did not clear every solo")
    checks.append(["name": "global_solo_clears", "cleared": true])

    window.performClose(nil)
    pump()
    try require(!window.isVisible, "Second close action did not hide the controls window")
    status.performClick(nil)
    pump()
    try require(window.isVisible, "Status-item reopen did not show controls")
    checks.append([
      "name": "close_and_reopen",
      "visible_after_reopen": window.isVisible,
      "status_click_activation": "disabled_for_native_e2e",
    ])
    guard let content = window.contentView,
      let quit = descendants(of: content).compactMap({ $0 as? NSButton })
        .first(where: { $0.title == "Quit Live Stems" }) else { throw StemError("Quit button missing") }
    let drumsMute = try control(named: "Drums Mute", in: window)
    drumsMute.performClick(nil)
    pump()
    quit.performClick(nil)
    pump()
    try require(!window.isVisible, "Quit kept controls visible")
    controller.e2eNotifyReadyForTest()
    pump()
    try require(!window.isVisible, "Readiness reopened Quit controls")
    try require(quitCompletions == 1, "Inactive Quit did not complete exactly once")
    controller.reopen()
    pump()
    try require(window.isVisible, "Relay reopen did not restore controls")
    try require(drumsMute.state == .off, "Quit did not reset the mix to Original")
    try require(controller.e2eStatusButton?.title == "Stems", "Relay reopen lost its status item")
    try require(app.isActive == launchActive, "Relay E2E stole app focus")
    checks.append(["name": "quit_and_reopen", "inactive_completion_count": quitCompletions,
      "readiness_stays_hidden": true, "reopen_visible": window.isVisible])
    return checks
  }
  static func snapshot(_ out: URL) throws {
    // Draws the real controls panel to PNG, light and dark, without screen recording.
    let controller = MenuController(activateOnStatusClick: false, terminate: {}, start: {})
    guard let window = controller.e2eWindow, let view = window.contentView else {
      throw StemError("Snapshot has no panel")
    }
    for (name, look) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
      window.appearance = NSAppearance(named: look)
      view.layoutSubtreeIfNeeded()
      let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
      NSAppearance(named: look)!.performAsCurrentDrawingAppearance {
        view.cacheDisplay(in: view.bounds, to: rep)
      }
      let image = NSImage(size: view.bounds.size)
      image.addRepresentation(rep)
      NSAppearance(named: look)!.performAsCurrentDrawingAppearance {
        image.lockFocus()
        NSColor.windowBackgroundColor.setFill()
        view.bounds.fill(using: .destinationOver)
        image.unlockFocus()
      }
      try NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
        .write(to: out.appendingPathComponent("panel-\(name).png"))
    }
    print("PASS snapshot · panel-light.png, panel-dark.png")
  }

  /// 3000 random clicks on every panel control. After each one the buttons must
  /// agree with each other; Reset must clear everything. No audio session runs.
  static func spam(_ out: URL) throws {
    let saved = AudioSource.saved
    defer { AudioSource.saved = saved }
    let controller = MenuController(activateOnStatusClick: false, terminate: {}, start: {})
    guard let window = controller.e2eWindow, let content = window.contentView else {
      throw StemError("Spam has no panel")
    }
    let views = descendants(of: content)
    func button(_ label: String) throws -> NSButton { try control(named: label, in: window) }
    let names = ["Vocals", "Drums", "Bass", "Other"]
    let mutes = try names.map { try button("\($0) Mute") }, solos = try names.map { try button("\($0) Solo") }
    let muteAll = try button("Mute all"), clearSolo = try button("Clear all solos")
    guard let reset = views.compactMap({ $0 as? NSButton }).first(where: { $0.title == "Reset" }),
      let picker = views.compactMap({ $0 as? NSPopUpButton }).first else { throw StemError("Spam lacks Reset or picker") }
    let sliders = views.compactMap { $0 as? NSSlider }
    guard sliders.count == 4 else { throw StemError("Spam found \(sliders.count) sliders") }
    var seed: UInt64 = 7
    func roll(_ n: Int) -> Int { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Int((seed >> 33) % UInt64(n)) }
    var counts = [String: Int]()
    for click in 0..<3000 {
      let action = roll(7)
      switch action {
      case 0: mutes[roll(4)].performClick(nil)
      case 1: solos[roll(4)].performClick(nil)
      case 2: muteAll.performClick(nil)
      case 3: clearSolo.performClick(nil)
      case 4: reset.performClick(nil)
      case 5:
        let slider = sliders[roll(4)]
        slider.floatValue = Float(roll(101)) / 100
        slider.sendAction(slider.action, to: slider.target)
      default:
        picker.selectItem(at: roll(picker.numberOfItems))
        picker.sendAction(picker.action, to: picker.target)
      }
      counts[["mute", "solo", "mute_all", "clear_solo", "reset", "slider", "source"][action], default: 0] += 1
      let allMuted = mutes.allSatisfy { $0.state == .on }, anySolo = solos.contains { $0.state == .on }
      guard muteAll.state == (allMuted ? .on : .off), clearSolo.state == (anySolo ? .on : .off) else {
        throw StemError("Click \(click): All M or clear-solo disagrees with the stem buttons")
      }
      if action == 4 {
        guard (mutes + solos).allSatisfy({ $0.state == .off }), sliders.allSatisfy({ $0.floatValue == 1 }) else {
          throw StemError("Click \(click): Reset left a control changed")
        }
      }
      guard picker.titleOfSelectedItem != nil else { throw StemError("Click \(click): source picker lost its selection") }
    }
    let report: [String: Any] = ["status": "pass", "clicks": 3000, "by_control": counts]
    try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
      .write(to: out.appendingPathComponent("spam.json"))
    print("PASS spam · 3000 random panel clicks, buttons always consistent")
  }
}
