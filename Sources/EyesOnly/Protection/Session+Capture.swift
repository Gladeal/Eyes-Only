import AppKit
import ScreenCaptureKit

@MainActor
extension Session {
    // MARK: Recovery

    func streamStopped(_ stopped: SCStream, _ error: Error) {
        // A stream we already replaced reporting its own shutdown: ignore it, or it would tear down the new one.
        guard stopped === stream else { log("STREAM (old) stopped: \(error.localizedDescription) — ignored"); return }
        log("STREAM stopped: \(error.localizedDescription)")
        stream = nil
        scheduleRestart("stream stopped", after: 1)
    }

    func scheduleRestart(_ reason: String, after seconds: Double) {
        guard running, restartTask == nil else { return }
        restartTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            restartTask = nil
            await restartStream(reason)
        }
    }

    func restartStream(_ reason: String) async {
        guard running, let sink, !restarting else { return }
        restarting = true
        restartStartedAt = Date()
        restartGeneration += 1
        let generation = restartGeneration
        defer { if restartGeneration == generation { restarting = false } }
        let id = windowID
        log("RESTART stream (\(reason))")
        // Don't wait for the old stream: after a display change its connection can be broken and never answer.
        if let old = stream { stream = nil; Task { try? await old.stopCapture() } }
        pendingConfig = nil; configInFlight = false
        do {
            // Every ScreenCaptureKit call gets a time limit; one that never returned froze the mirror for good.
            let content = try await withTimeout(4) { try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false) }
            guard running, restartGeneration == generation else { return }
            guard let w = content.windows.first(where: { $0.windowID == id }) else { throw failure("the protected window is no longer available") }
            let size = naturalSize.width > 0 ? naturalSize : w.frame.size
            let config = streamConfig(size: size, scale: captureScale, fps: fps(for: profile))
            let s = SCStream(filter: SCContentFilter(desktopIndependentWindow: w), configuration: config, delegate: sink)
            try s.addStreamOutput(sink, type: .screen, sampleHandlerQueue: sinkQueue)
            do {
                try await withTimeout(4) { try await s.startCapture() }
            } catch {
                Task { try? await s.stopCapture() }
                throw error
            }
            guard running, restartGeneration == generation else { Task { try? await s.stopCapture() }; return }
            stream = s; streamSize = size
            appliedConfig = ""   // a new stream: the next profile change applies whatever it asks for
            restartFailures = 0
            heldSince = nil
            log("RESTART ok")
        } catch {
            guard restartGeneration == generation else { return }
            restartFailures += 1
            let wait = min(10, 2 * Double(restartFailures))
            log("RESTART failed (#\(restartFailures)): \(error.localizedDescription); retrying in \(Int(wait)) s")
            restarting = false
            scheduleRestart("retry", after: wait)
        }
    }

    func noteClick() {
        let o = overlay
        guard o.visible, profile == .active, o.frame.contains(NSEvent.mouseLocation) else { return }
        clickAt = mach_absolute_time()
    }

    func checkForStall() {
        // Watchdog: a restart still running after 8 s is stuck (the time limits should have ended it).
        if restarting, Date().timeIntervalSince(restartStartedAt) > 8 {
            log("RESTART stuck for 8 s → abandoning it and trying again")
            restartGeneration += 1; restarting = false
            scheduleRestart("restart watchdog", after: 0.5)
        }
        let now = mach_absolute_time()
        let geometryQuietFor = Date().timeIntervalSince(targetGeometryChangedAt)
        let transitioning = geometryQuietFor < 1.5
        var reason: String?
        if !transitioning, clickAt != 0, machMilliseconds(now - clickAt) > 1500 {
            if lastArrival < clickAt { reason = "no new frame 1.5 s after a click in the window" }
            clickAt = 0
        }
        if reason == nil, !transitioning, profile == .active, let since = heldSince, Date().timeIntervalSince(since) > 6 {
            reason = "only unusable frames for 6 s while the window is in front and geometry is settled"
            heldSince = nil
        }
        guard let reason, Date().timeIntervalSince(lastStallRestart) > 10 else { return }
        lastStallRestart = Date()
        log("STALL: \(reason) → restarting capture")
        Task { await restartStream("stall: \(reason)") }
    }

    /// One configuration change at a time, and the newest one always wins.
    func submitConfiguration(_ config: SCStreamConfiguration, to stream: SCStream) {
        guard !configInFlight else { pendingConfig = config; return }
        configInFlight = true
        Task { @MainActor in
            do { try await stream.updateConfiguration(config) }
            catch { log("CONFIG update failed: \(error.localizedDescription)") }
            configInFlight = false
            if let next = pendingConfig, self.stream === stream {
                pendingConfig = nil
                submitConfiguration(next, to: stream)
            }
        }
    }

    // MARK: Adaptive capture (heat)

    /// Full-resolution capture at display rate costs about 1 GB/s of copying for a full-screen window, so
    /// capture quality follows what the user can actually see. Resolution stays full in every profile;
    /// only the frame rate changes.
    enum CaptureProfile: String {
        case active       // target app in front: full resolution, display refresh rate
        case background   // visible at full size, another app in front: full resolution, 15 fps
        case thumbnail    // shown shrunken (Stage Manager strip): full resolution, 4 fps
        case hidden       // minimized / other Space: full resolution, 1 fps
    }

    func desiredProfile(onScreen size: CGSize) -> CaptureProfile {
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == targetPID { return .active }
        if naturalSize.width > 0, size.width < naturalSize.width * 0.6 { return .thumbnail }
        return .background
    }

    func updateProfile(_ p: CaptureProfile, force: Bool = false) {
        guard force || p != profile else { return }
        profile = p
        if p == .active {
            offsetStart = nil
            // Blank frames while the window sat in the strip are normal; count only from now on.
            heldSince = nil
            // Going to full frame rate can't wait for the window to settle: the grow-out-of-the-strip
            // animation would play at thumbnail rate (4 fps). Only the frame rate changes here — the
            // resolution is already full in every profile — so this is one config change, not a flood.
            profileWork?.cancel(); profileWork = nil; profileScheduleGeneration += 1
            applyProfile()
            return
        }
        scheduleProfileApply(after: 0.18)
    }

    func scheduleProfileApply(after delay: TimeInterval) {
        profileWork?.cancel()
        profileScheduleGeneration += 1
        let generation = profileScheduleGeneration
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.profileScheduleGeneration == generation else { return }
                let now = Date()
                let quietFor = min(now.timeIntervalSince(self.targetGeometryChangedAt),
                                   now.timeIntervalSince(self.naturalSizeChangedAt))
                if quietFor < 0.5 {
                    self.scheduleProfileApply(after: 0.5 - quietFor)
                    return
                }
                self.profileWork = nil
                self.applyProfile()
            }
        }
        profileWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func fps(for p: CaptureProfile) -> Int {
        let hz = NSScreen.screens.map(\.maximumFramesPerSecond).max() ?? 60
        switch p {
        case .active: return max(60, hz)
        case .background: return 15
        case .thumbnail: return 4
        case .hidden: return 1
        }
    }

    func applyProfile() {
        guard let stream else { return }
        let base = naturalSize.width > 0 ? naturalSize : streamSize
        // Resolution stays full in every profile; only the frame rate changes. Cap the long edge at
        // 8192 px (ScreenCaptureKit's limit) by clamping the point size.
        let fps = fps(for: profile)
        let limit = 8192 / captureScale
        let size = CGSize(width: min(limit, base.width.rounded()), height: min(limit, base.height.rounded()))
        let config = streamConfig(size: size, scale: captureScale, fps: fps)
        streamSize = size
        // Usually only the frame rate changes now; skip a reconfiguration that changes nothing (each one is
        // a small capture hiccup).
        let key = "\(config.width)×\(config.height)@\(fps)·\(displayScale)x"
        guard key != appliedConfig else { return }
        appliedConfig = key
        logDetail("PROFILE \(profile.rawValue): config \(config.width)×\(config.height) px @ \(fps) fps, \(Int(displayScale))× display (window natural size \(naturalSize) pt)")
        submitConfiguration(config, to: stream)
    }
}
