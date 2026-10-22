/// A monotonic time source for product delays. The default uses Swift's
/// continuous clock, which keeps advancing while the machine is asleep.
public struct BetterTileClock: Clock, Sendable {
    public typealias Instant = ContinuousClock.Instant
    public typealias Duration = Swift.Duration

    public static let live = BetterTileClock(ContinuousClock())

    private let readNow: @Sendable () -> Instant
    private let suspend: @Sendable (Instant, Duration?) async throws -> Void
    public let minimumResolution: Duration

    public init<C: Clock>(_ clock: C) where C.Instant == Instant, C.Duration == Duration {
        readNow = { clock.now }
        suspend = { try await clock.sleep(until: $0, tolerance: $1) }
        minimumResolution = clock.minimumResolution
    }

    public var now: Instant { readNow() }

    public func sleep(until deadline: Instant, tolerance: Duration? = nil) async throws {
        try await suspend(deadline, tolerance)
    }
}
