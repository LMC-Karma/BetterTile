import AppKit
import Metal
import Testing
@_spi(LiquidWheelPrototype) @testable import BetterTileCore
@_spi(LiquidWheelPrototype) @testable import BetterTileMacOS

@MainActor @Suite(.macOSTestApplication, .serialized) struct LayoutWheelLiquidRasterReuseTests {
    private func pixels(_ atlas: LayoutWheelLiquidAtlas) -> Data {
        let texture = atlas.texture
        var data = Data(count: texture.width * texture.height * 4)
        data.withUnsafeMutableBytes { bytes in
            if let base = bytes.baseAddress {
                texture.getBytes(base, bytesPerRow: texture.width * 4,
                                 from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
            }
        }
        return data
    }

    @Test(.liquidPipeline, arguments: [LayoutWheelStyle.custom, .grouped], [LayoutWheelLevelCount.one, .two])
    func availabilityChangesKeepTheSameRasterAtlas(style: LayoutWheelStyle, levels: LayoutWheelLevelCount) throws {
        try #require(MTLCreateSystemDefaultDevice() != nil)
        let configuration = LayoutWheelConfiguration(style: style, levelCount: levels)
        let first = LayoutWheelLiquidDefaults.content(configuration: configuration, currentMode: .manual)
        let renderer = LayoutWheelLiquidPresenter(clock: WheelTestClock())
        renderer.dark = false
        #expect(renderer.open(first, center: .init(x: 0, y: 0), state: .init(), inPanel: false))
        defer { renderer.close() }
        let original = try #require(renderer.atlasForTesting)
        let unavailable = Set(WindowAction.allCases.map { LayoutWheelCommand.windowAction($0) })
        let changed = LayoutWheelLiquidDefaults.content(configuration: configuration,
            unavailableCommands: unavailable, layoutAvailable: false, currentMode: .manual)
        renderer.update(changed, state: .init())
        #expect(renderer.atlasForTesting === original)
        let retainedPixels = pixels(original)
        var model = try #require(renderer.currentModel)
        for _ in 0..<120 where !model.isAtRest { model.advance(1 / 60) }
        let names: [LayoutWheelLiquidPresenter.Names] = [.centre, .underIcons, .hidden]
        func sprites(_ atlas: LayoutWheelLiquidAtlas) -> [[SIMD4<Float>]] {
            names.map { name in
                var out: [SIMD4<Float>] = []
                LayoutWheelLiquidPresenter.fillSprites(&out, model: model, content: changed,
                    state: .init(), atlas: atlas, names: name)
                return out
            }
        }
        let retainedSprites = sprites(original)
        renderer.rebuildAtlasForTesting()
        let rebuilt = try #require(renderer.atlasForTesting)
        #expect(rebuilt !== original)
        let rebuiltPixels = pixels(rebuilt)
        // Cold SwiftUI glyph rasterization can round two antialias samples by one byte.
        // Atlas reuse above is exact; compare a fresh rebuild within that 8-bit rounding only.
        let deltas = zip(rebuiltPixels, retainedPixels).map { abs(Int($0) - Int($1)) }
        #expect(deltas.allSatisfy { $0 <= 1 })
        #expect(deltas.filter { $0 != 0 }.count <= 16)
        #expect(sprites(rebuilt) == retainedSprites)
        renderer.rebuildAtlasForTesting()
        let secondRebuild = try #require(renderer.atlasForTesting)
        #expect(pixels(secondRebuild) == rebuiltPixels)
        #expect(sprites(secondRebuild) == retainedSprites)
    }
    @Test(.liquidPipeline) func aimingTintsSpritesWithoutBuildingOrUploadingAnAtlas() throws {
        try #require(MTLCreateSystemDefaultDevice() != nil)
        let clock = WheelTestClock()
        let renderer = LayoutWheelLiquidPresenter(clock: clock)
        let content = LayoutWheelLiquidDefaults.content(configuration: .init(style: .grouped), currentMode: .manual)
        #expect(renderer.open(content, center: .init(x: 0, y: 0), state: .init(), inPanel: false))
        defer { renderer.close() }
        let builds = LayoutWheelLiquidAtlas.buildCount
        let uploads = LayoutWheelLiquidAtlas.uploadCount
        for sector in LayoutWheelSector.allCases {
            renderer.update(content, state: .init(selection: .init(ring: .outer, sector: sector)))
            for _ in 0..<16 { clock.frame(hz: 120) }
        }
        #expect(LayoutWheelLiquidAtlas.buildCount - builds == 0)
        #expect(LayoutWheelLiquidAtlas.uploadCount - uploads == 0)
    }

}
