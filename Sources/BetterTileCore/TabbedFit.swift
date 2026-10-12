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
        if target.width > bounds.size.width + tolerance || target.height > bounds.size.height + tolerance {
            return .largerThanDisplay
        }
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
        func selectedWindows(in nodes: [BentoNode]) -> [WindowID] { nodes.flatMap(\.windowIDs) }

        /// `available` is the most room the node can get on each axis.
        func check(_ node: BentoNode, available: BTSize) -> TabbedFitProblem? {
            guard case let .partition(partition) = node,
                  let index = partition.children.firstIndex(where: { $0.windowIDs.contains(windowID) })
            else { return nil }
            let axis = partition.axis
            let children = partition.children
            let room = extent(available, axis) - gap * Double(children.count - 1)
            let needs = children.map { minimumExtent($0, axis) }
            var others = children
            others.remove(at: index)
            if needs.reduce(0, +) > room + tolerance {
                return .neighbors(selectedWindows(in: others))
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
                return .lockedDivider
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
