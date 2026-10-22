import BetterTileTestSupport
import Testing
@testable import BetterTileMacOS

@MainActor
@Test(.timeLimit(.minutes(1))) func displayRefreshDebouncerCoalescesCallbackAndAppKitNotifications() async throws {
    let clock = ManualClock()
    let debouncer = DisplayRefreshDebouncer(delay: .milliseconds(20), clock: clock.clock)
    var refreshCount = 0

    debouncer.schedule { refreshCount += 1 }
    let first = try #require(debouncer.task)
    debouncer.schedule { refreshCount += 1 }
    let second = try #require(debouncer.task)
    debouncer.schedule { refreshCount += 1 }
    let last = try #require(debouncer.task)
    await clock.waitForSleepers(count: 1)
    clock.advance(by: .milliseconds(20))
    await clock.drain(first)
    await clock.drain(second)
    await clock.drain(last)

    #expect(refreshCount == 1)
}

@MainActor
@Test(.timeLimit(.minutes(1))) func cancelledDisplayRefreshDoesNotRun() async throws {
    let clock = ManualClock()
    let debouncer = DisplayRefreshDebouncer(delay: .milliseconds(20), clock: clock.clock)
    var refreshCount = 0

    debouncer.schedule { refreshCount += 1 }
    let task = try #require(debouncer.task)
    await clock.waitForSleepers(count: 1)
    debouncer.cancel()
    clock.advance(by: .milliseconds(60))
    await clock.drain(task)

    #expect(refreshCount == 0)
}

@MainActor
@Test(.timeLimit(.minutes(1))) func rescheduledDisplayRefreshWaitsForTheNewDeadline() async throws {
    let clock = ManualClock()
    let debouncer = DisplayRefreshDebouncer(delay: .milliseconds(20), clock: clock.clock)
    var refreshCount = 0

    debouncer.schedule { refreshCount += 1 }
    let first = try #require(debouncer.task)
    await clock.waitForSleepers(count: 1)
    clock.advance(by: .milliseconds(19))
    #expect(refreshCount == 0)
    #expect(clock.pendingSleepCount == 1)

    debouncer.schedule { refreshCount += 1 }
    await clock.drain(first)
    let last = try #require(debouncer.task)
    await clock.waitForSleepers(count: 1)
    clock.advance(by: .milliseconds(19))
    #expect(refreshCount == 0)
    #expect(clock.pendingSleepCount == 1)
    clock.advance(by: .milliseconds(1))
    await clock.drain(last)
    #expect(refreshCount == 1)

    // Both scheduled deadlines are behind us; neither can fire again.
    #expect(clock.advance(by: .seconds(1)).isEmpty)
    #expect(refreshCount == 1)
}
