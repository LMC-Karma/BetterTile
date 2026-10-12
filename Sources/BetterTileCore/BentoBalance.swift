import Foundation

/// Gives the panes of each Bento partition equal shares, as close as
/// minimum sizes allow. A pane that cannot shrink to an equal share keeps
/// its minimum, and the panes beside it share the rest equally. A locked
/// divider stays where it is; each side of it is balanced on its own.
public struct BentoBalancer: Sendable {
    public var tolerance: Double

    public init(tolerance: Double = 0.001) {
        self.tolerance = max(0, tolerance)
    }

    /// Returns nil when the minimum sizes cannot be met; the caller then
    /// keeps the layout it had.
    public func balance(
        state: BentoLayoutState,
        in bounds: BTRect,
        constraints: [WindowID: WindowConstraints] = [:]
    ) -> BentoLayoutState? {
        guard let root = state.root else { return state }
        let workingRoot = BentoLayoutState.normalized(root)
        let gap = state.metrics.paneGap
        let paneConstraints = state.metrics.paneConstraints(constraints, for: workingRoot.windowIDs)
        let vacantMinimum = state.metrics.vacantMinimumSize

        func visit(_ node: BentoNode, rect: BTRect) -> BentoNode {
            guard case var .partition(partition) = node else { return node }
            let extent = partition.axis == .vertical ? rect.size.width : rect.size.height
            let available = extent - gap * Double(partition.children.count - 1)
            if available > 0 {
                let minimums = partition.children.map {
                    BentoTreeGeometry.minimumExtent($0, axis: partition.axis, constraints: paneConstraints, gap: gap,
                                                    vacantMinimum: vacantMinimum) / available
                }
                for run in unlockedRuns(of: partition) {
                    let share = run.reduce(0) { $0 + partition.ratios[$1] }
                    // A run whose minimums do not fit keeps its ratios for
                    // the solver to judge.
                    guard let shares = waterFill(run.map { minimums[$0] }, total: share) else { continue }
                    for (index, value) in zip(run, shares) { partition.ratios[index] = value }
                }
            }
            let rects = BentoTreeGeometry.partitionRects(partition, in: rect, gap: gap)
            partition.children = zip(partition.children, rects).map { visit($0.0, rect: $0.1) }
            return .partition(partition)
        }

        var result = state
        result.root = BentoLayoutState.normalized(visit(workingRoot, rect: bounds))
        return BentoConstraintSolver(tolerance: tolerance).solve(state: result, in: bounds, constraints: constraints)
    }

    /// Child indices between locked dividers.
    private func unlockedRuns(of partition: BentoPartition) -> [[Int]] {
        var runs: [[Int]] = [[]]
        for index in partition.children.indices {
            runs[runs.count - 1].append(index)
            if index < partition.boundaryIDs.count,
               partition.lockedBoundaryIDs.contains(partition.boundaryIDs[index]) {
                runs.append([])
            }
        }
        return runs.filter { !$0.isEmpty }
    }

    /// Splits `total` equally, except that no share falls below its
    /// minimum: a share that would is raised to it, and the others split
    /// what remains. Nil when the minimums exceed the total.
    private func waterFill(_ minimums: [Double], total: Double) -> [Double]? {
        guard minimums.reduce(0, +) <= total + tolerance else { return nil }
        var held = Set<Int>()
        while held.count < minimums.count {
            let free = minimums.indices.filter { !held.contains($0) }
            let share = (total - held.reduce(0) { $0 + minimums[$1] }) / Double(free.count)
            let raised = free.filter { minimums[$0] > share }
            if raised.isEmpty {
                return minimums.indices.map { held.contains($0) ? minimums[$0] : share }
            }
            held.formUnion(raised)
        }
        return minimums
    }
}
