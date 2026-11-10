import AppKit
import CryptoKit
import ImageIO
import SwiftUI
import Testing
import UniformTypeIdentifiers
@testable import BetterTileCore
@testable import BetterTileMacOS

/// The only artwork generator. Product code never imports this reference path.
@MainActor enum GlyphMaskReference {
    static var wheelSlots: [LayoutWheelSlot] {
        WindowAction.allCases.map { .init(command: .windowAction($0)) }
        + LayoutGlyph.all.map { .init(label: $0.title, symbolName: "", glyph: $0, isEmpty: false, isAvailable: true) }
        + [LayoutWheelCommand.repairBento, .savedLayouts, .savedLayout(file: "Fixture.json", name: "Fixture"),
           .moreSavedLayouts, .moreLayoutChoices].map { .init(command: $0) }
        + [.init(label: "Legacy Grid", symbolName: "rectangle.split.3x2", isEmpty: false, isAvailable: true), .empty]
    }

    static var catalog: [String: LayoutWheelSlot] {
        var result: [String: LayoutWheelSlot] = [:]
        let modes: [LayoutMode?] = [nil] + LayoutMode.availableModes.map(Optional.some)
        let parents = LayoutWheelSector.allCases.flatMap { sector in
            modes.map { mode in
                var configuration = LayoutWheelConfiguration(style: .grouped, levelCount: .one)
                configuration.groupOverrides[sector.rawValue] = .init(quickAction: nil, options: [.windowAction(.leftHalf)])
                let scene = LayoutWheelSceneInput(configuration: configuration, currentMode: mode)
                return scene.slot(.sector(.init(ring: configuration.groupRing, sector: sector)))
            }
        }
        for slot in wheelSlots + parents { result[GlyphMaskStore.wheelID(slot)] = slot }
        return result
    }

    static var wheelSizes: [Double] {
        var sizes: Swift.Set<Double> = []
        for style in [LayoutWheelStyle.custom, .grouped] {
            for levels in [LayoutWheelLevelCount.one, .two] {
                for size in LayoutWheelSize.allCases {
                    let config = LayoutWheelConfiguration(style: style, levelCount: levels, appearance: .init(size: size))
                    let content = LayoutWheelLiquidDefaults.content(configuration: config)
                    for index in content.rings.indices { sizes.insert(content.iconSymbolSize(ringIndex: index)) }
                    if content.submenuLayout != nil { sizes.insert(content.fanIconSymbolSize) }
                }
            }
        }
        return sizes.sorted()
    }

    static var sizedContents: [LayoutWheelLiquidContent] {
        LayoutWheelSize.allCases.map {
            LayoutWheelLiquidDefaults.content(configuration: .init(appearance: .init(size: $0)))
        }
    }

    static func pixels(_ image: CGImage) throws -> [UInt8] {
        let context = try #require(CGContext(data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.setBlendMode(.copy)
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Array(UnsafeBufferPointer(start: context.data!.assumingMemoryBound(to: UInt8.self),
                                        count: image.width * image.height * 4))
    }

    static func render(set: GlyphMaskStore.Set, slot: LayoutWheelSlot, pointSize: Double,
                       scale: Double, dark: Bool, opaque: Bool = false) throws -> CGImage {
        switch set {
        case .wheel:
            // Match the original wheel path: its ink is explicit and only the
            // SwiftUI colour-scheme environment changes, not NSApp.appearance.
            let color = opaque ? NSColor.white : (dark ? NSColor.white.withAlphaComponent(0.94)
                : NSColor.black.withAlphaComponent(0.86))
            let side = 35 / 18 * pointSize
            let renderer = ImageRenderer(content: LayoutWheelIcon(slot: slot, tint: Color(nsColor: color), fontSize: pointSize)
                .frame(width: side, height: side).environment(\.colorScheme, dark ? .dark : .light))
            renderer.scale = scale
            return try #require(renderer.cgImage.flatMap(LayoutWheelLiquidImages.rasterize))
        case .menuGlass:
            return try MenuGlassGlyphReference.render(action: slot.windowAction!, scale: scale, dark: dark)
        case .wheelSymbols:
            // These symbols already used AppKit in the original Metal path.
            // Capture that existing reference; a different SwiftUI symbol draw
            // would change its canvas and placement.
            let color = dark ? NSColor.white.withAlphaComponent(0.94) : NSColor.black.withAlphaComponent(0.86)
            let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
                .applying(.init(paletteColors: [color]))
            let symbol = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)?.withSymbolConfiguration(config)
            var rect = CGRect(origin: .zero, size: symbol?.size ?? CGSize(width: pointSize, height: pointSize))
            return try #require(symbol?.cgImage(forProposedRect: &rect, context: nil, hints: [.ctm: AffineTransform(scale: scale)]))
        case .wheelLabels:
            let content = try #require(sizedContents.first { $0.cancelTextSize == pointSize })
            return try originalCancelLabel(content, scale: scale, dark: dark)
        }
    }

    /// Frozen copy of the original native cancel-label composition. Its
    /// dynamic-name sibling remains native text in production.
    static func originalCancelLabel(_ content: LayoutWheelLiquidContent, scale: Double, dark: Bool) throws -> CGImage {
        let s = content.layout.scale
        let ink = dark ? NSColor.white.withAlphaComponent(0.94) : NSColor.black.withAlphaComponent(0.86)
        let mark = NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: content.cancelSymbolSize, weight: .semibold)
                .applying(.init(paletteColors: [ink])))
        let text = NSAttributedString(string: "Cancel", attributes: [.font: NSFont.systemFont(ofSize: content.cancelTextSize, weight: .medium), .foregroundColor: ink])
        let size = text.size(), markSize = mark?.size ?? .zero, gap = mark == nil ? 0 : 3 * s
        let width = ceil(max(size.width, markSize.width)) + 4
        let height = ceil(size.height + markSize.height + gap) + 2
        let pixelWidth = Int(ceil(width * scale)), pixelHeight = Int(ceil(height * scale))
        let context = try #require(CGContext(data: nil, width: pixelWidth, height: pixelHeight,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue))
        context.translateBy(x: 0, y: Double(pixelHeight)); context.scaleBy(x: scale, y: -scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        defer { NSGraphicsContext.restoreGraphicsState() }
        var y = 1.0
        if let mark {
            mark.draw(in: CGRect(x: (width - markSize.width) / 2, y: y, width: markSize.width, height: markSize.height))
            y += markSize.height + gap
        }
        text.draw(at: CGPoint(x: (width - size.width) / 2, y: y))
        return try #require(context.makeImage())
    }

    static func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    struct Sample {
        let image: CGImage
        let outputs: [Data: Int]
        var mode: Data {
            outputs.keys.sorted {
                let a = outputs[$0]!, b = outputs[$1]!
                return a == b ? $0.lexicographicallyPrecedes($1) : a > b
            }.first!
        }
    }

    /// Apply the same N=20 rule to every case, including deterministic artwork.
    static func sample(_ key: String, render: @MainActor () throws -> CGImage) throws -> Sample {
        var outputs: [Data: Int] = [:], images: [Data: CGImage] = [:]
        for _ in 0..<20 {
            try autoreleasepool {
                let image = try render(), bytes = Data(try pixels(image))
                outputs[bytes, default: 0] += 1
                images[bytes] = image
            }
        }
        let mode = outputs.keys.sorted {
            let a = outputs[$0]!, b = outputs[$1]!
            return a == b ? $0.lexicographicallyPrecedes($1) : a > b
        }.first!
        print("Glyph reference N=20 key=\(key) setSize=\(outputs.count) frequencies=\(outputs.values.sorted(by: >))")
        return Sample(image: images[mode]!, outputs: outputs)
    }

    static func png(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        try #require(CGImageDestinationFinalize(destination))
        return data as Data
    }

    static func encode(_ reference: CGImage) throws -> (GlyphMaskStore.Entry, Data) {
        let rgba = try pixels(reference)
        let payload = Data(rgba)
        let image = try #require(CGImage(width: reference.width, height: reference.height, bitsPerComponent: 8,
            bitsPerPixel: 32, bytesPerRow: reference.width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
            provider: CGDataProvider(data: payload as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let data = try png(image)
        let entry = GlyphMaskStore.Entry(file: "\(sha(data)).png", width: reference.width, height: reference.height,
                                        format: "rgba")
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let final = try #require(GlyphMaskStore.decode(decoded, entry: entry))
        #expect(try pixels(final) == rgba, "PNG storage must preserve every final RGBA byte.")
        return (entry, data)
    }

    static func command(_ executable: String, _ args: [String]) throws -> String {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable); process.arguments = args
        process.standardOutput = pipe; process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0)
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    /// One generated manifest entry or one measured SF Symbol ink size.
    enum Case {
        case entry(set: GlyphMaskStore.Set, id: String, slot: LayoutWheelSlot, size: Double, scale: Double, dark: Bool)
        case ink(symbol: String, size: Double)

        var key: String {
            switch self {
            case let .entry(set, id, _, size, scale, dark):
                GlyphMaskStore.key(set: set, id: id, pointSize: size, scale: scale, appearance: dark ? .dark : .light)
            case let .ink(symbol, size): GlyphMaskReference.inkKey(symbol, size)
            }
        }
    }

    /// Every case in generation order. Tests use it to check the inventory
    /// without rendering.
    static var cases: [Case] {
        var result: [Case] = []
        for id in catalog.keys.sorted() {
            let slot = catalog[id]!
            for size in wheelSizes {
                for scale in [1.0, 2.0] {
                    for dark in [false, true] { result.append(.entry(set: .wheel, id: id, slot: slot, size: size, scale: scale, dark: dark)) }
                }
                if id.hasPrefix("symbol:"), slot.symbolName != "rectangle.split.3x2" {
                    result.append(.ink(symbol: slot.symbolName, size: size))
                }
            }
        }
        for content in sizedContents {
            for scale in [1.0, 2.0] { for dark in [false, true] {
                result.append(.entry(set: .wheelSymbols, id: "chevron.right", slot: .empty,
                                     size: content.chevronSymbolSize, scale: scale, dark: dark))
                result.append(.entry(set: .wheelLabels, id: "cancel", slot: .empty,
                                     size: content.cancelTextSize, scale: scale, dark: dark))
            } }
        }
        for action in WindowAction.allCases {
            for scale in [1.0, 2.0] { for dark in [false, true] {
                result.append(.entry(set: .menuGlass, id: action.rawValue,
                                     slot: .init(command: .windowAction(action)), size: 20, scale: scale, dark: dark))
            } }
        }
        return result
    }

    nonisolated static func inkKey(_ symbol: String, _ size: Double) -> String { "\(symbol)|\(String(size.bitPattern, radix: 16))" }

    /// The drawn ink size of an SF Symbol in points, measured at 4x.
    static func measureInk(symbol: String, size: Double, samples count: Int = 20) throws -> [Double] {
        let render: @MainActor () throws -> CGImage = {
            let renderer = ImageRenderer(content: Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold)).symbolRenderingMode(.monochrome)
                .foregroundStyle(.white).fixedSize().padding(4))
            renderer.scale = 4
            return try #require(renderer.cgImage)
        }
        let image = count == 1 ? try render() : try sample("ink|\(inkKey(symbol, size))", render: render).image
        let bytes = try pixels(image)
        var minX = image.width, minY = image.height, maxX = -1, maxY = -1
        for y in 0..<image.height { for x in 0..<image.width where bytes[(y * image.width + x) * 4 + 3] > 0 {
            minX = min(minX, x); minY = min(minY, y); maxX = max(maxX, x); maxY = max(maxY, y)
        } }
        return [Double(maxX - minX + 1) / 4, Double(maxY - minY + 1) / 4]
    }

    /// Reference sources whose hashes the manifest records. A change to any
    /// of them requires regeneration on the generator host.
    static let sourcePaths = ["Tests/BetterTileMacOSTests/MenuGlassGlyphReference.swift", "Sources/BetterTileMacOS/LayoutWheelView.swift", "Sources/BetterTileMacOS/LayoutGlyphView.swift",
                              "Sources/BetterTileMacOS/WindowActionPartitionGlyph.swift", "Sources/BetterTileCore/LayoutGlyph.swift",
                              "Sources/BetterTileMacOS/LayoutWheelLiquidContent.swift",
                              "Tests/BetterTileMacOSTests/GlyphMaskReference.swift"]

    static func sourceHashes() throws -> [String: String] {
        var sources: [String: String] = [:]
        for path in sourcePaths { sources[path] = sha(try Data(contentsOf: root.appendingPathComponent(path))) }
        return sources
    }

    static func generate(acceptStoredMember: Bool = false, refreshing: GlyphMaskStore.Set? = nil) throws -> (GlyphMaskStore.Manifest, [String: Data]) {
        var entries: [String: GlyphMaskStore.Entry] = [:], files: [String: Data] = [:]
        var ink: [String: [Double]] = [:]
        var counts: [String: Int] = [:]
        let storedDirectory = acceptStoredMember ? try #require(GlyphMaskStore.resourceDirectory) : nil
        let storedManifest = try storedDirectory.map {
            try JSONDecoder().decode(GlyphMaskStore.Manifest.self,
                from: Data(contentsOf: $0.appendingPathComponent("manifest.json")))
        }
        @MainActor func add(set: GlyphMaskStore.Set, id: String, slot: LayoutWheelSlot, size: Double, scale: Double, dark: Bool) throws {
            let key = GlyphMaskStore.key(set: set, id: id, pointSize: size, scale: scale, appearance: dark ? .dark : .light)
            let samples = try sample(key) { try render(set: set, slot: slot, pointSize: size, scale: scale, dark: dark) }
            let image = samples.image
            var (entry, data) = try encode(image)
            if set != refreshing, let directory = storedDirectory, let stored = storedManifest?.entries[key] {
                let storedData = try Data(contentsOf: directory.appendingPathComponent(stored.file))
                let source = try #require(CGImageSourceCreateWithData(storedData as CFData, nil))
                let encoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
                let decoded = try #require(GlyphMaskStore.decode(encoded, entry: stored))
                let member = samples.outputs[Data(try pixels(decoded))] != nil
                    && decoded.width == image.width && decoded.height == image.height
                #expect(member, "Stored PNG must equal an observed N=20 reference output: \(key)")
                if member {
                    // Generation selects the mode. Freshness accepts any exact
                    // member, as requested, even if sampling changes its rank.
                    (entry, data) = try encode(decoded)
                    #expect(data == storedData, "PNG bytes must match canonical reference encoding: \(key)")
                }
            }
            entries[key] = entry
            files[entry.file] = data
            counts["\(set.rawValue).\(dark ? "dark" : "light").\(entry.format)", default: 0] += 1
        }
        for item in cases {
            switch item {
            case let .entry(set, id, slot, size, scale, dark):
                try autoreleasepool { try add(set: set, id: id, slot: slot, size: size, scale: scale, dark: dark) }
            case let .ink(symbol, size):
                ink[item.key] = try autoreleasepool { try measureInk(symbol: symbol, size: size) }
            }
        }
        // The generator host. Tests compare these fields only to choose exact
        // or tolerance mode; they never fail on a different host.
        let platform = ["macOS": try command("/usr/bin/sw_vers", ["-productVersion"]),
                        "build": try command("/usr/bin/sw_vers", ["-buildVersion"]),
                        "architecture": try command("/usr/bin/arch", []),
                        "toolchain": try command("/usr/bin/xcrun", ["swift", "--version"]),
                        "sampling": "N=20; most frequent final RGBA; lexicographic byte tie break; exact set membership"]
        return (.init(version: 3, platform: platform, sources: try sourceHashes(), entries: entries, symbolInkSizes: ink, findings: counts), files)
    }
}
