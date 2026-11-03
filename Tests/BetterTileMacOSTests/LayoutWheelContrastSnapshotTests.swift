import AppKit
import SwiftUI
import Testing
@testable import BetterTileCore
@testable import BetterTileMacOS

/// Opt-in evidence generator for `Tools/measure-wheel-contrast.swift`.
///
/// Set `BT_WHEEL_CONTRAST_DIR`. It writes 2x PNGs of an idle wheel centred in a
/// 600 pt square over four simulated backdrops, plus a box manifest. All
/// rendering is offscreen through `ImageRenderer`. Native glass is a
/// WindowServer effect that `ImageRenderer` only approximates (a tinted,
/// lightly blurred layer), so these numbers model the glass stand-in. They do
/// not measure the real compositor, its adaptive frost or live blur.
@MainActor @Suite(.macOSTestApplication, .serialized) struct LayoutWheelContrastSnapshotTests {
    private enum Backdrop: String, CaseIterable {
        case darkWallpaper, white, midGrey, black
        var view: AnyView {
            switch self {
            case .darkWallpaper:
                AnyView(LinearGradient(colors: [.init(red: 0.10, green: 0.10, blue: 0.20),
                                                .init(red: 0.30, green: 0.12, blue: 0.23)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing))
            case .white: AnyView(Color.white)
            case .midGrey: AnyView(Color(red: 0.5, green: 0.5, blue: 0.5))
            case .black: AnyView(Color.black)
            }
        }
    }

    /// Ring plate response. The ring does not follow a linear blend of the
    /// plate: live Dark over white (plate alpha 0.26, 0.36,
    /// 0.86 beside a 0.16 measurement) read 0.22, 0.21, 0.09 behind the ring icons
    /// (pixel 123, 122, 82), where a linear blend predicts 0.178, 0.145, 0.04.
    /// The native glass seems to absorb small plate changes. So the ring uses
    /// an effective alpha through these live points. The well still blends
    /// linearly, which matches the lower-alpha measurements (0.25, 0.12).
    ///
    /// Fitted only to Dark-over-white live measurements. Other backdrops reuse
    /// the mapping unchecked, and nothing is known below
    /// 0.16 or between 0.36 and 0.86. Treat predictions there as indicative.
    static func ringEffectiveAlpha(_ alpha: Double) -> Double {
        let points: [(Double, Double)] = [(0, 0), (0.16, 0.16), (0.26, 0.165), (0.36, 0.185), (0.86, 0.54), (1, 1)]
        for pair in zip(points, points.dropFirst()) where alpha <= pair.1.0 {
            let t = (alpha - pair.0.0) / (pair.1.0 - pair.0.0)
            return pair.0.1 + t * (pair.1.1 - pair.0.1)
        }
        return 1
    }

    /// Luminance of native glass alone (no plate), body and well, over each
    /// backdrop. Calibrated from measured glass luminance: the
    /// worst luminance behind the ring icons and behind the well with the plate
    /// at 0.16 (floor 0.10, strength 30 percent), with the plate blend undone.
    /// Dark over white read 0.221 / 0.323 live; the popup stand-in (0.168, a
    /// popup measurement) predicted 0.130, so the wheel's glass is lighter than
    /// the popup glass. Light over wallpaper was not measured and reuses
    /// Light over black, the least favourable for black ink.
    private static func glassLuminance(_ scheme: ColorScheme, _ backdrop: Backdrop) -> (body: Double, well: Double) {
        switch (scheme, backdrop) {
        case (.dark, .white): (0.297, 0.442)
        case (.dark, .midGrey): (0.222, 0.210)
        case (.dark, .darkWallpaper): (0.101, 0.072)
        case (.dark, .black): (0.023, 0.009)
        case (_, .white): (0.727, 0.866)
        case (_, .midGrey): (0.416, 0.518)
        default: (0.188, 0.250)
        }
    }
    /// `ImageRenderer` bitmaps carry HDR headroom metadata that makes
    /// `NSBitmapImageRep.colorAt` return shifted values (0.44 reads as 0.51).
    /// Redraw into plain 8-bit sRGB before reading or writing pixels.
    private static func normalized(_ image: CGImage) throws -> NSBitmapImageRep {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return NSBitmapImageRep(cgImage: try #require(context.makeImage()))
    }
    private static func gray(luminance: Double) -> Color {
        let value = luminance <= 0.0031308 ? 12.92 * luminance : 1.055 * pow(luminance, 1 / 2.4) - 0.055
        return Color(.sRGB, red: value, green: value, blue: value)
    }

    private struct Box: Encodable { var name: String; var kind: String; var box: [Double]; var part: String }
    private struct Probe: Encodable { var image: String; var bodyNearWell: Double; var bodyNearRim: Double; var well: Double }
    private struct Capture: Encodable {
        var image: String; var combination: String; var state = "idle"; var scale = 2.0; var boxes: [Box]
    }

    private static func luminance(_ color: NSColor) -> Double {
        func linear(_ v: CGFloat) -> Double { let x = Double(v); return x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(color.redComponent) + 0.7152 * linear(color.greenComponent) + 0.0722 * linear(color.blueComponent)
    }

    private func boxes(for input: LayoutWheelSceneInput) -> [Box] {
        let drawn = LayoutWheelDrawnMetrics(input)
        let s = drawn.scale, c = 300.0
        var result: [Box] = []
        for ring in input.configuration.activeRings {
            for sector in LayoutWheelSector.allCases {
                let selection = LayoutWheelSelection(ring: ring, sector: sector)
                let slot = input.slot(.sector(selection))
                let point = drawn.iconPoint(selection, symbol: slot.symbolName)
                let outer = ring == .outer && drawn.levelCount == .two
                let size: (Double, Double) = outer ? (22 * s, 20 * s)
                    : (drawn.levelCount == .two ? (23.4 * s, 18.4 * s) : (21.06 * s, 16.56 * s))
                let inset = drawn.levelCount == .two && ring == .inner ? 0.8 : 1.0
                let w = size.0 * (outer ? 1 : inset), h = size.1 * (outer ? 1 : inset)
                result.append(.init(name: slot.label, kind: slot.isAvailable ? "hub" : "unavailable",
                                    box: [c + point.x - w / 2, c + point.y - h / 2, w, h],
                                    part: outer ? "outer-icon" : "icon"))
            }
        }
        result.append(.init(name: "Cancel", kind: "label", box: [c - 18 * s, c + 2 * s, 36 * s, 13 * s], part: "rest-label"))
        result.append(.init(name: "Cancel cross", kind: "hub", box: [c - 6 * s, c - 13 * s, 12 * s, 12 * s], part: "icon"))
        return result
    }

    @Test func offscreenBackdropMatrix() throws {
        guard let directory = ProcessInfo.processInfo.environment["BT_WHEEL_CONTRAST_DIR"] else { return }
        let folder = URL(filePath: directory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var captures: [Capture] = []
        var probes: [Probe] = []
        for (style, level, name) in [(LayoutWheelStyle.custom, LayoutWheelLevelCount.one, "custom-one"),
                                      (.custom, .two, "custom-two"), (.grouped, .two, "grouped-two")] {
            for scale in [0.8, 1.0, 1.2] {
                var configuration = LayoutWheelConfiguration(style: style, levelCount: level)
                configuration.scale = scale
                let input = LayoutWheelSceneInput(configuration: configuration, layoutAvailable: false)
                let manifest = boxes(for: input)
                // (label, strength, floor, scheme, solid). The wheel follows the
                // system appearance, so the scheme is the only tone input.
                // BT_WHEEL_PLATE_FLOORS is "body:well,body:well". Default: shipped values.
                let floors: [(Double, Double)] = (ProcessInfo.processInfo.environment["BT_WHEEL_PLATE_FLOORS"]
                    ?? "\(LayoutWheelGlassTreatment.plateFloor):\(LayoutWheelGlassTreatment.wellPlateFloor)")
                    .split(separator: ",").compactMap { pair in
                        let parts = pair.split(separator: ":").compactMap { Double($0) }
                        return parts.count == 2 ? (parts[0], parts[1]) : nil
                    }
                var variants: [(String, Double, Double, Double, ColorScheme, Bool)] = []
                for scheme in [ColorScheme.dark, .light] {
                    let name = scheme == .dark ? "dark" : "light"
                    for (floor, wellFloor) in floors {
                        for strength in [0.0, 0.3, 1.0] {
                            variants.append(("\(name)-f\(Int((floor * 100).rounded()))w\(Int((wellFloor * 100).rounded()))-s\(Int(strength * 100))",
                                             strength, floor, wellFloor, scheme, false))
                        }
                    }
                    variants.append(("solid-\(name)", 0.3, 0.08, 0.08, scheme, true))
                }
                for (label, strength, floor, wellFloor, scheme, solid) in variants {
                    for backdrop in Backdrop.allCases {
                        let clock = WheelTestClock()
                        let renderer = LayoutWheelGlassRenderer(clock: clock)
                        defer { renderer.stop() }
                        // The solid path is driven through the injected system
                        // display option, as Reduce Transparency would.
                        renderer.displayOptions = { .init(reduceMotion: false, reduceTransparency: solid, increaseContrast: false) }
                        renderer.configure(input, newOpen: true)
                        clock.settle()
                        #expect(renderer.usesGlass == !solid)
                        var view = try #require(renderer.hosting).rootView
                        view.strength = strength
                        // Test-only: drive the ring plate to its effective alpha.
                        let ringAlpha = LayoutWheelGlassTreatment.plateOpacity(strength: strength, floor: floor)
                        view.plateFloor = Self.ringEffectiveAlpha(ringAlpha) - 0.20 * strength
                        view.wellPlateFloor = wellFloor
                        let image = ImageRenderer(content: ZStack { backdrop.view; view }
                            .frame(width: 600, height: 600).environment(\.colorScheme, scheme)
                            .environment(\.layoutWheelGlassStandIn, {
                                let glass = Self.glassLuminance(scheme, backdrop)
                                return LayoutWheelGlassStandIn(body: Self.gray(luminance: glass.body), well: Self.gray(luminance: glass.well))
                            }()))
                        image.scale = 2
                        let cgImage = try #require(image.cgImage)
                        let bitmap = try Self.normalized(cgImage)
                        let file = "\(name)-\(scale)-\(label)-\(backdrop.rawValue)-idle.png"
                        try bitmap.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent(file))
                        captures.append(.init(image: file, combination: "\(label)/\(backdrop.rawValue)", boxes: manifest))
                        // Luminance of bare glass between icons: body near the
                        // well, body near the rim, and the well below its text.
                        let drawn = LayoutWheelDrawnMetrics(input)
                        let a = Double.pi / 16
                        let radii = [drawn.wellRadius + 7 * drawn.scale, drawn.outerRadius - 5 * drawn.scale]
                        var points: [CGPoint] = radii.map { CGPoint(x: 300 + cos(a) * $0, y: 300 + sin(a) * $0) }
                        points.append(CGPoint(x: 300, y: 300 + 24 * drawn.scale))
                        var lum: [Double] = []
                        for point in points {
                            // `normalized` already holds sRGB. Converting again would shift it.
                            let c = try #require(bitmap.colorAt(x: Int(point.x * 2), y: Int(point.y * 2)))
                            lum.append(Self.luminance(c))
                        }
                        probes.append(Probe(image: file, bodyNearWell: lum[0], bodyNearRim: lum[1], well: lum[2]))
                    }
                }
            }
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(captures).write(to: folder.appendingPathComponent("contrast-boxes.json"))
        try encoder.encode(probes).write(to: folder.appendingPathComponent("glass-luminance.json"))
    }
}
