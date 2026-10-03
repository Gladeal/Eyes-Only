import AppKit
import ScreenCaptureKit

@MainActor
extension Controller {
    // MARK: Always-protected apps
    func setAutoApp(_ id: String, _ on: Bool) {
        if on {
            autoApps.insert(id)
            diagnosticsLog("AUTO protect app \(id)")
        } else {
            autoApps.remove(id)
            diagnosticsLog("AUTO stop protecting app \(id)")
            let pids = Set(NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == id }.map(\.processIdentifier))
            for (wid, s) in sessions where s.autoApp && pids.contains(s.targetPID) { s.stop(); sessions[wid] = nil }
            sessionsChanged()
        }
        Settings.apps = Array(autoApps).sorted()
        recomputeAutoPIDs()
        updateAutoTimer()
        checkAutoApps()
        rebuildMenuIfClosed()
    }

    /// New windows of always-protected apps are picked up within a second (at once when an app launches or
    /// comes to the front). One cheap on-screen window list per second, only while some app is ticked.
    func updateAutoTimer() {
        if autoApps.isEmpty { autoTimer?.invalidate(); autoTimer = nil; return }
        guard autoTimer == nil else { return }
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.checkAutoApps() } }
        t.tolerance = 0.2
        RunLoop.main.add(t, forMode: .common)
        autoTimer = t
    }

    /// Processes of always-protected apps, kept up to date from launch/quit notifications. Asking every running
    /// app for its bundle identifier each second was a Launch Services round trip per app — most of the idle cost.
    func recomputeAutoPIDs() {
        autoPIDs = Set(NSWorkspace.shared.runningApplications.filter { autoApps.contains($0.bundleIdentifier ?? "") }.map(\.processIdentifier))
    }

    func checkAutoApps() {
        guard !autoApps.isEmpty, !autoPaused else { return }
        if autoPIDs == nil { recomputeAutoPIDs() }
        guard let pids = autoPIDs, !pids.isEmpty else { return }
        // The tick's own window list when it's fresh; a request of our own only when nothing else is running.
        guard let list = Date().timeIntervalSince(lastListAt) < 0.5 ? lastList
                       : windowList([.optionOnScreenOnly, .excludeDesktopElements]) else { return }
        let live = Set(list.map(\.id))
        autoDismissed = autoDismissed.filter { live.contains($0) || windowInfo($0) != nil }
        for w in list {
            guard pids.contains(w.pid), w.layer == 0, w.alpha > 0, w.bounds.width >= 120, w.bounds.height >= 80 else { continue }
            let id = w.id
            guard sessions[id] == nil, !autoDismissed.contains(id), !pendingAutoWindows.contains(id) else { continue }
            startAutoSession(id)
        }
    }

    func startAutoSession(_ id: CGWindowID) {
        pendingAutoWindows.insert(id)
        Task {
            defer { pendingAutoWindows.remove(id) }
            guard let content = try? await withTimeout(4, { try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false) }),
                  let w = content.windows.first(where: { $0.windowID == id }), sessions[id] == nil else { return }
            let s = Session(window: w, owner: self)
            s.autoApp = true
            s.keepOnTop = keepOnTop
            sessions[id] = s
            sessionsChanged()
            s.log("AUTO protecting a new window of an always-protected app")
            if await !s.start(), sessions[id] === s {
                sessions[id] = nil
                sessionsChanged()
            }
        }
    }

    /// Everything ticked by hand in the menu — windows and tabs. Apps and sites from Settings stay protected.
    @objc func unprotectTicked() {
        for (id, s) in sessions where !s.tabDriven && !s.autoApp { s.stop(); sessions[id] = nil }
        protectedTabs.removeAll()
        diagnosticsLog("STOP. Unprotected all ticked windows and tabs")
        sessionsChanged()
        reconcileTabs()   // tab windows still needed for site rules stay; the rest stop
    }

    /// Apps and sites from Settings, off or back on — the lists themselves are kept.
    @objc func toggleAutoPause() {
        autoPaused.toggle()
        diagnosticsLog(autoPaused ? "AUTO protection paused" : "AUTO protection resumed")
        if autoPaused {
            for (id, s) in sessions where s.autoApp { s.stop(); sessions[id] = nil }
            sessionsChanged()
        } else {
            checkAutoApps()
        }
        reconcileTabs()
        rebuildMenu()
    }

    var hasManualProtection: Bool { sessions.values.contains { !$0.tabDriven && !$0.autoApp } || !protectedTabs.isEmpty }
    var hasAutoRules: Bool { !autoApps.isEmpty || !siteRules.isEmpty }

    func setKeepOnTop(_ on: Bool) {
        guard on != keepOnTop else { return }
        keepOnTop.toggle()
        sessions.values.forEach { $0.setKeepOnTop(keepOnTop) }
        rebuildMenu()
    }

    /// A session's window closed: drop it.
    func sessionEnded(_ s: Session) {
        s.logDetail("The protected window closed. Protection stopped.")
        s.stop()
        if sessions[s.windowID] === s { sessions[s.windowID] = nil }
        sessionsChanged()
    }

    func sessionsChanged() {
        lastStackOrder = []
        updateStatusButton()
        rebuildMenu()
        if sessions.isEmpty { removeMouseMonitors() } else { installMouseMonitors() }
        if sessions.isEmpty {
            tickTimer?.invalidate(); tickTimer = nil
            displayLink?.invalidate(); displayLink = nil
            tickHot = false
        } else if tickTimer == nil {
            heat(2.0)   // a new cover: start at full rate
        }
    }
}
