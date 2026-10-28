import Foundation

/// Polls capture-only probes off the UI thread. Raw samples are never retained.
final class SourceActivity {
  static let pollInterval = 0.25
  private let queue = DispatchQueue(label: "LiveStems.sourceActivity")
  private var probes: [String: AudioActivityProbe] = [:] // queue only
  private var processes: [String: [UInt32]] = [:] // queue only
  private var recent: [String: Double] = [:] // queue only
  private var confirmed: [String: String] = [:] // main thread only
  private var confirmedAt = -Double.infinity
  private var pending = false
  private var generation = 0

  func clear() {
    generation += 1
    confirmed = [:]
    queue.async { [self] in probes = [:]; recent = [:]; processes = [:] }
  }

  func playing(candidates: [String: String]) -> [String: String] {
    if !pending {
      pending = true
      let requestedGeneration = generation
      queue.async { [self] in
        probes = probes.filter { candidates[$0.key] != nil }
        processes = processes.filter { candidates[$0.key] != nil }
        recent = recent.filter { candidates[$0.key] != nil }
        let now = stemClock()
        for id in candidates.keys {
          if #unavailable(macOS 26.0) {
            let ids = AudioSession.tapProcesses(for: id).sorted()
            if processes[id] != ids { probes[id] = nil; recent[id] = nil; processes[id] = ids }
          }
          if probes[id] == nil { probes[id] = try? AudioActivityProbe(bundleID: id) }
          if Self.isAudible(probes[id]?.takePeak() ?? 0) { recent[id] = now }
        }
        // Bridge short gaps between quarter-second poll windows, but do not keep silent streams alive.
        let audible = candidates.filter { now - (recent[$0.key] ?? -.infinity) < 0.5 }
        DispatchQueue.main.async { [self] in
          if generation == requestedGeneration { confirmed = audible; confirmedAt = now }
          pending = false
        }
      }
    }
    guard Self.isFresh(measured: confirmedAt, now: stemClock()) else { return [:] }
    return confirmed.filter { candidates[$0.key] != nil }
  }

  static func isFresh(measured: Double, now: Double) -> Bool { now - measured < 0.75 }

  static func isAudible(_ peak: Float) -> Bool { peak.isFinite && peak > 0.0001 }

  static func check() throws {
    guard isFresh(measured: 10, now: 10.5), !isFresh(measured: 10, now: 11) else {
      throw StemError("Stalled activity probes must not retain a playing app")
    }
    var follower = SourceFollower()
    for second in 0...8 {
      // Both output streams are open; Chrome has no samples above the noise floor.
      var peaks: [String: Float] = ["spotify": 0.2]
      if second >= 3 { peaks["chrome"] = 0 }
      let audible = Set(peaks.filter { isAudible($0.value) }.keys)
      guard follower.next(current: "spotify", playing: audible, now: Double(second)) == nil else {
        throw StemError("Silent Chrome output stole Spotify's source")
      }
    }
    guard !isAudible(.nan), !isAudible(.infinity), !isAudible(0.00001), isAudible(0.01) else {
      throw StemError("Follow activity must reject silence and invalid levels")
    }
    // Genuine new audio still takes over after the existing hold.
    _ = follower.next(current: "spotify", playing: ["spotify", "chrome"], now: 10)
    guard follower.next(current: "spotify", playing: ["spotify", "chrome"], now: 12) == "chrome" else {
      throw StemError("Audible Chrome did not qualify after the hold")
    }
  }
}
