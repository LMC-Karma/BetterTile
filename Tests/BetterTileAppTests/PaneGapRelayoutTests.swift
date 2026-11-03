import AppKit
import BetterTileCore
import BetterTileTestSupport
@testable import BetterTileMacOS
import Testing
@testable import BetterTileApp

@MainActor
private func paneGapSystem() -> FakeAppWindowSystem {
    let system = FakeAppWindowSystem()
    system.windows[0].frame = BTRect(x: 0, y: 0, width: 500, height: 800)
    system.windows.append(WindowSnapshot(
        id: WindowID(rawValue: "peer"), processIdentifier: 43,
        frame: BTRect(x: 500, y: 0, width: 500, height: 800), displayID: system.mainDisplay.id
    ))
    return system
}

@Test(.appTestApplication, .timeLimit(.minutes(5))) @MainActor func paneGapChangeMovesExistingAdaptiveWindows() async throws {
    _ = NSApplication.shared
    let system = paneGapSystem()
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.setActiveMode(.bento)
    try await waitForWindowEventsToDrain(model)
    model.updateConfiguration { $0.bentoInnerGap = 12 }
    #expect(await waitFor {
        let frames = system.windows.map(\.frame).sorted { $0.minX < $1.minX }
        return abs(frames[1].minX - frames[0].maxX - 12) < 0.01
    }, "Existing Adaptive panes must take the stored gap without another layout action.")
}

/// Uses the production coalescing delay with explicitly advanced test time.
@MainActor private final class PaneGapClock {
    let manual = ManualClock()
    var intervals: [Duration] = []
    var cancelledSleeps = 0

    func sleep(_ duration: Duration) async {
        intervals.append(duration)
        do { try await manual.sleep(for: duration) }
        catch { cancelledSleeps += 1 }
    }

    func advance() { manual.advance(by: .milliseconds(75)) }
}

@MainActor private func finishPaneGapInterval(_ model: BetterTileModel, clock: ManualClock) async throws {
    let task = try #require(model.paneGapRelayoutTask, "Changing the gap must schedule its coalescing interval")
    await clock.waitForSleepers(count: 1)
    clock.advance(by: .milliseconds(75))
    await task.value
}

@Test(.appTestApplication, .timeLimit(.minutes(5))) @MainActor func paneGapCoalescesEachIntervalAndAppliesTheFinalRelease() async throws {
    _ = NSApplication.shared
    let system = paneGapSystem()
    let model = makeModel(system: system)
    let clock = PaneGapClock()
    model.paneGapRelayoutSleep = { await clock.sleep($0) }
    defer { model.shutdown() }
    model.setActiveMode(.bento)
    try await waitForWindowEventsToDrain(model)
    let id = system.windows[0].id
    let baseline = system.frameWriteCounts[id, default: 0]
    model.paneGapEditingChanged(true)
    var buttonIsDown = true
    model.primaryButtonIsPressed = { buttonIsDown }
    for gap in 2...6 { model.updateConfiguration { $0.bentoInnerGap = Double(gap) } }
    try #require(await waitFor { clock.intervals.count == 1 && clock.manual.pendingSleepCount == 1 })
    #expect(clock.intervals == [.milliseconds(75)])
    #expect(system.frameWriteCounts[id, default: 0] == baseline)
    // An unrelated sweep must not publish the uncoalesced setting.
    model.watchdog()
    #expect(system.frameWriteCounts[id, default: 0] == baseline)
    clock.advance()
    try #require(await waitFor { system.frameWriteCounts[id, default: 0] == baseline + 1 })
    try await waitForWindowEventsToDrain(model)
    #expect(actualPaneGap(system) == 6)
    for gap in 7...10 { model.updateConfiguration { $0.bentoInnerGap = Double(gap) } }
    try #require(await waitFor { clock.intervals.count == 2 && clock.manual.pendingSleepCount == 1 })
    #expect(system.frameWriteCounts[id, default: 0] == baseline + 1)
    clock.advance()
    try #require(await waitFor { system.frameWriteCounts[id, default: 0] == baseline + 2 })
    try await waitForWindowEventsToDrain(model)
    #expect(actualPaneGap(system) == 10)
    model.updateConfiguration { $0.bentoInnerGap = 12 }
    try #require(await waitFor { clock.intervals.count == 3 && clock.manual.pendingSleepCount == 1 })
    buttonIsDown = false
    model.paneGapEditingChanged(false)
    #expect(actualPaneGap(system) == 12)
    #expect(system.frameWriteCounts[id, default: 0] == baseline + 3)
    clock.advance() // The cancelled interval cannot add another pass after release.
    try await waitForWindowEventsToDrain(model)
    #expect(system.frameWriteCounts[id, default: 0] == baseline + 3)
    #expect(clock.intervals == Array(repeating: .milliseconds(75), count: 3))
}

@MainActor private func actualPaneGap(_ system: FakeAppWindowSystem) -> Double {
    let frames = system.windows.map(\.frame).sorted { $0.minX < $1.minX }
    return frames[1].minX - frames[0].maxX
}

@Test(.appTestApplication, .timeLimit(.minutes(5))) @MainActor func paneGapLeavesManualDesktopsAlone() async throws {
    let system = paneGapSystem()
    let model = makeModel(system: system)
    let manual = ManualClock()
    model.paneGapRelayoutSleep = { try await manual.sleep(for: $0) }
    defer { model.shutdown() }
    model.setActiveMode(.manual)
    let frames = system.windows.map(\.frame)
    let writes = system.frameWriteCounts
    model.paneGapEditingChanged(true)
    model.updateConfiguration { $0.bentoInnerGap = 12 }
    try await finishPaneGapInterval(model, clock: manual)
    model.paneGapEditingChanged(false)
    #expect(system.windows.map(\.frame) == frames)
    #expect(system.frameWriteCounts == writes)
}

// This gesture installs a process-wide Escape monitor. Other native keyboard tests must wait.
@Test(.appTestApplication, .settingsUI, .timeLimit(.minutes(5))) @MainActor func paneGapWaitsForAUserDividerDrag() async throws {
    _ = NSApplication.shared
    let system = paneGapSystem()
    let model = makeModel(system: system)
    let clock = PaneGapClock()
    model.paneGapRelayoutSleep = { await clock.sleep($0) }
    defer { model.shutdown() }
    model.setActiveMode(.bento)
    try await waitForWindowEventsToDrain(model)
    let presentation = model.dividerPresentation(windows: system.windows)
    model.dividerResize.refresh(boundaries: presentation.boundaries, obscuringFrames: presentation.obscuringFrames)
    let start = BTPoint(x: 500, y: 400)
    let interaction = try #require(DividerInteractionResolver.resolve(
        at: start, in: presentation.boundaries, hitWidth: 18, adjacencyTolerance: 6,
        paneGap: model.configuration.bentoInnerGap))
    model.dividerResize.beginGesture(interaction: interaction, at: start)
    try #require(model.dividerResize.isDragging)
    let frames = system.windows.map(\.frame)
    let writes = system.frameWriteCounts
    model.paneGapEditingChanged(true)
    model.updateConfiguration { $0.bentoInnerGap = 6 }
    try #require(await waitFor { clock.intervals.count == 1 && clock.manual.pendingSleepCount == 1 })
    clock.advance()
    try #require(await waitFor { clock.intervals.count == 2 && clock.manual.pendingSleepCount == 1 })
    model.updateConfiguration { $0.bentoInnerGap = 12 }
    model.paneGapEditingChanged(false)
    try #require(await waitFor { clock.intervals.count == 3 && clock.manual.pendingSleepCount == 1 })
    clock.advance()
    try #require(await waitFor { clock.intervals.count == 4 && clock.manual.pendingSleepCount == 1 })
    #expect(system.windows.map(\.frame) == frames)
    #expect(system.frameWriteCounts == writes)
    #expect(model.dividerResize.isDragging)
    model.dividerResize.cancelActiveGesture()
    clock.advance()
    try #require(await waitFor { actualPaneGap(system) == 12 })
    try await waitForWindowEventsToDrain(model)
    #expect(system.frameWriteCounts[system.windows[0].id, default: 0]
            == writes[system.windows[0].id, default: 0] + 1)
}

@Test(.appTestApplication, .timeLimit(.minutes(5))) @MainActor func paneGapLeavesTabbedPaneFramesAndStripReserveUnchanged() async throws {
    _ = NSApplication.shared
    let system = paneGapSystem()
    let model = makeModel(system: system)
    let manual = ManualClock()
    model.paneGapRelayoutSleep = { try await manual.sleep(for: $0) }
    defer { model.shutdown() }
    model.configuration.defaultTabbedPreset = .columns
    model.setActiveMode(.tabbed)
    try #require(await waitFor { model.activeTabbedState?.windowIDs.count == 2 && !model.hasPendingTabbedPlacement })
    #expect(model.activeTabbedState?.layout.metrics.paneGap == TabbedLayoutState.gap)
    let right = try #require(model.activeTabbedState?.panes[1].id)
    model.performTabbed(.move(system.windows[1].id, pane: right, index: nil))
    try #require(await waitFor { model.activeTabbedState?.panes[1].selected == system.windows[1].id && !model.hasPendingTabbedPlacement })
    let frames = system.windows.map(\.frame)
    let state = model.activeTabbedState
    let writes = system.frameWriteCounts
    model.paneGapEditingChanged(true)
    model.updateConfiguration { $0.bentoInnerGap = 12 }
    try await finishPaneGapInterval(model, clock: manual)
    model.paneGapEditingChanged(false)
    // Final release applies synchronously; there must be no interval left to advance.
    #expect(model.paneGapRelayoutTask == nil)
    #expect(system.windows.map(\.frame) == frames)
    #expect(system.frameWriteCounts == writes)
    #expect(model.activeTabbedState == state)
    #expect(model.activeTabbedState?.layout.metrics.paneGap == TabbedLayoutState.gap)
    #expect(system.windows.allSatisfy { $0.frame.minY == TabbedLayoutState.headerHeight })
}

@Test(.appTestApplication, .timeLimit(.minutes(5))) @MainActor func paneGapRespectsMinimumSizesAndRollsBackARejectedWrite() async throws {
    _ = NSApplication.shared
    let system = paneGapSystem()
    system.windows[0].frame.size.width = 600
    system.windows[0].constraints.minimumSize.width = 600
    system.windows[1].frame = BTRect(x: 600, y: 0, width: 400, height: 800)
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.setActiveMode(.bento)
    try await waitForWindowEventsToDrain(model)
    model.updateConfiguration { $0.bentoInnerGap = 12 }
    try #require(await waitFor { actualPaneGap(system) == 12 })
    try await waitForWindowEventsToDrain(model)
    #expect(system.windows[0].frame.size.width >= 600)
    #expect(system.windows.allSatisfy { PlacementBounds.isContained($0.frame, in: system.mainDisplay.visibleFrame) })
    let frames = system.windows.map(\.frame)
    let peer = system.windows[1].id
    system.failedFrameWriteNumbers[peer] = [system.frameWriteCounts[peer, default: 0] + 1]
    model.updateConfiguration { $0.bentoInnerGap = 6 }
    try #require(await waitFor { model.statusMessage != nil })
    #expect(system.windows.map(\.frame) == frames)
}

@Test(.appTestApplication, .timeLimit(.minutes(5))) @MainActor func paneGapOnlyReflowsManagedDisplays() async throws {
    let system = paneGapSystem()
    let second = DisplaySnapshot(id: DisplayID(rawValue: "manual"),
        frame: BTRect(x: 1000, y: 0, width: 1000, height: 800),
        visibleFrame: BTRect(x: 1000, y: 0, width: 1000, height: 800))
    system.availableDisplays.append(second)
    let untouched = WindowSnapshot(id: WindowID(rawValue: "manual-window"), processIdentifier: 44,
        frame: BTRect(x: 1100, y: 100, width: 600, height: 400), displayID: second.id)
    system.windows.append(untouched)
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.setActiveMode(.bento)
    try await waitForWindowEventsToDrain(model)
    try #require(model.activeMode(for: second.id) == .manual)
    let writes = system.frameWriteCounts[untouched.id, default: 0]
    let manualFrame = system.windows.first { $0.id == untouched.id }?.frame
    model.paneGapEditingChanged(true)
    model.updateConfiguration { $0.bentoInnerGap = 12 }
    model.paneGapEditingChanged(false)
    #expect(actualPaneGap(system) == 12)
    #expect(system.windows.first { $0.id == untouched.id }?.frame == manualFrame)
    #expect(system.frameWriteCounts[untouched.id, default: 0] == writes)
}

@Test(.appTestApplication, .timeLimit(.minutes(5))) @MainActor func paneGapFinalReleaseReappliesTheLastCoalescedValue() async throws {
    let system = paneGapSystem()
    let model = makeModel(system: system)
    let clock = PaneGapClock()
    model.paneGapRelayoutSleep = { await clock.sleep($0) }
    defer { model.shutdown() }
    model.setActiveMode(.bento)
    try await waitForWindowEventsToDrain(model)
    let id = system.windows[0].id
    let writes = system.frameWriteCounts[id, default: 0]
    model.paneGapEditingChanged(true)
    model.updateConfiguration { $0.bentoInnerGap = 12 }
    try #require(await waitFor { clock.intervals.count == 1 && clock.manual.pendingSleepCount == 1 })
    clock.advance()
    try #require(await waitFor { system.frameWriteCounts[id, default: 0] == writes + 1 })
    try await waitForWindowEventsToDrain(model)
    model.paneGapEditingChanged(false)
    #expect(actualPaneGap(system) == 12)
    #expect(system.frameWriteCounts[id, default: 0] == writes + 2)
}

@Test(.appTestApplication, .timeLimit(.minutes(5))) @MainActor func paneGapWaitsForUntrackedNativeWindowResize() async throws {
    let system = paneGapSystem()
    let model = makeModel(system: system)
    let clock = PaneGapClock()
    model.paneGapRelayoutSleep = { await clock.sleep($0) }
    defer { model.shutdown() }
    model.setActiveMode(.bento)
    try await waitForWindowEventsToDrain(model)
    let frames = system.windows.map(\.frame)
    let writes = system.frameWriteCounts
    // A native edge resize can own the button before a controller recognizes it,
    // including when drag snapping is off. Only the Settings slider may bypass this.
    var buttonIsDown = true
    model.primaryButtonIsPressed = { buttonIsDown }
    model.updateConfiguration { $0.bentoInnerGap = 12 }
    try #require(await waitFor { clock.intervals.count == 1 && clock.manual.pendingSleepCount == 1 })
    clock.advance()
    try #require(await waitFor { clock.intervals.count == 2 && clock.manual.pendingSleepCount == 1 })
    #expect(system.windows.map(\.frame) == frames)
    #expect(system.frameWriteCounts == writes)
    buttonIsDown = false
    clock.advance()
    try #require(await waitFor { actualPaneGap(system) == 12 })
}

@Test(.appTestApplication, .timeLimit(.minutes(5))) @MainActor func paneGapReleaseRetriesFailedInventoryOnTheNextRefresh() async throws {
    _ = NSApplication.shared
    let system = paneGapSystem()
    let model = makeModel(system: system)
    let clock = PaneGapClock()
    model.paneGapRelayoutSleep = { await clock.sleep($0) }
    defer { model.shutdown() }
    model.setActiveMode(.bento)
    try await waitForWindowEventsToDrain(model)
    let previousGap = actualPaneGap(system)
    model.paneGapEditingChanged(true)
    model.updateConfiguration { $0.bentoInnerGap = 12 }
    try #require(await waitFor { clock.intervals.count == 1 && clock.manual.pendingSleepCount == 1 })
    let sweeps = system.completeSweepCount
    system.failedVisibleWindowSweeps.insert(sweeps + 1)
    model.paneGapEditingChanged(false)
    #expect(system.completeSweepCount == sweeps + 1)
    #expect(actualPaneGap(system) == previousGap)
    // A second failed inventory must retain the same request too.
    system.failedVisibleWindowSweeps.insert(system.completeSweepCount + 1)
    model.watchdog()
    #expect(actualPaneGap(system) == previousGap)
    model.watchdog()
    try #require(await waitFor { actualPaneGap(system) == 12 && !model.hasPendingTabbedPlacement })
}

@Test(.appTestApplication, .timeLimit(.minutes(5))) @MainActor func paneGapShutdownCancelsPendingCoalescing() async throws {
    let system = paneGapSystem()
    let model = makeModel(system: system)
    let clock = PaneGapClock()
    model.paneGapRelayoutSleep = { await clock.sleep($0) }
    defer { model.shutdown() }
    model.setActiveMode(.bento)
    try await waitForWindowEventsToDrain(model)
    model.updateConfiguration { $0.bentoInnerGap = 12 }
    try #require(await waitFor { clock.intervals.count == 1 && clock.manual.pendingSleepCount == 1 })
    let pending = try #require(model.paneGapRelayoutTask)
    model.shutdown()
    let writes = system.frameWriteCounts
    let sweeps = system.completeSweepCount
    clock.advance()
    await pending.value
    #expect(system.frameWriteCounts == writes)
    #expect(system.completeSweepCount == sweeps)
    #expect(clock.intervals.count == 1)
    #expect(clock.cancelledSleeps == 1)
}
