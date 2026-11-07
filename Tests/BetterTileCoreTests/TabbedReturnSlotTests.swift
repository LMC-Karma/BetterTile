import Foundation
import Testing
@testable import BetterTileCore

@Suite struct TabbedReturnSlotTests {
    private let bounds = BTRect(x: 0, y: 0, width: 1000, height: 800)
    private let a = WindowID(rawValue: "a"), b = WindowID(rawValue: "b"), c = WindowID(rawValue: "c")

    private func window(_ id: WindowID, width: Double = 120) -> WindowSnapshot {
        WindowSnapshot(id: id, processIdentifier: 1, frame: bounds, displayID: .init(rawValue: "return"),
                       constraints: .init(minimumSize: .init(width: width, height: 80)))
    }

    private func fixture() -> TabbedLayoutState {
        var state = TabbedLayoutState(preset: .columns)
        state.reconcile(windowIDs: [a, b, c], removed: [], focused: a)
        state.move(b, to: state.panes[1].id)
        state.move(c, to: state.panes[1].id)
        state.select(b)
        state.activatePane(state.panes[0].id)
        return state
    }

    @Test(arguments: [false, true])
    func returnRestoresPaneIndexAndSelection(selected: Bool) throws {
        var state = fixture()
        if !selected { state.select(c) }
        let pane = try #require(state.pane(containing: b))
        state.stepAway(b)
        #expect(state.returnSlots[b]?.index == 0)
        #expect(state.returnSlots[b]?.wasSelected == selected)
        state.stepAway(b) // Repeated evidence must not replace the original slot.
        let result = state.reconcile(windowIDs: [a, b, c], removed: [], fittingIn: bounds, windows: [a, b, c].map { window($0) })
        #expect(result.map(\.outcome) == [.returned(pane.id)])
        #expect(state.pane(containing: b)?.tabs == pane.tabs)
        #expect(state.pane(containing: b)?.selected == pane.selected)
        #expect(state.returnSlots.isEmpty)
    }

    @Test func returnDoesNotReplaceAUserSelectionInItsPane() throws {
        var state = fixture()
        state.stepAway(b)
        state.select(c) // Even explicitly choosing the automatic replacement counts.
        state.reconcile(windowIDs: [a, b, c], removed: [], fittingIn: bounds, windows: [a, b, c].map { window($0) })
        #expect(state.pane(containing: b)?.selected == c)
    }

    @Test func selectionInAnotherPaneDoesNotPreventRestoration() {
        var state = fixture()
        state.stepAway(b)
        state.select(a)
        state.reconcile(windowIDs: [a, b, c], removed: [], fittingIn: bounds, windows: [a, b, c].map { window($0) })
        #expect(state.pane(containing: b)?.selected == b)
        #expect(state.activeWindowID == a)
    }

    @Test func returnCanAdaptBoundaries() throws {
        var state = fixture()
        let home = try #require(state.paneID(containing: b))
        state.stepAway(b)
        let result = state.reconcile(windowIDs: [a, b, c], removed: [], fittingIn: bounds,
                                     windows: [window(a), window(b, width: 600), window(c)])
        #expect(result.map(\.outcome) == [.returned(home)])
        #expect(result.first?.trials.map(\.result) == [.fitsAfterAdapting])
        #expect(state.paneID(containing: b) == home)
    }

    @Test func returnFallsBackWhenHomeCannotFit() throws {
        let boundary = UUID()
        let layout = BentoLayoutState(root: .partition(.init(axis: .vertical, children: [.leaf(b), .leaf(a)],
            ratios: [0.3, 0.7], boundaryIDs: [boundary], lockedBoundaryIDs: [boundary])))
        var state = try #require(TabbedLayoutState(adopting: layout))
        let home = try #require(state.paneID(containing: b))
        let active = try #require(state.paneID(containing: a))
        state.activatePane(active)
        state.stepAway(b)
        let result = state.reconcile(windowIDs: [a, b], removed: [], fittingIn: bounds,
                                     windows: [window(a), window(b, width: 500)])
        #expect(result.map(\.outcome) == [.selected(active)])
        #expect(result.first?.trials.first?.paneID == home)
        #expect(result.first?.trials.first?.result == .doesNotFit)
        #expect(state.returnSlots.isEmpty)
    }

    @Test func removingHomeClearsSlotAndUsesOrdinaryArrival() throws {
        var state = fixture()
        state.stepAway(b); state.stepAway(c)
        let home = try #require(state.returnSlots[b]?.paneID)
        state.removeEmptyPane(home)
        #expect(state.returnSlots.isEmpty)
        let result = state.reconcile(windowIDs: [a, b], removed: [], fittingIn: bounds, windows: [window(a), window(b)])
        #expect(result.map(\.outcome) == [.selected(state.activePaneID)])
    }

    @Test func presetRepairAndCloseClearSlots() {
        let original = fixture()
        var preset = original
        preset.stepAway(b); preset.applyPreset(.columns)
        #expect(preset.returnSlots.isEmpty)
        var session = LayoutSession(displayID: .init(rawValue: "return"), mode: .tabbed)
        var state = original
        state.stepAway(b)
        session.tabbedState = state
        session.prepareForRepair()
        #expect(session.tabbedState?.returnSlots.isEmpty == true)
        state.removeClosedWindow(b)
        #expect(state.returnSlots.isEmpty)
    }

    @Test func synchronizeKeepsSlotsForExistingPanes() {
        var state = fixture()
        state.stepAway(b)
        let slot = state.returnSlots[b]
        state.synchronize(with: state.layout)
        #expect(state.returnSlots[b] == slot)
        state.reconcile(windowIDs: [a, b, c], removed: [], fittingIn: bounds, windows: [a, b, c].map { window($0) })
        #expect(state.paneID(containing: b) == slot?.paneID)
    }

    @Test func returnBookkeepingDoesNotChangePlacementEquality() {
        var state = fixture()
        state.activatePane(state.panes[1].id)
        state.stepAway(b)
        let remembered = state
        state.select(c) // Only a selection generation changes.
        #expect(state != remembered)
        #expect(state.layoutEquals(remembered))
        state.clearReturnSlots()
        #expect(state != remembered)
        #expect(state.layoutEquals(remembered))
    }

    @Test func floatingWindowsKeepTheirFloatingStateWhileAway() {
        var state = fixture()
        state.float(b)
        state.reconcile(windowIDs: [a, c, WindowID(rawValue: "huge")], removed: [], fittingIn: bounds,
            windows: [window(a), window(c), window(.init(rawValue: "huge"), width: 2000)])
        let before = state
        state.stepAway(b); state.stepAway(.init(rawValue: "huge"))
        #expect(state == before)
        state.reconcile(windowIDs: [a, b, c], removed: [], fittingIn: bounds, windows: [a, b, c].map { window($0) })
        #expect(state.floatingWindowIDs == before.floatingWindowIDs)
        #expect(state.automaticallyFloatingWindowIDs == before.automaticallyFloatingWindowIDs)
    }

    @Test(arguments: [false, true])
    func severalAbsentTabsKeepOrderAndOriginalSelection(reverse: Bool) throws {
        var state = TabbedLayoutState()
        state.reconcile(windowIDs: [a, b, c], removed: [], focused: b)
        let pane = state.panes[0]
        for id in reverse ? [c, b, a] : [a, b, c] { state.stepAway(id) }
        for id in reverse ? [a, c, b] : [c, b, a] {
            state.reconcile(windowIDs: [id], removed: [], fittingIn: bounds, windows: [a, b, c].map { window($0) })
        }
        #expect(state.panes[0].tabs == pane.tabs)
        #expect(state.panes[0].selected == pane.selected)
    }

    @Test func closeAfterMinimizeClearsAnInactiveSessionsSlot() throws {
        var store = LayoutSessionStore()
        let display = DisplayID(rawValue: "return")
        var session = store.select(displayID: display, nativeSpaceID: .init(rawValue: 1), defaultMode: .tabbed)
        session.tabbedState = fixture()
        session.windowIDs = [a, b, c]
        let committed = store.commit(session, replacing: session.revision)
        session = try #require(committed)
        store.select(displayID: display, nativeSpaceID: .init(rawValue: 2), defaultMode: .manual)
        store.removeMinimizedTabbedWindow(b)
        let away = try #require(store.allSessions(for: display).first { $0.id == session.id })
        #expect(away.tabbedState?.returnSlots[b] != nil)
        store.removeClosedTabbedWindow(b)
        let closed = try #require(store.allSessions(for: display).first { $0.id == session.id })
        #expect(closed.tabbedState?.returnSlots[b] == nil)
        #expect(closed.revision > away.revision)
    }
}

extension TabbedReturnSlotTests {
    @Test func closingAnotherTabKeepsReservedIndicesInOrder() {
        var state = TabbedLayoutState()
        state.reconcile(windowIDs: [a, b, c], removed: [], focused: a)
        state.stepAway(b)
        state.removeClosedWindow(a)
        state.reconcile(windowIDs: [b, c], removed: [], fittingIn: bounds, windows: [window(b), window(c)])
        #expect(state.panes[0].tabs == [b, c])
    }

    @Test(arguments: ["move", "split", "float"])
    func explicitMovesClearTheWindowsSlot(action: String) {
        var state = fixture()
        state.stepAway(b)
        let destination = state.panes[0].id
        switch action {
        case "move": state.move(b, to: destination)
        case "split": state.split(paneID: destination, moving: b, edge: .left)
        default: state.float(b)
        }
        #expect(state.returnSlots[b] == nil)
        #expect(state.windowIDs.union(state.floatingWindowIDs).contains(b))
    }
}

extension TabbedReturnSlotTests {
    @Test(arguments: [false, true])
    func movingAHiddenPeerDoesNotCancelSelectionRestoration(floating: Bool) {
        var state = fixture()
        let hidden = WindowID(rawValue: "hidden")
        state.reconcile(windowIDs: [a, b, c, hidden], removed: [], focused: nil)
        state.move(hidden, to: state.panes[1].id)
        state.select(b)
        state.activatePane(state.panes[0].id)
        state.stepAway(b)
        if floating { state.float(hidden) }
        else { state.move(hidden, to: state.panes[0].id) }
        state.reconcile(windowIDs: [a, b, c, hidden], removed: [], fittingIn: bounds,
                        windows: [a, b, c, hidden].map { window($0) })
        #expect(state.pane(containing: b)?.selected == b)
    }
}


extension TabbedReturnSlotTests {
    @Test func newSelectedArrivalKeepsSelectionWhenOlderTabReturns() {
        var state = fixture()
        let home = state.panes[1].id
        state.activatePane(home)
        state.stepAway(b)
        let n = WindowID(rawValue: "new")
        state.reconcile(windowIDs: [a, c, n], removed: [], fittingIn: bounds,
                        windows: [a, b, c, n].map { window($0) })
        #expect(state.pane(containing: n)?.selected == n)
        state.reconcile(windowIDs: [a, b, c, n], removed: [], fittingIn: bounds,
                        windows: [a, b, c, n].map { window($0) })
        #expect(state.pane(containing: b)?.tabs == [b, c, n])
        #expect(state.pane(containing: b)?.selected == n)
        #expect(state.hiddenWindowIDs.contains(b))
    }

    @Test(arguments: ["move", "split", "float", "tearOff"], [false, true])
    func removingPeerKeepsOtherReturnIndices(action: String, absent: Bool) throws {
        if absent && action == "tearOff" { return } // A drag can only tear off a present tab.
        let ids = [a, b, c, WindowID(rawValue: "d"), WindowID(rawValue: "e")]
        var state = TabbedLayoutState(preset: .columns)
        state.reconcile(windowIDs: ids, removed: [], focused: a)
        let home = state.panes[0].id
        let destination = state.panes[1].id
        if absent { state.stepAway(b) }
        state.stepAway(ids[3])
        switch action {
        case "move": state.move(b, to: destination)
        case "split": state.split(paneID: destination, moving: b, edge: .left)
        case "tearOff": _ = state.tearOff(b)
        default: state.float(b)
        }
        #expect(state.returnSlots[ids[3]]?.index == 2)
        state.reconcile(windowIDs: ids, removed: [], fittingIn: bounds, windows: ids.map { window($0) })
        #expect(state.panes.first { $0.id == home }?.tabs == [a, c, ids[3], ids[4]])
    }

    @Test(arguments: [false, true])
    func insertingAndReorderingPeersKeepsReturnOrder(reorder: Bool) {
        let d = WindowID(rawValue: "d"), e = WindowID(rawValue: "e")
        let ids = [a, b, c, d, e]
        var state = TabbedLayoutState(preset: .columns)
        state.reconcile(windowIDs: ids, removed: [], focused: a)
        let home = state.panes[0].id
        if !reorder { state.move(e, to: state.panes[1].id) }
        state.stepAway(b)
        state.stepAway(d)
        state.move(e, to: home, at: 0)
        state.reconcile(windowIDs: ids, removed: [], fittingIn: bounds, windows: ids.map { window($0) })
        #expect(state.pane(containing: b)?.tabs == [e, a, b, c, d])
        #expect(state.pane(containing: b)?.selected == e)
    }
}

extension TabbedReturnSlotTests {
    @Test(arguments: [false, true], [false, true])
    func synchronizedPeerRemovalKeepsReturnOrder(floating: Bool, absent: Bool) {
        let d = WindowID(rawValue: "d"), e = WindowID(rawValue: "e")
        let ids = [a, b, c, d, e]
        var state = TabbedLayoutState()
        state.reconcile(windowIDs: ids, removed: [], focused: a)
        let home = state.panes[0].id
        if absent { state.stepAway(b) }
        state.stepAway(d)
        var layout = state.layout
        if floating { layout.floatingWindowIDs.insert(b) }
        else { layout.root = .partition(.init(axis: .vertical, children: [layout.root!, .leaf(b)])) }
        state.synchronize(with: layout)
        #expect(state.returnSlots[d]?.index == 2)
        state.reconcile(windowIDs: ids, removed: [], fittingIn: bounds, windows: ids.map { window($0) })
        #expect(state.panes.first { $0.id == home }?.tabs == [a, c, d, e])
    }

    @Test func pendingCommitKeepsConcurrentSlotCleanupAndExactCommitsStayStale() throws {
        var store = LayoutSessionStore()
        let display = DisplayID(rawValue: "return")
        var session = store.select(displayID: display, nativeSpaceID: .init(rawValue: 1), defaultMode: .tabbed)
        var state = fixture()
        state.stepAway(b)
        session.tabbedState = state
        session.windowIDs = [a, c]
        session.tabbedBaselineFrames[b] = bounds
        let first = store.commit(session, replacing: session.revision)
        let baseline = try #require(first)
        var proposed = baseline
        proposed.mode = .manual
        store.removeClosedTabbedWindow(b)
        let latest = try #require(store.session(for: display))
        #expect(latest.revision > baseline.revision)
        #expect(latest.equalsIgnoringTabbedReturns(baseline))
        let exact = store.commit(proposed, replacing: baseline.revision)
        #expect(exact == nil)
        let result = store.commitIgnoringTabbedReturns(proposed, replacing: baseline)
        let committed = try #require(result)
        #expect(committed.mode == .manual)
        #expect(committed.tabbedState?.returnSlots[b] == nil)
        #expect(committed.tabbedBaselineFrames[b] == nil)
    }

    /// A Saved Layout Apply that dropped every slot must not get one back when
    /// a close shifts a sibling slot's index while the Apply is pending.
    @Test func pendingCommitDoesNotRestoreASlotTheProposalDropped() throws {
        let d = WindowID(rawValue: "d")
        var store = LayoutSessionStore()
        let display = DisplayID(rawValue: "return")
        var session = store.select(displayID: display, nativeSpaceID: .init(rawValue: 1), defaultMode: .tabbed)
        var state = TabbedLayoutState(preset: .columns)
        state.reconcile(windowIDs: [a, b, c, d], removed: [], focused: a)
        let home = state.panes[1].id
        for id in [b, c, d] { state.move(id, to: home) }
        state.activatePane(state.panes[0].id)
        state.stepAway(b)
        state.stepAway(c)
        #expect(state.returnSlots[b]?.index == 0 && state.returnSlots[c]?.index == 1)
        session.tabbedState = state
        session.windowIDs = [a, d]
        let first = store.commit(session, replacing: session.revision)
        let baseline = try #require(first)
        var proposed = baseline
        proposed.tabbedState?.clearReturnSlots()
        #expect(proposed.tabbedState?.returnSlots.isEmpty == true)
        store.removeClosedTabbedWindow(b)
        let latest = try #require(store.session(for: display))
        #expect(latest.tabbedState?.returnSlots[c]?.index == 0, "The close shifts the sibling slot")
        let result = store.commitIgnoringTabbedReturns(proposed, replacing: baseline)
        let committed = try #require(result)
        #expect(committed.tabbedState?.returnSlots.isEmpty == true,
                "A shifted slot must not come back into a proposal that dropped it")
    }

    @Test(arguments: ["mode", "selection", "membership", "pane"])
    func pendingCommitStillRejectsLayoutChanges(change: String) throws {
        var store = LayoutSessionStore()
        let display = DisplayID(rawValue: "return")
        var session = store.select(displayID: display, nativeSpaceID: .init(rawValue: 1), defaultMode: .tabbed)
        session.tabbedState = fixture()
        let first = store.commit(session, replacing: session.revision)
        let baseline = try #require(first)
        store.update(display) {
            switch change {
            case "mode": $0.mode = .manual
            case "selection": $0.tabbedState?.select(c)
            case "membership": $0.tabbedState?.float(c)
            default:
                let pane = $0.tabbedState!.panes[1].id
                $0.tabbedState?.activatePane(pane)
            }
        }
        let result = store.commitIgnoringTabbedReturns(baseline, replacing: baseline)
        #expect(result == nil)
    }
}
