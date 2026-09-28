import Foundation
import Testing
@testable import BetterTileCore

private func id(_ name: String) -> WindowID { WindowID(rawValue: name) }
private func snapshot(_ name: String, minimum: BTSize = BTSize(width: 120, height: 80)) -> WindowSnapshot {
    var window = WindowSnapshot(id: id(name), processIdentifier: 1, frame: BTRect(x: 0, y: 0, width: 400, height: 400),
                                displayID: DisplayID(rawValue: "d"))
    window.constraints = WindowConstraints(minimumSize: minimum)
    return window
}

@Test func tabbedActivationCollectsWindowsInFirstPaneAndKeepsEmptyPanes() {
    let a = id("a"), b = id("b")
    var state = TabbedLayoutState(preset: .focus)
    state.reconcile(windowIDs: [a, b], removed: [], focused: b)
    #expect(state.panes.count == 3)
    #expect(state.panes[0].tabs == [a, b])
    #expect(state.panes[0].selected == b)
    #expect(state.panes[1].tabs.isEmpty)
    #expect(state.panes[2].tabs.isEmpty)
    // Tabbed runs on a Bento tree that reserves the strip above each window.
    #expect(state.layout.metrics.contentTopInset == TabbedLayoutState.headerHeight)
    #expect(state.layout.root?.windowIDs == [b])
}

@Test func tabbedEmptyPaneReceivesNewWindowsAndLastCloseKeepsThePane() {
    let a = id("a"), b = id("b")
    var state = TabbedLayoutState(preset: .columns)
    state.activatePane(state.panes[1].id)
    state.reconcile(windowIDs: [a], removed: [], focused: nil)
    #expect(state.panes[1].tabs == [a])
    state.reconcile(windowIDs: [a, b], removed: [], focused: nil)
    #expect(state.panes[1].tabs == [a, b])
    #expect(state.panes[1].selected == b)
    state.removeClosedWindow(a)
    state.removeClosedWindow(b)
    #expect(state.panes.count == 2)
    #expect(state.panes[1].tabs.isEmpty)
}

@Test func tabbedMoveReorderSplitAndFloatPreserveUniqueMembership() {
    let a = id("a"), b = id("b"), c = id("c")
    var state = TabbedLayoutState(preset: .columns)
    state.reconcile(windowIDs: [a, b, c], removed: [], focused: a)
    state.move(c, to: state.panes[0].id, at: 0)
    #expect(state.panes[0].tabs == [c, a, b])
    let right = state.panes[1].id
    state.split(paneID: right, moving: b, edge: .bottom)
    #expect(state.panes.count == 3)
    #expect(state.panes[0].tabs == [c, a])
    #expect(state.panes[1].id == right)
    #expect(state.panes[1].tabs.isEmpty)
    #expect(state.panes[2].tabs == [b])
    // The split is a Bento partition: the new pane sits below the empty one.
    let frames = state.frames(in: BTRect(x: 0, y: 0, width: 1000, height: 800))
    #expect(frames[state.panes[2].id]!.minY > frames[right]!.minY)
    state.float(a)
    state.reconcile(windowIDs: [a, b, c], removed: [], focused: nil)
    #expect(!state.windowIDs.contains(a))
    #expect(state.floatingWindowIDs == [a])
    #expect(state.panes.flatMap(\.tabs).count == state.windowIDs.count)
}

@Test func tabbedReconcileKeepsFloatingMembershipUntilClosed() {
    let a = id("a"), b = id("b")
    var state = TabbedLayoutState()
    state.reconcile(windowIDs: [a, b], removed: [], focused: a)
    state.float(b)
    state.reconcile(windowIDs: [a], removed: [], focused: nil)
    #expect(state.floatingWindowIDs == [b])
    state.removeClosedWindow(b)
    #expect(state.floatingWindowIDs.isEmpty)
    #expect(state.windowIDs == [a])
}

@Test func tabbedPresetAddsEmptyPanesAndMergesWithoutReorderingGroups() {
    let a = id("a"), b = id("b")
    var state = TabbedLayoutState()
    state.reconcile(windowIDs: [a, b], removed: [], focused: a)
    let first = state.panes[0].id
    state.applyPreset(.focus)
    #expect(state.panes[0].id == first)
    #expect(state.panes[0].tabs == [a, b])
    #expect(state.panes.dropFirst().allSatisfy { $0.tabs.isEmpty })
    state.move(b, to: state.panes[2].id)
    state.applyPreset(.single)
    #expect(state.panes.count == 1)
    #expect(state.panes[0].tabs == [a, b])
    #expect(state.panes[0].selected == a)
}

@Test func tabbedClosingSelectedTabChoosesRightThenLeftAndMissingSweepDoesNotClose() {
    let a = id("a"), b = id("b"), c = id("c")
    var state = TabbedLayoutState()
    state.reconcile(windowIDs: [a, b, c], removed: [], focused: b)
    state.reconcile(windowIDs: [], removed: [], focused: nil)
    #expect(state.panes[0].tabs == [a, b, c])
    state.removeClosedWindow(b)
    #expect(state.activeWindowID == c)
    state.removeClosedWindow(c)
    #expect(state.activeWindowID == a)
}

@Test func hiddenTabsNeverMakeAHalfScreenSplitTooSmall() throws {
    // The reported failure: dragging a tab to half the screen said the layout
    // could not apply, because a hidden tab's minimum counted.
    let bounds = BTRect(x: 0, y: 0, width: 1400, height: 900)
    let a = id("a"), wide = id("wide"), b = id("b")
    var state = TabbedLayoutState()
    state.reconcile(windowIDs: [a, wide, b], removed: [], focused: a)
    state.split(paneID: state.panes[0].id, moving: b, edge: .right)
    let windows = [snapshot("a"), snapshot("wide", minimum: BTSize(width: 1000, height: 80)), snapshot("b")]
    let fitted = try state.fittingMinimumWidths(in: bounds, windows: windows)
    let placements = try fitted.placements(in: bounds, windows: windows)
    #expect(placements.count == 3)
    // The hidden wide tab stacks behind the selected one at the same frame.
    let frames = Dictionary(uniqueKeysWithValues: placements.map { ($0.windowID, $0.frame) })
    #expect(frames[wide] == frames[a])
    #expect(abs(frames[a]!.size.width - frames[b]!.size.width) < 1)
    // A selected tab that cannot fit is still rejected.
    var selectedWide = fitted
    selectedWide.select(wide)
    let tooWide = [snapshot("a"), snapshot("wide", minimum: BTSize(width: 1400, height: 80)), snapshot("b")]
    #expect(throws: TabbedLayoutError.self) { try selectedWide.fittingMinimumWidths(in: bounds, windows: tooWide) }
}

@Test func tabbedMinimumFittingUsesBentoAndOnlySelectedTabs() throws {
    let bounds = BTRect(x: 0, y: 0, width: 1000, height: 800)
    let a = id("a"), b = id("b"), hidden = id("hidden")
    var state = TabbedLayoutState(preset: .columns)
    state.reconcile(windowIDs: [a], removed: [], focused: a)
    state.activatePane(state.panes[1].id)
    state.reconcile(windowIDs: [a, hidden, b], removed: [], focused: nil)
    state.select(b)
    let windows = [snapshot("a"), snapshot("b", minimum: BTSize(width: 650, height: 80)),
                   snapshot("hidden", minimum: BTSize(width: 900, height: 80))]
    let fitted = try state.fittingMinimumWidths(in: bounds, windows: windows)
    let frames = fitted.frames(in: bounds)
    #expect(abs(frames[fitted.panes[1].id]!.size.width - 650) < 0.5)
    // Minimum heights include the strip.
    let tall = [snapshot("a"), snapshot("b", minimum: BTSize(width: 120, height: 790))]
    #expect(throws: TabbedLayoutError.self) { try state.fittingMinimumWidths(in: bounds, windows: tall) }
}

@Test func tabbedFollowsATreeThatBentoChanged() {
    let bounds = BTRect(x: 0, y: 0, width: 1000, height: 800)
    let a = id("a"), b = id("b"), c = id("c")
    var state = TabbedLayoutState(preset: .columns)
    state.reconcile(windowIDs: [a, b], removed: [], focused: a)
    state.activatePane(state.panes[1].id)
    state.reconcile(windowIDs: [a, b, c], removed: [], focused: nil)
    // A Bento divider drag moves the boundary; groups and selection stay.
    var moved = state.layout
    let boundary = moved.boundaries(in: bounds, displayID: DisplayID(rawValue: "d")).first!
    let didMove = moved.setBoundaryCoordinate(700, branchID: boundary.branchID!, in: bounds)
    #expect(didMove)
    state.synchronize(with: moved)
    #expect(state.panes[0].tabs == [a, b])
    #expect(abs(state.frames(in: bounds)[state.panes[0].id]!.maxX - 697) < 1)
}

@Test func tabbedAdoptsBentoAndUnstacksWhenLeaving() {
    let bounds = BTRect(x: 0, y: 0, width: 1000, height: 800)
    let a = id("a"), b = id("b"), c = id("c")
    let bento = BentoLayoutState(root: .partition(BentoPartition(axis: .vertical, children: [.leaf(a), .leaf(b)])),
                                 metrics: BentoLayoutMetrics(paneGap: 6))
    guard var state = TabbedLayoutState(adopting: bento) else {
        Issue.record("Adoption failed")
        return
    }
    #expect(state.panes.map(\.tabs) == [[a], [b]])
    state.reconcile(windowIDs: [a, b, c], removed: [], focused: nil)
    #expect(state.panes[0].tabs == [a, c])
    let back = state.unstacked(in: bounds)
    #expect(Set(back.root?.windowIDs ?? []) == [a, b, c])
    #expect(back.metrics.contentTopInset == 0)
}

@Test func tabbedConfigurationRoundTripDoesNotReviveHistoricalTabbedMode() throws {
    var configuration = BetterTileConfiguration(defaultLayoutMode: .tabbed)
    configuration.defaultTabbedPreset = .focus
    let data = try JSONEncoder().encode(configuration)
    let restored = try JSONDecoder().decode(BetterTileConfiguration.self, from: data)
    #expect(restored.defaultLayoutMode == .tabbed)
    #expect(restored.defaultTabbedPreset == .focus)
    let legacy = Data(#"{"schemaVersion":7,"defaultLayoutMode":"tabbed"}"#.utf8)
    #expect(try JSONDecoder().decode(BetterTileConfiguration.self, from: legacy).defaultLayoutMode == .bento)
}
