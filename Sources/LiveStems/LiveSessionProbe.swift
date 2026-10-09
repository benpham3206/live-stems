import Foundation

/// Reads the running session's diagnostics file for the live E2E stages.
struct LiveSessionProbe {
  let timeoutMessage: String
  private let path = LocalSettings.evidence.appendingPathComponent("active-session.json")
  /// The current snapshot, if this process wrote it within the last 3 s.
  func read() -> SessionDiagnostics? {
    guard let data = try? Data(contentsOf: path),
      let state = try? JSONDecoder().decode(SessionDiagnostics.self, from: data),
      state.appPID == ProcessInfo.processInfo.processIdentifier,
      stemClock() - state.observedUptime < 3 else { return nil }
    return state
  }
  /// Polls until `condition` holds, or throws `timeoutMessage` after `seconds`.
  func wait(_ seconds: Double, _ condition: (SessionDiagnostics) -> Bool) throws -> SessionDiagnostics {
    let deadline = stemClock() + seconds
    repeat {
      if let state = read(), condition(state) { return state }
      RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
    } while stemClock() < deadline
    throw StemError(timeoutMessage)
  }
}
