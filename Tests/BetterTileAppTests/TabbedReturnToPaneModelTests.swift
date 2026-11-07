import AppKit
import Foundation
import Testing
@testable import BetterTileApp
@testable import BetterTileCore

private let laptopID = DisplayID(rawValue: "laptop")
private let externalID = DisplayID(rawValue: "external")
private let laptopSpace = NativeSpaceID(rawValue: 11)
private let externalSpace = NativeSpaceID(rawValue: 22)

private func window(_ id: String, pid: Int32, x: Double, width: Double = 500, display: DisplayID,
                    minimumWidth: Double = 120) -> WindowSnapshot {
    WindowSnapshot(id: WindowID(rawValue: id), processIdentifier: pid, bundleIdentifier: "com.example.\(id)",
                   frame: BTRect(x: x, y: 0, width: width, height: 800), displayID: display,
                   constraints: WindowConstraints(minimumSize: BTSize(width: minimumWidth, height: 80), minimumSizeSource: .hint))
}

@MainActor private func twoDisplayFixture() -> (FakeAppWindowSystem, BetterTileModel) {
    _ = NSApplication.shared
    let system = makeManualWindowSystem(drivingPolicyDeadlines: true)
    system.availableDisplays = [
        DisplaySnapshot(id: laptopID, frame: BTRect(x: 0, y: 0, width: 1000, height: 800),
                        visibleFrame: BTRect(x: 0, y: 0, width: 1000, height: 800), isMain: true),
        DisplaySnapshot(id: externalID, frame: BTRect(x: 1000, y: 0, width: 1000, height: 800),
                        visibleFrame: BTRect(x: 1000, y: 0, width: 1000, height: 800)),
    ]
    system.windows = [
        window("L1", pid: 41, x: 0, display: laptopID),
        window("L2", pid: 42, x: 500, display: laptopID),
        window("E1", pid: 51, x: 1000, display: externalID),
        window("E2", pid: 52, x: 1500, display: externalID),
        window("E3", pid: 53, x: 1200, display: externalID),
    ]
    system.desktopObservation = NativeDesktopObservation(
        currentSpaceByDisplay: [laptopID: laptopSpace, externalID: externalSpace],
        knownSpacesByDisplay: [laptopID: [laptopSpace], externalID: [externalSpace]],
        windowMembership: Dictionary(uniqueKeysWithValues: system.windows.map {
            ($0.id, $0.displayID == laptopID ? [laptopSpace] : [externalSpace])
        })
    )
    let model = makeModel(system: system)
    model.configuration.defaultLayoutMode = .manual
    model.configuration.defaultTabbedPreset = .columns
    return (system, model)
}

@MainActor private func tabbedPanes(_ model: BetterTileModel, _ system: FakeAppWindowSystem, focusing id: String) -> [[String]] {
    system.focusedID = WindowID(rawValue: id)
    model.watchdog()
    return (model.activeTabbedState?.panes ?? []).map { $0.tabs.map(\.rawValue) }
}

@MainActor private func enterTabbedOnExternal(_ model: BetterTileModel, _ system: FakeAppWindowSystem) async throws -> [[String]] {
    system.focusedID = WindowID(rawValue: "E1")
    model.setActiveMode(.tabbed)
    try #require(await system.waitFor { model.activeMode(for: externalID) == .tabbed
        && model.activeTabbedState?.windowIDs.count == 3 && !model.hasPendingTabbedPlacement })
    await system.advance(by: .milliseconds(400))
    _ = tabbedPanes(model, system, focusing: "E1")
    model.performTabbed(.preset(.columns, grouping: .distributeWindows))
    try #require(await system.waitFor { !model.hasPendingTabbedPlacement })
    await system.advance(by: .milliseconds(400))
    let panes = tabbedPanes(model, system, focusing: "E1")
    try #require(panes.count == 2 && panes.allSatisfy { !$0.isEmpty }, "\(panes)")
    return panes
}

@Test(.appTestApplication) @MainActor func tabbedKeepsPaneAfterOneMisreportedSweep() async throws {
    let (system, model) = twoDisplayFixture()
    defer { model.shutdown() }
    let panesBefore = try await enterTabbedOnExternal(model, system)
    let selectionsBefore = model.activeTabbedState?.panes.map(\.selected)
    // A tab that is not in the focused window's pane.
    let moved = try #require(panesBefore.first { !$0.contains("E1") }?.first)
    let index = try #require(system.windows.firstIndex { $0.id.rawValue == moved })
    let home = system.windows[index]

    system.windows[index].displayID = laptopID
    system.windows[index].frame.origin.x = 200
    system.desktopObservation?.windowMembership[home.id] = [laptopSpace]
    model.handleApplicationTopologyChange(waking: true)
    await system.advance(by: .milliseconds(300))

    system.windows[index] = home
    system.desktopObservation?.windowMembership[home.id] = [externalSpace]
    model.handleApplicationTopologyChange(waking: true)
    await system.advance(by: .milliseconds(400))
    for _ in 0..<4 { model.watchdog(); await system.advance(by: .milliseconds(200)) }

    let panesAfter = tabbedPanes(model, system, focusing: "E1")
    #expect(model.activeTabbedState?.panes.map(\.selected) == selectionsBefore)
    #expect(panesAfter == panesBefore, "before \(panesBefore) after \(panesAfter)")
}

/// An ordinary desktop switch away and back, on one display.
@Test(.appTestApplication, arguments: [false, true]) @MainActor
func tabbedKeepsPanesAcrossDesktopSwitch(otherDesktopIsTabbed: Bool) async throws {
    _ = NSApplication.shared
    let system = makeManualWindowSystem(drivingPolicyDeadlines: true)
    let a = NativeSpaceID(rawValue: 1), b = NativeSpaceID(rawValue: 2)
    let d = system.mainDisplay.id
    system.windows = [window("A1", pid: 41, x: 0, display: d), window("A2", pid: 42, x: 500, display: d),
                      window("A3", pid: 43, x: 250, display: d)]
    let other = [window("B1", pid: 51, x: 100, display: d), window("B2", pid: 52, x: 400, display: d)]
    system.desktopObservation = NativeDesktopObservation(
        currentSpaceByDisplay: [d: a], knownSpacesByDisplay: [d: [a, b]],
        windowMembership: Dictionary(uniqueKeysWithValues: system.windows.map { ($0.id, [a]) } + other.map { ($0.id, [b]) }))
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.configuration.defaultTabbedPreset = .columns
    system.focusedID = WindowID(rawValue: "A1")
    model.setActiveMode(.tabbed)
    try #require(await system.waitFor { model.activeTabbedState?.windowIDs.count == 3 && !model.hasPendingTabbedPlacement })
    await system.advance(by: .milliseconds(300))
    model.performTabbed(.preset(.columns, grouping: .distributeWindows))
    try #require(await system.waitFor { !model.hasPendingTabbedPlacement })
    await system.advance(by: .milliseconds(400))
    let panesBefore = tabbedPanes(model, system, focusing: "A1")
    let selectionsBefore = model.activeTabbedState?.panes.map(\.selected)
    try #require(panesBefore.count == 2 && panesBefore.allSatisfy { !$0.isEmpty }, "\(panesBefore)")
    let homeA = system.windows

    var history: [String] = []
    for round in 0..<3 {
        system.desktopObservation?.currentSpaceByDisplay[d] = b
        system.windows = other
        system.focusedID = other[0].id
        model.beginActiveSpaceStabilization()
        try #require(await system.waitFor { !model.isStabilizingSpace })
        await system.advance(by: .milliseconds(300))
        if round == 0, otherDesktopIsTabbed {
            model.setActiveMode(.tabbed)
            try #require(await system.waitFor { !model.hasPendingTabbedPlacement })
            await system.advance(by: .milliseconds(300))
        }
        let otherSnapshot = system.windows
        system.desktopObservation?.currentSpaceByDisplay[d] = a
        system.windows = homeA.map { home in otherSnapshot.first { $0.id == home.id } ?? home }
        system.focusedID = WindowID(rawValue: "A1")
        model.beginActiveSpaceStabilization()
        try #require(await system.waitFor { !model.isStabilizingSpace })
        await system.advance(by: .milliseconds(300))
        for _ in 0..<2 { model.watchdog(); await system.advance(by: .milliseconds(200)) }
        history.append("\(tabbedPanes(model, system, focusing: "A1"))")
        #expect(model.activeTabbedState?.panes.map(\.selected) == selectionsBefore)
        // Keep B's windows where Tabbed put them for the next visit.
        _ = otherSnapshot
    }
    #expect(history.allSatisfy { $0 == "\(panesBefore)" }, "before \(panesBefore) after each return \(history)")
}

enum TabbedInterruption: String, CaseIterable, Sendable { case hideApp, minimize, fullScreen, narrowWorkArea }

/// Everyday actions that take a tab out of its pane for a moment.
@Test(.appTestApplication, arguments: TabbedInterruption.allCases) @MainActor
func tabbedKeepsPaneAfterInterruption(_ interruption: TabbedInterruption) async throws {
    _ = NSApplication.shared
    let system = makeManualWindowSystem(drivingPolicyDeadlines: true)
    let d = system.mainDisplay.id
    system.windows = [window("A1", pid: 41, x: 0, display: d, minimumWidth: 300),
                      window("A2", pid: 42, x: 500, display: d, minimumWidth: 300),
                      window("A3", pid: 43, x: 250, display: d, minimumWidth: 300)]
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.configuration.defaultTabbedPreset = .columns
    system.focusedID = WindowID(rawValue: "A1")
    model.setActiveMode(.tabbed)
    try #require(await system.waitFor { model.activeTabbedState?.windowIDs.count == 3 && !model.hasPendingTabbedPlacement })
    await system.advance(by: .milliseconds(300))
    model.performTabbed(.preset(.columns, grouping: .distributeWindows))
    try #require(await system.waitFor { !model.hasPendingTabbedPlacement })
    await system.advance(by: .milliseconds(400))
    let panesBefore = tabbedPanes(model, system, focusing: "A1")
    let selectionsBefore = model.activeTabbedState?.panes.map(\.selected)
    try #require(panesBefore.count == 2 && panesBefore.allSatisfy { !$0.isEmpty }, "\(panesBefore)")
    // Interrupt the window that is alone in its pane.
    let target = try #require(panesBefore.first { $0.count == 1 }?.first)
    let index = try #require(system.windows.firstIndex { $0.id.rawValue == target })
    let original = system.windows[index]

    switch interruption {
    case .hideApp: system.windows[index].isHidden = true
    case .minimize: system.windows[index].isMinimized = true
    case .fullScreen: system.windows[index].isFullScreen = true
    case .narrowWorkArea: system.availableDisplays[0].visibleFrame.size.width = 550
    }
    model.watchdog()
    await system.advance(by: .milliseconds(1500))
    let during = tabbedPanes(model, system, focusing: "A1")
    switch interruption {
    case .narrowWorkArea: system.availableDisplays[0].visibleFrame.size.width = 1000
    default: system.windows[index] = WindowSnapshot(
        id: original.id, processIdentifier: original.processIdentifier, bundleIdentifier: original.bundleIdentifier,
        frame: system.windows[index].frame, displayID: d, constraints: original.constraints)
    }
    model.watchdog()
    await system.advance(by: .milliseconds(1500))
    for _ in 0..<2 { model.watchdog(); await system.advance(by: .milliseconds(200)) }
    let panesAfter = tabbedPanes(model, system, focusing: "A1")
    #expect(model.activeTabbedState?.panes.map(\.selected) == selectionsBefore)
    #expect(panesAfter == panesBefore, "\(interruption): before \(panesBefore) during \(during) after \(panesAfter)")
}

@Suite @MainActor struct TabbedReturnLifecycleModelTests {
    private func fixture() async throws -> (FakeAppWindowSystem, BetterTileModel) {
        _ = NSApplication.shared
        let system = makeManualWindowSystem(drivingPolicyDeadlines: true)
        let display = system.mainDisplay.id
        system.windows = [window("A1", pid: 41, x: 0, display: display),
                          window("A2", pid: 42, x: 500, display: display),
                          window("A3", pid: 43, x: 250, display: display)]
        system.focusedID = WindowID(rawValue: "A1")
        let model = makeModel(system: system)
        model.configuration.defaultTabbedPreset = .columns
        model.setActiveMode(.tabbed)
        try #require(await system.waitFor { model.activeTabbedState?.windowIDs.count == 3 && !model.hasPendingTabbedPlacement })
        let pane = try #require(model.activeTabbedState?.panes[1].id)
        model.performTabbed(.move(.init(rawValue: "A2"), pane: pane, index: nil))
        try #require(await system.waitFor { !model.hasPendingTabbedPlacement })
        model.performTabbed(.move(.init(rawValue: "A3"), pane: pane, index: nil))
        try #require(await system.waitFor { !model.hasPendingTabbedPlacement })
        model.performTabbed(.select(.init(rawValue: "A2")))
        try #require(await system.waitFor { !model.hasPendingTabbedPlacement })
        model.performTabbed(.select(.init(rawValue: "A1")))
        try #require(await system.waitFor { !model.hasPendingTabbedPlacement })
        await system.advance(by: .seconds(1))
        return (system, model)
    }

    // Lifecycle handlers update the store synchronously before a sweep captures
    // `before`. This verifies no writes for those events, not the sweep's use of
    // layoutEquals: there is no supported event path that defers only slot cleanup
    // to that sweep. The Core equality test covers this defensive distinction.
    @Test(.appTestApplication) func minimizedHiddenTabAndSlotOnlyCloseWriteNoFrames() async throws {
        let (system, model) = try await fixture()
        defer { model.shutdown() }
        let id = WindowID(rawValue: "A3")
        let writes = system.frameWriteCounts
        let index = try #require(system.windows.firstIndex { $0.id == id })
        system.windows[index].isMinimized = true
        system.eventHandler?(.init(kind: .minimized, windowID: id, processIdentifier: 43))
        try #require(model.activeTabbedState?.returnSlots[id] != nil)
        await system.advance(by: .seconds(1))
        model.watchdog()
        await system.advance(by: .seconds(1))
        #expect(system.frameWriteCounts == writes, "Stepping away without changing visible selections must not write frames")
        let home = try #require(model.activeTabbedState?.returnSlots[id]?.paneID)
        system.eventHandler?(.init(kind: .destroyed, windowID: id, processIdentifier: 43))
        try #require(model.activeTabbedState?.returnSlots[id] == nil)
        await system.advance(by: .seconds(1))
        model.watchdog()
        await system.advance(by: .seconds(1))
        #expect(system.frameWriteCounts == writes, "Clearing a return slot alone must not write frames")
        #expect(model.activeTabbedState?.panes.first { $0.id == home }?.selected == WindowID(rawValue: "A2"))
    }

    @Test(.appTestApplication) func minimizedEventReturnsTabToItsPaneAndIndex() async throws {
        let (system, model) = try await fixture()
        defer { model.shutdown() }
        let id = WindowID(rawValue: "A2")
        let home = try #require(model.activeTabbedState?.pane(containing: id))
        let index = try #require(system.windows.firstIndex { $0.id == id })
        system.windows[index].isMinimized = true
        system.eventHandler?(.init(kind: .minimized, windowID: id, processIdentifier: 42))
        await system.advance(by: .seconds(1))
        system.windows[index].isMinimized = false
        system.eventHandler?(.init(kind: .restored, windowID: id, processIdentifier: 42))
        try #require(await system.waitFor { model.activeTabbedState?.pane(containing: id)?.id == home.id && !model.hasPendingTabbedPlacement })
        #expect(model.activeTabbedState?.pane(containing: id)?.tabs == home.tabs)
        #expect(model.activeTabbedState?.pane(containing: id)?.selected == home.selected)
    }

    @Test(.appTestApplication) func undoKeepsTemporarilyAbsentTabsReturnSlots() async throws {
        let (system, model) = try await fixture()
        defer { model.shutdown() }
        let id = WindowID(rawValue: "A2")
        let home = try #require(model.activeTabbedState?.pane(containing: id))
        model.performTabbed(.move(.init(rawValue: "A3"), pane: try #require(model.activeTabbedState?.panes[0].id), index: nil))
        try #require(await system.waitFor { !model.hasPendingTabbedPlacement })
        let index = try #require(system.windows.firstIndex { $0.id == id })
        system.windows[index].isMinimized = true
        system.eventHandler?(.init(kind: .minimized, windowID: id, processIdentifier: 42))
        await system.advance(by: .seconds(1))
        model.performTabbed(.undo)
        try #require(await system.waitFor { !model.hasPendingTabbedPlacement })
        #expect(model.activeTabbedState?.returnSlots[id]?.paneID == home.id)
        system.windows[index].isMinimized = false
        system.eventHandler?(.init(kind: .restored, windowID: id, processIdentifier: 42))
        try #require(await system.waitFor { model.activeTabbedState?.windowIDs.contains(id) == true && !model.hasPendingTabbedPlacement })
        #expect(model.activeTabbedState?.pane(containing: id)?.id == home.id)
        #expect(model.activeTabbedState?.pane(containing: id)?.tabs == home.tabs)
        #expect(model.activeTabbedState?.pane(containing: id)?.selected == home.selected)
    }


    @Test(.appTestApplication) func undoAfterRestorationKeepsTheSnapshotsReturnPane() async throws {
        let (system, model) = try await fixture()
        defer { model.shutdown() }
        func settle() async throws {
            await system.advance(by: .milliseconds(300))
            try #require(await system.waitFor {
                !model.hasPendingTabbedPlacement && model.windowEventTask == nil
            })
        }
        let b = WindowID(rawValue: "A2"), c = WindowID(rawValue: "A3")
        let before = try #require(model.activeTabbedState)
        let home = try #require(before.pane(containing: b))
        let active = before.activePaneID
        try #require(home.tabs == [b, c] && home.selected == b && active != home.id)
        let index = try #require(system.windows.firstIndex { $0.id == b })
        system.windows[index].isMinimized = true
        system.eventHandler?(.init(kind: .minimized, windowID: b, processIdentifier: 42))
        try await settle()
        try #require(model.activeTabbedState?.returnSlots[b]?.paneID == home.id)
        model.performTabbed(.move(c, pane: active, index: nil))
        try await settle()
        try #require(model.activeTabbedState?.paneID(containing: c) == active)
        system.windows[index].isMinimized = false
        system.eventHandler?(.init(kind: .restored, windowID: b, processIdentifier: 42))
        try await settle()
        try #require(model.activeTabbedState?.paneID(containing: b) == home.id)
        model.performTabbed(.undo)
        try await settle()
        let after = try #require(model.activeTabbedState)
        #expect(after.paneID(containing: b) == home.id)
        #expect(after.panes.map(\.tabs) == before.panes.map(\.tabs))
        #expect(after.panes.map(\.selected) == before.panes.map(\.selected))
        #expect(after.panes.map(\.id) == before.panes.map(\.id))
    }

    @Test(.appTestApplication, arguments: [false, true])
    func slotOnlyCloseDoesNotRejectPendingSavedLayoutApply(atFinalCheckpoint: Bool) async throws {
        let system = makeManualWindowSystem(drivingPolicyDeadlines: true)
        let h = ApplyHarness(system: system)
        defer { h.close() }
        for index in 1...3 { h.addWindow(id: "W\(index)", pid: Int32(40 + index)) }
        system.focusedID = system.windows[0].id
        let model = h.model()
        system.installWindowEventClock(in: model)
        defer { model.shutdown() }
        model.configuration.defaultTabbedPreset = .columns
        model.setActiveMode(.tabbed)
        try #require(await system.waitFor { model.activeTabbedState?.windowIDs.count == 3 && !model.hasPendingTabbedPlacement })
        let id = try #require(model.activeTabbedState?.hiddenWindowIDs.sorted().first)
        let index = try #require(system.windows.firstIndex { $0.id == id })
        let pid = system.windows[index].processIdentifier
        system.windows[index].isMinimized = true
        system.eventHandler?(.init(kind: .minimized, windowID: id, processIdentifier: pid))
        await system.advance(by: .seconds(1))
        try #require(model.activeTabbedState?.returnSlots[id] != nil)
        let applier = try #require(model.savedLayoutApplier)
        applier.observesKeyboard = false
        applier.application = h.applier.application
        func closeAbsentTab() {
            system.windows.removeAll { $0.id == id }
            system.eventHandler?(.init(kind: .destroyed, windowID: id, processIdentifier: pid))
            #expect(model.activeTabbedState?.returnSlots[id] == nil)
        }
        if atFinalCheckpoint {
            model.savedLayoutInputCheckpoint = { closeAbsentTab(); return true }
        } else {
            let commit = applier.commit
            applier.commit = { plan, desktop, snapshot, valid in
                closeAbsentTab()
                return await commit(plan, desktop, snapshot, valid)
            }
        }
        var document = h.document(mode: .tabbed)
        document.keepForNewWindows = true
        let result = try #require(await system.drive { await applier.apply(document, layoutFileID: "Work.json") })
        #expect(result.issues.isEmpty, "\(result.issues)")
        #expect(model.followedSavedLayout != nil)
        #expect(model.activeTabbedState?.returnSlots[id] == nil)
    }

}
