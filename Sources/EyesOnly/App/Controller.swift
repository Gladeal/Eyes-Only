import AppKit
import ScreenCaptureKit
import QuartzCore

// Controller: menu-bar app, many sessions, one shared tick

@MainActor
final class Controller: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem!
    let menu = NSMenu()
    var sessions: [CGWindowID: Session] = [:]
    var candidates: [SCWindow] = []
    var keepOnTop = false
    var menuOpen = false
    var iconCache: [pid_t: NSImage] = [:]   // menu-size app icons
    // Browser tabs
    let bridge = BrowserBridge()
    var browsers: [Int32: BrowserClient] = [:]
    var protectedTabs: Set<BrowserKey> = []      // tabs ticked in the menu
    var pendingTabWindows: Set<CGWindowID> = []  // tab-driven sessions being created
    /// Browser window → the window on screen. Matched by position + size once, then kept while
    /// that window exists: during a resize the browser's and the system's sizes briefly disagree, and
    /// re-matching then lost the window and restarted its capture on every resize.
    var tabWindowMap: [BrowserKey: CGWindowID] = [:]
    var siteRules = Settings.sites
    var captureOnlyActiveTab = Settings.captureOnlyActiveTab
    var livePreviews = Settings.livePreviews
    /// Capture handles of browser windows whose capture was stopped (active-tab-only mode): restarting with
    /// one skips the window lookup, so the picture comes back sooner.
    var captureHandles: [CGWindowID: SCWindow] = [:]
    lazy var settings: SettingsWindow = {
        let w = SettingsWindow()
        w.general.isKeepOnTop = { [weak self] in self?.keepOnTop ?? false }
        w.general.setKeepOnTop = { [weak self] on in self?.setKeepOnTop(on) }
        w.general.setLivePreviews = { [weak self] on in self?.livePreviews = on }
        w.apps.ticked = { [weak self] in self?.autoApps ?? [] }
        w.apps.setTicked = { [weak self] id, on in self?.setAutoApp(id, on) }
        w.sites.onChange = { [weak self] in
            guard let self else { return }
            self.siteRules = Settings.sites
            self.reconcileTabs(); self.rebuildMenuIfClosed()
        }
        w.sites.onActiveOnlyChange = { [weak self] on in
            guard let self else { return }
            self.captureOnlyActiveTab = on
            self.reconcileTabs()
        }
        w.shortcuts.setShortcut = { [weak self] action, s in self?.setShortcut(action, s) ?? false }
        w.shortcuts.recording = { [weak self] on in if on { HotKeys.shared.removeAll() } else { self?.registerShortcuts() } }
        w.shortcuts.failed = { HotKeys.shared.failed }
        w.browser.connected = { [weak self] in self?.browsers.values.filter { $0.pid != 0 }.map(\.name).sorted() ?? [] }
        return w
    }()
    // Always-protected apps
    var autoApps = Set(Settings.apps)
    var autoDismissed: Set<CGWindowID> = []      // auto-protected windows you unticked by hand
    var pendingAutoWindows: Set<CGWindowID> = []
    var autoTimer: Timer?
    var autoPIDs: Set<pid_t>?                    // nil = recompute
    /// Every cover off for now (menu: Pause Protection, or its shortcut). Back on at every launch.
    var paused = false
    var lastList: [WindowInfo] = []
    var lastListAt = Date.distantPast
    var pauseWork: [CGWindowID: DispatchWorkItem] = [:]
    var lastMenuTick = Date.distantPast
    var refreshing = false
    var refreshScheduled = false
    var hasPermission = CGPreflightScreenCaptureAccess()

    var tickTimer: Timer?
    var activity: NSObjectProtocol?
    var clickMonitor: Any?
    var lastProcStats = Date()
    var lastCPUSeconds = 0.0

    // System state shared by every session, read once per tick.
    var missionControlOpen = false
    // Stage Manager strip revealed from the left edge inside another app's full-screen Space. There the
    // strip's windows keep reporting their parked off-screen position (x ≈ −271) while macOS draws them
    // slid in, so the covers follow the same slide themselves.
    var fullScreenStripRevealed = false
    var lastMissionControlOpen = false
    var stripSlideFrom: CGFloat = 0, stripSlideTo: CGFloat = 0
    var stripSlideStart = Date.distantPast
    var lastPreviewInventoryLogAt = Date.distantPast
    var lastPreviewSurfaceInventory = ""
    var lastStackOrder: [CGWindowID] = []
    // Tick rate: 120 Hz while anything can be moving (mouse pressed/dragging, mouse at the left edge, app or
    // Space switch, any movement seen), 10 Hz otherwise. Each tick reads the full window list from
    // WindowServer — at 120 Hz around the clock that was most of the app's CPU (and WindowServer's).
    // "Full rate" is the display's own refresh (a display link, one tick per screen frame): ticks between
    // frames can never be seen, and on a 60 Hz display a fixed 120 Hz timer wasted half of them.
    static let idleRate = 10.0
    var displayLink: CADisplayLink?
    var hotRate: Double { Double(NSScreen.screens.map(\.maximumFramesPerSecond).max() ?? 60) }
    var hotUntil = Date.distantPast
    var tickHot = false
    var busyFrame = 0
    var workspaceObservers: [NSObjectProtocol] = []
    /// Every overlay window of every session: none of them is ever a Stage Manager preview.
    var ourWindowNumbers: Set<Int> = []

    // MARK: Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if SHIP
        if offerMoveToApplications() { return }   // relaunching from Applications
        #endif
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical], reason: "Following protected windows")
        installNativeHosts()
        ExtensionFolder.install()
        // No visible main menu in a menu-bar app, but its key equivalents make ⌘C / ⌘V / ⌘A work in our windows.
        let main = NSMenu(), editItem = NSMenuItem(), edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        editItem.submenu = edit; main.addItem(editItem); NSApp.mainMenu = main
        updateAutoTimer()
        bridge.onMessage = { [weak self] fd, msg in MainActor.assumeIsolated { self?.browserMessage(fd, msg) } }
        bridge.onDisconnect = { [weak self] fd in MainActor.assumeIsolated { self?.browserGone(fd) } }
        bridge.start()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        menu.delegate = self
        statusItem.menu = menu
        updateStatusButton()
        rebuildMenu()
        registerShortcuts()
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification,
                     NSWorkspace.didWakeNotification, NSWorkspace.didHideApplicationNotification,
                     NSWorkspace.didUnhideApplicationNotification] {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.heat(2.0) }
            })
        }
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification,
                     NSWorkspace.didUnhideApplicationNotification] {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleRefresh(); self?.checkAutoApps() }
            })
        }
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                let pid = app?.processIdentifier, id = app?.bundleIdentifier
                let launched = note.name == NSWorkspace.didLaunchApplicationNotification
                MainActor.assumeIsolated {
                    guard let self, let pid, self.autoPIDs != nil else { return }
                    if !launched { self.autoPIDs?.remove(pid) }
                    else if let id, self.autoApps.contains(id) { self.autoPIDs?.insert(pid) }
                }
            })
        }
        // Float a protected app's covers the moment it becomes active.
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil,
                                                     queue: .main) { [weak self] note in
            let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            MainActor.assumeIsolated {
                guard let self, let pid else { return }
                for s in self.sessions.values where s.targetPID == pid { s.appActivated() }
            }
        })
        #if !SHIP
        // Development builds (testing): cover a window the moment its Space becomes active.
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil,
                                                     queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.sessions.values.forEach { $0.spaceChanged() } }
        })
        #endif
        workspaceObservers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                         object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.heat(2.0)
                self?.sessions.values.forEach { $0.applyProfile() }   // a new display may need a bigger buffer
            }
        })
        diagnosticsLog("LAUNCH menu-bar app")
        if CGPreflightScreenCaptureAccess() {
            Task { await refresh() }
        } else {
            _ = CGRequestScreenCaptureAccess()
            diagnosticsLog("No Screen Recording permission yet. Allow Eyes Only in System Settings → Privacy & Security → Screen & System Audio Recording, then quit and reopen it.")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        sessions.values.forEach { $0.stop() }
        sessions.removeAll()
    }

    /// Opened from outside Applications (Downloads, the disk image, …): offer to move there, like most Mac apps.
    /// From Applications, macOS keeps the Screen Recording permission reliably (a downloaded app run in place
    /// is moved to a random read-only location by macOS each launch), and it's in Launchpad and Spotlight.
    /// Returns true when it moved itself and is relaunching from there.
    func offerMoveToApplications() -> Bool {
        let fm = FileManager.default
        let here = Bundle.main.bundleURL
        let path = here.path
        let homeApps = fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path
        guard !path.hasPrefix("/Applications/"), !path.hasPrefix(homeApps + "/"),
              !UserDefaults.standard.bool(forKey: "dontOfferMoveToApplications") else { return false }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Move Eyes Only to your Applications folder?"
        alert.informativeText = "It works best from there: macOS keeps its Screen Recording permission, and you'll find it in Launchpad and Spotlight."
        alert.addButton(withTitle: "Move to Applications")
        alert.addButton(withTitle: "Not Now")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't ask again"
        let answer = alert.runModal()
        if alert.suppressionButton?.state == .on { UserDefaults.standard.set(true, forKey: "dontOfferMoveToApplications") }
        guard answer == .alertFirstButtonReturn else { return false }
        for folder in ["/Applications", homeApps] {
            let dest = URL(fileURLWithPath: folder).appendingPathComponent(here.lastPathComponent)
            do {
                try fm.createDirectory(atPath: folder, withIntermediateDirectories: true)
                if fm.fileExists(atPath: dest.path) {
                    // An older copy: quit it if it's running, then move it to the Trash.
                    NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
                        .filter { $0.bundleURL?.standardizedFileURL == dest.standardizedFileURL }.forEach { $0.terminate() }
                    try fm.trashItem(at: dest, resultingItemURL: nil)
                }
                try fm.copyItem(at: here, to: dest)
                let x = Process(); x.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
                x.arguments = ["-dr", "com.apple.quarantine", dest.path]
                try? x.run(); x.waitUntilExit()
                // The copy we ran from: to the Trash too, unless macOS ran it from a temporary read-only spot.
                if !path.contains("/AppTranslocation/") { try? fm.trashItem(at: here, resultingItemURL: nil) }
                let config = NSWorkspace.OpenConfiguration(); config.createsNewApplicationInstance = true
                NSWorkspace.shared.openApplication(at: dest, configuration: config) { _, _ in
                    DispatchQueue.main.async { NSApp.terminate(nil) }
                }
                return true
            } catch {
                diagnosticsLog("Could not move to \(folder): \(error.localizedDescription)")
            }
        }
        let fail = NSAlert()
        fail.messageText = "Couldn't move Eyes Only"
        fail.informativeText = "Drag it into your Applications folder yourself, then open it from there."
        fail.runModal()
        return false
    }
}
