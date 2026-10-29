import Foundation

/// Polls capture-only probes off the UI thread. Raw samples are never retained.
final class SourceActivity {
  static let pollInterval = 0.25
  /// Bridges short gaps between poll windows, but does not keep silent streams alive.
  static let bridge = 0.5
  /// A probe that failed to open is retried after this long, not on every poll.
  static let retry = 2.0
  /// A probe opened in this poll has heard no device cycle yet; read it this much later.
  static let firstRead = 0.05
  private let queue = DispatchQueue(label: "LiveStems.sourceActivity", qos: .userInitiated)
  private var probes: [String: AudioActivityProbe] = [:] // queue only
  private var processes: [String: [UInt32]] = [:] // queue only
  private var recent: [String: Double] = [:] // queue only
  private var failed: [String: Double] = [:] // queue only
  private var pending = false, generation = 0 // main thread only

  func clear() {
    generation += 1
    queue.async { [self] in probes = [:]; recent = [:]; processes = [:]; failed = [:] }
  }

  /// Measures which of `apps` (bundle ID to name) are audible and calls `done` on the
  /// main thread with them and the measurement time. One poll runs at a time; a poll
  /// begun before `clear` is dropped. CoreAudio reads can block, so none run on main.
  func poll(apps: [String: String], done: @escaping ([String: String], Double) -> Void) {
    guard !pending else { return }
    pending = true
    let requested = generation
    queue.async { [self] in
      let list = AudioSession.audioProcesses()
      let candidates = SourceFollower.outputApps(apps, processes: list)
      probes = probes.filter { candidates[$0.key] != nil }
      processes = processes.filter { candidates[$0.key] != nil }
      recent = recent.filter { candidates[$0.key] != nil }
      failed = failed.filter { candidates[$0.key] != nil }
      let now = stemClock()
      var opened = false
      for id in candidates.keys {
        if #unavailable(macOS 26.0) {
          let ids = list.compactMap { AudioSession.belongs($0.1, to: id) ? $0.0 : nil }.sorted()
          if processes[id] != ids { probes[id] = nil; recent[id] = nil; failed[id] = nil; processes[id] = ids }
        }
        guard probes[id] == nil, now - (failed[id] ?? -.infinity) >= Self.retry else { continue }
        if let probe = try? AudioActivityProbe(bundleID: id) { probes[id] = probe; opened = true } else { failed[id] = now }
      }
      let measure = { [self] in
        let at = stemClock()
        for (id, probe) in probes where Self.isAudible(probe.takePeak()) { recent[id] = at }
        let audible = Self.audible(candidates, recent: recent, at: at)
        DispatchQueue.main.async { [self] in
          pending = false
          if generation == requested, Self.isFresh(measured: at, now: stemClock()) { done(audible, at) }
        }
      }
      if opened { queue.asyncAfter(deadline: .now() + Self.firstRead, execute: measure) } else { measure() }
    }
  }

  static func audible(_ candidates: [String: String], recent: [String: Double], at now: Double) -> [String: String] {
    candidates.filter { now - (recent[$0.key] ?? -.infinity) < bridge }
  }

  static func isAudible(_ peak: Float) -> Bool { peak.isFinite && peak > 0.0001 }
  static func isFresh(measured: Double, now: Double) -> Bool { now >= measured && now - measured < 0.75 }

  /// Poll timelines through the production level, bridge, and follower rules.
  /// `level` gives each app's peak over the window ending at a time; nil means no output stream.
  /// Returns the switch times. Probe and device latency are not modeled.
  static func simulate(from current: String, until end: Double, phase: Double = 0, picked: Double? = nil,
    level: (String, Double) -> Double?) -> [(Double, String)] {
    var follower = SourceFollower(), current = current, recent = [String: Double](), switches = [(Double, String)]()
    if let picked { follower.picked(at: picked) }
    var now = phase
    while now <= end {
      var candidates = [String: String]()
      for id in ["spotify", "chrome", "slack", "music"] {
        guard let peak = level(id, now) else { continue }
        candidates[id] = id
        if isAudible(Float(peak)) { recent[id] = now }
      }
      let heard = audible(candidates, recent: recent, at: now)
      if let id = follower.next(current: current, playing: Set(heard.keys), now: now) { current = id; switches.append((now, id)) }
      now += pollInterval
    }
    return switches
  }

  static func check() throws -> String {
    guard isFresh(measured: 10, now: 10.5), !isFresh(measured: 10, now: 11), !isFresh(measured: 11, now: 10) else {
      throw StemError("Delayed activity callbacks must not select a stale or future source")
    }
    var latencies = [Double]()
    for phase in stride(from: 0.0, to: pollInterval, by: 0.05) {
      // Spotify pauses at 10 s; Chrome starts sustained playback at 10 s.
      let switches = simulate(from: "spotify", until: 20, phase: phase) { id, t in
        id == "spotify" ? (t < 10 ? 0.2 : 0) : id == "chrome" ? (t > 10 ? 0.2 : 0) : nil
      }
      guard switches.count == 1, switches[0].1 == "chrome" else { throw StemError("Sustained Chrome playback did not take over once: \(switches)") }
      latencies.append(switches[0].0 - 10)
    }
    guard let slowest = latencies.max(), slowest <= SourceFollower.hold + pollInterval + 1e-9 else {
      throw StemError("Selection took \(latencies.max() ?? .nan) s; limit is hold plus one poll")
    }
    // Focused but silent Chrome: an open output stream at the noise floor, for a minute.
    let silent = simulate(from: "spotify", until: 70) { id, _ in id == "spotify" ? 0.2 : id == "chrome" ? 0.00001 : nil }
    guard silent.isEmpty else { throw StemError("Silent Chrome output stole Spotify's source") }
    // Invalid levels never qualify.
    guard !isAudible(.nan), !isAudible(.infinity), !isAudible(0.00001), isAudible(0.01) else {
      throw StemError("Follow activity must reject silence and invalid levels")
    }
    let invalid = simulate(from: "spotify", until: 20) { id, _ in id == "spotify" ? 0.2 : id == "chrome" ? .nan : nil }
    guard invalid.isEmpty else { throw StemError("Nonfinite Chrome levels took over") }
    // Short blips (a 1.5 s notification, repeated) never switch.
    let blips = simulate(from: "spotify", until: 30) { id, t in
      id == "spotify" ? 0.2 : id == "slack" ? (t.truncatingRemainder(dividingBy: 5) < 1.5 ? 0.3 : 0) : nil
    }
    guard blips.isEmpty else { throw StemError("Short blips switched the source: \(blips)") }
    // Rapid alternation between two apps: one switch per hold at most, never flapping.
    let rapid = simulate(from: "spotify", until: 30) { id, t in
      let chromeTurn = t >= 10 && Int(t / 0.75) % 2 == 0
      return id == "spotify" ? (t < 10 || !chromeTurn ? 0.2 : 0) : id == "chrome" ? (chromeTurn ? 0.2 : 0) : nil
    }
    guard rapid.isEmpty else { throw StemError("Alternating 0.75 s bursts switched the source: \(rapid)") }
    // A track gap in Spotify while Chrome plays underneath keeps Spotify.
    let gap = simulate(from: "spotify", until: 40) { id, t in
      id == "chrome" ? 0.2 : id == "spotify" ? ((20...21.5).contains(t) ? 0 : 0.2) : nil
    }
    guard gap.isEmpty else { throw StemError("A 1.5 s Spotify gap flapped to Chrome: \(gap)") }
    // A manual pick of a silent app stands until an app starts after it.
    let manual = simulate(from: "music", until: 20, picked: 0) { id, t in
      id == "music" ? 0 : id == "chrome" ? 0.2 : id == "spotify" ? (t > 12 ? 0.2 : 0) : nil
    }
    guard manual.map { $0.1 } == ["spotify"], let pickedSwitch = manual.first?.0, pickedSwitch > 12 + SourceFollower.hold - 1e-9 else {
      throw StemError("Manual pick did not stand until a new start: \(manual)")
    }
    let sorted = latencies.sorted()
    return String(format: "selection %.2f-%.2f s (poll phases %d)", sorted.first!, sorted.last!, sorted.count)
  }
}
