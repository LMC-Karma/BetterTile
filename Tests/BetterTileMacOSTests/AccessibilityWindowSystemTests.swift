import AppKit
import Testing
@testable import BetterTileCore
@testable import BetterTileMacOS

@Test func stageManagerThumbnailFramesAreRejected() {
    let full = BTRect(x: 100, y: 100, width: 800, height: 600)
    let decorated = BTRect(x: 100, y: 99, width: 800, height: 601)
    let thumbnail = BTRect(x: 20, y: 100, width: 160, height: 120)
    #expect(OnscreenWindowMatcher.matches(accessibilityFrame: full, windowServerFrame: decorated))
    #expect(!OnscreenWindowMatcher.matches(accessibilityFrame: full, windowServerFrame: thumbnail))
}

/// Another running instance of the application still uses the seed.
@Test func quitApplicationLosesItsSeedOnlyWhenNoInstanceStillRuns() {
    let forgotten = AccessibilityWindowSystem.minimumSizeSeedsToForget(
        quitApplications: ["com.apple.mail", "com.apple.Terminal"],
        runningApplications: ["com.apple.Terminal", "com.apple.finder"]
    )
    #expect(forgotten == ["com.apple.mail"])
    #expect(AccessibilityWindowSystem.minimumSizeSeedsToForget(
        quitApplications: [], runningApplications: ["com.apple.finder"]
    ).isEmpty)
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

/// A failed read of a title-bar button, or of its enabled state, is not
/// evidence for a popup verdict; only an absent attribute is.
@Test func popupButtonReadsMapFailuresToUnreadable() {
    typealias System = AccessibilityWindowSystem
    #expect(System.buttonState(reference: .attributeUnsupported, enabled: nil) == .missing)
    #expect(System.buttonState(reference: .noValue, enabled: nil) == .missing)
    #expect(System.buttonState(reference: .cannotComplete, enabled: nil) == .unreadable)
    #expect(System.buttonState(reference: .success, enabled: (.success, false)) == .disabled)
    #expect(System.buttonState(reference: .success, enabled: (.success, true)) == .enabled)
    #expect(System.buttonState(reference: .success, enabled: (.attributeUnsupported, nil)) == .enabled)
    #expect(System.buttonState(reference: .success, enabled: (.cannotComplete, nil)) == .unreadable)
}
