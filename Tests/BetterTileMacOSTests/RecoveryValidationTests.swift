import Testing
@testable import BetterTileCore
@testable import BetterTileMacOS

@Test(.macOSTestApplication, arguments: ["applied", "failed", "degraded"], ["placement", "retry"])
@MainActor func recoveryValidationPreservesTransactionOutcomes(kind: String, operation: String) async {
    let system = FakeWindowSystem()
    system.addSecondWindow()
    let ids = system.windows.map(\.id)
    let baseline = system.windows.map(\.frame)
    let coordinator = WindowCoordinator(system: system)
    let placements = [Placement(windowID: ids[0], frame: BTRect(x: 0, y: 0, width: 500, height: 800)),
                      Placement(windowID: ids[1], frame: BTRect(x: 500, y: 0, width: 500, height: 800))]
    if kind != "applied" { system.partiallyFailedFrameWriteNumbers[ids[1]] = [1] }
    if kind == "degraded" { system.failedFrameWriteNumbers[ids[0]] = [2] }
    var checks = 0
    let valid = { checks += 1; return true }
    let outcome = if operation == "retry" {
        await coordinator.settleAuthoritativePlacements(placements, retryDelay: .zero, revalidateBeforeEachWrite: true, validating: valid)
    } else {
        coordinator.applyPlacements(placements, revalidateBeforeEachWrite: true, validating: valid)
    }
    // Preflight and every forward or rollback write retain authorization.
    let expectedChecks = operation == "retry" ? 6 : (kind == "applied" ? 4 : 5)
    #expect(checks == expectedChecks)
    let writes = kind == "applied" ? 1 : 2
    #expect(system.frameWriteCounts == [ids[0]: writes, ids[1]: writes])
    #expect(system.probedWindowIDs.isEmpty)
    #expect(system.minimizeWriteCounts.isEmpty)
    switch kind {
    case "applied": #expect(outcome.isApplied)
    case "failed":
        guard case .failed = outcome else { Issue.record("Clean rollback must fail: \(outcome)"); return }
        #expect(system.windows.map(\.frame) == baseline)
    default:
        guard case .degraded = outcome else { Issue.record("Incomplete rollback must degrade: \(outcome)"); return }
        #expect(system.windows.map(\.frame) != baseline)
    }
}

@Test(.macOSTestApplication, arguments: ["placement", "focus", "probe", "retry"], [false, true])
@MainActor func recoveryStaleValidationDoesNotTakeWriteOwnership(kind: String, readFails: Bool) async {
    let system = FakeWindowSystem()
    let id = system.windows[0].id, baseline = system.windows[0].frame
    let coordinator = WindowCoordinator(system: system)
    let generation = coordinator.mutationGeneration(for: id)
    var checks = 0
    system.targetedSnapshotsFail = readFails
    let valid = { checks += 1; return false }
    let placement = Placement(windowID: id, frame: BTRect(x: 0, y: 0, width: 500, height: 800))
    let outcome: WindowMutationOutcome
    switch kind {
    case "placement": outcome = coordinator.applyPlacements([placement], validating: valid)
    case "focus": outcome = coordinator.applyFocusDrop(placement: placement, minimizing: [], sourceBaselineFrame: baseline, validating: valid)
    case "retry":
        outcome = await coordinator.settleAuthoritativePlacements([placement], retryDelay: .zero, revalidateBeforeEachWrite: true, validating: valid)
    default: outcome = coordinator.probeMinimumSizes(for: [id], validating: valid)
    }
    guard case .failed = outcome else { Issue.record("No mutation should have started: \(outcome)"); return }
    #expect(system.frameWriteCounts.isEmpty)
    #expect(system.probedWindowIDs.isEmpty)
    #expect(system.minimizeWriteCounts.isEmpty)
    #expect(coordinator.mutationGeneration(for: id) == generation)
    #expect(checks == ((!readFails || kind == "probe") ? 1 : 0))
}
