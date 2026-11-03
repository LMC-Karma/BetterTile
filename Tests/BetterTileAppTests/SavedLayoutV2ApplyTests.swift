import BetterTileCore
@testable import BetterTileMacOS
@testable import BetterTileApp
import Foundation
import Testing

@Suite(.appTestApplication) @MainActor struct SavedLayoutV2ApplyTests {
    @Test(arguments: [false, true])
    func pillDoesNotRepeatSummaryAndKeepsFollowingNotice(follow: Bool) async throws {
        let h = ApplyHarness(); defer { h.close() }
        h.addWindow(); h.addWindow("com.example.Music", id: "extra", pid: 43)
        var feedback: [SavedLayoutFeedback] = []
        h.applier.feedback = { feedback.append($0) }
        var document = h.document(); document.keepForNewWindows = follow
        _ = await h.applier.apply(document)
        let value = try #require(feedback.last)
        #expect(value.title == "Test · 1 arranged · com.example.Music not in layout")
        #expect(value.detail == (follow ? "Save this layout to keep following new windows." : nil))
        #expect(value.offersUndo)
    }

    @Test(arguments: ["undo", "other-layout", "desktop", "other-file"])
    func settledRepeatKeepsEarlierUndoReachableUntilItsOwnerChanges(ending: String) async throws {
        let h = ApplyHarness(); defer { h.close() }
        h.addWindow()
        let before = h.system.windows.map(\.frame)
        let model = h.model(); defer { model.shutdown() }
        let applier = try #require(model.savedLayoutApplier)
        applier.observesKeyboard = false
        let editor = SavedLayoutEditor(files: .init(directory: h.directory.appending(path: "Saved Layouts")))
        editor.newLayout(); #expect(editor.edit { $0 = h.document() }); #expect(editor.save())
        let document = try #require(editor.document)
        let context = SavedLayoutPositionContext(file: try #require(editor.url).lastPathComponent, store: .init(files: editor.files))
        let session = SavedLayoutApplySession(applier: applier)
        let page = SavedLayoutSettings(editor: editor, model: model, suppliedSession: session,
            targetOverride: .init(displayID: h.system.mainDisplay.id, spaceID: h.space(1)))
        _ = await applier.apply(document, displayID: h.system.mainDisplay.id, positions: context)
        let first = try #require(applier.lastRun)
        #expect(applier.canUndo(first))
        _ = await applier.apply(document, displayID: h.system.mainDisplay.id, positions: context)
        let repeated = try #require(applier.lastRun)
        #expect(repeated.presentation.title == document.name + " · already arranged")
        #expect(!repeated.offersUndo)
        #expect(applier.canUndo(repeated)) // This is the panel button's condition.
        #expect(session.adoptRun(document: document))
        #expect(page.showsUndoApply(document))
        #expect(page.pageStatus(document, states: [:]) == document.name + " · already arranged")
        #expect(session.canUndo)
        switch ending {
        case "undo":
            // The panel dispatches Undo with the result display, not the newest global checkpoint.
            await applier.undoLastApply(displayID: repeated.displayID)
            #expect(h.system.windows.map(\.frame) == before)
        case "other-layout":
            var other = document; other.name = "Other"; other.paneGap = 10
            _ = await applier.apply(other, displayID: repeated.displayID)
        case "other-file":
            let other = SavedLayoutPositionContext(file: "another.json", store: context.store)
            _ = await applier.apply(document, displayID: repeated.displayID, positions: other)
        default:
            h.arrive(2)
            model.beginActiveSpaceStabilization()
        }
        #expect(!applier.canUndo(repeated))
        #expect(!page.showsUndoApply(document))
        #expect(!session.canUndo || ending == "other-layout")
    }

    @Test func earlierUndoVisibilityRendersWithoutInventoryOrDesktopReads() async throws {
        let h = ApplyHarness(); defer { h.close() }
        h.addWindow()
        let model = h.model(); defer { model.shutdown() }
        let applier = try #require(model.savedLayoutApplier)
        applier.observesKeyboard = false
        let document = h.document()
        _ = await applier.apply(document)
        _ = await applier.apply(document)
        let session = SavedLayoutApplySession(applier: applier)
        #expect(session.adoptRun(document: document))
        let editor = SavedLayoutEditor(files: .init(directory: h.directory))
        editor.newLayout(); #expect(editor.edit { $0 = document })
        let page = SavedLayoutSettings(editor: editor, model: model, suppliedSession: session,
            targetOverride: .init(displayID: h.system.mainDisplay.id, spaceID: h.space(1)))
        let panel = SavedLayoutPanelRun(model: model)
        let run = try #require(applier.lastRun)
        var reads = 0
        let destination = applier.destinationSnapshot
        applier.destinationSnapshot = { reads += 1; return try destination() }
        let inventory = applier.snapshot
        applier.snapshot = { reads += 1; return try inventory() }
        let observationReads = h.system.nativeDesktopRefreshCount
        for _ in 0..<20 {
            _ = panel.body; _ = page.body
            #expect(applier.canUndo(run))
            #expect(session.canUndo)
            #expect(page.showsUndoApply(document))
        }
        #expect(reads == 0)
        #expect(h.system.nativeDesktopRefreshCount == observationReads)
    }

    private func ordered(_ h: ApplyHarness) {
        h.system.stack = h.system.windows.reversed().map { .init(windowID: $0.id, frame: $0.frame) }
    }

    /// The harness commits planned frames through WindowCoordinator and writes the target session.
    /// A settled repeat must not enter that commit seam, write frames, raise, or replace Undo.
    private func repeatAndUndo(_ h: ApplyHarness, _ document: SavedLayoutDocument,
                               before: [BTRect], previous: SavedLayoutSession = .manual,
                               choices: [String: WindowID] = [:]) async throws {
        let writes = h.system.frameWriteCounts
        let raises = h.system.raiseRequests.count
        let commits = h.commits.count
        let session = h.sessions[h.system.mainDisplay.id]
        var feedback: [SavedLayoutFeedback] = []
        h.applier.feedback = { feedback.append($0) }
        _ = await h.applier.apply(document, choices: choices)
        #expect(h.applier.lastPlan?.isEmpty == true)
        #expect(h.system.frameWriteCounts == writes)
        #expect(h.system.raiseRequests.count == raises)
        #expect(h.commits.count == commits)
        #expect(h.sessions[h.system.mainDisplay.id] == session)
        #expect(h.applier.lastRun?.presentation.pillDetail == "Already arranged.")
        #expect(h.applier.lastRun?.offersUndo == false)
        #expect(h.applier.hasUndo)
        #expect(feedback.last?.title == document.name + " · already arranged")
        #expect(feedback.last?.offersUndo == false && feedback.last?.detail == nil)
        await h.applier.undoLastApply()
        #expect(h.system.windows.map(\.frame) == before)
        #expect(h.sessions[h.system.mainDisplay.id] == previous)
        #expect(h.system.newWindowRequests.isEmpty && h.system.applicationActivations.isEmpty)
    }

    @Test func shapeOnlyUsesStackAndLeavesVacancies() async throws {
        let h = ApplyHarness(); defer { h.close() }
        h.addWindow("com.example.Back", id: "a-back")
        h.addWindow("com.example.Front", id: "z-front", pid: 43)
        ordered(h)
        h.system.stack?.insert(.init(windowID: nil, frame: .init(x: 0, y: 0, width: 20, height: 20)), at: 0)
        #expect(h.snapshot().frontRanks[h.system.windows[1].id] == 0)
        let before = h.system.windows.map(\.frame)
        let document = SavedLayoutDocument(name: "Shape", mode: .bento,
            layout: .split(axis: .vertical, ratios: [0.6, 0.2, 0.2], children: [.slot("big"), .slot("small"), .slot("empty")]),
            slots: [.init(id: "big"), .init(id: "small"), .init(id: "empty")], paneGap: 10)
        _ = await h.applier.apply(document)
        #expect(h.applier.lastPlan?.assignments["big"]?.rawValue == "z-front")
        // 1000 - 2 × 10 = 980; first pane takes 60%, with the second after one gap.
        #expect(h.system.windows[1].frame == BTRect(x: 0, y: 0, width: 588, height: 800))
        #expect(h.applier.lastPlan?.emptySlots.count == 1)
        #expect(h.applier.lastRun?.planPresentation?.lines.contains { $0.hasSuffix("— empty") } == true)
        #expect(h.applier.lastRun?.planPresentation?.lines.contains { $0.contains("frontmost window") } == true)
        #expect(h.applier.lastRun?.planPresentation?.lines.contains { $0.contains("nearest position") } == true)
        try await repeatAndUndo(h, document, before: before)
    }

    @Test(arguments: [false, true]) func extrasAndUndo(tabbed: Bool) async throws {
        let h = ApplyHarness(); defer { h.close() }
        h.addWindow("com.example.Editor", id: "chosen")
        h.addWindow("com.example.Music", id: "extra", pid: 43)
        ordered(h)
        let before = h.system.windows.map(\.frame)
        let previous: SavedLayoutSession
        if tabbed {
            previous = .tabbed(try #require(TabbedLayoutState(adopting: .init(root: .leaf(h.system.windows[0].id)))))
            h.sessions[h.system.mainDisplay.id] = previous
        } else { previous = .manual }
        let document = h.document(mode: tabbed ? .tabbed : .bento)
        _ = await h.applier.apply(document)
        if tabbed {
            guard case let .tabbed(state) = h.sessions[h.system.mainDisplay.id] else { Issue.record("No Tabbed target"); return }
            #expect(state.selectedWindowIDs == [h.system.windows[1].id])
            #expect(h.applier.lastPlan?.extras[h.system.windows[1].id] == .tab(groupID: "group", reason: .nearestPane))
        } else {
            #expect(h.applier.lastPlan?.extras[h.system.windows[1].id] == .floating)
            #expect(h.system.windows[1].frame == before[1])
            #expect(h.applier.lastRun?.presentation.title == "Test · 1 arranged · com.example.Music not in layout")
            #expect(h.applier.lastRun?.planPresentation?.lines.last == "com.example.Music — floating, no pane left")
        }
        try await repeatAndUndo(h, document, before: before, previous: previous)
    }

    @Test func addedPanesRestoreThePreviousAdaptiveTree() async throws {
        let h = ApplyHarness(); defer { h.close() }
        h.addWindow(id: "preferred")
        h.addWindow("com.example.Extra", id: "extra", pid: 43)
        ordered(h)
        let before = h.system.windows.map(\.frame)
        let previous = SavedLayoutSession.bento(.init(root: .leaf(h.system.windows[0].id)))
        h.sessions[h.system.mainDisplay.id] = previous
        var document = h.document(); document.extraWindows = .addAsPanes
        _ = await h.applier.apply(document)
        #expect(h.applier.lastPlan?.extras[h.system.windows[1].id] == .addedAsPane)
        #expect(h.applier.lastRun?.presentation.title == "Test · 2 arranged")
        try await repeatAndUndo(h, document, before: before, previous: previous)
    }

    @Test func manualExtrasStayAndSeveralFloatingExtrasHaveCountWording() async throws {
        for manual in [false, true] {
            let h = ApplyHarness(); defer { h.close() }
            h.addWindow(id: "preferred")
            h.addWindow("com.example.Extra", id: "extra1", pid: 43)
            h.addWindow("com.example.Other", id: "extra2", pid: 44)
            ordered(h)
            let before = h.system.windows.map(\.frame)
            let document = manual ? SavedLayoutDocument(name: "Manual", mode: .manual,
                slots: [.init(id: "slot", prefer: [.app("com.example.Editor")])],
                windows: [.init(slot: "slot", rect: .init(x: 0, y: 0, width: 1, height: 1))]) : h.document()
            _ = await h.applier.apply(document)
            #expect(h.system.windows.dropFirst().map(\.frame) == Array(before.dropFirst()))
            #expect(h.applier.lastPlan?.extras[h.system.windows[1].id] == (manual ? .untouched : .floating))
            #expect(h.applier.lastRun?.presentation.title == (manual ? "Manual · 1 arranged" : "Test · 1 arranged · 2 windows not in layout"))
            try await repeatAndUndo(h, document, before: before)
        }
    }

    @Test func groupPreferencePreviewAndApplyResolveNameOnlyEntries() async throws {
        let h = ApplyHarness(); defer { h.close() }
        h.addWindow("com.example.Pages", id: "pages")
        h.addWindow("com.example.Other", id: "other", pid: 43)
        ordered(h)
        let before = h.system.windows.map(\.frame)
        let groups = AppGroupsStore(directory: h.directory, catalog: {
            [.init(bundleIdentifier: "com.example.Pages", name: "Pages", url: URL(fileURLWithPath: "/fixture/Pages.app"))]
        }, defaultBrowserURL: { nil })
        try FileManager.default.createDirectory(at: h.directory, withIntermediateDirectories: true)
        try AppGroupsDocument(groups: [.init(name: "Documents", apps: [.init(bundleID: "com.example.Preview"), .init(name: "Pages")])]).encode().write(to: groups.fileURL)
        await groups.load()
        h.applier.appGroupsStore = groups
        h.applier.runningApplicationName = { $0 == 43 ? "Other" : nil }
        h.applier.application = { id in id == "com.example.Pages" ? .init(bundleIdentifier: id, name: "Pages", url: URL(fileURLWithPath: "/fixture/Pages.app")) : nil }
        let document = SavedLayoutDocument(name: "Group", mode: .bento, layout: .slot("slot"), slots: [.init(id: "slot", prefer: [.group("Documents")])])
        let preview = try h.applier.preview(document)
        guard case let .matched(window) = preview.rows.first?.status else { Issue.record("Group preview did not match"); return }
        #expect(window.id == h.system.windows[0].id)
        #expect(preview.rows[0].appName == "Pages")
        _ = await h.applier.apply(document)
        #expect(h.applier.lastPlan?.assignments["slot"] == window.id)
        #expect(h.applier.lastPlan?.slotReasons["slot"] == .preferred(rank: 1))
        #expect(h.applier.lastRun?.planPresentation?.lines == ["Pane — Pages (2nd choice; an app that is not installed)", "Other — floating, no pane left"])
        try await repeatAndUndo(h, document, before: before)
    }

    @Test func explicitChoiceAcceptsAnyEligibleApp() async throws {
        let h = ApplyHarness(); defer { h.close() }
        h.addWindow("com.example.Unlisted", id: "chosen")
        ordered(h)
        let before = h.system.windows.map(\.frame)
        let document = h.document("com.example.NotRunning")
        let choices = ["slot": h.system.windows[0].id]
        _ = await h.applier.apply(document, choices: choices)
        #expect(h.applier.lastPlan?.slotReasons["slot"] == .chosen)
        #expect(h.applier.lastRun?.planPresentation?.lines == ["Pane — com.example.Unlisted (chosen window)"])
        try await repeatAndUndo(h, document, before: before, choices: choices)
    }
}

extension SavedLayoutV2ApplyTests {
    @Test(arguments: [false, true]) func modelLoadsGroupsBeforeImmediateApplyAndUsesNonzeroOrigin(nilStack: Bool) async throws {
        let h = ApplyHarness(); defer { h.close() }
        h.addWindow("com.example.Other", id: "a-other")
        h.addWindow("com.example.Pages", id: "z-pages", pid: 43)
        let area = BTRect(x: -1200, y: 40, width: 1200, height: 900)
        h.system.availableDisplays = [.init(id: h.system.mainDisplay.id, frame: area, visibleFrame: area, isMain: true)]
        for index in h.system.windows.indices { h.system.windows[index].frame.origin.x -= 1000 }
        let before = h.system.windows.map(\.frame)
        let groups = AppGroupsStore(directory: h.directory, catalog: {
            await Task.yield()
            return [.init(bundleIdentifier: "com.example.Pages", name: "Pages", url: URL(fileURLWithPath: "/fixture/Pages.app"))]
        }, defaultBrowserURL: { nil })
        try FileManager.default.createDirectory(at: h.directory, withIntermediateDirectories: true)
        try AppGroupsDocument(groups: [.init(name: "Documents", apps: [.init(name: "Pages")])]).encode().write(to: groups.fileURL)
        let model = makeOffscreenModel(store: .init(fileURL: h.directory.appendingPathComponent("configuration.json")),
            system: h.system, startRuntime: false, appGroupsStore: groups)
        defer { model.shutdown() }
        model.primaryButtonIsPressed = { false }
        let applier = try #require(model.savedLayoutApplier)
        applier.observesKeyboard = false
        applier.application = { id in id == "com.example.Pages" ? .init(bundleIdentifier: id, name: "Pages", url: URL(fileURLWithPath: "/fixture/Pages.app")) : nil }
        ordered(h)
        if nilStack { h.system.stack = nil }
        let document = SavedLayoutDocument(name: "Immediate", mode: .bento,
            layout: .split(axis: .vertical, ratios: [0.6, 0.4], children: [.slot("group"), .slot("any")]),
            slots: [.init(id: "group", prefer: [.group("Documents")]), .init(id: "any")], paneGap: 10)
        #expect(try applier.preview(document).plan == nil) // no plan with unresolved startup inputs
        _ = await applier.apply(document)
        #expect(applier.lastPlan?.assignments["group"] == h.system.windows[1].id)
        // Independent work-area arithmetic: (1200 - 10) × 0.6 = 714, origin (-1200, 40).
        #expect(h.system.windows[1].frame == BTRect(x: -1200, y: 40, width: 714, height: 900))
        #expect(h.system.windows[0].frame == BTRect(x: -476, y: 40, width: 476, height: 900))
        #expect(try applier.preview(document).rows.first?.appName == "Pages")
        let writes = h.system.frameWriteCounts, raises = h.system.raiseRequests.count
        let session = model.savedLayoutSessions()
        _ = await applier.apply(document)
        #expect(applier.lastPlan?.isEmpty == true && h.system.frameWriteCounts == writes)
        #expect(h.system.raiseRequests.count == raises && model.savedLayoutSessions() == session)
        #expect(applier.lastRun?.presentation.title == "Immediate · already arranged")
        #expect(applier.lastRun?.presentation.pillDetail == "Already arranged." && applier.lastRun?.offersUndo == false)
        await applier.undoLastApply()
        #expect(h.system.windows.map(\.frame) == before)
        #expect(model.activeMode(for: h.system.mainDisplay.id) == .manual)
        #expect(h.system.newWindowRequests.isEmpty)
    }

    @Test(arguments: [false, true]) func nilStackUsesStableIDsAndChangesOfOrderDoNotInvalidateCommit(nilStack: Bool) async throws {
        let h = ApplyHarness(); defer { h.close() }
        h.addWindow("com.example.Back", id: "a-back")
        h.addWindow("com.example.Front", id: "z-front", pid: 43)
        ordered(h)
        if nilStack { h.system.stack = nil }
        let before = h.system.windows.map(\.frame)
        let document = SavedLayoutDocument(name: "Order", mode: .bento,
            layout: .split(axis: .vertical, ratios: [0.7, 0.3], children: [.slot("large"), .slot("small")]),
            slots: [.init(id: "large"), .init(id: "small")])
        h.onCommit = { h.system.stack?.reverse() }
        _ = await h.applier.apply(document)
        #expect(h.applier.lastPlan?.assignments["large"]?.rawValue == (nilStack ? "a-back" : "z-front"))
        #expect(h.commits.count == 1)
        try await repeatAndUndo(h, document, before: before)
    }

    @Test func foreignGroupPreferenceForManualApply() async throws {
        let h = ApplyHarness(); defer { h.close() }
        let other = DisplaySnapshot(id: .init(rawValue: "other"), frame: .init(x: 1000, y: 0, width: 1000, height: 800),
            visibleFrame: .init(x: 1000, y: 0, width: 1000, height: 800), isMain: false)
        h.system.availableDisplays.append(other)
        h.usesAllDisplays = true
        h.addWindow("com.example.Pages", id: "preferred")
        h.addWindow("com.example.Unlisted", id: "unlisted", pid: 43)
        h.system.desktopObservation?.currentSpaceByDisplay[other.id] = h.space(2)
        for index in h.system.windows.indices {
            h.system.windows[index].displayID = other.id
            h.system.windows[index].frame.origin.x += 1000
            h.system.desktopObservation?.windowMembership[h.system.windows[index].id] = [h.space(2)]
        }
        ordered(h)
        let before = h.system.windows.map(\.frame)
        let groups = AppGroupsStore(directory: h.directory, catalog: {
            [.init(bundleIdentifier: "COM.EXAMPLE.PAGES", name: "Pages", url: URL(fileURLWithPath: "/fixture/Pages.app"))]
        }, defaultBrowserURL: { nil })
        try FileManager.default.createDirectory(at: h.directory, withIntermediateDirectories: true)
        try AppGroupsDocument(groups: [.init(name: "Documents", apps: [.init(name: "Pages")])]).encode().write(to: groups.fileURL)
        await groups.load(); h.applier.appGroupsStore = groups
        h.applier.displayName = { id, _ in id == other.id ? "Studio Display" : "Main Display" }
        let document = SavedLayoutDocument(name: "Foreign", mode: .bento,
            layout: .split(axis: .vertical, ratios: [0.5, 0.5], children: [.slot("group"), .slot("any")]),
            slots: [.init(id: "group", prefer: [.group("Documents")]), .init(id: "any")])
        h.system.onFrameWrite = { id, frame in
            h.system.desktopObservation?.windowMembership[id] = [frame.midX >= 1000 ? h.space(2) : h.space(1)]
        }
        var feedback: [SavedLayoutFeedback] = []
        h.applier.feedback = { feedback.append($0) }
        _ = await h.applier.apply(document, choices: [:])
        #expect(h.applier.lastPlan?.assignments.count == 1)
        #expect(h.system.windows[1].frame == before[1] && h.system.windows[1].displayID == other.id)
        #expect(h.system.windows[0].frame == BTRect(x: 0, y: 0, width: 500, height: 800))
        #expect(h.applier.lastRun?.planPresentation?.lines.first?.contains("moved from Studio Display") == true)
        try await repeatAndUndo(h, document, before: before)
        #expect(h.system.windows.allSatisfy { $0.displayID == other.id })
    }

}

extension SavedLayoutV2ApplyTests {
    @Test func userEmptyApplyInstallsShapeAndUndoesThePreviousMode() async throws {
        let h = ApplyHarness(); defer { h.close() }
        let previous = SavedLayoutSession.tabbed(.init(preset: .columns))
        h.sessions[h.system.mainDisplay.id] = previous
        let document = SavedLayoutDocument(name: "Empty", mode: .bento,
            layout: .split(axis: .vertical, ratios: [0.6, 0.4], children: [.slot("left"), .slot("right")]),
            slots: [.init(id: "left", prefer: [.app("com.example.NotRunning")]), .init(id: "right")])
        _ = await h.applier.apply(document)
        #expect(h.commits.count == 1 && h.applier.lastPlan?.emptySlots.count == 2)
        #expect(h.applier.lastRun?.presentation.title == "Empty · no windows to arrange")
        #expect(h.applier.lastRun?.planPresentation?.lines == ["Left — empty", "Right — empty"])
        #expect(h.applier.slotStatuses.values.allSatisfy { $0 == .empty })
        try await repeatAndUndo(h, document, before: [], previous: previous)
    }


}

extension SavedLayoutV2ApplyTests {
    @Test(arguments: ["same app", "preferred app", "existing tab-mates"])
    func extraTabDetailsExplainEveryPreferenceRoute(route: String) async throws {
        let h = ApplyHarness(); defer { h.close() }
        let editor = "com.example.Editor"
        h.addWindow(editor, id: "assigned")
        h.addWindow(route == "same app" ? editor : "com.example.Music", id: "extra", pid: 43)
        ordered(h)
        let before = h.system.windows.map(\.frame)
        var document = h.document(mode: .tabbed)
        if route == "preferred app" { document.slots[0].prefer.append(.app("com.example.Music")) }
        let previous: SavedLayoutSession
        if route == "existing tab-mates" {
            var state = TabbedLayoutState()
            state.reconcile(windowIDs: h.system.windows.map(\.id), removed: [],
                fittingIn: h.system.mainDisplay.visibleFrame, windows: h.system.windows)
            previous = .tabbed(state)
            h.sessions[h.system.mainDisplay.id] = previous
        } else { previous = .manual }
        _ = await h.applier.apply(document)
        let expected: SavedLayoutTabReason = route == "same app" ? .sameApp : route == "preferred app" ? .listedApp : .tabMates
        #expect(h.applier.lastPlan?.extras[h.system.windows[1].id] == .tab(groupID: "group", reason: expected))
        #expect(h.applier.lastRun?.planPresentation?.lines.last == "\(h.system.windows[1].bundleIdentifier!) — tab in pane, \(route)")
        #expect(h.applier.lastRun?.planPresentation?.lines.first == "Pane — com.example.Editor (1st choice)")
        // Tabbed reserves the known 34-point strip: 800 - 34 = 766 points of content.
        #expect(h.system.windows.allSatisfy { $0.frame == BTRect(x: 0, y: 34, width: 1000, height: 766) })
        try await repeatAndUndo(h, document, before: before, previous: previous)
    }
}

extension SavedLayoutV2ApplyTests {
    @Test func modelRaisesTheFrontmostExtraTabAndRepeatKeepsItsUndo() async throws {
        let h = ApplyHarness(); defer { h.close() }
        h.addWindow("com.example.Editor", id: "assigned")
        h.addWindow("com.example.Music", id: "frontmost-extra", pid: 43)
        ordered(h)
        let before = h.system.windows.map(\.frame)
        let model = h.model(); defer { model.shutdown() }
        let applier = try #require(model.savedLayoutApplier)
        applier.observesKeyboard = false
        let document = h.document(mode: .tabbed)
        _ = await applier.apply(document)
        let selected = h.system.windows[1].id
        guard case let .tabbed(state) = model.savedLayoutSessions()[h.system.mainDisplay.id] else { Issue.record("No Tabbed session"); return }
        #expect(state.selectedWindowIDs == [selected])
        #expect(h.system.raiseRequests.contains { $0.0 == selected })
        #expect(h.system.windows.allSatisfy { $0.frame == BTRect(x: 0, y: 34, width: 1000, height: 766) })
        let writes = h.system.frameWriteCounts, raises = h.system.raiseRequests.count
        let sessions = model.savedLayoutSessions()
        _ = await applier.apply(document)
        #expect(applier.lastPlan?.isEmpty == true && h.system.frameWriteCounts == writes)
        #expect(h.system.raiseRequests.count == raises && model.savedLayoutSessions() == sessions)
        #expect(applier.lastRun?.presentation.pillDetail == "Already arranged." && applier.lastRun?.offersUndo == false)
        await applier.undoLastApply()
        #expect(h.system.windows.map(\.frame) == before)
        #expect(model.activeMode(for: h.system.mainDisplay.id) == .manual)
        #expect(h.system.newWindowRequests.isEmpty)
    }
}

extension SavedLayoutV2ApplyTests {
    @Test func inFlightCommitRefusesSecondApplyAndResetAndSilentlyRefusesUndo() async throws {
        let h = ApplyHarness(); defer { h.close() }
        h.addWindow(); ordered(h)
        let before = h.system.windows.map(\.frame)
        let document = h.document()
        let session = SavedLayoutApplySession(applier: h.applier)
        let commit = h.applier.commit
        var release: CheckedContinuation<Void, Never>?
        defer { release?.resume(); release = nil }
        h.applier.commit = { plan, desktop, state, valid in
            await withCheckedContinuation { release = $0 }
            return await commit(plan, desktop, state, valid)
        }
        session.apply(document: document)
        try await waitForSavedLayoutState("Apply did not reach its commit gate.") { release != nil }
        #expect(h.applier.isRunning && !h.applier.canUndo)
        let message = h.applier.message
        await h.applier.undoLastApply()
        #expect(h.applier.message == message && h.applier.isRunning)
        #expect(h.commits.isEmpty && h.system.frameWriteCounts.isEmpty)
        let refused = await h.applier.apply(document)
        #expect(refused.placed == 0)
        #expect(h.applier.message == SavedLayoutApplier.applyingBusy)
        session.reset()
        #expect(session.problem == SavedLayoutApplier.applyingBusy)
        #expect(session.preview?.document == document)
        release?.resume(); release = nil
        try await waitForSavedLayoutState("Apply did not finish after its commit gate opened.") { !h.applier.isBusy && session.run != nil }
        h.applier.commit = commit
        #expect(h.commits.count == 1)
        try await repeatAndUndo(h, document, before: before)
    }
}

extension SavedLayoutV2ApplyTests {
    @Test func paneNamesFollowColumnAndRowOrder() async throws {
        let cases: [(SplitAxis, [Double], [String])] = [
        (.vertical, [0.7, 0.3], ["Left", "Right"]),
        (.vertical, [0.3, 0.7], ["Left", "Right"]),
        (.horizontal, [0.7, 0.3], ["Top", "Bottom"]),
        (.horizontal, [0.3, 0.7], ["Top", "Bottom"]),
        (.vertical, [1.0 / 3, 1.0 / 3, 1.0 / 3], ["Left", "Middle", "Right"]),
        (.horizontal, [1.0 / 3, 1.0 / 3, 1.0 / 3], ["Top", "Middle", "Bottom"]),
        (.vertical, [0.25, 0.25, 0.25, 0.25], ["Column 1", "Column 2", "Column 3", "Column 4"]),
        (.horizontal, [0.25, 0.25, 0.25, 0.25], ["Row 1", "Row 2", "Row 3", "Row 4"])
        ]
        for (axis, ratios, expected) in cases {
            let tree = SavedLayoutNode.split(axis: axis, ratios: ratios, children: ratios.indices.map { .slot("slot\($0)") })
            try await checkPaneNames(tree, expected: expected)
        }
    }

    @Test(arguments: ["grid", "uneven grid", "L"]) func gridAndLShapePaneNames(shape: String) async throws {
        let useLShape = shape == "L"
        if shape == "uneven grid" {
            let tree = SavedLayoutNode.split(axis: .horizontal, ratios: [0.5, 0.5], children: [
                .split(axis: .vertical, ratios: [0.5, 0.5], children: [.slot("slot0"), .slot("slot1")]),
                .split(axis: .vertical, ratios: [0.6, 0.4], children: [.slot("slot2"), .slot("slot3")])])
            try await checkPaneNames(tree, expected: ["Top left", "Top right", "Bottom left", "Bottom right"])
            return
        }
        let right = SavedLayoutNode.split(axis: .horizontal, ratios: [0.7, 0.3], children: [.slot("slot1"), .slot("slot2")])
        let left = useLShape ? SavedLayoutNode.slot("slot0") : .split(axis: .horizontal, ratios: [0.7, 0.3], children: [.slot("slot0"), .slot("slot3")])
        let tree = SavedLayoutNode.split(axis: .vertical, ratios: [0.7, 0.3], children: [left, right])
        try await checkPaneNames(tree, expected: useLShape ? ["Left", "Top right", "Bottom right"]
            : ["Top left", "Bottom left", "Top right", "Bottom right"])
    }

    private func checkPaneNames(_ tree: SavedLayoutNode, expected: [String]) async throws {
        let h = ApplyHarness(); defer { h.close() }
        for index in expected.indices { h.addWindow("com.example.App\(index)", id: "window\(index)", pid: Int32(40 + index)) }
        ordered(h)
        let before = h.system.windows.map(\.frame)
        let document = SavedLayoutDocument(name: "Names", mode: .bento, layout: tree,
            slots: expected.indices.map { .init(id: "slot\($0)", prefer: [.app("com.example.App\($0)")]) })
        _ = await h.applier.apply(document)
        let labels = h.applier.lastRun?.planPresentation?.lines.map { String($0.split(separator: "—")[0]).trimmingCharacters(in: .whitespaces) }
        #expect(labels == expected)
        #expect(Set(labels ?? []).count == expected.count)
        try await repeatAndUndo(h, document, before: before)
    }

    @Test(arguments: [false, true]) func runningWindowNamesSurviveAnUnavailableCatalogEntry(tabbed: Bool) async throws {
        let h = ApplyHarness(); defer { h.close() }
        h.addWindow("com.example.Editor", id: "editor", pid: 42)
        h.addWindow("com.example.Music", id: "music", pid: 43)
        ordered(h)
        let before = h.system.windows.map(\.frame)
        h.applier.application = { _ in nil }
        h.applier.runningApplicationName = { pid in pid == 42 ? "Editor" : pid == 43 ? "Music" : nil }
        let document = h.document(mode: tabbed ? .tabbed : .bento)
        #expect(try h.applier.preview(document).rows.first?.appName == "Editor")
        _ = await h.applier.apply(document)
        let presentation = try #require(h.applier.lastRun?.planPresentation)
        #expect(presentation.lines.first == "Pane — Editor (1st choice)")
        #expect(presentation.lines.last == (tabbed ? "Music — tab in pane, nearest pane" : "Music — floating, no pane left"))
        #expect(!presentation.lines.joined().contains("not installed"))
        if !tabbed { #expect(presentation.title == "Test · 1 arranged · Music not in layout") }
        try await repeatAndUndo(h, document, before: before)
    }



    @Test func unavailablePreferredAppNeverExposesItsBundleIDInPreviewOrDetails() async throws {
        let h = ApplyHarness(); defer { h.close() }
        h.addWindow("com.example.Pages", id: "pages")
        ordered(h)
        let before = h.system.windows.map(\.frame)
        let missing = "com.example.NotInstalled"
        h.applier.application = { id in id == missing ? nil : .init(bundleIdentifier: id, name: "Pages", url: URL(fileURLWithPath: "/fixture/Pages.app")) }
        let document = SavedLayoutDocument(name: "Preferences", mode: .bento, layout: .slot("slot"),
            slots: [.init(id: "slot", prefer: [.app(missing), .app("com.example.Pages")])])
        _ = await h.applier.apply(document)
        #expect(h.applier.lastRun?.planPresentation?.lines == ["Pane — Pages (2nd choice; an app that is not installed)"])
        #expect(h.applier.lastRun?.presentation.title.contains(missing) == false)
        try await repeatAndUndo(h, document, before: before)
        // The preview's empty pane also names the unavailable preference without an identifier.
        h.system.windows = []
        let preview = try h.applier.preview(document)
        #expect(preview.rows[0].appName == "an app that is not installed")
        #expect(!preview.rows[0].appName.contains(missing))
    }

    @Test func sixSlotTwelveWindowPlannerMedianOfTwentyRuns() async throws {
        var samples: [Double] = []
        for _ in 0..<20 {
            let h = ApplyHarness(); defer { h.close() }
            for index in 0..<12 { h.addWindow("com.example.App\(index % 6)", id: "window\(index)", pid: Int32(40 + index)) }
            ordered(h)
            h.applier.uptime = { ProcessInfo.processInfo.systemUptime } // real-time: measures actual planner duration for the benchmark report
            h.applier.timing = { _, _, phase, seconds in if phase == .plan { samples.append(seconds * 1000) } }
            let document = SavedLayoutDocument(name: "Timing", mode: .bento,
                layout: .split(axis: .vertical, ratios: Array(repeating: 1.0 / 6, count: 6), children: (0..<6).map { .slot("slot\($0)") }),
                slots: (0..<6).map { .init(id: "slot\($0)", prefer: [.app("com.example.App\($0)")]) })
            let before = h.system.windows.map(\.frame)
            _ = await h.applier.apply(document)
            h.applier.timing = { _, _, _, _ in }
            #expect(h.applier.lastPlan?.assignments.count == 6 && h.applier.lastPlan?.extras.count == 6)
            try await repeatAndUndo(h, document, before: before)
        }
        #expect(samples.count == 20)
        let sorted = samples.sorted()
        print("SavedLayoutPlanner_6x12 median_ms=\((sorted[9] + sorted[10]) / 2) runs=20 mode=Debug fakeWindowSystem")
    }
}

extension SavedLayoutV2ApplyTests {
    private func tabbedPair(_ preferences: [AppPreference] = []) -> SavedLayoutDocument {
        .init(name: "Two panes", mode: .tabbed,
            layout: .split(axis: .vertical, ratios: [0.7, 0.3], children: [.group("left"), .group("right")]),
            slots: [.init(id: "one", prefer: preferences), .init(id: "two", prefer: preferences)],
            groups: [.init(id: "left", slots: ["one"], selected: "one"), .init(id: "right", slots: ["two"], selected: "two")])
    }

    @Test func tabbedSettledRepeatWithRealRaiseOrderForManualApply() async throws {
        let h = ApplyHarness(); defer { h.close() }
        h.addWindow("com.example.Editor", id: "editor")
        h.addWindow("com.example.Music", id: "music", pid: 43)
        h.system.stack = h.system.windows.map { .init(windowID: $0.id, frame: $0.frame) }
        h.system.updatesStackOnRaise = true
        let model = h.model(); defer { model.shutdown() }
        let applier = try #require(model.savedLayoutApplier)
        applier.observesKeyboard = false
        let before = h.system.windows.map(\.frame)
        let document = tabbedPair([.app("com.example.NotRunning")])
        let first = await applier.apply(document)
        try #require(first.issues.isEmpty)
        #expect(applier.lastPlan?.assignments == ["one": h.system.windows[0].id, "two": h.system.windows[1].id])
        // 70/30 of 1000; the 34-point Tabbed strip leaves 766 points of content.
        #expect(h.system.windows.map(\.frame) == [.init(x: 0, y: 34, width: 700, height: 766), .init(x: 700, y: 34, width: 300, height: 766)])
        #expect(h.system.stack?.first?.windowID == h.system.windows[1].id)
        let assignments = applier.lastPlan?.assignments, writes = h.system.frameWriteCounts
        let raises = h.system.raiseRequests.count, sessions = model.savedLayoutSessions()
        var feedback: [SavedLayoutFeedback] = []
        applier.feedback = { feedback.append($0) }
        _ = await applier.apply(document)
        #expect(applier.lastPlan?.isEmpty == true && applier.lastPlan?.assignments == assignments)
        #expect(h.system.frameWriteCounts == writes && h.system.raiseRequests.count == raises)
        #expect(model.savedLayoutSessions() == sessions)
        #expect(applier.lastRun?.offersUndo == false && applier.hasUndo)
        #expect(feedback.last?.title == "Two panes · already arranged" && feedback.last?.offersUndo == false)
        await applier.undoLastApply()
        #expect(h.system.windows.map(\.frame) == before)
        #expect(model.activeMode(for: h.system.mainDisplay.id) == .manual)
    }

    @Test func newlyEligiblePreferenceReplacesARememberedFallbackForManualApply() async throws {
        let h = ApplyHarness(); defer { h.close() }
        h.addWindow("com.example.Editor", id: "editor")
        h.addWindow("com.example.Music", id: "music", pid: 43)
        h.system.stack = h.system.windows.map { .init(windowID: $0.id, frame: $0.frame) }
        h.system.updatesStackOnRaise = true
        let model = h.model(); defer { model.shutdown() }
        let applier = try #require(model.savedLayoutApplier)
        applier.observesKeyboard = false
        let document = tabbedPair([.app("com.example.Pages")])
        _ = await applier.apply(document)
        h.addWindow("com.example.Pages", id: "pages", pid: 44)
        h.system.stack?.append(.init(windowID: h.system.windows[2].id, frame: h.system.windows[2].frame))
        let before = h.system.windows.map(\.frame), previous = model.savedLayoutSessions()
        _ = await applier.apply(document)
        #expect(applier.lastPlan?.assignments["one"] == h.system.windows[2].id)
        let writes = h.system.frameWriteCounts, raises = h.system.raiseRequests.count
        let settled = model.savedLayoutSessions()
        _ = await applier.apply(document)
        #expect(applier.lastPlan?.isEmpty == true && model.savedLayoutSessions() == settled)
        #expect(h.system.frameWriteCounts == writes && h.system.raiseRequests.count == raises)
        await applier.undoLastApply()
        #expect(h.system.windows.map(\.frame) == before)
        #expect(model.savedLayoutSessions() == addingOutsideFloat(h.system.windows[2].id, to: previous, on: h.system.mainDisplay.id))
    }

    private func addingOutsideFloat(_ id: WindowID, to sessions: [DisplayID: SavedLayoutSession], on display: DisplayID) -> [DisplayID: SavedLayoutSession] {
        var sessions = sessions
        if case var .tabbed(state) = sessions[display] {
            var layout = state.layout
            layout.floatingWindowIDs.insert(id)
            state.synchronize(with: layout)
            sessions[display] = .tabbed(state)
        }
        return sessions
    }

    @Test func hiddenTabUndoMustBeExact() async throws {
        let h = ApplyHarness(); defer { h.close() }
        h.addWindow("com.example.Editor", id: "editor")
        h.addWindow("com.example.Music", id: "music", pid: 43)
        h.system.stack = h.system.windows.map { .init(windowID: $0.id, frame: $0.frame) }
        let model = h.model(); defer { model.shutdown() }
        let applier = try #require(model.savedLayoutApplier)
        applier.observesKeyboard = false
        applier.application = { _ in nil }
        applier.runningApplicationName = { $0 == 43 ? "Music" : "Editor" }
        let initial = await applier.apply(h.document(mode: .tabbed))
        try #require(initial.issues.isEmpty)
        let before = h.system.windows.map(\.frame), previous = model.savedLayoutSessions()
        var document = tabbedPair()
        document.slots = [.init(id: "one", prefer: [.app("com.example.Editor")]), .init(id: "two", prefer: [.app("com.example.Music")])]
        let changed = await applier.apply(document)
        try #require(changed.issues.isEmpty)
        let writes = h.system.frameWriteCounts, raises = h.system.raiseRequests.count
        _ = await applier.apply(document)
        #expect(applier.lastPlan?.isEmpty == true && h.system.frameWriteCounts == writes && h.system.raiseRequests.count == raises)
        let hidden = h.system.windows[1].id
        h.system.failedFrameWriteNumbers[hidden] = [h.system.frameWriteCounts[hidden, default: 0] + 1]
        await applier.undoLastApply()
        #expect(h.system.windows.map(\.frame) != before)
        #expect(applier.hasUndo && applier.canUndo)
        #expect(applier.message == "Music could not be restored. Try Undo again.")
        #expect(applier.message != "Previous window frames restored.")
        #expect(applier.message?.contains("not installed") == false)
        h.system.failedFrameWriteNumbers = [:]
        await applier.undoLastApply()
        #expect(h.system.windows.map(\.frame) == before)
        #expect(model.savedLayoutSessions() == previous)
        #expect(!applier.hasUndo && applier.message == "Previous window frames restored.")
    }

    @Test func precommitFrameMoveMustInvalidatePlan() async throws {
        let h = ApplyHarness(); defer { h.close() }
        h.addWindow()
        let original = h.system.windows[0].frame
        let model = h.model(); defer { model.shutdown() }
        let applier = try #require(model.savedLayoutApplier)
        applier.observesKeyboard = false
        _ = await applier.apply(h.document())
        let previous = model.savedLayoutSessions(), writes = h.system.frameWriteCounts, raises = h.system.raiseRequests.count
        let manual = BTRect(x: 25, y: 30, width: 600, height: 400)
        let commit = applier.commit
        applier.commit = { plan, desktop, snapshot, valid in
            h.system.windows[0].frame = manual
            return await commit(plan, desktop, snapshot, valid)
        }
        var document = h.document(); document.name = "Different"; document.mode = .manual
        document.layout = nil; document.windows = [.init(slot: "slot", rect: .init(x: 0, y: 0, width: 0.5, height: 1))]
        let result = await applier.apply(document)
        #expect(result.placed == 0 && result.issues.map(\.message) == ["A window moved while applying. Try again."])
        #expect(h.system.windows[0].frame == manual)
        #expect(h.system.frameWriteCounts == writes && h.system.raiseRequests.count == raises)
        #expect(model.savedLayoutSessions() == previous && applier.hasUndo)
        applier.commit = commit
        await applier.undoLastApply()
        #expect(h.system.windows[0].frame == original)
        #expect(model.activeMode(for: h.system.mainDisplay.id) == .manual)
        // The rejected plan can subsequently apply normally, settle, and undo its own baseline.
        _ = await applier.apply(document)
        let acceptedWrites = h.system.frameWriteCounts, acceptedRaises = h.system.raiseRequests.count
        _ = await applier.apply(document)
        #expect(applier.lastPlan?.isEmpty == true && h.system.frameWriteCounts == acceptedWrites && h.system.raiseRequests.count == acceptedRaises)
        await applier.undoLastApply()
        #expect(h.system.windows[0].frame == original)
    }
}

extension SavedLayoutV2ApplyTests {
    @Test(arguments: ["selection", "membership"]) func tabbedRepeatCommitsChangedSelectionOrMembership(change: String) async throws {
        let h = ApplyHarness(); defer { h.close() }
        h.addWindow("com.example.Editor", id: "editor")
        h.addWindow("com.example.Music", id: "music", pid: 43)
        h.addWindow("com.example.Pages", id: "pages", pid: 44)
        h.system.stack = h.system.windows.map { .init(windowID: $0.id, frame: $0.frame) }
        h.system.updatesStackOnRaise = true
        let model = h.model(); defer { model.shutdown() }
        let applier = try #require(model.savedLayoutApplier)
        applier.observesKeyboard = false
        var document = tabbedPair()
        document.slots = [.init(id: "one", prefer: [.app("com.example.Editor")]), .init(id: "two", prefer: [.app("com.example.Music")])]
        _ = await applier.apply(document)
        let previous = model.savedLayoutSessions()
        if change == "selection" {
            // An external focus change makes the existing hidden Pages tab frontmost.
            h.system.stack = [h.system.windows[2], h.system.windows[0], h.system.windows[1]].map { .init(windowID: $0.id, frame: $0.frame) }
        } else {
            h.addWindow("com.example.New", id: "new", pid: 45)
            h.system.stack?.append(.init(windowID: h.system.windows[3].id, frame: h.system.windows[3].frame))
        }
        let before = h.system.windows.map(\.frame), raises = h.system.raiseRequests.count
        _ = await applier.apply(document)
        #expect(applier.lastPlan?.isEmpty == false && applier.lastRun?.offersUndo == true)
        #expect(model.savedLayoutSessions() != previous && h.system.raiseRequests.count > raises)
        guard case let .tabbed(state) = model.savedLayoutSessions()[h.system.mainDisplay.id] else { Issue.record("No Tabbed target"); return }
        if change == "selection" { #expect(state.selectedWindowIDs.contains(h.system.windows[2].id)) }
        else { #expect(state.windowIDs.contains(h.system.windows[3].id)) }
        if change == "membership" {
            let writes = h.system.frameWriteCounts, raises = h.system.raiseRequests.count, sessions = model.savedLayoutSessions()
            _ = await applier.apply(document)
            #expect(applier.lastPlan?.isEmpty == true && h.system.frameWriteCounts == writes && h.system.raiseRequests.count == raises)
            #expect(model.savedLayoutSessions() == sessions)
        }
        await applier.undoLastApply()
        let restored = change == "membership" ? addingOutsideFloat(h.system.windows[3].id, to: previous, on: h.system.mainDisplay.id) : previous
        #expect(h.system.windows.map(\.frame) == before && model.savedLayoutSessions() == restored)
        if change == "selection" {
            // Undo restores the previous selection; its now-settled arrangement must stay put.
            let writes = h.system.frameWriteCounts, raises = h.system.raiseRequests.count
            _ = await applier.apply(document)
            #expect(applier.lastPlan?.isEmpty == true && h.system.frameWriteCounts == writes && h.system.raiseRequests.count == raises)
            #expect(model.savedLayoutSessions() == previous && !applier.hasUndo)
        }
    }
}

extension SavedLayoutV2ApplyTests {
    @Test func firstChoiceArrivalReplacesRememberedSecondChoiceForManualApply() async throws {
        let h = ApplyHarness(); defer { h.close() }
        h.addWindow("com.example.Chrome", id: "chrome")
        let document = SavedLayoutDocument(name: "Browser", mode: .manual,
            slots: [.init(id: "browser", prefer: [.app("com.example.Safari"), .app("com.example.Chrome")])],
            windows: [.init(slot: "browser", rect: .init(x: 0, y: 0, width: 1, height: 1))])
        _ = await h.applier.apply(document)
        h.addWindow("com.example.Safari", id: "safari", pid: 43)
        #expect(try h.applier.preview(document).plan?.assignments["browser"] == h.system.windows[1].id)
        _ = await h.applier.apply(document)
        #expect(h.applier.lastPlan?.assignments["browser"] == h.system.windows[1].id)
        #expect(h.applier.lastPlan?.slotReasons["browser"] == .preferred(rank: 0))
        let writes = h.system.frameWriteCounts
        _ = await h.applier.apply(document)
        #expect(h.applier.lastPlan?.isEmpty == true && h.system.frameWriteCounts == writes)
    }

    @Test func groupReorderReoptimizesRememberedPreferences() async throws {
        let h = ApplyHarness(); defer { h.close() }
        h.addWindow("com.example.Chrome", id: "chrome"); h.addWindow("com.example.Safari", id: "safari", pid: 43)
        let store = AppGroupsStore(directory: h.directory, catalog: { [] })
        await store.load()
        try store.save(.init(groups: [.init(name: "Browser", apps: [.init(bundleID: "com.example.Chrome"), .init(bundleID: "com.example.Safari")])]))
        h.applier.appGroupsStore = store
        let document = SavedLayoutDocument(name: "Browser", mode: .manual,
            slots: [.init(id: "browser", prefer: [.group("Browser")])],
            windows: [.init(slot: "browser", rect: .init(x: 0, y: 0, width: 1, height: 1))])
        _ = await h.applier.apply(document)
        try store.save(.init(groups: [.init(name: "Browser", apps: [.init(bundleID: "com.example.Safari"), .init(bundleID: "com.example.Chrome")])]))
        _ = await h.applier.apply(document)
        #expect(h.applier.lastPlan?.assignments["browser"] == h.system.windows[1].id)
        #expect(h.applier.lastPlan?.slotReasons["browser"] == .preferred(rank: 0))
    }

    @Test func quickCapturePreservesMalformedNeighbor() throws {
        let h = ApplyHarness(); defer { h.close() }; h.addWindow()
        let editor = SavedLayoutEditor(files: .init(directory: h.directory))
        try FileManager.default.createDirectory(at: h.directory, withIntermediateDirectories: true)
        let bad = h.directory.appending(path: "bad.json"), bytes = Data("invalid".utf8)
        try bytes.write(to: bad)
        let message = SavedLayoutQuickCapture.save(applier: h.applier, editor: editor, displayID: h.system.mainDisplay.id)
        #expect(message.hasPrefix("Saved"))
        #expect(editor.document != nil && editor.entries.count == 2)
        #expect(try Data(contentsOf: bad) == bytes)
        #expect(editor.entryDocuments[bad] == nil)
    }
}

extension SavedLayoutV2ApplyTests {
    @Test(arguments: [LayoutMode.manual, .bento, .tabbed], [false, true])
    func previewIncludesExtraExplanationsAndPageUsesPlanCounts(mode: LayoutMode, addPanes: Bool) async throws {
        let h = ApplyHarness(); defer { h.close() }
        h.addWindow(); h.addWindow("com.example.Music", id: "music", pid: 43)
        h.applier.application = { id in .init(bundleIdentifier: id, name: id == "com.example.Music" ? "Music" : "Editor", url: URL(filePath: "/fixture/App.app")) }
        var document = h.document(mode: mode)
        if mode == .bento && addPanes { document.extraWindows = .addAsPanes }
        let preview = try h.applier.preview(document)
        let cache = SavedLayoutPagePlan()
        cache.refresh(document: document, displayID: preview.displayID, identity: nil, displays: h.snapshot().displays, unavailable: nil) { _, _ in preview }
        let predicted = try #require(cache.presentation(groups: .init(), resolvedBundleIDs: [:], name: { _ in "Editor" }, displayName: { _ in "Display" }))
        _ = await h.applier.apply(document)
        let run = try #require(h.applier.lastRun)
        #expect(predicted.lines == run.planPresentation?.lines)
        #expect(predicted.summary == run.planPresentation?.summary)
        #expect(predicted.lines.contains { $0.contains("Music") })
        let session = SavedLayoutApplySession(applier: h.applier)
        #expect(session.adoptRun(document: document))
        let page = SavedLayoutSettings(editor: .init(files: .init(directory: h.directory)), suppliedSession: session,
            targetOverride: .init(displayID: preview.displayID, spaceID: h.space(1)))
        #expect(page.pageDetail(document) == run.planPresentation?.summary)
    }

    @Test func successfulVacanciesAreEmptyInPageDetail() async throws {
        let h = ApplyHarness(); defer { h.close() }; h.addWindow()
        let document = SavedLayoutDocument(name: "Three panes", mode: .bento,
            layout: .split(axis: .vertical, ratios: [0.4, 0.3, 0.3], children: [.slot("a"), .slot("b"), .slot("c")]),
            slots: [.init(id: "a"), .init(id: "b"), .init(id: "c")])
        _ = await h.applier.apply(document)
        let session = SavedLayoutApplySession(applier: h.applier)
        #expect(session.adoptRun(document: document))
        let page = SavedLayoutSettings(editor: .init(files: .init(directory: h.directory)), suppliedSession: session,
            targetOverride: .init(displayID: h.system.mainDisplay.id, spaceID: h.space(1)))
        #expect(page.pageDetail(document) == "1 arranged · 2 empty panes")
        #expect(!page.pageDetail(document).contains("attention"))
    }

    @Test(arguments: [false, true]) func applyReportsUnknownAndUnresolvedGroupsWithoutBundleIDs(ambiguous: Bool) async throws {
        let h = ApplyHarness(); defer { h.close() }; h.addWindow()
        let store = AppGroupsStore(directory: h.directory, catalog: {
            ambiguous ? [
                .init(bundleIdentifier: "org.example.First", name: "Editor", url: URL(filePath: "/fixture/First.app")),
                .init(bundleIdentifier: "org.example.Second", name: "Editor", url: URL(filePath: "/fixture/Second.app"))
            ] : []
        })
        await store.load()
        try store.save(.init(groups: [.init(name: "Browser", apps: [.init(name: ambiguous ? "Editor" : "org.example.UnknownApp")])]))
        h.applier.appGroupsStore = store
        var document = h.document()
        document.slots[0].prefer = [.group("Old name"), .group("Browser")]
        let result = await h.applier.apply(document)
        #expect(result.placed == 1)
        #expect(result.issues.contains { $0.message.contains("Old name") })
        #expect(result.issues.contains { $0.message.contains("Browser") })
        #expect(!result.issues.map(\.message).joined().contains("org.example.UnknownApp"))
        #expect(h.applier.lastRun?.planPresentation?.issues == result.issues)
        #expect(h.applier.lastRun?.presentation.issues == result.issues)
    }
}

extension SavedLayoutV2ApplyTests {
    @Test func pageOffersExistingWindowChoiceListForMultipleEligibleWindows() throws {
        let h = ApplyHarness(); defer { h.close() }
        h.addWindow(); h.addWindow(id: "other", pid: 42)
        let document = h.document()
        let session = SavedLayoutApplySession(applier: h.applier)
        let editor = SavedLayoutEditor(files: .init(directory: h.directory))
        editor.newLayout(); #expect(editor.edit { $0 = document })
        let page = SavedLayoutSettings(editor: editor, suppliedSession: session,
            targetOverride: .init(displayID: h.system.mainDisplay.id, spaceID: h.space(1)))
        page.pagePlan.refresh(document: document, displayID: h.system.mainDisplay.id, identity: nil,
            displays: h.snapshot().displays, unavailable: nil) { _, _ in try h.applier.preview(document) }
        #expect(page.slotChooser("slot", document: document) != nil)
        #expect(h.system.frameWriteCounts.isEmpty)
    }
}

extension SavedLayoutV2ApplyTests {
    @Test func pageChoiceUsesTheNondefaultWindowForOneApplyAndRejectsStaleCandidates() async throws {
        let h = ApplyHarness(); defer { h.close() }
        h.addWindow(); h.addWindow(id: "other", pid: 42)
        let document = h.document()
        let session = SavedLayoutApplySession(applier: h.applier)
        let editor = SavedLayoutEditor(files: .init(directory: h.directory))
        editor.newLayout(); #expect(editor.edit { $0 = document })
        let page = SavedLayoutSettings(editor: editor, suppliedSession: session,
            targetOverride: .init(displayID: h.system.mainDisplay.id, spaceID: h.space(1)))
        let preview = try h.applier.preview(document)
        let selected = try #require(h.system.windows.first { $0.id != preview.plan?.assignments["slot"] }).id
        page.pagePlan.refresh(document: document, displayID: preview.displayID, identity: nil,
            displays: h.snapshot().displays, unavailable: nil) { _, _ in preview }
        page.chooseWindow(selected, forSlot: "slot", document: document)
        #expect(session.choices == ["slot": selected])
        #expect(h.commits.isEmpty && h.system.frameWriteCounts.isEmpty)
        page.apply(document)
        try await waitForSavedLayoutState("The chosen Apply did not finish.") { h.applier.lastRun != nil && !h.applier.isApplying }
        #expect(h.applier.lastPlan?.assignments["slot"] == selected)
        #expect(h.applier.lastPlan?.slotReasons["slot"] == .chosen)
        page.apply(document)
        try await waitForSavedLayoutState("The next Apply did not finish.") { !h.applier.isApplying }
        #expect(session.choices.isEmpty)
        #expect(h.applier.lastPlan?.slotReasons["slot"] == .preferred(rank: 0))
        // The cached list can outlive a window. The click reads fresh candidates.
        h.system.windows.removeAll { $0.id == selected }
        page.chooseWindow(selected, forSlot: "slot", document: document)
        #expect(session.choices["slot"] != selected)
        #expect(session.problem == "The chosen window is no longer available. Choose a window again.")
    }

    @Test func rememberedOccupantMovesToTheLargestPaneAfterItsWindowCloses() async throws {
        let h = ApplyHarness(); defer { h.close() }
        h.addWindow(id: "first"); h.addWindow(id: "remaining", pid: 43)
        let document = SavedLayoutDocument(name: "Unequal panes", mode: .bento,
            layout: .split(axis: .vertical, ratios: [0.75, 0.25], children: [.slot("large"), .slot("small")]),
            slots: [.init(id: "large", prefer: []), .init(id: "small", prefer: [])])
        _ = await h.applier.apply(document)
        let first = try #require(h.applier.lastPlan?.assignments["large"])
        let remaining = try #require(h.applier.lastPlan?.assignments["small"])
        h.system.windows.removeAll { $0.id == first }
        #expect(try h.applier.preview(document).plan?.assignments == ["large": remaining])
        _ = await h.applier.apply(document)
        #expect(h.applier.lastPlan?.assignments == ["large": remaining])
        #expect(h.applier.lastPlan?.emptySlots == ["small"])
        let writes = h.system.frameWriteCounts
        let commits = h.commits
        _ = await h.applier.apply(document)
        #expect(h.system.frameWriteCounts == writes && h.commits == commits)
        #expect(h.applier.hasUndo)
    }

    @Test func pageCountsArrangedLocalAndTransferredWindowsSeparately() async throws {
        let h = ApplyHarness(); defer { h.close() }
        let remote = DisplaySnapshot(id: .init(rawValue: "remote"), frame: .init(x: 1000, y: 0, width: 1000, height: 800),
            visibleFrame: .init(x: 1000, y: 0, width: 1000, height: 800), isMain: false)
        h.system.availableDisplays.append(remote); h.usesAllDisplays = true
        h.system.desktopObservation?.currentSpaceByDisplay[remote.id] = h.space(2)
        h.addWindow("com.example.Local", id: "local")
        h.addWindow("com.example.Remote", id: "remote", pid: 43, desktop: 2)
        h.system.windows[1].displayID = remote.id; h.system.windows[1].frame.origin.x += 1000
        h.system.onFrameWrite = { id, frame in h.system.desktopObservation?.windowMembership[id] = [frame.midX >= 1000 ? h.space(2) : h.space(1)] }
        let document = SavedLayoutDocument(name: "Two displays", mode: .bento,
            layout: .split(axis: .vertical, ratios: [0.5, 0.5], children: [.slot("local"), .slot("remote")]),
            slots: [.init(id: "local", prefer: [.app("com.example.Local")]), .init(id: "remote", prefer: [.app("com.example.Remote")])])
        _ = await h.applier.apply(document)
        #expect(h.applier.lastRun?.result.movedSlots == ["remote"])
        let session = SavedLayoutApplySession(applier: h.applier)
        #expect(session.adoptRun(document: document))
        let page = SavedLayoutSettings(editor: .init(files: .init(directory: h.directory)), suppliedSession: session,
            targetOverride: .init(displayID: h.system.mainDisplay.id, spaceID: h.space(1)))
        #expect(page.pageDetail(document) == "2 arranged · 1 moved from another display")
    }
}

extension SavedLayoutV2ApplyTests {


    @Test func partialMemoryKeepsTheFreshFillReasonForANewWindow() async throws {
        let h = ApplyHarness(); defer { h.close() }
        h.addWindow(id: "first"); h.addWindow(id: "second")
        let document = SavedLayoutDocument(name: "Three panes", mode: .bento,
            layout: .split(axis: .vertical, ratios: [0.5, 0.3, 0.2], children: [.slot("a"), .slot("b"), .slot("c")]),
            slots: [.init(id: "a", prefer: []), .init(id: "b", prefer: []), .init(id: "c", prefer: [])])
        _ = await h.applier.apply(document)
        let remembered = try #require(h.applier.lastPlan?.assignments)
        // A new front window makes the fresh optimum differ while memory can keep both old occupants.
        h.addWindow(id: "new", pid: 43)
        h.system.stack = h.system.windows.reversed().map { .init(windowID: $0.id, frame: $0.frame) }
        let plan = try #require(h.applier.preview(document).plan)
        #expect(plan.assignments["a"] == remembered["a"] && plan.assignments["b"] == remembered["b"])
        #expect(plan.assignments["c"] == WindowID(rawValue: "new"))
        #expect(plan.slotReasons["c"] == .largestFreeSlot)
    }
}

extension SavedLayoutV2ApplyTests {

}
