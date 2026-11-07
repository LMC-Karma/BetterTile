import AppKit
import BetterTileCore
import CoreGraphics
import Foundation
import Testing
@testable import BetterTileMacOS

@Test(.macOSTestApplication) func gestureSourceGateAcceptsExactlyOneSource() {
    var gate = GestureEventSourceGate()

    #expect(gate.accepts(.nsEvent))
    #expect(!gate.accepts(.eventTap))

    gate.setUsesEventTap(true)
    #expect(!gate.accepts(.nsEvent))
    #expect(gate.accepts(.eventTap))
}

@Test(.macOSTestApplication) func gestureSourceTransitionsDoNotDuplicateTheGestureSequence() {
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

@Test(.macOSTestApplication) func restartedTapRejectsEventsQueuedByTheStoppedWorker() {
    var gate = GestureEventGenerationGate()
    let stoppedGeneration = gate.begin()
    gate.end()
    let activeGeneration = gate.begin()

    #expect(!gate.accepts(stoppedGeneration))
    #expect(gate.accepts(activeGeneration))
}

@Test(.macOSTestApplication) func gestureTapRecoveryResumesOnlyWhenReenableSucceeds() {
    #expect(GestureEventTapRecovery.action(isEnabledAfterRecovery: true) == .resume)
    #expect(GestureEventTapRecovery.action(isEnabledAfterRecovery: false) == .fallBack)
}

@Test(.macOSTestApplication, arguments: [false, true]) @MainActor
func sharedGestureMonitorStopsAnInjectedWorkerWhetherStartSucceeds(canStart: Bool) {
    let log = GestureEventTapWorkerLog()
    log.canStart = canStart
    let monitor = makeCooldownMonitor(log: log, clock: GestureEventTapTestClock())

    #expect(monitor.start() == canStart)
    #expect(monitor.isUsingEventTap == canStart)
    let stopsBefore = log.stops
    monitor.stop()
    #expect(!monitor.isUsingEventTap)
    #expect(log.stops == stopsBefore + (canStart ? 1 : 0))
}

@Test(.macOSTestApplication) func gestureSourceHandoffDefersOnlyTheSwitchToTheEventTap() {
    var handoff = GestureEventSourceHandoff()

    // No active gesture: the switch to the event tap applies now.
    var appliesNow = handoff.request(
        usesEventTap: true,
        currentlyUsesEventTap: false,
        isGestureActive: false
    )
    #expect(appliesNow)
    #expect(!handoff.isPending)

    // Falling back to NSEvent always applies now, even mid-gesture.
    appliesNow = handoff.request(
        usesEventTap: false,
        currentlyUsesEventTap: true,
        isGestureActive: true
    )
    #expect(appliesNow)
    #expect(!handoff.isPending)

    // Taking over an active gesture waits for it to end.
    appliesNow = handoff.request(
        usesEventTap: true,
        currentlyUsesEventTap: false,
        isGestureActive: true
    )
    #expect(!appliesNow)
    #expect(handoff.isPending)

    var resolved = handoff.resolve()
    #expect(resolved)
    resolved = handoff.resolve()
    #expect(!resolved)

    // A cleared handoff cannot enable monitoring later.
    _ = handoff.request(
        usesEventTap: true,
        currentlyUsesEventTap: false,
        isGestureActive: true
    )
    handoff.clear()
    resolved = handoff.resolve()
    #expect(!resolved)
}

@Test(.macOSTestApplication) func gestureTapRetryGateBoundsRepeatedFailures() {
    var gate = GestureEventTapRetryGate(cooldown: 30)

    #expect(gate.allowsStart(at: 0))
    gate.recordFailure(at: 0)
    #expect(!gate.allowsStart(at: 29.9))
    #expect(gate.allowsStart(at: 30))

    gate.recordFailure(at: 30)
    #expect(!gate.allowsStart(at: 59))
    gate.recordSuccess()
    #expect(gate.allowsStart(at: 59))
}

@Test(.macOSTestApplication) @MainActor func failedTapStartIsSuppressedForTheRetryCooldown() {
    let log = GestureEventTapWorkerLog()
    let clock = GestureEventTapTestClock()
    let monitor = makeCooldownMonitor(log: log, clock: clock)

    #expect(!monitor.start())
    #expect(log.startAttempts == 1)

    clock.time = 29
    #expect(!monitor.start())
    #expect(!monitor.start())

    #expect(log.startAttempts == 1)
    #expect(!monitor.isUsingEventTap)
}

@Test(.macOSTestApplication) @MainActor func tapStartIsRetriedAfterTheCooldownExpires() {
    let log = GestureEventTapWorkerLog()
    let clock = GestureEventTapTestClock()
    let monitor = makeCooldownMonitor(log: log, clock: clock)

    #expect(!monitor.start())
    clock.time = 30
    #expect(!monitor.start())

    #expect(log.startAttempts == 2)
}

@Test(.macOSTestApplication) @MainActor func successfulTapStartClearsTheRetryCooldown() {
    let log = GestureEventTapWorkerLog()
    let clock = GestureEventTapTestClock()
    let monitor = makeCooldownMonitor(log: log, clock: clock)

    #expect(!monitor.start())
    clock.time = 30
    log.canStart = true
    #expect(monitor.start())
    #expect(monitor.isUsingEventTap)

    // An intentional stop is not a failure, so the next start is immediate.
    monitor.stop()
    #expect(monitor.start())
    #expect(log.startAttempts == 3)
}

@Test(.macOSTestApplication) @MainActor func failedTapRecoveryStartsTheRetryCooldown() async {
    let log = GestureEventTapWorkerLog()
    let clock = GestureEventTapTestClock()
    log.canStart = true
    let monitor = makeCooldownMonitor(log: log, clock: clock)

    #expect(monitor.start())
    #expect(log.startAttempts == 1)

    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        monitor.fallbackHandler = { continuation.resume() }
        log.handlers[0](.fallback)
    }

    #expect(!monitor.isUsingEventTap)
    #expect(!monitor.start())
    #expect(log.startAttempts == 1)
}

@MainActor
private func makeCooldownMonitor(
    log: GestureEventTapWorkerLog,
    clock: GestureEventTapTestClock,
    cooldown: TimeInterval = 30
) -> SharedGestureEventMonitor {
    SharedGestureEventMonitor(
        cooldown: cooldown,
        now: { clock.time },
        makeWorker: { handler in
            log.handlers.append(handler)
            return FakeGestureEventTapWorker(log: log)
        }
    )
}

private final class GestureEventTapTestClock: @unchecked Sendable {
    var time: TimeInterval = 0
}

/// Records every worker the monitor builds so a test can count start attempts
/// without waiting on a real event tap.
private final class GestureEventTapWorkerLog: @unchecked Sendable {
    var canStart = false
    var startAttempts = 0
    var stops = 0
    var handlers: [@Sendable (GestureEventTapMessage) -> Void] = []
}

private final class FakeGestureEventTapWorker: GestureEventTapWorking {
    private let log: GestureEventTapWorkerLog

    init(log: GestureEventTapWorkerLog) {
        self.log = log
    }

    func start() -> Bool {
        log.startAttempts += 1
        return log.canStart
    }

    func stop() {
        log.stops += 1
    }
}

@Test(.macOSTestApplication) func gestureLatencyMeasuresTheDeliveryIntervalWithTheCGEventClock() {
    let timestamp: CGEventTimestamp = 1_000

    #expect(GestureEventClock.nanoseconds(cgEventTimestamp: timestamp) == timestamp)
    #expect(GestureEventLatency.nanoseconds(
        eventTimestamp: GestureEventClock.nanoseconds(cgEventTimestamp: timestamp),
        deliveredAt: 3_500
    ) == 2_500)
}

@Test(.macOSTestApplication) func gestureLatencyRejectsAnUnusableOrMismatchedClock() {
    // A source that reports no time cannot be measured.
    #expect(GestureEventLatency.nanoseconds(
        eventTimestamp: 0,
        deliveredAt: 3_500
    ) == nil)

    // Delivery before the event means the two values came from different
    // clocks. Recording that as a latency would corrupt the comparison.
    #expect(GestureEventLatency.nanoseconds(
        eventTimestamp: 3_500,
        deliveredAt: 1_000
    ) == nil)
}

@Test(.macOSTestApplication) func gestureLatencySignpostNamesStayStableForTraceQueries() {
    // The measurement recipe in docs/BENTO_TESTING.md greps these names.
    #expect(GestureEventSource.eventTap.signpostName == "eventTap")
    #expect(GestureEventSource.nsEvent.signpostName == "nsEvent")
    #expect(GlobalGestureEventKind.leftMouseDown.signpostName == "down")
    #expect(GlobalGestureEventKind.leftMouseDragged.signpostName == "drag")
    #expect(GlobalGestureEventKind.leftMouseUp.signpostName == "up")
}

@Test(.macOSTestApplication) @MainActor func disabledSharedGestureEventsNeverStartTheTap() {
    // The NSEvent monitors are the baseline for the latency gate. Selecting
    // them must not start a worker thread or consume the retry cooldown.
    let log = GestureEventTapWorkerLog()
    log.canStart = true
    let monitor = SharedGestureEventMonitor(
        disabled: true,
        now: { 0 },
        makeWorker: { _ in FakeGestureEventTapWorker(log: log) }
    )

    #expect(!monitor.start())
    #expect(!monitor.isUsingEventTap)
    #expect(log.startAttempts == 0)
}

/// The fallback reads the event's own location. `NSEvent.mouseLocation`
/// would report where the pointer is once a stalled main actor runs the
/// handler, which can move a release across a display edge.
@Test(.macOSTestApplication) @MainActor func fallbackEventsUseTheirOwnLocation() throws {
    let mainFrame = try #require(NSScreen.screens.first?.frame)
    let location = CGPoint(x: mainFrame.minX + 37, y: mainFrame.minY + 61)
    let event = try #require(NSEvent.mouseEvent(with: .leftMouseUp, location: location, modifierFlags: [],
                                                timestamp: 2, windowNumber: 0, context: nil, eventNumber: 2,
                                                clickCount: 1, pressure: 0))
    #expect(GlobalGestureEvent.screenLocation(of: event) == location)
    let gestureEvent = try #require(GlobalGestureEvent(event, kind: .leftMouseUp))
    #expect(gestureEvent.position == CoordinateConverter.pointToTopLeft(location, mainScreenFrame: mainFrame))
}

/// A stop can arrive after the tap thread signals that it is ready, but before
/// it enters its run loop. `CFRunLoopStop` alone is lost then, and the thread
/// keeps its tap forever. The thread must end and disable its tap.
@Test(.macOSTestApplication) func aTapWorkerStoppedBeforeItsRunLoopStartsEndsAndDisablesItsTap() {
    final class Record: @unchecked Sendable {
        let lock = NSLock()
        var enabled: [Bool] = []
    }
    let record = Record()
    let worker = GestureEventTapWorker(handler: { _ in })
    // A plain mach port keeps the run loop alive like a tap, without permission.
    worker.makePort = {
        CFMachPortCreate(kCFAllocatorDefault, { _, _, _, _ in }, nil, nil)
    }
    worker.setPortEnabled = { _, enabled in record.lock.withLock { record.enabled.append(enabled) } }
    worker.portIsEnabled = { _ in true }
    let entering = DispatchSemaphore(value: 0)
    let exited = DispatchSemaphore(value: 0)
    worker.willEnterRunLoop = { entering.wait() }
    worker.didExit = { exited.signal() }

    #expect(worker.start())
    worker.stop()
    entering.signal()

    #expect(exited.wait(timeout: .now() + 2) == .success, "The tap thread kept running after stop")
    #expect(record.lock.withLock { record.enabled } == [true, false])
}
