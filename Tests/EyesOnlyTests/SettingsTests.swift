import Testing
import AppKit
@testable import EyesOnly

/// Every Settings page builds. A layout mistake there (spacing after a row that isn't on the page) threw while
/// the window was being made, and Settings simply never opened.
@MainActor
@Suite("Settings")
struct SettingsTests {
    @Test func everyPageBuilds() {
        let settings = SettingsWindow()
        for pane in [SettingsWindow.Pane.general, .apps, .browser, .shortcuts] { settings.select(pane.rawValue) }
        #expect(settings.window.title == "Shortcuts")
    }

    @Test func shortcutDisplayAndSaving() throws {
        let s = Shortcut(keyCode: 35, modifiers: NSEvent.ModifierFlags([.control, .option, .command]).rawValue, key: "P")
        #expect(s.display == "⌃⌥⌘P")
        let data = try JSONEncoder().encode(s)
        #expect(try JSONDecoder().decode(Shortcut.self, from: data) == s)
    }
}
