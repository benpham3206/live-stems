import AudioCore
import AVFoundation
import CoreAudio
import Foundation

enum TraceE2E {
  static func run(_ out: URL) throws {
    guard let core = ls_create(44100, 44100) else { throw StemError("Trace core unavailable") }
    defer { ls_destroy(core) }
    ls_enable(core, 1)
    var samples = [Float](repeating: 0, count: 4410 * 11)
    for frame in 0..<4410 {
      samples[frame * 11 + 8] = Float(frame) / 44100
      samples[frame * 11 + 9] = -samples[frame * 11 + 8]
      samples[frame * 11 + 10] = 1
    }
    let captureEnd = 100.1
    _ = samples.withUnsafeBufferPointer {
      ls_output_write_timed(core, $0.baseAddress, 4410, 50000, captureEnd)
    }
    var rendered = [Float](repeating: 0, count: 2205 * 2)
    func render(at seconds: Double) {
      var time = AudioTimeStamp()
      time.mHostTime = AVAudioTime.hostTime(forSeconds: seconds)
      time.mFlags = .hostTimeValid
      rendered.withUnsafeMutableBytes { data in
        var list = AudioBufferList(mNumberBuffers: 1,
          mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(data.count), mData: data.baseAddress))
        ls_render_timed(core, 2205, &list, &time)
      }
    }
    render(at: 100.35)
    guard ls_rendered_source_frame(core) == 52204 else { throw StemError("Rendered trace has wrong source frame") }
    let captureHost = Double(ls_rendered_capture_nanos(core)) / 1e9
    var snapshot = LSRenderSnapshot()
    guard ls_render_snapshot(core, &snapshot) != 0,
      snapshot.source_frame == 52204,
      abs(Double(snapshot.render_nanos - snapshot.capture_nanos) / 1e9 - 0.35) < 1e-8 else {
      throw StemError("Render callback did not publish a coherent source/host snapshot")
    }
    guard abs(captureHost - (100 + 2204.0 / 44100)) < 1e-8 else {
      throw StemError("Trace capture host timestamp does not follow source frame")
    }
    ls_stems(core, 0)
    render(at: 100.4)
    guard ls_rendered_source_frame(core) == 54409 else { throw StemError("Original switch changed trace timeline") }

    let pipeline = StemPipeline(core: core)
    var captured = [Float](repeating: 0.75, count: 4096 * 2)
    var stamp = AudioTimeStamp()
    captured.withUnsafeMutableBytes { data in
      var list = AudioBufferList(mNumberBuffers: 1,
        mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(data.count), mData: data.baseAddress))
      var output = list
      _ = ls_capture_callback(0, &stamp, &list, &stamp, &output, &stamp, UnsafeMutableRawPointer(core))
    }
    pipeline.start(generation: 7)
    let discardedStartup = captured.withUnsafeMutableBufferPointer {
      ls_capture_read(core, $0.baseAddress, 4096)
    }
    guard discardedStartup == 0 else { throw StemError("Startup admitted pre-clock captured backlog") }
    pipeline.ingest([Float](repeating: 0.1, count: 44100 * 2), hostTime: 200)
    pipeline.step()
    guard let oldJob = pipeline.job() else { throw StemError("Reset fixture lacks in-flight work") }
    let position = pipeline.outputPosition, queued = ls_queued(core), capture = pipeline.end
    pipeline.resetProcessor()
    guard pipeline.outputPosition == position, ls_queued(core) == queued, pipeline.end == capture,
      pipeline.generation != oldJob.range.generation else {
      throw StemError("Processor-only reset changed audio clock or kept old generation")
    }
    guard let newJob = pipeline.job() else { throw StemError("Processor-only reset cannot resume") }
    pipeline.accept(StemWindow(range: oldJob.range, samples: [Float](repeating: 0.01, count: 44100 * 8)))
    guard pipeline.discarded == 1, pipeline.cacheBytes == 0 else { throw StemError("Reset accepted old processor result") }
    pipeline.accept(StemWindow(range: newJob.range, samples: [Float](repeating: 0.01, count: 44100 * 8)))
    guard pipeline.acceptedResults == 1 else { throw StemError("Reset blocked matching new result") }
    // Hardware blocks seldom land on a 100 ms grid. A slow callback must not
    // make the next usable core lose an entire rounded hop.
    pipeline.ingest([Float](repeating: 0.1, count: 5003 * 2), hostTime: 200.113446)
    guard let irregular = pipeline.job(), irregular.range.start == 5003 else {
      throw StemError("Next window rounded away real captured frames")
    }
    var admitted: TraceRecord?
    pipeline.onTrace = { if $0.event == "accepted-result" { admitted = $0 } }
    pipeline.accept(StemWindow(range: irregular.range, samples: [Float](repeating: 0.01, count: 44100 * 8)))
    guard admitted?.sourceFrame == 41895, admitted?.sourceEnd == 46898 else {
      throw StemError("Irregular result lost source coverage between consecutive windows")
    }
    var lastCoveredWeight: Float = 0
    pipeline.onCommit = { _, block in lastCoveredWeight = block.last ?? 0 }
    pipeline.ingest([Float](repeating: 0.1, count: 9250 * 2), hostTime: 200.323197)
    pipeline.step()
    guard lastCoveredWeight == 1 else { throw StemError("Covered range leaked Original before its end") }

    let trace = LiveTrace(directory: out, fileLimit: 8192)
    for index in 0..<2000 {
      trace.record(TraceRecord(event: "sample", generation: 1, sourceFrame: index,
        renderedFrame: UInt64(index)))
      if index % 32 == 31 { trace.flushSync() }
    }
    trace.record(TraceRecord(event: "mix", generation: 1, sourceFrame: 54410))
    trace.flushSync()
    var parsed = 0, totalBytes = 0
    for name in ["live-trace.jsonl", "live-trace.previous.jsonl"] {
      let data = try Data(contentsOf: out.appendingPathComponent(name))
      totalBytes += data.count
      guard data.count <= 8192 else { throw StemError("Trace rotation exceeded limit") }
      for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
        let value = try JSONDecoder().decode(TraceRecord.self, from: Data(line.utf8))
        if value.event == "sample", value.sourceFrame != value.renderedFrame.map(Int.init) {
          throw StemError("Trace serialized the wrong source frame")
        }
        parsed += 1
      }
    }
    guard parsed > 10 else { throw StemError("Trace did not save verifiable records") }
    let report: [String: Any] = ["status": "pass", "parsed_records": parsed,
      "rotated_bytes": totalBytes, "rendered_frame_after_original_switch": ls_rendered_source_frame(core),
      "capture_timestamp_error_seconds": abs(captureHost - (100 + 2204.0 / 44100)),
      "processor_reset_preserves_position_and_queue": true,
      "startup_discards_pre_clock_capture": true,
      "processor_reset_rejects_stale_and_accepts_new": true,
      "irregular_capture_keeps_contiguous_usable_range": true,
      "covered_range_does_not_fade_to_original_early": true,
      "scope": "native output timeline and bounded log writer; live capture remains separate"]
    try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
      .write(to: out.appendingPathComponent("trace.json"))
  }
}
