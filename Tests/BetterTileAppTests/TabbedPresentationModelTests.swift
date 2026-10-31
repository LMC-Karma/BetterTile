import AppKit
import BetterTileCore
@testable import BetterTileMacOS
import Testing
@testable import BetterTileApp

@Test(.appTestApplication) @MainActor func switchingTabBarPresentationRefitsOnceAndShowCommandDoesNotWriteFrames() async throws {
    _ = NSApplication.shared
    let system = FakeAppWindowSystem()
    let store = ConfigurationStore(fileURL: URL(filePath: "/tmp/BetterTileStripTests-\(UUID().uuidString)/configuration.json"))
    let model = makeOffscreenModel(store: store, system: system, startRuntime: false, presentsTabbedChrome: true)
    model.primaryButtonIsPressed = { false }
    defer { model.shutdown() }
    model.setActiveMode(.tabbed)
    try #require(await waitFor { model.activeTabbedState?.windowIDs.count == 1 && system.windows[0].frame.minY == 34 })
    try await waitForWindowEventsToDrain(model)
    await model.tabbedFocusTask?.value
    for presentation in [TabbedStripPresentation.compact, .autoHide, .alwaysVisible] {
        let writes = system.frameWriteCounts[system.windows[0].id, default: 0]
        model.updateConfiguration { $0.tabbedStripPresentation = presentation }
        try #require(await waitFor { model.activeTabbedState?.presentation == presentation && system.windows[0].frame.minY == presentation.reservedInset })
        try await waitForWindowEventsToDrain(model)
        await model.tabbedFocusTask?.value
        #expect(system.frameWriteCounts[system.windows[0].id, default: 0] == writes + 1)
        let state = model.activeTabbedState
        let settledWrites = system.frameWriteCounts
        model.perform(.showTabBar)
        #expect(model.statusMessage == nil)
        model.updateConfiguration { $0.tabbedStripPresentation = presentation }
        try await waitForWindowEventsToDrain(model)
        await model.tabbedFocusTask?.value
        #expect(model.activeTabbedState == state)
        #expect(system.frameWriteCounts == settledWrites)
    }
}

@Test(.appTestApplication) @MainActor func showTabBarOutsideTabbedDoesNotRunWindowPlacement() {
    let system = FakeAppWindowSystem()
    let model = makeModel(system: system)
    defer { model.shutdown() }
    let frames = system.windows.map(\.frame)
    model.perform(.showTabBar)
    #expect(model.statusMessage == "Show Tab Bar is available on a Tabbed desktop.")
    #expect(system.windows.map(\.frame) == frames)
    #expect(system.frameWriteCounts.isEmpty)
    #expect(WindowActionGroup.tabs.actions == [.showTabBar] + WindowAction.tabCommands)
}

@Test(.appTestApplication) @MainActor func impossiblePresentationReserveKeepsThePreviousLayoutWithoutFrameWrites() async throws {
    let system = FakeAppWindowSystem()
    system.windows[0].constraints.minimumSize.height = 790
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.configuration.tabbedStripPresentation = .autoHide
    model.setActiveMode(.tabbed)
    try #require(await waitFor { model.activeTabbedState?.windowIDs.count == 1 && system.windows[0].frame.minY == 6 })
    try await waitForWindowEventsToDrain(model)
    await model.tabbedFocusTask?.value
    let state = model.activeTabbedState
    let frames = system.windows.map(\.frame)
    let writes = system.frameWriteCounts
    model.updateConfiguration { $0.tabbedStripPresentation = .alwaysVisible }
    #expect(model.statusMessage != nil)
    try await waitForWindowEventsToDrain(model)
    await model.tabbedFocusTask?.value
    #expect(model.activeTabbedState == state)
    #expect(system.windows.map(\.frame) == frames)
    #expect(system.frameWriteCounts == writes)
}

@Test(.appTestApplication) @MainActor func showTabBarExplainsDividerActivityWithoutFrameWrites() async throws {
    _ = NSApplication.shared
    let system = FakeAppWindowSystem()
    var other = system.windows[0]
    other.id = WindowID(rawValue: "other")
    other.processIdentifier += 1
    system.windows.append(other)
    let store = ConfigurationStore(fileURL: URL(filePath: "/tmp/BetterTileStripTests-\(UUID().uuidString)/configuration.json"))
    let model = makeOffscreenModel(store: store, system: system, startRuntime: false, presentsTabbedChrome: true)
    model.primaryButtonIsPressed = { false }
    defer { model.shutdown() }
    model.configuration.defaultTabbedPreset = .columns
    model.setActiveMode(.tabbed)
    try #require(await waitFor { model.activeTabbedState?.windowIDs.count == 2 })
    let right = try #require(model.activeTabbedState?.panes[1].id)
    model.performTabbed(.move(system.windows[1].id, pane: right, index: nil))
    try #require(await waitFor { model.activeTabbedState?.panes[1].selected == system.windows[1].id })
    try await waitForWindowEventsToDrain(model)
    await model.tabbedFocusTask?.value
    let presentation = model.dividerPresentation(windows: system.windows)
    model.dividerResize.refresh(boundaries: presentation.boundaries, obscuringFrames: presentation.obscuringFrames)
    let start = BTPoint(x: system.mainDisplay.visibleFrame.midX, y: system.mainDisplay.visibleFrame.midY)
    let interaction = try #require(DividerInteractionResolver.resolve(
        at: start, in: presentation.boundaries, hitWidth: 18, adjacencyTolerance: 6,
        paneGap: model.configuration.bentoInnerGap))
    // Concurrent tests share NSApp.windows; another test's panel must not cover this grip.
    model.dividerResize.ownWindowsProvider = { [] }
    model.dividerResize.beginGesture(interaction: interaction, at: start)
    try #require(model.dividerResize.isDragging)
    let writes = system.frameWriteCounts
    model.perform(.showTabBar)
    #expect(model.statusMessage == "Finish the divider drag first.")
    #expect(system.frameWriteCounts == writes)
}

@Test(.appTestApplication, arguments: [0.0, 10.0]) @MainActor
func showTabBarExplainsOcclusionWithoutFrameWrites(coverTop: Double) async throws {
    _ = NSApplication.shared
    let system = FakeAppWindowSystem()
    var other = system.windows[0]
    other.id = WindowID(rawValue: "other")
    other.processIdentifier += 1
    system.windows.append(other)
    let store = ConfigurationStore(fileURL: URL(filePath: "/tmp/BetterTileStripTests-\(UUID().uuidString)/configuration.json"))
    let model = makeOffscreenModel(store: store, system: system, startRuntime: false, presentsTabbedChrome: true)
    model.primaryButtonIsPressed = { false }
    defer { model.shutdown() }
    model.configuration.tabbedStripPresentation = .autoHide
    model.setActiveMode(.tabbed)
    try #require(await waitFor { model.activeTabbedState?.windowIDs.count == 2 })
    let floating = system.windows[1].id
    model.performTabbed(.float(floating))
    try #require(await waitFor { model.activeTabbedState?.floatingWindowIDs.contains(floating) == true })
    try await waitForWindowEventsToDrain(model)
    await model.tabbedFocusTask?.value
    system.windows[1].frame = BTRect(x: 100, y: coverTop, width: 500, height: 300)
    system.focusedID = floating
    model.handleApplicationActivation()
    let queries = system.windowNumberRequests.count
    try #require(await waitFor { system.windowNumberRequests.count > queries })
    let writes = system.frameWriteCounts
    model.perform(.showTabBar)
    #expect(model.statusMessage == "The tab bar is covered by another window.")
    #expect(system.frameWriteCounts == writes)
}

@Test(.appTestApplication) @MainActor func tabbedUndoUsesCurrentPresentationAfterSettingChange() async throws {
    let system = FakeAppWindowSystem()
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.configuration.defaultTabbedPreset = .single
    model.setActiveMode(.tabbed)
    try #require(await waitFor { model.activeTabbedState?.panes.count == 1 && !model.hasPendingTabbedPlacement })
    let originalPane = try #require(model.activeTabbedState?.panes.first?.id)
    model.performTabbed(.preset(.columns))
    try #require(await waitFor { model.activeTabbedState?.panes.count == 2 && !model.hasPendingTabbedPlacement })
    model.updateConfiguration { $0.tabbedStripPresentation = .autoHide }
    try #require(await waitFor { model.activeTabbedState?.presentation == .autoHide && !model.hasPendingTabbedPlacement })
    model.performTabbed(.undo)
    try #require(await waitFor { model.activeTabbedState?.panes.count == 1 && !model.hasPendingTabbedPlacement })
    let restored = try #require(model.activeTabbedState)
    #expect(restored.panes.first?.id == originalPane)
    #expect(model.configuration.tabbedStripPresentation == .autoHide)
    #expect(restored.presentation == .autoHide)
    #expect(system.windows[0].frame.minY == TabbedStripPresentation.autoHide.reservedInset)
    #expect(system.windows[0].frame.size.height == system.mainDisplay.visibleFrame.size.height - TabbedStripPresentation.autoHide.reservedInset)
}
