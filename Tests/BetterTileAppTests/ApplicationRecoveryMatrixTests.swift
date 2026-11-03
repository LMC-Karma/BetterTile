import AppKit
import BetterTileCore
import Foundation
import Testing
@testable import BetterTileApp

@Suite(.appTestApplication, .serialized) @MainActor
struct ApplicationRecoveryMatrixTests {
    struct Context: Sendable {
        let source: String
        let retainedEvent: Bool
        let roundTrip: Bool
    }
    nonisolated static let contexts = ["timer", "topology", "watchdog"].flatMap { source in
        [false, true].flatMap { retained in
            [false, true].map { Context(source: source, retainedEvent: retained, roundTrip: $0) }
        }
    }

    private func store(_ model: BetterTileModel) -> LayoutSessionStore? {
        Mirror(reflecting: model).children.first { $0.label?.hasSuffix("sessionStore") == true }?.value as? LayoutSessionStore
    }

    private func writesAreSuspended(_ model: BetterTileModel, on display: DisplayID) -> Bool? {
        let store = Mirror(reflecting: model).children.first {
            $0.label?.hasSuffix("sessionStore") == true
        }?.value as? LayoutSessionStore
        return store?.session(for: display)?.automaticWritesSuspended
    }

    private func prepare(_ context: Context) async throws -> (FakeAppWindowSystem, BetterTileModel) {
        _ = NSApplication.shared
        let system = makeManualWindowSystem()
        system.applicationHoldDuration = 60
        system.cachedSnapshotsAvailable = false
        system.windows.append(WindowSnapshot(id: WindowID(rawValue: "held"), processIdentifier: 43,
            frame: BTRect(x: 300, y: 200, width: 600, height: 400), displayID: system.mainDisplay.id))
        system.unresponsiveProcessIDs = [43]
        let display = system.mainDisplay.id
        let first = NativeSpaceID(rawValue: 1), second = NativeSpaceID(rawValue: 2)
        system.desktopObservation = NativeDesktopObservation(currentSpaceByDisplay: [display: first],
            knownSpacesByDisplay: [display: [first, second]],
            windowMembership: Dictionary(uniqueKeysWithValues: system.windows.map { ($0.id, [first]) }))
        let model = makeModel(system: system)
        model.configuration.defaultLayoutMode = .manual
        model.configuration.singleWindowPlacement = nil
        model.setActiveMode(.bento)
        if context.retainedEvent {
            system.eventHandler?(WindowSystemEvent(kind: .moved, windowID: system.windows[1].id, processIdentifier: 43))
            await system.joinWindowEvent(on: model)
        }
        if context.roundTrip {
            system.desktopObservation?.currentSpaceByDisplay[display] = second
            system.offscreenWindowIDs = Set(system.windows.map(\.id))
            model.beginActiveSpaceStabilization()
            try #require(await system.waitFor { !model.isStabilizingSpace })
            system.desktopObservation?.currentSpaceByDisplay[display] = first
            system.offscreenWindowIDs.removeAll()
            model.beginActiveSpaceStabilization()
            try #require(await system.waitFor { !model.isStabilizingSpace })
        }
        return (system, model)
    }

    private func recover(_ context: Context, system: FakeAppWindowSystem, model: BetterTileModel) async throws {
        system.unresponsiveProcessIDs.removeAll()
        if context.source == "timer" {
            system.applicationHoldsUntil[43] = system.uptime + 0.02
            model.watchdog()
            try #require(await system.waitFor { system.applicationHoldsUntil[43] == nil })
        } else {
            system.applicationHoldsUntil[43] = system.uptime - 0.01
            if context.source == "watchdog" { model.watchdog() }
            else {
                system.eventHandler?(WindowSystemEvent(kind: .created, windowID: nil, processIdentifier: 42))
                await system.joinWindowEvent(on: model)
            }
        }
    }

    @Test(arguments: contexts, ["space", "generation", "mode", "session"])
    func recoveryRejectsInvalidationDuringProbePreflight(context: Context, invalidation: String) async throws {
        let (system, model) = try await prepare(context)
        defer { model.shutdown() }
        let display = system.mainDisplay.id
        var invalidated = false
        var expectedWrites = system.frameWriteCounts
        var expectedProbes = system.probeRequests
        system.onWindowSnapshots = { [weak system, weak model] in
            guard let system, let model, !invalidated, system.applicationHoldsUntil[43] == nil else { return }
            invalidated = true
            switch invalidation {
            case "generation": model.beginActiveSpaceStabilization()
            case "mode": model.setActiveMode(.manual)
            default:
                system.desktopObservation?.currentSpaceByDisplay[display] = NativeSpaceID(rawValue: 2)
                system.offscreenWindowIDs = Set(system.windows.map(\.id))
                if invalidation == "session" { model.beginActiveSpaceStabilization() }
            }
            // A newer mode command owns its own reconciliation.
            expectedWrites = system.frameWriteCounts
            expectedProbes = system.probeRequests
        }
        try await recover(context, system: system, model: model)
        #expect(invalidated)
        #expect(system.probeRequests == expectedProbes)
        #expect(system.frameWriteCounts == expectedWrites)
        #expect(writesAreSuspended(model, on: display) == false)
        if invalidation == "mode" { #expect(model.activeMode(for: display) == .manual) }
    }

    @Test(arguments: contexts, ["failed", "degraded", "staleFailed", "staleDegraded", "sessionFailed", "sessionDegraded"])
    func recoveryPreservesRollbackOutcome(context: Context, outcome: String) async throws {
        let (system, model) = try await prepare(context)
        defer { model.shutdown() }
        let display = system.mainDisplay.id
        let focused = system.windows[0].id, held = system.windows[1].id
        let writes = system.frameWriteCounts
        let probes = system.probeRequests
        let frames = system.windows.map(\.frame)
        let originalSessionID = store(model)?.session(for: display)?.id
        let rollbackFails = outcome.lowercased().hasSuffix("degraded")
        let selectsSession = outcome.hasPrefix("session")
        let stale = outcome.hasPrefix("stale") || selectsSession
        let degraded = rollbackFails || stale
        system.failedFrameWriteNumbers[held] = [writes[held, default: 0] + 1]
        if rollbackFails { system.failedFrameWriteNumbers[focused] = [writes[focused, default: 0] + 2] }
        var invalidated = false
        system.onWindowSnapshots = { [weak system, weak model] in
            guard stale, let system, let model, !invalidated,
                  system.frameWriteCounts[held, default: 0] > writes[held, default: 0] else { return }
            invalidated = true
            if selectsSession {
                system.desktopObservation?.currentSpaceByDisplay[display] = NativeSpaceID(rawValue: 2)
                system.offscreenWindowIDs = Set(system.windows.map(\.id))
            }
            model.beginActiveSpaceStabilization()
        }
        try await recover(context, system: system, model: model)
        #expect(invalidated == stale)
        #expect(system.probeRequests == probes + [[held]])
        // Losing ownership refuses rollback even when its write would succeed.
        #expect(system.frameWriteCounts == [focused: writes[focused, default: 0] + (stale ? 1 : 2),
                                          held: writes[held, default: 0] + 1])
        #expect((system.windows.map(\.frame) != frames) == degraded)
        let needsRepair = degraded
        #expect((model.statusMessage?.contains("Use Repair") == true) == needsRepair)
        #expect(store(model)?.allSessions(for: display).first { $0.id == originalSessionID }?.automaticWritesSuspended == needsRepair)
        if selectsSession { #expect(writesAreSuspended(model, on: display) == false) }
        system.onWindowSnapshots = nil
        if stale { try #require(await system.waitFor { !model.isStabilizingSpace }) }
        let terminalWrites = system.frameWriteCounts
        let terminalProbes = system.probeRequests
        model.watchdog()
        if needsRepair {
            #expect(system.frameWriteCounts == terminalWrites)
            #expect(system.probeRequests == terminalProbes)
        }
    }

    @Test(arguments: [1, 2, 3], ["space", "generation", "mode", "session"])
    func recoveryRetryRejectsInvalidationDuringPreflight(targetRead: Int, invalidation: String) async throws {
        let context = Context(source: "watchdog", retainedEvent: false, roundTrip: false)
        let (system, model) = try await prepare(context)
        defer { model.shutdown() }
        let display = system.mainDisplay.id
        system.ignoredFrameWriteWindowIDs = [system.windows[1].id]
        try await recover(context, system: system, model: model)
        try #require(model.settlementTasks[display] != nil)
        var reads = 0
        var writesAtSwitch: [WindowID: Int]?
        let probes = system.probeRequests
        system.onWindowSnapshots = { [weak system, weak model] in
            guard let system, let model, writesAtSwitch == nil else { return }
            reads += 1
            guard reads == targetRead else { return }
            writesAtSwitch = system.frameWriteCounts
            if invalidation == "generation" { model.beginActiveSpaceStabilization() }
            else if invalidation == "mode" { model.setActiveMode(.manual) }
            else {
                system.desktopObservation?.currentSpaceByDisplay[display] = NativeSpaceID(rawValue: 2)
                system.offscreenWindowIDs = Set(system.windows.map(\.id))
                if invalidation == "session" { model.beginActiveSpaceStabilization() }
            }
            writesAtSwitch = system.frameWriteCounts
        }
        try #require(await system.waitFor { model.settlementTasks.isEmpty })
        let writes = try #require(writesAtSwitch)
        #expect(system.frameWriteCounts == writes)
        #expect(system.probeRequests == probes)
    }

    @Test(arguments: [false, true], ["current", "generation", "session"])
    func recoveryRetryPreservesRollbackOutcome(degraded: Bool, invalidation: String) async throws {
        let context = Context(source: "watchdog", retainedEvent: false, roundTrip: false)
        let (system, model) = try await prepare(context)
        defer { model.shutdown() }
        let display = system.mainDisplay.id
        let focused = system.windows[0].id, held = system.windows[1].id
        system.ignoredFrameWriteWindowIDs = [focused, held]
        try await recover(context, system: system, model: model)
        try #require(model.settlementTasks[display] != nil)
        system.ignoredFrameWriteWindowIDs.removeAll()
        let frames = system.windows.map(\.frame)
        let writes = system.frameWriteCounts
        let probes = system.probeRequests
        system.failedFrameWriteNumbers[held] = [writes[held, default: 0] + 1]
        if degraded { system.failedFrameWriteNumbers[focused] = [writes[focused, default: 0] + 2] }
        let invalidatesGeneration = invalidation != "current"
        let originalSessionID = store(model)?.session(for: display)?.id
        var invalidated = false
        system.onWindowSnapshots = { [weak system, weak model] in
            guard invalidatesGeneration, let system, let model, !invalidated,
                  system.frameWriteCounts[held, default: 0] > writes[held, default: 0] else { return }
            invalidated = true
            if invalidation == "session" {
                system.desktopObservation?.currentSpaceByDisplay[display] = NativeSpaceID(rawValue: 2)
                system.offscreenWindowIDs = Set(system.windows.map(\.id))
            }
            model.beginActiveSpaceStabilization()
        }
        try #require(await system.waitFor { model.settlementTasks.isEmpty })
        #expect(invalidated == invalidatesGeneration)
        #expect(system.frameWriteCounts == [focused: writes[focused, default: 0] + (invalidatesGeneration ? 1 : 2),
                                          held: writes[held, default: 0] + 1])
        #expect(system.probeRequests == probes)
        let needsRepair = degraded || invalidatesGeneration
        #expect((system.windows.map(\.frame) != frames) == needsRepair)
        #expect((model.statusMessage?.contains("Use Repair") == true) == needsRepair)
        #expect(store(model)?.allSessions(for: display).first { $0.id == originalSessionID }?.automaticWritesSuspended == needsRepair)
        if invalidation == "session" { #expect(writesAreSuspended(model, on: display) == false) }
    }
}
