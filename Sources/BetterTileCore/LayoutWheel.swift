import Foundation

public enum LayoutWheelStyle: String, Codable, CaseIterable, Sendable {
    case custom, grouped
}

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
    /// Decoded only for compatibility with older Layout Wheel configurations.
    case customZone(UUID)
    case repairBento
    case setMode(LayoutMode)
    case chooseLayout(TabbedPreset)
}

public struct LayoutWheelConfiguration: Codable, Hashable, Sendable {
    public static let slotCount = LayoutWheelSector.allCases.count
    public static let minimumScale = 0.8
    public static let maximumScale = 1.3
    public static let defaultScale = 1.0
    public static let supportedKeyboardModifiers: ShortcutModifiers = [
        .control, .option, .shift, .command,
    ]

    public var style: LayoutWheelStyle
    public var isEnabled: Bool
    public var levelCount: LayoutWheelLevelCount
    /// A nil slot is the user-facing Empty assignment.
    public var innerSlots: [LayoutWheelCommand?]
    /// Retained while One Level hides the outer ring.
    public var outerSlots: [LayoutWheelCommand?]
    public var groupOverrides: [Int: LayoutWheelGroupContents]
    public var groupedInnerSlots: [LayoutWheelCommand?]
    public var triggers: LayoutWheelTriggers

    // Compatibility projections never broaden a new trigger in an older build.
    public var keyboardTriggerEnabled: Bool {
        get { triggers.keyboardEnabled && triggers.keyboard == .modifiers }
        set { triggers.keyboardEnabled = newValue }
    }
    public var keyboardModifiers: ShortcutModifiers {
        get { triggers.normalized().modifiers }
        set { triggers.modifiers = newValue }
    }
    public var middleClickTriggerEnabled: Bool {
        get { triggers.mouse == .middleClick }
        set { triggers.mouse = newValue ? .middleClick : .off }
    }
    public var appearance: LayoutWheelAppearance

    /// Kept only for the current renderer and its Settings preview.
    /// New UI writes `appearance.size`, never scale. Remove this property and
    /// continuous-scale normalization when the new renderer uses `size.scale`.
    public var scale: Double {
        get { appearance.compatibilityScale }
        set { appearance.compatibilityScale = newValue }
    }

    /// An explicit appearance owns size; supplying it ignores `scale`.
    public init(
        style: LayoutWheelStyle = .custom,
        isEnabled: Bool = true,
        levelCount: LayoutWheelLevelCount = .one,
        innerSlots: [LayoutWheelCommand?] = Self.defaultInnerSlots,
        outerSlots: [LayoutWheelCommand?] = Self.defaultOuterSlots,
        keyboardTriggerEnabled: Bool = true,
        keyboardModifiers: ShortcutModifiers = [.control, .option, .shift],
        middleClickTriggerEnabled: Bool = false,
        scale: Double = Self.defaultScale,
        appearance: LayoutWheelAppearance? = nil,
        groupOverrides: [Int: LayoutWheelGroupContents] = [:],
        groupedInnerSlots: [LayoutWheelCommand?] = Self.defaultInnerSlots,
        triggers: LayoutWheelTriggers? = nil
    ) {
        self.style = style
        self.isEnabled = isEnabled
        self.levelCount = levelCount
        self.innerSlots = innerSlots
        self.outerSlots = outerSlots
        self.groupOverrides = groupOverrides
        self.groupedInnerSlots = groupedInnerSlots
        self.triggers = triggers ?? .init(keyboardEnabled: keyboardTriggerEnabled,
            modifiers: keyboardModifiers, mouse: middleClickTriggerEnabled ? .middleClick : .off)
        self.appearance = appearance ?? .init()
        if appearance == nil { self.scale = scale }
    }

    private enum CodingKeys: String, CodingKey {
        case style, appearance, groupOverrides, groupedInnerSlots, triggers
        case isEnabled, levelCount, innerSlots, outerSlots
        case keyboardTriggerEnabled, keyboardModifiers, middleClickTriggerEnabled, scale
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let legacyScale = try container.decodeIfPresent(Double.self, forKey: .scale) ?? Self.defaultScale
        let style = try container.decodeIfPresent(LayoutWheelStyle.self, forKey: .style) ?? .custom
        let legacyGrouped = style == .grouped && !container.contains(.groupedInnerSlots)
            && !container.contains(.groupOverrides) && !container.contains(.triggers)
        let storedLevels = try container.decodeIfPresent(LayoutWheelLevelCount.self, forKey: .levelCount) ?? .one
        var groupedInnerSlots = Self.defaultInnerSlots
        if container.contains(.groupedInnerSlots), try !container.decodeNil(forKey: .groupedInnerSlots) {
            var slots = try container.nestedUnkeyedContainer(forKey: .groupedInnerSlots)
            groupedInnerSlots = []
            while !slots.isAtEnd {
                // Keep each position; a command from a newer build becomes Empty.
                let slot = try slots.superDecoder()
                groupedInnerSlots.append(try? LayoutWheelCommand(from: slot))
            }
        }
        self.init(
            style: style,
            isEnabled: try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true,
            levelCount: legacyGrouped ? .two : storedLevels,
            innerSlots: try container.decodeIfPresent([LayoutWheelCommand?].self, forKey: .innerSlots)
                ?? Self.defaultInnerSlots,
            outerSlots: try container.decodeIfPresent([LayoutWheelCommand?].self, forKey: .outerSlots)
                ?? Self.defaultOuterSlots,
            keyboardTriggerEnabled: try container.decodeIfPresent(
                Bool.self,
                forKey: .keyboardTriggerEnabled
            ) ?? true,
            keyboardModifiers: try container.decodeIfPresent(
                ShortcutModifiers.self,
                forKey: .keyboardModifiers
            ) ?? [.control, .option, .shift],
            middleClickTriggerEnabled: try container.decodeIfPresent(
                Bool.self,
                forKey: .middleClickTriggerEnabled
            ) ?? false,
            scale: legacyScale,
            groupOverrides: try container.decodeIfPresent([Int: LayoutWheelGroupContents].self, forKey: .groupOverrides) ?? [:],
            groupedInnerSlots: groupedInnerSlots,
            triggers: try container.decodeIfPresent(LayoutWheelTriggers.self, forKey: .triggers)
        )
        if container.contains(.appearance), try !container.decodeNil(forKey: .appearance) {
            appearance = try LayoutWheelAppearance(
                from: container.superDecoder(forKey: .appearance), legacyScale: legacyScale
            )
        }
    }

    // Custom remains implicit for compatibility with pre-style configurations.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if style != .custom { try container.encode(style, forKey: .style) }
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encode(levelCount, forKey: .levelCount)
        try container.encode(innerSlots, forKey: .innerSlots)
        try container.encode(outerSlots, forKey: .outerSlots)
        try container.encode(keyboardTriggerEnabled, forKey: .keyboardTriggerEnabled)
        try container.encode(keyboardModifiers, forKey: .keyboardModifiers)
        try container.encode(middleClickTriggerEnabled, forKey: .middleClickTriggerEnabled)
        try container.encode(scale, forKey: .scale)
        try container.encode(appearance, forKey: .appearance)
        try container.encode(groupOverrides, forKey: .groupOverrides)
        try container.encode(groupedInnerSlots, forKey: .groupedInnerSlots)
        try container.encode(triggers.normalized(), forKey: .triggers)
    }

    public var effectiveLevelCount: LayoutWheelLevelCount { levelCount }

    public var groupRing: LayoutWheelRing { levelCount == .one ? .inner : .outer }

    public func group(at sector: LayoutWheelSector) -> LayoutWheelGroupContents {
        (groupOverrides[sector.rawValue] ?? .defaults(at: sector)).normalized()
    }

    public mutating func setGroup(_ contents: LayoutWheelGroupContents, at sector: LayoutWheelSector) {
        groupOverrides[sector.rawValue] = contents.normalized()
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
    /// Normalizes persisted assignments. Legacy Custom Zone commands are kept
    /// decodable, but the feature is no longer available and therefore cannot
    /// remain assigned to a sector.
    public func normalized() -> LayoutWheelConfiguration {
        var result = self
        if result.innerSlots.count != Self.slotCount {
            result.innerSlots = Self.defaultInnerSlots
        }
        if result.outerSlots.count != Self.slotCount {
            result.outerSlots = Self.defaultOuterSlots
        }

        result.triggers = result.triggers.normalized()
        if result.groupedInnerSlots.count != Self.slotCount {
            result.groupedInnerSlots = Self.defaultInnerSlots
        }
        result.groupedInnerSlots = result.groupedInnerSlots.removingCustomZoneAssignments()
        result.groupOverrides = result.groupOverrides.filter { LayoutWheelSector(rawValue: $0.key) != nil }
            .mapValues { $0.normalized() }

        result.scale = result.scale.isFinite
            ? min(max(result.scale, Self.minimumScale), Self.maximumScale)
            : Self.defaultScale

        // Custom Zones were never a complete Layout Wheel surface. Keep the
        // old enum case readable, but remove those assignments from runtime
        // configuration instead of exposing a dead picker.
        result.innerSlots = result.innerSlots.removingCustomZoneAssignments()
        result.outerSlots = result.outerSlots.removingCustomZoneAssignments()
        return result
    }
}

private extension Array where Element == LayoutWheelCommand? {
    func removingCustomZoneAssignments() -> Self {
        map { command in
            switch command {
            case .customZone: return nil
            default: break
            }
            return command
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
    /// Exchanges the assignments without changing either ring's visibility.
    mutating func swapRings() {
        swap(&innerSlots, &outerSlots)
    }

    /// The command a sector carries, or nil for Empty. Reading through one
    /// accessor keeps the renderer, the runtime gesture, and Settings agreeing
    /// about a slot list that hand-edited configuration could leave short.
    func command(at selection: LayoutWheelSelection) -> LayoutWheelCommand? {
        if style == .grouped {
            if selection.ring == groupRing { return group(at: selection.sector).quickAction }
            return groupedInnerSlots.indices.contains(selection.sector.rawValue)
                ? groupedInnerSlots[selection.sector.rawValue] : nil
        }
        let slots = selection.ring == .inner ? innerSlots : outerSlots
        guard slots.indices.contains(selection.sector.rawValue) else { return nil }
        return slots[selection.sector.rawValue]
    }

    var activeRings: [LayoutWheelRing] {
        effectiveLevelCount == .one ? [.inner] : [.inner, .outer]
    }
}

/// Where the wheel is drawn, and where pointer directions are measured from.
public struct LayoutWheelPlacement: Equatable, Sendable {
    /// The pointer position when the wheel opened, used to reject opening jitter.
    public var anchor: BTPoint
    /// The drawn centre, which clamping can move away from the anchor.
    public var center: BTPoint
    public var diameter: Double
    public var contentHeight: Double

    public init(
        anchor: BTPoint,
        center: BTPoint,
        diameter: Double,
        contentHeight: Double? = nil
    ) {
        self.anchor = anchor
        self.center = center
        self.diameter = diameter
        self.contentHeight = max(diameter, contentHeight ?? diameter)
    }

    public var frame: BTRect {
        BTRect(
            x: center.x - diameter / 2,
            y: center.y - diameter / 2,
            width: diameter,
            height: contentHeight
        )
    }

    /// Opens the wheel under the pointer, then slides the drawing back onto the
    /// display if it would hang off an edge.
    ///
    /// Selection uses the drawn `center`. `anchor` records the opening position.
    /// Transparent shadow padding may extend past the edge; visible controls stay inside.
    public static func clamped(
        anchor: BTPoint,
        diameter: Double,
        contentHeight: Double? = nil,
        overflowPadding: Double = 0,
        visibleFrame: BTRect
    ) -> LayoutWheelPlacement {
        let radius = diameter / 2
        let contentHeight = max(diameter, contentHeight ?? diameter)
        let padding = min(max(0, overflowPadding), radius)
        let center = BTPoint(
            x: clampedAxis(
                anchor.x,
                minimum: visibleFrame.minX,
                maximum: visibleFrame.maxX,
                before: radius - padding,
                after: radius - padding
            ),
            y: clampedAxis(
                anchor.y,
                minimum: visibleFrame.minY,
                maximum: visibleFrame.maxY,
                before: radius - padding,
                after: contentHeight - radius - padding
            )
        )
        return LayoutWheelPlacement(
            anchor: anchor,
            center: center,
            diameter: diameter,
            contentHeight: contentHeight
        )
    }

    private static func clampedAxis(
        _ value: Double,
        minimum: Double,
        maximum: Double,
        before: Double,
        after: Double
    ) -> Double {
        guard maximum - minimum >= before + after else {
            return (minimum + maximum + before - after) / 2
        }
        return min(max(value, minimum + before), maximum - after)
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
