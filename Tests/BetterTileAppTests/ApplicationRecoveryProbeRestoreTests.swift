import AppKit
import BetterTileCore
import Foundation
import Testing
@testable import BetterTileApp

@Suite(.appTestApplication, .serialized) @MainActor
struct ApplicationRecoveryProbeRestoreTests {
    private func makeHeldSystem() -> FakeAppWindowSystem {
        _ = NSApplication.shared
        let system = makeManualWindowSystem()
        system.applicationHoldDuration = 60
        system.windows.append(WindowSnapshot(id: WindowID(rawValue: "held"), processIdentifier: 43,
            frame: BTRect(x: 300, y: 200, width: 600, height: 400), displayID: system.mainDisplay.id))
        system.unresponsiveProcessIDs = [43]
        system.cachedSnapshotsAvailable = false
        return system
    }
    private func retainedCount(_ model: BetterTileModel) -> Int {
        (Mirror(reflecting: model).children.first { $0.label?.hasSuffix("applicationRecoveryFrameEventPIDs") == true }?.value as? [WindowID: Int32])?.count ?? -1
    }
    @Test(arguments: [1, 2], ["space", "generation", "session"])
    func recoveryProbeRestorationRejectsLateSpaceChange(targetRead: Int, invalidation: String) async throws {
        let system = makeHeldSystem()
        let display = system.mainDisplay.id
        let first = NativeSpaceID(rawValue: 1), second = NativeSpaceID(rawValue: 2)
        system.desktopObservation = NativeDesktopObservation(currentSpaceByDisplay: [display: first],
            knownSpacesByDisplay: [display: [first, second]],
            windowMembership: Dictionary(uniqueKeysWithValues: system.windows.map { ($0.id, [first]) }))
        let model = makeModel(system: system)
        defer { model.shutdown() }
        model.configuration.defaultLayoutMode = .manual
        model.configuration.singleWindowPlacement = nil
        model.setActiveMode(.bento)
        system.eventHandler?(WindowSystemEvent(kind: .moved, windowID: system.windows[1].id, processIdentifier: 43))
        await system.joinWindowEvent(on: model)
        try #require(retainedCount(model) == 1)
        let originalSessionID = sessionStore(model)?.session(for: display)?.id
        system.measuresOnWrite = true
        system.unrestoredProbeWindowIDs = [system.windows[1].id]
        let probes = system.probeRequests.count
        let writes = system.frameWriteCounts
        var reads = 0
        var switched = false
        system.onWindowSnapshots = { [weak system, weak model] in
            guard let system, let model, !switched, system.probeRequests.count > probes else { return }
            reads += 1
            guard reads == targetRead else { return }
            switched = true
            if invalidation == "generation" { model.beginActiveSpaceStabilization() }
            else {
                system.desktopObservation?.currentSpaceByDisplay[display] = second
                system.offscreenWindowIDs = Set(system.windows.map(\.id))
                if invalidation == "session" { model.beginActiveSpaceStabilization() }
            }
        }
        system.unresponsiveProcessIDs.removeAll()
        system.applicationHoldsUntil[43] = system.uptime - 0.01
        model.watchdog()
        #expect(switched)
        #expect(system.probeRequests.count == probes + 1)
        #expect(system.frameWriteCounts == writes)
        #expect(system.windows[1].frame.size == BTSize(width: 1, height: 1))
        #expect(model.statusMessage?.contains("Use Repair") == true)
        let store = try #require(sessionStore(model))
        #expect(store.allSessions(for: display).first { $0.id == originalSessionID }?.automaticWritesSuspended == true)
        if invalidation == "session" {
            #expect(store.session(for: display)?.id != originalSessionID)
            #expect(store.session(for: display)?.automaticWritesSuspended == false)
            #expect(model.statusMessage?.contains("other desktop") == true)
        }
    }
    private func sessionStore(_ model: BetterTileModel) -> LayoutSessionStore? {
        Mirror(reflecting: model).children.first { $0.label?.hasSuffix("sessionStore") == true }?.value as? LayoutSessionStore
    }
}
