import Testing
@testable import BetterTileCore
@testable import BetterTileMacOS

@Test(.macOSTestApplication, arguments: [false, true]) @MainActor
func authoritativeSettlementChecksFloatingFramesWithoutRejectingTheirOverlap(landed: Bool) async {
    let system = FakeWindowSystem()
    system.addSecondWindow()
    let tiled = system.windows[0].id
    let floating = system.windows[1].id
    let coordinator = WindowCoordinator(system: system)
    let placements = [
        Placement(windowID: tiled, frame: BTRect(x: 0, y: 0, width: 600, height: 800)),
        Placement(windowID: floating, frame: BTRect(x: 200, y: 200, width: 600, height: 400))
    ]
    #expect(coordinator.applyPlacements(placements).isApplied)
    if !landed { system.windows[1].frame.origin.x += 5 }
    let writes = system.frameWriteCounts
    let outcome = await coordinator.settleAuthoritativePlacements(placements,
        maximumRetries: 0, retryDelay: .zero, floatingWindowIDs: [floating])
    #expect(outcome.isApplied == landed)
    #expect(system.frameWriteCounts == writes)
}

@Test(.macOSTestApplication, arguments: [1.5, 2.0]) @MainActor
func authoritativeSettlementRejectsCompoundOverlap(offset: Double) async throws {
    let system = FakeWindowSystem()
    system.addSecondWindow()
    let left = system.windows[0].id
    let right = system.windows[1].id
    let coordinator = WindowCoordinator(system: system)
    let placements = [
        Placement(windowID: left, frame: BTRect(x: 0, y: 0, width: 499.5, height: 800)),
        Placement(windowID: right, frame: BTRect(x: 500.5, y: 0, width: 499.5, height: 800))
    ]
    system.writeReadbackHandler = { [unowned system] id, requested, _, _ in
        let index = system.windows.firstIndex { $0.id == id }!
        var actual = requested
        actual.origin.x += id == left ? offset : -offset
        if id == left { actual.size.width += offset }
        system.windows[index].frame = actual
    }
    #expect(coordinator.applyPlacements(placements).isApplied)
    let frames = Dictionary(uniqueKeysWithValues: system.windows.map { ($0.id, $0.frame) })
    let overlap = try #require(frames[left]?.intersection(frames[right]!)).size.width
    #expect(abs(overlap - (3 * offset - 1)) < 0.001)
    #expect(BentoLayoutVerifier.overlappingWindowIDs(frames) == [left, right])
    let outcome = await coordinator.settleAuthoritativePlacements(placements, retryDelay: .zero)
    #expect(outcome == .failed(reason: "One or more windows did not settle at the requested frame."))
    #expect(system.frameWriteCounts[left] == 1)
    #expect(system.frameWriteCounts[right] == 1)
}

@Test(.macOSTestApplication) @MainActor
func authoritativeSettlementAcceptsVerifierOverlapAllowance() async throws {
    let system = FakeWindowSystem()
    system.addSecondWindow()
    let left = system.windows[0].id
    let right = system.windows[1].id
    let coordinator = WindowCoordinator(system: system)
    let placements = [
        Placement(windowID: left, frame: BTRect(x: 0, y: 0, width: 499.5, height: 800)),
        Placement(windowID: right, frame: BTRect(x: 500.5, y: 0, width: 499.5, height: 800))
    ]
    system.writeReadbackHandler = { [unowned system] id, requested, _, _ in
        let index = system.windows.firstIndex { $0.id == id }!
        var actual = requested
        if id == left { actual.size.width += 2 } else { actual.origin.x -= 1 }
        system.windows[index].frame = actual
    }
    #expect(coordinator.applyPlacements(placements).isApplied)
    let frames = Dictionary(uniqueKeysWithValues: system.windows.map { ($0.id, $0.frame) })
    #expect(frames[left]?.intersection(frames[right]!)?.size.width == 2)
    #expect(BentoLayoutVerifier.overlappingWindowIDs(frames).isEmpty)
    #expect((await coordinator.settleAuthoritativePlacements(placements, retryDelay: .zero)).isApplied)
}

@Test(.macOSTestApplication) @MainActor
func authoritativeSettlementDoesNotAccumulateFractionalRounding() async throws {
    let system = FakeWindowSystem()
    system.availableDisplays = [DisplaySnapshot(
        id: DisplayID(rawValue: "main"), frame: BTRect(x: 0, y: 0, width: 2560, height: 1440),
        visibleFrame: BTRect(x: 0, y: 30, width: 2560, height: 1332), isMain: true
    )]
    let coordinator = WindowCoordinator(system: system)
    let id = system.windows[0].id
    let requested = BTRect(x: 1707.3333333333333, y: 696.5, width: 852.6666666666667, height: 665.5)
    let actual = BTRect(x: 1707, y: 697, width: 853, height: 664)
    system.writeReadbackHandler = { [unowned system] _, _, _, _ in system.windows[0].frame = actual }
    let placements = [Placement(windowID: id, frame: requested)]
    for _ in 0..<20 {
        #expect(coordinator.applyPlacements(placements).isApplied)
        #expect((await coordinator.settleAuthoritativePlacements(placements, retryDelay: .zero)).isApplied)
        #expect(system.windows[0].frame == actual)
    }
    #expect(system.frameWriteCounts[id] == 20)
}
