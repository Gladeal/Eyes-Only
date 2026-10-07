import AppKit
import ScreenCaptureKit
import CoreMedia
import CoreVideo

// Session: one protected window (own stream, overlay and state)

@MainActor
final class Session {
    // Target + capture
    let windowID: CGWindowID
    let targetName: String
    let targetPID: pid_t
    let overlay = Overlay()
    var stream: SCStream?
    var sink: FrameSink?
    let sinkQueue = DispatchQueue(label: "EyesOnly.frames", qos: .userInteractive)
    var streamSize = CGSize.zero
    var captureScale: CGFloat = 2
    var naturalSize = CGSize.zero
    var naturalSizeChangedAt = Date.distantPast
    var targetGeometryChangedAt = Date.distantPast
    var lastGeometry: FrameGeometry?


    // Profiles
    var profile: CaptureProfile = .active
    var profileWork: DispatchWorkItem?
    var profileScheduleGeneration = 0
    var pendingConfig: SCStreamConfiguration?
    var configInFlight = false

    // Recovery
    var restartTask: Task<Void, Never>?
    var restartFailures = 0
    var restarting = false
    var restartStartedAt = Date.distantPast
    var restartGeneration = 0
    var lastStallRestart = Date.distantPast

    // Metrics
    var frameCount = 0
    var frameAgeTotal = 0.0, frameAgeMax = 0.0, frameGapMax = 0.0
    var lastFrameTime: UInt64 = 0
    var lastArrival: UInt64 = 0
    var lastStatsTime = Date()
    var tickMax = 0.0
    var placeCount = 0
    var lastPlace = Date.distantPast

    // Unusable-frame handling
    var skippedEmpty = 0, skippedOffset = 0, shownCropped = 0
    var onePixelOffHeld = 0   // since the last STATS line
    var offsetMax: [Int] = [0, 0, 0, 0]
    var offsetStart: Date?
    var unusableBurstStart: Date?
    var heldSince: Date?
    var clickAt: UInt64 = 0
    var attachedLogged = false
    #if !SHIP
    var shownAt = Date.distantPast   // when the cover last went up (Space-switch timing)
    #endif
    var missingSince: Date?   // not in the window list (closed, or moving into a full-screen Space)

    // Exposure / stacking
    var exposedSince: UInt64 = 0
    var exposures = 0
    var coverMissingSince: Date?
    var lastCoverCheck = Date.distantPast
    var appliedConfig = ""
    var startedAt: UInt64 = 0   // cover up → first frame: how long the picture is black after a (re)start
    /// Backing scale of the display the window is on (capture density follows it).
    var displayScale: CGFloat = 2
    var lastStackCheck = Date.distantPast
    var stackAttemptAt = Date.distantPast
    var stackFallbackUntil = Date.distantPast
    var stackRetried = false
    // Screen feed: Stage Manager / Mission Control animations and live previews (Session+ScreenFeed)
    var screenFeed: SCStream?
    var screenFeedSink: FrameSink?
    let screenFeedQueue = DispatchQueue(label: "EyesOnly.screenFeed", qos: .userInteractive)
    var screenFeedStarting = false
    var screenFeedDisplay = CGRect.zero   // CoreGraphics global points
    var screenFeedScale: CGFloat = 2
    var screenFeedFps = 2
    var screenFeedConfigBusy = false
    var screenFeedHotSince: UInt64 = 0    // 0: idle
    var screenFeedShown = 0
    var feedTraceStart: UInt64 = 0
    var feedTraceState = ""
    var feedTraceMissionControl = false
    var lastFeedSurface: IOSurface?
    var lastFeedCrop = CGRect.zero
    var handoverPending = false
    var hotFrames = 0
    var lastFeedProxyFrame: NSRect?

    // Corner radius
    var radiusMeasured = false
    var radiusFinal = false
    var nextRadiusAttempt = Date.distantPast

    // Previews
    var previewWindowID: CGWindowID?
    var previewMissSince: Date?
    var lastPreviewInventoryLogAt = Date.distantPast

    // Session
    weak var owner: Controller?
    var target: SCWindow?   // nil until start() looks it up (tab-driven sessions skip the wait)
    var captureWindow: SCWindow? { target }
    var running = false
    /// "Always keep on top". Off (default): automatic stacking — other apps can cover the window while it's
    /// in the background.
    var keepOnTop = false

    init(window: SCWindow, owner: Controller) {
        target = window
        windowID = window.windowID
        targetPID = window.owningApplication?.processID ?? 0
        targetName = "\(window.owningApplication?.applicationName ?? "?") — \(window.title ?? "")"
        self.owner = owner
    }

    /// For a browser window: the cover can go up at once, the capture's window handle is looked up after.
    init(windowID: CGWindowID, pid: pid_t, name: String, owner: Controller) {
        target = nil
        self.windowID = windowID
        targetPID = pid
        targetName = name
        self.owner = owner
    }

    /// Log lines carry the app's name only — never the window's title (titles can be private: chat names,
    /// document names), so a log is safe to send for troubleshooting.
    func log(_ line: String) { diagnosticsLog("[\(appName)] \(line)") }
    func logDetail(_ line: @autoclosure () -> String) { diagnosticsDetail("[\(appName)] \(line())") }
    private var appName: String { targetName.components(separatedBy: " — ").first ?? "?" }

    // MARK: Protection

    /// Cover first, then start mirroring: until the first frame arrives the user sees black locally.
    func start() async -> Bool {
        guard let state = windowInfo(windowID) else { return false }
        let o = overlay
        o.place(cocoaRect(state.bounds))
        o.keepOnTop = true   // automatic stacking (keep-on-top off) decides from the first check on
        if state.onScreen && !suspended { o.show(above: windowID) }
        running = true
        profile = .active
        startedAt = mach_absolute_time()
        captureScale = scale(for: state.bounds)
        displayScale = captureScale
        lastStatsTime = Date()
        let sink = FrameSink(onFrame: { [weak self] frame in
            MainActor.assumeIsolated { self?.receive(frame) }
        }, onStop: { [weak self] stopped, error in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.streamStopped(stopped, error) }
            }
        })
        self.sink = sink
        do {
            // The cover is already up; now find the window for ScreenCaptureKit if we don't have it yet.
            if target == nil {
                let content = try await withTimeout(4) { try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false) }
                guard running else { return false }
                guard let w = content.windows.first(where: { $0.windowID == windowID }) else { throw failure("the window is no longer available") }
                target = w
            }
            guard let target else { throw failure("the window is no longer available") }
            let size = state.bounds.size
            let config = streamConfig(size: size, scale: captureScale)
            let s = SCStream(filter: SCContentFilter(desktopIndependentWindow: target), configuration: config, delegate: sink)
            try s.addStreamOutput(sink, type: .screen, sampleHandlerQueue: sinkQueue)
            try await s.startCapture()
            guard running else { try? await s.stopCapture(); return false }
            stream = s; streamSize = size
            lastGeometry = nil
            // Started with the active profile's settings already: don't reconfigure to the same thing a moment later.
            appliedConfig = "\(config.width)×\(config.height)@\(fps(for: .active))·\(displayScale)x"
            logDetail("START window \(state.bounds) pt (CG), stream config \(config.width)×\(config.height) px")
            return true
        } catch {
            log("Could not start mirror stream: \(error.localizedDescription)")
            stop()
            return false
        }
    }

    func stop() {
        running = false
        restartTask?.cancel(); restartTask = nil
        profileWork?.cancel(); profileWork = nil; profileScheduleGeneration += 1
        if let stream { Task { try? await stream.stopCapture() } }
        stream = nil; sink = nil
        stopScreenFeed()
        pendingConfig = nil; configInFlight = false
        overlay.close()
        log("STOP. The window is no longer protected.")
    }

    /// A thumbnail of this window is showing in the Stage Manager strip.
    var inStrip: Bool { overlay.proxyFrame != nil || profile == .thumbnail }

    /// The in-between frames of a busy tick: only keep the cover on the window (one cheap single-window
    /// query). Everything else — previews, Mission Control, copy visibility, stacking — runs on full ticks.
    func follow() {
        guard running, overlay.visible, !overlay.mainHidden,
              let state = windowInfo(windowID), state.onScreen else { return }
        let f = cocoaRect(state.bounds)
        guard f != overlay.frame else { return }
        owner?.heat(1.0)
        placeCount += 1; lastPlace = Date(); targetGeometryChangedAt = lastPlace
        clickAt = 0
        overlay.place(f)
    }

    /// Created for a browser window because one of its tabs is protected (not the whole window).
    var tabDriven = false
    /// Created because its app is set to "always protect".
    var autoApp = false
    /// Tab-driven only: the active tab isn't protected — no cover, capture idling at 1 fps. The stream keeps
    /// running so the cover can come back the instant a protected tab is active again.
    var suspended = false

    func setSuspended(_ s: Bool) {
        guard s != suspended else { return }
        suspended = s
        if s {
            overlay.hide()
            if overlay.proxyFrame != nil { overlay.placeProxy(nil) }
            if running { updateProfile(.hidden) }
            logDetail("TAB: active tab not protected → cover paused")
        } else {
            logDetail("TAB: protected tab active → cover on")
            guard running, let state = windowInfo(windowID), state.onScreen else { return }
            overlay.place(cocoaRect(state.bounds))
            overlay.show(above: windowID)
            owner?.heat(1.5)
            updateProfile(desiredProfile(onScreen: state.bounds.size))
        }
    }

    func setKeepOnTop(_ on: Bool) {
        keepOnTop = on
        if on, !overlay.keepOnTop {
            overlay.keepOnTop = true
            overlay.backing.orderFrontRegardless(); overlay.mirror.orderFrontRegardless()
        }
        stackFallbackUntil = .distantPast
        logDetail("STACKING \(on ? "always keep on top" : "automatic")")
    }

    func scale(for cgBounds: CGRect) -> CGFloat {
        let f = cocoaRect(cgBounds)
        return NSScreen.screens.first(where: { $0.frame.contains(NSPoint(x: f.midX, y: f.midY)) })?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor ?? 2
    }

    /// The capture buffer is as big as the largest display at its own pixel density (and at least the window):
    /// a window that fits is then always captured pixel-for-pixel, whatever its size. Sized to the window
    /// instead, every time the window grew (moved to a bigger display, maximised, resized) the capture squeezed
    /// it into the old buffer — blurry until a reconfiguration caught up after it stopped moving.
    func bufferPixels(atLeast size: CGSize, scale: CGFloat) -> (width: Int, height: Int) {
        var w = size.width * scale, h = size.height * scale
        for screen in NSScreen.screens {
            w = max(w, screen.frame.width * screen.backingScaleFactor)
            h = max(h, screen.frame.height * screen.backingScaleFactor)
        }
        return (min(8192, max(2, Int(w.rounded(.up)))), min(8192, max(2, Int(h.rounded(.up)))))
    }

    func streamConfig(size: CGSize, scale: CGFloat, fps: Int = 60) -> SCStreamConfiguration {
        let c = SCStreamConfiguration()
        let buffer = bufferPixels(atLeast: size, scale: scale)
        c.width = buffer.width; c.height = buffer.height
        c.scalesToFit = false                 // never stretch a smaller window to fill the buffer
        c.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(1, fps)))
        c.queueDepth = 4   // one on screen, one waiting for the main thread, two for ScreenCaptureKit
        c.pixelFormat = kCVPixelFormatType_32BGRA
        c.showsCursor = false
        c.backgroundColor = .clear            // keep the window's rounded corners transparent
        c.ignoreShadowsSingleWindow = true
        // The density of the display the window is on. `.best` captures at the highest density available —
        // 2× (the built-in Retina) for a window on a 1× monitor — and that shrunk back down to 1× looks softer
        // than the window's own 1× text: the lasting blur on a big monitor whenever the window wasn't full-size.
        c.captureResolution = displayScale >= 1.5 ? .best : .nominal
        return c
    }
}
