import AppKit
import BetterTileCore
import BetterTileMacOS
import SwiftUI
import Testing
@testable import BetterTileApp

@Suite(.appTestApplication, .serialized, .settingsUI) @MainActor struct SavedLayoutV2SnapshotTests {
    enum Scene: String, CaseIterable { case page, export, popover, unknownGroup = "unknown-group", longList = "long-list", manual, update, updateModeChange = "update-mode-change", importGroups = "import", picker, referencePicker = "reference-tabbed-picker" }
    static let apps = [
        ApplicationChoice(bundleIdentifier: "com.apple.Preview", name: "Preview", url: URL(filePath: "/System/Applications/Preview.app")),
        ApplicationChoice(bundleIdentifier: "com.apple.Safari", name: "Safari", url: URL(filePath: "/Applications/Safari.app")),
        ApplicationChoice(bundleIdentifier: "com.apple.Notes", name: "Notes", url: URL(filePath: "/System/Applications/Notes.app")),
        ApplicationChoice(bundleIdentifier: "com.apple.mail", name: "Mail", url: URL(filePath: "/System/Applications/Mail.app")),
        ApplicationChoice(bundleIdentifier: "com.apple.iBooksX", name: "Books", url: URL(filePath: "/System/Applications/Books.app"))
    ]
    static let groups = AppGroupsDocument(groups: [.init(name: "Browser", apps: [.init(name: "Safari", bundleID: "com.apple.Safari")])])
    static var preferences: [AppPreference] { [.app(apps[0].id), .group("Browser"), .app(apps[1].id), .app(apps[2].id), .app(apps[3].id), .app(apps[4].id)] }

    @Test(arguments: Scene.allCases, [false, true])
    func chosenScenesRender(_ scene: Scene, dark: Bool) async throws {
        let fixture = SavedLayoutDisplayPickerFixture()
        defer { fixture.close() }
        let editor = fixture.editor
        _ = editor.edit { document in
            document = .init(name: "Homework", mode: .bento,
                layout: .split(axis: .vertical, ratios: [0.6, 0.4], children: [.slot("a"),
                    .split(axis: .horizontal, ratios: [0.5, 0.5], children: [.slot("b"), .slot("c")])]),
                slots: [.init(id: "a", prefer: Self.preferences), .init(id: "b", prefer: [.group("Browser")]),
                    .init(id: "c", prefer: [.app(Self.apps[2].id), .app(Self.apps[3].id)])],
                extraWindows: .addAsPanes, keepForNewWindows: true)
        }
        await fixture.model.appGroupsStore.load()
        try fixture.model.appGroupsStore.save(Self.groups)
        #expect(editor.save())
        let applications = Dictionary(uniqueKeysWithValues: Self.apps.map { ($0.id, $0) })
        let palette = SavedLayoutPaletteSource(installed: { Self.apps }, running: { [Self.apps[0], Self.apps[1]] },
            recent: RecentApplications(defaults: MemoryDefaults()), windowCount: { _ in nil })
        let content: AnyView
        let size: NSSize
        var glass = false
        switch scene {
        case .page:
            fixture.system.windows = [WindowSnapshot(id: .init(rawValue: "preview"), processIdentifier: 0, bundleIdentifier: Self.apps[0].id,
                frame: .init(x: 0, y: 0, width: 600, height: 800), displayID: SavedLayoutDisplayPickerFixture.a.id)]
            content = AnyView(SavedLayoutSettings(editor: editor, model: fixture.model, paletteSource: palette,
                suppliedSession: fixture.session, readTargetDisplays: { fixture.live }))
            size = .init(width: 980, height: 1080)
        case .popover, .unknownGroup, .longList:
            if scene == .unknownGroup { _ = editor.edit { $0.slots[0].prefer = [.app(Self.apps[0].id), .group("Reading"), .app(Self.apps[1].id)] } }
            if scene == .longList { _ = editor.edit { $0.slots[0].prefer += (0..<10).map { .group("Missing group \($0 + 1)") } } }
            content = AnyView(SavedLayoutPanePreferences(editor: editor, slotID: "a", title: "Left pane", groups: Self.groups,
                applications: applications, paletteSource: palette))
            size = .init(width: 340, height: 460); glass = true
        case .export:
            content = AnyView(SavedLayoutExportSheet(document: try #require(editor.document), groups: Self.groups, onCancel: {}, onExport: {}))
            size = .init(width: 420, height: 260)
        case .manual:
            #expect(editor.edit { document in
                document.mode = .manual; document.layout = nil; document.groups = []; document.extraWindows = .float
                document.slots = [document.slots[0], document.slots[2]]
                document.windows = [.init(slot: "a", rect: .init(x: 0.06, y: 0.12, width: 0.46, height: 0.66)),
                    .init(slot: "c", rect: .init(x: 0.65, y: 0.25, width: 0.3, height: 0.55))]
            })
            let document = try #require(editor.document)
            content = AnyView(VStack(alignment: .leading, spacing: 16) {
                Text("Homework · Manual").font(SettingsFont.headline)
                SavedLayoutPagePreview(document: document, applications: applications, appGroups: Self.groups)
                Text("Now on Built-in Display").font(SettingsFont.caption).foregroundStyle(.secondary)
                Text("Rectangle 1 — Preview (1st choice)").font(SettingsFont.body)
                Text("Rectangle 2 — Notes (1st choice)").font(SettingsFont.body)
            }.padding(20))
            size = .init(width: 600, height: 460)
        case .update, .updateModeChange:
            content = AnyView(SavedLayoutUpdateConfirmation(name: "Homework", turnsOffExtraWindows: scene == .updateModeChange, onCancel: {}, onUpdate: {}))
            size = .init(width: 420, height: scene == .updateModeChange ? 260 : 220)
        case .importGroups:
            let source = fixture.directory.appending(path: "import.json")
            let reading = AppGroup(name: "Reading", apps: [.init(name: "Preview", bundleID: Self.apps[0].id), .init(name: "Books", bundleID: Self.apps[4].id)])
            var document = try #require(editor.document)
            document.slots[0].prefer = [.group("Reading")]
            try SavedLayoutTransfer.encode(document, groups: .init(groups: [reading])).write(to: source)
            #expect(!editor.beginImport(source, groups: fixture.model.appGroupsStore))
            content = AnyView(SavedLayoutImportSheet(editor: editor, groups: Self.groups, onImport: {}, onCancel: {}))
            size = .init(width: 440, height: 350)
        case .referencePicker:
            let request = PaneApplicationRequest(paneID: UUID(), paneNumber: 1,
                displayID: .init(rawValue: "snapshot"), sessionID: .init(rawValue: UUID()),
                spaceID: nil, generation: 0, workArea: .init(x: 0, y: 0, width: 1000, height: 800))
            content = AnyView(PaneApplicationPicker(request: request, installedApplications: { Self.apps },
                runningApplications: { [Self.apps[1]] }, recentApplications: RecentApplications(defaults: MemoryDefaults())))
            size = .init(width: 320, height: 420); glass = true
        case .picker:
            content = AnyView(PanePreferenceApplicationPicker(groups: Self.groups, selected: [], installedApplications: { Self.apps },
                runningApplications: { [Self.apps[1]] }, recentApplications: RecentApplications(defaults: MemoryDefaults()), onAdd: { _ in }, onDone: {}))
            size = .init(width: 320, height: 420); glass = true
        }
        try await render(content, size: size, dark: dark, glass: glass, name: scene.rawValue)
    }

    private func render(_ content: AnyView, size: NSSize, dark: Bool, glass: Bool, name: String) async throws {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let previousAppearance = NSApp.appearance
        NSApp.appearance = appearance
        defer { NSApp.appearance = previousAppearance }
        let backed = glass ? content : AnyView(content.background(Color(nsColor: .windowBackgroundColor)))
        let host = NSHostingView(rootView: backed.frame(width: size.width, height: size.height)
            .environment(\.colorScheme, dark ? .dark : .light).defaultAppStorage(MemoryDefaults()))
        host.frame = NSRect(origin: .zero, size: size); host.appearance = appearance
        let root: NSView
        if glass { root = PopupGlassHost(content: host) }
        else {
            host.wantsLayer = true
            root = host
        }
        root.frame = NSRect(origin: .zero, size: size)
        let window = OffscreenTestWindow(contentRect: NSRect(origin: NSPoint(x: 12000, y: 0), size: size),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.appearance = appearance
        window.backgroundColor = .windowBackgroundColor; window.contentView = root
        window.orderFrontForTesting()
        defer { window.close() }
        try await waitForSavedLayoutSnapshot(in: root)
        let bitmap = try #require(root.bitmapImageRepForCachingDisplay(in: root.bounds))
        root.cacheDisplay(in: root.bounds, to: bitmap)
        #expect(bitmap.pixelsWide > 0 && bitmap.pixelsHigh > 0)
        if let output = ProcessInfo.processInfo.environment["BT_SNAPSHOT_DIR"] {
            try #require(bitmap.representation(using: .png, properties: [:])).write(
                to: URL(filePath: output).appending(path: "slv2-3a-\(name)-\(dark ? "dark" : "light").png"))
        }
    }
}
