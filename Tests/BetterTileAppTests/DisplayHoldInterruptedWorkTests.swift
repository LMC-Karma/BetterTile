import AppKit
import BetterTileCore
@testable import BetterTileMacOS
import Testing
@testable import BetterTileApp

@MainActor private func settleHold(_ model: BetterTileModel, _ system: FakeAppWindowSystem) async throws {
    await system.advance(by: .seconds(2))
    try #require(await system.waitFor {
        !model.isHoldingDisplayChange && !model.hasPendingTabbedPlacement
            && model.windowEventTask == nil && model.settlementTasks.isEmpty
    })
}

@MainActor private func frame(_ id: WindowID, in system: FakeAppWindowSystem) throws -> BTRect {
    try #require(system.windows.first { $0.id == id }).frame
}

private func shifted(_ rect: BTRect, by dx: Double) -> BTRect {
    BTRect(x: rect.minX + dx, y: rect.minY, width: rect.size.width, height: rect.size.height)
}

// MARK: - Saved Layout Apply on a Manual desktop

enum ManualHoldChange: String, CaseIterable, Sendable {
    /// Nothing changes during the hold.
    case none
    /// The user moves a window that is not part of the Apply.
    case otherWindowMoved
    /// The user moves the Apply's own window.
    case appliedWindowMoved
    /// The display keeps its size but its global origin moves, as when another
    /// display becomes the main display. The window server keeps each window at
    /// its place on its display.
    case displayOriginMoved
    /// The display changes size.
    case displayResized
}

/// A display change interrupts a Saved Layout Apply on a Manual desktop.
/// Recovery after the hold restores only the Apply's own windows, keeps any
/// frame that changed during the hold, follows a moved display origin, and
/// writes nothing when the display's size changed.
@Test(.appTestApplication, arguments: ManualHoldChange.allCases) @MainActor
func manualApplyRecoveryRestoresOnlyItsWindowsAndKeepsNewerFrames(change: ManualHoldChange) async throws {
    let system = makeManualWindowSystem(drivingPolicyDeadlines: true)
    let h = ApplyHarness(system: system)
    defer { h.close() }
    h.addWindow()
    h.addWindow("com.example.Other", id: "other", pid: 44)
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.setActiveMode(.manual)
    await system.advance(by: .seconds(1))
    let window = WindowID(rawValue: "window"), other = WindowID(rawValue: "other")
    let original = try frame(window, in: system)
    let applier = try #require(model.savedLayoutApplier)
    applier.observesKeyboard = false
    applier.application = h.applier.application
    let writesBefore = system.frameWriteCounts
    var interrupted = false
    system.onWindowSnapshots = {
        guard !interrupted, system.frameWriteCounts != writesBefore else { return }
        interrupted = true
        model.handleDisplayChange(.displayReconfigurationBegan)
    }
    _ = await system.drive { await applier.apply(h.document(mode: .bento)) }
    try #require(interrupted)
    system.onWindowSnapshots = nil
    try #require(!(try frame(window, in: system)).approximatelyEquals(original, tolerance: 2))

    let moved = BTRect(x: 600, y: 400, width: 300, height: 250)
    let dx = 1000.0
    let index = { (id: WindowID) in system.windows.firstIndex { $0.id == id }! }
    switch change {
    case .none: break
    case .otherWindowMoved: system.windows[index(other)].frame = moved
    case .appliedWindowMoved: system.windows[index(window)].frame = moved
    case .displayOriginMoved:
        let display = system.mainDisplay
        system.availableDisplays = [DisplaySnapshot(id: display.id, frame: shifted(display.frame, by: dx),
            visibleFrame: shifted(display.visibleFrame, by: dx), isMain: true)]
        for i in system.windows.indices { system.windows[i].frame = shifted(system.windows[i].frame, by: dx) }
    case .displayResized:
        let display = system.mainDisplay
        let smaller = BTRect(x: 0, y: 0, width: 800, height: 700)
        system.availableDisplays = [DisplaySnapshot(id: display.id, frame: smaller, visibleFrame: smaller, isMain: true)]
    }
    let held = Dictionary(uniqueKeysWithValues: system.windows.map { ($0.id, $0.frame) })
    let heldWrites = system.frameWriteCounts
    model.handleDisplayChange(.displayReconfigurationEnded)
    try await settleHold(model, system)

    #expect(system.frameWriteCounts[other, default: 0] == heldWrites[other, default: 0],
            "A window outside the Apply was written after the hold")
    #expect(try frame(other, in: system) == held[other])
    let recovered = try frame(window, in: system)
    switch change {
    case .none, .otherWindowMoved:
        #expect(recovered.approximatelyEquals(original, tolerance: 2), "The Apply's window is at \(recovered)")
    case .appliedWindowMoved:
        #expect(recovered == moved, "A move made during the hold was undone")
        #expect(system.frameWriteCounts[window, default: 0] == heldWrites[window, default: 0])
    case .displayOriginMoved:
        #expect(recovered.approximatelyEquals(shifted(original, by: dx), tolerance: 2),
                "The Apply's window is at \(recovered), not at its place on the moved display")
    case .displayResized:
        #expect(system.frameWriteCounts[window, default: 0] == heldWrites[window, default: 0],
                "Recovery wrote an absolute frame on a display that changed size")
        #expect(recovered == held[window])
    }
    #expect(try layoutSessionStore(model).session(for: system.mainDisplay.id)?.automaticWritesSuspended == false)
}

// MARK: - Native linked resizing

@MainActor private final class LinkedResizeFixture {
    let system = makeManualWindowSystem(drivingPolicyDeadlines: true)
    let model: BetterTileModel
    let controller: LinkedResizeController
    let source: WindowID
    let peer = WindowID(rawValue: "peer")
    let peerFrame = BTRect(x: 500, y: 0, width: 500, height: 800)

    init() throws {
        source = system.windows[0].id
        system.windows[0].frame = BTRect(x: 0, y: 0, width: 500, height: 800)
        system.windows.append(.init(id: peer, processIdentifier: 43, bundleIdentifier: "com.example.Peer",
            frame: peerFrame, displayID: system.mainDisplay.id))
        system.focusedID = source
        model = makeModel(system: system)
        model.setActiveMode(.manual)
        controller = try #require(Mirror(reflecting: model).children.first {
            $0.label?.hasSuffix("linkedResize") == true
        }?.value as? LinkedResizeController)
        var configuration = model.configuration
        configuration.linkedResizeEnabled = true
        controller.configuration = configuration
        controller.setUsesSharedGestureEvents(true)
    }

    func send(_ kind: GlobalGestureEventKind, _ timestamp: UInt64) {
        controller.handleSharedGestureEvent(GlobalGestureEvent(kind: kind, position: BTPoint(x: 500, y: 400),
            button: 0, modifiers: [], timestamp: timestamp))
    }

    /// Presses on the shared edge and widens the source natively.
    func resizeSource(to width: Double, timestamp: UInt64) {
        system.windows[0].frame.size.width = width
        send(.leftMouseDragged, timestamp)
    }
}

/// A drag sample queues a neighbour update for the next display tick. A hold
/// that starts before that tick stops the gesture: the tick, the release and
/// the rest of the drag write nothing. Without a hold, the tick moves the
/// neighbour as usual.
@Test(.appTestApplication, arguments: [false, true]) @MainActor
func nativeLinkedResizeWritesNothingAfterAHoldStartsBeforeItsTick(held: Bool) async throws {
    let f = try LinkedResizeFixture()
    defer { f.model.shutdown() }
    f.send(.leftMouseDown, 1)
    f.send(.leftMouseDragged, 2)
    f.controller.displayTick()
    f.resizeSource(to: 600, timestamp: 3)
    if held { f.model.handleDisplayChange(.displayReconfigurationBegan) }
    f.controller.displayTick()
    guard held else {
        #expect(try frame(f.peer, in: f.system) == BTRect(x: 600, y: 0, width: 400, height: 800))
        f.send(.leftMouseUp, 4)
        return
    }
    #expect(f.system.frameWriteCounts[f.peer] == nil, "The queued tick moved the neighbour during the hold")
    f.resizeSource(to: 650, timestamp: 4)
    f.controller.displayTick()
    f.send(.leftMouseUp, 5)
    await f.system.advance(by: .seconds(1))
    #expect(f.system.frameWriteCounts[f.peer] == nil, "The interrupted drag moved the neighbour during the hold")
    f.model.handleDisplayChange(.displayReconfigurationEnded)
    try await settleHold(f.model, f.system)
    #expect(try frame(f.peer, in: f.system) == f.peerFrame)
}

/// An application ignored the last neighbour write. A hold starts before the
/// release, so the release must not resend that frame.
@Test(.appTestApplication) @MainActor
func nativeLinkedResizeReleaseDoesNotResendDuringAHold() async throws {
    let f = try LinkedResizeFixture()
    defer { f.model.shutdown() }
    f.send(.leftMouseDown, 1)
    f.send(.leftMouseDragged, 2)
    f.controller.displayTick()
    f.system.ignoredFrameWriteWindowIDs = [f.peer]
    f.resizeSource(to: 600, timestamp: 3)
    f.controller.displayTick()
    try #require(f.system.frameWriteCounts[f.peer] == 1)
    try #require(try frame(f.peer, in: f.system) == f.peerFrame)
    f.system.ignoredFrameWriteWindowIDs = []
    f.model.handleDisplayChange(.displayReconfigurationBegan)
    f.send(.leftMouseUp, 4)
    await f.system.advance(by: .seconds(1))
    #expect(f.system.frameWriteCounts[f.peer] == 1, "Release resent the neighbour frame during the hold")
    f.model.handleDisplayChange(.displayReconfigurationEnded)
    try await settleHold(f.model, f.system)
    #expect(f.system.frameWriteCounts[f.peer] == 1)
}

/// A resize that the user starts during a hold is a new explicit action. It
/// links its neighbour as usual.
@Test(.appTestApplication) @MainActor
func aNativeLinkedResizeStartedDuringAHoldStillLinks() async throws {
    let f = try LinkedResizeFixture()
    defer { f.model.shutdown() }
    f.model.handleDisplayChange(.displayReconfigurationBegan)
    f.send(.leftMouseDown, 1)
    f.send(.leftMouseDragged, 2)
    f.controller.displayTick()
    f.resizeSource(to: 600, timestamp: 3)
    f.controller.displayTick()
    #expect(try frame(f.peer, in: f.system) == BTRect(x: 600, y: 0, width: 400, height: 800))
    f.send(.leftMouseUp, 4)
    f.model.handleDisplayChange(.displayReconfigurationEnded)
    try await settleHold(f.model, f.system)
    #expect(try frame(f.peer, in: f.system) == BTRect(x: 600, y: 0, width: 400, height: 800))
}

// MARK: - Tabbed exit in progress

enum ExplicitActionDuringExit: String, CaseIterable, Sendable {
    case keyboardSnap, refusedDrag, newerModeChoice
}

/// A mode exit from Tabbed waits for a pending placement. An explicit action
/// in that time does not cancel the exit; only a newer mode choice replaces it.
@Test(.appTestApplication, arguments: ExplicitActionDuringExit.allCases) @MainActor
func onlyANewerModeChoiceCancelsATabbedExitInProgress(action: ExplicitActionDuringExit) async throws {
    let system = makeManualWindowSystem(drivingPolicyDeadlines: true)
    system.windows.append(.init(id: .init(rawValue: "peer"), processIdentifier: 43, bundleIdentifier: "com.example.Peer",
        frame: BTRect(x: 300, y: 200, width: 600, height: 400), displayID: system.mainDisplay.id))
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.tabbedClock = system.clock
    model.setActiveMode(.tabbed)
    try #require(await system.waitFor { !model.hasPendingTabbedPlacement })
    model.performTabbed(.preset(.columns))
    model.setActiveMode(.manual)
    switch action {
    case .keyboardSnap: model.perform(.leftHalf)
    case .refusedDrag:
        #expect(!model.beginBentoDrag(displayID: system.mainDisplay.id, sourceID: system.windows[0].id))
    case .newerModeChoice: model.setActiveMode(.bento)
    }
    await system.advance(by: .seconds(1))
    try #require(await system.waitFor { !model.hasPendingTabbedPlacement && model.windowEventTask == nil })
    #expect(model.activeMode(for: system.mainDisplay.id) == (action == .newerModeChoice ? .bento : .manual))
}

// MARK: - Tabbed tab drag

/// A hold interrupts a Tabbed tab drag. After the hold the tab is back in its
/// group, the desktop keeps its automatic placement, and tabs can be dragged
/// again.
@Test(.appTestApplication) @MainActor
func aTabbedTabDragInterruptedByAHoldReturnsTheTabAndAllowsTabDrags() async throws {
    _ = NSApplication.shared
    let system = makeManualWindowSystem(drivingPolicyDeadlines: true)
    system.windows.append(.init(id: .init(rawValue: "peer"), processIdentifier: 43, bundleIdentifier: "com.example.Peer",
        frame: BTRect(x: 300, y: 200, width: 600, height: 400), displayID: system.mainDisplay.id))
    // Keep the test's own tab bar panels off every real screen.
    system.availableDisplays[0].frame.origin.x = 12000
    system.availableDisplays[0].visibleFrame.origin.x = 12000
    for index in system.windows.indices { system.windows[index].frame.origin.x += 12000 }
    let store = ConfigurationStore(fileURL: URL(filePath: "/private/tmp/BetterTileAppTests-\(UUID().uuidString)/configuration.json"))
    let model = makeOffscreenModel(store: store, system: system, startRuntime: false, presentsTabbedChrome: true)
    system.installWindowEventClock(in: model)
    model.primaryButtonIsPressed = { false }
    model.displayChangeScreenIsLocked = { false }
    defer { model.shutdown() }
    model.tabbedClock = system.clock
    let display = system.mainDisplay.id
    let overlays = { @MainActor in
        try #require(Mirror(reflecting: model).children.first {
            $0.label?.hasSuffix("tabbedOverlays") == true
        }?.value as? [DisplayID: TabbedOverlayController])
    }
    model.setActiveMode(.tabbed)
    try #require(await system.waitFor { !model.hasPendingTabbedPlacement })
    model.performTabbed(.preset(.columns, grouping: .distributeWindows))
    try #require(await system.waitFor { !model.hasPendingTabbedPlacement && model.windowEventTask == nil })
    try #require(await system.waitFor { (try? overlays()[display]?.acceptsTabDrags) == true })
    let state = try #require(model.activeTabbedState)
    let source = try #require(state.panes.first?.selected)
    let index = try #require(system.windows.firstIndex { $0.id == source })
    let placed = system.windows[index].frame
    try #require(model.beginBentoDrag(displayID: display, sourceID: source))
    try #require(try overlays()[display]?.acceptsTabDrags == false)
    system.windows[index].frame.origin.x += 120
    let writes = system.frameWriteCounts
    model.handleDisplayChange(.displayReconfigurationBegan)
    model.finishBentoDrag(displayID: display, sourceID: source, end: .restore)
    await system.advance(by: .seconds(1))
    #expect(system.frameWriteCounts == writes)
    model.handleDisplayChange(.displayReconfigurationEnded)
    try await settleHold(model, system)
    #expect(model.activeTabbedState?.windowIDs == state.windowIDs)
    #expect(model.activeTabbedState?.panes.map(\.tabs) == state.panes.map(\.tabs))
    #expect(try layoutSessionStore(model).session(for: display)?.automaticWritesSuspended == false)
    #expect(system.windows[index].frame.approximatelyEquals(placed, tolerance: 2))
    #expect(await system.waitFor { (try? overlays()[display]?.acceptsTabDrags) == true },
            "Tab drags stayed disabled after the hold")
}
