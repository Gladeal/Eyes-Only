import AppKit

// Settings (saved across launches)

enum Settings {
    static let sitesKey = "protectedSites", appsKey = "autoProtectApps"
    static var sites: [String] {
        get { UserDefaults.standard.stringArray(forKey: sitesKey) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: sitesKey) }
    }
    /// Stage Manager thumbnails and Mission Control tiles look normal locally (from a screen capture), black in
    /// captures. On by default.
    static var livePreviews: Bool {
        get { UserDefaults.standard.object(forKey: "livePreviews") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "livePreviews") }
    }
    /// Browser windows are captured only while their protected tab is the active one (not paused). On by default.
    static var captureOnlyActiveTab: Bool {
        get { UserDefaults.standard.object(forKey: "captureOnlyActiveTab") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "captureOnlyActiveTab") }
    }
    static func shortcut(_ action: ShortcutAction) -> Shortcut? {
        UserDefaults.standard.data(forKey: "shortcut." + action.rawValue).flatMap { try? JSONDecoder().decode(Shortcut.self, from: $0) }
    }
    static func setShortcut(_ action: ShortcutAction, _ shortcut: Shortcut?) {
        let key = "shortcut." + action.rawValue
        if let shortcut, let data = try? JSONEncoder().encode(shortcut) { UserDefaults.standard.set(data, forKey: key) }
        else { UserDefaults.standard.removeObject(forKey: key) }
    }
    static var apps: [String] {   // bundle identifiers
        get { UserDefaults.standard.stringArray(forKey: appsKey) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: appsKey) }
    }

    /// Pre-release builds were named "ScreenPrivacy Mirror" (bundle ID com.screenprivacy.mirror.menubar):
    /// bring their settings over once. Remove when no one runs those builds any more.
    static func migrateFromOldName() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "migratedOldSettings"),
              let old = UserDefaults(suiteName: "com.screenprivacy.mirror.menubar") else { return }
        for key in [sitesKey, appsKey, "captureOnlyActiveTab", "diagnostics", "dontOfferMoveToApplications"]
            where defaults.object(forKey: key) == nil {
            if let value = old.object(forKey: key) { defaults.set(value, forKey: key) }
        }
        defaults.set(true, forKey: "migratedOldSettings")
    }
}

/// A site rule: "mail.google.com" (that host and its subdomains), "bank.com/accounts" (and only under that
/// path). A scheme or a leading "*." is ignored.
func siteMatches(_ url: String, _ rule: String) -> Bool {
    guard let comps = URLComponents(string: url), let host = comps.host?.lowercased() else { return false }
    var r = rule.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    for prefix in ["https://", "http://", "*."] where r.hasPrefix(prefix) { r.removeFirst(prefix.count) }
    while r.hasSuffix("/") { r.removeLast() }
    guard !r.isEmpty else { return false }
    let parts = r.split(separator: "/", maxSplits: 1).map(String.init)
    let ruleHost = parts[0], rulePath = parts.count > 1 ? "/" + parts[1] : ""
    guard host == ruleHost || host.hasSuffix("." + ruleHost) else { return false }
    return rulePath.isEmpty || comps.path.lowercased().hasPrefix(rulePath)
}
