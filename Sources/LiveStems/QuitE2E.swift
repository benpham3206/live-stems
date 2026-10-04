import Darwin
import Foundation

// Actual process tap, hardware renderer, worker, and session queue. Only the
// metadata pause is injected: this test does not control Spotify playback.
enum QuitE2E {
  static func run(_ out: URL) throws {
    guard let descriptor = try AppInstance.acquire() else {
      throw StemError("Close Live Stems before the Quit scenario")
    }
    defer { close(descriptor) }
    let lock = NSLock(), began = stemClock()
    var paused = false, position = 0.0
    let state = SpotifyState(reader: {
      lock.lock(); defer { lock.unlock() }
      if !paused { position = stemClock() - began }
      return PlaybackSnapshot(trackID: "quit-e2e", title: "Live capture", duration: 3600,
        position: position, isPlaying: !paused)
    })
    let session = SessionController(traceDirectory: out, spotifyState: state)
    defer { session.shutdownSync() }
    let diagnostics = LocalSettings.evidence.appendingPathComponent("active-session.json")
    var snapshots = [SessionDiagnostics](), completions = 0
    func read() -> SessionDiagnostics? {
      guard let data = try? Data(contentsOf: diagnostics),
        let value = try? JSONDecoder().decode(SessionDiagnostics.self, from: data),
        value.appPID == ProcessInfo.processInfo.processIdentifier else { return nil }
      return value
    }
    func wait(_ seconds: Double, _ condition: (SessionDiagnostics) -> Bool) throws -> SessionDiagnostics {
      let deadline = stemClock() + seconds
      repeat {
        if let value = read(), condition(value) { snapshots.append(value); return value }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.03))
      } while stemClock() < deadline
      throw StemError("Quit scenario timed out; leave Spotify playing")
    }
    do {
      session.start()
      let initial = try wait(35) { $0.active && $0.handedOff && $0.acceptedResults >= 10 && $0.capturePeak > 0.001 }
      session.quit { completions += 1 }
      let relay = try wait(5) { $0.active && $0.workerPID == 0 && !$0.stemsSelected }
      let later = try wait(5) { $0.workerPID == 0 && $0.playedFrames > relay.playedFrames + 44100 }
      guard completions == 0, relay.sessionGeneration == initial.sessionGeneration,
        later.hardCuts == initial.hardCuts, kill(initial.workerPID, 0) != 0 else {
        throw StemError("Quit stopped the source clock, kept AI, or ended while playing")
      }
      session.cancelQuit()
      session.toggleMix()
      let resumed = try wait(35) { $0.active && $0.workerPID > 0 && $0.stemsSelected && $0.blendWeight > 0.9 }
      guard completions == 0, resumed.sessionGeneration == initial.sessionGeneration else {
        throw StemError("Reopening the relay restarted the audio session")
      }
      session.quit { completions += 1 }
      _ = try wait(5) { $0.active && $0.workerPID == 0 && !$0.stemsSelected }
      lock.lock(); position = stemClock() - began; paused = true; lock.unlock()
      let deadline = stemClock() + 5
      while completions == 0 && stemClock() < deadline {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.03))
      }
      guard completions == 1, let stopped = read(), !stopped.active, stopped.queuedFrames == 0 else {
        throw StemError("Paused relay did not drain and complete exactly once")
      }
      session.shutdownSync()
      let data = try Data(contentsOf: out.appendingPathComponent("live-trace.jsonl"))
      let records = try String(decoding: data, as: UTF8.self).split(separator: "\n").map {
        try JSONDecoder().decode(TraceRecord.self, from: Data($0.utf8))
      }
      guard let handoff = records.first(where: { $0.event == "handoff" }),
        (handoff.queuedFrames ?? 0) >= 2205 else { throw StemError("Startup suppressed an unprimed queue") }
      let renders = records.filter { $0.event == "sample" }.compactMap(\.renderedFrame)
      guard renders.count >= 10, zip(renders, renders.dropFirst()).allSatisfy({ $1 >= $0 }) else {
        throw StemError("Quit or reopen moved the render clock backward")
      }
      let report: [String: Any] = ["status": "pass", "duration_seconds": stemClock() - began,
        "handoff_queued_frames": handoff.queuedFrames!, "render_samples": renders.count,
        "original_relay_keeps_clock": true, "ai_exited_before_pause": true,
        "reopen_keeps_session": true, "completion_count": completions,
        "paused_queue_drained": true,
        "scope": "actual capture, renderer and FT worker; metadata pause injected; physical listening pending"]
      try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        .write(to: out.appendingPathComponent("quit.json"))
      try JSONEncoder().encode(snapshots).write(to: out.appendingPathComponent("quit-snapshots.json"))
    } catch {
      session.shutdownSync()
      try? JSONSerialization.data(withJSONObject: ["status": "fail", "reason": error.localizedDescription],
        options: [.prettyPrinted, .sortedKeys]).write(to: out.appendingPathComponent("quit.json"))
      throw error
    }
  }
}
