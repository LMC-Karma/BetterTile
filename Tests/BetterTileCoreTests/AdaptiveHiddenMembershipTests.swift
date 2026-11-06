import BetterTileCore
import Testing

struct AdaptiveHiddenMembershipTests {
    private let display = DisplayID(rawValue: "hidden-membership")
    private let bounds = BTRect(x: 0, y: 0, width: 1000, height: 800)
    private func window(_ name: String) -> WindowSnapshot {
        WindowSnapshot(id: WindowID(rawValue: name), processIdentifier: 90,
            frame: bounds, displayID: display)
    }
    private func reduce(_ session: LayoutSession, windows: [WindowSnapshot], hidden: Set<WindowID>,
                        closed: Set<WindowID> = [], cap: Int = 6) -> LayoutSession {
        let transition = BentoSessionReducer(maximumManagedWindows: cap).reconcile(
            session: session, observation: BentoObservation(bounds: bounds, windows: windows),
            paneGap: 0, confirmedGone: closed, hiddenWindowIDs: hidden)
        if case let .update(next, _, _) = transition { return next }
        return session
    }
    @Test func hiddenPaneKeepsItsAnchorAndRestoresTheCustomRatio() {
        let a = window("left"), b = window("right")
        let layout = BentoLayoutState(root: .partition(BentoPartition(axis: .vertical,
            weight: 0.65, first: .leaf(a.id), second: .leaf(b.id))))
        let session = LayoutSession(displayID: display, mode: .bento, bentoState: layout,
            windowIDs: [a.id, b.id], bentoInsertionOrder: [a.id, b.id])
        let hidden = reduce(session, windows: [b], hidden: [a.id])
        #expect(hidden.bentoState.root?.windowIDs == [b.id])
        #expect(hidden.bentoReinsertionAnchors[a.id] != nil)
        #expect(hidden.bentoState.placements(in: bounds).first?.frame == bounds)
        let restored = reduce(hidden, windows: [b, a], hidden: [])
        #expect(restored.bentoState.placements(in: bounds) == layout.placements(in: bounds))
    }
    @Test func hiddenFloatsKeepTheirUserAndOverflowDisposition() {
        let pane = window("pane"), user = window("user-float"), overflow = window("overflow")
        let layout = BentoLayoutState(root: .leaf(pane.id), floatingWindowIDs: [user.id, overflow.id])
        var session = LayoutSession(displayID: display, mode: .bento, bentoState: layout,
            windowIDs: [pane.id, user.id, overflow.id], bentoInsertionOrder: [pane.id, user.id, overflow.id])
        session.automaticallyFloatingWindowIDs = [overflow.id]
        for _ in 0..<6 {
            session = reduce(session, windows: [pane], hidden: [user.id, overflow.id], cap: 1)
            #expect(session.bentoState.floatingWindowIDs == [user.id, overflow.id])
            #expect(session.automaticallyFloatingWindowIDs == [overflow.id])
        }
        session = reduce(session, windows: [pane, user, overflow], hidden: [], cap: 1)
        #expect(session.bentoState.floatingWindowIDs == [user.id, overflow.id])
        #expect(session.automaticallyFloatingWindowIDs == [overflow.id])
    }
    @Test func confirmedClosureWinsOverHiddenApplicationEvidence() {
        let a = window("closed"), b = window("survivor")
        let layout = BentoLayoutState(root: .partition(BentoPartition(axis: .vertical,
            first: .leaf(a.id), second: .leaf(b.id))))
        let session = LayoutSession(displayID: display, mode: .bento, bentoState: layout,
            windowIDs: [a.id, b.id], bentoInsertionOrder: [a.id, b.id])
        let result = reduce(session, windows: [b], hidden: [a.id], closed: [a.id])
        #expect(result.bentoState.root?.windowIDs == [b.id])
        #expect(result.bentoReinsertionAnchors[a.id] == nil)
    }
}
