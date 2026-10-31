import BetterTileCore
import Testing
@testable import BetterTileApp

@Test(.appTestApplication, arguments: ["mode", "workArea", "desktop"]) @MainActor
func authoritativeRepairRetryStopsWhenItsOwnerChanges(change: String) async throws {
    let system = FakeAppWindowSystem()
    system.windows.append(WindowSnapshot(id: WindowID(rawValue: "peer"), processIdentifier: 43,
        frame: BTRect(x: 500, y: 0, width: 500, height: 800), displayID: system.mainDisplay.id))
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.tileCurrentDisplay()
    try await finishAuthoritativeSettlement(model, system)
    system.frameReadbackTransform = { _, requested in
        var actual = requested
        actual.size.height -= 3
        return actual
    }
    model.tileCurrentDisplay()
    let sampling = try #require(model.settlementTasks[system.mainDisplay.id])
    await sampling.value
    let retry = try #require(model.settlementTasks[system.mainDisplay.id])
    let writes = system.frameWriteCounts
    switch change {
    case "mode": model.setActiveMode(.manual)
    case "workArea": system.availableDisplays[0].visibleFrame.size.height -= 50
    default:
        let space = NativeSpaceID(rawValue: 99)
        system.desktopObservation = NativeDesktopObservation(
            currentSpaceByDisplay: [system.mainDisplay.id: space],
            knownSpacesByDisplay: [system.mainDisplay.id: [space]])
    }
    await retry.value
    #expect(system.frameWriteCounts == writes)
}

@Test(.appTestApplication, arguments: [false, true]) @MainActor
func authoritativeRoundingNeedsNoExtraSettlementPass(reflow: Bool) async throws {
    let system = FakeAppWindowSystem()
    let peer = WindowID(rawValue: "peer")
    system.windows.append(WindowSnapshot(
        id: peer, processIdentifier: 43,
        frame: BTRect(x: 500.5, y: 0, width: 499.5, height: 800), displayID: system.mainDisplay.id
    ))
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.tileCurrentDisplay()
    try await finishAuthoritativeSettlement(model, system)
    system.frameReadbackTransform = { _, requested in
        var actual = requested
        actual.size.height -= 1.5
        return actual
    }

    if reflow {
        system.availableDisplays[0].visibleFrame.size = BTSize(width: 800, height: 700)
        system.eventHandler?(WindowSystemEvent(kind: .created, windowID: peer, processIdentifier: 43))
        let eventTask = try #require(model.windowEventTask)
        await eventTask.value
    } else {
        model.tileCurrentDisplay()
    }
    let writes = system.frameWriteCounts
    let task = try #require(model.settlementTasks[system.mainDisplay.id])
    await task.value

    #expect(model.settlementTasks[system.mainDisplay.id] == nil)
    #expect(system.frameWriteCounts == writes)
    #expect(model.statusMessage == nil)
    for window in system.windows {
        let requested = try #require(system.requestedFrames[window.id]?.last)
        #expect(window.frame.size.height == requested.size.height - 1.5)
    }
}

@MainActor private func finishAuthoritativeSettlement(
    _ model: BetterTileModel, _ system: FakeAppWindowSystem
) async throws {
    for _ in 0..<3 {
        guard let task = model.settlementTasks[system.mainDisplay.id] else { break }
        await task.value
    }
    try #require(model.settlementTasks[system.mainDisplay.id] == nil)
}

@Test(.appTestApplication, arguments: [1.5, 2.0]) @MainActor
func authoritativeReflowRejectsCompoundOverlap(offset: Double) async throws {
    let system = FakeAppWindowSystem()
    let left = system.windows[0].id
    let right = WindowID(rawValue: "peer")
    system.windows.append(WindowSnapshot(
        id: right, processIdentifier: 43,
        frame: BTRect(x: 500.5, y: 0, width: 499.5, height: 800), displayID: system.mainDisplay.id
    ))
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.configuration.bentoInnerGap = 1
    model.tileCurrentDisplay()
    try await finishAuthoritativeSettlement(model, system)
    try #require(model.statusMessage == nil)
    system.frameReadbackTransform = { id, requested in
        var actual = requested
        actual.origin.x += id == left ? offset : -offset
        if id == left { actual.size.width += offset }
        return actual
    }
    system.availableDisplays[0].visibleFrame.size = BTSize(width: 800, height: 700)
    system.eventHandler?(WindowSystemEvent(kind: .created, windowID: right, processIdentifier: 43))
    let task = try #require(model.windowEventTask)
    await task.value
    try await finishAuthoritativeSettlement(model, system)
    let actual = Dictionary(uniqueKeysWithValues: system.windows.map { ($0.id, $0.frame) })
    let overlap = try #require(actual[left]?.intersection(actual[right]!)).size.width
    #expect(abs(overlap - (3 * offset - 1)) < 0.001)
    #expect(BentoLayoutVerifier.overlappingWindowIDs(actual) == [left, right])
    #expect(model.statusMessage == "One or more windows did not settle at the requested frame.")
}

@Test(.appTestApplication) @MainActor
func authoritativeRepairWithFractionalBottomReadbackDoesNotDrift() async throws {
    let system = FakeAppWindowSystem()
    let displayID = system.mainDisplay.id
    let bounds = BTRect(x: 0, y: 30, width: 2560, height: 1332)
    system.availableDisplays = [DisplaySnapshot(
        id: displayID, frame: BTRect(x: 0, y: 0, width: 2560, height: 1440),
        visibleFrame: bounds, isMain: true
    )]
    let ids = (0..<5).map { WindowID(rawValue: "fixture-\($0)") }
    func rows(_ a: Int, _ b: Int) -> BentoNode {
        .partition(BentoPartition(axis: .horizontal, children: [.leaf(ids[a]), .leaf(ids[b])]))
    }
    let tree = BentoLayoutState(
        root: .partition(BentoPartition(axis: .vertical, children: [.leaf(ids[0]), rows(1, 2), rows(3, 4)])),
        metrics: BentoLayoutMetrics(paneGap: 1)
    )
    let initial = tree.paneFrames(in: bounds)
    system.windows = ids.enumerated().map { index, id in
        WindowSnapshot(id: id, processIdentifier: Int32(42 + index), frame: initial[id]!, displayID: displayID)
    }
    system.focusedID = ids[0]
    system.frameReadbackTransform = { _, requested in
        var actual = requested
        actual.origin.x = requested.minX.rounded()
        actual.origin.y = requested.minY.rounded()
        actual.size.width = requested.size.width.rounded()
        actual.size.height = requested.size.height.rounded()
        if requested.size.height == 1332 { actual.size.height = 1331 }
        if requested.minY == 697 && requested.size.height == 665 { actual.size.height = 663.5 }
        return actual
    }
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.configuration.bentoInnerGap = 1
    var firstActual: [BTRect]?
    var firstRequested: [WindowID: BTRect]?
    for _ in 0..<10 {
        model.tileCurrentDisplay()
        try await finishAuthoritativeSettlement(model, system)
        #expect(model.statusMessage == nil)
        let actual = system.windows.map(\.frame)
        #expect(actual.contains { $0.minY == 697 && $0.size.height == 663.5 })
        let requested = system.requestedFrames.mapValues { $0.last! }
        if let firstActual { #expect(actual == firstActual) } else { firstActual = actual }
        if let firstRequested { #expect(requested == firstRequested) } else { firstRequested = requested }
    }
    #expect(firstRequested?.values.contains { $0.minY == 697 && $0.size.height == 665 } == true)
}
