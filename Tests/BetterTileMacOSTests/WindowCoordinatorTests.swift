import Testing
@testable import BetterTileCore
@testable import BetterTileMacOS

@Test @MainActor func coordinatorAppliesActionAndRestoreThroughFakeSystem() throws {
    let system = FakeWindowSystem()
    let original = system.windows[0].frame
    let coordinator = WindowCoordinator(system: system)
    #expect(coordinator.performAction(.leftHalf))
    #expect(system.windows[0].frame.size.width == 500)
    #expect(coordinator.performAction(.restore))
    #expect(system.windows[0].frame == original)
}

@Test @MainActor func customZoneButtonsHonorApplicationRules() {
    let system = FakeWindowSystem()
    let original = system.windows[0].frame
    let coordinator = WindowCoordinator(system: system)
    let zone = CustomZone(
        name: "Focus",
        rect: NormalizedRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
    )
    var rules = ApplicationRuleSet()
    rules.set(.ignoreEverywhere, for: "com.example.Test")

    #expect(coordinator.applyCustomZone(zone, applicationRules: rules)
        == .failed(reason: "BetterTile is set to ignore this app."))
    #expect(system.windows[0].frame == original)

    rules.set(.excludeFromBento, for: "com.example.Test")
    #expect(coordinator.applyCustomZone(zone, applicationRules: rules).isApplied)
    #expect(system.windows[0].frame == BTRect(x: 100, y: 80, width: 800, height: 640))
}

@Test @MainActor func aCustomZoneWithoutAFocusedWindowNamesTheMissingWindow() {
    let system = FakeWindowSystem()
    system.windows.removeAll()
    let coordinator = WindowCoordinator(system: system)
    let zone = CustomZone(
        name: "Focus",
        rect: NormalizedRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
    )

    #expect(coordinator.applyCustomZone(zone, applicationRules: ApplicationRuleSet())
        == .failed(reason: "No eligible focused window."))
}

@Test @MainActor func aCustomZoneWithoutAResolvableDisplayNamesTheDisplay() {
    let system = FakeWindowSystem()
    system.availableDisplays.removeAll()
    let coordinator = WindowCoordinator(system: system)
    let zone = CustomZone(
        name: "Focus",
        rect: NormalizedRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
    )

    #expect(coordinator.applyCustomZone(zone, applicationRules: ApplicationRuleSet())
        == .failed(reason: "The window's display could not be found."))
}

@Test @MainActor func placementTransactionsUseTargetedWindowSnapshots() {
    let system = FakeWindowSystem()
    let coordinator = WindowCoordinator(system: system)
    let placement = Placement(
        windowID: system.windows[0].id,
        frame: BTRect(x: 0, y: 0, width: 500, height: 800)
    )

    #expect(coordinator.applyPlacements([placement]).isApplied)
    #expect(system.targetedSnapshotRequests >= 2)
}

@Test @MainActor func coordinatorCanPlanAnActionWithoutMovingTheWindow() throws {
    let system = FakeWindowSystem()
    let original = system.windows[0].frame
    let coordinator = WindowCoordinator(system: system)
    let plan = try #require(coordinator.plan(.leftThird).readyPlan)

    #expect(plan.resolvedAction == .leftThird)
    #expect(plan.windowID == system.windows[0].id)
    #expect(plan.targetFrame == BTRect(x: 0, y: 0, width: 1_000.0 / 3.0, height: 800))
    #expect(system.windows[0].frame == original)
    #expect(coordinator.perform(plan).isApplied)
    #expect(system.windows[0].frame == plan.targetFrame)
}

@Test @MainActor func plannedHalfActionsPreserveShortcutCycling() throws {
    let system = FakeWindowSystem()
    let coordinator = WindowCoordinator(system: system)
    let first = try #require(coordinator.plan(.leftHalf).readyPlan)
    #expect(first.resolvedAction == .leftHalf)
    #expect(coordinator.perform(first).isApplied)

    let second = try #require(coordinator.plan(.leftHalf).readyPlan)
    #expect(second.resolvedAction == .leftThird)
    #expect(coordinator.perform(second).isApplied)
    #expect(system.windows[0].frame == second.targetFrame)
}

@Test @MainActor func aFailedFocusedWindowReadPlansAsFailedWithItsReason() {
    let system = FakeWindowSystem()
    system.focusedWindowReadFails = true
    let coordinator = WindowCoordinator(system: system)

    guard case let .failed(reason) = coordinator.plan(.leftHalf) else {
        Issue.record("expected a failed plan, not ready or unavailable")
        return
    }
    #expect(reason == WindowSystemError.operationFailed("Simulated focused-window failure").localizedDescription)
}

@Test @MainActor func aMissingFocusedWindowPlansAsUnavailableNotFailed() {
    let system = FakeWindowSystem()
    system.windows.removeAll()
    let coordinator = WindowCoordinator(system: system)

    guard case .unavailable = coordinator.plan(.leftHalf) else {
        Issue.record("no focused window is nothing to plan, not a failure")
        return
    }
}

@Test @MainActor func displayTransferWraps() {
    let system = FakeWindowSystem()
    system.availableDisplays.append(DisplaySnapshot(
        id: DisplayID(rawValue: "second"),
        frame: BTRect(x: 1000, y: 0, width: 2000, height: 1200),
        visibleFrame: BTRect(x: 1000, y: 0, width: 2000, height: 1200)
    ))
    let coordinator = WindowCoordinator(system: system)
    #expect(coordinator.performAction(.nextDisplay))
    #expect(system.windows[0].frame.minX >= 1000)
}

@Test @MainActor func ghostPreviewDoesNotMutateFramesUntilCommit() throws {
    let system = FakeWindowSystem()
    system.addSecondWindow()
    let coordinator = WindowCoordinator(system: system)
    let original = system.windows.map(\.frame)
    var transaction = try #require(coordinator.beginTransaction(windowIDs: Set(system.windows.map(\.id))).startedTransaction)
    let placements = [
        Placement(windowID: system.windows[0].id, frame: BTRect(x: 0, y: 0, width: 500, height: 800)),
        Placement(windowID: system.windows[1].id, frame: BTRect(x: 500, y: 0, width: 500, height: 800)),
    ]
    #expect(coordinator.preview(transaction: &transaction, placements: placements) == .accepted)
    #expect(system.windows.map(\.frame) == original)
    #expect(coordinator.commit(transaction: &transaction).isApplied)
    #expect(system.windows.map(\.frame) == placements.map(\.frame))
}

@Test @MainActor func liveTransactionCanBeCancelledToItsBaseline() throws {
    let system = FakeWindowSystem()
    system.addSecondWindow()
    let coordinator = WindowCoordinator(system: system)
    let original = system.windows.map(\.frame)
    var transaction = try #require(coordinator.beginTransaction(windowIDs: Set(system.windows.map(\.id))).startedTransaction)
    let placements = [
        Placement(windowID: system.windows[0].id, frame: BTRect(x: 0, y: 0, width: 650, height: 800)),
        Placement(windowID: system.windows[1].id, frame: BTRect(x: 650, y: 0, width: 350, height: 800)),
    ]
    #expect(coordinator.applyLive(transaction: &transaction, placements: placements).isApplied)
    #expect(system.windows.map(\.frame) == placements.map(\.frame))
    #expect(coordinator.cancel(transaction: transaction).isApplied)
    #expect(system.windows.map(\.frame) == original)
}

@Test @MainActor func failedLiveCancellationRequiresRepair() throws {
    let system = FakeWindowSystem()
    system.addSecondWindow()
    let coordinator = WindowCoordinator(system: system)
    var transaction = try #require(coordinator.beginTransaction(windowIDs: Set(system.windows.map(\.id))).startedTransaction)
    let placements = [
        Placement(windowID: system.windows[0].id, frame: BTRect(x: 0, y: 0, width: 650, height: 800)),
        Placement(windowID: system.windows[1].id, frame: BTRect(x: 650, y: 0, width: 350, height: 800)),
    ]
    #expect(coordinator.applyLive(transaction: &transaction, placements: placements).isApplied)
    system.failingWindowID = system.windows[0].id

    #expect(coordinator.cancel(transaction: transaction)
        == .degraded(reason: "The divider change failed and the previous layout could not be fully restored."))
}

@Test @MainActor func cancellationRecoversADegradedFirstLiveWrite() throws {
    let system = FakeWindowSystem()
    system.addSecondWindow()
    let coordinator = WindowCoordinator(system: system)
    let original = system.windows.map(\.frame)
    let firstID = system.windows[0].id
    let secondID = system.windows[1].id
    var transaction = try #require(coordinator.beginTransaction(windowIDs: [firstID, secondID]).startedTransaction)
    system.failedFrameWriteNumbers[secondID] = [1]
    system.failedFrameWriteNumbers[firstID] = [2]

    #expect(coordinator.applyLive(
        transaction: &transaction,
        placements: [
            Placement(windowID: firstID, frame: BTRect(x: 0, y: 0, width: 650, height: 800)),
            Placement(windowID: secondID, frame: BTRect(x: 650, y: 0, width: 350, height: 800)),
        ]
    ) == .degraded(reason: "A window update failed and the previous layout could not be fully restored."))
    #expect(transaction.hasDegradedApply)
    #expect(!transaction.hasLiveChanges)

    system.failedFrameWriteNumbers.removeAll()
    #expect(coordinator.cancel(transaction: transaction).isApplied)
    #expect(system.windows.map(\.frame) == original)
}

@Test @MainActor func partialTransactionFailureRollsBackAppliedWindows() throws {
    let system = FakeWindowSystem()
    system.addSecondWindow()
    let coordinator = WindowCoordinator(system: system)
    let original = system.windows.map(\.frame)
    let failingID = system.windows[1].id
    system.failingWindowID = failingID
    var transaction = try #require(coordinator.beginTransaction(windowIDs: Set(system.windows.map(\.id))).startedTransaction)
    let placements = [
        Placement(windowID: system.windows[0].id, frame: BTRect(x: 0, y: 0, width: 500, height: 800)),
        Placement(windowID: failingID, frame: BTRect(x: 500, y: 0, width: 500, height: 800)),
    ]
    #expect(!coordinator.commit(transaction: &transaction, placements: placements).isApplied)
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

    #expect(coordinator.applyPlacements(placements).isApplied)
    #expect((await coordinator.settleAuthoritativePlacements(placements, retryDelay: .zero)).isApplied)
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

    #expect(coordinator.applyPlacements(placements).isApplied)
    let outcome = await coordinator.settleAuthoritativePlacements(placements, retryDelay: .zero)
    #expect(outcome == .failed(reason: "One or more windows did not settle at the requested frame."))
    #expect(system.frameWriteCounts[system.windows[1].id] == 3)
}

@Test @MainActor func aDegradedRetryDuringSettlementSurfacesTheMixedStateReason() async throws {
    let system = FakeWindowSystem()
    system.addSecondWindow()
    let coordinator = WindowCoordinator(system: system)
    let firstID = system.windows[0].id
    let secondID = system.windows[1].id
    let placements = [
        Placement(windowID: firstID, frame: BTRect(x: 0, y: 0, width: 500, height: 700)),
        Placement(windowID: secondID, frame: BTRect(x: 500, y: 0, width: 500, height: 700)),
    ]
    // Both first writes are accepted but ignored, so the settlement retry
    // re-applies both windows; the retry then degrades: the second window's
    // write fails and the first window's rollback write fails too.
    system.ignoredFrameWriteCounts[firstID] = 1
    system.ignoredFrameWriteCounts[secondID] = 1
    system.failedFrameWriteNumbers[secondID] = [2]
    system.failedFrameWriteNumbers[firstID] = [3]

    #expect(coordinator.applyPlacements(placements).isApplied)
    let outcome = await coordinator.settleAuthoritativePlacements(placements, retryDelay: .zero)
    #expect(outcome == .degraded(reason: "A window update failed and the previous layout could not be fully restored."))
}

@Test @MainActor func aFullySuccessfulApplyClearsTheTransactionDegradedLatch() throws {
    let system = FakeWindowSystem()
    system.addSecondWindow()
    let coordinator = WindowCoordinator(system: system)
    let firstID = system.windows[0].id
    let secondID = system.windows[1].id
    var transaction = try #require(coordinator.beginTransaction(windowIDs: [firstID, secondID]).startedTransaction)
    let placements = [
        Placement(windowID: firstID, frame: BTRect(x: 0, y: 0, width: 600, height: 800)),
        Placement(windowID: secondID, frame: BTRect(x: 600, y: 0, width: 400, height: 800)),
    ]
    system.failingWindowID = secondID
    system.failedFrameWriteNumbers[firstID] = [2]

    guard case .degraded = coordinator.commit(transaction: &transaction, placements: placements) else {
        Issue.record("expected the first commit to degrade")
        return
    }
    #expect(transaction.hasDegradedApply)

    system.failingWindowID = nil
    system.failedFrameWriteNumbers.removeAll()
    #expect(coordinator.commit(transaction: &transaction, placements: placements).isApplied)
    #expect(!transaction.hasDegradedApply)

    // Degrade-then-recover behaves like never-degraded: with no live changes
    // and no outstanding degrade, cancel leaves the committed frames alone.
    #expect(coordinator.cancel(transaction: transaction).isApplied)
    #expect(system.windows.map(\.frame) == placements.map(\.frame))
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
    ).isApplied)
    #expect(system.windows.first(where: { $0.id == source.id })?.frame == source.frame)
    #expect(system.windows.first(where: { $0.id == system.windows[1].id })?.isMinimized == false)
    #expect(system.windows.first(where: { $0.id == third.id })?.isMinimized == false)
}

@Test @MainActor func focusDropPeerRestoreUnminimizesEveryPeer() {
    let system = FakeWindowSystem()
    system.addSecondWindow()
    let thirdID = WindowID(rawValue: "third")
    system.windows.append(WindowSnapshot(
        id: thirdID,
        processIdentifier: 44,
        frame: BTRect(x: 600, y: 200, width: 200, height: 400),
        displayID: DisplayID(rawValue: "main")
    ))
    system.windows[1].isMinimized = true
    system.windows[2].isMinimized = true
    let coordinator = WindowCoordinator(system: system)

    #expect(coordinator.restoreFocusDropPeers([system.windows[1].id, thirdID]).isApplied)
    #expect(system.windows[1].isMinimized == false)
    #expect(system.windows[2].isMinimized == false)
}

@Test @MainActor func focusDropPeerRestoreContinuesPastAFailingPeer() {
    let system = FakeWindowSystem()
    system.addSecondWindow()
    let thirdID = WindowID(rawValue: "third")
    system.windows.append(WindowSnapshot(
        id: thirdID,
        processIdentifier: 44,
        frame: BTRect(x: 600, y: 200, width: 200, height: 400),
        displayID: DisplayID(rawValue: "main")
    ))
    let failingID = system.windows[1].id
    system.windows[1].isMinimized = true
    system.windows[2].isMinimized = true
    system.failingMinimizeWindowID = failingID
    let coordinator = WindowCoordinator(system: system)

    guard case let .failed(reason) = coordinator.restoreFocusDropPeers([failingID, thirdID]) else {
        Issue.record("an incomplete peer restore must report failure")
        return
    }
    #expect(reason == WindowSystemError.operationFailed("Simulated minimize failure").localizedDescription)
    // Best-effort by design: the peer that restored stays restored.
    #expect(system.windows[2].isMinimized == false)
    #expect(system.windows[1].isMinimized == true)
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
    var transaction = try #require(coordinator.beginTransaction(windowIDs: Set(system.windows.map(\.id))).startedTransaction)
    let placements = [
        Placement(windowID: first.id, frame: second.frame),
        Placement(windowID: second.id, frame: first.frame),
        Placement(windowID: unchanged.id, frame: unchanged.frame),
    ]

    #expect(coordinator.commit(transaction: &transaction, placements: placements).isApplied)
    system.focusedWindowID = unchanged.id
    #expect(!coordinator.performAction(.restore))
    system.focusedWindowID = first.id
    #expect(coordinator.performAction(.restore))
    #expect(system.windows.first(where: { $0.id == first.id })?.frame == first.frame)
}

@Test @MainActor func coordinatorFiltersOnlyItsOwnExpectedFrameEvent() throws {
    let system = FakeWindowSystem()
    let coordinator = WindowCoordinator(system: system)
    let id = system.windows[0].id
    let target = BTRect(x: 0, y: 0, width: 500, height: 800)
    #expect(coordinator.applyPlacements([Placement(windowID: id, frame: target)]).isApplied)
    #expect(coordinator.matchesExpectedMutation(windowID: id, actualFrame: target))
    #expect(!coordinator.matchesExpectedMutation(
        windowID: id,
        actualFrame: BTRect(x: 0, y: 0, width: 650, height: 800)
    ))
}

@Test @MainActor func coordinatorOwnsDelayedEventsFromOverlappingGenerations() throws {
    let system = FakeWindowSystem()
    let coordinator = WindowCoordinator(system: system)
    let id = system.windows[0].id
    let first = BTRect(x: 0, y: 0, width: 500, height: 800)
    let second = BTRect(x: 500, y: 0, width: 500, height: 800)

    #expect(coordinator.applyPlacements([Placement(windowID: id, frame: first)]).isApplied)
    #expect(coordinator.applyPlacements([Placement(windowID: id, frame: second)]).isApplied)

    #expect(coordinator.matchesExpectedMutation(windowID: id, actualFrame: first))
    #expect(coordinator.matchesExpectedMutation(windowID: id, actualFrame: second))
}

@Test @MainActor func anObservedGenerationStillOwnsDelayedDuplicatesAfterANewerWrite() throws {
    let system = FakeWindowSystem()
    let coordinator = WindowCoordinator(system: system)
    let id = system.windows[0].id
    let first = BTRect(x: 0, y: 0, width: 500, height: 800)
    let second = BTRect(x: 500, y: 0, width: 500, height: 800)

    #expect(coordinator.applyPlacements([Placement(windowID: id, frame: first)]).isApplied)
    #expect(coordinator.matchesExpectedMutation(windowID: id, actualFrame: first))
    #expect(coordinator.applyPlacements([Placement(windowID: id, frame: second)]).isApplied)

    #expect(coordinator.matchesExpectedMutation(windowID: id, actualFrame: first))
}

@Test @MainActor func coordinatorOwnsACallbackBeyondTheOldHalfSecondDeadline() async throws {
    let system = FakeWindowSystem()
    let coordinator = WindowCoordinator(system: system)
    let id = system.windows[0].id
    let target = BTRect(x: 0, y: 0, width: 500, height: 800)

    #expect(coordinator.applyPlacements([Placement(windowID: id, frame: target)]).isApplied)
    try await Task.sleep(for: .milliseconds(550))
    #expect(coordinator.matchesExpectedMutation(windowID: id, actualFrame: target))
}

@Test @MainActor func coordinatorOwnsEveryCallbackFromAFrameWrite() throws {
    let system = FakeWindowSystem()
    let coordinator = WindowCoordinator(system: system)
    let id = system.windows[0].id
    let target = BTRect(x: 0, y: 0, width: 500, height: 800)

    #expect(coordinator.applyPlacements([Placement(windowID: id, frame: target)]).isApplied)
    #expect(coordinator.matchesExpectedMutation(windowID: id, actualFrame: target))
    #expect(coordinator.matchesExpectedMutation(windowID: id, actualFrame: target))
    #expect(coordinator.matchesExpectedMutation(windowID: id, actualFrame: target))
    #expect(coordinator.matchesExpectedMutation(windowID: id, actualFrame: target))
    coordinator.finishExpectedMutations(upTo: [id: coordinator.mutationGeneration(for: id)])
    #expect(!coordinator.matchesExpectedMutation(windowID: id, actualFrame: target))
}

@Test @MainActor func rapidWritesDoNotDropAnOwnedGeneration() throws {
    let system = FakeWindowSystem()
    let coordinator = WindowCoordinator(system: system)
    let id = system.windows[0].id
    let targets = (0..<9).map { index in
        BTRect(x: Double(index * 10), y: 0, width: 500, height: 700)
    }

    for target in targets {
        #expect(coordinator.applyPlacements([Placement(windowID: id, frame: target)]).isApplied)
    }

    #expect(coordinator.matchesExpectedMutation(windowID: id, actualFrame: targets[0]))
}

@Test @MainActor func finishingAnOlderGenerationPreservesNewerOwnership() throws {
    let system = FakeWindowSystem()
    let coordinator = WindowCoordinator(system: system)
    let id = system.windows[0].id
    let first = BTRect(x: 0, y: 0, width: 500, height: 800)
    let second = BTRect(x: 500, y: 0, width: 500, height: 800)

    #expect(coordinator.applyPlacements([Placement(windowID: id, frame: first)]).isApplied)
    let firstGeneration = coordinator.mutationGeneration(for: id)
    #expect(coordinator.applyPlacements([Placement(windowID: id, frame: second)]).isApplied)
    coordinator.finishExpectedMutations(upTo: [id: firstGeneration])

    #expect(!coordinator.matchesExpectedMutation(windowID: id, actualFrame: first))
    #expect(coordinator.matchesExpectedMutation(windowID: id, actualFrame: second))
}

@Test @MainActor func terminalObservationFinishesOnlyGenerationsThroughTheObservedFrame() throws {
    let system = FakeWindowSystem()
    let coordinator = WindowCoordinator(system: system)
    let id = system.windows[0].id
    let first = BTRect(x: 0, y: 0, width: 500, height: 800)
    let second = BTRect(x: 500, y: 0, width: 500, height: 800)

    #expect(coordinator.applyPlacements([Placement(windowID: id, frame: first)]).isApplied)
    #expect(coordinator.applyPlacements([Placement(windowID: id, frame: second)]).isApplied)
    coordinator.finishExpectedMutations(observing: [
        WindowSnapshot(id: id, processIdentifier: 1, frame: first, displayID: system.displays()[0].id),
    ])

    #expect(!coordinator.matchesExpectedMutation(windowID: id, actualFrame: first))
    #expect(coordinator.matchesExpectedMutation(windowID: id, actualFrame: second))
}

@Test @MainActor func terminalObservationBoundsAnUnsettledBurst() throws {
    let system = FakeWindowSystem()
    let coordinator = WindowCoordinator(system: system)
    let id = system.windows[0].id
    let targets = (0..<20).map { index in
        BTRect(x: Double(index * 10), y: 0, width: 500, height: 700)
    }

    for target in targets {
        #expect(coordinator.applyPlacements([Placement(windowID: id, frame: target)]).isApplied)
    }
    coordinator.finishExpectedMutations(observing: try system.visibleWindows())

    #expect(!coordinator.matchesExpectedMutation(windowID: id, actualFrame: targets[0]))
    #expect(!coordinator.matchesExpectedMutation(windowID: id, actualFrame: targets[19]))
}

@Test @MainActor func repeatedTerminalMismatchBoundsAnIgnoredWrite() throws {
    let system = FakeWindowSystem()
    let coordinator = WindowCoordinator(system: system)
    let id = system.windows[0].id
    let target = BTRect(x: 0, y: 0, width: 500, height: 800)
    system.ignoredFrameWriteCounts[id] = 1

    #expect(coordinator.applyPlacements([Placement(windowID: id, frame: target)]).isApplied)
    let unchanged = try system.visibleWindows()
    coordinator.verifyExpectedMutations(observing: unchanged, failureLimit: 3)
    coordinator.verifyExpectedMutations(observing: unchanged, failureLimit: 3)
    #expect(coordinator.matchesExpectedMutation(windowID: id, actualFrame: target))
    coordinator.verifyExpectedMutations(observing: unchanged, failureLimit: 3)

    #expect(!coordinator.matchesExpectedMutation(windowID: id, actualFrame: target))
}

@Test @MainActor func olderFailedVerificationDoesNotRetireANewerGeneration() throws {
    let system = FakeWindowSystem()
    let coordinator = WindowCoordinator(system: system)
    let id = system.windows[0].id
    let first = BTRect(x: 0, y: 0, width: 500, height: 800)
    let second = BTRect(x: 500, y: 0, width: 500, height: 800)
    system.ignoredFrameWriteCounts[id] = 2

    #expect(coordinator.applyPlacements([Placement(windowID: id, frame: first)]).isApplied)
    let unchanged = try system.visibleWindows()
    coordinator.verifyExpectedMutations(observing: unchanged, failureLimit: 3)
    coordinator.verifyExpectedMutations(observing: unchanged, failureLimit: 3)
    #expect(coordinator.applyPlacements([Placement(windowID: id, frame: second)]).isApplied)
    coordinator.verifyExpectedMutations(observing: unchanged, failureLimit: 3)

    #expect(!coordinator.matchesExpectedMutation(windowID: id, actualFrame: first))
    #expect(coordinator.matchesExpectedMutation(windowID: id, actualFrame: second))
}

@Test @MainActor func failedFrameWriteDoesNotClaimAFutureEvent() throws {
    let system = FakeWindowSystem()
    let coordinator = WindowCoordinator(system: system)
    let id = system.windows[0].id
    let target = BTRect(x: 0, y: 0, width: 500, height: 800)
    system.failingWindowID = id

    #expect(!coordinator.applyPlacements([Placement(windowID: id, frame: target)]).isApplied)
    #expect(!coordinator.matchesExpectedMutation(windowID: id, actualFrame: target))
}

@Test @MainActor func rollbackOwnsBothForwardAndRestoringEvents() throws {
    let system = FakeWindowSystem()
    system.addSecondWindow()
    let coordinator = WindowCoordinator(system: system)
    let first = system.windows[0]
    let failing = system.windows[1]
    let forwardFrame = BTRect(x: 0, y: 0, width: 500, height: 800)
    let failingFrame = BTRect(x: 500, y: 0, width: 500, height: 800)
    system.failingWindowID = failing.id

    #expect(!coordinator.applyPlacements([
        Placement(windowID: first.id, frame: forwardFrame),
        Placement(windowID: failing.id, frame: failingFrame),
    ]).isApplied)

    #expect(coordinator.matchesExpectedMutation(windowID: first.id, actualFrame: forwardFrame))
    #expect(coordinator.matchesExpectedMutation(windowID: first.id, actualFrame: first.frame))
    #expect(!coordinator.matchesExpectedMutation(windowID: failing.id, actualFrame: failingFrame))
}

// MARK: - Accessibility write hints

@Test @MainActor func actionsTellTheSystemWhereTheWindowCurrentlyIs() throws {
    let system = FakeWindowSystem()
    let original = system.windows[0].frame
    let coordinator = WindowCoordinator(system: system)
    let id = system.windows[0].id

    #expect(coordinator.performAction(.leftHalf))
    #expect(system.recordedKnownCurrentFrames[id] == [original])
}

@Test @MainActor func aMoveActionLetsTheSystemSkipTheLeadingSizeWrite() throws {
    let system = FakeWindowSystem()
    let coordinator = WindowCoordinator(system: system)
    let id = system.windows[0].id
    let before = system.windows[0].frame

    #expect(coordinator.performAction(.moveRight))
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
    var transaction = try #require(coordinator.beginTransaction(windowIDs: Set(system.windows.map(\.id))).startedTransaction)
    let placements = system.windows.map {
        Placement(windowID: $0.id, frame: BTRect(x: 0, y: 0, width: 500, height: 800))
    }

    #expect(coordinator.commit(transaction: &transaction, placements: placements).isApplied)
    for (id, baseline) in baselines {
        #expect(system.recordedKnownCurrentFrames[id]?.first == baseline)
    }
}

@Test @MainActor func liveTransactionsPassTheLastAppliedFrameNotTheBaseline() throws {
    let system = FakeWindowSystem()
    let coordinator = WindowCoordinator(system: system)
    let id = system.windows[0].id
    var transaction = try #require(coordinator.beginTransaction(windowIDs: [id]).startedTransaction)

    let first = BTRect(x: 0, y: 0, width: 400, height: 800)
    let second = BTRect(x: 0, y: 0, width: 450, height: 800)
    #expect(coordinator.applyLive(transaction: &transaction, placements: [Placement(windowID: id, frame: first)]).isApplied)
    #expect(coordinator.applyLive(transaction: &transaction, placements: [Placement(windowID: id, frame: second)]).isApplied)

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
    #expect(!coordinator.applyPlacements(placements).isApplied)

    // Two writes for the first window: the forward apply, then the rollback,
    // which knows the window is sitting at the frame the forward apply wrote.
    let hints = try #require(system.recordedKnownCurrentFrames[firstID])
    #expect(hints.count == 2)
    #expect(hints[1] == placements[0].frame)
}

@Test @MainActor func rollbackFailureMarksTheApplyAsDegraded() {
    let system = FakeWindowSystem()
    system.addSecondWindow()
    let coordinator = WindowCoordinator(system: system)
    let firstID = system.windows[0].id
    system.failingWindowID = system.windows[1].id
    system.failedFrameWriteNumbers[firstID] = [2]

    let placements = system.windows.map {
        Placement(windowID: $0.id, frame: BTRect(x: 0, y: 0, width: 500, height: 800))
    }

    #expect(coordinator.applyPlacements(placements)
        == .degraded(reason: "A window update failed and the previous layout could not be fully restored."))
}

@Test @MainActor func aDegradedApplyDoesNotPoisonALaterTransaction() throws {
    let system = FakeWindowSystem()
    system.addSecondWindow()
    let coordinator = WindowCoordinator(system: system)
    let firstID = system.windows[0].id
    system.failingWindowID = system.windows[1].id
    system.failedFrameWriteNumbers[firstID] = [2]
    let failedPlacements = system.windows.map {
        Placement(windowID: $0.id, frame: BTRect(x: 0, y: 0, width: 500, height: 800))
    }
    guard case .degraded = coordinator.applyPlacements(failedPlacements) else {
        Issue.record("expected a degraded apply")
        return
    }

    system.failingWindowID = nil
    system.failedFrameWriteNumbers.removeAll()
    var transaction = try #require(coordinator.beginTransaction(windowIDs: [firstID]).startedTransaction)
    #expect(!transaction.hasDegradedApply)
    #expect(coordinator.applyLive(
        transaction: &transaction,
        placements: [Placement(windowID: firstID, frame: BTRect(x: 0, y: 0, width: 450, height: 800))]
    ).isApplied)
    // Cancelling the fresh transaction restores its own baseline and nothing
    // else: the earlier degraded apply does not leak into this gesture.
    #expect(coordinator.cancel(transaction: transaction).isApplied)
}

@Test @MainActor func focusDropRollbackFailureMarksTheApplyAsDegraded() {
    let system = FakeWindowSystem()
    system.addSecondWindow()
    let thirdID = WindowID(rawValue: "third")
    system.windows.append(WindowSnapshot(
        id: thirdID,
        processIdentifier: 44,
        frame: BTRect(x: 600, y: 200, width: 200, height: 400),
        displayID: DisplayID(rawValue: "main")
    ))
    let coordinator = WindowCoordinator(system: system)
    let source = system.windows[0]
    let firstMinimizedID = system.windows[1].id
    system.failingMinimizeWindowID = thirdID
    system.failedMinimizeWriteNumbers[firstMinimizedID] = [2]

    #expect(coordinator.applyFocusDrop(
        placement: Placement(
            windowID: source.id,
            frame: BTRect(x: 0, y: 0, width: 500, height: 800)
        ),
        minimizing: [firstMinimizedID, thirdID],
        sourceBaselineFrame: source.frame
    ) == .degraded(reason: "The focus drop failed and the previous layout could not be fully restored."))
}

@Test @MainActor func anUnappliedFocusDropDoesNotReportADegradedRollback() {
    let system = FakeWindowSystem()
    let coordinator = WindowCoordinator(system: system)
    let source = system.windows[0]
    system.failedFrameWriteNumbers[source.id] = [1, 2]

    guard case .failed = coordinator.applyFocusDrop(
        placement: Placement(
            windowID: source.id,
            frame: BTRect(x: 0, y: 0, width: 500, height: 800)
        ),
        minimizing: [],
        sourceBaselineFrame: source.frame
    ) else {
        Issue.record("expected a cleanly failed focus drop, not a degraded one")
        return
    }
    #expect(system.windows[0].frame == source.frame)
    #expect(system.frameWriteCounts[source.id] == 1)
}

@Test @MainActor func theConvenienceOverloadStillPerformsAFullWrite() throws {
    let system = FakeWindowSystem()
    let id = system.windows[0].id
    try system.setFrame(BTRect(x: 10, y: 10, width: 300, height: 300), for: id)
    #expect(system.recordedKnownCurrentFrames[id] == [nil])
}

// MARK: - Truthful outcomes

/// An application that applies a geometry change on its own run loop - which
/// Chromium-based applications do - must not be reported as a failure. Read
/// straight back, "ignored the write" and "has not applied it yet" are the same
/// observation, so the action succeeds and verification waits.
@Test @MainActor func aLateSettlingApplicationReachesItsTarget() async throws {
    let system = FakeWindowSystem()
    system.readsBeforeSettling = 2
    let coordinator = WindowCoordinator(system: system)
    let plan = try #require(coordinator.plan(.leftHalf).readyPlan)

    #expect(coordinator.perform(plan).isApplied, "a late-settling window still counts as applied")
    let generation = coordinator.mutationGeneration(for: plan.windowID)
    #expect(await coordinator.verifyPlacement(plan, since: generation, delay: .milliseconds(1)) == .landed)
    #expect(!coordinator.matchesExpectedMutation(windowID: plan.windowID, actualFrame: plan.targetFrame))
}

/// A window that never moves is still sitting at the action's source frame, and
/// nothing else has touched it. That is the only case a delayed check may
/// report.
@Test @MainActor func anIgnoredWriteLeavesTheWindowAtItsSourceAndFails() async throws {
    let system = FakeWindowSystem()
    let coordinator = WindowCoordinator(system: system)
    let plan = try #require(coordinator.plan(.leftHalf).readyPlan)
    system.ignoredFrameWriteCounts[plan.windowID] = 1

    #expect(coordinator.perform(plan).isApplied, "the write itself was accepted")
    #expect(system.windows[0].frame == plan.sourceFrame)
    let generation = coordinator.mutationGeneration(for: plan.windowID)
    #expect(await coordinator.verifyPlacement(plan, since: generation, delay: .milliseconds(1)) == .failed)
    #expect(!coordinator.matchesExpectedMutation(windowID: plan.windowID, actualFrame: plan.targetFrame))
}

/// Dragging the window somewhere else while verification is pending. The mouse
/// never touches the coordinator, so the generation is unchanged and only the
/// frame check can tell that the action has been superseded.
@Test @MainActor func aWindowMovedByHandDuringVerificationReportsNothing() async throws {
    let system = FakeWindowSystem()
    let coordinator = WindowCoordinator(system: system)
    let plan = try #require(coordinator.plan(.leftHalf).readyPlan)
    system.ignoredFrameWriteCounts[plan.windowID] = 1
    #expect(coordinator.perform(plan).isApplied)

    let generation = coordinator.mutationGeneration(for: plan.windowID)
    system.windows[0].frame = BTRect(x: 640, y: 320, width: 500, height: 400)
    #expect(coordinator.mutationGeneration(for: plan.windowID) == generation,
            "a drag does not go through the coordinator")

    #expect(await coordinator.verifyPlacement(plan, since: generation, delay: .milliseconds(1)) == .superseded)
}

@Test @MainActor func aWindowResizedByHandDuringVerificationReportsNothing() async throws {
    let system = FakeWindowSystem()
    let coordinator = WindowCoordinator(system: system)
    let plan = try #require(coordinator.plan(.leftHalf).readyPlan)
    system.ignoredFrameWriteCounts[plan.windowID] = 1
    #expect(coordinator.perform(plan).isApplied)

    let generation = coordinator.mutationGeneration(for: plan.windowID)
    system.windows[0].frame.size = BTSize(
        width: plan.sourceFrame.size.width + 100,
        height: plan.sourceFrame.size.height + 100
    )
    #expect(coordinator.mutationGeneration(for: plan.windowID) == generation,
            "a hand resize does not go through the coordinator")

    #expect(await coordinator.verifyPlacement(plan, since: generation, delay: .milliseconds(1)) == .superseded)
}

/// A second BetterTile mutation moves the generation on, so the earlier action
/// must not report even if the window happens to be back near where it started.
@Test @MainActor func anotherBetterTileMutationSupersedesTheCheck() async throws {
    let system = FakeWindowSystem()
    let coordinator = WindowCoordinator(system: system)
    let plan = try #require(coordinator.plan(.leftHalf).readyPlan)
    system.ignoredFrameWriteCounts[plan.windowID] = 1
    #expect(coordinator.perform(plan).isApplied)

    let generation = coordinator.mutationGeneration(for: plan.windowID)
    system.ignoredFrameWriteCounts[plan.windowID] = 1
    _ = coordinator.applyPlacements(
        [Placement(windowID: plan.windowID, frame: plan.sourceFrame)],
        recordHistory: false
    )
    #expect(coordinator.mutationGeneration(for: plan.windowID) != generation)
    #expect(await coordinator.verifyPlacement(plan, since: generation, delay: .milliseconds(1)) == .superseded)
    #expect(coordinator.matchesExpectedMutation(windowID: plan.windowID, actualFrame: plan.targetFrame))
}

/// A read-back that cannot be completed must not turn an applied action into a
/// reported failure.
@Test @MainActor func anUnreadableWindowIsInconclusive() async throws {
    let system = FakeWindowSystem()
    let coordinator = WindowCoordinator(system: system)
    let plan = try #require(coordinator.plan(.leftHalf).readyPlan)
    #expect(coordinator.perform(plan).isApplied)
    let generation = coordinator.mutationGeneration(for: plan.windowID)
    system.windows.removeAll()
    #expect(await coordinator.verifyPlacement(plan, since: generation, delay: .milliseconds(1)) == .inconclusive)
}

@Test @MainActor func cancellingVerificationRetainsItsMutationOwnership() async throws {
    let system = FakeWindowSystem()
    let coordinator = WindowCoordinator(system: system)
    let plan = try #require(coordinator.plan(.leftHalf).readyPlan)
    #expect(coordinator.perform(plan).isApplied)
    let generation = coordinator.mutationGeneration(for: plan.windowID)
    let verification = Task {
        await coordinator.verifyPlacement(plan, since: generation, delay: .seconds(1))
    }

    verification.cancel()
    #expect(await verification.value == .superseded)
    #expect(coordinator.matchesExpectedMutation(windowID: plan.windowID, actualFrame: plan.targetFrame))
}

@Test @MainActor func failedSettlementReadEndsOnlyItsOwnedGenerations() async throws {
    let system = FakeWindowSystem()
    let coordinator = WindowCoordinator(system: system)
    let id = system.windows[0].id
    let target = BTRect(x: 0, y: 0, width: 500, height: 800)
    let placements = [Placement(windowID: id, frame: target)]
    #expect(coordinator.applyPlacements(placements).isApplied)
    system.targetedSnapshotsFail = true

    #expect(!(await coordinator.settleAuthoritativePlacements(placements, retryDelay: .zero)).isApplied)
    #expect(!coordinator.matchesExpectedMutation(windowID: id, actualFrame: target))
}

/// A Bento operation resolves a shortcut to a pane, which is deliberately not
/// the standard action frame. The window did move, so nothing is reported.
@Test @MainActor func aBentoPlacementAwayFromTheStandardFrameReportsNothing() async throws {
    let system = FakeWindowSystem()
    let coordinator = WindowCoordinator(system: system)
    let plan = try #require(coordinator.plan(.leftHalf).readyPlan)

    // Bento puts the window in a pane of its own choosing rather than at the
    // half the shortcut nominally names.
    let generation = coordinator.mutationGeneration(for: plan.windowID)
    let pane = BTRect(x: 500, y: 0, width: 500, height: 800)
    #expect(pane != plan.targetFrame)
    #expect(coordinator.applyPlacements([Placement(windowID: plan.windowID, frame: pane)]).isApplied)
    #expect(system.windows[0].frame == pane)

    #expect(await coordinator.verifyPlacement(plan, since: generation, delay: .milliseconds(1)) == .superseded)
}

@Test @MainActor func anActionIsStillASuccessWhenTheWindowKeepsItsOwnSize() throws {
    let system = FakeWindowSystem()
    system.clampWidth = 400
    let coordinator = WindowCoordinator(system: system)

    #expect(coordinator.performAction(.leftHalf))
    #expect(system.windows[0].frame.size.width == 400)
    #expect(system.windows[0].frame.minX == 0, "the position is still honoured")
}

@Test @MainActor func placementsOutsideTheDisplayAreRejected() throws {
    let system = FakeWindowSystem()
    let coordinator = WindowCoordinator(system: system)
    let offScreen = Placement(
        windowID: system.windows[0].id,
        frame: BTRect(x: 4000, y: 0, width: 500, height: 500)
    )

    #expect(coordinator.applyPlacements([offScreen])
        == .failed(reason: "A window would have been placed off screen."))
}

// MARK: - Outcome test conveniences

private extension WindowPlanOutcome {
    var readyPlan: WindowActionPlan? {
        if case let .ready(plan) = self { return plan }
        return nil
    }
}

private extension TransactionStartOutcome {
    var startedTransaction: WindowFrameTransaction? {
        if case let .started(transaction) = self { return transaction }
        return nil
    }
}

@MainActor
private extension WindowCoordinator {
    /// Mirrors the removed `perform(_ action:)` convenience for tests that
    /// exercise plan-and-perform as one step.
    func performAction(_ action: WindowAction) -> Bool {
        guard case let .ready(plan) = plan(action) else { return false }
        return perform(plan).isApplied
    }
}
