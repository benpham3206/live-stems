import AppKit
import AudioCore
import AVFoundation

/// The production pitch graph, real AppKit actions, and explicit seek cuts.
/// Audio renders to memory only. Spotify boundaries are replaced with a fixture.
enum PitchE2E {
  private static func require(_ value: Bool, _ message: String) throws {
    if !value { throw StemError(message) }
  }

  static func run(_ out: URL) throws {
    var measured = [[String: Any]]()
    for semitones in [-12, -2, 0, 2, 12] {
      let samples = try render(semitones: semitones)
      let hz = frequency(Array(samples[22050..<66150]))
      let expected = 440 * pow(2, Double(semitones) / 12)
      try require(abs(hz - expected) < 2, "Pitch \(semitones): heard \(hz) Hz, expected \(expected)")
      try require(samples.allSatisfy { $0.isFinite && abs($0) < 1 }, "Invalid or clipped pitch output")
      measured.append(["semitones": semitones, "measured_hz": hz, "expected_hz": expected])
    }
    try rapidSeeks()
    try sourceSwitch(out)
    try panelActions(out)
    try JSONSerialization.data(withJSONObject: ["status": "pass", "pitch": measured,
      "checks": ["production pitch graph", "dynamic pitch and reset", "rapid explicit seeks flush queues",
        "stale result rejection", "pitch-only takeover", "AppKit seek actions and unsupported source"]], options: [.prettyPrinted, .sortedKeys])
      .write(to: out.appendingPathComponent("pitch.json"))
    print("PASS pitch · production graph, dynamic reset, rapid seeks, and panel actions")
  }

  private static func frequency(_ samples: [Float]) -> Double {
    let crossings = (1..<samples.count).filter { samples[$0 - 1] <= 0 && samples[$0] > 0 }
    guard let first = crossings.first, let last = crossings.last, last > first else { return 0 }
    return Double(crossings.count - 1) * 44100 / Double(last - first)
  }

  private static func render(semitones: Int) throws -> [Float] {
    let engine = AVAudioEngine()
    let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
    var frame = 0, sourceHz = 440.0
    let source = AVAudioSourceNode(format: format) { _, _, count, list in
      for buffer in UnsafeMutableAudioBufferListPointer(list) {
        let data = buffer.mData!.assumingMemoryBound(to: Float.self)
        for i in 0..<Int(count) { data[i] = Float(0.2 * sin(2 * .pi * sourceHz * Double(frame + i) / 44100)) }
      }
      frame += Int(count)
      return noErr
    }
    engine.attach(source)
    let pitch = PitchShift(engine: engine, source: source, format: format)
    try require(pitch.isBypassed, "Zero pitch does not bypass the effect")
    try require(!pitch.set(13) && pitch.isBypassed, "Out-of-range pitch changed the effect")
    try require(pitch.set(semitones), "Valid pitch rejected")
    try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 512)
    try engine.start()
    defer { engine.stop() }
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512)!
    func pull(_ frames: Int) throws -> [Float] {
      var result = [Float](), attempts = 0
      while result.count < frames {
        attempts += 1
        try require(attempts < 10000, "Offline pitch render stalled")
        let status = try engine.renderOffline(AVAudioFrameCount(min(512, frames - result.count)), to: buffer)
        if status == .success {
          result.append(contentsOf: UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
        } else { try require(status != .error, "Offline pitch render failed") }
      }
      return result
    }
    let original = try pull(88200)
    pitch.set(2)
    let changed = try pull(44100)
    try require(abs(frequency(Array(changed[11025...])) - 440 * pow(2, 2.0 / 12)) < 2,
      "Changing pitch while rendering did not reach the new key")
    engine.pause()
    pitch.reset()
    sourceHz = 880
    try engine.start()
    let reset = try pull(44100)
    try require(abs(frequency(Array(reset[11025...])) - 880 * pow(2, 2.0 / 12)) < 2,
      "Pitch reset kept old signal or lost the selected key")
    return original
  }

  private static func rapidSeeks() throws {
    guard let core = ls_create(44100, 44100) else { throw StemError("Seek core unavailable") }
    defer { ls_destroy(core) }
    let pipeline = StemPipeline(core: core)
    pipeline.start(generation: 1)
    var value = PlaybackSnapshot(trackID: "seek", title: "Seek", duration: 200, position: 10, isPlaying: true)
    pipeline.observe(value, hostTime: 100)
    pipeline.ingest([Float](repeating: 0.2, count: 176400), hostTime: 100)
    pipeline.step()
    guard let stale = pipeline.job() else { throw StemError("Seek check has no in-flight result") }
    for (position, host) in [(70.0, 100.2), (80.0, 100.4)] {
      value.position = position
      try require(pipeline.observe(value, hostTime: host, forceSeek: true), "Repeated seek was suppressed")
      try require(ls_queued(core) == 0, "Pre-seek audio remained queued")
    }
    try require(pipeline.hardCuts == 2, "Rapid seeks did not produce distinct cuts")
    let before = pipeline.discarded
    pipeline.accept(StemWindow(range: stale.range, samples: [Float](repeating: 0, count: Int(stale.range.count) * 8)))
    try require(pipeline.discarded > before, "Old worker result survived explicit seeks")
  }

  private static func panelActions(_ out: URL) throws {
    _ = NSApplication.shared
    var position = 60.0
    let release = DispatchSemaphore(value: 0)
    var fixtureWrites = 0
    defer { release.signal() }
    let spotify = SpotifyState(reader: {
      PlaybackSnapshot(trackID: "panel", title: "Panel", duration: 200, position: position, isPlaying: false)
    }, positionWriter: { target, _ in
      if fixtureWrites == 0 {
        guard release.wait(timeout: .now() + 2) == .success else { throw StemError("Panel seek fixture timed out") }
      }
      fixtureWrites += 1
      position = target
    })
    let session = SessionController(traceDirectory: out.appendingPathComponent("session"), spotifyState: spotify, source: .spotify)
    let controller = MenuController(activateOnStatusClick: false, terminate: {}, start: {}, session: session)
    guard let window = controller.e2eWindow, let content = window.contentView else { throw StemError("No test panel") }
    defer { window.orderOut(nil); session.shutdownSync() }
    func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap { descendants($0) } }
    let views = descendants(content)
    func popup(_ label: String) throws -> NSPopUpButton {
      guard let view = views.compactMap({ $0 as? NSPopUpButton }).first(where: { $0.accessibilityLabel() == label })
      else { throw StemError("No \(label)") }
      return view
    }
    func button(_ label: String) throws -> NSButton {
      guard let view = views.compactMap({ $0 as? NSButton }).first(where: { $0.accessibilityLabel() == label })
      else { throw StemError("No \(label)") }
      return view
    }
    let pitch = try popup("Transpose in semitones")
    try require(!session.e2eNeedsOutput, "Neutral controls unexpectedly need processed output")
    pitch.selectItem(withTag: 2)
    pitch.sendAction(pitch.action, to: pitch.target)
    try require(session.e2eNeedsOutput, "Pitch with neutral stems stayed on direct output")
    try button("Reset pitch").performClick(nil)
    try require(!session.e2eNeedsOutput && pitch.selectedItem?.tag == 0, "Pitch reset did not restore neutral output")
    let interval = try popup("Seek interval")
    interval.selectItem(withTag: 15)
    interval.sendAction(interval.action, to: interval.target)
    let back = try button("Rewind 15 seconds"), forward = try button("Forward 15 seconds")
    func shortcut(_ code: UInt16, modifiers: NSEvent.ModifierFlags = [.command, .shift]) -> Bool {
      let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
        timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "",
        charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)!
      return window.performKeyEquivalent(with: event)
    }
    let shortcutStart = stemClock()
    try require(shortcut(124), "Forward shortcut was not handled")
    try require(stemClock() - shortcutStart < 0.25, "Shortcut blocked the UI waiting for Spotify")
    try require(forward.cell?.isHighlighted == true && back.cell?.isHighlighted == false,
      "Shortcut did not press only the forward button")
    if let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
      content.cacheDisplay(in: content.bounds, to: bitmap)
      try bitmap.representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent("seek-pressed.png"))
    }
    try require(shortcut(123), "Pending shortcut was not handled")
    release.signal()
    let deadline = Date().addingTimeInterval(3)
    while controller.e2eSeeking && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    try require(forward.isEnabled && position == 75, "Forward action failed")
    try require(shortcut(123), "Rewind shortcut was not handled")
    let backDeadline = Date().addingTimeInterval(3)
    while controller.e2eSeeking && Date() < backDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    try require(back.isEnabled && position == 60 && fixtureWrites == 2, "Backward action or pending guard failed")
    let source = try popup("Audio source")
    let unsupported = NSMenuItem(title: "Unsupported fixture", action: nil, keyEquivalent: "")
    unsupported.representedObject = "test.unsupported"
    source.menu!.addItem(unsupported)
    source.select(unsupported)
    source.sendAction(source.action, to: source.target)
    try require(!back.isEnabled && !forward.isEnabled && !interval.isEnabled, "Unsupported source allowed seeking")
  }

  private static func sourceSwitch(_ out: URL) throws {
    let queue = DispatchQueue(label: "test.session.seek-race")
    let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
    let readRelease = DispatchSemaphore(value: 0)
    var writes = 0
    let spotify = SpotifyState(reader: {
      guard readRelease.wait(timeout: .now() + 2) == .success else { throw StemError("Source race fixture timed out") }
      return PlaybackSnapshot(trackID: "race", title: "Race", duration: 200, position: 60, isPlaying: false)
    }, positionWriter: { _, _ in writes += 1 })
    let session = SessionController(traceDirectory: out.appendingPathComponent("race-session"), spotifyState: spotify, source: .spotify, queue: queue)
    queue.async { entered.signal(); _ = release.wait(timeout: .now() + 2) }
    defer { release.signal(); readRelease.signal(); session.shutdownSync() }
    try require(entered.wait(timeout: .now() + 2) == .success, "Session queue fixture did not start")
    var completed = false
    session.seek(by: 10) { _ in completed = true }
    session.setSource(AudioSource(bundleID: "test.other", name: "Other"))
    release.signal()
    _ = session.e2eNeedsOutput // drain both queued operations before permitting the write
    readRelease.signal()
    let deadline = Date().addingTimeInterval(3)
    while !completed && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    try require(completed && writes == 0, "Queued seek wrote after the source switched")
  }
}
