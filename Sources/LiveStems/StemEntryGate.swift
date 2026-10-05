/// Decides when stems may play after a gap, and how fast the stem weight moves.
/// Stems (re)enter after on-time results, then fade in over `fade` frames. One
/// isolated gap, a skip, or a wake needs one on-time result, so a single miss
/// recovers fast. A second gap within `repeatWindow` frames means the model is
/// struggling: then `streak` results in a row are needed, so stems stay on the
/// stem-free mix instead of flickering against Original ten times a second.
struct StemEntryGate {
  let fade = 8820, streak = 3, repeatWindow = 88200
  private var closed = true, entering = false, onTime = 0, needed = 1, lastGap = Int.min / 2

  /// A skip, seek, wake, or processor reset: fresh context, quick re-entry.
  mutating func reset() { closed = true; entering = false; onTime = 0; needed = 1 }
  /// Stem data ran out while stems were playing.
  mutating func gap(at frame: Int) {
    let repeated = frame - lastGap < repeatWindow
    reset()
    if repeated { needed = streak }
    lastGap = frame
  }
  /// A result arrived; `fullyOnTime` is false for a partly late one.
  mutating func result(fullyOnTime: Bool) {
    guard fullyOnTime else { onTime = 0; return }
    onTime += 1
    if closed, onTime >= needed { closed = false; entering = true }
  }
  /// The next stem weight for a frame that has stem data. Closed: fade out.
  /// Entering: fade in. Otherwise the caller's seam blend (`seamStep` per frame).
  mutating func weight(from current: Float, toward target: Float, seamStep: Float) -> Float {
    if closed { return max(0, current - 1 / Float(fade)) }
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
