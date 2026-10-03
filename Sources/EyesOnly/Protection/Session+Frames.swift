import AppKit
import IOSurface

@MainActor
extension Session {
    // MARK: Receive — content + anti-flicker frame holding only (no window positioning)

    func receive(_ frame: CapturedFrame) {
        let o = overlay
        if startedAt != 0 {
            logDetail(String(format: "FIRST FRAME %.0f ms after the cover went up", machMilliseconds(mach_absolute_time() - startedAt)))
            startedAt = 0
        }
        let surface = frame.surface, displayTime = frame.displayTime, geometry = frame.geometry
        lastArrival = mach_absolute_time()
        // macOS delivers two kinds of unusable frames around Stage Manager:
        //  - empty: every pixel transparent while the window sits in the strip. Never shown; the copy
        //    keeps the last good frame.
        //  - offset: content pushed right/down with a transparent strip while the window grows back.
        //    Held during geometry animation; once settled, retain the 2 s safeguard.
        let gaps = frame.gaps
        let content = geometry.pixelRect.integral
        let empty = gaps[0] >= Int(content.width) / 2 && gaps[1] >= Int(content.height) / 2 &&
                    gaps[2] >= Int(content.width) / 2 && gaps[3] >= Int(content.height) / 2
        let offset = !empty && gaps.contains(where: { $0 > 2 })
        var shown = geometry
        if empty || offset {
            let now = Date()
            if unusableBurstStart == nil { unusableBurstStart = now; skippedEmpty = 0; skippedOffset = 0; shownCropped = 0; offsetMax = [0, 0, 0, 0] }
            if empty { offsetStart = nil }   // an empty frame ends a run of offset frames
            if heldSince == nil { heldSince = Date() }
            if empty, o.hasContents { skippedEmpty += 1; return }
            if offset {
                if offsetStart == nil { offsetStart = now }
                offsetMax = zip(offsetMax, gaps).map { max($0, $1) }
                let geometryStillMoving = now.timeIntervalSince(targetGeometryChangedAt) < 0.5
                if let live = wholeWindowCrop(geometry, gaps) {
                    shown = live; shownCropped += 1
                } else if o.hasContents, (now.timeIntervalSince(offsetStart!) < 2 || geometryStillMoving) {
                    skippedOffset += 1; return
                }
            }
        } else if let start = unusableBurstStart {
            logDetail(String(format: "UNUSABLE frames: %d empty and %d offset kept off screen, %d offset shown cropped, over %.0f ms (offset max px left %d top %d right %d bottom %d)",
                       skippedEmpty, skippedOffset, shownCropped, Date().timeIntervalSince(start) * 1000, offsetMax[0], offsetMax[1], offsetMax[2], offsetMax[3]))
            unusableBurstStart = nil; offsetStart = nil
        }
        if shown.crop == nil { heldSince = nil }
        o.setFrameContents(surface, geometry: shown)
        if !empty, !offset, let color = frame.fill { o.setFill(color) }
        // Measure the corner once; first full-resolution frame with ≥ 3 readable corners is final.
        let fullResolution = geometry.contentScale >= 0.99
        if !radiusFinal, !radiusMeasured || (fullResolution && Date() >= nextRadiusAttempt) {
            nextRadiusAttempt = Date().addingTimeInterval(0.5)
            if let (fraction, detail, readable) = measureCornerFraction(surface, geometry: geometry) {
                let naturalWidth = geometry.contentRect.width / geometry.contentScale
                o.radiusPoints = fraction * naturalWidth
                radiusMeasured = true
                radiusFinal = fullResolution && readable >= 3
                logDetail(String(format: "RADIUS %.1f pt from %@ frame (%@); corners %@", o.radiusPoints,
                           fullResolution ? "full-resolution" : "reduced", radiusFinal ? "final" : "provisional", detail))
            }
        }
        if geometry != lastGeometry {
            lastGeometry = geometry
            logDetail("FRAME \(geometry.description); mirror window \(o.frame.size) pt")
            // contentRect / contentScale is the window's real size in points, even when ScreenCaptureKit
            // shrank it to fit our buffer (Stage Manager reports a thumbnail frame on screen).
            if geometry.contentScale > 0, geometry.contentRect.width > 0 {
                let natural = CGSize(width: (geometry.contentRect.width / geometry.contentScale).rounded(),
                                     height: (geometry.contentRect.height / geometry.contentScale).rounded())
                captureScale = geometry.scaleFactor
                if abs(natural.width - naturalSize.width) > 2 || abs(natural.height - naturalSize.height) > 2 {
                    naturalSize = natural
                    naturalSizeChangedAt = Date()
                    o.naturalWidth = natural.width
                    updateProfile(desiredProfile(onScreen: o.frame.size))
                    scheduleProfileApply(after: 0.18)
                }
            }
        }
        frameCount += 1
        let now = mach_absolute_time()
        if now > displayTime {
            let age = machMilliseconds(now - displayTime)
            frameAgeTotal += age; frameAgeMax = max(frameAgeMax, age)
        }
        if lastFrameTime > 0 { frameGapMax = max(frameGapMax, machMilliseconds(now - lastFrameTime)) }
        lastFrameTime = now
    }

    /// Reads the window's transparent corners from the captured frame. Along a corner's diagonal, a
    /// rounded corner of radius r becomes opaque at distance s = r(1 − 1/√2) on each axis. Uses the
    /// largest of the four corners so no black shows locally. Returns radius / content width, or nil.
    func measureCornerFraction(_ surface: IOSurface, geometry g: FrameGeometry) -> (CGFloat, String, Int)? {
        let content = g.pixelRect.integral
        guard content.width >= 64, content.height >= 64, g.contentScale > 0, g.contentRect.width > 0 else { return nil }
        let pxPerPt = Double(content.width) / Double(g.contentRect.width / g.contentScale)
        let maxRadiusPx = 40 * pxPerPt, fallbackPx = 32 * pxPerPt
        guard IOSurfaceLock(surface, .readOnly, nil) == kIOReturnSuccess else { return nil }
        defer { IOSurfaceUnlock(surface, .readOnly, nil) }
        let base = IOSurfaceGetBaseAddress(surface).assumingMemoryBound(to: UInt8.self)
        let rowBytes = IOSurfaceGetBytesPerRow(surface)
        let width = IOSurfaceGetWidth(surface), height = IOSurfaceGetHeight(surface)
        func alpha(_ x: Int, _ y: Int) -> Int {
            guard x >= 0, y >= 0, x < width, y < height else { return 255 }
            return Int(base[y * rowBytes + x * 4 + 3])   // BGRA: alpha is byte 3
        }
        let x0 = Int(content.minX), y0 = Int(content.minY), x1 = Int(content.maxX) - 1, y1 = Int(content.maxY) - 1
        let corners = [(x0, y0, 1, 1), (x1, y0, -1, 1), (x0, y1, 1, -1), (x1, y1, -1, -1)]
        let maxSteps = min(Int((maxRadiusPx * (1 - 1 / 2.0.squareRoot())).rounded(.up)) + 2, Int(content.width) / 4, Int(content.height) / 4)
        var readings: [Double] = []
        var detail: [String] = []
        for (cx, cy, dx, dy) in corners {
            if alpha(cx, cy) > 2 { readings.append(0); detail.append("square"); continue }
            var found = false
            for i in 1...max(1, maxSteps) where alpha(cx + i * dx, cy + i * dy) > 2 {
                let r = (Double(i) + 0.8) / (1 - 1 / 2.0.squareRoot()) + 1
                readings.append(r); detail.append(String(format: "%.1fpt", r / pxPerPt)); found = true
                break
            }
            if !found { detail.append("unreadable") }
        }
        var radiusPx = readings.max() ?? fallbackPx
        var note = ""
        if readings.isEmpty { radiusPx = fallbackPx; note = " → no readable corner, using 32 pt" }
        else if radiusPx > maxRadiusPx { radiusPx = fallbackPx; note = " → above 40 pt cap, using 32 pt" }
        return (CGFloat(radiusPx) / content.width, detail.joined(separator: " ") + note, readings.count)
    }

    func failure(_ message: String) -> NSError { NSError(domain: "EyesOnly", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}
