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
    let controller = MenuController(activateOnStatusClick: false, terminate: { quitCompletions += 1 })
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
    try require(controller.e2eStatusButton?.title == "Stems", "Relay reopen lost its status item")
    try require(app.isActive == launchActive, "Relay E2E stole app focus")
    checks.append(["name": "quit_and_reopen", "inactive_completion_count": quitCompletions,
      "readiness_stays_hidden": true, "reopen_visible": window.isVisible])
    return checks
  }
}
