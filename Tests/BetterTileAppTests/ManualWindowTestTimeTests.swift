import BetterTileCore
import Testing
import Dispatch
@testable import BetterTileApp

@Test(.appTestApplication, .timeLimit(.minutes(1))) @MainActor
func manualWindowWaitAdvancesOnlyToRegisteredDeadlines() async throws {
    let system = makeManualWindowSystem()
    let clock = try #require(system.manualClock)
    let start = clock.now
    var completed = false
    let operation = Task { @MainActor in
        try? await clock.sleep(for: .milliseconds(1500))
        try? await clock.sleep(for: .milliseconds(50))
        completed = true
    }
    defer { operation.cancel() }
    try #require(await clock.waitForSleepers(count: 1, timeout: .seconds(45)))
    var observed: Set<Duration> = []
    try #require(await system.waitFor {
        observed.insert(clock.now - start)
        return completed
    })
    let deadlines: Set<Duration> = [.zero, .milliseconds(1500), .milliseconds(1550)]
    #expect(observed.subtracting(deadlines).count == 0,
            "The driver must visit policy deadlines instead of inventing one-millisecond polling instants")
    #expect(observed.contains(.milliseconds(1500)))
    #expect(observed.contains(.milliseconds(1550)))
    await operation.value
}

@Test(.appTestApplication, .timeLimit(.minutes(1))) @MainActor
func manualWindowWaitWithoutASleeperHasABoundedExecutorWatchdog() async throws {
    let system = makeManualWindowSystem(drivingPolicyDeadlines: true)
    let clock = try #require(system.manualClock)
    let start = clock.now
    #expect(await system.waitFor(executorTimeout: .milliseconds(10)) { false } == false)
    #expect(clock.now == start, "Executor-only waiting must not manufacture policy time")
}

@Test(.appTestApplication, .timeLimit(.minutes(1))) @MainActor
func manualWindowWaitObservesCompletionAtItsBudgetDeadline() async throws {
    let system = makeManualWindowSystem(drivingPolicyDeadlines: true)
    let clock = try #require(system.manualClock)
    var completed = false
    let operation = Task { @MainActor in
        try? await clock.sleep(for: .milliseconds(20))
        completed = true
    }
    defer { operation.cancel() }
    try #require(await clock.waitForSleepers(count: 1, timeout: .seconds(45)))
    #expect(await system.waitFor(timeout: .milliseconds(20)) { completed })
    await operation.value
}

@Test(.appTestApplication, .timeLimit(.minutes(1))) @MainActor
func manualWindowAdvanceStopsBeforeLaterPolicyWaits() async throws {
    let system = makeManualWindowSystem()
    let clock = try #require(system.manualClock)
    let start = clock.now
    var reachedCheckpoint = false
    var crossedCheckpoint = false
    let operation = Task { @MainActor in
        try? await clock.sleep(for: .milliseconds(350))
        for _ in 0..<4 {
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
        reachedCheckpoint = true
        try? await clock.sleep(for: .seconds(60))
        if !Task.isCancelled { crossedCheckpoint = true }
    }
    defer { operation.cancel() }
    try #require(await clock.waitForSleepers(count: 1, timeout: .seconds(45)))
    await system.advance(by: .milliseconds(350))
    // Advancing wakes continuations; observe this operation registering its next wait.
    try #require(await clock.waitForSleepers(count: 1, timeout: .seconds(45)))
    #expect(clock.now - start == .milliseconds(350))
    #expect(reachedCheckpoint)
    #expect(!crossedCheckpoint)
}

@Test(.appTestApplication, .timeLimit(.minutes(1))) @MainActor
func manualWindowWaitRegistersTheEventBeforeAdvancingAnUnrelatedTimer() async throws {
    let system = makeManualWindowSystem()
    let clock = try #require(system.manualClock)
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.setActiveMode(.bento)
    try #require(await system.waitFor { model.settlementTasks.isEmpty })
    await system.joinWindowEvent(on: model)
    let start = clock.now
    var unrelatedTimerFired = false
    let unrelated = Task { @MainActor in
        try? await clock.sleep(until: start.advanced(by: .seconds(60)))
        if !Task.isCancelled { unrelatedTimerFired = true }
    }
    defer { unrelated.cancel() }
    try #require(await clock.waitForSleepers(count: 1, timeout: .seconds(45)))
    let eventSleep = model.windowEventSleep
    var registrationTime: Duration?
    model.windowEventSleep = { duration in
        // Reproduce executor hops before this timer's continuation is registered.
        for _ in 0..<4 {
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
        registrationTime = clock.now - start
        try await eventSleep(duration)
    }
    let window = system.windows[0]
    system.eventHandler?(.init(kind: .resized, windowID: window.id, processIdentifier: window.processIdentifier))
    try #require(model.windowEventTask != nil)
    await system.joinWindowEvent(on: model)
    #expect(registrationTime == .zero)
    #expect(!unrelatedTimerFired)
}

@Test(.appTestApplication, .timeLimit(.minutes(1))) @MainActor
func manualWindowWaitAllowsAShorterSleepToRegisterWithinItsBudget() async throws {
    let system = makeManualWindowSystem()
    let clock = try #require(system.manualClock)
    let start = clock.now
    var unrelatedTimerFired = false
    let unrelated = Task { @MainActor in
        try? await clock.sleep(until: start.advanced(by: .seconds(60)))
        if !Task.isCancelled { unrelatedTimerFired = true }
    }
    defer { unrelated.cancel() }
    try #require(await clock.waitForSleepers(count: 1, timeout: .seconds(45)))
    var completed = false
    let operation = Task { @MainActor in
        for _ in 0..<4 {
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
        try? await clock.sleep(for: .milliseconds(1500))
        completed = true
    }
    defer { operation.cancel() }
    try #require(await system.waitFor { completed })
    #expect(clock.now - start == .milliseconds(1500))
    #expect(!unrelatedTimerFired)
    await operation.value
}
