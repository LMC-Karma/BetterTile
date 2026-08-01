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
    public var zoneID: UUID?
    public var frame: BTRect

    public init(action: WindowAction? = nil, zoneID: UUID? = nil, frame: BTRect) {
        self.action = action
        self.zoneID = zoneID
        self.frame = frame
    }
}

public struct SnapZoneDetector: Sendable {
    public var edgeActivationDistance: Double
    public var cornerActivationSize: Double

    public init(edgeActivationDistance: Double = 5, cornerActivationSize: Double = 20) {
        self.edgeActivationDistance = edgeActivationDistance
        self.cornerActivationSize = cornerActivationSize
    }

    public func target(
        at point: BTPoint,
        display: DisplaySnapshot,
        snapAreas: [SnapAreaBinding] = BetterTileConfiguration.defaultSnapAreaBindings,
        customZones: [CustomZone] = []
    ) -> SnapTarget? {
        let screenBounds = display.frame
        let placementBounds = display.visibleFrame
        guard screenBounds.contains(point) else { return nil }

        if let area = area(at: point, in: screenBounds) {
            guard let action = snapAreas.first(where: { $0.area == area })?.action else { return nil }
            let placeholder = WindowSnapshot(id: .init(rawValue: "snap-preview"), processIdentifier: 0, frame: placementBounds, displayID: display.id)
            let frame = StandardActionEngine().targetFrame(for: action, window: placeholder, display: display) ?? placementBounds
            return SnapTarget(action: action, frame: frame)
        }
        for zone in customZones {
            let frame = zone.rect.frame(in: placementBounds)
            if frame.contains(point) { return SnapTarget(zoneID: zone.id, frame: frame) }
        }
        return nil
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
