import AppKit

// Browser tabs (Chromium extension ⇄ native messaging ⇄ this app)
//
// The extension (BrowserExtension/) reports every window and tab of its browser. Chromium starts this
// same executable as its native-messaging host ("host mode", see main): that process relays the
// extension's messages to the running menu-bar app over a local socket. The app decides what's protected.

let nativeHostName = "com.eyesonly.bridge"
let extensionID = "mhebmngdhdfpccnfmpbomoleanijhpbj"

func bridgeSocketPath() -> String {
    let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Eyes Only")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    chmod(dir.path, 0o700)
    return dir.appendingPathComponent("bridge.sock").path
}

func unixAddress(_ path: String) -> sockaddr_un {
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8.prefix(MemoryLayout.size(ofValue: addr.sun_path) - 1))
    withUnsafeMutableBytes(of: &addr.sun_path) { raw in
        for (i, b) in bytes.enumerated() { raw[i] = b }
        raw[bytes.count] = 0
    }
    return addr
}

func writeAll(_ fd: Int32, _ data: Data) -> Bool {
    data.withUnsafeBytes { raw -> Bool in
        var off = 0
        while off < raw.count {
            let n = write(fd, raw.baseAddress!.advanced(by: off), raw.count - off)
            if n <= 0 { if n < 0 && errno == EINTR { continue }; return false }
            off += n
        }
        return true
    }
}

/// Host mode: Chromium talks length-prefixed JSON on stdin/stdout; the app talks newline-delimited JSON on
/// the socket. Keeps the extension's latest state so the app gets it as soon as it (re)connects.
func runNativeHost() -> Never {
    signal(SIGPIPE, SIG_IGN)
    /// Shared by the stdin (browser) and socket (app) threads; every access holds `lock`.
    final class Shared: @unchecked Sendable {
        let lock = NSLock()
        var sock: Int32 = -1
        var lastState: Data?
    }
    let shared = Shared()
    let lock = shared.lock
    let browserPID = getppid()   // Chromium starts the host from its browser process — the windows' owner

    func sendToApp(_ line: Data) {
        lock.lock(); defer { lock.unlock() }
        guard shared.sock >= 0 else { return }
        if !writeAll(shared.sock, line + Data([10])) { close(shared.sock); shared.sock = -1 }
    }
    func sendToExtension(_ json: Data) {
        var len = UInt32(json.count).littleEndian
        let frame = Data(bytes: &len, count: 4) + json
        _ = writeAll(STDOUT_FILENO, frame)
    }

    Thread.detachNewThread {
        let path = bridgeSocketPath()
        while true {
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            var addr = unixAddress(path)
            let ok = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            } == 0
            if !ok { close(fd); sleep(1); continue }   // the app isn't running (yet)
            let connectedAt = Date()
            var received = 0
            let hello = try! JSONSerialization.data(withJSONObject: ["type": "hello", "pid": Int(browserPID)])
            _ = writeAll(fd, hello + Data([10]))
            lock.lock(); shared.sock = fd; let state = shared.lastState; lock.unlock()
            if let state { sendToApp(state) }
            var buffer = Data()
            var chunk = [UInt8](repeating: 0, count: 65536)
            while true {
                let n = read(fd, &chunk, chunk.count)
                if n <= 0 { break }
                received += n
                buffer.append(contentsOf: chunk[0..<n])
                while let nl = buffer.firstIndex(of: 10) {
                    let line = buffer[buffer.startIndex..<nl]
                    buffer = Data(buffer[buffer.index(after: nl)...])
                    if !line.isEmpty { sendToExtension(Data(line)) }
                }
            }
            lock.lock(); if shared.sock == fd { close(fd); shared.sock = -1 }; lock.unlock()
            // Closed at once without a word: the app refused us — it's another build of Eyes Only (updated or
            // moved since the browser started this relay). Quit: the extension reconnects in a few seconds, and
            // the browser then starts the current build's relay. (Retrying here spun thousands of times a second.)
            if received == 0, Date().timeIntervalSince(connectedAt) < 2 { exit(0) }
            sleep(1)
        }
    }

    func readExactly(_ count: Int) -> Data? {
        var data = Data(); var buf = [UInt8](repeating: 0, count: max(1, min(count, 65536)))
        while data.count < count {
            let n = read(STDIN_FILENO, &buf, min(buf.count, count - data.count))
            if n <= 0 { return nil }
            data.append(contentsOf: buf[0..<n])
        }
        return data
    }
    while true {
        guard let header = readExactly(4) else { exit(0) }   // the browser closed the port
        let len = header.withUnsafeBytes { Int(UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self))) }
        guard len > 0, len < 64 << 20, let message = readExactly(len) else { exit(0) }
        lock.lock(); shared.lastState = message; lock.unlock()
        sendToApp(message)
    }
}

/// Registers the native-messaging host with every installed Chromium browser (rewritten at each launch,
/// so it always points at wherever this app is now).
func installNativeHosts() {
    guard let exe = Bundle.main.executablePath else { return }
    let manifest: [String: Any] = ["name": nativeHostName, "description": "Eyes Only bridge",
                                   "path": exe, "type": "stdio", "allowed_origins": ["chrome-extension://\(extensionID)/"]]
    guard let data = try? JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .withoutEscapingSlashes]) else { return }
    let support = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
    var installed: [String] = []
    for browser in ["Google/Chrome", "Google/Chrome Beta", "Google/Chrome Dev", "Google/Chrome Canary", "Chromium",
                    "Microsoft Edge", "BraveSoftware/Brave-Browser", "Vivaldi", "Arc/User Data"] {
        let base = support.appendingPathComponent(browser)
        guard FileManager.default.fileExists(atPath: base.path) else { continue }
        let dir = base.appendingPathComponent("NativeMessagingHosts")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if (try? data.write(to: dir.appendingPathComponent("\(nativeHostName).json"), options: .atomic)) != nil { installed.append(browser) }
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("com.screenprivacy.mirror.json"))   // pre-release name
    }
    diagnosticsLog("BROWSER native host registered for: \(installed.isEmpty ? "no Chromium browser found" : installed.joined(separator: ", "))")
}
