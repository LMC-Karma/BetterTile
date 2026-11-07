import BetterTileCore
import Testing
@testable import BetterTileApp

@Suite(.appTestApplication, .serialized) @MainActor
struct RestoreHistoryDisplayActionTests {
    @Test(arguments: [false, true])
    func restoreAfterUnplugKeepsWindowReachable(fromWheel: Bool) async throws {
        let system = makeManualWindowSystem()
        let east = DisplaySnapshot(id: DisplayID(rawValue: "east"),
            frame: BTRect(x: 1_000, y: 0, width: 1_000, height: 800),
            visibleFrame: BTRect(x: 1_000, y: 0, width: 1_000, height: 800))
        system.availableDisplays.append(east)
        system.windows[0].frame = BTRect(x: 1_200, y: 200, width: 600, height: 400)
        system.windows[0].displayID = east.id
        let model = makeModel(system: system)
        defer { model.shutdown() }
        model.perform(.leftHalf)
        try #require(system.windows[0].frame == BTRect(x: 1_000, y: 0, width: 500, height: 800))
        system.availableDisplays.removeLast()
        system.windows[0].displayID = system.mainDisplay.id
        system.windows[0].frame = BTRect(x: 200, y: 200, width: 600, height: 400)
        let reachable = system.windows[0].frame
        let writes = system.frameWriteCounts
        if fromWheel {
            model.performLayoutWheel(.windowAction(.restore), for: try #require(model.captureLayoutWheelTarget()))
        } else {
            model.perform(.restore)
        }
        await system.advance(by: .milliseconds(400))
        await system.joinWindowEvent(on: model)
        for task in Array(model.settlementTasks.values) { await system.joinSettlement(task, on: model) }
        #expect(PlacementBounds.isReachable(system.windows[0].frame, in: system.mainDisplay.visibleFrame))
        #expect(system.windows[0].frame == reachable)
        #expect(system.frameWriteCounts == writes)
        #expect(model.statusMessage?.contains("off screen") == true)
    }
}
