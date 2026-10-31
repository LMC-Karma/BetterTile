import AppKit
import BetterTileCore
import BetterTileMacOS
import SwiftUI
import Testing
@testable import BetterTileApp

@MainActor final class SavedLayoutDisplayPickerFixture {
    static func display(_ id: String, name: String = "Studio Display", uuid: String? = nil,
                        serial: UInt32 = 100, x: Double = 0) -> LiveDisplay {
        .init(id: .init(rawValue: id), fingerprint: .init(uuid: uuid ?? id, vendor: 7, model: 10,
            serial: serial, builtIn: false, name: name, frame: .init(x: x, y: 0, width: 1000, height: 800)))
    }
    static let a = display("a", name: "Studio Display (1)")
    static let b = display("b", name: "Studio Display (2)", serial: 200, x: 1000)
    static let c = display("c", name: "Built-in Display", serial: 300, x: 2000)
    let directory = FileManager.default.temporaryDirectory.appending(path: "SavedDisplayPicker-" + UUID().uuidString)
    let system = FakeAppWindowSystem()
    let model: BetterTileModel
    let editor: SavedLayoutEditor
    var live = [SavedLayoutDisplayPickerFixture.a, SavedLayoutDisplayPickerFixture.b, SavedLayoutDisplayPickerFixture.c]
    var current: DisplayID? = SavedLayoutDisplayPickerFixture.a.id
    var focusReads = 0
    var previewReads = 0
    var runSequence: TimeInterval = 1000
    var starts: [DisplayID] = []
    var runtime = SavedLayoutApplyRuntime()
    var session: SavedLayoutApplySession!
    var document: SavedLayoutDocument { editor.document! }
    var target: SavedLayoutTarget { model.savedLayoutTarget }
    var page: SavedLayoutSettings {
        SavedLayoutSettings(editor: editor, model: model, suppliedSession: session, readTargetDisplays: { [unowned self] in live })
    }
    init() {
        model = BetterTileModel(store: .init(fileURL: directory.appending(path: "config.json")), system: system, startRuntime: false)
        editor = SavedLayoutEditor(files: model.savedLayoutActions.files)
        model.hasAccessibilityPermission = true
        system.windows = []
        sync()
        editor.newLayout()
        editor.edit { $0 = .init(name: "Writing", mode: .bento, layout: .slot("editor"),
            slots: [.init(id: "editor", bundleID: "com.apple.Safari")]) }
        model.savedLayoutApplier?.currentDisplayID = { [unowned self] in focusReads += 1; return current }
        session = SavedLayoutApplySession(preview: { [unowned self] document, id, _ in
            previewReads += 1
            guard let id else { throw SavedLayoutFileError(message: "No target") }
            return .init(document: document, displayID: id, rows: [], problem: nil)
        }, start: { [unowned self] document, id, _ in
            guard let id, let space = system.desktopObservation?.currentSpace(on: id) else { Issue.record("Missing desktop"); return }
            starts.append(id)
            runtime.isRunning = true
            runtime.owner = .init(document: document, desktop: .init(displayID: id, spaceID: space))
            runSequence += 1
            runtime.lastRun = .init(layoutName: document.name, offersUndo: true, date: Date(timeIntervalSince1970: runSequence), displayID: id,
                result: .init(placed: 0, unplaced: 1, issues: [.init(.couldNotFit, "Try again", slotID: "editor")]))
            runtime.canUndo = true
            runtime.slotStatuses = ["editor": .failed(reason: "Try again")]
        }, runtime: { [unowned self] in runtime })
    }
    func sync() {
        system.availableDisplays = live.enumerated().map { index, display in
            .init(id: display.id, frame: display.fingerprint.frame, visibleFrame: display.fingerprint.frame, isMain: index == 0)
        }
        let spaces = Dictionary(uniqueKeysWithValues: live.enumerated().map { ($0.element.id, NativeSpaceID(rawValue: UInt64($0.offset + 1))) })
        system.desktopObservation = .init(currentSpaceByDisplay: spaces, knownSpacesByDisplay: spaces.mapValues { Set([$0]) })
    }
    func refresh() { sync(); page.refreshTarget() }
    func finish() async throws {
        runtime.isRunning = false
        try await waitForApplyStart(session)
    }
    func close() { model.shutdown(); try? FileManager.default.removeItem(at: directory) }
}

@Suite(.appTestApplication) @MainActor struct SavedLayoutDisplayPickerTests {
    typealias F = SavedLayoutDisplayPickerFixture
    @Test func defaultFollowsResolverAndPickSurvivesFocusAndPageReopen() {
        let f = F(); defer { f.close() }
        f.refresh()
        #expect(f.target.selection == .following)
        #expect(f.target.displayID == F.a.id)
        f.current = F.b.id; f.refresh()
        #expect(f.target.displayID == F.b.id)
        f.page.pickDisplay(F.a.id)
        let reads = f.focusReads
        f.current = F.c.id
        f.refresh()
        f.page.refreshTarget() // Another page value shares the app-session model.
        #expect(f.target.selection == .picked(F.a.id))
        #expect(f.focusReads == reads)
        #expect(f.page.displayID == F.a.id)
        let fresh = SavedLayoutTarget()
        #expect(fresh.picked == nil) // A new app session has no persisted identity.
    }

    @Test func followChoiceIsFirstAndRestoresFocusTrackingAfterAPick() {
        let f = F(); defer { f.close() }
        f.refresh()
        #expect(f.target.choices.first == .following)
        #expect(f.target.selection == .following)
        #expect(f.page.pickerName == "Studio Display (1) (follows focus)")
        f.page.pickDisplay(F.a.id)
        #expect(f.page.pickerName == "Studio Display (1)")
        f.current = F.b.id; f.page.followFocusedWindow()
        #expect(f.target.picked == nil)
        #expect(f.target.selection == .following)
        #expect(f.target.selectionID == F.b.id)
        #expect(f.page.pickerName == "Studio Display (2) (follows focus)")
        f.current = F.c.id; f.refresh()
        #expect(f.target.selectionID == F.c.id)
        f.page.pickDisplay(F.b.id)
        f.current = F.a.id; f.refresh()
        #expect(f.target.selectionID == F.b.id)
        #expect(f.page.pickerName == "Studio Display (2)")
        f.live = [F.b]; f.refresh()
        #expect(f.page.showsDisplayPicker) // Returning to following remains available with one picked screen.
        f.page.followFocusedWindow()
        #expect(!f.page.showsDisplayPicker)
        #expect(f.target.selection == .following)
    }

    @Test func followingCanRecoverADisconnectedPickWithoutStartingApply() {
        let f = F(); defer { f.close() }
        f.refresh(); f.page.pickDisplay(F.a.id)
        f.live.removeFirst(); f.sync()
        f.page.apply(f.document)
        #expect(f.target.unavailableReason != nil)
        #expect(f.target.choices.first == .following)
        #expect(f.session.problem != nil)
        f.current = F.c.id; f.page.followFocusedWindow()
        #expect(f.target.picked == nil)
        #expect(f.target.unavailableReason == nil)
        #expect(f.session.problem == nil)
        #expect(f.page.canApply(f.document))
        #expect(f.target.selectionID == F.c.id)
        #expect(f.starts.isEmpty && f.system.frameWriteCounts.isEmpty)
        f.page.apply(f.document)
        #expect(f.starts == [F.c.id])
    }

    @Test func returningToFollowingKeepsUndoOwnerAndIsBlockedDuringApply() async throws {
        let f = F(); defer { f.close() }
        f.refresh(); f.page.pickDisplay(F.a.id); f.page.apply(f.document)
        f.current = F.b.id; f.page.followFocusedWindow()
        #expect(f.target.picked?.uuid == F.a.fingerprint.uuid)
        #expect(f.page.displayID == F.a.id)
        try await f.finish()
        f.page.followFocusedWindow()
        #expect(f.target.picked == nil)
        #expect(f.target.selectionID == F.b.id)
        #expect(f.page.displayID == F.a.id)
        #expect(f.page.ownsSelection(f.document) && f.session.canUndo)
        #expect(f.page.targetContext(f.document) == "Last apply: Studio Display (1) · Current desktop")
        f.page.apply(f.document)
        #expect(f.starts == [F.a.id, F.b.id])
    }

    @Test func namesStayAsReportedAndEqualNamesRemainDistinctChoices() {
        let f = F(); defer { f.close() }
        f.refresh()
        #expect(f.target.name(for: F.a.id) == "Studio Display (1)")
        #expect(f.target.name(for: F.b.id) == "Studio Display (2)")
        f.live[0].fingerprint.name = "Studio Display"
        f.live[1].fingerprint.name = "Studio Display"
        f.refresh()
        #expect(f.target.liveDisplays.count == 3)
        #expect(f.target.name(for: F.a.id) == f.target.name(for: F.b.id))
        f.page.pickDisplay(F.b.id)
        #expect(f.target.selection == .picked(F.b.id))
    }

    @Test func disconnectRefusesAtClickAndReconnectUsesNewID() {
        let f = F(); defer { f.close() }
        f.refresh(); f.page.pickDisplay(F.a.id)
        #expect(f.page.canApply(f.document))
        // No page refresh: the display disappears between rendering and clicking Apply.
        f.live.removeFirst(); f.sync()
        f.page.apply(f.document)
        #expect(f.target.selection == .disconnected("Studio Display (1)"))
        #expect(!f.page.canApply(f.document))
        #expect(f.session.problem == f.target.unavailableReason)
        #expect(f.previewReads == 0 && f.starts.isEmpty)
        #expect(f.system.frameWriteCounts.isEmpty)
        let returned = F.display("a-new-id", name: "Studio Display (1)", uuid: "a")
        f.live.append(returned); f.refresh()
        #expect(f.target.selection == .picked(returned.id))
        #expect(f.page.canApply(f.document))
        f.page.apply(f.document)
        #expect(f.starts == [returned.id])
    }

    @Test func sharedSerialNeverReplacesTheMissingPickedUUID() {
        let f = F(); defer { f.close() }
        f.live[1].fingerprint.serial = f.live[0].fingerprint.serial
        f.refresh(); f.page.pickDisplay(F.a.id)
        f.live.removeFirst(); f.refresh()
        #expect(f.target.selection == .disconnected("Studio Display (1)"))
        #expect(f.target.selectionID == nil)
        #expect(!f.page.canApply(f.document))
    }

    @Test func serialMustRemainUniqueWhenATwinConnectsAfterPicking() {
        let f = F(); defer { f.close() }
        f.live = [F.a]; f.refresh(); f.page.pickDisplay(F.a.id)
        var changedA = F.a; changedA.fingerprint.uuid = "changed-a"
        var twin = F.b; twin.fingerprint.serial = F.a.fingerprint.serial
        f.live = [changedA, twin]; f.refresh()
        #expect(f.target.selection == .disconnected("Studio Display (1)"))
        #expect(!f.page.canApply(f.document))
    }

    @Test func uniqueSerialCanRecoverChangedUUIDButZeroSerialAndNameCannot() {
        let f = F(); defer { f.close() }
        f.refresh(); f.page.pickDisplay(F.a.id)
        f.live[0].id = .init(rawValue: "new-id")
        f.live[0].fingerprint.uuid = "new-uuid"
        f.refresh()
        #expect(f.target.selection == .picked(f.live[0].id))
        f.page.pickDisplay(f.live[0].id)
        f.live[0].fingerprint.serial = 0; f.refresh()
        #expect(f.target.selection == .picked(f.live[0].id)) // UUID still matches.
        f.page.pickDisplay(f.live[0].id)
        f.live[0].fingerprint.uuid = "another-uuid"; f.refresh()
        #expect(f.target.selection == .disconnected("Studio Display (1)"))
    }

    @Test func bindingBypassesPickInBothDirectionsWithoutChangingIt() async throws {
        let f = F(); defer { f.close() }
        f.refresh(); f.page.pickDisplay(F.a.id)
        let reads = f.focusReads
        let applier = try #require(f.model.savedLayoutApplier)
        #expect(try applier.preview(f.document, displayID: F.b.id).displayID == F.b.id)
        #expect(f.target.picked?.uuid == F.a.fingerprint.uuid)
        #expect(f.focusReads == reads)
        f.page.apply(f.document, on: F.b.id)
        #expect(f.starts == [F.b.id])
        #expect(f.target.picked?.uuid == F.a.fingerprint.uuid)
        #expect(f.page.displayID == F.b.id)
        try await f.finish()
        f.page.apply(f.document)
        #expect(f.starts == [F.b.id, F.a.id])
        #expect(f.target.picked?.uuid == F.a.fingerprint.uuid)
        try await f.finish()
        f.live.removeAll { $0.id == F.a.id }; f.refresh()
        f.page.apply(f.document, on: F.b.id)
        #expect(f.starts.last == F.b.id)
        #expect(f.target.selection == .disconnected("Studio Display (1)"))
    }

    @Test func followingPickerNamesTheNextDisplayWhileRecoveryKeepsItsOwner() async throws {
        let f = F(); defer { f.close() }
        f.refresh(); f.page.apply(f.document)
        #expect(!f.page.targetContext(f.document).hasPrefix("Last apply:"))
        try await f.finish()
        f.current = F.b.id; f.refresh()
        #expect(f.target.selection == .following)
        #expect(f.target.selectionID == F.b.id)
        #expect(f.page.displayID == F.a.id)
        #expect(f.page.targetContext(f.document) == "Last apply: Studio Display (1) · Current desktop")
        #expect(f.session.canUndo)
        let reads = f.focusReads
        _ = f.page.body
        #expect(f.focusReads == reads)
        f.page.apply(f.document)
        #expect(f.starts == [F.a.id, F.b.id])
        #expect(f.page.displayID == F.b.id)
    }

    @Test func runningPinBlocksPickingAndFinishedResultKeepsItsOwner() async throws {
        let f = F(); defer { f.close() }
        f.refresh(); f.page.pickDisplay(F.a.id); f.page.apply(f.document)
        let reads = f.focusReads
        f.current = F.b.id; f.refresh()
        _ = f.page.body
        #expect(f.focusReads == reads)
        f.page.pickDisplay(F.b.id)
        #expect(f.target.picked?.uuid == F.a.fingerprint.uuid)
        #expect(f.page.displayID == F.a.id)
        try await f.finish()
        f.page.pickDisplay(F.b.id)
        #expect(f.target.selectionID == F.b.id)
        #expect(f.page.displayID == F.a.id)
        #expect(f.page.ownsSelection(f.document))
        #expect(f.session.canUndo)
        f.page.apply(f.document)
        #expect(f.starts == [F.a.id, F.b.id])
        #expect(f.page.displayID == F.b.id)
    }
}
