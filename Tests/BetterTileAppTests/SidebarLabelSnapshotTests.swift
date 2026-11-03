import AppKit
import SwiftUI
import Testing
@testable import BetterTileApp

/// Exercise the production Label inside a native sidebar List. No window is ordered.
@MainActor @Suite(.appTestApplication, .serialized, .settingsUI) struct SidebarLabelSnapshotTests {
    @Test func sidebarListKeepsTheTileInkCentered() throws {
        let directory = ProcessInfo.processInfo.environment["BT_TILE_DIR"]
        let baseline = ProcessInfo.processInfo.environment["BT_TILE_BASELINE"] == "1"
        var csv = "tile,theme,scale,dx,dy\n"
        let destinations: [SettingsDestination] = [.general] + SettingsDestination.windowManagementDestinations + [.applicationRules]
        let legacy: [SettingsDestination: String] = [
            .general: "gearshape", .windowLayout: "rectangle.3.group", .savedLayouts: "rectangle.stack",
            .shortcuts: "keyboard", .snapZones: "rectangle.split.3x3", .menuBar: "line.3.horizontal",
            .layoutWheel: "circle.hexagonpath", .applicationRules: "app.badge.checkmark",
        ]
        let colors: [SettingsDestination: NSColor] = [.general: .systemGray, .windowLayout: baseline ? .controlAccentColor : .systemBlue,
            .savedLayouts: .systemIndigo, .shortcuts: .systemGray, .snapZones: .systemTeal,
            .menuBar: .systemOrange, .layoutWheel: .systemPurple, .applicationRules: .systemGreen]
        for dark in [false, true] {
            for scale in [1.0, 2.0] {
                let host = try SettingsSnapshotHost(
                    List {
                        ForEach(destinations) { destination in
                            HStack {
                                if baseline {
                                    Label { Text(destination.rawValue) } icon: {
                                        LegacySidebarTile(systemImage: legacy[destination]!)
                                            .background(destination == .windowLayout ? Color.accentColor : destination.tileColor,
                                                        in: .settings(SettingsRadius.mini))
                                    }
                                } else {
                                    SettingsSidebarLabel(destination: destination)
                                }
                                Spacer()
                            }
                        }
                    }
                    .listStyle(.sidebar)
                    .font(.system(size: 13))
                    .environment(\.displayScale, scale),
                    dark: dark, width: 210, height: 400, fitHeight: false)
                defer { host.close() }
                let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil,
                    pixelsWide: Int(210 * scale), pixelsHigh: Int(400 * scale), bitsPerSample: 8,
                    samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                    bytesPerRow: 0, bitsPerPixel: 0))
                bitmap.size = NSSize(width: 210, height: 400)
                let appearance = try #require(host.view.appearance)
                appearance.performAsCurrentDrawingAppearance { host.view.cacheDisplay(in: host.view.bounds, to: bitmap) }
                if let directory {
                    try #require(bitmap.representation(using: .png, properties: [:])).write(to:
                        URL(fileURLWithPath: directory).appendingPathComponent("native-list-\(dark ? "dark" : "light")-\(Int(scale))x.png"))
                }
                var grayIndex = 0
                for destination in destinations {
                    let base = try #require(colors[destination])
                    var resolved: NSColor?
                    appearance.performAsCurrentDrawingAppearance { resolved = base.usingColorSpace(.deviceRGB) }
                    // The base used an asset-defined accent for Window Layout.
                    // Sample its flat bottom margin rather than assuming a system hue.
                    if baseline, destination == .windowLayout {
                        let row = try #require(destinations.firstIndex(of: destination))
                        resolved = bitmap.colorAt(x: Int(29 * scale), y: Int(Double(35 + row * 32) * scale))?
                            .usingColorSpace(.deviceRGB)
                    }
                    let color = try #require(resolved)
                    var matching: Set<Int> = []
                    for y in 0..<bitmap.pixelsHigh {
                        for x in 0..<Int(60 * scale) {
                            let p = try #require(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                            if abs(p.redComponent - color.redComponent) < 0.03,
                               abs(p.greenComponent - color.greenComponent) < 0.03,
                               abs(p.blueComponent - color.blueComponent) < 0.03 {
                                matching.insert(y * bitmap.pixelsWide + x)
                            }
                        }
                    }
                    var components: [CGRect] = []
                    while let seed = matching.first {
                        matching.remove(seed)
                        var pending = [seed], xs: [Int] = [], ys: [Int] = []
                        while let pixel = pending.popLast() {
                            let x = pixel % bitmap.pixelsWide, y = pixel / bitmap.pixelsWide
                            xs.append(x); ys.append(y)
                            for next in [pixel - 1, pixel + 1, pixel - bitmap.pixelsWide, pixel + bitmap.pixelsWide] {
                                if matching.remove(next) != nil { pending.append(next) }
                            }
                        }
                        let box = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()! + 1, height: ys.max()! - ys.min()! + 1)
                        if baseline && destination == .windowLayout
                            || abs(box.width / scale - 20) <= 1 && abs(box.height / scale - 20) <= 1 { components.append(box) }
                    }
                    if baseline, destination == .windowLayout, !components.isEmpty {
                        // The old wide symbol reaches the edge and disconnects
                        // parts of its blue fill. Their union is still one tile.
                        components = [components.reduce(CGRect.null) { $0.union($1) }]
                    }
                    components.sort { $0.minY < $1.minY }
                    let index = destination == .general || destination == .shortcuts ? grayIndex : 0
                    let box = try #require(components.indices.contains(index) ? components[index] : nil,
                                           Comment(rawValue: "No colored tile for \(destination) at \(scale)x"))
                    if destination == .general || destination == .shortcuts { grayIndex += 1 }
                    var xs: [Int] = [], ys: [Int] = []
                    let fill = RoundedRectangle(cornerRadius: 4 * scale, style: .continuous)
                        .inset(by: 0.5 * scale).path(in: box)
                    for y in Int(box.minY)..<Int(box.maxY) {
                        for x in Int(box.minX)..<Int(box.maxX) {
                            guard fill.contains(CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5)) else { continue }
                            let p = try #require(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                            // Recover white glyph alpha from the fixed tile fill.
                            // Native inactive Lists can attenuate white before compositing.
                            let base = [color.redComponent, color.greenComponent, color.blueComponent]
                            let ink = [p.redComponent, p.greenComponent, p.blueComponent]
                            let numerator = zip(ink, base).reduce(0.0) { $0 + ($1.0 - $1.1) * (1 - $1.1) }
                            let denominator = base.reduce(0.0) { $0 + (1 - $1) * (1 - $1) }
                            if numerator / denominator > 0.25 { xs.append(x); ys.append(y) }
                        }
                    }
                    let dx = (Double(try #require(xs.min()) + #require(xs.max()) + 1) / 2 - box.midX) / scale
                    let dy = (Double(try #require(ys.min()) + #require(ys.max()) + 1) / 2 - box.midY) / scale
                    csv += "\(destination.rawValue),\(dark ? "dark" : "light"),\(scale),\(dx),\(dy)\n"
                    if destination == .general || destination == .layoutWheel && !baseline {
                        #expect(dx == 0)
                        #expect(dy == 0)
                    }
                    if let directory, let crop = bitmap.cgImage?.cropping(to: box) {
                        try #require(NSBitmapImageRep(cgImage: crop).representation(using: .png, properties: [:])).write(to:
                            URL(fileURLWithPath: directory).appendingPathComponent("native-\(destination.rawValue)-\(dark ? "dark" : "light")-\(Int(scale))x.png"))
                    }
                    #expect(abs(dx) <= 0.5 / scale, "\(destination) in List x \(dx) at \(scale)x")
                    #expect(abs(dy) <= 0.5 / scale, "\(destination) in List y \(dy) at \(scale)x")
                }
            }
        }
        print(csv)
        if let directory { try csv.write(toFile: directory + "/native-list-measurements.csv", atomically: true, encoding: .utf8) }
    }
}
