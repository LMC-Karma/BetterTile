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
        system.focusedWindowID = system.windows[0].id
        system.windows[0].frame.size.width = firstWidth
        send(.leftMouseDragged, 2)
        system.windows[0].frame.size.width = 430
        send(.leftMouseDragged, 3)
        send(.leftMouseUp, 4)
        #expect(system.windows[1].frame == BTRect(x: -9_570, y: -10_000, width: 570, height: 800))
        #expect(system.windows[0].frame.size.width == 430)
        #expect(system.frameWriteCounts[system.windows[0].id] == nil,
                "The application owns the source resize")
        #expect(!controller.isResizing)
    }
}
