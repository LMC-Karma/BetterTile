import AppKit
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

@Test @MainActor func linkedResizeDoesNotMoveAnIgnoredNeighbor() {
    let system = FakeWindowSystem()
    system.addSecondWindow()
    system.windows[0].frame = BTRect(x: 0, y: 0, width: 500, height: 800)
    system.windows[1].frame = BTRect(x: 500, y: 0, width: 500, height: 800)
    let neighbor = system.windows[1]
    var configuration = BetterTileConfiguration()
    configuration.linkedResizeEnabled = true
    configuration.applicationRules.set(.ignoreEverywhere, for: "com.example.Second")
    let ticks = ResizeDisplayLink(automatic: false)
    let controller = LinkedResizeController(
        coordinator: WindowCoordinator(system: system),
        configuration: configuration,
        displayTicks: ticks
    )
    controller.isEnabledForDisplay = { _ in true }
    controller.setUsesSharedGestureEvents(true)
    func event(_ kind: GlobalGestureEventKind) -> GlobalGestureEvent {
        GlobalGestureEvent(kind: kind, position: BTPoint(x: 500, y: 400), button: 0, modifiers: [], timestamp: 1)
    }

    controller.handleSharedGestureEvent(event(.leftMouseDown))
    controller.handleSharedGestureEvent(event(.leftMouseDragged))
    system.windows[0].frame.size.width = 600
    controller.handleSharedGestureEvent(event(.leftMouseDragged))
    ticks.fire()
    controller.handleSharedGestureEvent(event(.leftMouseUp))

    #expect(system.windows[1].frame == neighbor.frame)
    #expect(system.frameWriteCounts[neighbor.id] == nil)
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

@Test @MainActor func linkedResizeAppliesTheLatestObservedFrameOnDisplayTickAndFlushesRelease() async {
    let system = FakeWindowSystem()
    let focused = WindowID(rawValue: "focused")
    let second = WindowID(rawValue: "second")
    system.windows = [
        WindowSnapshot(
            id: focused,
            processIdentifier: 42,
            frame: BTRect(x: 0, y: 0, width: 500, height: 800),
            displayID: DisplayID(rawValue: "main")
        ),
        WindowSnapshot(
            id: second,
            processIdentifier: 43,
            frame: BTRect(x: 500, y: 0, width: 500, height: 800),
            displayID: DisplayID(rawValue: "main")
        ),
    ]
    system.focusedWindowID = focused
    var configuration = BetterTileConfiguration()
    configuration.linkedResizeEnabled = true
    let displayTicks = ResizeDisplayLink(automatic: false)
    let controller = LinkedResizeController(
        coordinator: WindowCoordinator(system: system),
        configuration: configuration,
        displayTicks: displayTicks
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
    controller.handleSharedGestureEvent(event(.leftMouseDragged, timestamp: 2))
    displayTicks.fire()
    for width in 501...620 {
        system.windows[0].frame.size.width = Double(width)
        controller.handleSharedGestureEvent(event(.leftMouseDragged, timestamp: UInt64(width)))
    }

    #expect(system.frameWriteCounts[second] == nil)
    displayTicks.fire()
    #expect(system.frameWriteCounts[second] == 1)
    #expect(system.frameWriteCounts[focused] == nil)
    // One read refreshes minimums when resizing starts; one validates the tick.
    #expect(system.targetedSnapshotRequests == 2)
    #expect(system.windows[1].frame == BTRect(x: 620, y: 0, width: 380, height: 800))

    system.windows[0].frame.size.width = 650
    controller.handleSharedGestureEvent(event(.leftMouseDragged, timestamp: 700))
    #expect(system.frameWriteCounts[second] == 1)
    controller.handleSharedGestureEvent(event(.leftMouseUp, timestamp: 701))

    #expect(system.frameWriteCounts[second] == 2)
    #expect(system.targetedSnapshotRequests == 3)
    #expect(system.windows[1].frame == BTRect(x: 650, y: 0, width: 350, height: 800))
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

@Test @MainActor func deferredStartDoesNotReplaceAnActiveLinkedResizeBaseline() async {
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
    system.windows[0].frame.size.width = 510
    await Task.yield()
    await Task.yield()
    system.windows[0].frame.size.width = 520
    controller.handleSharedGestureEvent(event(.leftMouseDragged, timestamp: 3))
    controller.handleSharedGestureEvent(event(.leftMouseUp, timestamp: 4))

    #expect(system.windows[1].frame.minX == 517)
}

@Test @MainActor func eventTapHandoffWaitsForTheActiveNSEventLinkedResize() async {
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

    func event(_ kind: GlobalGestureEventKind, timestamp: UInt64) -> GlobalGestureEvent {
        GlobalGestureEvent(
            kind: kind,
            position: BTPoint(x: 500, y: 400),
            button: 0,
            modifiers: [],
            timestamp: timestamp
        )
    }

    // The tap starts the resize, then fails, so NSEvent monitors take it over.
    controller.setUsesSharedGestureEvents(true)
    controller.handleSharedGestureEvent(event(.leftMouseDown, timestamp: 1))
    controller.setUsesSharedGestureEvents(false)
    system.windows[0].frame.size.width = 510
    controller.receive(event(.leftMouseDragged, timestamp: 2), from: .nsEvent)
    controller.displayTick()
    #expect(system.windows[1].frame.minX == 510)

    // The tap becomes available again while that NSEvent resize is still running.
    controller.setUsesSharedGestureEvents(true)
    system.windows[0].frame.size.width = 560
    controller.handleSharedGestureEvent(event(.leftMouseDragged, timestamp: 3))
    controller.handleSharedGestureEvent(event(.leftMouseUp, timestamp: 4))
    #expect(system.windows[1].frame.minX == 510)

    // The NSEvent events keep driving the gesture until it ends.
    controller.receive(event(.leftMouseDragged, timestamp: 5), from: .nsEvent)
    controller.displayTick()
    #expect(system.windows[1].frame == BTRect(x: 560, y: 0, width: 440, height: 800))
    controller.receive(event(.leftMouseUp, timestamp: 6), from: .nsEvent)
    await Task.yield()

    // The deferred handoff applies, so the next gesture uses the event tap. The
    // first drag only establishes the baseline, whichever path reaches it
    // first, so the measured change comes from the second drag alone.
    system.windows[0].frame = BTRect(x: 0, y: 0, width: 500, height: 800)
    system.windows[1].frame = BTRect(x: 500, y: 0, width: 500, height: 800)
    controller.handleSharedGestureEvent(event(.leftMouseDown, timestamp: 7))
    controller.handleSharedGestureEvent(event(.leftMouseDragged, timestamp: 8))
    system.windows[0].frame.size.width = 550
    controller.handleSharedGestureEvent(event(.leftMouseDragged, timestamp: 9))
    controller.handleSharedGestureEvent(event(.leftMouseUp, timestamp: 10))
    await Task.yield()

    #expect(system.windows[1].frame == BTRect(x: 550, y: 0, width: 450, height: 800))
}

/// A display tick usually consumes the last drag sample before release. The
/// release must still validate and apply the source window's final frame.
@Test @MainActor func linkedResizeReleaseAppliesTheFinalFrameAfterATickConsumedTheLastSample() {
    let system = FakeWindowSystem()
    let focused = WindowID(rawValue: "focused")
    let second = WindowID(rawValue: "second")
    system.windows = [
        WindowSnapshot(id: focused, processIdentifier: 42, frame: BTRect(x: 0, y: 0, width: 500, height: 800), displayID: DisplayID(rawValue: "main")),
        WindowSnapshot(id: second, processIdentifier: 43, frame: BTRect(x: 500, y: 0, width: 500, height: 800), displayID: DisplayID(rawValue: "main")),
    ]
    system.focusedWindowID = focused
    var configuration = BetterTileConfiguration()
    configuration.linkedResizeEnabled = true
    let displayTicks = ResizeDisplayLink(automatic: false)
    let controller = LinkedResizeController(
        coordinator: WindowCoordinator(system: system),
        configuration: configuration,
        displayTicks: displayTicks
    )
    controller.isEnabledForDisplay = { _ in true }
    controller.setUsesSharedGestureEvents(true)
    func event(_ kind: GlobalGestureEventKind, timestamp: UInt64) -> GlobalGestureEvent {
        GlobalGestureEvent(kind: kind, position: BTPoint(x: 500, y: 400), button: 0, modifiers: [], timestamp: timestamp)
    }

    controller.handleSharedGestureEvent(event(.leftMouseDown, timestamp: 1))
    controller.handleSharedGestureEvent(event(.leftMouseDragged, timestamp: 2))
    displayTicks.fire()
    system.windows[0].frame.size.width = 600
    controller.handleSharedGestureEvent(event(.leftMouseDragged, timestamp: 3))
    displayTicks.fire()
    #expect(system.windows[1].frame == BTRect(x: 600, y: 0, width: 400, height: 800))
    let snapshots = system.targetedSnapshotRequests

    // The application settles the source window after the last sample.
    system.windows[0].frame.size.width = 640
    controller.handleSharedGestureEvent(event(.leftMouseUp, timestamp: 4))

    #expect(system.windows[1].frame == BTRect(x: 640, y: 0, width: 360, height: 800))
    #expect(system.targetedSnapshotRequests > snapshots)
}

/// An application can accept a frame write and ignore it. Release at the same
/// position must resend the final frame instead of trusting the last request.
@Test @MainActor func linkedResizeReleaseResendsAFrameThatAnApplicationIgnored() {
    let system = FakeWindowSystem()
    let focused = WindowID(rawValue: "focused")
    let second = WindowID(rawValue: "second")
    system.windows = [
        WindowSnapshot(id: focused, processIdentifier: 42, frame: BTRect(x: 0, y: 0, width: 500, height: 800), displayID: DisplayID(rawValue: "main")),
        WindowSnapshot(id: second, processIdentifier: 43, frame: BTRect(x: 500, y: 0, width: 500, height: 800), displayID: DisplayID(rawValue: "main")),
    ]
    system.focusedWindowID = focused
    var configuration = BetterTileConfiguration()
    configuration.linkedResizeEnabled = true
    let displayTicks = ResizeDisplayLink(automatic: false)
    let controller = LinkedResizeController(
        coordinator: WindowCoordinator(system: system),
        configuration: configuration,
        displayTicks: displayTicks
    )
    controller.isEnabledForDisplay = { _ in true }
    controller.setUsesSharedGestureEvents(true)
    func event(_ kind: GlobalGestureEventKind, timestamp: UInt64) -> GlobalGestureEvent {
        GlobalGestureEvent(kind: kind, position: BTPoint(x: 500, y: 400), button: 0, modifiers: [], timestamp: timestamp)
    }

    controller.handleSharedGestureEvent(event(.leftMouseDown, timestamp: 1))
    controller.handleSharedGestureEvent(event(.leftMouseDragged, timestamp: 2))
    displayTicks.fire()
    system.windows[0].frame.size.width = 600
    system.ignoredFrameWriteCounts[second] = 1
    controller.handleSharedGestureEvent(event(.leftMouseDragged, timestamp: 3))
    displayTicks.fire()
    #expect(system.windows[1].frame == BTRect(x: 500, y: 0, width: 500, height: 800))

    controller.handleSharedGestureEvent(event(.leftMouseUp, timestamp: 4))

    #expect(system.windows[1].frame == BTRect(x: 600, y: 0, width: 400, height: 800))
}

@Test @MainActor func linkedResizeForgetsLearnedMinimumsOnlyWhenAWindowResizes() {
    let system = FakeWindowSystem()
    system.addSecondWindow()
    system.windows[0].frame = BTRect(x: 0, y: 0, width: 500, height: 800)
    system.windows[1].frame = BTRect(x: 500, y: 0, width: 500, height: 800)
    var configuration = BetterTileConfiguration()
    configuration.linkedResizeEnabled = true
    let ticks = ResizeDisplayLink(automatic: false)
    let controller = LinkedResizeController(
        coordinator: WindowCoordinator(system: system), configuration: configuration, displayTicks: ticks
    )
    controller.isEnabledForDisplay = { _ in true }
    controller.setUsesSharedGestureEvents(true)
    var forgets = 0
    controller.gestureWillBeginHandler = { forgets += 1 }
    func event(_ kind: GlobalGestureEventKind) -> GlobalGestureEvent {
        GlobalGestureEvent(kind: kind, position: BTPoint(x: 500, y: 400), button: 0, modifiers: [], timestamp: 1)
    }

    // A plain click or a drag that resizes nothing keeps learned minimums.
    controller.handleSharedGestureEvent(event(.leftMouseDown))
    controller.handleSharedGestureEvent(event(.leftMouseDragged))
    ticks.fire()
    controller.handleSharedGestureEvent(event(.leftMouseUp))
    #expect(forgets == 0)

    // An edge drag forgets them once, when the window first resizes.
    controller.handleSharedGestureEvent(event(.leftMouseDown))
    controller.handleSharedGestureEvent(event(.leftMouseDragged))
    system.windows[0].frame.size.width = 560
    controller.handleSharedGestureEvent(event(.leftMouseDragged))
    ticks.fire()
    system.windows[0].frame.size.width = 600
    controller.handleSharedGestureEvent(event(.leftMouseDragged))
    ticks.fire()
    controller.handleSharedGestureEvent(event(.leftMouseUp))
    #expect(forgets == 1)
    #expect(system.windows[1].frame.minX == 600)
}

@Test(arguments: ["stop", "restart", "configuration", "handoff"]) @MainActor
func queuedLinkedResizePressCannotStartAfterMonitorRetirement(retirement: String) async throws {
    let system = FakeWindowSystem()
    var configuration = BetterTileConfiguration()
    configuration.linkedResizeEnabled = true
    let ticks = ResizeDisplayLink(automatic: false)
    let controller = LinkedResizeController(coordinator: WindowCoordinator(system: system), configuration: configuration, displayTicks: ticks)
    controller.isEnabledForDisplay = { _ in true }
    var callback: ((NSEvent) -> Void)?
    var gestureMonitors = 0
    controller.addGlobalMonitor = { mask, handler in
        if mask.contains(.leftMouseDown) { callback = handler }
        else { gestureMonitors += 1 }
        return NSObject()
    }
    controller.removeEventMonitor = { _ in }
    controller.start()
    defer { controller.stop() }
    let event = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 1,
                                               windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
    #expect(callback != nil)
    callback?(event)
    switch retirement {
    case "configuration":
        controller.configuration.linkedResizeEnabled = false
        controller.configuration.linkedResizeEnabled = true
    case "handoff":
        controller.setUsesSharedGestureEvents(true)
        controller.setUsesSharedGestureEvents(false)
    default:
        controller.stop()
        if retirement == "restart" { controller.start() }
    }
    for _ in 0..<20 { await Task.yield() }
    #expect(gestureMonitors == 0)
    #expect(system.frameWriteCounts.isEmpty)
    if retirement != "stop" {
        #expect(callback != nil)
        callback?(event)
        for _ in 0..<20 { await Task.yield() }
        #expect(gestureMonitors == 2)
    }
}

@Test(arguments: [false, true]) @MainActor
func degradedLinkedResizeRestoresPeersOrReportsTerminalFailure(recoveryFails: Bool) {
    let system = FakeWindowSystem()
    system.addSecondWindow()
    system.windows[0].frame = BTRect(x: 0, y: 0, width: 500, height: 800)
    system.windows[1].frame = BTRect(x: 500, y: 0, width: 500, height: 800)
    let peer = system.windows[1]
    let ticks = ResizeDisplayLink(automatic: false)
    var configuration = BetterTileConfiguration()
    configuration.linkedResizeEnabled = true
    let controller = LinkedResizeController(coordinator: WindowCoordinator(system: system), configuration: configuration, displayTicks: ticks)
    controller.addGlobalMonitor = { _, _ in NSObject() }
    controller.removeEventMonitor = { _ in }
    controller.isEnabledForDisplay = { _ in true }
    controller.setUsesSharedGestureEvents(true)
    var failures: [DisplayID] = []
    controller.rollbackFailureHandler = { id, reason in
        failures.append(id)
        #expect(reason?.isEmpty == false)
    }
    func event(_ kind: GlobalGestureEventKind) -> GlobalGestureEvent {
        GlobalGestureEvent(kind: kind, position: BTPoint(x: 500, y: 400), button: 0, modifiers: [], timestamp: 1)
    }
    controller.handleSharedGestureEvent(event(.leftMouseDown))
    controller.handleSharedGestureEvent(event(.leftMouseDragged))
    system.partiallyFailedFrameWriteNumbers[peer.id] = [1]
    system.failedFrameWriteNumbers[peer.id] = recoveryFails ? [2, 3, 4] : [2]
    system.windows[0].frame.size.width = 600
    controller.handleSharedGestureEvent(event(.leftMouseDragged))
    ticks.fire()
    #expect(system.frameWriteCounts[peer.id] == (recoveryFails ? 4 : 3))
    #expect((system.windows[1].frame == peer.frame) == !recoveryFails)
    #expect(failures == (recoveryFails ? [peer.displayID] : []))
    let writes = system.frameWriteCounts
    system.windows[0].frame.size.width = 650
    controller.handleSharedGestureEvent(event(.leftMouseDragged))
    ticks.fire()
    controller.handleSharedGestureEvent(event(.leftMouseUp))
    #expect(system.frameWriteCounts == writes)
    controller.stop()
}
