import AppKit
import QuartzCore

@MainActor
extension Controller {
    /// System-wide mouse monitors exist only while something is protected: with one installed, macOS routes
    /// mouse events to this app too, which made our own menu lag behind the pointer. No `.mouseMoved` at all —
    /// the tick checks the pointer position itself (free) for the left-edge strip reveal.
    func installMouseMonitors() {
        guard clickMonitor == nil else { return }
        // Presses and drags start window moves, resizes and Stage Manager switches; also the stall check's click.
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp,
                                                                    .rightMouseDown, .otherMouseDown]) { [weak self] e in
            MainActor.assumeIsolated {
                guard let self, !self.sessions.isEmpty else { return }
                if e.type == .leftMouseDown || e.type == .rightMouseDown { self.sessions.values.forEach { $0.noteClick() } }
                self.heat(1.5)
            }
        }
    }

    func removeMouseMonitors() {
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
    }

    /// Pointer touching the left edge (reveals the strip), or over the strip while a protected window's
    /// thumbnail is in it (hover grows it) — what makes Stage Manager animate without a click.
    func pointerNearStrip() -> Bool {
        let m = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(m, $0.frame, false) }) else { return false }
        let x = m.x - screen.frame.minX
        return x < 8 || (x < 300 && sessions.values.contains(where: { $0.inStrip }))
    }

    /// Track at full rate for at least `seconds` from now.
    func heat(_ seconds: TimeInterval) {
        hotUntil = max(hotUntil, Date().addingTimeInterval(seconds))
        if !tickHot || (tickTimer == nil && displayLink == nil) { setTickRate(hot: true) }
    }

    func setTickRate(hot: Bool) {
        guard !sessions.isEmpty else { return }
        tickHot = hot
        tickTimer?.invalidate(); tickTimer = nil
        displayLink?.invalidate(); displayLink = nil
        if hot {
            // The fastest display drives it (ProMotion: up to 120 Hz; built-in Air / most externals: 60 Hz).
            let screen = NSScreen.screens.max(by: { $0.maximumFramesPerSecond < $1.maximumFramesPerSecond }) ?? NSScreen.main
            if let link = screen?.displayLink(target: self, selector: #selector(displayTick(_:))) {
                link.add(to: .main, forMode: .common)
                displayLink = link
                return
            }
        }
        let t = Timer(timeInterval: 1.0 / (hot ? hotRate : Self.idleRate), repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        t.tolerance = hot ? 0.001 : 0.01
        RunLoop.main.add(t, forMode: .common)
        tickTimer = t
    }

    @objc func displayTick(_ link: CADisplayLink) { tick() }

    // MARK: Shared tick

    func tick() {
        guard !sessions.isEmpty else { return }
        // An open menu is drawn on this (main) thread; each tick waits on WindowServer, which made the menu
        // lag behind the pointer. While you're in our menu nothing of yours is moving: track 4× a second.
        if menuOpen {
            guard Date().timeIntervalSince(lastMenuTick) >= 0.25 else { return }
            lastMenuTick = Date()
        }
        // While busy, the full window list (one expensive WindowServer round trip — nearly all of this app's
        // CPU) is read on every other screen frame; in between, each cover just follows its window.
        if pointerNearStrip() { heat(1.0) }
        busyFrame &+= 1
        if tickHot, busyFrame % 2 == 1 {
            for s in Array(sessions.values) { s.follow() }
            if Date() >= hotUntil { setTickRate(hot: false) }
            return
        }
        guard let list = windowList([.optionOnScreenOnly]) else { return }
        func isDock(_ w: WindowInfo, layer: Int) -> Bool {
            w.owner == "Dock" && w.layer == layer && w.bounds.width >= 600 && w.bounds.height >= 400
        }
        // Mission Control (and App Exposé) add a full-display Dock window at level 18 (plus level-17 tiles and
        // level-20 layers). A lone full-display level-20 Dock window is NOT Mission Control: the Dock shows it
        // at the start of Space switches / gestures and for the strip reveal in a full-screen app's Space.
        missionControlOpen = list.contains { isDock($0, layer: 18) }
        // In a full-screen Space, the Dock shows a lone full-display level-20 window while the strip is revealed.
        let revealed = !missionControlOpen && list.contains { isDock($0, layer: 20) }
        if revealed != fullScreenStripRevealed {
            fullScreenStripRevealed = revealed
            stripSlideFrom = stripSlide(); stripSlideTo = revealed ? Self.stripSlideDistance : 0
            stripSlideStart = Date()
            diagnosticsDetail(revealed ? "STRIP revealed (full-screen Space) → covers slide in with it" : "STRIP hidden (full-screen Space) → covers slide out")
            heat(1.0)   // the slide is animated
        }
        if missionControlOpen != lastMissionControlOpen {
            lastMissionControlOpen = missionControlOpen
            heat(1.5)
        }
        // Window numbers are read here, each tick, so they're valid even for covers created this run loop.
        ourWindowNumbers = Set(sessions.values.flatMap { [$0.overlay.backing.windowNumber, $0.overlay.mirror.windowNumber] })
        logSystemSurfaces(list)
        restackCovers(list)
        lastList = list; lastListAt = Date()
        for s in Array(sessions.values) { s.tick(list: list) }
        if tickHot, Date() >= hotUntil { setTickRate(hot: false) }
        if Date().timeIntervalSince(lastProcStats) >= 2 {
            let elapsed = Date().timeIntervalSince(lastProcStats)
            let cpu = processCPUSeconds()
            let pct = lastCPUSeconds > 0 ? 100 * (cpu - lastCPUSeconds) / elapsed : 0
            lastCPUSeconds = cpu; lastProcStats = Date()
            diagnosticsDetail(String(format: "PROC protecting %d · CPU %.0f%% · memory %.0f MB · heat %@ · tick %.0f Hz", sessions.count, pct, footprintMB(), thermalName(), tickHot ? hotRate : Self.idleRate))
        }
    }

    /// Covers of several protected windows stack in the same order as the windows themselves, so where two
    /// protected windows overlap, the front one's copy is on top. Re-ordered only when that order changes.
    func restackCovers(_ list: [WindowInfo]) {
        guard sessions.count > 1 else { return }
        let order = list.map(\.id).filter { sessions[$0] != nil }
        guard order != lastStackOrder else { return }
        lastStackOrder = order
        for id in order.reversed() {   // back to front
            guard let s = sessions[id], s.overlay.visible, s.overlay.keepOnTop else { continue }
            s.overlay.backing.orderFrontRegardless(); s.overlay.mirror.orderFrontRegardless()
        }
    }

    func logSystemSurfaces(_ list: [WindowInfo]) {
        guard Date().timeIntervalSince(lastPreviewInventoryLogAt) >= 1 else { return }
        lastPreviewInventoryLogAt = Date()
        let inventory = list.filter {
            ($0.owner == "WindowManager" || $0.owner == "Dock") && $0.bounds.width >= 40 && $0.bounds.height >= 40
        }.prefix(40).map { w -> String in
            let r = w.bounds
            return "\(w.id):\(w.owner)/L\(w.layer)@(\(Int(r.minX)),\(Int(r.minY)) \(Int(r.width))×\(Int(r.height)))"
        }.joined(separator: "  ")
        if inventory != lastPreviewSurfaceInventory {
            lastPreviewSurfaceInventory = inventory
            diagnosticsDetail("SYSTEM PREVIEW SURFACES: \(inventory.isEmpty ? "none" : inventory)")
        }
    }

    /// A Stage Manager preview of the window is either a strip-sized thumbnail (hovered ones reach ~270 pt) or
    /// sits exactly where the window is (grow / shrink animations). macOS's window-snapping preview — the
    /// half-screen outline shown while dragging toward an edge — is another WindowManager window directly
    /// above the dragged one, but it's neither, and covering it turned the snap outline black.
    static func previewShaped(_ r: CGRect, target t: CGRect) -> Bool {
        let sameAsWindow = abs(r.minX - t.minX) < 4 && abs(r.minY - t.minY) < 4 && abs(r.width - t.width) < 4 && abs(r.height - t.height) < 4
        return sameAsWindow || (r.width <= stripThumbnailMax && r.height <= stripThumbnailMax)
    }

    /// No Stage Manager strip thumbnail is larger than this on either side, in points; real windows usually are.
    static let stripThumbnailMax: CGFloat = 450

    /// How far Stage Manager slides its strip in from the parked position: −271 → 16 (measured).
    static let stripSlideDistance: CGFloat = 287

    /// Current slide offset, following macOS's own ease-out slide (~0.45 s, measured on the desktop strip).
    func stripSlide() -> CGFloat {
        let p = min(1, max(0, Date().timeIntervalSince(stripSlideStart) / 0.45))
        let eased = 1 - pow(1 - p, 3)
        return stripSlideFrom + (stripSlideTo - stripSlideFrom) * CGFloat(eased)
    }

    /// Where a strip thumbnail really is on screen: parked thumbnails (off the left edge) are drawn slid in
    /// while the strip is revealed in a full-screen Space. Anything already on screen is reported correctly.
    func slidIn(_ cg: CGRect) -> CGRect {
        guard cg.minX < -100 else { return cg }   // parked: x ≈ −271
        let dx = stripSlide()
        return dx > 0 ? cg.offsetBy(dx: dx, dy: 0) : cg
    }
}
