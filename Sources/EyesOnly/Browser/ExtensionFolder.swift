import AppKit

/// The Chromium extension's folder, kept outside the app so a browser can load it (refreshed at every launch).
enum ExtensionFolder {
    static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Eyes Only/Browser Extension")
    }
    static func install() {
        guard let bundled = Bundle.main.resourceURL?.appendingPathComponent("BrowserExtension"),
              FileManager.default.fileExists(atPath: bundled.path) else { return }
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.copyItem(at: bundled, to: url)
    }
}
