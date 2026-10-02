import AppKit
import SwiftUI
import Testing
@testable import BetterTileApp

@Test(.enabled(if: ProcessInfo.processInfo.environment["BETTERTILE_TAB_PREVIEW_DIR"] != nil,
               "Requires an explicit settings preview output directory."))
@MainActor func windowLayoutSettingsPreview() throws {
    let directory = try #require(ProcessInfo.processInfo.environment["BETTERTILE_TAB_PREVIEW_DIR"])
    _ = NSApplication.shared
    let model = makeModel(system: FakeAppWindowSystem())
    defer { model.shutdown() }
    for (name, appearanceName) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
        let appearance = try #require(NSAppearance(named: appearanceName))
        let view = NSHostingView(rootView: WindowLayoutSettings(model: model))
        let panel = NSPanel(contentRect: NSRect(x: 12000, y: 0, width: 750, height: 1300),
                            styleMask: [.borderless], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.appearance = appearance
        panel.contentView = view
        view.appearance = appearance
        view.layoutSubtreeIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        appearance.performAsCurrentDrawingAppearance { view.cacheDisplay(in: view.bounds, to: bitmap) }
        try bitmap.representation(using: .png, properties: [:])?.write(
            to: URL(fileURLWithPath: directory).appendingPathComponent("window-layout-\(name).png")
        )
        panel.close()
    }
}
