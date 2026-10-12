import AppKit
import Foundation
import Testing
@testable import BetterTileApp
@testable import BetterTileCore

/// Balancing can ask an existing window for less than a minimum its app
/// never reported. The refusal is learned and the layout solved again: the
/// result stays contained and never ends as a failure.
@Test(arguments: [false, true]) @MainActor
func balancedPlacementContainsAnUnreportedApplicationMinimum(balances: Bool) async throws {
    _ = NSApplication.shared
    let system = FakeAppWindowSystem()
    system.measuresOnWrite = true
    let mainID = system.windows[0].id
    system.windows[0].frame = BTRect(x: 0, y: 0, width: 400, height: 800)
    let peerID = WindowID(rawValue: "peer")
    system.windows.append(WindowSnapshot(
        id: peerID, processIdentifier: 43,
        frame: BTRect(x: 400, y: 0, width: 600, height: 800), displayID: system.mainDisplay.id
    ))
    // Bento adopts the two panes as they are, so nothing reveals this yet.
    system.enforcedMinimumWidths[peerID] = 600
    system.emitsFrameEvents = true
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.configuration.bentoBalancesNewWindows = balances
    model.setActiveMode(.bento)
    try await Task.sleep(for: .milliseconds(300))
    try #require(system.windows.first { $0.id == peerID }?.frame.size.width == 600)

    let newID = WindowID(rawValue: "new")
    system.windows.insert(WindowSnapshot(
        id: newID, processIdentifier: 44,
        frame: BTRect(x: 100, y: 100, width: 300, height: 300), displayID: system.mainDisplay.id
    ), at: 0)
    system.eventHandler?(WindowSystemEvent(kind: .created, windowID: newID, processIdentifier: 44))

    let contained = await waitFor {
        let frames = system.windows.map(\.frame)
        let disjoint = frames.indices.allSatisfy { first in
            frames.indices.allSatisfy { second in first == second || frames[first].intersection(frames[second]) == nil }
        }
        return frames.count == 3
            && frames.allSatisfy { PlacementBounds.isContained($0, in: system.mainDisplay.visibleFrame) }
            && disjoint
            && frames.reduce(0) { $0 + $1.area } > 1000 * 800 * 0.95
    }
    #expect(contained, "\(system.windows.map { ($0.id, $0.frame) })")
    #expect((system.windows.first { $0.id == peerID }?.frame.size.width ?? 0) >= 600)
    #expect(system.windows.contains { $0.id == mainID })
    if balances {
        // Balancing asked for less than the hidden minimum, so the refusal was real.
        #expect(system.requestedFrames[peerID, default: []].contains { $0.size.width < 600 })
    }
    let settled = system.windows.map(\.frame)
    try await Task.sleep(for: .milliseconds(400))
    #expect(system.windows.map(\.frame) == settled)
}

/// Balancing is a Bento setting. A new window on a Tabbed desktop joins a
/// pane as a tab and no pane changes size.
@Test @MainActor func tabbedPanesKeepTheirSizesWhenBalancingIsOn() async throws {
    _ = NSApplication.shared
    let system = FakeAppWindowSystem()
    system.windows.append(WindowSnapshot(
        id: WindowID(rawValue: "peer"), processIdentifier: 43,
        frame: BTRect(x: 500, y: 0, width: 500, height: 800), displayID: system.mainDisplay.id
    ))
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.configuration.bentoBalancesNewWindows = true
    model.configuration.defaultTabbedPreset = .columns
    model.setActiveMode(.tabbed)
    try #require(await waitFor { model.activeTabbedState?.windowIDs.count == 2 })
    let visible = system.mainDisplay.visibleFrame
    let paneFrames = try #require(model.activeTabbedState?.frames(in: visible))

    let newID = WindowID(rawValue: "new")
    system.windows.insert(WindowSnapshot(
        id: newID, processIdentifier: 44,
        frame: BTRect(x: 100, y: 100, width: 600, height: 600), displayID: system.mainDisplay.id
    ), at: 0)
    system.eventHandler?(WindowSystemEvent(kind: .created, windowID: newID, processIdentifier: 44))
    try #require(await waitFor { model.activeTabbedState?.windowIDs.contains(newID) == true })
    #expect(model.activeTabbedState?.frames(in: visible) == paneFrames)
    #expect(model.activeTabbedState?.panes.count == paneFrames.count)
}
