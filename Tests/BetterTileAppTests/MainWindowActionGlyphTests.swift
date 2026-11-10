import AppKit
import BetterTileCore
@testable import BetterTileMacOS
import BetterTileTestSupport
import SwiftUI
import Testing
@testable import BetterTileApp

/// A shipped place that shows the action template, with the tint it applies.
enum WindowActionGlyphSite: String, CaseIterable, Sendable, CustomStringConvertible {
    /// MenuPanelActionButton in the glass menu panel, enabled and disabled.
    case menuPanel, menuPanelDisabled
    /// A plain Settings button label, as in Shortcuts and Snap Zones. Shortcuts
    /// disables it without Accessibility permission.
    case settingsButton, settingsButtonDisabled
    /// A Settings Picker item. AppKit receives the template NSImage and tints it.
    case pickerItem, pickerItemHighlighted, pickerItemDisabled

    var description: String { rawValue }
    var isAppKit: Bool { [.pickerItem, .pickerItemHighlighted, .pickerItemDisabled].contains(self) }
}

@MainActor enum MainWindowActionGlyphSamples {
    /// Main's renderer can return more than one template for an action. Keep
    /// each distinct output of 20 fresh renders, keyed by its 2x RGBA bytes.
    private static var variants: [WindowAction: [Data: NSImage]] = [:]

    static func templates(for action: WindowAction) throws -> [Data: NSImage] {
        if let cached = variants[action] { return cached }
        var result: [Data: NSImage] = [:]
        for _ in 0..<20 {
            try autoreleasepool {
                MenuGlassPanelGlyph.resetReference(for: action)
                _ = MenuGlassPanelGlyph.image(for: action)
                let image = try MenuGlassPanelGlyph.cachedTemplate(for: action)
                result[Data(try MainWindowActionGlyphTests.coverage(image))] = image
            }
        }
        MenuGlassPanelGlyph.resetReference(for: action)
        variants[action] = result
        return result
    }
}

@MainActor @Suite(.appTestApplication, .serialized)
struct MainWindowActionGlyphTests {
    /// Main's live template matches the bundled bytes only on the host that
    /// generated them. Elsewhere, CI included, compare within the limits of
    /// GlyphRasterDifference. See docs/ARCHITECTURE.md, "Layout Wheel glyph masks".
    static func mode(_ test: String) throws -> GlyphMaskTestMode {
        let directory = try #require(GlyphMaskStore.resourceDirectory)
        let manifest = try JSONDecoder().decode(GlyphMaskStore.Manifest.self,
                                                from: Data(contentsOf: directory.appending(path: "manifest.json")))
        let mode = GlyphMaskTestMode.current(generator: manifest.platform)
        mode.log(test)
        return mode
    }

    /// The closest of several references, measured with the tolerance metric.
    static func nearest(_ actual: [UInt8], _ references: [[UInt8]], width: Int, height: Int) -> GlyphRasterDifference? {
        var best: GlyphRasterDifference?
        for reference: [UInt8] in references {
            let difference = GlyphRasterDifference(actual, width: width, height: height, reference, width: width, height: height)
            if let current = best, current.inkDifference <= difference.inkDifference { continue }
            best = difference
        }
        return best
    }

    struct Case: CustomStringConvertible {
        let action: WindowAction
        let scale: Int
        let dark: Bool
        var description: String { "\(action.rawValue)-\(scale)x-\(dark ? "dark" : "light")" }

        static var all: [Case] {
            var cases: [Case] = []
            for action: WindowAction in WindowAction.allCases {
                for scale: Int in [1, 2] {
                    for dark: Bool in [false, true] { cases.append(Case(action: action, scale: scale, dark: dark)) }
                }
            }
            return cases
        }
    }

    @Test func frozenMainGlyphMatchesTheCopyHashedByTheMaskManifest() throws {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        func frozen(_ path: String) throws -> Substring {
            let text = try String(contentsOf: root.appending(path: path), encoding: .utf8)
            let start = try #require(text.range(of: "// Frozen shipped WindowActionGlyph"))
            let end = try #require(text.range(of: "static func cachedTemplate", range: start.upperBound..<text.endIndex))
            return text[start.lowerBound..<end.lowerBound]
        }
        #expect(try frozen("Tests/BetterTileAppTests/MainWindowActionGlyphReference.swift")
            == frozen("Tests/BetterTileMacOSTests/MenuGlassGlyphReference.swift"))
    }

    @Test func bundledTemplateIsMainsTemplateObjectForEveryAction() throws {
        let mode = try Self.mode("menuTemplate")
        var worst: GlyphRasterDifference?
        for action in WindowAction.allCases {
            WindowActionGlyphCache.templates[action] = nil
            let candidate = try #require(WindowActionGlyphCache.template(for: action))
            #expect(candidate === WindowActionGlyphCache.template(for: action))
            let main = try #require(try MainWindowActionGlyphSamples.templates(for: action).values.first)
            #expect(candidate.isTemplate)
            #expect(main.isTemplate)
            let templateSize = NSSize(width: 30, height: 26)
            #expect(candidate.size == main.size)
            #expect(candidate.size == templateSize)
            let candidateWidths: [Int] = candidate.representations.map { (rep: NSImageRep) -> Int in rep.pixelsWide }
            let mainWidths: [Int] = main.representations.map { (rep: NSImageRep) -> Int in rep.pixelsWide }
            let candidateHeights: [Int] = candidate.representations.map { (rep: NSImageRep) -> Int in rep.pixelsHigh }
            let mainHeights: [Int] = main.representations.map { (rep: NSImageRep) -> Int in rep.pixelsHigh }
            #expect(candidateWidths == mainWidths)
            #expect(candidateHeights == mainHeights)
            let bytes = try Self.coverage(candidate)
            let references = try MainWindowActionGlyphSamples.templates(for: action)
            if mode.isExact {
                #expect(references[Data(bytes)] != nil,
                        "\(action): bundled 2x template must equal one of main's rendered templates")
            } else {
                var candidates: [[UInt8]] = []
                for data: Data in references.keys { candidates.append([UInt8](data)) }
                let difference = try #require(Self.nearest(bytes, candidates, width: 60, height: 52))
                if worst.map({ difference.inkDifference > $0.inkDifference }) ?? true { worst = difference }
                #expect(difference.isWithinLimits, "\(action): \(difference)")
            }
        }
        if let worst { print("Window action glyph tolerance test=menuTemplate worst=\(worst)") }
    }

    /// The disabled and highlighted sites must tint differently from the
    /// plain site; otherwise their parity proves nothing about those states.
    @Test func disabledAndHighlightedSitesChangeTheTint() throws {
        let pairs: [(WindowActionGlyphSite, WindowActionGlyphSite)] = [(.menuPanel, .menuPanelDisabled),
            (.settingsButton, .settingsButtonDisabled), (.pickerItem, .pickerItemDisabled), (.pickerItem, .pickerItemHighlighted)]
        for sample in Case.all where sample.action == .leftHalf {
            for (plain, state) in pairs {
                #expect(try Self.render(plain, sample) != Self.render(state, sample), "\(state) \(sample)")
            }
        }
        WindowActionGlyphCache.templates[.leftHalf] = nil
    }

    /// Each site draws the same view code twice. Only the cached template
    /// object differs: main's rendered image, then the bundled image.
    @Test(arguments: WindowActionGlyphSite.allCases)
    func everySiteDrawsMainsPixels(_ site: WindowActionGlyphSite) throws {
        let mode = try Self.mode("site-\(site)")
        var matched = 0, failures: [String] = [], worst: GlyphRasterDifference?
        for sample in Case.all {
            try autoreleasepool {
                let references = try MainWindowActionGlyphSamples.templates(for: sample.action)
                var expected: Swift.Set<Data> = []
                for image in references.values {
                    WindowActionGlyphCache.templates[sample.action] = image
                    expected.insert(Data(try Self.render(site, sample)))
                }
                WindowActionGlyphCache.templates[sample.action] = nil
                _ = try #require(WindowActionGlyphCache.template(for: sample.action))
                let actual = Data(try Self.render(site, sample))
                // The comparison must see the glyph: an empty template changes the site's pixels.
                let empty = NSImage(size: NSSize(width: 30, height: 26))
                empty.isTemplate = true
                WindowActionGlyphCache.templates[sample.action] = empty
                #expect(Data(try Self.render(site, sample)) != actual, "\(site) \(sample) does not show the glyph")
                if mode.isExact {
                    if expected.contains(actual) { matched += 1 } else { failures.append(sample.description) }
                } else {
                    let size = try Self.size(site, sample)
                    var candidates: [[UInt8]] = []
                    for data: Data in expected { candidates.append([UInt8](data)) }
                    let difference = try #require(Self.nearest([UInt8](actual), candidates,
                                                               width: size.width, height: size.height))
                    if worst.map({ difference.inkDifference > $0.inkDifference }) ?? true { worst = difference }
                    if difference.isWithinLimits { matched += 1 } else { failures.append("\(sample): \(difference)") }
                }
            }
            WindowActionGlyphCache.templates[sample.action] = nil
        }
        print("Window action glyph site=\(site) \(mode.isExact ? "exact" : "withinTolerance")=\(matched)/\(Case.all.count)"
              + Self.worstSummary(worst))
        #expect(matched == 164, "\(site): \(failures.prefix(8))")
    }

    static func worstSummary(_ worst: GlyphRasterDifference?) -> String {
        guard let worst else { return "" }
        return " worst=\(worst)"
    }

    /// The pixel size of a site render; every render of one site and case has it.
    static func size(_ site: WindowActionGlyphSite, _ sample: Case) throws -> (width: Int, height: Int) {
        let previous = NSApp.appearance
        defer { NSApp.appearance = previous }
        var image: CGImage?
        let appearance = try #require(NSAppearance(named: sample.dark ? .darkAqua : .aqua))
        NSApp.appearance = appearance
        appearance.performAsCurrentDrawingAppearance {
            image = site.isAppKit ? appKit(site, sample, appearance: appearance) : swiftUI(site, sample)
        }
        let bitmap = try #require(image)
        return (bitmap.width, bitmap.height)
    }

    static func render(_ site: WindowActionGlyphSite, _ sample: Case) throws -> [UInt8] {
        let previous = NSApp.appearance
        let appearance = try #require(NSAppearance(named: sample.dark ? .darkAqua : .aqua))
        NSApp.appearance = appearance
        defer { NSApp.appearance = previous }
        var image: CGImage?
        appearance.performAsCurrentDrawingAppearance {
            image = site.isAppKit ? appKit(site, sample, appearance: appearance) : swiftUI(site, sample)
        }
        return try pixels(try #require(image))
    }

    private static func swiftUI(_ site: WindowActionGlyphSite, _ sample: Case) -> CGImage? {
        let content: AnyView
        switch site {
        case .menuPanel, .menuPanelDisabled:
            content = AnyView(MenuPanelActionButton(action: sample.action, shortcut: nil,
                isEnabled: site == .menuPanel) {}.frame(width: 156))
        default:
            // ShortcutsSettings row label, with its plain button style.
            content = AnyView(Button {} label: {
                HStack(spacing: SettingsSpacing.s2) {
                    WindowActionGlyph(action: sample.action)
                    Text(sample.action.title).lineLimit(1)
                }
                .frame(minWidth: 145, alignment: .leading)
            }
            .buttonStyle(.plain)
            // The view modifier `disabled` sets this value. The timing guard
            // reads that spelling as a test trait, so set it directly.
            .environment(\.isEnabled, site != .settingsButtonDisabled))
        }
        let renderer = ImageRenderer(content: content
            .environment(\.colorScheme, sample.dark ? .dark : .light)
            .environment(\.displayScale, CGFloat(sample.scale)))
        renderer.scale = CGFloat(sample.scale)
        return renderer.cgImage
    }

    private static func appKit(_ site: WindowActionGlyphSite, _ sample: Case, appearance: NSAppearance) -> CGImage? {
        guard let template = WindowActionGlyphCache.template(for: sample.action) else { return nil }
        let view = NSImageView(frame: NSRect(x: 0, y: 0, width: 30, height: 26))
        view.appearance = appearance
        view.imageScaling = .scaleNone
        view.image = template
        view.isEnabled = site != .pickerItemDisabled
        if site == .pickerItemHighlighted { view.contentTintColor = .selectedMenuItemTextColor }
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 30 * sample.scale,
                                         pixelsHigh: 26 * sample.scale, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = NSSize(width: 30, height: 26)
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.cgImage
    }

    /// The 2x template pixels that a 30×26-point request returns.
    static func coverage(_ image: NSImage) throws -> [UInt8] {
        var rect = NSRect(x: 0, y: 0, width: 30, height: 26)
        let bitmap = try #require(image.cgImage(forProposedRect: &rect, context: nil,
                                                hints: [.ctm: AffineTransform(scale: 2)]))
        try #require(bitmap.width == 60)
        try #require(bitmap.height == 52)
        return try pixels(bitmap)
    }

    static func pixels(_ image: CGImage) throws -> [UInt8] {
        let context = try #require(CGContext(data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.setBlendMode(.copy)
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Array(UnsafeBufferPointer(start: try #require(context.data).assumingMemoryBound(to: UInt8.self),
                                        count: image.width * image.height * 4))
    }
}
