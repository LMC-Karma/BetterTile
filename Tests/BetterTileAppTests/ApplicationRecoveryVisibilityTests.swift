import AppKit
import BetterTileCore
import Foundation
import Testing
@testable import BetterTileApp

@Suite(.appTestApplication, .serialized) @MainActor
struct ApplicationRecoveryVisibilityTests {
    private func retained(_ model: BetterTileModel) -> [WindowID: Int32] {
        Mirror(reflecting: model).children.first { $0.label?.hasSuffix("applicationRecoveryFrameEventPIDs") == true }?.value as? [WindowID: Int32] ?? [:]
    }
    private func pending(_ model: BetterTileModel) -> [WindowID: Int32] {
        Mirror(reflecting: model).children.first { $0.label?.hasSuffix("applicationRecoveryPendingWindows") == true }?.value as? [WindowID: Int32] ?? [:]
    }
    private func store(_ model: BetterTileModel) -> LayoutSessionStore? {
        Mirror(reflecting: model).children.first { $0.label?.hasSuffix("sessionStore") == true }?.value as? LayoutSessionStore
    }
    private func quiet(_ system: FakeAppWindowSystem) async throws {
        let writes = system.frameWriteCounts, probes = system.probeRequests, sweeps = system.completeSweepCount
        await system.advance(by: .milliseconds(850))
        #expect(system.frameWriteCounts == writes)
        #expect(system.probeRequests == probes)
        #expect(system.completeSweepCount == sweeps)
    }

    @Test(arguments: [false, true], ["nativeSnap", "edgeResize", "unrecognisedMove"])
    func absentRetainedIdentityCannotOwnUnrelatedSettlement(evidence: Bool, kind: String) async throws {
        _ = NSApplication.shared
        let system = makeManualWindowSystem()
        system.applicationHoldDuration = 60
        system.cachedSnapshotsAvailable = false
        let display = system.mainDisplay.id, focused = system.windows[0].id
        let peer = WindowID(rawValue: "peer"), held = WindowID(rawValue: "held")
        system.windows.append(WindowSnapshot(id: peer, processIdentifier: 44,
            frame: BTRect(x: 300, y: 200, width: 600, height: 400), displayID: display))
        if evidence {
            system.windows.append(WindowSnapshot(id: held, processIdentifier: 43,
                frame: BTRect(x: 0, y: 0, width: 500, height: 800), displayID: display))
            system.unresponsiveProcessIDs = [43]
        }
        let model = makeModel(system: system)
        defer { model.shutdown() }
        model.primaryButtonIsPressed = { false }
        model.setActiveMode(.bento)
        try #require(await system.waitFor { model.settlementTasks.isEmpty })
        if evidence {
            system.eventHandler?(WindowSystemEvent(kind: .resized, windowID: held, processIdentifier: 43))
            await system.joinWindowEvent(on: model)
            try #require(retained(model) == [held: 43])
            system.offscreenWindowIDs = [held]
            system.unresponsiveProcessIDs.removeAll()
            system.applicationHoldsUntil[43] = system.uptime - 1
            _ = try system.visibleWindows()
            model.handleApplicationTopologyChange()
            await system.joinWindowEvent(on: model)
            try #require(await system.waitFor { model.settlementTasks.isEmpty })
            try #require(system.unresponsiveApplicationRecoveryDeadlines.isEmpty)
            try #require(pending(model).isEmpty)
            try #require(retained(model) == [held: 43])
        }
        system.enforcedMinimumWidths[focused] = 510
        model.perform(.rightHalf)
        let owned = try #require(model.settlementTasks[display])
        let writes = system.frameWriteCounts, probes = system.probeRequests
        if kind == "nativeSnap" { system.windows[0].frame = BTRect(x: 0, y: 0, width: 510, height: 800) }
        else if kind == "edgeResize" { system.windows[0].frame.size.width += 80 }
        else { system.windows[0].frame.origin.x += 75; system.windows[0].frame.origin.y += 30 }
        let observed = system.windows.map(\.frame)
        system.eventHandler?(WindowSystemEvent(kind: .resized, windowID: focused, processIdentifier: 42))
        model.processPendingWindowEvents()
        #expect(!owned.isCancelled, "Only a returning recovery snap may supersede settlement")
        #expect(model.settlementTasks[display] != nil)
        #expect(system.frameWriteCounts == writes)
        #expect(system.windows.map(\.frame) == observed)
        #expect(system.probeRequests == probes)
        #expect(retained(model) == (evidence ? [held: 43] : [:]))
        try #require(await system.waitFor { model.settlementTasks.isEmpty })
        await system.joinWindowEvent(on: model)
        #expect(retained(model) == (evidence ? [held: 43] : [:]))
        #expect(system.frameWriteCounts[held] == nil)
        try await quiet(system)
    }

    @Test(arguments: [false, true], ["stillHeld", "retainedAbsent", "readableControl"])
    func firstNativeObservationWithVisibleAnchorBeforeReturn(transition: Bool, evidence: String) async throws {
        _ = NSApplication.shared
        let system = makeManualWindowSystem()
        system.applicationHoldDuration = 60
        system.cachedSnapshotsAvailable = false
        let display = system.mainDisplay.id, held = WindowID(rawValue: "held")
        system.windows.append(WindowSnapshot(id: held, processIdentifier: 43,
            frame: BTRect(x: 0, y: 0, width: 500, height: 800), displayID: display))
        system.unresponsiveProcessIDs = [43]
        let model = makeModel(system: system)
        defer { model.shutdown() }
        model.primaryButtonIsPressed = { false }
        model.configuration.defaultLayoutMode = .bento
        model.setActiveMode(.bento)
        try #require(await system.waitFor { model.settlementTasks.isEmpty })
        if evidence == "retainedAbsent" {
            system.eventHandler?(WindowSystemEvent(kind: .resized, windowID: held, processIdentifier: 43))
            await system.joinWindowEvent(on: model)
            try #require(retained(model) == [held: 43])
        }
        model.setActiveMode(.manual)
        let original = try #require(store(model)?.session(for: display))
        try #require(original.mode == .manual && original.nativeSpaceID == nil)
        try #require(original.windowIDs.contains(system.windows[0].id))
        if evidence != "stillHeld" {
            if evidence == "retainedAbsent" { system.offscreenWindowIDs = [held] }
            system.unresponsiveProcessIDs.removeAll()
            system.applicationHoldsUntil[43] = system.uptime - 1
            if evidence == "retainedAbsent" { _ = try system.visibleWindows() }
        }
        if evidence == "stillHeld" {
            try #require(system.unresponsiveApplicationRecoveryDeadlines[43] != nil)
            try #require(retained(model).isEmpty && pending(model).isEmpty)
        } else if evidence == "retainedAbsent" {
            try #require(system.unresponsiveApplicationRecoveryDeadlines.isEmpty)
            try #require(pending(model).isEmpty && retained(model) == [held: 43])
        }
        let writes = system.frameWriteCounts, frames = system.windows.map(\.frame), probes = system.probeRequests
        let space = NativeSpaceID(rawValue: 1)
        system.desktopObservation = NativeDesktopObservation(currentSpaceByDisplay: [display: space],
            knownSpacesByDisplay: [display: [space]],
            windowMembership: Dictionary(uniqueKeysWithValues: system.windows.map { ($0.id, [space]) }))
        if transition {
            model.beginActiveSpaceStabilization()
            #expect(store(model)?.session(for: display)?.id == original.id)
            try #require(await system.waitFor { !model.isStabilizingSpace })
        } else { model.handleApplicationTopologyChange() }
        await system.joinWindowEvent(on: model)
        try #require(await system.waitFor { model.settlementTasks.isEmpty })
        let final = try #require(store(model)?.session(for: display))
        #expect(final.id == original.id)
        #expect(final.mode == .manual)
        #expect(final.nativeSpaceID == space)
        #expect(final.automaticWritesSuspended == original.automaticWritesSuspended)
        #expect(system.frameWriteCounts == writes)
        #expect(system.windows.map(\.frame) == frames)
        #expect(system.probeRequests == probes)
        #expect(retained(model) == (evidence == "retainedAbsent" ? [held: 43] : [:]))
        system.unresponsiveProcessIDs.removeAll()
        if evidence == "stillHeld" { system.applicationHoldsUntil[43] = system.uptime - 1 }
        system.offscreenWindowIDs.removeAll()
        model.handleApplicationTopologyChange()
        await system.joinWindowEvent(on: model)
        try #require(await system.waitFor { model.settlementTasks.isEmpty })
        #expect(store(model)?.session(for: display)?.id == original.id)
        #expect(store(model)?.session(for: display)?.mode == .manual)
        #expect(store(model)?.session(for: display)?.nativeSpaceID == space)
        #expect(store(model)?.session(for: display)?.automaticWritesSuspended == original.automaticWritesSuspended)
        #expect(system.frameWriteCounts == writes)
        #expect(system.windows.map(\.frame) == frames)
        #expect(system.probeRequests == probes)
        #expect(retained(model).isEmpty)
        try await quiet(system)
    }

    @Test(arguments: [false, true], ["otherDisplay", "samePIDSibling"])
    func recoveryParticipationIsDisplayAndIdentitySpecific(native: Bool, location: String) async throws {
        _ = NSApplication.shared
        let system = makeManualWindowSystem()
        system.applicationHoldDuration = 60
        system.cachedSnapshotsAvailable = false
        let display = system.mainDisplay.id, focused = system.windows[0].id
        let peer = WindowID(rawValue: "peer"), held = WindowID(rawValue: "held")
        let second = DisplaySnapshot(id: DisplayID(rawValue: "second"),
            frame: BTRect(x: 1000, y: 0, width: 1000, height: 800),
            visibleFrame: BTRect(x: 1000, y: 0, width: 1000, height: 800))
        system.availableDisplays.append(second)
        system.windows += [
            WindowSnapshot(id: peer, processIdentifier: 44,
                frame: BTRect(x: 300, y: 200, width: 600, height: 400), displayID: display),
            WindowSnapshot(id: held, processIdentifier: 43,
                frame: BTRect(x: 1200, y: 200, width: 600, height: 400), displayID: second.id),
            WindowSnapshot(id: WindowID(rawValue: "second-anchor"), processIdentifier: 45,
                frame: BTRect(x: 1300, y: 100, width: 600, height: 400), displayID: second.id)
        ]
        system.unresponsiveProcessIDs = [43]
        if native {
            let firstSpace = NativeSpaceID(rawValue: 1), secondSpace = NativeSpaceID(rawValue: 2)
            system.desktopObservation = NativeDesktopObservation(
                currentSpaceByDisplay: [display: firstSpace, second.id: secondSpace],
                knownSpacesByDisplay: [display: [firstSpace], second.id: [secondSpace]],
                windowMembership: [focused: [firstSpace], peer: [firstSpace], held: [secondSpace]])
        }
        let model = makeModel(system: system)
        defer { model.shutdown() }
        model.primaryButtonIsPressed = { false }
        model.setActiveMode(.bento)
        try #require(await system.waitFor { model.settlementTasks.isEmpty })
        system.eventHandler?(WindowSystemEvent(kind: .resized, windowID: held, processIdentifier: 43))
        await system.joinWindowEvent(on: model)
        try #require(retained(model) == [held: 43])
        if location == "samePIDSibling" {
            system.offscreenWindowIDs = [held]
            system.windows.append(WindowSnapshot(id: WindowID(rawValue: "sibling"), processIdentifier: 43,
                frame: BTRect(x: 300, y: 200, width: 600, height: 400), displayID: display))
        }
        system.unresponsiveProcessIDs.removeAll()
        system.applicationHoldsUntil[43] = system.uptime - 1
        // Release the adapter hold without giving model reconciliation a returning identity.
        let visible = try system.visibleWindows()
        try #require(system.unresponsiveApplicationRecoveryDeadlines.isEmpty && pending(model).isEmpty)
        try #require(visible.contains { $0.id == held } == (location == "otherDisplay"))
        system.enforcedMinimumWidths[focused] = 510
        model.perform(.rightHalf)
        let owned = try #require(model.settlementTasks[display])
        let writes = system.frameWriteCounts, probes = system.probeRequests
        system.windows[0].frame = BTRect(x: 0, y: 0, width: 510, height: 800)
        let frames = system.windows.map(\.frame)
        system.eventHandler?(WindowSystemEvent(kind: .resized, windowID: focused, processIdentifier: 42))
        model.processPendingWindowEvents()
        #expect(!owned.isCancelled)
        #expect(system.frameWriteCounts == writes)
        #expect(system.windows.map(\.frame) == frames)
        #expect(system.probeRequests == probes)
        #expect(system.frameWriteCounts[held] == nil)
        #expect(retained(model) == (location == "otherDisplay" ? [:] : [held: 43]))
        try #require(await system.waitFor { model.settlementTasks.isEmpty })
        await system.joinWindowEvent(on: model)
        try await quiet(system)
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
        try #require(model.statusMessage?.contains("Repair") == true)
        try #require(retained(model) == [held: 43])
        system.failedFrameWriteNumbers.removeAll()
        system.windows[1].frame = BTRect(x: 0, y: 0, width: 1000, height: 400)
        return (system, model, observation)
    }


    @Test(arguments: [false, true], [false, true])
    func degradedOwnerSurvivesFirstNativeObservationBeforeReturn(transition: Bool, stillHeld: Bool) async throws {
        let (system, model, observation) = try await prepareDegraded()
        defer { model.shutdown() }
        let display = system.mainDisplay.id, held = system.windows[1].id
        let original = try #require(store(model)?.session(for: display))
        try #require(original.automaticWritesSuspended && original.nativeSpaceID == nil && original.mode == .bento)
        try #require(original.windowIDs.contains(system.windows[0].id))
        if stillHeld {
            system.unresponsiveProcessIDs = [43]
            system.applicationHoldsUntil[43] = system.uptime + 60
        } else { system.offscreenWindowIDs = [held] }
        let writes = system.frameWriteCounts, probes = system.probeRequests, frames = system.windows.map(\.frame)
        system.desktopObservation = observation
        if transition {
            model.beginActiveSpaceStabilization()
            #expect(store(model)?.session(for: display)?.id == original.id)
            try #require(await system.waitFor { !model.isStabilizingSpace })
        } else { model.handleApplicationTopologyChange() }
        await system.joinWindowEvent(on: model)
        try #require(await system.waitFor { model.settlementTasks.isEmpty })
        let final = try #require(store(model)?.session(for: display))
        #expect(final.id == original.id)
        #expect(final.nativeSpaceID == NativeSpaceID(rawValue: 1))
        #expect(final.mode == original.mode)
        #expect(final.automaticWritesSuspended)
        #expect(retained(model) == [held: 43])
        #expect(system.frameWriteCounts == writes)
        #expect(system.windows.map(\.frame) == frames)
        #expect(system.probeRequests == probes)
        system.unresponsiveProcessIDs.removeAll()
        if stillHeld { system.applicationHoldsUntil[43] = system.uptime - 1 }
        system.offscreenWindowIDs.removeAll()
        model.handleApplicationTopologyChange()
        await system.joinWindowEvent(on: model)
        try #require(await system.waitFor { model.settlementTasks.isEmpty })
        #expect(store(model)?.session(for: display)?.id == original.id)
        #expect(store(model)?.session(for: display)?.nativeSpaceID == NativeSpaceID(rawValue: 1))
        #expect(store(model)?.session(for: display)?.mode == original.mode)
        #expect(store(model)?.session(for: display)?.automaticWritesSuspended == true)
        #expect(system.frameWriteCounts == writes)
        #expect(system.windows.map(\.frame) == frames)
        #expect(system.probeRequests == probes)
        #expect(retained(model) == [held: 43])
        try await quiet(system)
    }
}
