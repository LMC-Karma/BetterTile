import AppKit
import Foundation
import Testing
@testable import BetterTileApp
@testable import BetterTileCore

private let laptopID = DisplayID(rawValue: "laptop")
private let externalID = DisplayID(rawValue: "external")
private let laptopSpace = NativeSpaceID(rawValue: 11)
private let externalSpace = NativeSpaceID(rawValue: 22)

private func window(_ id: String, pid: Int32, x: Double, width: Double = 500, display: DisplayID,
                    minimumWidth: Double = 120) -> WindowSnapshot {
    WindowSnapshot(id: WindowID(rawValue: id), processIdentifier: pid, bundleIdentifier: "com.example.\(id)",
                   frame: BTRect(x: x, y: 0, width: width, height: 800), displayID: display,
                   constraints: WindowConstraints(minimumSize: BTSize(width: minimumWidth, height: 80), minimumSizeSource: .hint))
}

@MainActor private func twoDisplayFixture() -> (FakeAppWindowSystem, BetterTileModel) {
    _ = NSApplication.shared
    let system = makeManualWindowSystem(drivingPolicyDeadlines: true)
    system.availableDisplays = [
        DisplaySnapshot(id: laptopID, frame: BTRect(x: 0, y: 0, width: 1000, height: 800),
                        visibleFrame: BTRect(x: 0, y: 0, width: 1000, height: 800), isMain: true),
        DisplaySnapshot(id: externalID, frame: BTRect(x: 1000, y: 0, width: 1000, height: 800),
                        visibleFrame: BTRect(x: 1000, y: 0, width: 1000, height: 800)),
    ]
    system.availableDisplays[0].persistentIdentifier = "built-in-device"
    system.availableDisplays[1].persistentIdentifier = "external-device"
    system.windows = [
        window("L1", pid: 41, x: 0, display: laptopID),
        window("L2", pid: 42, x: 500, display: laptopID),
        window("E1", pid: 51, x: 1000, display: externalID),
        window("E2", pid: 52, x: 1500, display: externalID),
        window("E3", pid: 53, x: 1200, display: externalID),
    ]
    system.desktopObservation = NativeDesktopObservation(
        currentSpaceByDisplay: [laptopID: laptopSpace, externalID: externalSpace],
        knownSpacesByDisplay: [laptopID: [laptopSpace], externalID: [externalSpace]],
        windowMembership: Dictionary(uniqueKeysWithValues: system.windows.map {
            ($0.id, $0.displayID == laptopID ? [laptopSpace] : [externalSpace])
        })
    )
    let model = makeModel(system: system)
    model.configuration.defaultLayoutMode = .manual
    model.configuration.defaultTabbedPreset = .columns
    return (system, model)
}

@MainActor private func tabbedPanes(_ model: BetterTileModel, _ system: FakeAppWindowSystem, focusing id: String) -> [[String]] {
    system.focusedID = WindowID(rawValue: id)
    model.watchdog()
    return (model.activeTabbedState?.panes ?? []).map { $0.tabs.map(\.rawValue).sorted() }
}

@MainActor private func enterTabbedOnExternal(_ model: BetterTileModel, _ system: FakeAppWindowSystem) async throws -> [[String]] {
    system.focusedID = WindowID(rawValue: "E1")
    model.setActiveMode(.tabbed)
    try #require(await system.waitFor { model.activeMode(for: externalID) == .tabbed
        && model.activeTabbedState?.windowIDs.count == 3 && !model.hasPendingTabbedPlacement })
    await system.advance(by: .milliseconds(400))
    try #require(await system.waitFor { !model.hasPendingTabbedPlacement && model.windowEventTask == nil && model.settlementTasks.isEmpty })
    _ = tabbedPanes(model, system, focusing: "E1")
    model.performTabbed(.preset(.columns, grouping: .distributeWindows))
    try #require(await system.waitFor { !model.hasPendingTabbedPlacement })
    await system.advance(by: .milliseconds(400))
    try #require(await system.waitFor { !model.hasPendingTabbedPlacement && model.windowEventTask == nil && model.settlementTasks.isEmpty })
    let panes = tabbedPanes(model, system, focusing: "E1")
    try #require(panes.count == 2 && panes.allSatisfy { !$0.isEmpty }, "\(panes)")
    return panes
}

@Test(.appTestApplication, arguments: [false, true]) @MainActor
func reproDisplayReconnectKeepsDesktopMode(nativeObservationArrivesLate: Bool) async throws {
    let (system, model) = twoDisplayFixture()
    defer { model.shutdown() }
    system.focusedID = WindowID(rawValue: "L1")
    model.setActiveMode(.bento)
    try #require(await system.waitFor { model.activeMode(for: laptopID) == .bento })
    let panesBefore = try await enterTabbedOnExternal(model, system)

    // Unplug: macOS moves the external desktop to the laptop as another
    // desktop. Its windows are not on the laptop's current desktop.
    var external = system.availableDisplays[1]
    let externalWindows = system.windows.filter { $0.displayID == externalID }
    system.availableDisplays = [system.availableDisplays[0]]
    system.windows.removeAll { $0.displayID == externalID }
    system.desktopObservation = NativeDesktopObservation(
        currentSpaceByDisplay: [laptopID: laptopSpace],
        knownSpacesByDisplay: [laptopID: [laptopSpace, externalSpace]],
        windowMembership: system.desktopObservation!.windowMembership)
    model.handleApplicationTopologyChange(waking: true)
    await system.advance(by: .seconds(1))
    try #require(await system.waitFor { !model.isHoldingDisplayChange && !model.hasPendingTabbedPlacement && model.windowEventTask == nil && model.settlementTasks.isEmpty })

    // Reconnect: the UUID and windows survive, but display and Space numbers change.
    let reconnectedID = DisplayID(rawValue: "external-reconnected")
    let reconnectedSpace = NativeSpaceID(rawValue: 33)
    external.id = reconnectedID
    system.availableDisplays.append(external)
    system.windows += externalWindows.map { original in
        var window = original
        window.displayID = reconnectedID
        system.desktopObservation?.windowMembership[window.id] = [reconnectedSpace]
        return window
    }
    let reconnectedObservation = NativeDesktopObservation(
        currentSpaceByDisplay: [laptopID: laptopSpace, reconnectedID: reconnectedSpace],
        knownSpacesByDisplay: [laptopID: [laptopSpace], reconnectedID: [reconnectedSpace]],
        windowMembership: system.desktopObservation!.windowMembership)
    system.desktopObservation = nativeObservationArrivesLate ? nil : reconnectedObservation
    model.handleApplicationTopologyChange(waking: true)
    await system.advance(by: .seconds(1))
    try #require(await system.waitFor { !model.isHoldingDisplayChange && !model.hasPendingTabbedPlacement && model.windowEventTask == nil && model.settlementTasks.isEmpty })

    if nativeObservationArrivesLate {
        system.desktopObservation = reconnectedObservation
        model.beginActiveSpaceStabilization()
        await system.advance(by: .seconds(1))
        try #require(await system.waitFor { !model.isStabilizingSpace && !model.hasPendingTabbedPlacement
            && model.windowEventTask == nil && model.settlementTasks.isEmpty })
    }
    #expect(model.activeMode(for: laptopID) == .bento, "laptop mode after replug")
    #expect(model.activeMode(for: reconnectedID) == .tabbed, "external mode after replug: \(String(describing: model.activeMode(for: reconnectedID)))")
    if model.activeMode(for: reconnectedID) == .tabbed {
        #expect(tabbedPanes(model, system, focusing: "E1") == panesBefore)
    }
}

@Test(.appTestApplication, arguments: [LayoutMode.manual, .bento, .tabbed]) @MainActor
func reproClamshellSwapKeepsDesktopMode(mode: LayoutMode) async throws {
    try await checkClamshellSwap(mode: mode, carry: true)
}

@MainActor private func checkClamshellSwap(mode: LayoutMode, carry: Bool) async throws {
    let (system, model) = twoDisplayFixture()
    defer { model.shutdown() }
    model.configuration.keepsDesktopLayoutsAcrossDisplays = carry
    model.configuration.defaultLayoutMode = mode == .manual ? .bento : .manual
    system.availableDisplays.removeLast()
    system.windows.removeAll { $0.displayID == externalID }
    system.desktopObservation?.currentSpaceByDisplay = [laptopID: laptopSpace]
    system.desktopObservation?.knownSpacesByDisplay = [laptopID: [laptopSpace]]
    system.focusedID = system.windows[0].id
    model.setActiveMode(mode)
    await system.advance(by: .seconds(1))
    try #require(await system.waitFor { !model.hasPendingTabbedPlacement && model.windowEventTask == nil && model.settlementTasks.isEmpty })
    if mode == .tabbed {
        model.performTabbed(.preset(.columns, grouping: .distributeWindows))
        await system.advance(by: .seconds(1))
        try #require(await system.waitFor { !model.hasPendingTabbedPlacement && model.windowEventTask == nil && model.settlementTasks.isEmpty })
    }
    let panes = model.activeTabbedState?.panes.map { $0.tabs } ?? []
    let laptop = system.availableDisplays[0]
    var external = laptop
    external.id = externalID
    external.persistentIdentifier = "external-device"
    external.frame = BTRect(x: 0, y: 0, width: 850, height: 700)
    external.visibleFrame = external.frame
    let externalDesktop = NativeSpaceID(rawValue: 44)
    await swapOnlyDisplay(to: external, space: externalDesktop, system: system, model: model)
    #expect(model.activeMode(for: external.id) == (carry ? mode : model.configuration.defaultLayoutMode), "Replacing the only display must keep its desktop mode when carry-over is on")
    if carry && mode != .manual {
        #expect(system.windows.allSatisfy { $0.frame.maxX <= external.visibleFrame.maxX + 1 && $0.frame.maxY <= external.visibleFrame.maxY + 1 })
        if mode == .tabbed { #expect(model.activeTabbedState?.panes.map { $0.tabs } == panes) }
    }
    var returned = laptop
    returned.id = DisplayID(rawValue: "laptop-returned")
    await swapOnlyDisplay(to: returned, space: NativeSpaceID(rawValue: 55), system: system, model: model)
    #expect(model.activeMode(for: returned.id) == mode, "The laptop's own mode must return with either setting")
    if mode == .tabbed {
        #expect(model.activeTabbedState?.panes.map { $0.tabs } == panes)
        let current = Dictionary(uniqueKeysWithValues: system.windows.map { ($0.id, $0.frame) })
        model.setActiveMode(.manual)
        await system.advance(by: .seconds(1))
        try #require(await system.waitFor { !model.hasPendingTabbedPlacement && model.windowEventTask == nil && model.settlementTasks.isEmpty })
        #expect(Dictionary(uniqueKeysWithValues: system.windows.map { ($0.id, $0.frame) }) == current,
                "Leaving carried Tabbed must not restore frames from another screen")
    }
}

@MainActor private func swapOnlyDisplay(to display: DisplaySnapshot, space: NativeSpaceID,
                                       system: FakeAppWindowSystem, model: BetterTileModel) async {
    system.requestedFrames = [:]
    model.handleDisplayChange(.displayReconfigurationBegan)
    system.availableDisplays = [display]
    for i in system.windows.indices { system.windows[i].displayID = display.id }
    system.desktopObservation = NativeDesktopObservation(
        currentSpaceByDisplay: [display.id: space], knownSpacesByDisplay: [display.id: [space]],
        windowMembership: Dictionary(uniqueKeysWithValues: system.windows.map { ($0.id, [space]) }))
    model.handleApplicationTopologyChange()
    await system.advance(by: .milliseconds(500))
    #expect(system.requestedFrames.isEmpty)
    model.handleDisplayChange(.displayReconfigurationEnded)
    await system.advance(by: .seconds(1))
    #expect(await system.waitFor { !model.isHoldingDisplayChange && !model.hasPendingTabbedPlacement
        && model.windowEventTask == nil && model.settlementTasks.isEmpty })
}

@Test(.appTestApplication, arguments: [LayoutMode.manual, .bento, .tabbed]) @MainActor
func desktopModesRemainWithTheirOwnScreenWhenCarryOverIsOff(mode: LayoutMode) async throws {
    try await checkClamshellSwap(mode: mode, carry: false)
}
