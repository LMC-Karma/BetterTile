import AppKit
import BetterTileCore
import SwiftUI
import Testing
@testable import BetterTileApp

@Suite(.appTestApplication, .serialized, .settingsUI) @MainActor struct SavedLayoutCreationSnapshotTests {
    enum Scene: String, CaseIterable { case library, empty, noAccess, emptyNoAccess, draft, saved, saveError, setup, manualSetup, tabbedSetup }

    struct Variant: Sendable { let dark: Bool; let width: Int }
    nonisolated static let variants = [false, true].flatMap { dark in [980, 1280].map { Variant(dark: dark, width: $0) } }

    @Test(arguments: Scene.allCases, variants)
    func pageAndSetup(scene: Scene, variant: Variant) async throws {
        let dark = variant.dark, width = variant.width
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let editor = SavedLayoutEditor(files: .init(directory: directory.appending(path: "layouts")))
        let flow = SavedLayoutCreation()
        let model = BetterTileModel(store: .init(fileURL: directory.appending(path: "config.json")), system: FakeAppWindowSystem(), startRuntime: false)
        defer { model.shutdown() }
        model.hasAccessibilityPermission = ![.noAccess, .emptyNoAccess].contains(scene)
        let fixture = ApplySessionFixture()
        let desktop = SavedLayoutDesktop(displayID: fixture.display, spaceID: .init(rawValue: 1))
        if ![.empty, .emptyNoAccess].contains(scene) {
            editor.newLayout()
            editor.setPreset(.columns)
            editor.edit { $0.name = "Writing" }
            editor.assign(bundleID: "com.apple.Safari", pane: SavedLayoutCanvasGeometry.panes(try #require(editor.document)).first)
            #expect(editor.save(as: "Writing"))
        }
        if [.draft, .saved, .saveError].contains(scene) {
            flow.begin(.init(name: "Research"), editor: editor)
            editor.assign(bundleID: "com.apple.Safari", pane: SavedLayoutCanvasGeometry.panes(try #require(editor.document)).first)
            if scene == .saved { #expect(flow.save(editor: editor)) }
            if scene == .saveError { editor.reportFailure("Couldn’t save: Folder access is unavailable. Your draft was kept. Check folder access, retry, or Save As.") }
        }
        let palette = SavedLayoutPaletteSource(installed: { SavedLayoutPageSnapshotTests.installed }, running: { [] }, recent: RecentApplications(defaults: MemoryDefaults()))
        let page: AnyView
        if [.setup, .manualSetup, .tabbedSetup].contains(scene) {
            page = AnyView(SavedLayoutNewLayoutSheet(setup: .init(mode: scene == .manualSetup ? .manual : scene == .tabbedSetup ? .tabbed : .bento), onCancel: {}, onContinue: { _ in })
                .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle.settings(SettingsRadius.panel))
                .frame(width: CGFloat(width), height: 672))
        } else {
            page = AnyView(SavedLayoutSettings(editor: editor, model: model, paletteSource: palette,
                suppliedSession: fixture.session, targetOverride: desktop, targetNameOverride: "BTTest-B", suppliedCreation: flow))
        }
        let size = NSSize(width: width, height: 672)
        let host = NSHostingView(rootView: page.frame(width: size.width, height: size.height)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, dark ? .dark : .light).defaultAppStorage(MemoryDefaults()))
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: 24000, y: 0), size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = host.appearance
        window.contentView = host
        defer { window.close() }
        var previous: NSSize?
        try await waitForSettingsUI("creation page layout", in: host) {
            defer { previous = host.fittingSize }
            return host.bounds.size == size && previous == host.fittingSize
        }
        if [.draft, .saveError].contains(scene) {
            func anchor(_ view: NSView) -> SavedLayoutStageAnchorView? {
                if let view = view as? SavedLayoutStageAnchorView { return view }
                return view.subviews.lazy.compactMap(anchor).first
            }
            try await waitForSettingsUI("draft canvas and palette", in: host) {
                anchor(host)?.presentation?.applicationsResolved == true
            }
        }
        #expect(!window.isVisible)
        if scene == .empty || scene == .emptyNoAccess { #expect(editor.document == nil) }
        if scene == .saved { #expect(!flow.isDraft); #expect(editor.url != nil) }
        #expect(fixture.starts.isEmpty)
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.appearance?.performAsCurrentDrawingAppearance { host.cacheDisplay(in: host.bounds, to: bitmap) }
        #expect(bitmap.pixelsWide > 0)
        if let output = ProcessInfo.processInfo.environment["BT_SNAPSHOT_DIR"] {
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: URL(filePath: output).appending(path: "new-\(scene.rawValue)-\(dark ? "dark" : "light")-\(width).png"))
        }
        // Exercise the real page's Save Layout key equivalent, not a second test-only save action.
        if scene == .draft {
            window.makeFirstResponder(host)
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                timestamp: 1000, windowNumber: window.windowNumber, context: nil,
                characters: "s", charactersIgnoringModifiers: "s", isARepeat: false, keyCode: 1))
            #expect(try withNativeEventLoop { window.performKeyEquivalent(with: event) })
            try await waitForSettingsUI("saved creation", in: host) { !flow.isDraft && editor.url != nil }
            #expect(!editor.isDirty)
            #expect(fixture.starts.isEmpty)
        }
    }
}
