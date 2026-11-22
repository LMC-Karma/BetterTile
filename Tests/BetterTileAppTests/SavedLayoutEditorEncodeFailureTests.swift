import BetterTileCore
import Foundation
import Testing
@testable import BetterTileApp

/// Editor-built and validated documents always encode, so these tests inject a
/// failing encoder to reach the refusal paths that replaced `try!`.
@Suite(.appTestApplication) @MainActor struct SavedLayoutEditorEncodeFailureTests {
    private struct EncodeFailure: LocalizedError {
        var errorDescription: String? { "Test encoder refused." }
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "SavedLayoutEncodeFailure-" + UUID().uuidString)
    }

    private func failing(_ editor: SavedLayoutEditor) {
        editor.encodeLayout = { _ in throw EncodeFailure() }
    }

    private func expectRefusal(_ editor: SavedLayoutEditor, mentioning text: String) {
        #expect(editor.messageStatus?.kind == .bad)
        #expect(editor.message?.contains(text) == true)
        #expect(editor.message?.contains("Test encoder refused.") == true)
    }

    @Test func newLayoutRefusalKeepsTheSavedDraft() throws {
        let directory = temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let editor = SavedLayoutEditor(files: .init(directory: directory))
        #expect(editor.newLayout())
        #expect(editor.edit { $0.name = "Kept" })
        #expect(editor.save())
        let url = try #require(editor.url), source = editor.draft.source, document = editor.document

        failing(editor)
        #expect(!editor.newLayout(mode: .tabbed))
        expectRefusal(editor, mentioning: "Couldn’t start a new layout")
        #expect(editor.url == url)
        #expect(editor.draft.source == source)
        #expect(editor.document == document)
        #expect(!editor.isDirty)
    }

    @Test func creationRefusalDoesNotStartADraft() throws {
        let directory = temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let editor = SavedLayoutEditor(files: .init(directory: directory))
        #expect(editor.newLayout())
        #expect(editor.save(as: "Existing"))
        let url = try #require(editor.url)

        failing(editor)
        let flow = SavedLayoutCreation()
        #expect(!flow.begin(.init(name: "Writing", mode: .bento, preset: .columns), editor: editor))
        #expect(!flow.isDraft)
        #expect(editor.url == url)
        #expect(editor.document?.name == "Existing")
        expectRefusal(editor, mentioning: "Couldn’t start a new layout")
    }

    @Test func returnToLastValidRefusalKeepsTheRejectedSource() throws {
        let directory = temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let editor = SavedLayoutEditor(files: .init(directory: directory))
        #expect(editor.newLayout())
        let good = editor.document
        let invalid = directory.appendingPathComponent("invalid.json")
        let bytes = Data("{ \"version\": 99 }\n".utf8)
        try bytes.write(to: invalid)
        #expect(!editor.load(invalid, importing: true))
        #expect(editor.hasInvalidSource)

        failing(editor)
        #expect(!editor.returnToLastValid())
        expectRefusal(editor, mentioning: "Couldn’t show the last valid layout")
        #expect(editor.hasInvalidSource)
        #expect(editor.draft.source == bytes)
        #expect(editor.document == good)
        #expect(try Data(contentsOf: invalid) == bytes)
    }

    @Test func importRefusalKeepsTheDraftAndSource() throws {
        let library = temporaryDirectory(), outside = temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: library)
            try? FileManager.default.removeItem(at: outside)
        }
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let editor = SavedLayoutEditor(files: .init(directory: library))
        #expect(editor.newLayout())
        #expect(editor.save(as: "Current"))
        let url = try #require(editor.url), source = editor.draft.source

        let imported = SavedLayoutDocument(name: "Imported", mode: .bento, layout: .slot("main"), slots: [.init(id: "main")])
        let file = outside.appendingPathComponent("imported.json")
        let bytes = try SavedLayoutValidator.encode(imported)
        try bytes.write(to: file)

        failing(editor)
        #expect(!editor.beginImport(file, groups: nil))
        expectRefusal(editor, mentioning: "Couldn’t import")
        #expect(editor.url == url)
        #expect(editor.sourceURL == url)
        #expect(editor.draft.source == source)
        #expect(editor.document?.name == "Current")
        #expect(try Data(contentsOf: file) == bytes)

        // The same import succeeds once encoding works again.
        editor.encodeLayout = SavedLayoutValidator.encode
        #expect(editor.beginImport(file, groups: nil))
        #expect(editor.document?.name == "Imported")
        #expect(editor.url == nil && editor.sourceURL == file)
    }

    @Test func settingsNewLayoutRefusalFromALibraryLayoutStartsNoDraft() throws {
        let f = SavedLayoutDisplayPickerFixture(); defer { f.close() }
        #expect(f.editor.save(as: "Library"))
        let library = try #require(f.editor.url), source = f.editor.draft.source
        let creation = f.editor.creation
        #expect(!creation.isDraft)

        failing(f.editor)
        f.page.perform(.new(.init(name: "Writing", mode: .bento, preset: .columns)))
        expectRefusal(f.editor, mentioning: "Couldn’t start a new layout")
        #expect(!creation.isDraft)
        #expect(!f.page.isEditing)
        #expect(f.editor.url == library)
        #expect(f.editor.draft.source == source)

        // The refusal recorded no return URL: with none, cancel clears instead of reloading the library file.
        f.editor.encodeLayout = SavedLayoutValidator.encode
        #expect(creation.cancel(editor: f.editor))
        #expect(f.editor.document == nil && f.editor.url == nil)
    }

    @Test func settingsNewLayoutRefusalDuringADraftKeepsItsReturnURL() throws {
        let f = SavedLayoutDisplayPickerFixture(); defer { f.close() }
        #expect(f.editor.save(as: "Library"))
        let library = try #require(f.editor.url)
        let creation = f.editor.creation
        f.page.perform(.new(.init(name: "First draft", mode: .bento, preset: .columns)))
        #expect(creation.isDraft && f.page.isEditing)
        #expect(f.editor.url == nil && f.editor.document?.name == "First draft")
        let draft = f.editor.draft.source

        failing(f.editor)
        f.page.perform(.new(.init(name: "Second draft", mode: .tabbed, preset: .grid)))
        expectRefusal(f.editor, mentioning: "Couldn’t start a new layout")
        #expect(creation.isDraft)
        #expect(f.editor.draft.source == draft)
        #expect(f.editor.document?.name == "First draft")

        // Cancel still returns to the library layout that was open before the first draft.
        f.editor.encodeLayout = SavedLayoutValidator.encode
        #expect(creation.cancel(editor: f.editor))
        #expect(!creation.isDraft)
        #expect(f.editor.url == library && f.editor.document?.name == "Library")
    }

    @Test func completeImportRefusalKeepsTheDraftSourceLibraryAndGroups() async throws {
        let root = temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = AppGroupsStore(directory: root, catalog: { [] }, defaultBrowserURL: { nil })
        await store.load()
        let editor = SavedLayoutEditor(files: store.layouts)
        #expect(editor.newLayout())
        #expect(editor.save(as: "Current"))
        let url = try #require(editor.url), source = editor.draft.source
        let baseline = try editor.files.read(url), groups = store.document
        editor.refreshLibrary()
        let entries = editor.entries

        let imported = SavedLayoutDocument(name: "Homework", mode: .bento, layout: .slot("a"),
            slots: [.init(id: "a", prefer: [.group("Reading"), .app("com.apple.Safari")])])
        let group = AppGroup(name: "Reading", apps: [.init(name: "Preview", bundleID: "com.apple.Preview")])
        let file = root.appending(path: "export.json")
        let exported = try SavedLayoutTransfer.encode(imported, groups: .init(groups: [group]))
        try exported.write(to: file)
        #expect(!editor.beginImport(file, groups: store))
        #expect(editor.pendingImport?.choices == ["Reading": .add])

        failing(editor)
        #expect(!editor.completeImport(groups: store))
        expectRefusal(editor, mentioning: "Couldn’t import")
        #expect(editor.pendingImport != nil)
        #expect(editor.url == url && editor.sourceURL == url)
        #expect(editor.draft.source == source)
        #expect(editor.document?.name == "Current")
        #expect(editor.entries == entries)
        #expect(try editor.files.read(url) == baseline)
        #expect(store.document == groups)
        #expect(try Data(contentsOf: file) == exported)

        // The same pending import completes once encoding works again.
        editor.encodeLayout = SavedLayoutValidator.encode
        #expect(editor.completeImport(groups: store))
        #expect(editor.document?.name == "Homework")
        #expect(store.document.groups == [group])
    }
}
