import AVFoundation
import AudioCore
import Foundation

/// A paced, short-window acceptance run for the live worker path.
///
/// This scenario uses only NativeE2E's decoded source and WorkerClient. It
/// records the capture-frame contract at the pipeline commit boundary, then
/// checks the rendered stream at its fixed producer and native queue delay.
/// Prepared stem files never enter this path.
enum StreamE2E {
  private static let rate = 44_100
  private static let tickFrames = 441
  private static let tickSeconds = Double(tickFrames) / Double(rate)
  private static let totalSeconds = 40
  private static let windowFrames = 44_100
  private static let hopFrames = 4_410
  private static let rightContextFrames = 2_205
  private static let producerLagFrames = 11_466
  private static let nativeQueueFrames = 4 * tickFrames
  private static let waveformOffsetFrames = producerLagFrames + nativeQueueFrames
  private static let waveformToleranceFrames = 132
  private static let historyLimitFrames = 3 * rate
  private static let cacheLimitBytes = 8 * 1024 * 1024
  private static let holdSeconds = 0.25
  private static let pauseTailLimitFrames = Int(0.33 * Double(rate))

  private struct Track {
    let id: String
    let title: String
    let duration: Double
    let sourceOffset: Int
  }

  private struct State {
    let track: Track
    let position: Double
    let isPlaying: Bool
    let phase: String
  }

  private struct Observation {
    let wall: Double
    let phase: String
    let trackID: String
    let position: Double
    let playing: Bool
    let lag: Int
    let jumps: Int
    let weight: Double
    let output: Int
    let end: Int
    let base: Int
    let paused: Bool
    let underruns: UInt64
    let played: UInt64
  }

  private struct PacketSample {
    let jobID: UInt64
    let seconds: Double
  }

  private struct Packet {
    let jobID: UInt64
    let result: Result<StemWindow, Error>
    let seconds: Double
  }

  private final class PacketBox {
    private let lock = NSLock()
    private var pending: Packet?
    private var samples = [PacketSample]()

    func put(_ packet: Packet) {
      lock.lock()
      pending = packet
      samples.append(PacketSample(jobID: packet.jobID, seconds: packet.seconds))
      lock.unlock()
    }

    func take() -> Packet? {
      lock.lock()
      defer { lock.unlock() }
      let packet = pending
      pending = nil
      return packet
    }

    func timingSamples() -> [PacketSample] {
      lock.lock()
      defer { lock.unlock() }
      return samples
    }
  }

  private final class Probe {
    var failure: String?
    var workerError: String?
    var committedFrames = 0
    var fallbackFrames = 0
    var stemFrames = 0
    var nonFiniteBlocks = 0
    var outOfBoundsBlocks = 0
    var unanchoredBlocks = 0
    var commitOriginalChecks = 0
    var commitOriginalMismatches = 0
    var commitOriginalMaxError = 0.0
    var commitStarts = [Int]()
    var commitEnds = [Int]()
    var backwardCommits = 0
    var overlappingCommits = 0
    var maximumBlockPeak: Float = 0
    var firstStemWall: Double?
    var recoveryStemWall: Double?
    var heldFallbackFrames = 0
    var holdRequested = false
    var holdStarted = false
    var holdReleased = false
    var holdDiscarded = false
    var holdJobID: UInt64?
    var holdStartedHost: Double?
    var holdWall: Double?
    var holdReleaseWall: Double?
    var staleInjected = false
    var staleRejected = false
    var contextResetWalls = [Double]()
    var observations = [Observation]()
    var rendered = [Float]()
    var expected = [Float]()
    var captured = [Float]()
    var readFrames = 0
    var readGotFrames = 0
    var pausePlayedFrames = 0
    var pauseUnderruns: UInt64 = 0
    var continuousUnderruns: UInt64 = 0
    var allowedUnderruns = [[String: Any]]()
    var fixture = [Float]()
    var packetSamples = [PacketSample]()
    var warmups = [[String: Any]]()
    var commitJSONLines = 0
  }

  private static let trackA = Track(
    id: "stream-a", title: "Dreamflasher A", duration: 31, sourceOffset: 60 * rate)
  private static let trackB = Track(
    id: "stream-b", title: "Dreamflasher B", duration: 20, sourceOffset: 100 * rate)
  private static let trackC = Track(
    id: "stream-c", title: "Dreamflasher C", duration: 20, sourceOffset: 180 * rate)

  private static let failureScenarios = [
    "first-listen stems from an unseen source passage",
    "global-frame Original commits and fixed rendered waveform delay",
    "seek-back, unseen seek-forward, and frontier fallback",
    "pause drain and resume without capture-clock movement",
    "natural and manual track changes with no old-track stem mix",
    "real result held beyond its output deadline and fresh recovery",
    "stale generation injection leaves the matching request available",
    "neutral reconstruction, BassSolo, all-stem mute, and limiter",
    "finite output, bounded history/cache, timing, and underrun envelope",
  ]

  static func run(_ out: URL) throws {
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    var report: [String: Any] = [
      "status": "fail",
      "failure_scenarios": failureScenarios,
      "source": "NativeE2E.song()/samples() plus one real WorkerClient",
      "rate": rate,
      "window_frames": windowFrames,
      "hop_frames": hopFrames,
      "right_context_frames": rightContextFrames,
      "producer_lag_frames": producerLagFrames,
      "waveform_offset_frames": waveformOffsetFrames,
    ]
    do {
      let outcome = try execute(out)
      report = outcome.report
      try writeReport(report, to: out)
      guard outcome.failures.isEmpty else {
        throw StemError("Stream E2E failed: \(outcome.failures.joined(separator: "; "))")
      }
      print("PASS stream · \(outcome.report["committed_frames"] ?? 0) committed frames")
    } catch {
      report["reason"] = error.localizedDescription
      try? writeReport(report, to: out)
      throw error
    }
  }

  private static func execute(_ out: URL) throws -> (report: [String: Any], failures: [String]) {
    let source = try NativeE2E.song()
    let sourceFrames = source.count / 2
    let required = max(trackA.sourceOffset + 31 * rate,
      max(trackB.sourceOffset + 6 * rate, trackC.sourceOffset + 16 * rate))
    guard sourceFrames > required else {
      throw StemError("Stream fixture is shorter than its distinct source passages")
    }

    let commitURL = out.appendingPathComponent("stream-commits.bin")
    let recordsURL = out.appendingPathComponent("stream-commits.jsonl")
    FileManager.default.createFile(atPath: commitURL.path, contents: nil)
    FileManager.default.createFile(atPath: recordsURL.path, contents: nil)
    let commitFile = try FileHandle(forWritingTo: commitURL)
    let recordsFile = try FileHandle(forWritingTo: recordsURL)
    defer {
      try? commitFile.close()
      try? recordsFile.close()
    }

    guard let core = ls_create(Double(rate), Double(rate)) else {
      throw StemError("Cannot allocate stream E2E audio core")
    }
    defer { ls_destroy(core) }
    let worker = WorkerClient()
    defer { worker.stop() }
    try NativeE2E.waitStart(worker)

    let probe = Probe()
    let renderEvidence = StreamRenderEvidence(rate: rate, offset: waveformOffsetFrames)
    let pipeline = StemPipeline(core: core)
    let packetBox = PacketBox()
    var capture = [Float]()
    capture.reserveCapacity(totalSeconds * rate * 2)
    var currentWall = 0.0
    var inFlight = false
    var held: Packet?
    var jobID: UInt64 = 0
    var previousState: State?
    var previousUnderruns = ls_underruns(core)
    var pauseUnderrunStart: UInt64?
    var pausePlayedStart: UInt64?
    var holdRecoveryBoundary: Double?
    var hostStart = stemClock()

    pipeline.onFailure = { message in
      probe.failure = message
    }
    pipeline.onCommit = { start, block in
      let frames = block.count / 11
      probe.committedFrames += frames
      renderEvidence.record(start: start, block: block)
      commitFile.write(block.withUnsafeBytes { Data($0) })
      probe.commitJSONLines += 1
      if let prior = probe.commitStarts.last {
        if start < prior { probe.backwardCommits += 1 }
      }
      if let priorEnd = probe.commitEnds.last, start < priorEnd {
        probe.overlappingCommits += 1
      }
      probe.commitStarts.append(start)
      probe.commitEnds.append(start + frames)

      var anchored = start >= 0 && start + frames <= capture.count / 2
      var blockOriginalError = 0.0
      if anchored {
        for frame in 0..<frames {
          let at = frame * 11
          let captureAt = (start + frame) * 2
          let leftError = abs(Double(block[at + 8] - capture[captureAt]))
          let rightError = abs(Double(block[at + 9] - capture[captureAt + 1]))
          blockOriginalError = max(blockOriginalError, max(leftError, rightError))
          probe.commitOriginalChecks += 2
          if leftError > 1e-6 || rightError > 1e-6 {
            anchored = false
            probe.commitOriginalMismatches += 1
          }
        }
      }
      probe.commitOriginalMaxError = max(probe.commitOriginalMaxError, blockOriginalError)
      if !anchored {
        if start < 0 || start + frames > capture.count / 2 {
          probe.outOfBoundsBlocks += 1
        } else {
          probe.unanchoredBlocks += 1
        }
      }

      var finite = true
      for frame in 0..<frames {
        let at = frame * 11
        let weight = block[at + 10]
        if !weight.isFinite || weight < 0 || weight > 1 { finite = false }
        if weight < 0.001 {
          probe.fallbackFrames += 1
          if probe.holdStarted && !probe.holdReleased { probe.heldFallbackFrames += 1 }
        }
        if weight > 0.9 {
          probe.stemFrames += 1
          if probe.firstStemWall == nil { probe.firstStemWall = currentWall }
          if let boundary = holdRecoveryBoundary, probe.recoveryStemWall == nil,
            currentWall > boundary
          {
            probe.recoveryStemWall = currentWall
          }
          if weight == 1 && probe.fixture.count < 2 * rate * 11 {
            probe.fixture.append(contentsOf: block[at..<(at + 11)])
          }
        }
        for channel in 0..<11 {
          let value = block[at + channel]
          if !value.isFinite { finite = false }
          if channel < 10 { probe.maximumBlockPeak = max(probe.maximumBlockPeak, abs(value)) }
        }
      }
      if !finite { probe.nonFiniteBlocks += 1 }

      let record: [String: Any] = [
        "start_frame": start,
        "count": frames,
        "original_aligned": anchored,
        "original_max_abs_error": blockOriginalError,
        "min_weight": frames == 0 ? 0.0 : (0..<frames).map { Double(block[$0 * 11 + 10]) }.min()!,
        "max_weight": frames == 0 ? 0.0 : (0..<frames).map { Double(block[$0 * 11 + 10]) }.max()!,
        "wall_seconds": currentWall,
      ]
      if let data = try? JSONSerialization.data(withJSONObject: record) {
        recordsFile.write(data)
        recordsFile.write(Data([10]))
      }
    }

    pipeline.start(generation: 1)
    ls_enable(core, 1)
    let warmupOffsets = [trackA.sourceOffset, trackB.sourceOffset, trackC.sourceOffset]
    for (index, offset) in warmupOffsets.enumerated() {
      let window = AudioWindow(
        range: FrameRange(generation: 99, start: UInt64(offset), count: UInt32(windowFrames)),
        samples: NativeE2E.samples(source, start: offset, count: windowFrames))
      let began = stemClock()
      let result = try NativeE2E.separate(worker, window, UInt64(index + 1))
      let elapsed = stemClock() - began
      guard result.samples.count == windowFrames * 8,
        result.samples.allSatisfy(\.isFinite)
      else { throw StemError("Stream worker warmup returned an invalid stem window") }
      probe.warmups.append([
        "job": index + 1, "source_start_frame": offset,
        "seconds": elapsed, "finite": true, "frames": windowFrames,
      ])
    }

    hostStart = stemClock()
    let totalTicks = totalSeconds * rate / tickFrames
    for tick in 0..<totalTicks {
      currentWall = Double(tick * tickFrames) / Double(rate)
      let hostTime = hostStart + currentWall
      let state = state(at: currentWall)
      if tick == 5 * rate / tickFrames || tick == 6 * rate / tickFrames {
        [Float](repeating: 1, count: 4).withUnsafeBufferPointer { ls_controls(core, $0.baseAddress, 0, 4) }
        ls_stems(core, currentWall < 6 ? 1 : 0)
      } else if tick == 26 * rate / tickFrames || tick == 27 * rate / tickFrames {
        [Float](repeating: 1, count: 4).withUnsafeBufferPointer { ls_controls(core, $0.baseAddress, 15, 0) }
        ls_stems(core, currentWall < 27 ? 1 : 0)
      } else if tick == 7 * rate / tickFrames || tick == 28 * rate / tickFrames {
        [Float](repeating: 1, count: 4).withUnsafeBufferPointer { ls_controls(core, $0.baseAddress, 0, 0) }
        ls_stems(core, 1)
      }
      let boundary = previousState.map { old in
        old.track.id != state.track.id || old.isPlaying != state.isPlaying
          || abs(old.position - state.position) > 1.0
      } ?? true
      if boundary { probe.contextResetWalls.append(currentWall) }
      pipeline.observe(
        PlaybackSnapshot(
          trackID: state.track.id, title: state.track.title, duration: state.track.duration,
          position: state.position, isPlaying: state.isPlaying),
        hostTime: hostTime)
      previousState = state

      if state.isPlaying {
        let start = state.track.sourceOffset + Int(state.position * Double(rate))
        let part = NativeE2E.samples(source, start: start, count: tickFrames)
        capture.append(contentsOf: part)
        probe.captured.append(contentsOf: part)
        probe.expected.append(contentsOf: part)
        pipeline.ingest(part, hostTime: hostTime + tickSeconds)
      } else {
        let silence = [Float](repeating: 0, count: tickFrames * 2)
        probe.expected.append(contentsOf: silence)
        pipeline.ingest([], hostTime: hostTime + tickSeconds)
      }

      if currentWall >= 22 { probe.holdRequested = true }
      if let packet = packetBox.take() {
        inFlight = false
        switch packet.result {
        case .failure(let error):
          probe.workerError = error.localizedDescription
        case .success(let result):
          if probe.holdRequested && !probe.holdStarted && !probe.holdReleased {
            held = packet
            probe.holdStarted = true
            probe.holdWall = currentWall
            probe.holdJobID = packet.jobID
            probe.holdStartedHost = stemClock()
          } else if currentWall >= 32 && !probe.staleInjected {
            var stale = result
            stale.range.generation &+= 1
            let discardedBefore = pipeline.discarded
            pipeline.accept(stale)
            probe.staleRejected = pipeline.discarded == discardedBefore + 1
            probe.staleInjected = probe.staleRejected
            let discardedAfterStale = pipeline.discarded
            pipeline.accept(result)
            if pipeline.discarded != discardedAfterStale {
              probe.failure = "Matching result was lost after stale identity injection"
            }
          } else {
            pipeline.accept(result)
          }
        }
      }

      if let packet = held, let started = probe.holdStartedHost,
        stemClock() - started >= holdSeconds
      {
        let discardedBefore = pipeline.discarded
        pipeline.accept(try packet.result.get())
        probe.holdDiscarded = pipeline.discarded > discardedBefore
        probe.holdReleased = true
        probe.holdReleaseWall = currentWall
        holdRecoveryBoundary = currentWall
        held = nil
      }

      if !inFlight && held == nil, let window = pipeline.job() {
        inFlight = true
        jobID &+= 1
        let sent = stemClock()
        worker.separate(window, jobID: jobID) { result in
          packetBox.put(Packet(jobID: jobID, result: result, seconds: stemClock() - sent))
        }
      }

      pipeline.step()
      let read = readMix(core, frames: tickFrames)
      probe.rendered.append(contentsOf: read.samples)
      probe.readFrames += tickFrames
      probe.readGotFrames += read.got

      let underruns = ls_underruns(core)
      let underrunDelta = underruns >= previousUnderruns ? underruns - previousUnderruns : 0
      if underrunDelta > 0 {
        let priming = [0.0, 8.0, 12.0, 18.0, 35.0].contains { currentWall >= $0 && currentWall < $0 + 0.35 }
        let allowed = !state.isPlaying || priming
        if allowed {
          probe.allowedUnderruns.append([
            "wall_seconds": currentWall, "delta": underrunDelta,
            "phase": state.phase, "paused": !state.isPlaying,
          ])
        } else {
          probe.continuousUnderruns += underrunDelta
        }
      }
      previousUnderruns = underruns

      if !state.isPlaying {
        if pauseUnderrunStart == nil { pauseUnderrunStart = underruns }
        if pausePlayedStart == nil { pausePlayedStart = ls_played(core) }
        if let start = pausePlayedStart {
          probe.pausePlayedFrames = max(probe.pausePlayedFrames, Int(ls_played(core) - start))
        }
      } else if let start = pauseUnderrunStart {
        probe.pauseUnderruns = underruns - start
        pauseUnderrunStart = nil
        pausePlayedStart = nil
      }

      probe.observations.append(Observation(
        wall: currentWall, phase: state.phase, trackID: state.track.id,
        position: state.position, playing: state.isPlaying, lag: pipeline.lagFrames,
        jumps: pipeline.jumps, weight: Double(pipeline.weight), output: pipeline.outputPosition,
        end: pipeline.end, base: pipeline.base, paused: pipeline.paused,
        underruns: underruns, played: ls_played(core)))
      if probe.failure == nil, let error = probe.workerError {
        probe.failure = "Real worker packet failed: \(error)"
      }
      pace(until: hostStart + currentWall + tickSeconds)
    }
    let settleDeadline = stemClock() + 3
    while inFlight && stemClock() < settleDeadline {
      if let packet = packetBox.take() {
        inFlight = false
        if case .success(let result) = packet.result { pipeline.accept(result) }
        if case .failure(let error) = packet.result { probe.workerError = error.localizedDescription }
      } else {
        usleep(1_000)
      }
    }
    if inFlight { probe.failure = "Final real worker result did not settle" }
    if held != nil { probe.failure = "Held worker result was not released" }
    probe.packetSamples = packetBox.timingSamples()
    if !probe.holdReleased { probe.failure = "No real worker result was held beyond its deadline" }
    if !probe.staleInjected { probe.failure = "No stale identity was injected into a live request" }

    let settings = AVAudioFormat(
      standardFormatWithSampleRate: Double(rate), channels: 2)!.settings
    try NativeE2E.write(probe.captured, to: try AVAudioFile(
      forWriting: out.appendingPathComponent("stream-captured.wav"), settings: settings))
    try NativeE2E.write(probe.expected, to: try AVAudioFile(
      forWriting: out.appendingPathComponent("stream-expected.wav"), settings: settings))
    try NativeE2E.write(probe.rendered, to: try AVAudioFile(
      forWriting: out.appendingPathComponent("stream-rendered.wav"), settings: settings))

    var controls = try StreamMixerChecks.run(probe.fixture, rate: rate, out: out)
    let tail = try StreamMixerChecks.provisional()
    controls["provisional_tail"] = tail
    controls["pass"] = controls["pass"] as? Bool == true && tail["pass"] as? Bool == true
    let pacedControls = renderEvidence.check(rendered: probe.rendered, expected: probe.expected)
    controls["paced"] = pacedControls
    controls["pass"] = controls["pass"] as? Bool == true && pacedControls["pass"] as? Bool == true
    let correlations = phaseCorrelations(probe.rendered, probe.expected)
    let coverage = coverageReport(probe)
    let failures = evaluate(
      probe: probe, pipeline: pipeline, controls: controls,
      correlations: correlations, coverage: coverage)
    let timing = timingReport(probe.packetSamples, excludedJob: nil)
    let report: [String: Any] = [
      "status": failures.isEmpty ? "pass" : "fail",
      "failures": failures,
      "failure_scenarios": failureScenarios,
      "source": "NativeE2E.song()/samples() plus one real WorkerClient",
      "rate": rate,
      "scenario_seconds": totalSeconds,
      "window_frames": windowFrames,
      "hop_frames": hopFrames,
      "right_context_frames": rightContextFrames,
      "producer_lag_frames": producerLagFrames,
      "native_queue_frames": nativeQueueFrames,
      "waveform_offset_frames": waveformOffsetFrames,
      "waveform_offset_tolerance_frames": waveformToleranceFrames,
      "warmups": probe.warmups,
      "packet_timing": timing,
      "committed_frames": probe.committedFrames,
      "fallback_frames": probe.fallbackFrames,
      "stem_frames": probe.stemFrames,
      "first_stem_wall_seconds": probe.firstStemWall ?? NSNull(),
      "recovery_stem_wall_seconds": probe.recoveryStemWall ?? NSNull(),
      "hold": [
        "requested": probe.holdRequested, "started": probe.holdStarted,
        "released": probe.holdReleased, "discarded_as_late": probe.holdDiscarded,
        "same_position_fallback_frames": probe.heldFallbackFrames,
        "wall_seconds": probe.holdWall ?? NSNull(),
        "release_wall_seconds": probe.holdReleaseWall ?? NSNull(),
      ],
      "stale": ["injected": probe.staleInjected, "rejected": probe.staleRejected],
      "commit_original_checks": probe.commitOriginalChecks,
      "commit_original_mismatches": probe.commitOriginalMismatches,
      "commit_original_max_abs_error": probe.commitOriginalMaxError,
      "backward_commit_starts": probe.backwardCommits,
      "overlapping_commit_starts": probe.overlappingCommits,
      "non_finite_blocks": probe.nonFiniteBlocks,
      "out_of_bounds_blocks": probe.outOfBoundsBlocks,
      "unanchored_blocks": probe.unanchoredBlocks,
      "pause_played_frames": probe.pausePlayedFrames,
      "pause_underruns": probe.pauseUnderruns,
      "continuous_underruns": probe.continuousUnderruns,
      "allowed_underruns": probe.allowedUnderruns,
      "read_frames": probe.readFrames,
      "read_got_frames": probe.readGotFrames,
      "history_frames": pipeline.end - pipeline.base,
      "history_bound_frames": historyLimitFrames,
      "cache_bytes": pipeline.cacheBytes,
      "cache_bound_bytes": cacheLimitBytes,
      "lag_frames": probe.observations.map(\.lag).max() ?? 0,
      "jump_count": pipeline.jumps,
      "nonzero_lag_observations": probe.observations.filter { $0.lag != producerLagFrames }.count,
      "nonzero_jump_observations": probe.observations.filter { $0.jumps != 0 }.count,
      "coverage": coverage,
      "phase_correlations": correlations,
      "controls": controls,
      "timeline_observation_count": probe.observations.count,
      "artifacts": [
        "stream-captured.wav", "stream-expected.wav", "stream-rendered.wav",
        "stream-commits.bin", "stream-commits.jsonl", "stream.json",
      ],
    ]
    return (report, failures)
  }

  private static func state(at wall: Double) -> State {
    if wall < 8 {
      return State(track: trackA, position: wall, isPlaying: true, phase: "fresh")
    }
    if wall < 12 {
      return State(track: trackA, position: 2 + wall - 8, isPlaying: true, phase: "seek_back")
    }
    if wall < 16 {
      return State(track: trackA, position: 15 + wall - 12, isPlaying: true, phase: "seek_forward")
    }
    if wall < 18 {
      return State(track: trackA, position: 19, isPlaying: false, phase: "pause")
    }
    if wall < 30 {
      return State(track: trackA, position: 19 + wall - 18, isPlaying: true, phase: "resume")
    }
    if wall < 35 {
      return State(track: trackB, position: wall - 30, isPlaying: true, phase: "natural")
    }
    return State(track: trackC, position: 10 + wall - 35, isPlaying: true, phase: "manual")
  }

  static func readMix(_ core: OpaquePointer, frames: Int)
    -> (samples: [Float], got: Int)
  {
    var samples = [Float](repeating: 0, count: frames * 2)
    let got = samples.withUnsafeMutableBufferPointer {
      Int(ls_read_mix(core, $0.baseAddress, UInt32(frames)))
    }
    return (samples, got)
  }

  private static func pace(until deadline: Double) {
    let remaining = deadline - stemClock()
    if remaining > 0 {
      usleep(UInt32(min(remaining * 1_000_000, Double(UInt32.max))))
    }
  }

  private static func writeReport(_ report: [String: Any], to out: URL) throws {
    try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
      .write(to: out.appendingPathComponent("stream.json"))
  }

  private static func timingReport(
    _ samples: [PacketSample], excludedJob: UInt64?
  ) -> [String: Any] {
    let values = samples.filter { $0.jobID != excludedJob }.map(\.seconds).sorted()
    guard !values.isEmpty else { return ["count": 0, "steady_count": 0] }
    let p95 = values[Int(Double(values.count - 1) * 0.95)]
    return [
      "count": samples.count,
      "steady_count": values.count,
      "p50": values[values.count / 2],
      "p95": p95,
      "max": values[values.count - 1],
      "limit_p95_seconds": 0.08,
      "limit_max_seconds": 0.10,
      "held_job_excluded": excludedJob ?? NSNull(),
    ]
  }

  private static func coverageReport(_ probe: Probe) -> [String: Any] {
    let windows: [(String, Double, Double)] = [
      ("fresh", 1.5, 8), ("seek_back", 9.5, 12),
      ("seek_forward", 13.5, 16), ("resume", 19.5, 30),
      ("natural", 31.5, 35), ("manual", 36.5, 40),
    ]
    let holdStart = probe.holdWall ?? -1
    var report = [String: Any]()
    for (name, start, end) in windows {
      let observations = probe.observations.filter {
        $0.wall >= start && $0.wall < end && $0.playing
          && !(holdStart >= 0 && $0.wall >= holdStart && $0.wall < holdStart + 0.5)
      }
      let covered = observations.filter { $0.weight > 0.9 }.count
      report[name] = [
        "observations": observations.count,
        "stem_observations": covered,
        "ratio": observations.isEmpty ? 0.0 : Double(covered) / Double(observations.count),
        "steady_start_seconds": start,
        "steady_end_seconds": end,
      ]
    }
    return report
  }

  private static func phaseCorrelations(_ rendered: [Float], _ expected: [Float]) -> [String: Any] {
    let windows: [(String, Int)] = [
      ("fresh", 3), ("seek_back", 10), ("seek_forward", 14),
      ("resume", 24), ("natural", 32), ("manual", 37),
    ]
    let renderedFrames = rendered.count / 2
    let expectedFrames = expected.count / 2
    var report = [String: Any]()
    for (name, seconds) in windows {
      let outputStart = seconds * rate
      let count = min(rate / 2, min(renderedFrames - outputStart, expectedFrames))
      guard count > 0 else {
        report[name] = ["score": 0.0, "offset_frames": 0]
        continue
      }
      var best = -1.0
      var bestOffset = -waveformOffsetFrames
      for delta in stride(from: -waveformToleranceFrames,
                          through: waveformToleranceFrames, by: 4)
      {
        let offset = -waveformOffsetFrames + delta
        let score = correlation(
          rendered, expected, outputStart: outputStart,
          expectedStart: outputStart + offset, count: count, stride: 4)
        if score > best { best = score; bestOffset = offset }
      }
      let low = max(-waveformOffsetFrames - waveformToleranceFrames, bestOffset - 4)
      let high = min(-waveformOffsetFrames + waveformToleranceFrames, bestOffset + 4)
      if low <= high {
        for offset in low...high {
          let score = correlation(
            rendered, expected, outputStart: outputStart,
            expectedStart: outputStart + offset, count: count, stride: 1)
          if score > best { best = score; bestOffset = offset }
        }
      }
      report[name] = [
        "score": best,
        "offset_frames": bestOffset,
        "nominal_offset_frames": -waveformOffsetFrames,
        "queue_error_frames": bestOffset + waveformOffsetFrames,
        "queue_error_ms": Double(bestOffset + waveformOffsetFrames) * 1000 / Double(rate),
      ]
    }
    return report
  }

  private static func correlation(
    _ rendered: [Float], _ expected: [Float], outputStart: Int,
    expectedStart: Int, count: Int, stride: Int
  ) -> Double {
    let renderedFrames = rendered.count / 2
    let expectedFrames = expected.count / 2
    guard outputStart >= 0, expectedStart >= 0,
      outputStart + count <= renderedFrames, expectedStart + count <= expectedFrames
    else { return -1 }
    var dot = 0.0, renderedEnergy = 0.0, expectedEnergy = 0.0
    var frame = 0
    while frame < count {
      let a = (Double(rendered[(outputStart + frame) * 2])
        + Double(rendered[(outputStart + frame) * 2 + 1])) * 0.5
      let b = (Double(expected[(expectedStart + frame) * 2])
        + Double(expected[(expectedStart + frame) * 2 + 1])) * 0.5
      dot += a * b
      renderedEnergy += a * a
      expectedEnergy += b * b
      frame += max(1, stride)
    }
    return dot / sqrt(max(renderedEnergy * expectedEnergy, 1e-12))
  }

  private static func evaluate(
    probe: Probe, pipeline: StemPipeline, controls: [String: Any],
    correlations: [String: Any], coverage: [String: Any]
  ) -> [String] {
    var failures = [String]()
    if let failure = probe.failure { failures.append(failure) }
    if probe.committedFrames == 0 { failures.append("no global-frame commits") }
    if probe.fallbackFrames == 0 { failures.append("no Original fallback frames") }
    if probe.stemFrames == 0 { failures.append("no actual worker stem frames") }
    if probe.firstStemWall == nil || (probe.firstStemWall ?? 9) > 1.5 {
      failures.append("first-listen stems did not arrive within 1.5 seconds")
    }
    if !probe.holdDiscarded { failures.append("held result was not rejected after its output deadline") }
    if probe.heldFallbackFrames == 0 { failures.append("held job did not produce same-position fallback") }
    if let recovered = probe.recoveryStemWall, let released = probe.holdReleaseWall {
      if recovered - released > 0.5 { failures.append("fresh recovery exceeded 500 ms") }
    } else { failures.append("no fresh recovery after held result") }
    if !probe.staleRejected { failures.append("stale identity was not rejected") }
    if probe.commitOriginalChecks == 0 { failures.append("no exact Original commit checks") }
    if probe.commitOriginalMismatches > 0 || probe.commitOriginalMaxError > 1e-6 {
      failures.append("Original commits were not capture-frame exact")
    }
    if probe.backwardCommits > 0 { failures.append("commit starts moved backward") }
    if probe.overlappingCommits > 0 { failures.append("commit ranges overlapped") }
    if probe.nonFiniteBlocks > 0 { failures.append("commit block contained non-finite samples") }
    if probe.outOfBoundsBlocks > 0 { failures.append("commit block read outside captured source") }
    if probe.unanchoredBlocks > 0 { failures.append("commit block was not source anchored") }
    if probe.observations.contains(where: { $0.lag != producerLagFrames }) {
      failures.append("stream reported an unexpected producer lag")
    }
    if probe.observations.contains(where: { $0.jumps != 0 }) || pipeline.jumps != 0 {
      failures.append("stream reported a playback jump")
    }
    let pause = probe.observations.filter { $0.phase == "pause" }
    if pause.isEmpty || Set(pause.map(\.end)).count != 1 {
      failures.append("pause advanced the capture clock")
    }
    if probe.pausePlayedFrames > pauseTailLimitFrames {
      failures.append("pause drain exceeded 330 ms")
    }
    if probe.continuousUnderruns > 0 {
      failures.append("continuous playback underruns: \(probe.continuousUnderruns)")
    }
    if pipeline.end - pipeline.base > historyLimitFrames {
      failures.append("history exceeded its 3-second bound")
    }
    if pipeline.cacheBytes > cacheLimitBytes {
      failures.append("ready stem cache exceeded 8 MiB")
    }
    if controls["checked"] as? Bool != true || controls["pass"] as? Bool != true {
      failures.append("rendered controls or stem reconstruction failed")
    }
    for (name, value) in coverage {
      guard let item = value as? [String: Any], let ratio = item["ratio"] as? Double else {
        failures.append("coverage report missing \(name)")
        continue
      }
      if ratio < 0.9 { failures.append("\(name) stem coverage \(String(format: "%.2f", ratio)) < 0.90") }
    }
    for name in ["fresh", "seek_back", "seek_forward", "resume", "natural", "manual"] {
      guard let phase = correlations[name] as? [String: Any],
        let score = phase["score"] as? Double,
        let error = phase["queue_error_frames"] as? Int
      else {
        failures.append("\(name) waveform evidence is missing")
        continue
      }
      if score < 0.98 { failures.append("\(name) waveform correlation \(String(format: "%.2f", score)) < 0.98") }
      if abs(error) > waveformToleranceFrames {
        failures.append("\(name) waveform queue error \(error) frames")
      }
    }
    let timingValues = probe.packetSamples
      .filter { $0.jobID != 0 && !($0.seconds.isNaN || $0.seconds.isInfinite) }
      .map(\.seconds).sorted()
    if timingValues.count < 10 { failures.append("insufficient real packet timing evidence") }
    if timingValues.count >= 10 {
      let p95 = timingValues[Int(Double(timingValues.count - 1) * 0.95)]
      if p95 >= 0.08 { failures.append("worker p95 \(String(format: "%.3f", p95))s >= 80 ms") }
      if timingValues.max()! >= 0.10 { failures.append("worker packet exceeded 100 ms") }
    }
    return failures
  }
}
