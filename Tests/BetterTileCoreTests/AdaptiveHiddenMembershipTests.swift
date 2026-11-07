@testable import BetterTileCore
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
            paneGap: 0, confirmedGone: closed, hiddenApplicationWindowIDs: hidden)
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

    @Test(arguments: [false, true])
    func hiddenApplicationKeepsExistingFocusPeerPolicy(minimized: Bool) {
        let a = window("target"), b = window("covered-peer")
        let layout = BentoLayoutState(root: .partition(BentoPartition(axis: .vertical,
            weight: 0.65, first: .leaf(a.id), second: .leaf(b.id))))
        let session = LayoutSession(displayID: display, mode: .bento, bentoState: layout,
            windowIDs: [a.id, b.id], bentoInsertionOrder: [a.id, b.id], excludedFocusWindowIDs: [b.id])
        let observation = BentoObservation(bounds: bounds, windows: [a])
        let reducer = BentoSessionReducer()
        let ordinary = reducer.reconcile(session: session, observation: observation,
            paneGap: 0, minimized: minimized ? [b.id] : [])
        let hidden = reducer.reconcile(session: session, observation: observation,
            paneGap: 0, minimized: minimized ? [b.id] : [], hiddenApplicationWindowIDs: [b.id])
        func result(_ transition: BentoSessionTransition) -> LayoutSession {
            if case let .update(next, _, _) = transition { return next }
            return session
        }
        #expect(result(hidden) == result(ordinary))
    }

    @Test func hiddenFocusMinimizedPeerKeepsItsReturnVacancyWithoutPruningItsPane() throws {
        typealias F = FollowedLayoutTests
        let target = F.window("target"), peer = F.window("extra-peer", app: "test.extra")
        let preferred = F.window("preferred", app: "test.preferred")
        let (_, _, fixture) = try F.fixture(windows: [target, preferred, peer], addAsPanes: true)
        var session = fixture
        let vacatedID = session.bentoState.vacate(preferred.id)
        let vacancy = try #require(vacatedID)
        session.reconcileFollowing()
        session.followed?.rememberReturn(of: peer.id, to: vacancy)
        session.excludedFocusWindowIDs = [peer.id]
        #expect(session.followed?.anchorsWindow(peer.id, in: session.bentoState) == false)
        #expect(session.followed?.hasReturnVacancy(for: peer.id, in: session.bentoState) == true)

        let transition = BentoSessionReducer().reconcile(session: session,
            observation: BentoObservation(bounds: F.bounds, windows: [target]),
            paneGap: 0, minimized: [peer.id], hiddenApplicationWindowIDs: [peer.id])
        var result = session
        if case let .update(next, _, removed) = transition {
            result = next
            #expect(!removed.contains(peer.id))
        }
        #expect(result.bentoState == session.bentoState)
        #expect(result.followed == session.followed)
        #expect(result.bentoInsertionOrder == session.bentoInsertionOrder)
    }
}
