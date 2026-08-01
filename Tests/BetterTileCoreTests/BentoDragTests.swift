import Testing
@testable import BetterTileCore

private let dragDisplayID = DisplayID(rawValue: "drag-display")
private let dragBounds = BTRect(x: 80, y: 24, width: 1120, height: 776)

@Test func bentoPaneDropPositionUsesAdaptiveEdgesAndKeepsAUsableCenter() {
    let regular = BTRect(x: 100, y: 100, width: 1000, height: 600)
    #expect(BentoPaneDropPosition.resolve(BTPoint(x: 249, y: 400), in: regular) == .left)
    #expect(BentoPaneDropPosition.resolve(BTPoint(x: 251, y: 400), in: regular) == .center)
    #expect(BentoPaneDropPosition.resolve(BTPoint(x: 600, y: 189), in: regular) == .top)
    #expect(BentoPaneDropPosition.resolve(BTPoint(x: 600, y: 191), in: regular) == .center)
    #expect(BentoPaneDropPosition.resolve(
        BTPoint(x: 279, y: 400),
        in: regular,
        edgeFraction: 0.2
    ) == .left)

    let small = BTRect(x: 0, y: 0, width: 80, height: 60)
    #expect(BentoPaneDropPosition.resolve(BTPoint(x: 17, y: 30), in: small) == .left)
    #expect(BentoPaneDropPosition.resolve(BTPoint(x: 40, y: 30), in: small) == .center)
}

@Test func bentoPaneDropPositionRetainsThePreviousZoneAcrossBoundaryJitter() {
    let frame = BTRect(x: 0, y: 0, width: 1000, height: 600)

    #expect(BentoPaneDropPosition.resolve(
        BTPoint(x: 158, y: 300),
        in: frame,
        retaining: .left
    ) == .left)
    #expect(BentoPaneDropPosition.resolve(
        BTPoint(x: 164, y: 300),
        in: frame,
        retaining: .center
    ) == .center)
}

@Test func bentoPaneEdgeDropArmsImmediatelyWhenTheCallerUsesNoDwell() {
    let target = WindowID(rawValue: "target")
    var hover = BentoDropHoverState()
    hover.observe(
        BentoHoverCandidate(displayID: dragDisplayID, targetWindowID: target, position: .bottom),
        at: 10
    )

    #expect(hover.outcome(
        at: 10,
        delay: 0,
        snapTarget: nil
    ) == .insert(targetWindowID: target, edge: .bottom))
}

@Test func bentoHoverCompletesOnReleaseWithoutAnotherDragSample() {
    let target = WindowID(rawValue: "target")
    var hover = BentoDropHoverState()
    hover.observe(
        BentoHoverCandidate(displayID: dragDisplayID, targetWindowID: target, position: .center),
        at: 10
    )

    #expect(hover.outcome(
        at: 10.12,
        delay: 0.12,
        snapTarget: nil
    ) == .swap(targetWindowID: target))
}

@Test func bentoHoverPreservesQuickEdgeSnapsButWinsAfterItsDwell() {
    let target = WindowID(rawValue: "target")
    let snap = SnapTarget(
        action: .leftHalf,
        frame: BTRect(x: dragBounds.minX, y: dragBounds.minY, width: dragBounds.size.width / 2, height: dragBounds.size.height)
    )
    var hover = BentoDropHoverState()
    hover.observe(
        BentoHoverCandidate(displayID: dragDisplayID, targetWindowID: target, position: .center),
        at: 10
    )
    #expect(hover.armedCandidate(at: 10.2, delay: 0.12) != nil)
    hover.observe(
        BentoHoverCandidate(displayID: dragDisplayID, targetWindowID: target, position: .center),
        competingSnapTarget: snap,
        at: 10.2
    )

    #expect(hover.outcome(
        at: 10.25,
        delay: 0.12,
        snapTarget: snap
    ) == .snap(action: .leftHalf, frame: snap.frame))
    #expect(hover.outcome(
        at: 10.32,
        delay: 0.12,
        snapTarget: snap
    ) == .swap(targetWindowID: target))
}

@Test func bentoDragSnapshotKeepsTheSourceSlotReservedWhileActualFramesMove() throws {
    let source = WindowID(rawValue: "source")
    let target = WindowID(rawValue: "target")
    let state = BentoLayoutState(root: .branch(BentoBranch(
        axis: .vertical,
        weight: 0.5,
        first: .leaf(source),
        second: .leaf(target)
    )))
    var windows = dragWindows(for: state)
    let session = try #require(BentoDragSession(
        displayID: dragDisplayID,
        sourceWindowID: source,
        state: state,
        windows: windows,
        workArea: dragBounds
    ))
    let reserved = session.sourceReservedFrame

    windows[0].frame = BTRect(x: 5000, y: 5000, width: 300, height: 200)

    #expect(session.sourceReservedFrame == reserved)
    #expect(session.restorePlacement == Placement(windowID: source, frame: reserved))
    #expect(session.originalState == state)
}

@Test func bentoDragSwapUsesTheFrozenTreeAndStaysInsideTheDockAwareWorkArea() throws {
    let source = WindowID(rawValue: "source")
    let target = WindowID(rawValue: "target")
    let third = WindowID(rawValue: "third")
    let state = BentoLayoutState(root: .branch(BentoBranch(
        axis: .vertical,
        weight: 0.6,
        first: .leaf(source),
        second: .branch(BentoBranch(
            axis: .horizontal,
            weight: 0.4,
            first: .leaf(target),
            second: .leaf(third)
        ))
    )))
    let session = try #require(BentoDragSession(
        displayID: dragDisplayID,
        sourceWindowID: source,
        state: state,
        windows: dragWindows(for: state),
        workArea: dragBounds
    ))
    let before = Dictionary(uniqueKeysWithValues: state.placements(in: dragBounds).map { ($0.windowID, $0.frame) })
    let resolution = try #require(BentoDropPlanner().plan(
        intent: .pane(target), sourceWindowID: source, state: session.originalState,
        baselineFrames: session.baselineFrames, constraints: session.constraints,
        contextWindowIDs: session.contextWindowIDs, in: session.workArea
    ))
    let after = Dictionary(uniqueKeysWithValues: resolution.placements.map { ($0.windowID, $0.frame) })

    #expect(after[source] == before[target])
    #expect(after[target] == before[source])
    #expect(after[third] == before[third])
    #expect(resolution.placements.allSatisfy { placement in
        placement.frame.minX >= dragBounds.minX
            && placement.frame.minY >= dragBounds.minY
            && placement.frame.maxX <= dragBounds.maxX
            && placement.frame.maxY <= dragBounds.maxY
    })
}

@Test func bentoDragSwapUsesExactMouseDownFramesWithoutResolvingSizes() throws {
    let source = WindowID(rawValue: "source")
    let target = WindowID(rawValue: "target")
    let state = BentoLayoutState(root: .branch(BentoBranch(
        axis: .vertical,
        weight: 0.5,
        first: .leaf(source),
        second: .leaf(target)
    )))
    let sourceFrame = BTRect(x: 80, y: 24, width: 600, height: 776)
    let targetFrame = BTRect(x: 680, y: 24, width: 520, height: 776)
    let windows = [
        WindowSnapshot(id: source, processIdentifier: 1, frame: sourceFrame, displayID: dragDisplayID),
        WindowSnapshot(id: target, processIdentifier: 2, frame: targetFrame, displayID: dragDisplayID),
    ]
    let session = try #require(BentoDragSession(
        displayID: dragDisplayID,
        sourceWindowID: source,
        state: state,
        windows: windows,
        workArea: dragBounds
    ))
    let resolution = try #require(BentoDropPlanner().plan(
        intent: .pane(target), sourceWindowID: source, state: session.originalState,
        baselineFrames: session.baselineFrames, constraints: session.constraints,
        contextWindowIDs: session.contextWindowIDs, in: session.workArea
    ))
    let frames = Dictionary(uniqueKeysWithValues: resolution.placements.map { ($0.windowID, $0.frame) })

    #expect(session.restorePlacement.frame == sourceFrame)
    #expect(frames[source] == targetFrame)
    #expect(frames[target] == sourceFrame)
}

@Test func bentoDragStillFreezesAnInfeasibleLayoutButRejectsItsSwap() throws {
    let source = WindowID(rawValue: "source")
    let target = WindowID(rawValue: "target")
    let state = BentoLayoutState(root: .branch(BentoBranch(
        axis: .vertical,
        first: .leaf(source),
        second: .leaf(target)
    )))
    let minimum = WindowConstraints(minimumSize: BTSize(width: 700, height: 100))
    let windows = state.placements(in: dragBounds).map { placement in
        WindowSnapshot(
            id: placement.windowID,
            processIdentifier: 1,
            frame: placement.frame,
            displayID: dragDisplayID,
            constraints: minimum
        )
    }

    let session = try #require(BentoDragSession(
        displayID: dragDisplayID,
        sourceWindowID: source,
        state: state,
        windows: windows,
        workArea: dragBounds
    ))
    #expect(session.restorePlacement.frame == windows[0].frame)
    #expect(BentoDropPlanner().plan(
        intent: .pane(target), sourceWindowID: source, state: session.originalState,
        baselineFrames: session.baselineFrames, constraints: session.constraints,
        contextWindowIDs: session.contextWindowIDs, in: session.workArea
    ) == nil)
}

@Test func bentoDragAdaptsOnlyWhenExactSwapFramesViolateMinimumSizes() throws {
    let source = WindowID(rawValue: "source")
    let target = WindowID(rawValue: "target")
    let state = BentoLayoutState(root: .branch(BentoBranch(
        axis: .vertical,
        weight: 0.7,
        first: .leaf(source),
        second: .leaf(target)
    )))
    let frames = Dictionary(uniqueKeysWithValues: state.placements(in: dragBounds).map { ($0.windowID, $0.frame) })
    let plan = try #require(BentoDropPlanner().plan(
        intent: .pane(target),
        sourceWindowID: source,
        state: state,
        baselineFrames: frames,
        constraints: [
            source: WindowConstraints(minimumSize: BTSize(width: 600, height: 100)),
            target: WindowConstraints(minimumSize: BTSize(width: 200, height: 100)),
        ],
        contextWindowIDs: [source, target],
        in: dragBounds
    ))
    let swapped = Dictionary(uniqueKeysWithValues: plan.placements.map { ($0.windowID, $0.frame) })

    #expect(swapped[source]?.size.width == 600)
    #expect(swapped[target]?.size.width == 520)
}

@Test func bentoDragEventBufferDefersFrameAndTopologyEventsUntilDrain() {
    let source = WindowID(rawValue: "source")
    var buffer = BentoDragEventBuffer()
    buffer.record(WindowSystemEvent(kind: .moved, windowID: source, processIdentifier: 1))
    buffer.record(WindowSystemEvent(kind: .resized, windowID: source, processIdentifier: 1))
    buffer.record(WindowSystemEvent(kind: .created, windowID: nil, processIdentifier: 2))
    buffer.record(WindowSystemEvent(kind: .focused, windowID: source, processIdentifier: 1))

    #expect(buffer.frameEventWindowIDs == [source])
    #expect(buffer.topologyChanged)
    let drained = buffer.drain()
    #expect(drained.frameEventWindowIDs == [source])
    #expect(drained.topologyChanged)
    #expect(buffer.frameEventWindowIDs.isEmpty)
    #expect(!buffer.topologyChanged)
}

@Test func bentoDragPreviewShowsOnlyChangedNeighbours() {
    let source = WindowID(rawValue: "source")
    let unchanged = WindowID(rawValue: "unchanged")
    let moved = WindowID(rawValue: "moved")
    let baseline = [
        source: BTRect(x: 0, y: 0, width: 400, height: 600),
        unchanged: BTRect(x: 400, y: 0, width: 400, height: 300),
        moved: BTRect(x: 400, y: 300, width: 400, height: 300),
    ]
    let placements = [
        Placement(windowID: source, frame: BTRect(x: 400, y: 0, width: 400, height: 300)),
        Placement(windowID: unchanged, frame: baseline[unchanged]!),
        Placement(windowID: moved, frame: BTRect(x: 0, y: 300, width: 400, height: 300)),
    ]

    #expect(BentoDragPreview.changedPlacements(
        placements,
        baselineFrames: baseline,
        excluding: source
    ) == [placements[2]])
}

private func dragWindows(for state: BentoLayoutState) -> [WindowSnapshot] {
    state.placements(in: dragBounds).map { placement in
        WindowSnapshot(
            id: placement.windowID,
            processIdentifier: 1,
            frame: placement.frame,
            displayID: dragDisplayID
        )
    }
}
