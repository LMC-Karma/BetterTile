import AppKit
import BetterTileCore
import SwiftUI

/// Connected partitions. The selected region is one rectangle, clipped only
/// by the outside frame. A merged target has no internal divider.
struct WindowActionPartitionGlyph: Hashable, Sendable {
    let rows: Int
    let firstColumn: Int
    let columnCount: Int
    let row: Int

    static let actions: [WindowAction: Self] = [
        .leftThird: .init(rows: 1, firstColumn: 0, columnCount: 1, row: 0),
        .centerThird: .init(rows: 1, firstColumn: 1, columnCount: 1, row: 0),
        .rightThird: .init(rows: 1, firstColumn: 2, columnCount: 1, row: 0),
        .leftTwoThirds: .init(rows: 1, firstColumn: 0, columnCount: 2, row: 0),
        .rightTwoThirds: .init(rows: 1, firstColumn: 1, columnCount: 2, row: 0),
        .topLeftSixth: .init(rows: 2, firstColumn: 0, columnCount: 1, row: 0),
        .topCenterSixth: .init(rows: 2, firstColumn: 1, columnCount: 1, row: 0),
        .topRightSixth: .init(rows: 2, firstColumn: 2, columnCount: 1, row: 0),
        .bottomLeftSixth: .init(rows: 2, firstColumn: 0, columnCount: 1, row: 1),
        .bottomCenterSixth: .init(rows: 2, firstColumn: 1, columnCount: 1, row: 1),
        .bottomRightSixth: .init(rows: 2, firstColumn: 2, columnCount: 1, row: 1),
    ]

    struct Drawing {
        let frame: CGRect
        let stroke: CGFloat
        let radius: CGFloat
        let columns: [CGFloat]
        let rowEdges: [CGFloat]
        let target: CGRect
        let verticalDividers: [CGFloat]

        var inkBounds: CGRect { frame.insetBy(dx: -stroke / 2, dy: -stroke / 2) }

        var cells: [CGRect] {
            (0 ..< rowEdges.count - 1).flatMap { row in
                (0 ..< 3).map { column in
                    CGRect(x: columns[column], y: rowEdges[row],
                           width: columns[column + 1] - columns[column],
                           height: rowEdges[row + 1] - rowEdges[row])
                }
            }
        }

        func draw(in context: CGContext) {
            let outline = CGPath(roundedRect: frame, cornerWidth: radius, cornerHeight: radius, transform: nil)
            context.saveGState()
            context.setFillColor(NSColor.black.cgColor)
            context.setStrokeColor(NSColor.black.cgColor)
            context.setLineWidth(stroke)
            context.setLineJoin(.round)
            context.addPath(outline)
            context.clip()
            context.fill(target)
            context.restoreGState()
            context.saveGState()
            context.setStrokeColor(NSColor.black.cgColor)
            context.setLineWidth(stroke)
            context.setLineJoin(.round)
            context.addPath(outline)
            context.strokePath()
            for x in verticalDividers {
                context.move(to: CGPoint(x: x, y: frame.minY))
                context.addLine(to: CGPoint(x: x, y: frame.maxY))
            }
            for y in rowEdges.dropFirst().dropLast() {
                context.move(to: CGPoint(x: frame.minX, y: y))
                context.addLine(to: CGPoint(x: frame.maxX, y: y))
            }
            context.strokePath()
            context.restoreGState()
        }
    }

    // Measured against the native half and quarter at 13, 16, 18 and 24 pt.
    // Values describe the outside ink, rather than the stroke centre line.
    private static func metrics(pointSize: CGFloat, weight: LayoutGlyphWeight) -> (ink: CGSize, stroke: CGFloat, radius: CGFloat) {
        let semibold = weight == .semibold
        return (CGSize(width: pointSize * (semibold ? 1.159 : 1.151),
                       height: pointSize * (semibold ? 0.922 : 0.899)),
                pointSize * (semibold ? 0.109 : 0.079),
                pointSize * (semibold ? 0.142 : 0.130))
    }

    static func canvasSize(pointSize: CGFloat, weight: LayoutGlyphWeight) -> CGSize {
        let ink = metrics(pointSize: pointSize, weight: weight).ink
        return CGSize(width: ceil(ink.width + 4), height: ceil(ink.height + 4))
    }

    func drawing(pointSize: CGFloat, weight: LayoutGlyphWeight, displayScale: CGFloat) -> Drawing {
        let metrics = Self.metrics(pointSize: pointSize, weight: weight)
        let canvas = Self.canvasSize(pointSize: pointSize, weight: weight)
        let scale = max(1, displayScale)
        let stroke = max(1 / scale, metrics.stroke)
        let frame = CGRect(x: (canvas.width - metrics.ink.width + stroke) / 2,
                           y: (canvas.height - metrics.ink.height + stroke) / 2,
                           width: metrics.ink.width - stroke, height: metrics.ink.height - stroke)
        // At 1x the same lattice applies to the frame, dividers and fill.
        // Rounding equally spaced boundaries keeps widths within one pixel.
        func snap(_ value: CGFloat) -> CGFloat {
            guard scale == 1 else { return value }
            let phase: CGFloat = Int(stroke.rounded()) % 2 == 0 ? 0 : 0.5
            return (value - phase).rounded() + phase
        }
        let columns = (0 ... 3).map { snap(frame.minX + frame.width * CGFloat($0) / 3) }
        let rowEdges = (0 ... rows).map { snap(frame.minY + frame.height * CGFloat($0) / CGFloat(rows)) }
        let snapped = CGRect(x: columns[0], y: rowEdges[0], width: columns[3] - columns[0], height: rowEdges[rows] - rowEdges[0])
        let target = CGRect(x: columns[firstColumn], y: rowEdges[row],
                            width: columns[firstColumn + columnCount] - columns[firstColumn],
                            height: rowEdges[row + 1] - rowEdges[row])
        let dividers = (1 ... 2).filter { !((firstColumn + 1) ..< (firstColumn + columnCount)).contains($0) }
        return Drawing(frame: snapped, stroke: stroke, radius: max(0, metrics.radius - stroke / 2),
                       columns: columns, rowEdges: rowEdges, target: target,
                       verticalDividers: dividers.map { columns[$0] })
    }

    private struct ImageKey: Hashable {
        let glyph: WindowActionPartitionGlyph
        let pointSize: CGFloat
        let weight: LayoutGlyphWeight
    }
    @MainActor private static var images: [ImageKey: NSImage] = [:]

    @MainActor func templateImage(pointSize: CGFloat, weight: LayoutGlyphWeight) -> NSImage {
        let key = ImageKey(glyph: self, pointSize: pointSize, weight: weight)
        if let cached = Self.images[key] { return cached }
        let image = NSImage(size: Self.canvasSize(pointSize: pointSize, weight: weight), flipped: true) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            let scale = max(1, hypot(context.ctm.a, context.ctm.b))
            self.drawing(pointSize: pointSize, weight: weight, displayScale: scale).draw(in: context)
            return true
        }
        image.isTemplate = true
        Self.images[key] = image
        return image
    }
}
