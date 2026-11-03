import BetterTileCore
import Foundation

/// An exclusive test resource. Queueing has a separate watchdog from the test body's budget.
public actor AsyncTestLease {
    public enum Failure: Error, Equatable, CustomStringConvertible {
        case starvation
        public var description: String { "Test lease starvation: the shared UI resource did not become available." }
    }

    private struct Waiter {
        var id: UUID
        var continuation: CheckedContinuation<UUID, any Error>
    }
    private var owner: UUID?
    private var waiters: [Waiter] = []
    public var waitingCount: Int { waiters.count }
    public var isHeld: Bool { owner != nil }

    public init() {}

    public func acquire(clock: BetterTileClock = .live, queueLimit: Duration = .seconds(600)) async throws -> UUID {
        try Task.checkCancellation()
        let id = UUID()
        guard owner != nil else { owner = id; return id }
        let watchdog = Task {
            do { try await clock.sleep(for: queueLimit) } catch { return }
            removeWaiter(id, error: Failure.starvation)
        }
        defer { watchdog.cancel() }
        return try await withTaskCancellationHandler {
            let token: UUID = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UUID, any Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else { waiters.append(Waiter(id: id, continuation: continuation)) }
            }
            do { try Task.checkCancellation() }
            catch { release(token); throw error }
            return token
        } onCancel: {
            Task { await self.removeWaiter(id, error: CancellationError()) }
        }
    }

    @discardableResult public func release(_ token: UUID) -> Bool {
        guard owner == token else { return false }
        if waiters.isEmpty { owner = nil }
        else {
            let next = waiters.removeFirst()
            owner = next.id
            next.continuation.resume(returning: next.id)
        }
        return true
    }

    private func removeWaiter(_ id: UUID, error: any Error) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: error)
    }
}
