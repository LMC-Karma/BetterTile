import AppKit
import BetterTileCore
import SwiftUI

// Draws the layout and mode icon set from the geometry table in `LayoutGlyph`.
//
// Two renderers share one drawing: a SwiftUI view for Settings and the Layout
// Wheel, and a cached template `NSImage` for menus, segmented controls and
// AppKit drawing. Both stroke with round caps and round joins, and both ask
// `LayoutGlyph.drawing` for the stroke width and pixel snapping.

extension LayoutGlyphDrawing {
    /// One path for each stroked part. Arcs are drawn as quarter ellipses.
    func cgPaths() -> [CGPath] {
        paths.map { commands in
            let path = CGMutablePath()
            var current = CGPoint.zero
            // A pane starts along its top edge, so the first arc turns from a horizontal line.
            var horizontal = true
            for command in commands {
                switch command {
                case let .move(x, y):
                    current = CGPoint(x: x, y: y)
                    path.move(to: current)
                case let .line(x, y):
                    let next = CGPoint(x: x, y: y)
                    if next.x != current.x || next.y != current.y { horizontal = abs(next.x - current.x) >= abs(next.y - current.y) }
                    path.addLine(to: next)
                    current = next
                case let .arc(_, x, y):
                    let end = CGPoint(x: x, y: y)
                    let corner = horizontal ? CGPoint(x: end.x, y: current.y) : CGPoint(x: current.x, y: end.y)
                    let k = 0.5522847498
                    path.addCurve(
                        to: end,
                        control1: CGPoint(x: current.x + k * (corner.x - current.x), y: current.y + k * (corner.y - current.y)),
                        control2: CGPoint(x: end.x + k * (corner.x - end.x), y: end.y + k * (corner.y - end.y))
                    )
                    current = end
                    horizontal.toggle()
                case .close:
                    path.closeSubpath()
                }
            }
            return path
        }
    }
}

/// A layout or mode icon, stroked in the current foreground style.
///
/// `size` is the canvas size. Beside an SF Symbol of point size S, use
/// `LayoutGlyph.canvasSize(besideSymbolSize: S)`. Pane numbers appear only in
/// the Settings starting-layout pictures.
public struct LayoutGlyphView: View {
    private let glyph: LayoutGlyph
    private let size: CGFloat
    private let weight: LayoutGlyphWeight
    private let numbered: Bool

    @Environment(\.displayScale) private var displayScale

    public init(_ glyph: LayoutGlyph, size: CGFloat, weight: LayoutGlyphWeight = .regular, numbered: Bool = false) {
        self.glyph = glyph
        self.size = size
        self.weight = weight
        self.numbered = numbered
    }

    public var body: some View {
        let drawing = glyph.drawing(canvasSize: Double(size), weight: weight,
                                    displayScale: Double(displayScale), numbered: numbered)
        Canvas { context, _ in
            let style = StrokeStyle(lineWidth: CGFloat(drawing.strokeWidth), lineCap: .round, lineJoin: .round)
            for path in drawing.cgPaths() { context.stroke(Path(path), with: .foreground, style: style) }
            for number in drawing.numbers {
                let text = context.resolve(
                    Text(number.text).font(.system(size: CGFloat(number.fontSize), weight: .semibold))
                )
                context.draw(text, at: CGPoint(x: number.centerX, y: number.centerY), anchor: .center)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

// MARK: - Template images

private struct LayoutGlyphImageKey: Hashable {
    let glyph: LayoutGlyph
    let size: CGFloat
    let weight: LayoutGlyphWeight
    let trailingPadding: CGFloat
}

@MainActor private var layoutGlyphImages: [LayoutGlyphImageKey: NSImage] = [:]

public extension LayoutGlyph {
    /// A template image of the icon, cached for each icon, canvas size and weight.
    ///
    /// The image draws itself at the scale of the surface that shows it, so the stroke
    /// is never under one device pixel and straight edges snap on a 1x display below
    /// 20 points. A menu, a segmented control or a template `Image` colours it.
    /// `trailingPadding` adds transparent width after the canvas, to space the icon from a title.
    @MainActor
    func templateImage(canvasSize: CGFloat, weight: LayoutGlyphWeight = .regular, trailingPadding: CGFloat = 0) -> NSImage {
        let glyph = canonical
        let key = LayoutGlyphImageKey(glyph: glyph, size: canvasSize, weight: weight, trailingPadding: trailingPadding)
        if let cached = layoutGlyphImages[key] { return cached }
        let image = NSImage(size: NSSize(width: canvasSize + trailingPadding, height: canvasSize), flipped: true) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            glyph.stroke(in: context, origin: .zero, canvasSize: canvasSize, weight: weight,
                         color: NSColor.black.cgColor, flipped: true)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = glyph.title
        layoutGlyphImages[key] = image
        return image
    }

    /// Strokes the icon into a Core Graphics context, for AppKit views that draw themselves.
    ///
    /// `origin` is the top left of the canvas in the view's coordinates. Pass `flipped` as the
    /// view's `isFlipped`. The display scale comes from the context, so the stroke floor and the
    /// pixel snapping match the surface.
    func stroke(
        in context: CGContext,
        origin: CGPoint,
        canvasSize: CGFloat,
        weight: LayoutGlyphWeight = .regular,
        color: CGColor,
        flipped: Bool
    ) {
        let transform = context.ctm
        let scale = max(1, hypot(transform.a, transform.b))
        let art = self.drawing(canvasSize: Double(canvasSize), weight: weight, displayScale: Double(scale))
        context.saveGState()
        defer { context.restoreGState() }
        if flipped {
            context.translateBy(x: origin.x, y: origin.y)
        } else {
            // The drawing is top left and y down. Turn it over inside its own canvas.
            context.translateBy(x: origin.x, y: origin.y + canvasSize)
            context.scaleBy(x: 1, y: -1)
        }
        context.setStrokeColor(color)
        context.setLineWidth(CGFloat(art.strokeWidth))
        context.setLineCap(.round)
        context.setLineJoin(.round)
        for path in art.cgPaths() {
            context.addPath(path)
            context.strokePath()
        }
    }

    /// The same template image as a SwiftUI `Image`, for menu items and segmented pickers.
    @MainActor
    func templateSwiftUIImage(canvasSize: CGFloat, weight: LayoutGlyphWeight = .regular) -> Image {
        Image(nsImage: templateImage(canvasSize: canvasSize, weight: weight))
    }
}
