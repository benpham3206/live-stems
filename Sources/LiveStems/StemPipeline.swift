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
  private(set) var lateResults = 0, acceptedResults = 0
  private(set) var steadyFrames = 0, steadyFullStemFrames = 0, steadyFallbackFrames = 0
  var timings = [Double]()
  private var history = [Float](), ready = [Chunk]()
  private var inflight: Job?, version: UInt64 = 0, contextStart = 0, scheduledEnd = 0
  private var snapshot: PlaybackSnapshot?, snapshotHost = 0.0, captureHost = 0.0
  private var wasFallback = false
  private var traceCovered = false
  var onFailure: ((String) -> Void)?, onCommit: ((Int, [Float]) -> Void)?
  var onTrace: ((TraceRecord) -> Void)?
  func estimatedTrackPosition(at frame: Int) -> Double? {
    guard let snapshot else { return nil }
    let current = snapshot.position + (snapshot.isPlaying ? captureHost - snapshotHost : 0)
    return current - Double(end - frame) / 44100
  }
  init(core: OpaquePointer) { self.core = core }
  var cacheBytes: Int { ready.reduce(0) { $0 + $1.samples.count * MemoryLayout<Float>.size } }
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
    discarded = 0; lateResults = 0; acceptedResults = 0; stemCommits = 0
    fallbacks = 0; hardCuts = 0; wasFallback = false; timings.removeAll()
    steadyFrames = 0; steadyFullStemFrames = 0; steadyFallbackFrames = 0
    ls_reset(core)
  }
  func ingest(_ samples: [Float], hostTime: Double = stemClock()) {
    guard samples.count % 2 == 0, samples.allSatisfy(\.isFinite) else {
      onFailure?("Invalid capture samples"); return
    }
    captureHost = hostTime
    guard !paused else { return }
    history.append(contentsOf: samples); end += samples.count / 2
    if end - base > 3 * 44100 {
      let remove = end - base - 2 * 44100
      history.removeFirst(remove * 2); base += remove
    }
  }
  @discardableResult
  func observe(_ value: PlaybackSnapshot, hostTime: Double = stemClock()) -> Bool {
    guard value.position.isFinite, value.duration.isFinite,
      value.position >= 0, value.position <= 86400, value.duration >= 0 else { lost(); return false }
    var cut = false, natural = false
    if let old = snapshot {
      let expected = old.position + (old.isPlaying ? max(0, hostTime - snapshotHost) : 0)
      if value.trackID != old.trackID {
        cut = true
        natural = old.isPlaying && value.isPlaying && old.duration > 0
          && abs(expected - old.duration) < 1.2 && value.position < 1.5
      } else if abs(value.position - expected) > 0.35 { cut = true }
    }
    let changedPause = paused != !value.isPlaying
    paused = !value.isPlaying
    if cut {
      let position = max(0, value.position + (value.isPlaying && captureHost > 0 ? captureHost - hostTime : 0))
      let boundary = natural ? max(contextStart, end - Int(position * 44100)) : end
      resetContext(at: boundary, flush: !natural)
    } else if changedPause {
      // Drain already captured audio on pause. A resume begins new model
      // context but retains the queued source timeline, including short pauses.
      resetContext(at: end, flush: false)
    }
    snapshot = value; snapshotHost = hostTime
    if cut || changedPause {
      onTrace?(TraceRecord(event: cut ? "source-change" : "playback-state", generation: generation,
        sourceFrame: end, estimatedTrackSeconds: value.position, hardCuts: hardCuts))
    }
    return cut && !natural
  }
  func lost() {
    // Capture frame indexes remain valid if Spotify metadata is temporarily
    // unavailable. Never substitute a song-position clock for captured audio.
    snapshot = nil
    paused = false
  }
  func resetProcessor() {
    generation += 1; version += 1
    contextStart = max(base, end - windowFrames)
    scheduledEnd = contextStart
    inflight = nil; ready.removeAll(); weight = 0; traceCovered = false
    onTrace?(TraceRecord(event: "processor-reset", generation: generation, sourceFrame: outputPosition))
  }
  private func resetContext(at frame: Int, flush: Bool) {
    version += 1; contextStart = frame; scheduledEnd = frame
    ready.removeAll { flush || $0.range.upperBound > frame }
    if flush { weight = 0; outputPosition = end; hardCuts += 1; ls_flush_output(core) }
  }
  func job() -> AudioWindow? {
    guard inflight == nil, !paused else { return nil }
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
        windowStart: result.range.start, lateResults: lateResults))
      return
    }
    let lo = (job.core.lowerBound - job.window.lowerBound) * 8
    // Join two estimates of the same source frames. Touch only frames that
    // have not entered the output queue; never replace already played audio.
    if outputPosition < job.core.lowerBound,
      let last = ready.indices.last, ready[last].range.upperBound == job.core.lowerBound {
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
    ready.append(Chunk(range: job.core, samples: Array(result.samples[lo..<lo + job.core.count * 8])))
    acceptedResults += 1
    onTrace?(TraceRecord(event: "accepted-result", generation: generation,
      sourceFrame: job.core.lowerBound, sourceEnd: job.core.upperBound,
      windowStart: result.range.start, deadlineSlackSeconds: Double(job.core.lowerBound - outputPosition) / 44100))
  }
  private func block(start: Int, count: Int) -> [Float] {
    var samples = [Float](repeating: 0, count: count * 11)
    for i in 0..<count {
      let frame = start + i, out = i * 11, source = (frame - base) * 2
      samples[out + 8] = history[source]; samples[out + 9] = history[source + 1]
      if let index = ready.firstIndex(where: { $0.range.contains(frame) }) {
        var lo = index
        while lo > 0 && ready[lo - 1].range.upperBound == ready[lo].range.lowerBound { lo -= 1 }
        let target = min(1, Float(frame - ready[lo].range.lowerBound + 1) / Float(fade))
        weight += max(-1 / Float(fade), min(1 / Float(fade), target - weight))
        let offset = (frame - ready[index].range.lowerBound) * 8
        for channel in 0..<8 { samples[out + channel] = ready[index].samples[offset + channel] }
      } else { weight = 0 }
      samples[out + 10] = weight
      if traceCovered != (weight >= 0.999) {
        traceCovered = weight >= 0.999
        onTrace?(TraceRecord(event: traceCovered ? "coverage-restored" : "coverage-gap",
          generation: generation, sourceFrame: frame, blend: weight))
      }
      if frame >= contextStart + windowFrames {
        steadyFrames += 1
        if weight >= 0.999 { steadyFullStemFrames += 1 }
        if weight < 0.001 { steadyFallbackFrames += 1 }
      }
    }
    return samples
  }
  func step() {
    // The delay is established once. Missing stems use Original at this exact
    // same deadline. Results cannot push the cursor backward or extend delay.
    if outputPosition < base { outputPosition = end; resetContext(at: end, flush: true) }
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
    if cacheBytes > memoryLimit { onFailure?("Stem buffer exceeded its bound") }
  }
}
