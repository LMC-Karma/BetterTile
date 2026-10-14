import Foundation
import Testing
@testable import BetterTileCore

private let bounds = BTRect(x: 0, y: 0, width: 1000, height: 800)
private let top = WindowID(rawValue: "top")
private let bottom = WindowID(rawValue: "bottom")

private func window(_ id: WindowID, minimumHeight: Double = 80) -> WindowSnapshot {
    WindowSnapshot(id: id, processIdentifier: 1, frame: bounds, displayID: DisplayID(rawValue: "snap"),
                   constraints: WindowConstraints(minimumSize: BTSize(width: 120, height: minimumHeight)))
}

/// Two rows: `top` over `bottom`.
private func rows() -> TabbedLayoutState {
    var state = TabbedLayoutState(preset: .rows)
    state.reconcile(windowIDs: [top, bottom], removed: [], focused: nil)
    state.move(bottom, to: state.panes[1].id)
    return state
}

private func slot(_ id: WindowID, _ state: TabbedLayoutState) throws -> BTRect {
    try #require(state.layout.placements(in: bounds).first { $0.windowID == id }?.frame)
}

/// Terminal rounded its height up to the next row: its pane grows by the
/// overflow and the pane below gives it up. The user's pane sizes stay.
@Test func aWindowThatRoundsUpGrowsItsPane() throws {
    let state = rows()
    let before = try slot(top, state)
    let lower = try slot(bottom, state)
    let settled = BTSize(width: before.size.width, height: before.size.height + 4)
    let snap = try #require(state.snappingToSteppedSizes([top: settled], in: bounds, windows: [window(top), window(bottom)]))
    #expect(try slot(top, snap.state).approximatelyEquals(BTRect(origin: before.origin, size: settled), tolerance: 0.01))
    #expect(abs(try slot(bottom, snap.state).minY - (lower.minY + 4)) < 0.01)
    #expect(abs(try slot(bottom, snap.state).maxY - lower.maxY) < 0.01)
    #expect(snap.snaps == [TabbedSteppedSnap(windowID: top, axis: .horizontal, delta: 4, neighbors: [bottom])])
    #expect(snap.state.preferredPaneRatios == state.preferredPaneRatios)
    #expect(snap.placements.first { $0.windowID == top }?.frame
        .approximatelyEquals(BTRect(origin: before.origin, size: settled), tolerance: 0.01) == true)
}

/// A window that rounded down shrinks its pane to match; the neighbour grows.
/// The bottom pane has only its top edge to move.
@Test func aWindowThatRoundsDownShrinksItsPaneFromEitherEdge() throws {
    let state = rows()
    let before = try slot(bottom, state)
    let settled = BTSize(width: before.size.width - 7, height: before.size.height - 6)
    let snap = try #require(state.snappingToSteppedSizes([bottom: settled], in: bounds, windows: [window(top), window(bottom)]))
    let after = try slot(bottom, snap.state)
    #expect(abs(after.size.height - settled.height) < 0.01)
    #expect(abs(after.maxY - before.maxY) < 0.01)
    // One pane wide: no divider can follow the width, so that gap stays.
    #expect(abs(after.size.width - before.size.width) < 0.01)
    #expect(snap.snaps.map(\.axis) == [.horizontal])
}

/// Two columns snap widths.
@Test func widthsSnapToo() throws {
    var state = TabbedLayoutState(preset: .columns)
    state.reconcile(windowIDs: [top, bottom], removed: [], focused: nil)
    state.move(bottom, to: state.panes[1].id)
    let before = try slot(top, state)
    let settled = BTSize(width: before.size.width + 5, height: before.size.height)
    let snap = try #require(state.snappingToSteppedSizes([top: settled], in: bounds, windows: [window(top), window(bottom)]))
    #expect(abs(try slot(top, snap.state).size.width - settled.width) < 0.01)
}

/// The neighbour is at its minimum, so the pane cannot grow. The window is
/// asked for one step less instead, and the panes stay.
@Test func aNeighbourAtItsMinimumAsksTheWindowForOneStepLess() throws {
    let state = rows()
    let before = try slot(top, state)
    let lower = try slot(bottom, state)
    let settled = BTSize(width: before.size.width, height: before.size.height + 4)
    let snap = try #require(state.snappingToSteppedSizes(
        [top: settled], in: bounds, windows: [window(top), window(bottom, minimumHeight: lower.size.height)]))
    #expect(snap.snaps.isEmpty)
    #expect(snap.state.layout == state.layout)
    #expect(snap.placements.first { $0.windowID == top }?.frame.size.height == before.size.height - 4)
    // A window that settled smaller with nowhere to go keeps its gap: nothing to write.
    let smaller = BTSize(width: before.size.width, height: before.size.height - 4)
    let constrained = [window(top, minimumHeight: before.size.height), window(bottom)]
    #expect(state.snappingToSteppedSizes([top: smaller], in: bounds, windows: constrained) == nil)
}

/// Two stepped windows share the divider: neither moves it, so neither
/// chases the other. The overflowing one asks for one step less.
@Test func twoSteppedWindowsLeaveTheirSharedDivider() throws {
    let state = rows()
    let upper = try slot(top, state)
    let lower = try slot(bottom, state)
    let snap = try #require(state.snappingToSteppedSizes(
        [top: BTSize(width: upper.size.width, height: upper.size.height + 4),
         bottom: BTSize(width: lower.size.width, height: lower.size.height - 3)],
        in: bounds, windows: [window(top), window(bottom)]))
    #expect(snap.state.layout == state.layout)
    #expect(snap.placements.first { $0.windowID == top }?.frame.size.height == upper.size.height - 4)
    #expect(snap.placements.first { $0.windowID == bottom }?.frame == lower)
}

@Test func exactAndFarSizesNeedNoSnap() throws {
    let state = rows()
    let upper = try slot(top, state)
    let windows = [window(top), window(bottom)]
    #expect(state.snappingToSteppedSizes([top: upper.size], in: bounds, windows: windows) == nil)
    let far = BTSize(width: upper.size.width, height: upper.size.height + 60)
    #expect(state.snappingToSteppedSizes([top: far], in: bounds, windows: windows) == nil)
}

/// Terminal rounds to its next row. Inside a write that accepts stepped
/// sizes, neither a shrink that stopped one row short (600 to 495 lands at
/// 499) nor a growth past the request (447 lands at 454) teaches a minimum,
/// at once or through a later snapshot. A larger refusal still does.
@Test func aSteppedReadbackTeachesNoMinimum() {
    let id = WindowID(rawValue: "terminal")
    var learner = WindowMinimumSizeLearner()
    learner.acceptsSteppedSizes = true
    let shrink = learner.observeWriteReadback(
        windowID: id, application: "Terminal", requested: BTRect(x: 0, y: 0, width: 800, height: 495),
        previous: BTRect(x: 0, y: 0, width: 800, height: 600), actual: BTRect(x: 0, y: 0, width: 800, height: 499), now: 0)
    #expect(!shrink)
    _ = learner.observeWriteReadback(
        windowID: id, application: "Terminal", requested: BTRect(x: 0, y: 0, width: 800, height: 447),
        previous: BTRect(x: 0, y: 0, width: 800, height: 300), actual: BTRect(x: 0, y: 0, width: 800, height: 454), now: 1)
    learner.recordClampCandidate(windowID: id, requested: BTSize(width: 800, height: 447),
                                 actual: BTSize(width: 800, height: 454), now: 1)
    let confirmed = learner.confirmClampCandidate(windowID: id, application: "Terminal", size: BTSize(width: 800, height: 454), now: 2)
    #expect(!confirmed)
    #expect(learner.learnedSizes[id] == nil)

    let refused = learner.observeWriteReadback(
        windowID: id, application: "Terminal", requested: BTRect(x: 0, y: 0, width: 800, height: 400),
        previous: BTRect(x: 0, y: 0, width: 800, height: 600), actual: BTRect(x: 0, y: 0, width: 800, height: 450), now: 3)
    #expect(refused)
    #expect(learner.learnedSizes[id]?.height == 450)

    // Outside such a write, a shrink that stopped short is still a minimum.
    var plain = WindowMinimumSizeLearner()
    let learned = plain.observeWriteReadback(
        windowID: id, requested: BTRect(x: 0, y: 0, width: 800, height: 495),
        previous: BTRect(x: 0, y: 0, width: 800, height: 600), actual: BTRect(x: 0, y: 0, width: 800, height: 499), now: 0)
    #expect(learned)
}
