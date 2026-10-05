import Foundation

/// Publishes Spotify notices promptly while keeping the blocking state reader off
/// the event queue. All lifecycle and snapshot mutation stays on stateQueue.
final class SpotifyState {
  typealias SnapshotHandler = (PlaybackSnapshot, Double) -> Void
  typealias UnavailableHandler = (String) -> Void

  private struct Notice {
    let trackID: String
    let title: String?
    let position: Double
    let isPlaying: Bool
  }

  private let stateQueue = DispatchQueue(label: "livestems.spotify-state", qos: .utility)
  private let readerQueue = DispatchQueue(label: "livestems.spotify-reader", qos: .utility)
  private let queueKey = DispatchSpecificKey<UInt8>()
  private let reader: () throws -> PlaybackSnapshot
  private var timer: DispatchSourceTimer?
  private var observer: NSObjectProtocol?
  private var running = false
  private var lifecycle: UInt64 = 0
  private var noticeVersion: UInt64 = 0
  private var readSequence: UInt64 = 0
  private var activeReadID: UInt64?
  private var latestSnapshot: PlaybackSnapshot?
  private var lastUnavailable = ""
  private var onSnapshot: SnapshotHandler?
  private var onUnavailable: UnavailableHandler?

  init(reader: (() throws -> PlaybackSnapshot)? = nil) {
    self.reader = reader ?? Self.readSnapshot
    stateQueue.setSpecific(key: queueKey, value: 1)
  }

  deinit { stop() }

  func start(onSnapshot: @escaping SnapshotHandler, onUnavailable: @escaping UnavailableHandler) {
    syncState {
      stopLocked()
      lifecycle &+= 1
      running = true
      self.onSnapshot = onSnapshot
      self.onUnavailable = onUnavailable

      let center = DistributedNotificationCenter.default()
      observer = center.addObserver(
        forName: Notification.Name("com.spotify.client.PlaybackStateChanged"),
        object: nil,
        queue: nil
      ) { [weak self] note in
        self?.handleNotification(note)
      }

      let timer = DispatchSource.makeTimerSource(queue: stateQueue)
      timer.schedule(deadline: .now(), repeating: .milliseconds(250), leeway: .milliseconds(25))
      timer.setEventHandler { [weak self] in self?.pollIfNeeded() }
      self.timer = timer
      timer.resume()
    }
  }

  func stop() { syncState { stopLocked() } }

  // The observer and E2E both use this boundary. Parsing happens before the
  // state queue hop, so a slow reader cannot delay notice publication.
  func handleNotification(_ notification: Notification) {
    guard let notice = Self.parseNotice(notification.userInfo) else { return }
    stateQueue.async { [weak self] in self?.publish(notice) }
  }

  private func stopLocked() {
    dispatchPrecondition(condition: .onQueue(stateQueue))
    lifecycle &+= 1
    running = false
    activeReadID = nil
    timer?.setEventHandler {}
    timer?.cancel()
    timer = nil
    if let observer {
      DistributedNotificationCenter.default().removeObserver(observer)
      self.observer = nil
    }
    latestSnapshot = nil
    lastUnavailable = ""
    onSnapshot = nil
    onUnavailable = nil
  }

  private func syncState(_ work: () -> Void) {
    if DispatchQueue.getSpecific(key: queueKey) != nil {
      work()
    } else {
      stateQueue.sync(execute: work)
    }
  }

  private func pollIfNeeded() {
    dispatchPrecondition(condition: .onQueue(stateQueue))
    guard running, activeReadID == nil else { return }
    readSequence &+= 1
    let readID = readSequence
    activeReadID = readID
    let lifecycle = lifecycle
    let noticeVersion = noticeVersion
    let reader = self.reader
    readerQueue.async { [weak self] in
      let result: Result<PlaybackSnapshot, Error>
      do {
        result = .success(try reader())
      } catch {
        result = .failure(error)
      }
      self?.stateQueue.async { [weak self] in
        self?.finishRead(result, readID: readID, lifecycle: lifecycle, noticeVersion: noticeVersion)
      }
    }
  }

  private func finishRead(
    _ result: Result<PlaybackSnapshot, Error>, readID: UInt64,
    lifecycle: UInt64, noticeVersion: UInt64
  ) {
    dispatchPrecondition(condition: .onQueue(stateQueue))
    guard activeReadID == readID else { return }
    activeReadID = nil
    guard running, self.lifecycle == lifecycle, self.noticeVersion == noticeVersion else { return }
    switch result {
    case .success(let snapshot):
      latestSnapshot = snapshot
      lastUnavailable = ""
      onSnapshot?(snapshot, stemClock())
    case .failure(let error):
      let message = error.localizedDescription
      guard message != lastUnavailable else { return }
      lastUnavailable = message
      onUnavailable?(message)
    }
  }

  private func publish(_ notice: Notice) {
    dispatchPrecondition(condition: .onQueue(stateQueue))
    guard running else { return }
    let old = latestSnapshot
    let sameTrack = old?.trackID == notice.trackID
    let snapshot = PlaybackSnapshot(
      trackID: notice.trackID,
      title: notice.title ?? (sameTrack ? old?.title ?? "" : ""),
      duration: sameTrack ? old?.duration ?? 0 : 0,
      position: notice.position,
      isPlaying: notice.isPlaying)
    noticeVersion &+= 1
    latestSnapshot = snapshot
    lastUnavailable = ""
    onSnapshot?(snapshot, stemClock())
  }

  private static func parseNotice(_ userInfo: [AnyHashable: Any]?) -> Notice? {
    guard let trackID = string(value("Track ID", in: userInfo)), !trackID.isEmpty,
      let state = string(value("Player State", in: userInfo))?.lowercased(),
      let isPlaying = ["playing": true, "paused": false][state],
      let position = number(value("Playback Position", in: userInfo)),
      position.isFinite, position >= 0, position <= 86400
    else { return nil }
    return Notice(
      trackID: trackID, title: string(value("Name", in: userInfo)), position: position,
      isPlaying: isPlaying)
  }

  private static func value(_ key: String, in userInfo: [AnyHashable: Any]?) -> Any? {
    userInfo?.first(where: { String(describing: $0.key) == key })?.value
  }

  private static func string(_ value: Any?) -> String? {
    if let value = value as? String { return value }
    if let value = value as? NSString { return String(value) }
    return nil
  }

  private static func number(_ value: Any?) -> Double? {
    if let value = value as? NSNumber { return value.doubleValue }
    if let value = value as? Double { return value }
    return nil
  }

  /// Sends a transport command ("pause", "play") to Spotify. Runs on the reader
  /// queue so it never overlaps another AppleScript call.
  func command(_ verb: String) {
    readerQueue.async {
      var error: NSDictionary?
      NSAppleScript(source: "tell application \"Spotify\" to \(verb)")?.executeAndReturnError(&error)
    }
  }
  private static func readSnapshot() throws -> PlaybackSnapshot {
    let source = """
    with timeout of 1 second
      if application "Spotify" is not running then error number -1708
      tell application "Spotify"
        set currentTrack to current track
        if currentTrack is missing value then error number -1708
        set trackID to id of currentTrack
        set trackTitle to name of currentTrack
        set durationMS to duration of currentTrack
        set positionSeconds to player position
        set playbackState to (player state as text)
        return trackID & tab & trackTitle & tab & (durationMS as text) & tab & (positionSeconds as text) & tab & playbackState
      end tell
    end timeout
    """
    var scriptError: NSDictionary?
    guard let script = NSAppleScript(source: source) else {
      throw StemError("Cannot create Spotify state script")
    }
    guard let value = script.executeAndReturnError(&scriptError).stringValue else {
      if let scriptError, let message = scriptError[NSAppleScript.errorMessage] as? String {
        throw StemError("Spotify state unavailable · \(message)")
      }
      throw StemError("Spotify state unavailable")
    }
    let fields = value.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
    guard fields.count == 5, !fields[0].isEmpty else {
      throw StemError("Spotify state returned an invalid record")
    }
    guard let durationMS = Double(fields[2]), let position = Double(fields[3]),
      durationMS.isFinite, position.isFinite, durationMS >= 0, position >= 0
    else { throw StemError("Spotify state returned an invalid duration or position") }
    let state = fields[4].lowercased()
    return PlaybackSnapshot(
      trackID: fields[0], title: fields[1], duration: durationMS / 1000.0,
      position: position, isPlaying: state == "playing")
  }
}
