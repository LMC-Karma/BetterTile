import Foundation
import Testing
@testable import BetterTileCore

@Suite struct FollowedLayoutTests {
    static let display = DisplayID(rawValue: "following-tests")
    static let bounds = BTRect(x: 0, y: 0, width: 1200, height: 800)

    static func window(_ id: String, app: String = "test.app", minimum: BTSize = .init(width: 1, height: 1)) -> WindowSnapshot {
        WindowSnapshot(id: .init(rawValue: id), processIdentifier: 1, bundleIdentifier: app,
            frame: bounds, displayID: display, constraints: .init(minimumSize: minimum))
    }

    static func fixture(mode: LayoutMode = .bento, windows: [WindowSnapshot] = [window("a")],
                        preferences: [[String]] = [["test.app"], ["test.preferred"]], ratios: [Double] = [0.7, 0.3],
                        bounds: BTRect = Self.bounds, gap: Double = 0, addAsPanes: Bool = false) throws
        -> (SavedLayoutDocument, SavedLayoutApplyPlan, LayoutSession) {
        let slots = preferences.indices.map { SavedLayoutSlot(id: "s\($0)", prefer: preferences[$0].map(AppPreference.app)) }
        let children = slots.map { mode == .tabbed ? SavedLayoutNode.group($0.id) : .slot($0.id) }
        let document = SavedLayoutDocument(name: "Work", mode: mode,
            layout: children.count == 1 ? children[0] : .split(axis: .vertical, ratios: ratios, children: children), slots: slots,
            groups: mode == .tabbed ? slots.map { .init(id: $0.id, slots: [$0.id], selected: $0.id) } : [], paneGap: gap,
            extraWindows: addAsPanes ? .addAsPanes : .float, keepForNewWindows: true)
        let eligible = windows.enumerated().map { index, window in
            SavedLayoutEligibleWindow(id: window.id, bundleID: window.bundleIdentifier ?? "", frame: window.frame,
                constraints: window.constraints, frontRank: index)
        }
        let plan = try SavedLayoutPlanner.plan(document, in: bounds, windows: eligible)
        var session = LayoutSession(displayID: display, nativeSpaceID: NativeSpaceID(rawValue: 42), mode: mode,
            windowIDs: Set(windows.map(\.id)), bentoInsertionOrder: windows.map(\.id))
        switch plan.targetSession {
        case let .bento(layout): session.bentoState = layout
        case let .tabbed(state): session.tabbedState = state
        case .manual: Issue.record("Expected managed target")
        }
        session.followed = try #require(FollowedLayout.make(layoutFileID: "Work.json", document: document, plan: plan,
            expandedPreferences: Dictionary(uniqueKeysWithValues: slots.enumerated().map { ($0.element.id, preferences[$0.offset]) }),
            session: session))
        return (document, plan, session)
    }

    static func reduce(_ session: LayoutSession, windows: [WindowSnapshot], gone: Set<WindowID> = [],
                       minimized: Set<WindowID> = [], cap: Int = 6,
                       bounds: BTRect = Self.bounds, gap: Double = 0) -> LayoutSession {
        let transition = BentoSessionReducer(maximumManagedWindows: cap).reconcile(session: session,
            observation: .init(bounds: bounds, windows: windows), paneGap: gap,
            confirmedGone: gone, minimized: minimized)
        if case let .update(next, _, _) = transition { return next }
        return session
    }

    static func assertStableVacancies(_ layout: BentoLayoutState) throws {
        let vacancies = Set(layout.vacantFrames(in: bounds).keys)
        let normalized = BentoLayoutState(root: layout.root, floatingWindowIDs: layout.floatingWindowIDs, metrics: layout.metrics)
        #expect(Set(normalized.vacantFrames(in: bounds).keys) == vacancies)
        let solved = try #require(BentoConstraintSolver().solve(state: normalized, in: bounds, constraints: [:]))
        #expect(Set(solved.vacantFrames(in: bounds).keys) == vacancies)
    }

    @Test func closeLeavesTheFollowedAdaptiveSlotEmpty() throws {
        let a = Self.window("a")
        let (_, _, session) = try Self.fixture()
        let next = Self.reduce(session, windows: [], gone: [a.id])
        #expect(next.bentoState.vacantFrames(in: Self.bounds).count == 2)
        #expect(next.bentoState.root?.windowIDs.isEmpty == true)
        #expect(next.followed != nil)
        #expect(Self.reduce(next, windows: [], gone: [a.id]) == next)
        #expect(Self.reduce(next, windows: []) == next)
        try Self.assertStableVacancies(next.bentoState)
    }

    @Test(arguments: [LayoutMode.bento, .tabbed])
    func layoutsWithoutNamedSlotsDoNotStartFollowing(mode: LayoutMode) throws {
        let document = SavedLayoutDocument(name: "Empty", mode: mode,
            layout: mode == .bento ? .empty : .group("empty"),
            groups: mode == .tabbed ? [.init(id: "empty", slots: [])] : [], keepForNewWindows: true)
        let plan = try SavedLayoutPlanner.plan(document, in: Self.bounds, windows: [])
        var session = LayoutSession(displayID: Self.display, mode: mode)
        switch plan.targetSession {
        case let .bento(layout): session.bentoState = layout
        case let .tabbed(state): session.tabbedState = state
        case .manual: Issue.record("Expected managed plan")
        }
        #expect(FollowedLayout.make(layoutFileID: "Empty.json", document: document, plan: plan,
            expandedPreferences: [:], session: session) == nil)
        // Named Any-window slots still hold panes even without app preferences.
        let (_, _, named) = try Self.fixture(mode: mode, windows: [], preferences: [[], []])
        #expect(named.followed?.slots.count == 2)
        #expect(named.followed?.slots.allSatisfy { $0.preferences.isEmpty } == true)
        try Self.assertStableVacancies(session.bentoState)
    }

    @Test func missingWindowsVacateOnlyOnceAtConfirmation() throws {
        let a = Self.window("a")
        let (_, _, session) = try Self.fixture()
        let first = Self.reduce(session, windows: [])
        let second = Self.reduce(first, windows: [])
        #expect(first.bentoState.root?.windowIDs == [a.id])
        #expect(second.bentoState.root?.windowIDs == [a.id])
        let confirmed = Self.reduce(second, windows: [])
        #expect(confirmed.bentoState.root?.windowIDs == [])
        #expect(confirmed.followed != nil)
        #expect(Self.reduce(confirmed, windows: []) == confirmed)
        try Self.assertStableVacancies(confirmed.bentoState)
    }

    @Test(arguments: [LayoutMode.bento, .tabbed])
    func constructionAcceptsCommittedFloatingExtras(mode: LayoutMode) throws {
        let (document, plan, session) = try Self.fixture(mode: mode)
        var committed = session
        committed.bentoState.floatingWindowIDs.formUnion([Self.window("test.extra").id])
        if mode == .tabbed, var state = committed.tabbedState {
            state.synchronize(with: committed.bentoState)
            committed.tabbedState = state
        }
        let following = try #require(FollowedLayout.make(layoutFileID: "Work.json", document: document,
            plan: plan, expandedPreferences: ["s0": ["test.app"], "s1": ["test.preferred"]], session: committed))
        #expect(following.layoutFileID == "Work.json")
        #expect(following.layoutName == "Work")
        #expect(following.slots.map(\.slotID) == ["s0", "s1"])
        #expect(following.slots[1].anchor == session.followed?.slots[1].anchor)
        try Self.assertStableVacancies(committed.bentoState)
    }

    @Test(arguments: [BentoNewWindowSide.automatic, .left, .right])
    func adaptivePreferencePrecedesConfiguredSideAndBalance(side: BentoNewWindowSide) throws {
        let a = Self.window("a")
        let b = Self.window("b", app: "test.preferred")
        let (_, _, session) = try Self.fixture()
        let before = session.bentoState.followingFrames(in: Self.bounds)
        let vacancy = try #require(session.bentoState.vacantFrames(in: Self.bounds).first)
        let result = BentoPlanner(newWindowSide: side, balancesNewWindows: true).plan(
            state: .init(layout: session.bentoState), observation: .init(bounds: Self.bounds, windows: [a, b]),
            intent: .insert(b.id), followed: session.followed)
        #expect(result.state.layout.followingFrames(in: Self.bounds)[b.id] == vacancy.value)
        #expect(result.state.layout.followingFrames(in: Self.bounds)[a.id] == before[a.id])
        try Self.assertStableVacancies(result.state.layout)
        let next = Self.reduce(session, windows: [a, b])
        #expect(next.followed?.slots[1].anchor == .adaptive(.window(b.id)))
        #expect(Self.reduce(next, windows: [a, b]) == next)
        let c = Self.window("c", app: "test.preferred")
        var ordinary = next; ordinary.endFollowing()
        let expected = Self.reduce(ordinary, windows: [a, b, c])
        let actual = Self.reduce(next, windows: [a, b, c])
        #expect(actual.bentoState == expected.bentoState)
        #expect(actual.followed == nil) // The normal split changes structure.
        try Self.assertStableVacancies(actual.bentoState)
    }

    @Test(arguments: [false, true])
    func bestRankThenSlotOrderChooseTheEmptySlot(tied: Bool) throws {
        let a = Self.window("a")
        let b = Self.window("b", app: "test.preferred")
        let preferences = [["test.app"], tied ? ["test.preferred"] : ["test.other", "test.preferred"], ["test.preferred"]]
        let (_, _, session) = try Self.fixture(preferences: preferences, ratios: [0.5, 0.3, 0.2])
        let expected = tied ? 1 : 2
        let next = Self.reduce(session, windows: [a, b])
        #expect(next.followed?.slots[expected].anchor == .adaptive(.window(b.id)))
        #expect(next.bentoState.followingFrames(in: Self.bounds)[a.id] == session.bentoState.followingFrames(in: Self.bounds)[a.id])
        try Self.assertStableVacancies(next.bentoState)
    }

    @Test func unpreferredArrivalUsesNormalVacancyThenSplit() throws {
        let a = Self.window("a")
        let b = Self.window("b", app: "test.unpreferred")
        let (_, _, session) = try Self.fixture()
        var ordinary = session; ordinary.endFollowing()
        let next = Self.reduce(session, windows: [a, b])
        #expect(next.bentoState == Self.reduce(ordinary, windows: [a, b]).bentoState)
        #expect(next.followed?.slots[1].anchor == .adaptive(.window(b.id)))
        let c = Self.window("c", app: "test.unpreferred")
        let split = Self.reduce(next, windows: [a, b, c])
        #expect(split.followed == nil)
        try Self.assertStableVacancies(split.bentoState)
    }

    @Test func failedPreferredFillUsesNormalPolicy() throws {
        let a = Self.window("a")
        let b = Self.window("b", app: "test.preferred", minimum: .init(width: 2000, height: 100))
        let (_, _, session) = try Self.fixture()
        let observation = BentoObservation(bounds: Self.bounds, windows: [a, b])
        let planner = BentoPlanner()
        let state = BentoRuntimeState(layout: session.bentoState)
        let preferred = planner.plan(state: state, observation: observation, intent: .insert(b.id), followed: session.followed)
        let normal = planner.plan(state: state, observation: observation, intent: .insert(b.id))
        #expect(preferred.state == normal.state)
        #expect(preferred.pill == normal.pill)
        #expect(session.followed != nil)
        try Self.assertStableVacancies(preferred.state.layout)
    }

    @Test func closeAndArrivalKeepExactGeometryWithGaps() throws {
        let bounds = BTRect(x: 37, y: 51, width: 1600, height: 900)
        let a = Self.window("a"), b = Self.window("b", app: "test.preferred")
        let (_, _, session) = try Self.fixture(windows: [a, b], bounds: bounds, gap: 6)
        let frames = session.bentoState.followingFrames(in: bounds)
        let closed = Self.reduce(session, windows: [a], gone: [b.id], bounds: bounds, gap: 6)
        let vacancy = try #require(closed.bentoState.vacantFrames(in: bounds).first)
        #expect(vacancy.value.approximatelyEquals(try #require(frames[b.id]), tolerance: 1))
        #expect(closed.bentoState.followingFrames(in: bounds)[a.id] == frames[a.id])
        let c = Self.window("c", app: "test.preferred")
        let filled = Self.reduce(closed, windows: [a, c], bounds: bounds, gap: 6)
        #expect(filled.bentoState.followingFrames(in: bounds)[a.id] == frames[a.id])
        #expect(filled.bentoState.followingFrames(in: bounds)[c.id] == frames[b.id])
        try Self.assertStableVacancies(closed.bentoState)
        try Self.assertStableVacancies(filled.bentoState)
    }

    @Test func minimizePrunesAndEndsFollowing() throws {
        let a = Self.window("a"), b = Self.window("b", app: "test.preferred")
        let (_, _, session) = try Self.fixture(windows: [a, b])
        let minimized = Self.reduce(session, windows: [a, b], minimized: [b.id])
        #expect(minimized.bentoState.root?.windowIDs == [a.id])
        #expect(minimized.followed == nil)
        try Self.assertStableVacancies(minimized.bentoState)
        var plain = session; plain.endFollowing()
        let closed = Self.reduce(plain, windows: [a], gone: [b.id])
        #expect(closed.bentoState.root?.windowIDs == [a.id])
        #expect(closed.bentoState.vacantFrames(in: Self.bounds).isEmpty)
    }

    @Test(arguments: ["cap", "solver", "focus"])
    func automaticDeparturesVacateAndSettle(cause: String) throws {
        let a = Self.window("a"), b = Self.window("b", app: "test.preferred")
        let (_, _, original) = try Self.fixture(windows: [a, b])
        var session = original
        var windows = [a, b]
        if cause == "solver" { windows[1].constraints.minimumSize = .init(width: 2000, height: 100) }
        if cause == "focus" { session.excludedFocusWindowIDs = [b.id]; windows = [a] }
        let next = Self.reduce(session, windows: windows, cap: cause == "cap" ? 1 : 6)
        #expect(next.followed != nil)
        #expect(next.bentoState.root?.windowIDs == [a.id])
        #expect(next.bentoState.floatingWindowIDs.contains(b.id))
        #expect(next.bentoState.vacantFrames(in: Self.bounds).count == 1)
        var repeated = next
        for _ in 0..<3 {
            let following = Self.reduce(repeated, windows: windows, cap: cause == "cap" ? 1 : 6)
            #expect(following == repeated)
            repeated = following
        }
        try Self.assertStableVacancies(next.bentoState)
    }

    @Test func focusExclusionThenRealCloseVacatesOnlyOnce() throws {
        let a = Self.window("a"), b = Self.window("b", app: "test.preferred")
        let (_, _, original) = try Self.fixture(windows: [a, b])
        // Focus minimizes the covered peer before the next inventory sees it.
        var excluded = original
        excluded.excludedFocusWindowIDs = [b.id]
        let vacated = Self.reduce(excluded, windows: [a])
        #expect(vacated.followed != nil)
        #expect(Self.reduce(vacated, windows: [a]) == vacated)
        let closed = Self.reduce(vacated, windows: [a], gone: [b.id])
        #expect(closed.followed?.slots == vacated.followed?.slots)
        #expect(closed.followed?.shape == vacated.followed?.shape)
        #expect(closed.followed?.returnVacancies.isEmpty == true)
        #expect(closed.bentoState.root == vacated.bentoState.root)
        #expect(!closed.bentoState.floatingWindowIDs.contains(b.id))
        #expect(Self.reduce(closed, windows: [a], gone: [b.id]) == closed)
        try Self.assertStableVacancies(closed.bentoState)
    }

    @Test(arguments: [BentoPaneDropPosition.center, .left])
    func crossDisplayTransferRemapsCenterAndEndsOnEdge(position: BentoPaneDropPosition) throws {
        let a = Self.window("a"), b = Self.window("b", app: "test.preferred")
        let c = Self.window("c"), d = Self.window("d", app: "test.preferred")
        let (_, _, source) = try Self.fixture(windows: [a, b])
        let (_, _, destination) = try Self.fixture(windows: [c, d])
        let transfer = try #require(BentoPlanner().transfer(sourceWindowID: a.id, targetWindowID: c.id,
            position: position, sourceState: .init(layout: source.bentoState),
            destinationState: .init(layout: destination.bentoState),
            sourceObservation: .init(bounds: Self.bounds, windows: [a, b]),
            destinationObservation: .init(bounds: Self.bounds, windows: [c, d])))
        var nextSource = source, nextDestination = destination
        nextSource.bentoState = transfer.sourceState.layout
        nextDestination.bentoState = transfer.destinationState.layout
        nextSource.reconcileFollowing(); nextDestination.reconcileFollowing()
        if position == .center {
            #expect(nextSource.followed?.slots[0].anchor == .adaptive(.window(c.id)))
            #expect(nextDestination.followed?.slots[0].anchor == .adaptive(.window(a.id)))
        } else {
            #expect(nextSource.followed == nil)
            #expect(nextDestination.followed == nil)
        }
        try Self.assertStableVacancies(nextSource.bentoState)
        try Self.assertStableVacancies(nextDestination.bentoState)
    }

    @Test func restoreWhileFollowingCannotResurrectSnapshotOccupants() throws {
        let a = Self.window("a"), b = Self.window("b", app: "test.preferred")
        let (_, _, session) = try Self.fixture()
        let ghost = Self.window("departed").id
        let snapshot = BentoLayoutState(root: .partition(.init(axis: .vertical,
            children: [.leaf(a.id), .leaf(b.id), .leaf(ghost)])))
        let runtime = BentoRuntimeState(layout: session.bentoState,
            reinsertionAnchors: [b.id: .init(neighborWindowID: a.id, edge: .left, layoutBefore: snapshot)])
        let result = BentoPlanner().plan(state: runtime, observation: .init(bounds: Self.bounds, windows: [a, b]),
            intent: .restore(b.id), followed: session.followed)
        #expect(result.restoreWindowIDs == [b.id])
        #expect(result.state.reinsertionAnchors[b.id] == nil)
        #expect(result.state.layout.root?.windowIDs == [a.id, b.id])
        #expect(!result.state.layout.root!.windowIDs.contains(ghost))
        try Self.assertStableVacancies(result.state.layout)
    }

    @Test func preferredFillAdaptsMinimumWithoutChangingOccupantPositions() throws {
        let a = Self.window("a"), b = Self.window("b", app: "test.preferred", minimum: .init(width: 500, height: 100))
        let (_, _, session) = try Self.fixture()
        let next = Self.reduce(session, windows: [a, b])
        #expect(next.followed?.slots[0].anchor == .adaptive(.window(a.id)))
        #expect(next.followed?.slots[1].anchor == .adaptive(.window(b.id)))
        #expect(next.bentoState.followingFrames(in: Self.bounds)[b.id]!.size.width >= 500)
        try Self.assertStableVacancies(next.bentoState)
    }

    @Test func swapAndDividerResizeRemapWithoutEnding() throws {
        let a = Self.window("a"), b = Self.window("b", app: "test.preferred")
        let (_, _, original) = try Self.fixture(windows: [a, b])
        var next = original
        next.bentoState.swap(a.id, b.id)
        next.reconcileFollowing()
        #expect(next.followed?.slots[0].anchor == .adaptive(.window(b.id)))
        #expect(next.followed?.slots[1].anchor == .adaptive(.window(a.id)))
        let boundary = try #require(next.bentoState.branches.first).id
        let resized = next.bentoState.setBoundaryCoordinate(600, branchID: boundary, in: Self.bounds)
        #expect(resized)
        next.reconcileFollowing()
        #expect(next.followed != nil)
        #expect(next.followed?.slots[0].preferences == ["test.app"])
        try Self.assertStableVacancies(next.bentoState)
    }

    @Test(arguments: ["mode", "split", "merge", "undo", "repair", "apply", "preset", "drag-out", "stop"])
    func endConditionsEndFollowing(action: String) throws {
        let a = Self.window("a")
        let (_, _, original) = try Self.fixture()
        var next = original
        switch action {
        case "mode": next.mode = .manual
        case "split": next.bentoState.split(a.id, inserting: Self.window("b").id, in: Self.bounds)
        case "merge": next.bentoState.removeVacancies()
        case "undo": next.bentoState = .init(root: .leaf(a.id))
        case "repair": next.prepareForRepair()
        default: next.endFollowing() // Explicit intents supplied by 4B, including same-shape presets/Apply.
        }
        next.reconcileFollowing()
        #expect(next.followed == nil)
        try Self.assertStableVacancies(next.bentoState)
    }

    @Test func proposalCopiesAndStaleRevisionsLeaveFollowingUntouched() throws {
        var store = LayoutSessionStore()
        let (_, _, fixture) = try Self.fixture()
        var original = store.ensure(displayID: Self.display, defaultMode: .bento)
        original.bentoState = fixture.bentoState
        original.followed = fixture.followed
        let committedOriginal = store.commit(original, replacing: original.revision)
        let current = try #require(committedOriginal)
        var rejected = current; rejected.endFollowing(); rejected.mode = .manual
        #expect(store.session(for: Self.display) == current) // A rejected placement never calls commit.
        store.update(Self.display) { $0.focusedWindowID = Self.window("a").id }
        let latest = try #require(store.session(for: Self.display))
        #expect((store.commit(rejected, replacing: current.revision)) == nil)
        #expect(store.session(for: Self.display) == latest)
        #expect(latest.followed == current.followed)
        store.update(Self.display) { $0.bentoState.removeVacancies() }
        #expect(store.session(for: Self.display)?.followed == nil)
        try Self.assertStableVacancies(latest.bentoState)
    }

    @Test func lastCloseRetainsTheNativeSpaceSession() throws {
        var store = LayoutSessionStore()
        let (_, _, fixture) = try Self.fixture()
        var original = store.select(displayID: Self.display, nativeSpaceID: NativeSpaceID(rawValue: 42), defaultMode: .bento)
        original.bentoState = fixture.bentoState; original.followed = fixture.followed
        original.bentoInsertionOrder = [Self.window("a").id]
        let committedOriginal = store.commit(original, replacing: original.revision)
        original = try #require(committedOriginal)
        let closed = Self.reduce(original, windows: [], gone: [Self.window("a").id])
        let committedClose = store.commit(closed, replacing: original.revision)
        let committed = try #require(committedClose)
        let activated = store.activate(displayID: Self.display, windowIDs: [], focusedWindowID: nil,
            defaultMode: .manual, reuseActiveWhenUnmatched: false, nativeSpaceID: NativeSpaceID(rawValue: 42))
        #expect(activated.session.id == committed.id)
        #expect(activated.session.followed != nil)
        try Self.assertStableVacancies(activated.session.bentoState)
    }

    @Test func vacatingAReturnedFloatCannotReuseAnotherVacancysIdentity() throws {
        let a = Self.window("a").id
        var state = BentoLayoutState(root: .partition(.init(axis: .vertical,
            children: [.leaf(a), .vacant(UUID())])))
        let vacated = state.vacate(a)
        let oldVacancy = try #require(vacated)
        let otherVacancy = try #require(state.vacantFrames(in: Self.bounds).keys.first { $0 != oldVacancy })
        state.fillVacancy(otherVacancy, with: a)
        var repeatProposal = state
        let newVacancy = state.vacate(a)
        #expect(newVacancy != oldVacancy)
        let repeated = repeatProposal.vacate(a)
        #expect(newVacancy == repeated)
        #expect(state.vacantFrames(in: Self.bounds).count == 2)
        try Self.assertStableVacancies(state)
    }

    @Test func vacancyIdentitySurvivesAllGeometryPasses() throws {
        let (_, _, session) = try Self.fixture()
        var state = session.bentoState
        let a = Self.window("a").id
        let vacated = state.vacate(a)
        let vacancy = try #require(vacated)
        var identical = session.bentoState
        let repeatedVacancy = identical.vacate(a)
        #expect(repeatedVacancy == vacancy)
        try Self.assertStableVacancies(state)
        let balanced = try #require(BentoBalancer().balance(state: state, in: Self.bounds, constraints: [:]))
        #expect(Set(balanced.vacantFrames(in: Self.bounds).keys) == Set(state.vacantFrames(in: Self.bounds).keys))
        let tabbed = try #require(TabbedLayoutState(adopting: state))
        #expect(tabbed.layout.vacantFrames(in: Self.bounds)[vacancy] != nil)
        let returned = BentoLayoutState(root: tabbed.layout.root)
        #expect(returned.vacantFrames(in: Self.bounds)[vacancy] != nil)
    }

    @Test func closingAnAddedExtraEndsFollowing() throws {
        let a = Self.window("a"), b = Self.window("b", app: "test.preferred"), c = Self.window("c", app: "test.extra")
        let (_, plan, session) = try Self.fixture(windows: [a, b, c], addAsPanes: true)
        #expect(plan.extras[c.id] == .addedAsPane)
        let next = Self.reduce(session, windows: [a, b], gone: [c.id])
        #expect(next.followed == nil)
        #expect(next.bentoState.vacantFrames(in: Self.bounds).isEmpty)
        try Self.assertStableVacancies(next.bentoState)
    }
}

private extension BentoLayoutState {
    func followingFrames(in bounds: BTRect) -> [WindowID: BTRect] {
        Dictionary(uniqueKeysWithValues: placements(in: bounds).map { ($0.windowID, $0.frame) })
    }
}
