import BetterTileCore
import Testing
@testable import BetterTileMacOS

@Test func gestureSourceGateAcceptsExactlyOneSource() {
    var gate = GestureEventSourceGate()

    #expect(gate.accepts(.nsEvent))
    #expect(!gate.accepts(.eventTap))

    gate.setUsesEventTap(true)
    #expect(!gate.accepts(.nsEvent))
    #expect(gate.accepts(.eventTap))
}

@Test func gestureSourceTransitionsDoNotDuplicateTheGestureSequence() {
    var gate = GestureEventSourceGate()
    var delivered: [GlobalGestureEventKind] = []

    func deliver(_ kind: GlobalGestureEventKind, from source: GestureEventSource) {
        if gate.accepts(source) { delivered.append(kind) }
    }

    deliver(.leftMouseDown, from: .nsEvent)
    gate.setUsesEventTap(true)
    deliver(.leftMouseDragged, from: .nsEvent)
    deliver(.leftMouseDragged, from: .eventTap)
    gate.setUsesEventTap(false)
    deliver(.leftMouseUp, from: .eventTap)
    deliver(.leftMouseUp, from: .nsEvent)

    #expect(delivered == [.leftMouseDown, .leftMouseDragged, .leftMouseUp])
}

@Test func restartedTapRejectsEventsQueuedByTheStoppedWorker() {
    var gate = GestureEventGenerationGate()
    let stoppedGeneration = gate.begin()
    gate.end()
    let activeGeneration = gate.begin()

    #expect(!gate.accepts(stoppedGeneration))
    #expect(gate.accepts(activeGeneration))
}

@Test func gestureTapRecoveryResumesOnlyWhenReenableSucceeds() {
    #expect(GestureEventTapRecovery.action(isEnabledAfterRecovery: true) == .resume)
    #expect(GestureEventTapRecovery.action(isEnabledAfterRecovery: false) == .fallBack)
}

@Test func sharedGestureEventContainsOnlyScalarInputData() {
    let event = GlobalGestureEvent(
        kind: .leftMouseDragged,
        position: BTPoint(x: 20, y: 30),
        button: 0,
        modifiers: [.command, .shift],
        timestamp: 42
    )

    #expect(event.position == BTPoint(x: 20, y: 30))
    #expect(event.button == 0)
    #expect(event.modifiers == [.command, .shift])
    #expect(event.timestamp == 42)
}

@Test @MainActor func sharedGestureMonitorStopsCleanlyWithOrWithoutTapAccess() {
    let monitor = SharedGestureEventMonitor()
    let started = monitor.start()

    #expect(monitor.isUsingEventTap == started)
    monitor.stop()
    #expect(!monitor.isUsingEventTap)
}
