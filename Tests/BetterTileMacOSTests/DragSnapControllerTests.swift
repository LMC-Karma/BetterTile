import Testing
@testable import BetterTileCore
@testable import BetterTileMacOS

@Test @MainActor func nsEventMouseDownRequiresTheButtonToStillBePressed() {
    #expect(!DragSnapController.acceptsMouseDown(from: .nsEvent, pressedMouseButtons: 0))
    #expect(DragSnapController.acceptsMouseDown(from: .nsEvent, pressedMouseButtons: 1))
    #expect(DragSnapController.acceptsMouseDown(from: .eventTap, pressedMouseButtons: 0))
}

@Test @MainActor func bentoDragAdmissionHonorsApplicationRules() {
    let system = FakeWindowSystem()
    let window = system.windows[0]
    let controller = DragSnapController(
        coordinator: WindowCoordinator(system: system),
        configuration: BetterTileConfiguration()
    )
    let bundleIdentifier = "com.example.Test"

    #expect(controller.allowsBentoDrag(for: window))

    var configuration = BetterTileConfiguration()
    configuration.applicationRules.set(.excludeFromBento, for: bundleIdentifier)
    controller.configuration = configuration
    #expect(!controller.allowsBentoDrag(for: window))

    configuration.applicationRules.set(.ignoreEverywhere, for: bundleIdentifier)
    controller.configuration = configuration
    #expect(!controller.allowsBentoDrag(for: window))

    controller.configuration = BetterTileConfiguration()
    var floatingWindow = window
    floatingWindow.isFloating = true
    #expect(!controller.allowsBentoDrag(for: floatingWindow))
}

@Test @MainActor func sharedGestureSourceIgnoresMouseUpWithoutAnActiveDrag() {
    let system = FakeWindowSystem()
    let controller = DragSnapController(
        coordinator: WindowCoordinator(system: system),
        configuration: BetterTileConfiguration()
    )
    var endedCount = 0
    controller.gestureEndedHandler = { endedCount += 1 }
    controller.setUsesSharedGestureEvents(true)

    controller.handleSharedGestureEvent(GlobalGestureEvent(
        kind: .leftMouseUp,
        position: BTPoint(x: 0, y: 0),
        button: 0,
        modifiers: [],
        timestamp: 1
    ))

    #expect(endedCount == 0)
}

@Test @MainActor func sharedGestureSequenceAppliesSnapPlacement() {
    let system = FakeWindowSystem()
    let controller = DragSnapController(
        coordinator: WindowCoordinator(system: system),
        configuration: BetterTileConfiguration()
    )
    controller.setUsesSharedGestureEvents(true)

    controller.handleSharedGestureEvent(GlobalGestureEvent(
        kind: .leftMouseDown,
        position: BTPoint(x: 300, y: 220),
        button: 0,
        modifiers: [],
        timestamp: 1
    ))

    system.windows[0].frame.origin.x += 3
    controller.handleSharedGestureEvent(GlobalGestureEvent(
        kind: .leftMouseDragged,
        position: BTPoint(x: 1, y: 400),
        button: 0,
        modifiers: [],
        timestamp: 2
    ))
    controller.handleSharedGestureEvent(GlobalGestureEvent(
        kind: .leftMouseUp,
        position: BTPoint(x: 1, y: 400),
        button: 0,
        modifiers: [],
        timestamp: 3
    ))

    #expect(system.windows[0].frame == BTRect(x: 0, y: 0, width: 500, height: 800))
}

@Test @MainActor func cancellingSharedGesturePreventsSnapPlacement() {
    let system = FakeWindowSystem()
    let controller = DragSnapController(
        coordinator: WindowCoordinator(system: system),
        configuration: BetterTileConfiguration()
    )
    controller.setUsesSharedGestureEvents(true)

    controller.handleSharedGestureEvent(GlobalGestureEvent(
        kind: .leftMouseDown,
        position: BTPoint(x: 300, y: 220),
        button: 0,
        modifiers: [],
        timestamp: 1
    ))
    system.windows[0].frame.origin.x += 3
    controller.handleSharedGestureEvent(GlobalGestureEvent(
        kind: .leftMouseDragged,
        position: BTPoint(x: 1, y: 400),
        button: 0,
        modifiers: [],
        timestamp: 2
    ))

    controller.cancel()
    controller.handleSharedGestureEvent(GlobalGestureEvent(
        kind: .leftMouseUp,
        position: BTPoint(x: 1, y: 400),
        button: 0,
        modifiers: [],
        timestamp: 3
    ))

    #expect(system.windows[0].frame == BTRect(x: 203, y: 200, width: 600, height: 400))
}

@Test @MainActor func failedTapHandsActiveSnapToNSEventWithoutDuplicatePlacement() {
    let system = FakeWindowSystem()
    let controller = DragSnapController(
        coordinator: WindowCoordinator(system: system),
        configuration: BetterTileConfiguration()
    )
    controller.setUsesSharedGestureEvents(true)

    func event(_ kind: GlobalGestureEventKind, timestamp: UInt64) -> GlobalGestureEvent {
        GlobalGestureEvent(
            kind: kind,
            position: kind == .leftMouseDown
                ? BTPoint(x: 300, y: 220)
                : BTPoint(x: 1, y: 400),
            button: 0,
            modifiers: [],
            timestamp: timestamp
        )
    }

    controller.handleSharedGestureEvent(event(.leftMouseDown, timestamp: 1))
    system.windows[0].frame.origin.x += 3
    controller.handleSharedGestureEvent(event(.leftMouseDragged, timestamp: 2))
    controller.setUsesSharedGestureEvents(false)
    controller.handleSharedGestureEvent(event(.leftMouseUp, timestamp: 3))
    controller.receive(event(.leftMouseUp, timestamp: 3), from: .nsEvent)

    #expect(system.windows[0].frame == BTRect(x: 0, y: 0, width: 500, height: 800))
    #expect(system.frameWriteCounts[WindowID(rawValue: "focused")] == 1)
}

@Test func bentoSwapSupportsTallerUnifiedToolbarsWithoutEnteringWindowContent() {
    let frame = BTRect(x: 100, y: 100, width: 500, height: 400)
    #expect(BentoSwapDragRegion.isTitleBarStart(BTPoint(x: 200, y: 112), in: frame))
    #expect(BentoSwapDragRegion.isTitleBarStart(BTPoint(x: 200, y: 170), in: frame))
    #expect(!BentoSwapDragRegion.isTitleBarStart(BTPoint(x: 200, y: 190), in: frame))
    #expect(!BentoSwapDragRegion.isTitleBarStart(BTPoint(x: 104, y: 112), in: frame))
    #expect(!BentoSwapDragRegion.isTitleBarStart(BTPoint(x: 596, y: 112), in: frame))
}

@Test func bentoDragResolvesTheWindowUnderThePointerWhenFocusIsStale() throws {
    let displayID = DisplayID(rawValue: "main")
    let staleFocus = WindowSnapshot(
        id: WindowID(rawValue: "stale"),
        processIdentifier: 1,
        frame: BTRect(x: 0, y: 100, width: 400, height: 400),
        displayID: displayID
    )
    let dragged = WindowSnapshot(
        id: WindowID(rawValue: "dragged"),
        processIdentifier: 2,
        frame: BTRect(x: 500, y: 100, width: 400, height: 400),
        displayID: displayID
    )

    let resolved = try #require(BentoDragWindowResolver.window(
        at: BTPoint(x: 650, y: 120),
        focusedWindow: staleFocus,
        visibleWindows: [staleFocus, dragged]
    ))
    #expect(resolved.id == dragged.id)
}

@Test func bentoDragPrefersTheFocusedWindowWhenTitleBarsOverlap() throws {
    let displayID = DisplayID(rawValue: "main")
    let focused = WindowSnapshot(
        id: WindowID(rawValue: "focused"),
        processIdentifier: 1,
        frame: BTRect(x: 100, y: 100, width: 500, height: 400),
        displayID: displayID
    )
    let behind = WindowSnapshot(
        id: WindowID(rawValue: "behind"),
        processIdentifier: 2,
        frame: BTRect(x: 150, y: 100, width: 400, height: 400),
        displayID: displayID
    )

    let resolved = try #require(BentoDragWindowResolver.window(
        at: BTPoint(x: 250, y: 120),
        focusedWindow: focused,
        visibleWindows: [behind, focused]
    ))
    #expect(resolved.id == focused.id)
}

@Test func windowDragGateRequiresTheOriginalCandidateToActuallyMove() {
    let displayID = DisplayID(rawValue: "main")
    let original = WindowSnapshot(
        id: WindowID(rawValue: "dragged"),
        processIdentifier: 1,
        frame: BTRect(x: 100, y: 100, width: 500, height: 400),
        displayID: displayID
    )
    let other = WindowSnapshot(
        id: WindowID(rawValue: "focused-later"),
        processIdentifier: 2,
        frame: original.frame.offsetBy(dx: 20, dy: 20),
        displayID: displayID
    )
    var gate = WindowDragGate()

    #expect(gate.activate(with: other) == nil)
    gate.begin(with: original)
    #expect(gate.activate(with: original) == nil)
    #expect(gate.activate(with: other) == nil)

    var resized = original
    resized.frame.size.width += 20
    #expect(gate.activate(with: resized) == nil)

    var jittered = original
    jittered.frame = original.frame.offsetBy(dx: 1, dy: 1)
    #expect(gate.activate(with: jittered) == nil)

    var moved = original
    moved.frame = original.frame.offsetBy(dx: 2, dy: 0)
    #expect(gate.activate(with: moved) == original.id)
    #expect(gate.activate(with: nil) == original.id)
}
