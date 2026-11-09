import AppKit
import BetterTileCore
import SwiftUI
import Testing
@testable import BetterTileApp

@Suite(.appTestApplication) @MainActor struct SavedLayoutMenuThumbnailTests {
    typealias Metrics = SavedLayoutMenuThumbnailMetrics

    nonisolated static func columns(_ ratios: [Double], _ apps: [String]) -> SavedLayoutDocument {
        let ids = apps.indices.map { "s\($0)" }
        return .init(name: "Columns", mode: .bento,
                     layout: .split(axis: .vertical, ratios: ratios, children: ids.map { .slot($0) }),
                     slots: zip(ids, apps).map { .init(id: $0, bundleID: $1) })
    }

    nonisolated static let shapes: [(String, SavedLayoutDocument)] = [
        ("two panes", columns([0.5, 0.5], ["com.apple.Safari", "com.apple.Notes"])),
        ("three columns", columns([0.34, 0.33, 0.33], ["com.apple.iBooksX", "com.apple.Safari", "com.apple.Preview"])),
        ("three panes", .init(name: "Research", mode: .bento,
            layout: .split(axis: .vertical, ratios: [0.6, 0.4], children: [.slot("a"),
                .split(axis: .horizontal, ratios: [0.5, 0.5], children: [.slot("b"), .slot("c")])]),
            slots: [.init(id: "a", bundleID: "com.apple.Safari"), .init(id: "b", bundleID: "com.apple.Preview"),
                    .init(id: "c", prefer: [.group("Browser")])])),
        ("grid", .init(name: "Inbox", mode: .bento,
            layout: .split(axis: .vertical, ratios: [0.5, 0.5], children: [
                .split(axis: .horizontal, ratios: [0.5, 0.5], children: [.slot("a"), .slot("b")]),
                .split(axis: .horizontal, ratios: [0.5, 0.5], children: [.slot("c"), .slot("d")])]),
            slots: ["a", "b", "c", "d"].map { .init(id: $0, bundleID: "com.example.\($0)") })),
        ("manual", .init(name: "Manual", mode: .manual,
            slots: [.init(id: "a", bundleID: "com.apple.Safari"), .init(id: "b", bundleID: "com.apple.Notes")],
            windows: [.init(slot: "a", rect: .init(x: 0.05, y: 0.1, width: 0.5, height: 0.7)),
                      .init(slot: "b", rect: .init(x: 0.6, y: 0.3, width: 0.35, height: 0.6))]))
    ]

    @Test(arguments: shapes.indices)
    func everyPreferencePaneGetsAnIconThatFits(_ index: Int) {
        let (name, document) = Self.shapes[index]
        let panes = Metrics.panes(of: document, in: Metrics.canvasSize)
        let placements = Metrics.iconPlacements(of: document, in: Metrics.canvasSize)
        #expect(panes.count == document.slots.count, "\(name)")
        #expect(placements.count == panes.count, "\(name): \(panes.map(\.frame))")
        for (pane, placement) in zip(panes, placements) {
            let rect = placement.rect
            #expect(rect.width == rect.height)
            #expect(rect.width >= Metrics.minimumIcon && rect.width <= Metrics.maximumIcon, "\(name): \(rect)")
            #expect(pane.frame.insetBy(dx: Metrics.iconMargin - 0.001, dy: Metrics.iconMargin - 0.001).contains(rect), "\(name)")
            #expect(abs(rect.midX - pane.frame.midX) < 0.001 && abs(rect.midY - pane.frame.midY) < 0.001)
        }
    }

    nonisolated static let fourColumns = columns([0.25, 0.25, 0.25, 0.25], ["com.apple.Safari", "com.apple.Notes", "com.apple.mail", "com.apple.Preview"])

    @Test func fourColumnsAreTooNarrowForAnyIcon() {
        #expect(Metrics.panes(of: Self.fourColumns, in: Metrics.canvasSize).count == 4)
        #expect(Metrics.iconPlacements(of: Self.fourColumns, in: Metrics.canvasSize).isEmpty)
    }

    @Test func aPaneTooSmallForTheMinimumIconSkipsOnlyThatIcon() throws {
        let document = Self.columns([0.88, 0.12], ["com.apple.Safari", "com.apple.Notes"])
        let panes = Metrics.panes(of: document, in: Metrics.canvasSize)
        let placements = Metrics.iconPlacements(of: document, in: Metrics.canvasSize)
        #expect(placements == [.init(rect: try #require(Metrics.iconRect(in: panes[0].frame)), preference: .app("com.apple.Safari"))])
        #expect(Metrics.iconRect(in: panes[1].frame) == nil)
    }

    @Test func iconSizeFollowsThePaneUpToTheMaximum() throws {
        #expect(try #require(Metrics.iconRect(in: CGRect(x: 0, y: 0, width: 40, height: 20))).width == 14)
        #expect(try #require(Metrics.iconRect(in: CGRect(x: 0, y: 0, width: 100, height: 100))).width == Metrics.maximumIcon)
        // 70% would be under 8 pt, but 8 pt still fits with its margin.
        #expect(try #require(Metrics.iconRect(in: CGRect(x: 0, y: 0, width: 11, height: 30))).width == Metrics.minimumIcon)
        #expect(Metrics.iconRect(in: CGRect(x: 0, y: 0, width: 10.9, height: 30)) == nil)
    }

    /// A cache with fake app locations, so tests control installs, updates and icon art.
    final class FakeApps {
        var installed: Set<String>
        var modified: [String: Date] = [:]
        var loads: [String] = []
        init(_ installed: Set<String>) { self.installed = installed }
        @MainActor func cache(capacity: Int = SavedLayoutMenuIconCache.defaultCapacity,
                              art: @escaping (String) -> NSImage = { _ in SavedLayoutMenuThumbnailTests.solid(SavedLayoutMenuThumbnailTests.red) }) -> SavedLayoutMenuIconCache {
            SavedLayoutMenuIconCache(capacity: capacity,
                locate: { [self] id in installed.contains(id) ? URL(filePath: "/Applications/\(id).app") : nil },
                modificationDate: { [self] url in modified[url.deletingPathExtension().lastPathComponent] },
                load: { [self] url in
                    let id = url.deletingPathExtension().lastPathComponent
                    loads.append(id); return art(id)
                })
        }
    }

    nonisolated static func solid(_ color: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 64, height: 64), flipped: false) { rect in color.setFill(); rect.fill(); return true }
    }

    @Test func theCacheKeepsOneSmallImagePerApp() throws {
        let apps = FakeApps(["a", "b"])
        let cache = apps.cache()
        #expect(cache.capacity == 64)
        let first = try #require(cache.icon(for: "a", dark: false))
        #expect(cache.icon(for: "a", dark: false) === first)
        #expect(cache.icon(for: "b", dark: false) !== first)
        #expect(apps.loads == ["a", "b"] && cache.count == 2)
        #expect(first.size == NSSize(width: Metrics.maximumIcon, height: Metrics.maximumIcon))
        #expect(first.representations.map(\.pixelsWide) == SavedLayoutMenuIconCache.pixelSizes)
        #expect(first.representations.allSatisfy { $0 is NSBitmapImageRep && $0.pixelsWide == $0.pixelsHigh })
    }

    @Test func theCacheEvictsTheLeastRecentlyUsedIconAtItsCapacity() throws {
        let apps = FakeApps(["a", "b", "c", "d"])
        let cache = apps.cache(capacity: 3)
        let a = try #require(cache.icon(for: "a", dark: false))
        _ = cache.icon(for: "b", dark: false); _ = cache.icon(for: "c", dark: false)
        #expect(cache.icon(for: "a", dark: false) === a) // a is now the most recent; b is the oldest.
        _ = cache.icon(for: "d", dark: false)
        #expect(cache.count == 3)
        #expect(cache.icon(for: "a", dark: false) === a && cache.icon(for: "c", dark: false) != nil)
        #expect(apps.loads == ["a", "b", "c", "d"])
        _ = cache.icon(for: "b", dark: false)
        #expect(apps.loads == ["a", "b", "c", "d", "b"] && cache.count == 3)
    }

    @Test func theDefaultCacheHoldsAtMost64Icons() {
        let apps = FakeApps(Set((0..<70).map { "app\($0)" }))
        let cache = apps.cache()
        for n in 0..<70 { _ = cache.icon(for: "app\(n)", dark: false) }
        #expect(cache.count == 64)
        _ = cache.icon(for: "app0", dark: false)
        #expect(apps.loads.last == "app0" && apps.loads.count == 71 && cache.count == 64)
    }

    @Test func anUpdatedAppGetsANewIcon() throws {
        let apps = FakeApps(["a"])
        apps.modified["a"] = Date(timeIntervalSince1970: 1)
        var color = Self.red
        let cache = apps.cache(art: { _ in Self.solid(color) })
        let old = try #require(cache.icon(for: "a", dark: false))
        #expect(cache.icon(for: "a", dark: false) === old)
        apps.modified["a"] = Date(timeIntervalSince1970: 2); color = NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)
        let new = try #require(cache.icon(for: "a", dark: false))
        #expect(new !== old && apps.loads == ["a", "a"] && cache.count == 1)
        let pixel = try #require((new.representations[0] as? NSBitmapImageRep)?.colorAt(x: 8, y: 8))
        #expect(pixel.blueComponent > 0.99 && pixel.redComponent < 0.01)
    }

    @Test func lightAndDarkKeepSeparateIconsDrawnInTheirAppearance() throws {
        let apps = FakeApps(["a"])
        // Art that follows the drawing appearance, as a macOS 26 dark icon can.
        let cache = apps.cache(art: { _ in
            NSImage(size: NSSize(width: 64, height: 64), flipped: false) { rect in
                let dark = NSAppearance.currentDrawing().bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                (dark ? NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1) : NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)).setFill(); rect.fill(); return true
            }
        })
        let light = try #require(cache.icon(for: "a", dark: false))
        let dark = try #require(cache.icon(for: "a", dark: true))
        #expect(light !== dark && cache.count == 2)
        #expect(cache.icon(for: "a", dark: false) === light && cache.icon(for: "a", dark: true) === dark)
        #expect(apps.loads == ["a", "a"])
        let lightPixel = try #require((light.representations[0] as? NSBitmapImageRep)?.colorAt(x: 8, y: 8))
        let darkPixel = try #require((dark.representations[0] as? NSBitmapImageRep)?.colorAt(x: 8, y: 8))
        #expect(lightPixel.redComponent > 0.99 && darkPixel.blueComponent > 0.99)
    }

    @Test func aMissingAppGetsNoIconAndLeavesNoEntry() throws {
        let apps = FakeApps(["a"])
        let cache = apps.cache()
        #expect(cache.icon(for: "missing", dark: false) == nil && cache.count == 0)
        _ = try #require(cache.icon(for: "a", dark: false)); _ = cache.icon(for: "a", dark: true)
        #expect(cache.count == 2)
        apps.installed = []
        #expect(cache.icon(for: "a", dark: false) == nil && cache.count == 0)
        apps.installed = ["a"]
        #expect(cache.icon(for: "a", dark: false) != nil && apps.loads == ["a", "a", "a"])
    }

    @Test func theMenuPictureCachesOnlyIconsItDraws() {
        let apps = FakeApps(["first", "fallback", "narrow"])
        let cache = apps.cache()
        let document = SavedLayoutDocument(name: "Fallbacks", mode: .bento,
            layout: .split(axis: .vertical, ratios: [0.88, 0.12], children: [.slot("a"), .slot("b")]),
            slots: [.init(id: "a", prefer: [.app("first"), .app("fallback")]), .init(id: "b", prefer: [.app("narrow")])])
        _ = Self.render(document, cache: cache)
        #expect(apps.loads == ["first"] && cache.count == 1)
    }

    // MARK: Drawing

    /// Renders the menu picture at 2x. Canvas point (x, y) is pixel ((x + 4) × 2, (y + 4) × 2).
    static func render(_ document: SavedLayoutDocument, cache: SavedLayoutMenuIconCache, dark: Bool = false) -> NSBitmapImageRep? {
        let renderer = ImageRenderer(content: SavedLayoutThumbnail(document: document, style: .menu)
            .frame(width: Metrics.size.width, height: Metrics.size.height)
            .environment(\.savedLayoutMenuIcons, cache).environment(\.colorScheme, dark ? .dark : .light))
        renderer.scale = 2
        return renderer.cgImage.map { NSBitmapImageRep(cgImage: $0) }
    }

    static func color(_ bitmap: NSBitmapImageRep, _ point: CGPoint) -> NSColor? {
        bitmap.colorAt(x: Int(((point.x + Metrics.padding) * 2).rounded(.down)), y: Int(((point.y + Metrics.padding) * 2).rounded(.down)))?
            .usingColorSpace(.sRGB)
    }

    /// Same pure test colour. Rendering's colour matching can move a channel by up to about 0.25, so the tolerance is 0.3;
    /// the test colours differ by a whole channel.
    static func matches(_ color: NSColor?, _ target: NSColor) -> Bool {
        guard let color, let target = target.usingColorSpace(.sRGB) else { return false }
        return abs(color.redComponent - target.redComponent) < 0.3 && abs(color.greenComponent - target.greenComponent) < 0.3
            && abs(color.blueComponent - target.blueComponent) < 0.3 && color.alphaComponent > 0.96
    }

    static func distance(_ a: NSColor?, _ b: NSColor?) -> CGFloat {
        guard let a, let b else { return 0 }
        return max(abs(a.redComponent - b.redComponent), abs(a.greenComponent - b.greenComponent), abs(a.blueComponent - b.blueComponent))
    }

    nonisolated(unsafe) static let red = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
    nonisolated(unsafe) static let green = NSColor(srgbRed: 0, green: 1, blue: 0, alpha: 1)
    nonisolated(unsafe) static let palette: [String: NSColor] = ["com.apple.Safari": red, "com.apple.Notes": green, "com.apple.Preview": NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1),
        "com.apple.mail": NSColor(srgbRed: 1, green: 1, blue: 0, alpha: 1), "com.apple.iCal": NSColor(srgbRed: 1, green: 0, blue: 1, alpha: 1),
        "com.apple.iBooksX": NSColor(srgbRed: 0, green: 1, blue: 1, alpha: 1)]

    static func paletteCache() -> SavedLayoutMenuIconCache {
        FakeApps(Set(palette.keys)).cache(art: { solid(palette[$0] ?? .black) })
    }

    @Test(arguments: SavedLayoutMenuPickerSnapshotTests.documents.indices, [false, true])
    func eachIconIsDrawnInsideItsOwnPane(_ index: Int, dark: Bool) throws {
        let document = SavedLayoutMenuPickerSnapshotTests.documents[index]
        let bitmap = try #require(Self.render(document, cache: Self.paletteCache(), dark: dark))
        #expect(bitmap.pixelsWide == Int(Metrics.size.width) * 2 && bitmap.pixelsHigh == Int(Metrics.size.height) * 2)
        var drawn = 0
        for (pane, placement) in Metrics.drawings(of: document, in: Metrics.canvasSize) {
            guard let placement, case let .app(id) = placement.preference, let target = Self.palette[id] else { continue }
            let rect = placement.rect
            #expect(Self.matches(Self.color(bitmap, CGPoint(x: rect.midX, y: rect.midY)), target), "\(document.name) \(id) centre")
            #expect(Self.matches(Self.color(bitmap, CGPoint(x: rect.minX + 1, y: rect.minY + 1)), target), "\(document.name) \(id) corner")
            // Pane fill between the icon and the pane edge carries no icon colour.
            #expect(!Self.matches(Self.color(bitmap, CGPoint(x: pane.frame.minX + 0.6, y: pane.frame.midY)), target), "\(document.name) \(id) edge")
            drawn += 1
        }
        #expect(drawn == document.slots.filter { if case .app = $0.prefer.first { true } else { false } }.count)
    }

    /// The pixel at `point` must change when the front pane is added: its fill covers the back icon there.
    func expectFrontPaneCoversBackIcon(back: SavedLayoutDocument, both: SavedLayoutDocument, at point: CGPoint,
                                       front: CGPoint, frontColor: NSColor, dark: Bool) throws {
        let alone = try #require(Self.render(back, cache: Self.paletteCache(), dark: dark))
        let covered = try #require(Self.render(both, cache: Self.paletteCache(), dark: dark))
        #expect(Self.matches(Self.color(alone, point), Self.red), "The back icon is at the test point")
        // Painted the other way round, the back icon would cover the front pane and this pixel would not change.
        #expect(Self.distance(Self.color(covered, point), Self.color(alone, point)) > 0.1, "The front pane paints over the back icon")
        #expect(Self.matches(Self.color(covered, front), frontColor), "The front icon is on top")
    }

    @Test(arguments: [false, true])
    func overlappingManualWindowsPaintInPaneOrder(dark: Bool) throws {
        let back = SavedLayoutRectangle(slot: "a", rect: .init(x: 0, y: 0, width: 1, height: 1))
        let slots: [SavedLayoutSlot] = [.init(id: "a", bundleID: "com.apple.Safari"), .init(id: "b", bundleID: "com.apple.Notes")]
        let alone = SavedLayoutDocument(name: "Back", mode: .manual, slots: slots, windows: [back])
        let both = SavedLayoutDocument(name: "Overlap", mode: .manual, slots: slots,
            windows: [back, .init(slot: "b", rect: .init(x: 0.45, y: 0.15, width: 0.5, height: 0.7))])
        // Canvas 48×34: the back icon spans x 14–34; the front pane starts at x 23.6, its icon at x 26.7.
        let front = try #require(Metrics.drawings(of: both, in: Metrics.canvasSize)[1].icon?.rect)
        #expect(front.minX > 25.5)
        try expectFrontPaneCoversBackIcon(back: alone, both: both, at: CGPoint(x: 25, y: 17),
                                          front: CGPoint(x: front.midX, y: front.midY), frontColor: Self.green, dark: dark)
    }

    @Test(arguments: [false, true])
    func aFloatPaintsOverTheTileBelowIt(dark: Bool) throws {
        let slots: [SavedLayoutSlot] = [.init(id: "a", bundleID: "com.apple.Safari"), .init(id: "b", bundleID: "com.apple.Notes")]
        let alone = SavedLayoutDocument(name: "Tile", mode: .bento, layout: .slot("a"), slots: slots)
        let both = SavedLayoutDocument(name: "Float", mode: .bento, layout: .slot("a"), slots: slots,
            floats: [.init(slot: "b", rect: .init(x: 0.3, y: 0.25, width: 0.4, height: 0.5))])
        // The tile icon spans x 14–34 and y 7–27. The float pane starts at (16.4, 10.5); its icon at x 19.45.
        let front = try #require(Metrics.drawings(of: both, in: Metrics.canvasSize)[1].icon?.rect)
        #expect(front.minX > 18.5)
        try expectFrontPaneCoversBackIcon(back: alone, both: both, at: CGPoint(x: 17.5, y: 12),
                                          front: CGPoint(x: front.midX, y: front.midY), frontColor: Self.green, dark: dark)
    }

    @Test func theSmallCopyFillsEveryBitmap() throws {
        let source = NSImage(size: NSSize(width: 64, height: 64), flipped: false) { rect in
            NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1).setFill(); rect.fill(); return true
        }
        for rep in SavedLayoutMenuIconCache.smallCopy(of: source).representations {
            let bitmap = try #require(rep as? NSBitmapImageRep)
            let last = bitmap.pixelsWide - 1
            for (x, y) in [(0, 0), (last, 0), (0, last), (last, last), (last / 2, last / 2)] {
                let color = try #require(bitmap.colorAt(x: x, y: y))
                #expect(color.alphaComponent > 0.99 && color.redComponent > 0.99, "\(bitmap.pixelsWide) px at \(x),\(y)")
            }
        }
    }

    @Test(arguments: shapes.indices.map { $0 } + [-1], [false, true])
    func theSettingsPictureIsUnchanged(_ index: Int, dark: Bool) throws {
        let document = index < 0 ? Self.fourColumns : Self.shapes[index].1
        let current = try Self.pixels(SavedLayoutThumbnail(document: document), dark: dark)
        let legacy = try Self.pixels(LegacySettingsThumbnail(document: document), dark: dark)
        #expect(current == legacy)
        #expect(Set(legacy).count > 8, "The renderer drew the picture, not a blank image.")
    }

    static func pixels(_ view: some View, dark: Bool) throws -> Data {
        let renderer = ImageRenderer(content: view.frame(width: 42, height: 30).environment(\.colorScheme, dark ? .dark : .light))
        renderer.scale = 2
        let image = try #require(renderer.cgImage)
        return try #require(image.dataProvider?.data as Data?)
    }
}

/// The Settings picture as it was before the menu style. Do not edit: it guards Settings output.
private struct LegacySettingsThumbnail: View {
    let document: SavedLayoutDocument

    var body: some View {
        let icons = Dictionary(uniqueKeysWithValues: Set(document.slots.flatMap { $0.prefer.compactMap { preference -> String? in if case let .app(id) = preference { id } else { nil } } }).map { id in
            let icon = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
                .map { NSWorkspace.shared.icon(forFile: $0.path) }
            return (id, icon)
        })
        Canvas { context, size in
            let leaves = document.layout.map { SavedLayoutCanvas.leaves($0) } ?? []
            let panes = leaves.map { leaf in
                (leaf.rect, SavedLayoutCanvas.slotIDs(in: leaf.node, document: document).first)
            } + (document.windows + document.floats).map { ($0.rect, Optional($0.slot)) }
            for (rect, slot) in panes {
                let frame = CGRect(x: rect.x * size.width + 2, y: rect.y * size.height + 2,
                                   width: max(1, rect.width * size.width - 4), height: max(1, rect.height * size.height - 4))
                context.fill(Path(roundedRect: frame, cornerRadius: SavedLayoutMetrics.chipRadius), with: .color(.secondary.opacity(0.45)))
                if let slot, let first = document.slots.first(where: { $0.id == slot })?.prefer.first {
                    let icon: NSImage? = switch first {
                    case let .app(bundle): icons[bundle] ?? nil
                    case .group: NSImage(systemSymbolName: "square.stack.3d.up", accessibilityDescription: nil)
                    }
                    if let icon {
                    let edge = min(SettingsSpacing.s5, min(frame.width, frame.height) - SettingsSpacing.s1)
                    if edge >= SettingsSpacing.s2 {
                        context.draw(Image(nsImage: icon), in: CGRect(x: frame.midX - edge / 2, y: frame.midY - edge / 2,
                                                                     width: edge, height: edge))
                    }
                    }
                }
            }
        }
        .padding(4)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: SavedLayoutMetrics.stageRadius, style: .continuous))
        .accessibilityHidden(true)
    }
}
