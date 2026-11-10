import AppKit
import Metal
import Testing
#if !BETTERTILE_TEST_HOOKS
#error("Tests require BETTERTILE_TEST_HOOKS. Use Tools/test.sh LOG --release for Release tests.")
#endif
@_spi(LiquidWheelPrototype) @testable import BetterTileCore
@_spi(LiquidWheelPrototype) @testable import BetterTileMacOS

/// The Metal wheel fits its centre label with the bundled SF Symbol ink sizes.
/// Only the SwiftUI wheels (the panel fallback and the Settings preview's
/// fallback) measure ink with `ImageRenderer`.
@MainActor @Suite(.macOSTestApplication, .serialized) struct LayoutWheelSymbolInkPathTests {
    private let offscreen = BTPoint(x: -20_000, y: -20_000)

    /// Custom wheels whose inner ring holds SF Symbol commands, so the label
    /// space must size symbol icons.
    private var contents: [LayoutWheelLiquidContent] {
        var result: [LayoutWheelLiquidContent] = []
        for levels: LayoutWheelLevelCount in [.one, .two] {
            var configuration = LayoutWheelConfiguration(style: .custom, levelCount: levels)
            let symbols: [LayoutWheelCommand] = [.repairBento, .savedLayouts, .moreLayoutChoices, .moreSavedLayouts]
            for index: Int in configuration.innerSlots.indices {
                configuration.innerSlots[index] = symbols[index % symbols.count]
            }
            result.append(LayoutWheelLiquidContent(configuration: configuration, levelCount: levels))
            result.append(LayoutWheelLiquidContent(configuration: LayoutWheelConfiguration(style: .grouped), levelCount: levels))
        }
        return result
    }

    private func symbolSlots(_ content: LayoutWheelLiquidContent) -> Int {
        var count: Int = 0
        for slot: LayoutWheelSlot in content.rings[0].slots where slot.glyph == nil
            && slot.windowAction.flatMap({ WindowActionPartitionGlyph.actions[$0] }) == nil
            && slot.symbolName != "rectangle.split.3x2" && !slot.symbolName.isEmpty {
            count += 1
        }
        return count
    }

    private func state(_ content: LayoutWheelLiquidContent, _ sector: LayoutWheelSector) -> LayoutWheelLiquidState {
        let angle: Double = content.layout.slotAngle(sector.rawValue)
        let radius: Double = content.layout.iconRadii[0]
        let ring: LayoutWheelRing = content.configuration.style == .grouped ? content.configuration.groupRing : .inner
        return LayoutWheelLiquidState(selection: LayoutWheelSelection(ring: ring, sector: sector),
                                      pointer: BTPoint(x: cos(angle) * radius, y: sin(angle) * radius))
    }

    @Test(.liquidPipeline) func normalMetalWheelUseMakesNoImageRendererCalls() throws {
        try #require(MTLCreateSystemDefaultDevice() != nil)
        let cases: [LayoutWheelLiquidContent] = contents
        #expect(cases.contains { symbolSlots($0) > 0 }, "The scenario must put SF Symbols on the inner ring.")
        let calls: Int = LayoutWheelLabelSpace.symbolInkSizeCallsForTesting
        let renders: Int = LayoutWheelLabelSpace.symbolInkRendersForTesting
        for content: LayoutWheelLiquidContent in cases {
            let clock = WheelTestClock()
            let presenter = LayoutWheelLiquidPresenter(clock: clock)
            presenter.reduceMotion = true
            presenter.dark = true
            presenter.opaque = false
            // Hold, open, aim at every sector so each centre label is fitted, then choose.
            #expect(presenter.prepareToOpen(content))
            #expect(presenter.open(content, center: offscreen))
            clock.frame()
            for sector: LayoutWheelSector in LayoutWheelSector.allCases {
                presenter.update(state(content, sector))
                clock.frame()
            }
            #expect(presenter.labelImageForTesting != nil)
            presenter.end(.commit)
            for _ in 0..<10 { clock.frame() }
            presenter.close()
        }
        #expect(LayoutWheelLabelSpace.symbolInkSizeCallsForTesting == calls,
                "The Metal wheel must use the bundled ink sizes, not SwiftUI measurement.")
        #expect(LayoutWheelLabelSpace.symbolInkRendersForTesting == renders)
    }

    /// The Settings style cards draw through the same Metal path.
    @Test(.liquidPipeline) func settingsStyleCardsMakeNoImageRendererCalls() throws {
        try #require(MTLCreateSystemDefaultDevice() != nil)
        let calls: Int = LayoutWheelLabelSpace.symbolInkSizeCallsForTesting
        for size: LayoutWheelSize in LayoutWheelSize.allCases {
            for dark: Bool in [false, true] {
                var configuration = LayoutWheelConfiguration(style: .grouped, levelCount: .two)
                configuration.appearance.size = size
                let image: NSImage? = LayoutWheelStyleSnapshots.render(configuration: configuration, dark: dark)
                #expect(image != nil)
            }
        }
        #expect(LayoutWheelLabelSpace.symbolInkSizeCallsForTesting == calls)
    }

    /// The counter sees the SwiftUI measurement, so the zero above is meaningful.
    @Test func swiftUIWheelMeasurementIsCounted() throws {
        let content: LayoutWheelLiquidContent = try #require(contents.first)
        try #require(symbolSlots(content) > 0)
        let calls: Int = LayoutWheelLabelSpace.symbolInkSizeCallsForTesting
        _ = LayoutWheelLabelSpace(liquid: content)
        #expect(LayoutWheelLabelSpace.symbolInkSizeCallsForTesting > calls)
        let metal: LayoutWheelLabelSpace? = LayoutWheelLabelSpace(metal: content)
        #expect(metal != nil)
        let afterLiquid: Int = LayoutWheelLabelSpace.symbolInkSizeCallsForTesting
        _ = LayoutWheelLabelSpace(metal: content)
        #expect(LayoutWheelLabelSpace.symbolInkSizeCallsForTesting == afterLiquid)
    }
}
