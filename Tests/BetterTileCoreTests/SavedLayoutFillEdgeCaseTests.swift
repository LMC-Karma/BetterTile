import Foundation
import Testing
@testable import BetterTileCore

@Suite(.serialized) struct SavedLayoutFillEdgeCaseTests {
    let bounds = BTRect(x: 0, y: 0, width: 1200, height: 800)
    let app = "com.test.A"
    func window(_ id: String, app: String = "com.test.A", frame: BTRect? = nil,
                rank: Int = .max) -> SavedLayoutEligibleWindow {
        .init(id: .init(rawValue: id), bundleID: app,
              frame: frame ?? .init(x: 20, y: 20, width: 300, height: 400), frontRank: rank)
    }

    @Test(arguments: ["added", "floating", "tabs"])
    func settledExtraMembershipMakesRepeatApplyEmpty(kind: String) throws {
        let tabbed = kind == "tabs"
        let document = SavedLayoutDocument(name: "Repeat", mode: tabbed ? .tabbed : .bento,
            layout: tabbed ? .group("pane") : .slot("main"),
            slots: [.init(id: "main", prefer: [.app(app)])],
            groups: tabbed ? [.init(id: "pane", slots: ["main"], selected: "main")] : [],
            extraWindows: kind == "added" ? .addAsPanes : .float)
        let windows = [window("a", rank: 1), window("b", app: "com.test.B", rank: 0)]
        let first = try SavedLayoutPlanner.plan(document, in: bounds, windows: windows)
        let settled = windows.map { original in
            var window = original
            if let frame = first.placements.first(where: { $0.windowID == window.id })?.frame { window.frame = frame }
            return window
        }
        let repeated = try SavedLayoutPlanner.plan(document, in: bounds, windows: settled,
                                                   currentSession: first.targetSession)
        #expect(repeated.placements.isEmpty)
        #expect(repeated.targetSession == first.targetSession)
        #expect(repeated.needsSessionUpdate == false)
        #expect(repeated.isEmpty)
        if kind == "added" { #expect(repeated.extras[.init(rawValue: "b")] == .addedAsPane) }
        if kind == "floating" { #expect(repeated.extras[.init(rawValue: "b")] == .floating) }
    }

    @Test(arguments: 0..<3, [1, 2])
    func mixedAxisAreaAndDistanceUseRuntimeBounds(example: Int, count: Int) throws {
        let square = example < 2
        let area = square ? BTRect(x: 0, y: 0, width: 1200, height: 1200)
            : BTRect(x: -1600, y: 40, width: 1600, height: 900)
        let ratio = example == 0 ? 0.33 : (square ? 99.0 / 299 : 37.0 / 112)
        let document = SavedLayoutDocument(name: "Runtime areas", mode: .bento,
            layout: .split(axis: .vertical, ratios: [ratio, 1 - ratio], children: [.slot("L"),
                .split(axis: .horizontal, ratios: [0.5, 0.5], children: [.slot("RT"), .slot("RB")])]),
            slots: [.init(id: "L"), .init(id: "RT"), .init(id: "RB")], paneGap: 12)
        // Independent arithmetic: each split removes one 12-point gap before dividing.
        // These expectations do not use Canvas or Bento's geometry helpers.
        let leftWidth = (area.size.width - 12) * ratio
        let rightWidth = area.size.width - 12 - leftWidth
        let halfHeight = (area.size.height - 12) / 2
        let expected: [String: BTRect] = [
            "L": .init(x: area.minX, y: area.minY, width: leftWidth, height: area.size.height),
            "RT": .init(x: area.minX + leftWidth + 12, y: area.minY, width: rightWidth, height: halfHeight),
            "RB": .init(x: area.minX + leftWidth + 12, y: area.minY + halfHeight + 12, width: rightWidth, height: halfHeight),
        ]
        if example == 0 {
            #expect(abs(expected["L"]!.area - 470448) < 1e-6)
            #expect(abs(expected["RT"]!.area - 472800.24) < 1e-6)
        } else {
            #expect(abs(expected["L"]!.area - expected["RT"]!.area) < 1e-6)
            #expect(abs(expected["RT"]!.area - expected["RB"]!.area) < 1e-6)
        }
        let all = ["L", "RT", "RB"].map { window($0, frame: expected[$0]) }
        let geometry = try SavedLayoutPlanner.plan(document, in: area, windows: all,
            choices: Dictionary(uniqueKeysWithValues: all.map { ($0.id.rawValue, $0.id) }))
        guard case let .bento(state) = geometry.targetSession else { Issue.record("Expected Adaptive"); return }
        for (id, frame) in state.paneFrames(in: area) {
            #expect(frame.approximatelyEquals(expected[id.rawValue]!, tolerance: 1e-8))
        }
        let windows = [window("rt", frame: expected["RT"], rank: 0), window("rb", frame: expected["RB"], rank: 1)]
        let plan = try SavedLayoutPlanner.plan(document, in: area, windows: Array(windows.prefix(count)))
        let assignments: [String: WindowID] = count == 1 ? ["RT": .init(rawValue: "rt")]
            : ["RT": .init(rawValue: "rt"), "RB": .init(rawValue: "rb")]
        #expect(plan.assignments == assignments)
        #expect(plan.slotReasons["RT"] == .largestFreeSlot)
        #expect(plan.placements.isEmpty)
    }

    @Test(arguments: [["z-first", "a-second"], ["slot-9", "slot-10"]])
    func preferredCapturedGroupFillsItsFirstSlotBeforeLexicallyEarlierSlots(slots: [String]) throws {
        let document = SavedLayoutDocument(name: "Captured", mode: .tabbed, layout: .group("pane"),
            slots: slots.map { .init(id: $0, prefer: [.app(app)]) },
            groups: [.init(id: "pane", slots: slots, selected: slots[0])])
        let plan = try SavedLayoutPlanner.plan(document, in: bounds, windows: [window("only")])
        #expect(plan.assignments == [slots[0]: .init(rawValue: "only")])
        #expect(plan.emptySlots == [slots[1]])
        #expect(plan.slotReasons[slots[0]] == .preferred(rank: 0))
        guard case let .tabbed(state) = plan.targetSession else { Issue.record("Expected Tabbed"); return }
        #expect(state.panes[0].selected == .init(rawValue: "only"))
    }

    @Test func adaptiveSlotsKeepTheOriginalSlotIDTieRule() throws {
        let document = SavedLayoutDocument(name: "Unchanged ID tie", mode: .bento,
            layout: .split(axis: .vertical, ratios: [0.5, 0.5], children: [.slot("slot-9"), .slot("slot-10")]),
            slots: [.init(id: "slot-9", prefer: [.app(app)]), .init(id: "slot-10", prefer: [.app(app)])])
        let plan = try SavedLayoutPlanner.plan(document, in: bounds,
            windows: [window("only", frame: bounds)])
        #expect(plan.assignments == ["slot-10": .init(rawValue: "only")])
        #expect(plan.emptySlots == ["slot-9"])
        #expect(plan.slotReasons["slot-10"] == .preferred(rank: 0))
    }

    @Test func capturedSlotOrderNeverOutranksPreferenceRankOrDistance() throws {
        var document = SavedLayoutDocument(name: "Captured", mode: .tabbed, layout: .group("pane"),
            slots: [.init(id: "z-first", prefer: [.app("com.test.B"), .app(app)]),
                    .init(id: "a-second", prefer: [.app(app)])],
            groups: [.init(id: "pane", slots: ["z-first", "a-second"], selected: "z-first")])
        let ranked = try SavedLayoutPlanner.plan(document, in: bounds, windows: [window("only")])
        #expect(ranked.assignments == ["a-second": .init(rawValue: "only")])
        #expect(ranked.slotReasons["a-second"] == .preferred(rank: 0))
        document.slots[0].prefer = [.app(app)]
        let near = NormalizedRect(x: 0.7, y: 0, width: 0.3, height: 1)
        let distant = try SavedLayoutPlanner.plan(document, in: bounds,
            windows: [window("only", frame: near.frame(in: bounds))],
            preferredFrames: ["z-first": .init(x: 0, y: 0, width: 0.3, height: 1), "a-second": near])
        #expect(distant.assignments == ["a-second": .init(rawValue: "only")])
    }

    @Test func capturedPaneWithoutSlotsStaysEmptyWhenAnExtraIsNearestToIt() throws {
        let document = SavedLayoutDocument(name: "Empty captured pane", mode: .tabbed,
            layout: .split(axis: .vertical, ratios: [0.5, 0.5], children: [.group("left"), .group("empty")]),
            slots: [.init(id: "main", prefer: [.app(app)])],
            groups: [.init(id: "left", slots: ["main"], selected: "main"), .init(id: "empty", slots: [])])
        let plan = try SavedLayoutPlanner.plan(document, in: bounds,
            windows: [window("a"), window("extra", app: "com.test.B", frame: .init(x: 800, y: 0, width: 300, height: 400))])
        #expect(plan.extras[.init(rawValue: "extra")] == .tab(groupID: "left", reason: .nearestPane))
        guard case let .tabbed(state) = plan.targetSession else { Issue.record("Expected Tabbed"); return }
        #expect(state.panes[1].tabs.isEmpty)
        #expect(state.panes[1].selected == nil)
    }

    @Test(arguments: [false, true])
    func frontmostExtraOverridesSelectionOnlyWithAKnownRank(known: Bool) throws {
        let document = SavedLayoutDocument(name: "Selection", mode: .tabbed, layout: .group("pane"),
            slots: [.init(id: "main", prefer: [.app(app)])],
            groups: [.init(id: "pane", slots: ["main"], selected: "main")])
        let plan = try SavedLayoutPlanner.plan(document, in: bounds,
            windows: [window("z-placed", rank: known ? 1 : .max),
                      window("a-extra", app: "com.test.B", rank: known ? 0 : .max)])
        guard case let .tabbed(state) = plan.targetSession else { Issue.record("Expected Tabbed"); return }
        #expect(state.panes[0].selected == WindowID(rawValue: known ? "a-extra" : "z-placed"))
    }

    @Test func unpreferredNearestMatchingKeepsCachedTargetsAfterTheRuntimeFrontmostPick() throws {
        let document = SavedLayoutDocument(name: "Cache", mode: .bento,
            layout: .split(axis: .vertical, ratios: [1.0 / 3, 1.0 / 3, 1.0 / 3],
                           children: [.slot("L"), .slot("M"), .slot("R")]),
            slots: [.init(id: "L"), .init(id: "M"), .init(id: "R")], paneGap: 12)
        let left = BTRect(x: 0, y: 0, width: 392, height: 800)
        let middle = BTRect(x: 404, y: 0, width: 392, height: 800)
        let right = BTRect(x: 808, y: 0, width: 392, height: 800)
        let plan = try SavedLayoutPlanner.plan(document, in: bounds,
            windows: [window("front", frame: left, rank: 0), window("middle", frame: middle, rank: 1),
                      window("right", frame: right, rank: 2)],
            preferredFrames: ["L": .init(frame: right, in: bounds), "M": .init(frame: right, in: bounds),
                              "R": .init(frame: middle, in: bounds)])
        #expect(plan.assignments == ["L": .init(rawValue: "front"), "M": .init(rawValue: "right"),
                                     "R": .init(rawValue: "middle")])
        #expect(plan.slotReasons == ["L": .largestFreeSlot, "M": .nearestPosition, "R": .nearestPosition])
    }

    @Test func explicitChoiceCanUseAnUnpreferredForeignWindow() throws {
        let document = SavedLayoutDocument(name: "Choice", mode: .manual, slots: [.init(id: "main")],
            windows: [.init(slot: "main", rect: .init(x: 0, y: 0, width: 1, height: 1))])
        var foreign = window("foreign", frame: .init(x: 2000, y: 0, width: 300, height: 400))
        foreign.matchingFrame = .init(x: 0, y: 0, width: 0.25, height: 0.5)
        let plan = try SavedLayoutPlanner.plan(document, in: bounds, windows: [foreign], choices: ["main": foreign.id])
        #expect(plan.assignments == ["main": foreign.id])
        #expect(plan.slotReasons["main"] == .chosen)
    }

}
