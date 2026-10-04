import Foundation

/// Checks controls on the same paced stream used for seek and recovery checks.
final class StreamRenderEvidence {
  private let rate: Int
  private let offset: Int
  private var weights: [Float]
  private var bass: [Float]

  init(rate: Int, offset: Int) {
    self.rate = rate
    self.offset = offset
    weights = [Float](repeating: -1, count: 40 * rate)
    bass = [Float](repeating: 0, count: 8 * rate * 2)
  }

  func record(start: Int, block: [Float]) {
    for frame in 0..<(block.count / 11) {
      let source = start + frame
      let at = frame * 11
      if source >= 0 && source < weights.count { weights[source] = block[at + 10] }
      if source >= 0 && source < bass.count / 2 {
        bass[source * 2] = block[at + 4]
        bass[source * 2 + 1] = block[at + 5]
      }
    }
  }

  func check(rendered: [Float], expected: [Float]) -> [String: Any] {
    var evidence = [String: Any]()
    var pass = true
    for (name, second) in [("bass_solo", 5), ("original_with_bass_solo", 6),
                           ("all_mute", 26), ("original_with_all_mute", 27)] {
      var checked = 0
      var maxError = 0.0, sourceEnergy = 0.0, targetEnergy = 0.0, changedEnergy = 0.0
      for output in (second * rate + rate * 3 / 10)..<(second * rate + rate * 8 / 10) {
        let wallSource = output - offset
        // The scenario has exactly two seconds with capture stopped.
        let captured = wallSource >= 18 * rate ? wallSource - 2 * rate : wallSource
        guard captured >= 0, captured < weights.count, weights[captured] == 1 else { continue }
        let original = [expected[wallSource * 2], expected[wallSource * 2 + 1]]
        var target = original
        if name == "bass_solo" {
          target = [bass[captured * 2], bass[captured * 2 + 1]]
          let peak = max(abs(target[0]), abs(target[1]))
          let cap = max(Float(0.98), abs(original[0]), abs(original[1]))
          if peak > cap { target = target.map { $0 * cap / peak } }
        } else if name == "all_mute" { target = [0, 0] }
        checked += 1
        for channel in 0..<2 {
          let actual = rendered[output * 2 + channel]
          maxError = max(maxError, abs(Double(actual - target[channel])))
          sourceEnergy += Double(original[channel] * original[channel])
          targetEnergy += Double(target[channel] * target[channel])
          changedEnergy += Double((actual - original[channel]) * (actual - original[channel]))
        }
      }
      let altered = name == "bass_solo" || name == "all_mute"
      let valid = checked > rate / 4 && maxError <= 1e-6 && sourceEnergy > 1e-5
        && (!altered || changedEnergy > 1e-5)
        && (name != "bass_solo" || targetEnergy > 1e-7)
      pass = pass && valid
      evidence[name] = ["pass": valid, "checked_frames": checked,
                        "max_abs_error": maxError, "source_energy": sourceEnergy,
                        "target_energy": targetEnergy, "change_energy": changedEnergy]
    }
    evidence["pass"] = pass
    return evidence
  }
}
