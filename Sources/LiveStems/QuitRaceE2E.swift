import Foundation

enum QuitRaceE2E {
  static func run(_ out: URL) throws {
    let session = SessionController(traceDirectory: out, source: .spotify)
    var completions = 0
    // Main is deliberately not pumping. The synchronous session barrier
    // guarantees finishQuit has queued termination before reopen cancels it.
    session.quit { completions += 1 }
    session.shutdownSync()
    session.cancelQuit()
    session.shutdownSync()
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
    let passed = completions == 0
    let report: [String: Any] = ["status": passed ? "pass" : "fail",
      "queued_termination_completions_after_reopen": completions,
      "session_barrier_before_reopen": true,
      "scope": "actual session queue, quit completion, reopen cancellation and main run loop; no audio"]
    try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
      .write(to: out.appendingPathComponent("quit-race.json"))
    guard passed else { throw StemError("Queued Quit terminated after reopen") }
  }
}
