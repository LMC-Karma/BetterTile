import AppKit
import Testing
@testable import BetterTileCore
@testable import BetterTileMacOS

@MainActor private func restingController(_ system: FakeWindowSystem) -> DragSnapController {
    let value = DragSnapController(coordinator: WindowCoordinator(system: system), configuration: .init(),
                                   displayTicks: ResizeDisplayLink(automatic: false))
    value.primaryButtonIsPressed = { true }
    value.setUsesSharedGestureEvents(true)
    return value
}
@MainActor private func restingSend(_ controller: DragSnapController, _ kind: GlobalGestureEventKind, x: Double, y: Double) {
    controller.handleSharedGestureEvent(.init(kind: kind, position: .init(x: x, y: y), button: 0, modifiers: [], timestamp: 1))
}

// Probe: The pointer reaches the edge before AX reports any movement, then rests.
@Test(.macOSTestApplication) @MainActor func probeLateMovementShowsSnapWithoutAnotherSample() {
    let system = FakeWindowSystem(), controller = restingController(system)
    defer { controller.cancel() }
    restingSend(controller, .leftMouseDown, x: 300, y: 220)
    restingSend(controller, .leftMouseDragged, x: 999, y: 400)
    #expect(controller.dropTarget == nil)
    system.windows[0].frame.origin.x += 20
    controller.displayTick()
    #expect(controller.dropTarget?.drop == .snap(.init(action: .rightHalf, frame: .init(x: 500, y: 0, width: 500, height: 800))),
            "The resting pointer needs a nudge after the window finally moves")
    #expect(system.frameWriteCounts.isEmpty)
    let reads = system.targetedSnapshotRequests
    for _ in 0..<3 { controller.displayTick() }
    #expect(system.targetedSnapshotRequests == reads, "An active drag needs no retry without a new sample")
    restingSend(controller, .leftMouseUp, x: 999, y: 400)
    #expect(system.windows[0].frame == .init(x: 500, y: 0, width: 500, height: 800))
}

// Probe: A targeted read omits the held window once, then recovers while the pointer rests.
@Test(.macOSTestApplication) @MainActor func probeRecoveredDragReadShowsSnapWithoutAnotherSample() {
    let system = FakeWindowSystem(), controller = restingController(system)
    defer { controller.cancel() }
    restingSend(controller, .leftMouseDown, x: 300, y: 220)
    system.windows[0].frame.origin.x += 20
    system.unreadableWindowIDs = [system.windows[0].id]
    restingSend(controller, .leftMouseDragged, x: 1, y: 400)
    #expect(controller.dropTarget == nil)
    system.unreadableWindowIDs = []
    controller.displayTick()
    #expect(controller.dropTarget?.drop == .snap(.init(action: .leftHalf, frame: .init(x: 0, y: 0, width: 500, height: 800))),
            "A recovered read needs a new pointer sample to show its snap")
}

// Probe: A Space change without a carried gesture must not suppress the next ordinary drag.
@Test(.macOSTestApplication) @MainActor func probeFirstDragAfterUncarriedDesktopSwitchSnaps() {
    let system = FakeWindowSystem(), controller = restingController(system)
    defer { controller.cancel() }
    controller.suspendForDesktopChange()
    controller.resumeAfterDesktopChange()
    restingSend(controller, .leftMouseDown, x: 300, y: 220)
    system.windows[0].frame.origin.x += 20
    restingSend(controller, .leftMouseDragged, x: 999, y: 400)
    restingSend(controller, .leftMouseUp, x: 999, y: 400)
    #expect(system.windows[0].frame == .init(x: 500, y: 0, width: 500, height: 800))
    #expect(!controller.isGestureActive)
}
// Probe: A late movement report must not revive a released or cancelled drag.
@Test(.macOSTestApplication, arguments: [false, true]) @MainActor
func probeEndedWaitingDragCannotReviveOnDisplayTick(cancel: Bool) {
    let system = FakeWindowSystem(), controller = restingController(system)
    defer { controller.cancel() }
    restingSend(controller, .leftMouseDown, x: 300, y: 220)
    restingSend(controller, .leftMouseDragged, x: 999, y: 400)
    if cancel { controller.cancel() }
    else { restingSend(controller, .leftMouseUp, x: 999, y: 400) }
    let reads = system.targetedSnapshotRequests
    system.windows[0].frame.origin.x += 20
    for _ in 0..<3 { controller.displayTick() }
    #expect(!controller.isGestureActive)
    #expect(controller.dropTarget == nil)
    #expect(system.targetedSnapshotRequests == reads)
    #expect(system.frameWriteCounts.isEmpty)
}

// Probe: Pointer movement without window movement must never arm snapping.
@Test(.macOSTestApplication) @MainActor func probeWaitingDragStillRequiresActualWindowMovement() {
    let system = FakeWindowSystem(), controller = restingController(system)
    defer { controller.cancel() }
    restingSend(controller, .leftMouseDown, x: 300, y: 220)
    restingSend(controller, .leftMouseDragged, x: 999, y: 400)
    for _ in 0..<3 { controller.displayTick() }
    #expect(controller.dropTarget == nil)
    #expect(system.frameWriteCounts.isEmpty)
    restingSend(controller, .leftMouseUp, x: 999, y: 400)
    #expect(system.frameWriteCounts.isEmpty)
}
