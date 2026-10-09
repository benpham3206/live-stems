import AVFoundation

// Live measurement only: real Spotify capture with timestamps, every state
// snapshot, and scripted transport commands (pause, play, next, previous) to
// measure Spotify's own fades. Output stays disabled and Spotify stays
// unmuted, so the listener hears Spotify directly.
enum SkipProbeE2E {
  static func run(_ out: URL) throws {
    let audio = try AudioSession()
    let state = SpotifyState()
    var samples = [Float](), chunks = [[String: Double]](), notices = [[String: Any]]()
    let lock = NSLock()
    try audio.start()
    defer { state.stop(); audio.stop() }
    state.start(onSnapshot: { value, host in
      lock.lock(); defer { lock.unlock() }
      notices.append(["host": host, "track": value.trackID, "position": value.position,
        "playing": value.isPlaying])
    }, onUnavailable: { _ in })
    let began = stemClock()
    // Previous comes 1.5 s after next, so Spotify goes back a track instead of restarting it.
    let script: [(Double, String)] = [(3, "pause"), (5, "play"), (8, "next track"), (9.5, "previous track"),
      (13, "pause"), (15, "play"), (18, "next track"), (19.5, "previous track")]
    var commands = [[String: Any]]()
    while stemClock() - began < 23 {
      let samplesNow = try audio.drain()
      if !samplesNow.isEmpty {
        lock.lock()
        chunks.append(["end_host": audio.lastDrainEndHostSeconds, "start_frame": Double(samples.count / 2),
          "frames": Double(samplesNow.count / 2)])
        samples.append(contentsOf: samplesNow)
        lock.unlock()
      }
      if commands.count < script.count, stemClock() - began > script[commands.count].0 {
        let command = script[commands.count].1
        commands.append(["host": stemClock(), "command": command])
        DispatchQueue.global().async {
          var error: NSDictionary?
          NSAppleScript(source: "tell application \"Spotify\" to \(command)")?.executeAndReturnError(&error)
        }
      }
      RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.005))
    }
    lock.lock(); defer { lock.unlock() }
    try NativeE2E.write(samples, to: try AVAudioFile(forWriting: out.appendingPathComponent("capture.wav"),
      settings: AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!.settings))
    let report: [String: Any] = ["commands": commands, "chunks": chunks, "notices": notices,
      "rate": 44100, "peak": samples.map { abs($0) }.max() ?? 0]
    try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
      .write(to: out.appendingPathComponent("skip-probe.json"))
  }
}
