import Foundation
import Testing
@testable import BetterTileCore

@Suite struct FollowedLayoutTransitionTests {
    typealias F = FollowedLayoutTests

    @Test(arguments: [1, 2])
    func minimizeAndArrivalEndFollowingBeforeTopologyCanReturn(slotCount: Int) throws {
        let a = F.window("a"), b = F.window("b", app: "test.preferred"), c = F.window("c", app: "test.preferred")
        let remaining = slotCount == 1 ? [] : [b]
        let (_, _, original) = try F.fixture(windows: [a] + remaining,
            preferences: slotCount == 1 ? [["test.app"]] : [["test.app"], ["test.preferred"]],
            ratios: slotCount == 1 ? [1] : [0.7, 0.3])
        let minimized = F.reduce(original, windows: remaining, minimized: [a.id])
        let separate = F.reduce(minimized, windows: remaining + [c])
        let combined = F.reduce(original, windows: remaining + [c], minimized: [a.id])
        #expect(combined.followed == nil)
        #expect(combined.bentoState == separate.bentoState)
        #expect(original.followed != nil) // Planning changes only the proposal.
        var plain = combined; plain.endFollowing()
        let afterClose = F.reduce(combined, windows: remaining, gone: [c.id])
        #expect(afterClose.bentoState == F.reduce(plain, windows: remaining, gone: [c.id]).bentoState)
        #expect(afterClose.bentoState.vacantFrames(in: F.bounds).isEmpty)
        let d = F.window("d", app: "test.preferred")
        #expect(F.reduce(combined, windows: remaining + [c, d]).bentoState
            == F.reduce(plain, windows: remaining + [c, d]).bentoState)
        try F.assertStableVacancies(combined.bentoState)
    }

    static func ambient(_ original: LayoutSession, windows: [WindowSnapshot], gone: Set<WindowID> = [],
                        setting: WindowAction?) -> AmbientLayoutTransition {
        var session = original
        let previousIDs = session.windowIDs
        session.windowIDs = Set(windows.map(\.id)) // LayoutSessionStore.activate's membership update.
        return AmbientLayoutReconciler(paneGap: 0, adjacencyTolerance: 1, singleWindowPlacement: setting).transition(
            session: session, observation: .init(display: .init(id: F.display, frame: F.bounds, visibleFrame: F.bounds),
                windows: windows, wasCreated: false, previousWindowIDs: previousIDs,
                isDesktopTransition: false, confirmedGone: gone))
    }

    static func assertFollowedPlacement(_ transition: AmbientLayoutTransition, window: WindowSnapshot,
                                        expected: BTRect, setting: WindowAction?) throws {
        guard case let .applyLayout(proposed, placements, _) = transition else {
            Issue.record("A followed lone window must use the layout placement, not single-window or observe routing")
            return
        }
        #expect(placements == [Placement(windowID: window.id, frame: expected)])
        #expect(proposed.followed != nil)
        var committed = proposed
        committed.recordProposedFrames([window.id: expected])
        var placed = window; placed.frame = expected
        let repeated = ambient(committed, windows: [placed], setting: setting)
        guard case let .observe(unchanged) = repeated else {
            Issue.record("An already placed followed lone window must not write again")
            return
        }
        #expect(unchanged == committed)
        try F.assertStableVacancies(proposed.bentoState)
    }

    @Test(arguments: [nil, .maximize] as [WindowAction?])
    func ambientTwoToOneUsesTheFollowedTree(setting: WindowAction?) throws {
        var a = F.window("a"), b = F.window("b", app: "test.preferred")
        let (_, _, fixture) = try F.fixture(windows: [a, b])
        var session = fixture; session.isBentoInitialized = true; session.lastWorkArea = F.bounds
        let expected = try #require(session.bentoState.placements(in: F.bounds).first { $0.windowID == a.id }).frame
        a.frame = expected
        try Self.assertFollowedPlacement(Self.ambient(session, windows: [a], gone: [b.id], setting: setting),
            window: a, expected: expected, setting: setting)
    }

    @Test(arguments: [nil, .maximize] as [WindowAction?])
    func ambientZeroToOnePlacesThePreferredSlot(setting: WindowAction?) throws {
        let a = F.window("a"), b = F.window("b", app: "test.preferred")
        let (_, _, fixture) = try F.fixture(windows: [a, b])
        var session = F.reduce(fixture, windows: [], gone: [a.id, b.id])
        session.windowIDs = []; session.isBentoInitialized = true; session.lastWorkArea = F.bounds
        let expected = try #require(fixture.bentoState.placements(in: F.bounds).first { $0.windowID == b.id }).frame
        try Self.assertFollowedPlacement(Self.ambient(session, windows: [b], setting: setting),
            window: b, expected: expected, setting: setting)
    }

    @Test(arguments: [false, true])
    func focusMinimizeEvidenceVacatesInsteadOfPruning(closingInSameObservation: Bool) throws {
        let a = F.window("a"), b = F.window("b", app: "test.preferred")
        let (_, _, fixture) = try F.fixture(windows: [a, b])
        var session = fixture; session.excludedFocusWindowIDs = [b.id]
        let first = F.reduce(session, windows: [a], gone: closingInSameObservation ? [b.id] : [], minimized: [b.id])
        #expect(first.followed != nil)
        #expect(first.bentoState.vacantFrames(in: F.bounds).count == 1)
        #expect(first.bentoState.root?.windowIDs == [a.id])
        #expect(F.reduce(first, windows: [a], minimized: [b.id]) == first)
        let closed = F.reduce(first, windows: [a], gone: [b.id])
        #expect(closed.bentoState.root == first.bentoState.root)
        #expect(closed.followed?.slots == first.followed?.slots)
        #expect(closed.followed?.shape == first.followed?.shape)
        #expect(closed.followed?.returnVacancies.isEmpty == true)
        #expect(F.reduce(closed, windows: [a], gone: [b.id]) == closed)
        #expect(F.reduce(fixture, windows: [a], minimized: [b.id]).followed == nil)
        try F.assertStableVacancies(first.bentoState)
    }

    @Test func focusPeersReturnToTheirOwnAnyWindowSlots() throws {
        let a = F.window("a"), b = F.window("b"), c = F.window("c")
        let (_, _, fixture) = try F.fixture(windows: [a, b, c], preferences: [[], [], []], ratios: [0.4, 0.2, 0.4])
        var session = fixture
        session.excludedFocusWindowIDs = [b.id, c.id]
        let vacated = F.reduce(session, windows: [a], minimized: [b.id, c.id])
        #expect(vacated.followed != nil)
        var restored = vacated
        restored.reincludeInBento([b.id, c.id])
        let returned = F.reduce(restored, windows: [a, b, c])
        #expect(returned.followed?.slots == fixture.followed?.slots)
        #expect(returned.bentoState.placements(in: F.bounds) == fixture.bentoState.placements(in: F.bounds))
        #expect(F.reduce(returned, windows: [a, b, c]) == returned)
        try F.assertStableVacancies(vacated.bentoState)
    }
    @Test(arguments: ["return", "close", "another-fill"])
    func focusReturnMemoryRetiresAndRepeatedSweepsSettle(event: String) throws {
        let a = F.window("a"), b = F.window("b", app: "test.preferred"), c = F.window("c", app: "test.preferred")
        let (_, _, fixture) = try F.fixture(windows: [a, b])
        var session = fixture; session.excludedFocusWindowIDs = [b.id]
        var vacated = F.reduce(session, windows: [a], minimized: [b.id])
        let vacancy = try #require(vacated.bentoState.vacantFrames(in: F.bounds).first).key
        #expect(vacated.followed?.returnVacancies == [b.id: vacancy])
        let boundary = try #require(vacated.bentoState.branches.first).id
        vacated.bentoState.setBoundaryCoordinate(700, branchID: boundary, in: F.bounds)
        vacated.reconcileFollowing()
        #expect(vacated.followed?.returnVacancies == [b.id: vacancy])
        let windows: [WindowSnapshot]
        let gone: Set<WindowID>
        if event == "return" {
            vacated.reincludeInBento([b.id]); windows = [a, b]; gone = []
        } else if event == "close" {
            windows = [a]; gone = [b.id]
        } else {
            windows = [a, c]; gone = []
        }
        let next = F.reduce(vacated, windows: windows, gone: gone)
        #expect(next.followed != nil)
        #expect(next.followed?.returnVacancies.isEmpty == true)
        #expect(F.reduce(next, windows: windows, gone: gone) == next)
        try F.assertStableVacancies(next.bentoState)
    }

    @Test(arguments: [LayoutMode.bento, .tabbed])
    func everyEmptyPreferringPaneFillsForRepeatedApp(mode: LayoutMode) throws {
        let a = F.window("a"), b = F.window("b", app: "test.preferred"), c = F.window("c", app: "test.preferred")
        let (_, _, fixture) = try F.fixture(mode: mode,
            preferences: [["test.app"], ["test.other", "test.preferred"], ["test.preferred"], ["test.other"]],
            ratios: [0.25, 0.2, 0.2, 0.35])
        if mode == .bento {
            let first = F.reduce(fixture, windows: [a, b])
            #expect(first.followed?.slots[2].anchor == .adaptive(.window(b.id)))
            let second = F.reduce(first, windows: [a, b, c])
            #expect(second.followed?.slots[1].anchor == .adaptive(.window(c.id)))
            var normal = first; normal.endFollowing()
            #expect(F.reduce(normal, windows: [a, b, c]).bentoState != second.bentoState)
            #expect(F.reduce(second, windows: [a, b, c]) == second)
            try F.assertStableVacancies(second.bentoState)
        } else {
            var state = try #require(fixture.tabbedState)
            let active = try #require(state.pane(containing: a.id)).id
            state.activatePane(active)
            state.reconcile(windowIDs: [a.id, b.id], removed: [], fittingIn: F.bounds, windows: [a, b], followed: fixture.followed)
            #expect(fixture.followed?.slots[2].anchor == .tabbedPane(try #require(state.pane(containing: b.id)).id))
            var normal = state
            normal.reconcile(windowIDs: [a.id, b.id, c.id], removed: [], fittingIn: F.bounds, windows: [a, b, c])
            state.reconcile(windowIDs: [a.id, b.id, c.id], removed: [], fittingIn: F.bounds, windows: [a, b, c], followed: fixture.followed)
            #expect(fixture.followed?.slots[1].anchor == .tabbedPane(try #require(state.pane(containing: c.id)).id))
            #expect(normal.pane(containing: c.id)?.id == active)
            #expect(state.pane(containing: c.id)?.id != active)
        }
    }

    @Test func sameAxisEdgeDropThatKeepsShapeCountsAsASwap() throws {
        let a = F.window("a"), b = F.window("b", app: "test.preferred")
        let (_, _, fixture) = try F.fixture(windows: [a, b])
        let frames = Dictionary(uniqueKeysWithValues: fixture.bentoState.placements(in: F.bounds).map { ($0.windowID, $0.frame) })
        let drop = try #require(BentoDropPlanner().plan(intent: .insert(targetWindowID: b.id, edge: .right),
            sourceWindowID: a.id, state: fixture.bentoState, baselineFrames: frames, constraints: [:],
            contextWindowIDs: [a.id, b.id], in: F.bounds))
        var next = fixture; next.bentoState = drop.state; next.reconcileFollowing()
        #expect(next.followed != nil)
        #expect(next.followed?.slots[0].anchor == .adaptive(.window(b.id)))
        #expect(next.followed?.slots[1].anchor == .adaptive(.window(a.id)))
        try F.assertStableVacancies(next.bentoState)
    }

    @Test(arguments: [nil, .maximize] as [WindowAction?])
    func ordinaryAmbientSingleWindowPolicyStaysUnchanged(setting: WindowAction?) throws {
        let a = F.window("a"), b = F.window("b", app: "test.preferred")
        let (_, _, fixture) = try F.fixture(windows: [a, b])
        var session = fixture
        session.endFollowing(); session.isBentoInitialized = true; session.lastWorkArea = F.bounds
        let transition = Self.ambient(session, windows: [a], gone: [b.id], setting: setting)
        if setting == .maximize {
            guard case let .placeSingleWindow(_, placement) = transition else {
                Issue.record("Ordinary single-window maximize must still run"); return
            }
            #expect(placement.frame == F.bounds)
        } else {
            guard case .observe = transition else {
                Issue.record("With the single-window setting disabled, ordinary lone windows get no placement"); return
            }
        }
        try F.assertStableVacancies(transition.session.bentoState)
    }

}
