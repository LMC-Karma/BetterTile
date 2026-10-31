import Foundation
import Testing
import BetterTileCore
@testable import BetterTileApp

@MainActor @Suite(.appTestApplication) struct AppGroupsStoreTests {
    private func app(_ name: String, _ id: String) -> ApplicationChoice {
        .init(bundleIdentifier: id, name: name, url: URL(filePath: "/fake/\(id).app"))
    }
    private func root() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }

    private func bundle(_ root: URL, _ name: String, _ id: String) throws -> URL {
        let url = root.appendingPathComponent("\(name).app")
        let contents = url.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": id], format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        return url
    }

    @Test func browserStartersUseCuratedOrderAndDefault() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let safari = app("Safari", "com.apple.Safari"), chrome = app("Chrome", "com.google.Chrome")
        let firefox = app("Firefox", "org.mozilla.firefox"), brave = app("Brave", "com.brave.Browser")
        let t3 = app("T3 Code", "com.t3tools.t3code")
        let firefoxURL = try bundle(root, "different-path", firefox.id)
        let choices = [brave, t3, firefox, chrome, safari]
        let store = AppGroupsStore(directory: root.appendingPathComponent("store"), catalog: { choices }, defaultBrowserURL: { nil })
        await store.load()
        #expect(store.document.groups.first?.apps.map(\.bundleID) == [safari.id, chrome.id, firefox.id, brave.id])
        let defaultStore = AppGroupsStore(directory: root.appendingPathComponent("other"), catalog: { choices }, defaultBrowserURL: { firefoxURL })
        await defaultStore.load()
        #expect(defaultStore.document.groups.first?.apps.map(\.bundleID) == [firefox.id, safari.id, chrome.id, brave.id])
    }

    @Test func unlistedDefaultIsNotAddedAndEmptyResultOmitsBrowser() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let t3 = app("T3 Code", "com.t3tools.t3code"), safari = app("Safari", "com.apple.Safari")
        let t3URL = try bundle(root, "t3", t3.id)
        let store = AppGroupsStore(directory: root.appendingPathComponent("store"), catalog: { [t3, safari] }, defaultBrowserURL: { t3URL })
        await store.load()
        #expect(store.document.groups.first?.apps.map(\.bundleID) == [safari.id])
        let empty = AppGroupsStore(directory: root.appendingPathComponent("empty"), catalog: { [t3] }, defaultBrowserURL: { t3URL })
        await empty.load()
        #expect(empty.document.groups.isEmpty)
    }

    @Test func lookupRules() {
        let safari = app("Safari", "com.apple.Safari"), brave = app("Brave Browser", "com.brave.Browser")
        let chrome = app("Google Chrome", "com.google.Chrome"), canary = app("Chrome Canary", "com.google.Canary")
        let cafe = app("Café", "com.example.Cafe")
        let resolver = AppGroupResolver(applications: [safari, brave, chrome, canary, cafe])
        #expect(resolver.resolve(.init(name: "sAfArI")) == .resolved(safari.id))
        #expect(resolver.resolve(.init(name: "Brave")) == .resolved(brave.id))
        #expect(resolver.resolve(.init(name: brave.id)) == .resolved(brave.id))
        #expect(resolver.resolve(.init(name: "Chrome")) == .ambiguous([chrome, canary]))
        #expect(resolver.resolve(.init(name: "Cafe")) == .resolved(cafe.id))
        #expect(resolver.resolve(.init(name: "Missing")) == .notInstalled)
        let sameName = app("SAFARI", "com.example.Other")
        #expect(AppGroupResolver(applications: [safari, sameName]).resolve(.init(name: "safari")) == .ambiguous([safari, sameName]))
        #expect(resolver.resolve(.init(name: brave.id.uppercased())) == .resolved(brave.id))
        #expect(resolver.resolve(.init(name: "Safari", bundleID: "com.missing.App")) == .notInstalled)
        let missing = AppGroupEntry(name: "Safari", bundleID: "com.missing.App")
        #expect(resolver.resolvedBundleIDs(in: .init(groups: [.init(name: "X", apps: [missing])]))[missing] == nil)
    }

    @Test func exactNameWinsOverLongerMatchesIgnoringCaseAndDiacritics() {
        let safari = app("Safari", "com.apple.Safari")
        let safariPreview = app("Safari Technology Preview", "com.apple.SafariTechnologyPreview")
        let cafe = app("Café", "com.example.Cafe")
        let cafePro = app("Café Pro", "com.example.CafePro")
        #expect(AppGroupResolver(applications: [safari, safariPreview]).resolve(.init(name: "safari")) == .resolved(safari.id))
        #expect(AppGroupResolver(applications: [cafe, cafePro]).resolve(.init(name: "cafe")) == .resolved(cafe.id))
    }

    @Test func startersAndWriteBack() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let safari = app("Safari", "com.apple.Safari"), brave = app("Brave Browser", "com.brave.Browser")
        let xcode = app("Xcode", "com.apple.dt.Xcode")
        let safariURL = try bundle(root, "safari", safari.id)
        let store = AppGroupsStore(directory: root.appendingPathComponent("store"), catalog: { [safari, brave, xcode] }, defaultBrowserURL: { safariURL })
        await store.load()
        #expect(store.error == nil)
        #expect(store.document.groups.map(\.name) == ["Browser", "Coding"])
        #expect(store.document.groups[0].apps.map(\.bundleID) == [safari.id, brave.id])
        #expect(!FileManager.default.fileExists(atPath: store.fileURL.path))
        #expect(!FileManager.default.fileExists(atPath: store.directory.path))
        let group = AppGroupsDocument(groups: [.init(name: "Web", apps: [.init(name: "Brave")])])
        try store.save(group)
        #expect(store.document.groups[0].apps[0] == .init(name: "Brave", bundleID: brave.id))
        #expect(String(decoding: try Data(contentsOf: store.fileURL), as: UTF8.self).hasPrefix(AppGroupsDocument.fileHeader))
    }

    @Test func invalidExternalEditAndReload() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = AppGroupsStore(directory: root, catalog: { [] }, defaultBrowserURL: { nil })
        await store.load()
        try store.save(.init(groups: [.init(name: "First", apps: [])]))
        let invalid = Data("{\"version\":1,\"groups\":[{\"name\":\"\",\"apps\":[]}]}".utf8)
        try invalid.write(to: store.fileURL)
        #expect(try store.hasExternalChange())
        #expect(throws: (any Error).self) { try store.save(store.document) }
        await store.reload()
        #expect(store.document.groups[0].name == "First")
        #expect(store.error?.localizedDescription.contains("$.groups[0].name") == true)
        #expect(throws: (any Error).self) { try store.saveResolvedApps() }
        #expect(throws: (any Error).self) { try store.renameGroup("First", to: "Other") }
        #expect(try Data(contentsOf: store.fileURL) == invalid)
        #expect(throws: (any Error).self) { try store.save(store.document) }
        let valid = Data("{\"version\":1,\"groups\":[{\"name\":\"Second\",\"apps\":[]}]}".utf8)
        try valid.write(to: store.fileURL)
        await store.reload()
        #expect(store.document.groups[0].name == "Second")
        try store.saveResolvedApps()
        #expect(String(decoding: try Data(contentsOf: store.fileURL), as: UTF8.self).hasPrefix(AppGroupsDocument.fileHeader))
    }

    @Test func renameReportsChangedFiles() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let files = SavedLayoutFiles(directory: root.appendingPathComponent("Saved Layouts"))
        let layout = SavedLayoutDocument(name: "Test", mode: .manual, slots: [.init(id: "a", prefer: [.group("Browser")])], windows: [.init(slot: "a", rect: .init(x: 0, y: 0, width: 1, height: 1))])
        let urls = try (0..<3).map { _ in try files.create(SavedLayoutValidator.encode(layout)) }
        let store = AppGroupsStore(directory: root, catalog: { [] }, defaultBrowserURL: { nil })
        await store.load()
        try store.save(.init(groups: [.init(name: "Browser", apps: [])]))
        let changed = try files.read(urls[1]) + Data("\n// external\n".utf8)
        store.beforeLayoutWrite = { url in if url == urls[1] { try? changed.write(to: url) } }
        #expect(try store.renameGroup("Browser", to: "Web").map(\.url) == [urls[1]])
        #expect(try files.read(urls[1]) == changed)
        for url in [urls[0], urls[2]] { #expect(try SavedLayoutValidator.decode(files.read(url)).slots[0].prefer == [.group("Web")]) }
    }

    @Test func refusesSymlinksAndOversizedFiles() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let target = root.appendingPathComponent("target")
        try Data("{}".utf8).write(to: target)
        let store = AppGroupsStore(directory: root, catalog: { [] }, defaultBrowserURL: { nil })
        try FileManager.default.createSymbolicLink(at: store.fileURL, withDestinationURL: target)
        await store.load()
        #expect(store.error != nil)
        #expect(throws: (any Error).self) { try store.save(.init()) }
        try FileManager.default.removeItem(at: store.fileURL)
        try Data(repeating: 32, count: 1_048_577).write(to: store.fileURL)
        await store.reload()
        #expect(store.error != nil)
        #expect(throws: (any Error).self) { try store.save(.init()) }
    }

    @Test func layoutWritesRestoreHeader() throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let files = SavedLayoutFiles(directory: root)
        let current = SavedLayoutDocument(name: "Header", mode: .manual)
        let url = try files.create(SavedLayoutValidator.encode(current))
        let first = try files.read(url)
        #expect(String(decoding: first, as: UTF8.self).hasPrefix(SavedLayoutDocument.fileHeader))
        #expect(try SavedLayoutValidator.decode(first).version == 2)
        let withoutHeader = Data(first.dropFirst(SavedLayoutDocument.fileHeader.utf8.count))
        try withoutHeader.write(to: url)
        try files.save(SavedLayoutValidator.encode(SavedLayoutValidator.decode(withoutHeader)), to: url, expected: withoutHeader)
        #expect(String(decoding: try files.read(url), as: UTF8.self).hasPrefix(SavedLayoutDocument.fileHeader))
    }

    @Test func nameResolutionDoesNotWriteUntilRequested() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let app = app("Brave Browser", "com.brave.Browser")
        let chrome = self.app("Google Chrome", "com.google.Chrome"), canary = self.app("Chrome Canary", "com.google.Canary")
        let store = AppGroupsStore(directory: root, catalog: { [app, chrome, canary] }, defaultBrowserURL: { nil })
        let source = Data("{\"version\":1,\"groups\":[{\"name\":\"Web\",\"apps\":[{\"name\":\"brave\"},{\"name\":\"Missing\"},{\"name\":\"Chrome\"}]}]}".utf8)
        try source.write(to: store.fileURL)
        await store.load()
        let entry = AppGroupEntry(name: "brave")
        #expect(store.resolvedBundleIDs[entry] == app.id)
        let modified = try store.fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        await store.reload()
        #expect(try Data(contentsOf: store.fileURL) == source)
        #expect(try store.fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate == modified)
        try store.saveResolvedApps()
        let saved = try AppGroupsDocument.decode(Data(contentsOf: store.fileURL))
        #expect(saved.groups[0].apps[0] == .init(name: "brave", bundleID: app.id))
        #expect(saved.groups[0].apps[1] == .init(name: "Missing"))
        #expect(saved.groups[0].apps[2] == .init(name: "Chrome"))
    }

    @Test func renameReadsCurrentLayoutsAndReportsInvalidPossibleReferences() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let files = SavedLayoutFiles(directory: root.appendingPathComponent("Saved Layouts"))
        let store = AppGroupsStore(directory: root, catalog: { [] }, defaultBrowserURL: { nil })
        await store.load()
        try store.save(.init(groups: [.init(name: "Browser", apps: [])]))
        let layout = SavedLayoutDocument(name: "Test", mode: .manual, slots: [.init(id: "a", prefer: [.group("Browser")])], windows: [.init(slot: "a", rect: .init(x: 0, y: 0, width: 1, height: 1))])
        let createdAfterLoad = try files.create(SavedLayoutValidator.encode(layout))
        let invalid = files.directory.appendingPathComponent("invalid.json")
        let unrelated = files.directory.appendingPathComponent("other.json")
        try Data("invalid Browser".utf8).write(to: invalid)
        try Data("invalid unrelated".utf8).write(to: unrelated)
        let failures = try store.renameGroup("Browser", to: "Web")
        #expect(failures.map(\.url) == [invalid])
        #expect(try SavedLayoutValidator.decode(files.read(createdAfterLoad)).slots[0].prefer == [.group("Web")])
    }

    @Test func editorSavesTwice() throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let files = SavedLayoutFiles(directory: root)
        let url = root.appendingPathComponent("old.json")
        let bytes = Data(#"{"version":2,"name":"Original","mode":"manual","slots":[],"windows":[]}"#.utf8)
        try bytes.write(to: url)
        let editor = SavedLayoutEditor(files: files)
        #expect(editor.load(url))
        #expect(editor.edit { $0.name = "First" })
        #expect(editor.save())
        #expect(editor.edit { $0.name = "Second" })
        #expect(editor.save())
        #expect(String(decoding: try files.read(url), as: UTF8.self).hasPrefix(SavedLayoutDocument.fileHeader))
    }

    @Test func renameLeavesUnrelatedVersionsUntouchedAndLoadsBesideInvalidFile() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let files = SavedLayoutFiles(directory: root.appendingPathComponent("Saved Layouts"))
        try FileManager.default.createDirectory(at: files.directory, withIntermediateDirectories: true)
        let old = files.directory.appendingPathComponent("old.json")
        let unsupported = Data(#"{"version":1,"name":"Old","mode":"manual","slots":[],"windows":[]}"#.utf8)
        try unsupported.write(to: old)
        let new = try files.create(SavedLayoutValidator.encode(.init(name: "New", mode: .manual)))
        let supported = try files.read(new)
        try Data("broken".utf8).write(to: files.directory.appendingPathComponent("broken.json"))
        let store = AppGroupsStore(directory: root, catalog: { [] }, defaultBrowserURL: { nil })
        await store.load()
        #expect(store.error == nil)
        try store.save(.init(groups: [.init(name: "Browser", apps: [])]))
        #expect(try store.renameGroup("Browser", to: "Web").isEmpty)
        #expect(try files.read(old) == unsupported)
        #expect(try files.read(new) == supported)
    }

    @Test func refusesOversizedEncodedGroups() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = AppGroupsStore(directory: root, catalog: { [] }, defaultBrowserURL: { nil })
        await store.load()
        let document = AppGroupsDocument(groups: [.init(name: String(repeating: "a", count: 1_048_576), apps: [])])
        #expect(throws: (any Error).self) { try store.save(document) }
        #expect(!FileManager.default.fileExists(atPath: store.fileURL.path))
    }

    @Test func existingEmptyFileDoesNotSuggestStarters() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let safari = app("Safari", "com.apple.Safari"), xcode = app("Xcode", "com.apple.dt.Xcode")
        let safariURL = try bundle(root, "safari", safari.id)
        let store = AppGroupsStore(directory: root, catalog: { [safari, xcode] }, defaultBrowserURL: { safariURL })
        let bytes = Data(#"{"version":1,"groups":[]}"#.utf8)
        try bytes.write(to: store.fileURL)
        await store.load()
        #expect(store.error == nil)
        #expect(store.document.groups.isEmpty)
        #expect(try Data(contentsOf: store.fileURL) == bytes)
    }

    @Test func externalCreationAfterMissingLoadBlocksSave() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = AppGroupsStore(directory: root, catalog: { [] }, defaultBrowserURL: { nil })
        await store.load()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let external = Data(#"{"version":1,"groups":[]}"#.utf8)
        try external.write(to: store.fileURL)
        #expect(throws: (any Error).self) { try store.save(store.document) }
        #expect(try Data(contentsOf: store.fileURL) == external)
    }

}
