import AppKit
import Foundation

// Invoked by the user's launch command, never by the build or test runner.
let folder = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
let installed = URL(fileURLWithPath: "/Applications/Live Stems.app")
let test = folder.appendingPathComponent("Live Stems Test.app")
guard CommandLine.arguments.count == 2 else { fatalError("Expected an app path") }
let target = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
guard [installed.path, test.path].contains(target.path), FileManager.default.fileExists(atPath: target.path) else {
  fputs("The selected Live Stems build is missing.\n", stderr)
  exit(1)
}
let running = NSWorkspace.shared.runningApplications.filter {
  ["com.benpham.livestems", "com.benpham.livestems.test"].contains($0.bundleIdentifier ?? "")
}
for app in running where app.bundleURL?.standardizedFileURL != target {
  guard let path = app.bundleURL?.standardizedFileURL.path, [installed.path, test.path].contains(path) else {
    fputs("Another Live Stems checkout is open. Quit it before switching builds.\n", stderr)
    exit(1)
  }
  print("Closing \(app.localizedName ?? "Live Stems"). If it is waiting, pause the source player.")
  guard app.terminate() else {
    fputs("Live Stems could not quit. Quit it from its menu, then try again.\n", stderr)
    exit(1)
  }
}
let deadline = Date().addingTimeInterval(12)
while running.contains(where: { !$0.isTerminated && $0.bundleURL?.standardizedFileURL != target }) {
  guard Date() < deadline else {
    fputs("Live Stems is still closing. Pause Spotify, let it quit, then run this command again. No process was forced to stop.\n", stderr)
    exit(1)
  }
  RunLoop.current.run(until: Date().addingTimeInterval(0.1))
}
var finished = false, failure: Error?
NSWorkspace.shared.openApplication(at: target, configuration: NSWorkspace.OpenConfiguration()) { _, error in
  failure = error
  finished = true
}
let openDeadline = Date().addingTimeInterval(12)
while !finished && Date() < openDeadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
guard finished, failure == nil else {
  fputs("Could not open the selected build: \(failure?.localizedDescription ?? "launch timed out").\n", stderr)
  exit(1)
}
print("Opened \(target.lastPathComponent). The installed app was not replaced.")
