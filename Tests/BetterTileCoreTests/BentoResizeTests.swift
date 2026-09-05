import Foundation
import Testing
@testable import BetterTileCore

private let resizeBounds = BTRect(x: 0, y: 0, width: 1200, height: 800)
private let resizeDisplay = DisplayID(rawValue: "display")

@Test(arguments: [0.0, 1.0, 2.0, 6.0, 12.0], [SplitAxis.vertical, .horizontal])
func settledBentoPanesDoNotDrift(gap: Double, axis: SplitAxis) {
    let a = WindowID(rawValue: "a"), b = WindowID(rawValue: "b")
    let state = BentoLayoutState(
        root: .partition(BentoPartition(axis: axis, first: .leaf(a), second: .leaf(b))),
        metrics: BentoLayoutMetrics(paneGap: gap)
    )
    let frames = Dictionary(uniqueKeysWithValues: state.placements(in: resizeBounds).map { ($0.windowID, $0.frame) })
    for changedIDs: Set<WindowID> in [[a], [b], [a, b]] {
        #expect(BentoLayoutFitter().fit(
            state: state, currentFrames: frames, changedWindowIDs: changedIDs, in: resizeBounds
        ) == nil)
    }
}

@Test func unchangedWindowDoesNotTeachAMinimumSize() {
    let id = WindowID(rawValue: "slow")
    let baseline = BTRect(x: 200, y: 0, width: 800, height: 800)
    var learner = WindowMinimumSizeLearner()
    let learned = learner.observe(
        windowID: id,
        requested: BTRect(x: 500, y: 0, width: 500, height: 800),
        baseline: baseline,
        actual: baseline
    )
    #expect(!learned)
    #expect(learner.learnedSizes.isEmpty)
}

@Test(arguments: [SplitAxis.vertical, .horizontal])
func nativeResizeWithAGapMovesTheDividerByTheActualDelta(axis: SplitAxis) throws {
    let a = WindowID(rawValue: "a"), b = WindowID(rawValue: "b")
    let state = BentoLayoutState(
        root: .partition(BentoPartition(axis: axis, first: .leaf(a), second: .leaf(b))),
        metrics: BentoLayoutMetrics(paneGap: 12)
    )
    var frames = Dictionary(uniqueKeysWithValues: state.placements(in: resizeBounds).map { ($0.windowID, $0.frame) })
    if axis == .vertical {
        frames[a]?.size.width += 70
    } else {
        frames[a]?.size.height += 70
    }
    let result = try #require(BentoLayoutFitter(tolerance: 2).fit(
        state: state, currentFrames: frames, changedWindowIDs: [a], in: resizeBounds
    ))
    let moved = Dictionary(uniqueKeysWithValues: result.placements.map { ($0.windowID, $0.frame) })
    #expect(moved[a]?.approximatelyEquals(frames[a]!, tolerance: 0.001) == true)
    if axis == .vertical {
        #expect(abs(moved[b]!.minX - moved[a]!.maxX - 12) < 0.001)
    } else {
        #expect(abs(moved[b]!.minY - moved[a]!.maxY - 12) < 0.001)
    }
    #expect(BentoLayoutFitter(tolerance: 2).fit(
        state: result.state, currentFrames: moved, changedWindowIDs: [a, b], in: resizeBounds
    ) == nil)
}

@Test func nestedSameAxisResizeIsDerivedFromTheTreeAndStaysGapless() throws {
    let a = WindowID(rawValue: "a"), b = WindowID(rawValue: "b"), c = WindowID(rawValue: "c")
    let nestedID = UUID(), rootID = UUID()
    let state = BentoLayoutState(root: .partition(BentoPartition(
        id: rootID, axis: .vertical, weight: 0.5,
        first: .partition(BentoPartition(id: nestedID, axis: .vertical, weight: 0.5, first: .leaf(a), second: .leaf(b))),
        second: .leaf(c)
    )))

    let result = try #require(BentoResizeEngine().resize(
        state: state, branchCoordinates: [rootID: 800], in: resizeBounds
    ))
    let frames = Dictionary(uniqueKeysWithValues: result.placements.map { ($0.windowID, $0.frame) })
    #expect(frames[a] == BTRect(x: 0, y: 0, width: 300, height: 800))
    #expect(frames[b]?.approximatelyEquals(BTRect(x: 300, y: 0, width: 500, height: 800), tolerance: 0.001) == true)
    #expect(frames[c] == BTRect(x: 800, y: 0, width: 400, height: 800))
    #expect(abs(result.placements.reduce(0) { $0 + $1.frame.area } - resizeBounds.area) < 0.01)
}

@Test func multiPaneBoundaryResizePreservesTheUnrelatedPaneAndGap() throws {
    let a = WindowID(rawValue: "a"), b = WindowID(rawValue: "b"), c = WindowID(rawValue: "c")
    let firstBoundary = UUID(), secondBoundary = UUID()
    let state = BentoLayoutState(
        root: .partition(BentoPartition(
            axis: .vertical,
            children: [.leaf(a), .leaf(b), .leaf(c)],
            ratios: [1.0 / 3, 1.0 / 3, 1.0 / 3],
            boundaryIDs: [firstBoundary, secondBoundary]
        )),
        metrics: BentoLayoutMetrics(paneGap: 12)
    )
    let bounds = BTRect(x: 0, y: 0, width: 1_212, height: 800)
    let before = Dictionary(uniqueKeysWithValues: state.placements(in: bounds).map { ($0.windowID, $0.frame) })

    let moved = try #require(BentoResizeEngine().resize(
        state: state,
        branchCoordinates: [firstBoundary: (before[a]!.maxX + before[b]!.minX) / 2 + 80],
        in: bounds
    ))
    let after = Dictionary(uniqueKeysWithValues: moved.placements.map { ($0.windowID, $0.frame) })
    #expect(after[c] == before[c])
    #expect(after[a]!.maxX + 12 == after[b]!.minX)
    #expect(after[b]!.maxX + 12 == after[c]!.minX)
}

@Test func paneGapsParticipateInRecursiveMinimumConstraints() {
    let ids = ["a", "b", "c"].map { WindowID(rawValue: $0) }
    let state = BentoLayoutState(
        root: .partition(BentoPartition(axis: .vertical, children: ids.map(BentoNode.leaf))),
        metrics: BentoLayoutMetrics(paneGap: 12)
    )
    let constraints = Dictionary(uniqueKeysWithValues: ids.map {
        ($0, WindowConstraints(minimumSize: BTSize(width: 330, height: 80)))
    })
    #expect(BentoConstraintSolver().solve(
        state: state,
        in: BTRect(x: 0, y: 0, width: 1_000, height: 700),
        constraints: constraints
    ) == nil)
}

@Test func recursiveMinimumSizesClampTheWholeBranch() throws {
    let a = WindowID(rawValue: "a"), b = WindowID(rawValue: "b"), c = WindowID(rawValue: "c")
    let rootID = UUID()
    let state = BentoLayoutState(root: .partition(BentoPartition(
        id: rootID, axis: .vertical,
        first: .partition(BentoPartition(axis: .vertical, first: .leaf(a), second: .leaf(b))),
        second: .leaf(c)
    )))
    let constraints = Dictionary(uniqueKeysWithValues: [a, b, c].map {
        ($0, WindowConstraints(minimumSize: BTSize(width: 300, height: 80)))
    })
    let bounds = BTRect(x: 0, y: 0, width: 1000, height: 800)

    let result = try #require(BentoResizeEngine().resize(
        state: state, branchCoordinates: [rootID: 350], in: bounds, constraints: constraints
    ))
    #expect(result.appliedCoordinates[rootID] == 600)
    let frames = Dictionary(uniqueKeysWithValues: result.placements.map { ($0.windowID, $0.frame) })
    #expect(frames[a]?.size.width == 300)
    #expect(frames[b]?.size.width == 300)
    #expect(frames[c]?.size.width == 400)
}

@Test func constraintSolverProjectsWeightsWithoutGrowingIndividualLeaves() throws {
    let left = WindowID(rawValue: "left"), right = WindowID(rawValue: "right")
    let branchID = UUID()
    let state = BentoLayoutState(root: .partition(BentoPartition(
        id: branchID,
        axis: .vertical,
        weight: 0.1,
        first: .leaf(left),
        second: .leaf(right)
    )))
    let constraints = [
        left: WindowConstraints(minimumSize: BTSize(width: 320, height: 80)),
        right: WindowConstraints(minimumSize: BTSize(width: 200, height: 80)),
    ]
    let bounds = BTRect(x: 0, y: 0, width: 1000, height: 700)

    let solved = try #require(BentoConstraintSolver().solve(state: state, in: bounds, constraints: constraints))
    let frames = Dictionary(uniqueKeysWithValues: solved.placements(in: bounds).map { ($0.windowID, $0.frame) })
    #expect(frames[left] == BTRect(x: 0, y: 0, width: 320, height: 700))
    #expect(frames[right] == BTRect(x: 320, y: 0, width: 680, height: 700))
    #expect(frames[left]?.maxX == frames[right]?.minX)
    #expect((frames[left]?.area ?? 0) + (frames[right]?.area ?? 0) == bounds.area)
}

@Test func impossibleMinimumSizesRejectTheWholeTree() {
    let left = WindowID(rawValue: "left"), right = WindowID(rawValue: "right")
    let state = BentoLayoutState(root: .partition(BentoPartition(
        axis: .vertical,
        first: .leaf(left),
        second: .leaf(right)
    )))
    let constraints = [
        left: WindowConstraints(minimumSize: BTSize(width: 600, height: 80)),
        right: WindowConstraints(minimumSize: BTSize(width: 500, height: 80)),
    ]
    #expect(BentoConstraintSolver().solve(
        state: state,
        in: BTRect(x: 0, y: 0, width: 1000, height: 700),
        constraints: constraints
    ) == nil)
}

@Test func learnedApplicationMinimumClampsLaterDividerDrags() throws {
    let left = WindowID(rawValue: "left"), right = WindowID(rawValue: "right")
    var learner = WindowMinimumSizeLearner()
    let didLearn = learner.observe(
        windowID: left,
        requested: BTRect(x: 0, y: 0, width: 250, height: 700),
        baseline: BTRect(x: 0, y: 0, width: 500, height: 700),
        actual: BTRect(x: 0, y: 0, width: 360, height: 700)
    )
    #expect(didLearn)
    let constraints = [left: learner.merging(WindowConstraints(), for: left)]
    let branchID = UUID()
    let state = BentoLayoutState(root: .partition(BentoPartition(
        id: branchID,
        axis: .vertical,
        first: .leaf(left),
        second: .leaf(right)
    )))
    let result = try #require(BentoResizeEngine().resize(
        state: state,
        branchCoordinates: [branchID: 200],
        in: BTRect(x: 0, y: 0, width: 1000, height: 700),
        constraints: constraints
    ))
    #expect(result.appliedCoordinates[branchID] == 360)
}

@Test func bentoPlacementsStayInsideBottomAndSideDockWorkAreas() throws {
    let top = WindowID(rawValue: "top"), bottom = WindowID(rawValue: "bottom")
    let state = BentoLayoutState(root: .partition(BentoPartition(
        axis: .horizontal,
        first: .leaf(top),
        second: .leaf(bottom)
    )))
    let visibleFrames = [
        BTRect(x: 0, y: 24, width: 1200, height: 676),
        BTRect(x: 80, y: 24, width: 1120, height: 776),
        BTRect(x: 0, y: 24, width: 1120, height: 776),
    ]
    for visibleFrame in visibleFrames {
        let solved = try #require(BentoConstraintSolver().solve(state: state, in: visibleFrame))
        let placements = solved.placements(in: visibleFrame)
        #expect(placements.allSatisfy {
            $0.frame.minX >= visibleFrame.minX && $0.frame.maxX <= visibleFrame.maxX
                && $0.frame.minY >= visibleFrame.minY && $0.frame.maxY <= visibleFrame.maxY
        })
        #expect(placements.reduce(0) { $0 + $1.frame.area } == visibleFrame.area)
    }
}

@Test func junctionResizeUpdatesEveryIntersectingBranchAtomically() throws {
    let ids = ["a", "b", "c", "d"].map { WindowID(rawValue: $0) }
    let rootID = UUID(), leftID = UUID(), rightID = UUID()
    let state = BentoLayoutState(root: .partition(BentoPartition(
        id: rootID, axis: .vertical,
        first: .partition(BentoPartition(id: leftID, axis: .horizontal, first: .leaf(ids[0]), second: .leaf(ids[1]))),
        second: .partition(BentoPartition(id: rightID, axis: .horizontal, first: .leaf(ids[2]), second: .leaf(ids[3])))
    )))
    let result = try #require(BentoResizeEngine().resize(
        state: state,
        branchCoordinates: [rootID: 700, leftID: 300, rightID: 300],
        in: resizeBounds
    ))
    let frames = Dictionary(uniqueKeysWithValues: result.placements.map { ($0.windowID, $0.frame) })
    #expect(frames[ids[0]] == BTRect(x: 0, y: 0, width: 700, height: 300))
    #expect(frames[ids[1]] == BTRect(x: 0, y: 300, width: 700, height: 500))
    #expect(frames[ids[2]] == BTRect(x: 700, y: 0, width: 500, height: 300))
    #expect(frames[ids[3]] == BTRect(x: 700, y: 300, width: 500, height: 500))
}

@Test func actualFrameBoundaryResolverRejectsInteriorAndMergesRealSegments() {
    let a = WindowID(rawValue: "a"), b = WindowID(rawValue: "b"), c = WindowID(rawValue: "c"), d = WindowID(rawValue: "d")
    let rootID = UUID()
    let state = BentoLayoutState(root: .partition(BentoPartition(
        id: rootID, axis: .vertical,
        first: .partition(BentoPartition(axis: .horizontal, first: .leaf(a), second: .leaf(b))),
        second: .partition(BentoPartition(axis: .horizontal, first: .leaf(c), second: .leaf(d)))
    )))
    let matching = [
        window(a, x: 0, y: 0, width: 600, height: 400),
        window(b, x: 0, y: 400, width: 600, height: 400),
        window(c, x: 600, y: 0, width: 600, height: 400),
        window(d, x: 600, y: 400, width: 600, height: 400),
    ]
    let boundaries = BentoBoundaryResolver().boundaries(
        state: state, windows: matching, displayID: resizeDisplay, bounds: resizeBounds
    )
    let root = boundaries.first { $0.branchID == rootID }
    #expect(root?.coordinate == 600)
    #expect(root?.spanStart == 0)
    #expect(root?.spanEnd == 800)
    #expect(root?.beforeWindowIDs == [a, b])
    #expect(root?.afterWindowIDs == [c, d])

    var overlapping = matching
    overlapping[0].frame.size.width = 700
    overlapping[1].frame.size.width = 700
    #expect(BentoBoundaryResolver().boundaries(
        state: state, windows: overlapping, displayID: resizeDisplay, bounds: resizeBounds
    ).allSatisfy { $0.branchID != rootID })
}

@Test func nativeEdgeResizeIsAdoptedAndReflowsItsNeighbor() throws {
    let a = WindowID(rawValue: "a"), b = WindowID(rawValue: "b")
    let rootID = UUID()
    let state = BentoLayoutState(root: .partition(BentoPartition(
        id: rootID, axis: .vertical, first: .leaf(a), second: .leaf(b)
    )))
    let frames = [
        a: BTRect(x: 0, y: 0, width: 700, height: 800),
        b: BTRect(x: 600, y: 0, width: 600, height: 800),
    ]
    let fitted = try #require(BentoLayoutFitter().fit(
        state: state, currentFrames: frames, changedWindowIDs: [a], in: resizeBounds
    ))
    let placements = Dictionary(uniqueKeysWithValues: fitted.placements.map { ($0.windowID, $0.frame) })
    #expect(fitted.appliedCoordinates[rootID] == 700)
    #expect(placements[a]?.maxX == 700)
    #expect(placements[b]?.minX == 700)
    #expect(placements[b]?.maxX == resizeBounds.maxX)
}

private func window(_ id: WindowID, x: Double, y: Double, width: Double, height: Double) -> WindowSnapshot {
    WindowSnapshot(
        id: id, processIdentifier: 1,
        frame: BTRect(x: x, y: y, width: width, height: height),
        displayID: resizeDisplay
    )
}
