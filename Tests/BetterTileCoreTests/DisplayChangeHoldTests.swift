import Testing
@testable import BetterTileCore

struct DisplayChangeHoldTests {
    let display = DisplaySnapshot(id: DisplayID(rawValue: "test"),
        frame: BTRect(x: 0, y: 0, width: 1000, height: 800),
        visibleFrame: BTRect(x: 0, y: 0, width: 1000, height: 800))

    @Test func equalSamplesSettleAndChangedSamplesRestart() {
        var hold = DisplayChangeHold()
        hold.receive(.screenParametersChanged, at: 0)
        #expect(hold.sample(displaySignature: [display], windowFrames: [:], at: 0, token: hold.token) == nil)
        var changed = display
        changed.visibleFrame.size.height -= 30
        #expect(hold.sample(displaySignature: [changed], windowFrames: [:], at: 0.25, token: hold.token) == nil)
        #expect(hold.sample(displaySignature: [changed], windowFrames: [:], at: 0.49, token: hold.token) == nil)
        #expect(hold.sample(displaySignature: [changed], windowFrames: [:], at: 0.5, token: hold.token) == .settled(token: hold.token))
        #expect(!hold.isHolding)
    }

    @Test func changingWindowsMustAlsoBecomeQuiet() {
        var hold = DisplayChangeHold()
        hold.receive(.wake, at: 0)
        let id = WindowID(rawValue: "window")
        #expect(hold.sample(displaySignature: [display], windowFrames: [:], at: 0, token: hold.token) == nil)
        #expect(hold.sample(displaySignature: [display], windowFrames: [id: display.frame], at: 0.25, token: hold.token) == nil)
        #expect(hold.sample(displaySignature: [display], windowFrames: [id: display.frame], at: 0.5, token: hold.token) != nil)
    }

    @Test func sleepAndInactiveSessionWaitForWakeAndUnlock() {
        var hold = DisplayChangeHold()
        hold.receive(.sleep, at: 0)
        #expect(hold.sample(displaySignature: [display], windowFrames: [:], at: 10, token: hold.token) == nil)
        hold.receive(.sessionResigned, at: 11)
        hold.receive(.wake, at: 12)
        #expect(hold.sample(displaySignature: [display], windowFrames: [:], at: 20, token: hold.token) == nil)
        hold.receive(.sessionBecameActive, at: 21)
        #expect(hold.sample(displaySignature: [display], windowFrames: [:], at: 21, token: hold.token) == nil)
        #expect(hold.sample(displaySignature: [display], windowFrames: [:], at: 21.25, token: hold.token) != nil)
    }

    @Test func missingEndUsesDeadlineAndRejectsOldToken() {
        var hold = DisplayChangeHold()
        hold.receive(.displayReconfigurationBegan, at: 0)
        let old = hold.token
        #expect(hold.sample(displaySignature: [display], windowFrames: [:], at: 0, token: old) == nil)
        #expect(hold.sample(displaySignature: [display], windowFrames: [:], at: 1, token: old) == nil)
        hold.receive(.screenParametersChanged, at: 2)
        #expect(hold.sample(displaySignature: [display], windowFrames: [:], at: 7, token: old) == nil)
        #expect(hold.sample(displaySignature: [], windowFrames: nil, at: 6.99, token: hold.token) == nil)
        #expect(hold.sample(displaySignature: [], windowFrames: nil, at: 7, token: hold.token) == .settled(token: hold.token))
    }
}

@Test func displayArrangementIgnoresWorkAreasButNotFramesOrPixels() {
    let display = DisplaySnapshot(id: DisplayID(rawValue: "test"),
        frame: BTRect(x: 0, y: 0, width: 1000, height: 800),
        visibleFrame: BTRect(x: 0, y: 0, width: 1000, height: 800))
    var dock = display
    dock.visibleFrame.size.height = 740
    var moved = display
    moved.frame.origin.x = 1000
    var sharper = display
    sharper.scaleFactor = 2
    #expect(DisplayArrangement([dock]) == DisplayArrangement([display]))
    #expect(DisplayArrangement([moved]) != DisplayArrangement([display]))
    #expect(DisplayArrangement([sharper]) != DisplayArrangement([display]))
    #expect(DisplayArrangement([]) != DisplayArrangement([display]))
}

@Test func theLimitIsKnownBeforeASampleAndSleepStillWaits() {
    var hold = DisplayChangeHold()
    hold.receive(.displayReconfigurationBegan, at: 0)
    #expect(!hold.isPastLimit(at: 4.99))
    #expect(hold.isPastLimit(at: 5))
    hold.receive(.sleep, at: 6)
    #expect(!hold.isPastLimit(at: 20))
}

@Test func anUnchangedReconfigurationReleasesOnlyWhenNothingElseHolds() {
    var hold = DisplayChangeHold()
    hold.receive(.displayReconfigurationBegan, at: 0)
    #expect(hold.releaseUnchanged(token: hold.token) == nil)
    hold.receive(.displayReconfigurationEnded, at: 0.1)
    let old = hold.token
    hold.receive(.sleep, at: 0.2)
    #expect(hold.releaseUnchanged(token: old) == nil)
    #expect(hold.releaseUnchanged(token: hold.token) == nil)
    hold.receive(.wake, at: 0.3)
    #expect(hold.releaseUnchanged(token: hold.token) == .settled(token: hold.token))
    #expect(!hold.isHolding && !hold.settledByLimit)
}

@Test func displayHoldTransitionPreservesPendingWorkAreaReflow() throws {
    let id = DisplayID(rawValue: "screen")
    let old = BTRect(x: 0, y: 0, width: 1000, height: 800)
    let new = BTRect(x: 0, y: 0, width: 1400, height: 900)
    let windows = (0..<2).map { index in
        WindowSnapshot(id: WindowID(rawValue: "w-\(index)"), processIdentifier: 1,
            frame: BTRect(x: Double(index) * 500, y: 0, width: 500, height: 800), displayID: id)
    }
    let tree = BentoLayoutState(root: .partition(BentoPartition(axis: .vertical, children: windows.map { .leaf($0.id) })))
    let session = LayoutSession(displayID: id, mode: .bento, bentoState: tree,
        windowIDs: Set(windows.map(\.id)), lastWorkArea: old)
    let display = DisplaySnapshot(id: id, frame: new, visibleFrame: new)
    let reducer = AmbientLayoutReconciler(paneGap: 0, adjacencyTolerance: 8, singleWindowPlacement: nil)
    let transition = reducer.transition(session: session, observation: AmbientLayoutObservation(
        display: display, windows: windows, wasCreated: false, previousWindowIDs: session.windowIDs,
        isDesktopTransition: true))
    #expect(transition.session.lastWorkArea == old, "The display-transition sweep must not mark unwritten geometry as settled")
    let ordinary = reducer.transition(session: transition.session, observation: AmbientLayoutObservation(
        display: display, windows: windows, wasCreated: false, previousWindowIDs: session.windowIDs,
        isDesktopTransition: false))
    guard case let .applyLayout(_, placements, _) = ordinary else {
        Issue.record("The ordinary sweep must reflow the retained tree to the new work area")
        return
    }
    #expect(placements.map(\.frame.maxX).max() == new.maxX)
}
