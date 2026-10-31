import BetterTileCore
@testable import BetterTileMacOS
@testable import BetterTileApp
import Foundation
import Testing

@Suite(.appTestApplication) @MainActor struct SavedLayoutUndoExpiryTests {
    private func document(mode: LayoutMode = .tabbed) -> SavedLayoutDocument {
        let slots: [SavedLayoutSlot] = [.init(id: "editor", bundleID: "com.example.Editor"), .init(id: "peer", bundleID: "com.example.Peer")]
        return .init(name: "Undo expiry", mode: mode,
            layout: .split(axis: .vertical, ratios: [0.7, 0.3], children: mode == .tabbed ? [.group("left"), .group("right")] : [.slot("editor"), .slot("peer")]),
            slots: slots, groups: mode == .tabbed ? [.init(id: "left", slots: ["editor"], selected: "editor"), .init(id: "right", slots: ["peer"], selected: "peer")] : [])
    }
    private func quiet(_ model: BetterTileModel) -> Bool {
        model.settlementTasks.isEmpty && !model.hasPendingTabbedPlacement
            && (model.windowEventTask == nil || model.windowEventTask?.isCancelled == true)
    }
    private func fixture() -> ApplyHarness {
        let h = ApplyHarness()
        h.addWindow(id: "editor"); h.addWindow("com.example.Peer", id: "peer", pid: 43)
        h.system.focusedID = .init(rawValue: "editor")
        return h
    }

    @Test(arguments: ["mode", "mode and back", "preset", "repair", "added", "removed", "moved"])
    func aChangedSessionRefusesUndoWithoutWriting(change: String) async throws {
        let h = fixture(); defer { h.close() }
        let model = h.model(); defer { model.shutdown() }
        let arrival = WindowArrivalTestClock(model)
        let applier = try #require(model.savedLayoutApplier); applier.observesKeyboard = false; applier.application = h.applier.application
        let editor = SavedLayoutEditor(files: .init(directory: h.directory.appendingPathComponent("Saved Layouts")))
        let value = document(mode: change == "repair" ? .bento : .tabbed)
        editor.newLayout(); #expect(editor.edit { $0 = value }); #expect(editor.save(as: value.name))
        let context = SavedLayoutPositionContext(file: try #require(editor.url).lastPathComponent, store: .init(files: editor.files))
        _ = await applier.apply(value, displayID: h.system.mainDisplay.id, positions: context)
        let run = try #require(applier.lastRun)
        try #require(applier.canUndo(run))
        let session = SavedLayoutApplySession(applier: applier)
        #expect(session.adoptRun(document: value))
        let page = SavedLayoutSettings(editor: editor, model: model, suppliedSession: session,
            targetOverride: .init(displayID: h.system.mainDisplay.id, spaceID: h.space(1)))
        model.handleApplicationActivation()
        let arranged = model.savedLayoutSessions()[h.system.mainDisplay.id]
        var movedPane: UUID?
        switch change {
        case "mode", "mode and back":
            model.setActiveMode(.manual)
            if change == "mode and back" {
                try await waitForSavedLayoutState("The Manual transition did not settle.") { quiet(model) && model.activeLayoutMode == .manual }
                model.setActiveMode(.tabbed)
            }
        case "preset": model.performTabbed(.preset(.rows, grouping: .keepTabGroups))
        case "repair": model.repairCurrentLayout()
        case "added":
            h.addWindow("com.example.New", id: "new", pid: 44)
            h.system.eventHandler?(.init(kind: .created, windowID: .init(rawValue: "new"), processIdentifier: 44))
            arrival.elapsed = 1; model.processPendingWindowEvents(); model.watchdog()
        case "removed":
            let closed = h.system.windows.removeLast()
            h.system.desktopObservation?.windowMembership[closed.id] = nil
            h.system.eventHandler?(.init(kind: .destroyed, windowID: closed.id, processIdentifier: closed.processIdentifier))
            model.processPendingWindowEvents(); model.watchdog()
        default:
            let first = try #require(model.activeTabbedState?.panes.first?.id)
            movedPane = first
            model.performTabbed(.move(.init(rawValue: "peer"), pane: first, index: nil))
        }
        try await waitForSavedLayoutState("The desktop change did not settle.") {
            guard quiet(model) else { return false }
            switch change {
            case "added": return model.activeTabbedState?.windowIDs.contains(.init(rawValue: "new")) == true
            case "removed": return model.activeTabbedState?.windowIDs.contains(.init(rawValue: "peer")) == false
            case "moved": return model.activeTabbedState?.paneID(containing: .init(rawValue: "peer")) == movedPane
            case "mode and back": return model.activeLayoutMode == .tabbed
            default: return model.savedLayoutSessions()[h.system.mainDisplay.id] != arranged
            }
        }
        if change == "added" { try #require(model.activeTabbedState?.windowIDs.contains(.init(rawValue: "new")) == true) }
        if change == "removed" { try #require(model.activeTabbedState?.windowIDs.contains(.init(rawValue: "peer")) == false) }
        let beforeUndo = model.savedLayoutSessions()
        let writes = h.system.frameWriteCounts
        #expect(!applier.canUndo(run) && !session.canUndo && !page.showsUndoApply(value))
        #expect(page.pageDetail(value).contains("Undo Apply is no longer available"))
        await applier.undoLastApply(displayID: run.displayID)
        #expect(h.system.frameWriteCounts == writes)
        #expect(model.savedLayoutSessions() == beforeUndo)
        #expect(applier.message == "The desktop changed after Apply. Undo Apply is no longer available.")
    }

    @Test func unchangedRepeatKeepsTheOriginalUndoRecord() async throws {
        let h = fixture(); defer { h.close() }
        let model = h.model(); defer { model.shutdown() }
        let applier = try #require(model.savedLayoutApplier); applier.observesKeyboard = false; applier.application = h.applier.application
        let value = document(mode: .bento)
        let frames = h.system.windows.map(\.frame)
        let previous = model.savedLayoutSessions()[h.system.mainDisplay.id] ?? .manual
        _ = await applier.apply(value, displayID: h.system.mainDisplay.id)
        let writes = h.system.frameWriteCounts
        _ = await applier.apply(value, displayID: h.system.mainDisplay.id)
        let repeated = try #require(applier.lastRun)
        #expect(repeated.presentation.title.contains("already arranged"))
        #expect(h.system.frameWriteCounts == writes && applier.canUndo(repeated))
        await applier.undoLastApply(displayID: repeated.displayID)
        #expect(h.system.windows.map(\.frame) == frames)
        #expect((model.savedLayoutSessions()[h.system.mainDisplay.id] ?? .manual) == previous)
    }

    @Test func aFrameWritingRepeatReplacesTheOriginalCheckpoint() async throws {
        let h = fixture(); defer { h.close() }
        let model = h.model(); defer { model.shutdown() }
        let applier = try #require(model.savedLayoutApplier); applier.observesKeyboard = false; applier.application = h.applier.application
        let value = SavedLayoutDocument(name: "Frame repeat", mode: .manual,
            slots: [.init(id: "editor", bundleID: "com.example.Editor")],
            windows: [.init(slot: "editor", rect: .init(x: 0, y: 0, width: 1, height: 1))])
        _ = await applier.apply(value, displayID: h.system.mainDisplay.id)
        let first = try #require(applier.lastRun)
        h.system.windows[0].frame.size.width -= 25
        let changedFrames = h.system.windows.map(\.frame)
        let writes = h.system.frameWriteCounts
        _ = await applier.apply(value, displayID: h.system.mainDisplay.id)
        let repeated = try #require(applier.lastRun)
        #expect(h.system.frameWriteCounts != writes && !applier.canUndo(first) && applier.canUndo(repeated))
        await applier.undoLastApply(displayID: repeated.displayID)
        #expect(h.system.windows.map(\.frame) == changedFrames)
    }

    @Test(arguments: [false, true])
    func onlyTouchedSourceDesktopsCanExpireUndo(reusesForeignWindow: Bool) async throws {
        let h = fixture(); defer { h.close() }
        let second = DisplaySnapshot(id: .init(rawValue: "second"), frame: .init(x: 1000, y: 0, width: 1000, height: 800),
            visibleFrame: .init(x: 1000, y: 0, width: 1000, height: 800))
        h.system.availableDisplays.append(second)
        h.system.desktopObservation = .init(currentSpaceByDisplay: [h.system.mainDisplay.id: h.space(1), second.id: h.space(2)],
            knownSpacesByDisplay: [h.system.mainDisplay.id: [h.space(1)], second.id: [h.space(2)]],
            windowMembership: [.init(rawValue: "editor"): [h.space(reusesForeignWindow ? 1 : 2)], .init(rawValue: "peer"): [h.space(1)]])
        if !reusesForeignWindow { h.system.windows[0].displayID = second.id; h.system.windows[0].frame.origin.x += 1000 }
        h.system.onFrameWrite = { id, frame in
            h.system.desktopObservation?.windowMembership[id] = [h.space(frame.midX >= 1000 ? 2 : 1)]
        }
        h.system.focusedID = .init(rawValue: "peer")
        let model = h.model(); defer { model.shutdown() }
        model.handleApplicationActivation(); model.setActiveMode(.manual)
        try await waitForSavedLayoutState("Initial Manual mode did not settle.") { quiet(model) }
        let applier = try #require(model.savedLayoutApplier); applier.observesKeyboard = false; applier.application = h.applier.application
        let value = SavedLayoutDocument(name: "Source", mode: .manual, slots: [.init(id: "editor", bundleID: "com.example.Editor")],
            windows: [.init(slot: "editor", rect: .init(x: 0.1, y: 0.1, width: 0.7, height: 0.7))])
        let before = h.system.windows[0].frame
        _ = await applier.apply(value, displayID: second.id)
        let run = try #require(applier.lastRun)
        try #require(run.result.placed == 1, Comment(rawValue: run.result.issues.map(\.message).joined(separator: " ")))
        try #require(applier.canUndo(run), Comment(rawValue: applier.undoUnavailableReason(run) ?? "No cached Undo reason"))
        model.handleApplicationActivation(); model.setActiveMode(.tabbed)
        try await waitForSavedLayoutState("The source mode change did not settle.") { quiet(model) && model.activeLayoutMode == .tabbed }
        let writes = h.system.frameWriteCounts
        #expect(applier.canUndo(run) == !reusesForeignWindow)
        await applier.undoLastApply(displayID: second.id)
        if reusesForeignWindow {
            #expect(h.system.frameWriteCounts == writes)
            #expect(applier.message == "The desktop changed after Apply. Undo Apply is no longer available.")
        } else {
            #expect(h.system.windows[0].frame == before)
            #expect(h.system.frameWriteCounts[.init(rawValue: "peer")] == writes[.init(rawValue: "peer")])
        }
    }

    @Test func selectingAnotherTabKeepsUndoWithoutRenderingReads() async throws {
        let h = fixture(); defer { h.close() }
        let model = h.model(); defer { model.shutdown() }
        let applier = try #require(model.savedLayoutApplier); applier.observesKeyboard = false; applier.application = h.applier.application
        let frames = h.system.windows.map(\.frame)
        _ = await applier.apply(h.document(mode: .tabbed), displayID: h.system.mainDisplay.id)
        let run = try #require(applier.lastRun)
        model.handleApplicationActivation()
        let selected = try #require(model.activeTabbedState?.selectedWindowIDs.first)
        let other = try #require(h.system.windows.first { $0.id != selected }?.id)
        model.performTabbed(.select(other))
        try await waitForSavedLayoutState("The tab selection did not settle.") {
            quiet(model) && model.activeTabbedState?.selectedWindowIDs.contains(other) == true
        }
        var reads = 0
        let snapshot = applier.snapshot
        applier.snapshot = { reads += 1; return try snapshot() }
        for _ in 0..<20 {
            #expect(applier.canUndo(run))
            #expect(applier.undoUnavailableReason(run) == nil)
        }
        #expect(reads == 0)
        await applier.undoLastApply(displayID: run.displayID)
        #expect(h.system.windows.map(\.frame) == frames)
    }

    @Test func undoRechecksSessionStructureAtCommitTime() async throws {
        let h = fixture(); defer { h.close() }
        _ = await h.applier.apply(document(mode: .bento))
        let writes = h.system.frameWriteCounts
        let commits = h.commits.count
        h.onCommit = { h.sessions[h.system.mainDisplay.id] = .tabbed(.init(preset: .rows)) }
        await h.applier.undoLastApply()
        #expect(h.system.frameWriteCounts == writes && h.commits.count == commits)
        #expect(h.applier.message == "The desktop changed after Apply. Undo Apply is no longer available.")
    }
}
