import Foundation
import Testing
@testable import BetterTileCore

private let snapBounds = BTRect(x: -200, y: 100, width: 1200, height: 900)
private func snapID(_ name: String) -> WindowID { WindowID(rawValue: name) }
private func snapWindow(_ name: String, minimum: BTSize = BTSize(width: 120, height: 80)) -> WindowSnapshot {
    WindowSnapshot(id: snapID(name), processIdentifier: 1, frame: BTRect(x: 0, y: 0, width: 400, height: 400),
                   displayID: DisplayID(rawValue: "snap"), constraints: WindowConstraints(minimumSize: minimum))
}

@Test func tabbedSnapJoinsExactOccupiedPaneWithoutMovingOtherTabs() throws {
    let source = snapID("source"), hidden = snapID("hidden"), destination = snapID("destination")
    var state = TabbedLayoutState(preset: .columns)
    state.reconcile(windowIDs: [source, hidden], removed: [], focused: source)
    let left = state.panes[0].id, right = state.panes[1].id
    state.activatePane(right)
    state.reconcile(windowIDs: [source, hidden, destination], removed: [], focused: destination)
    let plan = try #require(TabbedSnapPlanner.plan(sourceWindowID: source, action: .rightHalf, state: state,
                                                  windows: [snapWindow("source"), snapWindow("hidden"), snapWindow("destination")],
                                                  in: snapBounds))
    #expect(plan.state.panes.map(\.id) == state.panes.map(\.id))
    #expect(plan.state.panes[0].tabs == [hidden] && plan.state.panes[0].selected == hidden)
    #expect(plan.state.panes[1].tabs == [destination, source] && plan.state.panes[1].selected == source)
    #expect(plan.state.activePaneID == right && plan.destinationPaneID == right)
    #expect(plan.targetFrame == BTRect(x: 400, y: 100, width: 600, height: 900))
    #expect(plan.state.logicalFrames(in: snapBounds)[left] == BTRect(x: -200, y: 100, width: 600, height: 900))
    #expect(Set(plan.placements.map(\.windowID)) == [source, hidden])
    #expect(plan.preservesTarget(in: plan.state, within: snapBounds))
}

@Test func tabbedSnapCreatesHalfAndKeepsTheEmptiedOriginalPane() throws {
    let source = snapID("source")
    var state = TabbedLayoutState()
    state.reconcile(windowIDs: [source], removed: [], focused: source)
    let oldPane = state.panes[0].id
    let plan = try #require(TabbedSnapPlanner.plan(sourceWindowID: source, action: .rightHalf, state: state,
                                                  windows: [snapWindow("source")], in: snapBounds))
    #expect(plan.state.panes.count == 2)
    #expect(plan.state.panes.first { $0.id == oldPane }?.tabs.isEmpty == true)
    #expect(plan.state.logicalFrames(in: snapBounds)[oldPane] == BTRect(x: -200, y: 100, width: 600, height: 900))
    #expect(plan.targetFrame == BTRect(x: 400, y: 100, width: 600, height: 900))
    #expect(plan.placements == [Placement(windowID: source, frame: BTRect(x: 403, y: 134, width: 597, height: 866))])
    #expect(plan.state.floatingWindowIDs.isEmpty)
}

private struct SnapCase: Sendable {
    let action: WindowAction
    let target: BTRect
}
private let snapCases: [SnapCase] = [
    .init(action: .leftHalf, target: BTRect(x: -200, y: 100, width: 600, height: 900)),
    .init(action: .rightHalf, target: BTRect(x: 400, y: 100, width: 600, height: 900)),
    .init(action: .topHalf, target: BTRect(x: -200, y: 100, width: 1200, height: 450)),
    .init(action: .bottomHalf, target: BTRect(x: -200, y: 550, width: 1200, height: 450)),
    .init(action: .leftThird, target: BTRect(x: -200, y: 100, width: 400, height: 900)),
    .init(action: .centerThird, target: BTRect(x: 200, y: 100, width: 400, height: 900)),
    .init(action: .rightThird, target: BTRect(x: 600, y: 100, width: 400, height: 900)),
    .init(action: .leftTwoThirds, target: BTRect(x: -200, y: 100, width: 800, height: 900)),
    .init(action: .rightTwoThirds, target: BTRect(x: 200, y: 100, width: 800, height: 900)),
    .init(action: .topLeftQuarter, target: BTRect(x: -200, y: 100, width: 600, height: 450)),
    .init(action: .topRightQuarter, target: BTRect(x: 400, y: 100, width: 600, height: 450)),
    .init(action: .bottomLeftQuarter, target: BTRect(x: -200, y: 550, width: 600, height: 450)),
    .init(action: .bottomRightQuarter, target: BTRect(x: 400, y: 550, width: 600, height: 450)),
    .init(action: .topLeftSixth, target: BTRect(x: -200, y: 100, width: 400, height: 450)),
    .init(action: .topCenterSixth, target: BTRect(x: 200, y: 100, width: 400, height: 450)),
    .init(action: .topRightSixth, target: BTRect(x: 600, y: 100, width: 400, height: 450)),
    .init(action: .bottomLeftSixth, target: BTRect(x: -200, y: 550, width: 400, height: 450)),
    .init(action: .bottomCenterSixth, target: BTRect(x: 200, y: 550, width: 400, height: 450)),
    .init(action: .bottomRightSixth, target: BTRect(x: 600, y: 550, width: 400, height: 450)),
]

private func snapGrid(gap: Double = 6) -> (TabbedLayoutState, [WindowSnapshot]) {
    var state = TabbedLayoutState(preset: .grid)
    let windows = (0..<4).map { snapWindow("w\($0)") }
    for (pane, window) in zip(state.panes, windows) {
        state.activatePane(pane.id)
        state.reconcile(windowIDs: [window.id], removed: [], focused: window.id)
    }
    var layout = state.layout
    layout.metrics.paneGap = gap
    state.synchronize(with: layout)
    return (state, windows)
}

@Test(arguments: snapCases, [0.0, 6.0, 12.0])
private func tabbedSnapAllRegionsPreserveGroupsAndCoverWorkArea(example: SnapCase, gap: Double) throws {
    let (state, windows) = snapGrid(gap: gap)
    let source = windows[0].id
    let original = state
    let plan = try #require(TabbedSnapPlanner.plan(sourceWindowID: source, action: example.action, state: state,
                                                  windows: windows, in: snapBounds))
    #expect(state == original)
    #expect(plan.targetFrame == example.target)
    #expect(plan.preservesTarget(in: plan.state, within: snapBounds))
    #expect(plan.state.windowIDs == state.windowIDs)
    #expect(plan.state.floatingWindowIDs.isEmpty)
    for old in state.panes {
        let kept = try #require(plan.state.panes.first { $0.id == old.id })
        if old.id != plan.destinationPaneID {
            #expect(kept.tabs == old.tabs.filter { $0 != source })
            #expect(kept.selected == old.selected.flatMap { $0 == source ? nil : $0 })
        }
    }
    let logical = plan.state.logicalFrames(in: snapBounds)
    #expect(logical.count == plan.state.panes.count)
    #expect(abs(logical.values.reduce(0) { $0 + $1.area } - snapBounds.area) < 0.001)
    let frames = Array(logical.values)
    for i in frames.indices {
        #expect(frames[i].minX >= snapBounds.minX - 0.001 && frames[i].maxX <= snapBounds.maxX + 0.001)
        #expect(frames[i].minY >= snapBounds.minY - 0.001 && frames[i].maxY <= snapBounds.maxY + 0.001)
        for j in frames.indices where j > i {
            let width = min(frames[i].maxX, frames[j].maxX) - max(frames[i].minX, frames[j].minX)
            let height = min(frames[i].maxY, frames[j].maxY) - max(frames[i].minY, frames[j].minY)
            #expect(width < 0.001 || height < 0.001)
        }
    }
    #expect(plan.placements.count == plan.state.selectedWindowIDs.count)
    for placement in plan.placements {
        let pane = try #require(plan.state.paneID(containing: placement.windowID))
        let frame = try #require(plan.state.frames(in: snapBounds)[pane])
        #expect(placement.frame.minY == frame.minY + 34)
        #expect(placement.frame.size.height == frame.size.height - 34)
    }
    let again = try #require(TabbedSnapPlanner.plan(sourceWindowID: source, action: example.action, state: state,
                                                   windows: windows.reversed(), in: snapBounds))
    #expect(again.placements == plan.placements)
    for old in state.panes { #expect(again.state.logicalFrames(in: snapBounds)[old.id] == logical[old.id]) }
}

private enum SnapSource: CaseIterable { case selectedMiddle, selectedLast, hidden, lone, floated }
@Test(arguments: SnapSource.allCases, [false, true])
private func tabbedSnapExactJoinPreservesTabOrderAndFloats(sourceKind: SnapSource, occupied: Bool) throws {
    let a = snapID("a"), b = snapID("b"), c = snapID("c"), d = snapID("d"), floating = snapID("z")
    var state = TabbedLayoutState(preset: .columns)
    state.reconcile(windowIDs: sourceKind == .lone ? [a] : [a, b, c], removed: [], focused: a)
    let left = state.panes[0].id, right = state.panes[1].id
    let source: WindowID
    switch sourceKind {
    case .selectedMiddle: source = b; state.select(b)
    case .selectedLast: source = c; state.select(c)
    case .hidden: source = b
    case .lone: source = a
    case .floated: source = b; state.float(b)
    }
    let selectedBeforeFloat = state.activeWindowID
    state.reconcile(windowIDs: [floating], removed: [], focused: nil)
    state.float(floating)
    if let selectedBeforeFloat { state.select(selectedBeforeFloat) }
    if occupied { state.activatePane(right); state.reconcile(windowIDs: [d], removed: [], focused: d) }
    let beforeLeft = try #require(state.panes.first { $0.id == left })
    let windows = ["a", "b", "c", "d", "z"].map { snapWindow($0) }
    let plan = try #require(TabbedSnapPlanner.plan(sourceWindowID: source, action: .rightHalf, state: state,
                                                  windows: windows, in: snapBounds))
    let remaining = try #require(plan.state.panes.first { $0.id == left })
    #expect(remaining.tabs == beforeLeft.tabs.filter { $0 != source })
    let expectedSelected: WindowID? = switch sourceKind {
    case .selectedMiddle: c
    case .selectedLast: b
    case .hidden, .floated: a
    case .lone: nil
    }
    #expect(remaining.selected == expectedSelected)
    #expect(plan.state.panes.first { $0.id == right }?.tabs == (occupied ? [d, source] : [source]))
    #expect(plan.state.floatingWindowIDs == [floating])
    #expect(plan.state.panes.count == 2 && plan.state.activeWindowID == source)
}

@Test func tabbedSnapWithinSamePaneSelectsWithoutReorderingOrDuplicating() throws {
    let a = snapID("a"), b = snapID("b")
    var state = TabbedLayoutState(preset: .columns)
    state.reconcile(windowIDs: [a, b], removed: [], focused: a)
    let windows = [snapWindow("a"), snapWindow("b")]
    let plan = try #require(TabbedSnapPlanner.plan(sourceWindowID: b, action: .leftHalf, state: state,
                                                  windows: windows, in: snapBounds))
    #expect(plan.state.panes[0].tabs == [a, b] && plan.state.panes[0].selected == b)
    #expect(plan.state.panes.map(\.id) == state.panes.map(\.id))
    #expect(plan.state.logicalFrames(in: snapBounds) == state.logicalFrames(in: snapBounds))
    let repeated = try #require(TabbedSnapPlanner.plan(sourceWindowID: b, action: .leftHalf, state: plan.state,
                                                      windows: windows, in: snapBounds))
    #expect(repeated.state == plan.state)
    #expect(!plan.preservesTarget(in: state, within: snapBounds))
    #expect(!plan.preservesTarget(in: plan.state, within: snapBounds.offsetBy(dx: 1, dy: 0)))
}

@Test func tabbedSnapIgnoresHiddenMinimumButChecksPromotedSelection() throws {
    let a = snapID("a"), b = snapID("b"), c = snapID("c")
    var state = TabbedLayoutState(preset: .columns)
    state.reconcile(windowIDs: [a, b, c], removed: [], focused: a)
    let windows = [snapWindow("a"), snapWindow("b"), snapWindow("c", minimum: BTSize(width: 10000, height: 10000))]
    let plan = try #require(TabbedSnapPlanner.plan(sourceWindowID: a, action: .rightHalf, state: state,
                                                  windows: windows, in: snapBounds))
    #expect(plan.state.panes[0].selected == b)
    #expect(!plan.placements.contains { $0.windowID == c })
    state.select(b)
    #expect(TabbedSnapPlanner.plan(sourceWindowID: b, action: .rightHalf, state: state,
                                   windows: windows, in: snapBounds) == nil)
}

@Test(arguments: [BTSize(width: 598, height: 80), BTSize(width: 120, height: 417)])
func tabbedSnapRejectsMinimaThatChangeTheRequestedRegion(minimum: BTSize) {
    let source = snapID("source")
    var state = TabbedLayoutState(preset: .grid)
    state.reconcile(windowIDs: [source], removed: [], focused: source)
    #expect(TabbedSnapPlanner.plan(sourceWindowID: source, action: .bottomRightQuarter, state: state,
                                   windows: [snapWindow("source", minimum: minimum)], in: snapBounds) == nil)
}

@Test func tabbedSnapAllowsFittingRemainderButRevalidatesLaterTargetCorrections() throws {
    let a = snapID("a"), b = snapID("b"), c = snapID("c")
    let tree = BentoNode.partition(BentoPartition(axis: .vertical,
        first: .partition(BentoPartition(axis: .horizontal, first: .leaf(a), second: .leaf(b))), second: .leaf(c)))
    var state = try #require(TabbedLayoutState(adopting: BentoLayoutState(root: tree, metrics: BentoLayoutMetrics(paneGap: 6))))
    state.reconcile(windowIDs: [snapID("source")], removed: [], focused: nil)
    let windows = [snapWindow("source"), snapWindow("a", minimum: BTSize(width: 120, height: 500)),
                   snapWindow("b"), snapWindow("c")]
    let plan = try #require(TabbedSnapPlanner.plan(sourceWindowID: snapID("source"), action: .rightHalf, state: state,
                                                  windows: windows, in: snapBounds))
    #expect(plan.placements.first { $0.windowID == a }?.frame.size.height == 500)
    #expect(plan.preservesTarget(in: plan.state, within: snapBounds))
    var learned = windows
    learned[0].constraints.minimumSize.width = 700
    let corrected = try plan.state.fittingMinimumWidths(in: snapBounds, windows: learned)
    #expect(!plan.preservesTarget(in: corrected, within: snapBounds))
}

@Test func tabbedSnapNewRegionPreservesExistingVacanciesAndCountsNewOnes() throws {
    var state = TabbedLayoutState()
    let source = snapID("source")
    state.reconcile(windowIDs: [source], removed: [], focused: source)
    let original = state.panes[0].id
    let plan = try #require(TabbedSnapPlanner.plan(sourceWindowID: source, action: .topCenterSixth, state: state,
                                                  windows: [snapWindow("source")], in: snapBounds))
    #expect(plan.state.panes.count == 4)
    #expect(plan.state.panes.filter { $0.tabs.isEmpty }.count == 3)
    #expect(plan.state.panes.contains { $0.id == original && $0.tabs.isEmpty })
    #expect(plan.placements.count == 1)
    let tooSmall = BTRect(x: 0, y: 0, width: 210, height: 900)
    #expect(TabbedSnapPlanner.plan(sourceWindowID: source, action: .rightHalf, state: state,
                                   windows: [snapWindow("source", minimum: BTSize(width: 1, height: 1))], in: tooSmall) == nil)
}

private func snapManyPanes(_ count: Int, exactHalf: Bool = false) throws -> (TabbedLayoutState, [WindowSnapshot]) {
    let windows = (0..<count).map { snapWindow("many-\($0)") }
    let nodes = windows.map { BentoNode.leaf($0.id) }
    let root: BentoNode = exactHalf
        ? .partition(BentoPartition(axis: .vertical, first: nodes[0],
                                    second: .partition(BentoPartition(axis: .horizontal, children: Array(nodes.dropFirst())))))
        : .partition(BentoPartition(axis: .vertical, children: nodes))
    return (try #require(TabbedLayoutState(adopting: BentoLayoutState(root: root, metrics: BentoLayoutMetrics(paneGap: 6)))), windows)
}

@Test(arguments: [12, 14])
func tabbedSnapJoinsAtOrAbovePaneCapButCannotCreate(paneCount: Int) throws {
    let (state, windows) = try snapManyPanes(paneCount, exactHalf: true)
    let bounds = BTRect(x: 0, y: 0, width: 6000, height: 6000)
    let source = windows[1].id
    let plan = try #require(TabbedSnapPlanner.plan(sourceWindowID: source, action: .leftHalf, state: state,
                                                  windows: windows, in: bounds))
    #expect(plan.state.panes.count == paneCount)
    #expect(plan.state.panes[0].tabs == [windows[0].id, source])
    #expect(plan.state.panes[1].tabs.isEmpty)
    #expect(TabbedSnapPlanner.plan(sourceWindowID: source, action: .centerThird, state: state,
                                   windows: windows, in: bounds) == nil)
}

@Test func tabbedSnapAssignsElevenRetainedPanesWithRestrictiveSlots() throws {
    var (state, windows) = try snapManyPanes(11)
    let bounds = BTRect(x: -300, y: -100, width: 4400, height: 2400)
    let source = windows[0].id
    for index in 1...5 { windows[index].constraints.minimumSize.width = 1000 }
    let plan = try #require(TabbedSnapPlanner.plan(sourceWindowID: source, action: .leftHalf, state: state,
                                                  windows: windows, in: bounds))
    #expect(plan.state.panes.count == 12 && plan.state.windowIDs == state.windowIDs)
    for window in windows.dropFirst().prefix(5) {
        #expect(plan.placements.first { $0.windowID == window.id }!.frame.size.width >= 1000)
    }
    windows[6].constraints.minimumSize.width = 1000
    #expect(TabbedSnapPlanner.plan(sourceWindowID: source, action: .leftHalf, state: state,
                                   windows: windows, in: bounds) == nil)
    // An unrelated explicit float does not consume a pane or enter allocation.
    state.reconcile(windowIDs: [snapID("float")], removed: [], focused: nil)
    state.float(snapID("float"))
    windows[6].constraints.minimumSize.width = 120
    let floated = try #require(TabbedSnapPlanner.plan(sourceWindowID: source, action: .leftHalf, state: state,
                                                     windows: windows + [snapWindow("float")], in: bounds))
    #expect(floated.state.floatingWindowIDs == [snapID("float")])
}

@Test(arguments: [false, true])
func tabbedSnapRejectsFixedSizeParticipantsEvenWhenCurrentSizeFits(sourceFixed: Bool) throws {
    var state = TabbedLayoutState(preset: .columns)
    state.reconcile(windowIDs: [snapID("source"), snapID("successor")], removed: [], focused: snapID("source"))
    var windows = [snapWindow("source"), snapWindow("successor")]
    let possible = try #require(TabbedSnapPlanner.plan(sourceWindowID: snapID("source"), action: .rightHalf, state: state,
                                                      windows: windows, in: snapBounds))
    let index = sourceFixed ? 0 : 1
    windows[index].frame = try #require(possible.placements.first { $0.windowID == windows[index].id }?.frame)
    windows[index].constraints.isResizable = false
    #expect(TabbedSnapPlanner.plan(sourceWindowID: snapID("source"), action: .rightHalf, state: state,
                                   windows: windows, in: snapBounds) == nil)
    windows[index].frame.size.width -= 10
    #expect(TabbedSnapPlanner.plan(sourceWindowID: snapID("source"), action: .rightHalf, state: state,
                                   windows: windows, in: snapBounds) == nil)
}

@Test func tabbedSnapGeometryExtractionKeepsLegacyBentoNarrowCutRefusal() {
    let windows = (0..<6).map { snapWindow("legacy-\($0)", minimum: BTSize(width: 1, height: 1)) }
    let state = BentoLayoutState(root: .partition(BentoPartition(axis: .vertical, children: windows.map { .leaf($0.id) })))
    let bounds = BTRect(x: 0, y: 0, width: 12000, height: 900)
    let result = BentoDropPlanner().plan(intent: .snap(action: .rightTwoThirds, frame: BTRect(x: 4000, y: 0, width: 8000, height: 900)),
        sourceWindowID: windows[0].id, state: state,
        baselineFrames: Dictionary(uniqueKeysWithValues: windows.map { ($0.id, $0.frame) }),
        constraints: Dictionary(uniqueKeysWithValues: windows.map { ($0.id, $0.constraints) }), contextWindowIDs: [], in: bounds)
    #expect(result == nil)
    #expect(BentoDropPlanner().maximumManagedWindows == 6)
}

@Test(arguments: WindowAction.allCases.filter { !BentoDropPlanner.partitionActions.contains($0) })
func tabbedSnapRejectsUnsupportedActions(action: WindowAction) {
    var state = TabbedLayoutState()
    state.reconcile(windowIDs: [snapID("source")], removed: [], focused: nil)
    #expect(TabbedSnapPlanner.plan(sourceWindowID: snapID("source"), action: action, state: state,
                                   windows: [snapWindow("source")], in: snapBounds) == nil)
}

@Test func tabbedSnapRejectsUnavailableSourcesBoundsAndSelectedMinima() {
    var state = TabbedLayoutState(preset: .columns)
    state.reconcile(windowIDs: [snapID("source"), snapID("successor")], removed: [], focused: snapID("source"))
    let normal = [snapWindow("source"), snapWindow("successor")]
    for minimum in [BTSize(width: .nan, height: 80), BTSize(width: 120, height: .infinity),
                    BTSize(width: -1, height: 80), BTSize(width: 120, height: -1)] {
        for index in 0...1 {
            var windows = normal
            windows[index].constraints.minimumSize = minimum
            #expect(TabbedSnapPlanner.plan(sourceWindowID: snapID("source"), action: .rightHalf, state: state,
                                           windows: windows, in: snapBounds) == nil)
        }
    }
    for bounds in [BTRect(x: .nan, y: 0, width: 1200, height: 900), BTRect(x: 0, y: 0, width: .infinity, height: 900),
                   BTRect(x: 0, y: 0, width: 0, height: 900), BTRect(x: 0, y: 0, width: 1200, height: -1)] {
        #expect(TabbedSnapPlanner.plan(sourceWindowID: snapID("source"), action: .rightHalf, state: state,
                                       windows: normal, in: bounds) == nil)
    }
    for change: (inout WindowSnapshot) -> Void in [
        { $0.isFloating = true }, { $0.isHidden = true }, { $0.isFullScreen = true }, { $0.isMinimized = true },
        { $0.constraints.isMovable = false }, { $0.frame.origin.x = .nan },
    ] {
        var windows = normal
        change(&windows[0])
        #expect(TabbedSnapPlanner.plan(sourceWindowID: snapID("source"), action: .rightHalf, state: state,
                                       windows: windows, in: snapBounds) == nil)
    }
    #expect(TabbedSnapPlanner.plan(sourceWindowID: snapID("missing"), action: .rightHalf, state: state,
                                   windows: normal, in: snapBounds) == nil)
    #expect(TabbedSnapPlanner.plan(sourceWindowID: snapID("source"), action: .rightHalf, state: state,
                                   windows: [normal[0]], in: snapBounds) == nil)
}

@Test func tabbedSnapNewRegionMovesOnlySourceAndKeepsHiddenGroupsAndFloats() throws {
    var (state, windows) = snapGrid()
    let source = windows[0].id
    state.activatePane(state.panes[0].id)
    state.reconcile(windowIDs: [snapID("sibling-1"), snapID("sibling-2")], removed: [], focused: source)
    state.select(source)
    state.activatePane(state.panes[2].id)
    state.reconcile(windowIDs: [snapID("hidden")], removed: [], focused: nil)
    state.select(windows[2].id)
    state.reconcile(windowIDs: [snapID("float")], removed: [], focused: nil)
    state.float(snapID("float"))
    windows += [snapWindow("sibling-1"), snapWindow("sibling-2"), snapWindow("hidden"), snapWindow("float")]
    let plan = try #require(TabbedSnapPlanner.plan(sourceWindowID: source, action: .rightHalf, state: state,
                                                  windows: windows, in: snapBounds))
    #expect(plan.state.panes.count == 5)
    #expect(plan.state.pane(containing: source)?.tabs == [source])
    for pane in state.panes {
        let kept = try #require(plan.state.panes.first { $0.id == pane.id })
        #expect(kept.tabs == pane.tabs.filter { $0 != source })
        if pane.selected != source { #expect(kept.selected == pane.selected) }
    }
    #expect(plan.state.panes[0].selected == snapID("sibling-1"))
    #expect(plan.state.floatingWindowIDs == [snapID("float")])
}

@Test func tabbedSnapAttachesExplicitFloatToNewRegionWithoutMovingOtherFloats() throws {
    let source = snapID("source"), kept = snapID("kept"), floating = snapID("floating")
    var state = TabbedLayoutState()
    state.reconcile(windowIDs: [source, kept, floating], removed: [], focused: kept)
    state.float(source)
    state.float(floating)
    let oldPane = state.panes[0]
    let plan = try #require(TabbedSnapPlanner.plan(sourceWindowID: source, action: .rightHalf, state: state,
        windows: [snapWindow("source"), snapWindow("kept"), snapWindow("floating")], in: snapBounds))
    #expect(plan.state.panes[0] == oldPane)
    #expect(plan.state.panes.count == 2 && plan.state.activeWindowID == source)
    #expect(plan.state.floatingWindowIDs == [floating])
    #expect(Set(plan.placements.map(\.windowID)) == [source, kept])
}
