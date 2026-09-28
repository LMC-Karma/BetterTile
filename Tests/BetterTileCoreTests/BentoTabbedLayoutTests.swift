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
    var state = try #require(BentoTabbedLayoutState(adopting: source))
    let added = state.add(hidden, to: state.panes[1].id)
    let selected = state.select(right)
    #expect(added)
    #expect(selected)
    let constraints: [WindowID: WindowConstraints] = [
        right: WindowConstraints(minimumSize: BTSize(width: 600, height: 100)),
        hidden: WindowConstraints(minimumSize: BTSize(width: 900, height: 500)),
    ]
    let fitted = try #require(state.fitted(in: tabbedBounds, constraints: constraints, stripHeight: 34))
    let panes = try #require(fitted.paneFrames(in: tabbedBounds))
    let contents = try #require(fitted.contentFrames(in: tabbedBounds, stripHeight: 34))
    #expect(abs(panes[fitted.panes[1].id]!.size.width - 600) < 0.01)
    #expect(contents[fitted.panes[1].id]!.minY == panes[fitted.panes[1].id]!.minY + 34)
    #expect(contents[fitted.panes[1].id]!.size.height == 566)
    #expect(state.layout == source)
    #expect(fitted.fitted(in: tabbedBounds, constraints: constraints, stripHeight: -.infinity) == nil)
    #expect(fitted.fitted(in: BTRect(x: 0, y: 0, width: .infinity, height: 600),
                          constraints: constraints, stripHeight: 34) == nil)
    #expect(fitted.fitted(in: tabbedBounds,
                          constraints: [right: WindowConstraints(minimumSize: BTSize(width: -1, height: 100))],
                          stripHeight: 34) == nil)
}

@Test func rowFitReservesStripAndLockedBoundaryCanReject() throws {
    let top = window("top"), bottom = window("bottom"), hidden = window("hidden")
    let bounds = BTRect(x: 0, y: 0, width: 800, height: 400)
    let branchID = UUID()
    let root = BentoNode.partition(BentoPartition(id: branchID, axis: .horizontal,
                                                  first: .leaf(top), second: .leaf(bottom)))
    var state = try #require(BentoTabbedLayoutState(adopting: BentoLayoutState(root: root)))
    let added = state.add(hidden, to: state.panes[1].id)
    let selected = state.select(bottom)
    #expect(added && selected)
    let constraints: [WindowID: WindowConstraints] = [
        bottom: WindowConstraints(minimumSize: BTSize(width: 120, height: 250)),
        hidden: WindowConstraints(minimumSize: BTSize(width: 120, height: 390)),
    ]
    let fitted = try #require(state.fitted(in: bounds, constraints: constraints, stripHeight: 34))
    let frames = try #require(fitted.paneFrames(in: bounds))
    #expect(abs(frames[fitted.panes[1].id]!.size.height - 284) < 0.01)
    #expect(abs(frames[fitted.panes[0].id]!.size.height - 116) < 0.01)
    let lockedRoot = BentoNode.partition(BentoPartition(
        id: branchID, axis: .horizontal, weight: 0.5, isLocked: true,
        first: .leaf(top), second: .leaf(bottom)
    ))
    var locked = try #require(BentoTabbedLayoutState(adopting: BentoLayoutState(root: lockedRoot)))
    let lockedAdded = locked.add(hidden, to: locked.panes[1].id)
    let lockedSelected = locked.select(bottom)
    #expect(lockedAdded && lockedSelected)
    #expect(locked.fitted(in: bounds, constraints: constraints, stripHeight: 34) == nil)
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
