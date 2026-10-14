import AppKit
import Testing
@testable import BetterTileCore
@testable import BetterTileMacOS

/// A plan the fake model prepared for an overlay.
private func prepared(_ outcome: BentoDragOutcome, _ placements: [Placement]) -> LayoutDropPreview {
    .ready(PreparedLayoutDrop(outcome: outcome, placements: placements, plan: .frame, dragID: UUID()))
}

/// The outcome of a committed end, or nil.
private func committedOutcome(_ end: LayoutDragEnd?) -> BentoDragOutcome? {
    if case let .commit(plan) = end { return plan.outcome }
    return nil
}

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

/// The overlay is the only decision. The release position cannot choose a
/// new target, but a suppression modifier held at release still cancels.
@Test(arguments: [1.0, 500.0, 999.0], [false, true])
@MainActor func snapReleaseCommitsTheShownDropUnlessSuppressed(x: Double, suppressed: Bool) {
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
    if suppressed {
        #expect(system.windows[0].frame == dragged)
        #expect(system.frameWriteCounts.isEmpty)
    } else {
        #expect(system.windows[0].frame == BTRect(x: 0, y: 0, width: 500, height: 800))
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
    // Release commits the shown drop. A queued sample the overlay never
    // showed does not change it.
    send(.leftMouseDragged, x: 500)
    send(.leftMouseUp, x: 500)
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
    var dropped: LayoutDragEnd?
    controller.bentoDragBeganHandler = { _, id, frame in
        #expect(id == source)
        capturedFrame = frame
        return true
    }
    controller.bentoPreviewHandler = { _, id, outcome in
        previews.append(outcome)
        return available ? prepared(outcome, [Placement(windowID: id, frame: previewFrame)])
            : .invalid(reason: "No plan")
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
    // An unavailable plan is invalid feedback: release applies nothing and
    // reports why.
    guard available else {
        #expect(dropped == .failed(reason: "No plan"))
        return
    }
    guard case .snap(action: .leftHalf, frame: _) = committedOutcome(dropped) else {
        Issue.record("Expected the same fixed-zone command on release"); return
    }
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
            return acceptsCenter ? prepared(outcome, [Placement(windowID: source, frame: BTRect(x: 12000, y: 0, width: 100, height: 80))])
                : .invalid(reason: "No swap")
        }
        guard available, case let .snap(action, _) = outcome else { return .invalid(reason: "No snap") }
        calls += 1
        let x = action == .rightHalf ? 12500.0 : 12000.0
        return prepared(outcome, [Placement(windowID: source, frame: BTRect(x: x, y: 34, width: 500, height: 766)),
                Placement(windowID: corner, frame: BTRect(x: 12300, y: 34, width: 200, height: 300)),
                Placement(windowID: right, frame: BTRect(x: 12300, y: 400, width: 200, height: 300))])
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
    // An unavailable plan keeps only the snap area's frame, as invalid
    // feedback, and records no committable drop.
    available = false
    send(.leftMouseDragged, point)
    #expect(panels().count == 1)
    #expect(panels().allSatisfy { ($0.contentView as? PlacementWireframeView)?.isInvalid == true })
    if case .layout = controller.dropTarget?.drop { Issue.record("Invalid feedback must not be committable") }
    available = true
    send(.leftMouseDragged, point)
    #expect(panels().count == 3)
    #expect(panels().allSatisfy { ($0.contentView as? PlacementWireframeView)?.isInvalid == false })
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
        var dropped: LayoutDragEnd?
        controller.bentoDragEndedHandler = { _, _, end in dropped = end }
        send(.leftMouseUp, point)
        guard acceptsCenter else {
            // The invalid swap cue is not a drop.
            #expect(dropped == .failed(reason: "No swap"))
            return
        }
        guard case .swap(targetWindowID: corner) = committedOutcome(dropped) else {
            Issue.record("Center hover must win after its delay"); return
        }
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

/// Live: a click on a browser's toolbar in a Tabbed pane with hidden tabs
/// started a drag at release. The drag tore the tab from its group, and the
/// release placed the group again, activating the window and closing the
/// popup the click opened. A click without drag samples starts no drag.
@Test @MainActor func aClickWithoutDragSamplesStartsNoTabbedDrag() {
    let system = FakeWindowSystem()
    let controller = DragSnapController(coordinator: WindowCoordinator(system: system), configuration: BetterTileConfiguration())
    controller.activeModeProvider = { _ in .tabbed }
    controller.bentoStateProvider = { _ in BentoLayoutState(root: .leaf(system.windows[0].id)) }
    controller.isTabbedMember = { _ in true }
    var began = 0
    var ended = 0
    controller.bentoDragBeganHandler = { _, _, _ in began += 1; return true }
    controller.bentoDragEndedHandler = { _, _, _ in ended += 1 }
    controller.setUsesSharedGestureEvents(true)
    let frame = system.windows[0].frame
    controller.handleSharedGestureEvent(GlobalGestureEvent(
        kind: .leftMouseDown, position: BTPoint(x: 300, y: 220), button: 0, modifiers: [], timestamp: 1))
    #expect(controller.isGestureActive)
    controller.handleSharedGestureEvent(GlobalGestureEvent(
        kind: .leftMouseUp, position: BTPoint(x: 300, y: 220), button: 0, modifiers: [], timestamp: 2))
    #expect(began == 0)
    #expect(ended == 0)
    #expect(!controller.isGestureActive)
    #expect(system.windows[0].frame == frame)
}

/// Drag samples suppressed by the snap modifiers still make a drag. When
/// the modifiers are released before the button, the release snaps.
@Test @MainActor func aReleaseAfterSuppressedDragSamplesStillSnaps() {
    let system = FakeWindowSystem()
    let controller = DragSnapController(coordinator: WindowCoordinator(system: system), configuration: BetterTileConfiguration())
    controller.setUsesSharedGestureEvents(true)
    func send(_ kind: GlobalGestureEventKind, x: Double, y: Double, modifiers: ShortcutModifiers = []) {
        controller.handleSharedGestureEvent(GlobalGestureEvent(kind: kind, position: BTPoint(x: x, y: y), button: 0, modifiers: modifiers, timestamp: 1))
    }
    send(.leftMouseDown, x: 300, y: 220)
    system.windows[0].frame.origin.x += 3
    send(.leftMouseDragged, x: 1, y: 400, modifiers: .option)
    send(.leftMouseUp, x: 1, y: 400)
    #expect(system.windows[0].frame == BTRect(x: 0, y: 0, width: 500, height: 800))
}

// MARK: - Drops at a shared display edge

/// Displays A (x 0-1000) and B (x 1000-2000) side by side.
@MainActor private func sideBySideDisplays() -> (FakeWindowSystem, DisplayID, DisplayID) {
    let system = FakeWindowSystem()
    let second = DisplayID(rawValue: "second")
    system.availableDisplays.append(DisplaySnapshot(
        id: second,
        frame: BTRect(x: 1000, y: 0, width: 1000, height: 800),
        visibleFrame: BTRect(x: 1000, y: 0, width: 1000, height: 800)
    ))
    return (system, system.availableDisplays[0].id, second)
}

@MainActor private func send(
    _ controller: DragSnapController, _ kind: GlobalGestureEventKind, x: Double, y: Double = 400,
    modifiers: ShortcutModifiers = []
) {
    controller.handleSharedGestureEvent(GlobalGestureEvent(
        kind: kind, position: BTPoint(x: x, y: y), button: 0, modifiers: modifiers, timestamp: 1
    ))
}

/// The window's center has crossed to B while the pointer shows A's right
/// half. The drop is A's right half, wherever the button comes up, and the
/// coordinator checks it on A, not on the display of the window's center.
@Test(arguments: [998.0, 1001.0, 1000.0]) @MainActor
func dropAtASharedEdgeCommitsTheSnapAreaUnderThePointer(releaseX: Double) throws {
    let (system, first, second) = sideBySideDisplays()
    let controller = DragSnapController(coordinator: WindowCoordinator(system: system),
                                        configuration: BetterTileConfiguration())
    var results: [(DisplayID, Bool, String?)] = []
    controller.actionResultHandler = { results.append(($0, $1, $2)) }
    controller.setUsesSharedGestureEvents(true)
    send(controller, .leftMouseDown, x: 300, y: 220)
    // macOS moved the window with the pointer: its center is now on B.
    system.windows[0].frame.origin.x = 750
    system.windows[0].displayID = second
    send(controller, .leftMouseDragged, x: 998)
    let shown = try #require(controller.dropTarget)
    #expect(shown.displayID == first)
    #expect(shown.drop == .snap(SnapTarget(action: .rightHalf, frame: BTRect(x: 500, y: 0, width: 500, height: 800))))
    send(controller, .leftMouseUp, x: releaseX)
    #expect(system.windows[0].frame == BTRect(x: 500, y: 0, width: 500, height: 800))
    #expect(system.windows[0].displayID == first)
    #expect(results.count == 1)
    #expect(results.first?.0 == first && results.first?.1 == true)
}

@Test @MainActor func pointerOnASharedEdgeBelongsToExactlyOneDisplay() throws {
    let (system, first, second) = sideBySideDisplays()
    let displays = system.availableDisplays
    #expect(PointerDisplay.display(at: BTPoint(x: 1000, y: 400), in: displays)?.id == second)
    #expect(PointerDisplay.display(at: BTPoint(x: 999.5, y: 400), in: displays)?.id == first)
    // Outer edges still belong to the display they touch.
    #expect(PointerDisplay.display(at: BTPoint(x: 0, y: 0), in: displays)?.id == first)
    #expect(PointerDisplay.display(at: BTPoint(x: 2000, y: 800), in: displays)?.id == second)
    #expect(PointerDisplay.display(at: BTPoint(x: 2001, y: 400), in: displays) == nil)

    let stacked = [
        DisplaySnapshot(id: first, frame: BTRect(x: 0, y: 0, width: 1000, height: 800),
                        visibleFrame: BTRect(x: 0, y: 0, width: 1000, height: 800)),
        DisplaySnapshot(id: second, frame: BTRect(x: 0, y: 800, width: 1000, height: 800),
                        visibleFrame: BTRect(x: 0, y: 800, width: 1000, height: 800)),
    ]
    #expect(PointerDisplay.display(at: BTPoint(x: 500, y: 800), in: stacked)?.id == second)
    #expect(PointerDisplay.display(at: BTPoint(x: 500, y: 799.5), in: stacked)?.id == first)
}

@Test @MainActor func dropAtAStackedEdgeCommitsTheUpperDisplaysBottomHalf() throws {
    let system = FakeWindowSystem()
    let first = system.availableDisplays[0].id
    let lower = DisplayID(rawValue: "lower")
    system.availableDisplays.append(DisplaySnapshot(
        id: lower,
        frame: BTRect(x: 0, y: 800, width: 1000, height: 800),
        visibleFrame: BTRect(x: 0, y: 800, width: 1000, height: 800)
    ))
    var configuration = BetterTileConfiguration()
    configuration.snapAreaBindings = [SnapAreaBinding(area: .bottom, action: .bottomHalf)]
    let controller = DragSnapController(coordinator: WindowCoordinator(system: system), configuration: configuration)
    controller.setUsesSharedGestureEvents(true)
    send(controller, .leftMouseDown, x: 300, y: 220)
    system.windows[0].frame.origin.y = 700
    system.windows[0].displayID = lower
    send(controller, .leftMouseDragged, x: 500, y: 798)
    #expect(controller.dropTarget?.displayID == first)
    send(controller, .leftMouseUp, x: 500, y: 801)
    #expect(system.windows[0].frame == BTRect(x: 0, y: 400, width: 1000, height: 400))
    #expect(system.windows[0].displayID == first)
}

/// A flick shows no drop before the button comes up, so the release point is
/// evaluated once. A drag that showed a drop and then left it drops nothing.
@Test(arguments: [false, true]) @MainActor
func releaseEvaluatesThePointOnlyWhenNoDropWasShown(showedEarlier: Bool) {
    let system = FakeWindowSystem()
    let controller = DragSnapController(coordinator: WindowCoordinator(system: system),
                                        configuration: BetterTileConfiguration(),
                                        displayTicks: ResizeDisplayLink(automatic: false))
    controller.setUsesSharedGestureEvents(true)
    send(controller, .leftMouseDown, x: 300, y: 220)
    system.windows[0].frame.origin.x += 3
    let dragged = system.windows[0].frame
    send(controller, .leftMouseDragged, x: showedEarlier ? 1 : 500)
    if showedEarlier {
        #expect(controller.dropTarget != nil)
        send(controller, .leftMouseDragged, x: 500)
        controller.displayTick()
    }
    #expect(controller.dropTarget == nil)
    send(controller, .leftMouseUp, x: 1)
    if showedEarlier {
        #expect(system.windows[0].frame == dragged)
        #expect(system.frameWriteCounts.isEmpty)
    } else {
        #expect(system.windows[0].frame == BTRect(x: 0, y: 0, width: 500, height: 800))
    }
}

/// The overlay shows the frame the window will really take: a minimum wider
/// than the half grows the frame from the snapped edge, on the drop's
/// display. Release writes that frame, even if the minimum it reads again is
/// larger, instead of failing after a valid overlay.
@Test @MainActor func minimumSizeIsPartOfTheShownDrop() throws {
    let (system, first, second) = sideBySideDisplays()
    system.windows[0].constraints.minimumSize = BTSize(width: 700, height: 80)
    let controller = DragSnapController(coordinator: WindowCoordinator(system: system),
                                        configuration: BetterTileConfiguration())
    var results: [(Bool, String?)] = []
    controller.actionResultHandler = { results.append(($1, $2)) }
    controller.setUsesSharedGestureEvents(true)
    send(controller, .leftMouseDown, x: 300, y: 220)
    system.windows[0].frame.origin.x = 750
    system.windows[0].displayID = second
    send(controller, .leftMouseDragged, x: 998)
    let enlarged = BTRect(x: 300, y: 0, width: 700, height: 800)
    #expect(controller.dropTarget?.drop == .snap(SnapTarget(action: .rightHalf, frame: enlarged)))
    #expect(controller.dropTarget?.displayID == first)
    // A minimum measured on the other display arrives before the release.
    system.windows[0].constraints.minimumSize.width = 750
    send(controller, .leftMouseUp, x: 998)
    #expect(system.windows[0].frame == enlarged)
    #expect(results.count == 1 && results.first?.0 == true)
}

/// Bento state for two windows side by side on display A, with no gap.
@MainActor private func bentoController(
    _ system: FakeWindowSystem, preview: @escaping (BentoDragOutcome) -> LayoutDropPreview?
) -> (DragSnapController, () -> LayoutDragEnd?) {
    let source = system.windows[0].id, peer = system.windows[1].id
    let first = system.availableDisplays[0].id
    let controller = DragSnapController(coordinator: WindowCoordinator(system: system),
                                        configuration: BetterTileConfiguration(),
                                        displayTicks: ResizeDisplayLink(automatic: false))
    controller.activeModeProvider = { $0 == first ? .bento : nil }
    let layout = BentoLayoutState(root: .partition(BentoPartition(axis: .vertical,
        children: [.leaf(source), .leaf(peer)])), metrics: BentoLayoutMetrics(paneGap: 0))
    controller.bentoStateProvider = { $0 == first ? layout : nil }
    controller.bentoDragBeganHandler = { displayID, _, _ in displayID == first }
    controller.bentoPreviewHandler = { _, _, outcome in preview(outcome) }
    var dropped: LayoutDragEnd?
    controller.bentoDragEndedHandler = { _, _, end in dropped = end }
    controller.setUsesSharedGestureEvents(true)
    return (controller, { dropped })
}

/// A Bento drag whose window center crossed to B still drops the snap area
/// the pointer showed on A. The snap area at the screen edge wins over the
/// edge of the pane under it. The overlay shows the Bento plan for the snap,
/// with its gaps, and release commits that plan.
@Test @MainActor func bentoDragAtASharedEdgeCommitsTheShownSnapPlan() throws {
    let (system, first, second) = sideBySideDisplays()
    system.addSecondWindow()
    let source = system.windows[0].id
    let planned = [Placement(windowID: source, frame: BTRect(x: 508, y: 8, width: 484, height: 784))]
    var previewed: [BentoDragOutcome] = []
    let (controller, dropped) = bentoController(system) { outcome in
        previewed.append(outcome)
        return prepared(outcome, planned)
    }
    defer { controller.cancel() }
    send(controller, .leftMouseDown, x: 300, y: 220)
    system.windows[0].frame.origin.x = 750
    system.windows[0].displayID = second
    // The peer's pane is under the pointer, and the pointer is on its right edge.
    send(controller, .leftMouseDragged, x: 998)
    let snap = BentoDragOutcome.snap(action: .rightHalf, frame: BTRect(x: 500, y: 0, width: 500, height: 800))
    #expect(previewed == [snap])
    guard case let .layout(plan)? = controller.dropTarget?.drop else { Issue.record("Expected the snap plan"); return }
    #expect(controller.dropTarget?.displayID == first)
    #expect(plan.outcome == snap && plan.placements == planned)
    send(controller, .leftMouseUp, x: 1001)
    #expect(dropped() == .commit(plan))
}

/// A Bento snap whose plan cannot be made shows invalid feedback. Release
/// over it commits nothing and reports the reason.
@Test @MainActor func bentoSnapWithoutAPlanIsInvalidFeedback() {
    let system = FakeWindowSystem()
    system.addSecondWindow()
    let (controller, dropped) = bentoController(system) { _ in .invalid(reason: "Peers cannot fit.") }
    send(controller, .leftMouseDown, x: 300, y: 220)
    system.windows[0].frame.origin.x += 30
    send(controller, .leftMouseDragged, x: 1)
    #expect(controller.dropTarget?.drop == .invalid(reason: "Peers cannot fit."))
    send(controller, .leftMouseUp, x: 1)
    #expect(dropped() == .failed(reason: "Peers cannot fit."))
    #expect(system.frameWriteCounts.isEmpty)
}

/// An armed Bento cue is the drop. Release commits its plan without running
/// the hover timer again. An invalid cue is not a drop.
@Test(arguments: [true, false]) @MainActor
func bentoReleaseCommitsTheArmedCue(valid: Bool) async throws {
    let system = FakeWindowSystem()
    system.addSecondWindow()
    let source = system.windows[0].id, peer = system.windows[1].id
    let planned = [Placement(windowID: source, frame: BTRect(x: 500, y: 0, width: 500, height: 400))]
    let (controller, dropped) = bentoController(system) { outcome in
        guard case .insert = outcome else { return nil }
        return valid ? prepared(outcome, planned) : .invalid(reason: "Too small.")
    }
    defer { controller.cancel() }
    send(controller, .leftMouseDown, x: 300, y: 220)
    system.windows[0].frame.origin.x += 30
    // The top edge of the peer's pane, away from any snap area.
    send(controller, .leftMouseDragged, x: 750, y: 40)
    #expect(controller.dropTarget == nil)
    // A busy test runner can delay the cue's arming task.
    let deadline = ContinuousClock.now.advanced(by: .seconds(10))
    while controller.dropTarget == nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    let insert = BentoDragOutcome.insert(targetWindowID: peer, edge: .top)
    // The button comes up over the pane's center; the armed cue still wins.
    send(controller, .leftMouseUp, x: 750, y: 400)
    if valid {
        guard case let .commit(plan)? = dropped() else { Issue.record("Expected the armed plan"); return }
        #expect(plan.outcome == insert && plan.placements == planned)
    } else {
        #expect(dropped() == .failed(reason: "Too small."))
    }
}

@Test(arguments: [false, true]) @MainActor
func bentoReleaseWithASuppressionModifierRestores(modified: Bool) {
    let system = FakeWindowSystem()
    system.addSecondWindow()
    let source = system.windows[0].id
    let (controller, dropped) = bentoController(system) { outcome in
        prepared(outcome, [Placement(windowID: source, frame: BTRect(x: 8, y: 8, width: 484, height: 784))])
    }
    send(controller, .leftMouseDown, x: 300, y: 220)
    system.windows[0].frame.origin.x += 30
    send(controller, .leftMouseDragged, x: 1, y: 400)
    send(controller, .leftMouseUp, x: 1, y: 400, modifiers: modified ? .option : [])
    if modified {
        #expect(dropped() == .restore)
    } else {
        guard case .snap(action: .leftHalf, frame: _) = committedOutcome(dropped()) else {
            Issue.record("Expected the shown snap"); return
        }
    }
}

/// A minimum larger than the snap area's display cannot be held. The overlay
/// shows invalid feedback instead of a drop, and release writes nothing.
@Test @MainActor func minimumSizeLargerThanTheDisplayIsInvalidFeedback() {
    let system = FakeWindowSystem()
    system.windows[0].constraints.minimumSize = BTSize(width: 1200, height: 80)
    let controller = DragSnapController(coordinator: WindowCoordinator(system: system),
                                        configuration: BetterTileConfiguration())
    var results: [(Bool, String?)] = []
    controller.actionResultHandler = { results.append(($1, $2)) }
    controller.setUsesSharedGestureEvents(true)
    send(controller, .leftMouseDown, x: 300, y: 220)
    system.windows[0].frame.origin.x += 3
    let dropped = system.windows[0].frame
    send(controller, .leftMouseDragged, x: 1)
    guard case .invalid? = controller.dropTarget?.drop else { Issue.record("Expected invalid feedback"); return }
    send(controller, .leftMouseUp, x: 1)
    // A Native window stays where the user dropped it, as after any drag
    // without a snap; it does not return to its mouse-down frame.
    #expect(system.windows[0].frame == dropped)
    #expect(system.frameWriteCounts.isEmpty)
    #expect(results.count == 1 && results.first?.0 == false && results.first?.1 != nil)
}

/// A click (no drag samples) on a Tabbed tab whose group has hidden tabs,
/// pressed inside a snap area, is still a click: no drag, no drop, no write.
@Test @MainActor func aClickInsideASnapAreaStartsNoTabbedDrag() {
    let system = FakeWindowSystem()
    system.addSecondWindow()
    // The tab is pressed in its title bar at the display's left edge snap area.
    system.windows[0].frame = BTRect(x: 0, y: 0, width: 500, height: 800)
    let hidden = system.windows[1].id
    system.windows[1].frame = system.windows[0].frame
    let controller = DragSnapController(coordinator: WindowCoordinator(system: system), configuration: BetterTileConfiguration())
    controller.activeModeProvider = { _ in .tabbed }
    controller.bentoStateProvider = { _ in BentoLayoutState(root: .leaf(system.windows[0].id)) }
    controller.isTabbedMember = { $0 == hidden || $0 == system.windows[0].id }
    var began = 0, ended = 0, previews = 0
    controller.bentoDragBeganHandler = { _, _, _ in began += 1; return true }
    controller.bentoPreviewHandler = { _, _, _ in previews += 1; return nil }
    controller.bentoDragEndedHandler = { _, _, _ in ended += 1 }
    controller.setUsesSharedGestureEvents(true)
    let point = BTPoint(x: 9, y: 20)
    #expect(SnapZoneDetector().area(at: BTPoint(x: 2, y: 400), in: system.availableDisplays[0].frame) == .left)
    controller.handleSharedGestureEvent(GlobalGestureEvent(
        kind: .leftMouseDown, position: point, button: 0, modifiers: [], timestamp: 1))
    controller.handleSharedGestureEvent(GlobalGestureEvent(
        kind: .leftMouseUp, position: BTPoint(x: 2, y: 400), button: 0, modifiers: [], timestamp: 2))
    #expect(began == 0 && ended == 0 && previews == 0)
    #expect(controller.dropTarget == nil)
    #expect(!controller.isGestureActive)
    #expect(system.frameWriteCounts.isEmpty)
}

/// Live, with separate Spaces per display: the window's center crossed to a
/// display whose current Space does not hold it. Its own Space is still
/// current on the display it came from, so the snapshot keeps it there, and
/// the drop shown on that display applies.
@Test @MainActor func dropAppliesWhenTheCenterCrossedIntoAnotherDisplaysSpace() throws {
    let (system, first, second) = sideBySideDisplays()
    let ownSpace = NativeSpaceID(rawValue: 638), otherSpace = NativeSpaceID(rawValue: 635)
    system.nativeObservation = NativeDesktopObservation(
        currentSpaceByDisplay: [first: ownSpace, second: otherSpace],
        knownSpacesByDisplay: [first: [ownSpace], second: [otherSpace]],
        windowMembership: [system.windows[0].id: [ownSpace]]
    )
    let controller = DragSnapController(coordinator: WindowCoordinator(system: system),
                                        configuration: BetterTileConfiguration())
    var results: [(Bool, String?)] = []
    controller.actionResultHandler = { results.append(($1, $2)) }
    controller.setUsesSharedGestureEvents(true)
    send(controller, .leftMouseDown, x: 300, y: 220)
    // The center-based display is B; the Space is still A's.
    system.windows[0].frame.origin.x = 750
    system.windows[0].displayID = second
    let snapshot = try #require(try system.windowSnapshots(ids: [system.windows[0].id]).first)
    #expect(snapshot.displayID == first)
    send(controller, .leftMouseDragged, x: 998)
    send(controller, .leftMouseUp, x: 998)
    #expect(results.count == 1 && results.first?.0 == true, "\(results)")
    #expect(system.windows[0].frame == BTRect(x: 500, y: 0, width: 500, height: 800))
    // After the write the window is on its Space's display; reads keep it.
    #expect(try system.windowSnapshots(ids: [system.windows[0].id]).first?.displayID == first)
}

// MARK: - Tabbed tab strip drops

/// Over a pane's tab strip, the overlay shows an insertion line at a tab
/// index, above the dragged window, and release adds the window there. The
/// display has no permanent menu bar, so the strip reaches the top edge. The
/// strip wins over a snap area except in the screen-edge bands, where the top
/// edge, its corners, and the side edges still snap.
@Test @MainActor func tabStripHoverShowsAnInsertionAndCommitsATabDrop() throws {
    _ = NSApplication.shared
    let system = FakeWindowSystem()
    system.availableDisplays[0].frame.origin.x = 12000
    system.availableDisplays[0].visibleFrame.origin.x = 12000
    system.windows[0].frame.origin.x += 12000
    system.addSecondWindow()
    let source = system.windows[0].id, other = system.windows[1].id
    let controller = DragSnapController(coordinator: WindowCoordinator(system: system),
                                        configuration: BetterTileConfiguration(),
                                        displayTicks: ResizeDisplayLink(automatic: false))
    defer { controller.cancel() }
    controller.activeModeProvider = { _ in .tabbed }
    let layout = BentoLayoutState(root: .partition(BentoPartition(axis: .vertical,
        children: [.leaf(source), .leaf(other)])))
    controller.bentoStateProvider = { _ in layout }
    controller.bentoDragBeganHandler = { _, _, _ in true }
    let paneID = UUID()
    // A strip across the display: y 0-34, with edges at 12250 and 12500.
    // Below y 500 the left side is an empty pane.
    let emptyPaneID = UUID()
    controller.tabbedDropZoneProvider = { _, point, id in
        #expect(id == source)
        if point.x < 12500, point.y >= 500 {
            return TabbedDropZone(paneID: emptyPaneID, index: nil,
                                  paneFrame: BTRect(x: 12000, y: 500, width: 500, height: 300), indicator: nil)
        }
        guard point.y < 34 else { return nil }
        let index = point.x < 12250 ? 0 : 1
        return TabbedDropZone(paneID: paneID, index: index,
                              paneFrame: BTRect(x: 12000, y: 10, width: 500, height: 790),
                              indicator: BTRect(x: index == 0 ? 12030 : 12248, y: 14, width: 4, height: 26))
    }
    var state = TabbedLayoutState()
    state.reconcile(windowIDs: [source], removed: [], focused: source)
    controller.bentoPreviewHandler = { _, _, outcome in
        if case let .snap(_, frame) = outcome { return prepared(outcome, [Placement(windowID: source, frame: frame)]) }
        return .ready(PreparedLayoutDrop(outcome: outcome, placements: [], plan: .tabbed(state), dragID: UUID()))
    }
    var dropped: LayoutDragEnd?
    controller.bentoDragEndedHandler = { _, _, end in dropped = end }
    controller.setUsesSharedGestureEvents(true)
    let mainFrame = try #require(NSScreen.screens.first?.frame)
    func indicators() -> [NSWindow] {
        NSApplication.shared.windows.filter { $0.isVisible && $0.contentView is TabInsertionIndicatorView }
    }

    send(controller, .leftMouseDown, x: 12300, y: 220)
    system.windows[0].frame.origin.x += 3
    send(controller, .leftMouseDragged, x: 12100, y: 20)
    #expect(committedOutcome(controller.dropTarget.map { $0.layoutEnd }) == .tab(paneID: paneID, index: 0))
    send(controller, .leftMouseDragged, x: 12300, y: 20)
    controller.displayTick()
    #expect(committedOutcome(controller.dropTarget.map { $0.layoutEnd }) == .tab(paneID: paneID, index: 1))
    let indicator = try #require(indicators().first)
    #expect(indicators().count == 1)
    #expect(indicator.level == .floating)
    #expect(indicator.frame == CoordinateConverter.toAppKit(BTRect(x: 12248, y: 14, width: 4, height: 26),
                                                            mainScreenFrame: mainFrame))

    // Inside the strip but away from the edge bands, the strip wins over the
    // top-left corner's snap area.
    send(controller, .leftMouseDragged, x: 12030, y: 20)
    controller.displayTick()
    #expect(committedOutcome(controller.dropTarget.map { $0.layoutEnd }) == .tab(paneID: paneID, index: 0))
    // In the edge bands over the strip, the top edge and the top corners
    // still snap; at strip height, a side edge is in its top corner.
    for (x, y, action) in [(12700.0, 2.0, WindowAction.almostMaximize), (12002, 20, .topLeftQuarter),
                           (12998, 20, .topRightQuarter)] {
        send(controller, .leftMouseDragged, x: x, y: y)
        controller.displayTick()
        guard case .snap(action: action, frame: _)? = committedOutcome(controller.dropTarget.map { $0.layoutEnd }) else {
            Issue.record("\(action) must still snap at the screen edge"); return
        }
        #expect(indicators().isEmpty)
    }

    send(controller, .leftMouseDragged, x: 12300, y: 20)
    controller.displayTick()
    send(controller, .leftMouseUp, x: 12300, y: 20)
    #expect(committedOutcome(dropped) == .tab(paneID: paneID, index: 1))
    #expect(indicators().isEmpty)
}

/// An empty pane is a drop target without an insertion line. A snap area
/// over it wins, as over a pane center.
@Test @MainActor func emptyPaneHoverCommitsATabDropUnlessASnapAreaWins() throws {
    _ = NSApplication.shared
    let system = FakeWindowSystem()
    system.availableDisplays[0].frame.origin.x = 12000
    system.availableDisplays[0].visibleFrame.origin.x = 12000
    system.windows[0].frame.origin.x += 12000
    system.addSecondWindow()
    let source = system.windows[0].id
    let controller = DragSnapController(coordinator: WindowCoordinator(system: system),
                                        configuration: BetterTileConfiguration(),
                                        displayTicks: ResizeDisplayLink(automatic: false))
    defer { controller.cancel() }
    controller.activeModeProvider = { _ in .tabbed }
    let layout = BentoLayoutState(root: .partition(BentoPartition(axis: .vertical,
        children: [.vacant(UUID()), .leaf(system.windows[1].id)])))
    controller.bentoStateProvider = { _ in layout }
    controller.bentoDragBeganHandler = { _, _, _ in true }
    let emptyPaneID = UUID()
    controller.tabbedDropZoneProvider = { _, point, _ in
        point.x < 12500 ? TabbedDropZone(paneID: emptyPaneID, index: nil,
                                         paneFrame: BTRect(x: 12000, y: 0, width: 500, height: 800), indicator: nil) : nil
    }
    var state = TabbedLayoutState()
    state.reconcile(windowIDs: [source], removed: [], focused: source)
    controller.bentoPreviewHandler = { _, _, outcome in
        if case let .snap(_, frame) = outcome { return prepared(outcome, [Placement(windowID: source, frame: frame)]) }
        return .ready(PreparedLayoutDrop(outcome: outcome, placements: [], plan: .tabbed(state), dragID: UUID()))
    }
    var dropped: LayoutDragEnd?
    controller.bentoDragEndedHandler = { _, _, end in dropped = end }
    controller.setUsesSharedGestureEvents(true)
    send(controller, .leftMouseDown, x: 12300, y: 220)
    system.windows[0].frame.origin.x += 3
    send(controller, .leftMouseDragged, x: 12002, y: 400)
    controller.displayTick()
    guard case .snap(action: .leftHalf, frame: _)? = committedOutcome(controller.dropTarget.map { $0.layoutEnd }) else {
        Issue.record("The left edge's snap area wins over an empty pane"); return
    }
    send(controller, .leftMouseDragged, x: 12250, y: 400)
    controller.displayTick()
    #expect(NSApplication.shared.windows.filter { $0.isVisible && $0.contentView is TabInsertionIndicatorView }.isEmpty)
    send(controller, .leftMouseUp, x: 12250, y: 400)
    #expect(committedOutcome(dropped) == .tab(paneID: emptyPaneID, index: nil))
}

/// A tab drop's cue says "Add as tab"; other drops keep their own badge.
@Test @MainActor func tabDropCueSaysAddAsTab() {
    let a = WindowID(rawValue: "a")
    var state = TabbedLayoutState()
    state.reconcile(windowIDs: [a], removed: [], focused: a)
    let pane = state.panes[0].id
    func label(_ outcome: BentoDragOutcome) -> String? {
        DragSnapController.tabCueLabel(PreparedLayoutDrop(outcome: outcome, placements: [], plan: .tabbed(state),
                                                          dragID: UUID()))
    }
    #expect(label(.tab(paneID: pane, index: 0)) == "Add as tab")
    #expect(label(.swap(targetWindowID: a)) == "Add as tab")
    #expect(label(.snap(action: .leftHalf, frame: BTRect(x: 0, y: 0, width: 1, height: 1))) == nil)
}
