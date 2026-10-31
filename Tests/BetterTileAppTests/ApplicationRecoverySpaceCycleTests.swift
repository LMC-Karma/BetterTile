import AppKit
import BetterTileCore
import Foundation
import Testing
@testable import BetterTileApp

@Suite(.appTestApplication, .serialized) @MainActor
struct ApplicationRecoverySpaceCycleTests {
    @Test(arguments: ["watchdog", "topology", "timer"])
    func retainedSnapSurvivesSpaceRoundTrip(source: String) async throws {
        _ = NSApplication.shared
        let system = makeManualWindowSystem()
        system.applicationHoldDuration = 60
        let held = WindowSnapshot(id: WindowID(rawValue: "held"), processIdentifier: 43,
            frame: BTRect(x: 300, y: 200, width: 600, height: 400), displayID: system.mainDisplay.id)
        system.windows.append(held)
        system.unresponsiveProcessIDs = [43]
        system.cachedSnapshotsAvailable = false
        let display = system.mainDisplay.id
        let first = NativeSpaceID(rawValue: 1), second = NativeSpaceID(rawValue: 2)
        system.desktopObservation = NativeDesktopObservation(currentSpaceByDisplay: [display: first],
            knownSpacesByDisplay: [display: [first, second]],
            windowMembership: Dictionary(uniqueKeysWithValues: system.windows.map { ($0.id, [first]) }))
        let model = makeModel(system: system)
        defer { model.shutdown() }
        model.configuration.defaultLayoutMode = .manual
        model.setActiveMode(.bento)
        let requested = BTRect(x: 0, y: 0, width: 500, height: 800)
        system.windows[1].frame = requested
        system.eventHandler?(WindowSystemEvent(kind: .resized, windowID: held.id, processIdentifier: 43))
        await system.joinWindowEvent(on: model)
        system.desktopObservation?.currentSpaceByDisplay[display] = second
        system.offscreenWindowIDs = Set(system.windows.map(\.id))
        model.beginActiveSpaceStabilization()
        try #require(await system.waitFor { !model.isStabilizingSpace })
        system.desktopObservation?.currentSpaceByDisplay[display] = first
        system.offscreenWindowIDs.removeAll()
        model.beginActiveSpaceStabilization()
        try #require(await system.waitFor { !model.isStabilizingSpace })
        try #require(model.activeMode(for: display) == .bento)
        system.unresponsiveProcessIDs.removeAll()
        if source == "timer" {
            system.applicationHoldsUntil[43] = system.uptime + 0.02
            model.watchdog()
            try #require(await system.waitFor { system.frameWriteCounts[held.id] != nil })
        } else {
            system.applicationHoldsUntil[43] = system.uptime - 0.01
            if source == "watchdog" { model.watchdog() }
            else {
                system.eventHandler?(WindowSystemEvent(kind: .created, windowID: nil, processIdentifier: 42))
                await system.joinWindowEvent(on: model)
            }
        }
        try #require(await system.waitFor { model.settlementTasks.isEmpty })
        #expect(system.windows[1].frame.approximatelyEquals(requested, tolerance: 1), "Retained snap must survive Space stabilization clearing the ordinary event buffer")
    }
}
