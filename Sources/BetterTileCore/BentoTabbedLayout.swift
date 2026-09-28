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

    public init?(adopting layout: BentoLayoutState) {
        var adopted = layout
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

    /// Full pane frames, including the area reserved for the tab strip.
    public func paneFrames(in bounds: BTRect) -> [UUID: BTRect]? {
        guard Self.valid(bounds) else { return nil }
        let occupied = Dictionary(uniqueKeysWithValues: layout.placements(in: bounds).map { ($0.windowID, $0.frame) })
        let vacant = layout.vacantFrames(in: bounds)
        var result: [UUID: BTRect] = [:]
        for pane in panes {
            guard let frame = pane.selected.flatMap({ occupied[$0] }) ?? vacant[pane.id] else { return nil }
            result[pane.id] = frame
        }
        return result
    }

    /// Window frames below the strip. Empty panes may have zero content height.
    public func contentFrames(in bounds: BTRect, stripHeight: Double) -> [UUID: BTRect]? {
        guard stripHeight.isFinite, stripHeight >= 0, let frames = paneFrames(in: bounds) else { return nil }
        return frames.mapValues { frame in
            BTRect(x: frame.minX, y: frame.minY + min(stripHeight, frame.size.height),
                   width: frame.size.width, height: max(0, frame.size.height - stripHeight))
        }
    }

    /// Fits selected minimum sizes using Bento's solver. A strip is reserved
    /// inside each occupied pane; hidden tabs contribute no minimum. Exact and
    /// maximum sizes, including fixed-size windows, require runtime validation.
    public func fitted(in bounds: BTRect, constraints: [WindowID: WindowConstraints], stripHeight: Double) -> Self? {
        guard Self.valid(bounds), stripHeight.isFinite, stripHeight >= 0 else { return nil }
        var selectedConstraints: [WindowID: WindowConstraints] = [:]
        for id in panes.compactMap(\.selected) {
            var value = constraints[id] ?? WindowConstraints()
            let minimum = value.minimumSize
            guard minimum.width.isFinite, minimum.height.isFinite,
                  minimum.width >= 0, minimum.height >= 0,
                  (minimum.height + stripHeight).isFinite else { return nil }
            value.minimumSize.height += stripHeight
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
