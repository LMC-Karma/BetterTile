import BetterTileCore
import Foundation
import Testing
@testable import BetterTileApp

/// Uses fake windows and a temporary configuration with automatic runtime startup disabled.
/// Test-owned panels, shortcut registrations, and hover monitors can still run.
@Suite(.appTestApplication, .serialized) @MainActor
struct ColdWindowReadinessTests {
    private func fixture(_ mode: LayoutMode) async throws -> (FakeAppWindowSystem, BetterTileModel) {
        let system = makeManualWindowSystem()
        let model = makeModel(system: system)
        model.configuration.singleWindowPlacement = .maximize
        model.setActiveMode(mode)
        try #require(await system.waitFor { model.settlementTasks.isEmpty && (mode != .tabbed || model.activeTabbedState != nil) })
        try await waitForWindowEventsToDrain(model, system)
        return (system, model)
    }

    /// A successful inventory can omit an initially unreadable first window without a hold.
    /// Readiness must cause discovery without a new callback or watchdog.
    @Test(arguments: [LayoutMode.bento, .tabbed], [false, true])
    func lateReadableCreationIsDiscoveredWithoutWatchdog(mode: LayoutMode, knownIdentity: Bool) async throws {
        let (system, model) = try await fixture(mode)
        defer { model.shutdown() }
        model.handleApplicationTopologyChange()
        try await waitForWindowEventsToDrain(model, system) // Finish launch before the later AX arrival.
        let clock = WindowArrivalTestClock(model)
        let id = WindowID(rawValue: "unreadable-first")
        system.windows.append(WindowSnapshot(id: id, processIdentifier: 81,
            frame: BTRect(x: 200, y: 200, width: 600, height: 400), displayID: system.mainDisplay.id))
        system.offscreenWindowIDs.insert(id) // Existing seam: omit snapshot, as snapshotAttributes failure does.
        system.focusedID = system.windows[0].id
        system.eventHandler?(WindowSystemEvent(kind: .created, windowID: knownIdentity ? id : nil, processIdentifier: 81))
        await system.joinWindowEvent(on: model)
        let sweeps = system.completeSweepCount
        #expect(system.frameWriteCounts[id, default: 0] == 0)
        clock.elapsed = 0.24
        system.offscreenWindowIDs.remove(id)
        await system.joinWindowEvent(on: model)
        try await waitForWindowEventsToDrain(model, system)
        #expect(system.frameWriteCounts[id, default: 0] > 0)
        #expect(system.completeSweepCount > sweeps)
    }

    @Test(arguments: [LayoutMode.bento, .tabbed])
    func readinessRetriesExpireWithoutAWindow(mode: LayoutMode) async throws {
        let (system, model) = try await fixture(mode)
        defer { model.shutdown() }
        let clock = WindowArrivalTestClock(model)
        let start = system.completeSweepCount
        let event = WindowSystemEvent(kind: .created, windowID: nil, processIdentifier: 81)
        system.eventHandler?(event)
        // Six duplicates all precede the original deadline, even under main-actor load.
        for tick in 1...3 {
            clock.elapsed = Double(tick) * 0.12
            system.eventHandler?(event)
            system.eventHandler?(event)
            await system.joinWindowEvent(on: model)
        }
        clock.elapsed = 0.499
        await system.joinWindowEvent(on: model)
        #expect(model.windowEventTask != nil, "An unreadable arrival still needs discovery before expiry")
        clock.elapsed = 0.5
        await system.joinWindowEvent(on: model)
        #expect(model.windowEventTask == nil, "Duplicates must not extend the original deadline")
        try await waitForWindowEventsToDrain(model, system)
        let finished = system.completeSweepCount
        #expect(finished > start)
        #expect(finished - start <= 6)
        await system.advance(by: .milliseconds(300))
        #expect(system.completeSweepCount == finished)
        let late = WindowID(rawValue: "readable-after-expiry")
        system.windows.append(WindowSnapshot(id: late, processIdentifier: 81,
            frame: BTRect(x: 200, y: 200, width: 600, height: 400), displayID: system.mainDisplay.id))
        clock.elapsed = 0.8
        await system.advance(by: .milliseconds(300))
        #expect(system.completeSweepCount == finished)
        #expect(system.frameWriteCounts[late, default: 0] == 0)
        #expect(!system.probeRequests.contains { $0.contains(late) })
    }

    @Test(arguments: [LayoutMode.bento, .tabbed])
    func existingSiblingDoesNotSatisfyUnknownArrival(mode: LayoutMode) async throws {
        let (system, model) = try await fixture(mode)
        defer { model.shutdown() }
        let clock = WindowArrivalTestClock(model)
        let id = WindowID(rawValue: "late-sibling")
        system.windows.append(WindowSnapshot(id: id, processIdentifier: 42,
            frame: BTRect(x: 200, y: 200, width: 600, height: 400), displayID: system.mainDisplay.id))
        system.offscreenWindowIDs.insert(id)
        system.focusedID = system.windows[0].id
        system.eventHandler?(WindowSystemEvent(kind: .created, windowID: nil, processIdentifier: 42))
        await system.joinWindowEvent(on: model)
        #expect(system.frameWriteCounts[id, default: 0] == 0)
        clock.elapsed = 0.24
        system.offscreenWindowIDs.remove(id)
        await system.joinWindowEvent(on: model)
        try await waitForWindowEventsToDrain(model, system)
        #expect(system.frameWriteCounts[id, default: 0] > 0)
    }

    @Test(arguments: [LayoutMode.bento, .tabbed], [false, true])
    func pendingReadinessDoesNotOutliveCancellation(mode: LayoutMode, shutdown: Bool) async throws {
        let (system, model) = try await fixture(mode)
        defer { model.shutdown() }
        _ = WindowArrivalTestClock(model)
        let id = WindowID(rawValue: "cancelled-late")
        system.windows.append(WindowSnapshot(id: id, processIdentifier: 81,
            frame: BTRect(x: 200, y: 200, width: 600, height: 400), displayID: system.mainDisplay.id))
        system.offscreenWindowIDs.insert(id)
        system.eventHandler?(WindowSystemEvent(kind: .created, windowID: id, processIdentifier: 81))
        await system.joinWindowEvent(on: model)
        if shutdown {
            model.shutdown()
        } else {
            system.offscreenWindowIDs = Set(system.windows.map(\.id))
            system.focusedWindowIsAbsent = true
            model.beginActiveSpaceStabilization()
            try #require(await system.waitFor { !model.isStabilizingSpace })
        }
        try await waitForWindowEventsToDrain(model, system)
        let sweeps = system.completeSweepCount
        await system.advance(by: .milliseconds(600))
        #expect(system.completeSweepCount == sweeps)
        #expect(system.frameWriteCounts[id, default: 0] == 0)
    }
}
