import Testing
import IOSurface
import CoreGraphics
@testable import EyesOnly

@Suite("Frames")
struct FrameTests {
    /// A 2× display, window at (10, 20) pt, 400×300 pt, in a 1000×800 px buffer.
    let geometry = FrameGeometry(bufferWidth: 1000, bufferHeight: 800,
                                 contentRect: CGRect(x: 10, y: 20, width: 400, height: 300),
                                 contentScale: 1, scaleFactor: 2)

    @Test func pixelRectIsTheContentRectInPixels() {
        #expect(geometry.pixelRect == CGRect(x: 20, y: 40, width: 800, height: 600))
    }

    @Test func pixelRectIsClampedToTheBuffer() {
        var g = geometry
        g.contentRect = CGRect(x: 300, y: 300, width: 400, height: 300)   // 600…1400 px wide: past the buffer
        #expect(g.pixelRect == CGRect(x: 600, y: 600, width: 400, height: 200))
    }

    @Test func pixelRectFallsBackToTheWholeBuffer() {
        var g = geometry
        g.contentRect = .zero
        #expect(g.pixelRect == CGRect(x: 0, y: 0, width: 1000, height: 800))
    }

    @Test func cropWinsOverTheContentRect() {
        var g = geometry
        g.crop = CGRect(x: 1, y: 2, width: 3, height: 4)
        #expect(g.pixelRect == CGRect(x: 1, y: 2, width: 3, height: 4))
    }

    @Test func aWholeShrunkenWindowIsCropped() {
        // Opaque part 10 % smaller on every side: same shape, so it's the whole window, just shrunk.
        let shown = wholeWindowCrop(geometry, [40, 30, 40, 30])
        #expect(shown?.crop == CGRect(x: 60, y: 70, width: 720, height: 540))
    }

    @Test func aPartialWindowIsNotCropped() {
        #expect(wholeWindowCrop(geometry, [300, 0, 0, 0]) == nil)       // different shape: part of the window
        #expect(wholeWindowCrop(geometry, [390, 290, 390, 290]) == nil) // too small to be worth showing
    }

    @Test func edgeGapsCountTransparentPixelsFromEachEdge() throws {
        let surface = try #require(Self.surface(width: 1000, height: 800))
        // Opaque only inside the content rect, inset by 5 px left, 7 top, 9 right, 11 bottom.
        Self.fill(surface, opaque: CGRect(x: 20 + 5, y: 40 + 7, width: 800 - 5 - 9, height: 600 - 7 - 11))
        #expect(edgeGaps(surface, geometry: geometry) == [5, 7, 9, 11])
    }

    @Test func edgeGapsAreZeroForAFullyOpaqueFrame() throws {
        let surface = try #require(Self.surface(width: 1000, height: 800))
        Self.fill(surface, opaque: CGRect(x: 0, y: 0, width: 1000, height: 800))
        #expect(edgeGaps(surface, geometry: geometry) == [0, 0, 0, 0])
    }

    // MARK: Helpers

    static func surface(width: Int, height: Int) -> IOSurface? {
        IOSurface(properties: [.width: width, .height: height, .bytesPerElement: 4,
                               .pixelFormat: 0x4247_5241 /* 'BGRA' */])
    }

    /// Alpha 255 inside `opaque` (pixels, top-left origin), 0 elsewhere.
    static func fill(_ s: IOSurface, opaque r: CGRect) {
        s.lock(options: [], seed: nil)
        defer { s.unlock(options: [], seed: nil) }
        let base = s.baseAddress.assumingMemoryBound(to: UInt8.self)
        for y in 0..<s.height {
            for x in 0..<s.width {
                base[y * s.bytesPerRow + x * 4 + 3] = r.contains(CGPoint(x: x, y: y)) ? 255 : 0
            }
        }
    }
}
