import BetterTileCore
import Foundation
import Testing
@testable import BetterTileApp

@MainActor @Suite(.appTestApplication) struct DisplayTriggerStoreTests {
    private let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DisplayTriggerStore-" + UUID().uuidString)
    private var url: URL { directory.appendingPathComponent("Display Triggers.json") }

    private func trigger(_ file: String = "one.json") -> DisplayTrigger {
        .init(layoutFile: file, displays: [.init(uuid: "A", vendor: 1, model: 2, serial: 3, builtIn: false, name: "Studio",
                                                  frame: BTRect(x: 0, y: 0, width: 100, height: 60))], target: 0)
    }

    @Test func aMissingFileIsEmptyAndWritesNothingUntilBound() throws {
        let store = DisplayTriggerStore(url: url)
        #expect(store.loadError == nil && store.document.triggers.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(store.bind(trigger()))
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test func aBindingRoundTripsAndSwitchesStartOff() throws {
        let store = DisplayTriggerStore(url: url)
        #expect(store.bind(trigger()))
        let reopened = DisplayTriggerStore(url: url)
        let loaded = try #require(reopened.trigger(for: "one.json"))
        #expect(!loaded.enabled && !loaded.alsoAfterWake)
        #expect(reopened.update("one.json") { $0.enabled = true })
        #expect(DisplayTriggerStore(url: url).trigger(for: "one.json")?.enabled == true)
        #expect(reopened.remove("one.json"))
        #expect(DisplayTriggerStore(url: url).document.triggers.isEmpty)
    }

    @Test func replacingAnotherLayoutsBindingRemovesIt() {
        let store = DisplayTriggerStore(url: url)
        #expect(store.bind(trigger("old.json")))
        #expect(store.bind(trigger("new.json"), replacing: "old.json"))
        #expect(store.document.triggers.map(\.layoutFile) == ["new.json"])
    }

    @Test func unknownKeysSurviveASaveFromTheStore() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let json = """
        {"version":1,"future":7,"triggers":[{"layoutFile":"one.json","target":0,"openIfNotRunning":["x"],
        "displays":[{"uuid":"A","vendor":1,"model":2,"serial":0,"builtIn":false,"name":"X","frame":{"x":0,"y":0,"width":1,"height":1}}]}]}
        """
        try Data(json.utf8).write(to: url)
        let store = DisplayTriggerStore(url: url)
        #expect(store.update("one.json") { $0.alsoAfterWake = true })
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("\"future\""))
        #expect(text.contains("\"openIfNotRunning\""))
        #expect(text.contains("\"alsoAfterWake\" : true"))
    }

    @Test func aCorruptFileIsReportedKeptAndNeverOverwritten() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let corrupt = Data("{ not json".utf8)
        try corrupt.write(to: url)
        let store = DisplayTriggerStore(url: url)
        #expect(store.loadError?.contains("kept") == true)
        #expect(!store.bind(trigger()))
        #expect(store.message != nil)
        #expect(try Data(contentsOf: url) == corrupt)
        // Fixing the file outside BetterTile lets Reload work again.
        try Data(#"{"version":1,"triggers":[]}"#.utf8).write(to: url)
        store.load()
        #expect(store.loadError == nil)
        #expect(store.bind(trigger()))
    }

    @Test func aFileFromANewerVersionIsKept() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let newer = Data(#"{"version":2,"triggers":[]}"#.utf8)
        try newer.write(to: url)
        let store = DisplayTriggerStore(url: url)
        #expect(store.loadError != nil)
        #expect(!store.remove("one.json"))
        #expect(try Data(contentsOf: url) == newer)
    }

    @Test func aChangeMadeOutsideBetterTileIsNotOverwritten() throws {
        let store = DisplayTriggerStore(url: url)
        #expect(store.bind(trigger("one.json")))
        let outside = Data(#"{"version":1,"triggers":[]}"#.utf8)
        try outside.write(to: url)
        #expect(!store.bind(trigger("two.json")))
        #expect(store.message?.contains("changed outside") == true)
        #expect(try Data(contentsOf: url) == outside)
        #expect(store.document.triggers.map(\.layoutFile) == ["one.json"])
    }

    @Test func aWriteLeavesNoStagingFileAndReplacesAtomically() throws {
        let store = DisplayTriggerStore(url: url)
        for index in 0..<5 { #expect(store.bind(trigger("file\(index).json"))) }
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(names == ["Display Triggers.json"])
        #expect(DisplayTriggerStore(url: url).document.triggers.count == 5)
    }

    @Test func anOversizedFileIsReportedKeptAndNeverOverwritten() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let padding = String(repeating: " ", count: DisplayTriggerDocument.maximumBytes)
        let oversized = Data((#"{"version":1,"triggers":[]}"# + padding).utf8)
        try oversized.write(to: url)
        let store = DisplayTriggerStore(url: url)
        #expect(store.loadError?.contains("256 KiB") == true)
        #expect(!store.bind(trigger()))
        #expect(try Data(contentsOf: url) == oversized)
        // A file at exactly the limit still reads.
        let atLimit = Data((#"{"version":1,"triggers":[]}"#
            + String(repeating: " ", count: DisplayTriggerDocument.maximumBytes - #"{"version":1,"triggers":[]}"#.utf8.count)).utf8)
        try atLimit.write(to: url)
        store.load()
        #expect(store.loadError == nil, "\(store.loadError ?? "")")
    }

    @Test func aSymbolicLinkIsRefused() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appendingPathComponent("real.json")
        try Data(#"{"version":1,"triggers":[]}"#.utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
        #expect(DisplayTriggerStore(url: url).loadError != nil)
    }

    @Test func theStandardLocationIsNextToTheLayoutFolder() {
        let files = SavedLayoutFiles(directory: directory.appendingPathComponent("Saved Layouts"))
        #expect(DisplayTriggerStore.standard(files: files).url.lastPathComponent == "Display Triggers.json")
        #expect(DisplayTriggerStore.standard(files: files).url.deletingLastPathComponent().resolvingSymlinksInPath()
                == directory.resolvingSymlinksInPath())
    }
}
