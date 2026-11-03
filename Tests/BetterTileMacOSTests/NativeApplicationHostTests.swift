import AppKit
import Testing

@Test(.macOSTestApplication, .macOSUI) @MainActor
func ownedNativeApplicationLoopStaysAccessoryAndInactive() throws {
    let activeBefore = NSRunningApplication.current.isActive
    try #require(!activeBefore)
    try withNativeEventLoop {
        #expect(NativeHostPolicyReading.current(of: NSApp) == .accessory)
        #expect(!NSApp.isRunning && NativeEventLoopState.isRunning)
        let activeInside = NSRunningApplication.current.isActive
        #expect(!activeInside)
    }
    let activeAfter = NSRunningApplication.current.isActive
    #expect(!activeAfter)
}
