/// A monotonic time source for product delays. The default uses Swift's
/// continuous clock, which keeps advancing while the machine is asleep.
///
/// Sleeps start on the caller's executor. A main-actor task reads `now` and
/// hands its deadline to the wrapped clock before it leaves the main actor.
public struct BetterTileClock: Clock, Sendable {
    public typealias Instant = ContinuousClock.Instant
    public typealias Duration = Swift.Duration
    public typealias Suspend = nonisolated(nonsending) @Sendable (Instant, Duration?) async throws -> Void

    public static let live = BetterTileClock(ContinuousClock())

    private let readNow: @Sendable () -> Instant
    private let suspend: Suspend
    public let minimumResolution: Duration

    public init<C: Clock>(_ clock: C) where C.Instant == Instant, C.Duration == Duration {
        self.init(now: { clock.now }, minimumResolution: clock.minimumResolution) {
            try await clock.sleep(until: $0, tolerance: $1)
        }
    }

    /// A clock whose sleep body runs on the caller's executor. Use it for a
    /// clock whose sleep is `nonisolated(nonsending)`. A generic `Clock` call
    /// would leave the caller's executor before it reached that sleep.
    public init(now: @escaping @Sendable () -> Instant, minimumResolution: Duration,
                sleep: @escaping Suspend) {
        readNow = now
        suspend = sleep
        self.minimumResolution = minimumResolution
    }

    public var now: Instant { readNow() }

    nonisolated(nonsending)
    public func sleep(until deadline: Instant, tolerance: Duration? = nil) async throws {
        try await suspend(deadline, tolerance)
    }

    /// Replaces the standard library's `Clock.sleep(for:)` extension, which
    /// leaves the caller's executor before it reads `now`.
    nonisolated(nonsending)
    public func sleep(for duration: Duration, tolerance: Duration? = nil) async throws {
        try await self.sleep(until: now.advanced(by: duration), tolerance: tolerance)
    }
}
