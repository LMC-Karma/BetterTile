import AppKit
import Testing
@testable import BetterTileCore
@testable import BetterTileMacOS

@MainActor @Suite(.serialized) struct LayoutWheelGlowTests {
    private let layout = LayoutWheelLiquidLayout(outerRadius: 120, stepRadius: 72, wellRadius: 32,
                                                iconRadii: [50, 93], dropletRadius: 20)

    @Test func approvedLightInkAndStyleTintReachTheSpriteFragment() throws {
        let pipeline = try #require(LayoutWheelLiquidPipeline.prepare())
        let encoder = try #require(LayoutWheelLiquidEncoder(pipeline: pipeline))
        let context = try #require(CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8,
            bytesPerRow: 16, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 0, alpha: 1)); context.fill(.init(x: 0, y: 0, width: 4, height: 4))
        let glyph = try #require(context.makeImage())
        let atlas = try #require(LayoutWheelLiquidAtlas(device: pipeline.device, images: [(.chevron, glyph)], scale: 1))
        let entry = try #require(atlas.entries[.chevron])
        var model = LayoutWheelLiquid(layout: layout, reduceMotion: true)
        model.open(); for _ in 0..<120 { model.advance(1.0 / 60) }
        for dark in [false, true] {
            for preset in LayoutWheelLiquidSettings.Preset.allCases {
                var wheel = LayoutWheelConfiguration(style: .grouped, levelCount: .two)
                wheel.appearance.liquid = .init(preset: preset, appearance: dark ? .dark : .light)
                var style = LayoutWheelLiquidDefaults.snapshotStyle(configuration: wheel, dark: dark)
                let expected: SIMD3<Float> = switch preset {
                case .ice: .init(0.12, 0.52, 1)
                case .warm: .init(0.93, 0.77, 0.53)
                case .frosted, .mono: .init(repeating: dark ? 1 : 0)
                }
                #expect(style.iconAccent == expected)
                style.bodyTint = .zero; style.wellTint = .zero; style.shadowAlpha = 0
                for mix: Float in [0, 0.5, 1] {
                    let image = try #require(encoder.image(model, style: style, size: .init(width: 280, height: 280), scale: 1,
                        sprites: .init(atlas: atlas, instances: [.init(0, 0, 4, 4), entry.uv, .init(0, 1, mix, 0)], viewSize: .init(width: 280, height: 280))))
                    // Read the shader's sRGB bytes, without converting through the active display profile.
                    let bytes = try #require(image.dataProvider?.data) as Data
                    let index = 140 * image.bytesPerRow + 140 * 4
                    for (value, target) in zip([bytes[index + 2], bytes[index + 1], bytes[index]], [expected.x, expected.y, expected.z]) {
                        #expect(abs(Double(value) / 255 - Double(target * mix)) < 0.006)
                    }
                }
            }
        }
    }

    @Test func fakeClockCrossfadesMainAndBubbleTintAndDimsOnlyOtherMainIcons() throws {
        let clock = WheelTestClock()
        let presenter = LayoutWheelLiquidPresenter(clock: clock)
        presenter.reduceMotion = false; presenter.dark = true
        let content = LayoutWheelLiquidDefaults.content(configuration: .init(style: .grouped, levelCount: .two), currentMode: .manual)
        #expect(presenter.open(content, center: .init(x: 0, y: 0), state: .init(), inPanel: false))
        defer { presenter.close() }
        clock.frame()
        let state = LayoutWheelLiquidState(selection: .init(ring: .outer, sector: .right), openSector: .right, aimedOption: 0)
        presenter.update(content, state: state)
        #expect(presenter.currentModel?.iconTint(ring: 1, slot: 2) == 0)
        func frames(_ count: Int) { for _ in 0..<count { clock.frame(hz: 100) } }
        frames(6)
        #expect(abs(try #require(presenter.currentModel).iconTint(ring: 1, slot: 2) - 0.5) < 1e-8)
        #expect(abs(try #require(presenter.currentModel).droplets[0].iconTint - 0.5) < 1e-8)
        frames(6)
        let model = try #require(presenter.currentModel), atlas = try #require(presenter.atlasForTesting)
        #expect(abs(model.iconTint(ring: 1, slot: 2) - 1) < 1e-8)
        #expect(model.iconTint(ring: 1, slot: 1) == 0)
        #expect(abs(model.submenuDimming - 1) < 1e-8)
        var sprites: [SIMD4<Float>] = []
        LayoutWheelLiquidPresenter.fillSprites(&sprites, model: model, content: content, state: state, atlas: atlas)
        func sprite(_ key: LayoutWheelLiquidAtlas.Key) throws -> SIMD4<Float> {
            let uv = try #require(atlas.entries[key]).uv
            let index = try #require(stride(from: 1, to: sprites.count, by: 3).first { sprites[$0] == uv })
            return sprites[index + 1]
        }
        #expect(try sprite(.ring(1, 2)).y == 1)
        #expect(try sprite(.ring(1, 1)).y == 0.5)
        #expect(try sprite(.ring(1, 1)).z == 0)
        #expect(try sprite(.option(2, 0)).z > 0.999)
        presenter.update(content, state: .init())
        frames(6)
        #expect(abs(try #require(presenter.currentModel).iconTint(ring: 1, slot: 2) - 0.5) < 1e-8)
        frames(6)
        #expect(try #require(presenter.currentModel).iconTint(ring: 1, slot: 2) < 1e-8)
        #expect(try #require(presenter.currentModel).submenuDimming < 1e-8)
    }

    @Test func renderedGlowHasAnOuterPeakSoftInteriorAndBoundedDividerSpill() throws {
        let pipeline = try #require(LayoutWheelLiquidPipeline.prepare())
        let encoder = try #require(LayoutWheelLiquidEncoder(pipeline: pipeline))
        var model = LayoutWheelLiquid(layout: layout, reduceMotion: true)
        model.open(); model.update(.init(focus: .init(ring: 1, slot: 2)))
        for _ in 0..<120 { model.advance(1.0 / 60) }
        var style = LayoutWheelLiquidStyle.make(dark: true, opaque: false, accent: .white)
        // Alpha isolates the real shader's selection envelope, with no glass, AA, sprites or rim light mixed in.
        style.bodyTint = .zero; style.wellTint = .zero; style.materialStandIn = .zero
        style.rimStrength = 0; style.sheen = 0; style.separatorAlpha = 0
        style.seamAlpha = 0; style.shadowAlpha = 0; style.glowAlpha = 1
        let image = try #require(encoder.image(model, style: style, size: .init(width: 280, height: 280), scale: 4))
        let bitmap = NSBitmapImageRep(cgImage: image)
        func value(_ r: Double, _ angle: Double = 0) -> Double {
            let x = Int((140 + r * cos(angle)) * 4), y = Int((140 + r * sin(angle)) * 4)
            return Double(bitmap.colorAt(x: x, y: y)!.alphaComponent)
        }
        var neutralModel = model
        neutralModel.update(.init())
        for _ in 0..<120 { neutralModel.advance(1.0 / 60) }
        let neutralImage = try #require(encoder.image(neutralModel, style: style, size: .init(width: 280, height: 280), scale: 4))
        let neutral = NSBitmapImageRep(cgImage: neutralImage)
        // Subtract the existing well edge. The glow starts continuously at zero, with no alpha step.
        for radius in stride(from: 32.0, through: 34.0, by: 0.25) {
            let baseline = Double(neutral.colorAt(x: Int((140 + radius) * 4), y: 560)!.alphaComponent)
            #expect(abs(value(radius) - baseline) <= 1.0 / 255 + 1e-9)
        }
        let radial = stride(from: 36.0, through: 119.5, by: 0.25).map { ($0, value($0)) }
        let maximum = try #require(radial.map(\.1).max())
        let peak = try #require(radial.last { $0.1 == maximum })
        #expect(peak.0 >= 118)
        for pair in zip(radial, radial.dropFirst()) { #expect(pair.1.1 + 0.005 >= pair.0.1) }
        // A four-point central span suppresses the 8-bit target's quantization noise.
        let interior = stride(from: 36.0, through: 116.0, by: 0.25).map { (radius: $0, slope: abs(value($0 + 2) - value($0 - 2)) / 4) }
        let gradient = try #require(interior.max { $0.slope < $1.slope })
        #expect(gradient.slope < 0.022)
        #expect(gradient.radius > 65 && gradient.radius < 90)
        let ninety = try #require(radial.first { $0.1 >= 0.9 })
        let ten = try #require(radial.first { $0.1 >= 0.1 })
        #expect(ninety.0 - ten.0 > 50 && ninety.0 - ten.0 < 57)
        let angularPeak = value(93)
        if let path = ProcessInfo.processInfo.environment["WH_GLOW_PROFILE_MEASUREMENTS"] {
            let row: [String: Any] = ["peakRadius": peak.0, "interiorMaximumGradient": gradient.slope,
                "gradientRadius": gradient.radius, "falloff10to90Points": ninety.0 - ten.0,
                "divider": value(93, 22.5 * .pi / 180) / angularPeak,
                "past5Degrees": value(93, 27.5 * .pi / 180) / angularPeak,
                "past10Degrees": value(93, 32.5 * .pi / 180) / angularPeak,
                "neighbor": value(93, .pi / 4) / angularPeak]
            try JSONSerialization.data(withJSONObject: row, options: [.prettyPrinted, .sortedKeys])
                .write(to: URL(filePath: path))
        }
        for sign in [-1.0, 1] {
            let samples = [22.5, 27.5, 32.5, 45].map { value(93, $0 * sign * .pi / 180) / angularPeak }
            #expect(samples[0] > 0.46 && samples[0] < 0.54)
            #expect(samples[1] > 0.17 && samples[1] < 0.25)
            #expect(samples[2] >= 0 && samples[2] < 0.08)
            #expect(samples[3] < 0.01)
        }
    }
    @Test func settledBubbleGapHasNoSmoothUnionBridge() throws {
        let pipeline = try #require(LayoutWheelLiquidPipeline.prepare())
        let encoder = try #require(LayoutWheelLiquidEncoder(pipeline: pipeline))
        var model = LayoutWheelLiquid(layout: layout)
        model.open()
        model.update(.init(pointer: .init(x: 150, y: 0), focus: .init(ring: 1, slot: 2),
                           fan: .init(parentSlot: 2, options: [.init(x: 150, y: 0)], aimedOption: 0)))
        let connectionFrames = Int(ceil(LayoutWheelLiquidDroplet.openingConnectionWindow.upperBound * 120))
        for _ in 0..<connectionFrames { model.advance(1.0 / 120) }
        #expect(model.droplets.allSatisfy { $0.connection == 0 })
        for _ in 0..<600 { model.advance(1.0 / 120) }
        let drop = try #require(model.droplets.first)
        let rim = model.outer.radius(at: 0), gap = drop.center.x - drop.radius - rim
        #expect(gap > 1 && gap < 4)
        #expect(drop.connection == 0)
        var reference = LayoutWheelLiquid(layout: layout)
        reference.open(); reference.update(.init(pointer: .init(x: 93, y: 0), focus: .init(ring: 1, slot: 2)))
        for _ in 0..<600 { reference.advance(1.0 / 120) }
        #expect(abs(rim - reference.outer.radius(at: 0)) < 0.01)
        #expect(rim - layout.outerRadius > 5)
        var style = LayoutWheelLiquidStyle.make(dark: true, opaque: true, accent: .white)
        style.shadowAlpha = 0
        let image = try #require(encoder.image(model, style: style, size: .init(width: 400, height: 400), scale: 4))
        let pixels = NSBitmapImageRep(cgImage: image)
        let midpoint = Int((200 + rim + gap / 2) * 4)
        #expect(try #require(pixels.colorAt(x: midpoint, y: 800)).alphaComponent < 0.01)
    }

}
