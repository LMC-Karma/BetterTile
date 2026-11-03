import AppKit
import BetterTileCore
import Foundation
import Testing
@testable import BetterTileApp

@Suite(.appTestApplication, .serialized) @MainActor
struct SingleWindowRepairRetentionTests {
    private func session(_ model: BetterTileModel, _ display: DisplayID) throws -> LayoutSession {
        let store = Mirror(reflecting: model).children.first { $0.label?.hasSuffix("sessionStore") == true }?.value as? LayoutSessionStore
        return try #require(store?.session(for: display))
    }

    @Test(arguments: [false, true], [false, true])
    func manualRepairKeepsStoredTabbedLayout(places: Bool, repairs: Bool) async throws {
        _ = NSApplication.shared
        let system = FakeAppWindowSystem()
        let model = makeModel(system: system)
        defer { model.shutdown() }
        model.configuration.defaultLayoutMode = .manual
        model.configuration.defaultTabbedPreset = .columns
        model.configuration.singleWindowPlacement = places ? .maximize : nil
        model.setActiveMode(.tabbed)
        try #require(await waitFor { model.activeTabbedState?.panes.count == 2 && !model.hasPendingTabbedPlacement })
        let original = try #require(model.activeTabbedState)
        let originalSession = try session(model, system.mainDisplay.id)
        model.setActiveMode(.manual)
        try #require(await waitFor { model.activeLayoutMode == .manual && !model.hasPendingTabbedPlacement })
        if repairs { model.repairCurrentLayout() }
        #expect(model.activeLayoutMode == .manual)
        #expect(try session(model, system.mainDisplay.id).id == originalSession.id)
        model.setActiveMode(.tabbed)
        try #require(await waitFor { model.activeLayoutMode == .tabbed && !model.hasPendingTabbedPlacement })
        let returned = try #require(model.activeTabbedState)
        #expect(returned.panes.map(\.id) == original.panes.map(\.id))
        #expect(returned.panes.map(\.tabs) == original.panes.map(\.tabs))
        #expect(returned.layout == original.layout)
        #expect(returned.panes == original.panes)
        #expect(returned.activePaneID == original.activePaneID)
    }

    @Test(arguments: ["success", "nil", "failed", "stale"], [false, true])
    func singleRepairCommitsOnlyValidState(outcome: String, native: Bool) async throws {
        _ = NSApplication.shared
        let system = FakeAppWindowSystem()
        let display = system.mainDisplay.id
        let b = WindowID(rawValue: "peer")
        system.windows.append(WindowSnapshot(id: b, processIdentifier: 43,
            frame: BTRect(x: 450, y: 200, width: 400, height: 400), displayID: display))
        if native {
            let space = NativeSpaceID(rawValue: 1)
            system.desktopObservation = NativeDesktopObservation(currentSpaceByDisplay: [display: space],
                knownSpacesByDisplay: [display: [space]], windowMembership: Dictionary(uniqueKeysWithValues: system.windows.map { ($0.id, [space]) }))
        }
        let model = makeModel(system: system)
        defer { model.shutdown() }
        model.configuration.defaultLayoutMode = .manual
        model.configuration.bentoInnerGap = 11
        model.setActiveMode(.bento)
        try #require(await waitFor { model.settlementTasks.isEmpty })
        let before = try session(model, display)
        let frames = system.windows.map(\.frame)
        system.offscreenWindowIDs = [b]
        model.configuration.singleWindowPlacement = outcome == "nil" ? nil : .maximize
        let a = system.windows[0].id
        if outcome == "failed" { system.failedFrameWriteNumbers[a] = [system.frameWriteCounts[a, default: 0] + 1] }
        var invalidated = false
        if outcome == "stale" {
            var reads = 0
            system.onWindowSnapshots = { [weak system, weak model] in
                reads += 1
                guard reads == 2 else { return }
                system?.onWindowSnapshots = nil
                invalidated = true
                model?.setActiveMode(.manual)
            }
        }
        model.repairCurrentLayout()
        let after = try session(model, display)
        #expect(after.id == before.id)
        #expect(after.bentoState.metrics == before.bentoState.metrics)
        #expect(system.windows[1].frame == frames[1])
        if outcome == "failed" || outcome == "stale" {
            #expect(after.bentoState == before.bentoState)
            #expect(after.isBentoInitialized)
            #expect(system.windows[0].frame == frames[0])
            #expect(!after.automaticWritesSuspended)
            if outcome == "stale" { #expect(invalidated); #expect(after.mode == .manual) }
        } else {
            #expect(after.bentoState.root == nil)
            #expect(!after.isBentoInitialized)
            #expect(system.windows[0].frame == (outcome == "nil" ? frames[0] : system.mainDisplay.visibleFrame))
            let writes = system.frameWriteCounts
            model.watchdog()
            #expect(system.frameWriteCounts == writes)
            system.offscreenWindowIDs = []
            model.handleApplicationTopologyChange()
            try #require(await waitFor { model.settlementTasks.isEmpty })
            let returned = try session(model, display)
            #expect(Set(returned.bentoState.root?.windowIDs ?? []) == Set(system.windows.map(\.id)))
            #expect(BentoLayoutVerifier.overlappingWindowIDs(Dictionary(uniqueKeysWithValues: system.windows.map { ($0.id, $0.frame) })).isEmpty)
        }
    }

    @Test(arguments: [false, true])
    func ordinaryOmissionKeepsUserPartition(native: Bool) async throws {
        _ = NSApplication.shared
        let system = FakeAppWindowSystem()
        let display = system.mainDisplay.id
        let b = WindowID(rawValue: "peer")
        system.windows.append(WindowSnapshot(id: b, processIdentifier: 43,
            frame: BTRect(x: 450, y: 200, width: 400, height: 400), displayID: display))
        if native {
            let space = NativeSpaceID(rawValue: 1)
            system.desktopObservation = NativeDesktopObservation(currentSpaceByDisplay: [display: space],
                knownSpacesByDisplay: [display: [space]], windowMembership: Dictionary(uniqueKeysWithValues: system.windows.map { ($0.id, [space]) }))
        }
        let model = makeModel(system: system)
        defer { model.shutdown() }
        model.setActiveMode(.bento)
        try #require(await waitFor { model.settlementTasks.isEmpty })
        model.perform(.leftThird)
        try #require(await waitFor { model.settlementTasks.isEmpty })
        let original = try session(model, display)
        let frames = system.windows.map(\.frame)
        let writes = system.frameWriteCounts
        system.offscreenWindowIDs = [b]
        model.handleApplicationTopologyChange()
        #expect(try session(model, display).bentoState == original.bentoState)
        #expect(system.windows.map(\.frame) == frames)
        system.offscreenWindowIDs = []
        model.handleApplicationTopologyChange()
        #expect(try session(model, display).bentoState == original.bentoState)
        #expect(system.windows.map(\.frame) == frames)
        #expect(system.frameWriteCounts == writes)
    }

    @Test(arguments: [0, 2], [false, true])
    func repairWithoutASingleWindowKeepsExistingPolicy(visibleCount: Int, native: Bool) async throws {
        _ = NSApplication.shared
        let system = FakeAppWindowSystem()
        let display = system.mainDisplay.id
        system.windows.append(WindowSnapshot(id: WindowID(rawValue: "peer"), processIdentifier: 43,
            frame: BTRect(x: 450, y: 200, width: 400, height: 400), displayID: display))
        if native {
            let space = NativeSpaceID(rawValue: 1)
            system.desktopObservation = NativeDesktopObservation(currentSpaceByDisplay: [display: space],
                knownSpacesByDisplay: [display: [space]],
                windowMembership: Dictionary(uniqueKeysWithValues: system.windows.map { ($0.id, [space]) }))
        }
        let model = makeModel(system: system)
        defer { model.shutdown() }
        model.configuration.defaultLayoutMode = .manual
        model.setActiveMode(.bento)
        try #require(await waitFor { model.settlementTasks.isEmpty })
        if visibleCount == 2 { model.setActiveMode(.manual) }
        let before = try session(model, display)
        let frames = system.windows.map(\.frame)
        let writes = system.frameWriteCounts
        if visibleCount == 0 { system.offscreenWindowIDs = Set(system.windows.map(\.id)) }

        model.repairCurrentLayout()
        try #require(await waitFor { model.settlementTasks.isEmpty })

        let after = try session(model, display)
        #expect(after.id == before.id)
        #expect(after.bentoState.metrics == before.bentoState.metrics)
        if visibleCount == 0 {
            #expect(after.bentoState == before.bentoState)
            #expect(after.isBentoInitialized == before.isBentoInitialized)
            #expect(system.windows.map(\.frame) == frames)
            #expect(system.frameWriteCounts == writes)
        } else {
            #expect(after.mode == .bento)
            #expect(after.isBentoInitialized)
            #expect(Set(after.bentoState.root?.windowIDs ?? []) == Set(system.windows.map(\.id)))
            #expect(BentoLayoutVerifier.overlappingWindowIDs(
                Dictionary(uniqueKeysWithValues: system.windows.map { ($0.id, $0.frame) })).isEmpty)
        }
    }

}
