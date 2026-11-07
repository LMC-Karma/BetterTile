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
    func adaptiveAutomaticFloatEntryRegressionGuard(placement: String) async throws {
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

    @Test(arguments: [LayoutMode.manual, .bento], [TabbedPreset.single, .columns])
    func entryDistributionKeepsIncomingFocus(mode: LayoutMode, preset: TabbedPreset) async throws {
        for fromWheel in [false, true] {
            let system = makeSystem()
            let model = makeModel(system: system)
            defer { model.shutdown() }
            try configure("onePerPane", preset: preset, model: model)
            model.setActiveMode(mode)
            try await settle(model, system: system)
            let focused = system.windows[0].id
            system.focusedID = focused
            let writes = system.frameWriteCounts
            if fromWheel {
                model.performLayoutWheel(.setMode(.tabbed), for: try #require(model.captureLayoutWheelTarget()))
            } else {
                model.setActiveMode(.tabbed)
            }
            try await settle(model, system: system)
            let state = try #require(model.activeTabbedState)
            #expect(state.selectedWindowIDs.contains(focused))
            #expect(state.activeWindowID == focused)
            #expect(try system.focusedWindow()?.id == focused)
            for window in system.windows {
                #expect(system.frameWriteCounts[window.id, default: 0] - writes[window.id, default: 0] == 1)
            }
            model.performTabbed(.undo)
            await system.advance(by: .seconds(1))
            try await settle(model, system: system)
            #expect(model.activeTabbedState == state)
            #expect(try system.focusedWindow()?.id == focused)
        }
    }

    @Test(arguments: ["allInOnePane", "onePerPane", "keepAdaptivePanes"], [false, true])
    func firstManualEntryDiscardsFloatsFromEarlierAdaptiveVisit(placement: String, automatic: Bool) async throws {
        let system = makeSystem(count: automatic ? 7 : 3)
        let model = makeModel(system: system)
        defer { model.shutdown() }
        if !automatic {
            model.setActiveMode(.tabbed)
            try await settle(model, system: system)
            model.performTabbed(.float(system.windows[1].id))
            try await settle(model, system: system)
        }
        model.setActiveMode(.bento)
        try #require(await system.waitFor { model.activeLayoutMode == .bento })
        try await settle(model, system: system)
        guard case let .bento(adaptive) = model.savedLayoutSessions()[system.mainDisplay.id] else {
            Issue.record("Expected the earlier Adaptive visit"); return
        }
        #expect(!adaptive.floatingWindowIDs.isEmpty)
        model.setActiveMode(.manual)
        try #require(await system.waitFor { model.activeLayoutMode == .manual })
        try await settle(model, system: system)
        try configure(placement, preset: .columns, model: model)
        model.setActiveMode(.tabbed)
        try await settle(model, system: system)
        let state = try #require(model.activeTabbedState)
        #expect(state.windowIDs == Set(system.windows.map(\.id)))
        #expect(state.floatingWindowIDs.isEmpty)
    }

    @Test(arguments: ["allInOnePane", "onePerPane", "keepAdaptivePanes"], [false, true])
    func retainedFloatKeepsIncomingFocus(placement: String, automatic: Bool) async throws {
        for fromWheel in [false, true] {
            let system = makeSystem(count: automatic ? 7 : 3)
            let floated = system.windows[automatic ? 6 : 1].id
            if automatic {
                let size = BTSize(width: 1200, height: 900)
                system.windows[6].constraints.minimumSize = size
                system.windows[6].constraints.minimumSizeSource = .probe
                system.windows[6].frame.size = size
                system.enforcedMinimumWidths[floated] = size.width
                system.enforcedMinimumHeights[floated] = size.height
            }
            let model = makeModel(system: system)
            defer { model.shutdown() }
            model.tabbedAutomaticFloatRetryDelay = .seconds(60)
            if !automatic {
                model.setActiveMode(.tabbed)
                try await settle(model, system: system)
                model.performTabbed(.float(floated))
                try await settle(model, system: system)
            }
            model.setActiveMode(.bento)
            try #require(await system.waitFor { model.activeLayoutMode == .bento })
            try await settle(model, system: system)
            guard case let .bento(adaptive) = model.savedLayoutSessions()[system.mainDisplay.id] else {
                Issue.record("Expected Adaptive before entry"); return
            }
            try #require(adaptive.floatingWindowIDs.contains(floated))
            system.focusedID = floated
            let frame = try #require(system.windows.first { $0.id == floated }).frame
            let raises = system.raiseRequests.count
            let writes = system.frameWriteCounts[floated, default: 0]
            try configure(placement, preset: .columns, model: model)
            if fromWheel {
                model.performLayoutWheel(.setMode(.tabbed), for: try #require(model.captureLayoutWheelTarget()))
            } else {
                model.setActiveMode(.tabbed)
            }
            try await settle(model, system: system)
            let state = try #require(model.activeTabbedState)
            #expect(state.floatingWindowIDs.contains(floated))
            #expect(state.automaticallyFloatingWindowIDs.contains(floated) == automatic)
            #expect(!state.windowIDs.contains(floated))
            #expect(try system.focusedWindow()?.id == floated)
            #expect(system.windows.first { $0.id == floated }?.frame == frame)
            #expect(system.frameWriteCounts[floated, default: 0] == writes)
            let entryRaises = system.raiseRequests.dropFirst(raises)
            #expect(!entryRaises.contains { $0.0 != floated && $0.1 })
        }
    }

    @Test(arguments: [LayoutMode.manual, .bento], [TabbedPreset.columns, .rows, .focus, .grid])
    func entryDistributionFollowsScreenReadingOrder(mode: LayoutMode, preset: TabbedPreset) async throws {
        let manualColumns = mode == .manual && preset == .columns
        let system = makeSystem(count: preset == .grid ? 4 : (manualColumns ? 2 : 3))
        // IDs disagree with the visible order. Manual windows in the same
        // visual row have top edges one point apart.
        system.windows[0].frame = BTRect(x: 600, y: 400, width: 300, height: 300)
        system.windows[1].frame = BTRect(x: 600, y: mode == .manual ? 40 : 0, width: 300, height: 300)
        if manualColumns {
            system.windows[0].frame = BTRect(x: 620, y: 40, width: 360, height: 500)
            system.windows[1].frame = BTRect(x: 20, y: 41, width: 360, height: 500)
        } else {
            let left = mode == .manual && preset == .rows ? 400.0 : 0.0
            system.windows[2].frame = BTRect(x: left, y: mode == .manual ? 41 : 0, width: 300, height: 300)
        }
        if preset == .grid {
            system.windows[3].frame = BTRect(x: 0, y: mode == .manual ? 401 : 400, width: 300, height: 300)
        }
        let ids = system.windows.map(\.id)
        let model = makeModel(system: system)
        defer { model.shutdown() }
        try configure("onePerPane", preset: preset, model: model)
        model.setActiveMode(mode)
        try await settle(model, system: system)
        let expected: [[WindowID]]
        if mode == .manual {
            // Explicit pane contents: left to right within each visual row.
            // These expectations must not copy the production matching policy.
            switch preset {
            case .columns: expected = [[ids[1]], [ids[0]]]
            case .rows: expected = [[ids[2], ids[1]], [ids[0]]]
            case .focus: expected = [[ids[2]], [ids[1]], [ids[0]]]
            case .grid: expected = [[ids[2]], [ids[1]], [ids[3]], [ids[0]]]
            case .single: expected = [ids]
            }
        } else {
            // Adaptive has already rearranged the fixture. Keep its established
            // reading-order result as a guard against changes to Adaptive entry.
            let ordered = system.windows.sorted {
                if $0.frame.minY != $1.frame.minY { return $0.frame.minY < $1.frame.minY }
                return $0.frame.minX < $1.frame.minX
            }.map(\.id)
            expected = (0..<preset.paneCount).map { pane in
                ordered.enumerated().filter { $0.offset % preset.paneCount == pane }.map(\.element)
            }
        }
        model.setActiveMode(.tabbed)
        try await settle(model, system: system)
        let state = try #require(model.activeTabbedState)
        let frames = state.frames(in: system.mainDisplay.visibleFrame)
        let panes = state.panes.sorted {
            let a = frames[$0.id]!, b = frames[$1.id]!
            return a.minY == b.minY ? a.minX < b.minX : a.minY < b.minY
        }
        for (index, pane) in panes.enumerated() {
            #expect(pane.tabs == expected[index])
        }
    }

    @Test
    func entryDistributionBreaksDistanceTiesByWindowID() async throws {
        let system = makeSystem(count: 6)
        for index in system.windows.indices {
            system.windows[index].frame = BTRect(x: 350, y: 250, width: 300, height: 300)
        }
        let ids = system.windows.map(\.id).sorted()
        // Neither scan order nor incoming focus should break distance ties.
        system.windows.reverse()
        system.focusedID = ids[5]
        let model = makeModel(system: system)
        defer { model.shutdown() }
        try configure("onePerPane", preset: .grid, model: model)
        model.setActiveMode(.manual)
        model.setActiveMode(.tabbed)
        try await settle(model, system: system)
        let state = try #require(model.activeTabbedState)
        let frames = state.frames(in: system.mainDisplay.visibleFrame)
        let panes = state.panes.sorted {
            let a = frames[$0.id]!, b = frames[$1.id]!
            return a.minY == b.minY ? a.minX < b.minX : a.minY < b.minY
        }
        let expected = [[ids[0], ids[4]], [ids[1], ids[5]], [ids[2]], [ids[3]]]
        #expect(panes.map(\.tabs) == expected)
        #expect(state.activeWindowID == ids[5])
        #expect(try system.focusedWindow()?.id == ids[5])
    }

}
