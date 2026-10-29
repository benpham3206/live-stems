import AudioCore
import Foundation

/// Offline checks at the worker packet and capture-frame boundaries.
enum SixSourceE2E {
  private static func require(_ value: Bool, _ message: String) throws {
    guard value else { throw StemError(message) }
  }
  private static func rejects(_ name: String, _ operation: () throws -> Void) throws {
    do { try operation() } catch { return }
    throw StemError("Six-source boundary accepted \(name)")
  }
  static func run(_ out: URL) throws {
    var controls = StemControls()
    controls.resize(to: 6)
    controls.gains[4] = 0.4; controls.gains[5] = 0.6
    controls.mute = 16; controls.solo = 32
    controls.resize(to: 6)
    try require(controls.gains[4] == 0.4 && controls.gains[5] == 0.6 && controls.mute == 16 && controls.solo == 32,
      "Same-model attachment reset guitar/piano controls")
    controls.resize(to: 4); controls.resize(to: 6)
    try require(controls.gains == [1, 1, 1, 1, 1, 1] && controls.mute == 0 && controls.solo == 0,
      "Four-source return retained inactive controls")

    var header = Data("LSTM".utf8)
    header.appendLE(UInt16(1)); header.appendLE(UInt16(3))
    header.appendLE(UInt64(1)); header.appendLE(UInt64(2)); header.appendLE(UInt64(0))
    header.appendLE(UInt32(44100)); header.appendLE(UInt32(1))
    header.appendLE(UInt16(2)); header.appendLE(UInt16(6)); header.appendLE(UInt32(48))
    let window = AudioWindow(range: FrameRange(generation: 1, start: 0, count: 1), samples: [0, 0])
    let values = [Float](repeating: 0.1, count: 12)
    let body = values.withUnsafeBytes { Data($0) }
    _ = try WorkerClient.decodeResponse(header, data: body, window: window, jobID: 2, model: .sixSource)
    var wrongCount = header; wrongCount[42] = 4
    try rejects("wrong stem count") { _ = try WorkerClient.decodeResponse(wrongCount, data: body, window: window, jobID: 2, model: .sixSource) }
    try rejects("short payload") { _ = try WorkerClient.decodeResponse(header, data: body.dropLast(4), window: window, jobID: 2, model: .sixSource) }
    var badValues = values; badValues[11] = .nan
    try rejects("nonfinite payload") { _ = try WorkerClient.decodeResponse(header, data: badValues.withUnsafeBytes { Data($0) }, window: window, jobID: 2, model: .sixSource) }
    var readyHeader = header; readyHeader[6] = 1
    func readiness(_ sources: [String]) throws -> Data {
      try JSONSerialization.data(withJSONObject: ["model": "htdemucs_6s", "sources": sources, "window_frames": 44100])
    }
    _ = try WorkerClient.readyModel(header: readyHeader, body: readiness(StemModel.sixSource.sources))
    try rejects("wrong source order") { _ = try WorkerClient.readyModel(header: readyHeader, body: readiness(StemModel.sixSource.sources.reversed())) }

    guard let core = ls_create(44100 * 4, 44100 * 4) else { throw StemError("Six-source core unavailable") }
    defer { ls_destroy(core) }
    let pipeline = StemPipeline(core: core)
    pipeline.sourceCount = 6
    pipeline.start(generation: 1)
    pipeline.e2eOpenStemGate()
    var checked = 0
    pipeline.onCommit = { _, block in
      for frame in 0..<(block.count / 15) where block[frame * 15 + 14] > 0.999 {
        for channel in 0..<12 {
          if abs(block[frame * 15 + channel] - Float(channel / 2 + 1) * 0.01) > 0.00001 { checked = -1000000 }
        }
        checked += 1
      }
    }
    for _ in 0..<30 {
      pipeline.ingest([Float](repeating: 0.21, count: 8820))
      if let job = pipeline.job() {
        let samples = (0..<(44100 * 12)).map { Float(($0 % 12) / 2 + 1) * 0.01 }
        pipeline.accept(StemWindow(range: job.range, samples: samples, sourceCount: 6))
      }
      pipeline.step()
    }
    try require(checked > 0, "Six-source pipeline did not preserve canonical channel routing")
    pipeline.start(generation: 2)
    pipeline.ingest([Float](repeating: 0.21, count: 88200))
    pipeline.takeOverAtBreak(fadeIn: true)
    var dipChecked = false
    pipeline.onCommit = { _, block in
      if !block.isEmpty { dipChecked = abs(block[12] - 0.21 / 2205) < 0.000001 && abs(block[13] - 0.21 / 2205) < 0.000001
          && abs(block[15 + 12] - 0.42 / 2205) < 0.000001 }
    }
    pipeline.ingest([Float](repeating: 0.21, count: 26460))
    pipeline.step()
    try require(dipChecked, "Six-source takeover failed to fade Original channels")
    try Data("PASS controls, malformed worker packets, six-channel pipeline routing, and takeover fade\n".utf8)
      .write(to: out.appendingPathComponent("six-source.txt"))
    print("PASS six-source")
  }
}
