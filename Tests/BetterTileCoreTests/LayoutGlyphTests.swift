import Foundation
import Testing
@testable import BetterTileCore

/// The reference paths pin the layout and mode icon geometry.
struct LayoutGlyphTests {
    static let reference: [String: [String]] = [
        "bt.layout.single": [
            "M3.5 4.25H20.5A1.75 1.75 0 0 1 22.25 6V18A1.75 1.75 0 0 1 20.5 19.75H3.5A1.75 1.75 0 0 1 1.75 18V6A1.75 1.75 0 0 1 3.5 4.25Z",
        ],
        "bt.layout.columns": [
            "M3.5 4.25H8.5A1.75 1.75 0 0 1 10.25 6V18A1.75 1.75 0 0 1 8.5 19.75H3.5A1.75 1.75 0 0 1 1.75 18V6A1.75 1.75 0 0 1 3.5 4.25Z",
            "M15.5 4.25H20.5A1.75 1.75 0 0 1 22.25 6V18A1.75 1.75 0 0 1 20.5 19.75H15.5A1.75 1.75 0 0 1 13.75 18V6A1.75 1.75 0 0 1 15.5 4.25Z",
        ],
        "bt.layout.rows": [
            "M3.5 4.25H20.5A1.75 1.75 0 0 1 22.25 6V8.5A1.75 1.75 0 0 1 20.5 10.25H3.5A1.75 1.75 0 0 1 1.75 8.5V6A1.75 1.75 0 0 1 3.5 4.25Z",
            "M3.5 13.75H20.5A1.75 1.75 0 0 1 22.25 15.5V18A1.75 1.75 0 0 1 20.5 19.75H3.5A1.75 1.75 0 0 1 1.75 18V15.5A1.75 1.75 0 0 1 3.5 13.75Z",
        ],
        "bt.layout.focus": [
            "M3.5 4.25H10.25A1.75 1.75 0 0 1 12 6V18A1.75 1.75 0 0 1 10.25 19.75H3.5A1.75 1.75 0 0 1 1.75 18V6A1.75 1.75 0 0 1 3.5 4.25Z",
            "M17.25 4.25H20.5A1.75 1.75 0 0 1 22.25 6V8.5A1.75 1.75 0 0 1 20.5 10.25H17.25A1.75 1.75 0 0 1 15.5 8.5V6A1.75 1.75 0 0 1 17.25 4.25Z",
            "M17.25 13.75H20.5A1.75 1.75 0 0 1 22.25 15.5V18A1.75 1.75 0 0 1 20.5 19.75H17.25A1.75 1.75 0 0 1 15.5 18V15.5A1.75 1.75 0 0 1 17.25 13.75Z",
        ],
        "bt.layout.grid": [
            "M3.5 4.25H8.5A1.75 1.75 0 0 1 10.25 6V8.5A1.75 1.75 0 0 1 8.5 10.25H3.5A1.75 1.75 0 0 1 1.75 8.5V6A1.75 1.75 0 0 1 3.5 4.25Z",
            "M15.5 4.25H20.5A1.75 1.75 0 0 1 22.25 6V8.5A1.75 1.75 0 0 1 20.5 10.25H15.5A1.75 1.75 0 0 1 13.75 8.5V6A1.75 1.75 0 0 1 15.5 4.25Z",
            "M3.5 13.75H8.5A1.75 1.75 0 0 1 10.25 15.5V18A1.75 1.75 0 0 1 8.5 19.75H3.5A1.75 1.75 0 0 1 1.75 18V15.5A1.75 1.75 0 0 1 3.5 13.75Z",
            "M15.5 13.75H20.5A1.75 1.75 0 0 1 22.25 15.5V18A1.75 1.75 0 0 1 20.5 19.75H15.5A1.75 1.75 0 0 1 13.75 18V15.5A1.75 1.75 0 0 1 15.5 13.75Z",
        ],
        "bt.mode.manual": [
            "M5.25 13.75H3.5A1.75 1.75 0 0 1 1.75 12V5A1.75 1.75 0 0 1 3.5 3.25H13.5A1.75 1.75 0 0 1 15.25 5V6.75",
            "M10.5 10.25H20.5A1.75 1.75 0 0 1 22.25 12V19A1.75 1.75 0 0 1 20.5 20.75H10.5A1.75 1.75 0 0 1 8.75 19V12A1.75 1.75 0 0 1 10.5 10.25Z",
        ],
        "bt.mode.adaptive": [
            "M3.5 4.25H11.25A1.75 1.75 0 0 1 13 6V13A1.75 1.75 0 0 1 11.25 14.75H3.5A1.75 1.75 0 0 1 1.75 13V6A1.75 1.75 0 0 1 3.5 4.25Z",
            "M18.25 4.25H20.5A1.75 1.75 0 0 1 22.25 6V13A1.75 1.75 0 0 1 20.5 14.75H18.25A1.75 1.75 0 0 1 16.5 13V6A1.75 1.75 0 0 1 18.25 4.25Z",
            "M5.25 19.75H18.75",
            "M7.25 17.75L5.25 19.75L7.25 21.75",
            "M16.75 17.75L18.75 19.75L16.75 21.75",
        ],
        "bt.mode.tabbed": [
            "M3.5 4.25H20.5A1.75 1.75 0 0 1 22.25 6V18A1.75 1.75 0 0 1 20.5 19.75H3.5A1.75 1.75 0 0 1 1.75 18V6A1.75 1.75 0 0 1 3.5 4.25Z",
            "M9.25 4.25V8.5H22.25",
            "M15.75 4.25V8.5",
        ],
        "bt.layouts": [
            "M5.25 4.25H18.75",
            "M3.5 7.75H11.25A1.75 1.75 0 0 1 13 9.5V18A1.75 1.75 0 0 1 11.25 19.75H3.5A1.75 1.75 0 0 1 1.75 18V9.5A1.75 1.75 0 0 1 3.5 7.75Z",
            "M18.25 7.75H20.5A1.75 1.75 0 0 1 22.25 9.5V18A1.75 1.75 0 0 1 20.5 19.75H18.25A1.75 1.75 0 0 1 16.5 18V9.5A1.75 1.75 0 0 1 18.25 7.75Z",
        ],
    ]

    static let numberedCentres: [String: [(Double, Double)]] = [
        "bt.layout.single": [(12, 12)],
        "bt.layout.columns": [(6, 12), (18, 12)],
        "bt.layout.rows": [(12, 7.25), (12, 16.75)],
        "bt.layout.focus": [(6.875, 12), (18.875, 7.25), (18.875, 16.75)],
        "bt.layout.grid": [(6, 7.25), (18, 7.25), (6, 16.75), (18, 16.75)],
    ]

    // MARK: - Helpers

    /// Centre-line corner and end points. Arcs stay inside the box their end points and corners span.
    private func points(of glyph: LayoutGlyph) -> [(Double, Double)] {
        glyph.parts.flatMap { part -> [(Double, Double)] in
            switch part {
            case let .pane(rect):
                return [(rect.x, rect.y), (rect.maxX, rect.maxY)]
            case let .path(commands):
                return commands.compactMap { command in
                    switch command {
                    case let .move(x, y), let .line(x, y), let .arc(_, x, y): (x, y)
                    case .close: nil
                    }
                }
            }
        }
    }

    private func inkBounds(of glyph: LayoutGlyph, weight: LayoutGlyphWeight) -> (minX: Double, minY: Double, maxX: Double, maxY: Double) {
        let half = weight.strokeAtReferenceSize / 2
        let all = points(of: glyph)
        return (all.map(\.0).min()! - half, all.map(\.1).min()! - half, all.map(\.0).max()! + half, all.map(\.1).max()! + half)
    }

    /// Dense samples along a part's centre line. A pane outline is sampled as its rectangle, which can
    /// only sit closer to a neighbour than the rounded outline does.
    private func samples(of part: LayoutGlyphPart) -> [(Double, Double)] {
        var line: [(Double, Double)] = []
        switch part {
        case let .pane(rect):
            line = [(rect.x, rect.y), (rect.maxX, rect.y), (rect.maxX, rect.maxY), (rect.x, rect.maxY), (rect.x, rect.y)]
        case let .path(commands):
            for command in commands {
                switch command {
                case let .move(x, y), let .line(x, y), let .arc(_, x, y): line.append((x, y))
                case .close: break
                }
            }
        }
        var result: [(Double, Double)] = []
        for (a, b) in zip(line, line.dropFirst()) {
            let length = hypot(b.0 - a.0, b.1 - a.1)
            let steps = max(1, Int(length / 0.05))
            for step in 0 ... steps {
                let t = Double(step) / Double(steps)
                result.append((a.0 + (b.0 - a.0) * t, a.1 + (b.1 - a.1) * t))
            }
        }
        return result
    }

    /// Parts that are drawn as one connected mark share a group.
    private func groups(of glyph: LayoutGlyph) -> [Int] {
        switch glyph {
        case .mode(.tabbed): [0, 0, 0]
        case .mode(.bento): [0, 1, 2, 2, 2]
        default: Array(glyph.parts.indices)
        }
    }

    private func minimumDistanceBetweenGroups(of glyph: LayoutGlyph) -> Double {
        let ids = groups(of: glyph)
        let sets = glyph.parts.map(samples)
        var minimum = Double.infinity
        for first in sets.indices {
            for second in sets.indices where second > first && ids[first] != ids[second] {
                for a in sets[first] {
                    for b in sets[second] { minimum = min(minimum, hypot(a.0 - b.0, a.1 - b.1)) }
                }
            }
        }
        return minimum
    }

    // MARK: - Geometry

    @Test func geometryMatchesTheESVGsExactly() {
        #expect(LayoutGlyph.all.count == 9)
        for glyph in LayoutGlyph.all {
            let expected = Self.reference[glyph.fileName]
            #expect(expected != nil, "\(glyph.fileName) has no reference")
            #expect(glyph.svgPathData == expected, "\(glyph.fileName) differs from the E SVG")
        }
    }

    @Test func paneNumbersSitAtTheCentreOfEachPane() {
        for preset in TabbedPreset.allCases {
            let glyph = LayoutGlyph.layout(preset)
            let expected = Self.numberedCentres[glyph.fileName]!
            #expect(glyph.numbers.count == preset.paneCount)
            for (number, centre) in zip(glyph.numbers, expected) {
                #expect(number.centerX == centre.0 && number.centerY == centre.1)
            }
            #expect(glyph.numbers.map(\.text) == (1 ... preset.paneCount).map(String.init))
        }
        // Tall panes: 5 units on a 24 canvas are 10.83 points at 52 points. Short panes: 3.8 units are
        // 8.23 points, which the 9 point text floor raises to 9.
        let focus = LayoutGlyph.layout(.focus).drawing(canvasSize: 52, weight: .regular, displayScale: 2, numbered: true)
        #expect(abs(focus.numbers[0].fontSize - 10.8333) < 0.001)
        #expect(focus.numbers[1].fontSize == 9 && focus.numbers[2].fontSize == 9)
        for preset in TabbedPreset.allCases {
            let drawing = LayoutGlyph.layout(preset).drawing(canvasSize: 52, weight: .regular, displayScale: 2, numbered: true)
            for (number, rect) in zip(drawing.numbers, LayoutGlyph.paneRects(of: preset)) {
                #expect(number.fontSize >= 9)
                #expect(rect.height <= 6 ? number.fontSize == 9 : abs(number.fontSize - 10.8333) < 0.001)
            }
        }
    }

    @Test func onlyTheFiveLayoutsCarryNumbers() {
        for glyph in LayoutGlyph.all {
            if case .layout = glyph { continue }
            #expect(glyph.numbers.isEmpty, "\(glyph.title)")
        }
        for preset in TabbedPreset.allCases {
            let plain = LayoutGlyph.layout(preset).drawing(canvasSize: 52, weight: .regular, displayScale: 2)
            #expect(plain.numbers.isEmpty)
        }
    }

    @Test func inkStaysInsideTheCanvasAtBothWeights() {
        for glyph in LayoutGlyph.all {
            for weight in LayoutGlyphWeight.allCases {
                let ink = inkBounds(of: glyph, weight: weight)
                #expect(ink.minX >= 0 && ink.minY >= 0, "\(glyph.title)")
                #expect(ink.maxX <= LayoutGlyph.canvasUnits && ink.maxY <= LayoutGlyph.canvasUnits, "\(glyph.title)")
            }
        }
    }

    @Test func layoutInkFitsTheTwentyTwoBySeventeenBox() {
        for preset in TabbedPreset.allCases {
            let ink = inkBounds(of: .layout(preset), weight: .regular)
            #expect(ink.minX >= 1 && ink.maxX <= 23)
            #expect(ink.minY >= 3.5 && ink.maxY <= 20.5)
        }
        let single = inkBounds(of: .layout(.single), weight: .regular)
        #expect(single.maxX - single.minX == 22 && single.maxY - single.minY == 17)
        // The canvas is centred on the icon point. Ink mass does not move it.
        #expect((single.minX + single.maxX) / 2 == 12 && (single.minY + single.maxY) / 2 == 12)
    }

    @Test func mainPlusTwoUsesTheTabbedProportions() throws {
        let state = TabbedLayoutState(preset: .focus)
        let frames = state.frames(in: BTRect(x: 0, y: 0, width: 1000, height: 1000))
        let widths = try state.panes.map { try #require(frames[$0.id]).size.width }
        let tabbedMain = widths[0] / (widths[0] + widths[1])
        let rects = LayoutGlyph.paneRects(of: .focus)
        let glyphMain = rects[0].width / (rects[0].width + rects[1].width)
        #expect(abs(tabbedMain - glyphMain) < 0.01, "glyph \(glyphMain), layout \(tabbedMain)")
        #expect(abs(glyphMain - 0.6) < 0.01)
    }

    @Test func everyPresetAndEveryAvailableModeHasAnIcon() {
        for preset in TabbedPreset.allCases {
            let glyph = LayoutGlyph.layout(preset)
            #expect(!glyph.parts.isEmpty && LayoutGlyph.all.contains(glyph))
            #expect(glyph.title == preset.title)
        }
        for mode in LayoutMode.availableModes {
            let glyph = LayoutGlyph.mode(mode)
            #expect(!glyph.parts.isEmpty && LayoutGlyph.all.contains(glyph.canonical))
            #expect(glyph.title == mode.title)
        }
        // Linked mode is not in the product. It reads as Manual.
        #expect(LayoutGlyph.mode(.linked).canonical == .mode(.manual))
        #expect(LayoutGlyph.mode(.linked).svgPathData == LayoutGlyph.mode(.manual).svgPathData)
    }

    @Test func noTwoIconsShareAPathSet() {
        let sets = LayoutGlyph.all.map { Set($0.svgPathData) }
        for first in sets.indices {
            for second in sets.indices where second > first { #expect(sets[first] != sets[second]) }
        }
        #expect(Set(LayoutGlyph.all.map(\.fileName)).count == LayoutGlyph.all.count)
    }

    @Test func separatePartsKeepTheSharedClearance() {
        for glyph in LayoutGlyph.all {
            let distance = minimumDistanceBetweenGroups(of: glyph)
            if glyph == .mode(.bento) {
                // The arrowhead tips stand 3 units below the panes.
                #expect(abs(distance - 3) < 0.001, "\(glyph.title) \(distance)")
            } else if glyph == .mode(.tabbed) || glyph == .layout(.single) {
                #expect(distance == .infinity, "\(glyph.title) is one connected mark")
            } else {
                #expect(abs(distance - LayoutGlyph.separation) < 0.001, "\(glyph.title) \(distance)")
            }
        }
        // 3.5 between centre lines leaves 2 clear at Regular and 1.5 at Semibold.
        #expect(LayoutGlyph.separation - LayoutGlyphWeight.regular.strokeAtReferenceSize == 2)
        #expect(LayoutGlyph.separation - LayoutGlyphWeight.semibold.strokeAtReferenceSize == 1.5)
    }

    @Test func everyPaneUsesOneRadius() {
        #expect(LayoutGlyph.paneRadius == 1.75)
        for glyph in LayoutGlyph.all {
            for path in glyph.drawing(canvasSize: 24, weight: .regular, displayScale: 2).paths {
                for case let .arc(radius, _, _) in path { #expect(radius == 1.75, "\(glyph.title)") }
            }
        }
    }

    // MARK: - Drawing

    @Test func strokeFollowsTheWeightAndNeverFallsUnderOneDevicePixel() {
        #expect(LayoutGlyph.strokeWidth(canvasSize: 24, weight: .regular, displayScale: 2) == 1.5)
        #expect(LayoutGlyph.strokeWidth(canvasSize: 24, weight: .semibold, displayScale: 2) == 2)
        #expect(abs(LayoutGlyph.strokeWidth(canvasSize: 52, weight: .regular, displayScale: 2) - 3.25) < 1e-9)
        for glyph in LayoutGlyph.all {
            for size in [13.0, 16.4, 17.7, 20.2, 22.8, 24, 30.4, 52, 66] {
                for scale in [1.0, 2, 3] {
                    for weight in LayoutGlyphWeight.allCases {
                        let drawing = glyph.drawing(canvasSize: size, weight: weight, displayScale: scale)
                        let expected = max(weight.strokeAtReferenceSize * size / 24, 1 / scale)
                        #expect(drawing.strokeWidth == expected)
                        #expect(drawing.strokeWidth >= 1 / scale)
                    }
                }
            }
        }
        // 13 points at 1x: 0.8125 points is raised to one pixel. At 2x it stays 0.8125.
        #expect(LayoutGlyph.strokeWidth(canvasSize: 13, weight: .regular, displayScale: 1) == 1)
        #expect(LayoutGlyph.strokeWidth(canvasSize: 13, weight: .regular, displayScale: 2) == 0.8125)
    }

    @Test func straightEdgesSnapToPixelCentresBelowTwentyPointsAtOneX() throws {
        let drawing = LayoutGlyph.layout(.single).drawing(canvasSize: 13, weight: .regular, displayScale: 1)
        var xs: [Double] = [], ys: [Double] = []
        for command in drawing.paths[0] {
            switch command {
            case let .move(x, y), let .line(x, y), let .arc(_, x, y): xs.append(x); ys.append(y)
            case .close: break
            }
        }
        // A one-pixel stroke is centred on a pixel centre, so its edges are whole pixels.
        for edge in [xs.min()!, xs.max()!, ys.min()!, ys.max()!] { #expect(edge - edge.rounded(.down) == 0.5) }

        // From 20 points, and on Retina, the drawing keeps its exact scaled positions.
        let large = LayoutGlyph.layout(.single).drawing(canvasSize: 22.8, weight: .regular, displayScale: 1)
        let retina = LayoutGlyph.layout(.single).drawing(canvasSize: 13, weight: .regular, displayScale: 2)
        guard case let .move(_, largeTop) = large.paths[0][0], case let .move(_, retinaTop) = retina.paths[0][0] else {
            Issue.record("A pane starts with a move"); return
        }
        #expect(abs(largeTop - 4.25 * 22.8 / 24) < 1e-9)
        #expect(abs(retinaTop - 4.25 * 13 / 24) < 1e-9)
    }

    @Test func snappedRetinaSizeStaysInsideItsCanvas() {
        for glyph in LayoutGlyph.all {
            let drawing = glyph.drawing(canvasSize: 13, weight: .regular, displayScale: 1)
            for path in drawing.paths {
                for command in path {
                    switch command {
                    case let .move(x, y), let .line(x, y), let .arc(_, x, y):
                        #expect(x >= 0 && x <= 13 && y >= 0 && y <= 13, "\(glyph.title)")
                    case .close: break
                    }
                }
            }
        }
    }

    @Test func canvasIsOnePointTwoSixFiveTimesTheSymbol() {
        #expect(abs(LayoutGlyph.canvasSize(besideSymbolSize: 18) - 22.77) < 1e-9)
        #expect(abs(LayoutGlyph.canvasSize(besideSymbolSize: 13) - 16.445) < 1e-9)
        #expect(abs(LayoutGlyph.canvasSize(besideSymbolSize: 14) - 17.71) < 1e-9)
    }

}
