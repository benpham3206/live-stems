import AppKit

// Finder supplies the two real icons. This image supplies only the backdrop.
let size = NSSize(width: 720, height: 480)
let image = NSImage(size: size)
image.lockFocus()
let canvas = NSRect(origin: .zero, size: size)
NSGradient(starting: NSColor(calibratedWhite: 0.985, alpha: 1), ending: NSColor(calibratedWhite: 0.93, alpha: 1))!.draw(in: canvas, angle: -90)
func text(_ value: String, _ x: CGFloat, _ y: CGFloat, _ size: CGFloat, _ weight: NSFont.Weight, _ color: NSColor) {
  (value as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color])
}
let white = NSColor(calibratedWhite: 0.10, alpha: 1)
let secondary = NSColor(calibratedWhite: 0.43, alpha: 1)
text("Live Stems", 48, 379, 36, .semibold, white)
text("Your music. Every part.", 50, 348, 17, .regular, secondary)
text("INSTALL", 51, 431, 10, .semibold, NSColor(calibratedRed: 0.16, green: 0.38, blue: 0.77, alpha: 1))
// A restrained waveform ties the window to audio without competing with icons.
let wave = NSBezierPath()
for i in 0..<42 {
  let x = 486 + CGFloat(i)*4
  let amplitude = 3 + 14*pow(sin(Double(i)*0.37),2)
  wave.move(to: NSPoint(x: x, y: 393-amplitude))
  wave.line(to: NSPoint(x: x, y: 393+amplitude))
}
wave.lineWidth = 1.5
NSColor(calibratedWhite: 0.78, alpha: 1).setStroke()
wave.stroke()
let arrow = NSBezierPath()
arrow.move(to: NSPoint(x: 324, y: 244)); arrow.line(to: NSPoint(x: 396, y: 244))
arrow.move(to: NSPoint(x: 386, y: 254)); arrow.line(to: NSPoint(x: 396, y: 244)); arrow.line(to: NSPoint(x: 386, y: 234))
arrow.lineWidth = 2
secondary.setStroke(); arrow.stroke()
text("Drag Live Stems into Applications", 208, 103, 17, .medium, white)
text("Then open it from Applications to start listening.", 192, 76, 13, .regular, secondary)
let line = NSBezierPath(); line.move(to: NSPoint(x: 48,y: 49)); line.line(to: NSPoint(x: 672,y: 49))
NSColor(calibratedWhite: 0.81, alpha: 1).setStroke(); line.lineWidth = 0.5; line.stroke()
text("APPLE SILICON", 49, 25, 9, .medium, secondary)
text("macOS 14.2 or later", 555, 25, 10, .regular, secondary)
image.unlockFocus()
let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
