import Foundation

/// Injected Spotify transport checks. Both boundaries are always replaced;
/// this runner never sends an Apple Event or starts Spotify or audio capture.
enum SeekE2E {
  private final class Transport {
    var snapshot = PlaybackSnapshot(
      trackID: "seek-test", title: "Seek", duration: 200, position: 60, isPlaying: true)
    var reads = 0
    var writes = [Double]()
    var failRead = 0
    var failWrite = false
    var readbackPosition: Double?
    var changeTrack = false
    var changeBeforeWrite = false
    var changePlayback = false

    // Accessed only on readerQueue, or by the test before enqueue/after completion.
    func read() throws -> PlaybackSnapshot {
      reads += 1
      if reads == failRead { throw StemError("injected read failure") }
      return snapshot
    }

    func write(_ target: Double, expectedTrackID: String) throws {
      if changeBeforeWrite { snapshot.trackID = "new-track" }
      guard snapshot.trackID == expectedTrackID else { throw StemError("Track changed before write") }
      writes.append(target)
      if failWrite { throw StemError("injected write failure") }
      snapshot.position = readbackPosition ?? target
      if changeTrack { snapshot.trackID = "different-track" }
      if changePlayback { snapshot.isPlaying.toggle() }
    }

    func state() -> SpotifyState {
      SpotifyState(reader: read, positionWriter: write)
    }
  }

  static func run(_ out: URL) throws {
    var report: [String: Any] = [
      "status": "fail",
      "scope": "Injected Spotify reader and writer only; no playback, Apple Events, or capture",
    ]
    do {
      try offsetsAndBounds()
      try failures()
      try cancellation()
      try stalePassiveUpdates()
      report["status"] = "pass"
      report["checks"] = ["all eight offsets", "start/end clamps", "cumulative queued seeks",
        "paused preservation", "actual readback", "invalid offsets and metadata",
        "read/write failures", "readback mismatch", "queued and pre-write cancellation",
        "stop cancellation", "direct mode after cancellation", "stale poll/notice suppression"]
      try write(report, out)
      print("PASS seek · bounded offsets, readback, failures, cancellation")
    } catch {
      report["reason"] = error.localizedDescription
      try? write(report, out)
      throw error
    }
  }

  private static func offsetsAndBounds() throws {
    for offset in [-30, -15, -10, -5, 5, 10, 15, 30] {
      let transport = Transport()
      transport.snapshot.isPlaying = false
      let value = try seek(transport.state(), offset).get()
      try require(value.position == 60 + Double(offset), "Wrong target for \(offset)")
      try require(!value.isPlaying && !transport.snapshot.isPlaying, "Seek resumed paused playback")
      try require(transport.reads == 2 && transport.writes == [value.position],
        "Seek did not use fresh read + one write + readback")
    }
    for (position, offset, expected) in [(2.0, -30, 0.0), (198.0, 30, 200.0)] {
      let transport = Transport()
      transport.snapshot.position = position
      let value = try seek(transport.state(), offset).get()
      try require(value.position == expected && transport.writes == [expected], "Seek failed to clamp")
    }
    let transport = Transport()
    let state = transport.state()
    let done = DispatchSemaphore(value: 0)
    var results = [Result<PlaybackSnapshot, Error>]()
    for _ in 0..<3 {
      state.seek(by: 10) { results.append($0); done.signal() }
    }
    for _ in 0..<3 { try wait(done, "Cumulative seek timed out") }
    let positions = try results.map { try $0.get().position }
    try require(positions == [70, 80, 90] && transport.writes == positions,
      "Queued seeks did not accumulate from fresh positions")

    let actual = Transport()
    actual.readbackPosition = 70.5
    try require(try seek(actual.state(), 10).get().position == 70.5,
      "Seek returned a synthesized target instead of actual readback")
  }

  private static func failures() throws {
    for offset in [0, 1, -1, 20, -20, Int.min, Int.max] {
      let transport = Transport()
      try requireFailure(seek(transport.state(), offset), "Unsupported offset \(offset)")
      try require(transport.reads == 0 && transport.writes.isEmpty, "Invalid offset crossed boundary")
    }
    let invalid: [(Double, Double)] = [
      (0, 0), (-1, 0), (.nan, 0), (.infinity, 0),
      (200, .nan), (200, .infinity), (200, -1), (200, 201),
    ]
    for (duration, position) in invalid {
      let transport = Transport()
      transport.snapshot.duration = duration
      transport.snapshot.position = position
      try requireFailure(seek(transport.state(), 5), "Invalid metadata")
      try require(transport.writes.isEmpty, "Invalid metadata caused a write")
    }
    let empty = Transport()
    empty.snapshot.trackID = ""
    try requireFailure(seek(empty.state(), 5), "Empty track")
    try require(empty.writes.isEmpty, "Empty track caused a write")

    for read in [1, 2] {
      let transport = Transport()
      transport.failRead = read
      let result = try seek(transport.state(), 5)
      try requireFailure(result, "Read failure \(read)")
      if case .failure(let error) = result {
        try require(error.localizedDescription == "injected read failure", "Read error was swallowed")
      }
      try require(transport.writes.count == read - 1, "Read failure write count changed")
    }
    let writer = Transport()
    writer.failWrite = true
    let writeResult = try seek(writer.state(), 5)
    try requireFailure(writeResult, "Write failure")
    if case .failure(let error) = writeResult {
      try require(error.localizedDescription == "injected write failure", "Write error was swallowed")
    }
    try require(writer.reads == 1, "Readback ran after failed write")
    let changed = Transport()
    changed.changeBeforeWrite = true
    try requireFailure(seek(changed.state(), 10), "Track changed before write")
    try require(changed.writes.isEmpty && changed.snapshot.position == 60,
      "Old track target was written to a new track")

    for position in [60.0, 72.0, .nan, .infinity, -1, 201] {
      let transport = Transport()
      transport.readbackPosition = position
      try requireFailure(seek(transport.state(), 10), "Unconfirmed readback")
    }
    for changeTrack in [true, false] {
      let transport = Transport()
      transport.changeTrack = changeTrack
      transport.changePlayback = !changeTrack
      try requireFailure(seek(transport.state(), 10), "Changed track/playback state")
    }
  }

  private static func cancellation() throws {
    for stop in [false, true] {
      let transport = Transport()
      let entered = DispatchSemaphore(value: 0)
      let release = DispatchSemaphore(value: 0)
      let done = DispatchSemaphore(value: 0)
      var results = [Result<PlaybackSnapshot, Error>]()
      let state = SpotifyState(reader: {
        entered.signal()
        guard release.wait(timeout: .now() + 2) == .success else {
          throw StemError("Cancellation test reader timed out")
        }
        return try transport.read()
      }, positionWriter: transport.write)
      defer { release.signal() }
      state.seek(by: 10) { results.append($0); done.signal() }
      try wait(entered, "Seek reader never started")
      state.seek(by: 10) { results.append($0); done.signal() }
      if stop { state.stop() } else { state.cancelSeeks() }
      release.signal()
      for _ in 0..<2 { try wait(done, "Cancelled seek did not complete") }
      try require(transport.reads == 1 && transport.writes.isEmpty,
        "Cancelled seek read or wrote after its generation was invalidated")
      for result in results {
        guard case .failure(let error) = result,
          let seekError = error as? SpotifyState.SeekError,
          case .cancelled = seekError
        else { throw StemError("Cancelled seek did not report typed cancellation") }
      }
      // Cancellation invalidates old requests without disabling future direct use.
      release.signal()
      release.signal()
      try require(try seek(state, 5).get().position == 65, "New direct seek failed after cancellation")
    }
  }

  private static func stalePassiveUpdates() throws {
    let transport = Transport()
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let done = DispatchSemaphore(value: 0)
    let lock = NSLock()
    var published = [Double]()
    var first = true
    var result: Result<PlaybackSnapshot, Error>?
    let state = SpotifyState(reader: {
      if first {
        first = false
        entered.signal()
        guard release.wait(timeout: .now() + 2) == .success else {
          throw StemError("Stale poll test timed out")
        }
        var stale = transport.snapshot
        stale.position = 1
        return stale
      }
      return try transport.read()
    }, positionWriter: transport.write)
    defer { release.signal(); state.stop() }
    state.start(onSnapshot: { value, _ in
      lock.lock(); published.append(value.position); lock.unlock()
    }, onUnavailable: { _ in })
    try wait(entered, "Initial passive poll never started")
    state.seek(by: 10) { result = $0; done.signal() }
    state.handleNotification(Notification(
      name: Notification.Name("com.spotify.client.PlaybackStateChanged"), object: nil,
      userInfo: ["Track ID": "seek-test", "Player State": "Playing", "Playback Position": 999]))
    release.signal()
    try wait(done, "Seek behind passive poll timed out")
    state.stop()
    guard let result else { throw StemError("Missing seek behind poll") }
    try require(try result.get().position == 70, "Passive state changed the fresh seek target")
    lock.lock(); let positions = published; lock.unlock()
    try require(!positions.contains(1) && !positions.contains(999),
      "Stale poll or pending notice escaped suppression")
  }

  private static func seek(_ state: SpotifyState, _ offset: Int) throws -> Result<PlaybackSnapshot, Error> {
    let done = DispatchSemaphore(value: 0)
    var result: Result<PlaybackSnapshot, Error>?
    state.seek(by: offset) { result = $0; done.signal() }
    try wait(done, "Seek completion timed out")
    guard let result else { throw StemError("Missing seek result") }
    return result
  }

  private static func wait(_ semaphore: DispatchSemaphore, _ message: String) throws {
    try require(semaphore.wait(timeout: .now() + 3) == .success, message)
  }

  private static func requireFailure(_ result: Result<PlaybackSnapshot, Error>, _ message: String) throws {
    if case .success = result { throw StemError("Unexpected seek success: \(message)") }
  }

  private static func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw StemError(message) }
  }

  private static func write(_ report: [String: Any], _ out: URL) throws {
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: out.appendingPathComponent("seek.json"), options: .atomic)
  }
}
