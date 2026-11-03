import AppKit
import BetterTileCore
import SwiftUI
import Testing
@testable import BetterTileApp

@MainActor @Suite(.appTestApplication, .serialized) struct AppGroupsSectionTests {
    private func app(_ name: String, _ id: String) -> ApplicationChoice {
        .init(bundleIdentifier: id, name: name, url: URL(filePath: "/fake/\(id).app"))
    }
    private func setup(_ apps: [ApplicationChoice]) async -> (URL, AppGroupsStore, InMemoryAppGroupsPreferences) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let defaults = InMemoryAppGroupsPreferences()
        let store = AppGroupsStore(directory: root, catalog: { apps }, preferences: defaults, defaultBrowserURL: { nil })
        await store.load()
        return (root, store, defaults)
    }
    @Test func suggestionsPersistAndOtherBecomesNormal() async throws {
        let apps = [app("Safari", "com.apple.Safari"), app("Xcode", "com.apple.dt.Xcode")]
        let (root, store, defaults) = await setup(apps); defer { try? FileManager.default.removeItem(at: root) }
        #expect(store.suggestedNames == ["Browser", "Coding"])
        try store.keepSuggestion("Browser")
        #expect(String(decoding: try Data(contentsOf: store.fileURL), as: UTF8.self).hasPrefix("// BetterTile App Groups"))
        #expect(store.suggestedNames.isEmpty)
        #expect(store.document.groups.map(\.name) == ["Browser", "Coding"])
        let second = AppGroupsStore(directory: root, catalog: { apps }, preferences: defaults, defaultBrowserURL: { nil })
        await second.load(); #expect(second.suggestedNames.isEmpty)
        try FileManager.default.removeItem(at: second.fileURL)
        await second.reload(); try second.removeSuggestion("Browser")
        let third = AppGroupsStore(directory: root, catalog: { apps }, preferences: defaults, defaultBrowserURL: { nil })
        await third.load(); #expect(third.document.groups.map(\.name) == ["Coding"]); #expect(third.suggestedNames.isEmpty)
        try FileManager.default.removeItem(at: third.fileURL)
        await third.reload(); #expect(third.document.groups.map(\.name) == ["Coding"])
    }
    @Test func reorderChooseAndRevision() async throws {
        let apps = [app("Google Chrome", "com.google.Chrome"), app("Chrome Canary", "com.google.Canary")]
        let (root, store, _) = await setup(apps); defer { try? FileManager.default.removeItem(at: root) }
        try store.save(.init(groups: [.init(name: "Web", apps: [.init(name: "Chrome"), .init(name: "Missing")])]))
        var changes = 0
        let model = AppGroupsSectionModel(store: store, didChange: { changes += 1 })
        model.choose(apps[1], at: 0)
        #expect(store.document.groups[0].apps[0] == .init(name: "Chrome", bundleID: apps[1].id))
        model.move(from: 0, to: 2)
        let saved = try AppGroupsDocument.decode(Data(contentsOf: store.fileURL))
        #expect(saved.groups[0].apps.map(\.name) == ["Missing", "Chrome"])
        await model.reload(); #expect(changes == 3)
    }
    @Test func renameOrdersEditorActionsAndSaveFailureStops() async throws {
        let (root, store, _) = await setup([]); defer { try? FileManager.default.removeItem(at: root) }
        try store.save(.init(groups: [.init(name: "Old", apps: [])]))
        var events: [String] = []; var fail = false; var changes = 0
        let bridge = AppGroupsEditorBridge(hasUnsavedChanges: { true }, save: {
            events.append("save"); if fail { throw SavedLayoutFileError(message: "Save failed") }
        }, discard: { events.append("discard") }, reload: { events.append("reload") })
        let model = AppGroupsSectionModel(store: store, editor: bridge, didChange: { changes += 1 })
        model.requestRename("New"); #expect(model.pendingRename == "New"); #expect(events.isEmpty)
        model.pendingRename = nil; #expect(store.document.groups[0].name == "Old")
        model.requestRename("New"); fail = true; model.resolvePendingRename(saveChanges: true)
        #expect(events == ["save"]); #expect(store.document.groups[0].name == "Old")
        events = []; fail = false; model.requestRename("New"); model.resolvePendingRename(saveChanges: true)
        #expect(events == ["save", "reload"]); #expect(store.document.groups[0].name == "New"); #expect(changes == 1)
        events = []; model.requestRename("Other"); model.resolvePendingRename(saveChanges: false)
        #expect(events == ["discard", "reload"]); #expect(store.document.groups[0].name == "Other"); #expect(changes == 2)
    }
    @Test func invalidAndExternalEditsRefuseWrites() async throws {
        let (root, store, _) = await setup([]); defer { try? FileManager.default.removeItem(at: root) }
        try store.save(.init(groups: [.init(name: "Valid", apps: [])]))
        let invalid = Data("{\"version\":1,\"groups\": [null]}".utf8); try invalid.write(to: store.fileURL)
        let model = AppGroupsSectionModel(store: store, didChange: {})
        model.save(.init())
        #expect(model.message?.contains("changed outside") == true)
        for _ in 0..<100 where store.canSave { await Task.yield() }
        #expect(!store.canSave); #expect(store.error?.localizedDescription.contains("$.groups[0]") == true)
        #expect(store.document.groups.first?.name == "Valid")
        #expect(throws: (any Error).self) { try store.save(.init()) }; #expect(try Data(contentsOf: store.fileURL) == invalid)
        try Data([0]).write(to: store.fileURL); await store.reload()
        #expect(store.error?.localizedDescription.contains("App Groups file") == true)
        #expect(store.error?.localizedDescription.contains("layout JSON") == false)
    }
    @Test func partialRenameFailureUsesLayoutName() async throws {
        let (root, store, _) = await setup([]); defer { try? FileManager.default.removeItem(at: root) }
        try store.save(.init(groups: [.init(name: "Browser", apps: [])]))
        let layout = SavedLayoutDocument(name: "Homework", mode: .manual, slots: [.init(id: "a", prefer: [.group("Browser")])], windows: [.init(slot: "a", rect: .init(x: 0, y: 0, width: 1, height: 1))])
        let url = try store.layouts.create(SavedLayoutValidator.encode(layout))
        store.beforeLayoutWrite = { url in try? Data("external".utf8).write(to: url) }
        var events: [String] = []
        let model = AppGroupsSectionModel(store: store, editor: .init(reload: { events.append("reload") }), didChange: { events.append("revision") })
        model.requestRename("Web")
        #expect(model.renameFailures.count == 1)
        #expect(model.renameFailures.first?.layoutName == "Homework")
        #expect(model.renameFailures.first?.url == url)
        #expect(events == ["reload", "revision"])
    }
    @Test func fileActionsAndReferencedRemoval() async throws {
        let (root, store, _) = await setup([]); defer { try? FileManager.default.removeItem(at: root) }
        var edited: [URL] = []; var revealed: [URL] = []
        let actions = AppGroupsFileActions(edit: { edited.append($0) }, reveal: { revealed.append($0) })
        let model = AppGroupsSectionModel(store: store, fileActions: actions, didChange: {})
        model.editFile(); model.revealFile(); #expect(edited.isEmpty && revealed.isEmpty)
        try store.save(.init(groups: [.init(name: "Browser", apps: [])]))
        model.editFile(); model.revealFile(); #expect(edited == [store.fileURL]); #expect(revealed == [store.fileURL])
        let layout = SavedLayoutDocument(name: "Homework", mode: .manual, slots: [.init(id: "a", prefer: [.group("Browser")])], windows: [.init(slot: "a", rect: .init(x: 0, y: 0, width: 1, height: 1))])
        _ = try store.layouts.create(SavedLayoutValidator.encode(layout))
        await model.reload()
        #expect(model.layoutCount(for: "Browser") == 1)
        model.requestRemoval("Browser"); #expect(model.pendingRemoval == "Browser")
        #expect(store.document.groups.count == 1)
        model.pendingRemoval = nil; #expect(store.document.groups.count == 1)
        model.remove("Browser"); #expect(store.document.groups.isEmpty)
    }
}
