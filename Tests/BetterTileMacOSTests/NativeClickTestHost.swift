import AppKit
import Testing

@MainActor private final class NativeClickTarget: NSObject {
    var presses = 0
    @objc func pressed(_ sender: Any?) { presses += 1 }
}





private enum NativeEventLoopTestError: Error { case expected }

@Test(.macOSTestApplication, .macOSUI) @MainActor func nativeEventLoopRethrowsAfterStoppingAndCanRunAgain() throws {
    #expect(throws: NativeEventLoopTestError.expected) {
        try withNativeEventLoop { () throws -> Void in
            #expect(NativeEventLoopState.isRunning)
            throw NativeEventLoopTestError.expected
        }
    }
    #expect(!NSApp.isRunning)
    #expect(try withNativeEventLoop { NativeEventLoopState.isRunning })
    #expect(!NSApp.isRunning)
}

// These tests inspect key state or share a real-key fixture; run only while the Mac is unattended.
// Add only reviewed real-key or activation cases; keep all other tests in default suites and update NativeLaneMembership.
@Suite(.enabled(if: NativeFocusTestLane.isEnabled, "Requires an unattended Mac; set BETTERTILE_NATIVE_FOCUS_TESTS=1"), .nativeFocus)
@MainActor struct NativeFocusNativeClickTestHost {
    @Test(.macOSTestApplication, .macOSUI) @MainActor func nativeClicksCompleteAfterRunLoopStall() throws {
        _ = NSApplication.shared
        let panel = NSPanel(contentRect: NSRect(x: 24000, y: 0, width: 100, height: 40),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        let target = NativeClickTarget()
        let button = NSButton(title: "Delayed fixture", target: target, action: #selector(NativeClickTarget.pressed(_:)))
        panel.contentView = button
        panel.orderFrontForTesting()
        defer { panel.orderOutForTesting() }
        // Stall the owned loop after the helper schedules its work. A wall-clock watchdog
        // must not race the native button's tracking loop when the main thread resumes.
        RunLoop.main.perform(inModes: [.default]) { Thread.sleep(forTimeInterval: 2.1) } // real-time: stalls the owned run loop past the native-click watchdog on purpose
        try performNativeClick(button)
        #expect(target.presses == 1)
        #expect(!NSApp.isRunning)
    }

    @Test(.macOSTestApplication, .macOSUI) @MainActor func nativeClicksPreservePendingMainActorWork() async throws {
        _ = NSApplication.shared
        let panel = NSPanel(contentRect: NSRect(x: 24000, y: 0, width: 100, height: 40),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        let target = NativeClickTarget()
        let button = NSButton(title: "Owned fixture", target: target, action: #selector(NativeClickTarget.pressed(_:)))
        panel.contentView = button
        panel.orderFrontForTesting()
        defer { panel.orderOutForTesting() }
        let (gate, continuation) = AsyncStream<Void>.makeStream()
        let pending = Task { @MainActor in
            for await _ in gate { break }
            return 42
        }
        defer { continuation.finish(); pending.cancel() }
        try performNativeClick(button)
        #expect(target.presses == 1)
        #expect(!NSApp.isRunning)
        continuation.yield(())
        #expect(await pending.value == 42)
        try performNativeClick(button)
        #expect(target.presses == 2)
        await Task.yield()
        #expect(!NSApp.isRunning)
    }
}
