import Testing
@testable import BetterTileCore
@testable import BetterTileMacOS

@Test(.macOSTestApplication, arguments: ["preparation", "between", "restoreFailure"])
@MainActor func minimumProbeRevalidatesAtEachMeasurementBoundary(stage: String) {
    let system = FakeWindowSystem()
    system.addSecondWindow()
    let first = system.windows.map(\.id).sorted()[0]
    var current = true
    if stage == "preparation" { system.beforeProbeMeasurement = { _ in current = false } }
    else { system.afterProbeMeasurement = { _ in current = false } }
    if stage == "restoreFailure" { system.unrestoredProbeWindowIDs = [first] }
    let coordinator = WindowCoordinator(system: system)
    let outcome = coordinator.probeMinimumSizes(for: Set(system.windows.map(\.id)), validating: { current })
    if stage == "restoreFailure" {
        guard case .degraded = outcome else { Issue.record("Failed cleanup must retain degradation"); return }
    } else {
        guard case .failed = outcome else { Issue.record("Interrupted measurements are not a complete batch: \(outcome)"); return }
    }
    #expect(system.measurementWrites == (stage == "preparation" ? [] : [first]))
    // Finish the bounded cleanup of a started measurement despite invalidation.
    #expect(system.measurementRestores == system.measurementWrites)
    for window in system.windows where !system.measurementWrites.contains(window.id) {
        #expect(!coordinator.matchesExpectedMutation(windowID: window.id, actualFrame: window.frame))
    }
}
