import AppKit
import Testing
@testable import BetterTileCore
@testable import BetterTileMacOS

/// The liquid wheel draws its centre name as one image at the wheel centre.
/// That image must stay clear of the innermost ring's icons.
@MainActor @Suite(.macOSTestApplication, .serialized) struct LayoutWheelLiquidCentreLabelTests {
    /// Each innermost icon's ink at rest, in points from the wheel centre.
    private func innerIconBoxes(_ content: LayoutWheelLiquidContent) -> [CGRect] {
        let layout = content.layout
        let symbol = (content.rings.count == 2 ? 16 : 18) * layout.scale
        return content.rings[0].slots.enumerated().map { index, slot in
            let size = LayoutWheelLabelSpace.iconSize(slot, frame: 35 / 18 * symbol, symbol: symbol)
            let angle = layout.slotAngle(index)
            let x = cos(angle) * layout.iconRadii[0], y = sin(angle) * layout.iconRadii[0]
            return CGRect(x: x - size.width / 2, y: y - size.height / 2, width: size.width, height: size.height)
        }
    }

    private func names(_ content: LayoutWheelLiquidContent) -> [(name: String, detail: String?, available: Bool)] {
        if content.configuration.style == .grouped {
            return LayoutWheelSector.allCases.compactMap {
                content.centreName(.init(selection: .init(ring: content.configuration.groupRing, sector: $0)))
            }
        }
        return WindowAction.allCases.map { ($0.title, nil, true) }
    }

    @Test(arguments: [LayoutWheelStyle.custom, .grouped], [LayoutWheelSize.small, .medium, .large])
    func centreNamesStayClearOfTheInnerIcons(style: LayoutWheelStyle, size: LayoutWheelSize) throws {
        for levels in [LayoutWheelLevelCount.one, .two] {
            var configuration = LayoutWheelConfiguration(style: style, levelCount: levels)
            configuration.appearance.size = size
            // The widest inner icon, as in the native long-label tests.
            if style == .custom {
                configuration.innerSlots = Array(repeating: .windowAction(.bottomCenterSixth), count: 8)
            }
            let content = LayoutWheelLiquidContent(configuration: configuration, levelCount: levels)
            let boxes = innerIconBoxes(content)
            var images = LayoutWheelLiquidImages()
            let space = LayoutWheelLabelSpace(liquid: content)
            for name in names(content) {
                // Truncation is the last resort for a future command, not for the catalog.
                let fitted = LayoutWheelCentreLabel(name: name.name, mainAction: name.detail, space: space)
                #expect(fitted.placement != .truncated, "\(style) \(levels) \(size): \(name.name)")
                let drawn = images.label(name, content: content, color: .white, scale: 2)
                let image = try #require(drawn)
                // The image adds 2 pt of padding at each side and 1 pt above and below.
                let width = Double(image.width) / 2 - 4, height = Double(image.height) / 2 - 2
                let text = CGRect(x: -width / 2, y: -height / 2, width: width, height: height)
                for box in boxes {
                    #expect(!text.intersects(box),
                            "\(style) \(levels) \(size): \(name.name) \(text) covers an icon at \(box)")
                }
            }
        }
    }
}
