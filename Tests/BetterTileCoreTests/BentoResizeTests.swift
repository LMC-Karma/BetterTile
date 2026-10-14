import Foundation
import Testing
@testable import BetterTileCore

private let resizeBounds = BTRect(x: 0, y: 0, width: 1200, height: 800)
private let resizeDisplay = DisplayID(rawValue: "display")

@Test(arguments: [SplitAxis.vertical, .horizontal], [-100.0, 900.0])
func unlockedBentoDividerClampsWithoutMovingLockedNeighbor(axis: SplitAxis, coordinate: Double) throws {
    let ids = ["a", "b", "c"].map { WindowID(rawValue: $0) }
    let moving = UUID(), locked = UUID()
    let bounds = BTRect(x: 0, y: 0, width: 1200, height: 1200)
    let state = BentoLayoutState(root: .partition(BentoPartition(
        axis: axis, children: ids.map(BentoNode.leaf),
        boundaryIDs: [moving, locked], lockedBoundaryIDs: [locked]
    )))
    let constraints = Dictionary(uniqueKeysWithValues: ids.map {
        ($0, WindowConstraints(minimumSize: BTSize(width: 120, height: 120)))
    })
    let before = state.placements(in: bounds, constraints: constraints)
    let result = try #require(BentoResizeEngine().resize(
        state: state, branchCoordinates: [moving: coordinate], in: bounds, constraints: constraints
    ))
    #expect(result.placements.last == before.last)
    let first = try #require(result.placements.first).frame
    #expect(abs((axis == .vertical ? first.size.width : first.size.height) - (coordinate < 0 ? 120 : 680)) < 0.001)
    let boundary = try #require(result.state.boundaries(in: bounds, displayID: resizeDisplay).first { $0.branchID == locked })
    #expect(abs(boundary.coordinate - 800) < 0.001)
}

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
    , now: 0)
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
    , now: 0)
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

@Test func learnedMinimumIsForgottenWithItsWindow() {
    var learner = WindowMinimumSizeLearner()
    let id = WindowID(rawValue: "w")
    let learned = learner.observe(
        windowID: id,
        requested: BTRect(x: 0, y: 0, width: 200, height: 400),
        baseline: BTRect(x: 0, y: 0, width: 500, height: 400),
        actual: BTRect(x: 0, y: 0, width: 360, height: 400)
    , now: 0)
    #expect(learned)
    #expect(learner.merging(WindowConstraints(), for: id).minimumSize.width == 360)
    learner.remove(id)
    #expect(learner.merging(WindowConstraints(), for: id).minimumSize.width == WindowConstraints().minimumSize.width)
}

@Test func positionOnlyChangesDoNotProveApplicationMinimums() {
    var learner = WindowMinimumSizeLearner()
    let baseline = BTRect(x: 100, y: 100, width: 600, height: 500)
    let learned = learner.observe(windowID: WindowID(rawValue: "ignored-size"),
        requested: BTRect(x: 0, y: 34, width: 400, height: 300), baseline: baseline,
        actual: BTRect(x: 0, y: 34, width: 600, height: 500), now: 0)
    #expect(!learned)
}

@Test func smallerAcceptedSizeCapsOnlyTheDisprovedLearnedMinimum() {
    let id = WindowID(rawValue: "content-changed")
    var learner = WindowMinimumSizeLearner(learnedSizes: [id: BTSize(width: 600, height: 450)])
    let first = learner.observeAcceptedSize(windowID: id, size: BTSize(width: 400, height: 500))
    #expect(!first)
    let capped = learner.observeAcceptedSize(windowID: id, size: BTSize(width: 400, height: 500))
    #expect(capped)
    #expect(learner.learnedSizes[id] == BTSize(width: 400, height: 450))
    let reported = WindowConstraints(minimumSize: BTSize(width: 480, height: 300))
    #expect(learner.merging(reported, for: id).minimumSize == BTSize(width: 480, height: 450))
    let grew = learner.observeAcceptedSize(windowID: id, size: BTSize(width: 800, height: 600))
    #expect(!grew)
    #expect(learner.learnedSizes[id] == BTSize(width: 400, height: 450))
}

@Test(arguments: [BTSize(width: .nan, height: 300), BTSize(width: 300, height: .infinity),
                  BTSize(width: 0, height: 300), BTSize(width: 300, height: -1)])
func invalidAcceptedSizesCannotChangeLearnedMinimums(size: BTSize) {
    let id = WindowID(rawValue: "invalid-size")
    var learner = WindowMinimumSizeLearner(learnedSizes: [id: BTSize(width: 600, height: 450)])
    learner.observeAcceptedSize(windowID: id, size: BTSize(width: 400, height: 300))
    let changed = learner.observeAcceptedSize(windowID: id, size: size)
    #expect(!changed)
    #expect(learner.learnedSizes[id] == BTSize(width: 600, height: 450))
    let restarted = learner.observeAcceptedSize(windowID: id, size: BTSize(width: 400, height: 300))
    #expect(!restarted)
}

@Test func transientSmallerSnapshotDoesNotEraseLearnedMinimum() {
    let id = WindowID(rawValue: "transient-frame")
    let minimum = BTSize(width: 600, height: 450)
    var learner = WindowMinimumSizeLearner(learnedSizes: [id: minimum])
    let transient = learner.observeAcceptedSize(windowID: id, size: BTSize(width: 400, height: 300))
    let restored = learner.observeAcceptedSize(windowID: id, size: minimum)
    #expect(!transient)
    #expect(!restored)
    #expect(learner.learnedSizes[id] == minimum)
}

@Test func smallerAcceptedSizeRequiresStableWholeSize() {
    let id = WindowID(rawValue: "changing-frame")
    var learner = WindowMinimumSizeLearner(learnedSizes: [id: BTSize(width: 600, height: 450)])
    learner.observeAcceptedSize(windowID: id, size: BTSize(width: 400, height: 300))
    let changing = learner.observeAcceptedSize(windowID: id, size: BTSize(width: 400, height: 350))
    #expect(!changing)
    #expect(learner.learnedSizes[id] == BTSize(width: 600, height: 450))
    let settled = learner.observeAcceptedSize(windowID: id, size: BTSize(width: 400.5, height: 350.5))
    #expect(settled)
    #expect(learner.learnedSizes[id] == BTSize(width: 400.5, height: 350.5))
}

@Test func removingLearnedMinimumsAlsoClearsSmallerSizeCandidates() {
    let id = WindowID(rawValue: "removed-candidate")
    var learner = WindowMinimumSizeLearner(learnedSizes: [id: BTSize(width: 600, height: 450)])
    learner.observeAcceptedSize(windowID: id, size: BTSize(width: 400, height: 300))
    learner.remove(id)
    learner.observe(windowID: id, requested: BTRect(x: 0, y: 0, width: 300, height: 250),
                    baseline: BTRect(x: 0, y: 0, width: 800, height: 600),
                    actual: BTRect(x: 0, y: 0, width: 600, height: 450), now: 0)
    let restarted = learner.observeAcceptedSize(windowID: id, size: BTSize(width: 400, height: 300))
    #expect(!restarted)
}

@Test(arguments: [false, true])
func newLearnedMinimumEvidenceClearsSmallerSizeCandidates(increased: Bool) {
    let id = WindowID(rawValue: "renewed-candidate")
    var learner = WindowMinimumSizeLearner(learnedSizes: [id: BTSize(width: 600, height: 450)])
    learner.observeAcceptedSize(windowID: id, size: BTSize(width: 400, height: 300))
    let minimum = increased ? BTSize(width: 800, height: 600) : BTSize(width: 600, height: 450)
    learner.observe(windowID: id, requested: BTRect(x: 0, y: 0, width: 300, height: 250),
                    baseline: BTRect(x: 0, y: 0, width: 1000, height: 800),
                    actual: BTRect(origin: BTPoint(x: 0, y: 0), size: minimum), now: 0)
    let restarted = learner.observeAcceptedSize(windowID: id, size: BTSize(width: 400, height: 300))
    #expect(!restarted)
    #expect(learner.learnedSizes[id] == minimum)
}

@Test(arguments: [SplitAxis.vertical, .horizontal], [1.0, 50.0])
func equallyContradictoryNativeEdgesDoNotChooseAnArbitraryDivider(axis: SplitAxis, displacement: Double) {
    let a = WindowID(rawValue: "a"), b = WindowID(rawValue: "b")
    let square = BTRect(x: 0, y: 0, width: 1200, height: 1200)
    let state = BentoLayoutState(root: .partition(BentoPartition(axis: axis, first: .leaf(a), second: .leaf(b))))
    let frames: [WindowID: BTRect] = axis == .vertical ? [
        a: BTRect(x: 0, y: 0, width: 600 + displacement, height: 1200),
        b: BTRect(x: 600 - displacement, y: 0, width: 600 + displacement, height: 1200),
    ] : [
        a: BTRect(x: 0, y: 0, width: 1200, height: 600 + displacement),
        b: BTRect(x: 0, y: 600 - displacement, width: 1200, height: 600 + displacement),
    ]
    #expect(BentoLayoutFitter().fit(state: state, currentFrames: frames,
        changedWindowIDs: [a, b], in: square) == nil)
}

@Test(arguments: [650.0, 550.0])
func agreeingOrUnequalNativeEdgesKeepTheStrongestDividerEvidence(otherEdge: Double) throws {
    let a = WindowID(rawValue: "a"), b = WindowID(rawValue: "b")
    let branch = UUID()
    let state = BentoLayoutState(root: .partition(BentoPartition(id: branch,
        axis: .vertical, first: .leaf(a), second: .leaf(b))))
    let controlledEdge = otherEdge == 650 ? 650.0 : 700.0
    let frames = [a: BTRect(x: 0, y: 0, width: controlledEdge, height: 800),
                  b: BTRect(x: otherEdge, y: 0, width: 1200 - otherEdge, height: 800)]
    let fitted = try #require(BentoLayoutFitter().fit(state: state, currentFrames: frames,
        changedWindowIDs: [a, b], in: resizeBounds))
    #expect(fitted.appliedCoordinates[branch] == controlledEdge)
    #expect(fitted.placements.count == 2)
}

private let readbackID = WindowID(rawValue: "readback")
private let afterDelay = WindowMinimumSizeLearner.clampConfirmationDelay

/// Brave at 500 wide was asked for 477 at a new origin. It moved at once and
/// still showed 500, which a late size would also show. The kept size is
/// learned only when a snapshot after the delay still shows it.
@Test func writeReadbackKeepsAMovedWindowsSizeAsAPendingClamp() {
    var learner = WindowMinimumSizeLearner()
    let previous = BTRect(x: 1440, y: 515, width: 500, height: 483)
    let requested = BTRect(x: 1463, y: 515, width: 477, height: 483)
    let actual = BTRect(x: 1463, y: 515, width: 500, height: 483)
    let r1 = learner.observeWriteReadback(windowID: readbackID, application: "com.brave.Browser",
        requested: requested, previous: previous, actual: actual, now: 10)
    #expect(!r1)
    #expect(learner.learnedSizes[readbackID] == nil)
    #expect(learner.applicationSizes.isEmpty)
    // A snapshot before the delay leaves the candidate pending.
    let early = learner.confirmClampCandidate(windowID: readbackID, application: "com.brave.Browser",
        size: actual.size, now: 10 + afterDelay / 2)
    #expect(!early)
    let confirmed = learner.confirmClampCandidate(windowID: readbackID, application: "com.brave.Browser",
        size: actual.size, now: 10 + afterDelay)
    #expect(confirmed)
    #expect(learner.learnedSizes[readbackID] == BTSize(width: 500, height: 0))
    #expect(learner.applicationSizes["com.brave.Browser"] == BTSize(width: 500, height: 0))
}

/// Chromium applies the position at once and the size later. The readback
/// shows the old size at the new origin; the next snapshot shows the
/// requested size. Nothing is learned, and no seed is taken.
@Test func aLateAppliedSizeIsNeverLearned() {
    var learner = WindowMinimumSizeLearner()
    let previous = BTRect(x: 0, y: 0, width: 1400, height: 900)
    let requested = BTRect(x: 700, y: 0, width: 700, height: 900)
    let learned = learner.observeWriteReadback(windowID: readbackID, application: "com.google.Chrome",
        requested: requested, previous: previous, actual: BTRect(x: 700, y: 0, width: 1400, height: 900), now: 0)
    #expect(!learned)
    let resized = learner.confirmClampCandidate(windowID: readbackID, application: "com.google.Chrome",
        size: requested.size, now: 0.05)
    #expect(!resized)
    // The candidate is gone: a later snapshot at the old size proves nothing.
    let stale = learner.confirmClampCandidate(windowID: readbackID, application: "com.google.Chrome",
        size: previous.size, now: 1)
    #expect(!stale)
    #expect(learner.learnedSizes.isEmpty)
    #expect(learner.applicationSizes.isEmpty)
    #expect(learner.merging(WindowConstraints(), for: WindowID(rawValue: "other"), application: "com.google.Chrome")
        .minimumSize == WindowConstraints().minimumSize)
}

/// A window that grew although it was asked to shrink can show a late size
/// from an earlier, larger write. It is a pending clamp, not a minimum.
@Test func aWindowThatGrewIsNotLearnedAtOnce() {
    var learner = WindowMinimumSizeLearner()
    let learned = learner.observeWriteReadback(windowID: readbackID, requested: BTRect(x: 0, y: 0, width: 500, height: 800),
        previous: BTRect(x: 0, y: 0, width: 500, height: 800), actual: BTRect(x: 0, y: 0, width: 900, height: 800), now: 0)
    #expect(!learned)
    #expect(learner.learnedSizes[readbackID] == nil)
    // The application then applies this write's size.
    let resized = learner.confirmClampCandidate(windowID: readbackID, size: BTSize(width: 500, height: 800), now: afterDelay)
    #expect(!resized)
    #expect(learner.learnedSizes[readbackID] == nil)
}

/// A move to a display with another backing scale can report the old size
/// at the new origin for a moment. That readback is not a minimum.
@Test func aMoveToAnotherDisplayThatKeptItsSizeIsNotLearned() {
    var learner = WindowMinimumSizeLearner()
    let onFirstDisplay = BTRect(x: 200, y: 100, width: 1200, height: 800)
    let onSecondDisplay = BTRect(x: 1800, y: 100, width: 800, height: 600)
    let learned = learner.observeWriteReadback(windowID: readbackID, application: "com.example.Editor",
        requested: onSecondDisplay, previous: onFirstDisplay,
        actual: BTRect(x: 1800, y: 100, width: 1200, height: 800), now: 0)
    #expect(!learned)
    #expect(learner.learnedSizes[readbackID] == nil)
    #expect(learner.applicationSizes.isEmpty)
    // The window then takes the requested size on the new display.
    let resized = learner.confirmClampCandidate(windowID: readbackID, application: "com.example.Editor",
        size: onSecondDisplay.size, now: afterDelay)
    #expect(!resized)
    #expect(learner.learnedSizes[readbackID] == nil)
}

@Test func writeReadbackIgnoresAWriteTheApplicationDidNotProcess() {
    var learner = WindowMinimumSizeLearner()
    let previous = BTRect(x: 0, y: 0, width: 500, height: 400)
    // Nothing moved: an asynchronous application, or an ignored write.
    let r2 = learner.observeWriteReadback(windowID: readbackID,
        requested: BTRect(x: 100, y: 0, width: 300, height: 400), previous: previous, actual: previous, now: 0)
    #expect(!r2)
    // Same origin and same size: no proof the write was processed.
    let r3 = learner.observeWriteReadback(windowID: readbackID,
        requested: BTRect(x: 0, y: 0, width: 300, height: 400), previous: previous, actual: previous, now: 0)
    #expect(!r3)
    // Neither leaves a candidate for a later snapshot to confirm.
    let confirmed = learner.confirmClampCandidate(windowID: readbackID, size: previous.size, now: afterDelay)
    #expect(!confirmed)
    #expect(learner.learnedSizes[readbackID] == nil)
}

@Test func writeReadbackMeasuresPartialShrinksAndLowersStaleBounds() {
    var learner = WindowMinimumSizeLearner()
    let previous = BTRect(x: 0, y: 0, width: 900, height: 600)
    // The window shrank, but only to its 708 pt minimum.
    let r4 = learner.observeWriteReadback(windowID: readbackID, requested: BTRect(x: 0, y: 0, width: 500, height: 600),
        previous: previous, actual: BTRect(x: 0, y: 0, width: 708, height: 600), now: 0)
    #expect(r4)
    #expect(learner.learnedSizes[readbackID] == BTSize(width: 708, height: 0))
    // A sidebar closed; a later request below the bound is accepted.
    let r5 = learner.observeWriteReadback(windowID: readbackID, requested: BTRect(x: 0, y: 0, width: 600, height: 600),
        previous: BTRect(x: 0, y: 0, width: 708, height: 600), actual: BTRect(x: 0, y: 0, width: 600, height: 600), now: 0)
    #expect(r5)
    #expect(learner.learnedSizes[readbackID] == BTSize(width: 600, height: 0))
}

/// One axis shrank and stopped; the other kept its size. Only the first is
/// proven now. The kept axis waits for a later snapshot.
@Test func writeReadbackLearnsOnlyTheAxisThatShrankAndStopped() {
    var learner = WindowMinimumSizeLearner()
    let learned = learner.observeWriteReadback(windowID: readbackID, requested: BTRect(x: 0, y: 0, width: 400, height: 300),
        previous: BTRect(x: 0, y: 0, width: 900, height: 500), actual: BTRect(x: 0, y: 0, width: 600, height: 500), now: 0)
    #expect(learned)
    #expect(learner.learnedSizes[readbackID] == BTSize(width: 600, height: 0))
    let confirmed = learner.confirmClampCandidate(windowID: readbackID, size: BTSize(width: 600, height: 500), now: afterDelay)
    #expect(confirmed)
    #expect(learner.learnedSizes[readbackID] == BTSize(width: 600, height: 500))
}

/// A window already at its minimum keeps its size and origin. The position
/// nudge proves the application handles writes, not that the size is final,
/// so the kept size is learned only after a later snapshot.
@Test func aWindowAtItsMinimumIsLearnedOnlyAfterDelayedConfirmation() {
    var learner = WindowMinimumSizeLearner()
    let kept = BTRect(x: 100, y: 50, width: 708, height: 484)
    let requested = BTRect(x: 100, y: 50, width: 458, height: 484)
    let learnedNow = learner.observeWriteReadback(windowID: readbackID, application: "com.apple.Preview",
        requested: requested, previous: kept, actual: kept, now: 3)
    #expect(!learnedNow)
    #expect(WriteReadbackPolicy.needsClampConfirmation(
        requested: requested, previous: kept, actual: kept, learnedMinimum: nil))
    learner.recordClampCandidate(windowID: readbackID, requested: requested.size, actual: kept.size, now: 3)
    #expect(learner.learnedSizes[readbackID] == nil)
    #expect(learner.applicationSizes.isEmpty)
    let early = learner.confirmClampCandidate(windowID: readbackID, application: "com.apple.Preview",
        size: kept.size, now: 3.1)
    #expect(!early)
    let confirmed = learner.confirmClampCandidate(windowID: readbackID, application: "com.apple.Preview",
        size: kept.size, now: 3 + afterDelay)
    #expect(confirmed)
    #expect(learner.learnedSizes[readbackID] == BTSize(width: 708, height: 0))
    #expect(learner.merging(WindowConstraints(), for: WindowID(rawValue: "other"), application: "com.apple.Preview")
        .minimumSize.width == 708)
}

/// A settled frame confirms a pending clamp only once the delay has passed
/// since the write. Bento settlement can settle after about 80 ms and the
/// Tabbed loop after about 150 ms; an application can still apply its size
/// after either, so those frames leave the candidate pending.
@Test(arguments: [0.08, 0.15])
func anEarlySettledFrameLeavesAPendingClampPending(settledAfter: Double) {
    let previous = BTRect(x: 200, y: 200, width: 600, height: 400)
    let requested = BTRect(x: 0, y: 34, width: 400, height: 400)
    let kept = BTRect(x: 0, y: 34, width: 600, height: 400)
    var learner = WindowMinimumSizeLearner()
    learner.observeWriteReadback(windowID: readbackID, application: "com.google.Chrome",
        requested: requested, previous: previous, actual: kept, now: 10)
    let early = learner.observe(windowID: readbackID, application: "com.google.Chrome",
        requested: requested, baseline: previous, actual: kept, now: 10 + settledAfter)
    #expect(!early)
    #expect(learner.learnedSizes.isEmpty)
    // The application applies the size at 200 ms: nothing is learned.
    var late = learner
    let resized = late.confirmClampCandidate(windowID: readbackID, application: "com.google.Chrome",
        size: requested.size, now: 10.2)
    #expect(!resized)
    let stale = late.confirmClampCandidate(windowID: readbackID, size: kept.size, now: 11)
    #expect(!stale)
    #expect(late.learnedSizes.isEmpty)
    #expect(late.applicationSizes.isEmpty)
    // A real clamp keeps its size; a later observation confirms it.
    let confirmed = learner.observe(windowID: readbackID, application: "com.google.Chrome",
        requested: requested, baseline: previous, actual: kept, now: 10 + afterDelay)
    #expect(confirmed)
    #expect(learner.learnedSizes[readbackID] == BTSize(width: 600, height: 0))
}

/// A size applied after the delay is the documented limit: the kept size is
/// learned, and only two smaller stable snapshots lower it again.
@Test func aSizeAppliedAfterTheDelayIsLearnedUntilDisproved() {
    let previous = BTRect(x: 200, y: 200, width: 600, height: 400)
    let requested = BTRect(x: 0, y: 34, width: 400, height: 400)
    let kept = BTRect(x: 0, y: 34, width: 600, height: 400)
    var learner = WindowMinimumSizeLearner()
    learner.observeWriteReadback(windowID: readbackID, requested: requested, previous: previous, actual: kept, now: 0)
    let learned = learner.observe(windowID: readbackID, requested: requested, baseline: previous, actual: kept, now: 0.3)
    #expect(learned)
    learner.observeAcceptedSize(windowID: readbackID, size: requested.size)
    let lowered = learner.observeAcceptedSize(windowID: readbackID, size: requested.size)
    #expect(lowered)
    #expect(learner.learnedSizes[readbackID] == BTSize(width: 400, height: 0))
}

/// A settled frame confirms only its own pending clamp: a settled frame of
/// another size drops it, and one for another request leaves it alone. A
/// confirmed clamp becomes the application's seed.
@Test func aSettledFrameConfirmsOnlyItsOwnPendingClamp() {
    let previous = BTRect(x: 200, y: 200, width: 600, height: 400)
    let requested = BTRect(x: 0, y: 34, width: 400, height: 400)
    let kept = BTRect(x: 0, y: 34, width: 600, height: 400)
    var learner = WindowMinimumSizeLearner()
    learner.observeWriteReadback(windowID: readbackID, requested: requested, previous: previous, actual: kept, now: 0)
    let settled = learner.observe(windowID: readbackID, application: "com.apple.Preview",
        requested: requested, baseline: previous, actual: kept, now: afterDelay)
    #expect(settled)
    #expect(learner.learnedSizes[readbackID] == BTSize(width: 600, height: 0))
    #expect(learner.applicationSizes["com.apple.Preview"] == BTSize(width: 600, height: 0))

    var late = WindowMinimumSizeLearner()
    late.observeWriteReadback(windowID: readbackID, requested: requested, previous: previous, actual: kept, now: 0)
    let resized = late.observe(windowID: readbackID, requested: requested, baseline: previous, actual: requested, now: afterDelay)
    #expect(!resized)
    #expect(late.learnedSizes.isEmpty)

    var other = WindowMinimumSizeLearner()
    other.observeWriteReadback(windowID: readbackID, requested: requested, previous: previous, actual: kept, now: 0)
    let otherRequest = other.observe(windowID: readbackID, requested: BTRect(x: 0, y: 34, width: 300, height: 400),
        baseline: previous, actual: kept, now: afterDelay)
    #expect(!otherRequest)
    #expect(other.learnedSizes.isEmpty)
}

/// A shrink that settled short of its request is also a seed.
@Test func aSettledShrinkBecomesTheApplicationSeed() {
    var learner = WindowMinimumSizeLearner()
    let learned = learner.observe(windowID: readbackID, application: "com.apple.mail",
        requested: BTRect(x: 0, y: 0, width: 200, height: 400), baseline: BTRect(x: 0, y: 0, width: 500, height: 400),
        actual: BTRect(x: 0, y: 0, width: 360, height: 400), now: 0)
    #expect(learned)
    #expect(learner.applicationSizes["com.apple.mail"] == BTSize(width: 360, height: 0))
}

/// A window at its real minimum width of 600 is asked for 400 x 300 and
/// moves at once. Its height reaches 300 after 100 ms, while its width stays
/// clamped. The late height drops only the height axis: the kept width is
/// still confirmed after the delay.
@Test func eachAxisOfAPendingClampIsConfirmedOnItsOwn() {
    var learner = WindowMinimumSizeLearner()
    let learned = learner.observeWriteReadback(windowID: readbackID, application: "com.apple.Preview",
        requested: BTRect(x: 0, y: 34, width: 400, height: 300), previous: BTRect(x: 200, y: 200, width: 600, height: 800),
        actual: BTRect(x: 0, y: 34, width: 600, height: 800), now: 0)
    #expect(!learned)
    let lateHeight = learner.confirmClampCandidate(windowID: readbackID, size: BTSize(width: 600, height: 300), now: 0.1)
    #expect(!lateHeight)
    let confirmed = learner.confirmClampCandidate(windowID: readbackID, application: "com.apple.Preview",
        size: BTSize(width: 600, height: 300), now: afterDelay)
    #expect(confirmed)
    #expect(learner.learnedSizes[readbackID] == BTSize(width: 600, height: 0))
    #expect(learner.applicationSizes["com.apple.Preview"] == BTSize(width: 600, height: 0))

    // The same through a settled frame.
    var settled = WindowMinimumSizeLearner()
    settled.observeWriteReadback(windowID: readbackID, requested: BTRect(x: 0, y: 34, width: 400, height: 300),
        previous: BTRect(x: 200, y: 200, width: 600, height: 800), actual: BTRect(x: 0, y: 34, width: 600, height: 800), now: 0)
    let reported = settled.observe(windowID: readbackID, requested: BTRect(x: 0, y: 34, width: 400, height: 300),
        baseline: BTRect(x: 200, y: 200, width: 600, height: 800), actual: BTRect(x: 0, y: 34, width: 600, height: 300),
        now: afterDelay)
    #expect(reported)
    #expect(settled.learnedSizes[readbackID] == BTSize(width: 600, height: 0))
}

/// A newer write replaces the request a candidate belonged to, and a
/// snapshot of another size disproves it.
@Test func aNewerWriteOrAnotherSizeDropsAPendingClamp() {
    let kept = BTSize(width: 600, height: 400)
    var learner = WindowMinimumSizeLearner()
    learner.recordClampCandidate(windowID: readbackID, requested: BTSize(width: 400, height: 400), actual: kept, now: 0)
    learner.discardClampCandidate(for: readbackID)
    let afterNewerWrite = learner.confirmClampCandidate(windowID: readbackID, size: kept, now: afterDelay)
    #expect(!afterNewerWrite)

    learner.recordClampCandidate(windowID: readbackID, requested: BTSize(width: 400, height: 400), actual: kept, now: 0)
    let resized = learner.confirmClampCandidate(windowID: readbackID, size: BTSize(width: 500, height: 400), now: afterDelay)
    #expect(!resized)
    let stale = learner.confirmClampCandidate(windowID: readbackID, size: kept, now: 2 * afterDelay)
    #expect(!stale)
    #expect(learner.learnedSizes.isEmpty)
}

@Test func applicationSeedStartsNewWindowsFromTheLatestMeasurement() {
    var learner = WindowMinimumSizeLearner()
    let first = WindowID(rawValue: "brave-1"), second = WindowID(rawValue: "brave-2")
    let measured = learner.observeWriteReadback(windowID: first, application: "com.brave.Browser",
        requested: BTRect(x: 100, y: 0, width: 300, height: 300), previous: BTRect(x: 0, y: 0, width: 800, height: 600),
        actual: BTRect(x: 100, y: 0, width: 500, height: 375), now: 0)
    #expect(measured)
    let seeded = learner.merging(WindowConstraints(), for: second, application: "com.brave.Browser")
    #expect(seeded.minimumSize == BTSize(width: 500, height: 375))
    // Another application keeps the default floor.
    #expect(learner.merging(WindowConstraints(), for: second, application: "com.apple.Preview").minimumSize
        == WindowConstraints().minimumSize)
    // An accepted write measures no minimum, so the seed stays.
    let own = learner.observeWriteReadback(windowID: second, application: "com.brave.Browser",
        requested: BTRect(x: 50, y: 0, width: 600, height: 400), previous: BTRect(x: 0, y: 0, width: 800, height: 600),
        actual: BTRect(x: 50, y: 0, width: 600, height: 400), now: 0)
    #expect(!own)
    #expect(learner.merging(WindowConstraints(), for: second, application: "com.brave.Browser").minimumSize
        == BTSize(width: 500, height: 375))
}

/// An ambiguous readback of a new window must not replace a proven seed.
@Test func anAmbiguousReadbackDoesNotChangeTheSeed() {
    var learner = WindowMinimumSizeLearner()
    let first = WindowID(rawValue: "chrome-1"), second = WindowID(rawValue: "chrome-2")
    learner.observeProbe(windowID: first, application: "com.google.Chrome",
        original: BTSize(width: 1200, height: 800), clamped: BTSize(width: 500, height: 300))
    learner.observeWriteReadback(windowID: second, application: "com.google.Chrome",
        requested: BTRect(x: 700, y: 0, width: 700, height: 900), previous: BTRect(x: 0, y: 0, width: 1400, height: 900),
        actual: BTRect(x: 700, y: 0, width: 1400, height: 900), now: 0)
    #expect(learner.applicationSizes["com.google.Chrome"] == BTSize(width: 500, height: 300))
    #expect(learner.learnedSizes[second] == nil)
}

/// A seed from a large main window must not stay the floor of a smaller
/// window of the same application once that window is measured.
@Test func probeMeasurementReplacesALargerSeedForItsWindow() {
    var learner = WindowMinimumSizeLearner()
    let main = WindowID(rawValue: "mail-main"), compose = WindowID(rawValue: "mail-compose")
    learner.observeProbe(windowID: main, application: "com.apple.mail",
        original: BTSize(width: 1200, height: 800), clamped: BTSize(width: 900, height: 600))
    // Before its probe, the new window plans with the seed and still needs one.
    #expect(learner.merging(WindowConstraints(), for: compose, application: "com.apple.mail").minimumSize
        == BTSize(width: 900, height: 600))
    #expect(learner.windowsNeedingMeasurement([main, compose]) == [compose])
    let probed = learner.observeProbe(windowID: compose, application: "com.apple.mail",
        original: BTSize(width: 700, height: 500), clamped: BTSize(width: 400, height: 300))
    #expect(probed)
    #expect(learner.windowsNeedingMeasurement([main, compose]).isEmpty)
    #expect(learner.merging(WindowConstraints(), for: compose, application: "com.apple.mail").minimumSize
        == BTSize(width: 400, height: 300))
    // The main window keeps its own, and the latest measurement is the seed.
    #expect(learner.merging(WindowConstraints(), for: main, application: "com.apple.mail").minimumSize
        == BTSize(width: 900, height: 600))
    #expect(learner.applicationSizes["com.apple.mail"] == BTSize(width: 400, height: 300))
}

/// A probe that leaves the size unchanged measures nothing: the window can be
/// at its minimum, or its application can apply the size late. The probe
/// restores the size at once, so a later snapshot confirms nothing either,
/// and the window is not probed again.
@Test func aProbeThatKeptTheSizeMeasuresNothingAndIsNotRepeated() {
    var learner = WindowMinimumSizeLearner()
    let late = WindowID(rawValue: "late")
    let original = BTSize(width: 800, height: 600)
    learner.recordProbe(of: late)
    let kept = learner.observeProbe(windowID: late, application: "com.google.Chrome", original: original, clamped: original)
    #expect(!kept)
    let confirmed = learner.confirmClampCandidate(windowID: late, application: "com.google.Chrome", size: original, now: 10)
    #expect(!confirmed)
    #expect(!learner.hasMeasurement(for: late))
    #expect(learner.applicationSizes.isEmpty)
    #expect(learner.windowsNeedingMeasurement([late]).isEmpty)
    // One axis that shrank and stopped is still a measurement.
    let partial = WindowID(rawValue: "partial")
    let shrank = learner.observeProbe(windowID: partial, original: original, clamped: BTSize(width: 500, height: 600))
    #expect(shrank)
    #expect(learner.learnedSizes[partial] == BTSize(width: 500, height: 0))
}

@Test func forgettingAnApplicationKeepsOtherSeedsAndWindowMeasurements() {
    var learner = WindowMinimumSizeLearner()
    let mail = WindowID(rawValue: "mail"), notes = WindowID(rawValue: "notes")
    let original = BTSize(width: 1200, height: 800)
    learner.observeProbe(windowID: mail, application: "com.apple.mail",
        original: original, clamped: BTSize(width: 900, height: 600))
    learner.observeProbe(windowID: notes, application: "com.apple.Notes",
        original: original, clamped: BTSize(width: 500, height: 400))

    learner.forgetApplication("com.apple.mail")
    learner.forgetApplication("com.example.never-measured")

    #expect(learner.applicationSizes == ["com.apple.Notes": BTSize(width: 500, height: 400)])
    #expect(learner.learnedSizes[mail] == BTSize(width: 900, height: 600))
    #expect(learner.learnedSizes[notes] == BTSize(width: 500, height: 400))
    let fresh = WindowID(rawValue: "mail-relaunched")
    #expect(learner.merging(WindowConstraints(), for: fresh, application: "com.apple.mail").minimumSize
        == WindowConstraints().minimumSize)
}

/// Forgetting one window drops its measurement and pending evidence. The
/// window then plans with its application's seed, and it is not probed again.
@Test func forgettingAWindowDropsItsMeasurementAndPendingClamp() {
    var learner = WindowMinimumSizeLearner()
    let window = WindowID(rawValue: "window"), sibling = WindowID(rawValue: "sibling")
    learner.observeProbe(windowID: sibling, application: "com.example.App",
        original: BTSize(width: 1000, height: 800), clamped: BTSize(width: 400, height: 300))
    learner.recordProbe(of: window)
    learner.observeProbe(windowID: window, application: "com.example.App",
        original: BTSize(width: 1000, height: 800), clamped: BTSize(width: 700, height: 500))
    learner.recordClampCandidate(windowID: window, requested: BTSize(width: 300, height: 500),
        actual: BTSize(width: 900, height: 500), now: 0)

    learner.forget(windowID: window)

    #expect(!learner.hasMeasurement(for: window))
    let confirmed = learner.confirmClampCandidate(windowID: window, size: BTSize(width: 900, height: 500), now: afterDelay)
    #expect(!confirmed)
    #expect(learner.windowsNeedingMeasurement([window]).isEmpty)
    #expect(learner.merging(WindowConstraints(), for: window, application: "com.example.App").minimumSize
        == BTSize(width: 700, height: 500))
    #expect(learner.learnedSizes[sibling] == BTSize(width: 400, height: 300))
    // Dropping the seed too leaves the default floor.
    learner.forgetApplication("com.example.App")
    #expect(learner.merging(WindowConstraints(), for: window, application: "com.example.App").minimumSize
        == WindowConstraints().minimumSize)
}

/// A window is probed once. An application that applies its minimum late
/// gives no measurement, and probing it on every selection would only resize
/// it again and again.
@Test func aProbedWindowIsNotProbedAgainWithoutAMeasurement() {
    var learner = WindowMinimumSizeLearner()
    let late = WindowID(rawValue: "late"), other = WindowID(rawValue: "other")
    #expect(learner.windowsNeedingMeasurement([late, other]) == [late, other])
    learner.recordProbe(of: late)
    #expect(learner.windowsNeedingMeasurement([late, other]) == [other])
    // A window ID that comes back after its window closed is a new window.
    learner.remove(late)
    #expect(learner.windowsNeedingMeasurement([late]) == [late])
}
