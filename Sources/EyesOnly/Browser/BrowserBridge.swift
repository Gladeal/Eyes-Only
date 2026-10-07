import AppKit

/// The app's end of the socket. Socket work runs on its own queue; messages are delivered on the main thread.
final class BrowserBridge {
    private let queue = DispatchQueue(label: "EyesOnly.bridge")
    private var listenSource: DispatchSourceRead?
    private var clients: [Int32: (source: DispatchSourceRead, buffer: Data)] = [:]
    private var refused = 0, lastRefusalLogged = Date.distantPast
    var onMessage: ((Int32, [String: Any]) -> Void)?
    var onDisconnect: ((Int32) -> Void)?

    func start() {
        let path = bridgeSocketPath()
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = unixAddress(path)
        let oldMask = umask(0o077)   // the socket is created owner-only (no window before the chmod below)
        defer { umask(oldMask) }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        } == 0
        guard bound, listen(fd, 8) == 0 else { diagnosticsLog("BROWSER bridge: could not listen (\(errno))"); close(fd); return }
        chmod(path, 0o600)   // this user only
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            while true {
                let c = accept(fd, nil, nil)
                if c < 0 { break }
                self?.add(c)
            }
        }
        source.resume()
        listenSource = source
    }

    /// Only this app's own relay (the same executable, started by a browser for the extension) may talk to the
    /// app. Anything else that connects — another program running as this user — is refused.
    private func peerIsOurRelay(_ fd: Int32) -> Bool {
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else { return false }
        var pid: pid_t = 0
        var len = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(fd, 0 /* SOL_LOCAL */, 0x002 /* LOCAL_PEERPID */, &pid, &len) == 0, pid > 0 else { return false }
        var buf = [CChar](repeating: 0, count: 4 * 1024)
        guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0, let mine = Bundle.main.executablePath else { return false }
        let theirs = String(cString: buf)
        var a = stat(), b = stat()
        guard stat(theirs, &a) == 0, stat(mine, &b) == 0 else { return false }
        return a.st_dev == b.st_dev && a.st_ino == b.st_ino   // the very same file, wherever it's called from
    }

    private func add(_ fd: Int32) {
        guard peerIsOurRelay(fd) else {
            close(fd)
            refused += 1
            if Date().timeIntervalSince(lastRefusalLogged) >= 60 {   // at most once a minute
                diagnosticsLog("BROWSER bridge: refused \(refused) connection(s) from another program")
                refused = 0; lastRefusalLogged = Date()
            }
            return
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var nosig: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &nosig, socklen_t(MemoryLayout<Int32>.size))
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.readable(fd) }
        source.setCancelHandler { close(fd) }
        clients[fd] = (source, Data())
        source.resume()
    }

    private func readable(_ fd: Int32) {
        var chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(fd, &chunk, chunk.count)
            if n == 0 || (n < 0 && errno != EAGAIN && errno != EINTR) { drop(fd); return }
            if n < 0 { break }
            clients[fd]?.buffer.append(contentsOf: chunk[0..<n])
            // A message is a few kB to a few hundred kB (all tabs); anything this big is not our extension.
            if (clients[fd]?.buffer.count ?? 0) > 16 << 20 { diagnosticsLog("BROWSER bridge: message too large, connection dropped"); drop(fd); return }
        }
        guard var buffer = clients[fd]?.buffer else { return }
        var messages: [[String: Any]] = []
        while let nl = buffer.firstIndex(of: 10) {
            let line = buffer[buffer.startIndex..<nl]
            buffer = Data(buffer[buffer.index(after: nl)...])
            if let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] { messages.append(obj) }
        }
        clients[fd]?.buffer = buffer
        guard !messages.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in messages.forEach { self?.onMessage?(fd, $0) } }
    }

    private func drop(_ fd: Int32) {
        guard let c = clients.removeValue(forKey: fd) else { return }
        c.source.cancel()
        DispatchQueue.main.async { [weak self] in self?.onDisconnect?(fd) }
    }

    func send(_ fd: Int32, _ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        queue.async { if self.clients[fd] != nil { _ = writeAll(fd, data + Data([10])) } }
    }
}

/// A tab or a window as the extension names it. Its IDs are per browser, so the browser's process is part of the key.
struct BrowserKey: Hashable, CustomStringConvertible {
    let pid: pid_t, id: Int
    var description: String { "\(pid):\(id)" }
}

struct BrowserTab { let id: Int; let title: String; let url: String; let active: Bool }
struct BrowserWindow { let id: Int; let bounds: CGRect; let state: String; let tabs: [BrowserTab] }
final class BrowserClient {
    var pid: pid_t = 0
    var name = "Browser"
    var windows: [BrowserWindow] = []
}
