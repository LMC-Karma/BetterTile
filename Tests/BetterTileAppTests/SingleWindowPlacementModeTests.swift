import AppKit
import BetterTileCore
import BetterTileMacOS
import Testing
@testable import BetterTileApp

/// "When a desktop has one window" applies in Adaptive. Manual leaves windows where they are; Repair
/// Layout still places a lone Manual window on request. Tabbed fills its panes and never uses the rule.
@Suite(.appTestApplication, .serialized) @MainActor struct SingleWindowPlacementModeTests {
    private let first = NativeSpaceID(rawValue: 1)
    private let second = NativeSpaceID(rawValue: 2)
    private let small = BTRect(x: 630, y: 160, width: 260, height: 170)

    /// Two windows on the current Space and one small window on another. Switching to a
    /// one-window Manual desktop must leave its window alone.
    private func twoSpaces() -> (FakeAppWindowSystem, WindowSnapshot) {
        let system = FakeAppWindowSystem()
        let display = system.mainDisplay.id
        system.windows.append(WindowSnapshot(id: WindowID(rawValue: "peer"), processIdentifier: 43,
            frame: BTRect(x: 100, y: 100, width: 400, height: 300), displayID: display))
        let lone = WindowSnapshot(id: WindowID(rawValue: "lone"), processIdentifier: 44, frame: small, displayID: display)
        var membership: [WindowID: Set<NativeSpaceID>] = [lone.id: [second]]
        for window in system.windows { membership[window.id] = [first] }
        system.desktopObservation = NativeDesktopObservation(currentSpaceByDisplay: [display: first],
            knownSpacesByDisplay: [display: [first, second]], windowMembership: membership)
        system.physicalSpace = first
        return (system, lone)
    }

    /// The Space switch completes; the stabilization sweep observes the new Space and returns.
    private func switchToSecond(_ system: FakeAppWindowSystem, showing windows: [WindowSnapshot],
                                model: BetterTileModel) async throws {
        system.physicalSpace = second
        system.desktopObservation?.currentSpaceByDisplay[system.mainDisplay.id] = second
        system.windows = windows
        model.beginActiveSpaceStabilization()
        try #require(model.isStabilizingSpace)
        try #require(await waitFor { !model.isStabilizingSpace }, "The stabilization sweep ran")
    }

    @Test(arguments: ["manual", "tabbed"])
    func aFreshManualSpaceLeavesItsLoneWindowAlone(firstSpaceMode: String) async throws {
        let (system, lone) = twoSpaces()
        let model = makeModel(system: system)
        defer { model.shutdown() }
        #expect(model.configuration.defaultLayoutMode == .manual)
        #expect(model.configuration.singleWindowPlacement == .maximize)
        if firstSpaceMode == "tabbed" {
            model.setActiveMode(.tabbed)
            try #require(await waitFor { model.activeTabbedState?.windowIDs.count == 2 && !model.hasPendingTabbedPlacement })
        }
        try await switchToSecond(system, showing: [lone], model: model)
        #expect(model.activeLayoutMode == .manual)
        #expect(system.frameWriteCounts[lone.id, default: 0] == 0, "Manual moves no window on its own")
        #expect(system.windows.first { $0.id == lone.id }?.frame == small)
    }

    @Test func aFreshAdaptiveSpaceStillPlacesItsLoneWindow() async throws {
        let (system, lone) = twoSpaces()
        let model = makeModel(system: system)
        defer { model.shutdown() }
        model.updateConfiguration { $0.defaultLayoutMode = .bento }
        try await switchToSecond(system, showing: [lone], model: model)
        #expect(model.activeLayoutMode == .bento)
        #expect(system.frameWriteCounts[lone.id, default: 0] == 1)
        #expect(system.windows.first { $0.id == lone.id }?.frame == system.mainDisplay.visibleFrame)
    }

    @Test func switchingALoneManualWindowToAdaptivePlacesItThen() async throws {
        let system = FakeAppWindowSystem()
        system.windows[0].frame = small
        let id = system.windows[0].id
        let model = makeModel(system: system)
        defer { model.shutdown() }
        model.beginActiveSpaceStabilization()
        try #require(await waitFor { !model.isStabilizingSpace })
        #expect(system.frameWriteCounts[id, default: 0] == 0, "Manual leaves the lone window alone")
        #expect(system.windows[0].frame == small)
        model.setActiveMode(.bento)
        #expect(await waitFor { system.windows[0].frame == system.mainDisplay.visibleFrame },
                "Adaptive applies the rule when the desktop switches")
        #expect(model.activeLayoutMode == .bento)
    }

    @Test func repairInManualStillPlacesALoneWindowAndStaysManual() async throws {
        let system = FakeAppWindowSystem()
        system.windows[0].frame = small
        let id = system.windows[0].id
        let model = makeModel(system: system)
        defer { model.shutdown() }
        model.updateConfiguration { $0.singleWindowPlacement = .leftHalf }
        model.beginActiveSpaceStabilization()
        try #require(await waitFor { !model.isStabilizingSpace })
        #expect(system.frameWriteCounts[id, default: 0] == 0)
        model.repairCurrentLayout()
        #expect(await waitFor { system.windows[0].frame == BTRect(x: 0, y: 0, width: 500, height: 800) },
                "Repair places the lone window on request")
        #expect(model.activeLayoutMode == .manual, "Repair keeps a one-window desktop Manual")
    }

    /// Unchanged behaviour, pinned with the caption: a lone Tabbed window fills its single pane.
    @Test func aLoneTabbedWindowFillsItsPaneWhateverTheRule() async throws {
        let system = FakeAppWindowSystem()
        system.windows[0].frame = small
        let model = makeModel(system: system)
        defer { model.shutdown() }
        model.updateConfiguration { $0.singleWindowPlacement = .leftHalf; $0.defaultTabbedPreset = .single }
        model.setActiveMode(.tabbed)
        try #require(await waitFor { model.activeTabbedState?.windowIDs.count == 1 && !model.hasPendingTabbedPlacement })
        #expect(system.windows[0].frame == BTRect(x: 0, y: 34, width: 1000, height: 766))
    }
}

@Suite(.appTestApplication, .serialized) @MainActor
struct CapturedLayoutActionTests {
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

    @Test
    func adaptiveSingleWindowRuleWaitsForRepair() async throws {
        let system = makeManualWindowSystem()
        let model = makeModel(system: system)
        defer { model.shutdown() }
        model.updateConfiguration { $0.singleWindowPlacement = .leftHalf; $0.defaultTabbedPreset = .single }
        model.setActiveMode(.bento)
        try await settle(model, system: system)
        let before = system.windows[0].frame
        #expect(before == BTRect(x: 0, y: 0, width: 500, height: 800))
        model.updateConfiguration { $0.singleWindowPlacement = .rightHalf }
        try await settle(model, system: system)
        #expect(system.windows[0].frame == before, "Changing the rule preserves the current placement")
        model.repairCurrentLayout()
        try await settle(model, system: system)
        #expect(system.windows[0].frame == BTRect(x: 500, y: 0, width: 500, height: 800))
        #expect(model.activeLayoutMode == .bento)
    }
}
