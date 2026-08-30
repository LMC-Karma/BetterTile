import Foundation
import Testing
@testable import BetterTileCore

private let dropDisplayID = DisplayID(rawValue: "drop-display")
private let dropBounds = BTRect(x: 0, y: 24, width: 1200, height: 876)

@Test func excludedApplicationPartitionShortcutsBypassBento() {
    #expect(BentoDropPlanner.handlesShortcut(.leftHalf, in: .bento, sourceRule: .manageNormally))
    #expect(!BentoDropPlanner.handlesShortcut(.leftHalf, in: .bento, sourceRule: .excludeFromBento))
    #expect(!BentoDropPlanner.handlesShortcut(.leftHalf, in: .manual, sourceRule: .manageNormally))
    #expect(!BentoDropPlanner.handlesShortcut(.maximize, in: .bento, sourceRule: .manageNormally))
}

@Test func topRightQuarterDropKeepsLeftHalfAndBottomRightVacant() throws {
    let source = WindowID(rawValue: "source")
    let other = WindowID(rawValue: "other")
    let state = BentoLayoutState(root: .partition(BentoPartition(
        axis: .vertical,
        first: .leaf(source),
        second: .leaf(other)
    )))
    let frames = Dictionary(uniqueKeysWithValues: state.placements(in: dropBounds).map { ($0.windowID, $0.frame) })
    let target = NormalizedRect(x: 0.5, y: 0, width: 0.5, height: 0.5).frame(in: dropBounds)
    let plan = try #require(BentoDropPlanner().plan(
        intent: .snap(action: .topRightQuarter, frame: target),
        sourceWindowID: source,
        state: state,
        baselineFrames: frames,
        constraints: defaultConstraints([source, other]),
        contextWindowIDs: [source, other],
        in: dropBounds
    ))
    let placements = Dictionary(uniqueKeysWithValues: plan.placements.map { ($0.windowID, $0.frame) })

    #expect(placements[source] == target)
    #expect(placements[other] == NormalizedRect(x: 0, y: 0, width: 0.5, height: 1).frame(in: dropBounds))
    #expect(Array(plan.state.vacantFrames(in: dropBounds).values) == [
        NormalizedRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5).frame(in: dropBounds),
    ])
}

@Test func partitionShortcutsReplaceVacanciesFromEarlierZones() throws {
    let left = WindowID(rawValue: "left")
    let right = WindowID(rawValue: "right")
    let constraints = defaultConstraints([left, right])
    let planner = BentoDropPlanner()
    let halves = BentoLayoutState(root: .partition(BentoPartition(
        axis: .vertical,
        children: [.leaf(left), .leaf(right)]
    )))

    func frames(_ state: BentoLayoutState) -> [WindowID: BTRect] {
        Dictionary(uniqueKeysWithValues: state.placements(in: dropBounds).map { ($0.windowID, $0.frame) })
    }

    func plan(_ action: WindowAction, from state: BentoLayoutState) throws -> BentoDropPlan {
        try #require(planner.plan(
            intent: .snap(action: action, frame: action.partition!.frame(in: dropBounds)),
            sourceWindowID: right,
            state: state,
            baselineFrames: frames(state),
            constraints: constraints,
            contextWindowIDs: [left, right],
            in: dropBounds
        ))
    }

    let centerThird = try plan(.centerThird, from: halves).state
    #expect(centerThird.vacantFrames(in: dropBounds).count == 1)

    for action in BentoDropPlanner.partitionActions {
        let fresh = try plan(action, from: halves)
        let replanned = try plan(action, from: centerThird)
        #expect(
            replanned.state.vacantFrames(in: dropBounds).count
                == fresh.state.vacantFrames(in: dropBounds).count,
            "\(action.rawValue) carried a vacancy from the earlier center-third layout"
        )
    }

    let leftHalf = try plan(.leftHalf, from: centerThird).state
    let rightHalf = try plan(.rightHalf, from: leftHalf).state
    #expect(rightHalf.vacantFrames(in: dropBounds).isEmpty)
    #expect(frames(rightHalf)[left] == WindowAction.leftHalf.partition!.frame(in: dropBounds))
    #expect(frames(rightHalf)[right] == WindowAction.rightHalf.partition!.frame(in: dropBounds))
}

@Test func everyPartitionDropKeepsTheSourceInItsExactZone() throws {
    let source = WindowID(rawValue: "source")
    let other = WindowID(rawValue: "other")
    let third = WindowID(rawValue: "third")
    var state = BentoLayoutState()
    for id in [source, other, third] { state.insert(id, in: dropBounds) }
    let frames = Dictionary(uniqueKeysWithValues: state.placements(in: dropBounds).map { ($0.windowID, $0.frame) })
    let display = DisplaySnapshot(id: dropDisplayID, frame: dropBounds, visibleFrame: dropBounds)
    let sourceWindow = WindowSnapshot(id: source, processIdentifier: 1, frame: frames[source]!, displayID: dropDisplayID)

    for action in BentoDropPlanner.partitionActions {
        let target = try #require(StandardActionEngine().targetFrame(for: action, window: sourceWindow, display: display))
        let plan = try #require(BentoDropPlanner().plan(
            intent: .snap(action: action, frame: target),
            sourceWindowID: source,
            state: state,
            baselineFrames: frames,
            constraints: defaultConstraints([source, other, third]),
            contextWindowIDs: [source, other, third],
            in: dropBounds
        ))
        #expect(plan.placements.first(where: { $0.windowID == source })?.frame
            .approximatelyEquals(target, tolerance: 0.001) == true)
        let occupied = plan.placements.map(\.frame) + Array(plan.state.vacantFrames(in: dropBounds).values)
        #expect(abs(occupied.reduce(0) { $0 + $1.area } - dropBounds.area) < 0.01)
        for first in occupied.indices {
            for second in occupied.indices where second > first {
                #expect((occupied[first].intersection(occupied[second])?.area ?? 0) < 0.001)
            }
        }
    }
}

@Test func everyShortcutPartitionWorksWhenBentoUsesPaneGaps() throws {
    let source = WindowID(rawValue: "source")
    let other = WindowID(rawValue: "other")
    let third = WindowID(rawValue: "third")
    var state = BentoLayoutState(metrics: BentoLayoutMetrics(paneGap: 8))
    for id in [source, other, third] { state.insert(id, in: dropBounds) }
    let frames = Dictionary(uniqueKeysWithValues: state.placements(in: dropBounds).map { ($0.windowID, $0.frame) })
    let display = DisplaySnapshot(id: dropDisplayID, frame: dropBounds, visibleFrame: dropBounds)
    let sourceWindow = WindowSnapshot(id: source, processIdentifier: 1, frame: frames[source]!, displayID: dropDisplayID)

    for action in BentoDropPlanner.partitionActions {
        let target = try #require(StandardActionEngine().targetFrame(for: action, window: sourceWindow, display: display))
        let plan = try #require(BentoDropPlanner().plan(
            intent: .snap(action: action, frame: target),
            sourceWindowID: source,
            state: state,
            baselineFrames: frames,
            constraints: defaultConstraints([source, other, third]),
            contextWindowIDs: [source, other, third],
            in: dropBounds
        ), "Expected \(action.rawValue) to produce a gapped Bento layout")
        #expect(plan.placements.allSatisfy {
            $0.frame.minX >= dropBounds.minX
                && $0.frame.maxX <= dropBounds.maxX
                && $0.frame.minY >= dropBounds.minY
                && $0.frame.maxY <= dropBounds.maxY
        })
    }
}

@Test func aNewWindowFillsAVacantSlotWithoutRebuildingTheDrop() throws {
    let source = WindowID(rawValue: "source")
    let other = WindowID(rawValue: "other")
    let newcomer = WindowID(rawValue: "newcomer")
    let state = BentoLayoutState(root: .partition(BentoPartition(axis: .vertical, first: .leaf(source), second: .leaf(other))))
    let frames = Dictionary(uniqueKeysWithValues: state.placements(in: dropBounds).map { ($0.windowID, $0.frame) })
    let target = NormalizedRect(x: 0.5, y: 0, width: 0.5, height: 0.5).frame(in: dropBounds)
    var planned = try #require(BentoDropPlanner().plan(
        intent: .snap(action: .topRightQuarter, frame: target), sourceWindowID: source,
        state: state, baselineFrames: frames, constraints: defaultConstraints([source, other]),
        contextWindowIDs: [source, other], in: dropBounds
    )).state
    let vacant = try #require(planned.vacantFrames(in: dropBounds).values.first)

    planned.insert(newcomer, in: dropBounds)

    #expect(planned.vacantFrames(in: dropBounds).isEmpty)
    #expect(planned.placements(in: dropBounds).first(where: { $0.windowID == newcomer })?.frame == vacant)
}

@Test func focusDropMinimizesEveryOtherContextWindow() throws {
    let source = WindowID(rawValue: "source")
    let other = WindowID(rawValue: "other")
    let floating = WindowID(rawValue: "floating")
    let state = BentoLayoutState(
        root: .partition(BentoPartition(axis: .vertical, first: .leaf(source), second: .leaf(other))),
        floatingWindowIDs: [floating]
    )
    var frames = Dictionary(uniqueKeysWithValues: state.placements(in: dropBounds).map { ($0.windowID, $0.frame) })
    frames[floating] = BTRect(x: 200, y: 200, width: 500, height: 400)
    let target = dropBounds.insetBy(dx: 24, dy: 24)
    let plan = try #require(BentoDropPlanner().plan(
        intent: .snap(action: .almostMaximize, frame: target), sourceWindowID: source,
        state: state, baselineFrames: frames, constraints: defaultConstraints([source, other, floating]),
        contextWindowIDs: [source, other, floating], in: dropBounds
    ))

    #expect(plan.placements == [Placement(windowID: source, frame: target)])
    #expect(plan.minimizedWindowIDs == [other, floating])
    #expect(plan.excludedWindowIDs == [other, floating])
    #expect(plan.state.root == state.root)
}

@Test func impossiblePartitionRestoresInsteadOfViolatingMinimumSizes() {
    let source = WindowID(rawValue: "source")
    let other = WindowID(rawValue: "other")
    let state = BentoLayoutState(root: .partition(BentoPartition(axis: .vertical, first: .leaf(source), second: .leaf(other))))
    let frames = Dictionary(uniqueKeysWithValues: state.placements(in: dropBounds).map { ($0.windowID, $0.frame) })
    let target = NormalizedRect(x: 0.5, y: 0, width: 0.5, height: 0.5).frame(in: dropBounds)
    let constraints = [
        source: WindowConstraints(),
        other: WindowConstraints(minimumSize: BTSize(width: 700, height: 800)),
    ]

    #expect(BentoDropPlanner().plan(
        intent: .snap(action: .topRightQuarter, frame: target), sourceWindowID: source,
        state: state, baselineFrames: frames, constraints: constraints,
        contextWindowIDs: [source, other], in: dropBounds
    ) == nil)
}

@Test func untrackedSeventhWindowCannotEnterBentoThroughAPaneDrop() {
    let source = WindowID(rawValue: "seventh")
    let ids = (0..<6).map { WindowID(rawValue: "window-\($0)") }
    var state = BentoLayoutState()
    for id in ids { state.insert(id, in: dropBounds) }
    var frames = Dictionary(uniqueKeysWithValues: state.placements(in: dropBounds).map { ($0.windowID, $0.frame) })
    frames[source] = BTRect(x: 100, y: 100, width: 400, height: 300)

    #expect(BentoDropPlanner().plan(
        intent: .pane(ids[0]), sourceWindowID: source, state: state,
        baselineFrames: frames, constraints: defaultConstraints(ids + [source]),
        contextWindowIDs: Set(ids + [source]), in: dropBounds
    ) == nil)
}

@Test func floatingSeventhWindowCanExchangeWithAPaneOccupant() throws {
    let source = WindowID(rawValue: "seventh")
    let ids = (0..<6).map { WindowID(rawValue: "window-\($0)") }
    var state = BentoLayoutState()
    for id in ids { state.insert(id, in: dropBounds) }
    state.setFloating(true, windowID: source)
    let originalFrames = Dictionary(
        uniqueKeysWithValues: state.placements(in: dropBounds).map { ($0.windowID, $0.frame) }
    )
    var baselineFrames = originalFrames
    baselineFrames[source] = BTRect(x: 100, y: 100, width: 400, height: 300)

    for intent in [
        BentoDropIntent.pane(ids[0]),
        .insert(targetWindowID: ids[0], edge: .left),
    ] {
        let plan = try #require(BentoDropPlanner().plan(
            intent: intent, sourceWindowID: source, state: state,
            baselineFrames: baselineFrames, constraints: defaultConstraints(ids + [source]),
            contextWindowIDs: Set(ids + [source]), in: dropBounds
        ))

        #expect(plan.state.root?.windowIDs.contains(source) == true)
        #expect(plan.state.root?.windowIDs.contains(ids[0]) != true)
        #expect(plan.state.floatingWindowIDs == [ids[0]])
        #expect(plan.state.root?.windowIDs.count == 6)
        #expect(plan.placements.first(where: { $0.windowID == source })?.frame == originalFrames[ids[0]])
        #expect(plan.placements.first(where: { $0.windowID == ids[0] })?.frame == baselineFrames[source])
        #expect(Set(plan.placements.map(\.windowID)) == Set(ids + [source]))
    }
}

@Test func restoredWindowReleasedWithoutATargetAutomaticallyRejoinsBento() throws {
    let existing = WindowID(rawValue: "existing")
    let restored = WindowID(rawValue: "restored")
    let state = BentoLayoutState(root: .leaf(existing), floatingWindowIDs: [restored])
    let plan = try #require(BentoDropPlanner().plan(
        intent: .automatic,
        sourceWindowID: restored,
        state: state,
        baselineFrames: [
            existing: dropBounds,
            restored: BTRect(x: 300, y: 200, width: 500, height: 400),
        ],
        constraints: defaultConstraints([existing, restored]),
        contextWindowIDs: [existing, restored],
        in: dropBounds
    ))

    #expect(Set(plan.state.root?.windowIDs ?? []) == [existing, restored])
    #expect(!plan.state.floatingWindowIDs.contains(restored))
    #expect(plan.placements.count == 2)
    #expect(plan.placements.allSatisfy {
        $0.frame.minX >= dropBounds.minX && $0.frame.maxX <= dropBounds.maxX
            && $0.frame.minY >= dropBounds.minY && $0.frame.maxY <= dropBounds.maxY
    })
}

@Test func edgeInsertionRebalancesAnEqualPartition() throws {
    let a = WindowID(rawValue: "a")
    let b = WindowID(rawValue: "b")
    let c = WindowID(rawValue: "c")
    let state = BentoLayoutState(root: .partition(BentoPartition(
        axis: .vertical,
        children: [.leaf(a), .leaf(b)]
    )))
    var frames = Dictionary(uniqueKeysWithValues: state.placements(in: dropBounds).map { ($0.windowID, $0.frame) })
    frames[c] = BTRect(x: 200, y: 200, width: 400, height: 300)

    let plan = try #require(BentoDropPlanner().plan(
        intent: .insert(targetWindowID: b, edge: .right),
        sourceWindowID: c,
        state: state,
        baselineFrames: frames,
        constraints: defaultConstraints([a, b, c]),
        contextWindowIDs: [a, b, c],
        in: dropBounds
    ))
    guard case let .partition(root) = plan.state.root else {
        Issue.record("Expected one normalized vertical partition")
        return
    }

    #expect(root.children.flatMap(\.windowIDs) == [a, b, c])
    #expect(root.ratios.allSatisfy { abs($0 - 1.0 / 3.0) < 0.000_001 })
}

@Test func edgeInsertionSplitsOnlyTheTargetShareInACustomPartition() throws {
    let a = WindowID(rawValue: "a")
    let b = WindowID(rawValue: "b")
    let c = WindowID(rawValue: "c")
    let state = BentoLayoutState(root: .partition(BentoPartition(
        axis: .vertical,
        children: [.leaf(a), .leaf(b)],
        ratios: [0.6, 0.4]
    )))
    var frames = Dictionary(uniqueKeysWithValues: state.placements(in: dropBounds).map { ($0.windowID, $0.frame) })
    frames[c] = BTRect(x: 200, y: 200, width: 400, height: 300)

    let plan = try #require(BentoDropPlanner().plan(
        intent: .insert(targetWindowID: b, edge: .left),
        sourceWindowID: c,
        state: state,
        baselineFrames: frames,
        constraints: defaultConstraints([a, b, c]),
        contextWindowIDs: [a, b, c],
        in: dropBounds
    ))
    guard case let .partition(root) = plan.state.root else {
        Issue.record("Expected one normalized vertical partition")
        return
    }

    #expect(root.children.flatMap(\.windowIDs) == [a, c, b])
    #expect(abs(root.ratios[0] - 0.6) < 0.000_001)
    #expect(abs(root.ratios[1] - 0.2) < 0.000_001)
    #expect(abs(root.ratios[2] - 0.2) < 0.000_001)
}

@Test func samePartitionReorderingPreservesCustomPaneShares() throws {
    let a = WindowID(rawValue: "a")
    let b = WindowID(rawValue: "b")
    let c = WindowID(rawValue: "c")
    let state = BentoLayoutState(root: .partition(BentoPartition(
        axis: .vertical,
        children: [.leaf(a), .leaf(b), .leaf(c)],
        ratios: [0.5, 0.3, 0.2]
    )))
    let frames = Dictionary(uniqueKeysWithValues: state.placements(in: dropBounds).map { ($0.windowID, $0.frame) })

    let plan = try #require(BentoDropPlanner().plan(
        intent: .insert(targetWindowID: a, edge: .left),
        sourceWindowID: c,
        state: state,
        baselineFrames: frames,
        constraints: defaultConstraints([a, b, c]),
        contextWindowIDs: [a, b, c],
        in: dropBounds
    ))
    guard case let .partition(root) = plan.state.root else {
        Issue.record("Expected one normalized vertical partition")
        return
    }

    #expect(root.children.flatMap(\.windowIDs) == [c, a, b])
    #expect(abs(root.ratios[0] - 0.2) < 0.000_001)
    #expect(abs(root.ratios[1] - 0.5) < 0.000_001)
    #expect(abs(root.ratios[2] - 0.3) < 0.000_001)
}

@Test func edgeDropsCanBuildTheFivePaneReferenceLayout() throws {
    let ids = ["a", "b", "c", "d", "e"].map { WindowID(rawValue: $0) }
    var state = BentoLayoutState(root: .leaf(ids[0]))
    state = try plannedInsertion(ids[1], beside: ids[0], edge: .right, state: state, allIDs: ids)
    state = try plannedInsertion(ids[2], beside: ids[1], edge: .bottom, state: state, allIDs: ids)
    state = try plannedInsertion(ids[3], beside: ids[0], edge: .right, state: state, allIDs: ids)
    state = try plannedInsertion(ids[4], beside: ids[3], edge: .bottom, state: state, allIDs: ids)

    guard case let .partition(root) = state.root else {
        Issue.record("Expected a vertical root partition")
        return
    }
    #expect(root.axis == .vertical)
    #expect(root.ratios.allSatisfy { abs($0 - 1.0 / 3.0) < 0.000_001 })
    #expect(root.children[0].windowIDs == [ids[0]])
    #expect(root.children[1].windowIDs == [ids[3], ids[4]])
    #expect(root.children[2].windowIDs == [ids[1], ids[2]])
    for child in root.children.dropFirst() {
        guard case let .partition(stack) = child else {
            Issue.record("Expected two stacked columns")
            return
        }
        #expect(stack.axis == .horizontal)
        #expect(stack.ratios == [0.5, 0.5])
    }
}

@Test func edgeDropsCanBuildTwoTallPanesAndAThreeWindowStack() throws {
    let ids = ["a", "b", "c", "d", "e"].map { WindowID(rawValue: $0) }
    var state = BentoLayoutState(root: .leaf(ids[0]))
    state = try plannedInsertion(ids[1], beside: ids[0], edge: .right, state: state, allIDs: ids)
    state = try plannedInsertion(ids[2], beside: ids[1], edge: .right, state: state, allIDs: ids)
    state = try plannedInsertion(ids[3], beside: ids[2], edge: .bottom, state: state, allIDs: ids)
    state = try plannedInsertion(ids[4], beside: ids[3], edge: .bottom, state: state, allIDs: ids)

    guard case let .partition(root) = state.root,
          case let .partition(stack) = root.children[2]
    else {
        Issue.record("Expected two tall panes and one stacked column")
        return
    }
    #expect(root.axis == .vertical)
    #expect(root.children[0].windowIDs == [ids[0]])
    #expect(root.children[1].windowIDs == [ids[1]])
    #expect(stack.axis == .horizontal)
    #expect(stack.children.flatMap(\.windowIDs) == [ids[2], ids[3], ids[4]])
    #expect(stack.ratios.allSatisfy { abs($0 - 1.0 / 3.0) < 0.000_001 })
}

@Test func perpendicularEdgeDropsPreserveAWeightedPrimaryColumn() throws {
    let ids = ["a", "b", "c", "d"].map { WindowID(rawValue: $0) }
    var state = BentoLayoutState(root: .partition(BentoPartition(
        axis: .vertical,
        children: [.leaf(ids[0]), .leaf(ids[1])],
        ratios: [2.0 / 3.0, 1.0 / 3.0]
    )))
    state = try plannedInsertion(ids[2], beside: ids[1], edge: .bottom, state: state, allIDs: ids)
    state = try plannedInsertion(ids[3], beside: ids[2], edge: .bottom, state: state, allIDs: ids)

    guard case let .partition(root) = state.root,
          case let .partition(stack) = root.children[1]
    else {
        Issue.record("Expected a weighted primary column and a three-pane stack")
        return
    }
    #expect(abs(root.ratios[0] - 2.0 / 3.0) < 0.000_001)
    #expect(abs(root.ratios[1] - 1.0 / 3.0) < 0.000_001)
    #expect(stack.children.flatMap(\.windowIDs) == [ids[1], ids[2], ids[3]])
    #expect(stack.ratios.allSatisfy { abs($0 - 1.0 / 3.0) < 0.000_001 })
}

@Test func impossiblePaneEdgeInsertionLeavesTheOriginalStateUntouched() {
    let a = WindowID(rawValue: "a")
    let b = WindowID(rawValue: "b")
    let c = WindowID(rawValue: "c")
    let state = BentoLayoutState(root: .partition(BentoPartition(
        axis: .vertical,
        children: [.leaf(a), .leaf(b)]
    )))
    var frames = Dictionary(uniqueKeysWithValues: state.placements(in: dropBounds).map { ($0.windowID, $0.frame) })
    frames[c] = BTRect(x: 200, y: 200, width: 400, height: 300)

    #expect(BentoDropPlanner().plan(
        intent: .insert(targetWindowID: b, edge: .right),
        sourceWindowID: c,
        state: state,
        baselineFrames: frames,
        constraints: [
            a: WindowConstraints(minimumSize: BTSize(width: 500, height: 100)),
            b: WindowConstraints(minimumSize: BTSize(width: 500, height: 100)),
            c: WindowConstraints(minimumSize: BTSize(width: 500, height: 100)),
        ],
        contextWindowIDs: [a, b, c],
        in: dropBounds
    ) == nil)
    #expect(state.root?.windowIDs == [a, b])
}

private func plannedInsertion(
    _ source: WindowID,
    beside target: WindowID,
    edge: BentoPaneDropPosition,
    state: BentoLayoutState,
    allIDs: [WindowID]
) throws -> BentoLayoutState {
    var frames = Dictionary(uniqueKeysWithValues: state.placements(in: dropBounds).map { ($0.windowID, $0.frame) })
    frames[source] = BTRect(x: 200, y: 200, width: 400, height: 300)
    return try #require(BentoDropPlanner().plan(
        intent: .insert(targetWindowID: target, edge: edge),
        sourceWindowID: source,
        state: state,
        baselineFrames: frames,
        constraints: defaultConstraints(allIDs),
        contextWindowIDs: Set(allIDs),
        in: dropBounds
    )).state
}

private func defaultConstraints(_ ids: [WindowID]) -> [WindowID: WindowConstraints] {
    Dictionary(uniqueKeysWithValues: ids.map { ($0, WindowConstraints()) })
}
