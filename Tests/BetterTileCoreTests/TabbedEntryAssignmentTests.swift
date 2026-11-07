import Testing
@testable import BetterTileCore

@Suite struct TabbedEntryAssignmentTests {
    private let bounds = BTRect(x: 0, y: 0, width: 1000, height: 800)

    private func window(_ id: String, _ frame: BTRect) -> WindowSnapshot {
        WindowSnapshot(id: WindowID(rawValue: id), processIdentifier: 1,
                       frame: frame, displayID: DisplayID(rawValue: "test-display"))
    }

    private func panes(_ preset: TabbedPreset) -> [BTRect] {
        TabbedLayoutState(preset: preset).frames(in: bounds).values.sorted {
            $0.minY == $1.minY ? $0.minX < $1.minX : $0.minY < $1.minY
        }
    }

    /// Pane members in pane order, `-` for an empty pane, then overflow tabs.
    private func assign(_ windows: [WindowSnapshot], _ frames: [BTRect]) -> [String] {
        let result = TabbedEntryAssignment.assign(windows: windows, paneFrames: frames)
        return result.primary.map { $0?.rawValue ?? "-" } + result.overflow.map(\.rawValue)
    }

    @Test func overlapOutranksDistanceAndChoosesOverflowJointly() {
        let top = window("top", .init(x: 0, y: 0, width: 300, height: 200))
        let bottom = window("bottom", .init(x: 350, y: 410, width: 300, height: 200))
        let extra = window("extra", .init(x: 0, y: 650, width: 300, height: 100))
        #expect(assign([extra, bottom, top], panes(.rows)) == ["top", "bottom", "extra"])
        // The nearest window is not the largest-overlap primary, even for one pane.
        let tiny = window("tiny", .init(x: 495, y: 395, width: 10, height: 10))
        #expect(assign([tiny, top], [bounds]) == ["top", "tiny"])
    }

    /// With fewer windows than panes, overlap chooses the panes, so the empty
    /// pane can be anywhere. A window that overlaps no pane still takes the
    /// nearest free pane, and a full tie leaves empty panes last.
    @Test func fewerWindowsThanPanesUseTheOverlappingPanes() {
        let right = window("right", .init(x: 700, y: 600, width: 100, height: 100))
        #expect(assign([right], panes(.grid)) == ["-", "-", "-", "right"])
        let left = window("left", .init(x: 0, y: 0, width: 200, height: 100))
        let topRight = window("top-right", .init(x: 605, y: 190, width: 120, height: 200))
        // Focus: a left pane, then top-right and bottom-right panes.
        #expect(assign([topRight, left], panes(.focus)) == ["left", "top-right", "-"])
        // No overlap at all: the nearest pane by centre distance.
        let below = window("below", .init(x: 800, y: 900, width: 100, height: 100))
        #expect(assign([below], panes(.grid)) == ["-", "-", "-", "below"])
        // Equal scores: empty panes stay last.
        let everywhere = window("everywhere", .init(x: 0, y: 0, width: 1000, height: 800))
        #expect(assign([everywhere], Array(repeating: bounds, count: 3)) == ["everywhere", "-", "-"])
        #expect(assign([], panes(.grid)) == ["-", "-", "-", "-"])
        #expect(assign([right, left], []) == ["left", "right"])
    }

    /// Live check: a left full-height window and a right column of two. Grid
    /// has four panes. The bottom-right window must take the bottom-right
    /// pane, leaving bottom-left empty.
    @Test func gridEntryLeavesTheUncoveredPaneEmpty() {
        let area = BTRect(x: 0, y: 30, width: 2560, height: 1410)
        let frames = TabbedLayoutState(preset: .grid).frames(in: area).values.sorted {
            $0.minY == $1.minY ? $0.minX < $1.minX : $0.minY < $1.minY
        }
        let a = window("a", .init(x: 1281, y: 736, width: 1279, height: 704))
        let b = window("b", .init(x: 1281, y: 30, width: 1279, height: 705))
        let c = window("c", .init(x: 0, y: 30, width: 1280, height: 1410))
        #expect(assign([a, b, c], frames) == ["c", "b", "-", "a"])
    }

    @Test func zeroOverlapUsesTotalDistanceRatherThanGreedyDistance() {
        let frames = [BTRect(x: 0, y: 0, width: 100, height: 100),
                      BTRect(x: 100, y: 0, width: 100, height: 100)]
        let left = window("left", .init(x: -5, y: -110, width: 10, height: 10))
        let right = window("right", .init(x: 55, y: -110, width: 10, height: 10))
        #expect([left, right].allSatisfy { w in frames.allSatisfy { w.frame.intersection($0) == nil } })
        #expect(assign([right, left], frames) == ["left", "right"])
        let distant = window("distant", .init(x: -1000, y: -110, width: 10, height: 10))
        #expect(assign([distant, right, left], frames) == ["left", "right", "distant"])
    }

    @Test func tiesUseWindowReadingOrderThenIDInPaneOrder() {
        // All panes have the same frame, so the assignments have equal scores.
        let frames = Array(repeating: bounds, count: 3)
        let lowID = window("a", .init(x: 50, y: 50, width: 100, height: 100))
        let highID = window("z", lowID.frame)
        let earlier = window("first", .init(x: 600, y: 0, width: 100, height: 100))
        #expect(assign([highID, lowID, earlier], frames) == ["first", "a", "z"])
        #expect(assign([earlier, lowID, highID], frames) == ["first", "a", "z"])
        let left = window("zz-left", .init(x: 0, y: 50, width: 100, height: 100))
        #expect(assign([highID, earlier, left, lowID], Array(repeating: bounds, count: 4))
                == ["first", "zz-left", "a", "z"])
        let same = (0..<6).reversed().map { window("w\($0)", .init(x: 350, y: 250, width: 300, height: 300)) }
        #expect(assign(same, panes(.grid)) == (0..<6).map { "w\($0)" })
    }

    @Test func overflowRetainsReadingOrderAndCyclesThroughPanes() {
        let left = window("left", .init(x: 0, y: 0, width: 500, height: 800))
        let right = window("right", .init(x: 500, y: 0, width: 500, height: 800))
        let extras = (0..<5).map { window("extra-\($0)", .init(x: Double($0 * 10), y: 900, width: 10, height: 10)) }
        let ordered = assign(Array(extras.reversed()) + [right, left], panes(.columns))
        let tabs = (0..<2).map { pane in ordered.enumerated().filter { $0.offset % 2 == pane }.map(\.element) }
        #expect(tabs == [["left", "extra-0", "extra-2", "extra-4"], ["right", "extra-1", "extra-3"]])
    }

    @Test func boundedSearchHandlesManyWindowsAndFallsBackAboveFourPanes() {
        let members = (0..<10_000).map {
            window("w\($0)", .init(x: 350, y: Double($0), width: 300, height: 300))
        }
        let result = assign(Array(members.reversed()), panes(.grid))
        #expect(result.count == members.count)
        #expect(Set(result).count == members.count)
        #expect(assign(Array(members.reversed()), Array(repeating: bounds, count: 5)) == members.map { $0.id.rawValue })
    }

    private struct Seed {
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        mutating func next(_ upper: Int) -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1
            return Int((state >> 32) % UInt64(upper))
        }
    }

    @Test func seededWindowsWhollyInsideAnyPaneRegionsKeepTheirPanes() {
        var seed = Seed()
        var covered = Set<TabbedPreset>()
        for example in 0..<300 {
            let preset = TabbedPreset.allCases[seed.next(TabbedPreset.allCases.count)]
            covered.insert(preset)
            let frames = panes(preset)
            // Use a random subset of the panes, so empty panes can be anywhere.
            var chosen = Array(frames.indices)
            for index in chosen.indices.reversed() { chosen.swapAt(index, seed.next(index + 1)) }
            let occupied = Set(chosen.prefix(1 + seed.next(frames.count)))
            let windows = frames.enumerated().filter { occupied.contains($0.offset) }.map { index, frame in
                let width = Double(1 + seed.next(Int(frame.size.width)))
                let height = Double(1 + seed.next(Int(frame.size.height)))
                let x = frame.minX + Double(seed.next(1001)) / 1000 * (frame.size.width - width)
                let y = frame.minY + Double(seed.next(1001)) / 1000 * (frame.size.height - height)
                return window("region-\(index)", .init(x: x, y: y, width: width, height: height))
            }
            var shuffled = windows
            for index in shuffled.indices.reversed() { shuffled.swapAt(index, seed.next(index + 1)) }
            let expected = frames.indices.map { occupied.contains($0) ? "region-\($0)" : "-" }
            #expect(assign(shuffled, frames) == expected, "seeded case \(example), \(preset)")
        }
        #expect(covered == Set(TabbedPreset.allCases))
    }

    @Test func seededAssignmentsMatchExhaustiveOracleIncludingOverflowAndEmptyPanes() {
        var seed = Seed()
        for example in 0..<250 {
            let frames = panes(TabbedPreset.allCases[seed.next(TabbedPreset.allCases.count)])
            let windows = (0..<seed.next(7)).map { index in
                window("w\(index)", .init(x: Double(seed.next(1400) - 200), y: Double(seed.next(1200) - 200),
                                         width: Double(1 + seed.next(700)), height: Double(1 + seed.next(600))))
            }.sorted {
                if $0.frame.minY != $1.frame.minY { return $0.frame.minY < $1.frame.minY }
                if $0.frame.minX != $1.frame.minX { return $0.frame.minX < $1.frame.minX }
                return $0.id < $1.id
            }
            let count = min(windows.count, frames.count)
            // One entry per pane: a window rank, or `empty` for an empty pane.
            // Any `frames.count - count` panes may stay empty.
            let empty = windows.count
            var bestRanks: [Int] = [], bestOverlap = -1.0, bestDistance = Double.infinity
            func visit(_ ranks: [Int]) {
                if ranks.count < frames.count {
                    let filled = ranks.filter { $0 != empty }.count
                    if ranks.count - filled < frames.count - count { visit(ranks + [empty]) }
                    if filled < count {
                        for rank in windows.indices where !ranks.contains(rank) { visit(ranks + [rank]) }
                    }
                    return
                }
                var overlap = 0.0, distance = 0.0
                // Sum in window reading order to compare the same floating-point
                // totals without using the DP's state pruning.
                for rank in windows.indices {
                    guard let pane = ranks.firstIndex(of: rank) else { continue }
                    overlap += windows[rank].frame.intersection(frames[pane])?.area ?? 0
                    let dx = windows[rank].frame.midX - frames[pane].midX
                    let dy = windows[rank].frame.midY - frames[pane].midY
                    distance += dx * dx + dy * dy
                }
                if overlap > bestOverlap || (overlap == bestOverlap &&
                    (distance < bestDistance || (distance == bestDistance && ranks.lexicographicallyPrecedes(bestRanks)))) {
                    bestRanks = ranks; bestOverlap = overlap; bestDistance = distance
                }
            }
            visit([])
            let expected = bestRanks.map { $0 == empty ? "-" : windows[$0].id.rawValue }
                + windows.indices.filter { !bestRanks.contains($0) }.map { windows[$0].id.rawValue }
            #expect(assign(Array(windows.reversed()), frames) == expected, "oracle case \(example)")
        }
    }
}
