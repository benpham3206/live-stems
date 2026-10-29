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
  /// Different estimates of the same frames must join once, without returning
  /// to the old estimate at the ready/provisional boundary.
  private static func estimateSeams() throws -> [[String: Any]] {
    var results = [[String: Any]]()
    for count in [4, 6] {
      for late in [false, true] {
        guard let core = ls_create(44100, 44100) else { throw StemError("Seam core unavailable") }
        defer { ls_destroy(core) }
        let pipeline = StemPipeline(core: core)
        pipeline.sourceCount = count
        pipeline.start(generation: 1)
        pipeline.e2eOpenStemGate()
        var committed = [Int: Float]()
        pipeline.onCommit = { start, block in
          for frame in 0..<(block.count / (count * 2 + 3)) {
            committed[start + frame] = block[frame * (count * 2 + 3)]
          }
        }
        func ingest(_ frames: Int) { pipeline.ingest([Float](repeating: 0.4, count: frames * 2)) }
        func estimate(_ job: AudioWindow, _ value: Float) -> StemWindow {
          StemWindow(range: job.range, samples: [Float](repeating: value, count: 44100 * count * 2), sourceCount: count)
        }
        ingest(44100)
        guard let first = pipeline.job() else { throw StemError("Missing first seam job") }
        pipeline.accept(estimate(first, 0.1))
        pipeline.step()
        ingest(pipeline.hop)
        guard let second = pipeline.job() else { throw StemError("Missing second seam job") }
        let boundary = Int(first.range.start) + pipeline.windowFrames - pipeline.rightContext
        if late {
          // Commit 100 frames of the old provisional tail before the result arrives.
          ingest(boundary + 100 + pipeline.lagFrames - pipeline.end)
          pipeline.step()
        }
        let seam = max(boundary, pipeline.outputPosition)
        pipeline.accept(estimate(second, 0.3))
        let coreEnd = Int(second.range.start) + pipeline.windowFrames - pipeline.rightContext
        ingest(coreEnd + pipeline.lagFrames - pipeline.end)
        pipeline.step()
        try require(pipeline.acceptedResults == 2 && pipeline.partialResults == (late ? 1 : 0),
          "Seam fixture did not exercise expected delivery")
        var maximumStep: Float = 0
        for frame in (seam - 1)...(seam + pipeline.fade + 1) {
          guard let previous = committed[frame - 1], let current = committed[frame] else {
            throw StemError("Seam fixture missed committed frame \(frame)")
          }
          maximumStep = max(maximumStep, abs(current - previous))
        }
        try require(maximumStep < 0.001,
          "\(count)-source \(late ? "partly late" : "on-time") estimate seam stepped by \(maximumStep)")
        try require(abs((committed[seam - 1] ?? 0) - 0.1) < 0.00001
          && abs((committed[seam + pipeline.fade] ?? 0) - 0.3) < 0.00001,
          "Estimate seam changed its committed prefix or failed to reach the new estimate")
        // The same boundary must remain smooth when one stem reaches the native output.
        var gains = [Float](repeating: 1, count: count)
        _ = gains.withUnsafeMutableBufferPointer { ls_controls_counted(core, $0.baseAddress, UInt32(count), 0, 1) }
        ls_enable(core, 1)
        var rendered = [Float](repeating: 0, count: coreEnd * 2)
        let got = rendered.withUnsafeMutableBufferPointer { ls_read_mix(core, $0.baseAddress, UInt32(coreEnd)) }
        try require(got == coreEnd, "Solo seam native output lost frames")
        var soloStep: Float = 0
        for frame in (seam - 1)...(seam + pipeline.fade + 1) {
          soloStep = max(soloStep, abs(rendered[frame * 2] - rendered[(frame - 1) * 2]))
        }
        try require(soloStep < 0.001, "Solo native output stepped by \(soloStep)")
        results.append(["sources": count, "partly_late": late, "maximum_step": maximumStep, "solo_output_step": soloStep])
      }
    }
    return results
  }
  static func run(_ out: URL) throws {
    let seams = try estimateSeams()
    try JSONSerialization.data(withJSONObject: seams, options: [.prettyPrinted, .sortedKeys])
      .write(to: out.appendingPathComponent("estimate-seams.json"))
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
