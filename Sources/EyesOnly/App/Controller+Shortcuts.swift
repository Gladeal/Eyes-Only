import AppKit

@MainActor
extension Controller {
    // MARK: Pause (everything)

    /// Takes every cover off until resumed — ticked windows and tabs, apps and sites alike. The captures keep
    /// idling behind the scenes, so resuming puts everything back at once, exactly as it was.
    @objc func togglePause() {
        paused.toggle()
        diagnosticsLog(paused ? "PAUSED all protection" : "RESUMED all protection")
        heat(1.0)   // covers off / back on at the next screen frame
        updateStatusButton()
        rebuildMenuIfClosed()
    }

    // MARK: Shortcuts

    func registerShortcuts() {
        HotKeys.shared.set(ShortcutAction.allCases.compactMap { action in
            Settings.shortcut(action).map { (action.rawValue, $0, { [weak self] in self?.perform(action) }) }
        })
        for name in HotKeys.shared.failed { diagnosticsLog("SHORTCUT for \(name) not available: another app or macOS uses it") }
    }

    /// From Settings: save it, unless another action already has it.
    func setShortcut(_ action: ShortcutAction, _ shortcut: Shortcut?) -> Bool {
        if let shortcut, ShortcutAction.allCases.contains(where: { $0 != action && Settings.shortcut($0) == shortcut }) { return false }
        Settings.setShortcut(action, shortcut)
        diagnosticsLog("LAUNCH-SETTING shortcut for \(action.rawValue) \(shortcut?.display ?? "removed")")
        registerShortcuts()
        return true
    }

    func perform(_ action: ShortcutAction) {
        diagnosticsDetail("SHORTCUT \(action.rawValue)")
        switch action {
        case .pause: togglePause()
        case .protectWindow: toggleFrontWindow()
        case .protectTab: toggleFrontTab()
        case .openMenu: statusItem.button?.performClick(nil)
        case .stopAll: if hasManualProtection { unprotectTicked() } else { NSSound.beep() }
        }
    }

    /// The window you're using: the front app's frontmost real window.
    func frontWindow() -> WindowInfo? {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier, pid != getpid() else { return nil }
        return windowList([.optionOnScreenOnly, .excludeDesktopElements])?.first {
            $0.pid == pid && $0.layer == 0 && $0.alpha > 0 && $0.bounds.width >= 120 && $0.bounds.height >= 80
        }
    }

    func toggleFrontWindow() {
        guard let w = frontWindow() else { NSSound.beep(); return }
        toggleWindow(w.id, pid: w.pid)
    }

    /// The active tab of the front browser window — matched to the window on screen by position and size,
    /// like covers for protected tabs are.
    func toggleFrontTab() {
        guard let w = frontWindow(), let client = browsers.values.first(where: { $0.pid == w.pid }),
              let bw = tabWindowMap.first(where: { $0.value == w.id && $0.key.pid == w.pid }).flatMap({ m in client.windows.first { $0.id == m.key.id } })
                ?? client.windows.first(where: { b in
                    abs(b.bounds.minX - w.bounds.minX) < 6 && abs(b.bounds.minY - w.bounds.minY) < 6 &&
                    abs(b.bounds.width - w.bounds.width) < 6 && abs(b.bounds.height - w.bounds.height) < 6 }),
              let tab = bw.tabs.first(where: \.active) else { NSSound.beep(); return }
        let key = BrowserKey(pid: client.pid, id: tab.id)
        // Protected by a site rule: that stays (it's edited in Settings), so there's nothing to toggle here.
        guard protectedTabs.contains(key) || siteRule(for: tab) == nil else { NSSound.beep(); return }
        if protectedTabs.remove(key) == nil { protectedTabs.insert(key) }
        diagnosticsDetail("TAB \(key) \(protectedTabs.contains(key) ? "protected" : "unprotected") (shortcut)")
        reconcileTabs()
        rebuildMenuIfClosed()
    }
}
