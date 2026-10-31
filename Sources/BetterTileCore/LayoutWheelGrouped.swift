import Foundation

/// Fixed group names, icons and default commands. User edits live in configuration.
public struct LayoutWheelGroup: Equatable, Sendable {
    public let title: String
    public let symbolName: String
    public let quickAction: LayoutWheelCommand?
    public let options: [LayoutWheelCommand]
    /// What the parent sector draws. Most groups keep their SF Symbol. Mode shows the
    /// icon of the current mode. Choose Layout shows the Layouts icon.
    public var parentIcon: ParentIcon = .symbol

    public enum ParentIcon: Equatable, Sendable {
        case symbol, layouts, currentMode
    }

    /// The layout or mode icon for the parent sector, or nil to draw `symbolName`. Mode has no
    /// icon until the mode of the target desktop is known.
    public func glyph(currentMode: LayoutMode?) -> LayoutGlyph? {
        switch parentIcon {
        case .symbol: nil
        case .layouts: .layouts
        case .currentMode: currentMode.map(LayoutGlyph.mode)
        }
    }

    public static func at(_ sector: LayoutWheelSector) -> Self {
        switch sector {
        case .top:
            Self(title: "Size", symbolName: "arrow.up.left.and.arrow.down.right", quickAction: .windowAction(.maximize),
                 options: [.windowAction(.almostMaximize), .windowAction(.center), .windowAction(.centerResize)])
        case .topRight:
            Self(title: "Thirds", symbolName: "rectangle.split.3x1", quickAction: nil,
                 options: [.leftThird, .centerThird, .rightThird, .leftTwoThirds, .rightTwoThirds].map(LayoutWheelCommand.windowAction))
        case .right:
            Self(title: "Displays", symbolName: "display.2", quickAction: .windowAction(.nextDisplay),
                 options: [.windowAction(.previousDisplay)])
        case .bottomRight:
            Self(title: "Mode", symbolName: "slider.horizontal.3", quickAction: nil,
                 options: [.manual, .bento, .tabbed].map(LayoutWheelCommand.setMode), parentIcon: .currentMode)
        case .bottom:
            Self(title: "Restore", symbolName: "arrow.uturn.backward", quickAction: .windowAction(.restore), options: [])
        case .bottomLeft:
            Self(title: "Choose Layout", symbolName: "rectangle.split.2x2", quickAction: nil,
                 options: TabbedPreset.allCases.map(LayoutWheelCommand.chooseLayout), parentIcon: .layouts)
        case .left:
            Self(title: "Sixths", symbolName: "square.grid.3x2", quickAction: nil,
                 options: [.topLeftSixth, .topCenterSixth, .topRightSixth, .bottomLeftSixth, .bottomCenterSixth, .bottomRightSixth]
                    .map(LayoutWheelCommand.windowAction))
        case .topLeft:
            Self(title: "Move", symbolName: "arrow.up.and.down.and.arrow.left.and.right", quickAction: nil,
                 options: [.moveUp, .moveLeft, .moveRight, .moveDown].map(LayoutWheelCommand.windowAction))
        }
    }
}

/// Stable top-left logical geometry, independent of presentation animation.
public struct LayoutWheelFanGeometry: Sendable {
    public let wheel: LayoutWheelGeometry
    public let innerRadius: Double
    public let outerRadius: Double
    public let configuration: LayoutWheelConfiguration
    public let optionAngle = Double.pi / 6 // 30-degree tiles, separated by transit gaps.

    public init(wheel: LayoutWheelGeometry, innerRadius: Double, outerRadius: Double,
                configuration: LayoutWheelConfiguration = .init(style: .grouped, levelCount: .two)) {
        self.configuration = configuration
        self.wheel = wheel
        self.innerRadius = innerRadius
        self.outerRadius = outerRadius
    }

    public func angle(sector: LayoutWheelSector, option: Int) -> Double {
        // The approved directional fans preserve the command's compass direction.
        // Angles start at the top and increase clockwise in logical coordinates.
        let degrees: [Double]
        switch sector {
        case .topLeft where configuration.groupOverrides[sector.rawValue] == nil: degrees = [0, -90, 90, 180]
        case .topRight where configuration.groupOverrides[sector.rawValue] == nil: degrees = [-90, 0, 90, -135, 135]
        case .left where configuration.groupOverrides[sector.rawValue] == nil: degrees = [-60, 0, 60, -120, 180, 120]
        default:
            let count = configuration.group(at: sector).options.count
            return Double(sector.rawValue) * .pi / 4 + (Double(option) - Double(count - 1) / 2) * .pi / 4
        }
        return degrees[option] * .pi / 180
    }

    public func point(sector: LayoutWheelSector, option: Int, radius: Double? = nil) -> BTPoint {
        let angle = angle(sector: sector, option: option)
        let radius = radius ?? (innerRadius + outerRadius) / 2
        return BTPoint(x: sin(angle) * radius, y: -cos(angle) * radius)
    }

    func option(at vector: BTPoint, sector: LayoutWheelSector, retaining previous: Int?) -> Int? {
        let radius = hypot(vector.x, vector.y)
        // Attach ten points inside the fan; detach five points toward the hub.
        guard radius >= innerRadius + (previous == nil ? 10 : -5), radius <= outerRadius + 5 else { return nil }
        let angle = atan2(vector.x, -vector.y)
        let count = configuration.group(at: sector).options.count
        if let previous, (0..<count).contains(previous),
           Self.angularDistance(angle, self.angle(sector: sector, option: previous)) <= optionAngle / 2 + 5 / radius {
            return previous
        }
        return (0..<count).first { Self.angularDistance(angle, self.angle(sector: sector, option: $0)) <= optionAngle / 2 }
    }

    /// True on a tile, within hysteresis of one, or in a gap of at most 90
    /// degrees between two neighbouring tiles.
    func isCrossingFan(at vector: BTPoint, sector: LayoutWheelSector) -> Bool {
        let radius = hypot(vector.x, vector.y)
        let angle = atan2(vector.x, -vector.y)
        let offsets = configuration.group(at: sector).options.indices.map { option in
            let difference = angle - self.angle(sector: sector, option: option)
            return atan2(sin(difference), cos(difference))
        }
        if offsets.contains(where: { abs($0) <= optionAngle / 2 + 5 / radius }) { return true }
        guard let before = offsets.filter({ $0 >= 0 }).min(),
              let after = offsets.filter({ $0 <= 0 }).max() else { return false }
        return before - after <= .pi / 2 + 1e-9
    }

    static func angularDistance(_ lhs: Double, _ rhs: Double) -> Double {
        abs(atan2(sin(lhs - rhs), cos(lhs - rhs)))
    }
}

/// Semantic state only. Time is supplied by the caller, so tests need no sleeps.
/// There is no display link: the controller schedules only the next rest deadline.
public struct LayoutWheelFanState: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case idle
        case hovering(LayoutWheelSector, deadline: TimeInterval)
        case open(LayoutWheelSector)
    }

    public private(set) var phase: Phase = .idle
    public private(set) var selection: LayoutWheelSelection?
    public private(set) var optionIndex: Int?
    private var configuration = LayoutWheelConfiguration(style: .grouped, levelCount: .two)
    private var restOrigin: BTPoint?
    private var revealOrigin: BTPoint?
    public static let restDuration: TimeInterval = 0.2

    public init() {}

    /// Switching a catalog keeps its parent open without selecting a child at the old pointer.
    public mutating func openCatalog(configuration: LayoutWheelConfiguration) {
        self.configuration = configuration
        phase = .open(.bottomLeft)
        selection = .init(ring: configuration.groupRing, sector: .bottomLeft)
        optionIndex = nil; restOrigin = nil; revealOrigin = nil
    }

    public var openSector: LayoutWheelSector? {
        if case let .open(sector) = phase { return sector }
        return nil
    }

    public var deadline: TimeInterval? {
        if case let .hovering(_, deadline) = phase { return deadline }
        return nil
    }

    public var command: LayoutWheelCommand? {
        if let sector = openSector, let optionIndex {
            let options = configuration.group(at: sector).options
            return options.indices.contains(optionIndex) ? options[optionIndex] : nil
        }
        guard let selection else { return nil }
        return configuration.command(at: selection)
    }

    public mutating func update(vector: BTPoint, at now: TimeInterval, geometry: LayoutWheelFanGeometry,
                                layoutAvailable: Bool = true) {
        configuration = geometry.configuration
        guard vector.x.isFinite, vector.y.isFinite, now.isFinite else { cancel(); return }
        let radius = hypot(vector.x, vector.y)
        guard radius.isFinite, radius > geometry.wheel.hubRadius else { cancel(); return }
        if let sector = openSector, radius > (configuration.levelCount == .one ? geometry.wheel.hubRadius : geometry.wheel.innerRingOuterRadius) + 5 {
            if let origin = revealOrigin {
                // Release can resample the exact point where the fan appeared.
                // Keep the parent until deliberate movement exceeds rest hysteresis.
                guard hypot(vector.x - origin.x, vector.y - origin.y) > 5 else { return }
                revealOrigin = nil
            }
            optionIndex = geometry.option(at: vector, sector: sector, retaining: optionIndex)
            // Keep the parent attached while crossing its fan, including its gaps,
            // but not in the band's empty directions away from every tile.
            if radius >= geometry.innerRadius - 5, radius <= geometry.outerRadius + 5,
               geometry.isCrossingFan(at: vector, sector: sector) {
                selection = LayoutWheelSelection(ring: configuration.groupRing, sector: sector)
                return
            }
            let aimed = geometry.wheel.selection(for: vector, levelCount: configuration.effectiveLevelCount)
            if aimed?.sector == sector { return }
        }
        revealOrigin = nil
        let previous = selection
        var next = geometry.wheel.selection(for: vector, levelCount: configuration.effectiveLevelCount)
        if next == nil, let previous,
           (previous.ring == .inner && radius <= geometry.wheel.innerRingOuterRadius + 5)
            || (previous.ring == .outer && radius >= geometry.wheel.outerRingInnerRadius - 5) {
            next = previous
        }
        if let previous, let candidate = next, previous != candidate {
            next?.sector = stickySector(candidate.sector, previous: previous, vector: vector, radius: radius)
            if previous.ring != candidate.ring {
                let boundary = previous.ring == .inner ? geometry.wheel.innerRingOuterRadius : geometry.wheel.outerRingInnerRadius
                if abs(radius - boundary) < 5 { next?.ring = previous.ring }
            }
        }
        selection = next
        optionIndex = nil
        guard let next, next.ring == configuration.groupRing,
              canOpen(next.sector, layoutAvailable: layoutAvailable) else {
            phase = .idle; restOrigin = nil; return
        }
        rest(on: next.sector, vector: vector, at: now, keepParentAtReveal: true)
    }

    private mutating func rest(on next: LayoutWheelSector, vector: BTPoint, at now: TimeInterval,
                               keepParentAtReveal: Bool) {
        if case let .hovering(sector, deadline) = phase, sector == next,
           let origin = restOrigin, hypot(vector.x - origin.x, vector.y - origin.y) <= 5 {
            if now >= deadline {
                phase = .open(next)
                restOrigin = nil
                revealOrigin = keepParentAtReveal ? vector : nil
            }
        } else {
            phase = .hovering(next, deadline: now + Self.restDuration)
            restOrigin = vector
        }
    }

    private func stickySector(_ candidate: LayoutWheelSector, previous: LayoutWheelSelection?,
                              vector: BTPoint, radius: Double) -> LayoutWheelSector {
        guard let previous else { return candidate }
        let angle = LayoutWheelFanGeometry.angularDistance(atan2(vector.x, -vector.y), Double(previous.sector.rawValue) * .pi / 4)
        return angle <= .pi / 8 + 5 / max(radius, 1) ? previous.sector : candidate
    }

    /// Sector margin before an open liquid sub-menu lets go.
    public static let leaveMargin = 10 * Double.pi / 180

    public mutating func update(vector: BTPoint, at now: TimeInterval, geometry: LayoutWheelGeometry,
                                layout: LayoutWheelSubmenuLayout, layoutAvailable: Bool = true,
                                lockBeyondRim: LayoutWheelSubmenuLockBeyondRim = .keep,
                                configuration: LayoutWheelConfiguration = .init(style: .grouped, levelCount: .two)) {
        self.configuration = configuration
        guard vector.x.isFinite, vector.y.isFinite, now.isFinite else { cancel(); return }
        let radius = hypot(vector.x, vector.y)
        guard radius.isFinite, radius > geometry.hubRadius else { cancel(); return }
        if let sector = openSector, canOpen(sector, layoutAvailable: layoutAvailable),
           selection?.ring == configuration.groupRing,
           holdsOpen(sector, vector: vector, radius: radius, geometry: geometry, layout: layout,
                     lockBeyondRim: lockBeyondRim) {
            aimOption(vector: vector, sector: sector, layout: layout)
            return
        }
        let previousPhase = phase
        phase = .idle
        revealOrigin = nil
        optionIndex = nil
        if lockBeyondRim == .withinGroupAngle, radius > layout.rimRadius + 4 {
            // Do not aim a different group or reopen at an angular boundary
            // outside the wheel. Returning to the ring rearms selection.
            selection = nil
            restOrigin = nil
            return
        }
        let previous = selection
        var next = geometry.selection(for: vector, levelCount: self.configuration.effectiveLevelCount)
        // Keep the current sector near its boundary, like the native wheel.
        if let previous, let candidate = next, candidate.ring == previous.ring {
            next?.sector = stickySector(candidate.sector, previous: previous, vector: vector, radius: radius)
        }
        selection = next
        guard let next, next.ring == self.configuration.groupRing,
              canOpen(next.sector, layoutAvailable: layoutAvailable) else {
            restOrigin = nil
            return
        }
        phase = previousPhase
        rest(on: next.sector, vector: vector, at: now, keepParentAtReveal: false)
        if openSector != nil { aimOption(vector: vector, sector: next.sector, layout: layout) }
    }

    /// An open group stays open unless the pointer reaches the inner ring or
    /// hub, or goes well into another group's sector on the ring itself.
    /// Past the rim the pointer cannot pick another group. The policy can
    /// either keep the lock everywhere or let go past its angular margin.
    private func holdsOpen(_ sector: LayoutWheelSector, vector: BTPoint, radius: Double,
                           geometry: LayoutWheelGeometry, layout: LayoutWheelSubmenuLayout,
                           lockBeyondRim: LayoutWheelSubmenuLockBeyondRim) -> Bool {
        if radius < (configuration.levelCount == .one ? geometry.hubRadius : geometry.outerRingInnerRadius - 4) { return false }
        var halfAngle = Double.pi / 8
        if radius > layout.rimRadius + 4 {
            if lockBeyondRim == .keep { return true }
            // Wide fans can reach past their parent sector. Include each
            // bubble's angular extent so every visible option remains reachable.
            let axis = Double(sector.rawValue) * .pi / 4
            for point in layout.positions(sector: sector, count: configuration.group(at: sector).options.count) {
                let offset = LayoutWheelFanGeometry.angularDistance(atan2(point.x, -point.y), axis)
                let bubble = asin(min(1, layout.optionRadius / max(hypot(point.x, point.y), 1)))
                halfAngle = max(halfAngle, offset + bubble)
            }
        }
        let angle = atan2(vector.x, -vector.y)
        let offset = LayoutWheelFanGeometry.angularDistance(angle, Double(sector.rawValue) * .pi / 4)
        return offset <= halfAngle + Self.leaveMargin
    }

    private mutating func aimOption(vector: BTPoint, sector: LayoutWheelSector, layout: LayoutWheelSubmenuLayout) {
        let positions = layout.positions(sector: sector, count: configuration.group(at: sector).options.count)
        guard !positions.isEmpty else { return }
        func distance(_ index: Int) -> Double { hypot(vector.x - positions[index].x, vector.y - positions[index].y) }
        let reach = layout.optionRadius + layout.spacing / 2 + 8
        let nearest = positions.indices.min { distance($0) < distance($1) }!
        if let current = optionIndex, positions.indices.contains(current) {
            // Stay on the aimed option unless another is clearly nearer.
            if nearest != current, distance(nearest) <= reach, distance(nearest) + 6 < distance(current) {
                optionIndex = nearest
            }
            return
        }
        if distance(nearest) <= reach { optionIndex = nearest }
    }

    /// Up opens a group; Left/Right step its options; Down returns to the rings.
    public mutating func handleKey(_ key: LayoutWheelKey, layoutAvailable: Bool = true,
                                   configuration: LayoutWheelConfiguration? = nil) {
        if let configuration { self.configuration = configuration }

        if key == .escape { cancel(); return }
        restOrigin = nil
        revealOrigin = nil
        if let sector = openSector {
            let count = self.configuration.group(at: sector).options.count
            guard count > 0 else { cancel(); return }
            switch key {
            case .previousSector: optionIndex = ((optionIndex ?? count) - 1 + count) % count
            case .nextSector: optionIndex = ((optionIndex ?? -1) + 1) % count
            case .innerRing, .switchRing: phase = .idle; optionIndex = nil
            default: break
            }
            return
        }
        if key == .outerRing, let selection, selection.ring == self.configuration.groupRing,
           canOpen(selection.sector, layoutAvailable: layoutAvailable) {
            phase = .open(selection.sector)
            optionIndex = nil
            return
        }
        selection = LayoutWheelKeyboard.selection(for: key, from: selection, levelCount: self.configuration.effectiveLevelCount)
        phase = .idle
        optionIndex = nil
    }

    public mutating func release() -> LayoutWheelCommand? {
        let result = command
        cancel()
        return result
    }

    private func canOpen(_ sector: LayoutWheelSector, layoutAvailable: Bool) -> Bool {
        let options = configuration.group(at: sector).options
        return !options.isEmpty && (layoutAvailable || options.contains {
            if case .chooseLayout = $0 { return false }
            return true
        })
    }

    public mutating func cancel() {
        let configuration = configuration
        self = Self()
        self.configuration = configuration
    }
}
