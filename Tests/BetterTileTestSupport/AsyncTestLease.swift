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
    private let report = HoldReport()
    public var waitingCount: Int { waiters.count }
    public var isHeld: Bool { owner != nil }

    public init() {}

    /// - Parameters:
    ///   - holder: The test that will hold the lease, named in the hold report.
    ///   - holdReport: While one holder keeps the lease this long, the lease writes its name to standard error,
    ///     and again after each further interval. A test that never returns then names itself in the log,
    ///     even when the job is cancelled before any test reports. Nil turns the report off.
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
                    report.setWaiting(waiters.count)
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
            report.update(owner: nil, holder: "", waiting: 0)
        } else {
            let next = waiters.removeFirst()
            grant(next.id, to: next.holder, holdReport: next.holdReport)
            next.continuation.resume(returning: next.id)
        }
        return true
    }

    private func grant(_ id: UUID, to holder: String, holdReport: Duration?) {
        owner = id
        report.update(owner: id, holder: holder, waiting: waiters.count)
        if let holdReport { report.schedule(id, after: holdReport) }
    }

    private func removeWaiter(_ id: UUID, error: any Error) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: error)
        report.setWaiting(waiters.count)
    }
}

/// The lease's current holder, readable without the actor. The report runs on a dispatch timer, so it still
/// appears when the main actor and every test task are stalled.
private final class HoldReport: @unchecked Sendable {
    private let lock = NSLock()
    private var owner: UUID?
    private var holder = ""
    private var waiting = 0

    func update(owner: UUID?, holder: String, waiting: Int) {
        lock.withLock { (self.owner, self.holder, self.waiting) = (owner, holder, waiting) }
    }

    func setWaiting(_ count: Int) {
        lock.withLock { waiting = count }
    }

    func schedule(_ id: UUID, after interval: Duration, held: Duration = .zero) {
        let seconds = Double(interval.components.seconds) + Double(interval.components.attoseconds) / 1e18
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { [self] in // real-time: names a lease holder that never returns, independent of the stalled test clocks
            let total = held + interval
            let line: String? = lock.withLock {
                guard owner == id else { return nil }
                return "Test lease: \(holder) has held the shared UI resource for \(total.components.seconds) s; "
                    + "\(waiting) test(s) waiting.\n"
            }
            guard let line else { return }
            FileHandle.standardError.write(Data(line.utf8))
            schedule(id, after: interval, held: total)
        }
    }
}
