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


@Test(.appTestApplication) @MainActor func reproAdaptiveKeepsPlaceAfterOneMisreportedSweep() async throws {
    let (system, model) = twoDisplayFixture()
    defer { model.shutdown() }
    system.windows.removeAll { $0.id.rawValue == "E3" }
    model.configuration.defaultLayoutMode = .bento
    system.focusedID = WindowID(rawValue: "E1")
    model.setActiveMode(.bento)
    try #require(await system.waitFor { model.activeMode(for: externalID) == .bento && model.activeMode(for: laptopID) == .bento })
    await system.advance(by: .milliseconds(500))
    let framesBefore = Dictionary(uniqueKeysWithValues: system.windows.map { ($0.id.rawValue, $0.frame) })

    model.handleDisplayChange(.displayReconfigurationBegan)
    let index = try #require(system.windows.firstIndex { $0.id.rawValue == "E2" })
    let home = system.windows[index]
    system.windows[index].displayID = laptopID
    system.windows[index].frame.origin.x = 300
    system.desktopObservation?.windowMembership[home.id] = [laptopSpace]
    model.handleApplicationTopologyChange(waking: true)
    await system.advance(by: .milliseconds(400))
    let duringLaptop = system.windows.filter { $0.displayID == laptopID }.map { "\($0.id.rawValue) \($0.frame)" }

    // macOS puts the window back where it was.
    system.windows[index].displayID = externalID
    system.windows[index].frame = home.frame
    system.desktopObservation?.windowMembership[home.id] = [externalSpace]
    model.handleDisplayChange(.displayReconfigurationEnded)
    model.handleApplicationTopologyChange(waking: true)
    await system.advance(by: .milliseconds(500))
    for _ in 0..<4 { model.watchdog(); await system.advance(by: .milliseconds(300)) }
    try #require(await system.waitFor { !model.isHoldingDisplayChange && !model.hasPendingTabbedPlacement && model.windowEventTask == nil && model.settlementTasks.isEmpty })
    let framesAfter = Dictionary(uniqueKeysWithValues: system.windows.map { ($0.id.rawValue, $0.frame) })
    #expect(framesAfter == framesBefore, "before \(framesBefore)\nduring laptop \(duringLaptop)\nafter \(framesAfter)")
}

@Test(.appTestApplication, arguments: [LayoutMode.tabbed, .bento]) @MainActor
func reproLaptopLayoutSurvivesExternalDropout(mode: LayoutMode) async throws {
    let (system, model) = twoDisplayFixture()
    defer { model.shutdown() }
    system.windows.append(window("L3", pid: 43, x: 250, display: laptopID))
    system.desktopObservation?.windowMembership[WindowID(rawValue: "L3")] = [laptopSpace]
    system.focusedID = WindowID(rawValue: "L1")
    model.setActiveMode(mode)
    try #require(await system.waitFor { model.activeMode(for: laptopID) == mode && !model.hasPendingTabbedPlacement })
    await system.advance(by: .milliseconds(400))
    if mode == .tabbed {
        _ = tabbedPanes(model, system, focusing: "L1")
        model.performTabbed(.preset(.columns, grouping: .distributeWindows))
        try #require(await system.waitFor { !model.hasPendingTabbedPlacement })
        await system.advance(by: .milliseconds(400))
    }
    try #require(await system.waitFor { !model.hasPendingTabbedPlacement })
    let panesBefore = mode == .tabbed ? tabbedPanes(model, system, focusing: "L1") : []
    let selectedBefore = model.activeTabbedState?.selectedWindowIDs.map(\.rawValue).sorted() ?? []
    let laptopBefore = system.windows.filter { $0.displayID == laptopID }.map { "\($0.id.rawValue) \($0.frame)" }.sorted()

    model.handleDisplayChange(.displayReconfigurationBegan)
    let external = system.availableDisplays[1]
    let home = system.windows
    system.availableDisplays = [system.availableDisplays[0]]
    for index in system.windows.indices where system.windows[index].displayID == externalID {
        system.windows[index].displayID = laptopID
        system.windows[index].frame.origin.x -= 1000
        system.desktopObservation?.windowMembership[system.windows[index].id] = [laptopSpace]
    }
    system.desktopObservation?.currentSpaceByDisplay = [laptopID: laptopSpace]
    system.desktopObservation?.knownSpacesByDisplay = [laptopID: [laptopSpace]]
    model.handleApplicationTopologyChange(waking: true)
    await system.advance(by: .milliseconds(400))
    let during = system.windows.map { "\($0.id.rawValue) \($0.frame)" }.sorted()

    // The display wakes. macOS returns the windows that BetterTile did not move.
    system.availableDisplays.append(external)
    for original in home where original.displayID == externalID {
        guard let index = system.windows.firstIndex(where: { $0.id == original.id }) else { continue }
        let movedByBetterTile = (system.requestedFrames[original.id]?.isEmpty == false)
        if !movedByBetterTile { system.windows[index] = original }
        system.desktopObservation?.windowMembership[original.id] =
            movedByBetterTile ? [laptopSpace] : [externalSpace]
    }
    system.desktopObservation?.currentSpaceByDisplay = [laptopID: laptopSpace, externalID: externalSpace]
    system.desktopObservation?.knownSpacesByDisplay = [laptopID: [laptopSpace], externalID: [externalSpace]]
    model.handleDisplayChange(.displayReconfigurationEnded)
    model.handleApplicationTopologyChange(waking: true)
    await system.advance(by: .milliseconds(400))
    for _ in 0..<4 { model.watchdog(); await system.advance(by: .milliseconds(250)) }

    try #require(await system.waitFor { !model.isHoldingDisplayChange && !model.hasPendingTabbedPlacement && model.windowEventTask == nil })
    let panesAfter = mode == .tabbed ? tabbedPanes(model, system, focusing: "L1") : []
    let selectedAfter = model.activeTabbedState?.selectedWindowIDs.map(\.rawValue).sorted() ?? []
    let laptopAfter = system.windows.filter { $0.displayID == laptopID }.map { "\($0.id.rawValue) \($0.frame)" }.sorted()
    let movedExternal = home.filter { $0.displayID == externalID && system.requestedFrames[$0.id]?.isEmpty == false }.map(\.id.rawValue)
    #expect(movedExternal.isEmpty, "BetterTile wrote frames to external windows during the dropout: \(movedExternal)")
    #expect(panesAfter == panesBefore, "panes before \(panesBefore) after \(panesAfter)")
    #expect(selectedAfter == selectedBefore, "selected before \(selectedBefore) after \(selectedAfter)")
    #expect(laptopAfter == laptopBefore, "laptop before \(laptopBefore)\nduring \(during)\nafter \(laptopAfter)")
    #expect(model.activeMode(for: externalID) == .manual, "external mode (default Manual either way)")
}

@Test(.appTestApplication) @MainActor
func displayHoldEndsAtLimitWithoutCompletionCallback() async throws {
    let (system, model) = twoDisplayFixture()
    defer { model.shutdown() }
    model.handleDisplayChange(.displayReconfigurationBegan)
    await system.advance(by: .seconds(4))
    #expect(model.isHoldingDisplayChange)
    await system.advance(by: .seconds(1.1))
    try #require(await system.waitFor { !model.isHoldingDisplayChange && model.windowEventTask == nil })
    #expect(!model.isHoldingDisplayChange)
}

@Test(.appTestApplication) @MainActor
func displayHoldWaitsForSessionAndScreenUnlock() async throws {
    let (system, model) = twoDisplayFixture()
    defer { model.shutdown() }
    model.setActiveMode(.bento)
    await system.advance(by: .seconds(1))
    system.requestedFrames = [:]
    let windowsBeforeLock = system.windows
    model.handleDisplayChange(.sessionResigned)
    system.windows.removeAll()
    model.handleDisplayChangeApplicationActivation(bundleID: "com.example.App")
    await system.advance(by: .seconds(6))
    #expect(model.isHoldingDisplayChange)
    #expect(system.requestedFrames.isEmpty)
    model.displayChangeScreenIsLocked = { true }
    model.handleDisplayChange(.sessionBecameActive)
    await system.advance(by: .seconds(6))
    #expect(model.isHoldingDisplayChange)
    system.windows = windowsBeforeLock
    model.displayChangeScreenIsLocked = { false }
    model.handleDisplayChangeApplicationActivation(bundleID: "com.example.App")
    await system.advance(by: .seconds(1))
    #expect(!model.isHoldingDisplayChange)
}

@Test(.appTestApplication) @MainActor
func displayHoldDefersARealWindowMoveUntilSettled() async throws {
    let (system, model) = twoDisplayFixture()
    defer { model.shutdown() }
    model.configuration.defaultLayoutMode = .bento
    system.focusedID = WindowID(rawValue: "L1")
    model.setActiveMode(.bento)
    await system.advance(by: .seconds(1))
    try #require(await system.waitFor { model.windowEventTask == nil && model.settlementTasks.isEmpty })
    system.requestedFrames = [:]
    model.handleDisplayChange(.displayReconfigurationBegan)
    let index = try #require(system.windows.firstIndex { $0.id.rawValue == "E2" })
    let id = system.windows[index].id
    system.windows[index].displayID = laptopID
    system.windows[index].frame.origin.x = 200
    system.desktopObservation?.windowMembership[id] = [laptopSpace]
    model.handleApplicationTopologyChange()
    model.watchdog()
    await system.advance(by: .seconds(1))
    #expect(system.requestedFrames.isEmpty)
    model.handleDisplayChange(.displayReconfigurationEnded)
    await system.advance(by: .seconds(1))
    try #require(await system.waitFor { !model.isHoldingDisplayChange && model.windowEventTask == nil && model.settlementTasks.isEmpty })
    #expect(system.requestedFrames[id]?.isEmpty == false)
    #expect(system.windows.filter { $0.displayID == laptopID }.allSatisfy { $0.frame.maxX <= 1000 })
}

@Test(.appTestApplication) @MainActor
func displayHoldAllowsExplicitLayoutOnOnlyItsTargetDisplay() async throws {
    let (system, model) = twoDisplayFixture()
    defer { model.shutdown() }
    model.configuration.defaultLayoutMode = .bento
    system.focusedID = WindowID(rawValue: "L1")
    model.setActiveMode(.bento)
    await system.advance(by: .seconds(1))
    try #require(await system.waitFor { model.windowEventTask == nil && model.settlementTasks.isEmpty })
    system.requestedFrames = [:]
    model.handleDisplayChange(.displayReconfigurationBegan)
    model.perform(.leftHalf)
    #expect(model.isHoldingDisplayChange)
    #expect(system.requestedFrames[WindowID(rawValue: "L1")]?.isEmpty == false)
    #expect(system.requestedFrames.keys.allSatisfy { $0.rawValue.hasPrefix("L") })
    let runtime = try #require(model.displayTriggerRuntime)
    #expect(!runtime.isReady(laptopID))
}
