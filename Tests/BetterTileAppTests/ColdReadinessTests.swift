import BetterTileCore
import Foundation
import Testing
@testable import BetterTileApp

@Suite(.appTestApplication, .serialized) @MainActor
struct ColdReadinessTests {
    private func fixture(_ mode: LayoutMode) async throws -> (FakeAppWindowSystem, BetterTileModel) {
        let s = makeManualWindowSystem()
        let m = makeModel(system: s)
        m.configuration.singleWindowPlacement = .maximize
        m.setActiveMode(mode)
        try #require(await s.waitFor { m.settlementTasks.isEmpty && (mode != .tabbed || m.activeTabbedState != nil) })
        try await waitForWindowEventsToDrain(m, s)
        return (s, m)
    }
    private func add(_ name: String, _ s: FakeAppWindowSystem, pid: Int32 = 81, floating: Bool = false) -> WindowID {
        let id = WindowID(rawValue: name)
        s.windows.append(WindowSnapshot(id: id, processIdentifier: pid,
            frame: BTRect(x: 200, y: 200, width: 600, height: 400), displayID: s.mainDisplay.id, isFloating: floating))
        return id
    }
    private func created(_ s: FakeAppWindowSystem, _ id: WindowID? = nil, pid: Int32 = 81) {
        s.eventHandler?(WindowSystemEvent(kind: .created, windowID: id, processIdentifier: pid))
    }
    @Test(arguments: [LayoutMode.bento, .tabbed], [false, true])
    func twoUnknownArrivalsDoNotLoseLateSecond(mode: LayoutMode, firstIsPopup: Bool) async throws {
        let (s, m) = try await fixture(mode)
        defer { m.shutdown() }
        let clock = WindowArrivalTestClock(m)
        let first = add("first", s, floating: firstIsPopup)
        let second = add("second", s)
        s.offscreenWindowIDs.insert(second)
        created(s)
        created(s) // Two accepted creations for two different windows, neither mapped by the adapter yet.
        await s.joinWindowEvent(on: m)
        try #require(await s.waitFor { m.settlementTasks.isEmpty })
        await s.joinWindowEvent(on: m) // Drain the first placement's trailing pass while second is unreadable.
        #expect(s.frameWriteCounts[second, default: 0] == 0)
        clock.elapsed = 0.36
        s.offscreenWindowIDs.remove(second)
        await s.joinWindowEvent(on: m)
        try #require(await s.waitFor { m.settlementTasks.isEmpty })
        clock.elapsed = 0.5
        try await waitForWindowEventsToDrain(m, s)
        #expect(s.frameWriteCounts[second, default: 0] > 0, "The second creation must retain discovery within the original readiness bound")
        #expect(s.probeRequests.contains { $0.contains(second) })
        if firstIsPopup { #expect(s.frameWriteCounts[first, default: 0] == 0) }
    }
    @Test(arguments: [LayoutMode.bento, .tabbed])
    func closingObservedSiblingDoesNotCancelUnknownArrival(mode: LayoutMode) async throws {
        let (s, m) = try await fixture(mode)
        defer { m.shutdown() }
        let sibling = add("existing-popup", s, floating: true)
        m.handleApplicationTopologyChange()
        try await waitForWindowEventsToDrain(m, s)
        let clock = WindowArrivalTestClock(m)
        let arriving = add("arriving", s)
        s.offscreenWindowIDs.insert(arriving)
        created(s)
        s.windows.removeAll { $0.id == sibling }
        s.eventHandler?(WindowSystemEvent(kind: .destroyed, windowID: sibling, processIdentifier: 81))
        await s.joinWindowEvent(on: m)
        #expect(s.frameWriteCounts[arriving, default: 0] == 0)
        clock.elapsed = 0.24
        s.offscreenWindowIDs.remove(arriving)
        await s.joinWindowEvent(on: m)
        try await waitForWindowEventsToDrain(m, s)
        #expect(s.frameWriteCounts[arriving, default: 0] > 0)
        #expect(s.probeRequests.contains { $0.contains(arriving) })
    }
    @Test(arguments: [LayoutMode.bento, .tabbed])
    func exactDestroyedIdentityStopsReadiness(mode: LayoutMode) async throws {
        let (s, m) = try await fixture(mode)
        defer { m.shutdown() }
        _ = WindowArrivalTestClock(m)
        let id = add("destroyed", s)
        s.offscreenWindowIDs.insert(id)
        created(s, id)
        await s.joinWindowEvent(on: m)
        s.windows.removeAll { $0.id == id }
        s.eventHandler?(WindowSystemEvent(kind: .destroyed, windowID: id, processIdentifier: 81))
        await s.joinWindowEvent(on: m)
        try await waitForWindowEventsToDrain(m, s)
        let sweeps = s.completeSweepCount
        await s.advance(by: .milliseconds(600))
        #expect(s.completeSweepCount == sweeps)
        #expect(s.frameWriteCounts[id, default: 0] == 0)
        #expect(!s.probeRequests.contains { $0.contains(id) })
    }
    @Test(arguments: [LayoutMode.bento, .tabbed])
    func knownReadablePopupRetiresWithoutMutation(mode: LayoutMode) async throws {
        let (s, m) = try await fixture(mode)
        defer { m.shutdown() }
        let clock = WindowArrivalTestClock(m)
        let id = add("popup", s, floating: true)
        let start = s.completeSweepCount
        created(s, id)
        await s.joinWindowEvent(on: m)
        await s.advance(by: .milliseconds(400))
        // A readable floating window is rechecked at the ordinary cadence, not every 8 ms (about 45 inventories).
        #expect(s.completeSweepCount - start <= 6, "A pending popup must not poll the whole desktop")
        clock.elapsed = 0.5 // A floating window stays provisional until the readiness deadline.
        try await waitForWindowEventsToDrain(m, s)
        let sweeps = s.completeSweepCount
        await s.advance(by: .milliseconds(600))
        #expect(s.completeSweepCount == sweeps)
        #expect(s.frameWriteCounts[id, default: 0] == 0)
        #expect(!s.probeRequests.contains { $0.contains(id) })
    }
    @Test(arguments: [LayoutMode.bento, .tabbed])
    func holdStopsReadinessAndDoesNotSpendRetryBudget(mode: LayoutMode) async throws {
        let (s, m) = try await fixture(mode)
        defer { m.shutdown() }
        _ = WindowArrivalTestClock(m)
        let id = add("held", s)
        s.applicationHoldDuration = 60
        s.unresponsiveProcessIDs.insert(81)
        created(s, id)
        await s.joinWindowEvent(on: m)
        try await waitForWindowEventsToDrain(m, s)
        let sweeps = s.completeSweepCount
        let attempts = s.unresponsiveInventoryAttemptTimes[81]?.count
        await s.advance(by: .milliseconds(650))
        #expect(s.completeSweepCount == sweeps)
        #expect(s.unresponsiveInventoryAttemptTimes[81]?.count == attempts)
        #expect(attempts == 1)
        #expect(s.frameWriteCounts[id, default: 0] == 0)
        #expect(!s.probeRequests.contains { $0.contains(id) })
    }
    @Test(arguments: [LayoutMode.bento, .tabbed])
    func switchToManualCannotDispatchLatePlacement(mode: LayoutMode) async throws {
        let (s, m) = try await fixture(mode)
        defer { m.shutdown() }
        _ = WindowArrivalTestClock(m)
        let id = add("manual-late", s)
        s.offscreenWindowIDs.insert(id)
        created(s, id)
        await s.joinWindowEvent(on: m)
        m.setActiveMode(.manual)
        try #require(await s.waitFor { m.activeMode(for: s.mainDisplay.id) == .manual && m.settlementTasks.isEmpty })
        let writes = s.frameWriteCounts, probes = s.probeRequests
        s.offscreenWindowIDs.remove(id)
        await s.advance(by: .milliseconds(650))
        #expect(s.frameWriteCounts == writes)
        #expect(s.probeRequests == probes)
    }
    @Test(arguments: [LayoutMode.bento, .tabbed])
    func topologyResetCannotTransferOldKnownIdentityToReusedPID(mode: LayoutMode) async throws {
        let (s, m) = try await fixture(mode)
        defer { m.shutdown() }
        _ = WindowArrivalTestClock(m)
        let id = add("old-launch", s)
        s.offscreenWindowIDs.insert(id)
        created(s, id)
        await s.joinWindowEvent(on: m)
        s.windows.removeAll { $0.id == id }
        m.handleApplicationTopologyChange()
        await s.joinWindowEvent(on: m)
        try await waitForWindowEventsToDrain(m, s)
        let sweeps = s.completeSweepCount
        let replacement = add("new-launch", s) // Same PID, distinct identity, no new event.
        await s.advance(by: .milliseconds(600))
        #expect(s.completeSweepCount == sweeps)
        #expect(s.frameWriteCounts[replacement, default: 0] == 0)
        #expect(!s.probeRequests.contains { $0.contains(replacement) })
    }
    @Test(arguments: [LayoutMode.bento, .tabbed])
    func failingInventoryRetainsExistingBackoff(mode: LayoutMode) async throws {
        let (s, m) = try await fixture(mode)
        defer { m.shutdown() }
        let id = add("failed", s)
        s.offscreenWindowIDs.insert(id)
        let start = s.completeSweepCount
        s.failedVisibleWindowSweeps = Set((start + 1)...(start + 3))
        var times: [TimeInterval] = []
        s.onVisibleWindowSweep = { _ in times.append(s.uptime) }
        created(s, id)
        for _ in 0..<3 { await s.joinWindowEvent(on: m) }
        #expect(times.count == 3)
        if times.count == 3 {
            #expect(times[1] - times[0] >= 0.22)
            #expect(times[2] - times[1] >= 0.45)
        }
        await s.joinWindowEvent(on: m)
        let sweeps = s.completeSweepCount
        await s.advance(by: .milliseconds(300))
        #expect(s.completeSweepCount == sweeps)
        #expect(s.frameWriteCounts[id, default: 0] == 0)
    }
    @Test(arguments: [LayoutMode.bento, .tabbed])
    func creationDuringGestureKeepsReadinessAfterReplay(mode: LayoutMode) async throws {
        let (s, m) = try await fixture(mode)
        defer { m.shutdown() }
        let peer = add("gesture-peer", s, pid: 43)
        created(s, peer, pid: 43)
        await s.joinWindowEvent(on: m)
        try #require(await s.waitFor { s.frameWriteCounts[peer, default: 0] > 0 && m.settlementTasks.isEmpty })
        try await waitForWindowEventsToDrain(m, s)
        let clock = WindowArrivalTestClock(m)
        let source = s.windows[0].id, display = s.mainDisplay.id
        try #require(m.beginBentoDrag(displayID: display, sourceID: source))
        let id = add("gesture-arrival", s)
        s.offscreenWindowIDs.insert(id)
        created(s, id)
        let writes = s.frameWriteCounts, probes = s.probeRequests
        clock.elapsed = 0.02
        #expect(s.frameWriteCounts == writes)
        #expect(s.probeRequests == probes)
        m.finishBentoDrag(displayID: display, sourceID: source, end: .restore)
        await s.joinWindowEvent(on: m)
        try #require(await s.waitFor { m.settlementTasks.isEmpty })
        await s.joinWindowEvent(on: m) // Drain replay's trailing placement pass before the arrival is readable.
        #expect(s.frameWriteCounts[id, default: 0] == 0)
        clock.elapsed = 0.36
        s.offscreenWindowIDs.remove(id)
        await s.joinWindowEvent(on: m)
        try await waitForWindowEventsToDrain(m, s)
        #expect(s.frameWriteCounts[id, default: 0] > 0)
        #expect(s.probeRequests.contains { $0.contains(id) })
    }

    @Test(arguments: [LayoutMode.bento, .tabbed])
    func duplicateReadyCallbacksStayBoundedWithoutRepeatedMutation(mode: LayoutMode) async throws {
        let (s, m) = try await fixture(mode)
        defer { m.shutdown() }
        let clock = WindowArrivalTestClock(m)
        let id = add("duplicate", s)
        let before = s.completeSweepCount
        created(s)
        created(s)
        await s.joinWindowEvent(on: m)
        // Expire readiness before waiting for settlement, independently of its sampling cadence.
        clock.elapsed = 0.5
        try #require(await s.waitFor { s.frameWriteCounts[id, default: 0] > 0 && m.settlementTasks.isEmpty })
        let writes = s.frameWriteCounts, probes = s.probeRequests
        try await waitForWindowEventsToDrain(m, s)
        #expect(s.frameWriteCounts == writes)
        #expect(s.probeRequests == probes)
        #expect(s.completeSweepCount - before <= 6)
        let finished = s.completeSweepCount
        await s.advance(by: .milliseconds(250))
        #expect(s.completeSweepCount == finished)
        #expect(m.windowEventTask == nil)
    }
    @Test(arguments: [LayoutMode.bento, .tabbed], [false, true])
    func cancellationStopsRearmedReadinessBeforeLateSnapshot(mode: LayoutMode, shutdown: Bool) async throws {
        let (s, m) = try await fixture(mode)
        defer { m.shutdown() }
        _ = WindowArrivalTestClock(m)
        let id = add("cancelled", s)
        s.offscreenWindowIDs.insert(id)
        created(s, id)
        await s.joinWindowEvent(on: m)
        let task = try #require(m.windowEventTask)
        if shutdown {
            m.shutdown()
        } else {
            s.offscreenWindowIDs = Set(s.windows.map(\.id))
            s.focusedWindowIsAbsent = true
            m.beginActiveSpaceStabilization()
            try #require(await s.waitFor { !m.isStabilizingSpace })
        }
        await s.joinWindowEvent(on: m, task: task)
        #expect(task.isCancelled)
        try await waitForWindowEventsToDrain(m, s)
        let writes = s.frameWriteCounts, probes = s.probeRequests, sweeps = s.completeSweepCount
        s.offscreenWindowIDs.remove(id)
        await s.advance(by: .milliseconds(650))
        #expect(s.frameWriteCounts == writes)
        #expect(s.probeRequests == probes)
        #expect(s.completeSweepCount == sweeps)
        #expect(s.frameWriteCounts[id, default: 0] == 0)
    }
    private func dragFixture(_ mode: LayoutMode) async throws -> (FakeAppWindowSystem, BetterTileModel) {
        let (s, m) = try await fixture(mode)
        let peer = add("gesture-peer", s, pid: 43)
        created(s, peer, pid: 43)
        await s.joinWindowEvent(on: m)
        try #require(await s.waitFor { s.frameWriteCounts[peer, default: 0] > 0 && m.settlementTasks.isEmpty })
        try await waitForWindowEventsToDrain(m, s)
        return (s, m)
    }

    // Regression from the review's actual event -> drag -> empty replay path.
    @Test(arguments: [LayoutMode.bento, .tabbed], [false, true])
    func creationBeforeGestureRetainsQueuedReadiness(mode: LayoutMode, firstSweepAlreadyRan: Bool) async throws {
        let (s, m) = try await dragFixture(mode)
        defer { m.shutdown() }
        let clock = WindowArrivalTestClock(m)
        let arriving = add("before-gesture-arrival", s)
        s.offscreenWindowIDs.insert(arriving)
        created(s, arriving)
        if firstSweepAlreadyRan { await s.joinWindowEvent(on: m) }
        let queued = try #require(m.windowEventTask)
        let source = s.windows[0].id, display = s.mainDisplay.id
        try #require(m.beginBentoDrag(displayID: display, sourceID: source))
        await s.joinWindowEvent(on: m, task: queued)
        #expect(queued.isCancelled)
        let writes = s.frameWriteCounts, probes = s.probeRequests, sweeps = s.completeSweepCount
        clock.elapsed = 0.10
        await s.advance(by: .milliseconds(150))
        #expect(s.frameWriteCounts == writes)
        #expect(s.probeRequests == probes)
        #expect(s.completeSweepCount == sweeps)
        m.finishBentoDrag(displayID: display, sourceID: source, end: .restore)
        try #require(await s.waitFor { m.settlementTasks.isEmpty })
        await s.joinWindowEvent(on: m)
        #expect(s.frameWriteCounts[arriving, default: 0] == 0)
        clock.elapsed = 0.24
        let beforeReveal = s.completeSweepCount
        s.offscreenWindowIDs.remove(arriving)
        await s.joinWindowEvent(on: m)
        await s.advance(by: .milliseconds(300))
        #expect(s.completeSweepCount > beforeReveal)
        #expect(s.frameWriteCounts[arriving, default: 0] > 0)
        #expect(s.probeRequests.contains { $0.contains(arriving) })
        // The review control proves the same window is eligible if another callback wakes it.
        clock.elapsed = 0.26
        created(s, arriving)
        await s.joinWindowEvent(on: m)
        try await waitForWindowEventsToDrain(m, s)
        #expect(s.frameWriteCounts[arriving, default: 0] > 0)
        #expect(s.probeRequests.contains { $0.contains(arriving) })
    }

    @Test(arguments: [LayoutMode.bento, .tabbed], [1, 3])
    func longAndRepeatedDragsKeepOriginalArrivalDeadline(mode: LayoutMode, dragCount: Int) async throws {
        let (s, m) = try await dragFixture(mode)
        defer { m.shutdown() }
        let clock = WindowArrivalTestClock(m)
        let arriving = add("expires-across-drag", s)
        s.offscreenWindowIDs.insert(arriving)
        created(s, arriving)
        await s.joinWindowEvent(on: m)
        let source = s.windows[0].id, display = s.mainDisplay.id
        for drag in 1...dragCount {
            let queued = try #require(m.windowEventTask)
            try #require(m.beginBentoDrag(displayID: display, sourceID: source))
            await s.joinWindowEvent(on: m, task: queued)
            #expect(queued.isCancelled)
            clock.elapsed = dragCount == 1 ? 0.6 : Double(drag) * 0.1
            m.finishBentoDrag(displayID: display, sourceID: source, end: .restore)
            try #require(await s.waitFor { m.settlementTasks.isEmpty })
            await s.joinWindowEvent(on: m)
        }
        if dragCount > 1 {
            clock.elapsed = 0.499
            await s.joinWindowEvent(on: m)
            #expect(m.windowEventTask != nil, "Repeated drags must preserve unexpired discovery")
            clock.elapsed = 0.5
            await s.joinWindowEvent(on: m)
        }
        #expect(m.windowEventTask == nil, "Neither a long drag nor repeated drags may renew arrival readiness")
        clock.elapsed = 2 // Let an incorrectly renewed record drain after the assertion above.
        try await waitForWindowEventsToDrain(m, s)
        let sweeps = s.completeSweepCount, writes = s.frameWriteCounts, probes = s.probeRequests
        s.offscreenWindowIDs.remove(arriving)
        await s.advance(by: .milliseconds(300))
        #expect(s.completeSweepCount == sweeps)
        #expect(s.frameWriteCounts == writes)
        #expect(s.probeRequests == probes)
        #expect(s.frameWriteCounts[arriving, default: 0] == 0)
    }

    @Test(arguments: [LayoutMode.bento, .tabbed], ["space", "reset", "destroyed", "manual", "shutdown"])
    func interruptedDragCannotReviveArrival(mode: LayoutMode, interruption: String) async throws {
        let (s, m) = try await dragFixture(mode)
        defer { m.shutdown() }
        let clock = WindowArrivalTestClock(m)
        let arriving = add("cancelled-across-drag", s)
        s.offscreenWindowIDs.insert(arriving)
        created(s, arriving)
        await s.joinWindowEvent(on: m)
        let queued = try #require(m.windowEventTask)
        let source = s.windows[0].id, display = s.mainDisplay.id
        try #require(m.beginBentoDrag(displayID: display, sourceID: source))
        await s.joinWindowEvent(on: m, task: queued)
        #expect(queued.isCancelled)
        clock.elapsed = 0.1
        switch interruption {
        case "space":
            s.offscreenWindowIDs = Set(s.windows.map(\.id))
            s.focusedWindowIsAbsent = true
            m.beginActiveSpaceStabilization()
        case "reset": m.handleApplicationTopologyChange()
        case "destroyed":
            s.windows.removeAll { $0.id == arriving }
            s.eventHandler?(WindowSystemEvent(kind: .destroyed, windowID: arriving, processIdentifier: 81))
        case "manual": m.setActiveMode(.manual)
        default: m.shutdown()
        }
        m.finishBentoDrag(displayID: display, sourceID: source, end: .restore)
        try #require(await s.waitFor { !m.isStabilizingSpace && m.settlementTasks.isEmpty })
        if interruption == "manual" {
            clock.elapsed = 0.24
            s.offscreenWindowIDs.remove(arriving)
        }
        try await waitForWindowEventsToDrain(m, s)
        let sweeps = s.completeSweepCount, writes = s.frameWriteCounts, probes = s.probeRequests
        s.offscreenWindowIDs.remove(arriving)
        await s.advance(by: .milliseconds(300))
        #expect(s.completeSweepCount == sweeps)
        #expect(s.frameWriteCounts == writes)
        #expect(s.probeRequests == probes)
        #expect(s.frameWriteCounts[arriving, default: 0] == 0)
        #expect(!s.probeRequests.contains { $0.contains(arriving) })
    }

}
