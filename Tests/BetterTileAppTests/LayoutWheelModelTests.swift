import BetterTileCore
import BetterTileMacOS
import Foundation
import Testing
@testable import BetterTileApp

@MainActor
private final class FakeAppWindowSystem: BetterTileWindowSystem {
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
    var frameWriteCounts: [WindowID: Int] = [:]
    var completeSweepCount = 0
    var cachedRefreshCount = 0
    var cachedSnapshotsAvailable = true
    var emitsFrameEvents = false
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
    func focusedWindow() throws -> WindowSnapshot? { windows.first }
    func visibleWindows() throws -> [WindowSnapshot] {
        completeSweepCount += 1
        return windows
    }
    func displays() -> [DisplaySnapshot] { availableDisplays }
    func windowSnapshots(ids: Set<WindowID>) throws -> [WindowSnapshot] {
        windows.filter { ids.contains($0.id) }
    }
    func cachedVisibleWindows(refreshing ids: Set<WindowID>) throws -> [WindowSnapshot]? {
        cachedRefreshCount += 1
        return cachedSnapshotsAvailable ? windows : nil
    }
    func setFrame(_ frame: BTRect, knownCurrentFrame: BTRect?, for windowID: WindowID) throws {
        guard let index = windows.firstIndex(where: { $0.id == windowID }) else {
            throw WindowSystemError.windowNotFound(windowID)
        }
        frameWriteCounts[windowID, default: 0] += 1
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
    func nativeDesktopObservation() -> NativeDesktopObservation? { nil }
    func refreshNativeDesktopObservation() -> NativeDesktopObservation? { nil }
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
            windows[index].constraints = minimumSizeLearner.merging(windows[index].constraints, for: windowID)
        }
        return learned
    }
    func startDockFootprintMonitoring(onChange: @escaping () -> Void) {}
    func stopDockFootprintMonitoring() {}
    func triggerDockFootprintCheck() {}
    func startDisplayReconfigurationMonitoring(onChange: @escaping @MainActor () -> Void) {}
    func stopDisplayReconfigurationMonitoring() {}
    func updateManagedWindowIDs(_ ids: Set<WindowID>) {}
}

@MainActor
private func makeModel(system: FakeAppWindowSystem) -> BetterTileModel {
    let store = ConfigurationStore(
        fileURL: URL(filePath: "/private/tmp/BetterTileAppTests-\(UUID().uuidString)/configuration.json")
    )
    return BetterTileModel(store: store, system: system, startRuntime: false)
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

    let contained = await waitFor(timeout: .seconds(1)) {
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
    try? await Task.sleep(for: .milliseconds(750))
    #expect(system.windows[1].constraints.minimumSize.width == 120)
    #expect(abs(system.windows[0].frame.size.width - system.windows[1].frame.size.width) < 1)
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
    try #require(await waitFor(timeout: .seconds(1)) { system.cachedRefreshCount >= 2 })

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
        try #require(await waitFor(timeout: .seconds(1)) { system.completeSweepCount > sweeps })
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
    try #require(await waitFor(timeout: .seconds(1)) { system.cachedRefreshCount >= 2 })

    let refresh = WindowSystemEvent(kind: .created, windowID: peerID, processIdentifier: 43)
    system.availableDisplays[0].visibleFrame.size.height = 700
    system.ignoredFrameWriteWindowIDs.insert(peerID)
    system.eventHandler?(refresh)
    try #require(await waitFor(timeout: .seconds(2)) {
        model.statusMessage == "One or more windows did not settle at the requested frame."
    })
    #expect(!PlacementBounds.isContained(system.windows[1].frame, in: system.availableDisplays[0].visibleFrame))

    // A failed settlement must leave the work-area change pending so a later
    // sweep can retry when the app starts accepting frame writes again.
    system.ignoredFrameWriteWindowIDs.remove(peerID)
    let samples = system.cachedRefreshCount
    system.eventHandler?(refresh)
    try #require(await waitFor(timeout: .seconds(1)) { system.cachedRefreshCount >= samples + 2 })
    #expect(system.windows.allSatisfy {
        PlacementBounds.isContained($0.frame, in: system.availableDisplays[0].visibleFrame)
    })
    let writes = system.frameWriteCounts
    let sweeps = system.completeSweepCount
    system.eventHandler?(refresh)
    try #require(await waitFor(timeout: .seconds(1)) { system.completeSweepCount > sweeps })
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
private func waitFor(
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
