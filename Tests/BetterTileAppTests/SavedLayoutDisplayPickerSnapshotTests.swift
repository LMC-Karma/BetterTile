import AppKit
import BetterTileCore
import SwiftUI
import Testing
@testable import BetterTileApp

/// Page-only captures at the same widths as the New Layout capture matrix. No window is ordered.
@Suite(.appTestApplication, .serialized, .settingsUI) @MainActor struct SavedLayoutDisplayPickerSnapshotTests {
    enum Scene: String, CaseIterable { case single, three, disconnected, recovery, followingRecovery, applying }
    struct Variant: Sendable { let dark: Bool; let width: Int }
    nonisolated static let variants = [false, true].flatMap { dark in [980, 1280].map { Variant(dark: dark, width: $0) } }

    @Test(arguments: Scene.allCases, variants)
    func page(scene: Scene, variant: Variant) async throws {
        _ = NSApplication.shared
        let f = SavedLayoutDisplayPickerFixture()
        defer { f.close() }
        if scene == .single { f.live = [SavedLayoutDisplayPickerFixture.a] }
        f.refresh()
        if scene == .three { f.page.pickDisplay(SavedLayoutDisplayPickerFixture.b.id) }
        if scene == .disconnected {
            f.page.pickDisplay(SavedLayoutDisplayPickerFixture.a.id)
            f.live.removeFirst(); f.refresh()
        }
        if scene == .recovery || scene == .applying {
            f.page.pickDisplay(SavedLayoutDisplayPickerFixture.a.id)
            f.page.apply(f.document)
            if scene == .recovery {
                try await f.finish()
                f.page.pickDisplay(SavedLayoutDisplayPickerFixture.b.id)
            }
        }
        if scene == .followingRecovery {
            f.page.apply(f.document); try await f.finish()
            f.current = SavedLayoutDisplayPickerFixture.b.id; f.refresh()
        }
        #expect(f.editor.save(as: "Writing"))
        let palette = SavedLayoutPaletteSource(installed: { SavedLayoutPageSnapshotTests.installed },
            running: { [] }, recent: RecentApplications(defaults: MemoryDefaults()))
        let size = NSSize(width: variant.width, height: 800)
        let page = SavedLayoutSettings(editor: f.editor, model: f.model, paletteSource: palette,
            suppliedSession: f.session, readTargetDisplays: { f.live })
        let host = NSHostingView(rootView: page.frame(width: size.width, height: size.height)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, variant.dark ? .dark : .light).defaultAppStorage(MemoryDefaults()))
        let appearance = NSAppearance(named: variant.dark ? .darkAqua : .aqua)
        host.appearance = appearance
        let window = NSWindow(contentRect: NSRect(origin: .init(x: 12000, y: 0), size: size),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = appearance
        window.contentView = host
        defer { window.close() }
        try await waitForSavedLayoutSnapshot(in: host)
        #expect(!window.isVisible)
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        appearance?.performAsCurrentDrawingAppearance { host.cacheDisplay(in: host.bounds, to: bitmap) }
        if let output = ProcessInfo.processInfo.environment["BT_SNAPSHOT_DIR"] {
            let path = URL(filePath: output).appending(path: "picker-\(scene.rawValue)-\(variant.dark ? "dark" : "light")-\(variant.width).png")
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: path)
        }
    }
}
