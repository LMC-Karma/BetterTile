import AppKit
import BetterTileCore
import BetterTileMacOS
import SwiftUI
import Testing
@testable import BetterTileApp

/// Renders the menu panel's Saved Layouts picker offscreen. Set `BT_SNAPSHOT_DIR` to keep the PNGs.
@Suite(.appTestApplication, .serialized, .settingsUI) @MainActor struct SavedLayoutMenuPickerSnapshotTests {
    static let documents: [SavedLayoutDocument] = [
        .init(name: "Writing", mode: .bento,
              layout: .split(axis: .vertical, ratios: [0.5, 0.5], children: [.slot("a"), .slot("b")]),
              slots: [.init(id: "a", bundleID: "com.apple.Safari"), .init(id: "b", bundleID: "com.apple.Notes")]),
        .init(name: "Research", mode: .bento,
              layout: .split(axis: .vertical, ratios: [0.6, 0.4], children: [.slot("a"),
                  .split(axis: .horizontal, ratios: [0.5, 0.5], children: [.slot("b"), .slot("c")])]),
              slots: [.init(id: "a", bundleID: "com.apple.Safari"), .init(id: "b", bundleID: "com.apple.Preview"),
                      .init(id: "c", bundleID: "com.apple.Notes")]),
        .init(name: "Inbox", mode: .bento,
              layout: .split(axis: .vertical, ratios: [0.5, 0.5], children: [
                  .split(axis: .horizontal, ratios: [0.5, 0.5], children: [.slot("a"), .slot("b")]),
                  .split(axis: .horizontal, ratios: [0.5, 0.5], children: [.slot("c"), .slot("d")])]),
              slots: [.init(id: "a", bundleID: "com.apple.mail"), .init(id: "b", bundleID: "com.apple.iCal"),
                      .init(id: "c", bundleID: "com.apple.Notes"), .init(id: "d", bundleID: "com.apple.Safari")]),
        .init(name: "Reading", mode: .bento,
              layout: .split(axis: .vertical, ratios: [0.34, 0.33, 0.33], children: [.slot("a"), .slot("b"), .slot("c")]),
              slots: [.init(id: "a", bundleID: "com.apple.iBooksX"), .init(id: "b", prefer: [.group("Browser")]),
                      .init(id: "c", bundleID: "com.apple.Preview")])
    ]

    @Test(arguments: [false, true], [1, 2])
    func menuPickerRenders(dark: Bool, scale: Int) async throws {
        let f = try SavedLayoutActionFixture(); defer { f.close() }
        for document in Self.documents {
            let url = try f.files.create(SavedLayoutValidator.encode(document))
            f.model.savedLayoutActions.refresh()
            #expect(f.model.setSavedLayoutActions(url.lastPathComponent, .init(showInMenuBar: true)))
        }
        #expect(f.model.savedLayoutActions.menuEntries.count == Self.documents.count)
        let size = NSSize(width: MenuPanelMetrics.width, height: 330)
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let previousAppearance = NSApp.appearance
        NSApp.appearance = appearance
        defer { NSApp.appearance = previousAppearance }
        let content = SavedLayoutPanelSection(model: f.model)
            .padding(MenuPanelMetrics.padding)
            .frame(width: size.width, height: size.height, alignment: .top)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, dark ? .dark : .light)
        let host = NSHostingView(rootView: content)
        host.frame = NSRect(origin: .zero, size: size); host.appearance = appearance
        // A plain host: cacheDisplay draws the panel glass's vibrant text dark in Dark Mode.
        let root: NSView = host
        host.wantsLayer = true
        let window = OffscreenTestWindow(contentRect: NSRect(origin: NSPoint(x: 12000, y: 0), size: size),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.appearance = appearance
        window.backgroundColor = .windowBackgroundColor; window.contentView = root
        window.orderFrontForTesting()
        defer { window.close() }
        try await waitForSavedLayoutSnapshot(in: root)
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width) * scale,
            pixelsHigh: Int(size.height) * scale, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.size = size
        root.cacheDisplay(in: root.bounds, to: bitmap)
        #expect(bitmap.pixelsWide == Int(size.width) * scale)
        if let output = ProcessInfo.processInfo.environment["BT_SNAPSHOT_DIR"] {
            try #require(bitmap.representation(using: .png, properties: [:])).write(
                to: URL(filePath: output).appending(path: "menu-saved-layouts-\(dark ? "dark" : "light")-\(scale)x.png"))
        }
    }
}
