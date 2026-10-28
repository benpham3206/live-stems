import AudioCore
import CoreAudio
import Foundation

/// An unmuted, capture-only meter. It never starts source playback or renders audio.
final class AudioActivityProbe {
  private var tap: AudioObjectID = 0, aggregate: AudioObjectID = 0
  private var ioProc: AudioDeviceIOProcID?
  private var started = false
  private let peak: OpaquePointer

  init(bundleID: String) throws {
    guard let peak = ls_activity_create() else { throw StemError("Cannot allocate activity meter") }
    self.peak = peak
    let description = CATapDescription()
    description.name = "Live Stems activity"
    description.uuid = UUID()
    description.isPrivate = true
    description.isMixdown = true
    description.isMono = false
    description.isExclusive = false
    description.muteBehavior = .unmuted
    if #available(macOS 26.0, *) {
      description.bundleIDs = AudioSession.tapBundleIDs(for: bundleID)
      description.isProcessRestoreEnabled = true
    } else {
      let processes = AudioSession.tapProcesses(for: bundleID)
      guard !processes.isEmpty else { throw StemError("No audio process to meter") }
      description.processes = processes
    }
    try audioCheck(AudioHardwareCreateProcessTap(description, &tap), "Cannot meter source")
    var address = audioAddress(kAudioTapPropertyFormat)
    var format = AudioStreamBasicDescription()
    var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    try audioCheck(AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &format), "Cannot read activity format")
    guard format.mFormatID == kAudioFormatLinearPCM,
      format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
      format.mFormatFlags & kAudioFormatFlagIsBigEndian == 0,
      format.mBitsPerChannel == 32
    else { throw StemError("Activity meter needs float32 audio") }
    let config: [String: Any] = [
      kAudioAggregateDeviceNameKey: "Live Stems Activity",
      kAudioAggregateDeviceUIDKey: UUID().uuidString,
      kAudioAggregateDeviceIsPrivateKey: 1,
      kAudioAggregateDeviceTapAutoStartKey: 0,
      kAudioAggregateDeviceTapListKey: [
        [kAudioSubTapUIDKey: description.uuid.uuidString, kAudioSubTapDriftCompensationKey: 1]
      ],
    ]
    try audioCheck(AudioHardwareCreateAggregateDevice(config as CFDictionary, &aggregate), "Cannot create activity device")
    try audioCheck(AudioDeviceCreateIOProcID(aggregate, ls_activity_callback, UnsafeMutableRawPointer(peak), &ioProc), "Cannot prepare activity meter")
    try audioCheck(AudioDeviceStart(aggregate, ioProc), "Cannot start activity meter")
    started = true
  }

  func takePeak() -> Float { ls_activity_take(peak) }

  static func check() throws {
    guard ls_activity_check() != 0 else { throw StemError("Activity meter buffer-layout or reset regression") }
  }

  private func close() {
    if let ioProc {
      if started { AudioDeviceStop(aggregate, ioProc) }
      AudioDeviceDestroyIOProcID(aggregate, ioProc)
    }
    started = false
    ioProc = nil
    if aggregate != 0 { AudioHardwareDestroyAggregateDevice(aggregate); aggregate = 0 }
    if tap != 0 { AudioHardwareDestroyProcessTap(tap); tap = 0 }
  }

  deinit {
    close()
    ls_activity_destroy(peak)
  }
}
