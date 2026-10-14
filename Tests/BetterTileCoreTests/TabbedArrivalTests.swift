import Foundation
import Testing
@testable import BetterTileCore

private let arrivalBounds = BTRect(x: 0, y: 0, width: 1000, height: 800)
private func window(_ name: String, minimumWidth: Double = 120) -> WindowSnapshot {
    WindowSnapshot(
        id: WindowID(rawValue: name), processIdentifier: 1, frame: arrivalBounds,
        displayID: DisplayID(rawValue: "arrival"),
        constraints: WindowConstraints(minimumSize: BTSize(width: minimumWidth, height: 80))
    )
}

/// A new window that no pane can show now still fits the work area, so it
/// waits as a hidden tab of the active pane instead of floating. Before, it
/// floated (#145), and nothing ever brought it back.
@Test func aNewWindowThatFitsNoPaneNowWaitsAsAHiddenTab() throws {
    var state = TabbedLayoutState(preset: .columns)
    let small = WindowID(rawValue: "small"), peer = WindowID(rawValue: "peer"), big = WindowID(rawValue: "big")
    state.reconcile(windowIDs: [small, peer], removed: [], focused: nil)
    state.move(peer, to: state.panes[1].id)
    state.activatePane(state.panes[0].id)
    let framesBefore = state.frames(in: arrivalBounds)
    let windows = [window("small"), window("peer"), window("big", minimumWidth: 950)]

    let adoptions = state.reconcile(windowIDs: [small, peer, big], removed: [], fittingIn: arrivalBounds, windows: windows)
    #expect(adoptions.map(\.outcome) == [.hiddenFallback(state.panes[0].id)])
    #expect(adoptions.first?.trials.map(\.result) == [.doesNotFit, .doesNotFit])
    #expect(state.pane(containing: big)?.id == state.panes[0].id)
    #expect(state.panes[0].selected == small)
    #expect(!state.floatingWindowIDs.contains(big))
    #expect(state.frames(in: arrivalBounds) == framesBefore)
    #expect((try? state.placements(in: arrivalBounds, windows: windows)) != nil)
    let settled = state
    state.reconcile(windowIDs: [small, peer, big], removed: [], fittingIn: arrivalBounds, windows: windows)
    #expect(state == settled)
}

/// Only a window that no pane could ever show floats: a fixed-size window,
/// or a proven minimum, larger than the work area below the tab strip. It
/// is an automatic float and is not adopted again on the next sweep.
@Test(arguments: [MinimumSizeSource.learned, .probe, .hint])
func aWindowLargerThanTheWorkAreaWithAProvenMinimumFloats(source: MinimumSizeSource) throws {
    var state = TabbedLayoutState(preset: .single)
    let small = WindowID(rawValue: "small"), huge = WindowID(rawValue: "huge")
    state.reconcile(windowIDs: [small], removed: [], focused: nil)
    var tooTall = window("huge")
    tooTall.constraints.minimumSize = BTSize(width: 400, height: 790)
    tooTall.constraints.minimumSizeSource = source
    let windows = [window("small"), tooTall]

    let adoptions = state.reconcile(windowIDs: [small, huge], removed: [], fittingIn: arrivalBounds, windows: windows)
    #expect(adoptions.map(\.outcome) == [.floated(.minimumLargerThanWorkArea)])
    #expect(state.floatingWindowIDs.contains(huge))
    #expect(state.automaticallyFloatingWindowIDs == [huge])
    let settled = state
    state.reconcile(windowIDs: [small, huge], removed: [], fittingIn: arrivalBounds, windows: windows)
    #expect(state == settled)
}

/// A minimum borrowed from another window of the application, or the
/// default, proves nothing about this window: it waits as a hidden tab.
@Test(arguments: [MinimumSizeSource.seed, .default])
func aWindowLargerThanTheWorkAreaWithAnUnprovenMinimumWaitsAsAHiddenTab(source: MinimumSizeSource) throws {
    var state = TabbedLayoutState(preset: .single)
    let small = WindowID(rawValue: "small"), huge = WindowID(rawValue: "huge")
    state.reconcile(windowIDs: [small], removed: [], focused: nil)
    var tooTall = window("huge")
    tooTall.constraints.minimumSize = BTSize(width: 400, height: 790)
    tooTall.constraints.minimumSizeSource = source

    let adoptions = state.reconcile(windowIDs: [small, huge], removed: [], fittingIn: arrivalBounds,
                                    windows: [window("small"), tooTall])
    #expect(adoptions.map(\.outcome) == [.hiddenFallback(state.panes[0].id)])
    #expect(state.hiddenWindowIDs == [huge])
    #expect(state.floatingWindowIDs.isEmpty)
}

/// A fixed-size window keeps its own size, so it floats only when that size
/// is larger than the work area below the strip; otherwise it waits hidden.
@Test(arguments: [false, true])
func aFixedSizeWindowFloatsOnlyWhenLargerThanTheWorkArea(larger: Bool) throws {
    var state = TabbedLayoutState(preset: .columns)
    let a = WindowID(rawValue: "a"), b = WindowID(rawValue: "b"), fixed = WindowID(rawValue: "fixed")
    state.reconcile(windowIDs: [a, b], removed: [], focused: nil)
    state.move(b, to: state.panes[1].id)
    state.activatePane(state.panes[0].id)
    var calculator = window("fixed")
    calculator.frame = BTRect(x: 0, y: 0, width: 980, height: larger ? 780 : 700)
    calculator.constraints.isResizable = false

    let adoptions = state.reconcile(windowIDs: [a, b, fixed], removed: [], fittingIn: arrivalBounds,
                                    windows: [window("a", minimumWidth: 400), window("b", minimumWidth: 400), calculator])
    if larger {
        #expect(adoptions.map(\.outcome) == [.floated(.fixedSizeLargerThanWorkArea)])
        #expect(state.automaticallyFloatingWindowIDs == [fixed])
    } else {
        #expect(adoptions.map(\.outcome) == [.hiddenFallback(state.panes[0].id)])
        #expect(state.hiddenWindowIDs == [fixed])
    }
}

/// One Pane can show any window that fits the work area, so it never
/// floats a window that fits, whatever pane is selected.
@Test func onePaneNeverFloatsAWindowThatFitsTheWorkArea() throws {
    var state = TabbedLayoutState(preset: .single)
    let ids = ["chrome", "brave", "preview", "finder"].map { WindowID(rawValue: $0) }
    state.reconcile(windowIDs: Array(ids.prefix(3)), removed: [], focused: nil)
    var finder = window("finder")
    finder.frame = BTRect(x: 0, y: 30, width: 501, height: 339)
    var windows = ids.prefix(3).map { window($0.rawValue) } + [finder]
    windows[1].constraints.minimumSize = BTSize(width: 852, height: 300)
    // A busy application's answer is unknown, so the snapshot keeps it
    // resizable; even read as fixed-size, its frame fits the pane.
    for resizable in [true, false] {
        var trial = state
        windows[3].constraints.isResizable = resizable
        let adoptions = trial.reconcile(windowIDs: ids, removed: [], fittingIn: arrivalBounds, windows: windows)
        #expect(adoptions.map(\.outcome) == [.selected(trial.panes[0].id)])
        #expect(trial.floatingWindowIDs.isEmpty)
    }
}

@Test func aNewWindowJoinsAnotherPaneThatCanGrowForIt() throws {
    // The active pane sits behind a locked divider and cannot grow; the
    // middle pane can, by taking room from the right pane.
    let a = WindowID(rawValue: "a"), b = WindowID(rawValue: "b"), c = WindowID(rawValue: "c")
    let locked = UUID()
    let tree = BentoLayoutState(root: .partition(BentoPartition(
        axis: .vertical, children: [.leaf(a), .leaf(b), .leaf(c)], ratios: [0.3, 0.35, 0.35],
        boundaryIDs: [locked, UUID()], lockedBoundaryIDs: [locked]
    )))
    var state = try #require(TabbedLayoutState(adopting: tree))
    state.select(a)
    let new = WindowID(rawValue: "new")
    let windows = [window("a"), window("b"), window("c"), window("new", minimumWidth: 400)]

    state.reconcile(windowIDs: [a, b, c, new], removed: [], fittingIn: arrivalBounds, windows: windows)
    #expect(state.pane(containing: new)?.id == state.pane(containing: b)?.id)
    #expect(!state.floatingWindowIDs.contains(new))
}

private func floatingState() -> (TabbedLayoutState, [WindowSnapshot]) {
    var state = TabbedLayoutState(preset: .single)
    let small = WindowID(rawValue: "small"), huge = WindowID(rawValue: "huge"), user = WindowID(rawValue: "user")
    state.reconcile(windowIDs: [small, user], removed: [], focused: nil)
    state.float(user)
    var tooTall = window("huge")
    tooTall.constraints.minimumSize = BTSize(width: 400, height: 790)
    tooTall.constraints.minimumSizeSource = .learned
    let windows = [window("small"), window("user"), tooTall]
    state.reconcile(windowIDs: [small, user, huge], removed: [], fittingIn: arrivalBounds, windows: windows)
    return (state, windows)
}

/// Tabbed tells its own floats from the user's. Moving, splitting, adding,
/// floating by hand, or closing the window ends an automatic float.
@Test func automaticFloatsAreTrackedApartFromUserFloats() throws {
    let (state, _) = floatingState()
    let huge = WindowID(rawValue: "huge"), user = WindowID(rawValue: "user")
    #expect(state.floatingWindowIDs == [huge, user])
    #expect(state.automaticallyFloatingWindowIDs == [huge])

    var moved = state
    moved.move(huge, to: moved.panes[0].id)
    #expect(moved.automaticallyFloatingWindowIDs.isEmpty)
    // Floated by hand later, it is the user's float.
    moved.float(huge)
    #expect(moved.floatingWindowIDs.contains(huge))
    #expect(moved.automaticallyFloatingWindowIDs.isEmpty)

    var split = state
    split.split(paneID: split.panes[0].id, moving: huge, edge: .right)
    #expect(split.automaticallyFloatingWindowIDs.isEmpty)

    var closed = state
    closed.removeClosedWindow(huge)
    #expect(closed.automaticallyFloatingWindowIDs.isEmpty)
    // The same window ID reported again is a new window, not a float.
    closed.reconcile(windowIDs: [huge], removed: [], fittingIn: arrivalBounds, windows: [window("huge")])
    #expect(closed.windowIDs.contains(huge))

    // Undo restores a whole state value, so it keeps the tracking.
    let undone = state
    #expect(undone.automaticallyFloatingWindowIDs == [huge])
}

/// Entering Tabbed from Bento keeps Bento's own floats as automatic floats
/// rather than treating them as the user's.
@Test func bentoAutomaticFloatsStayAutomaticInTabbed() throws {
    let a = WindowID(rawValue: "a"), overflow = WindowID(rawValue: "overflow"), user = WindowID(rawValue: "user")
    var bento = BentoLayoutState(root: .leaf(a))
    bento.floatingWindowIDs = [overflow, user]
    let state = try #require(TabbedLayoutState(adopting: bento, automaticallyFloating: [overflow, WindowID(rawValue: "gone")]))
    #expect(state.floatingWindowIDs == [overflow, user])
    #expect(state.automaticallyFloatingWindowIDs == [overflow])
    #expect(try #require(TabbedLayoutState(adopting: bento)).automaticallyFloatingWindowIDs.isEmpty)
}

/// Returning automatic floats adopts them as new windows: selected when they
/// fit, a hidden tab otherwise. User floats stay where they are.
@Test func returningAutomaticFloatsLeavesUserFloats() throws {
    var (state, windows) = floatingState()
    let huge = WindowID(rawValue: "huge"), user = WindowID(rawValue: "user")
    // A repair forgot the false minimum.
    windows[2].constraints = WindowConstraints()
    let returned = state.returnAutomaticFloats([huge, user], fittingIn: arrivalBounds, windows: windows)
    #expect(returned.map(\.windowID) == [huge])
    #expect(returned.map(\.outcome) == [.selected(state.panes[0].id)])
    #expect(state.windowIDs.contains(huge))
    #expect(state.floatingWindowIDs == [user])

    // A window that still fits no pane at all floats again, automatically.
    var (again, unchanged) = floatingState()
    let before = again
    let refloated = again.returnAutomaticFloats([huge], fittingIn: arrivalBounds, windows: unchanged)
    #expect(refloated.map(\.floated) == [true])
    #expect(again == before)
    unchanged.removeAll { $0.id == huge }
    // A window not on screen is left alone.
    #expect(again.returnAutomaticFloats([huge], fittingIn: arrivalBounds, windows: unchanged).isEmpty)
}

/// Bento changes to the tree keep only automatic floats that still float.
@Test func synchronizingKeepsOnlyAutomaticFloatsThatStillFloat() throws {
    var (state, _) = floatingState()
    let huge = WindowID(rawValue: "huge")
    var tree = state.layout
    tree.floatingWindowIDs.remove(huge)
    state.synchronize(with: tree)
    #expect(state.automaticallyFloatingWindowIDs.isEmpty)
    tree.floatingWindowIDs.insert(huge)
    state.synchronize(with: tree)
    #expect(state.automaticallyFloatingWindowIDs.isEmpty)
}

/// A hidden tab larger than its pane, resizable or fixed-size, is placed so
/// its whole size stays inside the work area, where the curtain covers it.
@Test(arguments: [true, false])
func aHiddenTabLargerThanItsPaneStaysInsideTheWorkArea(resizable: Bool) throws {
    var state = TabbedLayoutState(preset: .columns)
    let a = WindowID(rawValue: "a"), b = WindowID(rawValue: "b"), big = WindowID(rawValue: "big")
    state.reconcile(windowIDs: [a, b], removed: [], focused: nil)
    state.move(b, to: state.panes[1].id)
    var large = window("big")
    if resizable {
        large.constraints.minimumSize = BTSize(width: 900, height: 700)
    } else {
        large.constraints.isResizable = false
        large.frame = BTRect(x: 0, y: 0, width: 900, height: 700)
    }
    var windows = [window("a"), window("b"), large]
    windows[1].constraints.minimumSize = BTSize(width: 120, height: 80)
    state.reconcile(windowIDs: [a, b, big], removed: [], fittingIn: arrivalBounds, windows: windows)
    state.select(b)
    #expect(state.pane(containing: big)?.id == state.panes[1].id)
    #expect(state.hiddenWindowIDs == [big])
    let placement = try #require(try state.placements(in: arrivalBounds, windows: windows).first { $0.windowID == big })
    let size = resizable ? BTSize(width: 900, height: 700) : placement.frame.size
    #expect(PlacementBounds.isContained(BTRect(origin: placement.frame.origin, size: size), in: arrivalBounds),
            "\(placement.frame)")
}
