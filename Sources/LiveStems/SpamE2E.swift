import Darwin
import Foundation

// Live control spam: actual capture, renderer, worker, and the chosen source
// (Spotify unless LIVE_STEMS_E2E_SOURCE is set). Run from the signed bundle
// through `open`, with the source playing. 20 s of random mix changes every
// 20-80 ms, with Reset and worker stop/restart mixed in; the session must
// survive with its clock running, no overflow, and a live worker at the end.
enum SpamE2E {
  static func run(_ out: URL) throws {
    guard let descriptor = try AppInstance.acquire() else {
      throw StemError("Close Live Stems before the spam scenario")
    }
    defer { close(descriptor) }
    let sourceID = ProcessInfo.processInfo.environment["LIVE_STEMS_E2E_SOURCE"]
    let session = SessionController(traceDirectory: out,
      source: sourceID.map { AudioSource(bundleID: $0, name: $0) } ?? .spotify)
    defer { session.shutdownSync() }
    let path = LocalSettings.evidence.appendingPathComponent("active-session.json")
    func read() -> SessionDiagnostics? {
      guard let data = try? Data(contentsOf: path),
        let state = try? JSONDecoder().decode(SessionDiagnostics.self, from: data),
        state.appPID == ProcessInfo.processInfo.processIdentifier,
        stemClock() - state.observedUptime < 3 else { return nil }
      return state
    }
    func wait(_ seconds: Double, _ condition: (SessionDiagnostics) -> Bool) throws -> SessionDiagnostics {
      let deadline = stemClock() + seconds
      repeat {
        if let state = read(), condition(state) { return state }
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
      } while stemClock() < deadline
      throw StemError("Spam scenario timed out; leave the source playing")
    }
    session.start()
    session.setControls(StemControls(gains: [0.9, 1, 1, 1]))
    let before = try wait(35) { $0.active && $0.handedOff && $0.acceptedResults >= 10 && $0.workerPID > 0 }
    var seed: UInt64 = 11
    func roll(_ n: Int) -> Int { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Int((seed >> 33) % UInt64(n)) }
    var counts = [String: Int]()
    let spamEnd = stemClock() + 20
    while stemClock() < spamEnd {
      switch roll(100) {
      case 0..<3:
        session.useDirectPlayback(); counts["stop_worker", default: 0] += 1
      case 3..<8:
        session.restoreStems(); counts["reset", default: 0] += 1
      default:
        var controls = StemControls()
        controls.gains = (0..<4).map { _ in Float(roll(101)) / 100 }
        controls.mute = UInt32(roll(16)); controls.solo = roll(3) == 0 ? UInt32(roll(16)) : 0
        session.setControls(controls); counts["mix", default: 0] += 1
      }
      RunLoop.current.run(until: Date(timeIntervalSinceNow: Double(20 + roll(61)) / 1000))
    }
    // Settle on a mix that needs stems, then require a healthy session.
    session.restoreStems()
    session.setControls(StemControls(gains: [0.9, 1, 1, 1]))
    let after = try wait(35) {
      $0.active && $0.stemsSelected && $0.workerPID > 0 && $0.acceptedResults > before.acceptedResults + 10
    }
    // Diagnostics refresh every 2 s; compare against a genuinely newer snapshot.
    let last = try wait(5) { $0.observedUptime > after.observedUptime }
    guard last.active else { throw StemError("Spam stopped the session") }
    guard last.overflowCount == 0 else { throw StemError("Spam overflowed the output queue") }
    guard last.playedFrames > after.playedFrames, last.captureFrames > after.captureFrames else {
      throw StemError("Spam stalled the playback or capture clock")
    }
    guard last.sessionGeneration == before.sessionGeneration else { throw StemError("Spam restarted the session") }
    guard kill(last.workerPID, 0) == 0 else { throw StemError("Spam left no live worker") }
    // Rapid source switching: each pick tears down and rebuilds capture and the
    // worker. Six picks 150 ms apart, ending on the original source.
    let original = session.source
    for index in 0..<6 {
      session.setSource(index % 2 == 0 ? AudioSource(bundleID: "com.apple.Music", name: "Music") : original)
      // A plain sleep: this pause needs no run loop (run(until:) stalled here).
      Thread.sleep(forTimeInterval: 0.15)
    }
    session.setControls(StemControls(gains: [0.9, 1, 1, 1]))
    let switched = try wait(40) { $0.active && $0.handedOff && $0.workerPID > 0 && $0.acceptedResults >= 10 }
    guard switched.overflowCount == 0, session.source == original else {
      throw StemError("Rapid source switching left a broken session")
    }
    counts["source_switch"] = 6
    let report: [String: Any] = ["status": "pass", "actions": counts,
      "underruns_during_spam": Int(last.underrunFrames) - Int(before.underrunFrames),
      "late_results": last.lateResults, "hard_cuts": last.hardCuts - before.hardCuts]
    try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
      .write(to: out.appendingPathComponent("spam-live.json"))
    print("PASS spam-live · \(counts)")
  }
}
