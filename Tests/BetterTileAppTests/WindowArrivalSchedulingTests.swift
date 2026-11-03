import BetterTileCore
import Foundation
import Testing
@testable import BetterTileApp

/// New-window discovery retains its queued deadline while peers send frame events.
@Suite(.appTestApplication, .serialized) @MainActor
struct WindowArrivalSchedulingTests {
    private func fixture(_ mode: LayoutMode, hasNativeObservation: Bool = false) async throws -> (FakeAppWindowSystem, BetterTileModel) {
        let system = makeManualWindowSystem()
        if hasNativeObservation {
            let display = system.mainDisplay.id, space = NativeSpaceID(rawValue: 1)
            system.desktopObservation = NativeDesktopObservation(currentSpaceByDisplay: [display: space],
                knownSpacesByDisplay: [display: [space]], windowMembership: [:])
        }
        let model = makeModel(system: system)
        model.configuration.singleWindowPlacement = .maximize
        model.setActiveMode(mode)
        try #require(await system.waitFor { model.settlementTasks.isEmpty && (mode != .tabbed || model.activeTabbedState != nil) })
        // Drain entry settlement and its trailing 120 ms inventory request.
        await system.advance(by: .milliseconds(300))
        return (system, model)
    }

    @Test(arguments: [LayoutMode.bento, .tabbed], [false, true])
    func readableCreationDoesNotWaitForEventDebounce(mode: LayoutMode, knownIdentity: Bool) async throws {
        let (system, model) = try await fixture(mode)
        defer { model.shutdown() }
        var elapsed: Duration = .zero
        model.windowEventSleep = { elapsed += $0 }
        let id = WindowID(rawValue: "immediate-arrival")
        system.windows.append(WindowSnapshot(id: id, processIdentifier: 81,
            frame: BTRect(x: 200, y: 200, width: 600, height: 400), displayID: system.mainDisplay.id))
        var firstWrite: Duration?
        system.onFrameWrite = { windowID, _ in
            if windowID == id, firstWrite == nil { firstWrite = elapsed }
        }
        system.eventHandler?(WindowSystemEvent(kind: .created,
            windowID: knownIdentity ? id : nil, processIdentifier: 81))
        await system.joinWindowEvent(on: model)
        try #require(await system.waitFor { firstWrite != nil })
        #expect(firstWrite == .zero, "A readable creation must not wait for the 120 ms frame debounce")
        if mode == .tabbed {
            try #require(await system.waitFor { model.activeTabbedState?.windowIDs.contains(id) == true })
        }
    }

    @Test(arguments: [LayoutMode.bento, .tabbed])
    func unreadableCreationRetriesWithinOneFrame(mode: LayoutMode) async throws {
        let (system, model) = try await fixture(mode)
        defer { model.shutdown() }
        let clock = WindowArrivalTestClock(model)
        let id = WindowID(rawValue: "ready-on-retry")
        system.windows.append(WindowSnapshot(id: id, processIdentifier: 81,
            frame: BTRect(x: 200, y: 200, width: 600, height: 400), displayID: system.mainDisplay.id))
        system.offscreenWindowIDs.insert(id)
        var delays: [Duration] = []
        model.windowEventSleep = { delay in
            delays.append(delay)
            clock.elapsed += Double(delay.components.seconds) + Double(delay.components.attoseconds) / 1e18
            system.offscreenWindowIDs.remove(id)
        }
        var firstWriteAge: TimeInterval?
        system.onFrameWrite = { windowID, _ in
            if windowID == id, firstWriteAge == nil { firstWriteAge = clock.elapsed }
        }
        system.eventHandler?(WindowSystemEvent(kind: .created, windowID: id, processIdentifier: 81))
        await system.joinWindowEvent(on: model)
        await system.joinWindowEvent(on: model)
        try #require(await system.waitFor { firstWriteAge != nil })
        #expect(delays == [.milliseconds(8)])
        #expect(firstWriteAge == 0.008)
    }

    @Test(arguments: [LayoutMode.bento, .tabbed])
    func creationPromotesAlreadyQueuedTopology(mode: LayoutMode) async throws {
        let (system, model) = try await fixture(mode)
        defer { model.shutdown() }
        var waits: [Duration] = []
        model.windowEventSleep = { waits.append($0) }
        system.eventHandler?(WindowSystemEvent(kind: .destroyed, windowID: nil, processIdentifier: 82))
        let slowerPass = try #require(model.windowEventTask)
        let id = WindowID(rawValue: "promoted-arrival")
        system.windows.append(WindowSnapshot(id: id, processIdentifier: 81,
            frame: BTRect(x: 200, y: 200, width: 600, height: 400), displayID: system.mainDisplay.id))
        system.eventHandler?(WindowSystemEvent(kind: .created, windowID: id, processIdentifier: 81))
        await system.joinWindowEvent(on: model)
        try #require(await system.waitFor { system.frameWriteCounts[id, default: 0] > 0 })
        #expect(slowerPass.isCancelled)
        #expect(waits.isEmpty)
    }

    @Test(arguments: [LayoutMode.bento, .tabbed])
    func arrivalFrameCallbackReusesInventoryUntilMutation(mode: LayoutMode) async throws {
        let (system, model) = try await fixture(mode, hasNativeObservation: true) // Reuse needs native membership; otherwise the pass observes again.
        defer { model.shutdown() }
        let id = WindowID(rawValue: "arrival-with-frame-event")
        system.windows.append(WindowSnapshot(id: id, processIdentifier: 81,
            frame: BTRect(x: 200, y: 200, width: 600, height: 400), displayID: system.mainDisplay.id))
        let space = NativeSpaceID(rawValue: 1) // A window without membership is not trusted from a reused inventory.
        system.desktopObservation?.windowMembership = Dictionary(uniqueKeysWithValues: system.windows.map { ($0.id, [space]) })
        let sweeps = system.completeSweepCount
        var sweepsBeforeFirstWrite: Int?
        system.onFrameWrite = { windowID, _ in
            if windowID == id, sweepsBeforeFirstWrite == nil {
                sweepsBeforeFirstWrite = system.completeSweepCount - sweeps
            }
        }
        system.eventHandler?(WindowSystemEvent(kind: .created, windowID: id, processIdentifier: 81))
        system.eventHandler?(WindowSystemEvent(kind: .resized, windowID: id, processIdentifier: 81))
        await system.joinWindowEvent(on: model)
        try #require(await system.waitFor { sweepsBeforeFirstWrite != nil })
        #expect(sweepsBeforeFirstWrite == 1, "Unmanaged arrival frame traffic needs no second complete inventory before placement")
    }

    @Test(arguments: [LayoutMode.bento, .tabbed], [false, true])
    func creationSweepIsNotPostponedByFrameTraffic(mode: LayoutMode, coldLaunch: Bool) async throws {
        let (system, model) = try await fixture(mode)
        defer { model.shutdown() }
        if coldLaunch { model.handleApplicationTopologyChange() } // Process exists, no window yet.
        let id = WindowID(rawValue: "arrival")
        let pid: Int32 = coldLaunch ? 81 : 42
        let initial = BTRect(x: 200, y: 200, width: 600, height: 400)
        system.windows.append(WindowSnapshot(id: id, processIdentifier: pid,
            frame: initial, displayID: system.mainDisplay.id))
        let started = system.clock.now
        var firstWrite: Duration?
        system.onFrameWrite = { windowID, _ in
            if windowID == id, firstWrite == nil { firstWrite = started.duration(to: system.clock.now) }
        }
        system.eventHandler?(WindowSystemEvent(kind: .created, windowID: nil, processIdentifier: pid))
        // An already known peer can keep delivering accepted AX frame callbacks.
        // Keep the geometry fixed to isolate scheduling from layout refusal.
        for index in 0..<10 {
            await system.advance(by: .milliseconds(40))
            system.eventHandler?(WindowSystemEvent(kind: .moved, windowID: system.windows[0].id, processIdentifier: 42))
            if index == 5 {
                #expect(system.frameWriteCounts[id, default: 0] > 0,
                    "A readable arrival still overlaps its peer while frame traffic keeps resetting the sweep")
            }
        }
        try #require(await system.waitFor { firstWrite != nil })
        print("FAKE arrival mode=\(mode) cold=\(coldLaunch) created-to-first-write=\(firstWrite!)")
        #expect(system.probeRequests.contains { $0.contains(id) })
        #expect(system.windows.first { $0.id == id }?.frame != initial)
        if mode == .tabbed {
            #expect(await system.waitFor { model.activeTabbedState?.windowIDs.contains(id) == true })
            #expect(model.activeTabbedState?.panes.first?.selected == id)
        } else {
            #expect(system.windows[0].frame.intersection(system.windows[1].frame) == nil)
        }
    }

    @Test(arguments: [LayoutMode.bento, .tabbed])
    func topologyRetryRearmsAfterFailedSweep(mode: LayoutMode) async throws {
        let (system, model) = try await fixture(mode)
        defer { model.shutdown() }
        let id = WindowID(rawValue: "retry-arrival")
        system.windows.append(WindowSnapshot(id: id, processIdentifier: 81,
            frame: BTRect(x: 200, y: 200, width: 600, height: 400), displayID: system.mainDisplay.id))
        system.failedVisibleWindowSweeps.insert(system.completeSweepCount + 1)
        system.eventHandler?(WindowSystemEvent(kind: .created, windowID: nil, processIdentifier: 81))
        await system.joinWindowEvent(on: model)
        #expect(system.frameWriteCounts[id, default: 0] == 0)
        let retry = try #require(model.windowEventTask)
        await system.joinWindowEvent(on: model, task: retry)
        #expect(await system.waitFor { system.frameWriteCounts[id, default: 0] > 0 })
    }

    @Test func frameOnlyTrafficStillDebounces() async throws {
        let (system, model) = try await fixture(.bento)
        defer { model.shutdown() }
        let reads = system.cachedRefreshCount
        let event = WindowSystemEvent(kind: .moved, windowID: system.windows[0].id, processIdentifier: 42)
        system.eventHandler?(event)
        let first = try #require(model.windowEventTask)
        system.eventHandler?(event)
        await system.joinWindowEvent(on: model, task: first)
        #expect(system.cachedRefreshCount == reads)
        await system.joinWindowEvent(on: model)
        #expect(system.cachedRefreshCount > reads)
    }

    @Test(arguments: [LayoutMode.bento, .tabbed])
    func spaceSwitchCancelsQueuedArrival(mode: LayoutMode) async throws {
        let (system, model) = try await fixture(mode)
        defer { model.shutdown() }
        let id = WindowID(rawValue: "departed-arrival")
        system.windows.append(WindowSnapshot(id: id, processIdentifier: 81,
            frame: BTRect(x: 200, y: 200, width: 600, height: 400), displayID: system.mainDisplay.id))
        system.eventHandler?(WindowSystemEvent(kind: .created, windowID: nil, processIdentifier: 81))
        let pending = try #require(model.windowEventTask)
        system.offscreenWindowIDs = Set(system.windows.map(\.id))
        system.focusedWindowIsAbsent = true
        model.beginActiveSpaceStabilization()
        await system.joinWindowEvent(on: model, task: pending)
        try #require(await system.waitFor { !model.isStabilizingSpace })
        #expect(system.frameWriteCounts[id, default: 0] == 0)
        #expect(!system.probeRequests.contains { $0.contains(id) })
    }

}
