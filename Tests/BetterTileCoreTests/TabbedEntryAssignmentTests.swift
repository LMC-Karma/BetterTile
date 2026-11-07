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

    /// Each pane's tabs in pane order, joined by `+`; `-` for an empty pane.
    private func assign(_ windows: [WindowSnapshot], _ frames: [BTRect]) -> [String] {
        TabbedEntryAssignment.assign(windows: windows, paneFrames: frames).panes.map {
            $0.isEmpty ? "-" : $0.map(\.rawValue).joined(separator: "+")
        }
    }

    @Test func overlapOutranksDistanceAndChoosesOverflowJointly() {
        let top = window("top", .init(x: 0, y: 0, width: 300, height: 200))
        let bottom = window("bottom", .init(x: 350, y: 410, width: 300, height: 200))
        let extra = window("extra", .init(x: 0, y: 650, width: 300, height: 100))
        // The extra window joins the bottom pane, which it overlaps.
        #expect(assign([extra, bottom, top], panes(.rows)) == ["top", "bottom+extra"])
        // The nearest window is not the largest-overlap primary, even for one pane.
        let tiny = window("tiny", .init(x: 495, y: 395, width: 10, height: 10))
        #expect(assign([tiny, top], [bounds]) == ["top+tiny"])
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
        let paneless = TabbedEntryAssignment.assign(windows: [right, left], paneFrames: [])
        #expect(paneless.primary.isEmpty && paneless.panes.isEmpty)
        #expect(paneless.overflow == [left.id, right.id])
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
        // An extra window that overlaps no pane joins the nearest pane.
        let distant = window("distant", .init(x: 1000, y: -110, width: 10, height: 10))
        #expect(assign([distant, right, left], frames) == ["left", "right+distant"])
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
        // Extra windows that tie everywhere keep the panes-in-turn order.
        let same = (0..<6).reversed().map { window("w\($0)", .init(x: 350, y: 250, width: 300, height: 300)) }
        #expect(assign(same, panes(.grid)) == ["w0+w4", "w1+w5", "w2", "w3"])
    }

    /// Extra windows join the pane they overlap most, in reading order.
    /// Without overlap they join the nearest pane; full ties take the panes
    /// in turn.
    @Test func overflowJoinsTheMostOverlappedPaneThenTheNearest() {
        let left = window("left", .init(x: 0, y: 0, width: 500, height: 800))
        let right = window("right", .init(x: 500, y: 0, width: 500, height: 800))
        let inRight = (0..<2).map { window("in-right-\($0)", .init(x: 600 + Double($0 * 10), y: 500, width: 100, height: 100)) }
        #expect(assign(Array(inRight.reversed()) + [right, left], panes(.columns))
                == ["left", "right+in-right-0+in-right-1"])
        let nearLeft = (0..<3).map { window("near-left-\($0)", .init(x: Double($0 * 10), y: 900, width: 10, height: 10)) }
        #expect(assign(Array(nearLeft.reversed()) + [right, left], panes(.columns))
                == ["left+near-left-0+near-left-1+near-left-2", "right"])
        // Centred on the gap between the columns: equal distance to both.
        let tied = (0..<5).map { window("tied-\($0)", .init(x: 495, y: 900, width: 10, height: 10)) }
        #expect(assign(Array(tied.reversed()) + [right, left], panes(.columns))
                == ["left+tied-0+tied-2+tied-4", "right+tied-1+tied-3"])
    }

    /// Live layout on Columns: the bottom-right window lies inside the right
    /// pane, so it becomes a tab there.
    @Test func columnsEntryPutsTheExtraWindowInThePaneItCovers() {
        let area = BTRect(x: 0, y: 30, width: 2560, height: 1410)
        let frames = TabbedLayoutState(preset: .columns).frames(in: area).values.sorted {
            $0.minY == $1.minY ? $0.minX < $1.minX : $0.minY < $1.minY
        }
        let a = window("a", .init(x: 1281, y: 736, width: 1279, height: 704))
        let b = window("b", .init(x: 1281, y: 30, width: 1279, height: 705))
        let c = window("c", .init(x: 0, y: 30, width: 1280, height: 1410))
        #expect(assign([a, b, c], frames) == ["c", "b+a"])
    }

    /// Coincident windows score the same in every assignment. Summing their
    /// terms in a different window order must not change the result: window
    /// reading order (then ID) decides, in pane order. Main + 2 on integer and
    /// fractional work areas.
    @Test(arguments: [BTRect(x: 0, y: 0, width: 1000, height: 800),
                      BTRect(x: 0, y: 25, width: 1440.5, height: 875.25)])
    func coincidentWindowsFollowReadingOrderOnMainPlusTwo(area: BTRect) {
        let frames = TabbedLayoutState(preset: .focus).frames(in: area).values.sorted {
            $0.minY == $1.minY ? $0.minX < $1.minX : $0.minY < $1.minY
        }
        let frame = BTRect(x: area.minX + area.size.width * 0.35, y: area.minY + area.size.height * 0.3125,
                           width: area.size.width * 0.3, height: area.size.height * 0.375)
        let three = (0..<3).map { window("w\($0)", frame) }
        #expect(assign(three, frames) == ["w0", "w1", "w2"])
        #expect(assign(three.reversed(), frames) == ["w0", "w1", "w2"])
        // The main pane is the largest, so the extra windows overlap it most.
        let five = (0..<5).map { window("w\($0)", frame) }
        #expect(assign(five.reversed(), frames) == ["w0+w3+w4", "w1", "w2"])
        let exact = (0..<3).map { window("w\($0)", .init(x: 350, y: 250, width: 300, height: 300)) }
        #expect(assign(exact.reversed(), panes(.focus)) == ["w0", "w1", "w2"])
    }

    /// Evenly split panes give scores that are equal in exact arithmetic but
    /// differ by floating-point noise when summed. Quantized terms tie
    /// exactly, so window reading order decides, as documented.
    @Test func equalScoresTieExactlyDespiteFloatingPointNoise() {
        let main = BTRect(x: 0, y: 25, width: 1148.4, height: 1055)
        let topRight = BTRect(x: 1154, y: 25, width: 765.6, height: 524.5)
        let bottomRight = BTRect(x: 1154, y: 555.5, width: 765.6, height: 524.5)
        let w1 = window("w1", .init(x: 0, y: 25, width: 960, height: 527))
        let w0 = window("w0", .init(x: 0, y: 553, width: 960, height: 527))
        let w2 = window("w2", .init(x: 961, y: 25, width: 959, height: 1055))
        #expect(assign([w0, w1, w2], [main, topRight, bottomRight]) == ["w1", "w2", "w0"])
    }

    @Test func boundedSearchHandlesManyWindowsAndFallsBackAboveFourPanes() {
        let members = (0..<10_000).map {
            window("w\($0)", .init(x: 350, y: Double($0), width: 300, height: 300))
        }
        let result = TabbedEntryAssignment.assign(windows: Array(members.reversed()), paneFrames: panes(.grid))
        let tabs = result.panes.flatMap { $0 }
        #expect(tabs.count == members.count)
        #expect(Set(tabs).count == members.count)
        // Above four panes the members follow window reading order.
        let fallback = TabbedEntryAssignment.assign(windows: Array(members.reversed()),
                                                    paneFrames: Array(repeating: bounds, count: 5))
        #expect(fallback.primary == members.prefix(5).map(\.id))
        #expect(fallback.panes.flatMap { $0 }.count == members.count)
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
            // About a third of the windows coincide with the previous one, so
            // exact ties reach the rank tie-break.
            var previous: BTRect?
            let windows = (0..<seed.next(7)).map { index in
                let frame = previous.flatMap { seed.next(3) == 0 ? $0 : nil }
                    ?? BTRect(x: Double(seed.next(1400) - 200), y: Double(seed.next(1200) - 200),
                              width: Double(1 + seed.next(700)), height: Double(1 + seed.next(600)))
                previous = frame
                return window("w\(index)", frame)
            }.sorted {
                if $0.frame.minY != $1.frame.minY { return $0.frame.minY < $1.frame.minY }
                if $0.frame.minX != $1.frame.minX { return $0.frame.minX < $1.frame.minX }
                return $0.id < $1.id
            }
            let count = min(windows.count, frames.count)
            // One entry per pane: a window rank, or `empty` for an empty pane.
            // Any `frames.count - count` panes may stay empty.
            let empty = windows.count
            var bestRanks: [Int] = [], bestOverlap = -1, bestDistance = Int.max
            func visit(_ ranks: [Int]) {
                if ranks.count < frames.count {
                    let filled = ranks.filter { $0 != empty }.count
                    if ranks.count - filled < frames.count - count { visit(ranks + [empty]) }
                    if filled < count {
                        for rank in windows.indices where !ranks.contains(rank) { visit(ranks + [rank]) }
                    }
                    return
                }
                // Exact integer totals of the quantized terms: independent of
                // the order in which any implementation adds them.
                var overlap = 0, distance = 0
                for (pane, rank) in ranks.enumerated() where rank != empty {
                    overlap += Int(quantizedOverlap(windows[rank].frame, frames[pane]))
                    distance += Int(quantizedDistance(windows[rank].frame, frames[pane]))
                }
                if overlap > bestOverlap || (overlap == bestOverlap &&
                    (distance < bestDistance || (distance == bestDistance && ranks.lexicographicallyPrecedes(bestRanks)))) {
                    bestRanks = ranks; bestOverlap = overlap; bestDistance = distance
                }
            }
            visit([])
            // Extra windows: most overlap, then nearest centre, then panes in turn.
            var tabs = bestRanks.map { $0 == empty ? [String]() : [windows[$0].id.rawValue] }
            for (turn, rank) in windows.indices.filter({ !bestRanks.contains($0) }).enumerated() {
                let order = frames.indices.map { (turn + $0) % frames.count }
                let pane = order.max { lhs, rhs in
                    let a = quantizedOverlap(windows[rank].frame, frames[lhs])
                    let b = quantizedOverlap(windows[rank].frame, frames[rhs])
                    if a != b { return a < b }
                    let p = quantizedDistance(windows[rank].frame, frames[lhs])
                    let q = quantizedDistance(windows[rank].frame, frames[rhs])
                    if p != q { return p > q }
                    return order.firstIndex(of: lhs)! > order.firstIndex(of: rhs)!
                }!
                tabs[pane].append(windows[rank].id.rawValue)
            }
            let expected = tabs.map { $0.isEmpty ? "-" : $0.joined(separator: "+") }
            #expect(assign(Array(windows.reversed()), frames) == expected, "oracle case \(example)")
        }
    }

    private func quantizedOverlap(_ window: BTRect, _ pane: BTRect) -> Double {
        ((window.intersection(pane)?.area ?? 0) * 1024).rounded()
    }

    private func quantizedDistance(_ window: BTRect, _ pane: BTRect) -> Double {
        let dx = window.midX - pane.midX, dy = window.midY - pane.midY
        return ((dx * dx + dy * dy) * 1024).rounded()
    }
}
