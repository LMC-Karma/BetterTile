import Foundation

/// A provisional focused-window snap. Revalidate its target after every fit.
public struct TabbedSnapPlan: Sendable {
    public let state: TabbedLayoutState
    public let sourceWindowID: WindowID
    public let destinationPaneID: UUID
    public let targetFrame: BTRect
    /// Selected-window placements for preview; hidden tabs are applied later.
    public let placements: [Placement]
    fileprivate let bounds: BTRect

    public func preservesTarget(in state: TabbedLayoutState, within bounds: BTRect) -> Bool {
        bounds.approximatelyEquals(self.bounds, tolerance: 0.001)
            && state.pane(containing: sourceWindowID)?.id == destinationPaneID
            && state.pane(containing: sourceWindowID)?.selected == sourceWindowID
            && state.logicalFrames(in: bounds)[destinationPaneID]?.approximatelyEquals(targetFrame, tolerance: 0.001) == true
    }
}

/// Joins an exact pane or assigns retained panes to a deterministic remainder.
/// An infeasible subdivision is refused; this does not search every tiling.
public enum TabbedSnapPlanner {
    public static func plan(sourceWindowID: WindowID, action: WindowAction, state: TabbedLayoutState,
                            windows: [WindowSnapshot], in bounds: BTRect) -> TabbedSnapPlan? {
        guard valid(bounds), BentoDropPlanner.partitionActions.contains(action), let partition = action.partition,
              state.windowIDs.contains(sourceWindowID) || state.floatingWindowIDs.contains(sourceWindowID),
              let source = windows.first(where: { $0.id == sourceWindowID }),
              source.isEligible, source.constraints.isResizable, !source.isFloating,
              valid(source.frame) else { return nil }
        let target = partition.frame(in: bounds)
        let logicalFrames = state.logicalFrames(in: bounds)
        if let destination = state.panes.first(where: {
            logicalFrames[$0.id]?.approximatelyEquals(target, tolerance: 0.001) == true
        }) {
            var next = state
            next.move(sourceWindowID, to: destination.id)
            return finish(next, source: sourceWindowID, target: target, windows: windows, bounds: bounds)
        }
        guard state.panes.count < TabbedLayoutState.maximumPaneCount else { return nil }
        var next = state
        next.float(sourceWindowID)
        let panes = next.panes
        let geometry = BentoDropGeometry(tolerance: 0.001, clampSplitWeights: false)
        var regions = geometry.residualRegions(around: target, in: bounds)
        func ordered(_ a: BTRect, _ b: BTRect) -> Bool {
            (a.area, -a.minY, -a.minX) > (b.area, -b.minY, -b.minX)
        }
        while regions.count < panes.count {
            regions.sort(by: ordered)
            guard !regions.isEmpty else { return nil }
            regions.append(contentsOf: geometry.split(regions.removeFirst()))
        }
        regions.sort(by: ordered)
        guard regions.count + 1 <= TabbedLayoutState.maximumPaneCount else { return nil }
        let slots = regions.map { RegionNode(frame: $0, node: .vacant(UUID())) }
        guard let root = geometry.buildTree(items: [RegionNode(frame: target, node: .leaf(sourceWindowID))] + slots,
                                             bounds: bounds) else { return nil }
        // Normalize first: nested same-axis splits change where gaps apply.
        var layout = BentoLayoutState(root: root, floatingWindowIDs: next.floatingWindowIDs, metrics: state.layout.metrics)
        let decorated = layout.vacantFrames(in: bounds)
        let slotIDs = slots.compactMap { if case let .vacant(id) = $0.node { id } else { nil } }
        guard let assignment = allocate(panes: panes, regions: regions, decorated: slotIDs.compactMap { decorated[$0] },
                                        oldFrames: logicalFrames, windows: windows, metrics: layout.metrics, bounds: bounds)
        else { return nil }
        let replacements = Dictionary(uniqueKeysWithValues: zip(slotIDs, assignment).map { id, index in
            (id, index.map { panes[$0].selected.map(BentoNode.leaf) ?? .vacant(panes[$0].id) } ?? .vacant(id))
        })
        func replace(_ node: BentoNode) -> BentoNode {
            switch node {
            case let .vacant(id): return replacements[id] ?? node
            case var .partition(partition):
                partition.children = partition.children.map(replace)
                return .partition(partition)
            case .leaf: return node
            }
        }
        layout.root = layout.root.map(replace)
        layout.floatingWindowIDs.remove(sourceWindowID)
        next.synchronize(with: layout)
        next.select(sourceWindowID)
        guard Set(state.panes.map(\.id)).isSubset(of: Set(next.panes.map(\.id))),
              next.windowIDs == state.windowIDs.union([sourceWindowID]),
              next.floatingWindowIDs == state.floatingWindowIDs.subtracting([sourceWindowID]) else { return nil }
        return finish(next, source: sourceWindowID, target: target, windows: windows, bounds: bounds)
    }

    /// A fixed subdivision keeps the search bounded at 11 retained panes.
    /// Each remaining-pane subset is solved once, rather than permuting panes.
    private static func allocate(panes: [TabbedPane], regions: [BTRect], decorated: [BTRect],
                                 oldFrames: [UUID: BTRect], windows: [WindowSnapshot],
                                 metrics: BentoLayoutMetrics, bounds: BTRect) -> [Int?]? {
        guard decorated.count == regions.count else { return nil }
        let snapshots = Dictionary(windows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        func vacancyFits(_ frame: BTRect) -> Bool {
            frame.size.width + 0.001 >= metrics.vacantMinimumSize.width
                && frame.size.height + 0.001 >= metrics.vacantMinimumSize.height
        }
        let fits = decorated.map { frame in
            panes.map { pane in
                guard let selected = pane.selected else { return vacancyFits(frame) }
                guard let window = snapshots[selected], window.isEligible, window.constraints.isResizable else { return false }
                let content = metrics.contentFrame(forPane: frame)
                let minimum = window.constraints.minimumSize
                return minimum.width.isFinite && minimum.height.isFinite && minimum.width >= 0 && minimum.height >= 0
                    && content.size.width + 0.001 >= minimum.width && content.size.height + 0.001 >= minimum.height
            }
        }
        let costs = regions.map { region in
            panes.map { pane -> Double in
                guard let old = oldFrames[pane.id] else { return .infinity }
                return (pow(old.midX - region.midX, 2) + pow(old.midY - region.midY, 2)
                        + abs(old.area - region.area)) / max(1, bounds.area)
            }
        }
        struct Key: Hashable { var slot: Int; var mask: Int }
        var scores: [Key: Double] = [:]
        var choices: [Key: Int] = [:]
        func solve(_ slot: Int, _ mask: Int) -> Double {
            if slot == regions.count { return mask == 0 ? 0 : .infinity }
            let key = Key(slot: slot, mask: mask)
            if let cached = scores[key] { return cached }
            var best = Double.infinity
            for index in panes.indices where mask & (1 << index) != 0 && fits[slot][index] {
                let score = costs[slot][index] + solve(slot + 1, mask & ~(1 << index))
                if score < best { best = score; choices[key] = index }
            }
            if regions.count - slot > mask.nonzeroBitCount, vacancyFits(decorated[slot]) {
                let score = solve(slot + 1, mask)
                if score < best { best = score; choices[key] = -1 }
            }
            scores[key] = best
            return best
        }
        var mask = (1 << panes.count) - 1
        guard solve(0, mask).isFinite else { return nil }
        return regions.indices.map { slot in
            let index = choices[Key(slot: slot, mask: mask)]!
            if index < 0 { return nil }
            mask &= ~(1 << index)
            return index
        }
    }

    private static func finish(_ state: TabbedLayoutState, source: WindowID, target: BTRect,
                               windows: [WindowSnapshot], bounds: BTRect) -> TabbedSnapPlan? {
        guard let next = try? state.fittingMinimumWidths(in: bounds, windows: windows),
              let destination = next.paneID(containing: source) else { return nil }
        let selected = Set(next.selectedWindowIDs)
        let snapshots = Dictionary(windows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        guard selected.allSatisfy({ snapshots[$0]?.isEligible == true && snapshots[$0]?.constraints.isResizable == true }),
              let all = try? next.placements(in: bounds, windows: windows) else { return nil }
        let placements = all.filter { selected.contains($0.windowID) }
        guard placements.count == selected.count, placements.allSatisfy({ valid($0.frame) }) else { return nil }
        let plan = TabbedSnapPlan(state: next, sourceWindowID: source, destinationPaneID: destination,
                                  targetFrame: target, placements: placements, bounds: bounds)
        return plan.preservesTarget(in: next, within: bounds) ? plan : nil
    }

    private static func valid(_ frame: BTRect) -> Bool {
        [frame.minX, frame.minY, frame.maxX, frame.maxY, frame.size.width, frame.size.height].allSatisfy(\.isFinite)
            && frame.size.width > 0 && frame.size.height > 0
    }
}

extension TabbedLayoutState {
    /// Pane regions before gaps and the tab-strip reserve are applied.
    public func logicalFrames(in bounds: BTRect) -> [UUID: BTRect] {
        var logical = layout
        logical.metrics = .gapless
        let occupied = logical.paneFrames(in: bounds)
        let vacant = logical.vacantFrames(in: bounds)
        return Dictionary(uniqueKeysWithValues: panes.compactMap { pane in
            (pane.selected.flatMap { occupied[$0] } ?? vacant[pane.id]).map { (pane.id, $0) }
        })
    }
}
