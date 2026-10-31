import AppKit
import BetterTileCore
import Foundation
import Testing
@testable import BetterTileApp

@Suite(.appTestApplication, .serialized) @MainActor
struct SingleWindowRepairRollbackTests {
    private func store(_ model: BetterTileModel) throws -> LayoutSessionStore {
        try #require(Mirror(reflecting: model).children.first {
            $0.label?.hasSuffix("sessionStore") == true
        }?.value as? LayoutSessionStore)
    }

    private func fixture(native: Bool) async throws -> (FakeAppWindowSystem, BetterTileModel) {
        _ = NSApplication.shared
        let system = makeManualWindowSystem()
        system.windows.append(WindowSnapshot(id: WindowID(rawValue: "rollback-peer"), processIdentifier: 43,
            frame: BTRect(x: 550, y: 300, width: 400, height: 350), displayID: system.mainDisplay.id))
        if native {
            let first = NativeSpaceID(rawValue: 1), second = NativeSpaceID(rawValue: 2)
            system.desktopObservation = NativeDesktopObservation(
                currentSpaceByDisplay: [system.mainDisplay.id: first],
                knownSpacesByDisplay: [system.mainDisplay.id: [first, second]],
                windowMembership: Dictionary(uniqueKeysWithValues: system.windows.map { ($0.id, [first]) }))
        }
        let model = makeModel(system: system)
        model.configuration.defaultLayoutMode = .manual
        model.configuration.bentoInnerGap = 11
        model.setActiveMode(.bento)
        try #require(await system.waitFor { model.settlementTasks.isEmpty })
        return (system, model)
    }

    struct Context: Sendable {
        let native: Bool
        let manual: Bool
    }
    nonisolated static let contexts = [false, true].flatMap { native in
        [false, true].map { Context(native: native, manual: $0) }
    }

    // A real AX write can change the frame before reporting failure.
    @Test(arguments: ["degraded", "restored", "noEffect"], contexts)
    func singleRepairStopsOnlyAfterRollbackDamage(outcome: String, context: Context) async throws {
        let (system, model) = try await fixture(native: context.native)
        defer { model.shutdown() }
        if context.manual { model.setActiveMode(.manual) }
        let display = system.mainDisplay.id
        let before = try #require(store(model).session(for: display))
        let baseline = system.windows.map(\.frame)
        let a = system.windows[0].id, b = system.windows[1].id
        system.offscreenWindowIDs = [b]
        let firstWrite = system.frameWriteCounts[a, default: 0] + 1
        system.failedFrameWriteNumbers[a] = outcome == "degraded" ? [firstWrite, firstWrite + 1] : [firstWrite]
        let damagedFrame = BTRect(x: 40, y: 30, width: 800, height: 700)
        system.onFrameWrite = { [weak system] id, _ in
            guard let system, id == a, system.frameWriteCounts[a] == firstWrite, outcome != "noEffect" else { return }
            system.windows[0].frame = damagedFrame
        }
        model.repairCurrentLayout()
        system.onFrameWrite = nil
        let after = try #require(store(model).session(for: display))
        #expect(after.id == before.id)
        #expect(after.mode == before.mode)
        #expect(after.bentoState == before.bentoState, "Failure must not publish Repair's provisional reset")
        #expect(after.isBentoInitialized == before.isBentoInitialized)
        #expect(system.windows[1].frame == baseline[1])
        #expect(system.frameWriteCounts[a] == firstWrite + (outcome == "noEffect" ? 0 : 1))
        #expect(after.automaticWritesSuspended == (outcome == "degraded"))
        #expect((model.statusMessage?.contains("Repair Layout") == true) == (outcome == "degraded"))
        if outcome == "degraded" {
            #expect(system.windows[0].frame == damagedFrame)
            let writes = system.frameWriteCounts
            system.failedFrameWriteNumbers.removeAll()
            system.offscreenWindowIDs = []
            var resized = system.mainDisplay
            resized.visibleFrame.size.height -= 60
            system.availableDisplays = [resized]
            model.handleApplicationTopologyChange()
            model.watchdog()
            await system.advance(by: .milliseconds(350))
            #expect(system.frameWriteCounts == writes, "Later observations must not replay the damaged layout")
            #expect(system.windows.map(\.frame) == [damagedFrame, baseline[1]])
            #expect(try store(model).session(for: display)?.automaticWritesSuspended == true)
            if !context.manual {
                model.repairCurrentLayout()
                try #require(await system.waitFor { model.settlementTasks.isEmpty })
                #expect(try store(model).session(for: display)?.automaticWritesSuspended == false)
                #expect(BentoLayoutVerifier.overlappingWindowIDs(
                    Dictionary(uniqueKeysWithValues: system.windows.map { ($0.id, $0.frame) })).isEmpty)
            }
        } else {
            #expect(system.windows.map(\.frame) == baseline)
        }
    }

    @Test(arguments: [false, true], ["command", "generation"])
    func singleRepairRollbackKeepsNewerOwnerState(native: Bool, invalidation: String) async throws {
        let (system, model) = try await fixture(native: native)
        defer { model.shutdown() }
        let display = system.mainDisplay.id
        let before = try #require(store(model).session(for: display))
        let a = system.windows[0].id, b = system.windows[1].id
        system.offscreenWindowIDs = [b]
        let firstWrite = system.frameWriteCounts[a, default: 0] + 1
        system.failedFrameWriteNumbers[a] = [firstWrite, firstWrite + 1]
        var newer: LayoutSession?
        system.onFrameWrite = { [weak system, weak model] id, _ in
            guard let system, let model, id == a else { return }
            if system.frameWriteCounts[a] == firstWrite {
                system.windows[0].frame = BTRect(x: 40, y: 30, width: 800, height: 700)
            } else if system.frameWriteCounts[a] == firstWrite + 1 {
                if invalidation == "command" { model.setActiveMode(.manual) }
                else { model.beginActiveSpaceStabilization() }
                newer = try? store(model).session(for: display)
            }
        }
        model.repairCurrentLayout()
        system.onFrameWrite = nil
        let captured = try #require(newer, "The new command or generation must run during restoration")
        let after = try #require(store(model).session(for: display))
        #expect(after.id == before.id)
        #expect(after.mode == captured.mode)
        #expect(after.bentoState == captured.bentoState)
        #expect(after.lastObservedFrames == captured.lastObservedFrames)
        #expect(after.isBentoInitialized == captured.isBentoInitialized)
        #expect(after.automaticWritesSuspended)
        #expect(model.statusMessage?.contains("Repair Layout") == true)
        let frames = system.windows.map(\.frame), writes = system.frameWriteCounts
        system.failedFrameWriteNumbers.removeAll()
        system.offscreenWindowIDs = []
        await system.advance(by: .milliseconds(350))
        model.handleApplicationTopologyChange()
        model.watchdog()
        #expect(system.windows.map(\.frame) == frames)
        #expect(system.frameWriteCounts == writes)
        #expect(try store(model).session(for: display)?.mode == captured.mode)
    }

    @Test(arguments: [false, true])
    func singleRepairRollbackSuspendsCapturedInactiveDesktop(degraded: Bool) async throws {
        let (system, model) = try await fixture(native: true)
        defer { model.shutdown() }
        let display = system.mainDisplay.id
        let before = try #require(store(model).session(for: display))
        let a = system.windows[0].id, b = system.windows[1].id
        system.offscreenWindowIDs = [b]
        let firstWrite = system.frameWriteCounts[a, default: 0] + 1
        system.failedFrameWriteNumbers[a] = degraded ? [firstWrite, firstWrite + 1] : [firstWrite]
        var newer: LayoutSession?
        system.onFrameWrite = { [weak system, weak model] id, _ in
            guard let system, let model, id == a else { return }
            if system.frameWriteCounts[a] == firstWrite {
                system.windows[0].frame = BTRect(x: 40, y: 30, width: 800, height: 700)
            } else if system.frameWriteCounts[a] == firstWrite + 1 {
                system.desktopObservation?.currentSpaceByDisplay[display] = NativeSpaceID(rawValue: 2)
                system.offscreenWindowIDs = [a, b]
                model.beginActiveSpaceStabilization()
                newer = try? store(model).session(for: display)
            }
        }
        model.repairCurrentLayout()
        system.onFrameWrite = nil
        let captured = try #require(newer)
        try #require(captured.id != before.id)
        #expect(try store(model).session(for: display) == captured, "Failure must not replace or suspend the new desktop")
        let owner = try #require(store(model).allSessions(for: display).first { $0.id == before.id })
        #expect(owner.bentoState == before.bentoState)
        #expect(owner.lastObservedFrames == before.lastObservedFrames)
        #expect(owner.automaticWritesSuspended == degraded)
        #expect((model.statusMessage?.contains("other desktop") == true) == degraded)
        #expect((model.statusMessage?.contains("Repair Layout") == true) == degraded)
        let frames = system.windows.map(\.frame), writes = system.frameWriteCounts
        system.failedFrameWriteNumbers.removeAll()
        await system.advance(by: .milliseconds(350))
        model.handleApplicationTopologyChange()
        #expect(system.windows.map(\.frame) == frames)
        #expect(system.frameWriteCounts == writes)
        #expect(try store(model).session(for: display)?.id == captured.id)
        #expect(try store(model).session(for: display)?.automaticWritesSuspended == false)
    }
}
