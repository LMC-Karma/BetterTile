import Foundation
import Testing
@testable import BetterTileCore

private func id(_ name: String) -> WindowID { WindowID(rawValue: name) }
private let left = BTRect(x: 0, y: 34, width: 497, height: 766)
private let right = BTRect(x: 503, y: 34, width: 497, height: 766)

/// Two columns: `a` selected over hidden `b` on the left, `c` selected over
/// hidden `d` on the right.
private func twoPanes() -> TabbedLayoutState {
    var state = TabbedLayoutState(preset: .columns)
    state.reconcile(windowIDs: [id("a"), id("b")], removed: [], focused: id("a"))
    state.activatePane(state.panes[1].id)
    state.reconcile(windowIDs: [id("a"), id("b"), id("c"), id("d")], removed: [], focused: id("c"))
    state.select(id("a"))
    state.select(id("c"))
    return state
}

private func entry(_ name: String?, _ frame: BTRect) -> TabbedStackEntry {
    TabbedStackEntry(windowID: name.map(id), frame: frame)
}

@Test func tabbedStackingLeavesACorrectOrderAlone() {
    let state = twoPanes()
    let order = [entry("c", right), entry("a", left), entry("d", right), entry("b", left)]
    #expect(state.sharedCurtainStackingRepair(order: order) == [])
    #expect(state.sharedCurtainStackingRepair(order: [entry(nil, left)] + order) == [])
}

@Test func sharedCurtainRequiresEverySelectedWindowAboveEveryInactiveTab() {
    let state = twoPanes()
    let oversized = BTRect(x: 0, y: 0, width: 1000, height: 800)
    let order = [entry("a", left), entry("b", oversized), entry("c", right), entry("d", right)]
    #expect(state.sharedCurtainStackingRepair(order: order) == [id("c")])
}

@Test func sharedCurtainPreservesOverlappingFloatingAndDialogWindows() {
    let state = twoPanes()
    let floating = BTRect(x: 600, y: 200, width: 300, height: 200)
    let dialog = BTRect(x: 850, y: 350, width: 400, height: 200)
    let order = [entry("dialog", dialog), entry("d", right), entry("floating", floating),
                 entry("c", right), entry("a", left), entry("b", left)]
    let plan = state.sharedCurtainStackingRepair(order: order)
    #expect(plan == [id("a"), id("c"), id("floating"), id("dialog")])
    var repaired = order
    for window in plan ?? [] {
        let index = repaired.firstIndex { $0.windowID == window }!
        repaired.insert(repaired.remove(at: index), at: 0)
    }
    #expect(state.sharedCurtainStackingRepair(order: repaired) == [])
}

@Test func sharedCurtainNeverCoversAWindowItCannotRaise() {
    let state = twoPanes()
    let unreadable = BTRect(x: 600, y: 200, width: 300, height: 200)
    #expect(state.sharedCurtainStackingRepair(order: [entry("d", right), entry(nil, unreadable),
                entry("c", right), entry("a", left)]) == nil)
    let apart = [entry(nil, BTRect(x: 0, y: 900, width: 100, height: 100)),
                 entry("d", right), entry("c", right), entry("a", left)]
    #expect(state.sharedCurtainStackingRepair(order: apart) == [id("a"), id("c")])
}

@Test func sharedCurtainRequiresAllSelectedIdentities() {
    let state = twoPanes()
    #expect(state.sharedCurtainStackingRepair(order: [entry("d", right), entry("c", right)]) == nil)
    #expect(state.sharedCurtainStackingRepair(order: []) == nil)
}

@Test func sharedCurtainPreservesFloatingWindowsInPaneGaps() {
    let state = twoPanes()
    let bounds = BTRect(x: 0, y: 0, width: 1000, height: 800)
    let gap = BTRect(x: 498, y: 100, width: 4, height: 100)
    let order = [entry("a", left), entry("b", bounds), entry("floating", gap), entry("c", right), entry("d", right)]
    #expect(state.sharedCurtainStackingRepair(order: order, curtainBounds: bounds) == [id("c"), id("floating")])
    let unknown = [entry("a", left), entry("b", bounds), entry(nil, gap), entry("c", right), entry("d", right)]
    #expect(state.sharedCurtainStackingRepair(order: unknown, curtainBounds: bounds) == nil)
}
