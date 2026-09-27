import Foundation

public enum TabbedPreset: String, Codable, CaseIterable, Sendable {
    case single, columns, rows, focus, grid
    public var title: String {
        switch self {
        case .single: "One Pane"
        case .columns: "Two Columns"
        case .rows: "Two Rows"
        case .focus: "Bento — Focus"
        case .grid: "Four Panes"
        }
    }
    public var paneCount: Int {
        switch self { case .single: 1; case .columns, .rows: 2; case .focus: 3; case .grid: 4 }
    }
}

public struct TabbedPane: Hashable, Sendable, Identifiable {
    public let id: UUID
    public var tabs: [WindowID] = []
    public var selected: WindowID?
    public init(id: UUID = UUID()) { self.id = id }
}

public indirect enum TabbedNode: Hashable, Sendable {
    case pane(UUID)
    case split(id: UUID, vertical: Bool, ratio: Double, first: TabbedNode, second: TabbedNode)

    public var paneIDs: [UUID] {
        switch self {
        case let .pane(id): [id]
        case let .split(_, _, _, first, second): first.paneIDs + second.paneIDs
        }
    }
}

public struct TabbedDivider: Hashable, Sendable, Identifiable {
    public let id: UUID
    public let vertical: Bool
    public let bounds: BTRect
    public let frame: BTRect
    public let ratio: Double
}

/// Pure pane membership and geometry. No window identity is used as pane identity.
public struct TabbedLayoutState: Hashable, Sendable {
    public private(set) var root: TabbedNode
    public private(set) var panes: [TabbedPane]
    public private(set) var activePaneID: UUID
    public private(set) var floatingWindowIDs: Set<WindowID> = []
    public static let headerHeight = 34.0
    /// Edge splits stop at this many panes in the test build.
    public static let maximumPaneCount = 12
    public static let gap = 6.0

    public init(preset: TabbedPreset = .single) {
        let panes = (0..<preset.paneCount).map { _ in TabbedPane() }
        self.panes = panes
        activePaneID = panes[0].id
        root = Self.tree(preset, panes: panes)
    }

    private static func tree(_ preset: TabbedPreset, panes: [TabbedPane]) -> TabbedNode {
        func leaf(_ index: Int) -> TabbedNode { .pane(panes[index].id) }
        func split(_ vertical: Bool, _ first: TabbedNode, _ second: TabbedNode, _ ratio: Double = 0.5) -> TabbedNode {
            .split(id: UUID(), vertical: vertical, ratio: ratio, first: first, second: second)
        }
        switch preset {
        case .single: return leaf(0)
        case .columns: return split(true, leaf(0), leaf(1))
        case .rows: return split(false, leaf(0), leaf(1))
        case .focus: return split(true, leaf(0), split(false, leaf(1), leaf(2)), 0.6)
        case .grid: return split(true, split(false, leaf(0), leaf(1)), split(false, leaf(2), leaf(3)))
        }
    }

    public var windowIDs: Set<WindowID> { Set(panes.flatMap(\.tabs)) }
    public var selectedWindowIDs: [WindowID] { panes.compactMap(\.selected) }
    public var activeWindowID: WindowID? { panes.first { $0.id == activePaneID }?.selected }

    public mutating func activatePane(_ id: UUID) {
        if panes.contains(where: { $0.id == id }) { activePaneID = id }
    }

    public mutating func select(_ windowID: WindowID) {
        guard let index = panes.firstIndex(where: { $0.tabs.contains(windowID) }) else { return }
        panes[index].selected = windowID
        activePaneID = panes[index].id
    }

    /// Absence alone is not closure: the caller supplies authoritative removals.
    public mutating func reconcile(windowIDs observed: [WindowID], removed: Set<WindowID>, focused: WindowID?) {
        for id in removed { remove(id) }
        let known = windowIDs.union(floatingWindowIDs)
        let added = Array(Set(observed).subtracting(known)).sorted()
        if let index = panes.firstIndex(where: { $0.id == activePaneID }) {
            panes[index].tabs += added
            if let last = added.last { panes[index].selected = last }
        }
        if let focused, windowIDs.contains(focused), added.isEmpty || added.contains(focused) { select(focused) }
    }

    public mutating func remove(_ id: WindowID) {
        guard let pane = panes.firstIndex(where: { $0.tabs.contains(id) }),
              let index = panes[pane].tabs.firstIndex(of: id) else { return }
        panes[pane].tabs.remove(at: index)
        if panes[pane].selected == id {
            panes[pane].selected = panes[pane].tabs.isEmpty ? nil : panes[pane].tabs[min(index, panes[pane].tabs.count - 1)]
        }
    }

    /// Removes a window after direct closure evidence, including a floated window.
    public mutating func removeClosedWindow(_ id: WindowID) {
        remove(id)
        floatingWindowIDs.remove(id)
    }

    public mutating func float(_ id: WindowID) {
        guard windowIDs.contains(id) else { return }
        remove(id)
        floatingWindowIDs.insert(id)
    }

    public mutating func move(_ id: WindowID, to paneID: UUID, at index: Int? = nil) {
        guard panes.contains(where: { $0.id == paneID }), windowIDs.contains(id) || floatingWindowIDs.contains(id) else { return }
        remove(id)
        floatingWindowIDs.remove(id)
        guard let destination = panes.firstIndex(where: { $0.id == paneID }) else { return }
        let insertion = min(max(0, index ?? panes[destination].tabs.count), panes[destination].tabs.count)
        panes[destination].tabs.insert(id, at: insertion)
        panes[destination].selected = id
        activePaneID = paneID
    }

    public mutating func applyPreset(_ preset: TabbedPreset) {
        let oldFrames = frames(in: BTRect(x: 0, y: 0, width: 1000, height: 1000))
        let removed = Array(panes.dropFirst(preset.paneCount))
        panes = Array(panes.prefix(preset.paneCount))
        while panes.count < preset.paneCount { panes.append(TabbedPane()) }
        root = Self.tree(preset, panes: panes)
        let newFrames = frames(in: BTRect(x: 0, y: 0, width: 1000, height: 1000))
        for pane in removed {
            let center = oldFrames[pane.id]?.center ?? BTPoint(x: 0, y: 0)
            let destination = panes.indices.min { a, b in
                func distance(_ index: Int) -> Double {
                    let point = newFrames[panes[index].id]!.center
                    return pow(point.x - center.x, 2) + pow(point.y - center.y, 2)
                }
                return distance(a) < distance(b)
            }!
            panes[destination].tabs += pane.tabs
            if panes[destination].selected == nil { panes[destination].selected = pane.selected }
        }
        if !panes.contains(where: { $0.id == activePaneID }) { activePaneID = panes[0].id }
    }

    public mutating func split(paneID: UUID, moving windowID: WindowID, edge: TabbedEdge) {
        guard panes.count < Self.maximumPaneCount, panes.contains(where: { $0.id == paneID }), self.windowIDs.contains(windowID) else { return }
        let pane = TabbedPane()
        func replacing(_ node: TabbedNode) -> TabbedNode {
            switch node {
            case .pane(paneID):
                return .split(id: UUID(), vertical: edge == .left || edge == .right, ratio: 0.5,
                              first: edge == .left || edge == .top ? .pane(pane.id) : node,
                              second: edge == .left || edge == .top ? node : .pane(pane.id))
            case .pane: return node
            case let .split(id, vertical, ratio, first, second):
                return .split(id: id, vertical: vertical, ratio: ratio, first: replacing(first), second: replacing(second))
            }
        }
        root = replacing(root)
        panes.append(pane)
        panes.sort { root.paneIDs.firstIndex(of: $0.id)! < root.paneIDs.firstIndex(of: $1.id)! }
        move(windowID, to: pane.id)
    }

    public mutating func removeEmptyPane(_ id: UUID) {
        guard panes.count > 1, panes.first(where: { $0.id == id })?.tabs.isEmpty == true else { return }
        func removing(_ node: TabbedNode) -> TabbedNode? {
            switch node {
            case let .pane(paneID): return paneID == id ? nil : node
            case let .split(branch, vertical, ratio, first, second):
                let a = removing(first), b = removing(second)
                if let a, let b { return .split(id: branch, vertical: vertical, ratio: ratio, first: a, second: b) }
                return a ?? b
            }
        }
        if let updated = removing(root) { root = updated }
        panes.removeAll { $0.id == id }
        if activePaneID == id { activePaneID = panes[0].id }
    }

    public mutating func resize(dividerID: UUID, ratio: Double) {
        guard ratio.isFinite else { return }
        func replacing(_ node: TabbedNode) -> TabbedNode {
            guard case let .split(id, vertical, oldRatio, first, second) = node else { return node }
            return .split(id: id, vertical: vertical, ratio: id == dividerID ? min(0.95, max(0.05, ratio)) : oldRatio,
                          first: replacing(first), second: replacing(second))
        }
        root = replacing(root)
    }

    public func frames(in bounds: BTRect) -> [UUID: BTRect] { geometry(in: bounds).panes }
    public func dividers(in bounds: BTRect) -> [TabbedDivider] { geometry(in: bounds).dividers }
    public static func contentFrame(_ pane: BTRect) -> BTRect {
        BTRect(x: pane.minX, y: pane.minY + headerHeight, width: pane.size.width, height: max(0, pane.size.height - headerHeight))
    }

    /// Moves side-by-side dividers only as far as required by all member tabs.
    /// Row heights, pane identities, membership, and selection stay unchanged.
    public func fittingMinimumWidths(in bounds: BTRect, windows: [WindowSnapshot]) throws -> Self {
        guard [bounds.minX, bounds.minY, bounds.size.width, bounds.size.height].allSatisfy(\.isFinite),
              !bounds.isEmpty else { throw TabbedLayoutError.panesTooSmall }
        let snapshots = Dictionary(uniqueKeysWithValues: windows.map { ($0.id, $0) })
        var paneMinimums: [UUID: Double] = [:]
        for pane in panes {
            var width = 120.0
            for id in pane.tabs {
                guard let window = snapshots[id], window.isEligible else { continue }
                let minimum = window.constraints.minimumSize
                guard minimum.width.isFinite, minimum.height.isFinite,
                      minimum.width >= 0, minimum.height >= 0 else { throw TabbedLayoutError.panesTooSmall }
                width = max(width, minimum.width)
                if !window.constraints.isResizable { width = max(width, window.frame.size.width) }
            }
            paneMinimums[pane.id] = width
        }
        var branchMinimums: [UUID: (first: Double, second: Double)] = [:]
        func minimumWidth(_ node: TabbedNode) -> Double {
            switch node {
            case let .pane(id): return paneMinimums[id]!
            case let .split(id, vertical, _, first, second):
                let a = minimumWidth(first), b = minimumWidth(second)
                branchMinimums[id] = (a, b)
                return vertical ? a + Self.gap + b : max(a, b)
            }
        }
        guard minimumWidth(root) <= bounds.size.width else { throw TabbedLayoutError.panesTooSmall }
        func fit(_ node: TabbedNode, width: Double) -> TabbedNode {
            guard case let .split(id, vertical, ratio, first, second) = node else { return node }
            let minimums = branchMinimums[id]!
            let available = width - Self.gap
            let adjusted = vertical
                ? min(1 - minimums.second / available, max(minimums.first / available, ratio))
                : ratio
            let firstWidth = vertical ? available * adjusted : width
            let secondWidth = vertical ? available - firstWidth : width
            return .split(id: id, vertical: vertical, ratio: adjusted,
                          first: fit(first, width: firstWidth), second: fit(second, width: secondWidth))
        }
        var result = self
        result.root = fit(root, width: bounds.size.width)
        // Validate height including the tab strip, and exact sizes for fixed windows.
        _ = try result.placements(in: bounds, windows: windows)
        return result
    }

    private func geometry(in bounds: BTRect) -> (panes: [UUID: BTRect], dividers: [TabbedDivider]) {
        var frames: [UUID: BTRect] = [:]
        var dividers: [TabbedDivider] = []
        func walk(_ node: TabbedNode, _ rect: BTRect) {
            switch node {
            case let .pane(id): frames[id] = rect
            case let .split(id, vertical, ratio, first, second):
                let length = max(0, (vertical ? rect.size.width : rect.size.height) - Self.gap)
                let cut = length * ratio
                let a = BTRect(x: rect.minX, y: rect.minY, width: vertical ? cut : rect.size.width, height: vertical ? rect.size.height : cut)
                let b = BTRect(x: vertical ? rect.minX + cut + Self.gap : rect.minX,
                               y: vertical ? rect.minY : rect.minY + cut + Self.gap,
                               width: vertical ? length - cut : rect.size.width, height: vertical ? rect.size.height : length - cut)
                let line = BTRect(x: vertical ? a.maxX : rect.minX, y: vertical ? rect.minY : a.maxY,
                                  width: vertical ? Self.gap : rect.size.width, height: vertical ? rect.size.height : Self.gap)
                dividers.append(TabbedDivider(id: id, vertical: vertical, bounds: rect, frame: line, ratio: ratio))
                walk(first, a); walk(second, b)
            }
        }
        walk(root, bounds)
        return (frames, dividers)
    }

    /// Stacking needs every member contained in its pane, including during shrink.
    public func placements(in bounds: BTRect, windows: [WindowSnapshot]) throws -> [Placement] {
        let snapshots = Dictionary(uniqueKeysWithValues: windows.map { ($0.id, $0) })
        let paneFrames = frames(in: bounds)
        var result: [Placement] = []
        for pane in panes {
            let frame = Self.contentFrame(paneFrames[pane.id]!)
            guard frame.size.width + 0.001 >= 120, frame.size.height >= 80 else { throw TabbedLayoutError.panesTooSmall }
            for id in pane.tabs {
                guard let window = snapshots[id], window.isEligible else { continue }
                guard frame.size.width + 0.001 >= window.constraints.minimumSize.width,
                      frame.size.height >= window.constraints.minimumSize.height,
                      window.constraints.isResizable || frame.size == window.frame.size else { throw TabbedLayoutError.panesTooSmall }
                result.append(Placement(windowID: id, frame: frame))
            }
        }
        return result
    }
}

public enum TabbedEdge: String, CaseIterable, Sendable { case left, right, top, bottom }
public enum TabbedLayoutError: Error, LocalizedError {
    case panesTooSmall
    public var errorDescription: String? { "This layout is too small for one or more windows. Enlarge the pane or choose fewer panes." }
}
