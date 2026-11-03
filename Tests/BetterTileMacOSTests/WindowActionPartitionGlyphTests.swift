import AppKit
import SwiftUI
import Testing
@testable import BetterTileCore
@testable import BetterTileMacOS

@MainActor @Suite(.macOSTestApplication, .serialized) struct WindowActionPartitionGlyphTests {
    @Test func cellsAndFlushTargetShareTheSameBoundaries() {
        #expect(WindowActionPartitionGlyph.actions.count == 11)
        for glyph in WindowActionPartitionGlyph.actions.values {
            for size: CGFloat in [13, 16, 18, 24] {
                for weight in [LayoutGlyphWeight.regular, .semibold] {
                    for scale: CGFloat in [1, 2] {
                        let drawing = glyph.drawing(pointSize: size, weight: weight, displayScale: scale)
                        #expect(drawing.cells.count == 3 * glyph.rows)
                        let first = drawing.cells[glyph.row * 3 + glyph.firstColumn]
                        let last = drawing.cells[glyph.row * 3 + glyph.firstColumn + glyph.columnCount - 1]
                        #expect(drawing.target == first.union(last))
                        #expect(drawing.frame.contains(drawing.target))
                        #expect(drawing.verticalDividers.count == (glyph.columnCount == 2 ? 1 : 2))
                        #expect(drawing.rowEdges.count == glyph.rows + 1)
                        if scale == 1 {
                            let widths = (0 ..< 3).map { drawing.columns[$0 + 1] - drawing.columns[$0] }
                            #expect(widths.max()! - widths.min()! <= 1)
                        }
                    }
                }
            }
        }
    }

    @Test func templateCacheIncludesActionSizeAndWeight() throws {
        let left = try #require(WindowActionPartitionGlyph.actions[.leftThird])
        let image = left.templateImage(pointSize: 16, weight: .regular)
        #expect(image.isTemplate)
        #expect(image === left.templateImage(pointSize: 16, weight: .regular))
        #expect(image !== left.templateImage(pointSize: 24, weight: .regular))
        #expect(image !== left.templateImage(pointSize: 16, weight: .semibold))
        let right = try #require(WindowActionPartitionGlyph.actions[.rightThird])
        #expect(image !== right.templateImage(pointSize: 16, weight: .regular))
    }

    @Test func exactlyOneRegionIsFilledAndNeighbourDividersRemainVisible() throws {
        for (action, glyph) in WindowActionPartitionGlyph.actions {
            for size: CGFloat in [13, 16, 18, 24] {
                for weight in [LayoutGlyphWeight.regular, .semibold] {
                    for scale: CGFloat in [1, 2] {
                        let drawing = glyph.drawing(pointSize: size, weight: weight, displayScale: scale)
                        let canvas = WindowActionPartitionGlyph.canvasSize(pointSize: size, weight: weight)
                        let context = try #require(CGContext(data: nil, width: Int(canvas.width * scale), height: Int(canvas.height * scale),
                            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                        context.scaleBy(x: scale, y: scale)
                        drawing.draw(in: context)
                        let bitmap = NSBitmapImageRep(cgImage: try #require(context.makeImage()))
                        func alpha(_ point: CGPoint) -> CGFloat {
                            bitmap.colorAt(x: Int(point.x * scale), y: bitmap.pixelsHigh - 1 - Int(point.y * scale))!.alphaComponent
                        }
                        for cell in drawing.cells {
                            let midpoint = CGPoint(x: cell.midX, y: cell.midY)
                            let selected = drawing.target.contains(midpoint)
                            #expect(selected ? alpha(midpoint) > 0.99 : alpha(midpoint) < 0.01,
                                    "\(action), \(size), \(weight), \(scale)x, \(cell)")
                        }
                        for x in drawing.verticalDividers {
                            #expect(alpha(CGPoint(x: x, y: drawing.frame.midY)) > 0.5)
                        }
                    }
                }
            }
        }
    }

}
