import AVFoundation
import AudioCore
import CoreAudio
import Foundation

func audioAddress(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
  AudioObjectPropertyAddress(
    mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain)
}
func audioCheck(_ status: OSStatus, _ label: String) throws {
  if status != noErr { throw StemError("\(label) (\(status))") }
}
func defaultOutput() -> AudioObjectID {
  var a = audioAddress(kAudioHardwarePropertyDefaultOutputDevice)
  var value: UInt32 = 0
  var size = UInt32(4)
  AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &value)
  return value
}
func outputName(_ id: AudioObjectID) -> String {
  var a = audioAddress(kAudioObjectPropertyName)
  var value: CFString = "" as CFString
  var size = UInt32(MemoryLayout<CFString>.size)
  withUnsafeMutablePointer(to: &value) { _ = AudioObjectGetPropertyData(id, &a, 0, nil, &size, $0) }
  return value as String
}
final class AudioSession {
  private(set) var core: OpaquePointer!
  private(set) var rate = 48000.0
  private(set) var outputID = defaultOutput()
  var name: String { outputName(outputID) }
  private var tapID: AudioObjectID = 0, aggregate: AudioObjectID = 0, ioProc: AudioDeviceIOProcID?
  private let description = CATapDescription(), engine = AVAudioEngine()
  private var node: AVAudioSourceNode?, converter: AVAudioConverter?
  private var pitch: PitchShift?
  private var inputFormat: AVAudioFormat!,
    modelFormat = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
  private var started = false
  private var processListener: AudioObjectPropertyListenerBlock?
  private var captureBoundary = 0.0
  private(set) var lastDrainEndHostSeconds = 0.0
  private(set) var outputBufferFrames: UInt32 = 0
  init(source: AudioSource = .spotify) throws {
    do {
      guard outputID != 0 else { throw StemError("No output device") }
      description.name = "Live Stems \(source.name)"
      description.uuid = UUID()
      description.isPrivate = true
      description.isMixdown = true
      description.isMono = false
      description.isExclusive = false
      if #available(macOS 26.0, *) {
        description.bundleIDs = Self.tapBundleIDs(for: source.bundleID)
        description.isProcessRestoreEnabled = true
      } else {
        // Pre-26 has no bundle-ID tap: include the matching processes by object ID.
        description.processes = Self.tapProcesses(for: source.bundleID)
      }
      description.muteBehavior = .unmuted
      try audioCheck(
        AudioHardwareCreateProcessTap(description, &tapID), "Cannot capture \(source.name)")
      if #unavailable(macOS 26.0) { watchProcesses(bundleID: source.bundleID) }
      let format = try tapFormat()
      guard format.mFormatID == kAudioFormatLinearPCM,
        format.mFormatFlags & kAudioFormatFlagIsFloat != 0, format.mBitsPerChannel == 32,
        format.mChannelsPerFrame == 2
      else { throw StemError("Capture needs stereo float32 PCM") }
      rate = format.mSampleRate
      guard let c = ls_create(rate, 44100) else { throw StemError("Cannot allocate audio buffers") }
      core = c
      inputFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 2, interleaved: true)
      converter = AVAudioConverter(from: inputFormat, to: modelFormat)
      guard converter != nil else { throw StemError("Cannot convert capture rate") }
      let config: [String: Any] = [
        kAudioAggregateDeviceNameKey: "Live Stems Private",
        kAudioAggregateDeviceUIDKey: UUID().uuidString, kAudioAggregateDeviceIsPrivateKey: 1,
        kAudioAggregateDeviceTapAutoStartKey: 0,
        kAudioAggregateDeviceTapListKey: [
          [kAudioSubTapUIDKey: description.uuid.uuidString, kAudioSubTapDriftCompensationKey: 1]
        ],
      ]
      try audioCheck(
        AudioHardwareCreateAggregateDevice(config as CFDictionary, &aggregate),
        "Cannot create capture device")
      try audioCheck(
        AudioDeviceCreateIOProcID(
          aggregate, ls_capture_callback, UnsafeMutableRawPointer(c), &ioProc),
        "Cannot prepare capture callback")
      node = AVAudioSourceNode(format: modelFormat) { _, time, frames, list in
        ls_render_timed(c, frames, list, time)
        return noErr
      }
      engine.attach(node!)
      pitch = PitchShift(engine: engine, source: node!, format: modelFormat)
      setSmallOutputBuffer()
      engine.prepare()
    } catch {
      stop()
      throw error
    }
  }
  private func tapFormat() throws -> AudioStreamBasicDescription {
    var a = audioAddress(kAudioTapPropertyFormat)
    var format = AudioStreamBasicDescription()
    var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    try audioCheck(
      AudioObjectGetPropertyData(tapID, &a, 0, nil, &size, &format), "Cannot read capture format")
    return format
  }
  /// The capture rate follows the output device (44.1, 48, 24 kHz for AirPods
  /// with the mic on, ...). The converter and the core are built for `rate`.
  var captureRateChanged: Bool { (try? tapFormat().mSampleRate) != rate }
  /// Seconds from render to speaker (AirPods add ~0.2 s), so a display can wait for the sound.
  /// Read once per output: the query goes to the audio server and cost ~10% of a core at 30 reads a second.
  var outputLatency: Double {
    if let latency { return latency }
    let value = engine.outputNode.presentationLatency
    latency = value
    return value
  }
  private var latency: Double?
  /// AVAudioEngine stops itself when the output device's format changes.
  var outputStopped: Bool { !engine.isRunning }
  /// Many apps play audio from helper processes: browsers (com.google.Chrome.helper,
  /// company.thebrowser.browser.helper) and Safari, whose audio comes from the
  /// shared WebKit GPU process. Tap the app, its helpers, and Safari's WebKit.
  static func tapBundleIDs(for bundleID: String) -> [String] {
    var ids = [bundleID, bundleID + ".helper"]
    if bundleID == "com.apple.Safari" { ids.append("com.apple.WebKit.GPU") }
    let prefix = bundleID.lowercased() + "."
    for (_, id) in audioProcesses() {
      if id.lowercased().hasPrefix(prefix), !ids.contains(id) { ids.append(id) }
    }
    return ids
  }
  /// Same matching as `tapBundleIDs`, by process object for the pre-26 include list.
  static func tapProcesses(for bundleID: String) -> [AudioObjectID] {
    audioProcesses().compactMap { process, bid in belongs(bid, to: bundleID) ? process : nil }
  }
  /// The app itself, its helpers, and for Safari the shared WebKit GPU process.
  static func belongs(_ processBundleID: String, to bundleID: String) -> Bool {
    let lower = processBundleID.lowercased(), exact = bundleID.lowercased()
    return lower == exact || lower.hasPrefix(exact + ".")
      || (bundleID == "com.apple.Safari" && lower == "com.apple.webkit.gpu")
  }
  /// Every audio process object with its bundle ID. Objects without one are skipped.
  static func audioProcesses() -> [(AudioObjectID, String)] {
    var address = audioAddress(kAudioHardwarePropertyProcessObjectList)
    var size: UInt32 = 0
    AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size)
    var processes = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &processes)
    return processes.compactMap { process in
      var name = audioAddress(kAudioProcessPropertyBundleID)
      var value: CFString = "" as CFString
      var length = UInt32(MemoryLayout<CFString>.size)
      guard withUnsafeMutablePointer(to: &value, {
        AudioObjectGetPropertyData(process, &name, 0, nil, &length, $0)
      }) == noErr else { return nil }
      return (process, value as String)
    }
  }
  // Audio already handed to the device survives a flush. A small
  // per-process IO buffer bounds that old-audio leak after a skip.
  private func setSmallOutputBuffer() {
    guard let unit = engine.outputNode.audioUnit else { return }
    var frames = UInt32(64)
    AudioUnitSetProperty(unit, kAudioDevicePropertyBufferFrameSize, kAudioUnitScope_Global, 0,
      &frames, UInt32(MemoryLayout<UInt32>.size))
    var size = UInt32(MemoryLayout<UInt32>.size)
    AudioUnitGetProperty(unit, kAudioDevicePropertyBufferFrameSize, kAudioUnitScope_Global, 0,
      &frames, &size)
    outputBufferFrames = frames
  }
  /// Move playback to the new default output (headphones, speakers). Capture,
  /// the queue, and the delay stay, so no new takeover is needed.
  func followOutput() throws {
    outputID = defaultOutput()
    engine.stop()
    engine.reset()
    setSmallOutputBuffer()
    try engine.start()
    latency = nil
  }
  func setTranspose(_ semitones: Int) {
    pitch?.set(semitones)
  }
  /// A seek must discard audio retained inside the pitch unit as well as the core queue.
  func resetPitch() throws {
    guard let pitch, !pitch.isBypassed else { return }
    engine.pause()
    pitch.reset()
    try engine.start()
    latency = nil
  }
  func start() throws {
    do {
      try engine.start()
      latency = nil
      try audioCheck(
        AudioDeviceStart(aggregate, ioProc),
        "Cannot start audio capture")
      started = true
    } catch {
      stop()
      throw error
    }
  }
  func setOriginalSuppressed(_ value: Bool) throws {
    description.muteBehavior = value ? .mutedWhenTapped : .unmuted
    var a = audioAddress(kAudioTapPropertyDescription)
    var d = description
    try withUnsafePointer(to: &d) {
      try audioCheck(
        AudioObjectSetPropertyData(
          tapID, &a, 0, nil, UInt32(MemoryLayout<CATapDescription>.size), $0),
        "Cannot switch the source app's playback")
    }
  }
  /// Pre-26 taps hold a fixed process list. Re-match when processes start or quit,
  /// so a relaunched app or new helper joins the tap.
  private func watchProcesses(bundleID: String) {
    let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
      guard let self, self.tapID != 0 else { return }
      let processes = Self.tapProcesses(for: bundleID)
      guard processes != self.description.processes else { return }
      self.description.processes = processes
      var a = audioAddress(kAudioTapPropertyDescription)
      var d = self.description
      _ = withUnsafePointer(to: &d) {
        AudioObjectSetPropertyData(
          self.tapID, &a, 0, nil, UInt32(MemoryLayout<CATapDescription>.size), $0)
      }
    }
    var a = audioAddress(kAudioHardwarePropertyProcessObjectList)
    if AudioObjectAddPropertyListenerBlock(
      AudioObjectID(kAudioObjectSystemObject), &a, DispatchQueue.main, block) == noErr
    {
      processListener = block
    }
  }
  func setOutputEnabled(_ value: Bool) {
    if let c = core { ls_enable(c, value ? 1 : 0) }
  }
  func discardCapturedAudio(at hostTime: Double = stemClock()) {
    captureBoundary = hostTime
    ls_discard_capture(core)
    converter?.reset()
    lastDrainEndHostSeconds = 0
  }
  func drain() throws -> [Float] {
    var input = [Float](repeating: 0, count: 4096 * 2)
    let captured = input.withUnsafeMutableBufferPointer {
      ls_capture_read_timed(core, $0.baseAddress, 4096, &lastDrainEndHostSeconds)
    }
    guard captured > 0 else { return [] }
    // A callback can arrive after a skip with an older hardware block. The
    // publication fence cannot reject that block: its own clock must do so.
    let start = lastDrainEndHostSeconds - Double(captured) / rate
    let trim = captureBoundary > start
      ? min(Int(captured), max(0, Int(ceil((captureBoundary - start) * rate - 0.0001)))) : 0
    let frames = captured - UInt32(trim)
    guard frames > 0 else { return [] }
    guard let source = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: frames),
      let output = AVAudioPCMBuffer(
        pcmFormat: modelFormat, frameCapacity: UInt32(ceil(Double(frames) * 44100 / rate)) + 128)
    else { throw StemError("Cannot prepare conversion") }
    source.frameLength = frames
    _ = input.withUnsafeBytes { bytes in
      memcpy(
        source.mutableAudioBufferList.pointee.mBuffers.mData!, bytes.baseAddress!.advanced(by: trim * 8), Int(frames) * 8)
    }
    var supplied = false
    var error: NSError?
    let status = converter!.convert(to: output, error: &error) { _, state in
      if supplied {
        state.pointee = .noDataNow
        return nil
      }
      supplied = true
      state.pointee = .haveData
      return source
    }
    if status == .error { throw error ?? StemError("Capture conversion failed") as NSError }
    var result = [Float](repeating: 0, count: Int(output.frameLength) * 2)
    guard let channels = output.floatChannelData else {
      throw StemError("Capture format unavailable")
    }
    for f in 0..<Int(output.frameLength) {
      result[f * 2] = channels[0][f]
      result[f * 2 + 1] = channels[1][f]
    }
    guard result.allSatisfy(\.isFinite) else { throw StemError("Non-finite capture") }
    return result
  }
  func stop() {
    if let block = processListener {
      var a = audioAddress(kAudioHardwarePropertyProcessObjectList)
      AudioObjectRemovePropertyListenerBlock(
        AudioObjectID(kAudioObjectSystemObject), &a, DispatchQueue.main, block)
      processListener = nil
    }
    if let core = core { ls_enable(core, 0) }
    if tapID != 0 { try? setOriginalSuppressed(false) }
    if aggregate != 0, let proc = ioProc {
      if started { AudioDeviceStop(aggregate, proc) }
      AudioDeviceDestroyIOProcID(aggregate, proc)
    }
    started = false
    ioProc = nil
    engine.stop()
    if aggregate != 0 {
      AudioHardwareDestroyAggregateDevice(aggregate)
      aggregate = 0
    }
    if tapID != 0 {
      AudioHardwareDestroyProcessTap(tapID)
      tapID = 0
    }
  }
  deinit {
    stop()
    if let c = core { ls_destroy(c) }
  }
}
