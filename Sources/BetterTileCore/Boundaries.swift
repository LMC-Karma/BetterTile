import Foundation

public struct BoundaryDescriptor: Hashable, Identifiable, Sendable {
    public var id: String
    public var displayID: DisplayID
    public var axis: SplitAxis
    public var coordinate: Double
    public var spanStart: Double
    public var spanEnd: Double
    public var beforeWindowIDs: Set<WindowID>
    public var afterWindowIDs: Set<WindowID>
    public var isLocked: Bool
    public var branchID: UUID?
    /// The layout rectangle owned by the split that produced this edge.
    /// Linked/manual boundaries leave this unset.
    public var parentBounds: BTRect?

    public init(
        id: String,
        displayID: DisplayID,
        axis: SplitAxis,
        coordinate: Double,
        spanStart: Double,
        spanEnd: Double,
        beforeWindowIDs: Set<WindowID>,
        afterWindowIDs: Set<WindowID>,
        isLocked: Bool = false,
        branchID: UUID? = nil,
        parentBounds: BTRect? = nil
    ) {
        self.id = id
        self.displayID = displayID
        self.axis = axis
        self.coordinate = coordinate
        self.spanStart = min(spanStart, spanEnd)
        self.spanEnd = max(spanStart, spanEnd)
        self.beforeWindowIDs = beforeWindowIDs
        self.afterWindowIDs = afterWindowIDs
        self.isLocked = isLocked
        self.branchID = branchID
        self.parentBounds = parentBounds
    }

    public func hitFrame(width: Double) -> BTRect {
        switch axis {
        case .vertical:
            BTRect(x: coordinate - width / 2, y: spanStart, width: width, height: spanEnd - spanStart)
        case .horizontal:
            BTRect(x: spanStart, y: coordinate - width / 2, width: spanEnd - spanStart, height: width)
        }
    }
}

/// Separates the generous pointer-search radius from the panel that actually
/// receives clicks. Bento handles own only their real gap, leaving the native
/// resize regions on both neighboring windows available to macOS.
public enum DividerInteractionMetrics {
    public static func captureWidth(
        isBento: Bool,
        paneGap: Double,
        dividerThickness: Double
    ) -> Double {
        isBento
            ? max(0, paneGap)
            : max(18, dividerThickness * 3)
    }
}

public struct DividerVisualMetrics: Equatable, Sendable {
    public let capsuleLength: Double
    public let capsuleThickness: Double
    public let junctionDiameter: Double
    public let capsulePanelThickness: Double
    public let junctionPanelDiameter: Double

    public init(handleSize: Double) {
        let size = min(12, max(2, handleSize))
        capsuleLength = 32 + size * 4
        capsuleThickness = size
        junctionDiameter = min(20, max(10, size + 8))
        capsulePanelThickness = max(18, size * 3)
        junctionPanelDiameter = max(22, size * 3)
    }
}

public extension BentoLayoutState {
    func boundaries(in bounds: BTRect, displayID: DisplayID) -> [BoundaryDescriptor] {
        guard let root else { return [] }
        let normalizedRoot = BentoLayoutState.normalized(root)
        func collect(_ node: BentoNode, rect: BTRect) -> [BoundaryDescriptor] {
            switch node {
            case .leaf, .vacant:
                return []
            case .branch:
                return collect(BentoLayoutState.normalized(node), rect: rect)
            case let .partition(partition):
                let rects = partitionChildRects(partition, in: rect)
                let descriptors = partition.boundaryIDs.indices.map { index in
                    let first = rects[index]
                    let second = rects[index + 1]
                    let boundaryID = partition.boundaryIDs[index]
                    return BoundaryDescriptor(
                        id: "bento:\(boundaryID.uuidString)",
                        displayID: displayID,
                        axis: partition.axis,
                        coordinate: partition.axis == .vertical
                            ? (first.maxX + second.minX) / 2
                            : (first.maxY + second.minY) / 2,
                        spanStart: partition.axis == .vertical ? rect.minY : rect.minX,
                        spanEnd: partition.axis == .vertical ? rect.maxY : rect.maxX,
                        beforeWindowIDs: Set(partition.children[index].windowIDs),
                        afterWindowIDs: Set(partition.children[index + 1].windowIDs),
                        isLocked: partition.lockedBoundaryIDs.contains(boundaryID),
                        branchID: boundaryID,
                        parentBounds: rect
                    )
                }
                return descriptors + partition.children.indices.flatMap {
                    collect(partition.children[$0], rect: rects[$0])
                }
            }
        }
        return collect(normalizedRoot, rect: bounds)
    }
}

public extension LinkedResizeEngine {
    func boundaries(in windows: [WindowSnapshot], displayID: DisplayID) -> [BoundaryDescriptor] {
        let displayWindows = windows.filter { $0.displayID == displayID }
        let indexed = Dictionary(uniqueKeysWithValues: displayWindows.map { ($0.id, $0) })
        let raw = adjacencies(in: displayWindows).compactMap { adjacency -> BoundaryDescriptor? in
            guard let first = indexed[adjacency.first], let second = indexed[adjacency.second] else { return nil }
            switch (adjacency.firstEdge, adjacency.secondEdge) {
            case (.right, .left):
                return makeLinkedBoundary(displayID: displayID, axis: .vertical,
                    coordinate: (first.frame.maxX + second.frame.minX) / 2,
                    spanStart: max(first.frame.minY, second.frame.minY), spanEnd: min(first.frame.maxY, second.frame.maxY),
                    before: first.id, after: second.id)
            case (.left, .right):
                return makeLinkedBoundary(displayID: displayID, axis: .vertical,
                    coordinate: (first.frame.minX + second.frame.maxX) / 2,
                    spanStart: max(first.frame.minY, second.frame.minY), spanEnd: min(first.frame.maxY, second.frame.maxY),
                    before: second.id, after: first.id)
            case (.bottom, .top):
                return makeLinkedBoundary(displayID: displayID, axis: .horizontal,
                    coordinate: (first.frame.maxY + second.frame.minY) / 2,
                    spanStart: max(first.frame.minX, second.frame.minX), spanEnd: min(first.frame.maxX, second.frame.maxX),
                    before: first.id, after: second.id)
            case (.top, .bottom):
                return makeLinkedBoundary(displayID: displayID, axis: .horizontal,
                    coordinate: (first.frame.minY + second.frame.maxY) / 2,
                    spanStart: max(first.frame.minX, second.frame.minX), spanEnd: min(first.frame.maxX, second.frame.maxX),
                    before: second.id, after: first.id)
            default:
                return nil
            }
        }
        return mergeLinkedBoundaries(raw)
    }

    func resize(
        boundary: BoundaryDescriptor,
        delta requestedDelta: Double,
        windows: [WindowSnapshot],
        bounds: BTRect,
        lockedWindowIDs: Set<WindowID> = []
    ) -> LinkedResizeResult? {
        guard !boundary.isLocked else { return nil }
        let indexed = Dictionary(uniqueKeysWithValues: windows.map { ($0.id, $0) })
        let before = boundary.beforeWindowIDs.compactMap { indexed[$0] }
        let after = boundary.afterWindowIDs.compactMap { indexed[$0] }
        guard !before.isEmpty, !after.isEmpty,
              before.allSatisfy({
                  $0.displayID == boundary.displayID
                      && $0.isEligible && !$0.isFloating && !lockedWindowIDs.contains($0.id)
              }),
              after.allSatisfy({
                  $0.displayID == boundary.displayID
                      && $0.isEligible && !$0.isFloating && !lockedWindowIDs.contains($0.id)
              })
        else { return nil }

        let vertical = boundary.axis == .vertical
        var minimumDelta = vertical ? bounds.minX - boundary.coordinate : bounds.minY - boundary.coordinate
        var maximumDelta = vertical ? bounds.maxX - boundary.coordinate : bounds.maxY - boundary.coordinate
        for window in before {
            let extent = vertical ? window.frame.size.width : window.frame.size.height
            let minimum = vertical ? window.constraints.minimumSize.width : window.constraints.minimumSize.height
            minimumDelta = max(minimumDelta, -(extent - minimum))
        }
        for window in after {
            let extent = vertical ? window.frame.size.width : window.frame.size.height
            let minimum = vertical ? window.constraints.minimumSize.width : window.constraints.minimumSize.height
            maximumDelta = min(maximumDelta, extent - minimum)
        }
        let delta = min(max(requestedDelta, minimumDelta), maximumDelta)
        let beforePlacements = before.map { window in
            Placement(windowID: window.id, frame: vertical
                ? BTRect(x: window.frame.minX, y: window.frame.minY, width: window.frame.size.width + delta, height: window.frame.size.height)
                : BTRect(x: window.frame.minX, y: window.frame.minY, width: window.frame.size.width, height: window.frame.size.height + delta))
        }
        let afterPlacements = after.map { window in
            Placement(windowID: window.id, frame: vertical
                ? BTRect(x: window.frame.minX + delta, y: window.frame.minY, width: window.frame.size.width - delta, height: window.frame.size.height)
                : BTRect(x: window.frame.minX, y: window.frame.minY + delta, width: window.frame.size.width, height: window.frame.size.height - delta))
        }
        return LinkedResizeResult(placements: (beforePlacements + afterPlacements).sorted { $0.windowID < $1.windowID }, appliedDelta: delta)
    }

    private func makeLinkedBoundary(
        displayID: DisplayID, axis: SplitAxis, coordinate: Double, spanStart: Double, spanEnd: Double,
        before: WindowID, after: WindowID
    ) -> BoundaryDescriptor {
        BoundaryDescriptor(id: "", displayID: displayID, axis: axis, coordinate: coordinate,
            spanStart: spanStart, spanEnd: spanEnd, beforeWindowIDs: [before], afterWindowIDs: [after])
    }

    private func mergeLinkedBoundaries(_ boundaries: [BoundaryDescriptor]) -> [BoundaryDescriptor] {
        var merged: [BoundaryDescriptor] = []
        for boundary in boundaries.sorted(by: { ($0.axis.rawValue, $0.coordinate, $0.spanStart) < ($1.axis.rawValue, $1.coordinate, $1.spanStart) }) {
            if let index = merged.indices.last(where: {
                merged[$0].axis == boundary.axis
                    && abs(merged[$0].coordinate - boundary.coordinate) <= tolerance
                    && boundary.spanStart <= merged[$0].spanEnd + tolerance
                    && boundary.spanEnd >= merged[$0].spanStart - tolerance
            }) {
                merged[index].coordinate = (merged[index].coordinate + boundary.coordinate) / 2
                merged[index].spanStart = min(merged[index].spanStart, boundary.spanStart)
                merged[index].spanEnd = max(merged[index].spanEnd, boundary.spanEnd)
                merged[index].beforeWindowIDs.formUnion(boundary.beforeWindowIDs)
                merged[index].afterWindowIDs.formUnion(boundary.afterWindowIDs)
            } else {
                merged.append(boundary)
            }
        }
        return merged.map { boundary in
            var boundary = boundary
            let before = boundary.beforeWindowIDs.map(\.rawValue).sorted().joined(separator: ",")
            let after = boundary.afterWindowIDs.map(\.rawValue).sorted().joined(separator: ",")
            boundary.id = "linked:\(boundary.axis.rawValue):\(Int(boundary.coordinate.rounded())):\(before):\(after)"
            return boundary
        }
    }
}
