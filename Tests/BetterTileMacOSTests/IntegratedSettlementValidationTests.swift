import Testing
@testable import BetterTileCore
@testable import BetterTileMacOS

@Test(.macOSTestApplication, arguments: ["fractional", "overlap-allowed", "overlap-rejected", "retry"], [false, true])
@MainActor func integratedSettlementValidatorAndGeometry(kind: String, valid: Bool) async throws {
    let system = FakeWindowSystem(); system.addSecondWindow()
    let coordinator = WindowCoordinator(system: system)
    let left = system.windows[0].id, right = system.windows[1].id
    let placements = [Placement(windowID: left, frame: BTRect(x: 0, y: 0, width: 499.5, height: 800)),
                      Placement(windowID: right, frame: BTRect(x: 500.5, y: 0, width: 499.5, height: 800))]
    for (index, placement) in placements.enumerated() { system.windows[index].frame = placement.frame }
    switch kind {
    case "fractional": for i in system.windows.indices { system.windows[i].frame.size.height -= 1.5 }
    case "overlap-allowed": system.windows[0].frame.size.width += 2; system.windows[1].frame.origin.x -= 1
    case "overlap-rejected": system.windows[0].frame.origin.x += 1.5; system.windows[0].frame.size.width += 1.5; system.windows[1].frame.origin.x -= 1.5
    default: system.windows[0].frame.size.height -= 3
    }
    var checks = 0
    let outcome = await coordinator.settleAuthoritativePlacements(placements, retryDelay: .zero, validating: { checks += 1; return valid })
    #expect(outcome.isApplied == (valid && kind != "overlap-rejected"))
    #expect(checks > 0)
    if !valid {
        #expect(outcome.failureReason == "The desktop changed before settlement.")
        #expect(system.frameWriteCounts.isEmpty)
    } else if kind == "retry" {
        #expect(system.frameWriteCounts == [left: 1]); #expect(checks >= 3)
    } else {
        #expect(system.frameWriteCounts.isEmpty); #expect(checks == 1)
    }
}
