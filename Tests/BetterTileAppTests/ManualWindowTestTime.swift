import BetterTileCore
import BetterTileTestSupport
import Testing
@testable import BetterTileApp
import Dispatch

@MainActor
func makeManualWindowSystem(drivingPolicyDeadlines: Bool = false) -> FakeAppWindowSystem {
    let system = FakeAppWindowSystem(manualClock: ManualClock())
    system.drivesPolicyDeadlines = drivingPolicyDeadlines
    return system
}

extension FakeAppWindowSystem {
    /// Announce each event wait before its async clock call, then observe actual
    /// continuation registration. An unrelated long timer cannot bypass a new pass.
    @MainActor
    func installWindowEventClock(in model: BetterTileModel) {
        guard let manual = manualClock else { return }
        model.windowEventSleep = { [weak model, weak self] duration in
            let task = model?.windowEventTask
            let deadline = manual.now.advanced(by: duration)
            if let task { self?.windowEventSleepDeadlines[task] = deadline }
            defer { if let task { self?.windowEventSleepDeadlines[task] = nil } }
            try await manual.sleep(until: deadline)
        }
        isAwaitingWindowEventSleepRegistration = { [weak model, weak self] in
            guard let task = model?.windowEventTask, !task.isCancelled else { return false }
            guard let deadline = self?.windowEventSleepDeadlines[task] else { return true }
            return !manual.hasSleeper(until: deadline)
        }
    }

    @MainActor
    func join<Result: Sendable>(_ task: Task<Result, Never>?, budget: Duration = .seconds(120)) async -> Result? {
        guard let task else { return nil }
        let result = await drive(budget: budget) { await task.value }
        if case nil = result { task.cancel() }
        return result
    }

    /// Stop at this event pass, before a replacement pass or recovery timer runs.
    /// The model releases its handle before its synchronous processing finishes;
    /// observing that release on the main actor therefore observes the whole pass.
    @MainActor
    func joinWindowEvent(on model: BetterTileModel, task captured: Task<Void, Never>? = nil,
                         budget: Duration = .seconds(120)) async {
        guard let task = captured ?? model.windowEventTask else { return }
        await joinPolicyPass(task, budget: budget) { model.windowEventTask != task }
    }

    /// Observe this sampling pass ending before driving a replacement retry.
    @MainActor
    func joinSettlement(_ task: Task<Void, Never>, on model: BetterTileModel,
                        budget: Duration = .seconds(120)) async {
        await joinPolicyPass(task, budget: budget) { !model.settlementTasks.values.contains(task) }
    }

    @MainActor
    private func joinPolicyPass(_ task: Task<Void, Never>, budget: Duration,
                                finished: () -> Bool) async {
        guard let manualClock else { await task.value; return }
        let reachedCheckpoint = await waitFor(timeout: budget) { task.isCancelled || finished() }
        #expect(reachedCheckpoint, "The captured policy pass must finish within its virtual-time budget")
        guard reachedCheckpoint else { task.cancel(); return }
        _ = await drive(budget: budget, stoppingTimeAt: manualClock.now) { await task.value }
    }

    /// Observe state at policy deadlines, with a separate watchdog for executor-only progress.
    /// No virtual time passes while a task is still registering its next wait.
    @MainActor
    func waitFor(timeout: Duration = .seconds(10), executorTimeout: Duration = .seconds(45),
                 stoppingTimeAt checkpoint: ContinuousClock.Instant? = nil, _ condition: () -> Bool) async -> Bool {
        guard let manualClock else { return await waitForLiveWindowState(timeout: timeout, condition) }
        guard drivesPolicyDeadlines || timeout > .milliseconds(200) else {
            // Only short boundary probes may spend one turn per virtual millisecond.
            let step = Duration.milliseconds(1)
            for _ in 0..<Int((timeout / step).rounded(.up)) {
                if condition() { return true }
                await Task.yield()
                manualClock.advance(by: step)
            }
            return condition()
        }
        let deadline = manualClock.now.advanced(by: timeout)
        let executor = ContinuousClock() // real-time: bounds missing executor/registration progress while virtual time stays fixed
        var idleDeadline = executor.now.advanced(by: executorTimeout)
        var wokeAtBudgetDeadline = false
        while true {
            if condition() { return true }
            if Task.isCancelled { return false }
            if manualClock.now >= deadline && !wokeAtBudgetDeadline { return false }
            // Task.yield may immediately reschedule this caller. An enqueued main-queue
            // continuation lets the operation and resumed policy tasks register their waits.
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
            if condition() { return true }
            if Task.isCancelled { return false }
            if manualClock.now >= deadline {
                // A wait due exactly at the budget must get its executor completion turn.
                // A newly registered future wait, however, lies outside the virtual budget.
                guard manualClock.nextSleepDeadline == nil, executor.now < idleDeadline else { return false }
                try? await executor.sleep(for: .milliseconds(1)) // real-time: observes completion of a task just resumed at the final virtual deadline
                continue
            }
            let next = manualClock.nextSleepDeadline
            let limit = min(checkpoint ?? deadline, deadline)
            if isAwaitingWindowEventSleepRegistration?() == true
                || checkpoint.map({ manualClock.now >= $0 }) == true
                || next.map({ $0 > limit }) == true {
                guard executor.now < idleDeadline else { return false }
                try? await executor.sleep(for: .milliseconds(1)) // real-time: observes sleep registration or checkpoint completion when only unrelated or out-of-budget timers are registered
            } else if let next {
                // A budget is a bound, not a policy deadline. Do not jump to it
                // while a shorter in-budget operation is still registering.
                let target = next
                let resumed = manualClock.advance(by: max(.zero, target - manualClock.now))
                wokeAtBudgetDeadline = target == deadline && !resumed.isEmpty
                idleDeadline = executor.now.advanced(by: executorTimeout)
            } else {
                guard executor.now < idleDeadline else { return false }
                try? await executor.sleep(for: .milliseconds(1)) // real-time: bounded condition polling gives executor/native callbacks with no policy sleeper a turn
            }
        }
    }

    /// Join known work while its sleeps use the fixture's manual clock.
    @MainActor
    func drive<Result: Sendable>(
        budget: Duration = .seconds(120), stoppingTimeAt checkpoint: ContinuousClock.Instant? = nil,
        _ operation: @escaping @MainActor () async -> Result
    ) async -> Result? {
        guard manualClock != nil else { return await operation() }
        var completed = false
        let task = Task { @MainActor in
            let result = await operation()
            completed = true
            return result
        }
        let finished = await waitFor(timeout: budget, stoppingTimeAt: checkpoint) { completed }
        #expect(finished, "The fixture's operation must finish within its virtual-time budget")
        guard finished else {
            task.cancel()
            return nil
        }
        return await task.value
    }

    /// Give policy timers the requested interval, without advancing wall time.
    @MainActor
    func advance(by duration: Duration) async {
        guard let manualClock else {
            Issue.record("Policy-time advancement requires a manual fixture clock")
            return
        }
        let deadline = manualClock.now.advanced(by: duration)
        _ = await drive(stoppingTimeAt: deadline) { try? await manualClock.sleep(until: deadline) }
    }
}

@MainActor
private func waitForLiveWindowState(timeout: Duration, _ condition: () -> Bool) async -> Bool {
    await waitFor(timeout: timeout, condition)
}
