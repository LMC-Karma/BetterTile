import Foundation

/// Tab membership for one Bento leaf. The pane identity survives selection and closure.
public struct BentoTabbedPane: Hashable, Sendable, Identifiable {
    public let id: UUID
    public fileprivate(set) var tabs: [WindowID]
    public fileprivate(set) var selected: WindowID?

    fileprivate init(id: UUID, tabs: [WindowID]) {
        self.id = id
        self.tabs = tabs
        self.selected = tabs.first
    }
}

/// A Bento tree supplies pane geometry; each leaf represents only its selected tab.
/// Hidden tabs remain in membership, outside the geometry and minimum-size solver.
public struct BentoTabbedLayoutState: Hashable, Sendable {
    public private(set) var layout: BentoLayoutState
    public private(set) var panes: [BentoTabbedPane]

    /// - Parameter contentTopInset: Space for the tab strip above each window.
    public init?(adopting layout: BentoLayoutState, contentTopInset: Double = 0) {
        var adopted = layout
        adopted.metrics.contentTopInset = BentoLayoutMetrics(contentTopInset: contentTopInset).contentTopInset
        var panes: [BentoTabbedPane] = []
        var windowIDs = Set<WindowID>()
        var paneIDs = Set<UUID>()
        func collect(_ node: BentoNode) -> Bool {
            switch node {
            case let .leaf(id):
                guard windowIDs.insert(id).inserted else { return false }
                panes.append(BentoTabbedPane(id: UUID(), tabs: [id]))
                return true
            case let .vacant(id):
                guard paneIDs.insert(id).inserted else { return false }
                panes.append(BentoTabbedPane(id: id, tabs: []))
                return true
            case let .partition(partition):
                return partition.children.allSatisfy(collect)
            }
        }
        if let root = adopted.root {
            guard collect(root) else { return nil }
        } else {
            let paneID = UUID()
            adopted.root = .vacant(paneID)
            panes.append(BentoTabbedPane(id: paneID, tabs: []))
        }
        guard windowIDs.isDisjoint(with: layout.floatingWindowIDs) else { return nil }
        self.layout = adopted
        self.panes = panes
    }

    /// Adds a tab to an existing pane and selects it. Returns false without changes
    /// if the pane is absent or the window already belongs to a pane.
    @discardableResult
    public mutating func add(_ id: WindowID, to paneID: UUID) -> Bool {
        guard let index = panes.firstIndex(where: { $0.id == paneID }),
              !panes.contains(where: { $0.tabs.contains(id) }) else { return false }
        let oldSelected = panes[index].selected
        guard replaceRepresentative(oldSelected, paneID: paneID, with: id) else { return false }
        panes[index].tabs.append(id)
        panes[index].selected = id
        layout.floatingWindowIDs.remove(id)
        return true
    }

    /// Selecting a tab changes one Bento leaf without moving a boundary.
    @discardableResult
    public mutating func select(_ id: WindowID) -> Bool {
        guard let index = panes.firstIndex(where: { $0.tabs.contains(id) }),
              let previous = panes[index].selected else { return false }
        if previous == id { return true }
        guard layout.replace(previous, with: id) else { return false }
        panes[index].selected = id
        return true
    }

    /// The last tab leaves a vacant leaf, preserving the pane and its boundaries.
    @discardableResult
    public mutating func remove(_ id: WindowID) -> Bool {
        guard let index = panes.firstIndex(where: { $0.tabs.contains(id) }),
              let tabIndex = panes[index].tabs.firstIndex(of: id) else { return false }
        if panes[index].selected == id {
            let replacement = panes[index].tabs.first(where: { $0 != id })
            guard replaceRepresentative(id, paneID: panes[index].id, with: replacement) else { return false }
            panes[index].selected = replacement
        }
        panes[index].tabs.remove(at: tabIndex)
        return true
    }

    /// Restores tab membership saved beside a layout that Bento may have
    /// changed since (reconciliation, drops, swaps). See `synchronize`.
    public init(layout: BentoLayoutState, panes: [BentoTabbedPane]) {
        self.layout = layout
        self.panes = panes
        synchronize(with: layout)
    }

    public var windowIDs: Set<WindowID> { Set(panes.flatMap(\.tabs)) }
    public var hiddenWindowIDs: Set<WindowID> {
        Set(panes.flatMap { pane in pane.tabs.filter { $0 != pane.selected } })
    }

    public func pane(containing id: WindowID) -> BentoTabbedPane? {
        panes.first { $0.tabs.contains(id) }
    }

    /// Adopts a layout produced by a Bento operation. A pane follows its
    /// selected window, so swaps and drops carry the whole tab group. New
    /// leaves become one-tab panes. A pane whose selected window left the
    /// tree loses its place; its other tabs are returned for the caller to
    /// place, since the tree no longer holds a position for them.
    @discardableResult
    public mutating func synchronize(with layout: BentoLayoutState) -> [WindowID] {
        let leaves = layout.root?.windowIDs ?? []
        let leafSet = Set(leaves)
        let vacancies = Set(layout.root.map(Self.vacancyIDs) ?? [])
        var orphans: [WindowID] = []
        var kept: [BentoTabbedPane] = []
        var claimed = Set<WindowID>()
        for var pane in panes {
            pane.tabs.removeAll { layout.floatingWindowIDs.contains($0) || claimed.contains($0) }
            if let selected = pane.selected, leafSet.contains(selected), pane.tabs.contains(selected) {
                // A hidden tab that became a leaf elsewhere now leads its own pane.
                pane.tabs.removeAll { $0 != selected && leafSet.contains($0) }
                claimed.formUnion(pane.tabs)
                kept.append(pane)
            } else if pane.selected == nil, pane.tabs.isEmpty, vacancies.contains(pane.id) {
                kept.append(pane)
            } else {
                orphans += pane.tabs.filter { $0 != pane.selected && !leafSet.contains($0) }
            }
        }
        for id in leaves where !claimed.contains(id) {
            kept.append(BentoTabbedPane(id: UUID(), tabs: [id]))
            claimed.insert(id)
        }
        self.layout = layout
        self.panes = kept
        return orphans.filter { !claimed.contains($0) }
    }

    /// Removes a window from its tab group without touching the other tabs.
    /// A selected window hands its leaf to the next tab. The window ends up
    /// outside the tree and every pane, ready for a Bento drop or to float.
    /// A lone tab is not detached: moving it is an ordinary Bento operation.
    @discardableResult
    public mutating func detach(_ id: WindowID) -> Bool {
        guard let index = panes.firstIndex(where: { $0.tabs.contains(id) }),
              panes[index].tabs.count > 1 else { return false }
        return remove(id)
    }

    /// Moves a tab within its pane. Selection and geometry do not change.
    @discardableResult
    public mutating func reorder(_ id: WindowID, to position: Int) -> Bool {
        guard let index = panes.firstIndex(where: { $0.tabs.contains(id) }),
              let from = panes[index].tabs.firstIndex(of: id) else { return false }
        panes[index].tabs.remove(at: from)
        panes[index].tabs.insert(id, at: min(max(0, position), panes[index].tabs.count))
        return true
    }

    /// The Bento layout for leaving Tabbed: every hidden tab gets its own
    /// pane, split from its group's pane along that pane's longer side, and
    /// the strip reserve is removed.
    public func unstacked(in bounds: BTRect) -> BentoLayoutState {
        var result = layout
        result.metrics.contentTopInset = 0
        for pane in panes {
            guard let selected = pane.selected else { continue }
            var anchor = selected
            for hidden in pane.tabs where hidden != selected {
                let frame = result.paneFrames(in: bounds)[anchor] ?? bounds
                result.split(anchor, inserting: hidden,
                             axis: frame.size.width >= frame.size.height ? .vertical : .horizontal,
                             in: bounds)
                anchor = hidden
            }
        }
        return result
    }

    private static func vacancyIDs(_ node: BentoNode) -> [UUID] {
        switch node {
        case .leaf: []
        case let .vacant(id): [id]
        case let .partition(partition): partition.children.flatMap(vacancyIDs)
        }
    }

    /// Full pane frames, including the area reserved for the tab strip.
    public func paneFrames(in bounds: BTRect) -> [UUID: BTRect]? {
        guard Self.valid(bounds) else { return nil }
        let occupied = layout.paneFrames(in: bounds)
        let vacant = layout.vacantFrames(in: bounds)
        var result: [UUID: BTRect] = [:]
        for pane in panes {
            guard let frame = pane.selected.flatMap({ occupied[$0] }) ?? vacant[pane.id] else { return nil }
            result[pane.id] = frame
        }
        return result
    }

    /// Window frames below the strip, from the layout's content reserve.
    /// Empty panes may have zero content height.
    public func contentFrames(in bounds: BTRect) -> [UUID: BTRect]? {
        paneFrames(in: bounds)?.mapValues { layout.metrics.contentFrame(forPane: $0) }
    }

    /// Fits selected minimum sizes using Bento's solver, which adds the strip
    /// reserve to each pane's minimum height. Hidden tabs contribute no
    /// minimum. Exact and maximum sizes, including fixed-size windows, require
    /// runtime validation.
    public func fitted(in bounds: BTRect, constraints: [WindowID: WindowConstraints]) -> Self? {
        guard Self.valid(bounds) else { return nil }
        var selectedConstraints: [WindowID: WindowConstraints] = [:]
        for id in panes.compactMap(\.selected) {
            let value = constraints[id] ?? WindowConstraints()
            let minimum = value.minimumSize
            guard minimum.width.isFinite, minimum.height.isFinite,
                  minimum.width >= 0, minimum.height >= 0 else { return nil }
            selectedConstraints[id] = value
        }
        guard let solved = BentoConstraintSolver().solve(state: layout, in: bounds, constraints: selectedConstraints) else { return nil }
        var result = self
        result.layout = solved
        return result
    }

    private mutating func replaceRepresentative(_ old: WindowID?, paneID: UUID, with new: WindowID?) -> Bool {
        if let old, let new { return layout.replace(old, with: new) }
        guard let root = layout.root else { return false }
        var found = false
        func replace(_ node: BentoNode) -> BentoNode {
            switch node {
            case let .leaf(id) where id == old:
                found = true
                return new.map(BentoNode.leaf) ?? .vacant(paneID)
            case let .vacant(id) where old == nil && id == paneID:
                found = true
                return new.map(BentoNode.leaf) ?? node
            case var .partition(partition):
                partition.children = partition.children.map(replace)
                return .partition(partition)
            default: return node
            }
        }
        let updated = replace(root)
        if found { layout.root = updated }
        return found
    }

    private static func valid(_ bounds: BTRect) -> Bool {
        [bounds.minX, bounds.minY, bounds.maxX, bounds.maxY,
         bounds.size.width, bounds.size.height].allSatisfy(\.isFinite)
            && bounds.size.width > 0 && bounds.size.height > 0
    }
}
