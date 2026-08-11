import AppKit
import Testing
@testable import BetterTileCore
@testable import BetterTileMacOS

@Test @MainActor func fakeEventSourceEmitsDeterministicNativeResizeEvent() {
    let system = FakeWindowSystem()
    var received: WindowSystemEvent?
    system.setWindowEventHandler { received = $0 }
    let event = WindowSystemEvent(kind: .resized, windowID: system.windows[0].id, processIdentifier: 42)
    system.emit(event)
    #expect(received == event)
}

@Test func stageManagerThumbnailFramesAreRejected() {
    let full = BTRect(x: 100, y: 100, width: 800, height: 600)
    let decorated = BTRect(x: 100, y: 99, width: 800, height: 601)
    let thumbnail = BTRect(x: 20, y: 100, width: 160, height: 120)
    #expect(OnscreenWindowMatcher.matches(accessibilityFrame: full, windowServerFrame: decorated))
    #expect(!OnscreenWindowMatcher.matches(accessibilityFrame: full, windowServerFrame: thumbnail))
}

@Test func windowSystemNeverManagesItsOwnApplicationWindows() {
    #expect(!AccessibilityWindowSystem.shouldManageApplication(
        processIdentifier: 42,
        ownProcessIdentifier: 42,
        activationPolicy: .regular,
        isHidden: false,
        includeHidden: false
    ))
    #expect(AccessibilityWindowSystem.shouldManageApplication(
        processIdentifier: 43,
        ownProcessIdentifier: 42,
        activationPolicy: .regular,
        isHidden: false,
        includeHidden: false
    ))
}
