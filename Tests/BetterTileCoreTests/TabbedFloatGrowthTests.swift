import Foundation
import Testing
@testable import BetterTileCore

/// A display grows while its pane boundaries stay locked. Only the last of
/// three panes can show the automatic float. Returning it must leave the
/// focused tab selected and preserve all three pane dimensions and tab order.
@Test func automaticFloatUsesGrownPaneWithoutTakingFocus() throws {
    let ids = ["left", "middle", "right", "wide"].map { WindowID(rawValue: $0) }
    let boundaries = [UUID(), UUID()]
    let tree = BentoLayoutState(root: .partition(.init(axis: .vertical,
        children: ids.prefix(3).map(BentoNode.leaf), ratios: [0.2, 0.3, 0.5],
        boundaryIDs: boundaries, lockedBoundaryIDs: Set(boundaries))))
    var state = try #require(TabbedLayoutState(adopting: tree))
    state.select(ids[0])
    let small = BTRect(x: -1000, y: -800, width: 1000, height: 800)
    let large = BTRect(x: -1800, y: -800, width: 1800, height: 800)
    let windows = ids.enumerated().map { index, id in
        WindowSnapshot(id: id, processIdentifier: Int32(80 + index), frame: small, displayID: .init(rawValue: "growth-display"),
            constraints: .init(minimumSize: .init(width: index == 3 ? 550 : 120, height: 80), minimumSizeSource: .hint))
    }
    state.reconcile(windowIDs: ids, removed: [], fittingIn: small, windows: windows)
    try #require(state.automaticallyFloatingWindowIDs == [ids[3]])
    let before = state
    let frames = state.frames(in: large)
    let home = try #require(state.paneID(containing: ids[2]))
    let returns = state.returnAutomaticFloats([ids[3]], fittingIn: large, windows: windows, selecting: true, keeping: ids[2])
    #expect(returns.map(\.windowID) == [ids[3]])
    #expect(state.paneID(containing: ids[3]) == home)
    #expect(state.panes.first { $0.id == home }?.tabs == [ids[2], ids[3]])
    #expect(state.selectedWindowIDs == before.selectedWindowIDs)
    #expect(state.activePaneID == before.activePaneID)
    #expect(state.frames(in: large) == frames)
    #expect(state.automaticallyFloatingWindowIDs.isEmpty)
}
