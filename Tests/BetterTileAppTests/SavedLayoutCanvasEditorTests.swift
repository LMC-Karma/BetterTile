import BetterTileCore
import AppKit
import Foundation
import Testing
@testable import BetterTileApp

@Suite(.appTestApplication, .settingsUI) @MainActor struct SavedLayoutCanvasEditorTests {
    private func temporaryFiles() -> SavedLayoutFiles {
        SavedLayoutFiles(directory: FileManager.default.temporaryDirectory.appending(path: "SavedLayoutCanvasTests-" + UUID().uuidString))
    }
    private func columns(_ ratios: [Double], _ children: [SavedLayoutNode]) -> SavedLayoutNode {
        .split(axis: .vertical, ratios: ratios, children: children)
    }
    private func seeded(_ layout: SavedLayoutNode, slots: [String] = [], name: String = "Canvas") -> SavedLayoutEditor {
        let editor = SavedLayoutEditor(files: temporaryFiles())
        editor.newLayout()
        #expect(editor.edit {
            $0 = SavedLayoutDocument(name: name, mode: .bento, layout: layout, slots: slots.map { .init(id: $0, bundleID: "com.example.\($0)") })
        })
        return editor
    }
    private func ratios(_ editor: SavedLayoutEditor) -> [Double] {
        if case let .split(_, ratios, _)? = editor.document?.layout { ratios } else { [] }
    }
    private func firstPane(_ editor: SavedLayoutEditor) throws -> SavedLayoutPane {
        let document = try #require(editor.document)
        return try #require(SavedLayoutCanvasGeometry.panes(document).first)
    }
    private let first = SavedLayoutDividerAddress(path: [], index: 0)
    private let second = SavedLayoutDividerAddress(path: [], index: 1)
    private func name(_ bundleID: String) -> String { bundleID.split(separator: ".").last.map(String.init) ?? bundleID }

    @Test func aDividerDragCommitsOneEditAndOneHistoryEntry() throws {
        let editor = seeded(columns([0.5, 0.5], [.empty, .empty]))
        let original = try #require(editor.document), bytes = editor.draft.source
        #expect(editor.beginResize(first))
        for step in 1...30 {
            let moved = try #require(editor.updateResize(share: 0.5 + Double(step) * 0.01))
            #expect(moved.firstShare >= moved.lower)
        }
        // While dragging, the document, its bytes, and the history stay as they were.
        #expect(editor.document == original)
        #expect(editor.draft.source == bytes)
        #expect(editor.undoStack.count == 1) // only the seeding edit
        let shown = try #require(editor.displayDocument)
        #expect(shown != original)
        #expect(editor.commitResize())
        #expect(editor.undoStack.count == 2)
        #expect(abs(ratios(editor)[0] - 0.8) < 1e-9)
        #expect(abs(ratios(editor).reduce(0, +) - 1) < 1e-9)
        #expect(editor.resize == nil)
        #expect(editor.canvasStatus?.text == "80% | 20%")
        #expect(!editor.commitResize())
        editor.undo()
        #expect(editor.document == original)
    }

    @Test func aDragThatDoesNotMoveAddsNoHistoryAndACancelRestores() throws {
        let editor = seeded(columns([0.5, 0.5], [.empty, .empty]))
        let before = editor.undoStack.count, original = editor.document
        #expect(editor.beginResize(first))
        editor.updateResize(share: 0.5)
        #expect(!editor.commitResize())
        #expect(editor.undoStack.count == before)
        #expect(editor.beginResize(first))
        editor.updateResize(share: 0.7)
        editor.cancelResize()
        #expect(editor.displayDocument == original)
        #expect(editor.document == original)
        #expect(editor.undoStack.count == before)
        #expect(editor.canvasStatus?.text == "Resize cancelled.")
    }

    @Test func aDragAlwaysStartsFromItsBeginningAndStopsAtTheLimits() throws {
        let editor = seeded(columns([0.2, 0.3, 0.5], [.empty, .empty, .empty]))
        #expect(editor.beginResize(second))
        editor.updateResize(share: 0.9)
        editor.updateResize(share: 0.6) // moving back must not keep the earlier move
        #expect(editor.commitResize())
        let value = ratios(editor)
        #expect(abs(value[0] - 0.2) < 1e-9 && abs(value[1] - 0.4) < 1e-9 && abs(value[2] - 0.4) < 1e-9)
        #expect(editor.beginResize(first))
        let clamped = try #require(editor.updateResize(share: 0.0))
        #expect(abs(clamped.firstShare - 0.1) < 1e-9)
        editor.cancelResize()
    }

    @Test func manualLayoutsAndMissingDividersDoNotStartADrag() {
        let editor = SavedLayoutEditor(files: temporaryFiles())
        editor.newLayout(mode: .manual)
        #expect(!editor.beginResize(first))
        let tree = seeded(columns([0.5, 0.5], [.empty, .empty]))
        #expect(!tree.beginResize(.init(path: [4], index: 0)))
        #expect(tree.beginResize(first))
        #expect(!tree.beginResize(first)) // one drag at a time
        tree.cancelResize(announce: false)
    }

    @Test func undoAndRedoRoundTripAndANewEditClearsRedo() throws {
        let editor = seeded(columns([0.5, 0.5], [.slot("a"), .empty]), slots: ["a"])
        let start = try #require(editor.document)
        editor.setPreset(.rows)
        let rows = try #require(editor.document)
        #expect(rows != start)
        editor.split(try #require(SavedLayoutCanvasGeometry.panes(rows).first), axis: .vertical)
        let split = try #require(editor.document)
        editor.undo(); #expect(editor.document == rows)
        editor.undo(); #expect(editor.document == start)
        #expect(editor.undoStack.count == 1) // the seeding edit remains
        editor.redo(); #expect(editor.document == rows)
        editor.redo(); #expect(editor.document == split)
        #expect(!editor.canRedo)
        editor.undo()
        #expect(editor.canRedo)
        editor.setPreset(.grid)
        #expect(!editor.canRedo)
        #expect(editor.isDirty)
    }

    @Test func undoReturnsToTheSavedStateAndClearsTheDirtyFlag() throws {
        let editor = seeded(columns([0.5, 0.5], [.empty, .empty]))
        #expect(editor.save(as: "Saved"))
        #expect(!editor.isDirty)
        #expect(editor.nudge(first, by: 0.1))
        #expect(editor.isDirty)
        editor.undo()
        #expect(!editor.isDirty)
        editor.redo()
        #expect(editor.isDirty)
    }

    @Test func historyKeepsTheLastHundredEdits() throws {
        let editor = seeded(.empty)
        for index in 0..<105 { #expect(editor.edit(label: "Rename") { $0.name = "Name \(index)" }) }
        #expect(editor.undoStack.count == 100)
        for _ in 0..<100 { editor.undo() }
        #expect(!editor.canUndo)
        #expect(editor.document?.name == "Name 4")
    }

    @Test func keyboardNudgesOnOneDividerWithinOnePointTwoSecondsShareAnEntry() throws {
        let editor = seeded(columns([0.2, 0.3, 0.5], [.empty, .empty, .empty]))
        var now = 100.0
        editor.clock = { now }
        let original = try #require(editor.document), base = editor.undoStack.count
        #expect(editor.nudge(first, by: 0.01))
        now += 0.5; #expect(editor.nudge(first, by: 0.01))
        now += 1.0; #expect(editor.nudge(first, by: 0.01)) // 1.0 s after the last nudge: still one entry
        #expect(editor.undoStack.count == base + 1)
        #expect(abs(ratios(editor)[0] - 0.23) < 1e-9)
        now += 2.0; #expect(editor.nudge(first, by: 0.01)) // a pause starts a new entry
        #expect(editor.undoStack.count == base + 2)
        now += 0.1; #expect(editor.nudge(second, by: 0.01)) // another divider starts a new entry
        #expect(editor.undoStack.count == base + 3)
        editor.undo(); editor.undo()
        #expect(abs(ratios(editor)[0] - 0.23) < 1e-9)
        editor.undo()
        #expect(editor.document == original)
    }

    @Test func nudgesAtTheLimitReportAndRecordNothing() throws {
        let editor = seeded(columns([0.1, 0.9], [.empty, .empty]))
        let base = editor.undoStack.count
        #expect(!editor.nudge(first, by: -0.01))
        #expect(editor.canvasStatus?.text == "Minimum pane size reached.")
        #expect(editor.undoStack.count == base)
        #expect(editor.nudge(first, by: 0, to: 0.9))
        #expect(abs(ratios(editor)[0] - 0.9) < 1e-9)
        #expect(editor.equalize(first))
        #expect(abs(ratios(editor)[0] - 0.5) < 1e-9)
        #expect(!editor.equalize(first))
        #expect(editor.canvasStatus?.text == "These two panes are already equal.")
    }

    @Test func dropsGoThroughTheEditorWithOneEntryAndSelectTheResult() throws {
        let editor = seeded(columns([0.5, 0.5], [.slot("a"), .slot("b")]), slots: ["a", "b"])
        let base = editor.undoStack.count
        #expect(editor.swap([0], [1], names: name))
        #expect(editor.document?.layout == columns([0.5, 0.5], [.slot("b"), .slot("a")]))
        #expect(editor.selectedPane == "1")
        #expect(editor.canvasStatus?.text == "Swapped a with b.")
        #expect(editor.undoStack.count == base + 1)
        #expect(editor.drop(.app(bundleID: "com.example.c"), onto: .paneEdge([0], .right), names: name))
        #expect(editor.document?.slots.count == 3)
        #expect(editor.selectedPane == "1")
        #expect(editor.undoStack.count == base + 2)
        #expect(editor.drop(.pane([0]), onto: .canvasEdge(.bottom), names: name))
        #expect(SavedLayoutValidator.validate(try #require(editor.document)).isEmpty)
        editor.undo(); editor.undo()
        #expect(editor.document?.layout == columns([0.5, 0.5], [.slot("b"), .slot("a")]))
    }

    @Test func rejectedDropsChangeNothingAndSayWhy() throws {
        let six = (0..<6).map { "s\($0)" }
        let editor = seeded(columns(Array(repeating: 1.0 / 6, count: 6), six.map { .slot($0) }), slots: six)
        let before = editor.document, base = editor.undoStack.count
        #expect(!editor.drop(.app(bundleID: "com.example.seven"), onto: .paneEdge([0], .bottom), names: name))
        #expect(editor.document == before)
        #expect(editor.undoStack.count == base)
        #expect(editor.canvasStatus == .init(text: "Adaptive holds up to 6 apps.", kind: .bad))
    }

    @Test func removingAPaneRemovesItsAppAndUndoRestoresBoth() throws {
        let editor = seeded(columns([0.5, 0.5], [.slot("a"), .slot("b")]), slots: ["a", "b"])
        let before = try #require(editor.document)
        editor.removePane(try #require(SavedLayoutCanvasGeometry.panes(before).first))
        #expect(editor.document?.slots.map(\.id) == ["b"])
        #expect(editor.document?.layout == .slot("b"))
        editor.removePane(try firstPane(editor))
        #expect(editor.canvasStatus?.text == "The only pane can’t be removed.")
        editor.undo()
        #expect(editor.document == before)
    }

    @Test func assigningToAnOccupiedAdaptivePaneReplacesItsApp() throws {
        let editor = seeded(columns([0.5, 0.5], [.slot("a"), .empty]), slots: ["a"])
        editor.assign(bundleID: "com.example.b", pane: try firstPane(editor))
        #expect(editor.document?.slots == [.init(id: "a", bundleID: "com.example.b")])
        #expect(editor.paletteApps == ["com.example.a", "com.example.b"]) // the palette keeps earlier apps
    }

    @Test func aNewLayoutIsNamedAfterItsShapeUntilRenamed() throws {
        let editor = SavedLayoutEditor(files: temporaryFiles())
        editor.newLayout()
        #expect(editor.document?.name == "Untitled Layout")
        editor.setPreset(.columns)
        #expect(editor.document?.name == "2 Columns")
        editor.setPreset(.grid)
        #expect(editor.document?.name == "2×2 Grid")
        editor.split(try firstPane(editor), axis: .vertical)
        #expect(editor.document?.name == "Custom")
        editor.undo()
        #expect(editor.document?.name == "2×2 Grid")
        #expect(editor.edit { $0.name = "Writing" })
        editor.setPreset(.rows)
        #expect(editor.document?.name == "Writing") // a rename ends the automatic name
        #expect(editor.save(as: "Writing"))
        editor.setPreset(.columns)
        #expect(editor.document?.name == "Writing")
    }

    @Test func savedAndOpenedLayoutsKeepTheirNames() throws {
        let files = temporaryFiles(); defer { try? FileManager.default.removeItem(at: files.directory) }
        let editor = SavedLayoutEditor(files: files)
        editor.newLayout()
        editor.setPreset(.columns)
        #expect(editor.save(as: "2 Columns"))
        let url = try #require(editor.url)
        editor.setPreset(.rows)
        #expect(editor.document?.name == "2 Columns")
        #expect(editor.load(url))
        editor.setPreset(.rows)
        #expect(editor.document?.name == "2 Columns")
        #expect(editor.undoStack.count == 1)
        #expect(editor.paletteApps.isEmpty)
    }

    @Test func tabbedCanvasEditsKeepGroupsValid() throws {
        let editor = SavedLayoutEditor(files: temporaryFiles())
        editor.newLayout(mode: .tabbed)
        editor.setPreset(.columns)
        let panes = SavedLayoutCanvasGeometry.panes(try #require(editor.document))
        editor.assign(bundleID: "com.example.a", pane: panes[0])
        #expect(editor.drop(.app(bundleID: "com.example.b"), onto: .pane([0]), names: name)) // adds a tab
        #expect(editor.document?.groups.first?.slots.count == 2)
        #expect(editor.swap([0], [1], names: name))
        #expect(editor.document.map { SavedLayoutValidator.validate($0).isEmpty } == true)
        #expect(editor.drop(.pane([1]), onto: .palette, names: name))
        #expect(editor.document?.groups.count == 2)
        #expect(editor.document?.slots.count == 2)
        #expect(editor.document?.slots.allSatisfy { $0.prefer.isEmpty } == true)
        #expect(editor.document.map { SavedLayoutValidator.validate($0).isEmpty } == true)
    }

    @Test func aCancelledDragIgnoresMovementUntilTheNextMouseDown() {
        var latch = CanvasDragLatch()
        #expect(latch.accepts)
        latch.cancel() // Escape
        // The gesture keeps reporting movement while the button is down: none of it may start or commit anything.
        for _ in 0..<5 { #expect(!latch.accepts) }
        let cancelled = latch.finish() // release: nothing is committed
        #expect(cancelled)
        #expect(latch.accepts) // a new mouse-down starts clean
        let again = latch.finish()
        #expect(!again)
    }

    @Test func cancellingATransactionLeavesNothingToCommit() throws {
        let editor = seeded(columns([0.5, 0.5], [.empty, .empty]))
        let original = editor.document, base = editor.undoStack.count
        #expect(editor.beginResize(first))
        editor.updateResize(share: 0.8)
        editor.cancelResize()
        // What the view does after Escape: later gesture changes are dropped, and the release commits nothing.
        #expect(editor.updateResize(share: 0.9) == nil)
        #expect(!editor.commitResize())
        #expect(editor.document == original)
        #expect(editor.undoStack.count == base)
    }

    // MARK: Escape during a drag (live test C2: the change applied after Escape)

    private func escapeEvent() -> NSEvent {
        _ = NSApplication.shared // NSApp is nil until the application object exists
        return NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                         characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
    }
    private var quietKeys: CanvasKeySource { .init(secondsSinceKeyDown: { 3600 }) }

    @Test func escapeReachingTheKeyMonitorCancelsTheDragAndItsRelease() throws {
        _ = NSApplication.shared
        let session = CanvasDragSession(keys: quietKeys)
        var cancels = 0
        session.begin { cancels += 1 }
        NSApplication.shared.sendEvent(escapeEvent())
        #expect(cancels == 1)
        #expect(!session.accepts) // later movement is ignored
        #expect(session.finish()) // and the release commits nothing
        #expect(session.accepts) // the next mouse-down starts clean
    }

    @Test func aKeyDownTheMonitorNeverSawCancelsOnMovementAndOnRelease() {
        // The menu popover's monitor can consume Escape, and a synthetic Escape can go to another app.
        // No event reaches this session's monitor here; only the session's last key-down time changes.
        var now = Date(timeIntervalSince1970: 1000)
        var secondsSinceKeyDown = 3600.0
        let keys = CanvasKeySource(secondsSinceKeyDown: { secondsSinceKeyDown })
        let session = CanvasDragSession(keys: keys, now: { now })
        var cancels = 0
        session.begin { cancels += 1 }
        #expect(session.accepts)
        now = now.addingTimeInterval(0.5); secondsSinceKeyDown = 0.2
        #expect(!session.accepts) // the next movement cancels and clears the drag at once
        #expect(cancels == 1)
        #expect(session.finish())

        let late = CanvasDragSession(keys: keys, now: { now })
        secondsSinceKeyDown = 3600
        late.begin {}
        now = now.addingTimeInterval(0.5); secondsSinceKeyDown = 0.1
        #expect(late.finish()) // no movement after the key: the release still commits nothing
    }

    @Test func aKeyPressedBeforeTheDragDoesNotCancelIt() {
        var now = Date(timeIntervalSince1970: 1000)
        let session = CanvasDragSession(keys: .init(secondsSinceKeyDown: { 5 }), now: { now })
        session.begin {}
        now = now.addingTimeInterval(1) // the last key went down 5 s ago, before the 1 s old drag
        #expect(session.accepts)
        #expect(!session.finish())
    }

    // MARK: After a cancelled drag, the next drag must work

    @Test func theViewClearingItsStateAfterACancelledReleaseDoesNotBlockTheNextDrag() {
        var now = Date(timeIntervalSince1970: 1000)
        var secondsSinceKeyDown = 3600.0
        let session = CanvasDragSession(keys: .init(secondsSinceKeyDown: { secondsSinceKeyDown }), now: { now })
        // Another process-wide monitor may consume a synthetic Escape before this drag sees it.
        // Synthetic sendEvent does not update CGEventSource, so supply matching key history too.
        let competingMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in event.keyCode == 53 ? nil : event }
        defer { if let competingMonitor { NSEvent.removeMonitor(competingMonitor) } }
        session.begin {}
        now = now.addingTimeInterval(0.5)
        secondsSinceKeyDown = 0.1
        NSApplication.shared.sendEvent(escapeEvent())
        #expect(!session.accepts)
        let cancelled = session.finish() // release of the cancelled gesture
        #expect(cancelled)
        session.cancel() // the view's cleanup runs after finish; it used to set the latch again
        #expect(session.accepts)
    }

    @Test func aNewGestureDiscardsACancelledOneWhoseReleaseNeverArrived() throws {
        let editor = seeded(columns([0.5, 0.5], [.empty, .empty]))
        let session = CanvasDragSession(keys: quietKeys)
        // Drag 1: starts, Escape cancels it, and onEnded never runs.
        #expect(!session.startGesture(at: CGPoint(x: 10, y: 10)))
        session.begin {}
        #expect(editor.beginResize(first))
        NSApplication.shared.sendEvent(escapeEvent())
        #expect(!session.accepts)
        // Drag 2 starts somewhere else: the first onChanged resets everything and the drag commits.
        #expect(session.startGesture(at: CGPoint(x: 200, y: 40)))
        editor.cancelResize(announce: false) // what the view does when `startGesture` reports a stale gesture
        #expect(session.accepts)
        session.begin {}
        #expect(editor.beginResize(first))
        editor.updateResize(share: 0.7)
        #expect(session.accepts)
        let cancelled = session.finish()
        #expect(!cancelled)
        #expect(editor.commitResize())
        #expect(abs(ratios(editor)[0] - 0.7) < 1e-9)
        // The same start point after a normal release is a new gesture, not a stale one.
        #expect(!session.startGesture(at: CGPoint(x: 200, y: 40)))
    }

    @Test func aCancelledDragThenANewOneCommitsOnRelease() throws {
        let editor = seeded(columns([0.5, 0.5], [.empty, .empty]))
        let session = CanvasDragSession(keys: quietKeys)
        // Drag 1, cancelled by Escape, then released.
        _ = session.startGesture(at: .zero)
        session.begin { editor.cancelResize() }
        #expect(editor.beginResize(first))
        editor.updateResize(share: 0.8)
        NSApplication.shared.sendEvent(escapeEvent())
        #expect(!session.accepts)
        #expect(session.finish())
        session.cancel() // view cleanup after release
        #expect(ratios(editor) == [0.5, 0.5])
        // Drag 2: move and release commits.
        #expect(!session.startGesture(at: CGPoint(x: 5, y: 5)))
        #expect(session.accepts)
        session.begin {}
        #expect(editor.beginResize(first))
        editor.updateResize(share: 0.7)
        #expect(session.accepts)
        let cancelled = session.finish()
        #expect(!cancelled)
        #expect(editor.commitResize())
        #expect(abs(ratios(editor)[0] - 0.7) < 1e-9)
    }
}
