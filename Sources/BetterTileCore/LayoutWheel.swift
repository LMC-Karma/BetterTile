import Foundation

public enum LayoutWheelLevelCount: Int, Codable, CaseIterable, Sendable {
    case one = 1
    case two = 2
}

public enum LayoutWheelRing: Int, Codable, CaseIterable, Sendable {
    case inner
    case outer
}

/// The eight stable wheel directions, starting at the top and proceeding
/// clockwise in BetterTile's top-left coordinate system.
public enum LayoutWheelSector: Int, Codable, CaseIterable, Sendable {
    case top
    case topRight
    case right
    case bottomRight
    case bottom
    case bottomLeft
    case left
    case topLeft
}

public struct LayoutWheelSelection: Equatable, Sendable {
    public var ring: LayoutWheelRing
    public var sector: LayoutWheelSector

    public init(ring: LayoutWheelRing, sector: LayoutWheelSector) {
        self.ring = ring
        self.sector = sector
    }
}

/// Pure hit testing for the Layout Wheel.
///
/// In two-level mode, the open interval between `innerRingOuterRadius` and
/// `outerRingInnerRadius` separates the rings. Both endpoints remain
/// selectable: the inner endpoint belongs to the inner ring and the outer
/// endpoint belongs to the outer ring.
public struct LayoutWheelGeometry: Sendable {
    public var hubRadius: Double
    public var innerRingOuterRadius: Double
    public var outerRingInnerRadius: Double

    public init?(
        hubRadius: Double,
        innerRingOuterRadius: Double,
        outerRingInnerRadius: Double
    ) {
        guard hubRadius.isFinite,
              innerRingOuterRadius.isFinite,
              outerRingInnerRadius.isFinite,
              hubRadius >= 0,
              innerRingOuterRadius > hubRadius,
              outerRingInnerRadius > innerRingOuterRadius
        else { return nil }

        self.hubRadius = hubRadius
        self.innerRingOuterRadius = innerRingOuterRadius
        self.outerRingInnerRadius = outerRingInnerRadius
    }

    /// Returns nil for the cancel hub, the two-level inter-ring dead band, and
    /// non-finite input. Points beyond the drawn wheel remain selectable.
    public func selection(
        for vector: BTPoint,
        levelCount: LayoutWheelLevelCount
    ) -> LayoutWheelSelection? {
        guard vector.x.isFinite, vector.y.isFinite else { return nil }

        let distance = hypot(vector.x, vector.y)
        guard distance.isFinite, distance > hubRadius else { return nil }

        let ring: LayoutWheelRing
        switch levelCount {
        case .one:
            ring = .inner
        case .two:
            if distance <= innerRingOuterRadius {
                ring = .inner
            } else if distance < outerRingInnerRadius {
                return nil
            } else {
                ring = .outer
            }
        }

        // atan2(x, -y) makes Top zero and increases clockwise in BetterTile's
        // top-left coordinate system. Adding half a sector puts boundaries on
        // the diagonals between the eight direction centers.
        let sectorWidth = Double.pi / 4
        let clockwiseAngle = atan2(vector.x, -vector.y)
        let shiftedAngle = clockwiseAngle + sectorWidth / 2
        let normalizedAngle = shiftedAngle - floor(shiftedAngle / (2 * .pi)) * (2 * .pi)
        // Trigonometric reconstruction can put a mathematical boundary a few
        // ulps below itself. A sub-pixel angular bias preserves the documented
        // clockwise ownership without affecting practical pointer positions.
        let boundaryBias = 1e-12
        let sectorIndex = Int(floor((normalizedAngle + boundaryBias) / sectorWidth))
            % LayoutWheelSector.allCases.count
        guard let sector = LayoutWheelSector(rawValue: sectorIndex) else { return nil }
        return LayoutWheelSelection(ring: ring, sector: sector)
    }
}
