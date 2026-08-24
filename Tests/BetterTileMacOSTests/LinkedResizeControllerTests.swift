import Testing
@testable import BetterTileCore
@testable import BetterTileMacOS

@Test @MainActor func linkedResizeAdmissionHonorsApplicationRules() {
    let system = FakeWindowSystem()
    let window = system.windows[0]
    var configuration = BetterTileConfiguration()
    configuration.linkedResizeEnabled = true
    let controller = LinkedResizeController(
        coordinator: WindowCoordinator(system: system),
        configuration: configuration
    )
    controller.isEnabledForDisplay = { _ in true }

    #expect(controller.allowsLinkedResize(for: window))

    configuration.applicationRules.set(.excludeFromBento, for: "com.example.Test")
    controller.configuration = configuration
    #expect(controller.allowsLinkedResize(for: window))

    configuration.applicationRules.set(.ignoreEverywhere, for: "com.example.Test")
    controller.configuration = configuration
    #expect(!controller.allowsLinkedResize(for: window))
}

@Test @MainActor func sharedGestureBurstStartsLinkedResizeBeforeMouseUp() async {
    let system = FakeWindowSystem()
    system.windows = [
        WindowSnapshot(
            id: WindowID(rawValue: "focused"),
            processIdentifier: 42,
            frame: BTRect(x: 0, y: 0, width: 500, height: 800),
            displayID: DisplayID(rawValue: "main")
        ),
        WindowSnapshot(
            id: WindowID(rawValue: "second"),
            processIdentifier: 43,
            frame: BTRect(x: 500, y: 0, width: 500, height: 800),
            displayID: DisplayID(rawValue: "main")
        ),
    ]
    system.focusedWindowID = WindowID(rawValue: "focused")
    var configuration = BetterTileConfiguration()
    configuration.linkedResizeEnabled = true
    let controller = LinkedResizeController(
        coordinator: WindowCoordinator(system: system),
        configuration: configuration
    )
    controller.isEnabledForDisplay = { _ in true }
    controller.setUsesSharedGestureEvents(true)

    func event(_ kind: GlobalGestureEventKind, timestamp: UInt64) -> GlobalGestureEvent {
        GlobalGestureEvent(
            kind: kind,
            position: BTPoint(x: 500, y: 400),
            button: 0,
            modifiers: [],
            timestamp: timestamp
        )
    }

    controller.handleSharedGestureEvent(event(.leftMouseDown, timestamp: 1))
    system.windows[0].frame.size.width = 503
    controller.handleSharedGestureEvent(event(.leftMouseDragged, timestamp: 2))
    system.windows[0].frame.size.width = 520
    controller.handleSharedGestureEvent(event(.leftMouseDragged, timestamp: 3))
    controller.handleSharedGestureEvent(event(.leftMouseUp, timestamp: 4))
    await Task.yield()

    #expect(system.windows[1].frame.minX > 500)
}

@Test @MainActor func failedTapHandsActiveLinkedResizeToNSEvent() async {
    let system = FakeWindowSystem()
    system.windows = [
        WindowSnapshot(
            id: WindowID(rawValue: "focused"),
            processIdentifier: 42,
            frame: BTRect(x: 0, y: 0, width: 500, height: 800),
            displayID: DisplayID(rawValue: "main")
        ),
        WindowSnapshot(
            id: WindowID(rawValue: "second"),
            processIdentifier: 43,
            frame: BTRect(x: 500, y: 0, width: 500, height: 800),
            displayID: DisplayID(rawValue: "main")
        ),
    ]
    system.focusedWindowID = WindowID(rawValue: "focused")
    var configuration = BetterTileConfiguration()
    configuration.linkedResizeEnabled = true
    let controller = LinkedResizeController(
        coordinator: WindowCoordinator(system: system),
        configuration: configuration
    )
    controller.isEnabledForDisplay = { _ in true }
    controller.setUsesSharedGestureEvents(true)

    func event(_ kind: GlobalGestureEventKind, timestamp: UInt64) -> GlobalGestureEvent {
        GlobalGestureEvent(
            kind: kind,
            position: BTPoint(x: 500, y: 400),
            button: 0,
            modifiers: [],
            timestamp: timestamp
        )
    }

    controller.handleSharedGestureEvent(event(.leftMouseDown, timestamp: 1))
    controller.setUsesSharedGestureEvents(false)
    system.windows[0].frame.size.width = 510
    controller.receive(event(.leftMouseDragged, timestamp: 2), from: .nsEvent)
    controller.receive(event(.leftMouseUp, timestamp: 3), from: .nsEvent)
    await Task.yield()

    #expect(system.windows[1].frame.minX == 510)
}
