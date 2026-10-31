import BetterTileCore
import Foundation
import Testing
@testable import BetterTileApp

/// Regressions for the arrival-latency change.
@Suite(.appTestApplication, .serialized) @MainActor
struct ArrivalLatencyRegressionTests {
    private func fixture(_ mode: LayoutMode) async throws -> (FakeAppWindowSystem, BetterTileModel) {
        let system = makeManualWindowSystem()
        let model = makeModel(system: system)
        model.configuration.singleWindowPlacement = .maximize
        model.setActiveMode(mode)
        try #require(await system.waitFor { model.settlementTasks.isEmpty && (mode != .tabbed || model.activeTabbedState != nil) })
        try await waitForWindowEventsToDrain(model, system)
        return (system, model)
    }

    private func add(_ name: String, _ system: FakeAppWindowSystem, floating: Bool = false) -> WindowID {
        let id = WindowID(rawValue: name)
        system.windows.append(WindowSnapshot(id: id, processIdentifier: 81,
            frame: BTRect(x: 200, y: 200, width: 600, height: 400), displayID: system.mainDisplay.id, isFloating: floating))
        return id
    }

    private func created(_ system: FakeAppWindowSystem, _ id: WindowID) {
        system.eventHandler?(WindowSystemEvent(kind: .created, windowID: id, processIdentifier: 81))
    }

    @Test(arguments: [LayoutMode.bento, .tabbed], [true, false])
    func reusedInventoryDoesNotProbeOrWriteAfterUnnotifiedSpaceChange(mode: LayoutMode, hasNativeObservation: Bool) async throws {
        try await spaceChangeDuringClassification(mode, hasNativeObservation: hasNativeObservation, hasMembership: true)
    }

    @Test(arguments: [LayoutMode.bento, .tabbed])
    func reusedInventoryWithoutMembershipDoesNotWriteAfterUnnotifiedSpaceChange(mode: LayoutMode) async throws {
        try await spaceChangeDuringClassification(mode, hasNativeObservation: true, hasMembership: false)
    }

    private func spaceChangeDuringClassification(_ mode: LayoutMode, hasNativeObservation: Bool, hasMembership: Bool) async throws {
        let (system, model) = try await fixture(mode)
        defer { model.shutdown() }
        let first = NativeSpaceID(rawValue: 1), second = NativeSpaceID(rawValue: 2)
        let display = system.mainDisplay.id
        if hasNativeObservation { system.desktopObservation = NativeDesktopObservation(currentSpaceByDisplay: [display: first],
            knownSpacesByDisplay: [display: [first, second]],
            windowMembership: Dictionary(uniqueKeysWithValues: system.windows.map { ($0.id, [first]) })) }
        model.beginActiveSpaceStabilization()
        try #require(await system.waitFor { !model.isStabilizingSpace && model.settlementTasks.isEmpty })
        try await waitForWindowEventsToDrain(model, system)
        await system.advance(by: .milliseconds(350)) // Stabilization suppresses frame events for 300 ms.
        model.setActiveMode(mode)
        try #require(await system.waitFor { model.settlementTasks.isEmpty })
        try await waitForWindowEventsToDrain(model, system)
        await system.advance(by: .milliseconds(300)) // Drain the asynchronous Tabbed reapply.
        let id = add("departing-classified-arrival", system)
        if hasMembership { system.desktopObservation?.windowMembership[id] = [first] }
        let writes = system.frameWriteCounts, probes = system.probeRequests
        var switched = false
        system.onVisibleWindowSweep = { _ in
            guard !switched else { return }
            // The user changes Space while classification runs. The Space notification waits behind
            // this synchronous pass, and the cached observation still names the first Space.
            system.onDisplays = {
                system.onDisplays = nil
                switched = true
                system.physicalSpace = second
                system.offscreenWindowIDs = Set(system.windows.map(\.id))
            }
        }
        created(system, id)
        system.eventHandler?(WindowSystemEvent(kind: .resized, windowID: id, processIdentifier: 81))
        await system.joinWindowEvent(on: model)
        await system.advance(by: .milliseconds(20))
        #expect(switched)
        #expect(system.frameWriteCounts == writes, "A reused inventory must not authorize old-Space writes")
        #expect(system.probeRequests == probes, "A minimum-size probe also moves the window")
        system.onVisibleWindowSweep = nil
        system.onDisplays = nil
    }

    @Test(arguments: [LayoutMode.bento, .tabbed])
    func duplicateCreationKeepsFailedInventoryBackoff(mode: LayoutMode) async throws {
        let (system, model) = try await fixture(mode)
        defer { model.shutdown() }
        let id = add("failed-inventory", system)
        system.failedVisibleWindowSweeps = Set((system.completeSweepCount + 1)...(system.completeSweepCount + 20))
        created(system, id)
        await system.joinWindowEvent(on: model)
        let retry = try #require(model.windowEventTask)
        let count = system.completeSweepCount
        created(system, id)
        #expect(!retry.isCancelled, "A duplicate creation must not cancel the failed-inventory retry")
        await system.advance(by: .milliseconds(25))
        #expect(system.completeSweepCount == count, "The 240 ms retry must not run early")
    }

    @Test(arguments: [LayoutMode.bento, .tabbed])
    func creationAfterFailedFrameOnlyReadKeepsBackoff(mode: LayoutMode) async throws {
        let (system, model) = try await fixture(mode)
        defer { model.shutdown() }
        system.cachedSnapshotsAvailable = false
        system.failedVisibleWindowSweeps = [system.completeSweepCount + 1]
        system.eventHandler?(WindowSystemEvent(kind: .moved, windowID: system.windows[0].id, processIdentifier: system.windows[0].processIdentifier))
        await system.joinWindowEvent(on: model)
        try #require(model.windowEventTask)
        let count = system.completeSweepCount
        created(system, add("after-failed-read", system))
        await system.advance(by: .milliseconds(40))
        #expect(system.completeSweepCount == count, "The 240 ms frame-only retry must not become an 8 ms poll")
    }

    @Test(arguments: [LayoutMode.bento, .tabbed])
    func dialogThatBecomesWindowIsStillPlaced(mode: LayoutMode) async throws {
        let (system, model) = try await fixture(mode)
        defer { model.shutdown() }
        let clock = WindowArrivalTestClock(model)
        let id = add("dialog-then-window", system, floating: true)
        created(system, id)
        await system.advance(by: .milliseconds(40))
        #expect(system.frameWriteCounts[id, default: 0] == 0, "A floating dialog stays untiled")
        clock.elapsed = 0.04
        system.windows[system.windows.firstIndex { $0.id == id }!].isFloating = false
        try #require(await system.waitFor(timeout: .seconds(20)) {
            system.frameWriteCounts[id, default: 0] > 0 && !model.hasPendingTabbedPlacement
        }, "A window that stops being floating within the readiness interval must be placed after Tabbed work finishes")
        try await waitForWindowEventsToDrain(model, system)
    }
}
