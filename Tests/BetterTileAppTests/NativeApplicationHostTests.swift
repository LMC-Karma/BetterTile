import AppKit
import Testing

@Test(.appTestApplication, .settingsUI) @MainActor
func nativeApplicationHostStaysAccessoryAndInactive() throws {
    try #require(NativeEventLoopState.keepsApplicationRunning && NSApp.isRunning)
    #expect(NativeHostPolicyReading.current(of: NSApp) == .accessory)
    let processIsActive = NSRunningApplication.current.isActive
    #expect(!processIsActive)
}

@MainActor private final class StartupKeyTestPanel: OffscreenTestPanel {
    override var canBecomeKey: Bool { true }
}



// These tests require a real key window; run only while the Mac is unattended.
// Add only reviewed real-key or activation cases; keep all other tests in default suites and update NativeLaneMembership.
@Suite(.enabled(if: NativeFocusTestLane.isEnabled, "Requires an unattended Mac; set BETTERTILE_NATIVE_FOCUS_TESTS=1"), .nativeFocus)
@MainActor struct NativeFocusNativeApplicationHostTests {
    @Test(.appTestApplication, .settingsUI) @MainActor
    func nativeApplicationHostStaysInactiveWithAnAlreadyOrderedPanel() async throws {
        try #require(NativeEventLoopState.keepsApplicationRunning && NSApp.isRunning)
        let panel = StartupKeyTestPanel(contentRect: NSRect(x: 2_000_000, y: 0, width: 500, height: 100),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        OffscreenTestWindows.check(panel)
        panel.orderFrontForTesting()
        #expect(panel.isVisible)
        let activeBefore = NSRunningApplication.current.isActive
        try #require(!activeBefore)

        try await NativeEventLoopState.startApplicationHost()

        #expect(NativeHostPolicyReading.current(of: NSApp) == .accessory)
        let activeAfter = NSRunningApplication.current.isActive
        #expect(!activeAfter)
        panel.makeKeyAndOrderFrontForTesting()
        #expect(panel.isKeyWindow, Comment(rawValue: keyWindowDiagnostics(panel)))
        panel.orderOutForTesting()
        OffscreenTestWindows.check(panel)
    }
}
