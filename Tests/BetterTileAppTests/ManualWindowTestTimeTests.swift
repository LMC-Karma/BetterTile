import BetterTileCore
import BetterTileTestSupport
import Testing
import Dispatch
import Synchronization
@testable import BetterTileApp

@Suite(.appTestApplication, .timeLimit(.minutes(1))) @MainActor
struct ManualWindowTestTimeTests {
    @Test func aJoinWithoutProgressReportsFailureAndReturns() async throws {
        let system = makeManualWindowSystem()
        let clock = try #require(system.manualClock)
        let task = Task {
            try? await clock.sleep(for: .seconds(1_000))
            return 42
        }
        defer { task.cancel() }
        try #require(await clock.waitForSleepers(count: 1, timeout: .seconds(45)))
        let failures = HelperFailureLog()
        let result = await system.join(task, budget: .milliseconds(5), reporter: .collecting(into: failures))
        #expect(result == nil)
        #expect(failures.messages == [budgetExpiryMessage], "The virtual-time budget must report missing progress")
        #expect(failures.reported.map(\.sourceLocation.fileID) == ["BetterTileAppTests/ManualWindowTestTime.swift"],
                "The report keeps pointing at the helper, as its #expect did")
        #expect(task.isCancelled)
        #expect(clock.pendingSleepCount == 0)
    }

    @Test func aJoinOutcomeSaysTheBudgetExpired() async throws {
        let system = makeManualWindowSystem()
        let clock = try #require(system.manualClock)
        let task = Task {
            try? await clock.sleep(for: .seconds(1_000))
            return 42
        }
        defer { task.cancel() }
        try #require(await clock.waitForSleepers(count: 1, timeout: .seconds(45)))
        #expect(await system.joinOutcome(task, budget: .milliseconds(5)) == .budgetExpired)
        #expect(task.isCancelled)
        #expect(clock.pendingSleepCount == 0)
    }

    @Test func driveCancelsItsOwnedSleeperWhenItsBudgetExpires() async throws {
        let system = makeManualWindowSystem()
        let clock = try #require(system.manualClock)
        var started = false
        let outcome = await system.driveOutcome(budget: .milliseconds(5)) {
            started = true
            try? await clock.sleep(for: .seconds(1_000))
            return 42
        }
        #expect(outcome == .budgetExpired)
        #expect(started)
        #expect(clock.pendingSleepCount == 0)

        let failures = HelperFailureLog()
        let result = await system.drive(budget: .milliseconds(5), reporter: .collecting(into: failures)) {
            try? await clock.sleep(for: .seconds(1_000))
            return 42
        }
        #expect(result == nil)
        #expect(failures.messages == [budgetExpiryMessage], "The virtual-time budget must report missing progress")
        #expect(clock.pendingSleepCount == 0)
    }

    private let budgetExpiryMessage = "The fixture's operation must finish within its virtual-time budget"
}

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

/// A main-actor policy task registers each manual wait before it suspends, so the
/// driver always sees the next deadline. The settlement calls `sleep(for:)`.
@Test(.appTestApplication, .timeLimit(.minutes(1))) @MainActor
func aMainActorSleepRegistersBeforeItsTaskSuspends() async throws {
    let system = makeManualWindowSystem()
    let manual = try #require(system.manualClock)
    let clock = system.clock
    for iteration in 0..<20 {
        let viaProductClock = Task.immediate { @MainActor in try? await clock.sleep(for: .milliseconds(40)) }
        #expect(manual.pendingSleepCount == 1, "BetterTileClock.sleep(for:) registered late in iteration \(iteration)")
        let viaManualClock = Task.immediate { @MainActor in try? await manual.sleep(for: .milliseconds(40)) }
        #expect(manual.pendingSleepCount == 2, "ManualClock.sleep(for:) registered late in iteration \(iteration)")
        manual.advance(by: .milliseconds(40))
        // A late registration computes its deadline after this advance and never wakes.
        viaProductClock.cancel()
        viaManualClock.cancel()
        await viaProductClock.value
        await viaManualClock.value
        #expect(manual.pendingSleepCount == 0)
    }
}

/// The settlement shape: eight 40 ms samples on the main actor. A one-second
/// advance must not jump past a sample that is still registering. Before the
/// clock and driver fix, nearly every iteration skipped samples.
@Test(.appTestApplication, .timeLimit(.minutes(1))) @MainActor
func advanceRunsEveryStepOfAMainActorSamplingLoop() async throws {
    let system = makeManualWindowSystem()
    let clock = system.clock
    var lateIterations: [Int] = []
    for iteration in 0..<10 {
        var samples = 0
        let sampling = Task { @MainActor in
            for _ in 0..<8 {
                try? await clock.sleep(for: .milliseconds(40))
                samples += 1
            }
        }
        await system.advance(by: .seconds(1))
        if samples != 8 { lateIterations.append(iteration) }
        sampling.cancel()
        await sampling.value
    }
    #expect(lateIterations.isEmpty, "Samples were skipped in \(lateIterations.count) of 10 iterations: \(lateIterations)")
}

/// Runs actor jobs on the main queue, like a main-actor task, but can hold them.
/// A held job models a resumed task that has not yet reached its actor.
private final class HoldableMainQueueExecutor: SerialExecutor {
    private let state = Mutex<(holding: Bool, jobs: [UnownedJob])>((false, []))

    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        let runsNow = state.withLock { state in
            if state.holding { state.jobs.append(job) }
            return !state.holding
        }
        if runsNow { schedule(job) }
    }

    func hold() { state.withLock { $0.holding = true } }

    func release() {
        let jobs = state.withLock { state in
            state.holding = false
            defer { state.jobs = [] }
            return state.jobs
        }
        jobs.forEach(schedule)
    }

    private func schedule(_ job: UnownedJob) {
        DispatchQueue.main.async { job.runSynchronously(on: self.asUnownedSerialExecutor()) }
    }

    func asUnownedSerialExecutor() -> UnownedSerialExecutor { UnownedSerialExecutor(ordinary: self) }
}

private actor HeldSampler {
    let executor: HoldableMainQueueExecutor
    private(set) var samples = 0
    nonisolated var unownedExecutor: UnownedSerialExecutor { executor.asUnownedSerialExecutor() }

    init(executor: HoldableMainQueueExecutor) { self.executor = executor }

    func sample(_ clock: BetterTileClock, times: Int) async {
        for _ in 0..<times {
            try? await clock.sleep(for: .milliseconds(40))
            samples += 1
        }
    }
}

/// While a sleeper that an advance resumed has not reached its actor, its next
/// wait does not exist yet. The driver must keep virtual time still until it runs.
@Test(.appTestApplication, .timeLimit(.minutes(1))) @MainActor
func advanceWaitsForAResumedSleeperToReachItsActor() async throws {
    let system = makeManualWindowSystem()
    let manual = try #require(system.manualClock)
    let executor = HoldableMainQueueExecutor()
    let sampler = HeldSampler(executor: executor)
    let start = manual.now
    let sampling = Task { await sampler.sample(system.clock, times: 3) }
    defer { sampling.cancel() }
    try #require(await manual.waitForSleepers(count: 1, timeout: .seconds(45)))
    executor.hold()
    manual.advance(by: .milliseconds(40))
    #expect(manual.returningSleepCount == 1)
    let driving = Task { @MainActor in await system.advance(by: .seconds(1)) }
    for _ in 0..<50 {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
    #expect(manual.now - start == .milliseconds(40),
            "The driver advanced while a resumed sleeper was still returning to its actor")
    executor.release()
    await driving.value
    #expect(await sampler.samples == 3)
    // A skipped step leaves a wait past the advance; cancellation ends it.
    sampling.cancel()
    await sampling.value
}
