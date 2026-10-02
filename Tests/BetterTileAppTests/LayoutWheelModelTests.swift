import BetterTileCore
import BetterTileMacOS
import Foundation
import AppKit
import SwiftUI
import Testing
@testable import BetterTileApp

@MainActor
final class FakeAppWindowSystem: BetterTileWindowSystem, TabbedWindowSystem {
    let mainDisplay = DisplaySnapshot(
        id: DisplayID(rawValue: "main"),
        frame: BTRect(x: 0, y: 0, width: 1000, height: 800),
        visibleFrame: BTRect(x: 0, y: 0, width: 1000, height: 800),
        isMain: true
    )
    var enhancedUserInterfacePolicy: EnhancedUserInterfacePolicy = .disableAndRestore
    var permission = true
    var ignoredFrameWriteWindowIDs: Set<WindowID> = []
    var enforcedMinimumWidths: [WindowID: Double] = [:]
    var enforcedMinimumHeights: [WindowID: Double] = [:]
    var frameWriteCounts: [WindowID: Int] = [:]
    var failedFrameWriteNumbers: [WindowID: Set<Int>] = [:]
    var completeSweepCount = 0
    var cachedRefreshCount = 0
    var cachedSnapshotsAvailable = true
    var emitsFrameEvents = false
    var desktopObservation: NativeDesktopObservation?
    var frameApplicationDelays: [WindowID: Duration] = [:]
    private var minimumSizeLearner = WindowMinimumSizeLearner()
    var availableDisplays: [DisplaySnapshot]
    var windows: [WindowSnapshot]
    var eventHandler: (@MainActor (WindowSystemEvent) -> Void)?

    init() {
        availableDisplays = [mainDisplay]
        windows = [WindowSnapshot(
            id: WindowID(rawValue: "focused"),
            processIdentifier: 42,
            bundleIdentifier: "com.example.Test",
            frame: BTRect(x: 200, y: 200, width: 600, height: 400),
            displayID: mainDisplay.id
        )]
    }

    func requestAccessibilityPermission(prompt: Bool) -> Bool { permission }
    var focusedID: WindowID?
    var focusRequests: [WindowID] = []
    var raiseRequests: [(WindowID, Bool)] = []
    var failingNextRaiseWindowID: WindowID?
    var windowNumberRequests: [Set<WindowID>] = []
    func windowNumbers(for windows: [WindowSnapshot]) -> [WindowID: Int] {
        windowNumberRequests.append(Set(windows.map(\.id)))
        return [:] // Simulate unavailable exact identities without live AX.
    }
    /// WindowServer order, front to back. Nil simulates unavailable exact
    /// identities. Raises move a window to the front, as AXRaise does.
    var stack: [TabbedStackEntry]?
    var updatesStackOnRaise = true
    func stackingOrder(for windows: [WindowSnapshot], excluding windowNumbers: Set<Int>) -> [TabbedStackEntry]? { stack }
    /// Simulates BetterTile or an unreadable app in front; otherwise the
    /// focused window's app is frontmost.
    var frontmostOverride: Int32?
    var frontmostProcessIdentifier: Int32? {
        frontmostOverride ?? (windows.first { $0.id == focusedID } ?? windows.first)?.processIdentifier
    }
    func raiseWindow(_ id: WindowID, activate: Bool) throws {
        if failingNextRaiseWindowID == id {
            failingNextRaiseWindowID = nil
            throw WindowSystemError.operationFailed("Injected window ordering failure.")
        }
        raiseRequests.append((id, activate))
        if activate { focusedID = id; focusRequests.append(id) }
        if updatesStackOnRaise, let index = stack?.firstIndex(where: { $0.windowID == id }), let entry = stack?.remove(at: index) {
            stack?.insert(entry, at: 0)
        }
    }
    func requestCloseWindow(_ id: WindowID) throws {}
    var focusedWindowReadFails = false
    func focusedWindow() throws -> WindowSnapshot? {
        if focusedWindowReadFails { throw WindowSystemError.operationFailed("Simulated focused-window failure") }
        return windows.first { $0.id == focusedID } ?? windows.first
    }
    func visibleWindows() throws -> [WindowSnapshot] {
        completeSweepCount += 1
        refreshLearnedConstraints()
        return windows
    }
    func displays() -> [DisplaySnapshot] { availableDisplays }
    func windowSnapshots(ids: Set<WindowID>) throws -> [WindowSnapshot] {
        refreshLearnedConstraints()
        return windows.filter { ids.contains($0.id) }
    }
    private func refreshLearnedConstraints() {
        for index in windows.indices {
            let id = windows[index].id
            minimumSizeLearner.observeAcceptedSize(windowID: id, size: windows[index].frame.size)
            if let reported = reportedConstraints[id] {
                windows[index].constraints = minimumSizeLearner.merging(reported, for: id)
            }
        }
    }
    func cachedVisibleWindows(refreshing ids: Set<WindowID>) throws -> [WindowSnapshot]? {
        cachedRefreshCount += 1
        refreshLearnedConstraints()
        return cachedSnapshotsAvailable ? windows : nil
    }
    func setFrame(_ frame: BTRect, knownCurrentFrame: BTRect?, for windowID: WindowID) throws {
        guard let index = windows.firstIndex(where: { $0.id == windowID }) else {
            throw WindowSystemError.windowNotFound(windowID)
        }
        frameWriteCounts[windowID, default: 0] += 1
        if failedFrameWriteNumbers[windowID]?.contains(frameWriteCounts[windowID, default: 0]) == true {
            throw WindowSystemError.operationFailed("Injected frame write failure.")
        }
        guard !ignoredFrameWriteWindowIDs.contains(windowID) else { return }
        if let delay = frameApplicationDelays[windowID] {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: delay)
                self?.applyFrame(frame, at: index)
            }
            return
        }
        applyFrame(frame, at: index)
    }
    private func applyFrame(_ frame: BTRect, at index: Int) {
        let windowID = windows[index].id
        windows[index].frame = frame
        windows[index].frame.size.width = max(frame.size.width, enforcedMinimumWidths[windowID] ?? 0)
        windows[index].frame.size.height = max(frame.size.height, enforcedMinimumHeights[windowID] ?? 0)
        if emitsFrameEvents {
            eventHandler?(WindowSystemEvent(kind: .resized, windowID: windowID, processIdentifier: windows[index].processIdentifier))
        }
    }
    func setMinimized(_ minimized: Bool, for windowID: WindowID) throws {
        guard let index = windows.firstIndex(where: { $0.id == windowID }) else {
            throw WindowSystemError.windowNotFound(windowID)
        }
        windows[index].isMinimized = minimized
    }

    func setWindowEventHandler(_ handler: (@MainActor (WindowSystemEvent) -> Void)?) {
        eventHandler = handler
    }
    func startWindowObservation() {}
    func stopWindowObservation() {}
    func refreshApplicationObservers() {}
    func resetCachedWindows() {}
    func nativeDesktopObservation() -> NativeDesktopObservation? { desktopObservation }
    func refreshNativeDesktopObservation() -> NativeDesktopObservation? { desktopObservation }
    func observeApplicationEnforcedMinimum(
        windowID: WindowID,
        requested: BTRect,
        baseline: BTRect,
        actual: BTRect
    ) -> Bool {
        let learned = minimumSizeLearner.observe(
            windowID: windowID, requested: requested, baseline: baseline, actual: actual
        )
        if let index = windows.firstIndex(where: { $0.id == windowID }) {
            if reportedConstraints[windowID] == nil { reportedConstraints[windowID] = windows[index].constraints }
            windows[index].constraints = minimumSizeLearner.merging(windows[index].constraints, for: windowID)
        }
        return learned
    }
    var reportedConstraints: [WindowID: WindowConstraints] = [:]
    var forgetLearnedMinimumsCount = 0
    func forgetLearnedMinimums() {
        forgetLearnedMinimumsCount += 1
        minimumSizeLearner.removeAll()
        for index in windows.indices {
            if let reported = reportedConstraints[windows[index].id] { windows[index].constraints = reported }
        }
    }
    func startDockFootprintMonitoring(onChange: @escaping () -> Void) {}
    func stopDockFootprintMonitoring() {}
    func triggerDockFootprintCheck() {}
    func startDisplayReconfigurationMonitoring(onChange: @escaping @MainActor () -> Void) {}
    func stopDisplayReconfigurationMonitoring() {}
    func updateManagedWindowIDs(_ ids: Set<WindowID>) {}
}

@MainActor
func makeModel(system: FakeAppWindowSystem) -> BetterTileModel {
    let store = ConfigurationStore(
        fileURL: URL(filePath: "/private/tmp/BetterTileAppTests-\(UUID().uuidString)/configuration.json")
    )
    let model = BetterTileModel(store: store, system: system, startRuntime: false)
    // Fake-window tests own button state; physical input must not defer work.
    model.primaryButtonIsPressed = { false }
    return model
}

@Test(arguments: [0, 4]) @MainActor
func returningToBentoSpaceWithPartialVisibilityDoesNotMoveItsWindows(extraIncompleteSweeps: Int) async throws {
    _ = NSApplication.shared
    let system = FakeAppWindowSystem()
    let firstSpace = NativeSpaceID(rawValue: 1)
    let secondSpace = NativeSpaceID(rawValue: 2)
    let displayID = system.mainDisplay.id
    system.windows.append(WindowSnapshot(
        id: WindowID(rawValue: "peer"), processIdentifier: 43,
        frame: BTRect(x: 200, y: 0, width: 800, height: 800), displayID: displayID
    ))
    system.desktopObservation = NativeDesktopObservation(
        currentSpaceByDisplay: [displayID: firstSpace],
        knownSpacesByDisplay: [displayID: [firstSpace, secondSpace]],
        windowMembership: Dictionary(uniqueKeysWithValues: system.windows.map { ($0.id, [firstSpace]) })
    )
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.configuration.singleWindowPlacement = .maximize
    model.tileCurrentDisplay()
    try #require(await waitFor { system.cachedRefreshCount >= 2 })
    let firstWindows = system.windows
    model.installWorkspaceTriggers()

    system.desktopObservation?.currentSpaceByDisplay[displayID] = secondSpace
    system.windows = []
    NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
    try await Task.sleep(for: .milliseconds(200))

    // macOS can expose one window before its peers during the transition.
    system.desktopObservation?.currentSpaceByDisplay[displayID] = firstSpace
    system.windows = [firstWindows[0]]
    let writes = system.frameWriteCounts
    NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
    try await Task.sleep(for: .milliseconds(200))
    #expect(system.windows[0].frame == firstWindows[0].frame)
    #expect(system.frameWriteCounts == writes)

    for _ in 0..<extraIncompleteSweeps {
        system.eventHandler?(WindowSystemEvent(kind: .created, windowID: firstWindows[0].id, processIdentifier: 42))
        try await Task.sleep(for: .milliseconds(180))
        #expect(system.frameWriteCounts == writes)
        #expect(system.windows[0].frame == firstWindows[0].frame)
    }

    system.windows.append(firstWindows[1])
    system.eventHandler?(WindowSystemEvent(kind: .created, windowID: firstWindows[1].id, processIdentifier: 43))
    try await Task.sleep(for: .milliseconds(300))
    #expect(system.windows.map(\.frame) == firstWindows.map(\.frame))
    #expect(system.frameWriteCounts == writes)

    // Late AX events from the switch read the current frames. They must not
    // reinterpret unchanged left/right panes as a new snap or divider move.
    for window in firstWindows {
        system.eventHandler?(WindowSystemEvent(kind: .resized, windowID: window.id, processIdentifier: window.processIdentifier))
    }
    try await Task.sleep(for: .milliseconds(200))
    #expect(system.windows.map(\.frame) == firstWindows.map(\.frame))
    #expect(system.frameWriteCounts == writes)
}

@Test(arguments: [false, true]) @MainActor
func bentoPlacementContainsAnUnreportedApplicationMinimum(automaticArrival: Bool) async {
    let system = FakeAppWindowSystem()
    let model = makeModel(system: system)
    defer { model.shutdown() }
    if automaticArrival { model.setActiveMode(.bento) }
    let peerID = WindowID(rawValue: "peer")
    system.windows.append(WindowSnapshot(
        id: peerID, processIdentifier: 43,
        frame: BTRect(x: 200, y: 0, width: 800, height: 800), displayID: system.mainDisplay.id
    ))
    system.enforcedMinimumWidths[peerID] = 600
    system.emitsFrameEvents = true
    if automaticArrival {
        system.eventHandler?(WindowSystemEvent(kind: .created, windowID: peerID, processIdentifier: 43))
    } else {
        model.tileCurrentDisplay()
    }

    let contained = await waitFor {
        let frames = system.windows.map(\.frame)
        return frames.allSatisfy { PlacementBounds.isContained($0, in: system.mainDisplay.visibleFrame) }
            && frames[0].intersection(frames[1]) == nil
    }
    #expect(contained, "Bento must adapt to the app's minimum without leaving it past the display or its neighbor.")
    #expect(system.frameWriteCounts[peerID, default: 0] <= 2)
    let settledFrames = system.windows.map(\.frame)
    try? await Task.sleep(for: .milliseconds(400))
    #expect(system.windows.map(\.frame) == settledFrames)
    #expect(system.frameWriteCounts[peerID, default: 0] <= 2)
}

@Test @MainActor func bentoRepairWaitsForADelayedAppWithoutLearningItsOldSize() async {
    let system = FakeAppWindowSystem()
    let peerID = WindowID(rawValue: "peer")
    system.windows.append(WindowSnapshot(
        id: peerID, processIdentifier: 43,
        frame: BTRect(x: 200, y: 0, width: 800, height: 800), displayID: system.mainDisplay.id
    ))
    system.frameApplicationDelays[peerID] = .milliseconds(200)
    system.emitsFrameEvents = true
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.tileCurrentDisplay()
    let settled = await waitFor {
        abs(system.windows[0].frame.size.width - system.windows[1].frame.size.width) < 1
    }
    #expect(settled)
    #expect(system.windows[1].constraints.minimumSize.width == 120)
    #expect(system.frameWriteCounts[peerID, default: 0] <= 2)
}

@Test(arguments: [true, false]) @MainActor
func snappedBentoLayoutDoesNotResizeAgainAfterItLands(cachedSnapshotsAvailable: Bool) async {
    let system = FakeAppWindowSystem()
    system.cachedSnapshotsAvailable = cachedSnapshotsAvailable
    system.windows.append(WindowSnapshot(
        id: WindowID(rawValue: "peer"), processIdentifier: 43,
        frame: BTRect(x: 200, y: 0, width: 800, height: 800), displayID: system.mainDisplay.id
    ))
    system.emitsFrameEvents = true
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.configuration.bentoInnerGap = 6
    model.tileCurrentDisplay()
    model.performLayoutWheel(.windowAction(.rightHalf), for: target(for: system))
    let landedFrames = system.windows.map(\.frame)
    let writes = system.frameWriteCounts
    let sweeps = system.completeSweepCount
    try? await Task.sleep(for: .milliseconds(500))
    #expect(system.windows.map(\.frame) == landedFrames)
    #expect(system.frameWriteCounts == writes)
    if cachedSnapshotsAvailable {
        #expect(system.completeSweepCount - sweeps <= 2)
    }
}

@Test(arguments: [false, true], [false, true]) @MainActor
func settledWorkAreaChangeDoesNotReapplyOnLaterSweeps(learnMinimum: Bool, delayed: Bool) async throws {
    let system = FakeAppWindowSystem()
    let peerID = WindowID(rawValue: "peer")
    system.windows.append(WindowSnapshot(
        id: peerID, processIdentifier: 43,
        frame: BTRect(x: 200, y: 0, width: 800, height: 800), displayID: system.mainDisplay.id
    ))
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.tileCurrentDisplay()
    try #require(await waitFor { system.cachedRefreshCount >= 2 })

    // A topology event drives the same ambient reconciliation used for a Dock
    // or display change, without installing live workspace observers.
    let refresh = WindowSystemEvent(kind: .created, windowID: peerID, processIdentifier: 43)
    system.availableDisplays[0].visibleFrame.size.width = 800
    system.availableDisplays[0].visibleFrame.size.height = 700
    if learnMinimum { system.enforcedMinimumWidths[peerID] = 450 }
    if delayed { system.frameApplicationDelays[peerID] = .milliseconds(200) }
    let samples = system.cachedRefreshCount
    system.eventHandler?(refresh)
    try #require(await waitFor(timeout: .seconds(2)) {
        system.cachedRefreshCount >= samples + 2
            && system.windows.allSatisfy { PlacementBounds.isContained($0.frame, in: system.availableDisplays[0].visibleFrame) }
            && system.windows[0].frame.intersection(system.windows[1].frame) == nil
    })
    // Allow the two 40ms stable samples and, for a learned minimum, the
    // authoritative verifier's 100ms read after the corrected frames arrive.
    try await Task.sleep(for: .milliseconds(200))
    let settledFrames = system.windows.map(\.frame)
    #expect(settledFrames.allSatisfy {
        PlacementBounds.isContained($0, in: system.availableDisplays[0].visibleFrame)
    })
    let writes = system.frameWriteCounts
    let settledSamples = system.cachedRefreshCount

    for _ in 0..<3 {
        let sweeps = system.completeSweepCount
        system.eventHandler?(refresh)
        try #require(await waitFor { system.completeSweepCount > sweeps })
        #expect(system.frameWriteCounts == writes, "A settled work-area change must not apply the layout again.")
    }
    try await Task.sleep(for: .milliseconds(150))
    #expect(system.cachedRefreshCount == settledSamples, "Later sweeps must not restart settlement.")
    #expect(system.windows.map(\.frame) == settledFrames)
}

@Test @MainActor func failedWorkAreaSettlementCanRetryOnALaterSweep() async throws {
    let system = FakeAppWindowSystem()
    let peerID = WindowID(rawValue: "peer")
    system.windows.append(WindowSnapshot(
        id: peerID, processIdentifier: 43,
        frame: BTRect(x: 200, y: 0, width: 800, height: 800), displayID: system.mainDisplay.id
    ))
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.tileCurrentDisplay()
    try #require(await waitFor { system.cachedRefreshCount >= 2 })

    let refresh = WindowSystemEvent(kind: .created, windowID: peerID, processIdentifier: 43)
    system.availableDisplays[0].visibleFrame.size.height = 700
    system.ignoredFrameWriteWindowIDs.insert(peerID)
    system.eventHandler?(refresh)
    try #require(await waitFor {
        model.statusMessage == "One or more windows did not settle at the requested frame."
    })
    #expect(!PlacementBounds.isContained(system.windows[1].frame, in: system.availableDisplays[0].visibleFrame))

    // A failed settlement must leave the work-area change pending so a later
    // sweep can retry when the app starts accepting frame writes again.
    system.ignoredFrameWriteWindowIDs.remove(peerID)
    let samples = system.cachedRefreshCount
    system.eventHandler?(refresh)
    try #require(await waitFor { system.cachedRefreshCount >= samples + 2 })
    #expect(system.windows.allSatisfy {
        PlacementBounds.isContained($0.frame, in: system.availableDisplays[0].visibleFrame)
    })
    let writes = system.frameWriteCounts
    let sweeps = system.completeSweepCount
    system.eventHandler?(refresh)
    try #require(await waitFor { system.completeSweepCount > sweeps })
    #expect(system.frameWriteCounts == writes)
}

@MainActor
private func target(for system: FakeAppWindowSystem) -> LayoutWheelTarget {
    LayoutWheelTarget(
        windowID: system.windows[0].id,
        displayID: system.windows[0].displayID,
        visibleFrame: system.mainDisplay.visibleFrame
    )
}

/// Waits for a state the model reaches from its delayed verification task.
///
/// A fixed sleep cannot express this wait. The check makes three attempts
/// 120ms apart and each one hops back to the main actor, so its total is set
/// by how loaded the machine is, not by a constant the test can pick. Polling
/// finishes as soon as the state arrives and only spends the timeout when the
/// state never arrives at all.
@MainActor
func waitFor(
    timeout: Duration = .seconds(10),
    _ condition: () -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
}

@Test @MainActor func manualLayoutWheelPreviewIsPureAndMatchesCommit() {
    let system = FakeAppWindowSystem()
    let model = makeModel(system: system)
    defer { model.shutdown() }
    let captured = target(for: system)
    let baseline = system.windows[0].frame

    guard case let .ready(placements) = model.previewLayoutWheel(
        .windowAction(.leftHalf),
        for: captured
    ) else {
        Issue.record("Expected a Manual Layout Wheel preview")
        return
    }

    #expect(system.windows[0].frame == baseline)
    #expect(placements.count == 1)
    model.performLayoutWheel(.windowAction(.leftHalf), for: captured)
    #expect(system.windows[0].frame == placements[0].frame)
}

@Test @MainActor func movingTheCapturedWindowToAnotherDisplayCancelsTheCommand() {
    let system = FakeAppWindowSystem()
    let model = makeModel(system: system)
    defer { model.shutdown() }
    let captured = target(for: system)
    let second = DisplaySnapshot(
        id: DisplayID(rawValue: "second"),
        frame: BTRect(x: 1000, y: 0, width: 1000, height: 800),
        visibleFrame: BTRect(x: 1000, y: 0, width: 1000, height: 800)
    )
    system.availableDisplays.append(second)
    system.windows[0].displayID = second.id

    guard case let .unavailable(reason) = model.previewLayoutWheel(
        .windowAction(.leftHalf),
        for: captured
    ) else {
        Issue.record("Expected the captured-display change to cancel")
        return
    }

    #expect(reason.contains("window or display"))
}

@Test @MainActor func ignoredApplicationFailsBeforeLayoutWheelMutation() {
    let system = FakeAppWindowSystem()
    let model = makeModel(system: system)
    defer { model.shutdown() }
    let captured = target(for: system)
    let baseline = system.windows[0].frame
    model.updateConfiguration {
        $0.applicationRules.set(.ignoreEverywhere, for: "com.example.Test")
    }

    guard case let .unavailable(reason) = model.previewLayoutWheel(
        .windowAction(.maximize),
        for: captured
    ) else {
        Issue.record("Expected the application rule to reject the command")
        return
    }

    #expect(reason == "BetterTile is set to ignore this app.")
    #expect(system.windows[0].frame == baseline)
}

@Test @MainActor func bentoLayoutWheelPreviewDoesNotCommitItsProposal() {
    let system = FakeAppWindowSystem()
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.setActiveMode(.bento)
    let captured = target(for: system)
    let baseline = system.windows[0].frame

    guard case let .ready(placements) = model.previewLayoutWheel(
        .windowAction(.rightHalf),
        for: captured
    ) else {
        Issue.record("Expected a Bento Layout Wheel preview")
        return
    }

    #expect(!placements.isEmpty)
    #expect(system.windows[0].frame == baseline)
    model.performLayoutWheel(.windowAction(.rightHalf), for: captured)
    #expect(system.windows[0].frame == placements.first(where: {
        $0.windowID == captured.windowID
    })?.frame)
}

@Test @MainActor func bentoLayoutWheelFocusActionMatchesKeyboardPolicy() throws {
    let system = FakeAppWindowSystem()
    let peer = WindowSnapshot(
        id: WindowID(rawValue: "peer"),
        processIdentifier: 43,
        bundleIdentifier: "com.example.Peer",
        frame: BTRect(x: 0, y: 0, width: 200, height: 300),
        displayID: system.mainDisplay.id
    )
    system.windows.append(peer)
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.setActiveMode(.bento)
    let captured = target(for: system)
    let peerBaseline = try #require(system.windows.first(where: { $0.id == peer.id }))

    guard case let .ready(placements) = model.previewLayoutWheel(
        .windowAction(.maximize),
        for: captured
    ) else {
        Issue.record("Expected a Layout Wheel focus-action preview")
        return
    }

    #expect(placements.map(\.windowID) == [captured.windowID])
    model.performLayoutWheel(.windowAction(.maximize), for: captured)
    #expect(system.windows.first(where: { $0.id == peer.id })?.frame == peerBaseline.frame)
    #expect(
        system.windows.first(where: { $0.id == peer.id })?.isMinimized
            == peerBaseline.isMinimized
    )
}

@Test @MainActor func repairBentoRequiresBentoAndRunsWhenAvailable() {
    let system = FakeAppWindowSystem()
    let model = makeModel(system: system)
    defer { model.shutdown() }
    let captured = target(for: system)

    guard case let .unavailable(reason) = model.previewLayoutWheel(
        .repairBento,
        for: captured
    ) else {
        Issue.record("Expected Repair Bento to require a Bento desktop")
        return
    }

    #expect(reason == "Repair Bento is available only on a Bento desktop.")
    model.performLayoutWheel(.repairBento, for: captured)
    #expect(model.lastActionFeedback?.message == "Bento not active")

    model.setActiveMode(.bento)
    guard case let .ready(placements) = model.previewLayoutWheel(
        .repairBento,
        for: captured
    ) else {
        Issue.record("Expected Repair Bento on a Bento desktop")
        return
    }

    #expect(placements.isEmpty)
    model.statusMessage = "Repair did not run."
    model.performLayoutWheel(.repairBento, for: captured)
    #expect(model.statusMessage == nil)
    #expect(model.lastActionFeedback?.kind == .success)
}

@Test func menuBarDefaultOrderMatchesTheNativeCatalogExactly() {
    #expect(WindowActionGroup.flattenedActions == WindowAction.menuBarDefaultOrder)
    #expect(Set(WindowActionGroup.flattenedActions) == Set(WindowAction.allCases))
    #expect(WindowActionGroup.flattenedActions.count == 34)
}

@Test func menuActionOrderingCommitsOneValidatedInsertion() {
    let actions: [WindowAction] = [.leftHalf, .rightHalf, .topHalf, .bottomHalf]
    #expect(
        MenuActionOrder.moving(.leftHalf, toInsertionIndex: 3, in: actions)
            == [.rightHalf, .topHalf, .leftHalf, .bottomHalf]
    )
    #expect(
        MenuActionOrder.moving(.bottomHalf, toInsertionIndex: 0, in: actions)
            == [.bottomHalf, .leftHalf, .rightHalf, .topHalf]
    )
    #expect(MenuActionOrder.moving(.leftHalf, toInsertionIndex: 0, in: actions) == nil)
    #expect(MenuActionOrder.moving(.leftHalf, toInsertionIndex: 1, in: actions) == nil)
    #expect(MenuActionOrder.moving(.restore, toInsertionIndex: 2, in: actions) == nil)
    #expect(MenuActionOrder.moving(.leftHalf, toInsertionIndex: 99, in: actions) == nil)
}

@Test func menuActionKeyboardMovesRespectRowsAndBounds() {
    let actions: [WindowAction] = [.leftHalf, .rightHalf, .topHalf, .bottomHalf]
    #expect(MenuActionOrder.moving(.leftHalf, by: -1, in: actions) == nil)
    #expect(MenuActionOrder.moving(.bottomHalf, by: 1, in: actions) == nil)
    #expect(
        MenuActionOrder.moving(.topHalf, by: -2, in: actions)
            == [.topHalf, .leftHalf, .rightHalf, .bottomHalf]
    )
    #expect(
        MenuActionOrder.moving(.rightHalf, by: 2, in: actions)
            == [.leftHalf, .topHalf, .bottomHalf, .rightHalf]
    )
}

@Test func menuPanelHeightTracksItsContentAndCapsToTheDisplay() {
    let empty = MenuPanelMetrics.viewportHeight(actionCount: 0, editing: false, availableHeight: 700, chromeHeight: 280)
    let one = MenuPanelMetrics.viewportHeight(actionCount: 1, editing: false, availableHeight: 700, chromeHeight: 280)
    let three = MenuPanelMetrics.viewportHeight(actionCount: 3, editing: false, availableHeight: 700, chromeHeight: 280)
    let all = MenuPanelMetrics.viewportHeight(actionCount: 34, editing: false, availableHeight: 700, chromeHeight: 280)
    #expect(empty == 72)
    #expect(one == MenuPanelMetrics.tileHeight)
    #expect(three == MenuPanelMetrics.tileHeight * 2 + MenuPanelMetrics.gap)
    #expect(all == MenuPanelMetrics.maximumActionHeight)
    // Additional permission/update/feedback chrome reduces only the scroll area.
    #expect(MenuPanelMetrics.viewportHeight(actionCount: 34, editing: false,
                                           availableHeight: 500, chromeHeight: 350) == 150)
    #expect(MenuPanelMetrics.viewportHeight(actionCount: 34, editing: false,
                                           availableHeight: 200, chromeHeight: 350) == 0)
    #expect(MenuPanelMetrics.actionHeight(actionCount: 3, editing: true) > three)
    #expect(
        MenuPanelMetrics.tileWidth * 2
            + MenuPanelMetrics.gap
            + MenuPanelMetrics.padding * 2
            == MenuPanelMetrics.width
    )
}

@Test func menuDragPreviewsAnOrderWithoutChangingTheSavedOrder() {
    let original: [WindowAction] = [.leftHalf, .rightHalf, .topHalf, .bottomHalf]
    var drag = MenuActionDrag(source: .leftHalf, actions: original)
    #expect(drag.move(to: 4)?.to == 3)
    #expect(drag.original == original)
    #expect(drag.committedOrder == [.rightHalf, .topHalf, .bottomHalf, .leftHalf])
    #expect(drag.move(to: 4) == nil)
    #expect(drag.move(to: 0)?.to == 0)
    #expect(drag.committedOrder == nil)
    #expect(drag.move(to: -1) == nil)
}

@Test @MainActor func menuScrollHostOwnsItsGutterAndRetainsItsDocument() throws {
    let scroll = MenuPanelScrollHost(content: Color.clear.frame(height: 600))
    scroll.frame = CGRect(x: 0, y: 0, width: 328, height: 200)
    scroll.layoutSubtreeIfNeeded()
    let document = try #require(scroll.documentView)
    #expect(scroll.scrollerStyle == .overlay)
    #expect(!scroll.hasHorizontalScroller)
    #expect(scroll.contentSize.width == 328)
    #expect(document.frame.width == 328)
    #expect(document.frame.height == 600)
    scroll.update(content: Color.clear.frame(height: 700))
    #expect(scroll.documentView === document)
    #expect(document.frame.height == 700)
}

@Test(arguments: [260.0, 400.0, 619.0, 620.0, 900.0])
func snapZoneLayoutKeepsTheScreenInsideAvailableSpace(width: Double) {
    let layout = SnapZoneLayout(width: width)
    #expect(layout.monitorWidth <= width)
    #expect(layout.monitorWidth > 0)
    #expect(layout.height > layout.monitorWidth / 1.6)
    if layout.isWide { #expect(layout.monitorWidth + 280 <= width) }
}

@Test func snapZoneMarkersStayOnTheirTriggerEdgesAndSeparateFromPlacement() {
    let size = CGSize(width: 360, height: 225)
    let screen = CGRect(origin: .zero, size: size)
    for area in SnapArea.allCases {
        let marker = SnapZonePreviewGeometry.marker(for: area, in: size)
        #expect(screen.contains(marker))
        let target = SnapZonePreviewGeometry.trigger(for: area)
        let targetFrame = CGRect(x: target.x * size.width, y: target.y * size.height,
                                 width: target.width * size.width, height: target.height * size.height)
        #expect(targetFrame.contains(CGPoint(x: marker.midX, y: marker.midY)))
    }
    #expect(SnapZonePreviewGeometry.marker(for: .topLeft, in: size).size == CGSize(width: 22, height: 22))
    #expect(SnapZonePreviewGeometry.trigger(for: .topLeft).width == 0.3)
    #expect(SnapZonePreviewGeometry.trigger(for: .topLeft).height == 0.36)
    #expect(SnapZonePreviewGeometry.marker(for: .right, in: size).maxX == size.width)
    #expect(SnapZonePreviewGeometry.marker(for: .bottom, in: size).maxY == size.height)
}

@Test func snapZonePreviewKeepsCenterDistinctFromCenterResize() throws {
    let centered = try #require(SnapZonePreviewGeometry.placement(for: .center))
    let resized = try #require(SnapZonePreviewGeometry.placement(for: .centerResize))
    #expect(centered.x == 0.3)
    #expect(centered.y == 0.3)
    #expect(centered.width == 0.4)
    #expect(centered.height == 0.4)
    #expect(resized.x == 0.1)
    #expect(resized.y == 0.1)
    #expect(resized.width == 0.8)
    #expect(resized.height == 0.8)
    #expect(SnapZonePreviewGeometry.placement(for: nil) == nil)
}

@Test @MainActor func menuOnlyConfigurationPersistsWithoutWindowWritesOrWheelChanges() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = ConfigurationStore(fileURL: directory.appending(path: "configuration.json"))
    let system = FakeAppWindowSystem()
    let model = BetterTileModel(store: store, system: system, startRuntime: false)
    defer { model.shutdown() }
    let wheel = model.configuration.layoutWheel

    model.updateConfiguration { $0.menuBarActions = [.rightHalf, .leftHalf] }
    model.flushConfiguration()

    #expect(system.frameWriteCounts.isEmpty)
    #expect(model.configuration.layoutWheel == wheel)
    #expect(try store.load().menuBarActions == [.rightHalf, .leftHalf])
}

@Test @MainActor func menuCollectionLaysOutEveryTileAtItsAssignedSize() throws {
    _ = NSApplication.shared
    let actions = WindowAction.menuBarDefaultOrder
    let host = NSHostingView(rootView:
        MenuActionCollection(actions: actions, shortcuts: [], commit: { _, _ in })
    .frame(width: 328, height: 328)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator)))
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 328, height: 328),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    func collection(in view: NSView) -> NSCollectionView? {
        if let found = view as? NSCollectionView { return found }
        return view.subviews.compactMap { collection(in: $0) }.first
    }
    let view = try #require(collection(in: host))
    view.layoutSubtreeIfNeeded()
    let first = try #require(view.item(at: IndexPath(item: 0, section: 0)))
    let point = try #require(host.superview).convert(CGPoint(x: first.view.frame.midX, y: first.view.frame.midY), from: view)
    let hit = host.hitTest(point)
    #expect(hit === first.view)
    for index in view.indexPathsForVisibleItems().map(\.item) {
        let path = IndexPath(item: index, section: 0)
        let item = try #require(view.item(at: path))
        let attributes = try #require(view.collectionViewLayout?.layoutAttributesForItem(at: path))
        // AppKit aligns item origins to device pixels. A 1x CI display may
        // round the half-point column origin that a 2x display represents exactly.
        let pixelTolerance = 0.5 / window.backingScaleFactor + 0.001
        #expect(abs(item.view.frame.minX - attributes.frame.minX) <= pixelTolerance)
        #expect(abs(item.view.frame.minY - attributes.frame.minY) <= pixelTolerance)
        #expect(item.view.frame.width == MenuPanelMetrics.tileWidth)
        #expect(item.view.frame.height == MenuPanelMetrics.tileHeight)
    }
}

@Test @MainActor func menuKeyboardReorderingRetainsSelectionAfterConfigurationRefresh() throws {
    _ = NSApplication.shared
    var actions: [WindowAction] = [.leftHalf, .rightHalf, .topHalf, .bottomHalf]
    var commits = 0
    func content() -> some View {
        MenuActionCollection(actions: actions, shortcuts: [], commit: { order, _ in
            actions = order
            commits += 1
        }).frame(width: 328, height: 160)
    }
    let host = NSHostingView(rootView: content())
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 328, height: 160),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    func find(in view: NSView) -> MenuReorderCollectionView? {
        if let found = view as? MenuReorderCollectionView { return found }
        return view.subviews.compactMap { find(in: $0) }.first
    }
    let collection = try #require(find(in: host))
    collection.selectionIndexPaths = [IndexPath(item: 0, section: 0)]
    collection.moveSelection?(1)
    host.rootView = content()
    host.layoutSubtreeIfNeeded()
    #expect(collection.selectionIndexPaths == [IndexPath(item: 1, section: 0)])
    collection.moveSelection?(1)
    #expect(commits == 2)
    #expect(actions == [.rightHalf, .topHalf, .leftHalf, .bottomHalf])
}

@Test(arguments: [false, true]) @MainActor
func shutdownRemovesApplicationNotificationObservers(queuedBeforeShutdown: Bool) async {
    _ = NSApplication.shared
    let system = FakeAppWindowSystem()
    let model = makeModel(system: system)
    model.installWorkspaceTriggers()
    if queuedBeforeShutdown {
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApplication.shared)
    }
    model.shutdown()
    let sweeps = system.completeSweepCount
    NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApplication.shared)
    try? await Task.sleep(for: .milliseconds(30))
    #expect(system.completeSweepCount == sweeps)
    model.shutdown()
}

@Test @MainActor func menuConfigurationRefreshCancelsActiveDrag() async throws {
    _ = NSApplication.shared
    let actions = WindowAction.menuBarDefaultOrder
    let content = MenuActionCollection(actions: actions, shortcuts: [], commit: { _, _ in
        Issue.record("An external configuration refresh must not commit the drag")
    })
    let host = NSHostingView(rootView: content.frame(width: 328, height: 200))
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 328, height: 200),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    func find(in view: NSView) -> MenuReorderCollectionView? {
        if let found = view as? MenuReorderCollectionView { return found }
        return view.subviews.compactMap { find(in: $0) }.first
    }
    let view = try #require(find(in: host))
    let coordinator = try #require(view.delegate as? MenuActionCollection.Coordinator)
    coordinator.beginDrag(at: 0, in: view)
    let info = MenuTestDraggingInfo(collection: view, point: CGPoint(x: 30, y: 190))
    _ = view.draggingUpdated(info)
    try await Task.sleep(for: .milliseconds(20))
    #expect(view.dragDisplayLink != nil)
    #expect(view.visibleItems().contains { $0.view.alphaValue == 0 })

    var updated = content
    updated.actions = Array(actions.reversed())
    host.rootView = updated.frame(width: 328, height: 200)
    host.layoutSubtreeIfNeeded()
    #expect(coordinator.drag == nil)
    #expect(view.dragDisplayLink == nil)
    #expect(coordinator.displayed == updated.actions)
    #expect(view.visibleItems().allSatisfy { $0.view.alphaValue == 1 })
    _ = view.draggingUpdated(info)
    #expect(view.dragDisplayLink == nil)
    coordinator.endDrag(in: view)
    #expect(coordinator.displayed == updated.actions)
}

@Test(arguments: [false, true]) @MainActor
func shutdownIgnoresPendingWindowEvents(deliveredAfterShutdown: Bool) async throws {
    let system = FakeAppWindowSystem()
    let model = makeModel(system: system)
    let callback = try #require(system.eventHandler)
    let event = WindowSystemEvent(kind: .created, windowID: system.windows[0].id, processIdentifier: 42)
    if !deliveredAfterShutdown { callback(event) }
    model.shutdown()
    let sweeps = system.completeSweepCount
    if deliveredAfterShutdown { callback(event) }
    try await Task.sleep(for: WindowEventRetryBackoff.initialDelay + .milliseconds(100))
    #expect(system.completeSweepCount == sweeps)
    #expect(system.frameWriteCounts.isEmpty)
}

@Test @MainActor func menuCollectionScrollsToOffscreenTiles() throws {
    _ = NSApplication.shared
    let actions = WindowAction.menuBarDefaultOrder
    let host = NSHostingView(rootView:
        MenuActionCollection(actions: actions, shortcuts: [], commit: { _, _ in })
    .frame(width: 328, height: 200))
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 328, height: 200),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    func find(in view: NSView) -> NSCollectionView? {
        if let found = view as? NSCollectionView { return found }
        return view.subviews.compactMap { find(in: $0) }.first
    }
    let view = try #require(find(in: host))
    let last = IndexPath(item: actions.count - 1, section: 0)
    view.layoutSubtreeIfNeeded()
    let lastFrame = try #require(view.layoutAttributesForItem(at: last)).frame
    view.scrollToItems(at: [last], scrollPosition: .bottom)
    #expect(view.visibleRect.contains(lastFrame))
    let first = IndexPath(item: 0, section: 0)
    let firstFrame = try #require(view.layoutAttributesForItem(at: first)).frame
    view.scrollToItems(at: [first], scrollPosition: .top)
    #expect(view.visibleRect.contains(firstFrame))
}

@MainActor private final class MenuTestDraggingInfo: NSObject, @MainActor NSDraggingInfo {
    let collection: NSCollectionView
    var draggingLocation: NSPoint
    init(collection: NSCollectionView, point: NSPoint) {
        self.collection = collection
        draggingLocation = collection.convert(point, to: nil)
    }
    var draggingDestinationWindow: NSWindow? { collection.window }
    var draggingSourceOperationMask: NSDragOperation { .move }
    var draggedImageLocation: NSPoint { draggingLocation }
    var draggedImage: NSImage? { nil }
    var draggingPasteboard: NSPasteboard { NSPasteboard(name: NSPasteboard.Name("BetterTile-menu-test")) }
    var draggingSource: Any? { collection }
    var draggingSequenceNumber: Int { 1 }
    var draggingFormation: NSDraggingFormation = .none
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    nonisolated override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
    func resetSpringLoading() {}
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions, for view: NSView?,
                                classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
                                using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
}

@Test @MainActor func menuAdjacentDragSwapsOnEnteringItsNeighborAndKeepsTheAcceptedOrder() async throws {
    _ = NSApplication.shared
    var saved: [WindowAction] = [.leftHalf, .rightHalf, .topHalf, .bottomHalf]
    let host = NSHostingView(rootView: MenuActionCollection(actions: saved, shortcuts: [], commit: { order, _ in
        saved = order
    }).frame(width: 328, height: 200))
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 328, height: 200),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    func find(in view: NSView) -> NSCollectionView? {
        if let found = view as? NSCollectionView { return found }
        return view.subviews.compactMap { find(in: $0) }.first
    }
    let view = try #require(find(in: host))
    let coordinator = try #require(view.delegate as? MenuActionCollection.Coordinator)
    let neighbor = try #require(view.layoutAttributesForItem(at: IndexPath(item: 1, section: 0))).frame
    let info = MenuTestDraggingInfo(collection: view, point: CGPoint(x: neighbor.minX + 1, y: neighbor.midY))
    coordinator.beginDrag(at: 0, in: view)
    try await Task.sleep(for: .milliseconds(20))
    #expect(view.item(at: IndexPath(item: 0, section: 0))?.view.alphaValue == 0)
    var proposed = NSIndexPath(forItem: 1, inSection: 0)
    var operation = NSCollectionView.DropOperation.before
    #expect(coordinator.collectionView(view, validateDrop: info, proposedIndexPath: &proposed, dropOperation: &operation) == .move)
    #expect(coordinator.displayed == [.rightHalf, .leftHalf, .topHalf, .bottomHalf])
    #expect(view.item(at: IndexPath(item: 1, section: 0))?.view.alphaValue == 0)
    // Staying over the new slot must not repeatedly flip the two neighbors.
    _ = coordinator.collectionView(view, validateDrop: info, proposedIndexPath: &proposed, dropOperation: &operation)
    #expect(coordinator.displayed == [.rightHalf, .leftHalf, .topHalf, .bottomHalf])
    #expect(coordinator.collectionView(view, acceptDrop: info, indexPath: proposed as IndexPath, dropOperation: operation))
    #expect(saved == [.rightHalf, .leftHalf, .topHalf, .bottomHalf])
    // The drag-end callback must see the new order before SwiftUI refreshes.
    #expect(coordinator.parent.actions == saved)
    coordinator.endDrag(in: view)
    #expect(coordinator.displayed == saved)
    // A second drag starts from the accepted order, even before a SwiftUI update.
    coordinator.drag = MenuActionDrag(source: .leftHalf, actions: coordinator.parent.actions)
    info.draggingLocation = view.convert(CGPoint(x: 30, y: 30), to: nil)
    _ = coordinator.collectionView(view, validateDrop: info, proposedIndexPath: &proposed, dropOperation: &operation)
    #expect(coordinator.displayed.first == .leftHalf)
    coordinator.endDrag(in: view) // Escape/outside drop: restore the saved order.
    #expect(coordinator.displayed == saved)
    #expect(coordinator.drag == nil)
    #expect(view.visibleItems().allSatisfy { $0.view.alphaValue == 1 })

    coordinator.drag = MenuActionDrag(source: .rightHalf, actions: saved)
    coordinator.previewDrop(at: CGPoint(x: neighbor.midX, y: neighbor.midY), in: view, time: 1)
    let firstPreview = coordinator.displayed
    coordinator.previewDrop(at: CGPoint(x: neighbor.midX, y: 100), in: view, time: 1.01)
    if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
        #expect(coordinator.displayed.last == .rightHalf)
    } else {
        #expect(coordinator.displayed == firstPreview)
    }
    coordinator.previewDrop(at: CGPoint(x: neighbor.midX, y: 100), in: view, time: 1.2)
    #expect(coordinator.displayed.last == .rightHalf)
    coordinator.endDrag(in: view)
    #expect(coordinator.displayed == saved)
}

@Test @MainActor func menuDragAutoscrollUsesTheEdgeVisibleInsideSettings() throws {
    _ = NSApplication.shared
    let host = NSHostingView(rootView: MenuActionCollection(actions: WindowAction.menuBarDefaultOrder,
        shortcuts: [], commit: { _, _ in }).frame(width: 328, height: 400))
    host.frame = CGRect(x: 0, y: 0, width: 328, height: 400)
    let outer = NSScrollView(frame: CGRect(x: 0, y: 0, width: 328, height: 200))
    outer.documentView = host
    let window = NSWindow(contentRect: outer.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = outer
    outer.layoutSubtreeIfNeeded()
    func find(in view: NSView) -> NSCollectionView? {
        if let found = view as? NSCollectionView { return found }
        return view.subviews.compactMap { find(in: $0) }.first
    }
    let view = try #require(find(in: host) as? MenuReorderCollectionView)
    let scroll = try #require(view.enclosingScrollView)
    let before = scroll.contentView.bounds.origin
    let visible = view.visibleRect
    #expect(visible.height == 200)
    let coordinator = try #require(view.delegate as? MenuActionCollection.Coordinator)
    coordinator.beginDrag(at: 0, in: view)
    let info = MenuTestDraggingInfo(collection: view,
        point: CGPoint(x: visible.midX, y: visible.maxY - 12))
    #expect(view.wantsPeriodicDraggingUpdates())
    _ = view.draggingUpdated(info)
    #expect(scroll.contentView.bounds.origin == before)
    #expect(view.dragDisplayLink != nil)
    defer { view.stopDragFrames() }
    for step in 0..<900 { view.advanceDragFrame(time: Double(step) / 60) }
    let last = IndexPath(item: WindowAction.menuBarDefaultOrder.count - 1, section: 0)
    let lastFrame = try #require(view.layoutAttributesForItem(at: last)).frame
    #expect(view.visibleRect.contains(lastFrame))
    info.draggingLocation = view.convert(CGPoint(x: view.visibleRect.midX, y: view.visibleRect.minY + 12), to: nil)
    _ = view.draggingUpdated(info)
    for step in 900..<1800 { view.advanceDragFrame(time: Double(step) / 60) }
    let firstFrame = try #require(view.layoutAttributesForItem(at: IndexPath(item: 0, section: 0))).frame
    #expect(view.visibleRect.contains(firstFrame))
    info.draggingLocation = view.convert(CGPoint(x: view.visibleRect.midX, y: view.visibleRect.midY), to: nil)
    let centeredOrigin = scroll.contentView.bounds.origin
    _ = view.draggingUpdated(info)
    view.advanceDragFrame(time: 30)
    #expect(scroll.contentView.bounds.origin == centeredOrigin)
    view.draggingExited(info)
    #expect(view.dragDisplayLink != nil) // Leaving the box must not end drag scrolling.
    view.stopDragFrames()
    #expect(view.lastDragScrollTime == nil)
    _ = view.draggingUpdated(info)
    #expect(view.dragDisplayLink != nil)
    window.contentView = nil
    #expect(view.dragDisplayLink == nil)
}

@Test @MainActor func menuDragScrollsTheSettingsPageOutsideTheTileColumn() throws {
    _ = NSApplication.shared
    let host = NSHostingView(rootView: MenuActionCollection(actions: WindowAction.menuBarDefaultOrder,
        shortcuts: [], commit: { _, _ in }).frame(width: 328, height: 400).frame(width: 600, height: 800))
    host.frame = CGRect(x: 0, y: 0, width: 600, height: 800)
    let outer = NSScrollView(frame: CGRect(x: 0, y: 0, width: 600, height: 300))
    outer.documentView = host
    let window = NSWindow(contentRect: outer.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = outer
    outer.layoutSubtreeIfNeeded()
    func find(in view: NSView) -> MenuReorderCollectionView? {
        if let found = view as? MenuReorderCollectionView { return found }
        return view.subviews.compactMap { find(in: $0) }.first
    }
    let view = try #require(find(in: host))
    let inner = try #require(view.enclosingScrollView)
    let initial = outer.contentView.bounds.origin
    let innerInitial = inner.contentView.bounds.origin
    // Well below the window and outside the narrower tile column.
    let bottom = NSPoint(x: 20, y: -150)
    for step in 0..<120 { view.scrollDuringDrag(at: bottom, time: Double(step) / 60) }
    #expect(outer.contentView.bounds.origin != initial)
    #expect(inner.contentView.bounds.origin == innerInitial)
    let middle = NSPoint(x: 20, y: 150)
    let stopped = outer.contentView.bounds.origin
    for step in 120..<180 { view.scrollDuringDrag(at: middle, time: Double(step) / 60) }
    #expect(outer.contentView.bounds.origin == stopped)
    let top = NSPoint(x: 20, y: 450)
    for step in 180..<300 { view.scrollDuringDrag(at: top, time: Double(step) / 60) }
    #expect(outer.contentView.bounds.origin == initial)
}

private final class MenuTestDraggingSession: NSDraggingSession {
    var point: NSPoint = .zero
    override var draggingLocation: NSPoint { point }
}

@Test @MainActor func menuSourceDragScrollsBeyondBothEdgesAndStopsOnCancellation() throws {
    _ = NSApplication.shared
    let actions = WindowAction.menuBarDefaultOrder
    var commits = 0
    let host = NSHostingView(rootView: MenuActionCollection(actions: actions,
        shortcuts: [], commit: { _, _ in commits += 1 }).frame(width: 328, height: 200))
    let window = NSWindow(contentRect: CGRect(x: 300, y: 250, width: 328, height: 200),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    func find(in view: NSView) -> MenuReorderCollectionView? {
        if let found = view as? MenuReorderCollectionView { return found }
        return view.subviews.compactMap { find(in: $0) }.first
    }
    let view = try #require(find(in: host))
    let coordinator = try #require(view.delegate as? MenuActionCollection.Coordinator)
    let session = MenuTestDraggingSession()
    coordinator.beginDrag(at: 0, in: view)
    view.startDragFrames(session: session)
    defer { view.stopDragFrames() }
    session.point = window.convertPoint(toScreen: NSPoint(x: 100, y: -200))
    view.draggingExited(nil)
    for step in 0..<180 { view.advanceDragFrame(time: Double(step) / 60) }
    let lastFrame = try #require(view.layoutAttributesForItem(at: IndexPath(item: actions.count - 1, section: 0))).frame
    #expect(view.visibleRect.contains(lastFrame))
    #expect(coordinator.displayed == actions) // Outside scrolling does not select an outside drop.
    session.point = window.convertPoint(toScreen: NSPoint(x: 100, y: 400))
    for step in 180..<360 { view.advanceDragFrame(time: Double(step) / 60) }
    let firstFrame = try #require(view.layoutAttributesForItem(at: IndexPath(item: 0, section: 0))).frame
    #expect(view.visibleRect.contains(firstFrame))
    coordinator.endDrag(in: view)
    #expect(view.dragDisplayLink == nil)
    #expect(view.lastDragScrollTime == nil)
    session.point = window.convertPoint(toScreen: NSPoint(x: 100, y: -200))
    for step in 360..<540 { view.advanceDragFrame(time: Double(step) / 60) }
    #expect(view.visibleRect.contains(firstFrame))
    #expect(commits == 0)
}

@Test @MainActor func newWindowSideAppliesToFutureWindowsOnASingleWindowDesktop() async throws {
    let system = FakeAppWindowSystem()
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.configuration.defaultLayoutMode = .bento
    model.tileCurrentDisplay()
    let frames = system.windows.map(\.frame)
    let writes = system.frameWriteCounts
    model.updateConfiguration { $0.bentoNewWindowSide = .right }
    try await Task.sleep(for: .milliseconds(150))
    #expect(system.windows.map(\.frame) == frames)
    #expect(system.frameWriteCounts == writes)

    let oldID = system.windows[0].id
    let newID = WindowID(rawValue: "new")
    system.windows.insert(WindowSnapshot(
        id: newID, processIdentifier: 43,
        frame: BTRect(x: 100, y: 100, width: 600, height: 600), displayID: system.mainDisplay.id
    ), at: 0) // The newcomer is focused, as a newly opened app normally is.
    system.eventHandler?(WindowSystemEvent(kind: .created, windowID: newID, processIdentifier: 43))
    try #require(await waitFor {
        let newFrame = system.windows.first { $0.id == newID }!.frame
        let oldFrame = system.windows.first { $0.id == oldID }!.frame
        return newFrame.minX >= oldFrame.maxX
    })
    let settled = system.windows.map(\.frame)
    model.updateConfiguration { $0.bentoNewWindowSide = .left }
    try await Task.sleep(for: .milliseconds(250))
    #expect(system.windows.map(\.frame) == settled)
}

@Test(arguments: [false, true], [false, true]) @MainActor
func minimizedRightHalfReturnsToItsOriginalSide(nativeMembership: Bool, staleMinimizeSnapshot: Bool) async throws {
    let system = FakeAppWindowSystem()
    system.windows.append(WindowSnapshot(
        id: WindowID(rawValue: "peer"), processIdentifier: 43,
        frame: BTRect(x: 0, y: 0, width: 500, height: 800), displayID: system.mainDisplay.id
    ))
    system.emitsFrameEvents = true
    if nativeMembership {
        let space = NativeSpaceID(rawValue: 1)
        system.desktopObservation = NativeDesktopObservation(
            currentSpaceByDisplay: [system.mainDisplay.id: space],
            knownSpacesByDisplay: [system.mainDisplay.id: [space]],
            windowMembership: Dictionary(uniqueKeysWithValues: system.windows.map { ($0.id, [space]) })
        )
    }
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.configuration.singleWindowPlacement = .maximize
    model.tileCurrentDisplay()
    model.performLayoutWheel(.windowAction(.rightHalf), for: target(for: system))
    try await Task.sleep(for: .milliseconds(500))
    let originalFrames = system.windows.map(\.frame)
    try #require(originalFrames[0].minX > originalFrames[1].minX)

    let restoredID = system.windows[0].id
    if staleMinimizeSnapshot {
        let sweeps = system.completeSweepCount
        system.eventHandler?(WindowSystemEvent(kind: .minimized, windowID: restoredID, processIdentifier: 42))
        try #require(await waitFor { system.completeSweepCount > sweeps })
    }
    system.windows[0].isMinimized = true
    system.desktopObservation?.windowMembership.removeValue(forKey: restoredID)
    if staleMinimizeSnapshot {
        for _ in 0..<4 {
            let sweeps = system.completeSweepCount
            system.eventHandler?(WindowSystemEvent(kind: .created, windowID: system.windows[1].id, processIdentifier: 43))
            try #require(await waitFor { system.completeSweepCount > sweeps })
        }
    } else {
        system.eventHandler?(WindowSystemEvent(kind: .minimized, windowID: restoredID, processIdentifier: 42))
    }
    try #require(await waitFor { system.windows[1].frame.size.width == 1000 })
    try await Task.sleep(for: .milliseconds(300))
    system.windows[0].isMinimized = false
    if nativeMembership { system.desktopObservation?.windowMembership[restoredID] = [NativeSpaceID(rawValue: 1)] }
    system.eventHandler?(WindowSystemEvent(kind: .restored, windowID: restoredID, processIdentifier: 42))
    try await Task.sleep(for: .milliseconds(700))
    #expect(system.windows.map(\.frame) == originalFrames)
}
