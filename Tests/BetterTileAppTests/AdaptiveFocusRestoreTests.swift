import BetterTileCore
import Testing
import BetterTileMacOS
@testable import BetterTileApp

// These tests run on the manual clock. Their time limits only catch a hang:
// in the full suite many main-actor tests share the executor, so the many
// policy steps of one restore can take far longer in wall time than alone.

@Test(.appTestApplication, .timeLimit(.minutes(5)), arguments: [false, true], [false, true]) @MainActor
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
    try await restoreAdaptiveFocusPeer(ids[0], model: model, system: system)
    await system.advance(by: .milliseconds(200))
    #expect(system.windows[2].frame == expected[ids[2]])
    if returnsAfterDeadline {
        // Drive the restore past its deadline on the manual clock, one policy
        // wait at a time, until it gives the upper-right pane the full column
        // and no event pass is left. The budget is virtual time, not wall time.
        #expect(await system.waitFor(timeout: .seconds(3)) {
            system.windows[2].frame.size.height == 800 && model.windowEventTask == nil
        })
    }
    system.offscreenWindowIDs = []
    system.slowRestoreIDs = []
    // The omitted, before-deadline case delivers no later notification.
    // Other cases explicitly synchronize the fake's asynchronous notification.
    system.emitsMinimizationEvents = !omitsReturningPeer || returnsAfterDeadline
    try await restoreAdaptiveFocusPeer(ids[3], model: model, system: system)
    await settleAdaptiveFocus(model, system: system)
    for window in system.windows {
        #expect(window.frame == expected[window.id], "\(window.id) must return to its pre-Maximize frame")
        #expect(!window.isMinimized)
    }
    let writes = system.frameWriteCounts
    await settleAdaptiveFocus(model, system: system)
    #expect(system.frameWriteCounts == writes)
}

/// Observe this peer's callback, not merely an older event pass. The fake
/// delivers restored notifications from a separate task after a yield.
@MainActor private func restoreAdaptiveFocusPeer(
    _ id: WindowID, model: BetterTileModel, system: FakeAppWindowSystem
) async throws {
    let originalHandler = system.eventHandler
    var delivered = false
    system.eventHandler = { event in
        originalHandler?(event)
        if event.kind == .restored && event.windowID == id { delivered = true }
    }
    defer { system.eventHandler = originalHandler }
    try system.setMinimized(false, for: id)
    if system.emitsMinimizationEvents {
        try #require(await system.waitFor(stoppingTimeAt: system.clock.now) {
            delivered && model.windowEventTask != nil
        })
    }
}

@MainActor private func settleAdaptiveFocus(_ model: BetterTileModel, system: FakeAppWindowSystem) async {
    for _ in 0..<10 {
        await system.advance(by: .milliseconds(350))
        await system.joinWindowEvent(on: model)
        for task in Array(model.settlementTasks.values) { await system.joinSettlement(task, on: model) }
        guard model.windowEventTask == nil && model.settlementTasks.isEmpty else { continue }
        // Joining one pass can release another callback or settlement task.
        // Require a whole additional clock step without new pending work.
        await system.advance(by: .milliseconds(50))
        if model.windowEventTask == nil && model.settlementTasks.isEmpty { return }
    }
    #expect(model.windowEventTask == nil && model.settlementTasks.isEmpty)
}

@Test(.appTestApplication, .timeLimit(.minutes(5))) @MainActor
func adaptiveFocusRestoreKeepsPeerHeightBeforeALateRestoredNotification() async throws {
    let (system, model, ids, expected) = try await asymmetricFocusFixture()
    defer { model.shutdown() }
    let captured = try #require(model.captureLayoutWheelTarget())
    system.slowRestoreIDs = [ids[0], ids[3]]
    system.offscreenWindowIDs = [ids[3]]
    model.performLayoutWheel(.windowAction(.restore), for: captured)
    let clock = try #require(system.manualClock)
    let retry = clock.now.advanced(by: .milliseconds(50))
    try #require(await system.waitFor(stoppingTimeAt: clock.now) { clock.hasSleeper(until: retry) })
    await system.advance(by: .milliseconds(200))
    system.slowRestoreIDs.remove(ids[0])
    try await restoreAdaptiveFocusPeer(ids[0], model: model, system: system)
    await system.advance(by: .milliseconds(200))
    // Main expands upper-right here even though the lower-right peer is alive.
    #expect(system.windows[2].frame == expected[ids[2]])
    system.offscreenWindowIDs = []
    system.slowRestoreIDs = []
    system.emitsMinimizationEvents = false
    try system.setMinimized(false, for: ids[3])
    await system.advance(by: .milliseconds(150))
    #expect(system.windows[2].frame == expected[ids[2]])
    // A genuinely late notification can heal main's overlap. It must not be
    // needed to prevent the intermediate full-column write.
    system.eventHandler?(WindowSystemEvent(kind: .restored, windowID: ids[3], processIdentifier: 45))
    await settleAdaptiveFocus(model, system: system)
    for window in system.windows { #expect(window.frame == expected[window.id]) }
    let writes = system.frameWriteCounts
    await settleAdaptiveFocus(model, system: system)
    #expect(system.frameWriteCounts == writes)
}

@Test(.appTestApplication, .timeLimit(.minutes(5)), arguments: [false, true]) @MainActor
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
    await settleAdaptiveFocus(model, system: system)
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
