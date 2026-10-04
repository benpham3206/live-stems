import AudioCore
import AVFoundation
import Foundation

enum CaptureCutE2E {
  static func run(_ out: URL) throws {
    let actual = try AudioSession(), reference = try AudioSession()
    defer { actual.stop(); reference.stop() }
    guard actual.rate == reference.rate else { throw StemError("Capture formats differ") }
    let boundary = stemClock()
    func inject(_ session: AudioSession, _ samples: [Float], _ start: Double) {
      var stamp = AudioTimeStamp()
      stamp.mFlags = .hostTimeValid
      stamp.mHostTime = AVAudioTime.hostTime(forSeconds: start)
      samples.withUnsafeBytes { data in
        var list = AudioBufferList(mNumberBuffers: 1,
          mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(data.count),
            mData: UnsafeMutableRawPointer(mutating: data.baseAddress)))
        var output = list
        _ = ls_capture_callback(0, &stamp, &list, &stamp, &output, &stamp, UnsafeMutableRawPointer(session.core))
      }
    }
    actual.discardCapturedAudio(at: boundary)
    // This producer starts AFTER the cut, but its input is an older hardware
    // block. The CAS publication guard correctly allows this callback.
    inject(actual, [Float](repeating: 0.4, count: 600 * 2), boundary - 0.05)
    let old = try actual.drain()
    let fresh = [Float](repeating: -0.25, count: 2400 * 2)
    let crossing = [Float](repeating: 0.4, count: 1200 * 2) + fresh
    inject(actual, crossing, boundary - 1200 / actual.rate)
    inject(reference, fresh, boundary)
    let rendered = try actual.drain(), expected = try reference.drain()
    let count = min(rendered.count, expected.count)
    guard count >= 2000 else { throw StemError("Capture cut did not resume enough fresh samples") }
    let error = zip(rendered.prefix(count), expected.prefix(count)).map { abs($0 - $1) }.max() ?? 0
    for (name, samples) in [("captured.wav", rendered), ("expected.wav", expected)] {
      let file = try AVAudioFile(forWriting: out.appendingPathComponent(name),
        settings: AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!.settings)
      try NativeE2E.write(samples, to: file)
    }
    let passed = old.isEmpty && error < 1e-6
    let report: [String: Any] = ["status": passed ? "pass" : "fail",
      "pre_boundary_output_samples": old.count, "compared_samples": count,
      "max_sample_error": error, "capture_rate": actual.rate,
      "crossing_block_converted_frames": rendered.count / 2,
      "scope": "actual native capture callback and AudioSession converter; hardware input dates injected"]
    try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
      .write(to: out.appendingPathComponent("capture-cut.json"))
    guard passed else { throw StemError("Post-cut callback admitted old dated audio: \(old.count) samples, error \(error)") }
  }
}
