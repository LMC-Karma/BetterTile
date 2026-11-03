import AppKit
import BetterTileCore
import Foundation
import Testing
@testable import BetterTileApp

@Suite(.appTestApplication, .serialized) @MainActor
struct ApplicationRecoveryOwnershipTests {
    private func store(_ model: BetterTileModel) -> LayoutSessionStore? {
        Mirror(reflecting: model).children.first { $0.label?.hasSuffix("sessionStore") == true }?.value as? LayoutSessionStore
    }

    @Test(arguments: ["snap", "focus", "clamp", "settlement"], [false, true])
    func degradedNativeRecoverySuspendsItsOwner(stage: String, switchesSession: Bool) async throws {
        _ = NSApplication.shared
        let system = makeManualWindowSystem()
        system.cachedSnapshotsAvailable = false
        system.applicationHoldDuration = 60
        let display = system.mainDisplay.id
        let first = NativeSpaceID(rawValue: 1), second = NativeSpaceID(rawValue: 2)
        let held = WindowID(rawValue: "held"), focused = system.windows[0].id
        system.windows.append(WindowSnapshot(id: held, processIdentifier: 43,
            frame: BTRect(x: 300, y: 200, width: 600, height: 400), displayID: display))
        system.desktopObservation = NativeDesktopObservation(currentSpaceByDisplay: [display: first],
            knownSpacesByDisplay: [display: [first, second]],
            windowMembership: Dictionary(uniqueKeysWithValues: system.windows.map { ($0.id, [first]) }))
        let model = makeModel(system: system)
        defer { model.shutdown() }
        model.configuration.defaultLayoutMode = .manual
        model.configuration.singleWindowPlacement = nil
        if stage == "settlement" { system.unresponsiveProcessIDs = [43] }
        else { model.configuration.bentoInnerGap = 0 }
        model.setActiveMode(.bento)
        try #require(await system.waitFor { model.settlementTasks.isEmpty })
        system.unresponsiveProcessIDs = [43]
        system.applicationHoldsUntil[43] = system.uptime + 60
        let original = try #require(store(model)?.session(for: display))
        system.windows[1].frame = stage == "focus" ? system.mainDisplay.visibleFrame
            : BTRect(x: 0, y: 0, width: 500, height: 800)
        system.eventHandler?(WindowSystemEvent(kind: .resized, windowID: held, processIdentifier: 43))
        await system.joinWindowEvent(on: model)
        let writes = system.frameWriteCounts
        if stage == "clamp" {
            system.windows[0].frame.size.width = 700
            system.measuresOnWrite = true
            system.enforcedMinimumWidths[focused] = 600
            // The second transaction partially shrinks held, then fails and cannot restore it.
            system.failedFrameWriteNumbers[focused] = [writes[focused, default: 0] + 2]
            system.failedFrameWriteNumbers[held] = [writes[held, default: 0] + 3]
        } else if stage == "focus" {
            // The source is already displaced by the native Fill. Both the focus write and its restore fail.
            system.failedFrameWriteNumbers[held] = [writes[held, default: 0] + 1, writes[held, default: 0] + 2]
        } else if stage == "snap" {
            system.failedFrameWriteNumbers[held] = [writes[held, default: 0] + 1]
            system.failedFrameWriteNumbers[focused] = [writes[focused, default: 0] + 2]
        }
        var switched = false
        var rollbackWrites: [WindowID: Int]?
        let failCount = writes[stage == "focus" ? held : focused, default: 0] + (stage == "clamp" ? 2 : 1)
        system.onWindowSnapshots = { [weak system, weak model] in
            guard let system, let model, !switched else { return }
            let reachedFailure: Bool
            if stage == "focus" { reachedFailure = system.frameWriteCounts[held, default: 0] >= failCount }
            else if stage == "clamp" { reachedFailure = system.frameWriteCounts[focused, default: 0] >= failCount }
            else { reachedFailure = system.frameWriteCounts[held, default: 0] > writes[held, default: 0] }
            guard reachedFailure else { return }
            switched = true
            rollbackWrites = system.frameWriteCounts
            if switchesSession {
                system.desktopObservation?.currentSpaceByDisplay[display] = second
                system.offscreenWindowIDs = Set(system.windows.map(\.id))
            }
            model.beginActiveSpaceStabilization()
        }
        if stage == "settlement" { system.onWindowSnapshots = nil }
        system.unresponsiveProcessIDs.removeAll()
        system.applicationHoldsUntil[43] = system.uptime - 1
        model.watchdog()
        if stage == "settlement" {
            try #require(model.settlementTasks[display] != nil)
            system.windows[0].frame.size.width = 600
            system.windows[0].constraints.minimumSize.width = 600
            let before = system.frameWriteCounts
            system.failedFrameWriteNumbers[focused] = [before[focused, default: 0] + 1]
            system.failedFrameWriteNumbers[held] = [before[held, default: 0] + 2]
            system.onWindowSnapshots = { [weak system, weak model] in
                guard let system, let model, !switched,
                      system.frameWriteCounts[focused, default: 0] > before[focused, default: 0] else { return }
                switched = true
                rollbackWrites = system.frameWriteCounts
                if switchesSession {
                    system.desktopObservation?.currentSpaceByDisplay[display] = second
                    system.offscreenWindowIDs = Set(system.windows.map(\.id))
                }
                model.beginActiveSpaceStabilization()
            }
            try #require(await system.waitFor { switched })
        }
        try #require(switched, "The failure must reach rollback before desktop invalidation.")
        let suspended = store(model)?.allSessions(for: display).first { $0.id == original.id }
        #expect(suspended?.automaticWritesSuspended == true)
        #expect(model.statusMessage?.contains("Use Repair") == true)
        if switchesSession {
            #expect(store(model)?.session(for: display)?.id != original.id)
            #expect(store(model)?.session(for: display)?.automaticWritesSuspended == false)
            #expect(model.statusMessage?.contains("other desktop") == true)
        }
        // Every mutation path, including Focus restoration, must stop immediately.
        let atRollback = try #require(rollbackWrites)
        #expect(system.frameWriteCounts == atRollback)
        #expect(system.probeRequests.isEmpty)
    }
}
