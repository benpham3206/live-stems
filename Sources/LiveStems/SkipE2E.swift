import AudioCore
import AVFoundation
import Foundation

enum SkipE2E {
  static func run(_ out: URL) throws {
    guard let core = ls_create(44100, 44100) else { throw StemError("Skip core unavailable") }
    defer { ls_destroy(core) }
    func block(_ count: Int, _ left: Float, _ right: Float) -> [Float] {
      var data = [Float](repeating: 0, count: count * 11)
      for i in 0..<count { data[i * 11 + 8] = left; data[i * 11 + 9] = right }
      return data
    }
    func write(_ data: [Float]) {
      _ = data.withUnsafeBufferPointer { ls_output_write(core, $0.baseAddress, UInt32(data.count / 11)) }
    }
    func read(_ count: Int) -> [Float] {
      var data = [Float](repeating: 0, count: count * 2)
      _ = data.withUnsafeMutableBufferPointer { ls_read_mix(core, $0.baseAddress, UInt32(count)) }
      return data
    }
    ls_enable(core, 1)
    write(block(22050, 0.45, -0.4))
    let prefix = read(4410)
    guard abs(prefix[prefix.count - 2]) > 0.4, ls_queued(core) > 0 else {
      throw StemError("Skip fixture did not leave a nonzero previous frame and queue")
    }
    ls_flush_output(core)
    let gap = read(441)
    var snapshot = LSRenderSnapshot()
    guard ls_render_snapshot(core, &snapshot) == 1,
      snapshot.source_frame == UInt64.max, snapshot.capture_nanos == 0 else {
      throw StemError("Skip trace retained the previous source during priming")
    }
    write(block(441, -0.2, 0.35))
    let held = read(441)
    write(block(2205, -0.2, 0.35))
    let fresh = read(2205)
    let rendered = prefix + gap + held + fresh
    let file = try AVAudioFile(forWriting: out.appendingPathComponent("skip-rendered.wav"),
      settings: AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!.settings)
    try NativeE2E.write(rendered, to: file)
    var expected = [Float]()
    func appendExpected(_ count: Int, _ left: Float, _ right: Float) {
      var envelope: Float = 0
      for _ in 0..<count {
        envelope = min(1, envelope + Float(1 / (44100.0 * 0.0025)))
        expected.append(left * envelope); expected.append(right * envelope)
      }
    }
    appendExpected(4410, 0.45, -0.4)
    // A flush keeps the last rendered sample and fades it over 96 frames
    // (~2 ms), then holds silence through priming. No full-level old audio.
    let lastLeft = expected[expected.count - 2], lastRight = expected[expected.count - 1]
    for k in 0..<96 {
      let gain = Float(96 - 1 - k) / 96
      expected.append(lastLeft * gain); expected.append(lastRight * gain)
    }
    expected.append(contentsOf: [Float](repeating: 0, count: (882 - 96) * 2))
    appendExpected(2205, -0.2, 0.35)
    let expectedFile = try AVAudioFile(forWriting: out.appendingPathComponent("skip-expected.wav"),
      settings: AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!.settings)
    try NativeE2E.write(expected, to: expectedFile)
    let maxError = zip(rendered, expected).map { abs($0 - $1) }.max() ?? 0
    guard maxError < 1e-6 else { throw StemError("Skip waveform mismatch: \(maxError)") }
    let ghostPeak = (gap + held).map(abs).max() ?? 0
    guard ghostPeak <= max(abs(lastLeft), abs(lastRight)) + 1e-6 else {
      throw StemError("Skip replayed previous audio above its cut level: \(ghostPeak)")
    }
    let postFade = Array((gap + held).dropFirst(96 * 2))
    guard postFade.allSatisfy({ $0 == 0 }) else {
      throw StemError("Skip did not reach silence after its 96-frame fade")
    }
    guard abs(fresh[fresh.count - 2] + 0.2) < 1e-6,
      abs(fresh.last! - 0.35) < 1e-6 else { throw StemError("Skip failed to resume the new source") }

    var capture = [Float](repeating: 0.8, count: 4096 * 2)
    var now = AudioTimeStamp(), inputTime = AudioTimeStamp(), outputTime = AudioTimeStamp()
    capture.withUnsafeMutableBytes { data in
      var input = AudioBufferList(mNumberBuffers: 1,
        mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(data.count), mData: data.baseAddress))
      var output = input
      _ = ls_capture_callback(0, &now, &input, &inputTime, &output, &outputTime, UnsafeMutableRawPointer(core))
    }
    ls_discard_capture(core)
    let readAfterCut = capture.withUnsafeMutableBufferPointer { ls_capture_read(core, $0.baseAddress, 4096) }
    guard readAfterCut == 0 else { throw StemError("Skip retained unread previous capture") }
    // A callback can be copying old audio while the session receives a skip.
    // Use a long block to expose publication after a consumer-side discard.
    let started = DispatchSemaphore(value: 0), finished = DispatchSemaphore(value: 0)
    let oldCapture = [Float](repeating: 0.8, count: 990000 * 2)
    DispatchQueue.global(qos: .userInitiated).async {
      oldCapture.withUnsafeBytes { data in
        var input = AudioBufferList(mNumberBuffers: 1,
          mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(data.count),
            mData: UnsafeMutableRawPointer(mutating: data.baseAddress)))
        var output = input
        var stamp = AudioTimeStamp()
        started.signal()
        _ = ls_capture_callback(0, &stamp, &input, &stamp, &output, &stamp, UnsafeMutableRawPointer(core))
      }
      finished.signal()
    }
    guard started.wait(timeout: .now() + 1) == .success else { throw StemError("Capture race did not start") }
    Thread.sleep(forTimeInterval: 0.0005)
    ls_discard_capture(core)
    guard finished.wait(timeout: .now()) == .timedOut else {
      throw StemError("Capture race fixture completed before the discard")
    }
    guard finished.wait(timeout: .now() + 2) == .success else { throw StemError("Capture race did not finish") }
    let raceRemaining = capture.withUnsafeMutableBufferPointer { ls_capture_read(core, $0.baseAddress, 4096) }
    guard raceRemaining == 0 else { throw StemError("In-flight old capture published after skip: \(raceRemaining) frames") }
    // Spotify keeps playing the old track for ~50–100 ms after its notice.
    // That tail must not reach playback after the post-skip gap.
    guard let tailCore = ls_create(44100, 44100) else { throw StemError("Tail core unavailable") }
    defer { ls_destroy(tailCore) }
    let pipeline = StemPipeline(core: tailCore)
    var committed = [(frame: Int, left: Float)]()
    pipeline.onCommit = { start, data in
      for f in 0..<data.count / 11 { committed.append((start + f, data[f * 11 + 8])) }
    }
    pipeline.start(generation: 1)
    pipeline.observe(PlaybackSnapshot(trackID: "old", title: "", duration: 60, position: 10, isPlaying: true), hostTime: 100)
    func level(_ count: Int, _ value: Float) -> [Float] { [Float](repeating: value, count: count * 2) }
    pipeline.ingest(level(88200, 0.5), hostTime: 102)
    pipeline.step()
    let cutFrame = pipeline.end
    guard pipeline.observe(PlaybackSnapshot(trackID: "new", title: "", duration: 60, position: 0, isPlaying: true), hostTime: 102) else {
      throw StemError("Tail fixture did not register a manual cut")
    }
    committed.removeAll()
    pipeline.ingest(level(3000, 0.5), hostTime: 102.07)
    pipeline.ingest(level(1000, 0), hostTime: 102.09)
    pipeline.ingest(level(22050, 0.3), hostTime: 102.6)
    pipeline.step()
    guard let first = committed.first, first.frame == cutFrame + 3000,
      !committed.contains(where: { $0.left == 0.5 }), committed.contains(where: { $0.left == 0.3 }) else {
      throw StemError("Old-track tail reached playback after the skip: first frame \(committed.first?.frame ?? -1), cut \(cutFrame)")
    }
    let report: [String: Any] = ["status": "pass", "cut_fade_frames": 96,
      "old_tail_frames_trimmed_from_playback": 3000,
      "cut_fade_peak": ghostPeak,
      "gap_and_prime_frames_checked": 882, "old_unread_capture_discarded": true,
      "new_source_resumed": true, "rendered_wav": "skip-rendered.wav",
      "expected_wav": "skip-expected.wav", "max_sample_error": maxError,
      "inflight_capture_cannot_publish_after_cut": true,
      "priming_trace_cleared": true]
    try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
      .write(to: out.appendingPathComponent("skip.json"))
  }
}
