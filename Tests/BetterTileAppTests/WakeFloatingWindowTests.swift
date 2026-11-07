import AppKit
import BetterTileCore
import BetterTileMacOS
import Testing
@testable import BetterTileApp

@MainActor private func settleAfterWake(_ model: BetterTileModel, _ system: FakeAppWindowSystem) async throws {
    await system.advance(by: .seconds(1))
    try #require(await system.waitFor {
        !model.isHoldingDisplayChange && !model.hasPendingTabbedPlacement
            && model.windowEventTask == nil && model.settlementTasks.isEmpty
    })
}

/// A window the user floated keeps its place through a wake, even when it
/// stays missing for a few seconds.
@Test(.appTestApplication) @MainActor
func wakeWaitsForAUserFloatedAdaptiveWindow() async throws {
    let system = makeManualWindowSystem(drivingPolicyDeadlines: true)
    let ids = (0..<4).map { WindowID(rawValue: "window-\($0)") }
    system.windows = ids.enumerated().map { index, id in
        WindowSnapshot(id: id, processIdentifier: Int32(40 + index),
            frame: BTRect(x: 100, y: 100, width: 300, height: 300), displayID: system.mainDisplay.id,
            constraints: WindowConstraints(minimumSize: BTSize(width: 120, height: 80), minimumSizeSource: .hint))
    }
    system.focusedID = ids[0]
    let model = makeModel(system: system)
    defer { model.shutdown() }
    let drag = try #require(Mirror(reflecting: model).children.first {
        $0.label?.hasSuffix("dragSnap") == true
    }?.value as? DragSnapController)
    drag.primaryButtonIsPressed = { false }
    model.configuration.bentoInnerGap = 0
    model.configuration.defaultLayoutMode = .manual
    model.setActiveMode(.bento)
    try await settleAfterWake(model, system)
    let state = BentoLayoutState(root: .partition(BentoPartition(axis: .vertical, weight: 0.58,
        first: .leaf(ids[0]),
        second: .partition(BentoPartition(axis: .horizontal, weight: 0.43,
            first: .leaf(ids[1]), second: .leaf(ids[2]))))), floatingWindowIDs: [ids[3]])
    let old = Dictionary(uniqueKeysWithValues: system.windows.map { ($0.id, $0.frame) })
    let frames = Dictionary(uniqueKeysWithValues: BentoLayoutEngine(state: state)
        .placements(for: Array(system.windows.prefix(3)), in: system.mainDisplay).map { ($0.windowID, $0.frame) })
    for i in 0..<3 { system.windows[i].frame = try #require(frames[system.windows[i].id]) }
    system.windows[3].frame = BTRect(x: 200, y: 200, width: 250, height: 250)
    model.dividerResize.bentoStateChangedHandler?(system.mainDisplay.id, state, frames, old)
    try await settleAfterWake(model, system)
    let before = try #require(councilStore(model).session(for: system.mainDisplay.id))
    try #require(before.bentoState.floatingWindowIDs.contains(ids[3]), "float set up: \(before.bentoState)")
    try #require(!before.automaticallyFloatingWindowIDs.contains(ids[3]))
    let start = Dictionary(uniqueKeysWithValues: system.windows.map { ($0.id, $0.frame) })
    model.handleDisplayChange(.sleep)
    await system.advance(by: .seconds(2))
    system.windows[3].isHidden = true
    model.handleApplicationTopologyChange(waking: true)
    for _ in 0..<8 { model.watchdog(); await system.advance(by: .milliseconds(375)) }
    let heldAt3s = model.isHoldingDisplayChange
    system.windows[3].isHidden = false
    model.handleApplicationTopologyChange()
    try await settleAfterWake(model, system)
    for _ in 0..<4 { model.watchdog(); await system.advance(by: .milliseconds(500)) }
    let after = try #require(councilStore(model).session(for: system.mainDisplay.id))
    let end = Dictionary(uniqueKeysWithValues: system.windows.map { ($0.id, $0.frame) })
    #expect(heldAt3s, "hold released before the floated window returned")
    #expect(after.bentoState.floatingWindowIDs.contains(ids[3]), "floating lost: tree \(after.bentoState.root?.windowIDs ?? [])")
    #expect(end == start, "frames changed")
}

/// The Tabbed form of the same wake: the float does not become a tab.
@Test(.appTestApplication) @MainActor
func wakeWaitsForAUserFloatedTabbedWindow() async throws {
    let system = makeManualWindowSystem(drivingPolicyDeadlines: true)
    let ids = (0..<4).map { WindowID(rawValue: "window-\($0)") }
    system.windows = ids.enumerated().map { index, id in
        WindowSnapshot(id: id, processIdentifier: Int32(40 + index),
            frame: BTRect(x: 100, y: 100, width: 300, height: 300), displayID: system.mainDisplay.id,
            constraints: WindowConstraints(minimumSize: BTSize(width: 120, height: 80), minimumSizeSource: .hint))
    }
    system.focusedID = ids[0]
    let model = makeModel(system: system)
    defer { model.shutdown() }
    let drag = try #require(Mirror(reflecting: model).children.first {
        $0.label?.hasSuffix("dragSnap") == true
    }?.value as? DragSnapController)
    drag.primaryButtonIsPressed = { false }
    model.configuration.bentoInnerGap = 0
    model.configuration.defaultLayoutMode = .manual
    model.setActiveMode(.tabbed)
    try await settleAfterWake(model, system)
    model.performTabbed(.preset(.columns, grouping: .distributeWindows))
    try await settleAfterWake(model, system)
    model.performTabbed(.float(ids[3]))
    try await settleAfterWake(model, system)
    let tabbed = try #require(model.activeTabbedState)
    try #require(tabbed.floatingWindowIDs.contains(ids[3]), "float set up: \(tabbed.panes.map(\.tabs))")
    let tabs = tabbed.panes.map(\.tabs)
    let start = Dictionary(uniqueKeysWithValues: system.windows.map { ($0.id, $0.frame) })
    model.handleDisplayChange(.sleep)
    await system.advance(by: .seconds(2))
    system.desktopObservation = nil
    system.windows[3].isHidden = true
    model.handleApplicationTopologyChange(waking: true)
    for _ in 0..<8 { model.watchdog(); await system.advance(by: .milliseconds(375)) }
    let heldAt3s = model.isHoldingDisplayChange
    system.windows[3].isHidden = false
    model.handleApplicationTopologyChange()
    try await settleAfterWake(model, system)
    for _ in 0..<4 { model.watchdog(); await system.advance(by: .milliseconds(500)) }
    let end = Dictionary(uniqueKeysWithValues: system.windows.map { ($0.id, $0.frame) })
    #expect(heldAt3s, "hold released before the floated window returned")
    #expect(model.activeTabbedState?.floatingWindowIDs.contains(ids[3]) == true,
            "floating lost: \(String(describing: model.activeTabbedState?.panes.map(\.tabs)))")
    #expect(model.activeTabbedState?.panes.map(\.tabs) == tabs)
    #expect(end == start, "frames changed")
}
