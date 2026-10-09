import AppKit
import Darwin

final class AppDelegate: NSObject, NSApplicationDelegate {
  var menu: MenuController?
  private var reopenObserver: NSObjectProtocol?
  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory)
    menu = MenuController()
    menu?.applyVisibility()
    // Arm at launch: capture runs with Spotify still direct, and the model
    // sleeps until a control needs stems. Takeover waits for a natural break.
    menu?.enable()
    reopenObserver = DistributedNotificationCenter.default().addObserver(
      forName: AppInstance.reopenNotification, object: nil, queue: .main) { [weak self] _ in
        self?.menu?.reopen()
      }
    DispatchQueue.global(qos: .utility).async {
      try? FileManager.default.createDirectory(
        at: LocalSettings.runtime, withIntermediateDirectories: true)
      try? Data("\(ProcessInfo.processInfo.processIdentifier)\n".utf8).write(
        to: LocalSettings.runtime.appendingPathComponent("app.pid"))
    }
  }
  /// Cmd+Q, Cmd+Tab Quit and the Dock's Quit take the Quit button's path first.
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard let menu, !menu.canTerminate else { return .terminateNow }
    menu.requestQuit()
    return .terminateCancel
  }
  func applicationDockMenu(_ sender: NSApplication) -> NSMenu? { menu?.dockMenu() }
  func applicationWillTerminate(_ notification: Notification) { menu?.shutdown() }
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    menu?.reopen()
    return false
  }
}
@main enum EntryPoint {
  static func main() {
    if CommandLine.arguments.contains("--e2e") {
      do { try NativeE2E.run() } catch {
        fputs("E2E failed: \(error)\n", stderr)
        exit(1)
      }
      return
    }
    let instance: Int32
    do {
      guard let descriptor = try AppInstance.acquire() else {
        AppInstance.requestReopen()
        fputs("Live Stems is already running.\n", stderr)
        return
      }
      instance = descriptor
    } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
    defer { close(instance) }
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    if CommandLine.arguments.contains("--enable") {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
        delegate.menu?.enable()
      }
    }
    withExtendedLifetime(delegate) { app.run() }
  }
}
