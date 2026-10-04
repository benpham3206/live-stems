import Darwin
import Foundation

enum StartupE2E {
  static func run(_ out: URL) throws {
    let received = DispatchSemaphore(value: 0)
    let state = SpotifyState(reader: {
      Thread.sleep(forTimeInterval: 0.8)
      return PlaybackSnapshot(trackID: "startup", title: "Fixture", duration: 120,
        position: 30, isPlaying: true)
    })
    defer { state.stop() }
    let began = stemClock()
    state.start(onSnapshot: { value, _ in
      if value.trackID == "startup" { received.signal() }
    }, onUnavailable: { _ in })
    let returned = stemClock() - began
    guard returned < 0.1 else { throw StemError("Metadata startup blocked session for \(returned) seconds") }
    guard received.wait(timeout: .now() + 2) == .success else { throw StemError("Asynchronous startup lost its snapshot") }
    let descriptor = try AppInstance.acquire(in: out)
    guard let descriptor else { throw StemError("First fixture instance could not acquire lock") }
    defer { close(descriptor) }
    guard try AppInstance.acquire(in: out) == nil else { throw StemError("Second instance acquired live lock") }
    let report: [String: Any] = ["status": "pass", "initial_reader_start_seconds": returned,
      "injected_reader_delay_seconds": 0.8, "asynchronous_snapshot_received": true,
      "second_instance_lock_rejected": true]
    try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
      .write(to: out.appendingPathComponent("startup.json"))
  }
}
