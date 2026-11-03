import AppKit
import BetterTileCore
import Foundation
import Testing
@testable import BetterTileApp

@Suite(.appTestApplication, .serialized) @MainActor
struct ApplicationRecoveryEventLifecycleTests {
    @Test(arguments: [false, true], ["known", "unknown", "public"])
    func retainedSnapWhenAppRecoversOnOtherSpace(recoverWhileAway: Bool, membership: String) async throws {
        _ = NSApplication.shared
        let system = makeManualWindowSystem()
        system.applicationHoldDuration = 60
        let held = WindowSnapshot(id: WindowID(rawValue: "held"), processIdentifier: 43,
            frame: BTRect(x: 300, y: 200, width: 600, height: 400), displayID: system.mainDisplay.id)
        system.windows.append(held)
        system.unresponsiveProcessIDs = [43]
        system.cachedSnapshotsAvailable = false
        let display = system.mainDisplay.id
        let first = NativeSpaceID(rawValue: 1), second = NativeSpaceID(rawValue: 2)
        system.desktopObservation = NativeDesktopObservation(currentSpaceByDisplay: [display: first],
            knownSpacesByDisplay: [display: [first, second]],
            windowMembership: Dictionary(uniqueKeysWithValues: system.windows.map { ($0.id, [first]) }))
        if membership == "unknown" { system.desktopObservation?.windowMembership[held.id] = [] }
        if membership == "public" { system.desktopObservation = nil }
        let model = makeModel(system: system)
        defer { model.shutdown() }
        model.configuration.defaultLayoutMode = .manual
        model.primaryButtonIsPressed = { false }
        model.setActiveMode(.bento)
        let requested = BTRect(x: 0, y: 0, width: 500, height: 800)
        system.windows[1].frame = requested
        system.eventHandler?(WindowSystemEvent(kind: .resized, windowID: held.id, processIdentifier: 43))
        await system.joinWindowEvent(on: model)
        system.desktopObservation?.currentSpaceByDisplay[display] = second
        // Without native Space IDs, keep the overlap anchor visible so the
        // public fallback can match the supported inferred session.
        system.offscreenWindowIDs = membership == "public" ? [held.id] : Set(system.windows.map(\.id))
        model.beginActiveSpaceStabilization()
        try #require(await system.waitFor { !model.isStabilizingSpace })
        if recoverWhileAway {
            system.unresponsiveProcessIDs.removeAll()
            system.applicationHoldsUntil[43] = system.uptime - 1
            model.watchdog()
            system.eventHandler?(WindowSystemEvent(kind: .created, windowID: nil, processIdentifier: 42))
            await system.joinWindowEvent(on: model)
            #expect(retained(model) == [held.id: 43])
            #expect(system.applicationHoldsUntil[43] == nil)
            #expect(system.frameWriteCounts == [system.windows[0].id: 1])
            #expect(system.probeRequests.isEmpty)
        }
        system.desktopObservation?.currentSpaceByDisplay[display] = first
        system.offscreenWindowIDs.removeAll()
        model.beginActiveSpaceStabilization()
        try #require(await system.waitFor { !model.isStabilizingSpace })
        try #require(model.activeMode(for: display) == .bento)
        system.unresponsiveProcessIDs.removeAll()
        if !recoverWhileAway { system.applicationHoldsUntil[43] = system.uptime - 0.01 }
        model.watchdog()
        // A later ordinary topology event must not replace the retained native intent.
        system.eventHandler?(WindowSystemEvent(kind: .created, windowID: nil, processIdentifier: 42))
        await system.joinWindowEvent(on: model)
        try #require(await system.waitFor { system.frameWriteCounts[held.id] != nil && model.settlementTasks.isEmpty })
        // Manual's sweep before Adaptive no longer places the lone eligible window, so it writes once less.
        #expect(system.frameWriteCounts == [system.windows[0].id: 2, held.id: 2])
        #expect(system.probeRequests.isEmpty)
        #expect(system.windows[1].frame == BTRect(x: 0, y: 0, width: 500, height: 800))
        #expect(retained(model).isEmpty)
        #expect(system.windows[1].frame.approximatelyEquals(requested, tolerance: 1), "Retained snap must survive Space stabilization clearing the ordinary event buffer")
    }
    private func retained(_ model: BetterTileModel) -> [WindowID: Int32] {
        Mirror(reflecting: model).children.first { $0.label?.hasSuffix("applicationRecoveryFrameEventPIDs") == true }?.value as? [WindowID: Int32] ?? [:]
    }

    @Test(arguments: [false, true])
    func destroyedHeldEvidenceDuringStabilization(stabilizing: Bool) async throws {
        _ = NSApplication.shared
        let system = makeManualWindowSystem()
        system.applicationHoldDuration = 60
        let held = WindowID(rawValue: "held")
        let sibling = WindowID(rawValue: "sibling")
        for id in [held, sibling] {
            system.windows.append(WindowSnapshot(id: id, processIdentifier: 43,
                frame: BTRect(x: 300, y: 200, width: 600, height: 400), displayID: system.mainDisplay.id))
        }
        system.unresponsiveProcessIDs = [43]
        system.cachedSnapshotsAvailable = false
        let model = makeModel(system: system)
        defer { model.shutdown() }
        model.primaryButtonIsPressed = { false }
        model.setActiveMode(.bento)
        system.eventHandler?(WindowSystemEvent(kind: .moved, windowID: held, processIdentifier: 43))
        await system.joinWindowEvent(on: model)
        try #require(retained(model)[held] == 43)
        if stabilizing { model.beginActiveSpaceStabilization() }
        system.windows.removeAll { $0.id == held }
        system.eventHandler?(WindowSystemEvent(kind: .destroyed, windowID: held, processIdentifier: 43))
        #expect(retained(model)[held] == nil)
        if stabilizing { try #require(await system.waitFor { !model.isStabilizingSpace }) }
        else { await system.joinWindowEvent(on: model) }
        system.eventHandler?(WindowSystemEvent(kind: .created, windowID: nil, processIdentifier: 42))
        await system.joinWindowEvent(on: model)
        #expect(retained(model)[held] == nil)
        // Readiness for the nil-ID creation must finish before testing an isolated targeted read.
        try await waitForWindowEventsToDrain(model, system)
        #expect(retained(model)[held] == nil)
        // Space-animation suppression is independent of arrival readiness.
        await system.advance(by: .milliseconds(320))
        system.cachedSnapshotsAvailable = true
        let focused = system.windows[0].id
        let sweeps = system.completeSweepCount
        system.eventHandler?(WindowSystemEvent(kind: .resized, windowID: focused, processIdentifier: 42))
        await system.joinWindowEvent(on: model)
        #expect(system.cachedRefreshRequests.last == [focused])
        #expect(system.completeSweepCount == sweeps + 1)
    }
    @Test func retainedSnapSurvivesFailedInventoryAndUsesLatestFrame() async throws {
        _ = NSApplication.shared
        let system = makeManualWindowSystem()
        system.applicationHoldDuration = 60
        let held = WindowID(rawValue: "held")
        system.windows.append(WindowSnapshot(id: held, processIdentifier: 43,
            frame: BTRect(x: 0, y: 0, width: 500, height: 800), displayID: system.mainDisplay.id))
        system.unresponsiveProcessIDs = [43]
        system.cachedSnapshotsAvailable = false
        let model = makeModel(system: system)
        defer { model.shutdown() }
        model.primaryButtonIsPressed = { false }
        model.setActiveMode(.bento)
        system.eventHandler?(WindowSystemEvent(kind: .resized, windowID: held, processIdentifier: 43))
        await system.joinWindowEvent(on: model)
        try #require(retained(model) == [held: 43])
        system.offscreenWindowIDs = [held]
        system.unresponsiveProcessIDs.removeAll()
        system.applicationHoldsUntil[43] = system.uptime - 1
        model.watchdog()
        system.eventHandler?(WindowSystemEvent(kind: .created, windowID: nil, processIdentifier: 42))
        await system.joinWindowEvent(on: model)
        try #require(retained(model) == [held: 43])
        let writes = system.frameWriteCounts, probes = system.probeRequests
        system.offscreenWindowIDs.removeAll()
        let latest = BTRect(x: 0, y: 0, width: 1000, height: 400)
        system.windows[1].frame = latest
        system.failedVisibleWindowSweeps.insert(system.completeSweepCount + 1)
        model.watchdog()
        #expect(retained(model) == [held: 43])
        #expect(system.frameWriteCounts == writes)
        #expect(system.probeRequests == probes)
        system.eventHandler?(WindowSystemEvent(kind: .created, windowID: nil, processIdentifier: 42))
        await system.joinWindowEvent(on: model)
        try #require(await system.waitFor { system.frameWriteCounts[held] != nil && model.settlementTasks.isEmpty })
        #expect(system.windows[1].frame.approximatelyEquals(latest, tolerance: 1))
        #expect(retained(model).isEmpty)
        #expect(system.probeRequests == probes)
        let completedWrites = system.frameWriteCounts
        model.watchdog()
        #expect(system.frameWriteCounts == completedWrites)
    }

    @Test func retainedSnapSurvivesRejectedClassificationBeforeReturn() async throws {
        _ = NSApplication.shared
        let system = makeManualWindowSystem()
        system.applicationHoldDuration = 60
        let held = WindowID(rawValue: "held"), display = system.mainDisplay.id
        system.windows.append(WindowSnapshot(id: held, processIdentifier: 43,
            frame: BTRect(x: 0, y: 0, width: 500, height: 800), displayID: display))
        system.unresponsiveProcessIDs = [43]
        system.cachedSnapshotsAvailable = false
        let first = NativeSpaceID(rawValue: 1), second = NativeSpaceID(rawValue: 2)
        system.desktopObservation = NativeDesktopObservation(currentSpaceByDisplay: [display: first],
            knownSpacesByDisplay: [display: [first, second]],
            windowMembership: Dictionary(uniqueKeysWithValues: system.windows.map { ($0.id, [first]) }))
        let model = makeModel(system: system)
        defer { model.shutdown() }
        model.configuration.defaultLayoutMode = .manual
        model.primaryButtonIsPressed = { false }
        model.setActiveMode(.bento)
        system.eventHandler?(WindowSystemEvent(kind: .resized, windowID: held, processIdentifier: 43))
        await system.joinWindowEvent(on: model)
        system.unresponsiveProcessIDs.removeAll()
        system.applicationHoldsUntil[43] = system.uptime - 1
        var writesAtSwitch: [WindowID: Int]?
        let probes = system.probeRequests
        system.onWindowSnapshots = { [weak system, weak model] in
            guard let system, let model, writesAtSwitch == nil else { return }
            writesAtSwitch = system.frameWriteCounts
            system.desktopObservation?.currentSpaceByDisplay[display] = second
            system.offscreenWindowIDs = Set(system.windows.map(\.id))
            model.beginActiveSpaceStabilization()
        }
        model.watchdog()
        let writes = try #require(writesAtSwitch)
        #expect(system.frameWriteCounts == writes)
        #expect(system.probeRequests == probes)
        system.onWindowSnapshots = nil
        try #require(await system.waitFor { !model.isStabilizingSpace })
        let latest = BTRect(x: 0, y: 0, width: 1000, height: 400)
        system.windows[1].frame = latest
        system.desktopObservation?.currentSpaceByDisplay[display] = first
        system.offscreenWindowIDs.removeAll()
        model.beginActiveSpaceStabilization()
        try #require(await system.waitFor { !model.isStabilizingSpace })
        system.eventHandler?(WindowSystemEvent(kind: .created, windowID: nil, processIdentifier: 42))
        await system.joinWindowEvent(on: model)
        try #require(await system.waitFor { system.frameWriteCounts[held] != nil && model.settlementTasks.isEmpty })
        #expect(system.windows[1].frame.approximatelyEquals(latest, tolerance: 1))
        #expect(retained(model).isEmpty)
    }

    @Test(arguments: ["gesture", "processExit"])
    func destroyedEvidenceRetiresBeforeBufferedWork(interaction: String) async throws {
        _ = NSApplication.shared
        let system = makeManualWindowSystem()
        system.applicationHoldDuration = 60
        let held = WindowID(rawValue: "held"), sibling = WindowID(rawValue: "sibling")
        for id in [held, sibling] {
            system.windows.append(WindowSnapshot(id: id, processIdentifier: 43,
                frame: BTRect(x: 0, y: 0, width: 500, height: 800), displayID: system.mainDisplay.id))
        }
        system.windows.append(WindowSnapshot(id: WindowID(rawValue: "peer"), processIdentifier: 44,
            frame: BTRect(x: 300, y: 200, width: 600, height: 400), displayID: system.mainDisplay.id))
        system.unresponsiveProcessIDs = [43]
        system.cachedSnapshotsAvailable = false
        let model = makeModel(system: system)
        defer { model.shutdown() }
        model.primaryButtonIsPressed = { false }
        model.setActiveMode(.bento)
        try #require(await system.waitFor { model.settlementTasks.isEmpty })
        for id in [held, sibling] {
            system.eventHandler?(WindowSystemEvent(kind: .resized, windowID: id, processIdentifier: 43))
        }
        await system.joinWindowEvent(on: model)
        try #require(retained(model) == [held: 43, sibling: 43])
        let focused = system.windows[0].id, display = system.mainDisplay.id
        if interaction == "gesture" {
            try #require(model.beginBentoDrag(displayID: display, sourceID: focused))
        } else { model.beginActiveSpaceStabilization() }
        let writes = system.frameWriteCounts, probes = system.probeRequests
        let destroyed: Set<WindowID> = interaction == "processExit" ? [held, sibling] : [held]
        system.windows.removeAll { destroyed.contains($0.id) }
        // The adapter delivers one exact destroyed event per terminated identity.
        for id in destroyed {
            system.eventHandler?(WindowSystemEvent(kind: .destroyed, windowID: id, processIdentifier: 43))
        }
        #expect(retained(model) == (interaction == "processExit" ? [:] : [sibling: 43]))
        #expect(system.frameWriteCounts == writes)
        #expect(system.probeRequests == probes)
        let replacement = WindowID(rawValue: "replacement")
        system.windows.append(WindowSnapshot(id: replacement, processIdentifier: 43,
            frame: BTRect(x: 300, y: 200, width: 600, height: 400), displayID: display))
        #expect(retained(model)[replacement] == nil)
        if interaction == "gesture" {
            model.finishBentoDrag(displayID: display, sourceID: focused, outcome: .restore)
        } else { try #require(await system.waitFor { !model.isStabilizingSpace }) }
        system.unresponsiveProcessIDs.removeAll()
        system.applicationHoldsUntil[43] = system.uptime - 1
        system.eventHandler?(WindowSystemEvent(kind: .created, windowID: nil, processIdentifier: 43))
        await system.joinWindowEvent(on: model)
        try #require(await system.waitFor { system.frameWriteCounts[replacement] != nil && model.settlementTasks.isEmpty })
        #expect(system.frameWriteCounts[held] == nil)
        if interaction == "processExit" { #expect(system.frameWriteCounts[sibling] == nil) }
        #expect(retained(model).isEmpty)
        let frame = try #require(system.windows.first { $0.id == replacement }?.frame)
        #expect(!frame.approximatelyEquals(BTRect(x: 0, y: 0, width: 500, height: 800), tolerance: 1))
    }

    @Test(arguments: ["permissionReset", "shutdown"])
    func retainedIdentityEndsWithObservationLifetime(end: String) async throws {
        _ = NSApplication.shared
        let system = makeManualWindowSystem()
        system.applicationHoldDuration = 60
        let held = WindowID(rawValue: "held")
        system.windows.append(WindowSnapshot(id: held, processIdentifier: 43,
            frame: BTRect(x: 0, y: 0, width: 500, height: 800), displayID: system.mainDisplay.id))
        system.unresponsiveProcessIDs = [43]
        system.cachedSnapshotsAvailable = false
        let model = makeModel(system: system)
        defer { model.shutdown() }
        model.primaryButtonIsPressed = { false }
        model.setActiveMode(.bento)
        system.eventHandler?(WindowSystemEvent(kind: .resized, windowID: held, processIdentifier: 43))
        await system.joinWindowEvent(on: model)
        try #require(retained(model) == [held: 43])
        let writes = system.frameWriteCounts, probes = system.probeRequests
        if end == "permissionReset" {
            system.permission = false
            #expect(!model.refreshPermission())
        } else { model.shutdown() }
        #expect(retained(model).isEmpty)
        #expect(system.frameWriteCounts == writes)
        #expect(system.probeRequests == probes)
    }

    @Test func heldSnapDeliveredDuringGestureSurvivesUnreadableReplay() async throws {
        _ = NSApplication.shared
        let system = makeManualWindowSystem()
        system.applicationHoldDuration = 60
        let held = WindowID(rawValue: "held"), display = system.mainDisplay.id
        system.windows.append(WindowSnapshot(id: WindowID(rawValue: "peer"), processIdentifier: 44,
            frame: BTRect(x: 300, y: 200, width: 600, height: 400), displayID: display))
        system.windows.append(WindowSnapshot(id: held, processIdentifier: 43,
            frame: BTRect(x: 300, y: 200, width: 600, height: 400), displayID: display))
        system.unresponsiveProcessIDs = [43]
        system.cachedSnapshotsAvailable = false
        let model = makeModel(system: system)
        defer { model.shutdown() }
        model.primaryButtonIsPressed = { false }
        model.setActiveMode(.bento)
        try #require(await system.waitFor { model.settlementTasks.isEmpty })
        let focused = system.windows[0].id
        try #require(model.beginBentoDrag(displayID: display, sourceID: focused))
        let writes = system.frameWriteCounts, probes = system.probeRequests
        let requested = BTRect(x: 0, y: 0, width: 500, height: 800)
        system.windows[2].frame = requested
        system.eventHandler?(WindowSystemEvent(kind: .resized, windowID: held, processIdentifier: 43))
        #expect(system.frameWriteCounts == writes)
        #expect(system.probeRequests == probes)
        model.finishBentoDrag(displayID: display, sourceID: focused, outcome: .restore)
        await system.joinWindowEvent(on: model)
        #expect(retained(model) == [held: 43])
        system.unresponsiveProcessIDs.removeAll()
        system.applicationHoldsUntil[43] = system.uptime - 1
        model.watchdog()
        system.eventHandler?(WindowSystemEvent(kind: .created, windowID: nil, processIdentifier: 42))
        await system.joinWindowEvent(on: model)
        try #require(await system.waitFor { system.frameWriteCounts[held] != nil && model.settlementTasks.isEmpty })
        #expect(system.windows[2].frame.approximatelyEquals(requested, tolerance: 1))
        #expect(retained(model).isEmpty)
        let completed = system.frameWriteCounts
        model.watchdog()
        #expect(system.frameWriteCounts == completed)
    }

}
