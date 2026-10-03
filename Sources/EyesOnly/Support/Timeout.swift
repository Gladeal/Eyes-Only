import AppKit

struct TimedOut: LocalizedError { var errorDescription: String? { "timed out" } }

private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock(); private var done = false
    func claim() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
}

/// Runs `op`, but gives up after `seconds`. Unlike a task group, it doesn't wait for an `op` that never
/// returns (ScreenCaptureKit calls can hang when the capture service's connection breaks).
func withTimeout<T>(_ seconds: Double, _ op: @escaping () async throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
        let once = OnceFlag()
        Task {
            do { let v = try await op(); if once.claim() { cont.resume(returning: v) } }
            catch { if once.claim() { cont.resume(throwing: error) } }
        }
        Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if once.claim() { cont.resume(throwing: TimedOut()) }
        }
    }
}
