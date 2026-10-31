import BetterTileTestSupport
import Testing

@Suite(.timeLimit(.minutes(1))) struct AsyncTestLeaseTests {
    @Test func cancelledWaiterDoesNotTakeTheNextOwnership() async throws {
        let lease = AsyncTestLease(), clock = ManualClock()
        let owner = try await lease.acquire()
        let waiting = Task { try await lease.acquire(clock: clock.clock) }
        try #require(await clock.waitForSleepers(count: 1, timeout: .seconds(45)))
        waiting.cancel()
        do { _ = try await waiting.value; Issue.record("A cancelled waiter acquired the resource") }
        catch is CancellationError { }
        #expect(await lease.waitingCount == 0)
        #expect(clock.pendingSleepCount == 0)
        #expect(await lease.isHeld)
        #expect(await lease.release(owner))
        let next = try await lease.acquire()
        #expect(await lease.release(next))
        #expect(await !lease.isHeld)
    }

    @Test func queueStarvationReportsItsOwnFailureWithoutTakingTheOwner() async throws {
        let lease = AsyncTestLease(), clock = ManualClock()
        let owner = try await lease.acquire()
        let waiting = Task { try await lease.acquire(clock: clock.clock, queueLimit: .milliseconds(100)) }
        try #require(await clock.waitForSleepers(count: 1, timeout: .seconds(45)))
        clock.advance(by: .milliseconds(100))
        do { _ = try await waiting.value; Issue.record("A starved waiter acquired the resource") }
        catch { #expect(error as? AsyncTestLease.Failure == .starvation) }
        #expect(await lease.waitingCount == 0)
        #expect(clock.pendingSleepCount == 0)
        #expect(await lease.isHeld)
        #expect(await lease.release(owner))
        #expect(clock.pendingSleepCount == 0)
    }
}
