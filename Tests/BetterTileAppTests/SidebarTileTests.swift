import AppKit
import BetterTileCore
import BetterTileMacOS
import SwiftUI
import Testing
@testable import BetterTileApp

@MainActor @Suite(.appTestApplication, .serialized) struct SidebarTileTests {
    @Test func layoutsKeepTheFifteenPointSourceDrawing() throws {
        func inkSize(_ image: CGImage) -> CGSize {
            let bitmap = NSBitmapImageRep(cgImage: image)
            var xs: [Int] = [], ys: [Int] = []
            for y in 0..<bitmap.pixelsHigh {
                for x in 0..<bitmap.pixelsWide where (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.25 {
                    xs.append(x); ys.append(y)
                }
            }
            return CGSize(width: xs.max()! - xs.min()! + 1, height: ys.max()! - ys.min()! + 1)
        }
        for scale in [1.0, 2.0] {
            let source = ImageRenderer(content: LayoutGlyphView(.layouts, size: 15, weight: .semibold)
                .foregroundStyle(.white).frame(width: 20, height: 20).environment(\.displayScale, scale))
            source.scale = scale
            let tile = ImageRenderer(content: SidebarTile(icon: .layoutGlyph(.layouts), color: .clear)
                .environment(\.displayScale, scale))
            tile.scale = scale
            let expected = inkSize(try #require(source.cgImage)), actual = inkSize(try #require(tile.cgImage))
            print("LAYOUT_SOURCE \(scale)x expected=\(expected) actual=\(actual)")
            // Centring can change the edge phase by one pixel, but must retain
            // the source canvas and its display-scale-specific pixel snapping.
            #expect(abs(actual.width - expected.width) <= 1)
            #expect(abs(actual.height - expected.height) <= 1)
        }
    }

    @Test func symbolsKeepNativeEdgeSharpness() throws {
        func partialShare(_ bitmap: NSBitmapImageRep) -> Double {
            var ink = 0, partial = 0
            for y in 0..<bitmap.pixelsHigh {
                for x in 0..<bitmap.pixelsWide {
                    let alpha = bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0
                    if alpha > 0.1 {
                        ink += 1
                        if alpha < 0.9 { partial += 1 }
                    }
                }
            }
            return Double(partial) / Double(max(1, ink))
        }
        for destination in SettingsDestination.allCases {
            guard case let .symbol(name) = destination.icon else { continue }
            for scale in [1.0, 2.0] {
                let symbol = try #require(NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                    .withSymbolConfiguration(name == "gearshape"
                        ? .init(pointSize: 11, weight: .semibold) : .init(pointSize: 10.5, weight: .medium)))
                let direct = try #require(NSBitmapImageRep(bitmapDataPlanes: nil,
                    pixelsWide: Int(20 * scale), pixelsHigh: Int(20 * scale), bitsPerSample: 8,
                    samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                    bytesPerRow: 0, bitsPerPixel: 0))
                let graphics = try #require(NSGraphicsContext(bitmapImageRep: direct))
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = graphics
                graphics.cgContext.scaleBy(x: scale, y: scale)
                symbol.draw(in: CGRect(x: (((20 - symbol.size.width) / 2) * scale).rounded() / scale,
                                       y: (((20 - symbol.size.height) / 2) * scale).rounded() / scale,
                                       width: symbol.size.width, height: symbol.size.height))
                NSGraphicsContext.restoreGraphicsState()
                for dark in [false, true] {
                    let renderer = ImageRenderer(content: SidebarTile(icon: destination.icon, color: .clear)
                        .environment(\.displayScale, scale).environment(\.colorScheme, dark ? .dark : .light))
                    renderer.scale = scale
                    let actual = NSBitmapImageRep(cgImage: try #require(renderer.cgImage))
                    let nativeShare = partialShare(direct), tileShare = partialShare(actual)
                    print("SHARPNESS \(destination.rawValue) \(scale)x \(dark ? "dark" : "light") native=\(nativeShare) tile=\(tileShare)")
                    #expect(tileShare <= nativeShare + 0.05)
                }
            }
        }
    }

    @Test func inkIsCenteredAtBothDisplayScalesAndAppearances() throws {
        let directory = ProcessInfo.processInfo.environment["BT_TILE_DIR"]
        var measurements = "tile,theme,scale,dx,dy\n"
        var oneX: [String: [(Double, Double)]] = [:]
        let baseline = ProcessInfo.processInfo.environment["BT_TILE_BASELINE"] == "1"
        let legacySymbols: [SettingsDestination: String] = [
            .general: "gearshape", .windowLayout: "rectangle.3.group", .savedLayouts: "rectangle.stack",
            .shortcuts: "keyboard", .snapZones: "rectangle.split.3x3", .menuBar: "line.3.horizontal",
            .layoutWheel: "circle.hexagonpath", .applicationRules: "app.badge.checkmark",
        ]
        let tiles = SettingsDestination.allCases.map { ($0.rawValue, $0.icon, legacySymbols[$0]!, $0.tileColor) }
        for (name, icon, legacySymbol, tileColor) in tiles {
            for dark in [false, true] {
                for scale in [1.0, 2.0] {
                    let content = baseline
                        ? AnyView(LegacySidebarTile(systemImage: legacySymbol))
                        : AnyView(SidebarTile(icon: icon, color: .clear))
                    let renderer = ImageRenderer(content:
                        content.environment(\.colorScheme, dark ? .dark : .light)
                            .environment(\.displayScale, scale))
                    renderer.scale = scale
                    let bitmap = NSBitmapImageRep(cgImage: try #require(renderer.cgImage))
                    var xs: [Int] = [], ys: [Int] = []
                    for y in 0..<bitmap.pixelsHigh {
                        for x in 0..<bitmap.pixelsWide {
                            if try #require(bitmap.colorAt(x: x, y: y)).alphaComponent > 0.25 {
                                xs.append(x); ys.append(y)
                            }
                        }
                    }
                    let dx = Double(try #require(xs.min()) + #require(xs.max()) + 1) / (2 * scale) - 10
                    let dy = Double(try #require(ys.min()) + #require(ys.max()) + 1) / (2 * scale) - 10
                    if scale == 1 { oneX[dark ? "dark" : "light", default: []].append((dx, dy)) }
                    if name == "General" {
                        #expect(dx == 0)
                        #expect(dy == 0)
                    }
                    measurements += "\(name),\(dark ? "dark" : "light"),\(scale),\(dx),\(dy)\n"
                    #expect(abs(dx) <= 0.5 / scale, "\(name) \(scale)x x = \(dx)")
                    #expect(abs(dy) <= 0.5 / scale, "\(name) \(scale)x y = \(dy)")
                    if let directory {
                        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
                        let tileRenderer = ImageRenderer(content: content
                            .background(baseline && name == "Window Layout" ? Color.accentColor : tileColor,
                                        in: RoundedRectangle.settings(SettingsRadius.mini))
                            .environment(\.colorScheme, dark ? .dark : .light)
                            .environment(\.displayScale, scale))
                        tileRenderer.scale = scale
                        let tile = NSBitmapImageRep(cgImage: try #require(tileRenderer.cgImage))
                        try #require(tile.representation(using: .png, properties: [:])).write(to:
                            URL(fileURLWithPath: directory).appendingPathComponent("\(name)-\(dark ? "dark" : "light")-\(Int(scale))x-tile.png"))
                        try #require(bitmap.representation(using: .png, properties: [:])).write(to:
                            URL(fileURLWithPath: directory).appendingPathComponent("\(name)-\(dark ? "dark" : "light")-\(Int(scale))x.png"))
                    }
                }
            }
        }
        for values in oneX.values {
            for axis in [values.map(\.0), values.map(\.1)] {
                #expect(abs(axis.reduce(0, +) / Double(axis.count)) <= 0.125)
                #expect(axis.filter { $0 > 0 }.count <= axis.count / 2)
                #expect(axis.filter { $0 < 0 }.count <= axis.count / 2)
            }
        }
        print(measurements)
        if let directory {
            try measurements.write(toFile: directory + "/measurements.csv", atomically: true, encoding: .utf8)
        }
    }
}

@Test(.appTestApplication) func sidebarTilesUseFixedSystemColorsAndApprovedArtwork() {
    let expected: [SettingsDestination: Color] = [
        .general: SettingsColor.gray, .windowLayout: SettingsColor.blue,
        .savedLayouts: SettingsColor.indigo, .shortcuts: SettingsColor.gray,
        .snapZones: SettingsColor.teal, .menuBar: SettingsColor.orange,
        .layoutWheel: SettingsColor.purple, .applicationRules: SettingsColor.green,
    ]
    #expect(expected.count == SettingsDestination.allCases.count)
    for destination in SettingsDestination.allCases {
        #expect(destination.tileColor == expected[destination])
        #expect(destination.tileColor != Color.accentColor)
    }
    #expect(SettingsDestination.windowLayout.icon == .layoutGlyph(.layouts))
    #expect(SettingsDestination.menuBar.icon == .symbol("menubar.rectangle"))
    #expect(SettingsDestination.layoutWheel.icon == .wheel)
    #expect(SettingsDestination.shortcuts.icon == .symbol("keyboard"))
}

// Frozen from an earlier SettingsStyle.swift, with only its background cleared
// so the alpha threshold measures glyph ink. Keyboard was an unshipped candidate.
struct LegacySidebarTile: View {
    let systemImage: String
    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 20, height: 20)
    }
}

@Test(.appTestApplication) func shortcutsFollowsSavedLayoutsInTheSidebar() throws {
    let pages = SettingsDestination.windowManagementDestinations
    let shortcuts = try #require(pages.firstIndex(of: .shortcuts))
    #expect(pages[shortcuts - 1] == .savedLayouts)
    #expect(pages[shortcuts + 1] == .snapZones)
}
