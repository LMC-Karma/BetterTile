import BetterTileCore
import Foundation
import Testing
@testable import BetterTileApp

@Suite(.appTestApplication) @MainActor struct SavedLayoutEditorTests {
    private func temporaryFiles() -> SavedLayoutFiles {
        SavedLayoutFiles(directory: FileManager.default.temporaryDirectory.appending(path: "SavedLayoutTests-" + UUID().uuidString))
    }
    private func writing() -> SavedLayoutDocument {
        .init(name: "Writing", mode: .bento,
              layout: .split(axis: .vertical, ratios: [0.63, 0.37], children: [.slot("editor"), .empty]),
              slots: [.init(id: "editor", bundleID: "com.apple.dt.Xcode")], paneGap: 6)
    }
    private func seed(_ editor: SavedLayoutEditor, _ document: SavedLayoutDocument) {
        editor.newLayout()
        #expect(editor.edit { $0 = document })
    }

    @Test(arguments: [1, 0, 3])
    func unsupportedLayoutIsListedAndKeptWithoutImportOrSave(version: Int) throws {
        let files = temporaryFiles(); defer { try? FileManager.default.removeItem(at: files.directory) }
        try FileManager.default.createDirectory(at: files.directory, withIntermediateDirectories: true)
        let url = files.directory.appendingPathComponent("unsupported.json")
        let bytes = Data("{\"version\":\(version),\"name\":\"Unsupported\",\"mode\":\"manual\",\"slots\":[]}".utf8)
        try bytes.write(to: url)
        let editor = SavedLayoutEditor(files: files)
        editor.refreshLibrary()
        #expect(editor.entries == [url] && editor.entryDocuments[url] == nil)
        #expect(editor.entryNames[url] == "unsupported.json · unreadable")
        if version == 1 {
            #expect(editor.entryProblems[url] == "Made by a development build. Save the layout again.")
        } else { #expect(editor.entryProblems[url]?.contains("Only version 2 is supported") == true) }
        #expect(!editor.load(url) && editor.document == nil)
        #expect(!editor.load(url, importing: true) && editor.document == nil)
        #expect(!editor.beginImport(url, groups: nil) && editor.document == nil)
        #expect(!editor.save() && !editor.save(as: "Copy") && !editor.delete())
        #expect(!editor.edit { $0.name = "Renamed" })
        #expect(!editor.updateFromCurrentDesktop(writing(), libraryURL: url))
        #expect(try files.read(url) == bytes)
        #expect(try files.entries() == [url])
    }

    @Test(arguments: [LayoutMode.manual, .tabbed])
    func switchingFromAdaptiveClearsExtraPanes(mode: LayoutMode) throws {
        let files = temporaryFiles(); defer { try? FileManager.default.removeItem(at: files.directory) }
        let editor = SavedLayoutEditor(files: files)
        var value = writing(); value.extraWindows = .addAsPanes
        seed(editor, value)
        editor.setMode(mode)
        #expect(editor.document?.mode == mode)
        #expect(editor.document?.extraWindows == .float)
        #expect(editor.draft.issues.isEmpty)
    }

    @Test func newSaveAsRenameAndDeletePreserveIndependentFiles() throws {
        let files = temporaryFiles(); defer { try? FileManager.default.removeItem(at: files.directory) }
        let editor = SavedLayoutEditor(files: files)
        seed(editor, writing())
        #expect(editor.save(as: "Original"))
        let original = try #require(editor.url)
        let originalBytes = try files.read(original)
        #expect(!editor.isDirty)
        #expect(editor.save(as: "Copy"))
        let copy = try #require(editor.url)
        #expect(copy != original)
        #expect(try files.read(original) == originalBytes)
        #expect(editor.edit { $0.name = "Renamed" })
        #expect(editor.isDirty)
        #expect(editor.save())
        #expect(try SavedLayoutValidator.decode(files.read(copy)).name == "Renamed")
        #expect(editor.delete())
        #expect(!FileManager.default.fileExists(atPath: copy.path))
        #expect(try files.read(original) == originalBytes)
        #expect(editor.document?.name == "Original")
        #expect(!editor.isDirty)
        #expect(editor.url == original)
        #expect(editor.entries == [original])
    }

    @Test func invalidImportRetainsExactBytesLastValidAndBothFiles() throws {
        let files = temporaryFiles(); defer { try? FileManager.default.removeItem(at: files.directory) }
        let editor = SavedLayoutEditor(files: files)
        seed(editor, writing()); #expect(editor.save(as: "Good"))
        let original = try #require(editor.url), originalBytes = try files.read(original)
        let invalid = files.directory.appendingPathComponent("invalid.json")
        let bytes = Data("{ \n \"version\": 99, \"unknown\": true }\n".utf8)
        try bytes.write(to: invalid)
        let good = editor.document
        #expect(!editor.load(invalid, importing: true))
        #expect(editor.draft.source == bytes)
        #expect(editor.rejectedSource == bytes)
        #expect(editor.document == good)
        #expect(!editor.save())
        #expect(!editor.edit { $0.name = "Overwrite" })
        editor.export(to: invalid)
        #expect(try files.read(invalid) == bytes)
        #expect(try files.read(original) == originalBytes)
        editor.returnToLastValid()
        #expect(!editor.hasInvalidSource)
        #expect(editor.rejectedSource == bytes)
        editor.export(to: invalid)
        #expect(try files.read(invalid) == bytes)
    }

    @Test func externalEditsBlockSaveAndDeleteAndExplicitReloadRecovers() throws {
        let files = temporaryFiles(); defer { try? FileManager.default.removeItem(at: files.directory) }
        let editor = SavedLayoutEditor(files: files)
        seed(editor, writing()); #expect(editor.save(as: "Initial"))
        let url = try #require(editor.url)
        #expect(editor.edit { $0.name = "My draft" })
        var external = writing(); external.name = "Outside"
        let bytes = try SavedLayoutValidator.encode(external)
        try bytes.write(to: url)
        let draftBytes = editor.draft.source
        #expect(!editor.save())
        #expect(!editor.delete())
        #expect(editor.draft.source == draftBytes)
        #expect(editor.document?.name == "My draft")
        #expect(try files.read(url) == bytes)
        #expect(editor.message?.contains("changed outside") == true)
        #expect(editor.reload(url))
        #expect(editor.document == external)
        #expect(editor.url == url)
        #expect(!editor.isDirty)
    }

    @Test(arguments: ["valid", "invalid", "unreadable"], [false, true])
    func importedLibraryOriginalStaysUnownedAcrossReload(input: String, previousOwned: Bool) throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "SavedLayoutImportReload-" + UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let files = SavedLayoutFiles(directory: root.appending(path: "library", directoryHint: .isDirectory))
        try FileManager.default.createDirectory(at: files.directory, withIntermediateDirectories: true)
        let editor = SavedLayoutEditor(files: files)
        editor.newLayout()
        if previousOwned { #expect(editor.save(as: "Prior library file")) }
        let lastValid = editor.document
        let prior = editor.url
        let priorBytes = try prior.map(files.read)
        let original = files.directory.appendingPathComponent("imported.json")
        let document = SavedLayoutDocument(name: "Imported", mode: .bento, layout: .empty)
        let valid = try SavedLayoutValidator.encode(document)
        let invalid = Data(" { \n \"version\": 99, \"extra\": true } \n".utf8)
        if input != "unreadable" { try (input == "valid" ? valid : invalid).write(to: original) }
        #expect(editor.load(original, importing: true) == (input == "valid"))
        if input != "valid" {
            #expect(editor.url == prior)
            #expect(editor.document == lastValid)
            #expect(editor.rejectedURL == original)
            if input == "invalid" { #expect(editor.rejectedSource == invalid) }
            try valid.write(to: original)
        }
        #expect(editor.reload(original))
        #expect(editor.url == nil)
        #expect(editor.sourceURL == original)
        #expect(editor.rejectedURL == nil)
        #expect(editor.baseline == nil)
        #expect(!editor.delete())
        #expect(editor.edit { $0.name = "Edited imported draft" })
        editor.export(to: original)
        #expect(try files.read(original) == valid)
        #expect(editor.save())
        #expect(editor.url != original)
        #expect(editor.delete())
        #expect(try files.read(original) == valid)
        if let prior, let priorBytes { #expect(try files.read(prior) == priorBytes) }
    }

    @Test func librarySymlinkEntriesKeepTheirNamesAndRefreshSafely() throws {
        let files = temporaryFiles(); defer { try? FileManager.default.removeItem(at: files.directory) }
        try FileManager.default.createDirectory(at: files.directory, withIntermediateDirectories: true)
        let original = files.directory.appendingPathComponent("original.json")
        let alias = files.directory.appendingPathComponent("alias.json")
        try SavedLayoutValidator.encode(writing()).write(to: original)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: original)

        let editor = SavedLayoutEditor(files: files)
        editor.refreshLibrary()

        #expect(editor.libraryError == nil)
        #expect(editor.entries.count == 2)
        #expect(Set(editor.entries).count == 2)
        #expect(editor.entries.contains(original))
        #expect(editor.entries.contains(alias))
        #expect(editor.entryNames[original] == "Writing")
        #expect(editor.entryNames[alias] == "alias.json · unreadable")
    }

    @Test func invalidReloadAndReadFailurePreserveSourceAndRecover() throws {
        let files = temporaryFiles(); defer { try? FileManager.default.removeItem(at: files.directory) }
        let editor = SavedLayoutEditor(files: files)
        seed(editor, writing()); #expect(editor.save(as: "Initial"))
        let url = try #require(editor.url), valid = editor.document
        let invalid = Data("{\"version\":2, broken".utf8)
        try invalid.write(to: url)
        #expect(!editor.load(url))
        #expect(editor.document == valid)
        #expect(editor.draft.source == invalid)
        #expect(!editor.save())
        #expect(try files.read(url) == invalid)
        try FileManager.default.removeItem(at: url)
        #expect(!editor.load(url))
        #expect(editor.document == valid)
        #expect(editor.draft.source == invalid)
        let corrected = try SavedLayoutValidator.encode(writing())
        try corrected.write(to: url)
        #expect(editor.load(url))
        #expect(!editor.hasInvalidSource)
    }

    @Test func saveFailureRetainsDraftNameBytesAndLastValid() throws {
        let files = temporaryFiles()
        defer { try? FileManager.default.removeItem(at: files.directory) }
        // A regular file at the directory path deterministically rejects creation.
        try Data("keep".utf8).write(to: files.directory)
        let editor = SavedLayoutEditor(files: files)
        seed(editor, writing())
        let draft = editor.draft.source, valid = editor.document
        #expect(!editor.save(as: "Failed copy"))
        #expect(editor.draft.source == draft)
        #expect(editor.document == valid)
        #expect(editor.url == nil)
        #expect(try Data(contentsOf: files.directory) == Data("keep".utf8))
        editor.refreshLibrary()
        #expect(editor.libraryError != nil)
    }

    @Test func importedOriginalIsNeverOwnedAndExportDoesNotMarkSaved() throws {
        let files = temporaryFiles(); defer { try? FileManager.default.removeItem(at: files.directory) }
        let external = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: external) }
        let bytes = try SavedLayoutValidator.encode(writing()); try bytes.write(to: external)
        let editor = SavedLayoutEditor(files: files)
        #expect(editor.load(external, importing: true))
        #expect(editor.url == nil)
        #expect(editor.sourceURL == external)
        #expect(editor.edit { $0.name = "Draft" })
        #expect(try Data(contentsOf: external) == bytes)
        #expect(throws: (any Error).self) { try files.delete(external, expected: bytes) }
        #expect(editor.save(as: "Library copy"))
        let library = try #require(editor.url), baseline = try files.read(library)
        #expect(editor.edit { $0.name = "Exported draft" })
        let export = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: export) }
        editor.export(to: export)
        #expect(try SavedLayoutValidator.decode(Data(contentsOf: export)).name == "Exported draft")
        #expect(editor.isDirty)
        #expect(try files.read(library) == baseline)
        #expect(try Data(contentsOf: external) == bytes)
    }

    @Test func oversizedAndSymlinkInputsAreRejectedWithoutReplacement() throws {
        let files = temporaryFiles(); defer { try? FileManager.default.removeItem(at: files.directory) }
        try FileManager.default.createDirectory(at: files.directory, withIntermediateDirectories: true)
        let oversized = files.directory.appendingPathComponent("large.json")
        try Data(repeating: 32, count: SavedLayoutValidator.maximumBytes + 1).write(to: oversized)
        let editor = SavedLayoutEditor(files: files); seed(editor, writing())
        let bytes = editor.draft.source
        #expect(!editor.load(oversized))
        #expect(editor.draft.source == bytes)
        #expect(try Data(contentsOf: oversized).count == SavedLayoutValidator.maximumBytes + 1)
        let link = files.directory.appendingPathComponent("link.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: oversized)
        #expect(throws: (any Error).self) { try files.read(link) }
        #expect(throws: (any Error).self) { try files.save(bytes, to: link, expected: bytes) }
    }

    @Test func splitRatioAndRemovalKeepIDsAndProduceValidF1() throws {
        let editor = SavedLayoutEditor(files: temporaryFiles()); seed(editor, writing())
        let initialDocument = try #require(editor.document)
        let first = try #require(SavedLayoutCanvasGeometry.panes(initialDocument).first)
        editor.split(first, axis: .vertical)
        let value = try #require(editor.document)
        #expect(SavedLayoutValidator.validate(value).isEmpty)
        #expect(Array(value.slots.prefix(writing().slots.count)) == writing().slots)
        #expect(value.slots.last?.prefer == [])
        guard case let .split(axis, ratios, children) = value.layout else { Issue.record("Expected split"); return }
        #expect(axis == .vertical)
        #expect(children.count == 3) // Same-axis nesting is flattened in the layout file.
        #expect(abs(ratios[0] - 0.315) < 0.000001)
        editor.setRatio(path: [], child: 0, ratio: 0.7)
        let panes = SavedLayoutCanvasGeometry.panes(try #require(editor.document))
        #expect(panes.count == 3)
        #expect(abs(panes[0].rect.width - (1 - 12 / 1200.0) * 0.7) < 0.000001)
        let before = editor.document
        editor.removePane(panes[0]) // removes the pane and its app; Undo brings both back
        #expect(editor.document?.slots.count == 1)
        #expect(editor.document?.slots.first?.prefer == [])
        #expect(SavedLayoutCanvasGeometry.panes(try #require(editor.document)).count == 2)
        #expect(SavedLayoutValidator.validate(try #require(editor.document)).isEmpty)
        editor.undo()
        #expect(editor.document == before)
        editor.removePane(panes[1])
        #expect(SavedLayoutCanvasGeometry.panes(try #require(editor.document)).count == 2)
        #expect(editor.document?.slots.first?.id == "editor")
    }

    @Test func assignmentTabOrderSelectionAndDeliberateFloatsRoundTrip() throws {
        let editor = SavedLayoutEditor(files: temporaryFiles()); editor.newLayout(mode: .tabbed)
        let initialDocument = try #require(editor.document)
        var pane = try #require(SavedLayoutCanvasGeometry.panes(initialDocument).first)
        editor.assign(bundleID: "com.apple.Safari", pane: pane)
        let assignedDocument = try #require(editor.document)
        pane = try #require(SavedLayoutCanvasGeometry.panes(assignedDocument).first)
        editor.assign(bundleID: "com.apple.Safari", pane: pane)
        let group = try #require(editor.document?.groups.first)
        #expect(group.slots.count == 2)
        #expect(Set(group.slots).count == 2)
        editor.moveTab(group.slots[1], group: group.id, offset: -1)
        editor.selectTab(group.slots[0], group: group.id)
        editor.assign(bundleID: "com.apple.Notes", pane: nil, floating: true)
        let value = try #require(editor.document)
        #expect(value.groups[0].slots == group.slots.reversed())
        #expect(value.groups[0].selected == group.slots[0])
        #expect(value.floats.count == 1)
        #expect(try SavedLayoutValidator.decode(SavedLayoutValidator.encode(value)) == value)
        editor.removeSlot(group.slots[0])
        #expect(editor.document?.groups[0].selected == group.slots[1])
        #expect(editor.document?.groups[0].id == group.id)
        #expect(editor.document?.floats == value.floats)
    }

    @Test func invalidGeometryAndModeLimitsKeepLastValidDraft() throws {
        let editor = SavedLayoutEditor(files: temporaryFiles()); editor.newLayout(mode: .manual)
        editor.assign(bundleID: "com.apple.Notes", pane: nil)
        let rectangle = try #require(editor.document?.windows.first), before = editor.document, bytes = editor.draft.source
        editor.setRectangle(rectangle.slot, rect: .init(x: 0.9, y: 0.1, width: 0.5, height: 0.5))
        #expect(editor.document == before)
        #expect(editor.draft.source == bytes)
        editor.setRectangle(rectangle.slot, rect: .init(x: 0, y: 0, width: 0.5, height: 1))
        #expect(editor.document?.windows[0].rect.width == 0.5)
        editor.setMode(.tabbed)
        let slots = editor.document?.slots
        editor.setMode(.bento)
        #expect(editor.document?.slots == slots)
        #expect(SavedLayoutValidator.validate(try #require(editor.document)).isEmpty)
        editor.setMode(.manual)
        for _ in 0..<6 { editor.assign(bundleID: "com.apple.Notes", pane: nil) }
        let seven = editor.document
        editor.setMode(.bento)
        #expect(editor.document == seven)
    }

    @Test func presetsRetainAssignmentsAndRejectTooFewPanes() throws {
        let editor = SavedLayoutEditor(files: temporaryFiles()); seed(editor, writing())
        editor.setPreset(.focus)
        #expect(SavedLayoutCanvasGeometry.panes(try #require(editor.document)).count == 3)
        #expect(editor.document?.slots.first == writing().slots.first)
        #expect(editor.document?.slots.count == 3)
        let panes = SavedLayoutCanvasGeometry.panes(try #require(editor.document))
        editor.assign(bundleID: "com.apple.Safari", pane: panes[1])
        let before = editor.document
        editor.setPreset(.single)
        #expect(editor.document == before)
        #expect(editor.message?.contains("fewer panes") == true)
        // Empty panes do not count against a preset: one app fits One Pane.
        editor.removeSlot(try #require(editor.document?.slots.first { $0.prefer == [.app("com.apple.Safari")] }?.id))
        editor.setPreset(.single)
        #expect(SavedLayoutCanvasGeometry.panes(try #require(editor.document)).count == 1)
        #expect(editor.document?.layout == .slot("editor"))
        #expect(SettingsDestination.savedLayouts.matchesSearch("import"))
        #expect(SettingsDestination.savedLayouts.matchesSearch("JSON"))
    }
}

extension SavedLayoutEditorTests {
    @Test func movingSlotsBetweenGroupsAndFloatsPreservesIDsAndSelection() throws {
        let editor = SavedLayoutEditor(files: temporaryFiles())
        editor.newLayout(mode: .tabbed); editor.setPreset(.columns)
        var document = try #require(editor.document)
        var panes = SavedLayoutCanvasGeometry.panes(document)
        editor.assign(bundleID: "com.apple.Safari", pane: panes[0])
        document = try #require(editor.document); panes = SavedLayoutCanvasGeometry.panes(document)
        editor.assign(bundleID: "com.apple.Notes", pane: panes[1])
        document = try #require(editor.document); panes = SavedLayoutCanvasGeometry.panes(document)
        let slot = try #require(document.slots.first?.id), groupIDs = document.groups.map(\.id)
        editor.moveSlot(slot, to: panes[1])
        let placeholder = try #require(editor.document?.groups[0].slots.first)
        #expect(placeholder != slot)
        #expect(editor.document?.groups[0].slots == [placeholder])
        #expect(editor.document?.groups[0].selected == placeholder)
        #expect(editor.document?.slots.first { $0.id == placeholder }?.prefer == [])
        #expect(editor.document?.groups[1].selected == slot)
        #expect(editor.document?.groups.map(\.id) == groupIDs)
        editor.moveSlot(slot, to: nil)
        #expect(editor.document?.floats.first?.slot == slot)
        #expect(editor.document?.groups[1].slots.count == 1)
        document = try #require(editor.document); panes = SavedLayoutCanvasGeometry.panes(document)
        editor.moveSlot(slot, to: panes[0])
        #expect(editor.document?.floats.isEmpty == true)
        #expect(editor.document?.groups[0].selected == slot)
        #expect(SavedLayoutValidator.validate(try #require(editor.document)).isEmpty)
    }

    @Test func failedAtomicReplacementKeepsDiskAndUnsavedDraft() throws {
        let files = temporaryFiles(); defer { try? FileManager.default.removeItem(at: files.directory) }
        let editor = SavedLayoutEditor(files: files); seed(editor, writing())
        #expect(editor.save(as: "Disk"))
        let url = try #require(editor.url), baseline = try files.read(url)
        #expect(editor.edit { $0.name = "Unsaved" })
        let source = editor.draft.source, document = editor.document
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: files.directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: files.directory.path) }
        #expect(!editor.save())
        #expect(try files.read(url) == baseline)
        #expect(editor.draft.source == source)
        #expect(editor.document == document)
        #expect(editor.isDirty)
    }

    @Test func assignmentPayloadContainsBundleIDWithoutApplicationMetadata() throws {
        let files = temporaryFiles(); let editor = SavedLayoutEditor(files: files)
        editor.newLayout(mode: .manual)
        let application = ApplicationChoice(bundleIdentifier: "org.example.Editor", name: "Private app display name",
                                            url: URL(fileURLWithPath: "/private/app-install/Editor.app"))
        editor.assign(bundleID: application.bundleIdentifier, pane: nil)
        let payload = try #require(String(data: editor.draft.source, encoding: .utf8))
        #expect(payload.contains("org.example.Editor"))
        #expect(!payload.contains(application.name))
        #expect(!payload.contains(application.url.path))
        for forbidden in ["nativeID", "displayID", "spaceID", "windowID", "pid", "title", "url", "path", "command"] {
            #expect(!payload.contains("\"\(forbidden)\""))
        }
    }
}

extension SavedLayoutEditorTests {
    @Test func exportFailureKeepsExistingDestinationAndDraft() throws {
        let files = temporaryFiles(); defer { try? FileManager.default.removeItem(at: files.directory) }
        try FileManager.default.createDirectory(at: files.directory, withIntermediateDirectories: true)
        let editor = SavedLayoutEditor(files: files); seed(editor, writing())
        let destination = files.directory.appendingPathComponent("export.json")
        let existing = Data("user-authored source bytes".utf8); try existing.write(to: destination)
        let source = editor.draft.source, document = editor.document
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: files.directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: files.directory.path) }
        editor.export(to: destination)
        #expect(try files.read(destination) == existing)
        #expect(editor.draft.source == source)
        #expect(editor.document == document)
        #expect(editor.message?.contains("Couldn’t export") == true)
    }

    @Test func manualWindowCanFloatAndReturnWithoutChangingSlotOrRectangle() throws {
        let editor = SavedLayoutEditor(files: temporaryFiles()); editor.newLayout(mode: .manual)
        editor.assign(bundleID: "com.apple.Notes", pane: nil)
        let rectangle = try #require(editor.document?.windows.first)
        editor.moveSlot(rectangle.slot, to: nil)
        #expect(editor.document?.windows.isEmpty == true)
        #expect(editor.document?.floats == [rectangle])
        editor.returnToManualWindow(rectangle.slot)
        #expect(editor.document?.floats.isEmpty == true)
        #expect(editor.document?.windows == [rectangle])
        #expect(editor.document?.slots.count == 1)
    }
}


extension SavedLayoutEditorTests {
    @Test func staleSplitCallbacksAndInvalidRatiosPreserveDraft() throws {
        let editor = SavedLayoutEditor(files: temporaryFiles()); seed(editor, writing())
        let document = editor.document, bytes = editor.draft.source
        editor.setRatio(path: [7], child: 0, ratio: 0.5)
        #expect(editor.document == document)
        editor.setRatio(path: [], child: 7, ratio: 0.5)
        #expect(editor.document == document)
        editor.setRatio(path: [], child: 0, ratio: .infinity)
        #expect(editor.document == document)
        #expect(editor.draft.source == bytes)
        // A full share is clamped so the other pane keeps the minimum size (SavedLayoutProportionTests).
        editor.setRatio(path: [], child: 0, ratio: 1)
        guard case let .split(_, ratios, _)? = editor.document?.layout else { Issue.record("No split"); return }
        #expect(abs(ratios[1] - SavedLayoutCanvas.minimumWidth) < 1e-9)
        let root = try #require(document?.layout)
        #expect(SavedLayoutCanvasGeometry.replacing(root, at: [7], with: .empty) == root)
    }
}
