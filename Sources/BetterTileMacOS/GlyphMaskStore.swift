import CoreGraphics
import BetterTileCore
import Foundation
import ImageIO

private final class GlyphMaskBundleFinder {}

/// Exact, appearance-resolved artwork. Returned images already contain their
/// final ink; callers must not retint existing sets. menuGlass alone supplies
/// black template coverage and must be wrapped as an AppKit template image.
public enum GlyphMaskStore {
    public enum Set: String, Sendable { case wheel, menuActions, wheelSymbols, wheelLabels; case menuGlass = "menu-glass" }
    public enum Appearance: String, Codable, Sendable { case light, dark }

    struct Entry: Codable, Equatable {
        let file: String
        let width: Int
        let height: Int
        /// Per-appearance RGBA PNGs preserve final sRGB ink and alpha.
        let format: String
    }

    struct Manifest: Codable {
        let version: Int
        let platform: [String: String]
        let sources: [String: String]
        let entries: [String: Entry]
        let symbolInkSizes: [String: [Double]]
        let findings: [String: Int]
    }

    static func key(set: Set, id: String, pointSize: Double, scale: Double, appearance: Appearance) -> String {
        "\(set.rawValue)|\(id)|\(String(pointSize.bitPattern, radix: 16))|\(scale)|\(appearance.rawValue)"
    }

    @MainActor static func wheelID(_ slot: LayoutWheelSlot) -> String {
        if let glyph = slot.glyph?.canonical {
            switch glyph {
            case .layout(let preset): return "layout:\(preset.rawValue)"
            case .mode(let mode): return "mode:\(mode.rawValue)"
            case .layouts: return "layouts"
            }
        }
        if let action = slot.windowAction, WindowActionPartitionGlyph.actions[action] != nil {
            return "action:\(action.rawValue)"
        }
        return "symbol:\(slot.symbolName)"
    }

    @MainActor private static var cache = LayoutWheelLiquidImageCache(limit: 1_048_576)
    private static let manifest: Manifest? = {
        guard let url = resourceDirectory?.appendingPathComponent("manifest.json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Manifest.self, from: data)
    }()

    static var resourceDirectory: URL? {
        // Match SwiftPM's bundle search without Bundle.module's fatal error
        // when an embedding application omitted its resource bundle.
        var candidates = [Bundle.main.resourceURL, Bundle(for: GlyphMaskBundleFinder.self).resourceURL,
                          Bundle.main.bundleURL]
        #if DEBUG
        if let path = ProcessInfo.processInfo.environment["PACKAGE_RESOURCE_BUNDLE_PATH"]
            ?? ProcessInfo.processInfo.environment["PACKAGE_RESOURCE_BUNDLE_URL"] {
            candidates.insert(URL(fileURLWithPath: path), at: 0)
        }
        #endif
        return candidates.lazy.compactMap { base in
            base.flatMap { Bundle(url: $0.appendingPathComponent("BetterTile_BetterTileMacOS.bundle")) }?
                .url(forResource: "GlyphMasks", withExtension: nil)
        }.first
    }

    /// A missing key returns nil. No symbol substitution, resampling or runtime
    /// SwiftUI rendering occurs. pointSize and scale must match generated keys.
    @MainActor public static func image(set: Set, id: String, pointSize: Double, scale: Double,
                                        appearance: Appearance) -> CGImage? {
        let key = key(set: set, id: id, pointSize: pointSize, scale: scale, appearance: appearance)
        if let image = cache[key] { return image }
        guard let entry = manifest?.entries[key], let directory = resourceDirectory,
              let source = CGImageSourceCreateWithURL(directory.appendingPathComponent(entry.file) as CFURL, nil),
              let encoded = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = decode(encoded, entry: entry) else { return nil }
        cache[key] = image
        return image
    }

    static func decode(_ encoded: CGImage, entry: Entry) -> CGImage? {
        guard entry.format == "rgba", encoded.width == entry.width, encoded.height == entry.height,
              encoded.bitsPerComponent == 8,
              let context = CGContext(data: nil, width: entry.width, height: entry.height,
                bitsPerComponent: 8, bytesPerRow: entry.width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
        else { return nil }
        context.setBlendMode(.copy)
        context.interpolationQuality = .none
        context.draw(encoded, in: CGRect(x: 0, y: 0, width: entry.width, height: entry.height))
        return context.makeImage()
    }

    static func symbolInkSize(_ name: String, pointSize: Double) -> CGSize? {
        guard let size = manifest?.symbolInkSizes["\(name)|\(String(pointSize.bitPattern, radix: 16))"], size.count == 2 else { return nil }
        return CGSize(width: size[0], height: size[1])
    }

    @MainActor static var cachedDecodedBytes: Int { cache.bytes }
    @MainActor static func removeCachedImages() { cache = LayoutWheelLiquidImageCache(limit: 1_048_576) }
}
