import AudioCore
import Foundation

enum StreamMixerChecks {
  // Worker-free proof that a late result falls back to the previous tail
  // estimate instead of Original. Synthetic sine in, deterministic gates out.
  static func provisional() throws -> [String: Any] {
    guard let core = ls_create(44100, 44100) else {
      throw StemError("Cannot allocate provisional check core")
    }
    defer { ls_destroy(core) }
    let pipeline = StemPipeline(core: core)
    var events = [(String, Int)]()
    pipeline.onTrace = { events.append(($0.event, $0.sourceFrame ?? -1)) }
    var commits = [(frame: Int, weight: Float, vocals: Float)]()
    pipeline.onCommit = { start, block in
      for f in 0..<block.count / 11 {
        commits.append((start + f, block[f * 11 + 10], block[f * 11]))
      }
    }
    pipeline.start(generation: 1)
    pipeline.observe(PlaybackSnapshot(trackID: "tail", title: "Tail", duration: 60,
      position: 0, isPlaying: true), hostTime: stemClock())
    func synth(_ count: Int) -> [Float] {
      let from = pipeline.end
      var out = [Float]()
      out.reserveCapacity(count * 2)
      for f in 0..<count {
        let v = Float(sin(Double(from + f) * 2 * .pi * 440 / 44100)) * 0.5
        out.append(v); out.append(-v)
      }
      return out
    }
    func stems(for window: AudioWindow) -> StemWindow {
      var out = [Float](repeating: 0, count: window.samples.count * 4)
      for f in 0..<window.samples.count / 2 {
        out[f * 8] = window.samples[f * 2]; out[f * 8 + 1] = window.samples[f * 2 + 1]
      }
      return StemWindow(range: window.range, samples: out)
    }
    func drive(_ count: Int) {
      pipeline.ingest(synth(count), hostTime: stemClock())
      pipeline.step()
    }
    func weight(in range: Range<Int>) -> [Float] {
      commits.filter { range.contains($0.frame) }.map(\.weight)
    }
    drive(88200)
    guard let first = pipeline.job() else { throw StemError("Provisional check built no first window") }
    let tailStart = Int(first.range.start) + 44100 - 2205, tailEnd = Int(first.range.start) + 44100
    pipeline.accept(stems(for: first))
    guard pipeline.acceptedResults == 1, pipeline.discarded == 0 else {
      throw StemError("Provisional check lost its on-time result")
    }
    // Hold the next window: the frontier crosses the tail with no result, so
    // the tail estimate must carry those frames as stems, never Original.
    drive(13230)
    let tailWeights = weight(in: tailStart + 5..<tailEnd - 5)
    guard tailWeights.count == tailEnd - tailStart - 10,
      tailWeights.min() ?? 0 > 0.5
    else { throw StemError("Late result fell back to Original inside the tail estimate") }
    guard events.contains(where: { $0.0 == "provisional-cover" && tailStart..<tailEnd ~= $0.1 }) else {
      throw StemError("Provisional cover left no trace")
    }
    for f in stride(from: tailStart + 100, to: tailStart + 105, by: 1) {
      guard let commit = commits.first(where: { $0.frame == f }),
        abs(commit.vocals - sine(at: f)) < 1e-5
      else { throw StemError("Provisional frame did not carry stem content") }
    }
    // The held window arrives partly late: its suffix must commit without any
    // full-Original frame, and the hold must be logged, not hidden.
    guard let second = pipeline.job() else { throw StemError("Provisional check built no held window") }
    let heldAt = pipeline.outputPosition
    pipeline.accept(stems(for: second))
    guard pipeline.partialResults == 1, pipeline.discarded == 0,
      events.contains(where: { $0.0 == "partial-late" })
    else { throw StemError("Partly late result was not accepted as a partial") }
    drive(4410)
    let heldWeights = weight(in: heldAt..<pipeline.outputPosition)
    guard !heldWeights.isEmpty, heldWeights.min() ?? 0 > 0.001,
      !events.contains(where: { $0.0 == "coverage-gap" && heldAt..<pipeline.outputPosition ~= $0.1 })
    else { throw StemError("Partly late result left an Original gap inside its estimates") }
    // A window held past its whole core is fully late: discard and say so.
    guard let late = pipeline.job() else { throw StemError("Provisional check built no late window") }
    drive(13230)
    pipeline.accept(stems(for: late))
    guard pipeline.lateResults == 1, pipeline.discarded == 1,
      events.contains(where: { $0.0 == "late-result" })
    else { throw StemError("Fully late result was not discarded and logged") }
    return ["checked": true, "pass": true,
      "tail_frames": tailEnd - tailStart, "tail_min_weight": tailWeights.min() ?? -1,
      "held_min_weight": heldWeights.min() ?? -1,
      "partial_results": pipeline.partialResults, "late_results": pipeline.lateResults,
      "accepted_results": pipeline.acceptedResults, "discarded": pipeline.discarded]
  }

  // Worker-free proof that the model gets no jobs while resting or while
  // Spotify is paused, and that waking can start a job at once.
  static func resting() throws -> [String: Any] {
    guard let core = ls_create(44100, 44100) else { throw StemError("Cannot allocate resting check core") }
    defer { ls_destroy(core) }
    let pipeline = StemPipeline(core: core)
    pipeline.start(generation: 1)
    func observe(playing: Bool) {
      pipeline.observe(PlaybackSnapshot(trackID: "rest", title: "Rest", duration: 60,
        position: 0, isPlaying: playing), hostTime: stemClock())
    }
    func drive(_ count: Int) {
      pipeline.ingest((0..<count * 2).map { Float(sin(Double($0) * 0.01)) * 0.5 }, hostTime: stemClock())
      pipeline.step()
    }
    observe(playing: true)
    drive(88200)
    pipeline.setResting(true)
    let steadyBefore = pipeline.steadyFrames
    drive(44100)
    guard pipeline.job() == nil, pipeline.warmupWindow() == nil else {
      throw StemError("Resting model was given a job")
    }
    guard pipeline.steadyFrames == steadyBefore else {
      throw StemError("Resting frames were counted as steady stem frames")
    }
    pipeline.setResting(false)
    guard pipeline.job() != nil else { throw StemError("Waking model could not start a job at once") }
    observe(playing: false)
    drive(4410)
    guard pipeline.job() == nil, pipeline.warmupWindow() == nil else {
      throw StemError("Paused Spotify still gave the model a job")
    }
    // While the model rests, frames have no stems. The mix must still follow
    // the controls: equal gains give Original at that gain; otherwise only the
    // stem-free part (Original at Other's gain) plays.
    let frames = 14400
    var fixture = [Float](repeating: 0, count: frames * 11)
    for f in 0..<frames {
      let v = Float(sin(Double(f) * 0.01)) * 0.3, b = Float(sin(Double(f) * 0.05)) * 0.4
      fixture[f * 11] = v; fixture[f * 11 + 1] = v; fixture[f * 11 + 4] = b; fixture[f * 11 + 5] = b
      fixture[f * 11 + 8] = v + b; fixture[f * 11 + 9] = v + b
    }
    let cases: [(String, [Float], UInt32, UInt32, Float)] = [
      ("neutral", [1, 1, 1, 1], 0, 0, 1), ("all_muted", [1, 1, 1, 1], 15, 0, 0),
      ("all_half", [0.5, 0.5, 0.5, 0.5], 0, 0, 0.5), ("bass_solo", [1, 1, 1, 1], 0, 4, 0),
      ("vocals_muted", [1, 1, 1, 1], 1, 0, 1),
    ]
    var errors = [String: Double]()
    for (name, gains, mute, solo, scale) in cases {
      guard let mix = ls_create(48000, 48000) else { throw StemError("Cannot allocate resting mix core") }
      defer { ls_destroy(mix) }
      gains.withUnsafeBufferPointer { ls_controls(mix, $0.baseAddress, mute, solo) }
      ls_enable(mix, 1)
      _ = fixture.withUnsafeBufferPointer { ls_output_write(mix, $0.baseAddress, UInt32(frames)) }
      let out = StreamE2E.readMix(mix, frames: frames).samples
      errors[name] = (frames / 2..<frames).map { Double(abs(out[$0 * 2] - scale * fixture[$0 * 11 + 8])) }.max() ?? 1
      guard errors[name]! < 1e-4 else { throw StemError("Resting mix \(name) did not follow the controls") }
    }
    return ["checked": true, "pass": true, "resting_mix_max_error": errors]
  }
  // Worker-free proof of the startup ease: playback starts at the live edge, the
  // render (run at the pipeline's requested rate, as the time-pitch unit would)
  // never underruns, repeats, or skips, and the delay grows to the steady value.
  static func ease() throws -> [String: Any] {
    guard let core = ls_create(44100, 44100) else { throw StemError("Cannot allocate ease check core") }
    defer { ls_destroy(core) }
    let pipeline = StemPipeline(core: core)
    pipeline.start(generation: 1)
    pipeline.observe(PlaybackSnapshot(trackID: "ease", title: "Ease", duration: 600,
      position: 0, isPlaying: true), hostTime: stemClock())
    // Each frame carries its own index: left = index % 1000, right = index / 1000 (scaled).
    func tick() {
      let from = pipeline.end
      pipeline.ingest((0..<441).flatMap { f -> [Float] in
        let index = from + f
        return [Float(index % 1000) / 1000, Float(index / 1000) / 1000]
      }, hostTime: stemClock())
      pipeline.step()
    }
    for _ in 0..<30 { tick() }  // 300 ms of capture while Spotify still plays directly
    let liveEdge = pipeline.end
    pipeline.beginEase()
    pipeline.step()
    ls_enable(core, 1)
    var rendered = [Int](), owed = 0.0, minRate: Float = 1, maxStep: Float = 0, lastRate = pipeline.easeRate
    var endedAfter: Double?
    for t in 0..<1500 {  // 15 s
      tick()
      minRate = min(minRate, pipeline.easeRate)
      maxStep = max(maxStep, abs(pipeline.easeRate - lastRate)); lastRate = pipeline.easeRate
      if endedAfter == nil, !pipeline.easing { endedAfter = Double(t) / 100 }
      owed += 441 * Double(pipeline.easeRate)
      let take = Int(owed); owed -= Double(take)
      let out = StreamE2E.readMix(core, frames: take).samples
      for f in 0..<take { rendered.append(Int((out[f * 2 + 1] * 1000).rounded()) * 1000 + Int((out[f * 2] * 1000).rounded())) }
    }
    let settled = Array(rendered.dropFirst(200))  // the 2.5 ms start envelope scales the first frames
    let first = settled[0] - 200
    let replay = liveEdge - first
    let continuous = zip(settled, settled.dropFirst()).allSatisfy { $1 == $0 + 1 }
    let finalLatency = pipeline.end - (rendered.last ?? 0)
    let underruns = ls_underruns(core)
    guard replay <= pipeline.easeCushionFrames + 441 else { throw StemError("Ease replayed \(replay) frames at handoff") }
    guard continuous else { throw StemError("Ease render repeated or skipped a frame") }
    guard underruns == 0 else { throw StemError("Ease render underran \(underruns) times") }
    guard let ended = endedAfter, ended < 10 else { throw StemError("Ease did not finish within 10 s") }
    guard abs(finalLatency - (pipeline.lagFrames + 2205)) <= 882 else {
      throw StemError("Ease ended at latency \(finalLatency) frames")
    }
    guard minRate >= 1 - pipeline.easeMaxSlowdown - 0.0001, maxStep <= 0.0021 else {
      throw StemError("Ease rate left its bounds: min \(minRate), step \(maxStep)")
    }
    return ["checked": true, "pass": true, "handoff_replay_ms": Double(replay) / 44.1,
      "ease_seconds": ended, "final_latency_ms": Double(finalLatency) / 44.1,
      "min_rate": minRate, "max_rate_step": maxStep, "underruns": underruns]
  }
  // Seeded transition fuzz: skips, seeks, pauses, duplicate notices, model
  // sleep/wake, late results, and the startup ease, in random order. Playback
  // must never go backward, underrun outside a transition, overflow, or fail to
  // settle at the steady delay. Simulated host time, so it runs faster than real time.
  static func transitions(seed: UInt64, seconds: Int = 60) throws -> [String: Any] {
    guard let core = ls_create(44100, 44100) else { throw StemError("Cannot allocate fuzz core") }
    defer { ls_destroy(core) }
    var rng = seed
    func roll(_ n: Int) -> Int {
      rng = rng &* 6364136223846793005 &+ 1442695040888963407
      return Int((rng >> 33) % UInt64(n))
    }
    let pipeline = StemPipeline(core: core)
    var failure: String?
    pipeline.onFailure = { failure = $0 }
    pipeline.start(generation: 1)
    var host = 1000.0, track = 0, position = 30.0, playing = true
    func snapshot() -> PlaybackSnapshot {
      PlaybackSnapshot(trackID: "t\(track)", title: "T", duration: 240, position: position, isPlaying: playing)
    }
    _ = pipeline.observe(snapshot(), hostTime: host)
    var pending = [(due: Int, window: AudioWindow)]()
    var lastRendered: UInt64 = 0, unexpectedUnderruns = 0, events = [String: Int](), quietUntil = 0
    var handedOff = false, owed = 0.0, lastUnderruns: UInt64 = 0
    var handoff: (tick: Int, liveEdge: Int)?  // checked only when Spotify was playing
    let ticks = seconds * 100, tail = 1500
    for t in 0..<(ticks + tail) {
      host += 0.01
      let calm = t >= ticks
      if !calm {
        switch roll(1000) {
        case 0..<4:  // skip to a new track
          track += 1; position = 0; events["skip", default: 0] += 1
          _ = pipeline.observe(snapshot(), hostTime: host); quietUntil = t + 100
        case 4..<6:  // seek within the track
          position += Double(roll(60)) + 1; events["seek", default: 0] += 1
          _ = pipeline.observe(snapshot(), hostTime: host); quietUntil = t + 100
        case 6..<8:  // pause or resume
          playing.toggle(); events[playing ? "resume" : "pause", default: 0] += 1
          _ = pipeline.observe(snapshot(), hostTime: host); quietUntil = t + 100
        case 8..<10:  // duplicate notice for the last skip
          events["duplicate", default: 0] += 1
          _ = pipeline.observe(snapshot(), hostTime: host)
        case 10..<25:  // the mix changes, so the model sleeps or wakes
          pipeline.setResting(roll(2) == 0); events["rest_toggle", default: 0] += 1
        default: break
        }
        if !handedOff, pipeline.end > 2000, roll(30) == 0 {
          if playing { handoff = (t, pipeline.end) }
          pipeline.beginEase(); pipeline.step(); ls_enable(core, 1); handedOff = true; quietUntil = t + 100
          events["ease", default: 0] += 1
        }
      } else if !playing {
        playing = true; _ = pipeline.observe(snapshot(), hostTime: host); quietUntil = t + 100
      }
      if !handedOff, calm { handoff = (t, pipeline.end); pipeline.beginEase(); pipeline.step(); ls_enable(core, 1); handedOff = true; quietUntil = t + 100 }
      if playing {  // capture stalls while Spotify is paused
        position += 0.01
        let from = pipeline.end
        pipeline.ingest((0..<441).flatMap { f -> [Float] in
          let v = Float(sin(Double(from + f) * 0.031)) * 0.4
          return [v, -v]
        }, hostTime: host)
      }
      // A fake worker answers on time, a little late, or past its deadline.
      if let window = pipeline.job() {
        let delay = [0, 1, 3, 6, 25][roll(5)]
        pending.append((t + delay, window))
      }
      for (index, job) in pending.enumerated().reversed() where job.due <= t {
        var out = [Float](repeating: 0, count: job.window.samples.count * 4)
        for f in 0..<job.window.samples.count / 2 {
          out[f * 8] = job.window.samples[f * 2]; out[f * 8 + 1] = job.window.samples[f * 2 + 1]
        }
        pipeline.accept(StemWindow(range: job.window.range, samples: out))
        pending.remove(at: index)
      }
      pipeline.step()
      if handedOff {
        owed += 441 * Double(pipeline.easeRate)
        let take = Int(owed); owed -= Double(take)
        _ = StreamE2E.readMix(core, frames: take)
        let rendered = ls_rendered_source_frame(core)
        if let start = handoff {  // startup: play at once, from the live edge
          guard rendered != UInt64.max || t - start.tick < 2 else {
            throw StemError("seed \(seed) t=\(t): no playback 20 ms after the handoff")
          }
          if rendered != UInt64.max {
            let firstFrame = Int(rendered) - Int(441 * pipeline.easeRate)
            guard start.liveEdge - firstFrame <= pipeline.easeCushionFrames + 441 else {
              throw StemError("seed \(seed): handoff replayed \(start.liveEdge - firstFrame) frames")
            }
            handoff = nil
          }
        }
        if rendered != UInt64.max {
          guard rendered >= lastRendered else {
            throw StemError("seed \(seed) t=\(t): playback went back from \(lastRendered) to \(rendered)")
          }
          lastRendered = rendered
        }
        let underruns = ls_underruns(core)
        if underruns > lastUnderruns, t > quietUntil, playing { unexpectedUnderruns += Int(underruns - lastUnderruns) }
        lastUnderruns = underruns
      }
      // Before the handoff output is off and nothing plays; the app hands off ~40 ms in.
      guard !handedOff || ls_queued(core) <= UInt32(pipeline.lagFrames + 8820), ls_overflows(core) == 0 else {
        throw StemError("seed \(seed) t=\(t): output queue \(ls_queued(core)) overflowed its bound")
      }
      if let failure { throw StemError("seed \(seed) t=\(t): pipeline failed: \(failure)") }
    }
    let latency = pipeline.end - Int(lastRendered)
    guard unexpectedUnderruns == 0 else { throw StemError("seed \(seed): \(unexpectedUnderruns) underruns outside transitions") }
    guard !pipeline.easing else { throw StemError("seed \(seed): ease still running after 15 calm seconds") }
    guard abs(latency - (pipeline.lagFrames + 2205)) <= 2205 else {
      throw StemError("seed \(seed): settled at latency \(latency) frames")
    }
    return ["seed": seed, "events": events, "settled_latency_ms": Double(latency) / 44.1,
      "late_results": pipeline.lateResults, "accepted": pipeline.acceptedResults]
  }
  static func sine(at frame: Int) -> Float {
    Float(sin(Double(frame) * 2 * .pi * 440 / 44100)) * 0.5
  }
  static func run(_ fixture: [Float], rate: Int, out: URL) throws -> [String: Any] {
    let frames = fixture.count / 11
    guard frames >= rate else {
      return ["checked": false, "reason": "no one-second verified stem fixture"]
    }
    guard let core = ls_create(Double(rate), Double(rate)) else {
      throw StemError("Cannot allocate stream controls check core")
    }
    defer { ls_destroy(core) }
    let gains: [Float] = [1, 1, 1, 1]
    gains.withUnsafeBufferPointer { ls_controls(core, $0.baseAddress, 0, 0) }
    ls_enable(core, 1)
    let written = fixture.withUnsafeBufferPointer {
      ls_output_write(core, $0.baseAddress, UInt32(frames))
    }
    guard written == UInt32(frames) else { throw StemError("Controls fixture write was short") }
    let rendered = StreamE2E.readMix(core, frames: frames).samples
    let settle = rate / 10
    var neutralError = 0.0
    var neutralMax = 0.0
    var neutralEnergy = 0.0
    var limiterViolations = 0
    for frame in settle..<frames {
      let at = frame * 11
      for channel in 0..<2 {
        let expected = Double(fixture[at + 8 + channel])
        let actual = Double(rendered[frame * 2 + channel])
        neutralEnergy += expected * expected
        neutralError += (actual - expected) * (actual - expected)
        neutralMax = max(neutralMax, abs(actual - expected))
      }
      let ceiling = max(Float(0.98), abs(fixture[at + 8]), abs(fixture[at + 9])) + 1e-6
      if abs(rendered[frame * 2]) > ceiling || abs(rendered[frame * 2 + 1]) > ceiling {
        limiterViolations += 1
      }
    }

    guard let bassCore = ls_create(Double(rate), Double(rate)) else {
      throw StemError("Cannot allocate BassSolo controls core")
    }
    defer { ls_destroy(bassCore) }
    gains.withUnsafeBufferPointer { ls_controls(bassCore, $0.baseAddress, 0, 1 << 2) }
    ls_enable(bassCore, 1)
    _ = fixture.withUnsafeBufferPointer { ls_output_write(bassCore, $0.baseAddress, UInt32(frames)) }
    let bassRendered = StreamE2E.readMix(bassCore, frames: frames).samples
    var bassError = 0.0
    var bassEnergy = 0.0
    for frame in settle..<frames {
      let at = frame * 11
      for channel in 0..<2 {
        let expected = Double(fixture[at + 4 + channel])
        let actual = Double(bassRendered[frame * 2 + channel])
        bassEnergy += expected * expected
        bassError += (actual - expected) * (actual - expected)
      }
    }

    guard let muteCore = ls_create(Double(rate), Double(rate)) else {
      throw StemError("Cannot allocate all-mute controls core")
    }
    defer { ls_destroy(muteCore) }
    gains.withUnsafeBufferPointer { ls_controls(muteCore, $0.baseAddress, 15, 0) }
    ls_enable(muteCore, 1)
    _ = fixture.withUnsafeBufferPointer { ls_output_write(muteCore, $0.baseAddress, UInt32(frames)) }
    let muted = StreamE2E.readMix(muteCore, frames: frames).samples
    let mutePeak = muted.dropFirst(settle * 2).map { abs($0) }.max() ?? 0
    // Meters are pre-fader: all-stem mute is silent but still shows the bass.
    var meters: [Float] = [0, 0, 0, 0], cleared: [Float] = [0, 0, 0, 0]
    ls_take_meters(muteCore, &meters)
    ls_take_meters(muteCore, &cleared)
    let bassSourcePeak = fixture.enumerated().filter { $0.offset % 11 == 4 || $0.offset % 11 == 5 }
      .map { abs($0.element) }.max() ?? 0
    let meterPass = bassSourcePeak > 0 && meters[2] > 0.5 * bassSourcePeak
      && meters[2] <= bassSourcePeak + 1e-6 && cleared.allSatisfy { $0 == 0 }

    guard let toggleCore = ls_create(Double(rate), Double(rate)) else {
      throw StemError("Cannot allocate stem toggle controls core")
    }
    defer { ls_destroy(toggleCore) }
    gains.withUnsafeBufferPointer { ls_controls(toggleCore, $0.baseAddress, 0, 1 << 2) }
    ls_enable(toggleCore, 1)
    _ = fixture.withUnsafeBufferPointer { ls_output_write(toggleCore, $0.baseAddress, UInt32(frames)) }
    let prefix = settle
    let offFrames = rate / 3
    let onStart = prefix + offFrames
    let before = ls_underruns(toggleCore)
    _ = StreamE2E.readMix(toggleCore, frames: prefix)
    ls_stems(toggleCore, 0)
    let off = StreamE2E.readMix(toggleCore, frames: offFrames).samples
    ls_stems(toggleCore, 1)
    let on = StreamE2E.readMix(toggleCore, frames: min(offFrames, frames - onStart)).samples
    let toggleUnderruns = ls_underruns(toggleCore) - before
    var offOriginalError = 0.0
    for frame in settle..<offFrames {
      let at = (prefix + frame) * 11
      let sourceAt = frame * 2
      for channel in 0..<2 {
        offOriginalError = max(
          offOriginalError,
          abs(Double(off[sourceAt + channel] - fixture[at + 8 + channel])))
      }
    }

    let onSettle = rate / 50
    var onBassError = 0.0
    for frame in onSettle..<min(offFrames, on.count / 2) {
      let fixtureFrame = onStart + frame
      let at = fixtureFrame * 11
      for channel in 0..<2 {
        let expected = fixture[at + 4 + channel]
        let actual = on[frame * 2 + channel]
        onBassError = max(onBassError, abs(Double(actual - expected)))
      }
    }

    let sourceEnergy = (settle..<frames).reduce(0.0) { total, frame in
      let at = frame * 11
      return total + Double(fixture[at + 8] * fixture[at + 8]
        + fixture[at + 9] * fixture[at + 9])
    }
    let stemSumError = (settle..<frames).reduce(0.0) { total, frame in
      let at = frame * 11
      let left = fixture[at + 8] - fixture[at] - fixture[at + 2]
        - fixture[at + 4] - fixture[at + 6]
      let right = fixture[at + 9] - fixture[at + 1] - fixture[at + 3]
        - fixture[at + 5] - fixture[at + 7]
      return total + Double(left * left + right * right)
    }
    let snr = 10 * log10(max(sourceEnergy, 1e-12) / max(stemSumError, 1e-12))
    let neutralRelative = neutralError / max(neutralEnergy, 1e-12)
    let bassRelative = bassError / max(bassEnergy, 1e-12)
    let toggleStemPeak = on.map(abs).max() ?? 0
    let sourcePeak = fixture.dropFirst(8).enumerated().filter { $0.offset % 11 < 2 }
      .map { abs($0.element) }.max() ?? 0
    let pass = neutralMax <= 1e-6 && neutralRelative <= 1e-10
      && bassRelative <= 1e-5 && mutePeak <= 1e-6
      && offOriginalError <= 1e-6 && toggleUnderruns == 0
      && limiterViolations == 0 && toggleStemPeak <= max(0.98, sourcePeak) + 1e-6
      && onBassError <= 1e-6 && meterPass
    return [
      "checked": true, "pass": pass,
      "neutral_relative_error": neutralRelative, "neutral_max_abs_error": neutralMax,
      "bass_relative_error": bassRelative, "mute_peak": mutePeak,
      "toggle_off_original_max_abs_error": offOriginalError,
      "toggle_underruns": toggleUnderruns, "limiter_violations": limiterViolations,
      "raw_stem_sum_snr_db": snr, "toggle_on_bass_max_abs_error": onBassError, "toggle_stem_peak": toggleStemPeak,
      "source_peak": sourcePeak, "frames": frames,
      "persistent_controls": true, "bass_solo": true, "all_stem_mute": true,
      "premute_bass_meter": meters[2], "bass_source_peak": bassSourcePeak, "meter_pass": meterPass,
    ]
  }

}
