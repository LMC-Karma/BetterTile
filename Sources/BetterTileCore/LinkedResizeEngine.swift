import Foundation

public enum WindowEdge: String, Codable, Sendable {
    case left, right, top, bottom
}

public struct Adjacency: Codable, Hashable, Sendable {
    public var first: WindowID
    public var second: WindowID
    public var firstEdge: WindowEdge
    public var secondEdge: WindowEdge

    public init(first: WindowID, second: WindowID, firstEdge: WindowEdge, secondEdge: WindowEdge) {
        self.first = first
        self.second = second
        self.firstEdge = firstEdge
        self.secondEdge = secondEdge
    }
}

public struct LinkedResizeResult: Sendable, Equatable {
    public var placements: [Placement]
    public var appliedDelta: Double

    public init(placements: [Placement], appliedDelta: Double) {
        self.placements = placements
        self.appliedDelta = appliedDelta
    }
}

public struct LinkedResizeEngine: Sendable {
    public var tolerance: Double

    public init(tolerance: Double = 6) { self.tolerance = max(0, tolerance) }

    public func adjacencies(in windows: [WindowSnapshot]) -> [Adjacency] {
        let eligible = windows.filter { $0.isEligible && !$0.isFloating }.sorted { $0.id < $1.id }
        var result: [Adjacency] = []
        for firstIndex in eligible.indices {
            for secondIndex in eligible.indices where secondIndex > firstIndex {
                let first = eligible[firstIndex]
                let second = eligible[secondIndex]
                guard first.displayID == second.displayID else { continue }
                if abs(first.frame.maxX - second.frame.minX) <= tolerance, verticalOverlap(first.frame, second.frame) > tolerance {
                    result.append(.init(first: first.id, second: second.id, firstEdge: .right, secondEdge: .left))
                } else if abs(second.frame.maxX - first.frame.minX) <= tolerance, verticalOverlap(first.frame, second.frame) > tolerance {
                    result.append(.init(first: first.id, second: second.id, firstEdge: .left, secondEdge: .right))
                }
                if abs(first.frame.maxY - second.frame.minY) <= tolerance, horizontalOverlap(first.frame, second.frame) > tolerance {
                    result.append(.init(first: first.id, second: second.id, firstEdge: .bottom, secondEdge: .top))
                } else if abs(second.frame.maxY - first.frame.minY) <= tolerance, horizontalOverlap(first.frame, second.frame) > tolerance {
                    result.append(.init(first: first.id, second: second.id, firstEdge: .top, secondEdge: .bottom))
                }
            }
        }
        return result
    }

    /// Moves one shared boundary and all windows touching it. The returned delta is globally clamped.
    public func resize(
        windowID: WindowID,
        edge: WindowEdge,
        delta requestedDelta: Double,
        windows: [WindowSnapshot],
        bounds: BTRect,
        lockedWindowIDs: Set<WindowID> = []
    ) -> LinkedResizeResult? {
        guard let source = windows.first(where: { $0.id == windowID }), source.isEligible, !source.isFloating else { return nil }
        let vertical = edge == .left || edge == .right
        let boundary = switch edge {
        case .left: source.frame.minX
        case .right: source.frame.maxX
        case .top: source.frame.minY
        case .bottom: source.frame.maxY
        }
        let candidates = windows.filter { window in
            window.displayID == source.displayID
                && window.isEligible && !window.isFloating && !lockedWindowIDs.contains(window.id) && (vertical
                ? verticalOverlap(window.frame, source.frame) > tolerance
                : horizontalOverlap(window.frame, source.frame) > tolerance)
        }
        let before = candidates.filter {
            vertical ? abs($0.frame.maxX - boundary) <= tolerance : abs($0.frame.maxY - boundary) <= tolerance
        }
        let after = candidates.filter {
            vertical ? abs($0.frame.minX - boundary) <= tolerance : abs($0.frame.minY - boundary) <= tolerance
        }
        guard !before.isEmpty, !after.isEmpty else { return nil }

        var minimumDelta = vertical ? bounds.minX - boundary : bounds.minY - boundary
        var maximumDelta = vertical ? bounds.maxX - boundary : bounds.maxY - boundary
        for window in before {
            let available = (vertical ? window.frame.size.width : window.frame.size.height)
                - (vertical ? window.constraints.minimumSize.width : window.constraints.minimumSize.height)
            minimumDelta = max(minimumDelta, -available)
        }
        for window in after {
            let available = (vertical ? window.frame.size.width : window.frame.size.height)
                - (vertical ? window.constraints.minimumSize.width : window.constraints.minimumSize.height)
            maximumDelta = min(maximumDelta, available)
        }
        let delta = min(max(requestedDelta, minimumDelta), maximumDelta)
        var placements: [Placement] = []
        for window in before {
            let frame = vertical
                ? BTRect(x: window.frame.minX, y: window.frame.minY, width: window.frame.size.width + delta, height: window.frame.size.height)
                : BTRect(x: window.frame.minX, y: window.frame.minY, width: window.frame.size.width, height: window.frame.size.height + delta)
            placements.append(.init(windowID: window.id, frame: frame))
        }
        for window in after {
            let frame = vertical
                ? BTRect(x: window.frame.minX + delta, y: window.frame.minY, width: window.frame.size.width - delta, height: window.frame.size.height)
                : BTRect(x: window.frame.minX, y: window.frame.minY + delta, width: window.frame.size.width, height: window.frame.size.height - delta)
            placements.append(.init(windowID: window.id, frame: frame))
        }
        return LinkedResizeResult(placements: placements.sorted { $0.windowID < $1.windowID }, appliedDelta: delta)
    }

    private func verticalOverlap(_ lhs: BTRect, _ rhs: BTRect) -> Double { max(0, min(lhs.maxY, rhs.maxY) - max(lhs.minY, rhs.minY)) }
    private func horizontalOverlap(_ lhs: BTRect, _ rhs: BTRect) -> Double { max(0, min(lhs.maxX, rhs.maxX) - max(lhs.minX, rhs.minX)) }
}
