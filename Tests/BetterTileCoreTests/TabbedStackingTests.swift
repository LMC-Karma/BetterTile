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
    #expect(state.panes.map(\.tabs) == [[id("a"), id("b")], [id("c"), id("d")]])
    let order = [entry("c", right), entry("a", left), entry("d", right), entry("b", left)]
    #expect(state.stackingRepair(order: order).isEmpty)
    // A window outside Tabbed in front of a selected tab is not a fault.
    #expect(state.stackingRepair(order: [entry(nil, left)] + order).isEmpty)
}

@Test func tabbedStackingRaisesOnlyThePaneWhoseHiddenTabCameForward() {
    let state = twoPanes()
    // Activating the app that owns `d` brought it over `c`.
    let order = [entry("a", left), entry("d", right), entry("c", right), entry("b", left)]
    #expect(state.stackingRepair(order: order) == [id("c")])
}

@Test func tabbedStackingKeepsAFloatingWindowInFrontOfTheRepairedPane() {
    let state = twoPanes()
    let floating = BTRect(x: 600, y: 200, width: 300, height: 200)
    // The floating window was in front of `c` before the hidden tab came forward.
    let order = [entry("d", right), entry("floating", floating), entry("c", right), entry("a", left)]
    #expect(state.stackingRepair(order: order) == [id("c"), id("floating")])
    // Behind `c` it stays behind; elsewhere it is not touched.
    let behindSelected = [entry("d", right), entry("c", right), entry("floating", floating)]
    #expect(state.stackingRepair(order: behindSelected) == [id("c")])
    let elsewhere = [entry("floating", BTRect(x: 0, y: 900, width: 100, height: 100)),
                     entry("d", right), entry("c", right)]
    #expect(state.stackingRepair(order: elsewhere) == [id("c")])
}

@Test func tabbedStackingRaisesWindowsThatMustStayInFrontOfARaisedWindow() {
    let state = twoPanes()
    let floating = BTRect(x: 600, y: 200, width: 300, height: 200)
    let dialog = BTRect(x: 850, y: 350, width: 400, height: 200) // Overlaps only the floating window.
    let order = [entry("dialog", dialog), entry("d", right), entry("floating", floating), entry("c", right)]
    #expect(state.stackingRepair(order: order) == [id("c"), id("floating"), id("dialog")])
}

@Test func tabbedStackingNeverCoversAWindowItCannotRaise() {
    let state = twoPanes()
    let unreadable = BTRect(x: 600, y: 200, width: 300, height: 200)
    let order = [entry("d", right), entry(nil, unreadable), entry("c", right)]
    #expect(state.stackingRepair(order: order).isEmpty)
    // An unreadable window that does not overlap the pane does not block it.
    let apart = [entry(nil, BTRect(x: 0, y: 900, width: 100, height: 100)), entry("d", right), entry("c", right)]
    #expect(state.stackingRepair(order: apart) == [id("c")])
}

@Test func tabbedStackingIgnoresWindowsMissingFromTheOrder() {
    let state = twoPanes()
    // Without the selected tab's position there is nothing to compare.
    #expect(state.stackingRepair(order: [entry("d", right), entry("b", left)]).isEmpty)
    #expect(state.stackingRepair(order: []).isEmpty)
}
