import AppKit
import BetterTileCore
import Foundation
import Testing
@testable import BetterTileApp

@Suite(.appTestApplication, .serialized) @MainActor
struct ApplicationRecoveryFirstNativeSelectionTests {
    private func retained(_ model: BetterTileModel) -> [WindowID: Int32] {
        Mirror(reflecting: model).children.first { $0.label?.hasSuffix("applicationRecoveryFrameEventPIDs") == true }?.value as? [WindowID: Int32] ?? [:]
    }
    private func pending(_ model: BetterTileModel) -> [WindowID: Int32] {
        Mirror(reflecting: model).children.first {
            $0.label?.hasSuffix("applicationRecoveryPendingWindows") == true
        }?.value as? [WindowID: Int32] ?? [:]
    }
    private func store(_ model: BetterTileModel) -> LayoutSessionStore? {
        Mirror(reflecting: model).children.first { $0.label?.hasSuffix("sessionStore") == true }?.value as? LayoutSessionStore
    }
    private func prepareCapability(native: Bool, frameEvent: Bool = true) async throws -> (FakeAppWindowSystem, BetterTileModel, NativeDesktopObservation) {
        _ = NSApplication.shared
        let system = makeManualWindowSystem()
        system.applicationHoldDuration = 60
        system.cachedSnapshotsAvailable = false
        let display = system.mainDisplay.id
        let held = WindowID(rawValue: "held")
        system.windows.append(WindowSnapshot(id: held, processIdentifier: 43,
            frame: BTRect(x: 0, y: 0, width: 500, height: 800), displayID: display))
        let observation = NativeDesktopObservation(currentSpaceByDisplay: [display: NativeSpaceID(rawValue: 1)],
            knownSpacesByDisplay: [display: [NativeSpaceID(rawValue: 1)]],
            windowMembership: Dictionary(uniqueKeysWithValues: system.windows.map { ($0.id, [NativeSpaceID(rawValue: 1)]) }))
        system.desktopObservation = native ? observation : nil
        system.unresponsiveProcessIDs = [43]
        let model = makeModel(system: system)
        model.primaryButtonIsPressed = { false }
        model.configuration.defaultLayoutMode = .bento
        model.setActiveMode(.bento)
        try #require(await system.waitFor { model.settlementTasks.isEmpty })
        if frameEvent {
            system.eventHandler?(WindowSystemEvent(kind: .resized, windowID: held, processIdentifier: 43))
            await system.joinWindowEvent(on: model)
            try #require(retained(model) == [held: 43])
        }
        system.unresponsiveProcessIDs.removeAll()
        system.applicationHoldsUntil[43] = system.uptime - 1
        return (system, model, observation)
    }

    private func prepareDegraded() async throws -> (FakeAppWindowSystem, BetterTileModel, NativeDesktopObservation) {
        _ = NSApplication.shared
        let system = makeManualWindowSystem()
        system.applicationHoldDuration = 60
        system.cachedSnapshotsAvailable = false
        let display = system.mainDisplay.id, focused = system.windows[0].id, held = WindowID(rawValue: "held")
        system.windows.append(WindowSnapshot(id: held, processIdentifier: 43,
            frame: BTRect(x: 300, y: 200, width: 600, height: 400), displayID: display))
        let observation = NativeDesktopObservation(currentSpaceByDisplay: [display: NativeSpaceID(rawValue: 1)],
            knownSpacesByDisplay: [display: [NativeSpaceID(rawValue: 1)]],
            windowMembership: Dictionary(uniqueKeysWithValues: system.windows.map { ($0.id, [NativeSpaceID(rawValue: 1)]) }))
        let model = makeModel(system: system)
        model.primaryButtonIsPressed = { false }
        model.configuration.defaultLayoutMode = .bento
        model.configuration.bentoInnerGap = 0
        model.setActiveMode(.bento)
        try #require(await system.waitFor { model.settlementTasks.isEmpty })
        system.unresponsiveProcessIDs = [43]
        system.applicationHoldsUntil[43] = system.uptime + 60
        system.windows[1].frame = BTRect(x: 0, y: 0, width: 500, height: 800)
        system.eventHandler?(WindowSystemEvent(kind: .resized, windowID: held, processIdentifier: 43))
        await system.joinWindowEvent(on: model)
        let initial = system.frameWriteCounts
        system.failedFrameWriteNumbers[held] = [initial[held, default: 0] + 1]
        system.failedFrameWriteNumbers[focused] = [initial[focused, default: 0] + 2]
        system.unresponsiveProcessIDs.removeAll()
        system.applicationHoldsUntil[43] = system.uptime - 1
        model.handleApplicationTopologyChange()
        await system.joinWindowEvent(on: model)
        try #require(await system.waitFor { model.settlementTasks.isEmpty })
        let original = try #require(store(model)?.session(for: display))
        try #require(original.automaticWritesSuspended)
        try #require(retained(model) == [held: 43])
        system.failedFrameWriteNumbers.removeAll()
        system.windows[1].frame = BTRect(x: 0, y: 0, width: 1000, height: 400)
        return (system, model, observation)
    }

    private func expectQuiet(_ system: FakeAppWindowSystem) async throws {
        let writes = system.frameWriteCounts, probes = system.probeRequests, sweeps = system.completeSweepCount
        await system.advance(by: .milliseconds(850))
        #expect(system.frameWriteCounts == writes)
        #expect(system.probeRequests == probes)
        #expect(system.completeSweepCount == sweeps)
    }

    @Test(arguments: [false, true])
    func manualSurvivesFirstNativeSelection(transition: Bool) async throws {
        let (system, model, observation) = try await prepareCapability(native: false)
        defer { model.shutdown() }
        system.unresponsiveProcessIDs = [43]
        system.applicationHoldsUntil[43] = system.uptime + 60
        model.setActiveMode(.manual)
        let original = try #require(store(model)?.session(for: system.mainDisplay.id))
        try #require(original.mode == .manual)
        let writes = system.frameWriteCounts, frames = system.windows.map(\.frame), probes = system.probeRequests
        system.unresponsiveProcessIDs.removeAll()
        system.applicationHoldsUntil[43] = system.uptime - 1
        system.desktopObservation = observation
        if transition {
            model.beginActiveSpaceStabilization()
            #expect(store(model)?.session(for: system.mainDisplay.id)?.id == original.id)
            #expect(store(model)?.session(for: system.mainDisplay.id)?.nativeSpaceID == nil)
            try #require(await system.waitFor { !model.isStabilizingSpace })
        } else { model.handleApplicationTopologyChange() }
        await system.joinWindowEvent(on: model)
        try #require(await system.waitFor { model.settlementTasks.isEmpty })
        let final = try #require(store(model)?.session(for: system.mainDisplay.id))
        #expect(final.id == original.id)
        #expect(final.nativeSpaceID == NativeSpaceID(rawValue: 1))
        #expect(final.automaticWritesSuspended == original.automaticWritesSuspended)
        #expect(final.mode == .manual)
        #expect(system.frameWriteCounts == writes)
        #expect(system.windows.map(\.frame) == frames)
        #expect(system.probeRequests == probes)
        try await expectQuiet(system)
    }

    @Test(arguments: [false, true], ["settlement", "retry"])
    func delayedCapabilityInvalidation(native: Bool, stage: String) async throws {
        let (system, model, observation) = try await prepareCapability(native: native, frameEvent: stage == "settlement")
        defer { model.shutdown() }
        if stage == "retry" { system.ignoredFrameWriteWindowIDs = [system.windows[1].id] }
        model.handleApplicationTopologyChange()
        try #require(model.settlementTasks[system.mainDisplay.id] != nil)
        if stage == "settlement" {
            system.windows[0].frame.size.width = 600
            system.windows[0].constraints.minimumSize.width = 600
        }
        let writes = system.frameWriteCounts, probes = system.probeRequests
        var switched = false
        system.onWindowSnapshots = { [weak system] in
            guard let system, !switched else { return }
            switched = true
            system.desktopObservation = native ? nil : observation
        }
        try #require(await system.waitFor { model.settlementTasks.isEmpty })
        #expect(switched)
        #expect(system.frameWriteCounts == writes)
        #expect(system.probeRequests == probes)
        await system.joinWindowEvent(on: model)
        try await expectQuiet(system)
    }
    @Test(arguments: [false, true])
    func suspensionSurvivesFirstNativeSelection(transition: Bool) async throws {
        let (system, model, observation) = try await prepareDegraded()
        defer { model.shutdown() }
        let display = system.mainDisplay.id, held = system.windows[1].id
        let original = try #require(store(model)?.session(for: display))
        let writes = system.frameWriteCounts, frames = system.windows.map(\.frame), probes = system.probeRequests
        system.desktopObservation = observation
        if transition {
            model.beginActiveSpaceStabilization()
            #expect(store(model)?.session(for: system.mainDisplay.id)?.id == original.id)
            #expect(store(model)?.session(for: system.mainDisplay.id)?.nativeSpaceID == nil)
            try #require(await system.waitFor { !model.isStabilizingSpace })
        } else { model.handleApplicationTopologyChange() }
        await system.joinWindowEvent(on: model)
        try #require(await system.waitFor { model.settlementTasks.isEmpty })
        let final = try #require(store(model)?.session(for: display))
        #expect(final.id == original.id)
        #expect(final.nativeSpaceID == NativeSpaceID(rawValue: 1))
        #expect(final.mode == original.mode)
        #expect(final.automaticWritesSuspended)
        #expect(system.frameWriteCounts == writes)
        #expect(system.windows.map(\.frame) == frames)
        #expect(retained(model) == [held: 43])
        #expect(system.probeRequests == probes)
        try await expectQuiet(system)
    }

    @Test(arguments: [false, true], [false, true])
    func unrelatedNewNativeDesktopKeepsSeparateState(degraded: Bool, discardFirstObservation: Bool) async throws {
        let (system, model, observation) = try await degraded ? prepareDegraded() : prepareCapability(native: false)
        defer { model.shutdown() }
        if !degraded {
            system.unresponsiveProcessIDs = [43]
            system.applicationHoldsUntil[43] = system.uptime + 60
            model.setActiveMode(.manual)
        }
        let display = system.mainDisplay.id
        let original = try #require(store(model)?.session(for: display))
        let oldIDs = Set(system.windows.map(\.id)), before = system.frameWriteCounts
        let oldFrames = system.windows.map(\.frame), probes = system.probeRequests
        if discardFirstObservation {
            system.desktopObservation = observation
            model.beginActiveSpaceStabilization()
            #expect(store(model)?.session(for: display)?.id == original.id)
            #expect(store(model)?.session(for: display)?.nativeSpaceID == nil)
            #expect(system.frameWriteCounts == before)
        }
        system.offscreenWindowIDs = oldIDs
        let newID = WindowID(rawValue: "new-desktop-window")
        system.windows.append(WindowSnapshot(id: newID, processIdentifier: 44,
            frame: BTRect(x: 200, y: 100, width: 600, height: 400), displayID: display))
        system.focusedID = newID
        let first = NativeSpaceID(rawValue: 1), second = NativeSpaceID(rawValue: 2)
        system.desktopObservation = NativeDesktopObservation(currentSpaceByDisplay: [display: second],
            knownSpacesByDisplay: [display: [first, second]],
            windowMembership: Dictionary(uniqueKeysWithValues: system.windows.map { ($0.id, [$0.id == newID ? second : first]) }))
        model.beginActiveSpaceStabilization()
        try #require(await system.waitFor { !model.isStabilizingSpace })
        await system.joinWindowEvent(on: model)
        try #require(await system.waitFor { model.settlementTasks.isEmpty })
        let final = try #require(store(model)?.session(for: display))
        #expect(final.id != original.id)
        #expect(final.nativeSpaceID == second)
        #expect(final.mode == .bento)
        let storedOriginal = try #require(store(model)?.allSessions(for: display).first { $0.id == original.id })
        #expect(storedOriginal.mode == original.mode)
        #expect(storedOriginal.automaticWritesSuspended == original.automaticWritesSuspended)
        #expect(storedOriginal.nativeSpaceID == nil)
        #expect(!final.automaticWritesSuspended)
        #expect(system.windows.filter { oldIDs.contains($0.id) }.map(\.frame) == oldFrames)
        #expect(system.probeRequests == probes)
        #expect(system.frameWriteCounts[newID] == 1)
        #expect(system.windows.last?.frame == system.mainDisplay.visibleFrame)
        #expect(system.frameWriteCounts.filter { oldIDs.contains($0.key) } == before)
        #expect(retained(model) == [WindowID(rawValue: "held"): 43])
        try await expectQuiet(system)
    }

    @Test(arguments: ["hold", "pending", "retained"], [false, true])
    func manualBindingUsesEachRecoverySignal(evidence: String, transition: Bool) async throws {
        let (system, model, observation) = try await prepareCapability(native: false, frameEvent: evidence == "retained")
        defer { model.shutdown() }
        let display = system.mainDisplay.id, held = system.windows[1].id
        system.unresponsiveProcessIDs = [43]
        system.applicationHoldsUntil[43] = system.uptime + 60
        model.setActiveMode(.manual)
        let original = try #require(store(model)?.session(for: display))
        system.unresponsiveProcessIDs.removeAll()
        system.applicationHoldsUntil[43] = system.uptime - 1
        if evidence == "pending" {
            model.handleApplicationActivation()
            try #require(pending(model) == [held: 43])
            try #require(retained(model).isEmpty)
            try #require(system.unresponsiveApplicationRecoveryDeadlines.isEmpty)
        } else if evidence == "retained" {
            // A completed adapter read can release the gate before model reconciliation.
            _ = try system.visibleWindows()
            try #require(pending(model).isEmpty)
            try #require(retained(model) == [held: 43])
            try #require(system.unresponsiveApplicationRecoveryDeadlines.isEmpty)
        } else {
            try #require(pending(model).isEmpty && retained(model).isEmpty)
            try #require(!system.unresponsiveApplicationRecoveryDeadlines.isEmpty)
        }
        let writes = system.frameWriteCounts, frames = system.windows.map(\.frame), probes = system.probeRequests
        system.desktopObservation = observation
        if transition {
            model.beginActiveSpaceStabilization()
            #expect(store(model)?.session(for: system.mainDisplay.id)?.id == original.id)
            #expect(store(model)?.session(for: system.mainDisplay.id)?.nativeSpaceID == nil)
            try #require(await system.waitFor { !model.isStabilizingSpace })
        } else { model.handleApplicationTopologyChange() }
        await system.joinWindowEvent(on: model)
        try #require(await system.waitFor { model.settlementTasks.isEmpty })
        let final = try #require(store(model)?.session(for: display))
        #expect(final.id == original.id)
        #expect(final.nativeSpaceID == NativeSpaceID(rawValue: 1))
        #expect(final.mode == original.mode)
        #expect(final.automaticWritesSuspended == original.automaticWritesSuspended)
        #expect(system.frameWriteCounts == writes)
        #expect(system.windows.map(\.frame) == frames)
        #expect(system.probeRequests == probes)
        #expect(pending(model).isEmpty && retained(model).isEmpty)
        try await expectQuiet(system)
    }

    @Test
    func establishedExactSessionWinsOverRecoveringInferredSession() async throws {
        _ = NSApplication.shared
        let system = makeManualWindowSystem()
        system.cachedSnapshotsAvailable = false
        system.applicationHoldDuration = 60
        let display = system.mainDisplay.id, space = NativeSpaceID(rawValue: 1)
        let oldID = system.windows[0].id
        system.desktopObservation = NativeDesktopObservation(currentSpaceByDisplay: [display: space],
            knownSpacesByDisplay: [display: [space]], windowMembership: [oldID: [space]])
        let model = makeModel(system: system)
        defer { model.shutdown() }
        model.primaryButtonIsPressed = { false }
        model.configuration.defaultLayoutMode = .bento
        model.setActiveMode(.manual)
        let exact = try #require(store(model)?.session(for: display))
        try #require(exact.nativeSpaceID == space && exact.mode == .manual)
        let peer = WindowID(rawValue: "public-peer"), held = WindowID(rawValue: "held")
        system.windows += [
            WindowSnapshot(id: peer, processIdentifier: 44,
                frame: BTRect(x: 100, y: 100, width: 600, height: 400), displayID: display),
            WindowSnapshot(id: held, processIdentifier: 43,
                frame: BTRect(x: 0, y: 0, width: 500, height: 800), displayID: display)
        ]
        system.focusedID = peer
        system.offscreenWindowIDs = [oldID]
        system.desktopObservation = nil
        system.unresponsiveProcessIDs = [43]
        model.beginActiveSpaceStabilization()
        try #require(await system.waitFor { !model.isStabilizingSpace })
        await system.joinWindowEvent(on: model)
        try #require(await system.waitFor { model.settlementTasks.isEmpty })
        let inferred = try #require(store(model)?.session(for: display))
        try #require(inferred.id != exact.id && inferred.nativeSpaceID == nil && inferred.mode == .bento)
        await system.advance(by: .milliseconds(320))
        system.eventHandler?(WindowSystemEvent(kind: .resized, windowID: held, processIdentifier: 43))
        await system.joinWindowEvent(on: model)
        try #require(retained(model) == [held: 43])
        system.unresponsiveProcessIDs.removeAll()
        system.applicationHoldsUntil[43] = system.uptime - 1
        system.desktopObservation = NativeDesktopObservation(currentSpaceByDisplay: [display: space],
            knownSpacesByDisplay: [display: [space]],
            windowMembership: Dictionary(uniqueKeysWithValues: system.windows.map { ($0.id, [space]) }))
        let writes = system.frameWriteCounts, frames = system.windows.map(\.frame), probes = system.probeRequests
        model.beginActiveSpaceStabilization()
        #expect(store(model)?.session(for: display)?.id == exact.id)
        try #require(await system.waitFor { !model.isStabilizingSpace })
        await system.joinWindowEvent(on: model)
        try #require(await system.waitFor { model.settlementTasks.isEmpty })
        let final = try #require(store(model)?.session(for: display))
        #expect(final.id == exact.id)
        #expect(final.mode == exact.mode)
        #expect(final.automaticWritesSuspended == exact.automaticWritesSuspended)
        #expect(store(model)?.allSessions(for: display).first { $0.id == inferred.id }?.nativeSpaceID == nil)
        #expect(system.frameWriteCounts == writes)
        #expect(system.windows.map(\.frame) == frames)
        #expect(system.probeRequests == probes)
        try await expectQuiet(system)
    }

}
