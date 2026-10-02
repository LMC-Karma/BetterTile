import AppKit
import BetterTileCore
import BetterTileMacOS
import Testing
@testable import BetterTileApp

/// Two columns: `focused` selected over hidden `tab-1` on the left, `tab-3`
/// selected over hidden `tab-2` on the right.
@MainActor private func makeTwoTabbedColumns(_ system: FakeAppWindowSystem) async throws -> BetterTileModel {
    _ = NSApplication.shared
    addTabbedWindows(3, to: system)
    let model = makeModel(system: system)
    model.configuration.defaultTabbedPreset = .columns
    model.setActiveMode(.tabbed)
    try #require(await waitFor { model.activeTabbedState?.windowIDs.count == 4 })
    let right = try #require(model.activeTabbedState?.panes[1].id)
    for id in [system.windows[2].id, system.windows[3].id] {
        model.performTabbed(.move(id, pane: right, index: nil))
        try #require(await waitFor { model.activeTabbedState?.panes[1].selected == id })
    }
    let left = system.windows[0].id
    model.performTabbed(.select(left))
    try #require(await waitFor { model.activeTabbedState?.activeWindowID == left })
    try await Task.sleep(for: .milliseconds(400)) // Let focus refreshes settle.
    return model
}

private func stackEntry(_ window: WindowSnapshot) -> TabbedStackEntry {
    TabbedStackEntry(windowID: window.id, frame: window.frame)
}

@Test(arguments: [false, true]) @MainActor
func activationWithBetterTileInFrontNeverSelectsOrActivatesATab(staleFocusIsHidden: Bool) async throws {
    let system = FakeAppWindowSystem()
    let model = try await makeTwoTabbedColumns(system)
    defer { model.shutdown() }
    let state = try #require(model.activeTabbedState)
    // BetterTile's Settings is in front. focusedWindow() skips BetterTile and
    // reports the last managed app's window instead.
    system.frontmostOverride = 999
    system.focusedID = staleFocusIsHidden ? system.windows[1].id : system.windows[0].id
    let raises = system.raiseRequests.count

    model.handleApplicationActivation()
    try await Task.sleep(for: .milliseconds(500))
    #expect(system.raiseRequests.count == raises)
    #expect(model.activeTabbedState == state)
}

@Test(arguments: [false, true]) @MainActor
func activationRaisesSelectionsAboveAllInactiveTabs(failOrdering: Bool) async throws {
    let system = FakeAppWindowSystem()
    let model = try await makeTwoTabbedColumns(system)
    defer { model.shutdown() }
    // Cmd-Tab to the left tab's app brought its hidden right-hand tab over
    // that pane's selected tab.
    system.windows[2].processIdentifier = system.windows[0].processIdentifier
    system.stack = [2, 0, 3, 1].map { stackEntry(system.windows[$0]) }
    system.focusedID = system.windows[0].id
    let state = try #require(model.activeTabbedState)
    let frames = system.windows.map(\.frame)
    let writes = system.frameWriteCounts
    let raises = system.raiseRequests.count
    if failOrdering { system.failingNextRaiseWindowID = system.windows[3].id }

    model.handleApplicationActivation()
    // An AX focus event after activation must not discard the repair.
    system.eventHandler?(WindowSystemEvent(kind: .focused, windowID: system.windows[0].id,
                                          processIdentifier: system.windows[0].processIdentifier))
    if failOrdering {
        #expect(await waitFor(timeout: .seconds(1)) { model.statusMessage != nil })
        // Ordering is best effort. Later safe raises still run when one
        // selected tab refuses, but no verified curtain anchor is returned.
        #expect(system.raiseRequests.dropFirst(raises).map(\.0) == [system.windows[0].id])
    } else {
        #expect(await waitFor(timeout: .seconds(1)) { system.raiseRequests.count > raises })
        try await Task.sleep(for: .milliseconds(200))
        #expect(system.raiseRequests.dropFirst(raises).map(\.0) == [system.windows[3].id, system.windows[0].id])
        #expect(!system.raiseRequests.dropFirst(raises).contains { $0.1 })
        #expect(system.stack?.map(\.windowID) == [0, 3, 2, 1].map { system.windows[$0].id })
    }
    #expect(system.focusedID == system.windows[0].id)
    #expect(system.windows.map(\.frame) == frames)
    #expect(system.frameWriteCounts == writes)
    #expect(model.activeTabbedState == state)
}

@Test(arguments: [false, true]) @MainActor
func stackingRepairKeepsAWindowInFrontOrLeavesAnUnreadableOneAlone(readable: Bool) async throws {
    let system = FakeAppWindowSystem()
    let model = try await makeTwoTabbedColumns(system)
    defer { model.shutdown() }
    let right = system.windows[3].frame
    let floating = WindowID(rawValue: "ignored-floating")
    // A window outside Tabbed was in front of the right pane before a hidden
    // tab came forward.
    let front = TabbedStackEntry(windowID: readable ? floating : nil,
                                 frame: BTRect(x: right.minX + 50, y: right.minY + 50, width: 200, height: 150))
    system.stack = [stackEntry(system.windows[2]), front] + [3, 0, 1].map { stackEntry(system.windows[$0]) }
    system.focusedID = system.windows[0].id
    let raises = system.raiseRequests.count

    model.handleApplicationActivation()
    try await Task.sleep(for: .milliseconds(500))
    let raised = system.raiseRequests.dropFirst(raises)
    #expect(raised.map(\.0) == (readable ? [system.windows[0].id, system.windows[3].id, floating] : []))
    #expect(!raised.contains { $0.1 })
}

@Test(arguments: [false, true]) @MainActor
func activationRepairsHiddenTabsOnAnotherTabbedDisplay(focusedDisplayTabbed: Bool) async throws {
    _ = NSApplication.shared
    let system = FakeAppWindowSystem()
    addTabbedWindows(2, to: system)
    let other = DisplayID(rawValue: "other")
    system.availableDisplays.append(DisplaySnapshot(id: other,
        frame: BTRect(x: 1000, y: 0, width: 1000, height: 800),
        visibleFrame: BTRect(x: 1000, y: 0, width: 1000, height: 800)))
    for index in 1...2 { system.windows[index].displayID = other }
    system.windows[1].processIdentifier = system.windows[0].processIdentifier
    let model = makeModel(system: system)
    defer { model.shutdown() }
    if focusedDisplayTabbed {
        model.setActiveMode(.tabbed)
        try #require(await waitFor { model.activeTabbedState?.windowIDs == [system.windows[0].id] })
    }
    system.focusedID = system.windows[2].id
    model.setActiveMode(.tabbed)
    try #require(await waitFor { model.activeTabbedState?.windowIDs.count == 2 })
    try #require(model.activeTabbedState?.activeWindowID == system.windows[2].id)
    try await Task.sleep(for: .milliseconds(350)) // Let both entry placements settle.
    let frames = system.windows.map(\.frame)
    let writes = system.frameWriteCounts
    let raises = system.raiseRequests.count

    try await Task.sleep(for: .milliseconds(100))
    #expect(system.raiseRequests.count == raises) // An unchanged desktop settles once.

    // Cmd-Tab to the first window's app also raised its hidden tab on the
    // other display.
    system.stack = [1, 0, 2].map { stackEntry(system.windows[$0]) }
    system.focusedID = system.windows[0].id
    model.handleApplicationActivation()
    #expect(await waitFor(timeout: .seconds(1)) { system.raiseRequests.count > raises })
    #expect(system.raiseRequests.dropFirst(raises).map(\.0) == [system.windows[2].id])
    #expect(!system.raiseRequests.dropFirst(raises).contains { $0.1 })
    #expect(system.focusedID == system.windows[0].id)
    #expect(system.windows.map(\.frame) == frames)
    #expect(system.frameWriteCounts == writes)
}

@Test(arguments: [false, true]) @MainActor
func tabSelectionPreservesFloatingOrderWhenRepairingTheSharedCurtain(readableOrder: Bool) async throws {
    let system = FakeAppWindowSystem()
    let model = try await makeTwoTabbedColumns(system)
    defer { model.shutdown() }
    // The left hidden tab shares an app with the right selected tab, and a
    // floating window is in front of the right pane.
    system.windows[1].processIdentifier = system.windows[3].processIdentifier
    let right = system.windows[3].frame
    let floating = TabbedStackEntry(windowID: WindowID(rawValue: "floating"),
                                    frame: BTRect(x: right.minX + 50, y: right.minY + 50, width: 200, height: 150))
    if readableOrder { system.stack = [floating] + [0, 3, 1, 2].map { stackEntry(system.windows[$0]) } }
    let raises = system.raiseRequests.count

    let target = system.windows[1].id
    model.performTabbed(.select(target))
    #expect(await waitFor(timeout: .seconds(1)) { model.activeTabbedState?.activeWindowID == target })
    try await Task.sleep(for: .milliseconds(600)) // The stacking check follows the selection.
    let raised = Set(system.raiseRequests.dropFirst(raises).map(\.0))
    // The formerly selected left tab is now inactive above the right
    // selection. Repair puts both selected tabs above it, preserving floating.
    #expect(raised == (readableOrder ? [target, system.windows[3].id, floating.windowID!]
                                    : [target, system.windows[3].id]))
}

@Test(arguments: [false, true]) @MainActor
func tabbedCurtainsResolveOnlySelectedWindowsAfterPlacementAndFocus(failSelection: Bool) async throws {
    _ = NSApplication.shared
    let system = FakeAppWindowSystem()
    addTabbedWindows(1, to: system)
    // Keep the test panels off-screen; no desktop capture or live AX.
    system.availableDisplays[0].frame.origin.x = 12000
    system.availableDisplays[0].visibleFrame.origin.x = 12000
    for index in system.windows.indices { system.windows[index].frame.origin.x += 12000 }
    let store = ConfigurationStore(fileURL: URL(filePath: "/private/tmp/BetterTileAppTests-\(UUID().uuidString)/configuration.json"))
    let model = BetterTileModel(store: store, system: system, startRuntime: false, presentsTabbedChrome: true)
    defer { model.shutdown() }
    model.setActiveMode(.tabbed)
    try #require(await waitFor { model.activeTabbedState?.windowIDs.count == 2 })
    #expect(system.windowNumberRequests.last == [system.windows[0].id])
    let hidden = system.windows[1].id
    let initialRequests = system.windowNumberRequests.count
    if failSelection { system.failingNextRaiseWindowID = hidden }
    model.performTabbed(.select(hidden))
    let shown = failSelection ? system.windows[0].id : hidden
    if failSelection { try #require(await waitFor { model.statusMessage != nil }) }
    else { try #require(await waitFor { model.activeTabbedState?.activeWindowID == shown }) }
    #expect(system.windowNumberRequests.count > initialRequests) // Rollback reorders curtains too.
    #expect(system.windowNumberRequests.last == [shown])
    let requests = system.windowNumberRequests.count
    let status = model.statusMessage
    model.handleApplicationActivation()
    #expect(await waitFor(timeout: .seconds(1)) { system.windowNumberRequests.count > requests })
    #expect(system.windowNumberRequests.last == [shown])
    #expect(model.statusMessage == status) // Missing IDs add no error.
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
    // Selecting swaps which window a pane shows; pane geometry stays put.
    #expect(model.activeTabbedState?.frames(in: system.mainDisplay.visibleFrame) == previous.frames(in: system.mainDisplay.visibleFrame))
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
    // Both tabs share one pane below the strip. The hidden wide tab does not
    // widen the pane: only the selected tab's minimum counts.
    #expect(system.windows.allSatisfy { $0.frame.minY == 34 })
    let shown = try #require(model.activeTabbedState?.panes[0].selected)
    #expect(shown != wide.id)
    #expect(abs((system.windows.first { $0.id == shown }?.frame.size.width ?? 0) - 497) < 0.001)

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

@Test @MainActor func tabbedImpossibleHeightRefusalLearnsBothAxesAndPreservesFrames() async throws {
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
    #expect(system.windows[0].constraints.minimumSize.width == 600)
    #expect(system.windows[0].constraints.minimumSize.height == 780)
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

@MainActor private func tabbedWindows(_ system: FakeAppWindowSystem, _ names: [String]) -> [WindowSnapshot] {
    let base = system.windows[0]
    system.windows = names.enumerated().map { index, name in
        var window = base
        window.id = WindowID(rawValue: name)
        window.processIdentifier = pid_t(100 + index)
        window.frame = BTRect(x: 20 * Double(index), y: 20, width: 500, height: 400)
        return window
    }
    return system.windows
}

@Test @MainActor func tabbedHalfScreenSplitIgnoresAHiddenTabsMinimum() async throws {
    // Reported failure: a tab dragged to half the screen said the layout
    // could not apply because a hidden wide tab counted.
    _ = NSApplication.shared
    let system = FakeAppWindowSystem()
    var windows = tabbedWindows(system, ["a", "b", "wide"])
    windows[2].constraints.minimumSize.width = 900
    system.windows = windows
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.setActiveMode(.tabbed)
    try #require(await waitFor { model.activeTabbedState?.windowIDs.count == 3 })
    let state = try #require(model.activeTabbedState)
    let b = WindowID(rawValue: "b")
    if state.activeWindowID == WindowID(rawValue: "wide") { model.performTabbed(.select(WindowID(rawValue: "a"))) }
    try #require(await waitFor { model.activeTabbedState?.activeWindowID != WindowID(rawValue: "wide") })
    model.statusMessage = nil
    model.performTabbed(.split(b, pane: state.panes[0].id, edge: .right))
    try #require(await waitFor { model.activeTabbedState?.panes.count == 2 })
    #expect(model.statusMessage == nil)
    let frames = Dictionary(uniqueKeysWithValues: system.windows.map { ($0.id, $0.frame) })
    #expect(abs(frames[b]!.size.width - 497) < 1)
    #expect(frames[b]!.minX > 500)
}

@Test @MainActor func tabbedWindowDragsUseBentoAndCenterDropsAddATab() async throws {
    _ = NSApplication.shared
    let system = FakeAppWindowSystem()
    _ = tabbedWindows(system, ["a", "b", "c"])
    let a = WindowID(rawValue: "a"), b = WindowID(rawValue: "b"), c = WindowID(rawValue: "c")
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.configuration.defaultTabbedPreset = .columns
    model.setActiveMode(.tabbed)
    try #require(await waitFor { model.activeTabbedState?.windowIDs.count == 3 })
    let right = try #require(model.activeTabbedState?.panes[1].id)
    model.performTabbed(.move(b, pane: right, index: nil))
    try #require(await waitFor { model.activeTabbedState?.panes[1].tabs == [b] })
    let display = system.mainDisplay.id

    // Tear one tab out of the left group and drop it on the right pane's edge:
    // Bento splits, and the rest of the group stays where it was.
    let left = try #require(model.activeTabbedState?.panes[0])
    let torn = try #require(left.selected)
    let remaining = try #require(left.tabs.first { $0 != torn })
    #expect(model.completeBentoDrag(displayID: display, sourceID: torn, outcome: .insert(targetWindowID: b, edge: .bottom)))
    try #require(await waitFor { model.activeTabbedState?.panes.count == 3 })
    #expect(model.activeTabbedState?.panes[0].tabs == [remaining])
    #expect(model.activeTabbedState?.panes.first { $0.tabs == [torn] } != nil)
    #expect(model.activeTabbedState?.layout.metrics.contentTopInset == TabbedLayoutState.headerHeight)

    // A center drop adds the window to that pane as a tab.
    #expect(model.completeBentoDrag(displayID: display, sourceID: torn, outcome: .swap(targetWindowID: b)))
    try #require(await waitFor { model.activeTabbedState?.pane(containing: b)?.tabs.contains(torn) == true })
    #expect(model.activeTabbedState?.pane(containing: b)?.selected == torn)
    let bFrame = system.windows.first { $0.id == b }?.frame
    #expect(await waitFor { system.windows.first { $0.id == torn }?.frame == bFrame })

    // A torn tab dropped nowhere returns to its group.
    let group = try #require(model.activeTabbedState?.pane(containing: b))
    #expect(model.completeBentoDrag(displayID: display, sourceID: torn, outcome: .restore))
    try #require(await waitFor { model.activeTabbedState?.pane(containing: torn)?.id == group.id })
    _ = a; _ = c
}

@Test @MainActor func tabbedPointerDropsRecordUndo() async throws {
    _ = NSApplication.shared
    let system = FakeAppWindowSystem()
    _ = tabbedWindows(system, ["a", "b", "c"])
    let b = WindowID(rawValue: "b")
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.configuration.defaultTabbedPreset = .columns
    model.setActiveMode(.tabbed)
    try #require(await waitFor { model.activeTabbedState?.windowIDs.count == 3 })
    let right = try #require(model.activeTabbedState?.panes[1].id)
    model.performTabbed(.move(b, pane: right, index: nil))
    try #require(await waitFor { model.activeTabbedState?.panes[1].tabs == [b] })
    let before = try #require(model.activeTabbedState)
    let torn = try #require(before.panes[0].selected)
    // An edge drop is a Bento split; Undo returns the torn tab to its group.
    #expect(model.completeBentoDrag(displayID: system.mainDisplay.id, sourceID: torn,
                                    outcome: .insert(targetWindowID: b, edge: .bottom)))
    try #require(await waitFor { model.activeTabbedState?.panes.count == 3 })
    try #require(await waitFor { model.activeTabbedState?.pane(containing: torn)?.tabs == [torn] })
    model.performTabbed(.undo)
    #expect(await waitFor { model.activeTabbedState?.pane(containing: torn)?.id == before.panes[0].id })
}

@Test func leavingTabbedForBentoRestoresPlainBentoMetrics() {
    var state = TabbedLayoutState(preset: .columns)
    state.reconcile(windowIDs: [WindowID(rawValue: "a")], removed: [], focused: nil)
    let bento = state.unstacked(in: BTRect(x: 0, y: 0, width: 1000, height: 800))
    #expect(bento.metrics.contentTopInset == 0)
    #expect(bento.metrics.vacantMinimumSize == BTSize(width: 0, height: 0))
}

@MainActor private func addTabbedWindows(_ count: Int, to system: FakeAppWindowSystem) {
    for index in 1...count {
        var window = system.windows[0]
        window.id = WindowID(rawValue: "tab-\(index)")
        window.processIdentifier += Int32(index)
        system.windows.append(window)
    }
}

@MainActor private func sendResize(_ id: WindowID, to frame: BTRect, in system: FakeAppWindowSystem) throws {
    let index = try #require(system.windows.firstIndex { $0.id == id })
    system.windows[index].frame = frame
    system.eventHandler?(WindowSystemEvent(kind: .resized, windowID: id, processIdentifier: system.windows[index].processIdentifier))
}

@MainActor private func frame(_ id: WindowID, in system: FakeAppWindowSystem) -> BTRect? {
    system.windows.first { $0.id == id }?.frame
}

@Test(arguments: [false, true]) @MainActor
func tabbedOnePaneEdgeResizeSnapsBackAfterRelease(holdButton: Bool) async throws {
    _ = NSApplication.shared
    let system = FakeAppWindowSystem()
    addTabbedWindows(1, to: system)
    let model = makeModel(system: system)
    defer { model.shutdown() }
    var pressed = false
    model.primaryButtonIsPressed = { pressed }
    model.setActiveMode(.tabbed)
    try #require(await waitFor { model.activeTabbedState?.windowIDs.count == 2 })
    let state = try #require(model.activeTabbedState)
    let pane = try #require(state.frames(in: system.mainDisplay.visibleFrame)[state.panes[0].id])
    let content = TabbedLayoutState.contentFrame(pane)
    try #require(await waitFor { system.windows.allSatisfy { $0.frame == content } })
    try await Task.sleep(for: .milliseconds(350))
    let selected = try #require(state.panes[0].selected)
    let hidden = try #require(state.panes[0].tabs.first { $0 != selected })
    let shrunk = BTRect(x: content.minX, y: content.minY, width: content.size.width - 300, height: content.size.height)

    pressed = holdButton
    try sendResize(selected, to: shrunk, in: system)
    if holdButton {
        // The edge is still held: BetterTile must not fight the drag.
        try await Task.sleep(for: .milliseconds(400))
        #expect(frame(selected, in: system) == shrunk)
        pressed = false
    }
    #expect(await waitFor(timeout: .seconds(2)) { frame(selected, in: system) == content })
    #expect(frame(hidden, in: system) == content)
    #expect(model.activeTabbedState?.panes == state.panes)
    #expect(model.activeTabbedState?.frames(in: system.mainDisplay.visibleFrame) == state.frames(in: system.mainDisplay.visibleFrame))
}

@Test(arguments: [nil, 450.0] as [Double?]) @MainActor
func tabbedSharedEdgeResizeMovesThePaneItsHiddenTabsAndItsNeighbor(neighborMinimum: Double?) async throws {
    _ = NSApplication.shared
    let system = FakeAppWindowSystem()
    addTabbedWindows(2, to: system)
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.configuration.defaultTabbedPreset = .columns
    model.setActiveMode(.tabbed)
    try #require(await waitFor { model.activeTabbedState?.windowIDs.count == 3 })
    let rightPane = try #require(model.activeTabbedState?.panes[1].id)
    let neighbor = system.windows[2].id
    model.performTabbed(.move(neighbor, pane: rightPane, index: nil))
    try #require(await waitFor { model.activeTabbedState?.panes[1].selected == neighbor })
    let bounds = system.mainDisplay.visibleFrame
    let state = try #require(model.activeTabbedState)
    let leftPane = state.panes[0]
    let selected = try #require(leftPane.selected)
    let hidden = try #require(leftPane.tabs.first { $0 != selected })
    let left = TabbedLayoutState.contentFrame(try #require(state.frames(in: bounds)[leftPane.id]))
    try #require(await waitFor { frame(selected, in: system) == left && frame(hidden, in: system) == left })
    try await Task.sleep(for: .milliseconds(350))
    if let neighborMinimum {
        let index = try #require(system.windows.firstIndex { $0.id == neighbor })
        system.windows[index].constraints.minimumSize.width = neighborMinimum
    }

    // The user drags the shared edge 150 points into the right pane.
    try sendResize(selected, to: BTRect(x: left.minX, y: left.minY, width: left.size.width + 150, height: left.size.height), in: system)
    let edge = neighborMinimum.map { bounds.maxX - $0 - TabbedLayoutState.gap } ?? left.maxX + 150
    #expect(await waitFor(timeout: .seconds(2)) {
        guard let current = frame(selected, in: system), let behind = frame(hidden, in: system),
              let next = frame(neighbor, in: system) else { return false }
        return abs(current.maxX - edge) < 1 && abs(behind.maxX - edge) < 1
            && abs(next.minX - (edge + TabbedLayoutState.gap)) < 1
    })
    let adopted = try #require(model.activeTabbedState)
    #expect(try abs(#require(adopted.frames(in: bounds)[leftPane.id]).maxX - edge) < 1)
    #expect(adopted.panes.map(\.tabs) == state.panes.map(\.tabs))

    model.performTabbed(.undo)
    #expect(await waitFor(timeout: .seconds(2)) {
        frame(selected, in: system)?.approximatelyEquals(left, tolerance: 1) == true
    })
}

@Test(arguments: [false, true], [false, true]) @MainActor
func tabSelectionRefitsForReportedMinimumInBothAxes(height: Bool, learned: Bool) async throws {
    _ = NSApplication.shared
    let system = FakeAppWindowSystem()
    var other = system.windows[0]
    other.id = WindowID(rawValue: "larger-tab")
    system.windows.append(other)
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.configuration.defaultTabbedPreset = height ? .rows : .columns
    model.setActiveMode(.tabbed)
    try #require(await waitFor { model.activeTabbedState?.windowIDs.count == 2 })
    let target = other.id
    if learned {
        if height { system.enforcedMinimumHeights[target] = 450 }
        else { system.enforcedMinimumWidths[target] = 600 }
        system.windows[1].frame.size = BTSize(width: 800, height: 600)
    } else if height { system.windows[1].constraints.minimumSize.height = 450 }
    else { system.windows[1].constraints.minimumSize.width = 600 }
    model.performTabbed(.select(target))
    try #require(await waitFor { model.activeTabbedState?.activeWindowID == target })
    #expect(height ? system.windows[1].frame.size.height >= 450 : system.windows[1].frame.size.width >= 600)
    #expect(model.statusMessage == nil)
}

@Test @MainActor func repairTabbedLearnsHeightAndRestoresDisplacedWindow() async throws {
    _ = NSApplication.shared
    let system = FakeAppWindowSystem()
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.configuration.defaultTabbedPreset = .rows
    model.setActiveMode(.tabbed)
    try #require(await waitFor { model.activeTabbedState != nil && system.windows[0].frame.minY == 34 })
    let id = system.windows[0].id
    system.windows[0].frame = BTRect(x: 100, y: 50, width: 800, height: 600)
    system.enforcedMinimumHeights[id] = 450
    model.repairCurrentLayout()
    try #require(await waitFor { system.windows[0].frame.minX == 0 && system.windows[0].constraints.minimumSize.height >= 450 })
    #expect(model.statusMessage == nil)
    #expect(system.windows[0].constraints.minimumSize.height >= 450)
}

@Test(arguments: [false, true]) @MainActor
func impossibleTabSelectionPreservesSelectionAndFrames(height: Bool) async throws {
    _ = NSApplication.shared
    let system = FakeAppWindowSystem()
    var other = system.windows[0]
    other.id = WindowID(rawValue: "impossible-tab")
    system.windows.append(other)
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.configuration.defaultTabbedPreset = height ? .rows : .columns
    model.setActiveMode(.tabbed)
    try #require(await waitFor { model.activeTabbedState?.windowIDs.count == 2 })
    let before = try #require(model.activeTabbedState)
    let frames = system.windows.map(\.frame)
    let writes = system.frameWriteCounts
    if height { system.windows[1].constraints.minimumSize.height = 780 }
    else { system.windows[1].constraints.minimumSize.width = 950 }
    model.performTabbed(.select(other.id))
    #expect(model.statusMessage != nil)
    #expect(model.activeTabbedState == before)
    #expect(system.windows.map(\.frame) == frames)
    #expect(system.frameWriteCounts == writes)
}

@Test @MainActor
func activationRepairsAnInactiveTabAboveAnotherPanesSelection() async throws {
    let system = FakeAppWindowSystem()
    let model = try await makeTwoTabbedColumns(system)
    defer { model.shutdown() }
    // Each pane's selected tab is above its own inactive tab, but the left
    // inactive tab still sits above the right selection and shared curtain.
    system.stack = [0, 1, 3, 2].map { stackEntry(system.windows[$0]) }
    system.focusedID = system.windows[0].id
    let raises = system.raiseRequests.count
    model.handleApplicationActivation()
    #expect(await waitFor { system.raiseRequests.count > raises })
    #expect(system.raiseRequests.dropFirst(raises).map(\.0) == [system.windows[3].id])
    let selected = Set(try #require(model.activeTabbedState).selectedWindowIDs)
    let order = try #require(system.stack).compactMap(\.windowID)
    #expect(Set(order.prefix(2)) == selected)
    #expect(!system.raiseRequests.dropFirst(raises).contains { $0.1 })
}

@Test @MainActor
func sharedCurtainRepairKeepsAFloatingWindowInThePaneGapInFront() async throws {
    let system = FakeAppWindowSystem()
    let model = try await makeTwoTabbedColumns(system)
    defer { model.shutdown() }
    let state = try #require(model.activeTabbedState)
    let bounds = system.mainDisplay.visibleFrame
    let left = try #require(state.frames(in: bounds)[state.panes[0].id])
    let floating = WindowID(rawValue: "gap-floating")
    let gap = TabbedStackEntry(windowID: floating,
        frame: BTRect(x: left.maxX + 1, y: bounds.minY + 100, width: 2, height: 100))
    system.stack = [0, 1].map { stackEntry(system.windows[$0]) }
        + [gap] + [3, 2].map { stackEntry(system.windows[$0]) }
    let raises = system.raiseRequests.count
    model.handleApplicationActivation()
    #expect(await waitFor { system.raiseRequests.count > raises })
    #expect(system.raiseRequests.dropFirst(raises).map(\.0) == [system.windows[3].id, floating])
    #expect(system.stack?.first?.windowID == floating)
    #expect(!system.raiseRequests.dropFirst(raises).contains { $0.1 })
}

@Test @MainActor
func sharedCurtainRequiresVerifiedOrderAfterAnIgnoredRaise() async throws {
    let system = FakeAppWindowSystem()
    let model = try await makeTwoTabbedColumns(system)
    defer { model.shutdown() }
    let state = try #require(model.activeTabbedState)
    system.stack = [0, 1, 3, 2].map { stackEntry(system.windows[$0]) }
    system.updatesStackOnRaise = false
    #expect(model.repairTabbedOrder(state: state, windows: system.windows,
        bounds: system.mainDisplay.visibleFrame) == nil)
}

@Test @MainActor
func tabbedDividerPresentationSurvivesDisplacedWindowsAndExcludesInactiveTabs() async throws {
    let system = FakeAppWindowSystem()
    let model = try await makeTwoTabbedColumns(system)
    defer { model.shutdown() }
    let state = try #require(model.activeTabbedState)
    let bounds = system.mainDisplay.visibleFrame
    let expected = state.layout.boundaries(in: bounds, displayID: system.mainDisplay.id)
    let hidden = try #require(state.panes[0].tabs.first { $0 != state.panes[0].selected })
    let index = try #require(system.windows.firstIndex { $0.id == hidden })
    system.windows[index].processIdentifier = system.windows[0].processIdentifier
    system.windows[0].frame.size.width -= 200
    // A frontmost floating window still suppresses a handle it overlaps.
    var floating = system.windows[0]
    floating.id = WindowID(rawValue: "divider-floating")
    floating.isFloating = true
    system.windows.append(floating)
    let presentation = model.dividerPresentation(windows: system.windows)
    #expect(presentation.boundaries == expected)
    #expect(presentation.obscuringFrames == [floating.frame])
}

@Test(arguments: [false, true]) @MainActor
func tabbedDividerUsesVerifiedFloatingOrderAcrossApps(floatingInFront: Bool) async throws {
    let system = FakeAppWindowSystem()
    let model = try await makeTwoTabbedColumns(system)
    defer { model.shutdown() }
    var floating = system.windows[0]
    floating.id = WindowID(rawValue: "inactive-app-floating")
    if floatingInFront { floating.processIdentifier += 500 }
    floating.isFloating = true
    system.windows.append(floating)
    let managed = [0, 3, 1, 2].map { stackEntry(system.windows[$0]) }
    system.stack = floatingInFront ? [stackEntry(floating)] + managed : managed + [stackEntry(floating)]
    #expect(model.dividerPresentation(windows: system.windows).obscuringFrames.contains(floating.frame) == floatingInFront)
}

@Test(arguments: [false, true]) @MainActor
func tabbedGesturesRetainEvidenceForAnAlreadyClampedInactiveTab(height: Bool) async throws {
    _ = NSApplication.shared
    let system = FakeAppWindowSystem()
    var hidden = system.windows[0]
    hidden.id = WindowID(rawValue: "already-clamped")
    hidden.frame.size = BTSize(width: 800, height: 600)
    system.windows.append(hidden)
    if height { system.enforcedMinimumHeights[hidden.id] = 450 }
    else { system.enforcedMinimumWidths[hidden.id] = 600 }
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.configuration.defaultTabbedPreset = height ? .rows : .columns
    model.setActiveMode(.tabbed)
    try #require(await waitFor {
        height ? system.windows[1].constraints.minimumSize.height >= 450
               : system.windows[1].constraints.minimumSize.width >= 600
    })
    model.prepareWindowGesture(on: system.mainDisplay.id)
    #expect(system.forgetLearnedMinimumsCount == 0)
    model.performTabbed(.select(hidden.id))
    try #require(await waitFor { model.activeTabbedState?.activeWindowID == hidden.id })
    #expect(model.statusMessage == nil)
    #expect(height ? system.windows[1].frame.size.height >= 450 : system.windows[1].frame.size.width >= 600)
}

@Test @MainActor
func observedSmallerInactiveTabNoLongerForcesItsPreviousMinimum() async throws {
    _ = NSApplication.shared
    let system = FakeAppWindowSystem()
    var hidden = system.windows[0]
    hidden.id = WindowID(rawValue: "content-minimum-changed")
    hidden.frame.size.width = 800
    system.windows.append(hidden)
    system.enforcedMinimumWidths[hidden.id] = 600
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.configuration.defaultTabbedPreset = .columns
    model.setActiveMode(.tabbed)
    try #require(await waitFor { system.windows[1].constraints.minimumSize.width >= 600 })
    let previous = try #require(model.activeTabbedState).frames(in: system.mainDisplay.visibleFrame)
    system.enforcedMinimumWidths[hidden.id] = 400
    system.windows[1].frame.size.width = 400 // The app has actually accepted a smaller size.
    model.performTabbed(.select(hidden.id))
    try #require(await waitFor { model.activeTabbedState?.activeWindowID == hidden.id })
    #expect(model.activeTabbedState?.frames(in: system.mainDisplay.visibleFrame) == previous)
    #expect(model.statusMessage == nil)
}
