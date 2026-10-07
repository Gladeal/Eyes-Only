import AppKit

/// What a shortcut can do.
enum ShortcutAction: String, CaseIterable {
    case pause, protectWindow, protectTab, openMenu, stopAll

    var title: String {
        switch self {
        case .pause: "Pause / resume all protection"
        case .protectWindow: "Protect / unprotect the front window"
        case .protectTab: "Protect / unprotect the front browser tab"
        case .openMenu: "Open the Eyes Only menu"
        case .stopAll: "Stop All (windows and tabs you ticked)"
        }
    }
}

@MainActor
final class ShortcutsPane: NSObject {
    private(set) var view = NSStackView()
    /// Save a shortcut (nil removes it). Returns false when it's refused (already used for another action).
    var setShortcut: (ShortcutAction, Shortcut?) -> Bool = { _, _ in true }
    /// While a shortcut is being typed, the existing ones are off (so typing one records it instead of running it).
    var recording: (Bool) -> Void = { _ in }
    /// Actions whose shortcut another app or macOS already has.
    var failed: () -> Set<String> = { [] }
    private var recorders: [ShortcutAction: ShortcutRecorder] = [:]
    private var warnings: [ShortcutAction: NSTextField] = [:]

    override init() {
        super.init()
        var rows: [NSView] = []
        for action in ShortcutAction.allCases {
            let recorder = ShortcutRecorder()
            recorder.onChange = { [weak self] s in
                guard let self else { return false }
                let ok = self.setShortcut(action, s)
                DispatchQueue.main.async { self.reload() }   // after it's registered: show whether it worked
                return ok
            }
            recorder.onRecording = { [weak self] on in self?.recording(on) }
            recorders[action] = recorder
            let warning = label("", size: 11, width: 300)
            warning.textColor = .systemOrange
            warnings[action] = warning
            let title = label(action.title, width: 300)
            rows.append(sized(row([sized(column([title, warning], spacing: 2), width: 320), recorder]), width: contentWidth))
        }
        view = column(rows + [
            separator(),
            label("Shortcuts work in every app. Click a shortcut, then press the keys — at least one of ⌘ ⌥ ⌃ (or a function key on its own). Delete removes it, Esc cancels.", size: 12),
        ], spacing: 14)
    }

    func reload() {
        let failed = failed()
        for action in ShortcutAction.allCases {
            recorders[action]?.shortcut = Settings.shortcut(action)
            warnings[action]?.stringValue = failed.contains(action.rawValue) ? "⚠︎ Another app or macOS already uses this — pick another." : ""
        }
    }
}

/// A button that shows a shortcut; click it and press keys to change it.
@MainActor
final class ShortcutRecorder: NSButton {
    var shortcut: Shortcut? { didSet { refresh() } }
    var onChange: (Shortcut?) -> Bool = { _ in true }
    var onRecording: (Bool) -> Void = { _ in }
    private var monitor: Any?

    init() {
        super.init(frame: .zero)
        bezelStyle = .rounded
        target = self; action = #selector(clicked)
        widthAnchor.constraint(equalToConstant: 170).isActive = true
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func clicked() { monitor == nil ? start() : stop() }

    private func start() {
        title = "Press keys…"
        onRecording(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.record(event)
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        onRecording(false)
        refresh()
    }

    private func record(_ event: NSEvent) {
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if event.keyCode == 53, mods.isEmpty { stop(); return }                              // Esc: cancel
        if [51, 117].contains(event.keyCode), mods.isEmpty {                                  // Delete: remove
            if onChange(nil) { shortcut = nil }
            stop(); return
        }
        // A plain letter would fire while typing anywhere: a modifier is needed, except for function keys.
        guard !mods.intersection([.command, .option, .control]).isEmpty || Shortcut.functionKeys[event.keyCode] != nil else {
            NSSound.beep(); return
        }
        let s = Shortcut(event)
        if onChange(s) { shortcut = s } else { NSSound.beep() }
        stop()
    }

    private func refresh() {
        guard monitor == nil else { return }
        title = shortcut?.display ?? "Record Shortcut"
    }
}
