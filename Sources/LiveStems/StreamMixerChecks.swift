import AudioCore
import Foundation

enum StreamMixerChecks {
  static func run(_ fixture: [Float], rate: Int, out: URL) throws -> [String: Any] {
    let frames = fixture.count / 11
    guard frames >= rate else {
      return ["checked": false, "reason": "no one-second verified stem fixture"]
    }
    guard let core = ls_create(Double(rate), Double(rate)) else {
      throw StemError("Cannot allocate stream controls check core")
    }
    defer { ls_destroy(core) }
    let gains: [Float] = [1, 1, 1, 1]
    gains.withUnsafeBufferPointer { ls_controls(core, $0.baseAddress, 0, 0) }
    ls_enable(core, 1)
    let written = fixture.withUnsafeBufferPointer {
      ls_output_write(core, $0.baseAddress, UInt32(frames))
    }
    guard written == UInt32(frames) else { throw StemError("Controls fixture write was short") }
    let rendered = StreamE2E.readMix(core, frames: frames).samples
    let settle = rate / 10
    var neutralError = 0.0
    var neutralMax = 0.0
    var neutralEnergy = 0.0
    var limiterViolations = 0
    for frame in settle..<frames {
      let at = frame * 11
      for channel in 0..<2 {
        let expected = Double(fixture[at + 8 + channel])
        let actual = Double(rendered[frame * 2 + channel])
        neutralEnergy += expected * expected
        neutralError += (actual - expected) * (actual - expected)
        neutralMax = max(neutralMax, abs(actual - expected))
      }
      let ceiling = max(Float(0.98), abs(fixture[at + 8]), abs(fixture[at + 9])) + 1e-6
      if abs(rendered[frame * 2]) > ceiling || abs(rendered[frame * 2 + 1]) > ceiling {
        limiterViolations += 1
      }
    }

    guard let bassCore = ls_create(Double(rate), Double(rate)) else {
      throw StemError("Cannot allocate BassSolo controls core")
    }
    defer { ls_destroy(bassCore) }
    gains.withUnsafeBufferPointer { ls_controls(bassCore, $0.baseAddress, 0, 1 << 2) }
    ls_enable(bassCore, 1)
    _ = fixture.withUnsafeBufferPointer { ls_output_write(bassCore, $0.baseAddress, UInt32(frames)) }
    let bassRendered = StreamE2E.readMix(bassCore, frames: frames).samples
    var bassError = 0.0
    var bassEnergy = 0.0
    for frame in settle..<frames {
      let at = frame * 11
      for channel in 0..<2 {
        let expected = Double(fixture[at + 4 + channel])
        let actual = Double(bassRendered[frame * 2 + channel])
        bassEnergy += expected * expected
        bassError += (actual - expected) * (actual - expected)
      }
    }

    guard let muteCore = ls_create(Double(rate), Double(rate)) else {
      throw StemError("Cannot allocate all-mute controls core")
    }
    defer { ls_destroy(muteCore) }
    gains.withUnsafeBufferPointer { ls_controls(muteCore, $0.baseAddress, 15, 0) }
    ls_enable(muteCore, 1)
    _ = fixture.withUnsafeBufferPointer { ls_output_write(muteCore, $0.baseAddress, UInt32(frames)) }
    let muted = StreamE2E.readMix(muteCore, frames: frames).samples
    let mutePeak = muted.dropFirst(settle * 2).map { abs($0) }.max() ?? 0

    guard let toggleCore = ls_create(Double(rate), Double(rate)) else {
      throw StemError("Cannot allocate stem toggle controls core")
    }
    defer { ls_destroy(toggleCore) }
    gains.withUnsafeBufferPointer { ls_controls(toggleCore, $0.baseAddress, 0, 1 << 2) }
    ls_enable(toggleCore, 1)
    _ = fixture.withUnsafeBufferPointer { ls_output_write(toggleCore, $0.baseAddress, UInt32(frames)) }
    let prefix = settle
    let offFrames = rate / 3
    let onStart = prefix + offFrames
    let before = ls_underruns(toggleCore)
    _ = StreamE2E.readMix(toggleCore, frames: prefix)
    ls_stems(toggleCore, 0)
    let off = StreamE2E.readMix(toggleCore, frames: offFrames).samples
    ls_stems(toggleCore, 1)
    let on = StreamE2E.readMix(toggleCore, frames: min(offFrames, frames - onStart)).samples
    let toggleUnderruns = ls_underruns(toggleCore) - before
    var offOriginalError = 0.0
    for frame in settle..<offFrames {
      let at = (prefix + frame) * 11
      let sourceAt = frame * 2
      for channel in 0..<2 {
        offOriginalError = max(
          offOriginalError,
          abs(Double(off[sourceAt + channel] - fixture[at + 8 + channel])))
      }
    }

    let onSettle = rate / 50
    var onBassError = 0.0
    for frame in onSettle..<min(offFrames, on.count / 2) {
      let fixtureFrame = onStart + frame
      let at = fixtureFrame * 11
      for channel in 0..<2 {
        let expected = fixture[at + 4 + channel]
        let actual = on[frame * 2 + channel]
        onBassError = max(onBassError, abs(Double(actual - expected)))
      }
    }

    let sourceEnergy = (settle..<frames).reduce(0.0) { total, frame in
      let at = frame * 11
      return total + Double(fixture[at + 8] * fixture[at + 8]
        + fixture[at + 9] * fixture[at + 9])
    }
    let stemSumError = (settle..<frames).reduce(0.0) { total, frame in
      let at = frame * 11
      let left = fixture[at + 8] - fixture[at] - fixture[at + 2]
        - fixture[at + 4] - fixture[at + 6]
      let right = fixture[at + 9] - fixture[at + 1] - fixture[at + 3]
        - fixture[at + 5] - fixture[at + 7]
      return total + Double(left * left + right * right)
    }
    let snr = 10 * log10(max(sourceEnergy, 1e-12) / max(stemSumError, 1e-12))
    let neutralRelative = neutralError / max(neutralEnergy, 1e-12)
    let bassRelative = bassError / max(bassEnergy, 1e-12)
    let toggleStemPeak = on.map(abs).max() ?? 0
    let sourcePeak = fixture.dropFirst(8).enumerated().filter { $0.offset % 11 < 2 }
      .map { abs($0.element) }.max() ?? 0
    let pass = neutralMax <= 1e-6 && neutralRelative <= 1e-10
      && bassRelative <= 1e-5 && mutePeak <= 1e-6
      && offOriginalError <= 1e-6 && toggleUnderruns == 0
      && limiterViolations == 0 && toggleStemPeak <= max(0.98, sourcePeak) + 1e-6
      && onBassError <= 1e-6
    return [
      "checked": true, "pass": pass,
      "neutral_relative_error": neutralRelative, "neutral_max_abs_error": neutralMax,
      "bass_relative_error": bassRelative, "mute_peak": mutePeak,
      "toggle_off_original_max_abs_error": offOriginalError,
      "toggle_underruns": toggleUnderruns, "limiter_violations": limiterViolations,
      "raw_stem_sum_snr_db": snr, "toggle_on_bass_max_abs_error": onBassError, "toggle_stem_peak": toggleStemPeak,
      "source_peak": sourcePeak, "frames": frames,
      "persistent_controls": true, "bass_solo": true, "all_stem_mute": true,
    ]
  }

}
