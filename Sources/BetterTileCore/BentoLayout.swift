import Foundation

public enum SplitAxis: String, Sendable {
    case horizontal
    case vertical
}

public struct BentoLayoutMetrics: Hashable, Sendable {
    public var paneGap: Double

    public init(paneGap: Double = 0) {
        self.paneGap = min(12, max(0, paneGap))
    }

    public static let gapless = BentoLayoutMetrics()
}

/// An ordered, same-axis partition. Ratios describe each child's share of the
/// usable extent after pane gaps are removed. Boundary identifiers remain
/// stable while ratios change so overlays never need geometry-derived IDs.
public struct BentoPartition: Hashable, Sendable {
    public var id: UUID
    public var axis: SplitAxis
    public var children: [BentoNode]
    public var ratios: [Double]
    public var boundaryIDs: [UUID]
    public var lockedBoundaryIDs: Set<UUID>

    public init(
        id: UUID = UUID(),
        axis: SplitAxis,
        children: [BentoNode],
        ratios: [Double] = [],
        boundaryIDs: [UUID] = [],
        lockedBoundaryIDs: Set<UUID> = []
    ) {
        precondition(children.count >= 2, "A Bento partition needs at least two children.")
        self.id = id
        self.axis = axis
        self.children = children
        self.ratios = Self.normalizedRatios(ratios, count: children.count)
        self.boundaryIDs = boundaryIDs.count == children.count - 1
            ? boundaryIDs
            : (0..<(children.count - 1)).map { _ in UUID() }
        self.lockedBoundaryIDs = lockedBoundaryIDs.intersection(self.boundaryIDs)
    }

    public var isLocked: Bool { !lockedBoundaryIDs.isEmpty }

    public func cumulativeRatio(at boundaryIndex: Int) -> Double {
        ratios.prefix(boundaryIndex + 1).reduce(0, +)
    }

    public mutating func setCumulativeRatio(_ value: Double, at boundaryIndex: Int) {
        guard ratios.indices.contains(boundaryIndex), boundaryIndex < ratios.count - 1,
              !lockedBoundaryIDs.contains(boundaryIDs[boundaryIndex])
        else { return }
        let fixedPrefix = ratios.prefix(boundaryIndex).reduce(0, +)
        let adjacentTotal = ratios[boundaryIndex] + ratios[boundaryIndex + 1]
        guard adjacentTotal > 0 else { return }
        let first = min(adjacentTotal - 0.000_001, max(0.000_001, value - fixedPrefix))
        ratios[boundaryIndex] = first
        ratios[boundaryIndex + 1] = adjacentTotal - first
        ratios = Self.normalizedRatios(ratios, count: children.count)
    }

    private static func normalizedRatios(_ values: [Double], count: Int) -> [Double] {
        let candidates = values.count == count ? values.map { max(0.000_001, $0) } : Array(repeating: 1, count: count)
        let total = candidates.reduce(0, +)
        return candidates.map { $0 / total }
    }
}

public struct BentoBranch: Hashable, Sendable {
    public var id: UUID
    public var axis: SplitAxis
    public var weight: Double
    public var isLocked: Bool
    public var first: BentoNode
    public var second: BentoNode

    public init(id: UUID = UUID(), axis: SplitAxis, weight: Double = 0.5, isLocked: Bool = false, first: BentoNode, second: BentoNode) {
        self.id = id
        self.axis = axis
        self.weight = min(0.9, max(0.1, weight))
        self.isLocked = isLocked
        self.first = first
        self.second = second
    }
}

public indirect enum BentoNode: Hashable, Sendable {
    case leaf(WindowID)
    case vacant(UUID)
    case branch(BentoBranch)
    case partition(BentoPartition)

    public var windowIDs: [WindowID] {
        switch self {
        case let .leaf(id): [id]
        case .vacant: []
        case let .branch(branch): branch.first.windowIDs + branch.second.windowIDs
        case let .partition(partition): partition.children.flatMap(\.windowIDs)
        }
    }
}

public struct BentoLayoutState: Hashable, Sendable {
    public var root: BentoNode?
    public var floatingWindowIDs: Set<WindowID>
    public var metrics: BentoLayoutMetrics

    public init(
        root: BentoNode? = nil,
        floatingWindowIDs: Set<WindowID> = [],
        metrics: BentoLayoutMetrics = .gapless
    ) {
        self.root = root.map(Self.normalized)
        self.floatingWindowIDs = floatingWindowIDs
        self.metrics = metrics
    }

    public var branches: [BentoBranchDescriptor] {
        guard let root else { return [] }
        func collect(_ node: BentoNode, depth: Int) -> [BentoBranchDescriptor] {
            switch node {
            case .leaf, .vacant: return []
            case let .branch(branch):
                return [BentoBranchDescriptor(id: branch.id, axis: branch.axis, weight: branch.weight, isLocked: branch.isLocked, depth: depth)]
                    + collect(branch.first, depth: depth + 1)
                    + collect(branch.second, depth: depth + 1)
            case let .partition(partition):
                let boundaries = partition.boundaryIDs.indices.map { index in
                    BentoBranchDescriptor(
                        id: partition.boundaryIDs[index],
                        axis: partition.axis,
                        weight: partition.cumulativeRatio(at: index),
                        isLocked: partition.lockedBoundaryIDs.contains(partition.boundaryIDs[index]),
                        depth: depth
                    )
                }
                return boundaries + partition.children.flatMap { collect($0, depth: depth + 1) }
            }
        }
        return collect(root, depth: 0)
    }

    public mutating func insert(_ windowID: WindowID, in bounds: BTRect, currentFrames: [WindowID: BTRect] = [:]) {
        guard !floatingWindowIDs.contains(windowID), root?.windowIDs.contains(windowID) != true else { return }
        guard let root else {
            self.root = .leaf(windowID)
            return
        }
        if let slot = vacantFrames(for: root, in: bounds).max(by: { $0.value.area < $1.value.area })?.key {
            self.root = replacingVacant(slot, in: root, with: .leaf(windowID))
            return
        }
        let leaves = frames(for: root, in: bounds).keys.sorted()
        var best: (score: Double, id: WindowID, node: BentoNode)?
        for leafID in leaves {
            let candidate = replacingLeaf(leafID, in: root, transform: { leafFrame in
                let axis: SplitAxis = leafFrame.size.width >= leafFrame.size.height ? .vertical : .horizontal
                let id = stableBranchID(first: leafID, second: windowID)
                return .partition(BentoPartition(
                    id: id, axis: axis,
                    children: [.leaf(leafID), .leaf(windowID)],
                    boundaryIDs: [id]
                ))
            }, bounds: bounds)
            let candidateFrames = frames(for: candidate, in: bounds)
            let score = disruptionScore(candidateFrames: candidateFrames, currentFrames: currentFrames, excluding: windowID, bounds: bounds)
            if best == nil || score < best!.score || (score == best!.score && leafID < best!.id) {
                best = (score, leafID, candidate)
            }
        }
        self.root = Self.normalized(best?.node ?? root)
    }

    public mutating func remove(_ windowID: WindowID) {
        floatingWindowIDs.remove(windowID)
        root = root.flatMap { removing(windowID, from: $0) }
    }

    public mutating func setFloating(_ floating: Bool, windowID: WindowID) {
        if floating {
            floatingWindowIDs.insert(windowID)
            root = root.flatMap { removing(windowID, from: $0) }
        } else {
            floatingWindowIDs.remove(windowID)
        }
    }

    /// Moves one normalized partition boundary in screen coordinates. Only
    /// the two panes touching that boundary change size; siblings elsewhere in
    /// the partition keep their ratios and frames.
    @discardableResult
    public mutating func setBoundaryCoordinate(_ coordinate: Double, branchID: UUID, in bounds: BTRect) -> Bool {
        guard coordinate.isFinite, let root else { return false }
        let normalizedRoot = Self.normalized(root)

        func update(_ node: BentoNode, rect: BTRect) -> (BentoNode, Bool) {
            switch node {
            case .leaf, .vacant:
                return (node, false)
            case .branch:
                return update(Self.normalized(node), rect: rect)
            case var .partition(partition):
                if let index = partition.boundaryIDs.firstIndex(of: branchID) {
                    guard !partition.lockedBoundaryIDs.contains(branchID) else { return (node, false) }
                    let extent = partition.axis == .vertical ? rect.size.width : rect.size.height
                    let usable = extent - metrics.paneGap * Double(partition.children.count - 1)
                    guard usable > 0 else { return (node, false) }
                    let start = partition.axis == .vertical ? rect.minX : rect.minY
                    let cumulative = (coordinate - start
                        - metrics.paneGap * Double(index)
                        - metrics.paneGap / 2) / usable
                    partition.setCumulativeRatio(cumulative, at: index)
                    return (.partition(partition), true)
                }
                let rects = partitionChildRects(partition, in: rect)
                for index in partition.children.indices {
                    let (child, found) = update(partition.children[index], rect: rects[index])
                    if found {
                        partition.children[index] = child
                        return (.partition(partition), true)
                    }
                }
                return (.partition(partition), false)
            }
        }

        let (updated, found) = update(normalizedRoot, rect: bounds)
        if found { self.root = updated }
        return found
    }

    public mutating func swap(_ first: WindowID, _ second: WindowID) {
        guard first != second else { return }
        root = root.map { swapping(first, second, in: $0) }
    }

    @discardableResult
    public mutating func replace(_ targetWindowID: WindowID, with windowID: WindowID) -> Bool {
        guard targetWindowID != windowID,
              let root,
              root.windowIDs.contains(targetWindowID),
              !root.windowIDs.contains(windowID)
        else { return false }

        func replacing(_ node: BentoNode) -> BentoNode {
            switch node {
            case let .leaf(candidate):
                return candidate == targetWindowID ? .leaf(windowID) : node
            case .vacant:
                return node
            case var .branch(branch):
                branch.first = replacing(branch.first)
                branch.second = replacing(branch.second)
                return .branch(branch)
            case var .partition(partition):
                partition.children = partition.children.map(replacing)
                return .partition(partition)
            }
        }

        self.root = replacing(root)
        floatingWindowIDs.remove(windowID)
        return true
    }

    /// Exchanges a floating window with a pane.
    ///
    /// The floating window takes the pane's place in the tree and the pane's
    /// previous occupant floats in its stead, so the layout keeps its shape and
    /// its pane count while the user swaps which window occupies a slot. This
    /// is what makes an overflow window useful rather than merely visible: it
    /// can be brought into the layout without the layout being rebuilt.
    @discardableResult
    public mutating func exchangeFloating(
        _ floatingWindowID: WindowID,
        withPaneOf paneWindowID: WindowID
    ) -> Bool {
        guard floatingWindowID != paneWindowID,
              floatingWindowIDs.contains(floatingWindowID),
              root?.windowIDs.contains(paneWindowID) == true,
              replace(paneWindowID, with: floatingWindowID)
        else { return false }
        setFloating(true, windowID: paneWindowID)
        return true
    }

    public mutating func split(_ targetWindowID: WindowID, inserting windowID: WindowID, in bounds: BTRect) {
        let depth = depth(of: targetWindowID) ?? 0
        let axis: SplitAxis = depth.isMultiple(of: 2) ? .vertical : .horizontal
        split(targetWindowID, inserting: windowID, axis: axis, in: bounds)
    }

    public mutating func split(
        _ targetWindowID: WindowID,
        inserting windowID: WindowID,
        axis: SplitAxis,
        sourceComesFirst: Bool = false,
        in bounds: BTRect
    ) {
        guard let root, targetWindowID != windowID,
              root.windowIDs.contains(targetWindowID),
              !root.windowIDs.contains(windowID)
        else { return }
        self.root = Self.normalized(replacingLeaf(targetWindowID, in: root, transform: { _ in
            let id = stableBranchID(first: targetWindowID, second: windowID)
            let children: [BentoNode] = sourceComesFirst
                ? [.leaf(windowID), .leaf(targetWindowID)]
                : [.leaf(targetWindowID), .leaf(windowID)]
            return .partition(BentoPartition(
                id: id, axis: axis,
                children: children,
                boundaryIDs: [id]
            ))
        }, bounds: bounds))
        floatingWindowIDs.remove(windowID)
    }

    public func depth(of windowID: WindowID) -> Int? {
        guard let root else { return nil }
        func find(_ node: BentoNode, depth: Int) -> Int? {
            switch node {
            case let .leaf(candidate):
                return candidate == windowID ? depth : nil
            case .vacant:
                return nil
            case let .branch(branch):
                return find(branch.first, depth: depth + 1)
                    ?? find(branch.second, depth: depth + 1)
            case let .partition(partition):
                return partition.children.lazy.compactMap { find($0, depth: depth + 1) }.first
            }
        }
        return find(root, depth: 0)
    }

    public mutating func insertAtRoot(
        _ windowID: WindowID,
        edge: BentoPaneDropPosition,
        ratio: Double = 0.5
    ) -> Bool {
        guard let root, let axis = edge.axis,
              !root.windowIDs.contains(windowID)
        else { return false }
        let source = BentoNode.leaf(windowID)
        let children = edge.sourceComesFirst ? [source, root] : [root, source]
        let sourceRatio = min(0.9, max(0.1, ratio))
        let ratios = edge.sourceComesFirst
            ? [sourceRatio, 1 - sourceRatio]
            : [1 - sourceRatio, sourceRatio]
        let boundaryID = stableBranchID(
            first: children[0].windowIDs.first ?? windowID,
            second: children[1].windowIDs.first ?? windowID
        )
        self.root = Self.normalized(.partition(BentoPartition(
            id: boundaryID,
            axis: axis,
            children: children,
            ratios: ratios,
            boundaryIDs: [boundaryID]
        )))
        floatingWindowIDs.remove(windowID)
        return true
    }

    /// Moves a window beside another pane. Its old leaf collapses locally,
    /// then the target is split without invoking a full-display template.
    @discardableResult
    public mutating func reinsert(
        _ sourceWindowID: WindowID,
        beside targetWindowID: WindowID,
        edge: BentoPaneDropPosition
    ) -> Bool {
        guard sourceWindowID != targetWindowID,
              let axis = edge.axis,
              root?.windowIDs.contains(targetWindowID) == true
        else { return false }

        func directLeafIndex(_ id: WindowID, in children: [BentoNode]) -> Int? {
            children.firstIndex {
                guard case let .leaf(candidate) = $0 else { return false }
                return candidate == id
            }
        }

        func reorderSiblings(in node: BentoNode) -> (node: BentoNode, changed: Bool) {
            switch node {
            case .leaf, .vacant:
                return (node, false)
            case .branch:
                return reorderSiblings(in: Self.normalized(node))
            case var .partition(partition):
                if partition.axis == axis,
                   let sourceIndex = directLeafIndex(sourceWindowID, in: partition.children),
                   directLeafIndex(targetWindowID, in: partition.children) != nil {
                    let source = partition.children.remove(at: sourceIndex)
                    let sourceRatio = partition.ratios.remove(at: sourceIndex)
                    guard let targetIndex = directLeafIndex(targetWindowID, in: partition.children) else {
                        return (node, false)
                    }
                    let insertionIndex = edge.sourceComesFirst ? targetIndex : targetIndex + 1
                    partition.children.insert(source, at: insertionIndex)
                    partition.ratios.insert(sourceRatio, at: insertionIndex)
                    return (.partition(BentoPartition(
                        id: partition.id,
                        axis: partition.axis,
                        children: partition.children,
                        ratios: partition.ratios,
                        boundaryIDs: partition.boundaryIDs,
                        lockedBoundaryIDs: partition.lockedBoundaryIDs
                    )), true)
                }
                for index in partition.children.indices {
                    let result = reorderSiblings(in: partition.children[index])
                    if result.changed {
                        partition.children[index] = result.node
                        return (.partition(partition), true)
                    }
                }
                return (.partition(partition), false)
            }
        }

        func insertBesideTarget(in node: BentoNode) -> (node: BentoNode, changed: Bool) {
            switch node {
            case let .leaf(candidate):
                guard candidate == targetWindowID else { return (node, false) }
                let sourceLeaf = BentoNode.leaf(sourceWindowID)
                let targetLeaf = BentoNode.leaf(targetWindowID)
                let children = edge.sourceComesFirst
                    ? [sourceLeaf, targetLeaf]
                    : [targetLeaf, sourceLeaf]
                let boundaryID = stableBranchID(
                    first: children[0].windowIDs[0],
                    second: children[1].windowIDs[0]
                )
                return (.partition(BentoPartition(
                    id: boundaryID,
                    axis: axis,
                    children: children,
                    boundaryIDs: [boundaryID]
                )), true)
            case .vacant:
                return (node, false)
            case .branch:
                return insertBesideTarget(in: Self.normalized(node))
            case var .partition(partition):
                if partition.axis == axis,
                   let targetIndex = directLeafIndex(targetWindowID, in: partition.children) {
                    let insertionIndex = edge.sourceComesFirst ? targetIndex : targetIndex + 1
                    let isBalanced = partition.lockedBoundaryIDs.isEmpty
                        && (partition.ratios.max() ?? 0) - (partition.ratios.min() ?? 0) <= 0.05
                    if isBalanced {
                        partition.ratios = Array(
                            repeating: 1 / Double(partition.children.count + 1),
                            count: partition.children.count
                        )
                        partition.ratios.insert(1 / Double(partition.children.count + 1), at: insertionIndex)
                    } else {
                        let targetShare = partition.ratios[targetIndex] / 2
                        partition.ratios[targetIndex] = targetShare
                        partition.ratios.insert(targetShare, at: insertionIndex)
                    }
                    partition.children.insert(.leaf(sourceWindowID), at: insertionIndex)
                    let adjacentIndex = edge.sourceComesFirst
                        ? min(partition.children.count - 1, insertionIndex + 1)
                        : max(0, insertionIndex - 1)
                    let leftIndex = min(insertionIndex, adjacentIndex)
                    let rightIndex = max(insertionIndex, adjacentIndex)
                    let leftID = partition.children[leftIndex].windowIDs.first ?? sourceWindowID
                    let rightID = partition.children[rightIndex].windowIDs.first ?? sourceWindowID
                    let newBoundaryID = stableBranchID(first: leftID, second: rightID)
                    let newBoundaryIndex = edge.sourceComesFirst
                        ? insertionIndex
                        : max(0, insertionIndex - 1)
                    partition.boundaryIDs.insert(
                        newBoundaryID,
                        at: min(newBoundaryIndex, partition.boundaryIDs.count)
                    )
                    return (.partition(BentoPartition(
                        id: partition.id,
                        axis: partition.axis,
                        children: partition.children,
                        ratios: partition.ratios,
                        boundaryIDs: partition.boundaryIDs,
                        lockedBoundaryIDs: partition.lockedBoundaryIDs
                    )), true)
                }
                for index in partition.children.indices where
                    partition.children[index].windowIDs.contains(targetWindowID) {
                    let result = insertBesideTarget(in: partition.children[index])
                    if result.changed {
                        partition.children[index] = result.node
                        return (.partition(partition), true)
                    }
                }
                return (.partition(partition), false)
            }
        }

        if let root {
            let reordered = reorderSiblings(in: root)
            if reordered.changed {
                self.root = reordered.node
                floatingWindowIDs.remove(sourceWindowID)
                return true
            }
        }

        remove(sourceWindowID)
        guard let root, root.windowIDs.contains(targetWindowID) else { return false }
        let inserted = insertBesideTarget(in: root)
        guard inserted.changed else { return false }
        self.root = inserted.node
        floatingWindowIDs.remove(sourceWindowID)
        return true
    }

    /// Learns unlocked split weights from user-adjusted window frames.
    public mutating func updateWeights(from currentFrames: [WindowID: BTRect], in bounds: BTRect) {
        guard let root else { return }
        func update(_ node: BentoNode, rect: BTRect) -> BentoNode {
            switch node {
            case .leaf, .vacant: return node
            case var .branch(branch):
                if !branch.isLocked {
                    let firstFrames = branch.first.windowIDs.compactMap { currentFrames[$0] }
                    if !firstFrames.isEmpty {
                        let boundary: Double = switch branch.axis {
                        case .vertical: firstFrames.map(\.maxX).max() ?? rect.midX
                        case .horizontal: firstFrames.map(\.maxY).max() ?? rect.midY
                        }
                        let extent = branch.axis == .vertical ? rect.size.width : rect.size.height
                        let start = branch.axis == .vertical ? rect.minX : rect.minY
                        if extent > 0 { branch.weight = min(0.9, max(0.1, (boundary - start) / extent)) }
                    }
                }
                let firstRect: BTRect
                let secondRect: BTRect
                if branch.axis == .vertical {
                    let width = rect.size.width * branch.weight
                    firstRect = BTRect(x: rect.minX, y: rect.minY, width: width, height: rect.size.height)
                    secondRect = BTRect(x: rect.minX + width, y: rect.minY, width: rect.size.width - width, height: rect.size.height)
                } else {
                    let height = rect.size.height * branch.weight
                    firstRect = BTRect(x: rect.minX, y: rect.minY, width: rect.size.width, height: height)
                    secondRect = BTRect(x: rect.minX, y: rect.minY + height, width: rect.size.width, height: rect.size.height - height)
                }
                branch.first = update(branch.first, rect: firstRect)
                branch.second = update(branch.second, rect: secondRect)
                return .branch(branch)
            case var .partition(partition):
                if partition.lockedBoundaryIDs.isEmpty {
                    let measured = partition.children.map { child -> Double in
                        let childFrames = child.windowIDs.compactMap { currentFrames[$0] }
                        guard let first = childFrames.first else { return 0 }
                        let minimum = childFrames.dropFirst().reduce(
                            partition.axis == .vertical ? first.minX : first.minY
                        ) { min($0, partition.axis == .vertical ? $1.minX : $1.minY) }
                        let maximum = childFrames.dropFirst().reduce(
                            partition.axis == .vertical ? first.maxX : first.maxY
                        ) { max($0, partition.axis == .vertical ? $1.maxX : $1.maxY) }
                        return max(0, maximum - minimum)
                    }
                    let total = measured.reduce(0, +)
                    if total > 0 { partition.ratios = measured.map { $0 / total } }
                }
                let rects = partitionChildRects(partition, in: rect)
                for index in partition.children.indices {
                    partition.children[index] = update(partition.children[index], rect: rects[index])
                }
                return .partition(partition)
            }
        }
        self.root = update(root, rect: bounds)
    }

    public func placements(in bounds: BTRect, constraints: [WindowID: WindowConstraints] = [:]) -> [Placement] {
        guard let root else { return [] }
        return frames(for: root, in: bounds)
            .map { id, frame in Placement(windowID: id, frame: frame.clamped(to: bounds, minimumSize: constraints[id]?.minimumSize ?? .zero)) }
            .sorted { $0.windowID < $1.windowID }
    }

    public func vacantFrames(in bounds: BTRect) -> [UUID: BTRect] {
        guard let root else { return [:] }
        return vacantFrames(for: root, in: bounds)
    }

    private func frames(for node: BentoNode, in rect: BTRect) -> [WindowID: BTRect] {
        switch node {
        case let .leaf(id): return [id: rect]
        case .vacant: return [:]
        case let .branch(branch):
            let firstRect: BTRect
            let secondRect: BTRect
            switch branch.axis {
            case .vertical:
                let width = rect.size.width * branch.weight
                firstRect = BTRect(x: rect.minX, y: rect.minY, width: width, height: rect.size.height)
                secondRect = BTRect(x: rect.minX + width, y: rect.minY, width: rect.size.width - width, height: rect.size.height)
            case .horizontal:
                let height = rect.size.height * branch.weight
                firstRect = BTRect(x: rect.minX, y: rect.minY, width: rect.size.width, height: height)
                secondRect = BTRect(x: rect.minX, y: rect.minY + height, width: rect.size.width, height: rect.size.height - height)
            }
            return frames(for: branch.first, in: firstRect).merging(frames(for: branch.second, in: secondRect)) { first, _ in first }
        case let .partition(partition):
            return zip(partition.children, partitionChildRects(partition, in: rect)).reduce(into: [:]) { output, pair in
                output.merge(frames(for: pair.0, in: pair.1)) { first, _ in first }
            }
        }
    }

    private func replacingLeaf(_ id: WindowID, in node: BentoNode, transform: (BTRect) -> BentoNode, bounds: BTRect) -> BentoNode {
        func replace(_ node: BentoNode, rect: BTRect) -> BentoNode {
            switch node {
            case let .leaf(candidate): return candidate == id ? transform(rect) : node
            case .vacant: return node
            case var .branch(branch):
                if branch.axis == .vertical {
                    let width = rect.size.width * branch.weight
                    branch.first = replace(branch.first, rect: BTRect(x: rect.minX, y: rect.minY, width: width, height: rect.size.height))
                    branch.second = replace(branch.second, rect: BTRect(x: rect.minX + width, y: rect.minY, width: rect.size.width - width, height: rect.size.height))
                } else {
                    let height = rect.size.height * branch.weight
                    branch.first = replace(branch.first, rect: BTRect(x: rect.minX, y: rect.minY, width: rect.size.width, height: height))
                    branch.second = replace(branch.second, rect: BTRect(x: rect.minX, y: rect.minY + height, width: rect.size.width, height: rect.size.height - height))
                }
                return .branch(branch)
            case var .partition(partition):
                let rects = partitionChildRects(partition, in: rect)
                for index in partition.children.indices {
                    partition.children[index] = replace(partition.children[index], rect: rects[index])
                }
                return Self.normalized(.partition(partition))
            }
        }
        return replace(node, rect: bounds)
    }

    private func replacingVacant(_ id: UUID, in node: BentoNode, with replacement: BentoNode) -> BentoNode {
        switch node {
        case .leaf: return node
        case let .vacant(candidate): return candidate == id ? replacement : node
        case var .branch(branch):
            branch.first = replacingVacant(id, in: branch.first, with: replacement)
            branch.second = replacingVacant(id, in: branch.second, with: replacement)
            return .branch(branch)
        case var .partition(partition):
            partition.children = partition.children.map { replacingVacant(id, in: $0, with: replacement) }
            return Self.normalized(.partition(partition))
        }
    }

    private func vacantFrames(for node: BentoNode, in rect: BTRect) -> [UUID: BTRect] {
        switch node {
        case .leaf: return [:]
        case let .vacant(id): return [id: rect]
        case let .branch(branch):
            let children = childRects(branch, in: rect)
            return vacantFrames(for: branch.first, in: children.0)
                .merging(vacantFrames(for: branch.second, in: children.1)) { first, _ in first }
        case let .partition(partition):
            return zip(partition.children, partitionChildRects(partition, in: rect)).reduce(into: [:]) { output, pair in
                output.merge(vacantFrames(for: pair.0, in: pair.1)) { first, _ in first }
            }
        }
    }

    private func removing(_ id: WindowID, from node: BentoNode) -> BentoNode? {
        switch node {
        case let .leaf(candidate): return candidate == id ? nil : node
        case .vacant: return node
        case let .branch(branch):
            let first = removing(id, from: branch.first)
            let second = removing(id, from: branch.second)
            switch (first, second) {
            case (nil, nil): return nil
            case let (value?, nil), let (nil, value?): return value
            case let (first?, second?):
                var branch = branch
                branch.first = first
                branch.second = second
                return .branch(branch)
            }
        case var .partition(partition):
            var retainedChildren: [BentoNode] = []
            var retainedRatios: [Double] = []
            var retainedIndices: [Int] = []
            for index in partition.children.indices {
                guard let child = removing(id, from: partition.children[index]) else { continue }
                retainedChildren.append(child)
                retainedRatios.append(partition.ratios[index])
                retainedIndices.append(index)
            }
            guard !retainedChildren.isEmpty else { return nil }
            if retainedChildren.count == 1 { return retainedChildren[0] }
            partition.children = retainedChildren
            partition.ratios = retainedRatios
            partition.boundaryIDs = zip(retainedIndices, retainedIndices.dropFirst()).map { pair in
                partition.boundaryIDs[min(pair.0, partition.boundaryIDs.count - 1)]
            }
            partition.lockedBoundaryIDs.formIntersection(partition.boundaryIDs)
            return Self.normalized(.partition(BentoPartition(
                id: partition.id,
                axis: partition.axis,
                children: partition.children,
                ratios: partition.ratios,
                boundaryIDs: partition.boundaryIDs,
                lockedBoundaryIDs: partition.lockedBoundaryIDs
            )))
        }
    }

    private func swapping(_ first: WindowID, _ second: WindowID, in node: BentoNode) -> BentoNode {
        switch node {
        case let .leaf(id):
            if id == first { return .leaf(second) }
            if id == second { return .leaf(first) }
            return node
        case .vacant:
            return node
        case var .branch(branch):
            branch.first = swapping(first, second, in: branch.first)
            branch.second = swapping(first, second, in: branch.second)
            return .branch(branch)
        case var .partition(partition):
            partition.children = partition.children.map { swapping(first, second, in: $0) }
            return .partition(partition)
        }
    }

    private func childRects(_ branch: BentoBranch, in rect: BTRect) -> (BTRect, BTRect) {
        let gap = metrics.paneGap
        switch branch.axis {
        case .vertical:
            let usable = max(0, rect.size.width - gap)
            let width = usable * branch.weight
            return (
                BTRect(x: rect.minX, y: rect.minY, width: width, height: rect.size.height),
                BTRect(x: rect.minX + width + gap, y: rect.minY, width: usable - width, height: rect.size.height)
            )
        case .horizontal:
            let usable = max(0, rect.size.height - gap)
            let height = usable * branch.weight
            return (
                BTRect(x: rect.minX, y: rect.minY, width: rect.size.width, height: height),
                BTRect(x: rect.minX, y: rect.minY + height + gap, width: rect.size.width, height: usable - height)
            )
        }
    }

    func partitionChildRects(_ partition: BentoPartition, in rect: BTRect) -> [BTRect] {
        let gap = metrics.paneGap
        let extent = partition.axis == .vertical ? rect.size.width : rect.size.height
        let usable = max(0, extent - gap * Double(partition.children.count - 1))
        var cursor = partition.axis == .vertical ? rect.minX : rect.minY
        return partition.children.indices.map { index in
            let childExtent = index == partition.children.count - 1
                ? (partition.axis == .vertical ? rect.maxX : rect.maxY) - cursor
                : usable * partition.ratios[index]
            let child: BTRect = if partition.axis == .vertical {
                BTRect(x: cursor, y: rect.minY, width: max(0, childExtent), height: rect.size.height)
            } else {
                BTRect(x: rect.minX, y: cursor, width: rect.size.width, height: max(0, childExtent))
            }
            cursor += childExtent + gap
            return child
        }
    }

    private func disruptionScore(candidateFrames: [WindowID: BTRect], currentFrames: [WindowID: BTRect], excluding newWindow: WindowID, bounds: BTRect) -> Double {
        candidateFrames.reduce(0) { score, entry in
            guard entry.key != newWindow, let old = currentFrames[entry.key] else { return score }
            let next = entry.value
            let movement = pow(next.midX - old.midX, 2) + pow(next.midY - old.midY, 2)
            let areaChange = abs(next.area - old.area)
            return score + movement / max(1, bounds.area) + areaChange / max(1, bounds.area)
        }
    }

    private func stableBranchID(first: WindowID, second: WindowID) -> UUID {
        func fnv1a(_ string: String, seed: UInt64) -> UInt64 {
            string.utf8.reduce(seed) { hash, byte in (hash ^ UInt64(byte)) &* 1_099_511_628_211 }
        }
        let source = first.rawValue + "\u{0}" + second.rawValue
        let high = String(format: "%016llx", fnv1a(source, seed: 14_695_981_039_346_656_037))
        let low = String(format: "%016llx", fnv1a(String(source.reversed()), seed: 7_807_828_912_877_952_651))
        let hex = high + low
        let text = "\(hex.prefix(8))-\(hex.dropFirst(8).prefix(4))-\(hex.dropFirst(12).prefix(4))-\(hex.dropFirst(16).prefix(4))-\(hex.dropFirst(20).prefix(12))"
        return UUID(uuidString: text)!
    }

    public mutating func normalizePartitions() {
        root = root.map(Self.normalized)
    }

    public static func normalized(_ node: BentoNode) -> BentoNode {
        switch node {
        case .leaf, .vacant:
            return node
        case let .branch(branch):
            return normalized(.partition(BentoPartition(
                id: branch.id,
                axis: branch.axis,
                children: [branch.first, branch.second],
                ratios: [branch.weight, 1 - branch.weight],
                boundaryIDs: [branch.id],
                lockedBoundaryIDs: branch.isLocked ? [branch.id] : []
            )))
        case var .partition(partition):
            partition.children = partition.children.map(normalized)
            var children: [BentoNode] = []
            var ratios: [Double] = []
            var boundaryIDs: [UUID] = []
            var locked: Set<UUID> = []

            for index in partition.children.indices {
                let child = partition.children[index]
                let parentRatio = partition.ratios[index]
                if case let .partition(nested) = child, nested.axis == partition.axis {
                    children.append(contentsOf: nested.children)
                    ratios.append(contentsOf: nested.ratios.map { $0 * parentRatio })
                    boundaryIDs.append(contentsOf: nested.boundaryIDs)
                    locked.formUnion(nested.lockedBoundaryIDs)
                } else {
                    children.append(child)
                    ratios.append(parentRatio)
                }
                if index < partition.children.count - 1 {
                    boundaryIDs.append(partition.boundaryIDs[index])
                    if partition.lockedBoundaryIDs.contains(partition.boundaryIDs[index]) {
                        locked.insert(partition.boundaryIDs[index])
                    }
                }
            }
            return .partition(BentoPartition(
                id: partition.id,
                axis: partition.axis,
                children: children,
                ratios: ratios,
                boundaryIDs: boundaryIDs,
                lockedBoundaryIDs: locked
            ))
        }
    }

}

public struct BentoBranchDescriptor: Identifiable, Hashable, Sendable {
    public var id: UUID
    public var axis: SplitAxis
    public var weight: Double
    public var isLocked: Bool
    public var depth: Int

    public init(id: UUID, axis: SplitAxis, weight: Double, isLocked: Bool, depth: Int) {
        self.id = id
        self.axis = axis
        self.weight = weight
        self.isLocked = isLocked
        self.depth = depth
    }
}

public struct BentoLayoutEngine: Sendable {
    public var state: BentoLayoutState

    public init(state: BentoLayoutState) { self.state = state }

    public func placements(for windows: [WindowSnapshot], in display: DisplaySnapshot) -> [Placement] {
        let eligible = windows.filter { $0.isEligible && !$0.isFloating && $0.displayID == display.id }
        let ids = Set(eligible.map(\.id))
        let constraints = Dictionary(uniqueKeysWithValues: eligible.map { ($0.id, $0.constraints) })
        return state.placements(in: display.visibleFrame, constraints: constraints).filter { ids.contains($0.windowID) }
    }
}
