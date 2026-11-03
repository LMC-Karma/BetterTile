import AppKit
import BetterTileCore
import Testing
import BetterTileTestSupport
@testable import BetterTileMacOS

// WindowServer excludes off-display coordinates from windowNumber(at:). Run
// the positive hit tests only on an explicitly selected, reserved test screen.
@Test(.macOSTestApplication, .macOSUI, .enabled(if: ProcessInfo.processInfo.environment["BETTERTILE_HIT_TEST_SCREEN"] != nil))
@MainActor func appKitOwnershipHitTestsRealPanels() async throws {
    _ = NSApplication.shared
    let name = try #require(ProcessInfo.processInfo.environment["BETTERTILE_HIT_TEST_SCREEN"])
    try #require(["Virtual 16:9", "BTTest-B"].contains(name))
    let screen = try #require(NSScreen.screens.first { $0.localizedName == name })
    let mainFrame = try #require(NSScreen.screens.first?.frame)
    let frame = NSRect(x: screen.frame.midX, y: screen.frame.midY, width: 100, height: 100)
    func panel() throws -> NSPanel {
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: true, screen: screen)
        panel.isReleasedWhenClosed = false
        // Set the global frame before ordering on a secondary screen.
        panel.setFrame(frame, display: false)
        try #require(screen.frame.contains(panel.frame))
        return panel
    }
    let lower = try panel()
    let upper = try panel()
    defer { upper.close(); lower.close() }
    let point = BTPoint(x: frame.midX, y: mainFrame.maxY - frame.midY)
    let press = GlobalGestureEvent(kind: .leftMouseDown, position: point,
                                  button: 0, modifiers: [], timestamp: 1)
    func allowsPress() -> Bool {
        var filter = AppKitWindowGestureFilter()
        return filter.allows(press)
    }

    upper.orderFrontForTesting()
    try #require(await waitUntil { NSWindow.windowNumber(at: NSPoint(x: frame.midX, y: frame.midY), belowWindowWithWindowNumber: 0) == upper.windowNumber })
    #expect(upper.frame == frame)
    #expect(NSWindow.windowNumber(at: NSPoint(x: frame.midX, y: frame.midY),
                                  belowWindowWithWindowNumber: 0) == upper.windowNumber)
    #expect(!allowsPress())

    upper.ignoresMouseEvents = true
    #expect(allowsPress())

    lower.orderFrontForTesting()
    upper.orderFrontForTesting()
    try #require(await waitUntil { !allowsPress() })
    #expect(!allowsPress())
}

private func appKitGesture(_ kind: GlobalGestureEventKind, x: Double) -> GlobalGestureEvent {
    GlobalGestureEvent(kind: kind, position: BTPoint(x: x, y: 17), button: 0, modifiers: [], timestamp: 1)
}

@Test(.macOSTestApplication) @MainActor func appKitPressKeepsItsGestureWhenThePointerLeavesTheWindow() {
    var queries = 0
    var filter = AppKitWindowGestureFilter(appKitWindowAtPoint: { point in
        queries += 1
        return point.x < 200
    })
    let own = [appKitGesture(.leftMouseDown, x: 100), appKitGesture(.leftMouseDragged, x: 600), appKitGesture(.leftMouseUp, x: 600)]
        .map { filter.allows($0) }
    #expect(own == [false, false, false])
    #expect(queries == 1)
    let native = [appKitGesture(.leftMouseDown, x: 600), appKitGesture(.leftMouseDragged, x: 100), appKitGesture(.leftMouseUp, x: 100)]
        .map { filter.allows($0) }
    #expect(native == [true, true, true])
    #expect(queries == 2)
}

@Test(.macOSTestApplication) @MainActor func aNewPressReplacesAppKitOwnershipAfterALostRelease() {
    var filter = AppKitWindowGestureFilter(appKitWindowAtPoint: { $0.x < 200 })
    let allowed = [appKitGesture(.leftMouseDown, x: 100), appKitGesture(.leftMouseDown, x: 600),
                   appKitGesture(.leftMouseUp, x: 600), appKitGesture(.leftMouseUp, x: 100)].map { filter.allows($0) }
    #expect(allowed == [false, true, true, true])
}
