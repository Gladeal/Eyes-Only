import AppKit
import ServiceManagement

@MainActor
final class GeneralPane: NSObject {
    private(set) var view = NSStackView()
    private let openAtLogin = NSButton(checkboxWithTitle: "Open at login", target: nil, action: nil)
    private let keepOnTop = NSButton(checkboxWithTitle: "Always keep covers on top", target: nil, action: nil)
    private let diagnostics = NSButton(checkboxWithTitle: "Detailed diagnostics log", target: nil, action: nil)
    private let cutouts = NSButton(checkboxWithTitle: "Let windows show through Stage Manager thumbnail covers (experimental)", target: nil, action: nil)
    var isKeepOnTop: () -> Bool = { false }
    var setKeepOnTop: (Bool) -> Void = { _ in }
    var setCutouts: (Bool) -> Void = { _ in }

    override init() {
        super.init()
        openAtLogin.target = self; openAtLogin.action = #selector(openAtLoginChanged)
        keepOnTop.target = self; keepOnTop.action = #selector(changed)
        cutouts.target = self; cutouts.action = #selector(cutoutsChanged)
        diagnostics.target = self; diagnostics.action = #selector(diagnosticsChanged)
        let showLog = sized(NSButton(title: "Show Log File", target: self, action: #selector(revealLog)), width: 140)
        let diagnosticsRow = sized(row([diagnostics, showLog]), width: contentWidth)
        diagnosticsRow.distribution = .fill
        diagnostics.setContentHuggingPriority(.defaultLow, for: .horizontal)   // stretches: Show Log File sits at the right

        let keepOnTopNote = note("Off (recommended): a protected window behaves like any other — other apps' windows can cover it while it's in the background.\nOn: protected windows' covers float above every other window, which leaves no moment where a covered window could rise above its cover.")
        let cutoutsNote = note("A protected app's black cover in the Stage Manager strip floats above other windows. With this on, windows that overlap the strip cut through it, like they do with the other thumbnails.")
        let cutoutsWarning = note("⚠︎ Uses more CPU while a protected window is in the strip.", color: .systemOrange)
        let loginLine = separator(), diagnosticsLine = separator()
        view = column([
            openAtLogin, loginLine,
            keepOnTop, keepOnTopNote,
            cutouts, cutoutsNote, cutoutsWarning,
            diagnosticsLine,
            diagnosticsRow,
            note("Records what the app does — app names, window sizes and events; never window titles, web addresses or anything on screen — to help find a problem. Turn it on, make the problem happen again, then click Show Log File and send that file."),
        ], spacing: 6)
        for v in [openAtLogin, loginLine, cutoutsWarning, diagnosticsLine] { view.setCustomSpacing(16, after: v) }
        view.setCustomSpacing(24, after: keepOnTopNote)
        view.setCustomSpacing(10, after: cutoutsNote)
    }
    func reload() {
        keepOnTop.state = isKeepOnTop() ? .on : .off
        cutouts.state = Settings.thumbnailCutouts ? .on : .off
        diagnostics.state = fullDiagnostics ? .on : .off
        openAtLogin.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }
    /// A standard login item (System Settings → General → Login Items lists it).
    @objc private func openAtLoginChanged() {
        do {
            if openAtLogin.state == .on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            diagnosticsLog("LAUNCH-SETTING open at login \(openAtLogin.state == .on ? "on" : "off")")
        } catch {
            diagnosticsLog("Could not change open-at-login: \(error.localizedDescription)")
            openAtLogin.state = SMAppService.mainApp.status == .enabled ? .on : .off
        }
    }
    @objc private func diagnosticsChanged() {
        fullDiagnostics = diagnostics.state == .on
        UserDefaults.standard.set(fullDiagnostics, forKey: "diagnostics")
        diagnosticsLog("LAUNCH-SETTING detailed diagnostics \(fullDiagnostics ? "on" : "off")")
    }
    @objc private func revealLog() {
        if !FileManager.default.fileExists(atPath: logURL.path) { diagnosticsLog("LAUNCH-SETTING log opened") }
        NSWorkspace.shared.activateFileViewerSelecting([logURL])
    }
    @objc private func cutoutsChanged() { Settings.thumbnailCutouts = cutouts.state == .on; setCutouts(cutouts.state == .on) }
    @objc private func changed() { setKeepOnTop(keepOnTop.state == .on) }
}
