import AppKit
import BetterTileCore
import BetterTileMacOS
import Testing
@testable import BetterTileApp

@Test(.appTestApplication) @MainActor func groupedWheelSettingsSwitchKeepsEveryCustomAssignment() {
    let system = FakeAppWindowSystem()
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.updateConfiguration {
        $0.layoutWheel.innerSlots[0] = nil
        $0.layoutWheel.outerSlots[5] = .windowAction(.moveDown)
        $0.layoutWheel.levelCount = .one
        $0.layoutWheel.scale = 0.85
    }
    let custom = model.configuration.layoutWheel
    model.updateConfiguration { $0.layoutWheel.style = .grouped }
    #expect(model.configuration.layoutWheel.effectiveLevelCount == .one)
    #expect(system.frameWriteCounts.isEmpty)
    model.updateConfiguration { $0.layoutWheel.style = .custom }
    #expect(model.configuration.layoutWheel == custom)
}

@Test(.appTestApplication, arguments: [LayoutMode.manual, .bento, .tabbed]) @MainActor
func groupedWheelModeUsesMenuBarModelFunction(_ mode: LayoutMode) async throws {
    _ = NSApplication.shared
    let wheelSystem = FakeAppWindowSystem(), menuSystem = FakeAppWindowSystem()
    let wheel = makeModel(system: wheelSystem), menu = makeModel(system: menuSystem)
    defer { wheel.shutdown(); menu.shutdown() }
    let target = try #require(wheel.captureLayoutWheelTarget())
    #expect(wheel.previewLayoutWheel(.setMode(mode), for: target) == .ready(placements: []))
    #expect(wheelSystem.frameWriteCounts.isEmpty)
    wheel.performLayoutWheel(.setMode(mode), for: target)
    menu.setActiveMode(mode)
    #expect(wheel.activeMode(for: target.displayID) == menu.activeMode(for: target.displayID))
    #expect(wheel.activeMode(for: target.displayID) == mode)
    if mode == .tabbed {
        try #require(await waitFor { wheel.activeTabbedState != nil && menu.activeTabbedState != nil })
        #expect(wheel.activeTabbedState?.panes.count == menu.activeTabbedState?.panes.count)
    }
}

@Test(.appTestApplication, arguments: TabbedPreset.allCases) @MainActor
func groupedWheelChooseLayoutUsesGalleryIntentAndPreservesGroups(_ preset: TabbedPreset) async throws {
    _ = NSApplication.shared
    let system = FakeAppWindowSystem()
    let model = makeModel(system: system)
    defer { model.shutdown() }
    var target = try #require(model.captureLayoutWheelTarget())
    #expect(model.previewLayoutWheel(.chooseLayout(preset), for: target) == .unavailable(reason: "Choose Layout needs a Tabbed desktop."))
    let before = system.windows
    model.performLayoutWheel(.chooseLayout(preset), for: target)
    #expect(system.windows == before)
    model.setActiveMode(.tabbed)
    try #require(await waitFor { model.activeTabbedState != nil })
    target = try #require(model.captureLayoutWheelTarget())
    #expect(model.previewLayoutWheel(.chooseLayout(preset), for: target) == .ready(placements: []))
    let groups = model.activeTabbedState?.panes.map(\.tabs)
    model.performLayoutWheel(.chooseLayout(preset), for: target)
    try #require(await waitFor { model.activeTabbedState?.panes.count == preset.paneCount })
    let state = try #require(model.activeTabbedState)
    #expect(state.panes.count == preset.paneCount)
    #expect(state.panes.flatMap(\.tabs).count == groups?.flatMap { $0 }.count)
}

@Test(.appTestApplication) @MainActor func groupedWheelDesktopActionsRevalidateCapturedModeAndWindow() throws {
    let system = FakeAppWindowSystem()
    let model = makeModel(system: system)
    defer { model.shutdown() }
    let target = try #require(model.captureLayoutWheelTarget())
    model.setActiveMode(.tabbed)
    model.performLayoutWheel(.setMode(.manual), for: target)
    #expect(model.activeMode(for: target.displayID) == .tabbed)
    let current = try #require(model.captureLayoutWheelTarget())
    system.windows = []
    model.performLayoutWheel(.setMode(.manual), for: current)
    #expect(model.activeMode(for: target.displayID) == .tabbed)
}

@Test(.appTestApplication) @MainActor func groupedWheelEmptyDesktopHasARealDisplayTarget() async throws {
    _ = NSApplication.shared
    let system = FakeAppWindowSystem()
    system.windows = []
    let model = makeModel(system: system)
    defer { model.shutdown() }
    #expect(model.captureLayoutWheelTarget() == nil) // Custom retains its capture contract.
    model.updateConfiguration { $0.layoutWheel.style = .grouped }
    let target = try #require(model.captureLayoutWheelTarget())
    #expect(target.windowID == nil)
    #expect(target.displayID == system.mainDisplay.id)
    #expect(model.previewLayoutWheel(.windowAction(.maximize), for: target) == .unavailable(reason: "No eligible focused window."))
    model.performLayoutWheel(.setMode(.tabbed), for: target)
    #expect(model.activeMode(for: target.displayID) == .tabbed)
    try #require(await waitFor { model.activeTabbedState != nil })
    let tabbed = try #require(model.captureLayoutWheelTarget())
    model.performLayoutWheel(.chooseLayout(.grid), for: tabbed)
    #expect(await waitFor { model.activeTabbedState?.panes.count == 4 })
    #expect(system.frameWriteCounts.isEmpty)
}

@Test(.appTestApplication, arguments: [LayoutMode.manual, .tabbed], [false, true]) @MainActor
func groupedWheelAdaptiveOnEmptyCapturedDesktopSucceeds(from mode: LayoutMode, focusChanges: Bool) async throws {
    _ = NSApplication.shared
    let system = FakeAppWindowSystem()
    system.windows = []
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.updateConfiguration { $0.layoutWheel.style = .grouped }
    if mode == .tabbed {
        model.setActiveMode(.tabbed)
        try #require(await waitFor { model.activeTabbedState != nil && !model.hasPendingTabbedPlacement })
    }
    let target = try #require(model.captureLayoutWheelTarget())
    #expect(target.windowID == nil)
    if focusChanges {
        let other = DisplaySnapshot(id: DisplayID(rawValue: "other"),
            frame: BTRect(x: 1000, y: 0, width: 1000, height: 800),
            visibleFrame: BTRect(x: 1000, y: 0, width: 1000, height: 800), isMain: false)
        system.availableDisplays.append(other)
        system.windows.append(WindowSnapshot(id: WindowID(rawValue: "new-focus"), processIdentifier: 43,
            frame: BTRect(x: 1100, y: 100, width: 500, height: 400), displayID: other.id))
        system.focusedID = system.windows[0].id
    }
    model.performLayoutWheel(.setMode(.bento), for: target)
    #expect(await waitFor { model.activeMode(for: target.displayID) == .bento })
    #expect(model.statusMessage == nil)
    #expect(model.lastActionFeedback?.kind == .success)
    #expect(system.frameWriteCounts.isEmpty)
}

@Test(.appTestApplication, arguments: [LayoutMode.manual, .tabbed]) @MainActor
func groupedWheelAdaptiveUsesCapturedDisplayAfterFocusChanges(from mode: LayoutMode) async throws {
    _ = NSApplication.shared
    let system = FakeAppWindowSystem()
    let other = DisplaySnapshot(id: DisplayID(rawValue: "other"),
        frame: BTRect(x: 1000, y: 0, width: 1000, height: 800),
        visibleFrame: BTRect(x: 1000, y: 0, width: 1000, height: 800), isMain: false)
    system.availableDisplays.append(other)
    let captured = system.windows[0].id
    system.windows.append(WindowSnapshot(id: WindowID(rawValue: "other-window"), processIdentifier: 43,
        frame: BTRect(x: 1100, y: 100, width: 500, height: 400), displayID: other.id))
    let model = makeModel(system: system)
    defer { model.shutdown() }
    if mode == .tabbed {
        model.setActiveMode(.tabbed)
        try #require(await waitFor { model.activeTabbedState != nil && !model.hasPendingTabbedPlacement })
    }
    let target = try #require(model.captureLayoutWheelTarget())
    system.frameWriteCounts.removeAll()
    system.focusedID = system.windows[1].id
    let otherFrame = system.windows[1].frame
    model.performLayoutWheel(.setMode(.bento), for: target)
    #expect(await waitFor { model.activeMode(for: target.displayID) == .bento })
    #expect(model.activeMode(for: other.id) != .bento)
    #expect(system.windows[0].frame == system.mainDisplay.visibleFrame)
    #expect(system.frameWriteCounts[captured, default: 0] > 0)
    #expect(system.windows[1].frame == otherFrame)
    #expect(system.frameWriteCounts[system.windows[1].id, default: 0] == 0)
    #expect(model.statusMessage == nil)
}

// BetterTile's own windows are excluded by the window-system contract. A nil
// focus still permits a Grouped display target; an AX read error cancels capture
// in both styles. Neither path tests which one occurred in the live session.
@Test(.appTestApplication, arguments: [LayoutWheelStyle.custom, .grouped], [false, true]) @MainActor
func groupedWheelLiveTriageEmptyFocusAndReadFailure(style: LayoutWheelStyle, readFails: Bool) throws {
    let system = FakeAppWindowSystem()
    system.windows = []
    system.frontmostOverride = Int32(ProcessInfo.processInfo.processIdentifier)
    system.focusedWindowReadFails = readFails
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.updateConfiguration { $0.layoutWheel.style = style }
    let target = model.captureLayoutWheelTarget()
    if style == .grouped && !readFails {
        let captured = try #require(target)
        #expect(captured.windowID == nil)
        #expect(captured.displayID == system.mainDisplay.id)
        #expect(model.previewLayoutWheel(.setMode(.manual), for: captured) == .ready(placements: []))
    } else {
        #expect(target == nil)
    }
    #expect(system.frameWriteCounts.isEmpty)
}

/// With no eligible window, Grouped targets the display under the point the
/// wheel opens at. The controller supplies that point in top-left
/// coordinates; the model never reads the live pointer.
@Test(.appTestApplication) @MainActor func groupedWheelWithoutAWindowTargetsTheDisplayUnderTheWheelPointer() throws {
    let system = FakeAppWindowSystem()
    system.windows = []
    // Far from any real screen, and left of and above the main display.
    let left = DisplaySnapshot(id: DisplayID(rawValue: "left"),
                               frame: BTRect(x: -51_600, y: -200, width: 1600, height: 1000),
                               visibleFrame: BTRect(x: -51_600, y: -175, width: 1600, height: 975))
    system.availableDisplays.append(left)
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.updateConfiguration { $0.layoutWheel.style = .grouped }
    let onLeft = try #require(model.captureLayoutWheelTarget(pointer: BTPoint(x: -50_000, y: -100)))
    #expect(onLeft.windowID == nil && onLeft.displayID == left.id)
    #expect(onLeft.visibleFrame == left.visibleFrame)
    let onMain = try #require(model.captureLayoutWheelTarget(pointer: BTPoint(x: 500, y: 400)))
    #expect(onMain.displayID == system.mainDisplay.id)
    #expect(system.frameWriteCounts.isEmpty)
}
