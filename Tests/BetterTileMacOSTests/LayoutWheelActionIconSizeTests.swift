import AppKit
import SwiftUI
import Testing
@testable import BetterTileCore
@testable import BetterTileMacOS

@MainActor @Suite(.macOSTestApplication, .serialized) struct LayoutWheelActionIconSizeTests {
    @Test func fittingUsesTheDrawnSizeOfEveryActionAtEveryWheelSize() throws {
        var records: [[String: Any]] = []
        for levels in [LayoutWheelLevelCount.one, .two] {
            for scale in [0.8, 1.0, 1.2] {
                let input = LayoutWheelSceneInput(configuration: .init(levelCount: levels, scale: scale))
                let metrics = LayoutWheelDrawnMetrics(input)
                let symbol = metrics.symbolSize(.inner), frame = metrics.iconFrameSize(.inner)
                for action in WindowAction.allCases {
                    let slot = LayoutWheelSlot(command: .windowAction(action))
                    let actual = LayoutWheelLabelSpace.iconSize(slot, frame: frame, symbol: symbol)
                    let expected: CGSize
                    if let glyph = WindowActionPartitionGlyph.actions[action] {
                        let drawing = glyph.drawing(pointSize: symbol, weight: .semibold, displayScale: 2)
                        expected = drawing.frame.insetBy(dx: -drawing.stroke / 2, dy: -drawing.stroke / 2).size
                    } else {
                        // Native actions use the same four-pixel-per-point ink
                        // measurement as the fitter, through the actual view.
                        let renderer = ImageRenderer(content: LayoutWheelIcon(slot: slot, tint: .white, fontSize: symbol)
                            .fixedSize().padding(4))
                        renderer.scale = 4
                        let bitmap = NSBitmapImageRep(cgImage: try #require(renderer.cgImage))
                        var bounds = CGRect.null
                        for y in 0 ..< bitmap.pixelsHigh {
                            for x in 0 ..< bitmap.pixelsWide where (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0 {
                                bounds = bounds.union(CGRect(x: x, y: y, width: 1, height: 1))
                            }
                        }
                        expected = CGSize(width: bounds.width / 4, height: bounds.height / 4)
                    }
                    #expect(actual == expected, "\(action), \(levels), \(scale): fitting \(actual), drawing \(expected)")
                    records.append(["action": action.title, "levels": levels.rawValue, "scale": scale,
                                    "width": expected.width, "height": expected.height])
                }
            }
        }
        if let path = ProcessInfo.processInfo.environment["BT_ACTION_ICON_SIZES"] {
            try JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted, .sortedKeys])
                .write(to: URL(filePath: path))
        }
    }

    @Test func catalogFitsInsideAnEnvelopeOfEveryAssignableAction() {
        let commands: [LayoutWheelCommand?] = WindowAction.allCases.map { .windowAction($0) }
            + LayoutMode.allCases.map { .setMode($0) }
            + TabbedPreset.allCases.map { .chooseLayout($0) } + [.repairBento, nil]
        for levels in [LayoutWheelLevelCount.one, .two] {
            for scale in [0.8, 1.0, 1.2] {
                let input = LayoutWheelSceneInput(configuration: .init(levelCount: levels, scale: scale))
                let drawn = LayoutWheelDrawnMetrics(input)
                let base = LayoutWheelLabelSpace(input)
                // A dense sixths ring is no longer the largest arrangement.
                // Cover every action's bounds and optical shift at each slot.
                let boxes = LayoutWheelSector.allCases.map { sector in
                    let selection = LayoutWheelSelection(ring: .inner, sector: sector)
                    return WindowAction.allCases.reduce(CGRect.null) { box, action in
                        let slot = LayoutWheelSlot(command: .windowAction(action))
                        let size = LayoutWheelLabelSpace.iconSize(slot, frame: drawn.iconFrameSize(.inner),
                                                                 symbol: drawn.symbolSize(.inner))
                        let point = drawn.iconPoint(selection, symbol: slot.symbolName, hover: 1)
                        return box.union(CGRect(x: point.x - size.width * 1.08 / 2,
                                                y: point.y - size.height * 1.08 / 2,
                                                width: size.width * 1.08, height: size.height * 1.08))
                    }
                }
                let space = LayoutWheelLabelSpace(scale: scale, wellRadius: base.wellRadius, style: .custom,
                    levelCount: levels, iconBoxes: boxes, lenses: base.lenses)
                for command in commands {
                    let name = LayoutWheelSlot(command: command).label
                    let label = LayoutWheelCentreLabel(name: name, space: space)
                    #expect(label.placement != .truncated, "\(name), \(levels), \(scale)")
                    #expect(space.fits(label.lines, in: label.placement))
                }
            }
        }
    }
}
