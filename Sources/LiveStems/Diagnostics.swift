import AudioCore
import Foundation

struct SessionDiagnostics: Codable {
  var observedUptime: Double
  var sessionGeneration: UInt64
  var appPID: Int32
  var workerPID: Int32
  var capturePeak: Float
  var active: Bool
  var handedOff: Bool
  var captureFrames: Int
  var playedFrames: UInt64
  var queuedFrames: UInt32
  var historyFrames: Int
  var underrunFrames: UInt64
  var overflowCount: UInt64
  var discardedResults: Int
  var inferenceSeconds: [Double]
  var estimatedDelaySeconds: Double
  var observedCaptureToRenderSeconds: Double?
  var fallbacks: Int
  var paused: Bool
  var blendWeight: Float
  var cacheBytes: Int
  var cacheLimitBytes: Int
  var jumps: Int
  var hardCuts: Int
  var stemsSelected: Bool
  var windowFrames: Int
  var hopFrames: Int
  var lateResults: Int
  var acceptedResults: Int
  var steadyFrames: Int
  var steadyFullStemFrames: Int
  var steadyFallbackFrames: Int
  func save() {
    do {
      try FileManager.default.createDirectory(
        at: LocalSettings.evidence, withIntermediateDirectories: true)
      let encoder = JSONEncoder()
      encoder.outputFormatting = .prettyPrinted
      try encoder.encode(self).write(
        to: LocalSettings.evidence.appendingPathComponent("active-session.json"), options: .atomic)
    } catch { fputs("Diagnostics: \(error)\n", stderr) }
  }
}
