import AppKit
import BetterTileCore
import BetterTileMacOS
import Testing
@testable import BetterTileApp

@Suite(.appTestApplication) @MainActor struct SavedLayoutPageActionTests {
    typealias F = SavedLayoutDisplayPickerFixture

    private func addWindows(_ f: F) {
        f.system.windows = [F.a, F.b].enumerated().map { index, display in
            WindowSnapshot(id: .init(rawValue: "window-\(index)"), processIdentifier: Int32(41 + index),
                bundleIdentifier: index == 0 ? "org.example.Alpha" : "org.example.Beta",
                frame: .init(x: display.fingerprint.frame.minX + 100, y: 80, width: 500, height: 400), displayID: display.id)
        }
        f.system.desktopObservation?.windowMembership = Dictionary(uniqueKeysWithValues: f.system.windows.enumerated().map {
            ($0.element.id, Set([NativeSpaceID(rawValue: UInt64($0.offset + 1))]))
        })
    }
    private func save(_ f: F) throws -> URL {
        #expect(f.editor.save(as: "My layout"))
        return try #require(f.editor.url)
    }

    @Test func captureUsesPickedScreenInsteadOfFocusedScreen() throws {
        let f = F(); defer { f.close() }
        let a = WindowSnapshot(id: .init(rawValue: "a-window"), processIdentifier: 41,
            bundleIdentifier: "org.example.Alpha", frame: .init(x: 100, y: 80, width: 500, height: 400), displayID: F.a.id)
        let b = WindowSnapshot(id: .init(rawValue: "b-window"), processIdentifier: 42,
            bundleIdentifier: "org.example.Beta", frame: .init(x: 1200, y: 160, width: 400, height: 320), displayID: F.b.id)
        f.system.windows = [a, b]
        f.system.desktopObservation?.windowMembership = [a.id: [.init(rawValue: 1)], b.id: [.init(rawValue: 2)]]
        f.editor.clearDraft()
        f.refresh(); f.page.pickDisplay(F.b.id)
        #expect(f.page.captureHelp.contains("Studio Display (2)"))
        f.page.request(.capture)
        let document = try #require(f.editor.document)
        #expect(document.slots.map(\.prefer) == [[.app("org.example.Beta")]])
        #expect(document.windows.first?.rect == .init(x: 0.2, y: 0.2, width: 0.4, height: 0.4))
        #expect(f.system.frameWriteCounts.isEmpty)
    }
    @Test func captureRevalidatesDisconnectedPickWithoutFallback() throws {
        let f = F(); defer { f.close() }
        addWindows(f); f.editor.clearDraft(); f.refresh(); f.page.pickDisplay(F.b.id)
        f.live.removeAll { $0.id == F.b.id }; f.sync()
        f.page.request(.capture)
        #expect(f.editor.document == nil)
        #expect(f.editor.entries.isEmpty)
        #expect(f.editor.message == f.target.unavailableReason)
        #expect(f.system.frameWriteCounts.isEmpty)
    }

    @Test func captureUsesNextPickerTargetWhileFinishedRunIsPinned() async throws {
        let f = F(); defer { f.close() }
        addWindows(f); _ = try save(f); f.refresh()
        f.page.apply(f.document); try await f.finish()
        f.page.pickDisplay(F.b.id)
        #expect(f.page.displayID == F.a.id)
        #expect(f.target.selectionID == F.b.id)
        f.page.request(.capture)
        #expect(f.editor.document?.slots.map(\.prefer) == [[.app("org.example.Beta")]])
    }

    @Test func updatePreservesDraftAndDiskOnExternalChange() throws {
        let f = F(); defer { f.close() }
        addWindows(f); let url = try save(f); f.refresh()
        let draft = f.editor.draft.source
        var external = f.document; external.name = "Outside"
        let bytes = try SavedLayoutValidator.encode(external); try bytes.write(to: url)
        f.page.request(.updateFromDesktop)
        f.page.confirmUpdate()
        #expect(f.editor.message?.contains("This file changed outside BetterTile. Reload to inspect it, or Save As to keep your draft in a new file. Nothing was overwritten.") == true)
        #expect(try Data(contentsOf: url) == bytes)
        #expect(f.editor.draft.source == draft)
    }

    @Test func updateDirtyDraftAsksBeforeReadingOrWriting() throws {
        let f = F(); defer { f.close() }
        let url = try save(f); f.refresh()
        let bytes = try Data(contentsOf: url)
        f.editor.edit { $0.name = "Unsaved" }
        f.page.request(.updateFromDesktop)
        f.page.confirmUpdate()
        #expect(f.editor.creation.pending != nil)
        #expect(f.editor.creation.confirmationTitle(editor: f.editor) == "Discard unsaved changes?")
        #expect(f.editor.document?.name == "Unsaved")
        #expect(try Data(contentsOf: url) == bytes)
    }

    @Test func updateRefusesPinnedRunAndDisconnectedPick() async throws {
        let f = F(); defer { f.close() }
        let url = try save(f); f.refresh()
        f.page.apply(f.document); try await f.finish()
        let bytes = try Data(contentsOf: url)
        f.page.request(.updateFromDesktop)
        f.page.confirmUpdate()
        #expect(f.editor.message == "Finish or undo this layout’s Apply before updating it.")
        #expect(f.session.canUndo)
        #expect(try Data(contentsOf: url) == bytes)
        f.session.reset()
        f.page.pickDisplay(F.b.id); f.live.removeAll { $0.id == F.b.id }; f.refresh()
        f.page.request(.updateFromDesktop)
        f.page.confirmUpdate()
        #expect(f.editor.message == f.target.unavailableReason)
        #expect(try Data(contentsOf: url) == bytes)
        #expect(f.system.frameWriteCounts.isEmpty)
    }

    @Test(arguments: [false, true]) func updateRefusesInvalidOrUnreadableSource(invalid: Bool) throws {
        let f = F(); defer { f.close() }
        let url = try save(f); let before = f.editor.document
        if invalid { try Data("invalid".utf8).write(to: url) }
        else { try FileManager.default.removeItem(at: url) }
        let captured = SavedLayoutDocument(name: "Capture", mode: .manual)
        #expect(!f.editor.updateFromCurrentDesktop(captured))
        #expect(f.editor.document == before)
        if invalid { #expect(try Data(contentsOf: url) == Data("invalid".utf8)) }
        else { #expect(!FileManager.default.fileExists(atPath: url.path)) }
    }

    @Test func libraryUsesNaturalNameOrderWithStableEqualNamesAndUnreadableLast() throws {
        let f = F(); defer { f.close() }
        try FileManager.default.createDirectory(at: f.editor.files.directory, withIntermediateDirectories: true)
        let rows = [("z.json", "Layout 10"), ("b.json", "Layout 2"), ("c.json", "alpha"),
                    ("d.json", "Éclair"), ("equal-b.json", "Same"), ("equal-a.json", "Same")]
        for (file, name) in rows.reversed() {
            try SavedLayoutValidator.encode(.init(name: name, mode: .manual)).write(to: f.editor.files.directory.appending(path: file))
        }
        for file in ["bad-z.json", "bad-a.json"] { try Data("bad".utf8).write(to: f.editor.files.directory.appending(path: file)) }
        f.editor.refreshLibrary()
        #expect(f.editor.entries.map(\.lastPathComponent) == ["c.json", "d.json", "b.json", "z.json", "equal-a.json", "equal-b.json", "bad-a.json", "bad-z.json"])
        f.editor.refreshLibrary()
        #expect(f.editor.entries.last?.lastPathComponent == "bad-z.json")
    }

    @Test func deleteSelectsNextThenPreviousThenNoneAndKeepsIndependentOriginals() async throws {
        let f = F(); defer { f.close() }
        let first = try save(f)
        #expect(f.editor.save(as: "Second")); let second = try #require(f.editor.url)
        #expect(f.editor.save(as: "Third")); let third = try #require(f.editor.url)
        let exported = f.directory.appending(path: "export.json"); f.editor.export(to: exported)
        let bytes = try Data(contentsOf: exported)
        #expect(f.editor.load(second))
        f.refresh(); f.page.apply(f.document); try await f.finish()
        #expect(f.session.run != nil && f.session.canUndo)
        #expect(f.page.ownsSelection(f.document))
        f.page.deleteSelectedLayout()
        #expect(f.session.run == nil && !f.session.canUndo)
        #expect(!f.page.ownsSelection(f.document))
        #expect(f.editor.url == third)
        f.page.deleteSelectedLayout(); #expect(f.editor.url == first)
        f.page.deleteSelectedLayout(); #expect(f.editor.url == nil && f.editor.document == nil && f.editor.entries.isEmpty)
        #expect(try Data(contentsOf: exported) == bytes)
    }

    @Test func cardUpdateAlsoChecksTheLastLibraryReadAndProtectsDirtyDrafts() throws {
        let f = F(); defer { f.close() }
        addWindows(f); let first = try save(f)
        #expect(f.editor.save(as: "Second")); let second = try #require(f.editor.url)
        let baseline = try Data(contentsOf: first)
        f.editor.edit { $0.paneGap = 4 }
        f.page.request(.updateFromFile(first))
        f.page.confirmUpdate()
        #expect(f.editor.creation.pending != nil)
        #expect(f.editor.url == second)
        f.editor.creation.keepEditing()
        #expect(f.editor.load(second))
        var external = try SavedLayoutValidator.decode(baseline); external.name = "Outside"
        let bytes = try SavedLayoutValidator.encode(external); try bytes.write(to: first)
        f.page.request(.updateFromFile(first))
        f.page.confirmUpdate()
        #expect(f.editor.url == second)
        #expect(f.editor.message?.contains("changed outside") == true)
        #expect(try Data(contentsOf: first) == bytes)
    }

    @Test func deleteCanSelectAnUnreadableNextCardWithoutRetainingTheDeletedDraft() throws {
        let f = F(); defer { f.close() }
        _ = try save(f)
        let bad = f.editor.files.directory.appending(path: "unreadable.json")
        try Data("invalid".utf8).write(to: bad)
        f.editor.refreshLibrary()
        f.page.deleteSelectedLayout()
        #expect(f.editor.selectedLibraryURL == bad)
        #expect(f.editor.document == nil)
        #expect(f.editor.hasInvalidSource)
        #expect(f.editor.entries == [bad])
    }

}

extension SavedLayoutPageActionTests {
    @Test(arguments: [false, true]) func failedCardUpdateKeepsCompleteEditorState(writeFailure: Bool) throws {
        let f = F(); defer { f.close() }
        addWindows(f)
        let target = try save(f)
        #expect(f.editor.save(as: "Other draft"))
        #expect(f.editor.edit { $0.name = "Unsaved A" })
        #expect(f.editor.edit { $0.paneGap = 12 })
        f.editor.undo()
        f.editor.selectedPane = ""; f.editor.selectedRectangle = "editor"
        let source = f.editor.draft.source, baseline = f.editor.baseline
        let url = f.editor.url, sourceURL = f.editor.sourceURL
        let undo = f.editor.undoStack.map(\.document), redo = f.editor.redoStack.map(\.document)
        let targetBytes = try Data(contentsOf: target)
        f.refresh()
        if writeFailure {
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: f.editor.files.directory.path)
        } else {
            f.model.savedLayoutApplier?.snapshot = { throw SavedLayoutFileError(message: "Capture failed") }
        }
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: f.editor.files.directory.path) }
        // Same action invoked by the replacement confirmation, after its user approval.
        f.page.perform(.updateFromFile(target))
        #expect(f.editor.message?.contains("Couldn’t update") == true)
        #expect(f.editor.draft.source == source && f.editor.baseline == baseline)
        #expect(f.editor.url == url && f.editor.sourceURL == sourceURL)
        #expect(f.editor.selectedPane == "" && f.editor.selectedRectangle == "editor")
        #expect(f.editor.undoStack.map(\.document) == undo && f.editor.redoStack.map(\.document) == redo)
        #expect(try Data(contentsOf: target) == targetBytes)
        #expect(f.system.frameWriteCounts.isEmpty)
    }
}
