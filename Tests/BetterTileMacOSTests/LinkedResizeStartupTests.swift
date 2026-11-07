import Testing
@testable import BetterTileCore
@testable import BetterTileMacOS

@Suite(.macOSTestApplication, .serialized) @MainActor
struct LinkedResizeStartupTests {
    @Test(arguments: [false, true], [440.0, 560.0])
    func firstObservedMovementKeepsTheOriginalSharedBoundary(focusChanges: Bool, firstWidth: Double) {
        let system = FakeWindowSystem()
        let bounds = BTRect(x: -10_000, y: -10_000, width: 1_000, height: 800)
        system.availableDisplays = [DisplaySnapshot(id: DisplayID(rawValue: "main"),
            frame: bounds, visibleFrame: bounds)]
        system.addSecondWindow()
        system.windows[0].frame = BTRect(x: bounds.minX, y: bounds.minY, width: 500, height: 800)
        system.windows[1].frame = BTRect(x: bounds.midX, y: bounds.minY, width: 500, height: 800)
        system.focusedWindowID = system.windows[focusChanges ? 1 : 0].id
        var configuration = BetterTileConfiguration()
        configuration.linkedResizeEnabled = true
        let ticks = ResizeDisplayLink(automatic: false)
        let controller = LinkedResizeController(coordinator: WindowCoordinator(system: system),
            configuration: configuration, displayTicks: ticks)
        defer { controller.stop() }
        controller.isEnabledForDisplay = { _ in true }
        controller.setUsesSharedGestureEvents(true)
        func send(_ kind: GlobalGestureEventKind, _ timestamp: UInt64) {
            controller.handleSharedGestureEvent(GlobalGestureEvent(kind: kind,
                position: BTPoint(x: bounds.midX, y: bounds.midY), button: 0,
                modifiers: [], timestamp: timestamp))
        }
        // The native app can focus and resize before the queued admission task runs.
        send(.leftMouseDown, 1)
        #expect(system.visibleWindowsReadCount == 1)
        system.focusedWindowID = system.windows[0].id
        system.windows[0].frame.size.width = firstWidth
        send(.leftMouseDragged, 2)
        #expect(system.visibleWindowsReadCount == 1, "Admission reuses the Manual display's press snapshot")
        system.windows[0].frame.size.width = 430
        send(.leftMouseDragged, 3)
        send(.leftMouseUp, 4)
        #expect(system.windows[1].frame == BTRect(x: -9_570, y: -10_000, width: 570, height: 800))
        #expect(system.windows[0].frame.size.width == 430)
        #expect(system.frameWriteCounts[system.windows[0].id] == nil,
                "The application owns the source resize")
        #expect(!controller.isResizing)
    }

    @Test(arguments: [LayoutMode.manual, .bento, .tabbed])
    func pressInventoryHonorsThePointerDisplayMode(mode: LayoutMode) {
        let system = FakeWindowSystem()
        let pointerDisplay = DisplayID(rawValue: "pointer")
        let pointerBounds = BTRect(x: -2_000, y: -2_000, width: 1_000, height: 800)
        system.availableDisplays.append(DisplaySnapshot(id: pointerDisplay,
            frame: pointerBounds, visibleFrame: pointerBounds))
        // Focus is still on a different Manual display when the press arrives.
        let controller = LinkedResizeController(coordinator: WindowCoordinator(system: system),
            configuration: BetterTileConfiguration(), displayTicks: ResizeDisplayLink(automatic: false))
        defer { controller.stop() }
        controller.isEnabledForDisplay = { $0 != pointerDisplay || mode == .manual }
        controller.setUsesSharedGestureEvents(true)
        var target = system.windows[0]
        target.id = WindowID(rawValue: "target")
        target.displayID = pointerDisplay
        target.frame = pointerBounds
        system.windows.append(target)
        let point = BTPoint(x: pointerBounds.midX, y: pointerBounds.midY)
        controller.handleSharedGestureEvent(event(.leftMouseDown, at: point))
        #expect(system.visibleWindowsReadCount == (mode == .manual ? 1 : 0))
        controller.handleSharedGestureEvent(event(.leftMouseUp, at: point))
    }

    @Test(arguments: ["ignored", "floating", "immovable", "fullscreen", "desktop", "disabled"])
    func ineligiblePressDoesNotReadInventory(reason: String) {
        let system = FakeWindowSystem()
        var configuration = BetterTileConfiguration()
        switch reason {
        case "ignored": configuration.applicationRules.set(.ignoreEverywhere, for: "com.example.Test")
        case "floating": system.windows[0].isFloating = true
        case "immovable": system.windows[0].constraints.isMovable = false
        case "fullscreen": system.windows[0].isFullScreen = true
        case "disabled": configuration.linkedResizeEnabled = false
        default: break
        }
        let controller = LinkedResizeController(coordinator: WindowCoordinator(system: system),
            configuration: configuration, displayTicks: ResizeDisplayLink(automatic: false))
        defer { controller.stop() }
        controller.isEnabledForDisplay = { _ in true }
        controller.setUsesSharedGestureEvents(true)
        let point = reason == "desktop" ? BTPoint(x: 50, y: 50) : BTPoint(x: 500, y: 400)
        controller.handleSharedGestureEvent(event(.leftMouseDown, at: point))
        #expect(system.visibleWindowsReadCount == 0)
        controller.handleSharedGestureEvent(event(.leftMouseUp, at: point))
    }

    @Test(arguments: [false, true])
    func admissionRefreshesAPressSnapshotWithoutTheSourceOnItsDisplay(sourceWasOnAnotherDisplay: Bool) {
        let system = FakeWindowSystem()
        let bounds = BTRect(x: -10_000, y: -10_000, width: 1_000, height: 800)
        system.availableDisplays = [DisplaySnapshot(id: DisplayID(rawValue: "main"),
            frame: bounds, visibleFrame: bounds)]
        system.addSecondWindow()
        system.windows[0].frame = BTRect(x: bounds.minX, y: bounds.minY, width: 500, height: 800)
        system.windows[1].frame = BTRect(x: bounds.midX, y: bounds.minY, width: 500, height: 800)
        let source = system.windows[0]
        if sourceWasOnAnotherDisplay {
            system.windows[0].displayID = DisplayID(rawValue: "other")
        } else {
            system.windows.removeFirst()
        }
        let controller = LinkedResizeController(coordinator: WindowCoordinator(system: system),
            configuration: BetterTileConfiguration(), displayTicks: ResizeDisplayLink(automatic: false))
        defer { controller.stop() }
        controller.isEnabledForDisplay = { _ in true }
        controller.setUsesSharedGestureEvents(true)
        let point = BTPoint(x: bounds.midX + 250, y: bounds.midY)
        controller.handleSharedGestureEvent(event(.leftMouseDown, at: point))
        #expect(system.visibleWindowsReadCount == 1)
        system.windows = [source, system.windows.last!]
        system.focusedWindowID = source.id
        controller.handleSharedGestureEvent(event(.leftMouseDragged, at: point))
        #expect(system.visibleWindowsReadCount == 2, "The cached source identity and display must both match")
        system.windows[0].frame.size.width = 430
        controller.handleSharedGestureEvent(event(.leftMouseDragged, at: point))
        controller.handleSharedGestureEvent(event(.leftMouseUp, at: point))
        #expect(system.windows[1].frame == BTRect(x: -9_570, y: -10_000, width: 570, height: 800))
        #expect(system.frameWriteCounts[source.id] == nil)
    }

    private func event(_ kind: GlobalGestureEventKind, at point: BTPoint) -> GlobalGestureEvent {
        GlobalGestureEvent(kind: kind, position: point, button: 0, modifiers: [], timestamp: 1)
    }
}
