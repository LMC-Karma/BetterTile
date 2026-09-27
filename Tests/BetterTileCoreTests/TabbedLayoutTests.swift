import Foundation
import Testing
@testable import BetterTileCore

@Test func tabbedActivationCollectsWindowsInFirstPaneAndKeepsEmptyPanes() throws {
    let a = WindowID(rawValue: "a")
    let b = WindowID(rawValue: "b")
    var state = TabbedLayoutState(preset: .focus)
    state.reconcile(windowIDs: [a, b], removed: [], focused: b)
    #expect(state.panes.count == 3)
    #expect(state.panes[0].tabs == [a, b])
    #expect(state.panes[0].selected == b)
    #expect(state.panes[1].tabs.isEmpty)
    #expect(state.panes[2].tabs.isEmpty)
}

@Test func tabbedEmptyPaneCanReceiveNewWindowsAndLastCloseKeepsPane() {
    let a = WindowID(rawValue: "a"), b = WindowID(rawValue: "b")
    var state = TabbedLayoutState(preset: .columns)
    state.reconcile(windowIDs: [a], removed: [], focused: a)
    let empty = state.panes[1].id
    state.activatePane(empty)
    state.reconcile(windowIDs: [a, b], removed: [], focused: nil)
    #expect(state.panes[1].tabs == [b])
    #expect(state.activeWindowID == b)
    state.reconcile(windowIDs: [a], removed: [b], focused: nil)
    #expect(state.panes[1].id == empty)
    #expect(state.panes[1].selected == nil)
}

@Test func tabbedMoveReorderSplitAndFloatPreserveUniqueMembership() {
    let a = WindowID(rawValue: "a"), b = WindowID(rawValue: "b"), c = WindowID(rawValue: "c")
    var state = TabbedLayoutState(preset: .columns)
    state.reconcile(windowIDs: [a, b, c], removed: [], focused: a)
    state.move(c, to: state.panes[0].id, at: 0)
    #expect(state.panes[0].tabs == [c, a, b])
    let right = state.panes[1].id
    state.split(paneID: right, moving: b, edge: .bottom)
    #expect(state.panes.count == 3)
    #expect(state.panes[0].tabs == [c, a])
    #expect(state.panes[1].id == right)
    #expect(state.panes[1].tabs.isEmpty)
    #expect(state.panes[2].tabs == [b])
    state.float(a)
    state.reconcile(windowIDs: [a, b, c], removed: [], focused: nil)
    #expect(!state.windowIDs.contains(a))
    #expect(state.floatingWindowIDs == [a])
    #expect(state.panes.flatMap(\.tabs).count == state.windowIDs.count)
}

@Test func tabbedReconcileRemovalRetainsFloatingMembership() {
    let temporarilyAbsent = WindowID(rawValue: "temporarily-absent-floating")
    var state = TabbedLayoutState()
    state.reconcile(windowIDs: [temporarilyAbsent], removed: [], focused: temporarilyAbsent)
    state.float(temporarilyAbsent)

    state.reconcile(windowIDs: [temporarilyAbsent], removed: [temporarilyAbsent], focused: nil)

    #expect(state.floatingWindowIDs.contains(temporarilyAbsent))
    #expect(!state.windowIDs.contains(temporarilyAbsent))
}

@Test func tabbedRemovingClosedFloatingWindowClearsItsMembership() {
    let closed = WindowID(rawValue: "closed-floating")
    var state = TabbedLayoutState()
    state.reconcile(windowIDs: [closed], removed: [], focused: closed)
    state.float(closed)

    state.removeClosedWindow(closed)

    #expect(!state.floatingWindowIDs.contains(closed))
    #expect(!state.windowIDs.contains(closed))
}

@Test func tabbedPresetAddsEmptyPanesAndMergesWithoutReorderingGroups() {
    let a = WindowID(rawValue: "a"), b = WindowID(rawValue: "b")
    var state = TabbedLayoutState()
    state.reconcile(windowIDs: [a, b], removed: [], focused: a)
    let first = state.panes[0].id
    state.applyPreset(.focus)
    #expect(state.panes[0].id == first)
    #expect(state.panes[0].tabs == [a, b])
    #expect(state.panes.dropFirst().allSatisfy { $0.tabs.isEmpty })
    state.move(b, to: state.panes[2].id)
    state.applyPreset(.single)
    #expect(state.panes[0].tabs == [a, b])
    #expect(state.panes[0].selected == a)
}

@Test func tabbedClosingSelectedTabChoosesRightThenLeftAndMissingSweepDoesNotClose() {
    let a = WindowID(rawValue: "a"), b = WindowID(rawValue: "b"), c = WindowID(rawValue: "c")
    var state = TabbedLayoutState()
    state.reconcile(windowIDs: [a, b, c], removed: [], focused: b)
    state.reconcile(windowIDs: [], removed: [], focused: nil)
    #expect(state.panes[0].tabs == [a, b, c])
    state.remove(b)
    #expect(state.activeWindowID == c)
    state.remove(c)
    #expect(state.activeWindowID == a)
}

@Test func tabbedStackingContainsAllMembersAndRejectsShrinkingBelowInactiveMinimum() throws {
    let display = DisplayID(rawValue: "main")
    let a = WindowSnapshot(id: WindowID(rawValue: "a"), processIdentifier: 1, frame: BTRect(x: 0, y: 0, width: 600, height: 400), displayID: display)
    var b = a
    b.id = WindowID(rawValue: "b")
    b.constraints.minimumSize = BTSize(width: 500, height: 200)
    var state = TabbedLayoutState(preset: .columns)
    state.reconcile(windowIDs: [a.id, b.id], removed: [], focused: a.id)
    let bounds = BTRect(x: 0, y: 0, width: 1200, height: 800)
    let placements = try state.placements(in: bounds, windows: [a, b])
    #expect(placements.count == 2)
    #expect(placements[0].frame == BTRect(x: 0, y: 34, width: 597, height: 766))
    #expect(placements[0].frame == placements[1].frame)
    #expect(state.selectedWindowIDs == [a.id])
    state.resize(dividerID: state.dividers(in: bounds)[0].id, ratio: 0.3)
    #expect(throws: TabbedLayoutError.self) { try state.placements(in: bounds, windows: [a, b]) }
}

@Test func tabbedConfigurationRoundTripDoesNotReviveHistoricalTabbedMode() throws {
    var configuration = BetterTileConfiguration(defaultLayoutMode: .tabbed)
    configuration.defaultTabbedPreset = .focus
    let data = try JSONEncoder().encode(configuration)
    let restored = try JSONDecoder().decode(BetterTileConfiguration.self, from: data)
    #expect(restored.defaultLayoutMode == .tabbed)
    #expect(restored.defaultTabbedPreset == .focus)
    let legacy = Data(#"{"schemaVersion":7,"defaultLayoutMode":"tabbed"}"#.utf8)
    #expect(try JSONDecoder().decode(BetterTileConfiguration.self, from: legacy).defaultLayoutMode == .bento)
}

@Test func tabbedWidthFitGivesAnInactiveRightTabSixtyPercent() throws {
    let bounds = BTRect(x: -1006, y: 24, width: 1006, height: 800)
    let windows = tabbedWidthTestWindows(widths: [200, 200, 600], bounds: bounds)
    var state = TabbedLayoutState(preset: .columns)
    state.reconcile(windowIDs: windows.map(\.id), removed: [], focused: nil)
    let right = state.panes[1].id
    state.move(windows[2].id, to: right)
    state.move(windows[1].id, to: right)
    let fitted = try state.fittingMinimumWidths(in: bounds, windows: windows)
    let frames = fitted.frames(in: bounds)
    #expect(abs(frames[state.panes[0].id]!.size.width - 400) < 0.001)
    #expect(abs(frames[right]!.size.width - 600) < 0.001)
    #expect(fitted.panes == state.panes)
    #expect(fitted.activePaneID == state.activePaneID)
    #expect(fitted.dividers(in: bounds).map(\.id) == state.dividers(in: bounds).map(\.id))
    let placements = try fitted.placements(in: bounds, windows: windows)
    #expect(placements[1].frame == placements[2].frame)
    #expect(placements.allSatisfy { $0.frame.minY == bounds.minY + 34 && $0.frame.size.height == 766 })
    #expect(try fitted.fittingMinimumWidths(in: bounds, windows: windows) == fitted)
}

@Test func tabbedWidthFitAdjustsNestedAncestorsWithoutChangingRowHeights() throws {
    let bounds = BTRect(x: 0, y: 0, width: 1200, height: 800)
    var windows = tabbedWidthTestWindows(widths: [450, 300, 350], bounds: bounds)
    var state = TabbedLayoutState()
    state.reconcile(windowIDs: windows.map(\.id), removed: [], focused: nil)
    let left = state.panes[0].id
    state.split(paneID: left, moving: windows[1].id, edge: .right)
    state.split(paneID: left, moving: windows[2].id, edge: .right)
    let fitted = try state.fittingMinimumWidths(in: bounds, windows: windows)
    let placements = try fitted.placements(in: bounds, windows: windows)
    #expect(abs(placements.first { $0.windowID == windows[0].id }!.frame.size.width - 450) < 0.001)
    #expect(abs(placements.first { $0.windowID == windows[2].id }!.frame.size.width - 350) < 0.001)
    #expect(fitted.panes == state.panes)

    state.applyPreset(.focus)
    state.move(windows[0].id, to: state.panes[2].id)
    windows[0].constraints.minimumSize.width = 650
    let before = state.dividers(in: bounds).filter { !$0.vertical }
    let focus = try state.fittingMinimumWidths(in: bounds, windows: windows)
    #expect(abs(focus.frames(in: bounds)[state.panes[2].id]!.size.width - 650) < 0.001)
    #expect(focus.dividers(in: bounds).filter { !$0.vertical }.map(\.ratio) == before.map(\.ratio))
    #expect(focus.frames(in: bounds)[state.panes[1].id]!.size.height == state.frames(in: bounds)[state.panes[1].id]!.size.height)
}

@Test func tabbedWidthFitClampsDividerAndLeavesValidRatiosAlone() throws {
    let bounds = BTRect(x: 0, y: 0, width: 1006, height: 800)
    let windows = tabbedWidthTestWindows(widths: [200, 600], bounds: bounds)
    var state = TabbedLayoutState(preset: .columns)
    state.reconcile(windowIDs: windows.map(\.id), removed: [], focused: nil)
    state.move(windows[1].id, to: state.panes[1].id)
    let divider = state.dividers(in: bounds)[0].id
    state.resize(dividerID: divider, ratio: 0.9)
    let clamped = try state.fittingMinimumWidths(in: bounds, windows: windows)
    #expect(abs(clamped.dividers(in: bounds)[0].ratio - 0.4) < 0.001)
    state.resize(dividerID: divider, ratio: 0.3)
    #expect(try state.fittingMinimumWidths(in: bounds, windows: windows) == state)
}

@Test func tabbedWidthFitRejectsImpossibleWidthAndHeightWithoutChangingState() throws {
    let bounds = BTRect(x: 0, y: 0, width: 1006, height: 800)
    var windows = tabbedWidthTestWindows(widths: [500, 600], bounds: bounds)
    var state = TabbedLayoutState(preset: .columns)
    state.reconcile(windowIDs: windows.map(\.id), removed: [], focused: nil)
    state.move(windows[1].id, to: state.panes[1].id)
    let original = state
    #expect(throws: TabbedLayoutError.self) { try state.fittingMinimumWidths(in: bounds, windows: windows) }
    windows[0].constraints.minimumSize.width = 200
    windows[1].constraints.minimumSize.height = 767
    #expect(throws: TabbedLayoutError.self) { try state.fittingMinimumWidths(in: bounds, windows: windows) }
    #expect(state == original)
    windows[1].constraints.minimumSize.height = 766
    _ = try state.fittingMinimumWidths(in: bounds, windows: windows)

    state.applyPreset(.rows)
    windows[1].constraints.minimumSize.height = 400
    #expect(throws: TabbedLayoutError.self) { try state.fittingMinimumWidths(in: bounds, windows: windows) }
}

@Test func tabbedWidthFitKeepsEmptyPanesAndRejectsResizingFixedWindows() throws {
    let bounds = BTRect(x: 0, y: 0, width: 1006, height: 800)
    var windows = tabbedWidthTestWindows(widths: [600], bounds: bounds)
    var state = TabbedLayoutState(preset: .columns)
    state.reconcile(windowIDs: windows.map(\.id), removed: [], focused: nil)
    let fitted = try state.fittingMinimumWidths(in: bounds, windows: windows)
    #expect(fitted.panes[1].tabs.isEmpty)
    #expect(abs(fitted.frames(in: bounds)[state.panes[1].id]!.size.width - 400) < 0.001)
    windows[0].constraints.isResizable = false
    #expect(throws: TabbedLayoutError.self) { try state.fittingMinimumWidths(in: bounds, windows: windows) }
}

private func tabbedWidthTestWindows(widths: [Double], bounds: BTRect) -> [WindowSnapshot] {
    widths.enumerated().map { index, width in
        WindowSnapshot(id: WindowID(rawValue: "width-\(index)"), processIdentifier: 1,
                       frame: bounds, displayID: DisplayID(rawValue: "test"),
                       constraints: WindowConstraints(minimumSize: BTSize(width: width, height: 100)))
    }
}
