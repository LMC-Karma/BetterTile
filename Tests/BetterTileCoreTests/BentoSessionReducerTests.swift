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

    guard case let .partition(root) = transition.session.bentoState.root else {
        Issue.record("Expected the planner's three-pane topology")
        return
    }
    #expect(root.axis == .vertical)
    #expect(root.children.first == .leaf(a.id))
    #expect(Set(transition.placements.map(\.windowID)) == [a.id, b.id, c.id])
    #expect(transition.session.bentoInsertionOrder == [a.id, b.id, c.id])
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

    guard case let .partition(root) = transition.session.bentoState.root,
          case let .partition(preservedNested) = root.children.last
    else {
        Issue.record("Expected the customized topology to remain")
        return
    }
    #expect(root.ratios == [0.65, 0.35])
    #expect(preservedNested.ratios == [0.4, 0.6])
    #expect(transition.session.bentoState.root?.windowIDs == [a.id, b.id, d.id, c.id])
}

@Test func membershipFloatsOverflowWithoutChangingSixManagedPanes() {
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

    #expect(transition.session.bentoState.root == activated.state.layout.root)
    #expect(transition.session.automaticallyFloatingWindowIDs == [windows[6].id])
    #expect(transition.session.bentoState.floatingWindowIDs.contains(windows[6].id))
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

@Test func membershipCorroboratesAbsenceBeforeRemovingAPane() {
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
    let second = BentoSessionReducer().reconcile(
        session: first.session,
        observation: observation,
        paneGap: 0
    )
    let third = BentoSessionReducer().reconcile(
        session: second.session,
        observation: observation,
        paneGap: 0
    )

    #expect(first.session.bentoState.root?.windowIDs.contains(b.id) == true)
    #expect(second.session.bentoState.root?.windowIDs.contains(b.id) == true)
    #expect(third.session.bentoState.root?.windowIDs.contains(b.id) == false)
    #expect(third.removedWindowIDs == [b.id])
}

@Test func minimizedMembershipRemovalKeepsAReinsertionAnchor() {
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

    #expect(transition.session.bentoState.root?.windowIDs == [b.id])
    #expect(transition.session.bentoReinsertionAnchors[a.id]?.neighborWindowID == b.id)
}

@Test func simultaneousMinimizeAnchorsFollowInsertionOrder() {
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

    #expect(transition.session.bentoReinsertionAnchors[a.id]?.neighborWindowID == b.id)
    #expect(transition.session.bentoReinsertionAnchors[b.id]?.neighborWindowID == c.id)
}
