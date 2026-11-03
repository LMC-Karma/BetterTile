import AppKit
import BetterTileCore
import SwiftUI
import Testing
@testable import BetterTileApp

@MainActor final class ApplySessionFixture {
    let display = DisplayID(rawValue: "display")
    let defaults = MemoryDefaults()
    var runtime = SavedLayoutApplyRuntime()
    var starts: [(SavedLayoutDocument, DisplayID?, [String: WindowID])] = []
    var cancelled = false
    var undone = false
    var placed: WindowID?
    var problem: String?
    var rows: [SavedLayoutPreviewRow] = []
    private var runSequence: TimeInterval = 1000
    func nextRunDate() -> Date { runSequence += 1; return Date(timeIntervalSince1970: runSequence) }
    var session: SavedLayoutApplySession!
    var document: SavedLayoutDocument {
        .init(name: "Main + 2", mode: .bento, layout: .slot("ready"), slots: rows.map(\.slot))
    }
    func window(_ id: String, title: String = "Document") -> WindowSnapshot {
        .init(id: .init(rawValue: id), processIdentifier: 42, bundleIdentifier: "com.apple.TextEdit",
              title: title, frame: .init(x: 0, y: 0, width: 400, height: 300), displayID: display)
    }
    func row(_ id: String, _ status: SavedLayoutPreviewRow.Status) -> SavedLayoutPreviewRow {
        let applications = ["ready": ("com.apple.Safari", "Safari"), "choose": ("com.apple.TextEdit", "TextEdit"),
                            "open": ("com.apple.Notes", "Notes"), "new": ("com.apple.dt.Xcode", "Xcode"),
                            "missing": ("com.example.Missing", "Missing app"), "desktop": ("com.apple.Music", "Music")]
        let app = applications[id] ?? ("com.apple.TextEdit", "TextEdit")
        return .init(slot: .init(id: id, bundleID: app.0), appName: app.1, status: status)
    }
    init() {
        session = SavedLayoutApplySession(preview: { [unowned self] doc, target, _ in .init(document: doc, displayID: target ?? self.display, rows: self.rows, problem: self.problem) },
            start: { [unowned self] in
                self.starts.append(($0, $1, $2))
                self.runtime.isStarting = true
                Task { @MainActor [weak self] in
                    await Task.yield()
                    self?.runtime.isStarting = false
                }
            },
            runtime: { [unowned self] in self.runtime }, undo: { [unowned self] in self.undone = true })
    }
    func review() {
        rows = [row("ready", .matched(window("one"))), row("choose", .severalWindows([window("two"), window("three", title: "") ])),
                row("open", .empty), row("new", .empty), row("missing", .notInstalled), row("desktop", .onAnotherDesktop)]
        session.apply(document: document)
    }
    func finish() async throws {
        session.confirm()
        try await waitForApplyStart(session)
        runtime.lastRun = .init(layoutName: document.name, offersUndo: true, date: nextRunDate(), displayID: display,
            result: .init(placed: 1, unplaced: 5,
                          placedSlots: ["ready"]))
        runtime.canUndo = true

    }
}

@Suite(.appTestApplication) @MainActor struct SavedLayoutApplySessionTests {




    /// After an edit or a reload, the result of the last run is stale: the group shows Apply again.
    @Test func resetReturnsAFinishedResultToReadyButNotARunInProgress() async throws {
        let f = ApplySessionFixture()
        f.review()
        try await waitForSavedLayoutState("Apply did not finish starting.") {
            if case .idle = f.session.phase { true } else { false }
        }
        try await f.finish()
        guard case .applied = f.session.phase else { Issue.record("Expected a result, got \(f.session.phase)"); return }
        f.runtime.isRunning = true
        f.session.reset()
        guard case .applying = f.session.phase else { Issue.record("A run in progress must keep going"); return }
        f.runtime.isRunning = false
        f.session.reset()
        guard case .idle = f.session.phase else { Issue.record("Expected idle, got \(f.session.phase)"); return }
        #expect(f.session.preview == nil)
    }

    @Test func allReadyStartsWithoutReview() {
        let f = ApplySessionFixture()
        f.rows = [f.row("ready", .matched(f.window("a")))]
        f.session.apply(document: f.document, displayID: f.display)
        #expect(f.starts.count == 1)
        #expect(f.starts[0].1 == f.display && f.starts[0].2.isEmpty)
        if case .reviewing = f.session.phase { Issue.record("Ready layouts must start directly") }
    }
    @Test(arguments: [false, true]) func repeatedApplyClicksScheduleOnlyOneStart(resetFirst: Bool) async throws {
        let f = ApplySessionFixture()
        f.rows = [f.row("ready", .matched(f.window("a")))]
        f.session.apply(document: f.document)
        if resetFirst { f.session.reset() } else { f.session.apply(document: f.document) }
        #expect(f.starts.count == 1)
        if case .applying = f.session.phase {} else { Issue.record("Expected applying while the start is queued") }
        #expect(f.session.problem == "Applying… Wait before applying or resetting the layout.")
        f.runtime.lastRun = .init(layoutName: f.document.name, offersUndo: true, date: f.nextRunDate(), displayID: f.display,
            result: .init(placed: 1, placedSlots: ["ready"]))
        f.runtime.canUndo = true
        if case .applying = f.session.phase {} else { Issue.record("Keep Applying until the start guard clears") }
        #expect(f.session.isStartingForTesting)
        #expect(f.session.run == nil)
        #expect(!f.session.canUndo)
        f.session.reset()
        #expect(f.session.problem == "Applying… Wait before applying or resetting the layout.")
        #expect(f.session.preview != nil)
        f.session.apply(document: f.document)
        #expect(f.starts.count == 1)
        try await waitForApplyStart(f.session)
        if case .applied = f.session.phase {} else { Issue.record("Publish the result after startup") }
        #expect(f.session.run?.date == f.runtime.lastRun?.date)
        #expect(f.session.problem == nil)
        #expect(f.session.canUndo)
        f.session.undo()
        #expect(f.undone)
        f.session.reset()
        if case .idle = f.session.phase {} else { Issue.record("Reset works after startup") }
    }

    @Test func emptySlotsStartWithoutReview() {
        for status: SavedLayoutPreviewRow.Status in [.empty, .empty, .notInstalled] {
            let f = ApplySessionFixture()
            f.rows = [f.row("attention", status)]
            f.session.apply(document: f.document)
            #expect(f.starts.count == 1)
            if case .reviewing = f.session.phase { Issue.record("Apply must start in one click") }
        }
    }
    @Test func previewProblemsAndErrorsNeverStart() {
        let f = ApplySessionFixture()
        f.rows = [f.row("ready", .matched(f.window("a")))]
        f.problem = "The layout cannot fit."
        f.session.apply(document: f.document)
        f.session.confirm()
        #expect(f.session.problem == f.problem && f.starts.isEmpty)
        let session = SavedLayoutApplySession(preview: { _, _, _ in throw SavedLayoutFileError(message: "Cannot read desktop.") }, start: { _, _, _ in Issue.record("Must not start") })
        session.apply(document: f.document)
        #expect(session.problem == "Cannot read desktop.")
    }

    @Test func reportsStartFailureWithoutInventingAResult() async throws {
        let f = ApplySessionFixture()
        f.rows = [f.row("ready", .matched(f.window("a")))]
        f.session.apply(document: f.document)
        f.runtime.message = "This desktop cannot be laid out now."
        try await waitForSavedLayoutState("The Apply failure was not published.") {
            f.session.problem == f.runtime.message
        }
        #expect(f.session.problem == f.runtime.message)
        #expect(f.session.run == nil)
        f.session.cancelReview()
        #expect(f.session.problem == nil)
    }
    @Test func runtimeDrivesPhaseAndUndoWithoutLosingPlacedEvidence() async throws {
        let f = ApplySessionFixture()
        f.review(); f.session.confirm()
        f.runtime.isRunning = true
        if case .applying = f.session.phase {} else { Issue.record("Expected applying") }
        f.runtime.isRunning = false
        f.review(); try await f.finish()
        if case .applied = f.session.phase {} else { Issue.record("Expected applied") }
        #expect(f.session.run?.presentation.summary == "1 placed · 5 skipped")
        #expect(f.session.run?.result.placedSlots.contains("ready") == true)
        f.session.undo(); #expect(f.undone)
        f.runtime.lastRun?.result.issues.append(.init(.stopped, "Stopped."))
        #expect(f.session.run?.result.placedSlots.contains("ready") == true)
    }
    @Test func quickCaptureNamesUseShapeAndUniqueSuffixes() {
        let shapes: [(TabbedPreset, String)] = [(.single, "Single Pane"), (.columns, "2 Columns"), (.rows, "2 Rows"), (.focus, "Main + 2"), (.grid, "2×2 Grid")]
        for (preset, expected) in shapes {
            let count = preset == .single ? 1 : preset == .focus ? 3 : preset == .grid ? 4 : 2
            let document = SavedLayoutDocument(name: "Capture", mode: .bento,
                layout: SavedLayoutCanvas.presetLayout(preset, panes: (0..<count).map { .slot("\($0)") }))
            #expect(SavedLayoutQuickCapture.name(for: document, existingNames: []) == expected)
            #expect(SavedLayoutQuickCapture.name(for: document, existingNames: [expected, expected + " 2"]) == expected + " 3")
        }
        #expect(SavedLayoutQuickCapture.name(for: .init(name: "Capture", mode: .manual), existingNames: []) == "Manual")
    }
}



@Test(.appTestApplication) @MainActor func savedLayoutSessionExposesTypedStateAndExactOwner() {
    let f = ApplySessionFixture()
    let owner = SavedLayoutApplyOwner(document: f.document,
        desktop: .init(displayID: f.display, spaceID: .init(rawValue: 42)))
    f.runtime.owner = owner
    f.runtime.isRunning = true
    f.runtime.slotStatuses = ["ready": .waiting, "choice": .needsChoice]
    #expect(f.session.owner == owner)
    #expect(f.session.state(forSlot: "ready") == .waiting)
    if case .applying = f.session.phase {} else { Issue.record("Expected applying") }
    #expect(f.session.state(forSlot: "choice") == .needsChoice)
    #expect(f.session.state(forSlot: "unknown") == nil)
}

@Suite(.appTestApplication) @MainActor struct SavedLayoutPageStateTests {
    @Test func pageRequiresTheSameDocumentAndDesktopForResult() async throws {
        let f = ApplySessionFixture()
        f.review(); try await f.finish()
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let editor = SavedLayoutEditor(files: .init(directory: folder))
        defer { try? FileManager.default.removeItem(at: folder) }
        let desktop = SavedLayoutDesktop(displayID: f.display, spaceID: .init(rawValue: 1))
        f.runtime.owner = .init(document: f.document, desktop: desktop)
        let page = SavedLayoutSettings(editor: editor, suppliedSession: f.session, targetOverride: desktop)
        #expect(page.ownsSelection(f.document))
        var other = f.document
        other.name = "Other layout"
        #expect(!page.ownsSelection(other))
        f.runtime.owner?.desktop.spaceID = .init(rawValue: 2)
        #expect(!page.ownsSelection(f.document))
        #expect(page.pageStatus(f.document, states: ["ready": .failed(reason: "Old failure")]) == "Ready to apply")
    }

    @Test func pageStatusFollowsApplyFailureAndAlreadyApplied() async throws {
        let f = ApplySessionFixture()
        f.rows = [f.row("ready", .empty)]
        f.session.apply(document: f.document)
        try await waitForSavedLayoutState("Apply did not finish starting.") {
            if case .idle = f.session.phase { true } else { false }
        }
        let desktop = SavedLayoutDesktop(displayID: f.display, spaceID: .init(rawValue: 1))
        f.runtime.owner = .init(document: f.document, desktop: desktop)
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let page = SavedLayoutSettings(editor: SavedLayoutEditor(files: .init(directory: folder)),
            suppliedSession: f.session, targetOverride: desktop)
        f.runtime.isRunning = true
        #expect(page.pageStatus(f.document, states: ["ready": .waiting]) == "Applying…")
        f.runtime.isRunning = false
        f.runtime.lastRun = .init(layoutName: f.document.name, offersUndo: true, date: f.nextRunDate(), displayID: f.display,
            result: .init(placed: 1, placedSlots: ["ready"]))
        #expect(page.pageStatus(f.document, states: ["ready": .failed(reason: "Could not open")]) == "Some windows need attention")
        #expect(page.pageStatus(f.document, states: ["ready": .placed]) == "Applied")
        f.runtime.lastRun?.offersUndo = false
        #expect(page.pageStatus(f.document, states: ["ready": .placed]) == "Already applied")
        f.session.cancelReview()
        #expect(!page.ownsSelection(f.document))
        #expect(page.pageStatus(f.document, states: ["ready": .placed]) == "Ready to apply")
    }

    @Test func pageCountsAttentionAndSkippedOutcomes() async throws {
        let f = ApplySessionFixture()
        f.rows = [f.row("ready", .empty), f.row("missing", .notInstalled), f.row("choose", .empty)]
        f.session.apply(document: f.document)
        try await waitForApplyStart(f.session)
        let desktop = SavedLayoutDesktop(displayID: f.display, spaceID: .init(rawValue: 1))
        f.runtime.owner = .init(document: f.document, desktop: desktop)
        f.runtime.slotStatuses = ["ready": .placed, "missing": .failed(reason: "This app is not installed."), "choose": .needsChoice]
        var result = SavedLayoutApplyResult(placed: 1, placedSlots: ["ready"])
        result.recordSlots(f.document.slots.map(\.id))
        f.runtime.lastRun = .init(layoutName: f.document.name, offersUndo: true, date: f.nextRunDate(), displayID: f.display, result: result)
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let page = SavedLayoutSettings(editor: SavedLayoutEditor(files: .init(directory: folder)),
            suppliedSession: f.session, targetOverride: desktop)
        #expect(page.pageDetail(f.document) == "1 placed · 2 need attention")
        f.runtime.slotStatuses["missing"] = .skipped
        #expect(page.pageDetail(f.document) == "1 placed · 1 needs attention · 1 skipped")
        f.runtime.slotStatuses["choose"] = .skipped
        #expect(page.pageDetail(f.document) == "1 placed · 2 skipped")
    }

    @Test func recoveryIsOfferedOnlyForFailureOrWindowChoice() {
        #expect(SavedLayoutPagePreview.needsRecovery(.failed(reason: "App did not open")))
        #expect(SavedLayoutPagePreview.needsRecovery(.needsChoice))
        for state: SavedLayoutSlotStatus? in [nil, .waiting, .waiting, .placed, .skipped] {
            #expect(!SavedLayoutPagePreview.needsRecovery(state))
        }
    }
}



@Test(.appTestApplication) @MainActor func savedLayoutStartingPageDoesNotPublishAnEarlyResult() async throws {
    let f = ApplySessionFixture()
    f.rows = [f.row("ready", .matched(f.window("a")))]
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let page = SavedLayoutSettings(editor: .init(files: .init(directory: folder)), suppliedSession: f.session)
    f.session.apply(document: f.document)
    f.runtime.lastRun = .init(layoutName: f.document.name, offersUndo: true, date: f.nextRunDate(), displayID: f.display,
        result: .init(placed: 1, placedSlots: ["ready"]))
    #expect(page.pageStatus(f.document, states: ["ready": .placed]) == "Applying…")
    page.apply(f.document)
    #expect(f.session.problem == "Applying… Wait before applying or resetting the layout.")
    #expect(f.starts.count == 1)
    #expect(f.session.run == nil)
    try await waitForApplyStart(f.session)
    #expect(f.session.run?.date == f.runtime.lastRun?.date)
    #expect(f.session.problem == nil)
}
