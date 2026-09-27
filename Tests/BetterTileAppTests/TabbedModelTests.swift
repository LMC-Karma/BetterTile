import AppKit
import BetterTileCore
import BetterTileMacOS
import Testing
@testable import BetterTileApp

@Test(arguments: [TabbedPreset.rows, .focus], [0.01, 0.99]) @MainActor
func tabbedRowResizeClampsAtMinimumInsteadOfFreezing(preset: TabbedPreset, ratio: Double) async throws {
    _ = NSApplication.shared
    let system = FakeAppWindowSystem()
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.configuration.defaultTabbedPreset = preset
    model.setActiveMode(.tabbed)
    try #require(await waitFor { model.activeTabbedState?.panes.count == preset.paneCount })
    let before = try #require(model.activeTabbedState)
    let divider = try #require(before.dividers(in: system.mainDisplay.visibleFrame).first { !$0.vertical })
    model.performTabbed(.beginResize)
    model.performTabbed(.resize(divider.id, ratio))
    let resized = try #require(model.activeTabbedState)
    let actual = try #require(resized.dividers(in: system.mainDisplay.visibleFrame).first { $0.id == divider.id })
    #expect(ratio < 0.5 ? actual.ratio < 0.5 : actual.ratio > 0.5)
    let frames = resized.frames(in: system.mainDisplay.visibleFrame)
    #expect(frames.values.allSatisfy { $0.size.height + 0.001 >= 114 })
    #expect(resized.panes == before.panes)
    model.performTabbed(.cancelResize)
    #expect(model.activeTabbedState == before)
}

@Test(arguments: [false, true]) @MainActor
func tabSelectionDoesNotRearrangeOrRefitOtherWindows(sharedApplication: Bool) async throws {
    _ = NSApplication.shared
    let system = FakeAppWindowSystem()
    for index in 1...3 {
        var window = system.windows[0]
        window.id = WindowID(rawValue: "tab-\(index)")
        window.processIdentifier += Int32(index)
        system.windows.append(window)
    }
    if sharedApplication { system.windows[2].processIdentifier = system.windows[1].processIdentifier }
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.configuration.defaultTabbedPreset = .columns
    model.setActiveMode(.tabbed)
    try #require(await waitFor { model.activeTabbedState?.windowIDs.count == 4 })
    let right = try #require(model.activeTabbedState?.panes[1].id)
    model.performTabbed(.move(system.windows[2].id, pane: right, index: nil))
    try #require(await waitFor { model.activeTabbedState?.panes[1].selected == system.windows[2].id })
    model.performTabbed(.move(system.windows[3].id, pane: right, index: nil))
    try #require(await waitFor { model.activeTabbedState?.panes[1].selected == system.windows[3].id })
    let previous = try #require(model.activeTabbedState)
    // Another app has changed its constraints and frame. A tab click must not
    // refit that pane or fail because that unrelated app cannot be resized.
    system.windows[3].constraints.isResizable = false
    system.windows[3].constraints.minimumSize.width = 900
    system.windows[3].frame = BTRect(x: 550, y: 70, width: 400, height: 600)
    let frames = system.windows.map(\.frame)
    let writes = system.frameWriteCounts
    let raises = system.raiseRequests.count
    let target = system.windows[1].id
    model.performTabbed(.select(target))
    #expect(await waitFor(timeout: .seconds(1)) { model.activeTabbedState?.activeWindowID == target })
    #expect(model.activeTabbedState?.root == previous.root)
    #expect(model.activeTabbedState?.panes[1] == previous.panes[1])
    #expect(system.windows.map(\.frame) == frames)
    #expect(system.frameWriteCounts == writes)
    #expect(system.focusedID == target)
    let raisedOtherPane = system.raiseRequests.dropFirst(raises).contains { $0.0 == system.windows[3].id }
    #expect(raisedOtherPane == sharedApplication)
}

@Test @MainActor func activatingEmptyTabbedPaneCancelsAnOlderFocusNotification() async throws {
    _ = NSApplication.shared
    let system = FakeAppWindowSystem()
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.configuration.defaultTabbedPreset = .columns
    model.setActiveMode(.tabbed)
    try #require(await waitFor { model.activeTabbedState?.panes.count == 2 })
    let emptyPane = try #require(model.activeTabbedState?.panes[1].id)
    system.eventHandler?(WindowSystemEvent(kind: .focused, windowID: system.windows[0].id, processIdentifier: system.windows[0].processIdentifier))
    model.performTabbed(.activate(emptyPane))
    try await Task.sleep(for: .milliseconds(400))
    #expect(model.activeTabbedState?.activePaneID == emptyPane)
}

@Test @MainActor func failedTabbedFocusReadDoesNotLeaveARefreshPending() async throws {
    _ = NSApplication.shared
    let system = FakeAppWindowSystem()
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.setActiveMode(.tabbed)
    try #require(await waitFor { model.activeTabbedState?.windowIDs.count == 1 })
    try await Task.sleep(for: .milliseconds(350))
    system.focusedWindowReadFails = true
    system.eventHandler?(WindowSystemEvent(kind: .focused, windowID: system.windows[0].id, processIdentifier: system.windows[0].processIdentifier))
    #expect(model.tabbedNeedsFocusRefresh)
    #expect(await waitFor(timeout: .seconds(1)) { !model.tabbedNeedsFocusRefresh })
}

@Test(arguments: [false, true]) @MainActor
func tabbedRetainsExternalFocusChangesDuringPlacementSuppression(duringResize: Bool) async throws {
    _ = NSApplication.shared
    let system = FakeAppWindowSystem()
    var second = system.windows[0]
    second.id = WindowID(rawValue: "second")
    system.windows.append(second)
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.configuration.defaultTabbedPreset = .columns
    model.setActiveMode(.tabbed)
    try #require(await waitFor { model.activeTabbedState?.windowIDs.count == 2 })
    #expect(model.activeTabbedState?.activeWindowID != second.id)
    if duringResize {
        let divider = try #require(model.activeTabbedState?.dividers(in: system.mainDisplay.visibleFrame).first)
        model.performTabbed(.beginResize)
        model.performTabbed(.resize(divider.id, 0.6))
    }
    system.focusedID = second.id
    system.eventHandler?(WindowSystemEvent(kind: .focused, windowID: second.id, processIdentifier: second.processIdentifier))
    if duringResize {
        try await Task.sleep(for: .milliseconds(400))
        #expect(model.activeTabbedState?.activeWindowID != second.id)
        model.performTabbed(.endResize)
    }
    #expect(await waitFor(timeout: .seconds(1)) { model.activeTabbedState?.activeWindowID == second.id })
}

@Test(arguments: [false, true]) @MainActor
func degradedTabbedResizeRestoresItsBaselineOrStopsAutomaticPlacement(failRestore: Bool) async throws {
    _ = NSApplication.shared
    let system = FakeAppWindowSystem()
    var second = system.windows[0]
    second.id = WindowID(rawValue: "second")
    system.windows.append(second)
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.configuration.defaultTabbedPreset = .columns
    model.setActiveMode(.tabbed)
    try #require(await waitFor { model.activeTabbedState?.windowIDs.count == 2 })
    let before = try #require(model.activeTabbedState)
    let frames = system.windows.map(\.frame)
    let divider = try #require(before.dividers(in: system.mainDisplay.visibleFrame).first)
    model.performTabbed(.beginResize)
    model.performTabbed(.resize(divider.id, 0.6))
    let first = system.windows[0].id
    let writes = system.frameWriteCounts[first, default: 0]
    system.failedFrameWriteNumbers[second.id] = [system.frameWriteCounts[second.id, default: 0] + 1]
    system.failedFrameWriteNumbers[first] = failRestore ? [writes + 2, writes + 3] : [writes + 2]
    model.performTabbed(.resize(divider.id, 0.65))
    if !failRestore {
        #expect(model.activeTabbedState == before)
        #expect(system.windows.map(\.frame) == frames)
    }
    var added = second
    added.id = WindowID(rawValue: "after-degraded-resize")
    system.windows.append(added)
    let counts = system.frameWriteCounts
    system.eventHandler?(WindowSystemEvent(kind: .created, windowID: added.id, processIdentifier: added.processIdentifier))
    try #require(await waitFor { model.activeTabbedState?.windowIDs.contains(added.id) == true })
    if failRestore { #expect(system.frameWriteCounts == counts) }
}

@Test @MainActor func failedTabbedResizeCancellationStopsAutomaticPlacementUntilRepair() async throws {
    _ = NSApplication.shared
    let system = FakeAppWindowSystem()
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.configuration.defaultTabbedPreset = .columns
    model.setActiveMode(.tabbed)
    try #require(await waitFor { model.activeTabbedState?.panes.count == 2 })
    let before = try #require(model.activeTabbedState)
    let divider = try #require(before.dividers(in: system.mainDisplay.visibleFrame).first)
    let id = system.windows[0].id
    model.performTabbed(.beginResize)
    model.performTabbed(.resize(divider.id, 0.65))
    system.failedFrameWriteNumbers[id] = [system.frameWriteCounts[id, default: 0] + 1]
    model.performTabbed(.cancelResize)
    #expect(model.statusMessage != nil)

    var added = system.windows[0]
    added.id = WindowID(rawValue: "after-cancel-failure")
    added.frame = BTRect(x: 100, y: 100, width: 500, height: 400)
    system.windows.append(added)
    let writes = system.frameWriteCounts
    system.eventHandler?(WindowSystemEvent(kind: .created, windowID: added.id, processIdentifier: added.processIdentifier))
    try #require(await waitFor { model.activeTabbedState?.windowIDs.contains(added.id) == true })
    #expect(system.frameWriteCounts == writes)
    #expect(system.windows.last?.frame == added.frame)

    system.focusedID = added.id
    system.eventHandler?(WindowSystemEvent(kind: .focused, windowID: added.id, processIdentifier: added.processIdentifier))
    try await Task.sleep(for: .milliseconds(400))
    #expect(system.frameWriteCounts == writes)

    model.performTabbed(.repair)
    #expect(await waitFor { system.windows.last?.frame != added.frame })
}

@Test @MainActor func tabbedDividerResizeUsesLiveFramesWithoutRestackingWindows() async throws {
    _ = NSApplication.shared
    let system = FakeAppWindowSystem()
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.configuration.defaultTabbedPreset = .columns
    model.setActiveMode(.tabbed)
    try #require(await waitFor { model.activeTabbedState?.panes.count == 2 })
    let before = try #require(model.activeTabbedState)
    let divider = try #require(before.dividers(in: system.mainDisplay.visibleFrame).first)
    let raiseCountBefore = system.raiseRequests.count

    model.performTabbed(.beginResize)
    model.performTabbed(.resize(divider.id, 0.65))
    try #require(await waitFor {
        model.activeTabbedState?.dividers(in: system.mainDisplay.visibleFrame).first?.ratio == 0.65
    })

    let resized = try #require(model.activeTabbedState)
    let expected = try resized.placements(in: system.mainDisplay.visibleFrame, windows: system.windows)
    #expect(expected.allSatisfy { placement in
        system.windows.first(where: { $0.id == placement.windowID })?.frame == placement.frame
    })
    #expect(system.raiseRequests.count == raiseCountBefore)

    model.performTabbed(.endResize)
}

@Test @MainActor func tabbedDividerBalanceAfterResizeReleaseWaitsForSettlementAndCanUndo() async throws {
    _ = NSApplication.shared
    let system = FakeAppWindowSystem()
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.configuration.defaultTabbedPreset = .columns
    model.setActiveMode(.tabbed)
    try #require(await waitFor { model.activeTabbedState?.panes.count == 2 })
    let divider = try #require(model.activeTabbedState?.dividers(in: system.mainDisplay.visibleFrame).first)

    model.performTabbed(.beginResize)
    model.performTabbed(.resize(divider.id, 0.65))
    model.performTabbed(.endResize)
    model.performTabbed(.balanceDivider(divider.id))

    try #require(await waitFor(timeout: .seconds(2)) {
        model.activeTabbedState?.dividers(in: system.mainDisplay.visibleFrame).first?.ratio == 0.5
    })
    model.performTabbed(.undo)
    #expect(await waitFor(timeout: .seconds(2)) {
        model.activeTabbedState?.dividers(in: system.mainDisplay.visibleFrame).first?.ratio == 0.65
    })
}

@Test @MainActor func cancellingTabbedLiveResizeRestoresTheStateAndRealWindowFrames() async throws {
    _ = NSApplication.shared
    let system = FakeAppWindowSystem()
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.configuration.defaultTabbedPreset = .columns
    model.setActiveMode(.tabbed)
    try #require(await waitFor { model.activeTabbedState?.panes.count == 2 })
    let before = try #require(model.activeTabbedState)
    let framesBefore = Dictionary(uniqueKeysWithValues: system.windows.map { ($0.id, $0.frame) })
    let divider = try #require(before.dividers(in: system.mainDisplay.visibleFrame).first)

    model.performTabbed(.beginResize)
    model.performTabbed(.resize(divider.id, 0.65))
    #expect(system.windows.contains { framesBefore[$0.id] != $0.frame })
    model.performTabbed(.cancelResize)

    #expect(model.activeTabbedState == before)
    #expect(system.windows.allSatisfy { framesBefore[$0.id] == $0.frame })
}

@Test @MainActor func rejectedTabbedLiveResizeSnapsBackAfterFinalSettlement() async throws {
    _ = NSApplication.shared
    let system = FakeAppWindowSystem()
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.configuration.defaultTabbedPreset = .columns
    model.setActiveMode(.tabbed)
    try #require(await waitFor { model.activeTabbedState?.panes.count == 2 })
    let before = try #require(model.activeTabbedState)
    let framesBefore = Dictionary(uniqueKeysWithValues: system.windows.map { ($0.id, $0.frame) })
    let divider = try #require(before.dividers(in: system.mainDisplay.visibleFrame).first)
    system.ignoredFrameWriteWindowIDs = Set(system.windows.map(\.id))
    model.statusMessage = nil

    model.performTabbed(.beginResize)
    model.performTabbed(.resize(divider.id, 0.65))
    model.performTabbed(.endResize)

    try #require(await waitFor(timeout: .seconds(2)) {
        model.statusMessage != nil && model.activeTabbedState == before
    })
    #expect(system.windows.allSatisfy { framesBefore[$0.id] == $0.frame })
}

@Test @MainActor func invalidTabbedParticipantAtReleaseRestoresStateAndFrames() async throws {
    _ = NSApplication.shared
    let system = FakeAppWindowSystem()
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.configuration.defaultTabbedPreset = .columns
    model.setActiveMode(.tabbed)
    try #require(await waitFor { model.activeTabbedState?.panes.count == 2 })
    let before = try #require(model.activeTabbedState)
    let framesBefore = Dictionary(uniqueKeysWithValues: system.windows.map { ($0.id, $0.frame) })
    let divider = try #require(before.dividers(in: system.mainDisplay.visibleFrame).first)

    model.performTabbed(.beginResize)
    model.performTabbed(.resize(divider.id, 0.65))
    #expect(system.windows.contains { framesBefore[$0.id] != $0.frame })
    system.windows[0].isHidden = true
    model.statusMessage = nil
    model.performTabbed(.endResize)

    #expect(model.statusMessage != nil)
    #expect(model.activeTabbedState == before)
    #expect(system.windows.allSatisfy { framesBefore[$0.id] == $0.frame })
}

@Test @MainActor func repairCurrentLayoutRestoresTabbedFramesAndPreservesGroups() async throws {
    _ = NSApplication.shared
    let system = FakeAppWindowSystem()
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.configuration.defaultTabbedPreset = .columns
    model.setActiveMode(.tabbed)
    try #require(await waitFor { model.activeTabbedState?.panes.count == 2 })
    let before = try #require(model.activeTabbedState)
    let frame = system.windows[0].frame
    system.windows[0].frame = BTRect(x: 100, y: 150, width: 600, height: 500)
    model.repairCurrentLayout()
    try #require(await waitFor { system.windows[0].frame == frame })
    #expect(model.activeLayoutMode == .tabbed)
    #expect(model.activeTabbedState == before)
}

@Test(arguments: [false, true], [600.0, 611.37]) @MainActor
func tabbedModelAdaptsReportedAndLearnedWidthsAndRetainsThemThroughUndo(learnWidth: Bool, minimumWidth: Double) async throws {
    _ = NSApplication.shared
    let system = FakeAppWindowSystem()
    system.windows[0].frame = BTRect(x: 50, y: 50, width: 800, height: 500)
    var wide = system.windows[0]
    wide.id = WindowID(rawValue: "wide")
    wide.processIdentifier = 43
    if learnWidth { system.enforcedMinimumWidths[wide.id] = minimumWidth }
    else { wide.constraints.minimumSize.width = minimumWidth }
    system.windows.append(wide)
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.configuration.defaultTabbedPreset = .columns
    model.setActiveMode(.tabbed)
    try #require(await waitFor { model.activeTabbedState?.windowIDs.count == 2 })
    #expect(system.windows.allSatisfy { abs($0.frame.size.width - minimumWidth) < 0.001 && $0.frame.minY == 34 })
    #expect(system.frameWriteCounts[wide.id] == (learnWidth ? 3 : 1))

    let right = try #require(model.activeTabbedState?.panes[1].id)
    model.performTabbed(.move(wide.id, pane: right, index: nil))
    try #require(await waitFor { model.activeTabbedState?.panes[1].tabs == [wide.id] })
    #expect(abs(system.windows[0].frame.size.width - (994 - minimumWidth)) < 0.001)
    #expect(abs(system.windows[1].frame.size.width - minimumWidth) < 0.001)
    let fitted = try #require(model.activeTabbedState)
    let frames = system.windows.map(\.frame)
    #expect(abs(fitted.frames(in: system.mainDisplay.visibleFrame)[right]!.size.width - system.windows[1].frame.size.width) < 0.001)
    model.performTabbed(.preset(.single))
    try #require(await waitFor { model.activeTabbedState?.panes.count == 1 })
    model.performTabbed(.undo)
    try #require(await waitFor { model.activeTabbedState?.panes.count == 2 })
    #expect(model.activeTabbedState == fitted)
    #expect(system.windows.map(\.frame) == frames)
}

@Test @MainActor func tabbedImpossibleWidthMovePreservesMembershipAndFrames() async throws {
    _ = NSApplication.shared
    let system = FakeAppWindowSystem()
    system.windows[0].constraints.minimumSize.width = 300
    var wide = system.windows[0]
    wide.id = WindowID(rawValue: "wide")
    wide.constraints.minimumSize.width = 800
    wide.frame.size.width = 800
    system.windows.append(wide)
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.configuration.defaultTabbedPreset = .columns
    model.setActiveMode(.tabbed)
    try #require(await waitFor { model.activeTabbedState?.windowIDs.count == 2 })
    let before = try #require(model.activeTabbedState)
    let frames = system.windows.map(\.frame)
    let writes = system.frameWriteCounts
    model.performTabbed(.move(wide.id, pane: before.panes[1].id, index: nil))
    #expect(model.statusMessage != nil)
    #expect(model.activeTabbedState == before)
    #expect(system.windows.map(\.frame) == frames)
    #expect(system.frameWriteCounts == writes)
}

@Test(arguments: [false, true]) @MainActor
func tabbedLearnedWidthFailureDoesNotCommitOrRetryDegradedRestoration(failRestore: Bool) async throws {
    _ = NSApplication.shared
    let system = FakeAppWindowSystem()
    let id = system.windows[0].id
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.setActiveMode(.tabbed)
    try #require(await waitFor { model.activeTabbedState != nil })
    let before = try #require(model.activeTabbedState)
    let frame = system.windows[0].frame
    let writes = system.frameWriteCounts[id, default: 0]
    // With an empty pane's 120-point minimum, 900 cannot fit this display.
    system.enforcedMinimumWidths[id] = failRestore ? 600 : 900
    if failRestore { system.failedFrameWriteNumbers[id] = [writes + 2] }
    model.statusMessage = nil
    model.performTabbed(.preset(.columns))
    try #require(await waitFor { model.statusMessage != nil })
    #expect(model.activeTabbedState == before)
    #expect(system.frameWriteCounts[id] == writes + 2)
    if !failRestore { #expect(system.windows[0].frame == frame) }
}

@Test @MainActor func tabbedHeightRefusalDoesNotTriggerWidthAdaptation() async throws {
    _ = NSApplication.shared
    let system = FakeAppWindowSystem()
    let id = system.windows[0].id
    system.windows[0].frame = BTRect(x: 0, y: 0, width: 800, height: 800)
    system.enforcedMinimumWidths[id] = 600
    system.enforcedMinimumHeights[id] = 780
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.configuration.singleWindowPlacement = nil
    let before = system.windows[0].frame
    let writes = system.frameWriteCounts[id, default: 0]
    model.configuration.defaultTabbedPreset = .columns
    model.statusMessage = nil
    model.setActiveMode(.tabbed)
    try #require(await waitFor { model.statusMessage != nil })
    #expect(model.activeTabbedState == nil)
    #expect(system.windows[0].frame == before)
    #expect(system.frameWriteCounts[id] == writes + 2)
    #expect(system.windows[0].constraints.minimumSize.width < 600)
}

@Test @MainActor func tabbedFailedUndoCanBeRetried() async throws {
    _ = NSApplication.shared
    let system = FakeAppWindowSystem()
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.configuration.defaultTabbedPreset = .columns
    model.setActiveMode(.tabbed)
    try #require(await waitFor { model.activeTabbedState?.panes.count == 2 })
    model.performTabbed(.preset(.single))
    try #require(await waitFor { model.activeTabbedState?.panes.count == 1 })

    model.statusMessage = nil
    system.ignoredFrameWriteWindowIDs = [system.windows[0].id]
    model.performTabbed(.undo)
    try #require(await waitFor { model.statusMessage != nil })
    #expect(model.activeTabbedState?.panes.count == 1)

    system.ignoredFrameWriteWindowIDs = []
    model.performTabbed(.undo)
    #expect(await waitFor { model.activeTabbedState?.panes.count == 2 })
}

@Test @MainActor func tabbedModelSupportsEmptyPanePlacementAndNativeRestoration() async throws {
    _ = NSApplication.shared
    let system = FakeAppWindowSystem()
    let first = system.windows[0]
    let second = WindowSnapshot(id: WindowID(rawValue: "second"), processIdentifier: 43,
                                frame: BTRect(x: 10, y: 10, width: 400, height: 300), displayID: first.displayID)
    system.windows.append(second)
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.configuration.defaultTabbedPreset = .columns
    model.setActiveMode(.tabbed)
    try #require(await waitFor { model.activeTabbedState?.panes.count == 2 })
    let state = try #require(model.activeTabbedState)
    #expect(state.panes[0].tabs.count == 2)
    #expect(state.panes[1].tabs.isEmpty)
    #expect(system.windows[0].frame == system.windows[1].frame)
    model.performTabbed(.activate(state.panes[1].id))
    let third = WindowSnapshot(id: WindowID(rawValue: "third"), processIdentifier: 44,
                               frame: BTRect(x: 10, y: 10, width: 400, height: 300), displayID: first.displayID)
    system.windows.append(third)
    system.eventHandler?(WindowSystemEvent(kind: .created, windowID: third.id, processIdentifier: 44))
    try #require(await waitFor { model.activeTabbedState?.panes[1].selected == third.id })
    #expect(model.activeTabbedState?.panes[1].tabs == [third.id])
    let thirdTabbedFrame = system.windows[2].frame
    model.setActiveMode(.manual)
    try #require(await waitFor { model.activeLayoutMode == .manual })
    #expect(system.windows[0].frame == first.frame)
    #expect(system.windows[1].frame == second.frame)
    #expect(system.windows[2].frame == thirdTabbedFrame)
    model.setActiveMode(.tabbed)
    try #require(await waitFor { system.windows[0].frame.minY == 34 })
    #expect(model.activeTabbedState?.panes[1].tabs == [third.id])
}

@Test @MainActor func tabbedModelKeepsNativeSpaceSessionsSeparate() async throws {
    _ = NSApplication.shared
    let system = FakeAppWindowSystem()
    let display = system.mainDisplay.id
    let a = NativeSpaceID(rawValue: 1), b = NativeSpaceID(rawValue: 2)
    system.desktopObservation = NativeDesktopObservation(currentSpaceByDisplay: [display: a], knownSpacesByDisplay: [display: [a, b]], windowMembership: [system.windows[0].id: [a]])
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.configuration.singleWindowPlacement = nil
    model.setActiveMode(.tabbed)
    try #require(await waitFor { model.activeTabbedState != nil })
    let originalPane = model.activeTabbedState?.panes[0].id
    let firstWindows = system.windows
    model.installWorkspaceTriggers()
    system.desktopObservation?.currentSpaceByDisplay[display] = b
    system.windows = []
    NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
    try #require(await waitFor { model.activeLayoutMode == .manual })
    system.desktopObservation?.currentSpaceByDisplay[display] = a
    system.windows = firstWindows
    NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
    try #require(await waitFor { model.activeLayoutMode == .tabbed && model.activeTabbedState?.panes[0].id == originalPane })
}

@Test(arguments: [false, true]) @MainActor
func nativeSpaceChangeCancelsActiveTabbedResizeBeforeReturning(destroyedDuringResize: Bool) async throws {
    _ = NSApplication.shared
    let system = FakeAppWindowSystem()
    let display = system.mainDisplay.id
    let firstSpace = NativeSpaceID(rawValue: 1)
    let secondSpace = NativeSpaceID(rawValue: 2)
    var second = system.windows[0]
    second.id = WindowID(rawValue: "second")
    second.processIdentifier = 43
    system.windows.append(second)
    system.desktopObservation = NativeDesktopObservation(
        currentSpaceByDisplay: [display: firstSpace],
        knownSpacesByDisplay: [display: [firstSpace, secondSpace]],
        windowMembership: Dictionary(uniqueKeysWithValues: system.windows.map { ($0.id, [firstSpace]) })
    )
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.configuration.singleWindowPlacement = nil
    model.setActiveMode(.tabbed)
    try #require(await waitFor { model.activeTabbedState?.panes.count == 1 })
    let singlePaneState = try #require(model.activeTabbedState)
    model.performTabbed(.preset(.columns))
    try #require(await waitFor { model.activeTabbedState?.panes.count == 2 })
    let baselineState = try #require(model.activeTabbedState)
    let baselineFrames = Dictionary(uniqueKeysWithValues: system.windows.map { ($0.id, $0.frame) })
    var expectedReturnState = baselineState
    var expectedReturnFrames = baselineFrames
    let divider = try #require(baselineState.dividers(in: system.mainDisplay.visibleFrame).first)

    model.performTabbed(.beginResize)
    model.performTabbed(.resize(divider.id, 0.65))
    try #require(await waitFor { model.activeTabbedState?.dividers(in: system.mainDisplay.visibleFrame).first?.ratio == 0.65 })
    #expect(model.activeTabbedState != baselineState)
    let writesAfterResize = system.frameWriteCounts

    if destroyedDuringResize {
        system.windows.removeAll { $0.id == second.id }
        system.desktopObservation?.windowMembership.removeValue(forKey: second.id)
        system.eventHandler?(WindowSystemEvent(
            kind: .destroyed,
            windowID: second.id,
            processIdentifier: second.processIdentifier
        ))
        expectedReturnState.removeClosedWindow(second.id)
        expectedReturnFrames.removeValue(forKey: second.id)
    }

    model.installWorkspaceTriggers()
    system.desktopObservation?.currentSpaceByDisplay[display] = secondSpace
    let departureSweep = system.completeSweepCount
    NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
    try #require(await waitFor {
        model.activeLayoutMode == .manual && system.completeSweepCount >= departureSweep + 2
    })
    #expect(system.frameWriteCounts == writesAfterResize)

    system.desktopObservation?.currentSpaceByDisplay[display] = firstSpace
    NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
    try #require(await waitFor(timeout: .seconds(2)) {
        model.activeLayoutMode == .tabbed
            && model.activeTabbedState == expectedReturnState
            && Dictionary(uniqueKeysWithValues: system.windows.map { ($0.id, $0.frame) }) == expectedReturnFrames
    })

    model.performTabbed(.undo)
    try #require(await waitFor { model.activeTabbedState?.panes.count == 1 })
    var expectedUndoState = singlePaneState
    if destroyedDuringResize { expectedUndoState.removeClosedWindow(second.id) }
    #expect(model.activeTabbedState == expectedUndoState)
}

@Test @MainActor func tabbedModelFloatCanBeReattachedAndPresetUndoRestoresAssignments() async throws {
    _ = NSApplication.shared
    let system = FakeAppWindowSystem()
    let first = system.windows[0]
    system.windows.append(WindowSnapshot(id: WindowID(rawValue: "second"), processIdentifier: 43,
                                        frame: first.frame, displayID: first.displayID))
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.setActiveMode(.tabbed)
    try #require(await waitFor { model.activeTabbedState?.windowIDs.count == 2 })
    model.performTabbed(.float(first.id))
    try #require(await waitFor { model.activeTabbedState?.floatingWindowIDs.contains(first.id) == true })
    #expect(system.focusedID == first.id)
    #expect(system.windows[0].frame == first.frame)
    let pane = try #require(model.activeTabbedState?.panes[0].id)
    model.performTabbed(.move(first.id, pane: pane, index: nil))
    try #require(await waitFor { model.activeTabbedState?.windowIDs.count == 2 })
    model.performTabbed(.preset(.columns))
    try #require(await waitFor { model.activeTabbedState?.panes.count == 2 })
    model.performTabbed(.undo)
    try #require(await waitFor { model.activeTabbedState?.panes.count == 1 })
    #expect(model.activeTabbedState?.panes[0].id == pane)
    #expect(model.activeTabbedState?.windowIDs.count == 2)
}

@Test @MainActor func destroyedFloatingTabbedWindowIsRemovedFromStateAndUndo() async throws {
    _ = NSApplication.shared
    let system = FakeAppWindowSystem()
    let first = system.windows[0]
    var second = first
    second.id = WindowID(rawValue: "second")
    system.windows.append(second)
    let model = makeModel(system: system)
    defer { model.shutdown() }

    model.setActiveMode(.tabbed)
    try #require(await waitFor { model.activeTabbedState?.windowIDs.count == 2 })
    model.performTabbed(.float(first.id))
    try #require(await waitFor { model.activeTabbedState?.floatingWindowIDs.contains(first.id) == true })
    model.performTabbed(.preset(.columns))
    try #require(await waitFor { model.activeTabbedState?.panes.count == 2 })

    system.windows.removeAll { $0.id == first.id }
    system.eventHandler?(WindowSystemEvent(
        kind: .destroyed,
        windowID: first.id,
        processIdentifier: first.processIdentifier
    ))

    try #require(await waitFor { model.activeTabbedState?.floatingWindowIDs.contains(first.id) == false })
    model.performTabbed(.undo)
    try #require(await waitFor { model.activeTabbedState?.panes.count == 1 })
    #expect(model.activeTabbedState?.windowIDs.contains(first.id) == false)
    #expect(model.activeTabbedState?.floatingWindowIDs.contains(first.id) == false)
}

@Test @MainActor func tabbedEmptyActivationDoesNotCaptureNewWindowAsPreexistingBaseline() async throws {
    _ = NSApplication.shared
    let system = FakeAppWindowSystem()
    let window = system.windows[0]
    system.windows = []
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.setActiveMode(.tabbed)
    try #require(await waitFor { model.activeTabbedState != nil })
    system.windows = [window]
    system.eventHandler?(WindowSystemEvent(kind: .created, windowID: window.id, processIdentifier: window.processIdentifier))
    try #require(await waitFor { model.activeTabbedState?.windowIDs.count == 1 })
    let frame = system.windows[0].frame
    model.configuration.singleWindowPlacement = nil
    model.setActiveMode(.manual)
    try #require(await waitFor { model.activeLayoutMode == .manual })
    #expect(system.windows[0].frame == frame)
}
