import AppKit

@MainActor
final class BrowserPane: NSObject {
    private(set) var view = NSStackView()
    private let status = NSTextField(labelWithString: "")
    private let picker = NSPopUpButton()
    private var browsers: [(name: String, bundleID: String, page: String)] = []
    private var timer: Timer?
    var connected: () -> [String] = { [] }

    override init() {
        super.init()
        status.font = .systemFont(ofSize: 12, weight: .semibold)
        for (name, id, page) in [("Google Chrome", "com.google.Chrome", "chrome://extensions"), ("Microsoft Edge", "com.microsoft.edgemac", "edge://extensions"),
                                 ("Brave", "com.brave.Browser", "brave://extensions"), ("Arc", "company.thebrowser.Browser", "chrome://extensions"),
                                 ("Vivaldi", "com.vivaldi.Vivaldi", "vivaldi://extensions"), ("Chromium", "org.chromium.Chromium", "chrome://extensions")]
            where NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) != nil {
            browsers.append((name, id, page))
        }
        picker.addItems(withTitles: browsers.isEmpty ? ["No Chromium browser found"] : browsers.map(\.name))
        let open = NSButton(title: "Open Extensions Page", target: self, action: #selector(openPage))
        open.isEnabled = !browsers.isEmpty

        let intro = label("Needed to protect tabs and sites in Chrome, Edge, Brave, Arc, Vivaldi or Chromium. It only tells this app which tabs are open — no buttons of its own, nothing sent over the network.", size: 12)
        intro.textColor = .secondaryLabelColor
        let steps = label("""
        1.  Open your browser's Extensions page and turn on Developer mode (top right).
        2.  Show the extension folder and drag it onto that page — or click Load unpacked there and choose it.
        3.  "Eyes Only" appears in the list; your tabs show up in the menu-bar menu.
        """, size: 12)
        view = column([
            label("Browser extension", bold: true),
            status,
            intro,
            steps,
            row([sized(picker, width: 180), sized(open, width: 180)]),
            row([sized(NSButton(title: "Show Extension Folder", target: self, action: #selector(revealFolder)), width: 180),
                 sized(NSButton(title: "Copy Folder Path", target: self, action: #selector(copyPath)), width: 180)]),
        ], spacing: 8)
        view.setCustomSpacing(4, after: view.arrangedSubviews[0])
        view.setCustomSpacing(12, after: steps)
    }

    func start() {
        update()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.update() } }
    }
    func stop() { timer?.invalidate(); timer = nil }

    private func update() {
        let names = connected()
        status.stringValue = names.isEmpty ? "Not connected — install it below" : "✓ Connected: " + names.joined(separator: ", ")
        status.textColor = names.isEmpty ? .secondaryLabelColor : .systemGreen
    }

    @objc private func openPage() {
        guard browsers.indices.contains(picker.indexOfSelectedItem) else { return }
        let b = browsers[picker.indexOfSelectedItem]
        // Browsers don't open their internal pages from a plain URL open; hand the address to the browser itself.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-b", b.bundleID, b.page]
        try? p.run()
    }
    @objc private func revealFolder() {
        if !FileManager.default.fileExists(atPath: ExtensionFolder.url.path) { ExtensionFolder.install() }
        NSWorkspace.shared.activateFileViewerSelecting([ExtensionFolder.url])
    }
    @objc private func copyPath() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(ExtensionFolder.url.path, forType: .string)
    }
}
