import AppKit
import BetterTileCore
@testable import BetterTileMacOS
import Testing
@testable import BetterTileApp

// Terminal resizes in whole character cells and rounds to the nearest one,
// up or down. A pane follows the size the window settles at; its neighbour
// gives or takes the difference.

private let rowStep = 14.0

/// `names[0]` is selected in the first pane, `names[1]` in the second; any
/// others are hidden tabs of the first pane.
@MainActor private func makeTabbed(
    _ system: FakeAppWindowSystem, _ preset: TabbedPreset, _ names: [String]
) async throws -> BetterTileModel {
    _ = NSApplication.shared
    let base = system.windows[0]
    system.windows = names.enumerated().map { index, name in
        var window = base
        window.id = WindowID(rawValue: name)
        window.processIdentifier = pid_t(300 + index)
        window.title = name
        window.frame = BTRect(x: 20 * Double(index), y: 20, width: 500, height: 400)
        return window
    }
    let model = makeModel(system: system)
    model.configuration.defaultTabbedPreset = preset
    model.setActiveMode(.tabbed)
    try #require(await waitFor { model.activeTabbedState?.windowIDs.count == names.count })
    let second = try #require(model.activeTabbedState?.panes[1].id)
    let first = WindowID(rawValue: names[0]), other = WindowID(rawValue: names[1])
    model.performTabbed(.move(other, pane: second, index: nil))
    try #require(await waitFor { model.activeTabbedState?.panes[1].selected == other })
    model.performTabbed(.select(first))
    try #require(await waitFor { model.activeTabbedState?.activeWindowID == first })
    try await Task.sleep(for: .milliseconds(400))
    return model
}

@MainActor private func content(_ pane: Int, _ model: BetterTileModel, _ system: FakeAppWindowSystem) -> BTRect? {
    guard let state = model.activeTabbedState,
          let frame = state.frames(in: system.mainDisplay.visibleFrame)[state.panes[pane].id] else { return nil }
    return TabbedLayoutState.contentFrame(frame)
}

@MainActor private func frame(_ name: String, _ system: FakeAppWindowSystem) -> BTRect? {
    system.windows.first { $0.id.rawValue == name }?.frame
}

@MainActor private func addTerminal(_ system: FakeAppWindowSystem, heightGrid: Double? = nil, widthGrid: Double? = nil) -> WindowID {
    var window = system.windows[0]
    window.id = WindowID(rawValue: "terminal")
    window.processIdentifier = 399
    window.title = "Terminal"
    window.frame = BTRect(x: 60, y: 60, width: 480, height: 300)
    system.windows.append(window)
    system.sizeGrids[window.id] = (BTSize(width: widthGrid == nil ? 0 : rowStep, height: heightGrid == nil ? 0 : rowStep),
                                   BTSize(width: widthGrid ?? 0, height: heightGrid ?? 0))
    return window.id
}

private func near(_ lhs: Double?, _ rhs: Double?, _ tolerance: Double = 0.6) -> Bool {
    guard let lhs, let rhs else { return false }
    return abs(lhs - rhs) <= tolerance
}

/// A new Terminal joins the top pane and rounds its height up 4 points. The
/// pane grows by 4 and the pane below gives them up; nothing fails.
@Test @MainActor func aNewSteppedWindowThatRoundsUpGrowsItsPane() async throws {
    let system = FakeAppWindowSystem()
    let model = try await makeTabbed(system, .rows, ["upper", "lower"])
    defer { model.shutdown() }
    let slot = try #require(content(0, model, system))
    let lowerBefore = try #require(frame("lower", system))
    let terminal = addTerminal(system, heightGrid: slot.size.height + 4)
    system.eventHandler?(WindowSystemEvent(kind: .created, windowID: terminal, processIdentifier: 399))

    #expect(await waitFor(timeout: .seconds(3)) {
        model.activeTabbedState?.panes[0].selected == terminal && near(content(0, model, system)?.size.height, slot.size.height + 4)
    })
    try await Task.sleep(for: .milliseconds(300))
    let placed = try #require(frame("terminal", system))
    #expect(near(placed.size.height, slot.size.height + 4))
    #expect(placed.approximatelyEquals(try #require(content(0, model, system)), tolerance: 0.6))
    let lower = try #require(frame("lower", system))
    #expect(near(lower.minY, lowerBefore.minY + 4))
    #expect(near(lower.maxY, lowerBefore.maxY))
    #expect(model.statusMessage == nil)
    #expect(model.activeTabbedState?.floatingWindowIDs.contains(terminal) == false)
    let writes = system.frameWriteCounts
    try await Task.sleep(for: .milliseconds(500))
    #expect(system.frameWriteCounts == writes)
}

/// Rounding down shrinks the pane to match, and the neighbour grows.
@Test @MainActor func aNewSteppedWindowThatRoundsDownShrinksItsPane() async throws {
    let system = FakeAppWindowSystem()
    let model = try await makeTabbed(system, .rows, ["upper", "lower"])
    defer { model.shutdown() }
    let slot = try #require(content(0, model, system))
    let lowerBefore = try #require(frame("lower", system))
    let terminal = addTerminal(system, heightGrid: slot.size.height - 6)
    system.eventHandler?(WindowSystemEvent(kind: .created, windowID: terminal, processIdentifier: 399))

    #expect(await waitFor(timeout: .seconds(3)) {
        model.activeTabbedState?.panes[0].selected == terminal && near(content(0, model, system)?.size.height, slot.size.height - 6)
    })
    try await Task.sleep(for: .milliseconds(300))
    #expect(near(frame("terminal", system)?.size.height, slot.size.height - 6))
    #expect(near(frame("lower", system)?.minY, lowerBefore.minY - 6))
    #expect(model.statusMessage == nil)
}

/// Both axes: in a 2×2 grid the Terminal's width and height both round up,
/// and its pane follows each.
@Test @MainActor func bothAxesSnap() async throws {
    let system = FakeAppWindowSystem()
    let model = try await makeTabbed(system, .grid, ["a", "b", "c", "d"])
    defer { model.shutdown() }
    let state = try #require(model.activeTabbedState)
    for (index, name) in ["c", "d"].enumerated() {
        model.performTabbed(.move(WindowID(rawValue: name), pane: state.panes[index + 2].id, index: nil))
        try #require(await waitFor { model.activeTabbedState?.panes[index + 2].selected == WindowID(rawValue: name) })
    }
    model.performTabbed(.select(WindowID(rawValue: "a")))
    try await Task.sleep(for: .milliseconds(400))
    let slot = try #require(content(0, model, system))
    let terminal = addTerminal(system, heightGrid: slot.size.height + 5, widthGrid: slot.size.width + 3)
    system.eventHandler?(WindowSystemEvent(kind: .created, windowID: terminal, processIdentifier: 399))

    #expect(await waitFor(timeout: .seconds(3)) {
        model.activeTabbedState?.panes[0].selected == terminal
            && near(content(0, model, system)?.size.height, slot.size.height + 5)
            && near(content(0, model, system)?.size.width, slot.size.width + 3)
    }, "\(String(describing: content(0, model, system))) \(String(describing: frame("terminal", system)))")
    #expect(frame("terminal", system)?.approximatelyEquals(try #require(content(0, model, system)), tolerance: 0.6) == true)
    #expect(model.statusMessage == nil)
}

/// The pane below is at its minimum, so it cannot give up the overflow.
/// The Terminal is asked for one step less, rounds down, and keeps a gap.
@Test @MainActor func aNeighbourAtItsMinimumLeavesAGapInstead() async throws {
    let system = FakeAppWindowSystem()
    let model = try await makeTabbed(system, .rows, ["upper", "lower"])
    defer { model.shutdown() }
    let slot = try #require(content(0, model, system))
    let lowerSlot = try #require(content(1, model, system))
    let index = try #require(system.windows.firstIndex { $0.id.rawValue == "lower" })
    system.windows[index].constraints.minimumSize.height = lowerSlot.size.height - 0.5
    let terminal = addTerminal(system, heightGrid: slot.size.height + 4)
    system.eventHandler?(WindowSystemEvent(kind: .created, windowID: terminal, processIdentifier: 399))

    #expect(await waitFor(timeout: .seconds(3)) {
        model.activeTabbedState?.panes[0].selected == terminal
            && near(frame("terminal", system)?.size.height, slot.size.height + 4 - rowStep)
    }, "\(String(describing: frame("terminal", system)))")
    try await Task.sleep(for: .milliseconds(300))
    #expect(near(content(0, model, system)?.size.height, slot.size.height))
    #expect(system.requestedFrames[terminal]?.last.map { near($0.size.height, slot.size.height - 4) } == true)
    #expect(model.statusMessage == nil)
}

/// Two Terminals stacked: one rounds up, one rounds down. The divider
/// between them stays, so neither chases the other; the placement takes one
/// extra write and then stops.
@Test @MainActor func twoSteppedWindowsStackedConvergeInOneRound() async throws {
    let system = FakeAppWindowSystem()
    let model = try await makeTabbed(system, .rows, ["upper", "lower"])
    defer { model.shutdown() }
    let upperSlot = try #require(content(0, model, system))
    let lowerSlot = try #require(content(1, model, system))
    system.sizeGrids[WindowID(rawValue: "upper")] = (BTSize(width: 0, height: rowStep),
                                                     BTSize(width: 0, height: upperSlot.size.height + 4))
    system.sizeGrids[WindowID(rawValue: "lower")] = (BTSize(width: 0, height: rowStep),
                                                     BTSize(width: 0, height: lowerSlot.size.height - 3))
    // Both windows drifted, so the repair writes both.
    for index in system.windows.indices { system.windows[index].frame.origin.x += 7 }
    let before = system.frameWriteCounts
    model.performTabbed(.repair)

    #expect(await waitFor(timeout: .seconds(3)) {
        near(frame("lower", system)?.size.height, lowerSlot.size.height - 3)
            && near(frame("upper", system)?.size.height, upperSlot.size.height + 4 - rowStep)
    }, "\(String(describing: frame("upper", system))) \(String(describing: frame("lower", system)))")
    try await Task.sleep(for: .milliseconds(600))
    let writes = system.frameWriteCounts
    #expect(writes[WindowID(rawValue: "upper"), default: 0] - before[WindowID(rawValue: "upper"), default: 0] == 2)
    #expect(writes[WindowID(rawValue: "lower"), default: 0] - before[WindowID(rawValue: "lower"), default: 0] <= 2)
    #expect(near(content(0, model, system)?.size.height, upperSlot.size.height))
    #expect(model.statusMessage == nil)
    try await Task.sleep(for: .milliseconds(500))
    #expect(system.frameWriteCounts == writes)
}

/// A Terminal dropped on the centre of the right column joins it. Its width
/// rounds up; the right pane grows to the left and the left pane gives way.
@Test @MainActor func aDroppedSteppedWindowGrowsItsPane() async throws {
    let system = FakeAppWindowSystem()
    let model = try await makeTabbed(system, .columns, ["left", "right", "terminal"])
    defer { model.shutdown() }
    let terminal = WindowID(rawValue: "terminal")
    let slot = try #require(content(1, model, system))
    let leftBefore = try #require(frame("left", system))
    system.sizeGrids[terminal] = (BTSize(width: rowStep, height: 0), BTSize(width: slot.size.width + 4, height: 0))
    #expect(model.completeBentoDrag(displayID: system.mainDisplay.id, sourceID: terminal,
                                    outcome: .swap(targetWindowID: WindowID(rawValue: "right"))))

    #expect(await waitFor(timeout: .seconds(3)) {
        model.activeTabbedState?.panes[1].selected == terminal && near(content(1, model, system)?.size.width, slot.size.width + 4)
    }, "\(String(describing: frame("terminal", system)))")
    try await Task.sleep(for: .milliseconds(300))
    #expect(near(frame("terminal", system)?.minX, slot.minX - 4))
    #expect(near(frame("terminal", system)?.size.width, slot.size.width + 4))
    #expect(near(frame("left", system)?.size.width, leftBefore.size.width - 4))
    #expect(model.statusMessage == nil)
}

/// Add Floating Window Here: a floating Terminal joins the lower pane and
/// rounds its height down; the pane follows.
@Test @MainActor func aSteppedWindowAddedFromThePaneMenuFitsItsPane() async throws {
    let system = FakeAppWindowSystem()
    let model = try await makeTabbed(system, .rows, ["upper", "lower", "terminal"])
    defer { model.shutdown() }
    let terminal = WindowID(rawValue: "terminal")
    model.performTabbed(.float(terminal))
    try #require(await waitFor { model.activeTabbedState?.floatingWindowIDs.contains(terminal) == true })
    try await Task.sleep(for: .milliseconds(300))
    let slot = try #require(content(1, model, system))
    system.sizeGrids[terminal] = (BTSize(width: 0, height: rowStep), BTSize(width: 0, height: slot.size.height - 5))
    let lower = try #require(model.activeTabbedState?.panes[1].id)
    model.performTabbed(.move(terminal, pane: lower, index: nil))

    #expect(await waitFor(timeout: .seconds(3)) {
        model.activeTabbedState?.panes[1].selected == terminal && near(content(1, model, system)?.size.height, slot.size.height - 5)
    }, "\(String(describing: frame("terminal", system)))")
    #expect(near(frame("terminal", system)?.minY, slot.minY + 5))
    #expect(model.statusMessage == nil)
}

/// Selecting another tab returns the pane to the user's size. Selecting the
/// Terminal again fits the pane to the size it is known to keep before the
/// write, so it takes one write, not a refused one and a correction.
@Test @MainActor func reselectingASteppedTabTakesOneWrite() async throws {
    let system = FakeAppWindowSystem()
    let model = try await makeTabbed(system, .rows, ["upper", "lower"])
    defer { model.shutdown() }
    let slot = try #require(content(0, model, system))
    let terminal = addTerminal(system, heightGrid: slot.size.height + 4)
    system.eventHandler?(WindowSystemEvent(kind: .created, windowID: terminal, processIdentifier: 399))
    try #require(await waitFor(timeout: .seconds(3)) {
        model.activeTabbedState?.panes[0].selected == terminal && near(content(0, model, system)?.size.height, slot.size.height + 4)
    })
    try await Task.sleep(for: .milliseconds(300))

    model.performTabbed(.select(WindowID(rawValue: "upper")))
    #expect(await waitFor { near(content(0, model, system)?.size.height, slot.size.height) })
    try await Task.sleep(for: .milliseconds(400))
    let writes = system.frameWriteCounts[terminal, default: 0]
    let requests = system.requestedFrames[terminal]?.count ?? 0
    model.performTabbed(.select(terminal))
    #expect(await waitFor { near(content(0, model, system)?.size.height, slot.size.height + 4) })
    try await Task.sleep(for: .milliseconds(400))
    #expect(model.activeTabbedState?.panes[0].selected == terminal)
    #expect(system.frameWriteCounts[terminal, default: 0] - writes <= 1)
    // As a hidden tab it already holds its size; any write asks for exactly that.
    #expect(system.requestedFrames[terminal, default: []].dropFirst(requests).allSatisfy { near($0.size.height, slot.size.height + 4) })
    #expect(near(frame("terminal", system)?.size.height, slot.size.height + 4))
    #expect(model.statusMessage == nil)
}

/// Live failure: Terminal rounded up one row and held it, and that size was
/// learned as its minimum and its application's seed. Two Terminals then
/// no longer fit stacked. A size within one step of a Tabbed request is the
/// window's step, never a minimum, so the second Terminal can still move.
@Test @MainActor func aSteppedSizeIsNotLearnedAsAMinimum() async throws {
    let system = FakeAppWindowSystem()
    let model = try await makeTabbed(system, .rows, ["upper", "lower"])
    defer { model.shutdown() }
    model.performTabbed(.select(WindowID(rawValue: "lower")))
    try #require(await waitFor { model.activeTabbedState?.activeWindowID == WindowID(rawValue: "lower") })
    try await Task.sleep(for: .milliseconds(300))
    let slot = try #require(content(1, model, system))
    system.measuresOnWrite = true
    func arrive(_ name: String) -> WindowID {
        let id = addTerminal(system, heightGrid: slot.size.height + 5)
        let index = system.windows.count - 1
        system.windows[index].id = WindowID(rawValue: name)
        system.windows[index].bundleIdentifier = "com.apple.Terminal"
        system.sizeGrids[WindowID(rawValue: name)] = system.sizeGrids.removeValue(forKey: id)
        system.enforcedMinimumHeights[WindowID(rawValue: name)] = 124
        system.eventHandler?(WindowSystemEvent(kind: .created, windowID: WindowID(rawValue: name),
                                              processIdentifier: system.windows[index].processIdentifier))
        return WindowID(rawValue: name)
    }
    let first = arrive("first")
    try #require(await waitFor(timeout: .seconds(3)) {
        model.activeTabbedState?.panes[1].selected == first && near(content(1, model, system)?.size.height, slot.size.height + 5)
    }, "\(String(describing: model.activeTabbedState?.panes.map(\.tabs))) \(String(describing: frame("first", system))) \(slot) \(model.statusMessage ?? "-") \(String(describing: system.windows.first { $0.id == first }?.constraints))")
    try await Task.sleep(for: .milliseconds(500))
    _ = try system.windowSnapshots(ids: [first]) // A late snapshot that could confirm a clamp.
    #expect((system.windows.first { $0.id == first }?.constraints.minimumSize.height ?? 0) < 200)

    // The second Terminal is never measured, so it plans with the seed.
    system.unprobeableWindowIDs = [WindowID(rawValue: "second")]
    let second = arrive("second")
    try #require(await waitFor(timeout: .seconds(3)) { model.activeTabbedState?.panes[1].selected == second })
    try await Task.sleep(for: .milliseconds(500))
    let upper = try #require(model.activeTabbedState?.panes[0].id)
    model.performTabbed(.move(first, pane: upper, index: nil))
    #expect(await waitFor(timeout: .seconds(3)) {
        model.activeTabbedState?.panes[0].selected == first && model.activeTabbedState?.panes[1].selected == second
    }, "\(model.statusMessage ?? "")")
    try await Task.sleep(for: .milliseconds(500))
    #expect(model.statusMessage == nil)
}
