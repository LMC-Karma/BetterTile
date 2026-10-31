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
