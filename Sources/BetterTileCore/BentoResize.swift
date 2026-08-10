import Foundation

public struct BentoResizeResult: Sendable {
    public var state: BentoLayoutState
    public var placements: [Placement]
    public var appliedCoordinates: [UUID: Double]

    public init(state: BentoLayoutState, placements: [Placement], appliedCoordinates: [UUID: Double]) {
        self.state = state
        self.placements = placements
        self.appliedCoordinates = appliedCoordinates
    }
}

/// Projects a Bento tree onto the nearest set of split weights that satisfies
/// every descendant minimum size. It never adjusts leaf frames independently,
/// so a successful result preserves the configured pane gaps by construction.
public struct BentoConstraintSolver: Sendable {
    public var tolerance: Double

    public init(tolerance: Double = 0.001) {
        self.tolerance = max(0, tolerance)
    }

    public func solve(
        state: BentoLayoutState,
        in bounds: BTRect,
        constraints: [WindowID: WindowConstraints] = [:]
    ) -> BentoLayoutState? {
        guard let root = state.root else { return state }
        let workingRoot = BentoLayoutState.normalized(root)
        let gap = state.metrics.paneGap

        func childRects(_ partition: BentoPartition, in rect: BTRect) -> [BTRect] {
            let extent = partition.axis == .vertical ? rect.size.width : rect.size.height
            let usable = max(0, extent - gap * Double(partition.children.count - 1))
            var cursor = partition.axis == .vertical ? rect.minX : rect.minY
            return partition.children.indices.map { index in
                let childExtent = index == partition.children.count - 1
                    ? (partition.axis == .vertical ? rect.maxX : rect.maxY) - cursor
                    : usable * partition.ratios[index]
                let child = partition.axis == .vertical
                    ? BTRect(x: cursor, y: rect.minY, width: max(0, childExtent), height: rect.size.height)
                    : BTRect(x: rect.minX, y: cursor, width: rect.size.width, height: max(0, childExtent))
                cursor += childExtent + gap
                return child
            }
        }

        func solveNode(_ node: BentoNode, rect: BTRect) -> BentoNode? {
            switch node {
            case .vacant:
                return node
            case let .leaf(id):
                let minimum = constraints[id]?.minimumSize ?? WindowConstraints().minimumSize
                guard rect.size.width + tolerance >= minimum.width,
                      rect.size.height + tolerance >= minimum.height
                else { return nil }
                return node
            case var .partition(partition):
                let extent = partition.axis == .vertical ? rect.size.width : rect.size.height
                let available = extent - gap * Double(partition.children.count - 1)
                let minimumExtents = partition.children.map {
                    BentoTreeGeometry.minimumExtent($0, axis: partition.axis, constraints: constraints, gap: gap)
                }
                guard available > 0,
                      minimumExtents.reduce(0, +) <= available + tolerance
                else { return nil }

                let lowerBounds = minimumExtents.map { max(0, $0 / available) }
                let currentExtents = partition.ratios.map { $0 * available }
                if !zip(currentExtents, minimumExtents).allSatisfy({ $0 + tolerance >= $1 }) {
                    guard partition.lockedBoundaryIDs.isEmpty else { return nil }
                    var ratios = partition.ratios
                    for index in ratios.indices where ratios[index] + tolerance / available < lowerBounds[index] {
                        var deficit = lowerBounds[index] - ratios[index]
                        ratios[index] = lowerBounds[index]
                        for distance in 1..<ratios.count where deficit > tolerance / available {
                            for donor in [index - distance, index + distance]
                            where ratios.indices.contains(donor) && deficit > tolerance / available {
                                let availableExcess = max(0, ratios[donor] - lowerBounds[donor])
                                let transfer = min(deficit, availableExcess)
                                ratios[donor] -= transfer
                                deficit -= transfer
                            }
                        }
                        guard deficit <= tolerance / available else { return nil }
                    }
                    partition.ratios = ratios
                }

                let rects = childRects(partition, in: rect)
                for index in partition.children.indices {
                    guard let child = solveNode(partition.children[index], rect: rects[index]) else { return nil }
                    partition.children[index] = child
                }
                return .partition(partition)
            }
        }

        guard let solvedRoot = solveNode(workingRoot, rect: bounds) else { return nil }
        var result = state
        result.root = BentoLayoutState.normalized(solvedRoot)
        return result
    }
}

/// Learns minimum sizes only when a requested shrink settles at a larger size
/// between the request and the gesture baseline. This avoids treating ordinary
/// moves or expansions as application constraints.
public struct WindowMinimumSizeLearner: Sendable {
    public private(set) var learnedSizes: [WindowID: BTSize]

    public init(learnedSizes: [WindowID: BTSize] = [:]) {
        self.learnedSizes = learnedSizes
    }

    @discardableResult
    public mutating func observe(
        windowID: WindowID,
        requested: BTRect,
        baseline: BTRect,
        actual: BTRect,
        tolerance: Double = 2
    ) -> Bool {
        var learned = learnedSizes[windowID] ?? .zero
        let previous = learned
        if requested.size.width + tolerance < baseline.size.width,
           actual.size.width > requested.size.width + tolerance,
           actual.size.width <= baseline.size.width + tolerance {
            learned.width = max(learned.width, actual.size.width)
        }
        if requested.size.height + tolerance < baseline.size.height,
           actual.size.height > requested.size.height + tolerance,
           actual.size.height <= baseline.size.height + tolerance {
            learned.height = max(learned.height, actual.size.height)
        }
        guard learned != previous else { return false }
        learnedSizes[windowID] = learned
        return true
    }

    public func merging(_ constraints: WindowConstraints, for windowID: WindowID) -> WindowConstraints {
        guard let learned = learnedSizes[windowID] else { return constraints }
        var result = constraints
        result.minimumSize.width = max(result.minimumSize.width, learned.width)
        result.minimumSize.height = max(result.minimumSize.height, learned.height)
        return result
    }

    public mutating func remove(_ windowID: WindowID) {
        learnedSizes.removeValue(forKey: windowID)
    }
}

/// Resizes Bento split branches by changing tree weights, then deriving every
/// affected frame from the tree. This keeps nested layouts coherent.
public struct BentoResizeEngine: Sendable {
    public init() {}

    public func resize(
        state: BentoLayoutState,
        branchCoordinates: [UUID: Double],
        in bounds: BTRect,
        constraints: [WindowID: WindowConstraints] = [:]
    ) -> BentoResizeResult? {
        guard state.root != nil, !branchCoordinates.isEmpty,
              var next = BentoConstraintSolver().solve(state: state, in: bounds, constraints: constraints)
        else { return nil }

        // Junctions always contain orthogonal branches. Stable ordering makes
        // the operation deterministic while each coordinate remains absolute.
        for branchID in branchCoordinates.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard let requested = branchCoordinates[branchID], requested.isFinite,
                  next.setBoundaryCoordinate(requested, branchID: branchID, in: bounds)
            else { return nil }
            guard let solved = BentoConstraintSolver().solve(state: next, in: bounds, constraints: constraints) else { return nil }
            next = solved
        }

        let applied = Dictionary(uniqueKeysWithValues: branchCoordinates.keys.compactMap { id -> (UUID, Double)? in
            guard let geometry = BentoTreeGeometry.boundary(id, in: next, bounds: bounds) else { return nil }
            return (id, geometry.resolvedCoordinate)
        })

        return BentoResizeResult(
            state: next,
            placements: next.placements(in: bounds),
            appliedCoordinates: applied
        )
    }
}

/// Fits externally changed native window frames back into the Bento tree.
/// Changed windows are preferred so a single native edge drag is adopted even
/// before its neighbor has been reflowed.
public struct BentoLayoutFitter: Sendable {
    public var tolerance: Double

    public init(tolerance: Double = 6) {
        self.tolerance = max(0, tolerance)
    }

    public func fit(
        state: BentoLayoutState,
        currentFrames: [WindowID: BTRect],
        changedWindowIDs: Set<WindowID>,
        in bounds: BTRect,
        constraints: [WindowID: WindowConstraints] = [:]
    ) -> BentoResizeResult? {
        guard state.root != nil, !changedWindowIDs.isEmpty else { return nil }
        var next = state
        var allApplied: [UUID: Double] = [:]
        let originalFrames = Dictionary(uniqueKeysWithValues: state.placements(in: bounds).map { ($0.windowID, $0.frame) })

        // Parents first. Orthogonal descendants remain valid when an ancestor
        // changes; their own parent geometry is recalculated before fitting.
        for descriptor in state.branches.sorted(by: { $0.depth < $1.depth }) {
            guard let geometry = BentoTreeGeometry.boundary(descriptor.id, in: next, bounds: bounds),
                  !geometry.isLocked
            else { continue }
            let expectedCoordinate = geometry.resolvedCoordinate
            var changedCandidates: [Double] = []

            for id in changedWindowIDs {
                guard let expected = originalFrames[id], let actual = currentFrames[id] else { continue }
                switch geometry.axis {
                case .vertical:
                    if geometry.before.windowIDs.contains(id), abs(expected.maxX - expectedCoordinate) <= tolerance {
                        changedCandidates.append(actual.maxX)
                    }
                    if geometry.after.windowIDs.contains(id), abs(expected.minX - expectedCoordinate) <= tolerance {
                        changedCandidates.append(actual.minX)
                    }
                case .horizontal:
                    if geometry.before.windowIDs.contains(id), abs(expected.maxY - expectedCoordinate) <= tolerance {
                        changedCandidates.append(actual.maxY)
                    }
                    if geometry.after.windowIDs.contains(id), abs(expected.minY - expectedCoordinate) <= tolerance {
                        changedCandidates.append(actual.minY)
                    }
                }
            }

            let coordinate: Double?
            if !changedCandidates.isEmpty {
                // A corner resize can contribute two close candidates. If they
                // disagree, the edge that moved furthest from the old split is
                // the user-controlled edge.
                coordinate = changedCandidates.max(by: {
                    abs($0 - expectedCoordinate) < abs($1 - expectedCoordinate)
                })
            } else {
                coordinate = stableSharedCoordinate(for: geometry, frames: currentFrames)
            }

            guard let coordinate, abs(coordinate - expectedCoordinate) > 0.5,
                  let result = BentoResizeEngine().resize(
                    state: next,
                    branchCoordinates: [descriptor.id: coordinate],
                    in: bounds,
                    constraints: constraints
                  )
            else { continue }
            next = result.state
            allApplied.merge(result.appliedCoordinates) { _, latest in latest }
        }

        guard !allApplied.isEmpty else { return nil }
        return BentoResizeResult(
            state: next,
            placements: next.placements(in: bounds),
            appliedCoordinates: allApplied
        )
    }

    private func stableSharedCoordinate(
        for boundary: BentoTreeGeometry.BoundaryGeometry,
        frames: [WindowID: BTRect]
    ) -> Double? {
        let first = boundary.before.windowIDs.compactMap { frames[$0] }
        let second = boundary.after.windowIDs.compactMap { frames[$0] }
        guard !first.isEmpty, !second.isEmpty else { return nil }
        let firstEdge: Double
        let secondEdge: Double
        switch boundary.axis {
        case .vertical:
            firstEdge = first.map(\.maxX).max()!
            secondEdge = second.map(\.minX).min()!
        case .horizontal:
            firstEdge = first.map(\.maxY).max()!
            secondEdge = second.map(\.minY).min()!
        }
        guard abs(secondEdge - firstEdge) <= tolerance else { return nil }
        return (firstEdge + secondEdge) / 2
    }
}

/// Resolves only shared edges that really exist in the current Accessibility
/// frames. The overlay therefore cannot drift into a window's interior when an
/// application clamps or delays a frame update.
public struct BentoBoundaryResolver: Sendable {
    public var tolerance: Double
    public var minimumSegmentLength: Double

    public init(tolerance: Double = 6, minimumSegmentLength: Double = 24) {
        self.tolerance = max(0, tolerance)
        self.minimumSegmentLength = max(1, minimumSegmentLength)
    }

    public func boundaries(
        state: BentoLayoutState,
        windows: [WindowSnapshot],
        displayID: DisplayID,
        bounds: BTRect
    ) -> [BoundaryDescriptor] {
        guard let root = state.root else { return [] }
        let normalizedRoot = BentoLayoutState.normalized(root)
        let frames = Dictionary(uniqueKeysWithValues: windows.map { ($0.id, $0.frame) })
        var output: [BoundaryDescriptor] = []

        func collect(_ node: BentoNode) {
            switch node {
            case .leaf, .vacant:
                return
            case let .partition(partition):
                for index in partition.boundaryIDs.indices {
                    let beforeNode = partition.children[index]
                    let afterNode = partition.children[index + 1]
                    let firstFrames = beforeNode.windowIDs.compactMap { id in frames[id].map { (id, $0) } }
                    let secondFrames = afterNode.windowIDs.compactMap { id in frames[id].map { (id, $0) } }
                    let parent = boundingRect((firstFrames + secondFrames).map(\.1)) ?? bounds
                    let boundaryID = partition.boundaryIDs[index]
                    var segments: [BoundaryDescriptor] = []

                    for (firstID, firstFrame) in firstFrames {
                        for (secondID, secondFrame) in secondFrames {
                            let coordinate: Double
                            let start: Double
                            let end: Double
                            switch partition.axis {
                            case .vertical:
                                guard abs((secondFrame.minX - firstFrame.maxX) - state.metrics.paneGap) <= tolerance else { continue }
                                coordinate = (firstFrame.maxX + secondFrame.minX) / 2
                                start = max(firstFrame.minY, secondFrame.minY)
                                end = min(firstFrame.maxY, secondFrame.maxY)
                            case .horizontal:
                                guard abs((secondFrame.minY - firstFrame.maxY) - state.metrics.paneGap) <= tolerance else { continue }
                                coordinate = (firstFrame.maxY + secondFrame.minY) / 2
                                start = max(firstFrame.minX, secondFrame.minX)
                                end = min(firstFrame.maxX, secondFrame.maxX)
                            }
                            guard end - start >= minimumSegmentLength else { continue }
                            segments.append(BoundaryDescriptor(
                                id: "", displayID: displayID, axis: partition.axis,
                                coordinate: coordinate, spanStart: start, spanEnd: end,
                                beforeWindowIDs: [firstID], afterWindowIDs: [secondID],
                                isLocked: partition.lockedBoundaryIDs.contains(boundaryID),
                                branchID: boundaryID, parentBounds: parent
                            ))
                        }
                    }

                    output += merge(segments, branchID: boundaryID).map { descriptor in
                        var descriptor = descriptor
                        descriptor.beforeWindowIDs = Set(beforeNode.windowIDs)
                        descriptor.afterWindowIDs = Set(afterNode.windowIDs)
                        return descriptor
                    }
                }
                partition.children.forEach(collect)
            }
        }

        collect(normalizedRoot)
        return output.sorted { ($0.axis.rawValue, $0.coordinate, $0.spanStart, $0.id) < ($1.axis.rawValue, $1.coordinate, $1.spanStart, $1.id) }
    }

    private func merge(_ segments: [BoundaryDescriptor], branchID: UUID) -> [BoundaryDescriptor] {
        var merged: [BoundaryDescriptor] = []
        for segment in segments.sorted(by: { $0.spanStart < $1.spanStart }) {
            if let index = merged.indices.last(where: {
                merged[$0].axis == segment.axis
                    && abs(merged[$0].coordinate - segment.coordinate) <= tolerance
                    && segment.spanStart <= merged[$0].spanEnd + tolerance
            }) {
                let existingLength = merged[index].spanEnd - merged[index].spanStart
                let newLength = segment.spanEnd - segment.spanStart
                merged[index].coordinate = (merged[index].coordinate * existingLength + segment.coordinate * newLength) / max(1, existingLength + newLength)
                merged[index].spanStart = min(merged[index].spanStart, segment.spanStart)
                merged[index].spanEnd = max(merged[index].spanEnd, segment.spanEnd)
                merged[index].beforeWindowIDs.formUnion(segment.beforeWindowIDs)
                merged[index].afterWindowIDs.formUnion(segment.afterWindowIDs)
            } else {
                merged.append(segment)
            }
        }
        return merged.enumerated().map { index, descriptor in
            var descriptor = descriptor
            descriptor.id = "bento:\(branchID.uuidString):\(index)"
            return descriptor
        }
    }

    private func boundingRect(_ frames: [BTRect]) -> BTRect? {
        guard let first = frames.first else { return nil }
        let minX = frames.dropFirst().reduce(first.minX) { min($0, $1.minX) }
        let minY = frames.dropFirst().reduce(first.minY) { min($0, $1.minY) }
        let maxX = frames.dropFirst().reduce(first.maxX) { max($0, $1.maxX) }
        let maxY = frames.dropFirst().reduce(first.maxY) { max($0, $1.maxY) }
        return BTRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

private enum BentoTreeGeometry {
    struct BoundaryGeometry {
        var axis: SplitAxis
        var before: BentoNode
        var after: BentoNode
        var isLocked: Bool
        var resolvedCoordinate: Double
    }

    static func boundary(
        _ id: UUID,
        in state: BentoLayoutState,
        bounds: BTRect
    ) -> BoundaryGeometry? {
        guard let root = state.root else { return nil }
        let normalizedRoot = BentoLayoutState.normalized(root)
        func find(_ node: BentoNode, rect: BTRect) -> BoundaryGeometry? {
            switch node {
            case .leaf, .vacant:
                return nil
            case let .partition(partition):
                let children = partitionRects(partition, in: rect, gap: state.metrics.paneGap)
                if let index = partition.boundaryIDs.firstIndex(of: id) {
                    let first = children[index]
                    let second = children[index + 1]
                    return BoundaryGeometry(
                        axis: partition.axis,
                        before: partition.children[index],
                        after: partition.children[index + 1],
                        isLocked: partition.lockedBoundaryIDs.contains(id),
                        resolvedCoordinate: partition.axis == .vertical
                            ? (first.maxX + second.minX) / 2
                            : (first.maxY + second.minY) / 2
                    )
                }
                for index in partition.children.indices {
                    if let match = find(partition.children[index], rect: children[index]) { return match }
                }
                return nil
            }
        }
        return find(normalizedRoot, rect: bounds)
    }

    static func minimumExtent(
        _ node: BentoNode,
        axis: SplitAxis,
        constraints: [WindowID: WindowConstraints],
        gap: Double = 0
    ) -> Double {
        switch node {
        case .vacant:
            return 0
        case let .leaf(id):
            let minimum = constraints[id]?.minimumSize ?? WindowConstraints().minimumSize
            return axis == .vertical ? minimum.width : minimum.height
        case let .partition(partition):
            let values = partition.children.map { minimumExtent($0, axis: axis, constraints: constraints, gap: gap) }
            return partition.axis == axis
                ? values.reduce(0, +) + gap * Double(max(0, values.count - 1))
                : values.max() ?? 0
        }
    }

    static func partitionRects(_ partition: BentoPartition, in rect: BTRect, gap: Double) -> [BTRect] {
        let extent = partition.axis == .vertical ? rect.size.width : rect.size.height
        let usable = max(0, extent - gap * Double(partition.children.count - 1))
        var cursor = partition.axis == .vertical ? rect.minX : rect.minY
        return partition.children.indices.map { index in
            let childExtent = index == partition.children.count - 1
                ? (partition.axis == .vertical ? rect.maxX : rect.maxY) - cursor
                : usable * partition.ratios[index]
            let child = partition.axis == .vertical
                ? BTRect(x: cursor, y: rect.minY, width: max(0, childExtent), height: rect.size.height)
                : BTRect(x: rect.minX, y: cursor, width: rect.size.width, height: max(0, childExtent))
            cursor += childExtent + gap
            return child
        }
    }
}
