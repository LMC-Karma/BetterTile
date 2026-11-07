import AppKit
import Foundation
import Testing
@testable import BetterTileApp
@testable import BetterTileCore

private func window(_ id: String, pid: Int32, x: Double, width: Double = 500, display: DisplayID,
                    minimumWidth: Double = 120) -> WindowSnapshot {
    WindowSnapshot(id: WindowID(rawValue: id), processIdentifier: pid, bundleIdentifier: "com.example.\(id)",
                   frame: BTRect(x: x, y: 0, width: width, height: 800), displayID: display,
                   constraints: WindowConstraints(minimumSize: BTSize(width: minimumWidth, height: 80), minimumSizeSource: .hint))
}

enum AdaptiveDeparture: String, CaseIterable, Sendable {
    /// Closed, and macOS sends a destroyed event for it.
    case closedWithEvent
    /// Closed, but no destroyed event arrives (the window just disappears).
    case closedWithoutEvent
    /// Closed, but the app keeps the window alive off screen: macOS still
    /// reports it on this desktop.
    case closedButStillOnDesktop
    /// Moved to another desktop while the user stays here.
    case movedToOtherDesktop
    /// The user takes the window along to another desktop, then comes back.
    case takenAlongThenReturn
    /// Closed with an event, and a desktop-change notification arrives right
    /// away (macOS can switch desktops when focus moves to the app's window
    /// on another desktop, or post the notification on app activation).
    case closedThenSpaceNotification

    /// Measured on the fixture clock: 0.12 s with a destroyed event, about
    /// 0.45 s after the notification, about 0.9 s for an inferred absence,
    /// about 1.1 s after a return. A window that macOS still reports on this
    /// desktop waits out the longer membership budget, about 1.6 s.
    var fillDeadline: Duration {
        self == .closedButStillOnDesktop ? .seconds(2) : .milliseconds(1_500)
    }
}

/// Two Adaptive halves; one window leaves. The other fills the work area on
/// its own, without Repair Layout or another user action.
@Test(.appTestApplication, arguments: AdaptiveDeparture.allCases) @MainActor
func adaptiveFillsTheSpaceWhenAWindowLeaves(_ departure: AdaptiveDeparture) async throws {
    let (system, model) = try await makeTwoPaneAdaptiveFixture()
    defer { model.shutdown() }
    let d = system.mainDisplay.id
    let a = NativeSpaceID(rawValue: 1), b = NativeSpaceID(rawValue: 2)
    let leaving = try #require(system.windows.first { $0.id == right })

    switch departure {
    case .closedWithEvent:
        system.windows.removeAll { $0.id == right }
        system.desktopObservation?.windowMembership[right] = nil
        system.eventHandler?(WindowSystemEvent(kind: .destroyed, windowID: right, processIdentifier: 42))
    case .closedThenSpaceNotification:
        system.windows.removeAll { $0.id == right }
        system.desktopObservation?.windowMembership[right] = nil
        system.eventHandler?(WindowSystemEvent(kind: .destroyed, windowID: right, processIdentifier: 42))
        model.beginActiveSpaceStabilization()
    case .closedWithoutEvent:
        system.windows.removeAll { $0.id == right }
        system.desktopObservation?.windowMembership[right] = nil
        system.eventHandler?(WindowSystemEvent(kind: .focused, windowID: left, processIdentifier: 41))
    case .closedButStillOnDesktop:
        system.windows.removeAll { $0.id == right }
        system.eventHandler?(WindowSystemEvent(kind: .focused, windowID: left, processIdentifier: 41))
    case .movedToOtherDesktop:
        system.windows.removeAll { $0.id == right }
        system.desktopObservation?.windowMembership[right] = [b]
        system.eventHandler?(WindowSystemEvent(kind: .focused, windowID: left, processIdentifier: 41))
    case .takenAlongThenReturn:
        system.desktopObservation?.windowMembership[right] = [b]
        system.desktopObservation?.currentSpaceByDisplay[d] = b
        let remaining = try #require(system.windows.first { $0.id == left })
        system.windows = [leaving]
        system.focusedID = right
        model.beginActiveSpaceStabilization()
        try #require(await system.waitFor { !model.isStabilizingSpace })
        await system.advance(by: .milliseconds(500))
        system.desktopObservation?.currentSpaceByDisplay[d] = a
        system.windows = [remaining]
        system.focusedID = left
        model.beginActiveSpaceStabilization()
        try #require(await system.waitFor { !model.isStabilizingSpace })
    }
    let filled = await system.waitFor(timeout: departure.fillDeadline) {
        system.windows.first { $0.id == left }?.frame == system.mainDisplay.visibleFrame
    }
    #expect(filled, "\(departure): Left stayed at \(String(describing: system.windows.first { $0.id == left }?.frame))")
    if departure == .closedButStillOnDesktop {
        // The window server keeps the closed window, but not on screen, so
        // only its desktop membership remains.
        #expect(!system.unreadOnScreenWindowIDs.contains(right))
        #expect(system.desktopObservation?.exclusiveWindowIDs(on: d).contains(right) == true)
    }
}

private let left = WindowID(rawValue: "Left"), right = WindowID(rawValue: "Right")

/// Two Adaptive halves, Left and Right, on desktop 1 of desktops 1 and 2.
@MainActor
private func makeTwoPaneAdaptiveFixture() async throws -> (FakeAppWindowSystem, BetterTileModel) {
    _ = NSApplication.shared
    let system = makeManualWindowSystem()
    let d = system.mainDisplay.id
    let a = NativeSpaceID(rawValue: 1), b = NativeSpaceID(rawValue: 2)
    system.windows = [window("Left", pid: 41, x: 0, display: d), window("Right", pid: 42, x: 500, display: d)]
    system.desktopObservation = NativeDesktopObservation(
        currentSpaceByDisplay: [d: a], knownSpacesByDisplay: [d: [a, b]],
        windowMembership: Dictionary(uniqueKeysWithValues: system.windows.map { ($0.id, [a]) }))
    let model = makeModel(system: system)
    model.configuration.singleWindowPlacement = .maximize
    system.focusedID = left
    model.setActiveMode(.bento)
    try #require(await system.waitFor { model.activeMode(for: d) == .bento })
    await system.advance(by: .milliseconds(500))
    try #require(system.windows.first { $0.id == left }?.frame != system.mainDisplay.visibleFrame,
                 "The fixture must start with two panes")
    return (system, model)
}

@MainActor
private func storedSession(_ model: BetterTileModel, _ display: DisplayID) throws -> LayoutSession {
    let store = Mirror(reflecting: model).children.first { $0.label?.hasSuffix("sessionStore") == true }?.value as? LayoutSessionStore
    return try #require(store?.session(for: display))
}

@MainActor
private func retainedDestroyedEvidence(_ model: BetterTileModel) -> Set<WindowID> {
    Mirror(reflecting: model).children.first { $0.label?.hasSuffix("confirmedGoneWindowIDs") == true }?.value
        as? Set<WindowID> ?? []
}

/// Accessibility briefly omits a live window, as when its application returns
/// no window or a quick `cannotComplete` that starts no hold. The window server
/// still shows it on screen and on this desktop. Through more ordinary sweeps
/// than any absence budget, the window keeps its pane, nothing moves, and when
/// it is readable again the layout is unchanged.
@Test(.appTestApplication) @MainActor
func aVisibleWindowThatAccessibilityOmitsKeepsItsAdaptivePane() async throws {
    let (system, model) = try await makeTwoPaneAdaptiveFixture()
    defer { model.shutdown() }
    let d = system.mainDisplay.id
    let frames = system.windows.map(\.frame)
    let tree = try storedSession(model, d).bentoState
    let writes = system.frameWriteCounts
    try #require(tree.root?.windowIDs.count == 2)

    system.offscreenWindowIDs = [right]
    system.omittedButOnScreenWindowIDs = [right]
    let sweeps = system.completeSweepCount
    for _ in 0..<8 {
        model.handleApplicationTopologyChange()
        await system.advance(by: .milliseconds(400))
    }
    let budget = try storedSession(model, d).presence.toleratedMembershipOnlyAbsences
    try #require(system.completeSweepCount - sweeps > budget + 1,
                 "The omission must last more than the membership budget of ordinary sweeps")
    #expect(system.unreadOnScreenWindowIDs.contains(right))
    #expect(try storedSession(model, d).bentoState == tree, "the omitted window keeps its pane and ratios")
    #expect(system.windows.map(\.frame) == frames, "the neighbour must not fill the screen")

    system.offscreenWindowIDs.removeAll()
    system.omittedButOnScreenWindowIDs.removeAll()
    model.handleApplicationTopologyChange()
    await system.advance(by: .milliseconds(500))
    #expect(try storedSession(model, d).bentoState == tree)
    #expect(system.windows.map(\.frame) == frames)
    #expect(system.frameWriteCounts == writes, "no single-window placement and no relayout")
}

/// Accessibility omits Right while the window server shows it on screen, so
/// Right keeps its pane and has no absence tally. Then Right closes without a
/// destroyed event: its application keeps the window object off screen, so
/// Accessibility still omits it and the visible window set does not change.
/// The watchdog's complete sweep loses the on-screen evidence. The watchdog
/// must reconcile again, so the ordinary confirmation budget starts and Left
/// fills. Another complete read before the watchdog must not hide the loss.
@Test(.appTestApplication) @MainActor
func losingOnScreenEvidenceStartsTheAbsenceBudgetFromTheWatchdog() async throws {
    let (system, model) = try await makeTwoPaneAdaptiveFixture()
    defer { model.shutdown() }
    let d = system.mainDisplay.id
    system.offscreenWindowIDs = [right]
    system.omittedButOnScreenWindowIDs = [right]
    for _ in 0..<3 {
        model.handleApplicationTopologyChange()
        await system.advance(by: .milliseconds(400))
    }
    await system.advance(by: .seconds(2))
    try #require(system.unreadOnScreenWindowIDs.contains(right))
    try #require(try storedSession(model, d).bentoState.root?.windowIDs.count == 2)
    try #require(try storedSession(model, d).presence.pending.isEmpty, "protection leaves no absence tally")

    // Right closes; the application keeps it off screen. No event arrives.
    system.omittedButOnScreenWindowIDs.removeAll()
    try #require(system.desktopObservation?.exclusiveWindowIDs(on: d).contains(right) == true)
    // Another complete read updates the adapter's evidence first.
    _ = try system.visibleWindows()
    #expect(system.unreadOnScreenWindowIDs.isEmpty)
    model.watchdog()
    #expect(system.unreadOnScreenWindowIDs.isEmpty, "the watchdog's sweep has no on-screen evidence")
    // The watchdog reconciles at once: the ordinary budget starts, and Right
    // still has its pane.
    #expect(try storedSession(model, d).presence.pending[right] == 1)
    #expect(try storedSession(model, d).bentoState.root?.windowIDs.count == 2)

    // Repeated watchdog ticks must not leave Right protected without a tally.
    var filled = false
    for _ in 0..<6 where !filled {
        await system.advance(by: .milliseconds(400))
        model.watchdog()
        filled = system.windows.first { $0.id == left }?.frame == system.mainDisplay.visibleFrame
    }
    if !filled {
        filled = await system.waitFor(timeout: .seconds(2)) {
            system.windows.first { $0.id == left }?.frame == system.mainDisplay.visibleFrame
        }
    }
    #expect(filled, "Left stayed at \(String(describing: system.windows.first { $0.id == left }?.frame))")
    #expect(try storedSession(model, d).bentoState.root?.windowIDs == [left])
}

/// Accessibility omits Right while the window server shows it on screen, so
/// Right keeps its pane on the main display. Then Right moves to the current
/// desktop of a second display. Accessibility still omits it, the window
/// server still shows it on screen, and no event arrives. Only its desktop
/// membership changes. The watchdog must see that Right lost the protection
/// that the reducer used, start the ordinary absence budget, and fill Left.
@Test(.appTestApplication) @MainActor
func aVisibleWindowThatLeavesForAnotherDisplayStartsTheAbsenceBudgetFromTheWatchdog() async throws {
    let (system, model) = try await makeTwoPaneAdaptiveFixture()
    defer { model.shutdown() }
    let d = system.mainDisplay.id
    let side = DisplaySnapshot(
        id: DisplayID(rawValue: "side"),
        frame: BTRect(x: 1000, y: 0, width: 1000, height: 800),
        visibleFrame: BTRect(x: 1000, y: 0, width: 1000, height: 800)
    )
    let c = NativeSpaceID(rawValue: 3)
    system.availableDisplays.append(side)
    system.desktopObservation?.currentSpaceByDisplay[side.id] = c
    system.desktopObservation?.knownSpacesByDisplay[side.id] = [c]
    system.offscreenWindowIDs = [right]
    system.omittedButOnScreenWindowIDs = [right]
    for _ in 0..<3 {
        model.handleApplicationTopologyChange()
        await system.advance(by: .milliseconds(400))
    }
    await system.advance(by: .seconds(2))
    try #require(system.unreadOnScreenWindowIDs.contains(right))
    try #require(try storedSession(model, d).bentoState.root?.windowIDs.count == 2)
    try #require(try storedSession(model, d).presence.pending.isEmpty, "protection leaves no absence tally")

    // Right moves to the side display's current desktop. It stays on screen
    // and unread, and no event arrives.
    system.desktopObservation?.windowMembership[right] = [c]
    try #require(system.desktopObservation?.exclusiveWindowIDs(on: d).contains(right) == false)
    model.watchdog()
    #expect(system.unreadOnScreenWindowIDs.contains(right), "the on-screen evidence stays")
    #expect(try storedSession(model, d).presence.pending[right] == 1, "the ordinary budget starts")
    #expect(try storedSession(model, d).bentoState.root?.windowIDs.count == 2)

    var filled = false
    for _ in 0..<6 where !filled {
        await system.advance(by: .milliseconds(400))
        model.watchdog()
        filled = system.windows.first { $0.id == left }?.frame == system.mainDisplay.visibleFrame
    }
    if !filled {
        filled = await system.waitFor(timeout: .seconds(2)) {
            system.windows.first { $0.id == left }?.frame == system.mainDisplay.visibleFrame
        }
    }
    #expect(filled, "Left stayed at \(String(describing: system.windows.first { $0.id == left }?.frame))")
    #expect(try storedSession(model, d).bentoState.root?.windowIDs == [left])
}

/// The user returns to the desktop, and Accessibility exposes Left before
/// Right. macOS still reports Right on this desktop, and events from Left make
/// sweeps frequent. Right keeps its pane through the minimum membership time,
/// however many sweeps run, and nothing moves when Right appears.
@Test(.appTestApplication) @MainActor
func aWindowExposedLateAfterAReturnKeepsItsPaneThroughFrequentSweeps() async throws {
    let (system, model) = try await makeTwoPaneAdaptiveFixture()
    defer { model.shutdown() }
    let d = system.mainDisplay.id
    let a = NativeSpaceID(rawValue: 1), b = NativeSpaceID(rawValue: 2)
    let tiled = system.windows
    let tree = try storedSession(model, d).bentoState

    system.desktopObservation?.currentSpaceByDisplay[d] = b
    system.windows = []
    model.beginActiveSpaceStabilization()
    try #require(await system.waitFor { !model.isStabilizingSpace })
    await system.advance(by: .milliseconds(200))

    system.desktopObservation?.currentSpaceByDisplay[d] = a
    system.windows = tiled.filter { $0.id == left }
    let writes = system.frameWriteCounts
    model.beginActiveSpaceStabilization()
    try #require(await system.waitFor { !model.isStabilizingSpace })
    let sweeps = system.completeSweepCount
    for _ in 0..<13 {
        system.eventHandler?(WindowSystemEvent(kind: .created, windowID: left, processIdentifier: 41))
        await system.advance(by: .milliseconds(90))
    }
    let budget = try storedSession(model, d).presence.toleratedMembershipOnlyAbsences
    try #require(system.completeSweepCount - sweeps > budget + 1,
                 "The partial return must last more than the membership budget of ordinary sweeps")
    #expect(system.frameWriteCounts == writes, "Left must not fill the screen")
    #expect(try storedSession(model, d).bentoState == tree)

    system.windows = tiled
    system.eventHandler?(WindowSystemEvent(kind: .created, windowID: right, processIdentifier: 42))
    await system.advance(by: .milliseconds(500))
    #expect(system.windows.map(\.frame) == tiled.map(\.frame))
    #expect(system.frameWriteCounts == writes)
    #expect(try storedSession(model, d).bentoState == tree)
}

/// A destroyed event arrives just before a desktop-change notification. The
/// desktop-transition sweep keeps the stored tree but must not drop that
/// evidence: the first ordinary sweep after the transition removes the pane at
/// once, before an inferred removal is possible, and then consumes it.
@Test(.appTestApplication) @MainActor
func aClosureJustBeforeADesktopNotificationRemovesThePaneOnTheFirstOrdinarySweep() async throws {
    let (system, model) = try await makeTwoPaneAdaptiveFixture()
    defer { model.shutdown() }
    let d = system.mainDisplay.id
    system.windows.removeAll { $0.id == right }
    system.desktopObservation?.windowMembership[right] = nil
    system.eventHandler?(WindowSystemEvent(kind: .destroyed, windowID: right, processIdentifier: 42))
    model.beginActiveSpaceStabilization()
    try #require(await system.waitFor { !model.isStabilizingSpace })
    try #require(try storedSession(model, d).bentoState.root?.windowIDs.contains(right) == true,
                 "the desktop-transition sweep keeps the stored tree")
    #expect(retainedDestroyedEvidence(model).contains(right), "the transition sweep keeps the evidence")

    let transitionSweeps = system.completeSweepCount
    try #require(await system.waitFor { system.completeSweepCount > transitionSweeps })
    try #require(system.completeSweepCount == transitionSweeps + 1)
    // An inferred removal needs more than `toleratedAbsences` ordinary misses.
    try #require(try storedSession(model, d).presence.toleratedAbsences >= 1)
    #expect(try storedSession(model, d).bentoState.root?.windowIDs == [left],
            "the first ordinary sweep removes the closed pane from its destroyed event")
    #expect(!retainedDestroyedEvidence(model).contains(right), "that sweep consumes the evidence")
}

/// Pure policy for the case above: a tree of two halves, one closed.
@Test func theReconcilerPlacesTheLoneWindowAfterAClose() throws {
    let display = DisplaySnapshot(id: DisplayID(rawValue: "d"), frame: BTRect(x: 0, y: 0, width: 1000, height: 800),
                                  visibleFrame: BTRect(x: 0, y: 0, width: 1000, height: 800), isMain: true)
    let left = window("Left", pid: 41, x: 0, display: display.id)
    let right = window("Right", pid: 42, x: 500, display: display.id)
    let reconciler = AmbientLayoutReconciler(paneGap: 0, adjacencyTolerance: 8, singleWindowPlacement: .maximize)
    var session = LayoutSession(displayID: display.id, mode: .bento)
    session.windowIDs = [left.id, right.id]
    let first = reconciler.transition(session: session, observation: AmbientLayoutObservation(
        display: display, windows: [left, right], wasCreated: true, previousWindowIDs: [], isDesktopTransition: false))
    session = first.session
    try #require(session.isBentoInitialized, "\(first)")
    session.windowIDs = [left.id]
    let second = reconciler.transition(session: session, observation: AmbientLayoutObservation(
        display: display, windows: [left], wasCreated: false, previousWindowIDs: [left.id, right.id],
        isDesktopTransition: false, confirmedGone: [right.id]))
    guard case let .placeSingleWindow(_, placement) = second else {
        Issue.record("expected the lone window to be placed, got \(second); latch \(session.hasAppliedSingleWindowPlacement) tree \(String(describing: second.session.bentoState.root))")
        return
    }
    #expect(placement.frame == display.visibleFrame)
}

/// BetterTile skips a held (unresponsive) application in its inventory, so the
/// held window is missing from every sweep while macOS still reports it on this
/// desktop. That is BetterTile's own choice, not evidence of a closure: the
/// window keeps its pane, and its neighbour does not fill the screen.
@Test(.appTestApplication) @MainActor
func aHeldApplicationKeepsItsAdaptivePane() async throws {
    let (system, model) = try await makeTwoPaneAdaptiveFixture()
    defer { model.shutdown() }
    let tiled = try #require(system.windows.first { $0.id == left }?.frame)

    system.applicationHoldDuration = 60
    system.unresponsiveProcessIDs = [42]
    for _ in 0..<8 {
        model.handleApplicationTopologyChange()
        await system.advance(by: .milliseconds(400))
    }
    try #require(system.applicationHoldsUntil[42] != nil, "The fixture must hold the application")
    #expect(system.windows.first { $0.id == left }?.frame == tiled,
            "A held window keeps its pane; its neighbour must not fill the screen")
}

/// Shared native Spaces do not make a readable window on another display a
/// missing member of this display. Commands must use the short absence budget.
@Test(.appTestApplication) @MainActor
func adaptiveCommandsExcludeReadableWindowsOnAnotherSharedSpaceDisplay() async throws {
    let (system, model) = try await makeTwoPaneAdaptiveFixture()
    defer { model.shutdown() }
    let display = system.mainDisplay.id
    let side = DisplaySnapshot(id: DisplayID(rawValue: "side"),
        frame: BTRect(x: 1000, y: 0, width: 1000, height: 800),
        visibleFrame: BTRect(x: 1000, y: 0, width: 1000, height: 800))
    system.availableDisplays.append(side)
    system.desktopObservation?.currentSpaceByDisplay[side.id] = NativeSpaceID(rawValue: 1)
    system.desktopObservation?.knownSpacesByDisplay[side.id] = [NativeSpaceID(rawValue: 1)]
    let index = try #require(system.windows.firstIndex { $0.id == right })
    system.windows[index].displayID = side.id
    system.windows[index].frame.origin.x = 1000
    try #require(system.desktopObservation?.exclusiveWindowIDs(on: display).contains(right) == true)
    model.handleApplicationTopologyChange()
    model.handleApplicationTopologyChange()
    try #require(try storedSession(model, display).presence.pending[right] == 2)
    model.perform(.leftHalf)
    #expect(try storedSession(model, display).presence.membershipOnlyAbsenceStarts[right] == nil)
    #expect(try storedSession(model, display).bentoState.root?.windowIDs == [left])
    #expect(system.windows[index].frame.origin.x == 1000)
}

/// Losing native observation cannot assign an unread on-screen window to a
/// desktop. The ordinary absence budget applies until that capability returns.
@Test(.appTestApplication, arguments: [false, true]) @MainActor
func nativeObservationLossDuringProtectedOmissionUsesTheOrdinaryBudget(returnsBeforeRemoval: Bool) async throws {
    let (system, model) = try await makeTwoPaneAdaptiveFixture()
    defer { model.shutdown() }
    let display = system.mainDisplay.id
    let tree = try storedSession(model, display).bentoState
    let observation = system.desktopObservation
    system.offscreenWindowIDs = [right]
    system.omittedButOnScreenWindowIDs = [right]
    model.handleApplicationTopologyChange()
    await system.advance(by: .milliseconds(400))
    try #require(try storedSession(model, display).presence.pending.isEmpty)
    try #require(try storedSession(model, display).bentoState == tree)
    system.desktopObservation = nil
    model.watchdog()
    #expect(try storedSession(model, display).presence.pending[right] == 1)
    #expect(system.unreadOnScreenWindowIDs.contains(right))
    if returnsBeforeRemoval {
        system.desktopObservation = observation
        model.handleApplicationTopologyChange()
        await system.advance(by: .seconds(2))
        #expect(try storedSession(model, display).presence.pending.isEmpty)
        #expect(try storedSession(model, display).bentoState == tree)
    } else {
        try #require(await system.waitFor {
            system.windows.first { $0.id == left }?.frame == system.mainDisplay.visibleFrame
        })
        #expect(try storedSession(model, display).bentoState.root?.windowIDs == [left])
        system.desktopObservation = observation
        system.offscreenWindowIDs = []
        system.omittedButOnScreenWindowIDs = []
        model.handleApplicationTopologyChange()
        try #require(await system.waitFor {
            (try? storedSession(model, display).bentoState.root?.windowIDs.count) == 2
        })
    }
}
