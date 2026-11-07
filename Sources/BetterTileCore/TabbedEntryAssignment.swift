import Foundation

/// Chooses pane members, then overflow tabs, for One per pane entry.
public enum TabbedEntryAssignment {
    public struct Result: Equatable, Sendable {
        /// One entry per pane, in `paneFrames` order. `nil` leaves that pane
        /// empty, which happens only when there are fewer windows than panes.
        public var primary: [WindowID?]
        /// Windows that join the panes as extra tabs, in window reading order.
        public var overflow: [WindowID]
        /// Each pane's tabs in `paneFrames` order: its primary member first,
        /// then its extra tabs in window reading order.
        public var panes: [[WindowID]]
    }

    /// Scores are quantized to 1/1024 pt² before summing. Integer-valued
    /// sums are exact at these magnitudes, so mathematically equal layouts,
    /// such as evenly split panes, tie exactly and reach the rank tie-break.
    static func quantized(_ value: Double) -> Double { (value * 1024).rounded() }

    static func overlap(_ window: BTRect, _ pane: BTRect) -> Double {
        quantized(window.intersection(pane)?.area ?? 0)
    }

    static func distance(_ window: BTRect, _ pane: BTRect) -> Double {
        let dx = window.midX - pane.midX, dy = window.midY - pane.midY
        return quantized(dx * dx + dy * dy)
    }

    /// `paneFrames` must be in screen reading order. Every pane can take a
    /// window, so with fewer windows than panes the empty panes may be
    /// anywhere. Maximize total overlap, then minimize total squared centre
    /// distance. Equal scores choose the lexicographically first window
    /// reading-order ranks in pane order (top edge, left edge, then ID); an
    /// empty pane ranks after every window, so ties leave empty panes last.
    /// Each extra window joins the pane it overlaps most, then the nearest by
    /// centre distance. Remaining ties keep the panes-in-turn order: the
    /// i-th extra window prefers pane i mod k, then the panes after it.
    ///
    /// A bit-mask dynamic program considers each window once, including the
    /// choice to leave it for overflow. Presets have at most four panes:
    /// at most n * k * 2^k transitions (64n), O(2^k * k) working storage,
    /// plus O(n log n) sorting and O(n) output. Each rank vector has at most
    /// four elements. More than four panes falls back to window reading order
    /// rather than allowing an unbounded exponential search.
    public static func assign(windows: [WindowSnapshot], paneFrames: [BTRect]) -> Result {
        let windows = windows.sorted {
            if $0.frame.minY != $1.frame.minY { return $0.frame.minY < $1.frame.minY }
            if $0.frame.minX != $1.frame.minX { return $0.frame.minX < $1.frame.minX }
            return $0.id < $1.id
        }
        let panes = paneFrames.count
        let count = min(windows.count, panes)
        func result(primary: [Int?]) -> Result {
            let chosen = Set(primary.compactMap { $0 })
            let overflow = windows.indices.filter { !chosen.contains($0) }
            var tabs = primary.map { $0.map { [windows[$0].id] } ?? [] }
            for (turn, rank) in overflow.enumerated() where panes > 0 {
                let frame = windows[rank].frame
                let pane = (0..<panes).map { (turn + $0) % panes }.min { lhs, rhs in
                    let a = overlap(frame, paneFrames[lhs]), b = overlap(frame, paneFrames[rhs])
                    if a != b { return a > b }
                    return distance(frame, paneFrames[lhs]) < distance(frame, paneFrames[rhs])
                }!
                tabs[pane].append(windows[rank].id)
            }
            return Result(primary: primary.map { $0.map { windows[$0].id } },
                          overflow: overflow.map { windows[$0].id }, panes: tabs)
        }
        func readingOrder() -> Result { result(primary: (0..<panes).map { $0 < count ? $0 : nil }) }
        guard count > 0, panes <= 4 else { return readingOrder() }
        let full = (1 << panes) - 1
        var best = Array<Assignment?>(repeating: nil, count: full + 1)
        best[0] = Assignment(overlap: 0, distance: 0, ranks: Array(repeating: windows.count, count: panes))
        for (rank, window) in windows.enumerated() {
            let overlaps = paneFrames.map { overlap(window.frame, $0) }
            let distances = paneFrames.map { distance(window.frame, $0) }
            // A destination mask is larger than its source. Descending masks
            // ensure a window cannot be used twice in this iteration. Leaving
            // the existing state untouched is the overflow choice.
            for mask in stride(from: full - 1, through: 0, by: -1) {
                guard let prior = best[mask], mask.nonzeroBitCount < count else { continue }
                for pane in 0..<panes where mask & (1 << pane) == 0 {
                    var candidate = prior
                    candidate.overlap += overlaps[pane]
                    candidate.distance += distances[pane]
                    candidate.ranks[pane] = rank
                    let destination = mask | (1 << pane)
                    if best[destination].map({ candidate.precedes($0) }) ?? true {
                        best[destination] = candidate
                    }
                }
            }
        }
        // Every pane can take every window, even with no overlap, so some
        // state fills exactly `count` panes.
        let filled = (0...full).filter { $0.nonzeroBitCount == count }.compactMap { best[$0] }
        guard let assignment = filled.min(by: { $0.precedes($1) }) else { return readingOrder() }
        return result(primary: assignment.ranks.map { $0 < windows.count ? $0 : nil })
    }

    private struct Assignment {
        var overlap: Double
        var distance: Double
        var ranks: [Int]

        func precedes(_ other: Self) -> Bool {
            if overlap != other.overlap { return overlap > other.overlap }
            if distance != other.distance { return distance < other.distance }
            return ranks.lexicographicallyPrecedes(other.ranks)
        }
    }
}
