import Foundation
import Testing
@testable import BetterTileCore

@Suite(.serialized) struct SavedLayoutFillTests {
    typealias F = SavedLayoutFillAcceptanceTests
    typealias App = F.App

    @Test func preferredCardinalityPrecedesRanksAndInvalidEdgesHaveDummies() throws {
        let document = SavedLayoutDocument(name: "Dummies", mode: .manual,
            slots: [.init(id: "a", prefer: [.app(App.safari)]), .init(id: "b")],
            windows: [.init(slot: "a", rect: .init(x: 0, y: 0, width: 0.5, height: 1)),
                      .init(slot: "b", rect: .init(x: 0.5, y: 0, width: 0.5, height: 1))])
        let windows = F.windows([("safari", App.safari, nil), ("mail", App.mail, nil),
                                 ("notes", App.notes, nil), ("pages", App.pages, nil)])
        let targets = Dictionary(uniqueKeysWithValues: document.windows.map { ($0.slot, $0.rect) })
        let preferred = SavedLayoutPositionMatching.assign(slots: document.slots, windows: windows,
            targets: targets, in: F.workArea, preferences: ["a": [App.safari], "b": []])
        #expect(preferred == ["a": F.id("safari")])
        let plan = try F.plan(document, windows)
        #expect(plan.slotReasons == ["a": .preferred(rank: 0), "b": .largestFreeSlot])
        #expect(plan.assignments["b"] == F.id("mail"))

        var two = document
        two.slots = [.init(id: "a", prefer: [.app(App.safari), .app(App.chrome)]),
                     .init(id: "b", prefer: [.app(App.safari)])]
        let cardinality = try F.plan(two, F.windows([("safari", App.safari, nil), ("chrome", App.chrome, nil)]))
        #expect(cardinality.assignments == ["a": F.id("chrome"), "b": F.id("safari")])
    }

    @Test func threeSlotRanksBeatDistanceEvenWithExistingMembership() throws {
        let windows = F.windows([("safari", App.safari, F.frame(0, 0, 0.6, 1)),
                                 ("chrome", App.chrome, F.frame(0.6, 0, 0.4, 0.5)),
                                 ("finder", App.finder, F.frame(0.6, 0.5, 0.4, 0.5))])
        let current = BentoLayoutState(root: .partition(.init(axis: .vertical,
            children: [.leaf(F.id("safari")), .partition(.init(axis: .horizontal,
                children: [.leaf(F.id("chrome")), .leaf(F.id("finder"))], ratios: [0.5, 0.5]))], ratios: [0.6, 0.4])))
        let plan = try SavedLayoutPlanner.plan(F.homework(), in: F.workArea, windows: windows,
            appGroups: F.appGroups, currentSession: .bento(current))
        #expect(plan.assignments == ["L": F.id("chrome"), "RT": F.id("safari"), "RB": F.id("finder")])
        #expect(plan.slotReasons["RT"] == .preferred(rank: 0))
    }

    @Test func equallyLargeGapPanesChooseNearestAndExactTiesChooseLeft() throws {
        var document = SavedLayoutDocument(name: "Thirds", mode: .bento,
            layout: .split(axis: .vertical, ratios: [1.0 / 3, 1.0 / 3, 1.0 / 3],
                           children: [.slot("z-left"), .slot("middle"), .slot("a-right")]),
            slots: [.init(id: "z-left"), .init(id: "middle"), .init(id: "a-right")], paneGap: 6)
        let leaves = SavedLayoutCanvas.leaves(document.layout!, paneGap: 6)
        let windows = F.windows([("right", App.mail, leaves[2].rect.frame(in: F.workArea)),
                                 ("middle", App.pages, leaves[1].rect.frame(in: F.workArea))])
        let plan = try F.plan(document, windows)
        #expect(plan.assignments == ["a-right": F.id("right"), "middle": F.id("middle")])
        #expect(plan.emptySlots == ["z-left"])
        document.layout = .split(axis: .vertical, ratios: [0.5, 0.5], children: [.slot("z-left"), .slot("a-right")])
        document.slots.remove(at: 1)
        let tied = try F.plan(document, F.windows([("center", App.mail, F.anywhere)]))
        #expect(tied.assignments == ["z-left": F.id("center")])
    }

    @Test func foreignWindowsNeedPreferencesAndKeepTheirOwnCoordinates() throws {
        let local = F.windows([("local", App.mail, F.frame(0, 0, 0.5, 1))])[0]
        var foreign = SavedLayoutEligibleWindow(id: F.id("foreign"), bundleID: App.safari,
            frame: .init(x: 2500, y: 0, width: 500, height: 800),
            matchingFrame: .init(x: 0.5, y: 0, width: 0.5, height: 1), frontRank: 0)
        let unpreferred = try F.plan(F.writing(), [foreign, local])
        #expect(unpreferred.assignments == ["L": local.id])
        #expect(unpreferred.extras[foreign.id] == nil)
        #expect(unpreferred.unmatchedWindowIDs.contains(foreign.id))
        #expect(F.bento(unpreferred)?.floatingWindowIDs.contains(foreign.id) == false)
        #expect(!unpreferred.placements.contains { $0.windowID == foreign.id })
        var document = F.writing()
        document.slots[1].prefer = [.app(App.safari)]
        let preferred = try F.plan(document, [local, foreign])
        #expect(preferred.assignments == ["L": local.id, "R": foreign.id])
        #expect(preferred.slotReasons["R"] == .preferred(rank: 0))
        foreign.bundleID = App.music
        #expect(try F.plan(document, [local, foreign]).unmatchedWindowIDs.contains(foreign.id))
    }

    @Test func choicesCanOverrideAppPreferencesAndFramesStillSteerSameApp() throws {
        let windows = F.windows([("a", App.safari, F.frame(0, 0, 0.5, 1)),
                                 ("b", App.safari, F.frame(0.5, 0, 0.5, 1)), ("mail", App.mail, nil)])
        let hints: [String: NormalizedRect] = ["L": .init(x: 0.5, y: 0, width: 0.5, height: 1),
                                              "R": .init(x: 0, y: 0, width: 0.5, height: 1)]
        let plan = try SavedLayoutPlanner.plan(F.twoBrowsers, in: F.workArea, windows: windows,
            appGroups: F.appGroups, preferredFrames: hints)
        #expect(plan.assignments == ["L": F.id("b"), "R": F.id("a")])
        let choice = try SavedLayoutPlanner.plan(F.twoBrowsers, in: F.workArea, windows: windows,
            appGroups: F.appGroups, choices: ["L": F.id("mail")], preferredFrames: hints)
        #expect(choice.assignments == ["L": F.id("mail"), "R": F.id("a")])
        #expect(choice.slotReasons["L"] == .chosen)
        #expect(throws: SavedLayoutValidationError.self) {
            try SavedLayoutPlanner.plan(F.twoBrowsers, in: F.workArea, windows: windows,
                choices: ["L": F.id("mail"), "R": F.id("mail")])
        }
    }

    @Test func tabMatesAndAlreadyAddedSameAppTabsChooseTheirPane() throws {
        let placed = F.windows([("xcode", App.xcode, nil), ("safari", App.safari, nil), ("terminal", App.terminal, nil)])
        let initial = try #require(F.tabbed(try F.plan(F.coding, placed)))
        var previous = try #require(TabbedLayoutState(adopting: BentoLayoutState(
            root: initial.layout.root, floatingWindowIDs: [F.id("slack-1"), F.id("slack-2")], metrics: initial.layout.metrics)))
        // Previous pane membership can differ from the target shape. Give Slack a Safari mate.
        let right = try #require(previous.pane(containing: F.id("safari"))?.id)
        previous.move(F.id("slack-1"), to: right)
        previous.move(F.id("slack-2"), to: right)
        let extras = F.windows([("slack-1", App.slack, F.frame(0, 0, 0.6, 1)),
                                ("slack-2", App.slack, F.frame(0, 0, 0.6, 1))])
        let plan = try SavedLayoutPlanner.plan(F.coding, in: F.workArea, windows: extras + placed.map {
            var w = $0; w.frontRank += 2; return w
        }, appGroups: F.appGroups, currentSession: .tabbed(previous))
        #expect(plan.extras[F.id("slack-1")] == .tab(groupID: "g-rt", reason: .tabMates))
        #expect(plan.extras[F.id("slack-2")] == .tab(groupID: "g-rt", reason: .sameApp))
        let state = try #require(F.tabbed(plan))
        #expect(state.pane(containing: F.id("safari"))?.selected == F.id("slack-1"))
        #expect(state.pane(containing: F.id("safari"))?.tabs == [F.id("slack-1"), F.id("slack-2"), F.id("safari")])
    }

    @Test func addingPanesPreservesDeliberateEmptyNodesAndIsDeterministic() throws {
        let document = SavedLayoutDocument(name: "Empty", mode: .bento,
            layout: .split(axis: .vertical, ratios: [0.5, 0.5], children: [.slot("L"), .empty]),
            slots: [.init(id: "L", prefer: [.app(App.safari)])], extraWindows: .addAsPanes)
        let windows = F.windows([("safari", App.safari, nil), ("mail", App.mail, nil)])
        let plan = try F.plan(document, windows)
        #expect(plan.extras[F.id("mail")] == .addedAsPane)
        #expect(F.vacancies(try #require(F.bento(plan)).root) == 1)
        #expect(try F.plan(document, windows.reversed()) == plan)
        let overflowWindows = F.windows((0..<9).map { ("w\($0)", App.mail, F.anywhere) })
        let overflow = try F.plan(F.writing(extraWindows: .addAsPanes), overflowWindows)
        #expect(F.bento(overflow)?.root?.windowIDs.count == 6)
        #expect(overflow.extras.values.filter { $0 == .addedAsPane }.count == 4)
        #expect(overflow.extras.values.filter { $0 == .floating }.count == 3)
        for window in overflowWindows where overflow.extras[window.id] == .floating {
            #expect(!overflow.placements.contains { $0.windowID == window.id })
        }
        #expect(try F.plan(F.writing(extraWindows: .addAsPanes), overflowWindows.reversed()) == overflow)
    }

    @Test func manualFloatingRectanglesParticipateInFillByArea() throws {
        let document = SavedLayoutDocument(name: "Float", mode: .manual,
            slots: [.init(id: "small"), .init(id: "float")],
            windows: [.init(slot: "small", rect: .init(x: 0, y: 0, width: 0.2, height: 0.2))],
            floats: [.init(slot: "float", rect: .init(x: 0.1, y: 0.1, width: 0.8, height: 0.8))])
        let plan = try F.plan(document, F.windows([("mail", App.mail, nil)]))
        #expect(plan.assignments == ["float": F.id("mail")])
        #expect(plan.slotReasons == ["small": .empty, "float": .largestFreeSlot])
        #expect(plan.placements.count == 1)
    }

    @Test func defaultAndEqualFrontRanksUseIDs() throws {
        let windows = ["z", "a", "b"].map {
            SavedLayoutEligibleWindow(id: F.id($0), bundleID: App.mail, frame: F.anywhere)
        }
        let plan = try F.plan(F.writing(), windows)
        #expect(plan == (try F.plan(F.writing(), windows.reversed())))
        #expect(plan.assignments["L"] == F.id("a"))
        #expect(plan.slotReasons["L"] == .largestFreeSlot)
    }

    @Test func sixSlotsTwelveWindowsTimingMedianTwentyRuns() throws {
        let ids = (0..<6).map { "s\($0)" }
        let document = SavedLayoutDocument(name: "Six", mode: .manual,
            slots: ids.map { .init(id: $0, prefer: [.app(App.safari), .app(App.chrome)]) },
            windows: ids.enumerated().map { .init(slot: $0.element,
                rect: .init(x: Double($0.offset % 3) / 3, y: Double($0.offset / 3) / 2, width: 1.0 / 3, height: 0.5)) })
        let windows = F.windows((0..<12).map { ("w\($0)", $0 % 2 == 0 ? App.safari : App.chrome, F.anywhere) })
        var durations: [Double] = []
        for _ in 0..<20 {
            let start = ContinuousClock.now // real-time: measures actual fill-planner duration; correctness uses plan assertions
            let plan = try F.plan(document, windows)
            let elapsed = start.duration(to: .now).components // real-time: ends the actual fill-planner measurement
            durations.append(Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15)
            #expect(plan.assignments.count == 6)
            #expect(plan.extras.count == 6)
        }
        durations.sort()
        print("SavedLayoutFill 6 slots x 12 windows, 20 runs, median ms: \((durations[9] + durations[10]) / 2)")
    }
}

extension SavedLayoutFillTests {
    @Test func largeManualAndTabbedTimingMedians() throws {
        func measure(_ document: SavedLayoutDocument, _ windows: [SavedLayoutEligibleWindow], _ label: String) throws {
            var times: [Double] = []
            for _ in 0..<5 {
                let start = ContinuousClock.now // real-time: measures actual fill-planner duration; correctness uses plan assertions
                let plan = try F.plan(document, windows)
                let elapsed = start.duration(to: .now).components // real-time: ends the actual fill-planner measurement
                times.append(Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15)
                #expect(plan.assignments.count == min(document.slots.count, windows.count))
            }
            print("SavedLayoutFill \(label), 5 runs, median ms: \(times.sorted()[2])")
        }
        let slots = (0..<64).map { SavedLayoutSlot(id: String(format: "s%02d", $0), prefer: [.group("Browser")]) }
        let manual = SavedLayoutDocument(name: "64", mode: .manual, slots: slots,
            windows: slots.enumerated().map { .init(slot: $0.element.id, rect: .init(
                x: Double($0.offset % 8) / 8, y: Double($0.offset / 8) / 8, width: 0.125, height: 0.125)) })
        let smallWindows = F.windows((0..<16).map { ("w\($0)", App.safari,
            F.frame(0.8, 0.8, 0.125, 0.125)) })
        try measure(manual, smallWindows, "64 Manual slots x 16 windows")
        let groups = (0..<12).map { SavedLayoutGroup(id: "g\($0)", slots: ["s\($0)"], selected: "s\($0)") }
        let tabbed = SavedLayoutDocument(name: "12", mode: .tabbed,
            layout: .split(axis: .vertical, ratios: Array(repeating: 0.25, count: 4), children: (0..<4).map { column in
                .split(axis: .horizontal, ratios: Array(repeating: 1.0 / 3, count: 3), children: (0..<3).map {
                    .group("g\(column * 3 + $0)")
                })
            }), slots: (0..<12).map { .init(id: "s\($0)", prefer: [.group("Browser")]) }, groups: groups)
        let manyWindows = F.windows((0..<20).map { ("w\($0)", App.safari, F.anywhere) })
        try measure(tabbed, manyWindows, "12 Tabbed panes x 20 windows")
    }
}

extension SavedLayoutFillTests {
    @Test func preferredAssignmentMatchesExhaustiveOracleIncludingTranspose() {
        struct Seed {
            var state: UInt64 = 0x1C_2026
            mutating func next(_ upper: Int) -> Int {
                state = state &* 6_364_136_223_846_793_005 &+ 1
                return Int((state >> 32) % UInt64(upper))
            }
        }
        struct Outcome {
            var priority: [Int]
            var distance: Double
            var ids: [Int]
        }
        var seed = Seed()
        var checked = 0
        let sizes = (1...5).flatMap { n in (0...5).map { (n, $0) } } + [(8, 3), (8, 4)]
        for (n, m) in sizes { for variant in 0..<8 {
            let slots = (0..<n).map { SavedLayoutSlot(id: "s\($0)") }
            var preferences: [String: [String]] = [:]
            var targets: [String: NormalizedRect] = [:]
            for slot in slots {
                preferences[slot.id] = (0..<3).filter { _ in seed.next(3) != 0 }.map { "com.test.a\($0)" }
                targets[slot.id] = .init(x: Double(seed.next(4)) / 5, y: Double(seed.next(4)) / 5, width: 0.1, height: 0.1)
            }
            let common = F.frame(0.3, 0.3, 0.1, 0.1)
            let windows = (0..<m).map { index in
                SavedLayoutEligibleWindow(id: F.id("w\(index)"), bundleID: "com.test.a\(seed.next(3))",
                    frame: variant < 3 || (variant < 6 && index < 2) ? common
                        : F.frame(Double(seed.next(4)) / 5 + (variant == 7 ? 1e-13 : 0), Double(seed.next(4)) / 5, 0.1, 0.1))
            }
            var outcomes: [Outcome] = []
            func enumerate(_ row: Int, _ used: Set<Int>, _ priority: [Int], _ distance: Double, _ ids: [Int]) {
                if row == n { outcomes.append(.init(priority: priority, distance: distance, ids: ids)); return }
                enumerate(row + 1, used, priority, distance, ids + [m])
                for column in windows.indices where !used.contains(column) {
                    guard let rank = preferences[slots[row].id]!.firstIndex(of: windows[column].bundleID) else { continue }
                    var next = priority; next[0] -= 1; next[rank + 1] -= 1
                    enumerate(row + 1, used.union([column]), next,
                        distance + SavedLayoutPositionMatching.distance(windows[column], to: targets[slots[row].id]!, in: F.workArea), ids + [column])
                }
            }
            enumerate(0, [], [0, 0, 0, 0], 0, [])
            let bestPriority = outcomes.map(\.priority).min { $0.lexicographicallyPrecedes($1) }!
            let preferred = outcomes.filter { $0.priority == bestPriority }
            let bestDistance = preferred.map(\.distance).min()!
            let expected = preferred.filter { $0.distance <= bestDistance + 1e-12 }.min { $0.ids.lexicographicallyPrecedes($1.ids) }!
            let expectedIDs = Dictionary(uniqueKeysWithValues: expected.ids.enumerated().compactMap { row, column in
                column < m ? (slots[row].id, windows[column].id) : nil
            })
            let actual = SavedLayoutPositionMatching.assign(slots: slots.reversed(), windows: windows.reversed(),
                targets: targets, in: F.workArea, preferences: preferences)
            #expect(actual == expectedIDs, "n=\(n), m=\(m), variant=\(variant)")
            checked += 1
        } }
        print("SavedLayoutFill preferred exhaustive oracle: \(checked) cases, including transpose and exact ties")
    }
}

extension SavedLayoutFillTests {
    @Test func capturedTabbedSlotsKeepTheirOrderWithoutFrontRanks() throws {
        let document = SavedLayoutDocument(name: "Tabs", mode: .tabbed, layout: .group("pane"),
            slots: [.init(id: "first", prefer: [.app(App.safari)]), .init(id: "second", prefer: [.app(App.chrome)])],
            groups: [.init(id: "pane", slots: ["first", "second"], selected: "first")])
        let windows = [SavedLayoutEligibleWindow(id: F.id("z"), bundleID: App.safari, frame: F.anywhere),
                       .init(id: F.id("a"), bundleID: App.chrome, frame: F.anywhere)]
        let plan = try F.plan(document, windows)
        #expect(F.tabbed(plan)?.panes[0].tabs == [F.id("z"), F.id("a")])
        #expect(F.tabbed(plan)?.panes[0].selected == F.id("z"))
        var unpreferred = document
        unpreferred.slots = [.init(id: "first"), .init(id: "second")]
        let partial = try F.plan(unpreferred, [windows[1]])
        #expect(partial.assignments == ["first": F.id("a")])
        #expect(partial.emptySlots == ["second"])
    }
}

extension SavedLayoutFillTests {
    @Test func sixteenManualRectanglesTimingMedianTwentyRuns() throws {
        let slots = (0..<16).map { SavedLayoutSlot(id: String(format: "s%02d", $0), prefer: [.group("Browser")]) }
        let document = SavedLayoutDocument(name: "Sixteen", mode: .manual, slots: slots,
            windows: slots.enumerated().map { .init(slot: $0.element.id,
                rect: .init(x: Double($0.offset % 4) / 4, y: Double($0.offset / 4) / 4, width: 0.25, height: 0.25)) })
        let specs: [(String, String, BTRect?)] = (0..<16).map { index in
            let app = index % 2 == 0 ? App.safari : App.chrome
            let frame = F.frame(Double(index % 4) / 4, Double(index / 4) / 4, 0.25, 0.25)
            return ("w\(index)", app, frame)
        }
        let windows = F.windows(specs)
        var times: [Double] = []
        for _ in 0..<20 {
            let start = ContinuousClock.now // real-time: measures actual fill-planner duration; correctness uses plan assertions
            let plan = try F.plan(document, windows)
            let elapsed = start.duration(to: .now).components // real-time: ends the actual fill-planner measurement
            times.append(Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15)
            #expect(plan.assignments.count == 16)
            #expect(plan.extras.isEmpty)
        }
        times.sort()
        print("SavedLayoutFill 16 Manual rectangles x 16 windows, 20 runs, median ms: \((times[9] + times[10]) / 2)")
    }
}
