import AppKit
import BetterTileCore
import BetterTileMacOS
import Testing
@testable import BetterTileApp

@Test @MainActor func requestedTabbedSnapJoinsExistingRightPane() async throws {
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
    model.perform(.rightHalf)
    #expect(await waitFor(timeout: .seconds(1)) {
        model.activeTabbedState?.panes.first { $0.id == destination }?.tabs == [window]
    })
    #expect(model.activeTabbedState?.panes.first { $0.id == destination }?.selected == window)
    #expect(model.statusMessage == nil)
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
    try #require(await waitFor { model.activeTabbedState?.panes[1].selected == target.windowID })
    for placement in placements {
        #expect(system.windows.first { $0.id == placement.windowID }?.frame == placement.frame)
    }
    #expect(model.activeTabbedState?.panes[1].tabs == [system.windows[2].id, target.windowID])
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
    guard case .unavailable = model.previewLayoutWheel(.windowAction(action), for: target) else {
        Issue.record("An unsupported member action was previewed"); return
    }
    model.performLayoutWheel(.windowAction(action), for: target)
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

@Test(arguments: [TabbedPreset.single, .grid])
@MainActor func tabbedSnapCreatesExactPanePreservesOldPanesAndUndoesOnce(preset: TabbedPreset) async throws {
    let (system, model) = try await snapFixture(preset: preset)
    defer { model.shutdown() }
    let before = try #require(model.activeTabbedState), id = system.windows[0].id
    model.perform(.rightHalf)
    try #require(await waitFor { model.activeTabbedState?.panes.count == before.panes.count + 1 })
    let after = try #require(model.activeTabbedState), destination = try #require(after.paneID(containing: id))
    #expect(Set(before.panes.map(\.id)).isSubset(of: Set(after.panes.map(\.id))))
    #expect(after.logicalFrames(in: system.mainDisplay.visibleFrame)[destination] == WindowAction.rightHalf.partition?.frame(in: system.mainDisplay.visibleFrame))
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
    try #require(model.completeBentoDrag(displayID: system.mainDisplay.id, sourceID: id,
        outcome: .snap(action: .rightHalf, frame: system.mainDisplay.visibleFrame), sourceFrame: frame))
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
