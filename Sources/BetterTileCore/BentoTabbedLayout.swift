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
    public fileprivate(set) var layout: BentoLayoutState
    public fileprivate(set) var panes: [BentoTabbedPane]

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
    /// - Parameters:
    ///   - position: Tab position; appends when nil.
    ///   - select: Selecting shows the window in the pane. An empty pane
    ///     always selects its first tab.
    @discardableResult
    public mutating func add(_ id: WindowID, to paneID: UUID, at position: Int? = nil, select: Bool = true) -> Bool {
        guard let index = panes.firstIndex(where: { $0.id == paneID }),
              !panes.contains(where: { $0.tabs.contains(id) }),
              layout.root?.windowIDs.contains(id) != true else { return false }
        let oldSelected = panes[index].selected
        let selects = select || oldSelected == nil
        if selects {
            guard replaceRepresentative(oldSelected, paneID: paneID, with: id) else { return false }
        }
        let insertion = min(max(0, position ?? panes[index].tabs.count), panes[index].tabs.count)
        panes[index].tabs.insert(id, at: insertion)
        if selects { panes[index].selected = id }
        layout.floatingWindowIDs.remove(id)
        return true
    }

    /// Takes a tab out of its group and keeps it outside the tree.
    @discardableResult
    public mutating func float(_ id: WindowID) -> Bool {
        guard remove(id) else { return false }
        layout.floatingWindowIDs.insert(id)
        return true
    }

    public mutating func forgetFloating(_ id: WindowID) {
        layout.floatingWindowIDs.remove(id)
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
            // Like a browser: the tab to the right, else the one to the left.
            let tabs = panes[index].tabs
            let replacement = tabIndex + 1 < tabs.count ? tabs[tabIndex + 1] : (tabIndex > 0 ? tabs[tabIndex - 1] : nil)
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
        result.metrics.vacantMinimumSize = BTSize(width: 0, height: 0)
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

/// A Tabbed desktop. The Bento tree owns all pane geometry, boundaries, and
/// minimum-size solving; this adds tab groups and the pane that receives new
/// windows. Bento's own operations (divider drags, drops, settlement) change
/// the tree directly, and `synchronize(with:)` brings the groups along.
public struct TabbedLayoutState: Hashable, Sendable {
    public private(set) var groups: BentoTabbedLayoutState
    public private(set) var activePaneID: UUID
    /// The tab strip, reserved above each window by Bento's content inset.
    public static let headerHeight = 34.0
    public static let maximumPaneCount = 12
    public static let gap = 6.0
    /// An empty pane stays large enough to show its drop target.
    public static let emptyPaneMinimum = BTSize(width: 120, height: 80 + headerHeight)

    private static func tabbedMetrics(_ metrics: BentoLayoutMetrics) -> BentoLayoutMetrics {
        var result = metrics
        result.contentTopInset = headerHeight
        result.vacantMinimumSize = emptyPaneMinimum
        return result
    }

    public var layout: BentoLayoutState { groups.layout }
    public var panes: [TabbedPane] {
        groups.panes.map { group in
            var pane = TabbedPane(id: group.id)
            pane.tabs = group.tabs
            pane.selected = group.selected
            return pane
        }
    }
    public var floatingWindowIDs: Set<WindowID> { layout.floatingWindowIDs }
    public var windowIDs: Set<WindowID> { groups.windowIDs }
    public var selectedWindowIDs: [WindowID] { groups.panes.compactMap(\.selected) }
    public var hiddenWindowIDs: Set<WindowID> { groups.hiddenWindowIDs }
    public var activeWindowID: WindowID? { groups.panes.first { $0.id == activePaneID }?.selected }

    public init(preset: TabbedPreset = .single) {
        let ids = (0..<preset.paneCount).map { _ in UUID() }
        let layout = BentoLayoutState(root: Self.tree(preset, leaves: ids.map { BentoNode.vacant($0) }),
                                      metrics: Self.tabbedMetrics(BentoLayoutMetrics(paneGap: Self.gap)))
        groups = BentoTabbedLayoutState(adopting: layout, contentTopInset: Self.headerHeight)!
        activePaneID = groups.panes[0].id
    }

    /// Entering Tabbed from Bento keeps every pane where it is; each window
    /// becomes a one-tab pane.
    public init?(adopting bento: BentoLayoutState) {
        var bento = bento
        bento.metrics = Self.tabbedMetrics(bento.metrics)
        // The pane cap limits Tabbed's own splits; an existing Bento layout
        // keeps every pane, however many.
        guard let groups = BentoTabbedLayoutState(adopting: bento, contentTopInset: Self.headerHeight) else { return nil }
        self.groups = groups
        activePaneID = groups.panes[0].id
    }

    /// Follows a tree that a Bento operation changed. A pane follows its
    /// selected window. Tabs whose pane lost its place join the active pane
    /// without being shown.
    public mutating func synchronize(with bento: BentoLayoutState) {
        var bento = bento
        bento.metrics = Self.tabbedMetrics(bento.metrics)
        let orphans = groups.synchronize(with: bento)
        if groups.panes.isEmpty {
            let paneID = UUID()
            var empty = bento
            empty.root = .vacant(paneID)
            groups.synchronize(with: empty)
        }
        if !groups.panes.contains(where: { $0.id == activePaneID }) { activePaneID = groups.panes[0].id }
        for id in orphans { groups.add(id, to: activePaneID, select: false) }
    }

    public mutating func activatePane(_ id: UUID) {
        if groups.panes.contains(where: { $0.id == id }) { activePaneID = id }
    }

    public mutating func select(_ windowID: WindowID) {
        guard let pane = groups.pane(containing: windowID), groups.select(windowID) else { return }
        activePaneID = pane.id
    }

    /// New windows join the active pane as its selected tab. Absence alone is
    /// not closure: the caller supplies authoritative removals.
    public mutating func reconcile(windowIDs observed: [WindowID], removed: Set<WindowID>, focused: WindowID?) {
        for id in removed { removeClosedWindow(id) }
        let known = windowIDs.union(floatingWindowIDs)
        let added = Array(Set(observed).subtracting(known)).sorted()
        for id in added { groups.add(id, to: activePaneID) }
        if let focused, windowIDs.contains(focused), added.isEmpty || added.contains(focused) { select(focused) }
    }

    /// The last tab of a pane leaves the pane empty, ready for another tab.
    public mutating func removeClosedWindow(_ id: WindowID) {
        groups.remove(id)
        groups.forgetFloating(id)
    }

    public mutating func float(_ id: WindowID) {
        groups.float(id)
    }

    /// Starts dragging one tab out of a group: the next tab takes the leaf
    /// and the dragged window floats until Bento places it. Returns the pane
    /// it came from, or nil for a lone tab, which moves as an ordinary Bento
    /// pane.
    public mutating func tearOff(_ id: WindowID) -> UUID? {
        guard let pane = groups.pane(containing: id), pane.tabs.count > 1, groups.float(id) else { return nil }
        return pane.id
    }

    public func paneID(containing id: WindowID) -> UUID? { groups.pane(containing: id)?.id }

    public func pane(containing id: WindowID) -> TabbedPane? {
        guard let paneID = paneID(containing: id) else { return nil }
        return panes.first { $0.id == paneID }
    }

    /// Moves a tab (or a floating window) into a pane at a position and
    /// selects it. Within one pane this only reorders.
    public mutating func move(_ id: WindowID, to paneID: UUID, at index: Int? = nil) {
        guard groups.panes.contains(where: { $0.id == paneID }),
              windowIDs.contains(id) || floatingWindowIDs.contains(id) else { return }
        if groups.pane(containing: id)?.id == paneID {
            if let index { groups.reorder(id, to: index) }
            select(id)
            return
        }
        groups.remove(id)
        groups.forgetFloating(id)
        if groups.add(id, to: paneID, at: index) { activePaneID = paneID }
    }

    /// Moves a tab into a new pane on one edge of another pane.
    public mutating func split(paneID: UUID, moving windowID: WindowID, edge: TabbedEdge) {
        guard groups.panes.count < Self.maximumPaneCount,
              groups.panes.contains(where: { $0.id == paneID }),
              windowIDs.contains(windowID) || floatingWindowIDs.contains(windowID) else { return }
        groups.remove(windowID)
        groups.forgetFloating(windowID)
        guard let target = groups.panes.first(where: { $0.id == paneID }), let root = layout.root else { return }
        let targetNode: BentoNode = target.selected.map(BentoNode.leaf) ?? .vacant(target.id)
        let axis: SplitAxis = edge == .left || edge == .right ? .vertical : .horizontal
        let sourceFirst = edge == .left || edge == .top
        var found = false
        func replacing(_ node: BentoNode) -> BentoNode {
            if node == targetNode {
                found = true
                let id = UUID()
                return .partition(BentoPartition(
                    id: id, axis: axis,
                    children: sourceFirst ? [.leaf(windowID), node] : [node, .leaf(windowID)],
                    boundaryIDs: [id]
                ))
            }
            guard case var .partition(partition) = node else { return node }
            partition.children = partition.children.map(replacing)
            return .partition(partition)
        }
        var next = layout
        next.root = BentoLayoutState.normalized(replacing(root))
        guard found else { return }
        groups.synchronize(with: next)
        if let pane = groups.pane(containing: windowID) { activePaneID = pane.id }
    }

    public mutating func removeEmptyPane(_ id: UUID) {
        guard groups.panes.count > 1, groups.panes.first(where: { $0.id == id })?.tabs.isEmpty == true,
              let root = layout.root else { return }
        func removing(_ node: BentoNode) -> BentoNode? {
            switch node {
            case let .vacant(paneID): return paneID == id ? nil : node
            case .leaf: return node
            case var .partition(partition):
                var children: [BentoNode] = []
                var ratios: [Double] = []
                for (child, ratio) in zip(partition.children, partition.ratios) {
                    guard let kept = removing(child) else { continue }
                    children.append(kept)
                    ratios.append(ratio)
                }
                guard !children.isEmpty else { return nil }
                guard children.count > 1 else { return children[0] }
                let total = ratios.reduce(0, +)
                partition.children = children
                partition.ratios = ratios.map { $0 / max(total, .leastNonzeroMagnitude) }
                partition.boundaryIDs = Array(partition.boundaryIDs.prefix(children.count - 1))
                partition.lockedBoundaryIDs.formIntersection(partition.boundaryIDs)
                return .partition(partition)
            }
        }
        var next = layout
        next.root = removing(root).map(BentoLayoutState.normalized)
        synchronize(with: next)
    }

    /// Replaces the pane arrangement with a preset. The first groups keep
    /// their order; groups beyond the preset merge into the nearest pane.
    public mutating func applyPreset(_ preset: TabbedPreset) {
        let unit = BTRect(x: 0, y: 0, width: 1000, height: 1000)
        let oldGroups = groups.panes
        let oldFrames = groups.paneFrames(in: unit) ?? [:]
        let kept = Array(oldGroups.prefix(preset.paneCount))
        var paneIDs = kept.map(\.id)
        while paneIDs.count < preset.paneCount { paneIDs.append(UUID()) }
        var empty = layout
        empty.root = Self.tree(preset, leaves: paneIDs.map { BentoNode.vacant($0) })
        guard var next = BentoTabbedLayoutState(adopting: empty, contentTopInset: Self.headerHeight) else { return }
        let newFrames = next.paneFrames(in: unit) ?? [:]
        func place(_ group: BentoTabbedPane, into paneID: UUID) {
            for id in group.tabs { next.add(id, to: paneID, select: id == group.selected) }
        }
        for (group, paneID) in zip(kept, paneIDs) { place(group, into: paneID) }
        // Merged groups join as hidden tabs; each pane keeps what it shows.
        func merge(_ group: BentoTabbedPane, into paneID: UUID) {
            for id in group.tabs { next.add(id, to: paneID, select: false) }
        }
        for group in oldGroups.dropFirst(preset.paneCount) {
            let center = oldFrames[group.id]?.center ?? BTPoint(x: 0, y: 0)
            let nearest = paneIDs.min { a, b in
                func distance(_ id: UUID) -> Double {
                    guard let point = newFrames[id]?.center else { return .infinity }
                    return pow(point.x - center.x, 2) + pow(point.y - center.y, 2)
                }
                return distance(a) < distance(b)
            }!
            merge(group, into: nearest)
        }
        groups = next
        if !groups.panes.contains(where: { $0.id == activePaneID }) { activePaneID = groups.panes[0].id }
    }

    /// Full pane frames, including the tab strip.
    public func frames(in bounds: BTRect) -> [UUID: BTRect] { groups.paneFrames(in: bounds) ?? [:] }

    /// Pane dividers from the Bento tree, for accessibility controls.
    public func dividers(in bounds: BTRect) -> [BoundaryDescriptor] {
        layout.boundaries(in: bounds, displayID: DisplayID(rawValue: "tabbed")).filter { !$0.isLocked }
    }

    /// Moves one Bento divider by a fraction of the area it splits, as
    /// VoiceOver increment and decrement do. Minimum sizes are fitted later.
    @discardableResult
    public mutating func adjustDivider(_ branchID: UUID, by fraction: Double, in bounds: BTRect) -> Bool {
        guard fraction.isFinite,
              let divider = dividers(in: bounds).first(where: { $0.branchID == branchID }),
              let parent = divider.parentBounds else { return false }
        let extent = divider.axis == .vertical ? parent.size.width : parent.size.height
        var next = layout
        guard next.setBoundaryCoordinate(divider.coordinate + fraction * extent, branchID: branchID, in: bounds)
        else { return false }
        synchronize(with: next)
        return true
    }

    /// Reads a user's edge resize of selected windows as Bento does. A drag on
    /// a shared pane edge moves that divider, stopping at each pane's minimum.
    /// Returns nil for anything else (an outer edge, a move, a macOS
    /// destination), and the caller puts the windows back. Hidden tabs follow
    /// their pane, so their frames are not read.
    public func adoptingResize(
        of changed: Set<WindowID>,
        frames: [WindowID: BTRect],
        constraints: [WindowID: WindowConstraints],
        in bounds: BTRect,
        tolerance: Double
    ) -> Self? {
        let expected = Dictionary(uniqueKeysWithValues: layout.placements(in: bounds).map { ($0.windowID, $0.frame) })
        var classifications: [WindowID: ExternalWindowChange] = [:]
        for id in changed.intersection(selectedWindowIDs) {
            guard let expectedFrame = expected[id], let observed = frames[id] else { continue }
            classifications[id] = ExternalWindowChangeClassifier.classify(
                expected: expectedFrame, observed: observed, in: bounds, edgeTolerance: tolerance
            )
        }
        guard case let .fitDividers(ids) = ExternalChangeRouter.route(classifications),
              let fitted = BentoLayoutFitter(tolerance: tolerance).fit(
                  state: layout, currentFrames: frames, changedWindowIDs: ids, in: bounds, constraints: constraints
              )
        else { return nil }
        var result = self
        result.synchronize(with: fitted.state)
        return result
    }

    /// The Bento layout for leaving Tabbed: every hidden tab gets a pane.
    public func unstacked(in bounds: BTRect) -> BentoLayoutState { groups.unstacked(in: bounds) }

    /// The window area of a pane frame, below the strip.
    public static func contentFrame(_ pane: BTRect) -> BTRect {
        BentoLayoutMetrics(contentTopInset: headerHeight).contentFrame(forPane: pane)
    }

    /// Every tab takes its pane's window area; hidden tabs stack behind the
    /// selected one. Only selected tabs must fit: a hidden tab never makes a
    /// layout too small.
    public func placements(in bounds: BTRect, windows: [WindowSnapshot]) throws -> [Placement] {
        let snapshots = Dictionary(uniqueKeysWithValues: windows.map { ($0.id, $0) })
        let paneFrames = frames(in: bounds)
        var result: [Placement] = []
        for pane in groups.panes {
            guard let paneFrame = paneFrames[pane.id] else { continue }
            let frame = Self.contentFrame(paneFrame)
            for id in pane.tabs {
                guard let window = snapshots[id], window.isEligible else { continue }
                if id == pane.selected {
                    guard frame.size.width + 0.001 >= window.constraints.minimumSize.width,
                          frame.size.height + 0.001 >= window.constraints.minimumSize.height,
                          window.constraints.isResizable || frame.size == window.frame.size
                    else { throw TabbedLayoutError.panesTooSmall }
                }
                result.append(Placement(windowID: id, frame: frame))
            }
        }
        return result
    }

    /// Solves the selected tabs' minimum sizes with Bento's solver.
    public func fittingMinimumWidths(in bounds: BTRect, windows: [WindowSnapshot]) throws -> Self {
        let constraints = Dictionary(windows.map { ($0.id, $0.constraints) }, uniquingKeysWith: { first, _ in first })
        guard let fitted = groups.fitted(in: bounds, constraints: constraints) else { throw TabbedLayoutError.panesTooSmall }
        var result = self
        result.groups = fitted
        return result
    }

    private static func tree(_ preset: TabbedPreset, leaves: [BentoNode]) -> BentoNode {
        func split(_ axis: SplitAxis, _ children: [BentoNode], ratios: [Double] = []) -> BentoNode {
            let ids = (0..<(children.count - 1)).map { _ in UUID() }
            return .partition(BentoPartition(axis: axis, children: children, ratios: ratios, boundaryIDs: ids))
        }
        switch preset {
        case .single: return leaves[0]
        case .columns: return split(.vertical, [leaves[0], leaves[1]])
        case .rows: return split(.horizontal, [leaves[0], leaves[1]])
        case .focus: return split(.vertical, [leaves[0], split(.horizontal, [leaves[1], leaves[2]])], ratios: [0.6, 0.4])
        case .grid: return split(.vertical, [split(.horizontal, [leaves[0], leaves[1]]),
                                             split(.horizontal, [leaves[2], leaves[3]])])
        }
    }
}
