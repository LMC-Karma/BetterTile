import Foundation
import Testing
@testable import BetterTileCore

private let balanceBounds = BTRect(x: 0, y: 0, width: 1200, height: 800)
private func id(_ name: String) -> WindowID { WindowID(rawValue: name) }
private func minimum(width: Double = 120, height: Double = 80) -> WindowConstraints {
    WindowConstraints(minimumSize: BTSize(width: width, height: height))
}
private func ratios(_ node: BentoNode?) -> [Double] {
    guard case let .partition(partition)? = node else { return [] }
    return partition.ratios
}
private func child(_ node: BentoNode?, _ index: Int) -> BentoNode? {
    guard case let .partition(partition)? = node else { return nil }
    return partition.children[index]
}
private func close(_ lhs: [Double], _ rhs: [Double]) -> Bool {
    lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { abs($0 - $1) < 0.000_1 }
}

@Test func balancingGivesEveryPartitionEqualShares() throws {
    let state = BentoLayoutState(root: .partition(BentoPartition(
        axis: .vertical,
        children: [.leaf(id("a")), .partition(BentoPartition(
            axis: .horizontal, children: [.leaf(id("b")), .leaf(id("c")), .leaf(id("d"))], ratios: [0.2, 0.3, 0.5]
        ))],
        ratios: [0.7, 0.3]
    )))
    let balanced = try #require(BentoBalancer().balance(state: state, in: balanceBounds))
    #expect(close(ratios(balanced.root), [0.5, 0.5]))
    #expect(close(ratios(child(balanced.root, 1)), [1.0 / 3, 1.0 / 3, 1.0 / 3]))
}

@Test func aWindowThatCannotShrinkToAnEqualShareKeepsItsMinimum() throws {
    let state = BentoLayoutState(root: .partition(BentoPartition(
        axis: .vertical, children: [.leaf(id("a")), .leaf(id("b")), .leaf(id("c"))], ratios: [0.6, 0.2, 0.2]
    )))
    let balanced = try #require(BentoBalancer().balance(
        state: state, in: balanceBounds, constraints: [id("a"): minimum(width: 600)]
    ))
    // a needs 600 of 1200; b and c share the other 600 equally.
    let frames = balanced.paneFrames(in: balanceBounds)
    #expect(frames[id("a")]?.size.width == 600)
    #expect(frames[id("b")]?.size.width == 300)
    #expect(frames[id("c")]?.size.width == 300)
}

@Test func nestedMinimumsCountForTheirWholeBranch() throws {
    let state = BentoLayoutState(root: .partition(BentoPartition(
        axis: .vertical,
        children: [.leaf(id("a")), .partition(BentoPartition(
            axis: .horizontal, children: [.leaf(id("b")), .leaf(id("c"))], ratios: [0.5, 0.5]
        ))],
        ratios: [0.5, 0.5]
    )))
    let balanced = try #require(BentoBalancer().balance(
        state: state, in: balanceBounds,
        constraints: [id("b"): minimum(width: 800), id("c"): minimum(height: 500)]
    ))
    let frames = balanced.paneFrames(in: balanceBounds)
    // b's width holds its whole column at 800; c's height takes 500 of 800.
    #expect(abs((frames[id("a")]?.size.width ?? 0) - 400) < 0.001)
    #expect(abs((frames[id("b")]?.size.width ?? 0) - 800) < 0.001)
    #expect(abs((frames[id("b")]?.size.height ?? 0) - 300) < 0.001)
    #expect(abs((frames[id("c")]?.size.height ?? 0) - 500) < 0.001)
}

@Test func aLockedDividerStaysAndEachSideIsBalanced() throws {
    let locked = UUID()
    let state = BentoLayoutState(root: .partition(BentoPartition(
        axis: .vertical,
        children: [.leaf(id("a")), .leaf(id("b")), .leaf(id("c"))],
        ratios: [0.1, 0.5, 0.4],
        boundaryIDs: [UUID(), locked],
        lockedBoundaryIDs: [locked]
    )))
    let balanced = try #require(BentoBalancer().balance(state: state, in: balanceBounds))
    #expect(close(ratios(balanced.root), [0.3, 0.3, 0.4]))
}

@Test func anEmptySlotCountsAsOnePane() throws {
    let state = BentoLayoutState(root: .partition(BentoPartition(
        axis: .vertical, children: [.leaf(id("a")), .vacant(UUID()), .leaf(id("b"))], ratios: [0.5, 0.1, 0.4]
    )))
    let balanced = try #require(BentoBalancer().balance(state: state, in: balanceBounds))
    #expect(close(ratios(balanced.root), [1.0 / 3, 1.0 / 3, 1.0 / 3]))
}

@Test func balancingFailsOnlyWhenNoRatiosMeetTheMinimums() {
    let state = BentoLayoutState(root: .partition(BentoPartition(
        axis: .vertical, children: [.leaf(id("a")), .leaf(id("b"))]
    )))
    #expect(BentoBalancer().balance(
        state: state, in: balanceBounds,
        constraints: [id("a"): minimum(width: 700), id("b"): minimum(width: 700)]
    ) == nil)
}

private let plannerBalanceBounds = BTRect(x: 0, y: 0, width: 1200, height: 800)
private func plannerWindow(_ name: String, _ frame: BTRect = plannerBalanceBounds, minimumWidth: Double = 120) -> WindowSnapshot {
    WindowSnapshot(
        id: id(name), processIdentifier: 1, frame: frame, displayID: DisplayID(rawValue: "balance"),
        constraints: minimum(width: minimumWidth)
    )
}

@Test(arguments: [false, true])
func aNewWindowBalancesTheLayoutOnlyWhenTheSettingIsOn(balances: Bool) throws {
    let left = plannerWindow("left", BTRect(x: 0, y: 0, width: 840, height: 800))
    let right = plannerWindow("right", BTRect(x: 840, y: 0, width: 360, height: 800))
    let new = plannerWindow("new")
    let columns = BentoPartition(axis: .vertical, children: [.leaf(left.id), .leaf(right.id)], ratios: [0.7, 0.3])
    let result = BentoPlanner(balancesNewWindows: balances).plan(
        state: BentoRuntimeState(layout: BentoLayoutState(root: .partition(columns))),
        observation: BentoObservation(bounds: plannerBalanceBounds, windows: [left, right, new], focusedWindowID: right.id),
        intent: .insert(new.id)
    )

    #expect(result.writesFrames)
    let frames = Dictionary(uniqueKeysWithValues: result.placements.map { ($0.windowID, $0.frame) })
    // The new window stacks below the narrow right column either way.
    #expect(frames[new.id]?.size.width == frames[right.id]?.size.width)
    #expect(frames[new.id]?.size.height == 400)
    if balances {
        #expect(frames[left.id]?.size.width == 600)
        #expect(frames[right.id]?.size.width == 600)
    } else {
        #expect(frames[left.id] == left.frame)
        #expect(frames[right.id]?.size.width == 360)
    }
}

@Test func balancingSettlesOnTheClosestLayoutThatFits() throws {
    // a cannot shrink below 800 of 1200, so an even split is impossible.
    let a = plannerWindow("a", BTRect(x: 0, y: 0, width: 900, height: 800), minimumWidth: 800)
    let b = plannerWindow("b", BTRect(x: 900, y: 0, width: 300, height: 800))
    let new = plannerWindow("new")
    let columns = BentoPartition(axis: .vertical, children: [.leaf(a.id), .leaf(b.id)], ratios: [0.75, 0.25])
    let result = BentoPlanner(balancesNewWindows: true).plan(
        state: BentoRuntimeState(layout: BentoLayoutState(root: .partition(columns))),
        observation: BentoObservation(bounds: plannerBalanceBounds, windows: [a, b, new], focusedWindowID: b.id),
        intent: .insert(new.id)
    )

    #expect(result.writesFrames)
    #expect(Set(result.state.layout.root?.windowIDs ?? []) == [a.id, b.id, new.id])
    let frames = Dictionary(uniqueKeysWithValues: result.placements.map { ($0.windowID, $0.frame) })
    #expect(frames[a.id]?.size.width == 800)
}

@Test func balancingNeverChangesAnInsertionThatCannotPlaceTheWindow() {
    let windows = (1...7).map { plannerWindow("\($0)") }
    var state = BentoRuntimeState(layout: BentoLayoutState(root: .leaf(windows[0].id)))
    for window in windows.dropFirst().prefix(5) {
        state = BentoPlanner().plan(
            state: state,
            observation: BentoObservation(bounds: plannerBalanceBounds, windows: windows, focusedWindowID: windows[0].id),
            intent: .insert(window.id)
        ).state
    }
    let observation = BentoObservation(bounds: plannerBalanceBounds, windows: windows, focusedWindowID: windows[0].id)
    let off = BentoPlanner().plan(state: state, observation: observation, intent: .insert(windows[6].id))
    let on = BentoPlanner(balancesNewWindows: true).plan(state: state, observation: observation, intent: .insert(windows[6].id))
    #expect(!on.writesFrames)
    #expect(on.state == off.state)
    #expect(on.placements == off.placements)
}
