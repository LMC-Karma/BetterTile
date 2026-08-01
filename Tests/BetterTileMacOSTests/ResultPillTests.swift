import Testing
@testable import BetterTileCore
@testable import BetterTileMacOS

@Test func resultPillUsesCompactSuccessAndFailureContent() {
    let success = ResultPillFeedback.success()
    let failure = ResultPillFeedback.failure("That Bento drop cannot satisfy the windows’ minimum sizes.")

    #expect(success.message == "Layout applied")
    #expect(success.symbolName == "checkmark")
    #expect(success.dismissDelay == 0.9)
    #expect(failure.message == "Can’t fit this layout")
    #expect(failure.symbolName == "xmark")
    #expect(failure.dismissDelay == 1.6)
}

@Test func resultPillShortensKnownErrors() {
    #expect(ResultPillFeedback.failure("No eligible focused window.").message == "No eligible window")
    #expect(ResultPillFeedback.failure("Accessibility access was removed.").message == "Accessibility required")
    #expect(ResultPillFeedback.failure("The preview no longer matches the active window transaction.").message == "Window changed")
    #expect(ResultPillFeedback.failure("Something unexpected happened.").message == "Couldn’t apply layout")
}

@Test func resultPillIsCenteredBelowTheDisplayWorkAreaTop() {
    let display = DisplaySnapshot(
        id: DisplayID(rawValue: "secondary"),
        frame: BTRect(x: 1512, y: 0, width: 1728, height: 1117),
        visibleFrame: BTRect(x: 1512, y: 38, width: 1728, height: 1039)
    )

    let frame = ResultPillLayout.frame(for: .success(), on: display)

    #expect(frame.size.height == 40)
    #expect(frame.size.width == 172)
    #expect(frame.midX == display.visibleFrame.midX)
    #expect(frame.minY == display.visibleFrame.minY + 24)
    #expect(frame.minX >= display.visibleFrame.minX)
    #expect(frame.maxX <= display.visibleFrame.maxX)
    #expect(frame.minY >= display.visibleFrame.minY)
    #expect(frame.maxY <= display.visibleFrame.maxY)
}

@Test func resultPillWidthGrowsForFailureButStaysCompact() {
    let display = DisplaySnapshot(
        id: DisplayID(rawValue: "main"),
        frame: BTRect(x: 0, y: 0, width: 1440, height: 900),
        visibleFrame: BTRect(x: 0, y: 24, width: 1440, height: 840)
    )

    let frame = ResultPillLayout.frame(for: .failure("That layout cannot fit."), on: display)

    #expect(frame.size.width >= 172)
    #expect(frame.size.width <= 240)
    #expect(frame.midX == display.visibleFrame.midX)
}
