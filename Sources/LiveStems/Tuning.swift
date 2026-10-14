/// The values that set how the 3D spectrum looks, in one place to change and try. `./stems tune`
/// lists them; `./stems render` draws the result; `./stems verify` checks it; `./stems install` runs it.
/// Spans are the window's 2, 5 and 10 s choices; rows come 30 a second.
enum Tuning {
  /// Glow line brightness at the back of each span, as a share of the front. Between, it falls as
  /// 1 / (1 + a·t), a = 1/glowEnd − 1: a steep drop near the front, then a long dim tail, like y = 1/x.
  /// At 0.11 it is half by an eighth of the way back. The stacked glow of the lines lifts what you see:
  /// 0.11 reads about 25% at the back. Too low and the back goes dark (the spectrum E2E fails).
  static let glowEnd: [Int: Float] = [2: 0.11, 5: 0.11, 10: 0.11]
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
