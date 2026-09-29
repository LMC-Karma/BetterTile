import AppKit
import Testing
import SwiftUI
@testable import BetterTileCore
@testable import BetterTileMacOS

@Test func dividerHandleIsSuppressedWhenAFloatingWindowCoversIt() {
    let handle = BTRect(x: 490, y: 300, width: 20, height: 56)
    let settings = BTRect(x: 300, y: 180, width: 700, height: 520)
    let besideHandle = BTRect(x: 520, y: 300, width: 200, height: 200)

    #expect(DividerHandleOcclusion.isCovered(handle, by: [settings]))
    #expect(!DividerHandleOcclusion.isCovered(handle, by: [besideHandle]))

    let displayID = DisplayID(rawValue: "main")
    let managed = WindowSnapshot(
        id: WindowID(rawValue: "managed"),
        processIdentifier: 1,
        frame: BTRect(x: 0, y: 0, width: 500, height: 800),
        displayID: displayID
    )
    let floating = WindowSnapshot(
        id: WindowID(rawValue: "floating"),
        processIdentifier: 2,
        frame: settings,
        displayID: displayID
    )
    #expect(DividerHandleOcclusion.obscuringFrames(
        in: [managed, floating],
        excluding: [managed.id]
    ) == [settings])
}

@Test func dividerGripUsesThreefoldStraightGrowthAndShortSpanCap() {
    #expect(DividerHandleGeometry.straightLength(span: 0...200, active: false) == 56)
    #expect(DividerHandleGeometry.straightLength(span: 0...200, active: true) == 168)
    #expect(DividerHandleGeometry.straightLength(span: 0...90, active: true) == 90)
}

@Test(arguments: [2.0, 6.0, 12.0])
func junctionGripKeepsACompactTargetAndCapsEachExistingArm(thickness: Double) {
    let center = BTPoint(x: 100, y: 100)
    let boundaries = [
        boundary("vertical", axis: .vertical, coordinate: 100, start: 80, end: 150),
        boundary("horizontal", axis: .horizontal, coordinate: 100, start: 80, end: 100),
    ]
    let restingArms = DividerHandleGeometry.junctionArmLengths(
        center: center,
        boundaries: boundaries,
        active: false,
        thickness: thickness
    )
    let activeArms = DividerHandleGeometry.junctionArmLengths(
        center: center,
        boundaries: boundaries,
        active: true,
        thickness: thickness
    )
    let resting = DividerHandleGeometry.junctionFrame(
        center: center,
        armLengths: restingArms,
        thickness: thickness
    )
    let active = DividerHandleGeometry.junctionFrame(
        center: center,
        armLengths: activeArms,
        thickness: thickness
    )

    let acquisition = DividerHandleGeometry.junctionAcquisitionFrame(center: center)
    #expect(resting.minX <= acquisition.minX)
    #expect(resting.minY <= acquisition.minY)
    #expect(resting.maxX >= acquisition.maxX)
    #expect(resting.maxY >= acquisition.maxY)
    #expect(Set(activeArms.keys) == [.up, .down, .left])
    #expect(activeArms[.right] == nil)
    #expect(activeArms[.down] == 36)
    #expect(activeArms[.up] == 20 - max(1, thickness / 2))
    #expect(activeArms[.left] == 20 - max(1, thickness / 2))
    #expect(active.minX >= 80)
    #expect(active.maxX <= 100 + max(16, thickness / 2))
    #expect(active.minY >= 80)
    #expect(active.maxY <= 150)
}

@Test func junctionAcquisitionIncludesSquareCornersAndAnEmptyTQuadrant() throws {
    let verticalID = UUID()
    let horizontalID = UUID()
    let boundaries = [
        boundary(
            "vertical", axis: .vertical, coordinate: 100, start: 40, end: 160,
            branchID: verticalID
        ),
        boundary(
            "left-arm", axis: .horizontal, coordinate: 100, start: 40, end: 100,
            branchID: horizontalID
        ),
    ]

    let interaction = try #require(DividerInteractionResolver.resolve(
        at: BTPoint(x: 116, y: 84),
        in: boundaries,
        hitWidth: 18,
        adjacencyTolerance: 6
    ))
    guard case .junction = interaction.kind else {
        Issue.record("The complete 32-point target must select the T junction.")
        return
    }
    let arms = DividerHandleGeometry.junctionArmLengths(
        center: BTPoint(x: 100, y: 100),
        boundaries: interaction.boundaries,
        active: false,
        thickness: 6
    )
    #expect(Set(arms.keys) == [.up, .down, .left])
}

@Test func junctionWinsInsideItsTargetAndStraightBoundaryWinsOutside() throws {
    let boundaries = [
        boundary("vertical", axis: .vertical, coordinate: 100, start: 40, end: 160),
        boundary("horizontal", axis: .horizontal, coordinate: 100, start: 40, end: 160),
    ]
    let junction = try #require(DividerInteractionResolver.resolve(
        at: BTPoint(x: 115, y: 115), in: boundaries, hitWidth: 18, adjacencyTolerance: 6
    ))
    let straight = try #require(DividerInteractionResolver.resolve(
        at: BTPoint(x: 100, y: 130), in: boundaries, hitWidth: 18, adjacencyTolerance: 6
    ))
    guard case .junction = junction.kind else {
        Issue.record("An eligible junction has priority inside its target.")
        return
    }
    #expect(straight.kind == .vertical)
}

@Test func fourWayJunctionRetainsEveryMeetingBentoBranch() throws {
    let boundaries = [
        boundary("v-top", axis: .vertical, coordinate: 100, start: 0, end: 100),
        boundary("v-bottom", axis: .vertical, coordinate: 100, start: 100, end: 200),
        boundary("h-left", axis: .horizontal, coordinate: 100, start: 0, end: 100),
        boundary("h-right", axis: .horizontal, coordinate: 100, start: 100, end: 200),
    ]
    let interaction = try #require(DividerInteractionResolver.resolve(
        at: BTPoint(x: 100, y: 100), in: boundaries, hitWidth: 18, adjacencyTolerance: 6
    ))
    #expect(interaction.boundaries.map(\.id).sorted() == boundaries.map(\.id).sorted())
    let arms = DividerHandleGeometry.junctionArmLengths(
        center: BTPoint(x: 100, y: 100),
        boundaries: interaction.boundaries,
        active: false,
        thickness: 6
    )
    #expect(Set(arms.keys) == Set(DividerHandleArm.allCases))
}

@Test func lockedOtherDisplayAndNearbyNonintersectionsCannotCreateAJunction() throws {
    let vertical = boundary("vertical", axis: .vertical, coordinate: 100, start: 40, end: 160)
    let locked = boundary(
        "locked", axis: .horizontal, coordinate: 100, start: 40, end: 160, isLocked: true
    )
    let otherDisplay = boundary(
        "other-display", display: "other", axis: .horizontal,
        coordinate: 100, start: 40, end: 160
    )
    let nearby = boundary(
        "nearby", axis: .horizontal, coordinate: 100, start: 40, end: 90
    )
    for candidate in [locked, otherDisplay, nearby] {
        let interaction = try #require(DividerInteractionResolver.resolve(
            at: BTPoint(x: 100, y: 100),
            in: [vertical, candidate],
            hitWidth: 18,
            adjacencyTolerance: 6
        ))
        guard case .junction = interaction.kind else { continue }
        Issue.record("An ineligible or cross-display boundary created a junction.")
    }
}

@Test func overlappingJunctionTargetsUseDistanceThenAStableCenterTieBreak() throws {
    let boundaries = [
        boundary("v100", axis: .vertical, coordinate: 100, start: 40, end: 160),
        boundary("h100", axis: .horizontal, coordinate: 100, start: 40, end: 160),
        boundary("v108", axis: .vertical, coordinate: 108, start: 40, end: 160),
        boundary("h108", axis: .horizontal, coordinate: 100, start: 101, end: 170),
    ]
    let nearest = try #require(DividerInteractionResolver.resolve(
        at: BTPoint(x: 107, y: 100), in: boundaries, hitWidth: 18, adjacencyTolerance: 2
    ))
    let tied = try #require(DividerInteractionResolver.resolve(
        at: BTPoint(x: 104, y: 100), in: boundaries, hitWidth: 18, adjacencyTolerance: 2
    ))
    #expect(nearest.boundaries.contains { $0.id == "v108" })
    #expect(tied.boundaries.contains { $0.id == "v100" })
}

@Test @MainActor func ghostPanelsRemainBelowTheActiveHandle() throws {
    _ = NSApplication.shared
    let handle = NSPanel(
        contentRect: CGRect(x: 100, y: 100, width: 20, height: 60),
        styleMask: [.borderless, .nonactivatingPanel],
        backing: .buffered,
        defer: false
    )
    handle.level = .floating
    handle.orderFrontRegardless()
    defer { handle.orderOut(nil) }

    let display = DisplayID(rawValue: "main")
    let snapshot = WindowSnapshot(
        id: WindowID(rawValue: "window"), processIdentifier: 1,
        frame: BTRect(x: 0, y: 0, width: 300, height: 200), displayID: display
    )
    let ghosts = GhostFrameOverlayController()
    ghosts.show(
        placements: [Placement(windowID: snapshot.id, frame: snapshot.frame)],
        windows: [snapshot],
        below: handle
    )
    defer { ghosts.hide() }

    #expect(!ghosts.windowNumbers.isEmpty)
    #expect(ghosts.relativeOrderTargets[snapshot.id] == handle.windowNumber)
}

@Test(arguments: [0.0, 1.0, 6.0, 12.0], [false, true])
func actualBentoPaneGapsStillAcquireJunctions(gap: Double, fourWay: Bool) throws {
    let ids = ["a", "b", "c", "d"].map { WindowID(rawValue: $0) }
    let state = BentoLayoutState(root: .partition(BentoPartition(
        axis: .vertical,
        first: .partition(BentoPartition(axis: .horizontal, first: .leaf(ids[0]), second: .leaf(ids[1]))),
        second: fourWay
            ? .partition(BentoPartition(axis: .horizontal, first: .leaf(ids[2]), second: .leaf(ids[3])))
            : .leaf(ids[2])
    )), metrics: BentoLayoutMetrics(paneGap: gap))
    let bounds = BTRect(x: 0, y: 0, width: 800, height: 600)
    let display = DisplayID(rawValue: "main")
    let windows = state.placements(in: bounds).map {
        WindowSnapshot(id: $0.windowID, processIdentifier: 1, frame: $0.frame, displayID: display)
    }
    let boundaries = BentoBoundaryResolver().boundaries(
        state: state, windows: windows, displayID: display, bounds: bounds
    )
    let interaction = try #require(DividerInteractionResolver.resolve(
        at: BTPoint(x: 400, y: 300), in: boundaries,
        hitWidth: 18, adjacencyTolerance: 6, paneGap: gap
    ))
    guard case .junction = interaction.kind else {
        Issue.record("Real pane gaps must not turn a junction into a straight divider.")
        return
    }
    #expect(Set(interaction.boundaries.compactMap(\.branchID)).count == (fourWay ? 3 : 2))
    #expect(interaction.boundaries.count == (fourWay ? 3 : 2))
    let arms = DividerHandleGeometry.junctionArmLengths(
        center: BTPoint(x: 400, y: 300), boundaries: interaction.boundaries,
        active: true, thickness: 6
    )
    #expect(Set(arms.keys) == (fourWay ? Set(DividerHandleArm.allCases) : [.up, .down, .left]))
}

@Test @MainActor func dragUpdatesDoNotCompleteTheGripAnimationEarly() async throws {
    let grip = DividerHandleView(
        frame: CGRect(x: 0, y: 0, width: 20, height: 168),
        mode: .vertical(restingLength: 56, activeLength: 168), thickness: 6
    )
    await withCheckedContinuation { continuation in
        grip.setActive(true, animated: true) { continuation.resume() }
        grip.setActive(true, animated: false)
        #expect(grip.stretchProgress < 1)
    }
    #expect(grip.stretchProgress == 1)
    await withCheckedContinuation { continuation in
        grip.setActive(false, animated: true) { continuation.resume() }
        grip.setActive(false, animated: false)
        #expect(grip.stretchProgress > 0)
    }
    #expect(grip.stretchProgress == 0)
}

@Test func junctionGrabOffsetIsPreservedAndEachBranchMovesOnce() {
    let v = boundary("v", axis: .vertical, coordinate: 100, start: 0, end: 200)
    let h = boundary("h", axis: .horizontal, coordinate: 100, start: 0, end: 200)
    let interaction = DividerInteraction(boundaries: [v, v, h], kind: .vertical)
    let coordinates = interaction.branchCoordinates(from: BTPoint(x: 115, y: 84), to: BTPoint(x: 125, y: 104))
    #expect(coordinates.count == 2)
    #expect(coordinates[v.branchID!] == 110)
    #expect(coordinates[h.branchID!] == 120)
}

@Test func paneGapCannotJoinUnrelatedOrDistantBranches() {
    let v = boundary("v", axis: .vertical, coordinate: 100, start: 0, end: 200)
    var h = boundary("h", axis: .horizontal, coordinate: 100, start: 0, end: 94)
    let point = BTPoint(x: 100, y: 100)
    #expect(DividerInteractionResolver.resolve(at: point, in: [v, h], hitWidth: 18, adjacencyTolerance: 6, paneGap: 12)?.kind == .vertical)
    h.beforeWindowIDs = v.beforeWindowIDs
    h.spanEnd = 93
    #expect(DividerInteractionResolver.resolve(at: point, in: [v, h], hitWidth: 18, adjacencyTolerance: 6, paneGap: 12)?.kind == .vertical)
}

@Test(arguments: DividerPreviewShape.allCases, [0.0, 12.0])
func previewShapesRetainTheirArmsAndFollowAcceptedGeometry(shape: DividerPreviewShape, gap: Double) {
    let sample = shape.sample(in: BTRect(x: 0, y: 0, width: 600, height: 250), position: CGPoint(x: 0.35, y: 0.65), paneGap: gap)
    #expect(sample.placements.count == (shape == .plus ? 4 : (shape == .vertical || shape == .horizontal ? 2 : 3)))
    for boundary in sample.boundaries {
        #expect(abs(boundary.coordinate - (boundary.axis == .vertical ? sample.center.x : sample.center.y)) < 0.001)
    }
    let expected: Set<DividerHandleArm> = switch shape {
    case .vertical: [.up, .down]
    case .horizontal: [.left, .right]
    case .plus: Set(DividerHandleArm.allCases)
    case .up: [.left, .right, .up]
    case .down: [.left, .right, .down]
    case .left: [.up, .down, .left]
    case .right: [.up, .down, .right]
    }
    let arms = DividerHandleGeometry.junctionArmLengths(center: sample.center, boundaries: sample.boundaries, active: true, thickness: 6)
    #expect(Set(arms.keys) == expected)
}

@Test @MainActor func nativeResizePreviewFitsAndRenders() throws {
    let view = NSHostingView(rootView: DividerResizePreview(thickness: 6, feedback: .ghost, paneGap: 6).padding(16))
    view.frame = CGRect(x: 0, y: 0, width: 680, height: 390)
    let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = view
    view.layoutSubtreeIfNeeded()
    #expect(view.fittingSize.height <= 390)
    let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
    view.cacheDisplay(in: view.bounds, to: bitmap)
    let png = try #require(bitmap.representation(using: .png, properties: [:]))
    #expect(png.count > 2_000)
    if let path = ProcessInfo.processInfo.environment["BETTERTILE_PREVIEW_SNAPSHOT_PATH"] {
        try png.write(to: URL(fileURLWithPath: path))
    }
}

enum DividerTestEnding: CaseIterable {
    case commit, rapidCommit, cancel, participantLoss, stationaryParticipantLoss, failedAcquisition
}

@Test(arguments: [ResizeFeedbackMode.ghost, .live], DividerTestEnding.allCases)
@MainActor func dividerGestureCommitsOrRollsBackWithTheFakeWindowSystem(feedback: ResizeFeedbackMode, ending: DividerTestEnding) async throws {
    _ = NSApplication.shared
    let system = FakeWindowSystem()
    let bounds = BTRect(x: -10_000, y: -10_000, width: 800, height: 600)
    let display = DisplayID(rawValue: "main")
    system.availableDisplays = [DisplaySnapshot(id: display, frame: bounds, visibleFrame: bounds, isMain: true)]
    let ids = ["a", "b", "c", "d"].map { WindowID(rawValue: $0) }
    let state = BentoLayoutState(root: .partition(BentoPartition(
        axis: .vertical,
        first: .partition(BentoPartition(axis: .horizontal, first: .leaf(ids[0]), second: .leaf(ids[1]))),
        second: .partition(BentoPartition(axis: .horizontal, first: .leaf(ids[2]), second: .leaf(ids[3])))
    )), metrics: BentoLayoutMetrics(paneGap: 12))
    system.windows = state.placements(in: bounds).map {
        WindowSnapshot(id: $0.windowID, processIdentifier: 1, frame: $0.frame, displayID: display)
    }
    let original = system.windows.map(\.frame)
    var config = BetterTileConfiguration()
    config.resizeFeedbackMode = feedback
    config.bentoInnerGap = 12
    let controller = DividerOverlayController(coordinator: WindowCoordinator(system: system), configuration: config)
    controller.bentoStateProvider = { _ in state }
    let boundaries = BentoBoundaryResolver().boundaries(state: state, windows: system.windows, displayID: display, bounds: bounds)
    let start = BTPoint(x: bounds.midX + 14, y: bounds.midY - 12)
    let interaction = try #require(DividerInteractionResolver.resolve(at: start, in: boundaries, hitWidth: 18, adjacencyTolerance: 6, paneGap: 12))
    system.targetedSnapshotsFail = ending == .failedAcquisition
    controller.beginGesture(interaction: interaction, at: start)
    defer { controller.hideAndCancel() }
    if ending == .failedAcquisition {
        #expect(!controller.isDragging)
        #expect(system.frameWriteCounts.isEmpty)
        return
    }
    #expect(controller.isDragging)
    #expect(system.frameWriteCounts.isEmpty)
    let screen = try #require(NSScreen.screens.first)
    for delta in [20.0, 50.0] {
        controller.drag(to: CGPoint(x: start.x + delta, y: screen.frame.maxY - (start.y + delta)))
        if ending != .rapidCommit { try await Task.sleep(for: .milliseconds(40)) }
    }
    if feedback == .ghost { #expect(system.frameWriteCounts.isEmpty) }
    if ending == .participantLoss {
        system.windows.removeLast()
        controller.drag(to: CGPoint(x: start.x + 60, y: screen.frame.maxY - (start.y + 60)))
        controller.displayTick()
        #expect(!controller.isDragging)
        return
    } else if ending == .stationaryParticipantLoss {
        // A window-list refresh reports the closure without a pointer sample.
        system.windows.removeLast()
        controller.refresh(boundaries: boundaries)
        #expect(!controller.isDragging)
        return
    } else if ending == .cancel {
        controller.cancelActiveGesture()
        #expect(system.windows.map(\.frame) == original)
    } else {
        controller.end()
        let accepted = BentoBoundaryResolver().boundaries(state: state, windows: system.windows, displayID: display, bounds: bounds)
        #expect(!accepted.isEmpty)
        #expect(accepted.allSatisfy { abs($0.coordinate - (($0.axis == .vertical ? bounds.midX : bounds.midY) + 50)) < 0.001 })
        #expect(system.windows.map(\.frame) != original)
        let writes = system.frameWriteCounts
        controller.end()
        #expect(system.frameWriteCounts == writes)
    }
    #expect(!controller.isDragging)
}

@Test @MainActor func liveDividerAppliesOnlyTheLatestSampleOnEachDisplayTickAndFlushesRelease() throws {
    _ = NSApplication.shared
    let system = FakeWindowSystem()
    let bounds = BTRect(x: -10_000, y: -10_000, width: 800, height: 600)
    let display = DisplayID(rawValue: "main")
    system.availableDisplays = [DisplaySnapshot(id: display, frame: bounds, visibleFrame: bounds, isMain: true)]
    let left = WindowID(rawValue: "left")
    let right = WindowID(rawValue: "right")
    system.windows = [
        WindowSnapshot(
            id: left,
            processIdentifier: 1,
            frame: BTRect(x: bounds.minX, y: bounds.minY, width: 400, height: 600),
            displayID: display
        ),
        WindowSnapshot(
            id: right,
            processIdentifier: 2,
            frame: BTRect(x: bounds.midX, y: bounds.minY, width: 400, height: 600),
            displayID: display
        ),
    ]
    var configuration = BetterTileConfiguration()
    configuration.resizeFeedbackMode = .live
    let displayTicks = ResizeDisplayLink(automatic: false)
    let controller = DividerOverlayController(
        coordinator: WindowCoordinator(system: system),
        configuration: configuration,
        displayTicks: displayTicks
    )
    let boundary = BoundaryDescriptor(
        id: "live-test",
        displayID: display,
        axis: .vertical,
        coordinate: bounds.midX,
        spanStart: bounds.minY,
        spanEnd: bounds.maxY,
        beforeWindowIDs: [left],
        afterWindowIDs: [right]
    )
    let interaction = DividerInteraction(boundaries: [boundary], kind: .vertical)
    let start = BTPoint(x: bounds.midX, y: bounds.midY)
    let screen = try #require(NSScreen.screens.first)
    func appKitPoint(delta: Double) -> CGPoint {
        CGPoint(x: start.x + delta, y: screen.frame.maxY - start.y)
    }

    controller.beginGesture(interaction: interaction, at: start)
    defer { controller.hideAndCancel() }
    for delta in 1...120 {
        controller.drag(to: appKitPoint(delta: Double(delta) / 2))
    }

    #expect(system.frameWriteCounts.isEmpty)
    displayTicks.fire()
    #expect(system.frameWriteCounts == [left: 1, right: 1])
    #expect(system.windows.first(where: { $0.id == left })?.frame.maxX == bounds.midX + 60)
    #expect(system.windows.first(where: { $0.id == right })?.frame.minX == bounds.midX + 60)

    for delta in 121...240 {
        controller.drag(to: appKitPoint(delta: Double(delta) / 2))
    }
    #expect(system.frameWriteCounts == [left: 1, right: 1])

    controller.end(at: appKitPoint(delta: 140))
    #expect(system.frameWriteCounts == [left: 2, right: 2])
    #expect(system.windows.first(where: { $0.id == left })?.frame.maxX == bounds.midX + 140)
    #expect(system.windows.first(where: { $0.id == right })?.frame.minX == bounds.midX + 140)
}

@Test(arguments: [ResizeFeedbackMode.ghost, .live], [true, false]) @MainActor
func dividerEscapeCancelsBeforeReleaseFromEitherKeyMonitor(feedback: ResizeFeedbackMode, useLocalMonitor: Bool) throws {
    _ = NSApplication.shared
    let system = FakeWindowSystem()
    let bounds = BTRect(x: -10_000, y: -10_000, width: 800, height: 600)
    let display = DisplayID(rawValue: "escape-display")
    system.availableDisplays = [DisplaySnapshot(id: display, frame: bounds, visibleFrame: bounds, isMain: true)]
    let state = BentoLayoutState(root: .partition(BentoPartition(
        axis: .vertical,
        first: .leaf(WindowID(rawValue: "left")),
        second: .leaf(WindowID(rawValue: "right"))
    )))
    system.windows = state.placements(in: bounds).map {
        WindowSnapshot(id: $0.windowID, processIdentifier: 1, frame: $0.frame, displayID: display)
    }
    let baseline = system.windows.map(\.frame)
    var configuration = BetterTileConfiguration()
    configuration.resizeFeedbackMode = feedback
    let displayTicks = ResizeDisplayLink(automatic: false)
    var globalHandler: (@MainActor (UInt16) -> Void)?
    var localHandler: (@MainActor (UInt16) -> Bool)?
    var removedMonitors = 0
    let controller = DividerOverlayController(
        coordinator: WindowCoordinator(system: system),
        configuration: configuration,
        displayTicks: displayTicks,
        addGlobalKeyMonitor: { handler in
            globalHandler = handler
            return NSObject()
        },
        addLocalKeyMonitor: { handler in
            localHandler = handler
            return NSObject()
        },
        removeKeyMonitor: { _ in removedMonitors += 1 }
    )
    controller.bentoStateProvider = { _ in state }
    var commits = 0
    controller.bentoStateChangedHandler = { _, _, _, _ in commits += 1 }
    let boundaries = state.boundaries(in: bounds, displayID: display)
    let start = BTPoint(x: bounds.midX, y: bounds.midY)
    let interaction = try #require(DividerInteractionResolver.resolve(
        at: start, in: boundaries, hitWidth: 18, adjacencyTolerance: 6
    ))
    let screen = try #require(NSScreen.screens.first)
    let dragPoint = CGPoint(x: start.x + 60, y: screen.frame.maxY - start.y)
    controller.beginGesture(interaction: interaction, at: start)
    defer { controller.hideAndCancel() }
    #expect(controller.isDragging)
    controller.drag(to: dragPoint)
    displayTicks.fire()
    #expect((system.windows.map(\.frame) != baseline) == (feedback == .live))
    #expect(localHandler?(42) == false)
    globalHandler?(42)
    #expect(controller.isDragging)

    if useLocalMonitor {
        #expect(localHandler?(53) == true)
    } else {
        globalHandler?(53)
    }
    // Cancellation must complete before the next AppKit event can commit.
    #expect(!controller.isDragging)
    controller.end(at: dragPoint)
    displayTicks.fire()

    #expect(system.windows.map(\.frame) == baseline)
    #expect(commits == 0)
    #expect(removedMonitors == 2)
    if feedback == .ghost { #expect(system.frameWriteCounts.isEmpty) }
}

private func boundary(
    _ id: String,
    display: String = "main",
    axis: SplitAxis,
    coordinate: Double,
    start: Double,
    end: Double,
    isLocked: Bool = false,
    branchID: UUID? = UUID()
) -> BoundaryDescriptor {
    BoundaryDescriptor(
        id: id,
        displayID: DisplayID(rawValue: display),
        axis: axis,
        coordinate: coordinate,
        spanStart: start,
        spanEnd: end,
        beforeWindowIDs: [WindowID(rawValue: "\(id)-before")],
        afterWindowIDs: [WindowID(rawValue: "\(id)-after")],
        isLocked: isLocked,
        branchID: branchID
    )
}

enum DividerLimitCase: CaseIterable { case straight, junction, linked }

@Test(arguments: [ResizeFeedbackMode.ghost, .live], DividerLimitCase.allCases)
@MainActor func dividerTurnsOrangeWhenANeighborIsAlreadyAtItsMinimum(feedback: ResizeFeedbackMode, shape: DividerLimitCase) throws {
    _ = NSApplication.shared
    let system = FakeWindowSystem()
    let bounds = BTRect(x: -10_000, y: -10_000, width: 800, height: 600)
    let display = DisplayID(rawValue: "main")
    system.availableDisplays = [DisplaySnapshot(id: display, frame: bounds, visibleFrame: bounds, isMain: true)]
    let ids = ["a", "b", "c", "d"].map { WindowID(rawValue: $0) }
    let state = BentoLayoutState(root: .partition(BentoPartition(
        axis: .vertical,
        first: .partition(BentoPartition(axis: .horizontal, first: .leaf(ids[0]), second: .leaf(ids[1]))),
        second: .partition(BentoPartition(axis: .horizontal, first: .leaf(ids[2]), second: .leaf(ids[3])))
    )), metrics: BentoLayoutMetrics(paneGap: 12))
    let linked = shape == .linked
    system.windows = linked
        ? [
            WindowSnapshot(id: ids[0], processIdentifier: 1, frame: BTRect(x: bounds.minX, y: bounds.minY, width: 400, height: 600), displayID: display),
            WindowSnapshot(id: ids[2], processIdentifier: 1, frame: BTRect(x: bounds.minX + 400, y: bounds.minY, width: 400, height: 600), displayID: display),
        ]
        : state.placements(in: bounds).map { WindowSnapshot(id: $0.windowID, processIdentifier: 1, frame: $0.frame, displayID: display) }
    // The right column already sits at its minimum width.
    for index in system.windows.indices where [ids[2], ids[3]].contains(system.windows[index].id) {
        system.windows[index].constraints = WindowConstraints(minimumSize: BTSize(width: system.windows[index].frame.size.width, height: 80))
    }
    var config = BetterTileConfiguration()
    config.resizeFeedbackMode = feedback
    config.bentoInnerGap = 12
    let controller = DividerOverlayController(coordinator: WindowCoordinator(system: system), configuration: config)
    if !linked { controller.bentoStateProvider = { _ in state } }
    let boundaries = linked
        ? [BoundaryDescriptor(
            id: "native", displayID: display, axis: .vertical, coordinate: bounds.minX + 400,
            spanStart: bounds.minY, spanEnd: bounds.maxY, beforeWindowIDs: [ids[0]], afterWindowIDs: [ids[2]]
        )]
        : BentoBoundaryResolver().boundaries(state: state, windows: system.windows, displayID: display, bounds: bounds)
    let start = shape == .junction
        ? BTPoint(x: bounds.midX, y: bounds.midY)
        : BTPoint(x: bounds.midX, y: bounds.minY + 80)
    let interaction = try #require(DividerInteractionResolver.resolve(at: start, in: boundaries, hitWidth: 18, adjacencyTolerance: 6, paneGap: linked ? 0 : 12))
    if shape == .junction { guard case .junction = interaction.kind else { Issue.record("Expected a junction"); return } }
    let screen = try #require(NSScreen.screens.first)

    controller.beginGesture(interaction: interaction, at: start)
    defer { controller.hideAndCancel() }
    #expect(!controller.dragLimit.isLimited)
    // Moving away from the minimum is not limited.
    controller.drag(to: CGPoint(x: start.x - 30, y: screen.frame.maxY - start.y))
    controller.displayTick()
    #expect(!controller.dragLimit.isLimited)
    // Pushing into the window at its minimum turns the drag orange.
    controller.drag(to: CGPoint(x: start.x + 50, y: screen.frame.maxY - start.y))
    controller.displayTick()
    #expect(controller.dragLimit.width)
    #expect(controller.dragLimit.blockedTowardPositive)
    if feedback == .ghost {
        #expect(controller.limitedGhostWindowIDs.contains(ids[2]))
        #expect(!controller.limitedGhostWindowIDs.contains(ids[0]))
    }
    controller.end()
    #expect(!controller.dragLimit.isLimited)
    #expect(controller.limitedGhostWindowIDs.isEmpty)
}

@Test @MainActor func limitedDividerCursorShowsOnlyTheOpenDirection() {
    let grip = DividerHandleView(
        frame: CGRect(x: 0, y: 0, width: 20, height: 168),
        mode: .vertical(restingLength: 56, activeLength: 168), thickness: 6
    )
    #expect(grip.cursor == .columnResize)
    grip.setLimit(DragLimit(width: true, blockedTowardPositive: true))
    #expect(grip.cursor == .columnResize(directions: .left))
    grip.setLimit(DragLimit())
    #expect(grip.cursor == .columnResize)
}

@Test @MainActor func junctionCursorFollowsTheJunctionShape() {
    func cursor(_ arms: [DividerHandleArm]) -> NSCursor {
        let lengths = Dictionary(uniqueKeysWithValues: arms.map { ($0, 12.0) })
        return DividerHandleView(
            frame: CGRect(x: 0, y: 0, width: 80, height: 80),
            mode: .junction(center: CGPoint(x: 40, y: 40), resting: lengths, active: lengths), thickness: 6
        ).cursor
    }
    #expect(cursor([.up, .down, .left, .right]) == .frameResize(position: .topLeft, directions: .all))
    // Arms up and left only: the junction ends both dividers at its bottom right.
    #expect(cursor([.up, .left, .right]) == .frameResize(position: .bottomLeft, directions: .all))
    #expect(cursor([.up, .down, .left]) == .frameResize(position: .topRight, directions: .all))
    #expect(cursor([.up, .left]) == .frameResize(position: .bottomRight, directions: .all))
}
