import Foundation
import Testing
@testable import BetterTileCore

private let arrivalBounds = BTRect(x: 0, y: 0, width: 1000, height: 800)
private func window(_ name: String, minimumWidth: Double = 120) -> WindowSnapshot {
    WindowSnapshot(
        id: WindowID(rawValue: name), processIdentifier: 1, frame: arrivalBounds,
        displayID: DisplayID(rawValue: "arrival"),
        constraints: WindowConstraints(minimumSize: BTSize(width: minimumWidth, height: 80))
    )
}

@Test func aNewWindowThatFitsNoPaneFloatsInsteadOfHidingInOne() throws {
    var state = TabbedLayoutState(preset: .columns)
    let small = WindowID(rawValue: "small"), peer = WindowID(rawValue: "peer"), big = WindowID(rawValue: "big")
    state.reconcile(windowIDs: [small, peer], removed: [], focused: nil)
    state.move(peer, to: state.panes[1].id)
    let windows = [window("small"), window("peer"), window("big", minimumWidth: 950)]

    state.reconcile(windowIDs: [small, peer, big], removed: [], fittingIn: arrivalBounds, windows: windows)
    #expect(state.floatingWindowIDs.contains(big))
    #expect(!state.windowIDs.contains(big))
    // Already floating, it is not adopted again on the next sweep.
    let settled = state
    state.reconcile(windowIDs: [small, peer, big], removed: [], fittingIn: arrivalBounds, windows: windows)
    #expect(state == settled)
}

@Test func aNewWindowJoinsAnotherPaneThatCanGrowForIt() throws {
    // The active pane sits behind a locked divider and cannot grow; the
    // middle pane can, by taking room from the right pane.
    let a = WindowID(rawValue: "a"), b = WindowID(rawValue: "b"), c = WindowID(rawValue: "c")
    let locked = UUID()
    let tree = BentoLayoutState(root: .partition(BentoPartition(
        axis: .vertical, children: [.leaf(a), .leaf(b), .leaf(c)], ratios: [0.3, 0.35, 0.35],
        boundaryIDs: [locked, UUID()], lockedBoundaryIDs: [locked]
    )))
    var state = try #require(TabbedLayoutState(adopting: tree))
    state.select(a)
    let new = WindowID(rawValue: "new")
    let windows = [window("a"), window("b"), window("c"), window("new", minimumWidth: 400)]

    state.reconcile(windowIDs: [a, b, c, new], removed: [], fittingIn: arrivalBounds, windows: windows)
    #expect(state.pane(containing: new)?.id == state.pane(containing: b)?.id)
    #expect(!state.floatingWindowIDs.contains(new))
}
