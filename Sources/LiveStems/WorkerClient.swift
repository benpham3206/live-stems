import Darwin
import Foundation

final class WorkerClient {
  private let process = Process(), input = Pipe(), output = Pipe()
  private let io = DispatchQueue(label: "stems.worker", qos: .userInitiated)
  private var log: FileHandle?
  private let lifecycle = NSLock()
  private var cancelled = false
  private func launch() throws {
    lifecycle.lock()
    defer { lifecycle.unlock() }
    guard !cancelled else { throw StemError("Processor start cancelled") }
    try process.run()
    let fd = input.fileHandleForWriting.fileDescriptor
    guard fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) != -1,
      fcntl(fd, F_SETNOSIGPIPE, 1) != -1
    else { throw StemError("Cannot prepare bounded processor input") }
  }
  func start(completion: @escaping (Result<Void, Error>) -> Void) {
    io.async {
      do {
        try FileManager.default.createDirectory(
          at: LocalSettings.evidence, withIntermediateDirectories: true)
        let path = LocalSettings.evidence.appendingPathComponent("worker-stderr.log")
        FileManager.default.createFile(atPath: path.path, contents: nil)
        self.log = try FileHandle(forWritingTo: path)
        self.process.executableURL = LocalSettings.python
        self.process.arguments = [
          LocalSettings.source.appendingPathComponent("worker/stem_worker.py").path, "--cache",
          LocalSettings.cache.path, "--trace-dir", LocalSettings.evidence.path,
        ]
        self.process.standardInput = self.input
        self.process.standardOutput = self.output
        self.process.standardError = self.log
        var env = ProcessInfo.processInfo.environment
        env["OMP_NUM_THREADS"] = "4"
        env["MKL_NUM_THREADS"] = "4"
        env["PYTHONUNBUFFERED"] = "1"
        self.process.environment = env
        try self.launch()
        let (h, b) = try self.reply(timeout: 20)
        guard h.integer(UInt16.self, 6) == 1,
          let ready = try JSONSerialization.jsonObject(with: b) as? [String: Any],
          ready["sources"] as? [String] == ["vocals", "drums", "bass", "other"],
          ready["window_frames"] as? Int == 44100
        else { throw StemError("Model did not become ready") }
        completion(.success(()))
      } catch {
        self.stop()
        completion(.failure(error))
      }
    }
  }
  private func read(_ count: Int, deadline: Double) throws -> Data {
    var data = Data(count: count)
    try data.withUnsafeMutableBytes { bytes in
      var offset = 0
      while offset < count {
        var fd = pollfd(
          fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
        let remaining = deadline - stemClock()
        guard remaining > 0 else { throw StemError("Processor response timed out") }
        let status = poll(&fd, 1, Int32(min(remaining * 1000, 20000)))
        if status < 0 && errno == EINTR { continue }
        guard status > 0 else { throw StemError("Processor response timed out") }
        let n = Darwin.read(fd.fd, bytes.baseAddress!.advanced(by: offset), count - offset)
        if n < 0 && errno == EINTR { continue }
        guard n > 0 else { throw StemError("Processor stopped") }
        offset += n
      }
    }
    return data
  }
  private func write(_ data: Data, deadline: Double) throws {
    try data.withUnsafeBytes { bytes in
      var offset = 0
      let fd = input.fileHandleForWriting.fileDescriptor
      while offset < data.count {
        let remaining = deadline - stemClock()
        guard remaining > 0, process.isRunning else {
          throw StemError("Processor input timed out or stopped")
        }
        var wait = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        let status = poll(&wait, 1, Int32(min(remaining * 1000, 5000)))
        if status < 0 && errno == EINTR { continue }
        guard status > 0 else { throw StemError("Processor input timed out") }
        let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), data.count - offset)
        if count < 0 && (errno == EINTR || errno == EAGAIN) { continue }
        guard count > 0 else { throw StemError("Processor input closed") }
        offset += count
      }
    }
  }
  private func reply(timeout: Double) throws -> (Data, Data) {
    let deadline = stemClock() + timeout
    let h = try read(48, deadline: deadline)
    guard h.prefix(4) == Data("LSTM".utf8), h.integer(UInt16.self, 4) == 1,
      h.integer(UInt32.self, 44) <= 16 * 1024 * 1024
    else { throw StemError("Invalid processor packet") }
    let kind = h.integer(UInt16.self, 6)
    if kind == 1 || kind == 4 {
      guard h.integer(UInt32.self, 44) <= 65536 else {
        throw StemError("Processor message too large")
      }
    }
    let b = try read(Int(h.integer(UInt32.self, 44)), deadline: deadline)
    if h.integer(UInt16.self, 6) == 4 {
      throw StemError(String(data: b, encoding: .utf8) ?? "Processor error")
    }
    return (h, b)
  }
  func separate(
    _ window: AudioWindow, jobID: UInt64, completion: @escaping (Result<StemWindow, Error>) -> Void
  ) {
    io.async {
      do {
        guard self.process.isRunning, window.samples.count == Int(window.range.count) * 2 else {
          throw StemError("Invalid input window")
        }
        var h = Data("LSTM".utf8)
        h.appendLE(UInt16(1))
        h.appendLE(UInt16(2))
        h.appendLE(window.range.generation)
        h.appendLE(jobID)
        h.appendLE(window.range.start)
        h.appendLE(UInt32(44100))
        h.appendLE(window.range.count)
        h.appendLE(UInt16(2))
        h.appendLE(UInt16(1))
        h.appendLE(UInt32(window.samples.count * 4))
        let body = window.samples.withUnsafeBytes { Data($0) }
        try self.write(h + body, deadline: stemClock() + 5)
        let (response, data) = try self.reply(timeout: 5)
        guard response.integer(UInt16.self, 6) == 3,
          response.integer(UInt64.self, 8) == window.range.generation,
          response.integer(UInt64.self, 16) == jobID,
          response.integer(UInt64.self, 24) == window.range.start,
          response.integer(UInt32.self, 32) == 44100,
          response.integer(UInt32.self, 36) == window.range.count,
          response.integer(UInt16.self, 40) == 2, response.integer(UInt16.self, 42) == 4,
          data.count == Int(window.range.count) * 32
        else { throw StemError("Processor output does not match input") }
        var samples = [Float](repeating: 0, count: data.count / 4)
        _ = samples.withUnsafeMutableBytes { target in data.copyBytes(to: target) }
        guard samples.allSatisfy(\.isFinite) else { throw StemError("Invalid output samples") }
        completion(.success(StemWindow(range: window.range, samples: samples)))
      } catch { completion(.failure(error)) }
    }
  }
  func stop() {
    lifecycle.lock()
    cancelled = true
    let running = process.isRunning
    if running { process.terminate() }
    lifecycle.unlock()
    if running {
      let child = process
      DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
        if child.isRunning { kill(child.processIdentifier, SIGKILL) }
      }
    }
  }
  var pid: Int32 { process.processIdentifier }
  deinit {
    stop()
    try? log?.close()
  }
}
