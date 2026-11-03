import Foundation

/// Pure geometry and edits for the Saved Layouts canvas. Positions are fractions of a
/// 1200 × 750 reference work area. Every function returns a new value; none writes a file.

public enum SavedLayoutSide: String, CaseIterable, Sendable {
    case left, right, top, bottom
    public var axis: SplitAxis { self == .left || self == .right ? .vertical : .horizontal }
    public var isLeading: Bool { self == .left || self == .top }
}

public enum SavedLayoutDirection: Sendable { case left, right, up, down }

public struct SavedLayoutCanvasError: Error, LocalizedError, Equatable, Sendable {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public struct SavedLayoutLeaf: Equatable, Sendable, Identifiable {
    public var path: [Int]
    public var node: SavedLayoutNode
    public var rect: NormalizedRect
    public var id: String { SavedLayoutCanvas.identifier(path) }
}

/// One divider of one split. `lower...upper` is the range it can move, as a cumulative share of the split.
public struct SavedLayoutDivider: Equatable, Sendable, Identifiable {
    public var path: [Int]
    public var index: Int
    public var axis: SplitAxis
    /// The rectangle of the split that owns this divider.
    public var span: NormalizedRect
    /// Work-area length that the split's shares divide, without pane gaps.
    public var travel: Double
    public var gap: Double
    public var before: Double
    public var pair: Double
    public var current: Double
    public var lower: Double
    public var upper: Double
    public var id: String { SavedLayoutCanvas.identifier(path) + "|" + String(index) }
    public var firstShare: Double { current - before }
    public var secondShare: Double { before + pair - current }
    public var canMove: Bool { upper - lower > 1e-9 }

    /// Where the divider sits along its axis when it divides the split at `share`.
    public func position(atShare share: Double) -> Double {
        (axis == .vertical ? span.x : span.y) + share * travel + Double(index) * gap + gap / 2
    }
    public var position: Double { position(atShare: current) }
}

public struct SavedLayoutSnap: Equatable, Sendable {
    public var fraction: Double
    public var label: String
}

public struct SavedLayoutShape: Equatable, Sendable {
    public var id: String
    public var name: String
    public var detail: String?
    public var preset: TabbedPreset?
}

public enum SavedLayoutDragItem: Equatable, Sendable {
    case pane([Int])
    case app(bundleID: String)
}

public enum SavedLayoutDropTarget: Equatable, Sendable {
    case pane([Int])
    case paneEdge([Int], SavedLayoutSide)
    case canvasEdge(SavedLayoutSide)
    case palette
}

public struct SavedLayoutEdit: Equatable, Sendable {
    public var document: SavedLayoutDocument
    /// The pane to select afterwards.
    public var selection: [Int]?
    public var summary: String
}

public enum SavedLayoutOutcome: Equatable, Sendable {
    case change(SavedLayoutEdit)
    case unchanged(String)
    case rejected(String)
}

public struct SavedLayoutDropPlan: Equatable, Sendable {
    public var label: String
    public var preview: NormalizedRect?
    public var isCanvasEdge: Bool
    public var outcome: SavedLayoutOutcome
    public var target: SavedLayoutDropTarget?
    public var rejection: String? { if case let .rejected(reason) = outcome { reason } else { nil } }
}

public enum SavedLayoutCanvas {
    public static let referenceWidth = 1200.0
    public static let referenceHeight = 750.0
    /// Smallest pane the editor allows, as a fraction of the work area. A real window can need more.
    public static let minimumWidth = 0.10
    public static let minimumHeight = 0.12
    public static let snapDistance = 8.0
    public static let maximumAdaptiveApps = 6
    public static let history = 100
    public static let nudgeCoalescingInterval = 1.2
    public static let snapPoints: [SavedLayoutSnap] = [
        .init(fraction: 1.0 / 4, label: "¼"), .init(fraction: 1.0 / 3, label: "⅓"), .init(fraction: 1.0 / 2, label: "½"),
        .init(fraction: 2.0 / 3, label: "⅔"), .init(fraction: 3.0 / 4, label: "¾"),
    ]
    static let unit = NormalizedRect(x: 0, y: 0, width: 1, height: 1)

    public static func identifier(_ path: [Int]) -> String { path.map(String.init).joined(separator: ".") }

    // MARK: Tree

    private static func walk(_ node: SavedLayoutNode, _ rect: NormalizedRect, _ path: [Int], _ paneGap: Double,
                             leaf: (SavedLayoutLeaf) -> Void, divider: (SavedLayoutDivider) -> Void) {
        guard case let .split(axis, ratios, children) = node else {
            leaf(.init(path: path, node: node, rect: rect)); return
        }
        let vertical = axis == .vertical
        let gap = paneGap / (vertical ? referenceWidth : referenceHeight)
        let extent = vertical ? rect.width : rect.height
        let travel = max(0, extent - gap * Double(children.count - 1))
        var offset = vertical ? rect.x : rect.y
        var cumulative = 0.0
        for (index, child) in children.enumerated() {
            let length = travel * ratios[index]
            walk(child, NormalizedRect(x: vertical ? offset : rect.x, y: vertical ? rect.y : offset,
                                       width: vertical ? length : rect.width, height: vertical ? rect.height : length),
                 path + [index], paneGap, leaf: leaf, divider: divider)
            offset += length
            cumulative += ratios[index]
            guard index < children.count - 1 else { continue }
            let pair = ratios[index] + ratios[index + 1]
            let before = cumulative - ratios[index]
            let first = minimumExtent(child, axis: axis) / max(extent, 1e-9)
            let second = minimumExtent(children[index + 1], axis: axis) / max(extent, 1e-9)
            var lower = before + first, upper = before + pair - second
            if lower > upper { lower = cumulative; upper = cumulative }
            divider(.init(path: path, index: index, axis: axis, span: rect, travel: travel, gap: gap, before: before,
                          pair: pair, current: cumulative, lower: lower, upper: upper))
            offset += gap
        }
    }

    public static func leaves(_ root: SavedLayoutNode, paneGap: Double = 0) -> [SavedLayoutLeaf] {
        var result: [SavedLayoutLeaf] = []
        walk(root, unit, [], paneGap, leaf: { result.append($0) }, divider: { _ in })
        return result
    }

    public static func dividers(_ root: SavedLayoutNode, paneGap: Double = 0) -> [SavedLayoutDivider] {
        var result: [SavedLayoutDivider] = []
        walk(root, unit, [], paneGap, leaf: { _ in }, divider: { result.append($0) })
        return result
    }

    /// A split holds no direct child split on its own axis, so the minimum adds up along the axis and
    /// takes the largest child across it.
    public static func minimumExtent(_ node: SavedLayoutNode, axis: SplitAxis) -> Double {
        guard case let .split(nodeAxis, _, children) = node else { return axis == .vertical ? minimumWidth : minimumHeight }
        let values = children.map { minimumExtent($0, axis: axis) }
        return nodeAxis == axis ? values.reduce(0, +) : values.max() ?? 0
    }

    /// The rectangle a node fills, as a fraction of the work area.
    public static func rect(at path: [Int], in root: SavedLayoutNode, paneGap: Double = 0) -> NormalizedRect? {
        var node = root, rect = unit
        for index in path {
            guard case let .split(axis, ratios, children) = node, children.indices.contains(index) else { return nil }
            let vertical = axis == .vertical
            let gap = paneGap / (vertical ? referenceWidth : referenceHeight)
            let travel = max(0, (vertical ? rect.width : rect.height) - gap * Double(children.count - 1))
            let offset = (vertical ? rect.x : rect.y) + travel * ratios[..<index].reduce(0, +) + gap * Double(index)
            let length = travel * ratios[index]
            rect = NormalizedRect(x: vertical ? offset : rect.x, y: vertical ? rect.y : offset,
                                  width: vertical ? length : rect.width, height: vertical ? rect.height : length)
            node = children[index]
        }
        return rect
    }

    /// Gives one child of a split `share` of it. The share is clamped so every child keeps the
    /// editor's minimum size. The other children keep their relative proportions; a child that
    /// would fall below its minimum stays at the minimum, and children with no share left split
    /// the rest equally.
    public static func settingShare(in root: SavedLayoutNode, path: [Int], child: Int, to share: Double,
                                    paneGap: Double = 0) throws -> SavedLayoutNode {
        let changed = SavedLayoutCanvasError("The layout changed. Select this split again.")
        guard share.isFinite, case let .split(axis, ratios, children)? = node(at: path, in: root),
              ratios.indices.contains(child), let rect = rect(at: path, in: root, paneGap: paneGap) else { throw changed }
        let extent = max(axis == .vertical ? rect.width : rect.height, 1e-9)
        let minimums = children.map { minimumExtent($0, axis: axis) / extent }
        let others = ratios.indices.filter { $0 != child }
        let upper = 1 - others.reduce(0) { $0 + minimums[$1] }
        guard minimums[child] <= upper else {
            throw SavedLayoutCanvasError("This split has no room to change. Remove a pane first.")
        }
        var result = ratios
        result[child] = min(max(share, minimums[child]), upper)
        var rest = 1 - result[child]
        var free = others
        while !free.isEmpty {
            let weight = free.reduce(0) { $0 + ratios[$1] }
            let proposed = free.map { weight > 1e-9 ? rest * ratios[$0] / weight : rest / Double(free.count) }
            let short = zip(free, proposed).filter { $0.1 < minimums[$0.0] - 1e-12 }.map(\.0)
            guard !short.isEmpty else {
                for (index, value) in zip(free, proposed) { result[index] = value }
                break
            }
            for index in short { result[index] = minimums[index]; rest -= minimums[index] }
            free.removeAll { short.contains($0) }
        }
        // Absorb rounding so the shares add up to exactly 1.
        if let last = others.last { result[last] += 1 - result.reduce(0, +) }
        return replacing(root, at: path, with: .split(axis: axis, ratios: result, children: children))
    }

    public static func node(at path: [Int], in root: SavedLayoutNode) -> SavedLayoutNode? {
        guard let index = path.first else { return root }
        guard case let .split(_, _, children) = root, children.indices.contains(index) else { return nil }
        return node(at: Array(path.dropFirst()), in: children[index])
    }

    /// Replaces the node at `path`, then flattens. This is the one rule that keeps same-axis splits merged.
    public static func replacing(_ node: SavedLayoutNode, at path: [Int], with replacement: SavedLayoutNode) -> SavedLayoutNode {
        guard let index = path.first else { return replacement }
        guard case let .split(axis, ratios, originalChildren) = node, originalChildren.indices.contains(index) else { return node }
        var children = originalChildren
        children[index] = replacing(children[index], at: Array(path.dropFirst()), with: replacement)
        return normalized(.split(axis: axis, ratios: ratios, children: children))
    }

    public static func normalized(_ node: SavedLayoutNode) -> SavedLayoutNode {
        guard case let .split(axis, ratios, children) = node else { return node }
        var flatChildren: [SavedLayoutNode] = []
        var flatRatios: [Double] = []
        for (child, ratio) in zip(children, ratios) {
            if case let .split(innerAxis, innerRatios, innerChildren) = normalized(child), innerAxis == axis {
                flatChildren += innerChildren
                flatRatios += innerRatios.map { $0 * ratio }
            } else { flatChildren.append(normalized(child)); flatRatios.append(ratio) }
        }
        return .split(axis: axis, ratios: flatRatios, children: flatChildren)
    }

    /// Removes a pane. The others share its room in proportion; a split left with one child collapses.
    /// Returns nil for the root, which has no sibling to take its room.
    public static func removing(_ path: [Int], from node: SavedLayoutNode) -> SavedLayoutNode? {
        guard let index = path.first else { return nil }
        guard case let .split(axis, oldRatios, oldChildren) = node, oldChildren.indices.contains(index) else { return node }
        var children = oldChildren, ratios = oldRatios
        if path.count == 1 { children.remove(at: index); ratios.remove(at: index) }
        else if let child = removing(Array(path.dropFirst()), from: children[index]) { children[index] = child }
        if children.count == 1 { return children[0] }
        let sum = ratios.reduce(0, +)
        return normalized(.split(axis: axis, ratios: ratios.map { $0 / sum }, children: children))
    }

    private static func setting(_ node: SavedLayoutNode, at path: [Int], to leaf: SavedLayoutNode) -> SavedLayoutNode {
        guard let index = path.first, case let .split(axis, ratios, children) = node, children.indices.contains(index) else { return leaf }
        var next = children
        next[index] = setting(children[index], at: Array(path.dropFirst()), to: leaf)
        return .split(axis: axis, ratios: ratios, children: next)
    }

    /// Exchanges two panes' content. The tree and its ratios do not change.
    public static func swapLeaves(_ root: SavedLayoutNode, _ a: [Int], _ b: [Int]) -> SavedLayoutNode? {
        guard a != b, let first = node(at: a, in: root), let second = node(at: b, in: root) else { return nil }
        return setting(setting(root, at: a, to: second), at: b, to: first)
    }

    public static func slotIDs(in node: SavedLayoutNode, document: SavedLayoutDocument) -> [String] {
        switch node {
        case let .slot(id): [id]
        case let .group(id): document.groups.first { $0.id == id }?.slots ?? []
        case .empty: []
        case let .split(_, _, children): children.flatMap { slotIDs(in: $0, document: document) }
        }
    }

    // MARK: Dividers

    private static func round4(_ value: Double) -> Double { (value * 1e4).rounded() / 1e4 }

    /// Moves one divider. Only its two neighbors change, and together they keep their sum.
    public static func movingDivider(in root: SavedLayoutNode, path: [Int], index: Int, to share: Double,
                                     paneGap: Double = 0) throws -> SavedLayoutNode {
        guard let divider = dividers(root, paneGap: paneGap).first(where: { $0.path == path && $0.index == index }) else {
            throw SavedLayoutCanvasError("The layout changed. Select this divider again.")
        }
        // A divider with no room keeps its shares. Rounding an imported tiny share could make it 0.
        guard divider.canMove else { return root }
        let first = round4(min(divider.upper, max(divider.lower, share)) - divider.before)
        let onGrid = abs(divider.pair * 1e4 - (divider.pair * 1e4).rounded()) < 1e-6
        let second = onGrid ? round4(divider.pair - first) : divider.pair - first
        return try rewriting(root, path: path) { axis, ratios, children in
            var next = ratios
            next[index] = first; next[index + 1] = second
            return .split(axis: axis, ratios: next, children: children)
        }
    }

    public static func equalizingDivider(in root: SavedLayoutNode, path: [Int], index: Int, paneGap: Double = 0) throws -> SavedLayoutNode {
        guard let divider = dividers(root, paneGap: paneGap).first(where: { $0.path == path && $0.index == index }) else {
            throw SavedLayoutCanvasError("The layout changed. Select this divider again.")
        }
        return try movingDivider(in: root, path: path, index: index, to: divider.before + divider.pair / 2, paneGap: paneGap)
    }

    private static func rewriting(_ node: SavedLayoutNode, path: [Int],
                                  _ change: (SplitAxis, [Double], [SavedLayoutNode]) -> SavedLayoutNode) throws -> SavedLayoutNode {
        guard case let .split(axis, ratios, children) = node else { throw SavedLayoutCanvasError("The layout changed. Select this divider again.") }
        guard let first = path.first else { return change(axis, ratios, children) }
        guard children.indices.contains(first) else { throw SavedLayoutCanvasError("The layout changed. Select this divider again.") }
        var next = children
        next[first] = try rewriting(children[first], path: Array(path.dropFirst()), change)
        return .split(axis: axis, ratios: ratios, children: next)
    }

    /// The nearest snap point inside the divider's range and within 8 points. `enabled` is false while Option is held.
    public static func snap(_ share: Double, for divider: SavedLayoutDivider, travelPoints: Double, enabled: Bool = true) -> SavedLayoutSnap? {
        guard enabled, travelPoints > 0 else { return nil }
        var best: (SavedLayoutSnap, Double)?
        for point in snapPoints where point.fraction >= divider.lower - 1e-9 && point.fraction <= divider.upper + 1e-9 {
            let distance = abs(share - point.fraction) * travelPoints
            if distance <= snapDistance, distance < (best?.1 ?? .infinity) { best = (point, distance) }
        }
        return best?.0
    }

    // MARK: Shape name

    public static func shape(_ root: SavedLayoutNode) -> SavedLayoutShape {
        func isLeaf(_ node: SavedLayoutNode) -> Bool { if case .split = node { false } else { true } }
        func equal(_ ratios: [Double]) -> Bool { ratios.allSatisfy { abs($0 - 1 / Double(ratios.count)) <= 0.005 } }
        guard case let .split(axis, ratios, children) = root else { return .init(id: "single", name: "Single Pane", detail: nil, preset: .single) }
        let count = children.count, noun = axis == .vertical ? "Columns" : "Rows"
        if children.allSatisfy(isLeaf), equal(ratios) {
            return .init(id: "\(noun.lowercased())-\(count)", name: "\(count) \(noun)", detail: nil,
                         preset: count == 2 ? (axis == .vertical ? .columns : .rows) : nil)
        }
        var inner: [(SplitAxis, [Double], [SavedLayoutNode])] = []
        for child in children { if case let .split(a, r, c) = child { inner.append((a, r, c)) } }
        if inner.count == count, equal(ratios), let rows = inner.first?.2.count,
           inner.allSatisfy({ $0.0 != axis && $0.2.allSatisfy(isLeaf) && equal($0.1) && $0.2.count == rows }) {
            let columns = axis == .vertical ? count : rows, rowCount = axis == .vertical ? rows : count
            return .init(id: "grid-\(columns)x\(rowCount)", name: "\(columns)×\(rowCount) Grid",
                         detail: "\(columns) columns, \(rowCount) rows", preset: columns == 2 && rowCount == 2 ? .grid : nil)
        }
        if count == 2 {
            let main = isLeaf(children[0]) ? 0 : isLeaf(children[1]) ? 1 : -1
            if main >= 0, case let .split(otherAxis, otherRatios, others) = children[1 - main], otherAxis != axis,
               others.allSatisfy(isLeaf), equal(otherRatios), ratios[main] >= 0.5 - 0.005 {
                let side = axis == .vertical ? (main == 0 ? "" : "Right") : (main == 0 ? "Top" : "Bottom")
                return .init(id: "main\(side.isEmpty ? "" : "-" + side.lowercased())+\(others.count)",
                             name: "Main\(side.isEmpty ? "" : " " + side) + \(others.count)", detail: nil,
                             preset: side.isEmpty && others.count == 2 ? .focus : nil)
            }
        }
        return .init(id: "custom", name: "Custom", detail: nil, preset: nil)
    }

    // MARK: Limits

    public static func problem(in document: SavedLayoutDocument, checkingMinimumSize: Bool = false) -> String? {
        guard let root = document.layout else { return nil }
        var nodes = 0, depth = 0
        func count(_ node: SavedLayoutNode, _ level: Int) {
            nodes += 1; depth = max(depth, level)
            if case let .split(_, _, children) = node { children.forEach { count($0, level + 1) } }
        }
        count(root, 1)
        let panes = leaves(root, paneGap: 0)
        if document.mode == .bento, panes.filter({ if case .slot = $0.node { true } else { false } }).count > maximumAdaptiveApps {
            return "Adaptive holds up to \(maximumAdaptiveApps) apps."
        }
        if document.mode == .tabbed, panes.count > TabbedLayoutState.maximumPaneCount {
            return "Tabbed holds up to \(TabbedLayoutState.maximumPaneCount) panes."
        }
        if nodes > SavedLayoutValidator.maximumNodes { return "A layout holds up to \(SavedLayoutValidator.maximumNodes) panes and splits." }
        if depth > SavedLayoutValidator.maximumTreeDepth { return "A layout nests up to \(SavedLayoutValidator.maximumTreeDepth) levels." }
        if checkingMinimumSize, panes.contains(where: { $0.rect.width < minimumWidth - 1e-6 || $0.rect.height < minimumHeight - 1e-6 }) {
            return "Not enough room: a pane would be smaller than \(Int(minimumWidth * 100))% × \(Int(minimumHeight * 100))% of the work area."
        }
        return nil
    }

    // MARK: Hit testing and keyboard focus

    /// Maps a pointer position inside the canvas to a drop target. Positions outside by more than 24 points miss.
    public static func dropTarget(x: Double, y: Double, width: Double, height: Double, leaves: [SavedLayoutLeaf]) -> SavedLayoutDropTarget? {
        guard width > 0, height > 0, !leaves.isEmpty else { return nil }
        let slack = 24.0
        guard x >= -slack, x <= width + slack, y >= -slack, y <= height + slack else { return nil }
        let px = min(max(x, 0), width), py = min(max(y, 0), height)
        let bandX = min(max(0.06 * width, 16), 36), bandY = min(max(0.06 * height, 14), 28)
        let edges: [(Double, SavedLayoutSide)] = [(px / bandX, .left), ((width - px) / bandX, .right), (py / bandY, .top), ((height - py) / bandY, .bottom)]
        if let nearest = edges.min(by: { $0.0 < $1.0 }), nearest.0 < 1 { return .canvasEdge(nearest.1) }
        let fx = px / width, fy = py / height
        let leaf = leaves.first { fx >= $0.rect.x && fx <= $0.rect.x + $0.rect.width && fy >= $0.rect.y && fy <= $0.rect.y + $0.rect.height }
            ?? leaves.min { distance(fx, fy, $0.rect) < distance(fx, fy, $1.rect) }
        guard let leaf else { return nil }
        let w = leaf.rect.width * width, h = leaf.rect.height * height
        let lx = px - leaf.rect.x * width, ly = py - leaf.rect.y * height
        let zoneX = min(max(0.28 * w, 14), 72), zoneY = min(max(0.28 * h, 12), 56)
        let zones: [(Double, SavedLayoutSide)] = [(lx / zoneX, .left), ((w - lx) / zoneX, .right), (ly / zoneY, .top), ((h - ly) / zoneY, .bottom)]
        if let nearest = zones.min(by: { $0.0 < $1.0 }), nearest.0 < 1 { return .paneEdge(leaf.path, nearest.1) }
        return .pane(leaf.path)
    }

    private static func distance(_ x: Double, _ y: Double, _ r: NormalizedRect) -> Double {
        hypot(min(max(x, r.x), r.x + r.width) - x, min(max(y, r.y), r.y + r.height) - y)
    }

    /// The pane next to `path` in `direction`: nearest across the gap, then largest overlap.
    public static func neighbor(of path: [Int], _ direction: SavedLayoutDirection, in leaves: [SavedLayoutLeaf]) -> [Int]? {
        guard let me = leaves.first(where: { $0.path == path })?.rect else { return nil }
        let eps = 1e-6
        var best: (path: [Int], gap: Double, overlap: Double)?
        for other in leaves where other.path != path {
            let r = other.rect
            let horizontal = direction == .left || direction == .right
            let adjacent = switch direction {
            case .right: r.x >= me.x + me.width - eps
            case .left: r.x + r.width <= me.x + eps
            case .down: r.y >= me.y + me.height - eps
            case .up: r.y + r.height <= me.y + eps
            }
            guard adjacent else { continue }
            let overlap = horizontal ? min(me.y + me.height, r.y + r.height) - max(me.y, r.y)
                : min(me.x + me.width, r.x + r.width) - max(me.x, r.x)
            guard overlap > eps else { continue }
            let gap = switch direction {
            case .right: r.x - (me.x + me.width)
            case .left: me.x - (r.x + r.width)
            case .down: r.y - (me.y + me.height)
            case .up: me.y - (r.y + r.height)
            }
            if let current = best, gap > current.gap + eps || (abs(gap - current.gap) <= eps && overlap <= current.overlap) { continue }
            best = (other.path, gap, overlap)
        }
        return best?.path
    }

    // MARK: Edits on a document

    public static func defaultName(_ bundleID: String) -> String { bundleID.split(separator: ".").last.map(String.init) ?? bundleID }
    public static func defaultID(_ prefix: String) -> String { prefix + "-" + UUID().uuidString.lowercased() }

    private static func title(of node: SavedLayoutNode, in document: SavedLayoutDocument, names: (String) -> String) -> String? {
        let ids = slotIDs(in: node, document: document)
        guard let first = ids.first, let bundle = document.slots.first(where: { $0.id == first })?.prefer.compactMap({ if case let .app(id) = $0 { id } else { nil } }).first else { return nil }
        return names(bundle) + (ids.count > 1 ? " + \(ids.count - 1)" : "")
    }

    /// A new pane takes a slot in Adaptive and its own group in Tabbed.
    private static func newLeaf(for bundleID: String? = nil, in document: inout SavedLayoutDocument, makeID: (String) -> String) -> SavedLayoutNode {
        let slot = makeID("slot")
        document.slots.append(.init(id: slot, prefer: bundleID.map { [.app($0)] } ?? []))
        guard document.mode == .tabbed else { return .slot(slot) }
        let group = makeID("group")
        document.groups.append(.init(id: group, slots: [slot], selected: slot))
        return .group(group)
    }

    /// Frees the slots (and group) that a pane held.
    private static func release(_ node: SavedLayoutNode, from document: inout SavedLayoutDocument) {
        let ids = Set(slotIDs(in: node, document: document))
        document.slots.removeAll { ids.contains($0.id) }
        if case let .group(group) = node { document.groups.removeAll { $0.id == group } }
    }

    private static func strip(_ rect: NormalizedRect, _ side: SavedLayoutSide, share: Double) -> NormalizedRect {
        side.axis == .vertical
            ? .init(x: side.isLeading ? rect.x : rect.x + rect.width * (1 - share), y: rect.y, width: rect.width * share, height: rect.height)
            : .init(x: rect.x, y: side.isLeading ? rect.y : rect.y + rect.height * (1 - share), width: rect.width, height: rect.height * share)
    }

    private static func wrapped(_ target: SavedLayoutNode, _ side: SavedLayoutSide, with new: SavedLayoutNode, share: Double) -> SavedLayoutNode {
        .split(axis: side.axis, ratios: side.isLeading ? [share, 1 - share] : [1 - share, share],
               children: side.isLeading ? [new, target] : [target, new])
    }

    /// A new column or row at the canvas edge takes 1/(n+1) when the root already splits that way, else a third.
    public static func canvasEdgeShare(_ root: SavedLayoutNode, _ side: SavedLayoutSide) -> Double {
        if case let .split(axis, _, children) = root, axis == side.axis { return 1 / Double(children.count + 1) }
        return 1.0 / 3
    }

    private static func finish(_ document: SavedLayoutDocument, _ original: SavedLayoutDocument, selecting node: SavedLayoutNode?,
                               summary: String, checkingMinimumSize: Bool) -> SavedLayoutOutcome {
        if let problem = problem(in: document, checkingMinimumSize: checkingMinimumSize) { return .rejected(problem) }
        if document == original { return .unchanged(summary) }
        let selection = node.flatMap { selected in document.layout.flatMap { leaves($0).first { $0.node == selected }?.path } }
        return .change(.init(document: document, selection: selection, summary: summary))
    }

    /// What dropping `item` on `target` would do, with the rectangle to preview. Nothing is written.
    public static func plan(_ item: SavedLayoutDragItem, onto target: SavedLayoutDropTarget, in document: SavedLayoutDocument,
                            names: (String) -> String = defaultName, makeID: (String) -> String = defaultID) -> SavedLayoutDropPlan {
        var result = makePlan(item, onto: target, in: document, names: names, makeID: makeID)
        result.target = target
        return result
    }

    private static func makePlan(_ item: SavedLayoutDragItem, onto target: SavedLayoutDropTarget, in document: SavedLayoutDocument,
                                 names: (String) -> String, makeID: (String) -> String) -> SavedLayoutDropPlan {
        func reject(_ reason: String, preview: NormalizedRect? = nil) -> SavedLayoutDropPlan {
            .init(label: reason, preview: preview, isCanvasEdge: false, outcome: .rejected(reason))
        }
        guard document.mode != .manual, let root = document.layout else {
            return reject("Dragging edits Adaptive and Tabbed layouts.")
        }
        let panes = leaves(root, paneGap: document.paneGap)
        func number(_ path: [Int]) -> Int { (panes.firstIndex { $0.path == path } ?? 0) + 1 }
        var moved: SavedLayoutNode?
        let appName: String
        switch item {
        case let .pane(path):
            guard let leaf = panes.first(where: { $0.path == path }), leaf.node != .empty,
                  let name = title(of: leaf.node, in: document, names: names) else {
                return reject("This pane has no app to move.")
            }
            moved = leaf.node; appName = name
        case let .app(bundleID): appName = names(bundleID)
        }
        var next = document

        switch target {
        case .palette:
            guard case let .pane(path) = item, let leaf = panes.first(where: { $0.path == path }) else {
                return .init(label: "", preview: nil, isCanvasEdge: false, outcome: .unchanged(""))
            }
            return .init(label: "Unassign \(appName)", preview: nil, isCanvasEdge: false,
                         outcome: removingApps(slotIDs(in: leaf.node, document: document), from: document).withSelection(path))

        case let .pane(destination):
            guard let leaf = panes.first(where: { $0.path == destination }) else { return reject("The layout changed. Try the drop again.") }
            let occupant = title(of: leaf.node, in: document, names: names)
            if case let .pane(source) = item {
                guard source != destination else {
                    return .init(label: "Drop on another pane", preview: leaf.rect, isCanvasEdge: false, outcome: .unchanged("Drop on another pane."))
                }
                next.layout = swapLeaves(root, source, destination)
                let label = occupant.map { "Swap \(appName) with \($0)" } ?? "Move \(appName) to pane \(number(destination))"
                let summary = occupant.map { "Swapped \(appName) with \($0)." } ?? "Moved \(appName) to pane \(number(destination))."
                return .init(label: label, preview: leaf.rect, isCanvasEdge: false,
                             outcome: finish(next, document, selecting: nil, summary: summary, checkingMinimumSize: false).withSelection(destination))
            }
            guard case let .app(bundleID) = item else { return reject("") }
            switch leaf.node {
            case let .slot(id):
                guard let index = next.slots.firstIndex(where: { $0.id == id }) else { return reject("The layout changed. Try the drop again.") }
                if next.slots[index].prefer.compactMap({ if case let .app(id) = $0 { id } else { nil } }).first == bundleID {
                    return .init(label: "\(appName) is already here", preview: leaf.rect, isCanvasEdge: false, outcome: .unchanged("\(appName) is already in this pane."))
                }
                next.slots[index].prefer = [.app(bundleID)]
                return .init(label: "Replace \(occupant ?? "app") with \(appName)", preview: leaf.rect, isCanvasEdge: false,
                             outcome: finish(next, document, selecting: nil, summary: "Replaced \(occupant ?? "the app") with \(appName).", checkingMinimumSize: false)
                                .withSelection(destination))
            case let .group(id):
                guard let index = next.groups.firstIndex(where: { $0.id == id }) else { return reject("The layout changed. Try the drop again.") }
                if next.groups[index].slots.count == 1, let id = next.groups[index].slots.first,
                   let slot = next.slots.firstIndex(where: { $0.id == id && $0.prefer.isEmpty }) {
                    next.slots[slot].prefer = [.app(bundleID)]
                    return .init(label: "Assign \(appName) to pane \(number(destination))", preview: leaf.rect, isCanvasEdge: false,
                                 outcome: finish(next, document, selecting: nil, summary: "Assigned \(appName) to pane \(number(destination)).", checkingMinimumSize: false)
                                    .withSelection(destination))
                }
                let slot = makeID("slot")
                next.slots.append(.init(id: slot, bundleID: bundleID))
                next.groups[index].slots.append(slot); next.groups[index].selected = slot
                return .init(label: "Add \(appName) as a tab", preview: leaf.rect, isCanvasEdge: false,
                             outcome: finish(next, document, selecting: nil, summary: "Added \(appName) as a tab.", checkingMinimumSize: false)
                                .withSelection(destination))
            default:
                let fresh = newLeaf(for: bundleID, in: &next, makeID: makeID)
                next.layout = setting(root, at: destination, to: fresh)
                return .init(label: "Assign \(appName) to pane \(number(destination))", preview: leaf.rect, isCanvasEdge: false,
                             outcome: finish(next, document, selecting: nil, summary: "Assigned \(appName) to pane \(number(destination)).", checkingMinimumSize: false)
                                .withSelection(destination))
            }

        case .paneEdge, .canvasEdge:
            let side: SavedLayoutSide, destination: [Int]?
            switch target {
            case let .paneEdge(path, s): side = s; destination = path
            case let .canvasEdge(s): side = s; destination = nil
            default: return reject("The layout changed. Try the drop again.")
            }
            if let destination, !panes.contains(where: { $0.path == destination }) { return reject("The layout changed. Try the drop again.") }
            let share = destination == nil ? canvasEdgeShare(root, side) : 0.5
            let area = destination.flatMap { path in panes.first { $0.path == path }?.rect } ?? unit
            let preview = strip(area, side, share: share)
            let word = side.axis == .vertical ? "column" : "row"
            let label = destination == nil ? "New \(word) at the \(side.rawValue) edge"
                : "Split pane \(number(destination ?? [])): \(appName) in new \(side.rawValue) pane"
            // A moved pane is marked in place, so paths stay valid until the new pane exists.
            let marker = SavedLayoutNode.slot("\u{1}moving")
            var tree = root
            let incoming: SavedLayoutNode
            if case let .pane(path) = item, let held = moved {
                incoming = held
                tree = setting(tree, at: path, to: marker)
            } else if case let .app(bundleID) = item {
                incoming = newLeaf(for: bundleID, in: &next, makeID: makeID)
            } else { return reject("The layout changed. Try the drop again.") }
            let holder = destination.flatMap { node(at: $0, in: tree) } ?? tree
            let split = wrapped(holder, side, with: incoming, share: share)
            tree = destination.map { replacing(tree, at: $0, with: split) } ?? normalized(split)
            if case let .pane(source) = item, let markerPath = leaves(tree).first(where: { $0.node == marker })?.path {
                // Dropping on the app's own pane edge keeps both halves; elsewhere the emptied pane goes away.
                if source == destination { tree = setting(tree, at: markerPath, to: newLeaf(in: &next, makeID: makeID)) }
                else if let reduced = removing(markerPath, from: tree) { tree = reduced }
            }
            next.layout = tree
            let summary = "\(appName) is in a new \(word) at the \(side.rawValue)\(destination == nil ? " edge" : " of pane \(number(destination ?? []))")."
            return .init(label: label, preview: preview, isCanvasEdge: destination == nil,
                         outcome: finish(next, document, selecting: incoming, summary: summary, checkingMinimumSize: true))
        }
    }

    public static func splitting(_ path: [Int], axis: SplitAxis, in document: SavedLayoutDocument) -> SavedLayoutOutcome {
        guard document.mode != .manual, let root = document.layout, let node = node(at: path, in: root) else {
            return .rejected("Select a pane to split.")
        }
        var next = document
        let added = newLeaf(in: &next, makeID: defaultID)
        next.layout = replacing(root, at: path, with: .split(axis: axis, ratios: [0.5, 0.5], children: [node, added]))
        let word = axis == .vertical ? "columns" : "rows"
        let outcome = finish(next, document, selecting: nil, summary: "Split the pane into \(word). The new pane is empty and selected.", checkingMinimumSize: true)
        // The new pane reads right after the one that was split.
        guard case var .change(edit) = outcome, let index = leaves(root).firstIndex(where: { $0.path == path }),
              let updated = edit.document.layout else { return outcome }
        let all = leaves(updated)
        edit.selection = all.indices.contains(index + 1) ? all[index + 1].path : nil
        return .change(edit)
    }

    /// Removes a pane together with its app (or tabs). Undo brings both back.
    public static func removingPane(_ path: [Int], from document: SavedLayoutDocument) -> SavedLayoutOutcome {
        guard document.mode != .manual, let root = document.layout, let node = node(at: path, in: root) else {
            return .rejected("Select a pane to remove.")
        }
        guard let reduced = removing(path, from: root) else { return .rejected("The only pane can’t be removed.") }
        var next = document
        let held = title(of: node, in: document, names: { $0 })
        release(node, from: &next)
        next.layout = reduced
        let summary = held == nil ? "Removed the empty pane." : "Removed the pane and its app."
        return finish(next, document, selecting: nil, summary: summary, checkingMinimumSize: false)
    }

    /// Removes preferences without leaving a pane that Apply cannot fill. Tabbed drops removed
    /// slots while other tabs remain; the last removed slot stays as an Any-window slot.
    public static func removingApps(_ ids: [String], from document: SavedLayoutDocument) -> SavedLayoutOutcome {
        let requested = Set(ids)
        var next = document
        // A deliberate float is a placement, not a pane. Removing it must not leave a free target.
        var discarded = Set(document.floats.map(\.slot)).intersection(requested)
        next.floats.removeAll { requested.contains($0.slot) }
        let grouped = Set(document.groups.flatMap(\.slots))
        for index in next.groups.indices {
            let original = document.groups[index]
            let removed = original.slots.filter { requested.contains($0) }
            guard !removed.isEmpty else { continue }
            let remaining = original.slots.filter { !requested.contains($0) }
            if remaining.isEmpty {
                let kept = original.selected ?? removed[0]
                next.groups[index].slots = [kept]
                next.groups[index].selected = kept
                discarded.formUnion(removed.filter { $0 != kept })
                if let slot = next.slots.firstIndex(where: { $0.id == kept }) { next.slots[slot].prefer = [] }
            } else {
                next.groups[index].slots = remaining
                if original.selected.map({ requested.contains($0) }) == true {
                    next.groups[index].selected = remaining.first
                }
                discarded.formUnion(removed)
            }
        }
        next.slots.removeAll { discarded.contains($0.id) }
        for index in next.slots.indices where requested.contains(next.slots[index].id) && !grouped.contains(next.slots[index].id) {
            next.slots[index].prefer = []
        }
        let pane = document.layout.flatMap { root in
            leaves(root).first { !requested.isDisjoint(with: slotIDs(in: $0.node, document: document)) }?.node
        }
        return finish(next, document, selecting: pane, summary: "Removed app preferences.", checkingMinimumSize: false)
    }

    // MARK: Presets

    public static func presetLayout(_ preset: TabbedPreset, panes: [SavedLayoutNode]) -> SavedLayoutNode {
        let leaves = panes + Array(repeating: SavedLayoutNode.empty, count: max(0, preset.paneCount - panes.count))
        switch preset {
        case .single: return leaves[0]
        case .columns: return .split(axis: .vertical, ratios: [0.5, 0.5], children: Array(leaves.prefix(2)))
        case .rows: return .split(axis: .horizontal, ratios: [0.5, 0.5], children: Array(leaves.prefix(2)))
        case .focus: return .split(axis: .vertical, ratios: [0.63, 0.37], children: [leaves[0],
            .split(axis: .horizontal, ratios: [0.5, 0.5], children: Array(leaves[1...2]))])
        case .grid: return .split(axis: .vertical, ratios: [0.5, 0.5], children: [
            .split(axis: .horizontal, ratios: [0.5, 0.5], children: Array(leaves[0...1])),
            .split(axis: .horizontal, ratios: [0.5, 0.5], children: Array(leaves[2...3]))])
        }
    }

    /// Keeps assigned panes in reading order and drops empty ones. Only assigned panes count against the preset.
    public static func applyingPreset(_ preset: TabbedPreset, to document: SavedLayoutDocument) -> SavedLayoutOutcome {
        guard document.mode != .manual, let root = document.layout else { return .rejected("Presets edit Adaptive and Tabbed layouts.") }
        let panes = leaves(root).map(\.node)
        let assigned = panes.filter { node in
            slotIDs(in: node, document: document).contains { id in
                document.slots.contains { $0.id == id && !$0.prefer.isEmpty }
            }
        }
        guard assigned.count <= preset.paneCount else {
            return .rejected("\(preset.title) has fewer panes than your \(assigned.count) assigned \(document.mode == .tabbed ? "panes" : "apps"). Move or remove one first; your layout was kept.")
        }
        if shape(root).preset == preset { return .unchanged("Already \(document.mode == .tabbed ? shape(root).name : preset.title). Pane sizes were kept.") }
        var next = document
        for pane in panes where !assigned.contains(pane) { release(pane, from: &next) }
        let added = (assigned.count..<preset.paneCount).map { _ in newLeaf(in: &next, makeID: defaultID) }
        // Tabbed names the result by its shape; the preset's own title reads as Adaptive there.
        let layout = presetLayout(preset, panes: assigned + added)
        let title = document.mode == .tabbed ? shape(layout).name : preset.title
        next.layout = layout
        let noun = document.mode == .tabbed ? "assigned pane" : "app"
        return finish(next, document, selecting: nil,
                      summary: assigned.isEmpty ? "\(title)."
                          : "\(title). Your \(assigned.count) \(noun)\(assigned.count == 1 ? "" : "s") kept their order.", checkingMinimumSize: false)
    }
}

private extension SavedLayoutOutcome {
    func withSelection(_ path: [Int]) -> SavedLayoutOutcome {
        guard case var .change(edit) = self else { return self }
        edit.selection = path
        return .change(edit)
    }
}
