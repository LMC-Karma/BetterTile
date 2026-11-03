import AppKit
import BetterTileCore
import Foundation
import Testing
@testable import BetterTileMacOS
@testable import BetterTileApp

/// Uses the native adapter's capture and deferred validation with a fake window system.
@MainActor final class CapturedFrameDelivery {
    private var identities = WindowIdentityRegistry()
    private var lifetime = WindowObservationLifetime()
    private var applications: Set<Int32> = []
    private var nextHash: UInt = 100
    private weak var system: FakeAppWindowSystem?
    var onDelivery: ((WindowSystemEvent) -> Void)?
    private(set) var delivered: [WindowID] = []

    init(system: FakeAppWindowSystem) {
        self.system = system
        for index in system.windows.indices { register(&system.windows[index]) }
    }

    func register(_ window: inout WindowSnapshot) {
        let application = ApplicationLaunchInstance(processIdentifier: window.processIdentifier, generation: 1)
        if applications.insert(window.processIdentifier).inserted { lifetime.install(application) }
        nextHash += 1
        window.id = identities.resolve(application: application, accessibilityHash: nextHash,
                                       exactWindowID: UInt32(nextHash))
    }

    @discardableResult
    func send(_ kind: WindowSystemEvent.Kind, for id: WindowID) -> Task<Void, Never>? {
        guard let record = identities.records[id], let hash = record.accessibilityHashes.first,
              let captured = lifetime.capture(kind: kind, application: record.application,
                  accessibilityHash: hash, identities: identities) else { return nil }
        return Task { @MainActor [self] in
            guard let event = lifetime.event(for: captured, identities: identities) else { return }
            delivered.append(id)
            system?.eventHandler?(event)
            onDelivery?(event)
        }
    }
}

@MainActor func pendingCapturedFrameIDs(_ model: BetterTileModel) -> Set<WindowID> {
    let buffer = Mirror(reflecting: model).children.first { $0.label?.hasSuffix("pendingWindowEvents") == true }?.value as? WindowEventBuffer
    return buffer?.frameEventWindowIDs ?? []
}

@MainActor @Suite(.appTestApplication, .serialized) struct CapturedFrameConsumerTests {
    @Test func aKnownManualWindowKeepsFrameEvidenceAndCanJoinAdaptiveMidStream() async throws {
        _ = NSApplication.shared
        let system = FakeAppWindowSystem()
        let delivery = CapturedFrameDelivery(system: system)
        let id = system.windows[0].id
        let model = makeModel(system: system)
        defer { model.shutdown() }
        model.configuration.singleWindowPlacement = nil
        model.setActiveMode(.manual)
        var recordedAtDelivery: [Set<WindowID>] = []
        var scheduledAtDelivery = false
        delivery.onDelivery = { _ in
            recordedAtDelivery.append(pendingCapturedFrameIDs(model))
            scheduledAtDelivery = model.windowEventTask != nil
        }
        system.windows[0].frame.origin.x += 30
        await delivery.send(.moved, for: id)?.value
        #expect(recordedAtDelivery.last?.contains(id) == true)
        #expect(scheduledAtDelivery)
        await model.windowEventTask?.value
        model.setActiveMode(.bento)
        await delivery.send(.resized, for: id)?.value
        #expect(recordedAtDelivery.last?.contains(id) == true)
        await model.windowEventTask?.value
        #expect(model.activeMode(for: system.mainDisplay.id) == .bento)
        #expect(delivery.delivered == [id, id])
    }

    @Test func aForeignMoveHidesTheDividerBeforeTheTrailingSweep() async throws {
        _ = NSApplication.shared
        let system = FakeAppWindowSystem()
        var peer = system.windows[0]
        peer.id = .init(rawValue: "peer")
        peer.processIdentifier = 43
        system.windows.append(peer)
        let delivery = CapturedFrameDelivery(system: system)
        let model = makeModel(system: system)
        defer { model.shutdown() }
        model.configuration.singleWindowPlacement = nil
        model.setActiveMode(.bento)
        try #require(await waitFor { model.settlementTasks.isEmpty })
        let divider = try #require(Mirror(reflecting: model).children.first {
            $0.label?.hasSuffix("dividerResize") == true
        }?.value as? DividerOverlayController)
        try #require(!divider.currentBoundaries.isEmpty)
        var foreign = WindowSnapshot(id: .init(rawValue: "foreign"), processIdentifier: 44,
            frame: .init(x: 20, y: 20, width: 150, height: 100), displayID: system.mainDisplay.id)
        foreign.isFloating = true
        delivery.register(&foreign)
        system.windows.append(foreign)
        var hidAtDelivery = false
        var bufferedAtDelivery = false
        delivery.onDelivery = { _ in
            hidAtDelivery = divider.currentBoundaries.isEmpty
            bufferedAtDelivery = pendingCapturedFrameIDs(model).contains(foreign.id)
        }
        await delivery.send(.moved, for: foreign.id)?.value
        #expect(hidAtDelivery)
        #expect(bufferedAtDelivery)
    }

    @Test func recoveryKeepsTheCapturedFrameIdentityWhileTheApplicationIsHeld() async throws {
        _ = NSApplication.shared
        let system = FakeAppWindowSystem()
        system.applicationHoldDuration = 60
        var held = system.windows[0]
        held.processIdentifier = 43
        system.windows.append(held)
        let delivery = CapturedFrameDelivery(system: system)
        let id = system.windows[1].id
        system.unresponsiveProcessIDs = [43]
        let model = makeModel(system: system)
        defer { model.shutdown() }
        model.setActiveMode(.bento)
        var retainedAtDelivery = false
        delivery.onDelivery = { _ in
            let recovery = Mirror(reflecting: model).children.first {
                $0.label?.hasSuffix("applicationRecoveryFrameEventPIDs") == true
            }?.value as? [WindowID: Int32]
            retainedAtDelivery = recovery?[id] == 43
        }
        await delivery.send(.resized, for: id)?.value
        #expect(retainedAtDelivery)
        await model.windowEventTask?.value
        #expect(system.frameWriteCounts[id] == nil)
    }

    @Test func manualDragSnapRetainsKnownUnmanagedFrameEventsUntilRelease() async throws {
        _ = NSApplication.shared
        let system = FakeAppWindowSystem()
        let bounds = BTRect(x: -30000, y: -30000, width: 1000, height: 800)
        system.availableDisplays = [.init(id: system.mainDisplay.id, frame: bounds, visibleFrame: bounds, isMain: true)]
        system.windows[0].frame.origin.x += bounds.minX
        system.windows[0].frame.origin.y += bounds.minY
        let delivery = CapturedFrameDelivery(system: system)
        let id = system.windows[0].id
        let model = makeModel(system: system)
        defer { model.shutdown() }
        model.configuration.singleWindowPlacement = nil
        model.setActiveMode(.manual)
        let drag = try #require(Mirror(reflecting: model).children.first {
            $0.label?.hasSuffix("dragSnap") == true
        }?.value as? DragSnapController)
        drag.setUsesSharedGestureEvents(true)
        drag.beginExposedWindowDrag(with: system.windows[0])
        system.windows[0].frame.origin.x += 5
        var retainedDuringDrag = false
        delivery.onDelivery = { _ in
            retainedDuringDrag = drag.isGestureActive && pendingCapturedFrameIDs(model).contains(id)
        }
        await delivery.send(.moved, for: id)?.value
        #expect(retainedDuringDrag)
        drag.handleSharedGestureEvent(.init(kind: .leftMouseDragged, position: .init(x: bounds.minX + 1, y: bounds.midY),
            button: 0, modifiers: [], timestamp: 1))
        drag.displayTick()
        drag.handleSharedGestureEvent(.init(kind: .leftMouseUp, position: .init(x: bounds.minX + 1, y: bounds.midY),
            button: 0, modifiers: [], timestamp: 2))
        await model.windowEventTask?.value
        #expect(!drag.isGestureActive)
        #expect(system.windows[0].frame == BTRect(x: bounds.minX, y: bounds.minY, width: 500, height: 800))
    }

}
