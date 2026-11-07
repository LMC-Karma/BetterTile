import Testing
@testable import BetterTileCore

// A window that a drag carried from another desktop floats in the Tabbed
// state only for its drag. These are the two operations it needs.

private func id(_ name: String) -> WindowID { WindowID(rawValue: name) }

@Test func anOutsideWindowFloatsAndIsForgottenWithoutTouchingThePanes() {
    let a = id("a"), b = id("b"), outside = id("outside")
    var state = TabbedLayoutState(preset: .columns)
    state.reconcile(windowIDs: [a, b], removed: [], focused: a)
    let before = state
    state.addFloating(outside)
    #expect(state.floatingWindowIDs == [outside])
    #expect(state.panes == before.panes)
    #expect(state.layout.root == before.layout.root)
    #expect(state.automaticallyFloatingWindowIDs.isEmpty)
    state.forgetFloating(outside)
    #expect(state == before)
}

@Test func addingOrForgettingAFloatDoesNotChangeAPaneMember() {
    let a = id("a"), b = id("b")
    var state = TabbedLayoutState(preset: .columns)
    state.reconcile(windowIDs: [a, b], removed: [], focused: a)
    let before = state
    state.addFloating(a)
    #expect(state == before)
    state.forgetFloating(b)
    #expect(state == before)
}

@Test func anOutsideFloatCanJoinAPaneAsItsSelectedTab() {
    let a = id("a"), outside = id("outside")
    var state = TabbedLayoutState(preset: .columns)
    state.reconcile(windowIDs: [a], removed: [], focused: a)
    let pane = state.panes[1].id
    state.move(outside, to: pane)
    #expect(state.pane(containing: outside) == nil, "A window from outside the layout joined without a float")
    state.addFloating(outside)
    state.move(outside, to: pane)
    #expect(state.pane(containing: outside)?.id == pane)
    #expect(state.pane(containing: outside)?.selected == outside)
    #expect(!state.floatingWindowIDs.contains(outside))
}

/// The provisional float of a carried window can outlive the destination's
/// selection. The store removes it from that stored session by ID, also
/// while another session is active, and changes nothing else.
@Test func aStoredInactiveSessionForgetsAFloatByID() throws {
    let display = DisplayID(rawValue: "display"), a = id("a"), b = id("b"), carried = id("carried")
    var store = LayoutSessionStore()
    var session = store.select(displayID: display, nativeSpaceID: .init(rawValue: 2), defaultMode: .tabbed)
    var state = TabbedLayoutState(preset: .columns)
    state.reconcile(windowIDs: [a, b], removed: [], focused: a)
    let panes = state.panes
    state.addFloating(carried)
    session.tabbedState = state
    session.windowIDs = state.windowIDs
    let committed = store.commit(session, replacing: session.revision)
    let stored = try #require(committed)
    let other = store.select(displayID: display, nativeSpaceID: .init(rawValue: 3), defaultMode: .manual)

    // A pane member and an unknown session are not changed.
    let changedMember = store.forgetTabbedFloat(a, sessionID: stored.id, on: display)
    let changedUnknown = store.forgetTabbedFloat(carried, sessionID: DesktopSessionID(), on: display)
    #expect(!changedMember)
    #expect(!changedUnknown)
    #expect(store.allSessions(for: display).first { $0.id == stored.id }?.revision == stored.revision)

    let forgot = store.forgetTabbedFloat(carried, sessionID: stored.id, on: display)
    #expect(forgot)
    let updated = try #require(store.allSessions(for: display).first { $0.id == stored.id })
    #expect(updated.tabbedState?.floatingWindowIDs.isEmpty == true)
    #expect(updated.tabbedState?.panes == panes)
    #expect(updated.revision > stored.revision)
    // The selection does not change.
    #expect(store.session(for: display)?.id == other.id)
    let forgotAgain = store.forgetTabbedFloat(carried, sessionID: stored.id, on: display)
    #expect(!forgotAgain)
}
