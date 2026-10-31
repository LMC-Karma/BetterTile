import AppKit
import BetterTileCore
import Foundation
import Testing
@testable import BetterTileApp

@Suite(.appTestApplication, .serialized) @MainActor
struct ApplicationRecoveryObservationTests {
    struct Context: Sendable {
        let source: String
        let retainedEvent: Bool
        let roundTrip: Bool
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


    nonisolated static let readContexts = ["watchdog", "topology"].flatMap { source in
        [false, true].map { Context(source: source, retainedEvent: $0, roundTrip: false) }
    }
    @Test(arguments: readContexts, ["space", "generation", "mode", "session", "bento"])
    func recoveryReadOutsideReconciliation(context: Context, invalidation: String) async throws {
        let (system, model) = try await prepare(context)
        defer { model.shutdown() }
        let display = system.mainDisplay.id
        system.unresponsiveProcessIDs.removeAll()
        system.applicationHoldsUntil[43] = system.uptime - 0.01
        model.handleApplicationActivation()
        try #require(system.applicationHoldsUntil[43] == nil)
        var invalidated = false
        var writes = system.frameWriteCounts
        var probes = system.probeRequests
        system.onWindowSnapshots = { [weak system, weak model] in
            guard let system, let model, !invalidated else { return }
            invalidated = true
            if invalidation == "generation" { model.beginActiveSpaceStabilization() }
            else if invalidation == "mode" { model.setActiveMode(.manual) }
            else if invalidation == "bento" { model.setActiveMode(.bento) }
            else {
                system.desktopObservation?.currentSpaceByDisplay[display] = NativeSpaceID(rawValue: 2)
                system.offscreenWindowIDs = Set(system.windows.map(\.id))
                if invalidation == "session" { model.beginActiveSpaceStabilization() }
            }
            writes = system.frameWriteCounts
            probes = system.probeRequests
        }
        if context.source == "watchdog" { model.watchdog() }
        else {
            system.eventHandler?(WindowSystemEvent(kind: .created, windowID: nil, processIdentifier: 42))
            await system.joinWindowEvent(on: model)
        }
        #expect(invalidated)
        #expect(system.frameWriteCounts == writes)
        #expect(system.probeRequests == probes)
    }

    @Test(arguments: [false, true])
    func degradedRollbackSuspendsItsOriginalSession(retry: Bool) async throws {
        let (system, model) = try await prepare(Context(source: "watchdog", retainedEvent: false, roundTrip: false))
        defer { model.shutdown() }
        let display = system.mainDisplay.id
        let original = session(model, display)
        let focused = system.windows[0].id, held = system.windows[1].id
        if retry {
            system.ignoredFrameWriteWindowIDs = [focused, held]
            try await recover(Context(source: "watchdog", retainedEvent: false, roundTrip: false), system: system, model: model)
            try #require(model.settlementTasks[display] != nil)
            system.ignoredFrameWriteWindowIDs.removeAll()
        }
        let writes = system.frameWriteCounts
        let frames = system.windows.map(\.frame)
        system.failedFrameWriteNumbers[held] = [writes[held, default: 0] + 1]
        system.failedFrameWriteNumbers[focused] = [writes[focused, default: 0] + 2]
        var invalidated = false
        system.onWindowSnapshots = { [weak system, weak model] in
            guard let system, let model, !invalidated,
                system.frameWriteCounts[held, default: 0] > writes[held, default: 0] else { return }
            invalidated = true
            system.desktopObservation?.currentSpaceByDisplay[display] = NativeSpaceID(rawValue: 2)
            system.offscreenWindowIDs = Set(system.windows.map(\.id))
            model.beginActiveSpaceStabilization()
        }
        if !retry {
            try await recover(Context(source: "watchdog", retainedEvent: false, roundTrip: false), system: system, model: model)
        } else { try #require(await system.waitFor { invalidated }) }
        #expect(invalidated)
        #expect(system.windows.map(\.frame) != frames)
        #expect(system.frameWriteCounts == [focused: writes[focused, default: 0] + 1, held: writes[held, default: 0] + 1])
        #expect(model.statusMessage?.contains("Use Repair") == true)
        // No transaction touched the newly selected desktop.
        #expect(session(model, display)?.id != original?.id)
        #expect(writesAreSuspended(model, on: display) == false)
        system.onWindowSnapshots = nil
        try #require(await system.waitFor { !model.isStabilizingSpace })
        system.desktopObservation?.currentSpaceByDisplay[display] = NativeSpaceID(rawValue: 1)
        system.offscreenWindowIDs.removeAll()
        model.beginActiveSpaceStabilization()
        #expect(session(model, display)?.id == original?.id)
        #expect(writesAreSuspended(model, on: display) == true)
    }
    private func pending(_ model: BetterTileModel) -> [WindowID: Int32] {
        (Mirror(reflecting: model).children.first {
            $0.label?.hasSuffix("applicationRecoveryPendingWindows") == true
        }?.value as? [WindowID: Int32]) ?? [:]
    }

    @Test func activationReadSchedulesAutomaticReconciliationWithoutAnotherCallback() async throws {
        let (system, model) = try await prepare(Context(source: "watchdog", retainedEvent: false, roundTrip: false))
        defer { model.shutdown() }
        let held = system.windows[1].id
        system.unresponsiveProcessIDs.removeAll()
        system.applicationHoldsUntil[43] = system.uptime - 1
        model.handleApplicationActivation()
        try #require(pending(model) == [held: 43])
        try #require(await system.waitFor {
            pending(model).isEmpty && model.settlementTasks.isEmpty && system.frameWriteCounts[held] != nil
        })
        #expect(system.probeRequests == [[held]])
        #expect(Set(session(model, system.mainDisplay.id)?.bentoState.root?.windowIDs ?? []) == Set(system.windows.map(\.id)))
    }

    @Test func pendingTabbedReconciliationRetiresAfterCommitAndCurrentNoOp() async throws {
        let (system, model) = try await prepare(Context(source: "watchdog", retainedEvent: false, roundTrip: false))
        defer { model.shutdown() }
        let display = system.mainDisplay.id
        let held = system.windows[1].id
        model.setActiveMode(.tabbed)
        try #require(await system.waitFor { !model.hasPendingTabbedPlacement })
        system.unresponsiveProcessIDs.removeAll()
        system.applicationHoldsUntil[43] = system.uptime - 1
        model.handleApplicationActivation()
        try #require(pending(model) == [held: 43])
        model.processPendingWindowEvents()
        #expect(model.hasPendingTabbedPlacement)
        #expect(pending(model) == [held: 43])
        try #require(await system.waitFor { pending(model).isEmpty && !model.hasPendingTabbedPlacement })
        #expect(session(model, display)?.tabbedState?.windowIDs.contains(held) == true)
        // A later read can release a hold without changing the already adopted membership.
        system.applicationHoldsUntil[43] = system.uptime - 1
        model.handleApplicationActivation()
        try #require(pending(model) == [held: 43])
        let writes = system.frameWriteCounts, probes = system.probeRequests
        model.watchdog()
        #expect(pending(model).isEmpty)
        #expect(system.frameWriteCounts == writes)
        #expect(system.probeRequests == probes)
    }

    @Test func pendingReconciliationSurvivesFailedInventoryAndStaleAttempt() async throws {
        let (system, model) = try await prepare(Context(source: "watchdog", retainedEvent: false, roundTrip: false))
        defer { model.shutdown() }
        let held = system.windows[1].id
        system.unresponsiveProcessIDs.removeAll()
        system.applicationHoldsUntil[43] = system.uptime - 1
        model.handleApplicationActivation()
        try #require(pending(model) == [held: 43])
        system.failedVisibleWindowSweeps.insert(system.completeSweepCount + 1)
        model.watchdog()
        #expect(pending(model) == [held: 43])
        var invalidated = false
        system.onWindowSnapshots = { [weak model] in
            guard !invalidated else { return }
            invalidated = true
            model?.beginActiveSpaceStabilization()
        }
        model.watchdog()
        #expect(invalidated)
        #expect(pending(model) == [held: 43])
        system.onWindowSnapshots = nil
        try #require(await system.waitFor { !model.isStabilizingSpace })
        model.watchdog()
        try #require(await system.waitFor { pending(model).isEmpty && model.settlementTasks.isEmpty })
        let writes = system.frameWriteCounts, probes = system.probeRequests
        model.watchdog()
        #expect(system.frameWriteCounts == writes)
        #expect(system.probeRequests == probes)
    }

    @Test(arguments: [false, true])
    func pendingReconciliationRetiresAfterCurrentManualObservation(newerCommand: Bool) async throws {
        let (system, model) = try await prepare(Context(source: "watchdog", retainedEvent: false, roundTrip: false))
        defer { model.shutdown() }
        if !newerCommand { model.setActiveMode(.manual) }
        system.unresponsiveProcessIDs.removeAll()
        system.applicationHoldsUntil[43] = system.uptime - 1
        model.handleApplicationActivation()
        try #require(pending(model).count == 1)
        if newerCommand { model.setActiveMode(.manual) }
        let writes = system.frameWriteCounts, probes = system.probeRequests
        model.watchdog()
        #expect(pending(model).isEmpty)
        #expect(model.activeMode(for: system.mainDisplay.id) == .manual)
        #expect(system.frameWriteCounts == writes)
        #expect(system.probeRequests == probes)
    }

    @Test func independentReturningApplicationsReconcileOnlyOnTheirCurrentSpace() async throws {
        let (system, model) = try await prepare(Context(source: "watchdog", retainedEvent: false, roundTrip: false))
        defer { model.shutdown() }
        let display = system.mainDisplay.id
        let held = system.windows[1].id
        var other = system.windows[1]
        other.id = WindowID(rawValue: "other-held"); other.processIdentifier = 44
        system.windows.append(other)
        system.desktopObservation?.windowMembership[other.id] = [NativeSpaceID(rawValue: 2)]
        system.offscreenWindowIDs.insert(other.id)
        system.applicationHoldsUntil[44] = system.uptime + 60
        system.unresponsiveProcessIDs.removeAll()
        system.applicationHoldsUntil[43] = system.uptime - 1
        model.handleApplicationActivation()
        try #require(pending(model) == [held: 43])
        system.desktopObservation?.currentSpaceByDisplay[display] = NativeSpaceID(rawValue: 2)
        system.offscreenWindowIDs = Set(system.windows.filter { $0.id != other.id }.map(\.id))
        system.applicationHoldsUntil[44] = system.uptime - 1
        model.beginActiveSpaceStabilization()
        try #require(await system.waitFor { !model.isStabilizingSpace })
        #expect(pending(model) == [held: 43, other.id: 44])
        let writes = system.frameWriteCounts, probes = system.probeRequests
        model.watchdog()
        #expect(pending(model) == [held: 43])
        #expect(system.frameWriteCounts == writes)
        #expect(system.probeRequests == probes)
        system.desktopObservation?.currentSpaceByDisplay[display] = NativeSpaceID(rawValue: 1)
        system.offscreenWindowIDs = [other.id]
        model.beginActiveSpaceStabilization()
        try #require(await system.waitFor { !model.isStabilizingSpace })
        model.watchdog()
        try #require(await system.waitFor { pending(model).isEmpty && model.settlementTasks.isEmpty })
    }

    @Test(arguments: [false, true])
    func pendingReconciliationRetiresDestroyedWindowsDuringStabilization(processExit: Bool) async throws {
        let (system, model) = try await prepare(Context(source: "watchdog", retainedEvent: false, roundTrip: false))
        defer { model.shutdown() }
        let held = system.windows[1]
        var sibling = held; sibling.id = WindowID(rawValue: "sibling")
        system.windows.append(sibling)
        system.desktopObservation?.windowMembership[sibling.id] = [NativeSpaceID(rawValue: 1)]
        system.unresponsiveProcessIDs.removeAll()
        system.applicationHoldsUntil[43] = system.uptime - 1
        model.handleApplicationActivation()
        try #require(pending(model).count == 2)
        model.beginActiveSpaceStabilization()
        system.windows.removeAll { $0.id == held.id || (processExit && $0.processIdentifier == 43) }
        system.eventHandler?(WindowSystemEvent(kind: .destroyed, windowID: held.id, processIdentifier: 43))
        if processExit {
            system.eventHandler?(WindowSystemEvent(kind: .destroyed, windowID: sibling.id, processIdentifier: 43))
        }
        #expect(pending(model) == (processExit ? [:] : [sibling.id: 43]))
        var replacement = held; replacement.id = WindowID(rawValue: "replacement")
        system.windows.append(replacement)
        #expect(pending(model)[replacement.id] == nil)
        model.shutdown()
        #expect(pending(model).isEmpty)
    }

    private func session(_ model: BetterTileModel, _ display: DisplayID) -> LayoutSession? {
        let store = Mirror(reflecting: model).children.first { $0.label?.hasSuffix("sessionStore") == true }?.value as? LayoutSessionStore
        return store?.session(for: display)
    }
}
