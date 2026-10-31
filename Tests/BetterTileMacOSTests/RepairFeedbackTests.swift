import AppKit
import BetterTileCore
import Testing
@testable import BetterTileMacOS

@Suite(.macOSTestApplication) struct RepairFeedbackTests {
    @Test(arguments: [
        " Use Repair Layout to rebuild the layout.",
        " Use Repair Layout on the other desktop to rebuild the layout.",
        " Use Repair Layout on both affected desktops to rebuild their layouts.",
    ])
    func repairFeedbackRetainsReasonAndDesktop(advice: String) {
        let reason = "Window update failed and the previous layout could not be fully restored." + advice
        let feedback = ResultPillFeedback.failure(reason)
        #expect(feedback.kind == .failure)
        #expect(feedback.message == (advice == repairLayoutRecoverySuffix ? "Couldn’t apply layout" : "Use Repair Layout"))
        #expect(feedback.detail == reason)
        #expect(feedback.symbolName == "xmark")
        #expect(feedback.dismissDelay == 3)
    }

    @Test(arguments: ["The desktop changed.", "No eligible focused window.", "Accessibility access was removed."])
    func repairFeedbackKeepsCompactFailures(reason: String) {
        let feedback = ResultPillFeedback.failure(reason)
        let titles = ["The desktop changed.": "Desktop changed",
                      "No eligible focused window.": "No eligible window",
                      "Accessibility access was removed.": "Accessibility required"]
        #expect(feedback.message == titles[reason])
        #expect(feedback.detail == nil)
        #expect(feedback.dismissDelay == 1.6)
    }

    @Test func repairFeedbackKeepsActiveDesktopAndOrdinaryReasons() {
        let reason = "Adaptive could not adopt the settled divider."
        let ordinary = ResultPillFeedback.failure(reason)
        let active = ResultPillFeedback.failure(reason + repairLayoutRecoverySuffix)
        #expect(ordinary.message == "Couldn’t apply layout")
        #expect(ordinary.detail == reason)
        #expect(ordinary.dismissDelay == 3)
        #expect(active.message == ordinary.message)
        #expect(active.detail == reason + repairLayoutRecoverySuffix)
        #expect(active.dismissDelay == ordinary.dismissDelay)
        #expect(ResultPillFeedback.failure(nil).detail == nil)
        #expect(ResultPillFeedback.failure(nil).dismissDelay == 1.6)
    }

    // Measure the actual failure strings with the production fonts and label.
    // This needs no panel, app launch, or live Accessibility observation.
    @MainActor @Test(arguments: [
        "A window update failed and the previous layout could not be fully restored. Use Repair Layout on the other desktop to rebuild the layout.",
        "A window update failed and the previous layout could not be fully restored. Use Repair Layout on both affected desktops to rebuild their layouts.",
        "The divider change failed and the previous layout could not be fully restored. Use Repair Layout on both affected desktops to rebuild their layouts.",
    ])
    func repairFeedbackFitsExistingDetailLabel(reason: String) throws {
        let feedback = ResultPillFeedback.failure(reason)
        let detail = try #require(feedback.detail)
        #expect(detail == reason)
        let display = DisplaySnapshot(id: DisplayID(rawValue: "feedback"),
            frame: BTRect(x: 0, y: 0, width: 1920, height: 1080),
            visibleFrame: BTRect(x: 0, y: 30, width: 1920, height: 1050))
        let frame = ResultPillLayout.frame(for: feedback, on: display)
        let textWidth = frame.size.width - ResultPillLayout.detailChrome
            - ResultPillLayout.labelTextInset - ResultPillLayout.measurementMargin
        let lines = ResultPillLayout.detailLineCount(detail, width: textWidth)
        #expect(lines == 2)
        #expect(ResultPillLayout.detailFits(detail))
        #expect(ResultPillLayout.titleFits(feedback.message))
        #expect(frame.size.width == 520)
        #expect(frame.size.height == 72)
        #expect(feedback.dismissDelay == 3)

        let label = NSTextField(labelWithString: detail)
        ResultPillController.configureDetailLabel(label)
        let bounds = NSRect(x: 0, y: 0, width: frame.size.width - ResultPillLayout.detailChrome, height: 1000)
        let shown = try #require(label.cell?.cellSize(forBounds: bounds).height)
        label.maximumNumberOfLines = 0
        let needed = try #require(label.cell?.cellSize(forBounds: bounds).height)
        #expect(needed > 0)
        #expect(needed <= shown)
        #expect(label.stringValue == reason)
        #expect(label.accessibilityValue() as? String == reason)
        print("REPAIR_FEEDBACK_LAYOUT lines=\(lines) textWidth=\(textWidth) frame=\(frame) shown=\(shown) needed=\(needed) reason=\(reason)")
    }
}
