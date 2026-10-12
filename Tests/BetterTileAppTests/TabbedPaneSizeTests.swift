import AppKit
import BetterTileCore
@testable import BetterTileMacOS
import Testing
@testable import BetterTileApp

/// A window with a name the pill can use: no running application has this
/// process identifier, so the title stands in for the application name.
@MainActor private func namedWindow(_ name: String, pid: Int32, in system: FakeAppWindowSystem) -> WindowID {
    let id = WindowID(rawValue: name)
    system.windows.append(WindowSnapshot(
        id: id, processIdentifier: pid, title: name,
        frame: BTRect(x: 200, y: 200, width: 600, height: 400), displayID: system.mainDisplay.id
    ))
    return id
}

/// Two columns: `focused` selected over hidden `Large` on the left, `Peer`
/// on the right, with the left pane narrowed by the user to about 300 pt.
@MainActor private func narrowLeftPaneWithAHiddenTab(
    _ system: FakeAppWindowSystem, restores: Bool
) async throws -> (BetterTileModel, large: WindowID, peer: WindowID) {
    _ = NSApplication.shared
    let large = namedWindow("Large", pid: 900_001, in: system)
    let peer = namedWindow("Peer", pid: 900_002, in: system)
    let model = makeModel(system: system)
    model.configuration.tabbedRestoresPaneSizes = restores
    model.configuration.defaultTabbedPreset = .columns
    model.setActiveMode(.tabbed)
    try #require(await waitFor { model.activeTabbedState?.windowIDs.count == 3 })
    let right = try #require(model.activeTabbedState?.panes[1].id)
    model.performTabbed(.move(peer, pane: right, index: nil))
    try #require(await waitFor { model.activeTabbedState?.panes[1].selected == peer })
    let small = system.windows[0].id
    model.performTabbed(.select(small))
    try #require(await waitFor { model.activeTabbedState?.panes[0].selected == small })
    let visible = system.mainDisplay.visibleFrame
    let divider = try #require(model.activeTabbedState?.dividers(in: visible).first?.branchID)
    model.performTabbed(.adjustDivider(divider, by: -0.2))
    try #require(await waitFor {
        (model.activeTabbedState?.frames(in: visible)[model.activeTabbedState!.panes[0].id]?.size.width ?? 1000) < 320
    })
    try await Task.sleep(for: .milliseconds(300))
    return (model, large, peer)
}

@MainActor private func leftPaneWidth(_ model: BetterTileModel, _ system: FakeAppWindowSystem) -> Double {
    guard let state = model.activeTabbedState else { return 0 }
    return state.frames(in: system.mainDisplay.visibleFrame)[state.panes[0].id]?.size.width ?? 0
}

@Test(arguments: [true, false]) @MainActor
func aLargerHiddenTabGrowsItsPaneAndTheSmallerTabRestoresIt(restores: Bool) async throws {
    let system = FakeAppWindowSystem()
    let (model, large, _) = try await narrowLeftPaneWithAHiddenTab(system, restores: restores)
    defer { model.shutdown() }
    let small = system.windows[0].id
    let narrow = leftPaneWidth(model, system)
    system.windows[1].constraints.minimumSize.width = 600

    model.performTabbed(.select(large))
    try #require(await waitFor { model.activeTabbedState?.panes[0].selected == large })
    #expect(leftPaneWidth(model, system) >= 600)
    #expect((system.windows.first { $0.id == large }?.frame.size.width ?? 0) >= 600)
    #expect(model.statusMessage == nil)
    try await Task.sleep(for: .milliseconds(300))

    model.performTabbed(.select(small))
    try #require(await waitFor { model.activeTabbedState?.panes[0].selected == small })
    try await Task.sleep(for: .milliseconds(300))
    if restores {
        #expect(abs(leftPaneWidth(model, system) - narrow) < 1)
        #expect(abs((system.windows.first { $0.id == small }?.frame.size.width ?? 0) - narrow) < 1)
    } else {
        #expect(leftPaneWidth(model, system) >= 600)
    }

    // Growing again starts from the size the user set, not a drifted one.
    model.performTabbed(.select(large))
    try #require(await waitFor { model.activeTabbedState?.panes[0].selected == large })
    #expect(leftPaneWidth(model, system) >= 600)
    #expect(leftPaneWidth(model, system) < 700)
}

@Test @MainActor func aUserResizeWhileTheLargerTabShowsBecomesThePaneSize() async throws {
    let system = FakeAppWindowSystem()
    let (model, large, _) = try await narrowLeftPaneWithAHiddenTab(system, restores: true)
    defer { model.shutdown() }
    let small = system.windows[0].id
    system.windows[1].constraints.minimumSize.width = 600
    model.performTabbed(.select(large))
    try #require(await waitFor { model.activeTabbedState?.panes[0].selected == large })
    try await Task.sleep(for: .milliseconds(300))
    let visible = system.mainDisplay.visibleFrame
    let divider = try #require(model.activeTabbedState?.dividers(in: visible).first?.branchID)
    model.performTabbed(.adjustDivider(divider, by: 0.1))
    try #require(await waitFor { leftPaneWidth(model, system) > 650 })
    let chosen = leftPaneWidth(model, system)
    try await Task.sleep(for: .milliseconds(300))

    model.performTabbed(.select(small))
    try #require(await waitFor { model.activeTabbedState?.panes[0].selected == small })
    try await Task.sleep(for: .milliseconds(300))
    #expect(abs(leftPaneWidth(model, system) - chosen) < 1)
}

@Test @MainActor func aHiddenTabIsMeasuredBeforeItComesForward() async throws {
    let system = FakeAppWindowSystem()
    let (model, large, _) = try await narrowLeftPaneWithAHiddenTab(system, restores: true)
    defer { model.shutdown() }
    let requests = system.probeRequests.count
    model.performTabbed(.select(large))
    try #require(await waitFor { model.activeTabbedState?.panes[0].selected == large })
    #expect(system.probeRequests.dropFirst(requests).contains([large]))
}

@Test @MainActor func aTabThatCannotFitNamesTheWindowInItsWay() async throws {
    let system = FakeAppWindowSystem()
    let (model, large, peer) = try await narrowLeftPaneWithAHiddenTab(system, restores: true)
    defer { model.shutdown() }
    let before = try #require(model.activeTabbedState)
    system.windows[1].constraints.minimumSize.width = 600
    system.windows[2].constraints.minimumSize.width = 500
    _ = peer
    model.performTabbed(.select(large))
    #expect(await waitFor { model.lastActionFeedback?.kind == .failure })
    #expect(model.lastActionFeedback?.message == "Large doesn’t fit here")
    #expect(model.lastActionFeedback?.detail == "It would overlap Peer.")
    #expect(model.activeTabbedState == before)
}

@Test @MainActor func aTabLargerThanTheDisplaySaysSo() async throws {
    let system = FakeAppWindowSystem()
    let (model, large, _) = try await narrowLeftPaneWithAHiddenTab(system, restores: true)
    defer { model.shutdown() }
    system.windows[1].constraints.minimumSize.width = 1200
    model.performTabbed(.select(large))
    #expect(await waitFor { model.lastActionFeedback?.kind == .failure })
    #expect(model.lastActionFeedback?.message == "Large is too large for this display")
}

/// A probe that leaves the hidden tab at its probe size is undone at once,
/// even when the selection then does not fit and writes no frames.
@Test @MainActor func aHiddenTabLeftAtItsProbeSizeIsPutBack() async throws {
    let system = FakeAppWindowSystem()
    let (model, large, _) = try await narrowLeftPaneWithAHiddenTab(system, restores: true)
    defer { model.shutdown() }
    // The app keeps its window at least 1200 wide, behind the narrower pane.
    system.windows[1].constraints.minimumSize.width = 1200
    system.windows[1].frame.size.width = 1200
    let before = system.windows[1].frame
    system.measuresOnWrite = true
    system.unrestoredProbeWindowIDs = [large]
    model.performTabbed(.select(large))
    #expect(await waitFor { model.lastActionFeedback?.kind == .failure })
    #expect(system.windows.first { $0.id == large }?.frame == before)
}

