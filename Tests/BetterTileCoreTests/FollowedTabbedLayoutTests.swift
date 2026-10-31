import Foundation
import Testing
@testable import BetterTileCore

extension FollowedLayoutTests {
    @Test func tabbedCloseKeepsPaneAndPreferredArrivalFillsItOnce() throws {
        let a = Self.window("a"), b = Self.window("b", app: "test.preferred")
        let (_, _, original) = try Self.fixture(mode: .tabbed, windows: [a, b])
        var session = original
        var state = try #require(session.tabbedState)
        let paneID = try #require(state.pane(containing: b.id)).id
        let aPaneID = try #require(state.pane(containing: a.id)).id
        state.removeClosedWindow(b.id)
        session.tabbedState = state; session.reconcileFollowing()
        #expect(session.followed == original.followed)
        #expect(state.panes.first { $0.id == paneID }?.tabs.isEmpty == true)
        let c = Self.window("c", app: "test.preferred")
        state.activatePane(aPaneID)
        let frames = state.frames(in: Self.bounds)
        state.reconcile(windowIDs: [a.id, c.id], removed: [], fittingIn: Self.bounds,
            windows: [a, c], followed: session.followed)
        #expect(state.pane(containing: c.id)?.id == paneID)
        #expect(state.pane(containing: a.id)?.id == aPaneID)
        #expect(state.frames(in: Self.bounds)[aPaneID] == frames[aPaneID])
        let repeated = state
        #expect(state.reconcile(windowIDs: [a.id, c.id], removed: [], fittingIn: Self.bounds,
            windows: [a, c], followed: session.followed).isEmpty)
        #expect(state == repeated)
        let d = Self.window("d", app: "test.preferred")
        state.reconcile(windowIDs: [a.id, c.id, d.id], removed: [], fittingIn: Self.bounds,
            windows: [a, c, d], followed: session.followed)
        #expect(state.pane(containing: d.id)?.id == aPaneID) // Occupied preferred pane cannot take a second arrival.
    }

    @Test(arguments: [false, true])
    func tabbedRanksAndSlotOrderPrecedeTheActivePane(tied: Bool) throws {
        let a = Self.window("a"), b = Self.window("b", app: "test.preferred")
        let (_, _, session) = try Self.fixture(mode: .tabbed,
            preferences: [["test.app"], tied ? ["test.preferred"] : ["test.other", "test.preferred"], ["test.preferred"]],
            ratios: [0.5, 0.3, 0.2])
        var state = try #require(session.tabbedState)
        let expected = try #require(session.followed?.slots[tied ? 1 : 2].anchor)
        state.activatePane(try #require(state.pane(containing: a.id)).id)
        state.reconcile(windowIDs: [a.id, b.id], removed: [], fittingIn: Self.bounds,
            windows: [a, b], followed: session.followed)
        #expect(expected == .tabbedPane(try #require(state.pane(containing: b.id)).id))
    }

    @Test func tabbedUnpreferredArrivalAndFailedPreferenceUseNormalRule() throws {
        let a = Self.window("a")
        let (_, _, session) = try Self.fixture(mode: .tabbed)
        let start = try #require(session.tabbedState)
        for b in [Self.window("b", app: "test.unpreferred"),
                  Self.window("big", app: "test.preferred", minimum: .init(width: 2000, height: 100))] {
            var ordinary = start, following = start
            ordinary.reconcile(windowIDs: [a.id, b.id], removed: [], fittingIn: Self.bounds, windows: [a, b])
            following.reconcile(windowIDs: [a.id, b.id], removed: [], fittingIn: Self.bounds,
                windows: [a, b], followed: session.followed)
            #expect(following == ordinary)
        }
    }

    @Test func inactiveTabbedCloseKeepsFollowingAndMinimizeEndsIt() throws {
        let a = Self.window("a")
        let (_, _, fixture) = try Self.fixture(mode: .tabbed)
        for minimized in [false, true] {
            var store = LayoutSessionStore()
            var session = store.select(displayID: Self.display, nativeSpaceID: .init(rawValue: 42), defaultMode: .tabbed)
            session.tabbedState = fixture.tabbedState; session.followed = fixture.followed
            let committed = store.commit(session, replacing: session.revision)
            session = try #require(committed)
            store.select(displayID: Self.display, nativeSpaceID: .init(rawValue: 43), defaultMode: .manual)
            if minimized { store.removeMinimizedTabbedWindow(a.id) }
            else { store.removeClosedTabbedWindow(a.id) }
            let updated = try #require(store.allSessions(for: Self.display).first { $0.id == session.id })
            #expect((updated.followed == nil) == minimized)
            #expect(updated.tabbedState?.panes.count == 2)
            let revision = updated.revision
            if minimized { store.removeMinimizedTabbedWindow(a.id) }
            else { store.removeClosedTabbedWindow(a.id) }
            #expect(store.allSessions(for: Self.display).first { $0.id == session.id }?.revision == revision)
        }
    }

    @Test func tabbedSelectionAndMovesKeepFollowingButPaneRemovalAndPresetEndIt() throws {
        let a = Self.window("a"), b = Self.window("b", app: "test.preferred")
        let (_, _, fixture) = try Self.fixture(mode: .tabbed, windows: [a, b])
        var session = fixture
        var state = try #require(session.tabbedState)
        let aPane = try #require(state.pane(containing: a.id)).id
        let bPane = try #require(state.pane(containing: b.id)).id
        state.move(b.id, to: aPane); state.select(a.id)
        session.tabbedState = state; session.reconcileFollowing()
        #expect(session.followed != nil)
        #expect(session.followed?.slots[1].anchor == .tabbedPane(bPane))
        state.removeEmptyPane(bPane)
        session.tabbedState = state; session.reconcileFollowing()
        #expect(session.followed == nil)
        session = fixture
        session.endFollowing() // A same-shape preset is an explicit end intent from 4B.
        session.tabbedState?.applyPreset(.columns)
        session.reconcileFollowing()
        #expect(session.followed == nil)
    }

    @Test func tabbedAutomaticFloatReturnUsesPreferredEmptyPane() throws {
        let a = Self.window("a"), big = Self.window("big", app: "test.preferred", minimum: .init(width: 2000, height: 100))
        let (_, _, session) = try Self.fixture(mode: .tabbed)
        var state = try #require(session.tabbedState)
        let active = try #require(state.pane(containing: a.id)).id
        state.activatePane(active)
        state.reconcile(windowIDs: [a.id, big.id], removed: [], fittingIn: Self.bounds,
            windows: [a, big], followed: session.followed)
        #expect(state.automaticallyFloatingWindowIDs.contains(big.id))
        let small = Self.window("big", app: "test.preferred")
        state.returnAutomaticFloats([small.id], fittingIn: Self.bounds, windows: [a, small], followed: session.followed)
        #expect(state.pane(containing: small.id)?.id != active)
        #expect(state.floatingWindowIDs.isEmpty)
    }
}
