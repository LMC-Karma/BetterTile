import BetterTileCore

/// Coalesces duplicate Core Graphics and AppKit display notifications.
@MainActor
public final class DisplayRefreshDebouncer {
    private let delay: Duration
    private let clock: BetterTileClock
    private(set) var task: Task<Void, Never>?

    public init(delay: Duration = .milliseconds(120), clock: BetterTileClock = .live) {
        self.delay = delay
        self.clock = clock
    }

    public func schedule(_ action: @escaping @MainActor @Sendable () -> Void) {
        task?.cancel()
        task = Task { @MainActor [delay, clock] in
            try? await clock.sleep(for: delay)
            guard !Task.isCancelled else { return }
            action()
        }
    }

    public func cancel() {
        task?.cancel()
        task = nil
    }
}
