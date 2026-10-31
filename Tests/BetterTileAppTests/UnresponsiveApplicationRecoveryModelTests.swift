import AppKit
import BetterTileCore
import Foundation
import Testing
@testable import BetterTileApp

@Suite(.appTestApplication, .serialized) @MainActor
struct ApplicationRecoveryTests {
    @Test @MainActor
    func heldApplicationReturnsToBentoWithoutAnotherEvent() async throws {
        _ = NSApplication.shared
        let system = makeManualWindowSystem()
        let held = WindowSnapshot(
            id: WindowID(rawValue: "held"), processIdentifier: 43,
            frame: BTRect(x: 300, y: 200, width: 600, height: 400), displayID: system.mainDisplay.id
        )
        system.windows.append(held)
        system.unresponsiveProcessIDs = [held.processIdentifier]
        let model = makeModel(system: system)
        defer { model.shutdown() }
        model.setActiveMode(.bento)
        try #require(system.applicationHoldsUntil[held.processIdentifier] != nil)
        #expect(system.windows.first { $0.id == held.id }?.frame == held.frame)

        system.unresponsiveProcessIDs.removeAll()
        await system.advance(by: .seconds(system.applicationHoldDuration))
        #expect(await system.waitFor(timeout: .milliseconds(500)) {
            system.windows.first { $0.id == held.id }?.frame != held.frame
                && system.windows.allSatisfy { $0.frame.size.height == 800 }
                && Set(system.windows.map(\.frame)).count == 2
        }, "A responsive app must rejoin Bento within 0.5 s of hold expiry, without another event.")
    }

    @Test @MainActor
    func applicationRecoveryStopsAfterThreeAttempts() async throws {
        _ = NSApplication.shared
        let system = makeManualWindowSystem()
        let held = addHeldApplication(to: system)
        let model = makeModel(system: system)
        defer { model.shutdown() }
        model.setActiveMode(.bento)
        try #require(await system.waitFor(timeout: .seconds(5)) {
            system.unresponsiveInventoryAttemptTimes[held.processIdentifier]?.count == 4
        })
        let times = try #require(system.unresponsiveInventoryAttemptTimes[held.processIdentifier])
        #expect(times[1] - times[0] >= system.applicationHoldDuration)
        #expect(times[2] - times[1] >= 0.99)
        #expect(times[3] - times[2] >= 1.99)
        let sweeps = system.completeSweepCount
        await system.advance(by: .milliseconds(600))
        #expect(system.completeSweepCount == sweeps)
        #expect(system.windows.first { $0.id == held.id }?.frame == held.frame)

        // An ordinary watchdog sweep must not restart the exhausted retry budget.
        model.watchdog()
        let afterWatchdog = system.completeSweepCount
        await system.advance(by: .milliseconds(600))
        #expect(system.completeSweepCount == afterWatchdog)
    }

    @Test @MainActor
    func applicationRecoveryStopsWhenTheApplicationQuits() async throws {
        _ = NSApplication.shared
        let system = makeManualWindowSystem()
        let held = addHeldApplication(to: system)
        let model = makeModel(system: system)
        defer { model.shutdown() }
        model.setActiveMode(.bento)
        let sweeps = system.completeSweepCount
        system.windows.removeAll { $0.processIdentifier == held.processIdentifier }
        await system.advance(by: .milliseconds(600))
        #expect(system.completeSweepCount == sweeps)
        #expect(system.unresponsiveInventoryAttemptTimes[held.processIdentifier]?.count == 1)
        #expect(system.frameWriteCounts[held.id] == nil)
    }

    @Test @MainActor
    func applicationRecoveryUsesTheCurrentDesktopAfterASpaceSwitch() async throws {
        _ = NSApplication.shared
        let system = makeManualWindowSystem()
        system.applicationHoldDuration = 0.6
        let held = addHeldApplication(to: system)
        let firstSpace = NativeSpaceID(rawValue: 1)
        let secondSpace = NativeSpaceID(rawValue: 2)
        let displayID = system.mainDisplay.id
        system.desktopObservation = NativeDesktopObservation(
            currentSpaceByDisplay: [displayID: firstSpace],
            knownSpacesByDisplay: [displayID: [firstSpace, secondSpace]],
            windowMembership: Dictionary(uniqueKeysWithValues: system.windows.map { ($0.id, [firstSpace]) })
        )
        let model = makeModel(system: system)
        defer { model.shutdown() }
        model.configuration.defaultLayoutMode = .manual
        model.configuration.singleWindowPlacement = nil
        model.setActiveMode(.bento)
        let oldFrames = system.windows.map(\.frame)
        let writes = system.frameWriteCounts
        let other = WindowSnapshot(
            id: WindowID(rawValue: "other-space"), processIdentifier: 44,
            frame: BTRect(x: 100, y: 100, width: 400, height: 300), displayID: displayID
        )
        system.windows.append(other)
        system.desktopObservation?.windowMembership[other.id] = [secondSpace]
        system.desktopObservation?.currentSpaceByDisplay[displayID] = secondSpace
        system.offscreenWindowIDs = Set(system.windows.dropLast().map(\.id))
        model.beginActiveSpaceStabilization()
        system.unresponsiveProcessIDs.removeAll()
        try #require(await system.waitFor { !model.isStabilizingSpace })
        #expect(model.activeMode(for: displayID) == .manual)
        await system.advance(by: .milliseconds(900))
        #expect(Array(system.windows.prefix(2).map(\.frame)) == oldFrames)
        #expect(system.windows.last?.frame == other.frame)
        #expect(system.frameWriteCounts == writes)
        #expect(system.frameWriteCounts[held.id] == nil)
    }

    @Test @MainActor
    func applicationRecoveryPreservesANewerManualAction() async throws {
        _ = NSApplication.shared
        let system = makeManualWindowSystem()
        system.applicationHoldDuration = 0.4
        let held = addHeldApplication(to: system)
        let model = makeModel(system: system)
        defer { model.shutdown() }
        model.setActiveMode(.bento)
        model.setActiveMode(.manual)
        model.perform(.rightHalf)
        let requested = system.windows[0].frame
        system.unresponsiveProcessIDs.removeAll()
        await system.advance(by: .milliseconds(900))
        #expect(model.activeMode(for: system.mainDisplay.id) == .manual)
        #expect(system.windows[0].frame == requested)
        #expect(system.windows.first { $0.id == held.id }?.frame == held.frame)
        #expect(system.frameWriteCounts[held.id] == nil)
    }

    @Test @MainActor
    func applicationRecoveryPrioritizesANewEarlierHold() async throws {
        _ = NSApplication.shared
        let system = makeManualWindowSystem()
        system.applicationHoldDuration = 3
        let held = addHeldApplication(to: system)
        let model = makeModel(system: system)
        defer { model.shutdown() }
        model.setActiveMode(.bento)

        let earlier = WindowSnapshot(
            id: WindowID(rawValue: "earlier"), processIdentifier: 44,
            frame: BTRect(x: 200, y: 100, width: 600, height: 400), displayID: system.mainDisplay.id
        )
        system.windows.append(earlier)
        system.applicationHoldDuration = 0.15
        system.unresponsiveProcessIDs.insert(earlier.processIdentifier)
        model.setActiveMode(.bento)
        system.unresponsiveProcessIDs.remove(earlier.processIdentifier)
        await system.advance(by: .seconds(system.applicationHoldDuration))
        #expect(await system.waitFor(timeout: .milliseconds(500)) {
            system.windows.first { $0.id == earlier.id }?.frame != earlier.frame
        })
        #expect(system.windows.first { $0.id == held.id }?.frame == held.frame)
    }

    @Test @MainActor
    func applicationRecoveryPreservesANewerBentoPartition() async throws {
        _ = NSApplication.shared
        let system = makeManualWindowSystem()
        system.applicationHoldDuration = 0.4
        let held = addHeldApplication(to: system)
        let model = makeModel(system: system)
        defer { model.shutdown() }
        model.setActiveMode(.bento)
        model.perform(.leftHalf)
        let requested = system.windows[0].frame
        system.unresponsiveProcessIDs.removeAll()
        #expect(await system.waitFor(timeout: .seconds(1)) {
            system.windows.first { $0.id == held.id }?.frame != held.frame
        })
        #expect(system.windows[0].frame == requested)
        #expect(system.windows[0].frame.maxX <= system.windows[1].frame.minX)
    }

    @Test @MainActor
    func applicationRecoveryPreservesAPendingNativeSnap() async throws {
        _ = NSApplication.shared
        let system = makeManualWindowSystem()
        system.applicationHoldDuration = 60
        let held = addHeldApplication(to: system)
        let model = makeModel(system: system)
        defer { model.shutdown() }
        model.setActiveMode(.bento)
        model.perform(.leftHalf)
        try #require(await system.waitFor { model.settlementTasks.isEmpty })
        system.applicationHoldsUntil[held.processIdentifier] = system.uptime + 0.15
        model.watchdog()

        let requested = BTRect(x: 500, y: 0, width: 500, height: 800)
        system.windows[0].frame = requested
        system.eventHandler?(WindowSystemEvent(
            kind: .resized, windowID: system.windows[0].id, processIdentifier: system.windows[0].processIdentifier
        ))
        // Leave the native event pending so recovery must handle it before arrival.
        model.windowEventTask?.cancel()
        system.unresponsiveProcessIDs.removeAll()
        #expect(await system.waitFor(timeout: .seconds(1)) {
            system.windows.first { $0.id == held.id }?.frame != held.frame
        })
        #expect(system.windows[0].frame.approximatelyEquals(requested, tolerance: 1))
        #expect(system.windows[1].frame.maxX <= system.windows[0].frame.minX)
    }

    @MainActor private func addHeldApplication(to system: FakeAppWindowSystem) -> WindowSnapshot {
        let held = WindowSnapshot(
            id: WindowID(rawValue: "held"), processIdentifier: 43,
            frame: BTRect(x: 300, y: 200, width: 600, height: 400), displayID: system.mainDisplay.id
        )
        system.windows.append(held)
        system.unresponsiveProcessIDs = [held.processIdentifier]
        return held
    }

    @Test @MainActor
    func applicationRecoveryShutdownCancelsPendingWakeup() async throws {
        _ = NSApplication.shared
        let system = makeManualWindowSystem()
        system.windows.append(WindowSnapshot(id: WindowID(rawValue: "held"), processIdentifier: 43,
            frame: BTRect(x: 300, y: 200, width: 600, height: 400), displayID: system.mainDisplay.id))
        system.unresponsiveProcessIDs = [43]
        var model: BetterTileModel? = makeModel(system: system)
        weak let released = model
        model?.setActiveMode(.bento)
        model?.shutdown()
        model = nil
        let sweeps = system.completeSweepCount
        await system.advance(by: .milliseconds(600))
        #expect(released == nil)
        #expect(system.completeSweepCount == sweeps)
    }

    @Test @MainActor
    func applicationRecoveryReadoptsIntoTabbed() async throws {
        _ = NSApplication.shared
        let system = makeManualWindowSystem()
        let held = WindowSnapshot(id: WindowID(rawValue: "held"), processIdentifier: 43,
            frame: BTRect(x: 300, y: 200, width: 600, height: 400), displayID: system.mainDisplay.id)
        system.windows.append(held)
        system.unresponsiveProcessIDs = [43]
        let model = makeModel(system: system)
        defer { model.shutdown() }
        model.setActiveMode(.tabbed)
        system.unresponsiveProcessIDs.removeAll()
        #expect(await system.waitFor(timeout: .seconds(1)) {
            model.activeTabbedState?.windowIDs.contains(held.id) == true
                && !model.hasPendingTabbedPlacement
        })
    }

    @Test @MainActor
    func applicationRecoveryPreservesNativeSnapOnReturningWindow() async throws {
        _ = NSApplication.shared
        let system = makeManualWindowSystem()
        system.applicationHoldDuration = 0.4
        let held = WindowSnapshot(id: WindowID(rawValue: "held"), processIdentifier: 43,
            frame: BTRect(x: 300, y: 200, width: 600, height: 400), displayID: system.mainDisplay.id)
        system.windows.append(held)
        system.unresponsiveProcessIDs = [43]
        let model = makeModel(system: system)
        defer { model.shutdown() }
        model.setActiveMode(.bento)
        let requested = BTRect(x: 0, y: 0, width: 500, height: 800)
        system.unresponsiveProcessIDs.removeAll()
        system.windows[1].frame = requested
        system.eventHandler?(WindowSystemEvent(kind: .resized, windowID: held.id, processIdentifier: 43))
        model.windowEventTask?.cancel()
        #expect(await system.waitFor(timeout: .seconds(1)) { system.frameWriteCounts[held.id] != nil })
        #expect(system.windows[1].frame.approximatelyEquals(requested, tolerance: 1))
        try #require(await system.waitFor { model.settlementTasks.isEmpty })
        let writes = system.frameWriteCounts
        model.watchdog()
        #expect(system.frameWriteCounts == writes, "The adopted membership must not rebuild on the next sweep")
        #expect(system.windows[1].frame.approximatelyEquals(requested, tolerance: 1))
    }

    @Test(arguments: [false, true]) @MainActor
    func applicationRecoveryPreservesNativeSnapWhileSettlementIsPending(samplesMinimumBeforeReturn: Bool) async throws {
        _ = NSApplication.shared
        let system = makeManualWindowSystem()
        system.applicationHoldDuration = 0.02
        let held = WindowSnapshot(id: WindowID(rawValue: "held"), processIdentifier: 43,
            frame: BTRect(x: 300, y: 200, width: 600, height: 400), displayID: system.mainDisplay.id)
        system.windows.append(held)
        system.unresponsiveProcessIDs = [43]
        system.enforcedMinimumWidths[system.windows[0].id] = 510
        let model = makeModel(system: system)
        defer { model.shutdown() }
        model.setActiveMode(.bento)
        // Entry maximizes the source. Start this action at its kept size, so a delayed
        // settlement sample cannot prove a shrink from 1,000 points and reject the later snap.
        system.windows[0].frame.size.width = 510
        let baseline = system.windows[0].frame
        model.perform(.leftHalf)
        // The source kept 510 points when the previous partition requested 500.
        #expect(system.windows[0].frame.size == baseline.size)
        try #require(!model.settlementTasks.isEmpty)
        let requested = BTRect(x: 500, y: 0, width: 510, height: 800)
        system.windows[0].frame = requested
        system.eventHandler?(WindowSystemEvent(kind: .resized, windowID: system.windows[0].id, processIdentifier: 42))
        model.windowEventTask?.cancel()
        if samplesMinimumBeforeReturn {
            // Settlement can sample before a delayed recovery task. A kept size must not prove
            // a shrinking minimum and make the native half-screen destination unplannable.
            let partitionFrame = try #require(system.requestedFrames[system.windows[0].id]?.last)
            #expect(!system.observeApplicationEnforcedMinimum(windowID: system.windows[0].id,
                requested: partitionFrame, baseline: baseline, actual: requested))
        }
        system.unresponsiveProcessIDs.removeAll()
        #expect(await system.waitFor(timeout: .seconds(1)) { system.frameWriteCounts[held.id] != nil })
        #expect(abs(system.windows[0].frame.minX - requested.minX) <= 1)
        try #require(await system.waitFor { model.settlementTasks.isEmpty })
        #expect(abs(system.windows[0].frame.minX - requested.minX) <= 1)
    }

    @Test @MainActor
    func applicationRecoveryBoundsRealisticMainActorTimeouts() async throws {
        _ = NSApplication.shared
        let system = makeManualWindowSystem()
        system.applicationHoldDuration = 2
        system.unresponsiveInventoryDelay = 0.35
        for pid: Int32 in [43, 44] {
            system.windows.append(WindowSnapshot(id: WindowID(rawValue: "held-\(pid)"), processIdentifier: pid,
                frame: BTRect(x: 300, y: 200, width: 600, height: 400), displayID: system.mainDisplay.id))
        }
        system.unresponsiveProcessIDs = [43, 44]
        let model = makeModel(system: system)
        defer { model.shutdown() }
        model.setActiveMode(.bento)
        try #require(await system.waitFor(timeout: .seconds(20)) {
            [Int32(43), 44].allSatisfy { (system.unresponsiveInventoryAttemptTimes[$0]?.count ?? 0) >= 4 }
        })
        // Let the other app's last timer fire after the first app exhausts its budget.
        await system.advance(by: .seconds(3))
        for pid: Int32 in [43, 44] {
            #expect(system.unresponsiveInventoryAttemptTimes[pid]?.count == 4,
                "Initial inventory plus at most three recovery probes per app")
        }
        let sweeps = system.completeSweepCount
        await system.advance(by: .milliseconds(600))
        #expect(system.completeSweepCount == sweeps)
    }

    @Test @MainActor
    func applicationRecoveryRejectsSpaceSwitchDuringPrePlacementReads() async throws {
        _ = NSApplication.shared
        let system = makeManualWindowSystem()
        let display = system.mainDisplay.id
        let first = NativeSpaceID(rawValue: 1), second = NativeSpaceID(rawValue: 2)
        let held = WindowSnapshot(id: WindowID(rawValue: "held"), processIdentifier: 43,
            frame: BTRect(x: 300, y: 200, width: 600, height: 400), displayID: display)
        system.windows.append(held)
        system.unresponsiveProcessIDs = [43]
        system.desktopObservation = NativeDesktopObservation(currentSpaceByDisplay: [display: first],
            knownSpacesByDisplay: [display: [first, second]],
            windowMembership: Dictionary(uniqueKeysWithValues: system.windows.map { ($0.id, [first]) }))
        let model = makeModel(system: system)
        defer { model.shutdown() }
        model.configuration.defaultLayoutMode = .manual
        model.configuration.singleWindowPlacement = nil
        model.setActiveMode(.bento)
        let writes = system.frameWriteCounts
        var switched = false
        system.onWindowSnapshots = { [weak system] in
            guard let system, !switched, system.applicationHoldsUntil[43] == nil else { return }
            switched = true
            system.desktopObservation?.currentSpaceByDisplay[display] = second
            system.offscreenWindowIDs = Set(system.windows.map(\.id))
        }
        system.unresponsiveProcessIDs.removeAll()
        try #require(await system.waitFor(timeout: .seconds(1)) { switched })
        #expect(system.frameWriteCounts == writes, "No frame placement from the old Space may follow the switch")
    }
}
