import Foundation

/// Choice for holding an open group past the wheel's rim.
public enum LayoutWheelSubmenuLockBeyondRim: String, CaseIterable, Sendable {
    /// Keep the open group and its aim anywhere outside the rim.
    case keep
    /// Hold within the group's sector and option span plus the leave margin.
    /// Leaving that angle cancels selection until the pointer returns to the ring.
    case withinGroupAngle
}

/// Choice for how a Grouped wheel shows a group's options.
public enum LayoutWheelSubmenuStyle: String, CaseIterable, Codable, Sendable {
    /// Options in a tight arc just outside the rim, centred on the group.
    case fan
    /// Options as a small ring of bubbles that grows out of the group's chevron.
    case cluster
    /// A cluster for groups with more than three options, a fan otherwise.
    case clusterAboveThree
}

/// Where a group's options sit, in top-left points relative to the wheel
/// centre. Pure geometry: the drawing and the selection both read it.
public struct LayoutWheelSubmenuLayout: Equatable, Sendable {
    /// The wheel's outer edge, including the room for the chevron.
    public var rimRadius: Double
    /// One option bubble's radius.
    public var optionRadius: Double
    /// The gap between neighbouring options.
    public var spacing: Double
    /// The gap between the rim and the nearest option.
    public var clearance: Double
    public var style: LayoutWheelSubmenuStyle

    public init(rimRadius: Double, optionRadius: Double, spacing: Double = 6, clearance: Double = 8,
                style: LayoutWheelSubmenuStyle = .fan) {
        self.rimRadius = rimRadius
        self.optionRadius = max(1, optionRadius)
        self.spacing = max(0, spacing)
        self.clearance = max(0, clearance)
        self.style = style
    }

    public func usesCluster(count: Int) -> Bool {
        switch style {
        case .fan: false
        case .cluster: count >= 3
        case .clusterAboveThree: count > 3
        }
    }

    static func sectorAngle(_ sector: LayoutWheelSector) -> Double {
        -Double.pi / 2 + Double(sector.rawValue) * .pi / 4
    }

    /// The chevron's place on the rim, where a cluster grows from.
    public func emergence(_ sector: LayoutWheelSector) -> BTPoint {
        let angle = Self.sectorAngle(sector)
        return BTPoint(x: cos(angle) * rimRadius, y: sin(angle) * rimRadius)
    }

    /// The radius of the circle a cluster's options sit on: neighbours just
    /// `spacing` apart.
    public func clusterRadius(count: Int) -> Double {
        guard count >= 2 else { return 0 }
        return (optionRadius + spacing / 2) / sin(.pi / Double(count))
    }

    public func positions(sector: LayoutWheelSector, count: Int) -> [BTPoint] {
        guard count > 0 else { return [] }
        let axis = Self.sectorAngle(sector)
        if usesCluster(count: count) {
            let ring = clusterRadius(count: count)
            let distance = rimRadius + clearance + optionRadius + ring
            let center = BTPoint(x: cos(axis) * distance, y: sin(axis) * distance)
            // Start beside the wheel, on the counter-clockwise side, and go
            // clockwise, so the first option is the one nearest the group.
            return (0..<count).map { index in
                let angle = axis + .pi + 2 * .pi * (Double(index) + 0.5) / Double(count)
                return BTPoint(x: center.x + cos(angle) * ring, y: center.y + sin(angle) * ring)
            }
        }
        let radius = rimRadius + clearance + optionRadius
        let step = 2 * asin(min(1, (optionRadius + spacing / 2) / radius))
        return (0..<count).map { index in
            let angle = axis + (Double(index) - Double(count - 1) / 2) * step
            return BTPoint(x: cos(angle) * radius, y: sin(angle) * radius)
        }
    }

    /// The farthest any option reaches from the wheel centre, for sizing.
    public func extent(count: Int) -> Double {
        positions(sector: .top, count: count).map { hypot($0.x, $0.y) + optionRadius }.max() ?? rimRadius
    }
}

/// Compatibility name for the standalone prototype harness. Product gestures
/// use `LayoutWheelFanState`; there is no separate prototype selection state.
@_spi(LiquidWheelPrototype)
public typealias LayoutWheelSubmenuState = LayoutWheelFanState
