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
        window.bundleIdentifier = "com.example.\(name)"
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
          let frame = state.frames(in: system.availableDisplays[0].visibleFrame)[state.panes[pane].id] else { return nil }
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
    window.bundleIdentifier = "com.apple.Terminal"
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
/// The Terminal is asked for more than one step less. Whatever its row
/// height and rounding, it lands inside its pane and keeps a gap; it may
/// round up toward the pane, and that is accepted.
@Test(arguments: [11.0, 14.0, 17.0, 20.0], [false, true]) @MainActor
func aNeighbourAtItsMinimumLeavesAGapInstead(step: Double, roundsUp: Bool) async throws {
    let system = FakeAppWindowSystem()
    let model = try await makeTabbed(system, .rows, ["upper", "lower"])
    defer { model.shutdown() }
    let slot = try #require(content(0, model, system))
    let lowerSlot = try #require(content(1, model, system))
    let index = try #require(system.windows.firstIndex { $0.id.rawValue == "lower" })
    system.windows[index].constraints.minimumSize.height = lowerSlot.size.height - 0.5
    // 3 points over: the pane minus the overflow would round back up to the
    // same row.
    let terminal = addTerminal(system)
    let settled = slot.size.height + 3
    system.sizeGrids[terminal] = (BTSize(width: 0, height: step), BTSize(width: 0, height: settled))
    if roundsUp { system.sizeGridsRoundUp.insert(terminal) }
    let request = settled - SteppedSizeAcceptance.maximumShortfall - 1
    let cells = (request - settled) / step
    let landed = settled + (roundsUp ? cells.rounded(.up) : cells.rounded()) * step
    system.eventHandler?(WindowSystemEvent(kind: .created, windowID: terminal, processIdentifier: 399))

    #expect(await waitFor(timeout: .seconds(3)) {
        model.activeTabbedState?.panes[0].selected == terminal && near(frame("terminal", system)?.size.height, landed)
    }, "\(slot) \(system.requestedFrames[terminal] ?? []) \(model.statusMessage ?? "-")")
    try await Task.sleep(for: .milliseconds(400))
    #expect(landed < slot.size.height)
    #expect(near(frame("terminal", system)?.size.height, landed))
    #expect(near(content(0, model, system)?.size.height, slot.size.height))
    #expect(system.requestedFrames[terminal]?.last.map { near($0.size.height, request) } == true)
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
            && near(frame("upper", system)?.size.height, upperSlot.size.height + 4 - 2 * rowStep)
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

/// A pane keeps the edge it snapped to for its Terminal while another tab is
/// selected, so selecting the Terminal again takes at most one write, not a
/// refused one and a correction.
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

    // The hidden Terminal keeps its pane at the height it fills.
    model.performTabbed(.select(WindowID(rawValue: "upper")))
    #expect(await waitFor { model.activeTabbedState?.panes[0].selected == WindowID(rawValue: "upper") })
    #expect(near(content(0, model, system)?.size.height, slot.size.height + 4))
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

/// Two Terminals in Two Rows: the upper one rounds up, the lower one lands
/// exactly on its pane. The divider between them stays, because moving it
/// would ask the lower Terminal for a size it rounds away from; the upper
/// one takes a gap instead. With another application below that is not yet
/// known to step, the first try finds out, and the retry keeps the divider.
@Test(arguments: [true, false]) @MainActor
func aSteppedNeighbourThatLandedExactlyKeepsTheDivider(sameApplication: Bool) async throws {
    let system = FakeAppWindowSystem()
    let model = try await makeTabbed(system, .rows, ["upper", "lower"])
    defer { model.shutdown() }
    let upperSlot = try #require(content(0, model, system))
    let lowerSlot = try #require(content(1, model, system))
    let upper = WindowID(rawValue: "upper"), lower = WindowID(rawValue: "lower")
    system.sizeGrids[upper] = (BTSize(width: 0, height: rowStep), BTSize(width: 0, height: upperSlot.size.height + 4))
    system.sizeGrids[lower] = (BTSize(width: 0, height: rowStep), BTSize(width: 0, height: lowerSlot.size.height))
    for index in system.windows.indices {
        system.windows[index].bundleIdentifier = sameApplication ? "com.apple.Terminal" : "com.example.\(index)"
        // Their real frames sit on their own rows, off to one side.
        system.windows[index].frame.origin.x += 7
    }
    let upperIndex = try #require(system.windows.firstIndex { $0.id == upper })
    system.windows[upperIndex].frame.size.height = upperSlot.size.height + 4
    model.performTabbed(.repair)

    #expect(await waitFor(timeout: .seconds(4)) {
        near(frame("lower", system)?.minX, lowerSlot.minX) && near(frame("upper", system)?.minX, upperSlot.minX)
            && (frame("upper", system)?.size.height ?? .infinity) < upperSlot.size.height
    }, "\(String(describing: frame("upper", system))) \(String(describing: frame("lower", system))) \(model.statusMessage ?? "-")")
    try await Task.sleep(for: .milliseconds(600))
    #expect(frame("lower", system)?.approximatelyEquals(lowerSlot, tolerance: 0.6) == true)
    #expect(near(content(1, model, system)?.size.height, lowerSlot.size.height))
    #expect(model.statusMessage == nil)
    let writes = system.frameWriteCounts
    try await Task.sleep(for: .milliseconds(500))
    #expect(system.frameWriteCounts == writes)
}

/// A window that is not stepped at all refuses 10 points of its pane, and
/// the pane below is at its minimum. The request for more than one step
/// less shows the window keeps its size, so its minimum is learned and the
/// arrival is placed by the usual rules, here as a hidden tab of the pane
/// that can show it, instead of failing the same way on every placement.
@Test @MainActor func aRealMinimumJustAboveThePaneIsLearned() async throws {
    let system = FakeAppWindowSystem()
    let model = try await makeTabbed(system, .rows, ["upper", "lower"])
    defer { model.shutdown() }
    let slot = try #require(content(0, model, system))
    let lowerSlot = try #require(content(1, model, system))
    let lowerIndex = try #require(system.windows.firstIndex { $0.id.rawValue == "lower" })
    system.windows[lowerIndex].constraints.minimumSize.height = lowerSlot.size.height - 0.5
    system.measuresOnWrite = true
    var window = system.windows[0]
    let big = WindowID(rawValue: "big")
    window.id = big
    window.processIdentifier = 398
    window.title = "Big"
    window.bundleIdentifier = "com.example.big"
    window.frame = BTRect(x: 60, y: 60, width: 480, height: 400)
    system.windows.append(window)
    system.enforcedMinimumHeights[big] = slot.size.height + 10
    system.unprobeableWindowIDs = [big]
    system.eventHandler?(WindowSystemEvent(kind: .created, windowID: big, processIdentifier: 398))

    #expect(await waitFor(timeout: .seconds(5)) {
        (system.windows.first { $0.id == big }?.constraints.minimumSize.height ?? 0) >= slot.size.height + 9
            && model.activeTabbedState?.panes[1].tabs.contains(big) == true
    }, "\(String(describing: system.windows.first { $0.id == big }?.constraints)) \(String(describing: model.activeTabbedState?.panes.map(\.tabs))) \(model.statusMessage ?? "-")")
    #expect(model.statusMessage == nil)
}

/// Two Terminals stacked, the upper one sharing its pane with another tab,
/// with grids that do not both fit the panes: one rounds up and one lands
/// exactly, or both round up. The first selections learn the grids. After
/// that, switching tabs in the upper pane writes no Terminal, fails nothing,
/// and leaves no Terminal larger than its pane.
@Test(arguments: [(3.0, 0.0), (5.0, 5.0)]) @MainActor
func switchingTabsBesideTwoSteppedTerminalsSettles(upperOver: Double, lowerOver: Double) async throws {
    let system = FakeAppWindowSystem()
    let model = try await makeTabbed(system, .rows, ["t1", "t2", "other"])
    defer { model.shutdown() }
    let slot = try #require(content(0, model, system))
    let lowerSlot = try #require(content(1, model, system))
    let t1 = WindowID(rawValue: "t1"), t2 = WindowID(rawValue: "t2"), other = WindowID(rawValue: "other")
    for (id, area, over) in [(t1, slot, upperOver), (t2, lowerSlot, lowerOver)] {
        system.sizeGrids[id] = (BTSize(width: 0, height: rowStep), BTSize(width: 0, height: area.size.height + over))
        let index = try #require(system.windows.firstIndex { $0.id == id })
        system.windows[index].bundleIdentifier = "com.apple.Terminal"
        // Each holds its own row size, off its pane, so placements write it.
        system.windows[index].frame = BTRect(x: 7, y: area.minY, width: area.size.width, height: area.size.height + over)
    }
    var failures = 0
    func select(_ id: WindowID) async throws {
        model.performTabbed(.select(id))
        try #require(await waitFor { model.activeTabbedState?.panes[0].selected == id })
        try await Task.sleep(for: .milliseconds(600))
        if model.statusMessage != nil { failures += 1; model.statusMessage = nil }
    }
    model.performTabbed(.repair)
    try await Task.sleep(for: .milliseconds(800))
    for id in [other, t1, other, t1] { try await select(id) }
    let settled = (frame("t1", system), frame("t2", system))
    let writes = (system.frameWriteCounts[t1, default: 0], system.frameWriteCounts[t2, default: 0])
    for _ in 0..<3 {
        try await select(other)
        #expect(frame("t1", system) == settled.0 && frame("t2", system) == settled.1)
        try await select(t1)
        #expect(frame("t1", system) == settled.0 && frame("t2", system) == settled.1)
    }
    #expect(failures == 0)
    #expect(system.frameWriteCounts[t1, default: 0] == writes.0)
    #expect(system.frameWriteCounts[t2, default: 0] == writes.1)
    for (pane, frame) in [(0, settled.0), (1, settled.1)] {
        let area = try #require(content(pane, model, system))
        #expect((frame?.size.height ?? .infinity) <= area.size.height + 0.5, "\(String(describing: frame)) \(area)")
        #expect(area.size.height - (frame?.size.height ?? 0) <= SteppedSizeAcceptance.maximumShortfall + 1)
        #expect(near(frame?.minY, area.minY))
    }
}

/// The live sequence on a 1920×968 work area in Two Rows: Finder's Recents
/// and Terminal T1 share the top pane, Terminal T2 is alone below. Terminal
/// heights are 4 + 15·k, rounded to the nearest row. Selecting T1 and then
/// switching between Recents and T1 three times settles the divider so T2
/// fills its pane at 454 and T1 takes 439, and then writes no Terminal again.
@Test @MainActor func liveTwoTerminalsInTwoRowsSettleOnTheirGrids() async throws {
    _ = NSApplication.shared
    let system = FakeAppWindowSystem()
    system.availableDisplays[0].frame = BTRect(x: 0, y: 0, width: 1920, height: 1080)
    system.availableDisplays[0].visibleFrame = BTRect(x: 0, y: 30, width: 1920, height: 968)
    let base = system.windows[0]
    let t1 = WindowID(rawValue: "t1"), t2 = WindowID(rawValue: "t2"), recents = WindowID(rawValue: "recents")
    system.windows = [(t1, "com.apple.Terminal"), (t2, "com.apple.Terminal"), (recents, "com.apple.finder")]
        .enumerated().map { index, entry in
            var window = base
            window.id = entry.0
            window.processIdentifier = pid_t(500 + index)
            window.bundleIdentifier = entry.1
            window.title = entry.0.rawValue
            window.frame = BTRect(x: 100, y: 100, width: 800, height: entry.0 == recents ? 500 : 424)
            return window
        }
    for id in [t1, t2] { system.sizeGrids[id] = (BTSize(width: 0, height: 15), BTSize(width: 0, height: 4)) }
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.configuration.defaultTabbedPreset = .rows
    model.setActiveMode(.tabbed)
    try #require(await waitFor { model.activeTabbedState?.windowIDs.count == 3 })
    let lower = try #require(model.activeTabbedState?.panes[1].id)
    model.performTabbed(.move(t2, pane: lower, index: nil))
    try #require(await waitFor { model.activeTabbedState?.panes[1].selected == t2 })
    try await Task.sleep(for: .milliseconds(500))

    var failures = 0
    func select(_ id: WindowID) async throws {
        model.performTabbed(.select(id))
        try #require(await waitFor { model.activeTabbedState?.panes[0].selected == id })
        try await Task.sleep(for: .milliseconds(600))
        if model.statusMessage != nil { failures += 1; model.statusMessage = nil }
    }
    try await select(t1)
    try await select(recents)
    try await select(t1)
    let settled = (frame("t1", system), frame("t2", system))
    let writes = (system.frameWriteCounts[t1, default: 0], system.frameWriteCounts[t2, default: 0])
    for _ in 0..<3 {
        try await select(recents)
        #expect(frame("t1", system) == settled.0 && frame("t2", system) == settled.1)
        try await select(t1)
        #expect(frame("t1", system) == settled.0 && frame("t2", system) == settled.1)
    }
    #expect(failures == 0)
    #expect(system.frameWriteCounts[t1, default: 0] == writes.0)
    #expect(system.frameWriteCounts[t2, default: 0] == writes.1)
    let heights = [settled.0?.size.height, settled.1?.size.height].compactMap { $0 }.sorted()
    #expect(heights == [439, 454], "\(String(describing: settled))")
    // No Terminal is larger than its window area.
    for (pane, frame) in [(0, settled.0), (1, settled.1)] {
        let state = try #require(model.activeTabbedState)
        let area = TabbedLayoutState.contentFrame(try #require(state.frames(in: system.availableDisplays[0].visibleFrame)[state.panes[pane].id]))
        #expect((frame?.size.height ?? .infinity) <= area.size.height + 0.5)
        #expect(near(frame?.minY, area.minY))
    }
}

@MainActor private func settleAfterRepair(_ model: BetterTileModel, _ system: FakeAppWindowSystem, drifting ids: [WindowID]) async throws -> Int {
    for index in system.windows.indices where ids.contains(system.windows[index].id) {
        system.windows[index].frame.origin.x += 7
    }
    model.statusMessage = nil
    model.performTabbed(.repair)
    try await waitForIdle(model, system)
    return model.statusMessage == nil ? 0 : 1
}

/// Waits on conditions, not a fixed time, so a busy runner cannot fail a
/// test: every placement has finished and no window moved for 300 ms.
@MainActor private func waitForIdle(_ model: BetterTileModel, _ system: FakeAppWindowSystem) async throws {
    var frames = system.windows.map(\.frame)
    let settled = await waitFor(timeout: .seconds(20)) {
        guard !model.hasPendingTabbedPlacement else { frames = system.windows.map(\.frame); return false }
        return true
    }
    try #require(settled, "a Tabbed placement never finished")
    for _ in 0..<100 {
        try await Task.sleep(for: .milliseconds(300))
        let now = system.windows.map(\.frame)
        if now == frames, !model.hasPendingTabbedPlacement { return }
        frames = now
    }
    Issue.record("the windows never settled")
}

/// A font change gives Terminal another grid. Its next placement settles off
/// the length it was asked for on its old grid, so its lengths start again
/// from the new one, and the retry fits its pane to it without a failure.
@Test @MainActor func aFontChangeStartsTheGridAgain() async throws {
    let system = FakeAppWindowSystem()
    let model = try await makeTabbed(system, .rows, ["upper", "lower"])
    defer { model.shutdown() }
    let slot = try #require(content(0, model, system))
    let terminal = addTerminal(system, heightGrid: slot.size.height + 4)
    system.eventHandler?(WindowSystemEvent(kind: .created, windowID: terminal, processIdentifier: 399))
    try #require(await waitFor(timeout: .seconds(3)) {
        model.activeTabbedState?.panes[0].selected == terminal && near(content(0, model, system)?.size.height, slot.size.height + 4)
    })
    try await Task.sleep(for: .milliseconds(400))
    // A larger font: rows of 17 points.
    system.sizeGrids[terminal] = (BTSize(width: 0, height: 17), BTSize(width: 0, height: slot.size.height + 9))
    var failures = 0
    for _ in 0..<2 { failures += try await settleAfterRepair(model, system, drifting: [terminal]) }
    #expect(failures == 0)
    #expect(near(frame("terminal", system)?.size.height, slot.size.height + 9))
    #expect(near(content(0, model, system)?.size.height, slot.size.height + 9))
}

/// A window whose lengths share no step, such as one with fractional cells,
/// gets no grid. It still snaps one placement at a time and never fails or
/// overlaps its neighbour.
@Test @MainActor func fractionalCellsGetNoGridAndNeverFail() async throws {
    let system = FakeAppWindowSystem()
    let model = try await makeTabbed(system, .rows, ["upper", "lower"])
    defer { model.shutdown() }
    let slot = try #require(content(0, model, system))
    let terminal = addTerminal(system)
    system.sizeGrids[terminal] = (BTSize(width: 0, height: 7.3), BTSize(width: 0, height: slot.size.height + 3.3))
    system.eventHandler?(WindowSystemEvent(kind: .created, windowID: terminal, processIdentifier: 399))
    try #require(await waitFor(timeout: .seconds(3)) { model.activeTabbedState?.panes[0].selected == terminal })
    try await Task.sleep(for: .milliseconds(600))
    var failures = 0
    for step in 0..<3 {
        let branch = try #require(model.activeTabbedState?.dividers(in: system.availableDisplays[0].visibleFrame).first?.branchID)
        model.performTabbed(.adjustDivider(branch, by: step % 2 == 0 ? 0.03 : -0.05))
        try await Task.sleep(for: .milliseconds(1200))
        if model.statusMessage != nil { failures += 1; model.statusMessage = nil }
        let area = try #require(content(0, model, system))
        #expect((frame("terminal", system)?.size.height ?? .infinity) <= area.size.height + 2)
    }
    #expect(failures == 0)
}

/// A window that is not stepped but whose minimum is just above its pane
/// snaps its pane once. A larger pane later takes its request exactly, which
/// teaches no grid, so the divider stays where the user put it.
@Test @MainActor func aMinimumNearThePaneTeachesNoGrid() async throws {
    let system = FakeAppWindowSystem()
    let model = try await makeTabbed(system, .rows, ["upper", "lower"])
    defer { model.shutdown() }
    let slot = try #require(content(0, model, system))
    var window = system.windows[0]
    let big = WindowID(rawValue: "big")
    window.id = big
    window.processIdentifier = 398
    window.bundleIdentifier = "com.example.big"
    window.frame = BTRect(x: 60, y: 60, width: 480, height: 400)
    system.windows.append(window)
    system.enforcedMinimumHeights[big] = slot.size.height + 10
    system.eventHandler?(WindowSystemEvent(kind: .created, windowID: big, processIdentifier: 398))
    try #require(await waitFor(timeout: .seconds(3)) {
        model.activeTabbedState?.panes[0].selected == big && near(content(0, model, system)?.size.height, slot.size.height + 10)
    })
    try await Task.sleep(for: .milliseconds(400))
    for fraction in [0.08, 0.02] {
        let branch = try #require(model.activeTabbedState?.dividers(in: system.availableDisplays[0].visibleFrame).first?.branchID)
        model.performTabbed(.adjustDivider(branch, by: fraction))
        try await Task.sleep(for: .milliseconds(800))
        let area = try #require(content(0, model, system))
        #expect(frame("big", system)?.approximatelyEquals(area, tolerance: 0.6) == true)
        #expect(model.activeTabbedState?.withPreferredPaneSizes() == nil, "the divider drifted from the user's size")
    }
    #expect(model.statusMessage == nil)
}

/// Four Panes with Terminals in three of them, whose grids fit no layout
/// exactly. Placements settle on one arrangement and then write nothing.
@Test @MainActor func fourPanesWithThreeSteppedWindowsSettle() async throws {
    let system = FakeAppWindowSystem()
    let model = try await makeTabbed(system, .grid, ["a", "b", "c", "d"])
    defer { model.shutdown() }
    let state = try #require(model.activeTabbedState)
    for (index, name) in ["c", "d"].enumerated() {
        model.performTabbed(.move(WindowID(rawValue: name), pane: state.panes[index + 2].id, index: nil))
        try #require(await waitFor { model.activeTabbedState?.panes[index + 2].selected == WindowID(rawValue: name) })
    }
    try await waitForIdle(model, system)
    let stepped = ["a", "b", "c"].map { WindowID(rawValue: $0) }
    for (offset, id) in stepped.enumerated() {
        system.sizeGrids[id] = (BTSize(width: 9 + Double(offset), height: 15), BTSize(width: 2, height: 4 + Double(offset)))
        let index = try #require(system.windows.firstIndex { $0.id == id })
        system.windows[index].bundleIdentifier = "com.apple.Terminal"
    }
    var failures = 0
    for _ in 0..<3 { failures += try await settleAfterRepair(model, system, drifting: stepped) }
    let frames = system.windows.map(\.frame)
    let layout = model.activeTabbedState?.layout
    let writes = system.frameWriteCounts
    for _ in 0..<2 { failures += try await settleAfterRepair(model, system, drifting: []) }
    #expect(failures == 0)
    #expect(system.windows.map(\.frame) == frames)
    #expect(model.activeTabbedState?.layout == layout)
    #expect(system.frameWriteCounts == writes, "\(writes) \(system.frameWriteCounts) \(system.windows.map { "\($0.id.rawValue) \($0.frame)" })")
    let current = try #require(model.activeTabbedState)
    let areas = current.frames(in: system.availableDisplays[0].visibleFrame)
    for pane in current.panes {
        guard let id = pane.selected, let area = areas[pane.id].map(TabbedLayoutState.contentFrame),
              let placed = system.windows.first(where: { $0.id == id })?.frame else { continue }
        // Within the write tolerance.
        #expect(placed.size.width <= area.size.width + 2 && placed.size.height <= area.size.height + 2, "\(id) \(placed) \(area)")
    }
}

/// A small divider drag beside a window held up by a minimum it never
/// reported. That window settles at one length off its request, which is no
/// grid, so the drag sticks and the window fills its new area.
@Test(arguments: [10.0, 1.5]) @MainActor
func aSmallDragBesideAMinimumHeldWindowSticks(minimumAbovePane: Double) async throws {
    let system = FakeAppWindowSystem()
    let model = try await makeTabbed(system, .rows, ["upper", "lower"])
    defer { model.shutdown() }
    let slot = try #require(content(0, model, system))
    var window = system.windows[0]
    let big = WindowID(rawValue: "big")
    window.id = big
    window.processIdentifier = 398
    window.bundleIdentifier = "com.example.big"
    window.frame = BTRect(x: 60, y: 60, width: 480, height: 400)
    system.windows.append(window)
    system.enforcedMinimumHeights[big] = slot.size.height + minimumAbovePane
    system.eventHandler?(WindowSystemEvent(kind: .created, windowID: big, processIdentifier: 398))
    try #require(await waitFor(timeout: .seconds(5)) { model.activeTabbedState?.panes[0].selected == big })
    try await waitForIdle(model, system)
    let before = try #require(content(0, model, system))
    // About 12 points: less than one step.
    let branch = try #require(model.activeTabbedState?.dividers(in: system.availableDisplays[0].visibleFrame).first?.branchID)
    model.performTabbed(.adjustDivider(branch, by: 12 / system.availableDisplays[0].visibleFrame.size.height))
    try await waitForIdle(model, system)
    let area = try #require(content(0, model, system))
    #expect(area.size.height > before.size.height + 10, "the drag was undone: \(before) \(area)")
    #expect(model.activeTabbedState?.withPreferredPaneSizes() == nil, "the divider drifted from the user's size")
    #expect(frame("big", system)?.approximatelyEquals(area, tolerance: 0.6) == true)
    #expect(model.statusMessage == nil)
}

/// Review: leaving Tabbed forgets a learned grid, also for a stepped window
/// that floats inside Tabbed at that moment.
@Test @MainActor func leavingTabbedForgetsAFloatingSteppedWindowsGrid() async throws {
    let system = FakeAppWindowSystem()
    let model = try await makeTabbed(system, .rows, ["upper", "lower"])
    defer { model.shutdown() }
    let slot = try #require(content(0, model, system))
    let terminal = addTerminal(system, heightGrid: slot.size.height + 4)
    system.eventHandler?(WindowSystemEvent(kind: .created, windowID: terminal, processIdentifier: 399))
    try #require(await waitFor(timeout: .seconds(3)) { model.tabbedSteppedWindows[terminal] != nil })
    try await Task.sleep(for: .milliseconds(300))
    model.performTabbed(.float(terminal))
    try #require(await waitFor { model.activeTabbedState?.floatingWindowIDs.contains(terminal) == true })
    try await Task.sleep(for: .milliseconds(300))
    #expect(model.tabbedSteppedWindows[terminal] != nil)

    model.setActiveMode(.bento)

    #expect(await waitFor { model.tabbedSteppedWindows[terminal] == nil })
}

/// Fixed commands move a whole pane; a native snap moves its selected window.
/// A newly observed cell must not move the exact target, whichever pane steps.
@Test(arguments: ["keyboard", "wheel", "native"], [(false, false), (false, true), (true, false), (true, true)]) @MainActor
func aSteppedSnapKeepsItsExactLogicalRegion(entry: String, variant: (height: Bool, neighbour: Bool)) async throws {
    let (height, neighbour) = variant
    let system = FakeAppWindowSystem()
    let model = try await makeTabbed(system, height ? .rows : .columns, ["source", "peer", "hidden"])
    defer { model.shutdown() }
    let source = WindowID(rawValue: "source")
    let stepped = WindowID(rawValue: neighbour ? (entry == "native" ? "hidden" : "peer") : "source")
    let before = try #require(model.activeTabbedState)
    let slot = try #require(content(neighbour && entry != "native" ? 1 : 0, model, system))
    system.sizeGrids[stepped] = (
        BTSize(width: height ? 0 : 14, height: height ? 14 : 0),
        BTSize(width: height ? 0 : slot.size.width + 5, height: height ? slot.size.height + 5 : 0))
    system.emitsFrameEvents = true
    system.focusedID = source
    let action: WindowAction = height ? .bottomHalf : .rightHalf
    let bounds = system.mainDisplay.visibleFrame
    switch entry {
    case "keyboard": model.perform(action)
    case "wheel":
        model.performLayoutWheel(.windowAction(action), for: LayoutWheelTarget(
            windowID: source, displayID: system.mainDisplay.id, visibleFrame: bounds))
    default:
        try #require(model.completeBentoDrag(displayID: system.mainDisplay.id, sourceID: source,
            outcome: .snap(action: action, frame: bounds)))
    }
    try await waitForIdle(model, system)
    let state = try #require(model.activeTabbedState), pane = try #require(state.pane(containing: source))
    #expect(model.statusMessage == nil)
    #expect(state.logicalFrames(in: bounds)[pane.id] == action.partition?.frame(in: bounds))
    #expect(state.windowIDs == before.windowIDs && state.floatingWindowIDs == before.floatingWindowIDs)
    #expect(pane.selected == source && state.activeWindowID == source)
    if entry == "native" {
        #expect(pane.tabs == [WindowID(rawValue: "peer"), source])
        #expect(state.pane(containing: WindowID(rawValue: "hidden"))?.tabs == [WindowID(rawValue: "hidden")])
    } else { #expect(pane.tabs == before.pane(containing: source)?.tabs) }
    for selected in state.selectedWindowIDs {
        let selectedPane = try #require(state.paneID(containing: selected))
        let area = TabbedLayoutState.contentFrame(try #require(state.frames(in: bounds)[selectedPane]))
        let actual = try #require(system.windows.first { $0.id == selected }?.frame)
        #expect(actual.minX >= area.minX - 0.6 && actual.minY >= area.minY - 0.6)
        #expect(actual.maxX <= area.maxX + 0.6 && actual.maxY <= area.maxY + 0.6)
    }
    let writes = system.frameWriteCounts
    try await Task.sleep(for: .milliseconds(350)) // Catch queued self-event reapplication after settlement.
    #expect(system.frameWriteCounts == writes)
    #expect(model.activeTabbedState == state)
    model.performTabbed(.undo)
    try await waitForIdle(model, system)
    #expect(model.activeTabbedState?.panes.map(\.tabs) == before.panes.map(\.tabs))
    #expect(model.activeTabbedState?.panes.map(\.selected) == before.panes.map(\.selected))
}

/// Ordinary adaptive placement learns two distinct cells first. A later fixed
/// snap uses that grid inside the requested region instead of fitting its edge.
@Test(arguments: ["keyboard", "wheel", "native"]) @MainActor
func aLearnedGridFitsInsideAnExactSnap(entry: String) async throws {
    let system = FakeAppWindowSystem()
    let model = try await makeTabbed(system, .columns, ["source", "peer"])
    defer { model.shutdown() }
    let source = WindowID(rawValue: "source")
    let area = try #require(content(0, model, system))
    system.sizeGrids[source] = (BTSize(width: 14, height: 0), BTSize(width: area.size.width + 5, height: 0))
    system.windows[0].frame.origin.x += 7 // Force the first grid observation on Repair.
    model.performTabbed(.repair)
    try await waitForIdle(model, system)
    let branch = try #require(model.activeTabbedState?.dividers(in: system.mainDisplay.visibleFrame).first?.branchID)
    model.performTabbed(.adjustDivider(branch, by: 0.02))
    try await waitForIdle(model, system)
    // These ordinary placements retain their adaptive behavior.
    #expect(near(content(0, model, system)?.size.width, area.size.width + 19))
    switch entry {
    case "keyboard": model.perform(.rightHalf)
    case "wheel":
        model.performLayoutWheel(.windowAction(.rightHalf), for: LayoutWheelTarget(
            windowID: source, displayID: system.mainDisplay.id, visibleFrame: system.mainDisplay.visibleFrame))
    default:
        try #require(model.completeBentoDrag(displayID: system.mainDisplay.id, sourceID: source,
            outcome: .snap(action: .rightHalf, frame: system.mainDisplay.visibleFrame)))
    }
    try await waitForIdle(model, system)
    let state = try #require(model.activeTabbedState), pane = try #require(state.paneID(containing: source))
    #expect(state.logicalFrames(in: system.mainDisplay.visibleFrame)[pane] == BTRect(x: 500, y: 0, width: 500, height: 800))
    #expect(near(system.windows[0].frame.size.width, area.size.width - 9))
    #expect(near(system.requestedFrames[source]?.last?.size.width, area.size.width - 9))
    #expect(model.statusMessage == nil)
}

/// A nearby minimum can look like one cell. Asking for less proves the
/// refusal; it must reject the fixed snap and restore all original frames.
@Test @MainActor func aMinimumHeldSnapRejectsAndRestoresBeforeALargerSnap() async throws {
    let system = FakeAppWindowSystem()
    let model = try await makeTabbed(system, .columns, ["source", "peer", "hidden"])
    defer { model.shutdown() }
    let source = WindowID(rawValue: "source")
    let before = try #require(model.activeTabbedState), frames = system.windows.map(\.frame)
    let bounds = system.mainDisplay.visibleFrame
    let plan = try #require(TabbedSnapPlanner.plan(sourceWindowID: source, action: .rightThird,
        scope: .pane, state: before, windows: system.windows, in: bounds))
    let requested = try #require(plan.placements.first { $0.windowID == source }?.frame.size.width)
    system.enforcedMinimumWidths[source] = requested + 5
    model.perform(.rightThird)
    try await waitForIdle(model, system)
    #expect(model.statusMessage != nil)
    #expect(model.activeTabbedState == before)
    #expect(system.windows.map(\.frame) == frames)
    // A larger request is accepted exactly, so the held length is not a grid.
    model.perform(.rightHalf)
    try await waitForIdle(model, system)
    let after = try #require(model.activeTabbedState), pane = try #require(after.paneID(containing: source))
    #expect(after.logicalFrames(in: bounds)[pane] == BTRect(x: 500, y: 0, width: 500, height: 800))
    let area = TabbedLayoutState.contentFrame(try #require(after.frames(in: bounds)[pane]))
    #expect(system.windows[0].frame.approximatelyEquals(area, tolerance: 0.6))
    #expect(model.statusMessage == nil)
}

/// A failed corrective write and command retry restore the verified checkpoint
/// without committing provisional pane membership or an Undo step.
@Test(arguments: [false, true]) @MainActor
func aFailedSteppedSnapCorrectionRestoresItsCheckpoint(native: Bool) async throws {
    let system = FakeAppWindowSystem()
    let model = try await makeTabbed(system, .columns, ["source", "peer", "hidden"])
    defer { model.shutdown() }
    let source = WindowID(rawValue: "source")
    let slot = try #require(content(0, model, system))
    system.sizeGrids[source] = (BTSize(width: 14, height: 0), BTSize(width: slot.size.width + 5, height: 0))
    system.windows[0].frame.origin.x += 7
    model.performTabbed(.repair) // Verify a grid-aligned checkpoint before the snap.
    try await waitForIdle(model, system)
    let before = try #require(model.activeTabbedState), frames = system.windows.map(\.frame)
    let writes = system.frameWriteCounts[source, default: 0]
    system.failedFrameWriteNumbers[source] = [writes + 2, writes + 4] // Correction and learned-grid retry.
    if native {
        try #require(model.completeBentoDrag(displayID: system.mainDisplay.id, sourceID: source,
            outcome: .snap(action: .rightThird, frame: system.mainDisplay.visibleFrame)))
    } else { model.perform(.rightThird) }
    try await waitForIdle(model, system)
    #expect(model.statusMessage?.contains("Injected frame write failure") == true)
    #expect(model.activeTabbedState == before)
    #expect(system.windows.map(\.frame) == frames)
    model.performTabbed(.undo)
    try await waitForIdle(model, system)
    #expect(model.activeTabbedState?.panes[1].tabs.isEmpty == true)
}

/// A native gesture takes ownership while the smaller-cell write settles.
/// The cancelled fixed snap cannot later commit over the gesture's recovery.
@Test @MainActor func aNativeDragInterruptsASteppedSnapCorrection() async throws {
    let system = FakeAppWindowSystem()
    let model = try await makeTabbed(system, .columns, ["source", "peer"])
    defer { model.shutdown() }
    let source = WindowID(rawValue: "source"), display = system.mainDisplay.id
    let slot = try #require(content(0, model, system))
    let before = try #require(model.activeTabbedState)
    system.sizeGrids[source] = (BTSize(width: 14, height: 0), BTSize(width: slot.size.width + 5, height: 0))
    system.frameApplicationDelays[source] = .milliseconds(60)
    let correctionWrite = system.frameWriteCounts[source, default: 0] + 2
    model.perform(.rightHalf)
    try #require(await waitFor { system.frameWriteCounts[source, default: 0] >= correctionWrite })
    try #require(model.beginBentoDrag(displayID: display, sourceID: source))
    // The application's in-flight correction finishes during the held drag.
    try await Task.sleep(for: .milliseconds(100))
    model.finishBentoDrag(displayID: display, sourceID: source, end: .restore)
    try await waitForIdle(model, system)
    let state = try #require(model.activeTabbedState)
    #expect(state.panes.map(\.tabs) == before.panes.map(\.tabs))
    #expect(state.paneID(containing: source) == before.paneID(containing: source))
    let pane = try #require(state.paneID(containing: source))
    #expect(state.logicalFrames(in: system.mainDisplay.visibleFrame)[pane]?.minX == 0)
    #expect(model.statusMessage == nil)
    let writes = system.frameWriteCounts
    try await Task.sleep(for: .milliseconds(350))
    #expect(system.frameWriteCounts == writes)
    #expect(model.activeTabbedState == state)
}

/// A floating source gets a new destination pane. A retry may allocate that
/// pane again; its new identity must retain the same exact snap region.
@Test @MainActor func aFloatingSteppedSnapCanRetryIntoANewExactPane() async throws {
    let system = FakeAppWindowSystem()
    let model = try await makeTabbed(system, .columns, ["source", "peer"])
    defer { model.shutdown() }
    let source = WindowID(rawValue: "source")
    model.performTabbed(.float(source))
    try await waitForIdle(model, system)
    let before = try #require(model.activeTabbedState), bounds = system.mainDisplay.visibleFrame
    let plan = try #require(TabbedSnapPlanner.plan(sourceWindowID: source, action: .rightThird,
        scope: .pane, state: before, windows: system.windows, in: bounds))
    let area = try #require(plan.placements.first { $0.windowID == source }?.frame)
    system.sizeGrids[source] = (BTSize(width: 14, height: 0), BTSize(width: area.size.width + 5, height: 0))
    system.windows[0].frame.size.width = area.size.width + 145 // A valid floating cell for rollback.
    system.failedFrameWriteNumbers[source] = [system.frameWriteCounts[source, default: 0] + 2]
    model.perform(.rightThird)
    try await waitForIdle(model, system)
    let after = try #require(model.activeTabbedState), pane = try #require(after.pane(containing: source))
    let target = try #require(WindowAction.rightThird.partition?.frame(in: bounds))
    #expect(after.logicalFrames(in: bounds)[pane.id]?.approximatelyEquals(target, tolerance: 0.001) == true)
    #expect(pane.tabs == [source] && pane.selected == source)
    #expect(after.floatingWindowIDs.contains(source) == false)
    #expect(system.windows[0].frame.maxX <= area.maxX + 0.6)
    #expect(model.statusMessage == nil)
}

/// One held length is not proof of a grid. If a new minimum also prevents
/// checkpoint recovery, report degradation and stop automatic frame writes.
@Test(arguments: [false, true]) @MainActor
func anImpossibleMinimumHeldSnapRollbackStopsAutomaticWrites(native: Bool) async throws {
    let system = FakeAppWindowSystem()
    let model = try await makeTabbed(system, .columns, ["source", "peer"])
    defer { model.shutdown() }
    let source = WindowID(rawValue: "source")
    let before = try #require(model.activeTabbedState)
    let area = try #require(content(0, model, system))
    system.enforcedMinimumWidths[source] = area.size.width + 5
    if native {
        try #require(model.completeBentoDrag(displayID: system.mainDisplay.id, sourceID: source,
            outcome: .snap(action: .rightHalf, frame: system.mainDisplay.visibleFrame)))
    } else { model.perform(.rightHalf) }
    try await waitForIdle(model, system)
    #expect(model.statusMessage?.contains("could not fully restore") == true)
    #expect(model.activeTabbedState == before)
    let writes = system.frameWriteCounts
    system.eventHandler?(WindowSystemEvent(kind: .resized, windowID: source, processIdentifier: system.windows[0].processIdentifier))
    try await Task.sleep(for: .milliseconds(350)) // A degraded transaction must not trigger a background correction.
    #expect(system.frameWriteCounts == writes)
}
