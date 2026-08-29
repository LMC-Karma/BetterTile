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

public extension LayoutWheelConfiguration {
    /// The command a sector carries, or nil for Empty. Reading through one
    /// accessor keeps the renderer, the runtime gesture, and Settings agreeing
    /// about a slot list that hand-edited configuration could leave short.
    func command(at selection: LayoutWheelSelection) -> LayoutWheelCommand? {
        let slots = selection.ring == .inner ? innerSlots : outerSlots
        guard slots.indices.contains(selection.sector.rawValue) else { return nil }
        return slots[selection.sector.rawValue]
    }

    var activeRings: [LayoutWheelRing] {
        levelCount == .one ? [.inner] : [.inner, .outer]
    }
}

/// Where the wheel is drawn, and where pointer directions are measured from.
public struct LayoutWheelPlacement: Equatable, Sendable {
    /// The pointer position when the wheel opened. Selection is always measured
    /// from here.
    public var anchor: BTPoint
    /// The drawn centre, which clamping can move away from the anchor.
    public var center: BTPoint
    public var diameter: Double

    public init(anchor: BTPoint, center: BTPoint, diameter: Double) {
        self.anchor = anchor
        self.center = center
        self.diameter = diameter
    }

    public var frame: BTRect {
        BTRect(
            x: center.x - diameter / 2,
            y: center.y - diameter / 2,
            width: diameter,
            height: diameter
        )
    }

    /// Opens the wheel under the pointer, then slides the drawing back onto the
    /// display if it would hang off an edge.
    ///
    /// Clamping moves only `center`. `anchor` stays where the pointer was, so a
    /// wheel opened near a corner still reads "right" as the right sector
    /// instead of rotating every direction toward the display middle.
    public static func clamped(
        anchor: BTPoint,
        diameter: Double,
        visibleFrame: BTRect
    ) -> LayoutWheelPlacement {
        let radius = diameter / 2
        let center: BTPoint
        if visibleFrame.size.width < diameter || visibleFrame.size.height < diameter {
            // Too small to hold the wheel; centring keeps as much on screen as
            // possible instead of pinning it to one edge.
            center = visibleFrame.center
        } else {
            center = BTPoint(
                x: min(max(anchor.x, visibleFrame.minX + radius), visibleFrame.maxX - radius),
                y: min(max(anchor.y, visibleFrame.minY + radius), visibleFrame.maxY - radius)
            )
        }
        return LayoutWheelPlacement(anchor: anchor, center: center, diameter: diameter)
    }
}

public enum LayoutWheelKey: Equatable, Sendable {
    case escape
    case commit
    case switchRing
    case previousSector
    case nextSector
    case outerRing
    case innerRing
}

public enum LayoutWheelKeyboard {
    /// Where a key moves the selection, or nil to leave it on the cancel hub.
    ///
    /// Left and right step around the current ring, up and down move between
    /// rings, and Tab switches rings. With nothing selected any of them enters
    /// the wheel at the top of the inner ring, so a keyboard user never has to
    /// find a sector with the pointer first.
    public static func selection(
        for key: LayoutWheelKey,
        from current: LayoutWheelSelection?,
        levelCount: LayoutWheelLevelCount
    ) -> LayoutWheelSelection? {
        guard let current else {
            switch key {
            case .escape, .commit: return nil
            default: return LayoutWheelSelection(ring: .inner, sector: .top)
            }
        }

        let sectorCount = LayoutWheelSector.allCases.count
        switch key {
        case .escape, .commit:
            return current
        case .previousSector, .nextSector:
            let step = key == .nextSector ? 1 : -1
            let index = (current.sector.rawValue + step + sectorCount) % sectorCount
            guard let sector = LayoutWheelSector(rawValue: index) else { return current }
            return LayoutWheelSelection(ring: current.ring, sector: sector)
        case .switchRing:
            guard levelCount == .two else { return current }
            return LayoutWheelSelection(
                ring: current.ring == .inner ? .outer : .inner,
                sector: current.sector
            )
        case .outerRing:
            guard levelCount == .two else { return current }
            return LayoutWheelSelection(ring: .outer, sector: current.sector)
        case .innerRing:
            return LayoutWheelSelection(ring: .inner, sector: current.sector)
        }
    }
}
