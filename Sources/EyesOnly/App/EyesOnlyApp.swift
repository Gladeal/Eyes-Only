// Eyes Only — a macOS menu-bar app that keeps chosen windows and browser tabs out of screen captures.
//
// A protected window is captured live with ScreenCaptureKit into an IOSurface. Two borderless windows are
// stacked over it: a capturable black backing (captures of the screen see this → black box) and a
// sharingType = .none mirror showing the live copy (you keep seeing the window). A black proxy covers
// Stage Manager / Mission Control previews of it. Each protected window runs in its own `Session`; the
// `Controller` owns the menu-bar menu and the shared tick that drives every session.
// No network code; nothing on screen is stored.
//
// Started by a Chromium browser instead (a chrome-extension:// argument), the same executable is the
// browser extension's native-messaging host: see Browser/NativeHost.swift.

import AppKit
import IOSurface

@main struct EyesOnlyApp {
    @MainActor static func main() {
        // Started by a Chromium browser as its native-messaging host: relay, don't start the menu-bar app.
        if CommandLine.arguments.dropFirst().contains(where: { $0.hasPrefix("chrome-extension://") }) { runNativeHost() }
        Settings.migrateFromOldName()
        let app = NSApplication.shared
        // Developer check: render each Settings tab to PNGs in the given folder, then quit (nothing shown).
        #if !SHIP
        if let i = CommandLine.arguments.firstIndex(of: "--render-settings"), CommandLine.arguments.count > i + 1 {
            let dir = URL(fileURLWithPath: CommandLine.arguments[i + 1])
            NSApp.appearance = NSAppearance(named: .aqua)   // the cached image has no window background
            let settings = SettingsWindow()
            for (n, pane) in [SettingsWindow.Pane.general, .apps, .browser].enumerated() {
                settings.select(pane.rawValue)
                settings.general.reload(); settings.apps.reload(); settings.sites.reload()
                let v = settings.window.contentView!.superview ?? settings.window.contentView!   // whole window, toolbar too
                v.layoutSubtreeIfNeeded()
                if let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                    v.cacheDisplay(in: v.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("settings-\(n)-\(pane).png"))
                }
            }
            exit(0)
        }
        #endif
        app.setActivationPolicy(.accessory)   // background app: menu-bar only, no Dock icon
        let delegate = Controller()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
