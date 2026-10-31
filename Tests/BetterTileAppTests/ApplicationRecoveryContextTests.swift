import AppKit
import BetterTileCore
import BetterTileMacOS
import Foundation
import Testing
@testable import BetterTileApp

@Suite(.appTestApplication, .serialized) @MainActor
struct ApplicationRecoveryContextTests {
    private func retained(_ model: BetterTileModel) -> [WindowID: Int32] {
        Mirror(reflecting: model).children.first { $0.label?.hasSuffix("applicationRecoveryFrameEventPIDs") == true }?.value as? [WindowID: Int32] ?? [:]
    }
    private func store(_ model: BetterTileModel) -> LayoutSessionStore? {
        Mirror(reflecting: model).children.first { $0.label?.hasSuffix("sessionStore") == true }?.value as? LayoutSessionStore
    }
    @Test(arguments: ["unchanged", "unavailable", "restored"])
    func nativeCapabilityChangesDuringRecovery(change: String) async throws {
        _ = NSApplication.shared
        let system = makeManualWindowSystem()
        system.applicationHoldDuration = 60
        system.cachedSnapshotsAvailable = false
        let held = WindowID(rawValue: "held"), focused = system.windows[0].id, display = system.mainDisplay.id
        system.windows.append(WindowSnapshot(id: held, processIdentifier: 43,
            frame: BTRect(x: 0, y: 0, width: 500, height: 800), displayID: display))
        let native = NativeDesktopObservation(currentSpaceByDisplay: [display: NativeSpaceID(rawValue: 1)],
            knownSpacesByDisplay: [display: [NativeSpaceID(rawValue: 1)]],
            windowMembership: [focused: [NativeSpaceID(rawValue: 1)], held: [NativeSpaceID(rawValue: 1)]])
        if change != "restored" { system.desktopObservation = native }
        system.unresponsiveProcessIDs = [43]
        let model = makeModel(system: system)
        defer { model.shutdown() }
        model.primaryButtonIsPressed = { false }
        model.configuration.defaultLayoutMode = .bento
        model.setActiveMode(.bento)
        try #require(await system.waitFor { model.settlementTasks.isEmpty })
        system.eventHandler?(WindowSystemEvent(kind: .resized, windowID: held, processIdentifier: 43))
        await system.joinWindowEvent(on: model)
        try #require(retained(model) == [held: 43])
        let original = try #require(store(model)?.session(for: display))
        if change == "unavailable" { system.desktopObservation = nil }
        if change == "restored" { system.desktopObservation = native }
        system.unresponsiveProcessIDs.removeAll()
        system.applicationHoldsUntil[43] = system.uptime - 1
        model.handleApplicationTopologyChange()
        let immediateSweeps = system.completeSweepCount
        await system.advance(by: .milliseconds(800))
        #expect(system.completeSweepCount - immediateSweeps <= 2, "Recovery cannot schedule its own topology retry loop")
        try #require(await system.waitFor(timeout: .seconds(3)) { model.settlementTasks.isEmpty })
        let final = try #require(store(model)?.session(for: display))
        print("RECOVERY_CONTEXT_CAPABILITY change=\(change) originalSpace=\(String(describing: original.nativeSpaceID)) finalSpace=\(String(describing: final.nativeSpaceID)) sameSession=\(original.id == final.id) additionalSweeps=\(system.completeSweepCount - immediateSweeps) writes=\(system.frameWriteCounts) probes=\(system.probeRequests) retained=\(retained(model)) frames=\(system.windows.map { ($0.id, $0.frame) })")
        #expect(system.completeSweepCount - immediateSweeps == 2)
        #expect(system.windows[1].frame == BTRect(x: 0, y: 0, width: 500, height: 800))
        #expect(system.windows[0].frame == BTRect(x: 501, y: 0, width: 499, height: 800))
        #expect(system.frameWriteCounts == [focused: 3, held: 2])
        #expect(system.probeRequests.isEmpty)
        #expect(retained(model).isEmpty)
        try await expectQuiet(system)
    }

    @Test(arguments: ["none", "destroyed", "minimized"], ["relocation", "divider"])
    func retainedNonSnapWithPeerRemoval(removal: String, movement: String) async throws {
        _ = NSApplication.shared
        let system = makeManualWindowSystem()
        system.applicationHoldDuration = 60
        system.cachedSnapshotsAvailable = false
        let held = WindowID(rawValue: "held"), peer = WindowID(rawValue: "peer"), display = system.mainDisplay.id
        system.windows += [
            WindowSnapshot(id: held, processIdentifier: 43, frame: BTRect(x: 100, y: 100, width: 600, height: 400), displayID: display),
            WindowSnapshot(id: peer, processIdentifier: 44, frame: BTRect(x: 200, y: 200, width: 600, height: 400), displayID: display)
        ]
        let model = makeModel(system: system)
        defer { model.shutdown() }
        model.primaryButtonIsPressed = { false }
        model.setActiveMode(.bento)
        try #require(await system.waitFor { model.settlementTasks.isEmpty })
        let before = system.frameWriteCounts
        system.unresponsiveProcessIDs = [43]
        system.applicationHoldsUntil[43] = system.uptime + 60
        if movement == "relocation" {
            system.windows[1].frame.origin.x += 65
            system.windows[1].frame.origin.y += 35
        } else { system.windows[1].frame.size.width += 55 }
        system.eventHandler?(WindowSystemEvent(kind: .resized, windowID: held, processIdentifier: 43))
        await system.joinWindowEvent(on: model)
        try #require(retained(model) == [held: 43])
        if removal == "destroyed" { system.windows.removeAll { $0.id == peer } }
        if removal == "minimized" { system.windows[2].isMinimized = true }
        if removal != "none" {
            system.eventHandler?(WindowSystemEvent(kind: removal == "destroyed" ? .destroyed : .minimized, windowID: peer, processIdentifier: 44))
        }
        system.unresponsiveProcessIDs.removeAll()
        system.applicationHoldsUntil[43] = system.uptime - 1
        model.handleApplicationTopologyChange()
        await system.joinWindowEvent(on: model)
        try #require(await system.waitFor { model.settlementTasks.isEmpty })
        for _ in 0..<3 { model.watchdog() }
        await system.joinWindowEvent(on: model)
        try #require(await system.waitFor { model.settlementTasks.isEmpty })
        let current = try #require(store(model)?.session(for: display))
        print("RECOVERY_CONTEXT_REMOVAL kind=\(removal) movement=\(movement) before=\(before) writes=\(system.frameWriteCounts) probes=\(system.probeRequests) sweeps=\(system.completeSweepCount) retained=\(retained(model)) members=\(current.bentoState.root?.windowIDs ?? []) frames=\(system.windows.map { ($0.id, $0.frame) })")
        #expect(retained(model).isEmpty)
        if removal != "none" {
            let expectedWidth = movement == "divider" ? 555.0 : 500.0
            #expect(system.windows[1].frame == BTRect(x: 0, y: 0, width: expectedWidth, height: 800))
            let frames = Dictionary(uniqueKeysWithValues: system.windows.filter(\.isEligible).map { ($0.id, $0.frame) })
            #expect(BentoLayoutVerifier.overlappingWindowIDs(frames).isEmpty)
            #expect(current.bentoState.root?.windowIDs.contains(peer) != true)
            #expect(system.frameWriteCounts[peer] == before[peer])
        }
        #expect(!current.automaticWritesSuspended)
        #expect(system.probeRequests.isEmpty)
        if movement == "divider", removal != "none" {
            #expect(system.frameWriteCounts == [system.windows[0].id: 2, held: 2, peer: 1])
            #expect(system.completeSweepCount == 10)
        }
        try await expectQuiet(system)
    }
    private func prepareCapability(native: Bool, frameEvent: Bool = true, sibling: Bool = false) async throws -> (FakeAppWindowSystem, BetterTileModel, NativeDesktopObservation) {
        _ = NSApplication.shared
        let system = makeManualWindowSystem()
        system.applicationHoldDuration = 60
        system.cachedSnapshotsAvailable = false
        let display = system.mainDisplay.id
        let held = WindowID(rawValue: "held")
        system.windows.append(WindowSnapshot(id: held, processIdentifier: 43,
            frame: BTRect(x: 0, y: 0, width: 500, height: 800), displayID: display))
        if sibling {
            system.windows.append(WindowSnapshot(id: WindowID(rawValue: "sibling"), processIdentifier: 43,
                frame: BTRect(x: 200, y: 100, width: 400, height: 300), displayID: display))
        }
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

    private func expectQuiet(_ system: FakeAppWindowSystem) async throws {
        let writes = system.frameWriteCounts, probes = system.probeRequests, sweeps = system.completeSweepCount
        await system.advance(by: .milliseconds(850))
        #expect(system.frameWriteCounts == writes)
        #expect(system.probeRequests == probes)
        #expect(system.completeSweepCount == sweeps)
    }

    @Test(arguments: [false, true], [false, true])
    func capabilityInvalidationDuringPreflight(native: Bool, oscillating: Bool) async throws {
        let (system, model, observation) = try await prepareCapability(native: native)
        defer { model.shutdown() }
        let held = WindowID(rawValue: "held")
        let writes = system.frameWriteCounts, probes = system.probeRequests
        var invalidations = 0
        var invalidatedSweeps: Set<Int> = []
        system.onWindowSnapshots = { [weak system] in
            guard let system, oscillating || invalidations == 0,
                  invalidatedSweeps.insert(system.completeSweepCount).inserted else { return }
            invalidations += 1
            system.desktopObservation = system.desktopObservation == nil ? observation : nil
        }
        model.handleApplicationTopologyChange()
        #expect(invalidations > 0)
        #expect(system.frameWriteCounts == writes, "Preflight cannot dispatch under a changed observation capability")
        #expect(system.probeRequests == probes)
        #expect(retained(model) == [held: 43])
        await system.joinWindowEvent(on: model)
        try #require(await system.waitFor { model.settlementTasks.isEmpty })
        // Each explicit reconciliation sees the opposite capability during preflight.
        try await expectQuiet(system)
        if oscillating {
            for _ in 0..<3 {
                model.watchdog()
                await system.joinWindowEvent(on: model)
                #expect(system.frameWriteCounts == writes)
                #expect(system.probeRequests == probes)
                #expect(retained(model) == [held: 43])
                try await expectQuiet(system)
            }
            #expect(invalidations == 4)
        }
        system.onWindowSnapshots = nil
        system.windows[1].frame = BTRect(x: 0, y: 0, width: 1000, height: 400)
        model.watchdog()
        await system.joinWindowEvent(on: model)
        try #require(await system.waitFor { model.settlementTasks.isEmpty })
        print("RECOVERY_CONTEXT_PREFLIGHT native=\(native) oscillating=\(oscillating) invalidations=\(invalidations) writes=\(system.frameWriteCounts) probes=\(system.probeRequests) sweeps=\(system.completeSweepCount) frames=\(system.windows.map { ($0.id, $0.frame) }) retained=\(retained(model))")
        #expect(system.windows[1].frame == BTRect(x: 0, y: 0, width: 1000, height: 400))
        #expect(retained(model).isEmpty)
        #expect(system.probeRequests.isEmpty)
        try await expectQuiet(system)
    }

    @Test(arguments: [false, true])
    func capabilityChangeKeepsCurrentMode(native: Bool) async throws {
        let (system, model, observation) = try await prepareCapability(native: native)
        defer { model.shutdown() }
        system.unresponsiveProcessIDs = [43]
        system.applicationHoldsUntil[43] = system.uptime + 60
        model.setActiveMode(.manual)
        try #require(retained(model) == [system.windows[1].id: 43])
        system.unresponsiveProcessIDs.removeAll()
        system.applicationHoldsUntil[43] = system.uptime - 1
        model.configuration.defaultLayoutMode = .bento
        system.desktopObservation = native ? nil : observation
        let writes = system.frameWriteCounts, frames = system.windows.map(\.frame)
        model.handleApplicationTopologyChange()
        await system.joinWindowEvent(on: model)
        try #require(await system.waitFor { model.settlementTasks.isEmpty })
        #expect(store(model)?.session(for: system.mainDisplay.id)?.mode == .manual)
        #expect(system.frameWriteCounts == writes)
        #expect(system.windows.map(\.frame) == frames)
        #expect(system.probeRequests.isEmpty)
        #expect(retained(model).isEmpty)
        try await expectQuiet(system)
    }

    @Test(arguments: [false, true])
    func publicFallbackWithoutOverlapDefersUntilAnchorReturns(native: Bool) async throws {
        let (system, model, _) = try await prepareCapability(native: native)
        defer { model.shutdown() }
        let focused = system.windows[0].id, held = system.windows[1].id
        system.offscreenWindowIDs = [focused]
        system.desktopObservation = nil
        let writes = system.frameWriteCounts, frames = system.windows.map(\.frame)
        model.handleApplicationTopologyChange()
        await system.joinWindowEvent(on: model)
        #expect(system.frameWriteCounts == writes)
        #expect(system.windows.map(\.frame) == frames)
        #expect(system.probeRequests.isEmpty)
        #expect(retained(model) == [held: 43])
        try await expectQuiet(system)
        system.offscreenWindowIDs.removeAll()
        model.watchdog()
        await system.joinWindowEvent(on: model)
        try #require(await system.waitFor { model.settlementTasks.isEmpty })
        #expect(system.windows[1].frame == BTRect(x: 0, y: 0, width: 500, height: 800))
        #expect(system.frameWriteCounts == [focused: 3, held: 2])
        #expect(system.probeRequests.isEmpty)
        #expect(retained(model).isEmpty)
        try await expectQuiet(system)
    }

    @Test(arguments: [false, true], [false, true])
    func capabilityChangeAcrossDisplays(native: Bool, duringPreflight: Bool) async throws {
        _ = NSApplication.shared
        let system = makeManualWindowSystem()
        system.applicationHoldDuration = 60
        system.cachedSnapshotsAvailable = false
        let other = DisplaySnapshot(id: DisplayID(rawValue: "other"),
            frame: BTRect(x: 1000, y: 0, width: 1000, height: 800),
            visibleFrame: BTRect(x: 1000, y: 0, width: 1000, height: 800))
        system.availableDisplays.append(other)
        let heldA = WindowID(rawValue: "held-a"), heldB = WindowID(rawValue: "held-b"), peerB = WindowID(rawValue: "peer-b")
        system.windows += [
            WindowSnapshot(id: heldA, processIdentifier: 43, frame: BTRect(x: 0, y: 0, width: 500, height: 800), displayID: system.mainDisplay.id),
            WindowSnapshot(id: peerB, processIdentifier: 44, frame: BTRect(x: 1200, y: 100, width: 600, height: 400), displayID: other.id),
            WindowSnapshot(id: heldB, processIdentifier: 45, frame: BTRect(x: 1000, y: 0, width: 500, height: 800), displayID: other.id)
        ]
        let space = NativeSpaceID(rawValue: 1), secondSpace = NativeSpaceID(rawValue: 2)
        let observation = NativeDesktopObservation(currentSpaceByDisplay: [system.mainDisplay.id: space, other.id: secondSpace],
            knownSpacesByDisplay: [system.mainDisplay.id: [space], other.id: [secondSpace]],
            windowMembership: Dictionary(uniqueKeysWithValues: system.windows.map { ($0.id, [$0.displayID == other.id ? secondSpace : space]) }))
        system.desktopObservation = native ? observation : nil
        system.unresponsiveProcessIDs = [43, 45]
        let model = makeModel(system: system)
        defer { model.shutdown() }
        model.primaryButtonIsPressed = { false }
        model.configuration.defaultLayoutMode = .bento
        model.setActiveMode(.bento)
        system.focusedID = peerB
        model.setActiveMode(.bento)
        try #require(await system.waitFor { model.settlementTasks.isEmpty })
        for (id, pid): (WindowID, Int32) in [(heldA, 43), (heldB, 45)] {
            system.eventHandler?(WindowSystemEvent(kind: .resized, windowID: id, processIdentifier: pid))
        }
        await system.joinWindowEvent(on: model)
        try #require(retained(model) == [heldA: 43, heldB: 45])
        let writes = system.frameWriteCounts
        system.unresponsiveProcessIDs.removeAll()
        for pid: Int32 in [43, 45] { system.applicationHoldsUntil[pid] = system.uptime - 1 }
        var invalidated = false
        if duringPreflight {
            system.onWindowSnapshots = { [weak system] in
                guard let system, !invalidated else { return }
                invalidated = true
                system.desktopObservation = native ? nil : observation
            }
        } else { system.desktopObservation = native ? nil : observation }
        model.handleApplicationTopologyChange()
        if duringPreflight {
            #expect(invalidated)
            #expect(system.frameWriteCounts == writes)
            #expect(retained(model) == [heldA: 43, heldB: 45])
            await system.joinWindowEvent(on: model)
            try await expectQuiet(system)
            system.onWindowSnapshots = nil
            model.watchdog()
        }
        await system.joinWindowEvent(on: model)
        try #require(await system.waitFor { model.settlementTasks.isEmpty })
        #expect(retained(model).isEmpty)
        #expect(system.probeRequests.isEmpty)
        #expect(system.frameWriteCounts == [system.windows[0].id: 3, heldA: 2, peerB: 3, heldB: 2])
        let frames = Dictionary(uniqueKeysWithValues: system.windows.map { ($0.id, $0.frame) })
        #expect(frames[heldA] == BTRect(x: 0, y: 0, width: 500, height: 800))
        #expect(frames[heldB] == BTRect(x: 1000, y: 0, width: 500, height: 800))
        #expect(frames[system.windows[0].id] == BTRect(x: 501, y: 0, width: 499, height: 800))
        #expect(frames[peerB] == BTRect(x: 1501, y: 0, width: 499, height: 800))
        print("RECOVERY_CONTEXT_DISPLAYS native=\(native) preflight=\(duringPreflight) writes=\(system.frameWriteCounts) probes=\(system.probeRequests) sweeps=\(system.completeSweepCount) frames=\(frames)")
        try await expectQuiet(system)
    }

    @Test(arguments: [false, true], [false, true])
    func firstNativeObservationKeepsRetainedSnap(transition: Bool, topHalf: Bool) async throws {
        let (system, model, observation) = try await prepareCapability(native: false)
        defer { model.shutdown() }
        // Selection creates an unobserved native session before recovery classification.
        if topHalf { system.windows[1].frame = BTRect(x: 0, y: 0, width: 1000, height: 400) }
        system.desktopObservation = observation
        if transition {
            model.beginActiveSpaceStabilization()
            try #require(await system.waitFor { !model.isStabilizingSpace })
        } else { model.handleApplicationTopologyChange() }
        await system.joinWindowEvent(on: model)
        try #require(await system.waitFor { model.settlementTasks.isEmpty })
        let held = system.windows[1].id
        print("RECOVERY_CONTEXT_FIRST transition=\(transition) top=\(topHalf) frames=\(system.windows.map { ($0.id, $0.frame) }) writes=\(system.frameWriteCounts) probes=\(system.probeRequests) sweeps=\(system.completeSweepCount) retained=\(retained(model))")
        let expected = topHalf ? BTRect(x: 0, y: 0, width: 1000, height: 400)
            : BTRect(x: 0, y: 0, width: 500, height: 800)
        #expect(system.windows[1].frame == expected)
        #expect(system.requestedFrames[held]?.allSatisfy { $0.approximatelyEquals(expected, tolerance: 1) } == true)
        #expect(system.frameWriteCounts == [system.windows[0].id: 3, held: 2])
        #expect(system.probeRequests.isEmpty)
        #expect(retained(model).isEmpty)
        try await expectQuiet(system)
    }

    @Test(arguments: [false, true], ["manual", "partition"])
    func newerCommandDuringCapabilityPreflight(native: Bool, command: String) async throws {
        let (system, model, observation) = try await prepareCapability(native: native)
        defer { model.shutdown() }
        system.desktopObservation = native ? nil : observation
        var commandWrites: [WindowID: Int] = [:], commandFrames: [BTRect] = []
        var invoked = false
        system.onWindowSnapshots = { [weak system, weak model] in
            guard let system, let model, !invoked else { return }
            invoked = true
            if command == "manual" { model.setActiveMode(.manual) }
            else { model.perform(.rightHalf) }
            commandWrites = system.frameWriteCounts
            commandFrames = system.windows.map(\.frame)
        }
        // Run the event pass after the command settles. Its whole-point frames
        // already match the partition, so adopting them needs no extra write.
        // This explicit seam waits on settlement instead of registering an event timer.
        system.isAwaitingWindowEventSleepRegistration = nil
        model.windowEventSleep = { [weak model] _ in
            _ = await system.waitFor { model?.settlementTasks.isEmpty ?? true }
            try Task.checkCancellation()
        }
        model.handleApplicationTopologyChange()
        #expect(invoked)
        #expect(system.frameWriteCounts == commandWrites)
        #expect(system.windows.map(\.frame) == commandFrames)
        system.onWindowSnapshots = nil
        await system.joinWindowEvent(on: model)
        try #require(await system.waitFor { model.settlementTasks.isEmpty })
        model.watchdog()
        await system.joinWindowEvent(on: model)
        try #require(await system.waitFor { model.settlementTasks.isEmpty })
        #expect(system.windows.map(\.frame) == commandFrames)
        #expect(system.frameWriteCounts == commandWrites)
        #expect(system.probeRequests.isEmpty)
        #expect(retained(model).isEmpty)
        try await expectQuiet(system)
    }

    @Test(arguments: [false, true], [false, true])
    func newerCommandDuringCapabilityPreflightSkipsEventPassWhileSettling(native: Bool, observesCommandFrames: Bool) async throws {
        let (system, model, observation) = try await prepareCapability(native: native)
        defer { model.shutdown() }
        let display = system.mainDisplay.id
        system.desktopObservation = native ? nil : observation
        var commandWrites: [WindowID: Int] = [:], commandFrames: [BTRect] = []
        var invoked = false
        system.onWindowSnapshots = { [weak system, weak model] in
            guard let system, let model, !invoked else { return }
            invoked = true
            model.perform(.rightHalf)
            commandWrites = system.frameWriteCounts
            commandFrames = system.windows.map(\.frame)
        }
        model.handleApplicationTopologyChange()
        try #require(invoked)
        system.onWindowSnapshots = nil
        let settlement = try #require(model.settlementTasks[display])
        let debounced = try #require(model.windowEventTask)
        // Drain the debounced work synchronously, as in NonRecoverySettlementTests. Holding this
        // actor turn keeps the command's settlement open throughout the pass, regardless of load.
        debounced.cancel()
        if observesCommandFrames {
            // A successful terminal sample can retire self-event suppression before settlement ends.
            // Exercise the settlement guard too, rather than only the earlier self-event match.
            let coordinator = try #require(Mirror(reflecting: model).children.first {
                $0.label == "coordinator"
            }?.value as? WindowCoordinator)
            coordinator.finishExpectedMutations(observing: system.windows)
        }
        model.processPendingWindowEvents()
        try #require(model.settlementTasks[display] != nil)
        #expect(!settlement.isCancelled)
        #expect(system.frameWriteCounts == commandWrites)
        #expect(system.windows.map(\.frame) == commandFrames)
        #expect(system.probeRequests.isEmpty)
        let deferred: [WindowID: Int32] = observesCommandFrames ? [system.windows[1].id: 43] : [:]
        #expect(retained(model) == deferred)
        await system.joinWindowEvent(on: model, task: debounced)
        try #require(await system.waitFor { model.settlementTasks.isEmpty })
        #expect(system.frameWriteCounts == commandWrites)
        #expect(retained(model) == deferred)
        model.watchdog()
        await system.joinWindowEvent(on: model)
        try #require(await system.waitFor { model.settlementTasks.isEmpty })
        #expect(system.windows.map(\.frame) == commandFrames)
        let finalWrites = observesCommandFrames ? commandWrites.mapValues { $0 + 1 } : commandWrites
        #expect(system.frameWriteCounts == finalWrites)
        #expect(system.probeRequests.isEmpty)
        #expect(retained(model).isEmpty)
        try await expectQuiet(system)
    }

    @Test(arguments: [false, true], [false, true])
    func capabilityChangeWithoutFrameCallback(native: Bool, duringPreflight: Bool) async throws {
        let (system, model, observation) = try await prepareCapability(native: native, frameEvent: false)
        defer { model.shutdown() }
        var invalidated = false
        if duringPreflight {
            system.onWindowSnapshots = { [weak system] in
                guard let system, !invalidated else { return }
                invalidated = true
                system.desktopObservation = native ? nil : observation
            }
        } else { system.desktopObservation = native ? nil : observation }
        let before = system.frameWriteCounts, probes = system.probeRequests
        model.handleApplicationTopologyChange()
        if duringPreflight {
            #expect(invalidated)
            #expect(system.frameWriteCounts == before)
            #expect(system.probeRequests == probes)
            await system.joinWindowEvent(on: model)
            try await expectQuiet(system)
            system.onWindowSnapshots = nil
            model.watchdog()
        }
        await system.joinWindowEvent(on: model)
        try #require(await system.waitFor { model.settlementTasks.isEmpty })
        let frames = Dictionary(uniqueKeysWithValues: system.windows.map { ($0.id, $0.frame) })
        #expect(BentoLayoutVerifier.overlappingWindowIDs(frames).isEmpty)
        #expect(system.frameWriteCounts == [system.windows[0].id: 3, system.windows[1].id: 1])
        #expect(system.probeRequests == [[system.windows[1].id]])
        #expect(system.completeSweepCount == (duringPreflight ? 7 : 6))
        #expect(system.windows[0].frame == BTRect(x: 0, y: 0, width: 500, height: 800))
        #expect(system.windows[1].frame == BTRect(x: 501, y: 0, width: 499, height: 800))
        let pending = Mirror(reflecting: model).children.first {
            $0.label?.hasSuffix("applicationRecoveryPendingWindows") == true
        }?.value as? [WindowID: Int32]
        #expect(pending?.isEmpty == true)
        print("RECOVERY_CONTEXT_NO_CALLBACK native=\(native) preflight=\(duringPreflight) writes=\(system.frameWriteCounts) probes=\(system.probeRequests) sweeps=\(system.completeSweepCount) frames=\(frames)")
        try await expectQuiet(system)
    }

    @Test(arguments: [false, true])
    func capabilityChangeWithSeveralReturningWindows(native: Bool) async throws {
        let (system, model, observation) = try await prepareCapability(native: native, sibling: true)
        defer { model.shutdown() }
        system.desktopObservation = native ? nil : observation
        model.handleApplicationTopologyChange()
        await system.joinWindowEvent(on: model)
        try #require(await system.waitFor { model.settlementTasks.isEmpty })
        #expect(retained(model).isEmpty)
        #expect(system.windows[1].frame == BTRect(x: 0, y: 0, width: 500, height: 800))
        let frames = Dictionary(uniqueKeysWithValues: system.windows.map { ($0.id, $0.frame) })
        #expect(BentoLayoutVerifier.overlappingWindowIDs(frames).isEmpty)
        #expect(system.frameWriteCounts == [system.windows[0].id: 3, system.windows[1].id: 2, system.windows[2].id: 1])
        #expect(system.probeRequests == [[system.windows[2].id]])
        #expect(system.completeSweepCount == 9)
        #expect(system.windows[0].frame == BTRect(x: 501, y: 0, width: 499, height: 400))
        #expect(system.windows[2].frame == BTRect(x: 501, y: 401, width: 499, height: 399))
        print("RECOVERY_CONTEXT_SIBLING native=\(native) writes=\(system.frameWriteCounts) probes=\(system.probeRequests) sweeps=\(system.completeSweepCount) frames=\(frames)")
        try await expectQuiet(system)
    }

}
