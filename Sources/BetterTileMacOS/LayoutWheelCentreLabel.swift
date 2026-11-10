import AppKit
import BetterTileCore
import SwiftUI

/// Measured presentation only. It neither chooses a command nor changes input geometry.
@MainActor struct LayoutWheelCentreLabel: Equatable {
    struct Line: Equatable {
        let text: String
        let fontSize: Double
        let height: Double
        let secondary: Bool
        let width: Double
        var font: NSFont { .systemFont(ofSize: fontSize, weight: secondary ? .medium : .semibold) }
    }
    enum Placement: Equatable { case well, tag, truncated }
    let lines: [Line]
    let placement: Placement
    let usedShortName: Bool
    var usesTag: Bool { placement != .well }
    var width: Double { lines.map(\.width).max() ?? 0 }
    var height: Double { lines.reduce(0) { $0 + $1.height } }

    static func measured(_ text: String, size: Double, height: Double, secondary: Bool = false) -> Line {
        let font = NSFont.systemFont(ofSize: size, weight: secondary ? .medium : .semibold)
        return Line(text: text, fontSize: size, height: height, secondary: secondary,
                    width: (text as NSString).size(withAttributes: [.font: font]).width)
    }

    /// A word boundary with the smallest widest line. Ties keep reading order.
    static func balanced(_ text: String, size: Double, height: Double) -> [Line]? {
        let words = text.split(separator: " ").map(String.init)
        guard words.count > 1 else { return nil }
        return (1..<words.count).map { index in
            [measured(words[..<index].joined(separator: " "), size: size, height: height),
             measured(words[index...].joined(separator: " "), size: size, height: height)]
        }.min { ($0.map(\.width).max() ?? 0) < ($1.map(\.width).max() ?? 0) }
    }

    /// Three lines have narrower outer chords than their middle chord. Choose
    /// the most balanced word-boundary split among those that fit the well.
    static func balancedThree(_ text: String, size: Double, height: Double,
                              space: LayoutWheelLabelSpace) -> [Line]? {
        let words = text.split(separator: " ").map(String.init)
        guard words.count >= 3 else { return nil }
        var candidates: [[Line]] = []
        for first in 1..<(words.count - 1) {
            for second in (first + 1)..<words.count {
                let lines = [measured(words[..<first].joined(separator: " "), size: size, height: height),
                    measured(words[first..<second].joined(separator: " "), size: size, height: height),
                    measured(words[second...].joined(separator: " "), size: size, height: height)]
                if space.fits(lines, in: .well) { candidates.append(lines) }
            }
        }
        return candidates.min {
            let a = $0.map(\.width), b = $1.map(\.width)
            let widestA = a.max() ?? 0, widestB = b.max() ?? 0
            if widestA != widestB { return widestA < widestB }
            return widestA - (a.min() ?? 0) < widestB - (b.min() ?? 0)
        }
    }

    init(name: String, mainAction: String? = nil, space: LayoutWheelLabelSpace) {
        let s = space.scale
        let steps = [(max(10, 11 * s), max(12, 13 * s)),
                     (max(9, 10 * s), max(11, 12 * s))]
        func variants(_ name: String, step: (Double, Double)) -> [[Line]] {
            let first = Self.measured(name, size: step.0, height: step.1)
            if let mainAction {
                return [[first, Self.measured(mainAction, size: max(9, 9.5 * s),
                    height: max(11, 11.5 * s), secondary: true)]]
            }
            return [[first]] + (Self.balanced(name, size: step.0, height: step.1).map { [$0] } ?? [])
        }
        func fit(_ name: String, short: Bool) -> Self? {
            for placement in [Placement.well, .tag] {
                for (index, step) in steps.enumerated() {
                    for lines in variants(name, step: step) where space.fits(lines, in: placement) {
                        return Self(lines: lines, placement: placement, usedShortName: short)
                    }
                    if placement == .well, index == 0, !short, mainAction == nil,
                       let lines = Self.balancedThree(name, size: step.0, height: step.1, space: space) {
                        return Self(lines: lines, placement: .well, usedShortName: false)
                    }
                }
            }
            return nil
        }
        if let full = fit(name, short: false) { self = full }
        else if mainAction == nil, let short = space.shortName(for: name), let fitted = fit(short, short: true) {
            self = fitted
        } else {
            // A future command can still render safely. Catalog tests reject this path.
            let height = steps[1].1
            let limit = space.tagWidthLimit(height: height + 2 * space.verticalPadding) - 2 * space.horizontalPadding
            var prefix = name
            while !prefix.isEmpty && Self.measured(prefix + "…", size: steps[1].0, height: height).width > limit {
                prefix.removeLast()
            }
            self.init(lines: [Self.measured(prefix + "…", size: steps[1].0, height: height)],
                      placement: .truncated, usedShortName: false)
        }
    }

    private init(lines: [Line], placement: Placement, usedShortName: Bool) {
        self.lines = lines; self.placement = placement; self.usedShortName = usedShortName
    }
}

/// Space is independent of availability and the cosmetic spring, so dimming or
/// opening a fan never reflows the current name.
@MainActor struct LayoutWheelLabelSpace {
    let scale: Double
    let wellRadius: Double
    let style: LayoutWheelStyle
    let levelCount: LayoutWheelLevelCount
    let iconBoxes: [CGRect]
    struct Lens {
        let center: CGPoint
        /// Includes the outside half of the drawn outline.
        let radius: Double
    }
    let lenses: [Lens]
    /// The liquid wheel draws a tag's lines without a plate, so they need no padding.
    var drawsTagPlate = true
    var horizontalPadding: Double { drawsTagPlate ? 4 * scale : 0 }
    var verticalPadding: Double { drawsTagPlate ? 3 * scale : 0 }
    var markSize: Double { max(9, 10 * scale) }
    var markFrame: CGRect {
        CGRect(x: -markSize / 2, y: -wellRadius + scale, width: markSize, height: markSize)
    }

    init(_ input: LayoutWheelSceneInput) {
        let drawn = LayoutWheelDrawnMetrics(input)
        scale = drawn.scale; wellRadius = drawn.wellRadius
        style = input.configuration.style; levelCount = input.configuration.effectiveLevelCount
        iconBoxes = LayoutWheelSector.allCases.map { sector in
            let selection = LayoutWheelSelection(ring: .inner, sector: sector)
            let slot = input.slot(.sector(selection))
            let size = Self.iconSize(slot, frame: drawn.iconFrameSize(.inner), symbol: drawn.symbolSize(.inner))
            let point = drawn.iconPoint(selection, symbol: slot.symbolName, hover: 1)
            return CGRect(x: point.x - size.width * 1.08 / 2, y: point.y - size.height * 1.08 / 2,
                          width: size.width * 1.08, height: size.height * 1.08)
        }
        lenses = LayoutWheelSector.allCases.map { sector in
            let selection = LayoutWheelSelection(ring: .inner, sector: sector)
            let point = drawn.iconPoint(selection)
            return Lens(center: CGPoint(x: point.x, y: point.y),
                        radius: drawn.lensRadius(selection, lean: .init(x: 0, y: 0)) + drawn.lensOutlineWidth / 2)
        }
    }

    /// The liquid wheel's innermost icons, with the same 8% allowance for the
    /// selection magnet as the native wheel. The liquid wheel has no lenses
    /// and no tag plate.
    init(liquid content: LayoutWheelLiquidContent) {
        let layout = content.layout
        let symbol = content.iconSymbolSize(ringIndex: 0)
        let boxes = content.rings[0].slots.enumerated().map { index, slot in
            let size = Self.iconSize(slot, frame: 35 / 18 * symbol, symbol: symbol)
            let angle = layout.slotAngle(index)
            let x = cos(angle) * layout.iconRadii[0], y = sin(angle) * layout.iconRadii[0]
            return CGRect(x: x - size.width * 1.08 / 2, y: y - size.height * 1.08 / 2,
                          width: size.width * 1.08, height: size.height * 1.08)
        }
        self.init(scale: layout.scale, wellRadius: layout.wellRadius, style: content.configuration.style,
                  levelCount: content.levelCount, iconBoxes: boxes)
        drawsTagPlate = false
    }

    /// Explicit presentation fixtures can cover a future ring arrangement
    /// without changing the runtime's Core geometry.
    init(scale: Double, wellRadius: Double, style: LayoutWheelStyle,
         levelCount: LayoutWheelLevelCount, iconBoxes: [CGRect], lenses: [Lens] = []) {
        self.scale = scale; self.wellRadius = wellRadius; self.style = style
        self.levelCount = levelCount; self.iconBoxes = iconBoxes
        self.lenses = lenses
    }

    static func iconSize(_ slot: LayoutWheelSlot, frame: Double, symbol: Double) -> CGSize {
        if let glyph = slot.windowAction.flatMap({ WindowActionPartitionGlyph.actions[$0] }) {
            return glyph.drawing(pointSize: symbol, weight: .semibold, displayScale: 2).inkBounds.size
        }
        if let glyph = slot.glyph {
            let drawing = glyph.drawing(canvasSize: LayoutGlyph.canvasSize(besideSymbolSize: symbol),
                                        weight: .semibold, displayScale: 2)
            let box = drawing.cgPaths().reduce(CGRect.null) { $0.union($1.boundingBoxOfPath) }
                .insetBy(dx: -drawing.strokeWidth / 2, dy: -drawing.strokeWidth / 2)
            return box.size
        }
        switch slot.symbolName {
        case "rectangle.split.3x2":
            let rect = LayoutWheelGlyphLayout.outerRect(in: CGSize(width: frame, height: frame))
            return CGSize(width: (rect.width + 1.25) * 0.86, height: (rect.height + 1.25) * 0.86)
        default:
            return symbolInkSize(slot.symbolName, size: symbol)
        }
    }

    private struct SymbolKey: Hashable {
        let name: String
        let size: Double
    }
    private static var symbolInkSizes: [SymbolKey: CGSize] = [:]
    #if BETTERTILE_TEST_HOOKS
    /// Every request for a measured SF Symbol ink size, cached or not.
    static var symbolInkSizeCallsForTesting = 0
    /// Every SwiftUI `ImageRenderer` measurement this type performs.
    static var symbolInkRendersForTesting = 0
    #endif

    /// SF Symbol image frames include transparent margins. Measure their actual
    /// ink offscreen once per symbol and font size, using the same SwiftUI font.
    private static func symbolInkSize(_ name: String, size: Double) -> CGSize {
        #if BETTERTILE_TEST_HOOKS
        symbolInkSizeCallsForTesting += 1
        #endif
        let key = SymbolKey(name: name, size: size)
        if let cached = symbolInkSizes[key] { return cached }
        #if BETTERTILE_TEST_HOOKS
        symbolInkRendersForTesting += 1
        #endif
        let renderer = ImageRenderer(content: Image(systemName: name)
            .font(.system(size: size, weight: .semibold)).symbolRenderingMode(.monochrome)
            .foregroundStyle(.white).fixedSize().padding(4))
        renderer.scale = 4
        var result = CGSize(width: 35 / 18 * size, height: 35 / 18 * size)
        if let image = renderer.cgImage {
            let bitmap = NSBitmapImageRep(cgImage: image)
            var minX = bitmap.pixelsWide, minY = bitmap.pixelsHigh, maxX = -1, maxY = -1
            for y in 0..<bitmap.pixelsHigh {
                for x in 0..<bitmap.pixelsWide where (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0 {
                    minX = min(minX, x); maxX = max(maxX, x)
                    minY = min(minY, y); maxY = max(maxY, y)
                }
            }
            if maxX >= minX && maxY >= minY {
                result = CGSize(width: Double(maxX - minX + 1) / 4,
                                height: Double(maxY - minY + 1) / 4)
            }
        }
        symbolInkSizes[key] = result
        return result
    }

    func tagWidthLimit(height: Double) -> Double {
        let margin = 2 * scale
        return iconBoxes.reduce(Double.infinity) { limit, box in
            guard box.minY < height / 2 + margin, box.maxY > -height / 2 - margin else { return limit }
            return min(limit, 2 * max(0, max(box.minX, -box.maxX) - margin))
        }
    }

    func fits(_ lines: [LayoutWheelCentreLabel.Line], in placement: LayoutWheelCentreLabel.Placement) -> Bool {
        let height = lines.reduce(0) { $0 + $1.height }
        if placement == .well {
            // Reserve the same fixed unavailable mark for every name, even
            // when it is available. Availability must never change wrapping.
            guard -height / 2 - markFrame.maxY >= scale - 0.001 else { return false }
            var y = -height / 2
            for line in lines {
                let edge = max(abs(y), abs(y + line.height))
                let r = wellRadius - 2 * scale
                guard edge < r, line.width <= 2 * sqrt(r * r - edge * edge) else { return false }
                y += line.height
            }
            return true
        }
        guard (lines.map(\.width).max() ?? 0) + 2 * horizontalPadding
            <= tagWidthLimit(height: height + 2 * verticalPadding) else { return false }
        var y = -height / 2
        for line in lines {
            let text = CGRect(x: -line.width / 2, y: y, width: line.width, height: line.height)
            for lens in lenses {
                let dx = max(text.minX - lens.center.x, 0, lens.center.x - text.maxX)
                let dy = max(text.minY - lens.center.y, 0, lens.center.y - text.maxY)
                guard hypot(dx, dy) >= lens.radius + 2 * scale else { return false }
            }
            y += line.height
        }
        return true
    }

    func shortName(for name: String) -> String? {
        guard style == .custom else { return nil }
        let small = scale < 0.9
        switch name {
        case "Move Tab to Previous Pane" where levelCount == .two || small: return "To Prev. Pane"
        case "Move Tab to Next Pane" where levelCount == .two && scale <= 1: return "To Next Pane"
        case "Bottom Right Quarter" where levelCount == .two || small: return "Bottom Right ¼"
        case "Bottom Center Sixth" where levelCount == .two: return "Bottom Mid ⅙"
        case "Bottom Left Quarter" where levelCount == .two && small: return "Bottom Left ¼"
        case "Top Center Sixth" where levelCount == .two && small: return "Top Mid ⅙"
        case "Bottom Right Sixth" where levelCount == .two && small: return "Bottom Right ⅙"
        default: return nil
        }
    }
}

extension LayoutWheelSceneInput {
    @MainActor var centreLabel: LayoutWheelCentreLabel? {
        centreContent.map { LayoutWheelCentreLabel(name: $0.name, mainAction: $0.mainAction, space: .init(self)) }
    }

    var centreContent: (name: String, mainAction: String?, available: Bool)? {
        if let sector = fan.openSector, let index = fan.optionIndex {
            let slot = slot(.option(sector, index))
            return (slot.label, nil, slot.isAvailable)
        }
        guard let selection else { return nil }
        let slot = slot(.sector(selection))
        if configuration.style == .grouped && selection.ring == configuration.groupRing {
            let group = LayoutWheelGroup.at(selection.sector)
            let main = configuration.group(at: selection.sector).quickAction.map { LayoutWheelSlot(command: $0).label }
            return (group.title, main, slot.isAvailable)
        }
        return (slot.label, nil, slot.isAvailable)
    }
}
