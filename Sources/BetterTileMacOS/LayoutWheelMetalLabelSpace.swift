import AppKit
import BetterTileCore

// The panel/preview constructors and their SwiftUI measurement stay unchanged.
// Only the Metal presenter uses this resource-backed measurement boundary.
extension LayoutWheelLabelSpace {
    init?(metal content: LayoutWheelLiquidContent) {
        let layout = content.layout
        let symbol = content.iconSymbolSize(ringIndex: 0)
        var boxes: [CGRect] = []
        for (index, slot) in content.rings[0].slots.enumerated() {
            let size: CGSize
            if slot.glyph != nil || slot.windowAction.flatMap({ WindowActionPartitionGlyph.actions[$0] }) != nil
                || slot.symbolName == "rectangle.split.3x2" {
                // These original geometry-only branches never invoke SwiftUI.
                size = Self.iconSize(slot, frame: 35 / 18 * symbol, symbol: symbol)
            } else {
                guard let measured = GlyphMaskStore.symbolInkSize(slot.symbolName, pointSize: symbol) else { return nil }
                size = measured
            }
            let angle = layout.slotAngle(index)
            let x = cos(angle) * layout.iconRadii[0], y = sin(angle) * layout.iconRadii[0]
            boxes.append(CGRect(x: x - size.width * 1.08 / 2, y: y - size.height * 1.08 / 2,
                                width: size.width * 1.08, height: size.height * 1.08))
        }
        self.init(scale: layout.scale, wellRadius: layout.wellRadius, style: content.configuration.style,
                  levelCount: content.levelCount, iconBoxes: boxes)
        drawsTagPlate = false
    }
}
