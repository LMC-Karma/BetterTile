import BetterTileCore
import BetterTileMacOS
import Testing
@testable import BetterTileApp

@Suite(.appTestApplication, .serialized) @MainActor
struct LayoutActionRegressionProbeTests {
    private func settle(_ model: BetterTileModel, system: FakeAppWindowSystem) async throws {
        await system.advance(by: .milliseconds(400))
        await system.joinWindowEvent(on: model)
        for task in Array(model.settlementTasks.values) { await system.joinSettlement(task, on: model) }
        try #require(await system.waitFor { model.windowEventTask == nil && !model.hasPendingTabbedPlacement })
    }

    @Test func manualLoneWindowKeepsWheelPlacementAfterResizeEvents() async throws {
        let system = makeManualWindowSystem()
        system.emitsFrameEvents = true
        let model = makeModel(system: system)
        defer { model.shutdown() }
        model.updateConfiguration { $0.singleWindowPlacement = .maximize }
        let captured = try #require(model.captureLayoutWheelTarget())
        model.performLayoutWheel(.windowAction(.rightThird), for: captured)
        try await settle(model, system: system)
        #expect(model.activeLayoutMode == .manual)
        #expect(system.windows[0].frame.approximatelyEquals(
            BTRect(x: 2_000.0 / 3, y: 0, width: 1_000.0 / 3, height: 800), tolerance: 0.01))
        #expect(system.frameWriteCounts[system.windows[0].id] == 1)
    }

    @Test func manualWheelUsesCapturedWindowAfterFocusChanges() async throws {
        let system = makeManualWindowSystem()
        let first = system.windows[0].id
        system.focusedID = first
        let model = makeModel(system: system)
        defer { model.shutdown() }
        let captured = try #require(model.captureLayoutWheelTarget())
        let peer = WindowSnapshot(id: WindowID(rawValue: "peer"), processIdentifier: 43,
            frame: BTRect(x: 150, y: 170, width: 400, height: 300), displayID: system.mainDisplay.id)
        system.windows.append(peer)
        system.focusedID = peer.id
        model.performLayoutWheel(.windowAction(.almostMaximize), for: captured)
        try await settle(model, system: system)
        #expect(system.windows[0].frame == BTRect(x: 24, y: 24, width: 952, height: 752))
        #expect(system.windows[1].frame == peer.frame)
        #expect(system.frameWriteCounts[peer.id] == nil)
    }

    @Test(arguments: [LayoutMode.manual, .bento, .tabbed])
    func changedSingleWindowRuleWaitsForRepair(mode: LayoutMode) async throws {
        let system = makeManualWindowSystem()
        let model = makeModel(system: system)
        defer { model.shutdown() }
        model.updateConfiguration { $0.singleWindowPlacement = .leftHalf; $0.defaultTabbedPreset = .single }
        model.setActiveMode(mode)
        try await settle(model, system: system)
        let before = system.windows[0].frame
        model.updateConfiguration { $0.singleWindowPlacement = .rightHalf }
        try await settle(model, system: system)
        #expect(system.windows[0].frame == before, "Changing the rule preserves the current placement")
        if mode != .tabbed {
            model.repairCurrentLayout()
            try await settle(model, system: system)
            #expect(system.windows[0].frame == BTRect(x: 500, y: 0, width: 500, height: 800))
        }
        #expect(model.activeLayoutMode == mode)
    }
}
