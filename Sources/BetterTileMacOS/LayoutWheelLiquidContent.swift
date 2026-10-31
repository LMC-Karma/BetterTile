import BetterTileCore
import Foundation

/// What the liquid Layout Wheel shows, independent of where the pointer is.
///
/// Built once per gesture from the existing configuration and metrics, so
/// the liquid renderer draws the same commands and icons as the native
/// wheel. Selection uses `wheelGeometry` and, for Grouped, `submenuLayout`;
/// the drawing never decides what is selected.
public struct LayoutWheelLiquidContent: Equatable, Sendable {
    public struct Ring: Equatable, Sendable {
        public var ring: LayoutWheelRing
        public var slots: [LayoutWheelSlot]
        /// Sectors with a sub-menu of options, Grouped only.
        public var hasFan: [Bool]
    }

    public let configuration: LayoutWheelConfiguration
    public let levelCount: LayoutWheelLevelCount
    /// Inner ring first.
    public let rings: [Ring]
    public let layout: LayoutWheelLiquidLayout
    public let wheelGeometry: LayoutWheelGeometry
    /// Grouped only: where each group's options sit and how they are hit.
    public let submenuLayout: LayoutWheelSubmenuLayout?
    public let unavailableCommands: Set<LayoutWheelCommand>
    public let layoutAvailable: Bool
    public let currentMode: LayoutMode?
    /// The square drawing size, in points, with room for stretch and shadow.
    public let diameter: Double

    /// Grouped draws at the Custom size plus this much room, at Medium, for
    /// the chevron that marks a group with options.
    public static let chevronRoom = 10.0

    public init(configuration: LayoutWheelConfiguration, levelCount: LayoutWheelLevelCount,
                unavailableCommands: Set<LayoutWheelCommand> = [], layoutAvailable: Bool = true,
                currentMode: LayoutMode? = nil) {
        self.init(configuration: configuration, levelCount: levelCount, submenuStyle: .fan,
                  unavailableCommands: unavailableCommands, layoutAvailable: layoutAvailable, currentMode: currentMode)
    }

    /// The gesture and drawing share this configured sub-menu layout.
    public init(configuration: LayoutWheelConfiguration, levelCount: LayoutWheelLevelCount,
                submenuStyle: LayoutWheelSubmenuStyle,
                unavailableCommands: Set<LayoutWheelCommand> = [], layoutAvailable: Bool = true,
                currentMode: LayoutMode? = nil) {
        var configuration = configuration.normalized()
        configuration.levelCount = levelCount
        self.configuration = configuration
        self.levelCount = levelCount
        self.unavailableCommands = unavailableCommands
        self.layoutAvailable = layoutAvailable
        self.currentMode = currentMode
        // The selected size, never the legacy continuous scale.
        let scale = configuration.appearance.size.scale
        let scene = LayoutWheelSceneInput(configuration: configuration, unavailableCommands: unavailableCommands,
                                          layoutAvailable: layoutAvailable, currentMode: currentMode)
        let grouped = configuration.style == .grouped
        func ring(_ ring: LayoutWheelRing, groups: Bool) -> Ring {
            let sectors = LayoutWheelSector.allCases
            return Ring(ring: ring,
                        slots: sectors.map { scene.slot(.sector(.init(ring: ring, sector: $0))) },
                        hasFan: sectors.map { groups && !configuration.group(at: $0).options.isEmpty })
        }
        let droplet = 20 * scale
        let settings = configuration.appearance.liquid
        let stretch = (settings.feel.stretch + (settings.motion.pointerLean ? settings.motion.leanAmount : 0)) * scale
        let shadow = 14 * scale
        // Every style shares the Custom radii; Grouped only adds the chevron room.
        let metrics = LayoutWheelMetrics.standard.scaled(by: scale)
        let room = grouped ? Self.chevronRoom * scale : 0
        let well = metrics.geometry.hubRadius
        let outer: Double
        switch levelCount {
        case .one:
            outer = metrics.oneLevelInnerRingOuterRadius + room
            rings = [ring(.inner, groups: grouped)]
            layout = .init(outerRadius: outer, wellRadius: well,
                           iconRadii: [(well + metrics.oneLevelInnerRingOuterRadius) / 2],
                           dropletRadius: droplet, scale: scale)
            wheelGeometry = metrics.geometry(for: .one)
        case .two:
            let g = metrics.geometry
            outer = metrics.outerRingOuterRadius + room
            rings = [ring(.inner, groups: false), ring(.outer, groups: grouped)]
            layout = .init(outerRadius: outer, stepRadius: (g.innerRingOuterRadius + g.outerRingInnerRadius) / 2,
                           wellRadius: well,
                           iconRadii: [metrics.iconRadius(for: .inner), metrics.iconRadius(for: .outer)],
                           dropletRadius: droplet, scale: scale)
            wheelGeometry = g
        }
        var extent = outer + stretch + shadow
        if grouped {
            // 10 pt from the rim, just past the droplets' 9 pt detach gap, so
            // options pinch off instead of staying joined by a neck.
            let submenu = LayoutWheelSubmenuLayout(rimRadius: outer, optionRadius: droplet, spacing: 6 * scale,
                                                   clearance: 10 * scale, style: submenuStyle)
            submenuLayout = submenu
            let largest = LayoutWheelSector.allCases.map { configuration.group(at: $0).options.count }.max() ?? 0
            let counts = Set(LayoutWheelSector.allCases.map { configuration.group(at: $0).options.count })
            extent = max(extent, (counts.map { submenu.extent(count: $0) }.max() ?? submenu.extent(count: largest)) + shadow)
        } else {
            submenuLayout = nil
        }
        diameter = 2 * extent
    }

    /// Geometry derives from the other values, which also lack equality.
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.configuration == rhs.configuration && lhs.levelCount == rhs.levelCount
            && lhs.submenuLayout == rhs.submenuLayout
            && lhs.unavailableCommands == rhs.unavailableCommands && lhs.layoutAvailable == rhs.layoutAvailable
            && lhs.currentMode == rhs.currentMode
    }

    /// True when `other` draws the same wheel and differs at most in the
    /// captured target's mode and availability.
    public func drawsSameWheel(as other: Self) -> Bool {
        configuration == other.configuration && levelCount == other.levelCount
            && submenuLayout == other.submenuLayout
    }

    /// The icon symbol size for a model ring; Two Levels draws its inner ring smaller.
    public func iconSymbolSize(ringIndex: Int) -> Double {
        (rings.count == 2 && ringIndex == 0 ? 16 : 18) * layout.scale
    }

    /// The model's ring index for a selection, or nil when this content has no such ring.
    public func ringIndex(_ ring: LayoutWheelRing) -> Int? {
        rings.firstIndex { $0.ring == ring }
    }

    public func slot(_ selection: LayoutWheelSelection) -> LayoutWheelSlot? {
        ringIndex(selection.ring).map { rings[$0].slots[selection.sector.rawValue] }
    }

    public func fanOptions(_ sector: LayoutWheelSector) -> [LayoutWheelSlot] {
        guard submenuLayout != nil else { return [] }
        let scene = LayoutWheelSceneInput(configuration: configuration, unavailableCommands: unavailableCommands,
                                          layoutAvailable: layoutAvailable, currentMode: currentMode)
        return configuration.group(at: sector).options.indices.map { scene.slot(.option(sector, $0)) }
    }

    /// The command a release would run, decided only by Core selection state.
    public func command(_ state: LayoutWheelLiquidState) -> LayoutWheelCommand? {
        if let sector = state.openSector, let option = state.aimedOption {
            let options = configuration.group(at: sector).options
            return options.indices.contains(option) ? options[option] : nil
        }
        return state.selection.flatMap { configuration.command(at: $0) }
    }

    /// The command whose kind gives the highlight its colour (Action tint). It is what a
    /// release would run. A Grouped group without a quick flick has no command of its own,
    /// so it takes the kind of its first child.
    public func tintCommand(_ state: LayoutWheelLiquidState) -> LayoutWheelCommand? {
        if let command = command(state) { return command }
        // The owner of an open submenu counts as selected, as in the highlight itself.
        let parent = state.selection ?? state.openSector.map { LayoutWheelSelection(ring: configuration.groupRing, sector: $0) }
        guard configuration.style == .grouped, state.aimedOption == nil, let parent,
              parent.ring == configuration.groupRing else { return nil }
        return configuration.group(at: parent.sector).options.lazy.compactMap { $0 }.first
    }

    /// The name shown for the moment: parent first, then its main action; a child alone.
    public func centreName(_ state: LayoutWheelLiquidState) -> (name: String, detail: String?, available: Bool)? {
        if let sector = state.openSector, let option = state.aimedOption {
            let options = fanOptions(sector)
            guard options.indices.contains(option) else { return nil }
            let slot = options[option]
            return (slot.label, nil, slot.isAvailable)
        }
        guard let selection = state.selection, let slot = slot(selection) else { return nil }
        if configuration.style == .grouped, selection.ring == configuration.groupRing {
            let group = LayoutWheelGroup.at(selection.sector)
            return (group.title, configuration.group(at: selection.sector).quickAction.map { LayoutWheelSlot(command: $0).label }, slot.isAvailable)
        }
        return (slot.label, nil, slot.isAvailable)
    }

    /// Model input for one moment of the gesture.
    public func liquidInput(_ state: LayoutWheelLiquidState) -> LayoutWheelLiquidInput {
        var input = LayoutWheelLiquidInput(pointer: state.pointer)
        if let selection = state.selection, let ring = ringIndex(selection.ring) {
            input.focus = .init(ring: ring, slot: selection.sector.rawValue)
        }
        // The icon that owns an open submenu stays highlighted, whatever the pointer selects.
        if let sector = state.openSector, let ring = ringIndex(configuration.groupRing) {
            input.focus = .init(ring: ring, slot: sector.rawValue)
        }
        if let sector = state.openSector, let submenuLayout {
            let count = configuration.group(at: sector).options.count
            input.fan = .init(parentSlot: sector.rawValue,
                              options: submenuLayout.positions(sector: sector, count: count),
                              aimedOption: state.aimedOption,
                              emergence: submenuLayout.usesCluster(count: count) ? submenuLayout.emergence(sector) : nil)
        }
        return input
    }
}
