import BetterTileCore
@testable import BetterTileMacOS
@testable import BetterTileApp
import Testing

@MainActor private func choicePage(_ h: ApplyHarness, _ document: SavedLayoutDocument) throws
    -> (SavedLayoutSettings, SavedLayoutApplySession) {
    let editor = SavedLayoutEditor(files: .init(directory: h.directory))
    editor.newLayout()
    #expect(editor.edit { $0 = document })
    #expect(editor.save())
    let session = SavedLayoutApplySession(applier: h.applier, positions: { editor.positionContext })
    let page = SavedLayoutSettings(editor: editor, suppliedSession: session,
        targetOverride: .init(displayID: h.system.mainDisplay.id, spaceID: h.space(1)))
    page.pagePlan.refresh(document: document, displayID: h.system.mainDisplay.id, identity: nil,
        displays: h.snapshot().displays, unavailable: nil) { doc, display in
            try h.applier.preview(doc, displayID: display, positions: editor.positionContext)
        }
    return (page, session)
}

@Suite(.appTestApplication) @MainActor struct SavedLayoutChoiceRegressionTests {
    @Test func choiceDismissesItsPopoverOnlyAfterAnAcceptedSelection() throws {
        let h = ApplyHarness(); defer { h.close() }
        h.addWindow(); h.addWindow(id: "other")
        let document = h.document()
        let (page, session) = try choicePage(h, document)
        var dismissals = 0
        let selected = WindowID(rawValue: "other")
        page.chooseWindow(selected, forSlot: "slot", document: document, onChosen: { dismissals += 1 })
        #expect(dismissals == 1)
        #expect(session.choices == ["slot": selected])
        h.system.windows.removeAll { $0.id == selected }
        page.chooseWindow(selected, forSlot: "slot", document: document, onChosen: { dismissals += 1 })
        #expect(dismissals == 1)
        #expect(session.problem == "The chosen window is no longer available. Choose a window again.")
    }

    @Test func closingAChosenWindowDoesNotBlockAnotherPanesChoice() throws {
        let h = ApplyHarness(); defer { h.close() }
        h.addWindow(id: "first"); h.addWindow(id: "fallback")
        h.addWindow("com.example.Browser", id: "second", pid: 43)
        let document = SavedLayoutDocument(name: "Two panes", mode: .bento,
            layout: .split(axis: .vertical, ratios: [0.5, 0.5], children: [.slot("a"), .slot("b")]),
            slots: [.init(id: "a", prefer: [.app("com.example.Editor")]),
                    .init(id: "b", prefer: [.app("com.example.Browser")])])
        let (page, session) = try choicePage(h, document)
        let first = WindowID(rawValue: "first"), second = WindowID(rawValue: "second")
        page.chooseWindow(first, forSlot: "a", document: document)
        #expect(session.choices == ["a": first])
        h.system.windows.removeAll { $0.id == first }
        var accepted = false
        page.chooseWindow(second, forSlot: "b", document: document, onChosen: { accepted = true })
        #expect(accepted)
        #expect(session.problem == nil)
        #expect(session.choices == ["b": second])
        #expect(page.pagePlan.preview?.plan?.slotReasons["b"] == .chosen)
        #expect(h.system.frameWriteCounts.isEmpty)
    }

    @Test(arguments: ["repair", "desktop", "groups"])
    func transientReviewKeepsPendingChoices(reason: String) throws {
        let h = ApplyHarness(); defer { h.close() }
        h.addWindow(); h.addWindow(id: "other")
        let document = h.document()
        let (page, session) = try choicePage(h, document)
        let selected = WindowID(rawValue: "other")
        page.chooseWindow(selected, forSlot: "slot", document: document)
        if reason == "repair" { h.suspended = true }
        else if reason == "desktop" { h.ready = false }
        else { h.applier.isLoadingAppGroups = true }
        session.review(document: document, displayID: h.system.mainDisplay.id)
        #expect(session.preview?.plan == nil)
        #expect(session.choices == ["slot": selected])
        h.suspended = false; h.ready = true; h.applier.isLoadingAppGroups = false
        session.review(document: document, displayID: h.system.mainDisplay.id)
        #expect(session.preview?.plan?.slotReasons["slot"] == .chosen)
        #expect(session.choices == ["slot": selected])
    }

    @Test func applyingAPendingChoiceDuringAnEmptyPreviewExplainsTheWait() throws {
        let h = ApplyHarness(); defer { h.close() }
        h.addWindow(); h.addWindow(id: "other")
        let document = h.document()
        let (page, session) = try choicePage(h, document)
        let selected = WindowID(rawValue: "other")
        page.chooseWindow(selected, forSlot: "slot", document: document)
        h.applier.isLoadingAppGroups = true
        page.apply(document)
        #expect(session.preview?.rows.isEmpty == true && session.preview?.plan == nil)
        #expect(session.problem == SavedLayoutApplier.desktopNotReady)
        #expect(session.choices == ["slot": selected])
        #expect(h.commits.isEmpty && h.system.frameWriteCounts.isEmpty && !h.applier.isApplying)
        h.applier.isLoadingAppGroups = false
        session.review(document: document, displayID: h.system.mainDisplay.id)
        #expect(session.problem == nil && session.preview?.plan?.slotReasons["slot"] == .chosen)
    }

    @Test func staleApplyKeepsOtherValidChoicesForTheNextAttempt() throws {
        let h = ApplyHarness(); defer { h.close() }
        h.addWindow(id: "first"); h.addWindow(id: "second")
        let document = SavedLayoutDocument(name: "Two panes", mode: .bento,
            layout: .split(axis: .vertical, ratios: [0.5, 0.5], children: [.slot("a"), .slot("b")]),
            slots: [.init(id: "a", prefer: []), .init(id: "b", prefer: [])])
        let (page, session) = try choicePage(h, document)
        let first = WindowID(rawValue: "first"), second = WindowID(rawValue: "second")
        page.chooseWindow(first, forSlot: "a", document: document)
        page.chooseWindow(second, forSlot: "b", document: document)
        #expect(session.choices == ["a": first, "b": second])
        h.system.windows.removeAll { $0.id == first }
        page.apply(document)
        #expect(session.problem == SavedLayoutApplySession.unavailableChoice)
        #expect(session.choices == ["b": second])
        #expect(h.commits.isEmpty && h.system.frameWriteCounts.isEmpty && !h.applier.isApplying)
        // Review must reuse the surviving choice instead of rebuilding the default plan.
        session.review(document: document, displayID: h.system.mainDisplay.id)
        #expect(session.preview?.plan?.assignments["b"] == second)
        #expect(session.preview?.plan?.slotReasons["b"] == .chosen)
    }

    @Test(arguments: ["closed", "minimized", "other-desktop", "foreign-owned", "unfittable-fallback"])
    func queuedApplyRefusesALostChoiceAndKeepsTheOtherSelection(ending: String) async throws {
        let h = ApplyHarness(); defer { h.close() }
        h.addWindow(id: "fallback"); h.addWindow(id: "chosen")
        h.addWindow("com.example.Browser", id: "browser-default", pid: 43)
        h.addWindow("com.example.Browser", id: "browser-chosen", pid: 43)
        if ending == "foreign-owned" {
            let remote = DisplaySnapshot(id: .init(rawValue: "remote"), frame: .init(x: 1000, y: 0, width: 1000, height: 800),
                visibleFrame: .init(x: 1000, y: 0, width: 1000, height: 800), isMain: false)
            h.system.availableDisplays.append(remote); h.usesAllDisplays = true
            h.system.desktopObservation?.currentSpaceByDisplay[remote.id] = h.space(2)
            h.system.desktopObservation?.knownSpacesByDisplay[remote.id] = [h.space(2)]
        }
        let document = SavedLayoutDocument(name: "Two choices", mode: .bento,
            layout: .split(axis: .vertical, ratios: [0.5, 0.5], children: [.slot("a"), .slot("b")]),
            slots: [.init(id: "a", prefer: [.app("com.example.Editor")]),
                    .init(id: "b", prefer: [.app("com.example.Browser")])])
        let (page, session) = try choicePage(h, document)
        let lost = WindowID(rawValue: "chosen"), kept = WindowID(rawValue: "browser-chosen")
        page.chooseWindow(lost, forSlot: "a", document: document)
        page.chooseWindow(kept, forSlot: "b", document: document)
        #expect(session.choices == ["a": lost, "b": kept])
        page.apply(document) // The synchronous page preview has succeeded; the run is only queued.
        try #require(session.preview?.plan?.assignments["a"] == lost && h.applier.isApplying)
        #expect(h.commits.isEmpty && h.system.frameWriteCounts.isEmpty)
        let fallbackConstraints = h.system.windows[0].constraints
        if ending == "closed" || ending == "unfittable-fallback" {
            h.system.windows.removeAll { $0.id == lost }
            if ending == "unfittable-fallback" { h.system.windows[0].constraints.minimumSize = .init(width: 2000, height: 1000) }
        } else if ending == "minimized" {
            let index = try #require(h.system.windows.firstIndex { $0.id == lost })
            h.system.windows[index].isMinimized = true
        } else if ending == "foreign-owned" {
            let index = try #require(h.system.windows.firstIndex { $0.id == lost })
            h.system.windows[index].displayID = .init(rawValue: "remote")
            h.system.windows[index].frame.origin.x += 1000
            h.system.desktopObservation?.windowMembership[lost] = [h.space(2)]
            h.applier.reservesOtherOwnerWindow = { $0.id == lost }
        } else { h.system.desktopObservation?.windowMembership[lost] = [h.space(2)] }
        try await waitForSavedLayoutState("The queued Apply did not finish.") { h.applier.lastRun != nil && !h.applier.isApplying }
        #expect(h.commits.isEmpty && h.system.frameWriteCounts.isEmpty)
        #expect(h.applier.lastRun?.result.placed == 0)
        #expect(h.applier.lastRun?.result.issues.contains { $0.message == SavedLayoutApplySession.unavailableChoice } == true)
        #expect(session.problem == SavedLayoutApplySession.unavailableChoice)
        #expect(session.choices == ["b": kept])
        h.system.windows[0].constraints = fallbackConstraints
        // Preview refresh remains permissive, so a disappeared choice does not hide other candidates.
        let fresh = try h.applier.preview(document, choices: ["a": lost, "b": kept])
        #expect(fresh.problem == nil && fresh.plan?.assignments["a"] == WindowID(rawValue: "fallback"))
        let refused = h.applier.lastRun?.date
        page.apply(document)
        try await waitForSavedLayoutState("Retry did not finish.") { h.applier.lastRun?.date != refused && !h.applier.isApplying }
        #expect(h.applier.lastRun?.result.placed == 2)
        #expect(h.applier.lastPlan?.assignments["b"] == kept && h.applier.lastPlan?.slotReasons["b"] == .chosen)
        #expect(session.choices.isEmpty)
    }

    @Test func consumedChoiceIsNotReusedWhenAnotherPaneIsChosen() async throws {
        let h = ApplyHarness(); defer { h.close() }
        h.addWindow(id: "editor-one"); h.addWindow(id: "editor-two")
        h.addWindow("com.example.Browser", id: "browser-one", pid: 43)
        h.addWindow("com.example.Browser", id: "browser-two", pid: 43)
        let document = SavedLayoutDocument(name: "Two apps", mode: .bento,
            layout: .split(axis: .vertical, ratios: [0.5, 0.5], children: [.slot("a"), .slot("b")]),
            slots: [.init(id: "a", prefer: [.app("com.example.Editor")]),
                    .init(id: "b", prefer: [.app("com.example.Browser")])])
        let (page, session) = try choicePage(h, document)
        let w1 = WindowID(rawValue: "editor-two"), w2 = WindowID(rawValue: "browser-two")
        page.chooseWindow(w1, forSlot: "a", document: document)
        page.apply(document)
        try await waitForSavedLayoutState("The first choice did not finish.") { h.applier.lastRun != nil && !h.applier.isApplying }
        #expect(h.applier.lastPlan?.slotReasons["a"] == .chosen)
        #expect(session.choices.isEmpty)
        let first = h.applier.lastRun?.date
        page.chooseWindow(w2, forSlot: "b", document: document)
        #expect(session.choices == ["b": w2])
        page.apply(document)
        try await waitForSavedLayoutState("The second choice did not finish.") { h.applier.lastRun?.date != first && !h.applier.isApplying }
        #expect(h.applier.lastPlan?.slotReasons["a"] == .preferred(rank: 0))
        #expect(h.applier.lastPlan?.slotReasons["b"] == .chosen)
        #expect(session.choices.isEmpty)
    }

    @Test func pendingChoiceKeepsThePreviousApplyUndoAndUpdateBlock() async throws {
        let h = ApplyHarness(); defer { h.close() }
        h.addWindow(); h.addWindow(id: "other")
        let document = h.document()
        let (page, session) = try choicePage(h, document)
        page.apply(document)
        try await waitForSavedLayoutState("Apply did not finish.") { h.applier.lastRun != nil && !h.applier.isApplying }
        let previous = try #require(session.run)
        #expect(session.canUndo && page.showsUndoApply(document))
        #expect(page.updateUnavailableReason == "Finish or undo this layout’s Apply before updating it.")
        let writes = h.system.frameWriteCounts
        page.chooseWindow(.init(rawValue: "other"), forSlot: "slot", document: document)
        #expect(session.run?.date == previous.date)
        #expect(session.choices["slot"] == WindowID(rawValue: "other"))
        #expect(page.pagePlan.preview?.plan?.slotReasons["slot"] == .chosen)
        #expect(session.canUndo && page.showsUndoApply(document))
        #expect(page.updateUnavailableReason == "Finish or undo this layout’s Apply before updating it.")
        #expect(h.system.frameWriteCounts == writes)
    }

    @Test func applyRefusesAChoiceThatDisappearedAfterSelection() throws {
        let h = ApplyHarness(); defer { h.close() }
        h.addWindow(); h.addWindow(id: "other")
        let document = h.document()
        let (page, session) = try choicePage(h, document)
        let selected = WindowID(rawValue: "other")
        page.chooseWindow(selected, forSlot: "slot", document: document)
        #expect(session.choices == ["slot": selected])
        h.system.windows.removeAll { $0.id == selected }
        page.apply(document)
        #expect(session.problem == "The chosen window is no longer available. Choose a window again.")
        #expect(h.commits.isEmpty && h.system.frameWriteCounts.isEmpty && !h.applier.isApplying)
    }

    @Test func pendingChoiceSurvivesDefaultAppChangeAndUpdatesThePagePreview() async throws {
        let h = ApplyHarness(); defer { h.close() }
        h.addWindow("com.example.Safari", id: "safari-one")
        h.addWindow("com.example.Safari", id: "safari-two")
        let document = SavedLayoutDocument(name: "Any windows", mode: .bento,
            layout: .split(axis: .vertical, ratios: [0.5, 0.5], children: [.slot("a"), .slot("b")]),
            slots: [.init(id: "a", prefer: []), .init(id: "b", prefer: [])])
        let (page, session) = try choicePage(h, document)
        let defaultWindow = try #require(page.pagePlan.preview?.plan?.assignments["a"])
        let selected = try #require(h.system.windows.first { $0.id != defaultWindow }).id
        page.chooseWindow(selected, forSlot: "a", document: document)
        #expect(page.pagePlan.preview?.plan?.assignments["a"] == selected)
        #expect(page.pagePlan.preview?.plan?.slotReasons["a"] == .chosen)
        h.addWindow("com.example.Chrome", id: "aaa-chrome", pid: 43)
        #expect(try h.applier.preview(document).rows.first { $0.id == "a" }?.appName == "com.example.Chrome")
        page.apply(document)
        try await waitForSavedLayoutState("The pending choice did not finish.") { !h.applier.isApplying }
        #expect(session.problem == nil)
        #expect(h.applier.lastPlan?.assignments["a"] == selected)
        #expect(h.applier.lastPlan?.slotReasons["a"] == .chosen)
    }
}
