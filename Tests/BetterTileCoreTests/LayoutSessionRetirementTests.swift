import Foundation
import Testing
@testable import BetterTileCore

struct LayoutSessionRetirementTests {
    let old = DisplayID(rawValue: "old")
    let new = DisplayID(rawValue: "new")
    let a = WindowID(rawValue: "a")
    let b = WindowID(rawValue: "b")
    let c = WindowID(rawValue: "c")

    func activate(_ store: inout LayoutSessionStore, display: DisplayID, space: UInt64,
                  windows: Set<WindowID>, uuid: String? = "screen", carry: Bool = true) -> LayoutSession {
        store.activate(displayID: display, windowIDs: windows, focusedWindowID: windows.sorted().first,
            defaultMode: .manual, reuseActiveWhenUnmatched: false,
            nativeSpaceID: NativeSpaceID(rawValue: space), displayIdentifier: uuid, carryOver: carry).session
    }

    @Test func restoresChangedDisplayAndSpaceWithoutOldGeometry() throws {
        var store = LayoutSessionStore()
        let original = activate(&store, display: old, space: 1, windows: [a, b])
        var tabbed = TabbedLayoutState(preset: .columns)
        tabbed.reconcile(windowIDs: [a, b], removed: [], focused: a)
        let frame = BTRect(x: 0, y: 0, width: 1000, height: 800)
        let anchor = BentoReinsertionAnchor(neighborWindowID: a, edge: .right, layoutBefore: tabbed.layout)
        store.update(old) {
            $0.mode = .tabbed
            $0.tabbedState = tabbed
            $0.tabbedBaselineFrames = [a: frame]
            $0.tabbedHasEntryBaseline = true
            $0.lastWorkArea = frame
            $0.bentoReinsertionAnchors[c] = anchor
            if case .partition(var partition)? = $0.bentoState.root {
                partition.ratios = [0.3, 0.7]
                $0.bentoState.root = .partition(partition)
            }
        }
        let remembered = store.session(for: old)?.tabbedState
        store.removeMissingDisplays([], at: 10)
        #expect(store.sessions.isEmpty)
        #expect(store.retiredSessions.count == 1)
        let restored = activate(&store, display: new, space: 2, windows: [a, b])
        #expect(restored.id == original.id)
        #expect(restored.displayID == new)
        #expect(restored.nativeSpaceID == NativeSpaceID(rawValue: 2))
        #expect(restored.mode == .tabbed)
        #expect(restored.tabbedState == remembered)
        #expect(restored.bentoReinsertionAnchors[c] == anchor)
        #expect(restored.lastWorkArea == nil)
        #expect(restored.lastObservedFrames.isEmpty)
        #expect(restored.tabbedBaselineFrames.isEmpty)
        #expect(restored.tabbedHasEntryBaseline)
        #expect(store.retiredSessions.isEmpty)
    }

    @Test(arguments: [true, false]) func carryOverChoosesOtherScreenOnlyWhenEnabled(carry: Bool) {
        var store = LayoutSessionStore()
        _ = activate(&store, display: old, space: 1, windows: [a, b])
        store.update(old) { $0.mode = .bento }
        store.removeMissingDisplays([], at: 1)
        let moved = activate(&store, display: new, space: 2, windows: [a, b], uuid: "other", carry: carry)
        #expect(moved.mode == (carry ? .bento : .manual))
        store.removeMissingDisplays([], at: 2)
        let returned = activate(&store, display: old, space: 3, windows: [a, b], carry: carry)
        #expect(returned.mode == .bento)
    }

    @Test func selectedPlaceholderRestoresOnFirstObservation() {
        var store = LayoutSessionStore()
        let original = activate(&store, display: old, space: 1, windows: [a, b])
        store.update(old) { $0.mode = .tabbed }
        store.removeMissingNativeSpaces([old: [NativeSpaceID(rawValue: 2)]], at: 1)
        let placeholder = store.select(displayID: old, nativeSpaceID: NativeSpaceID(rawValue: 2), defaultMode: .manual)
        let restored = activate(&store, display: old, space: 2, windows: [a, b])
        #expect(restored.id == original.id)
        #expect(restored.mode == .tabbed)
        #expect(store.allSessions(for: old).count == 1)
        #expect(restored.id != placeholder.id)
    }

    @Test func emptyAndBelowHalfOverlapDoNotMatch() {
        var store = LayoutSessionStore()
        _ = activate(&store, display: old, space: 1, windows: [a])
        store.removeMissingDisplays([], at: 1)
        #expect(store.restoreRetired(on: new, identifier: "screen", windowIDs: [], carryOver: true) == nil)
        #expect(store.restoreRetired(on: new, identifier: "screen", windowIDs: [a, b, c], carryOver: true) == nil)
        #expect(store.restoreRetired(on: new, identifier: "screen", windowIDs: [a, b], carryOver: true) != nil)
    }

    @Test func unknownUUIDIsNotASameScreenMatch() {
        var store = LayoutSessionStore()
        _ = activate(&store, display: old, space: 1, windows: [a], uuid: nil)
        store.removeMissingDisplays([], at: 1)
        #expect(store.restoreRetired(on: old, identifier: nil, windowIDs: [a], carryOver: false) == nil)
    }

    @Test func sameUUIDFiltersCandidatesWhenCarryOverIsOff() throws {
        var store = LayoutSessionStore()
        let original = activate(&store, display: old, space: 1, windows: [a, b])
        store.removeMissingDisplays([], at: 1)
        // Off keeps the first screen's history parked while the other gets defaults.
        _ = activate(&store, display: new, space: 2, windows: [a, b], uuid: "other", carry: false)
        store.removeMissingDisplays([], at: 2)
        let candidate = store.restoreRetired(on: old, identifier: "screen", windowIDs: [a, b], carryOver: false)
        let match = try #require(candidate)
        #expect(match.id == original.id)
        #expect(store.lastRestoration?.sameDisplay == true)
    }

    @Test func retirementIsCappedAtThirtyTwoOldestFirst() {
        var store = LayoutSessionStore()
        for i in 0..<35 {
            _ = activate(&store, display: old, space: UInt64(i + 1), windows: [WindowID(rawValue: "w-\(i)")])
            store.removeMissingDisplays([], at: Double(i))
        }
        #expect(store.retiredSessions.count == 32)
        #expect(store.retiredSessions.first?.retiredAt == 3)
        #expect(store.retiredSessions.last?.retiredAt == 34)
    }

    @Test func restoredFallbackSessionKeepsItsModeWhenNativeIdentityArrives() {
        var store = LayoutSessionStore()
        let original = activate(&store, display: old, space: 1, windows: [a, b])
        store.update(old) { $0.mode = .bento }
        store.removeMissingDisplays([], at: 1)
        let fallback = store.activate(displayID: new, windowIDs: [a, b], focusedWindowID: a,
            defaultMode: .manual, reuseActiveWhenUnmatched: false, displayIdentifier: "screen").session
        #expect(fallback.id == original.id && fallback.mode == .bento)
        store.select(displayID: new, nativeSpaceID: NativeSpaceID(rawValue: 2), defaultMode: .manual)
        let native = activate(&store, display: new, space: 2, windows: [a, b])
        #expect(native.id == original.id, "Late native metadata must adopt the restored runtime owner")
        #expect(native.mode == .bento)
    }
}
