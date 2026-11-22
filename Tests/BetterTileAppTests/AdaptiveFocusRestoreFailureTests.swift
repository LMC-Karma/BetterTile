import AppKit
import BetterTileCore
import BetterTileMacOS
import Testing
@testable import BetterTileApp

// A Focus mode peer that does not come back must stay known. Restore names
// its application, and Repair tries it again instead of reporting success.
// These tests run on the manual clock; their time limits only catch a hang.

/// How the stuck peer fails: macOS refuses the request at once, or the
/// application accepts it and never shows the window.
enum FocusPeerFailure: CaseIterable, Sendable { case refused, neverReturns }

/// The stuck peer's application name holds words that pick a pill title by
/// keyword from a free-form failure reason. The pills must not use them.
private let stuckName = "Accessibility Permission Tabbed"
private let stuckMinimized = "The \(stuckName) window stayed minimized."
private let repairPartial = "Layout partly applied"

@Test(.appTestApplication, .timeLimit(.minutes(5)),
      arguments: FocusPeerFailure.allCases, [false, true]) @MainActor
func aFocusPeerThatDoesNotReturnIsNamedAndRepairTriesItAgain(
    failure: FocusPeerFailure, repairsWhileWaiting: Bool
) async throws {
    let (system, model, stuck) = try await focusModeWithTwoPeers()
    defer { model.shutdown() }
    stuckPeerFails(failure, stuck: stuck, system: system)

    model.perform(.restore)
    if failure == .refused {
        // The refusal is known at once, so Restore names the application.
        #expect(model.lastActionFeedback == .failure(title: "Use Repair Layout", detail: stuckMinimized),
                "\(feedbackText(model))")
    }
    if !repairsWhileWaiting {
        await settleFocusRestore(model, system: system)
        // The wait ended without the peer. Restore reports it by name, once.
        let expected: ResultPillFeedback = failure == .refused
            ? .failure(title: "Use Repair Layout", detail: stuckMinimized)
            : .layoutResult(title: "Layout partly restored",
                            detail: "The \(stuckName) window has not come back yet. Use Repair Layout if it stays away.",
                            kind: .warning, actions: [])
        #expect(model.lastActionFeedback == expected, "\(feedbackText(model))")
    }
    let requestsBeforeRepair = system.restoreRequests.filter { $0 == stuck }.count

    // Repair tries the peer again. It still fails, so Repair reports a
    // partial result that names the application, not "Layout applied".
    model.tileCurrentDisplay()
    // Repair reports after its own wait for the peer, which can start only
    // after Restore's wait ends.
    #expect(await system.waitFor(timeout: .seconds(6)) { model.lastActionFeedback?.message == repairPartial },
            "\(feedbackText(model))")
    await settleFocusRestore(model, system: system)
    #expect(system.restoreRequests.filter { $0 == stuck }.count == requestsBeforeRepair + 1)
    #expect(system.windows.first { $0.id == stuck }?.isMinimized == true)
    expectRepairPartial(model)
    // The windows that did return still fill the display without overlap.
    let visible = system.windows.filter { !$0.isMinimized }
    #expect(visible.count == 2)
    #expect(fillsDisplay(visible, system: system), "\(visible.map(\.frame))")

    // When the peer can return, Repair brings it back and tiles it.
    system.failedRestoreWindowIDs = []
    system.slowRestoreIDs = []
    model.tileCurrentDisplay()
    #expect(await system.waitFor(timeout: .seconds(6)) { model.lastActionFeedback?.kind == .success },
            "\(feedbackText(model))")
    await settleFocusRestore(model, system: system)
    #expect(system.windows.allSatisfy { !$0.isMinimized })
    #expect(fillsDisplay(system.windows, system: system), "\(system.windows.map(\.frame))")
    #expect(model.lastActionFeedback?.kind == .success, "\(feedbackText(model))")

    // The peer is no longer outstanding: the next Repair does not touch it.
    let requests = system.restoreRequests.count
    model.tileCurrentDisplay()
    await settleFocusRestore(model, system: system)
    #expect(system.restoreRequests.count == requests)
    #expect(model.lastActionFeedback?.kind == .success, "\(feedbackText(model))")
}

/// A peer restored later from the Dock is no longer outstanding, so Repair
/// neither restores it again nor reports it.
@Test(.appTestApplication, .timeLimit(.minutes(5))) @MainActor
func aFocusPeerRestoredLaterFromTheDockIsNoLongerReported() async throws {
    let (system, model, stuck) = try await focusModeWithTwoPeers()
    defer { model.shutdown() }
    stuckPeerFails(.refused, stuck: stuck, system: system)
    model.perform(.restore)
    await settleFocusRestore(model, system: system)
    try #require(system.windows.first { $0.id == stuck }?.isMinimized == true)

    system.failedRestoreWindowIDs = []
    try system.setMinimized(false, for: stuck)
    await settleFocusRestore(model, system: system)
    #expect(fillsDisplay(system.windows, system: system), "\(system.windows.map(\.frame))")
    let requests = system.restoreRequests.count
    model.tileCurrentDisplay()
    await settleFocusRestore(model, system: system)
    #expect(system.restoreRequests.count == requests)
    #expect(model.lastActionFeedback?.kind == .success, "\(feedbackText(model))")
}

/// A peer that closes while it is outstanding is not reported or restored.
@Test(.appTestApplication, .timeLimit(.minutes(5))) @MainActor
func aClosedFocusPeerIsNoLongerReported() async throws {
    let (system, model, stuck) = try await focusModeWithTwoPeers()
    defer { model.shutdown() }
    stuckPeerFails(.refused, stuck: stuck, system: system)
    model.perform(.restore)
    await settleFocusRestore(model, system: system)

    system.windows.removeAll { $0.id == stuck }
    system.eventHandler?(WindowSystemEvent(kind: .destroyed, windowID: stuck, processIdentifier: 44))
    await settleFocusRestore(model, system: system)
    let requests = system.restoreRequests.count
    model.tileCurrentDisplay()
    await settleFocusRestore(model, system: system)
    #expect(system.restoreRequests.count == requests)
    #expect(model.lastActionFeedback?.kind == .success, "\(feedbackText(model))")
    #expect(fillsDisplay(system.windows, system: system), "\(system.windows.map(\.frame))")
}

/// A quit application's minimized window may never send a destroyed
/// notification. Its termination ends the record, so Repair stops asking.
@Test(.appTestApplication, .timeLimit(.minutes(5))) @MainActor
func aFocusPeerOfAQuitApplicationIsNoLongerReported() async throws {
    let (system, model, stuck) = try await focusModeWithTwoPeers()
    defer { model.shutdown() }
    stuckPeerFails(.refused, stuck: stuck, system: system)
    model.perform(.restore)
    await settleFocusRestore(model, system: system)

    // No destroyed notification arrives. A stale read can still return the
    // window as minimized after its process quit.
    model.handleApplicationTermination(processIdentifier: 44)
    await settleFocusRestore(model, system: system)
    let requests = system.restoreRequests.count
    model.tileCurrentDisplay()
    await settleFocusRestore(model, system: system)
    #expect(system.restoreRequests.count == requests)
    #expect(model.lastActionFeedback?.message != repairPartial, "\(feedbackText(model))")
}

/// The record belongs to Adaptive. Leaving Adaptive ends it, so Repair after
/// a return to Adaptive does not restore or report the peer.
@Test(.appTestApplication, .timeLimit(.minutes(5)), arguments: [LayoutMode.manual, .tabbed]) @MainActor
func leavingAdaptiveForgetsAnUnreturnedFocusPeer(mode: LayoutMode) async throws {
    let (system, model, stuck) = try await focusModeWithTwoPeers()
    defer { model.shutdown() }
    stuckPeerFails(.refused, stuck: stuck, system: system)
    model.perform(.restore)
    await settleFocusRestore(model, system: system)

    model.setActiveMode(mode)
    await settleFocusRestore(model, system: system)
    model.setActiveMode(.bento)
    await settleFocusRestore(model, system: system)
    #expect(system.restoreRequests.filter { $0 == stuck }.count == 1)
    #expect(model.lastActionFeedback?.message != repairPartial, "\(feedbackText(model))")
}

/// A Saved Layout apply resets Focus mode state, and the record with it.
@Test(.appTestApplication, .timeLimit(.minutes(5))) @MainActor
func aSavedLayoutApplyForgetsAnUnreturnedFocusPeer() async throws {
    let (system, model, stuck) = try await focusModeWithTwoPeers(observesDesktops: true)
    defer { model.shutdown() }
    stuckPeerFails(.refused, stuck: stuck, system: system)
    model.perform(.restore)
    await settleFocusRestore(model, system: system)

    let applier = try #require(model.savedLayoutApplier)
    applier.observesKeyboard = false
    let document = SavedLayoutDocument(name: "Pair", mode: .bento,
        layout: .split(axis: .vertical, ratios: [0.5, 0.5], children: [.slot("left"), .slot("right")]),
        slots: [.init(id: "left", bundleID: "com.example.Test"), .init(id: "right", bundleID: "com.example.Kept")])
    let result = await system.drive { await applier.apply(document) }
    try #require(result?.placed == 2, "\(String(describing: result))")
    await settleFocusRestore(model, system: system)
    model.tileCurrentDisplay()
    await settleFocusRestore(model, system: system)
    #expect(system.restoreRequests.filter { $0 == stuck }.count == 1)
    #expect(model.lastActionFeedback?.message != repairPartial, "\(feedbackText(model))")
}

/// At the end of Restore's wait, a peer that is not minimized is not stuck:
/// it may be on another display or Space. Restore does not report it.
@Test(.appTestApplication, .timeLimit(.minutes(5))) @MainActor
func aFocusPeerThatIsNotMinimizedAtTheDeadlineIsNotReported() async throws {
    let (system, model, stuck) = try await focusModeWithTwoPeers()
    defer { model.shutdown() }
    stuckPeerFails(.neverReturns, stuck: stuck, system: system)
    model.perform(.restore)
    let index = try #require(system.windows.firstIndex { $0.id == stuck })
    // The application shows the window, but it is not eligible here.
    system.windows[index].isMinimized = false
    system.windows[index].isHidden = true
    await settleFocusRestore(model, system: system)
    #expect(model.lastActionFeedback == .success("Layout restored"), "\(feedbackText(model))")
}

/// A mode command that chooses Adaptive repairs the desktop. It cancels
/// Restore's wait first, and the peer that wait was still waiting for must
/// stay known, so this Repair tries it again and reports it.
@Test(.appTestApplication, .timeLimit(.minutes(5))) @MainActor
func choosingAdaptiveDuringRestoresWaitTriesTheMissingPeerAgain() async throws {
    let (system, model, stuck) = try await focusModeWithTwoPeers()
    defer { model.shutdown() }
    stuckPeerFails(.neverReturns, stuck: stuck, system: system)
    model.perform(.restore)
    await system.advance(by: .milliseconds(200))
    model.setActiveMode(.bento)
    #expect(await system.waitFor(timeout: .seconds(6)) { model.lastActionFeedback?.message == repairPartial },
            "\(feedbackText(model))")
    #expect(system.restoreRequests.filter { $0 == stuck }.count == 2)
    expectRepairPartial(model)
}

/// A stopped or hung application cannot answer Accessibility reads or
/// writes, so its minimized peer is unreadable. WindowServer still shows it
/// off screen. Restore names the application from the process recorded at
/// Focus entry, and Repair warns instead of reporting "Layout applied".
@Test(.appTestApplication, .timeLimit(.minutes(5)), arguments: FocusPeerFailure.allCases) @MainActor
func aFocusPeerWhoseApplicationDoesNotAnswerIsNamedAndReported(failure: FocusPeerFailure) async throws {
    let (system, model, stuck) = try await focusModeWithTwoPeers()
    defer { model.shutdown() }
    model.applicationNameForProcess = { $0.processIdentifier == 44 ? "Stopped Fixture" : nil }
    let notResponding = "Stopped Fixture is not responding, so its window did not come back. "
        + "Use Repair Layout when it responds."
    // Under the "Use Repair Layout" title the detail does not repeat it.
    let refusedNotResponding = "Stopped Fixture is not responding, so its window did not come back. "
        + "Try again when it responds."
    // The application stops: every read of its window fails from now on,
    // and its calls wait out their timeouts, which holds it as unresponsive.
    system.unreadableAfterWrites[stuck] = 0
    system.unresponsiveWindowIDs = [stuck]
    stuckPeerFails(failure, stuck: stuck, system: system)

    model.perform(.restore)
    if failure == .refused {
        #expect(model.lastActionFeedback == .failure(title: "Use Repair Layout", detail: refusedNotResponding),
                "\(feedbackText(model))")
    }
    await settleFocusRestore(model, system: system)
    let restoreResult: ResultPillFeedback = failure == .refused
        ? .failure(title: "Use Repair Layout", detail: refusedNotResponding)
        : .layoutResult(title: "Layout partly restored", detail: notResponding, kind: .warning, actions: [])
    #expect(model.lastActionFeedback == restoreResult, "\(feedbackText(model))")

    let reads = system.windowSnapshotRequests.count
    model.tileCurrentDisplay()
    #expect(await system.waitFor(timeout: .seconds(6)) { model.lastActionFeedback?.message == repairPartial },
            "\(feedbackText(model))")
    // A held application is not asked again: each read would wait out a timeout.
    #expect(!system.windowSnapshotRequests.dropFirst(reads).contains { $0.contains(stuck) })
    await settleFocusRestore(model, system: system)
    #expect(model.lastActionFeedback == .layoutResult(title: repairPartial, detail: notResponding,
                                                      kind: .warning, actions: []), "\(feedbackText(model))")
    #expect(system.windows.first { $0.id == stuck }?.isMinimized == true)

    // The application answers again: Repair brings the peer back.
    system.unreadableAfterWrites = [:]
    system.unresponsiveWindowIDs = []
    system.failedRestoreWindowIDs = []
    system.slowRestoreIDs = []
    model.tileCurrentDisplay()
    #expect(await system.waitFor(timeout: .seconds(6)) { model.lastActionFeedback?.kind == .success },
            "\(feedbackText(model))")
    await settleFocusRestore(model, system: system)
    #expect(system.windows.allSatisfy { !$0.isMinimized })
    #expect(fillsDisplay(system.windows, system: system), "\(system.windows.map(\.frame))")
}

/// An unreadable peer that WindowServer shows on screen is back, even while
/// its application does not answer. Repair does not report it.
@Test(.appTestApplication, .timeLimit(.minutes(5))) @MainActor
func anUnreadablePeerOnScreenIsNotReported() async throws {
    let (system, model, stuck) = try await focusModeWithTwoPeers()
    defer { model.shutdown() }
    stuckPeerFails(.refused, stuck: stuck, system: system)
    model.perform(.restore)
    await settleFocusRestore(model, system: system)
    // The window came back without BetterTile, and its application then
    // stopped answering.
    let index = try #require(system.windows.firstIndex { $0.id == stuck })
    system.windows[index].isMinimized = false
    system.unreadableAfterWrites[stuck] = 0
    system.unresponsiveWindowIDs = [stuck]
    // The inventory sweep cannot read the hung application either.
    system.applicationHoldsUntil[44] = 1_000_000
    system.failedRestoreWindowIDs = []
    let before = model.lastActionFeedback
    model.tileCurrentDisplay()
    // The held application keeps recovery passes running, so wait for the
    // Repair result rather than for an idle model.
    #expect(await system.waitFor(timeout: .seconds(6)) { model.lastActionFeedback != before },
            "\(feedbackText(model))")
    #expect(model.lastActionFeedback?.message != repairPartial, "\(feedbackText(model))")
    #expect(model.lastActionFeedback?.kind == .success, "\(feedbackText(model))")
}

/// A peer the user moved to another Space, or that opened in its own
/// full-screen Space, cannot be read and is off screen, like a hung peer.
/// Its application still answers, so it is not reported, and Repair leaves
/// it alone.
@Test(.appTestApplication, .timeLimit(.minutes(5)), arguments: [false, true]) @MainActor
func aFocusPeerOnAnotherSpaceIsNotReported(fullScreen: Bool) async throws {
    let (system, model, stuck) = try await focusModeWithTwoPeers(observesDesktops: true)
    defer { model.shutdown() }
    stuckPeerFails(.neverReturns, stuck: stuck, system: system)
    model.perform(.restore)
    // The window returns on another Space. Like the adapter, the fake then
    // hides it from Accessibility reads, and WindowServer shows it off screen.
    let other = NativeSpaceID(rawValue: fullScreen ? 3 : 2)
    system.simulatesNativeClassification = true
    system.desktopObservation?.knownSpacesByDisplay[system.mainDisplay.id]?.insert(other)
    if fullScreen { system.desktopObservation?.fullscreenSpaceIDs.insert(other) }
    system.desktopObservation?.windowMembership[stuck] = [other]
    let index = try #require(system.windows.firstIndex { $0.id == stuck })
    system.windows[index].isMinimized = false
    await settleFocusRestore(model, system: system)
    #expect(model.lastActionFeedback == .success("Layout restored"), "\(feedbackText(model))")

    let requests = system.restoreRequests.filter { $0 == stuck }.count
    model.tileCurrentDisplay()
    await settleFocusRestore(model, system: system)
    #expect(model.lastActionFeedback?.kind == .success, "\(feedbackText(model))")
    #expect(system.restoreRequests.filter { $0 == stuck }.count == requests)
}

/// A process number can be reused after a missed termination. The name
/// lookup must then not name the other application.
@Test(.appTestApplication) @MainActor func aReusedProcessNumberDoesNotNameAnotherApplication() async throws {
    _ = NSApplication.shared
    let model = makeModel(system: makeManualWindowSystem())
    defer { model.shutdown() }
    let current = ProcessInfo.processInfo.processIdentifier
    let running = try #require(RunningApplicationLookup.application(processIdentifier: current))
    #expect(model.applicationNameForProcess(.init(processIdentifier: current,
        bundleIdentifier: "com.example.Other", knowsBundleIdentifier: true)) == nil)
    #expect(model.applicationNameForProcess(.init(processIdentifier: current,
        bundleIdentifier: running.bundleIdentifier, knowsBundleIdentifier: true)) != nil)
    #expect(model.applicationNameForProcess(.init(processIdentifier: current)) != nil)
}

/// The adapter holds a stalled application for only 2 s. A later sweep
/// keeps it in inventory backoff without messaging it, and a targeted read
/// of a peer whose element was dropped runs such a sweep, so it fails
/// without a call and the hold is not renewed. The peer must still count as
/// not answering, so Repair warns instead of reporting "Layout applied".
@Test(.appTestApplication, .timeLimit(.minutes(5))) @MainActor
func aStoppedPeerInInventoryBackoffIsReportedAfterItsCallHoldExpires() async throws {
    let (system, model, stuck) = try await focusModeWithTwoPeers(modelsAdapterGate: true)
    defer { model.shutdown() }
    model.applicationNameForProcess = { $0.processIdentifier == 44 ? "Stopped Fixture" : nil }
    // The application stops: each call to it waits out a 0.35 s timeout.
    system.adapterInventoryTimeouts = [44: 0.35]
    system.failedRestoreWindowIDs = [stuck]
    model.perform(.restore)
    #expect(model.lastActionFeedback == .failure(title: "Use Repair Layout", detail:
        "Stopped Fixture is not responding, so its window did not come back. Try again when it responds."),
        "\(feedbackText(model))")
    await settleFocusRestore(model, system: system)

    // A timed-out write dropped the element. Several stalls put the
    // application in a long inventory backoff; the 2 s call hold then ends.
    system.droppedElementWindowIDs = [stuck]
    system.recordAdapterStalls(44, count: 3)
    await system.advance(by: .milliseconds(2500))
    _ = try system.visibleWindows()
    try #require(!system.isApplicationUnresponsive(for: stuck))
    try #require(system.unreadableApplicationWindowIDs.contains(stuck))

    model.tileCurrentDisplay()
    #expect(await system.waitFor(timeout: .seconds(6)) { model.lastActionFeedback?.message == repairPartial },
            "\(feedbackText(model))")
    #expect(model.lastActionFeedback == .layoutResult(title: repairPartial, detail:
        "Stopped Fixture is not responding, so its window did not come back. Use Repair Layout when it responds.",
        kind: .warning, actions: []), "\(feedbackText(model))")
}

/// An unreadable peer whose application still answers is not evidence of a
/// stuck window, even when macOS refused its restore. Without a desktop
/// observation, as with private APIs off, it may simply be on another Space.
/// With an observation that places it on another Space, it leaves the record.
@Test(.appTestApplication, .timeLimit(.minutes(5)), arguments: [false, true]) @MainActor
func aRefusedUnreadablePeerOfAnAnsweringApplicationIsNotReported(observesDesktops: Bool) async throws {
    let (system, model, stuck) = try await focusModeWithTwoPeers(observesDesktops: observesDesktops)
    defer { model.shutdown() }
    system.failedRestoreWindowIDs = [stuck]
    if observesDesktops {
        let other = NativeSpaceID(rawValue: 2)
        system.simulatesNativeClassification = true
        system.desktopObservation?.knownSpacesByDisplay[system.mainDisplay.id]?.insert(other)
        system.desktopObservation?.windowMembership[stuck] = [other]
    } else {
        // The read cannot see the window, and nothing says why.
        system.unreadableAfterWrites[stuck] = 0
    }
    model.perform(.restore)
    #expect(model.lastActionFeedback == .success("Layout restored"), "\(feedbackText(model))")
    await settleFocusRestore(model, system: system)
    #expect(model.lastActionFeedback == .success("Layout restored"), "\(feedbackText(model))")
    model.tileCurrentDisplay()
    await settleFocusRestore(model, system: system)
    #expect(model.lastActionFeedback?.kind == .success, "\(feedbackText(model))")
}

@Test func aNotRespondingFocusPeerMessageNamesTheApplication() {
    let message = { (names: [String], count: Int) in
        BetterTileModel.notRespondingFocusPeersMessage(names: names, windowCount: count)
    }
    #expect(message(["TextEdit"], 1)
        == "TextEdit is not responding, so its window did not come back. Use Repair Layout when it responds.")
    #expect(message(["TextEdit"], 2)
        == "TextEdit is not responding, so its windows did not come back. Use Repair Layout when it responds.")
    #expect(message(["TextEdit", "Terminal"], 2) == "TextEdit and Terminal are not responding, "
        + "so their windows did not come back. Use Repair Layout when they respond.")
    #expect(message(["A", "B", "C"], 3) == "A, B, and 1 more app are not responding, "
        + "so their windows did not come back. Use Repair Layout when they respond.")
    #expect(message(["A", "B", "C", "D"], 4) == "A, B, and 2 more apps are not responding, "
        + "so their windows did not come back. Use Repair Layout when they respond.")
    #expect(message([], 1)
        == "An application is not responding, so its window did not come back. Use Repair Layout when it responds.")
    #expect(BetterTileModel.notRespondingFocusPeersMessage(names: [], windowCount: 2, applicationCount: 2)
        == "Some applications are not responding, so their windows did not come back. "
            + "Use Repair Layout when they respond.")
    #expect(BetterTileModel.notRespondingFocusPeersMessage(names: ["TextEdit"], windowCount: 1, remedy: .tryAgain)
        == "TextEdit is not responding, so its window did not come back. Try again when it responds.")
}

@Test func anUnreturnedFocusPeerMessageNamesEachApplicationOnce() {
    let message = { (names: [String], count: Int) in
        BetterTileModel.unreturnedFocusPeersMessage(names: names, windowCount: count)
    }
    #expect(message([], 1) == "A window stayed minimized.")
    #expect(message([], 2) == "2 windows stayed minimized.")
    #expect(message(["TextEdit"], 1) == "The TextEdit window stayed minimized.")
    #expect(message(["TextEdit"], 2) == "The TextEdit windows stayed minimized.")
    #expect(message(["TextEdit", "Terminal"], 2) == "The TextEdit and Terminal windows stayed minimized.")
    #expect(message(["TextEdit", "Terminal", "Finder"], 3)
        == "The TextEdit, Terminal, and 1 more windows stayed minimized.")
    let away = { (names: [String], count: Int) in
        BetterTileModel.unreturnedFocusPeersMessage(names: names, windowCount: count, stillAway: true)
    }
    #expect(away(["TextEdit"], 1) == "The TextEdit window has not come back yet.")
    #expect(away(["TextEdit", "Terminal"], 2) == "The TextEdit and Terminal windows have not come back yet.")
    #expect(away([], 1) == "A window has not come back yet.")
}

@MainActor private func expectRepairPartial(_ model: BetterTileModel, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(model.lastActionFeedback == .layoutResult(title: repairPartial,
        detail: stuckMinimized + " Restore it from the Dock.", kind: .warning, actions: []),
        "\(feedbackText(model))", sourceLocation: sourceLocation)
}

@MainActor private func stuckPeerFails(_ failure: FocusPeerFailure, stuck: WindowID, system: FakeAppWindowSystem) {
    switch failure {
    case .refused: system.failedRestoreWindowIDs = [stuck]
    case .neverReturns: system.slowRestoreIDs = [stuck]
    }
}

@MainActor private func feedbackText(_ model: BetterTileModel) -> String {
    guard let feedback = model.lastActionFeedback else { return "" }
    return [feedback.message, feedback.detail].compactMap { $0 }.joined(separator: " ")
}

@MainActor private func fillsDisplay(_ windows: [WindowSnapshot], system: FakeAppWindowSystem) -> Bool {
    let display = system.mainDisplay.visibleFrame
    let area = windows.map { $0.frame.size.width * $0.frame.size.height }.reduce(0, +)
    let frames = Dictionary(uniqueKeysWithValues: windows.map { ($0.id, $0.frame) })
    return area >= display.size.width * display.size.height * 0.98
        && BentoLayoutVerifier.overlappingWindowIDs(frames).isEmpty
}

/// Drive the policy clock past two serial 1.5 s peer waits, Restore's and
/// then Repair's, and on until no event pass or settlement is left.
@MainActor private func settleFocusRestore(_ model: BetterTileModel, system: FakeAppWindowSystem) async {
    await system.advance(by: .milliseconds(3500))
    for _ in 0..<12 {
        await system.advance(by: .milliseconds(350))
        await system.joinWindowEvent(on: model)
        for task in Array(model.settlementTasks.values) { await system.joinSettlement(task, on: model) }
        guard model.windowEventTask == nil && model.settlementTasks.isEmpty else { continue }
        await system.advance(by: .milliseconds(50))
        if model.windowEventTask == nil && model.settlementTasks.isEmpty { return }
    }
    #expect(model.windowEventTask == nil && model.settlementTasks.isEmpty)
}

/// Three tiled windows on an Adaptive desktop, with the first in Focus mode
/// and its two peers minimized. Returns the peer the test makes fail.
/// - Parameter observesDesktops: Gives the desktop a Space, as Saved Layouts need.
@MainActor private func focusModeWithTwoPeers(
    observesDesktops: Bool = false, modelsAdapterGate: Bool = false
) async throws -> (FakeAppWindowSystem, BetterTileModel, WindowID) {
    _ = NSApplication.shared
    let system = makeManualWindowSystem(drivingPolicyDeadlines: true)
    for (index, name) in ["Kept", "Stuck"].enumerated() {
        system.windows.append(WindowSnapshot(id: WindowID(rawValue: name.lowercased()),
            processIdentifier: Int32(43 + index), bundleIdentifier: name == "Stuck" ? stuckName : "com.example.\(name)",
            frame: BTRect(x: 0, y: 0, width: 200, height: 300), displayID: system.mainDisplay.id))
    }
    if modelsAdapterGate {
        // Sweeps run the adapter's own inventory gate. Every application
        // answers until a test gives one a timeout.
        system.adapterInventoryTimeouts = [:]
        system.adapterGateReportsUnresponsive = true
    }
    if observesDesktops {
        let space = NativeSpaceID(rawValue: 1)
        system.desktopObservation = NativeDesktopObservation(
            currentSpaceByDisplay: [system.mainDisplay.id: space],
            knownSpacesByDisplay: [system.mainDisplay.id: [space]],
            windowMembership: Dictionary(uniqueKeysWithValues: system.windows.map { ($0.id, [space]) }))
    }
    system.emitsMinimizationEvents = true
    let model = makeModel(system: system)
    // Fake process numbers can belong to real processes on this Mac. Name
    // applications from their bundle unless a test names a process.
    model.applicationNameForProcess = { _ in nil }
    model.configuration.bentoInnerGap = 0
    model.setActiveMode(.bento)
    try #require(await system.waitFor { system.frameWriteCounts.count == system.windows.count })
    await settleFocusRestore(model, system: system)
    try #require(fillsDisplay(system.windows, system: system))
    system.focusedID = system.windows[0].id
    model.perform(.maximize)
    try #require(system.windows.dropFirst().allSatisfy { $0.isMinimized })
    await settleFocusRestore(model, system: system)
    return (system, model, WindowID(rawValue: "stuck"))
}

/// WindowServer state as the Accessibility adapter reads it: a window it
/// knows is on screen unless it is minimized, hidden or off screen. It asks
/// no application, so it answers for an unreadable window too.
extension FakeAppWindowSystem: WindowStackReading {
    func onScreenStack(labeling ids: Set<WindowID>) -> [SeamStackEntry]? { nil }

    func windowServerPresence(for ids: Set<WindowID>) -> [WindowID: WindowServerPresence]? {
        Dictionary(uniqueKeysWithValues: windows.filter { ids.contains($0.id) }.map { window in
            (window.id, WindowServerPresence(
                isOnScreen: !window.isMinimized && !window.isHidden && !offscreenWindowIDs.contains(window.id)
                    // WindowServer lists a window on another Space as off screen.
                    && desktopObservation.map { !$0.windowsOnCurrentSpaces([window]).isEmpty } != false,
                processIdentifier: window.processIdentifier))
        })
    }
}
