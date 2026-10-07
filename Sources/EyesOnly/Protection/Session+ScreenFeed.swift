import AppKit
import ScreenCaptureKit
import CoreMedia

/// During Stage Manager's grow-out animation the window capture only has
/// unusable frames, so the copy froze on an old one. macOS draws that animation itself (tilted, scaled), and
/// a capture of the screen there — without our own windows — has it. A new stream takes about as long as the
/// animation to start, so one runs slowly while the window sits in the strip or Mission Control is open (a click
/// there grows the window back the same way), at full rate only while it moves.
/// With "live previews" on, the copy also shows the strip thumbnail (and the Mission Control tile) from it, so
/// they look normal locally; captures still see the black cover.
@MainActor
extension Session {
    var screenFeedHot: Bool { screenFeedHotSince != 0 }
    /// Live previews: the strip thumbnail's copy comes from the feed, also while it's idle.
    var screenFeedLive: Bool { owner?.livePreviews == true && inStrip }
    /// The copy is showing screen frames instead of the window's own.
    var screenFeedShowing: Bool { (screenFeedHot || screenFeedLive) && screenFeedShown > 0 }
    /// Where a grow-back animation can start from.
    var screenFeedWanted: Bool { inStrip || owner?.missionControlOpen == true }
    var screenFeedIdleFps: Int { screenFeedLive ? 4 : 2 }

    /// From the tick: start, speed up, slow down or stop the feed. `moving`: the window changed size or place.
    func updateScreenFeed(_ f: NSRect, moving: Bool) {
        if screenFeedWanted, screenFeed == nil, !screenFeedStarting { Task { await startScreenFeed(f) } }
        guard screenFeed != nil else { return }
        let quiet = Date().timeIntervalSince(targetGeometryChangedAt)
        // Full rate all the while Mission Control is open: the window flies back the moment it closes.
        let missionControl = owner?.missionControlOpen == true
        let proxyMoved = overlay.proxyFrame != lastFeedProxyFrame
        lastFeedProxyFrame = overlay.proxyFrame
        if moving || proxyMoved || missionControl, !screenFeedHot { setScreenFeedHot(true) }
        if !screenFeedHot, screenFeedFps != screenFeedIdleFps { setScreenFeedRate(screenFeedIdleFps) }   // live previews switched
        if !screenFeedLive, overlay.proxyCopyShown { overlay.setProxyCopy(nil) }
        if missionControl != feedTraceMissionControl {
            feedTraceMissionControl = missionControl
            if !missionControl, screenFeedHot { feedTraceStart = mach_absolute_time(); feedTraceState = "" }   // trace the way back
        }
        if moving { let r = cocoaRect(f); feedTrace(String(format: "window at (%.0f,%.0f %.0f×%.0f) pt", r.minX, r.minY, r.width, r.height)) }
        // Back to the window's own frames once it has settled and they're usable again.
        if screenFeedHot, !missionControl, quiet > 0.4, unusableBurstStart == nil || quiet > 1.5 { setScreenFeedHot(false) }
        if !screenFeedHot, !screenFeedWanted, quiet > 1 { stopScreenFeed() }
    }

    func setScreenFeedRate(_ fps: Int) {
        guard let s = screenFeed else { return }
        screenFeedFps = fps
        guard !screenFeedConfigBusy else { return }   // the running update picks up the newest rate after it
        screenFeedConfigBusy = true
        Task { @MainActor in
            var applied = 0
            while applied != screenFeedFps, screenFeed === s {
                applied = screenFeedFps
                do { try await s.updateConfiguration(screenFeedConfig(screenFeedDisplay.size, scale: screenFeedScale, fps: applied)) }
                catch { log("SCREENFEED config failed: \(error.localizedDescription)") }
            }
            screenFeedConfigBusy = false
        }
    }

    func startScreenFeed(_ f: NSRect) async {
        screenFeedStarting = true
        defer { screenFeedStarting = false }
        let begun = mach_absolute_time()
        do {
            let content = try await withTimeout(4) { try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) }
            guard running, screenFeedWanted, screenFeed == nil else { return }
            let center = NSPoint(x: f.midX, y: f.midY)
            guard let screen = NSScreen.screens.first(where: { $0.frame.contains(center) }) ?? NSScreen.main,
                  let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  let display = content.displays.first(where: { $0.displayID == number.uint32Value }) else { throw failure("display not found") }
            // Without our own windows: the black cover and the copy would otherwise be all it shows.
            let me = content.applications.filter { $0.processID == getpid() }
            guard !me.isEmpty else { throw failure("own app not found") }
            let sink = FrameSink(onFrame: { [weak self] frame in
                MainActor.assumeIsolated { self?.receiveScreenFeed(frame) }
            }, onStop: { [weak self] stopped, error in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.screenFeedStopped(stopped, error) } }
            })
            let scale = screen.backingScaleFactor
            let s = SCStream(filter: SCContentFilter(display: display, excludingApplications: me, exceptingWindows: []),
                             configuration: screenFeedConfig(display.frame.size, scale: scale, fps: screenFeedIdleFps), delegate: sink)
            try s.addStreamOutput(sink, type: .screen, sampleHandlerQueue: screenFeedQueue)
            try await withTimeout(4) { try await s.startCapture() }
            guard running, screenFeed == nil else { Task { try? await s.stopCapture() }; return }
            screenFeed = s; screenFeedSink = sink; screenFeedFps = screenFeedIdleFps
            screenFeedDisplay = display.frame; screenFeedScale = scale
            log(String(format: "SCREENFEED ready in %.0f ms (display %.0f×%.0f pt @ %.0f×, idle %d fps)",
                       machMilliseconds(mach_absolute_time() - begun), display.frame.width, display.frame.height, scale, screenFeedFps))
        } catch {
            log("SCREENFEED could not start: \(error.localizedDescription)")
        }
    }

    func screenFeedConfig(_ size: CGSize, scale: CGFloat, fps: Int) -> SCStreamConfiguration {
        let c = SCStreamConfiguration()
        c.width = Int((size.width * scale).rounded()); c.height = Int((size.height * scale).rounded())
        c.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(1, fps)))
        c.queueDepth = 4
        c.pixelFormat = kCVPixelFormatType_32BGRA
        c.showsCursor = false
        return c
    }

    /// Millisecond trace of everything the copy does for 2.5 s after the window starts moving: the log's
    /// one-second timestamps can't show which step a frame-long jump at the end lines up with.
    func feedTrace(_ line: @autoclosure () -> String) {
        #if !SHIP   // development builds only
        guard feedTraceStart != 0 else { return }
        let ms = machMilliseconds(mach_absolute_time() - feedTraceStart)
        guard ms < 2500 else { feedTraceStart = 0; return }
        logDetail(String(format: "TRACE +%4.0f ms ", ms) + line())
        #endif
    }

    func traceState(_ o: Overlay) {
        #if !SHIP
        guard feedTraceStart != 0 else { return }
        let state = "copy \(o.copyVisible ? "on" : "black") · \(o.keepOnTop ? "floating" : "in window order")\(o.aboveSystemUI ? " · above system UI" : "") · Mission Control \(owner?.missionControlOpen == true ? "open" : "closed") · front \(NSWorkspace.shared.frontmostApplication?.processIdentifier == targetPID ? "yes" : "no")"
        if state != feedTraceState { feedTraceState = state; feedTrace("state: " + state) }
        #endif
    }

    func setScreenFeedHot(_ hot: Bool) {
        guard screenFeed != nil else { return }
        if hot {
            screenFeedHotSince = mach_absolute_time(); hotFrames = 0
            // Live previews were already showing current screen frames: keep showing them, no gap.
            if !screenFeedLive { screenFeedShown = 0 }
            feedTraceStart = screenFeedHotSince; feedTraceState = ""
            logDetail("SCREENFEED full rate (window moving)")
        } else {
            logDetail("SCREENFEED idle (\(hotFrames) screen frames at full rate)")
            screenFeedHotSince = 0
            if !screenFeedLive {
                feedTrace("screen feed off → window frames from now on")
                handoverPending = screenFeedShown > 0
                screenFeedShown = 0
            }
        }
        setScreenFeedRate(hot ? fps(for: .active) : screenFeedIdleFps)
    }

    func receiveScreenFeed(_ frame: CapturedFrame) {
        // Only frames taken since the window started moving (older ones show the screen as it was), or any
        // with live previews (the feed is the thumbnail's picture then).
        let live = screenFeedLive
        guard live || (screenFeedHot && frame.displayTime >= screenFeedHotSince) else { return }
        let o = overlay, d = screenFeedDisplay
        var g = frame.geometry
        guard d.width > 0, g.bufferWidth > 0 else { return }
        let s = CGFloat(g.bufferWidth) / d.width
        let buffer = CGRect(x: 0, y: 0, width: g.bufferWidth, height: g.bufferHeight)
        /// A place on screen (Cocoa) → the same place in the frame, in pixels, top-left origin.
        func pixels(_ f: NSRect) -> CGRect {
            let r = cocoaRect(f)
            return CGRect(x: (r.minX - d.minX) * s, y: (r.minY - d.minY) * s, width: r.width * s, height: r.height * s).intersection(buffer)
        }
        // Stage Manager's own thumbnail surface, covered separately.
        if live, let p = o.proxyFrame, case let c = pixels(p), c.width >= 8, c.height >= 8 {
            o.setProxyCopy(frame.surface, crop: c, bufferWidth: g.bufferWidth, bufferHeight: g.bufferHeight)
        } else if o.proxyCopyShown {
            o.setProxyCopy(nil)
        }
        let r = cocoaRect(o.frame)   // the window's place on screen, top-left origin
        let crop = pixels(o.frame)
        guard crop.width >= 8, crop.height >= 8 else { return }
        g.scaleFactor = s; g.crop = crop
        if screenFeedHot, hotFrames == 0 {
            logDetail(String(format: "SCREENFEED first frame %.0f ms after the window started moving", machMilliseconds(mach_absolute_time() - screenFeedHotSince)))
        }
        if screenFeedHot { hotFrames += 1 }
        screenFeedShown += 1
        o.setFrameContents(frame.surface, geometry: g)
        o.setCopyRounded(false)
        #if !SHIP
        lastFeedSurface = frame.surface; lastFeedCrop = crop   // for compareHandover
        #endif
        feedTrace(String(format: "screen frame #%d at (%.0f,%.0f %.0f×%.0f) pt, %.0f ms old", screenFeedShown, r.minX, r.minY, r.width, r.height,
                         mach_absolute_time() > frame.displayTime ? machMilliseconds(mach_absolute_time() - frame.displayTime) : 0))
    }

    /// The first window frame after the screen feed: how it differs from the last screen frame — shifted
    /// (best match away from 0,0) or recoloured (still different at the best shift). Sampled on a grid.
    func compareHandover(_ window: IOSurface, _ g: FrameGeometry) {
        #if !SHIP   // development builds only
        guard handoverPending else { return }
        handoverPending = false
        guard let screen = lastFeedSurface else { return }
        let a = g.pixelRect.integral, b = lastFeedCrop.integral
        guard g.crop == nil, abs(a.width - b.width) <= 4, abs(a.height - b.height) <= 4, a.width > 64, a.height > 64 else {
            feedTrace(String(format: "handover: sizes differ (window %.0f×%.0f px, screen %.0f×%.0f px)", a.width, a.height, b.width, b.height)); return
        }
        guard IOSurfaceLock(window, .readOnly, nil) == kIOReturnSuccess else { return }
        defer { IOSurfaceUnlock(window, .readOnly, nil) }
        guard IOSurfaceLock(screen, .readOnly, nil) == kIOReturnSuccess else { return }
        defer { IOSurfaceUnlock(screen, .readOnly, nil) }
        let wb = IOSurfaceGetBaseAddress(window).assumingMemoryBound(to: UInt8.self), wr = IOSurfaceGetBytesPerRow(window)
        let sb = IOSurfaceGetBaseAddress(screen).assumingMemoryBound(to: UInt8.self), sr = IOSurfaceGetBytesPerRow(screen)
        let sw = IOSurfaceGetWidth(screen), sh = IOSurfaceGetHeight(screen)
        let ww = IOSurfaceGetWidth(window), wh = IOSurfaceGetHeight(window)
        var best = (dx: 0, dy: 0, diff: Double.infinity), atZero = 0.0, channel = [0.0, 0.0, 0.0]
        for dy in -3...3 { for dx in -3...3 {
            var total = 0.0, n = 0.0, ch = [0.0, 0.0, 0.0]
            for j in 0..<40 { for i in 0..<40 {
                let x = Int(a.minX) + 12 + i * (Int(a.width) - 24) / 40, y = Int(a.minY) + 12 + j * (Int(a.height) - 24) / 40
                let x2 = Int(b.minX) + (x - Int(a.minX)) + dx, y2 = Int(b.minY) + (y - Int(a.minY)) + dy
                guard x < ww, y < wh, x2 >= 0, y2 >= 0, x2 < sw, y2 < sh else { continue }
                let p = wb + y * wr + x * 4, q = sb + y2 * sr + x2 * 4
                guard p[3] == 255 else { continue }   // the window's transparent corners
                for c in 0..<3 { let d = Double(p[c]) - Double(q[c]); total += abs(d); ch[c] += d }
                n += 1
            } }
            guard n > 0 else { continue }
            let diff = total / n / 3
            if dx == 0, dy == 0 { atZero = diff; channel = ch.map { $0 / n } }
            if diff < best.diff { best = (dx, dy, diff) }
        } }
        feedTrace(String(format: "handover: window vs last screen frame differ by %.1f/255 in place; best match shifted %d,%d px (%.1f/255); colour window−screen B%+.1f G%+.1f R%+.1f",
                         atZero, best.dx, best.dy, best.diff, channel[0], channel[1], channel[2]))
        #endif
    }

    func screenFeedStopped(_ stopped: SCStream, _ error: Error) {
        guard stopped === screenFeed else { return }
        log("SCREENFEED stopped: \(error.localizedDescription)")
        screenFeed = nil; screenFeedSink = nil; screenFeedHotSince = 0; screenFeedShown = 0
        overlay.setProxyCopy(nil)
    }

    func stopScreenFeed() {
        guard let s = screenFeed else { return }
        screenFeed = nil; screenFeedSink = nil; screenFeedHotSince = 0; screenFeedShown = 0
        overlay.setProxyCopy(nil)
        Task { try? await s.stopCapture() }
        logDetail("SCREENFEED stopped (window out of the strip and Mission Control)")
    }
}
