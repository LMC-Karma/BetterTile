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
