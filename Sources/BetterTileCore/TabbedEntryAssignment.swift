import Foundation

/// Orders primary pane members, then overflow tabs, for fresh non-Adaptive entry.
public enum TabbedEntryAssignment {
    /// `paneFrames` must be in screen reading order. Only the first
    /// min(windows, panes) panes participate, so empty panes remain last.
    /// Maximize total overlap, then minimize total squared centre distance.
    /// Equal scores choose the lexicographically first window reading-order
    /// ranks in pane order (top edge, left edge, then ID).
    ///
    /// A bit-mask dynamic program considers each window once, including the
    /// choice to leave it for overflow. Presets have at most four panes:
    /// at most n * k * 2^k transitions (64n), O(2^k * k) working storage,
    /// plus O(n log n) sorting and O(n) output. Each rank vector has at most
    /// four elements. More than four panes falls back to window reading order
    /// rather than allowing an unbounded exponential search.
    public static func orderedWindowIDs(windows: [WindowSnapshot], paneFrames: [BTRect]) -> [WindowID] {
        let windows = windows.sorted {
            if $0.frame.minY != $1.frame.minY { return $0.frame.minY < $1.frame.minY }
            if $0.frame.minX != $1.frame.minX { return $0.frame.minX < $1.frame.minX }
            return $0.id < $1.id
        }
        let count = min(windows.count, paneFrames.count)
        guard count > 0, paneFrames.count <= 4 else { return windows.map(\.id) }
        let full = (1 << count) - 1
        var best = Array<Assignment?>(repeating: nil, count: full + 1)
        best[0] = Assignment(overlap: 0, distance: 0, ranks: Array(repeating: windows.count, count: count))
        for (rank, window) in windows.enumerated() {
            let overlaps = paneFrames.prefix(count).map { window.frame.intersection($0)?.area ?? 0 }
            let distances = paneFrames.prefix(count).map {
                let dx = window.frame.midX - $0.midX, dy = window.frame.midY - $0.midY
                return dx * dx + dy * dy
            }
            // A destination mask is larger than its source. Descending masks
            // ensure a window cannot be used twice in this iteration. Leaving
            // the existing state untouched is the overflow choice.
            for mask in stride(from: full - 1, through: 0, by: -1) {
                guard let prior = best[mask] else { continue }
                for pane in 0..<count where mask & (1 << pane) == 0 {
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
        // Every participating pane can take every window, even with no overlap.
        guard let assignment = best[full] else { return windows.map(\.id) }
        let primary = Set(assignment.ranks)
        return assignment.ranks.map { windows[$0].id }
            + windows.enumerated().filter { !primary.contains($0.offset) }.map { $0.element.id }
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
