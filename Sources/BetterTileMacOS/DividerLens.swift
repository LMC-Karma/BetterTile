import AppKit
import BetterTileCore
import CoreImage

/// Coordinates stay in the non-flipped handle view. Room uses screen directions.
struct DividerLensGeometry {
    let bounds: CGRect
    let capsules: [CGRect]
    let capsuleAxes: [SplitAxis]
    let outline: CGPath
    let trackRects: [CGRect]

    init(
        bounds: CGRect, mode: DividerHandleMode, thickness: Double, progress: Double,
        trackRoom: [DividerHandleArm: Double] = [:],
        useLiquidGlass: Bool = true, cached: DividerLensGeometry? = nil
    ) {
        func interpolate(_ a: Double, _ b: Double) -> CGFloat { a + (b - a) * progress }
        let width = DividerHandleGeometry.renderedThickness(thickness, useLiquidGlass: useLiquidGlass)
        let center: CGPoint
        let rects: [CGRect]
        switch mode {
        case let .vertical(resting, active):
            capsuleAxes = [.vertical]
            center = CGPoint(x: bounds.midX, y: bounds.midY)
            let length = max(0, interpolate(resting, active) - (useLiquidGlass ? 2 : 0))
            rects = [CGRect(x: center.x - width / 2, y: center.y - length / 2, width: width, height: length)]
        case let .horizontal(resting, active):
            capsuleAxes = [.horizontal]
            center = CGPoint(x: bounds.midX, y: bounds.midY)
            let length = max(0, interpolate(resting, active) - (useLiquidGlass ? 2 : 0))
            rects = [CGRect(x: center.x - length / 2, y: center.y - width / 2, width: length, height: width)]
        case let .junction(junction, resting, active):
            capsuleAxes = [.horizontal, .vertical]
            center = junction
            let left = interpolate(resting[.left] ?? 0, active[.left] ?? 0)
            let right = interpolate(resting[.right] ?? 0, active[.right] ?? 0)
            let up = interpolate(resting[.up] ?? 0, active[.up] ?? 0)
            let down = interpolate(resting[.down] ?? 0, active[.down] ?? 0)
            rects = [
                CGRect(x: center.x - left - width / 2, y: center.y - width / 2,
                       width: left + right + width, height: width),
                CGRect(x: center.x - width / 2, y: center.y - down - width / 2,
                       width: width, height: up + down + width),
            ]
        }
        let reach = interpolate(16, 70)
        let trackWidth = max(1.5, 0.21 * width)
        let tracks = zip(rects, capsuleAxes).map { rect, axis in
            if axis == .vertical {
                let start = max(rect.minY - reach, center.y - max(0, trackRoom[.down] ?? .infinity))
                let end = min(rect.maxY + reach, center.y + max(0, trackRoom[.up] ?? .infinity))
                return CGRect(x: center.x - trackWidth / 2, y: start, width: trackWidth, height: max(0, end - start))
            }
            let start = max(rect.minX - reach, center.x - max(0, trackRoom[.left] ?? .infinity))
            let end = min(rect.maxX + reach, center.x + max(0, trackRoom[.right] ?? .infinity))
            return CGRect(x: start, y: center.y - trackWidth / 2, width: max(0, end - start), height: trackWidth)
        }
        self.bounds = bounds
        capsules = rects
        self.outline = cached?.capsules == capsules ? cached!.outline : BetterTileMacOS.outline(capsules)
        trackRects = tracks
    }
}

extension DividerHandleMode {
    var decorationMargins: CGPoint {
        switch self {
        case .vertical: CGPoint(x: 24, y: 84)
        case .horizontal: CGPoint(x: 84, y: 24)
        case .junction: CGPoint(x: 84, y: 84)
        }
    }
}

/// The two views share retained layers and filter instances. The decoration
/// translates the handle geometry into its larger, click-through panel.
@MainActor
final class DividerLensLayers {
    let handleLayer = CALayer()
    let decorationLayer = CALayer()
    let body = CAShapeLayer()
    let trackHosts = (0..<2).map { _ in CALayer() }
    private let tracks = (0..<2).map { _ in CAGradientLayer() }
    private let lenses = (0..<2).map { _ in CIFilter(name: "CIGlassLozenge")! }
    private let blurs = (0..<2).map { _ in CIFilter(name: "CIGaussianBlur")! }
    private var blurred = false
    private(set) var filterChainUpdateCount = 0
    private let rings = (0..<3).map { _ in CAShapeLayer() }
    private let hairline = CAShapeLayer()
    private let glints = (0..<4).map { _ in CALayer() }
    private let shadow = CALayer()
    private var capsules: [CGRect] = []

    init() {
        decorationLayer.addSublayer(shadow)
        for index in tracks.indices {
            let host = trackHosts[index]
            lenses[index].name = "lens"
            lenses[index].setValue(1.2, forKey: "inputRefraction")
            blurs[index].name = "frost"
            host.filters = [lenses[index]]
            host.addSublayer(tracks[index])
            decorationLayer.addSublayer(host)
            tracks[index].locations = [0, 0.3, 0.7, 1]
        }
        handleLayer.addSublayer(body)
        for ring in rings {
            ring.fillColor = nil
            ring.lineWidth = 1
            handleLayer.addSublayer(ring)
        }
        hairline.fillColor = nil
        handleLayer.addSublayer(hairline)
        for glint in glints {
            glint.shadowPath = CGMutablePath()
            glint.shadowColor = NSColor.white.cgColor
            glint.shadowOffset = .zero
            handleLayer.addSublayer(glint)
        }
        shadow.shadowColor = NSColor.black.cgColor
        shadow.shadowRadius = 3
        shadow.shadowOffset = CGSize(width: 0, height: -1)
    }

    func apply(geometry g: DividerLensGeometry, margins: CGPoint, tint: NSColor,
               dark: Bool, strength: Double, limited: Bool, p: Double) {
        handleLayer.frame = g.bounds
        decorationLayer.frame = g.bounds.insetBy(dx: -margins.x, dy: -margins.y)
        // The decoration view already supplies the outside margin.
        decorationLayer.frame.origin = .zero
        let hostFrame = CGRect(origin: margins, size: g.bounds.size)
        shadow.frame = hostFrame
        shadow.shadowPath = g.outline
        shadow.shadowOpacity = dark ? 0.45 : 0.16
        let width = g.capsuleAxes[0] == .vertical ? g.capsules[0].width : g.capsules[0].height
        let geometryChanged = capsules != g.capsules
        if geometryChanged {
            capsules = g.capsules
            body.path = g.outline
            hairline.path = g.outline
            for (index, inset) in [0.5, 1.5, 2.5].enumerated() {
                rings[index].isHidden = inset >= width / 2 - 1 || (capsules.count > 1 && index > 0)
                rings[index].path = capsules.count > 1 ? g.outline : capsulePath(capsules[0].insetBy(dx: inset, dy: inset))
            }
            for index in glints.indices {
                glints[index].isHidden = index / 2 >= capsules.count
                guard index / 2 < capsules.count else { continue }
                let arcs = capGlints(capsules[index / 2], vertical: g.capsuleAxes[index / 2] == .vertical,
                                     inset: max(0.8, 0.115 * width))
                glints[index].shadowPath = (index % 2 == 0 ? arcs.bright : arcs.dim).copy(
                    strokingWithWidth: min(1.4, max(0.8, 0.1 * width)), lineCap: .round, lineJoin: .round, miterLimit: 1
                )
            }
        }
        body.fillColor = NSColor.white.withAlphaComponent((dark ? 0.02 : 0.12) + (dark ? 0.12 : 0.40) * strength).cgColor
        for (index, alpha) in (dark ? [0.34, 0.12, 0.05] : [0.70, 0.30, 0.12]).enumerated() {
            rings[index].strokeColor = NSColor.white.withAlphaComponent(alpha).cgColor
        }
        hairline.strokeColor = (limited ? tint.withAlphaComponent(0.85)
            : NSColor.black.withAlphaComponent(dark ? 0.55 : 0.16)).cgColor
        hairline.lineWidth = limited ? 1 : 0.5
        for (index, glint) in glints.enumerated() {
            glint.frame = g.bounds
            glint.shadowOpacity = index % 2 == 0 ? (dark ? 0.55 : 0.9) : (dark ? 0.22 : 0.45)
            glint.shadowRadius = min(1.2, 0.09 * width)
        }
        let needsBlur = strength > 0.5
        for index in trackHosts.indices {
            let host = trackHosts[index]
            // Change the chain only when crossing the frost threshold. Pointer
            // samples update the named filters, never replace their arrays.
            if blurred != needsBlur { host.filters = needsBlur ? [lenses[index], blurs[index]] : [lenses[index]] }
            host.isHidden = index >= g.capsules.count || p == 0
            guard index < g.capsules.count else { continue }
            let capsule = g.capsules[index]
            let vertical = g.capsuleAxes[index] == .vertical
            let radius = width / 2
            host.frame = hostFrame
            host.setValue(vertical ? CIVector(x: capsule.midX, y: capsule.minY + radius)
                : CIVector(x: capsule.minX + radius, y: capsule.midY), forKeyPath: "filters.lens.inputPoint0")
            host.setValue(vertical ? CIVector(x: capsule.midX, y: capsule.maxY - radius)
                : CIVector(x: capsule.maxX - radius, y: capsule.midY), forKeyPath: "filters.lens.inputPoint1")
            host.setValue(radius, forKeyPath: "filters.lens.inputRadius")
            if needsBlur { host.setValue((strength - 0.5) * 5, forKeyPath: "filters.frost.inputRadius") }
            let track = tracks[index]
            track.frame = g.trackRects[index]
            track.cornerRadius = max(1.5, 0.21 * width) / 2
            track.colors = [0.0, 1, 1, 0].map { tint.withAlphaComponent($0 * p).cgColor }
            track.startPoint = vertical ? CGPoint(x: 0.5, y: 0) : CGPoint(x: 0, y: 0.5)
            track.endPoint = vertical ? CGPoint(x: 0.5, y: 1) : CGPoint(x: 1, y: 0.5)
        }
        if blurred != needsBlur { filterChainUpdateCount += 1 }
        blurred = needsBlur
    }

    func setContentsScale(_ scale: CGFloat) {
        func update(_ layer: CALayer) {
            layer.contentsScale = scale
            layer.sublayers?.forEach(update)
        }
        update(handleLayer)
        update(decorationLayer)
    }
}

private func capGlints(_ rect: CGRect, vertical: Bool, inset: CGFloat) -> (bright: CGPath, dim: CGPath) {
    let radius = (vertical ? rect.width : rect.height) / 2 - inset
    let bright = CGMutablePath()
    let dim = CGMutablePath()
    if vertical {
        bright.addArc(center: CGPoint(x: rect.midX, y: rect.maxY - radius - inset), radius: radius,
                      startAngle: .pi * 0.95, endAngle: .pi * 0.35, clockwise: true)
        dim.addArc(center: CGPoint(x: rect.midX, y: rect.minY + radius + inset), radius: radius,
                   startAngle: -.pi * 0.05, endAngle: -.pi * 0.65, clockwise: true)
    } else {
        bright.addArc(center: CGPoint(x: rect.minX + radius + inset, y: rect.midY), radius: radius,
                      startAngle: .pi * 1.25, endAngle: .pi * 0.6, clockwise: true)
        dim.addArc(center: CGPoint(x: rect.maxX - radius - inset, y: rect.midY), radius: radius,
                   startAngle: .pi * 0.25, endAngle: -.pi * 0.4, clockwise: true)
    }
    return (bright, dim)
}

@MainActor
final class DividerLensDecorationView: NSView {
    let lensLayers: DividerLensLayers
    var showsContent: Bool { !lensLayers.decorationLayer.isHidden }

    init(frame: CGRect, lensLayers: DividerLensLayers) {
        self.lensLayers = lensLayers
        super.init(frame: frame)
        wantsLayer = true
        layerUsesCoreImageFilters = true
        layer?.addSublayer(lensLayers.decorationLayer)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        lensLayers.setContentsScale(window?.backingScaleFactor ?? 1)
    }
}

func capsulePath(_ rect: CGRect) -> CGPath {
    let radius = min(rect.width, rect.height) / 2
    return CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func outline(_ capsules: [CGRect], inset: CGFloat = 0) -> CGPath {
    let union = capsules.map { capsulePath($0.insetBy(dx: inset, dy: inset)) }.reduce(nil as CGPath?) { $0?.union($1) ?? $1 }!
    guard capsules.count > 1 else { return union }
    let radius = min(capsules[0].width, capsules[0].height) * 0.45
    let dilated = union.union(union.copy(strokingWithWidth: 2 * radius, lineCap: .round, lineJoin: .round, miterLimit: 1))
    return dilated.subtracting(dilated.copy(strokingWithWidth: 2 * radius, lineCap: .round, lineJoin: .round, miterLimit: 1))
}
