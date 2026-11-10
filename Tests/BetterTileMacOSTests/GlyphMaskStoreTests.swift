import Accelerate
import AppKit
import BetterTileTestSupport
import CryptoKit
import ImageIO
import SwiftUI
import Testing
import UniformTypeIdentifiers
@testable import BetterTileCore
@testable import BetterTileMacOS

extension GlyphMaskReference {
    static func storedManifest() throws -> GlyphMaskStore.Manifest {
        let directory = try #require(GlyphMaskStore.resourceDirectory)
        return try JSONDecoder().decode(GlyphMaskStore.Manifest.self,
                                        from: Data(contentsOf: directory.appendingPathComponent("manifest.json")))
    }

    private static var cachedMode: GlyphMaskTestMode?

    /// Exact on the generator host, tolerance everywhere else.
    static func mode() throws -> GlyphMaskTestMode {
        if let cachedMode { return cachedMode }
        let mode = GlyphMaskTestMode.current(generator: try storedManifest().platform)
        cachedMode = mode
        return mode
    }

    static func storedImage(_ key: String, _ entry: GlyphMaskStore.Entry) throws -> CGImage {
        let directory = try #require(GlyphMaskStore.resourceDirectory)
        let data = try Data(contentsOf: directory.appendingPathComponent(entry.file))
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let encoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        return try #require(GlyphMaskStore.decode(encoded, entry: entry), "\(key) does not decode")
    }

    static func difference(_ a: CGImage, _ b: CGImage) throws -> GlyphRasterDifference {
        GlyphRasterDifference(try pixels(a), width: a.width, height: a.height,
                              try pixels(b), width: b.width, height: b.height)
    }
}

/// The worst tolerance result of one test, logged so a reader can see the margin.
private struct ToleranceLog {
    var cases = 0, emptyLive = 0
    var worst: (key: String, difference: GlyphRasterDifference)?

    mutating func add(_ key: String, _ difference: GlyphRasterDifference) {
        cases += 1
        if worst.map({ difference.inkDifference > $0.difference.inkDifference }) ?? true { worst = (key, difference) }
    }

    func print(_ test: String) {
        var summary: String = "none"
        if let worst { summary = "\(worst.key): \(worst.difference)" }
        Swift.print("Glyph mask tolerance test=\(test) cases=\(cases) emptyLiveRenders=\(emptyLive) worst=\(summary)")
    }
}

@MainActor @Suite(.macOSTestApplication, .serialized)
struct GlyphMaskStoreTests {
    @Test func shippedResourcesAreFreshOrRegenerateExplicitly() throws {
        let output = ProcessInfo.processInfo.environment["BT_GENERATE_GLYPH_MASKS"]
        if let output {
            let (manifest, files) = try GlyphMaskReference.generate()
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let directory = URL(fileURLWithPath: output, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for name in files.keys.sorted() { try files[name]!.write(to: directory.appendingPathComponent(name)) }
            try encoder.encode(manifest).write(to: directory.appendingPathComponent("manifest.json"))
            for name in try FileManager.default.contentsOfDirectory(atPath: directory.path)
                where name.count == 68 && name.hasSuffix(".png") && files[name] == nil {
                try FileManager.default.removeItem(at: directory.appendingPathComponent(name))
            }
            return
        }
        let mode = try GlyphMaskReference.mode()
        mode.log("freshness")
        let directory = try #require(GlyphMaskStore.resourceDirectory)
        let stored = try GlyphMaskReference.storedManifest()

        // These checks do not depend on the host.
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        #expect(try encoder.encode(stored) == Data(contentsOf: directory.appendingPathComponent("manifest.json")),
                "The manifest must use the generator's canonical JSON encoding.")
        #expect(stored.sources == (try GlyphMaskReference.sourceHashes()),
                "A reference source changed. Regenerate with Tools/generate-glyph-masks.sh on the generator host.")
        var entryKeys: Swift.Set<String> = [], inkKeys: Swift.Set<String> = []
        for item in GlyphMaskReference.cases {
            if case .ink = item { inkKeys.insert(item.key) } else { entryKeys.insert(item.key) }
        }
        #expect(Swift.Set(stored.entries.keys) == entryKeys, "The catalogue changed. Regenerate the glyph masks.")
        #expect(Swift.Set(stored.symbolInkSizes.keys) == inkKeys, "The symbol catalogue changed. Regenerate the glyph masks.")
        var counts: [String: Int] = [:]
        for (key, entry) in stored.entries.sorted(by: { $0.key < $1.key }) {
            let parts = key.split(separator: "|")
            counts["\(parts[0]).\(parts[4]).\(entry.format)", default: 0] += 1
            let data = try Data(contentsOf: directory.appendingPathComponent(entry.file))
            #expect(GlyphMaskReference.sha(data) + ".png" == entry.file, "\(key): file name must be its SHA-256")
            let image = try GlyphMaskReference.storedImage(key, entry)
            try Self.checkSemantics(key, image)
        }
        #expect(counts == stored.findings)
        let pngs = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".png") }
        #expect(Swift.Set(pngs) == Swift.Set(stored.entries.values.map(\.file)), "Remove obsolete generated PNGs.")

        if mode.isExact {
            // Regenerate with N=20 sampling and require the shipped bytes.
            let (manifest, files) = try GlyphMaskReference.generate(acceptStoredMember: true)
            #expect(manifest.version == stored.version)
            #expect(manifest.entries == stored.entries, "Stale entries. Regenerate with Tools/generate-glyph-masks.sh.")
            #expect(manifest.symbolInkSizes == stored.symbolInkSizes, "Stale symbol ink sizes.")
            #expect(manifest.findings == stored.findings)
            for file in files.keys.sorted() {
                #expect(try Data(contentsOf: directory.appendingPathComponent(file)) == files[file], "Stale mask: \(file)")
            }
        } else {
            // One live measurement per symbol. SF Symbols can change between
            // releases; the shipped sizes stay the generator's by policy.
            var worst = 0.0
            for item in GlyphMaskReference.cases {
                guard case let .ink(symbol, size) = item, let recorded = stored.symbolInkSizes[item.key] else { continue }
                let live = try GlyphMaskReference.measureInk(symbol: symbol, size: size, samples: 1)
                let drawn: Bool = !live.contains { (value: Double) -> Bool in value <= 0 }
                guard drawn else {
                    print("Glyph mask tolerance: \(symbol) draws nothing on this host; the recorded size ships by policy.")
                    continue
                }
                var delta: Double = 0
                for (measured, stored) in zip(live, recorded) { delta = max(delta, abs(measured - stored)) }
                worst = max(worst, delta)
                #expect(delta <= Self.inkSizeLimit, "\(item.key): live \(live), recorded \(recorded)")
            }
            print("Glyph mask tolerance test=inkSizes cases=\(inkKeys.count) worstDelta=\(worst)pt limit=\(Self.inkSizeLimit)pt")
        }
    }

    /// Largest accepted difference, in points, between a live and a recorded
    /// symbol ink size on a host other than the generator.
    static let inkSizeLimit = 1.0

    /// The ink colour and template rules that every stored PNG keeps on every host.
    static func checkSemantics(_ key: String, _ image: CGImage) throws {
        let parts = key.split(separator: "|")
        let set = try #require(GlyphMaskStore.Set(rawValue: String(parts[0])))
        let dark = parts[4] == "dark", scale = try #require(Double(parts[3]))
        let bytes: [UInt8] = try GlyphMaskReference.pixels(image)
        let premultiplied: Bool = Self.isPremultiplied(bytes)
        #expect(premultiplied, "\(key): channels must be premultiplied")
        let peak: Int = Self.peakAlpha(bytes)
        switch set {
        case .menuGlass:
            let width: Int = Int(30 * scale), height: Int = Int(26 * scale)
            let sized: Bool = image.width == width && image.height == height
            #expect(sized, "\(key): template size")
            #expect(peak == 255, "\(key): template coverage must reach full alpha")
            let black: Bool = Self.isBlackCoverage(bytes)
            #expect(black, "\(key): a template stores black coverage")
        case .wheel, .wheelSymbols, .wheelLabels:
            // Overlapping layers can exceed the tint's alpha, so only the
            // colour of covered pixels is fixed.
            if set == .wheel { #expect(image.width == image.height, "\(key): wheel icons are square") }
            if let ink = GlyphRasterDifference.inkColor(bytes) {
                let expected: Int = dark ? 255 : 0
                var matches: Bool = true
                for channel: Int in ink where abs(channel - expected) > GlyphRasterDifference.inkColorLimit { matches = false }
                #expect(matches, "\(key): ink \(ink) must be the \(dark ? "dark" : "light") wheel ink")
            }
        }
    }

    /// Every colour channel is at most its alpha.
    static func isPremultiplied(_ bytes: [UInt8]) -> Bool {
        var offset: Int = 0
        while offset + 3 < bytes.count {
            let alpha: UInt8 = bytes[offset + 3]
            if bytes[offset] > alpha || bytes[offset + 1] > alpha || bytes[offset + 2] > alpha { return false }
            offset += 4
        }
        return true
    }

    /// Every colour channel is zero, as a template stores it.
    static func isBlackCoverage(_ bytes: [UInt8]) -> Bool {
        var offset: Int = 0
        while offset + 3 < bytes.count {
            if bytes[offset] != 0 || bytes[offset + 1] != 0 || bytes[offset + 2] != 0 { return false }
            offset += 4
        }
        return true
    }

    static func peakAlpha(_ bytes: [UInt8]) -> Int {
        var peak: UInt8 = 0
        var offset: Int = 3
        while offset < bytes.count {
            peak = max(peak, bytes[offset])
            offset += 4
        }
        return Int(peak)
    }

    @Test func wheelFinalRGBAIsExactAtEveryComputedMetalSize() throws {
        var log = ToleranceLog()
        for size in GlyphMaskReference.wheelSizes {
            for scale in [1.0, 2.0] { for dark in [false, true] { for slot in GlyphMaskReference.wheelSlots {
                try autoreleasepool { try compare(set: .wheel, id: GlyphMaskStore.wheelID(slot), slot: slot, size: size, scale: scale, dark: dark, log: &log) }
            } } }
        }
        try finish("wheelSlots", log)
    }

    @Test func menuGlassCoverageIsExactAndOpaqueAtBothScales() throws {
        var log = ToleranceLog()
        for action in WindowAction.allCases { for scale in [1.0, 2.0] { for dark in [false, true] {
            try compare(set: .menuGlass, id: action.rawValue, slot: .init(command: .windowAction(action)), size: 20, scale: scale, dark: dark, log: &log)
            let image = try #require(GlyphMaskStore.image(set: .menuGlass, id: action.rawValue, pointSize: 20, scale: scale, appearance: dark ? .dark : .light))
            try Self.checkSemantics(GlyphMaskStore.key(set: .menuGlass, id: action.rawValue, pointSize: 20, scale: scale,
                                                       appearance: dark ? .dark : .light), image)
        } } }
        try finish("menuGlass", log)
    }

    @Test func existingNamespaceEntryHashesRemainUnchanged() throws {
        let expected: [String: String] = [
            "menu-glass": "6f904f905958ff2b89d568f647d73874c2ca3a905c4efe0dc2feb499e4ddb0d0",
            "wheel": "4e3f116c17fcf1c28bb49c2358f6627fb0c3615916233e24e08ce849141c8753",
            "wheelLabels": "0b24522e70bf547430c976eeb3c4537b2dcb37603888994513381d1df81f9c17",
            "wheelSymbols": "2f8eb5bd5cdb4a3b347095d77864b58a16782429c8850c77776e8d55ffa47cf3"]
        let directory = try #require(GlyphMaskStore.resourceDirectory)
        let manifest = try GlyphMaskReference.storedManifest()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var namespaces: Swift.Set<String> = []
        for key: String in manifest.entries.keys { namespaces.insert(String(key.prefix { $0 != "|" })) }
        let expectedNamespaces: Swift.Set<String> = Swift.Set(expected.keys)
        #expect(namespaces == expectedNamespaces)
        for (name, hash) in expected {
            let entries = manifest.entries.filter { $0.key.hasPrefix(name + "|") }
            let actual = GlyphMaskReference.sha(try encoder.encode(entries))
            #expect(actual == hash, "\(name) entries hash \(actual)")
            for entry in entries.values {
                #expect(GlyphMaskReference.sha(try Data(contentsOf: directory.appendingPathComponent(entry.file))) + ".png" == entry.file)
            }
        }
    }

    @Test func everyGeneratedWheelSizeAndGroupParentIsExact() throws {
        var log = ToleranceLog()
        for (id, slot) in GlyphMaskReference.catalog { for size in GlyphMaskReference.wheelSizes {
            for scale in [1.0, 2.0] { for dark in [false, true] {
                try autoreleasepool { try compare(set: .wheel, id: id, slot: slot, size: size, scale: scale, dark: dark, log: &log) }
            } }
        } }
        try finish("wheelCatalog", log)
    }

    @Test func centreSymbolsMatchAnObservedReferenceOutput() throws {
        var log = ToleranceLog()
        for content in GlyphMaskReference.sizedContents {
            for scale in [1.0, 2.0] { for dark in [false, true] {
                try compare(set: .wheelSymbols, id: "chevron.right", slot: .empty,
                            size: content.chevronSymbolSize, scale: scale, dark: dark, log: &log)
                try compare(set: .wheelLabels, id: "cancel", slot: .empty,
                            size: content.cancelTextSize, scale: scale, dark: dark, log: &log)
            } }
        }
        try finish("centre", log)
    }

    /// The tolerance limit alone could accept a similar glyph. On every host,
    /// each stored glyph must also be closer to its own live render than to
    /// the live render of any other glyph in its group.
    @Test func eachStoredGlyphIsNearestToItsOwnLiveRender() throws {
        let mode = try GlyphMaskReference.mode()
        mode.log("identity")
        let manifest = try GlyphMaskReference.storedManifest()
        var groups: [String: [(id: String, key: String, set: GlyphMaskStore.Set, slot: LayoutWheelSlot,
                               size: Double, scale: Double, dark: Bool)]] = [:]
        for item in GlyphMaskReference.cases {
            guard case let .entry(set, id, slot, size, scale, dark) = item, set == .wheel || set == .menuGlass else { continue }
            groups["\(set.rawValue)|\(size)|\(scale)|\(dark)", default: []].append((id, item.key, set, slot, size, scale, dark))
        }
        var checked = 0, skipped = 0, worstOwn = 0.0, closestOther = Double.infinity, closestPair = ""
        for (_, members) in groups.sorted(by: { $0.key < $1.key }) {
            var live: [[Float]] = [], stored: [[Float]] = [], liveBytes: [Data] = [], totals: [(Float, Float)] = []
            for member in members {
                try autoreleasepool {
                    let reference = try GlyphMaskReference.render(set: member.set, slot: member.slot, pointSize: member.size,
                                                                  scale: member.scale, dark: member.dark)
                    let image = try GlyphMaskReference.storedImage(member.key, try #require(manifest.entries[member.key]))
                    try #require(reference.width == image.width && reference.height == image.height,
                                 "\(member.key): live size \(reference.width)×\(reference.height), stored \(image.width)×\(image.height)")
                    let r = try GlyphMaskReference.pixels(reference), s = try GlyphMaskReference.pixels(image)
                    live.append(Self.alpha(r)); stored.append(Self.alpha(s)); liveBytes.append(Data(r))
                    totals.append((vDSP.sum(live.last!), vDSP.sum(stored.last!)))
                }
            }
            for i in members.indices {
                if totals[i].0 == 0 { skipped += 1; continue }
                let own = Self.inkDifference(stored[i], totals[i].1, live[i], totals[i].0)
                worstOwn = max(worstOwn, own)
                for j in members.indices where j != i && liveBytes[j] != liveBytes[i] {
                    let other = Self.inkDifference(stored[i], totals[i].1, live[j], totals[j].0)
                    if other < closestOther { closestOther = other; closestPair = "\(members[i].key) vs \(members[j].id)" }
                    #expect(own < other, "\(members[i].key) is closer to \(members[j].id): own \(own), other \(other)")
                }
                checked += 1
            }
        }
        print("Glyph mask identity checked=\(checked) emptyLiveSkipped=\(skipped) worstOwn=\(worstOwn) closestOther=\(closestOther) (\(closestPair)) limit=\(GlyphRasterDifference.inkDifferenceLimit)")
        #expect(checked > 1_500)
    }

    /// The store reads the folder that Package.swift copies into the
    /// target's own SwiftPM resource bundle, found by Bundle.module.
    @Test func resourcesResolveInsideTheTargetResourceBundle() throws {
        let directory: URL = try #require(GlyphMaskStore.resourceDirectory)
        let bundleName: String = directory.deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().lastPathComponent
        #expect(directory.lastPathComponent == "GlyphMasks")
        #expect(bundleName == "BetterTile_BetterTileMacOS.bundle", "\(directory.path)")
        let manifest: Bool = FileManager.default.fileExists(atPath: directory.appendingPathComponent("manifest.json").path)
        #expect(manifest)
        print("Glyph mask resources: \(directory.path)")
    }

    @Test func missingArtworkAndUnsupportedSizesAreExplicit() {
        #expect(GlyphMaskStore.image(set: .menuGlass, id: "missing", pointSize: 20, scale: 1, appearance: .light) == nil)
        #expect(GlyphMaskStore.image(set: .menuGlass, id: WindowAction.maximize.rawValue, pointSize: 19.8, scale: 1, appearance: .light) == nil)
    }

    @Test func toleranceModeIsChosenOnlyByTheHostFields() {
        let generator = ["macOS": "27.0.1", "build": "26A434", "architecture": "arm64", "toolchain": "Swift 6.4.2",
                         "sampling": "N=20"]
        #expect(GlyphMaskTestMode.current(generator: generator, environment: [:], host: {
            ["macOS": "27.0.1", "build": "26A434", "architecture": "arm64", "toolchain": "Swift 6.4.2"]
        }) == .exact)
        for (key, value) in [("build", "25A100"), ("architecture", "x86_64"), ("toolchain", "Swift 6.4.3")] {
            var host = generator; host[key] = value
            #expect(!GlyphMaskTestMode.current(generator: generator, environment: [:], host: { host }).isExact, "\(key)")
        }
        #expect(GlyphMaskTestMode.current(generator: generator, environment: ["BT_GLYPH_MASK_TEST_MODE": "tolerance"],
                                          host: { generator }) == .tolerance(reason: "BT_GLYPH_MASK_TEST_MODE=tolerance"))
        #expect(GlyphMaskTestMode.current(generator: generator, environment: ["BT_GLYPH_MASK_TEST_MODE": "exact"],
                                          host: { [:] }) == .exact)
    }

    @Test func toleranceDifferenceMeasuresCoverageAndInk() {
        func raster(_ width: Int, _ height: Int, alpha: (Int, Int) -> UInt8, ink: UInt8 = 0) -> [UInt8] {
            var bytes: [UInt8] = []
            for y: Int in 0..<height { for x: Int in 0..<width {
                let a: UInt8 = alpha(x, y)
                let product: Int = Int(ink) * Int(a)
                let channel: UInt8 = UInt8(product / 255)
                bytes.append(channel); bytes.append(channel); bytes.append(channel); bytes.append(a)
            } }
            return bytes
        }
        let square = raster(10, 10) { x, _ in x < 5 ? 255 : 0 }
        let same = GlyphRasterDifference(square, width: 10, height: 10, square, width: 10, height: 10)
        #expect(same.inkDifference == 0)
        #expect(same.inkColorDelta == 0)
        #expect(same.isWithinLimits)
        let other = raster(10, 10) { x, _ in x >= 5 ? 255 : 0 }
        #expect(GlyphRasterDifference(square, width: 10, height: 10, other, width: 10, height: 10).inkDifference == 2)
        let white = raster(10, 10, alpha: { x, _ in x < 5 ? 255 : 0 }, ink: 255)
        let inverted = GlyphRasterDifference(square, width: 10, height: 10, white, width: 10, height: 10)
        #expect(inverted.inkDifference == 0)
        #expect(inverted.inkColorDelta == 255)
        #expect(!inverted.isWithinLimits)
        let wider = raster(12, 10) { x, _ in (1..<6).contains(x) ? 255 : 0 }
        let padded = GlyphRasterDifference(square, width: 10, height: 10, wider, width: 12, height: 10)
        #expect(padded.inkDifference == 0)
        #expect(padded.sizeDelta == 2)
        #expect(padded.isWithinLimits)
        let empty = raster(10, 10) { _, _ in 0 }
        #expect(GlyphRasterDifference(square, width: 10, height: 10, empty, width: 10, height: 10).oneSideEmpty)
    }

    @Test func rgbaArtworkSurvivesPNGRoundTripWithoutLosingPremultipliedChannels() throws {
        // Exercise the RGBA alternative even if today's semantic ink happens
        // to fit an alpha mask. Every alpha value includes fractional colours.
        var rgba = Data()
        for alpha in 0...255 {
            rgba.append(contentsOf: [UInt8(alpha / 3), UInt8(alpha / 2), UInt8(alpha), UInt8(alpha)])
        }
        let image = try #require(CGImage(width: 256, height: 1, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: 256 * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
            provider: CGDataProvider(data: rgba as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let (entry, data) = try GlyphMaskReference.encode(image)
        #expect(entry.format == "rgba")
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let actual = try #require(GlyphMaskStore.decode(decoded, entry: entry))
        #expect(try GlyphMaskReference.pixels(actual) == Array(rgba))
    }

    @Test func sharedCacheIsBoundedAndClearingItReleasesOwnedPixels() throws {
        GlyphMaskStore.removeCachedImages()
        // 164 menu-glass images decode to more than the 1 MiB bound.
        for action in WindowAction.allCases { for scale in [1.0, 2.0] { for dark in [false, true] {
            _ = GlyphMaskStore.image(set: .menuGlass, id: action.rawValue, pointSize: 20, scale: scale, appearance: dark ? .dark : .light)
            #expect(GlyphMaskStore.cachedDecodedBytes <= 1_048_576)
        } } }
        weak var weakImage: CGImage?
        autoreleasepool {
            let image = GlyphMaskStore.image(set: .menuGlass, id: WindowAction.maximize.rawValue, pointSize: 20, scale: 2, appearance: .dark)
            weakImage = image
            #expect(image === GlyphMaskStore.image(set: .menuGlass, id: WindowAction.maximize.rawValue, pointSize: 20, scale: 2, appearance: .dark))
        }
        #expect(weakImage != nil)
        GlyphMaskStore.removeCachedImages()
        #expect(weakImage == nil)
        #expect(GlyphMaskStore.cachedDecodedBytes == 0)
    }

    private func finish(_ test: String, _ log: ToleranceLog) throws {
        let mode = try GlyphMaskReference.mode()
        mode.log(test)
        if !mode.isExact { log.print(test) }
    }

    private static func maxChannelDelta(_ a: [UInt8], _ b: [UInt8]) -> Int {
        var largest: Int = 0
        for (left, right) in zip(a, b) { largest = max(largest, abs(Int(left) - Int(right))) }
        return largest
    }

    private static func alpha(_ pixels: [UInt8]) -> [Float] {
        var result: [Float] = []
        result.reserveCapacity(pixels.count / 4)
        var offset: Int = 3
        while offset < pixels.count { result.append(Float(pixels[offset])); offset += 4 }
        return result
    }

    /// GlyphRasterDifference.inkDifference for two equal-size alpha planes.
    private static func inkDifference(_ a: [Float], _ aTotal: Float, _ b: [Float], _ bTotal: Float) -> Double {
        Double(vDSP.sum(vDSP.absolute(vDSP.subtract(a, b)))) / Double(max(aTotal, bTotal, 1))
    }

    private func compare(set: GlyphMaskStore.Set, id: String, slot: LayoutWheelSlot, size: Double, scale: Double,
                         dark: Bool, log: inout ToleranceLog) throws {
        let key = GlyphMaskStore.key(set: set, id: id, pointSize: size, scale: scale, appearance: dark ? .dark : .light)
        let image: CGImage
        if set == .wheel {
            var images = LayoutWheelLiquidImages()
            let drawn = images.icon(slot, symbol: size,
                color: dark ? .white.withAlphaComponent(0.94) : .black.withAlphaComponent(0.86), dark: dark, scale: scale)
            image = try #require(drawn)
        } else if set == .wheelLabels {
            var images = LayoutWheelLiquidImages()
            let content = try #require(GlyphMaskReference.sizedContents.first { $0.cancelTextSize == size })
            let drawn = images.label(nil, content: content,
                color: dark ? .white.withAlphaComponent(0.94) : .black.withAlphaComponent(0.86), scale: scale)
            image = try #require(drawn)
        } else if set == .wheelSymbols {
            var images = LayoutWheelLiquidImages()
            let drawn = images.chevron(size: size,
                color: dark ? .white.withAlphaComponent(0.94) : .black.withAlphaComponent(0.86), scale: scale)
            image = try #require(drawn)
        } else {
            image = try #require(GlyphMaskStore.image(set: set, id: id, pointSize: size, scale: scale, appearance: dark ? .dark : .light))
        }
        guard try GlyphMaskReference.mode().isExact else {
            // One live render. The bundled image ships unchanged on this host,
            // so it must stay the same glyph within the stated limits.
            let live = try GlyphMaskReference.render(set: set, slot: slot, pointSize: size, scale: scale, dark: dark)
            let difference = try GlyphMaskReference.difference(image, live)
            let livePixels = try GlyphMaskReference.pixels(live)
            if difference.oneSideEmpty, !stride(from: 3, to: livePixels.count, by: 4).contains(where: { livePixels[$0] > 0 }) {
                log.emptyLive += 1
                print("Glyph mask tolerance: \(key) draws nothing live on this host; the bundled artwork ships by policy.")
                return
            }
            log.add(key, difference)
            #expect(difference.isWithinLimits, "\(key): \(difference)")
            return
        }
        let samples = try GlyphMaskReference.sample(key) {
            try GlyphMaskReference.render(set: set, slot: slot, pointSize: size, scale: scale, dark: dark)
        }
        let reference = samples.image
        #expect(image.width == reference.width)
        #expect(image.height == reference.height)
        let expected = try GlyphMaskReference.pixels(reference), actual = try GlyphMaskReference.pixels(image)
        if let path = ProcessInfo.processInfo.environment["BT_GLYPH_MASK_DIAGNOSTICS"] {
            let directory = URL(fileURLWithPath: path, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let filename = GlyphMaskReference.sha(Data(key.utf8))
            let bitmaps: [(String, CGImage)] = [("reference", reference), ("stored", image)]
            for (suffix, bitmap) in bitmaps {
                try GlyphMaskReference.png(bitmap).write(to: directory.appendingPathComponent("\(filename)-\(suffix).png"))
            }
            var changedPixels: Int = 0
            var offset: Int = 0
            while offset + 3 < actual.count {
                if actual[offset..<(offset + 4)] != expected[offset..<(offset + 4)] { changedPixels += 1 }
                offset += 4
            }
            let exact: Bool = samples.outputs[Data(actual)] != nil
            var record: [String: Any] = [:]
            record["set"] = set.rawValue
            record["id"] = id
            record["pointSize"] = size
            record["scale"] = scale
            record["dark"] = dark
            record["exact"] = exact
            record["setSize"] = samples.outputs.count
            record["file"] = filename
            record["changedPixels"] = changedPixels
            record["maxChannelDelta"] = Self.maxChannelDelta(actual, expected)
            try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
                .write(to: directory.appendingPathComponent("\(filename).json"))
        }
        #expect(samples.outputs[Data(actual)] != nil,
                "\(set.rawValue):\(id) \(size)pt \(scale)x dark=\(dark)")
    }
}
