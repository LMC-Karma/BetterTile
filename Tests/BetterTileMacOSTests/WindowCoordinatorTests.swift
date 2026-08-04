import AppKit
import Testing
@testable import BetterTileCore
@testable import BetterTileMacOS

@Test @MainActor func coordinatorAppliesActionAndRestoreThroughFakeSystem() throws {
    let system = FakeWindowSystem()
    let original = system.windows[0].frame
    let coordinator = WindowCoordinator(system: system)
    #expect(coordinator.perform(.leftHalf))
    #expect(system.windows[0].frame.size.width == 500)
    #expect(coordinator.perform(.restore))
    #expect(system.windows[0].frame == original)
}

@Test @MainActor func placementTransactionsUseTargetedWindowSnapshots() {
    let system = FakeWindowSystem()
    let coordinator = WindowCoordinator(system: system)
    let placement = Placement(
        windowID: system.windows[0].id,
        frame: BTRect(x: 0, y: 0, width: 500, height: 800)
    )

    #expect(coordinator.applyPlacements([placement]))
    #expect(system.targetedSnapshotRequests >= 2)
}

@Test @MainActor func coordinatorCanPlanAnActionWithoutMovingTheWindow() throws {
    let system = FakeWindowSystem()
    let original = system.windows[0].frame
    let coordinator = WindowCoordinator(system: system)
    let plan = try #require(coordinator.plan(.leftThird))

    #expect(plan.resolvedAction == .leftThird)
    #expect(plan.windowID == system.windows[0].id)
    #expect(plan.targetFrame == BTRect(x: 0, y: 0, width: 1_000.0 / 3.0, height: 800))
    #expect(system.windows[0].frame == original)
    #expect(coordinator.perform(plan))
    #expect(system.windows[0].frame == plan.targetFrame)
}

@Test @MainActor func plannedHalfActionsPreserveShortcutCycling() throws {
    let system = FakeWindowSystem()
    let coordinator = WindowCoordinator(system: system)
    let first = try #require(coordinator.plan(.leftHalf))
    #expect(first.resolvedAction == .leftHalf)
    #expect(coordinator.perform(first))

    let second = try #require(coordinator.plan(.leftHalf))
    #expect(second.resolvedAction == .leftThird)
    #expect(coordinator.perform(second))
    #expect(system.windows[0].frame == second.targetFrame)
}

@Test @MainActor func displayTransferWraps() {
    let system = FakeWindowSystem()
    system.availableDisplays.append(DisplaySnapshot(
        id: DisplayID(rawValue: "second"),
        frame: BTRect(x: 1000, y: 0, width: 2000, height: 1200),
        visibleFrame: BTRect(x: 1000, y: 0, width: 2000, height: 1200)
    ))
    let coordinator = WindowCoordinator(system: system)
    #expect(coordinator.perform(.nextDisplay))
    #expect(system.windows[0].frame.minX >= 1000)
}

@Test @MainActor func ghostPreviewDoesNotMutateFramesUntilCommit() throws {
    let system = FakeWindowSystem()
    system.addSecondWindow()
    let coordinator = WindowCoordinator(system: system)
    let original = system.windows.map(\.frame)
    var transaction = try #require(coordinator.beginTransaction(windowIDs: Set(system.windows.map(\.id))))
    let placements = [
        Placement(windowID: system.windows[0].id, frame: BTRect(x: 0, y: 0, width: 500, height: 800)),
        Placement(windowID: system.windows[1].id, frame: BTRect(x: 500, y: 0, width: 500, height: 800)),
    ]
    #expect(coordinator.preview(transaction: &transaction, placements: placements))
    #expect(system.windows.map(\.frame) == original)
    #expect(coordinator.commit(transaction: &transaction))
    #expect(system.windows.map(\.frame) == placements.map(\.frame))
}

@Test @MainActor func liveTransactionCanBeCancelledToItsBaseline() throws {
    let system = FakeWindowSystem()
    system.addSecondWindow()
    let coordinator = WindowCoordinator(system: system)
    let original = system.windows.map(\.frame)
    var transaction = try #require(coordinator.beginTransaction(windowIDs: Set(system.windows.map(\.id))))
    let placements = [
        Placement(windowID: system.windows[0].id, frame: BTRect(x: 0, y: 0, width: 650, height: 800)),
        Placement(windowID: system.windows[1].id, frame: BTRect(x: 650, y: 0, width: 350, height: 800)),
    ]
    #expect(coordinator.applyLive(transaction: &transaction, placements: placements))
    #expect(system.windows.map(\.frame) == placements.map(\.frame))
    coordinator.cancel(transaction: transaction)
    #expect(system.windows.map(\.frame) == original)
}

@Test @MainActor func partialTransactionFailureRollsBackAppliedWindows() throws {
    let system = FakeWindowSystem()
    system.addSecondWindow()
    let coordinator = WindowCoordinator(system: system)
    let original = system.windows.map(\.frame)
    let failingID = system.windows[1].id
    system.failingWindowID = failingID
    var transaction = try #require(coordinator.beginTransaction(windowIDs: Set(system.windows.map(\.id))))
    let placements = [
        Placement(windowID: system.windows[0].id, frame: BTRect(x: 0, y: 0, width: 500, height: 800)),
        Placement(windowID: failingID, frame: BTRect(x: 500, y: 0, width: 500, height: 800)),
    ]
    #expect(!coordinator.commit(transaction: &transaction, placements: placements))
    #expect(system.windows.map(\.frame) == original)
}

@Test @MainActor func authoritativeSettlementRetriesOnlyAcceptedButUnappliedFrames() async throws {
    let system = FakeWindowSystem()
    system.addSecondWindow()
    let coordinator = WindowCoordinator(system: system)
    let placements = [
        Placement(windowID: system.windows[0].id, frame: BTRect(x: 0, y: 0, width: 500, height: 700)),
        Placement(windowID: system.windows[1].id, frame: BTRect(x: 500, y: 0, width: 500, height: 700)),
    ]
    system.ignoredFrameWriteCounts[system.windows[1].id] = 1

    #expect(coordinator.applyPlacements(placements))
    #expect(await coordinator.settleAuthoritativePlacements(placements, retryDelay: .zero))
    #expect(system.windows.map(\.frame) == placements.map(\.frame))
    #expect(system.frameWriteCounts[system.windows[0].id] == 1)
    #expect(system.frameWriteCounts[system.windows[1].id] == 2)
}

@Test @MainActor func authoritativeSettlementStopsAfterItsRetryLimit() async throws {
    let system = FakeWindowSystem()
    system.addSecondWindow()
    let coordinator = WindowCoordinator(system: system)
    let placements = [
        Placement(windowID: system.windows[0].id, frame: BTRect(x: 0, y: 0, width: 500, height: 700)),
        Placement(windowID: system.windows[1].id, frame: BTRect(x: 500, y: 0, width: 500, height: 700)),
    ]
    system.ignoredFrameWriteCounts[system.windows[1].id] = 3

    #expect(coordinator.applyPlacements(placements))
    #expect(!(await coordinator.settleAuthoritativePlacements(placements, retryDelay: .zero)))
    #expect(system.frameWriteCounts[system.windows[1].id] == 3)
    #expect(coordinator.lastError == "One or more windows did not settle at the requested frame.")
}

@Test @MainActor func focusDropRollsBackFramesAndMinimizedWindowsAfterPartialFailure() throws {
    let system = FakeWindowSystem()
    system.addSecondWindow()
    let third = WindowSnapshot(
        id: WindowID(rawValue: "third"), processIdentifier: 44,
        frame: BTRect(x: 0, y: 0, width: 200, height: 200), displayID: DisplayID(rawValue: "main")
    )
    system.windows.append(third)
    system.failingMinimizeWindowID = third.id
    let coordinator = WindowCoordinator(system: system)
    let source = system.windows[0]
    let target = BTRect(x: 0, y: 0, width: 1000, height: 800)

    #expect(!coordinator.applyFocusDrop(
        placement: Placement(windowID: source.id, frame: target),
        minimizing: [system.windows[1].id, third.id],
        sourceBaselineFrame: source.frame
    ))
    #expect(system.windows.first(where: { $0.id == source.id })?.frame == source.frame)
    #expect(system.windows.first(where: { $0.id == system.windows[1].id })?.isMinimized == false)
    #expect(system.windows.first(where: { $0.id == third.id })?.isMinimized == false)
}

@Test @MainActor func transactionHistoryIncludesOnlyWindowsWhoseFramesChanged() throws {
    let system = FakeWindowSystem()
    system.addSecondWindow()
    let unchanged = WindowSnapshot(
        id: WindowID(rawValue: "unchanged"),
        processIdentifier: 44,
        frame: BTRect(x: 0, y: 0, width: 1000, height: 120),
        displayID: DisplayID(rawValue: "main")
    )
    system.windows.append(unchanged)
    let coordinator = WindowCoordinator(system: system)
    let first = system.windows[0]
    let second = system.windows[1]
    var transaction = try #require(coordinator.beginTransaction(windowIDs: Set(system.windows.map(\.id))))
    let placements = [
        Placement(windowID: first.id, frame: second.frame),
        Placement(windowID: second.id, frame: first.frame),
        Placement(windowID: unchanged.id, frame: unchanged.frame),
    ]

    #expect(coordinator.commit(transaction: &transaction, placements: placements))
    system.focusedWindowID = unchanged.id
    #expect(!coordinator.perform(.restore))
    system.focusedWindowID = first.id
    #expect(coordinator.perform(.restore))
    #expect(system.windows.first(where: { $0.id == first.id })?.frame == first.frame)
}

@Test @MainActor func coordinatorFiltersOnlyItsOwnExpectedFrameEvent() throws {
    let system = FakeWindowSystem()
    let coordinator = WindowCoordinator(system: system)
    let id = system.windows[0].id
    let target = BTRect(x: 0, y: 0, width: 500, height: 800)
    #expect(coordinator.applyPlacements([Placement(windowID: id, frame: target)]))
    #expect(coordinator.consumeExpectedMutation(windowID: id, actualFrame: target))
    #expect(!coordinator.consumeExpectedMutation(
        windowID: id,
        actualFrame: BTRect(x: 0, y: 0, width: 650, height: 800)
    ))
}

@Test @MainActor func fakeEventSourceEmitsDeterministicNativeResizeEvent() {
    let system = FakeWindowSystem()
    var received: WindowSystemEvent?
    system.setWindowEventHandler { received = $0 }
    let event = WindowSystemEvent(kind: .resized, windowID: system.windows[0].id, processIdentifier: 42)
    system.emit(event)
    #expect(received == event)
}

@Test func stageManagerThumbnailFramesAreRejected() {
    let full = BTRect(x: 100, y: 100, width: 800, height: 600)
    let decorated = BTRect(x: 100, y: 99, width: 800, height: 601)
    let thumbnail = BTRect(x: 20, y: 100, width: 160, height: 120)
    #expect(OnscreenWindowMatcher.matches(accessibilityFrame: full, windowServerFrame: decorated))
    #expect(!OnscreenWindowMatcher.matches(accessibilityFrame: full, windowServerFrame: thumbnail))
}

@Test func windowSystemNeverManagesItsOwnApplicationWindows() {
    #expect(!AccessibilityWindowSystem.shouldManageApplication(
        processIdentifier: 42,
        ownProcessIdentifier: 42,
        activationPolicy: .regular,
        isHidden: false,
        includeHidden: false
    ))
    #expect(AccessibilityWindowSystem.shouldManageApplication(
        processIdentifier: 43,
        ownProcessIdentifier: 42,
        activationPolicy: .regular,
        isHidden: false,
        includeHidden: false
    ))
}

@Test func bentoSwapSupportsTallerUnifiedToolbarsWithoutEnteringWindowContent() {
    let frame = BTRect(x: 100, y: 100, width: 500, height: 400)
    #expect(BentoSwapDragRegion.isTitleBarStart(BTPoint(x: 200, y: 112), in: frame))
    #expect(BentoSwapDragRegion.isTitleBarStart(BTPoint(x: 200, y: 170), in: frame))
    #expect(!BentoSwapDragRegion.isTitleBarStart(BTPoint(x: 200, y: 190), in: frame))
    #expect(!BentoSwapDragRegion.isTitleBarStart(BTPoint(x: 104, y: 112), in: frame))
    #expect(!BentoSwapDragRegion.isTitleBarStart(BTPoint(x: 596, y: 112), in: frame))
}

@Test func dividerHandleIsSuppressedWhenAFloatingWindowCoversIt() {
    let handle = BTRect(x: 490, y: 300, width: 20, height: 56)
    let settings = BTRect(x: 300, y: 180, width: 700, height: 520)
    let besideHandle = BTRect(x: 520, y: 300, width: 200, height: 200)

    #expect(DividerHandleOcclusion.isCovered(handle, by: [settings]))
    #expect(!DividerHandleOcclusion.isCovered(handle, by: [besideHandle]))

    let displayID = DisplayID(rawValue: "main")
    let managed = WindowSnapshot(
        id: WindowID(rawValue: "managed"),
        processIdentifier: 1,
        frame: BTRect(x: 0, y: 0, width: 500, height: 800),
        displayID: displayID
    )
    let floating = WindowSnapshot(
        id: WindowID(rawValue: "floating"),
        processIdentifier: 2,
        frame: settings,
        displayID: displayID
    )
    #expect(DividerHandleOcclusion.obscuringFrames(
        in: [managed, floating],
        excluding: [managed.id]
    ) == [settings])
}

@Test func bentoDragResolvesTheWindowUnderThePointerWhenFocusIsStale() throws {
    let displayID = DisplayID(rawValue: "main")
    let staleFocus = WindowSnapshot(
        id: WindowID(rawValue: "stale"),
        processIdentifier: 1,
        frame: BTRect(x: 0, y: 100, width: 400, height: 400),
        displayID: displayID
    )
    let dragged = WindowSnapshot(
        id: WindowID(rawValue: "dragged"),
        processIdentifier: 2,
        frame: BTRect(x: 500, y: 100, width: 400, height: 400),
        displayID: displayID
    )

    let resolved = try #require(BentoDragWindowResolver.window(
        at: BTPoint(x: 650, y: 120),
        focusedWindow: staleFocus,
        visibleWindows: [staleFocus, dragged]
    ))
    #expect(resolved.id == dragged.id)
}

@Test func bentoDragPrefersTheFocusedWindowWhenTitleBarsOverlap() throws {
    let displayID = DisplayID(rawValue: "main")
    let focused = WindowSnapshot(
        id: WindowID(rawValue: "focused"),
        processIdentifier: 1,
        frame: BTRect(x: 100, y: 100, width: 500, height: 400),
        displayID: displayID
    )
    let behind = WindowSnapshot(
        id: WindowID(rawValue: "behind"),
        processIdentifier: 2,
        frame: BTRect(x: 150, y: 100, width: 400, height: 400),
        displayID: displayID
    )

    let resolved = try #require(BentoDragWindowResolver.window(
        at: BTPoint(x: 250, y: 120),
        focusedWindow: focused,
        visibleWindows: [behind, focused]
    ))
    #expect(resolved.id == focused.id)
}

@Test func windowDragGateRequiresTheOriginalCandidateToActuallyMove() {
    let displayID = DisplayID(rawValue: "main")
    let original = WindowSnapshot(
        id: WindowID(rawValue: "dragged"),
        processIdentifier: 1,
        frame: BTRect(x: 100, y: 100, width: 500, height: 400),
        displayID: displayID
    )
    let other = WindowSnapshot(
        id: WindowID(rawValue: "focused-later"),
        processIdentifier: 2,
        frame: original.frame.offsetBy(dx: 20, dy: 20),
        displayID: displayID
    )
    var gate = WindowDragGate()

    #expect(gate.activate(with: other) == nil)
    gate.begin(with: original)
    #expect(gate.activate(with: original) == nil)
    #expect(gate.activate(with: other) == nil)

    var resized = original
    resized.frame.size.width += 20
    #expect(gate.activate(with: resized) == nil)

    var jittered = original
    jittered.frame = original.frame.offsetBy(dx: 1, dy: 1)
    #expect(gate.activate(with: jittered) == nil)

    var moved = original
    moved.frame = original.frame.offsetBy(dx: 2, dy: 0)
    #expect(gate.activate(with: moved) == original.id)
    #expect(gate.activate(with: nil) == original.id)
}

@Test func dockFootprintRequiresStableAppearanceAndDelayedDisappearance() {
    let displayID = DisplayID(rawValue: "main")
    let footprint = DockFootprint(edge: .bottom, thickness: 80)
    var stabilizer = DockFootprintStabilizer()
    stabilizer.sample([displayID: footprint], timestamp: 1)
    #expect(stabilizer.visible[displayID] == nil)
    stabilizer.sample([displayID: footprint], timestamp: 1.09)
    #expect(stabilizer.visible[displayID] == nil)
    stabilizer.sample([displayID: footprint], timestamp: 1.1)
    #expect(stabilizer.visible[displayID] == footprint)

    stabilizer.sample([:], timestamp: 2)
    stabilizer.sample([:], timestamp: 2.49)
    #expect(stabilizer.visible[displayID] == footprint)
    stabilizer.sample([:], timestamp: 2.5)
    #expect(stabilizer.visible[displayID] == nil)
}

@Test func dockSamplingLeaseCoalescesTriggersAndStopsAfterStableSamples() {
    var lease = DockSamplingLease()
    lease.trigger(at: 1)
    #expect(lease.isActive)

    lease.recordSample(changed: false, at: 1.2)
    lease.recordSample(changed: false, at: 1.4)
    lease.recordSample(changed: false, at: 1.6)
    #expect(lease.isActive)

    lease.recordSample(changed: false, at: 1.7)
    #expect(!lease.isActive)

    lease.trigger(at: 2)
    lease.recordSample(changed: true, at: 2.2)
    lease.recordSample(changed: false, at: 2.4)
    lease.recordSample(changed: false, at: 2.6)
    #expect(lease.isActive)
    lease.recordSample(changed: false, at: 2.9)
    #expect(!lease.isActive)
}

@Test func dockSamplingLeaseHasABoundedMaximumDuration() {
    var lease = DockSamplingLease()
    lease.trigger(at: 10)
    for step in 1...20 {
        lease.trigger(at: 10 + Double(step) / 10)
        lease.recordSample(changed: true, at: 10 + Double(step) / 10)
    }
    #expect(!lease.isActive)
}

@Test func visibleDockFootprintsReserveBottomAndSideWorkAreas() {
    let displayID = DisplayID(rawValue: "main")
    let full = BTRect(x: 0, y: 0, width: 1200, height: 800)
    let appKitVisible = BTRect(x: 0, y: 24, width: 1200, height: 776)
    var stabilizer = DockFootprintStabilizer()
    stabilizer.sample([displayID: DockFootprint(edge: .bottom, thickness: 80)], timestamp: 1)
    stabilizer.sample([displayID: DockFootprint(edge: .bottom, thickness: 80)], timestamp: 1.1)
    #expect(stabilizer.effectiveFrame(
        displayID: displayID, fullFrame: full, appKitVisibleFrame: appKitVisible
    ) == BTRect(x: 0, y: 24, width: 1200, height: 696))

    stabilizer.sample([:], timestamp: 2)
    stabilizer.sample([:], timestamp: 2.5)
    #expect(stabilizer.effectiveFrame(
        displayID: displayID, fullFrame: full, appKitVisibleFrame: appKitVisible
    ) == appKitVisible)

    var left = DockFootprintStabilizer()
    left.sample([displayID: DockFootprint(edge: .left, thickness: 80)], timestamp: 1)
    left.sample([displayID: DockFootprint(edge: .left, thickness: 80)], timestamp: 1.1)
    #expect(left.effectiveFrame(
        displayID: displayID, fullFrame: full, appKitVisibleFrame: appKitVisible
    ) == BTRect(x: 80, y: 24, width: 1120, height: 776))

    var right = DockFootprintStabilizer()
    right.sample([displayID: DockFootprint(edge: .right, thickness: 80)], timestamp: 1)
    right.sample([displayID: DockFootprint(edge: .right, thickness: 80)], timestamp: 1.1)
    #expect(right.effectiveFrame(
        displayID: displayID, fullFrame: full, appKitVisibleFrame: appKitVisible
    ) == BTRect(x: 0, y: 24, width: 1120, height: 776))
}

@MainActor
private final class FakeWindowSystem: WindowSystem, TargetedWindowSystem, WindowEventSource {
    var availableDisplays = [DisplaySnapshot(
        id: DisplayID(rawValue: "main"),
        frame: BTRect(x: 0, y: 0, width: 1000, height: 800),
        visibleFrame: BTRect(x: 0, y: 0, width: 1000, height: 800),
        isMain: true
    )]
    var windows: [WindowSnapshot]
    var failingWindowID: WindowID?
    var ignoredFrameWriteCounts: [WindowID: Int] = [:]
    var frameWriteCounts: [WindowID: Int] = [:]
    var failingMinimizeWindowID: WindowID?
    var focusedWindowID: WindowID?
    var eventHandler: (@MainActor (WindowSystemEvent) -> Void)?
    var targetedSnapshotRequests = 0
    /// Every `knownCurrentFrame` hint the coordinator supplied, per window, in
    /// call order. `nil` means the coordinator had no fresh reading.
    var recordedKnownCurrentFrames: [WindowID: [BTRect?]] = [:]
    /// Simulates an application that refuses to grow beyond a fixed width.
    var clampWidth: Double?

    init() {
        windows = [WindowSnapshot(
            id: WindowID(rawValue: "focused"), processIdentifier: 42, bundleIdentifier: "com.example.Test",
            frame: BTRect(x: 200, y: 200, width: 600, height: 400), displayID: DisplayID(rawValue: "main")
        )]
    }

    func requestAccessibilityPermission(prompt: Bool) -> Bool { true }
    func focusedWindow() throws -> WindowSnapshot? {
        focusedWindowID.flatMap { id in windows.first(where: { $0.id == id }) } ?? windows.first
    }
    func visibleWindows() throws -> [WindowSnapshot] { windows }
    func windowSnapshots(ids: Set<WindowID>) throws -> [WindowSnapshot] {
        targetedSnapshotRequests += 1
        return windows.filter { ids.contains($0.id) }
    }
    func displays() -> [DisplaySnapshot] { availableDisplays }
    func setWindowEventHandler(_ handler: (@MainActor (WindowSystemEvent) -> Void)?) { eventHandler = handler }
    func startWindowObservation() {}
    func stopWindowObservation() {}
    func emit(_ event: WindowSystemEvent) { eventHandler?(event) }

    func setFrame(_ frame: BTRect, knownCurrentFrame: BTRect?, for windowID: WindowID) throws {
        recordedKnownCurrentFrames[windowID, default: []].append(knownCurrentFrame)
        if failingWindowID == windowID { throw WindowSystemError.operationFailed("Simulated Accessibility failure") }
        guard let index = windows.firstIndex(where: { $0.id == windowID }) else { throw WindowSystemError.windowNotFound(windowID) }
        frameWriteCounts[windowID, default: 0] += 1
        if ignoredFrameWriteCounts[windowID, default: 0] > 0 {
            ignoredFrameWriteCounts[windowID, default: 0] -= 1
            return
        }
        var applied = frame
        if let clampWidth { applied.size.width = min(applied.size.width, clampWidth) }
        windows[index].frame = applied
        windows[index].displayID = availableDisplays.first(where: { $0.visibleFrame.intersection(applied)?.area ?? 0 > applied.area / 2 })?.id ?? windows[index].displayID
    }

    func setMinimized(_ minimized: Bool, for windowID: WindowID) throws {
        if failingMinimizeWindowID == windowID { throw WindowSystemError.operationFailed("Simulated minimize failure") }
        guard let index = windows.firstIndex(where: { $0.id == windowID }) else { throw WindowSystemError.windowNotFound(windowID) }
        windows[index].isMinimized = minimized
    }

    func addSecondWindow() {
        windows.append(WindowSnapshot(
            id: WindowID(rawValue: "second"), processIdentifier: 43, bundleIdentifier: "com.example.Second",
            frame: BTRect(x: 800, y: 200, width: 200, height: 400), displayID: DisplayID(rawValue: "main")
        ))
    }
}

// MARK: - Accessibility write hints

@Test @MainActor func actionsTellTheSystemWhereTheWindowCurrentlyIs() throws {
    let system = FakeWindowSystem()
    let original = system.windows[0].frame
    let coordinator = WindowCoordinator(system: system)
    let id = system.windows[0].id

    #expect(coordinator.perform(.leftHalf))
    #expect(system.recordedKnownCurrentFrames[id] == [original])
}

@Test @MainActor func aMoveActionLetsTheSystemSkipTheLeadingSizeWrite() throws {
    let system = FakeWindowSystem()
    let coordinator = WindowCoordinator(system: system)
    let id = system.windows[0].id
    let before = system.windows[0].frame

    #expect(coordinator.perform(.moveRight))
    let hint = try #require(system.recordedKnownCurrentFrames[id]?.first ?? nil)
    // A move keeps the size, so the planner drops one of the three AX writes.
    let plan = FrameWritePlanner.plan(target: system.windows[0].frame, knownCurrentFrame: hint)
    #expect(hint == before)
    #expect(plan.writeCount == 2)
}

@Test @MainActor func transactionsPassTheBaselineAsTheCurrentFrame() throws {
    let system = FakeWindowSystem()
    system.addSecondWindow()
    let coordinator = WindowCoordinator(system: system)
    let baselines = Dictionary(uniqueKeysWithValues: system.windows.map { ($0.id, $0.frame) })
    var transaction = try #require(coordinator.beginTransaction(windowIDs: Set(system.windows.map(\.id))))
    let placements = system.windows.map {
        Placement(windowID: $0.id, frame: BTRect(x: 0, y: 0, width: 500, height: 800))
    }

    #expect(coordinator.commit(transaction: &transaction, placements: placements))
    for (id, baseline) in baselines {
        #expect(system.recordedKnownCurrentFrames[id]?.first == baseline)
    }
}

@Test @MainActor func liveTransactionsPassTheLastAppliedFrameNotTheBaseline() throws {
    let system = FakeWindowSystem()
    let coordinator = WindowCoordinator(system: system)
    let id = system.windows[0].id
    var transaction = try #require(coordinator.beginTransaction(windowIDs: [id]))

    let first = BTRect(x: 0, y: 0, width: 400, height: 800)
    let second = BTRect(x: 0, y: 0, width: 450, height: 800)
    #expect(coordinator.applyLive(transaction: &transaction, placements: [Placement(windowID: id, frame: first)]))
    #expect(coordinator.applyLive(transaction: &transaction, placements: [Placement(windowID: id, frame: second)]))

    let hints = try #require(system.recordedKnownCurrentFrames[id])
    #expect(hints.count == 2)
    #expect(hints[1] == first)
}

@Test @MainActor func rollbackTellsTheSystemTheWindowIsAtTheFrameItJustWrote() throws {
    let system = FakeWindowSystem()
    system.addSecondWindow()
    let coordinator = WindowCoordinator(system: system)
    let firstID = system.windows[0].id
    system.failingWindowID = system.windows[1].id

    let placements = system.windows.map {
        Placement(windowID: $0.id, frame: BTRect(x: 0, y: 0, width: 500, height: 800))
    }
    #expect(!coordinator.applyPlacements(placements))

    // Two writes for the first window: the forward apply, then the rollback,
    // which knows the window is sitting at the frame the forward apply wrote.
    let hints = try #require(system.recordedKnownCurrentFrames[firstID])
    #expect(hints.count == 2)
    #expect(hints[1] == placements[0].frame)
}

@Test @MainActor func theConvenienceOverloadStillPerformsAFullWrite() throws {
    let system = FakeWindowSystem()
    let id = system.windows[0].id
    try system.setFrame(BTRect(x: 10, y: 10, width: 300, height: 300), for: id)
    #expect(system.recordedKnownCurrentFrames[id] == [nil])
}

// MARK: - Truthful outcomes

/// A successful Accessibility write is not the same as a window that moved.
/// Reporting the write told the user an action succeeded while they were
/// looking at a window that had not moved.
@Test @MainActor func anActionThatLeavesTheWindowPutIsReportedAsAFailure() throws {
    let system = FakeWindowSystem()
    let coordinator = WindowCoordinator(system: system)
    let original = system.windows[0].frame
    system.ignoredFrameWriteCounts[system.windows[0].id] = 1

    #expect(!coordinator.perform(.leftHalf))
    #expect(system.windows[0].frame == original)
    #expect(coordinator.lastError == "The window did not move where it was asked to.")
}

/// A window that keeps a size of its own is still where the user asked for it,
/// so the action succeeded and nothing is reported.
@Test @MainActor func anActionIsStillASuccessWhenTheWindowKeepsItsOwnSize() throws {
    let system = FakeWindowSystem()
    system.clampWidth = 400
    let coordinator = WindowCoordinator(system: system)

    #expect(coordinator.perform(.leftHalf))
    #expect(system.windows[0].frame.size.width == 400)
    #expect(system.windows[0].frame.minX == 0, "the position is still honoured")
    #expect(coordinator.lastError == nil)
}

@Test @MainActor func placementsOutsideTheDisplayAreRejected() throws {
    let system = FakeWindowSystem()
    let coordinator = WindowCoordinator(system: system)
    let offScreen = Placement(
        windowID: system.windows[0].id,
        frame: BTRect(x: 4000, y: 0, width: 500, height: 500)
    )

    #expect(!coordinator.applyPlacements([offScreen]))
    #expect(coordinator.lastError == "A window would have been placed off screen.")
}
