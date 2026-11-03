import AppKit
import BetterTileCore
import SwiftUI
import Testing
@testable import BetterTileApp

@Suite(.appTestApplication, .serialized, .settingsUI) @MainActor struct SavedLayoutPageStateSnapshotTests {
    enum Scene: String, CaseIterable { case library, edit, editDirty, recovery, actions, delete, updated, disconnected, emptyAfterDelete }

    @Test(arguments: Scene.allCases, [false, true])
    func changedStates(_ scene: Scene, dark: Bool) async throws {
        _ = NSApplication.shared
        let f = SavedLayoutDisplayPickerFixture(); defer { f.close() }
        let store = DisplayTriggerStore.standard(files: f.editor.files)
        for name in ["Coding", "Design review with diagrams and notes", "Mail + Calendar", "Research", "Writing", "Xcode + Simulator"] {
            #expect(f.editor.save(as: name))
            if name == "Coding", let url = f.editor.url {
                #expect(store.bind(.init(layoutFile: url.lastPathComponent, enabled: true,
                    displays: [SavedLayoutDisplayPickerFixture.b.fingerprint], target: 0)))
            }
        }
        #expect(f.editor.load(try #require(f.editor.entries.first)))
        f.refresh(); f.page.pickDisplay(SavedLayoutDisplayPickerFixture.b.id)
        if scene == .disconnected {
            f.live.removeAll { $0.id == SavedLayoutDisplayPickerFixture.b.id }; f.refresh()
        }
        if scene == .editDirty { f.editor.edit { $0.paneGap = 4 } }
        if scene == .recovery {
            f.page.apply(f.document); try await f.finish(); f.refresh()
        }
        if scene == .updated { f.editor.message = "Updated from the current desktop. No windows were changed." }
        if scene == .emptyAfterDelete {
            while !f.editor.entries.isEmpty { #expect(f.editor.delete()) }
        }
        let page = SavedLayoutSettings(editor: f.editor, model: f.model, displayTriggers: store,
            paletteSource: .init(installed: { SavedLayoutPageSnapshotTests.installed }, running: { [] },
                recent: RecentApplications(defaults: MemoryDefaults())), suppliedSession: f.session,
            editing: scene == .edit || scene == .editDirty, readTargetDisplays: { f.live })
        let content: AnyView
        switch scene {
        case .delete: content = AnyView(page.deleteSheet)
        case .actions:
            // The actual menu content is rendered offscreen; no NSMenu is ordered onto a display.
            content = AnyView(VStack(alignment: .leading, spacing: 10) { page.fileMenuItems }.padding(20).frame(width: 360))
        default: content = AnyView(page.frame(width: 760, height: 1080))
        }
        let defaults = MemoryDefaults(); defaults.set(false, forKey: "savedLayoutsBindingsExpanded")
        let host = NSHostingView(rootView: content.background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, dark ? .dark : .light).defaultAppStorage(defaults))
        let size = scene == .delete ? NSSize(width: 478, height: 250) : scene == .actions ? NSSize(width: 360, height: 410) : NSSize(width: 760, height: 1080)
        let window = OffscreenTestWindow(contentRect: .init(origin: .init(x: 12000, y: 0), size: size),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        host.appearance = window.appearance; window.contentView = host
        defer { window.close() }
        try await waitForSavedLayoutSnapshot(in: host)
        #expect(!window.isVisible)
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        if let directory = ProcessInfo.processInfo.environment["BT_SNAPSHOT_DIR"] {
            try #require(bitmap.representation(using: .png, properties: [:])).write(
                to: URL(filePath: directory).appending(path: "a1-\(scene.rawValue)-\(dark ? "dark" : "light").png"))
        }
        #expect(bitmap.pixelsWide > 0)
    }
}
