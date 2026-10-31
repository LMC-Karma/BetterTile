import BetterTileCore
import Foundation
import Testing
@testable import BetterTileApp

/// A creation callback names its window's element. The model reads that one window and
/// places it before any complete inventory; one inventory then validates the result.
@Suite(.appTestApplication, .serialized) @MainActor
struct TargetedArrivalReadTests {
    private let token: UInt64 = 7

    private func fixture(_ mode: LayoutMode) async throws -> (FakeAppWindowSystem, BetterTileModel) {
        let system = makeManualWindowSystem()
        let model = makeModel(system: system)
        model.configuration.singleWindowPlacement = .maximize
        model.setActiveMode(mode)
        try #require(await system.waitFor { model.settlementTasks.isEmpty && (mode != .tabbed || model.activeTabbedState != nil) })
        // Drain entry settlement and its trailing inventory request.
        await system.advance(by: .milliseconds(300))
        return (system, model)
    }

    @discardableResult
    private func addArrival(
        _ system: FakeAppWindowSystem, id: String = "targeted-arrival", token: UInt64? = nil,
        bundleIdentifier: String? = nil, isFloating: Bool = false
    ) -> WindowID {
        let windowID = WindowID(rawValue: id)
        system.windows.append(WindowSnapshot(id: windowID, processIdentifier: 81, bundleIdentifier: bundleIdentifier,
            frame: BTRect(x: 200, y: 200, width: 600, height: 400), displayID: system.mainDisplay.id,
            isFloating: isFloating))
        system.createdWindowsByToken[token ?? self.token] = windowID
        return windowID
    }

    private func create(_ system: FakeAppWindowSystem, token: UInt64? = nil, windowID: WindowID? = nil) {
        system.eventHandler?(WindowSystemEvent(kind: .created, windowID: windowID, processIdentifier: 81,
            creationToken: token ?? self.token))
    }

    @Test(arguments: [LayoutMode.bento, .tabbed])
    func firstWriteNeedsNoCompleteInventory(mode: LayoutMode) async throws {
        let (system, model) = try await fixture(mode)
        defer { model.shutdown() }
        let id = addArrival(system)
        let sweeps = system.completeSweepCount
        var sweepsBeforeFirstWrite: Int?
        system.onFrameWrite = { windowID, _ in
            if windowID == id, sweepsBeforeFirstWrite == nil { sweepsBeforeFirstWrite = system.completeSweepCount - sweeps }
        }
        create(system)
        model.processPendingWindowEvents()
        #expect(system.frameWriteCounts[id, default: 0] > 0, "The first write happens in the event pass, behind no queued task")
        try #require(await system.waitFor { sweepsBeforeFirstWrite != nil })
        #expect(sweepsBeforeFirstWrite == 0)
        #expect(system.createdReadCount == 1)
        if mode == .tabbed {
            try #require(await system.waitFor { model.activeTabbedState?.windowIDs.contains(id) == true })
        } else {
            #expect(system.windows[0].frame.intersection(system.windows[1].frame) == nil)
        }
        // One complete inventory follows to validate; it finds nothing to change.
        try #require(await system.waitFor { system.completeSweepCount - sweeps >= 1 })
        try await waitForWindowEventsToDrain(model, system)
        await system.advance(by: .milliseconds(400))
        #expect(system.completeSweepCount - sweeps == 1)
        #expect(system.createdReadCount == 1)
    }

    @Test(arguments: [LayoutMode.bento, .tabbed])
    func floatingPanelCostsAtMostOneInventoryAndNoPolling(mode: LayoutMode) async throws {
        let (system, model) = try await fixture(mode)
        defer { model.shutdown() }
        let id = addArrival(system, isFloating: true)
        let sweeps = system.completeSweepCount
        let writes = system.frameWriteCounts
        create(system)
        await system.advance(by: .milliseconds(700)) // Past the 500 ms arrival deadline.
        #expect(system.frameWriteCounts[id, default: 0] == 0)
        #expect(system.frameWriteCounts == writes)
        #expect(system.completeSweepCount - sweeps <= 1)
        #expect(system.createdReadCount <= 6, "A panel is read again only as single reads, 120 ms apart")
        #expect(!system.probeRequests.contains { $0.contains(id) })
    }

    /// An early floating verdict (dialog subrole, AXUnknown, missing buttons) can be a standard
    /// window still being built. No further callback arrives, so the model must read it again.
    @Test(arguments: [LayoutMode.bento, .tabbed], [40, 200, 350])
    func floatingThenStandardIsStillPlaced(mode: LayoutMode, flipMs: Int) async throws {
        let (system, model) = try await fixture(mode)
        defer { model.shutdown() }
        let clock = WindowArrivalTestClock(model)
        let id = addArrival(system, isFloating: true)
        let sweeps = system.completeSweepCount
        create(system)
        await system.advance(by: .milliseconds(flipMs))
        #expect(system.frameWriteCounts[id, default: 0] == 0)
        clock.elapsed = Double(flipMs) / 1_000
        system.windows[system.windows.firstIndex { $0.id == id }!].isFloating = false
        try #require(await system.waitFor { system.frameWriteCounts[id, default: 0] > 0 })
        try await waitForWindowEventsToDrain(model, system)
        #expect(system.completeSweepCount - sweeps <= 1)
        #expect(system.createdReadCount <= 6)
    }

    @Test(arguments: [LayoutMode.bento, .tabbed])
    func unreadableElementRetriesOnlyTheSingleRead(mode: LayoutMode) async throws {
        let (system, model) = try await fixture(mode)
        defer { model.shutdown() }
        let clock = WindowArrivalTestClock(model)
        let id = addArrival(system)
        system.notReadyReads[token] = 3
        var delays: [Duration] = []
        model.windowEventSleep = { delay in
            delays.append(delay)
            clock.elapsed += Double(delay.components.seconds) + Double(delay.components.attoseconds) / 1e18
        }
        let sweeps = system.completeSweepCount
        var sweepsBeforeFirstWrite: Int?
        system.onFrameWrite = { windowID, _ in
            if windowID == id, sweepsBeforeFirstWrite == nil { sweepsBeforeFirstWrite = system.completeSweepCount - sweeps }
        }
        create(system)
        try #require(await system.waitFor { sweepsBeforeFirstWrite != nil })
        #expect(sweepsBeforeFirstWrite == 0)
        #expect(system.createdReadCount == 4)
        #expect(delays.prefix(3).allSatisfy { $0 == .milliseconds(8) })
        #expect(delays.count >= 3)
    }

    @Test(arguments: [LayoutMode.bento, .tabbed])
    func anElementThatStaysUnreadableFallsBackAtTheDeadline(mode: LayoutMode) async throws {
        let (system, model) = try await fixture(mode)
        defer { model.shutdown() }
        let clock = WindowArrivalTestClock(model)
        let id = addArrival(system)
        system.notReadyReads[token] = 10_000
        model.windowEventSleep = { delay in
            clock.elapsed += Double(delay.components.seconds) + Double(delay.components.attoseconds) / 1e18
        }
        let sweeps = system.completeSweepCount
        var sweepsBeforeFirstWrite: Int?
        system.onFrameWrite = { windowID, _ in
            if windowID == id, sweepsBeforeFirstWrite == nil { sweepsBeforeFirstWrite = system.completeSweepCount - sweeps }
        }
        create(system)
        try #require(await system.waitFor { sweepsBeforeFirstWrite != nil })
        #expect(sweepsBeforeFirstWrite == 1, "Only the deadline hands the arrival to a complete inventory")
        #expect(system.createdReadCount > 40 && system.createdReadCount < 80)
    }

    @Test(arguments: [LayoutMode.bento, .tabbed])
    func anInvalidElementFallsBackAtOnce(mode: LayoutMode) async throws {
        let (system, model) = try await fixture(mode)
        defer { model.shutdown() }
        // Hold arrival age at zero. Only the invalid element may hand the arrival to the complete
        // inventory, not a 500 ms deadline that full-suite load expires before the queued pass.
        _ = WindowArrivalTestClock(model)
        let id = addArrival(system)
        system.unavailableTokens.insert(token)
        let sweeps = system.completeSweepCount
        create(system)
        try #require(await system.waitFor { system.frameWriteCounts[id, default: 0] > 0 })
        #expect(system.createdReadCount == 1)
        #expect(system.completeSweepCount - sweeps >= 1)
    }

    @Test(arguments: [LayoutMode.bento, .tabbed])
    func aWindowOnAnotherSpaceIsNotPlaced(mode: LayoutMode) async throws {
        let (system, model) = try await fixture(mode)
        defer { model.shutdown() }
        // The queued pass must read the window; full-suite load must not expire its arrival first.
        _ = WindowArrivalTestClock(model)
        let display = system.mainDisplay.id
        let current = NativeSpaceID(rawValue: 1), other = NativeSpaceID(rawValue: 2)
        system.desktopObservation = NativeDesktopObservation(currentSpaceByDisplay: [display: current],
            knownSpacesByDisplay: [display: [current, other]], windowMembership: [system.windows[0].id: [current]])
        let id = addArrival(system)
        create(system)
        // The user switches Space before the queued pass reads the window.
        system.desktopObservation?.windowMembership[id] = [other]
        await system.advance(by: .milliseconds(700))
        #expect(system.createdReadCount == 1, "The read saw the window on another Space")
        #expect(system.frameWriteCounts[id, default: 0] == 0)
        #expect(!system.probeRequests.contains { $0.contains(id) })
    }

    @Test(arguments: [LayoutMode.bento, .tabbed])
    func aSpaceSwitchInProgressDefersTheRead(mode: LayoutMode) async throws {
        let (system, model) = try await fixture(mode)
        defer { model.shutdown() }
        let id = addArrival(system)
        create(system)
        system.offscreenWindowIDs = Set(system.windows.map(\.id))
        system.focusedWindowIsAbsent = true
        model.beginActiveSpaceStabilization()
        try #require(await system.waitFor { !model.isStabilizingSpace })
        await system.advance(by: .milliseconds(300))
        #expect(system.frameWriteCounts[id, default: 0] == 0)
        #expect(!system.probeRequests.contains { $0.contains(id) })
    }

    @Test(arguments: [LayoutMode.bento, .tabbed])
    func aRepeatedNotificationAdoptsTheWindowOnce(mode: LayoutMode) async throws {
        let (system, model) = try await fixture(mode)
        defer { model.shutdown() }
        _ = WindowArrivalTestClock(model)
        let id = addArrival(system)
        create(system)
        create(system) // The same element, before the queued pass.
        try #require(await system.waitFor { system.frameWriteCounts[id, default: 0] > 0 })
        try await waitForWindowEventsToDrain(model, system)
        await system.advance(by: .milliseconds(300))
        #expect(system.createdReadCount >= 1)
        let writes = system.frameWriteCounts
        let probes = system.probeRequests.filter { $0.contains(id) }.count
        #expect(probes == 1)
        create(system, windowID: id) // Late duplicate, after the identity is known.
        await system.advance(by: .milliseconds(500))
        try await waitForWindowEventsToDrain(model, system)
        #expect(system.frameWriteCounts == writes)
        #expect(system.probeRequests.filter { $0.contains(id) }.count == probes)
        if mode == .tabbed {
            #expect(model.activeTabbedState?.windowIDs.filter { $0 == id }.count == 1)
        }
    }

    @Test(arguments: [LayoutMode.bento, .tabbed])
    func aPerAppRuleKeepsTheWindowOutOfTheLayout(mode: LayoutMode) async throws {
        let (system, model) = try await fixture(mode)
        defer { model.shutdown() }
        model.setRule(.excludeFromBento, for: "com.example.Excluded")
        // The queued pass must read the window; full-suite load must not expire its arrival first.
        _ = WindowArrivalTestClock(model)
        let id = addArrival(system, bundleIdentifier: "com.example.Excluded")
        let sweeps = system.completeSweepCount
        create(system)
        await system.advance(by: .milliseconds(700))
        #expect(system.createdReadCount >= 1)
        #expect(system.frameWriteCounts[id, default: 0] == 0)
        #expect(!system.probeRequests.contains { $0.contains(id) })
        #expect(system.completeSweepCount - sweeps <= 1)
    }

    @Test func aStaleInventoryIsCorrectedByTheValidatingInventory() async throws {
        let (system, model) = try await fixture(.bento)
        defer { model.shutdown() }
        let peer = system.windows[0].id
        let id = addArrival(system)
        _ = WindowArrivalTestClock(model)
        // Close the cached peer at the first write, before the validating inventory can run.
        system.onFrameWrite = { [weak system] writtenID, _ in
            if writtenID == id { system?.offscreenWindowIDs.insert(peer) }
        }
        create(system)
        try #require(await system.waitFor { system.frameWriteCounts[id, default: 0] > 0 })
        let work = system.mainDisplay.visibleFrame
        try #require(await system.waitFor(timeout: .seconds(20)) {
            system.windows.first { $0.id == id }?.frame == work
        })
    }

    /// A peer that hid (Cmd-H), moved Space, or closed without an event is still in the cached
    /// inventory. The cache check fails, so the complete inventory runs and the peer gets no write.
    @Test(arguments: [LayoutMode.bento, .tabbed])
    func aHiddenPeerInAStaleCacheIsNotWritten(mode: LayoutMode) async throws {
        let (system, model) = try await fixture(mode)
        defer { model.shutdown() }
        let peer = WindowID(rawValue: "hidden-peer")
        system.windows.append(WindowSnapshot(id: peer, processIdentifier: 82,
            frame: BTRect(x: 100, y: 100, width: 500, height: 400), displayID: system.mainDisplay.id))
        system.eventHandler?(WindowSystemEvent(kind: .created, windowID: peer, processIdentifier: 82))
        try #require(await system.waitFor { system.frameWriteCounts[peer, default: 0] > 0 })
        try await waitForWindowEventsToDrain(model, system)
        try #require(await system.waitFor { model.settlementTasks.isEmpty })
        await system.advance(by: .milliseconds(400))
        system.staleCache = system.windows
        system.offscreenWindowIDs.insert(peer)
        let peerWrites = system.frameWriteCounts[peer, default: 0]
        let sweeps = system.completeSweepCount
        let id = addArrival(system)
        create(system)
        try #require(await system.waitFor { system.frameWriteCounts[id, default: 0] > 0 })
        try await waitForWindowEventsToDrain(model, system)
        await system.advance(by: .milliseconds(400))
        #expect(system.frameWriteCounts[peer, default: 0] == peerWrites)
        #expect(system.completeSweepCount - sweeps >= 1)
    }

    @Test(arguments: [LayoutMode.bento, .tabbed])
    func anEventWithoutAnElementUsesTheCompleteInventory(mode: LayoutMode) async throws {
        let (system, model) = try await fixture(mode)
        defer { model.shutdown() }
        let id = addArrival(system)
        let sweeps = system.completeSweepCount
        system.eventHandler?(WindowSystemEvent(kind: .created, windowID: nil, processIdentifier: 81))
        try #require(await system.waitFor { system.frameWriteCounts[id, default: 0] > 0 })
        #expect(system.createdReadCount == 0)
        #expect(system.completeSweepCount - sweeps >= 1)
    }
}
