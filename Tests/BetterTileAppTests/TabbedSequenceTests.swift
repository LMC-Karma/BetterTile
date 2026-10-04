import AppKit
import BetterTileCore
import BetterTileMacOS
import Testing
@testable import BetterTileApp

@MainActor private func sequenceFixture(sharedApplication: Bool = false) async throws -> (FakeAppWindowSystem, BetterTileModel) {
    _ = NSApplication.shared
    let system = FakeAppWindowSystem()
    for index in 1...3 {
        var window = system.windows[0]
        window.id = WindowID(rawValue: "sequence-\(index)")
        if !sharedApplication { window.processIdentifier += Int32(index) }
        system.windows.append(window)
    }
    let model = makeModel(system: system)
    model.configuration.defaultTabbedPreset = .columns
    model.setActiveMode(.tabbed)
    try #require(await waitFor { model.activeTabbedState?.windowIDs.count == 4 })
    let right = try #require(model.activeTabbedState?.panes[1].id)
    for window in system.windows.suffix(2) {
        model.performTabbed(.move(window.id, pane: right, index: nil))
        try #require(await waitFor { model.activeTabbedState?.pane(containing: window.id)?.id == right })
    }
    model.performTabbed(.select(system.windows[0].id))
    try #require(await waitFor { model.activeTabbedState?.activeWindowID == system.windows[0].id })
    await model.tabbedFocusTask?.value
    return (system, model)
}

@Test @MainActor func queuedTabbedMoveSurvivesALaterSelection() async throws {
    let (system, model) = try await sequenceFixture()
    defer { model.shutdown() }
    let a = system.windows[0].id, b = system.windows[1].id, c = system.windows[2].id
    let right = try #require(model.activeTabbedState?.panes[1].id)
    // These calls run in one main-actor turn. Selection owns the active
    // placement before either subsequent action is submitted.
    model.performTabbed(.select(b))
    model.performTabbed(.move(a, pane: right, index: nil))
    model.performTabbed(.select(c))
    try #require(await waitFor(timeout: .seconds(2)) { model.activeTabbedState?.activeWindowID == c })
    #expect(model.activeTabbedState?.pane(containing: a)?.id == right)
    #expect(model.activeTabbedState?.panes[0].tabs == [b])
}

@Test @MainActor func rapidTabbedMoveBackRetainsBothStructuralUndoSteps() async throws {
    let (system, model) = try await sequenceFixture()
    defer { model.shutdown() }
    let before = try #require(model.activeTabbedState)
    let a = system.windows[0].id, b = system.windows[1].id, c = system.windows[2].id
    let left = before.panes[0].id, right = before.panes[1].id
    model.performTabbed(.select(b))
    model.performTabbed(.move(a, pane: right, index: nil))
    model.performTabbed(.select(c))
    model.performTabbed(.select(a))
    model.performTabbed(.move(a, pane: left, index: 0))
    model.performTabbed(.select(b))
    model.performTabbed(.select(a))
    // C is a distinct final selection, so the initial A selection or the
    // intermediate move back cannot satisfy this completion barrier.
    model.performTabbed(.select(c))
    try #require(await waitFor(timeout: .seconds(2)) {
        model.activeTabbedState?.activeWindowID == c && model.activeTabbedState?.paneID(containing: a) == left
    })
    model.performTabbed(.undo)
    #expect(await waitFor(timeout: .seconds(2)) { model.activeTabbedState?.pane(containing: a)?.id == right })
    model.performTabbed(.undo)
    #expect(await waitFor(timeout: .seconds(2)) { model.activeTabbedState?.panes.map(\.tabs) == before.panes.map(\.tabs) })
}

@Test @MainActor func queuedPaneActivationRetainsADeferredTopologyRefresh() async throws {
    let (system, model) = try await sequenceFixture()
    defer { model.shutdown() }
    let b = system.windows[1].id
    let right = try #require(model.activeTabbedState?.panes[1].id)
    model.performTabbed(.select(b))
    model.performTabbed(.activate(right))
    var opened = system.windows[0]
    opened.id = WindowID(rawValue: "opened-during-selection")
    system.windows.append(opened)
    model.setActiveMode(.tabbed) // Refresh the current mode while placement is busy.
    #expect(await waitFor(timeout: .seconds(2)) { model.activeTabbedState?.windowIDs.contains(opened.id) == true })
    #expect(model.activeTabbedState?.activePaneID == right)
    #expect(model.activeTabbedState?.pane(containing: opened.id)?.id == right)
}

@Test(arguments: [false, true]) @MainActor
func failedNativeCenterDropRestoresMembershipAndDoesNotRecordUndo(inactiveSource: Bool) async throws {
    let (system, model) = try await sequenceFixture()
    defer { model.shutdown() }
    let before = try #require(model.activeTabbedState)
    let a = system.windows[0].id, b = system.windows[1].id, d = system.windows[3].id
    let source = inactiveSource ? b : a
    let frames = system.windows.map(\.frame)
    system.ignoredFrameWriteWindowIDs.insert(source)
    try #require(model.completeBentoDrag(displayID: system.mainDisplay.id, sourceID: source, outcome: .swap(targetWindowID: d)))
    try #require(await waitFor(timeout: .seconds(2)) { model.statusMessage != nil })
    #expect(model.activeTabbedState == before)
    #expect(system.windows.map(\.frame) == frames)
    system.ignoredFrameWriteWindowIDs.remove(source)
    // The latest successful structural action was moving D into the right
    // pane. Undo must consume it rather than the failed native drop.
    model.performTabbed(.undo)
    #expect(await waitFor(timeout: .seconds(2)) { model.activeTabbedState?.pane(containing: d)?.id == before.panes[0].id })
    model.performTabbed(.select(b))
    #expect(await waitFor(timeout: .seconds(2)) { model.activeTabbedState?.activeWindowID == b })
}

@Test @MainActor func nativeCenterDropSupersedesAnInFlightStripMoveThenRemainsUsable() async throws {
    let (system, model) = try await sequenceFixture()
    defer { model.shutdown() }
    let before = try #require(model.activeTabbedState)
    let a = system.windows[0].id, b = system.windows[1].id
    let c = system.windows[2].id, d = system.windows[3].id
    let right = before.panes[1].id
    system.frameApplicationDelays[a] = .milliseconds(60)
    let writes = system.frameWriteCounts[a, default: 0]
    model.performTabbed(.move(a, pane: right, index: nil))
    try #require(await waitFor { system.frameWriteCounts[a, default: 0] > writes })
    // The old placement has written frames and yielded to settlement. Native
    // capture supersedes it, then release immediately waits for its apply slot.
    try #require(model.beginBentoDrag(displayID: system.mainDisplay.id, sourceID: a))
    model.finishBentoDrag(displayID: system.mainDisplay.id, sourceID: a, outcome: .swap(targetWindowID: d))
    model.performTabbed(.select(c))
    try #require(await waitFor(timeout: .seconds(2)) { model.activeTabbedState?.pane(containing: a)?.id == right && model.activeTabbedState?.activeWindowID == c })
    model.performTabbed(.undo)
    try #require(await waitFor(timeout: .seconds(2)) { model.activeTabbedState == before })
    model.performTabbed(.select(b))
    try #require(await waitFor(timeout: .seconds(2)) { model.activeTabbedState?.activeWindowID == b })
    // The superseded strip placement did not create a second Undo entry.
    model.performTabbed(.undo)
    #expect(await waitFor(timeout: .seconds(2)) { model.activeTabbedState?.pane(containing: d)?.id == before.panes[0].id })
}

@Test @MainActor func slowFocusSelectionBurstKeepsTheLatestChoiceInEachPane() async throws {
    let (system, model) = try await sequenceFixture()
    defer { model.shutdown() }
    let a = system.windows[0].id, b = system.windows[1].id
    let c = system.windows[2].id, d = system.windows[3].id
    system.acceptsFocusRequests = false
    let requests = system.focusRequests.count
    model.performTabbed(.select(b))
    for _ in 0..<10 {
        model.performTabbed(.select(a))
        model.performTabbed(.select(b))
        model.performTabbed(.select(c))
        model.performTabbed(.select(d))
    }
    model.performTabbed(.select(c))
    model.performTabbed(.select(a))
    // Two bounded focus waits take at least 1.1 seconds. Leave room for the
    // other main-actor tests without replacing completion checks with a sleep.
    try #require(await waitFor(timeout: .seconds(5)) {
        model.activeTabbedState?.activeWindowID == a && model.activeTabbedState?.panes[1].selected == c
    })
    // One active request, then the last right and left choices. Intermediate
    // clicks must not each wait for focus that the app does not deliver.
    #expect(Array(system.focusRequests.dropFirst(requests)) == [b, c, a])
}

@Test @MainActor func selectionCoalescingUsesMembershipAfterThePendingMove() async throws {
    let (system, model) = try await sequenceFixture()
    defer { model.shutdown() }
    let a = system.windows[0].id, b = system.windows[1].id
    let c = system.windows[2].id, d = system.windows[3].id
    let right = try #require(model.activeTabbedState?.panes[1].id)
    let requests = system.focusRequests.count
    model.performTabbed(.move(a, pane: right, index: nil))
    model.performTabbed(.select(b))
    model.performTabbed(.select(c))
    model.performTabbed(.select(d))
    model.performTabbed(.select(a))
    try #require(await waitFor(timeout: .seconds(2)) {
        system.focusRequests.count >= requests + 3
            && model.activeTabbedState?.pane(containing: a)?.id == right
            && model.activeTabbedState?.activeWindowID == a
    })
    #expect(model.activeTabbedState?.panes[0].selected == b)
    #expect(Array(system.focusRequests.dropFirst(requests)) == [a, b, a])
}

@Test(arguments: [false, true]) @MainActor
func queuedMoveToARemovedPaneDoesNotStealFocus(split: Bool) async throws {
    let (system, model) = try await sequenceFixture()
    defer { model.shutdown() }
    let a = system.windows[0].id, b = system.windows[1].id, c = system.windows[2].id
    let right = try #require(model.activeTabbedState?.panes[1].id)
    let requests = system.focusRequests.count
    model.performTabbed(.select(b))
    model.performTabbed(.preset(.single))
    model.performTabbed(split ? .split(a, pane: right, edge: .bottom) : .move(a, pane: right, index: nil))
    model.performTabbed(.select(c))
    try #require(await waitFor(timeout: .seconds(2)) { model.activeTabbedState?.panes.count == 1 && model.activeTabbedState?.activeWindowID == c })
    #expect(!system.focusRequests.dropFirst(requests).contains(a))
    #expect(model.activeTabbedState?.windowIDs.count == 4)
}

@Test @MainActor func queuedClosedWindowDoesNotBlockTheNextSelection() async throws {
    let (system, model) = try await sequenceFixture()
    defer { model.shutdown() }
    let a = system.windows[0].id, b = system.windows[1].id, c = system.windows[2].id
    let right = try #require(model.activeTabbedState?.panes[1].id)
    model.performTabbed(.select(b))
    model.performTabbed(.move(a, pane: right, index: nil))
    model.performTabbed(.select(c))
    system.windows.removeAll { $0.id == a }
    system.eventHandler?(WindowSystemEvent(kind: .destroyed, windowID: a, processIdentifier: 42))
    #expect(await waitFor(timeout: .seconds(2)) { model.activeTabbedState?.activeWindowID == c })
    #expect(model.activeTabbedState?.windowIDs.contains(a) == false)
    #expect(model.activeTabbedState?.windowIDs.count == 3)
}

@Test @MainActor func nativeCancelledInactiveTabRestoresItsIndexSelectionAndUndo() async throws {
    let (system, model) = try await sequenceFixture()
    defer { model.shutdown() }
    let before = try #require(model.activeTabbedState)
    let b = system.windows[1].id, d = system.windows[3].id
    try #require(model.completeBentoDrag(displayID: system.mainDisplay.id, sourceID: b, outcome: .restore))
    try #require(await waitFor(timeout: .seconds(2)) { model.activeTabbedState == before })
    model.performTabbed(.undo)
    #expect(await waitFor(timeout: .seconds(2)) { model.activeTabbedState?.pane(containing: d)?.id == before.panes[0].id })
}

@Test @MainActor func loneTabNativeRestoreDrainsSelectionAcceptedDuringTheGesture() async throws {
    let (system, model) = try await sequenceFixture()
    defer { model.shutdown() }
    let a = system.windows[0].id, b = system.windows[1].id, c = system.windows[2].id
    let right = try #require(model.activeTabbedState?.panes[1].id)
    model.performTabbed(.move(b, pane: right, index: nil))
    try #require(await waitFor { model.activeTabbedState?.panes[0].tabs == [a] })
    let before = try #require(model.activeTabbedState)
    try #require(model.beginBentoDrag(displayID: system.mainDisplay.id, sourceID: a))
    model.performTabbed(.select(c))
    model.finishBentoDrag(displayID: system.mainDisplay.id, sourceID: a, outcome: .restore)
    try #require(await waitFor(timeout: .seconds(2)) { model.activeTabbedState?.activeWindowID == c })
    #expect(model.activeTabbedState?.panes.map(\.tabs) == before.panes.map(\.tabs))
    model.performTabbed(.undo)
    #expect(await waitFor(timeout: .seconds(2)) { model.activeTabbedState?.pane(containing: b)?.id == before.panes[0].id })
}

@Test @MainActor func loneTabNativeRestoreDrainsACapturedSnapAcceptedDuringTheGesture() async throws {
    let (system, model) = try await sequenceFixture()
    defer { model.shutdown() }
    let a = system.windows[0].id, b = system.windows[1].id, c = system.windows[2].id
    let right = try #require(model.activeTabbedState?.panes[1].id)
    model.performTabbed(.move(b, pane: right, index: nil))
    try #require(await waitFor { model.activeTabbedState?.panes[0].tabs == [a] })
    model.performTabbed(.select(a))
    try #require(await waitFor { model.activeTabbedState?.activeWindowID == a })
    let target = try #require(model.captureLayoutWheelTarget())
    try #require(model.beginBentoDrag(displayID: system.mainDisplay.id, sourceID: a))
    model.performLayoutWheel(.windowAction(.rightHalf), for: target)
    model.finishBentoDrag(displayID: system.mainDisplay.id, sourceID: a, outcome: .restore)
    let expected = try #require(WindowAction.rightHalf.partition).frame(in: system.mainDisplay.visibleFrame)
    try #require(await waitFor(timeout: .seconds(2)) {
        guard let state = model.activeTabbedState, let pane = state.paneID(containing: a) else { return false }
        return state.logicalFrames(in: system.mainDisplay.visibleFrame)[pane]?.approximatelyEquals(expected, tolerance: 0.001) == true
    })
    model.performTabbed(.select(c))
    #expect(await waitFor(timeout: .seconds(2)) { model.activeTabbedState?.activeWindowID == c })
}

@Test(arguments: [false, true], [false, true]) @MainActor
func mixedNativeAndStripMoveReturnSequencesRemainUsable(nativeFirst: Bool, sharedApplication: Bool) async throws {
    let (system, model) = try await sequenceFixture(sharedApplication: sharedApplication)
    defer { model.shutdown() }
    let before = try #require(model.activeTabbedState)
    let a = system.windows[0].id, b = system.windows[1].id, c = system.windows[2].id
    let left = before.panes[0].id, right = before.panes[1].id
    for iteration in 0..<25 {
        let moving = iteration.isMultiple(of: 2) ? a : b
        let other = moving == a ? b : a
        if nativeFirst {
            try #require(model.completeBentoDrag(displayID: system.mainDisplay.id, sourceID: moving,
                outcome: .swap(targetWindowID: c)))
        } else {
            model.performTabbed(.move(moving, pane: right, index: nil))
        }
        model.performTabbed(.select(c))
        try #require(await waitFor(timeout: .seconds(2)) { model.activeTabbedState?.pane(containing: moving)?.id == right && model.activeTabbedState?.activeWindowID == c })
        if nativeFirst {
            model.performTabbed(.move(moving, pane: left, index: moving == a ? 0 : 1))
        } else {
            try #require(model.completeBentoDrag(displayID: system.mainDisplay.id, sourceID: moving,
                outcome: .swap(targetWindowID: other)))
        }
        model.performTabbed(.select(other))
        model.performTabbed(.select(moving))
        try #require(await waitFor(timeout: .seconds(2)) { model.activeTabbedState?.pane(containing: moving)?.id == left && model.activeTabbedState?.activeWindowID == moving })
        let state = try #require(model.activeTabbedState)
        #expect(state.windowIDs == before.windowIDs)
        #expect(state.panes.map { Set($0.tabs) } == before.panes.map { Set($0.tabs) })
        #expect(state.frames(in: system.mainDisplay.visibleFrame) == before.frames(in: system.mainDisplay.visibleFrame))
        let content = TabbedLayoutState.contentFrame(try #require(state.frames(in: system.mainDisplay.visibleFrame)[left]))
        #expect(system.windows.first { $0.id == moving }?.frame == content)
    }
}
