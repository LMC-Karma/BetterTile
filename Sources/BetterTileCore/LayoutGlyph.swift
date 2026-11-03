import Foundation

/// The stroke weights of the layout and mode icons, in canvas units at a
/// 24-unit canvas. Regular is for settings, menus and pickers. Semibold is for
/// the Layout Wheel.
public enum LayoutGlyphWeight: Sendable, Hashable, CaseIterable {
    case regular, semibold

    /// Stroke width at a 24-unit canvas.
    public var strokeAtReferenceSize: Double {
        switch self {
        case .regular: 1.5
        case .semibold: 2.0
        }
    }
}

/// One drawing step of an icon, in canvas units with the origin at the top
/// left. Coordinates are absolute. `arc` is a quarter turn clockwise from the
/// current point, matching the SVG arc flags `0 0 1` that the icons use.
public enum LayoutGlyphCommand: Equatable, Sendable {
    case move(x: Double, y: Double)
    case line(x: Double, y: Double)
    case arc(radius: Double, x: Double, y: Double)
    case close
}

/// A pane outline, as centre-line geometry in canvas units.
public struct LayoutGlyphRect: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(_ x: Double, _ y: Double, _ width: Double, _ height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
    public var midX: Double { x + width / 2 }
    public var midY: Double { y + height / 2 }
}

/// One stroked part of an icon: a rounded pane outline, or a free path.
public enum LayoutGlyphPart: Equatable, Sendable {
    case pane(LayoutGlyphRect)
    case path([LayoutGlyphCommand])
}

/// A pane number to draw inside a layout picture, centred on its pane.
public struct LayoutGlyphNumber: Equatable, Sendable {
    public var text: String
    public var centerX: Double
    public var centerY: Double
    /// Font size in the same units as the drawing.
    public var fontSize: Double
}

/// What to stroke for one icon at one size and display scale. Every value is
/// in points of the final canvas. Already snapped to the pixel grid when the
/// rules in `LayoutGlyph.drawing` ask for it.
public struct LayoutGlyphDrawing: Equatable, Sendable {
    public var canvasSize: Double
    public var strokeWidth: Double
    public var paths: [[LayoutGlyphCommand]]
    public var numbers: [LayoutGlyphNumber]
}

/// The layout and mode icon set (direction E).
///
/// This file holds the only copy of the icon geometry. The renderers in
/// `BetterTileMacOS` stroke it. The reference artwork is the E SVG set; a test
/// compares `svgPathData` with those files' path data.
///
/// Rules (see the design specification, section 6.2):
/// - The canvas is 24 by 24 units. Coordinates are stroke centre lines.
/// - Outline only. Round caps and round joins. One pane radius.
/// - Parallel centre lines are 3.5 units apart.
public enum LayoutGlyph: Hashable, Sendable {
    case layout(TabbedPreset)
    case mode(LayoutMode)
    /// The master icon for "Choose Layout" and for layout settings in general.
    case layouts

    /// Every distinct icon, in the order the set is presented.
    public static let all: [LayoutGlyph] =
        TabbedPreset.allCases.map(LayoutGlyph.layout)
        + LayoutMode.availableModes.map(LayoutGlyph.mode)
        + [.layouts]

    public static let canvasUnits = 24.0
    /// One radius for every pane, in canvas units.
    public static let paneRadius = 1.75
    /// Distance between parallel centre lines of separate panes.
    public static let separation = 3.5
    /// The canvas size beside a symbol of the given point size.
    public static let canvasScale = 1.265
    /// Pane numbers never draw under 9 points. At the 52 point Settings size this raises the
    /// short-pane numbers from 8.23 points to 9. The 9 point text floor wins over the specification's size.
    public static let minimumNumberFontSize = 9.0

    public static func canvasSize(besideSymbolSize symbolSize: Double) -> Double {
        symbolSize * canvasScale
    }

    /// The icon that stands for `mode`. Linked mode is not available in the
    /// product, so it uses Manual's icon.
    public var canonical: LayoutGlyph {
        if case let .mode(mode) = self { return .mode(mode.availableMode) }
        return self
    }

    public var title: String {
        switch self {
        case let .layout(preset): preset.title
        case let .mode(mode): mode.availableMode.title
        case .layouts: "Layouts"
        }
    }

    /// The reference file name, without extension.
    public var fileName: String {
        switch canonical {
        case let .layout(preset): "bt.layout.\(preset.rawValue)"
        case let .mode(mode):
            switch mode {
            case .bento: "bt.mode.adaptive"
            case .tabbed: "bt.mode.tabbed"
            case .manual, .linked: "bt.mode.manual"
            }
        case .layouts: "bt.layouts"
        }
    }

    // MARK: - Geometry table

    private static func panes(_ rects: [LayoutGlyphRect]) -> [LayoutGlyphPart] { rects.map(LayoutGlyphPart.pane) }

    /// The pane rectangles of a layout icon, in pane order. These also place
    /// the pane numbers.
    public static func paneRects(of preset: TabbedPreset) -> [LayoutGlyphRect] {
        switch preset {
        case .single:
            [.init(1.75, 4.25, 20.5, 15.5)]
        case .columns:
            [.init(1.75, 4.25, 8.5, 15.5), .init(13.75, 4.25, 8.5, 15.5)]
        case .rows:
            [.init(1.75, 4.25, 20.5, 6), .init(1.75, 13.75, 20.5, 6)]
        case .focus:
            [.init(1.75, 4.25, 10.25, 15.5), .init(15.5, 4.25, 6.75, 6), .init(15.5, 13.75, 6.75, 6)]
        case .grid:
            [.init(1.75, 4.25, 8.5, 6), .init(13.75, 4.25, 8.5, 6),
             .init(1.75, 13.75, 8.5, 6), .init(13.75, 13.75, 8.5, 6)]
        }
    }

    /// The stroked parts of this icon.
    public var parts: [LayoutGlyphPart] {
        switch canonical {
        case let .layout(preset):
            Self.panes(Self.paneRects(of: preset))
        case .mode(.manual), .mode(.linked):
            [
                // The back pane is interrupted so it keeps the shared clearance from the front pane.
                .path([
                    .move(x: 5.25, y: 13.75), .line(x: 3.5, y: 13.75),
                    .arc(radius: 1.75, x: 1.75, y: 12), .line(x: 1.75, y: 5),
                    .arc(radius: 1.75, x: 3.5, y: 3.25), .line(x: 13.5, y: 3.25),
                    .arc(radius: 1.75, x: 15.25, y: 5), .line(x: 15.25, y: 6.75),
                ]),
                .pane(.init(8.75, 10.25, 13.5, 10.5)),
            ]
        case .mode(.bento):
            [
                .pane(.init(1.75, 4.25, 11.25, 10.5)),
                .pane(.init(16.5, 4.25, 5.75, 10.5)),
                .path([.move(x: 5.25, y: 19.75), .line(x: 18.75, y: 19.75)]),
                .path([.move(x: 7.25, y: 17.75), .line(x: 5.25, y: 19.75), .line(x: 7.25, y: 21.75)]),
                .path([.move(x: 16.75, y: 17.75), .line(x: 18.75, y: 19.75), .line(x: 16.75, y: 21.75)]),
            ]
        case .mode(.tabbed):
            [
                .pane(.init(1.75, 4.25, 20.5, 15.5)),
                .path([.move(x: 9.25, y: 4.25), .line(x: 9.25, y: 8.5), .line(x: 22.25, y: 8.5)]),
                .path([.move(x: 15.75, y: 4.25), .line(x: 15.75, y: 8.5)]),
            ]
        case .layouts:
            [
                .path([.move(x: 5.25, y: 4.25), .line(x: 18.75, y: 4.25)]),
                .pane(.init(1.75, 7.75, 11.25, 12)),
                .pane(.init(16.5, 7.75, 5.75, 12)),
            ]
        }
    }

    /// Pane numbers for the Settings starting-layout pictures. Empty for
    /// every icon but the five layouts.
    public var numbers: [LayoutGlyphNumber] {
        guard case let .layout(preset) = canonical else { return [] }
        return Self.paneRects(of: preset).enumerated().map { index, rect in
            LayoutGlyphNumber(text: "\(index + 1)", centerX: rect.midX, centerY: rect.midY,
                              fontSize: rect.height <= 6 ? 3.8 : 5)
        }
    }

    // MARK: - SVG reference

    /// The `d` attribute of each part's SVG path, as in the E reference files.
    public var svgPathData: [String] {
        parts.map { part in
            Self.svg(Self.commands(of: part, radius: Self.paneRadius))
        }
    }

    static func commands(of part: LayoutGlyphPart, radius: Double) -> [LayoutGlyphCommand] {
        switch part {
        case let .path(commands): commands
        case let .pane(rect): paneCommands(x0: rect.x, y0: rect.y, x1: rect.maxX, y1: rect.maxY, radius: radius)
        }
    }

    private static func paneCommands(x0: Double, y0: Double, x1: Double, y1: Double, radius r: Double) -> [LayoutGlyphCommand] {
        [
            .move(x: x0 + r, y: y0), .line(x: x1 - r, y: y0),
            .arc(radius: r, x: x1, y: y0 + r), .line(x: x1, y: y1 - r),
            .arc(radius: r, x: x1 - r, y: y1), .line(x: x0 + r, y: y1),
            .arc(radius: r, x: x0, y: y1 - r), .line(x: x0, y: y0 + r),
            .arc(radius: r, x: x0 + r, y: y0), .close,
        ]
    }

    private static func number(_ value: Double) -> String {
        var text = String(format: "%.4f", value)
        while text.contains("."), text.hasSuffix("0") || text.hasSuffix(".") { text.removeLast() }
        return text == "-0" ? "0" : text
    }

    private static func svg(_ commands: [LayoutGlyphCommand]) -> String {
        var result = ""
        var current = (x: 0.0, y: 0.0)
        for command in commands {
            switch command {
            case let .move(x, y):
                result += "M\(number(x)) \(number(y))"
                current = (x, y)
            case let .line(x, y):
                if y == current.y { result += "H\(number(x))" }
                else if x == current.x { result += "V\(number(y))" }
                else { result += "L\(number(x)) \(number(y))" }
                current = (x, y)
            case let .arc(radius, x, y):
                result += "A\(number(radius)) \(number(radius)) 0 0 1 \(number(x)) \(number(y))"
                current = (x, y)
            case .close:
                result += "Z"
            }
        }
        return result
    }

    // MARK: - Drawing

    /// The stroke width at a canvas size and display scale: the reference width
    /// scaled with the canvas, never under one device pixel.
    public static func strokeWidth(canvasSize: Double, weight: LayoutGlyphWeight, displayScale: Double) -> Double {
        max(weight.strokeAtReferenceSize * canvasSize / canvasUnits, 1 / displayScale)
    }

    /// The icon scaled to `canvasSize` points, ready to stroke with round caps
    /// and round joins.
    ///
    /// At 1x below 20 points, straight edges move to pixel centres for an odd
    /// stroke width in pixels and to pixel edges for an even one. Curves keep
    /// their shape. Pane numbers are included only when `numbered` is true.
    public func drawing(
        canvasSize: Double,
        weight: LayoutGlyphWeight,
        displayScale: Double = 2,
        numbered: Bool = false
    ) -> LayoutGlyphDrawing {
        let scale = canvasSize / Self.canvasUnits
        let stroke = Self.strokeWidth(canvasSize: canvasSize, weight: weight, displayScale: displayScale)
        let snaps = displayScale == 1 && canvasSize < 20
        let phase = Double(Int((stroke * displayScale).rounded(.toNearestOrAwayFromZero)) % 2) / 2
        // Round half up, as the reference renderer does.
        func place(_ value: Double) -> Double {
            guard snaps else { return value * scale }
            return ((value * scale * displayScale - phase + 0.5).rounded(.down) + phase) / displayScale
        }
        let radius = Self.paneRadius * scale
        let paths: [[LayoutGlyphCommand]] = parts.map { part in
            switch part {
            case let .pane(rect):
                let x0 = place(rect.x), y0 = place(rect.y), x1 = place(rect.maxX), y1 = place(rect.maxY)
                let r = min(radius, (x1 - x0) / 2, (y1 - y0) / 2)
                return Self.paneCommands(x0: x0, y0: y0, x1: x1, y1: y1, radius: r)
            case let .path(commands):
                return commands.map { command in
                    switch command {
                    case let .move(x, y): .move(x: place(x), y: place(y))
                    case let .line(x, y): .line(x: place(x), y: place(y))
                    case let .arc(r, x, y): .arc(radius: r * scale, x: place(x), y: place(y))
                    case .close: .close
                    }
                }
            }
        }
        let numbers = numbered ? self.numbers.map {
            LayoutGlyphNumber(text: $0.text, centerX: place($0.centerX), centerY: place($0.centerY), fontSize: max($0.fontSize * scale, Self.minimumNumberFontSize))
        } : []
        return LayoutGlyphDrawing(canvasSize: canvasSize, strokeWidth: stroke, paths: paths, numbers: numbers)
    }
}
