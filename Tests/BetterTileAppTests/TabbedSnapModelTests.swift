import AppKit
import BetterTileCore
import BetterTileMacOS
import Testing
@testable import BetterTileApp

@Test @MainActor func requestedTabbedSnapSwapsThePaneWithTheExactOccupant() async throws {
    _ = NSApplication.shared
    let system = FakeAppWindowSystem()
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.configuration.defaultTabbedPreset = .columns
    model.setActiveMode(.tabbed)
    try #require(await waitFor { model.activeTabbedState?.panes.count == 2 })
    let before = try #require(model.activeTabbedState)
    let window = system.windows[0].id
    let destination = before.panes[1].id
    try #require(before.panes[0].tabs == [window])
    try #require(before.panes[1].tabs.isEmpty)
    let bounds = system.mainDisplay.visibleFrame
    let right = WindowAction.rightHalf.partition?.frame(in: bounds)
    model.perform(.rightHalf)
    #expect(await waitFor(timeout: .seconds(1)) {
        model.activeTabbedState?.logicalFrames(in: bounds)[before.panes[0].id] == right
    })
    let after = try #require(model.activeTabbedState)
    #expect(after.panes.first { $0.id == before.panes[0].id }?.tabs == [window])
    #expect(after.panes.first { $0.id == destination }?.tabs.isEmpty == true)
    #expect(after.logicalFrames(in: bounds)[destination] == WindowAction.leftHalf.partition?.frame(in: bounds))
    #expect(after.panes.count == 2 && after.activeWindowID == window)
    #expect(model.statusMessage == nil)
    model.performTabbed(.undo)
    #expect(await waitFor { model.activeTabbedState == before })
}

@Test(arguments: ["wheel", "drag"]) @MainActor
func requestedTabbedSnapPreservesExistingOccupiedPane(entry: String) async throws {
    _ = NSApplication.shared
    let system = FakeAppWindowSystem()
    for name in ["hidden", "right"] {
        var window = system.windows[0]
        window.id = WindowID(rawValue: name)
        system.windows.append(window)
    }
    let source = system.windows[0].id, hidden = system.windows[1].id, right = system.windows[2].id
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.configuration.defaultTabbedPreset = .columns
    model.setActiveMode(.tabbed)
    try #require(await waitFor { model.activeTabbedState?.windowIDs.count == 3 })
    let destination = try #require(model.activeTabbedState?.panes[1].id)
    model.performTabbed(.move(right, pane: destination, index: nil))
    try #require(await waitFor { model.activeTabbedState?.panes[1].selected == right })
    model.performTabbed(.select(source))
    try #require(await waitFor { model.activeTabbedState?.activeWindowID == source })
    let before = try #require(model.activeTabbedState)
    let target = LayoutWheelTarget(windowID: source, displayID: system.mainDisplay.id,
                                  visibleFrame: system.mainDisplay.visibleFrame)
    switch entry {
    case "wheel":
        model.performLayoutWheel(.windowAction(.rightHalf), for: target)
    default:
        let frame = try #require(StandardActionEngine().targetFrame(for: .rightHalf,
            window: system.windows[0], display: system.mainDisplay))
        try #require(model.completeBentoDrag(displayID: system.mainDisplay.id, sourceID: source,
                                            outcome: .snap(action: .rightHalf, frame: frame)))
    }
    let bounds = system.mainDisplay.visibleFrame
    if entry == "wheel" {
        // A command moves the source's whole pane; the occupant swaps places.
        #expect(await waitFor(timeout: .seconds(1)) {
            model.activeTabbedState?.logicalFrames(in: bounds)[before.panes[0].id]
                == WindowAction.rightHalf.partition?.frame(in: bounds)
        })
        let after = try #require(model.activeTabbedState)
        #expect(after.panes.first { $0.id == before.panes[0].id }?.tabs == [source, hidden])
        #expect(after.panes.first { $0.id == destination }?.tabs == [right])
        #expect(after.activeWindowID == source && after.panes.count == 2)
        return
    }
    // A native drag moves only the dragged window into the exact pane.
    #expect(await waitFor(timeout: .seconds(1)) {
        model.activeTabbedState?.panes.first { $0.id == destination }?.selected == source
    })
    let after = try #require(model.activeTabbedState)
    #expect(after.panes.first { $0.id == destination }?.tabs == [right, source])
    #expect(after.panes.first { $0.id == before.panes[0].id }?.tabs == [hidden])
    #expect(after.panes.count == 2)
}

@MainActor
private func snapFixture(preset: TabbedPreset = .columns) async throws -> (FakeAppWindowSystem, BetterTileModel) {
    _ = NSApplication.shared
    let system = FakeAppWindowSystem()
    for (index, name) in ["hidden", "right"].enumerated() {
        var window = system.windows[0]
        window.id = WindowID(rawValue: name)
        window.processIdentifier += Int32(index + 1)
        window.bundleIdentifier = "com.example.Peer-\(index)"
        system.windows.append(window)
    }
    let model = makeModel(system: system)
    model.configuration.defaultTabbedPreset = preset
    model.setActiveMode(.tabbed)
    try #require(await waitFor { model.activeTabbedState?.windowIDs.count == 3 })
    if preset == .columns {
        let right = try #require(model.activeTabbedState?.panes[1].id)
        model.performTabbed(.move(system.windows[2].id, pane: right, index: nil))
        try #require(await waitFor { model.activeTabbedState?.panes[1].selected == system.windows[2].id })
    }
    model.performTabbed(.select(system.windows[0].id))
    try #require(await waitFor { model.activeTabbedState?.activeWindowID == system.windows[0].id })
    return (system, model)
}

@Test @MainActor func tabbedSnapWheelCapturesAMemberAndKeepsThatWindowAfterFocusChanges() async throws {
    let (system, model) = try await snapFixture()
    defer { model.shutdown() }
    let before = try #require(model.activeTabbedState)
    let target = try #require(model.captureLayoutWheelTarget())
    #expect(target.desktopSessionID != nil)
    #expect(target.layoutMode == .tabbed)
    system.focusedID = system.windows[2].id
    let writes = system.frameWriteCounts
    let preview = model.previewLayoutWheel(.windowAction(.rightHalf), for: target)
    guard case let .ready(placements) = preview else { Issue.record("Expected Tabbed preview"); return }
    #expect(placements.count == 2) // Selected tabs only, not duplicate hidden ghosts.
    #expect(system.frameWriteCounts == writes)
    #expect(model.activeTabbedState == before)
    model.performLayoutWheel(.windowAction(.rightHalf), for: target)
    let bounds = system.mainDisplay.visibleFrame
    try #require(await waitFor {
        model.activeTabbedState?.logicalFrames(in: bounds)[before.panes[0].id]
            == WindowAction.rightHalf.partition?.frame(in: bounds)
    })
    for placement in placements {
        #expect(system.windows.first { $0.id == placement.windowID }?.frame == placement.frame)
    }
    let after = try #require(model.activeTabbedState)
    #expect(after.panes.first { $0.id == before.panes[0].id }?.tabs == [target.windowID, system.windows[1].id])
    #expect(after.panes.first { $0.id == before.panes[1].id }?.tabs == [system.windows[2].id])
    #expect(after.activeWindowID == target.windowID)
}

@Test(arguments: [WindowAction.maximize, .restore, .center, .centerResize, .almostMaximize,
                  .nextDisplay, .previousDisplay, .moveLeft, .growWidth])
@MainActor func tabbedSnapUnsupportedMemberActionsNeverMoveRawFrames(action: WindowAction) async throws {
    let (system, model) = try await snapFixture()
    defer { model.shutdown() }
    let before = try #require(model.activeTabbedState)
    let target = try #require(model.captureLayoutWheelTarget())
    let frames = system.windows.map(\.frame), writes = system.frameWriteCounts
    model.perform(action)
    #expect(model.statusMessage != nil)
    if action == .maximize { #expect(model.statusMessage?.contains("One Pane") == true) }
    if action == .restore { #expect(model.statusMessage?.contains("Tabbed Undo") == true) }
    let feedbackMessage = switch action {
    case .maximize: "Choose One Pane"
    case .restore: "Use Tabbed Undo"
    default: "Float this window first"
    }
    #expect(model.lastActionFeedback?.message == feedbackMessage)
    guard case .unavailable = model.previewLayoutWheel(.windowAction(action), for: target) else {
        Issue.record("An unsupported member action was previewed"); return
    }
    model.performLayoutWheel(.windowAction(action), for: target)
    #expect(model.lastActionFeedback?.message == feedbackMessage)
    #expect(model.activeTabbedState == before)
    #expect(system.windows.map(\.frame) == frames)
    #expect(system.frameWriteCounts == writes)
}

@Test(arguments: ["keyboard", "wheel"], [WindowAction.center, .maximize])
@MainActor func tabbedSnapUserFloatsKeepFreeWindowActions(entry: String, action: WindowAction) async throws {
    let (system, model) = try await snapFixture()
    defer { model.shutdown() }
    let id = system.windows[0].id
    model.performTabbed(.float(id))
    try #require(await waitFor { model.activeTabbedState?.floatingWindowIDs.contains(id) == true })
    let before = try #require(model.activeTabbedState)
    system.focusedID = id
    let expected = try #require(StandardActionEngine().targetFrame(for: action, window: system.windows[0], display: system.mainDisplay))
    if entry == "keyboard" { model.perform(action) }
    else { model.performLayoutWheel(.windowAction(action), for: try #require(model.captureLayoutWheelTarget())) }
    #expect(system.windows[0].frame == expected)
    #expect(model.activeTabbedState == before)
}

@Test(arguments: [false, true], [false, true])
@MainActor func tabbedSnapRefusesReportedAndLearnedMinimaWithoutChangingExactTarget(learned: Bool, height: Bool) async throws {
    let (system, model) = try await snapFixture(preset: .single)
    defer { model.shutdown() }
    let id = system.windows[0].id
    let before = try #require(model.activeTabbedState), frames = system.windows.map(\.frame)
    if learned {
        if height { system.enforcedMinimumHeights[id] = 450 }
        else { system.enforcedMinimumWidths[id] = 600 }
    } else {
        if height { system.windows[0].constraints.minimumSize.height = 450 }
        else { system.windows[0].constraints.minimumSize.width = 600 }
    }
    model.perform(height ? .topHalf : .rightHalf)
    try #require(await waitFor { model.statusMessage != nil })
    #expect(model.activeTabbedState == before)
    #expect(system.windows.map(\.frame) == frames)
    if learned {
        #expect(height ? system.windows[0].constraints.minimumSize.height >= 450
                       : system.windows[0].constraints.minimumSize.width >= 600)
    }
    model.performTabbed(.undo)
    #expect(model.activeTabbedState == before) // No failed step was recorded.
}

@Test(arguments: ["ignored", "raise"])
@MainActor func tabbedSnapFailureRestoresMembershipFramesAndDoesNotAddUndo(failure: String) async throws {
    let (system, model) = try await snapFixture()
    defer { model.shutdown() }
    let id = system.windows[0].id
    let before = try #require(model.activeTabbedState), frames = system.windows.map(\.frame)
    if failure == "ignored" { system.ignoredFrameWriteWindowIDs.insert(id) }
    else { system.failingNextRaiseWindowID = id }
    model.perform(.rightHalf)
    try #require(await waitFor { model.statusMessage != nil })
    #expect(model.activeTabbedState == before)
    #expect(system.windows.map(\.frame) == frames)
    system.ignoredFrameWriteWindowIDs = []
    model.performTabbed(.undo)
    #expect(await waitFor { model.activeTabbedState?.panes[1].tabs.isEmpty == true })
}

@Test @MainActor func tabbedSnapSamePaneDoesNotAddAnUndoStep() async throws {
    let (_, model) = try await snapFixture()
    defer { model.shutdown() }
    let before = try #require(model.activeTabbedState)
    model.perform(.leftHalf)
    model.performTabbed(.undo) // Queued behind the no-op snap if needed.
    #expect(await waitFor { model.activeTabbedState?.panes[1].tabs.isEmpty == true })
    #expect(model.activeTabbedState?.panes.map(\.id) == before.panes.map(\.id))
}

/// One Pane needs an empty pane for the remainder. Four Panes reflows its
/// other panes into the remainder without adding one.
@Test(arguments: [TabbedPreset.single, .grid])
@MainActor func tabbedSnapMovesThePaneAndUndoesOnce(preset: TabbedPreset) async throws {
    let (system, model) = try await snapFixture(preset: preset)
    defer { model.shutdown() }
    let before = try #require(model.activeTabbedState), id = system.windows[0].id
    let source = try #require(before.pane(containing: id))
    let bounds = system.mainDisplay.visibleFrame
    model.perform(.rightHalf)
    try #require(await waitFor {
        model.activeTabbedState?.logicalFrames(in: bounds)[source.id] == WindowAction.rightHalf.partition?.frame(in: bounds)
    })
    let after = try #require(model.activeTabbedState)
    #expect(after.panes.count == before.panes.count + (preset == .single ? 1 : 0))
    #expect(Set(before.panes.map(\.id)).isSubset(of: Set(after.panes.map(\.id))))
    #expect(after.panes.first { $0.id == source.id }?.tabs == source.tabs)
    model.performTabbed(.undo)
    #expect(await waitFor { model.activeTabbedState == before })
}

@Test(arguments: [false, true])
@MainActor func tabbedSnapFloatUndoRestoresItsActualPreActionFrame(native: Bool) async throws {
    let (system, model) = try await snapFixture()
    defer { model.shutdown() }
    let id = system.windows[0].id
    model.performTabbed(.float(id))
    try #require(await waitFor { model.activeTabbedState?.floatingWindowIDs.contains(id) == true })
    let before = try #require(model.activeTabbedState)
    let frame = BTRect(x: 75, y: 110, width: 620, height: 470)
    system.windows[0].frame = frame
    system.focusedID = id
    if native {
        system.windows[0].frame.origin.x += 40
        try #require(model.completeBentoDrag(displayID: system.mainDisplay.id, sourceID: id,
            outcome: .snap(action: .rightHalf, frame: BTRect(x: 0, y: 0, width: 900, height: 700)), sourceFrame: frame))
    } else { model.perform(.rightHalf) }
    try #require(await waitFor { model.activeTabbedState?.paneID(containing: id) != nil })
    model.performTabbed(.undo)
    try #require(await waitFor { model.activeTabbedState?.floatingWindowIDs.contains(id) == true })
    #expect(model.activeTabbedState == before)
    #expect(system.windows[0].frame == frame)
}

@Test @MainActor func tabbedSnapQueuedIntentKeepsCapturedSourceAndReplans() async throws {
    let (system, model) = try await snapFixture(preset: .single)
    defer { model.shutdown() }
    let id = system.windows[0].id, target = try #require(model.captureLayoutWheelTarget())
    system.frameApplicationDelays[id] = .milliseconds(60)
    model.perform(.rightHalf)
    model.performLayoutWheel(.windowAction(.leftThird), for: target)
    system.focusedID = system.windows[1].id
    let expected = WindowAction.leftThird.partition!.frame(in: system.mainDisplay.visibleFrame)
    #expect(await waitFor {
        guard let state = model.activeTabbedState, let pane = state.paneID(containing: id) else { return false }
        return state.logicalFrames(in: system.mainDisplay.visibleFrame)[pane]?.approximatelyEquals(expected, tolerance: 0.001) == true
    })
    #expect(model.activeTabbedState?.activeWindowID == id)
}

@Test(arguments: ["work-area", "session", "mode", "closed", "shutdown"])
@MainActor func tabbedSnapStaleWheelTargetsNeverWrite(change: String) async throws {
    let (system, model) = try await snapFixture()
    defer { model.shutdown() }
    var target = try #require(model.captureLayoutWheelTarget())
    switch change {
    case "work-area": system.availableDisplays[0].visibleFrame.size.height -= 50
    case "session": target.desktopSessionID = DesktopSessionID()
    case "mode": model.setActiveMode(.manual)
    case "closed": system.windows.removeFirst()
    default: model.shutdown()
    }
    let writes = system.frameWriteCounts, frames = system.windows.map(\.frame)
    guard case .unavailable = model.previewLayoutWheel(.windowAction(.rightHalf), for: target) else {
        Issue.record("Expected stale target rejection"); return
    }
    model.performLayoutWheel(.windowAction(.rightHalf), for: target)
    #expect(system.frameWriteCounts == writes)
    #expect(system.windows.map(\.frame) == frames)
}

@Test(arguments: ["success", "minimum", "unsupported", "raise"])
@MainActor func tabbedSnapNativeUsesVerifiedFramesAndOriginalMembership(outcome: String) async throws {
    let (system, model) = try await snapFixture()
    defer { model.shutdown() }
    let before = try #require(model.activeTabbedState), frames = system.windows.map(\.frame), id = system.windows[0].id
    system.windows[0].frame.origin.x += 77 // macOS already moved the window before begin.
    if outcome == "minimum" { system.windows[0].constraints.minimumSize.width = 600 }
    if outcome == "raise" { system.failingNextRaiseWindowID = id }
    let action: WindowAction = outcome == "unsupported" ? .maximize : .rightHalf
    try #require(model.completeBentoDrag(displayID: system.mainDisplay.id, sourceID: id,
        outcome: .snap(action: action, frame: BTRect(x: 0, y: 0, width: 900, height: 700))))
    if outcome == "success" {
        try #require(await waitFor { model.activeTabbedState?.panes[1].selected == id })
        model.performTabbed(.undo)
        try #require(await waitFor { model.activeTabbedState == before })
    } else { try #require(await waitFor { model.statusMessage != nil }) }
    #expect(model.activeTabbedState == before)
    #expect(system.windows.map(\.frame) == frames)
}

@Test @MainActor func tabbedSnapNativeObservationFailureStillRestoresItsCheckpoint() async throws {
    let (system, model) = try await snapFixture()
    defer { model.shutdown() }
    let before = try #require(model.activeTabbedState), frames = system.windows.map(\.frame), id = system.windows[0].id
    system.windows[0].frame.origin.x += 80
    system.failedVisibleWindowSweeps = [system.completeSweepCount + 2] // Begin succeeds; release observation fails.
    try #require(model.completeBentoDrag(displayID: system.mainDisplay.id, sourceID: id,
        outcome: .snap(action: .rightHalf, frame: BTRect(x: 0, y: 0, width: 900, height: 700))))
    try #require(await waitFor { model.statusMessage != nil })
    #expect(model.activeTabbedState == before)
    #expect(system.windows.map(\.frame) == frames)
}

@Test @MainActor func tabbedSnapNativeDepartureNeverRestoresOnTheNewSpace() async throws {
    let (system, model) = try await snapFixture()
    defer { model.shutdown() }
    let display = system.mainDisplay.id, id = system.windows[0].id
    let first = NativeSpaceID(rawValue: 1), second = NativeSpaceID(rawValue: 2)
    system.desktopObservation = NativeDesktopObservation(currentSpaceByDisplay: [display: first],
        knownSpacesByDisplay: [display: [first, second]],
        windowMembership: Dictionary(uniqueKeysWithValues: system.windows.map { ($0.id, Set([first])) }))
    // The begin snapshot belongs to the current runtime session. The task must
    // validate the fresh observation before its first frame write.
    system.windows[0].frame.origin.x += 50
    try #require(model.completeBentoDrag(displayID: display, sourceID: id,
        outcome: .snap(action: .rightHalf, frame: system.mainDisplay.visibleFrame)))
    system.desktopObservation?.currentSpaceByDisplay[display] = second
    let writes = system.frameWriteCounts, frames = system.windows.map(\.frame)
    try await Task.sleep(for: .milliseconds(250))
    #expect(system.frameWriteCounts == writes)
    #expect(system.windows.map(\.frame) == frames)
}

@Test(arguments: ["floating-frame", "stacking"])
@MainActor func tabbedSnapRejectedGestureSuspendsWhenCheckpointRecoveryFails(failure: String) async throws {
    let (system, model) = try await snapFixture()
    defer { model.shutdown() }
    let id = system.windows[0].id
    if failure == "floating-frame" {
        model.performTabbed(.float(id))
        try #require(await waitFor { model.activeTabbedState?.floatingWindowIDs.contains(id) == true })
        system.windows[0].frame = BTRect(x: 70, y: 110, width: 620, height: 470)
    }
    let before = try #require(model.activeTabbedState), frame = system.windows[0].frame
    system.windows[0].frame.origin.x += 40
    system.windows[0].constraints.minimumSize.width = 600
    if failure == "floating-frame" {
        system.failedFrameWriteNumbers[id] = [system.frameWriteCounts[id, default: 0] + 1]
    } else { system.failingNextRaiseWindowID = before.selectedWindowIDs.first }
    let dropped = system.windows[0].frame, sourceWrites = system.frameWriteCounts[id]
    try #require(model.completeBentoDrag(displayID: system.mainDisplay.id, sourceID: id,
        outcome: .snap(action: .rightHalf, frame: system.mainDisplay.visibleFrame), sourceFrame: frame))
    if failure == "floating-frame" {
        // The overlay showed invalid feedback. A floating window has no slot
        // to return to, so it stays where it was dropped and nothing is
        // written; the pill gives the reason.
        #expect(model.statusMessage != nil)
        #expect(system.windows[0].frame == dropped)
        #expect(system.frameWriteCounts[id] == sourceWrites)
        #expect(model.activeTabbedState == before)
        return
    }
    try #require(await waitFor { model.statusMessage?.contains("restore") == true })
    #expect(model.activeTabbedState == before)
    let writes = system.frameWriteCounts
    system.eventHandler?(WindowSystemEvent(kind: .resized, windowID: id, processIdentifier: system.windows[0].processIdentifier))
    try await Task.sleep(for: .milliseconds(250))
    #expect(system.frameWriteCounts == writes) // Degraded recovery stopped ambient writes.
}

@Test @MainActor func tabbedSnapLastFloatingWindowCanUseNativeSnapIntoVacantPanes() async throws {
    _ = NSApplication.shared
    let system = FakeAppWindowSystem()
    let subject = makeModel(system: system)
    defer { subject.shutdown() }
    subject.configuration.defaultTabbedPreset = .columns
    subject.setActiveMode(.tabbed)
    let id = system.windows[0].id
    try #require(await waitFor { subject.activeTabbedState?.windowIDs == [id] })
    subject.performTabbed(.float(id))
    try #require(await waitFor { subject.activeTabbedState?.floatingWindowIDs == [id] })
    let right = try #require(subject.activeTabbedState?.panes[1].id), initial = system.windows[0].frame
    system.windows[0].frame.origin.x += 30
    try #require(subject.completeBentoDrag(displayID: system.mainDisplay.id, sourceID: id,
        outcome: .snap(action: .rightHalf, frame: system.mainDisplay.visibleFrame), sourceFrame: initial))
    #expect(await waitFor { subject.activeTabbedState?.paneID(containing: id) == right })
}

@Test @MainActor func tabbedSnapSpaceChangeDuringReleaseDoesNotAdoptTheNewSpaceForRollback() async throws {
    let (system, model) = try await snapFixture()
    defer { model.shutdown() }
    let display = system.mainDisplay.id, id = system.windows[0].id
    let first = NativeSpaceID(rawValue: 1), second = NativeSpaceID(rawValue: 2)
    system.desktopObservation = NativeDesktopObservation(currentSpaceByDisplay: [display: first],
        knownSpacesByDisplay: [display: [first, second]],
        windowMembership: Dictionary(uniqueKeysWithValues: system.windows.map { ($0.id, Set([first])) }))
    let releaseSweep = system.completeSweepCount + 2
    system.onVisibleWindowSweep = { [weak system] count in
        if count == releaseSweep { system?.desktopObservation?.currentSpaceByDisplay[display] = second }
    }
    system.windows[0].frame.origin.x += 50
    let writes = system.frameWriteCounts, frames = system.windows.map(\.frame)
    try #require(model.completeBentoDrag(displayID: display, sourceID: id,
        outcome: .snap(action: .rightHalf, frame: system.mainDisplay.visibleFrame)))
    try await Task.sleep(for: .milliseconds(250))
    #expect(system.frameWriteCounts == writes)
    #expect(system.windows.map(\.frame) == frames)
}

@Test @MainActor func tabbedSnapKeyboardCyclesWhileWheelPreviewsRemainExact() async throws {
    let (system, model) = try await snapFixture()
    defer { model.shutdown() }
    // A loaded runner can take longer than the 2-second cycle between presses.
    model.shortcutCycleInterval = 60
    let id = system.windows[0].id
    for action in [WindowAction.leftHalf, .leftThird, .leftTwoThirds] {
        model.perform(.leftHalf)
        let expected = action.partition!.frame(in: system.mainDisplay.visibleFrame)
        try #require(await waitFor {
            guard let state = model.activeTabbedState, let pane = state.paneID(containing: id) else { return false }
            return state.logicalFrames(in: system.mainDisplay.visibleFrame)[pane]?.approximatelyEquals(expected, tolerance: 0.001) == true
        })
        let target = try #require(model.captureLayoutWheelTarget())
        let one = model.previewLayoutWheel(.windowAction(.rightHalf), for: target)
        #expect(model.previewLayoutWheel(.windowAction(.rightHalf), for: target) == one)
    }
}

@Test(arguments: ["sticky", "excluded", "ignored"])
@MainActor func tabbedSnapDoesNotEnrollSystemFloatsOrExcludedApps(rule: String) async throws {
    let (system, model) = try await snapFixture()
    defer { model.shutdown() }
    let id = system.windows[0].id
    model.performTabbed(.float(id))
    try #require(await waitFor { model.activeTabbedState?.floatingWindowIDs.contains(id) == true })
    let before = try #require(model.activeTabbedState), frame = system.windows[0].frame
    system.focusedID = id
    if rule == "sticky" { system.windows[0].isFloating = true }
    else { model.configuration.applicationRules.set(rule == "excluded" ? .excludeFromBento : .ignoreEverywhere,
                                                     for: system.windows[0].bundleIdentifier!) }
    model.perform(.rightHalf)
    #expect(model.activeTabbedState == before)
    #expect(system.windows[0].frame == (rule == "ignored" ? frame : BTRect(x: 500, y: 0, width: 500, height: 800)))
}

@Test @MainActor func tabbedSnapRuleChangeProtectsAFloatingSourceAndDiscardsItsQueue() async throws {
    let (system, model) = try await snapFixture()
    defer { model.shutdown() }
    let id = system.windows[0].id, bundle = try #require(system.windows[0].bundleIdentifier)
    model.performTabbed(.float(id))
    try #require(await waitFor { model.activeTabbedState?.floatingWindowIDs.contains(id) == true })
    system.focusedID = id
    let before = try #require(model.activeTabbedState), writes = system.frameWriteCounts
    let target = try #require(model.captureLayoutWheelTarget())
    model.perform(.rightHalf)
    model.performLayoutWheel(.windowAction(.leftThird), for: target)
    model.configuration.applicationRules.set(.ignoreEverywhere, for: bundle)
    try await Task.sleep(for: .milliseconds(200))
    #expect(model.activeTabbedState == before)
    #expect(system.frameWriteCounts == writes)
    model.configuration.applicationRules.set(.manageNormally, for: bundle)
    model.performTabbed(.preset(.columns))
    try await Task.sleep(for: .milliseconds(250))
    #expect(model.activeTabbedState?.floatingWindowIDs.contains(id) == true)
    #expect(model.activeTabbedState?.panes.count == 2) // A stale queued Left Third was discarded.
}

@Test(arguments: [WindowAction.rightHalf, .maximize, .restore, .center], [false, true]) @MainActor
func tabbedSnapExcludedMembersReceiveParticipationGuidance(action: WindowAction, ignored: Bool) async throws {
    let (system, model) = try await snapFixture()
    defer { model.shutdown() }
    let id = system.windows[0].id, bundle = try #require(system.windows[0].bundleIdentifier)
    let before = try #require(model.activeTabbedState)
    let target = try #require(model.captureLayoutWheelTarget())
    model.setRule(ignored ? .ignoreEverywhere : .excludeFromBento, for: bundle)
    #expect(model.activeTabbedState?.windowIDs.contains(id) == true)
    let frames = system.windows.map(\.frame), writes = system.frameWriteCounts
    for wheel in [false, true] {
        model.statusMessage = nil
        if wheel { model.performLayoutWheel(.windowAction(action), for: target) }
        else { model.perform(action) }
        #expect(model.activeTabbedState == before)
        #expect(system.windows.map(\.frame) == frames)
        #expect(system.frameWriteCounts == writes)
        #expect(model.lastActionFeedback?.kind == .failure)
        #expect(model.lastActionFeedback?.message == (ignored ? "App is ignored" : "Float this window first"))
        #expect(model.statusMessage?.contains(ignored ? "ignore this app" : "no longer participates") == true)
    }
}

@Test(arguments: [WindowAction.rightHalf, .maximize, .restore, .center], [false, true]) @MainActor
func tabbedSnapExcludedNonmembersRetainOrdinaryActions(action: WindowAction, floated: Bool) async throws {
    for wheel in [false, true] {
        _ = NSApplication.shared
        let system = FakeAppWindowSystem()
        let model = makeModel(system: system)
        defer { model.shutdown() }
        let id = system.windows[0].id, bundle = try #require(system.windows[0].bundleIdentifier)
        if !floated { model.setRule(.excludeFromBento, for: bundle) }
        model.setActiveMode(.tabbed)
        try #require(await waitFor { model.activeTabbedState != nil })
        if floated {
            model.performTabbed(.float(id))
            try #require(await waitFor { model.activeTabbedState?.floatingWindowIDs.contains(id) == true })
            model.setRule(.excludeFromBento, for: bundle)
        }
        #expect(model.activeTabbedState?.windowIDs.contains(id) == false)
        let before = try #require(model.activeTabbedState), restoreFrame = system.windows[0].frame
        if action == .restore { model.perform(.leftHalf) }
        let target = try #require(model.captureLayoutWheelTarget())
        let expected = try #require(action == .restore ? restoreFrame : StandardActionEngine().targetFrame(
            for: action, window: system.windows[0], display: system.mainDisplay))
        let writes = system.frameWriteCounts
        if wheel { model.performLayoutWheel(.windowAction(action), for: target) }
        else { model.perform(action) }
        #expect(system.windows[0].frame == expected)
        #expect(system.frameWriteCounts != writes)
        #expect(model.lastActionFeedback?.kind == .success)
        #expect(model.statusMessage == nil)
        #expect(model.activeTabbedState == before)
    }
}

@Test(arguments: [LayoutMode.manual, .bento, .tabbed], [false, true]) @MainActor
func spaceStabilizationDelaysOnlyTabbedWindowActions(mode: LayoutMode, wheel: Bool) async throws {
    _ = NSApplication.shared
    let system = FakeAppWindowSystem()
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.configuration.bentoInnerGap = 0
    model.configuration.defaultTabbedPreset = .columns
    model.setActiveMode(mode)
    if mode == .tabbed {
        try #require(await waitFor { model.activeTabbedState?.windowIDs == [system.windows[0].id] })
    }
    let captured = try #require(model.captureLayoutWheelTarget())
    func act(_ action: WindowAction) {
        if wheel { model.performLayoutWheel(.windowAction(action), for: captured) }
        else { model.perform(action) }
    }
    let target = WindowAction.rightHalf.partition!.frame(in: system.mainDisplay.visibleFrame)
    model.beginActiveSpaceStabilization()
    try #require(model.isStabilizingSpace)
    let frames = system.windows.map(\.frame), writes = system.frameWriteCounts
    act(.rightHalf)

    if mode == .tabbed {
        #expect(system.windows.map(\.frame) == frames)
        #expect(system.frameWriteCounts == writes)
        #expect(model.lastActionFeedback?.kind == .failure)
        #expect(model.lastActionFeedback?.message == "Desktop changed")
        #expect(model.statusMessage?.contains("Space switch") == true)
        #expect(model.captureLayoutWheelTarget() == nil)

        try #require(await waitFor { !model.isStabilizingSpace })
        #expect(model.captureLayoutWheelTarget() != nil)
        let resumedWrites = system.frameWriteCounts
        act(.rightHalf)
        #expect(await waitFor {
            guard let state = model.activeTabbedState,
                  let pane = state.paneID(containing: system.windows[0].id) else { return false }
            return state.logicalFrames(in: system.mainDisplay.visibleFrame)[pane] == target
                && state.groups.contentFrames(in: system.mainDisplay.visibleFrame)?[pane] == system.windows[0].frame
        })
        #expect(system.frameWriteCounts != resumedWrites)
    } else {
        // Other modes keep acting on the focused window during a Space switch.
        #expect(system.windows[0].frame == target)
        #expect(system.frameWriteCounts != writes)
        #expect(model.lastActionFeedback?.kind == .success)
        #expect(model.captureLayoutWheelTarget() != nil)
        try #require(await waitFor { !model.isStabilizingSpace })
        #expect(system.windows[0].frame == target)
    }
    #expect(model.statusMessage == nil)

    model.shutdown()
    model.statusMessage = "shutdown checkpoint"
    let shutdownFeedback = model.lastActionFeedback, shutdownWrites = system.frameWriteCounts
    model.perform(.leftHalf)
    #expect(model.statusMessage == "shutdown checkpoint")
    #expect(model.lastActionFeedback == shutdownFeedback)
    #expect(system.frameWriteCounts == shutdownWrites)
}

@Test @MainActor func tabbedSnapWaitsForThePreviousNativeDropsTabPlacement() async throws {
    let (system, model) = try await snapFixture()
    defer { model.shutdown() }
    let id = system.windows[0].id, right = system.windows[2].id, display = system.mainDisplay.id
    try #require(model.completeBentoDrag(displayID: display, sourceID: id,
        outcome: .insert(targetWindowID: right, edge: .bottom)))
    // The Bento split published its tree; its hidden-tab follow-up still owns
    // the apply slot. A new fixed snap must retain its gesture until that ends.
    try #require(model.activeTabbedState?.panes.count == 3)
    try #require(model.completeBentoDrag(displayID: display, sourceID: id,
        outcome: .snap(action: .rightHalf, frame: system.mainDisplay.visibleFrame)))
    let expected = WindowAction.rightHalf.partition!.frame(in: system.mainDisplay.visibleFrame)
    #expect(await waitFor {
        guard let state = model.activeTabbedState, let pane = state.paneID(containing: id) else { return false }
        return state.logicalFrames(in: system.mainDisplay.visibleFrame)[pane]?.approximatelyEquals(expected, tolerance: 0.001) == true
    })
    #expect(model.activeTabbedState?.panes.count == 4)
}

@Test @MainActor func tabbedSnapHeldGestureSupersedesPendingPlacementAndQueuedWork() async throws {
    let (system, model) = try await snapFixture()
    defer { model.shutdown() }
    let before = try #require(model.activeTabbedState), id = system.windows[0].id, display = system.mainDisplay.id
    let target = try #require(model.captureLayoutWheelTarget())
    system.frameApplicationDelays[id] = .milliseconds(60)
    let writesBefore = system.frameWriteCounts[id, default: 0]
    model.performTabbed(.preset(.rows))
    try #require(await waitFor { system.frameWriteCounts[id, default: 0] > writesBefore })
    model.performLayoutWheel(.windowAction(.leftThird), for: target)
    try #require(model.beginBentoDrag(displayID: display, sourceID: id))
    let writesAtCapture = system.frameWriteCounts
    try await Task.sleep(for: .milliseconds(180)) // The old apply ends while the native gesture is still held.
    #expect(system.frameWriteCounts == writesAtCapture)
    #expect(model.activeTabbedState?.floatingWindowIDs.contains(id) == true)
    model.finishBentoDrag(displayID: display, sourceID: id,
        outcome: .snap(action: .rightHalf, frame: system.mainDisplay.visibleFrame))
    try #require(await waitFor { model.activeTabbedState?.panes[1].selected == id })
    #expect(model.activeTabbedState?.panes.count == 2)
    model.performTabbed(.undo)
    #expect(await waitFor { model.activeTabbedState == before })
}

/// The dragged window's center can cross to the neighbouring display while
/// the pointer shows a Tabbed drop. The drop still lands on the Tabbed
/// display, and no participant check degrades it.
@Test(arguments: ["snap", "center"]) @MainActor
func tabbedDropAfterTheSourceCenterCrossedIsNotDegraded(entry: String) async throws {
    let (system, model) = try await snapFixture()
    defer { model.shutdown() }
    let source = system.windows[0].id, right = system.windows[2].id
    let main = system.mainDisplay.id
    let destination = try #require(model.activeTabbedState?.panes[1].id)
    let second = DisplayID(rawValue: "second")
    system.availableDisplays.append(DisplaySnapshot(id: second,
        frame: BTRect(x: 1000, y: 0, width: 1000, height: 800),
        visibleFrame: BTRect(x: 1000, y: 0, width: 1000, height: 800)))
    let frame = try #require(StandardActionEngine().targetFrame(for: .rightHalf,
        window: system.windows[0], display: system.mainDisplay))
    try #require(model.beginBentoDrag(displayID: main, sourceID: source))
    // macOS moved the window with the pointer: its center is now on the
    // second display, while the pointer is still on the Tabbed display.
    let index = try #require(system.windows.firstIndex { $0.id == source })
    system.windows[index].frame.origin.x = 1050 - system.windows[index].frame.size.width / 2
    system.windows[index].displayID = second
    model.finishBentoDrag(displayID: main, sourceID: source,
        outcome: entry == "snap" ? .snap(action: .rightHalf, frame: frame) : .swap(targetWindowID: right))
    #expect(await waitFor(timeout: .seconds(2)) {
        model.activeTabbedState?.panes.first { $0.id == destination }?.selected == source
    })
    #expect(model.statusMessage == nil, "\(model.statusMessage ?? "")")
    let placed = try #require(system.windows.first { $0.id == source })
    #expect(placed.displayID == main)
    #expect(PlacementBounds.isContained(placed.frame, in: system.mainDisplay.visibleFrame))
}

/// A Tabbed center drop is fitted when the overlay shows it. Release commits
/// those panes. A tab that cannot show in the pane joins it hidden.
@Test(arguments: [600.0, 1100.0]) @MainActor
func tabbedCenterDropIsFittedByItsPreview(sourceMinimumWidth: Double) async throws {
    let (system, model) = try await snapFixture()
    defer { model.shutdown() }
    let source = system.windows[0].id, right = system.windows[2].id
    let main = system.mainDisplay.id, bounds = system.mainDisplay.visibleFrame
    let destination = try #require(model.activeTabbedState?.panes[1].id)
    system.windows[0].constraints.minimumSize.width = sourceMinimumWidth
    try #require(model.beginBentoDrag(displayID: main, sourceID: source))
    let preview = model.previewBentoDrag(displayID: main, sourceID: source, outcome: .swap(targetWindowID: right))
    guard case let .ready(plan)? = preview, let fitted = plan.tabbedState else {
        Issue.record("Expected a fitted center drop"); return
    }
    let fits = sourceMinimumWidth < bounds.size.width
    let fittedFrames = fitted.logicalFrames(in: bounds)
    if fits { #expect((fittedFrames[destination]?.size.width ?? 0) >= sourceMinimumWidth) }
    model.finishBentoDrag(displayID: main, sourceID: source, end: .commit(plan))
    #expect(await waitFor(timeout: .seconds(2)) {
        guard let pane = model.activeTabbedState?.panes.first(where: { $0.id == destination }) else { return false }
        return pane.tabs.contains(source) && pane.selected == (fits ? source : right)
    })
    #expect(model.activeTabbedState?.logicalFrames(in: bounds) == fittedFrames)
}

/// A Tabbed snap commits with the constraints its overlay planned with. A
/// larger minimum read at release does not change or reject it.
@Test @MainActor func tabbedSnapIsNotVetoedByAMinimumReadAtRelease() async throws {
    let (system, model) = try await snapFixture()
    defer { model.shutdown() }
    let source = system.windows[0].id, main = system.mainDisplay.id
    let destination = try #require(model.activeTabbedState?.panes[1].id)
    let frame = try #require(StandardActionEngine().targetFrame(for: .rightHalf,
        window: system.windows[0], display: system.mainDisplay))
    try #require(model.beginBentoDrag(displayID: main, sourceID: source))
    guard case let .ready(plan)? = model.previewBentoDrag(displayID: main, sourceID: source,
                                                          outcome: .snap(action: .rightHalf, frame: frame)) else {
        Issue.record("Expected a snap plan"); return
    }
    system.windows[0].constraints.minimumSize.width = 700
    model.finishBentoDrag(displayID: main, sourceID: source, end: .commit(plan))
    #expect(await waitFor(timeout: .seconds(2)) {
        model.activeTabbedState?.panes.first { $0.id == destination }?.selected == source
    })
    #expect(model.statusMessage == nil, "\(model.statusMessage ?? "")")
}

/// A floating Tabbed window's snap must hold its minimum size, or the
/// overlay shows invalid feedback.
@Test @MainActor func floatingTabbedSnapChecksTheMinimumSize() async throws {
    let (system, model) = try await snapFixture()
    defer { model.shutdown() }
    let id = system.windows[0].id, main = system.mainDisplay.id
    model.performTabbed(.float(id))
    try #require(await waitFor { model.activeTabbedState?.floatingWindowIDs.contains(id) == true })
    try await Task.sleep(for: .milliseconds(200))
    let frame = try #require(StandardActionEngine().targetFrame(for: .almostMaximize,
        window: system.windows[0], display: system.mainDisplay))
    system.windows[0].constraints.minimumSize.width = frame.size.width + 20
    try #require(model.beginBentoDrag(displayID: main, sourceID: id, sourceFrame: system.windows[0].frame))
    let preview = model.previewBentoDrag(displayID: main, sourceID: id, outcome: .snap(action: .almostMaximize, frame: frame))
    #expect(preview == .invalid(reason: "The window’s minimum size does not fit in that snap area."))
    model.finishBentoDrag(displayID: main, sourceID: id, end: .restore)
}

/// A Tabbed drop whose layout changed during the drag writes nothing of its
/// plan. The dragged window takes its frame in the current arrangement.
@Test @MainActor func aStaleTabbedPlanPutsTheDraggedWindowInTheCurrentLayout() async throws {
    let (system, model) = try await snapFixture()
    defer { model.shutdown() }
    let source = system.windows[0].id, main = system.mainDisplay.id, bounds = system.mainDisplay.visibleFrame
    let frame = try #require(StandardActionEngine().targetFrame(for: .rightHalf,
        window: system.windows[0], display: system.mainDisplay))
    try #require(model.beginBentoDrag(displayID: main, sourceID: source))
    guard case let .ready(plan)? = model.previewBentoDrag(displayID: main, sourceID: source,
                                                          outcome: .snap(action: .rightHalf, frame: frame)) else {
        Issue.record("Expected a snap plan"); return
    }
    let before = try #require(model.activeTabbedState)
    let destination = before.panes[1].id
    // The Dock grows during the drag: the work area the plan was made for is gone.
    system.availableDisplays[0].visibleFrame.size.height -= 50
    let shrunk = system.availableDisplays[0].visibleFrame
    system.windows[0].frame.origin.x += 140
    model.finishBentoDrag(displayID: main, sourceID: source, end: .commit(plan))
    #expect(model.statusMessage?.hasPrefix("The layout changed during the drag.") == true, "\(model.statusMessage ?? "nil")")
    #expect(await waitFor(timeout: .seconds(3)) {
        guard let state = model.activeTabbedState,
              let placed = try? state.placements(in: shrunk, windows: system.windows)
                .first(where: { $0.windowID == source })?.frame else { return false }
        return system.windows[0].frame.approximatelyEquals(placed, tolerance: 1)
    }, "\(system.windows[0].frame)")
    // The plan's arrangement never applied: the source stays in its own pane.
    #expect(model.activeTabbedState?.panes.first { $0.id == destination }?.tabs.contains(source) == false)
    _ = bounds
}

/// Release over invalid feedback for a Tabbed tab restores the verified
/// checkpoint and the original group, and reports the reason.
@Test @MainActor func aFailedTabbedDropRestoresTheCheckpoint() async throws {
    let (system, model) = try await snapFixture()
    defer { model.shutdown() }
    let source = system.windows[0].id, main = system.mainDisplay.id
    let before = try #require(model.activeTabbedState), frames = system.windows.map(\.frame)
    try #require(model.beginBentoDrag(displayID: main, sourceID: source))
    system.windows[0].frame.origin.x += 140
    model.finishBentoDrag(displayID: main, sourceID: source, end: .failed(reason: "That pane cannot hold it."))
    #expect(await waitFor(timeout: .seconds(2)) { model.statusMessage == "That pane cannot hold it." })
    #expect(await waitFor(timeout: .seconds(2)) { system.windows.map(\.frame) == frames })
    #expect(model.activeTabbedState == before)
}

/// A Tabbed center drop onto a window outside every pane is invalid; it is
/// never planned as a Bento swap instead.
@Test @MainActor func aTabbedCenterDropOutsideAPaneIsInvalid() async throws {
    let (system, model) = try await snapFixture()
    defer { model.shutdown() }
    let source = system.windows[0].id, main = system.mainDisplay.id
    try #require(model.beginBentoDrag(displayID: main, sourceID: source))
    let preview = model.previewBentoDrag(displayID: main, sourceID: source,
                                         outcome: .swap(targetWindowID: WindowID(rawValue: "not-a-tab")))
    #expect(preview == .invalid(reason: "The layout changed during the drag. Try again."))
    model.finishBentoDrag(displayID: main, sourceID: source, end: .restore)
}

// MARK: - Dropping a window into a pane as a tab

/// Floats `id` and waits for its float placement to settle.
@MainActor private func float(_ id: WindowID, in model: BetterTileModel) async throws {
    model.performTabbed(.float(id))
    try #require(await waitFor { model.activeTabbedState?.floatingWindowIDs.contains(id) == true })
    try await Task.sleep(for: .milliseconds(200))
}

/// A floating window dropped on a pane's center becomes its selected tab.
/// Undo floats it again where it was before the drag.
@Test @MainActor func aFloatingWindowDroppedOnAPaneCenterBecomesItsSelectedTab() async throws {
    let (system, model) = try await snapFixture()
    defer { model.shutdown() }
    let source = system.windows[0].id, right = system.windows[2].id, main = system.mainDisplay.id
    try await float(source, in: model)
    let floated = try #require(model.activeTabbedState)
    let floatFrame = system.windows[0].frame
    let destination = floated.panes[1].id
    try #require(model.beginBentoDrag(displayID: main, sourceID: source, sourceFrame: floatFrame))
    system.windows[0].frame.origin.x += 140
    model.finishBentoDrag(displayID: main, sourceID: source, outcome: .swap(targetWindowID: right))
    #expect(await waitFor(timeout: .seconds(2)) {
        model.activeTabbedState?.panes.first { $0.id == destination }?.selected == source
    })
    #expect(model.activeTabbedState?.floatingWindowIDs.contains(source) == false)
    #expect(model.statusMessage == nil, "\(model.statusMessage ?? "")")
    model.performTabbed(.undo)
    #expect(await waitFor(timeout: .seconds(2)) { model.activeTabbedState == floated })
    #expect(await waitFor(timeout: .seconds(2)) { system.windows[0].frame.approximatelyEquals(floatFrame, tolerance: 1) },
            "\(system.windows[0].frame)")
}

/// A floating window too large to show in the pane joins it as a hidden
/// tab. The overlay shows that as a drop, not as invalid feedback, and the
/// panes keep their sizes.
@Test @MainActor func aFloatingWindowTooLargeForThePaneJoinsItHidden() async throws {
    let (system, model) = try await snapFixture()
    defer { model.shutdown() }
    let source = system.windows[0].id, right = system.windows[2].id, main = system.mainDisplay.id
    let bounds = system.mainDisplay.visibleFrame
    try await float(source, in: model)
    let floated = try #require(model.activeTabbedState)
    let destination = floated.panes[1].id
    system.windows[0].constraints.minimumSize.width = bounds.size.width + 100
    try #require(model.beginBentoDrag(displayID: main, sourceID: source, sourceFrame: system.windows[0].frame))
    guard case let .ready(plan)? = model.previewBentoDrag(displayID: main, sourceID: source,
                                                          outcome: .tab(paneID: destination, index: nil)),
          let state = plan.tabbedState else {
        Issue.record("A window that can join hidden is a drop"); return
    }
    #expect(state.pane(containing: source)?.selected == right)
    #expect(state.logicalFrames(in: bounds) == floated.logicalFrames(in: bounds))
    model.finishBentoDrag(displayID: main, sourceID: source, end: .commit(plan))
    #expect(await waitFor(timeout: .seconds(2)) {
        model.activeTabbedState?.panes.first { $0.id == destination }?.tabs == [right, source]
    })
    #expect(model.activeTabbedState?.panes.first { $0.id == destination }?.selected == right)
    #expect(model.activeTabbedState?.floatingWindowIDs.isEmpty == true)
    // The active pane keeps focus; the hidden tab does not take it.
    #expect(system.focusedID == model.activeTabbedState?.activeWindowID)
}

/// A tab strip drop inserts the window at the strip's index, whether it
/// floated or was a tab of another pane.
@Test(arguments: [0, 1, 2], [false, true]) @MainActor
func aTabStripDropInsertsTheWindowAtItsIndex(index: Int, floating: Bool) async throws {
    let (system, model) = try await snapFixture()
    defer { model.shutdown() }
    let source = system.windows[2].id, main = system.mainDisplay.id
    if floating { try await float(source, in: model) }
    let before = try #require(model.activeTabbedState)
    let destination = before.panes[0]
    #expect(destination.tabs.count == 2)
    try #require(model.beginBentoDrag(displayID: main, sourceID: source, sourceFrame: system.windows[2].frame))
    model.finishBentoDrag(displayID: main, sourceID: source, outcome: .tab(paneID: destination.id, index: index))
    var expected = destination.tabs
    expected.insert(source, at: index)
    #expect(await waitFor(timeout: .seconds(2)) {
        let pane = model.activeTabbedState?.panes.first { $0.id == destination.id }
        return pane?.tabs == expected && pane?.selected == source
    })
    #expect(model.activeTabbedState?.floatingWindowIDs.isEmpty == true)
    model.performTabbed(.undo)
    #expect(await waitFor(timeout: .seconds(2)) { model.activeTabbedState == before })
}

/// An empty pane is a drop target: the window becomes its tab.
@Test @MainActor func aWindowDroppedOnAnEmptyPaneBecomesItsTab() async throws {
    let (system, model) = try await snapFixture()
    defer { model.shutdown() }
    let right = system.windows[2].id, source = system.windows[0].id, main = system.mainDisplay.id
    try await float(right, in: model)
    let empty = try #require(model.activeTabbedState?.panes[1])
    #expect(empty.tabs.isEmpty)
    try await float(source, in: model)
    try #require(model.beginBentoDrag(displayID: main, sourceID: source, sourceFrame: system.windows[0].frame))
    model.finishBentoDrag(displayID: main, sourceID: source, outcome: .tab(paneID: empty.id, index: nil))
    #expect(await waitFor(timeout: .seconds(2)) {
        model.activeTabbedState?.panes.first { $0.id == empty.id }?.selected == source
    })
    #expect(model.activeTabbedState?.floatingWindowIDs == [right])
}

/// A floating window released where the overlay showed no committable drop,
/// nothing or invalid feedback, stays floating where the user dropped it. No
/// write returns it to where the drag started.
@Test(arguments: [false, true]) @MainActor
func aFloatingWindowReleasedWithoutADropStaysWhereItWasDropped(invalid: Bool) async throws {
    let (system, model) = try await snapFixture()
    defer { model.shutdown() }
    let source = system.windows[0].id, main = system.mainDisplay.id
    try await float(source, in: model)
    let floated = try #require(model.activeTabbedState)
    try #require(model.beginBentoDrag(displayID: main, sourceID: source, sourceFrame: system.windows[0].frame))
    system.windows[0].frame.origin.x += 140
    let dropped = system.windows[0].frame
    let writes = system.frameWriteCounts[source, default: 0]
    model.finishBentoDrag(displayID: main, sourceID: source, end: invalid ? .failed(reason: "No pane") : .restore)
    try await Task.sleep(for: .milliseconds(200))
    #expect(model.activeTabbedState == floated)
    #expect(system.windows[0].frame == dropped)
    #expect(system.frameWriteCounts[source, default: 0] == writes)
}

/// A committed tab drop whose placement fails leaves a floating window where
/// it was dropped, not where the drag started, and reports the failure.
@Test @MainActor func aFailedTabDropLeavesAFloatingWindowWhereItWasDropped() async throws {
    let (system, model) = try await snapFixture()
    defer { model.shutdown() }
    let source = system.windows[0].id, right = system.windows[2].id, main = system.mainDisplay.id
    try await float(right, in: model)
    let empty = try #require(model.activeTabbedState?.panes[1])
    try await float(source, in: model)
    let floated = try #require(model.activeTabbedState)
    let start = system.windows[0].frame
    try #require(model.beginBentoDrag(displayID: main, sourceID: source, sourceFrame: start))
    system.windows[0].frame.origin = BTPoint(x: start.minX + 140, y: start.minY + 60)
    let dropped = system.windows[0].frame
    guard case let .ready(plan)? = model.previewBentoDrag(displayID: main, sourceID: source,
                                                          outcome: .tab(paneID: empty.id, index: nil)) else {
        Issue.record("An empty pane is a drop"); return
    }
    system.failedFrameWriteNumbers[source] = [system.frameWriteCounts[source, default: 0] + 1]
    model.finishBentoDrag(displayID: main, sourceID: source, end: .commit(plan))
    #expect(await waitFor(timeout: .seconds(2)) { model.statusMessage != nil })
    try await Task.sleep(for: .milliseconds(200))
    #expect(system.windows[0].frame == dropped, "\(system.windows[0].frame)")
    #expect(model.activeTabbedState == floated)
}

/// A window that resizes in steps, such as Terminal, can settle a row taller
/// than its pane. A tab drop then fits the panes again with that size, as any
/// Tabbed placement does, into an empty pane and through a tab strip.
@Test(arguments: [false, true]) @MainActor
func aSteppedFloatingWindowJoinsAPaneByDrop(throughStrip: Bool) async throws {
    let (system, model) = try await snapFixture(preset: .rows)
    defer { model.shutdown() }
    let source = system.windows[0].id, right = system.windows[2].id, main = system.mainDisplay.id
    let destination = try #require(model.activeTabbedState?.panes[1])
    if throughStrip {
        model.performTabbed(.move(right, pane: destination.id, index: nil))
        try #require(await waitFor { model.activeTabbedState?.panes[1].selected == right })
    }
    try await float(source, in: model)
    system.widthSteps[source] = 7
    system.heightSteps[source] = 17
    // Its floating frame is already on its cell grid.
    system.windows[0].frame.size = BTSize(width: 595, height: 408)
    try #require(model.beginBentoDrag(displayID: main, sourceID: source, sourceFrame: system.windows[0].frame))
    system.windows[0].frame.origin.x += 140
    model.finishBentoDrag(displayID: main, sourceID: source,
                          outcome: .tab(paneID: destination.id, index: throughStrip ? 0 : nil))
    #expect(await waitFor(timeout: .seconds(2)) {
        model.activeTabbedState?.panes.first { $0.id == destination.id }?.selected == source
    })
    try await Task.sleep(for: .milliseconds(300))
    #expect(model.statusMessage == nil, "\(model.statusMessage ?? "")")
    #expect(model.activeTabbedState?.floatingWindowIDs.contains(source) == false)
    // The pane grew to the height the window settled at.
    let pane = try #require(model.activeTabbedState?.frames(in: system.mainDisplay.visibleFrame)[destination.id])
    #expect(TabbedLayoutState.contentFrame(pane).size.height + 0.5 >= system.windows[0].frame.size.height)
}

/// A snap drag commits exactly the snap its overlay showed. When the window
/// refuses that size, the drop fails; it is not planned again with the size
/// the window revealed.
@Test @MainActor func aRefusedSnapDragIsNotPlannedAgain() async throws {
    let (system, model) = try await snapFixture()
    defer { model.shutdown() }
    let source = system.windows[0].id, main = system.mainDisplay.id
    let before = try #require(model.activeTabbedState)
    let frame = try #require(StandardActionEngine().targetFrame(for: .rightHalf,
        window: system.windows[0], display: system.mainDisplay))
    try #require(model.beginBentoDrag(displayID: main, sourceID: source))
    guard case let .ready(plan)? = model.previewBentoDrag(displayID: main, sourceID: source,
                                                          outcome: .snap(action: .rightHalf, frame: frame)),
          let planned = plan.placements.first(where: { $0.windowID == source })?.frame else {
        Issue.record("Expected a snap plan"); return
    }
    // The window settles a row taller than any frame it is asked for.
    system.heightSteps[source] = 17
    system.windows[0].frame.origin.x += 140
    model.finishBentoDrag(displayID: main, sourceID: source, end: .commit(plan))
    #expect(await waitFor(timeout: .seconds(3)) { model.statusMessage != nil })
    try await Task.sleep(for: .milliseconds(300))
    #expect(system.requestedFrames[source]?.filter { $0 == planned }.count == 1, "\(system.requestedFrames[source] ?? [])")
    #expect(model.activeTabbedState?.panes.map(\.tabs) == before.panes.map(\.tabs))
}
