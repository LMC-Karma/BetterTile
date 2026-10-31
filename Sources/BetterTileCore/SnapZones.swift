import Foundation

public enum SnapArea: String, Codable, CaseIterable, Identifiable, Sendable {
    case topLeft, top, topRight
    case left, right
    case bottomLeft, bottom, bottomRight

    public var id: Self { self }

    public var title: String {
        switch self {
        case .topLeft: "Top Left Corner"
        case .top: "Top Edge"
        case .topRight: "Top Right Corner"
        case .left: "Left Edge"
        case .right: "Right Edge"
        case .bottomLeft: "Bottom Left Corner"
        case .bottom: "Bottom Edge"
        case .bottomRight: "Bottom Right Corner"
        }
    }
}

public struct SnapAreaBinding: Codable, Hashable, Identifiable, Sendable {
    public var area: SnapArea
    public var action: WindowAction?
    public var id: SnapArea { area }

    public init(area: SnapArea, action: WindowAction?) {
        self.area = area
        self.action = action
    }
}

public extension WindowAction {
    static let snapAssignableActions: [WindowAction] = [
        .leftHalf, .rightHalf, .topHalf, .bottomHalf,
        .leftThird, .centerThird, .rightThird,
        .leftTwoThirds, .rightTwoThirds,
        .topLeftQuarter, .topRightQuarter, .bottomLeftQuarter, .bottomRightQuarter,
        .topLeftSixth, .topCenterSixth, .topRightSixth,
        .bottomLeftSixth, .bottomCenterSixth, .bottomRightSixth,
        .maximize, .almostMaximize, .center, .centerResize,
    ]
}

public struct SnapTarget: Equatable, Sendable {
    public var action: WindowAction?
    public var frame: BTRect

    public init(action: WindowAction? = nil, frame: BTRect) {
        self.action = action
        self.frame = frame
    }
}

/// Activation values derived from the existing edge and corner-extension settings.
public struct SnapZoneActivation: Equatable, Sendable {
    public var edge: Double
    public var cornerExtension: Double
    public var reach: Double { edge + cornerExtension }
    public var reachRange: ClosedRange<Double> {
        (edge + SnapZoneDetector.cornerActivationRange.lowerBound)...(edge + SnapZoneDetector.cornerActivationRange.upperBound)
    }

    public init(edge: Double, cornerExtension: Double) {
        self.edge = edge
        self.cornerExtension = cornerExtension
    }

    public func settingReach(_ reach: Double) -> Self {
        let clamped = min(max(reach, reachRange.lowerBound), reachRange.upperBound)
        return Self(edge: edge, cornerExtension: clamped - edge)
    }

    /// Preserve total reach where possible, then clamp it to the new edge's range.
    public func settingEdge(_ edge: Double) -> Self {
        let clamped = min(max(edge, SnapZoneDetector.edgeActivationRange.lowerBound), SnapZoneDetector.edgeActivationRange.upperBound)
        return Self(edge: clamped, cornerExtension: cornerExtension).settingReach(reach)
    }
}

public enum SnapZonePreset: String, CaseIterable, Identifiable, Sendable {
    case narrow, standard, wide

    public var id: Self { self }
    public var title: String {
        switch self {
        case .narrow: "Narrow"
        case .standard: "Standard"
        case .wide: "Wide"
        }
    }

    public var activation: SnapZoneActivation {
        switch self {
        case .narrow: .init(edge: 3, cornerExtension: 45)
        case .standard: .init(edge: 5, cornerExtension: 64)
        case .wide: .init(edge: 12, cornerExtension: 108)
        }
    }

    /// Nil represents Custom. Match exact stored values without rounding.
    public static func matching(_ activation: SnapZoneActivation) -> Self? {
        allCases.first { $0.activation == activation }
    }
}

public struct SnapZoneDetector: Sendable {
    public static let defaultEdgeActivationDistance: Double = 5
    public static let defaultCornerActivationSize: Double = 64
    public static let edgeActivationRange: ClosedRange<Double> = 1...40
    public static let cornerActivationRange: ClosedRange<Double> = 16...160

    public var edgeActivationDistance: Double
    public var cornerActivationSize: Double

    public init(
        edgeActivationDistance: Double = Self.defaultEdgeActivationDistance,
        cornerActivationSize: Double = Self.defaultCornerActivationSize
    ) {
        self.edgeActivationDistance = edgeActivationDistance
        self.cornerActivationSize = cornerActivationSize
    }

    public func target(
        at point: BTPoint,
        display: DisplaySnapshot,
        snapAreas: [SnapAreaBinding] = BetterTileConfiguration.defaultSnapAreaBindings,
        window: WindowSnapshot? = nil
    ) -> SnapTarget? {
        let screenBounds = display.frame
        let placementBounds = display.visibleFrame
        guard screenBounds.contains(point) else { return nil }

        if let area = area(at: point, in: screenBounds) {
            guard let action = snapAreas.first(where: { $0.area == area })?.action else { return nil }
            let placeholder = WindowSnapshot(id: .init(rawValue: "snap-preview"), processIdentifier: 0, frame: placementBounds, displayID: display.id)
            let frame = StandardActionEngine().targetFrame(for: action, window: window ?? placeholder, display: display) ?? placementBounds
            return SnapTarget(action: action, frame: frame)
        }
        return nil
    }

    public func isInEdgeBand(at point: BTPoint, in bounds: BTRect) -> Bool {
        guard bounds.contains(point) else { return false }
        return point.x <= bounds.minX + edgeActivationDistance
            || point.x >= bounds.maxX - edgeActivationDistance
            || point.y <= bounds.minY + edgeActivationDistance
            || point.y >= bounds.maxY - edgeActivationDistance
    }

    public func area(at point: BTPoint, in bounds: BTRect) -> SnapArea? {
        guard bounds.contains(point) else { return nil }
        let cornerDistance = edgeActivationDistance + cornerActivationSize
        let inLeftCorner = point.x <= bounds.minX + cornerDistance
        let inRightCorner = point.x >= bounds.maxX - cornerDistance
        let inTopCorner = point.y <= bounds.minY + cornerDistance
        let inBottomCorner = point.y >= bounds.maxY - cornerDistance

        switch (inLeftCorner, inRightCorner, inTopCorner, inBottomCorner) {
        case (true, _, true, _): return .topLeft
        case (_, true, true, _): return .topRight
        case (true, _, _, true): return .bottomLeft
        case (_, true, _, true): return .bottomRight
        default: break
        }

        if point.x <= bounds.minX + edgeActivationDistance { return .left }
        if point.x >= bounds.maxX - edgeActivationDistance { return .right }
        if point.y <= bounds.minY + edgeActivationDistance { return .top }
        if point.y >= bounds.maxY - edgeActivationDistance { return .bottom }
        return nil
    }
}
