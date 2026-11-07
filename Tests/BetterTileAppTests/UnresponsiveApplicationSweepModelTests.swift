import AppKit
import BetterTileCore
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
}
