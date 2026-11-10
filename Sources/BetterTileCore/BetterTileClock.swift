/// A monotonic time source for product delays. The default uses Swift's
/// continuous clock, which keeps advancing while the machine is asleep.
///
/// Sleeps start in the caller's isolation. A main-actor task reads `now` and
/// hands its deadline to the wrapped clock before it leaves the main actor.
/// An explicit `isolation` parameter does this on every supported toolchain.
public struct BetterTileClock: Clock, Sendable {
    public typealias Instant = ContinuousClock.Instant
    public typealias Duration = Swift.Duration
    /// A sleep body that runs in the isolation it receives.
    public typealias Suspend = @Sendable (Instant, Duration?, isolated (any Actor)?) async throws -> Void

    public static let live = BetterTileClock(ContinuousClock())

    private let readNow: @Sendable () -> Instant
    private let suspend: Suspend
    public let minimumResolution: Duration

    public init<C: Clock>(_ clock: C) where C.Instant == Instant, C.Duration == Duration {
        self.init(now: { clock.now }, minimumResolution: clock.minimumResolution) { deadline, tolerance, _ in
            try await clock.sleep(until: deadline, tolerance: tolerance)
        }
    }

    /// A clock whose sleep body runs in the caller's isolation. Use it for a
    /// clock with an isolated sleep. A generic `Clock` call would leave the
    /// caller's isolation before it reached that sleep.
    public init(now: @escaping @Sendable () -> Instant, minimumResolution: Duration,
                sleep: @escaping Suspend) {
        readNow = now
        suspend = sleep
        self.minimumResolution = minimumResolution
    }

    public var now: Instant { readNow() }

    /// The `Clock` requirement, for generic callers. It runs on the global
    /// executor. A concrete call that names `tolerance:` without `isolation:`
    /// also resolves here.
    public func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        try await suspend(deadline, tolerance, nil)
    }

    public func sleep(until deadline: Instant, tolerance: Duration? = nil,
                      isolation: isolated (any Actor)? = #isolation) async throws {
        try await suspend(deadline, tolerance, isolation)
    }

    /// Replaces the standard library's `Clock.sleep(for:)` extension, which
    /// leaves the caller's isolation before it reads `now`.
    public func sleep(for duration: Duration, tolerance: Duration? = nil,
                      isolation: isolated (any Actor)? = #isolation) async throws {
        try await suspend(now.advanced(by: duration), tolerance, isolation)
    }
}
