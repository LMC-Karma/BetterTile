import AppKit
import BetterTileCore
import Foundation
import Testing
@testable import BetterTileApp

@Suite(.appTestApplication, .serialized) @MainActor
struct RepeatedApplicationRecoveryTests {
    /// A frame-only inventory, or its trailing divider inventory, can release
    /// a hold without reconciling arrivals in that pass.
    @Test(arguments: [false, true], [false, true])
    func heldReturnDuringFrameOnlyReadIsReconciled(cached: Bool, native: Bool) async throws {
        _ = NSApplication.shared
        let system = makeManualWindowSystem()
        let returning = WindowSnapshot(id: WindowID(rawValue: "returning"), processIdentifier: 43,
            frame: BTRect(x: 300, y: 200, width: 600, height: 400), displayID: system.mainDisplay.id)
        system.windows.append(returning)
        if native {
            let space = NativeSpaceID(rawValue: 1)
            system.desktopObservation = NativeDesktopObservation(
                currentSpaceByDisplay: [system.mainDisplay.id: space],
                knownSpacesByDisplay: [system.mainDisplay.id: [space]],
                windowMembership: Dictionary(uniqueKeysWithValues: system.windows.map { ($0.id, [space]) }))
        }
        var now = system.uptime
        system.applicationHoldUptime = { now }
        system.applicationHoldDuration = 60
        system.unresponsiveProcessIDs = [returning.processIdentifier]
        let model = makeModel(system: system)
        defer { model.shutdown() }
        model.configuration.defaultLayoutMode = .manual
        model.configuration.singleWindowPlacement = .maximize
        model.setActiveMode(.bento)
        try #require(system.applicationHoldsUntil[43] != nil)
        try #require(model.settlementTasks.isEmpty)
        // The last complete inventory omitted the held window. A targeted
        // refresh of A must not invent a readable cached B.
        system.cachedSnapshotsAvailable = cached
        system.cachedVisibilityOmittedIDs = [returning.id]
        system.unresponsiveProcessIDs.removeAll()
        system.onVisibleWindowSweep = { _ in now += 61 }
        system.windows[0].frame.origin.x += 10
        system.eventHandler?(WindowSystemEvent(kind: .moved, windowID: system.windows[0].id,
            processIdentifier: system.windows[0].processIdentifier))
        model.processPendingWindowEvents()
        system.onVisibleWindowSweep = nil
        system.cachedVisibilityOmittedIDs.removeAll()
        try #require(system.applicationHoldsUntil[43] == nil, "The frame-only inventory released the hold")
        #expect(await system.waitFor(timeout: .seconds(1)) { system.windows[1].frame != returning.frame },
            """
            A frame-only hold release must queue reconciliation without another event. \
            cached=\(cached), native=\(native), hold=\(String(describing: system.applicationHoldsUntil[43])), \
            B=\(system.windows[1].frame), settlementTasks=\(model.settlementTasks.count), \
            sweeps=\(system.completeSweepCount)
            """)
        try #require(await system.waitFor { model.settlementTasks.isEmpty })
        #expect(BentoLayoutVerifier.overlappingWindowIDs(
            Dictionary(uniqueKeysWithValues: system.windows.map { ($0.id, $0.frame) })).isEmpty)
    }

    @Test(arguments: [false, true], [false, true])
    func repeatedManualAdaptiveHeldReturn(repositionCallbacks: Bool, measuresMinimums: Bool) async throws {
        _ = NSApplication.shared
        let system = makeManualWindowSystem()
        let display = DisplaySnapshot(id: system.mainDisplay.id,
            frame: BTRect(x: 0, y: 0, width: 2560, height: 1440),
            visibleFrame: BTRect(x: 0, y: 30, width: 2560, height: 1332), isMain: true)
        system.availableDisplays = [display]
        let initial = [BTRect(x: 100, y: 250, width: 640, height: 480),
                       BTRect(x: 1700, y: 600, width: 640, height: 480)]
        system.windows = zip(["A", "B"], initial).enumerated().map { index, item in
            WindowSnapshot(id: WindowID(rawValue: item.0), processIdentifier: Int32(10019 + index * 3),
                bundleIdentifier: "test.BigMin", frame: item.1, displayID: display.id)
        }
        system.measuresOnWrite = measuresMinimums
        for window in system.windows {
            system.enforcedMinimumWidths[window.id] = 200
            system.enforcedMinimumHeights[window.id] = 154
        }
        let space = NativeSpaceID(rawValue: 3848)
        system.desktopObservation = NativeDesktopObservation(currentSpaceByDisplay: [display.id: space],
            knownSpacesByDisplay: [display.id: [space]],
            windowMembership: Dictionary(uniqueKeysWithValues: system.windows.map { ($0.id, [space]) }))
        system.applicationHoldDuration = 0.3
        let model = makeModel(system: system)
        defer { model.shutdown() }
        model.configuration.defaultLayoutMode = .manual
        model.configuration.singleWindowPlacement = .maximize
        model.configuration.bentoInnerGap = 1
        for cycle in 1...3 {
            model.setActiveMode(.manual)
            await system.advance(by: .milliseconds(300))
            for index in system.windows.indices {
                system.windows[index].frame = initial[index]
                if repositionCallbacks {
                    system.eventHandler?(WindowSystemEvent(kind: .moved, windowID: system.windows[index].id,
                        processIdentifier: system.windows[index].processIdentifier))
                    system.eventHandler?(WindowSystemEvent(kind: .resized, windowID: system.windows[index].id,
                        processIdentifier: system.windows[index].processIdentifier))
                }
            }
            await system.advance(by: .milliseconds(300))
            let held = system.windows[1]
            system.unresponsiveProcessIDs = [held.processIdentifier]
            model.setActiveMode(.bento)
            try #require(system.applicationHoldsUntil[held.processIdentifier] != nil)
            #expect(system.windows[0].frame == display.visibleFrame, "Responsive A expands while B is unreadable")
            #expect(system.windows[1].frame == initial[1])
            system.unresponsiveProcessIDs.removeAll()
            let recovered = await system.waitFor(timeout: .seconds(2)) {
                system.applicationHoldsUntil[held.processIdentifier] == nil
                    && system.windows[1].frame != initial[1]
                    && BentoLayoutVerifier.overlappingWindowIDs(
                        Dictionary(uniqueKeysWithValues: system.windows.map { ($0.id, $0.frame) })
                    ).isEmpty
            }
            let pid = held.processIdentifier
            #expect(recovered, """
                Cycle \(cycle): a readable same-identity B must rejoin without a post-return action. \
                hold=\(String(describing: system.applicationHoldsUntil[pid])), now=\(system.uptime), \
                B=\(system.windows[1].frame) (initial \(initial[1])), settlementTasks=\(model.settlementTasks.count), \
                sweeps=\(system.completeSweepCount), recoveryDeadline=\(String(describing: system.unresponsiveApplicationRecoveryDeadlines[pid]))
                """)
            try #require(await system.waitFor { model.settlementTasks.isEmpty })
        }
    }
}
