import Foundation
import Testing
@testable import BetterTileCore

struct DesktopRetirementCouncilTests {
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

}
