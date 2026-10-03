// Draws the app icon. Regenerate Packaging/AppIcon.icns with:
//   swift Scripts/make-icon.swift /tmp/AppIcon.iconset && iconutil -c icns /tmp/AppIcon.iconset -o Packaging/AppIcon.icns
import AppKit
// Apple's icon grid: a 1024 canvas, the shape 824×824 centred, continuous corners (~22.5 % radius).
func render(_ px: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: px, height: px)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px) / 1024
    let body = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let shape = NSBezierPath(roundedRect: body, xRadius: 185 * s, yRadius: 185 * s)
    // soft drop shadow, as on Apple's icons
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.35); shadow.shadowBlurRadius = 20 * s; shadow.shadowOffset = NSSize(width: 0, height: -10 * s)
    shadow.set()
    NSColor.black.setFill(); shape.fill()
    NSGraphicsContext.restoreGraphicsState()
    // dark graphite gradient body
    NSGradient(starting: NSColor(calibratedRed: 0.20, green: 0.21, blue: 0.25, alpha: 1), ending: NSColor(calibratedRed: 0.06, green: 0.06, blue: 0.08, alpha: 1))!
        .draw(in: shape, angle: -90)
    // subtle top highlight
    NSColor.white.withAlphaComponent(0.08).setStroke(); shape.lineWidth = 3 * s; shape.stroke()
    // An eye with a slash, drawn from scratch (SF Symbols may not be used in app icons).
    let cx = 512 * s, cy = 508 * s
    let w: CGFloat = 640 * s, h: CGFloat = 380 * s
    let eye = NSBezierPath()
    eye.move(to: NSPoint(x: cx - w / 2, y: cy))
    eye.curve(to: NSPoint(x: cx + w / 2, y: cy), controlPoint1: NSPoint(x: cx - w * 0.22, y: cy + h * 0.78), controlPoint2: NSPoint(x: cx + w * 0.22, y: cy + h * 0.78))
    eye.curve(to: NSPoint(x: cx - w / 2, y: cy), controlPoint1: NSPoint(x: cx + w * 0.22, y: cy - h * 0.78), controlPoint2: NSPoint(x: cx - w * 0.22, y: cy - h * 0.78))
    eye.close()
    let iris = NSBezierPath(ovalIn: NSRect(x: cx - 120 * s, y: cy - 120 * s, width: 240 * s, height: 240 * s))
    let pupil = NSBezierPath(ovalIn: NSRect(x: cx - 62 * s, y: cy - 62 * s, width: 124 * s, height: 124 * s))
    let light = NSGradient(starting: NSColor(calibratedWhite: 1, alpha: 1), ending: NSColor(calibratedRed: 0.72, green: 0.80, blue: 0.95, alpha: 1))!
    let dark = NSColor(calibratedRed: 0.11, green: 0.12, blue: 0.15, alpha: 1)
    // white of the eye, then a dark ring for the iris, then the light pupil
    light.draw(in: eye, angle: -90)
    dark.setFill(); iris.fill()
    light.draw(in: pupil, angle: -90)
    // the slash: a dark gap with a light bar inside, top-left to bottom-right
    let a1 = NSPoint(x: cx - 250 * s, y: cy + 250 * s), a2 = NSPoint(x: cx + 250 * s, y: cy - 250 * s)
    let gap = NSBezierPath(); gap.move(to: a1); gap.line(to: a2); gap.lineWidth = 92 * s; gap.lineCapStyle = .round
    let bar = NSBezierPath(); bar.move(to: a1); bar.line(to: a2); bar.lineWidth = 46 * s; bar.lineCapStyle = .round
    NSGraphicsContext.saveGraphicsState(); shape.addClip()
    dark.setStroke(); gap.stroke()
    NSColor(calibratedRed: 0.86, green: 0.90, blue: 0.98, alpha: 1).setStroke(); bar.stroke()
    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}
let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256),
                   ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try! render(px).representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent("icon_\(name).png"))
}
