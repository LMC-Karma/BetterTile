import Testing
@testable import BetterTileCore
@testable import BetterTileMacOS

@Suite(.macOSTestApplication, .serialized) @MainActor
struct RestoreHistoryDisplayTests {
    @Test(arguments: [false, true])
    func restoreAfterTopologyChangeKeepsTheWindowAndHistory(movedDisplay: Bool) throws {
        let system = FakeWindowSystem()
        let coordinator = WindowCoordinator(system: system)
        let east = DisplaySnapshot(id: DisplayID(rawValue: "east"),
            frame: BTRect(x: 1_000, y: 0, width: 1_000, height: 800),
            visibleFrame: BTRect(x: 1_000, y: 0, width: 1_000, height: 800))
        system.availableDisplays.append(east)
        let original = BTRect(x: 1_200, y: 200, width: 600, height: 400)
        system.windows[0].frame = original
        system.windows[0].displayID = east.id
        try #require(coordinator.performHistoryAction(.leftHalf))
        // macOS moves the window onto the remaining display after the topology changes.
        system.availableDisplays.removeLast()
        if movedDisplay {
            system.availableDisplays.append(DisplaySnapshot(id: east.id,
                frame: BTRect(x: -1_000, y: 0, width: 1_000, height: 800),
                visibleFrame: BTRect(x: -1_000, y: 0, width: 1_000, height: 800)))
        }
        system.windows[0].displayID = system.availableDisplays[0].id
        let reachable = BTRect(x: 200, y: 200, width: 600, height: 400)
        system.windows[0].frame = reachable
        let writes = system.frameWriteCounts
        #expect(!coordinator.performHistoryAction(.restore))
        #expect(system.windows[0].frame == reachable)
        #expect(system.frameWriteCounts == writes)
        // A rejected restore does not consume history. Reconnecting allows it again.
        system.availableDisplays = [system.availableDisplays[0], east]
        #expect(coordinator.performHistoryAction(.restore))
        #expect(system.windows[0].frame == original)
        #expect(system.windows[0].displayID == east.id)
        guard case .unavailable = coordinator.plan(.restore) else {
            Issue.record("Successful Restore should consume its history"); return
        }
    }

    @Test func restoreRechecksDisplaysAfterPlanning() throws {
        let system = FakeWindowSystem()
        let coordinator = WindowCoordinator(system: system)
        let east = DisplaySnapshot(id: DisplayID(rawValue: "east"),
            frame: BTRect(x: 1_000, y: 0, width: 1_000, height: 800),
            visibleFrame: BTRect(x: 1_000, y: 0, width: 1_000, height: 800))
        system.availableDisplays.append(east)
        let original = BTRect(x: 1_200, y: 200, width: 600, height: 400)
        system.windows[0].frame = original
        system.windows[0].displayID = east.id
        try #require(coordinator.performHistoryAction(.leftHalf))
        guard case let .ready(plan) = coordinator.plan(.restore) else {
            Issue.record("Expected Restore plan"); return
        }
        system.availableDisplays.removeLast()
        system.windows[0].displayID = system.availableDisplays[0].id
        let before = BTRect(x: 200, y: 200, width: 600, height: 400)
        system.windows[0].frame = before
        let writes = system.frameWriteCounts
        #expect(!coordinator.perform(plan).isApplied)
        #expect(system.windows[0].frame == before)
        #expect(system.frameWriteCounts == writes)
        system.availableDisplays.append(east)
        #expect(coordinator.performHistoryAction(.restore))
        #expect(system.windows[0].frame == original)
    }

    @Test func reachableRestoreCanReturnToAnotherConnectedDisplay() throws {
        let system = FakeWindowSystem()
        let coordinator = WindowCoordinator(system: system)
        let original = system.windows[0].frame
        system.availableDisplays.append(DisplaySnapshot(id: DisplayID(rawValue: "east"),
            frame: BTRect(x: 1_000, y: 0, width: 1_200, height: 900),
            visibleFrame: BTRect(x: 1_000, y: 30, width: 1_200, height: 870)))
        try #require(coordinator.performHistoryAction(.nextDisplay))
        try #require(system.windows[0].displayID == system.availableDisplays[1].id)
        #expect(coordinator.performHistoryAction(.restore))
        #expect(system.windows[0].frame == original)
        #expect(system.windows[0].displayID == system.availableDisplays[0].id)
    }

    @Test(arguments: [650.0, 775.0])
    func restoreReturnsToWindowParkedAtBottomEdge(y: Double) throws {
        let system = FakeWindowSystem()
        // The second case leaves only the title bar behind the reserved Dock strip.
        system.availableDisplays[0].visibleFrame = BTRect(x: 0, y: 25, width: 1_000, height: 725)
        let coordinator = WindowCoordinator(system: system)
        let original = BTRect(x: 200, y: y, width: 600, height: 400)
        system.windows[0].frame = original
        try #require(coordinator.performHistoryAction(.leftHalf))
        #expect(coordinator.performHistoryAction(.restore))
        #expect(system.windows[0].frame == original)
    }

    @Test func restoreReturnsToWindowSpanningConnectedDisplays() throws {
        let system = FakeWindowSystem()
        system.availableDisplays.append(DisplaySnapshot(id: DisplayID(rawValue: "east"),
            frame: BTRect(x: 1_000, y: 300, width: 1_000, height: 800),
            visibleFrame: BTRect(x: 1_000, y: 325, width: 1_000, height: 725)))
        let coordinator = WindowCoordinator(system: system)
        let original = BTRect(x: 650, y: 100, width: 800, height: 400)
        system.windows[0].frame = original
        try #require(coordinator.performHistoryAction(.leftHalf))
        #expect(coordinator.performHistoryAction(.restore))
        #expect(system.windows[0].frame == original)
    }

    @Test(arguments: [
        BTRect(x: 999, y: 200, width: 600, height: 400),
        BTRect(x: 200, y: -100, width: 600, height: 400)
    ])
    func restoreRejectsSliverOrMissingTitleBar(original: BTRect) throws {
        let system = FakeWindowSystem()
        let coordinator = WindowCoordinator(system: system)
        system.windows[0].frame = original
        try #require(coordinator.performHistoryAction(.leftHalf))
        let before = system.windows[0].frame
        let writes = system.frameWriteCounts
        #expect(!coordinator.performHistoryAction(.restore))
        #expect(system.windows[0].frame == before)
        #expect(system.frameWriteCounts == writes)
        guard case let .ready(plan) = coordinator.plan(.restore) else {
            Issue.record("Rejected Restore should retain its history"); return
        }
        #expect(plan.targetFrame == original)
    }
}

@MainActor
private extension WindowCoordinator {
    func performHistoryAction(_ action: WindowAction) -> Bool {
        guard case let .ready(plan) = plan(action) else { return false }
        return perform(plan).isApplied
    }
}
