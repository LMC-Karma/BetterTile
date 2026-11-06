import AppKit
import Testing
@testable import BetterTileCore
@testable import BetterTileMacOS

/// Manual gestures use synthetic displays far outside the desktop.
@Suite(.macOSTestApplication, .serialized) @MainActor
struct LayoutCoreRegressionProbeTests {
    private let origin = BTPoint(x: -12_000, y: -12_000)

    private func system() -> FakeWindowSystem {
        let system = FakeWindowSystem()
        let frame = rect(0, 0, 1_000, 800)
        system.availableDisplays = [DisplaySnapshot(id: DisplayID(rawValue: "main"),
            frame: frame, visibleFrame: rect(60, 24, 940, 726), isMain: true)]
        system.windows[0].frame = rect(200, 200, 600, 400)
        return system
    }

    private func rect(_ x: Double, _ y: Double, _ width: Double, _ height: Double) -> BTRect {
        BTRect(x: origin.x + x, y: origin.y + y, width: width, height: height)
    }

    private func event(_ kind: GlobalGestureEventKind, _ x: Double, _ y: Double,
                       modifiers: ShortcutModifiers = []) -> GlobalGestureEvent {
        GlobalGestureEvent(kind: kind, position: BTPoint(x: origin.x + x, y: origin.y + y),
            button: 0, modifiers: modifiers, timestamp: 1)
    }

    private func startSnap(_ system: FakeWindowSystem, bottom: WindowAction? = nil) -> DragSnapController {
        var configuration = BetterTileConfiguration()
        if let bottom { configuration.snapAreaBindings = [.init(area: .bottom, action: bottom)] }
        let controller = DragSnapController(coordinator: WindowCoordinator(system: system),
            configuration: configuration)
        controller.setUsesSharedGestureEvents(true)
        controller.handleSharedGestureEvent(event(.leftMouseDown, 300, 220))
        system.windows[0].frame.origin.x += 3
        return controller
    }

    @Test(arguments: ["menu", "dock", "leftDock", "corner"])
    func snapFromReservedAreaMatchesShownFrame(area: String) throws {
        let system = system()
        let controller = startSnap(system, bottom: area == "dock" ? .bottomHalf : nil)
        defer { controller.cancel() }
        let point: (Double, Double) = switch area {
        case "menu": (500, 1)
        case "dock": (500, 799)
        case "leftDock": (1, 400)
        default: (1, 1)
        }
        controller.handleSharedGestureEvent(event(.leftMouseDragged, point.0, point.1))
        let drop = try #require(controller.dropTarget)
        guard case let .snap(target) = drop.drop else { Issue.record("Expected a snap preview"); return }
        #expect(target.frame.minX >= origin.x + 60)
        #expect(target.frame.minY >= origin.y + 24)
        #expect(target.frame.maxY <= origin.y + 750)
        controller.handleSharedGestureEvent(event(.leftMouseUp, point.0, point.1))
        #expect(system.windows[0].frame == target.frame)
        #expect(system.frameWriteCounts[system.windows[0].id] == 1)
    }

    @Test func sharedEdgeSnapUsesPointerDisplayWithWindowCenterOnSource() throws {
        let system = system()
        let other = DisplayID(rawValue: "east")
        system.availableDisplays.append(DisplaySnapshot(id: other,
            frame: rect(1_000, 0, 1_200, 900), visibleFrame: rect(1_000, 30, 1_200, 820)))
        let controller = startSnap(system)
        defer { controller.cancel() }
        controller.handleSharedGestureEvent(event(.leftMouseDragged, 1_000, 400))
        #expect(controller.dropTarget?.displayID == other)
        controller.handleSharedGestureEvent(event(.leftMouseUp, 1_000, 400))
        #expect(system.windows[0].frame == rect(1_000, 30, 600, 820))
    }

    @Test func suppressedDragCanSnapAfterModifierIsReleased() throws {
        let system = system()
        let controller = startSnap(system)
        defer { controller.cancel() }
        controller.handleSharedGestureEvent(event(.leftMouseDragged, 1, 400, modifiers: .option))
        #expect(controller.dropTarget == nil)
        controller.handleSharedGestureEvent(event(.leftMouseDragged, 999, 400))
        controller.handleSharedGestureEvent(event(.leftMouseUp, 999, 400))
        #expect(system.windows[0].frame == rect(530, 24, 470, 726))
    }

    @Test func quickReleaseDoesNotChooseANewZoneAfterPreview() throws {
        let system = system()
        let controller = startSnap(system)
        defer { controller.cancel() }
        controller.handleSharedGestureEvent(event(.leftMouseDragged, 1, 400))
        controller.handleSharedGestureEvent(event(.leftMouseUp, 999, 1))
        #expect(system.windows[0].frame == rect(60, 24, 470, 726))
    }

    @Test func minimumWidthSnapKeepsTheRightEdgeAndTheShownFrame() throws {
        let system = system()
        system.windows[0].constraints.minimumSize = BTSize(width: 650, height: 100)
        let controller = startSnap(system)
        defer { controller.cancel() }
        controller.handleSharedGestureEvent(event(.leftMouseDragged, 999, 400))
        let drop = try #require(controller.dropTarget)
        guard case let .snap(target) = drop.drop else { Issue.record("Expected a snap preview"); return }
        #expect(target.frame == rect(350, 24, 650, 726))
        controller.handleSharedGestureEvent(event(.leftMouseUp, 999, 400))
        #expect(system.windows[0].frame == target.frame)
    }

    @Test func disappearingSnapDisplayDoesNotWriteAStaleFrame() {
        let system = system()
        let controller = startSnap(system)
        defer { controller.cancel() }
        controller.handleSharedGestureEvent(event(.leftMouseDragged, 1, 400))
        let baseline = system.windows[0].frame
        system.availableDisplays = []
        controller.handleSharedGestureEvent(event(.leftMouseUp, 1, 400))
        #expect(system.frameWriteCounts.isEmpty)
        #expect(system.windows[0].frame == baseline)
    }

    @Test(arguments: [WindowAction.leftThird, .centerThird, .rightThird, .maximize, .almostMaximize])
    func exactActionUsesCurrentWorkAreaAfterDockMoves(action: WindowAction) throws {
        let system = system()
        let coordinator = WindowCoordinator(system: system)
        system.availableDisplays[0].visibleFrame = rect(0, 24, 940, 776)
        let plan = try #require(coordinator.planExact(action, for: system.windows[0].id).probeReadyPlan)
        let expected: BTRect = switch action {
        case .leftThird: rect(0, 24, 940.0 / 3, 776)
        case .centerThird: rect(940.0 / 3, 24, 940.0 / 3, 776)
        case .rightThird: rect(940.0 * 2 / 3, 24, 940.0 / 3, 776)
        case .maximize: rect(0, 24, 940, 776)
        default: rect(24, 48, 892, 728)
        }
        #expect(plan.targetFrame.approximatelyEquals(expected, tolerance: 0.001))
        #expect(coordinator.perform(plan).isApplied)
        #expect(system.windows[0].frame.approximatelyEquals(expected, tolerance: 0.001))
    }

    @Test(arguments: [WindowAction.nextDisplay, .previousDisplay])
    func displayTransferUsesNewArrangementOrder(action: WindowAction) throws {
        let system = system()
        let west = DisplayID(rawValue: "west")
        let east = DisplayID(rawValue: "east")
        system.availableDisplays += [
            DisplaySnapshot(id: east, frame: rect(1_000, 0, 1_000, 800), visibleFrame: rect(1_000, 0, 1_000, 800)),
            DisplaySnapshot(id: west, frame: rect(-1_000, 0, 1_000, 800), visibleFrame: rect(-1_000, 0, 1_000, 800))]
        let coordinator = WindowCoordinator(system: system)
        // Enumeration order differs from the newly arranged physical order.
        system.availableDisplays[1].frame = rect(-1_000, 0, 1_000, 800)
        system.availableDisplays[1].visibleFrame = system.availableDisplays[1].frame
        system.availableDisplays[2].frame = rect(1_000, 0, 1_000, 800)
        system.availableDisplays[2].visibleFrame = system.availableDisplays[2].frame
        let plan = try #require(coordinator.plan(action).probeReadyPlan)
        if action == .nextDisplay {
            #expect(plan.targetFrame.minX >= origin.x + 1_000)
        } else {
            #expect(plan.targetFrame.maxX <= origin.x)
        }
        #expect(coordinator.perform(plan).isApplied)
        #expect(system.windows[0].displayID == (action == .nextDisplay ? west : east))
    }

    @Test func failedActionLeavesRestoreHistoryIntact() throws {
        let system = system()
        let original = system.windows[0].frame
        let id = system.windows[0].id
        let coordinator = WindowCoordinator(system: system)
        #expect(coordinator.performProbeAction(.leftHalf))
        system.failedFrameWriteNumbers[id] = [2]
        #expect(!coordinator.performProbeAction(.rightHalf))
        #expect(coordinator.performProbeAction(.restore))
        #expect(system.windows[0].frame == original)
        #expect(coordinator.plan(.restore).probeReadyPlan == nil)
    }

    @Test func transferThenRestoreReturnsToOriginalDisplayAndFrame() {
        let system = system()
        let original = system.windows[0].frame
        system.availableDisplays.append(DisplaySnapshot(id: DisplayID(rawValue: "east"),
            frame: rect(1_000, 0, 1_600, 1_000), visibleFrame: rect(1_000, 30, 1_600, 900)))
        let coordinator = WindowCoordinator(system: system)
        #expect(coordinator.performProbeAction(.nextDisplay))
        #expect(coordinator.performProbeAction(.restore))
        #expect(system.windows[0].frame == original)
        #expect(system.windows[0].displayID == system.availableDisplays[0].id)
    }
}

@MainActor
private extension WindowCoordinator {
    func performProbeAction(_ action: WindowAction) -> Bool {
        guard case let .ready(plan) = plan(action) else { return false }
        return perform(plan).isApplied
    }
}

private extension WindowPlanOutcome {
    var probeReadyPlan: WindowActionPlan? {
        guard case let .ready(plan) = self else { return nil }
        return plan
    }
}
