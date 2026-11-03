import Testing
@testable import BetterTileCore
@testable import BetterTileMacOS

@Test(.macOSTestApplication, arguments: ["source", "peer", "final", "rollback"])
@MainActor func focusRecoveryRechecksBeforeEveryMutationAndBeforeSuccess(stage: String) {
    let system = FakeWindowSystem()
    system.addSecondWindow()
    let source = system.windows[0], peer = system.windows[1].id
    let third = WindowID(rawValue: "third")
    system.windows.append(WindowSnapshot(id: third, processIdentifier: 44,
        frame: BTRect(x: 0, y: 0, width: 200, height: 200), displayID: source.displayID))
    if stage == "rollback" { system.failingMinimizeWindowID = third }
    let coordinator = WindowCoordinator(system: system)
    let current = {
        switch stage {
        case "source": system.frameWriteCounts[source.id, default: 0] == 0
        case "peer": system.minimizeWriteCounts[peer, default: 0] == 0
        case "final": system.minimizeWriteCounts[third, default: 0] == 0
        default: system.minimizeWriteCounts[peer, default: 0] < 2
        }
    }
    let outcome = coordinator.applyFocusDrop(
        placement: Placement(windowID: source.id, frame: system.availableDisplays[0].visibleFrame),
        minimizing: [peer, third], sourceBaselineFrame: source.frame, validating: current)
    guard case .degraded = outcome else { Issue.record("A stale partial Focus operation must degrade: \(outcome)"); return }
    #expect(system.frameWriteCounts[source.id] == 1)
    #expect(system.minimizeWriteCounts[peer, default: 0] == (stage == "source" ? 0 : stage == "rollback" ? 2 : 1))
    #expect(system.minimizeWriteCounts[third, default: 0] == (["source", "peer"].contains(stage) ? 0 : 1))
}

@Test(.macOSTestApplication) @MainActor
func focusRecoveryPreflightsPeersBeforeChangingTheSource() {
    let system = FakeWindowSystem()
    system.addSecondWindow()
    let source = system.windows[0]
    system.unpreparedBatchWindowID = system.windows[1].id
    let outcome = WindowCoordinator(system: system).applyFocusDrop(
        placement: Placement(windowID: source.id, frame: system.availableDisplays[0].visibleFrame),
        minimizing: [system.windows[1].id], sourceBaselineFrame: source.frame)
    guard case .failed = outcome else { Issue.record("Preflight must refuse without a partial mutation"); return }
    #expect(system.frameWriteCounts.isEmpty)
    #expect(system.minimizeWriteCounts.isEmpty)
}
