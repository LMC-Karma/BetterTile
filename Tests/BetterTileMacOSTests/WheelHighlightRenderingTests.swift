import AppKit
import Foundation
import Testing
@testable import BetterTileCore
@testable import BetterTileMacOS

@MainActor @Suite(.macOSTestApplication, .serialized) struct WheelHighlightRenderingTests {
    typealias Liquid = LayoutWheelLiquidSettings

    @Test func everyBridgeIsExplicitAndNoneIsNotSystemAccent() {
        for opening in Liquid.Opening.allCases { #expect(LayoutWheelLiquidDefaults.opening(opening).rawValue == opening.rawValue) }
        for closing in Liquid.Closing.allCases { #expect(LayoutWheelLiquidDefaults.closing(closing).rawValue == closing.rawValue) }
        for arrangement in Liquid.Arrangement.allCases { #expect(LayoutWheelLiquidDefaults.arrangement(arrangement).rawValue == arrangement.rawValue) }
        for names in Liquid.Names.allCases { #expect(LayoutWheelLiquidDefaults.names(names).rawValue == names.rawValue) }
        for keep in Liquid.KeepOpen.allCases {
            var wheel = LayoutWheelConfiguration(); wheel.appearance.liquid.submenus.keepOpen = keep
            #expect(LayoutWheelLiquidDefaults.lockBeyondRim(configuration: wheel).rawValue == keep.rawValue)
        }
        for highlight in Liquid.HighlightColour.allCases {
            var wheel = LayoutWheelConfiguration(); wheel.appearance.liquid.look.highlightColour = highlight
            let renderer = LayoutWheelLiquidPresenter(clock: WheelTestClock())
            LayoutWheelLiquidDefaults.apply(to: renderer, configuration: wheel, appearance: .init())
            #expect(renderer.brightenHighlight == (highlight == .noHighlight))
            #expect(renderer.neutralUnderglow == (highlight == .smokeGrey))
            #expect((renderer.accent == nil) == (highlight == .systemAccent))
        }
    }

    @Test func blurCurveKeepsTheApprovedDefaultLookBeforeItsClearEnd() {
        for (value, expected) in [(0.0, 1.0), (0.30, 0.79), (0.35, 0.755), (0.85, 0.405), (0.925, 0.2025), (1.0, 0.0)] {
            #expect(abs(LayoutWheelLiquidStyle.blurOpacity(translucency: value) - expected) < 1e-12)
        }
    }

    @Test func retiredMaterialsDoNotOverrideAppearanceAndFullTranslucencyRemovesBlur() {
        guard LayoutWheelLiquidPresenter.prepare() else { return }
        let renderer = LayoutWheelLiquidPresenter(clock: WheelTestClock())
        defer { renderer.close() }
        for material in Liquid.Material.allCases {
            for dark in [false, true] {
                for translucency in [0.0, 1.0] {
                    var wheel = LayoutWheelConfiguration()
                    wheel.appearance.liquid.appearance = dark ? .dark : .light
                    wheel.appearance.liquid.look.material = material
                    wheel.appearance.liquid.translucency = .init(light: translucency, dark: translucency)
                    LayoutWheelLiquidDefaults.apply(to: renderer, configuration: wheel, appearance: .init())
                    renderer.opaque = false
                    #expect(renderer.material == .automatic)
                    #expect(renderer.prepareToOpen(LayoutWheelLiquidDefaults.content(configuration: wheel)))
                    let actual = Double(renderer.blurAlphaForTesting)
                    #expect(abs(actual - (1 - translucency)) < 1e-6)
                    #expect(renderer.blurIsHiddenForTesting == (translucency == 1))
                    #expect(renderer.blurMaterialForTesting == (dark ? .hudWindow : .popover))
                }
            }
        }
    }

    @Test func clearBrightensDarkGlass() throws {
        guard LayoutWheelLiquidPresenter.prepare() else { return }
        var wheel = LayoutWheelConfiguration(style: .grouped, levelCount: .two)
        wheel.appearance.liquid = .init(preset: .mono, appearance: .dark)
        let image = try #require(LayoutWheelStyleSnapshots.render(configuration: wheel, dark: true))
        let neutral = try #require(LayoutWheelStyleSnapshots.render(configuration: wheel, dark: true, state: .init()))
        let content = LayoutWheelLiquidDefaults.content(configuration: wheel)
        let radius = try #require(content.layout.iconRadii.last) + 16
        func contrast(_ image: NSImage) throws -> Double {
            let pixels = try composite(image, white: 1)
            let aimed = luminance(patch(pixels, points: image.size, radius: radius, angle: 0.15))
            let next = luminance(patch(pixels, points: image.size, radius: radius, angle: .pi / 4 + 0.15))
            return aimed - next
        }
        let highlightDifference = try contrast(image) - contrast(neutral)
        #expect(highlightDifference > 0.02)
    }

    @Test func realStylePixelsDifferAndClearScreensWithoutAddingAlpha() throws {
        guard LayoutWheelLiquidPresenter.prepare() else { return }
        let folder = ProcessInfo.processInfo.environment["WH_STYLE_CAPTURE_DIR"].map { URL(filePath: $0) }
        if let folder { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        var measurements: [[String: Any]] = []
        for dark in [false, true] {
            var cards: [(Liquid.Preset, NSBitmapImageRep)] = []
            for preset in Liquid.Preset.allCases {
                var wheel = LayoutWheelConfiguration(style: .grouped, levelCount: .two)
                wheel.appearance.liquid = .init(preset: preset, appearance: dark ? .dark : .light)
                let image = try #require(LayoutWheelStyleSnapshots.render(configuration: wheel, dark: dark))
                let bitmap = try normalized(image)
                cards.append((preset, bitmap))
                if let folder { try png(bitmap).write(to: folder.appendingPathComponent("card-\(preset.rawValue)-\(dark ? "dark" : "light").png")) }
            }
            for a in cards.indices {
                for b in cards.indices where b > a {
                    let difference = difference(cards[a].1, cards[b].1)
                    #expect(difference > 0.004)
                    measurements.append(["kind": "cardDifference", "dark": dark, "a": cards[a].0.rawValue, "b": cards[b].0.rawValue, "meanChannelDifference": difference])
                }
            }
            for preset in [Liquid.Preset.frosted, .mono] {
                for translucency in [0.30, 0.85] {
                    var wheel = LayoutWheelConfiguration(style: .grouped, levelCount: .two)
                    wheel.appearance.liquid = .init(preset: preset, appearance: dark ? .dark : .light)
                    wheel.appearance.liquid.translucency = .init(light: translucency, dark: translucency)
                    let image = try #require(LayoutWheelStyleSnapshots.render(configuration: wheel, dark: dark))
                    let neutral = try #require(LayoutWheelStyleSnapshots.render(configuration: wheel, dark: dark, state: .init()))
                    let focusedPixels = try bitmap(image), neutralPixels = try bitmap(neutral)
                    let content = LayoutWheelLiquidDefaults.content(configuration: wheel)
                    let radius = try #require(content.layout.iconRadii.last) + 16
                    if preset == .mono {
                        let aimed = patch(focusedPixels, points: image.size, radius: radius, angle: 0.15)
                        let rest = patch(neutralPixels, points: image.size, radius: radius, angle: 0.15)
                        #expect(abs(aimed[3] - rest[3]) < 0.01)
                        #expect(aimed[0] >= rest[0] - 0.005)
                        #expect(abs(aimed[0] - aimed[1]) < 0.01 && abs(aimed[1] - aimed[2]) < 0.01)
                    }
                    for background in [1.0, 0.10] {
                        let opaque = try composite(image, white: background), base = try composite(neutral, white: background)
                        let aimed = luminance(patch(opaque, points: image.size, radius: radius, angle: 0.15))
                        let next = luminance(patch(opaque, points: image.size, radius: radius, angle: .pi / 4 + 0.15))
                        let baseAim = luminance(patch(base, points: image.size, radius: radius, angle: 0.15))
                        let baseNext = luminance(patch(base, points: image.size, radius: radius, angle: .pi / 4 + 0.15))
                        measurements.append(["kind": "luminance", "style": preset.rawValue, "dark": dark, "translucency": translucency, "background": background, "aimed": aimed, "neighbor": next, "difference": aimed - next, "highlightDifference": (aimed - baseAim) - (next - baseNext)])
                        if let folder { try png(opaque).write(to: folder.appendingPathComponent("\(preset.rawValue)-\(dark ? "dark" : "light")-\(translucency)-bg\(background).png")) }
                    }
                }
            }
        }
        if let folder { try JSONSerialization.data(withJSONObject: measurements, options: [.prettyPrinted, .sortedKeys]).write(to: folder.appendingPathComponent("visibility.json")) }
    }

    @Test func onlyColourlessHighlightUsesTheRimAndSystemUsesEffectiveDark() throws {
        guard LayoutWheelLiquidPresenter.prepare() else { return }
        #expect(LayoutWheelLiquidDefaults.accent(.smokeGrey) == .white)
        for dark in [false, true] {
            for opaque in [false, true] {
                for highlight in Liquid.HighlightColour.allCases {
                    var wheel = LayoutWheelConfiguration(style: .grouped, levelCount: .two)
                    wheel.appearance.liquid.look.highlightColour = highlight
                    wheel.appearance.liquid.look.actionTint = true
                    let renderer = LayoutWheelLiquidPresenter(clock: WheelTestClock())
                    renderer.systemDarkProvider = { dark }
                    LayoutWheelLiquidDefaults.apply(to: renderer, configuration: wheel, appearance: .init(), systemDark: dark)
                    renderer.opaque = opaque
                    #expect(renderer.dark == nil)
                    #expect(renderer.prepareToOpen(LayoutWheelLiquidDefaults.content(configuration: wheel)))
                    #expect(renderer.styleForTesting.dark == dark)
                    #expect(renderer.styleForTesting.brightenHighlight == (highlight == .noHighlight))
                    renderer.close()
                }
            }
        }
    }

    @Test func lightRimLeavesEveryTintedHighlightByteIdentical() throws {
        guard LayoutWheelLiquidPresenter.prepare() else { return }
        for highlight in Liquid.HighlightColour.allCases where highlight != .noHighlight {
            for opaque in [false, true] {
                var wheel = LayoutWheelConfiguration(style: .grouped, levelCount: .two)
                wheel.appearance.liquid.look.highlightColour = highlight
                wheel.appearance.liquid.look.actionTint = true
                let rim = try #require(LayoutWheelStyleSnapshots.render(configuration: wheel, dark: false, opaque: opaque))
                let absent = try #require(LayoutWheelStyleSnapshots.render(configuration: wheel, dark: false, opaque: opaque, clearLightRimStrength: 0))
                #expect(try png(bitmap(rim)) == png(bitmap(absent)))
            }
        }
    }

    // Compares a rendered glow profile with an approved golden file at 2/255, and the hosted runner's GPU renders
    // it differently. On CI, blurCurveKeepsTheApprovedDefaultLookBeforeItsClearEnd,
    // retiredMaterialsDoNotOverrideAppearanceAndFullTranslucencyRemovesBlur and clearBrightensDarkGlass still cover it.
    @Test(.liveDesktop, arguments: [1, 2]) func mistAndClearProfileContrast(ambientScale: Int) throws {
        guard LayoutWheelLiquidPresenter.prepare() else { return }
        // Neither a 1x generic RGB context nor a 2x wide-gamut context may choose
        // the snapshot's raster. Both must measure the same 2x sRGB fixture.
        let ambientSpace = try #require(ambientScale == 1 ? NSColorSpace.genericRGB.cgColorSpace
            : CGColorSpace(name: CGColorSpace.displayP3))
        let ambient = try #require(CGContext(data: nil, width: 32 * ambientScale, height: 32 * ambientScale,
                                            bitsPerComponent: 8, bytesPerRow: 0, space: ambientSpace,
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ambient.scaleBy(x: CGFloat(ambientScale), y: CGFloat(ambientScale))
        #expect(ambient.colorSpace != CGColorSpace(name: CGColorSpace.sRGB))
        #expect(ambient.ctm.a == CGFloat(ambientScale) && ambient.ctm.d == CGFloat(ambientScale))
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ambient, flipped: false)
        var rows: [[String: Any]] = []
        // Dark Clear must keep the recorded glow profile in the fixture. Light Clear must darken the ring.
        // Mist and Clear stay distinct.
        let goldenURL = try #require(Bundle.module.url(forResource: "WheelStyleApprovedDark", withExtension: "json"))
        let golden = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: goldenURL)) as? [[String: Any]])
        for dark in [false, true] {
            for translucency in [0.30, 0.85] {
                for background in [1.0, 0.10] {
                    for opaque in [false, true] {
                        var profiles: [[Double]] = []
                        for preset in [Liquid.Preset.frosted, .mono] {
                            var wheel = LayoutWheelConfiguration(style: .grouped, levelCount: .two)
                            wheel.appearance.liquid = .init(preset: preset, appearance: dark ? .dark : .light)
                            wheel.appearance.liquid.translucency = .init(light: translucency, dark: translucency)
                            let focused = try #require(LayoutWheelStyleSnapshots.render(configuration: wheel, dark: dark, opaque: opaque))
                            let neutral = try #require(LayoutWheelStyleSnapshots.render(configuration: wheel, dark: dark, state: .init(), opaque: opaque))
                            // Measure the fixture's profile in a fixed 2x sRGB RGBA8 raster.
                            // A display-dependent raster changes colour conversion and the point
                            // area covered by each 5x5 patch.
                            for snapshot in [focused, neutral] {
                                let raster = try #require(snapshot.cgImage(forProposedRect: nil, context: nil, hints: nil))
                                #expect(raster.width == Int(ceil(snapshot.size.width * 2)))
                                #expect(raster.height == Int(ceil(snapshot.size.height * 2)))
                                #expect(raster.colorSpace == CGColorSpace(name: CGColorSpace.sRGB))
                                #expect(raster.bitsPerComponent == 8 && raster.bitsPerPixel == 32)
                                #expect(raster.alphaInfo == .premultipliedLast)
                                #expect(raster.bitmapInfo.intersection(.byteOrderMask) == .byteOrderDefault)
                            }
                            let image = try composite(focused, white: background), base = try composite(neutral, white: background)
                            let radius = try #require(LayoutWheelLiquidDefaults.content(configuration: wheel).layout.iconRadii.last)
                            let rawImage = try bitmap(focused), rawBase = try bitmap(neutral)
                            var alphaChanges: [Double] = []
                            var deltas: [Double] = [], pixels: [Double] = [], chroma = 0.0
                            for offset in [12.0, 16, 20, 24] {
                                for angle in [-0.30, -0.15, 0, 0.15, 0.30] {
                                    let a = patch(image, points: focused.size, radius: radius + offset, angle: angle)
                                    let b = patch(base, points: neutral.size, radius: radius + offset, angle: angle)
                                    let rgb = zip(a.prefix(3), b.prefix(3)).map { $0 - $1 }
                                    deltas.append(luminance(a) - luminance(b))
                                    alphaChanges.append(patch(rawImage, points: focused.size, radius: radius + offset, angle: angle)[3]
                                        - patch(rawBase, points: neutral.size, radius: radius + offset, angle: angle)[3])
                                    pixels += a
                                    chroma = max(chroma, (rgb.max() ?? 0) - (rgb.min() ?? 0))
                                }
                            }
                            profiles.append(deltas)
                            #expect(chroma < 0.002)
                            if preset == .mono {
                                #expect(alphaChanges.allSatisfy { abs($0) < 0.01 })
                                if dark {
                                    let row = try #require(golden.first { ($0["opaque"] as? Bool) == opaque
                                        && ($0["translucency"] as? Double) == translucency && ($0["background"] as? Double) == background })
                                    let expected = try #require(row["pixels"] as? [Double])
                                    #expect(pixels.count == expected.count)
                                    // The fixture is one GPU's 8-bit render, composited over opaque grey: C + grey(1 - A).
                                    // Another GPU may round C and A each by one 8-bit step, which moves a composited
                                    // channel by at most (1 + grey) steps, and so by at most two. A patch mean of such
                                    // pixels moves no further.
                                    let tolerance = 2.0 / 255
                                    let largest = zip(pixels, expected).map { abs($0 - $1) }.max() ?? 0
                                    #expect(largest <= tolerance, "largest difference \(largest * 255) 8-bit steps")
                                } else {
                                    let minimum = try #require(deltas.min())
                                    #expect(minimum < -0.002)
                                    if !opaque && translucency == 0.30 && background == 1 {
                                        #expect(minimum < -0.02)
                                    }
                                }
                            } else if !opaque {
                                #expect(alphaChanges.reduce(0,+) / Double(alphaChanges.count) > 0.05)
                            }
                            rows.append(["dark": dark, "translucency": translucency, "background": background,
                                "opaque": opaque, "style": preset.rawValue, "luminance": deltas.reduce(0,+) / Double(deltas.count),
                                "minimum": deltas.min()!, "chroma": chroma, "pixels": pixels,
                                "alphaIncrease": alphaChanges.reduce(0,+) / Double(alphaChanges.count)])
                        }
                        let distinction = zip(profiles[0], profiles[1]).map { abs($0 - $1) }.reduce(0,+) / Double(profiles[0].count)
                        #expect(distinction > 0.025)
                        rows.append(["dark": dark, "translucency": translucency, "background": background,
                            "opaque": opaque, "distinction": distinction])
                    }
                }
            }
        }
        if let path = ProcessInfo.processInfo.environment["WH_STYLE_MEASUREMENTS_PATH"] {
            try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]).write(to: URL(filePath: path))
        }
    }

    private func normalized(_ image: NSImage) throws -> NSBitmapImageRep {
        let result = NSImage(size: NSSize(width: 256, height: 256))
        result.lockFocus()
        image.draw(in: CGRect(x: 0, y: 0, width: 256, height: 256))
        result.unlockFocus()
        return try bitmap(result)
    }
    private func bitmap(_ image: NSImage) throws -> NSBitmapImageRep {
        NSBitmapImageRep(cgImage: try #require(image.cgImage(forProposedRect: nil, context: nil, hints: nil)))
    }
    private func composite(_ image: NSImage, white: Double) throws -> NSBitmapImageRep {
        let source = try #require(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let context = try #require(CGContext(data: nil, width: source.width, height: source.height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: white, alpha: 1));context.fill(CGRect(x: 0, y: 0, width: source.width, height: source.height))
        context.draw(source, in: CGRect(x: 0, y: 0, width: source.width, height: source.height))
        return NSBitmapImageRep(cgImage: try #require(context.makeImage()))
    }
    private func png(_ bitmap: NSBitmapImageRep) throws -> Data { try #require(bitmap.representation(using: .png, properties: [:])) }
    private func patch(_ bitmap: NSBitmapImageRep, points: NSSize, radius: Double, angle: Double) -> [Double] {
        let x = Int((points.width / 2 + radius * cos(angle)) * Double(bitmap.pixelsWide) / points.width)
        let y = Int((points.height / 2 + radius * sin(angle)) * Double(bitmap.pixelsHigh) / points.height)
        var total = [Double](repeating: 0, count: 4)
        for dx in -2...2 { for dy in -2...2 {
            let color = bitmap.colorAt(x: x + dx, y: y + dy)!.usingColorSpace(.sRGB)!
            total[0] += color.redComponent;total[1] += color.greenComponent;total[2] += color.blueComponent;total[3] += color.alphaComponent
        } }
        return total.map { $0 / 25 }
    }
    private func luminance(_ rgba: [Double]) -> Double {
        func linear(_ x: Double) -> Double { x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(rgba[0]) + 0.7152 * linear(rgba[1]) + 0.0722 * linear(rgba[2])
    }
    private func difference(_ lhs: NSBitmapImageRep, _ rhs: NSBitmapImageRep) -> Double {
        // Compare actual encoded pixels, not labels outside the image or a cache key.
        precondition(lhs.pixelsWide == rhs.pixelsWide && lhs.pixelsHigh == rhs.pixelsHigh)
        var difference = 0.0, count = 0
        for x in stride(from: 0, to: lhs.pixelsWide, by: 4) { for y in stride(from: 0, to: lhs.pixelsHigh, by: 4) {
            let a = lhs.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!, b = rhs.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!
            difference += abs(a.redComponent - b.redComponent) + abs(a.greenComponent - b.greenComponent) + abs(a.blueComponent - b.blueComponent) + abs(a.alphaComponent - b.alphaComponent)
            count += 4
        } }
        return difference / Double(count)
    }
}
