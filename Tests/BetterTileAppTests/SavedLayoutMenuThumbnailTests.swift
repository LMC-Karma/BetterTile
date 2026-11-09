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

    @Test func theCacheReturnsOneSmallImagePerBundleID() throws {
        var resolves: [String] = []
        let cache = SavedLayoutMenuIconCache { id in
            resolves.append(id)
            return id == "missing" ? nil : NSWorkspace.shared.icon(for: .applicationBundle)
        }
        let first = try #require(cache.icon(for: "com.apple.Safari"))
        let second = try #require(cache.icon(for: "com.apple.Safari"))
        #expect(first === second)
        #expect(cache.icon(for: "com.apple.Notes") !== first)
        #expect(cache.icon(for: "missing") == nil && cache.icon(for: "missing") == nil)
        #expect(resolves == ["com.apple.Safari", "com.apple.Notes", "missing", "missing"])
        #expect(first.size == NSSize(width: Metrics.maximumIcon, height: Metrics.maximumIcon))
        let pixels = first.representations.map(\.pixelsWide)
        #expect(pixels == SavedLayoutMenuIconCache.pixelSizes)
        #expect(first.representations.allSatisfy { $0 is NSBitmapImageRep && $0.pixelsWide == $0.pixelsHigh })
    }

    @Test func theSmallCopyFillsEveryBitmap() throws {
        let source = NSImage(size: NSSize(width: 64, height: 64), flipped: false) { rect in
            NSColor.red.setFill(); rect.fill(); return true
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
