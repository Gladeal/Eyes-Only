import AppKit

// Diagnostics log. Two kinds of lines:
//  - events (`diagnosticsLog`): what happened, what went wrong and what the app did about it — always written;
//  - detail (`diagnosticsDetail`): positions, frame rates, per-frame decisions — only with detailed diagnostics on.
// Lines carry app names, window sizes and events only: never window titles, web addresses or screen content.

private let logFormatter = ISO8601DateFormatter()
// Detailed diagnostics are a setting (General tab): off by default in the shared build (built with SHIP=1),
// which logs to ~/Library/Logs; on by default in the development build, which logs to results/ next to the app.
#if SHIP
private let diagnosticsDefault = false
let logURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Eyes Only/eyes-only.log")
#else
private let diagnosticsDefault = true
let logURL = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("results/mirror-diagnostics.log")
#endif
/// Read on every log call (some are per frame), so kept in memory and updated by the setting.
nonisolated(unsafe) var fullDiagnostics: Bool = UserDefaults.standard.object(forKey: "diagnostics") as? Bool ?? diagnosticsDefault

private let logHandle: FileHandle? = {
    let fm = FileManager.default
    try? fm.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    // Keep it from growing forever: past 5 MB, start over (the previous one is kept as .old).
    if let size = (try? fm.attributesOfItem(atPath: logURL.path))?[.size] as? Int, size > 5 << 20 {
        let old = logURL.appendingPathExtension("old")
        try? fm.removeItem(at: old)
        try? fm.moveItem(at: logURL, to: old)
    }
    if !fm.fileExists(atPath: logURL.path) { fm.createFile(atPath: logURL.path, contents: nil) }
    let h = try? FileHandle(forWritingTo: logURL)
    h?.seekToEndOfFile()
    return h
}()

/// An event: always written.
func diagnosticsLog(_ line: String) {
    logHandle?.write(Data("\(logFormatter.string(from: Date())) \(line)\n".utf8))
}

/// Detail: written only with detailed diagnostics on. The text isn't even built otherwise (some run every frame).
func diagnosticsDetail(_ line: @autoclosure () -> String) {
    if fullDiagnostics { diagnosticsLog(line()) }
}

func thermalName() -> String {
    switch ProcessInfo.processInfo.thermalState {
    case .nominal: return "nominal"
    case .fair: return "fair"
    case .serious: return "SERIOUS"
    case .critical: return "CRITICAL"
    @unknown default: return "unknown"
    }
}

func processCPUSeconds() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    func seconds(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1_000_000 }
    return seconds(usage.ru_utime) + seconds(usage.ru_stime)
}

func footprintMB() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
    }
    return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
}
