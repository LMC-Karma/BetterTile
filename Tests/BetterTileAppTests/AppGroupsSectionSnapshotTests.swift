import AppKit
import BetterTileCore
import SwiftUI
import Testing
@testable import BetterTileApp

@MainActor @Suite(.appTestApplication, .serialized, .settingsUI) struct AppGroupsSectionSnapshotTests {
    @Test func snapshots() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = InMemoryAppGroupsPreferences()
        let apps = [ApplicationChoice(bundleIdentifier: "com.apple.Safari", name: "Safari", url: URL(filePath: "/fake/Safari.app")),
                    ApplicationChoice(bundleIdentifier: "com.brave.Browser", name: "Brave Browser", url: URL(filePath: "/fake/Brave.app")),
                    ApplicationChoice(bundleIdentifier: "com.google.Chrome", name: "Google Chrome", url: URL(filePath: "/fake/Chrome.app")),
                    ApplicationChoice(bundleIdentifier: "com.google.Canary", name: "Chrome Canary", url: URL(filePath: "/fake/Canary.app"))]
        let store = AppGroupsStore(directory: root, catalog: { apps }, preferences: defaults, defaultBrowserURL: { nil })
        await store.load()
        for dark in [false, true] {
            try capture(AppGroupsSection(store: store, didChange: {}), name: "suggestions", dark: dark)
            try capture(AppGroupsRenameSheet(group: "Browser", save: {}, discard: {}, cancel: {}), name: "rename", dark: dark, width: 420, height: 160)
            let failures = [AppGroupsStore.RenameFailure(url: root.appendingPathComponent("uuid.json"), reason: "The file changed outside BetterTile.", layoutName: "Homework")]
            try capture(AppGroupsFailureSheet(old: "Browser", new: "Web", failures: failures, done: {}), name: "partial-failure", dark: dark, width: 420, height: 190)
        }
        let document = AppGroupsDocument(groups: [.init(name: "Browser", apps: [.init(name: "Safari", bundleID: "com.apple.Safari"), .init(name: "Brave"), .init(name: "Chrome"), .init(bundleID: "com.example.missing")])])
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try document.encode().write(to: store.fileURL)
        await store.reload()
        let model = AppGroupsSectionModel(store: store, didChange: {})
        #expect(model.displayName(.init(bundleID: "com.example.missing")) == "An app that is not installed")
        for dark in [false, true] { try capture(AppGroupsSection(store: store, didChange: {}), name: "problem-detail", dark: dark) }
        try store.save(.init())
        for dark in [false, true] { try capture(AppGroupsSection(store: store, didChange: {}), name: "empty", dark: dark) }
        let missing = AppGroupsStore(directory: root.appendingPathComponent("missing"), catalog: { [] }, preferences: defaults, defaultBrowserURL: { nil })
        await missing.load()
        for dark in [false, true] { try capture(AppGroupsSection(store: missing, didChange: {}), name: "no-suggestions", dark: dark) }
    }
    private func capture<V: View>(_ content: V, name: String, dark: Bool, width: CGFloat = 700, height: CGFloat = 460) throws {
        let host = NSHostingView(rootView: content.environment(\.colorScheme, dark ? .dark : .light)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(nsColor: .windowBackgroundColor)))
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let window = OffscreenTestWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.appearance = appearance; host.appearance = appearance; window.contentView = host
        defer { window.close() }
        try settleSavedLayoutSnapshot(host)
        #expect(host.fittingSize.width > 0 && host.fittingSize.height > 0)
        guard let directory = ProcessInfo.processInfo.environment["BT_SNAPSHOT_DIR"] else { return }
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try data.write(to: URL(filePath: directory).appendingPathComponent("app-groups-\(name)-\(dark ? "dark" : "light").png"))
    }
}
