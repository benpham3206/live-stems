import Foundation

/// Publishes Spotify notices promptly unless a seek is pending, keeping the
/// blocking reader off the event queue. Lifecycle and snapshots use stateQueue.
final class SpotifyState {
  typealias SnapshotHandler = (PlaybackSnapshot, Double) -> Void
  typealias UnavailableHandler = (String) -> Void

  enum SeekError: LocalizedError {
    case unsupportedOffset, invalidSnapshot, cancelled, readbackMismatch

    var errorDescription: String? {
      switch self {
      case .unsupportedOffset: return "Spotify seek supports only ±5, 10, 15, or 30 seconds"
      case .invalidSnapshot: return "Spotify seek requires a track with a valid duration and position"
      case .cancelled: return "Spotify seek cancelled"
      case .readbackMismatch: return "Spotify seek readback did not confirm the requested position and playback state"
      }
    }
  }

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
  private let positionWriter: (Double, String) throws -> Void
  private var seekGeneration: UInt64 = 0
  private var pendingSeeks = 0
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

  init(reader: (() throws -> PlaybackSnapshot)? = nil,
       positionWriter: ((Double, String) throws -> Void)? = nil) {
    self.reader = reader ?? Self.readSnapshot
    self.positionWriter = positionWriter ?? Self.writePosition
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

  /// Invalidates queued seeks, including a seek waiting for its fresh read.
  /// An external write already in progress cannot be retracted.
  func cancelSeeks() { syncState { seekGeneration &+= 1 } }

  /// Completion runs exactly once on stateQueue, including failures/cancellation.
  /// Works before start(): direct Spotify transport does not need capture.
  func seek(by offset: Int, completion: @escaping (Result<PlaybackSnapshot, Error>) -> Void) {
    syncState {
      let generation = seekGeneration
      pendingSeeks += 1
      // A poll begun before this request must not publish an old position later.
      activeReadID = nil
      readerQueue.async {
        let result = Result { () throws -> PlaybackSnapshot in
          try self.checkSeek(generation)
          guard [-30, -15, -10, -5, 5, 10, 15, 30].contains(offset) else {
            throw SeekError.unsupportedOffset
          }
          let before = try self.reader()
          try Self.validateSeekSnapshot(before)
          let target = min(before.duration, max(0, before.position + Double(offset)))
          try self.checkSeek(generation)
          try self.positionWriter(target, before.trackID)
          let after = try self.reader()
          try Self.validateSeekSnapshot(after)
          guard after.trackID == before.trackID, after.isPlaying == before.isPlaying,
            abs(after.duration - before.duration) <= 1, abs(after.position - target) <= 1
          else { throw SeekError.readbackMismatch }
          return after
        }
        self.stateQueue.async {
          self.pendingSeeks -= 1
          guard self.seekGeneration == generation else {
            completion(.failure(SeekError.cancelled))
            return
          }
          if case .success(let snapshot) = result {
            self.noticeVersion &+= 1
            self.latestSnapshot = snapshot
            self.lastUnavailable = ""
          }
          // The caller handles the confirmed seek explicitly; no passive callback.
          completion(result)
        }
      }
    }
  }

  private func checkSeek(_ generation: UInt64) throws {
    var cancelled = false
    syncState { cancelled = seekGeneration != generation }
    if cancelled { throw SeekError.cancelled }
  }

  private static func validateSeekSnapshot(_ snapshot: PlaybackSnapshot) throws {
    guard !snapshot.trackID.isEmpty, snapshot.duration.isFinite, snapshot.duration > 0,
      snapshot.position.isFinite, snapshot.position >= 0, snapshot.position <= snapshot.duration
    else { throw SeekError.invalidSnapshot }
  }

  // The observer and E2E both use this boundary. Parsing happens before the
  // state queue hop, so a slow reader cannot delay notice publication.
  func handleNotification(_ notification: Notification) {
    guard let notice = Self.parseNotice(notification.userInfo) else { return }
    stateQueue.async { [weak self] in self?.publish(notice) }
  }

  private func stopLocked() {
    dispatchPrecondition(condition: .onQueue(stateQueue))
    lifecycle &+= 1
    seekGeneration &+= 1
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
    guard running, pendingSeeks == 0, activeReadID == nil else { return }
    readSequence &+= 1
    let readID = readSequence
    activeReadID = readID
    let lifecycle = lifecycle
    let noticeVersion = noticeVersion
    let reader = self.reader
    readerQueue.async { [weak self] in
      let result: Result<PlaybackSnapshot, Error>
      // Spotify samples the position during the Apple Event, not when the reply
      // is published. A slow read stamped at publish time looks like a seek.
      let began = stemClock()
      do {
        result = .success(try reader())
      } catch {
        result = .failure(error)
      }
      let sampled = (began + stemClock()) / 2
      self?.stateQueue.async { [weak self] in
        self?.finishRead(result, sampled: sampled, readID: readID, lifecycle: lifecycle, noticeVersion: noticeVersion)
      }
    }
  }

  private func finishRead(
    _ result: Result<PlaybackSnapshot, Error>, sampled: Double, readID: UInt64,
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
      onSnapshot?(snapshot, sampled)
    case .failure(let error):
      let message = error.localizedDescription
      guard message != lastUnavailable else { return }
      lastUnavailable = message
      onUnavailable?(message)
    }
  }

  private func publish(_ notice: Notice) {
    dispatchPrecondition(condition: .onQueue(stateQueue))
    guard running, pendingSeeks == 0 else { return }
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

  /// Track navigation shares seek cancellation and the serialized Apple Event queue.
  func changeTrack(forward: Bool, completion: @escaping (Error?) -> Void) {
    cancelSeeks()
    let generation = syncGeneration()
    readerQueue.async {
      do {
        try self.checkSeek(generation)
        let verb = forward ? "next track" : "previous track"
        var error: NSDictionary?
        guard let script = NSAppleScript(source: "if application \"Spotify\" is running then tell application \"Spotify\" to \(verb)") else {
          throw StemError("Cannot prepare Spotify track navigation")
        }
        script.executeAndReturnError(&error)
        if let error { throw StemError("Spotify track navigation failed: \(error)") }
        completion(nil)
      } catch { completion(error) }
    }
  }
  private func syncGeneration() -> UInt64 {
    var value: UInt64 = 0
    syncState { value = seekGeneration }
    return value
  }

  private static func writePosition(_ target: Double, expectedTrackID: String) throws {
    // POSIX formatting keeps the decimal point independent of the user's locale.
    // Only validated numeric data crosses into AppleScript.
    guard target.isFinite, target >= 0 else { throw SeekError.invalidSnapshot }
    let number = String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), target)
    let track = expectedTrackID.replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
      .replacingOccurrences(of: "\r", with: "\\r").replacingOccurrences(of: "\n", with: "\\n")
    let source = """
      with timeout of 2 seconds
        if application "Spotify" is not running then error number -1708
        tell application "Spotify"
          if id of current track is not "\(track)" then error "Track changed; try seeking again"
          set player position to \(number)
        end tell
      end timeout
      """
    guard let script = NSAppleScript(source: source) else {
      throw StemError("Cannot create Spotify seek script")
    }
    var error: NSDictionary?
    script.executeAndReturnError(&error)
    if let error {
      throw StemError("Spotify seek failed · \(error[NSAppleScript.errorMessage] as? String ?? error.description)")
    }
  }
  private static let stateSource = """
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
  /// Compiled on its first run and kept: compiling it every 250 ms was ~40% of each read. A
  /// failed read drops it, so the next read compiles afresh, as every read did before.
  /// NSAppleScript is not thread-safe, and two sessions can overlap for a moment.
  private static var stateScript: NSAppleScript?
  private static let stateScriptLock = NSLock()
  private static func readSnapshot() throws -> PlaybackSnapshot {
    var scriptError: NSDictionary?
    stateScriptLock.lock()
    guard let script = stateScript ?? NSAppleScript(source: stateSource) else {
      stateScriptLock.unlock()
      throw StemError("Cannot create Spotify state script")
    }
    let reply = script.executeAndReturnError(&scriptError)
    stateScript = reply.stringValue == nil ? nil : script
    stateScriptLock.unlock()
    guard let value = reply.stringValue else {
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
