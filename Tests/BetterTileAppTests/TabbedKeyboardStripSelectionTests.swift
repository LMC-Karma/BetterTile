import AppKit
import BetterTileCore
@testable import BetterTileMacOS
import Testing
@testable import BetterTileApp

@MainActor private func tabCommandStripFixture(count: Int = 3, preset: TabbedPreset = .columns,
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
    system.availableDisplays[0].frame.origin.x = 12000
    system.availableDisplays[0].visibleFrame.origin.x = 12000
    for index in system.windows.indices { system.windows[index].frame.origin.x += 12000 }
    let store = ConfigurationStore(fileURL: URL(filePath: "/tmp/bettertile-tab-strip-test-\(UUID().uuidString)/configuration.json"))
    let model = makeOffscreenModel(store: store, system: system, startRuntime: false, presentsTabbedChrome: true)
    model.primaryButtonIsPressed = { false }
    model.configuration.defaultTabbedPreset = preset
    model.setActiveMode(.tabbed)
    try #require(await waitFor { model.activeTabbedState?.windowIDs.count == count })
    model.performTabbed(.select(system.windows[0].id))
    try #require(await waitFor { model.activeTabbedState?.activeWindowID == system.windows[0].id })
    try #require(await waitFor { !model.hasPendingTabbedPlacement })
    await model.tabbedFocusTask?.value
    return (system, model)
}



@Test(.appTestApplication, arguments: [WindowAction.nextTab, .previousTab], ["space", "display", "publicDisplay", "floating", "sticky", "minimized", "closed", "unreadable"])
@MainActor func rejectedTabNavigationKeepsDisplayedSelection(action: WindowAction, change: String) async throws {
    let space = NativeSpaceID(rawValue: 1), elsewhere = NativeSpaceID(rawValue: 2)
    let (system, model) = try await tabCommandStripFixture(count: 2, nativeSpaceID: change == "publicDisplay" ? nil : space)
    defer { model.shutdown() }
    let target = try #require(model.captureLayoutWheelTarget())
    let before = try #require(model.activeTabbedState)
    let pane = try #require(NSApp.windows.compactMap(\.contentView).compactMap { $0 as? TabbedPaneView }
        .first { $0.pane.id == before.panes[0].id })
    let previous = try #require(before.panes[0].selected)
    let departed = system.windows[1].id
    switch change {
    case "space": system.desktopObservation?.windowMembership[departed] = [elsewhere]
    case "display", "publicDisplay":
        let display = DisplaySnapshot(id: DisplayID(rawValue: "other"),
            frame: BTRect(x: 14000, y: 0, width: 1000, height: 800),
            visibleFrame: BTRect(x: 14000, y: 0, width: 1000, height: 800))
        system.availableDisplays.append(display)
        system.desktopObservation?.currentSpaceByDisplay[display.id] = elsewhere
        system.desktopObservation?.knownSpacesByDisplay[display.id] = [elsewhere]
        system.desktopObservation?.windowMembership[departed] = [elsewhere]
        system.windows[1].displayID = display.id
        system.windows[1].frame.origin.x = 14100
    case "floating": system.windows[1].isFloating = true
    case "sticky": system.desktopObservation?.windowMembership[departed] = [space, elsewhere]
    case "minimized": system.windows[1].isMinimized = true
    case "closed": system.windows.remove(at: 1)
    case "unreadable": system.unreadableAfterWrites[departed] = system.frameWriteCounts[departed, default: 0]
    default: break
    }
    let writes = system.frameWriteCounts, scans = system.completeSweepCount
    let raises = system.raiseRequests.count, focuses = system.focusRequests.count, probes = system.probeRequests.count
    for wheel in [false, true] {
        if wheel { model.performLayoutWheel(.windowAction(action), for: target) }
        else { model.perform(action) }
        // This checks the actual strip, without waiting for its one-second
        // pressed-selection timeout, as well as the committed model state.
        #expect(pane.displayedSelection == previous)
        #expect(pane.pane == before.panes[0])
        #expect(model.presentedTabbedState(on: target.displayID) == before)
        #expect(model.activeTabbedState == before)
        #expect(!model.hasPendingTabbedPlacement)
        #expect(model.lastActionFeedback?.kind == .failure)
    }
    #expect(system.frameWriteCounts == writes)
    #expect(system.completeSweepCount == scans)
    #expect(system.raiseRequests.count == raises)
    #expect(system.focusRequests.count == focuses)
    #expect(system.probeRequests.count == probes)
}
