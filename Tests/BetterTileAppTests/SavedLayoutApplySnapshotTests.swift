import AppKit
import BetterTileCore
import SwiftUI
import Testing
@testable import BetterTileApp

/// Offline hosting only. The window is never ordered and no Accessibility windows are read.
@Suite(.appTestApplication, .settingsUI) @MainActor struct SavedLayoutApplySnapshotTests {
    @Test(arguments: [false, true])
    func windowChoiceSnapshot(dark: Bool) throws {
        let f = ApplySessionFixture()
        let content = AnyView(SavedLayoutWindowChoiceList(appName: "TextEdit",
            windows: [f.window("one"), f.window("two", title: ""),
                      f.window("three", title: "A long live document title that must truncate within the choice list")],
            chosen: .init(rawValue: "one"), choose: { _ in }))
        let root = content.frame(width: 380)
            .fixedSize(horizontal: false, vertical: true)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, dark ? .dark : .light)
            .environment(\.controlActiveState, .active)
        let view = NSHostingView(rootView: root)
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        view.appearance = appearance
        view.frame = NSRect(x: 0, y: 0, width: 380, height: 800)
        let window = OffscreenTestWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = appearance
        window.contentView = view
        defer { window.close() }
        try settleSavedLayoutSnapshot(view)
        window.setContentSize(NSSize(width: view.frame.width, height: max(80, view.fittingSize.height)))
        view.frame = NSRect(origin: .zero, size: window.contentLayoutRect.size)
        try settleSavedLayoutSnapshot(view)
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        #expect(bitmap.pixelsWide >= Int(view.bounds.width))
        #expect(bitmap.pixelsHigh > 40)
        if let directory = ProcessInfo.processInfo.environment["BT_SNAPSHOT_DIR"] {
            let folder = URL(fileURLWithPath: directory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try #require(bitmap.representation(using: .png, properties: [:])).write(
                to: folder.appendingPathComponent("apply-window-choice-\(dark ? "dark" : "light").png"))
        }
    }
}
