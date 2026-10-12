import Foundation
import Testing
@testable import BetterTileCore

private let bentoBounds = BTRect(x: 0, y: 0, width: 1200, height: 800)
private let plannerBounds = BTRect(x: 0, y: 0, width: 1200, height: 800)
private let plannerDisplay = DisplayID(rawValue: "empty-slots")

private func plannerWindow(_ name: String, frame: BTRect = plannerBounds) -> WindowSnapshot {
    WindowSnapshot(id: WindowID(rawValue: name), processIdentifier: 1, frame: frame, displayID: plannerDisplay)
}

@Test func removingEmptySlotsKeepsTheOtherPanesRelativeSizes() throws {
    let a = WindowID(rawValue: "a"), b = WindowID(rawValue: "b")
    let locked = UUID(), free = UUID()
    var state = BentoLayoutState(root: .partition(BentoPartition(
        axis: .vertical,
        children: [.vacant(UUID()), .leaf(a), .leaf(b)],
        ratios: [0.2, 0.3, 0.5],
        boundaryIDs: [free, locked],
        lockedBoundaryIDs: [locked]
    )))
    state.removeVacancies()
    guard case let .partition(root) = state.root else {
        Issue.record("Expected a partition")
        return
    }
    #expect(root.children == [.leaf(a), .leaf(b)])
    #expect(abs(root.ratios[0] - 0.375) < 0.000_001)
    #expect(root.lockedBoundaryIDs == [locked])

    var onlyEmpty = BentoLayoutState(root: .partition(BentoPartition(
        axis: .horizontal, children: [.vacant(UUID()), .vacant(UUID())]
    )))
    onlyEmpty.removeVacancies()
    #expect(onlyEmpty.root == nil)
}

@Test func fillingAnEmptySlotKeepsTheOtherPanes() throws {
    let a = WindowID(rawValue: "a"), b = WindowID(rawValue: "b")
    let empty = UUID()
    var state = BentoLayoutState(root: .partition(BentoPartition(
        axis: .vertical, children: [.leaf(a), .vacant(empty)], ratios: [0.3, 0.7]
    )), floatingWindowIDs: [b])
    let unknown = state.fillVacancy(UUID(), with: b)
    let filled = state.fillVacancy(empty, with: b)
    let again = state.fillVacancy(empty, with: b)
    #expect(!unknown && filled && !again)
    #expect(state.floatingWindowIDs.isEmpty)
    let frames = state.paneFrames(in: bentoBounds)
    #expect(frames[a] == BTRect(x: 0, y: 0, width: 360, height: 800))
    #expect(frames[b] == BTRect(x: 360, y: 0, width: 840, height: 800))
}

@Test func aNewWindowFillsAnEmptySlotBeforeSplittingTheFocusedPane() throws {
    let left = plannerWindow("left", frame: BTRect(x: 0, y: 0, width: 600, height: 800))
    let new = plannerWindow("new")
    let snapped = BentoPartition(axis: .vertical, children: [.leaf(left.id), .vacant(UUID())])
    let result = BentoPlanner().plan(
        state: BentoRuntimeState(layout: BentoLayoutState(root: .partition(snapped))),
        observation: BentoObservation(bounds: plannerBounds, windows: [left, new], focusedWindowID: left.id),
        intent: .insert(new.id)
    )

    #expect(result.writesFrames)
    let frames = Dictionary(uniqueKeysWithValues: result.placements.map { ($0.windowID, $0.frame) })
    #expect(frames[left.id] == left.frame)
    #expect(frames[new.id] == BTRect(x: 600, y: 0, width: 600, height: 800))
}

@Test func repairRemovesEmptySlots() throws {
    let a = plannerWindow("a", frame: BTRect(x: 0, y: 0, width: 400, height: 800))
    let b = plannerWindow("b", frame: BTRect(x: 400, y: 0, width: 400, height: 800))
    let tree = BentoPartition(axis: .vertical, children: [.leaf(a.id), .leaf(b.id), .vacant(UUID())])
    let result = BentoPlanner().plan(
        state: BentoRuntimeState(layout: BentoLayoutState(root: .partition(tree))),
        observation: BentoObservation(bounds: plannerBounds, windows: [a, b], focusedWindowID: a.id),
        intent: .retile
    )

    #expect(result.writesFrames)
    let area = result.placements.reduce(0) { $0 + $1.frame.area }
    #expect(abs(area - plannerBounds.area) < 0.01)
    guard case let .partition(root) = result.state.layout.root else {
        Issue.record("Expected a partition")
        return
    }
    #expect(!root.children.contains { if case .vacant = $0 { true } else { false } })
}
