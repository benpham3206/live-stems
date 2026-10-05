import AudioCore
import Foundation

// The session queue owns every pipeline mutation. Audio and state readers
// publish events here; their callbacks never mutate caches on another queue.
final class SessionController {
  private let queue = DispatchQueue(label: "stems.session", qos: .userInitiated)
  private var worker: WorkerClient?, audio: AudioSession?, pipeline: StemPipeline?,
    timer: DispatchSourceTimer?
  private var spotify: SpotifyState?
  /// The app being separated. Spotify adds transport notices and the self-pause.
  private(set) var source: AudioSource
  private let stateSource: SpotifyState
  private var token: UInt64 = 0, job: UInt64 = 0, busy = false, enabled = false,
    outputOn = false, stemsSelected = true, warmupsLeft = 0
  private var awaitingFirstAudio = false, cutHost = 0.0
  private var stemsWantedAt: Double?  // stems wanted before takeover: waiting for (or making) a break
  private var controls = StemControls(), began = 0.0, capturePeak: Float = 0,
    lastCaptureEndHost = 0.0
  private var lastDeviceCheck = 0.0, lastDiagnostics = 0.0, lastStatus = ""
  private let trace: LiveTrace
  private var lastTrace = 0.0
  private var quitCompletion: (() -> Void)?
  private var quitVersion: UInt64 = 0, quitStarted = 0.0
  // A running session is real-time work: without this, App Nap can coalesce the
  // 10 ms tick when no audio plays (before takeover, between sessions).
  private var activity: NSObjectProtocol?
  var onReady: (() -> Void)?
  var onStatus: ((String, String, Bool, Bool) -> Void)?
  init(traceDirectory: URL = LocalSettings.evidence, spotifyState: SpotifyState = SpotifyState(),
    source: AudioSource = .saved) {
    trace = LiveTrace(directory: traceDirectory)
    stateSource = spotifyState
    self.source = source
  }
  /// Switch the app being separated; a running session restarts on the new app.
  func setSource(_ value: AudioSource) {
    queue.async {
      guard value != self.source else { return }
      self.source = value
      guard self.enabled else { return }
      self.end("\(value.name) selected")
      self.queue.async { self.start() }
    }
  }
  private func status(_ text: String) {
    guard text != lastStatus else { return }
    lastStatus = text
    let name = audio?.name ?? outputName(defaultOutput())
    let active = enabled
    let stems = stemsSelected
    DispatchQueue.main.async { self.onStatus?(text, name, active, stems) }
  }
  func start() {
    queue.async {
      guard !self.enabled else { return }
      self.enabled = true
      self.activity = ProcessInfo.processInfo.beginActivity(
        options: [.userInitiated, .latencyCritical], reason: "Live Stems real-time audio")
      self.stemsSelected = true
      self.token += 1
      let token = self.token
      self.trace.record(TraceRecord(event: "start", generation: token))
      self.startProcessor(token: token)
    }
  }
  private func startProcessor(token: UInt64) {
    busy = true
    self.status(audio == nil ? "\(source.name) · starting" : "Original · restarting processor")
    let worker = WorkerClient()
    self.worker = worker
    worker.start { result in
      self.queue.async {
        guard self.enabled, self.token == token, self.worker === worker else {
          worker.stop()
          return
        }
        do {
          try result.get()
          self.busy = false
          if let audio = self.audio {
            ls_stems(audio.core, self.stemsSelected ? 1 : 0)
            self.status(self.pipeline.map(self.mixStatus) ?? "Original mix")
            return
          }
          let audio = try AudioSession(source: self.source)
          self.audio = audio
          let pipeline = StemPipeline(core: audio.core!)
          pipeline.onFailure = { [weak self = self] message in self?.end(message) }
          pipeline.onTrace = { [weak self = self] value in self?.trace.record(value) }
          self.pipeline = pipeline
          self.applyControls()
          try audio.start()
          // Hardware startup can block while the tap already captures. Those
          // samples predate our playback clock and must not become a backlog.
          pipeline.start(generation: token)
          pipeline.holdForBreak()
          audio.discardCapturedAudio()
          self.busy = false
          self.began = stemClock()
          self.lastCaptureEndHost = 0
          if self.source.isSpotify {
            let spotify = self.stateSource
            self.spotify = spotify
            spotify.start(onSnapshot: { value, host in
              self.queue.async {
                guard self.enabled, self.token == token else { return }
                if self.pipeline?.observe(value, hostTime: host) == true {
                  self.audio?.discardCapturedAudio(at: host)
                  self.warmupsLeft = 3
                  self.cutHost = host
                  self.awaitingFirstAudio = true
                  self.capturePeak = 0
                }
              }
            }, onUnavailable: { message in
              self.queue.async {
                guard self.enabled, self.token == token else { return }
                self.pipeline?.lost()
                self.status(message + " · audio continues")
              }
            })
          }
          let timer = DispatchSource.makeTimerSource(queue: self.queue)
          self.timer = timer
          timer.schedule(deadline: .now(), repeating: .milliseconds(10))
          timer.setEventHandler { [weak self = self] in self?.tick() }
          timer.resume()
          self.status("Original · splitting")
        } catch { self.end(error.localizedDescription) }
      }
    }
  }
  private func tick() {
    guard enabled, let audio = audio, let pipeline = pipeline else { return }
    do {
      if stemClock() - lastDeviceCheck > 0.5 {
        lastDeviceCheck = stemClock()
        if defaultOutput() != audio.outputID {
          // Follow headphones or speakers; capture and the delay stay, so no new takeover.
          try audio.followOutput()
          trace.record(TraceRecord(event: "output-change", generation: token,
            sourceFrame: pipeline.outputPosition, outputBufferFrames: audio.outputBufferFrames))
          self.status(mixStatus(pipeline))
        }
      }
      let samples = try audio.drain()
      capturePeak = max(capturePeak, samples.map { abs($0) }.max() ?? 0)
      if !samples.isEmpty {
        lastCaptureEndHost = audio.lastDrainEndHostSeconds
        pipeline.ingest(samples, hostTime: lastCaptureEndHost)
        if awaitingFirstAudio, capturePeak > 0.005 {
          awaitingFirstAudio = false
          trace.record(TraceRecord(event: "skip-first-audio", generation: pipeline.generation,
            sourceFrame: pipeline.end, elapsedSeconds: stemClock() - cutHost))
        }
      }
      if pipeline.tailScanning, stemClock() - pipeline.cutHost > 0.5 { pipeline.cancelTailScan() }
      if pipeline.paused { began = stemClock() }
      // Only Spotify reports pauses; other apps may simply be silent for a while.
      if spotify != nil, !pipeline.paused, stemClock() - began > 10, pipeline.end == 0 {
        throw StemError("\(source.name) capture silent · direct playback restored")
      }
      pipeline.step()
      if quitCompletion != nil, quitReady(audio, pipeline) {
        finishQuit()
        return
      }
      if !outputOn { try takeOverIfReady(audio, pipeline) }
      startJob()
      startWarmup()
      guard enabled else { return }
      if stemClock() - lastTrace >= 0.25 {
        lastTrace = stemClock()
        var rendered = LSRenderSnapshot()
        let coherent = ls_render_snapshot(audio.core, &rendered) != 0
        let frame = coherent ? rendered.source_frame : UInt64.max
        let renderedWeight = rendered.stem_weight
        let captureHost = coherent ? Double(rendered.capture_nanos) / 1e9 : 0
        let renderHost = coherent ? Double(rendered.render_nanos) / 1e9 : 0
        trace.record(TraceRecord(event: "sample", generation: pipeline.generation, sourceFrame: pipeline.end,
          renderedFrame: frame == UInt64.max ? nil : frame,
          queuedFrames: ls_queued(audio.core), fullStemFrames: pipeline.steadyFullStemFrames,
          fallbackFrames: pipeline.steadyFallbackFrames, blend: renderedWeight,
          stemsSelected: stemsSelected, paused: pipeline.paused,
          estimatedTrackSeconds: frame == UInt64.max ? nil : pipeline.estimatedTrackPosition(at: Int(frame)),
          captureHostSeconds: captureHost > 0 ? captureHost : nil,
          renderHostSeconds: renderHost > 0 ? renderHost : nil,
          estimatedCaptureToRenderSeconds: captureHost > 0 && renderHost > 0 ? renderHost - captureHost : nil,
          hardCuts: pipeline.hardCuts, lateResults: pipeline.lateResults,
          thermalState: ProcessInfo.processInfo.thermalState.rawValue))
      }
      status(mixStatus(pipeline))
      if ls_overflows(audio.core) > 0 {
        throw StemError("Audio buffer overflow · direct playback restored")
      }
      if stemClock() - lastDiagnostics >= 2 {
        lastDiagnostics = stemClock()
        saveDiagnostics()
        capturePeak = 0
      }
    } catch { end(error.localizedDescription) }
  }
  /// Quit hands back to the source app at a break: a Spotify pause (after the
  /// queued tail drains), or for other apps a quiet moment, at most 3 s later.
  private func quitReady(_ audio: AudioSession, _ pipeline: StemPipeline) -> Bool {
    if pipeline.paused { return ls_queued(audio.core) == 0 }
    return spotify == nil && (pipeline.quietFrames >= 11025 || stemClock() - quitStarted > 3)
  }
  /// The source app plays directly until a break, where the 0.3 s shift is
  /// silent: a pause, a skip or seek (Spotify notices), or 250 ms of quiet audio
  /// (any app). Stems wanted before a break: Spotify is paused for a blink;
  /// other apps get up to 3 s to go quiet, then a dip (a 0.3 s gap that fades
  /// back in). Never a replay or a speed change.
  private func takeOverIfReady(_ audio: AudioSession, _ pipeline: StemPipeline) throws {
    let atBreak = pipeline.paused || pipeline.breakPending || pipeline.quietFrames >= 11025
    if !pipeline.resting, !atBreak, stemsWantedAt == nil {
      stemsWantedAt = stemClock()
      spotify?.command("pause")
      trace.record(TraceRecord(event: spotify == nil ? "await-quiet" : "self-pause",
        generation: token, sourceFrame: pipeline.end))
    }
    let waited = stemsWantedAt.map { stemClock() - $0 > 3 } ?? false
    guard atBreak || waited else { return }
    // Mute first: if macOS refuses, nothing has moved yet.
    try audio.setOriginalSuppressed(true)
    pipeline.takeOverAtBreak(fadeIn: !atBreak)
    pipeline.step()
    // Always undo our own pause, even if its notice never came: the commands
    // run in order on one queue, so Spotify can never be left paused by us.
    if stemsWantedAt != nil { spotify?.command("play") }
    stemsWantedAt = nil
    audio.setOutputEnabled(true)
    outputOn = true
    trace.record(TraceRecord(event: "handoff", generation: token,
      sourceFrame: pipeline.outputPosition, queuedFrames: ls_queued(audio.core),
      outputBufferFrames: audio.outputBufferFrames))
    DispatchQueue.main.async { self.onReady?() }
  }
  private func startJob() {
    guard enabled, !busy, let worker = worker, let pipeline = pipeline,
      let window = pipeline.job() else { return }
    busy = true
    start(window: window, worker: worker, warmup: false)
  }
  private func startWarmup() {
    guard enabled, !busy, warmupsLeft > 0, let worker = worker, let pipeline = pipeline,
      let window = pipeline.warmupWindow() else { return }
    busy = true
    warmupsLeft -= 1
    start(window: window, worker: worker, warmup: true)
  }
  // Results schedule the next job on arrival instead of waiting for the 10 ms
  // tick. The slice is cheap; the worker round trip dominates either way.
  private func start(window: AudioWindow, worker: WorkerClient, warmup: Bool) {
    guard let pipeline = pipeline else { busy = false; return }
    job += 1
    let began = stemClock()
    let jobID = job
    trace.record(TraceRecord(event: warmup ? "warmup-start" : "job-start", generation: pipeline.generation,
      sourceFrame: pipeline.outputPosition, windowStart: window.range.start,
      windowFrames: window.range.count, jobID: jobID, workerPID: worker.pid))
    worker.separate(window, jobID: job) { result in
      self.queue.async {
        guard self.worker === worker else { return }
        self.busy = false
        guard self.enabled, let current = self.pipeline else { return }
        do {
          let output = try result.get()
          if warmup {
            self.trace.record(TraceRecord(event: "warmup-finish", generation: output.range.generation,
              sourceFrame: current.outputPosition, windowStart: output.range.start,
              windowFrames: output.range.count, jobID: jobID, workerPID: worker.pid,
              elapsedSeconds: stemClock() - began))
          } else {
            current.timings.append(stemClock() - began)
            self.trace.record(TraceRecord(event: "job-finish", generation: output.range.generation,
              sourceFrame: current.outputPosition, windowStart: output.range.start,
              windowFrames: output.range.count, jobID: jobID, workerPID: worker.pid,
              elapsedSeconds: stemClock() - began))
            if current.timings.count > 2048 { current.timings.removeFirst() }
            current.accept(output)
          }
          self.startJob()
        } catch { self.end(error.localizedDescription) }
      }
    }
  }
  private func applyControls() {
    if let core = audio?.core {
      controls.gains.withUnsafeBufferPointer {
        ls_controls(core, $0.baseAddress, controls.mute, controls.solo)
      }
    }
    // Equal effective gains render Original at that gain, so stems are not needed.
    pipeline?.setResting(!stemsSelected || Set(controls.effectiveGains).count == 1)
  }
  func setControls(_ value: StemControls) {
    queue.async {
      self.controls = value
      self.trace.record(TraceRecord(event: "controls", generation: self.pipeline?.generation ?? self.token,
        sourceFrame: self.pipeline?.outputPosition, muteMask: value.mute, soloMask: value.solo, gains: value.gains))
      self.applyControls()
    }
  }
  /// Pre-fader stem peaks since the last call; zeros when no session runs.
  func takeMeters(_ done: @escaping ([Float]) -> Void) {
    queue.async {
      var peaks: [Float] = [0, 0, 0, 0]
      if let core = self.audio?.core { ls_take_meters(core, &peaks) }
      DispatchQueue.main.async { done(peaks) }
    }
  }
  private func mixStatus(_ pipeline: StemPipeline) -> String {
    if pipeline.paused { return pipeline.statusText }
    if !stemsSelected { return "Original mix · model asleep" }
    if pipeline.resting {
      let gain = controls.effectiveGains[0]
      if gain == 0 { return "Muted · model asleep" }
      return gain == 1 ? "Original · model asleep" : "Original at \(Int(gain * 100))% · model asleep"
    }
    return pipeline.statusText
  }
  /// Back to the stem splitter from Original or a stopped worker: stems are
  /// selected, a worker starts if none runs, and Original fades into stems.
  func restoreStems() { queue.async { self.selectStems() } }
  private func selectStems() {
    guard enabled, let audio = audio, let pipeline = pipeline else { return }
    stemsSelected = true
    ls_stems(audio.core, 1)
    trace.record(TraceRecord(event: "mix", generation: pipeline.generation,
      sourceFrame: pipeline.outputPosition, stemsSelected: true))
    applyControls()
    if worker == nil { startProcessor(token: token) }
    lastStatus = ""
    status(mixStatus(pipeline))
  }
  func useDirectPlayback() {
    queue.async {
      guard self.enabled, let audio = self.audio, let pipeline = self.pipeline else {
        self.end("\(self.source.name) · direct playback"); return
      }
      self.stopProcessor(audio, pipeline)
      self.trace.record(TraceRecord(event: "mix", generation: pipeline.generation,
        sourceFrame: pipeline.outputPosition, stemsSelected: false))
      self.status("Original mix · processor stopped")
      self.saveDiagnostics()
    }
  }
  /// Original only, worker stopped; capture and the playback clock keep running.
  private func stopProcessor(_ audio: AudioSession, _ pipeline: StemPipeline) {
    stemsSelected = false
    ls_stems(audio.core, 0)
    worker?.stop(); worker = nil; busy = false
    pipeline.resetProcessor()
  }
  private func saveDiagnostics() {
    guard let audio = audio, let p = pipeline else { return }
    var rendered = LSRenderSnapshot()
    let valid = ls_render_snapshot(audio.core, &rendered) != 0
      && rendered.source_frame != UInt64.max && rendered.capture_nanos > 0 && rendered.render_nanos > 0
    let observedAge = valid ? (Double(rendered.render_nanos) - Double(rendered.capture_nanos)) / 1e9 : nil
    SessionDiagnostics(
      observedUptime: stemClock(), sessionGeneration: token,
      appPID: ProcessInfo.processInfo.processIdentifier, workerPID: worker?.pid ?? 0,
      capturePeak: capturePeak, active: enabled, handedOff: outputOn,
      captureFrames: p.end, playedFrames: ls_played(audio.core),
      queuedFrames: ls_queued(audio.core), historyFrames: p.end - p.base,
      underrunFrames: ls_underruns(audio.core), overflowCount: ls_overflows(audio.core),
      discardedResults: p.discarded, inferenceSeconds: p.timings,
      estimatedDelaySeconds: Double(p.lagFrames) / 44100,
      observedCaptureToRenderSeconds: observedAge,
      fallbacks: p.fallbacks, paused: p.paused, blendWeight: p.weight,
      cacheBytes: p.cacheBytes, cacheLimitBytes: p.memoryLimit, jumps: p.jumps, hardCuts: p.hardCuts,
      stemsSelected: stemsSelected, modelResting: p.resting, windowFrames: p.windowFrames, hopFrames: p.hop,
      lateResults: p.lateResults, acceptedResults: p.acceptedResults,
      steadyFrames: p.steadyFrames, steadyFullStemFrames: p.steadyFullStemFrames,
      steadyFallbackFrames: p.steadyFallbackFrames, steadyProvisionalFrames: p.steadyProvisionalFrames
    ).save()
  }
  private func end(_ message: String) {
    let completion = quitCompletion
    quitCompletion = nil
    trace.record(TraceRecord(event: "stop", generation: token, sourceFrame: pipeline?.outputPosition, reason: message))
    enabled = false
    if let activity { ProcessInfo.processInfo.endActivity(activity) }
    activity = nil
    token += 1
    timer?.cancel()
    timer = nil
    // Restore audio before waiting for the state reader's bounded script call.
    audio?.stop()
    spotify?.stop()
    spotify = nil
    outputOn = false
    saveDiagnostics()
    pipeline = nil
    audio = nil
    worker?.stop()
    worker = nil
    busy = false
    status(message)
    if let completion {
      let version = quitVersion
      DispatchQueue.main.async {
        // Reopen is a main-thread action that queues cancellation here before
        // a pending main-thread termination can check its session generation.
        let current = self.queue.sync { self.quitVersion == version }
        if current { completion() }
      }
    }
  }
  func quit(completion: @escaping () -> Void) {
    queue.async {
      self.quitVersion &+= 1
      self.quitCompletion = completion
      self.quitStarted = stemClock()
      // Before takeover Spotify is still direct: nothing to relay or drain.
      guard self.enabled, self.outputOn, let audio = self.audio, let pipeline = self.pipeline else {
        self.finishQuit(); return
      }
      self.stopProcessor(audio, pipeline)
      self.trace.record(TraceRecord(event: "quit-relay", generation: self.token,
        sourceFrame: pipeline.outputPosition, queuedFrames: ls_queued(audio.core), stemsSelected: false))
      self.saveDiagnostics()
    }
  }
  func cancelQuit() {
    queue.async {
      self.quitVersion &+= 1
      self.quitCompletion = nil
      guard self.enabled else { return }
      self.trace.record(TraceRecord(event: "quit-reopen", generation: self.token,
        sourceFrame: self.pipeline?.outputPosition))
      self.selectStems()
    }
  }
  private func finishQuit() {
    end("\(source.name) · direct playback")
    trace.flushSync()
  }
  func shutdownSync() {
    queue.sync { self.end("\(source.name) · direct playback"); self.trace.flushSync() }
  }
}
