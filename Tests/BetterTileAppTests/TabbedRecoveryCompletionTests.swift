import AppKit
import BetterTileCore
import BetterTileTestSupport
import Testing
@testable import BetterTileApp

@MainActor private func recoveryCompletionModel(_ system: FakeAppWindowSystem) -> (BetterTileModel, ManualClock) {
    let model = makeModel(system: system)
    let clock = ManualClock()
    let origin = clock.now
    let uptime = {
        let elapsed = origin.duration(to: clock.now).components
        return 1_000 + Double(elapsed.seconds) + Double(elapsed.attoseconds) * 1e-18
    }
    system.applicationHoldUptime = uptime
    model.applicationRecoveryUptime = uptime
    model.applicationRecoveryClock = clock.clock
    return (model, clock)
}

/// These completed or invalidated scenarios have no delayed recovery left to replay.
@MainActor private func assertRecoveryRemainsIdle(_ model: BetterTileModel, clock: ManualClock) async throws {
    try #require(await waitFor { !model.isStabilizingSpace && !model.hasPendingTabbedPlacement })
    try await waitForWindowEventsToDrain(model)
    try #require(model.applicationRecoveryTask == nil, "Completed or invalidated recovery must have no retry timer")
    clock.advance(by: .milliseconds(450))
    await model.tabbedFocusTask?.value
    model.watchdog()
    try await waitForWindowEventsToDrain(model)
    #expect(model.applicationRecoveryTask == nil, "The later sweep must not restart recovery")
}

@MainActor private func recoveryCompletionStore(_ model: BetterTileModel) -> LayoutSessionStore? {
    Mirror(reflecting: model).children.first { $0.label?.hasSuffix("sessionStore") == true }?.value as? LayoutSessionStore
}
@MainActor private func recoveryCompletionPending(_ model: BetterTileModel) -> [WindowID: Int32] {
    Mirror(reflecting: model).children.first { $0.label?.hasSuffix("applicationRecoveryPendingWindows") == true }?.value as? [WindowID: Int32] ?? [:]
}

@Suite(.appTestApplication, .serialized, .timeLimit(.minutes(5))) @MainActor
struct TabbedRecoveryDegradationTests {
    @Test(arguments: ["none", "generation", "session", "sameModeCommand", "drag"])
    func tabbedEntryRecoveryDegradationKeepsOwner(invalidation: String) async throws {
        _ = NSApplication.shared
        let system = FakeAppWindowSystem()
        let display = system.mainDisplay.id
        let first = NativeSpaceID(rawValue: 1), second = NativeSpaceID(rawValue: 2)
        let held = WindowID(rawValue: "held")
        system.windows.append(WindowSnapshot(id: held, processIdentifier: 43,
            frame: BTRect(x: 500, y: 0, width: 500, height: 800), displayID: display))
        system.desktopObservation = NativeDesktopObservation(currentSpaceByDisplay: [display: first],
            knownSpacesByDisplay: [display: [first, second]],
            windowMembership: Dictionary(uniqueKeysWithValues: system.windows.map { ($0.id, [first]) }))
        let (model, recoveryClock) = recoveryCompletionModel(system)
        defer { model.shutdown() }
        model.configuration.defaultLayoutMode = .manual
        model.configuration.defaultTabbedPreset = .columns
        model.configuration.bentoInnerGap = 0
        model.setActiveMode(.bento)
        try #require(await waitFor { model.settlementTasks.isEmpty })
        let focused = system.windows[0].id
        let owner = try #require(recoveryCompletionStore(model)?.session(for: display))
        let baseline = system.windows.map(\.frame)
        system.applicationHoldsUntil[43] = 999
        let writes = system.frameWriteCounts
        system.failedFrameWriteNumbers[held] = [writes[held, default: 0] + 1]
        system.failedFrameWriteNumbers[focused] = [writes[focused, default: 0] + 2]
        var hitRollback = false
        var newerOwner: LayoutSession?
        var beganDrag = false
        system.onWindowSnapshots = { [weak model, weak system] in
            guard let model, let system, !hitRollback,
                  system.frameWriteCounts[held, default: 0] > writes[held, default: 0] else { return }
            hitRollback = true
            if invalidation == "session" {
                system.desktopObservation?.currentSpaceByDisplay[display] = second
                system.offscreenWindowIDs = Set(system.windows.map(\.id))
            }
            if invalidation == "sameModeCommand" {
                model.setActiveMode(.tabbed)
            } else if invalidation == "drag" {
                beganDrag = model.beginBentoDrag(displayID: display, sourceID: focused)
                newerOwner = recoveryCompletionStore(model)?.session(for: display)
            } else if invalidation != "none" { model.beginActiveSpaceStabilization() }
        }
        system.failedVisibleWindowSweeps.insert(system.completeSweepCount + 1)
        model.setActiveMode(.tabbed)
        try #require(recoveryCompletionPending(model)[held] == 43, "Entry must start with a returning recovery identity.")
        try #require(await waitFor { hitRollback && !model.hasPendingTabbedPlacement })
        let damaged = try #require(recoveryCompletionStore(model)?.allSessions(for: display).first { $0.id == owner.id })
        if invalidation == "none" || invalidation == "sameModeCommand" {
            #expect(system.windows.map(\.frame) == baseline, "The current entry gets its second baseline restoration.")
            #expect(!damaged.automaticWritesSuspended)
            #expect(damaged.mode == .bento)
        } else {
            #expect(system.windows.map(\.frame) != baseline, "A failed restore must leave an actually mixed layout.")
            #expect(damaged.automaticWritesSuspended, "A real failed rollback must suspend its stored owner even after cancellation/Space change.")
            #expect(model.statusMessage?.contains("Repair Layout") == true)
        }
        if invalidation == "drag" { try #require(beganDrag) }
        if let newerOwner {
            #expect(damaged.revision >= newerOwner.revision)
            #expect(damaged.mode == newerOwner.mode)
            #expect(damaged.tabbedState == newerOwner.tabbedState)
            #expect(damaged.lastObservedFrames == newerOwner.lastObservedFrames)
        }
        if invalidation == "session" {
            #expect(model.statusMessage?.contains("other desktop") == true)
            #expect(recoveryCompletionStore(model)?.session(for: display)?.id != owner.id)
            #expect(recoveryCompletionStore(model)?.session(for: display)?.automaticWritesSuspended == false)
        }
        let after = system.frameWriteCounts
        try await assertRecoveryRemainsIdle(model, clock: recoveryClock)
        #expect(system.frameWriteCounts == after, "No automatic replay is allowed after the damaged entry.")
    }
}

@Suite(.appTestApplication, .serialized, .timeLimit(.minutes(5))) @MainActor
struct RecoveryRulePublicationTests {
    @Test(arguments: ["watchdog", "topology", "event"])
    func retainedRecoveryPublishesRuleSnapshotsBeforeClassificationReturns(route: String) async throws {
        let system = FakeAppWindowSystem()
        let display = system.mainDisplay.id, held = WindowID(rawValue: "held")
        system.windows.append(WindowSnapshot(id: held, processIdentifier: 43, bundleIdentifier: "com.example.Returned",
            title: "old", frame: BTRect(x: 500, y: 0, width: 500, height: 800), displayID: display))
        let space = NativeSpaceID(rawValue: 1)
        system.desktopObservation = NativeDesktopObservation(currentSpaceByDisplay: [display: space],
            knownSpacesByDisplay: [display: [space]],
            windowMembership: Dictionary(uniqueKeysWithValues: system.windows.map { ($0.id, [space]) }))
        let (model, _) = recoveryCompletionModel(system); defer { model.shutdown() }
        model.configuration.bentoInnerGap = 0
        model.setActiveMode(.bento)
        try #require(await waitFor { model.settlementTasks.isEmpty })
        system.applicationHoldsUntil[43] = 1_060
        system.windows[1].frame = BTRect(x: 0, y: 0, width: 500, height: 800)
        system.eventHandler?(WindowSystemEvent(kind: .resized, windowID: held, processIdentifier: 43))
        await model.windowEventTask?.value
        try #require(model.applicationRecoveryTask != nil, "An application held until future uptime must schedule recovery")
        system.windows[1].title = "current after hold"
        system.failedFrameWriteNumbers[held] = [system.frameWriteCounts[held, default: 0] + 1]
        system.applicationHoldsUntil[43] = 999
        if route == "watchdog" { model.watchdog() }
        else if route == "topology" { model.handleApplicationTopologyChange() }
        else {
            system.eventHandler?(WindowSystemEvent(kind: .created, windowID: held, processIdentifier: 43))
            await model.windowEventTask?.value
        }
        #expect(model.observedRuleWindows.first { $0.id == held }?.title == "current after hold")
        #expect(model.matchingRuleWindows(for: "com.example.Returned").first?.title == "current after hold")
        // Snapshot publication is checked independently of later recovery completion.
    }
}

@Suite(.appTestApplication, .serialized, .timeLimit(.minutes(5))) @MainActor
struct TabbedRecoveryEntryCompletionTests {
    @Test(arguments: TabbedStripPresentation.allCases)
    func successfulRecoveryEntryRetiresBaselineAndPendingIdentity(presentation: TabbedStripPresentation) async throws {
        let system = FakeAppWindowSystem()
        var added = system.windows[0]; added.id = WindowID(rawValue: "tab-1"); added.processIdentifier += 1; system.windows.append(added)
        let (model, _) = recoveryCompletionModel(system); defer { model.shutdown() }
        model.configuration.defaultTabbedPreset = .columns
        model.configuration.tabbedStripPresentation = presentation
        model.setActiveMode(.bento)
        try #require(await waitFor { model.settlementTasks.isEmpty })
        let returning = system.windows[1]
        system.applicationHoldsUntil[returning.processIdentifier] = 999
        system.failedVisibleWindowSweeps.insert(system.completeSweepCount + 1)
        model.setActiveMode(.tabbed)
        try #require(recoveryCompletionPending(model)[returning.id] == returning.processIdentifier)
        try #require(await waitFor { !model.hasPendingTabbedPlacement && model.activeLayoutMode == .tabbed })
        #expect(recoveryCompletionPending(model).isEmpty)
        let baselines = Mirror(reflecting: model).children.first { $0.label?.hasSuffix("tabbedEntryBaselines") == true }?.value as? [DesktopSessionID: LayoutSession]
        #expect(baselines?.isEmpty == true)
        let state = try #require(model.activeTabbedState)
        let selected = try #require(state.selectedWindowIDs.first)
        system.failedFrameWriteNumbers[selected] = [system.frameWriteCounts[selected, default: 0] + 1]
        model.performTabbed(.preset(.rows))
        try #require(await waitFor { !model.hasPendingTabbedPlacement })
        #expect(model.activeLayoutMode == .tabbed, "A later rejection must not reuse the retired entry baseline.")
        #expect(model.activeTabbedState == state)
    }
}

@Suite(.appTestApplication, .serialized, .timeLimit(.minutes(5))) @MainActor
struct TabbedRecoveryCancellationTests {
    @Test(arguments: [false, true])
    func entryCancelledBeforeDispatchDoesNotSuspend(changesSpace: Bool) async throws {
        let system = FakeAppWindowSystem()
        let display = system.mainDisplay.id
        let first = NativeSpaceID(rawValue: 1), second = NativeSpaceID(rawValue: 2)
        system.desktopObservation = NativeDesktopObservation(currentSpaceByDisplay: [display: first],
            knownSpacesByDisplay: [display: [first, second]], windowMembership: [system.windows[0].id: [first]])
        let (model, _) = recoveryCompletionModel(system)
        defer { model.shutdown() }
        model.setActiveMode(.bento)
        try #require(await waitFor { model.settlementTasks.isEmpty })
        let owner = try #require(recoveryCompletionStore(model)?.session(for: display))
        let frames = system.windows.map(\.frame), writes = system.frameWriteCounts
        var cancelled = false
        model.setActiveMode(.tabbed)
        system.onWindowSnapshots = { [weak model, weak system] in
            guard let model, let system, !cancelled else { return }
            cancelled = true
            if changesSpace {
                system.desktopObservation?.currentSpaceByDisplay[display] = second
                system.offscreenWindowIDs = Set(system.windows.map(\.id))
            }
            model.beginActiveSpaceStabilization()
        }
        try #require(await waitFor { cancelled && !model.hasPendingTabbedPlacement })
        let stored = try #require(recoveryCompletionStore(model)?.allSessions(for: display).first { $0.id == owner.id })
        #expect(!stored.automaticWritesSuspended)
        #expect(system.windows.map(\.frame) == frames)
        #expect(system.frameWriteCounts == writes)
        #expect(model.statusMessage?.contains("Repair Layout") != true)
    }

    @Test(arguments: ["none", "generation", "session"])
    func rejectedDropRetainsDegradedRestoration(invalidation: String) async throws {
        let system = FakeAppWindowSystem()
        let display = system.mainDisplay.id
        let first = NativeSpaceID(rawValue: 1), second = NativeSpaceID(rawValue: 2)
        system.desktopObservation = NativeDesktopObservation(currentSpaceByDisplay: [display: first],
            knownSpacesByDisplay: [display: [first, second]], windowMembership: [system.windows[0].id: [first]])
        let (model, recoveryClock) = recoveryCompletionModel(system)
        defer { model.shutdown() }
        model.setActiveMode(.tabbed)
        try #require(await waitFor { !model.hasPendingTabbedPlacement })
        let source = system.windows[0].id
        let owner = try #require(recoveryCompletionStore(model)?.session(for: display))
        try #require(model.beginBentoDrag(displayID: display, sourceID: source))
        system.windows[0].frame.origin.x += 140
        let displaced = system.windows[0].frame
        let writes = system.frameWriteCounts[source, default: 0]
        system.failedFrameWriteNumbers[source] = [writes + 1]
        var failedRestore = false
        system.onFrameWrite = { [weak model, weak system] id, _ in
            guard let model, let system, id == source, !failedRestore else { return }
            failedRestore = true
            if invalidation == "session" {
                system.desktopObservation?.currentSpaceByDisplay[display] = second
                system.offscreenWindowIDs = Set(system.windows.map(\.id))
            }
            if invalidation != "none" { model.beginActiveSpaceStabilization() }
        }
        model.finishBentoDrag(displayID: display, sourceID: source, end: .failed(reason: "That pane cannot hold it."))
        try #require(await waitFor { failedRestore && !model.hasPendingTabbedPlacement })
        let stored = try #require(recoveryCompletionStore(model)?.allSessions(for: display).first { $0.id == owner.id })
        #expect(stored.automaticWritesSuspended)
        #expect(system.windows[0].frame == displaced)
        #expect(model.statusMessage?.contains("Repair Layout") == true)
        if invalidation == "session" {
            #expect(model.statusMessage?.contains("other desktop") == true)
            #expect(recoveryCompletionStore(model)?.session(for: display)?.automaticWritesSuspended == false)
        }
        let after = system.frameWriteCounts
        try await assertRecoveryRemainsIdle(model, clock: recoveryClock)
        #expect(system.frameWriteCounts == after)
    }
}

@Suite(.appTestApplication, .serialized, .timeLimit(.minutes(5))) @MainActor
struct TabbedRecoveryStaleRestorationTests {
    @Test(arguments: [false, true])
    func rejectedDropWithStaleRestoreKeepsDamagedOwner(changesSpace: Bool) async throws {
        let system = FakeAppWindowSystem()
        let display = system.mainDisplay.id
        let first = NativeSpaceID(rawValue: 1), second = NativeSpaceID(rawValue: 2)
        system.desktopObservation = NativeDesktopObservation(currentSpaceByDisplay: [display: first],
            knownSpacesByDisplay: [display: [first, second]], windowMembership: [system.windows[0].id: [first]])
        let (model, recoveryClock) = recoveryCompletionModel(system)
        defer { model.shutdown() }
        model.setActiveMode(.tabbed)
        try #require(await waitFor { !model.hasPendingTabbedPlacement })
        let owner = try #require(recoveryCompletionStore(model)?.session(for: display))
        let source = system.windows[0].id
        try #require(model.beginBentoDrag(displayID: display, sourceID: source))
        system.windows[0].frame.origin.x += 140
        let displaced = system.windows[0].frame
        let writes = system.frameWriteCounts
        model.finishBentoDrag(displayID: display, sourceID: source, end: .failed(reason: "That pane cannot hold it."))
        var invalidated = false
        system.onWindowSnapshots = { [weak system, weak model] in
            guard let system, let model, !invalidated else { return }
            invalidated = true
            if changesSpace {
                system.desktopObservation?.currentSpaceByDisplay[display] = second
                system.offscreenWindowIDs = Set(system.windows.map(\.id))
            }
            model.beginActiveSpaceStabilization()
        }
        try #require(await waitFor { invalidated && !model.hasPendingTabbedPlacement })
        let stored = try #require(recoveryCompletionStore(model)?.allSessions(for: display).first { $0.id == owner.id })
        #expect(stored.automaticWritesSuspended)
        #expect(system.windows[0].frame == displaced)
        #expect(system.frameWriteCounts == writes, "A stale checkpoint must dispatch no restore or automatic replay.")
        #expect(model.statusMessage?.contains("Repair Layout") == true)
        if changesSpace {
            #expect(model.statusMessage?.contains("other desktop") == true)
            #expect(recoveryCompletionStore(model)?.session(for: display)?.automaticWritesSuspended == false)
        }
        try await assertRecoveryRemainsIdle(model, clock: recoveryClock)
        #expect(system.frameWriteCounts == writes)
    }
}
