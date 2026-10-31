import AppKit
import Testing

/// Delivers deactivation at the end of either native ordering entry point.
/// Key state and ordering still come from AppKit on an offscreen window.
@MainActor private final class DeactivatingOrderTestPanel: OffscreenTestPanel {
    override var canBecomeKey: Bool { true }
    private(set) var deactivationCount = 0

    override func orderFrontRegardless() {
        super.orderFrontRegardless()
        deactivateAfterOrdering()
    }

    override func order(_ place: NSWindow.OrderingMode, relativeTo otherWin: Int) {
        super.order(place, relativeTo: otherWin)
        if place != .out { deactivateAfterOrdering() }
    }

    private func deactivateAfterOrdering() {
        NSApp.deactivate()
        deactivationCount += 1
    }
}



// These tests require a real key window; run only while the Mac is unattended.
// Add only reviewed real-key or activation cases; keep all other tests in default suites and update NativeLaneMembership.
@Suite(.enabled(if: NativeFocusTestLane.isEnabled, "Requires an unattended Mac; set BETTERTILE_NATIVE_FOCUS_TESTS=1"), .nativeFocus)
@MainActor struct NativeFocusNativeKeyWindowTests {
    @Test(.appTestApplication, .settingsUI) @MainActor
    func keyWindowSetupSurvivesDeactivationDuringOrdering() throws {
        try #require(NativeEventLoopState.keepsApplicationRunning && NSApp.isRunning,
                     "The regression must run after the long-lived App host starts")
        let panel = DeactivatingOrderTestPanel(contentRect: NSRect(x: 2_000_000, y: 0, width: 500, height: 100),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        OffscreenTestWindows.check(panel)
        let activeBefore = NSRunningApplication.current.isActive
        let frontmostBefore = NSWorkspace.shared.frontmostApplication?.processIdentifier
            == ProcessInfo.processInfo.processIdentifier
        try #require(!activeBefore && !frontmostBefore, Comment(rawValue: keyWindowDiagnostics(panel)))

        panel.makeKeyAndOrderFrontForTesting()

        #expect(panel.isKeyWindow, Comment(rawValue: keyWindowDiagnostics(panel)))
        #expect(panel.deactivationCount > 0, "The native ordering path must deliver deactivation")
        let activeAfter = NSRunningApplication.current.isActive
        let frontmostAfter = NSWorkspace.shared.frontmostApplication?.processIdentifier
            == ProcessInfo.processInfo.processIdentifier
        #expect(activeAfter == activeBefore)
        #expect(frontmostAfter == frontmostBefore)
        OffscreenTestWindows.check(panel)
    }
}
