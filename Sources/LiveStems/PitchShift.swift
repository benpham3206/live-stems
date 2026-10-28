import AVFoundation
import PitchCore

/// The engine retains its source node. Keep DSP storage alive with the render
/// closure even if the PitchShift owner is released first.
private final class PitchProcessor {
  let pointer: OpaquePointer
  init?(rate: Double) {
    guard let pointer = ls_pitch_create(rate) else { return nil }
    self.pointer = pointer
  }
  deinit { ls_pitch_destroy(pointer) }
}

/// Shared final-mix transpose, statically linked and using the capture clock.
final class PitchShift {
  private let processor: PitchProcessor
  private var core: OpaquePointer { processor.pointer }
  private let rate: Double
  private var semitones = 0
  private let node: AVAudioSourceNode
  var isBypassed: Bool { semitones == 0 }
  var failed: Bool { ls_pitch_failed(core) != 0 }
  var latency: Double { Double(ls_pitch_latency(core)) / rate }

  init(engine: AVAudioEngine, format: AVAudioFormat, render: @escaping AVAudioSourceNodeRenderBlock) throws {
    guard let processor = PitchProcessor(rate: format.sampleRate) else {
      throw StemError("Cannot allocate transpose processor")
    }
    self.processor = processor
    rate = format.sampleRate
    node = AVAudioSourceNode(format: format) { silence, time, frames, list in
      let status = render(silence, time, frames, list)
      guard status == noErr else { return status }
      let buffers = UnsafeMutableAudioBufferListPointer(list)
      guard buffers.count == 2,
        let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
        let right = buffers[1].mData?.assumingMemoryBound(to: Float.self)
      else { return kAudio_ParamError }
      ls_pitch_process(processor.pointer, left, right, frames)
      return noErr
    }
    engine.attach(node)
    engine.connect(node, to: engine.mainMixerNode, format: format)
  }

  @discardableResult func set(_ semitones: Int) -> Bool {
    guard (-12...12).contains(semitones) else { return false }
    self.semitones = semitones
    ls_pitch_set(core, Int32(semitones))
    return true
  }

  /// Call only while the engine is paused, after the core queue has been cut.
  func reset() { ls_pitch_reset(core) }
}
