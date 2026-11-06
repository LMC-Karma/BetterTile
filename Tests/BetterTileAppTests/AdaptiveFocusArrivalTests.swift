import BetterTileCore
import BetterTileMacOS
import Testing
@testable import BetterTileApp

/// Creation notifications consumed by the Focus wait must resume ordinary
/// arrival placement when the saved tree has been restored successfully.
@Test(.appTestApplication, .timeLimit(.minutes(1)), arguments: [1, 2], [false, true]) @MainActor
func adaptiveArrivalDuringFocusRestoreJoinsWithoutAnotherEvent(arrivalCount: Int, rejectRestore: Bool) async throws {
    let system = makeManualWindowSystem(drivingPolicyDeadlines: true)
    for name in ["first-peer", "slow-peer"] {
        system.windows.append(WindowSnapshot(id: WindowID(rawValue: name), processIdentifier: 43,
            frame: BTRect(x: 100, y: 100, width: 300, height: 300), displayID: system.mainDisplay.id))
    }
    system.emitsMinimizationEvents = true
    let model = makeModel(system: system)
    let drag = try #require(Mirror(reflecting: model).children.first {
        $0.label?.hasSuffix("dragSnap") == true
    }?.value as? DragSnapController)
    drag.primaryButtonIsPressed = { false }
    defer { model.shutdown() }
    model.configuration.bentoInnerGap = 0
    model.setActiveMode(.bento)
    try #require(await system.waitFor { system.frameWriteCounts.count == 3 })
    await system.advance(by: .milliseconds(350))
    await system.joinWindowEvent(on: model)
    for task in Array(model.settlementTasks.values) { await system.joinSettlement(task, on: model) }
    system.focusedID = system.windows[0].id
    model.perform(.maximize)
    try #require(system.windows.dropFirst().allSatisfy { $0.isMinimized })
    await system.advance(by: .milliseconds(350))
    await system.joinWindowEvent(on: model)
    let slow = system.windows[2].id
    system.slowRestoreIDs = [slow]
    model.perform(.restore)
    let clock = try #require(system.manualClock)
    let now = clock.now
    try #require(await system.waitFor(stoppingTimeAt: now) {
        clock.hasSleeper(until: now.advanced(by: .milliseconds(50)))
    })
    await system.advance(by: .milliseconds(150))

    let arrivals = (0..<arrivalCount).map { index in
        WindowSnapshot(id: WindowID(rawValue: "arrival-\(index)"), processIdentifier: 44,
            frame: BTRect(x: 100, y: 100, width: 300, height: 300), displayID: system.mainDisplay.id)
    }
    for arrival in arrivals {
        system.windows.append(arrival)
        system.eventHandler?(WindowSystemEvent(kind: .created, windowID: arrival.id, processIdentifier: 44))
    }
    await system.advance(by: .milliseconds(300))
    await system.joinWindowEvent(on: model)
    for arrival in arrivals { #expect(system.frameWriteCounts[arrival.id, default: 0] == 0) }
    let focusedID = system.windows[0].id
    if rejectRestore {
        system.failedFrameWriteNumbers[focusedID] = [system.frameWriteCounts[focusedID, default: 0] + 1]
    }
    system.slowRestoreIDs = []
    // The wait's inventory sees the returned peer without another event that
    // could otherwise conceal the missing arrival reconciliation.
    system.emitsMinimizationEvents = false
    try system.setMinimized(false, for: slow)
    try #require(await system.waitFor {
        rejectRestore ? model.statusMessage?.contains("Use Repair") == true
            : system.windows[0].frame != system.mainDisplay.visibleFrame
    })
    await system.joinWindowEvent(on: model)
    for task in Array(model.settlementTasks.values) { await system.joinSettlement(task, on: model) }
    if rejectRestore {
        for arrival in arrivals { #expect(system.frameWriteCounts[arrival.id, default: 0] == 0) }
    } else {
        for arrival in arrivals {
            #expect(model.dividerResize.bentoStateProvider?(system.mainDisplay.id)?.root?.windowIDs.contains(arrival.id) == true)
            #expect(system.frameWriteCounts[arrival.id, default: 0] > 0)
        }
        let frames = Dictionary(uniqueKeysWithValues: system.windows.map { ($0.id, $0.frame) })
        #expect(BentoLayoutVerifier.overlappingWindowIDs(frames).isEmpty)
    }
    let writes = system.frameWriteCounts
    await system.advance(by: .milliseconds(500))
    await system.joinWindowEvent(on: model)
    #expect(system.frameWriteCounts == writes)
}
