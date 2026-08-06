import Foundation
import Testing
@testable import BetterTileCore

private let sessionDisplay = DisplayID(rawValue: "main")

@Test func activeWindowsUseOneImmediateSessionPerDisplay() {
    var store = LayoutSessionStore()
    let a1 = WindowID(rawValue: "a1")
    let a2 = WindowID(rawValue: "a2")
    let b1 = WindowID(rawValue: "b1")

    store.refresh(displayID: sessionDisplay, windowIDs: [a1, a2], focusedWindowID: a1, defaultMode: .manual)
    store.update(sessionDisplay) { $0.mode = .bento }
    let refreshed = store.refresh(displayID: sessionDisplay, windowIDs: [b1], focusedWindowID: b1, defaultMode: .linked)

    #expect(store.sessions.count == 1)
    #expect(refreshed.mode == .bento)
    #expect(refreshed.windowIDs == [b1])
    #expect(refreshed.focusedWindowID == b1)
}

@Test func openingAndClosingWindowsUpdatesTheDisplaySessionImmediately() {
    var store = LayoutSessionStore()
    let a = WindowID(rawValue: "a")
    let b = WindowID(rawValue: "b")
    let c = WindowID(rawValue: "c")
    store.refresh(displayID: sessionDisplay, windowIDs: [a, b], focusedWindowID: a, defaultMode: .bento)
    let afterOpen = store.refresh(displayID: sessionDisplay, windowIDs: [a, b, c], focusedWindowID: c, defaultMode: .manual)
    let afterClose = store.refresh(displayID: sessionDisplay, windowIDs: [a, c], focusedWindowID: a, defaultMode: .manual)
    #expect(afterOpen.windowIDs == [a, b, c])
    #expect(afterClose.windowIDs == [a, c])
    #expect(afterClose.mode == .bento)
}

@Test func displaysHaveIndependentSessions() {
    var store = LayoutSessionStore()
    let second = DisplayID(rawValue: "second")
    store.refresh(displayID: sessionDisplay, windowIDs: [WindowID(rawValue: "a")], focusedWindowID: nil, defaultMode: .manual)
    store.refresh(displayID: second, windowIDs: [WindowID(rawValue: "b")], focusedWindowID: nil, defaultMode: .bento)
    #expect(store.session(for: sessionDisplay)?.mode == .manual)
    #expect(store.session(for: second)?.mode == .bento)
    #expect(store.sessions.count == 2)
}

@Test func aDisplaySessionExistsWithoutWaitingForWindows() {
    var store = LayoutSessionStore()
    let session = store.refresh(displayID: sessionDisplay, windowIDs: [], focusedWindowID: nil, defaultMode: .linked)
    #expect(session.mode == .linked)
    #expect(session.windowIDs.isEmpty)
    #expect(store.session(for: sessionDisplay) != nil)
}

@Test func restoredFocusWindowBecomesEligibleForBentoAgain() {
    let restored = WindowID(rawValue: "restored")
    var session = LayoutSession(
        displayID: sessionDisplay,
        mode: .bento,
        bentoState: BentoLayoutState(floatingWindowIDs: [restored]),
        excludedFocusWindowIDs: [restored]
    )

    session.reincludeInBento([restored])

    #expect(!session.excludedFocusWindowIDs.contains(restored))
    #expect(!session.bentoState.floatingWindowIDs.contains(restored))
    #expect(session.automaticallyFloatingWindowIDs.contains(restored))
}

@Test func aLoneWindowIsPlacedOnceAndThenLeftAlone() {
    var session = LayoutSession(displayID: sessionDisplay, mode: .manual)
    let empty = session.shouldApplySingleWindowPlacement(eligibleWindowCount: 0)
    let becameSolo = session.shouldApplySingleWindowPlacement(eligibleWindowCount: 1)
    let sweptAgain = session.shouldApplySingleWindowPlacement(eligibleWindowCount: 1)
    let sweptOnceMore = session.shouldApplySingleWindowPlacement(eligibleWindowCount: 1)
    #expect(!empty)
    #expect(becameSolo)
    // The later sweeps are what let a manual resize survive.
    #expect(!sweptAgain)
    #expect(!sweptOnceMore)
    #expect(session.hasAppliedSingleWindowPlacement)
}

@Test func closingBackToOneWindowPlacesItAgain() {
    var session = LayoutSession(displayID: sessionDisplay, mode: .bento)
    let firstSolo = session.shouldApplySingleWindowPlacement(eligibleWindowCount: 1)
    let secondOpened = session.shouldApplySingleWindowPlacement(eligibleWindowCount: 2)
    let reArmed = !session.hasAppliedSingleWindowPlacement
    let soloAgain = session.shouldApplySingleWindowPlacement(eligibleWindowCount: 1)
    #expect(firstSolo)
    #expect(!secondOpened)
    #expect(reArmed, "leaving one window re-arms the placement")
    #expect(soloAgain)
    #expect(session.hasAppliedSingleWindowPlacement)
}

@Test func aDesktopFirstSeenWithSeveralWindowsStillPlacesItsLastSurvivor() {
    var session = LayoutSession(displayID: sessionDisplay, mode: .bento)
    let three = session.shouldApplySingleWindowPlacement(eligibleWindowCount: 3)
    let two = session.shouldApplySingleWindowPlacement(eligibleWindowCount: 2)
    let survivor = session.shouldApplySingleWindowPlacement(eligibleWindowCount: 1)
    #expect(!three)
    #expect(!two)
    #expect(survivor, "a crowded first observation must not disqualify the desktop forever")
}

@Test func anEmptyDesktopReArmsTheSingleWindowPlacement() {
    var session = LayoutSession(displayID: sessionDisplay, mode: .manual)
    let solo = session.shouldApplySingleWindowPlacement(eligibleWindowCount: 1)
    let emptied = session.shouldApplySingleWindowPlacement(eligibleWindowCount: 0)
    let soloAgain = session.shouldApplySingleWindowPlacement(eligibleWindowCount: 1)
    #expect(solo)
    #expect(!emptied)
    #expect(soloAgain)
}

@Test func returningToAnEarlierDesktopRestoresItsRuntimeSession() throws {
    var store = LayoutSessionStore()
    let a = WindowID(rawValue: "a")
    let a2 = WindowID(rawValue: "a2")
    let b = WindowID(rawValue: "b")
    let first = store.activate(
        displayID: sessionDisplay,
        windowIDs: [a, a2],
        focusedWindowID: a,
        defaultMode: .bento,
        reuseActiveWhenUnmatched: false
    )
    store.update(sessionDisplay) {
        $0.bentoState = BentoLayoutState(root: .branch(BentoBranch(
            axis: .vertical,
            weight: 0.68,
            first: .leaf(a),
            second: .leaf(a2)
        )))
        $0.isBentoInitialized = true
        $0.hasAppliedSingleWindowPlacement = true
        $0.lastObservedFrames = [
            a: BTRect(x: 0, y: 0, width: 680, height: 800),
            a2: BTRect(x: 680, y: 0, width: 320, height: 800),
        ]
    }
    let second = store.activate(
        displayID: sessionDisplay,
        windowIDs: [b],
        focusedWindowID: b,
        defaultMode: .manual,
        reuseActiveWhenUnmatched: false
    )
    let returned = store.activate(
        displayID: sessionDisplay,
        windowIDs: [a, a2],
        focusedWindowID: a,
        defaultMode: .manual,
        reuseActiveWhenUnmatched: false
    )

    #expect(first.wasCreated)
    #expect(second.wasCreated)
    #expect(first.session.id != second.session.id)
    #expect(returned.session.id == first.session.id)
    #expect(returned.session.mode == .bento)
    #expect(returned.session.bentoState.branches.first?.weight == 0.68)
    #expect(returned.session.lastObservedFrames[a]?.size.width == 680)
    #expect(returned.session.hasAppliedSingleWindowPlacement)
    #expect(store.allSessions(for: sessionDisplay).count == 2)
}

@Test func desktopMatchingUsesFocusThenAtLeastHalfOverlap() {
    var store = LayoutSessionStore()
    let a = WindowID(rawValue: "a"), b = WindowID(rawValue: "b"), c = WindowID(rawValue: "c")
    let first = store.activate(
        displayID: sessionDisplay,
        windowIDs: [a, b],
        focusedWindowID: a,
        defaultMode: .bento,
        reuseActiveWhenUnmatched: false
    )
    let overlap = store.activate(
        displayID: sessionDisplay,
        windowIDs: [a, b, c],
        focusedWindowID: c,
        defaultMode: .manual,
        reuseActiveWhenUnmatched: false
    )
    let focused = store.activate(
        displayID: sessionDisplay,
        windowIDs: [a, WindowID(rawValue: "x"), WindowID(rawValue: "y"), WindowID(rawValue: "z")],
        focusedWindowID: a,
        defaultMode: .manual,
        reuseActiveWhenUnmatched: false
    )

    #expect(overlap.session.id == first.session.id)
    #expect(focused.session.id == first.session.id)
    #expect(store.allSessions(for: sessionDisplay).count == 1)
}

@Test func updatesCannotMutateAnInactiveDesktopSession() {
    var store = LayoutSessionStore()
    let a = WindowID(rawValue: "a"), b = WindowID(rawValue: "b")
    let first = store.activate(
        displayID: sessionDisplay,
        windowIDs: [a],
        focusedWindowID: a,
        defaultMode: .bento,
        reuseActiveWhenUnmatched: false
    )
    _ = store.activate(
        displayID: sessionDisplay,
        windowIDs: [b],
        focusedWindowID: b,
        defaultMode: .manual,
        reuseActiveWhenUnmatched: false
    )
    store.update(sessionDisplay) { $0.mode = .manual }
    let inactive = store.allSessions(for: sessionDisplay).first(where: { $0.id == first.session.id })
    #expect(inactive?.mode == .bento)
    #expect(!store.isActive(first.session.id, on: sessionDisplay))
}

@Test func transientSpaceMembershipNeedsTwoStableSamples() {
    let a = WindowID(rawValue: "a"), b = WindowID(rawValue: "b")
    var stabilizer = DesktopObservationStabilizer()
    let first = stabilizer.observe([sessionDisplay: [a, b]])
    let transient = stabilizer.observe([sessionDisplay: [b]])
    let stable = stabilizer.observe([sessionDisplay: [b]])
    #expect(!first)
    #expect(!transient)
    #expect(stable)
}

@Test func adopterInfersNestedGuillotineLayoutWithoutMovingFrames() throws {
    let bounds = BTRect(x: 0, y: 24, width: 1200, height: 876)
    let a = WindowID(rawValue: "a"), b = WindowID(rawValue: "b")
    let c = WindowID(rawValue: "c"), d = WindowID(rawValue: "d")
    let frames = [
        a: BTRect(x: 0, y: 24, width: 720, height: 438),
        b: BTRect(x: 0, y: 462, width: 720, height: 438),
        c: BTRect(x: 720, y: 24, width: 480, height: 350.4),
        d: BTRect(x: 720, y: 374.4, width: 480, height: 525.6),
    ]
    let adopted = try #require(BentoLayoutAdopter().adopt(frames: frames, in: bounds))
    let placements = Dictionary(uniqueKeysWithValues: adopted.placements(in: bounds).map { ($0.windowID, $0.frame) })
    #expect(frames.allSatisfy { id, frame in placements[id]?.approximatelyEquals(frame) == true })
}

@Test func adopterRejectsLayoutsWithUnexplainedEmptySpace() {
    let bounds = BTRect(x: 0, y: 0, width: 1000, height: 800)
    let frames = [
        WindowID(rawValue: "left"): BTRect(x: 0, y: 0, width: 400, height: 800),
        WindowID(rawValue: "right"): BTRect(x: 600, y: 0, width: 400, height: 800),
    ]
    #expect(BentoLayoutAdopter().adopt(frames: frames, in: bounds) == nil)
}

@Test func nestedBentoTreeProducesOneBoundaryPerBranch() {
    let display = DisplayID(rawValue: "display")
    let a = WindowID(rawValue: "a"), b = WindowID(rawValue: "b"), c = WindowID(rawValue: "c"), d = WindowID(rawValue: "d")
    let root = BentoNode.branch(BentoBranch(axis: .vertical, weight: 0.6,
        first: .branch(BentoBranch(axis: .horizontal, weight: 0.5, first: .leaf(a), second: .leaf(b))),
        second: .branch(BentoBranch(axis: .horizontal, weight: 0.4, first: .leaf(c), second: .leaf(d)))))
    let state = BentoLayoutState(root: root)
    let boundaries = state.boundaries(in: BTRect(x: 0, y: 0, width: 1000, height: 800), displayID: display)
    #expect(boundaries.count == 3)
    #expect(boundaries.first(where: { $0.axis == .vertical })?.coordinate == 600)
    #expect(boundaries.filter { $0.axis == .horizontal }.allSatisfy { $0.spanEnd - $0.spanStart > 0 })
}

@Test func linkedBoundariesMergeNeighborsAndClampAsOneTransaction() throws {
    let display = DisplayID(rawValue: "display")
    var leftTop = testWindow("lt", x: 0, y: 0, width: 500, height: 400)
    var leftBottom = testWindow("lb", x: 0, y: 400, width: 500, height: 400)
    var right = testWindow("r", x: 500, y: 0, width: 500, height: 800)
    leftTop.displayID = display
    leftBottom.displayID = display
    right.displayID = display
    right.constraints.minimumSize = BTSize(width: 450, height: 80)
    let engine = LinkedResizeEngine(tolerance: 6)
    let boundaries = engine.boundaries(in: [leftTop, leftBottom, right], displayID: display)
    let boundary = try #require(boundaries.first(where: { $0.axis == .vertical }))
    #expect(boundary.beforeWindowIDs == [leftTop.id, leftBottom.id])
    #expect(boundary.afterWindowIDs == [right.id])
    #expect(boundary.hitFrame(width: 18).size.width == 18)
    let result = try #require(engine.resize(boundary: boundary, delta: 200, windows: [leftTop, leftBottom, right], bounds: BTRect(x: 0, y: 0, width: 1000, height: 800)))
    #expect(result.appliedDelta == 50)
    #expect(result.placements.first(where: { $0.windowID == right.id })?.frame.size.width == 450)
}

private func testWindow(_ id: String, x: Double, y: Double = 0, width: Double = 500, height: Double = 800) -> WindowSnapshot {
    WindowSnapshot(id: WindowID(rawValue: id), processIdentifier: 1,
        frame: BTRect(x: x, y: y, width: width, height: height), displayID: sessionDisplay)
}
