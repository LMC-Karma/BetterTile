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
    // The settled size less one whole step and a point, so any step rounds inside the pane.
    #expect(snap.placements.first { $0.windowID == top }?.frame.size.height
        == before.size.height + 4 - SteppedSizeAcceptance.maximumShortfall - 1)
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
    #expect(snap.placements.first { $0.windowID == top }?.frame.size.height
        == upper.size.height + 4 - SteppedSizeAcceptance.maximumShortfall - 1)
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

/// A protected neighbour, such as a second Terminal that landed exactly on
/// its pane, keeps its edges; the overflowing window takes a gap instead.
@Test func aProtectedNeighbourKeepsTheDivider() throws {
    let state = rows()
    let upper = try slot(top, state)
    let snap = try #require(state.snappingToSteppedSizes(
        [top: BTSize(width: upper.size.width, height: upper.size.height + 4)], protecting: [bottom],
        in: bounds, windows: [window(top), window(bottom)]))
    #expect(snap.snaps.isEmpty)
    #expect(snap.state.layout == state.layout)
}

/// The request for more than one step less never goes below a minimum the
/// write itself would refuse. A seed is another window's minimum and is
/// not a floor.
@Test func theStepDownRequestKeepsAKnownMinimum() throws {
    let state = rows()
    let before = try slot(top, state)
    let lower = try slot(bottom, state)
    let settled = [top: BTSize(width: before.size.width, height: before.size.height + 4)]
    let neighbour = window(bottom, minimumHeight: lower.size.height)
    var proven = window(top, minimumHeight: before.size.height - 10)
    proven.constraints.minimumSizeSource = .probe
    let clamped = try #require(state.snappingToSteppedSizes(settled, in: bounds, windows: [proven, neighbour]))
    #expect(clamped.placements.first { $0.windowID == top }?.frame.size.height == before.size.height - 10)
    var seeded = proven
    seeded.constraints.minimumSizeSource = .seed
    let free = try #require(state.snappingToSteppedSizes(settled, in: bounds, windows: [seeded, neighbour]))
    #expect(free.placements.first { $0.windowID == top }?.frame.size.height
        == before.size.height + 4 - SteppedSizeAcceptance.maximumShortfall - 1)
}

@Test func aGridIsLearnedFromSettledLengths() throws {
    // Terminal on a 1920×968 display: heights are 4 + 15·k. Two lengths 30
    // or 60 points apart cannot tell 15 from 20 or 30, so only the latest
    // length is kept until a third shows the step.
    let two = try #require(SteppedGrid(observed: [454, 424]))
    #expect(two.step == nil && two.offset == 424)
    #expect(SteppedGrid(observed: [439, 499])?.step == nil)
    #expect(SteppedGrid(observed: [439, 499, 454])?.step == 15)
    let grid = try #require(SteppedGrid(observed: [454, 424, 439]))
    #expect(grid.step == 15)
    #expect(grid.contains(439) && grid.contains(499) && !grid.contains(447))
    #expect(grid.request(inside: 447) == 439)
    #expect(grid.lengths(near: 447, within: 24).sorted() == [424, 439, 454, 469])
    // Without a step, both known lengths stay usable.
    #expect(two.contains(454) && two.contains(424) && !two.contains(439))
    #expect(two.request(inside: 447) == 424)
    #expect(two.request(inside: 500) == 454)
    #expect(two.request(inside: 520) == nil)
        // Fractional cells rounded to whole points share no step: no grid.
    #expect(SteppedGrid(observed: [366.1, 373.4, 380.7]) == nil)
    #expect(SteppedGrid(observed: [454])?.step == nil)
    #expect(SteppedGrid(observed: [454])?.request(inside: 470) == 454)
    #expect(SteppedGrid(observed: [454])?.request(inside: 500) == nil)
    // An area smaller than the one known length asks for more than a step
    // less, which rounds to a lower row and teaches the step.
    #expect(SteppedGrid(observed: [454])?.request(inside: 447) == 454 - SteppedSizeAcceptance.maximumShortfall - 1)
    // Lengths one point apart are no window's steps.
    #expect(SteppedGrid(observed: [454, 455]) == nil)
}

/// Live, Two Rows on a 968-point work area: each window area is 447 high,
/// and both Terminals take 4 + 15·k. 439 + 454 = 893 of 894 points: the
/// divider moves 7 points so one Terminal fills its pane and the other
/// takes 439 with one point to spare. Which tab is selected in the top pane
/// does not change it.
@Test func twoTerminalGridsShareTheirDivider() throws {
    let work = BTRect(x: 0, y: 30, width: 1920, height: 968)
    let t1 = WindowID(rawValue: "t1"), t2 = WindowID(rawValue: "t2"), recents = WindowID(rawValue: "recents")
    var state = TabbedLayoutState(preset: .rows)
    state.reconcile(windowIDs: [t1, recents, t2], removed: [], focused: nil)
    state.move(t2, to: state.panes[1].id)
    state.select(t1)
    let windows = [t1, t2, recents].map {
        WindowSnapshot(id: $0, processIdentifier: 1, frame: work, displayID: DisplayID(rawValue: "live"),
                       constraints: WindowConstraints(minimumSize: BTSize(width: 177, height: 124)))
    }
    let grid = try #require(SteppedGrid(observed: [454, 439]))
    let grids: [WindowID: [SplitAxis: SteppedGrid]] = [t1: [.horizontal: grid], t2: [.horizontal: grid]]
    func heights(_ state: TabbedLayoutState) -> [Double] {
        state.panes.compactMap { state.frames(in: work)[$0.id] }.map { TabbedLayoutState.contentFrame($0).size.height }
    }
    #expect(heights(state).map { $0.rounded() } == [447, 447])
    let fitted = state.fittingSteppedGrids(grids, in: work, windows: windows)
    #expect(heights(fitted).map { $0.rounded() } == [440, 454])
    #expect(fitted.preferredPaneRatios == state.preferredPaneRatios)
    let requests = TabbedLayoutState.requestingSteppedGrids(try fitted.placements(in: work, windows: windows), grids)
    #expect(requests.first { $0.windowID == t1 }?.frame.size.height == 439)
    #expect(abs((requests.first { $0.windowID == t2 }?.frame.size.height ?? 0) - 454) < 0.01)
    var other = state
    other.select(recents)
    #expect(heights(other.fittingSteppedGrids(grids, in: work, windows: windows)) == heights(fitted))
}
