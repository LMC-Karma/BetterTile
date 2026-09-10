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
