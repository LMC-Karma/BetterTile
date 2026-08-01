import Foundation

public enum BentoDragOutcome: Equatable, Sendable {
    case swap(targetWindowID: WindowID)
    case insert(targetWindowID: WindowID, edge: BentoPaneDropPosition)
    case snap(action: WindowAction, frame: BTRect)
    case customZone(id: UUID, frame: BTRect)
    case restore
}

public enum BentoPaneDropPosition: String, Equatable, Hashable, Sendable {
    case center
    case left
    case right
    case top
    case bottom

    public static func resolve(
        _ point: BTPoint,
        in frame: BTRect,
        retaining previous: Self? = nil,
        edgeFraction: Double = 0.15,
        minimumEdgeDepth: Double = 18,
        hysteresis: Double = 12
    ) -> Self {
        let fraction = min(0.4, max(0.1, edgeFraction))
        let minimum = max(0, minimumEdgeDepth)
        let horizontalInset = min(
            frame.size.width * 0.4,
            max(minimum, frame.size.width * fraction)
        )
        let verticalInset = min(
            frame.size.height * 0.4,
            max(minimum, frame.size.height * fraction)
        )
        if let previous {
            let margin = max(0, hysteresis)
            let retained = switch previous {
            case .center:
                point.x >= frame.minX + horizontalInset - margin
                    && point.x <= frame.maxX - horizontalInset + margin
                    && point.y >= frame.minY + verticalInset - margin
                    && point.y <= frame.maxY - verticalInset + margin
            case .left: point.x <= frame.minX + horizontalInset + margin
            case .right: point.x >= frame.maxX - horizontalInset - margin
            case .top: point.y <= frame.minY + verticalInset + margin
            case .bottom: point.y >= frame.maxY - verticalInset - margin
            }
            if retained { return previous }
        }
        let horizontal = min(point.x - frame.minX, frame.maxX - point.x) / max(1, horizontalInset)
        let vertical = min(point.y - frame.minY, frame.maxY - point.y) / max(1, verticalInset)
        guard min(horizontal, vertical) < 1 else { return .center }
        if horizontal < vertical { return point.x < frame.midX ? .left : .right }
        return point.y < frame.midY ? .top : .bottom
    }

    public var axis: SplitAxis? {
        switch self {
        case .center: nil
        case .left, .right: .vertical
        case .top, .bottom: .horizontal
        }
    }

    public var sourceComesFirst: Bool { self == .left || self == .top }
}

public struct BentoHoverCandidate: Equatable, Sendable {
    public let displayID: DisplayID
    public let targetWindowID: WindowID
    public let position: BentoPaneDropPosition

    public init(displayID: DisplayID, targetWindowID: WindowID, position: BentoPaneDropPosition) {
        self.displayID = displayID
        self.targetWindowID = targetWindowID
        self.position = position
    }
}

public struct BentoDropHoverState: Sendable {
    public private(set) var candidate: BentoHoverCandidate?
    private var enteredAt: TimeInterval?
    private var competingSnapTarget: SnapTarget?

    public init() {}

    @discardableResult
    public mutating func observe(
        _ candidate: BentoHoverCandidate,
        competingSnapTarget: SnapTarget? = nil,
        at time: TimeInterval
    ) -> Bool {
        guard self.candidate != candidate || self.competingSnapTarget != competingSnapTarget else {
            return false
        }
        self.candidate = candidate
        self.competingSnapTarget = competingSnapTarget
        enteredAt = time
        return true
    }

    public func armedCandidate(at time: TimeInterval, delay: TimeInterval) -> BentoHoverCandidate? {
        guard let candidate, let enteredAt,
              time - enteredAt + 1e-9 >= max(0, delay)
        else { return nil }
        return candidate
    }

    public func outcome(
        at time: TimeInterval,
        delay: TimeInterval,
        snapTarget: SnapTarget?
    ) -> BentoDragOutcome {
        if let candidate = armedCandidate(at: time, delay: delay) {
            return candidate.position == .center
                ? .swap(targetWindowID: candidate.targetWindowID)
                : .insert(targetWindowID: candidate.targetWindowID, edge: candidate.position)
        }
        if let snapTarget, let action = snapTarget.action {
            return .snap(action: action, frame: snapTarget.frame)
        }
        if let snapTarget, let zoneID = snapTarget.zoneID {
            return .customZone(id: zoneID, frame: snapTarget.frame)
        }
        return .restore
    }

    public mutating func clear() {
        candidate = nil
        enteredAt = nil
        competingSnapTarget = nil
    }
}

public enum BentoDragPreview {
    public static func changedPlacements(
        _ placements: [Placement],
        baselineFrames: [WindowID: BTRect],
        excluding sourceWindowID: WindowID,
        tolerance: Double = 2
    ) -> [Placement] {
        let tolerance = max(0, tolerance)
        return placements.filter { placement in
            guard placement.windowID != sourceWindowID else { return false }
            guard let baseline = baselineFrames[placement.windowID] else { return true }
            return abs(placement.frame.minX - baseline.minX) > tolerance
                || abs(placement.frame.minY - baseline.minY) > tolerance
                || abs(placement.frame.size.width - baseline.size.width) > tolerance
                || abs(placement.frame.size.height - baseline.size.height) > tolerance
        }
    }
}

/// Immutable layout and geometry captured before macOS begins moving a Bento
/// window. Accessibility move events can continue arriving during the gesture
/// without changing this snapshot or the slot reserved for the source window.
public struct BentoDragSession: Sendable {
    public let displayID: DisplayID
    public let sourceWindowID: WindowID
    public let originalState: BentoLayoutState
    public let workArea: BTRect
    public let baselineFrames: [WindowID: BTRect]
    public let constraints: [WindowID: WindowConstraints]
    public let managedWindowIDs: Set<WindowID>
    public let contextWindowIDs: Set<WindowID>
    public let sourceReservedFrame: BTRect

    public init?(
        displayID: DisplayID,
        sourceWindowID: WindowID,
        state: BentoLayoutState,
        windows: [WindowSnapshot],
        workArea: BTRect,
        useLayoutFrames: Bool = false,
        tolerance: Double = 0.5
    ) {
        let treeWindowIDs = Set(state.root?.windowIDs ?? [])
        let managedWindowIDs = treeWindowIDs.union([sourceWindowID])
        guard !treeWindowIDs.isEmpty else { return nil }

        let indexed = Dictionary(uniqueKeysWithValues: windows.map { ($0.id, $0) })
        guard managedWindowIDs.allSatisfy({ indexed[$0]?.isEligible == true }) else { return nil }
        let constraints = Dictionary(uniqueKeysWithValues: managedWindowIDs.compactMap { id in
            indexed[id].map { (id, $0.constraints) }
        })
        var baselineFrames = Dictionary(uniqueKeysWithValues: managedWindowIDs.compactMap { id in
            indexed[id].map { (id, $0.frame) }
        })
        if useLayoutFrames {
            for placement in state.placements(in: workArea) where treeWindowIDs.contains(placement.windowID) {
                baselineFrames[placement.windowID] = placement.frame
            }
        }
        guard constraints.count == managedWindowIDs.count,
              baselineFrames.count == managedWindowIDs.count
        else { return nil }

        // A move gesture must not become an implicit resize. Validate the
        // captured weights exactly as they are instead of projecting them to
        // a newly solved layout.
        let placements = state.placements(in: workArea)
            .filter { treeWindowIDs.contains($0.windowID) }
        guard Set(placements.map(\.windowID)) == treeWindowIDs,
              placements.allSatisfy({ Self.contains($0.frame, in: workArea, tolerance: tolerance) })
        else { return nil }
        let sourceReservedFrame = placements.first(where: { $0.windowID == sourceWindowID })?.frame
            ?? baselineFrames[sourceWindowID]!

        self.displayID = displayID
        self.sourceWindowID = sourceWindowID
        originalState = state
        self.workArea = workArea
        self.baselineFrames = baselineFrames
        self.constraints = constraints
        self.managedWindowIDs = managedWindowIDs
        contextWindowIDs = Set(windows.filter { $0.displayID == displayID && $0.isEligible }.map(\.id))
        self.sourceReservedFrame = sourceReservedFrame
    }

    public var restorePlacement: Placement {
        Placement(windowID: sourceWindowID, frame: baselineFrames[sourceWindowID] ?? sourceReservedFrame)
    }

    private static func contains(_ frame: BTRect, in bounds: BTRect, tolerance: Double) -> Bool {
        !frame.isEmpty
            && frame.minX >= bounds.minX - tolerance
            && frame.minY >= bounds.minY - tolerance
            && frame.maxX <= bounds.maxX + tolerance
            && frame.maxY <= bounds.maxY + tolerance
    }
}

public struct BentoDragEventBuffer: Sendable {
    public private(set) var frameEventWindowIDs: Set<WindowID> = []
    public private(set) var resizedWindowIDs: Set<WindowID> = []
    public private(set) var topologyChanged = false

    public init() {}

    public mutating func record(_ event: WindowSystemEvent) {
        switch event.kind {
        case .moved:
            if let windowID = event.windowID { frameEventWindowIDs.insert(windowID) }
        case .resized:
            if let windowID = event.windowID {
                frameEventWindowIDs.insert(windowID)
                resizedWindowIDs.insert(windowID)
            }
        case .created, .destroyed, .minimized, .restored:
            topologyChanged = true
        case .focused:
            break
        }
    }

    public mutating func drain() -> (
        frameEventWindowIDs: Set<WindowID>,
        resizedWindowIDs: Set<WindowID>,
        topologyChanged: Bool
    ) {
        let result = (
            frameEventWindowIDs: frameEventWindowIDs,
            resizedWindowIDs: resizedWindowIDs,
            topologyChanged: topologyChanged
        )
        frameEventWindowIDs.removeAll()
        resizedWindowIDs.removeAll()
        topologyChanged = false
        return result
    }
}
