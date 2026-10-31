import Foundation
import Testing
@testable import BetterTileCore

@Test(arguments: TabbedStripPresentation.allCases)
func tabbedPresentationReservesInsetOnceForFittingAndSnaps(_ presentation: TabbedStripPresentation) throws {
    let bounds = BTRect(x: 0, y: 0, width: 1000, height: 800)
    let id = WindowID(rawValue: "presentation")
    let window = WindowSnapshot(id: id, processIdentifier: 1, frame: bounds, displayID: DisplayID(rawValue: "test"),
                                constraints: WindowConstraints(minimumSize: BTSize(width: 120, height: 800 - presentation.reservedInset)))
    var state = TabbedLayoutState(presentation: presentation)
    state.reconcile(windowIDs: [id], removed: [], focused: id)
    let fitted = try state.fittingMinimumWidths(in: bounds, windows: [window])
    let placement = try #require(fitted.placements(in: bounds, windows: [window]).first)
    #expect(placement.frame.minY == presentation.reservedInset)
    #expect(placement.frame.size.height == 800 - presentation.reservedInset)
    #expect(fitted.layout.metrics.contentTopInset == presentation.reservedInset)
    #expect(fitted.layout.metrics.vacantMinimumSize.height == 80 + presentation.reservedInset)
    #expect(throws: TabbedLayoutError.self) {
        _ = try state.fittingMinimumWidths(in: bounds.insetBy(dx: 0, dy: 1), windows: [window])
    }
    let plan = try #require(TabbedSnapPlanner.plan(sourceWindowID: id, action: .leftHalf, scope: .pane,
                                                  state: state, windows: [window], in: bounds))
    #expect(plan.state.presentation == presentation)
    #expect(plan.placements.first?.frame.minY == presentation.reservedInset)
    state.applyPreset(.rows)
    #expect(state.presentation == presentation)
    state.synchronize(with: state.layout)
    #expect(state.presentation == presentation)
}

@Test(arguments: TabbedStripPresentation.allCases)
func tabbedPresentationConfigurationRoundTripsAndOldFilesKeepAlwaysVisible(_ presentation: TabbedStripPresentation) throws {
    var config = BetterTileConfiguration()
    config.tabbedStripPresentation = presentation
    config.shortcuts = [.init(action: .showTabBar, shortcut: nil)]
    let data = try JSONEncoder().encode(config)
    #expect(try JSONDecoder().decode(BetterTileConfiguration.self, from: data) == config)
    var old = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    old.removeValue(forKey: "tabbedStripPresentation")
    let decoded = try JSONDecoder().decode(BetterTileConfiguration.self, from: JSONSerialization.data(withJSONObject: old))
    #expect(decoded.tabbedStripPresentation == .alwaysVisible)
    #expect(decoded.shortcuts == config.shortcuts)
    #expect(BetterTileConfiguration.defaultShortcuts.first { $0.action == .showTabBar }?.shortcut == nil)
}

private struct BarClock {
    var time = 0.0
    var bar = TabbedBarVisibility()
    mutating func tick(_ seconds: Double) { time += seconds; bar.advance(to: time) }
}

@Test func autoHideWaitsForDwellAndLeaveDelayAndCancelsAnEarlyLeave() {
    var clock = BarClock()
    clock.bar.enter(at: clock.time)
    clock.tick(0.079)
    #expect(!clock.bar.isRevealed)
    clock.bar.enter(at: clock.time) // Repeated drag samples do not restart dwell.
    clock.tick(0.001)
    #expect(clock.bar.isRevealed)
    clock.bar.leave(at: clock.time)
    clock.tick(0.299)
    #expect(clock.bar.isRevealed)
    clock.tick(0.002)
    #expect(!clock.bar.isRevealed)
    clock.bar.enter(at: clock.time)
    clock.tick(0.040)
    clock.bar.leave(at: clock.time)
    clock.tick(1)
    #expect(!clock.bar.isRevealed)
}

@Test(arguments: [TabbedBarVisibility.Hold.drag, .menu, .keyboard, .selection, .gallery, .applicationPicker])
func autoHideHoldsUntilInteractionEnds(_ hold: TabbedBarVisibility.Hold) {
    var clock = BarClock()
    clock.bar.hold(hold, enabled: true, at: clock.time)
    clock.bar.leave(at: clock.time)
    clock.tick(2)
    #expect(clock.bar.isRevealed)
    clock.bar.hold(hold, enabled: false, at: clock.time)
    clock.tick(0.299)
    #expect(clock.bar.isRevealed)
    clock.tick(0.002)
    #expect(!clock.bar.isRevealed)
}

@Test func autoHideSuppressesDividerDragsAndEscapeClearsHolds() {
    var clock = BarClock()
    clock.bar.enter(at: clock.time)
    clock.bar.setDividerDragging(true)
    clock.tick(1)
    clock.bar.enter(at: clock.time)
    clock.bar.hold(.drag, enabled: true, at: clock.time)
    clock.tick(1)
    #expect(!clock.bar.isRevealed)
    clock.bar.hold(.drag, enabled: false, at: clock.time)
    clock.bar.setDividerDragging(false)
    clock.tick(1)
    #expect(!clock.bar.isRevealed)
    clock.bar.enter(at: clock.time)
    clock.tick(0.081)
    clock.bar.hold(.keyboard, enabled: true, at: clock.time)
    clock.bar.dismiss()
    clock.tick(1)
    #expect(!clock.bar.isRevealed)
    #expect(clock.bar.nextDeadline == nil)
}

@Test func autoHideReentryCancelsCollapseAndOverlappingHoldsReleaseTogether() {
    var clock = BarClock()
    clock.bar.enter(at: clock.time)
    clock.tick(0.081)
    clock.bar.leave(at: clock.time)
    clock.tick(0.2)
    clock.bar.enter(at: clock.time)
    clock.tick(1)
    #expect(clock.bar.isRevealed)
    clock.bar.hold(.menu, enabled: true, at: clock.time)
    clock.bar.hold(.keyboard, enabled: true, at: clock.time)
    clock.bar.leave(at: clock.time)
    clock.bar.hold(.menu, enabled: false, at: clock.time)
    clock.tick(1)
    #expect(clock.bar.isRevealed)
    clock.bar.hold(.keyboard, enabled: false, at: clock.time)
    clock.tick(0.2)
    clock.bar.leave(at: clock.time) // Repeated outside samples cannot extend collapse.
    clock.tick(0.101)
    #expect(!clock.bar.isRevealed)
}

@Test(arguments: TabbedStripPresentation.allCases)
func stackedPanesCountEachPresentationReserveAndTheDividerGapOnce(_ presentation: TabbedStripPresentation) throws {
    let bounds = BTRect(x: 0, y: 0, width: 1000, height: 800)
    let ids = [WindowID(rawValue: "upper"), WindowID(rawValue: "lower")]
    let windows = ids.map {
        WindowSnapshot(id: $0, processIdentifier: 1, frame: bounds, displayID: DisplayID(rawValue: "test"),
                       constraints: WindowConstraints(minimumSize: BTSize(width: 120, height: 397 - presentation.reservedInset)))
    }
    var state = TabbedLayoutState(preset: .rows, presentation: presentation)
    state.reconcile(windowIDs: ids, removed: [], focused: ids[0])
    state.move(ids[1], to: state.panes[1].id)
    let fitted = try state.fittingMinimumWidths(in: bounds, windows: windows)
    let placements = try fitted.placements(in: bounds, windows: windows)
    #expect(placements.map(\.frame.size.height) == [397 - presentation.reservedInset, 397 - presentation.reservedInset])
    #expect(placements[0].frame.minY == presentation.reservedInset)
    #expect(placements[1].frame.minY == 403 + presentation.reservedInset)
    #expect(placements[1].frame.maxY == 800)
}

@Test(arguments: TabbedStripPresentation.allCases, [false, true])
func tabbedPresentationFloatDiagnosticsUseTheCurrentReserve(_ presentation: TabbedStripPresentation, fixed: Bool) throws {
    let bounds = BTRect(x: 0, y: 0, width: 1000, height: 800)
    let ids = [WindowID(rawValue: "upper"), WindowID(rawValue: "lower"), WindowID(rawValue: "tall")]
    var state = TabbedLayoutState(preset: .rows, presentation: presentation)
    state.reconcile(windowIDs: Array(ids.prefix(2)), removed: [], focused: ids[0])
    state.move(ids[1], to: state.panes[1].id)
    var windows = ids.map {
        WindowSnapshot(id: $0, processIdentifier: 1, frame: bounds, displayID: DisplayID(rawValue: "test"),
                       constraints: WindowConstraints(minimumSize: BTSize(width: 120, height: 80)))
    }
    windows[2].constraints.minimumSize = BTSize(width: 400, height: 770)
    windows[2].constraints.minimumSizeSource = .probe
    windows[2].constraints.isResizable = !fixed
    windows[2].frame = BTRect(x: 0, y: 0, width: 400, height: 770)
    let result = state.reconcile(windowIDs: ids, removed: [], fittingIn: bounds, windows: windows)
    let reason: TabbedAdoption.FloatReason = presentation == .alwaysVisible
        ? (fixed ? .fixedSizeLargerThanWorkArea : .minimumLargerThanWorkArea) : .fitsNoPane
    #expect(result.map(\.outcome) == [.floated(reason)])
    #expect(state.automaticallyFloatingWindowIDs == [ids[2]])
}
