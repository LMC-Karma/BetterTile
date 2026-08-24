import Foundation

/// Coalesces duplicate Core Graphics and AppKit display notifications.
@MainActor
public final class DisplayRefreshDebouncer {
    private let delay: Duration
    private var task: Task<Void, Never>?

    public init(delay: Duration = .milliseconds(120)) {
        self.delay = delay
    }

    public func schedule(_ action: @escaping @MainActor @Sendable () -> Void) {
        task?.cancel()
        task = Task { @MainActor [delay] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            action()
        }
    }

    public func cancel() {
        task?.cancel()
        task = nil
    }
}
