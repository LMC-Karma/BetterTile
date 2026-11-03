// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 LMC-Karma

import Foundation

/// Minimum total squared centre distance in normalized work-area coordinates.
/// Whole-assignment totals within an absolute 1e-12 of the minimum are ties. They choose
/// the lexicographically smallest window-ID assignment in slot-ID order, with an unfilled
/// slot after real IDs. Integer tie vectors settle exact ties; a whole-total refinement
/// handles near-ties without an epsilon in the Hungarian potential comparisons.
enum SavedLayoutPositionMatching {
    private struct Cost: Comparable {
        var priorities: [Int]
        var distance: Double
        var ranks: [Int]
        static func < (lhs: Self, rhs: Self) -> Bool {
            // Infinity is the Hungarian sentinel, above every finite priority vector.
            if lhs.distance == .infinity { return false }
            if rhs.distance == .infinity { return true }
            if lhs.priorities != rhs.priorities { return lhs.priorities.lexicographicallyPrecedes(rhs.priorities) }
            if lhs.distance != rhs.distance { return lhs.distance < rhs.distance }
            return lhs.ranks.lexicographicallyPrecedes(rhs.ranks)
        }
        static func + (lhs: Self, rhs: Self) -> Self {
            .init(priorities: zip(lhs.priorities, rhs.priorities).map(+), distance: lhs.distance + rhs.distance, ranks: zip(lhs.ranks, rhs.ranks).map(+))
        }
        static func - (lhs: Self, rhs: Self) -> Self {
            .init(priorities: zip(lhs.priorities, rhs.priorities).map(-), distance: lhs.distance - rhs.distance, ranks: zip(lhs.ranks, rhs.ranks).map(-))
        }
    }
    /// Preferred edges contribute (-1, -oneHot(rank)); dummy edges contribute zero.
    /// Summing and comparing these integer vectors first maximizes matched preferences,
    /// then rank-0 matches, rank-1 matches, and so on. Distance and the slot-ID/window-ID
    /// tie vector follow. No scalar weighting can let distance outweigh a preference.
    static func assign(slots: [SavedLayoutSlot], windows: [SavedLayoutEligibleWindow],
                       targets: [String: NormalizedRect], in bounds: BTRect,
                       preferences: [String: [String]]? = nil,
                       fillPriorities: [String: [Int]] = [:],
                       slotOrder: [String]? = nil) -> [String: WindowID] {
        let order = Dictionary(uniqueKeysWithValues: (slotOrder ?? []).enumerated().map { ($0.element, $0.offset) })
        let rows = slots.sorted {
            if let a = order[$0.id], let b = order[$1.id], a != b { return a < b }
            return $0.id < $1.id
        }
        let columns = windows.sorted { $0.id < $1.id }
        guard !rows.isEmpty, !columns.isEmpty else { return [:] }
        let rankCount = preferences?.values.map(\.count).max() ?? 0
        let priorityCount = preferences == nil ? (fillPriorities.values.first?.count ?? 0) : rankCount + 1
        let n = rows.count, m = preferences == nil ? max(n, columns.count) : columns.count + n
        let costs = rows.enumerated().map { row, slot in
            (0..<m).map { column -> Cost in
                var cost = Cost(priorities: Array(repeating: 0, count: priorityCount), distance: 0,
                                ranks: Array(repeating: 0, count: n))
                cost.ranks[row] = min(column, columns.count)
                guard column < columns.count else { return cost }
                if let preferences {
                    guard let rank = preferences[slot.id]?.firstIndex(where: {
                        $0.caseInsensitiveCompare(columns[column].bundleID) == .orderedSame
                    }) else {
                        cost.priorities[0] = 1 // Worse than an unfilled slot; never returned.
                        return cost
                    }
                    cost.priorities[0] = -1
                    cost.priorities[rank + 1] = -1
                } else { cost.priorities = fillPriorities[slot.id] ?? cost.priorities }
                cost.distance = distance(columns[column], to: targets[slot.id] ?? .init(x: 0, y: 0, width: 1, height: 1), in: bounds)
                return cost
            }
        }
        let selected = canonicalAssignment(costs, realColumnCount: columns.count, optional: preferences != nil)
        var assignments: [String: WindowID] = [:]
        for row in rows.indices where selected[row] < columns.count {
            if preferences != nil && costs[row][selected[row]].priorities[0] != -1 { continue }
            assignments[rows[row].id] = columns[selected[row]].id
        }
        return assignments
    }

    static func distance(_ window: SavedLayoutEligibleWindow, to target: NormalizedRect, in bounds: BTRect) -> Double {
        let frame = window.matchingFrame ?? NormalizedRect(frame: window.frame, in: bounds)
        let dx = frame.x + frame.width / 2 - target.x - target.width / 2
        let dy = frame.y + frame.height / 2 - target.y - target.height / 2
        let result = dx * dx + dy * dy
        return result.isFinite ? result : Double.greatestFiniteMagnitude / 1_000_000
    }

    private static func minimumAssignment(_ costs: [[Cost]], realColumnCount: Int? = nil, optional: Bool = false,
                                          potentials: (([Cost], [Cost]) -> Void)? = nil) -> [Int] {
        // When slots outnumber windows, transpose the real edges instead of solving
        // dozens of interchangeable dummy columns. The unfilled-slot cost is a
        // constant baseline; each real edge contributes its difference from it.
        if let real = realColumnCount, real > 0, real < costs.count, costs[0].count > real {
            let baseline = costs.map { $0[real] }
            let zero = baseline[0] - baseline[0]
            let transposed = (0..<real).map { column in
                costs.indices.map { costs[$0][column] - baseline[$0] }
                    + Array(repeating: zero, count: optional ? real : 0)
            }
            let selected = minimumAssignment(transposed, potentials: potentials.map { receive in
                { u, v in
                    let rows = costs.indices.map { baseline[$0] + v[$0] }
                    let columns = (0..<costs[0].count).map { $0 < real ? u[$0] : zero }
                    receive(rows, columns)
                }
            })
            var result = Array(repeating: -1, count: costs.count)
            for column in 0..<real where selected[column] < costs.count { result[selected[column]] = column }
            var dummy = real
            for row in result.indices where result[row] == -1 { result[row] = dummy; dummy += 1 }
            return result
        }
        // Rectangular Hungarian assignment. Dummy columns represent unfilled slots; their
        // fixed count preserves maximum matching before minimizing distance.
        let n = costs.count, m = costs.first?.count ?? 0
        guard n > 0 else { return [] }
        let zero = Cost(priorities: Array(repeating: 0, count: costs[0][0].priorities.count), distance: 0, ranks: costs[0][0].ranks.map { _ in 0 })
        let infinity = Cost(priorities: zero.priorities, distance: .infinity, ranks: zero.ranks)
        var u = Array(repeating: zero, count: n + 1), v = Array(repeating: zero, count: m + 1)
        var p = Array(repeating: 0, count: m + 1), way = p
        for row in 1...n {
            p[0] = row
            var column = 0
            var minimum = Array(repeating: infinity, count: m + 1)
            var used = Array(repeating: false, count: m + 1)
            repeat {
                used[column] = true
                let currentRow = p[column]
                var delta = infinity
                var next = 0
                for candidate in 1...m where !used[candidate] {
                    let ranked = costs[currentRow - 1][candidate - 1]
                    let cost = ranked - u[currentRow] - v[candidate]
                    if cost < minimum[candidate] { minimum[candidate] = cost; way[candidate] = column }
                    if minimum[candidate] < delta { delta = minimum[candidate]; next = candidate }
                }
                for candidate in 0...m {
                    if used[candidate] { u[p[candidate]] = u[p[candidate]] + delta; v[candidate] = v[candidate] - delta }
                    else { minimum[candidate] = minimum[candidate] - delta }
                }
                column = next
            } while p[column] != 0
            repeat {
                let previous = way[column]
                p[column] = p[previous]
                column = previous
            } while column != 0
        }
        var result = Array(repeating: 0, count: n)
        for column in 1...m where p[column] != 0 { result[p[column] - 1] = column - 1 }
        potentials?(Array(u.dropFirst()), Array(v.dropFirst()))
        return result
    }

    private static func canonicalAssignment(_ costs: [[Cost]], realColumnCount: Int, optional: Bool) -> [Int] {
        var rowPotentials: [Cost] = [], columnPotentials: [Cost] = []
        var selected = minimumAssignment(costs, realColumnCount: realColumnCount, optional: optional) {
            rowPotentials = $0; columnPotentials = $1
        }
        let zero = Cost(priorities: costs[0][0].priorities.map { _ in 0 }, distance: 0,
                        ranks: costs[0][0].ranks.map { _ in 0 })
        func total(_ columns: [Int]) -> Cost {
            columns.enumerated().reduce(zero) { $0 + costs[$1.offset][$1.element] }
        }
        let optimum = total(selected)
        let ceiling = optimum.distance + 1e-12
        var prefix: [Int] = [], available = Array(costs[0].indices)
        for row in costs.indices {
            for column in available {
                if column == selected[row] { break }
                // Hungarian dual potentials bound any assignment containing this edge.
                // Its reduced cost is a lower bound on the excess over the optimum.
                let reduced = costs[row][column] - rowPotentials[row] - columnPotentials[column]
                if zero.priorities.lexicographicallyPrecedes(reduced.priorities) ||
                    (reduced.priorities == zero.priorities && reduced.distance > 1e-12 + 1e-15) { continue }
                let remaining = available.filter { $0 != column }
                // Relax column uniqueness for a cheap lower bound, but keep every
                // priority component. A distance-only bound can discard a better rank.
                let fixed = prefix.enumerated().reduce(zero) { $0 + costs[$1.offset][$1.element] }
                    + costs[row][column]
                let lower = (row + 1..<costs.count).reduce(fixed) { sum, index in
                    sum + remaining.map { costs[index][$0] }.min()!
                }
                if optimum.priorities.lexicographicallyPrecedes(lower.priorities) ||
                    (lower.priorities == optimum.priorities && lower.distance > ceiling + 1e-15) { continue }
                let realRemaining = remaining.filter { $0 < realColumnCount }
                if let dummy = remaining.first(where: { $0 >= realColumnCount }),
                   realRemaining.count < costs.count - row - 1 {
                    // Also bound the number of real edges. Otherwise 64 rows can each
                    // claim the same one of 16 windows in the relaxed lower bound.
                    var bounded = fixed
                    var differences: [Cost] = []
                    for index in row + 1..<costs.count {
                        let baseline = costs[index][dummy]
                        bounded = bounded + baseline
                        if let best = realRemaining.map({ costs[index][$0] }).min() {
                            differences.append(best - baseline)
                        }
                    }
                    for delta in differences.sorted().prefix(realRemaining.count) {
                        if !optional || delta < zero { bounded = bounded + delta }
                    }
                    if optimum.priorities.lexicographicallyPrecedes(bounded.priorities) ||
                        (bounded.priorities == optimum.priorities && bounded.distance > ceiling + 1e-15) { continue }
                }
                let suffix = (row + 1..<costs.count).map { index in remaining.map { costs[index][$0] } }
                let completion = minimumAssignment(suffix, realColumnCount: remaining.filter { $0 < realColumnCount }.count, optional: optional)
                let candidate = prefix + [column] + completion.map { remaining[$0] }
                let sum = total(candidate)
                if sum.priorities == optimum.priorities && sum.distance <= ceiling {
                    selected = candidate; break
                }
            }
            prefix.append(selected[row])
            available.removeAll { $0 == selected[row] }
        }
        return selected
    }
}
