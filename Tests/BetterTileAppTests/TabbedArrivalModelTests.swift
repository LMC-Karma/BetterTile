import AppKit
import BetterTileCore
@testable import BetterTileMacOS
import Testing
@testable import BetterTileApp

/// A window too wide for every pane, but not for the display, floats at its
/// own size as an automatic float, moved fully onto the work area. The pill
/// names the window by its title, though Peer belongs to the same app.
@Test @MainActor func aNewWindowThatFitsNoPaneFloatsOnScreenAndSaysSo() async throws {
    _ = NSApplication.shared
    let system = FakeAppWindowSystem()
    let peer = WindowID(rawValue: "peer")
    system.windows.append(WindowSnapshot(
        id: peer, processIdentifier: 900_011, bundleIdentifier: "com.apple.finder", title: "Peer",
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
        id: big, processIdentifier: 900_012, bundleIdentifier: "com.apple.finder", title: "Big",
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
    #expect(model.activeTabbedState?.automaticallyFloatingWindowIDs == [big])
}

/// A new window whose minimum shows only when it refuses its pane's size is
/// adopted again with that minimum. No pane can show it beside the other
/// pane, so it floats automatically, and the pill says so instead of
/// reporting the refused size.
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

    let feedback = model.lastActionFeedback
    var shown: [String] = []
    #expect(await waitFor(timeout: .seconds(3)) {
        if model.lastActionFeedback != feedback, let message = model.lastActionFeedback?.message,
           shown.last != message { shown.append(message) }
        return model.activeTabbedState?.automaticallyFloatingWindowIDs == [big]
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
            frame: BTRect(x: 20, y: 5, width: 600, height: 790), displayID: system.mainDisplay.id
        )
        // Taller than any pane can be below its tab strip.
        window.constraints.minimumSize = BTSize(width: 600, height: 780)
        window.constraints.minimumSizeSource = .hint
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

/// A new window is adopted again only once. When it still refuses its pane
/// because nothing learned its minimum, the refusal is reported and
/// BetterTile does not keep adopting it.
@Test @MainActor func aNewWindowThatRefusesAgainIsReportedNotAdoptedForever() async throws {
    _ = NSApplication.shared
    let system = FakeAppWindowSystem()
    let peer = WindowID(rawValue: "peer")
    system.windows.append(WindowSnapshot(
        id: peer, processIdentifier: 900_041, title: "Peer",
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

    let stubborn = WindowID(rawValue: "stubborn")
    system.windows.append(WindowSnapshot(
        id: stubborn, processIdentifier: 900_042, title: "Stubborn",
        frame: BTRect(x: 20, y: 100, width: 960, height: 500), displayID: system.mainDisplay.id
    ))
    // It refuses anything narrower, and nothing records that as a minimum.
    system.enforcedMinimumWidths[stubborn] = 960
    system.eventHandler?(WindowSystemEvent(kind: .created, windowID: stubborn, processIdentifier: 900_042))

    #expect(await waitFor(timeout: .seconds(3)) { model.lastActionFeedback?.message == "Window refused this size" })
    let writes = system.frameWriteCounts[stubborn, default: 0]
    try await Task.sleep(for: .milliseconds(800))
    #expect(system.frameWriteCounts[stubborn, default: 0] == writes)
    #expect(model.activeTabbedState?.windowIDs.contains(stubborn) != true)
}

/// "X is floating" is said only after the placement that floats it lands.
@Test @MainActor func aFloatThatCannotBePlacedIsNotAnnounced() async throws {
    _ = NSApplication.shared
    let system = FakeAppWindowSystem()
    let peer = WindowID(rawValue: "peer")
    system.windows.append(WindowSnapshot(
        id: peer, processIdentifier: 900_051, title: "Peer",
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
        id: big, processIdentifier: 900_052, title: "Big",
        frame: BTRect(x: 300, y: 100, width: 600, height: 790), displayID: system.mainDisplay.id
    )
    window.constraints.minimumSize = BTSize(width: 600, height: 780)
    window.constraints.minimumSizeSource = .hint
    system.windows.append(window)
    // Every write that would move it onto the work area fails.
    system.failedFrameWriteNumbers[big] = Set(1...50)
    system.eventHandler?(WindowSystemEvent(kind: .created, windowID: big, processIdentifier: 900_052))

    var shown: [String] = []
    _ = await waitFor(timeout: .seconds(2)) {
        if let message = model.lastActionFeedback?.message, shown.last != message { shown.append(message) }
        return false
    }
    #expect(!shown.isEmpty)
    #expect(!shown.contains("Big is floating"), "\(shown)")
}

/// The live sequence: four full-screen windows go Native → Bento (four
/// panes) → Tabbed → One Pane → Native; a new window opens; Tabbed again.
/// One window is too wide for a Bento quarter, so Bento floats a window on
/// its own. Tabbed used to keep that float as if the user made it, and One
/// Pane never offered it a pane. Every window fits One Pane and becomes a tab.
@Test @MainActor func theLiveSequenceEndsWithEveryWindowAsATab() async throws {
    _ = NSApplication.shared
    let system = FakeAppWindowSystem()
    let area = system.mainDisplay.visibleFrame
    let names = ["chrome", "brave", "preview", "finder"]
    system.windows = names.enumerated().map { index, name in
        WindowSnapshot(id: WindowID(rawValue: name), processIdentifier: 920_000 + Int32(index),
                       bundleIdentifier: "com.example.\(name)", title: name.capitalized,
                       frame: area, displayID: system.mainDisplay.id)
    }
    // Brave's sidebar makes it wider than a quarter of the display.
    system.windows[1].constraints.minimumSize = BTSize(width: 700, height: 300)
    system.windows[1].constraints.minimumSizeSource = .hint
    let finder = system.windows[3].id
    system.focusedID = finder
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.setActiveMode(.bento)
    try #require(await waitFor { system.windows.contains { $0.frame != area } })
    try await Task.sleep(for: .milliseconds(300))
    model.setActiveMode(.tabbed)
    try #require(await waitFor { model.activeTabbedState != nil && model.activeLayoutMode == .tabbed })
    try await Task.sleep(for: .milliseconds(300))
    model.performTabbed(.preset(.single))
    try #require(await waitFor { model.activeTabbedState?.panes.count == 1 })
    try await Task.sleep(for: .milliseconds(300))
    model.setActiveMode(.manual)
    try #require(await waitFor { model.activeMode(for: system.mainDisplay.id) == .manual })
    try await Task.sleep(for: .milliseconds(300))

    let new = WindowID(rawValue: "chrome-2")
    system.windows.append(WindowSnapshot(id: new, processIdentifier: 920_000, bundleIdentifier: "com.example.chrome",
                                         title: "Chrome", frame: area, displayID: system.mainDisplay.id))
    system.eventHandler?(WindowSystemEvent(kind: .created, windowID: new, processIdentifier: 920_000))
    try await Task.sleep(for: .milliseconds(300))
    model.setActiveMode(.tabbed)

    #expect(await waitFor(timeout: .seconds(3)) { model.activeTabbedState?.windowIDs.count == 5 },
            "\(model.activeTabbedState?.panes.map(\.tabs) as Any) floating \(model.activeTabbedState?.floatingWindowIDs as Any)")
    #expect(model.activeTabbedState?.floatingWindowIDs.isEmpty == true)
    #expect(model.lastActionFeedback?.message.hasSuffix("is floating") != true)
}

/// A Tabbed desktop in One Pane with a small window, ready for arrivals.
@MainActor
private func onePaneFixture() async throws -> (FakeAppWindowSystem, BetterTileModel) {
    _ = NSApplication.shared
    let system = FakeAppWindowSystem()
    let model = makeModel(system: system)
    model.configuration.defaultTabbedPreset = .single
    model.setActiveMode(.tabbed)
    try #require(await waitFor { model.activeTabbedState?.windowIDs.count == 1 })
    try await Task.sleep(for: .milliseconds(300))
    return (system, model)
}

/// A window whose learned minimum is taller than the work area below the
/// tab strip, so it floats automatically on arrival.
@MainActor
private func addFalselyMeasuredWindow(_ name: String, pid: Int32, to system: FakeAppWindowSystem) -> WindowID {
    let id = WindowID(rawValue: name)
    var window = WindowSnapshot(id: id, processIdentifier: pid, bundleIdentifier: "com.example.\(name)",
                                title: name.capitalized, frame: BTRect(x: 100, y: 5, width: 600, height: 790),
                                displayID: system.mainDisplay.id)
    window.constraints.minimumSize = BTSize(width: 600, height: 790)
    window.constraints.minimumSizeSource = .learned
    system.windows.append(window)
    system.eventHandler?(WindowSystemEvent(kind: .created, windowID: id, processIdentifier: pid))
    return id
}

/// Repair Tabbed returns windows that floated on their own: it reads them
/// again and adopts them. A window the user floated stays floating. The pill
/// counts the returned windows.
@Test @MainActor func repairTabbedReturnsAutomaticFloatsAndKeepsUserFloats() async throws {
    let (system, model) = try await onePaneFixture()
    defer { model.shutdown() }
    model.tabbedAutomaticFloatRetryDelay = .seconds(60)
    let user = WindowID(rawValue: "user")
    system.windows.append(WindowSnapshot(id: user, processIdentifier: 930_001, title: "User",
                                         frame: BTRect(x: 50, y: 50, width: 400, height: 300), displayID: system.mainDisplay.id))
    system.eventHandler?(WindowSystemEvent(kind: .created, windowID: user, processIdentifier: 930_001))
    try #require(await waitFor { model.activeTabbedState?.windowIDs.contains(user) == true })
    try await Task.sleep(for: .milliseconds(300))
    model.performTabbed(.float(user))
    try #require(await waitFor { model.activeTabbedState?.floatingWindowIDs.contains(user) == true })
    try await Task.sleep(for: .milliseconds(300))
    let tall = addFalselyMeasuredWindow("tall", pid: 930_002, to: system)
    try #require(await waitFor { model.activeTabbedState?.automaticallyFloatingWindowIDs == [tall] })
    try #require(await waitFor { model.lastActionFeedback?.message.hasSuffix("is floating") == true })
    try await Task.sleep(for: .milliseconds(300))
    // The application now reports a smaller minimum.
    let index = try #require(system.windows.firstIndex { $0.id == tall })
    system.windows[index].constraints = WindowConstraints()

    model.performTabbed(.repair)

    #expect(await waitFor { model.activeTabbedState?.windowIDs.contains(tall) == true })
    #expect(model.activeTabbedState?.floatingWindowIDs == [user])
    #expect(model.activeTabbedState?.automaticallyFloatingWindowIDs.isEmpty == true)
    #expect(await waitFor { model.lastActionFeedback?.message == "1 window returned to a pane" })
}

/// An automatic float is checked again once, a moment after its placement
/// settles, with a fresh snapshot. An application that was busy, or that
/// applied its size late, then gets a pane without a repair.
@Test @MainActor func anAutomaticFloatIsCheckedAgainOnce() async throws {
    let (system, model) = try await onePaneFixture()
    defer { model.shutdown() }
    model.tabbedAutomaticFloatRetryDelay = .seconds(1)
    let tall = addFalselyMeasuredWindow("tall", pid: 930_011, to: system)
    try #require(await waitFor { model.activeTabbedState?.automaticallyFloatingWindowIDs == [tall] })
    // The window's real minimum shows before the check.
    let index = try #require(system.windows.firstIndex { $0.id == tall })
    system.windows[index].constraints = WindowConstraints()

    #expect(await waitFor(timeout: .seconds(5)) { model.activeTabbedState?.windowIDs.contains(tall) == true })
    #expect(model.activeTabbedState?.floatingWindowIDs.isEmpty == true)
}

/// A window that still fits no pane at all is checked once, then left
/// floating: the check does not repeat or move it again.
@Test @MainActor func anAutomaticFloatThatStillCannotFitIsCheckedOnlyOnce() async throws {
    let (system, model) = try await onePaneFixture()
    defer { model.shutdown() }
    model.tabbedAutomaticFloatRetryDelay = .milliseconds(200)
    let tall = addFalselyMeasuredWindow("tall", pid: 930_021, to: system)
    try #require(await waitFor { model.activeTabbedState?.automaticallyFloatingWindowIDs == [tall] })
    // Wait for the one later check. A loaded runner can start it late.
    try #require(await waitFor(timeout: .seconds(20)) { model.tabbedAutomaticFloatChecksRun == 1 })
    let writes = system.frameWriteCounts[tall, default: 0]
    let sweeps = system.completeSweepCount
    try await Task.sleep(for: .milliseconds(800))
    #expect(model.tabbedAutomaticFloatChecksRun == 1)
    #expect(model.activeTabbedState?.automaticallyFloatingWindowIDs == [tall])
    #expect(system.frameWriteCounts[tall, default: 0] == writes)
    #expect(system.completeSweepCount == sweeps)
}

/// Bento floats a seventh window on its own. Entering Tabbed keeps it an
/// automatic float rather than the user's, and offers it a pane at once.
@Test @MainActor func enteringTabbedFromBentoGivesBentoFloatsAPane() async throws {
    _ = NSApplication.shared
    let system = FakeAppWindowSystem()
    let area = system.mainDisplay.visibleFrame
    system.windows = (0..<7).map { index in
        WindowSnapshot(id: WindowID(rawValue: "w\(index)"), processIdentifier: 930_100 + Int32(index),
                       title: "W\(index)", frame: area, displayID: system.mainDisplay.id)
    }
    let model = makeModel(system: system)
    defer { model.shutdown() }
    // The later check must not be what brings it in.
    model.tabbedAutomaticFloatRetryDelay = .seconds(60)
    model.setActiveMode(.bento)
    try #require(await waitFor { Set(system.windows.map(\.frame)).count >= 6 })
    try await Task.sleep(for: .milliseconds(300))
    model.setActiveMode(.tabbed)

    #expect(await waitFor { model.activeTabbedState?.windowIDs.count == 7 },
            "\(model.activeTabbedState?.panes.map(\.tabs) as Any) \(model.activeTabbedState?.floatingWindowIDs as Any)")
    #expect(model.activeTabbedState?.floatingWindowIDs.isEmpty == true)
    #expect(model.activeTabbedState?.panes.count == 6)
}

/// Repair keeps a proven minimum. A window whose probe measured it taller
/// than the work area below the strip stays floating, and Repair writes no
/// frame to it, now or later.
@Test @MainActor func repairKeepsAProvenMinimumAndDoesNotLoop() async throws {
    let (system, model) = try await onePaneFixture()
    defer { model.shutdown() }
    model.tabbedAutomaticFloatRetryDelay = .milliseconds(100)
    let tall = addFalselyMeasuredWindow("tall", pid: 930_031, to: system)
    let index = try #require(system.windows.firstIndex { $0.id == tall })
    system.windows[index].constraints.minimumSizeSource = .probe
    try #require(await waitFor { model.activeTabbedState?.automaticallyFloatingWindowIDs == [tall] })
    try await Task.sleep(for: .milliseconds(600))
    let writes = system.frameWriteCounts[tall, default: 0]

    model.performTabbed(.repair)
    try await Task.sleep(for: .milliseconds(800))

    #expect(model.activeTabbedState?.automaticallyFloatingWindowIDs == [tall])
    #expect(system.windows[index].constraints.minimumSize.height == 790)
    #expect(system.frameWriteCounts[tall, default: 0] == writes)
    #expect(model.lastActionFeedback?.message.contains("returned") != true)
}

/// Entering Tabbed is stored before its placement. When that placement
/// fails, later sweeps do not run the entry again, so they do not return the
/// same automatic floats and write their frames over and over.
@Test @MainActor func aFailedEntryPlacementDoesNotRepeatTheEntry() async throws {
    _ = NSApplication.shared
    let system = FakeAppWindowSystem()
    let area = system.mainDisplay.visibleFrame
    system.windows = (0..<7).map { index in
        WindowSnapshot(id: WindowID(rawValue: "w\(index)"), processIdentifier: 930_200 + Int32(index),
                       title: "W\(index)", frame: area, displayID: system.mainDisplay.id)
    }
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.tabbedAutomaticFloatRetryDelay = .seconds(60)
    model.setActiveMode(.bento)
    try #require(await waitFor { Set(system.windows.map(\.frame)).count >= 6 })
    try await Task.sleep(for: .milliseconds(300))
    // Six windows are tiled; Bento floats the seventh where it was.
    let overflow = try #require(system.windows.first { $0.frame == area }?.id)
    // Every write to the Bento float fails, so the entry placement fails.
    system.failedFrameWriteNumbers[overflow] = Set(1...200)
    model.setActiveMode(.tabbed)
    try #require(await waitFor { (system.frameWriteCounts[overflow] ?? 0) > 0 })
    try await Task.sleep(for: .milliseconds(500))
    let writes = system.frameWriteCounts[overflow, default: 0]
    for _ in 0..<3 {
        model.setActiveMode(.tabbed) // Already Tabbed: only a forced sweep.
        try await Task.sleep(for: .milliseconds(300))
    }

    #expect(system.frameWriteCounts[overflow, default: 0] == writes)
    #expect(model.activeTabbedState?.automaticallyFloatingWindowIDs == [overflow])
}

/// Selecting a hidden tab that is larger than its pane grows the pane when
/// the other pane can give the room. When the other windows have since grown
/// and it cannot, the pill names the problem and the previous selection
/// stays; nothing overlaps.
@Test(arguments: [false, true]) @MainActor
func selectingALargeHiddenTabGrowsItsPaneOrKeepsTheSelection(impossible: Bool) async throws {
    _ = NSApplication.shared
    let system = FakeAppWindowSystem()
    let peer = WindowID(rawValue: "peer")
    system.windows.append(WindowSnapshot(id: peer, processIdentifier: 930_401, title: "Peer",
        frame: BTRect(x: 500, y: 0, width: 500, height: 800), displayID: system.mainDisplay.id))
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.configuration.defaultTabbedPreset = .columns
    model.setActiveMode(.tabbed)
    try #require(await waitFor { model.activeTabbedState?.windowIDs.count == 2 })
    let right = try #require(model.activeTabbedState?.panes[1].id)
    model.performTabbed(.move(peer, pane: right, index: nil))
    try #require(await waitFor { model.activeTabbedState?.panes[1].selected == peer })
    let first = system.windows[0].id
    model.performTabbed(.select(first))
    try await Task.sleep(for: .milliseconds(300))
    let wide = WindowID(rawValue: "wide")
    var window = WindowSnapshot(id: wide, processIdentifier: 930_402, title: "Wide",
        frame: BTRect(x: 100, y: 100, width: 700, height: 500), displayID: system.mainDisplay.id)
    window.constraints.minimumSize = BTSize(width: 700, height: 300)
    system.windows.append(window)
    system.eventHandler?(WindowSystemEvent(kind: .created, windowID: wide, processIdentifier: 930_402))
    // It fits the active pane once the divider moves, so it arrives
    // selected; showing the other tab again hides it.
    try #require(await waitFor { model.activeTabbedState?.panes[0].selected == wide })
    try await Task.sleep(for: .milliseconds(300))
    model.performTabbed(.select(first))
    try #require(await waitFor { model.activeTabbedState?.hiddenWindowIDs.contains(wide) == true })
    #expect(model.activeTabbedState?.pane(containing: wide)?.id == model.activeTabbedState?.panes[0].id)
    try await Task.sleep(for: .milliseconds(300))
    if impossible {
        for index in system.windows.indices where system.windows[index].id != wide {
            system.windows[index].constraints.minimumSize = BTSize(width: 400, height: 80)
        }
    }

    model.performTabbed(.select(wide))

    if impossible {
        #expect(await waitFor { model.lastActionFeedback?.message.hasSuffix("doesn’t fit here") == true },
                "\(model.lastActionFeedback as Any)")
        #expect(model.activeTabbedState?.panes[0].selected == first)
    } else {
        #expect(await waitFor { model.activeTabbedState?.panes[0].selected == wide })
        let frames = try #require(model.activeTabbedState?.frames(in: system.mainDisplay.visibleFrame))
        #expect((frames[model.activeTabbedState!.panes[0].id]?.size.width ?? 0) >= 700)
        let shown = [wide, peer].compactMap { id in system.windows.first { $0.id == id }?.frame }
        #expect(shown.count == 2 && (shown[0].maxX <= shown[1].minX || shown[1].maxX <= shown[0].minX), "\(shown)")
    }
}

/// A window whose only large minimum is its application's seed plans
/// without that seed: it joins as the selected tab, and stays selectable,
/// because the write shows its real minimum.
@Test @MainActor func aWindowWithALargeSeedJoinsAndStaysSelectable() async throws {
    let (system, model) = try await onePaneFixture()
    defer { model.shutdown() }
    let first = try #require(system.windows.first?.id)
    let seeded = WindowID(rawValue: "seeded")
    var window = WindowSnapshot(id: seeded, processIdentifier: 930_501, title: "Seeded",
        frame: BTRect(x: 100, y: 5, width: 600, height: 790), displayID: system.mainDisplay.id)
    window.constraints.minimumSize = BTSize(width: 600, height: 790)
    window.constraints.minimumSizeSource = .seed
    system.windows.append(window)
    system.eventHandler?(WindowSystemEvent(kind: .created, windowID: seeded, processIdentifier: 930_501))
    let content = TabbedLayoutState.contentFrame(system.mainDisplay.visibleFrame)
    #expect(await waitFor { model.activeTabbedState?.activeWindowID == seeded })
    #expect(await waitFor { system.windows.first { $0.id == seeded }?.frame == content })
    try await Task.sleep(for: .milliseconds(300))

    model.performTabbed(.select(first))
    try #require(await waitFor { model.activeTabbedState?.hiddenWindowIDs.contains(seeded) == true })
    try await Task.sleep(for: .milliseconds(300))
    model.performTabbed(.select(seeded))

    #expect(await waitFor { model.activeTabbedState?.activeWindowID == seeded }, "\(model.lastActionFeedback as Any)")
    #expect(await waitFor { system.windows.first { $0.id == seeded }?.frame == content })
}

/// Undo that brings an automatic float back does not start its later check,
/// which would undo part of the Undo.
@Test @MainActor func undoToAnAutomaticFloatDoesNotCheckItAgain() async throws {
    let (system, model) = try await onePaneFixture()
    defer { model.shutdown() }
    model.tabbedAutomaticFloatRetryDelay = .milliseconds(200)
    let tall = addFalselyMeasuredWindow("tall", pid: 930_601, to: system)
    try #require(await waitFor { model.activeTabbedState?.automaticallyFloatingWindowIDs == [tall] })
    // Well past the later check, so it cannot return the window later.
    try await Task.sleep(for: .milliseconds(1_500))
    let index = try #require(system.windows.firstIndex { $0.id == tall })
    system.windows[index].constraints = WindowConstraints()
    let pane = try #require(model.activeTabbedState?.panes[0].id)
    model.performTabbed(.move(tall, pane: pane, index: nil))
    try #require(await waitFor { model.activeTabbedState?.windowIDs.contains(tall) == true })
    try await Task.sleep(for: .milliseconds(300))

    model.performTabbed(.undo)
    try #require(await waitFor { model.activeTabbedState?.automaticallyFloatingWindowIDs == [tall] })
    try await Task.sleep(for: .milliseconds(800))
    #expect(model.activeTabbedState?.automaticallyFloatingWindowIDs == [tall])
}

/// Leaving Tabbed for Bento hands Tabbed's automatic floats to Bento as its
/// own, so Bento offers them a pane; Bento panes have no tab strip.
@Test @MainActor func leavingForBentoHandsAutomaticFloatsToBento() async throws {
    let (system, model) = try await onePaneFixture()
    defer { model.shutdown() }
    model.tabbedAutomaticFloatRetryDelay = .seconds(60)
    let tall = addFalselyMeasuredWindow("tall", pid: 930_701, to: system)
    try #require(await waitFor { model.activeTabbedState?.automaticallyFloatingWindowIDs == [tall] })
    try await Task.sleep(for: .milliseconds(300))

    model.setActiveMode(.bento)
    try await Task.sleep(for: .milliseconds(300))
    // The next desktop sweep offers Bento's own floats a pane.
    system.eventHandler?(WindowSystemEvent(kind: .created, windowID: tall, processIdentifier: 930_701))

    // Bento tiles it beside the other window, at least as tall as its minimum.
    #expect(await waitFor {
        guard let frame = system.windows.first(where: { $0.id == tall })?.frame,
              let other = system.windows.first(where: { $0.id != tall })?.frame else { return false }
        return frame.origin != BTPoint(x: 100, y: 5) && frame.size.height >= 790
            && (frame.maxX <= other.minX || other.maxX <= frame.minX)
    }, "\(system.windows.map(\.frame))")
}

/// The later check waits while another placement owns the display, then
/// runs. If the display stays busy, it gives up and the window stays an
/// automatic float for Repair Tabbed.
@Test(arguments: [false, true]) @MainActor
func theLaterCheckWaitsForABusyDisplayOrGivesUp(staysBusy: Bool) async throws {
    let (system, model) = try await onePaneFixture()
    defer { model.shutdown() }
    // Wide margins: the drag must begin before the check, and a loaded
    // runner must not use up the ten waits before the drag ends.
    model.tabbedAutomaticFloatRetryDelay = .seconds(1)
    model.tabbedAutomaticFloatRetryDeferral = .milliseconds(staysBusy ? 10 : 400)
    let other = try #require(system.windows.first?.id)
    let tall = addFalselyMeasuredWindow("tall", pid: 930_801, to: system)
    try #require(await waitFor(timeout: .milliseconds(900)) {
        model.activeTabbedState?.automaticallyFloatingWindowIDs == [tall]
    })
    try #require(model.beginBentoDrag(displayID: system.mainDisplay.id, sourceID: other))
    let index = try #require(system.windows.firstIndex { $0.id == tall })
    system.windows[index].constraints = WindowConstraints()
    if staysBusy {
        try #require(await waitFor(timeout: .seconds(5)) { model.tabbedAutomaticFloatChecksGivenUp == 1 })
    } else {
        // The check runs at 1 s and waits for the drag until about 5 s.
        try await Task.sleep(for: .milliseconds(1_500))
    }
    #expect(model.activeTabbedState?.automaticallyFloatingWindowIDs == [tall])

    model.finishBentoDrag(displayID: system.mainDisplay.id, sourceID: other, outcome: .restore)

    if staysBusy {
        try await Task.sleep(for: .milliseconds(800))
        #expect(model.activeTabbedState?.automaticallyFloatingWindowIDs == [tall])
    } else {
        #expect(await waitFor(timeout: .seconds(5)) { model.activeTabbedState?.windowIDs.contains(tall) == true })
    }
}

/// A later check that fails says nothing: the user did not ask for it.
@Test @MainActor func aFailedLaterCheckIsSilent() async throws {
    let (system, model) = try await onePaneFixture()
    defer { model.shutdown() }
    model.tabbedAutomaticFloatRetryDelay = .milliseconds(300)
    let tall = addFalselyMeasuredWindow("tall", pid: 930_901, to: system)
    try #require(await waitFor { model.lastActionFeedback?.message.hasSuffix("is floating") == true })
    let feedback = model.lastActionFeedback
    let index = try #require(system.windows.firstIndex { $0.id == tall })
    system.windows[index].constraints = WindowConstraints()
    // It keeps focus, so the check makes it the selected tab rather than a
    // hidden tab behind the focused window. Its pane write fails, so the
    // check's placement fails.
    system.focusedID = tall
    system.acceptsFocusRequests = false
    system.failedFrameWriteNumbers[tall] = Set(1...100)
    let writesBefore = system.frameWriteCounts[tall, default: 0]

    // The check ran and tried to show it. A loaded runner can start it late.
    #expect(await waitFor(timeout: .seconds(20)) { system.frameWriteCounts[tall, default: 0] > writesBefore })
    // Give a failure pill time to appear if the check were to show one.
    try await Task.sleep(for: .milliseconds(500))
    #expect(model.lastActionFeedback == feedback)
    #expect(model.statusMessage == nil)
    #expect(model.activeTabbedState?.automaticallyFloatingWindowIDs == [tall])
}

/// A window 950 pt wide at least: too wide for a pane beside another, but
/// not for the 1000-pt work area.
@MainActor
private func addWideWindow(_ name: String, pid: Int32, to system: FakeAppWindowSystem) -> WindowID {
    let id = WindowID(rawValue: name)
    var window = WindowSnapshot(id: id, processIdentifier: pid, title: name.capitalized,
                                frame: BTRect(x: 20, y: 100, width: 950, height: 500), displayID: system.mainDisplay.id)
    window.constraints.minimumSize = BTSize(width: 950, height: 300)
    system.windows.append(window)
    system.eventHandler?(WindowSystemEvent(kind: .created, windowID: id, processIdentifier: pid))
    return id
}

/// Changing the layout to One Pane makes room for an automatic float, so it
/// returns without a repair. Change Layout focuses the pane's tab, so the
/// float joins behind it as a hidden tab and focus stays; when the float
/// itself keeps focus, it becomes the selected tab. A window the user
/// floated stays floating.
@Test(arguments: [false, true]) @MainActor
func changingToOnePaneReturnsAnAutomaticFloatAndKeepsUserFloats(floatIsFocused: Bool) async throws {
    _ = NSApplication.shared
    let system = FakeAppWindowSystem()
    let model = makeModel(system: system)
    defer { model.shutdown() }
    // The one later check must not be what brings it in.
    model.tabbedAutomaticFloatRetryDelay = .seconds(60)
    model.configuration.defaultTabbedPreset = .columns
    model.setActiveMode(.tabbed)
    try #require(await waitFor { model.activeTabbedState?.windowIDs.count == 1 })
    let user = WindowID(rawValue: "user")
    system.windows.append(WindowSnapshot(id: user, processIdentifier: 931_001, title: "User",
                                         frame: BTRect(x: 50, y: 50, width: 400, height: 300), displayID: system.mainDisplay.id))
    system.eventHandler?(WindowSystemEvent(kind: .created, windowID: user, processIdentifier: 931_001))
    try #require(await waitFor { model.activeTabbedState?.windowIDs.contains(user) == true })
    try await Task.sleep(for: .milliseconds(300))
    model.performTabbed(.float(user))
    try #require(await waitFor { model.activeTabbedState?.floatingWindowIDs.contains(user) == true })
    try await Task.sleep(for: .milliseconds(300))
    let wide = addWideWindow("wide", pid: 931_002, to: system)
    try #require(await waitFor { model.activeTabbedState?.automaticallyFloatingWindowIDs == [wide] })
    try await Task.sleep(for: .milliseconds(300))

    let shown = system.windows[0].id
    if floatIsFocused {
        system.focusedID = wide
        system.acceptsFocusRequests = false
    }

    model.performTabbed(.preset(.single))

    #expect(await waitFor { model.activeTabbedState?.pane(containing: wide) != nil },
            "\(model.activeTabbedState?.panes.map(\.tabs) as Any)")
    #expect(model.activeTabbedState?.floatingWindowIDs == [user])
    if !floatIsFocused {
        try await Task.sleep(for: .milliseconds(300))
        #expect(model.activeTabbedState?.panes.first?.selected == shown)
        #expect(system.focusedID == shown)
    } else {
        #expect(model.activeTabbedState?.panes.first?.selected == wide)
        let content = TabbedLayoutState.contentFrame(system.mainDisplay.visibleFrame)
        #expect(await waitFor { system.windows.first { $0.id == wide }?.frame == content })
    }
}

/// Removing the empty pane beside an automatic float's only possible pane
/// returns it as that pane's selected tab.
@Test @MainActor func removingAPaneReturnsAnAutomaticFloat() async throws {
    _ = NSApplication.shared
    let system = FakeAppWindowSystem()
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.tabbedAutomaticFloatRetryDelay = .seconds(60)
    model.configuration.defaultTabbedPreset = .columns
    model.setActiveMode(.tabbed)
    try #require(await waitFor { model.activeTabbedState?.windowIDs.count == 1 })
    try await Task.sleep(for: .milliseconds(300))
    let wide = addWideWindow("wide", pid: 931_101, to: system)
    try #require(await waitFor { model.activeTabbedState?.automaticallyFloatingWindowIDs == [wide] })
    try await Task.sleep(for: .milliseconds(300))
    let empty = try #require(model.activeTabbedState?.panes.first { $0.tabs.isEmpty }?.id)
    system.focusedID = wide

    model.performTabbed(.removePane(empty))

    #expect(await waitFor { model.activeTabbedState?.panes.first?.selected == wide },
            "\(model.activeTabbedState?.panes.map(\.tabs) as Any)")
    #expect(model.activeTabbedState?.floatingWindowIDs.isEmpty == true)
}

/// A work area that grows, for example when the Dock hides, returns an
/// automatic float that now fits.
@Test @MainActor func aLargerWorkAreaReturnsAnAutomaticFloat() async throws {
    _ = NSApplication.shared
    let system = FakeAppWindowSystem()
    system.availableDisplays[0].visibleFrame.size.width = 800
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.tabbedAutomaticFloatRetryDelay = .seconds(60)
    model.configuration.defaultTabbedPreset = .single
    model.setActiveMode(.tabbed)
    try #require(await waitFor { model.activeTabbedState?.windowIDs.count == 1 })
    try await Task.sleep(for: .milliseconds(300))
    let wide = addWideWindow("wide", pid: 931_201, to: system)
    try #require(await waitFor { model.activeTabbedState?.automaticallyFloatingWindowIDs == [wide] })
    try await Task.sleep(for: .milliseconds(300))

    system.focusedID = wide
    system.availableDisplays[0].visibleFrame.size.width = 1000
    system.eventHandler?(WindowSystemEvent(kind: .created, windowID: wide, processIdentifier: 931_201))

    #expect(await waitFor { model.activeTabbedState?.panes.first?.selected == wide },
            "\(model.activeTabbedState?.panes.map(\.tabs) as Any)")
    #expect(model.activeTabbedState?.floatingWindowIDs.isEmpty == true)
}

/// A layout change that still leaves no room keeps the automatic float and
/// says nothing: the user did not ask for the check.
@Test @MainActor func aLayoutChangeWithoutRoomKeepsTheFloatSilently() async throws {
    _ = NSApplication.shared
    let system = FakeAppWindowSystem()
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.tabbedAutomaticFloatRetryDelay = .seconds(60)
    model.configuration.defaultTabbedPreset = .columns
    model.setActiveMode(.tabbed)
    try #require(await waitFor { model.activeTabbedState?.windowIDs.count == 1 })
    try await Task.sleep(for: .milliseconds(300))
    let wide = addWideWindow("wide", pid: 931_301, to: system)
    try #require(await waitFor { model.lastActionFeedback?.message == "Wide is floating" })
    try await Task.sleep(for: .milliseconds(300))
    let feedback = model.lastActionFeedback
    let writes = system.frameWriteCounts[wide, default: 0]

    model.performTabbed(.preset(.grid))
    try #require(await waitFor { model.activeTabbedState?.panes.count == 4 })
    try await Task.sleep(for: .milliseconds(500))

    #expect(model.activeTabbedState?.automaticallyFloatingWindowIDs == [wide])
    #expect(system.frameWriteCounts[wide, default: 0] == writes)
    #expect(model.lastActionFeedback == feedback)
    #expect(model.statusMessage == nil)
}

/// Showing a smaller tab beside the pane an automatic float needs makes
/// room, so the float returns to that pane without a repair.
@Test @MainActor func selectingASmallerTabNextDoorReturnsAnAutomaticFloat() async throws {
    _ = NSApplication.shared
    let system = FakeAppWindowSystem()
    system.windows[0].constraints.minimumSize = BTSize(width: 400, height: 80)
    let large = system.windows[0].id
    let peer = WindowID(rawValue: "peer"), small = WindowID(rawValue: "small")
    for (index, id) in [peer, small].enumerated() {
        var window = WindowSnapshot(id: id, processIdentifier: 931_401 + Int32(index), title: id.rawValue.capitalized,
                                    frame: BTRect(x: 500, y: 0, width: 500, height: 800), displayID: system.mainDisplay.id)
        window.constraints.minimumSize = BTSize(width: id == peer ? 400 : 120, height: 80)
        system.windows.append(window)
    }
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.tabbedAutomaticFloatRetryDelay = .seconds(60)
    model.configuration.defaultTabbedPreset = .columns
    model.setActiveMode(.tabbed)
    try #require(await waitFor { model.activeTabbedState?.windowIDs.count == 3 })
    let right = try #require(model.activeTabbedState?.panes[1].id)
    model.performTabbed(.move(small, pane: right, index: nil))
    try #require(await waitFor { model.activeTabbedState?.pane(containing: small)?.id == right })
    model.performTabbed(.move(peer, pane: right, index: nil))
    try #require(await waitFor { model.activeTabbedState?.panes[1].selected == peer })
    model.performTabbed(.select(large))
    try #require(await waitFor { model.activeTabbedState?.activePaneID == model.activeTabbedState?.panes[0].id })
    try await Task.sleep(for: .milliseconds(300))
    let wide = WindowID(rawValue: "wide")
    var window = WindowSnapshot(id: wide, processIdentifier: 931_410, title: "Wide",
                                frame: BTRect(x: 20, y: 100, width: 700, height: 500), displayID: system.mainDisplay.id)
    window.constraints.minimumSize = BTSize(width: 700, height: 300)
    system.windows.append(window)
    system.eventHandler?(WindowSystemEvent(kind: .created, windowID: wide, processIdentifier: 931_410))
    try #require(await waitFor { model.activeTabbedState?.automaticallyFloatingWindowIDs == [wide] },
                 "\(model.activeTabbedState?.panes.map(\.tabs) as Any)")
    try await Task.sleep(for: .milliseconds(300))

    model.performTabbed(.select(small))

    #expect(await waitFor { model.activeTabbedState?.pane(containing: wide)?.id == model.activeTabbedState?.panes[0].id },
            "\(model.activeTabbedState?.panes.map(\.tabs) as Any)")
    #expect(model.activeTabbedState?.floatingWindowIDs.isEmpty == true)
}

/// Review: the later check and Repair Tabbed return a window to a pane
/// other than the active one as its selected tab, as the layout-change check
/// does. Hidden behind that pane's tab, the window was lost from view.
@Test(arguments: ["later check", "repair"]) @MainActor
func aFloatReturnedToAnotherPaneIsShown(path: String) async throws {
    _ = NSApplication.shared
    let system = FakeAppWindowSystem()
    let first = system.windows[0].id, peer = WindowID(rawValue: "peer")
    var window = WindowSnapshot(id: peer, processIdentifier: 931_501, title: "Peer",
                                frame: BTRect(x: 500, y: 0, width: 500, height: 800), displayID: system.mainDisplay.id)
    window.constraints.minimumSize = BTSize(width: 400, height: 80)
    system.windows.append(window)
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.tabbedAutomaticFloatRetryDelay = path == "repair" ? .seconds(60) : .seconds(1)
    model.configuration.defaultTabbedPreset = .columns
    model.setActiveMode(.tabbed)
    try #require(await waitFor { model.activeTabbedState?.windowIDs.count == 2 })
    let right = try #require(model.activeTabbedState?.panes[1].id)
    if model.activeTabbedState?.pane(containing: peer)?.id != right {
        model.performTabbed(.move(peer, pane: right, index: nil))
        try #require(await waitFor { model.activeTabbedState?.panes[1].selected == peer })
    }
    model.performTabbed(.select(first))
    try #require(await waitFor { model.activeTabbedState?.activePaneID == model.activeTabbedState?.panes[0].id })
    try await Task.sleep(for: .milliseconds(300))
    system.focusedID = first
    let tall = addFalselyMeasuredWindow("tall", pid: 931_502, to: system)
    try #require(await waitFor { model.activeTabbedState?.automaticallyFloatingWindowIDs == [tall] })
    try await Task.sleep(for: .milliseconds(300))
    // Too wide for the active pane beside the peer; the right pane can grow.
    let index = try #require(system.windows.firstIndex { $0.id == tall })
    system.windows[index].constraints = WindowConstraints(minimumSize: BTSize(width: 700, height: 80))

    if path == "repair" { model.performTabbed(.repair) }

    #expect(await waitFor(timeout: .seconds(5)) { model.activeTabbedState?.panes[1].selected == tall },
            "\(model.activeTabbedState?.panes.map(\.tabs) as Any)")
    #expect(model.activeTabbedState?.panes[0].selected == first)
    #expect(model.activeTabbedState?.floatingWindowIDs.isEmpty == true)
}
