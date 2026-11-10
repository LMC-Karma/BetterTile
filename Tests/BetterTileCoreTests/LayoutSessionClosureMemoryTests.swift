import Foundation
import Testing
@testable import BetterTileCore

struct LayoutSessionClosureMemoryTests {
    @Test func anUnidentifiedEmptyDesktopKeepsItsChosenModeWithoutClosureEvidence() {
        let display = DisplayID(rawValue: "main")
        var store = LayoutSessionStore()
        let empty = store.activate(displayID: display, windowIDs: [], focusedWindowID: nil,
            defaultMode: .tabbed, reuseActiveWhenUnmatched: false).session
        _ = store.activate(displayID: display, windowIDs: [.init(rawValue: "other")], focusedWindowID: nil,
            defaultMode: .manual, reuseActiveWhenUnmatched: false)
        let returned = store.activate(displayID: display, windowIDs: [], focusedWindowID: nil,
            defaultMode: .manual, reuseActiveWhenUnmatched: false).session
        #expect(returned.id == empty.id)
        #expect(returned.mode == .tabbed)
    }

    /// Closing a desktop's last window does not prove that the desktop
    /// ended. A return to it while it is empty restores its chosen mode.
    @Test(arguments: [LayoutMode.tabbed, .manual])
    func anEmptiedUnidentifiedDesktopKeepsItsChosenModeWhenTheUserReturns(mode: LayoutMode) throws {
        let display = DisplayID(rawValue: "main")
        let closed = WindowID(rawValue: "closed"), other = WindowID(rawValue: "other")
        var store = LayoutSessionStore()
        let chosen = store.activate(displayID: display, windowIDs: [closed], focusedWindowID: closed,
            defaultMode: .bento, reuseActiveWhenUnmatched: false).session
        var tabs = TabbedLayoutState(preset: .columns)
        tabs.reconcile(windowIDs: [closed], removed: [], focused: closed)
        store.update(display) {
            $0.mode = mode
            if mode == .tabbed { $0.tabbedState = tabs }
        }
        store.removeClosedTabbedWindow(closed)
        _ = store.refresh(displayID: display, windowIDs: [], focusedWindowID: nil, defaultMode: .bento)
        _ = store.activate(displayID: display, windowIDs: [other], focusedWindowID: other,
            defaultMode: .bento, reuseActiveWhenUnmatched: false)
        #expect(store.allSessions(for: display).count == 2)
        let returned = store.activate(displayID: display, windowIDs: [], focusedWindowID: nil,
            defaultMode: .bento, reuseActiveWhenUnmatched: false).session
        #expect(returned.id == chosen.id)
        #expect(returned.mode == mode)
        if mode == .tabbed { #expect(returned.tabbedState?.groups.panes.count == 2) }
    }

    /// Emptied desktops stay bounded: each display keeps only the newest one.
    /// Tabbed removes a closed window from an inactive desktop's membership,
    /// so each cohort below empties while another desktop is active.
    @Test func emptiedUnidentifiedDesktopsKeepOnlyTheNewestOnePerDisplay() throws {
        let display = DisplayID(rawValue: "main")
        let hidden = WindowID(rawValue: "hidden-control")
        var store = LayoutSessionStore()
        let control = store.activate(displayID: display, windowIDs: [hidden], focusedWindowID: hidden,
            defaultMode: .bento, reuseActiveWhenUnmatched: false).session
        var newest: LayoutSession?
        for index in 0..<1_000 {
            let window = WindowID(rawValue: "window-\(index)")
            newest = store.activate(displayID: display, windowIDs: [window], focusedWindowID: window,
                defaultMode: .tabbed, reuseActiveWhenUnmatched: false).session
            var tabs = TabbedLayoutState(preset: .single)
            tabs.reconcile(windowIDs: [window], removed: [], focused: window)
            store.update(display) { $0.tabbedState = tabs }
            _ = store.activate(displayID: display, windowIDs: [hidden], focusedWindowID: hidden,
                defaultMode: .bento, reuseActiveWhenUnmatched: false)
            store.removeClosedTabbedWindow(window)
            #expect(store.allSessions(for: display).count == 2)
        }
        let kept = try #require(newest)
        #expect(Set(store.allSessions(for: display).map(\.id)) == [control.id, kept.id])
        let returned = store.activate(displayID: display, windowIDs: [], focusedWindowID: nil,
            defaultMode: .bento, reuseActiveWhenUnmatched: false).session
        #expect(returned.id == kept.id)
        #expect(returned.mode == .tabbed)
        let markers = Mirror(reflecting: store).children.first { $0.label == "closedInferredWindowIDs" }?.value
        #expect((markers as? any Collection)?.count == 0)
    }

    /// A kept empty desktop that the user changed after it emptied is not
    /// released when another desktop empties.
    @Test func anEmptiedDesktopChangedAfterItEmptiedIsNotReleasedByANewerOne() throws {
        let display = DisplayID(rawValue: "main")
        let first = WindowID(rawValue: "first"), second = WindowID(rawValue: "second")
        let hidden = WindowID(rawValue: "hidden-control")
        var store = LayoutSessionStore()
        _ = store.activate(displayID: display, windowIDs: [hidden], focusedWindowID: hidden,
            defaultMode: .bento, reuseActiveWhenUnmatched: false)
        let changed = store.activate(displayID: display, windowIDs: [first], focusedWindowID: first,
            defaultMode: .manual, reuseActiveWhenUnmatched: false).session
        store.removeClosedTabbedWindow(first)
        _ = store.refresh(displayID: display, windowIDs: [], focusedWindowID: nil, defaultMode: .bento)
        _ = store.activate(displayID: display, windowIDs: [hidden], focusedWindowID: hidden,
            defaultMode: .bento, reuseActiveWhenUnmatched: false)
        _ = store.activate(displayID: display, windowIDs: [], focusedWindowID: nil,
            defaultMode: .bento, reuseActiveWhenUnmatched: false)
        store.update(display) { $0.mode = .tabbed }
        _ = store.activate(displayID: display, windowIDs: [second], focusedWindowID: second,
            defaultMode: .tabbed, reuseActiveWhenUnmatched: false)
        var tabs = TabbedLayoutState(preset: .single)
        tabs.reconcile(windowIDs: [second], removed: [], focused: second)
        store.update(display) { $0.tabbedState = tabs }
        _ = store.activate(displayID: display, windowIDs: [hidden], focusedWindowID: hidden,
            defaultMode: .bento, reuseActiveWhenUnmatched: false)
        store.removeClosedTabbedWindow(second)
        let kept = try #require(store.allSessions(for: display).first { $0.id == changed.id })
        #expect(kept.mode == .tabbed)
        #expect(store.allSessions(for: display).count == 3)
    }

    @Test func closedInferredDesktopsDoNotAccumulateAcrossUnidentifiedSpaceSwitches() throws {
        let display = DisplayID(rawValue: "main")
        let hidden = WindowID(rawValue: "hidden-control")
        var store = LayoutSessionStore()
        let control = store.activate(displayID: display, windowIDs: [hidden], focusedWindowID: hidden,
            defaultMode: .bento, reuseActiveWhenUnmatched: false).session
        store.update(display) { $0.bentoState.root = .leaf(hidden) }
        for index in 0..<1_000 {
            let ids: Set<WindowID> = [.init(rawValue: "first-\(index)"), .init(rawValue: "second-\(index)")]
            _ = store.activate(displayID: display, windowIDs: ids, focusedWindowID: nil,
                defaultMode: .manual, reuseActiveWhenUnmatched: false)
            _ = store.activate(displayID: display, windowIDs: [hidden], focusedWindowID: hidden,
                defaultMode: .bento, reuseActiveWhenUnmatched: false)
            store.removeClosedTabbedWindow(ids.sorted()[0])
            #expect(store.allSessions(for: display).count == 2)
            store.removeClosedTabbedWindow(ids.sorted()[1])
            #expect(store.allSessions(for: display).count == 1)
        }
        #expect(store.session(for: display)?.id == control.id)
        #expect(store.session(for: display)?.bentoState.root == .leaf(hidden))
        let evidence = Mirror(reflecting: store).children.first { $0.label == "closedInferredWindowIDs" }?.value
        #expect((evidence as? any Collection)?.count == 0)
    }

    @Test func closingAnInactiveFollowingWindowForgetsItsReturnButKeepsTheVacancy() throws {
        let window = FollowedLayoutTests.window("minimized")
        var (_, _, original) = try FollowedLayoutTests.fixture(windows: [window])
        original.excludedFocusWindowIDs = [window.id]
        let away = FollowedLayoutTests.reduce(original, windows: [], minimized: [window.id])
        #expect(away.followed?.returnVacancies[window.id] != nil)
        var store = LayoutSessionStore()
        _ = store.activate(displayID: away.displayID, windowIDs: [], focusedWindowID: nil,
            defaultMode: .bento, reuseActiveWhenUnmatched: false, nativeSpaceID: .init(rawValue: 42))
        store.update(away.displayID) {
            $0.bentoState = away.bentoState
            $0.followed = away.followed
        }
        _ = store.activate(displayID: away.displayID, windowIDs: [], focusedWindowID: nil,
            defaultMode: .manual, reuseActiveWhenUnmatched: false, nativeSpaceID: .init(rawValue: 43))
        store.removeClosedTabbedWindow(window.id)
        let retained = try #require(store.allSessions(for: away.displayID).first { $0.nativeSpaceID?.rawValue == 42 })
        #expect(retained.followed != nil)
        #expect(retained.followed?.returnVacancies.isEmpty == true)
        #expect(retained.bentoState == away.bentoState)
    }

    @Test func closingWindowsOnAnotherSpaceReleasesAdaptiveReturnEvidence() throws {
        let display = DisplayID(rawValue: "main")
        let survivor = WindowID(rawValue: "survivor")
        let minimized = WindowID(rawValue: "still-minimized")
        var store = LayoutSessionStore()
        let owner = store.activate(displayID: display, windowIDs: [survivor], focusedWindowID: survivor,
            defaultMode: .bento, reuseActiveWhenUnmatched: false, nativeSpaceID: .init(rawValue: 1)).session
        let anchor = BentoReinsertionAnchor(neighborWindowID: survivor, edge: .right,
            layoutBefore: BentoLayoutState(root: .leaf(survivor)))
        store.update(display) {
            $0.bentoState.root = .leaf(survivor)
            $0.bentoReinsertionAnchors[minimized] = anchor
        }
        for index in 0..<1_000 {
            let closed = WindowID(rawValue: "closed-\(index)")
            store.update(display) { $0.bentoReinsertionAnchors[closed] = anchor }
        }
        _ = store.activate(displayID: display, windowIDs: [], focusedWindowID: nil,
            defaultMode: .manual, reuseActiveWhenUnmatched: false, nativeSpaceID: .init(rawValue: 2))
        for index in 0..<1_000 { store.removeClosedTabbedWindow(.init(rawValue: "closed-\(index)")) }
        let retained = try #require(store.allSessions(for: display).first { $0.id == owner.id })
        #expect(retained.bentoReinsertionAnchors.count == 1)
        #expect(retained.bentoReinsertionAnchors[minimized] == anchor)
        #expect(retained.bentoState.root == .leaf(survivor))
        #expect(retained.windowIDs == [survivor])
    }

    @Test func closureBookkeepingLeavesTheActiveTreeForItsReducer() throws {
        let display = DisplayID(rawValue: "main")
        let closed = WindowID(rawValue: "closed")
        var store = LayoutSessionStore()
        _ = store.refresh(displayID: display, windowIDs: [closed], focusedWindowID: closed, defaultMode: .bento)
        let frame = BTRect(x: 0, y: 0, width: 500, height: 800)
        store.update(display) {
            $0.bentoState.root = .leaf(closed)
            $0.lastObservedFrames[closed] = frame
            $0.bentoReinsertionAnchors[closed] = .init(neighborWindowID: closed, edge: .right,
                layoutBefore: .init(root: .leaf(closed)))
        }
        let revision = try #require(store.session(for: display)).revision
        store.removeClosedTabbedWindow(closed)
        let session = try #require(store.session(for: display))
        #expect(session.bentoState.root == .leaf(closed))
        #expect(session.windowIDs == [closed])
        #expect(session.lastObservedFrames[closed] == frame)
        #expect(session.bentoReinsertionAnchors[closed] != nil)
        #expect(session.revision == revision, "The active reducer must keep its recovery revision until it consumes the closure")
    }
}
