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

/// A process that quits takes its applications' seeds with it: those of the
/// windows it had and the one its launch record names. Another application's
/// seed and every window's own measurement stay.
@Test func aQuitProcessDropsItsApplicationsSeedsOnly() {
    var learner = WindowMinimumSizeLearner()
    let mail = WindowID(rawValue: "mail"), notes = WindowID(rawValue: "notes")
    func measure(_ id: WindowID, _ application: String) {
        _ = learner.observeWriteReadback(windowID: id, application: application,
            requested: BTRect(x: 0, y: 0, width: 100, height: 100), previous: BTRect(x: 0, y: 0, width: 800, height: 600),
            actual: BTRect(x: 0, y: 0, width: 500, height: 375))
    }
    measure(mail, "com.apple.mail")
    measure(notes, "com.apple.Notes")
    let keys = [mail: "com.apple.mail", notes: "com.apple.Notes"]

    let quit = AccessibilityWindowSystem.quitApplicationBundles(
        closedWindowIDs: [mail], applicationKeys: keys, launchBundleIdentifier: nil
    )
    #expect(quit == ["com.apple.mail"])
    #expect(AccessibilityWindowSystem.forgetSeeds(of: quit, in: &learner) == ["com.apple.mail"])
    #expect(learner.applicationSizes["com.apple.mail"] == nil)
    #expect(learner.applicationSizes["com.apple.Notes"] != nil)
    #expect(learner.hasMeasurement(for: mail))

    // A process that quit without windows is known by its launch record.
    let windowless = AccessibilityWindowSystem.quitApplicationBundles(
        closedWindowIDs: [], applicationKeys: keys, launchBundleIdentifier: "com.apple.Notes"
    )
    #expect(windowless == ["com.apple.Notes"])
    #expect(AccessibilityWindowSystem.forgetSeeds(of: windowless, in: &learner) == ["com.apple.Notes"])
    #expect(learner.applicationSizes.isEmpty)
    // Nothing left to drop.
    #expect(AccessibilityWindowSystem.forgetSeeds(of: windowless, in: &learner).isEmpty)
}

/// A process registered without a name learns it from its own windows, so
/// its seed can be dropped when it quits; a named or older record does not.
@Test func aLaunchRecordLearnsItsBundleIdentifierOnlyFromItsOwnLaunch() {
    let current = ApplicationLaunchInstance(processIdentifier: 42, generation: 2)
    let earlier = ApplicationLaunchInstance(processIdentifier: 42, generation: 1)
    #expect(AccessibilityWindowSystem.recordLearnsBundleIdentifier(
        recordInstance: current, recordBundleIdentifier: nil, windowInstance: current))
    #expect(!AccessibilityWindowSystem.recordLearnsBundleIdentifier(
        recordInstance: current, recordBundleIdentifier: "com.apple.mail", windowInstance: current))
    #expect(!AccessibilityWindowSystem.recordLearnsBundleIdentifier(
        recordInstance: earlier, recordBundleIdentifier: nil, windowInstance: current))
}


/// Only two real answers make a window unmovable. An application that did
/// not answer leaves the question open, so a drag asks again on its next
/// tick instead of keeping the window still for the rest of the drag.
@Test func movabilityNeedsAnAnswerBeforeAWindowCountsAsUnmovable() {
    #expect(AccessibilityWindowSystem.movability(position: true, size: nil) == true)
    #expect(AccessibilityWindowSystem.movability(position: false, size: true) == true)
    #expect(AccessibilityWindowSystem.movability(position: false, size: false) == false)
    #expect(AccessibilityWindowSystem.movability(position: nil, size: nil) == nil)
    #expect(AccessibilityWindowSystem.movability(position: false, size: nil) == nil)
}

/// Only a successful read that names the window confirms focus. An
/// application without a focused window, or a failed read, proves nothing.
@Test func applicationFocusRequiresAPositiveRead() {
    func focus(_ result: AXError, role: String? = "AXWindow", subrole: String? = "AXStandardWindow",
               matches: Bool = false) -> ApplicationFocusMatch {
        AccessibilityWindowSystem.applicationFocus(readResult: result, focusedRole: role,
                                                   focusedSubrole: subrole, matchesWindow: matches)
    }
    #expect(focus(.success, matches: true) == .confirmed)
    #expect(focus(.success) == .otherWindow(isTransientPopup: false))
    #expect(focus(.success, subrole: "AXUnknown") == .otherWindow(isTransientPopup: true))
    #expect(focus(.success, subrole: "AXDialog") == .otherWindow(isTransientPopup: false))
    // Finder's desktop is a scroll area; no window has focus.
    #expect(focus(.success, role: "AXScrollArea", subrole: nil) == .noWindow)
    #expect(focus(.noValue, role: nil, subrole: nil) == .noWindow)
    #expect(focus(.cannotComplete, role: nil, subrole: nil) == .unknown)
    #expect(focus(.attributeUnsupported, role: nil, subrole: nil) == .unknown)
    #expect(focus(.apiDisabled, matches: true) == .unknown)
}
