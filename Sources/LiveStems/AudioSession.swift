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
  private var inputFormat: AVAudioFormat!,
    modelFormat = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
  private var started = false
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
      description.bundleIDs = Self.tapBundleIDs(for: source.bundleID)
      description.isProcessRestoreEnabled = true
      description.muteBehavior = .unmuted
      try audioCheck(
        AudioHardwareCreateProcessTap(description, &tapID), "Cannot capture \(source.name)")
      var a = audioAddress(kAudioTapPropertyFormat)
      var format = AudioStreamBasicDescription()
      var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
      try audioCheck(
        AudioObjectGetPropertyData(tapID, &a, 0, nil, &size, &format), "Cannot read capture format")
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
      engine.connect(node!, to: engine.mainMixerNode, format: modelFormat)
      setSmallOutputBuffer()
      engine.prepare()
    } catch {
      stop()
      throw error
    }
  }
  /// Many apps play audio from helper processes: browsers (com.google.Chrome.helper,
  /// company.thebrowser.browser.helper) and Safari, whose audio comes from the
  /// shared WebKit GPU process. Tap the app, its helpers, and Safari's WebKit.
  static func tapBundleIDs(for bundleID: String) -> [String] {
    var ids = [bundleID, bundleID + ".helper"]
    if bundleID == "com.apple.Safari" { ids.append("com.apple.WebKit.GPU") }
    var address = audioAddress(kAudioHardwarePropertyProcessObjectList)
    var size: UInt32 = 0
    AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size)
    var processes = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &processes)
    let prefix = bundleID.lowercased() + "."
    for process in processes {
      var name = audioAddress(kAudioProcessPropertyBundleID)
      var value: CFString = "" as CFString
      var length = UInt32(MemoryLayout<CFString>.size)
      guard withUnsafeMutablePointer(to: &value, {
        AudioObjectGetPropertyData(process, &name, 0, nil, &length, $0)
      }) == noErr else { continue }
      let id = value as String
      if id.lowercased().hasPrefix(prefix), !ids.contains(id) { ids.append(id) }
    }
    return ids
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
  }
  func start() throws {
    do {
      try engine.start()
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
