import AppKit
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
    controller.bentoStateProvider = { _ in BentoLayoutState(root: .leaf(window.id)) }

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

@Test @MainActor func singleWindowBentoDesktopWithoutATreeStillDragSnaps() {
    let system = FakeWindowSystem()
    let controller = DragSnapController(
        coordinator: WindowCoordinator(system: system),
        configuration: BetterTileConfiguration()
    )
    controller.activeModeProvider = { _ in .bento }
    controller.bentoStateProvider = { _ in BentoLayoutState() }
    var bentoStartAttempts = 0
    controller.bentoDragBeganHandler = { _, _, _ in
        bentoStartAttempts += 1
        // A new one-window desktop has no Bento tree to freeze.
        return false
    }
    controller.setUsesSharedGestureEvents(true)
    controller.handleSharedGestureEvent(GlobalGestureEvent(
        kind: .leftMouseDown, position: BTPoint(x: 300, y: 220),
        button: 0, modifiers: [], timestamp: 1
    ))
    system.windows[0].frame.origin.x += 3
    controller.handleSharedGestureEvent(GlobalGestureEvent(
        kind: .leftMouseDragged, position: BTPoint(x: 1, y: 400),
        button: 0, modifiers: [], timestamp: 2
    ))
    controller.handleSharedGestureEvent(GlobalGestureEvent(
        kind: .leftMouseUp, position: BTPoint(x: 1, y: 400),
        button: 0, modifiers: [], timestamp: 3
    ))
    #expect(system.windows[0].frame == BTRect(x: 0, y: 0, width: 500, height: 800))
    #expect(bentoStartAttempts == 0)
    #expect(!controller.isGestureActive)
}

@Test(arguments: [1.0, 500.0, 999.0], [false, true])
@MainActor func snapReleaseUsesItsFinalPositionAndSuppression(x: Double, suppressed: Bool) {
    let system = FakeWindowSystem()
    let controller = DragSnapController(coordinator: WindowCoordinator(system: system), configuration: BetterTileConfiguration())
    controller.setUsesSharedGestureEvents(true)
    func send(_ kind: GlobalGestureEventKind, x: Double, y: Double, modifiers: ShortcutModifiers = []) {
        controller.handleSharedGestureEvent(GlobalGestureEvent(kind: kind, position: BTPoint(x: x, y: y), button: 0, modifiers: modifiers, timestamp: 1))
    }
    send(.leftMouseDown, x: 300, y: 220)
    system.windows[0].frame.origin.x += 3
    let dragged = system.windows[0].frame
    send(.leftMouseDragged, x: 1, y: 400)
    send(.leftMouseUp, x: x, y: 400, modifiers: suppressed ? .option : [])
    if suppressed || x == 500 {
        #expect(system.windows[0].frame == dragged)
        #expect(system.frameWriteCounts.isEmpty)
    } else {
        #expect(system.windows[0].frame == BTRect(x: x == 1 ? 0 : 500, y: 0, width: 500, height: 800))
    }
}

@Test @MainActor func centerSnapPreservesTheDraggedWindowsSize() {
    let system = FakeWindowSystem()
    var configuration = BetterTileConfiguration()
    configuration.snapAreaBindings = [SnapAreaBinding(area: .left, action: .center)]
    let controller = DragSnapController(coordinator: WindowCoordinator(system: system), configuration: configuration)
    controller.setUsesSharedGestureEvents(true)
    controller.handleSharedGestureEvent(GlobalGestureEvent(kind: .leftMouseDown, position: BTPoint(x: 300, y: 220), button: 0, modifiers: [], timestamp: 1))
    system.windows[0].frame.origin.x += 3
    controller.handleSharedGestureEvent(GlobalGestureEvent(kind: .leftMouseDragged, position: BTPoint(x: 1, y: 400), button: 0, modifiers: [], timestamp: 2))
    controller.handleSharedGestureEvent(GlobalGestureEvent(kind: .leftMouseUp, position: BTPoint(x: 1, y: 400), button: 0, modifiers: [], timestamp: 3))
    #expect(system.windows[0].frame == BTRect(x: 200, y: 200, width: 600, height: 400))
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

@Test @MainActor func eventTapHandoffWaitsForTheActiveNSEventDrag() {
    let system = FakeWindowSystem()
    let controller = DragSnapController(
        coordinator: WindowCoordinator(system: system),
        configuration: BetterTileConfiguration()
    )
    let windowID = WindowID(rawValue: "focused")

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

    // The tap starts the drag, then fails, so NSEvent monitors take the gesture.
    controller.setUsesSharedGestureEvents(true)
    controller.handleSharedGestureEvent(event(.leftMouseDown, timestamp: 1))
    system.windows[0].frame.origin.x += 3
    controller.setUsesSharedGestureEvents(false)
    controller.receive(event(.leftMouseDragged, timestamp: 2), from: .nsEvent)
    #expect(controller.isGestureActive)

    // The tap becomes available again while that NSEvent drag is still running.
    controller.setUsesSharedGestureEvents(true)
    controller.handleSharedGestureEvent(event(.leftMouseDragged, timestamp: 3))
    controller.handleSharedGestureEvent(event(.leftMouseUp, timestamp: 4))
    #expect(controller.isGestureActive)
    #expect(system.windows[0].frame == BTRect(x: 203, y: 200, width: 600, height: 400))

    // The NSEvent up finishes the gesture exactly once.
    controller.receive(event(.leftMouseUp, timestamp: 5), from: .nsEvent)
    #expect(!controller.isGestureActive)
    #expect(system.windows[0].frame == BTRect(x: 0, y: 0, width: 500, height: 800))
    #expect(system.frameWriteCounts[windowID] == 1)

    // The deferred handoff applies, so the next gesture uses the event tap.
    system.windows[0].frame = BTRect(x: 200, y: 200, width: 600, height: 400)
    controller.handleSharedGestureEvent(event(.leftMouseDown, timestamp: 6))
    system.windows[0].frame.origin.x += 3
    controller.handleSharedGestureEvent(event(.leftMouseDragged, timestamp: 7))
    controller.handleSharedGestureEvent(event(.leftMouseUp, timestamp: 8))

    #expect(system.windows[0].frame == BTRect(x: 0, y: 0, width: 500, height: 800))
    #expect(system.frameWriteCounts[windowID] == 2)
}

@Test @MainActor func stoppingDuringADeferredHandoffDoesNotEnableTheEventTap() {
    let system = FakeWindowSystem()
    let controller = DragSnapController(
        coordinator: WindowCoordinator(system: system),
        configuration: BetterTileConfiguration()
    )

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

    controller.setUsesSharedGestureEvents(true)
    controller.handleSharedGestureEvent(event(.leftMouseDown, timestamp: 1))
    system.windows[0].frame.origin.x += 3
    controller.setUsesSharedGestureEvents(false)
    controller.receive(event(.leftMouseDragged, timestamp: 2), from: .nsEvent)
    controller.setUsesSharedGestureEvents(true)

    controller.stop()

    // The cleared handoff must not switch the source back to the event tap.
    controller.handleSharedGestureEvent(event(.leftMouseDown, timestamp: 3))
    #expect(!controller.isGestureActive)
    #expect(system.windows[0].frame == BTRect(x: 203, y: 200, width: 600, height: 400))
}

@Test @MainActor func dragSnapEvaluatesOnlyTheNewestSampleEachDisplayFrameAndFlushesRelease() {
    let system = FakeWindowSystem()
    let controller = DragSnapController(
        coordinator: WindowCoordinator(system: system),
        configuration: BetterTileConfiguration(),
        displayTicks: ResizeDisplayLink(automatic: false)
    )
    controller.setUsesSharedGestureEvents(true)
    func send(_ kind: GlobalGestureEventKind, x: Double) {
        controller.handleSharedGestureEvent(GlobalGestureEvent(kind: kind, position: BTPoint(x: x, y: 400), button: 0, modifiers: [], timestamp: 1))
    }
    controller.handleSharedGestureEvent(GlobalGestureEvent(kind: .leftMouseDown, position: BTPoint(x: 300, y: 220), button: 0, modifiers: [], timestamp: 1))
    system.windows[0].frame.origin.x += 3
    send(.leftMouseDragged, x: 400)
    // The first sample resolves the window immediately.
    #expect(controller.isGestureActive)
    #expect(!controller.hasPendingDragSample)
    send(.leftMouseDragged, x: 200)
    send(.leftMouseDragged, x: 1)
    #expect(controller.hasPendingDragSample)
    controller.displayTick()
    #expect(!controller.hasPendingDragSample)
    // Release applies its own position even when a sample is still queued.
    send(.leftMouseDragged, x: 500)
    send(.leftMouseUp, x: 1)
    #expect(system.windows[0].frame == BTRect(x: 0, y: 0, width: 500, height: 800))
    #expect(!controller.hasPendingDragSample)
}

@Test @MainActor func exposedDragStartsDisplayTicksBeforeConsumingQueuedSamples() {
    let system = FakeWindowSystem()
    let ticks = ResizeDisplayLink(automatic: false)
    let controller = DragSnapController(
        coordinator: WindowCoordinator(system: system),
        configuration: BetterTileConfiguration(), displayTicks: ticks
    )
    controller.setUsesSharedGestureEvents(true)
    // Both Dock and Stage Manager use this admission after resolving exposure.
    controller.beginExposedWindowDrag(with: system.windows[0])
    system.windows[0].frame.origin.x += 3
    controller.handleSharedGestureEvent(GlobalGestureEvent(
        kind: .leftMouseDragged, position: BTPoint(x: 1, y: 400),
        button: 0, modifiers: [], timestamp: 1
    ))
    #expect(controller.hasPendingDragSample)
    ticks.fire()
    #expect(!controller.hasPendingDragSample)
    #expect(system.frameWriteCounts.isEmpty)
    controller.handleSharedGestureEvent(GlobalGestureEvent(
        kind: .leftMouseUp, position: BTPoint(x: 1, y: 400),
        button: 0, modifiers: [], timestamp: 2
    ))
    #expect(system.windows[0].frame == BTRect(x: 0, y: 0, width: 500, height: 800))
    controller.cancel()
    ticks.fire()
    #expect(!controller.hasPendingDragSample)
}

@Test @MainActor func dragPacingFollowsTheDisplayUnderThePointer() {
    let system = FakeWindowSystem()
    let secondaryID = DisplayID(rawValue: "secondary")
    system.availableDisplays.append(DisplaySnapshot(
        id: secondaryID,
        frame: BTRect(x: 1000, y: 0, width: 1000, height: 800),
        visibleFrame: BTRect(x: 1000, y: 0, width: 1000, height: 800),
        isMain: false
    ))
    let ticks = ResizeDisplayLink(automatic: false)
    let controller = DragSnapController(
        coordinator: WindowCoordinator(system: system),
        configuration: BetterTileConfiguration(), displayTicks: ticks
    )
    controller.setUsesSharedGestureEvents(true)
    controller.beginExposedWindowDrag(with: system.windows[0])
    func drag(at x: Double) {
        controller.handleSharedGestureEvent(GlobalGestureEvent(
            kind: .leftMouseDragged, position: BTPoint(x: x, y: 400),
            button: 0, modifiers: [], timestamp: 1
        ))
    }
    drag(at: 1500)
    #expect(controller.pacingDisplayID == secondaryID)
    ticks.fire()
    #expect(!controller.hasPendingDragSample)
    drag(at: 1501)
    ticks.fire()
    #expect(!controller.hasPendingDragSample)
    drag(at: 500)
    #expect(controller.pacingDisplayID == system.availableDisplays[0].id)
    ticks.fire()
    #expect(!controller.hasPendingDragSample)
    controller.cancel()
    #expect(controller.pacingDisplayID == nil)
}

@Test(arguments: ["restart", "configuration", "replacement"]) @MainActor
func queuedDragEscapeCannotCancelAReplacementGesture(retirement: String) async throws {
    let system = FakeWindowSystem()
    let controller = DragSnapController(coordinator: WindowCoordinator(system: system),
                                        configuration: BetterTileConfiguration(), displayTicks: ResizeDisplayLink(automatic: false))
    var escape: ((NSEvent) -> Void)?
    controller.addGlobalMonitor = { mask, handler in
        if mask.contains(.keyDown) { escape = handler }
        return NSObject()
    }
    controller.removeEventMonitor = { _ in }
    controller.setUsesSharedGestureEvents(true)
    controller.start()
    defer { controller.stop() }
    let down = GlobalGestureEvent(kind: .leftMouseDown, position: BTPoint(x: 300, y: 220), button: 0, modifiers: [], timestamp: 1)
    controller.handleSharedGestureEvent(down)
    #expect(controller.isGestureActive)
    let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 1,
                                             windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 53))
    #expect(escape != nil)
    escape?(event)
    switch retirement {
    case "configuration":
        controller.configuration.snappingEnabled = false
        controller.configuration.snappingEnabled = true
    case "replacement": controller.cancel()
    default:
        controller.stop()
        controller.start()
    }
    controller.handleSharedGestureEvent(down)
    for _ in 0..<20 { await Task.yield() }
    #expect(controller.isGestureActive)
    #expect(escape != nil)
    escape?(event)
    for _ in 0..<20 { await Task.yield() }
    #expect(!controller.isGestureActive)
}

@Test @MainActor func retiredFallbackReleaseCannotEndANewDragAfterEventTapHandoff() async throws {
    let system = FakeWindowSystem()
    let controller = DragSnapController(coordinator: WindowCoordinator(system: system),
                                        configuration: BetterTileConfiguration(), displayTicks: ResizeDisplayLink(automatic: false))
    var release: ((NSEvent) -> Void)?
    controller.addGlobalMonitor = { mask, handler in
        if mask.contains(.leftMouseUp) { release = handler }
        return NSObject()
    }
    controller.removeEventMonitor = { _ in }
    controller.start()
    defer { controller.stop() }
    let down = GlobalGestureEvent(kind: .leftMouseDown, position: BTPoint(x: 300, y: 220), button: 0, modifiers: [], timestamp: 1)
    controller.setUsesSharedGestureEvents(true)
    controller.handleSharedGestureEvent(down)
    controller.setUsesSharedGestureEvents(false)
    #expect(controller.isGestureActive)
    let event = try #require(NSEvent.mouseEvent(with: .leftMouseUp, location: .zero, modifierFlags: [], timestamp: 2,
                                               windowNumber: 0, context: nil, eventNumber: 2, clickCount: 1, pressure: 0))
    #expect(release != nil)
    release?(event)
    controller.cancel()
    controller.setUsesSharedGestureEvents(true)
    controller.handleSharedGestureEvent(down)
    controller.setUsesSharedGestureEvents(false)
    for _ in 0..<20 { await Task.yield() }
    #expect(controller.isGestureActive)
    release?(event)
    for _ in 0..<20 { await Task.yield() }
    #expect(!controller.isGestureActive)
}

@Test(arguments: [false, true]) @MainActor
func tabbedSnapGestureUsesMouseDownFrameAndPlansItsFixedZonePreview(available: Bool) async throws {
    let system = FakeWindowSystem()
    system.addSecondWindow()
    let source = system.windows[0].id
    let initialFrame = system.windows[0].frame
    let controller = DragSnapController(coordinator: WindowCoordinator(system: system), configuration: BetterTileConfiguration())
    controller.activeModeProvider = { _ in .tabbed }
    let layout = BentoLayoutState(root: .partition(BentoPartition(axis: .vertical,
        children: [.leaf(source), .leaf(system.windows[1].id)])))
    controller.bentoStateProvider = { _ in layout }
    let previewFrame = BTRect(x: available ? 12000 : 14000, y: 34, width: 497, height: 766)
    let previousPanels = Set(NSApplication.shared.windows.map(\.windowNumber))
    var capturedFrame: BTRect?
    var previews: [BentoDragOutcome] = []
    var dropped: BentoDragOutcome?
    controller.bentoDragBeganHandler = { _, id, frame in
        #expect(id == source)
        capturedFrame = frame
        return true
    }
    controller.bentoPreviewHandler = { _, id, outcome in
        previews.append(outcome)
        return available ? [Placement(windowID: id, frame: previewFrame)] : nil
    }
    controller.bentoDragEndedHandler = { _, _, outcome in dropped = outcome }
    controller.setUsesSharedGestureEvents(true)
    controller.handleSharedGestureEvent(GlobalGestureEvent(kind: .leftMouseDown,
        position: BTPoint(x: initialFrame.minX + 100, y: initialFrame.minY + 20), button: 0, modifiers: [], timestamp: 1))
    system.windows[0].frame.origin.x += 30
    controller.handleSharedGestureEvent(GlobalGestureEvent(kind: .leftMouseDragged,
        position: BTPoint(x: 1, y: 400), button: 0, modifiers: [], timestamp: 2))
    let deadline = ContinuousClock.now.advanced(by: .seconds(1))
    while previews.isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    let mainFrame = try #require(NSScreen.screens.first?.frame)
    let expected = CoordinateConverter.toAppKit(previewFrame, mainScreenFrame: mainFrame)
        .insetBy(dx: BentoPreviewMetrics.motionPanelInset, dy: BentoPreviewMetrics.motionPanelInset)
    // Inspect only this test application's newly created preview panels.
    // The synthetic preview is off-screen; no foreign window/AX is involved.
    let shown = NSApplication.shared.windows.contains {
        !previousPanels.contains($0.windowNumber) && $0.isVisible
            && $0.contentView is PlacementWireframeView && $0.frame.equalTo(expected)
    }
    #expect(shown == available)
    controller.handleSharedGestureEvent(GlobalGestureEvent(kind: .leftMouseUp,
        position: BTPoint(x: 1, y: 400), button: 0, modifiers: [], timestamp: 3))
    #expect(capturedFrame == initialFrame)
    #expect(previews.contains { if case .snap(action: .leftHalf, frame: _) = $0 { true } else { false } })
    guard case .snap(action: .leftHalf, frame: _) = dropped else { Issue.record("Expected the same fixed-zone command on release"); return }
}

@Test @MainActor func tabbedSnapRepeatedTicksRetainPreviewPanelsAndClearTransitions() async throws {
    for (competingCenter, acceptsCenter) in [(false, false), (true, false), (true, true)] {
        try await checkSnapPreviewRetention(competingCenter: competingCenter, acceptsCenter: acceptsCenter)
    }
}

@MainActor private func checkSnapPreviewRetention(competingCenter: Bool, acceptsCenter: Bool) async throws {
    let system = FakeWindowSystem()
    system.availableDisplays[0].frame.origin.x = 12000
    system.availableDisplays[0].visibleFrame.origin.x = 12000
    system.windows[0].frame.origin.x += 12000
    for name in ["corner", "right"] {
        var window = system.windows[0]
        window.id = WindowID(rawValue: name)
        system.windows.append(window)
    }
    let source = system.windows[0].id, corner = system.windows[1].id, right = system.windows[2].id
    let layout = BentoLayoutState(root: .partition(BentoPartition(axis: .vertical, children: [
        .partition(BentoPartition(axis: .horizontal, children: [.leaf(corner), .leaf(source)], ratios: [0.1, 0.9])),
        .leaf(right)
    ], ratios: [0.1, 0.9])), metrics: BentoLayoutMetrics(paneGap: 0))
    var configuration = BetterTileConfiguration()
    configuration.bentoSwapHoverDelay = 1
    configuration.snapAreaBindings = [SnapAreaBinding(area: .left, action: .rightHalf),
        SnapAreaBinding(area: .topLeft, action: .rightHalf), SnapAreaBinding(area: .right, action: .leftHalf)]
    let ticks = ResizeDisplayLink(automatic: false)
    let controller = DragSnapController(coordinator: WindowCoordinator(system: system),
        configuration: configuration, displayTicks: ticks)
    defer { controller.cancel() }
    controller.activeModeProvider = { _ in .tabbed }
    controller.bentoStateProvider = { _ in layout }
    controller.bentoDragBeganHandler = { _, _, _ in true }
    var available = true
    var calls = 0
    var centerCalls = 0
    var centerEnteredAt: TimeInterval?
    controller.bentoPreviewHandler = { _, _, outcome in
        if case .swap = outcome {
            centerCalls += 1
            if let centerEnteredAt {
                #expect(ProcessInfo.processInfo.systemUptime - centerEnteredAt >= configuration.bentoSwapHoverDelay - 0.01)
            }
            return acceptsCenter ? [Placement(windowID: source, frame: BTRect(x: 12000, y: 0, width: 100, height: 80))] : nil
        }
        guard available, case let .snap(action, _) = outcome else { return nil }
        calls += 1
        let x = action == .rightHalf ? 12500.0 : 12000.0
        return [Placement(windowID: source, frame: BTRect(x: x, y: 34, width: 500, height: 766)),
                Placement(windowID: corner, frame: BTRect(x: 12300, y: 34, width: 200, height: 300)),
                Placement(windowID: right, frame: BTRect(x: 12300, y: 400, width: 200, height: 300))]
    }
    controller.setUsesSharedGestureEvents(true)
    let owner = NSUserInterfaceItemIdentifier(UUID().uuidString)
    func panels() -> [NSWindow] {
        NSApplication.shared.windows.filter {
            $0.identifier == owner && $0.isVisible && $0.contentView is PlacementWireframeView
        }
    }
    func send(_ kind: GlobalGestureEventKind, _ point: BTPoint) {
        let previous = Set(NSApplication.shared.windows.map(ObjectIdentifier.init))
        controller.handleSharedGestureEvent(GlobalGestureEvent(kind: kind, position: point,
            button: 0, modifiers: [], timestamp: 1))
        ticks.fire()
        for panel in NSApplication.shared.windows where !previous.contains(ObjectIdentifier(panel))
                && panel.contentView is PlacementWireframeView { panel.identifier = owner }
    }
    send(.leftMouseDown, BTPoint(x: 12300, y: 220))
    system.windows[0].frame.origin.x += 30
    let point = competingCenter ? BTPoint(x: 12050, y: 40) : BTPoint(x: 12001, y: 400)
    if competingCenter {
        let cornerFrame = try #require(layout.placements(in: system.availableDisplays[0].visibleFrame).first { $0.windowID == corner }?.frame)
        #expect(cornerFrame.contains(point))
        #expect(BentoPaneDropPosition.resolve(point, in: cornerFrame) == .center)
    }
    send(.leftMouseDragged, point)
    let first = panels()
    #expect(first.count == 3)
    let identities = Set(first.map(ObjectIdentifier.init))
    for _ in 0..<5 { send(.leftMouseDragged, point) }
    #expect(calls == 6)
    #expect(Set(panels().map(ObjectIdentifier.init)) == identities)
    // Changed target keeps the owned panels; invalid/exit/cancel must hide them.
    configuration.snapAreaBindings = [SnapAreaBinding(area: .left, action: .leftHalf),
        SnapAreaBinding(area: .topLeft, action: .leftHalf)]
    controller.configuration = configuration
    send(.leftMouseDragged, point)
    #expect(Set(panels().map(ObjectIdentifier.init)) == identities)
    available = false
    send(.leftMouseDragged, point)
    #expect(panels().isEmpty)
    available = true
    send(.leftMouseDragged, point)
    #expect(panels().count == 3)
    send(.leftMouseDragged, BTPoint(x: 13001, y: 400))
    #expect(panels().isEmpty)
    centerEnteredAt = ProcessInfo.processInfo.systemUptime
    send(.leftMouseDragged, point)
    #expect(panels().count == 3)
    if competingCenter {
        let waitingPanels = Set(panels().map(ObjectIdentifier.init))
        // Pass the cue-arm delay while the configured center-hover delay is
        // still pending. The fixed-zone preview must retain ownership.
        try await Task.sleep(for: .milliseconds(180))
        send(.leftMouseDragged, point)
        if ProcessInfo.processInfo.systemUptime - (centerEnteredAt ?? 0) < configuration.bentoSwapHoverDelay {
            #expect(centerCalls == 0)
            #expect(Set(panels().map(ObjectIdentifier.init)) == waitingPanels)
        } else {
            // A busy main actor can resume this task after the full hover
            // delay. The callback above still verifies it never arms early.
            #expect(panels().isEmpty)
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while centerCalls == 0, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(centerCalls == 1)
        #expect(panels().isEmpty)
        var dropped: BentoDragOutcome?
        controller.bentoDragEndedHandler = { _, _, outcome in dropped = outcome }
        send(.leftMouseUp, point)
        guard case .swap(targetWindowID: corner) = dropped else { Issue.record("Center hover must win after its delay"); return }
    }
    controller.cancel()
    #expect(panels().isEmpty)
    #expect(system.frameWriteCounts.isEmpty)
}

@Test(arguments: ["member", "member-no-zone", "becomes-member", "float"]) @MainActor
func excludedTabbedMembersNeverUseRawNativeSnapping(membership: String) {
    let system = FakeWindowSystem()
    var configuration = BetterTileConfiguration()
    configuration.applicationRules.set(.excludeFromBento, for: "com.example.Test")
    let controller = DragSnapController(coordinator: WindowCoordinator(system: system), configuration: configuration,
                                        displayTicks: ResizeDisplayLink(automatic: false))
    defer { controller.cancel() }
    var isMember = membership.hasPrefix("member")
    controller.isTabbedMember = { _ in isMember }
    controller.activeModeProvider = { _ in .tabbed }
    controller.bentoStateProvider = { _ in BentoLayoutState(root: .leaf(system.windows[0].id)) }
    controller.setUsesSharedGestureEvents(true)
    var resultCount = 0
    controller.actionResultHandler = { _, _, _ in resultCount += 1 }
    let existing = Set(NSApplication.shared.windows.map(ObjectIdentifier.init))
    func send(_ kind: GlobalGestureEventKind, _ point: BTPoint) {
        controller.handleSharedGestureEvent(GlobalGestureEvent(kind: kind, position: point,
            button: 0, modifiers: [], timestamp: 1))
        controller.displayTick()
    }
    send(.leftMouseDown, BTPoint(x: 300, y: 220))
    system.windows[0].frame.origin.x += 3
    let draggedFrame = system.windows[0].frame
    let point = BTPoint(x: membership == "member-no-zone" ? 500 : 1, y: 400)
    send(.leftMouseDragged, point)
    if isMember {
        #expect(!NSApplication.shared.windows.contains {
            !existing.contains(ObjectIdentifier($0)) && $0.isVisible && $0.contentView is PlacementWireframeView
        })
    }
    if membership == "becomes-member" { isMember = true }
    send(.leftMouseUp, point)
    if membership == "float" {
        #expect(system.windows[0].frame == BTRect(x: 0, y: 0, width: 500, height: 800))
    } else {
        #expect(system.windows[0].frame == draggedFrame)
        #expect(system.frameWriteCounts.isEmpty)
        #expect(resultCount == 0)
    }
}
