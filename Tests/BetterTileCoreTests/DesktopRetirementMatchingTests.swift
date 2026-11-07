import Foundation
import Testing
@testable import BetterTileCore

struct DesktopRetirementMatchingTests {
    let a = WindowID(rawValue: "a"), b = WindowID(rawValue: "b"), c = WindowID(rawValue: "c")
    let old = DisplayID(rawValue: "old"), new = DisplayID(rawValue: "new")
    func activate(_ store: inout LayoutSessionStore, _ display: DisplayID, _ space: UInt64,
                  _ windows: Set<WindowID>, uuid: String, carry: Bool = true, defaultMode: LayoutMode = .manual) -> LayoutSession {
        store.activate(displayID: display, windowIDs: windows, focusedWindowID: windows.sorted().first,
            defaultMode: defaultMode, reuseActiveWhenUnmatched: false, nativeSpaceID: NativeSpaceID(rawValue: space),
            displayIdentifier: uuid, carryOver: carry).session
    }

    @Test(arguments: [false, true], [false, true])
    func retiredTabsReceiveLifecycleEvents(closed: Bool, missingSpace: Bool) throws {
        var store = LayoutSessionStore()
        let original = activate(&store, old, 1, [a, b], uuid: "A")
        var tabs = TabbedLayoutState(preset: .single)
        tabs.reconcile(windowIDs: [a, b], removed: [], focused: b)
        let baseline = BTRect(x: 20, y: 20, width: 400, height: 300)
        store.update(old) { $0.mode = .tabbed; $0.tabbedState = tabs; $0.tabbedBaselineFrames[b] = baseline }
        if missingSpace { store.removeMissingNativeSpaces([old: [NativeSpaceID(rawValue: 2)]], at: 1) }
        else { store.removeMissingDisplays([], at: 1) }
        _ = activate(&store, new, 2, [a, b], uuid: "B", carry: false)
        if closed { store.removeClosedTabbedWindow(b) } else { store.removeMinimizedTabbedWindow(b) }
        let retired = try #require(store.retiredSessions.first { $0.session.id == original.id })
        #expect(retired.session.tabbedState?.windowIDs == [a])
        #expect(retired.session.tabbedState?.activeWindowID == a)
        #expect(retired.session.tabbedBaselineFrames[b] == (closed ? nil : baseline))
        #expect(retired.windowIDs.contains(b) == !closed)
        store.removeMissingDisplays([], at: 2)
        let restored = activate(&store, old, 3, [a], uuid: "A", carry: false)
        #expect(restored.id == original.id)
        #expect(restored.tabbedState?.windowIDs == [a])
        #expect(restored.tabbedState?.activeWindowID == a)
    }

    @Test(arguments: [false, true]) func enablingCarryOverUsesNewestCopyAndRemovesSupersededCopies(offRoundTrip: Bool) {
        var store = LayoutSessionStore()
        let original = activate(&store, old, 1, [a, b], uuid: "A", carry: false)
        store.update(old) { $0.mode = .bento }
        store.removeMissingDisplays([], at: 1)
        _ = activate(&store, new, 2, [a, b], uuid: "B", carry: false)
        if offRoundTrip {
            store.removeMissingDisplays([], at: 2)
            #expect(activate(&store, old, 3, [a, b], uuid: "A", carry: false).mode == .bento)
        }
        let current = store.session(for: offRoundTrip ? old : new)
        store.removeMissingDisplays([], at: 3)
        let carried = activate(&store, offRoundTrip ? new : old, 4, [a, b], uuid: offRoundTrip ? "B" : "A", carry: true)
        #expect(carried.mode == current?.mode)
        #expect(carried.id == current?.id)
        #expect(offRoundTrip ? carried.id == original.id : carried.id != original.id)
        #expect(store.retiredSessions.isEmpty)
    }

    @Test(arguments: [false, true], [false, true])
    func movedWindowDoesNotPruneAnotherRetiredDesktop(carryOver: Bool, destinationFirst: Bool) throws {
        var store = LayoutSessionStore()
        let source = activate(&store, old, 1, [a, b, c], uuid: "A", carry: carryOver)
        store.update(old) { $0.mode = .bento }
        // The source is inactive when b moves, so its old membership still has b.
        let destination = activate(&store, old, 2, [b], uuid: "A", carry: carryOver)
        store.update(old) { $0.mode = .tabbed }
        store.removeMissingDisplays([], at: 1)
        let sourceSpace: UInt64 = 11, destinationSpace: UInt64 = 22
        for isDestination in [destinationFirst, !destinationFirst] {
            let returned = activate(&store, new, isDestination ? destinationSpace : sourceSpace,
                isDestination ? [b] : [a, c], uuid: "A", carry: carryOver)
            #expect(returned.id == (isDestination ? destination.id : source.id))
            #expect(returned.mode == (isDestination ? .tabbed : .bento))
        }
        let sessions = store.allSessions(for: new)
        #expect(sessions.first { $0.id == source.id }?.mode == .bento)
        #expect(sessions.first { $0.id == destination.id }?.mode == .tabbed)
    }

    /// macOS can merge the windows of two desktops onto one desktop of the new
    /// screen. Carrying the first desktop there must not delete the second
    /// desktop's memory, and both must return to their own desktops later.
    @Test(arguments: [false, true])
    func carryingMergedDesktopsKeepsEachDesktopsMemory(firstDesktopFirst: Bool) {
        var store = LayoutSessionStore()
        let first = activate(&store, old, 1, [a, b], uuid: "A")
        store.update(old) { $0.mode = .bento }
        let second = activate(&store, old, 2, [c], uuid: "A")
        store.update(old) { $0.mode = .tabbed }
        store.removeMissingDisplays([], at: 1)
        let merged = activate(&store, new, 21, [a, b, c], uuid: "B")
        #expect(merged.id == first.id && merged.mode == .bento)
        #expect(store.retiredSessions.map(\.session.id) == [second.id])
        store.removeMissingDisplays([], at: 2)
        let returned = DisplayID(rawValue: "returned")
        for isFirst in [firstDesktopFirst, !firstDesktopFirst] {
            let session = activate(&store, returned, isFirst ? 31 : 32, isFirst ? [a, b] : [c], uuid: "A")
            #expect(session.id == (isFirst ? first.id : second.id))
            #expect(session.mode == (isFirst ? .bento : .tabbed))
        }
    }

    @Test func anEmptyLookDoesNotMakeLaterArrivalsANewDesktop() {
        var store = LayoutSessionStore()
        let empty = store.activate(displayID: old, windowIDs: [], focusedWindowID: nil,
            defaultMode: .bento, reuseActiveWhenUnmatched: true, nativeSpaceID: .init(rawValue: 1))
        #expect(empty.wasCreated)
        let arrival = store.activate(displayID: old, windowIDs: [a, b], focusedWindowID: a,
            defaultMode: .bento, reuseActiveWhenUnmatched: true, nativeSpaceID: .init(rawValue: 1))
        #expect(arrival.session.id == empty.session.id)
        #expect(!arrival.wasCreated)
        #expect(arrival.previousWindowIDs.isEmpty)
    }

    @Test func overlapTiePrefersTheDesktopCoveredMostFully() {
        var store = LayoutSessionStore()
        _ = activate(&store, old, 1, [a, b, c], uuid: "A", carry: false)
        store.update(old) { $0.mode = .bento }
        _ = activate(&store, old, 2, [c], uuid: "A", carry: false)
        store.update(old) { $0.mode = .tabbed }
        store.removeMissingDisplays([], at: 1)
        #expect(activate(&store, new, 3, [c], uuid: "B").mode == .tabbed)
        #expect(store.retiredSessions.count == 1)
    }

    @Test func retirementAndEqualScoreSelectionHaveAFixedOrder() throws {
        var store = LayoutSessionStore()
        _ = activate(&store, old, 1, [a], uuid: "A", carry: false)
        _ = activate(&store, old, 2, [a], uuid: "A", carry: false)
        let ordered = store.allSessions(for: old).map(\.id).sorted { $0.rawValue.uuidString < $1.rawValue.uuidString }
        store.removeMissingDisplays([], at: 1)
        #expect(store.retiredSessions.map { $0.session.id } == ordered)
        let candidate = store.restoreRetired(on: new, identifier: "B", windowIDs: [a], carryOver: true)
        let restored = try #require(candidate)
        #expect(restored.id == ordered.first)
    }

    @Test(arguments: [LayoutMode.manual, .bento, .tabbed])
    func anEmptyFirstObservationKeepsTheRestorationOpportunity(defaultMode: LayoutMode) {
        var store = LayoutSessionStore()
        let original = activate(&store, old, 1, [a], uuid: "A")
        store.update(old) { $0.mode = .bento }
        store.removeMissingDisplays([], at: 1)
        _ = activate(&store, new, 2, [], uuid: "B", defaultMode: defaultMode)
        if defaultMode == .tabbed { store.update(new) { $0.tabbedState = TabbedLayoutState(preset: .columns) } }
        let restored = activate(&store, new, 2, [a], uuid: "B", defaultMode: defaultMode)
        #expect(restored.id == original.id && restored.mode == .bento)
    }

    @Test func anExplicitModeChangeEndsAnEmptyRestorationOpportunity() {
        var store = LayoutSessionStore()
        _ = activate(&store, old, 1, [a], uuid: "A")
        store.update(old) { $0.mode = .bento }
        store.removeMissingDisplays([], at: 1)
        _ = activate(&store, new, 2, [], uuid: "B")
        store.update(new) { $0.mode = .tabbed }
        #expect(activate(&store, new, 2, [a], uuid: "B").mode == .tabbed)
    }

    @Test func emptyDesktopsDoNotEvictUsefulRetiredSessions() {
        var store = LayoutSessionStore()
        let original = activate(&store, old, 1, [a], uuid: "A")
        store.removeMissingDisplays([], at: 1)
        for i in 2...40 {
            _ = activate(&store, new, UInt64(i), [], uuid: "B")
            store.removeMissingDisplays([], at: Double(i))
        }
        #expect(store.retiredSessions.map { $0.session.id } == [original.id])
    }
    @Test func aRecoveryFailureStillSuspendsItsRetiredOwner() throws {
        var store = LayoutSessionStore()
        let original = activate(&store, old, 1, [a], uuid: "A")
        store.removeMissingDisplays([], at: 1)
        store.suspendAutomaticWrites(sessionID: original.id, on: old)
        let candidate = store.restoreRetired(on: new, identifier: "A", windowIDs: [a], carryOver: true)
        let restored = try #require(candidate)
        #expect(restored.automaticWritesSuspended)
    }

    @Test func choosingTheExistingDefaultModeEndsRestoration() {
        var store = LayoutSessionStore()
        _ = activate(&store, old, 1, [a], uuid: "A")
        store.update(old) { $0.mode = .bento }
        store.removeMissingDisplays([], at: 1)
        _ = activate(&store, new, 2, [], uuid: "B")
        store.endRestorationOpportunity(on: new)
        #expect(activate(&store, new, 2, [a], uuid: "B").mode == .manual)
    }

    @Test func retiredBookkeepingCannotResurrectAClosedIdentity() throws {
        var store = LayoutSessionStore()
        var original = activate(&store, old, 1, [a, b], uuid: "A")
        store.removeMissingDisplays([], at: 1)
        original.mode = .tabbed
        let first = store.commitRetiredBookkeeping(original, replacing: original.revision)
        var proposed = try #require(first)
        store.removeClosedTabbedWindow(b)
        proposed.lastObservedFrames[b] = BTRect(x: 0, y: 0, width: 100, height: 100)
        let stale = store.commitRetiredBookkeeping(proposed, replacing: proposed.revision)
        #expect(stale == nil)
        #expect(store.retiredSessions.first?.windowIDs.contains(b) == false)
    }


    /// A second settled screen setup that still shows both desktops' windows
    /// together. The first merge taught the carried desktop the other
    /// desktop's windows; that must not make the other desktop look like a
    /// copy of it, nor make the carried desktop the better match for the
    /// other desktop's windows. `.minimize` keeps the window as evidence.
    @Test(arguments: RepeatedMergeCase.all)
    func aSecondMergedScreenSetupKeepsTheOtherDesktopsMemory(_ run: RepeatedMergeCase) throws {
        let d = WindowID(rawValue: "d"), e = WindowID(rawValue: "e")
        let merged = DisplayID(rawValue: "merged"), mergedAgain = DisplayID(rawValue: "merged-again")
        let returned = DisplayID(rawValue: "returned")
        // The model stages each observation and then commits it.
        func observe(_ store: inout LayoutSessionStore, _ display: DisplayID, _ space: UInt64,
                     _ windows: Set<WindowID>, uuid: String) throws -> LayoutSession {
            let activation = store.activate(displayID: display, windowIDs: windows, focusedWindowID: windows.sorted().first,
                defaultMode: .manual, reuseActiveWhenUnmatched: false, commitObservation: false,
                nativeSpaceID: NativeSpaceID(rawValue: space), displayIdentifier: uuid, carryOver: run.carry)
            let committed = store.commit(activation.session, replacing: activation.session.revision)
            return try #require(committed)
        }
        var store = LayoutSessionStore()
        let first = try observe(&store, old, 1, [a, b, e], uuid: "A")
        store.update(old) { $0.mode = .bento }
        let second = try observe(&store, old, 2, [c, d], uuid: "A")
        var tabs = TabbedLayoutState(preset: .single)
        tabs.reconcile(windowIDs: [c, d], removed: [], focused: d)
        store.update(old) { $0.mode = .tabbed; $0.tabbedState = tabs }
        store.removeMissingDisplays([], at: 1)
        _ = try observe(&store, merged, 11, [a, b, c, d, e], uuid: "B")
        switch run.event {
        case .none, .move: break
        case .close: store.removeClosedTabbedWindow(d)
        case .minimize: store.removeMinimizedTabbedWindow(d)
        }
        let visible: Set<WindowID> = [.none, .move].contains(run.event) ? [a, b, c, d, e] : [a, b, c, e]
        _ = try observe(&store, merged, 11, visible, uuid: "B")
        store.removeMissingDisplays([], at: 2)
        _ = try observe(&store, mergedAgain, 21, visible, uuid: "B")
        #expect(store.retiredSessions.contains { $0.session.id == second.id },
                "The second merge deleted the independent desktop: \(store.retiredSessions.map(\.windowIDs))")
        store.removeMissingDisplays([], at: 3)
        // `.move`: in Mission Control the user moved b to the second desktop.
        let firstWindows: Set<WindowID> = run.event == .move ? [a, e] : [a, b, e]
        let secondWindows: Set<WindowID> = switch run.event {
        case .none: [c, d]
        case .move: [b, c, d]
        case .close, .minimize: [c]
        }
        for isFirst in [run.firstDesktopFirst, !run.firstDesktopFirst] {
            let session = try observe(&store, returned, isFirst ? 31 : 32, isFirst ? firstWindows : secondWindows, uuid: "A")
            #expect(session.id == (isFirst ? first.id : second.id), "\(isFirst ? "first" : "second") desktop lost its owner")
            #expect(session.mode == (isFirst ? .bento : .tabbed))
        }
    }

    /// With carry-over off, a restore keeps the other screen's copy of the
    /// same desktop on purpose. A window opened on that screen is not merged
    /// into the restored desktop, so turning carry-over on later still finds
    /// the newest copy.
    @Test func carryOverOffDoesNotTreatTheOtherScreensWindowsAsMerged() throws {
        let laptop = DisplayID(rawValue: "laptop"), dock = DisplayID(rawValue: "dock")
        let laptopAgain = DisplayID(rawValue: "laptop-again"), dockAgain = DisplayID(rawValue: "dock-again")
        func observe(_ store: inout LayoutSessionStore, _ display: DisplayID, _ space: UInt64,
                     _ windows: Set<WindowID>, uuid: String, carry: Bool) throws -> LayoutSession {
            let activation = store.activate(displayID: display, windowIDs: windows, focusedWindowID: windows.sorted().first,
                defaultMode: .manual, reuseActiveWhenUnmatched: false, commitObservation: false,
                nativeSpaceID: NativeSpaceID(rawValue: space), displayIdentifier: uuid, carryOver: carry)
            let committed = store.commit(activation.session, replacing: activation.session.revision)
            return try #require(committed)
        }
        var store = LayoutSessionStore()
        let laptopDesktop = try observe(&store, laptop, 1, [a], uuid: "A", carry: false)
        store.update(laptop) { $0.mode = .bento }
        store.removeMissingDisplays([], at: 1)
        let dockDesktop = try observe(&store, dock, 11, [a], uuid: "B", carry: false)
        #expect(dockDesktop.id != laptopDesktop.id)
        _ = try observe(&store, dock, 11, [a, c], uuid: "B", carry: false)
        store.removeMissingDisplays([], at: 2)
        let back = try observe(&store, laptopAgain, 21, [a, c], uuid: "A", carry: false)
        #expect(back.id == laptopDesktop.id)
        #expect(back.mode == .bento)
        store.removeMissingDisplays([], at: 3)
        let docked = try observe(&store, dockAgain, 31, [a, c], uuid: "B", carry: true)
        #expect(docked.id == laptopDesktop.id, "Carry-over must take the newest copy")
        #expect(docked.mode == .bento)
    }
}

enum RepeatedMergeEvent: String, Sendable { case none, close, minimize, move }

struct RepeatedMergeCase: Sendable, CustomTestStringConvertible {
    var carry: Bool
    var firstDesktopFirst: Bool
    var event: RepeatedMergeEvent
    var testDescription: String { "carry \(carry), first desktop first \(firstDesktopFirst), \(event.rawValue)" }
    static let all: [RepeatedMergeCase] = [false, true].flatMap { carry in
        [false, true].flatMap { order in
            [RepeatedMergeEvent.none, .close, .minimize, .move].map { RepeatedMergeCase(carry: carry, firstDesktopFirst: order, event: $0) }
        }
    }
}
