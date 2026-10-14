/// The values that set how the 3D spectrum looks, in one place to change and try. `./stems tune`
/// lists them; `./stems render` draws the result; `./stems verify` checks it; `./stems install` runs it.
/// Spans are the window's 2, 5 and 10 s choices; rows come 30 a second.
enum Tuning {
  /// How the glow lines dim from the front of the span (t = 0) to the back (t = 1).
  enum GlowCurve {
    /// e^(−rate·t): the back is at e^(−rate).
    case exponential(rate: [Int: Float])
    /// A straight line to `end` at the back.
    case straight(end: [Int: Float])
    /// An exponential decay of rate k, scaled to land on `end` at the back.
    case scaledExponential(k: Float, end: [Int: Float])
    /// 1 / (1 + a·t), a = 1/end − 1: a steep drop near the front, then a long dim tail, like y = 1/x.
    case inverse(end: [Int: Float])
  }
  /// Every glow curve tried, oldest first, to compare from the Spectrum window's gear menu (the choice is
  /// remembered). `glowLook` is the one used until another is picked. The stacked glow of neighbouring
  /// lines lifts what you see at the back: the inverse curve at 0.11 reads about 25%. Too dark at the
  /// back fails the spectrum E2E, which checks `glowLook`.
  static let glowLooks: [(name: String, curve: GlowCurve)] = [
    ("Original · e^−2.3t, 10% at the back", .exponential(rate: [2: 2.3, 5: 2.3, 10: 2.3])),
    ("Brighter back · e^−1.7t, 18%", .exponential(rate: [2: 1.7, 5: 1.7, 10: 2.1])),
    ("Straight · to 50%", .straight(end: [2: 0.5, 5: 0.5, 10: 0.35])),
    ("Straight · to 34%", .straight(end: [2: 0.34, 5: 0.34, 10: 0.24])),
    ("Exponential · to 34%", .scaledExponential(k: 2, end: [2: 0.34, 5: 0.34, 10: 0.24])),
    ("1/x · to 11%", .inverse(end: [2: 0.11, 5: 0.11, 10: 0.11])),
  ]
  static let glowLook = 5
  /// Rows between glow lines, for each span: 1 is every row (33 ms apart), 2 every other (66 ms),
  /// 3 every third (100 ms). More lines also stack more glow and fog.
  static let lineEvery: [Int: Int] = [2: 2, 5: 2, 10: 2]
  /// Navy fog at the back of the span, as a share of the front. Fades by the same share each second.
  static let fogEnd: Float = 0.32
  /// New rows fade in over this many rows: the soft front edge.
  static let emergeRows: Float = 2
  /// Pitch, in degrees, where the flat ribbons seen from straight over and under start and finish
  /// fading in. Below `ribbonFrom` the view is unchanged.
  static let ribbonFrom: Float = 30, ribbonTo: Float = 70
}
