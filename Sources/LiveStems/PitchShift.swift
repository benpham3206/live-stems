import AVFoundation

/// Apple's native pitch effect, shared by Original and stem output.
final class PitchShift {
  private let unit = AVAudioUnitTimePitch()
  var isBypassed: Bool { unit.auAudioUnit.shouldBypassEffect }
  var latency: Double { isBypassed ? 0 : unit.auAudioUnit.latency }

  init(engine: AVAudioEngine, format: AVAudioFormat, render: @escaping AVAudioSourceNodeRenderBlock) {
    let source = AVAudioSourceNode(format: format, renderBlock: render)
    engine.attach(source)
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
