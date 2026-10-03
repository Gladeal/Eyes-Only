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
                exposures += 1
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

    /// Windows above this window's strip thumbnail are cut out of its cover: the cover floats (macOS won't keep
    /// it placed among Stage Manager's windows), and would otherwise sit on top of them. Only where the cut
    /// is safe for captures — what shows through must really be hiding the thumbnail there:
    ///  - real windows (larger than any strip thumbnail on a side) and Stage Manager's app icons; not the thumbnail-sized,
    ///    invisible windows apps keep parked in the strip;
    ///  - not while the strip slides in over a full-screen app (reported positions ≠ drawn ones), not in
    ///    Mission Control.
    func updateProxyHoles(_ o: Overlay, _ list: [WindowInfo]) {
        guard let owner, owner.thumbnailCutouts, let cover = o.proxyFrame, let thumb = previewWindowID, !owner.missionControlOpen, owner.stripSlide() == 0,
              let ti = list.firstIndex(where: { $0.id == thumb }) else {
            o.setProxyHoles([], includingMainCover: false); return
        }
        var holes: [Overlay.Hole] = []
        for w in list[..<ti] {   // front to back: everything before the thumbnail is above it
            guard !owner.ourWindowNumbers.contains(Int(w.id)), w.layer == 0, w.alpha > 0.9 else { continue }
            let b = w.bounds, r = cocoaRect(b)
            guard r.intersects(cover) else { continue }
            if w.owner == "WindowManager" {
                guard b.width >= 32, b.width <= 128, abs(b.width - b.height) < 2 else { continue }   // an app icon
                // The icon window is 64 pt, but the icon in it is only ~38 pt (drawn at 48 pt, and macOS icons
                // keep a transparent margin inside that). Cut just the visible icon — a little inside it — so
                // nothing of the thumbnail shows around it.
                let icon = r.insetBy(dx: r.width * 0.21, dy: r.height * 0.21)
                holes.append(.init(rect: icon, radius: icon.width * 0.225))
            } else if b.width > Controller.stripThumbnailMax || b.height > Controller.stripThumbnailMax {
                // Rounded generously: the hole's corners must stay inside the window's own rounded corners.
                holes.append(.init(rect: r, radius: 26))
            }
        }
        if holes != o.proxyHoles, !holes.isEmpty || !o.proxyHoles.isEmpty {
            logDetail("PROXY holes: \(holes.count) (\(holes.map { "\(Int($0.rect.width))×\(Int($0.rect.height))" }.joined(separator: ", ")))")
        }
        // The main cover shows a thumbnail (black locally, no live copy) — cut it the same way.
        o.setProxyHoles(holes, includingMainCover: !o.copyVisible || o.mainHidden)
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

    func logExposureIfAny() {
        guard exposedSince != 0 else { return }
        exposures += 1
        log(String(format: "EXPOSED: protected window was above the black box for ≥ %.1f ms (exposure #%d)",
                   machMilliseconds(mach_absolute_time() - exposedSince), exposures))
        exposedSince = 0
    }
}
