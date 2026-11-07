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
    private func hangFrontmostApplicationLong(_ system: FakeAppWindowSystem, model: BetterTileModel,
                                              trying action: WindowAction) async -> TimeInterval {
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
            model.perform(action)
            if system.adapterGate.timeoutSerial(pid) != before { lastStall = system.uptime }
        }
        system.adapterInventoryTimeouts = [:]
        return lastStall
    }

    /// Manual: the window moves to the requested half. Adaptive: a second,
    /// responsive application shares the desktop, and the action swaps the
    /// frontmost window into the right half.
    private func prepareQuietRecovery(adaptive: Bool) async throws -> (FakeAppWindowSystem, BetterTileModel, WindowAction) {
        let system = makeManualWindowSystem()
        system.adapterInventoryTimeouts = [:]
        if adaptive {
            system.windows.append(WindowSnapshot(id: WindowID(rawValue: "peer"), processIdentifier: 43,
                frame: BTRect(x: 500, y: 100, width: 400, height: 300), displayID: system.mainDisplay.id))
        }
        let model = makeModel(system: system)
        if adaptive {
            model.setActiveMode(.bento)
            try #require(await system.waitFor {
                system.windows.allSatisfy { system.frameWriteCounts[$0.id] != nil }
                    && system.windows[0].frame.midX < system.mainDisplay.visibleFrame.midX
            })
            await system.advance(by: .seconds(2))
            try #require(await system.waitFor { model.settlementTasks.isEmpty && model.windowEventTask == nil })
        }
        return (system, model, adaptive ? .rightHalf : .leftHalf)
    }

    private func reachedHalf(_ action: WindowAction, _ frame: BTRect, on display: BTRect) -> Bool {
        let half = display.size.width / 2
        return action == .leftHalf
            ? frame.minX == display.minX && frame.size.width == half
            : frame.midX > display.midX && abs(frame.size.width - half) <= 20
    }

    @Test(arguments: [false, true])
    func aShortcutWorksOnAQuietlyRecoveredFrontmostApplicationWithinTwoSeconds(adaptive: Bool) async throws {
        _ = NSApplication.shared
        let (system, model, action) = try await prepareQuietRecovery(adaptive: adaptive)
        defer { model.shutdown() }
        let original = system.windows[0].frame
        let lastStall = await hangFrontmostApplicationLong(system, model: model, trying: action)
        try #require(system.windows[0].frame == original, "No shortcut landed while the application hung")
        try #require(system.adapterGate.stallCount(42) >= 4)
        await system.advance(by: .seconds(max(0, lastStall + UnresponsiveApplicationGate.holdSeconds + 0.05 - system.uptime)))
        try #require(system.adapterGate.isInventoryBackedOff(42, now: system.uptime), "The long backoff is still running")
        model.perform(action)
        let display = system.mainDisplay.visibleFrame
        #expect(await system.waitFor(timeout: .seconds(1)) { reachedHalf(action, system.windows[0].frame, on: display) },
            "A shortcut 2 s after the last stall must work: \(system.windows[0].frame), status \(String(describing: model.statusMessage))")
    }

    @Test(arguments: [false, true])
    func aLayoutWheelActionWorksOnAQuietlyRecoveredFrontmostApplicationWithinTwoSeconds(adaptive: Bool) async throws {
        _ = NSApplication.shared
        let (system, model, action) = try await prepareQuietRecovery(adaptive: adaptive)
        defer { model.shutdown() }
        let original = system.windows[0].frame
        let lastStall = await hangFrontmostApplicationLong(system, model: model, trying: action)
        try #require(system.windows[0].frame == original)
        await system.advance(by: .seconds(max(0, lastStall + UnresponsiveApplicationGate.holdSeconds + 0.05 - system.uptime)))
        let target = LayoutWheelTarget(windowID: system.windows[0].id, displayID: system.windows[0].displayID,
            visibleFrame: system.mainDisplay.visibleFrame)
        let wheelAction: WindowAction = .rightHalf
        model.performLayoutWheel(.windowAction(wheelAction), for: target)
        let display = system.mainDisplay.visibleFrame
        #expect(await system.waitFor(timeout: .seconds(1)) { reachedHalf(wheelAction, system.windows[0].frame, on: display) },
            "A Layout Wheel action 2 s after the last stall must work: \(system.windows[0].frame), status \(String(describing: model.statusMessage))")
    }

    /// Three Adaptive windows; the middle one's application keeps timing out.
    private func prepareUnreadPane(native: Bool) async throws -> (FakeAppWindowSystem, BetterTileModel, NativeSpaceID) {
        let system = makeManualWindowSystem()
        let display = system.mainDisplay.id
        for (name, pid) in [("unread", Int32(43)), ("third", Int32(44))] {
            system.windows.append(WindowSnapshot(id: WindowID(rawValue: name), processIdentifier: pid,
                frame: BTRect(x: 300, y: 200, width: 400, height: 300), displayID: display))
        }
        // The application keeps running with another open window on another Space.
        let elsewhere = WindowSnapshot(id: WindowID(rawValue: "unread-elsewhere"), processIdentifier: 43,
            frame: BTRect(x: 100, y: 100, width: 300, height: 200), displayID: display)
        system.windows.append(elsewhere)
        system.offscreenWindowIDs.insert(elsewhere.id)
        let space = NativeSpaceID(rawValue: 7), other = NativeSpaceID(rawValue: 8)
        if native {
            var membership: [WindowID: Set<NativeSpaceID>] = Dictionary(uniqueKeysWithValues: system.windows.map { ($0.id, [space]) })
            membership[elsewhere.id] = [other]
            system.desktopObservation = NativeDesktopObservation(currentSpaceByDisplay: [display: space],
                knownSpacesByDisplay: [display: [space, other]], windowMembership: membership)
        }
        system.adapterInventoryTimeouts = [:]
        let model = makeModel(system: system)
        model.setActiveMode(.bento)
        let managed = ["focused", "unread", "third"].map(WindowID.init(rawValue:))
        try #require(await system.waitFor { managed.allSatisfy { system.frameWriteCounts[$0] != nil } })
        await system.advance(by: .seconds(5))
        try #require(await system.waitFor { model.settlementTasks.isEmpty && model.windowEventTask == nil })
        system.adapterInventoryTimeouts = [43: Self.timeout]
        model.watchdog()
        try #require(system.unreadableApplicationWindowIDs.contains(WindowID(rawValue: "unread")))
        return (system, model, space)
    }

    /// Ordinary sweeps while the application stays unread.
    private func sweepWhileUnread(_ system: FakeAppWindowSystem, _ model: BetterTileModel, times: Int = 8) async {
        for _ in 0..<times {
            system.eventHandler?(WindowSystemEvent(kind: .moved, windowID: system.windows[0].id, processIdentifier: 42))
            await system.advance(by: .seconds(5))
            model.watchdog()
        }
        _ = await system.waitFor { model.settlementTasks.isEmpty && model.windowEventTask == nil }
    }

    private func neighboursFillTheDisplay(_ system: FakeAppWindowSystem) -> Bool {
        let ids: Set<WindowID> = [WindowID(rawValue: "focused"), WindowID(rawValue: "third")]
        let area = system.windows.filter { ids.contains($0.id) }.map { $0.frame.size.width * $0.frame.size.height }.reduce(0, +)
        let display = system.mainDisplay.visibleFrame
        return area >= display.size.width * display.size.height * 0.98
    }

    /// The window closes without a destroyed event while its application stays
    /// unread. Its identity record stays, as in the adapter. Two full
    /// WindowServer lists without it prove the closure, and the neighbours fill.
    @Test(arguments: [true, false])
    func aSilentlyClosedWindowOfAnUnreadApplicationLeavesItsPane(native: Bool) async throws {
        _ = NSApplication.shared
        let (system, model, _) = try await prepareUnreadPane(native: native)
        defer { model.shutdown() }
        let unread = WindowID(rawValue: "unread")
        system.windows.removeAll { $0.id == unread }
        // A closed window has no Space membership.
        system.desktopObservation?.windowMembership.removeValue(forKey: unread)
        await sweepWhileUnread(system, model)
        #expect(system.unresponsiveApplicationRecoveryDeadlines[43] != nil, "The application stayed unread")
        #expect(!system.unreadableApplicationWindowIDs.contains(unread), "Closure evidence retired its record")
        #expect(neighboursFillTheDisplay(system), "Neighbours must fill the closed pane: \(system.windows.map(\.frame))")
    }

    /// Controls: an open unread window keeps its pane; confirmed departures still leave.
    @Test(arguments: ["open", "minimize", "otherSpace", "quit"])
    func anUnreadApplicationsPaneStaysOnlyWhileItsWindowIsOpenHere(change: String) async throws {
        _ = NSApplication.shared
        let (system, model, _) = try await prepareUnreadPane(native: true)
        defer { model.shutdown() }
        let unread = WindowID(rawValue: "unread")
        let index = try #require(system.windows.firstIndex { $0.id == unread })
        let tiled = system.windows[index].frame
        switch change {
        case "minimize":
            system.windows[index].isMinimized = true
            system.offscreenWindowIDs.insert(unread)
            system.eventHandler?(WindowSystemEvent(kind: .minimized, windowID: unread, processIdentifier: 43))
        case "otherSpace":
            system.offscreenWindowIDs.insert(unread)
            system.desktopObservation?.windowMembership[unread] = [NativeSpaceID(rawValue: 8)]
        case "quit":
            // The adapter's termination path: every window of the process is destroyed.
            for window in system.windows where window.processIdentifier == 43 {
                system.eventHandler?(WindowSystemEvent(kind: .destroyed, windowID: window.id, processIdentifier: 43))
            }
            system.windows.removeAll { $0.processIdentifier == 43 }
        default: break
        }
        await sweepWhileUnread(system, model)
        if change == "open" {
            #expect(system.windows[index].frame == tiled, "An open unread window keeps its place")
            #expect(!neighboursFillTheDisplay(system), "Neighbours must not grow over an open unread pane")
        } else {
            #expect(neighboursFillTheDisplay(system), "\(change): \(system.windows.map(\.frame))")
        }
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
