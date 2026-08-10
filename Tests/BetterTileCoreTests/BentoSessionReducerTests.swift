import Testing
@testable import BetterTileCore

private let reducerDisplay = DisplayID(rawValue: "reducer")
private let reducerBounds = BTRect(x: 0, y: 0, width: 1_200, height: 800)

private func reducerWindow(_ name: String) -> WindowSnapshot {
    WindowSnapshot(
        id: WindowID(rawValue: name),
        processIdentifier: 1,
        frame: reducerBounds,
        displayID: reducerDisplay
    )
}

private extension BentoSessionTransition {
    var update: (session: LayoutSession, placements: [Placement], removedWindowIDs: Set<WindowID>)? {
        guard case let .update(session, placements, removedWindowIDs) = self else { return nil }
        return (session, placements, removedWindowIDs)
    }
}

@Test func unchangedMembershipProducesNoTransition() {
    let window = reducerWindow("stable")
    let session = LayoutSession(
        displayID: reducerDisplay,
        mode: .bento,
        bentoState: BentoLayoutState(root: .leaf(window.id)),
        windowIDs: [window.id],
        bentoInsertionOrder: [window.id]
    )

    let transition = BentoSessionReducer().reconcile(
        session: session,
        observation: BentoObservation(bounds: reducerBounds, windows: [window]),
        paneGap: 0
    )

    guard case .none = transition else {
        Issue.record("An unchanged observation must not create another transition")
        return
    }
}

@Test func everyMembershipCauseReachesAFixedPoint() {
    let a = reducerWindow("a")
    let b = reducerWindow("b")
    let windows = [a, b]
    let tiledPair = BentoLayoutState(root: .partition(BentoPartition(
        axis: .vertical,
        children: [.leaf(a.id), .leaf(b.id)]
    )))

    func expectFixedPoint(
        _ cause: String,
        session: LayoutSession,
        windows: [WindowSnapshot],
        paneGap: Double = 0,
        confirmedGone: Set<WindowID> = [],
        minimized: Set<WindowID> = []
    ) {
        let observation = BentoObservation(bounds: reducerBounds, windows: windows)
        let reducer = BentoSessionReducer()
        let first = reducer.reconcile(
            session: session,
            observation: observation,
            paneGap: paneGap,
            confirmedGone: confirmedGone,
            minimized: minimized
        )
        guard case let .update(updated, _, _) = first else {
            Issue.record("\(cause) did not produce its expected transition")
            return
        }
        let second = reducer.reconcile(
            session: updated,
            observation: observation,
            paneGap: paneGap,
            confirmedGone: confirmedGone,
            minimized: minimized
        )
        guard case .none = second else {
            Issue.record("\(cause) did not converge after one transition")
            return
        }
    }

    expectFixedPoint(
        "insertion",
        session: LayoutSession(
            displayID: reducerDisplay,
            mode: .bento,
            bentoState: BentoLayoutState(root: .leaf(a.id)),
            windowIDs: [a.id, b.id],
            bentoInsertionOrder: [a.id]
        ),
        windows: windows
    )
    expectFixedPoint(
        "confirmed removal",
        session: LayoutSession(
            displayID: reducerDisplay,
            mode: .bento,
            bentoState: tiledPair,
            windowIDs: [a.id],
            bentoInsertionOrder: [a.id, b.id]
        ),
        windows: [a],
        confirmedGone: [b.id]
    )
    expectFixedPoint(
        "minimize",
        session: LayoutSession(
            displayID: reducerDisplay,
            mode: .bento,
            bentoState: tiledPair,
            windowIDs: [b.id],
            bentoInsertionOrder: [a.id, b.id]
        ),
        windows: [b],
        minimized: [a.id]
    )
    expectFixedPoint(
        "restore",
        session: LayoutSession(
            displayID: reducerDisplay,
            mode: .bento,
            bentoState: BentoLayoutState(root: .leaf(b.id)),
            windowIDs: [a.id, b.id],
            bentoInsertionOrder: [a.id, b.id],
            bentoReinsertionAnchors: [
                a.id: BentoReinsertionAnchor(neighborWindowID: b.id, edge: .left)
            ]
        ),
        windows: windows
    )
    expectFixedPoint(
        "gap change",
        session: LayoutSession(
            displayID: reducerDisplay,
            mode: .bento,
            bentoState: BentoLayoutState(root: .leaf(a.id)),
            windowIDs: [a.id],
            bentoInsertionOrder: [a.id]
        ),
        windows: [a],
        paneGap: 6
    )
}

@Test func membershipUsesThePlannerInsertionPolicy() throws {
    let a = reducerWindow("a")
    let b = reducerWindow("b")
    let c = reducerWindow("c")
    let session = LayoutSession(
        displayID: reducerDisplay,
        mode: .bento,
        bentoState: BentoLayoutState(root: .leaf(a.id)),
        windowIDs: [a.id, b.id, c.id],
        focusedWindowID: a.id,
        bentoInsertionOrder: [a.id]
    )

    let transition = BentoSessionReducer().reconcile(
        session: session,
        observation: BentoObservation(
            bounds: reducerBounds,
            windows: [a, b, c],
            focusedWindowID: a.id
        ),
        paneGap: 0
    )
    let update = try #require(transition.update)

    guard case let .partition(root) = update.session.bentoState.root else {
        Issue.record("Expected the planner's three-pane topology")
        return
    }
    #expect(root.axis == .vertical)
    #expect(root.children.first == .leaf(a.id))
    #expect(Set(update.placements.map(\.windowID)) == [a.id, b.id, c.id])
    #expect(update.session.bentoInsertionOrder == [a.id, b.id, c.id])
}

@Test func membershipInsertionPreservesCustomizedPaneRatios() throws {
    let a = reducerWindow("a")
    let b = reducerWindow("b")
    let c = reducerWindow("c")
    let d = reducerWindow("d")
    let nested = BentoPartition(
        axis: .horizontal,
        children: [.leaf(b.id), .leaf(c.id)],
        ratios: [0.4, 0.6]
    )
    let customizedRoot = BentoPartition(
        axis: .vertical,
        children: [.leaf(a.id), .partition(nested)],
        ratios: [0.65, 0.35]
    )
    let session = LayoutSession(
        displayID: reducerDisplay,
        mode: .bento,
        bentoState: BentoLayoutState(root: .partition(customizedRoot)),
        windowIDs: [a.id, b.id, c.id, d.id],
        focusedWindowID: b.id,
        bentoInsertionOrder: [a.id, b.id, c.id]
    )

    let transition = BentoSessionReducer().reconcile(
        session: session,
        observation: BentoObservation(
            bounds: reducerBounds,
            windows: [a, b, c, d],
            focusedWindowID: b.id
        ),
        paneGap: 0
    )
    let update = try #require(transition.update)

    guard case let .partition(root) = update.session.bentoState.root,
          case let .partition(preservedNested) = root.children.last
    else {
        Issue.record("Expected the customized topology to remain")
        return
    }
    #expect(root.ratios == [0.65, 0.35])
    #expect(preservedNested.ratios == [0.4, 0.6])
    #expect(update.session.bentoState.root?.windowIDs == [a.id, b.id, d.id, c.id])
}

@Test func membershipFloatsOverflowWithoutChangingSixManagedPanes() throws {
    let windows = (1...7).map { reducerWindow("\($0)") }
    let firstSix = Array(windows.prefix(6))
    let activated = BentoPlanner().plan(
        state: BentoRuntimeState(),
        observation: BentoObservation(bounds: reducerBounds, windows: firstSix),
        intent: .activate
    )
    let session = LayoutSession(
        displayID: reducerDisplay,
        mode: .bento,
        bentoState: activated.state.layout,
        windowIDs: Set(windows.map(\.id)),
        bentoInsertionOrder: firstSix.map(\.id)
    )

    let transition = BentoSessionReducer().reconcile(
        session: session,
        observation: BentoObservation(bounds: reducerBounds, windows: windows),
        paneGap: 0
    )
    let update = try #require(transition.update)

    #expect(update.session.bentoState.root == activated.state.layout.root)
    #expect(update.session.automaticallyFloatingWindowIDs == [windows[6].id])
    #expect(update.session.bentoState.floatingWindowIDs.contains(windows[6].id))
}

@Test func plannerInsertionPreservesAnExplicitlyFloatingWindow() {
    let managed = reducerWindow("managed")
    let added = reducerWindow("added")
    let floating = reducerWindow("floating")
    let state = BentoRuntimeState(layout: BentoLayoutState(
        root: .leaf(managed.id),
        floatingWindowIDs: [floating.id]
    ))

    let result = BentoPlanner().plan(
        state: state,
        observation: BentoObservation(
            bounds: reducerBounds,
            windows: [managed, added, floating],
            focusedWindowID: managed.id
        ),
        intent: .insert(added.id)
    )

    #expect(result.state.layout.floatingWindowIDs.contains(floating.id))
    #expect(result.state.layout.root?.windowIDs.contains(added.id) == true)
}

@Test func membershipCorroboratesAbsenceBeforeRemovingAPane() throws {
    let a = reducerWindow("a")
    let b = reducerWindow("b")
    let state = BentoLayoutState(root: .partition(BentoPartition(
        axis: .vertical,
        children: [.leaf(a.id), .leaf(b.id)]
    )))
    let session = LayoutSession(
        displayID: reducerDisplay,
        mode: .bento,
        bentoState: state,
        windowIDs: [a.id],
        bentoInsertionOrder: [a.id, b.id]
    )
    let observation = BentoObservation(bounds: reducerBounds, windows: [a])

    let first = BentoSessionReducer().reconcile(
        session: session,
        observation: observation,
        paneGap: 0
    )
    let firstUpdate = try #require(first.update)
    let second = BentoSessionReducer().reconcile(
        session: firstUpdate.session,
        observation: observation,
        paneGap: 0
    )
    let secondUpdate = try #require(second.update)
    let third = BentoSessionReducer().reconcile(
        session: secondUpdate.session,
        observation: observation,
        paneGap: 0
    )
    let thirdUpdate = try #require(third.update)

    #expect(firstUpdate.session.bentoState.root?.windowIDs.contains(b.id) == true)
    #expect(secondUpdate.session.bentoState.root?.windowIDs.contains(b.id) == true)
    #expect(thirdUpdate.session.bentoState.root?.windowIDs.contains(b.id) == false)
    #expect(thirdUpdate.removedWindowIDs == [b.id])
}

@Test func minimizedMembershipRemovalKeepsAReinsertionAnchor() throws {
    let a = reducerWindow("a")
    let b = reducerWindow("b")
    let state = BentoLayoutState(root: .partition(BentoPartition(
        axis: .vertical,
        children: [.leaf(a.id), .leaf(b.id)]
    )))
    let session = LayoutSession(
        displayID: reducerDisplay,
        mode: .bento,
        bentoState: state,
        windowIDs: [b.id],
        bentoInsertionOrder: [a.id, b.id]
    )

    let transition = BentoSessionReducer().reconcile(
        session: session,
        observation: BentoObservation(bounds: reducerBounds, windows: [b]),
        paneGap: 0,
        minimized: [a.id]
    )
    let update = try #require(transition.update)

    #expect(update.session.bentoState.root?.windowIDs == [b.id])
    #expect(update.session.bentoReinsertionAnchors[a.id]?.neighborWindowID == b.id)
}

@Test func simultaneousMinimizeAnchorsFollowInsertionOrder() throws {
    let a = reducerWindow("a")
    let b = reducerWindow("b")
    let c = reducerWindow("c")
    let state = BentoLayoutState(root: .partition(BentoPartition(
        axis: .vertical,
        children: [.leaf(a.id), .leaf(b.id), .leaf(c.id)]
    )))
    let session = LayoutSession(
        displayID: reducerDisplay,
        mode: .bento,
        bentoState: state,
        windowIDs: [c.id],
        bentoInsertionOrder: [a.id, b.id, c.id]
    )

    let transition = BentoSessionReducer().reconcile(
        session: session,
        observation: BentoObservation(bounds: reducerBounds, windows: [c]),
        paneGap: 0,
        minimized: [b.id, a.id]
    )
    let update = try #require(transition.update)

    #expect(update.session.bentoReinsertionAnchors[a.id]?.neighborWindowID == b.id)
    #expect(update.session.bentoReinsertionAnchors[b.id]?.neighborWindowID == c.id)
}
