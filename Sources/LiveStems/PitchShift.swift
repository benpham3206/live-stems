import AVFoundation

/// The output effect is shared by Original and the stem mix. Its graph can also
/// render offline, so tests exercise the same effect as a captured source.
final class PitchShift {
  private let unit = AVAudioUnitTimePitch()
  var isBypassed: Bool { unit.auAudioUnit.shouldBypassEffect }

  init(engine: AVAudioEngine, source: AVAudioNode, format: AVAudioFormat) {
    engine.attach(unit)
    unit.rate = 1
    set(0)
    engine.connect(source, to: unit, format: format)
    engine.connect(unit, to: engine.mainMixerNode, format: format)
  }

  @discardableResult func set(_ semitones: Int) -> Bool {
    guard (-12...12).contains(semitones) else { return false }
    unit.pitch = Float(semitones * 100)
    unit.auAudioUnit.shouldBypassEffect = semitones == 0
    return true
  }

  func reset() { unit.reset() }
}
