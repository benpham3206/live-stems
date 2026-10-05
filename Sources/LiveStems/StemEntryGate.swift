/// Decides when stems may play, and how fast the stem weight moves. A miss (stem
/// data about to run out: the stand-in tail is ending with no newer result)
/// closes the gate, so stems fade out over `fadeOut` frames while data remains,
/// never with a jump. A partly late result is not a miss: the tail covered it. Stems re-enter after on-time results and
/// fade in over `fade` frames. One isolated miss, a skip, or a wake needs one
/// on-time result; a second miss within `repeatWindow` frames means the model
/// is struggling, so `streak` results in a row are needed and stems stay out
/// instead of flickering against Original.
struct StemEntryGate {
  let fade = 8820, fadeOut = 882, streak = 3, repeatWindow = 88200
  private var closed = true, entering = false, onTime = 0, needed = 1, lastGap = Int.min / 2

  /// A skip, seek, wake, or processor reset: fresh context, quick re-entry.
  mutating func reset() { closed = true; entering = false; onTime = 0; needed = 1 }
  var isOpen: Bool { !closed }
  /// Stem data is about to run out (or did).
  mutating func miss(at frame: Int) {
    let repeated = frame - lastGap < repeatWindow
    reset()
    if repeated { needed = streak }
    lastGap = frame
  }
  /// A result arrived partly late: it breaks an on-time streak, nothing more.
  mutating func partialResult() { onTime = 0 }
  /// A result arrived with its whole core before the playback deadline.
  mutating func onTimeResult() {
    onTime += 1
    if closed, onTime >= needed { closed = false; entering = true }
  }
  /// The next stem weight for a frame that has stem data. Closed: fade out.
  /// Entering: fade in. Otherwise the caller's seam blend (`seamStep` per frame).
  mutating func weight(from current: Float, toward target: Float, seamStep: Float) -> Float {
    if closed { return max(0, current - 1 / Float(fadeOut)) }
    if entering {
      let next = min(target, current + 1 / Float(fade))
      if next >= 1 { entering = false }
      return next
    }
    return current + max(-seamStep, min(seamStep, target - current))
  }
  /// E2E fixtures that test seams, not entry, start with stems already admitted.
  mutating func openForTest() { closed = false; entering = false; onTime = streak }
}
