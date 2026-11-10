import AppKit
import BetterTileCore
@testable import BetterTileMacOS
import SwiftUI
import Testing
@testable import BetterTileApp

private struct MenuGlyphRasterCase: Sendable, CustomStringConvertible {
    let action: WindowAction
    let pointSize: Int
    let scale: Int
    let dark: Bool

    // The menu uses 20-point semibold artwork in a fixed 30×26-point frame.
    static let menuPointSizes = [20]
    static var all: [Self] {
        menuPointSizes.flatMap { size in
            WindowAction.allCases.flatMap { action in
                [1, 2].flatMap { scale in
                    [false, true].map { Self(action: action, pointSize: size, scale: scale, dark: $0) }
                }
            }
        }
    }

    var appearance: String { dark ? "dark" : "light" }
    var description: String { "\(action.rawValue)-\(pointSize)pt-\(scale)x-\(appearance)" }
}

private struct MenuGlyphRasterMeasurement: Encodable {
    let action: String
    let pointSize: Int
    let scale: Int
    let appearance: String
    let width: Int
    let height: Int
    let exactReferenceMember: Bool
    let referenceRenderCount: Int
    let referenceSetSize: Int
    let referenceFrequencies: [String: Int]
    let candidateSHA256: String
    let processIdentifier: Int32
    let applicationIsRunning: Bool
}

@Suite(.appTestApplication, .serialized) @MainActor
struct WindowActionTemplateTests {
    @Test func bundledMenuArtworkIsDiscoverable() throws {
        let directory = try #require(GlyphMaskStore.resourceDirectory)
        let data = try Data(contentsOf: directory.appending(path: "manifest.json"))
        let manifest = try JSONDecoder().decode(GlyphMaskStore.Manifest.self, from: data)
        let menu = manifest.entries.filter { $0.key.hasPrefix("menuActions|") }
        #expect(menu.count == 164)
        #expect(menu.values.allSatisfy { $0.format == "rgba" })
        _ = try #require(WindowActionGlyphCache.image(for: .leftHalf, scale: 1, appearance: .light))
    }

    @Test func everyActionReusesItsExactBitmap() throws {
        for action in WindowAction.allCases {
            for scale: CGFloat in [1, 2] {
                for appearance in [GlyphMaskStore.Appearance.light, .dark] {
                    let image = try #require(WindowActionGlyphCache.image(for: action, scale: scale, appearance: appearance))
                    #expect(image.width == Int(30 * scale) && image.height == Int(26 * scale))
                    #expect(image === WindowActionGlyphCache.image(for: action, scale: scale, appearance: appearance))
                }
            }
        }
    }

    @Test func unsupportedScaleDoesNotSubstituteArtwork() {
        #expect(WindowActionGlyphCache.image(for: .maximize, scale: 1.5, appearance: .light) == nil)
    }

    @Test func menuLookupContainsNoRuntimeRendererOrSymbolFallback() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let lookup = try String(contentsOf: root.appending(path: "Sources/BetterTileApp/WindowActionGlyphCache.swift"), encoding: .utf8)
        let store = try String(contentsOf: root.appending(path: "Sources/BetterTileMacOS/GlyphMaskStore.swift"), encoding: .utf8)
        let app = try String(contentsOf: root.appending(path: "Sources/BetterTileApp/BetterTileApp.swift"), encoding: .utf8)
        let glyph = try #require(app.range(of: "struct WindowActionGlyph: View {"))
        for source in [lookup, store] {
            #expect(!source.contains("import SwiftUI"))
            #expect(!source.contains("ImageRenderer"))
            #expect(!source.contains("NSHosting"))
        }
        #expect(!app.contains("ImageRenderer"))
        #expect(!app[glyph.lowerBound...].contains("LayoutWheelActionGlyph"))
        #expect(!app[glyph.lowerBound...].contains("systemName:"))
        #expect(app[glyph.lowerBound...].contains("renderingMode(.original)"))
    }

    @Test(arguments: MenuGlyphRasterCase.all)
    private func cachedMenuGlyphsExactlyMatchSwiftUIAtEveryMenuScaleAndAppearance(_ sample: MenuGlyphRasterCase) throws {
        _ = NSApplication.shared
        let previousAppearance = NSApp.appearance
        let appearance = try #require(NSAppearance(named: sample.dark ? .darkAqua : .aqua))
        NSApp.appearance = appearance
        defer { NSApp.appearance = previousAppearance }

        _ = try #require(WindowActionGlyphCache.image(for: sample.action, scale: CGFloat(sample.scale),
            appearance: sample.dark ? .dark : .light), "The exact comparison requires bundled menu pixels.")

        // Use the producer's unchanged sampler and renderer, copied byte for
        // byte in SharedGlyphMaskStoreTests.swift. No tolerance or separate
        // reference generator is introduced by this consumer test.
        let references = try GlyphMaskReference.sample("wired-menu|\(sample)") {
            try GlyphMaskReference.render(set: .menuActions,
                slot: .init(command: .windowAction(sample.action)),
                pointSize: Double(sample.pointSize), scale: Double(sample.scale), dark: sample.dark)
        }
        var candidateImage: CGImage?
        appearance.performAsCurrentDrawingAppearance {
            let renderer = ImageRenderer(content:
                WindowActionGlyph(action: sample.action)
                    .foregroundStyle(.primary).frame(width: 30, height: 26)
                    .environment(\.colorScheme, sample.dark ? .dark : .light)
                    .environment(\.displayScale, CGFloat(sample.scale)))
            renderer.scale = CGFloat(sample.scale)
            candidateImage = renderer.cgImage
        }
        let candidate = try canonical(try #require(candidateImage), scale: sample.scale)
        let payload = Data(candidate.bytes)
        let frequencies = Dictionary(uniqueKeysWithValues: references.outputs.map {
            (GlyphMaskReference.sha($0.key), $0.value)
        })
        let result = MenuGlyphRasterMeasurement(action: sample.action.rawValue, pointSize: sample.pointSize,
            scale: sample.scale, appearance: sample.appearance, width: candidate.image.width, height: candidate.image.height,
            exactReferenceMember: references.outputs[payload] != nil,
            referenceRenderCount: references.outputs.values.reduce(0, +), referenceSetSize: references.outputs.count,
            referenceFrequencies: frequencies, candidateSHA256: GlyphMaskReference.sha(payload),
            processIdentifier: ProcessInfo.processInfo.processIdentifier, applicationIsRunning: NSApp.isRunning)
        #expect(result.referenceRenderCount == 20)

        // The offline runner repeats this suite in five fresh processes and
        // verifies byte membership across their exported reference sets too.
        if let path = ProcessInfo.processInfo.environment["BT_WINDOW_ACTION_TEMPLATE_ARTIFACTS"] {
            let directory = URL(filePath: path)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(result).write(to: directory.appending(path: sample.description + ".json"), options: .atomic)
            try payload.write(to: directory.appending(path: sample.description + "-candidate.rgba"), options: .atomic)
            for output in references.outputs.keys {
                try output.write(to: directory.appending(path: sample.description + "-reference-" + GlyphMaskReference.sha(output) + ".rgba"), options: .atomic)
            }
            for (name, image) in [("reference", references.image), ("candidate", candidate.image)] {
                let data = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
                try data.write(to: directory.appending(path: sample.description + "-" + name + ".png"), options: .atomic)
            }
        }
        #expect(result.exactReferenceMember,
            "\(sample): candidate must equal one of \(result.referenceSetSize) observed outputs from the shared N=20 reference sampler")
    }

    private func canonical(_ image: CGImage, scale: Int) throws -> (image: CGImage, bytes: [UInt8]) {
        let width = 30 * scale, height = 26 * scale
        try #require(image.width == width && image.height == height)
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        context.setBlendMode(.copy)
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        return (try #require(context.makeImage()), Array(UnsafeBufferPointer(start: bytes, count: width * height * 4)))
    }
}
