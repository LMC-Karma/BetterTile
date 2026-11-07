import AppKit
import Testing
import BetterTileTestSupport
@testable import BetterTileCore
@testable import BetterTileMacOS

// A window drag can carry its window to another desktop: macOS switches
// desktops when the pointer is held at the screen edge. The drag then
// suspends for the desktop change and resumes on the destination desktop.

@MainActor private func controller(
    _ system: FakeWindowSystem, buttonPressed: @escaping () -> Bool = { true }
) -> DragSnapController {
    let controller = DragSnapController(coordinator: WindowCoordinator(system: system),
                                        configuration: BetterTileConfiguration(),
                                        displayTicks: ResizeDisplayLink(automatic: false))
    controller.primaryButtonIsPressed = buttonPressed
    controller.setUsesSharedGestureEvents(true)
    return controller
}

@MainActor private func send(_ controller: DragSnapController, _ kind: GlobalGestureEventKind, x: Double, y: Double = 400) {
    controller.handleSharedGestureEvent(GlobalGestureEvent(
        kind: kind, position: BTPoint(x: x, y: y), button: 0, modifiers: [], timestamp: 1
    ))
}

/// Starts an ordinary drag of the first window and moves it to the middle of
/// the display, away from every snap area.
@MainActor private func beginDrag(_ controller: DragSnapController, _ system: FakeWindowSystem) {
    send(controller, .leftMouseDown, x: 300, y: 220)
    system.windows[0].frame.origin.x += 3
    send(controller, .leftMouseDragged, x: 500, y: 400)
}

private let rightHalf = BTRect(x: 500, y: 0, width: 500, height: 800)

/// After the desktop change, the drag resolves targets again: a sample at the
/// right edge shows the right half, and release applies it.
@Test(.macOSTestApplication) @MainActor func aResumedDragSnapsOnTheDestinationDesktop() {
    let system = FakeWindowSystem()
    let controller = controller(system)
    defer { controller.cancel() }
    beginDrag(controller, system)
    #expect(controller.dropTarget == nil)

    controller.suspendForDesktopChange()
    controller.resumeAfterDesktopChange()
    send(controller, .leftMouseDragged, x: 999)
    // Resume evaluated the last sample; later samples run on display ticks.
    controller.displayTick()
    #expect(controller.dropTarget?.drop == .snap(SnapTarget(action: .rightHalf, frame: rightHalf)),
            "The resumed drag shows no snap on the destination desktop")
    send(controller, .leftMouseUp, x: 999)
    #expect(system.windows[0].frame == rightHalf)
    #expect(!controller.isGestureActive)
}

/// The pointer can rest in a snap area while the desktop changes. Resume
/// evaluates the newest sample at once, so the preview shows without another
/// pointer move.
@Test(.macOSTestApplication) @MainActor func resumeEvaluatesTheNewestSampleAtOnce() {
    let system = FakeWindowSystem()
    let controller = controller(system)
    defer { controller.cancel() }
    beginDrag(controller, system)
    controller.suspendForDesktopChange()
    send(controller, .leftMouseDragged, x: 700)
    send(controller, .leftMouseDragged, x: 999)
    controller.resumeAfterDesktopChange()
    #expect(controller.dropTarget?.drop == .snap(SnapTarget(action: .rightHalf, frame: rightHalf)))
}

/// A suspended drag shows no preview and records no drop, even from a queued
/// display tick.
@Test(.macOSTestApplication) @MainActor func aSuspendedDragShowsNoSnapPreview() {
    let system = FakeWindowSystem()
    let controller = controller(system)
    defer { controller.cancel() }
    send(controller, .leftMouseDown, x: 300, y: 220)
    system.windows[0].frame.origin.x += 3
    send(controller, .leftMouseDragged, x: 1)
    #expect(controller.dropTarget != nil)

    controller.suspendForDesktopChange()
    #expect(controller.dropTarget == nil)
    #expect(controller.isGestureActive, "Suspending ended the gesture")
    send(controller, .leftMouseDragged, x: 999)
    controller.displayTick()
    #expect(controller.dropTarget == nil)
    #expect(controller.isGestureActive)
}

/// A release while the drag is suspended applies nothing and ends the gesture.
@Test(.macOSTestApplication) @MainActor func aReleaseWhileSuspendedAppliesNothing() {
    let system = FakeWindowSystem()
    var pressed = true
    let controller = controller(system) { pressed }
    var ended = 0
    controller.gestureEndedHandler = { ended += 1 }
    send(controller, .leftMouseDown, x: 300, y: 220)
    system.windows[0].frame.origin.x += 3
    send(controller, .leftMouseDragged, x: 1)
    let dragged = system.windows[0].frame

    controller.suspendForDesktopChange()
    #expect(ended == 0)
    pressed = false
    send(controller, .leftMouseUp, x: 999)
    #expect(system.windows[0].frame == dragged)
    #expect(system.frameWriteCounts.isEmpty)
    #expect(!controller.isGestureActive)
    #expect(ended == 1)
    // The stabilization that suspended the drag still ends.
    controller.resumeAfterDesktopChange()
    #expect(ended == 1)
}

/// The button can come up without a release event reaching BetterTile, for
/// example while macOS changes desktops. Resume then ends the gesture with no
/// drop.
@Test(.macOSTestApplication) @MainActor func resumeWithTheButtonReleasedEndsTheGesture() {
    let system = FakeWindowSystem()
    var pressed = true
    let controller = controller(system) { pressed }
    var ended = 0
    controller.gestureEndedHandler = { ended += 1 }
    beginDrag(controller, system)
    controller.suspendForDesktopChange()
    send(controller, .leftMouseDragged, x: 999)
    pressed = false
    controller.resumeAfterDesktopChange()
    #expect(!controller.isGestureActive)
    #expect(controller.dropTarget == nil)
    #expect(system.frameWriteCounts.isEmpty)
    #expect(ended == 1)
}

/// With the button up there is no drag to keep, so a desktop change cancels.
@Test(.macOSTestApplication) @MainActor func suspendWithTheButtonUpCancels() {
    let system = FakeWindowSystem()
    var pressed = true
    let controller = controller(system) { pressed }
    var ended = 0
    controller.gestureEndedHandler = { ended += 1 }
    beginDrag(controller, system)
    pressed = false
    controller.suspendForDesktopChange()
    #expect(!controller.isGestureActive)
    #expect(ended == 1)
}

/// The Adaptive drag belongs to the desktop where it began. Suspending ends it
/// once with a restore, which the model writes nothing for on a changed
/// desktop. The window drag continues.
@Test(.macOSTestApplication) @MainActor func suspendEndsTheSourceDesktopsAdaptiveDragOnce() {
    let system = FakeWindowSystem()
    system.addSecondWindow()
    let display = system.availableDisplays[0].id
    let source = system.windows[0].id, peer = system.windows[1].id
    let controller = controller(system)
    defer { controller.cancel() }
    let layout = BentoLayoutState(root: .partition(BentoPartition(axis: .vertical,
        children: [.leaf(source), .leaf(peer)])), metrics: BentoLayoutMetrics(paneGap: 0))
    controller.activeModeProvider = { _ in .bento }
    controller.bentoStateProvider = { _ in layout }
    var began: [DisplayID] = []
    controller.bentoDragBeganHandler = { displayID, _, _ in began.append(displayID); return true }
    controller.bentoPreviewHandler = { _, _, _ in nil }
    var ends: [LayoutDragEnd] = []
    controller.bentoDragEndedHandler = { _, _, end in ends.append(end) }
    beginDrag(controller, system)
    #expect(began == [display])

    controller.suspendForDesktopChange()
    #expect(ends == [.restore])
    #expect(controller.isGestureActive)
    controller.suspendForDesktopChange()
    send(controller, .leftMouseUp, x: 500)
    #expect(ends == [.restore], "A release after suspension ended the Adaptive drag again")
}

/// The destination desktop decides the drop. A Manual destination after an
/// Adaptive source offers the plain snap areas.
@Test(.macOSTestApplication) @MainActor func anAdaptiveDragResumedOnAManualDesktopUsesPlainSnapAreas() {
    let system = FakeWindowSystem()
    system.addSecondWindow()
    let source = system.windows[0].id, peer = system.windows[1].id
    let controller = controller(system)
    defer { controller.cancel() }
    var destination = false
    let layout = BentoLayoutState(root: .partition(BentoPartition(axis: .vertical,
        children: [.leaf(source), .leaf(peer)])), metrics: BentoLayoutMetrics(paneGap: 0))
    controller.activeModeProvider = { _ in destination ? .manual : .bento }
    controller.bentoStateProvider = { _ in destination ? nil : layout }
    controller.bentoDragBeganHandler = { _, _, _ in true }
    controller.bentoPreviewHandler = { _, _, _ in nil }
    var ends: [LayoutDragEnd] = []
    controller.bentoDragEndedHandler = { _, _, end in ends.append(end) }
    beginDrag(controller, system)

    controller.suspendForDesktopChange()
    destination = true
    // The other desktop's windows are not under the pointer.
    system.windows.removeAll { $0.id == peer }
    controller.resumeAfterDesktopChange()
    send(controller, .leftMouseDragged, x: 999)
    // Resume evaluated the last sample; later samples run on display ticks.
    controller.displayTick()
    #expect(controller.dropTarget?.drop == .snap(SnapTarget(action: .rightHalf, frame: rightHalf)))
    send(controller, .leftMouseUp, x: 999)
    #expect(system.windows[0].frame == rightHalf)
    #expect(ends == [.restore])
}

/// A Manual drag resumed on an Adaptive desktop starts an Adaptive drag there
/// for the dragged window, and release commits the snap plan it showed.
@Test(.macOSTestApplication) @MainActor func aManualDragResumedOnAnAdaptiveDesktopStartsAnAdaptiveDrag() {
    let system = FakeWindowSystem()
    system.addSecondWindow()
    let display = system.availableDisplays[0].id
    let source = system.windows[0].id, peer = system.windows[1].id
    let controller = controller(system)
    defer { controller.cancel() }
    var destination = false
    // The destination layout does not hold the dragged window.
    let layout = BentoLayoutState(root: .leaf(peer), metrics: BentoLayoutMetrics(paneGap: 0))
    controller.activeModeProvider = { _ in destination ? .bento : .manual }
    controller.bentoStateProvider = { _ in destination ? layout : nil }
    var began: [WindowID] = []
    controller.bentoDragBeganHandler = { _, id, _ in began.append(id); return true }
    let planned = [Placement(windowID: source, frame: rightHalf)]
    controller.bentoPreviewHandler = { _, _, outcome in
        .ready(PreparedLayoutDrop(outcome: outcome, placements: planned, plan: .frame, dragID: UUID()))
    }
    var ends: [LayoutDragEnd] = []
    controller.bentoDragEndedHandler = { _, _, end in ends.append(end) }
    beginDrag(controller, system)
    #expect(began.isEmpty)

    controller.suspendForDesktopChange()
    destination = true
    controller.resumeAfterDesktopChange()
    send(controller, .leftMouseDragged, x: 999)
    // Resume evaluated the last sample; later samples run on display ticks.
    controller.displayTick()
    #expect(began == [source])
    guard case let .layout(plan)? = controller.dropTarget?.drop else {
        Issue.record("The resumed drag shows no Adaptive snap plan"); return
    }
    #expect(controller.dropTarget?.displayID == display)
    send(controller, .leftMouseUp, x: 999)
    #expect(ends == [.commit(plan)])
}

/// When the destination desktop refuses the Adaptive drag, for example
/// because its layout cannot freeze, the plain snap areas stay available.
@Test(.macOSTestApplication) @MainActor func aRefusedDestinationAdaptiveDragFallsBackToPlainSnapAreas() {
    let system = FakeWindowSystem()
    system.addSecondWindow()
    let peer = system.windows[1].id
    let controller = controller(system)
    defer { controller.cancel() }
    var destination = false
    let layout = BentoLayoutState(root: .leaf(peer), metrics: BentoLayoutMetrics(paneGap: 0))
    controller.activeModeProvider = { _ in destination ? .bento : .manual }
    controller.bentoStateProvider = { _ in destination ? layout : nil }
    controller.bentoDragBeganHandler = { _, _, _ in false }
    beginDrag(controller, system)
    controller.suspendForDesktopChange()
    destination = true
    controller.resumeAfterDesktopChange()
    send(controller, .leftMouseDragged, x: 999)
    // Resume evaluated the last sample; later samples run on display ticks.
    controller.displayTick()
    #expect(controller.isGestureActive)
    #expect(controller.dropTarget?.drop == .snap(SnapTarget(action: .rightHalf, frame: rightHalf)))
    send(controller, .leftMouseUp, x: 999)
    #expect(system.windows[0].frame == rightHalf)
}

/// Holding the pointer at the edge can switch desktops again. Each change
/// suspends and resumes the same drag.
@Test(.macOSTestApplication) @MainActor func aDragSurvivesTwoDesktopChanges() {
    let system = FakeWindowSystem()
    let controller = controller(system)
    defer { controller.cancel() }
    beginDrag(controller, system)
    for _ in 0..<2 {
        controller.suspendForDesktopChange()
        send(controller, .leftMouseDragged, x: 999)
        #expect(controller.dropTarget == nil)
        controller.resumeAfterDesktopChange()
        #expect(controller.dropTarget?.drop == .snap(SnapTarget(action: .rightHalf, frame: rightHalf)))
    }
    send(controller, .leftMouseDragged, x: 1)
    controller.displayTick()
    send(controller, .leftMouseUp, x: 1)
    #expect(system.windows[0].frame == BTRect(x: 0, y: 0, width: 500, height: 800))
}

/// Escape still cancels a suspended drag, and a later resume does nothing.
@Test(.macOSTestApplication) @MainActor func cancellingASuspendedDragEndsIt() {
    let system = FakeWindowSystem()
    let controller = controller(system)
    beginDrag(controller, system)
    controller.suspendForDesktopChange()
    controller.cancel()
    controller.resumeAfterDesktopChange()
    send(controller, .leftMouseDragged, x: 999)
    // Resume evaluated the last sample; later samples run on display ticks.
    controller.displayTick()
    send(controller, .leftMouseUp, x: 999)
    #expect(!controller.isGestureActive)
    #expect(system.frameWriteCounts.isEmpty)
}

/// The pointer rests at the edge while macOS changes desktops, so no drag
/// event arrives during the change. A display tick already evaluated the last
/// sample. Resume evaluates that sample again on the destination desktop, so
/// the preview shows without another pointer move, also after a second change.
@Test(.macOSTestApplication) @MainActor func resumeShowsThePreviewForARestingPointer() {
    let system = FakeWindowSystem()
    let controller = controller(system)
    defer { controller.cancel() }
    beginDrag(controller, system)
    send(controller, .leftMouseDragged, x: 999)
    #expect(controller.hasPendingDragSample)
    controller.displayTick()
    #expect(!controller.hasPendingDragSample, "The display tick did not consume the edge sample")
    #expect(controller.dropTarget?.drop == .snap(SnapTarget(action: .rightHalf, frame: rightHalf)))

    for change in 1...2 {
        controller.suspendForDesktopChange()
        #expect(controller.dropTarget == nil)
        controller.resumeAfterDesktopChange()
        #expect(controller.dropTarget?.drop == .snap(SnapTarget(action: .rightHalf, frame: rightHalf)),
                "No preview after desktop change \(change) with a resting pointer")
    }
    send(controller, .leftMouseUp, x: 999)
    #expect(system.windows[0].frame == rightHalf)
}

/// The held window can be unreadable just after the desktop change. The drag
/// keeps the gesture and reads the window again on the next display tick,
/// even while the pointer rests; a new sample also retries.
@Test(.macOSTestApplication) @MainActor func aFailedDestinationReadRetriesWithARestingPointer() {
    let system = FakeWindowSystem()
    let controller = controller(system)
    defer { controller.cancel() }
    beginDrag(controller, system)
    send(controller, .leftMouseDragged, x: 999)
    controller.displayTick()

    controller.suspendForDesktopChange()
    system.targetedSnapshotsFail = true
    controller.resumeAfterDesktopChange()
    #expect(controller.isGestureActive, "An unreadable window ended the drag")
    #expect(controller.dropTarget == nil)
    controller.displayTick()
    #expect(controller.dropTarget == nil)
    system.targetedSnapshotsFail = false
    controller.displayTick()
    #expect(controller.dropTarget?.drop == .snap(SnapTarget(action: .rightHalf, frame: rightHalf)),
            "The resting pointer never retried the destination read")

    // Again with a new sample instead of a tick.
    controller.suspendForDesktopChange()
    system.targetedSnapshotsFail = true
    controller.resumeAfterDesktopChange()
    #expect(controller.dropTarget == nil)
    system.targetedSnapshotsFail = false
    send(controller, .leftMouseDragged, x: 999)
    #expect(controller.dropTarget?.drop == .snap(SnapTarget(action: .rightHalf, frame: rightHalf)))
}

/// The drag names the window it carried to another desktop until the gesture
/// ends, so the destination layout can hold back automatic placement.
@Test(.macOSTestApplication) @MainActor func theCarriedWindowIsKnownUntilTheGestureEnds() {
    let system = FakeWindowSystem()
    let controller = controller(system)
    beginDrag(controller, system)
    #expect(controller.carriedWindowID == nil)
    controller.suspendForDesktopChange()
    #expect(controller.carriedWindowID == system.windows[0].id)
    controller.resumeAfterDesktopChange()
    #expect(controller.carriedWindowID == system.windows[0].id)
    send(controller, .leftMouseUp, x: 500)
    #expect(controller.carriedWindowID == nil)

    beginDrag(controller, system)
    controller.suspendForDesktopChange()
    controller.cancel()
    #expect(controller.carriedWindowID == nil)
}

/// While the held window stays unreadable after the desktop change, each
/// display tick reads it once. The retry stops when the gesture ends by a
/// release or by a cancel: later ticks read nothing.
@Test(.macOSTestApplication, arguments: ["release", "cancel"]) @MainActor
func theDestinationReadRetryStopsWhenTheGestureEnds(ending: String) {
    let system = FakeWindowSystem()
    let controller = controller(system)
    defer { controller.cancel() }
    beginDrag(controller, system)
    controller.suspendForDesktopChange()
    system.targetedSnapshotsFail = true
    controller.resumeAfterDesktopChange()
    let afterResume = system.targetedSnapshotRequests
    controller.displayTick()
    controller.displayTick()
    #expect(system.targetedSnapshotRequests == afterResume + 2, "One read per display tick")
    let frame = system.windows[0].frame
    if ending == "release" { send(controller, .leftMouseUp, x: 999) } else { controller.cancel() }
    #expect(!controller.isGestureActive)
    let afterEnd = system.targetedSnapshotRequests
    system.targetedSnapshotsFail = false
    for _ in 0..<5 { controller.displayTick() }
    #expect(system.targetedSnapshotRequests == afterEnd, "The read retry continued after the gesture ended")
    #expect(system.windows[0].frame == frame, "The ended gesture still placed the window")
    #expect(controller.dropTarget == nil)
}
