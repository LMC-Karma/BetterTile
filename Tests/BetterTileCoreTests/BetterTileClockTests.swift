import BetterTileCore
import BetterTileTestSupport
import Testing

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct BetterTileClockTests {
    @Test func advancingPastSeveralDeadlinesResumesThemInOrder() async {
        let manual = ManualClock()
        let clock = manual.clock
        let start = clock.now
        var tasks: [Task<Void, Never>] = []
        // Register out of deadline order to distinguish ordering from FIFO.
        for seconds in [3, 1, 2] {
            tasks.append(Task {
                do { try await clock.sleep(until: start.advanced(by: .seconds(seconds))) }
                catch { Issue.record("Unexpected clock error: \(error)") }
            })
            await manual.waitForSleepers(count: tasks.count)
        }

        let resumed = manual.advance(by: .seconds(4))
        #expect(resumed == [1, 2, 3].map { start.advanced(by: .seconds($0)) })
        for task in tasks { await manual.drain(task) }
        #expect(manual.pendingSleepCount == 0)
        #expect(clock.now == start.advanced(by: .seconds(4)))
    }

    @Test func aSleeperDoesNotWakeBeforeItsDeadline() async {
        let manual = ManualClock()
        var woke = false
        let task = Task {
            do {
                try await manual.clock.sleep(for: .seconds(1))
                woke = true
            } catch { Issue.record("Unexpected clock error: \(error)") }
        }
        await manual.waitForSleepers(count: 1)
        #expect(manual.advance(by: .milliseconds(999)).isEmpty)
        #expect(manual.pendingSleepCount == 1)
        #expect(!woke)
        manual.advance(by: .milliseconds(1))
        await manual.drain(task)
        #expect(woke)
    }

    @Test func cancellingASleepRemovesItAndThrows() async {
        let manual = ManualClock()
        let task = Task {
            do {
                try await manual.clock.sleep(for: .seconds(1))
                return false
            } catch is CancellationError { return true }
            catch { return false }
        }
        await manual.waitForSleepers(count: 1)
        task.cancel()
        #expect(await manual.drain(task))
        #expect(manual.pendingSleepCount == 0)
        #expect(manual.advance(by: .seconds(2)).isEmpty)
    }

    @Test func cancellationBeforeRegistrationAlsoThrows() async {
        let manual = ManualClock()
        let task = Task {
            do {
                try await manual.clock.sleep(for: .seconds(1))
                return false
            } catch is CancellationError { return true }
            catch { return false }
        }
        task.cancel()
        #expect(await manual.drain(task))
        #expect(manual.pendingSleepCount == 0)
    }

    @Test func aDeadlineAlreadyReachedNeedsNoAdvance() async throws {
        let manual = ManualClock()
        let start = manual.now
        manual.advance(by: .seconds(1))
        try await manual.clock.sleep(until: start)
        try await manual.clock.sleep(for: .zero)
        #expect(manual.pendingSleepCount == 0)
    }

    @Test func drainWaitsForWorkAfterChainedSleeps() async {
        let manual = ManualClock()
        var completed = false
        let task = Task {
            do {
                try await manual.clock.sleep(for: .seconds(1))
                try await manual.clock.sleep(for: .seconds(2))
                completed = true
            } catch { Issue.record("Unexpected clock error: \(error)") }
        }
        await manual.waitForSleepers(count: 1)
        manual.advance(by: .seconds(1))
        await manual.waitForSleepers(count: 1)
        #expect(!completed)
        manual.advance(by: .seconds(2))
        await manual.drain(task)
        #expect(completed)
    }
}
