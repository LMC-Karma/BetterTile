import AppKit
import BetterTileCore

/// Coordinates stay in the non-flipped handle view. Room uses screen directions.
struct DividerLensGeometry {
    let bounds: CGRect
    let capsules: [CGRect]
    let capsuleAxes: [SplitAxis]
    let outline: CGPath
    let corePaths: [CGPath]
    let glossRects: [CGRect]
    let trackRects: [CGRect]
    var boundingBox: CGRect { outline.boundingBoxOfPath }

    init(
        bounds: CGRect, mode: DividerHandleMode, thickness: Double, progress: Double,
        trackRoom: [DividerHandleArm: Double] = [:], originOffset: CGPoint = .zero,
        useLiquidGlass: Bool = true
    ) {
        func interpolate(_ a: Double, _ b: Double) -> CGFloat { a + (b - a) * progress }
        let resting = min(16, max(12, thickness + 4))
        let active = DividerHandleGeometry.renderedThickness(thickness, useLiquidGlass: true)
        let width = useLiquidGlass ? interpolate(resting, active) : thickness
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
        let tracks = zip(rects, capsuleAxes).map { rect, axis in
            if axis == .vertical {
                let start = max(rect.minY - reach, center.y - max(0, trackRoom[.down] ?? .infinity))
                let end = min(rect.maxY + reach, center.y + max(0, trackRoom[.up] ?? .infinity))
                return CGRect(x: center.x - 1.5, y: start, width: 3, height: max(0, end - start))
            }
            let start = max(rect.minX - reach, center.x - max(0, trackRoom[.left] ?? .infinity))
            let end = min(rect.maxX + reach, center.x + max(0, trackRoom[.right] ?? .infinity))
            return CGRect(x: start, y: center.y - 1.5, width: max(0, end - start), height: 3)
        }
        self.bounds = CGRect(origin: .zero, size: CGSize(
            width: bounds.width + originOffset.x * 2, height: bounds.height + originOffset.y * 2
        ))
        capsules = rects.map { $0.offsetBy(dx: originOffset.x, dy: originOffset.y) }
        self.outline = BetterTileMacOS.outline(capsules)
        corePaths = zip(capsules, capsuleAxes).map { capsule, axis in
            refractedTrack(capsule, track: 3, magnification: interpolate(1.5, 1.8), vertical: axis == .vertical)
        }
        glossRects = zip(capsules, capsuleAxes).map { capsule, axis in
            let thick = axis == .vertical ? capsule.width : capsule.height
            return axis == .vertical
                ? CGRect(x: capsule.minX + thick * 0.2, y: capsule.minY + thick * 0.9,
                         width: max(1.2, thick * 0.14), height: max(0, capsule.height - thick * 1.5))
                : CGRect(x: capsule.minX + thick * 0.9, y: capsule.maxY - thick * 0.2 - max(1.2, thick * 0.14),
                         width: max(0, capsule.width - thick * 1.5), height: max(1.2, thick * 0.14))
        }
        trackRects = tracks.map { $0.offsetBy(dx: originOffset.x, dy: originOffset.y) }
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

/// The roots are hosted by separate views, but every layer is allocated once.
@MainActor
final class DividerLensLayers {
    let handleLayer = CALayer()
    let decorationLayer = CALayer()
    private let optics = CALayer()
    private let clip = CAShapeLayer()
    private let body = CAGradientLayer()
    private let cores = (0..<2).map { _ in CAShapeLayer() }
    private let edgeBand = CAGradientLayer()
    private let band = CAShapeLayer()
    private let depth = CAGradientLayer()
    private let depthRing = CAShapeLayer()
    private let glosses = (0..<2).map { _ in CAGradientLayer() }
    private let glossMasks = (0..<2).map { _ in CAShapeLayer() }
    private let specular = CAGradientLayer()
    private let rim = CAShapeLayer()
    private let hairline = CAShapeLayer()
    private let tracks = (0..<2).map { _ in CAGradientLayer() }
    private let trackMasks = (0..<2).map { _ in CAShapeLayer() }
    private let shadow = CAShapeLayer()
    private let outside = CAShapeLayer()

    init() {
        for index in tracks.indices {
            tracks[index].mask = trackMasks[index]
            decorationLayer.addSublayer(tracks[index])
        }
        shadow.mask = outside
        decorationLayer.addSublayer(shadow)
        optics.mask = clip
        handleLayer.addSublayer(optics)
        optics.addSublayer(body)
        for core in cores { optics.addSublayer(core) }
        edgeBand.mask = band
        optics.addSublayer(edgeBand)
        depth.mask = depthRing
        optics.addSublayer(depth)
        for index in glosses.indices {
            glosses[index].mask = glossMasks[index]
            optics.addSublayer(glosses[index])
        }
        specular.mask = rim
        handleLayer.addSublayer(specular)
        handleLayer.addSublayer(hairline)
    }

    func apply(geometry g: DividerLensGeometry, tint: NSColor, dark: Bool, frost: Double, limited: Bool, p: Double) {
        let cg = { (alpha: CGFloat) in tint.withAlphaComponent(alpha).cgColor }
        let white = { (alpha: CGFloat) in NSColor.white.withAlphaComponent(alpha).cgColor }
        let box = g.boundingBox
        handleLayer.frame = g.bounds
        optics.frame = g.bounds
        clip.path = g.outline
        body.frame = box
        body.colors = [white(min(1, (dark ? 0.10 : 0.42) * frost)), white(min(1, (dark ? 0.02 : 0.12) * frost))]
        body.startPoint = CGPoint(x: 0.3, y: 1)
        body.endPoint = CGPoint(x: 0.7, y: 0)
        for index in cores.indices {
            cores[index].isHidden = index >= g.corePaths.count
            glosses[index].isHidden = index >= g.glossRects.count
            guard index < g.corePaths.count else { continue }
            let core = cores[index]
            core.path = g.corePaths[index]
            core.fillColor = cg(0.70 + 0.15 * p)
            core.shadowColor = cg(1)
            core.shadowOpacity = 0.6
            core.shadowRadius = 2
            core.shadowOffset = .zero
            let streak = g.glossRects[index]
            let vertical = g.capsuleAxes[index] == .vertical
            let gloss = glosses[index]
            gloss.frame = streak
            gloss.colors = [white(0), white(0.75), white(0.15)]
            gloss.locations = [0, 0.75, 1]
            gloss.startPoint = vertical ? CGPoint(x: 0.5, y: 0) : CGPoint(x: 0, y: 0.5)
            gloss.endPoint = vertical ? CGPoint(x: 0.5, y: 1) : CGPoint(x: 1, y: 0.5)
            glossMasks[index].path = capsulePath(CGRect(origin: .zero, size: streak.size))
        }
        edgeBand.frame = g.bounds
        if g.capsules.count > 1 {
            edgeBand.type = .radial
            edgeBand.colors = [cg(0.15), cg(0.55)]
            edgeBand.locations = nil
            edgeBand.startPoint = CGPoint(x: box.midX / g.bounds.width, y: box.midY / g.bounds.height)
            edgeBand.endPoint = CGPoint(x: box.maxX / g.bounds.width, y: box.maxY / g.bounds.height)
        } else {
            edgeBand.type = .axial
            edgeBand.colors = [cg(0.75), cg(0.12), cg(0.12), cg(0.75)]
            edgeBand.locations = [0, 0.42, 0.58, 1]
            let vertical = g.capsuleAxes[0] == .vertical
            edgeBand.startPoint = vertical
                ? CGPoint(x: 0.5, y: box.minY / g.bounds.height) : CGPoint(x: box.minX / g.bounds.width, y: 0.5)
            edgeBand.endPoint = vertical
                ? CGPoint(x: 0.5, y: box.maxY / g.bounds.height) : CGPoint(x: box.maxX / g.bounds.width, y: 0.5)
        }
        setRing(band, path: outline(g.capsules, inset: 1.6), width: 2.6)
        depth.frame = box
        depth.colors = [NSColor.black.withAlphaComponent(dark ? 0.35 : 0.14).cgColor, NSColor.clear.cgColor]
        depth.startPoint = CGPoint(x: 0.8, y: 0)
        depth.endPoint = CGPoint(x: 0.4, y: 0.45)
        depthRing.frame = CGRect(origin: .zero, size: box.size)
        var toBox = CGAffineTransform(translationX: -box.minX, y: -box.minY)
        setRing(depthRing, path: outline(g.capsules, inset: 1.2).copy(using: &toBox), width: 2.2)
        specular.type = .conic
        specular.frame = box.insetBy(dx: -2, dy: -2)
        specular.startPoint = CGPoint(x: 0.5, y: 0.5)
        specular.endPoint = CGPoint(x: 0, y: 1)
        specular.colors = [white(1), white(0.35), white(0.12), white(0.7), white(0.12), white(0.35), white(1)]
        specular.locations = [0, 0.14, 0.32, 0.5, 0.68, 0.86, 1]
        var toSpec = CGAffineTransform(translationX: -specular.frame.minX, y: -specular.frame.minY)
        setRing(rim, path: outline(g.capsules, inset: 0.6).copy(using: &toSpec), width: 1.2)
        hairline.path = g.outline
        hairline.fillColor = nil
        hairline.strokeColor = limited ? cg(0.9) : NSColor.black.withAlphaComponent(dark ? 0.5 : 0.18).cgColor
        hairline.lineWidth = limited ? 1 : 0.5
    }

    func applyDecoration(geometry g: DividerLensGeometry, tint: NSColor, dark: Bool, p: Double) {
        decorationLayer.frame = g.bounds
        for index in tracks.indices {
            tracks[index].isHidden = index >= g.trackRects.count
            guard index < g.trackRects.count else { continue }
            let rect = g.trackRects[index]
            let track = tracks[index]
            track.frame = rect
            track.colors = [0.0, 1, 1, 0].map { tint.withAlphaComponent($0).cgColor }
            track.locations = [0, 0.3, 0.7, 1]
            let vertical = g.capsuleAxes[index] == .vertical
            track.startPoint = vertical ? CGPoint(x: 0.5, y: 0) : CGPoint(x: 0, y: 0.5)
            track.endPoint = vertical ? CGPoint(x: 0.5, y: 1) : CGPoint(x: 1, y: 0.5)
            trackMasks[index].path = capsulePath(CGRect(origin: .zero, size: rect.size))
        }
        shadow.frame = g.bounds
        shadow.path = g.outline
        shadow.fillColor = NSColor.black.cgColor
        shadow.shadowColor = NSColor.black.cgColor
        shadow.shadowOpacity = dark ? 0.55 : 0.28
        shadow.shadowRadius = 4 + 5 * p
        shadow.shadowOffset = CGSize(width: 0, height: -(1.5 + 2.5 * p))
        let cut = CGMutablePath()
        cut.addRect(g.bounds)
        cut.addPath(g.outline)
        outside.path = cut
        outside.fillRule = .evenOdd
    }

    private func setRing(_ layer: CAShapeLayer, path: CGPath?, width: CGFloat) {
        layer.path = path
        layer.fillColor = nil
        layer.strokeColor = NSColor.white.cgColor
        layer.lineWidth = width
    }

    func setContentsScale(_ scale: CGFloat) {
        func update(_ layer: CALayer) {
            layer.contentsScale = scale
            if let mask = layer.mask { update(mask) }
            layer.sublayers?.forEach(update)
        }
        update(handleLayer)
        update(decorationLayer)
    }
}

@MainActor
final class DividerLensDecorationView: NSView {
    let lensLayers: DividerLensLayers
    var showsContent: Bool { !lensLayers.decorationLayer.isHidden }

    init(frame: CGRect, lensLayers: DividerLensLayers) {
        self.lensLayers = lensLayers
        super.init(frame: frame)
        wantsLayer = true
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

/// Track as seen through the lens: magnified across the body, pinched where
/// it enters the end caps.
func refractedTrack(_ rect: CGRect, track: CGFloat, magnification: CGFloat, vertical: Bool) -> CGPath {
    let r = vertical ? rect : CGRect(x: rect.minY, y: rect.minX, width: rect.height, height: rect.width)
    let cap = r.width / 2
    let wide = min(r.width * 0.36, track * magnification)
    let cx = r.midX
    let path = CGMutablePath()
    path.move(to: CGPoint(x: cx - track / 2, y: r.minY))
    path.addCurve(to: CGPoint(x: cx - wide / 2, y: r.minY + cap * 1.4),
                  control1: CGPoint(x: cx - track / 2, y: r.minY + cap * 0.6),
                  control2: CGPoint(x: cx - wide / 2, y: r.minY + cap * 0.8))
    path.addLine(to: CGPoint(x: cx - wide / 2, y: r.maxY - cap * 1.4))
    path.addCurve(to: CGPoint(x: cx - track / 2, y: r.maxY),
                  control1: CGPoint(x: cx - wide / 2, y: r.maxY - cap * 0.8),
                  control2: CGPoint(x: cx - track / 2, y: r.maxY - cap * 0.6))
    path.addLine(to: CGPoint(x: cx + track / 2, y: r.maxY))
    path.addCurve(to: CGPoint(x: cx + wide / 2, y: r.maxY - cap * 1.4),
                  control1: CGPoint(x: cx + track / 2, y: r.maxY - cap * 0.6),
                  control2: CGPoint(x: cx + wide / 2, y: r.maxY - cap * 0.8))
    path.addLine(to: CGPoint(x: cx + wide / 2, y: r.minY + cap * 1.4))
    path.addCurve(to: CGPoint(x: cx + track / 2, y: r.minY),
                  control1: CGPoint(x: cx + wide / 2, y: r.minY + cap * 0.8),
                  control2: CGPoint(x: cx + track / 2, y: r.minY + cap * 0.6))
    path.closeSubpath()
    guard !vertical else { return path }
    var swap = CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0)
    return path.copy(using: &swap)!
}
