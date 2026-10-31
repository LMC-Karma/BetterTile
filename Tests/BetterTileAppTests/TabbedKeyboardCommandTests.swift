import AppKit
import BetterTileCore
import BetterTileMacOS
import Testing
@testable import BetterTileApp

@MainActor private func tabCommandFixture(count: Int = 3, preset: TabbedPreset = .columns,
                                          nativeSpaceID: NativeSpaceID? = nil)
    async throws -> (FakeAppWindowSystem, BetterTileModel) {
    _ = NSApplication.shared
    let system = FakeAppWindowSystem()
    if count > 1 {
        for index in 1..<count {
            var window = system.windows[0]
            window.id = WindowID(rawValue: "tab-command-\(index)")
            window.processIdentifier += Int32(index)
            system.windows.append(window)
        }
    }
    if let nativeSpaceID {
        system.desktopObservation = NativeDesktopObservation(
            currentSpaceByDisplay: [system.mainDisplay.id: nativeSpaceID],
            knownSpacesByDisplay: [system.mainDisplay.id: [nativeSpaceID]],
            windowMembership: Dictionary(uniqueKeysWithValues: system.windows.map { ($0.id, [nativeSpaceID]) })
        )
    }
    let model = makeModel(system: system)
    model.configuration.defaultTabbedPreset = preset
    model.setActiveMode(.tabbed)
    try #require(await waitFor { model.activeTabbedState?.windowIDs.count == count })
    model.performTabbed(.select(system.windows[0].id))
    try #require(await waitFor { model.activeTabbedState?.activeWindowID == system.windows[0].id })
    try #require(await waitFor { !model.hasPendingTabbedPlacement })
    await model.tabbedFocusTask?.value
    return (system, model)
}

@Test(.appTestApplication, arguments: WindowAction.tabCommands, [false, true]) @MainActor
func tabCommandsUseExistingSelectionAndMoveRoutes(action: WindowAction, wheel: Bool) async throws {
    let (system, model) = try await tabCommandFixture()
    defer { model.shutdown() }
    let before = try #require(model.activeTabbedState)
    let a = system.windows[0].id, b = system.windows[1].id, c = system.windows[2].id
    let source = before.panes[0].id, destination = before.panes[1].id
    if action == .moveTabLeft {
        model.performTabbed(.select(b))
        try #require(await waitFor { model.activeTabbedState?.activeWindowID == b && system.focusedID == b })
    }
    let selected = action == .moveTabLeft ? b : a
    let target = try #require(model.captureLayoutWheelTarget())
    if wheel {
        let writes = system.frameWriteCounts
        guard case let .ready(placements) = model.previewLayoutWheel(.windowAction(action), for: target) else {
            Issue.record("Tab command should be assignable to the Layout Wheel")
            return
        }
        #expect(placements.isEmpty)
        #expect(system.frameWriteCounts == writes)
        model.performLayoutWheel(.windowAction(action), for: target)
    } else {
        model.perform(action)
    }
    let expected = switch action {
    case .nextTab: b
    case .previousTab: c
    default: selected
    }
    try #require(await waitFor(timeout: .seconds(2)) {
        guard let state = model.activeTabbedState else { return false }
        switch action {
        case .moveTabLeft: return state.panes[0].tabs == [b, a, c]
        case .moveTabRight: return state.panes[0].tabs == [b, a, c]
        case .moveTabToNextPane, .moveTabToPreviousPane: return state.paneID(containing: a) == destination
        default: return state.activeWindowID == expected
        }
    })
    #expect(await waitFor { system.focusedID == expected })
    #expect(model.activeTabbedState?.activeWindowID == expected)
    #expect(system.raiseRequests.contains { $0.0 == expected })
    if action == .moveTabToNextPane || action == .moveTabToPreviousPane {
        #expect(model.activeTabbedState?.panes[1].selected == a)
        #expect(model.activeTabbedState?.panes[0].tabs == [b, c])
        model.performTabbed(.undo)
        #expect(await waitFor { model.activeTabbedState?.paneID(containing: a) == source })
    }
    #expect(model.statusMessage == nil)
}

@Test(.appTestApplication, arguments: [WindowAction.nextTab, .previousTab]) @MainActor
func tabNavigationWrapsAndRepeatedCommandsUseCommittedSelection(action: WindowAction) async throws {
    let (system, model) = try await tabCommandFixture()
    defer { model.shutdown() }
    let a = system.windows[0].id
    for _ in 0..<3 { model.perform(action) }
    let first = action == .nextTab ? system.windows[1].id : system.windows[2].id
    try #require(await waitFor(timeout: .seconds(2)) { system.focusRequests.contains(first) })
    try #require(await waitFor(timeout: .seconds(2)) { model.activeTabbedState?.activeWindowID == a && system.focusedID == a })
    #expect(Set(system.focusRequests).isSuperset(of: system.windows.map(\.id)))
}

@Test(.appTestApplication, arguments: [WindowAction.moveTabLeft, .moveTabRight]) @MainActor
func tabReorderingStopsAtStripEnds(action: WindowAction) async throws {
    let (system, model) = try await tabCommandFixture()
    defer { model.shutdown() }
    let selected = action == .moveTabLeft ? system.windows[0].id : system.windows[2].id
    model.performTabbed(.select(selected))
    try #require(await waitFor { model.activeTabbedState?.activeWindowID == selected && system.focusedID == selected })
    try #require(await waitFor { !model.hasPendingTabbedPlacement })
    let before = model.activeTabbedState, writes = system.frameWriteCounts
    let requests = system.focusRequests.count
    model.perform(action)
    try #require(await waitFor { !model.hasPendingTabbedPlacement })
    #expect(model.activeTabbedState == before)
    #expect(system.frameWriteCounts == writes)
    #expect(system.focusRequests.count == requests)
}

@Test(.appTestApplication, arguments: WindowAction.tabCommands) @MainActor
func tabCommandsDoNothingWithOneTabAndOnePane(action: WindowAction) async throws {
    let (system, model) = try await tabCommandFixture(count: 1, preset: .single)
    defer { model.shutdown() }
    try #require(await waitFor { !model.hasPendingTabbedPlacement })
    let before = model.activeTabbedState, writes = system.frameWriteCounts
    let requests = system.focusRequests.count
    model.perform(action)
    try #require(await waitFor { !model.hasPendingTabbedPlacement })
    #expect(model.activeTabbedState == before)
    #expect(system.frameWriteCounts == writes)
    #expect(system.focusRequests.count == requests)
}

@Test(.appTestApplication, arguments: WindowAction.tabCommands) @MainActor
func tabCommandsDoNothingInAnEmptyPane(action: WindowAction) async throws {
    let (system, model) = try await tabCommandFixture(count: 1)
    defer { model.shutdown() }
    let empty = try #require(model.activeTabbedState?.panes[1].id)
    model.performTabbed(.activate(empty))
    system.focusedID = nil
    system.focusedWindowIsAbsent = true
    try #require(await waitFor { !model.hasPendingTabbedPlacement })
    let before = model.activeTabbedState, writes = system.frameWriteCounts
    model.perform(action)
    try #require(await waitFor { !model.hasPendingTabbedPlacement })
    #expect(model.activeTabbedState == before)
    #expect(system.frameWriteCounts == writes)
}

@Test(.appTestApplication, arguments: [WindowAction.moveTabToNextPane, .moveTabToPreviousPane]) @MainActor
func tabPaneCommandsFollowMenuOrderAndKeepEmptyPanes(action: WindowAction) async throws {
    let (system, model) = try await tabCommandFixture(count: 1, preset: .grid)
    defer { model.shutdown() }
    let before = try #require(model.activeTabbedState)
    let a = system.windows[0].id
    let destination = before.panes[action == .moveTabToNextPane ? 1 : 3].id
    model.perform(action)
    try #require(await waitFor { model.activeTabbedState?.paneID(containing: a) == destination })
    #expect(model.activeTabbedState?.panes.map(\.id) == before.panes.map(\.id))
    #expect(model.activeTabbedState?.panes[0].tabs.isEmpty == true)
    #expect(model.activeTabbedState?.pane(containing: a)?.selected == a)
}

@Test(.appTestApplication, arguments: [WindowAction.moveTabToNextPane, .moveTabToPreviousPane], [false, true]) @MainActor
func failedTabPaneCommandRollsBackMembershipAndFrames(action: WindowAction, occupiedDestination: Bool) async throws {
    let (system, model) = try await tabCommandFixture()
    defer { model.shutdown() }
    if occupiedDestination {
        let c = system.windows[2].id, a = system.windows[0].id
        let right = try #require(model.activeTabbedState?.panes[1].id)
        model.performTabbed(.move(c, pane: right, index: nil))
        try #require(await waitFor { model.activeTabbedState?.paneID(containing: c) == right })
        model.performTabbed(.select(a))
        try #require(await waitFor { model.activeTabbedState?.activeWindowID == a && system.focusedID == a })
    }
    let before = model.activeTabbedState, frames = system.windows.map(\.frame)
    system.ignoredFrameWriteWindowIDs.insert(system.windows[0].id)
    model.perform(action)
    try #require(await waitFor(timeout: .seconds(2)) { model.statusMessage != nil })
    #expect(model.activeTabbedState == before)
    #expect(system.windows.map(\.frame) == frames)
    #expect(model.lastActionFeedback?.kind == .failure)
}

@Test(.appTestApplication, arguments: WindowAction.tabCommands, [LayoutMode.manual, .bento]) @MainActor
func tabCommandsReportUnavailableOutsideTabbed(action: WindowAction, mode: LayoutMode) async throws {
    _ = NSApplication.shared
    let system = FakeAppWindowSystem()
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.setActiveMode(mode)
    let before = system.windows, writes = system.frameWriteCounts
    let target = try #require(model.captureLayoutWheelTarget())
    for wheel in [false, true] {
        if wheel { model.performLayoutWheel(.windowAction(action), for: target) }
        else { model.perform(action) }
        #expect(model.statusMessage == "Tab commands work on Tabbed desktops.")
        #expect(model.lastActionFeedback?.kind == .failure)
        #expect(model.lastActionFeedback?.message == "Tabbed not active")
        #expect(model.lastActionFeedback?.detail == "Tab commands work on Tabbed desktops.")
        #expect(system.windows == before)
        #expect(system.frameWriteCounts == writes)
    }
}

@Test(.appTestApplication, arguments: WindowAction.tabCommands) @MainActor
func wheelTabCommandKeepsItsCapturedPaneAfterFocusChanges(action: WindowAction) async throws {
    let (system, model) = try await tabCommandFixture()
    defer { model.shutdown() }
    let a = system.windows[0].id, b = system.windows[1].id, c = system.windows[2].id
    let right = try #require(model.activeTabbedState?.panes[1].id)
    model.performTabbed(.move(c, pane: right, index: nil))
    try #require(await waitFor { model.activeTabbedState?.paneID(containing: c) == right })
    let source = action == .moveTabLeft ? b : a
    model.performTabbed(.select(source))
    try #require(await waitFor { model.activeTabbedState?.activeWindowID == source && system.focusedID == source })
    let target = try #require(model.captureLayoutWheelTarget())
    model.performTabbed(.select(c))
    try #require(await waitFor { model.activeTabbedState?.activeWindowID == c && system.focusedID == c })
    model.performLayoutWheel(.windowAction(action), for: target)
    let expected = action == .nextTab || action == .previousTab ? b : source
    try #require(await waitFor { model.activeTabbedState?.activeWindowID == expected && system.focusedID == expected })
    if action == .moveTabToNextPane || action == .moveTabToPreviousPane {
        #expect(model.activeTabbedState?.panes[1].tabs == [c, a])
        #expect(model.activeTabbedState?.panes[1].selected == a)
        #expect(model.activeTabbedState?.panes[0].tabs == [b])
    } else {
        #expect(model.activeTabbedState?.panes[1].tabs == [c])
        #expect(model.activeTabbedState?.panes[0].tabs == (action == .moveTabLeft || action == .moveTabRight ? [b, a] : [a, b]))
    }
}

@Test(.appTestApplication, arguments: WindowAction.tabCommands, [false, true]) @MainActor
func tabCommandsUseCachedWindowsWithoutAFullScan(action: WindowAction, wheel: Bool) async throws {
    let (system, model) = try await tabCommandFixture()
    defer { model.shutdown() }
    if action == .moveTabLeft {
        let b = system.windows[1].id
        model.performTabbed(.select(b))
        try #require(await waitFor { model.activeTabbedState?.activeWindowID == b && system.focusedID == b })
    }
    try #require(await waitFor { !model.hasPendingTabbedPlacement })
    await model.tabbedFocusTask?.value
    let target = try #require(model.captureLayoutWheelTarget())
    let scans = system.completeSweepCount
    if wheel {
        guard case .ready = model.previewLayoutWheel(.windowAction(action), for: target) else {
            Issue.record("Tab command should have a wheel preview")
            return
        }
        model.performLayoutWheel(.windowAction(action), for: target)
    } else {
        model.perform(action)
    }
    try #require(await waitFor { !model.hasPendingTabbedPlacement })
    await model.tabbedFocusTask?.value
    #expect(system.completeSweepCount == scans)
}

@Test(.appTestApplication, arguments: WindowAction.tabCommands, [(false, false), (false, true), (true, false), (true, true)]) @MainActor
func tabCommandsExplainWhenFocusedWindowIsNotATab(action: WindowAction, scenario: (wheel: Bool, floating: Bool)) async throws {
    let (system, model) = try await tabCommandFixture()
    defer { model.shutdown() }
    if scenario.floating {
        let id = system.windows[0].id
        model.performTabbed(.float(id))
        try #require(await waitFor { model.activeTabbedState?.floatingWindowIDs.contains(id) == true })
    } else {
        var outsider = system.windows[0]
        outsider.id = WindowID(rawValue: "not-a-tab")
        system.windows.append(outsider)
        system.focusedID = outsider.id
    }
    try #require(await waitFor { !model.hasPendingTabbedPlacement })
    await model.tabbedFocusTask?.value
    let target = try #require(model.captureLayoutWheelTarget())
    let before = model.activeTabbedState, writes = system.frameWriteCounts
    if scenario.wheel { model.performLayoutWheel(.windowAction(action), for: target) }
    else { model.perform(action) }
    try #require(await waitFor { !model.hasPendingTabbedPlacement })
    #expect(model.lastActionFeedback?.kind == .failure)
    #expect(model.lastActionFeedback?.message == "Focus a tab to use tab commands.")
    #expect(model.lastActionFeedback?.detail == nil)
    #expect(model.activeTabbedState == before)
    #expect(system.frameWriteCounts == writes)
}

@Test(.appTestApplication, arguments: WindowAction.tabCommands) @MainActor
func tabCommandsRejectAChangedNativeSpace(action: WindowAction) async throws {
    let (system, model) = try await tabCommandFixture(nativeSpaceID: NativeSpaceID(rawValue: 1))
    defer { model.shutdown() }
    let target = try #require(model.captureLayoutWheelTarget())
    let before = model.activeTabbedState, writes = system.frameWriteCounts
    system.desktopObservation?.currentSpaceByDisplay[system.mainDisplay.id] = NativeSpaceID(rawValue: 2)
    for wheel in [false, true] {
        if wheel { model.performLayoutWheel(.windowAction(action), for: target) }
        else { model.perform(action) }
        try #require(await waitFor { !model.hasPendingTabbedPlacement })
        #expect(model.activeTabbedState == before)
        #expect(system.frameWriteCounts == writes)
    }
}

@Test(.appTestApplication, arguments: [WindowAction.nextTab, .previousTab], [(false, false), (false, true), (true, false), (true, true)]) @MainActor
func tabNavigationRejectsDepartedDestinationBeforeRaising(action: WindowAction, scenario: (wheel: Bool, otherDisplay: Bool)) async throws {
    let space = NativeSpaceID(rawValue: 1), elsewhere = NativeSpaceID(rawValue: 2)
    let (system, model) = try await tabCommandFixture(count: 2, nativeSpaceID: space)
    defer { model.shutdown() }
    let target = try #require(model.captureLayoutWheelTarget())
    let departed = system.windows[1].id
    if scenario.otherDisplay {
        let display = DisplaySnapshot(id: DisplayID(rawValue: "other"),
            frame: BTRect(x: 1000, y: 0, width: 1000, height: 800),
            visibleFrame: BTRect(x: 1000, y: 0, width: 1000, height: 800))
        system.availableDisplays.append(display)
        system.desktopObservation?.currentSpaceByDisplay[display.id] = elsewhere
        system.desktopObservation?.knownSpacesByDisplay[display.id] = [elsewhere]
        system.windows[1].displayID = display.id
        system.windows[1].frame.origin.x += 1000
    } else {
        system.desktopObservation?.knownSpacesByDisplay[system.mainDisplay.id]?.insert(elsewhere)
    }
    system.desktopObservation?.windowMembership[departed] = [elsewhere]
    let before = model.activeTabbedState, writes = system.frameWriteCounts
    let scans = system.completeSweepCount, raises = system.raiseRequests.count
    let focuses = system.focusRequests.count, probes = system.probeRequests.count
    if scenario.wheel { model.performLayoutWheel(.windowAction(action), for: target) }
    else { model.perform(action) }
    try #require(await waitFor { !model.hasPendingTabbedPlacement })
    await model.tabbedFocusTask?.value
    #expect(model.activeTabbedState == before)
    #expect(system.frameWriteCounts == writes)
    #expect(system.completeSweepCount == scans)
    #expect(!system.raiseRequests.dropFirst(raises).contains { $0.0 == departed })
    #expect(!system.focusRequests.dropFirst(focuses).contains(departed))
    #expect(!system.probeRequests.dropFirst(probes).contains { $0.contains(departed) })
    #expect(system.focusedID == target.windowID)
}

@Test(.appTestApplication, arguments: WindowAction.tabCommands, [(false, false), (false, true), (true, false), (true, true)]) @MainActor
func tabCommandsRejectNewlyFloatingSourceBeforeReconciliation(action: WindowAction, scenario: (wheel: Bool, sticky: Bool)) async throws {
    let space = NativeSpaceID(rawValue: 1), elsewhere = NativeSpaceID(rawValue: 2)
    let (system, model) = try await tabCommandFixture(nativeSpaceID: scenario.sticky ? space : nil)
    defer { model.shutdown() }
    let target = try #require(model.captureLayoutWheelTarget())
    if scenario.sticky {
        system.desktopObservation?.knownSpacesByDisplay[system.mainDisplay.id]?.insert(elsewhere)
        system.desktopObservation?.windowMembership[try #require(target.windowID)] = [space, elsewhere]
    } else {
        system.windows[0].isFloating = true
    }
    let before = model.activeTabbedState, writes = system.frameWriteCounts
    let scans = system.completeSweepCount, raises = system.raiseRequests.count
    let focuses = system.focusRequests.count
    if scenario.wheel { model.performLayoutWheel(.windowAction(action), for: target) }
    else { model.perform(action) }
    try #require(await waitFor { !model.hasPendingTabbedPlacement })
    await model.tabbedFocusTask?.value
    #expect(model.lastActionFeedback?.kind == .failure)
    #expect(model.lastActionFeedback?.message == "Focus a tab to use tab commands.")
    #expect(model.activeTabbedState == before)
    #expect(system.frameWriteCounts == writes)
    #expect(system.completeSweepCount == scans)
    #expect(system.raiseRequests.count == raises)
    #expect(system.focusRequests.count == focuses)
}
