import AppKit
import Testing

/// Native layout must advance for hosted SwiftUI content. Observe geometry rather than
/// waiting a fixed number of milliseconds, and require consecutive stable layouts.
@MainActor private final class SavedLayoutSnapshotGeometry {
    private var previous: [NSRect]?
    private var stablePasses = 0

    func observe(_ view: NSView) -> Bool {
        func geometry(_ node: NSView) -> [NSRect] {
            [node.frame, node.bounds] + node.subviews.flatMap(geometry)
        }
        guard view.window != nil, !view.bounds.isEmpty,
              view.fittingSize.width > 0, view.fittingSize.height > 0 else { return false }
        let current = geometry(view)
        stablePasses = current == previous ? stablePasses + 1 : 0
        previous = current
        return stablePasses >= 2 && !view.needsLayout
    }
}

@MainActor func waitForSavedLayoutSnapshot(in view: NSView, until ready: () -> Bool = { true }) async throws {
    let geometry = SavedLayoutSnapshotGeometry()
    try await waitForSettingsUI("stable Saved Layout snapshot geometry", in: view) {
        ready() && geometry.observe(view)
    }
}

/// Static synchronous fixtures service native layout invalidations. Task-fed fixtures must use
/// the async helper and wait for the content they assert, so the main actor can run those tasks.
@MainActor func settleSavedLayoutSnapshot(_ view: NSView, until ready: () -> Bool = { true }) throws {
    let geometry = SavedLayoutSnapshotGeometry()
    let clock = ContinuousClock() // real-time: bounds native AppKit layout readiness in synchronous snapshot fixtures
    let deadline = clock.now.advanced(by: .seconds(5))
    repeat {
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        if ready() && geometry.observe(view) { return }
        RunLoop.main.run(until: Date().addingTimeInterval(0.01)) // real-time: services native AppKit and SwiftUI layout between geometry observations
    } while clock.now < deadline
    let settled = ready() && geometry.observe(view)
    try #require(settled, "Saved Layout snapshot geometry did not settle.")
}
