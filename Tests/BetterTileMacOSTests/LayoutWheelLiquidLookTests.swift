import AppKit
import Metal
import Testing
@_spi(LiquidWheelPrototype) @testable import BetterTileCore
@_spi(LiquidWheelPrototype) @testable import BetterTileMacOS

/// Wheel look options. Offscreen; real Metal for the atlas.
@MainActor @Suite(.macOSTestApplication, .serialized) struct LayoutWheelLiquidLookTests {
    private let grouped = LayoutWheelLiquidContent(configuration: .init(style: .grouped), levelCount: .two)

    private func restingModel(_ content: LayoutWheelLiquidContent, state: LayoutWheelLiquidState) -> LayoutWheelLiquid {
        var model = LayoutWheelLiquid(layout: content.layout)
        model.open()
        model.update(content.liquidInput(state))
        for _ in 0..<480 where !model.isAtRest { model.advance(1 / 120) }
        return model
    }

    @Test func namesUnderIconsAddOneNamePerIcon() throws {
        try #require(MTLCreateSystemDefaultDevice() != nil)
        let presenter = LayoutWheelLiquidPresenter(clock: WheelTestClock())
        // Only a wheel that draws under-icon names builds their captions.
        presenter.names = .underIcons
        #expect(presenter.prepareToOpen(grouped))
        let atlas = try #require(presenter.atlasForTesting)
        let model = restingModel(grouped, state: .init())
        var centre: [SIMD4<Float>] = [], under: [SIMD4<Float>] = [], hidden: [SIMD4<Float>] = []
        LayoutWheelLiquidPresenter.fillSprites(&centre, model: model, content: grouped, state: .init(), atlas: atlas)
        LayoutWheelLiquidPresenter.fillSprites(&under, model: model, content: grouped, state: .init(), atlas: atlas,
                                               names: .underIcons)
        LayoutWheelLiquidPresenter.fillSprites(&hidden, model: model, content: grouped, state: .init(), atlas: atlas,
                                               names: .hidden)
        // Three float4 values per sprite; 16 icons gain 16 names.
        #expect(under.count - centre.count == 16 * 3)
        #expect(hidden.count == centre.count)
        #expect(presenter.open(grouped, center: BTPoint(x: -20_000, y: -20_000)))
        presenter.close()
    }

    @Test func actionTintGivesEachKindOfActionItsOwnColour() {
        let half = LayoutWheelLiquidPresenter.actionTint(.windowAction(.leftHalf))
        let quarter = LayoutWheelLiquidPresenter.actionTint(.windowAction(.topLeftQuarter))
        let display = LayoutWheelLiquidPresenter.actionTint(.windowAction(.nextDisplay))
        #expect(half != nil && quarter != nil && display != nil)
        #expect(half != quarter && quarter != display)
        #expect(half == LayoutWheelLiquidPresenter.actionTint(.windowAction(.rightHalf)))
        #expect(LayoutWheelLiquidPresenter.actionTint(nil) == nil)
    }

    @Test func translucencyThinsTheGlassButNeverTheOpaqueFallback() {
        for dark in [true, false] {
            let solid = LayoutWheelLiquidStyle.make(dark: dark, opaque: false, translucency: 0)
            let clear = LayoutWheelLiquidStyle.make(dark: dark, opaque: false, translucency: 1)
            #expect(clear.bodyTint.w < solid.bodyTint.w * 0.3)
            #expect(clear.wellTint.w < solid.wellTint.w)
            #expect(clear.materialStandIn.w < solid.materialStandIn.w * 0.35)
            let opaque = LayoutWheelLiquidStyle.make(dark: dark, opaque: true, translucency: 1)
            #expect(opaque.bodyTint.w == 1 && opaque.materialStandIn == .zero)
        }
        let champagne = NSColor(srgbRed: 0.93, green: 0.77, blue: 0.53, alpha: 1)
        let warm = LayoutWheelLiquidStyle.make(dark: true, opaque: false, accent: champagne)
        #expect(abs(warm.accent.x - 0.93) < 0.01 && abs(warm.accent.z - 0.53) < 0.01)
    }

    /// Opt-in visual review: BT_LIQUID_SNAPSHOT_DIR=/some/dir writes PNGs of
    /// the look layouts (fan, cluster, names under icons, sizes).
    @Test func writeReviewImages() throws {
        guard let directory = ProcessInfo.processInfo.environment["BT_LIQUID_SNAPSHOT_DIR"] else { return }
        try #require(MTLCreateSystemDefaultDevice() != nil)
        let folder = URL(filePath: directory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let pipeline = try #require(LayoutWheelLiquidPipeline.prepare())
        let encoder = try #require(LayoutWheelLiquidEncoder(pipeline: pipeline))
        let cases: [(String, LayoutWheelStyle, LayoutWheelLevelCount, LayoutWheelSubmenuStyle,
                     LayoutWheelLiquidPresenter.Names, LayoutWheelSector?)] = [
            ("custom-two", .custom, .two, .fan, .centre, nil),
            ("grouped-two", .grouped, .two, .fan, .centre, nil),
            ("grouped-two-fan-left", .grouped, .two, .fan, .centre, .left),
            ("grouped-two-cluster-left", .grouped, .two, .cluster, .centre, .left),
            ("grouped-two-cluster-top", .grouped, .two, .cluster, .centre, .top),
            ("grouped-one-fan-topright", .grouped, .one, .fan, .centre, .topRight),
            ("custom-one-names", .custom, .one, .fan, .underIcons, nil),
            ("grouped-two-names-fan", .grouped, .two, .fan, .underIcons, .left),
        ]
        for (name, style, levels, submenuStyle, names, open) in cases {
            let content = LayoutWheelLiquidContent(configuration: .init(style: style, levelCount: levels),
                                                   levelCount: levels, submenuStyle: submenuStyle)
            var state = LayoutWheelLiquidState()
            if let open, let layout = content.submenuLayout {
                var submenu = LayoutWheelSubmenuState()
                let ring = content.layout.iconRadii.last!
                let angle = content.layout.slotAngle(open.rawValue)
                let point = BTPoint(x: cos(angle) * ring, y: sin(angle) * ring)
                submenu.update(vector: point, at: 0, geometry: content.wheelGeometry, layout: layout)
                submenu.update(vector: point, at: 0.25, geometry: content.wheelGeometry, layout: layout)
                let options = layout.positions(sector: open, count: LayoutWheelGroup.at(open).options.count)
                submenu.update(vector: options[1], at: 0.3, geometry: content.wheelGeometry, layout: layout)
                state = LayoutWheelLiquidState(submenu: submenu, pointer: options[1])
            }
            let presenter = LayoutWheelLiquidPresenter(clock: WheelTestClock())
            presenter.dark = true
            #expect(presenter.prepareToOpen(content))
            let atlas = try #require(presenter.atlasForTesting)
            let model = restingModel(content, state: state)
            var sprites: [SIMD4<Float>] = []
            LayoutWheelLiquidPresenter.fillSprites(&sprites, model: model, content: content, state: state,
                                                   atlas: atlas, names: names)
            let size = CGSize(width: content.diameter, height: content.diameter)
            let image = try #require(encoder.image(model, style: .make(dark: true, opaque: false), size: size, scale: 2,
                                                   sprites: .init(atlas: atlas, instances: sprites, viewSize: size)))
            let url = folder.appending(path: "\(name).png")
            let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
            CGImageDestinationAddImage(destination, image, nil)
            #expect(CGImageDestinationFinalize(destination))
        }
    }
}
