import BetterTileCore
import BetterTileMacOS
import Testing
@testable import BetterTileApp

/// Creation notifications consumed by the Focus wait must resume ordinary
/// arrival placement when the saved tree has been restored successfully.
@Test(.appTestApplication, .timeLimit(.minutes(1)), arguments: [1, 2], [false, true]) @MainActor
func adaptiveArrivalDuringFocusRestoreJoinsWithoutAnotherEvent(arrivalCount: Int, rejectRestore: Bool) async throws {
    try await exerciseAdaptiveFocusArrival(arrivalCount: arrivalCount, rejectRestore: rejectRestore)
}

@Test(.appTestApplication, .timeLimit(.minutes(1)), arguments: [false, true]) @MainActor
func adaptiveFocusArrivalMeasuresHiddenMinimumBeforePlacement(rejectRestore: Bool) async throws {
    try await exerciseAdaptiveFocusArrival(arrivalCount: 1, rejectRestore: rejectRestore, hiddenMinimum: true)
}

@Test(.appTestApplication, .timeLimit(.minutes(1))) @MainActor
func adaptiveFocusArrivalRetriesAfterStaleRestore() async throws {
    try await exerciseAdaptiveFocusArrival(arrivalCount: 1, rejectRestore: false, hiddenMinimum: true, staleRestore: true)
}

@MainActor private func exerciseAdaptiveFocusArrival(
    arrivalCount: Int, rejectRestore: Bool, hiddenMinimum: Bool = false, staleRestore: Bool = false
) async throws {
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
    defer { system.onBeforeFrameWrite = nil; system.onWindowSnapshots = nil; model.shutdown() }
    model.configuration.bentoInnerGap = 0
    model.setActiveMode(.bento)
    try #require(await system.waitFor { system.frameWriteCounts.count == 3 })
    await system.advance(by: .milliseconds(350))
    await system.joinWindowEvent(on: model)
    for task in Array(model.settlementTasks.values) { await system.joinSettlement(task, on: model) }
    let floatingID = WindowID(rawValue: "intentional-float")
    let hasIntentionalFloat = hiddenMinimum && !staleRestore
    if hasIntentionalFloat {
        // A deliberate float is represented in the layout, even though its
        // window snapshot is otherwise eligible for Adaptive.
        system.windows.append(WindowSnapshot(id: floatingID, processIdentifier: 46,
            frame: BTRect(x: 80, y: 80, width: 200, height: 200), displayID: system.mainDisplay.id))
        var state = try #require(model.dividerResize.bentoStateProvider?(system.mainDisplay.id))
        state.floatingWindowIDs.insert(floatingID)
        let frames = Dictionary(uniqueKeysWithValues: system.windows.map { ($0.id, $0.frame) })
        model.dividerResize.bentoStateChangedHandler?(system.mainDisplay.id, state, frames, frames)
        model.handleApplicationTopologyChange()
        await system.joinWindowEvent(on: model)
        for task in Array(model.settlementTasks.values) { await system.joinSettlement(task, on: model) }
    }
    let expectedPeerFrames = Dictionary(uniqueKeysWithValues: system.windows.map { ($0.id, $0.frame) })
    system.focusedID = system.windows[0].id
    model.perform(.maximize)
    try #require(system.windows.dropFirst().filter { $0.id != floatingID }.allSatisfy { $0.isMinimized })
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
            frame: BTRect(x: 100, y: 50, width: 300, height: hiddenMinimum ? 700 : 300), displayID: system.mainDisplay.id)
    }
    system.probeRequests = []
    system.measuresOnWrite = hiddenMinimum
    if hiddenMinimum { system.enforcedMinimumHeights[arrivals[0].id] = 600 }
    var measuredBeforeFirstWrite: [WindowID: Bool] = [:]
    let arrivalIDs = Set(arrivals.map(\.id))
    system.onBeforeFrameWrite = { id in
        if arrivalIDs.contains(id), measuredBeforeFirstWrite[id] == nil {
            measuredBeforeFirstWrite[id] = system.probeRequests.contains { $0.contains(id) }
                && (!hiddenMinimum || system.windows.first { $0.id == id }?.constraints.minimumSize.height == 600)
        }
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
    var invalidatedRestore = false
    if staleRestore {
        system.onWindowSnapshots = {
            guard !invalidatedRestore,
                  system.windows.filter({ expectedPeerFrames[$0.id] != nil }).allSatisfy({ $0.frame == expectedPeerFrames[$0.id] }),
                  let current = model.dividerResize.bentoStateProvider?(system.mainDisplay.id) else { return }
            invalidatedRestore = true
            // The frame batch succeeded. Its clamp readback re-enters the
            // model before the proposed session commits, invalidating that
            // revision without creating a failed rollback or a window event.
            model.dividerResize.bentoStateChangedHandler?(system.mainDisplay.id, current, [:], [:])
        }
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
    if staleRestore {
        #expect(invalidatedRestore)
        #expect(model.statusMessage?.contains("Use Repair") != true)
    }
    if rejectRestore {
        #expect(system.probeRequests.isEmpty)
        for arrival in arrivals { #expect(system.frameWriteCounts[arrival.id, default: 0] == 0) }
    } else {
        #expect(Set(system.probeRequests.flatMap { $0 }) == arrivalIDs)
        #expect(measuredBeforeFirstWrite.values.allSatisfy { $0 })
        for arrival in arrivals {
            #expect(model.dividerResize.bentoStateProvider?(system.mainDisplay.id)?.root?.windowIDs.contains(arrival.id) == true)
            #expect(system.frameWriteCounts[arrival.id, default: 0] > 0)
            #expect(measuredBeforeFirstWrite[arrival.id] == true)
            if hiddenMinimum {
                #expect(system.requestedFrames[arrival.id, default: []].allSatisfy { $0.size.height >= 600 })
            }
        }
        let frames = Dictionary(uniqueKeysWithValues: system.windows.filter { $0.id != floatingID }.map { ($0.id, $0.frame) })
        #expect(BentoLayoutVerifier.overlappingWindowIDs(frames).isEmpty)
    }
    if hasIntentionalFloat {
        if !rejectRestore {
            #expect(model.dividerResize.bentoStateProvider?(system.mainDisplay.id)?.floatingWindowIDs.contains(floatingID) == true)
        }
        #expect(system.windows.first { $0.id == floatingID }?.frame == BTRect(x: 80, y: 80, width: 200, height: 200))
    }
    let writes = system.frameWriteCounts
    await system.advance(by: .milliseconds(500))
    await system.joinWindowEvent(on: model)
    #expect(system.frameWriteCounts == writes)
}
