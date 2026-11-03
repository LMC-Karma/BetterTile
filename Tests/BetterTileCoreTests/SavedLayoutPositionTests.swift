import Testing
@testable import BetterTileCore

@Suite struct SavedLayoutPositionTests {
    let bounds = BTRect(x: 0, y: 0, width: 1000, height: 800)
    func terminal(_ id: String, x: Double) -> SavedLayoutEligibleWindow {
        .init(id: .init(rawValue: id), bundleID: "com.apple.Terminal", frame: .init(x: x, y: 40, width: 400, height: 600))
    }
    func document() -> SavedLayoutDocument {
        .init(name: "Two terminals", mode: .manual,
            slots: [.init(id: "right", bundleID: "com.apple.Terminal"), .init(id: "left", bundleID: "com.apple.Terminal")],
            windows: [.init(slot: "left", rect: .init(x: 0, y: 0, width: 0.5, height: 1)),
                      .init(slot: "right", rect: .init(x: 0.5, y: 0, width: 0.5, height: 1))])
    }
    @Test func reversedSlotOrderDoesNotSwapTerminalWindows() throws {
        let windows = [terminal("a-left", x: 30), terminal("z-right", x: 550)]
        let plan = try SavedLayoutPlanner.plan(document(), in: bounds, windows: windows)
        #expect(plan.assignments["left"] == windows[0].id)
        #expect(plan.assignments["right"] == windows[1].id)
    }
}

extension SavedLayoutPositionTests {
    @Test func assignmentMinimizesTheTotalRatherThanEachSlotGreedily() throws {
        let doc = SavedLayoutDocument(name: "Global", mode: .manual,
            slots: [.init(id: "near", bundleID: "com.apple.Terminal"), .init(id: "far", bundleID: "com.apple.Terminal")],
            windows: [.init(slot: "near", rect: .init(x: 0.3, y: 0, width: 0.1, height: 1)),
                      .init(slot: "far", rect: .init(x: 0.85, y: 0, width: 0.1, height: 1))])
        let windows = [SavedLayoutEligibleWindow(id: .init(rawValue: "a"), bundleID: "com.apple.Terminal", frame: .init(x: 50, y: 0, width: 100, height: 800)),
                       .init(id: .init(rawValue: "b"), bundleID: "com.apple.Terminal", frame: .init(x: 350, y: 0, width: 100, height: 800))]
        let plan = try SavedLayoutPlanner.plan(doc, in: bounds, windows: windows)
        #expect(plan.assignments == ["near": windows[0].id, "far": windows[1].id])
    }
    @Test func equalDistanceTiesIgnoreInputOrderAndRepeatIdentically() throws {
        let slots = ["c", "a", "b"].map { SavedLayoutSlot(id: $0, bundleID: "com.apple.Terminal") }
        let doc = SavedLayoutDocument(name: "Equal", mode: .manual, slots: slots,
            windows: slots.map { .init(slot: $0.id, rect: .init(x: 0, y: 0, width: 1, height: 1)) })
        let windows = ["z", "a", "m"].map { terminal($0, x: 300) }
        let first = try SavedLayoutPlanner.plan(doc, in: bounds, windows: windows)
        let second = try SavedLayoutPlanner.plan(doc, in: bounds, windows: windows.reversed())
        #expect(first.assignments == second.assignments)
        #expect(first.assignments == ["a": .init(rawValue: "a"), "b": .init(rawValue: "m"), "c": .init(rawValue: "z")])
    }
    @Test func persistedFramesOutrankSavedRectanglesButNotChoicesOrPaneMembership() throws {
        let windows = [terminal("a-left", x: 30), terminal("z-right", x: 550)]
        let hints = ["left": NormalizedRect(frame: windows[1].frame, in: bounds), "right": NormalizedRect(frame: windows[0].frame, in: bounds)]
        let persisted = try SavedLayoutPlanner.plan(document(), in: bounds, windows: windows, preferredFrames: hints)
        #expect(persisted.assignments["left"] == windows[1].id)
        let explicit = try SavedLayoutPlanner.plan(document(), in: bounds, windows: windows, choices: ["left": windows[0].id], preferredFrames: hints)
        #expect(explicit.assignments["left"] == windows[0].id)
        var doc = document(); doc.mode = .bento; doc.windows = []
        doc.layout = .split(axis: .vertical, ratios: [0.5, 0.5], children: [.slot("left"), .slot("right")])
        let session = BentoLayoutState(root: .partition(.init(axis: .vertical,
            children: [.leaf(windows[0].id), .leaf(windows[1].id)], ratios: [0.5, 0.5])))
        let pane = try SavedLayoutPlanner.plan(doc, in: bounds, windows: windows, preferredFrames: hints, currentSession: .bento(session))
        #expect(pane.assignments["left"] == windows[1].id)
    }
    @Test func foreignPositionUsesItsOwnDisplayCoordinates() throws {
        var foreign = terminal("foreign-left", x: 2030)
        foreign.matchingFrame = .init(x: 0.03, y: 0.05, width: 0.4, height: 0.75)
        let local = terminal("local-right", x: 550)
        let plan = try SavedLayoutPlanner.plan(document(), in: bounds, windows: [local, foreign])
        #expect(plan.assignments["left"] == foreign.id)
        #expect(plan.assignments["right"] == local.id)
    }
    @Test func defaultFillUsesPositionHints() throws {
        let windows = [terminal("a", x: 30), terminal("b", x: 550)]
        let plan = try SavedLayoutPlanner.plan(document(), in: bounds, windows: windows,
            preferredFrames: ["left": .init(x: 0, y: 0, width: 0.5, height: 1)])
        #expect(plan.assignments == ["left": windows[0].id, "right": windows[1].id])
        #expect(plan.emptySlots.isEmpty)
    }
}

extension SavedLayoutPositionTests {
    @Test func exactAssignmentAgreesWithSeededBruteForceIncludingNearTies() throws {
        struct Seed {
            var state: UInt64 = 0xA2_2026_10_25
            mutating func next(_ upper: Int) -> Int {
                state = state &* 6_364_136_223_846_793_005 &+ 1
                return Int((state >> 32) % UInt64(upper))
            }
        }
        func check(_ targets: [NormalizedRect], _ frames: [BTRect], caseNumber: Int) throws {
            let slots = targets.indices.map { SavedLayoutSlot(id: "s\($0)", bundleID: "com.example.Editor") }
            let windows = frames.enumerated().map { SavedLayoutEligibleWindow(id: .init(rawValue: "w\($0.offset)"), bundleID: "com.example.Editor", frame: $0.element) }
            let doc = SavedLayoutDocument(name: "Oracle", mode: .manual, slots: slots.reversed(),
                windows: targets.enumerated().map { .init(slot: "s\($0.offset)", rect: $0.element) })
            var possibilities: [(distance: Double, columns: [Int], ranks: [Int])] = []
            func enumerate(_ columns: [Int], used: Set<Int>, distance: Double) {
                let row = columns.count
                if row == slots.count {
                    possibilities.append((distance, columns, columns.map { min($0, windows.count) }))
                    return
                }
                for column in 0..<max(slots.count, windows.count) where !used.contains(column) {
                    var cost = 0.0
                    if column < frames.count {
                        let target = targets[row]
                        let dx = frames[column].midX / bounds.size.width - (target.x + target.width / 2)
                        let dy = frames[column].midY / bounds.size.height - (target.y + target.height / 2)
                        cost = dx * dx + dy * dy
                    }
                    enumerate(columns + [column], used: used.union([column]), distance: distance + cost)
                }
            }
            enumerate([], used: [], distance: 0)
            let minimum = possibilities.map(\.distance).min()!
            let expected = possibilities.filter { $0.distance <= minimum + 1e-12 }.min { $0.ranks.lexicographicallyPrecedes($1.ranks) }!
            let plan = try SavedLayoutPlanner.plan(doc, in: bounds, windows: windows.reversed())
            let expectedIDs = Dictionary(uniqueKeysWithValues: expected.columns.enumerated().compactMap { row, column in
                column < windows.count ? (slots[row].id, windows[column].id) : nil
            })
            #expect(plan.assignments == expectedIDs, "case \(caseNumber)")
        }
        var seed = Seed()
        for index in 0..<120 {
            let n = 1 + seed.next(6), m = 1 + seed.next(7)
            let targets = (0..<n).map { _ in NormalizedRect(x: Double(seed.next(850)) / 1000, y: Double(seed.next(850)) / 1000, width: 0.1, height: 0.1) }
            let frames = (0..<m).map { _ in BTRect(x: Double(seed.next(850)), y: Double(seed.next(680)), width: 100, height: 80) }
            try check(targets, frames, caseNumber: index)
        }
        // Every assignment has the same mathematical sum, but adding 0.16, 0.04 and
        // 0.04 in different row orders need not produce the same floating-point total.
        try check(Array(repeating: .init(x: 0.45, y: 0.45, width: 0.1, height: 0.1), count: 3),
            [0.1, 0.3, 0.7].map { .init(x: $0 * 1000 - 50, y: 360, width: 100, height: 80) }, caseNumber: 120)
        try check([.init(x: 0.45, y: 0.45, width: 0.1, height: 0.1)],
            [0.6 + 1e-13, 0.6].map { .init(x: $0 * 1000 - 50, y: 360, width: 100, height: 80) }, caseNumber: 121)
    }
}
