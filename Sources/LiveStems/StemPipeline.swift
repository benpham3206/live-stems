import AudioCore
import Foundation

// The session queue owns this capture-frame timeline. Worker completion never
// changes the playback cursor. Original and stems share one fixed deadline.
final class StemPipeline {
  struct Job {
    let version: UInt64, window: Range<Int>, core: Range<Int>, request: FrameRange
  }
  struct Chunk {
    let range: Range<Int>
    var samples: [Float]
  }
  let core: OpaquePointer
  let hop = 4410, windowFrames = 44100, rightContext = 2205, fade = 441
  let lagFrames = 11466, memoryLimit = 8 * 1024 * 1024
  var jumps: Int { 0 }
  private(set) var generation: UInt64 = 1, base = 0, end = 0, outputPosition = 0
  private(set) var weight: Float = 0, paused = false
  private(set) var discarded = 0, stemCommits = 0, fallbacks = 0, hardCuts = 0
  private(set) var lateResults = 0, acceptedResults = 0, partialResults = 0
  private(set) var steadyFrames = 0, steadyFullStemFrames = 0, steadyFallbackFrames = 0
  private(set) var steadyProvisionalFrames = 0
  // The model rests while the mix equals Original. Resting frames are not steady stem frames.
  private(set) var resting = false
  // Until takeover the listener hears Spotify directly and nothing is queued.
  // A pause, skip, or seek is a break where the 0.3 s shift cannot be heard.
  private(set) var outputLive = true, breakPending = false
  /// How long the captured audio has been quiet, in frames, up to the newest frame.
  private(set) var quietFrames = 0
  private var dipFade = 0..<0
  /// The live session holds output for a break; fixtures keep committing at once.
  func holdForBreak() { outputLive = false; breakPending = false }
  /// When stems may play after a gap; see StemEntryGate.
  private(set) var gate = StemEntryGate()
  var timings = [Double]()
  private var history = [Float](), ready = [Chunk]()
  private var provisional: Chunk?
  private var inflight: Job?, version: UInt64 = 0, contextStart = 0, scheduledEnd = 0
  private var snapshot: PlaybackSnapshot?, snapshotHost = 0.0, captureHost = 0.0
  private var wasFallback = false, wasProvisional = false
  private var traceCovered = false
  private(set) var tailScanning = false, cutHost = 0.0
  private var tailScanEnd = 0, gapRun = 0, cutEnd = 0
  private var cutFromTrack = "", cutToTrack = "", lastCutHost = -10.0
  var onFailure: ((String) -> Void)?, onCommit: ((Int, [Float]) -> Void)?
  var onTrace: ((TraceRecord) -> Void)?
  func estimatedTrackPosition(at frame: Int) -> Double? {
    guard let snapshot else { return nil }
    let current = snapshot.position + (snapshot.isPlaying ? captureHost - snapshotHost : 0)
    return current - Double(end - frame) / 44100
  }
  init(core: OpaquePointer) { self.core = core }
  var cacheBytes: Int {
    ready.reduce(0) { $0 + $1.samples.count * MemoryLayout<Float>.size }
      + (provisional?.samples.count ?? 0) * MemoryLayout<Float>.size
  }
  var statusText: String {
    if paused { return "Paused" }
    if end - contextStart < windowFrames { return "Original · preparing live stems" }
    return "Live stems"
  }
  func start(generation: UInt64) {
    self.generation = generation
    base = 0; end = 0; outputPosition = 0; contextStart = 0; scheduledEnd = 0
    weight = 0; paused = false; history.removeAll(); ready.removeAll(); inflight = nil
    snapshot = nil; snapshotHost = 0; captureHost = 0; version += 1
    discarded = 0; lateResults = 0; acceptedResults = 0; partialResults = 0; stemCommits = 0
    fallbacks = 0; hardCuts = 0; wasFallback = false; wasProvisional = false; timings.removeAll()
    steadyFrames = 0; steadyFullStemFrames = 0; steadyFallbackFrames = 0
    steadyProvisionalFrames = 0
    provisional = nil; tailScanning = false
    cutFromTrack = ""; cutToTrack = ""; lastCutHost = -10.0
    ls_reset(core)
  }
  func ingest(_ samples: [Float], hostTime: Double = stemClock()) {
    guard samples.count % 2 == 0, samples.allSatisfy(\.isFinite) else {
      onFailure?("Invalid capture samples"); return
    }
    captureHost = hostTime
    guard !paused else { return }
    history.append(contentsOf: samples); end += samples.count / 2
    // Trailing quiet frames (below about -48 dBFS): a quiet moment is a break
    // for any source app, where the takeover's 0.3 s shift cannot be heard.
    for frame in stride(from: samples.count / 2 - 1, through: 0, by: -1) {
      guard max(abs(samples[frame * 2]), abs(samples[frame * 2 + 1])) < 0.004 else {
        quietFrames = samples.count / 2 - 1 - frame; return finishIngest(samples.count / 2)
      }
    }
    quietFrames += samples.count / 2
    finishIngest(samples.count / 2)
  }
  private func finishIngest(_ frames: Int) {
    if end - base > 3 * 44100 {
      let remove = end - base - 2 * 44100
      history.removeFirst(remove * 2); base += remove
    }
    if tailScanning { scanTail(from: end - frames) }
  }
  // After a manual cut the notice precedes the acoustic change by ~50 ms and
  // a true silence gap follows the old-track tail. The first gap start is the
  // new-track boundary for model context and, while nothing past the cut has
  // been committed, for playback too: the old tail must not play after the gap.
  private func scanTail(from start: Int) {
    for frame in max(start, base)..<end {
      let at = (frame - base) * 2
      if max(abs(history[at]), abs(history[at + 1])) < 0.008 {
        gapRun += 1
        if gapRun >= fade {
          let boundary = frame + 1 - gapRun
          contextStart = max(contextStart, boundary); scheduledEnd = max(scheduledEnd, boundary)
          if outputPosition == cutEnd { outputPosition = boundary }
          tailScanning = false
          onTrace?(TraceRecord(event: "skip-boundary", generation: generation,
            sourceFrame: boundary, sourceEnd: cutEnd))
          return
        }
      } else { gapRun = 0 }
      if frame + 1 >= tailScanEnd { cancelTailScan(); return }
    }
  }
  func cancelTailScan() {
    guard tailScanning else { return }
    tailScanning = false
    onTrace?(TraceRecord(event: "skip-boundary", generation: generation,
      sourceFrame: cutEnd, sourceEnd: cutEnd))
  }
  @discardableResult
  func observe(_ value: PlaybackSnapshot, hostTime: Double = stemClock()) -> Bool {
    guard value.position.isFinite, value.duration.isFinite,
      value.position >= 0, value.position <= 86400, value.duration >= 0 else { lost(); return false }
    var cut = false, natural = false, fromTrack = ""
    if let old = snapshot {
      fromTrack = old.trackID
      let expected = old.position + (old.isPlaying ? max(0, hostTime - snapshotHost) : 0)
      if value.trackID != old.trackID {
        cut = true
        natural = old.isPlaying && value.isPlaying && old.duration > 0
          && abs(expected - old.duration) < 1.2 && value.position < 1.5
      } else if abs(value.position - expected) > 1.0 {
        // An AppleScript read samples the position at an unknown point inside a
        // call that can take ~0.5 s, so smaller drift is read noise. A false seek
        // flushes audible playback; a missed sub-second seek costs only context.
        cut = true
      }
    }
    let changedPause = paused != !value.isPlaying
    paused = !value.isPlaying
    if cut || (changedPause && paused) { breakPending = true }
    if cut {
      // The notice and the poll can disagree for ~1 s around one transition
      // (duplicate notice, stale old-track read). A second cut naming either
      // side of the last cut is that same transition, not a new skip.
      if hostTime - lastCutHost < 1.0
        && (value.trackID == cutToTrack || value.trackID == cutFromTrack)
      {
        snapshot = value; snapshotHost = hostTime
        onTrace?(TraceRecord(event: "source-duplicate", generation: generation,
          sourceFrame: end, estimatedTrackSeconds: value.position))
        return false
      }
      cutFromTrack = fromTrack; cutToTrack = value.trackID; lastCutHost = hostTime
      let position = max(0, value.position + (value.isPlaying && captureHost > 0 ? captureHost - hostTime : 0))
      let boundary = natural ? max(contextStart, end - Int(position * 44100)) : end
      resetContext(at: boundary, flush: !natural, host: hostTime, scan: !natural)
    } else if changedPause {
      // Drain already captured audio on pause. A resume begins new model
      // context but retains the queued source timeline, including short pauses.
      resetContext(at: end, flush: false)
    }
    snapshot = value; snapshotHost = hostTime
    if cut || changedPause {
      onTrace?(TraceRecord(event: cut ? "source-change" : "playback-state", generation: generation,
        sourceFrame: end, queuedFrames: ls_queued(core), estimatedTrackSeconds: value.position,
        hardCuts: hardCuts, noticeHostSeconds: hostTime))
    }
    return cut && !natural
  }
  func lost() {
    // Capture frame indexes remain valid if Spotify metadata is temporarily
    // unavailable. Never substitute a song-position clock for captured audio.
    snapshot = nil
    paused = false
  }
  func setResting(_ value: Bool) {
    guard value != resting else { return }
    resting = value
    onTrace?(TraceRecord(event: value ? "model-rest" : "model-wake", generation: generation, sourceFrame: outputPosition))
    // Waking rebuilds context from the last captured second, so the first job can start now.
    if !value { resetProcessor() }
  }
  func resetProcessor() {
    gate.reset()
    generation += 1; version += 1
    contextStart = max(base, end - windowFrames)
    scheduledEnd = contextStart
    inflight = nil; ready.removeAll(); weight = 0; traceCovered = false
    provisional = nil; wasProvisional = false; tailScanning = false
    onTrace?(TraceRecord(event: "processor-reset", generation: generation, sourceFrame: outputPosition))
  }
  /// E2E fixtures that test seams, not entry, start with stems already admitted.
  func e2eOpenStemGate() { gate.openForTest() }
  private func resetContext(at frame: Int, flush: Bool, host: Double = stemClock(), scan: Bool = false) {
    gate.reset()
    version += 1; contextStart = frame; scheduledEnd = frame
    ready.removeAll { flush || $0.range.upperBound > frame }
    if flush {
      weight = 0; outputPosition = end; hardCuts += 1; ls_flush_output(core)
      provisional = nil; wasProvisional = false
      tailScanning = scan; cutEnd = end; tailScanEnd = end + 13230; gapRun = 0; cutHost = host
    }
  }
  func warmupWindow() -> AudioWindow? {
    // Post-skip context rebuild idles the worker for ~1 s while the GPU goes
    // cold. Rehearse the latest full second at the steady hop; the caller
    // discards these results. Never competes with a real window.
    guard !paused, !resting, end - base >= windowFrames, end - contextStart < windowFrames else { return nil }
    let window = (end - windowFrames)..<end
    let offset = (window.lowerBound - base) * 2
    return AudioWindow(range: FrameRange(generation: generation, start: UInt64(window.lowerBound),
      count: UInt32(windowFrames)), samples: Array(history[offset..<offset + windowFrames * 2]))
  }
  func job() -> AudioWindow? {
    guard inflight == nil, !paused, !resting else { return nil }
    let windowEnd = end
    guard windowEnd - contextStart >= windowFrames, windowEnd - scheduledEnd >= hop else { return nil }
    let window = (windowEnd - windowFrames)..<windowEnd
    guard window.lowerBound >= base else { return nil }
    let coreEnd = windowEnd - rightContext
    let coreStart = scheduledEnd == contextStart ? coreEnd - hop : scheduledEnd - rightContext
    let core = max(window.lowerBound + fade, coreStart)..<coreEnd
    scheduledEnd = windowEnd
    guard core.upperBound > outputPosition else { return nil }
    let request = FrameRange(generation: generation, start: UInt64(window.lowerBound), count: UInt32(windowFrames))
    inflight = Job(version: version, window: window, core: core, request: request)
    let offset = (window.lowerBound - base) * 2
    return AudioWindow(range: request, samples: Array(history[offset..<offset + windowFrames * 2]))
  }
  func accept(_ result: StemWindow) {
    guard let job = inflight, result.range == job.request else {
      discarded += 1
      onTrace?(TraceRecord(event: "rejected-identity", generation: generation, windowStart: result.range.start))
      return
    }
    inflight = nil
    guard job.version == version, result.range.generation == generation,
      result.samples.count == windowFrames * 8, result.samples.allSatisfy(\.isFinite) else {
      discarded += 1
      onTrace?(TraceRecord(event: "rejected-context", generation: generation, windowStart: result.range.start))
      return
    }
    guard job.core.upperBound > outputPosition else {
      discarded += 1; lateResults += 1
      onTrace?(TraceRecord(event: "late-result", generation: generation, sourceFrame: outputPosition,
        windowStart: result.range.start, lateResults: lateResults, lateFrames: job.core.count))
      return
    }
    // A partly late result still owns its uncommitted suffix. Frames before
    // the commit frontier already played; the rest must not fall back.
    let coreLo = max(job.core.lowerBound, outputPosition)
    if coreLo > job.core.lowerBound {
      partialResults += 1
      onTrace?(TraceRecord(event: "partial-late", generation: generation, sourceFrame: outputPosition,
        sourceEnd: job.core.upperBound, windowStart: result.range.start, lateFrames: coreLo - job.core.lowerBound))
    }
    var coreSamples = Array(result.samples[(coreLo - job.window.lowerBound) * 8..<((job.core.upperBound - job.window.lowerBound) * 8)])
    // The next estimate overlaps the previous right-context tail. Blend the
    // uncommitted overlap instead of stepping between two estimates.
    if let tail = provisional, tail.range.upperBound > coreLo, tail.range.lowerBound < job.core.upperBound {
      let overlap = max(tail.range.lowerBound, coreLo)..<min(tail.range.upperBound, job.core.upperBound)
      for frame in overlap.lowerBound..<min(overlap.upperBound, overlap.lowerBound + fade) {
        let amount = Float(frame - overlap.lowerBound + 1) / Float(fade + 1)
        for channel in 0..<8 {
          coreSamples[(frame - coreLo) * 8 + channel] =
            tail.samples[(frame - tail.range.lowerBound) * 8 + channel] * (1 - amount)
            + coreSamples[(frame - coreLo) * 8 + channel] * amount
        }
      }
    }
    // Join two estimates of the same source frames. Touch only frames that
    // have not entered the output queue; never replace already played audio.
    if outputPosition < job.core.lowerBound,
      let last = ready.indices.last, ready[last].range.upperBound == job.core.lowerBound
    {
      let overlapStart = job.core.lowerBound - fade
      for frame in max(outputPosition, overlapStart)..<job.core.lowerBound {
        let amount = Float(frame - overlapStart + 1) / Float(fade + 1)
        let previous = (frame - ready[last].range.lowerBound) * 8
        let incoming = (frame - job.window.lowerBound) * 8
        for channel in 0..<8 {
          ready[last].samples[previous + channel] = ready[last].samples[previous + channel] * (1 - amount)
            + result.samples[incoming + channel] * amount
        }
      }
    }
    ready.append(Chunk(range: coreLo..<job.core.upperBound, samples: coreSamples))
    // Keep the right-context tail as a provisional estimate. It commits only
    // if the next result arrives late; that result then replaces it.
    let tailLo = max(job.core.upperBound, outputPosition)
    if tailLo < job.window.upperBound {
      let at = (tailLo - job.window.lowerBound) * 8
      provisional = Chunk(range: tailLo..<job.window.upperBound,
        samples: Array(result.samples[at..<at + (job.window.upperBound - tailLo) * 8]))
    } else { provisional = nil }
    acceptedResults += 1
    gate.result(fullyOnTime: coreLo == job.core.lowerBound)
    onTrace?(TraceRecord(event: "accepted-result", generation: generation,
      sourceFrame: coreLo, sourceEnd: job.core.upperBound,
      windowStart: result.range.start, deadlineSlackSeconds: Double(job.core.lowerBound - outputPosition) / 44100))
  }
  private func blend(toward target: Float) {
    weight = gate.weight(from: weight, toward: target, seamStep: 1 / Float(fade))
  }
  private func block(start: Int, count: Int) -> [Float] {
    var samples = [Float](repeating: 0, count: count * 11)
    for i in 0..<count {
      let frame = start + i, out = i * 11, source = (frame - base) * 2
      samples[out + 8] = history[source]; samples[out + 9] = history[source + 1]
      let dip: Float = dipFade.contains(frame) ? Float(frame - dipFade.lowerBound + 1) / Float(dipFade.count) : 1
      let usedProvisional: Bool
      // Targets never pull weight down while estimates cover the frame. A
      // ready/provisional handoff then continues at full stems, never dips.
      if let index = ready.firstIndex(where: { $0.range.contains(frame) }) {
        var lo = index
        while lo > 0 && ready[lo - 1].range.upperBound == ready[lo].range.lowerBound { lo -= 1 }
        blend(toward: min(1, max(Float(frame - ready[lo].range.lowerBound + 1) / Float(fade), weight)))
        let offset = (frame - ready[index].range.lowerBound) * 8
        for channel in 0..<8 { samples[out + channel] = ready[index].samples[offset + channel] }
        usedProvisional = false
      } else if let tail = provisional, tail.range.contains(frame) {
        // A late result falls back to the previous tail estimate, never to
        // the full mix. The next result replaces these frames on arrival.
        blend(toward: min(1, max(Float(frame - tail.range.lowerBound + 1) / Float(fade), weight)))
        let offset = (frame - tail.range.lowerBound) * 8
        for channel in 0..<8 { samples[out + channel] = tail.samples[offset + channel] }
        usedProvisional = true
      } else {
        if weight > 0 { gate.gap(at: frame) }
        weight = 0
        usedProvisional = false
      }
      if usedProvisional != wasProvisional {
        wasProvisional = usedProvisional
        onTrace?(TraceRecord(event: usedProvisional ? "provisional-cover" : "provisional-end",
          generation: generation, sourceFrame: frame))
      }
      if dip < 1 { for channel in 0..<10 { samples[out + channel] *= dip } }
      samples[out + 10] = weight
      if traceCovered != (weight >= 0.999) {
        traceCovered = weight >= 0.999
        onTrace?(TraceRecord(event: traceCovered ? "coverage-restored" : "coverage-gap",
          generation: generation, sourceFrame: frame, blend: weight))
      }
      if !resting, frame >= contextStart + windowFrames {
        steadyFrames += 1
        if weight >= 0.999 { steadyFullStemFrames += 1 }
        if weight < 0.001 { steadyFallbackFrames += 1 }
        if wasProvisional { steadyProvisionalFrames += 1 }
      }
    }
    return samples
  }
  /// Take over at a pause or a cut: everything captured so far was already
  /// heard directly, so playback continues from here after the steady lag.
  func takeOverAtBreak(fadeIn: Bool = false) {
    outputPosition = end
    // A dip (no quiet moment came) resumes with a 50 ms fade instead of a hard start.
    dipFade = fadeIn ? end..<(end + 2205) : 0..<0
    ls_flush_output(core)
    outputLive = true; breakPending = false
    onTrace?(TraceRecord(event: "takeover-break", generation: generation, sourceFrame: outputPosition))
  }
  func step() {
    // The delay is established once. Missing stems use Original at this exact
    // same deadline. Results cannot push the cursor backward or extend delay.
    if outputPosition < base { outputPosition = end; resetContext(at: end, flush: true) }
    guard outputLive else { outputPosition = max(outputPosition, end - lagFrames); return }
    let deadline = paused ? end : max(outputPosition, end - lagFrames)
    let count = deadline - outputPosition
    guard count > 0 else { return }
    let start = outputPosition, samples = block(start: start, count: count)
    let endHost = captureHost - Double(end - deadline) / 44100
    let wrote = samples.withUnsafeBufferPointer {
      ls_output_write_timed(core, $0.baseAddress, UInt32(count), UInt64(start), endHost)
    }
    guard wrote == count else { onFailure?("Playback buffer full"); return }
    outputPosition += count
    if weight > 0.9 { stemCommits += 1; wasFallback = false }
    else if !wasFallback { fallbacks += 1; wasFallback = true }
    onCommit?(start, samples)
    ready.removeAll { $0.range.upperBound < outputPosition - fade }
    if let tail = provisional, tail.range.upperBound <= outputPosition { provisional = nil }
    if cacheBytes > memoryLimit { onFailure?("Stem buffer exceeded its bound") }
  }
}
