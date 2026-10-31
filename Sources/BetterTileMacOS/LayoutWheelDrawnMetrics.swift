import BetterTileCore
import Foundation

/// Presentation values only. Core receives the unchanged metrics geometry,
/// never these offsets, frames, separator segments or lens sizes.
struct LayoutWheelDrawnMetrics {
    let metrics: LayoutWheelMetrics
    let levelCount: LayoutWheelLevelCount
    let scale: Double

    init(_ input: LayoutWheelSceneInput) {
        metrics = input.metrics
        levelCount = input.configuration.effectiveLevelCount
        let base = input.configuration.style == .grouped ? LayoutWheelMetrics.grouped : input.customMetrics
        scale = metrics.geometry.hubRadius / base.geometry.hubRadius
    }

    var wellRadius: Double { metrics.geometry.hubRadius }
    var outerRadius: Double { metrics.diameter(for: levelCount) / 2 }
    var stepRadius: Double? {
        levelCount == .two ? (metrics.geometry.innerRingOuterRadius + metrics.geometry.outerRingInnerRadius) / 2 : nil
    }
    var separatorInset: Double { 4 * scale }
    var separatorFade: Double { 5 * scale }
    let separatorWidth = 1.0
    let edgeWidth = 1.2
    let lensOutlineWidth = 1.0
    var chevronSize: Double { 8 * scale }

    struct Separator {
        let angle: Double
        let startRadius: Double
        let endRadius: Double
        var start: BTPoint { .init(x: cos(angle) * startRadius, y: sin(angle) * startRadius) }
        var end: BTPoint { .init(x: cos(angle) * endRadius, y: sin(angle) * endRadius) }
    }
    var separators: [Separator] {
        LayoutWheelSector.allCases.flatMap { sector in
            let angle = sector.drawnCenterAngle.radians + .pi / 8
            // End at the near side of the dead band. This also keeps the full
            // segment inside its hit band rather than extending across a boundary.
            if levelCount == .two {
                return [Separator(angle: angle, startRadius: wellRadius + separatorInset,
                                  endRadius: metrics.geometry.innerRingOuterRadius - separatorInset),
                        Separator(angle: angle, startRadius: metrics.geometry.outerRingInnerRadius + separatorInset,
                                  endRadius: outerRadius - separatorInset)]
            }
            return [Separator(angle: angle, startRadius: wellRadius + separatorInset,
                              endRadius: outerRadius - separatorInset)]
        }
    }

    func symbolSize(_ ring: LayoutWheelRing) -> Double {
        (levelCount == .two && ring == .inner ? 16 : 18) * scale
    }
    func iconFrameSize(_ ring: LayoutWheelRing) -> Double { 35 / 18 * symbolSize(ring) }
    func lensRadius(_ ring: LayoutWheelRing) -> Double {
        let depth = metrics.outerRadius(for: ring, levelCount: levelCount) - metrics.innerRadius(for: ring)
        return min((ring == .inner && levelCount == .two ? 17.6 : 19.5) * scale, depth / 2 - scale)
    }
    func lensRadius(_ selection: LayoutWheelSelection, lean: BTPoint) -> Double {
        // Fading lenses retain their own sector while the body leans toward
        // the new selection. Keep their outline outside the fixed well too.
        let center = iconPoint(selection, lean: lean)
        let clearance = hypot(center.x, center.y) - wellRadius - scale
        return max(0, min(lensRadius(selection.ring), clearance))
    }
    func iconPoint(_ selection: LayoutWheelSelection, symbol: String = "", hover: Double = 0,
                   lean: BTPoint = .init(x: 0, y: 0)) -> BTPoint {
        let angle = selection.sector.drawnCenterAngle.radians
        let radius = metrics.iconRadius(for: selection.ring, levelCount: levelCount)
        let shift = Self.opticalShift(symbol, symbolSize: symbolSize(selection.ring) * (1 + 0.08 * hover))
        return .init(x: cos(angle) * radius + shift.x + lean.x,
                     y: sin(angle) * radius + shift.y + lean.y)
    }
    func chevronPoint(_ sector: LayoutWheelSector) -> BTPoint {
        point(radius: outerRadius - 10 * scale, angle: sector.drawnCenterAngle.radians)
    }
    /// The cosmetic lean amount at Medium. All sizes and states share it.
    static let leanDistance = 4.0

    func lean(angle: Double, strength: Double, reduceMotion: Bool) -> BTPoint {
        let radius = reduceMotion ? 0 : Self.leanDistance * scale * min(1, max(0, strength))
        return point(radius: radius, angle: angle)
    }
    func bulge(fanOpen: Bool, inner: Bool, strength: Double, reduceMotion: Bool) -> Double {
        reduceMotion ? 0 : (inner ? 5 : (fanOpen ? 10 : 8)) * scale * min(1, max(0, strength))
    }
    func point(radius: Double, angle: Double) -> BTPoint {
        .init(x: cos(angle) * radius, y: sin(angle) * radius)
    }
    /// Shift away from the arrowhead; other symbols are frame centred.
    static func opticalShift(_ symbol: String, symbolSize: Double) -> BTPoint {
        let amount = 0.6 * symbolSize / 18
        switch symbol {
        case "arrow.left": return .init(x: amount, y: 0)
        case "arrow.right": return .init(x: -amount, y: 0)
        case "arrow.up": return .init(x: 0, y: amount)
        case "arrow.down": return .init(x: 0, y: -amount)
        default: return .init(x: 0, y: 0)
        }
    }
}

struct LayoutWheelGlassTreatment: Equatable {
    let useGlass: Bool
    let increasedContrast: Bool
    static let strength = 0.30
    /// Window-background plate over native glass, as the glass popups use.
    /// The floor is the alpha at strength 0; strength adds 0.20 x strength.
    /// The ring floor is capped at 0.20. The centre well uses a darker plate
    /// (0.47) so Cancel and the hovered names stay readable over bright windows.
    ///
    /// Both floors rise with strength (+0.20 x strength): at 100 percent the
    /// well plate is 0.67. A strength control needs its own check.
    static let plateCap = 0.20
    static let plateFloor = 0.20
    static let wellPlateFloor = 0.47
    static func plateOpacity(strength: Double, floor: Double = plateFloor) -> Double {
        floor + 0.20 * (strength.isFinite ? min(1, max(0, strength)) : 0)
    }
    static func wellPlateOpacity(strength: Double, floor: Double = wellPlateFloor) -> Double {
        plateOpacity(strength: strength, floor: floor)
    }

    init(useLiquidGlass: Bool, reduceTransparency: Bool, increasedContrast: Bool) {
        useGlass = useLiquidGlass && !reduceTransparency && !increasedContrast
        self.increasedContrast = increasedContrast
    }
    func separatorOpacity(dark: Bool, fanOpen: Bool) -> Double {
        let opacity = useGlass ? (dark ? 0.12 : 0.10) : (dark ? 0.16 : 0.14)
        return opacity * (increasedContrast ? 2 : 1) * (fanOpen ? 0.5 : 1)
    }
}
