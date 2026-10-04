import AVFoundation

// Live measurement only: real Spotify capture with timestamps, every state
// snapshot, and scripted "next track" commands. Output stays disabled and
// Spotify stays unmuted, so the listener hears Spotify directly.
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
    var skips = [Double]()
    while stemClock() - began < 16 {
      let samplesNow = try audio.drain()
      if !samplesNow.isEmpty {
        lock.lock()
        chunks.append(["end_host": audio.lastDrainEndHostSeconds, "start_frame": Double(samples.count / 2),
          "frames": Double(samplesNow.count / 2)])
        samples.append(contentsOf: samplesNow)
        lock.unlock()
      }
      let elapsed = stemClock() - began
      if skips.count < 3, elapsed > 4 + Double(skips.count) * 4 {
        skips.append(stemClock())
        DispatchQueue.global().async {
          var error: NSDictionary?
          NSAppleScript(source: "tell application \"Spotify\" to next track")?.executeAndReturnError(&error)
        }
      }
      RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.005))
    }
    lock.lock(); defer { lock.unlock() }
    try NativeE2E.write(samples, to: try AVAudioFile(forWriting: out.appendingPathComponent("capture.wav"),
      settings: AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!.settings))
    let report: [String: Any] = ["skip_commands_host": skips, "chunks": chunks, "notices": notices,
      "rate": 44100, "peak": samples.map { abs($0) }.max() ?? 0]
    try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
      .write(to: out.appendingPathComponent("skip-probe.json"))
  }
}
