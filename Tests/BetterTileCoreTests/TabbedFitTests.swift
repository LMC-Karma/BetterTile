import Foundation
import Testing
@testable import BetterTileCore

private let fitBounds = BTRect(x: 0, y: 0, width: 1000, height: 800)
private func window(_ name: String, minimumWidth: Double = 120, minimumHeight: Double = 80) -> WindowSnapshot {
    WindowSnapshot(
        id: WindowID(rawValue: name), processIdentifier: 1, frame: fitBounds, displayID: DisplayID(rawValue: "fit"),
        constraints: WindowConstraints(minimumSize: BTSize(width: minimumWidth, height: minimumHeight))
    )
}

/// Two columns: `small` selected over hidden `large` on the left, `peer` on the right.
private func twoColumns() -> TabbedLayoutState {
    var state = TabbedLayoutState(preset: .columns)
    state.reconcile(windowIDs: ["small", "large", "peer"].map { WindowID(rawValue: $0) }, removed: [], focused: nil)
    state.move(WindowID(rawValue: "peer"), to: state.panes[1].id)
    state.select(WindowID(rawValue: "small"))
    return state
}

private func leftWidth(_ state: TabbedLayoutState) -> Double {
    state.frames(in: fitBounds)[state.panes[0].id]?.size.width ?? 0
}

@Test func paneSizesFollowUserResizesButNotATabThatNeedsMoreRoom() throws {
    var state = twoColumns()
    try #require(state.pane(containing: WindowID(rawValue: "large"))?.id == state.panes[0].id)
    try #require(state.pane(containing: WindowID(rawValue: "peer"))?.id == state.panes[1].id)
    let divider = try #require(state.dividers(in: fitBounds).first?.branchID)
    let adjusted = state.adjustDivider(divider, by: -0.2, in: fitBounds)
    #expect(adjusted)
    let narrow = leftWidth(state)
    #expect(narrow < 320)
    #expect(state.withPreferredPaneSizes() == nil)

    state.select(WindowID(rawValue: "large"))
    let windows = [window("small"), window("large", minimumWidth: 600), window("peer")]
    let grown = try state.fittingMinimumWidths(in: fitBounds, windows: windows)
    #expect(leftWidth(grown) >= 600)
    #expect(grown.preferredPaneRatios == state.preferredPaneRatios)

    var back = grown
    back.select(WindowID(rawValue: "small"))
    let restored = try #require(back.withPreferredPaneSizes())
    #expect(abs(leftWidth(restored) - narrow) < 0.001)
}

@Test func presetsAndSplitsSetThePaneSizes() {
    var state = twoColumns()
    let before = state.preferredPaneRatios
    state.applyPreset(.grid)
    #expect(state.preferredPaneRatios != before)
    #expect(state.withPreferredPaneSizes() == nil)
    let afterPreset = state.preferredPaneRatios
    state.split(paneID: state.panes[0].id, moving: WindowID(rawValue: "large"), edge: .right)
    #expect(state.preferredPaneRatios != afterPreset)
    #expect(state.withPreferredPaneSizes() == nil)
}

@Test func fitProblemNamesTheNeighbourThatCannotShrink() {
    let state = twoColumns()
    let windows = [window("small"), window("large", minimumWidth: 600), window("peer", minimumWidth: 500)]
    #expect(state.fitProblem(showing: WindowID(rawValue: "large"), in: fitBounds, windows: windows)
        == .neighbors([WindowID(rawValue: "peer")]))
    let fits = [window("small"), window("large", minimumWidth: 600), window("peer", minimumWidth: 300)]
    #expect(state.fitProblem(showing: WindowID(rawValue: "large"), in: fitBounds, windows: fits) == nil)
}

@Test func fitProblemReportsAWindowLargerThanTheDisplay() {
    let state = twoColumns()
    let wide = [window("small"), window("large", minimumWidth: 1200), window("peer")]
    #expect(state.fitProblem(showing: WindowID(rawValue: "large"), in: fitBounds, windows: wide) == .largerThanDisplay)
    // The tab strip counts toward the height.
    let tall = [window("small"), window("large", minimumHeight: 780), window("peer")]
    #expect(state.fitProblem(showing: WindowID(rawValue: "large"), in: fitBounds, windows: tall) == .largerThanDisplay)
}

@Test func fitProblemReportsALockedDivider() throws {
    // Three columns; the divider between the left two panes is locked.
    let a = WindowID(rawValue: "a"), b = WindowID(rawValue: "b"), c = WindowID(rawValue: "c")
    let locked = UUID()
    let tree = BentoLayoutState(root: .partition(BentoPartition(
        axis: .vertical, children: [.leaf(a), .leaf(b), .leaf(c)], ratios: [0.3, 0.3, 0.4],
        boundaryIDs: [locked, UUID()], lockedBoundaryIDs: [locked]
    )))
    let state = try #require(TabbedLayoutState(adopting: tree))
    // a needs 500: c could give room, but the locked divider fixes a's side.
    let windows = [window("a", minimumWidth: 500), window("b"), window("c")]
    #expect(state.fitProblem(showing: a, in: fitBounds, windows: windows) == .lockedDivider)
}

@Test func restoringTabbedPaneSizesDefaultsOnAndRoundTrips() throws {
    let legacy = try ConfigurationStore.decode(JSONSerialization.data(withJSONObject: [
        "schemaVersion": BetterTileConfiguration.currentSchemaVersion,
    ]))
    #expect(legacy.tabbedRestoresPaneSizes)
    var changed = legacy
    changed.tabbedRestoresPaneSizes = false
    #expect(try !ConfigurationStore.decode(JSONEncoder().encode(changed)).tabbedRestoresPaneSizes)
    // Read at selection time; changing it must not restart gestures or reflow.
    #expect(ConfigurationChangeSet.between(legacy, changed).isEmpty)
}

@Test func fitProblemNamesOnlyTheWindowsThatSetAColumnsWidth() throws {
    // Left: small over hidden large. Right column: wide stacked over narrow.
    let small = WindowID(rawValue: "small"), large = WindowID(rawValue: "large")
    let wide = WindowID(rawValue: "wide"), narrow = WindowID(rawValue: "narrow")
    let tree = BentoLayoutState(root: .partition(BentoPartition(
        axis: .vertical,
        children: [.leaf(small), .partition(BentoPartition(axis: .horizontal, children: [.leaf(wide), .leaf(narrow)]))]
    )))
    var state = try #require(TabbedLayoutState(adopting: tree))
    state.reconcile(windowIDs: [small, wide, narrow, large], removed: [], focused: nil)
    try #require(state.pane(containing: large)?.id == state.pane(containing: small)?.id)
    state.select(small)
    let windows = [window("small"), window("large", minimumWidth: 600), window("wide", minimumWidth: 500), window("narrow")]
    let problem = state.fitProblem(showing: large, in: fitBounds, windows: windows)
    #expect(problem == .neighbors([wide]))
}

