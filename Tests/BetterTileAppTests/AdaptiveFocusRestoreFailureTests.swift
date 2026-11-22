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
    observesDesktops: Bool = false
) async throws -> (FakeAppWindowSystem, BetterTileModel, WindowID) {
    _ = NSApplication.shared
    let system = makeManualWindowSystem(drivingPolicyDeadlines: true)
    for (index, name) in ["Kept", "Stuck"].enumerated() {
        system.windows.append(WindowSnapshot(id: WindowID(rawValue: name.lowercased()),
            processIdentifier: Int32(43 + index), bundleIdentifier: name == "Stuck" ? stuckName : "com.example.\(name)",
            frame: BTRect(x: 0, y: 0, width: 200, height: 300), displayID: system.mainDisplay.id))
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
