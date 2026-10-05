import AudioCore
import Foundation

struct StemError: LocalizedError {
  let message: String
  var errorDescription: String? { message }
  init(_ message: String) { self.message = message }
}
func stemClock() -> Double { ProcessInfo.processInfo.systemUptime }
struct FrameRange: Equatable {
  var generation: UInt64
  var start: UInt64
  var count: UInt32
}
struct AudioWindow {
  var range: FrameRange
  var samples: [Float]
}
struct StemWindow {
  var range: FrameRange
  var samples: [Float]
}
struct PlaybackSnapshot {
  var trackID: String
  var title: String
  var duration: Double
  var position: Double
  var isPlaying: Bool
}
/// The app whose audio Live Stems separates. Spotify gets extra transport
/// support (exact pause/skip notices, a self-pause); any app works through audio.
struct AudioSource: Equatable {
  var bundleID: String
  var name: String
  static let spotify = AudioSource(bundleID: "com.spotify.client", name: "Spotify")
  var isSpotify: Bool { bundleID == Self.spotify.bundleID }
  /// The chosen source, kept across launches.
  static var saved: AudioSource {
    get {
      let defaults = UserDefaults.standard
      guard let id = defaults.string(forKey: "sourceBundleID"), let name = defaults.string(forKey: "sourceName")
      else { return .spotify }
      return AudioSource(bundleID: id, name: name)
    }
    set {
      UserDefaults.standard.set(newValue.bundleID, forKey: "sourceBundleID")
      UserDefaults.standard.set(newValue.name, forKey: "sourceName")
    }
  }
}
struct StemControls {
  var gains: [Float] = [1, 1, 1, 1]
  var mute: UInt32 = 0
  var solo: UInt32 = 0
  /// Stem gains after mute and solo.
  var effectiveGains: [Float] {
    (0..<4).map { s in
      let bit: UInt32 = 1 << UInt32(s)
      return mute & bit != 0 || (solo != 0 && solo & bit == 0) ? 0 : gains[s]
    }
  }
}
enum LocalSettings {
  static let root: URL = {
    if let p = Bundle.main.url(forResource: "local", withExtension: "json"),
      let data = try? Data(contentsOf: p),
      let values = try? JSONSerialization.jsonObject(with: data) as? [String: String],
      let path = values["root"]
    {
      return URL(fileURLWithPath: path)
    }
    var p = URL(fileURLWithPath: #filePath)
    for _ in 0..<5 { p.deleteLastPathComponent() }
    return p
  }()
  static var source: URL { root.appendingPathComponent("outputs/live-stems-source") }
  static var python: URL { root.appendingPathComponent("work/stems-venv/bin/python") }
  static var cache: URL { root.appendingPathComponent("work/model-cache") }
  static var runtime: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Live Stems")
  }
  static var evidence: URL {
    Bundle.main.bundleURL.pathExtension == "app"
      ? runtime : root.appendingPathComponent("outputs/live-stems-acceptance")
  }
}
extension Data {
  mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
    var v = value.littleEndian
    Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
  }
  func integer<T: FixedWidthInteger>(_ type: T.Type, _ offset: Int) -> T {
    withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: type).littleEndian }
  }
}
