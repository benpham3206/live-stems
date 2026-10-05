import Darwin
import Foundation

// Actual capture, renderer, Spotify reader, and worker. Run from the signed
// bundle with Spotify playing. No menu interaction or synthetic source clock.
enum ReturnE2E {
  static func run(_ out: URL) throws {
    guard let descriptor = try AppInstance.acquire() else {
      throw StemError("Close Live Stems before the Return scenario")
    }
    defer { close(descriptor) }
    // LIVE_STEMS_E2E_SOURCE=<bundle id> runs this against another app (no transport notices).
    let sourceID = ProcessInfo.processInfo.environment["LIVE_STEMS_E2E_SOURCE"]
    let session = SessionController(traceDirectory: out,
      source: sourceID.map { AudioSource(bundleID: $0, name: $0) } ?? .spotify)
    var stopped = false
    defer { if !stopped { session.shutdownSync() } }
    let path = LocalSettings.evidence.appendingPathComponent("active-session.json")
    var snapshots = [SessionDiagnostics]()
    let began = stemClock()
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
        if let state = read(), condition(state) { snapshots.append(state); return state }
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
      } while stemClock() < deadline
      throw StemError("Return scenario timed out; leave Spotify playing")
    }
    do {
      session.start()
      session.setControls(StemControls(gains: [0.9, 1, 1, 1]))  // a neutral mix sleeps the model
      let initial = try wait(35) {
        $0.active && $0.handedOff && !$0.paused && $0.acceptedResults >= 10
          && $0.capturePeak > 0.001 && $0.workerPID > 0
      }
      session.useDirectPlayback()
      let original = try wait(5) { $0.active && $0.workerPID == 0 && !$0.stemsSelected }
      let continued = try wait(5) { $0.workerPID == 0 && $0.playedFrames > original.playedFrames + 44100 }
      guard original.sessionGeneration == initial.sessionGeneration,
        continued.captureFrames > initial.captureFrames, continued.playedFrames > initial.playedFrames,
        kill(initial.workerPID, 0) != 0 else {
        throw StemError("Return reset capture/playback or retained the previous worker")
      }
      // Exercise cancellation while the first replacement warms. Keep capture
      // running throughout; the second replacement must own completion.
      session.toggleMix()
      RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
      session.useDirectPlayback()
      RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
      session.toggleMix()
      let resumed = try wait(35) {
        $0.active && $0.stemsSelected && $0.workerPID > 0 && $0.workerPID != initial.workerPID
          && $0.acceptedResults >= continued.acceptedResults + 10 && $0.blendWeight > 0.9
      }
      guard resumed.sessionGeneration == initial.sessionGeneration,
        resumed.playedFrames > continued.playedFrames,
        resumed.captureFrames > continued.captureFrames,
        resumed.hardCuts == initial.hardCuts else {
        throw StemError("Rapid Return/restart changed the session or source clock: generation \(initial.sessionGeneration)->\(resumed.sessionGeneration) played \(continued.playedFrames)->\(resumed.playedFrames) capture \(continued.captureFrames)->\(resumed.captureFrames) cuts \(initial.hardCuts)->\(resumed.hardCuts)")
      }
      session.shutdownSync(); stopped = true
      var samples = [TraceRecord]()
      for name in ["live-trace.previous.jsonl", "live-trace.jsonl"] {
        guard let data = try? Data(contentsOf: out.appendingPathComponent(name)) else { continue }
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
          let record = try JSONDecoder().decode(TraceRecord.self, from: Data(line.utf8))
          if record.event == "sample", record.renderedFrame != nil { samples.append(record) }
        }
      }
      guard samples.count >= 10 else { throw StemError("Return lacked actual render trace samples") }
      for (previous, next) in zip(samples, samples.dropFirst()) {
        guard next.renderedFrame! >= previous.renderedFrame! else {
          throw StemError("Return moved the rendered source frame backward")
        }
      }
      let ages = samples.compactMap(\.estimatedCaptureToRenderSeconds)
      guard ages.count == samples.count, ages.allSatisfy({ $0 >= 0.2 && $0 <= 0.45 }) else {
        throw StemError("Return changed observed capture-to-render age: \(ages.min() ?? -1)…\(ages.max() ?? -1)")
      }
      try JSONEncoder().encode(snapshots).write(to: out.appendingPathComponent("return-snapshots.json"))
      let report: [String: Any] = ["status": "pass", "duration_seconds": stemClock() - began,
        "render_samples": samples.count, "observed_age_min_seconds": ages.min()!,
        "observed_age_max_seconds": ages.max()!, "return_keeps_session_clock": true,
        "retired_worker_exited": true, "rapid_cancel_and_restart_recovered": true,
        "trace": "live-trace.jsonl", "scope": "real Spotify capture and worker; human listening remains separate"]
      try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        .write(to: out.appendingPathComponent("return.json"))
    } catch {
      session.shutdownSync(); stopped = true
      let report = ["status": "fail", "reason": error.localizedDescription]
      try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        .write(to: out.appendingPathComponent("return.json"))
      throw error
    }
  }
}
