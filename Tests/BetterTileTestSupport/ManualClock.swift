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
    public var clock: BetterTileClock { BetterTileClock(self) }

    public init() {}

    public func sleep(until deadline: Instant, tolerance: Duration? = nil) async throws {
        let id = state.withLock { state in
            state.nextID += 1
            state.sleepers[state.nextID] = Sleeper(deadline: deadline)
            return state.nextID
        }
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

    /// Join known work after advancing past its deadlines. Explicit task
    /// handles make completion observable without scheduler guesses. This
    /// does not advance time or drain unrelated tasks or AppKit's run loop.
    public func drain<Result: Sendable>(_ task: Task<Result, Never>) async -> Result {
        await task.value
    }
}
