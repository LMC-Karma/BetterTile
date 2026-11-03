import AppKit
import BetterTileCore
import SwiftUI
import Testing
@testable import BetterTileApp

/// Hosts the Saved Layouts page on its own (no Settings shell) at a fixed width. With `BT_SNAPSHOT_DIR` set,
/// each case also writes a PNG there. Without it, the cases only check that the page renders.
@Suite(.appTestApplication, .serialized, .settingsUI) @MainActor struct SavedLayoutPageSnapshotTests {
    @Test func settingsAndCanvasGeometryStayOnTheApprovedTokens() {
        #expect([SettingsRadius.window, SettingsRadius.panel, SettingsRadius.sidebar,
                 SettingsRadius.inner, SettingsRadius.control, SettingsRadius.mini] == [16, 12, 10, 8, 6, 4])
        for radius in [SettingsRadius.window, SettingsRadius.panel, SettingsRadius.sidebar,
                       SettingsRadius.inner, SettingsRadius.control, SettingsRadius.mini] {
            let shape = RoundedRectangle.settings(radius)
            #expect(shape.cornerSize == CGSize(width: radius, height: radius))
            #expect(shape.style == .continuous)
        }
        #expect(SettingsMetrics.rowMinHeight == 36)
        // FB-ROWS canvas geometry stays independent of the 36 pt Settings rows.
        #expect(SavedLayoutMetrics.rowHeight == 32)
        #expect(SavedLayoutMetrics.stageRadius == 8)
        #expect(SavedLayoutMetrics.paneRadius == 6)
        #expect(SavedLayoutMetrics.chipRadius == 4)
        #expect(SavedLayoutMetrics.chipIcon == 40)
        #expect(SavedLayoutMetrics.chipNameGap == 6)
    }

    enum Scene: String, CaseIterable, CustomTestStringConvertible {
        case populated, emptySelected = "empty-selected", tabbed, manual, firstUse = "first-use", long, many, applying, failed, done, already
        var testDescription: String { rawValue }
    }

    private static func app(_ id: String, _ name: String, _ path: String) -> ApplicationChoice {
        ApplicationChoice(bundleIdentifier: id, name: name, url: URL(filePath: path))
    }
    static let installed = [
        app("com.apple.Safari", "Safari", "/Applications/Safari.app"),
        app("com.apple.dt.Xcode", "Xcode", "/Applications/Xcode.app"),
        app("com.apple.Notes", "Notes", "/System/Applications/Notes.app"),
        app("com.apple.mail", "Mail", "/System/Applications/Mail.app"),
        app("com.apple.Terminal", "Terminal", "/System/Applications/Utilities/Terminal.app"),
        app("com.apple.calculator", "Calculator", "/System/Applications/Calculator.app"),
        app("com.apple.iCal", "Calendar", "/System/Applications/Calendar.app"),
        app("com.apple.TextEdit", "TextEdit", "/System/Applications/TextEdit.app"),
    ]

    private func editor(_ scene: Scene, directory: URL) throws -> SavedLayoutEditor {
        let editor = SavedLayoutEditor(files: .init(directory: directory))
        guard scene != .firstUse else { return editor }
        editor.newLayout()
        #expect(editor.edit { document in
            document = SavedLayoutDocument(name: "Work focus", mode: .bento,
                layout: .split(axis: .vertical, ratios: [0.5, 0.5], children: [.slot("browser"),
                    .split(axis: .horizontal, ratios: [0.5, 0.5], children: [.slot("editor"), .empty])]),
                slots: [.init(id: "browser", bundleID: "com.apple.Safari"), .init(id: "editor", bundleID: "com.apple.dt.Xcode")],
                paneGap: 6)
        })
        #expect(editor.save(as: "Work focus"))
        editor.select(path: [1, 0])
        switch scene {
        case .emptySelected: editor.select(path: [1, 1])
        case .tabbed:
            editor.setMode(.tabbed)
            let document = try #require(editor.document)
            let pane = try #require(SavedLayoutCanvasGeometry.panes(document).first)
            editor.assign(bundleID: "com.apple.Notes", pane: pane)
            editor.selectedPane = pane.id
        case .manual:
            editor.setMode(.manual)
            editor.selectedRectangle = "editor"
        case .many:
            for index in 1...24 { #expect(editor.save(as: "Workspace \(index)")) }
        case .long:
            #expect(editor.edit { $0.name = "Research, writing, and review for the autumn product launch across the team" })
        default: break
        }
        return editor
    }

    struct Variant: CustomTestStringConvertible {
        var dark: Bool, width: Double
        var testDescription: String { "\(dark ? "dark" : "light") \(Int(width))" }
    }
    nonisolated static let variants: [Variant] = ProcessInfo.processInfo.environment["BT_SNAPSHOT_DIR"] == nil
        ? [Variant(dark: false, width: 760)]
        : [false, true].flatMap { dark in [640.0, 980, 1280].map { Variant(dark: dark, width: $0) } }

    @Test(arguments: Scene.allCases, variants)
    func pageRenders(_ scene: Scene, variant: Variant) async throws {
        let dark = variant.dark
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appending(path: "SavedLayoutPage-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let editor = try editor(scene, directory: directory.appending(path: "layouts"))
        let model = makeOffscreenModel(store: .init(fileURL: directory.appending(path: "configuration.json")),
                                    system: FakeAppWindowSystem(), startRuntime: false)
        defer { model.shutdown() }
        model.hasAccessibilityPermission = true
        let recent = RecentApplications(defaults: MemoryDefaults())
        recent.record("com.apple.Notes"); recent.record("com.apple.Terminal")
        let source = SavedLayoutPaletteSource(installed: { Self.installed }, running: {
            [Self.installed[0], Self.installed[1], Self.installed[3]]
        }, recent: recent, windowCount: { ["com.apple.Safari": 2, "com.apple.mail": 1][$0] })
        let fixture = ApplySessionFixture()
        let desktop = SavedLayoutDesktop(displayID: fixture.display, spaceID: .init(rawValue: 1))
        if let document = editor.document {
            fixture.rows = document.slots.map { .init(slot: $0, appName: $0.id == "browser" ? "Safari" : "Xcode", status: .empty) }
            if [.applying, .failed, .done, .already].contains(scene) {
                fixture.session.apply(document: document, displayID: fixture.display)
                fixture.runtime.owner = .init(document: document, desktop: desktop)
                fixture.runtime.slotStatuses = ["browser": .placed, "editor": .placed]
                fixture.runtime.isRunning = scene == .applying
                if scene == .applying { fixture.runtime.slotStatuses["editor"] = .waiting }
                if scene == .failed { fixture.runtime.slotStatuses["editor"] = .failed(reason: "Xcode could not be placed.") }
                var result = SavedLayoutApplyResult(placed: scene == .failed ? 1 : 2,
                    placedSlots: scene == .failed ? ["browser"] : ["browser", "editor"])
                if scene == .failed { result.issues = [.init(.couldNotFit, "Xcode could not be placed.", slotID: "editor")] }
                result.recordSlots(document.slots.map(\.id))
                fixture.runtime.lastRun = .init(layoutName: document.name, offersUndo: scene != .already, date: Date(timeIntervalSince1970: 1000), displayID: fixture.display, result: result)
                fixture.runtime.canUndo = scene != .already
            }
        }
        let size = NSSize(width: variant.width, height: scene == .firstUse ? 560 : 1000)
        let page = SavedLayoutSettings(editor: editor, model: model, paletteSource: source,
            suppliedSession: fixture.session, targetOverride: desktop, targetNameOverride: "Virtual 16:9")
            .frame(width: size.width, height: size.height)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, dark ? .dark : .light)
            .defaultAppStorage(MemoryDefaults())
        let host = NSHostingView(rootView: AnyView(page))
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        host.appearance = appearance
        let window = OffscreenTestWindow(contentRect: NSRect(origin: NSPoint(x: 12000, y: 0), size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = appearance
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        try await waitForSavedLayoutSnapshot(in: host)
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        if let output = ProcessInfo.processInfo.environment["BT_SNAPSHOT_DIR"] {
            try #require(bitmap.representation(using: .png, properties: [:])).write(
                to: URL(filePath: output).appending(path: "page-\(scene.rawValue)-\(dark ? "dark" : "light")-\(Int(variant.width)).png"))
        }
        #expect(bitmap.pixelsWide > 0)
    }

    /// The canvas with a plan badge on each pane: Ready, Choose window, Will open, Not installed (dimmed).
    @Test(arguments: [false, true])
    func canvasShowsPlanBadges(dark: Bool) async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appending(path: "SavedLayoutBadges-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let editor = SavedLayoutEditor(files: .init(directory: directory))
        editor.newLayout()
        #expect(editor.edit { document in
            document = SavedLayoutDocument(name: "Review setup", mode: .bento,
                layout: .split(axis: .vertical, ratios: [0.5, 0.5], children: [
                    .split(axis: .horizontal, ratios: [0.5, 0.5], children: [.slot("a"), .slot("b")]),
                    .split(axis: .horizontal, ratios: [0.5, 0.5], children: [.slot("c"), .slot("d")])]),
                slots: [.init(id: "a", bundleID: "com.apple.Safari"), .init(id: "b", bundleID: "com.apple.dt.Xcode"),
                        .init(id: "c", bundleID: "com.apple.Notes"), .init(id: "d", bundleID: "org.example.Missing")])
        })
        let badges: [String: SavedLayoutPaneBadge] = [
            "0.0": .init(text: "Ready", tone: .ok),
            "0.1": .init(text: "Choose window", tone: .warning, detail: "3 windows", chooses: true),
            "1.0": .init(text: "Will open", tone: .info, detail: "Not running"),
            "1.1": .init(text: "Not installed", tone: .neutral, detail: "Skipped", dimmed: true),
        ]
        let document = try #require(editor.document)
        let canvas = SavedLayoutCanvasView(editor: editor, document: document,
            paletteSource: SavedLayoutPaletteSource(installed: { Self.installed }, running: { [] },
                                                    recent: RecentApplications(defaults: MemoryDefaults())),
            paneBadge: { badges[$0.id] }, badgeChooser: { _ in AnyView(EmptyView()) },
            displaySize: CGSize(width: 1512, height: 950))
            .padding(16).frame(width: 720)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, dark ? .dark : .light)
        let host = NSHostingView(rootView: AnyView(canvas))
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let window = OffscreenTestWindow(contentRect: NSRect(x: 12000, y: 0, width: 720, height: 900), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.appearance = host.appearance
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        try await waitForSavedLayoutSnapshot(in: host)
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        if let output = ProcessInfo.processInfo.environment["BT_SNAPSHOT_DIR"] {
            try #require(bitmap.representation(using: .png, properties: [:])).write(
                to: URL(filePath: output).appending(path: "canvas-badges-\(dark ? "dark" : "light").png"))
        }
        #expect(bitmap.pixelsWide > 0)
    }
}
