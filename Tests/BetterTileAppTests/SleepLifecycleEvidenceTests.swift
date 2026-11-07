import AppKit
import BetterTileCore
import BetterTileMacOS
import Testing
@testable import BetterTileApp

@MainActor private func settleSleepLifecycle(_ model: BetterTileModel, _ system: FakeAppWindowSystem) async throws {
    await system.advance(by: .seconds(1))
    try #require(await system.waitFor {
        !model.isHoldingDisplayChange && !model.hasPendingTabbedPlacement
            && model.windowEventTask == nil && model.settlementTasks.isEmpty
    })
}

@MainActor private func sleepLifecycleFixture(mode: LayoutMode) async throws -> (FakeAppWindowSystem, BetterTileModel) {
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
    try await settleSleepLifecycle(model, system)
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
    try await settleSleepLifecycle(model, system)
    return (system, model)
}

@Suite(.appTestApplication) @MainActor
struct SleepLifecycleEvidenceTests {
    @Test(arguments: [LayoutMode.bento, .tabbed], ["sleep", "inactive"])
    func minimizeAndRestoreWhileInactiveKeepLayout(mode: LayoutMode, context: String) async throws {
        let (system, model) = try await sleepLifecycleFixture(mode: mode)
        defer { model.shutdown() }
        let before = Dictionary(uniqueKeysWithValues: system.windows.map { ($0.id, $0.frame) })
        let tree = model.dividerResize.bentoStateProvider?(system.mainDisplay.id)
        let tabs = model.activeTabbedState?.panes.map { $0.tabs }
        let selected = model.activeTabbedState?.selectedWindowIDs
        let target = system.windows[1]
        model.handleDisplayChange(context == "sleep" ? .sleep : .sessionResigned)
        let writes = system.frameWriteCounts
        try system.setMinimized(true, for: target.id)
        system.eventHandler?(WindowSystemEvent(kind: .minimized, windowID: target.id, processIdentifier: target.processIdentifier))
        await system.advance(by: .seconds(7))
        #expect(system.frameWriteCounts == writes)
        if mode == .tabbed {
            #expect(model.activeTabbedState?.panes.map { $0.tabs } == tabs)
            #expect(model.activeTabbedState?.selectedWindowIDs == selected)
        }
        // Both lifecycle notifications arrive before the hold can settle.
        try system.setMinimized(false, for: target.id)
        system.eventHandler?(WindowSystemEvent(kind: .restored, windowID: target.id, processIdentifier: target.processIdentifier))
        await system.advance(by: .seconds(1))
        #expect(system.frameWriteCounts == writes)
        if context == "sleep" { model.handleApplicationTopologyChange(waking: true) }
        else { model.handleDisplayChange(.sessionBecameActive) }
        try await settleSleepLifecycle(model, system)
        for _ in 0..<3 {
            model.watchdog()
            try await settleSleepLifecycle(model, system)
        }
        #expect(Dictionary(uniqueKeysWithValues: system.windows.map { ($0.id, $0.frame) }) == before)
        #expect(system.frameWriteCounts == writes)
        if mode == .tabbed {
            #expect(model.activeTabbedState?.panes.map { $0.tabs } == tabs)
            #expect(model.activeTabbedState?.selectedWindowIDs == selected)
        } else {
            let current = model.dividerResize.bentoStateProvider?(system.mainDisplay.id)
            #expect(current?.root?.windowIDs == tree?.root?.windowIDs)
            #expect(current?.branches.map(\.axis) == tree?.branches.map(\.axis))
            #expect(current?.branches.map(\.weight) == tree?.branches.map(\.weight))
        }
    }

    @Test(arguments: [LayoutMode.bento, .tabbed])
    func minimizationThroughWakeRemovesWindow(mode: LayoutMode) async throws {
        let (system, model) = try await sleepLifecycleFixture(mode: mode)
        defer { model.shutdown() }
        let target = system.windows[1]
        let tabs = model.activeTabbedState?.panes.map { $0.tabs }
        model.handleDisplayChange(.sleep)
        let writes = system.frameWriteCounts
        try system.setMinimized(true, for: target.id)
        system.eventHandler?(WindowSystemEvent(kind: .minimized, windowID: target.id, processIdentifier: target.processIdentifier))
        await system.advance(by: .seconds(7))
        #expect(system.frameWriteCounts == writes)
        if mode == .tabbed { #expect(model.activeTabbedState?.panes.map { $0.tabs } == tabs) }
        model.handleApplicationTopologyChange(waking: true)
        try await settleSleepLifecycle(model, system)
        #expect(system.windows.first { $0.id == target.id }?.isMinimized == true)
        if mode == .tabbed { #expect(model.activeTabbedState?.windowIDs.contains(target.id) == false) }
        else { #expect(model.dividerResize.bentoStateProvider?(system.mainDisplay.id)?.root?.windowIDs.contains(target.id) != true) }
    }

    @Test(arguments: [LayoutMode.bento, .tabbed])
    func closeAfterMinimizeDuringSleepRemovesWindow(mode: LayoutMode) async throws {
        let (system, model) = try await sleepLifecycleFixture(mode: mode)
        defer { model.shutdown() }
        let target = system.windows[1]
        model.handleDisplayChange(.sleep)
        let writes = system.frameWriteCounts
        try system.setMinimized(true, for: target.id)
        system.eventHandler?(WindowSystemEvent(kind: .minimized, windowID: target.id, processIdentifier: target.processIdentifier))
        system.windows.removeAll { $0.id == target.id }
        system.eventHandler?(WindowSystemEvent(kind: .destroyed, windowID: target.id, processIdentifier: target.processIdentifier))
        await system.advance(by: .seconds(7))
        #expect(system.frameWriteCounts == writes)
        if mode == .tabbed { #expect(model.activeTabbedState?.windowIDs.contains(target.id) == false) }
        model.handleApplicationTopologyChange(waking: true)
        try await settleSleepLifecycle(model, system)
        if mode == .tabbed { #expect(model.activeTabbedState?.windowIDs.contains(target.id) == false) }
        else { #expect(model.dividerResize.bentoStateProvider?(system.mainDisplay.id)?.root?.windowIDs.contains(target.id) != true) }
        #expect(system.frameWriteCounts[target.id] == writes[target.id])
    }

    @Test(arguments: [LayoutMode.bento, .tabbed])
    func unreadMinimizedWindowStaysOutOfLayoutAfterWake(mode: LayoutMode) async throws {
        let (system, model) = try await sleepLifecycleFixture(mode: mode)
        defer { model.shutdown() }
        let target = system.windows[1]
        model.handleDisplayChange(.sleep)
        let writes = system.frameWriteCounts
        try system.setMinimized(true, for: target.id)
        system.eventHandler?(WindowSystemEvent(kind: .minimized, windowID: target.id, processIdentifier: target.processIdentifier))
        system.offscreenWindowIDs.insert(target.id)
        await system.advance(by: .seconds(7))
        #expect(system.frameWriteCounts == writes)
        model.handleApplicationTopologyChange(waking: true)
        try await settleSleepLifecycle(model, system)
        // A later snapshot remains minimized without a restore notification.
        system.offscreenWindowIDs.remove(target.id)
        model.watchdog()
        try await settleSleepLifecycle(model, system)
        if mode == .tabbed { #expect(model.activeTabbedState?.windowIDs.contains(target.id) == false) }
        else { #expect(model.dividerResize.bentoStateProvider?(system.mainDisplay.id)?.root?.windowIDs.contains(target.id) != true) }
        #expect(system.frameWriteCounts[target.id] == writes[target.id])
    }

    @Test
    func awakeMinimizeDuringDisplayChangeRemovesTabImmediately() async throws {
        let (system, model) = try await sleepLifecycleFixture(mode: .tabbed)
        defer { model.shutdown() }
        let target = system.windows[1]
        model.handleDisplayChange(.displayReconfigurationBegan)
        // While awake an AX event can precede its visible snapshot update.
        system.eventHandler?(WindowSystemEvent(kind: .minimized, windowID: target.id, processIdentifier: target.processIdentifier))
        #expect(model.activeTabbedState?.windowIDs.contains(target.id) == false)
    }
}
