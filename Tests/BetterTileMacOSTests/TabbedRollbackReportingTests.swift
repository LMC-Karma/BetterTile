import BetterTileCore
import BetterTileTestSupport
import Testing
@testable import BetterTileMacOS

@Suite(.macOSTestApplication, .timeLimit(.minutes(1))) @MainActor
struct TabbedRollbackReportingTests {
    @Test(arguments: ["writeFailure", "mismatch", "cancel", "cancelAfterWriteFailure"])
    func rollbackReportsFailureOnlyWhenRestorationActuallyFails(ending: String) async throws {
        let clock = ManualClock()
        let system = FakeWindowSystem()
        let id = system.windows[0].id
        let checkpoint = system.windows[0].frame
        system.windows[0].frame.size.width += 150
        let failsWrite = ending == "writeFailure" || ending == "cancelAfterWriteFailure"
        if failsWrite { system.failedFrameWriteNumbers[id] = [1] }
        else { system.ignoredFrameWriteCounts[id] = 1 }
        var reports = 0
        let coordinator = WindowCoordinator(system: system, clock: clock.clock)
        let task = Task { @MainActor in
            await coordinator.restoreTabbedFrames([id: checkpoint], required: [id],
                on: system.availableDisplays[0].id, onRollbackFailure: { reports += 1 }, isCurrent: { true })
        }
        defer { task.cancel() }
        // The first restore read must reach its retry wait before cancellation.
        try #require(await clock.waitForSleepers(count: 1, timeout: .seconds(45)))
        if ending.hasPrefix("cancel") {
            task.cancel()
        } else {
            for step in 0..<3 {
                if step > 0 { try #require(await clock.waitForSleepers(count: 1, timeout: .seconds(45))) }
                clock.advance(by: .milliseconds(50))
            }
        }
        let outcome = await task.value
        #expect(!outcome.isApplied)
        #expect(system.frameWriteCounts[id] == 1)
        #expect(reports == (ending == "cancel" ? 0 : 1))
    }

    @Test func cancelledApplyDoesNotReportItsInterruptedRollback() async throws {
        let clock = ManualClock()
        let system = FakeWindowSystem()
        let id = system.windows[0].id
        let checkpoint = system.windows[0].frame
        system.failingRaiseWindowID = id
        system.writeReadbackHandler = { _, _, _, _ in system.ignoredFrameWriteCounts[id] = 1 }
        var reports = 0
        let coordinator = WindowCoordinator(system: system, clock: clock.clock)
        let task = Task { @MainActor in
            await coordinator.applyTabbed(placements: [Placement(windowID: id, frame: checkpoint.offsetBy(dx: 50, dy: 0))],
                selected: [id], previousSelected: [], focus: nil,
                onRollbackFailure: { reports += 1 }, isCurrent: { true })
        }
        defer { task.cancel() }
        try #require(await clock.waitForSleepers(count: 1, timeout: .seconds(45)))
        task.cancel()
        let outcome = await task.value
        #expect(!outcome.isApplied)
        #expect(reports == 0)
        #expect(system.frameWriteCounts[id] == 2)
    }
}
