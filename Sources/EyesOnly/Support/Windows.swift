import AppKit

/// One window as the system's window list (CoreGraphics) reports it.
struct WindowInfo: Equatable {
    let id: CGWindowID
    let pid: pid_t
    let owner: String     // the owning app's name ("WindowManager" is Stage Manager, "Dock" also draws Mission Control)
    let layer: Int        // 0 for normal app windows; system UI sits on higher layers
    let alpha: Double
    let bounds: CGRect    // CoreGraphics global coordinates (top-left origin)
    let onScreen: Bool

    init(_ d: [String: Any]) {
        id = CGWindowID(d[kCGWindowNumber as String] as? Int ?? 0)
        pid = pid_t(d[kCGWindowOwnerPID as String] as? Int ?? 0)
        owner = d[kCGWindowOwnerName as String] as? String ?? ""
        layer = d[kCGWindowLayer as String] as? Int ?? -1
        alpha = d[kCGWindowAlpha as String] as? Double ?? 1
        bounds = (d[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0) } ?? .zero
        onScreen = d[kCGWindowIsOnscreen as String] as? Bool ?? false
    }
}

/// The system's window list, front to back; nil if WindowServer didn't answer.
func windowList(_ options: CGWindowListOption, relativeTo id: CGWindowID = kCGNullWindowID) -> [WindowInfo]? {
    (CGWindowListCopyWindowInfo(options, id) as? [[String: Any]])?.map(WindowInfo.init)
}

/// One window, on screen or not; nil once it's gone.
func windowInfo(_ id: CGWindowID) -> WindowInfo? {
    windowList([.optionIncludingWindow], relativeTo: id)?.first
}

extension Array where Element == WindowInfo {
    func window(_ id: CGWindowID) -> WindowInfo? { first { $0.id == id } }
}

/// CoreGraphics global (top-left origin) rect -> Cocoa global (bottom-left origin) rect.
func cocoaRect(_ r: CGRect) -> NSRect {
    let h = NSScreen.screens.first?.frame.height ?? 0
    return NSRect(x: r.minX, y: h - r.maxY, width: r.width, height: r.height)
}

func machMilliseconds(_ delta: UInt64) -> Double {
    var base = mach_timebase_info_data_t(); mach_timebase_info(&base)
    return Double(delta) * Double(base.numer) / Double(base.denom) / 1_000_000
}
