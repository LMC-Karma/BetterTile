import BetterTileCore
import Synchronization

/// Test time advances only when requested. Each instance owns its sleepers.
public final class ManualClock: Clock, Sendable {
    public typealias Instant = ContinuousClock.Instant
    public typealias Duration = Swift.Duration

    private struct Sleeper {
        let deadline: Instant
        var continuation: CheckedContinuation<Void, any Error>?
        var cancelled = false
    }

    private struct State {
        var now = ContinuousClock.now // real-time: seeds the manual clock's origin once
        var nextID: UInt64 = 0
        var sleepers: [UInt64: Sleeper] = [:]
        /// Sleepers that `advance` resumed and that have not yet run on their caller's executor.
        var returning: Set<UInt64> = []
        var registrationWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

        var sleepingCount: Int {
            sleepers.values.filter { $0.continuation != nil }.count
        }

        mutating func notifyRegistrationWaiters() {
            let count = sleepingCount
            let ready = registrationWaiters.filter { $0.0 <= count }
            registrationWaiters.removeAll { $0.0 <= count }
            for (_, continuation) in ready { continuation.resume() }
        }
    }

    private let state = Mutex(State())
    public let minimumResolution: Duration = .nanoseconds(1)
    public var now: Instant { state.withLock { $0.now } }
    public var pendingSleepCount: Int { state.withLock { $0.sleepingCount } }
    /// Waits that `advance` resumed but whose callers have not run again yet.
    /// A resumed task reaches its actor later than the driver's next main-queue
    /// turn can run. Until it arrives, that caller's next wait is missing.
    public var returningSleepCount: Int { state.withLock { $0.returning.count } }
    /// Earliest registered policy wait, excluding reservations and cancelled waits.
    public var nextSleepDeadline: Instant? {
        state.withLock { state in
            state.sleepers.values.filter { $0.continuation != nil && !$0.cancelled }.map(\.deadline).min()
        }
    }
    /// Whether an announced wait has reached continuation registration.
    public func hasSleeper(until deadline: Instant) -> Bool {
        state.withLock { state in
            state.sleepers.values.contains { $0.deadline == deadline && $0.continuation != nil && !$0.cancelled }
        }
    }
    /// Calls this clock's own sleep directly, so a wait registers on the
    /// caller's executor. `BetterTileClock(self)` would call it through the
    /// generic `Clock` requirement, which leaves the caller's executor first.
    public var clock: BetterTileClock {
        BetterTileClock(now: { self.now }, minimumResolution: minimumResolution) {
            try await self.sleep(until: $0, tolerance: $1)
        }
    }

    public init() {}

    /// Registers the wait before the caller suspends, on the caller's executor.
    /// A main-actor task therefore never leaves a gap in which a driver reads
    /// `nextSleepDeadline` without this wait.
    nonisolated(nonsending)
    public func sleep(until deadline: Instant, tolerance: Duration? = nil) async throws {
        let id = state.withLock { state in
            state.nextID += 1
            state.sleepers[state.nextID] = Sleeper(deadline: deadline)
            return state.nextID
        }
        // Runs on the caller's executor after the resumed continuation hops back.
        defer { _ = state.withLock { $0.returning.remove(id) } }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                state.withLock { state in
                    let sleeper = state.sleepers[id]!
                    if sleeper.cancelled || Task.isCancelled {
                        state.sleepers.removeValue(forKey: id)
                        continuation.resume(throwing: CancellationError())
                    } else if deadline <= state.now {
                        state.sleepers.removeValue(forKey: id)
                        continuation.resume()
                    } else {
                        state.sleepers[id]?.continuation = continuation
                        state.notifyRegistrationWaiters()
                    }
                }
            }
        } onCancel: {
            self.state.withLock { state in
                guard let sleeper = state.sleepers[id] else { return }
                if let continuation = sleeper.continuation {
                    state.sleepers.removeValue(forKey: id)
                    continuation.resume(throwing: CancellationError())
                } else {
                    // Cancellation can arrive before continuation registration.
                    state.sleepers[id]?.cancelled = true
                }
            }
        }
    }

    /// Replaces the standard library's `Clock.sleep(for:)` extension, which
    /// leaves the caller's executor before it reads `now`.
    nonisolated(nonsending)
    public func sleep(for duration: Duration, tolerance: Duration? = nil) async throws {
        try await self.sleep(until: now.advanced(by: duration), tolerance: tolerance)
    }

    /// Resume due continuations by deadline, then by registration order.
    /// Returns their deadlines in that order. Executor scheduling of the
    /// resumed task bodies is separate; use drain to join those tasks.
    @discardableResult
    public func advance(by duration: Duration) -> [Instant] {
        precondition(duration >= .zero, "Manual time cannot move backwards")
        return state.withLock { state in
            state.now = state.now.advanced(by: duration)
            let due = state.sleepers.filter { $0.value.deadline <= state.now && $0.value.continuation != nil }
                .sorted {
                    if $0.value.deadline == $1.value.deadline { return $0.key < $1.key }
                    return $0.value.deadline < $1.value.deadline
                }
            for (id, sleeper) in due {
                state.sleepers.removeValue(forKey: id)
                state.returning.insert(id)
                sleeper.continuation?.resume()
            }
            return due.map { $0.value.deadline }
        }
    }

    /// Wait until at least `count` sleepers are registered in total, including
    /// earlier ones that have not resumed. This avoids racing a task that has
    /// been created but has not reached its first sleep. It waits until the
    /// test's time limit if the sleep never happens.
    public func waitForSleepers(count: Int) async {
        await withCheckedContinuation { continuation in
            state.withLock { state in
                if state.sleepingCount >= count { continuation.resume() }
                else { state.registrationWaiters.append((count, continuation)) }
            }
        }
    }

    /// Bounds executor registration without advancing virtual policy time.
    /// Returns false when the expected operation exits or never reaches its sleep.
    public func waitForSleepers(count: Int, timeout: Duration) async -> Bool {
        let executorClock = ContinuousClock() // real-time: bounds executor sleep registration while virtual policy time stays fixed
        let deadline = executorClock.now.advanced(by: timeout)
        while pendingSleepCount < count {
            if Task.isCancelled || executorClock.now >= deadline { return false }
            try? await executorClock.sleep(for: .milliseconds(1)) // real-time: yields to AppKit and executor registration without advancing virtual policy time
        }
        return true
    }

    /// Join known work after advancing past its deadlines. Explicit task
    /// handles make completion observable without scheduler guesses. This
    /// does not advance time or drain unrelated tasks or AppKit's run loop.
    public func drain<Result: Sendable>(_ task: Task<Result, Never>) async -> Result {
        await task.value
    }
}
