import Darwin
import Foundation

enum AppInstance {
  static let reopenNotification = Notification.Name("com.benpham.livestems.reopen")
  static func requestReopen() {
    DistributedNotificationCenter.default().postNotificationName(reopenNotification,
      object: nil, userInfo: nil, deliverImmediately: true)
  }
  // An OS lock releases on process exit. A stale PID file cannot grant a
  // second instance permission to capture or to overwrite the same trace.
  static func acquire(in directory: URL = LocalSettings.runtime) throws -> Int32? {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let descriptor = open(directory.appendingPathComponent("app.lock").path, O_CREAT | O_RDWR, 0o600)
    guard descriptor >= 0 else { throw StemError("Cannot open app instance lock") }
    if flock(descriptor, LOCK_EX | LOCK_NB) == 0 { return descriptor }
    let failure = errno
    close(descriptor)
    if failure == EWOULDBLOCK { return nil }
    throw StemError("Cannot acquire app instance lock (\(failure))")
  }
}
