import AppKit
import BetterTileTestSupport
import Testing
@testable import BetterTileApp
@testable import BetterTileCore
@testable import BetterTileMacOS

// A window drag held at the screen edge makes macOS switch desktops and carry
// the window along. The drag continues on the destination desktop.

/// Off every real screen, so the drag overlay panels stay out of sight.
private let bounds = BTRect(x: -30000, y: -30000, width: 1000, height: 800)
private let spaceA = NativeSpaceID(rawValue: 1)
private let spaceB = NativeSpaceID(rawValue: 2)
private let spaceC = NativeSpaceID(rawValue: 3)

private func window(_ id: String, pid: Int32, x: Double, display: DisplayID) -> WindowSnapshot {
    WindowSnapshot(id: WindowID(rawValue: id), processIdentifier: pid, bundleIdentifier: "com.example.\(id)",
                   frame: BTRect(x: bounds.minX + x, y: bounds.minY, width: 500, height: 800), displayID: display,
                   constraints: WindowConstraints(minimumSize: BTSize(width: 120, height: 80), minimumSizeSource: .hint))
}

@MainActor private func member<Value>(_ model: BetterTileModel, _ name: String, as type: Value.Type) -> Value? {
    Mirror(reflecting: model).children.first { $0.label?.hasSuffix(name) == true }?.value as? Value
}

/// Whether the model holds an Adaptive or Tabbed drag.
@MainActor private func hasLayoutDrag(_ model: BetterTileModel) -> Bool {
    guard let value = Mirror(reflecting: model).children.first(where: { $0.label?.hasSuffix("activeBentoDrag") == true })?.value
    else { return false }
    return !Mirror(reflecting: value).children.isEmpty
}

@MainActor private func gesture(_ drag: DragSnapController, _ kind: GlobalGestureEventKind, x: Double, y: Double) {
    drag.handleSharedGestureEvent(.init(kind: kind, position: BTPoint(x: bounds.minX + x, y: bounds.minY + y),
                                        button: 0, modifiers: [], timestamp: 1))
}

/// Desktop A is Adaptive with two windows. The user drags A1 until macOS
/// switches to desktop B and carries A1 there. Still holding the button, the
/// user drags to B's right edge and releases: A1 takes B's right half.
@Test(.appTestApplication, arguments: [LayoutMode.manual, .bento]) @MainActor
func aWindowCarriedToAnotherDesktopSnapsThere(destinationMode: LayoutMode) async throws {
    _ = NSApplication.shared
    let system = makeManualWindowSystem()
    let d = system.mainDisplay.id
    system.availableDisplays = [DisplaySnapshot(id: d, frame: bounds, visibleFrame: bounds, isMain: true)]
    let a1 = window("A1", pid: 41, x: 0, display: d), a2 = window("A2", pid: 42, x: 500, display: d)
    let b1 = window("B1", pid: 51, x: 0, display: d), b2 = window("B2", pid: 52, x: 500, display: d)
    system.windows = [b1, b2]
    system.desktopObservation = NativeDesktopObservation(
        currentSpaceByDisplay: [d: spaceB], knownSpacesByDisplay: [d: [spaceA, spaceB]],
        windowMembership: [a1.id: [spaceA], a2.id: [spaceA], b1.id: [spaceB], b2.id: [spaceB]])
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.configuration.defaultLayoutMode = .manual
    model.configuration.bentoInnerGap = 0
    var pressed = false
    model.primaryButtonIsPressed = { pressed }
    system.focusedID = b1.id
    model.setActiveMode(destinationMode)
    await system.advance(by: .milliseconds(350))
    let bBefore = system.windows

    // Desktop A, Adaptive.
    system.desktopObservation?.currentSpaceByDisplay[d] = spaceA
    system.windows = [a1, a2]
    system.focusedID = a1.id
    model.beginActiveSpaceStabilization()
    try #require(await system.waitFor { !model.isStabilizingSpace })
    model.setActiveMode(.bento)
    await system.advance(by: .milliseconds(350))
    try #require(model.activeMode(for: d) == .bento)
    try #require(system.windows.map(\.frame) == [a1.frame, a2.frame])

    let drag = try #require(member(model, "dragSnap", as: DragSnapController.self))
    drag.setUsesSharedGestureEvents(true)
    pressed = true
    gesture(drag, .leftMouseDown, x: 200, y: 20)
    system.windows[0].frame.origin.x += 3
    gesture(drag, .leftMouseDragged, x: 300, y: 400)
    try #require(hasLayoutDrag(model), "The drag did not start an Adaptive drag on desktop A")

    // macOS switches to B and carries A1 along.
    var carried = system.windows[0]
    carried.frame.origin.x = bounds.minX + 400
    system.desktopObservation?.currentSpaceByDisplay[d] = spaceB
    system.desktopObservation?.windowMembership[a1.id] = [spaceB]
    system.windows = bBefore + [carried]
    system.requestedFrames = [:]
    system.frameWriteCounts = [:]
    model.beginActiveSpaceStabilization()
    #expect(!hasLayoutDrag(model))
    #expect(drag.isGestureActive, "The desktop change ended the window drag")
    try #require(await system.waitFor { !model.isStabilizingSpace })
    await system.advance(by: .milliseconds(100))
    #expect(system.frameWriteCounts[a1.id] == nil, "BetterTile moved the held window during the drag")

    gesture(drag, .leftMouseDragged, x: 999, y: 400)
    drag.displayTick()
    #expect(drag.dropTarget != nil, "No snap is offered on the destination desktop")
    gesture(drag, .leftMouseUp, x: 999, y: 400)
    pressed = false
    await system.advance(by: .milliseconds(350))

    let right = BTRect(x: bounds.minX + 500, y: bounds.minY, width: 500, height: 800)
    #expect(system.windows.first { $0.id == a1.id }?.frame == right)
    if destinationMode == .bento {
        // The carried window joins B's layout as its right half.
        let state = member(model, "sessionStore", as: LayoutSessionStore.self)?.session(for: d)?.bentoState
        #expect(Set(state?.root?.windowIDs ?? []) == [a1.id, b1.id, b2.id],
                "\(String(describing: state?.root)) \(system.windows.map { ($0.id, $0.frame) })")
        #expect(system.windows.filter { $0.id != a1.id }.allSatisfy { $0.frame.maxX <= right.minX + 0.5 })
    } else {
        #expect(system.windows.filter { $0.id != a1.id }.map(\.frame) == bBefore.map(\.frame))
    }
}

// MARK: - Destinations that would place the carried window on their own

enum CarryDestination: String, CustomStringConvertible, Sendable {
    /// An Adaptive desktop with no window, whose single-window placement
    /// would maximize the carried window.
    case emptyAdaptive
    /// A desktop BetterTile has not observed before; the default mode makes
    /// it Adaptive, and its first observation initializes the layout.
    case firstObservationAdaptive
    /// A Tabbed desktop with B1 and B2 that never held the carried window.
    case tabbed
    /// An Adaptive desktop whose tree holds B1 and B2.
    case adaptive
    case manual
    var description: String { rawValue }
}

enum CarrySource: String, CustomStringConvertible, Sendable {
    case adaptive
    /// A1 alone in its Tabbed pane.
    case tabbedLoneTab
    /// A1 and A2 as tabs of one Tabbed pane.
    case tabbedGroup
    var description: String { rawValue }
}

@MainActor private final class Button { var pressed = false }

/// Desktop C's own windows, side by side.
private func cWindows(on display: DisplayID) -> [WindowSnapshot] {
    [window("C1", pid: 61, x: 0, display: display), window("C2", pid: 62, x: 500, display: display)]
}

@MainActor private struct Carry {
    let system: FakeAppWindowSystem
    let model: BetterTileModel
    let drag: DragSnapController
    let button: Button
    let display: DisplayID
    let a1: WindowID
    let destinationWindows: [WindowSnapshot]

    var session: LayoutSession? { member(model, "sessionStore", as: LayoutSessionStore.self)?.session(for: display) }
    var carriedFrame: BTRect? { system.windows.first { $0.id == a1 }?.frame }
    /// Whether B's layout has the carried window as a pane member or in its tree.
    var destinationAdmitted: Bool {
        guard let session else { return false }
        return session.bentoState.root?.windowIDs.contains(a1) == true
            || session.tabbedState?.windowIDs.contains(a1) == true
    }

    func send(_ kind: GlobalGestureEventKind, x: Double, y: Double) {
        gesture(drag, kind, x: x, y: y)
    }
}

/// Builds desktop B (unless it is first observed only after the carry),
/// then desktop A with the source layout, starts dragging A1 on A and
/// carries it to B. Before the stabilization ends, `suspendedSample` is sent
/// when given. Returns once B's stabilization has ended.
@MainActor private func carry(
    to destination: CarryDestination, from source: CarrySource = .adaptive,
    suspendedSample: (x: Double, y: Double)? = nil,
    establishesAdaptiveC: Bool = false,
    floatsB2: Bool = false,
    beforeStabilizationEnds: (Carry) async -> Void = { _ in }
) async throws -> Carry {
    _ = NSApplication.shared
    let system = makeManualWindowSystem()
    let d = system.mainDisplay.id
    system.availableDisplays = [DisplaySnapshot(id: d, frame: bounds, visibleFrame: bounds, isMain: true)]
    let a1 = window("A1", pid: 41, x: 0, display: d), a2 = window("A2", pid: 42, x: 500, display: d)
    // Overlapping, so a first Adaptive observation must place them.
    let b1 = window("B1", pid: 51, x: 0, display: d), b2 = window("B2", pid: 52, x: 100, display: d)
    let bWindows = destination == .emptyAdaptive ? [] : [b1, b2]
    let firstOnA = destination == .firstObservationAdaptive
    system.windows = firstOnA ? [a1, a2] : bWindows
    system.desktopObservation = NativeDesktopObservation(
        currentSpaceByDisplay: [d: firstOnA ? spaceA : spaceB], knownSpacesByDisplay: [d: [spaceA, spaceB]],
        windowMembership: [a1.id: [spaceA], a2.id: [spaceA], b1.id: [spaceB], b2.id: [spaceB]])
    let model = makeModel(system: system)
    model.configuration.defaultLayoutMode = firstOnA ? .bento : .manual
    model.configuration.bentoInnerGap = 0
    model.configuration.defaultTabbedPreset = source == .tabbedGroup ? .single : .columns
    let button = Button()
    model.primaryButtonIsPressed = { button.pressed }
    let sessions = { member(model, "sessionStore", as: LayoutSessionStore.self)?.session(for: d) }
    if !firstOnA {
        system.focusedID = bWindows.first?.id
        switch destination {
        case .emptyAdaptive, .adaptive: model.setActiveMode(.bento)
        case .tabbed: model.setActiveMode(.tabbed)
        case .manual, .firstObservationAdaptive: break
        }
        await system.advance(by: .milliseconds(350))
        if destination == .tabbed {
            try #require(await system.waitFor { sessions()?.tabbedState?.windowIDs == [b1.id, b2.id] })
            if floatsB2 {
                // The user floats B2 on B.
                model.performTabbed(.float(b2.id))
                try #require(await system.waitFor {
                    sessions()?.tabbedState?.floatingWindowIDs.contains(b2.id) == true && !model.hasPendingTabbedPlacement
                })
            }
        }
        if destination == .adaptive {
            try #require(await system.waitFor { Set(sessions()?.bentoState.root?.windowIDs ?? []) == [b1.id, b2.id] })
        }
        if destination != .manual {
            try #require(model.activeMode(for: d) == (destination == .tabbed ? .tabbed : .bento))
        }
        if establishesAdaptiveC {
            // Desktop C, Adaptive, with its own tree.
            let establishedAdaptiveC = cWindows(on: d)
            system.desktopObservation?.knownSpacesByDisplay[d] = [spaceA, spaceB, spaceC]
            for window in establishedAdaptiveC { system.desktopObservation?.windowMembership[window.id] = [spaceC] }
            system.desktopObservation?.currentSpaceByDisplay[d] = spaceC
            system.windows = establishedAdaptiveC
            system.focusedID = establishedAdaptiveC[0].id
            model.beginActiveSpaceStabilization()
            try #require(await system.waitFor { !model.isStabilizingSpace })
            model.setActiveMode(.bento)
            await system.advance(by: .milliseconds(350))
            try #require(await system.waitFor {
                Set(sessions()?.bentoState.root?.windowIDs ?? []) == Set(establishedAdaptiveC.map(\.id))
            })
        }
        // Desktop A.
        system.desktopObservation?.currentSpaceByDisplay[d] = spaceA
        system.windows = [a1, a2]
        system.focusedID = a1.id
        model.beginActiveSpaceStabilization()
        try #require(await system.waitFor { !model.isStabilizingSpace })
    }
    let bSettled = system.windows.filter { $0.id != a1.id && $0.id != a2.id }
    system.focusedID = a1.id
    model.setActiveMode(source == .adaptive ? .bento : .tabbed)
    await system.advance(by: .milliseconds(350))
    if source != .adaptive {
        try #require(await system.waitFor { sessions()?.tabbedState?.windowIDs == [a1.id, a2.id] })
        if source == .tabbedLoneTab, let state = sessions()?.tabbedState,
           let other = state.panes.first(where: { !$0.tabs.contains(a1.id) }), state.pane(containing: a2.id)?.tabs.contains(a1.id) == true {
            model.performTabbed(.move(a2.id, pane: other.id, index: nil))
            try #require(await system.waitFor { sessions()?.tabbedState?.pane(containing: a2.id)?.id == other.id })
        }
        let pane = sessions()?.tabbedState?.pane(containing: a1.id)
        try #require(pane?.tabs.count == (source == .tabbedGroup ? 2 : 1), "\(String(describing: sessions()?.tabbedState?.panes))")
        if source == .tabbedGroup {
            model.performTabbed(.select(a1.id))
            try #require(await system.waitFor { sessions()?.tabbedState?.activeWindowID == a1.id })
        }
    }
    let destinationWindows = destination == .firstObservationAdaptive ? [b1, b2] : bSettled.isEmpty ? bWindows : bSettled

    let drag = try #require(member(model, "dragSnap", as: DragSnapController.self))
    drag.setUsesSharedGestureEvents(true)
    button.pressed = true
    let a1Frame = try #require(system.windows.first { $0.id == a1.id }?.frame)
    let press = (x: a1Frame.minX - bounds.minX + 150, y: a1Frame.minY - bounds.minY + 10)
    gesture(drag, .leftMouseDown, x: press.x, y: press.y)
    if let index = system.windows.firstIndex(where: { $0.id == a1.id }) { system.windows[index].frame.origin.x += 3 }
    gesture(drag, .leftMouseDragged, x: 300, y: 400)
    try #require(drag.isGestureActive, "The drag did not start on desktop A")

    // macOS switches to B and carries A1 along.
    var carried = try #require(system.windows.first { $0.id == a1.id })
    carried.frame = BTRect(x: bounds.minX + 250, y: bounds.minY + 100, width: 500, height: 600)
    system.desktopObservation?.currentSpaceByDisplay[d] = spaceB
    system.desktopObservation?.windowMembership[a1.id] = [spaceB]
    system.windows = destinationWindows + [carried]
    system.requestedFrames = [:]
    system.frameWriteCounts = [:]
    let fixture = Carry(system: system, model: model, drag: drag, button: button, display: d, a1: a1.id,
                        destinationWindows: destinationWindows)
    model.beginActiveSpaceStabilization()
    try #require(drag.isSuspendedForDesktopChange, "The desktop change ended the window drag")
    if let suspendedSample { fixture.send(.leftMouseDragged, x: suspendedSample.x, y: suspendedSample.y) }
    await beforeStabilizationEnds(fixture)
    try #require(await system.waitFor { !model.isStabilizingSpace })
    return fixture
}

/// While the button is held, BetterTile writes no frame for the carried
/// window and the destination layout does not admit it, also after the
/// destination's own timers ran.
@MainActor private func expectHeld(_ fixture: Carry, _ comment: Comment, sourceLocation: SourceLocation = #_sourceLocation) async {
    #expect(fixture.system.frameWriteCounts[fixture.a1] == nil,
            "BetterTile moved the held window: \(comment)", sourceLocation: sourceLocation)
    #expect(!fixture.destinationAdmitted, "The destination admitted the held window: \(comment)", sourceLocation: sourceLocation)
    await fixture.system.advance(by: .seconds(2))
    #expect(fixture.system.frameWriteCounts[fixture.a1] == nil,
            "BetterTile moved the held window later: \(comment)", sourceLocation: sourceLocation)
    #expect(!fixture.destinationAdmitted, "The destination admitted the held window later: \(comment)",
            sourceLocation: sourceLocation)
    #expect(fixture.drag.isGestureActive, "The drag ended during the hold: \(comment)", sourceLocation: sourceLocation)
}

/// Advances virtual time, then joins the policy work still in flight.
/// `advance` returns at its own deadline, even when a Tabbed placement or an
/// event pass resumed at that deadline has not run its next step yet.
@MainActor private func settle(_ fixture: Carry, for duration: Duration = .seconds(2),
                               sourceLocation: SourceLocation = #_sourceLocation) async throws {
    await fixture.system.advance(by: duration)
    try #require(await fixture.system.waitFor {
        !fixture.model.hasPendingTabbedPlacement && fixture.model.windowEventTask == nil
    }, "Tabbed placements and event passes did not finish", sourceLocation: sourceLocation)
}

/// The number of provisional-float records the model holds.
@MainActor private func provisionalFloatRecordCount(_ model: BetterTileModel) -> Int? {
    guard let value = Mirror(reflecting: model).children
        .first(where: { $0.label?.hasSuffix("provisionalTabbedFloats") == true })?.value else { return nil }
    return Mirror(reflecting: value).children.count
}

private let rightHalf = BTRect(x: bounds.minX + 500, y: bounds.minY, width: 500, height: 800)

enum CarryEnding: String, CustomStringConvertible, Sendable {
    case snapAtRightEdge, releaseWithoutDrop, escape
    var description: String { rawValue }
}

struct CarryHold: CustomStringConvertible, Sendable {
    var sampleDuringChange: Bool
    var ending: CarryEnding
    var description: String { "\(ending), sample during change: \(sampleDuringChange)" }
    static let all = [false, true].flatMap { sample in
        [CarryEnding.snapAtRightEdge, .releaseWithoutDrop, .escape].map { CarryHold(sampleDuringChange: sample, ending: $0) }
    }
}

/// A destination whose layout would place a window on its own leaves the
/// carried window alone while the button is down, whether a drag sample
/// arrived during the change or not. After the gesture, a snap keeps its
/// frame, or the window becomes an ordinary arrival.
@Test(.appTestApplication, arguments: [CarryDestination.emptyAdaptive, .firstObservationAdaptive, .adaptive, .tabbed],
      CarryHold.all) @MainActor
func aDestinationLayoutWaitsForTheCarriedWindowsRelease(destination: CarryDestination, hold: CarryHold) async throws {
    let sampleDuringChange = hold.sampleDuringChange, ending = hold.ending
    let fixture = try await carry(to: destination, suspendedSample: sampleDuringChange ? (300, 420) : nil)
    defer { fixture.model.shutdown() }
    let held = fixture.carriedFrame
    await expectHeld(fixture, "\(destination), sample \(sampleDuringChange)")
    #expect(fixture.carriedFrame == held)
    if destination == .firstObservationAdaptive {
        // B's own windows still get their first layout.
        let tree = Set(fixture.session?.bentoState.root?.windowIDs ?? [])
        #expect(tree == Set(fixture.destinationWindows.map(\.id)), "\(String(describing: fixture.session?.bentoState.root))")
    }

    switch ending {
    case .snapAtRightEdge:
        fixture.send(.leftMouseDragged, x: 999, y: 400)
        fixture.drag.displayTick()
        #expect(fixture.drag.dropTarget != nil, "No snap on the destination desktop")
        fixture.send(.leftMouseUp, x: 999, y: 400)
    case .releaseWithoutDrop:
        fixture.send(.leftMouseUp, x: 300, y: 420)
    case .escape:
        fixture.drag.cancel()
    }
    fixture.button.pressed = false
    #expect(!fixture.drag.isGestureActive)
    try await settle(fixture, for: .seconds(2))

    let state = fixture.session
    switch (destination, ending) {
    case (.tabbed, .snapAtRightEdge):
        // The snap puts A1 in the right pane as its selected tab.
        let pane = state?.tabbedState?.pane(containing: fixture.a1)
        #expect(pane?.selected == fixture.a1, "\(String(describing: state?.tabbedState?.panes))")
        #expect(state?.tabbedState?.floatingWindowIDs.contains(fixture.a1) == false)
        #expect(fixture.carriedFrame.map { $0.minX >= rightHalf.minX - 0.5 } == true, "\(String(describing: fixture.carriedFrame))")
    case (.firstObservationAdaptive, .snapAtRightEdge), (.adaptive, .snapAtRightEdge):
        // B's layout took the drag, and A1 joins it as the right half.
        #expect(Set(state?.bentoState.root?.windowIDs ?? []) == Set(fixture.destinationWindows.map(\.id) + [fixture.a1]))
        #expect(fixture.carriedFrame == rightHalf, "\(String(describing: fixture.carriedFrame))")
    case (.emptyAdaptive, .snapAtRightEdge):
        // An empty Adaptive desktop has no tree to drag in, so the plain
        // snap area applies. A1 becomes the desktop's single window, and the
        // single-window placement does not move it off the snap.
        #expect(state?.windowIDs == [fixture.a1])
        #expect(state?.hasAppliedSingleWindowPlacement == true)
        #expect(fixture.carriedFrame == rightHalf, "\(String(describing: fixture.carriedFrame))")
    case (_, .releaseWithoutDrop), (_, .escape):
        // No drop: the event pass after the gesture admits A1 like any
        // window that arrives on B.
        if destination == .emptyAdaptive {
            // A lone window has no tree: it gets the single-window placement.
            #expect(state?.windowIDs == [fixture.a1])
            #expect(fixture.carriedFrame == bounds, "\(String(describing: fixture.carriedFrame))")
        } else {
            #expect(fixture.destinationAdmitted, "A1 never joined B's layout after the gesture: \(String(describing: state))")
        }
        if destination == .tabbed {
            #expect(state?.tabbedState?.floatingWindowIDs.contains(fixture.a1) == false)
        }
    case (.manual, _):
        Issue.record("Not a case of this test")
    }
}

// MARK: - A Tabbed destination that never held the carried window

/// The drag sample arrives while B is still stabilizing, so the drag starts
/// on B's Tabbed layout as soon as B settles. A1 is in none of B's panes and
/// not floating there. The drop still lands: an Add as tab drop makes A1 the
/// selected tab of that pane. Release without a drop and Escape leave B's
/// panes as they were, and A1 then arrives as any new window.
@Test(.appTestApplication, arguments: ["addAsTab", "release", "escape"]) @MainActor
func aTabbedDestinationTakesACarriedWindowOnlyWithADrop(ending: String) async throws {
    let fixture = try await carry(to: .tabbed, suspendedSample: (300, 420))
    defer { fixture.model.shutdown() }
    try #require(hasLayoutDrag(fixture.model), "The resumed drag did not start B's Tabbed drag")
    let before = try #require(fixture.session?.tabbedState)
    #expect(!before.windowIDs.contains(fixture.a1))
    await expectHeld(fixture, "Tabbed, \(ending)")
    let target = try #require(before.panes.last)
    switch ending {
    case "addAsTab":
        let preview = fixture.model.previewBentoDrag(displayID: fixture.display, sourceID: fixture.a1,
                                                     outcome: .tab(paneID: target.id, index: nil))
        guard case .ready? = preview else { Issue.record("Add as tab is not a drop: \(String(describing: preview))"); return }
        fixture.model.finishBentoDrag(displayID: fixture.display, sourceID: fixture.a1,
                                      outcome: .tab(paneID: target.id, index: nil))
        fixture.send(.leftMouseUp, x: 300, y: 420)
    case "release":
        fixture.send(.leftMouseUp, x: 300, y: 420)
    default:
        fixture.drag.cancel()
    }
    fixture.button.pressed = false
    try await settle(fixture, for: .seconds(2))
    let state = try #require(fixture.session?.tabbedState)
    if ending == "addAsTab" {
        #expect(state.pane(containing: fixture.a1)?.id == target.id, "\(state.panes)")
        #expect(state.pane(containing: fixture.a1)?.selected == fixture.a1)
        #expect(state.activeWindowID == fixture.a1)
        #expect(!state.floatingWindowIDs.contains(fixture.a1))
        #expect(Set(state.panes.flatMap(\.tabs)) == Set(before.windowIDs).union([fixture.a1]))
    } else {
        // B's panes keep their windows; A1 joins only as an arrival.
        #expect(before.windowIDs.isSubset(of: state.windowIDs))
        #expect(!state.floatingWindowIDs.contains(fixture.a1), "A1 kept the drag's provisional float")
        #expect(state.windowIDs.contains(fixture.a1), "A1 never arrived on B after the gesture")
    }
}

// MARK: - A Tabbed source carried to a Manual desktop

/// A Tabbed tab, alone in its pane or one of a group, carried to a Manual
/// desktop gets the plain snap areas there. Desktop A's inactive Tabbed
/// layout does not block them.
@Test(.appTestApplication, arguments: [CarrySource.tabbedLoneTab, .tabbedGroup]) @MainActor
func aTabbedTabCarriedToAManualDesktopSnapsThere(source: CarrySource) async throws {
    let fixture = try await carry(to: .manual, from: source)
    defer { fixture.model.shutdown() }
    #expect(!hasLayoutDrag(fixture.model))
    fixture.send(.leftMouseDragged, x: 999, y: 400)
    fixture.drag.displayTick()
    #expect(fixture.drag.dropTarget?.drop == .snap(SnapTarget(action: .rightHalf, frame: rightHalf)),
            "No snap on the Manual destination for a \(source)")
    fixture.send(.leftMouseUp, x: 999, y: 400)
    fixture.button.pressed = false
    try await settle(fixture, for: .milliseconds(500))
    #expect(fixture.carriedFrame == rightHalf, "\(String(describing: fixture.carriedFrame))")
    #expect(fixture.destinationWindows.allSatisfy { window in
        fixture.system.windows.first { $0.id == window.id }?.frame == window.frame
    })
}

// MARK: - Stabilization edge cases

/// A second desktop change during the first stabilization wait keeps the
/// drag suspended. Only the newest stabilization resumes it.
@Test(.appTestApplication) @MainActor func aSecondDesktopChangeKeepsTheDragSuspended() async throws {
    var resumedEarly = false
    let fixture = try await carry(to: .manual) { fixture in
        // The first stabilization is waiting between samples.
        await fixture.system.advance(by: .milliseconds(20))
        guard fixture.model.isStabilizingSpace else { Issue.record("The first stabilization already ended"); return }
        fixture.model.beginActiveSpaceStabilization()
        await fixture.system.advance(by: .milliseconds(80))
        resumedEarly = !fixture.drag.isSuspendedForDesktopChange && fixture.model.isStabilizingSpace
    }
    defer { fixture.model.shutdown() }
    #expect(!resumedEarly, "The replaced stabilization resumed the drag")
    #expect(!fixture.drag.isSuspendedForDesktopChange)
    #expect(fixture.drag.isGestureActive)
    fixture.send(.leftMouseDragged, x: 999, y: 400)
    fixture.drag.displayTick()
    fixture.send(.leftMouseUp, x: 999, y: 400)
    fixture.button.pressed = false
    #expect(fixture.carriedFrame == rightHalf)
}

/// A stabilization sample that fails still ends the suspension. The drag
/// continues on the selected destination session.
@Test(.appTestApplication) @MainActor func anObservationFailureResumesTheDrag() async throws {
    let fixture = try await carry(to: .manual) { fixture in
        fixture.system.failedVisibleWindowSweeps = [fixture.system.completeSweepCount + 1]
    }
    defer { fixture.model.shutdown() }
    #expect(!fixture.drag.isSuspendedForDesktopChange)
    #expect(fixture.drag.isGestureActive)
    #expect(fixture.system.frameWriteCounts[fixture.a1] == nil)
    fixture.send(.leftMouseDragged, x: 999, y: 400)
    fixture.drag.displayTick()
    #expect(fixture.drag.dropTarget?.drop == .snap(SnapTarget(action: .rightHalf, frame: rightHalf)))
    fixture.send(.leftMouseUp, x: 999, y: 400)
    fixture.button.pressed = false
    #expect(fixture.carriedFrame == rightHalf)
}

/// Escape during the change ends the drag. The stabilization's late resume
/// then starts nothing: no layout drag, no preview, no write for the window,
/// and B admits it as an ordinary arrival.
@Test(.appTestApplication) @MainActor func aLateResumeAfterEscapeStartsNothing() async throws {
    var ended = false
    let fixture = try await carry(to: .tabbed) { fixture in
        fixture.drag.cancel()
        ended = !fixture.drag.isGestureActive
    }
    defer { fixture.model.shutdown() }
    fixture.button.pressed = false
    #expect(ended)
    #expect(!fixture.drag.isGestureActive)
    #expect(!hasLayoutDrag(fixture.model))
    #expect(fixture.drag.dropTarget == nil)
    try await settle(fixture, for: .seconds(2))
    #expect(fixture.session?.tabbedState?.windowIDs.contains(fixture.a1) == true,
            "A1 never arrived on B: \(String(describing: fixture.session?.tabbedState))")
}

// MARK: - Round 3: failed drops and failed observations

/// The number of Tabbed Undo steps the model holds, over all sessions.
@MainActor private func tabbedUndoStepCount(_ model: BetterTileModel) -> Int {
    guard let undo = Mirror(reflecting: model).children
        .first(where: { $0.label == "tabbedUndo" || $0.label == "_tabbedUndo" })?.value else { return 0 }
    return Mirror(reflecting: undo).children.reduce(0) { total, entry in
        guard let steps = Mirror(reflecting: entry.value).children.dropFirst().first?.value else { return total }
        return total + Mirror(reflecting: steps).children.count
    }
}

/// Ends a Tabbed destination drag with an Add as tab drop on B's last pane,
/// or with a half snap at B's right edge.
@MainActor private func dropOnTabbedDestination(_ fixture: Carry, _ drop: String, target: UUID) {
    if drop == "addAsTab" {
        fixture.model.finishBentoDrag(displayID: fixture.display, sourceID: fixture.a1,
                                      outcome: .tab(paneID: target, index: nil))
        fixture.send(.leftMouseUp, x: 300, y: 420)
    } else {
        fixture.send(.leftMouseDragged, x: 999, y: 400)
        fixture.drag.displayTick()
        fixture.send(.leftMouseUp, x: 999, y: 400)
    }
    fixture.button.pressed = false
}

/// A Tabbed drop of a carried window whose placement fails and rolls back
/// publishes nothing. A1 does not keep the drag's provisional float, no
/// failed step joins Tabbed Undo, and A1 then arrives on B as any new
/// window does: it joins a pane.
@Test(.appTestApplication, arguments: ["addAsTab", "halfSnap"]) @MainActor
func aFailedTabbedDropOfACarriedWindowLeavesNoProvisionalFloat(drop: String) async throws {
    let fixture = try await carry(to: .tabbed, suspendedSample: (300, 420))
    defer { fixture.model.shutdown() }
    try #require(hasLayoutDrag(fixture.model), "The resumed drag did not start B's Tabbed drag")
    let before = try #require(fixture.session?.tabbedState)
    let target = try #require(before.panes.last)
    let undoSteps = tabbedUndoStepCount(fixture.model)
    // The drop's first write of A1 fails once; the rollback then succeeds.
    fixture.system.failedFrameWriteNumbers[fixture.a1] = [1]
    var sawFloatAfterRollback = false
    var sawFailure = false
    dropOnTabbedDestination(fixture, drop, target: target.id)
    for _ in 0..<40 {
        await fixture.system.advance(by: .milliseconds(50))
        if fixture.model.statusMessage != nil { sawFailure = true }
        if fixture.session?.tabbedState?.floatingWindowIDs.contains(fixture.a1) == true, sawFailure {
            sawFloatAfterRollback = true
        }
    }
    #expect(fixture.system.frameWriteCounts[fixture.a1, default: 0] >= 1, "The drop never wrote A1")
    #expect(sawFailure, "The injected write failure did not fail the drop")
    #expect(!sawFloatAfterRollback, "A1 kept the drag's provisional float after the rollback")
    let state = try #require(fixture.session?.tabbedState)
    #expect(!state.floatingWindowIDs.contains(fixture.a1), "A1 kept the drag's provisional float: \(state)")
    #expect(state.windowIDs.contains(fixture.a1), "A1 never arrived on B after the failed drop: \(state.panes)")
    #expect(before.windowIDs.isSubset(of: state.windowIDs))
    #expect(tabbedUndoStepCount(fixture.model) == undoSteps, "The failed drop added a Tabbed Undo step")
}

/// Undo of a carried window's Tabbed drop that landed restores the layout
/// from the drag's start on B. That layout held A1 as a floating window, so
/// A1 floats again at its frame from that moment and stays floating: Undo
/// is not undone by arrival admission or by Repair Layout.
@Test(.appTestApplication, arguments: ["addAsTab", "halfSnap"]) @MainActor
func undoOfACarriedWindowsTabbedDropFloatsIt(drop: String) async throws {
    let fixture = try await carry(to: .tabbed, suspendedSample: (300, 420))
    defer { fixture.model.shutdown() }
    try #require(hasLayoutDrag(fixture.model), "The resumed drag did not start B's Tabbed drag")
    let before = try #require(fixture.session?.tabbedState)
    let target = try #require(before.panes.last)
    let dragStartFrame = try #require(fixture.carriedFrame)
    dropOnTabbedDestination(fixture, drop, target: target.id)
    try await settle(fixture, for: .seconds(1))
    try #require(fixture.session?.tabbedState?.pane(containing: fixture.a1) != nil,
                 "The drop did not land: \(String(describing: fixture.session?.tabbedState))")
    fixture.model.performTabbed(.undo)
    try await settle(fixture, for: .seconds(2))
    let state = try #require(fixture.session?.tabbedState)
    #expect(state.floatingWindowIDs.contains(fixture.a1), "\(state)")
    #expect(!state.windowIDs.contains(fixture.a1))
    #expect(state.panes.map(\.tabs) == before.panes.map(\.tabs))
    #expect(fixture.carriedFrame == dragStartFrame, "\(String(describing: fixture.carriedFrame))")
    // Repair Layout returns only windows that floated on their own.
    fixture.model.performTabbed(.repair)
    try await settle(fixture, for: .seconds(1))
    #expect(fixture.session?.tabbedState?.floatingWindowIDs.contains(fixture.a1) == true,
            "\(String(describing: fixture.session?.tabbedState))")
}

enum StabilizationFault: String, CustomStringConvertible, Sendable {
    /// The first stabilization inventory fails.
    case failedInventory
    /// The stabilization inventories succeed but do not list A1.
    case omittedWindow
    var description: String { rawValue }
}

struct FaultedCarry: CustomStringConvertible, Sendable {
    var fault: StabilizationFault
    var ending: CarryEnding
    var description: String { "\(fault), \(ending)" }
    static let all = [StabilizationFault.failedInventory, .omittedWindow].flatMap { fault in
        [CarryEnding.snapAtRightEdge, .releaseWithoutDrop, .escape].map { FaultedCarry(fault: fault, ending: $0) }
    }
}

/// Carries A1 to the Adaptive B with a stabilization fault. The resumed drag
/// then starts B's Adaptive drag, which clears queued window events.
@MainActor private func carryWithFault(_ fault: StabilizationFault,
                                        establishesAdaptiveC: Bool = false) async throws -> Carry {
    var omitted: WindowSnapshot?
    let fixture = try await carry(to: .adaptive, suspendedSample: (300, 420),
                                  establishesAdaptiveC: establishesAdaptiveC) { fixture in
        switch fault {
        case .failedInventory:
            fixture.system.failedVisibleWindowSweeps = [fixture.system.completeSweepCount + 1]
        case .omittedWindow:
            omitted = fixture.system.windows.first { $0.id == fixture.a1 }
            fixture.system.windows.removeAll { $0.id == fixture.a1 }
        }
    }
    if let omitted {
        // A1 is readable again; the resumed drag retries its read.
        fixture.system.windows.append(omitted)
        fixture.drag.displayTick()
    }
    return fixture
}

/// The gesture, not a stabilization refresh, arms the arrival pass after
/// the gesture. With a failed or incomplete stabilization observation, a
/// release without a drop and Escape still admit A1 into B's tree after the
/// normal debounce, well before the 10-second watchdog. A drop admits it
/// at once.
@Test(.appTestApplication, arguments: FaultedCarry.all) @MainActor
func aCarriedWindowArrivesAfterAFaultedStabilization(carry: FaultedCarry) async throws {
    let fixture = try await carryWithFault(carry.fault)
    defer { fixture.model.shutdown() }
    try #require(hasLayoutDrag(fixture.model), "The resumed drag did not start B's Adaptive drag")
    #expect(!fixture.destinationAdmitted)
    #expect(fixture.system.frameWriteCounts[fixture.a1] == nil)
    switch carry.ending {
    case .snapAtRightEdge:
        fixture.send(.leftMouseDragged, x: 999, y: 400)
        fixture.drag.displayTick()
        fixture.send(.leftMouseUp, x: 999, y: 400)
    case .releaseWithoutDrop:
        fixture.send(.leftMouseUp, x: 300, y: 420)
    case .escape:
        fixture.drag.cancel()
    }
    fixture.button.pressed = false
    #expect(!fixture.drag.isGestureActive)
    try await settle(fixture, for: .seconds(2))
    let tree = Set(fixture.session?.bentoState.root?.windowIDs ?? [])
    #expect(tree == Set(fixture.destinationWindows.map(\.id) + [fixture.a1]),
            "A1 did not join B's tree after the gesture: \(String(describing: fixture.session?.bentoState.root))")
    if carry.ending == .snapAtRightEdge {
        #expect(fixture.carriedFrame == rightHalf, "\(String(describing: fixture.carriedFrame))")
    }
}

/// After a failed stabilization inventory on B, the drag carries A1 on to a
/// third desktop C. C is an established Adaptive desktop with its own tree,
/// and its stabilization observation fails as well. The resumed drag starts
/// C's Adaptive drag, and that drag start clears queued window events. A
/// release without a drop must still admit A1 on C, the desktop current at
/// the gesture's end, before the 10-second watchdog. B's stored layout keeps
/// only its own windows.
@Test(.appTestApplication, arguments: [StabilizationFault.failedInventory, .omittedWindow]) @MainActor
func onlyTheFinalDestinationAdmitsACarriedWindow(faultOnC: StabilizationFault) async throws {
    let fixture = try await carryWithFault(.failedInventory, establishesAdaptiveC: true)
    defer { fixture.model.shutdown() }
    let system = fixture.system, display = fixture.display
    let cs = cWindows(on: display), c1 = cs[0], c2 = cs[1]
    try #require(hasLayoutDrag(fixture.model), "The resumed drag did not start B's Adaptive drag")
    let sessions = { member(fixture.model, "sessionStore", as: LayoutSessionStore.self)?.allSessions(for: display) ?? [] }
    let cBefore = try #require(sessions().first { $0.nativeSpaceID == spaceC })
    try #require(Set(cBefore.bentoState.root?.windowIDs ?? []) == [c1.id, c2.id])

    // The drag carries A1 on to C.
    var carried = try #require(system.windows.first { $0.id == fixture.a1 })
    carried.frame.origin.y += 10
    system.desktopObservation?.windowMembership[fixture.a1] = [spaceC]
    system.desktopObservation?.currentSpaceByDisplay[display] = spaceC
    system.windows = [c1, c2]
    system.frameWriteCounts = [:]
    switch faultOnC {
    case .failedInventory:
        system.windows.append(carried)
        system.failedVisibleWindowSweeps = [system.completeSweepCount + 1]
    case .omittedWindow:
        break
    }
    fixture.model.beginActiveSpaceStabilization()
    try #require(fixture.drag.isSuspendedForDesktopChange, "The second desktop change ended the drag")
    fixture.send(.leftMouseDragged, x: 300, y: 430)
    try #require(await system.waitFor { !fixture.model.isStabilizingSpace })
    if faultOnC == .omittedWindow {
        // A1 is readable again; the resumed drag retries its read.
        system.windows.append(carried)
        fixture.drag.displayTick()
    }
    try #require(fixture.session?.id == cBefore.id, "C's stored session is not active")
    try #require(hasLayoutDrag(fixture.model), "The resumed drag did not start C's Adaptive drag")
    #expect(system.frameWriteCounts[fixture.a1] == nil)
    #expect(fixture.session?.bentoState.root?.windowIDs.contains(fixture.a1) != true)

    fixture.send(.leftMouseUp, x: 300, y: 430)
    fixture.button.pressed = false
    #expect(!fixture.drag.isGestureActive)
    try await settle(fixture, for: .seconds(2))
    let b = sessions().first { $0.nativeSpaceID == spaceB }
    #expect(Set(b?.bentoState.root?.windowIDs ?? []) == Set(fixture.destinationWindows.map(\.id)),
            "B admitted A1 after A1 left B: \(String(describing: b?.bentoState.root))")
    #expect(Set(fixture.session?.bentoState.root?.windowIDs ?? []) == [c1.id, c2.id, fixture.a1],
            "C did not admit A1 after the gesture: \(String(describing: fixture.session?.bentoState.root))")
}

/// A Tabbed snap area that is not a pane partition, such as Almost Maximize
/// at the top edge, only moves a floating source. A carried window placed there
/// stays a floating member of B at the snapped frame. If that write fails,
/// the provisional float is removed and A1 arrives on B as any new window.
@Test(.appTestApplication, arguments: [false, true]) @MainActor
func aCarriedWindowsFrameOnlyTabbedSnap(writeFails: Bool) async throws {
    let fixture = try await carry(to: .tabbed, suspendedSample: (300, 420))
    defer { fixture.model.shutdown() }
    try #require(hasLayoutDrag(fixture.model), "The resumed drag did not start B's Tabbed drag")
    let before = try #require(fixture.session?.tabbedState)
    if writeFails { fixture.system.failedFrameWriteNumbers[fixture.a1] = [1] }
    fixture.send(.leftMouseDragged, x: 500, y: 0)
    fixture.drag.displayTick()
    guard case let .layout(prepared)? = fixture.drag.dropTarget?.drop,
          case let .snap(action, frame) = prepared.outcome else {
        Issue.record("No Tabbed snap at the top edge: \(String(describing: fixture.drag.dropTarget))"); return
    }
    try #require(!BentoDropPlanner.partitionActions.contains(action), "\(action) is a partition")
    fixture.send(.leftMouseUp, x: 500, y: 0)
    fixture.button.pressed = false
    try await settle(fixture)
    let state = try #require(fixture.session?.tabbedState)
    #expect(before.windowIDs.isSubset(of: state.windowIDs))
    if writeFails {
        #expect(!state.floatingWindowIDs.contains(fixture.a1), "A1 kept the drag's provisional float: \(state)")
        #expect(state.windowIDs.contains(fixture.a1), "A1 never arrived on B after the failed snap: \(state.panes)")
    } else {
        #expect(state.floatingWindowIDs.contains(fixture.a1), "\(state)")
        #expect(!state.windowIDs.contains(fixture.a1))
        #expect(fixture.carriedFrame == frame, "\(String(describing: fixture.carriedFrame))")
    }
}

// MARK: - Round 4: the provisional float ends with its drag on every path

/// B's stored session, active or not.
@MainActor private func storedSession(_ fixture: Carry, _ id: DesktopSessionID) -> LayoutSession? {
    member(fixture.model, "sessionStore", as: LayoutSessionStore.self)?
        .allSessions(for: fixture.display).first { $0.id == id }
}

/// macOS switches the display to desktop C, a Manual desktop with one window.
@MainActor private func switchToC(_ fixture: Carry) {
    let system = fixture.system, d = fixture.display
    let c1 = cWindows(on: d)[0]
    system.desktopObservation?.knownSpacesByDisplay[d] = [spaceA, spaceB, spaceC]
    system.desktopObservation?.windowMembership[c1.id] = [spaceC]
    system.desktopObservation?.currentSpaceByDisplay[d] = spaceC
    system.windows = [c1]
    fixture.model.beginActiveSpaceStabilization()
}

/// The user returns to B, where `windows` still are.
@MainActor private func returnToB(_ fixture: Carry, windows: [WindowSnapshot]) async throws {
    fixture.system.desktopObservation?.currentSpaceByDisplay[fixture.display] = spaceB
    fixture.system.windows = windows
    fixture.model.beginActiveSpaceStabilization()
    try #require(await fixture.system.waitFor { !fixture.model.isStabilizingSpace })
    try await settle(fixture)
}

/// Checks B after the user returned: A1 holds no provisional float, it
/// arrived in a pane as any new window does, B's panes kept their windows,
/// and no Undo step was added.
@MainActor private func expectOrdinaryArrivalOnB(
    _ fixture: Carry, before: TabbedLayoutState, undoSteps: Int, _ comment: Comment,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    guard let state = fixture.session?.tabbedState else {
        Issue.record("B has no Tabbed state: \(comment)", sourceLocation: sourceLocation); return
    }
    #expect(!state.floatingWindowIDs.contains(fixture.a1),
            "A1 kept the drag's provisional float on B: \(comment) \(state)", sourceLocation: sourceLocation)
    #expect(state.windowIDs.contains(fixture.a1),
            "A1 did not arrive in a pane on B: \(comment) \(state.panes)", sourceLocation: sourceLocation)
    #expect(before.windowIDs.isSubset(of: state.windowIDs), "\(comment)", sourceLocation: sourceLocation)
    #expect(tabbedUndoStepCount(fixture.model) == undoSteps,
            "The unpublished drop added an Undo step: \(comment)", sourceLocation: sourceLocation)
}

enum PendingDrop: String, CustomStringConvertible, Sendable {
    /// The drop started its placement task, which has not run yet.
    case placementPending
    /// The release waits for an older placement that the drag took over.
    case releaseDeferred
    var description: String { rawValue }
}

/// The user releases a Tabbed drop of a carried window on B, then switches
/// to C before the drop finishes. The desktop change cancels the pending
/// work, and C is the active session when it ends. B, now inactive, must
/// not keep the drag's provisional float, and no window moves while B is
/// inactive. When the user returns to B, A1 arrives in a pane as any new
/// window does.
@Test(.appTestApplication, arguments: ["addAsTab", "halfSnap"], [PendingDrop.placementPending, .releaseDeferred])
@MainActor
func aTabbedDropCancelledByADesktopChangeLeavesNoProvisionalFloat(drop: String, pending: PendingDrop) async throws {
    let fixture = try await carry(to: .tabbed, suspendedSample: (300, 420))
    defer { fixture.model.shutdown() }
    try #require(hasLayoutDrag(fixture.model), "The resumed drag did not start B's Tabbed drag")
    // Do not infer a pending placement from how many executor turns the
    // stabilization wait happened to take. End B's placement explicitly.
    try await settle(fixture, for: .milliseconds(100))
    let before = try #require(fixture.session?.tabbedState)
    let bID = try #require(fixture.session?.id)
    let target = try #require(before.panes.last)
    let undoSteps = tabbedUndoStepCount(fixture.model)
    let onB = fixture.system.windows
    let writes = fixture.system.frameWriteCounts

    if pending == .releaseDeferred {
        // A second drag of the same carried window takes over its pending
        // drop. No await lets that placement release the apply slot first.
        let frame = try #require(fixture.carriedFrame)
        dropOnTabbedDestination(fixture, "addAsTab", target: target.id)
        fixture.button.pressed = true
        try #require(fixture.model.hasPendingTabbedPlacement)
        try #require(fixture.model.beginBentoDrag(displayID: fixture.display,
            sourceID: fixture.a1, sourceFrame: frame))
    }
    // No await between the release and the switch: the placement task
    // has not run yet. The second drag above uses the model seam directly.
    if pending == .releaseDeferred, drop == "halfSnap" {
        let frame = BTRect(x: bounds.midX, y: bounds.minY, width: bounds.size.width / 2, height: bounds.size.height)
        fixture.model.finishBentoDrag(displayID: fixture.display, sourceID: fixture.a1,
                                     outcome: .snap(action: .rightHalf, frame: frame))
        fixture.button.pressed = false
    } else {
        dropOnTabbedDestination(fixture, drop, target: target.id)
    }
    try #require(hasLayoutDrag(fixture.model) == (pending == .releaseDeferred),
                 "The release did not finish as the case needs: \(pending)")
    switchToC(fixture)
    try #require(storedSession(fixture, bID)?.tabbedState?.floatingWindowIDs.contains(fixture.a1) == true,
                 "The drop did not leave a pending placement with the provisional float")
    try #require(await fixture.system.waitFor { !fixture.model.isStabilizingSpace })
    try await settle(fixture, for: .seconds(1))
    try #require(fixture.session?.id != bID, "B is still the active session")
    let inactive = try #require(storedSession(fixture, bID)?.tabbedState)
    #expect(!inactive.floatingWindowIDs.contains(fixture.a1), "Inactive B kept the provisional float: \(inactive)")
    #expect(inactive.panes.map(\.tabs) == before.panes.map(\.tabs))
    #expect(fixture.system.frameWriteCounts == writes, "A window moved while B was inactive")

    try await returnToB(fixture, windows: onB)
    expectOrdinaryArrivalOnB(fixture, before: before, undoSteps: undoSteps, "\(drop)")
}

/// Native observation reports desktop C during the release inventory,
/// before the Space notification arrives. The Tabbed drop then returns at
/// its first validation, before any placement starts. The provisional float
/// must still end with the drag: B holds no float for A1 while inactive,
/// and A1 arrives in a pane when the user returns.
@Test(.appTestApplication, arguments: ["addAsTab", "halfSnap"]) @MainActor
func aDesktopChangeDuringTheReleaseInventoryLeavesNoProvisionalFloat(drop: String) async throws {
    let fixture = try await carry(to: .tabbed, suspendedSample: (300, 420))
    defer { fixture.model.shutdown() }
    let system = fixture.system, d = fixture.display
    try #require(hasLayoutDrag(fixture.model), "The resumed drag did not start B's Tabbed drag")
    let before = try #require(fixture.session?.tabbedState)
    let bID = try #require(fixture.session?.id)
    let target = try #require(before.panes.last)
    let undoSteps = tabbedUndoStepCount(fixture.model)
    let onB = system.windows
    if drop == "halfSnap" {
        // The pointer reaches the edge before the release.
        fixture.send(.leftMouseDragged, x: 999, y: 400)
        fixture.drag.displayTick()
    }
    let releaseSweep = system.completeSweepCount + 1
    var sawReleaseSweep = false
    system.onVisibleWindowSweep = { [weak system] count in
        guard count == releaseSweep else { return }
        sawReleaseSweep = true
        system?.desktopObservation?.currentSpaceByDisplay[d] = spaceC
    }
    if drop == "addAsTab" {
        fixture.model.finishBentoDrag(displayID: d, sourceID: fixture.a1, outcome: .tab(paneID: target.id, index: nil))
        fixture.send(.leftMouseUp, x: 300, y: 420)
    } else {
        fixture.send(.leftMouseUp, x: 999, y: 400)
    }
    fixture.button.pressed = false
    // The release can wait for a placement the drag took over.
    await system.advance(by: .milliseconds(50))
    try #require(!hasLayoutDrag(fixture.model), "The drop did not finish")
    system.onVisibleWindowSweep = nil
    #expect(sawReleaseSweep, "The release took no window inventory")
    #expect(system.frameWriteCounts[fixture.a1] == nil, "The drop moved A1 on a changed desktop")
    // The Space notification follows.
    switchToC(fixture)
    try #require(await system.waitFor { !fixture.model.isStabilizingSpace })
    try await settle(fixture, for: .seconds(1))
    let inactive = try #require(storedSession(fixture, bID)?.tabbedState)
    #expect(!inactive.floatingWindowIDs.contains(fixture.a1), "Inactive B kept the provisional float: \(inactive)")

    try await returnToB(fixture, windows: onB)
    expectOrdinaryArrivalOnB(fixture, before: before, undoSteps: undoSteps, "\(drop)")
}

enum NewerDragEnding: String, CustomStringConvertible, Sendable {
    /// B1 joins B's empty pane as a tab.
    case addAsTab
    /// B1 is released over invalid feedback and returns to its group.
    case invalidFeedback
    /// B1 joins B's empty pane as a tab, and the user then uses Undo.
    case undoOfTheDrop
    /// B2, which the user floated, takes Almost Maximize, a frame-only snap.
    case floatingSourceFrameOnlySnap
    /// The user drags A1 itself again and releases it without a drop.
    case sameWindowAgain
    var description: String { rawValue }
}

/// The user releases a Tabbed drop of a carried window on B and at once
/// starts dragging another window there, before the drop's placement runs.
/// The new drag cancels that placement. Its start also ends A1's
/// provisional float, so the new drag's baseline, rollback and Undo step
/// hold nothing of A1. However the new drag ends, A1 then arrives in a pane
/// as any new window does, and no provisional-float record remains.
@Test(.appTestApplication, arguments: [NewerDragEnding.addAsTab, .invalidFeedback, .undoOfTheDrop,
                                       .floatingSourceFrameOnlySnap, .sameWindowAgain])
@MainActor func aNewDragEndsAnOlderProvisionalFloat(ending: NewerDragEnding) async throws {
    let floats = ending == .floatingSourceFrameOnlySnap
    let fixture = try await carry(to: .tabbed, suspendedSample: (300, 420), floatsB2: floats)
    defer { fixture.model.shutdown() }
    let system = fixture.system, model = fixture.model, d = fixture.display, a1 = fixture.a1
    let b1 = WindowID(rawValue: "B1"), b2 = WindowID(rawValue: "B2")
    try #require(hasLayoutDrag(model), "The resumed drag did not start B's Tabbed drag")
    await system.advance(by: .milliseconds(100))
    let before = try #require(fixture.session?.tabbedState)
    // B's first pane holds B1 (and B2 unless the user floated it); the last pane is empty.
    try #require(before.panes.count == 2 && before.panes[1].tabs.isEmpty, "\(before.panes)")
    let group = before.panes[0], target = before.panes[1]
    try #require(group.tabs == (floats ? [b1] : [b1, b2]), "\(group)")
    try #require(before.floatingWindowIDs.contains(b2) == floats)
    let source = ending == .sameWindowAgain ? a1 : floats ? b2 : b1
    let sourceFrame = try #require(system.windows.first { $0.id == source }?.frame)
    let undoSteps = tabbedUndoStepCount(model)

    dropOnTabbedDestination(fixture, "addAsTab", target: target.id)
    try #require(!hasLayoutDrag(model), "The drop did not start its placement")
    // No await: the drop's placement task has not run.
    try #require(model.beginBentoDrag(displayID: d, sourceID: source, sourceFrame: sourceFrame),
                 "The new drag did not start")
    // Only a drag of A1 itself keeps A1's provisional float, as its own.
    #expect(fixture.session?.tabbedState?.floatingWindowIDs.contains(a1) == (ending == .sameWindowAgain),
            "The new drag's baseline is wrong about A1's provisional float")
    await system.advance(by: .milliseconds(100))
    try #require(hasLayoutDrag(model), "The new drag ended early")
    model.statusMessage = nil
    let rejection = "That pane cannot show this window."
    let snapFrame = BTRect(x: bounds.minX + 40, y: bounds.minY + 30, width: 920, height: 740)
    switch ending {
    case .addAsTab, .undoOfTheDrop:
        model.finishBentoDrag(displayID: d, sourceID: source, outcome: .tab(paneID: target.id, index: nil))
    case .invalidFeedback:
        model.finishBentoDrag(displayID: d, sourceID: source, end: .failed(reason: rejection))
    case .floatingSourceFrameOnlySnap:
        model.finishBentoDrag(displayID: d, sourceID: source, outcome: .snap(action: .almostMaximize, frame: snapFrame))
    case .sameWindowAgain:
        model.finishBentoDrag(displayID: d, sourceID: source, outcome: .restore)
    }
    try await settle(fixture)
    var state = try #require(fixture.session?.tabbedState)
    switch ending {
    case .addAsTab, .undoOfTheDrop:
        #expect(state.pane(containing: b1)?.id == target.id,
                "B1's drop did not land: \(state.panes) \(String(describing: model.statusMessage))")
    case .invalidFeedback:
        #expect(state.pane(containing: b1)?.id == group.id, "B1 did not return to its pane: \(state.panes)")
        #expect(state.pane(containing: b1)?.tabs.starts(with: group.tabs) == true, "\(state.panes)")
        #expect(!state.floatingWindowIDs.contains(b1), "B1 was left floating: \(state)")
        // A1's later arrival fills the empty pane, so B1's frame can change
        // after the rollback; a degraded rollback would name Repair Layout.
        #expect(model.statusMessage?.contains("Repair") != true, "\(String(describing: model.statusMessage))")
    case .floatingSourceFrameOnlySnap:
        #expect(state.floatingWindowIDs.contains(b2), "B2 is no longer the user's float: \(state)")
        #expect(!state.automaticallyFloatingWindowIDs.contains(b2))
        #expect(system.windows.first { $0.id == b2 }?.frame == snapFrame, "B2 did not take the snap frame")
    case .sameWindowAgain:
        #expect(state.panes.first { $0.id == group.id }?.tabs.starts(with: group.tabs) == true, "\(state.panes)")
    }
    #expect(fixture.session?.automaticWritesSuspended == false, "The new drag suspended automatic writes")
    #expect(!state.floatingWindowIDs.contains(a1), "A1 kept the provisional float: \(state)")
    #expect(state.windowIDs.contains(a1), "A1 did not arrive in a pane: \(state.panes)")
    #expect(before.windowIDs.isSubset(of: state.windowIDs))

    if ending == .undoOfTheDrop {
        try #require(tabbedUndoStepCount(model) == undoSteps + 1, "B1's drop added no Undo step")
        model.performTabbed(.undo)
        try await settle(fixture)
        state = try #require(fixture.session?.tabbedState)
        #expect(state.pane(containing: b1)?.id == group.id, "Undo did not return B1 to its pane: \(state.panes)")
        #expect(!state.floatingWindowIDs.contains(a1), "Undo restored A1's provisional float: \(state)")
        #expect(state.windowIDs.contains(a1), "A1 is in no pane after Undo: \(state.panes)")
    }
    #expect(provisionalFloatRecordCount(model) == 0, "A provisional-float record remained")
}

enum RecordLifecycleEnd: String, CustomStringConvertible, Sendable {
    /// The display goes away while the carried window's drag is held on B.
    case displayRemovedDuringTheDrag
    /// The display goes away while the carried window's drop placement waits.
    case displayRemovedBeforeThePlacement
    var description: String { rawValue }
}

/// Provisional-float records do not accumulate. Repeated drags on B, a
/// cancelled carried drop and a display removal each leave no record. A
/// record whose session ended with its display is removed at once, so it
/// cannot depend on its owner's end.
@Test(.appTestApplication, arguments: [RecordLifecycleEnd.displayRemovedDuringTheDrag, .displayRemovedBeforeThePlacement])
@MainActor func provisionalFloatRecordsEndWithTheirDragsAndDisplays(end: RecordLifecycleEnd) async throws {
    // The carried window's drop, cancelled by a newer drag, then several
    // ordinary drags on B: each end leaves no record.
    do {
        let fixture = try await carry(to: .tabbed, suspendedSample: (300, 420))
        defer { fixture.model.shutdown() }
        let model = fixture.model, d = fixture.display, b1 = WindowID(rawValue: "B1")
        try #require(hasLayoutDrag(model))
        #expect(provisionalFloatRecordCount(model) == 1, "The carried drag holds no record")
        await fixture.system.advance(by: .milliseconds(100))
        let target = try #require(fixture.session?.tabbedState?.panes.last)
        dropOnTabbedDestination(fixture, "addAsTab", target: target.id)
        try #require(model.beginBentoDrag(displayID: d, sourceID: b1), "B1's drag did not start")
        #expect(provisionalFloatRecordCount(model) == 0, "The cancelled drop kept its record")
        model.finishBentoDrag(displayID: d, sourceID: b1, outcome: .restore)
        try await settle(fixture)
        for index in 0..<4 {
            let shown = try #require(fixture.session?.tabbedState?.selectedWindowIDs.sorted { $0.rawValue < $1.rawValue })
            let window = shown[index % shown.count]
            try #require(model.beginBentoDrag(displayID: d, sourceID: window), "Drag \(index) did not start")
            if index.isMultiple(of: 2) {
                model.finishBentoDrag(displayID: d, sourceID: window, end: .failed(reason: "Invalid"))
            } else {
                model.finishBentoDrag(displayID: d, sourceID: window, outcome: .restore)
            }
            try await settle(fixture)
            #expect(provisionalFloatRecordCount(model) == 0, "Drag \(index) left a record")
        }
        #expect(fixture.session?.tabbedState?.windowIDs.contains(fixture.a1) == true)
    }
    // A display removal while a record is held.
    let fixture = try await carry(to: .tabbed, suspendedSample: (300, 420))
    defer { fixture.model.shutdown() }
    let system = fixture.system, model = fixture.model
    try #require(hasLayoutDrag(model))
    await system.advance(by: .milliseconds(100))
    let target = try #require(fixture.session?.tabbedState?.panes.last)
    if end == .displayRemovedBeforeThePlacement {
        dropOnTabbedDestination(fixture, "addAsTab", target: target.id)
        try #require(!hasLayoutDrag(model))
    }
    #expect(provisionalFloatRecordCount(model) == 1)
    system.availableDisplays = []
    system.windows = []
    system.desktopObservation?.currentSpaceByDisplay = [:]
    system.desktopObservation?.knownSpacesByDisplay = [:]
    model.handleApplicationTopologyChange()
    if end == .displayRemovedBeforeThePlacement {
        // The record ends with its session, before its placement task runs.
        #expect(provisionalFloatRecordCount(model) == 0, "The record outlived its session")
    }
    if end == .displayRemovedDuringTheDrag {
        fixture.send(.leftMouseUp, x: 300, y: 420)
        fixture.button.pressed = false
    }
    try await settle(fixture, for: .seconds(2))
    #expect(!hasLayoutDrag(model), "The drag outlived its display")
    #expect(provisionalFloatRecordCount(model) == 0, "A record outlived its display")
}

/// A same-desktop revision change ends an older carried drop. Its provisional
/// membership must be gone before a queued action captures its own revision.
@Test(.appTestApplication) @MainActor
func queuedTabbedActionStartsAfterStaleCarriedDropCleanup() async throws {
    let fixture = try await carry(to: .tabbed, suspendedSample: (300, 420))
    defer { fixture.model.shutdown() }
    let model = fixture.model
    let before = try #require(fixture.session)
    let target = try #require(before.tabbedState?.panes.last)
    let b1 = WindowID(rawValue: "B1")
    dropOnTabbedDestination(fixture, "addAsTab", target: target.id)
    try #require(model.hasPendingTabbedPlacement)
    try #require(provisionalFloatRecordCount(model) == 1)
    model.performTabbed(.move(b1, pane: target.id, index: nil, reselecting: nil))
    // Explicitly simulate an independent owner's failed rollback while the
    // placement is pending. This keeps the desktop and provisional record,
    // but advances its revision; no new drag consumes the record first.
    model.dividerResize.rollbackFailureHandler?(fixture.display, "Injected rollback failure")
    try #require(fixture.session?.id == before.id)
    try #require(fixture.session?.revision != before.revision)
    try #require(fixture.session?.automaticWritesSuspended == true)
    try #require(fixture.session?.tabbedState?.floatingWindowIDs.contains(fixture.a1) == true)
    try await settle(fixture)
    let state = try #require(fixture.session?.tabbedState)
    #expect(state.pane(containing: b1)?.id == target.id, "The queued move was discarded after capturing a dirty revision")
    #expect(!state.floatingWindowIDs.contains(fixture.a1))
    #expect(provisionalFloatRecordCount(model) == 0)
    model.performTabbed(.undo)
    try await settle(fixture)
    #expect(fixture.session?.tabbedState?.pane(containing: b1)?.id == before.tabbedState?.pane(containing: b1)?.id)
    #expect(fixture.session?.tabbedState?.floatingWindowIDs.contains(fixture.a1) == false,
            "The queued action's Undo captured provisional membership")
}

/// A closed peer invalidates the carried drop before its placement runs.
/// The next queued move must use the session after the drop's float cleanup.
@Test(.appTestApplication, arguments: ["addAsTab", "halfSnap"]) @MainActor
func aQueuedTabMoveSurvivesAnInvalidatedCarriedDrop(drop: String) async throws {
    let fixture = try await carry(to: .tabbed, suspendedSample: (300, 420))
    defer { fixture.model.shutdown() }
    let model = fixture.model, system = fixture.system
    try #require(hasLayoutDrag(model))
    try await settle(fixture, for: .milliseconds(100))
    let before = try #require(fixture.session?.tabbedState)
    let target = try #require(before.panes.last)
    let b1 = WindowID(rawValue: "B1"), b2 = WindowID(rawValue: "B2")
    let peer = try #require(system.windows.first { $0.id == b2 })
    let undoSteps = tabbedUndoStepCount(model)
    dropOnTabbedDestination(fixture, drop, target: target.id)
    try #require(model.hasPendingTabbedPlacement)
    model.performTabbed(.move(b1, pane: target.id, index: nil))
    system.windows.removeAll { $0.id == b2 }
    system.eventHandler?(WindowSystemEvent(kind: .destroyed, windowID: b2,
                                          processIdentifier: peer.processIdentifier))
    try await settle(fixture)
    let state = try #require(fixture.session?.tabbedState)
    #expect(state.paneID(containing: b1) == target.id, "The queued move was lost after carried-drop cleanup")
    #expect(state.windowIDs.contains(fixture.a1), "The carried window did not arrive")
    #expect(!state.floatingWindowIDs.contains(fixture.a1))
    #expect(!state.windowIDs.contains(b2))
    #expect(fixture.session?.automaticWritesSuspended == false)
    #expect(provisionalFloatRecordCount(model) == 0)
    #expect(tabbedUndoStepCount(model) == undoSteps + 1, "Only the queued move should add an Undo step")
    model.performTabbed(.undo)
    try await settle(fixture)
    let undone = try #require(fixture.session?.tabbedState)
    #expect(undone.paneID(containing: b1) == before.paneID(containing: b1))
    #expect(undone.windowIDs.contains(fixture.a1))
    #expect(!undone.floatingWindowIDs.contains(fixture.a1), "Undo restored the failed drop's provisional float")
    #expect(!undone.windowIDs.contains(b2), "Undo restored the closed peer")
}

// MARK: - Council round 1: degraded recovery and completion ordering

@Test(.appTestApplication, arguments: [CarryDestination.tabbed, .emptyAdaptive]) @MainActor
func aDegradedCarriedFrameSnapWaitsForRepair(destination: CarryDestination) async throws {
    let fixture = try await carry(to: destination, suspendedSample: (300, 420))
    defer { fixture.model.shutdown() }
    let model = fixture.model, system = fixture.system
    try await settle(fixture, for: .milliseconds(100))
    let owner = try #require(fixture.session?.id)
    let before = try #require(fixture.carriedFrame)
    let undoSteps = tabbedUndoStepCount(model)
    // Apply only the position, then fail both the forward write and rollback.
    system.failedFrameWriteNumbers[fixture.a1] = [1, 2]
    system.onFrameWrite = { id, frame in
        guard id == fixture.a1, system.frameWriteCounts[id] == 1,
              let index = system.windows.firstIndex(where: { $0.id == id }) else { return }
        system.windows[index].frame.origin = frame.origin
    }
    fixture.send(.leftMouseDragged, x: 500, y: 0)
    fixture.drag.displayTick()
    switch fixture.drag.dropTarget?.drop {
    case let .layout(prepared):
        guard case let .snap(action, _) = prepared.outcome else {
            Issue.record("No layout snap at the top edge"); return
        }
        try #require(!BentoDropPlanner.partitionActions.contains(action))
    case .snap:
        try #require(destination == .emptyAdaptive)
    default:
        Issue.record("No frame-only snap at the top edge"); return
    }
    fixture.send(.leftMouseUp, x: 500, y: 0)
    fixture.button.pressed = false
    system.onFrameWrite = nil
    try #require(system.frameWriteCounts[fixture.a1] == 2, "Forward write and rollback must both run")
    try #require(fixture.carriedFrame != before, "The rollback unexpectedly restored the window")
    #expect(fixture.session?.id == owner)
    #expect(fixture.session?.automaticWritesSuspended == true, "An incomplete rollback must suspend its owner")
    #expect(model.statusMessage?.contains("Repair Layout") == true)
    #expect(provisionalFloatRecordCount(model) == 0)
    if destination == .tabbed {
        #expect(fixture.session?.tabbedState?.floatingWindowIDs.contains(fixture.a1) == false)
    }
    #expect(tabbedUndoStepCount(model) == undoSteps)
    let writes = system.frameWriteCounts
    let frames = system.windows.map(\.frame)
    system.failedFrameWriteNumbers = [:]
    model.handleApplicationTopologyChange()
    try await settle(fixture)
    model.watchdog()
    try await settle(fixture)
    #expect(system.frameWriteCounts == writes, "Automatic reconciliation wrote after a degraded snap")
    #expect(system.windows.map(\.frame) == frames)
    #expect(fixture.session?.automaticWritesSuspended == true)
    #expect(tabbedUndoStepCount(model) == undoSteps)
    model.repairCurrentLayout()
    try await settle(fixture)
    #expect(fixture.session?.automaticWritesSuspended == false)
    #expect(system.frameWriteCounts != writes, "Repair must resume placement")
    #expect(fixture.session?.windowIDs.contains(fixture.a1) == true)
}

@Test(.appTestApplication, arguments: [false, true]) @MainActor
func aWorkAreaRefreshStartsAfterCarriedDropCleanup(afterWrite: Bool) async throws {
    let fixture = try await carry(to: .tabbed, suspendedSample: (300, 420))
    defer { fixture.model.shutdown() }
    let model = fixture.model, system = fixture.system
    try await settle(fixture, for: .milliseconds(100))
    let target = try #require(fixture.session?.tabbedState?.panes.last)
    var changedWorkArea = false
    var recordsAtRefresh: Int?
    system.onFrameWrite = { id, _ in
        guard afterWrite, id == fixture.a1, !changedWorkArea else { return }
        changedWorkArea = true
        system.availableDisplays[0].visibleFrame.size.width -= 100
    }
    system.onVisibleWindowSweep = { _ in
        guard changedWorkArea, !model.hasPendingTabbedPlacement, recordsAtRefresh == nil else { return }
        recordsAtRefresh = provisionalFloatRecordCount(model)
    }
    defer { system.onFrameWrite = nil; system.onVisibleWindowSweep = nil; system.onWindowSnapshots = nil }
    dropOnTabbedDestination(fixture, "addAsTab", target: target.id)
    if !afterWrite {
        // The task has not run: change the work area on its preflight read,
        // before it can mutate a frame or require rollback.
        try #require(model.hasPendingTabbedPlacement && system.frameWriteCounts[fixture.a1] == nil)
        system.onWindowSnapshots = {
            guard !changedWorkArea else { return }
            changedWorkArea = true
            system.availableDisplays[0].visibleFrame.size.width -= 100
        }
    }
    try await settle(fixture)
    try #require(changedWorkArea, "The work-area change did not reach the placement")
    #expect(recordsAtRefresh == 0, "The work-area refresh captured provisional membership")
    #expect(provisionalFloatRecordCount(model) == 0)
    if afterWrite {
        // A write already landed in the old work area. Preserve its degraded
        // recovery instead of allowing the refresh to move windows again.
        #expect(fixture.session?.automaticWritesSuspended == true)
        let writes = system.frameWriteCounts
        model.watchdog()
        try await settle(fixture)
        #expect(system.frameWriteCounts == writes)
        model.performTabbed(.repair)
        try await settle(fixture)
    }
    #expect(fixture.session?.lastWorkArea == system.availableDisplays[0].visibleFrame)
    #expect(fixture.session?.tabbedState?.windowIDs.contains(fixture.a1) == true)
    #expect(fixture.session?.automaticWritesSuspended == false)
}
