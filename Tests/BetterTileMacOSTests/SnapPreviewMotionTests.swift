import CoreGraphics
import Testing
@testable import BetterTileMacOS

/// Displays from a live test, in AppKit coordinates: the main
/// display at the origin, the test display to its right, and a shorter test
/// screen to the right of that.
struct SnapPreviewMotionTests {
    private let screens = [
        CGRect(x: 0, y: 606, width: 1210, height: 834),
        CGRect(x: 1210, y: 0, width: 2560, height: 1440),
        CGRect(x: 3770, y: 360, width: 1920, height: 1080),
    ]

    @Test func previewAnimatesWithinOneDisplay() {
        let left = CGRect(x: 1215, y: 5, width: 1270, height: 1400)
        let right = CGRect(x: 2495, y: 5, width: 1270, height: 1400)
        #expect(SnapPreviewMotion.animates(from: left, to: right, screenFrames: screens))
    }

    @Test func previewJumpsWhenItChangesDisplay() {
        // The live morph between these two frames left the panel outside both displays.
        let virtualRight = CGRect(x: 2495, y: 5, width: 1270, height: 1400)
        let testScreenRight = CGRect(x: 3775, y: 405, width: 950, height: 1040)
        #expect(!SnapPreviewMotion.animates(from: virtualRight, to: testScreenRight, screenFrames: screens))
        #expect(!SnapPreviewMotion.animates(from: testScreenRight, to: virtualRight, screenFrames: screens))
    }

    @Test func unchangedOrOffscreenStartDoesNotAnimate() {
        let frame = CGRect(x: 2495, y: 5, width: 1270, height: 1400)
        #expect(!SnapPreviewMotion.animates(from: frame, to: frame, screenFrames: screens))
        let nowhere = CGRect(x: -500, y: -500, width: 10, height: 10)
        #expect(!SnapPreviewMotion.animates(from: nowhere, to: frame, screenFrames: screens))
    }
}
