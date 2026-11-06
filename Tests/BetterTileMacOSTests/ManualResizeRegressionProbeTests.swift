import AppKit
import Testing
@testable import BetterTileCore
@testable import BetterTileMacOS

@Suite(.macOSTestApplication, .serialized) @MainActor
struct ManualResizeRegressionProbeTests {
    private func fixture() -> FakeWindowSystem {
        let system = FakeWindowSystem()
        let bounds = BTRect(x: -10_000, y: -10_000, width: 1_000, height: 800)
        system.availableDisplays = [DisplaySnapshot(id: DisplayID(rawValue: "main"), frame: bounds, visibleFrame: bounds)]
        system.addSecondWindow()
        system.windows[0].frame = BTRect(x: bounds.minX, y: bounds.minY, width: 500, height: 800)
        system.windows[1].frame = BTRect(x: bounds.midX, y: bounds.minY, width: 500, height: 800)
        return system
    }

    private func divider(_ system: FakeWindowSystem, feedback: ResizeFeedbackMode) throws -> DividerOverlayController {
        var configuration = BetterTileConfiguration()
        configuration.resizeFeedbackMode = feedback
        let controller = DividerOverlayController(coordinator: WindowCoordinator(system: system), configuration: configuration)
        let bounds = system.availableDisplays[0].visibleFrame
        let boundary = BoundaryDescriptor(id: "manual", displayID: system.availableDisplays[0].id,
            axis: .vertical, coordinate: bounds.midX, spanStart: bounds.minY, spanEnd: bounds.maxY,
            beforeWindowIDs: [system.windows[0].id], afterWindowIDs: [system.windows[1].id])
        let point = BTPoint(x: bounds.midX, y: bounds.midY)
        let interaction = try #require(DividerInteractionResolver.resolve(at: point, in: [boundary],
            hitWidth: 18, adjacencyTolerance: 6))
        controller.beginGesture(interaction: interaction, at: point)
        try #require(controller.isDragging)
        return controller
    }

    private func point(_ delta: Double) throws -> CGPoint {
        CGPoint(x: -9_500 + delta, y: try #require(NSScreen.screens.first).frame.maxY + 9_600)
    }

    @Test(arguments: [ResizeFeedbackMode.live, .ghost])
    func dividerReleaseWithoutATickUsesFinalPointer(feedback: ResizeFeedbackMode) throws {
        let system = fixture()
        let controller = try divider(system, feedback: feedback)
        defer { controller.hideAndCancel() }
        controller.drag(to: try point(40))
        controller.end(at: try point(125))
        #expect(system.windows[0].frame.size.width == 625)
        #expect(system.windows[1].frame.size.width == 375)
        #expect(system.windows[0].frame.maxX == system.windows[1].frame.minX)
    }

    @Test(arguments: [ResizeFeedbackMode.live, .ghost])
    func dividerEscapeAfterDirectionChangeRestoresBothWindows(feedback: ResizeFeedbackMode) throws {
        let system = fixture()
        let baseline = system.windows.map(\.frame)
        let controller = try divider(system, feedback: feedback)
        defer { controller.hideAndCancel() }
        controller.drag(to: try point(130))
        controller.displayTick()
        controller.drag(to: try point(-80))
        controller.displayTick()
        controller.cancelActiveGesture()
        #expect(system.windows.map(\.frame) == baseline)
        #expect(!controller.isDragging)
    }

    @Test(arguments: [ResizeFeedbackMode.live, .ghost])
    func dividerMinimumClampCanReverseWithoutASecondGesture(feedback: ResizeFeedbackMode) throws {
        let system = fixture()
        system.windows[1].constraints.minimumSize = BTSize(width: 450, height: 100)
        let controller = try divider(system, feedback: feedback)
        defer { controller.hideAndCancel() }
        controller.drag(to: try point(200))
        controller.displayTick()
        #expect(controller.dragLimit.isLimited)
        controller.drag(to: try point(-100))
        controller.displayTick()
        controller.end()
        #expect(system.windows[0].frame.size.width == 400)
        #expect(system.windows[1].frame.size.width == 600)
    }

    @Test func nativeLinkedResizeFlushesReversedMovementBeforeFirstTick() {
        let system = fixture()
        var configuration = BetterTileConfiguration()
        configuration.linkedResizeEnabled = true
        let ticks = ResizeDisplayLink(automatic: false)
        let controller = LinkedResizeController(coordinator: WindowCoordinator(system: system),
            configuration: configuration, displayTicks: ticks)
        defer { controller.stop() }
        controller.isEnabledForDisplay = { _ in true }
        controller.setUsesSharedGestureEvents(true)
        func send(_ kind: GlobalGestureEventKind) {
            controller.handleSharedGestureEvent(GlobalGestureEvent(kind: kind,
                position: BTPoint(x: -9_500, y: -9_600), button: 0, modifiers: [], timestamp: 1))
        }
        send(.leftMouseDown)
        // Admit the gesture while the original shared boundary is observable.
        send(.leftMouseDragged)
        system.windows[0].frame.size.width = 560
        send(.leftMouseDragged)
        system.windows[0].frame.size.width = 430
        send(.leftMouseDragged)
        send(.leftMouseUp)
        #expect(system.windows[1].frame == BTRect(x: -9_570, y: -10_000, width: 570, height: 800))
    }

    @Test(arguments: [ResizeFeedbackMode.live, .ghost])
    func steppedWidthApplicationLandsNearDividerWithoutOverlap(feedback: ResizeFeedbackMode) throws {
        let system = fixture()
        system.roundsSizesAndReportsReadback = true
        // A cell-based application chooses the next smaller supported width.
        system.writeReadbackHandler = { id, requested, _, _ in
            guard let index = system.windows.firstIndex(where: { $0.id == id }) else { return }
            system.windows[index].frame.size.width = (requested.size.width / 10).rounded(.down) * 10
        }
        defer { system.writeReadbackHandler = nil }
        let controller = try divider(system, feedback: feedback)
        defer { controller.hideAndCancel() }
        controller.drag(to: try point(125))
        controller.displayTick()
        controller.end()
        #expect(system.windows[0].frame.size.width == 620)
        #expect(system.windows[1].frame.size.width == 370)
        #expect(system.windows[0].frame.maxX <= system.windows[1].frame.minX)
        let targets = [system.windows[0].id: BTRect(x: -10_000, y: -10_000, width: 625, height: 800),
                       system.windows[1].id: BTRect(x: -9_375, y: -10_000, width: 375, height: 800)]
        #expect(controller.windowsHaveLanded(targets, baseline: [:]))
        #expect(controller.releaseVerificationTask == nil)
    }
}
