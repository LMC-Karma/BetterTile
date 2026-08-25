import BetterTileCore
import Foundation
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

@Test func gestureSourceHandoffDefersOnlyTheSwitchToTheEventTap() {
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

@Test func gestureTapRetryGateBoundsRepeatedFailures() {
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

@Test @MainActor func failedTapStartIsSuppressedForTheRetryCooldown() {
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

@Test @MainActor func tapStartIsRetriedAfterTheCooldownExpires() {
    let log = GestureEventTapWorkerLog()
    let clock = GestureEventTapTestClock()
    let monitor = makeCooldownMonitor(log: log, clock: clock)

    #expect(!monitor.start())
    clock.time = 30
    #expect(!monitor.start())

    #expect(log.startAttempts == 2)
}

@Test @MainActor func successfulTapStartClearsTheRetryCooldown() {
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

@Test @MainActor func failedTapRecoveryStartsTheRetryCooldown() async {
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

@Test func gestureClockConvertsMachTicksToNanoseconds() {
    // A one-second interval must read as one second whatever the timebase is,
    // otherwise the two sources cannot be compared against one p95 limit.
    let start = GestureEventClock.uptimeNanoseconds
    let ticks = mach_absolute_time()
    let converted = GestureEventClock.nanoseconds(machAbsolute: ticks)
    let end = GestureEventClock.uptimeNanoseconds

    #expect(converted >= start)
    #expect(converted <= end)
}

@Test func gestureClockConversionIsMonotonicAndScaled() {
    let onceOver = GestureEventClock.nanoseconds(machAbsolute: 1_000)
    let twiceOver = GestureEventClock.nanoseconds(machAbsolute: 2_000)

    // Integer division truncates, so doubling the ticks may lose one
    // nanosecond. That is far below the millisecond scale of the p95 gate.
    #expect(twiceOver >= onceOver * 2)
    #expect(twiceOver - onceOver * 2 <= 1)
    #expect(GestureEventClock.nanoseconds(machAbsolute: 0) == 0)
}

@Test func gestureLatencyMeasuresTheDeliveryInterval() {
    #expect(GestureEventLatency.nanoseconds(
        eventTimestamp: 1_000,
        deliveredAt: 3_500
    ) == 2_500)
}

@Test func gestureLatencyRejectsAnUnusableOrMismatchedClock() {
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

@Test func gestureLatencySignpostNamesStayStableForTraceQueries() {
    // The measurement recipe in docs/BENTO_TESTING.md greps these names.
    #expect(GestureEventSource.eventTap.signpostName == "eventTap")
    #expect(GestureEventSource.nsEvent.signpostName == "nsEvent")
    #expect(GlobalGestureEventKind.leftMouseDown.signpostName == "down")
    #expect(GlobalGestureEventKind.leftMouseDragged.signpostName == "drag")
    #expect(GlobalGestureEventKind.leftMouseUp.signpostName == "up")
}

@Test @MainActor func disabledSharedGestureEventsNeverStartTheTap() {
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
