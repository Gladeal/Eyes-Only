import AppKit
import ScreenCaptureKit
import CoreMedia
import CoreVideo

// Stream sink (coalescing; delivers the newest frame on the main thread)

final class FrameSink: NSObject, SCStreamOutput, SCStreamDelegate {
    private let lock = NSLock()
    private var pending: CapturedFrame?
    private var scheduled = false
    private var dropped = 0
    let onFrame: (CapturedFrame) -> Void
    let onStop: (SCStream, Error) -> Void

    init(onFrame: @escaping (CapturedFrame) -> Void, onStop: @escaping (SCStream, Error) -> Void) {
        self.onFrame = onFrame; self.onStop = onStop
    }

    func takeDroppedCount() -> Int { lock.lock(); defer { lock.unlock() }; let d = dropped; dropped = 0; return d }

    /// Frames ScreenCaptureKit sent that weren't complete pictures, by status (idle, blank, suspended…), since
    /// the last call. They're skipped; counted so a stream that keeps sending only those shows in the log.
    private var skipped: [String: Int] = [:]
    func takeSkippedCounts() -> String {
        lock.lock(); defer { lock.unlock() }
        let s = skipped.sorted { $0.key < $1.key }.map { "\($0.value) \($0.key)" }.joined(separator: ", ")
        skipped = [:]
        return s
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        guard let frame = FrameSink.make(sampleBuffer) else {
            let name = FrameSink.statusName(sampleBuffer)
            lock.lock(); skipped[name, default: 0] += 1; lock.unlock()
            return
        }
        lock.lock()
        if pending != nil { dropped += 1 }
        pending = frame
        let need = !scheduled; scheduled = true
        lock.unlock()
        if need { DispatchQueue.main.async { [weak self] in self?.deliver() } }
    }

    private func deliver() {
        lock.lock(); let frame = pending; pending = nil; scheduled = false; lock.unlock()
        if let frame { onFrame(frame) }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) { onStop(stream, error) }

    static func statusName(_ sb: CMSampleBuffer) -> String {
        guard let arr = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = arr.first?[.status] as? Int, let status = SCFrameStatus(rawValue: raw) else { return "no status" }
        switch status {
        case .complete: return "complete but unreadable"
        case .idle: return "idle"
        case .blank: return "blank"
        case .suspended: return "suspended"
        case .started: return "started"
        case .stopped: return "stopped"
        @unknown default: return "status \(raw)"
        }
    }

    static func make(_ sb: CMSampleBuffer) -> CapturedFrame? {
        guard sb.isValid,
              let arr = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let info = arr.first,
              let raw = info[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let pixels = CMSampleBufferGetImageBuffer(sb),
              let surface = CVPixelBufferGetIOSurface(pixels)?.takeUnretainedValue() else { return nil }
        let bufW = CVPixelBufferGetWidth(pixels), bufH = CVPixelBufferGetHeight(pixels)
        var contentRect = CGRect.zero
        if let d = info[.contentRect] as? NSDictionary, let r = CGRect(dictionaryRepresentation: d) { contentRect = r }
        let contentScale = (info[.contentScale] as? CGFloat) ?? 1
        let scaleFactor = (info[.scaleFactor] as? CGFloat) ?? 1
        let geometry = FrameGeometry(bufferWidth: bufW, bufferHeight: bufH, contentRect: contentRect,
                                     contentScale: contentScale, scaleFactor: scaleFactor)
        let displayTime = (info[.displayTime] as? UInt64) ?? mach_absolute_time()
        return CapturedFrame(surface: surface, displayTime: displayTime, geometry: geometry,
                             gaps: edgeGaps(surface, geometry: geometry), fill: edgeColor(surface, geometry: geometry))
    }
}
