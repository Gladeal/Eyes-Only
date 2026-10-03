import AppKit

@MainActor
extension Session {
    // MARK: Tick — follow the window's position + stacking (content is separate, in receive)

    func tick(list: [WindowInfo]) {
        let tickStart = mach_absolute_time()
        guard running, let owner else { return }
        let id = windowID, o = overlay
        let missionControlOpen = owner.missionControlOpen
        checkForStall()
        // From the tick's own window list; ask WindowServer separately only when the window isn't on screen
        // (to tell "closed" from "hidden / other Space").
        guard let state = list.window(id) ?? windowInfo(id) else {
            owner.sessionEnded(self); return
        }
        if suspended {   // a browser window whose active tab isn't protected
            if o.visible { o.hide() }
            if o.proxyFrame != nil { o.placeProxy(nil) }
            updateProfile(.hidden)
            return
        }
        // Refresh the separate Stage Manager surface before checking target visibility; WindowServer
        // can omit the target while the preview is already animating into view.
        updateStageManagerPreview(o, id, list)
        updateProxyHoles(o, list)
        if o.aboveSystemUI != missionControlOpen {
            o.aboveSystemUI = missionControlOpen
            if o.visible { o.backing.orderFrontRegardless(); o.mirror.orderFrontRegardless() }
            logDetail(missionControlOpen ? "MISSION CONTROL open → cover above Dock level, black locally" : "MISSION CONTROL closed → normal cover level")
        }
        guard state.onScreen else {
            // The window itself is reported off screen, but Stage Manager may still show its preview.
            if let pid = previewWindowID, let ps = list.window(pid) {
                if !o.mainHidden { o.setMainHidden(true); logDetail("HIDE window reported off screen; keeping its Stage Manager preview (win \(pid)) covered") }
                if !o.keepOnTop { o.keepOnTop = true; o.backing.orderFrontRegardless(); o.mirror.orderFrontRegardless() }
                o.show(above: id)
                o.placeProxy(cocoaRect(owner.slidIn(ps.bounds)))
                updateProfile(.hidden)
                return
            }
            if o.visible { logDetail("HIDE target not on screen (minimized / other Space)") }
            o.hide()
            updateProfile(.hidden)
            return
        }
        if o.mainHidden { o.setMainHidden(false) }
        let f = cocoaRect(state.bounds)
        if f != o.frame {
            owner.heat(1.0)   // moving / animating: track at full rate
            placeCount += 1; lastPlace = Date(); targetGeometryChangedAt = lastPlace
            // A click can be followed by several seconds of offset frames during a Stage Manager
            // transition. It is not evidence of a dead stream; let the settled-window stall check decide.
            clickAt = 0
        }
        else if placeCount > 0, Date().timeIntervalSince(lastPlace) > 0.3 {
            logDetail("MOVED \(placeCount) steps, settled at \(f.size) pt")
            placeCount = 0
        }
        if !o.visible { logDetail("SHOW") }
        let screenScale = NSScreen.screens.first(where: { $0.frame.contains(NSPoint(x: f.midX, y: f.midY)) })?.backingScaleFactor ?? displayScale
        if screenScale != displayScale {
            displayScale = screenScale
            logDetail("DISPLAY now \(Int(screenScale))× → capture density follows")
            applyProfile()
        }
        o.place(f)
        o.show(above: id)
        // Show the copy only where the window is readable: in front (including while it grows out of the
        // strip) or at full size in the background. A Stage Manager thumbnail or Mission Control tile stays
        // black locally as well. Never stretch a held frame to more than twice its size: at first focus the
        // only frame is the strip thumbnail, and blown up to the full window it looked broken.
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier == targetPID
        let shrunk = naturalSize.width > 0 && f.width < naturalSize.width * 0.9
        let copyVisible = !missionControlOpen && (front || !shrunk) && o.shownContentWidth * 2 >= f.width
        if copyVisible != o.copyVisible {
            o.setCopyVisible(copyVisible)
            logDetail(String(format: "COPY %@ (front %@, window %.0f pt wide, frame %.0f pt wide%@)", copyVisible ? "shown" : "black locally",
                       front ? "yes" : "no", f.width, o.shownContentWidth, missionControlOpen ? ", Mission Control" : ""))
        }
        if !keepOnTop, !o.aboveSystemUI { autoStack(o, above: id) }
        ensureCoverOnScreen(o, list)
        updateProfile(desiredProfile(onScreen: f.size))
        let elapsed = Date().timeIntervalSince(lastStatsTime)
        if elapsed >= 2 {
            let fps = Double(frameCount) / elapsed
            let age = frameCount > 0 ? frameAgeTotal / Double(frameCount) : 0
            let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
            let dropped = sink?.takeDroppedCount() ?? 0
            let line = String(format: "mirror %.0f fps · profile %@ · frame age avg %.1f / max %.0f ms · longest gap %.0f ms · dropped %d · main-thread tick max %.1f ms · window %.0f×%.0f pt · front: %@",
                              fps, profile.rawValue, age, frameAgeMax, frameGapMax, dropped, tickMax, f.width, f.height, front)
            logDetail("STATS " + line + (frameCount == 0 ? " · NO NEW FRAMES" : ""))
            frameCount = 0; frameAgeTotal = 0; frameAgeMax = 0; frameGapMax = 0; tickMax = 0; lastStatsTime = Date()
        }
        tickMax = max(tickMax, machMilliseconds(mach_absolute_time() - tickStart))
    }
}
