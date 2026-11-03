import AppKit

// Padded-containment helper for the liquid wheel glow component.
struct LiquidWheelSectorBounds: Equatable, Sendable {
    var center: CGPoint
    var innerRadius: Double
    var outerRadius: Double
    var midAngle: Double
    var halfWidth: Double

    init(center: CGPoint, innerRadius: Double, outerRadius: Double, midAngle: Double, halfWidth: Double) {
        self.center = center
        self.innerRadius = innerRadius
        self.outerRadius = outerRadius
        self.midAngle = midAngle
        self.halfWidth = halfWidth
    }

    func point(angle: Double, radius: Double) -> CGPoint {
        CGPoint(x: center.x + radius * sin(angle), y: center.y - radius * cos(angle))
    }

    /// Radius and the signed angle from `midAngle`, in (-pi, pi].
    func polar(_ point: CGPoint) -> (radius: Double, offset: Double) {
        let dx = point.x - center.x
        let dy = point.y - center.y
        let radius = (dx * dx + dy * dy).squareRoot()
        guard radius > 0 else { return (0, 0) }
        return (radius, remainder(atan2(dx, -dy) - midAngle, 2 * .pi))
    }

    /// True when `point` is inside the sector and at least `padding` from
    /// both arcs and both radial edges.
    func contains(_ point: CGPoint, padding: Double = 0) -> Bool {
        let (radius, offset) = polar(point)
        guard abs(offset) <= halfWidth,
              radius - innerRadius >= padding,
              outerRadius - radius >= padding else { return false }
        let edgeAngle = halfWidth - abs(offset)
        let edgeDistance = edgeAngle >= .pi / 2 ? radius : radius * sin(edgeAngle)
        return edgeDistance >= padding
    }

    /// True when the whole rectangle, sampled along its edges, keeps `padding`
    /// from every boundary. Sampling catches the concave inner arc.
    func contains(_ rect: CGRect, padding: Double) -> Bool {
        let steps = 12
        for step in 0...steps {
            let t = Double(step) / Double(steps)
            let x = rect.minX + rect.width * t
            let y = rect.minY + rect.height * t
            for point in [CGPoint(x: x, y: rect.minY), CGPoint(x: x, y: rect.maxY),
                          CGPoint(x: rect.minX, y: y), CGPoint(x: rect.maxX, y: y)]
            where !contains(point, padding: padding) {
                return false
            }
        }
        return true
    }

}
