import Testing
@testable import BetterTileCore
@testable import BetterTileMacOS

@Test @MainActor func tabbedCoordinatorOrdersSelectedWindowsAndDoesNotMinimize() async {
    let system = FakeWindowSystem()
    system.addSecondWindow()
    let first = system.windows[0].id, second = system.windows[1].id
    let coordinator = WindowCoordinator(system: system)
    let frame = BTRect(x: 0, y: 34, width: 600, height: 600)
    let result = await coordinator.applyTabbed(
        placements: [Placement(windowID: first, frame: frame), Placement(windowID: second, frame: frame)],
        selected: [second], previousSelected: [first], focus: second, isCurrent: { true })
    #expect(result.isApplied)
    #expect(system.windows.allSatisfy { $0.frame == frame })
    #expect(system.focusedWindowID == second)
    #expect(system.raisedWindows.last?.0 == second)
    #expect(system.minimizeWriteCounts.isEmpty)
}

@Test @MainActor func tabbedCoordinatorWaitsForSlowFocusWithoutRollingBack() async {
    let system = FakeWindowSystem()
    system.addSecondWindow()
    let first = system.windows[0].id, second = system.windows[1].id
    system.focusedWindowID = first
    system.delayedFocusReads = 6
    let frame = BTRect(x: 0, y: 34, width: 600, height: 600)
    let result = await WindowCoordinator(system: system).applyTabbed(
        placements: [Placement(windowID: first, frame: frame), Placement(windowID: second, frame: frame)],
        selected: [second], previousSelected: [first], focus: second, isCurrent: { true })
    #expect(result.isApplied)
    #expect(system.windows.allSatisfy { $0.frame == frame })
    #expect(system.focusedWindowID == second)
}

@Test @MainActor func tabbedCoordinatorKeepsAcceptedFramesWhenFocusNeverArrives() async {
    let system = FakeWindowSystem()
    system.addSecondWindow()
    let first = system.windows[0].id, second = system.windows[1].id
    system.focusedWindowID = first
    system.ignoredRaise = true
    let frame = BTRect(x: 0, y: 34, width: 600, height: 600)
    let result = await WindowCoordinator(system: system).applyTabbed(
        placements: [Placement(windowID: first, frame: frame), Placement(windowID: second, frame: frame)],
        selected: [second], previousSelected: [first], focus: second, isCurrent: { true })
    // The frames were accepted and the window was raised. Focus is left to
    // the focus observer instead of undoing a correct arrangement.
    #expect(result.isApplied)
    #expect(system.windows.allSatisfy { $0.frame == frame })
    #expect(system.raisedWindows.last?.0 == second)
}

@Test @MainActor func tabbedCoordinatorRollsBackFrameAndFocusWhenRaiseFails() async {
    let system = FakeWindowSystem()
    system.addSecondWindow()
    let original = system.windows
    system.failingRaiseWindowID = system.windows[1].id
    let coordinator = WindowCoordinator(system: system)
    let result = await coordinator.applyTabbed(
        placements: system.windows.map { Placement(windowID: $0.id, frame: BTRect(x: 0, y: 34, width: 600, height: 600)) },
        selected: [system.windows[1].id], previousSelected: [system.windows[0].id],
        focus: system.windows[1].id, isCurrent: { true })
    guard case .failed = result else { Issue.record("Expected a fully rolled-back failure"); return }
    #expect(system.windows == original)
}

@Test @MainActor func tabbedCoordinatorRejectsStaleDesktopWithoutWriting() async {
    let system = FakeWindowSystem()
    let coordinator = WindowCoordinator(system: system)
    let result = await coordinator.applyTabbed(
        placements: [Placement(windowID: system.windows[0].id, frame: BTRect(x: 0, y: 34, width: 600, height: 600))],
        selected: [], previousSelected: [], focus: nil, isCurrent: { false })
    #expect(!result.isApplied)
    #expect(system.frameWriteCounts.isEmpty)
    #expect(system.raisedWindows.isEmpty)
}

@Test @MainActor func tabbedCoordinatorReportsDegradedIfRestoreIsRejected() async {
    let system = FakeWindowSystem()
    let id = system.windows[0].id
    system.failedFrameWriteNumbers[id] = [2]
    system.failingRaiseWindowID = id
    let result = await WindowCoordinator(system: system).applyTabbed(
        placements: [Placement(windowID: id, frame: BTRect(x: 0, y: 34, width: 600, height: 600))],
        selected: [id], previousSelected: [id], focus: id, isCurrent: { true })
    guard case .degraded = result else { Issue.record("Expected incomplete rollback"); return }
}

@Test @MainActor func tabbedCloseRequestsClosureWithoutRemovingAnUnconfirmedWindow() {
    let system = FakeWindowSystem()
    let id = system.windows[0].id
    #expect(WindowCoordinator(system: system).closeTabbedWindow(id).isApplied)
    #expect(system.closedWindowRequests == [id])
    #expect(system.windows.count == 1)
}

@Test @MainActor func hiddenTabsAreWrittenOnlyWhenMovedAndInTheSameBatch() async {
    let system = FakeWindowSystem()
    system.addSecondWindow()
    var third = system.windows[1]
    third.id = WindowID(rawValue: "third")
    third.processIdentifier = 44
    system.windows.append(third)
    let shown = system.windows[0].id, still = system.windows[1].id, moved = system.windows[2].id
    let frame = BTRect(x: 0, y: 34, width: 600, height: 600)
    system.windows[1].frame = frame
    let coordinator = WindowCoordinator(system: system)
    let placements = [shown, still, moved].map { Placement(windowID: $0, frame: frame) }
    let result = await coordinator.applyTabbed(
        placements: placements, required: [shown], selected: [shown],
        previousSelected: [], focus: shown, isCurrent: { true })
    #expect(result.isApplied)
    #expect(system.frameWriteCounts[still] == nil)
    #expect(system.frameWriteCounts[moved] == 1)
    #expect(system.frameWriteBatches.contains { Set($0) == [shown, moved] })
}

@Test @MainActor func failedTabbedLayoutReturnsMovedHiddenTabs() async {
    let system = FakeWindowSystem()
    system.addSecondWindow()
    let shown = system.windows[0].id, hidden = system.windows[1].id
    let hiddenBefore = system.windows[1].frame
    system.clampWidth = 300
    let frame = BTRect(x: 0, y: 34, width: 600, height: 600)
    let result = await WindowCoordinator(system: system).applyTabbed(
        placements: [Placement(windowID: shown, frame: frame), Placement(windowID: hidden, frame: frame)],
        required: [shown], selected: [shown], previousSelected: [], focus: nil, isCurrent: { true })
    #expect(!result.isApplied)
    #expect(system.windows[1].frame == hiddenBefore)
}

@Test @MainActor func hiddenTabbedPartialResizeIsNotLearnedBeforeItSettles() async throws {
    let system = FakeWindowSystem()
    system.addSecondWindow()
    let shown = system.windows[0].id, hidden = system.windows[1].id
    let target = BTRect(x: 0, y: 34, width: 400, height: 300)
    system.windows[0].frame = target
    system.windows[1].frame = BTRect(x: 200, y: 200, width: 600, height: 400)
    system.enforcedMinimumWidths[hidden] = 500
    var learner = WindowMinimumSizeLearner()
    var hiddenReads = 0
    system.targetedSnapshotHandler = { ids in
        guard ids.contains(hidden), system.frameWriteCounts[hidden, default: 0] > 0 else { return }
        hiddenReads += 1
        if hiddenReads == 3 { system.windows[1].frame = target }
    }
    let result = await WindowCoordinator(system: system).applyTabbed(
        placements: [Placement(windowID: shown, frame: target), Placement(windowID: hidden, frame: target)],
        required: [shown], selected: [shown], previousSelected: [], focus: nil,
        onSizeMismatch: { id, requested, baseline, actual in
            learner.observe(windowID: id, requested: requested, baseline: baseline, actual: actual)
        }, isCurrent: { true })
    #expect(result.isApplied)
    #expect(learner.learnedSizes.isEmpty)
}

@Test @MainActor func tabbedResizeUsesActualFramesAsWriteHintsInsteadOfItsCheckpoint() async throws {
    let system = FakeWindowSystem()
    let id = system.windows[0].id
    let checkpoint = system.windows[0].frame
    system.windows[0].frame.size.width += 150
    let actual = system.windows[0].frame
    let target = checkpoint.offsetBy(dx: 50, dy: 0)
    let result = await WindowCoordinator(system: system).applyTabbed(
        placements: [Placement(windowID: id, frame: target)], rollbackFrames: [id: checkpoint], rollbackDisplayID: system.availableDisplays[0].id,
        selected: [id], previousSelected: [id], focus: nil, isCurrent: { true })
    #expect(result.isApplied)
    #expect(system.recordedKnownCurrentFrames[id]?.first == actual)
}

@Test(arguments: ["stale", "unreadable", "minimized", "missing", "immovable", "display"])
@MainActor func tabbedCheckpointPreflightNeverWritesUnvalidatedParticipants(failure: String) async {
    let system = FakeWindowSystem()
    let id = system.windows[0].id
    let checkpoint = system.windows[0].frame
    system.windows[0].frame.size.width += 150
    var current = true
    system.targetedSnapshotHandler = { _ in
        switch failure {
        case "stale": current = false; system.targetedSnapshotsFail = true
        case "unreadable": system.targetedSnapshotsFail = true
        case "minimized": system.windows[0].isMinimized = true
        case "missing": system.windows = []
        case "immovable": system.windows[0].constraints.isMovable = false
        default: system.windows[0].displayID = DisplayID(rawValue: "other")
        }
    }
    let result = await WindowCoordinator(system: system).applyTabbed(
        placements: [Placement(windowID: id, frame: checkpoint)], rollbackFrames: [id: checkpoint], rollbackDisplayID: system.availableDisplays[0].id,
        selected: [id], previousSelected: [id], focus: nil, isCurrent: { current })
    #expect(!result.isApplied)
    #expect(system.frameWriteCounts.isEmpty)
    #expect(system.raisedWindows.isEmpty)
}

@Test(arguments: [false, true]) @MainActor
func tabbedCheckpointVerificationStopsWhenItsDesktopOrTaskChanges(cancelled: Bool) async {
    let system = FakeWindowSystem()
    let id = system.windows[0].id
    let checkpoint = system.windows[0].frame
    system.windows[0].frame.size.width += 150
    system.ignoredFrameWriteCounts[id] = 1
    var current = true
    let task = Task { @MainActor in
        await WindowCoordinator(system: system).restoreTabbedFrames([id: checkpoint], required: [id],
            on: system.availableDisplays[0].id, isCurrent: { current })
    }
    while system.frameWriteCounts.isEmpty { await Task.yield() }
    if cancelled { task.cancel() } else { current = false }
    let outcome = await task.value
    #expect(!outcome.isApplied)
    #expect(system.frameWriteCounts[id] == 1)
    #expect(system.windows[0].frame != checkpoint)
    #expect(system.raisedWindows.isEmpty)
}

@Test @MainActor func tabbedRequiredSelectionsCannotBeOmittedFromPlacement() async {
    let system = FakeWindowSystem()
    system.addSecondWindow()
    let first = system.windows[0].id, second = system.windows[1].id
    let outcome = await WindowCoordinator(system: system).applyTabbed(
        placements: [Placement(windowID: first, frame: system.windows[0].frame)],
        required: [first, second], selected: [first, second], previousSelected: [], focus: nil, isCurrent: { true })
    #expect(!outcome.isApplied)
    #expect(system.frameWriteCounts.isEmpty)
    #expect(system.raisedWindows.isEmpty)
}
