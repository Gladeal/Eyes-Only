import AppKit

@MainActor
extension Session {
    // MARK: Stacking

    /// Automatic stacking (checkbox off). Keep-on-top whenever the window is in front, in the strip, or
    /// hidden; only while it's a full-size background window, sit directly above it so other apps can
    /// cover it. If macOS won't hold that placement, fall back to keep-on-top for a few seconds instead
    /// of re-ordering over and over (that churn exposed the window and caused lag).
    func autoStack(_ o: Overlay, above id: CGWindowID) {
        let now = Date()
        // Full-size in the background, or a thumbnail in the Stage Manager strip: sit in the window stack, so
        // whatever covers the window (or the strip) covers the cover too. Floating there put the strip's
        // black box above other apps' windows.
        // In the strip the cover floats: macOS doesn't keep it placed among Stage Manager's windows (it ends up
        // above other apps' windows anyway). Windows above the thumbnail are cut out of it instead.
        let wantDirectlyAbove = profile == .background && now >= stackFallbackUntil
        if !wantDirectlyAbove {
            guard !o.keepOnTop else { return }
            if o.stackState(above: id, targetPID: targetPID).exposed {
                noteExposure()
                log("EXPOSED: protected window rose above the black box (≤ one check, ~16 ms) before keep-on-top took over (exposure #\(exposures))")
            }
            exposedSince = 0
            o.keepOnTop = true
            o.backing.orderFrontRegardless(); o.mirror.orderFrontRegardless()
            logDetail("STACK keep on top (\(profile.rawValue))")
            return
        }
        if o.keepOnTop {
            o.keepOnTop = false
            o.orderDirectlyAbove(id, force: true)
            stackAttemptAt = now; stackRetried = false
            if windowInfo(CGWindowID(o.backing.windowNumber))?.onScreen != true {
                stackFallbackUntil = now.addingTimeInterval(10)
                o.keepOnTop = true
                o.backing.orderFrontRegardless(); o.mirror.orderFrontRegardless()
                log("STACK directly above failed (cover not on screen) → keep on top for 10 s")
                return
            }
            logDetail("STACK directly above the protected window")
            return
        }
        // The order check is its own WindowServer query; 4 times a second is enough to notice it didn't hold.
        guard now.timeIntervalSince(lastStackCheck) >= 0.25 else { return }
        lastStackCheck = now
        let (inOrder, exposed, detail) = o.stackState(above: id, targetPID: targetPID)
        if exposed && exposedSince == 0 { exposedSince = mach_absolute_time() }
        if inOrder {
            logExposureIfAny()
            stackRetried = false
            return
        }
        guard now.timeIntervalSince(stackAttemptAt) > 0.3 else { return }
        if !stackRetried {
            o.orderDirectlyAbove(id)
            stackAttemptAt = now; stackRetried = true
            return
        }
        stackFallbackUntil = now.addingTimeInterval(5)
        o.keepOnTop = true
        o.backing.orderFrontRegardless(); o.mirror.orderFrontRegardless()
        logExposureIfAny()
        logDetail("STACK order didn't hold → keep on top for 5 s (exposed: \(exposed); nearest above the window: \(detail))")
    }

    /// Stage Manager draws its strip preview of an app in its own WindowManager window, placed directly
    /// above the app's window. That preview isn't where the app's own window is reported, so the main
    /// cover missed it and captures showed the preview. Cover it too while the window isn't in front.
    func updateStageManagerPreview(_ o: Overlay, _ id: CGWindowID, _ list: [WindowInfo]) {
        guard let owner else { return }
        // Every session's cover windows (and the app's own), not just this one's: another protected
        // window's cover can sit directly above this window too.
        let ours = owner.ourWindowNumbers
        if Date().timeIntervalSince(lastPreviewInventoryLogAt) >= 1 {
            lastPreviewInventoryLogAt = Date()
            let ts = windowInfo(id)
            let idx = list.firstIndex(where: { $0.id == id })
            logDetail("DIAG target win \(id) onScreen=\(ts?.onScreen ?? false) bounds=\(ts.map { "\($0.bounds)" } ?? "nil") listIndex=\(idx.map(String.init) ?? "notInList") screens=\(NSScreen.screens.map { $0.frame })")
        }
        guard let ti = list.firstIndex(where: { $0.id == id }) else {
            if let cached = previewWindowID, let state = list.window(cached) {
                let rect = cocoaRect(owner.slidIn(state.bounds))
                if rect != o.proxyFrame { o.placeProxy(rect) }
            }
            return
        }
        let targetBounds = list[ti].bounds
        // Nearest window above the protected one (the list is front to back), skipping ours and slivers.
        var j = ti - 1
        while j >= 0, ours.contains(Int(list[j].id)) || list[j].bounds.width < 100 || list[j].bounds.height < 80 { j -= 1 }
        var preview: (id: CGWindowID, rect: CGRect, how: String)?
        if j >= 0, list[j].owner == "WindowManager", list[j].layer == 0 {
            let b = list[j].bounds
            if b.width <= targetBounds.width * 1.05, b.height <= targetBounds.height * 1.05,
               b.width >= targetBounds.width * 0.08, b.height >= targetBounds.height * 0.08,
               Controller.previewShaped(b, target: targetBounds) {
                preview = (list[j].id, b, "directly above")
            }
        }
        if preview == nil, let same = list.first(where: { w in
            let b = w.bounds
            return w.owner == "WindowManager" && w.layer == 0 &&
                   abs(b.minX - targetBounds.minX) < 2 && abs(b.minY - targetBounds.minY) < 2 &&
                   abs(b.width - targetBounds.width) < 2 && abs(b.height - targetBounds.height) < 2 }) {
            preview = (same.id, same.bounds, "same place")
        }
        if preview == nil, NSWorkspace.shared.frontmostApplication?.processIdentifier == targetPID {
            if o.proxyFrame != nil { o.placeProxy(nil); logDetail("PROXY cleared (target active; no Stage Manager surface)") }
            previewWindowID = nil; previewMissSince = nil
            return
        }
        if let preview {
            previewWindowID = preview.id
            previewMissSince = nil
        } else if previewWindowID != nil {
            if previewMissSince == nil { previewMissSince = Date() }
            guard Date().timeIntervalSince(previewMissSince!) > 0.75 else { return }
            previewWindowID = nil; previewMissSince = nil
        }
        let rect = preview.map { cocoaRect($0.rect) }
        if rect != o.proxyFrame {
            owner.heat(1.0)
            if let preview {
                logDetail(String(format: "PROXY Stage Manager preview win %u %@ at (%.0f,%.0f %.0f×%.0f); window reported at (%.0f,%.0f %.0f×%.0f)",
                           preview.id, preview.how, preview.rect.minX, preview.rect.minY, preview.rect.width, preview.rect.height,
                           targetBounds.minX, targetBounds.minY, targetBounds.width, targetBounds.height))
            } else if o.proxyFrame != nil {
                logDetail("PROXY none found")
            }
            o.placeProxy(rect)
        }
    }

    /// Safety net: the black backing must really be on screen whenever the window is protected.
    func ensureCoverOnScreen(_ o: Overlay, _ list: [WindowInfo]) {
        // From the tick's own (on-screen) window list — no extra WindowServer round trip.
        guard Date().timeIntervalSince(lastCoverCheck) >= 0.25,
              Date().timeIntervalSince(o.lastOrderedAt) >= 0.5 else { return }   // list may not show a fresh order yet
        lastCoverCheck = Date()
        guard o.visible, list.window(CGWindowID(o.backing.windowNumber)) == nil else {
            coverMissingSince = nil
            return
        }
        if coverMissingSince == nil { coverMissingSince = Date() }
        stackFallbackUntil = Date().addingTimeInterval(10)
        o.keepOnTop = true
        o.backing.orderFrontRegardless(); o.mirror.orderFrontRegardless()
        log("COVER missing (black window not on screen; profile \(profile.rawValue)) → restored on top")
    }

    /// The protected app just became active, so macOS has raised its windows — float the cover now instead of
    /// at the next check (waiting for it let the window show above its cover on most switches). Checks for an
    /// exposure first, like the tick would.
    func appActivated() {
        let o = overlay
        guard running, !keepOnTop, o.visible, !o.keepOnTop else { return }
        if o.stackState(above: windowID, targetPID: targetPID).exposed {
            noteExposure()
            log("EXPOSED: protected window rose above the black box before the activation reaction (exposure #\(exposures))")
        }
        exposedSince = 0
        stackFallbackUntil = Date().addingTimeInterval(1)   // the tick still sees the old profile for a moment
        o.keepOnTop = true
        o.backing.orderFrontRegardless(); o.mirror.orderFrontRegardless()
        logDetail("STACK keep on top (app activated — immediate)")
    }

    #if !SHIP
    /// Development builds (testing): the active Space changed. If the window is on screen here, put its cover
    /// up now, floating, instead of at the next check. Logs which came first — the window or the announcement.
    func spaceChanged() {
        let o = overlay
        guard running, !suspended, !paused, let state = windowInfo(windowID) else { return }
        let coverAgo = o.visible ? String(format: "cover already up for %.0f ms", Date().timeIntervalSince(shownAt) * 1000) : "cover not up"
        guard state.onScreen else { logDetail("SPACE switched: window not on this Space (\(coverAgo))"); return }
        if !o.visible {
            noteExposure()
            log("EXPOSED: window on screen before its cover at the Space switch announcement (exposure #\(exposures))")
        }
        logDetail("SPACE switched: window on screen, \(coverAgo) → cover up at once, floating")
        if !keepOnTop { stackFallbackUntil = Date().addingTimeInterval(1); o.keepOnTop = true }
        o.place(cocoaRect(state.bounds))
        if o.visible { o.backing.orderFrontRegardless(); o.mirror.orderFrontRegardless() } else { o.show(above: windowID); shownAt = Date() }
    }
    #endif

    private func noteExposure() {
        exposures += 1
        #if !SHIP
        NSSound(named: "Tink")?.play()   // development builds: hear the moment it happens
        #endif
    }

    func logExposureIfAny() {
        guard exposedSince != 0 else { return }
        noteExposure()
        log(String(format: "EXPOSED: protected window was above the black box for ≥ %.1f ms (exposure #%d)",
                   machMilliseconds(mach_absolute_time() - exposedSince), exposures))
        exposedSince = 0
    }
}
