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

@Test(.appTestApplication, arguments: WakeWindowRead.allCases, [LayoutMode.bento, .tabbed]) @MainActor
private func wakeWaitsForPreviouslyManagedWindows(read: WakeWindowRead, mode: LayoutMode) async throws {
    let (system, model) = try await wakeFixture(mode: mode)
    defer { model.shutdown() }
    let frames = Dictionary(uniqueKeysWithValues: system.windows.map { ($0.id, $0.frame) })
    let tabs = model.activeTabbedState?.panes.map { $0.tabs }
    let selected = model.activeTabbedState?.selectedWindowIDs
    let observation = system.desktopObservation
    model.handleDisplayChange(.sleep)
    await system.advance(by: .seconds(7))
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
    model.handleApplicationTopologyChange(waking: true)
    for _ in 0..<8 { model.watchdog(); await system.advance(by: .milliseconds(375)) }
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
    model.handleDisplayChange(.sleep)
    system.offscreenWindowIDs = [system.windows[3].id]
    model.handleApplicationTopologyChange(waking: true)
    #expect(await system.waitFor(timeout: .seconds(5)) { !model.isHoldingDisplayChange })
}

@Test(.appTestApplication) @MainActor
func wakeReadinessDoesNotWaitForConfirmedClosure() async throws {
    let (system, model) = try await wakeFixture(mode: .bento)
    defer { model.shutdown() }
    model.handleDisplayChange(.sleep)
    let closed = system.windows.removeLast()
    system.eventHandler?(WindowSystemEvent(kind: .destroyed, windowID: closed.id, processIdentifier: closed.processIdentifier))
    model.handleApplicationTopologyChange(waking: true)
    await system.advance(by: .seconds(1))
    #expect(!model.isHoldingDisplayChange)
}

@Test(.appTestApplication) @MainActor
func displayOnlyHoldDoesNotWaitForWakeMembership() async throws {
    let (system, model) = try await wakeFixture(mode: .bento)
    defer { model.shutdown() }
    model.handleDisplayChange(.displayReconfigurationBegan)
    system.offscreenWindowIDs = [system.windows[3].id]
    model.handleDisplayChange(.displayReconfigurationEnded)
    await system.advance(by: .seconds(1))
    #expect(!model.isHoldingDisplayChange)
}
