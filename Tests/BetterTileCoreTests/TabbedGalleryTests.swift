import Foundation
import Testing
@testable import BetterTileCore

@Test(arguments: TabbedPreset.allCases, [0, 1, 3, 9])
func tabbedGalleryDistributesInTabOrderWithoutLosingWindows(preset: TabbedPreset, count: Int) {
    for presentation in TabbedStripPresentation.allCases {
        let ids = (0..<count).map { WindowID(rawValue: "gallery-\($0)") }
        var state = TabbedLayoutState(preset: .columns, presentation: presentation)
        state.reconcile(windowIDs: ids, removed: [], focused: ids.last)
        if let last = ids.last { state.move(last, to: state.panes[1].id) }
        let ordered = state.panes.flatMap(\.tabs)
        let focused = state.activeWindowID
        state.applyPreset(preset, grouping: .distributeWindows)
        #expect(state.panes.count == preset.paneCount)
        #expect(state.presentation == presentation)
        #expect(state.layout.metrics.contentTopInset == presentation.reservedInset)
        for (index, pane) in state.panes.enumerated() {
            let expected = ordered.enumerated().filter { $0.offset % preset.paneCount == index }.map(\.element)
            #expect(pane.tabs == expected)
            #expect(pane.selected == expected.first)
        }
        #expect(state.windowIDs == Set(ids))
        #expect(state.panes.flatMap(\.tabs).count == ids.count)
        if let focused { #expect(state.panes.first { $0.id == state.activePaneID }?.tabs.contains(focused) == true) }
        let frames = state.frames(in: BTRect(x: 0, y: 0, width: 1400, height: 1000))
        #expect(frames.count == preset.paneCount)
        #expect(frames.values.allSatisfy { $0.size.width > 0 && $0.size.height > TabbedLayoutState.headerHeight })
    }
}

@Test func tabbedGalleryDistributionKeepsFloatingWindowsOutsidePanes() {
    let ids = (0..<5).map { WindowID(rawValue: "gallery-\($0)") }
    var state = TabbedLayoutState()
    state.reconcile(windowIDs: ids, removed: [], focused: ids[0])
    state.float(ids[4])
    state.applyPreset(.columns, grouping: .distributeWindows)
    #expect(state.panes.map(\.tabs) == [[ids[0], ids[2]], [ids[1], ids[3]]])
    #expect(state.floatingWindowIDs == [ids[4]])
    #expect(!state.windowIDs.contains(ids[4]))
}

@Test func tabbedGalleryKeepPolicyPreservesGroupsAndSelections() {
    let ids = (0..<4).map { WindowID(rawValue: "gallery-\($0)") }
    var state = TabbedLayoutState(preset: .columns)
    state.reconcile(windowIDs: ids, removed: [], focused: ids[1])
    state.move(ids[2], to: state.panes[1].id)
    state.move(ids[3], to: state.panes[1].id)
    let groups = state.panes
    state.applyPreset(.grid, grouping: .keepTabGroups)
    for group in groups {
        #expect(state.panes.first { $0.id == group.id } == group)
    }
    #expect(state.panes.filter { $0.tabs.isEmpty }.count == 2)
}
