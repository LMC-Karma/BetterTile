import AppKit
import BetterTileCore
import Testing
@testable import BetterTileMacOS

/// The Tabbed Layout Gallery and the empty-pane hint draw the layout icons. With `BT_SNAPSHOT_DIR` set, each
/// case also writes a PNG there.
@MainActor @Suite(.macOSTestApplication, .serialized)
struct LayoutGlyphSiteTests {
    private func write(_ view: NSView, _ name: String, dark: Bool) throws -> Data {
        view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        view.layoutSubtreeIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.appearance!.performAsCurrentDrawingAppearance { view.cacheDisplay(in: view.bounds, to: bitmap) }
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        if let directory = ProcessInfo.processInfo.environment["BT_SNAPSHOT_DIR"] {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            try data.write(to: URL(filePath: directory).appendingPathComponent("\(name)-\(dark ? "dark" : "light").png"))
        }
        return data
    }

    @Test func galleryDrawsTheLayoutIcons() throws {
        _ = NSApplication.shared
        for dark in [false, true] {
            var renders: [Data] = []
            for preset in TabbedPreset.allCases {
                let gallery = TabbedLayoutGallery(state: TabbedLayoutState(preset: preset), onPreview: { _, _ in }, onApply: { _, _ in })
                defer { gallery.cancel() }
                let window = NSWindow(contentRect: NSRect(x: 12000, y: 0, width: 366, height: 402), styleMask: [.titled],
                                      backing: .buffered, defer: false)
                defer { window.orderOutForTesting() }
                window.contentView = gallery.content
                renders.append(try write(gallery.content, "glyph-gallery-current-\(preset.rawValue)", dark: dark))
            }
            // Each current layout selects another tile, so no two renders are the same.
            #expect(Set(renders).count == renders.count)
        }
    }

    @Test func emptyPaneHintShowsTheIconOfTheCurrentLayout() throws {
        _ = NSApplication.shared
        for preset in TabbedPreset.allCases {
            let overlay = TabbedOverlayController()
            defer { overlay.hide() }
            let state = TabbedLayoutState(preset: preset)
            overlay.refresh(state: state, bounds: BTRect(x: 12000, y: 0, width: 1000, height: 800), windows: [])
            let ids = Set(state.panes.map(\.id))
            let views = NSApp.windows.compactMap(\.contentView).compactMap { $0 as? TabbedPaneView }.filter { ids.contains($0.pane.id) }
            #expect(views.count == preset.paneCount)
            for view in views { #expect(view.content.layoutGlyph == .layout(preset)) }
        }
        // A layout that is not one of the five presets shows the Layouts icon.
        var state = TabbedLayoutState(preset: .columns)
        let bounds = BTRect(x: 0, y: 0, width: 1000, height: 800)
        let branch = try #require(state.dividers(in: bounds).first?.branchID)
        let adjusted = state.adjustDivider(branch, by: 0.1, in: bounds)
        #expect(adjusted)
        let overlay = TabbedOverlayController()
        defer { overlay.hide() }
        overlay.refresh(state: state, bounds: BTRect(x: 12000, y: 0, width: 1000, height: 800), windows: [])
        let view = try #require(NSApp.windows.compactMap(\.contentView).compactMap { $0 as? TabbedPaneView }.first { state.panes.map(\.id).contains($0.pane.id) })
        #expect(view.content.layoutGlyph == .layouts)
        for dark in [false, true] {
            _ = try write(view, "glyph-empty-pane-hint-custom", dark: dark)
        }
    }

    @Test func emptyPaneHintRendersEachPreset() throws {
        _ = NSApplication.shared
        for preset in [TabbedPreset.columns, .grid] {
            let overlay = TabbedOverlayController()
            defer { overlay.hide() }
            let state = TabbedLayoutState(preset: preset)
            overlay.refresh(state: state, bounds: BTRect(x: 12000, y: 0, width: 1000, height: 800), windows: [])
            let ids = Set(state.panes.map(\.id))
            let view = try #require(NSApp.windows.compactMap(\.contentView).compactMap { $0 as? TabbedPaneView }.first { ids.contains($0.pane.id) })
            for dark in [false, true] { _ = try write(view, "glyph-empty-pane-hint-\(preset.rawValue)", dark: dark) }
        }
    }
}
