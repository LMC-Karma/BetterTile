import Foundation

/// Why a tab's window cannot be shown in its pane, so a message can name
/// what is in the way instead of a general failure.
public enum TabbedFitProblem: Equatable, Sendable {
    /// The window's minimum size, with its tab strip, is larger than the
    /// display's work area.
    case largerThanDisplay
    /// The other panes could make room, but a locked divider keeps this
    /// pane from growing.
    case lockedDivider
    /// The selected windows of the panes that would have to shrink below
    /// their own minimum sizes. Empty when only empty panes are in the way.
    case neighbors([WindowID])
}

extension TabbedLayoutState {
    /// Finds why `windowID`, selected in its pane, leaves no layout that meets
    /// every selected window's minimum size. Nil when one exists.
    public func fitProblem(showing windowID: WindowID, in bounds: BTRect, windows: [WindowSnapshot]) -> TabbedFitProblem? {
        fitFailure(showing: windowID, in: bounds, windows: windows)?.problem
    }

    /// The fit problem and whether it is on the width axis: false means the
    /// window is too tall.
    public func fitFailure(showing windowID: WindowID, in bounds: BTRect,
                           windows: [WindowSnapshot]) -> (problem: TabbedFitProblem, tooWide: Bool)? {
        var state = self
        state.select(windowID)
        guard state.selectedWindowIDs.contains(windowID), let root = state.layout.root,
              bounds.size.width > 0, bounds.size.height > 0 else { return nil }
        let tolerance = 0.001
        let metrics = state.layout.metrics
        var minimums: [WindowID: BTSize] = [:]
        for window in windows {
            var size = window.constraints.minimumSize
            // A fixed-size window needs its whole size, as when fitting.
            if !window.constraints.isResizable {
                size = BTSize(width: max(size.width, window.frame.size.width),
                              height: max(size.height, window.frame.size.height))
            }
            size.height += metrics.contentTopInset
            minimums[window.id] = size
        }
        let defaultMinimum = WindowConstraints().minimumSize
        func minimum(_ id: WindowID) -> BTSize {
            minimums[id] ?? BTSize(width: defaultMinimum.width, height: defaultMinimum.height + metrics.contentTopInset)
        }
        let target = minimum(windowID)
        if target.width > bounds.size.width + tolerance { return (.largerThanDisplay, true) }
        if target.height > bounds.size.height + tolerance { return (.largerThanDisplay, false) }
        let gap = metrics.paneGap
        func extent(_ size: BTSize, _ axis: SplitAxis) -> Double { axis == .vertical ? size.width : size.height }
        func minimumExtent(_ node: BentoNode, _ axis: SplitAxis) -> Double {
            switch node {
            case let .leaf(id): return extent(minimum(id), axis)
            case .vacant: return extent(metrics.vacantMinimumSize, axis)
            case let .partition(partition):
                let values = partition.children.map { minimumExtent($0, axis) }
                return partition.axis == axis
                    ? values.reduce(0, +) + gap * Double(max(0, values.count - 1))
                    : values.max() ?? 0
            }
        }
        /// The windows that set a node's minimum extent on an axis. In a
        /// stack across the axis only the largest minimum counts: a narrower
        /// window beside it would not need to shrink below its own minimum.
        func binding(_ node: BentoNode, _ axis: SplitAxis) -> [WindowID] {
            switch node {
            case let .leaf(id): return [id]
            case .vacant: return []
            case let .partition(partition):
                if partition.axis == axis { return partition.children.flatMap { binding($0, axis) } }
                let largest = partition.children.map { minimumExtent($0, axis) }.max() ?? 0
                return partition.children.filter { minimumExtent($0, axis) >= largest - tolerance }
                    .flatMap { binding($0, axis) }
            }
        }

        /// `available` is the most room the node can get on each axis.
        func check(_ node: BentoNode, available: BTSize) -> (problem: TabbedFitProblem, tooWide: Bool)? {
            guard case let .partition(partition) = node,
                  let index = partition.children.firstIndex(where: { $0.windowIDs.contains(windowID) })
            else { return nil }
            let axis = partition.axis
            let tooWide = axis == .vertical
            let children = partition.children
            let room = extent(available, axis) - gap * Double(children.count - 1)
            let needs = children.map { minimumExtent($0, axis) }
            var others = children
            others.remove(at: index)
            // The others must give up `shortfall` below their minimums. A pane
            // must give some only if the rest together cannot cover it, even
            // by shrinking to nothing; when any could, all are named.
            let shortfall = needs.reduce(0, +) - room
            if shortfall > tolerance {
                let otherIndices = children.indices.filter { $0 != index }
                let othersNeed = otherIndices.reduce(0) { $0 + needs[$1] }
                let forced = otherIndices.filter { othersNeed - needs[$0] < shortfall - tolerance }
                let named = forced.isEmpty ? otherIndices : forced
                return (.neighbors(named.flatMap { binding(children[$0], axis) }), tooWide)
            }
            // Locked dividers fix the total size of each run between them.
            let locked = partition.boundaryIDs.indices.filter {
                partition.lockedBoundaryIDs.contains(partition.boundaryIDs[$0])
            }
            let start = locked.last { $0 < index }.map { $0 + 1 } ?? 0
            let end = locked.first { $0 >= index }.map { $0 + 1 } ?? children.count
            let run = start..<end
            let runRoom = run.reduce(0) { $0 + partition.ratios[$1] } * room
            let runNeeds = run.reduce(0) { $0 + needs[$1] }
            if run.count < children.count, runNeeds > runRoom + tolerance {
                return (.lockedDivider, tooWide)
            }
            let othersInRun = run.filter { $0 != index }.reduce(0) { $0 + needs[$1] }
            let childRoom = (run.count < children.count ? runRoom : room) - othersInRun
            let childAvailable = axis == .vertical
                ? BTSize(width: childRoom, height: available.height)
                : BTSize(width: available.width, height: childRoom)
            return check(children[index], available: childAvailable)
        }
        return check(BentoLayoutState.normalized(root), available: bounds.size)
    }
}
