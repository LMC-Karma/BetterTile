import AppKit
import BetterTileCore
import BetterTileMacOS
import Testing
@testable import BetterTileApp

@MainActor func councilStore(_ model: BetterTileModel) throws -> LayoutSessionStore {
    try #require(Mirror(reflecting: model).children.first {
        $0.label?.hasSuffix("sessionStore") == true
    }?.value as? LayoutSessionStore)
}

@Test(.appTestApplication, arguments: ["sleep", "lock", "inactive", "screensaver"]) @MainActor
func displayHoldDoesNotPollWindowsWhileSleepingOrLocked(reason: String) async throws {
    let system = makeManualWindowSystem(drivingPolicyDeadlines: true)
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.setActiveMode(.bento)
    await system.advance(by: .seconds(1))
    let before = try councilStore(model).session(for: system.mainDisplay.id)
    let locked = reason == "lock" || reason == "screensaver"
    if locked {
        model.displayChangeScreenIsLocked = { true }
        model.handleDisplayChangeApplicationActivation(bundleID: reason == "lock" ? "com.apple.loginwindow" : "com.apple.ScreenSaver.Engine")
    } else { model.handleDisplayChange(reason == "inactive" ? .sessionResigned : .sleep) }
    system.offscreenWindowIDs = Set(system.windows.map(\.id))
    let sweeps = system.completeSweepCount
    let writes = system.frameWriteCounts
    for _ in 0..<240 { model.watchdog(); await system.advance(by: .milliseconds(250)) }
    #expect(system.completeSweepCount - sweeps <= 1)
    #expect(system.frameWriteCounts == writes)
    let held = try councilStore(model).session(for: system.mainDisplay.id)
    #expect(held?.bentoState == before?.bentoState)
    #expect(held?.presence == before?.presence)
    #expect(model.isHoldingDisplayChange)
    system.offscreenWindowIDs = []
    model.displayChangeScreenIsLocked = { false }
    if locked { model.handleDisplayChangeApplicationActivation(bundleID: "org.example.Editor") }
    else if reason == "inactive" { model.handleDisplayChange(.sessionBecameActive) }
    else { model.handleApplicationTopologyChange(waking: true) }
    await system.advance(by: .seconds(1))
    #expect(await system.waitFor { !model.isHoldingDisplayChange && model.windowEventTask == nil })
    #expect(try councilStore(model).session(for: system.mainDisplay.id)?.bentoState == before?.bentoState)
}

@Test(.appTestApplication) @MainActor
func displayHoldDetectsUnlockWithoutAnotherActivation() async throws {
    let system = makeManualWindowSystem(drivingPolicyDeadlines: true)
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.displayChangeScreenIsLocked = { true }
    model.handleApplicationTopologyChange(waking: true)
    await system.advance(by: .seconds(2))
    model.displayChangeScreenIsLocked = { false }
    #expect(await system.waitFor(timeout: .seconds(4)) { !model.isHoldingDisplayChange })
}

@Test(.appTestApplication) @MainActor
func displayHoldCoversScreenSaverActivation() async throws {
    let system = makeManualWindowSystem(drivingPolicyDeadlines: true)
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.handleDisplayChangeApplicationActivation(bundleID: "com.apple.ScreenSaver.Engine")
    #expect(model.isHoldingDisplayChange)
    model.handleDisplayChangeApplicationActivation(bundleID: "org.example.Editor")
    await system.advance(by: .seconds(1))
    #expect(!model.isHoldingDisplayChange)
}

@Test(.appTestApplication) @MainActor
func displayHoldWaitsForEveryReconfigurationCompletion() async throws {
    let system = makeManualWindowSystem(drivingPolicyDeadlines: true)
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.handleDisplayReconfiguration(.beginConfigurationFlag)
    model.handleDisplayReconfiguration(.beginConfigurationFlag)
    model.handleDisplayReconfiguration([])
    await system.advance(by: .seconds(1))
    #expect(model.isHoldingDisplayChange)
    model.handleDisplayReconfiguration([])
    await system.advance(by: .seconds(1))
    #expect(!model.isHoldingDisplayChange)
}

@Test(.appTestApplication) @MainActor
func anotherDisplayEventEndsAnExplicitHoldOverride() async throws {
    let system = makeManualWindowSystem(drivingPolicyDeadlines: true)
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.handleDisplayChange(.displayReconfigurationBegan)
    model.perform(.leftHalf)
    try #require(!system.requestedFrames.isEmpty)
    model.handleDisplayChange(.sleep)
    let writes = system.frameWriteCounts
    system.windows.append(WindowSnapshot(id: WindowID(rawValue: "arrival"), processIdentifier: 43,
        frame: BTRect(x: 50, y: 50, width: 300, height: 300), displayID: system.mainDisplay.id))
    model.handleApplicationTopologyChange()
    await system.advance(by: .seconds(1))
    #expect(system.frameWriteCounts == writes)
}

@Test(.appTestApplication, arguments: [LayoutMode.bento, .tabbed], [false, true]) @MainActor
func savedApplyNeverRollsBackThroughANewerDisplayHold(mode: LayoutMode, automatic: Bool) async throws {
    let system = makeManualWindowSystem(drivingPolicyDeadlines: true)
    let h = ApplyHarness(system: system)
    defer { h.close() }
    h.addWindow()
    let model = makeModel(system: system)
    defer { model.shutdown() }
    let applier = try #require(model.savedLayoutApplier)
    applier.observesKeyboard = false
    applier.application = h.applier.application
    var atHold: [WindowID: Int]?
    system.onWindowSnapshots = { [weak model, weak system] in
        guard let model, let system, atHold == nil,
              system.frameWriteCounts.values.contains(where: { $0 > 0 }) else { return }
        atHold = system.frameWriteCounts
        model.handleDisplayChange(.displayReconfigurationBegan)
    }
    var finished = false
    let task = Task { @MainActor in
        _ = await applier.apply(h.document(mode: mode), automatic: automatic)
        finished = true
    }
    try #require(await system.waitFor { finished })
    await task.value
    let writes = try #require(atHold, "The hold must start after a forward write")
    #expect(system.frameWriteCounts == writes, "Recovery must not write during an unsettled display configuration")
    system.onWindowSnapshots = nil
    #expect(applier.message?.contains("could not be restored") != true)
    model.handleDisplayChange(.displayReconfigurationEnded)
    await system.advance(by: .seconds(2))
    try #require(await system.waitFor { !model.isHoldingDisplayChange && !model.hasPendingTabbedPlacement && model.windowEventTask == nil })
    #expect(try councilStore(model).session(for: system.mainDisplay.id)?.automaticWritesSuspended == false)
}

@Test(.appTestApplication, arguments: [false, true]) @MainActor
func displayHoldHandsOffInterruptedTabbedRecovery(failsWrite: Bool) async throws {
    let system = makeManualWindowSystem(drivingPolicyDeadlines: true)
    let model = makeModel(system: system)
    defer { model.shutdown() }
    let display = system.mainDisplay.id, source = system.windows[0].id
    model.setActiveMode(.tabbed)
    try #require(await system.waitFor { !model.hasPendingTabbedPlacement })
    try #require(model.beginBentoDrag(displayID: display, sourceID: source))
    system.windows[0].frame.origin.x += 140
    let writes = system.frameWriteCounts[source, default: 0]
    if failsWrite { system.failedFrameWriteNumbers[source] = [writes + 1] }
    else { system.ignoredFrameWriteWindowIDs = [source] }
    var readAfterRestore = false
    system.onWindowSnapshots = {
        if system.frameWriteCounts[source, default: 0] > writes { readAfterRestore = true }
    }
    model.finishBentoDrag(displayID: display, sourceID: source, end: .failed(reason: "That pane cannot hold it."))
    try #require(await system.waitFor { readAfterRestore })
    model.handleDisplayChange(.displayReconfigurationBegan)
    let heldWrites = system.frameWriteCounts
    await system.advance(by: .seconds(1))
    try #require(await system.waitFor { !model.hasPendingTabbedPlacement })
    #expect(system.frameWriteCounts == heldWrites)
    #expect(try councilStore(model).session(for: display)?.automaticWritesSuspended == failsWrite)
    system.ignoredFrameWriteWindowIDs = []
    system.failedFrameWriteNumbers = [:]
    model.handleDisplayChange(.displayReconfigurationEnded)
    await system.advance(by: .seconds(1))
    try #require(await system.waitFor { !model.isHoldingDisplayChange && !model.hasPendingTabbedPlacement && model.windowEventTask == nil })
    #expect(try councilStore(model).session(for: display)?.automaticWritesSuspended == failsWrite)
    if !failsWrite {
        #expect(system.windows[0].frame.origin.x == 0)
        let arrival = WindowSnapshot(id: WindowID(rawValue: "arrival"), processIdentifier: 43,
            frame: BTRect(x: 50, y: 50, width: 300, height: 300), displayID: display)
        system.windows.append(arrival)
        system.eventHandler?(WindowSystemEvent(kind: .created, windowID: arrival.id, processIdentifier: 43))
        await system.advance(by: .seconds(1))
        try #require(await system.waitFor { !model.hasPendingTabbedPlacement && model.windowEventTask == nil })
        #expect(model.activeTabbedState?.windowIDs.contains(arrival.id) == true)
        #expect(system.frameWriteCounts[arrival.id, default: 0] > 0)
    }
}

@Test(.appTestApplication) @MainActor
func desktopSwitchDuringDisplayHoldStillCancelsSavedApply() throws {
    let system = makeManualWindowSystem(drivingPolicyDeadlines: true)
    let model = makeModel(system: system)
    defer { model.shutdown() }
    let applier = try #require(model.savedLayoutApplier)
    model.handleDisplayChange(.displayReconfigurationBegan)
    try #require(applier.message != "Saved Layout cancelled.")
    model.beginActiveSpaceStabilization()
    #expect(applier.message == "Saved Layout cancelled.")
    #expect(model.isHoldingDisplayChange)
    #expect(!model.isStabilizingSpace)
}
