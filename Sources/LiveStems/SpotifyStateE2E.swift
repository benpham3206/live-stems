import Foundation

/// Failure-first acceptance for the native Spotify state boundary.
///
/// The reader is delayed on purpose. Notices enter through the same handler
/// that the distributed observer uses. No Spotify process, GUI automation, or
/// audio session is involved.
enum SpotifyStateE2E {
  private static let noticeName = Notification.Name("com.spotify.client.PlaybackStateChanged")

  private final class Recorder {
    private let lock = NSLock()
    private var values = [PlaybackSnapshot]()
    private var unavailable = 0

    func record(_ value: PlaybackSnapshot) {
      lock.lock()
      values.append(value)
      lock.unlock()
    }

    func count() -> Int {
      lock.lock(); defer { lock.unlock() }
      return values.count
    }

    func snapshots() -> [PlaybackSnapshot] {
      lock.lock(); defer { lock.unlock() }
      return values
    }

    func recordUnavailable() {
      lock.lock()
      unavailable += 1
      lock.unlock()
    }

    func unavailableCount() -> Int {
      lock.lock(); defer { lock.unlock() }
      return unavailable
    }
  }

  private final class DelayedReader {
    let firstStarted = DispatchSemaphore(value: 0)
    let releaseFirst = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var calls = 0
    let first: PlaybackSnapshot
    let later: PlaybackSnapshot

    init(first: PlaybackSnapshot, later: PlaybackSnapshot) {
      self.first = first
      self.later = later
    }

    func read() -> PlaybackSnapshot {
      lock.lock()
      calls += 1
      let call = calls
      lock.unlock()
      if call == 1 {
        firstStarted.signal()
        releaseFirst.wait()
        return first
      }
      return later
    }
  }

  private final class RestartReader {
    let firstStarted = DispatchSemaphore(value: 0)
    let releaseFirst = DispatchSemaphore(value: 0)
    let secondStarted = DispatchSemaphore(value: 0)
    let releaseSecond = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var calls = 0
    let old: PlaybackSnapshot
    let restarted: PlaybackSnapshot

    init(old: PlaybackSnapshot, restarted: PlaybackSnapshot) {
      self.old = old
      self.restarted = restarted
    }

    func read() -> PlaybackSnapshot {
      lock.lock()
      calls += 1
      let call = calls
      lock.unlock()
      if call == 1 {
        firstStarted.signal()
        releaseFirst.wait()
        return old
      }
      secondStarted.signal()
      releaseSecond.wait()
      return restarted
    }
  }

  private final class FailingReader {
    let started = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)

    func read() throws -> PlaybackSnapshot {
      started.signal()
      release.wait()
      throw StemError("stale reader failure")
    }
  }

  static func run(_ out: URL) throws {
    var report: [String: Any] = [
      "status": "fail",
      "scope": "Spotify state boundary; no CUA, GUI AppleScript, Spotify process, or audio session",
    ]
    do {
      let skip = try delayedSkipAndNotices()
      let staleFailureCheck = try staleFailure()
      let lifecycle = try stopAndRestart()
      let stamp = try slowReadStamp()
      report["status"] = "pass"
      report["checks"] = [skip, staleFailureCheck, lifecycle, stamp]
      let skipElapsed = skip["elapsed_seconds"] as? Double ?? 0
      let failureElapsed = staleFailureCheck["elapsed_seconds"] as? Double ?? 0
      let lifecycleElapsed = lifecycle["elapsed_seconds"] as? Double ?? 0
      report["elapsed_seconds"] = (skipElapsed + failureElapsed) + lifecycleElapsed
      try write(report, to: out)
      print("PASS spotify-state · delayed skip, notice ordering, and lifecycle")
    } catch {
      report["reason"] = error.localizedDescription
      try? write(report, to: out)
      throw error
    }
  }

  /// A slow read carries the time Spotify sampled the position (mid-read), not
  /// the publish time. Stamping at publish made slow reads look like seeks.
  private static func slowReadStamp() throws -> [String: Any] {
    let readTime = 0.6
    let state = SpotifyState(reader: {
      Thread.sleep(forTimeInterval: readTime)
      return PlaybackSnapshot(trackID: "stamp", title: "S", duration: 200, position: 10, isPlaying: true)
    })
    let got = DispatchSemaphore(value: 0)
    var stamped = 0.0, published = 0.0
    let began = stemClock()
    state.start(onSnapshot: { _, host in
      if stamped == 0 { stamped = host; published = stemClock(); got.signal() }
    }, onUnavailable: { _ in })
    defer { state.stop() }
    try require(got.wait(timeout: .now() + 3) == .success, "Slow reader never published")
    let offset = stamped - began
    try require(abs(offset - readTime / 2) < 0.15, "Slow read stamped at \(offset) s, expected about \(readTime / 2) s")
    return ["name": "slow_read_stamp", "stamp_offset_seconds": offset, "publish_offset_seconds": published - began]
  }

  private static func delayedSkipAndNotices() throws -> [String: Any] {
    let reader = DelayedReader(
      first: PlaybackSnapshot(
        trackID: "old-track", title: "Old", duration: 300, position: 42, isPlaying: true),
      later: PlaybackSnapshot(
        trackID: "polled-track", title: "Polled", duration: 180, position: 3, isPlaying: true))
    let recorder = Recorder()
    let state = SpotifyState(reader: reader.read)
    defer {
      reader.releaseFirst.signal()
      state.stop()
    }
    state.start(
      onSnapshot: { value, _ in recorder.record(value) },
      onUnavailable: { _ in })
    try require(reader.firstStarted.wait(timeout: .now() + 1) == .success,
      "Delayed reader did not become in flight")

    let began = stemClock()
    state.handleNotification(notice(
      trackID: "new-track", name: "New", playerState: "Playing", position: 0, duration: 999_999))
    try require(wait(for: { recorder.count() >= 1 }, timeout: 0.25),
      "New-track notice did not publish while the reader was blocked")
    let skipLatency = stemClock() - began
    let first = recorder.snapshots()
    try require(first.first?.trackID == "new-track", "First published snapshot was not the skip")
    try require(first.first?.duration == 0, "New notice inferred an unverified duration unit")

    for index in 0..<3 {
      state.handleNotification(notice(
        trackID: "rapid-\(index)", name: "Rapid \(index)", playerState: "Playing",
        position: Double(index) / 10))
    }
    state.handleNotification(notice(
      trackID: "rapid-2", name: nil, playerState: "Paused", position: 1.2))
    state.handleNotification(notice(
      trackID: "rapid-2", name: nil, playerState: "Playing", position: 1.3))
    try require(wait(for: { recorder.count() >= 6 }, timeout: 0.5),
      "Rapid track and pause notices were not all published")

    let beforeInvalid = recorder.count()
    state.handleNotification(Notification(name: noticeName, object: nil, userInfo: [
      "Player State": "Playing", "Playback Position": 2.0,
    ]))
    state.handleNotification(notice(
      trackID: "bad-state", name: "Bad", playerState: "Stopped", position: 2))
    state.handleNotification(notice(
      trackID: "bad-position", name: "Bad", playerState: "Playing", position: "NaN"))
    let invalidStable = wait(for: { recorder.count() == beforeInvalid }, timeout: 0.08)
    try require(invalidStable,
      "Invalid notice data published a false snapshot")

    let targetBlockedDuration = 0.8
    let remaining = targetBlockedDuration - (stemClock() - began)
    if remaining > 0 { Thread.sleep(forTimeInterval: remaining) }
    let blockedDuration = stemClock() - began
    reader.releaseFirst.signal()
    try require(wait(for: {
      recorder.snapshots().contains { $0.trackID == "polled-track" }
    }, timeout: 1.5), "A valid poll did not recover after invalid notices")
    state.handleNotification(notice(
      trackID: "polled-track", name: nil, playerState: "Playing", position: 4, duration: 1))
    try require(wait(for: {
      recorder.snapshots().contains { $0.trackID == "polled-track" && $0.duration == 180 }
    }, timeout: 0.5), "Known duration was not retained for a partial notice")

    let snapshots = recorder.snapshots()
    try require(!snapshots.contains { $0.trackID == "old-track" },
      "Stale in-flight reader result published the old track")
    let ids = Array(snapshots.prefix(6).map(\.trackID))
    try require(ids == ["new-track", "rapid-0", "rapid-1", "rapid-2", "rapid-2", "rapid-2"],
      "Notice order changed: \(ids)")
    return [
      "name": "delayed_skip_and_notices",
      "skip_latency_seconds": skipLatency,
      "reader_blocked_seconds": blockedDuration,
      "notice_sequence": ids,
      "invalid_notice_ignored": invalidStable,
      "stale_reader_suppressed": !snapshots.contains { $0.trackID == "old-track" },
      "known_duration_retained": snapshots.contains {
        $0.trackID == "polled-track" && $0.duration == 180
      },
      "elapsed_seconds": stemClock() - began,
    ]
  }

  private static func staleFailure() throws -> [String: Any] {
    let reader = FailingReader()
    let recorder = Recorder()
    let state = SpotifyState(reader: reader.read)
    defer {
      reader.release.signal()
      state.stop()
    }
    state.start(
      onSnapshot: { value, _ in recorder.record(value) },
      onUnavailable: { _ in recorder.recordUnavailable() })
    try require(reader.started.wait(timeout: .now() + 1) == .success,
      "Failing reader did not become in flight")
    let began = stemClock()
    state.handleNotification(notice(
      trackID: "valid-before-failure", name: "Valid", playerState: "Playing", position: 0))
    try require(wait(for: {
      recorder.snapshots().contains { $0.trackID == "valid-before-failure" }
    }, timeout: 0.25), "Valid notice did not publish before reader failure")
    let beforeFailure = recorder.unavailableCount()
    reader.release.signal()
    Thread.sleep(forTimeInterval: 0.1)
    try require(recorder.unavailableCount() == beforeFailure,
      "Stale reader failure replaced a newer valid notice")
    state.stop()
    return [
      "name": "stale_reader_failure",
      "reader_failure_suppressed": true,
      "unavailable_callbacks": recorder.unavailableCount(),
      "elapsed_seconds": stemClock() - began,
    ]
  }

  private static func stopAndRestart() throws -> [String: Any] {
    let reader = RestartReader(
      old: PlaybackSnapshot(
        trackID: "old-lifecycle", title: "Old", duration: 120, position: 4, isPlaying: true),
      restarted: PlaybackSnapshot(
        trackID: "restarted", title: "Restarted", duration: 200, position: 0, isPlaying: true))
    let recorder = Recorder()
    let state = SpotifyState(reader: reader.read)
    defer {
      reader.releaseFirst.signal()
      reader.releaseSecond.signal()
      state.stop()
    }
    state.start(
      onSnapshot: { value, _ in recorder.record(value) },
      onUnavailable: { _ in })
    try require(reader.firstStarted.wait(timeout: .now() + 1) == .success,
      "Lifecycle reader did not become in flight")
    let began = stemClock()
    state.stop()
    let stopLatency = stemClock() - began
    try require(stopLatency < 0.1, "stop() waited for the blocked reader")

    state.start(
      onSnapshot: { value, _ in recorder.record(value) },
      onUnavailable: { _ in })
    let restartLatency = stemClock() - began
    try require(restartLatency < 0.1, "restart() waited for the blocked reader")
    reader.releaseFirst.signal()
    try require(reader.secondStarted.wait(timeout: .now() + 1) == .success,
      "Restarted reader did not begin after the old read completed")
    reader.releaseSecond.signal()
    try require(wait(for: { recorder.count() >= 1 }, timeout: 1),
      "Restarted reader did not publish")
    let ids = recorder.snapshots().map(\.trackID)
    try require(ids == ["restarted"], "Old lifecycle result leaked into restart: \(ids)")
    return [
      "name": "stop_and_restart",
      "stop_latency_seconds": stopLatency,
      "restart_latency_seconds": restartLatency,
      "old_result_rejected": !ids.contains("old-lifecycle"),
      "restarted_result_published": ids == ["restarted"],
      "elapsed_seconds": stemClock() - began,
    ]
  }

  private static func notice(
    trackID: String?, name: String?, playerState: String?, position: Any?, duration: Any? = nil
  ) -> Notification {
    var fields = [AnyHashable: Any]()
    if let trackID { fields["Track ID"] = trackID }
    if let name { fields["Name"] = name }
    if let playerState { fields["Player State"] = playerState }
    if let position { fields["Playback Position"] = position }
    if let duration { fields["Duration"] = duration }
    return Notification(name: noticeName, object: nil, userInfo: fields)
  }

  private static func wait(for predicate: () -> Bool, timeout: Double) -> Bool {
    let deadline = stemClock() + timeout
    while stemClock() < deadline {
      if predicate() { return true }
      Thread.sleep(forTimeInterval: 0.005)
    }
    return predicate()
  }

  private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw StemError(message) }
  }

  private static func write(_ report: [String: Any], to out: URL) throws {
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: out.appendingPathComponent("skip-state.json"), options: .atomic)
  }
}
