import Testing
import CoreGraphics
@testable import EyesOnly

@Suite("Stage Manager previews")
@MainActor
struct StageManagerTests {
    let window = CGRect(x: 200, y: 100, width: 1200, height: 800)

    @Test func stripThumbnailsAreCovered() {
        #expect(Controller.previewShaped(CGRect(x: 16, y: 300, width: 124, height: 137), target: window))
        #expect(Controller.previewShaped(CGRect(x: 16, y: 300, width: 270, height: 200), target: window))  // hovered
    }

    @Test func aPreviewExactlyOverTheWindowIsCovered() {
        #expect(Controller.previewShaped(window.offsetBy(dx: 2, dy: -1), target: window))   // grow / shrink animation
    }

    @Test func theSnapOutlineIsNotCovered() {
        // Dragging toward an edge: a half-screen outline above the window — not a preview of it.
        #expect(!Controller.previewShaped(CGRect(x: 0, y: 25, width: 735, height: 931), target: window))
    }
}
