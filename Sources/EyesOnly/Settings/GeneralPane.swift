import AppKit
import ServiceManagement

@MainActor
final class GeneralPane: NSObject {
    private(set) var view = NSStackView()
    private let openAtLogin = NSButton(checkboxWithTitle: "Open at login", target: nil, action: nil)
    private let keepOnTop = NSButton(checkboxWithTitle: "Always keep covers on top", target: nil, action: nil)
    private let livePreviews = NSButton(checkboxWithTitle: "Live previews in Stage Manager and Mission Control", target: nil, action: nil)
    private let diagnostics = NSButton(checkboxWithTitle: "Detailed diagnostics log", target: nil, action: nil)
    var isKeepOnTop: () -> Bool = { false }
    var setKeepOnTop: (Bool) -> Void = { _ in }
    var setLivePreviews: (Bool) -> Void = { _ in }

    override init() {
        super.init()
        openAtLogin.target = self; openAtLogin.action = #selector(openAtLoginChanged)
        keepOnTop.target = self; keepOnTop.action = #selector(changed)
        livePreviews.target = self; livePreviews.action = #selector(livePreviewsChanged)
        diagnostics.target = self; diagnostics.action = #selector(diagnosticsChanged)
        let showLog = sized(NSButton(title: "Show Log File", target: self, action: #selector(revealLog)), width: 140)
        let diagnosticsRow = sized(row([diagnostics, showLog]), width: contentWidth)
        diagnosticsRow.distribution = .fill
        diagnostics.setContentHuggingPriority(.defaultLow, for: .horizontal)   // stretches: Show Log File sits at the right

        let keepOnTopNote = note("Off (recommended): a protected window behaves like any other — other apps' windows can cover it while it's in the background.\nOn: protected windows' covers float above every other window, which leaves no moment where a covered window could rise above its cover.")
        let livePreviewsNote = note("Protected windows' Stage Manager thumbnails and Mission Control tiles look normal to you (a live capture of the screen there, never saved or sent anywhere); captures still show them black. Off: black for you too.")
        let livePreviewsWarning = note("⚠︎ Uses more CPU while a protected window is in the Stage Manager strip or Mission Control is open.", color: .systemOrange)
        let loginLine = separator(), diagnosticsLine = separator()
        view = column([
            openAtLogin, loginLine,
            keepOnTop, keepOnTopNote,
            livePreviews, livePreviewsNote, livePreviewsWarning,
            diagnosticsLine,
            diagnosticsRow,
            note("Records what the app does — app names, window sizes and events; never window titles, web addresses or anything on screen — to help find a problem. Turn it on, make the problem happen again, then click Show Log File and send that file."),
        ], spacing: 6)
        for v in [openAtLogin, loginLine, livePreviewsWarning, diagnosticsLine] { view.setCustomSpacing(16, after: v) }
        view.setCustomSpacing(24, after: keepOnTopNote)
        view.setCustomSpacing(10, after: livePreviewsNote)
    }
    func reload() {
        keepOnTop.state = isKeepOnTop() ? .on : .off
        livePreviews.state = Settings.livePreviews ? .on : .off
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
    @objc private func livePreviewsChanged() {
        Settings.livePreviews = livePreviews.state == .on; setLivePreviews(livePreviews.state == .on)
        diagnosticsLog("LAUNCH-SETTING live previews \(livePreviews.state == .on ? "on" : "off")")
    }
    @objc private func changed() { setKeepOnTop(keepOnTop.state == .on) }
}
