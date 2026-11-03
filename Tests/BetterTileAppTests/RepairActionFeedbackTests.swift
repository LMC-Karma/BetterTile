import AppKit
import BetterTileCore
import Foundation
import Testing
@testable import BetterTileApp

@Suite(.appTestApplication, .serialized) @MainActor
struct RepairActionFeedbackTests {
    private func store(_ model: BetterTileModel) throws -> LayoutSessionStore {
        try #require(Mirror(reflecting: model).children.first {
            $0.label?.hasSuffix("sessionStore") == true
        }?.value as? LayoutSessionStore)
    }

    private func fixture(native: Bool) async throws -> (FakeAppWindowSystem, BetterTileModel) {
        _ = NSApplication.shared
        let system = makeManualWindowSystem()
        system.windows.append(WindowSnapshot(id: WindowID(rawValue: "r3-peer"), processIdentifier: 73,
            frame: BTRect(x: 620, y: 180, width: 340, height: 410), displayID: system.mainDisplay.id))
        if native {
            let one = NativeSpaceID(rawValue: 11), two = NativeSpaceID(rawValue: 12)
            system.desktopObservation = NativeDesktopObservation(currentSpaceByDisplay: [system.mainDisplay.id: one],
                knownSpacesByDisplay: [system.mainDisplay.id: [one, two]],
                windowMembership: Dictionary(uniqueKeysWithValues: system.windows.map { ($0.id, [one]) }))
        }
        let model = makeModel(system: system)
        model.configuration.defaultLayoutMode = .manual
        model.setActiveMode(.bento)
        try #require(await system.waitFor { model.settlementTasks.isEmpty })
        return (system, model)
    }

    // Follow a genuinely damaged Repair with a no-effect rejected Repair, then a
    // successful explicit Repair. Outcome/advice must belong to each operation.
    @Test(arguments: [false, true], [false, true])
    func repairFeedbackAndResumption(native: Bool, manual: Bool) async throws {
        let (system, model) = try await fixture(native: native)
        defer { model.shutdown() }
        if manual { model.setActiveMode(.manual) }
        let display = system.mainDisplay.id, a = system.windows[0].id, b = system.windows[1].id
        let original = try #require(store(model).session(for: display))
        system.offscreenWindowIDs = [b]
        let next = system.frameWriteCounts[a, default: 0] + 1
        let damage = BTRect(x: 53, y: 47, width: 823, height: 681)
        system.failedFrameWriteNumbers[a] = [next, next + 1]
        system.onFrameWrite = { [weak system] id, _ in
            guard let system, id == a, system.frameWriteCounts[a] == next else { return }
            system.windows[0].frame = damage
        }
        model.repairCurrentLayout()
        system.onFrameWrite = nil
        #expect(system.windows[0].frame == damage)
        #expect(try store(model).session(for: display)?.automaticWritesSuspended == true)
        #expect(try store(model).session(for: display)?.bentoState == original.bentoState)
        #expect(model.lastActionFeedback?.kind == .failure)
        #expect(model.lastActionFeedback?.message == "Couldn’t apply layout")
        #expect(model.lastActionFeedback?.detail == model.statusMessage)
        #expect(model.lastActionFeedback?.detail?.contains("Repair Layout") == true)
        let written = system.frameWriteCounts
        model.handleApplicationTopologyChange(waking: true)
        model.watchdog()
        await system.advance(by: .milliseconds(400))
        #expect(system.frameWriteCounts == written)
        // Explicit Repair is permitted to resume; its harmless failure must not
        // inherit the preceding transaction's degradation or advice.
        system.failedFrameWriteNumbers[a] = [system.frameWriteCounts[a, default: 0] + 1]
        model.repairCurrentLayout()
        #expect(try store(model).session(for: display)?.automaticWritesSuspended == false)
        #expect(model.lastActionFeedback?.kind == .failure)
        #expect(model.lastActionFeedback?.detail?.contains("Repair Layout") != true)
        #expect(system.windows[0].frame == damage)
        system.failedFrameWriteNumbers = [:]
        model.repairCurrentLayout()
        #expect(model.lastActionFeedback?.kind == .success)
        #expect(model.statusMessage == nil)
        #expect(try store(model).session(for: display)?.mode == original.mode)
        system.offscreenWindowIDs = []
        model.handleApplicationTopologyChange()
        try #require(await system.waitFor { model.settlementTasks.isEmpty })
        if !manual {
            #expect(BentoLayoutVerifier.overlappingWindowIDs(Dictionary(uniqueKeysWithValues:
                system.windows.map { ($0.id, $0.frame) })).isEmpty)
        }
        model.shutdown()
        let afterShutdown = system.frameWriteCounts
        await system.advance(by: .milliseconds(400))
        #expect(system.frameWriteCounts == afterShutdown)
    }

    // Switch to a populated, unrelated native desktop during the actual rollback.
    // Check the user-visible action result, not just the internal status string.
    @Test(arguments: [false, true])
    func inactiveRepairOwnerVisibleAdvice(degraded: Bool) async throws {
        let (system, model) = try await fixture(native: true)
        defer { model.shutdown() }
        let display = system.mainDisplay.id, a = system.windows[0].id, b = system.windows[1].id
        let original = try #require(store(model).session(for: display))
        let baseline = system.windows.map(\.frame)
        system.offscreenWindowIDs = [b]
        let next = system.frameWriteCounts[a, default: 0] + 1
        system.failedFrameWriteNumbers[a] = degraded ? [next, next + 1] : [next]
        system.onFrameWrite = { [weak system, weak model] id, _ in
            guard let system, let model, id == a else { return }
            if system.frameWriteCounts[a] == next {
                system.windows[0].frame = BTRect(x: 53, y: 47, width: 823, height: 681)
            } else if system.frameWriteCounts[a] == next + 1 {
                let c = WindowID(rawValue: "unrelated-c"), d = WindowID(rawValue: "unrelated-d")
                system.windows.append(WindowSnapshot(id: c, processIdentifier: 81,
                    frame: BTRect(x: 100, y: 150, width: 370, height: 420), displayID: display))
                system.windows.append(WindowSnapshot(id: d, processIdentifier: 82,
                    frame: BTRect(x: 540, y: 230, width: 350, height: 400), displayID: display))
                system.desktopObservation?.windowMembership[c] = [NativeSpaceID(rawValue: 12)]
                system.desktopObservation?.windowMembership[d] = [NativeSpaceID(rawValue: 12)]
                system.desktopObservation?.currentSpaceByDisplay[display] = NativeSpaceID(rawValue: 12)
                system.offscreenWindowIDs = [a, b]
                system.focusedID = c
                model.beginActiveSpaceStabilization()
            }
        }
        model.repairCurrentLayout()
        system.onFrameWrite = nil
        let current = try #require(store(model).session(for: display))
        let owner = try #require(store(model).allSessions(for: display).first { $0.id == original.id })
        #expect(current.id != original.id)
        #expect(!current.automaticWritesSuspended)
        #expect(owner.automaticWritesSuspended == degraded)
        #expect(owner.bentoState == original.bentoState)
        #expect(owner.isBentoInitialized == original.isBentoInitialized)
        #expect(system.windows[1].frame == baseline[1])
        #expect(system.frameWriteCounts[a] == next + 1)
        #expect(model.lastActionFeedback?.kind == .failure)
        if degraded {
            #expect(model.statusMessage?.contains("other desktop") == true)
            let visible = [model.lastActionFeedback?.message, model.lastActionFeedback?.detail].compactMap { $0 }.joined(separator: " ")
            #expect(model.lastActionFeedback?.detail == model.statusMessage)
            #expect(visible.contains("other desktop"), "The visible result must identify the inactive damaged desktop")
        } else {
            #expect(system.windows[0].frame == baseline[0])
            #expect(model.statusMessage?.contains("Repair Layout") != true)
        }
        let writes = system.frameWriteCounts, frames = system.windows.map(\.frame)
        system.failedFrameWriteNumbers = [:]
        await system.advance(by: .milliseconds(400))
        model.handleApplicationTopologyChange()
        model.watchdog()
        #expect(system.frameWriteCounts == writes)
        #expect(system.windows.map(\.frame) == frames)
        #expect(try store(model).session(for: display)?.id == current.id)
    }
}
