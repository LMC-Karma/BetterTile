import AppKit
import BetterTileCore
import Foundation
import Testing
@testable import BetterTileApp

@Suite(.appTestApplication, .serialized) @MainActor
struct RepeatedRecoveryLifecycleTests {
    struct Context: Sendable {
        let native: Bool
        let placesSingleWindow: Bool
    }
    nonisolated static let contexts = [false, true].flatMap { native in
        [false, true].map { Context(native: native, placesSingleWindow: $0) }
    }

    @Test(arguments: ["sameIdentity", "replacementWindow", "replacementProcess", "cold"], contexts)
    func recoveryAfterSingleWindowRepair(identity: String, context: Context) async throws {
        let native = context.native, placesSingleWindow = context.placesSingleWindow
        _ = NSApplication.shared
        let system = FakeAppWindowSystem()
        let display = system.mainDisplay
        let frames = [BTRect(x: 100, y: 100, width: 400, height: 300),
                      BTRect(x: 550, y: 400, width: 400, height: 300)]
        system.windows[0].frame = frames[0]
        system.windows.append(WindowSnapshot(id: WindowID(rawValue: "returning"), processIdentifier: 43,
            bundleIdentifier: "test.BigMin", frame: frames[1], displayID: display.id))
        let space = NativeSpaceID(rawValue: 1)
        if native {
            system.desktopObservation = NativeDesktopObservation(currentSpaceByDisplay: [display.id: space],
                knownSpacesByDisplay: [display.id: [space]],
                windowMembership: Dictionary(uniqueKeysWithValues: system.windows.map { ($0.id, [space]) }))
        }
        system.applicationHoldDuration = 0.05
        let model = makeModel(system: system)
        defer { model.shutdown() }
        model.configuration.defaultLayoutMode = .manual
        model.configuration.singleWindowPlacement = placesSingleWindow ? .maximize : nil
        let cycles = identity == "cold" ? 1 : 2
        for cycle in 1...cycles {
            model.setActiveMode(.manual)
            system.windows[0].frame = frames[0]
            system.windows[1].frame = frames[1]
            if cycle == 2, identity.hasPrefix("replacement") {
                let previous = system.windows[1]
                system.windows[1] = WindowSnapshot(id: WindowID(rawValue: "replacement"),
                    processIdentifier: identity == "replacementProcess" ? 44 : previous.processIdentifier,
                    bundleIdentifier: previous.bundleIdentifier, frame: frames[1], displayID: display.id)
                system.desktopObservation?.windowMembership.removeValue(forKey: previous.id)
                system.desktopObservation?.windowMembership[system.windows[1].id] = [space]
                system.eventHandler?(WindowSystemEvent(kind: .destroyed, windowID: previous.id,
                    processIdentifier: previous.processIdentifier))
            }
            let returning = system.windows[1]
            let writes = system.frameWriteCounts[returning.id, default: 0]
            system.unresponsiveProcessIDs = [returning.processIdentifier]
            model.setActiveMode(.bento)
            try #require(system.applicationHoldsUntil[returning.processIdentifier] != nil)
            #expect(system.windows[1].frame == frames[1])
            #expect(system.windows[0].frame == (placesSingleWindow ? display.visibleFrame : frames[0]))
            system.unresponsiveProcessIDs.removeAll()
            // No event, command, or refresh after return: only the scheduled recovery may act.
            let recovered = await waitFor(timeout: .milliseconds(600)) {
                system.applicationHoldsUntil[returning.processIdentifier] == nil
                    && system.frameWriteCounts[returning.id, default: 0] > writes
                    && system.windows[1].frame != frames[1]
                    && BentoLayoutVerifier.overlappingWindowIDs(
                        Dictionary(uniqueKeysWithValues: system.windows.map { ($0.id, $0.frame) })
                    ).isEmpty
            }
            #expect(recovered, "Cycle \(cycle) must place the current returning identity after single-window Repair")
            try #require(await waitFor { model.settlementTasks.isEmpty })
            let session = try #require(self.session(model, display: display.id))
            #expect(session.mode == .bento)
            #expect(!session.automaticWritesSuspended)
            #expect(session.bentoState.root?.windowIDs.contains(returning.id) == true)
            #expect(!session.bentoState.floatingWindowIDs.contains(returning.id))
            #expect(!session.automaticallyFloatingWindowIDs.contains(returning.id))
        }
    }

    private func session(_ model: BetterTileModel, display: DisplayID) -> LayoutSession? {
        let store = Mirror(reflecting: model).children.first {
            $0.label?.hasSuffix("sessionStore") == true
        }?.value as? LayoutSessionStore
        return store?.session(for: display)
    }
}
