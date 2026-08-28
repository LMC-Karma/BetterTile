import Foundation
import Testing
@testable import BetterTileCore

/// A 1920x1080 display with the menu bar and Dock removed, matching the
/// machine the original report came from.
private let bounds = BTRect(x: 0, y: 0, width: 1920, height: 983)

private func partition(_ action: WindowAction) -> BTRect {
    action.partition!.frame(in: bounds)
}

/// macOS insets every tiled window by roughly 7pt per side when "Tiled windows
/// have margins" is on, which is the default.
private func withMacOSMargins(_ rect: BTRect, inset: Double = 7) -> BTRect {
    BTRect(
        x: rect.minX + inset,
        y: rect.minY + inset,
        width: rect.size.width - inset * 2,
        height: rect.size.height - inset * 2
    )
}

// MARK: - The reported failure

/// Two panes split 50/50; the user invokes macOS Window > Move & Resize > Right
/// on the left one. Its far edge lands at the display edge, which the divider
/// fitter used to read as "the divider was dragged to 1920", collapsing the
/// neighbour to its minimum width and producing the reported 90/10 split.
@Test func macOSRightHalfOnATiledWindowIsNotADividerDrag() {
    let change = ExternalWindowChangeClassifier.classify(
        expected: partition(.leftHalf),
        observed: partition(.rightHalf),
        in: bounds
    )
    #expect(change == .snapDestination(.rightHalf))
    #expect(change != .dividerResize)
}

/// Same command with margins left at the macOS default. This is the case a
/// developer is most likely to miss, because the deltas are small enough to
/// look like noise and large enough to defeat a tight tolerance.
@Test func macOSRightHalfIsRecognisedWithMarginsOn() {
    let change = ExternalWindowChangeClassifier.classify(
        expected: partition(.leftHalf),
        observed: withMacOSMargins(partition(.rightHalf)),
        in: bounds
    )
    #expect(change == .snapDestination(.rightHalf))
}

/// Guards the tolerance itself. Reusing `adjacencyTolerance` here would compile,
/// pass every margins-off test, and silently fail for everyone running the
/// macOS default.
@Test func marginedFramesNeedMoreSlackThanTheAdjacencyTolerance() {
    let margined = withMacOSMargins(partition(.rightHalf))
    #expect(ExternalWindowChangeClassifier.matchDestination(margined, in: bounds, tolerance: 6) == nil)
    #expect(ExternalWindowChangeClassifier.matchDestination(margined, in: bounds) == .rightHalf)
}

// MARK: - Every destination macOS offers

@Test(arguments: [
    WindowAction.leftHalf, .rightHalf, .topHalf, .bottomHalf,
    .topLeftQuarter, .topRightQuarter, .bottomLeftQuarter, .bottomRightQuarter,
    .maximize,
])
func everyRecognisedDestinationIsMatchedWithAndWithoutMargins(action: WindowAction) {
    let exact = partition(action)
    #expect(ExternalWindowChangeClassifier.matchDestination(exact, in: bounds) == action)
    #expect(
        ExternalWindowChangeClassifier.matchDestination(withMacOSMargins(exact), in: bounds) == action,
        "\(action) not recognised with macOS margins"
    )
}

/// Filling the screen from a half moves only one edge, so the anchored-edge
/// test alone would call it a divider drag and push the split past the display
/// edge. Destination matching has to take priority for this to come out right.
@Test func fillingTheScreenFromAHalfIsADestinationNotADividerDrag() {
    let change = ExternalWindowChangeClassifier.classify(
        expected: partition(.leftHalf),
        observed: partition(.maximize),
        in: bounds
    )
    #expect(change == .snapDestination(.maximize))
}

// MARK: - Genuine divider work must still reach the fitter

/// The pivot that defines a divider drag: the right edge follows the pointer
/// while the left edge stays anchored.
@Test func draggingASharedEdgeIsStillADividerResize() {
    let change = ExternalWindowChangeClassifier.classify(
        expected: partition(.leftHalf),
        observed: BTRect(x: 0, y: 0, width: 1200, height: 983),
        in: bounds
    )
    #expect(change == .dividerResize)
}

/// A corner drag moves two edges, but one per axis, so each axis still has an
/// anchor.
@Test func aCornerResizeIsStillADividerResize() {
    let change = ExternalWindowChangeClassifier.classify(
        expected: BTRect(x: 0, y: 0, width: 960, height: 500),
        observed: BTRect(x: 0, y: 0, width: 1200, height: 700),
        in: bounds
    )
    #expect(change == .dividerResize)
}

@Test func aSmallEdgeNudgeStaysADividerResize() {
    let change = ExternalWindowChangeClassifier.classify(
        expected: partition(.leftHalf),
        observed: BTRect(x: 0, y: 0, width: 968, height: 983),
        in: bounds
    )
    #expect(change == .dividerResize)
}

// MARK: - Unrecognised movement

/// Dragged by its title bar to somewhere arbitrary: both edges on both axes
/// moved and it matches nothing, so the layout has to re-derive rather than
/// pretend a divider moved.
@Test func aFreeDragIsARelocation() {
    let change = ExternalWindowChangeClassifier.classify(
        expected: partition(.leftHalf),
        observed: BTRect(x: 300, y: 200, width: 960, height: 983),
        in: bounds
    )
    #expect(change == .relocation)
}

@Test func aWindowCarriedWithoutResizingIsARelocation() {
    let change = ExternalWindowChangeClassifier.classify(
        expected: BTRect(x: 0, y: 0, width: 400, height: 400),
        observed: BTRect(x: 700, y: 300, width: 400, height: 400),
        in: bounds
    )
    #expect(change == .relocation)
}

// MARK: - Matching hygiene

@Test func aFrameFarFromEveryDestinationMatchesNothing() {
    #expect(
        ExternalWindowChangeClassifier.matchDestination(
            BTRect(x: 240, y: 180, width: 700, height: 500),
            in: bounds
        ) == nil
    )
}

@Test func degenerateBoundsMatchNothing() {
    #expect(
        ExternalWindowChangeClassifier.matchDestination(
            BTRect(x: 0, y: 0, width: 10, height: 10),
            in: BTRect(x: 0, y: 0, width: 0, height: 0)
        ) == nil
    )
}

/// Thirds and sixths are BetterTile-only. Accepting them would add false
/// matches without matching anything macOS can actually produce.
@Test func thirdsAreNotTreatedAsMacOSDestinations() {
    #expect(ExternalWindowChangeClassifier.matchDestination(partition(.leftThird), in: bounds) == nil)
    #expect(!ExternalWindowChangeClassifier.recognisedDestinations.contains(.leftThird))
}

/// A tolerance wide enough to make a half and a quarter both plausible must
/// resolve to the nearer one rather than whichever was listed first.
@Test func theNearerDestinationWinsWhenToleranceIsWide() {
    let nearlyLeftHalf = BTRect(x: 0, y: 0, width: 940, height: 983)
    #expect(
        ExternalWindowChangeClassifier.matchDestination(nearlyLeftHalf, in: bounds, tolerance: 600)
            == .leftHalf
    )
}

// MARK: - The shared partition table

/// `targetFrame` and destination matching must not drift apart; they now read
/// the same table.
@Test(arguments: [
    WindowAction.leftHalf, .rightHalf, .topHalf, .bottomHalf,
    .topLeftQuarter, .topRightQuarter, .bottomLeftQuarter, .bottomRightQuarter,
])
func targetFrameAgreesWithThePartitionTable(action: WindowAction) {
    let display = DisplaySnapshot(id: DisplayID(rawValue: "d"), frame: bounds, visibleFrame: bounds)
    let window = WindowSnapshot(
        id: WindowID(rawValue: "w"),
        processIdentifier: 1,
        frame: BTRect(x: 0, y: 0, width: 400, height: 400),
        displayID: display.id
    )
    let target = StandardActionEngine().targetFrame(for: action, window: window, display: display)
    #expect(target == partition(action))
}

/// A divider dragged from well away onto the exact midpoint matches a half on
/// every edge, but it is still a divider drag: the left edge never moved. The
/// anchored edge has to win, or the layout gets rebuilt around a destination the
/// user never asked for.
@Test func aDividerDraggedOntoTheMidpointIsStillADividerResize() {
    let change = ExternalWindowChangeClassifier.classify(
        expected: BTRect(x: 0, y: 0, width: 700, height: 983),
        observed: partition(.leftHalf),
        in: bounds
    )
    #expect(change == .dividerResize)
}

// MARK: - Multi-pane layouts must not be restructured by a divider drag

/// Three equal columns. Dragging the first divider rightwards towards the middle
/// leaves column one looking exactly like a left half — same origin, same full
/// height, right edge within tolerance of the midpoint.
///
/// Routing that to the planner would take the `.leftHalf` root path, which drops
/// the source from the tree and reinserts it at the root, collapsing the two
/// columns the user never touched into the other half. The anchored left edge is
/// what keeps this on the divider path.
@Test(arguments: [940.0, 950.0, 958.0, 960.0, 972.0])
func aDividerDragInAThreeColumnSplitIsNeverASnapDestination(width: Double) {
    let a = WindowID(rawValue: "A"), b = WindowID(rawValue: "B"), c = WindowID(rawValue: "C")
    let state = BentoLayoutState(
        root: .partition(BentoPartition(
            axis: .vertical, weight: 1.0 / 3,
            first: .leaf(a),
            second: .partition(BentoPartition(axis: .vertical, weight: 0.5, first: .leaf(b), second: .leaf(c)))
        )),
        metrics: .gapless
    )
    let expected = Dictionary(
        uniqueKeysWithValues: state.placements(in: bounds).map { ($0.windowID, $0.frame) }
    )
    let change = ExternalWindowChangeClassifier.classify(
        expected: expected[a]!,
        observed: BTRect(x: 0, y: 0, width: width, height: bounds.size.height),
        in: bounds
    )
    #expect(change == .dividerResize, "a \(width)pt first column was treated as a snap destination")
}

/// The same column filling the display is unambiguous, because no leaf in a
/// multi-leaf tree can span the whole bounds by a weight change.
@Test func fillingTheDisplayFromAColumnIsStillRecognised() {
    let change = ExternalWindowChangeClassifier.classify(
        expected: BTRect(x: 0, y: 0, width: 640, height: 983),
        observed: bounds,
        in: bounds
    )
    #expect(change == .snapDestination(.maximize))
}

// MARK: - End to end: the reported 90/10 split

private func twoPaneState(_ a: WindowID, _ b: WindowID) -> BentoLayoutState {
    BentoLayoutState(
        root: .partition(BentoPartition(axis: .vertical, weight: 0.5, first: .leaf(a), second: .leaf(b))),
        metrics: .gapless
    )
}

private let minimums: [WindowID: WindowConstraints] = [
    WindowID(rawValue: "A"): WindowConstraints(minimumSize: BTSize(width: 120, height: 80)),
    WindowID(rawValue: "B"): WindowConstraints(minimumSize: BTSize(width: 120, height: 80)),
]

/// What the old code did, kept as an executable record of the defect. The
/// fitter reads the relocated window's new far edge as a divider position and
/// drives the split to the display edge, leaving the neighbour at its minimum
/// width. If the classifier is ever removed, the test above goes red and this
/// one explains why.
@Test func theDividerFitterAloneStillCollapsesTheNeighbour() throws {
    let a = WindowID(rawValue: "A")
    let b = WindowID(rawValue: "B")
    let state = twoPaneState(a, b)
    let observed: [WindowID: BTRect] = [a: partition(.rightHalf), b: partition(.rightHalf)]

    let fitted = try #require(
        BentoLayoutFitter(tolerance: 6).fit(
            state: state,
            currentFrames: observed,
            changedWindowIDs: [a],
            in: bounds,
            constraints: minimums
        )
    )
    let widths = Dictionary(uniqueKeysWithValues: fitted.placements.map { ($0.windowID, $0.frame.size.width) })
    #expect(widths[b] == 120, "the neighbour collapses to its minimum width")
    #expect(widths[a] == 1800)
}

/// The fix, end to end: classification routes the same observation to the
/// planner a BetterTile shortcut uses, which swaps the panes and leaves both at
/// half width.
@Test(arguments: [false, true])
func macOSRightHalfSwapsThePanesInsteadOfCollapsingThem(margins: Bool) throws {
    let a = WindowID(rawValue: "A")
    let b = WindowID(rawValue: "B")
    let state = twoPaneState(a, b)
    let baseline = Dictionary(uniqueKeysWithValues: state.placements(in: bounds).map { ($0.windowID, $0.frame) })
    let landed = margins ? withMacOSMargins(partition(.rightHalf)) : partition(.rightHalf)

    let change = ExternalWindowChangeClassifier.classify(
        expected: baseline[a]!,
        observed: landed,
        in: bounds
    )
    let action = try #require({ if case let .snapDestination(action) = change { action } else { nil } }())
    #expect(action == .rightHalf)

    let plan = try #require(
        BentoDropPlanner().plan(
            intent: .snap(action: action, frame: action.partition!.frame(in: bounds)),
            sourceWindowID: a,
            state: state,
            baselineFrames: baseline,
            constraints: minimums,
            contextWindowIDs: [a, b],
            in: bounds
        )
    )
    let placed = Dictionary(uniqueKeysWithValues: plan.placements.map { ($0.windowID, $0.frame) })
    #expect(placed[a] == partition(.rightHalf), "the moved window takes the right pane")
    #expect(placed[b] == partition(.leftHalf), "its neighbour takes the left pane")
    #expect(placed[b]?.size.width != 120, "nothing collapses to a minimum-width sliver")
}

// MARK: - Routing a batch of classified changes

private let w1 = WindowID(rawValue: "w1")
private let w2 = WindowID(rawValue: "w2")
private let w3 = WindowID(rawValue: "w3")

@Test func anEmptyFlushIsNotActionable() {
    #expect(ExternalChangeRouter.route([:]) == .none)
}

@Test func dividerChangesAreCollectedForTheFitter() {
    let route = ExternalChangeRouter.route([w1: .dividerResize, w2: .dividerResize])
    #expect(route == .fitDividers([w1, w2]))
}

@Test func aRecognisedDestinationTakesPriorityOverDividerWork() {
    let route = ExternalChangeRouter.route([w1: .dividerResize, w2: .snapDestination(.rightHalf)])
    #expect(route == .snap(windowID: w2, action: .rightHalf))
}

@Test func aRecognisedDestinationTakesPriorityOverARelocation() {
    let route = ExternalChangeRouter.route([w1: .relocation, w2: .snapDestination(.topLeftQuarter)])
    #expect(route == .snap(windowID: w2, action: .topLeftQuarter))
}

/// A relocation with no recognised destination is usually a window mid-drag,
/// which its own gesture will settle. A divider change is actionable now, so it
/// wins rather than triggering a restore that would fight the drag.
@Test func dividerWorkWinsOverAnUnrecognisedRelocation() {
    let route = ExternalChangeRouter.route([w1: .relocation, w2: .dividerResize])
    #expect(route == .fitDividers([w2]))
}

@Test func aRelocationAloneRestoresTheLayout() {
    #expect(ExternalChangeRouter.route([w1: .relocation]) == .restoreLayout)
}

/// Two snaps in one flush must not depend on dictionary ordering.
@Test func competingSnapsResolveDeterministically() {
    let changes: [WindowID: ExternalWindowChange] = [
        w3: .snapDestination(.leftHalf),
        w1: .snapDestination(.rightHalf),
        w2: .snapDestination(.maximize),
    ]
    for _ in 0..<50 {
        #expect(ExternalChangeRouter.route(changes) == .snap(windowID: w1, action: .rightHalf))
    }
}

// MARK: - macOS Window > Fill

/// Fill is a focus plan, not a partition. The classifier recognises it, the
/// router sends it to the snap path, and the planner asks for the peers it
/// covers to be minimized. Anything applying that plan has to honour the
/// minimize list, or the filled window sits on top of peers the tree still
/// calls tiled.
@Test func macOSFillRoutesToAFocusPlanThatMinimizesItsPeers() {
    let a = WindowID(rawValue: "a")
    let b = WindowID(rawValue: "b")

    var state = BentoLayoutState()
    state.insert(a, in: bounds)
    state.insert(b, in: bounds)
    let tiled = Dictionary(
        uniqueKeysWithValues: state.placements(in: bounds).map { ($0.windowID, $0.frame) }
    )

    guard let tiledA = tiled[a] else {
        Issue.record("the layout did not place the first window")
        return
    }
    let change = ExternalWindowChangeClassifier.classify(
        expected: tiledA,
        observed: bounds,
        in: bounds,
        edgeTolerance: 6
    )
    #expect(change == ExternalWindowChange.snapDestination(.maximize))
    #expect(ExternalChangeRouter.route([a: change]) == .snap(windowID: a, action: .maximize))

    let plan = BentoDropPlanner().plan(
        intent: .snap(action: .maximize, frame: bounds),
        sourceWindowID: a,
        state: state,
        baselineFrames: tiled,
        constraints: [:],
        contextWindowIDs: [a, b],
        in: bounds
    )
    #expect(plan?.isFocusDrop == true)
    #expect(plan?.minimizedWindowIDs == [b])
    #expect(plan?.excludedWindowIDs == [b])
    #expect(plan?.placements.count == 1)
}
