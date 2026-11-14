import AppKit
import BetterTileCore
@testable import BetterTileMacOS
import Foundation
import Testing
@testable import BetterTileApp

/// A launched application's first window usually exists before BetterTile
/// installs the application's Accessibility observer, so no creation
/// notification follows. The launch sweep is then the only prompt read, and it
/// can omit the window: the window server can list it as not on screen yet.
/// Launch discovery reads that one application again on a bounded schedule.
/// These tests pin that such a window is placed promptly without the watchdog,
/// that discovery never makes a real creation worse off, that it reads only the
/// launched application, and that it ends.
@Suite(.appTestApplication, .serialized) @MainActor
struct LaunchedApplicationArrivalTests {
    private let launchedPID: Int32 = 77
    private let launchFrame = BTRect(x: 200, y: 200, width: 600, height: 400)

    private func fixture(_ mode: LayoutMode) async throws -> (FakeAppWindowSystem, BetterTileModel) {
        _ = NSApplication.shared
        let system = makeManualWindowSystem()
        system.windows.append(WindowSnapshot(id: WindowID(rawValue: "running-peer"), processIdentifier: 43,
            frame: BTRect(x: 100, y: 100, width: 600, height: 400), displayID: system.mainDisplay.id))
        system.focusedID = system.windows[0].id
        let model = makeModel(system: system)
        model.configuration.singleWindowPlacement = .maximize
        model.setActiveMode(mode)
        try #require(await system.waitFor { model.settlementTasks.isEmpty && (mode != .tabbed || model.activeTabbedState != nil) })
        try await waitForWindowEventsToDrain(model, system)
        await system.advance(by: .milliseconds(500))
        try await waitForWindowEventsToDrain(model, system)
        return (system, model)
    }

    @discardableResult
    private func addWindow(_ name: String, pid: Int32? = nil, _ system: FakeAppWindowSystem,
                           isFloating: Bool = false, offscreen: Bool = false) -> WindowID {
        let id = WindowID(rawValue: name)
        system.windows.append(WindowSnapshot(id: id, processIdentifier: pid ?? launchedPID,
            frame: launchFrame, displayID: system.mainDisplay.id, isFloating: isFloating))
        if offscreen { system.offscreenWindowIDs.insert(id) }
        return id
    }

    private func launch(_ model: BetterTileModel, _ pid: Int32? = nil) {
        model.handleApplicationLaunch(LaunchedApplication(processIdentifier: pid ?? launchedPID, isManaged: true))
    }

    private func isPlaced(_ id: WindowID, _ system: FakeAppWindowSystem, _ model: BetterTileModel) -> Bool {
        system.frameWriteCounts[id, default: 0] > 0 && !model.hasPendingTabbedPlacement
    }

    /// Advances the manual clock and the arrival clock together, in steps.
    private func run(to seconds: Double, from start: inout Double, _ system: FakeAppWindowSystem,
                     _ clock: WindowArrivalTestClock, step: Double = 0.01, until done: () -> Bool = { false }) async {
        while start < seconds - 1e-9, !done() {
            start += step
            clock.elapsed = start
            await system.advance(by: .milliseconds(Int64((step * 1000).rounded())))
        }
    }

    // MARK: - The measured case

    /// The live failure: the launch sweep reads the new window but omits it,
    /// the window is on screen a moment later, and no event follows. Before
    /// the fix only the watchdog found it, 2.5 to 10 seconds later.
    @Test(arguments: [LayoutMode.bento, .tabbed])
    func firstWindowThatTheLaunchSweepOmitsIsPlacedWithoutTheWatchdog(mode: LayoutMode) async throws {
        let (system, model) = try await fixture(mode)
        defer { model.shutdown() }
        _ = WindowArrivalTestClock(model)
        let id = addWindow("launched-first-window", system, offscreen: true)
        let launchSweep = system.completeSweepCount + 1
        system.onVisibleWindowSweep = { count in
            // The window server shows the window right after the launch sweep.
            if count > launchSweep { system.offscreenWindowIDs.remove(id) }
        }
        defer { system.onVisibleWindowSweep = nil }
        // Discovery reads do not run sweeps; show the window right after the launch sweep for them too.
        launch(model)
        system.offscreenWindowIDs.remove(id)

        #expect(system.completeSweepCount == launchSweep, "The launch runs its own sweep")
        #expect(system.frameWriteCounts[id, default: 0] == 0, "The launch sweep omitted the window")
        // The first discovery read runs 10 ms after the launch sweep.
        let placed = await system.waitFor(timeout: .milliseconds(100)) { isPlaced(id, system, model) }
        #expect(placed, "A launched window must be placed by discovery, not by the watchdog")
        #expect(system.launchedApplicationReads.allSatisfy { $0 == launchedPID })
        try await waitForWindowEventsToDrain(model, system)
        let frame = try #require(system.windows.first { $0.id == id }?.frame)
        #expect(frame != launchFrame, "The window left its launch frame")
        #expect(!model.hasLaunchDiscovery)
    }

    /// The common case needs no extra work: when the launch sweep returns the
    /// window, it is placed by that sweep and no discovery starts.
    @Test(arguments: [LayoutMode.bento, .tabbed])
    func firstWindowThatTheLaunchSweepReadsStartsNoDiscovery(mode: LayoutMode) async throws {
        let (system, model) = try await fixture(mode)
        defer { model.shutdown() }
        _ = WindowArrivalTestClock(model)
        let id = addWindow("launched-readable-window", system)
        let before = system.completeSweepCount

        launch(model)

        let sweepsAfterLaunch = system.completeSweepCount
        try #require(await system.waitFor { isPlaced(id, system, model) })
        try await waitForWindowEventsToDrain(model, system)
        await system.advance(by: .milliseconds(600))
        #expect(sweepsAfterLaunch - before == 1)
        #expect(system.completeSweepCount - sweepsAfterLaunch <= 1, "At most the ordinary validation pass follows")
        #expect(system.launchedApplicationReads.isEmpty)
        #expect(!model.hasLaunchDiscovery)
    }

    // MARK: - A first window shown after the burst

    /// The application built its window before the observer existed, but shows
    /// it later, with no further creation event.
    @Test(arguments: [LayoutMode.bento, .tabbed], [1.0, 3.0])
    func firstWindowShownAfterTheBurstIsPlacedPromptly(mode: LayoutMode, shownAt: Double) async throws {
        let (system, model) = try await fixture(mode)
        defer { model.shutdown() }
        let clock = WindowArrivalTestClock(model)
        let id = addWindow("launched-shown-late", system, offscreen: true)
        launch(model)
        var now = 0.0
        await run(to: shownAt, from: &now, system, clock)
        #expect(system.frameWriteCounts[id, default: 0] == 0)
        system.offscreenWindowIDs.remove(id)
        let shown = now
        await run(to: shownAt + 1.0, from: &now, system, clock) { isPlaced(id, system, model) }
        #expect(isPlaced(id, system, model), "Shown at \(shownAt) s, the window must be placed before the watchdog")
        #expect(now - shown <= 0.6, "Placed \(now - shown) s after it showed; the slowest turn gap there is 0.5 s")
        try await waitForWindowEventsToDrain(model, system)
    }

    /// A focus change of the launched application asks for a read at once.
    @Test(arguments: [LayoutMode.bento, .tabbed])
    func focusChangeOfTheLaunchedApplicationReadsAtOnce(mode: LayoutMode) async throws {
        let (system, model) = try await fixture(mode)
        defer { model.shutdown() }
        let clock = WindowArrivalTestClock(model)
        let id = addWindow("launched-focused", system, offscreen: true)
        launch(model)
        var now = 0.0
        await run(to: 2.05, from: &now, system, clock) // The next turn is at 2.5 s.
        system.offscreenWindowIDs.remove(id)
        system.focusedID = id
        system.eventHandler?(WindowSystemEvent(kind: .focused, windowID: nil, processIdentifier: launchedPID))
        let placed = await system.waitFor(timeout: .milliseconds(50)) { isPlaced(id, system, model) }
        #expect(placed, "The focus event must not wait for the next scheduled turn")
        try await waitForWindowEventsToDrain(model, system)
    }

    // MARK: - Only the launched application, bounded, then idle

    /// A launched application that never shows a window gets its scheduled
    /// reads and nothing more: no complete inventory, and no work once
    /// discovery ends.
    @Test(arguments: [LayoutMode.bento, .tabbed])
    func discoveryWithoutAWindowReadsOnlyThatApplicationAndEnds(mode: LayoutMode) async throws {
        let (system, model) = try await fixture(mode)
        defer { model.shutdown() }
        _ = WindowArrivalTestClock(model)
        addWindow("launched-never-shown", system, offscreen: true)
        let writes = system.frameWriteCounts

        launch(model)
        let sweepsAfterLaunch = system.completeSweepCount
        let ended = await system.waitFor(timeout: LaunchDiscoverySchedule.bound + .milliseconds(100)) { !model.hasLaunchDiscovery }

        #expect(ended, "Discovery ends at its bound")
        #expect(system.launchedApplicationReads == Array(repeating: launchedPID, count: LaunchDiscoverySchedule.delays.count))
        #expect(system.completeSweepCount == sweepsAfterLaunch, "Discovery takes no complete inventory")
        #expect(!model.hasLaunchDiscovery)
        let reads = system.launchedApplicationReads.count, sweeps = system.completeSweepCount
        await system.advance(by: .seconds(20))
        #expect(system.launchedApplicationReads.count == reads, "No read after discovery ends")
        #expect(system.completeSweepCount == sweeps, "No sweep after discovery ends")
        #expect(system.frameWriteCounts == writes, "A window that is not shown is not placed")
    }

    /// The adapter refuses an application it does not manage, or one that quit
    /// or stopped responding: discovery ends after that read.
    @Test func discoveryEndsWhenTheApplicationIsUnavailable() async throws {
        let (system, model) = try await fixture(.bento)
        defer { model.shutdown() }
        _ = WindowArrivalTestClock(model)
        addWindow("launched-unavailable", system, offscreen: true)
        system.unavailableLaunchedProcessIDs.insert(launchedPID)
        launch(model)
        await system.advance(by: .seconds(7))
        #expect(system.launchedApplicationReads == [launchedPID])
        #expect(!model.hasLaunchDiscovery)
    }

    enum Launch: String, CaseIterable, Sendable {
        case menuBarApplication, backgroundHelper, hiddenRegularApplication, alreadyQuit, betterTileItself
    }

    /// A menu-bar application, a background helper or agent, a hidden launch,
    /// a launch that already quit, and BetterTile itself start no discovery.
    @Test(arguments: Launch.allCases)
    func unmanagedLaunchStartsNoDiscovery(_ kind: Launch) async throws {
        let ownPID: Int32 = 4_242
        let launched = switch kind {
        case .menuBarApplication:
            LaunchedApplication(processIdentifier: launchedPID, activationPolicy: .accessory, isHidden: false,
                                isTerminated: false, ownProcessIdentifier: ownPID)
        case .backgroundHelper:
            LaunchedApplication(processIdentifier: launchedPID, activationPolicy: .prohibited, isHidden: false,
                                isTerminated: false, ownProcessIdentifier: ownPID)
        case .hiddenRegularApplication:
            LaunchedApplication(processIdentifier: launchedPID, activationPolicy: .regular, isHidden: true,
                                isTerminated: false, ownProcessIdentifier: ownPID)
        case .alreadyQuit:
            LaunchedApplication(processIdentifier: launchedPID, activationPolicy: .regular, isHidden: false,
                                isTerminated: true, ownProcessIdentifier: ownPID)
        case .betterTileItself:
            LaunchedApplication(processIdentifier: ownPID, activationPolicy: .regular, isHidden: false,
                                isTerminated: false, ownProcessIdentifier: ownPID)
        }
        #expect(!launched.isManaged)
        #expect(LaunchedApplication(processIdentifier: launchedPID, activationPolicy: .regular, isHidden: false,
                                    isTerminated: false, ownProcessIdentifier: ownPID).isManaged)

        let (system, model) = try await fixture(.bento)
        defer { model.shutdown() }
        _ = WindowArrivalTestClock(model)
        addWindow("unmanaged-launch", pid: launched.processIdentifier, system, offscreen: true)
        let before = system.completeSweepCount
        model.handleApplicationLaunch(launched)
        await system.advance(by: .seconds(7))
        #expect(system.launchedApplicationReads.isEmpty)
        #expect(system.completeSweepCount - before == 1, "Only the launch sweep that main already runs")
        #expect(!model.hasLaunchDiscovery)
    }

    /// Manual mode places nothing, so a launch starts no discovery.
    @Test func manualModeStartsNoDiscovery() async throws {
        let (system, model) = try await fixture(.manual)
        defer { model.shutdown() }
        _ = WindowArrivalTestClock(model)
        let id = addWindow("launched-in-manual", system, offscreen: true)

        launch(model)
        let sweepsAfterLaunch = system.completeSweepCount
        await system.advance(by: .seconds(7))

        #expect(system.completeSweepCount == sweepsAfterLaunch)
        #expect(system.launchedApplicationReads.isEmpty)
        #expect(system.frameWriteCounts[id, default: 0] == 0)
    }

    /// A Space change defers discovery reads; discovery resumes afterwards.
    @Test func spaceChangeDefersDiscoveryReads() async throws {
        let (system, model) = try await fixture(.bento)
        defer { model.shutdown() }
        _ = WindowArrivalTestClock(model)
        let id = addWindow("launched-during-space-change", system, offscreen: true)
        launch(model)
        model.beginActiveSpaceStabilization()
        try #require(model.isStabilizingSpace)
        await system.advance(by: .milliseconds(30))
        if model.isStabilizingSpace {
            #expect(system.launchedApplicationReads.isEmpty, "No discovery read while the Space settles")
        }
        try #require(await system.waitFor { !model.isStabilizingSpace })
        system.offscreenWindowIDs.remove(id)
        let placed = await system.waitFor(timeout: .seconds(2)) { isPlaced(id, system, model) }
        #expect(placed)
        try await waitForWindowEventsToDrain(model, system)
    }

    // MARK: - A real creation is never worse off

    /// Launch, then a token-bearing creation at 0.4 s whose geometry is not
    /// complete until 0.65 s. The creation keeps its own token, its own 0.5 s
    /// deadline and the targeted read, as on main.
    @Test(arguments: [LayoutMode.bento, .tabbed])
    func creationDuringDiscoveryKeepsItsOwnReadinessDeadline(mode: LayoutMode) async throws {
        let (system, model) = try await fixture(mode)
        defer { model.shutdown() }
        let clock = WindowArrivalTestClock(model)
        launch(model)
        var now = 0.0
        await run(to: 0.4, from: &now, system, clock)
        let id = addWindow("created-after-launch", system, offscreen: true)
        let token: UInt64 = 7_001
        system.createdWindowsByToken[token] = id
        system.notReadyReads[token] = .max
        let createdReads = system.createdReadCount
        system.eventHandler?(WindowSystemEvent(kind: .created, windowID: nil, processIdentifier: launchedPID, creationToken: token))
        let discoveryReads = system.launchedApplicationReads.count
        await run(to: 0.65, from: &now, system, clock)
        #expect(system.launchedApplicationReads.count == discoveryReads, "Discovery waits while the creation owns its window")
        system.notReadyReads[token] = 0
        system.offscreenWindowIDs.remove(id)
        await run(to: 1.2, from: &now, system, clock) { isPlaced(id, system, model) }
        #expect(isPlaced(id, system, model), "Placed by the creation's own readiness interval, as on main")
        #expect(now <= 0.9, "Placed at \(now) s, inside the creation's deadline")
        #expect(system.createdReadCount > createdReads, "The creation used its targeted read")
        try await waitForWindowEventsToDrain(model, system)
    }

    /// A floating first window, such as a splash panel, does not end the wait
    /// for the application's ordinary window.
    @Test(arguments: [LayoutMode.bento, .tabbed])
    func floatingFirstWindowDoesNotEndTheWaitForTheOrdinaryWindow(mode: LayoutMode) async throws {
        let (system, model) = try await fixture(mode)
        defer { model.shutdown() }
        _ = WindowArrivalTestClock(model)
        let splash = addWindow("launched-splash", system, isFloating: true)
        let id = addWindow("launched-document", system, offscreen: true)
        let launchSweep = system.completeSweepCount + 1
        system.onVisibleWindowSweep = { count in
            if count > launchSweep { system.offscreenWindowIDs.remove(id) }
        }
        defer { system.onVisibleWindowSweep = nil }

        launch(model)
        system.offscreenWindowIDs.remove(id)

        let placed = await system.waitFor(timeout: .milliseconds(100)) { isPlaced(id, system, model) }
        #expect(placed, "The ordinary window must still be placed promptly")
        #expect(system.frameWriteCounts[splash, default: 0] == 0, "The floating splash stays untiled")
        try await waitForWindowEventsToDrain(model, system)
    }

    // MARK: - Other launches and quits retire only their own process

    enum Interruption: String, CaseIterable, Sendable { case anotherLaunch, helperQuits }

    /// A's launch sweep misses its window. During A's discovery, B launches with
    /// a readable window, or a helper quits. A stays omitted through those
    /// sweeps, shows at 0.3 s, and is placed within its budget.
    @Test(arguments: [LayoutMode.bento, .tabbed], Interruption.allCases)
    func unrelatedLaunchOrQuitKeepsDiscovery(mode: LayoutMode, interruption: Interruption) async throws {
        let (system, model) = try await fixture(mode)
        defer { model.shutdown() }
        let clock = WindowArrivalTestClock(model)
        let a = addWindow("launched-a", system, offscreen: true)
        launch(model)
        var now = 0.0
        await run(to: 0.05, from: &now, system, clock)
        switch interruption {
        case .anotherLaunch:
            let b: Int32 = 88
            let bWindow = addWindow("launched-b", pid: b, system)
            launch(model, b)
            await run(to: 0.15, from: &now, system, clock) { isPlaced(bWindow, system, model) }
        case .helperQuits:
            model.handleApplicationTermination(processIdentifier: 99)
            await run(to: 0.15, from: &now, system, clock)
        }
        #expect(model.hasLaunchDiscovery, "A's discovery survives")
        await run(to: 0.3, from: &now, system, clock)
        system.offscreenWindowIDs.remove(a)
        await run(to: 1.0, from: &now, system, clock) { isPlaced(a, system, model) }
        #expect(isPlaced(a, system, model))
        #expect(now <= 0.6, "Placed at \(now) s")
        try await waitForWindowEventsToDrain(model, system)
    }

    /// A running application's created arrival, still waiting for readable
    /// geometry, survives an unrelated launch.
    @Test(arguments: [LayoutMode.bento, .tabbed])
    func pendingCreationOfAnotherApplicationSurvivesALaunch(mode: LayoutMode) async throws {
        let (system, model) = try await fixture(mode)
        defer { model.shutdown() }
        let clock = WindowArrivalTestClock(model)
        let pid = system.windows[1].processIdentifier
        let id = addWindow("running-created", pid: pid, system, offscreen: true)
        let token: UInt64 = 7_002
        system.createdWindowsByToken[token] = id
        system.notReadyReads[token] = .max
        system.eventHandler?(WindowSystemEvent(kind: .created, windowID: nil, processIdentifier: pid, creationToken: token))
        var now = 0.0
        await run(to: 0.05, from: &now, system, clock)
        addWindow("unrelated-launch", pid: 89, system)
        launch(model, 89)
        await run(to: 0.25, from: &now, system, clock)
        system.notReadyReads[token] = 0
        system.offscreenWindowIDs.remove(id)
        await run(to: 1.0, from: &now, system, clock) { isPlaced(id, system, model) }
        #expect(isPlaced(id, system, model), "The created arrival keeps its deadline across another launch")
        #expect(now <= 0.55)
        try await waitForWindowEventsToDrain(model, system)
    }

    /// The launched application quits during discovery: discovery ends.
    @Test func quitOfTheLaunchedApplicationEndsDiscovery() async throws {
        let (system, model) = try await fixture(.bento)
        defer { model.shutdown() }
        _ = WindowArrivalTestClock(model)
        addWindow("launched-then-quit", system, offscreen: true)
        launch(model)
        await system.advance(by: .milliseconds(60))
        #expect(model.hasLaunchDiscovery)
        system.windows.removeAll { $0.processIdentifier == launchedPID }
        model.handleApplicationTermination(processIdentifier: launchedPID)
        let reads = system.launchedApplicationReads.count
        await system.advance(by: .seconds(7))
        #expect(!model.hasLaunchDiscovery)
        #expect(system.launchedApplicationReads.count == reads)
    }

    /// A second window of an application that already runs arrives through its
    /// creation notification; pinned beside the launch.
    @Test(arguments: [LayoutMode.bento, .tabbed])
    func secondWindowOfARunningApplicationThatTheFirstSweepOmitsIsPlaced(mode: LayoutMode) async throws {
        let (system, model) = try await fixture(mode)
        defer { model.shutdown() }
        _ = WindowArrivalTestClock(model)
        let pid = system.windows[1].processIdentifier
        let id = addWindow("running-second-window", pid: pid, system, offscreen: true)
        let firstSweep = system.completeSweepCount + 1
        system.onVisibleWindowSweep = { count in
            if count > firstSweep { system.offscreenWindowIDs.remove(id) }
        }
        defer { system.onVisibleWindowSweep = nil }

        system.eventHandler?(WindowSystemEvent(kind: .created, windowID: nil, processIdentifier: pid))

        let placed = await system.waitFor(timeout: .milliseconds(400)) { isPlaced(id, system, model) }
        #expect(placed)
        try await waitForWindowEventsToDrain(model, system)
    }

    // MARK: - Round 2: placement guards, creations that are not ordinary, missing state

    /// A peer's native resize is queued when discovery finds the window. The
    /// window must not be placed from the cached inventory, whose peer frame is
    /// stale: that placement would write the peer back to its old pane. A
    /// complete inventory adopts the resize first, and the peer keeps it.
    /// (Adaptive only: Tabbed returns a pane window to its pane either way.)
    @Test func discoveryKeepsAPeerResizeThatIsStillQueued() async throws {
        let (system, model) = try await fixture(.bento)
        defer { model.shutdown() }
        _ = WindowArrivalTestClock(model)
        let id = addWindow("launched-during-snap", system, offscreen: true)
        launch(model)
        try #require(model.hasLaunchDiscovery)
        // The cache still holds the peer's frame from before the resize.
        system.staleCache = system.windows.filter { $0.id != id }
        let peer = try #require(system.windows.firstIndex { $0.id == WindowID(rawValue: "running-peer") })
        let pane = system.windows[peer].frame
        try #require(pane.minX == 0 && pane.size.width > 300, "The peer starts in the left pane: \(pane)")
        var snapped = pane
        snapped.size.width -= 150
        system.windows[peer].frame = snapped
        for kind in [WindowSystemEvent.Kind.moved, .resized] {
            system.eventHandler?(WindowSystemEvent(kind: kind, windowID: system.windows[peer].id,
                                                   processIdentifier: system.windows[peer].processIdentifier))
        }
        system.offscreenWindowIDs.remove(id)
        let writes = system.frameWriteCounts, sweeps = system.completeSweepCount

        model.launchDiscoveryRead(launchedPID)

        #expect(system.frameWriteCounts == writes, "No write from the cache while the resize is unclassified")
        var sweepsAtFirstWrite: Int?
        system.onFrameWrite = { written, _ in if written == id, sweepsAtFirstWrite == nil { sweepsAtFirstWrite = system.completeSweepCount } }
        defer { system.onFrameWrite = nil }
        let placed = await system.waitFor(timeout: .milliseconds(100)) { isPlaced(id, system, model) }
        #expect(placed, "A complete inventory places the window at the arrival delay")
        #expect((sweepsAtFirstWrite ?? 0) > sweeps, "Placement follows a complete inventory")
        try await waitForWindowEventsToDrain(model, system)
        await system.advance(by: .milliseconds(500))
        try await waitForWindowEventsToDrain(model, system)
        let kept = try #require(system.windows.first { $0.id == WindowID(rawValue: "running-peer") }?.frame)
        #expect(kept.approximatelyEquals(snapped, tolerance: 1), "The peer keeps the user's resize: \(kept), expected \(snapped)")
        #expect(!model.hasLaunchDiscovery)
    }

    /// Without exact identities, discovery's own read places nothing. A missed
    /// first window is found by the complete inventory that the next scheduled
    /// turn asks for, where main's ordinary filter decides it.
    @Test(arguments: [LayoutMode.bento, .tabbed])
    func withoutExactIdentitiesAMissedFirstWindowIsPlacedByACompleteInventory(mode: LayoutMode) async throws {
        let (system, model) = try await fixture(mode)
        defer { model.shutdown() }
        _ = WindowArrivalTestClock(model)
        let first = addWindow("launched-unidentified-a", system, offscreen: true)
        let second = addWindow("launched-unidentified-b", system, offscreen: true)
        system.unidentifiedLaunchedProcessIDs.insert(launchedPID)
        launch(model)
        try #require(model.hasLaunchDiscovery)
        system.offscreenWindowIDs.subtract([first, second])
        let sweeps = system.completeSweepCount
        let placed = await system.waitFor(timeout: .milliseconds(100)) {
            isPlaced(first, system, model) && isPlaced(second, system, model)
        }
        #expect(placed, "The first turn's complete inventory places both windows")
        #expect(system.completeSweepCount > sweeps)
        try await waitForWindowEventsToDrain(model, system)
        #expect(!model.hasLaunchDiscovery)
        #expect(system.launchedApplicationReads.count <= 2)
    }

    /// The bound without exact identities: a first window that main's filter
    /// still rejects causes at most one complete inventory per scheduled turn
    /// (16 for one launch), none for focus-requested reads, and none after
    /// discovery ends.
    @Test(arguments: [LayoutMode.bento, .tabbed])
    func withoutExactIdentitiesDiscoveryCausesAtMostOneInventoryPerScheduledTurn(mode: LayoutMode) async throws {
        let (system, model) = try await fixture(mode)
        defer { model.shutdown() }
        let clock = WindowArrivalTestClock(model)
        addWindow("launched-never-on-screen", system, offscreen: true)
        system.unidentifiedLaunchedProcessIDs.insert(launchedPID)
        launch(model)
        let sweepsAfterLaunch = system.completeSweepCount
        var now = 0.0
        // Focus events throughout ask for extra reads; they must not add inventories.
        while model.hasLaunchDiscovery, now < 8 {
            system.eventHandler?(WindowSystemEvent(kind: .focused, windowID: nil, processIdentifier: launchedPID))
            await run(to: now + 0.05, from: &now, system, clock)
        }
        #expect(!model.hasLaunchDiscovery, "Discovery ends at its bound")
        // The last turn's inventory may still be queued; it counts against the bound.
        try await waitForWindowEventsToDrain(model, system)
        let inventories = system.completeSweepCount - sweepsAfterLaunch
        #expect(inventories <= LaunchDiscoverySchedule.delays.count, "\(inventories) complete inventories for one launch")
        #expect(inventories >= 1)
        let sweeps = system.completeSweepCount
        await system.advance(by: .seconds(20))
        #expect(system.completeSweepCount == sweeps, "Nothing after discovery ends: \(system.completeSweepCount - sweeps) more")
    }

    /// The same while an application is held as unresponsive.
    @Test func discoveryDoesNotPlaceFromTheCacheDuringApplicationRecovery() async throws {
        let (system, model) = try await fixture(.bento)
        defer { model.shutdown() }
        _ = WindowArrivalTestClock(model)
        let id = addWindow("launched-during-recovery", system, offscreen: true)
        launch(model)
        system.applicationHoldsUntil[43] = system.uptime + 30
        system.offscreenWindowIDs.remove(id)
        let writes = system.frameWriteCounts, sweeps = system.completeSweepCount
        model.launchDiscoveryRead(launchedPID)
        #expect(system.frameWriteCounts == writes)
        _ = await system.waitFor(timeout: .milliseconds(50)) { system.completeSweepCount > sweeps }
        #expect(system.completeSweepCount > sweeps, "A complete inventory takes over")
        system.applicationHoldsUntil[43] = nil
    }

    /// Opus's probe: the app creates a floating splash at 0.1 s; its ordinary
    /// window, built before the observer, shows at 1.0 s with no new event.
    @Test(arguments: [LayoutMode.bento, .tabbed])
    func floatingCreationDoesNotEndDiscovery(mode: LayoutMode) async throws {
        let (system, model) = try await fixture(mode)
        defer { model.shutdown() }
        let clock = WindowArrivalTestClock(model)
        let id = addWindow("launched-prebuilt", system, offscreen: true)
        launch(model)
        var now = 0.0
        await run(to: 0.1, from: &now, system, clock)
        let splash = addWindow("launched-splash-created", system, isFloating: true)
        let token: UInt64 = 7_003
        system.createdWindowsByToken[token] = splash
        system.eventHandler?(WindowSystemEvent(kind: .created, windowID: nil, processIdentifier: launchedPID, creationToken: token))
        await run(to: 1.0, from: &now, system, clock)
        #expect(model.hasLaunchDiscovery, "A floating creation does not end discovery")
        system.offscreenWindowIDs.remove(id)
        let shown = now
        await run(to: 2.5, from: &now, system, clock) { isPlaced(id, system, model) }
        #expect(isPlaced(id, system, model))
        #expect(now - shown <= 0.6, "Placed \(now - shown) s after it showed")
        #expect(system.frameWriteCounts[splash, default: 0] == 0)
        try await waitForWindowEventsToDrain(model, system)
    }

    /// A window that the launch sweep returned as floating (still being
    /// built) is placed once it is ordinary: discovery decides by state.
    @Test(arguments: [LayoutMode.bento, .tabbed])
    func windowFirstReadAsFloatingIsPlacedWhenItBecomesOrdinary(mode: LayoutMode) async throws {
        let (system, model) = try await fixture(mode)
        defer { model.shutdown() }
        let clock = WindowArrivalTestClock(model)
        let id = addWindow("launched-building", system, isFloating: true)
        launch(model)
        #expect(model.hasLaunchDiscovery)
        var now = 0.0
        await run(to: 0.2, from: &now, system, clock)
        #expect(system.frameWriteCounts[id, default: 0] == 0)
        let index = try #require(system.windows.firstIndex { $0.id == id })
        system.windows[index].isFloating = false
        let ordinary = now
        await run(to: 1.5, from: &now, system, clock) { isPlaced(id, system, model) }
        #expect(isPlaced(id, system, model))
        #expect(now - ordinary <= 0.3, "Placed \(now - ordinary) s after it became ordinary")
        try await waitForWindowEventsToDrain(model, system)
    }

    /// A burst of focus events is coalesced and rate-limited; it does not use
    /// up the scheduled turns, so a window shown at 1.0 s is still placed.
    @Test(arguments: [LayoutMode.bento, .tabbed])
    func focusBurstDoesNotUseUpTheSchedule(mode: LayoutMode) async throws {
        let (system, model) = try await fixture(mode)
        defer { model.shutdown() }
        let clock = WindowArrivalTestClock(model)
        let id = addWindow("launched-focus-burst", system, offscreen: true)
        launch(model)
        var now = 0.0
        for _ in 0..<16 {
            system.eventHandler?(WindowSystemEvent(kind: .focused, windowID: nil, processIdentifier: launchedPID))
            await run(to: now + 0.01, from: &now, system, clock)
        }
        let burstReads = system.launchedApplicationReads.count
        #expect(burstReads <= 7 + 2, "At most the 6 scheduled turns before 0.16 s and two focus reads: \(burstReads)")
        await run(to: 1.0, from: &now, system, clock)
        #expect(model.hasLaunchDiscovery)
        system.offscreenWindowIDs.remove(id)
        let shown = now
        await run(to: 2.5, from: &now, system, clock) { isPlaced(id, system, model) }
        #expect(isPlaced(id, system, model))
        #expect(now - shown <= 0.6)
        #expect(system.launchedApplicationReads.count <= LaunchDiscoverySchedule.delays.count + LaunchDiscoverySchedule.focusReadLimit)
        try await waitForWindowEventsToDrain(model, system)
    }

    // MARK: - End and postpone conditions

    @Test func wakeEndsDiscovery() async throws {
        let (system, model) = try await fixture(.bento)
        defer { model.shutdown() }
        _ = WindowArrivalTestClock(model)
        addWindow("launched-before-sleep", system, offscreen: true)
        launch(model)
        try #require(model.hasLaunchDiscovery)
        model.handleApplicationTopologyChange(waking: true)
        #expect(!model.hasLaunchDiscovery)
        let reads = system.launchedApplicationReads.count
        await system.advance(by: .seconds(7))
        #expect(system.launchedApplicationReads.count == reads)
        model.handleDisplayChange(.wake)
    }

    @Test func switchingToManualEndsDiscovery() async throws {
        let (system, model) = try await fixture(.bento)
        defer { model.shutdown() }
        _ = WindowArrivalTestClock(model)
        addWindow("launched-then-manual", system, offscreen: true)
        launch(model)
        try #require(model.hasLaunchDiscovery)
        model.setActiveMode(.manual)
        let ended = await system.waitFor(timeout: .milliseconds(100)) { !model.hasLaunchDiscovery }
        #expect(ended)
        let reads = system.launchedApplicationReads.count
        await system.advance(by: .seconds(7))
        #expect(system.launchedApplicationReads.count == reads)
    }

    @Test func displayHoldPostponesDiscoveryReads() async throws {
        let (system, model) = try await fixture(.bento)
        defer { model.shutdown() }
        _ = WindowArrivalTestClock(model)
        addWindow("launched-during-hold", system, offscreen: true)
        launch(model)
        model.handleDisplayChange(.displayReconfigurationBegan)
        try #require(model.isHoldingDisplayChange)
        let reads = system.launchedApplicationReads.count
        #expect(model.launchDiscoveryRead(launchedPID))
        #expect(system.launchedApplicationReads.count == reads, "No read during a display hold")
        #expect(model.hasLaunchDiscovery)
        model.handleDisplayChange(.displayReconfigurationEnded)
    }

    @Test func dividerGesturePostponesDiscoveryReads() async throws {
        let (system, model) = try await fixture(.bento)
        defer { model.shutdown() }
        _ = WindowArrivalTestClock(model)
        addWindow("launched-during-gesture", system, offscreen: true)
        launch(model)
        let presentation = model.dividerPresentation(windows: system.windows)
        model.dividerResize.refresh(boundaries: presentation.boundaries, obscuringFrames: [])
        model.dividerResize.ownWindowsProvider = { [] }
        let grip = try #require(presentation.boundaries.lazy.compactMap { boundary -> (DividerInteraction, BTPoint)? in
            let middle = (boundary.spanStart + boundary.spanEnd) / 2
            for point in [BTPoint(x: boundary.coordinate, y: middle), BTPoint(x: middle, y: boundary.coordinate)] {
                if let found = DividerInteractionResolver.resolve(at: point, in: presentation.boundaries, hitWidth: 18,
                    adjacencyTolerance: 6, paneGap: model.configuration.bentoInnerGap) { return (found, point) }
            }
            return nil
        }.first)
        model.dividerResize.beginGesture(interaction: grip.0, at: grip.1)
        try #require(model.dividerResize.isDragging)
        let reads = system.launchedApplicationReads.count
        #expect(model.launchDiscoveryRead(launchedPID))
        #expect(system.launchedApplicationReads.count == reads, "No read during a gesture")
        model.dividerResize.hideAndCancel()
    }

    @Test func savedLayoutApplyPostponesDiscoveryReads() async throws {
        let system = makeManualWindowSystem(drivingPolicyDeadlines: true)
        let h = ApplyHarness(system: system)
        defer { h.close() }
        h.addWindow()
        h.addWindow("com.example.Other", id: "other", pid: 44)
        let model = makeModel(system: system)
        defer { model.shutdown() }
        _ = WindowArrivalTestClock(model)
        model.setActiveMode(.bento)
        await system.advance(by: .seconds(1))
        try #require(await system.waitFor { model.windowEventTask == nil && model.settlementTasks.isEmpty })
        system.windows.append(WindowSnapshot(id: WindowID(rawValue: "launched-during-apply"), processIdentifier: launchedPID,
            frame: launchFrame, displayID: system.mainDisplay.id))
        system.offscreenWindowIDs.insert(WindowID(rawValue: "launched-during-apply"))
        launch(model)
        try #require(model.hasLaunchDiscovery)
        let applier = try #require(model.savedLayoutApplier)
        applier.observesKeyboard = false
        applier.application = h.applier.application
        var readsDuringApply: Int?
        system.onWindowSnapshots = {
            guard readsDuringApply == nil, applier.ownedDisplayID != nil else { return }
            let before = system.launchedApplicationReads.count
            model.launchDiscoveryRead(launchedPID)
            readsDuringApply = system.launchedApplicationReads.count - before
        }
        defer { system.onWindowSnapshots = nil }
        _ = await system.drive { await applier.apply(h.document(mode: .bento), automatic: false) }
        let observed = try #require(readsDuringApply, "The apply owned the display while it read windows")
        #expect(observed == 0, "No discovery read while Saved Layout Apply owns the display")
    }
}
