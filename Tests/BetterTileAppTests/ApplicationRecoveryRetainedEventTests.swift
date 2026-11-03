import AppKit
import BetterTileCore
import Foundation
import Testing
@testable import BetterTileApp

@Suite(.appTestApplication, .serialized) @MainActor
struct ApplicationRecoveryRetainedEventTests {
    private func makeHeldSystem() -> FakeAppWindowSystem {
        _ = NSApplication.shared
        let system = makeManualWindowSystem()
        system.applicationHoldDuration = 60
        system.windows.append(WindowSnapshot(id: WindowID(rawValue: "held"), processIdentifier: 43,
            frame: BTRect(x: 300, y: 200, width: 600, height: 400), displayID: system.mainDisplay.id))
        system.unresponsiveProcessIDs = [43]
        system.cachedSnapshotsAvailable = false
        return system
    }
    private func retainedCount(_ model: BetterTileModel) -> Int {
        (Mirror(reflecting: model).children.first { $0.label?.hasSuffix("applicationRecoveryFrameEventPIDs") == true }?.value as? [WindowID: Int32])?.count ?? -1
    }
    @Test func latestFrameWinsAndEvidenceIsDeduplicated() async throws {
        let system = makeHeldSystem()
        let model = makeModel(system: system)
        defer { model.shutdown() }
        model.setActiveMode(.bento)
        system.windows[1].frame = BTRect(x: 0, y: 0, width: 500, height: 800)
        let held = system.windows[1]
        for _ in 0..<1000 {
            system.eventHandler?(WindowSystemEvent(kind: .resized, windowID: held.id, processIdentifier: 43))
        }
        await system.joinWindowEvent(on: model)
        #expect(retainedCount(model) == 1)
        let requested = BTRect(x: 500, y: 0, width: 500, height: 800)
        system.windows[1].frame = requested
        system.eventHandler?(WindowSystemEvent(kind: .moved, windowID: held.id, processIdentifier: 43))
        await system.joinWindowEvent(on: model)
        #expect(retainedCount(model) == 1)
        system.unresponsiveProcessIDs.removeAll()
        system.applicationHoldsUntil[43] = system.uptime + 0.05
        model.watchdog()
        try #require(await system.waitFor { system.frameWriteCounts[held.id] != nil && model.settlementTasks.isEmpty })
        #expect(system.windows[1].frame.approximatelyEquals(requested, tolerance: 1))
        #expect(retainedCount(model) == 0)
        let writes = system.frameWriteCounts
        model.watchdog()
        #expect(system.frameWriteCounts == writes)
    }
    @Test(arguments: ["topology", "watchdog"]) func returningSnapSurvivesOrdinaryReadBeforeRecoveryTimer(source: String) async throws {
        let system = makeHeldSystem()
        let model = makeModel(system: system)
        defer { model.shutdown() }
        model.setActiveMode(.bento)
        let requested = BTRect(x: 0, y: 0, width: 500, height: 800)
        system.windows[1].frame = requested
        system.eventHandler?(WindowSystemEvent(kind: .resized, windowID: system.windows[1].id, processIdentifier: 43))
        await system.joinWindowEvent(on: model)
        #expect(retainedCount(model) == 1)
        system.unresponsiveProcessIDs.removeAll()
        // An ordinary topology event reads the recovered app after hold expiry,
        // before the hold+0.1 recovery wake-up gets control.
        system.applicationHoldsUntil[43] = system.uptime + 0.08
        model.watchdog()
        if source == "topology" {
            system.eventHandler?(WindowSystemEvent(kind: .created, windowID: nil, processIdentifier: 42))
            await system.joinWindowEvent(on: model)
        } else {
            await system.advance(by: .milliseconds(100))
            model.watchdog()
        }
        try #require(await system.waitFor { model.settlementTasks.isEmpty })
        #expect(system.windows[1].frame.approximatelyEquals(requested, tolerance: 1))
    }

    @Test(arguments: ["snapBaseline", "snapValidation", "focusValidation", "clampReadback", "clampBaseline", "clampValidation"], ["space", "generation", "mode", "session"])
    func recoveredNativeSnapRejectsSpaceSwitchDuringMutationPreflight(stage: String, invalidation: String) async throws {
        let system = makeHeldSystem()
        let display = system.mainDisplay.id
        let first = NativeSpaceID(rawValue: 1), second = NativeSpaceID(rawValue: 2)
        system.desktopObservation = NativeDesktopObservation(currentSpaceByDisplay: [display: first],
            knownSpacesByDisplay: [display: [first, second]],
            windowMembership: Dictionary(uniqueKeysWithValues: system.windows.map { ($0.id, [first]) }))
        let model = makeModel(system: system)
        defer { model.shutdown() }
        model.configuration.defaultLayoutMode = .manual
        model.setActiveMode(.bento)
        let isFocus = stage == "focusValidation"
        let isClamp = stage.hasPrefix("clamp")
        system.windows[1].frame = isFocus ? system.mainDisplay.visibleFrame : BTRect(x: 0, y: 0, width: 500, height: 800)
        system.eventHandler?(WindowSystemEvent(kind: .resized, windowID: system.windows[1].id, processIdentifier: 43))
        await system.joinWindowEvent(on: model)
        try #require(retainedCount(model) == 1)
        if isClamp {
            system.measuresOnWrite = true
            system.enforcedMinimumWidths[system.windows[0].id] = 600
        }
        let initialWrites = system.frameWriteCounts
        let targetRead = ["snapBaseline": 1, "snapValidation": 2, "focusValidation": 1,
                          "clampReadback": 1, "clampBaseline": 2, "clampValidation": 3][stage]!
        var reads = 0
        var writesAtSwitch: [WindowID: Int]?
        var probesAtSwitch: [Set<WindowID>]?
        var minimizesAtSwitch: Set<WindowID>?
        system.onWindowSnapshots = { [weak system, weak model] in
            guard let system, let model, writesAtSwitch == nil, system.applicationHoldsUntil[43] == nil else { return }
            if isClamp && system.frameWriteCounts == initialWrites { return }
            reads += 1
            guard reads == targetRead else { return }
            writesAtSwitch = system.frameWriteCounts
            probesAtSwitch = system.probeRequests
            minimizesAtSwitch = Set(system.windows.filter(\.isMinimized).map(\.id))
            if invalidation == "generation" { model.beginActiveSpaceStabilization() }
            else if invalidation == "mode" { model.setActiveMode(.manual) }
            else {
                system.desktopObservation?.currentSpaceByDisplay[display] = second
                system.offscreenWindowIDs = Set(system.windows.map(\.id))
                if invalidation == "session" { model.beginActiveSpaceStabilization() }
            }
            writesAtSwitch = system.frameWriteCounts
            probesAtSwitch = system.probeRequests
            minimizesAtSwitch = Set(system.windows.filter(\.isMinimized).map(\.id))
        }
        system.unresponsiveProcessIDs.removeAll()
        system.applicationHoldsUntil[43] = system.uptime - 0.01
        model.watchdog()
        let writes = try #require(writesAtSwitch, "The recovered snap must reach the selected preflight read.")
        #expect(system.frameWriteCounts == writes, "No old-Space frame write may start after preflight.")
        #expect(system.probeRequests == probesAtSwitch)
        #expect(Set(system.windows.filter(\.isMinimized).map(\.id)) == minimizesAtSwitch, "No old-Space peer may be minimized.")
        if invalidation == "space", stage == "snapBaseline" || stage == "snapValidation" {
            system.onWindowSnapshots = nil
            model.beginActiveSpaceStabilization()
            try #require(await system.waitFor { !model.isStabilizingSpace })
            system.desktopObservation?.currentSpaceByDisplay[display] = first
            system.offscreenWindowIDs.removeAll()
            model.beginActiveSpaceStabilization()
            try #require(await system.waitFor { !model.isStabilizingSpace && model.settlementTasks.isEmpty })
            #expect(system.windows[1].frame.approximatelyEquals(BTRect(x: 0, y: 0, width: 500, height: 800), tolerance: 1))
        }
    }

    @Test(arguments: [1, 2], ["space", "generation", "mode", "session"])
    func recoverySettlementRejectsSpaceSwitchDuringMutationPreflight(targetRead: Int, invalidation: String) async throws {
        let system = makeHeldSystem()
        let display = system.mainDisplay.id
        let first = NativeSpaceID(rawValue: 1), second = NativeSpaceID(rawValue: 2)
        system.desktopObservation = NativeDesktopObservation(currentSpaceByDisplay: [display: first],
            knownSpacesByDisplay: [display: [first, second]],
            windowMembership: Dictionary(uniqueKeysWithValues: system.windows.map { ($0.id, [first]) }))
        let model = makeModel(system: system)
        defer { model.shutdown() }
        model.configuration.defaultLayoutMode = .manual
        model.setActiveMode(.bento)
        system.windows[1].frame = BTRect(x: 0, y: 0, width: 500, height: 800)
        system.eventHandler?(WindowSystemEvent(kind: .resized, windowID: system.windows[1].id, processIdentifier: 43))
        await system.joinWindowEvent(on: model)
        try #require(retainedCount(model) == 1)
        system.unresponsiveProcessIDs.removeAll()
        system.applicationHoldsUntil[43] = system.uptime - 0.01
        model.watchdog()
        try #require(model.settlementTasks[display] != nil)
        // The peer reveals a minimum only after the initial recovery placement.
        system.windows[0].frame.size.width = 600
        system.windows[0].constraints.minimumSize.width = 600
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
                system.desktopObservation?.currentSpaceByDisplay[display] = second
                system.offscreenWindowIDs = Set(system.windows.map(\.id))
                if invalidation == "session" { model.beginActiveSpaceStabilization() }
            }
            writesAtSwitch = system.frameWriteCounts
        }
        try #require(await system.waitFor { model.settlementTasks.isEmpty })
        let writes = try #require(writesAtSwitch, "Recovery settlement must reach the selected preflight read.")
        #expect(system.frameWriteCounts == writes, "Delayed recovery must keep its desktop validation through settlement.")
        #expect(system.probeRequests == probes)
    }

    @Test func destroyedWindowEvidenceDoesNotAccumulateOrTransferToAReplacement() async throws {
        let system = makeHeldSystem()
        let first = system.windows[1]
        for i in 0..<64 {
            var sibling = first
            sibling.id = WindowID(rawValue: "sibling-\(i)")
            system.windows.append(sibling)
        }
        let model = makeModel(system: system)
        defer { model.shutdown() }
        model.setActiveMode(.bento)
        for window in system.windows.dropFirst() {
            system.eventHandler?(WindowSystemEvent(kind: .resized, windowID: window.id, processIdentifier: 43))
        }
        await system.joinWindowEvent(on: model)
        #expect(retainedCount(model) == 65)
        for window in system.windows.dropFirst().dropFirst() {
            system.eventHandler?(WindowSystemEvent(kind: .destroyed, windowID: window.id, processIdentifier: 43))
        }
        system.windows.removeSubrange(2...)
        await system.joinWindowEvent(on: model)
        #expect(retainedCount(model) == 1)
        system.windows.removeLast()
        system.eventHandler?(WindowSystemEvent(kind: .destroyed, windowID: first.id, processIdentifier: 43))
        var replacement = first
        replacement.id = WindowID(rawValue: "replacement")
        system.windows.append(replacement)
        await system.joinWindowEvent(on: model)
        #expect(retainedCount(model) == 0)
        system.unresponsiveProcessIDs.removeAll()
        system.applicationHoldsUntil[43] = system.uptime + 0.05
        model.watchdog()
        try #require(await system.waitFor { system.frameWriteCounts[replacement.id] != nil && model.settlementTasks.isEmpty })
        #expect(system.frameWriteCounts[first.id] == nil)
        #expect(!system.windows[1].frame.approximatelyEquals(BTRect(x: 0, y: 0, width: 500, height: 800), tolerance: 1))
    }
    @Test func registrationDefaultUsesOnlyTheVolatileDomain() {
        let system = makeManualWindowSystem()
        let defaults = UserDefaults.standard
        let domain = Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName
        let before = defaults.persistentDomain(forName: domain)?["disableSharedGestureEvents"] as? Bool
        let model = makeModel(system: system)
        defer { model.shutdown() }
        #expect(defaults.volatileDomain(forName: UserDefaults.registrationDomain)["disableSharedGestureEvents"] as? Bool == true)
        #expect(defaults.persistentDomain(forName: domain)?["disableSharedGestureEvents"] as? Bool == before)
    }
}
