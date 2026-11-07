import AppKit
import BetterTileCore
import BetterTileMacOS
import Foundation
import Testing
@testable import BetterTileApp

/// Adaptive with several hung applications, as in the live report: nine
/// running applications each waited out a 0.35 s Accessibility timeout in
/// every complete sweep. These tests run the adapter's own sweep loop and gate
/// in the fake (`adapterInventoryTimeouts`) on the manual clock.
@Suite(.appTestApplication, .serialized) @MainActor
struct UnresponsiveApplicationSweepModelTests {
    static let hung: [Int32] = Array(201...209)
    static let timeout: TimeInterval = 0.351

    /// Each hung application owns one window that no read reaches.
    private func addHungApplications(to system: FakeAppWindowSystem) {
        for pid in Self.hung {
            let window = WindowSnapshot(id: WindowID(rawValue: "hung-\(pid)"), processIdentifier: pid,
                frame: BTRect(x: 100, y: 100, width: 300, height: 200), displayID: system.mainDisplay.id)
            system.windows.append(window)
            system.offscreenWindowIDs.insert(window.id)
        }
        system.adapterInventoryTimeouts = Dictionary(uniqueKeysWithValues: Self.hung.map { ($0, Self.timeout) })
    }

    @Test func closeToFillStaysQuickWhileOtherApplicationsHang() async throws {
        _ = NSApplication.shared
        let system = makeManualWindowSystem()
        let display = system.mainDisplay.visibleFrame
        let survivor = system.windows[0].id
        let closing = WindowSnapshot(id: WindowID(rawValue: "closing"), processIdentifier: 43,
            frame: BTRect(x: 500, y: 100, width: 400, height: 300), displayID: system.mainDisplay.id)
        system.windows.append(closing)
        addHungApplications(to: system)
        let model = makeModel(system: system)
        defer { model.shutdown() }
        model.configuration.singleWindowPlacement = .maximize
        model.setActiveMode(.bento)
        try #require(await system.waitFor {
            system.frameWriteCounts[closing.id] != nil && system.windows[0].frame.size.width < display.size.width
        })
        // A session that has run for a while: first-contact timeouts, recovery
        // probes and settlement have finished.
        await system.advance(by: .seconds(20))
        try #require(await system.waitFor { model.settlementTasks.isEmpty && model.windowEventTask == nil })
        let readsBefore = system.adapterInventoryReads.count

        var filledAt: TimeInterval?
        system.onFrameWrite = { id, frame in
            if id == survivor, frame.size.width == display.size.width, filledAt == nil { filledAt = system.uptime }
        }
        let closedAt = system.uptime
        system.windows.removeAll { $0.id == closing.id }
        system.eventHandler?(WindowSystemEvent(kind: .destroyed, windowID: closing.id, processIdentifier: 43))
        try #require(await system.waitFor(timeout: .seconds(10)) { filledAt != nil }, "\(system.windows[0].frame)")
        let elapsed = try #require(filledAt) - closedAt
        let sweeps = system.adapterInventoryReads.dropFirst(readsBefore)
        let stalled = sweeps.map { $0.filter { Self.hung.contains($0) }.count }
        print("close-to-fill-measure: elapsed=\(elapsed) sweeps=\(sweeps.count) stalled-reads-per-sweep=\(stalled)")
        #expect(elapsed < 0.5, """
            The survivor must fill without waiting out the hung applications' timeouts: \
            \(elapsed) s, stalled reads per sweep \(stalled)
            """)
    }

    /// A hung application's pane stays in the layout while sweeps skip it, and
    /// its neighbours do not grow over it. When it runs again, the next sweep
    /// reads it and its window keeps its place.
    @Test func aHungApplicationsPaneKeepsItsPlaceUntilItRunsAgain() async throws {
        _ = NSApplication.shared
        let system = makeManualWindowSystem()
        let display = system.mainDisplay.id
        for (name, pid) in [("held", Int32(43)), ("third", Int32(44))] {
            system.windows.append(WindowSnapshot(id: WindowID(rawValue: name), processIdentifier: pid,
                frame: BTRect(x: 300, y: 200, width: 400, height: 300), displayID: display))
        }
        let space = NativeSpaceID(rawValue: 7)
        system.desktopObservation = NativeDesktopObservation(currentSpaceByDisplay: [display: space],
            knownSpacesByDisplay: [display: [space]],
            windowMembership: Dictionary(uniqueKeysWithValues: system.windows.map { ($0.id, [space]) }))
        addHungApplications(to: system)
        let model = makeModel(system: system)
        defer { model.shutdown() }
        model.setActiveMode(.bento)
        let managed = system.windows.prefix(3).map(\.id)
        try #require(await system.waitFor { managed.allSatisfy { system.frameWriteCounts[$0] != nil } })
        await system.advance(by: .seconds(5))
        try #require(await system.waitFor { model.settlementTasks.isEmpty && model.windowEventTask == nil })
        let tiled = Dictionary(uniqueKeysWithValues: system.windows.prefix(3).map { ($0.id, $0.frame) })

        system.adapterInventoryTimeouts?[43] = Self.timeout
        let held = WindowID(rawValue: "held")
        for _ in 0..<12 {
            system.eventHandler?(WindowSystemEvent(kind: .moved, windowID: system.windows[0].id, processIdentifier: 42))
            await system.advance(by: .seconds(5))
            model.watchdog()
        }
        try #require(await system.waitFor { model.settlementTasks.isEmpty && model.windowEventTask == nil })
        #expect(system.unresponsiveApplicationRecoveryDeadlines[43] != nil)
        #expect(system.windows[1].frame == tiled[held], "The hung application's window keeps its place")
        #expect(abs(system.windows[2].frame.minX - tiled[WindowID(rawValue: "third")]!.minX) <= 1
            && system.windows[2].frame.size == tiled[WindowID(rawValue: "third")]!.size,
            "A neighbour must not grow over the hung application's pane")

        // It runs again and posts a notification: the next pass reads it at once.
        system.adapterInventoryTimeouts?.removeValue(forKey: 43)
        system.adapterApplicationRuns(43)
        let readsBefore = system.adapterInventoryReads.count
        system.eventHandler?(WindowSystemEvent(kind: .moved, windowID: held, processIdentifier: 43))
        #expect(await system.waitFor(timeout: .seconds(1)) {
            system.adapterInventoryReads.dropFirst(readsBefore).contains { $0.contains(43) }
                && system.unresponsiveApplicationRecoveryDeadlines[43] == nil
        }, "A recovered application is read on the next pass")
        try #require(await system.waitFor { model.settlementTasks.isEmpty && model.windowEventTask == nil })
        #expect(system.windows[1].frame == tiled[held])
    }

    /// The frontmost application stalls on each try until its hold has grown,
    /// then recovers quietly: no activation and no notification. Returns the
    /// uptime of its last stall.
    private func hangFrontmostApplicationLong(_ system: FakeAppWindowSystem, model: BetterTileModel) async -> TimeInterval {
        let pid = system.windows[0].processIdentifier
        system.adapterInventoryTimeouts = [pid: Self.timeout]
        var lastStall = system.uptime
        for index in 0..<5 {
            if index > 0 {
                // Each try comes after the longest hold that the previous stall started.
                let wait = max(system.adapterGate.holdDeadline(pid) ?? 0,
                               system.adapterGate.inventoryBackoffDeadline(pid) ?? 0) - system.uptime + 0.1
                await system.advance(by: .seconds(max(0.1, wait)))
            }
            let before = system.adapterGate.timeoutSerial(pid)
            model.perform(.leftHalf)
            if system.adapterGate.timeoutSerial(pid) != before { lastStall = system.uptime }
        }
        system.adapterInventoryTimeouts = [:]
        return lastStall
    }

    @Test func aShortcutWorksOnAQuietlyRecoveredFrontmostApplicationWithinTwoSeconds() async throws {
        _ = NSApplication.shared
        let system = makeManualWindowSystem()
        system.adapterInventoryTimeouts = [:]
        let model = makeModel(system: system)
        defer { model.shutdown() }
        let original = system.windows[0].frame
        let lastStall = await hangFrontmostApplicationLong(system, model: model)
        try #require(system.windows[0].frame == original, "No shortcut landed while the application hung")
        try #require(system.adapterGate.stallCount(42) >= 4)
        await system.advance(by: .seconds(max(0, lastStall + UnresponsiveApplicationGate.holdSeconds + 0.05 - system.uptime)))
        model.perform(.leftHalf)
        let display = system.mainDisplay.visibleFrame
        #expect(await system.waitFor(timeout: .seconds(1)) {
            system.windows[0].frame.minX == display.minX && system.windows[0].frame.size.width == display.size.width / 2
        }, "A shortcut 2 s after the last stall must work: \(system.windows[0].frame), status \(String(describing: model.statusMessage))")
    }

    @Test func aLayoutWheelActionWorksOnAQuietlyRecoveredFrontmostApplicationWithinTwoSeconds() async throws {
        _ = NSApplication.shared
        let system = makeManualWindowSystem()
        system.adapterInventoryTimeouts = [:]
        let model = makeModel(system: system)
        defer { model.shutdown() }
        let original = system.windows[0].frame
        let lastStall = await hangFrontmostApplicationLong(system, model: model)
        try #require(system.windows[0].frame == original)
        await system.advance(by: .seconds(max(0, lastStall + UnresponsiveApplicationGate.holdSeconds + 0.05 - system.uptime)))
        let target = LayoutWheelTarget(windowID: system.windows[0].id, displayID: system.windows[0].displayID,
            visibleFrame: system.mainDisplay.visibleFrame)
        model.performLayoutWheel(.windowAction(.rightHalf), for: target)
        let display = system.mainDisplay.visibleFrame
        #expect(await system.waitFor(timeout: .seconds(1)) {
            system.windows[0].frame.minX == display.midX && system.windows[0].frame.size.width == display.size.width / 2
        }, "A Layout Wheel action 2 s after the last stall must work: \(system.windows[0].frame), status \(String(describing: model.statusMessage))")
    }

    /// Without native observation, nothing else vouches for a window that a
    /// sweep did not read. An earlier application keeps posting notifications
    /// while its reads time out, so each sweep times out on it first and keeps
    /// the later, quietly recovered application. Its pane must stay.
    @Test func aKeptApplicationsPaneStaysWithoutNativeObservation() async throws {
        _ = NSApplication.shared
        let system = makeManualWindowSystem()
        let display = system.mainDisplay.id
        let noisy: Int32 = 201, quiet: Int32 = 202
        let quietWindow = WindowSnapshot(id: WindowID(rawValue: "quiet"), processIdentifier: quiet,
            frame: BTRect(x: 500, y: 100, width: 400, height: 300), displayID: display)
        system.windows.append(quietWindow)
        let noisyWindow = WindowSnapshot(id: WindowID(rawValue: "noisy"), processIdentifier: noisy,
            frame: BTRect(x: 100, y: 100, width: 300, height: 200), displayID: display)
        system.windows.append(noisyWindow)
        system.offscreenWindowIDs.insert(noisyWindow.id)
        system.adapterInventoryTimeouts = [noisy: Self.timeout]
        let model = makeModel(system: system)
        defer { model.shutdown() }
        model.setActiveMode(.bento)
        try #require(await system.waitFor {
            system.frameWriteCounts[quietWindow.id] != nil && system.windows[0].frame.size.width < system.mainDisplay.visibleFrame.size.width
        })
        await system.advance(by: .seconds(20))
        try #require(await system.waitFor { model.settlementTasks.isEmpty && model.windowEventTask == nil })
        try #require(system.desktopObservation == nil)
        let tiled = (system.windows[0].frame, system.windows[1].frame)

        // The quiet application stalls once, then recovers without a sign.
        system.adapterInventoryTimeouts?[quiet] = Self.timeout
        model.watchdog()
        system.adapterInventoryTimeouts?.removeValue(forKey: quiet)
        try #require(system.adapterGate.stallCount(quiet) == 1)
        await system.advance(by: .seconds(UnresponsiveApplicationGate.holdSeconds + 0.5))
        for _ in 0..<5 {
            system.adapterApplicationRuns(noisy)
            system.eventHandler?(WindowSystemEvent(kind: .created, windowID: nil, processIdentifier: noisy))
            model.processPendingWindowEvents()
            #expect(system.adapterInventoryReads.last?.contains(quiet) == false, "The sweep keeps the quiet application")
        }
        #expect(system.windows[1].frame == tiled.1, "The kept window keeps its place")
        #expect(system.windows[0].frame == tiled.0, "Its neighbour must not grow over the kept pane: \(system.windows[0].frame)")

        // Confirmed destruction still removes a kept window's pane.
        system.windows.removeAll { $0.id == quietWindow.id }
        system.eventHandler?(WindowSystemEvent(kind: .destroyed, windowID: quietWindow.id, processIdentifier: quiet))
        #expect(await system.waitFor(timeout: .seconds(2)) {
            system.windows[0].frame.size.width == system.mainDisplay.visibleFrame.size.width
        }, "\(system.windows[0].frame)")
    }

    /// A kept application stays due for recovery, so recovery sweeps can come
    /// about once a second. Each one reads at least one due application and
    /// charges it, so the three-attempt limit still ends them.
    @Test func recoveryOfKeptApplicationsStopsAtItsAttemptLimit() async throws {
        _ = NSApplication.shared
        let system = makeManualWindowSystem()
        addHungApplications(to: system)
        let model = makeModel(system: system)
        defer { model.shutdown() }
        model.setActiveMode(.bento)
        // Short steps: a recovery wait that is already due resumes on the next clock advance.
        for _ in 0..<180 { await system.advance(by: .seconds(1)) }
        let attempts = Self.hung.map { system.unresponsiveInventoryAttemptTimes[$0]?.count ?? 0 }
        let sweeps = system.completeSweepCount
        print("recovery-limit-measure: sweeps=\(sweeps) attempts-per-app=\(attempts)")
        // The activation sweep, at most one read in an ordinary follow-up
        // sweep, and at most three recovery probes.
        #expect(attempts.allSatisfy { $0 <= 5 }, "Reads per hung application: \(attempts)")
        #expect(sweeps <= 1 + 2 + 3 * Self.hung.count, "Complete sweeps: \(sweeps)")
        for _ in 0..<60 { await system.advance(by: .seconds(1)) }
        #expect(system.completeSweepCount == sweeps, "No recovery sweeps after every budget is spent")
    }
}
