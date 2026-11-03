import AppKit
import BetterTileCore
import Foundation
import Testing
@testable import BetterTileApp

@Suite(.appTestApplication, .serialized) @MainActor
struct ApplicationRecoveryClassificationTests {
    private func retained(_ model: BetterTileModel) -> [WindowID: Int32] {
        Mirror(reflecting: model).children.first { $0.label?.hasSuffix("applicationRecoveryFrameEventPIDs") == true }?.value as? [WindowID: Int32] ?? [:]
    }
    @Test(arguments: [(false, false, false), (false, false, true), (true, false, false),
                      (true, false, true), (true, true, false), (true, true, true)])
    func returningSnapWithOneRejectedWrite(reject: Bool, changesLatestFrame: Bool, unrelatedCallback: Bool) async throws {
        _ = NSApplication.shared
        let system = makeManualWindowSystem()
        system.applicationHoldDuration = 60
        system.cachedSnapshotsAvailable = false
        let held = WindowID(rawValue: "held")
        system.windows.append(WindowSnapshot(id: held, processIdentifier: 43,
            frame: BTRect(x: 300, y: 200, width: 600, height: 400), displayID: system.mainDisplay.id))
        system.unresponsiveProcessIDs = [43]
        let model = makeModel(system: system)
        defer { model.shutdown() }
        model.primaryButtonIsPressed = { false }
        model.setActiveMode(.bento)
        let snap = BTRect(x: 0, y: 0, width: 500, height: 800)
        system.windows[1].frame = snap
        system.eventHandler?(WindowSystemEvent(kind: .resized, windowID: held, processIdentifier: 43))
        await system.joinWindowEvent(on: model)
        try #require(retained(model) == [held: 43])
        let before = system.frameWriteCounts
        if reject { system.failedFrameWriteNumbers[held] = [1] }
        system.unresponsiveProcessIDs.removeAll()
        system.applicationHoldsUntil[43] = system.uptime - 1
        model.watchdog()
        if reject {
            #expect(system.windows[1].frame == snap)
            #expect(system.frameWriteCounts == [system.windows[0].id: 1, held: 1])
            #expect(system.probeRequests.isEmpty)
            #expect(retained(model) == [held: 43])
        }
        if changesLatestFrame {
            system.windows[1].frame = BTRect(x: 0, y: 0, width: 1000, height: 400)
        }
        if unrelatedCallback {
            system.cachedSnapshotsAvailable = true
            system.eventHandler?(WindowSystemEvent(kind: .resized, windowID: system.windows[0].id, processIdentifier: 42))
        }
        await system.joinWindowEvent(on: model)
        try #require(await system.waitFor { model.settlementTasks.isEmpty })
        model.watchdog()
        await system.joinWindowEvent(on: model)
        try #require(await system.waitFor { model.settlementTasks.isEmpty })
        let expected = changesLatestFrame ? BTRect(x: 0, y: 0, width: 1000, height: 400)
            : BTRect(x: 0, y: 0, width: 500, height: 800)
        #expect(system.windows[1].frame == expected)
        #expect(system.probeRequests.isEmpty)
        #expect(retained(model).isEmpty)
        // Manual's sweep before Adaptive no longer places the lone eligible window, so it writes once less.
        #expect(system.frameWriteCounts == [system.windows[0].id: 2,
                                           held: reject || changesLatestFrame ? 3 : 2])
    }

    @Test(arguments: ["watchdog", "application", "wake", "AX"])
    func directTopologySweepHonorsRetainedSnap(entry: String) async throws {
        _ = NSApplication.shared
        let system = makeManualWindowSystem()
        system.applicationHoldDuration = 60
        system.cachedSnapshotsAvailable = false
        let held = WindowID(rawValue: "held")
        system.windows.append(WindowSnapshot(id: held, processIdentifier: 43,
            frame: BTRect(x: 300, y: 200, width: 600, height: 400), displayID: system.mainDisplay.id))
        system.unresponsiveProcessIDs = [43]
        let model = makeModel(system: system)
        defer { model.shutdown() }
        model.primaryButtonIsPressed = { false }
        model.setActiveMode(.bento)
        let snap = BTRect(x: 0, y: 0, width: 500, height: 800)
        system.windows[1].frame = snap
        system.eventHandler?(WindowSystemEvent(kind: .resized, windowID: held, processIdentifier: 43))
        await system.joinWindowEvent(on: model)
        try #require(retained(model) == [held: 43])
        system.unresponsiveProcessIDs.removeAll()
        system.applicationHoldsUntil[43] = system.uptime - 1
        // Same refresh entry used by app launch/termination and wake callbacks.
        switch entry {
        case "application": model.handleApplicationTopologyChange()
        case "wake": model.handleApplicationTopologyChange(waking: true)
        case "AX": system.eventHandler?(WindowSystemEvent(kind: .created, windowID: nil, processIdentifier: 42))
        default: model.watchdog()
        }
        await system.joinWindowEvent(on: model)
        try #require(await system.waitFor { model.settlementTasks.isEmpty })
        model.watchdog()
        await system.joinWindowEvent(on: model)
        try #require(await system.waitFor { model.settlementTasks.isEmpty })
        #expect(system.windows[1].frame == BTRect(x: 0, y: 0, width: 500, height: 800))
        // Manual's sweep before Adaptive no longer places the lone eligible window, so it writes once less.
        #expect(system.frameWriteCounts == [system.windows[0].id: 2, held: 2])
        #expect(system.probeRequests.isEmpty)
        #expect(retained(model).isEmpty)
    }

    @Test(arguments: [false, true]) func absentEvidenceCost(retainEvidence: Bool) async throws {
        _ = NSApplication.shared
        let system = makeManualWindowSystem()
        system.applicationHoldDuration = 60
        system.cachedSnapshotsAvailable = false
        let held = WindowID(rawValue: "held")
        system.windows.append(WindowSnapshot(id: held, processIdentifier: 43,
            frame: BTRect(x: 0, y: 0, width: 500, height: 800), displayID: system.mainDisplay.id))
        system.unresponsiveProcessIDs = [43]
        let model = makeModel(system: system)
        defer { model.shutdown() }
        model.primaryButtonIsPressed = { false }
        model.setActiveMode(.bento)
        if retainEvidence {
            system.eventHandler?(WindowSystemEvent(kind: .resized, windowID: held, processIdentifier: 43))
            await system.joinWindowEvent(on: model)
        }
        system.offscreenWindowIDs = [held]
        system.unresponsiveProcessIDs.removeAll()
        system.applicationHoldsUntil[43] = system.uptime - 1
        model.watchdog()
        await system.joinWindowEvent(on: model)
        let quietSweeps = system.completeSweepCount, writes = system.frameWriteCounts
        await system.advance(by: .milliseconds(1200))
        #expect(system.completeSweepCount == quietSweeps)
        #expect(system.frameWriteCounts == writes)
        #expect(retained(model) == (retainEvidence ? [held: 43] : [:]))
        system.cachedSnapshotsAvailable = true
        for _ in 0..<3 {
            system.eventHandler?(WindowSystemEvent(kind: .resized, windowID: system.windows[0].id, processIdentifier: 42))
            await system.joinWindowEvent(on: model)
        }
        #expect(system.frameWriteCounts == writes)
        #expect(system.completeSweepCount - quietSweeps == 3)
        #expect(system.cachedRefreshRequests.suffix(3).allSatisfy { $0 == [system.windows[0].id] })
        system.offscreenWindowIDs.removeAll()
        model.watchdog()
        await system.joinWindowEvent(on: model)
        try #require(await system.waitFor { model.settlementTasks.isEmpty })
        if retainEvidence {
            #expect(system.windows[1].frame == BTRect(x: 0, y: 0, width: 500, height: 800))
            #expect(system.probeRequests.isEmpty)
        }
        #expect(retained(model).isEmpty)
        system.windows.removeAll { $0.id == held }
        system.eventHandler?(WindowSystemEvent(kind: .destroyed, windowID: held, processIdentifier: 43))
        await system.joinWindowEvent(on: model)
        #expect(retained(model).isEmpty)
    }

    @Test(arguments: [false, true])
    func rejectedBatchPreservesEveryIdentityAndAllowsOtherDisplay(bothRejected: Bool) async throws {
        _ = NSApplication.shared
        let system = makeManualWindowSystem()
        system.applicationHoldDuration = 60
        system.cachedSnapshotsAvailable = false
        let second = DisplaySnapshot(id: DisplayID(rawValue: "second"),
            frame: BTRect(x: 1000, y: 0, width: 1000, height: 800),
            visibleFrame: BTRect(x: 1000, y: 0, width: 1000, height: 800))
        let third = DisplaySnapshot(id: DisplayID(rawValue: "third"),
            frame: BTRect(x: 2000, y: 0, width: 1000, height: 800),
            visibleFrame: BTRect(x: 2000, y: 0, width: 1000, height: 800))
        system.availableDisplays += [second, third]
        let held = WindowID(rawValue: "held-a"), sibling = WindowID(rawValue: "sibling-a")
        let other = WindowID(rawValue: "held-b"), peer = WindowID(rawValue: "peer-b")
        let safePeer = WindowID(rawValue: "peer-c"), arrival = WindowID(rawValue: "arrival-c")
        system.windows += [
            WindowSnapshot(id: held, processIdentifier: 43, frame: BTRect(x: 0, y: 0, width: 500, height: 800), displayID: system.mainDisplay.id),
            WindowSnapshot(id: sibling, processIdentifier: 43, frame: BTRect(x: 300, y: 200, width: 600, height: 400), displayID: system.mainDisplay.id),
            WindowSnapshot(id: peer, processIdentifier: 45, frame: BTRect(x: 1200, y: 200, width: 600, height: 400), displayID: second.id),
            WindowSnapshot(id: other, processIdentifier: 44, frame: BTRect(x: 1000, y: 0, width: 500, height: 800), displayID: second.id),
            WindowSnapshot(id: safePeer, processIdentifier: 46, frame: BTRect(x: 2200, y: 200, width: 600, height: 400), displayID: third.id),
        ]
        system.unresponsiveProcessIDs = [43, 44]
        let model = makeModel(system: system)
        defer { model.shutdown() }
        model.configuration.defaultLayoutMode = .bento
        model.handleApplicationTopologyChange()
        try #require(await system.waitFor { model.settlementTasks.isEmpty })
        for window in system.windows where [held, sibling, other].contains(window.id) {
            system.eventHandler?(WindowSystemEvent(kind: .resized, windowID: window.id, processIdentifier: window.processIdentifier))
        }
        await system.joinWindowEvent(on: model)
        try #require(retained(model) == [held: 43, sibling: 43, other: 44])
        let originalSibling = try #require(system.windows.first { $0.id == sibling }?.frame)
        system.windows.append(WindowSnapshot(id: arrival, processIdentifier: 47,
            frame: BTRect(x: 2300, y: 200, width: 600, height: 400), displayID: third.id))
        system.failedFrameWriteNumbers[held] = [1]
        if bothRejected { system.failedFrameWriteNumbers[other] = [1] }
        system.unresponsiveProcessIDs.removeAll()
        for pid: Int32 in [43, 44] { system.applicationHoldsUntil[pid] = system.uptime - 1 }
        model.handleApplicationTopologyChange()
        #expect(system.windows.first { $0.id == held }?.frame == BTRect(x: 0, y: 0, width: 500, height: 800))
        #expect(system.windows.first { $0.id == sibling }?.frame == originalSibling)
        #expect(retained(model) == (bothRejected ? [held: 43, sibling: 43, other: 44] : [held: 43, sibling: 43]))
        #expect(system.probeRequests == [[arrival]])
        #expect(system.frameWriteCounts == [system.windows[0].id: 1, held: 1, other: bothRejected ? 1 : 2,
                                           peer: bothRejected ? 1 : 2, safePeer: 2, arrival: 1])
        await system.joinWindowEvent(on: model)
        try #require(await system.waitFor { model.settlementTasks.isEmpty })
        model.watchdog()
        await system.joinWindowEvent(on: model)
        try #require(await system.waitFor { model.settlementTasks.isEmpty })
        #expect(system.windows.first { $0.id == held }?.frame == BTRect(x: 0, y: 0, width: 500, height: 800))
        #expect(system.windows.first { $0.id == other }?.frame == BTRect(x: 1000, y: 0, width: 500, height: 800))
        #expect(retained(model).isEmpty)
        #expect(system.probeRequests == [[arrival]])
        #expect(system.frameWriteCounts == [system.windows[0].id: 2, held: 3, sibling: 1,
                                           other: bothRejected ? 3 : 2, peer: 2, safePeer: 2, arrival: 1])
        #expect(system.windows.first { $0.id == system.windows[0].id }?.frame == BTRect(x: 501, y: 0, width: 499, height: 400))
        #expect(system.windows.first { $0.id == sibling }?.frame == BTRect(x: 501, y: 401, width: 499, height: 399))
        #expect(system.windows.first { $0.id == arrival }?.frame == BTRect(x: 2000, y: 0, width: 500, height: 800))
        #expect(system.windows.first { $0.id == safePeer }?.frame == BTRect(x: 2501, y: 0, width: 499, height: 800))
        #expect(system.windows.first { $0.id == peer }?.frame == BTRect(x: 1501, y: 0, width: 499, height: 800))
        let writes = system.frameWriteCounts, sweeps = system.completeSweepCount
        await system.advance(by: .milliseconds(1200))
        #expect(system.frameWriteCounts == writes)
        #expect(system.completeSweepCount == sweeps)
    }

    @Test(arguments: ["clean", "degraded", "deferred", "unplannable"])
    func unresolvedClassificationDoesNotRetryOnItsOwn(outcome: String) async throws {
        _ = NSApplication.shared
        let system = makeManualWindowSystem()
        system.applicationHoldDuration = 60
        system.cachedSnapshotsAvailable = false
        let held = WindowID(rawValue: "held"), focused = system.windows[0].id
        system.windows.append(WindowSnapshot(id: held, processIdentifier: 43,
            frame: BTRect(x: 300, y: 200, width: 600, height: 400), displayID: system.mainDisplay.id))
        if outcome != "degraded" { system.unresponsiveProcessIDs = [43] }
        let model = makeModel(system: system)
        defer { model.shutdown() }
        if outcome == "degraded" { model.configuration.bentoInnerGap = 0 }
        model.setActiveMode(.bento)
        try #require(await system.waitFor { model.settlementTasks.isEmpty })
        system.unresponsiveProcessIDs = [43]
        system.applicationHoldsUntil[43] = system.uptime + 60
        let snap = BTRect(x: 0, y: 0, width: 500, height: 800)
        system.windows[1].frame = snap
        system.eventHandler?(WindowSystemEvent(kind: .resized, windowID: held, processIdentifier: 43))
        await system.joinWindowEvent(on: model)
        var before = system.frameWriteCounts
        let originalConstraints = system.windows[1].constraints
        if outcome == "unplannable" {
            system.windows[1].constraints.minimumSize = BTSize(width: 1200, height: 900)
        } else if outcome == "deferred" {
            // A non-snap sample must wait behind the existing settlement owner.
            system.windows[1].frame = BTRect(x: 250, y: 150, width: 600, height: 400)
            model.perform(.rightHalf)
            try #require(model.settlementTasks[system.mainDisplay.id] != nil)
            before = system.frameWriteCounts
        } else {
            system.failedFrameWriteNumbers[held] = [before[held, default: 0] + 1]
            if outcome == "degraded" { system.failedFrameWriteNumbers[focused] = [before[focused, default: 0] + 2] }
        }
        system.unresponsiveProcessIDs.removeAll()
        system.applicationHoldsUntil[43] = system.uptime - 1
        model.handleApplicationTopologyChange()
        #expect(retained(model) == [held: 43])
        #expect(system.probeRequests.isEmpty)
        // Manual's sweep before Adaptive no longer places the lone eligible window. Only "degraded",
        // where the held app answers during setup and Manual sees two windows, keeps its counts.
        #expect(system.frameWriteCounts == (outcome == "deferred" ? [focused: 2]
            : outcome == "unplannable" ? [focused: 1] : outcome == "clean" ? [focused: 1, held: 1] : [focused: 3, held: 2]))
        if outcome == "degraded" {
            let store = Mirror(reflecting: model).children.first { $0.label?.hasSuffix("sessionStore") == true }?.value as? LayoutSessionStore
            #expect(store?.session(for: system.mainDisplay.id)?.automaticWritesSuspended == true)
            #expect(model.statusMessage?.contains("Use Repair") == true)
        }
        await system.joinWindowEvent(on: model)
        try #require(await system.waitFor { model.settlementTasks.isEmpty })
        let writes = system.frameWriteCounts, sweeps = system.completeSweepCount
        await system.advance(by: .milliseconds(1200))
        #expect(system.frameWriteCounts == writes)
        #expect(system.completeSweepCount == sweeps)
        if outcome == "deferred" { system.windows[1].frame = snap }
        system.windows[1].constraints = originalConstraints
        model.watchdog()
        if outcome == "degraded" {
            #expect(system.frameWriteCounts == writes)
            #expect(retained(model) == [held: 43])
        } else {
            #expect(system.windows[1].frame == BTRect(x: 0, y: 0, width: 500, height: 800))
            #expect(retained(model).isEmpty)
        }
        #expect(system.frameWriteCounts == (outcome == "deferred" ? [focused: 3, held: 1]
            : outcome == "unplannable" ? [focused: 2, held: 2] : outcome == "clean" ? [focused: 2, held: 3] : [focused: 3, held: 2]))

    }

    @Test(arguments: [false, true])
    func laterReadableIdentityWaitsForClassification(sameDisplay: Bool) async throws {
        _ = NSApplication.shared
        let system = makeManualWindowSystem()
        system.applicationHoldDuration = 60
        system.cachedSnapshotsAvailable = false
        let second = DisplaySnapshot(id: DisplayID(rawValue: "second"),
            frame: BTRect(x: 1000, y: 0, width: 1000, height: 800),
            visibleFrame: BTRect(x: 1000, y: 0, width: 1000, height: 800))
        if !sameDisplay {
            system.availableDisplays.append(second)
            system.windows.append(WindowSnapshot(id: WindowID(rawValue: "peer"), processIdentifier: 45,
                frame: BTRect(x: 1200, y: 200, width: 600, height: 400), displayID: second.id))
        }
        let first = WindowID(rawValue: "held-a"), later = WindowID(rawValue: "held-b")
        let destination = sameDisplay ? system.mainDisplay : second
        let latest = BTRect(x: destination.visibleFrame.minX, y: 0, width: 1000, height: 400)
        system.windows += [
            WindowSnapshot(id: first, processIdentifier: 43, frame: BTRect(x: 0, y: 0, width: 500, height: 800), displayID: system.mainDisplay.id),
            WindowSnapshot(id: later, processIdentifier: 44, frame: latest, displayID: destination.id),
        ]
        system.unresponsiveProcessIDs = [43, 44]
        let model = makeModel(system: system)
        defer { model.shutdown() }
        model.configuration.defaultLayoutMode = .bento
        model.handleApplicationTopologyChange()
        // Establish an actual tree on each display before testing recovery.
        for window in system.windows where window.processIdentifier == 42 || window.processIdentifier == 45 {
            system.focusedID = window.id
            model.perform(.leftHalf)
        }
        system.focusedID = nil
        try #require(await system.waitFor { model.settlementTasks.isEmpty })
        let initializedStore = Mirror(reflecting: model).children.first {
            $0.label?.hasSuffix("sessionStore") == true
        }?.value as? LayoutSessionStore
        for window in system.windows where window.processIdentifier == 42 || window.processIdentifier == 45 {
            try #require(initializedStore?.session(for: window.displayID)?.bentoState.root?.windowIDs.contains(window.id) == true)
        }
        for window in system.windows where [first, later].contains(window.id) {
            system.eventHandler?(WindowSystemEvent(kind: .resized, windowID: window.id, processIdentifier: window.processIdentifier))
        }
        await system.joinWindowEvent(on: model)
        try #require(retained(model) == [first: 43, later: 44])
        system.unresponsiveProcessIDs.removeAll()
        system.applicationHoldsUntil[43] = system.uptime - 1
        let initialSweep = system.completeSweepCount + 1
        var releasedLater = false
        system.onVisibleWindowSweep = { [weak system] count in
            guard count > initialSweep, !releasedLater else { return }
            releasedLater = true
            system?.applicationHoldsUntil[44] = (system?.uptime ?? 1000) - 1
        }
        model.handleApplicationTopologyChange()
        system.onVisibleWindowSweep = nil
        #expect(retained(model) == [later: 44])
        #expect(system.windows.first { $0.id == later }?.frame == latest)
        #expect(system.frameWriteCounts == (sameDisplay ? [system.windows[0].id: 3, first: 1]
            : [system.windows[0].id: 3, first: 1, WindowID(rawValue: "peer"): 2]))
        #expect(system.probeRequests.isEmpty)
        await system.joinWindowEvent(on: model)
        try #require(await system.waitFor { model.settlementTasks.isEmpty })
        model.watchdog()
        await system.joinWindowEvent(on: model)
        try #require(await system.waitFor { model.settlementTasks.isEmpty })
        #expect(system.windows.first { $0.id == later }?.frame == BTRect(x: latest.minX, y: 0, width: 1000, height: 400))
        #expect(retained(model).isEmpty)
        #expect(system.probeRequests.isEmpty)
        #expect(system.frameWriteCounts == (sameDisplay ? [system.windows[0].id: 4, first: 2, later: 1]
            : [system.windows[0].id: 3, first: 1, later: 1, WindowID(rawValue: "peer"): 3]))
    }

    @Test(arguments: [false, true], [false, true])
    func deferredDisplayKeepsLifecycleEvidence(minimized: Bool, transitionBookkeeping: Bool) async throws {
        _ = NSApplication.shared
        let system = makeManualWindowSystem()
        system.applicationHoldDuration = 60
        system.cachedSnapshotsAvailable = false
        let peer = WindowID(rawValue: "peer"), held = WindowID(rawValue: "held")
        system.windows.append(WindowSnapshot(id: peer, processIdentifier: 45,
            frame: BTRect(x: 300, y: 200, width: 600, height: 400), displayID: system.mainDisplay.id))
        system.windows.append(WindowSnapshot(id: held, processIdentifier: 43,
            frame: BTRect(x: 0, y: 0, width: 500, height: 800), displayID: system.mainDisplay.id))
        system.unresponsiveProcessIDs = [43]
        let model = makeModel(system: system)
        defer { model.shutdown() }
        model.setActiveMode(.bento)
        try #require(await system.waitFor { model.settlementTasks.isEmpty })
        system.eventHandler?(WindowSystemEvent(kind: .resized, windowID: held, processIdentifier: 43))
        await system.joinWindowEvent(on: model)
        if transitionBookkeeping {
            system.offscreenWindowIDs = [peer]
            model.beginActiveSpaceStabilization()
            try #require(await system.waitFor { !model.isStabilizingSpace })
            let transitioned = Mirror(reflecting: model).children.first {
                $0.label?.hasSuffix("sessionStore") == true
            }?.value as? LayoutSessionStore
            try #require(transitioned?.session(for: system.mainDisplay.id)?.bentoState.root?.windowIDs.contains(peer) == true)
            try #require(transitioned?.session(for: system.mainDisplay.id)?.windowIDs.contains(peer) == false)
            system.offscreenWindowIDs.removeAll()
        }
        if minimized { system.windows[1].isMinimized = true }
        else { system.windows.removeAll { $0.id == peer } }
        system.eventHandler?(WindowSystemEvent(kind: minimized ? .minimized : .destroyed, windowID: peer, processIdentifier: 45))
        system.unresponsiveProcessIDs.removeAll()
        system.applicationHoldsUntil[43] = system.uptime - 1
        system.failedFrameWriteNumbers[held] = [1]
        model.handleApplicationTopologyChange()
        func lifecycleEvidence() -> Set<WindowID> {
            let name = minimized ? "confirmedMinimizedWindowIDs" : "confirmedGoneWindowIDs"
            return Mirror(reflecting: model).children.first { $0.label?.hasSuffix(name) == true }?.value as? Set<WindowID> ?? []
        }
        #expect(retained(model) == [held: 43])
        #expect(lifecycleEvidence() == [peer])
        #expect(system.frameWriteCounts == [system.windows[0].id: 3, peer: 1, held: 1])
        #expect(system.probeRequests.isEmpty)
        await system.joinWindowEvent(on: model)
        model.watchdog()
        await system.joinWindowEvent(on: model)
        try #require(await system.waitFor { model.settlementTasks.isEmpty })
        #expect(lifecycleEvidence().isEmpty)
        #expect(system.frameWriteCounts == [system.windows[0].id: 4, peer: 1, held: 2])
        #expect(retained(model).isEmpty)
        #expect(system.windows.first { $0.id == held }?.frame == BTRect(x: 0, y: 0, width: 500, height: 800))
        #expect(system.probeRequests.isEmpty)
    }
}
