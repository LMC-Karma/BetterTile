import AppKit
import BetterTileCore
import BetterTileTestSupport
import Testing
@testable import BetterTileMacOS

/// These tests use only owned offscreen panels. They never read Accessibility.
@Suite(.macOSTestApplication, .macOSUI) @MainActor
struct DividerOverlayLifetimeTests {
    private func presentation(clock: BetterTileClock = .live) throws -> (DividerDragOverlay, NSPanel, BTRect, WindowSnapshot) {
        let bounds = BTRect(x: -10000, y: -10000, width: 800, height: 600)
        let input = NSPanel(contentRect: CGRect(x: -10000, y: -10000, width: 30, height: 168),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        input.isReleasedWhenClosed = false
        let snapshot = WindowSnapshot(id: WindowID(rawValue: "lifetime"), processIdentifier: 0,
                                      bundleIdentifier: "com.example.Sample", title: "Sample",
                                      frame: bounds, displayID: DisplayID(rawValue: "offscreen"))
        let overlay = DividerDragOverlay(clock: clock)
        overlay.begin(displayFrame: bounds, below: input, appearance: .init(), windows: [snapshot])
        return (overlay, input, bounds, snapshot)
    }

    @Test func endingCancelsAndReleasesItsFade() async throws {
        let clock = ManualClock()
        let (overlay, input, _, _) = try presentation(clock: clock.clock)
        defer { overlay.end(); overlay.panel?.close(); input.close() }
        overlay.fadeOut()
        let fade = try #require(overlay.fadeTask)
        try #require(await clock.waitForSleepers(count: 1, timeout: .seconds(20)))
        overlay.end()
        #expect(overlay.fadeTask == nil)
        #expect(fade.isCancelled)
        #expect(clock.pendingSleepCount == 0)
        // Also drain the baseline failure, so a failing test leaves no timer behind.
        clock.advance(by: .seconds(1))
        await fade.value
        #expect(!overlay.isVisible)
    }

    @Test func beginningAgainCancelsTheOldFadeWithoutEndingTheNewPresentation() async throws {
        let clock = ManualClock()
        let (overlay, input, bounds, snapshot) = try presentation(clock: clock.clock)
        defer { overlay.end(); overlay.panel?.close(); input.close() }
        overlay.fadeOut()
        let fade = try #require(overlay.fadeTask)
        try #require(await clock.waitForSleepers(count: 1, timeout: .seconds(20)))
        overlay.begin(displayFrame: bounds, below: input, appearance: .init(), windows: [snapshot])
        #expect(overlay.fadeTask == nil)
        #expect(fade.isCancelled)
        #expect(clock.pendingSleepCount == 0)
        clock.advance(by: .seconds(1))
        await fade.value
        #expect(overlay.isVisible && !overlay.isFading)
        #expect(overlay.panel?.alphaValue == 1)
    }

    @Test func aCompletedFadeReleasesItsTaskAndPreviewViews() async throws {
        let clock = ManualClock()
        let (overlay, input, bounds, snapshot) = try presentation(clock: clock.clock)
        defer { overlay.end(); overlay.panel?.close(); input.close() }
        overlay.update(previews: [Placement(windowID: snapshot.id, frame: bounds)])
        overlay.fadeOut()
        let fade = try #require(overlay.fadeTask)
        try #require(await clock.waitForSleepers(count: 1, timeout: .seconds(20)))
        clock.advance(by: .milliseconds(120))
        await fade.value
        #expect(overlay.fadeTask == nil)
        #expect(clock.pendingSleepCount == 0)
        #expect(overlay.previewViews.isEmpty && !overlay.isVisible)
    }

    @Test func replacingAFadeKeepsOnlyTheNewTimer() async throws {
        let clock = ManualClock()
        let (overlay, input, _, _) = try presentation(clock: clock.clock)
        defer { overlay.end(); overlay.panel?.close(); input.close() }
        overlay.fadeOut()
        let oldFade = try #require(overlay.fadeTask)
        try #require(await clock.waitForSleepers(count: 1, timeout: .seconds(20)))
        overlay.fadeOut()
        let newFade = try #require(overlay.fadeTask)
        await oldFade.value
        try #require(await clock.waitForSleepers(count: 1, timeout: .seconds(20)))
        #expect(oldFade.isCancelled)
        #expect(clock.pendingSleepCount == 1)
        #expect(overlay.isVisible && overlay.isFading)
        clock.advance(by: .milliseconds(120))
        await newFade.value
        #expect(overlay.fadeTask == nil && !overlay.isVisible)
    }

    @Test func destroyingTheOverlayCancelsItsPendingFade() async throws {
        let clock = ManualClock()
        let input = NSPanel(contentRect: CGRect(x: -10000, y: -10000, width: 30, height: 168),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        input.isReleasedWhenClosed = false
        defer { input.close() }
        var overlay: DividerDragOverlay? = DividerDragOverlay(clock: clock.clock)
        overlay?.begin(displayFrame: BTRect(x: -10000, y: -10000, width: 800, height: 600),
                       below: input, appearance: .init(), windows: [])
        let panel = try #require(overlay?.panel)
        defer { panel.close() }
        overlay?.fadeOut()
        let fade = try #require(overlay?.fadeTask)
        try #require(await clock.waitForSleepers(count: 1, timeout: .seconds(20)))
        weak var released = overlay
        overlay = nil
        #expect(released == nil)
        #expect(fade.isCancelled)
        #expect(clock.pendingSleepCount == 0)
        await fade.value
    }

}
