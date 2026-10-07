import AppKit
import ScreenCaptureKit

@MainActor
extension Controller {
    // MARK: Status item + menu

    /// What's really protected: whole windows, and tabs that are protected right now. Not the paused captures
    /// kept ready for browser windows (for site rules), which cover nothing until a protected tab is active.
    var protectedCounts: (windows: Int, tabs: Int) {
        let windows = sessions.values.filter { !$0.tabDriven }.count
        let tabs = browsers.values.reduce(0) { n, c in n + c.windows.reduce(0) { m, w in m + w.tabs.filter { tabProtected(c.pid, $0) }.count } }
        return (windows, tabs)
    }

    var protectedSummary: String {
        let (w, t) = protectedCounts
        var parts: [String] = []
        if w > 0 { parts.append("\(w) window\(w == 1 ? "" : "s")") }
        if t > 0 { parts.append("\(t) tab\(t == 1 ? "" : "s")") }
        return parts.isEmpty ? "Nothing protected" : "Protecting " + parts.joined(separator: " and ")
    }

    func updateStatusButton() {
        guard let button = statusItem.button else { return }
        let (w, t) = protectedCounts
        let n = w + t
        button.image = NSImage(systemSymbolName: n > 0 ? "eye.slash.fill" : "eye", accessibilityDescription: "Eyes Only")
        button.image?.isTemplate = true
        button.title = n > 0 ? " \(n)" : ""
        #if !SHIP
        // Development build: marked in the menu bar, so it's never mistaken for the shared one.
        button.attributedTitle = NSAttributedString(string: " DEV" + button.title, attributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: .bold), .foregroundColor: NSColor.systemOrange,
            .baselineOffset: 1])
        #endif
        button.imagePosition = .imageLeading
        button.toolTip = n > 0 ? protectedSummary : "Eyes Only — nothing protected"
    }

    // The menu opens instantly from the window list kept fresh in the background (app switches, launches,
    // quits, Space changes, each menu open). Asking ScreenCaptureKit for the list takes a moment, and
    // rebuilding the menu while it's open (as it used to, on every open) made it stall.
    func menuNeedsUpdate(_ menu: NSMenu) { rebuildMenu() }
    func menuWillOpen(_ menu: NSMenu) { menuOpen = true; scheduleRefresh(after: 0) }
    func menuDidClose(_ menu: NSMenu) { menuOpen = false }

    /// Coalesces bursts of triggers into one window-list refresh.
    func scheduleRefresh(after delay: TimeInterval = 0.4) {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.refreshScheduled = false
                Task { await self.refresh() }
            }
        }
    }

    func rebuildMenu() {
        menu.removeAllItems()
        #if !SHIP
        let build = NSMenuItem(title: "Development build · \(Self.buildDate)", action: nil, keyEquivalent: "")
        build.isEnabled = false
        menu.addItem(build)
        #endif
        let header = NSMenuItem(title: protectedSummary, action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        if autoPaused {
            let paused = NSMenuItem(title: "Auto-protection paused", action: nil, keyEquivalent: "")
            paused.isEnabled = false
            menu.addItem(paused)
        }
        if !hasPermission {
            let p = NSMenuItem(title: "Needs Screen Recording permission (System Settings → Privacy & Security)", action: nil, keyEquivalent: "")
            p.isEnabled = false
            menu.addItem(p)
        }
        menu.addItem(.separator())
        let sorted = candidates.sorted {
            ($0.owningApplication?.applicationName ?? "").localizedCaseInsensitiveCompare($1.owningApplication?.applicationName ?? "") == .orderedAscending
        }
        if sorted.isEmpty {
            let empty = NSMenuItem(title: "  (no windows — open one, then reopen this menu)", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        // Just the app's name — not what its window shows. Several windows of one app: "Code", "Code (2)", …
        var seen: [String: Int] = [:]
        for w in sorted {
            let app = w.owningApplication?.applicationName ?? "?"
            seen[app, default: 0] += 1
            let label = seen[app]! == 1 ? app : "\(app) (\(seen[app]!))"
            let item = NSMenuItem(title: label, action: #selector(toggleWindow(_:)), keyEquivalent: "")
            item.image = appIcon(pid: w.owningApplication?.processID)
            // The window's own title only on hover, not in the menu itself.
            if let title = w.title, !title.isEmpty { item.toolTip = title }
            item.target = self
            item.representedObject = NSNumber(value: w.windowID)
            item.state = sessions[w.windowID].map { !$0.tabDriven } == true ? .on : .off
            menu.addItem(item)
        }
        // Protected windows that dropped out of the list (e.g. on another Space) stay listed so they can be stopped.
        for (id, s) in sessions where !s.tabDriven && !sorted.contains(where: { $0.windowID == id }) {
            let app = s.targetName.components(separatedBy: " — ").first ?? s.targetName
            let item = NSMenuItem(title: app, action: #selector(toggleWindow(_:)), keyEquivalent: "")
            item.image = appIcon(pid: s.targetPID)
            if let title = s.targetName.components(separatedBy: " — ").dropFirst().joined(separator: " — ").nilIfEmpty { item.toolTip = title }
            item.target = self
            item.representedObject = NSNumber(value: id)
            item.state = .on
            menu.addItem(item)
        }
        if !browsers.isEmpty {
            menu.addItem(.separator())
            addBrowserTabItems()
        }
        menu.addItem(.separator())
        // macOS's own symbols, as its apps use them — every item in this group has one, so they line up.
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self
        settingsItem.image = symbol("gear")   // the gear Apple's menu uses for System Settings…
        menu.addItem(settingsItem)
        if hasManualProtection { add("Stop All", #selector(unprotectTicked)).image = symbol("stop.circle") }
        if hasAutoRules {
            let pause = add(autoPaused ? "Resume Auto-Protection" : "Pause Auto-Protection", #selector(toggleAutoPause))
            pause.image = symbol(autoPaused ? "play.circle" : "pause.circle")
            pause.toolTip = "The apps and sites you set to always protect in Settings. Your lists are kept."
        }
        let quit = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        quit.image = symbol("xmark.rectangle")   // the symbol macOS gives Quit
        menu.addItem(quit)
    }

    #if !SHIP
    /// When this build was made (the build number is its date and time: yyyyMMddHHmm).
    static let buildDate: String = {
        let raw = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        let parse = DateFormatter(); parse.dateFormat = "yyyyMMddHHmm"
        guard let date = parse.date(from: raw) else { return raw }
        return "built " + date.formatted(date: .abbreviated, time: .shortened)
    }()
    #endif

    func symbol(_ name: String) -> NSImage? { NSImage(systemSymbolName: name, accessibilityDescription: nil) }

    /// The app's icon at menu size, cached per app (the menu is rebuilt often).
    func appIcon(pid: pid_t?) -> NSImage? {
        guard let pid else { return nil }
        if let cached = iconCache[pid] { return cached }
        guard let icon = NSRunningApplication(processIdentifier: pid)?.icon?.copy() as? NSImage else { return nil }
        icon.size = NSSize(width: 16, height: 16)
        iconCache[pid] = icon
        return icon
    }

    @discardableResult
    func add(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return item
    }

    // MARK: Picking windows

    func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        hasPermission = CGPreflightScreenCaptureAccess()
        let before = menuSignature()
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            let me = getpid()
            // Only real, normal app windows (windowLayer == 0). macOS's own surfaces — Stage Manager
            // overlays, Dock, Control Center, wallpaper, backstop, the gesture-blocking overlay —
            // live on other layers or these system apps and are never offered.
            let system: Set<String> = ["com.apple.WindowManager", "com.apple.dock", "com.apple.controlcenter",
                                       "com.apple.notificationcenterui", "com.apple.Spotlight", "com.apple.systemuiserver",
                                       "com.apple.wallpaper.agent", "com.apple.loginwindow"]
            candidates = content.windows.filter {
                $0.windowLayer == 0 && $0.frame.width >= 120 && $0.frame.height >= 80 &&
                $0.owningApplication?.processID != me &&
                !system.contains($0.owningApplication?.bundleIdentifier ?? "")
            }
        } catch {
            diagnosticsLog("Could not list windows: \(error.localizedDescription). Check Screen Recording permission.")
        }
        // Rebuild only when something shown changed. An open menu is rebuilt only for a window that appeared or
        // went away (not a title change — rebuilding resets the highlight under the pointer); otherwise the
        // change shows the next time it opens.
        let after = menuSignature()
        guard after != before else { return }
        if !menuOpen || windowSet(before) != windowSet(after) { rebuildMenu() }
    }

    private func windowSet(_ signature: String) -> Set<Substring> {
        Set(signature.split(separator: "|").dropFirst().map { $0.prefix(while: { $0 != ":" }) })
    }

    /// What the menu shows, minus per-session status text (that changes every couple of seconds).
    func menuSignature() -> String {
        "\(hasPermission)|" + candidates.map { "\($0.windowID):\($0.owningApplication?.applicationName ?? ""):\($0.title ?? "")" }.sorted().joined(separator: "|")
    }

    @objc func toggleWindow(_ sender: NSMenuItem) {
        guard let id = (sender.representedObject as? NSNumber)?.uint32Value else { return }
        if let s = sessions[id], s.tabDriven {
            s.tabDriven = false   // now the whole window is protected, whatever tab is active
            s.setSuspended(false)
            pauseWork.removeValue(forKey: id)?.cancel()
            sessionsChanged()
        } else if let s = sessions[id] {
            if s.autoApp { autoDismissed.insert(id) }   // you unticked it: leave this window alone
            s.stop()
            sessions[id] = nil
            sessionsChanged()
            reconcileTabs()       // it may still have protected tabs
        } else if let w = candidates.first(where: { $0.windowID == id }) {
            let s = Session(window: w, owner: self)
            s.keepOnTop = keepOnTop
            sessions[id] = s
            sessionsChanged()
            Task {
                if await !s.start(), sessions[id] === s {
                    sessions[id] = nil
                    sessionsChanged()
                }
            }
        }
    }

    @objc func showSettings() { settings.show() }
    @objc func quit() { NSApp.terminate(nil) }
}

private extension String { var nilIfEmpty: String? { isEmpty ? nil : self } }
