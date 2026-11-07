import AppKit
import Testing
import BetterTileTestSupport
@testable import BetterTileCore
@testable import BetterTileMacOS

@MainActor private func restingController(_ system: FakeWindowSystem, clock: BetterTileClock = .live) -> DragSnapController {
    let value = DragSnapController(coordinator: WindowCoordinator(system: system), configuration: .init(),
                                   displayTicks: ResizeDisplayLink(automatic: false), clock: clock)
    value.primaryButtonIsPressed = { true }
    value.setUsesSharedGestureEvents(true)
    return value
}
@MainActor private func restingSend(_ controller: DragSnapController, _ kind: GlobalGestureEventKind, x: Double, y: Double) {
    controller.handleSharedGestureEvent(.init(kind: kind, position: .init(x: x, y: y), button: 0, modifiers: [], timestamp: 1))
}

// The pointer reaches the edge before AX reports any movement, then rests.
@Test(.macOSTestApplication) @MainActor func restingPointerShowsSnapAfterLateWindowMovement() {
    let clock = ManualClock()
    let system = FakeWindowSystem(), controller = restingController(system, clock: clock.clock)
    defer { controller.cancel() }
    restingSend(controller, .leftMouseDown, x: 300, y: 220)
    restingSend(controller, .leftMouseDragged, x: 999, y: 400)
    #expect(controller.dropTarget == nil)
    system.windows[0].frame.origin.x += 20
    clock.advance(by: .milliseconds(50))
    controller.displayTick()
    #expect(controller.dropTarget?.drop == .snap(.init(action: .rightHalf, frame: .init(x: 500, y: 0, width: 500, height: 800))),
            "Observed movement must show the snap while the pointer rests")
    #expect(system.frameWriteCounts.isEmpty)
    let reads = system.targetedSnapshotRequests
    for _ in 0..<3 {
        clock.advance(by: .milliseconds(50))
        controller.displayTick()
    }
    #expect(system.targetedSnapshotRequests == reads, "An active drag needs no retry without a new sample")
    restingSend(controller, .leftMouseUp, x: 999, y: 400)
    #expect(system.windows[0].frame == .init(x: 500, y: 0, width: 500, height: 800))
}

// A targeted read omits the held window once, then recovers while the pointer rests.
@Test(.macOSTestApplication) @MainActor func restingPointerShowsSnapAfterWindowReadRecovers() {
    let clock = ManualClock()
    let system = FakeWindowSystem(), controller = restingController(system, clock: clock.clock)
    defer { controller.cancel() }
    restingSend(controller, .leftMouseDown, x: 300, y: 220)
    system.windows[0].frame.origin.x += 20
    system.unreadableWindowIDs = [system.windows[0].id]
    restingSend(controller, .leftMouseDragged, x: 1, y: 400)
    #expect(controller.dropTarget == nil)
    system.unreadableWindowIDs = []
    clock.advance(by: .milliseconds(50))
    controller.displayTick()
    #expect(controller.dropTarget?.drop == .snap(.init(action: .leftHalf, frame: .init(x: 0, y: 0, width: 500, height: 800))),
            "A recovered window read must show the snap while the pointer rests")
}

// A Space change without a carried gesture must not suppress the next ordinary drag.
@Test(.macOSTestApplication) @MainActor func firstDragAfterUncarriedDesktopSwitchSnaps() {
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
// A late movement report must not revive a released or cancelled drag.
@Test(.macOSTestApplication, arguments: [false, true]) @MainActor
func endedWaitingDragCannotReviveOnDisplayTick(cancel: Bool) {
    let clock = ManualClock()
    let system = FakeWindowSystem(), controller = restingController(system, clock: clock.clock)
    defer { controller.cancel() }
    restingSend(controller, .leftMouseDown, x: 300, y: 220)
    restingSend(controller, .leftMouseDragged, x: 999, y: 400)
    if cancel { controller.cancel() }
    else { restingSend(controller, .leftMouseUp, x: 999, y: 400) }
    let reads = system.targetedSnapshotRequests
    system.windows[0].frame.origin.x += 20
    for _ in 0..<3 {
        clock.advance(by: .milliseconds(50))
        controller.displayTick()
    }
    #expect(!controller.isGestureActive)
    #expect(controller.dropTarget == nil)
    #expect(system.targetedSnapshotRequests == reads)
    #expect(system.frameWriteCounts.isEmpty)
}

// Pointer movement without window movement must never arm snapping.
@Test(.macOSTestApplication) @MainActor func waitingDragRequiresActualWindowMovement() {
    let clock = ManualClock()
    let system = FakeWindowSystem(), controller = restingController(system, clock: clock.clock)
    defer { controller.cancel() }
    restingSend(controller, .leftMouseDown, x: 300, y: 220)
    restingSend(controller, .leftMouseDragged, x: 999, y: 400)
    for _ in 0..<3 {
        clock.advance(by: .milliseconds(50))
        controller.displayTick()
    }
    #expect(controller.dropTarget == nil)
    #expect(system.frameWriteCounts.isEmpty)
    restingSend(controller, .leftMouseUp, x: 999, y: 400)
    #expect(system.frameWriteCounts.isEmpty)
}


@Test(.macOSTestApplication) @MainActor
func waitingDragObservationReadsAreThrottledAndExpire() {
    let clock = ManualClock()
    let system = FakeWindowSystem(), controller = restingController(system, clock: clock.clock)
    defer { controller.cancel() }
    restingSend(controller, .leftMouseDown, x: 300, y: 220)
    restingSend(controller, .leftMouseDragged, x: 999, y: 400)
    let initialReads = system.targetedSnapshotRequests
    for _ in 0..<120 {
        clock.advance(by: .milliseconds(10))
        controller.displayTick()
    }
    #expect(system.targetedSnapshotRequests - initialReads == 24, "Idle retries must be paced to 50 ms")
    for _ in 0..<880 {
        clock.advance(by: .milliseconds(10))
        controller.displayTick()
    }
    #expect(system.targetedSnapshotRequests - initialReads <= 60, "The three-second idle window must bound reads")
    let expiredReads = system.targetedSnapshotRequests
    system.windows[0].frame.origin.x += 20
    for _ in 0..<120 {
        clock.advance(by: .milliseconds(10))
        controller.displayTick()
    }
    #expect(system.targetedSnapshotRequests == expiredReads)
    #expect(controller.dropTarget == nil)
    #expect(system.frameWriteCounts.isEmpty)
    // A new sample starts a fresh observation window and still evaluates promptly.
    restingSend(controller, .leftMouseDragged, x: 999, y: 400)
    controller.displayTick()
    #expect(controller.dropTarget?.drop == .snap(.init(action: .rightHalf,
        frame: .init(x: 500, y: 0, width: 500, height: 800))))
}

@Test(.macOSTestApplication, arguments: [1, 2]) @MainActor
func carriedDragShowsSnapWhenMovementStartsAfterResume(switches: Int) {
    let clock = ManualClock()
    let system = FakeWindowSystem(), controller = restingController(system, clock: clock.clock)
    defer { controller.cancel() }
    restingSend(controller, .leftMouseDown, x: 300, y: 220)
    restingSend(controller, .leftMouseDragged, x: 999, y: 400)
    #expect(controller.dropTarget == nil)
    for _ in 0..<switches {
        controller.suspendForDesktopChange()
        let suspendedReads = system.targetedSnapshotRequests
        for _ in 0..<120 {
            clock.advance(by: .milliseconds(50))
            controller.displayTick()
        }
        #expect(system.targetedSnapshotRequests == suspendedReads)
        controller.resumeAfterDesktopChange()
        #expect(controller.carriedWindowID == system.windows[0].id)
        #expect(controller.dropTarget == nil, "Resuming alone must not bypass the movement gate")
    }
    system.windows[0].frame.origin.x += 20
    clock.advance(by: .milliseconds(50))
    controller.displayTick()
    #expect(controller.dropTarget?.drop == .snap(.init(action: .rightHalf,
        frame: .init(x: 500, y: 0, width: 500, height: 800))))
    #expect(system.frameWriteCounts.isEmpty)
}

@Test(.macOSTestApplication) @MainActor
func waitingDragObservationSkipsUnresponsiveApplications() {
    let clock = ManualClock()
    let system = FakeWindowSystem(), controller = restingController(system, clock: clock.clock)
    defer { controller.cancel() }
    restingSend(controller, .leftMouseDown, x: 300, y: 220)
    restingSend(controller, .leftMouseDragged, x: 999, y: 400)
    system.heldWindowIDs = [system.windows[0].id]
    let heldReads = system.targetedSnapshotRequests
    for _ in 0..<200 {
        clock.advance(by: .milliseconds(10))
        controller.displayTick()
    }
    #expect(system.targetedSnapshotRequests == heldReads, "A responsiveness hold must prevent targeted reads")
    #expect(controller.dropTarget == nil)
    system.heldWindowIDs = []
    system.windows[0].frame.origin.x += 20
    clock.advance(by: .milliseconds(50))
    controller.displayTick()
    #expect(controller.dropTarget?.drop == .snap(.init(action: .rightHalf,
        frame: .init(x: 500, y: 0, width: 500, height: 800))))
    #expect(system.frameWriteCounts.isEmpty)
}


@Test(.macOSTestApplication) @MainActor
func aNewDragSampleRenewsTheIdleObservationWindow() {
    let clock = ManualClock()
    let system = FakeWindowSystem(), controller = restingController(system, clock: clock.clock)
    defer { controller.cancel() }
    restingSend(controller, .leftMouseDown, x: 300, y: 220)
    restingSend(controller, .leftMouseDragged, x: 999, y: 400)
    clock.advance(by: .seconds(4))
    let expiredReads = system.targetedSnapshotRequests
    controller.displayTick()
    #expect(system.targetedSnapshotRequests == expiredReads)
    restingSend(controller, .leftMouseDragged, x: 1, y: 400)
    controller.displayTick()
    #expect(controller.dropTarget == nil)
    clock.advance(by: .milliseconds(2500))
    system.windows[0].frame.origin.x += 20
    controller.displayTick()
    #expect(controller.dropTarget?.drop == .snap(.init(action: .leftHalf,
        frame: .init(x: 0, y: 0, width: 500, height: 800))))
    #expect(system.frameWriteCounts.isEmpty)
}
