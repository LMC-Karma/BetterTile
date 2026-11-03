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
        var holder: String
        var holdReport: Duration?
        var continuation: CheckedContinuation<UUID, any Error>
    }
    private var owner: UUID?
    private var waiters: [Waiter] = []
    private let identity = UUID()
    public var waitingCount: Int { waiters.count }
    public var isHeld: Bool { owner != nil }

    public init() {}

    /// - Parameters:
    ///   - holder: The test that will hold the lease, named in the hold report.
    ///   - holdReport: While one holder keeps the lease this long, `TestWatchdog` writes its name to standard
    ///     error from its own thread, and again after each further interval. A test that never returns then
    ///     names itself in the log, even when every test task is stalled. Nil turns the report off.
    public func acquire(holder: String = "a test", clock: BetterTileClock = .live, queueLimit: Duration = .seconds(600),
                        holdReport: Duration? = .seconds(180)) async throws -> UUID {
        try Task.checkCancellation()
        let id = UUID()
        guard owner != nil else { grant(id, to: holder, holdReport: holdReport); return id }
        let watchdog = Task {
            do { try await clock.sleep(for: queueLimit) } catch { return }
            removeWaiter(id, error: Failure.starvation)
        }
        defer { watchdog.cancel() }
        return try await withTaskCancellationHandler {
            let token: UUID = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UUID, any Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else {
                    waiters.append(Waiter(id: id, holder: holder, holdReport: holdReport, continuation: continuation))
                    TestWatchdog.waitingChanged(identity, waiting: waiters.count)
                }
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
        if waiters.isEmpty {
            owner = nil
            TestWatchdog.holderChanged(identity, holder: nil, waiting: 0, interval: nil)
        } else {
            let next = waiters.removeFirst()
            grant(next.id, to: next.holder, holdReport: next.holdReport)
            next.continuation.resume(returning: next.id)
        }
        return true
    }

    private func grant(_ id: UUID, to holder: String, holdReport: Duration?) {
        owner = id
        let interval = holdReport.map { Double($0.components.seconds) + Double($0.components.attoseconds) / 1e18 }
        TestWatchdog.holderChanged(identity, holder: holder, waiting: waiters.count, interval: interval)
    }

    private func removeWaiter(_ id: UUID, error: any Error) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: error)
        TestWatchdog.waitingChanged(identity, waiting: waiters.count)
    }
}
