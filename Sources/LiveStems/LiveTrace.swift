import Foundation
import OSLog

struct TraceRecord: Codable {
  var event: String
  var generation: UInt64
  var uptime: Double = stemClock()
  var sourceFrame: Int? = nil
  var sourceEnd: Int? = nil
  var renderedFrame: UInt64? = nil
  var windowStart: UInt64? = nil
  var windowFrames: UInt32? = nil
  var jobID: UInt64? = nil
  var workerPID: Int32? = nil
  var elapsedSeconds: Double? = nil
  var deadlineSlackSeconds: Double? = nil
  var queuedFrames: UInt32? = nil
  var fullStemFrames: Int? = nil
  var fallbackFrames: Int? = nil
  var blend: Float? = nil
  var stemsSelected: Bool? = nil
  var paused: Bool? = nil
  var estimatedTrackSeconds: Double? = nil
  var captureHostSeconds: Double? = nil
  var renderHostSeconds: Double? = nil
  var estimatedCaptureToRenderSeconds: Double? = nil
  var hardCuts: Int? = nil
  var lateResults: Int? = nil
  var lateFrames: Int? = nil
  var noticeHostSeconds: Double? = nil
  var thermalState: Int? = nil
  var muteMask: UInt32? = nil
  var soloMask: UInt32? = nil
  var gains: [Float]? = nil
  var droppedRecords: Int? = nil
  var outputBufferFrames: UInt32? = nil
  var reason: String? = nil  // why a session stopped; app messages only, never track data
}

// The audio callback only updates atomic values. Encoding and file access
// happen here, on a utility queue, with a bounded pending batch and two files.
final class LiveTrace {
  private let logger = Logger(subsystem: "com.benpham.livestems", category: "Timing")
  private let queue = DispatchQueue(label: "stems.trace", qos: .utility)
  private let lock = NSLock()
  private var pending = [TraceRecord](), dropped = 0
  private let directory: URL, fileLimit: Int
  private var timer: DispatchSourceTimer?, handle: FileHandle?, bytes = 0
  init(directory: URL = LocalSettings.evidence, fileLimit: Int = 2 * 1024 * 1024) {
    self.directory = directory; self.fileLimit = fileLimit
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .now(), repeating: .milliseconds(250))
    timer.setEventHandler { [weak self] in self?.flush() }
    timer.resume(); self.timer = timer
  }
  deinit { timer?.cancel(); try? handle?.close() }
  func record(_ value: TraceRecord) {
    lock.lock()
    if pending.count < 256 { pending.append(value) } else { dropped += 1 }
    lock.unlock()
    if value.event == "mix" || value.event == "start" || value.event == "stop" || value.event == "controls" {
      logger.info("\(value.event, privacy: .public) generation=\(value.generation) frame=\(value.sourceFrame ?? -1) stems=\(value.stemsSelected ?? false)")
    }
  }
  func flushSync() { queue.sync { flush() } }
  private func flush() {
    lock.lock()
    var batch = pending; pending.removeAll(keepingCapacity: true)
    let lost = dropped; dropped = 0
    lock.unlock()
    guard !batch.isEmpty else { return }
    batch[0].droppedRecords = lost
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let path = directory.appendingPathComponent("live-trace.jsonl")
      if handle == nil {
        if !FileManager.default.fileExists(atPath: path.path) {
          FileManager.default.createFile(atPath: path.path, contents: nil)
        }
        handle = try FileHandle(forWritingTo: path)
        bytes = Int(try handle!.seekToEnd())
      }
      let encoder = JSONEncoder()
      for value in batch {
        var data = try encoder.encode(value); data.append(10)
        if bytes + data.count > fileLimit {
          try handle?.close(); handle = nil
          let previous = directory.appendingPathComponent("live-trace.previous.jsonl")
          // Atomic replacement retains exactly one previous trace.
          if FileManager.default.fileExists(atPath: previous.path) {
            _ = try FileManager.default.replaceItemAt(previous, withItemAt: path)
          } else { try FileManager.default.moveItem(at: path, to: previous) }
          FileManager.default.createFile(atPath: path.path, contents: nil)
          handle = try FileHandle(forWritingTo: path); bytes = 0
        }
        try handle?.write(contentsOf: data); bytes += data.count
      }
    } catch { logger.error("Timing trace write failed: \(error.localizedDescription, privacy: .public)") }
  }
}
