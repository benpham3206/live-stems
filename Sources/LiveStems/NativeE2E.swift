import AVFoundation
import AudioCore
import Darwin
import Foundation

/// Native E2E entry points shared by the stream scenario and recovery checks.
/// The source fixture is decoded at runtime. Prepared stem files never enter
/// the admission path.
enum NativeE2E {
  static func song() throws -> [Float] {
    let path = LocalSettings.root.appendingPathComponent(
      "work/dreamflasher-original.wav").path
    let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
    let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
    guard file.processingFormat.channelCount == 2,
      let source = AVAudioPCMBuffer(
        pcmFormat: file.processingFormat, frameCapacity: UInt32(file.length)),
      let output = AVAudioPCMBuffer(
        pcmFormat: format,
        frameCapacity: UInt32(Double(file.length) * 44100 / file.processingFormat.sampleRate) + 4096
      ), let converter = AVAudioConverter(from: file.processingFormat, to: format)
    else { throw StemError("Reference format invalid") }
    try file.read(into: source)
    var supplied = false
    var error: NSError?
    let state = converter.convert(to: output, error: &error) { _, status in
      if supplied {
        status.pointee = .endOfStream
        return nil
      }
      supplied = true
      status.pointee = .haveData
      return source
    }
    guard state != .error, let channels = output.floatChannelData else {
      throw StemError("Reference conversion failed")
    }
    var data = [Float](repeating: 0, count: Int(output.frameLength) * 2)
    for frame in 0..<Int(output.frameLength) {
      data[frame * 2] = channels[0][frame]
      data[frame * 2 + 1] = channels[1][frame]
    }
    return data
  }

  static func waitStart(_ worker: WorkerClient) throws {
    let sem = DispatchSemaphore(value: 0)
    var response: Result<Void, Error>?
    worker.start {
      response = $0
      sem.signal()
    }
    guard sem.wait(timeout: .now() + 25) == .success else {
      worker.stop()
      throw StemError("Readiness timed out")
    }
    guard let response else { throw StemError("Worker returned no readiness result") }
    try response.get()
  }

  static func separate(
    _ worker: WorkerClient, _ window: AudioWindow, _ job: UInt64
  ) throws -> StemWindow {
    let sem = DispatchSemaphore(value: 0)
    var response: Result<StemWindow, Error>?
    worker.separate(window, jobID: job) {
      response = $0
      sem.signal()
    }
    guard sem.wait(timeout: .now() + 6) == .success else {
      worker.stop()
      throw StemError("Job timed out")
    }
    guard let response else { throw StemError("Worker returned no separation result") }
    return try response.get()
  }

  static func samples(_ source: [Float], start: Int, count: Int) -> [Float] {
    let frames = source.count / 2
    var data = [Float](repeating: 0, count: count * 2)
    for frame in 0..<count {
      let index = ((start + frame) % frames) * 2
      data[frame * 2] = source[index]
      data[frame * 2 + 1] = source[index + 1]
    }
    return data
  }

  static func write(_ samples: [Float], to file: AVAudioFile) throws {
    let frames = samples.count / 2
    guard let buffer = AVAudioPCMBuffer(
      pcmFormat: file.processingFormat, frameCapacity: UInt32(frames)),
      let channels = buffer.floatChannelData
    else { throw StemError("Render format unavailable") }
    buffer.frameLength = UInt32(frames)
    for frame in 0..<frames {
      channels[0][frame] = samples[frame * 2]
      channels[1][frame] = samples[frame * 2 + 1]
    }
    try file.write(from: buffer)
  }

  static func run() throws {
    let args = CommandLine.arguments
    guard let stageIndex = args.firstIndex(of: "--e2e"), stageIndex + 1 < args.count,
      let outputIndex = args.firstIndex(of: "--output"), outputIndex + 1 < args.count
    else { throw StemError("E2E needs --e2e <stream|recovery> --output <directory>") }
    let stage = args[stageIndex + 1]
    let out = URL(fileURLWithPath: args[outputIndex + 1])
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    switch stage {
    case "trace":
      try TraceE2E.run(out)
    case "menu":
      try MenuE2E.run(out)
    case "startup":
      try StartupE2E.run(out)
    case "skip":
      try SkipE2E.run(out)
    case "skip-state":
      try SpotifyStateE2E.run(out)
    case "return":
      try ReturnE2E.run(out)
    case "capture-cut":
      try CaptureCutE2E.run(out)
    case "skip-probe":
      try SkipProbeE2E.run(out)
    case "quit":
      try QuitE2E.run(out)
    case "quit-race":
      try QuitRaceE2E.run(out)
    case "stream":
      try StreamE2E.run(out)
    case "recovery":
      try recovery(out)
    case "sustained":
      throw StemError(
        "Use the live session acceptance monitor for sustained capture; offline E2E is not live acceptance"
      )
    default:
      throw StemError("Unknown native E2E stage: \(stage)")
    }
  }

  private static func recovery(_ out: URL) throws {
    let source = try song()
    let count = min(44_100, source.count / 2)
    let input = samples(source, start: 0, count: count)
    let direct = AudioWindow(
      range: FrameRange(generation: 1, start: 0, count: UInt32(count)), samples: input)

    guard let core = ls_create(44100, 44100) else {
      throw StemError("Cannot allocate recovery audio core")
    }
    defer { ls_destroy(core) }

    let worker = WorkerClient()
    defer { worker.stop() }
    try waitStart(worker)

    // Create an actual in-flight request under generation 2. The generation 1
    // result from the direct worker window must be rejected by accept().
    let oldResult = try separate(worker, direct, 1)
    // The start of the reference contains silence. Use an audible passage
    // for the mix-switch comparison, with its real worker frame range.
    var mixerSamples = [Float]()
    for second in 60..<63 {
      let request = AudioWindow(
        range: FrameRange(generation: 1, start: UInt64(second * 44100), count: UInt32(count)),
        samples: samples(source, start: second * 44100, count: count))
      mixerSamples.append(contentsOf: try separate(worker, request, UInt64(second)).samples)
    }
    let mixerResult = StemWindow(
      range: FrameRange(generation: 1, start: 60 * 44100, count: UInt32(count * 3)),
      samples: mixerSamples)
    let mixerSwitch = try verifyMixerSwitch(source: source, result: mixerResult, out: out)
    let pipeline = StemPipeline(core: core)
    pipeline.start(generation: 2)
    pipeline.observe(
      PlaybackSnapshot(
        trackID: "recovery", title: "Recovery", duration: 60,
        position: 0, isPlaying: true),
      hostTime: stemClock()
    )
    pipeline.ingest(input, hostTime: stemClock())
    pipeline.step()
    guard let request = pipeline.job() else {
      throw StemError("Recovery did not create a direct pipeline request")
    }
    var stale = oldResult
    stale.range = request.range
    stale.range.generation = 1
    let beforeDiscarded = pipeline.discarded
    pipeline.accept(stale)
    guard pipeline.discarded > beforeDiscarded else {
      throw StemError("Old generation result entered the new pipeline")
    }

    // The generation mismatch above leaves the in-flight request intact. Use
    // that exact request with the real worker. This proves that invalidation
    // rejects only the stale result and that the cache can progress afterward.
    let validRequest = request
    let bytesBeforeValid = pipeline.cacheBytes
    let discardedBeforeValid = pipeline.discarded
    let validResult = try separate(worker, validRequest, 4)
    pipeline.accept(validResult)
    guard pipeline.discarded == discardedBeforeValid,
      pipeline.cacheBytes > bytesBeforeValid
    else {
      throw StemError("Matching worker result did not advance the cache after stale rejection")
    }
    let validProgress: [String: Any] = [
      "stale_discarded_before_accept": true,
      "matching_request_generation": validRequest.range.generation,
      "matching_request_frames": validRequest.range.count,
      "cache_bytes_before": bytesBeforeValid,
      "cache_bytes_after": pipeline.cacheBytes,
      "discarded_unchanged": pipeline.discarded == discardedBeforeValid,
    ]

    let exitWorker = WorkerClient()
    try waitStart(exitWorker)
    let exitSem = DispatchSemaphore(value: 0)
    var exitFailure = false
    exitWorker.separate(direct, jobID: 2) { result in
      if case .failure = result { exitFailure = true }
      exitSem.signal()
    }
    exitWorker.stop()
    guard exitSem.wait(timeout: .now() + 6) == .success, exitFailure else {
      throw StemError("Worker termination was not detected")
    }

    let cancelled = WorkerClient()
    cancelled.stop()
    let cancelSem = DispatchSemaphore(value: 0)
    var cancelFailure = false
    cancelled.start {
      if case .failure = $0 { cancelFailure = true }
      cancelSem.signal()
    }
    guard cancelSem.wait(timeout: .now() + 2) == .success, cancelFailure,
      cancelled.pid == 0
    else { throw StemError("Cancelled worker acquired a process") }

    let frozen = WorkerClient()
    defer { frozen.stop() }
    try waitStart(frozen)
    guard kill(frozen.pid, SIGSTOP) == 0 else {
      throw StemError("Cannot freeze owned worker")
    }
    let frozenSem = DispatchSemaphore(value: 0)
    var frozenFailure = false
    let frozenBegan = stemClock()
    frozen.separate(direct, jobID: 3) { result in
      if case .failure = result { frozenFailure = true }
      frozenSem.signal()
    }
    guard frozenSem.wait(timeout: .now() + 6) == .success, frozenFailure,
      stemClock() - frozenBegan < 6
    else { throw StemError("Frozen worker exceeded its bounded deadline") }

    let report: [String: Any] = [
      "status": "pass",
      "direct_window_frames": count,
      "old_generation_discarded": true,
      "discarded_results": pipeline.discarded,
      "worker_exit_detected": true,
      "cancel_before_launch": true,
      "frozen_worker_deadline_seconds": stemClock() - frozenBegan,
      "capture_recovery": "pending_physical_test",
      "mixer_switch": mixerSwitch,
      "valid_matching_progress": validProgress,
    ]
    try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
      .write(to: out.appendingPathComponent("recovery.json"))
    print("PASS recovery · generation, worker exit, cancellation, and bounded freeze")
  }

  private static func verifyMixerSwitch(
    source: [Float], result: StemWindow, out: URL
  ) throws -> [String: Any] {
    let rate = 44_100
    let sourceFrames = source.count / 2
    let sourceStart = Int(result.range.start)
    let resultFrames = Int(result.range.count)
    guard sourceStart >= 0, sourceStart < sourceFrames,
      resultFrames > 0, result.samples.count == resultFrames * 8
    else { throw StemError("Recovery mixer fixture is not frame aligned") }
    let frames = min(resultFrames, sourceFrames - sourceStart, 3 * rate)
    guard frames >= 2 * rate else { throw StemError("Recovery mixer fixture is too short") }

    guard let core = ls_create(Double(rate), Double(rate)) else {
      throw StemError("Cannot allocate mixer switch core")
    }
    defer { ls_destroy(core) }

    // The worker result supplies eight stem channels. The original pair and
    // cache weight use the same frame index, so a toggle cannot hide a clock
    // discontinuity behind a synthetic fixture.
    var blocks = [Float](repeating: 0, count: frames * 11)
    for frame in 0..<frames {
      let sourceIndex = (sourceStart + frame) * 2
      let stemIndex = frame * 8
      let blockIndex = frame * 11
      for channel in 0..<8 { blocks[blockIndex + channel] = result.samples[stemIndex + channel] }
      blocks[blockIndex + 8] = source[sourceIndex]
      blocks[blockIndex + 9] = source[sourceIndex + 1]
      blocks[blockIndex + 10] = 1
    }

    let gains: [Float] = [1, 1, 1, 1]
    gains.withUnsafeBufferPointer { ls_controls(core, $0.baseAddress, 1, 0) }
    ls_enable(core, 1)
    ls_stems(core, 1)
    let written = blocks.withUnsafeBufferPointer {
      ls_output_write(core, $0.baseAddress, UInt32(frames))
    }
    guard written == UInt32(frames) else { throw StemError("Mixer switch output write was short") }
    let underrunsBefore = ls_underruns(core)
    let overflowsBefore = ls_overflows(core)

    func take(_ count: Int, into rendered: inout [Float]) {
      rendered.append(contentsOf: readMix(core, frames: count))
    }
    var rendered = [Float](); rendered.reserveCapacity(frames * 2)
    let prefix = rate / 10
    let toggleFrames = rate / 2
    take(prefix, into: &rendered)
    let offStart = rendered.count / 2
    ls_stems(core, 0)
    take(toggleFrames, into: &rendered)
    let playedAtOff = ls_played(core)
    let onStart = rendered.count / 2
    ls_stems(core, 1)
    take(toggleFrames, into: &rendered)
    let renderedFrames = rendered.count / 2
    guard renderedFrames == prefix + toggleFrames * 2 else {
      throw StemError("Mixer switch rendered frame count changed")
    }

    let underruns = ls_underruns(core) - underrunsBefore
    let overflows = ls_overflows(core) - overflowsBefore
    let expectedPlayedAtOff = UInt64(prefix + toggleFrames)
    let played = ls_played(core)
    guard playedAtOff == expectedPlayedAtOff, played == UInt64(renderedFrames),
      underruns == 0, overflows == 0
    else { throw StemError("Mixer switch lost queued frames or underrun-free playback") }

    let settle = rate / 50 // 20 ms; the C mixer ramp is 8 ms.
    let compareStart = offStart + settle
    let compareEnd = min(onStart, compareStart + rate / 10)
    guard compareStart < compareEnd else { throw StemError("Mixer original comparison window is empty") }
    func limited(_ left: Float, _ right: Float, original: (Float, Float)) -> (Float, Float) {
      var l = left, r = right
      let peak = max(abs(l), abs(r))
      let ceiling = max(0.98, abs(original.0), abs(original.1))
      if peak > ceiling {
        let gain = ceiling / peak
        l *= gain; r *= gain
      }
      return (l, r)
    }
    var originalEnergy = 0.0, originalErrorEnergy = 0.0, maxOriginalError = 0.0
    var stemEnergy = 0.0, stemErrorEnergy = 0.0, maxStemError = 0.0
    var exactChecks = 0
    for frame in compareStart..<compareEnd {
      let sourceIndex = (sourceStart + frame) * 2
      let expectedOriginal = (source[sourceIndex], source[sourceIndex + 1])
      let onFrame = onStart + settle + (frame - compareStart)
      let stemIndex = onFrame * 8
      let onSource = (sourceStart + onFrame) * 2
      // Other retains the reconstruction residual. Muting vocals therefore
      // yields Original minus the vocal estimate at this same source frame.
      let expectedStems = limited(
        source[onSource] - result.samples[stemIndex],
        source[onSource + 1] - result.samples[stemIndex + 1],
        original: (source[onSource], source[onSource + 1]))
      for channel in 0..<2 {
        let actual = Double(rendered[frame * 2 + channel])
        let original = Double(channel == 0 ? expectedOriginal.0 : expectedOriginal.1)
        let stems = Double(channel == 0 ? expectedStems.0 : expectedStems.1)
        // The source and worker frames share the same input index. These
        // comparisons therefore catch a one-frame shift as well as a jump.
        if frame < onStart {
          originalEnergy += original * original
          originalErrorEnergy += (actual - original) * (actual - original)
          maxOriginalError = max(maxOriginalError, abs(actual - original))
        }
        if onFrame < renderedFrames {
          let switched = Double(rendered[onFrame * 2 + channel])
          stemEnergy += stems * stems
          stemErrorEnergy += (switched - stems) * (switched - stems)
          maxStemError = max(maxStemError, abs(switched - stems))
        }
        exactChecks += 1
      }
    }
    guard originalEnergy > 1e-5, stemEnergy > 1e-5 else {
      throw StemError("Mixer original or worker stem fixture is silent")
    }
    let originalRelativeError = originalErrorEnergy / originalEnergy
    let stemRelativeError = stemErrorEnergy / stemEnergy

    func step(at frame: Int) -> Double {
      guard frame > 0 else { return 0 }
      var largest = 0.0
      for channel in 0..<2 {
        largest = max(largest, abs(Double(rendered[frame * 2 + channel])
          - Double(rendered[(frame - 1) * 2 + channel])))
      }
      return largest
    }
    let offStep = step(at: offStart)
    let onStep = step(at: onStart)
    let maxSwitchStep = max(offStep, onStep)
    let maxOutput = rendered.reduce(0.0) { max($0, abs(Double($1))) }
    let finite = rendered.allSatisfy(\.isFinite)
    let sourcePeak = blocks.enumerated().filter { $0.offset % 11 == 8 || $0.offset % 11 == 9 }
      .reduce(0.0) { max($0, abs(Double($1.element))) }
    let processedPeak = rendered[(onStart + settle) * 2..<rendered.count]
      .reduce(0.0) { max($0, abs(Double($1))) }
    guard finite, maxOutput <= max(sourcePeak, 0.98) + 1e-6,
      processedPeak <= 0.981, originalRelativeError <= 1e-10,
      maxOriginalError <= 1e-6, stemRelativeError <= 1e-6,
      maxStemError <= 1e-5, maxSwitchStep < 0.35
    else { throw StemError("Mixer switch failed finite, original, limiter, or step checks") }

    let switchFile = try AVAudioFile(
      forWriting: out.appendingPathComponent("recovery-switch.wav"),
      settings: AVAudioFormat(standardFormatWithSampleRate: Double(rate), channels: 2)!.settings)
    try write(rendered, to: switchFile)

    // Reset must clear the old queue. A flush after a new stale write must
    // prime the callback and return silence instead of replaying that write.
    let queuedBeforeReset = ls_queued(core)
    guard queuedBeforeReset > 0 else { throw StemError("Mixer reset fixture drained its queued signal") }
    ls_reset(core)
    ls_enable(core, 1)
    ls_stems(core, 1)
    guard ls_queued(core) == 0 else { throw StemError("Mixer reset retained queued audio") }
    let playedAfterReset = ls_played(core)
    let resetProbe = readMix(core, frames: rate / 10)
    let resetNoStale = resetProbe.allSatisfy { abs($0) < 1e-7 }
      && ls_queued(core) == 0 && ls_played(core) == playedAfterReset
    guard resetNoStale else { throw StemError("Mixer reset returned stale audio") }

    // Flush an empty queue first. The short write after this boundary must
    // remain queued while the callback waits for its 50 ms prime.
    ls_flush_output(core)
    var short = [Float](repeating: 0, count: 441 * 11)
    for frame in 0..<441 {
      short[frame * 11 + 8] = 0.75
      short[frame * 11 + 9] = -0.75
    }
    let shortWrite = short.withUnsafeBufferPointer {
      ls_output_write(core, $0.baseAddress, 441)
    }
    guard shortWrite == 441 else { throw StemError("Mixer short-prime fixture write was short") }
    let playedBeforeShort = ls_played(core)
    let shortProbe = readMix(core, frames: 441)
    let shortHeld = shortProbe.allSatisfy { abs($0) < 1e-7 }
      && ls_played(core) == playedBeforeShort && ls_queued(core) == 441
    guard shortHeld else { throw StemError("Mixer empty flush consumed a short unprimed block") }

    var prime = [Float](repeating: 0, count: 2_205 * 11)
    for frame in 0..<2_205 {
      prime[frame * 11 + 8] = 0.25
      prime[frame * 11 + 9] = -0.25
    }
    let primeWrite = prime.withUnsafeBufferPointer {
      ls_output_write(core, $0.baseAddress, 2_205)
    }
    guard primeWrite == 2_205 else { throw StemError("Mixer prime fixture write was short") }
    let resumedProbe = readMix(core, frames: 441)
    let resumed = ls_played(core) > playedBeforeShort
      && resumedProbe.contains { abs($0) > 1e-6 }
    guard resumed else { throw StemError("Mixer did not resume after sufficient prime") }
    let finalUnderruns = ls_underruns(core)

    return [
      "frames": frames,
      "source_start_frame": sourceStart,
      "original_compare_start_frame": compareStart,
      "original_compare_end_frame": compareEnd,
      "exact_original_sample_checks": exactChecks,
      "original_relative_error": originalRelativeError,
      "original_max_abs_error": maxOriginalError,
      "stem_relative_error": stemRelativeError,
      "stem_max_abs_error": maxStemError,
      "toggle_off_frame": offStart,
      "toggle_on_frame": onStart,
      "rendered_frames": renderedFrames,
      "played_at_toggle_off": playedAtOff,
      "played_final": played,
      "underruns": underruns,
      "overflows": overflows,
      "max_switch_step": maxSwitchStep,
      "max_output_abs": maxOutput,
      "source_peak": sourcePeak,
      "processed_peak": processedPeak,
      "queued_before_reset": queuedBeforeReset,
      "finite": finite,
      "reset_clears_stale": resetNoStale,
      "empty_flush_holds_short_write": shortHeld,
      "empty_flush_resumes_after_prime": resumed,
      "post_flush_underruns": finalUnderruns - underrunsBefore,
      "rendered_wav": "recovery-switch.wav",
    ]
  }

  private static func readMix(_ core: OpaquePointer, frames: Int) -> [Float] {
    var samples = [Float](repeating: 0, count: frames * 2)
    _ = samples.withUnsafeMutableBufferPointer {
      ls_read_mix(core, $0.baseAddress, UInt32(frames))
    }
    return samples
  }

}
