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
    /// - Parameter reselecting: See `remove(_:reselecting:)`.
    @discardableResult
    public mutating func float(_ id: WindowID, reselecting: WindowID? = nil) -> Bool {
        guard remove(id, reselecting: reselecting) else { return false }
        layout.floatingWindowIDs.insert(id)
        return true
    }

    public mutating func forgetFloating(_ id: WindowID) {
        layout.floatingWindowIDs.remove(id)
    }

    /// Adds a window that is in no pane and not in the tree as floating.
    public mutating func addFloating(_ id: WindowID) {
        guard !panes.contains(where: { $0.tabs.contains(id) }),
              layout.root?.windowIDs.contains(id) != true else { return }
        layout.floatingWindowIDs.insert(id)
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
    /// - Parameter reselecting: When the removed tab is selected, this tab
    ///   takes its place if it is another tab of the same pane. A tab drag
    ///   uses it to give the pane back the tab it showed before the press
    ///   that selected the dragged tab.
    @discardableResult
    public mutating func remove(_ id: WindowID, reselecting: WindowID? = nil) -> Bool {
        guard let index = panes.firstIndex(where: { $0.tabs.contains(id) }),
              let tabIndex = panes[index].tabs.firstIndex(of: id) else { return false }
        if panes[index].selected == id {
            let tabs = panes[index].tabs
            let replacement: WindowID?
            if let reselecting, reselecting != id, tabs.contains(reselecting) {
                replacement = reselecting
            } else {
                // Like a browser: the tab to the right, else the one to the left.
                replacement = tabIndex + 1 < tabs.count ? tabs[tabIndex + 1] : (tabIndex > 0 ? tabs[tabIndex - 1] : nil)
            }
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
        let vacancyIDs = layout.root.map(Self.vacancyIDs) ?? []
        let vacancies = Set(vacancyIDs)
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
        let keptPaneIDs = Set(kept.map(\.id))
        for id in vacancyIDs where !keptPaneIDs.contains(id) {
            kept.append(BentoTabbedPane(id: id, tabs: []))
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
    /// pane and the strip reserve is removed. Hidden tabs first fill empty
    /// panes, each taking the nearest pane's next hidden tab. The others
    /// split from their group's pane along that pane's longer side. An empty
    /// pane left over is removed, and the panes beside it take its space.
    public func unstacked(in bounds: BTRect) -> BentoLayoutState {
        var result = layout
        result.metrics.contentTopInset = 0
        result.metrics.vacantMinimumSize = BTSize(width: 0, height: 0)
        let occupiedFrames = result.paneFrames(in: bounds)
        var hidden: [(frame: BTRect, tabs: [WindowID])] = panes.compactMap { pane in
            guard let selected = pane.selected, let frame = occupiedFrames[selected] else { return nil }
            let tabs = pane.tabs.filter { $0 != selected }
            return tabs.isEmpty ? nil : (frame, tabs)
        }
        let emptyPanes = result.vacantFrames(in: bounds).sorted {
            $0.value.area != $1.value.area ? $0.value.area > $1.value.area : $0.key.uuidString < $1.key.uuidString
        }
        func distance(_ first: BTRect, _ second: BTRect) -> Double {
            hypot(first.midX - second.midX, first.midY - second.midY)
        }
        for (vacancyID, frame) in emptyPanes {
            guard let source = hidden.indices.filter({ !hidden[$0].tabs.isEmpty }).min(by: {
                distance(hidden[$0].frame, frame) < distance(hidden[$1].frame, frame)
            }) else { break }
            result.fillVacancy(vacancyID, with: hidden[source].tabs.removeFirst())
        }
        let filled = Set(result.root?.windowIDs ?? [])
        for pane in panes {
            guard let selected = pane.selected else { continue }
            var anchor = selected
            for hidden in pane.tabs where hidden != selected && !filled.contains(hidden) {
                let frame = result.paneFrames(in: bounds)[anchor] ?? bounds
                result.split(anchor, inserting: hidden,
                             axis: frame.size.width >= frame.size.height ? .vertical : .horizontal,
                             in: bounds)
                anchor = hidden
            }
        }
        result.removeVacancies()
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
        paneFrames(in: bounds)?.mapValues { layout.metrics.windowFrame(forPane: $0) }
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
            selectedConstraints[id] = wholePointMinimumConstraints(value)
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

/// A tab's place while its window cannot participate in automatic layout.
public struct TabbedReturnSlot: Hashable, Sendable {
    public let paneID: UUID
    public let index: Int
    public let wasSelected: Bool
    fileprivate let selectionGeneration: UInt64
}

/// A Tabbed desktop. The Bento tree owns all pane geometry, boundaries, and
/// minimum-size solving; this adds tab groups and the pane that receives new
/// windows. Bento's own operations (divider drags, drops, settlement) change
/// the tree directly, and `synchronize(with:)` brings the groups along.
public struct TabbedLayoutState: Hashable, Sendable {
    public private(set) var groups: BentoTabbedLayoutState
    public private(set) var activePaneID: UUID
    /// Pane sizes as the user last set them, by partition: with a divider,
    /// an edge resize, a preset, or a split. A tab that needs more room grows
    /// its pane without changing these, so the pane can return to them.
    public private(set) var preferredPaneRatios: [UUID: [Double]] = [:]
    /// Floating windows that Tabbed or Bento floated on its own, for example
    /// a new window that fit no pane. The user did not float them, so a
    /// repair or a later check can return them to a pane. Stored with the
    /// rest of the state, so Undo and a rollback keep it.
    private var automaticFloats: Set<WindowID> = []
    /// Process-local places held for tabs that temporarily cannot participate.
    public private(set) var returnSlots: [WindowID: TabbedReturnSlot] = [:]
    private var selectionGenerations: [UUID: UInt64] = [:]

    /// Return bookkeeping is part of session identity, but cannot by itself
    /// require placement or invalidate a tab interaction.
    public func layoutEquals(_ other: Self) -> Bool {
        groups == other.groups && activePaneID == other.activePaneID
            && preferredPaneRatios == other.preferredPaneRatios
            && automaticFloats == other.automaticFloats
    }

    /// Apply only bookkeeping that changed while a proposal was pending.
    /// A new preset owns its panes; slots for removed panes never carry over.
    /// A slot the proposal dropped stays dropped: a concurrent close can shift
    /// that slot's index, but the change must not bring it back. Only a window
    /// that stepped away while the proposal was pending gains a slot.
    mutating func mergeReturnChanges(from current: Self, since baseline: Self) {
        for id in Set(current.returnSlots.keys).union(baseline.returnSlots.keys)
            where current.returnSlots[id] != baseline.returnSlots[id] {
            guard let updated = current.returnSlots[id] else {
                returnSlots.removeValue(forKey: id)
                continue
            }
            if baseline.returnSlots[id] == nil || returnSlots[id] != nil {
                returnSlots[id] = updated
            }
        }
        for id in Set(current.selectionGenerations.keys).union(baseline.selectionGenerations.keys)
            where current.selectionGenerations[id] != baseline.selectionGenerations[id] {
            selectionGenerations[id] = current.selectionGenerations[id]
        }
        let paneIDs = Set(groups.panes.map(\.id))
        returnSlots = returnSlots.filter { paneIDs.contains($0.value.paneID) }
        selectionGenerations = selectionGenerations.filter { paneIDs.contains($0.key) }
    }

    public mutating func clearReturnSlots() {
        returnSlots.removeAll()
        selectionGenerations.removeAll()
    }

    private mutating func recordSelection(in paneID: UUID) {
        // Only pending returns need to distinguish user selections. Keeping
        // no history otherwise also keeps repeated selections idempotent.
        if returnSlots.values.contains(where: { $0.paneID == paneID }) {
            selectionGenerations[paneID, default: 0] &+= 1
        }
    }
    /// The tab strip, reserved above each window by Bento's content inset.
    public static let headerHeight = 34.0
    public static let maximumPaneCount = 12
    public static let gap = 6.0
    /// An empty pane stays large enough to show its drop target.
    public static let emptyPaneMinimum = BTSize(width: 120, height: 80 + headerHeight)

    private static func tabbedMetrics(_ metrics: BentoLayoutMetrics, presentation: TabbedStripPresentation) -> BentoLayoutMetrics {
        var result = metrics
        result.contentTopInset = presentation.reservedInset
        result.vacantMinimumSize = BTSize(width: 120, height: 80 + presentation.reservedInset)
        return result
    }

    public var layout: BentoLayoutState { groups.layout }
    public var presentation: TabbedStripPresentation {
        TabbedStripPresentation.allCases.first { $0.reservedInset == layout.metrics.contentTopInset } ?? .alwaysVisible
    }

    public mutating func setPresentation(_ presentation: TabbedStripPresentation) {
        guard self.presentation != presentation else { return }
        var next = layout
        next.metrics = Self.tabbedMetrics(next.metrics, presentation: presentation)
        groups.synchronize(with: next)
    }

    public func windowArea(_ pane: BTRect) -> BTRect { layout.metrics.windowFrame(forPane: pane) }
    public var panes: [TabbedPane] {
        groups.panes.map { group in
            var pane = TabbedPane(id: group.id)
            pane.tabs = group.tabs
            pane.selected = group.selected
            return pane
        }
    }
    public var floatingWindowIDs: Set<WindowID> { layout.floatingWindowIDs }
    /// Floating windows that the user did not float. See `automaticFloats`.
    public var automaticallyFloatingWindowIDs: Set<WindowID> { automaticFloats.intersection(floatingWindowIDs) }
    public var windowIDs: Set<WindowID> { groups.windowIDs }
    public var selectedWindowIDs: [WindowID] { groups.panes.compactMap(\.selected) }
    public var hiddenWindowIDs: Set<WindowID> { groups.hiddenWindowIDs }
    public var activeWindowID: WindowID? { groups.panes.first { $0.id == activePaneID }?.selected }

    /// A fresh pane arrangement can retain floating windows from Adaptive.
    /// Only automatic floats are offered a pane on entry.
    public init(preset: TabbedPreset = .single, presentation: TabbedStripPresentation = .alwaysVisible,
                floatingWindowIDs: Set<WindowID> = [], automaticallyFloating: Set<WindowID> = []) {
        let ids = (0..<preset.paneCount).map { _ in UUID() }
        let layout = BentoLayoutState(root: Self.tree(preset, leaves: ids.map { BentoNode.vacant($0) }),
                                      floatingWindowIDs: floatingWindowIDs, metrics: Self.tabbedMetrics(BentoLayoutMetrics(paneGap: Self.gap), presentation: presentation))
        groups = BentoTabbedLayoutState(adopting: layout, contentTopInset: presentation.reservedInset)!
        activePaneID = groups.panes[0].id
        automaticFloats = automaticallyFloating.intersection(floatingWindowIDs)
        rememberPaneSizes()
    }

    /// Entering Tabbed with Keep Adaptive panes keeps every pane where it is; each window
    /// becomes a one-tab pane.
    /// - Parameter automaticallyFloating: The windows Bento floated on its
    ///   own, such as a seventh window or one that fit no pane. They stay
    ///   automatic floats, so Tabbed can return them to a pane.
    public init?(adopting bento: BentoLayoutState, automaticallyFloating: Set<WindowID> = [], presentation: TabbedStripPresentation = .alwaysVisible) {
        var bento = bento
        bento.metrics = Self.tabbedMetrics(bento.metrics, presentation: presentation)
        // The pane cap limits Tabbed's own splits; an existing Bento layout
        // keeps every pane, however many.
        guard let groups = BentoTabbedLayoutState(adopting: bento, contentTopInset: presentation.reservedInset) else { return nil }
        self.groups = groups
        activePaneID = groups.panes[0].id
        automaticFloats = automaticallyFloating.intersection(groups.layout.floatingWindowIDs)
        rememberPaneSizes()
    }

    /// Follows a tree that a Bento operation changed. A pane follows its
    /// selected window. Tabs whose pane lost its place join the active pane
    /// without being shown.
    public mutating func synchronize(with bento: BentoLayoutState) {
        var bento = bento
        bento.metrics = Self.tabbedMetrics(bento.metrics, presentation: presentation)
        let previousRoot = layout.root
        let previousPanes = groups.panes
        let orphans = groups.synchronize(with: bento)
        if groups.panes.isEmpty {
            let paneID = UUID()
            var empty = bento
            empty.root = .vacant(paneID)
            groups.synchronize(with: empty)
        }
        if !groups.panes.contains(where: { $0.id == activePaneID }) { activePaneID = groups.panes[0].id }
        // A tree edit can move a hidden peer or an absent tab out of a pane.
        // Capture logical positions before changing slots, then close gaps from
        // the end so multiple removals cannot change each other's indices.
        var removedPositions: [(paneID: UUID, index: Int)] = []
        for pane in previousPanes {
            for id in pane.tabs where groups.pane(containing: id)?.id != pane.id {
                if let index = logicalIndex(of: id, in: pane) { removedPositions.append((pane.id, index)) }
            }
        }
        let placed = windowIDs.union(floatingWindowIDs)
        for (id, slot) in returnSlots where placed.contains(id) {
            removedPositions.append((slot.paneID, slot.index))
            returnSlots.removeValue(forKey: id)
        }
        for position in removedPositions.sorted(by: { $0.index > $1.index }) {
            removeReservedIndex(position.index, in: position.paneID)
        }
        for id in orphans {
            if groups.add(id, to: activePaneID, select: false), groups.pane(containing: id)?.selected == id {
                recordSelection(in: activePaneID)
            }
        }
        automaticFloats.formIntersection(floatingWindowIDs)
        let paneIDs = Set(groups.panes.map(\.id))
        returnSlots = returnSlots.filter { paneIDs.contains($0.value.paneID) }
        selectionGenerations = selectionGenerations.filter { paneIDs.contains($0.key) }
        rememberPaneSizes(changedFrom: previousRoot)
    }

    /// This layout with the pane sizes the user last set, or nil when it
    /// already has them. A partition the user has not sized keeps its ratios.
    public func withPreferredPaneSizes() -> Self? {
        guard let root = layout.root else { return nil }
        func restoring(_ node: BentoNode) -> BentoNode {
            guard case var .partition(partition) = node else { return node }
            if let ratios = preferredPaneRatios[partition.id], ratios.count == partition.children.count {
                partition.ratios = ratios
            }
            partition.children = partition.children.map(restoring)
            return .partition(partition)
        }
        let restored = restoring(root)
        guard restored != root else { return nil }
        var result = self
        result.groups.layout.root = restored
        return result
    }

    /// Records the pane sizes of the partitions an edit changed. A partition
    /// the edit left alone keeps the size the user set, even while a larger
    /// tab has grown it, so its pane can still return to that size.
    /// - Parameter previous: The tree before the edit; nil records every
    ///   partition.
    private mutating func rememberPaneSizes(changedFrom previous: BentoNode? = nil) {
        var before: [UUID: [Double]] = [:]
        func collectBefore(_ node: BentoNode) {
            guard case let .partition(partition) = node else { return }
            before[partition.id] = partition.ratios
            partition.children.forEach(collectBefore)
        }
        previous.map(collectBefore)
        var ratios: [UUID: [Double]] = [:]
        func collect(_ node: BentoNode) {
            guard case let .partition(partition) = node else { return }
            if before[partition.id] == partition.ratios, let kept = preferredPaneRatios[partition.id] {
                ratios[partition.id] = kept
            } else {
                ratios[partition.id] = partition.ratios
            }
            partition.children.forEach(collect)
        }
        layout.root.map(collect)
        preferredPaneRatios = ratios
    }

    public mutating func activatePane(_ id: UUID) {
        if groups.panes.contains(where: { $0.id == id }) { activePaneID = id }
    }

    public mutating func select(_ windowID: WindowID) {
        guard let pane = groups.pane(containing: windowID), groups.select(windowID) else { return }
        recordSelection(in: pane.id)
        activePaneID = pane.id
    }

    /// New windows join the active pane as its selected tab. Absence alone is
    /// not closure: the caller supplies authoritative removals.
    public mutating func reconcile(windowIDs observed: [WindowID], removed: Set<WindowID>, away: Set<WindowID> = [], focused: WindowID?) {
        for id in removed { removeClosedWindow(id) }
        for id in away.subtracting(removed).sorted() { stepAway(id) }
        let known = windowIDs.union(floatingWindowIDs)
        let added = Array(Set(observed).subtracting(known)).sorted()
        for id in added {
            removeTabPosition(id)
            if groups.add(id, to: activePaneID) { recordSelection(in: activePaneID) }
        }
        if let focused, windowIDs.contains(focused), added.isEmpty || added.contains(focused) { select(focused) }
    }

    /// Reconciles a running layout. A window that arrives later, for example
    /// from another Space, joins as the selected tab of the active pane when
    /// it fits there, moving boundaries only as far as it needs. Otherwise it
    /// joins, as a hidden tab, the other pane that can show it with the least
    /// change to the panes, as is or after boundaries adapt. A window that no
    /// pane can show floats automatically.
    /// - Returns: How each new window joined, for diagnostics.
    @discardableResult
    public mutating func reconcile(
        windowIDs observed: [WindowID],
        removed: Set<WindowID>,
        away: Set<WindowID> = [],
        fittingIn bounds: BTRect,
        windows: [WindowSnapshot],
        followed: FollowedLayout? = nil
    ) -> [TabbedAdoption] {
        for id in removed { removeClosedWindow(id) }
        for id in away.subtracting(removed).sorted() { stepAway(id) }
        let known = windowIDs.union(floatingWindowIDs)
        return Array(Set(observed).subtracting(known)).sorted().map {
            adopt($0, fittingIn: bounds, windows: windows, followed: followed)
        }
    }

    /// Takes windows that float automatically back into the panes, as new
    /// windows join. A window that still fits no pane at all floats again,
    /// automatically. User-floated windows are not affected.
    /// - Parameters:
    ///   - selecting: A window that joins a pane other than the active one
    ///     becomes its selected tab instead of a hidden tab.
    ///   - focused: The focused window, for a check the user did not ask
    ///     for. A returned window joins the pane that shows it as a hidden
    ///     tab, so it never takes the focused window's place.
    /// - Returns: How each window joined, for diagnostics.
    @discardableResult
    public mutating func returnAutomaticFloats(
        _ ids: Set<WindowID>,
        fittingIn bounds: BTRect,
        windows: [WindowSnapshot],
        selecting: Bool = false,
        keeping focused: WindowID? = nil,
        followed: FollowedLayout? = nil
    ) -> [TabbedAdoption] {
        let present = Set(windows.map(\.id))
        return ids.intersection(automaticallyFloatingWindowIDs).intersection(present).sorted().map { id in
            groups.forgetFloating(id)
            automaticFloats.remove(id)
            return adopt(id, fittingIn: bounds, windows: windows, selecting: selecting, keeping: focused, followed: followed)
        }
    }

    /// Why a window that no pane can show floats, for the decision log. A
    /// fixed-size window, or a proven minimum, larger than the work area
    /// below the strip fits no pane of any layout.
    public static func floatReason(for window: WindowSnapshot?, in bounds: BTRect, presentation: TabbedStripPresentation = .alwaysVisible) -> TabbedAdoption.FloatReason {
        guard let window else { return .fitsNoPane }
        let largest = contentFrame(bounds, presentation: presentation).size
        let required = window.constraints.isResizable ? window.constraints.minimumSize : window.frame.size
        guard required.width > largest.width + 0.001 || required.height > largest.height + 0.001 else { return .fitsNoPane }
        if !window.constraints.isResizable { return .fixedSizeLargerThanWorkArea }
        return window.constraints.minimumSizeSource.isProven ? .minimumLargerThanWorkArea : .fitsNoPane
    }

    private mutating func adopt(
        _ id: WindowID, fittingIn bounds: BTRect, windows: [WindowSnapshot], selecting: Bool = false,
        keeping focused: WindowID? = nil, followed: FollowedLayout? = nil
    ) -> TabbedAdoption {
        let window = windows.first { $0.id == id }
        func showsFocus(_ paneID: UUID) -> Bool {
            focused.map { $0 != id && groups.panes.first { $0.id == paneID }?.selected == $0 } == true
        }
        let current = frames(in: bounds)
        var trials: [TabbedAdoption.Trial] = []
        func trial(_ paneID: UUID, _ result: TabbedAdoption.TrialResult) -> TabbedAdoption.Trial {
            .init(paneID: paneID, contentFrame: current[paneID].map(windowArea), result: result)
        }
        func attempt(_ candidate: Self) -> (Self?, TabbedAdoption.TrialResult) {
            if (try? candidate.placements(in: bounds, windows: windows)) != nil { return (candidate, .fits) }
            if let fitted = try? candidate.fittingMinimumWidths(in: bounds, windows: windows),
               (try? fitted.placements(in: bounds, windows: windows)) != nil {
                return (fitted, .fitsAfterAdapting)
            }
            return (nil, .doesNotFit)
        }
        // A remembered place takes precedence over Saved Layout following
        // and the active pane. Prove that this pane can show the window even
        // when the return will be a hidden tab.
        let returnSlot = returnSlots.removeValue(forKey: id)
        if let slot = returnSlot,
           groups.panes.contains(where: { $0.id == slot.paneID }) {
            var candidate = self
            let absentBefore = returnSlots.values.filter {
                $0.paneID == slot.paneID && $0.index < slot.index
            }.count
            let index = max(0, slot.index - absentBefore)
            let selects = slot.wasSelected && selectionGenerations[slot.paneID, default: 0] == slot.selectionGeneration
            if candidate.groups.add(id, to: slot.paneID, at: index) {
                let (shown, result) = attempt(candidate)
                trials.append(trial(slot.paneID, result))
                if let shown {
                    if selects || groups.panes.first(where: { $0.id == slot.paneID })?.selected == nil {
                        self = shown
                    } else {
                        groups.add(id, to: slot.paneID, at: index, select: false)
                    }
                    return TabbedAdoption(windowID: id, outcome: .returned(slot.paneID), trials: trials)
                }
            }
        }
        if let slot = returnSlot { removeReservedIndex(slot.index, in: slot.paneID) }
        if let paneID = followed?.preferredPane(for: window?.bundleIdentifier, in: self) {
            var preferred = self
            if preferred.groups.add(id, to: paneID) {
                let (shown, result) = attempt(preferred)
                trials.append(trial(paneID, result))
                if let shown {
                    self = shown
                    recordSelection(in: paneID)
                    return TabbedAdoption(windowID: id, outcome: .selected(paneID), trials: trials)
                }
            }
        }
        // The active pane is the user's choice for new windows: keep it when
        // the window fits there as is, or after boundaries adapt.
        var active = self
        if active.groups.add(id, to: activePaneID) {
            let (shown, result) = attempt(active)
            trials.append(trial(activePaneID, result))
            if let shown {
                if showsFocus(activePaneID) {
                    groups.add(id, to: activePaneID, select: false)
                    return TabbedAdoption(windowID: id, outcome: .hidden(activePaneID), trials: trials)
                }
                self = shown
                recordSelection(in: activePaneID)
                return TabbedAdoption(windowID: id, outcome: .selected(activePaneID), trials: trials)
            }
        } else {
            trials.append(trial(activePaneID, .rejected))
        }
        // Otherwise the pane that can show it with the least change to the
        // other panes, as is or after boundaries adapt. It joins as a hidden
        // tab; selecting it fits the panes again.
        var best: (change: Double, paneID: UUID, shown: Self)?
        for paneID in groups.panes.map(\.id) where paneID != activePaneID {
            var candidate = self
            guard candidate.groups.add(id, to: paneID) else {
                trials.append(trial(paneID, .rejected))
                continue
            }
            let (fitted, result) = attempt(candidate)
            trials.append(trial(paneID, result))
            guard let shown = fitted else { continue }
            let change = shown.frames(in: bounds).reduce(0) { total, entry in
                guard let old = current[entry.key] else { return total }
                return total + abs(old.minX - entry.value.minX) + abs(old.minY - entry.value.minY)
                    + abs(old.size.width - entry.value.size.width) + abs(old.size.height - entry.value.size.height)
            }
            if best.map({ change < $0.change - 0.5 }) ?? true { best = (change, paneID, shown) }
        }
        if let best {
            if selecting, !showsFocus(best.paneID) {
                self = best.shown
                recordSelection(in: best.paneID)
                return TabbedAdoption(windowID: id, outcome: .selected(best.paneID), trials: trials)
            }
            groups.add(id, to: best.paneID, select: false)
            if groups.pane(containing: id)?.selected == id { recordSelection(in: best.paneID) }
            return TabbedAdoption(windowID: id, outcome: .hidden(best.paneID), trials: trials)
        }
        // No pane can show it, even after boundaries adapt. It floats at its
        // own size instead of hiding behind a pane it overflows, as an
        // automatic float that a later layout change can return to a pane.
        groups.layout.floatingWindowIDs.insert(id)
        automaticFloats.insert(id)
        return TabbedAdoption(windowID: id, outcome: .floated(Self.floatReason(for: window, in: bounds, presentation: presentation)), trials: trials)
    }

    /// Forget a tab's logical position and close the gap for absent peers.
    private mutating func removeTabPosition(_ id: WindowID) {
        if let slot = returnSlots.removeValue(forKey: id) {
            removeReservedIndex(slot.index, in: slot.paneID)
        } else if let pane = groups.pane(containing: id), let index = logicalIndex(of: id, in: pane) {
            removeReservedIndex(index, in: pane.id)
        }
    }

    /// The last tab of a pane leaves the pane empty, ready for another tab.
    public mutating func removeClosedWindow(_ id: WindowID) {
        removeTabPosition(id)
        groups.remove(id)
        groups.forgetFloating(id)
        automaticFloats.remove(id)
    }

    /// An unavailable tab leaves a place to return to. Floating windows keep
    /// their existing floating state and never become new tab arrivals.
    public mutating func stepAway(_ id: WindowID) {
        guard returnSlots[id] == nil, let pane = groups.pane(containing: id),
              let index = logicalIndex(of: id, in: pane) else { return }
        let generation = selectionGenerations[pane.id, default: 0]
        // An automatic replacement must not also claim the original selection
        // when several tabs step away before any of them returns.
        let selectionIsHeld = returnSlots.values.contains {
            $0.paneID == pane.id && $0.wasSelected && $0.selectionGeneration == generation
        }
        let slot = TabbedReturnSlot(paneID: pane.id, index: index,
                                    wasSelected: pane.selected == id && !selectionIsHeld,
                                    selectionGeneration: generation)
        guard groups.remove(id) else { return }
        returnSlots[id] = slot
    }

    private func logicalIndex(of id: WindowID, in pane: BentoTabbedPane) -> Int? {
        guard var index = pane.tabs.firstIndex(of: id) else { return nil }
        // Include already absent tabs, so an app hiding several windows over
        // separate events preserves their order whichever one returns first.
        for position in returnSlots.values.filter({ $0.paneID == pane.id }).sorted(by: { $0.index < $1.index }) {
            if position.index <= index { index += 1 }
        }
        return index
    }

    /// Reserve a new position before inserting a present tab. Positions in
    /// return slots include absent peers; UI insertion indices do not.
    private mutating func insertTabPosition(at index: Int?, in paneID: UUID) {
        guard let pane = groups.panes.first(where: { $0.id == paneID }) else { return }
        let physical = min(max(0, index ?? pane.tabs.count), pane.tabs.count)
        var logical = physical
        for slot in returnSlots.values.filter({ $0.paneID == paneID }).sorted(by: { $0.index < $1.index }) {
            if slot.index <= logical { logical += 1 }
        }
        for (id, slot) in returnSlots where slot.paneID == paneID && slot.index >= logical {
            returnSlots[id] = TabbedReturnSlot(paneID: paneID, index: slot.index + 1,
                wasSelected: slot.wasSelected, selectionGeneration: slot.selectionGeneration)
        }
    }

    private mutating func removeReservedIndex(_ index: Int, in paneID: UUID) {
        for (id, slot) in returnSlots where slot.paneID == paneID && slot.index > index {
            returnSlots[id] = TabbedReturnSlot(paneID: paneID, index: slot.index - 1,
                wasSelected: slot.wasSelected, selectionGeneration: slot.selectionGeneration)
        }
    }

    /// Adds a window from outside this layout as a floating window, such as
    /// one a window drag carried here from another desktop. A member does
    /// not change.
    public mutating func addFloating(_ id: WindowID) {
        groups.addFloating(id)
    }

    /// Removes a floating window from this layout. A pane member does not
    /// change.
    public mutating func forgetFloating(_ id: WindowID) {
        guard floatingWindowIDs.contains(id) else { return }
        groups.forgetFloating(id)
        automaticFloats.remove(id)
    }

    /// - Parameter reselecting: The tab the source pane showed before the
    ///   gesture that selected `id`. The pane selects it again when it is
    ///   still a member; otherwise the next tab takes the pane as usual.
    public mutating func float(_ id: WindowID, reselecting: WindowID? = nil) {
        if returnSlots[id] != nil {
            removeTabPosition(id)
            groups.layout.floatingWindowIDs.insert(id)
            automaticFloats.remove(id)
            return
        }
        if let pane = groups.pane(containing: id), pane.selected == id { recordSelection(in: pane.id) }
        // The user floated it: a repair leaves it floating.
        removeTabPosition(id)
        if groups.float(id, reselecting: reselecting) { automaticFloats.remove(id) }
    }

    /// Starts dragging one tab out of a group: the next tab takes the leaf
    /// and the dragged window floats until Bento places it. Returns the pane
    /// it came from, or nil for a lone tab, which moves as an ordinary Bento
    /// pane.
    public mutating func tearOff(_ id: WindowID) -> UUID? {
        guard let pane = groups.pane(containing: id), pane.tabs.count > 1,
              let index = logicalIndex(of: id, in: pane), groups.float(id) else { return nil }
        removeReservedIndex(index, in: pane.id)
        automaticFloats.remove(id)
        if pane.selected == id { recordSelection(in: pane.id) }
        return pane.id
    }

    public func paneID(containing id: WindowID) -> UUID? { groups.pane(containing: id)?.id }

    public func pane(containing id: WindowID) -> TabbedPane? {
        guard let paneID = paneID(containing: id) else { return nil }
        return panes.first { $0.id == paneID }
    }

    /// Moves a tab (or a floating window) into a pane at a position and
    /// selects it. Within one pane this only reorders.
    /// - Parameter reselecting: The tab the source pane showed before the
    ///   gesture that selected `id`. It applies only when the tab leaves its
    ///   pane, and only while it is still a member of that pane.
    public mutating func move(_ id: WindowID, to paneID: UUID, at index: Int? = nil, reselecting: WindowID? = nil) {
        guard groups.panes.contains(where: { $0.id == paneID }),
              windowIDs.contains(id) || floatingWindowIDs.contains(id) || returnSlots[id] != nil else { return }
        if groups.pane(containing: id)?.id == paneID, index == nil {
            select(id)
            return
        }
        if let source = groups.pane(containing: id), source.selected == id { recordSelection(in: source.id) }
        recordSelection(in: paneID)
        removeTabPosition(id)
        groups.remove(id, reselecting: reselecting)
        groups.forgetFloating(id)
        automaticFloats.remove(id)
        insertTabPosition(at: index, in: paneID)
        if groups.add(id, to: paneID, at: index) { activePaneID = paneID }
    }

    /// The pane and tab index a window drag adds its window to: a tab strip
    /// or empty pane, or the center of a pane's selected tab, which appends.
    /// Nil when the outcome adds no tab or its pane is gone.
    public func tabDrop(for outcome: BentoDragOutcome) -> (paneID: UUID, index: Int?)? {
        switch outcome {
        case let .tab(paneID, index):
            groups.panes.contains { $0.id == paneID } ? (paneID, index) : nil
        case let .swap(targetWindowID):
            paneID(containing: targetWindowID).map { ($0, nil) }
        case .insert, .snap, .restore:
            nil
        }
    }

    /// Moves a tab into a new pane on one edge of another pane.
    /// - Parameter reselecting: See `move(_:to:at:reselecting:)`.
    public mutating func split(paneID: UUID, moving windowID: WindowID, edge: TabbedEdge, reselecting: WindowID? = nil) {
        guard groups.panes.count < Self.maximumPaneCount,
              groups.panes.contains(where: { $0.id == paneID }),
              windowIDs.contains(windowID) || floatingWindowIDs.contains(windowID) || returnSlots[windowID] != nil else { return }
        if let source = groups.pane(containing: windowID), source.selected == windowID { recordSelection(in: source.id) }
        removeTabPosition(windowID)
        groups.remove(windowID, reselecting: reselecting)
        groups.forgetFloating(windowID)
        automaticFloats.remove(windowID)
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
        rememberPaneSizes(changedFrom: root)
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

    /// Replaces the pane arrangement with a preset. By default, groups keep
    /// their order and overflow groups merge into the nearest pane.
    /// Distribution fills panes in tab order, then adds extra windows as tabs.
    public mutating func applyPreset(_ preset: TabbedPreset, grouping: TabbedPresetGrouping = .keepTabGroups) {
        clearReturnSlots()
        let activeWindow = activeWindowID
        let unit = BTRect(x: 0, y: 0, width: 1000, height: 1000)
        let oldGroups = groups.panes
        let oldFrames = groups.paneFrames(in: unit) ?? [:]
        let kept = Array(oldGroups.prefix(preset.paneCount))
        // Each kept group takes the new pane nearest its old position, so
        // Two Columns to Four Panes keeps left on the left and right on the
        // right instead of filling the first column.
        var paneIDs = (0..<preset.paneCount).map { _ in UUID() }
        var probe = layout
        probe.root = Self.tree(preset, leaves: paneIDs.map { BentoNode.vacant($0) })
        if let probeState = BentoTabbedLayoutState(adopting: probe, contentTopInset: presentation.reservedInset),
           let probeFrames = probeState.paneFrames(in: unit) {
            var free = Set(paneIDs.indices)
            var assigned: [Int: UUID] = [:]
            for group in kept {
                let center = oldFrames[group.id]?.center ?? BTPoint(x: 0, y: 0)
                guard let slot = free.min(by: { a, b in
                    func distance(_ index: Int) -> Double {
                        guard let point = probeFrames[paneIDs[index]]?.center else { return .infinity }
                        return pow(point.x - center.x, 2) + pow(point.y - center.y, 2)
                    }
                    return distance(a) == distance(b) ? a < b : distance(a) < distance(b)
                }) else { break }
                free.remove(slot)
                assigned[slot] = group.id
            }
            for (slot, id) in assigned { paneIDs[slot] = id }
        } else {
            for (index, group) in kept.enumerated() { paneIDs[index] = group.id }
        }
        var empty = layout
        empty.root = Self.tree(preset, leaves: paneIDs.map { BentoNode.vacant($0) })
        guard var next = BentoTabbedLayoutState(adopting: empty, contentTopInset: presentation.reservedInset) else { return }
        if grouping == .distributeWindows {
            // Fill panes once in tab order, then append extra tabs round-robin.
            for (index, id) in oldGroups.flatMap(\.tabs).enumerated() {
                next.add(id, to: paneIDs[index % paneIDs.count], select: false)
            }
            groups = next
            activePaneID = activeWindow.flatMap { next.pane(containing: $0)?.id } ?? paneIDs[0]
            rememberPaneSizes()
            return
        }
        let newFrames = next.paneFrames(in: unit) ?? [:]
        func place(_ group: BentoTabbedPane, into paneID: UUID) {
            for id in group.tabs { next.add(id, to: paneID, select: id == group.selected) }
        }
        for group in kept where paneIDs.contains(group.id) { place(group, into: group.id) }
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
        rememberPaneSizes()
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
        let expected = layout.contentFrames(in: bounds)
        var classifications: [WindowID: ExternalWindowChange] = [:]
        for id in changed.intersection(selectedWindowIDs) {
            guard let expectedFrame = expected[id], let observed = frames[id] else { continue }
            classifications[id] = ExternalWindowChangeClassifier.classify(
                expected: expectedFrame, observed: observed, in: bounds, edgeTolerance: tolerance
            )
        }
        guard case let .fitDividers(ids) = ExternalChangeRouter.route(classifications),
              let fitted = BentoLayoutFitter(tolerance: tolerance).fit(
                  state: layout, currentFrames: frames, changedWindowIDs: ids, in: bounds,
                  constraints: constraints, expectedFrames: expected
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
        contentFrame(pane, presentation: .alwaysVisible)
    }

    public static func contentFrame(_ pane: BTRect, presentation: TabbedStripPresentation) -> BTRect {
        BentoLayoutMetrics(contentTopInset: presentation.reservedInset).windowFrame(forPane: pane)
    }

    /// Every tab takes its pane's window area; hidden tabs stack behind the
    /// selected one. Only selected tabs must fit: a hidden tab never makes a
    /// layout too small.
    public func placements(in bounds: BTRect, windows: [WindowSnapshot]) throws -> [Placement] {
        let snapshots = Dictionary(uniqueKeysWithValues: windows.map { ($0.id, $0) })
        let paneFrames = frames(in: bounds)
        var result: [Placement] = []
        // A hidden tab larger than its pane, for example after its pane
        // shrank, moves back inside the work area, so the curtain, which
        // covers the work area, hides all of it.
        func inside(_ origin: BTPoint, _ size: BTSize) -> BTPoint {
            BTPoint(x: max(bounds.minX, min(origin.x, bounds.maxX - size.width)),
                    y: max(bounds.minY, min(origin.y, bounds.maxY - size.height)))
        }
        for pane in groups.panes {
            guard let paneFrame = paneFrames[pane.id] else { continue }
            let frame = windowArea(paneFrame)
            for id in pane.tabs {
                guard let window = snapshots[id], window.isEligible else { continue }
                guard window.constraints.isResizable else {
                    // A fixed-size window, such as Calculator, keeps its size,
                    // centred in its pane; the backdrop covers the rest.
                    let size = window.frame.size
                    if id == pane.selected,
                       size.width > frame.size.width + 0.001 || size.height > frame.size.height + 0.001 {
                        throw TabbedLayoutError.panesTooSmall
                    }
                    let origin = inside(BTPoint(
                        x: frame.minX + max(0, ((frame.size.width - size.width) / 2).rounded(.down)),
                        y: frame.minY + max(0, ((frame.size.height - size.height) / 2).rounded(.down))), size)
                    result.append(Placement(windowID: id, frame: BTRect(origin: origin, size: size)))
                    continue
                }
                let minimum = window.constraints.minimumSize
                if id == pane.selected {
                    guard frame.size.width + 0.001 >= minimum.width,
                          frame.size.height + 0.001 >= minimum.height
                    else { throw TabbedLayoutError.panesTooSmall }
                }
                // The application keeps at least its minimum, growing from the origin.
                let grown = BTSize(width: max(frame.size.width, minimum.width), height: max(frame.size.height, minimum.height))
                result.append(Placement(windowID: id, frame: BTRect(origin: inside(frame.origin, grown), size: frame.size)))
            }
        }
        return result
    }

    /// Solves the selected tabs' minimum sizes with Bento's solver.
    public func fittingMinimumWidths(in bounds: BTRect, windows: [WindowSnapshot]) throws -> Self {
        guard let fitted = groups.fitted(in: bounds, constraints: Self.fittingConstraints(windows)) else {
            throw TabbedLayoutError.panesTooSmall
        }
        var result = self
        result.groups = fitted
        return result
    }

    /// Fits panes to selected windows that settled up to one resize step
    /// (`SteppedSizeAcceptance.maximumShortfall`) larger or smaller than
    /// their window area, such as Terminal on whole character cells. One pane
    /// edge moves per axis, so the window area matches the settled size; the
    /// neighbour gives or takes the difference above its minimum, across an
    /// unlocked divider. A divider between two such windows stays put, so
    /// neither chases the other. Like any fit, it records no pane sizes.
    /// - Parameter settled: Sizes the selected windows hold now.
    /// - Parameter protecting: Windows whose panes' edges must stay, such as
    ///   other windows known to resize in steps, selected or hidden. The
    ///   windows that settled off their panes are always protected from each
    ///   other's snaps.
    /// - Parameter fixedPaneIDs: Panes whose logical regions must stay exact,
    ///   including when their own selected window settles off its request.
    /// - Returns: Nil when no window needs another write. Otherwise the
    ///   fitted state, its placements, and the snaps. A window larger than its
    ///   area that no edge can follow is asked for more than one step less:
    ///   its settled size minus `maximumShortfall` and 1 point. Any step up
    ///   to that size rounds to a cell inside the pane. A window that still
    ///   keeps its size there refuses it, and the write learns its minimum.
    public func snappingToSteppedSizes(
        _ settled: [WindowID: BTSize], protecting: Set<WindowID> = [], fixedPaneIDs: Set<UUID> = [],
        in bounds: BTRect, windows: [WindowSnapshot]
    ) -> (state: Self, placements: [Placement], snaps: [TabbedSteppedSnap])? {
        let tolerance = 2.0
        let fixedFrames = logicalFrames(in: bounds).filter { fixedPaneIDs.contains($0.key) }
        let constraints = Self.fittingConstraints(windows)
        let resizable = Set(windows.filter(\.constraints.isResizable).map(\.id))
        let slots = layout.contentFrames(in: bounds)
        func extent(_ size: BTSize, _ axis: SplitAxis) -> Double { axis == .vertical ? size.width : size.height }
        // Per axis, how far each stepped window settled from its area.
        var deltas: [WindowID: [SplitAxis: Double]] = [:]
        for id in selectedWindowIDs where resizable.contains(id) {
            guard let slot = slots[id], let size = settled[id] else { continue }
            let axes = [SplitAxis.vertical, .horizontal].map { ($0, extent(size, $0) - extent(slot.size, $0)) }
            guard axes.allSatisfy({ abs($0.1) <= SteppedSizeAcceptance.maximumShortfall }) else { continue }
            let moved = axes.filter { abs($0.1) > tolerance }
            if !moved.isEmpty { deltas[id] = Dictionary(uniqueKeysWithValues: moved) }
        }
        guard !deltas.isEmpty else { return nil }
        // A pane that holds a protected tab, shown or hidden, keeps its edges,
        // so its edges do not move with which tab is selected.
        let pinned = Set(protecting.compactMap { pane(containing: $0)?.selected })
        var result = self
        var snaps: [TabbedSteppedSnap] = []
        var overflow: [WindowID: BTSize] = [:]
        for id in deltas.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            for axis in [SplitAxis.vertical, .horizontal] {
                guard let delta = deltas[id]?[axis] else { continue }
                let current = result.layout.contentFrames(in: bounds)
                guard let slot = current[id] else { continue }
                let grow = axis == .vertical ? BTSize(width: delta, height: 0) : BTSize(width: 0, height: delta)
                let size = BTSize(width: slot.size.width + grow.width, height: slot.size.height + grow.height)
                // The far edge first: the window kept its origin.
                let targets = [BTRect(origin: slot.origin, size: size),
                               BTRect(x: slot.minX - grow.width, y: slot.minY - grow.height,
                                      width: size.width, height: size.height)]
                var snapped = false
                for target in targets {
                    var frames = current
                    frames[id] = target
                    guard let fitted = BentoLayoutFitter(tolerance: 1).fit(
                        state: result.layout, currentFrames: frames, changedWindowIDs: [id],
                        in: bounds, constraints: constraints, expectedFrames: current) else { continue }
                    var candidate = result
                    candidate.groups.synchronize(with: fitted.state)
                    let logical = candidate.logicalFrames(in: bounds)
                    guard fixedFrames.allSatisfy({ logical[$0.key]?.approximatelyEquals($0.value, tolerance: 0.001) == true }) else { continue }
                    let placed = fitted.state.contentFrames(in: bounds)
                    guard placed[id]?.approximatelyEquals(target, tolerance: 0.5) == true,
                          Set(deltas.keys).union(pinned).allSatisfy({ other in
                              other == id || current[other].map { placed[other]?.approximatelyEquals($0, tolerance: 0.5) == true } != false })
                    else { continue }
                    let neighbors = current.keys.filter { $0 != id && placed[$0]?.approximatelyEquals(current[$0]!, tolerance: 0.5) == false }
                    snaps.append(TabbedSteppedSnap(windowID: id, axis: axis, delta: delta,
                                                   neighbors: neighbors.sorted { $0.rawValue < $1.rawValue }))
                    result.groups.synchronize(with: fitted.state)
                    snapped = true
                    break
                }
                if !snapped, delta > 0 {
                    // The pane less this is the settled size less one step and a point.
                    let less = SteppedSizeAcceptance.maximumShortfall + 1 - delta
                    overflow[id, default: .zero] = BTSize(
                        width: overflow[id, default: .zero].width + (axis == .vertical ? less : 0),
                        height: overflow[id, default: .zero].height + (axis == .horizontal ? less : 0))
                }
            }
        }
        guard !snaps.isEmpty || !overflow.isEmpty,
              let placements = try? result.placements(in: bounds, windows: windows) else { return nil }
        let minimums = Dictionary(windows.map { ($0.id, $0.constraints) }, uniquingKeysWith: { first, _ in first })
        let stepped = placements.map { placement -> Placement in
            guard let less = overflow[placement.windowID] else { return placement }
            var frame = placement.frame
            // Never below a minimum the write itself would refuse; a seed is
            // another window's minimum and is not checked.
            let floor = minimums[placement.windowID].flatMap { $0.minimumSizeSource == .seed ? nil : $0.minimumSize } ?? .zero
            frame.size = BTSize(width: max(frame.size.width - less.width, min(frame.size.width, floor.width)),
                                height: max(frame.size.height - less.height, min(frame.size.height, floor.height)))
            return Placement(windowID: placement.windowID, frame: frame)
        }
        return (result, stepped, snaps)
    }

    /// Moves each divider beside a window that resizes in steps, by at most
    /// `SteppedSizeAcceptance.maximumShortfall`, to the closest position where
    /// the most such windows fill their window areas exactly on their grids.
    /// Hidden tabs count too, so a pane keeps its edge whichever tab is
    /// selected. Ties go to the smaller move, then toward the top or left.
    /// Like any fit, it records no pane sizes.
    /// - Parameter grids: Each window's grid per axis: `.vertical` for widths,
    ///   `.horizontal` for heights.
    public func fittingSteppedGrids(
        _ grids: [WindowID: [SplitAxis: SteppedGrid]], in bounds: BTRect, windows: [WindowSnapshot]
    ) -> Self {
        guard !grids.isEmpty else { return self }
        let constraints = Self.fittingConstraints(windows)
        let halfGap = layout.metrics.paneGap / 2
        let reach = SteppedSizeAcceptance.maximumShortfall
        var result = self
        let branches = dividers(in: bounds).sorted {
            ($0.axis.rawValue, $0.coordinate) < ($1.axis.rawValue, $1.coordinate)
        }.compactMap(\.branchID)
        for branch in branches {
            guard let divider = result.dividers(in: bounds).first(where: { $0.branchID == branch }) else { continue }
            let vertical = divider.axis == .vertical
            let frames = result.frames(in: bounds)
            // Each gridded pane beside the divider: its grids, its window
            // area's length across the divider, and +1 before it, -1 after.
            var sides: [(grids: [SteppedGrid], length: Double, sign: Double)] = []
            for pane in result.groups.panes {
                guard let frame = frames[pane.id] else { continue }
                let (low, high) = vertical ? (frame.minX, frame.maxX) : (frame.minY, frame.maxY)
                let (spanLow, spanHigh) = vertical ? (frame.minY, frame.maxY) : (frame.minX, frame.maxX)
                guard min(spanHigh, divider.spanEnd) - max(spanLow, divider.spanStart) > 1 else { continue }
                let sign: Double = abs(high + halfGap - divider.coordinate) <= 1 ? 1
                    : abs(low - halfGap - divider.coordinate) <= 1 ? -1 : 0
                let paneGrids = pane.tabs.compactMap { grids[$0]?[divider.axis] }
                guard sign != 0, !paneGrids.isEmpty else { continue }
                let content = windowArea(frame)
                sides.append((paneGrids, vertical ? content.size.width : content.size.height, sign))
            }
            guard !sides.isEmpty else { continue }
            var moves: Set<Double> = [0]
            for side in sides {
                for grid in side.grids {
                    // One known length can be a minimum the window never
                    // reported, so it only grows a pane that is too small.
                    for length in grid.lengths(near: side.length, within: reach)
                    where grid.step != nil || grid.known.count > 1 || length >= side.length - 0.5 {
                        moves.insert((length - side.length) * side.sign)
                    }
                }
            }
            func fits(_ move: Double) -> Int {
                sides.reduce(0) { count, side in
                    count + side.grids.filter { $0.contains(side.length + side.sign * move) }.count
                }
            }
            let ordered = moves.sorted { (-fits($0), abs($0), $0) < (-fits($1), abs($1), $1) }
            for move in ordered {
                guard abs(move) > 0.5 else { break }
                let target = divider.coordinate + move
                guard let moved = BentoResizeEngine().resize(
                    state: result.layout, branchCoordinates: [branch: target], in: bounds, constraints: constraints),
                    let applied = moved.appliedCoordinates[branch], abs(applied - target) <= 0.5 else { continue }
                result.groups.synchronize(with: moved.state)
                break
            }
        }
        return result
    }

    /// Asks each window that resizes in steps for the largest length on its
    /// grid that fits its window area, so it settles exactly there.
    public static func requestingSteppedGrids(
        _ placements: [Placement], _ grids: [WindowID: [SplitAxis: SteppedGrid]]
    ) -> [Placement] {
        placements.map { placement in
            guard let axes = grids[placement.windowID] else { return placement }
            var frame = placement.frame
            if let width = axes[.vertical]?.request(inside: frame.size.width), width > 0 { frame.size.width = width }
            if let height = axes[.horizontal]?.request(inside: frame.size.height), height > 0 { frame.size.height = height }
            return Placement(windowID: placement.windowID, frame: frame)
        }
    }

    /// Minimum sizes for fitting. A fixed-size window needs a pane whose
    /// window area holds it; the solver adds the tab strip, as for any minimum.
    private static func fittingConstraints(_ windows: [WindowSnapshot]) -> [WindowID: WindowConstraints] {
        Dictionary(windows.map { window -> (WindowID, WindowConstraints) in
            var value = window.constraints
            if !value.isResizable {
                value.minimumSize = BTSize(
                    width: max(value.minimumSize.width, window.frame.size.width),
                    height: max(value.minimumSize.height, window.frame.size.height))
            }
            return (window.id, wholePointMinimumConstraints(value))
        }, uniquingKeysWith: { first, _ in first })
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

/// A whole-point request must meet the original minimum, including its fractional part.
/// Only planning copies change; measured window constraints retain their original values.
private func wholePointMinimumConstraints(_ value: WindowConstraints) -> WindowConstraints {
    let minimum = value.minimumSize
    // Preserve invalid-input rejection: ceiling must not turn -0.1 into valid zero.
    guard minimum.width.isFinite, minimum.height.isFinite,
          minimum.width >= 0, minimum.height >= 0 else { return value }
    var result = value
    result.minimumSize = BTSize(width: minimum.width.rounded(.up), height: minimum.height.rounded(.up))
    return result
}

/// How `TabbedLayoutState.reconcile` placed one new window, with each pane
/// it tried, for the decision log.
public struct TabbedAdoption: Hashable, Sendable {
    public enum Outcome: Hashable, Sendable {
        /// The selected tab of this pane.
        case selected(UUID)
        /// A hidden tab of the other pane that can show it with the least change.
        case hidden(UUID)
        /// A tab restored to its remembered pane and position.
        case returned(UUID)
        case floated(FloatReason)
    }

    public enum FloatReason: String, Hashable, Sendable {
        /// No pane of this layout can show it.
        case fitsNoPane
        case fixedSizeLargerThanWorkArea
        case minimumLargerThanWorkArea
    }

    public enum TrialResult: String, Hashable, Sendable {
        case fits
        case fitsAfterAdapting
        case doesNotFit
        /// The pane did not accept the tab.
        case rejected
    }

    public struct Trial: Hashable, Sendable {
        public var paneID: UUID
        /// The pane's window area before the window joined.
        public var contentFrame: BTRect?
        public var result: TrialResult

        public init(paneID: UUID, contentFrame: BTRect?, result: TrialResult) {
            self.paneID = paneID
            self.contentFrame = contentFrame
            self.result = result
        }
    }

    public var windowID: WindowID
    public var outcome: Outcome
    public var trials: [Trial]

    public init(windowID: WindowID, outcome: Outcome, trials: [Trial]) {
        self.windowID = windowID
        self.outcome = outcome
        self.trials = trials
    }

    public var floated: Bool {
        if case .floated = outcome { return true }
        return false
    }
}

/// A pane edge that moved so a window resizing in steps fills its pane.
public struct TabbedSteppedSnap: Equatable, Sendable {
    public var windowID: WindowID
    /// `.vertical` changes the width, `.horizontal` the height.
    public var axis: SplitAxis
    /// Settled size minus the pane's window area, in points.
    public var delta: Double
    /// Selected windows whose frames changed to give or take the points.
    public var neighbors: [WindowID]
}
