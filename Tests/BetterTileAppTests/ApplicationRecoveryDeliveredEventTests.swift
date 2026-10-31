import AppKit
import BetterTileCore
import Foundation
import Testing
@testable import BetterTileApp

@Suite(.appTestApplication, .serialized) @MainActor
struct ApplicationRecoveryDeliveredEventTests {
    @Test
    func deliveredNativeSnapOnReturningWindow() async throws {
        _ = NSApplication.shared
        let system = makeManualWindowSystem()
        // The test releases this hold explicitly after delivery. Keep the
        // fake system's clock still while full-suite load delays the main actor.
        var holdUptime = system.uptime
        system.applicationHoldUptime = { holdUptime }
        system.applicationHoldDuration = 60
        let held = WindowSnapshot(id: WindowID(rawValue: "held"), processIdentifier: 43,
            frame: BTRect(x: 300, y: 200, width: 600, height: 400), displayID: system.mainDisplay.id)
        system.windows.append(held)
        system.unresponsiveProcessIDs = [43]
        let model = makeModel(system: system)
        defer { model.shutdown() }
        model.setActiveMode(.bento)
        system.cachedSnapshotsAvailable = false
        let requested = BTRect(x: 0, y: 0, width: 500, height: 800)
        system.unresponsiveProcessIDs.removeAll()
        system.windows[1].frame = requested
        system.eventHandler?(WindowSystemEvent(kind: .resized, windowID: held.id, processIdentifier: 43))
        await system.joinWindowEvent(on: model)
        try #require(system.unresponsiveApplicationRecoveryDeadlines[43] != nil,
            "Normal event processing must complete while the app is still held.")
        #expect(system.frameWriteCounts[held.id] == nil)
        let sweepsDuringHold = system.completeSweepCount
        await system.advance(by: .milliseconds(150))
        #expect(system.completeSweepCount == sweepsDuringHold,
            "Retaining a frame event must not poll the held app.")
        // Release the fake hold after normal delivery has completed.
        holdUptime += 60.1
        model.watchdog()
        #expect(await system.waitFor(timeout: .seconds(1)) { system.frameWriteCounts[held.id] != nil })
        #expect(system.windows[1].frame.approximatelyEquals(requested, tolerance: 1))
        try #require(await system.waitFor { model.settlementTasks.isEmpty })
        let writes = system.frameWriteCounts
        model.watchdog()
        #expect(system.frameWriteCounts == writes, "The adopted membership must not rebuild on the next sweep")
        #expect(system.windows[1].frame.approximatelyEquals(requested, tolerance: 1))
    }

    @Test(arguments: [false, true])
    func heldFrameEventsRetireOnDestructionOrProcessExit(processExited: Bool) async throws {
        _ = NSApplication.shared
        let system = makeManualWindowSystem()
        system.applicationHoldDuration = 60
        let held = WindowSnapshot(id: WindowID(rawValue: "held"), processIdentifier: 43,
            frame: BTRect(x: 300, y: 200, width: 600, height: 400), displayID: system.mainDisplay.id)
        system.windows.append(held)
        // Destruction must retire the event even when another window keeps this PID held.
        var sibling = held
        sibling.id = WindowID(rawValue: "held-sibling")
        system.windows.append(sibling)
        system.unresponsiveProcessIDs = [43]
        let model = makeModel(system: system)
        defer { model.shutdown() }
        model.setActiveMode(.bento)
        system.cachedSnapshotsAvailable = false
        system.eventHandler?(WindowSystemEvent(kind: .resized, windowID: held.id, processIdentifier: 43))
        await system.joinWindowEvent(on: model)

        if processExited {
            let terminated = system.windows.filter { $0.processIdentifier == 43 }
            system.windows.removeAll { $0.processIdentifier == 43 }
            // Match the adapter's termination path; hold release alone also
            // happens when live windows remain off screen.
            for window in terminated {
                system.eventHandler?(WindowSystemEvent(kind: .destroyed,
                    windowID: window.id, processIdentifier: 43))
            }
            model.watchdog()
        } else {
            system.windows.removeAll { $0.id == held.id }
            system.eventHandler?(WindowSystemEvent(kind: .destroyed, windowID: held.id, processIdentifier: 43))
            await system.joinWindowEvent(on: model)
        }

        let remaining = system.windows[0]
        // Consume the exit's remaining pending batch, then verify later callbacks
        // never refresh or requeue the retired window's frame event.
        system.eventHandler?(WindowSystemEvent(kind: .resized, windowID: remaining.id, processIdentifier: 42))
        await system.joinWindowEvent(on: model)
        system.cachedSnapshotsAvailable = true
        system.eventHandler?(WindowSystemEvent(kind: .resized, windowID: remaining.id, processIdentifier: 42))
        await system.joinWindowEvent(on: model)
        #expect(system.cachedRefreshRequests.last == [remaining.id])
        #expect(system.frameWriteCounts[held.id] == nil)
        #expect((system.unresponsiveApplicationRecoveryDeadlines[43] != nil) == !processExited)
        let sweeps = system.completeSweepCount
        await system.advance(by: .milliseconds(250))
        #expect(system.completeSweepCount == sweeps, "Retirement must not schedule repeated sweeps.")
    }
}
