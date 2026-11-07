import Foundation
import Testing
@testable import BetterTileApp
@testable import BetterTileCore
@testable import BetterTileMacOS

@MainActor private final class DesktopMemoryCouncilFixture {
    let system = makeManualWindowSystem(drivingPolicyDeadlines: true)
    let model: BetterTileModel
    let a = WindowID(rawValue: "a"), b = WindowID(rawValue: "b")
    init() {
        var display = system.mainDisplay
        display.persistentIdentifier = "A"
        system.availableDisplays = [display]
        system.windows = [a, b].enumerated().map { index, id in
            WindowSnapshot(id: id, processIdentifier: Int32(41 + index), bundleIdentifier: "example.\(id.rawValue)",
                frame: BTRect(x: Double(index * 400), y: 40, width: 400, height: 500), displayID: display.id)
        }
        system.focusedID = b
        system.desktopObservation = NativeDesktopObservation(
            currentSpaceByDisplay: [display.id: .init(rawValue: 1)], knownSpacesByDisplay: [display.id: [.init(rawValue: 1)]],
            windowMembership: [a: [.init(rawValue: 1)], b: [.init(rawValue: 1)]])
        model = makeModel(system: system)
        model.configuration.defaultLayoutMode = .manual
        model.configuration.defaultTabbedPreset = .single
    }
    var display: DisplayID { system.availableDisplays[0].id }
    func store() throws -> LayoutSessionStore {
        try #require(Mirror(reflecting: model).children.first { $0.label?.hasSuffix("sessionStore") == true }?.value as? LayoutSessionStore)
    }
    func idle() async throws {
        await system.advance(by: .seconds(1))
        try #require(await system.waitFor { !self.model.isHoldingDisplayChange && !self.model.hasPendingTabbedPlacement
            && self.model.windowEventTask == nil && self.model.settlementTasks.isEmpty })
    }
    func replaceDisplay(_ name: String, uuid: String, space: UInt64, finish: Bool = true) async throws {
        model.handleDisplayChange(.displayReconfigurationBegan)
        var screen = system.mainDisplay
        screen.id = DisplayID(rawValue: name)
        screen.persistentIdentifier = uuid
        system.availableDisplays = [screen]
        for index in system.windows.indices { system.windows[index].displayID = screen.id }
        let native = NativeSpaceID(rawValue: space)
        system.desktopObservation = NativeDesktopObservation(currentSpaceByDisplay: [screen.id: native],
            knownSpacesByDisplay: [screen.id: [native]], windowMembership: Dictionary(uniqueKeysWithValues: system.windows.map { ($0.id, [native]) }))
        if finish { model.handleDisplayChange(.displayReconfigurationEnded); try await idle() }
    }
}

@Test(.appTestApplication, arguments: [false, true], [false, true]) @MainActor
func retiredDesktopLifecycleSurvivesCarryOffRoundTrip(closed: Bool, missingSpace: Bool) async throws {
    let f = DesktopMemoryCouncilFixture()
    defer { f.model.shutdown() }
    f.model.configuration.keepsDesktopLayoutsAcrossDisplays = false
    f.model.setActiveMode(.tabbed)
    try await f.idle()
    let original = try #require(f.store().session(for: f.display))
    try #require(original.tabbedState?.activeWindowID == f.b)
    if missingSpace {
        f.model.handleDisplayChange(.displayReconfigurationBegan)
        f.system.offscreenWindowIDs = [f.a, f.b]
        f.system.desktopObservation = NativeDesktopObservation(
            currentSpaceByDisplay: [f.display: .init(rawValue: 2)],
            knownSpacesByDisplay: [f.display: [.init(rawValue: 2), .init(rawValue: 3)]],
            windowMembership: [f.a: [.init(rawValue: 3)], f.b: [.init(rawValue: 3)]])
        f.model.handleDisplayChange(.displayReconfigurationEnded)
        try await f.idle()
    } else { try await f.replaceDisplay("external", uuid: "B", space: 2) }
    try #require(f.store().retiredSessions.contains { $0.session.id == original.id })
    if closed { f.system.windows.removeAll { $0.id == f.b } }
    else { f.system.windows[1].isMinimized = true }
    f.system.focusedID = f.a
    f.system.eventHandler?(WindowSystemEvent(kind: closed ? .destroyed : .minimized, windowID: f.b, processIdentifier: 42))
    try await f.idle()
    let parked = try #require(f.store().retiredSessions.first { $0.session.id == original.id })
    #expect(parked.session.tabbedState?.windowIDs == [f.a])
    #expect(parked.session.tabbedState?.activeWindowID == f.a)
    #expect(parked.windowIDs.contains(f.b) == !closed)
    f.system.offscreenWindowIDs = []
    try await f.replaceDisplay("laptop-returned", uuid: "A", space: 3)
    let restored = try #require(f.store().session(for: f.display))
    #expect(restored.id == original.id && restored.mode == .tabbed)
    #expect(restored.tabbedState?.windowIDs == [f.a])
    #expect(restored.tabbedState?.activeWindowID == f.a)
}

@Test(.appTestApplication, arguments: [false, true]) @MainActor
func enablingDesktopCarryOverUsesNewestMode(offRoundTrip: Bool) async throws {
    let f = DesktopMemoryCouncilFixture()
    defer { f.model.shutdown() }
    f.model.configuration.keepsDesktopLayoutsAcrossDisplays = false
    f.model.setActiveMode(.bento)
    try await f.idle()
    try await f.replaceDisplay("external", uuid: "B", space: 2)
    #expect(f.model.activeMode(for: f.display) == .manual)
    if offRoundTrip {
        try await f.replaceDisplay("laptop-returned", uuid: "A", space: 3)
        #expect(f.model.activeMode(for: f.display) == .bento)
    }
    let newestMode = f.model.activeMode(for: f.display)
    f.model.configuration.keepsDesktopLayoutsAcrossDisplays = true
    try await f.replaceDisplay("return", uuid: offRoundTrip ? "B" : "A", space: 4)
    #expect(f.model.activeMode(for: f.display) == newestMode)
    #expect(try f.store().retiredSessions.isEmpty)
}

@Test(.appTestApplication) @MainActor
func aShortcutDuringDisplayHoldDoesNotConsumeDesktopRestoration() async throws {
    let f = DesktopMemoryCouncilFixture()
    defer { f.model.shutdown() }
    f.model.setActiveMode(.bento)
    try await f.idle()
    let original = try #require(f.store().session(for: f.display))
    try await f.replaceDisplay("external", uuid: "B", space: 2, finish: false)
    f.model.perform(.leftHalf)
    f.model.handleApplicationTopologyChange()
    #expect(f.model.activeMode(for: f.display) == .bento)
    f.model.handleDisplayChange(.displayReconfigurationEnded)
    try await f.idle()
    let restored = try #require(f.store().session(for: f.display))
    #expect(restored.id == original.id && restored.mode == .bento)
    let left = try #require(f.system.windows.first { $0.id == f.b })
    let right = try #require(f.system.windows.first { $0.id == f.a })
    #expect(left.frame.midX < right.frame.midX)
}

@Test(.appTestApplication) @MainActor
func desktopRestorationDropsOldScreenFrameHistory() async throws {
    let f = DesktopMemoryCouncilFixture()
    defer { f.model.shutdown() }
    f.model.watchdog()
    f.model.perform(.leftHalf)
    let coordinator = try #require(Mirror(reflecting: f.model).children.first {
        $0.label?.hasSuffix("coordinator") == true
    }?.value as? WindowCoordinator)
    try #require(coordinator.retainedState(for: f.b).historyFrames > 0)
    try await f.replaceDisplay("external", uuid: "B", space: 2)
    #expect(coordinator.retainedState(for: f.b).historyFrames == 0)
}

@Test(.appTestApplication) @MainActor
func nativeFullscreenPlaceholdersDoNotEnterDesktopMemory() async throws {
    let f = DesktopMemoryCouncilFixture()
    defer { f.model.shutdown() }
    f.model.setActiveMode(.bento)
    try await f.idle()
    f.system.desktopObservation = NativeDesktopObservation(
        currentSpaceByDisplay: [f.display: .init(rawValue: 2)],
        knownSpacesByDisplay: [f.display: [.init(rawValue: 1), .init(rawValue: 2)]],
        windowMembership: [f.a: [.init(rawValue: 1)], f.b: [.init(rawValue: 1)]],
        fullscreenSpaceIDs: [.init(rawValue: 2)])
    f.model.beginActiveSpaceStabilization()
    try #require(await f.system.waitFor { !f.model.isStabilizingSpace })
    f.model.configuration.keepsDesktopLayoutsAcrossDisplays = false
    try await f.replaceDisplay("external", uuid: "B", space: 3)
    #expect(try f.store().retiredSessions.count == 1)
    #expect(try f.store().retiredSessions.allSatisfy { $0.session.nativeSpaceID != .init(rawValue: 2) })
}

@Test(.appTestApplication, arguments: [false, true]) @MainActor
func repairDropsOldTabbedUndoDuringHoldOrAfterAnEmptyObservation(duringHold: Bool) async throws {
    let f = DesktopMemoryCouncilFixture()
    defer { f.model.shutdown() }
    f.model.setActiveMode(.tabbed)
    try await f.idle()
    let original = try #require(f.store().session(for: f.display))
    f.model.performTabbed(.preset(.columns, grouping: .distributeWindows))
    try await f.idle()
    func history() throws -> [DesktopSessionID: Any] {
        try #require(Mirror(reflecting: f.model).children.first {
            $0.label?.hasSuffix("tabbedUndo") == true
        }?.value as? [DesktopSessionID: Any])
    }
    let previousSteps = try #require(try history()[original.id])
    try #require(!Mirror(reflecting: previousSteps).children.isEmpty)
    if duringHold {
        try await f.replaceDisplay("external", uuid: "B", space: 2, finish: false)
    } else {
        var windows = f.system.windows
        f.system.windows = []
        try await f.replaceDisplay("external", uuid: "B", space: 2)
        for index in windows.indices { windows[index].displayID = f.display }
        f.system.windows = windows
        f.system.desktopObservation?.windowMembership = Dictionary(uniqueKeysWithValues: windows.map { ($0.id, [NativeSpaceID(rawValue: 2)]) })
    }
    f.model.tileCurrentDisplay()
    #expect(try history()[original.id] == nil)
    f.model.handleDisplayChange(.displayReconfigurationEnded)
    try await f.idle()
    #expect(try history()[original.id] == nil)
}

@Test(.appTestApplication) @MainActor
func retiredDesktopInvalidatesSavedApplyUndoWithoutWritingFrames() async throws {
    let h = ApplyHarness()
    defer { h.close() }
    h.addWindow()
    _ = await h.applier.apply(h.document())
    try #require(h.applier.canUndo)
    let writes = h.system.frameWriteCounts
    h.applier.invalidateUndo(involving: Set(h.system.windows.map(\.id)), desktop: nil)
    #expect(!h.applier.canUndo)
    await h.applier.undoLastApply()
    #expect(h.system.frameWriteCounts == writes)
}

@Test(.appTestApplication, arguments: [false, true], [false, true]) @MainActor
func movedWindowKeepsBothDesktopOwnersOnReconnect(carryOver: Bool, destinationFirst: Bool) async throws {
    let f = DesktopMemoryCouncilFixture()
    defer { f.model.shutdown() }
    f.model.configuration.keepsDesktopLayoutsAcrossDisplays = carryOver
    let c = WindowID(rawValue: "c")
    f.system.windows.append(WindowSnapshot(id: c, processIdentifier: 43, bundleIdentifier: "example.c",
        frame: BTRect(x: 200, y: 40, width: 400, height: 500), displayID: f.display))
    f.system.desktopObservation?.windowMembership[c] = [.init(rawValue: 1)]
    f.model.setActiveMode(.bento)
    try await f.idle()
    let source = try #require(f.store().session(for: f.display))
    func observe(current: UInt64, source: UInt64, destination: UInt64) {
        f.system.offscreenWindowIDs = current == source ? [f.b] : [f.a, c]
        f.system.focusedID = current == source ? f.a : f.b
        f.system.desktopObservation = NativeDesktopObservation(
            currentSpaceByDisplay: [f.display: .init(rawValue: current)],
            knownSpacesByDisplay: [f.display: [.init(rawValue: source), .init(rawValue: destination)]],
            windowMembership: [f.a: [.init(rawValue: source)], c: [.init(rawValue: source)],
                               f.b: [.init(rawValue: destination)]])
    }
    // Move b while the source is inactive, then choose Tabbed on its new desktop.
    observe(current: 2, source: 1, destination: 2)
    f.model.beginActiveSpaceStabilization()
    try #require(await f.system.waitFor { !f.model.isStabilizingSpace })
    f.model.setActiveMode(.tabbed)
    try await f.idle()
    let destination = try #require(f.store().session(for: f.display))
    try #require(destination.id != source.id && destination.mode == .tabbed)
    try #require(f.store().allSessions(for: f.display).first { $0.id == source.id }?.windowIDs.contains(f.b) == true)

    // Disconnect both desktops, then reconnect the same UUID with new runtime IDs.
    f.model.handleDisplayChange(.displayReconfigurationBegan)
    f.system.availableDisplays = []
    f.system.offscreenWindowIDs = [f.a, f.b, c]
    f.system.desktopObservation = NativeDesktopObservation(
        currentSpaceByDisplay: [:], knownSpacesByDisplay: [:], windowMembership: [:])
    f.model.handleDisplayChange(.displayReconfigurationEnded)
    try await f.idle()
    try #require(f.store().retiredSessions.count == 2)
    f.model.handleDisplayChange(.displayReconfigurationBegan)
    var returned = f.system.mainDisplay
    returned.id = DisplayID(rawValue: "reconnected")
    returned.persistentIdentifier = "A"
    f.system.availableDisplays = [returned]
    for index in f.system.windows.indices { f.system.windows[index].displayID = returned.id }
    observe(current: destinationFirst ? 22 : 11, source: 11, destination: 22)
    f.model.handleDisplayChange(.displayReconfigurationEnded)
    try await f.idle()
    for isDestination in [destinationFirst, !destinationFirst] {
        if isDestination != destinationFirst {
            observe(current: isDestination ? 22 : 11, source: 11, destination: 22)
            f.model.beginActiveSpaceStabilization()
            try #require(await f.system.waitFor { !f.model.isStabilizingSpace })
            try await f.idle()
        }
        let session = try #require(f.store().session(for: f.display))
        #expect(session.id == (isDestination ? destination.id : source.id))
        #expect(session.mode == (isDestination ? .tabbed : .bento))
    }
    let sessions = try f.store().allSessions(for: f.display)
    #expect(sessions.first { $0.id == source.id }?.mode == .bento)
    #expect(sessions.first { $0.id == destination.id }?.mode == .tabbed)
}

@Test(.appTestApplication, arguments: [LayoutMode.bento, .tabbed], [1, 2]) @MainActor
func arrivalsAfterAnEmptyDesktopAreMeasuredBeforePlacement(mode: LayoutMode, windowCount: Int) async throws {
    let f = DesktopMemoryCouncilFixture()
    defer { f.model.shutdown() }
    f.model.configuration.defaultLayoutMode = mode
    f.model.configuration.defaultTabbedPreset = .columns
    f.system.windows = []
    f.system.focusedID = nil
    f.system.desktopObservation?.windowMembership = [:]
    f.system.measuresOnWrite = true
    f.model.watchdog()
    try await f.idle()
    try #require(f.model.activeMode(for: f.display) == mode)
    try #require(f.system.probeRequests.isEmpty)
    let arrivals = Array([f.a, f.b].prefix(windowCount))
    // Tabbed selects the last arrival in the active pane. Its selected tab,
    // rather than a hidden peer, must be the one that needs the wider pane.
    let wide = mode == .tabbed && windowCount == 2 ? f.b : f.a
    f.system.windows = arrivals.map { id in
        WindowSnapshot(id: id, processIdentifier: id == f.a ? 41 : 42,
            bundleIdentifier: "example.\(id.rawValue)",
            frame: BTRect(x: 0, y: 0, width: 800, height: 600), displayID: f.display)
    }
    f.system.enforcedMinimumWidths = Dictionary(uniqueKeysWithValues: arrivals.map { ($0, $0 == wide ? 650.0 : 300.0) })
    f.system.focusedID = wide
    f.system.desktopObservation?.windowMembership = Dictionary(uniqueKeysWithValues: arrivals.map { ($0, [.init(rawValue: 1)]) })
    f.model.handleApplicationTopologyChange()
    try await f.idle()
    #expect(f.system.probeRequests == [Set(arrivals)])
    if mode == .tabbed { #expect(f.model.activeTabbedState?.selectedWindowIDs.contains(wide) == true) }
    let frames = f.system.requestedFrames[wide] ?? []
    #expect(!frames.isEmpty)
    #expect(frames.allSatisfy { $0.size.width >= 650 }, "Requested widths: \(frames.map { $0.size.width })")
}

@Test(.appTestApplication, arguments: [false, true]) @MainActor
func mergedDesktopsReturnToTheirOwnModesAfterCarryOver(firstDesktopFirst: Bool) async throws {
    let f = DesktopMemoryCouncilFixture()
    defer { f.model.shutdown() }
    let c = WindowID(rawValue: "c")
    f.system.windows.append(WindowSnapshot(id: c, processIdentifier: 43, bundleIdentifier: "example.c",
        frame: BTRect(x: 200, y: 40, width: 400, height: 500), displayID: f.display))
    func observe(display: DisplayID, current: UInt64, first: UInt64, second: UInt64) {
        f.system.offscreenWindowIDs = current == first ? [c] : [f.a, f.b]
        f.system.focusedID = current == first ? f.b : c
        f.system.desktopObservation = NativeDesktopObservation(
            currentSpaceByDisplay: [display: .init(rawValue: current)],
            knownSpacesByDisplay: [display: [.init(rawValue: first), .init(rawValue: second)]],
            windowMembership: [f.a: [.init(rawValue: first)], f.b: [.init(rawValue: first)],
                               c: [.init(rawValue: second)]])
    }
    observe(display: f.display, current: 1, first: 1, second: 2)
    f.model.setActiveMode(.bento)
    try await f.idle()
    let first = try #require(f.store().session(for: f.display))
    observe(display: f.display, current: 2, first: 1, second: 2)
    f.model.beginActiveSpaceStabilization()
    try #require(await f.system.waitFor { !f.model.isStabilizingSpace })
    f.model.setActiveMode(.tabbed)
    try await f.idle()
    let second = try #require(f.store().session(for: f.display))
    try #require(second.id != first.id && second.mode == .tabbed)

    // The new screen has one desktop, and macOS moves every window onto it.
    f.system.offscreenWindowIDs = []
    try await f.replaceDisplay("external", uuid: "B", space: 21)
    let merged = try #require(f.store().session(for: f.display))
    #expect(merged.id == first.id && merged.mode == .bento)
    #expect(try f.store().retiredSessions.map(\.session.id) == [second.id])

    // The original screen returns with new runtime IDs and two desktops.
    f.model.handleDisplayChange(.displayReconfigurationBegan)
    var returned = f.system.mainDisplay
    returned.id = DisplayID(rawValue: "returned")
    returned.persistentIdentifier = "A"
    f.system.availableDisplays = [returned]
    for index in f.system.windows.indices { f.system.windows[index].displayID = returned.id }
    observe(display: returned.id, current: firstDesktopFirst ? 31 : 32, first: 31, second: 32)
    f.model.handleDisplayChange(.displayReconfigurationEnded)
    try await f.idle()
    for isFirst in [firstDesktopFirst, !firstDesktopFirst] {
        if isFirst != firstDesktopFirst {
            observe(display: returned.id, current: isFirst ? 31 : 32, first: 31, second: 32)
            f.model.beginActiveSpaceStabilization()
            try #require(await f.system.waitFor { !f.model.isStabilizingSpace })
            try await f.idle()
        }
        let session = try #require(f.store().session(for: f.display))
        #expect(session.id == (isFirst ? first.id : second.id))
        #expect(session.mode == (isFirst ? .bento : .tabbed))
    }
}
