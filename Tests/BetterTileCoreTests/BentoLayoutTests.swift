import Foundation
import Testing
@testable import BetterTileCore

private let bentoBounds = BTRect(x: 0, y: 0, width: 1200, height: 800)

@Test func bentoInsertionIsDeterministicAndGapless() {
    var first = BentoLayoutState()
    var second = BentoLayoutState()
    let ids = ["a", "b", "c", "d"].map { WindowID(rawValue: $0) }
    for id in ids {
        first.insert(id, in: bentoBounds)
        second.insert(id, in: bentoBounds)
    }
    #expect(first == second)
    let placements = first.placements(in: bentoBounds)
    #expect(placements.count == 4)
    #expect(abs(placements.reduce(0) { $0 + $1.frame.area } - bentoBounds.area) < 0.01)
}

@Test func bentoRemoveCollapsesParentAndSwapPreservesFrames() {
    var state = BentoLayoutState()
    let a = WindowID(rawValue: "a")
    let b = WindowID(rawValue: "b")
    state.insert(a, in: bentoBounds)
    state.insert(b, in: bentoBounds)
    let before = Dictionary(uniqueKeysWithValues: state.placements(in: bentoBounds).map { ($0.windowID, $0.frame) })
    state.swap(a, b)
    let after = Dictionary(uniqueKeysWithValues: state.placements(in: bentoBounds).map { ($0.windowID, $0.frame) })
    #expect(after[a] == before[b])
    #expect(after[b] == before[a])
    state.remove(a)
    #expect(state.root?.windowIDs == [b])
}

/// Boundary identifiers come from the window pair a divider separates, so
/// moving a window next to a pane it already neighboured used to mint an
/// identifier the partition already held. Lookups resolve a boundary with
/// `firstIndex(of:)`, so the two dividers became one.
@Test func bentoReinsertionKeepsBoundaryIdentifiersDistinct() {
    var state = BentoLayoutState()
    let a = WindowID(rawValue: "a")
    let b = WindowID(rawValue: "b")
    let c = WindowID(rawValue: "c")
    for id in [a, b, c] {
        state.insert(id, in: bentoBounds)
    }
    let reinserted = state.reinsert(a, beside: b, edge: .left)
    #expect(reinserted)

    let ids = state.boundaries(in: bentoBounds, displayID: DisplayID(rawValue: "d")).map(\.id)
    #expect(ids.count == 2)
    #expect(Set(ids).count == ids.count)
}

/// Every pane pair in a four-window layout, reinserted on every edge, has to
/// leave one identifier for each divider.
@Test func bentoReinsertionNeverRepeatsABoundaryIdentifier() {
    let ids = ["a", "b", "c", "d"].map { WindowID(rawValue: $0) }
    let display = DisplayID(rawValue: "d")
    for source in ids {
        for target in ids where target != source {
            for edge in [BentoPaneDropPosition.left, .right, .top, .bottom] {
                var state = BentoLayoutState()
                for id in ids {
                    state.insert(id, in: bentoBounds)
                }
                let reinserted = state.reinsert(source, beside: target, edge: edge)
                #expect(
                    reinserted,
                    "reinsertion failed for \(source.rawValue) to \(edge.rawValue) of \(target.rawValue)"
                )
                let boundaryIDs = state.boundaries(in: bentoBounds, displayID: display).map(\.id)
                #expect(
                    Set(boundaryIDs).count == boundaryIDs.count,
                    "repeated boundary identifier after \(source.rawValue) to \(edge.rawValue) of \(target.rawValue)"
                )
            }
        }
    }
}

/// Cleaning a repeated identifier must preserve the lock on its boundary and
/// must not mint another identifier when the cleaned tree is stored again.
@Test func duplicateBoundaryCleanupPreservesLocksAndIdentity() throws {
    let repeatedID = UUID()
    let a = WindowID(rawValue: "a")
    let b = WindowID(rawValue: "b")
    let c = WindowID(rawValue: "c")
    var state = BentoLayoutState(root: .partition(BentoPartition(
        axis: .vertical,
        children: [
            .leaf(a),
            .partition(BentoPartition(
                axis: .horizontal,
                children: [.leaf(b), .leaf(c)],
                boundaryIDs: [repeatedID],
                lockedBoundaryIDs: [repeatedID]
            )),
        ],
        boundaryIDs: [repeatedID]
    )))

    let cleanedRoot = try #require(state.root)
    let branches = state.branches
    let rootBoundary = try #require(branches.first { $0.depth == 0 })
    let nestedBoundary = try #require(branches.first { $0.depth == 1 })
    #expect(rootBoundary.id == repeatedID)
    #expect(!rootBoundary.isLocked)
    #expect(nestedBoundary.id != repeatedID)
    #expect(nestedBoundary.isLocked)

    state.root = cleanedRoot
    #expect(state.root == cleanedRoot)
    #expect(state.branches == branches)
}

/// A repeated identifier made one drag move the wrong divider. Dragging the
/// first boundary must move only the first boundary.
@Test func bentoResizeMovesOnlyTheDraggedBoundary() {
    var state = BentoLayoutState()
    let a = WindowID(rawValue: "a")
    let b = WindowID(rawValue: "b")
    let c = WindowID(rawValue: "c")
    for id in [a, b, c] {
        state.insert(id, in: bentoBounds)
    }
    let reinserted = state.reinsert(a, beside: b, edge: .left)
    #expect(reinserted)

    let before = state.boundaries(in: bentoBounds, displayID: DisplayID(rawValue: "d"))
    #expect(before.count == 2)
    guard let dragged = before.first, let untouched = before.last, dragged.id != untouched.id,
          let draggedBranchID = dragged.branchID
    else {
        Issue.record("the layout did not give two distinct boundaries")
        return
    }

    let target = dragged.coordinate - 80
    guard let result = BentoResizeEngine().resize(
        state: state,
        branchCoordinates: [draggedBranchID: target],
        in: bentoBounds
    ) else {
        Issue.record("the resize returned no result")
        return
    }

    let after = result.state.boundaries(in: bentoBounds, displayID: DisplayID(rawValue: "d"))
    let movedByID: [String: Double] = Dictionary(
        uniqueKeysWithValues: after.map { ($0.id, $0.coordinate) }
    )
    #expect(abs((movedByID[dragged.id] ?? 0) - target) < 1)
    #expect(abs((movedByID[untouched.id] ?? 0) - untouched.coordinate) < 1)
}
