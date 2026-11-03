import BetterTileCore
import Foundation
import BetterTileTestSupport
import Testing
@testable import BetterTileApp

// These tests use no AppKit state. A Settings UI lease would queue them behind UI work
// and consume their time limit before the throttle test body can start.
@Suite @MainActor struct SavedLayoutInventoryThrottleTests {
    @Test(.timeLimit(.minutes(1)))
    func inventoryBurstUsesOneInjectedThrottleAndNeverReadsFromRendering() async throws {
        let clock = ManualClock()
        let cache = SavedLayoutPagePlan(clock: clock.clock)
        defer { cache.cancel() }
        var reads = 0
        let refresh: @MainActor () -> Void = { reads += 1 }
        for _ in 0..<30 { cache.inventoryChanged(refresh) }
        try #require(await throttleCondition { clock.pendingSleepCount == 1 }, "The burst did not register its throttle sleep.")
        #expect(reads == 0)
        clock.advance(by: .milliseconds(249))
        #expect(clock.pendingSleepCount == 1 && reads == 0)
        clock.advance(by: .milliseconds(1))
        try #require(await throttleCondition { reads == 1 }, "The due burst did not refresh.")
        #expect(clock.pendingSleepCount == 0)

        cache.inventoryChanged(refresh)
        try #require(await throttleCondition { clock.pendingSleepCount == 1 }, "The second burst did not register its sleep.")
        cache.cancel()
        try #require(await throttleCondition { clock.pendingSleepCount == 0 }, "Cancellation did not retire the old sleeper.")
        clock.advance(by: .seconds(1))
        #expect(reads == 1)

        cache.inventoryChanged(refresh)
        try #require(await throttleCondition { clock.pendingSleepCount == 1 }, "The replacement burst did not register a new sleep.")
        clock.advance(by: .milliseconds(250))
        try #require(await throttleCondition { reads == 2 }, "The replacement burst did not refresh.")
        #expect(clock.pendingSleepCount == 0)
    }

    @Test func registrationGetsAnObservationAfterTheMainActorWasBlocked() async throws {
        let clock = ManualClock()
        let cache = SavedLayoutPagePlan(clock: clock.clock)
        defer { cache.cancel() }
        cache.inventoryChanged {}
        var observations = 0
        let observedAfterStall = await throttleCondition(timeout: .milliseconds(20)) {
            observations += 1
            if observations == 1 {
                Thread.sleep(forTimeInterval: 0.1) // real-time: reproduces executor starvation before the throttle task's first registration
            }
            return observations == 2
        }
        #expect(observedAfterStall && observations == 2)
        // One polling opportunity proves the wait survives the stall, but it
        // cannot promise that a separate task has registered its clock sleep.
        try #require(await throttleCondition { clock.pendingSleepCount == 1 })
        cache.cancel()
    }

    @Test func anUndeliveredRefreshEndsAtTheConditionDeadline() async throws {
        let clock = ManualClock()
        let cache = SavedLayoutPagePlan(clock: clock.clock)
        defer { cache.cancel() }
        var reads = 0
        cache.inventoryChanged { reads += 1 }
        try #require(await throttleCondition { clock.pendingSleepCount == 1 })
        // Leave the manual deadline in the future: no refresh can arrive. The wait must end.
        #expect(await throttleCondition(timeout: .milliseconds(20)) { reads == 1 } == false)
        #expect(reads == 0)
        cache.cancel()
        try #require(await throttleCondition { clock.pendingSleepCount == 0 })
    }
}

/// Bound the number of observations, using the shared polling helper. MainActor may be
/// occupied by other tests; elapsed queueing must not consume an unobserved readiness budget.
/// A missing condition fails after at most 100 polling steps (two seconds of scheduled waits).
@MainActor private func throttleCondition(timeout: Duration = .seconds(2), _ ready: () -> Bool) async -> Bool {
    await waitFor(timeout: timeout, ready)
}
