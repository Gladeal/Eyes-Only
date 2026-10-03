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

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, let frame = FrameSink.make(sampleBuffer) else { return }
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
