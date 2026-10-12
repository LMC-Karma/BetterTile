import AppKit
import BetterTileCore
@testable import BetterTileMacOS
import Testing
@testable import BetterTileApp

/// A window too large for every pane floats at its own size, moved fully
/// onto the work area, and the pill says why it did not become a tab.
@Test @MainActor func aNewWindowThatFitsNoPaneFloatsOnScreenAndSaysSo() async throws {
    _ = NSApplication.shared
    let system = FakeAppWindowSystem()
    let peer = WindowID(rawValue: "peer")
    system.windows.append(WindowSnapshot(
        id: peer, processIdentifier: 900_011, title: "Peer",
        frame: BTRect(x: 500, y: 0, width: 500, height: 800), displayID: system.mainDisplay.id
    ))
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.configuration.defaultTabbedPreset = .columns
    model.setActiveMode(.tabbed)
    try #require(await waitFor { model.activeTabbedState?.windowIDs.count == 2 })
    let right = try #require(model.activeTabbedState?.panes[1].id)
    model.performTabbed(.move(peer, pane: right, index: nil))
    try #require(await waitFor { model.activeTabbedState?.panes[1].selected == peer })
    try await Task.sleep(for: .milliseconds(300))

    let big = WindowID(rawValue: "big")
    var window = WindowSnapshot(
        id: big, processIdentifier: 900_012, title: "Big",
        frame: BTRect(x: 300, y: 100, width: 950, height: 500), displayID: system.mainDisplay.id
    )
    window.constraints.minimumSize = BTSize(width: 950, height: 400)
    system.windows.append(window)
    system.eventHandler?(WindowSystemEvent(kind: .created, windowID: big, processIdentifier: 900_012))

    #expect(await waitFor { model.activeTabbedState?.floatingWindowIDs.contains(big) == true })
    #expect(model.activeTabbedState?.windowIDs.contains(big) == false)
    #expect(model.lastActionFeedback?.message == "Big is floating")
    #expect(model.lastActionFeedback?.detail == "It doesn’t fit in any pane.")
    let placed = await waitFor {
        let frame = system.windows.first { $0.id == big }?.frame
        return frame.map { PlacementBounds.isContained($0, in: system.mainDisplay.visibleFrame) } == true
    }
    #expect(placed, "\(system.windows.first { $0.id == big }?.frame as Any)")
    #expect(system.windows.first { $0.id == big }?.frame.size == BTSize(width: 950, height: 500))
}

/// A new window whose minimum shows only when it refuses its pane's size is
/// adopted again with that minimum. It floats, and the pill says so instead
/// of reporting the refused size.
@Test @MainActor func aNewWindowThatRefusesItsPaneIsAdoptedAgainAndFloats() async throws {
    _ = NSApplication.shared
    let system = FakeAppWindowSystem()
    let peer = WindowID(rawValue: "peer")
    system.windows.append(WindowSnapshot(
        id: peer, processIdentifier: 900_021, title: "Peer",
        frame: BTRect(x: 500, y: 0, width: 500, height: 800), displayID: system.mainDisplay.id
    ))
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.configuration.defaultTabbedPreset = .columns
    model.setActiveMode(.tabbed)
    try #require(await waitFor { model.activeTabbedState?.windowIDs.count == 2 })
    let right = try #require(model.activeTabbedState?.panes[1].id)
    model.performTabbed(.move(peer, pane: right, index: nil))
    try #require(await waitFor { model.activeTabbedState?.panes[1].selected == peer })
    model.performTabbed(.select(system.windows[0].id))
    try await Task.sleep(for: .milliseconds(300))

    let big = WindowID(rawValue: "big")
    system.windows.append(WindowSnapshot(
        id: big, processIdentifier: 900_022, title: "Big",
        frame: BTRect(x: 100, y: 100, width: 960, height: 500), displayID: system.mainDisplay.id
    ))
    // The app reports nothing; it clamps any narrower write to 960, which
    // reading the size back after a write reveals, as Accessibility does.
    system.enforcedMinimumWidths[big] = 960
    system.measuresOnWrite = true
    system.unprobeableWindowIDs = [big]
    system.eventHandler?(WindowSystemEvent(kind: .created, windowID: big, processIdentifier: 900_022))

    var shown: [String] = []
    #expect(await waitFor(timeout: .seconds(3)) {
        if let message = model.lastActionFeedback?.message, shown.last != message { shown.append(message) }
        return model.activeTabbedState?.floatingWindowIDs.contains(big) == true
            && model.lastActionFeedback?.message == "Big is floating"
    }, "\(model.lastActionFeedback as Any) \(model.activeTabbedState?.panes.map(\.tabs) as Any)")
    #expect(shown == ["Big is floating"], "\(shown)")
    #expect(model.activeTabbedState?.windowIDs.contains(big) == false)
    #expect(model.statusMessage == nil)
    #expect(await waitFor {
        system.windows.first { $0.id == big }.map { PlacementBounds.isContained($0.frame, in: system.mainDisplay.visibleFrame) } == true
    })
}

/// Two windows that float in the same sweep are both named in one pill.
@Test @MainActor func windowsThatFloatTogetherAreAllNamed() async throws {
    _ = NSApplication.shared
    let system = FakeAppWindowSystem()
    let peer = WindowID(rawValue: "peer")
    system.windows.append(WindowSnapshot(
        id: peer, processIdentifier: 900_031, title: "Peer",
        frame: BTRect(x: 500, y: 0, width: 500, height: 800), displayID: system.mainDisplay.id
    ))
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.configuration.defaultTabbedPreset = .columns
    model.setActiveMode(.tabbed)
    try #require(await waitFor { model.activeTabbedState?.windowIDs.count == 2 })
    let right = try #require(model.activeTabbedState?.panes[1].id)
    model.performTabbed(.move(peer, pane: right, index: nil))
    try #require(await waitFor { model.activeTabbedState?.panes[1].selected == peer })
    try await Task.sleep(for: .milliseconds(300))

    var arrivals: [WindowID] = []
    for (index, name) in ["Wide", "Wider"].enumerated() {
        let id = WindowID(rawValue: name)
        var window = WindowSnapshot(
            id: id, processIdentifier: 900_032 + Int32(index), title: name,
            frame: BTRect(x: 20, y: 100, width: 950, height: 500), displayID: system.mainDisplay.id
        )
        window.constraints.minimumSize = BTSize(width: 950, height: 400)
        system.windows.append(window)
        arrivals.append(id)
    }
    for (index, id) in arrivals.enumerated() {
        system.eventHandler?(WindowSystemEvent(kind: .created, windowID: id, processIdentifier: 900_032 + Int32(index)))
    }

    #expect(await waitFor { arrivals.allSatisfy { model.activeTabbedState?.floatingWindowIDs.contains($0) == true } })
    #expect(model.lastActionFeedback?.message == "2 windows are floating")
    #expect(model.lastActionFeedback?.detail == "Wide and Wider don’t fit in any pane.")
}
