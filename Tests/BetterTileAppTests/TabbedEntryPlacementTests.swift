import Foundation
import BetterTileCore
import Testing
@testable import BetterTileApp

@MainActor @Suite(.appTestApplication, .serialized)
struct TabbedEntryPlacementTests {
    private func configure(_ placement: String, preset: TabbedPreset, model: BetterTileModel) throws {
        // Decode the new key so this regression also runs against older builds.
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(model.configuration)) as? [String: Any])
        json["tabbedEntryPlacement"] = placement
        model.configuration = try ConfigurationStore.decode(JSONSerialization.data(withJSONObject: json))
        model.configuration.defaultTabbedPreset = preset
    }

    private func makeSystem(count: Int = 3) -> FakeAppWindowSystem {
        let system = makeManualWindowSystem()
        let first = system.windows[0]
        for index in 1..<count {
            var window = first
            window.id = WindowID(rawValue: "entry-\(index)")
            window.processIdentifier = Int32(900_000 + index)
            system.windows.append(window)
        }
        return system
    }

    private func settle(_ model: BetterTileModel, system: FakeAppWindowSystem) async throws {
        try #require(await system.waitFor {
            !model.hasPendingTabbedPlacement && model.windowEventTask == nil && model.settlementTasks.isEmpty
        })
    }

    @Test(arguments: ["allInOnePane", "onePerPane", "keepAdaptivePanes"], [TabbedPreset.single, .columns])
    func adaptiveEntryUsesPlacement(placement: String, preset: TabbedPreset) async throws {
        let system = makeSystem()
        let model = makeModel(system: system)
        defer { model.shutdown() }
        try configure(placement, preset: preset, model: model)
        model.setActiveMode(.bento)
        try await settle(model, system: system)
        let session = try #require(model.savedLayoutSessions()[system.mainDisplay.id])
        guard case let .bento(adaptive) = session else { Issue.record("Expected Adaptive session"); return }
        let writes = system.frameWriteCounts
        model.setActiveMode(.tabbed)
        try await settle(model, system: system)
        let state = try #require(model.activeTabbedState)
        if placement == "keepAdaptivePanes" {
            #expect(state.panes.count == 3)
            #expect(state.panes.allSatisfy { $0.tabs.count == 1 })
            #expect(state.layout.root == adaptive.root)
        } else {
            #expect(state.panes.count == preset.paneCount)
            let counts = state.panes.map { $0.tabs.count }
            #expect(counts == (placement == "onePerPane" && preset == .columns ? [2, 1] : [3] + Array(repeating: 0, count: preset.paneCount - 1)))
        }
        #expect(state.windowIDs == Set(system.windows.map(\.id)))
        // Every fixture accepts the requested frame immediately: one entry pass.
        for window in system.windows {
            #expect(system.frameWriteCounts[window.id, default: 0] - writes[window.id, default: 0] == 1)
        }
        let frames = system.windows.map(\.frame)
        let afterWrites = system.frameWriteCounts
        model.performTabbed(.undo)
        await system.advance(by: .seconds(1))
        try await settle(model, system: system)
        #expect(model.activeTabbedState == state)
        #expect(system.windows.map(\.frame) == frames)
        #expect(system.frameWriteCounts == afterWrites)
    }

    @Test(arguments: ["allInOnePane", "onePerPane", "keepAdaptivePanes"], [TabbedPreset.single, .columns])
    func firstManualEntryUsesPlacement(placement: String, preset: TabbedPreset) async throws {
        let system = makeSystem()
        let model = makeModel(system: system)
        defer { model.shutdown() }
        try configure(placement, preset: preset, model: model)
        model.setActiveMode(.manual)
        model.setActiveMode(.tabbed)
        try await settle(model, system: system)
        let state = try #require(model.activeTabbedState)
        #expect(state.panes.count == preset.paneCount)
        #expect(state.panes.map { $0.tabs.count } == (placement == "onePerPane" && preset == .columns ? [2, 1] : [3] + Array(repeating: 0, count: preset.paneCount - 1)))
    }

    @Test(arguments: ["allInOnePane", "onePerPane", "keepAdaptivePanes"])
    func manualReturnRestoresGroups(placement: String) async throws {
        let system = makeSystem()
        let model = makeModel(system: system)
        defer { model.shutdown() }
        model.setActiveMode(.manual)
        model.setActiveMode(.tabbed)
        try await settle(model, system: system)
        model.performTabbed(.preset(.rows, grouping: .distributeWindows))
        try await settle(model, system: system)
        let state = try #require(model.activeTabbedState)
        model.setActiveMode(.manual)
        try await settle(model, system: system)
        try #require(await system.waitFor { model.activeLayoutMode == .manual })
        try configure(placement, preset: .columns, model: model)
        model.setActiveMode(.tabbed)
        try await settle(model, system: system)
        #expect(model.activeTabbedState == state)
    }

    @Test(arguments: ["allInOnePane", "onePerPane", "keepAdaptivePanes"])
    func adaptiveAutomaticFloatsJoinOnEntry(placement: String) async throws {
        let system = makeSystem(count: 7)
        let model = makeModel(system: system)
        defer { model.shutdown() }
        try configure(placement, preset: .columns, model: model)
        model.setActiveMode(.bento)
        try await settle(model, system: system)
        let session = try #require(model.savedLayoutSessions()[system.mainDisplay.id])
        guard case let .bento(adaptive) = session else { Issue.record("Expected Adaptive session"); return }
        #expect(!adaptive.floatingWindowIDs.isEmpty)
        model.setActiveMode(.tabbed)
        try await settle(model, system: system)
        let state = try #require(model.activeTabbedState)
        #expect(state.windowIDs == Set(system.windows.map(\.id)))
        #expect(state.automaticallyFloatingWindowIDs.isEmpty)
    }
    @Test(arguments: ["allInOnePane", "onePerPane", "keepAdaptivePanes"])
    func oversizedAutomaticFloatStaysAutomatic(placement: String) async throws {
        let system = makeSystem(count: 7)
        let oversized = system.windows[6].id
        system.windows[6].constraints.minimumSize = BTSize(width: 1200, height: 900)
        system.windows[6].constraints.minimumSizeSource = .probe
        system.windows[6].frame.size = BTSize(width: 1200, height: 900)
        system.enforcedMinimumWidths[oversized] = 1200
        system.enforcedMinimumHeights[oversized] = 900
        let model = makeModel(system: system)
        defer { model.shutdown() }
        model.tabbedAutomaticFloatRetryDelay = .seconds(60)
        try configure(placement, preset: .columns, model: model)
        model.setActiveMode(.bento)
        try await settle(model, system: system)
        model.setActiveMode(.tabbed)
        try await settle(model, system: system)
        let state = try #require(model.activeTabbedState)
        #expect(state.automaticallyFloatingWindowIDs.contains(oversized))
        #expect(state.windowIDs.count == 6)
        #expect(model.activeLayoutMode == .tabbed)
    }

    @Test(arguments: ["allInOnePane", "onePerPane", "keepAdaptivePanes"])
    func adaptiveEntryReplacesAnEarlierTabbedVisit(placement: String) async throws {
        let system = makeSystem()
        let model = makeModel(system: system)
        defer { model.shutdown() }
        model.configuration.defaultTabbedPreset = .rows
        model.setActiveMode(.tabbed)
        try await settle(model, system: system)
        let oldPaneIDs = try #require(model.activeTabbedState).panes.map(\.id)
        model.setActiveMode(.bento)
        try #require(await system.waitFor { model.activeLayoutMode == .bento })
        try await settle(model, system: system)
        try configure(placement, preset: .single, model: model)
        let target = try #require(model.captureLayoutWheelTarget())
        model.performLayoutWheel(.setMode(.tabbed), for: target)
        try await settle(model, system: system)
        let state = try #require(model.activeTabbedState)
        #expect(state.panes.count == (placement == "keepAdaptivePanes" ? 3 : 1))
        #expect(state.panes.map(\.id) != oldPaneIDs)
    }

    @Test(arguments: ["allInOnePane", "onePerPane", "keepAdaptivePanes"])
    func userFloatedWindowStaysFloating(placement: String) async throws {
        let system = makeSystem()
        let model = makeModel(system: system)
        defer { model.shutdown() }
        model.setActiveMode(.tabbed)
        try await settle(model, system: system)
        let floated = system.windows[1].id
        model.performTabbed(.float(floated))
        try await settle(model, system: system)
        model.setActiveMode(.bento)
        try #require(await system.waitFor { model.activeLayoutMode == .bento })
        try await settle(model, system: system)
        let frame = system.windows[1].frame
        try configure(placement, preset: .columns, model: model)
        model.setActiveMode(.tabbed)
        try await settle(model, system: system)
        let state = try #require(model.activeTabbedState)
        #expect(state.floatingWindowIDs.contains(floated))
        #expect(!state.automaticallyFloatingWindowIDs.contains(floated))
        #expect(system.windows[1].frame == frame)
    }

    @Test(arguments: ["allInOnePane", "onePerPane", "keepAdaptivePanes"])
    func failedEntryRestoresAdaptive(placement: String) async throws {
        let system = makeSystem()
        let model = makeModel(system: system)
        defer { model.shutdown() }
        try configure(placement, preset: .columns, model: model)
        model.setActiveMode(.bento)
        try await settle(model, system: system)
        let session = model.savedLayoutSessions()[system.mainDisplay.id]
        let frames = system.windows.map(\.frame)
        for window in system.windows {
            system.failedFrameWriteNumbers[window.id] = [system.frameWriteCounts[window.id, default: 0] + 1]
        }
        model.setActiveMode(.tabbed)
        try await settle(model, system: system)
        #expect(model.activeLayoutMode == .bento)
        #expect(model.savedLayoutSessions()[system.mainDisplay.id] == session)
        #expect(system.windows.map(\.frame) == frames)
        #expect(model.lastActionFeedback?.kind == .failure)
    }

}
