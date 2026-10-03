import AppKit
import IOSurface

// Frame model

struct FrameGeometry: Equatable, CustomStringConvertible {
    var bufferWidth: Int
    var bufferHeight: Int
    var contentRect: CGRect     // where the window sits in the buffer, in points (pixels = points × scaleFactor)
    var contentScale: CGFloat   // < 1 when ScreenCaptureKit shrank the window to fit the buffer
    var scaleFactor: CGFloat    // the display's backing scale
    /// Set for a frame whose window image is smaller than the content rectangle (Stage Manager animations):
    /// the opaque part actually showing the window, in buffer pixels, top-left origin.
    var crop: CGRect? = nil

    /// Content rectangle in buffer pixels, top-left origin, clamped to the buffer.
    var pixelRect: CGRect {
        if let crop { return crop }
        let full = CGRect(x: 0, y: 0, width: bufferWidth, height: bufferHeight)
        guard contentRect.width > 0, contentRect.height > 0 else { return full }
        let r = CGRect(x: contentRect.minX * scaleFactor, y: contentRect.minY * scaleFactor,
                       width: contentRect.width * scaleFactor, height: contentRect.height * scaleFactor).intersection(full)
        return r.isEmpty ? full : r
    }

    var description: String {
        String(format: "buffer %d×%d contentRect (%.0f,%.0f %.0f×%.0f) cs %.3f sf %.1f",
               bufferWidth, bufferHeight, contentRect.minX, contentRect.minY,
               contentRect.width, contentRect.height, contentScale, scaleFactor)
    }
}

struct CapturedFrame {
    let surface: IOSurface
    let displayTime: UInt64
    let geometry: FrameGeometry
    let gaps: [Int]          // fully-transparent px inward from each edge middle: [L, T, R, B]
    let fill: CGColor?       // window's own left-edge colour, from a good frame
}

/// Fully transparent pixels counted inward from the middle of each edge of the content rectangle
/// (left, top, right, bottom). Middles avoid the rounded corners.
func edgeGaps(_ surface: IOSurface, geometry g: FrameGeometry) -> [Int] {
    let c = g.pixelRect.integral
    guard c.width >= 16, c.height >= 16, IOSurfaceLock(surface, .readOnly, nil) == kIOReturnSuccess else { return [0, 0, 0, 0] }
    defer { IOSurfaceUnlock(surface, .readOnly, nil) }
    let base = IOSurfaceGetBaseAddress(surface).assumingMemoryBound(to: UInt8.self)
    let rowBytes = IOSurfaceGetBytesPerRow(surface)
    let w = IOSurfaceGetWidth(surface), h = IOSurfaceGetHeight(surface)
    func a(_ x: Int, _ y: Int) -> UInt8 { (x >= 0 && y >= 0 && x < w && y < h) ? base[y * rowBytes + x * 4 + 3] : 255 }
    let x0 = Int(c.minX), y0 = Int(c.minY), x1 = Int(c.maxX) - 1, y1 = Int(c.maxY) - 1
    let mx = (x0 + x1) / 2, my = (y0 + y1) / 2
    func run(_ x: Int, _ y: Int, _ dx: Int, _ dy: Int, _ limit: Int) -> Int {
        var n = 0
        while n < limit && a(x + n * dx, y + n * dy) == 0 { n += 1 }
        return n
    }
    return [run(x0, my, 1, 0, Int(c.width) / 2), run(mx, y0, 0, 1, Int(c.height) / 2),
            run(x1, my, -1, 0, Int(c.width) / 2), run(mx, y1, 0, -1, Int(c.height) / 2)]
}

/// An offset frame whose opaque part is still the whole window, just smaller and shifted (Stage Manager
/// grow/shrink animations): show that part instead of holding the old frame. nil when the opaque part is
/// too small or its shape doesn't match the content rectangle (then it's a partial window, not a scaled one).
func wholeWindowCrop(_ g: FrameGeometry, _ gaps: [Int]) -> FrameGeometry? {
    let c = g.pixelRect.integral
    let r = CGRect(x: c.minX + CGFloat(gaps[0]), y: c.minY + CGFloat(gaps[1]),
                   width: c.width - CGFloat(gaps[0] + gaps[2]), height: c.height - CGFloat(gaps[1] + gaps[3]))
    guard r.width >= 64, r.height >= 64, c.width > 0, c.height > 0,
          abs((r.width / r.height) / (c.width / c.height) - 1) < 0.03 else { return nil }
    var shown = g
    shown.crop = r
    return shown
}

/// Colour of the window's left edge, halfway down (the sidebar for most apps), from a good frame.
func edgeColor(_ surface: IOSurface, geometry g: FrameGeometry) -> CGColor? {
    let c = g.pixelRect.integral
    guard c.width >= 16, c.height >= 16, IOSurfaceLock(surface, .readOnly, nil) == kIOReturnSuccess else { return nil }
    defer { IOSurfaceUnlock(surface, .readOnly, nil) }
    let base = IOSurfaceGetBaseAddress(surface).assumingMemoryBound(to: UInt8.self)
    let i = Int(c.midY) * IOSurfaceGetBytesPerRow(surface) + (Int(c.minX) + 6) * 4
    let a = CGFloat(base[i + 3]) / 255
    guard a > 0.9 else { return nil }
    // BGRA, premultiplied
    return CGColor(srgbRed: CGFloat(base[i + 2]) / 255 / a, green: CGFloat(base[i + 1]) / 255 / a, blue: CGFloat(base[i]) / 255 / a, alpha: 1)
}
