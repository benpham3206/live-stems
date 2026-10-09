import AppKit

/// Headless check for stuck fader caps. AppKit repaints only the rectangles a
/// control marks dirty, so a cap that paints outside them leaves ghost pixels.
/// This replays that: keep a "shown" bitmap, copy in only the dirty pixels after
/// each change, then compare it with a full redraw. No window is ever shown.
/// A fader that remembers every rectangle AppKit asked to repaint.
private final class RecordingSlider: NSSlider {
  var dirty = [NSRect]()
  override func setNeedsDisplay(_ invalidRect: NSRect) {
    dirty.append(invalidRect)
    super.setNeedsDisplay(invalidRect)
  }
  override var needsDisplay: Bool {
    didSet { if needsDisplay { dirty.append(bounds) } }
  }
}

enum FaderRedrawE2E {
  private struct Pixels {
    let rep: NSBitmapImageRep
    var bytes: [UInt8]
    init(_ rep: NSBitmapImageRep) {
      self.rep = rep
      bytes = Array(UnsafeBufferPointer(start: rep.bitmapData!, count: rep.bytesPerRow * rep.pixelsHigh))
    }
  }

  private static func render(_ view: NSView) -> Pixels {
    let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
    NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance { view.cacheDisplay(in: view.bounds, to: rep) }
    return Pixels(rep)
  }

  /// Number of pixels that differ from a full redraw after repainting dirty areas only.
  private static func ghostPixels(_ fader: RecordingSlider, _ groups: [(FaderCell, NSSlider) -> Void]) -> Int {
    let cell = fader.cell as! FaderCell
    var shown = render(fader)
    for change in groups {
      fader.dirty = []
      change(cell, fader)
      let fresh = render(fader)
      let scale = CGFloat(fresh.rep.pixelsWide) / fader.bounds.width
      for row in 0..<fresh.rep.pixelsHigh {
        let y = fader.isFlipped ? (CGFloat(row) + 0.5) / scale : fader.bounds.height - (CGFloat(row) + 0.5) / scale
        for column in 0..<fresh.rep.pixelsWide {
          let x = (CGFloat(column) + 0.5) / scale
          guard fader.dirty.contains(where: { $0.contains(NSPoint(x: x, y: y)) }) else { continue }
          let at = row * fresh.rep.bytesPerRow + column * 4
          for channel in 0..<4 { shown.bytes[at + channel] = fresh.bytes[at + channel] }
        }
      }
    }
    let final = render(fader)
    return zip(shown.bytes, final.bytes).filter { abs(Int($0) - Int($1)) > 2 }.count
  }

  static func run() throws {
    // Same setup as ChannelStrip's fader, but recording its repaint requests.
    let fader = RecordingSlider(value: 1, minValue: 0, maxValue: 1, target: nil, action: nil)
    fader.cell = FaderCell()
    fader.minValue = 0
    fader.maxValue = 1
    fader.isVertical = true
    fader.isContinuous = true
    fader.frame = NSRect(x: 0, y: 0, width: 46, height: 196)
    func set(_ values: Float...) -> (FaderCell, NSSlider) -> Void {
      { _, slider in for value in values { slider.floatValue = value } }
    }
    // A drag step: the cell moves the cap to where the pointer is, like trackMouse does.
    func drag(to fraction: CGFloat) -> (FaderCell, NSSlider) -> Void {
      { cell, slider in
        let track = cell.trackRect
        let point = NSPoint(x: slider.bounds.midX, y: track.minY + cell.knobThickness / 2 + fraction * (track.height - cell.knobThickness))
        _ = cell.continueTracking(last: point, current: point, in: slider)
      }
    }
    let scenarios: [(String, Float, [(FaderCell, NSSlider) -> Void])] = [
      ("0 dB to -inf", 1, [set(0)]),
      ("-inf to 0 dB", 0, [set(1)]),
      ("0 dB to -inf and back before a repaint", 1, [set(0, 1)]),
      ("back and forth, one repaint each", 1, [set(0), set(1), set(0), set(1)]),
      ("back and forth, no repaint between", 1, [set(0, 1, 0, 1, 0)]),
      ("drag down then up", 1, [drag(to: 0.5), drag(to: 0), drag(to: 1), drag(to: 0)]),
    ]
    var report = [[String: Any]]()
    var failures = [String]()
    for (name, start, groups) in scenarios {
      fader.floatValue = start
      let ghosts = ghostPixels(fader, groups)
      report.append(["scenario": name, "ghost_pixels": ghosts])
      if ghosts > 0 { failures.append("\(name): \(ghosts)") }
    }
    guard failures.isEmpty else { throw StemError("FAIL fader-redraw · ghost pixels: " + failures.joined(separator: "; ")) }
    print("PASS fader-redraw · \(report.count) scenarios, no ghost pixels")
  }
}
