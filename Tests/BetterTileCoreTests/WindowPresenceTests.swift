import Foundation
import Testing
@testable import BetterTileCore

private let a = WindowID(rawValue: "a")
private let b = WindowID(rawValue: "b")
private let c = WindowID(rawValue: "c")

/// The reported collapse: a shortcut on a two-pane layout produced a single
/// placement covering the whole display, because the other window was missing
/// from one sweep and its pane had already been given up. One unlucky
/// observation must not be enough.
@Test func oneMissedSweepDoesNotGiveUpAPane() {
    var tracker = WindowPresenceTracker()
    #expect(tracker.observe(known: [a, b], present: [a]).isEmpty)
    #expect(tracker.pending[b] == 1)
}

@Test func aWindowThatComesBackKeepsItsPane() {
    var tracker = WindowPresenceTracker()
    _ = tracker.observe(known: [a, b], present: [a])
    _ = tracker.observe(known: [a, b], present: [a])
    #expect(tracker.pending[b] == 2)

    #expect(tracker.observe(known: [a, b], present: [a, b]).isEmpty)
    #expect(tracker.pending[b] == nil, "the tally resets rather than accumulating across gaps")
}

@Test func aWindowMissingForLongEnoughIsFinallyRemoved() {
    var tracker = WindowPresenceTracker()
    #expect(tracker.observe(known: [a, b], present: [a]).isEmpty)
    #expect(tracker.observe(known: [a, b], present: [a]).isEmpty)
    #expect(tracker.observe(known: [a, b], present: [a]) == [b])
    #expect(tracker.pending[b] == nil, "the tally is cleared once the pane is released")
}

/// A destroyed event is direct evidence rather than an inference from silence,
/// so it must not wait out the tolerance.
@Test func aConfirmedDestroyedWindowIsReleasedImmediately() {
    var tracker = WindowPresenceTracker()
    #expect(tracker.observe(known: [a, b], present: [a], confirmedGone: [b]) == [b])
}

@Test func aConfirmedWindowIsReleasedEvenMidWait() {
    var tracker = WindowPresenceTracker()
    _ = tracker.observe(known: [a, b], present: [a])
    #expect(tracker.observe(known: [a, b], present: [a], confirmedGone: [b]) == [b])
}

/// Windows the layout is deliberately hiding are absent by design; they must
/// not accumulate absences and quietly lose their place while hidden.
@Test func deliberatelyHiddenWindowsNeverAccumulateAbsences() {
    var tracker = WindowPresenceTracker()
    for _ in 0..<10 {
        #expect(tracker.observe(known: [a, b], present: [a], exempt: [b]).isEmpty)
    }
    #expect(tracker.pending[b] == nil)
}

@Test func exemptionOutranksAPartialWait() {
    var tracker = WindowPresenceTracker()
    _ = tracker.observe(known: [a, b], present: [a])
    #expect(tracker.pending[b] == 1)
    _ = tracker.observe(known: [a, b], present: [a], exempt: [b])
    #expect(tracker.pending[b] == nil)
}

/// A window the layout no longer holds must not leave a tally behind for a
/// later window to inherit.
@Test func talliesAreDroppedWhenTheLayoutForgetsAWindow() {
    var tracker = WindowPresenceTracker()
    _ = tracker.observe(known: [a, b], present: [a])
    #expect(tracker.pending[b] == 1)
    _ = tracker.observe(known: [a], present: [a])
    #expect(tracker.pending[b] == nil)

    // b returns as a fresh pane and gets the full tolerance again.
    #expect(tracker.observe(known: [a, b], present: [a]).isEmpty)
    #expect(tracker.pending[b] == 1)
}

@Test func severalWindowsAreTrackedIndependently() {
    var tracker = WindowPresenceTracker()
    _ = tracker.observe(known: [a, b, c], present: [a])
    _ = tracker.observe(known: [a, b, c], present: [a, b])
    #expect(tracker.pending[b] == nil)
    #expect(tracker.pending[c] == 2)
    #expect(tracker.observe(known: [a, b, c], present: [a, b]) == [c])
}

@Test func zeroToleranceRestoresImmediateRemoval() {
    var tracker = WindowPresenceTracker(toleratedAbsences: 0)
    #expect(tracker.observe(known: [a, b], present: [a]) == [b])
}

@Test func aNegativeToleranceIsClampedRatherThanTrusted() {
    let tracker = WindowPresenceTracker(toleratedAbsences: -5)
    #expect(tracker.toleratedAbsences == 0)
}

@Test func anEmptyLayoutRemovesNothing() {
    var tracker = WindowPresenceTracker()
    #expect(tracker.observe(known: [], present: [a, b]).isEmpty)
    #expect(tracker.pending.isEmpty)
}

@Test func forgettingAndResettingClearTallies() {
    var tracker = WindowPresenceTracker()
    _ = tracker.observe(known: [a, b, c], present: [a])
    tracker.forget(b)
    #expect(tracker.pending[b] == nil)
    #expect(tracker.pending[c] == 1)
    tracker.reset()
    #expect(tracker.pending.isEmpty)
}

/// A session carries its tracker, so the tolerance survives the reconcile that
/// rebuilds the rest of the session state.
@Test func aLayoutSessionCarriesItsPresenceTracker() {
    var session = LayoutSession(displayID: DisplayID(rawValue: "d"), mode: .bento)
    #expect(session.presence.pending.isEmpty)
    _ = session.presence.observe(known: [a, b], present: [a])
    #expect(session.presence.pending[b] == 1)
}

// MARK: - Placement bounds

private let screen = BTRect(x: 0, y: 0, width: 1920, height: 983)

@Test func aPlacementInsideTheDisplayIsReachable() {
    #expect(PlacementBounds.isReachable(BTRect(x: 0, y: 0, width: 960, height: 983), in: screen))
}

@Test func aPlacementMostlyOffScreenIsRejected() {
    #expect(!PlacementBounds.isReachable(BTRect(x: 1800, y: 0, width: 960, height: 983), in: screen))
}

@Test func aPlacementEntirelyOffScreenIsRejected() {
    #expect(!PlacementBounds.isReachable(BTRect(x: 4000, y: 0, width: 400, height: 400), in: screen))
    #expect(!PlacementBounds.isReachable(BTRect(x: -900, y: 0, width: 400, height: 400), in: screen))
}

/// A window may legitimately overhang a little; the rule is about frames that
/// leave nothing to grab, not about pixel-perfect containment.
@Test func aSlightOverhangIsStillReachable() {
    #expect(PlacementBounds.isReachable(BTRect(x: -20, y: -10, width: 960, height: 983), in: screen))
}

@Test func aDegeneratePlacementIsNotReachable() {
    #expect(!PlacementBounds.isReachable(BTRect(x: 0, y: 0, width: 0, height: 500), in: screen))
}

/// Unknown display bounds must not cause every placement to be rejected.
@Test func unknownDisplayBoundsDoNotBlockPlacement() {
    #expect(
        PlacementBounds.isReachable(
            BTRect(x: 0, y: 0, width: 400, height: 400),
            in: BTRect(x: 0, y: 0, width: 0, height: 0)
        )
    )
}

// MARK: - Placement verification

private let requested = BTRect(x: 960, y: 30, width: 960, height: 983)

@Test func aWindowAtTheRequestedFrameLanded() {
    #expect(PlacementVerifier.outcome(requested: requested, actual: requested) == .landed)
}

@Test func subPointDriftStillCountsAsLanded() {
    let actual = BTRect(x: 960.5, y: 30.5, width: 959.6, height: 982.7)
    #expect(PlacementVerifier.outcome(requested: requested, actual: actual) == .landed)
}

/// The case behind the reported confusion: the window is where it was asked to
/// be but kept a size of its own. Reported as resisted, not as failure, because
/// the position is right and the layout can adapt.
@Test func aWindowThatKeptItsOwnSizeIsResistedNotFailed() {
    let actual = BTRect(x: 960, y: 30, width: 655, height: 800)
    #expect(PlacementVerifier.outcome(requested: requested, actual: actual) == .resisted(actual: actual))
}

@Test func aWindowInTheWrongPlaceFails() {
    let actual = BTRect(x: 0, y: 30, width: 960, height: 983)
    #expect(PlacementVerifier.outcome(requested: requested, actual: actual) == .failed(actual: actual))
}

/// Position is judged more strictly than size: a window in the wrong place is
/// the failure people notice, a window of the wrong size usually is not.
@Test func positionIsJudgedMoreStrictlyThanSize() {
    let wrongSizeOnly = BTRect(x: 960, y: 30, width: 700, height: 983)
    let wrongPlaceOnly = BTRect(x: 900, y: 30, width: 960, height: 983)
    #expect(PlacementVerifier.outcome(requested: requested, actual: wrongSizeOnly) != .failed(actual: wrongSizeOnly))
    #expect(PlacementVerifier.outcome(requested: requested, actual: wrongPlaceOnly) == .failed(actual: wrongPlaceOnly))
}
