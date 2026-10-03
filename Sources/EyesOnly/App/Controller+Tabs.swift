import AppKit

@MainActor
extension Controller {
    // MARK: Browser tabs

    func browserMessage(_ fd: Int32, _ msg: [String: Any]) {
        let client = browsers[fd] ?? { let c = BrowserClient(); browsers[fd] = c; return c }()
        switch msg["type"] as? String {
        case "hello":
            client.pid = pid_t(msg["pid"] as? Int ?? 0)
            client.name = NSRunningApplication(processIdentifier: client.pid)?.localizedName ?? "Browser"
            diagnosticsLog("BROWSER connected: \(client.name) (pid \(client.pid))")
            bridge.send(fd, ["type": "refresh"])
            rebuildMenuIfClosed()
        case "state":
            let windows = (msg["windows"] as? [[String: Any]]) ?? []
            client.windows = windows.compactMap { w in
                guard let id = w["id"] as? Int else { return nil }
                let r = CGRect(x: w["left"] as? Double ?? 0, y: w["top"] as? Double ?? 0,
                               width: w["width"] as? Double ?? 0, height: w["height"] as? Double ?? 0)
                let tabs = ((w["tabs"] as? [[String: Any]]) ?? []).compactMap { t -> BrowserTab? in
                    guard let id = t["id"] as? Int else { return nil }
                    return BrowserTab(id: id, title: t["title"] as? String ?? "", url: t["url"] as? String ?? "", active: t["active"] as? Bool ?? false)
                }
                return BrowserWindow(id: id, bounds: r, state: w["state"] as? String ?? "normal", tabs: tabs)
            }
            // Tabs that closed can't come back (ids aren't reused): forget them.
            let alive = Set(browsers.values.flatMap { c in c.windows.flatMap { w in w.tabs.map { BrowserKey(pid: c.pid, id: $0.id) } } })
            protectedTabs = protectedTabs.filter { key in alive.contains(key) || key.pid != client.pid }
            reconcileTabs()
        default:
            break
        }
    }

    func browserGone(_ fd: Int32) {
        guard let c = browsers.removeValue(forKey: fd) else { return }
        diagnosticsLog("BROWSER disconnected: \(c.name)")
        protectedTabs = protectedTabs.filter { $0.pid != c.pid }
        reconcileTabs()
        rebuildMenuIfClosed()
    }

    func rebuildMenuIfClosed() { if !menuOpen { rebuildMenu() } }

    /// Which browser windows need a cover, and whether it shows right now (their active tab is protected).
    func reconcileTabs() {
        var desired: [CGWindowID: Bool] = [:]
        for c in browsers.values where c.pid != 0 {
            let mine = c.windows.filter { watchWindow(c, $0) }
            guard !mine.isEmpty else { continue }
            let onScreen = (windowList([.optionAll, .excludeDesktopElements]) ?? []).filter { $0.pid == c.pid && $0.layer == 0 }
            let existing = Set(onScreen.map(\.id))
            for w in mine {
                let mapKey = BrowserKey(pid: c.pid, id: w.id)
                var cgID = tabWindowMap[mapKey].flatMap { existing.contains($0) ? $0 : nil }
                if cgID == nil {
                    // The extension reports bounds in screen points with a top-left origin — CoreGraphics' space.
                    let taken = Set(tabWindowMap.values)
                    cgID = onScreen.first(where: { info in
                        let b = info.bounds
                        return !taken.contains(info.id) &&
                               abs(b.minX - w.bounds.minX) < 6 && abs(b.minY - w.bounds.minY) < 6 &&
                               abs(b.width - w.bounds.width) < 6 && abs(b.height - w.bounds.height) < 6
                    })?.id
                    if let cgID { tabWindowMap[mapKey] = cgID }
                }
                guard let cgID else { continue }
                let active = w.tabs.first(where: \.active)
                desired[cgID] = active.map { tabProtected(c.pid, $0) } ?? false
            }
        }
        for (id, show) in desired {
            if let s = sessions[id] {
                guard s.tabDriven else { continue }   // the whole window is protected anyway
                if show {
                    pauseWork.removeValue(forKey: id)?.cancel()
                    s.setSuspended(false)
                } else if pauseWork[id] == nil, !s.suspended || captureOnlyActiveTab {
                    // Lift the cover a moment after the switch, once the protected tab has been painted over —
                    // and in active-tab-only mode stop the capture altogether.
                    let work = DispatchWorkItem { [weak self, weak s] in
                        MainActor.assumeIsolated {
                            guard let self, let s else { return }
                            self.pauseWork[id] = nil
                            if self.captureOnlyActiveTab, self.sessions[id] === s {
                                if let h = s.captureWindow { self.captureHandles[id] = h }
                                s.logDetail("TAB: active tab not protected → capture stopped (active-tab-only)")
                                s.stop(); self.sessions[id] = nil; self.sessionsChanged()
                            } else {
                                s.setSuspended(true)
                            }
                        }
                    }
                    pauseWork[id] = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
                }
            } else if !pendingTabWindows.contains(id), show || !captureOnlyActiveTab {
                startTabSession(id, showing: show)
            }
        }
        // Keep sessions whose browser window still has a protected tab, even if this round couldn't place it.
        var keep = Set(desired.keys)
        for c in browsers.values where c.pid != 0 {
            for w in c.windows where watchWindow(c, w) {
                if let id = tabWindowMap[BrowserKey(pid: c.pid, id: w.id)] { keep.insert(id) }
            }
        }
        let liveKeys = Set(browsers.values.flatMap { c in c.windows.map { BrowserKey(pid: c.pid, id: $0.id) } })
        tabWindowMap = tabWindowMap.filter { liveKeys.contains($0.key) }
        captureHandles = captureHandles.filter { keep.contains($0.key) }
        defer { updateStatusButton() }   // tabs that became (un)protected change the count
        var changed = false
        for (id, s) in sessions where s.tabDriven && !keep.contains(id) {
            pauseWork.removeValue(forKey: id)?.cancel()
            s.stop(); sessions[id] = nil; changed = true
        }
        if changed { sessionsChanged() }
    }

    /// Site rules in effect (none while auto-protection is paused).
    var activeSiteRules: [String] { autoPaused ? [] : siteRules }

    func tabProtected(_ pid: pid_t, _ t: BrowserTab) -> Bool {
        protectedTabs.contains(BrowserKey(pid: pid, id: t.id)) || activeSiteRules.contains { siteMatches(t.url, $0) }
    }

    func siteRule(for t: BrowserTab) -> String? { activeSiteRules.first { siteMatches(t.url, $0) } }

    /// Browser windows that get captured: only those with a protected tab (ticked, or on a protected site) —
    /// paused while another tab is active. Nothing else in the browser is ever captured.
    func watchWindow(_ c: BrowserClient, _ w: BrowserWindow) -> Bool {
        w.tabs.contains { tabProtected(c.pid, $0) }
    }

    func startTabSession(_ id: CGWindowID, showing: Bool) {
        guard sessions[id] == nil else { return }
        let browser = browsers.values.first { c in tabWindowMap.contains { $0.value == id && $0.key.pid == c.pid } }
        pendingTabWindows.insert(id)
        Task {
            defer { pendingTabWindows.remove(id) }
            // No ScreenCaptureKit lookup first: the cover goes up immediately when a protected tab is active,
            // and the capture starts behind it.
            let s = captureHandles.removeValue(forKey: id).map { Session(window: $0, owner: self) }
                ?? Session(windowID: id, pid: browser?.pid ?? 0, name: "\(browser?.name ?? "Browser") — tab", owner: self)
            s.tabDriven = true
            s.keepOnTop = keepOnTop
            s.setSuspended(!showing)
            sessions[id] = s
            sessionsChanged()
            if await !s.start(), sessions[id] === s {
                sessions[id] = nil
                sessionsChanged()
            }
            reconcileTabs()   // tabs may have switched while it was starting
        }
    }

    func addBrowserTabItems() {
        guard !browsers.isEmpty else { return }
        for c in browsers.values.sorted(by: { $0.name < $1.name }) where c.pid != 0 {
            let count = c.windows.reduce(0) { n, w in n + w.tabs.filter { tabProtected(c.pid, $0) }.count }
            let parent = NSMenuItem(title: "\(c.name) tabs" + (count > 0 ? "  (\(count) protected)" : ""), action: nil, keyEquivalent: "")
            parent.image = appIcon(pid: c.pid)
            let sub = NSMenu()
            for (i, w) in c.windows.enumerated() {
                if i > 0 { sub.addItem(.separator()) }
                for t in w.tabs {
                    var label = t.title.isEmpty ? t.url : t.title
                    if label.count > 60 { label = String(label.prefix(59)) + "…" }
                    let item = NSMenuItem(title: label, action: #selector(toggleTab(_:)), keyEquivalent: "")
                    item.target = self
                    let key = BrowserKey(pid: c.pid, id: t.id)
                    item.representedObject = key
                    let rule = protectedTabs.contains(key) ? nil : siteRule(for: t)
                    if let rule { item.title = label + "   — site: \(rule)" }
                    item.state = tabProtected(c.pid, t) ? .on : .off
                    item.toolTip = rule == nil ? t.url : "\(t.url)\nProtected by the site rule “\(rule!)”. Edit it in Protected Sites…"
                    if rule == nil, let host = URLComponents(string: t.url)?.host, !host.isEmpty, t.url.hasPrefix("http") {
                        // ⌥: protect the whole site instead of just this tab
                        let alt = NSMenuItem(title: "Always protect \(host)", action: #selector(protectSite(_:)), keyEquivalent: "")
                        alt.target = self; alt.representedObject = host
                        alt.keyEquivalentModifierMask = .option; alt.isAlternate = true
                        sub.addItem(item); sub.addItem(alt)
                        continue
                    }
                    sub.addItem(item)
                }
            }
            if sub.items.isEmpty { sub.addItem(withTitle: "(no tabs)", action: nil, keyEquivalent: "").isEnabled = false }
            parent.submenu = sub
            menu.addItem(parent)
        }
    }

    @objc func protectSite(_ sender: NSMenuItem) {
        guard let host = sender.representedObject as? String else { return }
        settings.sites.addSite(host)
        settings.show(.browser)
    }

    @objc func toggleTab(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? BrowserKey else { return }
        // A tab protected by a site rule stays protected; the rule is edited in Protected Sites.
        if !protectedTabs.contains(key), let t = browsers.values.first(where: { $0.pid == key.pid })?
            .windows.lazy.flatMap(\.tabs).first(where: { $0.id == key.id }), siteRule(for: t) != nil {
            settings.show(.browser); return
        }
        if protectedTabs.remove(key) == nil { protectedTabs.insert(key) }
        diagnosticsDetail("TAB \(key) \(protectedTabs.contains(key) ? "protected" : "unprotected")")
        reconcileTabs()
        rebuildMenu()
    }
}
