import AppKit
import BetterTileCore
import BetterTileMacOS
import Testing
@testable import BetterTileApp

private enum WakeWindowRead: String, CaseIterable {
    case missing, hidden, minimized, fullscreen
}

@MainActor private func settleWake(_ model: BetterTileModel, _ system: FakeAppWindowSystem) async throws {
    await system.advance(by: .seconds(1))
    try #require(await system.waitFor {
        !model.isHoldingDisplayChange && !model.hasPendingTabbedPlacement
            && model.windowEventTask == nil && model.settlementTasks.isEmpty
    })
}

@MainActor private func wakeFixture(mode: LayoutMode) async throws -> (FakeAppWindowSystem, BetterTileModel) {
    let system = makeManualWindowSystem(drivingPolicyDeadlines: true)
    let ids = (0..<4).map { WindowID(rawValue: "window-\($0)") }
    system.windows = ids.enumerated().map { index, id in
        WindowSnapshot(id: id, processIdentifier: Int32(40 + index),
            frame: BTRect(x: 100, y: 100, width: 300, height: 300), displayID: system.mainDisplay.id,
            constraints: WindowConstraints(minimumSize: BTSize(width: 120, height: 80), minimumSizeSource: .hint))
    }
    let space = NativeSpaceID(rawValue: 101)
    system.desktopObservation = NativeDesktopObservation(currentSpaceByDisplay: [system.mainDisplay.id: space],
        knownSpacesByDisplay: [system.mainDisplay.id: [space]],
        windowMembership: Dictionary(uniqueKeysWithValues: ids.map { ($0, [space]) }))
    system.focusedID = ids[0]
    let model = makeModel(system: system)
    let drag = try #require(Mirror(reflecting: model).children.first {
        $0.label?.hasSuffix("dragSnap") == true
    }?.value as? DragSnapController)
    drag.primaryButtonIsPressed = { false }
    model.configuration.bentoInnerGap = 0
    model.configuration.defaultLayoutMode = .manual
    model.setActiveMode(mode)
    try await settleWake(model, system)
    if mode == .tabbed {
        model.performTabbed(.preset(.columns, grouping: .distributeWindows))
    } else {
        let state = BentoLayoutState(root: .partition(BentoPartition(axis: .vertical, weight: 0.58,
            first: .partition(BentoPartition(axis: .horizontal, weight: 0.52,
                first: .leaf(ids[0]), second: .leaf(ids[1]))),
            second: .partition(BentoPartition(axis: .horizontal, weight: 0.43,
                first: .leaf(ids[2]), second: .leaf(ids[3]))))))
        let old = Dictionary(uniqueKeysWithValues: system.windows.map { ($0.id, $0.frame) })
        let frames = Dictionary(uniqueKeysWithValues: BentoLayoutEngine(state: state)
            .placements(for: system.windows, in: system.mainDisplay).map { ($0.windowID, $0.frame) })
        for i in system.windows.indices { system.windows[i].frame = try #require(frames[system.windows[i].id]) }
        model.dividerResize.bentoStateChangedHandler?(system.mainDisplay.id, state, frames, old)
    }
    try await settleWake(model, system)
    return (system, model)
}

/// How the session leaves and regains activity. `repeatedWake` delivers the
/// `didWake` and `screensDidWake` pair while a window is still missing.
private enum WakeEntry: String, CaseIterable {
    case sleep, lock, screenSaver, repeatedWake
}

@MainActor private func enterInactive(_ entry: WakeEntry, _ model: BetterTileModel) {
    switch entry {
    case .sleep, .repeatedWake: model.handleDisplayChange(.sleep)
    case .lock, .screenSaver:
        model.displayChangeScreenIsLocked = { true }
        model.handleDisplayChangeApplicationActivation(
            bundleID: entry == .lock ? "com.apple.loginwindow" : "com.apple.ScreenSaver.Engine")
    }
}

@MainActor private func leaveInactive(_ entry: WakeEntry, _ model: BetterTileModel, _ system: FakeAppWindowSystem) async {
    switch entry {
    case .sleep: model.handleApplicationTopologyChange(waking: true)
    case .repeatedWake:
        model.handleDisplayChange(.wake)
        await system.advance(by: .milliseconds(375))
        model.handleApplicationTopologyChange(waking: true)
    case .lock, .screenSaver:
        model.displayChangeScreenIsLocked = { false }
        model.handleDisplayChangeApplicationActivation(bundleID: "org.example.Editor")
    }
}

/// Without the readiness wait, Tabbed still keeps an unreported tab, so the
/// Tabbed `.missing` case fails only on the hold-state check.
@Test(.appTestApplication, arguments: WakeWindowRead.allCases, [LayoutMode.bento, .tabbed]) @MainActor
private func wakeWaitsForPreviouslyManagedWindows(read: WakeWindowRead, mode: LayoutMode) async throws {
    try await readinessScenario(read: read, mode: mode, entry: .sleep)
}

@Test(.appTestApplication, arguments: [WakeEntry.lock, .screenSaver, .repeatedWake], [LayoutMode.bento, .tabbed]) @MainActor
private func returningSessionWaitsForPreviouslyManagedWindows(entry: WakeEntry, mode: LayoutMode) async throws {
    try await readinessScenario(read: .hidden, mode: mode, entry: entry)
}

@MainActor private func readinessScenario(read: WakeWindowRead, mode: LayoutMode, entry: WakeEntry) async throws {
    let (system, model) = try await wakeFixture(mode: mode)
    defer { model.shutdown() }
    let frames = Dictionary(uniqueKeysWithValues: system.windows.map { ($0.id, $0.frame) })
    let tabs = model.activeTabbedState?.panes.map { $0.tabs }
    let selected = model.activeTabbedState?.selectedWindowIDs
    let observation = system.desktopObservation
    enterInactive(entry, model)
    await system.advance(by: .seconds(7))
    #expect(model.isHoldingDisplayChange)
    system.requestedFrames = [:]
    let writesBeforeWake = system.frameWriteCounts
    // Native metadata is also temporarily unavailable. This reaches the
    // public fallback without relying on permanent desktop membership.
    system.desktopObservation = nil
    let missing = system.windows[3].id
    switch read {
    case .missing: system.offscreenWindowIDs = [missing]
    case .hidden: system.windows[3].isHidden = true
    case .minimized: system.windows[3].isMinimized = true
    case .fullscreen: system.windows[3].isFullScreen = true
    }
    await leaveInactive(entry, model, system)
    for _ in 0..<8 { model.watchdog(); await system.advance(by: .milliseconds(375)) }
    #expect(model.isHoldingDisplayChange, "The hold must still wait for the missing window")
    #expect(system.frameWriteCounts == writesBeforeWake, "A quiet but incomplete wake inventory must not write frames")
    system.offscreenWindowIDs = []
    system.windows[3].isHidden = false
    system.windows[3].isMinimized = false
    system.windows[3].isFullScreen = false
    system.desktopObservation = observation
    model.handleApplicationTopologyChange()
    try await settleWake(model, system)
    #expect(model.activeMode(for: system.mainDisplay.id) == mode)
    #expect(Dictionary(uniqueKeysWithValues: system.windows.map { ($0.id, $0.frame) }) == frames)
    if mode == .tabbed {
        #expect(model.activeTabbedState?.panes.map { $0.tabs } == tabs)
        #expect(model.activeTabbedState?.selectedWindowIDs == selected)
    }
}

@Test(.appTestApplication) @MainActor
func wakeReadinessKeepsTheFiveSecondLimit() async throws {
    let (system, model) = try await wakeFixture(mode: .bento)
    defer { model.shutdown() }
    let missing = system.windows[3].id
    model.handleDisplayChange(.sleep)
    await system.advance(by: .seconds(1))
    // The public fallback: no desktop membership keeps the absent identity.
    system.desktopObservation = nil
    system.offscreenWindowIDs = [missing]
    let writes = system.frameWriteCounts
    model.handleApplicationTopologyChange(waking: true)
    let origin = system.clock.now
    var released: Duration?
    for _ in 0..<60 {
        await system.advance(by: .milliseconds(100))
        if released == nil, !model.isHoldingDisplayChange {
            released = system.clock.now - origin
            break
        }
        #expect(system.frameWriteCounts == writes, "No layout may run before the deadline")
    }
    let at = try #require(released, "The hold must not get stuck")
    #expect(at >= .milliseconds(4900) && at <= .milliseconds(5500), "The hold ended at \(at), not at its deadline")
    try await settleWake(model, system)
    // After the deadline ordinary sweeps apply again: the missing window
    // leaves the layout instead of keeping a permanent place.
    var tree: [WindowID] = []
    for _ in 0..<10 {
        model.watchdog()
        await system.advance(by: .milliseconds(500))
        tree = try sessionStore(of: model).session(for: system.mainDisplay.id)?.bentoState.root?.windowIDs ?? []
        if !tree.contains(missing) { break }
    }
    #expect(Set(tree) == Set(system.windows.map(\.id)).subtracting([missing]), "tree \(tree)")
}

@Test(.appTestApplication) @MainActor
func wakeReadinessDoesNotWaitForConfirmedClosure() async throws {
    let (system, model) = try await wakeFixture(mode: .bento)
    defer { model.shutdown() }
    model.handleDisplayChange(.sleep)
    let closed = system.windows.removeLast()
    system.eventHandler?(WindowSystemEvent(kind: .destroyed, windowID: closed.id, processIdentifier: closed.processIdentifier))
    model.handleApplicationTopologyChange(waking: true)
    // A confirmed closure settles on quiet observations, well before the
    // five-second deadline. Wait for the sampler instead of a fixed step.
    let released = await system.waitFor(timeout: .seconds(2)) { !model.isHoldingDisplayChange }
    #expect(released, "The hold waited for a window that was confirmed closed")
}

@Test(.appTestApplication) @MainActor
func displayOnlyHoldDoesNotWaitForWakeMembership() async throws {
    let (system, model) = try await wakeFixture(mode: .bento)
    defer { model.shutdown() }
    model.handleDisplayChange(.displayReconfigurationBegan)
    // A real change, so the hold settles through the sampler rather than the
    // early release of an unchanged arrangement.
    system.availableDisplays.append(DisplaySnapshot(id: DisplayID(rawValue: "added"),
        frame: BTRect(x: 1000, y: 0, width: 800, height: 600), visibleFrame: BTRect(x: 1000, y: 0, width: 800, height: 600)))
    system.offscreenWindowIDs = [system.windows[3].id]
    model.handleDisplayChange(.displayReconfigurationEnded)
    try #require(model.isHoldingDisplayChange, "A changed arrangement must hold")
    let released = await system.waitFor(timeout: .seconds(2)) { !model.isHoldingDisplayChange }
    #expect(released, "A display-only hold must not wait for the missing window")
}

@MainActor private func readinessState(_ model: BetterTileModel) -> (expected: Set<WindowID>?, minimized: Set<WindowID>) {
    let fields = Mirror(reflecting: model).children
    let expected = fields.first { $0.label?.hasSuffix("displayChangeExpectedWindows") == true }?.value as? Set<WindowID>?
    let minimized = fields.first { $0.label?.hasSuffix("displayChangeActiveMinimizedWindows") == true }?.value as? Set<WindowID>
    return (expected ?? nil, minimized ?? [])
}

/// A wake hold that ends at its time limit must clear the readiness state,
/// like a quiet settlement, so no captured window or minimize carries over.
@Test(.appTestApplication) @MainActor
func aLimitEndedWakeHoldLeavesNoReadinessState() async throws {
    let (system, model) = try await wakeFixture(mode: .bento)
    defer { model.shutdown() }
    model.handleDisplayChange(.sleep)
    await system.advance(by: .seconds(1))
    system.desktopObservation = nil
    system.offscreenWindowIDs = [system.windows[3].id]
    model.handleApplicationTopologyChange(waking: true)
    let minimized = system.windows[2]
    await system.advance(by: .milliseconds(100))
    system.windows[2].isMinimized = true
    system.eventHandler?(WindowSystemEvent(kind: .minimized, windowID: minimized.id, processIdentifier: minimized.processIdentifier))
    try #require(readinessState(model).expected?.isEmpty == false)
    try #require(readinessState(model).minimized == [minimized.id])
    let released = await system.waitFor(timeout: .seconds(7)) { !model.isHoldingDisplayChange }
    try #require(released)
    let state = readinessState(model)
    #expect(state.expected == nil, "The limit left captured windows: \(String(describing: state.expected))")
    #expect(state.minimized.isEmpty, "The limit left awake minimize evidence: \(state.minimized)")
}

/// The readiness wait ends five seconds after the last real event. An
/// unchanged screen notification after the wake does not extend it; a real
/// display change does.
@Test(.appTestApplication, arguments: [false, true]) @MainActor
func wakeReadinessDeadlineCountsFromTheLastRealEvent(realChange: Bool) async throws {
    let (system, model) = try await wakeFixture(mode: .bento)
    defer { model.shutdown() }
    model.handleDisplayChange(.sleep)
    await system.advance(by: .seconds(1))
    system.desktopObservation = nil
    system.offscreenWindowIDs = [system.windows[3].id]
    model.handleApplicationTopologyChange(waking: true)
    let origin = system.clock.now
    await system.advance(by: .seconds(3))
    try #require(model.isHoldingDisplayChange)
    if realChange {
        system.availableDisplays.append(DisplaySnapshot(id: DisplayID(rawValue: "added"),
            frame: BTRect(x: 1000, y: 0, width: 800, height: 600), visibleFrame: BTRect(x: 1000, y: 0, width: 800, height: 600)))
    }
    model.scheduleDisplayRefresh()
    var released: Duration?
    for _ in 0..<80 {
        await system.advance(by: .milliseconds(100))
        if !model.isHoldingDisplayChange { released = system.clock.now - origin; break }
    }
    let at = try #require(released, "The hold must end")
    if realChange {
        #expect(at >= .milliseconds(7900), "A real change must restart the deadline; the hold ended at \(at)")
    } else {
        #expect(at <= .milliseconds(5500), "An unchanged notification extended the wait to \(at)")
    }
}

/// Focus mode only adds to a session's observed windows. A window that opens
/// and closes during Focus keeps its observed ID after its closure evidence is
/// consumed, but it holds no place in the layout, so a wake must not wait for it.
@Test(.appTestApplication) @MainActor
func wakeDoesNotWaitForAWindowThatLeftDuringFocus() async throws {
    let system = makeManualWindowSystem(drivingPolicyDeadlines: true)
    let peer = WindowID(rawValue: "peer")
    system.windows.append(WindowSnapshot(id: peer, processIdentifier: 43, bundleIdentifier: "com.example.Peer",
        frame: BTRect(x: 0, y: 0, width: 200, height: 300), displayID: system.mainDisplay.id))
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.setActiveMode(.bento)
    try await settleWake(model, system)
    system.focusedID = system.windows[0].id
    model.perform(.maximize)
    try #require(system.windows[1].isMinimized)
    try await settleWake(model, system)
    let late = WindowID(rawValue: "late")
    system.windows.append(WindowSnapshot(id: late, processIdentifier: 44, bundleIdentifier: "com.example.Late",
        frame: BTRect(x: 100, y: 100, width: 300, height: 300), displayID: system.mainDisplay.id))
    system.eventHandler?(WindowSystemEvent(kind: .created, windowID: late, processIdentifier: 44))
    try await settleWake(model, system)
    system.windows.removeAll { $0.id == late }
    system.eventHandler?(WindowSystemEvent(kind: .destroyed, windowID: late, processIdentifier: 44))
    try await settleWake(model, system)
    model.watchdog()
    try await settleWake(model, system)
    let session = try #require(sessionStore(of: model).session(for: system.mainDisplay.id))
    try #require(!session.excludedFocusWindowIDs.isEmpty, "Focus mode must still be active")
    try #require(session.windowIDs.contains(late), "Focus keeps the closed window in the observed windows")
    try #require(session.bentoState.root?.windowIDs.contains(late) != true, "The closed window holds no place in the layout")
    model.handleDisplayChange(.sleep)
    await system.advance(by: .seconds(2))
    model.handleApplicationTopologyChange(waking: true)
    let origin = system.clock.now
    #expect(await system.waitFor(timeout: .seconds(2)) { !model.isHoldingDisplayChange },
            "The hold waited for a window outside the layout until \(system.clock.now - origin)")
}

/// A minimize the user makes after the session returns is real evidence, like
/// a closure. A minimize recorded while asleep is not trusted for the wait.
@Test(.appTestApplication, arguments: [true, false]) @MainActor
func wakeTreatsAnAwakeMinimizeLikeAClosure(afterWake: Bool) async throws {
    let (system, model) = try await wakeFixture(mode: .bento)
    defer { model.shutdown() }
    let window = system.windows[3]
    model.handleDisplayChange(.sleep)
    await system.advance(by: .seconds(1))
    if !afterWake {
        system.windows[3].isMinimized = true
        system.eventHandler?(WindowSystemEvent(kind: .minimized, windowID: window.id, processIdentifier: window.processIdentifier))
    }
    model.handleApplicationTopologyChange(waking: true)
    if afterWake {
        // Between two samples, so the hold has seen the window but not settled.
        await system.advance(by: .milliseconds(100))
        try #require(model.isHoldingDisplayChange)
        system.windows[3].isMinimized = true
        system.eventHandler?(WindowSystemEvent(kind: .minimized, windowID: window.id, processIdentifier: window.processIdentifier))
    }
    let origin = system.clock.now
    let released = await system.waitFor(timeout: .seconds(2)) { !model.isHoldingDisplayChange }
    #expect(released == afterWake, "Hold state after \(system.clock.now - origin): holding \(model.isHoldingDisplayChange)")
}

/// A tab drag removes the tab from its pane until the drop. Sleep interrupts
/// the drag and puts the tab back. The wake must wait for that tab too, and
/// it must return to its pane, order and selection.
@Test(.appTestApplication) @MainActor
func wakeWaitsForATabThatSleepReturnedFromADrag() async throws {
    let (system, model) = try await wakeFixture(mode: .tabbed)
    defer { model.shutdown() }
    let display = system.mainDisplay.id
    let panes = try #require(model.activeTabbedState?.panes.map(\.tabs))
    let selected = model.activeTabbedState?.selectedWindowIDs
    let frames = Dictionary(uniqueKeysWithValues: system.windows.map { ($0.id, $0.frame) })
    let group = try #require(model.activeTabbedState?.panes.first { $0.tabs.count > 1 })
    let dragged = try #require(group.tabs.first { $0 != group.selected })
    try #require(model.beginBentoDrag(displayID: display, sourceID: dragged))
    try #require(model.activeTabbedState?.windowIDs.contains(dragged) == false, "The drag tears the tab off its pane")
    let observation = system.desktopObservation
    model.handleDisplayChange(.sleep)
    try #require(model.activeTabbedState?.panes.map(\.tabs) == panes, "Sleep puts the dragged tab back")
    await system.advance(by: .seconds(7))
    let writes = system.frameWriteCounts
    // The tab's application answers late after wake.
    system.desktopObservation = nil
    let index = try #require(system.windows.firstIndex { $0.id == dragged })
    system.windows[index].isHidden = true
    model.handleApplicationTopologyChange(waking: true)
    for _ in 0..<8 { model.watchdog(); await system.advance(by: .milliseconds(375)) }
    #expect(model.isHoldingDisplayChange, "The hold must still wait for the returned tab")
    #expect(system.frameWriteCounts == writes)
    system.windows[index].isHidden = false
    system.desktopObservation = observation
    model.handleApplicationTopologyChange()
    try await settleWake(model, system)
    #expect(model.activeTabbedState?.panes.map(\.tabs) == panes)
    #expect(model.activeTabbedState?.selectedWindowIDs == selected)
    #expect(Dictionary(uniqueKeysWithValues: system.windows.map { ($0.id, $0.frame) }) == frames)
}

/// Adaptive builds no tree for a lone window. A wake that cannot read that
/// window yet must not settle and let its first sweep place it again.
@Test(.appTestApplication) @MainActor
func wakeWaitsForTheOnlyWindowOfAnAdaptiveDesktop() async throws {
    let system = makeManualWindowSystem(drivingPolicyDeadlines: true)
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.setActiveMode(.bento)
    try await settleWake(model, system)
    try #require(sessionStore(of: model).session(for: system.mainDisplay.id)?.bentoState.root == nil)
    // The user sizes the window by hand; Adaptive keeps that frame.
    system.windows[0].frame = BTRect(x: 120, y: 80, width: 500, height: 400)
    model.handleApplicationTopologyChange()
    try await settleWake(model, system)
    let frame = system.windows[0].frame
    try #require(frame == BTRect(x: 120, y: 80, width: 500, height: 400))
    model.handleDisplayChange(.sleep)
    await system.advance(by: .seconds(2))
    system.desktopObservation = nil
    system.offscreenWindowIDs = [system.windows[0].id]
    model.handleApplicationTopologyChange(waking: true)
    for _ in 0..<4 { model.watchdog(); await system.advance(by: .milliseconds(375)) }
    #expect(model.isHoldingDisplayChange, "The hold must wait for the only window")
    system.offscreenWindowIDs = []
    model.handleApplicationTopologyChange()
    try await settleWake(model, system)
    #expect(system.windows[0].frame == frame, "The lone window was placed again after the wake")
}
