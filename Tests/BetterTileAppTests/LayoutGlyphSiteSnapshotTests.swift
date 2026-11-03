import AppKit
import BetterTileCore
import BetterTileMacOS
import SwiftUI
import Testing
@testable import BetterTileApp

/// Offscreen renders of the layout and mode icons at the sites that the existing page snapshots do not
/// cover. With `BT_SNAPSHOT_DIR` set, each case also writes a PNG there. Without it, the cases check
/// the structure only.
@MainActor @Suite(.appTestApplication, .serialized, .settingsUI) struct LayoutGlyphSiteSnapshotTests {
    nonisolated static let directory = ProcessInfo.processInfo.environment["BT_SNAPSHOT_DIR"]
    nonisolated static let themes: [Bool] = directory == nil ? [false] : [false, true]

    private func write(_ bitmap: NSBitmapImageRep, _ name: String, dark: Bool) throws {
        guard let directory = Self.directory else { return }
        let folder = URL(filePath: directory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: folder.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png"))
    }

    private static let symbolPairs: [(LayoutGlyph, String)] = [
        (.layout(.single), "rectangle"), (.layout(.columns), "rectangle.3.group"), (.layout(.rows), "rectangle.3.group"),
        (.layout(.focus), "rectangle.3.group"), (.layout(.grid), "square.grid.2x2"), (.mode(.manual), "rectangle.on.rectangle"),
        (.mode(.bento), "arrow.left.and.right"), (.mode(.tabbed), "macwindow"), (.layouts, "rectangle.stack"),
    ]

    /// Native rendering check: every icon beside its SF Symbol pairing at 13, 16, 18 and 24 points, and the
    /// numbered and plain Settings sizes.
    private struct Sheet: View {
        var body: some View {
            VStack(alignment: .leading, spacing: 14) {
                ForEach([13.0, 16, 18, 24], id: \.self) { size in
                    HStack(spacing: 14) {
                        Text("\(Int(size)) pt").font(.system(size: 10)).frame(width: 34, alignment: .leading)
                        ForEach(Array(LayoutGlyphSiteSnapshotTests.symbolPairs.enumerated()), id: \.offset) { _, pair in
                            HStack(spacing: 4) {
                                Image(systemName: pair.1).font(.system(size: size, weight: .regular))
                                LayoutGlyphView(pair.0, size: CGFloat(LayoutGlyph.canvasSize(besideSymbolSize: size)))
                            }
                            .frame(width: 70)
                        }
                    }
                }
                Text("Semibold, wheel sizes 20.2 and 22.8 pt, and 30.4 pt fan size").font(.system(size: 10))
                HStack(spacing: 14) {
                    ForEach(LayoutGlyph.all, id: \.self) { LayoutGlyphView($0, size: 22.8, weight: .semibold) }
                    ForEach(LayoutGlyph.all, id: \.self) { LayoutGlyphView($0, size: 30.4, weight: .semibold) }
                }
                Text("Settings 52 pt and Gallery 66 pt, Regular. Numbers only in the first row.").font(.system(size: 10))
                HStack(spacing: 14) {
                    ForEach(TabbedPreset.allCases, id: \.self) { LayoutGlyphView(.layout($0), size: 52, numbered: true).foregroundStyle(.secondary) }
                    ForEach(LayoutMode.availableModes, id: \.self) { LayoutGlyphView(.mode($0), size: 52).foregroundStyle(Color.accentColor) }
                }
                HStack(spacing: 14) {
                    ForEach(TabbedPreset.allCases, id: \.self) { LayoutGlyphView(.layout($0), size: 66).foregroundStyle(.secondary) }
                }
            }
            .padding(20)
        }
    }

    @Test func iconSheetBesideSFSymbols() throws {
        for dark in Self.themes {
            let host = try SettingsSnapshotHost(Sheet(), dark: dark, width: 980, height: 600)
            defer { host.close() }
            try write(host.render(), "glyph-sheet", dark: dark)
        }
    }


    @Test func defaultModeCardsShowTheModeIcon() throws {
        for dark in Self.themes {
            for mode in LayoutMode.availableModes {
                let card = StatusCard("Default mode", glyph: .mode(mode), value: mode.title, caption: "New desktops start here.", tint: .accentColor)
                    .frame(width: 180).padding(12)
                let host = try SettingsSnapshotHost(card, dark: dark, width: 204, height: 200)
                defer { host.close() }
                try write(host.render(), "glyph-status-card-\(mode.rawValue)", dark: dark)
            }
        }
    }



}

@MainActor @Suite(.appTestApplication, .serialized, .settingsUI) struct LayoutGlyphRenderingTests {
    /// Renders a Window mode choice in a column of the given width, with room on both sides. Badges that
    /// clip or overflow would leave ink in that room.
    @Test(arguments: [96.0, 120, 160, 200, 230])
    func modeBadgesNeverClip(width: Double) throws {
        let margin = 24.0
        for dark in Self.themes {
            let choice = HStack(spacing: 0) {
                PictureChoice("Manual", detail: "Use macOS windows with BetterTile snapping.", isSelected: true,
                              thumbnailHeight: WindowLayoutSettings.modePictureHeight,
                              accessory: AnyView(ModeBadges(isThisDesktop: true, isDefault: true)), action: {}) {
                    LayoutGlyphView(.mode(.manual), size: 52)
                }
                .frame(width: width)
            }
            .padding(.horizontal, margin).padding(.vertical, 8)
            let host = try SettingsSnapshotHost(choice, dark: dark, width: width + margin * 2, height: 220)
            defer { host.close() }
            let bitmap = try host.render()
            let scale = Double(bitmap.pixelsWide) / (width + margin * 2)
            let reference = try #require(bitmap.colorAt(x: 4, y: bitmap.pixelsHigh / 2))
            func isBackground(_ x: Int, _ y: Int) -> Bool {
                guard let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), let r = reference.usingColorSpace(.sRGB) else { return true }
                return abs(c.redComponent - r.redComponent) + abs(c.greenComponent - r.greenComponent) + abs(c.blueComponent - r.blueComponent) < 0.03
            }
            // The 4 pt selection ring is allowed beside the column. Nothing may sit past it.
            let ringRoom = Int(((margin - 8) * scale).rounded(.down))
            // The host window rounds its corners, so the top and bottom 16 px are skipped.
            for y in 16 ..< bitmap.pixelsHigh - 16 {
                for x in 1 ..< ringRoom { #expect(isBackground(x, y), "Ink at x=\(x) left of the column, width \(width)") }
                for x in (bitmap.pixelsWide - ringRoom) ..< bitmap.pixelsWide - 1 { #expect(isBackground(x, y), "Ink at x=\(x) right of the column, width \(width)") }
            }
            if let dir = Self.directory { try write(bitmap, dir, "glyph-mode-badges-\(Int(width))", dark: dark) }
        }
    }

    nonisolated static let directory = ProcessInfo.processInfo.environment["BT_SNAPSHOT_DIR"]
    nonisolated static let themes: [Bool] = directory == nil ? [false] : [false, true]

    private func write(_ bitmap: NSBitmapImageRep, _ directory: String, _ name: String, dark: Bool) throws {
        let folder = URL(filePath: directory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: folder.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png"))
    }
}
