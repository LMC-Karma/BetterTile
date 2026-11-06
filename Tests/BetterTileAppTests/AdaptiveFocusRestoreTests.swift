import BetterTileCore
import Testing
import BetterTileMacOS
@testable import BetterTileApp

@Test(.appTestApplication, .timeLimit(.minutes(1)), arguments: [false, true], [false, true]) @MainActor
func adaptiveFocusRestoreKeepsFourAsymmetricPanes(omitsReturningPeer: Bool, returnsAfterDeadline: Bool) async throws {
    let (system, model, ids, expected) = try await asymmetricFocusFixture()
    defer { model.shutdown() }
    let captured = try #require(model.captureLayoutWheelTarget())

    // Upper-right returns first. Lower-right is still restoring and can be
    // absent from an AX inventory even though its window has not closed.
    system.slowRestoreIDs = [ids[0], ids[3]]
    if omitsReturningPeer { system.offscreenWindowIDs = [ids[3]] }
    model.performLayoutWheel(.windowAction(.restore), for: captured)
    let clock = try #require(system.manualClock)
    let firstRetry = system.clock.now.advanced(by: .milliseconds(50))
    try #require(await system.waitFor(stoppingTimeAt: system.clock.now) { clock.hasSleeper(until: firstRetry) })
    await system.advance(by: .milliseconds(200))
    #expect(system.windows[2].frame == expected[ids[2]])
    system.slowRestoreIDs.remove(ids[0])
    try system.setMinimized(false, for: ids[0])
    await system.advance(by: .milliseconds(200))
    #expect(system.windows[2].frame == expected[ids[2]])
    if returnsAfterDeadline {
        await system.advance(by: .milliseconds(1700))
        await system.joinWindowEvent(on: model)
        // A resumed poll can register its next sleep after the large advance.
        // Drive that final poll before checking the completed restore.
        #expect(await system.waitFor(timeout: .milliseconds(200)) {
            system.windows[2].frame.size.height == 800
        })
    }
    system.offscreenWindowIDs = []
    system.slowRestoreIDs = []
    // The last peer becomes readable before its restored notification arrives.
    system.emitsMinimizationEvents = !omitsReturningPeer || returnsAfterDeadline
    try system.setMinimized(false, for: ids[3])
    await settleAdaptiveFocus(model, system: system)
    for window in system.windows {
        #expect(window.frame == expected[window.id], "\(window.id) must return to its pre-Maximize frame")
        #expect(!window.isMinimized)
    }
    let writes = system.frameWriteCounts
    await settleAdaptiveFocus(model, system: system)
    #expect(system.frameWriteCounts == writes)
}

@MainActor private func settleAdaptiveFocus(_ model: BetterTileModel, system: FakeAppWindowSystem) async {
    await system.advance(by: .milliseconds(350))
    await system.joinWindowEvent(on: model)
    for task in Array(model.settlementTasks.values) { await system.joinSettlement(task, on: model) }
    #expect(model.windowEventTask == nil && model.settlementTasks.isEmpty)
}

@Test(.appTestApplication, .timeLimit(.minutes(1)), arguments: [false, true]) @MainActor
func adaptiveFocusRestoreRemembersConfirmedClosure(whileRestoring: Bool) async throws {
    let (system, model, ids, expected) = try await asymmetricFocusFixture()
    defer { model.shutdown() }
    let captured = try #require(model.captureLayoutWheelTarget())
    system.slowRestoreIDs = [ids[3]]
    if whileRestoring {
        model.performLayoutWheel(.windowAction(.restore), for: captured)
        await system.advance(by: .milliseconds(200))
    }
    system.windows.removeAll { $0.id == ids[3] }
    system.eventHandler?(WindowSystemEvent(kind: .destroyed, windowID: ids[3], processIdentifier: 45))
    // A normal sweep may consume the destruction evidence before Restore.
    if !whileRestoring {
        await settleAdaptiveFocus(model, system: system)
        model.performLayoutWheel(.windowAction(.restore), for: captured)
    }
    await system.advance(by: .milliseconds(350))
    await system.joinWindowEvent(on: model)
    #expect(system.windows.allSatisfy { !$0.isMinimized })
    #expect(system.windows.first { $0.id == ids[0] }?.frame == expected[ids[0]])
    #expect(system.windows.first { $0.id == ids[1] }?.frame == expected[ids[1]])
    #expect(system.windows.first { $0.id == ids[2] }?.frame == BTRect(x: 580, y: 0, width: 420, height: 800))
}

@MainActor private func asymmetricFocusFixture() async throws
    -> (FakeAppWindowSystem, BetterTileModel, [WindowID], [WindowID: BTRect]) {
    let system = makeManualWindowSystem(drivingPolicyDeadlines: true)
    let ids = ["upper-left", "lower-left", "upper-right", "lower-right"].map { WindowID(rawValue: $0) }
    system.windows = ids.enumerated().map { index, id in
        WindowSnapshot(id: id, processIdentifier: Int32(42 + index), bundleIdentifier: "com.example.Pane\(index)",
            frame: BTRect(x: 100, y: 100, width: 300, height: 300), displayID: system.mainDisplay.id)
    }
    system.emitsMinimizationEvents = true
    system.emitsFrameEvents = true
    let model = makeModel(system: system)
    let drag = try #require(Mirror(reflecting: model).children.first {
        $0.label?.hasSuffix("dragSnap") == true
    }?.value as? DragSnapController)
    drag.primaryButtonIsPressed = { false }
    model.configuration.bentoInnerGap = 0
    model.setActiveMode(.bento)
    try #require(await system.waitFor { system.frameWriteCounts.count == 4 })
    await settleAdaptiveFocus(model, system: system)

    // Commit the result of an asymmetric divider resize, before opening the wheel.
    let state = BentoLayoutState(root: .partition(BentoPartition(axis: .vertical, weight: 0.58,
        first: .partition(BentoPartition(axis: .horizontal, weight: 0.52, first: .leaf(ids[0]), second: .leaf(ids[1]))),
        second: .partition(BentoPartition(axis: .horizontal, weight: 0.52, first: .leaf(ids[2]), second: .leaf(ids[3]))))))
    let placements = BentoLayoutEngine(state: state).placements(for: system.windows, in: system.mainDisplay)
    let baseline = Dictionary(uniqueKeysWithValues: system.windows.map { ($0.id, $0.frame) })
    let expected = Dictionary(uniqueKeysWithValues: placements.map { ($0.windowID, $0.frame) })
    for index in system.windows.indices { system.windows[index].frame = try #require(expected[system.windows[index].id]) }
    model.dividerResize.bentoStateChangedHandler?(system.mainDisplay.id, state, expected, baseline)
    await settleAdaptiveFocus(model, system: system)
    try #require(system.windows.allSatisfy { $0.frame == expected[$0.id] })
    try #require(expected[ids[2]]?.size.height == 416)
    system.focusedID = ids[1]
    let captured = try #require(model.captureLayoutWheelTarget())
    model.performLayoutWheel(.windowAction(.maximize), for: captured)
    try #require(system.windows[1].frame == system.mainDisplay.visibleFrame)
    try #require(system.windows.filter { $0.id != ids[1] }.allSatisfy { $0.isMinimized })
    await settleAdaptiveFocus(model, system: system)

    // Restore owns its writes; correctness must not depend on frame callbacks.
    system.emitsFrameEvents = false
    return (system, model, ids, expected)
}
