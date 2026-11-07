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

/// Desktop membership is weaker evidence than a deliberate hide: it buys a
/// longer wait, not a permanent pane.
@Test func membershipOnlyWindowsGetALongerButFiniteBudget() {
    var tracker = WindowPresenceTracker(toleratedAbsences: 2, toleratedMembershipOnlyAbsences: 4)
    for _ in 0..<4 {
        #expect(tracker.observe(known: [a, b], present: [a], membershipOnly: [b]).isEmpty)
    }
    #expect(tracker.pending[b] == 4)
    #expect(tracker.observe(known: [a, b], present: [a], membershipOnly: [b]) == [b])
    #expect(tracker.pending[b] == nil)
}

@Test func losingDesktopMembershipFallsBackToTheShortBudget() {
    var tracker = WindowPresenceTracker(toleratedAbsences: 2, toleratedMembershipOnlyAbsences: 4)
    for _ in 0..<3 {
        #expect(tracker.observe(known: [a, b], present: [a], membershipOnly: [b]).isEmpty)
    }
    #expect(tracker.observe(known: [a, b], present: [a]) == [b],
            "a window that already missed more than the short budget goes once membership no longer covers it")
}

/// Events make sweeps frequent, so the count of misses alone can pass in a
/// fraction of a second. With a time, a window known only by desktop
/// membership also waits the minimum absence from its first miss.
@Test func membershipOnlyWindowsAlsoWaitAMinimumTime() {
    var tracker = WindowPresenceTracker(
        toleratedAbsences: 2, toleratedMembershipOnlyAbsences: 4, minimumMembershipOnlyAbsence: .milliseconds(1_400))
    let start = ContinuousClock().now // real-time: base instant only; every observation uses fixed offsets
    for sweep in 0..<10 {
        #expect(tracker.observe(known: [a, b], present: [a], membershipOnly: [b],
                                now: start.advanced(by: .milliseconds(100 * sweep))).isEmpty,
                "sweep \(sweep) is still inside the minimum time")
    }
    #expect(tracker.pending[b] == 10)
    #expect(tracker.observe(known: [a, b], present: [a], membershipOnly: [b],
                            now: start.advanced(by: .milliseconds(1_400))) == [b])
    #expect(tracker.pending[b] == nil)
    #expect(tracker.membershipOnlyAbsenceStarts.isEmpty)
}

/// The time does not replace the count: a slow series of misses still needs
/// the full membership budget.
@Test func theMinimumTimeDoesNotShortenTheMembershipBudget() {
    var tracker = WindowPresenceTracker(
        toleratedAbsences: 2, toleratedMembershipOnlyAbsences: 4, minimumMembershipOnlyAbsence: .milliseconds(1_400))
    let start = ContinuousClock().now // real-time: base instant only; every observation uses fixed offsets
    for sweep in 0..<4 {
        #expect(tracker.observe(known: [a, b], present: [a], membershipOnly: [b],
                                now: start.advanced(by: .seconds(sweep))).isEmpty)
    }
    #expect(tracker.observe(known: [a, b], present: [a], membershipOnly: [b],
                            now: start.advanced(by: .seconds(4))) == [b])
}

/// A new run of misses starts a new minimum time. Direct evidence and the
/// short budget do not wait for it.
@Test func theMinimumTimeRestartsAndYieldsToDirectEvidence() {
    var tracker = WindowPresenceTracker(
        toleratedAbsences: 2, toleratedMembershipOnlyAbsences: 4, minimumMembershipOnlyAbsence: .milliseconds(1_400))
    let start = ContinuousClock().now // real-time: base instant only; every observation uses fixed offsets
    func at(_ ms: Int) -> ContinuousClock.Instant { start.advanced(by: .milliseconds(ms)) }
    for sweep in 0..<6 {
        _ = tracker.observe(known: [a, b], present: [a], membershipOnly: [b], now: at(100 * sweep))
    }
    // b is seen again, then missed again: the time counts from the new miss.
    _ = tracker.observe(known: [a, b], present: [a, b], now: at(700))
    #expect(tracker.membershipOnlyAbsenceStarts[b] == nil)
    for sweep in 0..<6 {
        #expect(tracker.observe(known: [a, b], present: [a], membershipOnly: [b], now: at(800 + 100 * sweep)).isEmpty)
    }
    #expect(tracker.observe(known: [a, b], present: [a], membershipOnly: [b], now: at(2_200)) == [b])

    // A destroyed event removes at once.
    _ = tracker.observe(known: [a, c], present: [a], membershipOnly: [c], now: at(3_000))
    #expect(tracker.observe(known: [a, c], present: [a], confirmedGone: [c], membershipOnly: [c], now: at(3_100)) == [c])
    // Without membership, the short budget applies with no minimum time.
    for sweep in 0..<2 {
        #expect(tracker.observe(known: [a, b], present: [a], now: at(4_000 + 10 * sweep)).isEmpty)
    }
    #expect(tracker.observe(known: [a, b], present: [a], now: at(4_020)) == [b])
}

@Test func theMembershipBudgetIsNeverShorterThanTheOrdinaryOne() {
    let tracker = WindowPresenceTracker(toleratedAbsences: 3, toleratedMembershipOnlyAbsences: 1)
    #expect(tracker.toleratedMembershipOnlyAbsences == 3)
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

// MARK: - History Restore bounds

@Test func historyRestoreBoundsAcceptsLargeSpanningWindowOnNegativeOriginDisplays() {
    let displays = [
        BTRect(x: -1_000, y: 0, width: 1_000, height: 800),
        BTRect(x: 0, y: 0, width: 1_000, height: 800)
    ]
    let spanning = BTRect(x: -90_000, y: 100, width: 180_000, height: 400)
    #expect(PlacementBounds.isHistoryRestoreReachable(spanning, in: displays))
    for display in displays {
        #expect(PlacementBounds.isHistoryRestoreReachable(spanning, in: [display]))
    }
}

@Test(arguments: [(9.9, false), (10.0, true), (10.1, true)])
func historyRestoreBoundsRequiresMinimumTitleStripArea(visibleWidth: Double, reachable: Bool) {
    let display = BTRect(x: 0, y: 0, width: 1_000, height: 800)
    let frame = BTRect(x: 1_000 - visibleWidth, y: 200, width: 600, height: 400)
    #expect(PlacementBounds.isHistoryRestoreReachable(frame, in: [display]) == reachable)
}

@Test(arguments: [(1.0, false), (2.0, true), (3.0, true)])
func historyRestoreBoundsRequiresMinimumPartiallyVisibleTitleStripArea(visibleHeight: Double, reachable: Bool) {
    let display = BTRect(x: 0, y: 0, width: 1_000, height: 800)
    let frame = BTRect(x: 890, y: 800 - visibleHeight, width: 600, height: 600)
    #expect(PlacementBounds.isHistoryRestoreReachable(frame, in: [display]) == reachable)
}

@Test(arguments: [
    (BTRect(x: 100, y: 100, width: 8, height: 400), true),
    (BTRect(x: 100, y: 100, width: 200, height: 1), true),
    (BTRect(x: 996, y: 100, width: 8, height: 400), false)
])
func historyRestoreBoundsAcceptsWholeStripSmallerThanMinimum(frame: BTRect, reachable: Bool) {
    let display = BTRect(x: 0, y: 0, width: 1_000, height: 800)
    #expect(PlacementBounds.isHistoryRestoreReachable(frame, in: [display]) == reachable)
}

@Test func historyRestoreBoundsDoesNotCombineSmallFragments() {
    let displays = [
        BTRect(x: 0, y: 0, width: 5, height: 800),
        BTRect(x: 10, y: 0, width: 5, height: 800)
    ]
    #expect(!PlacementBounds.isHistoryRestoreReachable(
        BTRect(x: 0, y: 100, width: 600, height: 400), in: displays))
}

@Test func historyRestoreBoundsRejectsTitleBarInOffsetDisplayGap() {
    let displays = [
        BTRect(x: 0, y: 0, width: 1_000, height: 800),
        BTRect(x: 1_000, y: 300, width: 1_000, height: 800)
    ]
    #expect(!PlacementBounds.isHistoryRestoreReachable(
        BTRect(x: 1_100, y: 150, width: 600, height: 400), in: displays))
    #expect(!PlacementBounds.isHistoryRestoreReachable(
        BTRect(x: 0, y: 0, width: 600, height: 400), in: []))
}

@Test(arguments: [(-22.0, false), (-21.0, true), (779.0, true), (800.0, false)])
func historyRestoreBoundsRequiresTitleBarIntersection(y: Double, reachable: Bool) {
    let display = BTRect(x: 0, y: 0, width: 1_000, height: 800)
    let frame = BTRect(x: 200, y: y, width: 600, height: 400)
    #expect(PlacementBounds.isHistoryRestoreReachable(frame, in: [display]) == reachable)
}

@Test(arguments: [
    BTRect(x: 0, y: 0, width: 0, height: 400),
    BTRect(x: 0, y: 0, width: 600, height: -400),
    BTRect(x: .infinity, y: 0, width: 600, height: 400),
    BTRect(x: 0, y: .nan, width: 600, height: 400)
])
func historyRestoreBoundsRejectsInvalidFrames(frame: BTRect) {
    #expect(!PlacementBounds.isHistoryRestoreReachable(frame, in: [screen]))
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
@Test(arguments: [BTRect(x: 960, y: 30, width: 655, height: 800), BTRect(x: 960, y: 30, width: 700, height: 983)])
func aWindowThatKeptItsOwnSizeIsResistedNotFailed(actual: BTRect) {
    #expect(PlacementVerifier.outcome(requested: requested, actual: actual) == .resisted(actual: actual))
}

@Test(arguments: [BTRect(x: 0, y: 30, width: 960, height: 983), BTRect(x: 900, y: 30, width: 960, height: 983)])
func aWindowInTheWrongPlaceFails(actual: BTRect) {
    #expect(PlacementVerifier.outcome(requested: requested, actual: actual) == .failed(actual: actual))
}

// MARK: - Bento containment

/// Bento panes are derived from the whole work area, so "mostly on screen" is
/// not good enough for one: a pane that overhangs is a bad proposal even though
/// the same frame would be a perfectly reasonable window to place by hand.
@Test func bentoContainmentIsStricterThanReachability() {
    let overhanging = BTRect(x: -20, y: -10, width: 960, height: 983)
    #expect(PlacementBounds.isReachable(overhanging, in: screen))
    #expect(!PlacementBounds.isContained(overhanging, in: screen))
}

@Test func aPaneFillingTheWorkAreaIsContained() {
    #expect(PlacementBounds.isContained(screen, in: screen))
}

/// Derived frames carry rounding, so containment tolerates sub-point error
/// without tolerating a window actually leaving the work area.
@Test func containmentToleratesRoundingButNotRealOverhang() {
    #expect(PlacementBounds.isContained(BTRect(x: -0.3, y: 0, width: 960, height: 983), in: screen))
    #expect(!PlacementBounds.isContained(BTRect(x: -4, y: 0, width: 960, height: 983), in: screen))
}

@Test func aPaneRunningPastTheFarEdgeIsNotContained() {
    #expect(!PlacementBounds.isContained(BTRect(x: 1000, y: 0, width: 960, height: 983), in: screen))
    #expect(!PlacementBounds.isContained(BTRect(x: 0, y: 30, width: 1920, height: 983), in: screen))
}

@Test func aDegeneratePaneIsNotContained() {
    #expect(!PlacementBounds.isContained(BTRect(x: 0, y: 0, width: 0, height: 500), in: screen))
}

/// A confirmed-gone identifier for a window the layout does not hold is inert.
/// That is what makes it safe to hand a whole sweep's batch of destroyed
/// identifiers to every display: identifiers belonging to another display, to a
/// manual-mode desktop, or to a session that was never initialised cannot evict
/// anything.
@Test func aConfirmedGoneIdentifierForAnUnheldWindowDoesNothing() {
    var tracker = WindowPresenceTracker()
    #expect(tracker.observe(known: [a], present: [a], confirmedGone: [b, c]).isEmpty)
    #expect(tracker.pending.isEmpty)
}
