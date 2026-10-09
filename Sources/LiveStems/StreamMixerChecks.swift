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
    pipeline.e2eOpenStemGate()  // this check is about late tails, not entry
    guard let first = pipeline.job() else { throw StemError("Provisional check built no first window") }
    let tailStart = Int(first.range.start) + 44100 - 2205, tailEnd = Int(first.range.start) + 44100
    pipeline.accept(stems(for: first))
    guard pipeline.acceptedResults == 1, pipeline.discarded == 0 else {
      throw StemError("Provisional check lost its on-time result")
    }
    // Hold the next window: the frontier crosses the tail with no result, so
    // the tail estimate must carry those frames as stems, never Original.
    drive(13230)
    // Full stems through the tail until its last fadeOut frames; there the gap is
    // certain, so stems fade out smoothly (never a jump) while data remains.
    let fadeFrom = tailEnd - pipeline.gate.fadeOut
    let tailWeights = weight(in: tailStart + 5..<fadeFrom)
    let fadeWeights = weight(in: fadeFrom..<tailEnd)
    guard tailWeights.count == fadeFrom - tailStart - 5, tailWeights.min() ?? 0 > 0.5
    else { throw StemError("Late result fell back to Original inside the tail estimate") }
    guard zip(fadeWeights, fadeWeights.dropFirst()).allSatisfy({ $1 <= $0 && $0 - $1 <= 1 / Float(pipeline.gate.fadeOut) + 1e-6 })
    else { throw StemError("Tail did not fade out smoothly before the gap") }
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
    // The hold above ran past the tail, a real gap, which closes the entry gate
    // (see the flutter stage). This part checks only that a partly late result
    // commits its uncommitted suffix, so it starts with stems admitted again.
    pipeline.e2eOpenStemGate()
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
    // Quiet detection (the takeover break for apps without transport notices).
    pipeline.ingest([Float](repeating: 0.0005, count: 11025 * 2), hostTime: stemClock())
    guard pipeline.quietFrames == 11025 else { throw StemError("Quiet run measured \(pipeline.quietFrames) frames") }
    pipeline.ingest([Float](repeating: 0.3, count: 441 * 2) + [Float](repeating: 0, count: 100 * 2), hostTime: stemClock())
    guard pipeline.quietFrames == 100 else { throw StemError("Quiet run did not restart after sound") }
    // A dip takeover (no quiet moment came) fades back in over 50 ms.
    var dipped = [Float]()
    pipeline.onCommit = { _, block in for f in 0..<block.count / 11 { dipped.append(block[f * 11 + 8]) } }
    pipeline.takeOverAtBreak(fadeIn: true)
    pipeline.ingest([Float](repeating: 0.5, count: 22050 * 2), hostTime: stemClock())
    pipeline.step()
    pipeline.onCommit = nil
    guard dipped.count > 2205, dipped[0] < 0.001, abs(dipped[1102] - 0.25) < 0.01, abs(dipped[2205] - 0.5) < 1e-6,
      zip(dipped.prefix(2205), dipped.dropFirst().prefix(2205)).allSatisfy({ $1 >= $0 }) else {
      throw StemError("Dip takeover did not fade in over 50 ms")
    }
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
  // Worker-free proof that a struggling model cannot make stems flutter. After a
  // break takeover, every third answer arrives 300 ms late. Without the escalating
  // entry gate stems would drop out and come back about twice a second.
  static func flutter() throws -> [String: Any] {
    guard let core = ls_create(44100, 44100) else { throw StemError("Cannot allocate flutter check core") }
    defer { ls_destroy(core) }
    let pipeline = StemPipeline(core: core)
    pipeline.start(generation: 1)
    pipeline.holdForBreak()
    var host = 500.0, playing = true
    func observe() {
      _ = pipeline.observe(PlaybackSnapshot(trackID: "f", title: "F", duration: 600, position: host - 500,
        isPlaying: playing), hostTime: host)
    }
    observe()
    var pending = [(due: Int, window: AudioWindow)](), entries = 0, maxRise: Float = 0, last: Float = 0
    var struggleEntries = 0, turns = 0, struggleTurns = 0, peak: Float = 0, rising = false, maxFall: Float = 0
    pipeline.onCommit = { _, block in
      for f in 0..<block.count / 11 {
        let w = block[f * 11 + 10]
        if last < 0.01, w >= 0.01 { entries += 1 }
        // A turn is a rise of 0.05 or more followed by a fall of 0.05 or more.
        if rising { if w > peak { peak = w } else if peak - w >= 0.05 { turns += 1; rising = false; peak = w } }
        else { if w < peak { peak = w } else if w - peak >= 0.05 { rising = true; peak = w } }
        maxRise = max(maxRise, w - last); maxFall = max(maxFall, last - w); last = w
      }
    }
    var answers = 0
    for t in 0..<1700 {  // 12 s of a struggling model, then 5 s of a healthy one
      host += 0.01
      if t == 50 { playing = false; observe() }  // a pause: the takeover break
      if t == 52, !pipeline.outputLive { pipeline.takeOverAtBreak(); ls_enable(core, 1) }
      if t == 60 { playing = true; observe() }
      if playing {
        let from = pipeline.end
        pipeline.ingest((0..<441).flatMap { f -> [Float] in
          let v = Float(sin(Double(from + f) * 0.031)) * 0.4
          return [v, -v]
        }, hostTime: host)
      }
      if let window = pipeline.job() {
        answers += 1
        pending.append((t + (t < 1200 && answers % 3 == 0 ? 30 : 7), window))  // every third answer late
      }
      while let job = pending.first, job.due <= t {
        pending.removeFirst()
        var out = [Float](repeating: 0, count: job.window.samples.count * 4)
        for f in 0..<job.window.samples.count / 2 {
          out[f * 8] = job.window.samples[f * 2]; out[f * 8 + 1] = job.window.samples[f * 2 + 1]
        }
        pipeline.accept(StemWindow(range: job.window.range, samples: out))
      }
      pipeline.step()
      _ = StreamE2E.readMix(core, frames: 441)
      if t == 1199 { struggleEntries = entries; struggleTurns = turns }
    }
    // First entry, then at most one fast recovery from an isolated miss; the
    // repeated gaps escalate the gate and stems stay out until the model is healthy.
    guard struggleTurns <= 2 else {
      throw StemError("Stems fluttered: weight turned down \(struggleTurns) times in 12 s")
    }
    guard last >= 0.999 else { throw StemError("Stems did not come back after the model recovered") }
    // Misses fade stems out while data remains: never a jump back to Original.
    guard maxFall <= 1 / Float(pipeline.gate.fadeOut) + 1e-6 else {
      throw StemError("Stems dropped by \(maxFall) in one frame; misses must fade out")
    }
    guard maxRise <= 1 / Float(pipeline.gate.fade) + 1e-6 else {
      throw StemError("Stems entered too fast: weight rose \(maxRise) in one frame")
    }
    return ["checked": true, "pass": true, "stem_entries": entries, "struggle_entries": struggleEntries, "struggle_turns": struggleTurns, "max_fall": maxFall, "late_results": pipeline.lateResults,
      "partial_results": pipeline.partialResults, "underruns": ls_underruns(core)]
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
    pipeline.holdForBreak()  // like the live session: Spotify direct until takeover
    var host = 1000.0, track = 0, position = 30.0, playing = true
    func snapshot() -> PlaybackSnapshot {
      PlaybackSnapshot(trackID: "t\(track)", title: "T", duration: 240, position: position, isPlaying: playing)
    }
    _ = pipeline.observe(snapshot(), hostTime: host)
    var pending = [(due: Int, window: AudioWindow)]()
    var lastRendered: UInt64 = 0, unexpectedUnderruns = 0, events = [String: Int](), quietUntil = 0
    var handedOff = false, lastUnderruns: UInt64 = 0
    var selfPaused = false, resumeAt: Int?
    func selfPause() {  // as the session does: pause Spotify to make a takeover break
      selfPaused = true; playing = false; events["self_pause", default: 0] += 1
      _ = pipeline.observe(snapshot(), hostTime: host); quietUntil = Int.max
    }
    var breakEdge: Int?  // a break takeover may replay nothing at all
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
        if !handedOff, pipeline.paused || pipeline.breakPending {
          breakEdge = pipeline.end
          if selfPaused { resumeAt = t + 3 + roll(10); selfPaused = false }
          pipeline.takeOverAtBreak(); pipeline.step(); ls_enable(core, 1); handedOff = true; quietUntil = t + 100
          events["break_takeover", default: 0] += 1
        }
        if !handedOff, playing, pipeline.end > 2000, roll(400) == 0 { selfPause() }  // stems wanted early
      } else if !playing {
        playing = true; _ = pipeline.observe(snapshot(), hostTime: host); quietUntil = t + 100
      }
      if !handedOff, calm, playing { selfPause() }
      if let at = resumeAt, t >= at {  // Live Stems presses play again after its own pause
        resumeAt = nil; playing = true; _ = pipeline.observe(snapshot(), hostTime: host); quietUntil = t + 100
      }
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
        _ = StreamE2E.readMix(core, frames: 441)
        let rendered = ls_rendered_source_frame(core)
        if let edge = breakEdge, rendered != UInt64.max {
          guard Int(rendered) - 441 >= edge - 64 else {
            throw StemError("seed \(seed): break takeover replayed \(edge - Int(rendered) + 441) frames")
          }
          breakEdge = nil
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
      // Held for a break: nothing may queue, or minutes of waiting would overflow.
      guard handedOff || ls_queued(core) == 0 else { throw StemError("seed \(seed) t=\(t): queued audio while held") }
      guard ls_queued(core) <= UInt32(pipeline.lagFrames + 8820), ls_overflows(core) == 0 else {
        throw StemError("seed \(seed) t=\(t): output queue \(ls_queued(core)) overflowed its bound")
      }
      if let failure { throw StemError("seed \(seed) t=\(t): pipeline failed: \(failure)") }
    }
    let latency = pipeline.end - Int(lastRendered)
    guard unexpectedUnderruns == 0 else { throw StemError("seed \(seed): \(unexpectedUnderruns) underruns outside transitions") }
    guard abs(latency - (pipeline.lagFrames + 2205)) <= 2205 else {
      throw StemError("seed \(seed): settled at latency \(latency) frames")
    }
    return ["seed": seed, "events": events, "settled_latency_ms": Double(latency) / 44.1,
      "late_results": pipeline.lateResults, "accepted": pipeline.acceptedResults]
  }
  /// Pause and skip fade out from the notice like Spotify, (1 - t/T)^4, with
  /// no click, and are silent once the fade ends.
  static func fades() throws -> [String: Any] {
    var report = [String: Any]()
    for (name, fadeFrames) in [("pause", StemPipeline.pauseFadeFrames), ("skip", StemPipeline.skipFadeFrames)] {
      guard let core = ls_create(44100, 44100) else { throw StemError("Cannot allocate fade core") }
      defer { ls_destroy(core) }
      let pipeline = StemPipeline(core: core)
      pipeline.start(generation: 1)
      var host = 1000.0, track = 0, playing = true, position = 30.0
      func notice() {
        _ = pipeline.observe(PlaybackSnapshot(trackID: "t\(track)", title: "T", duration: 240, position: position,
          isPlaying: playing), hostTime: host)
      }
      func tick() -> [Float] {
        host += 0.01
        if playing {
          position += 0.01
          let from = pipeline.end
          pipeline.ingest((0..<441).flatMap { [sine(at: from + $0), sine(at: from + $0)] }, hostTime: host)
        }
        pipeline.step()
        let mix = StreamE2E.readMix(core, frames: 441).samples
        return stride(from: 0, to: 882, by: 2).map { mix[$0] }
      }
      notice()
      ls_enable(core, 1)
      for _ in 0..<200 { _ = tick() }  // settle at the steady delay
      if name == "pause" { playing = false } else { track += 1 }
      notice()
      let after = (0..<(fadeFrames / 441 + 4)).flatMap { _ in tick() }
      var worst: Float = 0
      for block in 0..<fadeFrames / 441 {
        let expected = 0.5 * pow(1 - Float(block * 441) / Float(fadeFrames), 4)
        let peak = after[block * 441..<(block + 1) * 441].map(abs).max()!
        worst = max(worst, abs(peak - expected))
      }
      let maxStep: Float = zip(after, after.dropFirst()).map { abs($1 - $0) }.max()!
      let silentFrom = (fadeFrames / 441 + 1) * 441
      let tail: Float = after[silentFrom...].map { abs($0) }.max()!
      guard worst < 0.03 else { throw StemError("\(name) fade strayed \(worst) from Spotify's curve") }
      guard maxStep < 0.035 else { throw StemError("\(name) fade clicked: step \(maxStep)") }
      guard tail < 0.001 else { throw StemError("\(name) still sounded after its fade: \(tail)") }
      report[name] = ["fade_ms": Double(fadeFrames) / 44.1, "max_curve_error": worst, "max_step": maxStep]
    }
    return report
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
