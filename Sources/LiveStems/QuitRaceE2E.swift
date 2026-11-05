import Foundation

enum QuitRaceE2E {
  static func run(_ out: URL) throws {
    var processorStarts = 0
    let session = SessionController(traceDirectory: out, source: .spotify,
      startProcessorForTesting: { processorStarts += 1 })
    session.start()
    let activeBeforeQuit = session.e2eEnabledForQuitRace
    var completions = 0
    // Main is deliberately not pumping. The synchronous session barrier
    // guarantees finishQuit has queued termination before reopen cancels it.
    session.quit { completions += 1 }
    session.shutdownSync()
    session.cancelQuit()
    let sessionActiveAfterReopen = session.e2eEnabledForQuitRace
    let processorRestarted = processorStarts == 2
    session.shutdownSync()

    var inactiveProcessorStarts = 0
    let inactiveSession = SessionController(traceDirectory: out.appendingPathComponent("inactive-session"),
      source: .spotify, startProcessorForTesting: { inactiveProcessorStarts += 1 })
    inactiveSession.quit { completions += 1 }
    inactiveSession.shutdownSync()
    inactiveSession.cancelQuit()
    let inactiveSessionStayedOff = !inactiveSession.e2eEnabledForQuitRace && inactiveProcessorStarts == 0
    inactiveSession.shutdownSync()

    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
    let passed = activeBeforeQuit && sessionActiveAfterReopen && processorRestarted
      && inactiveSessionStayedOff && completions == 0
    let report: [String: Any] = ["status": passed ? "pass" : "fail",
      "queued_termination_completions_after_reopen": completions,
      "session_active_before_quit": activeBeforeQuit,
      "session_active_after_reopen": sessionActiveAfterReopen,
      "processor_restarted_after_reopen": processorRestarted,
      "inactive_session_stayed_off": inactiveSessionStayedOff,
      "session_barrier_before_reopen": true,
      "scope": "actual session queue, quit completion, reopen cancellation and main run loop; no audio"]
    try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
      .write(to: out.appendingPathComponent("quit-race.json"))
    guard passed else { throw StemError("Reopen did not restore the pre-Quit session and prevent termination") }
  }
}
