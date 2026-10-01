import Foundation
import Testing
@testable import BetterTileCore

private let tabbedBounds = BTRect(x: 0, y: 0, width: 1000, height: 600)
private func window(_ name: String) -> WindowID { WindowID(rawValue: name) }

@Test func tabbedAdoptsBentoTreeWithoutMovingBoundaries() throws {
    let a = window("a"), b = window("b"), c = window("c")
    let firstBoundary = UUID(), secondBoundary = UUID(), vacantID = UUID()
    let root = BentoNode.partition(BentoPartition(
        axis: .vertical,
        children: [.leaf(a), .leaf(b), .leaf(c), .vacant(vacantID)],
        ratios: [0.1, 0.2, 0.3, 0.4],
        boundaryIDs: [firstBoundary, secondBoundary, UUID()],
        lockedBoundaryIDs: [secondBoundary]
    ))
    let source = BentoLayoutState(root: root, floatingWindowIDs: [window("floating")],
                                  metrics: BentoLayoutMetrics(paneGap: 6))
    let state = try #require(BentoTabbedLayoutState(adopting: source))
    #expect(state.layout == source)
    #expect(state.panes.map(\.tabs) == [[a], [b], [c], []])
    #expect(state.panes.last?.id == vacantID)
    #expect(state.layout.floatingWindowIDs == [window("floating")])
    let frames = try #require(state.paneFrames(in: tabbedBounds))
    #expect(frames.count == 4)
    #expect(frames[state.panes[0].id] == source.placements(in: tabbedBounds).first { $0.windowID == a }?.frame)
}

@Test func tabSelectionKeepsTreeAndPaneIdentity() throws {
    let a = window("a"), b = window("b"), hidden = window("hidden")
    let boundary = UUID()
    let source = BentoLayoutState(root: .partition(BentoPartition(
        id: boundary, axis: .vertical, weight: 0.4, isLocked: true,
        first: .leaf(a), second: .leaf(b)
    )))
    var state = try #require(BentoTabbedLayoutState(adopting: source))
    let pane = state.panes[0].id
    let before = try #require(state.paneFrames(in: tabbedBounds))
    let added = state.add(hidden, to: pane)
    #expect(added)
    #expect(state.panes[0].tabs == [a, hidden])
    #expect(state.panes[0].selected == hidden)
    #expect(state.layout.root?.windowIDs == [hidden, b])
    let selected = state.select(a)
    #expect(selected)
    #expect(state.panes[0].id == pane)
    #expect(state.layout.root == source.root)
    #expect(state.paneFrames(in: tabbedBounds) == before)
}

@Test func lastTabLeavesVacantPaneAndCanReceiveAnother() throws {
    let a = window("a"), b = window("b")
    var state = try #require(BentoTabbedLayoutState(adopting: BentoLayoutState(root: .leaf(a))))
    let paneID = state.panes[0].id
    let removed = state.remove(a)
    #expect(removed)
    #expect(state.panes[0].tabs.isEmpty)
    #expect(state.panes[0].selected == nil)
    #expect(state.layout.root == .vacant(paneID))
    #expect(state.paneFrames(in: tabbedBounds)?[paneID] == tabbedBounds)
    let added = state.add(b, to: paneID)
    #expect(added)
    #expect(state.layout.root == .leaf(b))
    #expect(state.panes[0].id == paneID)
}

@Test func emptyBentoDesktopStartsWithOneUsablePane() throws {
    let floating = window("floating")
    var state = try #require(BentoTabbedLayoutState(adopting: BentoLayoutState(floatingWindowIDs: [floating])))
    #expect(state.panes.count == 1)
    #expect(state.panes[0].tabs.isEmpty)
    #expect(state.layout.floatingWindowIDs == [floating])
    let paneID = state.panes[0].id
    let added = state.add(floating, to: paneID)
    #expect(added)
    #expect(state.layout.root == .leaf(floating))
    #expect(state.layout.floatingWindowIDs.isEmpty)
}

@Test func invalidTabOperationsDoNotMutateState() throws {
    let a = window("a"), b = window("b")
    var state = try #require(BentoTabbedLayoutState(adopting: BentoLayoutState(root: .partition(BentoPartition(
        axis: .vertical, children: [.leaf(a), .leaf(b)]
    )))))
    let original = state
    let duplicate = state.add(a, to: state.panes[1].id)
    let invalidPane = state.add(window("new"), to: UUID())
    let invalidSelection = state.select(window("missing"))
    let invalidRemoval = state.remove(window("missing"))
    #expect(!duplicate)
    #expect(!invalidPane)
    #expect(!invalidSelection)
    #expect(!invalidRemoval)
    #expect(state == original)
    let duplicateTree = BentoLayoutState(root: .partition(BentoPartition(axis: .vertical,
                                                                          children: [.leaf(a), .leaf(a)])))
    #expect(BentoTabbedLayoutState(adopting: duplicateTree) == nil)
    let vacancyID = UUID()
    let duplicateVacancies = BentoLayoutState(root: .partition(BentoPartition(axis: .vertical,
        children: [.vacant(vacancyID), .vacant(vacancyID)]
    )))
    #expect(BentoTabbedLayoutState(adopting: duplicateVacancies) == nil)
}

@Test func selectedMinimumAndStripHeightMoveOnlyNeededBoundary() throws {
    let left = window("left"), right = window("right"), hidden = window("hidden")
    let source = BentoLayoutState(root: .partition(BentoPartition(axis: .vertical,
                                                                  children: [.leaf(left), .leaf(right)])))
    var state = try #require(BentoTabbedLayoutState(adopting: source, contentTopInset: 34))
    let added = state.add(hidden, to: state.panes[1].id)
    let selected = state.select(right)
    #expect(added)
    #expect(selected)
    let constraints: [WindowID: WindowConstraints] = [
        right: WindowConstraints(minimumSize: BTSize(width: 600, height: 100)),
        hidden: WindowConstraints(minimumSize: BTSize(width: 900, height: 500)),
    ]
    let fitted = try #require(state.fitted(in: tabbedBounds, constraints: constraints))
    let panes = try #require(fitted.paneFrames(in: tabbedBounds))
    let contents = try #require(fitted.contentFrames(in: tabbedBounds))
    #expect(abs(panes[fitted.panes[1].id]!.size.width - 600) < 0.01)
    #expect(contents[fitted.panes[1].id]!.minY == panes[fitted.panes[1].id]!.minY + 34)
    #expect(contents[fitted.panes[1].id]!.size.height == 566)
    #expect(state.layout.root == source.root)
    // The window's placement is the content frame: Bento reserves the strip.
    #expect(fitted.layout.placements(in: tabbedBounds).first { $0.windowID == right }?.frame == contents[fitted.panes[1].id])
    #expect(BentoTabbedLayoutState(adopting: source, contentTopInset: -.infinity)?.layout.metrics.contentTopInset == 0)
    #expect(fitted.fitted(in: BTRect(x: 0, y: 0, width: .infinity, height: 600),
                          constraints: constraints) == nil)
    #expect(fitted.fitted(in: tabbedBounds,
                          constraints: [right: WindowConstraints(minimumSize: BTSize(width: -1, height: 100))]) == nil)
}

@Test func rowFitReservesStripAndLockedBoundaryCanReject() throws {
    let top = window("top"), bottom = window("bottom"), hidden = window("hidden")
    let bounds = BTRect(x: 0, y: 0, width: 800, height: 400)
    let branchID = UUID()
    let root = BentoNode.partition(BentoPartition(id: branchID, axis: .horizontal,
                                                  first: .leaf(top), second: .leaf(bottom)))
    var state = try #require(BentoTabbedLayoutState(adopting: BentoLayoutState(root: root), contentTopInset: 34))
    let added = state.add(hidden, to: state.panes[1].id)
    let selected = state.select(bottom)
    #expect(added && selected)
    let constraints: [WindowID: WindowConstraints] = [
        bottom: WindowConstraints(minimumSize: BTSize(width: 120, height: 250)),
        hidden: WindowConstraints(minimumSize: BTSize(width: 120, height: 390)),
    ]
    let fitted = try #require(state.fitted(in: bounds, constraints: constraints))
    let frames = try #require(fitted.paneFrames(in: bounds))
    #expect(abs(frames[fitted.panes[1].id]!.size.height - 284) < 0.01)
    #expect(abs(frames[fitted.panes[0].id]!.size.height - 116) < 0.01)
    let lockedRoot = BentoNode.partition(BentoPartition(
        id: branchID, axis: .horizontal, weight: 0.5, isLocked: true,
        first: .leaf(top), second: .leaf(bottom)
    ))
    var locked = try #require(BentoTabbedLayoutState(adopting: BentoLayoutState(root: lockedRoot), contentTopInset: 34))
    let lockedAdded = locked.add(hidden, to: locked.panes[1].id)
    let lockedSelected = locked.select(bottom)
    #expect(lockedAdded && lockedSelected)
    #expect(locked.fitted(in: bounds, constraints: constraints) == nil)
    #expect(locked.layout.root == lockedRoot)
}

@Test func removingHiddenTabKeepsTreeAndSelectedClosurePromotesFirst() throws {
    let a = window("a"), b = window("b"), c = window("c")
    var state = try #require(BentoTabbedLayoutState(adopting: BentoLayoutState(root: .leaf(a))))
    let paneID = state.panes[0].id
    let addedB = state.add(b, to: paneID)
    let addedC = state.add(c, to: paneID)
    #expect(addedB && addedC)
    let tree = state.layout.root
    let removedHidden = state.remove(b)
    #expect(removedHidden)
    #expect(state.layout.root == tree)
    let removedSelected = state.remove(c)
    #expect(removedSelected)
    #expect(state.panes[0].tabs == [a])
    #expect(state.panes[0].selected == a)
    #expect(state.layout.root == .leaf(a))
}

@Test func contentReserveKeepsBentoBoundariesAndPaneMinimums() throws {
    let top = window("top"), bottom = window("bottom")
    let bounds = BTRect(x: 0, y: 0, width: 800, height: 600)
    let display = DisplayID(rawValue: "d")
    let state = BentoLayoutState(
        root: .partition(BentoPartition(axis: .horizontal, first: .leaf(top), second: .leaf(bottom))),
        metrics: BentoLayoutMetrics(paneGap: 6, contentTopInset: 34)
    )
    let placements = Dictionary(uniqueKeysWithValues: state.placements(in: bounds).map { ($0.windowID, $0.frame) })
    let panes = state.paneFrames(in: bounds)
    // Each window starts below its pane's reserve; panes keep their geometry.
    #expect(placements[top]?.minY == panes[top]!.minY + 34)
    #expect(placements[bottom]?.minY == panes[bottom]!.minY + 34)
    #expect(placements[bottom]?.maxY == panes[bottom]?.maxY)
    // The horizontal boundary is still found from real window frames, at the pane gap.
    let windows = [top, bottom].map { WindowSnapshot(id: $0, processIdentifier: 1, frame: placements[$0]!, displayID: display) }
    let boundaries = BentoBoundaryResolver().boundaries(state: state, windows: windows, displayID: display, bounds: bounds)
    #expect(boundaries.count == 1)
    #expect(abs(boundaries[0].coordinate - (panes[top]!.maxY + 3)) < 0.001)
    // A window minimum of 300 needs a 334-point pane.
    let constraints = [bottom: WindowConstraints(minimumSize: BTSize(width: 120, height: 300))]
    let solved = try #require(BentoConstraintSolver().solve(state: state, in: bounds, constraints: constraints))
    #expect(abs(solved.paneFrames(in: bounds)[bottom]!.size.height - 334) < 0.01)
    #expect(BentoConstraintSolver().solve(state: state, in: BTRect(x: 0, y: 0, width: 800, height: 400),
                                          constraints: [top: constraints[bottom]!, bottom: constraints[bottom]!]) == nil)
}

private func twoPaneGroup() throws -> (BentoTabbedLayoutState, WindowID, WindowID, WindowID) {
    let a = window("a"), b = window("b"), c = window("c")
    var state = try #require(BentoTabbedLayoutState(adopting: BentoLayoutState(root: .partition(BentoPartition(
        axis: .vertical, children: [.leaf(a), .leaf(c)]
    ))), contentTopInset: 34))
    let added = state.add(b, to: state.panes[0].id)
    let selected = state.select(a)
    #expect(added && selected)
    return (state, a, b, c)
}

@Test func swappingSelectedWindowsCarriesTheirTabGroups() throws {
    var (state, a, b, c) = try twoPaneGroup()
    let before = state.layout.paneFrames(in: tabbedBounds)
    var swapped = state.layout
    swapped.swap(a, c)
    let orphans = state.synchronize(with: swapped)
    #expect(orphans.isEmpty)
    #expect(state.pane(containing: a)?.tabs == [a, b])
    #expect(state.pane(containing: c)?.tabs == [c])
    #expect(state.layout.paneFrames(in: tabbedBounds)[a] == before[c])
}

@Test func synchronizeReturnsTabsWhoseGroupLostItsPlace() throws {
    var (state, a, b, c) = try twoPaneGroup()
    var closed = state.layout
    closed.remove(a)
    let orphans = state.synchronize(with: closed)
    #expect(orphans == [b])
    #expect(state.panes.map(\.tabs) == [[c]])
    #expect(!state.windowIDs.contains(b))
}

@Test func synchronizeGivesNewLeavesTheirOwnPaneAndDropsFloatingTabs() throws {
    var (state, a, b, c) = try twoPaneGroup()
    let d = window("d")
    var next = state.layout
    next.split(c, inserting: d, in: tabbedBounds)
    next.floatingWindowIDs.insert(b)
    let nextOrphans = state.synchronize(with: next)
    #expect(nextOrphans.isEmpty)
    #expect(state.pane(containing: d)?.tabs == [d])
    #expect(state.pane(containing: a)?.tabs == [a])
    #expect(state.pane(containing: b) == nil)
    // A hidden tab placed elsewhere in the tree leads its own pane.
    var (other, a2, b2, c2) = try twoPaneGroup()
    var placed = other.layout
    placed.split(c2, inserting: b2, in: tabbedBounds)
    let placedOrphans = other.synchronize(with: placed)
    #expect(placedOrphans.isEmpty)
    #expect(other.pane(containing: a2)?.tabs == [a2])
    #expect(other.pane(containing: b2)?.tabs == [b2])
}

@Test func detachingATabLeavesTheRestOfItsGroupInPlace() throws {
    var (state, a, b, c) = try twoPaneGroup()
    let frame = state.layout.paneFrames(in: tabbedBounds)[a]
    let detached = state.detach(a)
    #expect(detached)
    #expect(state.pane(containing: b)?.selected == b)
    #expect(state.layout.paneFrames(in: tabbedBounds)[b] == frame)
    #expect(state.pane(containing: a) == nil)
    #expect(state.layout.root?.windowIDs.contains(a) == false)
    // A lone tab moves with ordinary Bento operations instead.
    let loneDetached = state.detach(c)
    #expect(!loneDetached)
    #expect(state.pane(containing: c)?.tabs == [c])
}

@Test func reorderingTabsKeepsSelectionAndGeometry() throws {
    var (state, a, b, _) = try twoPaneGroup()
    let layout = state.layout
    let reordered = state.reorder(b, to: 0)
    #expect(reordered)
    #expect(state.pane(containing: a)?.tabs == [b, a])
    #expect(state.pane(containing: a)?.selected == a)
    #expect(state.layout == layout)
}

@Test func unstackingGivesEveryHiddenTabAPaneAndRemovesTheReserve() throws {
    let (state, a, b, c) = try twoPaneGroup()
    let bento = state.unstacked(in: tabbedBounds)
    #expect(bento.metrics.contentTopInset == 0)
    #expect(Set(bento.root?.windowIDs ?? []) == [a, b, c])
    let frames = bento.paneFrames(in: tabbedBounds)
    // The group's pane splits along its longer side: a and b share a's column.
    #expect(abs(frames[a]!.minY - frames[b]!.minY) > 1 || abs(frames[a]!.minX - frames[b]!.minX) > 1)
    #expect(frames[a]!.maxX <= frames[c]!.minX + 0.001)
    #expect(frames[b]!.maxX <= frames[c]!.minX + 0.001)
}

@Test func restoringMembershipFollowsTheCurrentLayout() throws {
    let (state, a, b, c) = try twoPaneGroup()
    var swapped = state.layout
    swapped.swap(a, c)
    let restored = BentoTabbedLayoutState(layout: swapped, panes: state.panes)
    #expect(restored.pane(containing: a)?.tabs == [a, b])
    #expect(restored.hiddenWindowIDs == [b])
    #expect(restored.layout == swapped)
}

@Test func horizontalBoundaryAveragesObservedEdgesWithAndWithoutReserve() {
    let top = window("top"), bottom = window("bottom")
    let display = DisplayID(rawValue: "d")
    let bounds = BTRect(x: 0, y: 0, width: 800, height: 600)
    for reserve in [0.0, 34.0] {
        let state = BentoLayoutState(
            root: .partition(BentoPartition(axis: .horizontal, first: .leaf(top), second: .leaf(bottom))),
            metrics: BentoLayoutMetrics(paneGap: 6, contentTopInset: reserve)
        )
        // The applications settled 2 points off the exact fit, within tolerance.
        let windows = [
            WindowSnapshot(id: top, processIdentifier: 1, frame: BTRect(x: 0, y: reserve, width: 800, height: 297 - reserve), displayID: display),
            WindowSnapshot(id: bottom, processIdentifier: 1, frame: BTRect(x: 0, y: 305 + reserve, width: 800, height: 295 - reserve), displayID: display),
        ]
        let boundary = BentoBoundaryResolver().boundaries(state: state, windows: windows, displayID: display, bounds: bounds).first
        #expect(boundary.map { abs($0.coordinate - 301) < 0.001 } == true)
    }
}
