import AppKit
import SwiftUI
import Testing
@testable import BetterTileApp

/// Hosts the shared app picker at popover size (320 × 420). With `BT_SNAPSHOT_DIR` set,
/// each case also writes a PNG there. Without it, the cases only check that rows render.
@Suite(.appTestApplication, .serialized) @MainActor struct ApplicationPickerSnapshotTests {
    enum Scene: String, CaseIterable, CustomTestStringConvertible {
        case populated, keyboard, search, noResults = "no-results", longNames = "long-names", noRunning = "no-running"
        var testDescription: String { rawValue }
    }

    private static func app(_ id: String, _ name: String, _ path: String) -> ApplicationChoice {
        ApplicationChoice(bundleIdentifier: id, name: name, url: URL(filePath: path))
    }

    private static let safari = app("com.apple.Safari", "Safari", "/Applications/Safari.app")
    private static let notes = app("com.apple.Notes", "Notes", "/System/Applications/Notes.app")
    private static let mail = app("com.apple.mail", "Mail", "/System/Applications/Mail.app")
    private static let terminal = app("com.apple.Terminal", "Terminal", "/System/Applications/Utilities/Terminal.app")
    private static let calculator = app("com.apple.calculator", "Calculator", "/System/Applications/Calculator.app")
    private static let calendar = app("com.apple.iCal", "Calendar", "/System/Applications/Calendar.app")
    private static let textEdit = app("com.apple.TextEdit", "TextEdit", "/System/Applications/TextEdit.app")
    private static let editorCopy = app("com.example.Editor.beta", "TextEdit",
                                        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Applications/TextEdit.app").path)
    private static let longName = app("com.microsoft.VSCodeInsiders", "Microsoft Visual Studio Code — Insiders Edition for Testing",
                                      "/Applications/Visual Studio Code - Insiders.app")

    private struct Fixture {
        var installed: [ApplicationChoice]
        var running: [ApplicationChoice]
        var recent: [String]
        var search = ""
        var downPresses = 0
    }

    private func fixture(_ scene: Scene) -> Fixture {
        let all = [Self.safari, Self.notes, Self.mail, Self.terminal, Self.calculator, Self.calendar, Self.textEdit, Self.editorCopy]
        switch scene {
        case .populated: return Fixture(installed: all, running: [Self.safari, Self.mail], recent: ["com.apple.Notes", "com.apple.Terminal"])
        case .keyboard: return Fixture(installed: all, running: [Self.safari, Self.mail], recent: ["com.apple.Notes", "com.apple.Terminal"], downPresses: 2)
        case .search: return Fixture(installed: all, running: [Self.safari], recent: [], search: "te")
        case .noResults: return Fixture(installed: all, running: [Self.safari], recent: [], search: "zzq")
        case .longNames: return Fixture(installed: all + [Self.longName], running: [Self.longName, Self.safari],
                                        recent: ["com.microsoft.VSCodeInsiders", "com.apple.Notes"])
        case .noRunning: return Fixture(installed: all, running: [], recent: ["com.apple.Safari", "com.apple.Notes"], downPresses: 1)
        }
    }

    @Test(arguments: Scene.allCases, [false, true])
    func pickerRendersScene(_ scene: Scene, dark: Bool) async throws {
        _ = NSApplication.shared
        let fixture = fixture(scene)
        let recent = RecentApplications(defaults: MemoryDefaults())
        for id in fixture.recent.reversed() { recent.record(id) }
        let installed = fixture.installed
        let running = fixture.running
        var picker = ApplicationPicker(exclusions: [], installedApplications: { installed }, runningApplications: { running },
                                       recentApplications: recent, resolveApplication: { _ in nil }, onChoose: { _ in })
        let readiness = ReadinessBox()
        picker.onPresentationChange = { readiness.value = $0 }
        let size = NSSize(width: 320, height: 420)
        let content = picker
            .padding(12)
            .frame(width: size.width, height: size.height)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, dark ? .dark : .light)
        let view = NSHostingView(rootView: AnyView(content))
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        view.appearance = appearance
        let window = OffscreenTestWindow(contentRect: NSRect(origin: NSPoint(x: 12000, y: 0), size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = appearance
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer { window.close() }
        try await settle(view, readiness)
        let field = try #require(subviews(of: view).compactMap { $0 as? NSSearchField }.first)
        if !fixture.search.isEmpty {
            #expect(window.makeFirstResponder(field))
            let editor = try #require(field.currentEditor() as? NSTextView)
            editor.insertText(fixture.search, replacementRange: editor.selectedRange())
            try await settle(view, readiness)
        }
        for _ in 0..<fixture.downPresses {
            let editor = try #require(field.currentEditor() as? NSTextView)
            editor.doCommand(by: #selector(NSResponder.moveDown(_:)))
            try await settle(view, readiness)
        }
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        if let directory = ProcessInfo.processInfo.environment["BT_SNAPSHOT_DIR"] {
            let url = URL(filePath: directory).appending(path: "picker-\(scene.rawValue)-\(dark ? "dark" : "light").png")
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: url)
        }
        #expect(bitmap.pixelsWide > 0)
    }

    /// Waits until the picker has loaded and its published rows and highlight stay the same
    /// for several layout opportunities in a row.
    private func settle(_ view: NSView, _ readiness: ReadinessBox) async throws {
        var previous: ApplicationPickerReadiness?
        var unchanged = 0
        try await waitForSettingsUI("the picker to finish updating", in: view) {
            let current = readiness.value
            unchanged = current != nil && current == previous && current?.isLoading == false ? unchanged + 1 : 0
            previous = current
            return unchanged >= 3
        }
    }

    @MainActor private final class ReadinessBox {
        var value: ApplicationPickerReadiness?
    }

    private func subviews(of view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(subviews(of:))
    }
}
