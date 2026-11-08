import AppKit
import BetterTileCore
@testable import BetterTileMacOS
import Testing
@testable import BetterTileApp

@MainActor private func holdSettled(_ model: BetterTileModel, _ system: FakeAppWindowSystem) async throws {
    await system.advance(by: .seconds(2))
    try #require(await system.waitFor {
        !model.isHoldingDisplayChange && !model.hasPendingTabbedPlacement
            && model.windowEventTask == nil && model.settlementTasks.isEmpty
    })
}

/// Waits until the initial Adaptive placement has settled. Its settlement samples on
/// 40 ms clock waits that register off the main actor, so `advance` can reach its own
/// deadline first and return while settlement still runs. An action then meets a
/// desktop that is still settling.
@MainActor func adaptiveSettled(_ model: BetterTileModel, _ system: FakeAppWindowSystem) async throws {
    try #require(await system.waitFor { model.windowEventTask == nil && model.settlementTasks.isEmpty })
}

@Test(.appTestApplication, arguments: [false, true]) @MainActor
func displayHoldSavedApplyRestoresTreeAndTilesArrival(automatic: Bool) async throws {
    let system = makeManualWindowSystem(drivingPolicyDeadlines: true)
    let h = ApplyHarness(system: system)
    defer { h.close() }
    h.addWindow()
    h.addWindow("com.example.Other", id: "other", pid: 44)
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.setActiveMode(.bento)
    await system.advance(by: .seconds(1))
    // Apply refuses a desktop that still settles, so it would write nothing to interrupt.
    try await adaptiveSettled(model, system)
    let frames = system.windows.map(\.frame)
    let before = system.frameWriteCounts
    let applier = try #require(model.savedLayoutApplier)
    applier.observesKeyboard = false
    applier.application = h.applier.application
    var interrupted = false
    system.onWindowSnapshots = {
        guard !interrupted, system.frameWriteCounts != before else { return }
        interrupted = true
        model.handleDisplayChange(.displayReconfigurationBegan)
    }
    _ = await system.drive { await applier.apply(h.document(mode: .bento), automatic: automatic) }
    try #require(interrupted)
    let heldWrites = system.frameWriteCounts
    await system.advance(by: .seconds(1))
    #expect(system.frameWriteCounts == heldWrites)
    #expect(applier.message?.contains("could not be restored") != true)
    system.onWindowSnapshots = nil
    model.handleDisplayChange(.displayReconfigurationEnded)
    try await holdSettled(model, system)
    #expect(try sessionStore(of: model).session(for: system.mainDisplay.id)?.automaticWritesSuspended == false)
    #expect(system.windows.map(\.frame) == frames)
    let arrival = WindowSnapshot(id: .init(rawValue: "arrival"), processIdentifier: 45,
        frame: BTRect(x: 50, y: 50, width: 300, height: 300), displayID: system.mainDisplay.id)
    system.windows.append(arrival)
    system.eventHandler?(.init(kind: .created, windowID: arrival.id, processIdentifier: 45))
    await system.advance(by: .seconds(2))
    try #require(await system.waitFor { model.windowEventTask == nil && model.settlementTasks.isEmpty })
    #expect(system.frameWriteCounts[arrival.id, default: 0] > 0)
    #expect(try sessionStore(of: model).session(for: system.mainDisplay.id)?.bentoState.root?.windowIDs.contains(arrival.id) == true)
}

@Test(.appTestApplication, arguments: [LayoutMode.manual, .bento], [false, true]) @MainActor
func displayHoldStopsQueuedTabbedExit(destination: LayoutMode, pendingPlacement: Bool) async throws {
    try await queuedTabbedExitScenario(destination: destination, pendingPlacement: pendingPlacement, twoPanes: false)
}

/// Two occupied panes reach the Adaptive commit and the Manual baseline restoration with real frames.
@Test(.appTestApplication, arguments: [LayoutMode.manual, .bento], [false, true]) @MainActor
func displayHoldStopsQueuedTwoPaneTabbedExit(destination: LayoutMode, pendingPlacement: Bool) async throws {
    try await queuedTabbedExitScenario(destination: destination, pendingPlacement: pendingPlacement, twoPanes: true)
}

@MainActor private func queuedTabbedExitScenario(destination: LayoutMode, pendingPlacement: Bool, twoPanes: Bool) async throws {
    let system = makeManualWindowSystem(drivingPolicyDeadlines: true)
    if twoPanes {
        system.windows.append(.init(id: .init(rawValue: "peer"), processIdentifier: 43, bundleIdentifier: "com.example.Peer",
            frame: BTRect(x: 300, y: 200, width: 600, height: 400), displayID: system.mainDisplay.id))
    }
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.tabbedClock = system.clock
    model.setActiveMode(.tabbed)
    try #require(await system.waitFor { !model.hasPendingTabbedPlacement })
    if twoPanes {
        model.performTabbed(.preset(.columns, grouping: .distributeWindows))
        try #require(await system.waitFor { !model.hasPendingTabbedPlacement && model.windowEventTask == nil })
        try #require(model.activeTabbedState?.panes.filter { !$0.tabs.isEmpty }.count == 2)
    }
    if pendingPlacement { model.performTabbed(.preset(twoPanes ? .rows : .columns)) }
    model.setActiveMode(destination)
    model.handleDisplayChange(.displayReconfigurationBegan)
    let heldWrites = system.frameWriteCounts
    await system.advance(by: .seconds(1))
    #expect(system.frameWriteCounts == heldWrites)
    #expect(model.activeMode(for: system.mainDisplay.id) == .tabbed)
    model.handleDisplayChange(.displayReconfigurationEnded)
    try await holdSettled(model, system)
    #expect(model.activeMode(for: system.mainDisplay.id) == destination)
    #expect(try sessionStore(of: model).session(for: system.mainDisplay.id)?.automaticWritesSuspended == false)
    // A current explicit command still owns an override, unlike the old exit.
    model.handleDisplayChange(.displayReconfigurationBegan)
    let beforeAction = system.frameWriteCounts
    model.perform(.leftHalf)
    #expect(system.frameWriteCounts != beforeAction)
}

@Test(.appTestApplication, arguments: [false, true]) @MainActor
func displayHoldDefersAdaptiveDragRestoration(escape: Bool) async throws {
    let system = makeManualWindowSystem(drivingPolicyDeadlines: true)
    system.windows.append(.init(id: .init(rawValue: "peer"), processIdentifier: 43,
        frame: BTRect(x: 50, y: 50, width: 300, height: 300), displayID: system.mainDisplay.id))
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.setActiveMode(.bento)
    await system.advance(by: .seconds(1))
    try await adaptiveSettled(model, system)
    let source = system.windows[0].id
    let baseline = system.windows[0].frame
    try #require(model.beginBentoDrag(displayID: system.mainDisplay.id, sourceID: source))
    system.windows[0].frame.origin.x += 130
    let writes = system.frameWriteCounts
    if !escape { model.handleDisplayReconfiguration(.beginConfigurationFlag) }
    model.finishBentoDrag(displayID: system.mainDisplay.id, sourceID: source, end: .restore)
    if escape { #expect(system.windows[0].frame == baseline); return }
    await system.advance(by: .seconds(1))
    #expect(system.frameWriteCounts == writes)
    model.handleDisplayChange(.displayReconfigurationEnded)
    try await holdSettled(model, system)
    #expect(system.windows[0].frame == baseline)
    #expect(try sessionStore(of: model).session(for: system.mainDisplay.id)?.automaticWritesSuspended == false)
}

@Test(.appTestApplication, arguments: [false, true]) @MainActor
func displayHoldDefersLiveDividerRestoration(escape: Bool) async throws {
    try await liveDividerDisplayHoldScenario(escape: escape)
}

@Test(.appTestApplication) @MainActor
func displayHoldDebounceKeepsANewerDividerGesture() async throws {
    try await liveDividerDisplayHoldScenario(escape: false, startsAfterEvent: true)
}

@MainActor private func liveDividerDisplayHoldScenario(escape: Bool, startsAfterEvent: Bool = false) async throws {
    let system = makeManualWindowSystem(drivingPolicyDeadlines: true)
    let bounds = BTRect(x: -10_000, y: -10_000, width: 1000, height: 800)
    let display = system.mainDisplay.id
    system.availableDisplays = [.init(id: display, frame: bounds, visibleFrame: bounds, isMain: true)]
    system.windows[0].frame = bounds
    system.windows.append(.init(id: .init(rawValue: "peer"), processIdentifier: 43,
        frame: bounds, displayID: display))
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.configuration.resizeFeedbackMode = .live
    model.dividerResize.configuration = model.configuration
    model.setActiveMode(.bento)
    await system.advance(by: .seconds(1))
    try await adaptiveSettled(model, system)
    let state = try #require(sessionStore(of: model).session(for: display)?.bentoState)
    let boundaries = BentoBoundaryResolver().boundaries(state: state, windows: system.windows, displayID: display, bounds: bounds)
    let boundary = try #require(boundaries.first)
    let start = BTPoint(x: boundary.coordinate, y: (boundary.spanStart + boundary.spanEnd) / 2)
    let interaction = try #require(DividerInteractionResolver.resolve(at: start, in: boundaries, hitWidth: 18, adjacencyTolerance: 6, paneGap: state.metrics.paneGap))
    let controller = model.dividerResize
    controller.ownWindowsProvider = { [] }
    let baseline = system.windows.map(\.frame)
    if startsAfterEvent { model.handleDisplayReconfiguration(.beginConfigurationFlag) }
    controller.beginGesture(interaction: interaction, at: start)
    try #require(controller.isDragging)
    let screen = try #require(NSScreen.screens.first)
    controller.drag(to: CGPoint(x: start.x + 70, y: screen.frame.maxY - start.y))
    controller.displayTick()
    try #require(system.windows.map(\.frame) != baseline)
    let writes = system.frameWriteCounts
    if startsAfterEvent {
        let frames = system.windows.map(\.frame)
        await system.advance(by: .seconds(1))
        #expect(controller.isDragging)
        #expect(system.windows.map(\.frame) == frames)
        #expect(system.frameWriteCounts == writes)
        controller.cancelActiveGesture()
        return
    }
    if escape { controller.cancelActiveGesture(); #expect(system.windows.map(\.frame) == baseline); return }
    model.handleDisplayReconfiguration(.beginConfigurationFlag)
    await system.advance(by: .seconds(1))
    #expect(!controller.isDragging)
    #expect(system.frameWriteCounts == writes)
    model.handleDisplayChange(.displayReconfigurationEnded)
    try await holdSettled(model, system)
    #expect(system.windows.map(\.frame) == baseline)
}

@Test(.appTestApplication) @MainActor
func displayHoldLockCheckStartsAfterTwoSeconds() async throws {
    let system = makeManualWindowSystem(drivingPolicyDeadlines: true)
    let model = makeModel(system: system)
    defer { model.shutdown() }
    var checks = 0
    model.displayChangeScreenIsLocked = { checks += 1; return false }
    model.handleDisplayChangeApplicationActivation(bundleID: "com.apple.loginwindow")
    await system.advance(by: .seconds(1))
    #expect(checks == 0)
    #expect(model.isHoldingDisplayChange)
    try #require(await system.waitFor(timeout: .seconds(3)) { !model.isHoldingDisplayChange })
}

/// `frontmostApplication` can still name the previous app just after the
/// lock activation. The first check must wait until it names the lock screen.
@Test(.appTestApplication) @MainActor
func displayHoldLockSurvivesALateFrontmostApplicationUpdate() async throws {
    let system = makeManualWindowSystem(drivingPolicyDeadlines: true)
    let model = makeModel(system: system)
    defer { model.shutdown() }
    let origin = system.clock.now
    model.displayChangeScreenIsLocked = { system.clock.now - origin >= .milliseconds(500) }
    model.handleDisplayChangeApplicationActivation(bundleID: "com.apple.loginwindow")
    for _ in 0..<16 {
        await system.advance(by: .milliseconds(250))
        #expect(model.isHoldingDisplayChange, "The lock hold ended at \(system.clock.now - origin)")
    }
    model.displayChangeScreenIsLocked = { false }
    model.handleDisplayChangeApplicationActivation(bundleID: "org.example.Editor")
    try #require(await system.waitFor(timeout: .seconds(2)) { !model.isHoldingDisplayChange })
}

@Test(.appTestApplication) @MainActor
func displayHoldInterruptsOrdinaryTabbedPlacement() async throws {
    let system = makeManualWindowSystem(drivingPolicyDeadlines: true)
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.setActiveMode(.tabbed)
    try #require(await system.waitFor { !model.hasPendingTabbedPlacement })
    let before = system.frameWriteCounts
    var heldWrites: [WindowID: Int]?
    system.onWindowSnapshots = {
        guard heldWrites == nil, system.frameWriteCounts != before else { return }
        heldWrites = system.frameWriteCounts
        model.handleDisplayChange(.displayReconfigurationBegan)
    }
    model.performTabbed(.preset(.columns))
    try #require(await system.waitFor { heldWrites != nil && !model.hasPendingTabbedPlacement })
    #expect(system.frameWriteCounts == heldWrites)
    system.onWindowSnapshots = nil
    model.handleDisplayChange(.displayReconfigurationEnded)
    try await holdSettled(model, system)
    #expect(try sessionStore(of: model).session(for: system.mainDisplay.id)?.automaticWritesSuspended == false)
    let state = try #require(model.activeTabbedState)
    let placements = try state.placements(in: system.mainDisplay.visibleFrame, windows: system.windows)
    for placement in placements {
        #expect(system.windows.first { $0.id == placement.windowID }?.frame.approximatelyEquals(placement.frame, tolerance: 2) == true)
    }
}

@Test(.appTestApplication, arguments: [false, true]) @MainActor
func savedApplyRealRestorationFailureStillSuspends(displayChangesDuringRestore: Bool) async throws {
    let system = makeManualWindowSystem(drivingPolicyDeadlines: true)
    let h = ApplyHarness(system: system)
    defer { h.close() }
    h.addWindow()
    let model = makeModel(system: system)
    defer { model.shutdown() }
    let applier = try #require(model.savedLayoutApplier)
    applier.observesKeyboard = false
    applier.application = h.applier.application
    let source = system.windows[0].id
    // The forward frame is accepted; the final checkpoint cancels, and the
    // second frame write (restoration) is genuinely refused.
    system.failedFrameWriteNumbers[source] = [2]
    if displayChangesDuringRestore {
        system.onFrameWrite = { id, _ in
            if id == source, system.frameWriteCounts[id] == 2 {
                model.handleDisplayChange(.displayReconfigurationBegan)
            }
        }
    }
    model.savedLayoutInputCheckpoint = {
        if system.frameWriteCounts[source, default: 0] > 0 { return false }
        return true
    }
    _ = await system.drive { await applier.apply(h.document(mode: .bento)) }
    #expect(system.frameWriteCounts[source, default: 0] >= 2)
    #expect(try sessionStore(of: model).session(for: system.mainDisplay.id)?.automaticWritesSuspended == true)
}

@Test(.appTestApplication) @MainActor
func displayHoldDragRecoveryDoesNotCrossDesktopOwners() async throws {
    let system = makeManualWindowSystem(drivingPolicyDeadlines: true)
    let display = system.mainDisplay.id
    let first = NativeSpaceID(rawValue: 11), second = NativeSpaceID(rawValue: 12)
    let source = system.windows[0].id
    system.desktopObservation = .init(currentSpaceByDisplay: [display: first],
        knownSpacesByDisplay: [display: [first, second]], windowMembership: [source: [first]])
    let peer = WindowID(rawValue: "peer")
    system.windows.append(.init(id: peer, processIdentifier: 43,
        frame: BTRect(x: 50, y: 50, width: 300, height: 300), displayID: display))
    system.desktopObservation?.windowMembership[peer] = [first]
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.setActiveMode(.bento)
    await system.advance(by: .seconds(1))
    try await adaptiveSettled(model, system)
    try #require(model.beginBentoDrag(displayID: display, sourceID: source))
    system.windows[0].frame.origin.x += 130
    model.handleDisplayReconfiguration(.beginConfigurationFlag)
    model.finishBentoDrag(displayID: display, sourceID: source, end: .restore)
    let heldWrites = system.frameWriteCounts
    system.desktopObservation?.currentSpaceByDisplay[display] = second
    system.offscreenWindowIDs = [source, peer]
    model.beginActiveSpaceStabilization()
    model.handleDisplayChange(.displayReconfigurationEnded)
    try await holdSettled(model, system)
    #expect(system.frameWriteCounts == heldWrites)
}

@Test(.appTestApplication) @MainActor
func displayHoldRecoveryYieldsToANewerGesture() async throws {
    let system = makeManualWindowSystem(drivingPolicyDeadlines: true)
    system.windows.append(.init(id: .init(rawValue: "peer"), processIdentifier: 43,
        frame: BTRect(x: 50, y: 50, width: 300, height: 300), displayID: system.mainDisplay.id))
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.setActiveMode(.bento)
    await system.advance(by: .seconds(1))
    try await adaptiveSettled(model, system)
    let display = system.mainDisplay.id, source = system.windows[0].id
    try #require(model.beginBentoDrag(displayID: display, sourceID: source))
    system.windows[0].frame.origin.x += 130
    model.handleDisplayChange(.displayReconfigurationBegan)
    model.finishBentoDrag(displayID: display, sourceID: source, end: .restore)
    try #require(model.beginBentoDrag(displayID: display, sourceID: source))
    system.windows[0].frame.origin.x += 80
    let writes = system.frameWriteCounts, frame = system.windows[0].frame
    // Missing completion reaches the hold limit while this newer gesture
    // still owns the display. Old recovery must not move its participant.
    await system.advance(by: .seconds(6))
    // The jump to the deadline can finish before the sampler's last turn.
    #expect(await system.waitFor(timeout: .seconds(1)) { !model.isHoldingDisplayChange })
    #expect(system.frameWriteCounts == writes)
    #expect(system.windows[0].frame == frame)
    model.finishBentoDrag(displayID: display, sourceID: source, end: .restore)
}
