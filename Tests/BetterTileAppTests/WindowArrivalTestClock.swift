import Foundation
import Testing
@testable import BetterTileApp

/// Only arrival age is controlled. Event debounce, placement, panels, and shortcuts run normally.
@MainActor
final class WindowArrivalTestClock {
    private let start: Date
    var elapsed: TimeInterval = 0

    init(_ model: BetterTileModel) {
        start = model.windowArrivalNow()
        model.windowArrivalNow = { [self] in start.addingTimeInterval(elapsed) }
    }
}

@MainActor
func waitForWindowEventsToDrain(_ model: BetterTileModel, _ system: FakeAppWindowSystem? = nil) async throws {
    if let system {
        try #require(await system.waitFor {
            (model.windowEventTask == nil || model.windowEventTask?.isCancelled == true)
                && model.settlementTasks.isEmpty
        })
        await system.joinWindowEvent(on: model)
        return
    }
    try #require(await waitFor {
        (model.windowEventTask == nil || model.windowEventTask?.isCancelled == true)
            && model.settlementTasks.isEmpty
    })
    // Shutdown retains a cancelled task handle. Await completion before calling it quiet.
    await model.windowEventTask?.value
}

/// Pane application deadlines, click limits, and arrival guards read this clock instead of system uptime.
/// It moves only when a test advances it, so a slow full-suite run cannot expire a guard or a timeout.
@MainActor
final class PaneApplicationTestClock {
    var now: TimeInterval

    init(_ model: BetterTileModel) {
        now = model.paneApplicationUptime()
        model.paneApplicationUptime = { [self] in self.now }
    }

    /// An event timestamp at the current test time, in nanoseconds of uptime.
    var timestamp: UInt64 { UInt64(now * 1_000_000_000) }
}
