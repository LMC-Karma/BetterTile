import AppKit
import BetterTileCore
import SwiftUI
import Testing
@testable import BetterTileApp

@Suite(.appTestApplication) @MainActor struct SavedLayoutCreationTests {
    func editor(_ directory: URL) -> SavedLayoutEditor { .init(files: .init(directory: directory)) }

    @Test(arguments: [LayoutMode.manual, .bento, .tabbed])
    func continueCreatesOnlyALocalDraft(mode: LayoutMode) throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let editor = editor(directory), flow = SavedLayoutCreation(), apply = ApplySessionFixture()
        let setup = SavedLayoutNewSetup(name: "Writing", mode: mode, preset: .grid)
        #expect(setup.showsPresets == (mode != .manual))
        flow.begin(setup, editor: editor)
        let document = try #require(editor.document)
        #expect(document.name == "Writing")
        #expect(document.mode == mode)
        #expect(document.slots.count == (mode == .manual ? 1 : 4))
        #expect(document.slots.allSatisfy { $0.prefer.isEmpty })
        #expect(mode == .manual ? document.layout == nil : SavedLayoutCanvasGeometry.panes(document).count == 4)
        #expect(flow.isDraft)
        #expect(editor.url == nil)
        #expect(editor.entries.isEmpty)
        #expect(flow.pending == nil)
        #expect(apply.starts.isEmpty)
    }

    @Test func setupIsTheStartingPointForUndo() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let editor = editor(directory), flow = SavedLayoutCreation()
        flow.openSetup()
        flow.continueSetup(.init(name: "Research", mode: .tabbed, preset: .grid))
        #expect(!flow.showingSetup)
        guard case let .new(setup)? = flow.setupDismissed(editor: editor, isApplying: false) else {
            Issue.record("Expected Continue after sheet dismissal"); return
        }
        #expect(flow.setupToContinue == nil)
        #expect(flow.pending == nil)
        flow.begin(setup, editor: editor)
        let startingPoint = editor.document
        #expect(!editor.canUndo)
        #expect(!editor.canRedo)
        editor.assign(bundleID: "com.apple.Safari", pane: SavedLayoutCanvasGeometry.panes(try #require(editor.document)).first)
        #expect(editor.canUndo)
        editor.undo()
        #expect(editor.document == startingPoint)
        #expect(!editor.canUndo)
    }

    @Test func draftConfirmationTitlesNameTheAction() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let editor = editor(directory), flow = SavedLayoutCreation()
        flow.begin(.init(), editor: editor)
        _ = flow.request(.cancelDraft, editor: editor, isApplying: false)
        #expect(flow.confirmationTitle(editor: editor) == "Discard this draft?")
        flow.keepEditing()
        _ = flow.request(.new(.init()), editor: editor, isApplying: false)
        #expect(flow.confirmationTitle(editor: editor) == "Replace this draft?")
        flow.keepEditing()
        #expect(flow.save(editor: editor))
        editor.edit { $0.paneGap = 6 }
        _ = flow.request(.capture, editor: editor, isApplying: false)
        #expect(flow.confirmationTitle(editor: editor) == "Discard unsaved changes?")
    }

    @Test func setupCancelLeavesSelectionDraftAndApplyUntouched() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let editor = editor(directory), flow = SavedLayoutCreation(), apply = ApplySessionFixture()
        editor.newLayout(); #expect(editor.save(as: "Existing"))
        editor.edit { $0.paneGap = 8 }
        let before = editor.document, url = editor.url, history = editor.undoStack.count
        flow.openSetup()
        flow.cancelSetup()
        #expect(flow.setupDismissed(editor: editor, isApplying: false) == nil)
        #expect(!flow.showingSetup)
        #expect(flow.setupToContinue == nil)
        #expect(flow.pending == nil)
        #expect(editor.document == before)
        #expect(editor.url == url)
        #expect(editor.undoStack.count == history)
        #expect(editor.isDirty)
        #expect(!apply.cancelled)
        #expect(apply.starts.isEmpty)
    }

    @Test(arguments: [false, true])
    func everyReplacementProtectsFreshAndAssignedDrafts(assigned: Bool) throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let editor = editor(directory), flow = SavedLayoutCreation()
        editor.newLayout(); #expect(editor.save(as: "Existing"))
        let url = try #require(editor.url)
        flow.begin(.init(), editor: editor)
        if assigned { editor.assign(bundleID: "com.apple.Safari", pane: SavedLayoutCanvasGeometry.panes(try #require(editor.document)).first) }
        let before = editor.document
        for action: SavedLayoutEditorAction in [.new(.init()), .open(url), .capture, .cancelDraft] {
            #expect(flow.request(action, editor: editor, isApplying: false) == nil)
            #expect(flow.pending != nil)
            flow.keepEditing()
            #expect(flow.pending == nil)
            #expect(editor.document == before)
            #expect(editor.url == nil)
        }
        #expect(flow.request(.open(url), editor: editor, isApplying: false) == nil)
        guard case let .open(approved)? = flow.discardDraft() else { Issue.record("Expected confirmed card selection"); return }
        #expect(editor.load(approved))
        flow.finish()
        #expect(editor.url == url)
        #expect(editor.document?.name == "Existing")
    }

    @Test func runningApplyBlocksCreationCaptureAndDraftCancel() async throws {
        let editor = editor(FileManager.default.temporaryDirectory.appending(path: UUID().uuidString))
        let flow = SavedLayoutCreation(), apply = ApplySessionFixture()
        apply.review(); try await apply.finish(); apply.runtime.isRunning = true
        let starts = apply.starts.count, owner = apply.session.owner
        for action: SavedLayoutEditorAction in [.new(.init()), .capture, .cancelDraft] {
            #expect(flow.request(action, editor: editor, isApplying: true) == nil)
            #expect(flow.pending == nil)
        }
        #expect(apply.starts.count == starts)
        #expect(!apply.cancelled)
        #expect(apply.session.owner == owner)
        #expect(apply.session.canUndo)
    }

    @Test func browsingCardsDuringApplyKeepsOwnerProgressAndUndo() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let editor = editor(directory), apply = ApplySessionFixture()
        apply.rows = [apply.row("ready", .matched(apply.window("one")))]
        editor.newLayout()
        #expect(editor.edit { $0 = apply.document })
        #expect(editor.save(as: apply.document.name))
        let ownedURL = try #require(editor.url), ownedDocument = try #require(editor.document)
        editor.newLayout(); #expect(editor.save(as: "Other"))
        let otherURL = try #require(editor.url)
        #expect(editor.load(ownedURL))
        let desktop = SavedLayoutDesktop(displayID: apply.display, spaceID: .init(rawValue: 1))
        apply.session.apply(document: ownedDocument, displayID: apply.display)
        try await apply.finish()
        apply.runtime.owner = .init(document: ownedDocument, desktop: desktop)
        apply.runtime.slotStatuses = ["ready": .waiting]
        apply.runtime.isRunning = true
        let owner = apply.session.owner, progress = apply.runtime.slotStatuses, runDate = apply.session.run?.date
        let page = SavedLayoutSettings(editor: editor, suppliedSession: apply.session, targetOverride: desktop)
        page.request(.open(otherURL))
        #expect(editor.url == otherURL)
        guard editor.url == otherURL else { return }
        let other = try #require(editor.document)
        #expect(page.applyingStatus(other) == "Another layout is applying…")
        #expect(page.pageStatus(other, states: [:]) == "Ready to apply")
        #expect(!page.ownsSelection(other))
        #expect(apply.session.owner == owner)
        #expect(apply.runtime.slotStatuses == progress)
        #expect(apply.session.canUndo)
        #expect(apply.session.run?.date == runDate)
        #expect(!apply.cancelled)
        page.request(.open(ownedURL))
        #expect(editor.document == ownedDocument)
        #expect(page.ownsSelection(ownedDocument))
        #expect(page.applyingStatus(ownedDocument) == "Applying…")
        #expect(page.pageStatus(ownedDocument, states: progress) == "Applying…")
        #expect(apply.runtime.slotStatuses == progress)
        #expect(apply.session.canUndo)
    }

    @Test func nameValidationAndDuplicateNamesReuseExistingRules() throws {
        #expect(SavedLayoutNewSetup().name == "Untitled Layout")
        #expect(SavedLayoutNewSetup(name: " \n ").nameIssue == "Give this layout a name.")
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let editor = editor(directory), flow = SavedLayoutCreation(), apply = ApplySessionFixture()
        editor.newLayout(); #expect(editor.save(as: "Writing"))
        let original = try #require(editor.url), bytes = try editor.files.read(original)
        flow.begin(.init(name: "Writing"), editor: editor)
        #expect(flow.save(editor: editor))
        #expect(editor.url != original)
        #expect(editor.entries.count == 2)
        #expect(try editor.files.read(original) == bytes)
        #expect(!flow.isDraft)
        #expect(!editor.isDirty)
        #expect(apply.starts.isEmpty)
    }

    @Test func failedSaveKeepsDraftAndRetrySucceeds() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("blocks directory creation".utf8).write(to: directory)
        let editor = editor(directory), flow = SavedLayoutCreation()
        flow.begin(.init(name: "Keep me"), editor: editor)
        let before = editor.document
        #expect(!flow.save(editor: editor))
        #expect(flow.isDraft)
        #expect(editor.document == before)
        #expect(editor.url == nil)
        #expect(editor.messageStatus?.kind == .bad)
        try FileManager.default.removeItem(at: directory)
        #expect(flow.save(editor: editor))
        #expect(editor.url != nil)
        #expect(!flow.isDraft)
    }

    @Test func cancelReturnsToPreviousSavedSelectionOrEmptyLibrary() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let editor = editor(directory), flow = SavedLayoutCreation()
        flow.begin(.init(), editor: editor)
        #expect(flow.cancel(editor: editor))
        #expect(editor.document == nil)
        #expect(SavedLayoutSettings(editor: editor).isEmptyLibrary)
        editor.newLayout(); #expect(editor.save(as: "Existing"))
        let url = editor.url
        flow.begin(.init(), editor: editor)
        #expect(flow.cancel(editor: editor))
        #expect(editor.url == url)
        #expect(editor.document?.name == "Existing")
    }

    @Test func creationSurvivesPageRecreationAndAccessOnlyGatesLiveActions() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let editor = editor(directory)
        editor.creation.begin(.init(), editor: editor)
        editor.assign(bundleID: "com.apple.Safari", pane: SavedLayoutCanvasGeometry.panes(try #require(editor.document)).first)
        let model = BetterTileModel(store: .init(fileURL: directory.appending(path: "config.json")), system: FakeAppWindowSystem(), startRuntime: false)
        defer { model.shutdown() }
        let apply = ApplySessionFixture()
        var page = SavedLayoutSettings(editor: editor, model: model, suppliedSession: apply.session)
        model.hasAccessibilityPermission = false
        #expect(page.canCreate)
        #expect(!page.canCapture)
        #expect(!page.canApply(try #require(editor.document)))
        page = SavedLayoutSettings(editor: editor, model: model, suppliedSession: apply.session)
        #expect(editor.creation.isDraft)
        #expect(page.canCreate)
        model.hasAccessibilityPermission = true
        #expect(editor.creation.save(editor: editor))
        #expect(page.canApply(try #require(editor.document)))
        #expect(apply.starts.isEmpty)
        apply.runtime.isRunning = true
        #expect(!page.canCreate)
        #expect(!page.canCapture)
        #expect(!page.canApply(try #require(editor.document)))
    }

    @Test func fileMenuHasNoCreationEntryOrShortcut() throws {
        let source = try String(contentsOf: URL(filePath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appending(path: "Sources/BetterTileApp/SavedLayoutSettings.swift"), encoding: .utf8)
        let menu = try #require(source.range(of: "@ViewBuilder var fileMenuItems"))
        let end = try #require(source.range(of: "private func modeRow", range: menu.upperBound..<source.endIndex))
        #expect(!source[menu.lowerBound..<end.lowerBound].contains("New Layout"))
    }
}
