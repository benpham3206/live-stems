import AppKit
import CoreAudio

/// Follow what's playing: the source becomes the app that most recently started
/// playing and kept playing for `hold` seconds. One source at a time: while two
/// apps play, the newer one wins; when the source stops for `hold` seconds, the
/// newest app still playing takes over, so a track gap cannot flap the source.
/// A manual pick stands until some app starts playing after it.
struct SourceFollower {
  static let hold = 2.0
  /// When each playing app was first seen playing.
  private(set) var since: [String: Double] = [:]
  /// Only starts after this count; a manual pick moves it to now.
  private var floor = -Double.infinity
  /// When the current source was last heard.
  private var heard = (id: "", at: -Double.infinity)

  mutating func picked(at now: Double) { floor = now }

  /// The bundle ID to switch to, or nil to stay.
  mutating func next(current: String, playing: Set<String>, now: Double) -> String? {
    var playing = playing
    if playing.contains(current) { heard = (current, now) }
    else if heard.id == current, now - heard.at < Self.hold { playing.insert(current) }
    since = since.filter { playing.contains($0.key) }
    for id in playing where since[id] == nil { since[id] = now }
    // A blip shorter than `hold` (a notification sound) never counts.
    guard let (id, start) = since.filter({ now - $0.value >= Self.hold && $0.value > floor })
      .max(by: { $0.value < $1.value }), id != current
    else { return nil }
    if let mine = since[current], mine >= start { return nil }
    heard = (id, now)
    return id
  }

  /// Open regular apps other than Live Stems, by bundle ID. Main thread.
  static func regularApps() -> [String: String] {
    var apps = [String: String]()
    for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
      guard let id = app.bundleIdentifier, id != Bundle.main.bundleIdentifier else { continue }
      apps[id] = app.localizedName ?? id
    }
    return apps
  }
  /// Apps with open output streams. This is not evidence of audible playback.
  static func outputApps(_ apps: [String: String], processes: [(AudioObjectID, String)]) -> [String: String] {
    let running = processes.filter { isRunningOutput($0.0) }.map(\.1)
    return apps.filter { app in running.contains { AudioSession.belongs($0, to: app.key) } }
  }
  private static func isRunningOutput(_ process: AudioObjectID) -> Bool {
    var address = audioAddress(kAudioProcessPropertyIsRunningOutput)
    var value: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    return AudioObjectGetPropertyData(process, &address, 0, nil, &size, &value) == noErr && value != 0
  }

  /// The rule on scripted timelines. No audio or apps involved.
  static func check() throws {
    func run(_ steps: [(Double, Set<String>, String?)], from current: String, picked: Double? = nil) throws {
      var follower = SourceFollower(), current = current
      if let picked { follower.picked(at: picked) }
      for (now, playing, expected) in steps {
        let got = follower.next(current: current, playing: playing, now: now)
        guard got == expected else {
          throw StemError("At \(now) s playing \(playing.sorted()) from \(current): got \(got ?? "stay"), expected \(expected ?? "stay")")
        }
        if let got { current = got }
      }
    }
    // Spotify pauses, Chrome plays: switch after the hold.
    try run([(0, ["spotify"], nil), (5, ["chrome"], nil), (6, ["chrome"], nil), (7, ["chrome"], "chrome")], from: "spotify")
    // Chrome starts over Spotify: the newer one wins; Spotify still playing does not pull it back.
    try run([(0, ["spotify"], nil), (5, ["spotify", "chrome"], nil), (7, ["spotify", "chrome"], "chrome"),
      (20, ["spotify", "chrome"], nil)], from: "spotify")
    // Then Chrome stops: Spotify, still playing, takes over once Chrome has been silent for the hold.
    try run([(0, ["spotify"], nil), (5, ["spotify", "chrome"], nil), (7, ["spotify", "chrome"], "chrome"),
      (8, ["spotify"], nil), (8.9, ["spotify"], nil), (9, ["spotify"], "spotify")], from: "spotify")
    // A track gap in the source while an older app keeps playing never flaps the source.
    try run([(0, ["chrome"], nil), (5, ["chrome", "spotify"], nil), (7, ["chrome", "spotify"], "spotify"),
      (60, ["chrome", "spotify"], nil), (60.5, ["chrome"], nil), (61.5, ["chrome"], nil), (61.75, ["chrome", "spotify"], nil),
      (64, ["chrome", "spotify"], nil)], from: "chrome")
    // A one-second notification blip never switches.
    try run([(0, ["spotify"], nil), (5, ["spotify", "slack"], nil), (6, ["spotify"], nil), (9, ["spotify"], nil)], from: "spotify")
    // Both already playing at launch: keep the saved source.
    try run([(0, ["spotify", "arc"], nil), (3, ["spotify", "arc"], nil)], from: "spotify")
    // Launch with a silent saved source: follow what plays.
    try run([(0, ["arc"], nil), (2, ["arc"], "arc")], from: "spotify")
    // A manual pick of a silent app stands until something starts after it.
    try run([(10, ["chrome"], nil), (30, ["chrome"], nil), (31, ["chrome", "arc"], nil), (33, ["chrome", "arc"], "arc")],
      from: "music", picked: 10)
  }
}
