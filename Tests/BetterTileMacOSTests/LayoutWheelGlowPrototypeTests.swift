import AppKit
import Testing
@testable import BetterTileCore
@testable import BetterTileMacOS

@MainActor @Suite(.serialized) struct LayoutWheelGlowPrototypeTests {
    @Test func captureLightIconTintOptionsForUserJudgment() throws {
        guard let path = ProcessInfo.processInfo.environment["WH_GLOW_DIAGNOSTICS"] else { return }
        let folder = URL(filePath: path)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var rows: [[String: Any]] = []
        for preset in LayoutWheelLiquidSettings.Preset.allCases {
            var wheel = LayoutWheelConfiguration(style: .grouped, levelCount: .two)
            wheel.appearance.liquid = .init(preset: preset, appearance: .light)
            let content = LayoutWheelLiquidDefaults.content(configuration: wheel)
            let tinted = try #require(LayoutWheelStyleSnapshots.render(configuration: wheel, dark: false))
            let ink = try #require(LayoutWheelStyleSnapshots.render(configuration: wheel, dark: false, tintIcons: false))
            let glass = try #require(LayoutWheelStyleSnapshots.render(configuration: wheel, dark: false, drawIcons: false))
            let a = try pixels(tinted), b = try pixels(ink), c = try pixels(glass)
            let radius = try #require(content.layout.iconRadii.last)
            // The calm snapshot has no bulge offset. Select solid glyph pixels using its untinted mask.
            let cx = Int(Double(a.pixelsWide) / 2 + radius * 2), cy = a.pixelsHigh / 2
            var tintedL: [Double] = [], inkL: [Double] = [], contrast: [Double] = []
            for y in (cy-22)...(cy+22) {
                for x in (cx-22)...(cx+22) {
                    let surface = luminance(c, x, y), original = luminance(b, x, y)
                    guard abs(original - surface) > 0.12 else { continue }
                    let aimed = luminance(a, x, y)
                    tintedL.append(abs(aimed - surface)); inkL.append(abs(original - surface))
                    contrast.append((max(aimed, surface) + 0.05) / (min(aimed, surface) + 0.05))
                }
            }
            #expect(!tintedL.isEmpty)
            rows.append(["style": preset.rawValue, "glyphSamples": tintedL.count,
                         "tintedDeltaL": tintedL.reduce(0,+) / Double(tintedL.count),
                         "inkDeltaL": inkL.reduce(0,+) / Double(inkL.count),
                         "tintedContrastRatio": contrast.reduce(0,+) / Double(contrast.count)])
            for (name, image) in [("tinted", tinted), ("ink", ink)] {
                let data = try #require(try pixels(image).representation(using: .png, properties: [:]))
                try data.write(to: folder.appendingPathComponent("\(preset.rawValue)-light-\(name).png"))
            }
        }
        try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
            .write(to: folder.appendingPathComponent("icon-contrast.json"))
    }

    @Test func measureNeutralLightInsideTheAimedSlice() throws {
        guard let path = ProcessInfo.processInfo.environment["WH_GLOW_DIAGNOSTICS"],
              let pipeline = LayoutWheelLiquidPipeline.prepare(), let encoder = LayoutWheelLiquidEncoder(pipeline: pipeline) else { return }
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        var rows: [[String: Any]] = []
        for dark in [false, true] {
            let content = LayoutWheelLiquidDefaults.content(configuration: .init(style: .grouped, levelCount: .two))
            var model = LayoutWheelLiquid(layout: content.layout, reduceMotion: true)
            model.open()
            for _ in 0..<120 { model.advance(1.0 / 60) }
            var style = LayoutWheelLiquidStyle.make(dark: dark, opaque: false, accent: .white, translucency: 0.30)
            style.glowAlpha = 0; style.clearLightRimStrength = 0
            let size = CGSize(width: 368, height: 368)
            let neutral = try #require(encoder.image(model, style: style, size: size, scale: 2))
            model.update(.init(focus: .init(ring: 1, slot: 2)))
            for _ in 0..<120 { model.advance(1.0 / 60) }
            let focused = try #require(encoder.image(model, style: style, size: size, scale: 2))
            let a = NSBitmapImageRep(cgImage: focused), b = NSBitmapImageRep(cgImage: neutral)
            let radius = content.layout.iconRadii[1] + 16
            let cx = Int(size.width + cos(0.15) * radius * 2), cy = Int(size.height + sin(0.15) * radius * 2)
            let values = (-2...2).flatMap { dy in (-2...2).map { dx in luminance(a, cx+dx, cy+dy) - luminance(b, cx+dx, cy+dy) } }
            rows.append(["dark":dark,"whiteBackdrop":true,"neutralLiftDeltaL":values.reduce(0,+)/Double(values.count)])
        }
        try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(filePath: path).appendingPathComponent("neutral-lift.json"))
    }

    private func pixels(_ image: NSImage) throws -> NSBitmapImageRep {
        let cg = try #require(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        return NSBitmapImageRep(cgImage: cg)
    }
    private func luminance(_ image: NSBitmapImageRep, _ x: Int, _ y: Int) -> Double {
        let color = image.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!
        func linear(_ value: Double) -> Double { value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4) }
        // Composite the Metal-only image on white, equally for the two options.
        let a = Double(color.alphaComponent)
        return zip([Double(color.redComponent), Double(color.greenComponent), Double(color.blueComponent)], [0.2126, 0.7152, 0.0722])
            .reduce(0) { $0 + linear($1.0 * a + 1 - a) * $1.1 }
    }
}
