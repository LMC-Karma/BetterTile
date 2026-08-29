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

public struct LayoutWheelSelection: Hashable, Sendable {
    public var ring: LayoutWheelRing
    public var sector: LayoutWheelSector

    public init(ring: LayoutWheelRing, sector: LayoutWheelSector) {
        self.ring = ring
        self.sector = sector
    }
}

public enum LayoutWheelCommand: Codable, Hashable, Sendable {
    case windowAction(WindowAction)
    case customZone(UUID)
    case repairBento
}

public struct LayoutWheelConfiguration: Codable, Hashable, Sendable {
    public static let slotCount = LayoutWheelSector.allCases.count
    public static let supportedKeyboardModifiers: ShortcutModifiers = [
        .control, .option, .shift, .command,
    ]

    public var isEnabled: Bool
    public var levelCount: LayoutWheelLevelCount
    /// A nil slot is the user-facing Empty assignment.
    public var innerSlots: [LayoutWheelCommand?]
    /// Retained while One Level hides the outer ring.
    public var outerSlots: [LayoutWheelCommand?]
    public var keyboardTriggerEnabled: Bool
    public var keyboardModifiers: ShortcutModifiers
    public var middleClickTriggerEnabled: Bool

    public init(
        isEnabled: Bool = true,
        levelCount: LayoutWheelLevelCount = .two,
        innerSlots: [LayoutWheelCommand?] = Self.defaultInnerSlots,
        outerSlots: [LayoutWheelCommand?] = Self.defaultOuterSlots,
        keyboardTriggerEnabled: Bool = true,
        keyboardModifiers: ShortcutModifiers = [.control, .option],
        middleClickTriggerEnabled: Bool = false
    ) {
        self.isEnabled = isEnabled
        self.levelCount = levelCount
        self.innerSlots = innerSlots
        self.outerSlots = outerSlots
        self.keyboardTriggerEnabled = keyboardTriggerEnabled
        self.keyboardModifiers = keyboardModifiers
        self.middleClickTriggerEnabled = middleClickTriggerEnabled
    }

    public static let defaultInnerSlots: [LayoutWheelCommand?] = [
        .windowAction(.topHalf),
        .windowAction(.topRightQuarter),
        .windowAction(.rightHalf),
        .windowAction(.bottomRightQuarter),
        .windowAction(.bottomHalf),
        .windowAction(.bottomLeftQuarter),
        .windowAction(.leftHalf),
        .windowAction(.topLeftQuarter),
    ]

    public static let defaultOuterSlots: [LayoutWheelCommand?] = [
        .windowAction(.maximize),
        .windowAction(.almostMaximize),
        .windowAction(.nextDisplay),
        .windowAction(.centerResize),
        .windowAction(.restore),
        .windowAction(.center),
        .windowAction(.previousDisplay),
        .repairBento,
    ]

    /// Produces safe runtime state from decoded or hand-edited configuration.
    public func normalized(customZoneIDs: Set<UUID>) -> LayoutWheelConfiguration {
        var result = self
        if result.innerSlots.count != Self.slotCount {
            result.innerSlots = Self.defaultInnerSlots
        }
        if result.outerSlots.count != Self.slotCount {
            result.outerSlots = Self.defaultOuterSlots
        }

        let supportedModifiers = result.keyboardModifiers
            .intersection(Self.supportedKeyboardModifiers)
        result.keyboardModifiers = supportedModifiers.rawValue.nonzeroBitCount >= 2
            ? supportedModifiers
            : [.control, .option]

        result.innerSlots = result.innerSlots.removingMissingZones(from: customZoneIDs)
        result.outerSlots = result.outerSlots.removingMissingZones(from: customZoneIDs)
        return result
    }
}

private extension Array where Element == LayoutWheelCommand? {
    func removingMissingZones(from customZoneIDs: Set<UUID>) -> Self {
        map { command in
            guard case let .customZone(id) = command,
                  !customZoneIDs.contains(id)
            else { return command }
            return nil
        }
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
