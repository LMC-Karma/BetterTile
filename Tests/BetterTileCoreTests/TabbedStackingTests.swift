import Foundation
import Testing
@testable import BetterTileCore

private func id(_ name: String) -> WindowID { WindowID(rawValue: name) }
private let bounds = BTRect(x: 0, y: 0, width: 1000, height: 800)
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
    #expect(state.sharedCurtainStackingRepair(order: order, curtainBounds: bounds) == [])
    #expect(state.sharedCurtainStackingRepair(order: [entry(nil, left)] + order, curtainBounds: bounds) == [])
}

@Test func sharedCurtainRequiresEverySelectedWindowAboveEveryInactiveTab() {
    let state = twoPanes()
    let oversized = BTRect(x: 0, y: 0, width: 1000, height: 800)
    let order = [entry("a", left), entry("b", oversized), entry("c", right), entry("d", right)]
    #expect(state.sharedCurtainStackingRepair(order: order, curtainBounds: bounds) == [id("c")])
}

@Test func sharedCurtainPreservesOverlappingFloatingAndDialogWindows() {
    let state = twoPanes()
    let floating = BTRect(x: 600, y: 200, width: 300, height: 200)
    let dialog = BTRect(x: 850, y: 350, width: 400, height: 200)
    let order = [entry("dialog", dialog), entry("d", right), entry("floating", floating),
                 entry("c", right), entry("a", left), entry("b", left)]
    let plan = state.sharedCurtainStackingRepair(order: order, curtainBounds: bounds)
    #expect(plan == [id("a"), id("c"), id("floating"), id("dialog")])
    var repaired = order
    for window in plan ?? [] {
        let index = repaired.firstIndex { $0.windowID == window }!
        repaired.insert(repaired.remove(at: index), at: 0)
    }
    #expect(state.sharedCurtainStackingRepair(order: repaired, curtainBounds: bounds) == [])
}

@Test func sharedCurtainNeverCoversAWindowItCannotRaise() {
    let state = twoPanes()
    let unreadable = BTRect(x: 600, y: 200, width: 300, height: 200)
    #expect(state.sharedCurtainStackingRepair(order: [entry("d", right), entry(nil, unreadable),
                entry("c", right), entry("a", left), entry("b", left)], curtainBounds: bounds) == nil)
    let apart = [entry(nil, BTRect(x: 0, y: 900, width: 100, height: 100)),
                 entry("d", right), entry("c", right), entry("a", left), entry("b", left)]
    #expect(state.sharedCurtainStackingRepair(order: apart, curtainBounds: bounds) == [id("a"), id("c")])
}

@Test func sharedCurtainRequiresAllSelectedIdentities() {
    let state = twoPanes()
    #expect(state.sharedCurtainStackingRepair(order: [entry("d", right), entry("c", right)], curtainBounds: bounds) == nil)
    #expect(state.sharedCurtainStackingRepair(order: [], curtainBounds: bounds) == nil)
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

@Test func sharedCurtainRequiresInactiveTabIdentitiesToo() {
    let state = twoPanes()
    let oversized = BTRect(x: 0, y: 0, width: 1000, height: 800)
    let unknownHidden = [entry(nil, oversized), entry("a", left), entry("c", right), entry("d", right)]
    #expect(state.sharedCurtainStackingRepair(order: unknownHidden, curtainBounds: bounds) == nil)
}

@Test func keyPreservingPlanRaisesTheKeyWindowLastWhenItsAppIsRaised() {
    let state = twoPanes()
    let pids: [WindowID: Int32] = [id("a"): 1, id("b"): 1, id("c"): 1, id("d"): 2]
    // Raising `c` makes it the app's main window; `a` must be raised again.
    #expect(state.keyPreservingRaisePlan([id("c")], key: .window(id("a")), processIdentifiers: pids).raises
        == [id("c"), id("a")])
    // An already-last key window is left in place.
    #expect(state.keyPreservingRaisePlan([id("a"), id("c")], key: .window(id("a")), processIdentifiers: pids).raises
        == [id("c"), id("a")])
}

@Test func keyPreservingPlanLeavesOtherAppsAndHiddenTabsAlone() {
    let state = twoPanes()
    let pids: [WindowID: Int32] = [id("a"): 1, id("b"): 1, id("c"): 2, id("d"): 2]
    // Another application's raise cannot steal this app's focus.
    #expect(state.keyPreservingRaisePlan([id("c")], key: .window(id("a")), processIdentifiers: pids).raises == [id("c")])
    // A hidden tab would cover its pane's selected tab.
    #expect(state.keyPreservingRaisePlan([id("a")], key: .window(id("b")), processIdentifiers: pids).raises == [id("a")])
    #expect(state.keyPreservingRaisePlan([id("c")], key: nil, processIdentifiers: pids).raises == [id("c")])
}

/// A browser toolbar bubble closes as soon as it loses focus, and raising
/// any window of its application moves focus. Those raises wait, and so do
/// raises that would cover that application's windows. Others proceed.
@Test func keyPreservingPlanDefersRaisesThatWouldTakeAPopupsFocus() {
    let state = twoPanes()
    let pids: [WindowID: Int32] = [id("a"): 1, id("b"): 2, id("c"): 3, id("d"): 3, id("popup"): 1]
    let frames: [WindowID: BTRect] = [id("a"): left, id("b"): left, id("c"): right, id("d"): right,
                                      id("popup"): BTRect(x: 100, y: 100, width: 200, height: 200)]
    let popup = TabbedKeyWindow.transient(processIdentifier: 1)
    #expect(state.keyPreservingRaisePlan([id("a")], key: popup, processIdentifiers: pids, frames: frames)
        == TabbedKeyPreservingPlan(raises: [], isDeferred: true))
    // The right pane's raise covers nothing of the popup's application.
    #expect(state.keyPreservingRaisePlan([id("c"), id("a"), id("popup")], key: popup,
                                         processIdentifiers: pids, frames: frames)
        == TabbedKeyPreservingPlan(raises: [id("c")], isDeferred: true))
    // A raise over the popup's application waits too.
    #expect(state.keyPreservingRaisePlan([id("b")], key: popup, processIdentifiers: pids, frames: frames)
        == TabbedKeyPreservingPlan(raises: [], isDeferred: true))
    #expect(state.keyPreservingRaisePlan([id("c")], key: popup, processIdentifiers: pids, frames: frames)
        == TabbedKeyPreservingPlan(raises: [id("c")], isDeferred: false))
}

/// A standard window the user floated gets focus back when it is raised
/// last, as a key tab does.
@Test func keyPreservingPlanRaisesAFloatedStandardKeyWindowLast() {
    let state = twoPanes()
    let pids: [WindowID: Int32] = [id("a"): 1, id("b"): 2, id("c"): 3, id("d"): 3, id("floated"): 1]
    #expect(state.keyPreservingRaisePlan([id("a")], key: .window(id("floated")), processIdentifiers: pids).raises
        == [id("a"), id("floated")])
}

/// A floating window that ended behind the backmost selected tab would sit
/// under the curtain, invisible. The repair raises it above the panes.
@Test func sharedCurtainRaisesABuriedFloatingWindow() {
    let state = twoPanes()
    let floating = BTRect(x: 300, y: 200, width: 400, height: 300)
    let order = [entry("a", left), entry("c", right), entry("b", left), entry("floating", floating), entry("d", right)]
    #expect(state.sharedCurtainStackingRepair(order: order, curtainBounds: bounds) == [])
    #expect(state.sharedCurtainStackingRepair(order: order, curtainBounds: bounds,
                                              aboveCurtain: [id("floating")]) == [id("floating")])
}

/// A floating dialog of the front application behind its selected tab is
/// kept in place: raising it would take focus, and raising the key tab last
/// would put it back. The curtain goes behind it instead.
@Test func sharedCurtainKeepsAFrontApplicationFloatInPlaceBehindTheSelectedTab() {
    let state = twoPanes()
    let dialog = BTRect(x: 100, y: 100, width: 300, height: 200)
    let order = [entry("a", left), entry("c", right), entry("dialog", dialog), entry("b", left), entry("d", right)]
    #expect(state.sharedCurtainStackingRepair(order: order, curtainBounds: bounds,
                                              aboveCurtain: [id("dialog")]) == [id("dialog")])
    #expect(state.sharedCurtainStackingRepair(order: order, curtainBounds: bounds, aboveCurtain: [id("dialog")],
                                              keptInPlace: [id("dialog")]) == [])
    #expect(state.curtainAnchor(order: order) == id("c"))
    #expect(state.curtainAnchor(order: order, keptInPlace: [id("dialog")]) == id("dialog"))
    // A hidden tab in front of the kept window moves behind it.
    let exposed = [entry("a", left), entry("c", right), entry("b", left), entry("dialog", dialog), entry("d", right)]
    #expect(state.sharedCurtainStackingRepair(order: exposed, curtainBounds: bounds, aboveCurtain: [id("dialog")],
                                              keptInPlace: [id("dialog")]) == [id("dialog"), id("a")])
}
