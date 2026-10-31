import AppKit
import BetterTileCore
@testable import BetterTileMacOS
@testable import BetterTileApp
import Testing

@Suite(.appTestApplication) @MainActor struct SavedLayoutFollowingTests {
    private func store(_ model: BetterTileModel) throws -> LayoutSessionStore {
        try #require(Mirror(reflecting: model).children.first { $0.label?.hasSuffix("sessionStore") == true }?.value as? LayoutSessionStore)
    }

    private func document(_ h: ApplyHarness, mode: LayoutMode = .bento) -> SavedLayoutDocument {
        var value = h.document(mode: mode)
        value.keepForNewWindows = true
        return value
    }

    @Test(arguments: [LayoutMode.bento, .tabbed]) func applyStartsFollowingAndRepeatKeepsIt(mode: LayoutMode) async throws {
        let h = ApplyHarness(); defer { h.close() }
        h.addWindow()
        let model = h.model(); defer { model.shutdown() }
        let applier = try #require(model.savedLayoutApplier)
        applier.observesKeyboard = false
        let document = document(h, mode: mode)
        _ = await applier.apply(document, layoutFileID: "Work.json")
        let first = try #require(try store(model).session(for: h.system.mainDisplay.id)?.followed)
        #expect(first.layoutName == document.name)
        let writes = h.system.frameWriteCounts
        let revision = try store(model).session(for: h.system.mainDisplay.id)?.revision
        _ = await applier.apply(document, layoutFileID: "Work.json")
        #expect(try store(model).session(for: h.system.mainDisplay.id)?.followed == first)
        #expect(try store(model).session(for: h.system.mainDisplay.id)?.revision == revision)
        #expect(h.system.frameWriteCounts == writes)
        await applier.undoLastApply()
        #expect(try store(model).session(for: h.system.mainDisplay.id)?.followed == nil)
        let undoneWrites = h.system.frameWriteCounts
        await applier.undoLastApply()
        #expect(h.system.frameWriteCounts == undoneWrites)
    }

    private func session(_ model: BetterTileModel, _ display: DisplayID) throws -> LayoutSession {
        try #require(try store(model).session(for: display))
    }

    private func historyCounts(_ model: BetterTileModel, _ ids: [WindowID]) throws -> [Int] {
        let coordinator = try #require(Mirror(reflecting: model).children.first { $0.label?.hasSuffix("coordinator") == true }?.value as? WindowCoordinator)
        let history = try #require(Mirror(reflecting: coordinator).children.first { $0.label == "history" }?.value as? FrameHistory)
        return ids.map { history.count(for: $0) }
    }

    private func idle(_ model: BetterTileModel) -> Bool {
        let tasks = Mirror(reflecting: model).children.first { $0.label?.hasSuffix("tabbedTasks") == true }?.value as? [DisplayID: Task<Void, Never>]
        return model.settlementTasks.isEmpty && tasks?.isEmpty != false
    }

    private func sweep(_ model: BetterTileModel) async throws {
        model.processPendingWindowEvents()
        model.watchdog()
        try await waitForWindowEventsToDrain(model)
        try #require(await waitFor { idle(model) })
        for _ in 0..<20 { await Task.yield() }
    }

    private func repeatSweep(_ model: BetterTileModel, _ h: ApplyHarness, event: WindowSystemEvent? = nil) async throws {
        let before = try store(model).session(for: h.system.mainDisplay.id)
        let writes = h.system.frameWriteCounts
        if let event { h.system.eventHandler?(event) }
        try await sweep(model)
        #expect(try store(model).session(for: h.system.mainDisplay.id) == before)
        #expect(h.system.frameWriteCounts == writes)
    }

    private func twoPanes(mode: LayoutMode, sameApp: Bool = false) -> SavedLayoutDocument {
        .init(name: "Homework", mode: mode,
            layout: .split(axis: .vertical, ratios: [0.6, 0.4], children: mode == .tabbed
                ? [.group("left"), .group("right")] : [.slot("left"), .slot("right")]),
            slots: [.init(id: "left", prefer: [.app("com.example.Editor")]),
                    .init(id: "right", prefer: [.app(sameApp ? "com.example.Editor" : "com.example.Browser")])],
            groups: mode == .tabbed ? [.init(id: "left", slots: ["left"], selected: "left"), .init(id: "right", slots: ["right"], selected: "right")] : [],
            keepForNewWindows: true)
    }

    @Test(arguments: [LayoutMode.bento, .tabbed]) func closeAndReopenFillThePreferredPane(mode: LayoutMode) async throws {
        let h = ApplyHarness(); defer { h.close() }
        h.addWindow(id: "editor")
        h.addWindow("com.example.Browser", id: "browser", pid: 43)
        h.system.focusedID = .init(rawValue: "browser")
        let model = h.model(); defer { model.shutdown() }
        let applier = try #require(model.savedLayoutApplier); applier.observesKeyboard = false
        let document = twoPanes(mode: mode)
        _ = await applier.apply(document, layoutFileID: "Homework.json")
        try #require(try session(model, h.system.mainDisplay.id).followed != nil)
        let editorFrame = h.system.windows[0].frame
        let browserFrame = h.system.windows[1].frame
        let removed = h.system.windows.removeFirst()
        h.system.eventHandler?(.init(kind: .destroyed, windowID: removed.id, processIdentifier: removed.processIdentifier))
        try await sweep(model)
        let closed = try session(model, h.system.mainDisplay.id)
        #expect(closed.followed != nil)
        #expect(h.system.windows[0].frame == browserFrame)
        #expect(closed.bentoState.root?.windowIDs.count == 1)
        try await repeatSweep(model, h, event: .init(kind: .destroyed, windowID: removed.id, processIdentifier: removed.processIdentifier))
        h.addWindow(id: "editor-reopened", pid: 44)
        h.system.eventHandler?(.init(kind: .created, windowID: h.system.windows.last!.id, processIdentifier: 44))
        try await sweep(model)
        #expect(h.system.windows.last?.frame == editorFrame)
        #expect(h.system.requestedFrames[.init(rawValue: "editor-reopened")]?.last == editorFrame)
        #expect(h.system.windows[0].frame == browserFrame)
        #expect(try session(model, h.system.mainDisplay.id).followed != nil)
        try await repeatSweep(model, h, event: .init(kind: .created, windowID: h.system.windows.last!.id, processIdentifier: 44))
    }

    @Test(arguments: [LayoutMode.bento, .tabbed]) func secondWindowOfSameAppUsesSecondPreferredPane(mode: LayoutMode) async throws {
        let h = ApplyHarness(); defer { h.close() }
        h.addWindow(id: "editor")
        let model = h.model(); defer { model.shutdown() }
        let applier = try #require(model.savedLayoutApplier); applier.observesKeyboard = false
        _ = await applier.apply(twoPanes(mode: mode, sameApp: true), layoutFileID: "Homework.json")
        try #require(try session(model, h.system.mainDisplay.id).followed != nil)
        h.addWindow(id: "second", pid: 43)
        h.system.eventHandler?(.init(kind: .created, windowID: h.system.windows.last!.id, processIdentifier: 43))
        try await sweep(model)
        let current = try session(model, h.system.mainDisplay.id)
        #expect(current.followed != nil)
        let right = try #require(current.bentoState.placements(in: h.system.mainDisplay.visibleFrame).last?.frame)
        let content = mode == .tabbed ? (try current.tabbedState?.placements(in: h.system.mainDisplay.visibleFrame, windows: h.system.windows))?.first { $0.windowID.rawValue == "second" }?.frame : right
        #expect(h.system.windows.last?.frame == content)
        #expect(h.system.windows.last?.frame.minX ?? 0 > 500)
        try await repeatSweep(model, h, event: .init(kind: .created, windowID: h.system.windows.last!.id, processIdentifier: 43))
    }

    @Test(arguments: [false, true]) func metadataOnlyApplyChangesFollowingWithoutUndoOrWrites(turnOff: Bool) async throws {
        let h = ApplyHarness(); defer { h.close() }
        h.addWindow()
        let model = h.model(); defer { model.shutdown() }
        let applier = try #require(model.savedLayoutApplier); applier.observesKeyboard = false
        var document = document(h)
        if !turnOff { document.keepForNewWindows = false }
        _ = await applier.apply(document, layoutFileID: "Work.json")
        let baseline = h.system.windows.map(\.frame)
        let writes = h.system.frameWriteCounts
        document.keepForNewWindows = !document.keepForNewWindows
        _ = await applier.apply(document, layoutFileID: "Work.json")
        #expect(applier.lastPlan?.isEmpty == true)
        #expect((try session(model, h.system.mainDisplay.id).followed != nil) == !turnOff)
        #expect(h.system.windows.map(\.frame) == baseline && h.system.frameWriteCounts == writes)
        #expect(applier.lastRun?.offersUndo == false)
        let revision = try session(model, h.system.mainDisplay.id).revision
        _ = await applier.apply(document, layoutFileID: "Work.json")
        #expect(try session(model, h.system.mainDisplay.id).revision == revision)
        #expect(h.system.frameWriteCounts == writes && applier.lastRun?.offersUndo == false)
        // The older placement Undo remains the only step.
        await applier.undoLastApply()
        #expect(model.activeMode(for: h.system.mainDisplay.id) == .manual)
        #expect(try session(model, h.system.mainDisplay.id).followed == nil)
    }

    @Test func anotherLayoutAndUndoNeverRestoreFollowing() async throws {
        let h = ApplyHarness(); defer { h.close() }
        h.addWindow()
        let model = h.model(); defer { model.shutdown() }
        let applier = try #require(model.savedLayoutApplier); applier.observesKeyboard = false
        let a = twoPanes(mode: .bento)
        _ = await applier.apply(a, layoutFileID: "A.json")
        let framesA = h.system.windows.map(\.frame)
        var b = a; b.name = "Other"; b.keepForNewWindows = false
        _ = await applier.apply(b, layoutFileID: "B.json")
        #expect(try session(model, h.system.mainDisplay.id).followed == nil)
        #expect(h.system.windows.map(\.frame) == framesA)
        let writes = h.system.frameWriteCounts, revision = try session(model, h.system.mainDisplay.id).revision
        _ = await applier.apply(b, layoutFileID: "B.json")
        #expect(h.system.frameWriteCounts == writes)
        #expect(try session(model, h.system.mainDisplay.id).revision == revision)
        b.keepForNewWindows = true
        b.layout = .split(axis: .vertical, ratios: [0.3, 0.7], children: [.slot("left"), .slot("right")])
        _ = await applier.apply(b, layoutFileID: "B.json")
        #expect(try session(model, h.system.mainDisplay.id).followed?.layoutFileID == "B.json")
        await applier.undoLastApply()
        #expect(h.system.windows.map(\.frame) == framesA)
        #expect(try session(model, h.system.mainDisplay.id).followed == nil)
        let undone = h.system.frameWriteCounts
        await applier.undoLastApply()
        #expect(h.system.frameWriteCounts == undone)
    }

    @Test func stopOnlyClearsFollowingAndRepeatsWithoutRevision() async throws {
        let h = ApplyHarness(); defer { h.close() }
        h.addWindow()
        let model = h.model(); defer { model.shutdown() }
        let applier = try #require(model.savedLayoutApplier); applier.observesKeyboard = false
        _ = await applier.apply(document(h), layoutFileID: "Work.json")
        model.handleApplicationActivation()
        #expect(model.followedSavedLayout?.layoutName == "Test")
        let original = try session(model, h.system.mainDisplay.id)
        let writes = h.system.frameWriteCounts
        let hadUndo = applier.hasUndo
        let history = try historyCounts(model, h.system.windows.map(\.id))
        model.stopFollowingSavedLayout()
        var expected = original; expected.endFollowing()
        #expect(try session(model, h.system.mainDisplay.id).followed == nil)
        #expect(model.followedSavedLayout == nil)
        #expect(h.system.frameWriteCounts == writes && applier.hasUndo == hadUndo)
        #expect(try historyCounts(model, h.system.windows.map(\.id)) == history)
        let stopped = try session(model, h.system.mainDisplay.id)
        #expect(stopped.mode == expected.mode && stopped.bentoState == expected.bentoState && stopped.windowIDs == expected.windowIDs)
        model.stopFollowingSavedLayout()
        #expect(try session(model, h.system.mainDisplay.id) == stopped)
        #expect(h.system.frameWriteCounts == writes)
        await applier.undoLastApply()
        #expect(model.activeMode(for: h.system.mainDisplay.id) == .manual)
    }

    @Test(arguments: [LayoutMode.bento, .tabbed]) func minimizeAndUnpreferredArrivalUseNormalPolicy(mode: LayoutMode) async throws {
        let h = ApplyHarness(); defer { h.close() }
        h.addWindow(id: "editor")
        h.addWindow("com.example.Browser", id: "browser", pid: 43)
        h.system.focusedID = .init(rawValue: "browser")
        let model = h.model(); defer { model.shutdown() }
        let applier = try #require(model.savedLayoutApplier); applier.observesKeyboard = false
        _ = await applier.apply(twoPanes(mode: mode), layoutFileID: "Homework.json")
        model.handleApplicationActivation()
        #expect(model.followedSavedLayout != nil)
        h.system.windows[0].isMinimized = true
        h.system.eventHandler?(.init(kind: .minimized, windowID: h.system.windows[0].id, processIdentifier: 42))
        try await sweep(model)
        #expect(try session(model, h.system.mainDisplay.id).followed == nil)
        #expect(model.followedSavedLayout == nil)
        try await repeatSweep(model, h, event: .init(kind: .minimized, windowID: h.system.windows[0].id, processIdentifier: 42))
        h.system.windows[0].isMinimized = false
        _ = await applier.apply(twoPanes(mode: mode), layoutFileID: "Homework.json")
        h.addWindow("com.example.Unlisted", id: "extra", pid: 44)
        h.system.eventHandler?(.init(kind: .created, windowID: h.system.windows.last!.id, processIdentifier: 44))
        try await sweep(model)
        let current = try session(model, h.system.mainDisplay.id)
        if mode == .bento {
            #expect(current.bentoState.root?.windowIDs.count == 3)
            #expect(current.followed == nil)
        } else {
            #expect(current.tabbedState?.windowIDs.count == 3)
            #expect(current.tabbedState?.paneID(containing: h.system.windows.last!.id) == current.tabbedState?.activePaneID)
        }
        #expect(h.system.requestedFrames[h.system.windows.last!.id]?.last == h.system.windows.last?.frame)
        try await repeatSweep(model, h)
    }

    @Test(arguments: ["repair", "preset", "float", "cancelled drag", "snap"])
    func explicitActionsEndOnlyAfterSuccess(action: String) async throws {
        let h = ApplyHarness(); defer { h.close() }
        h.addWindow()
        let mode: LayoutMode = ["preset", "float"].contains(action) ? .tabbed : .bento
        let model = h.model(); defer { model.shutdown() }
        let applier = try #require(model.savedLayoutApplier); applier.observesKeyboard = false
        _ = await applier.apply(twoPanes(mode: mode), layoutFileID: "Homework.json")
        model.handleApplicationActivation()
        try await sweep(model)
        let before = try #require(try session(model, h.system.mainDisplay.id).followed)
        switch action {
        case "repair": model.repairCurrentLayout()
        case "preset": model.performTabbed(.preset(.columns, grouping: .keepTabGroups))
        case "float": model.performTabbed(.float(h.system.windows[0].id))
        case "snap": model.perform(.leftHalf)
        default:
            #expect(model.completeBentoDrag(displayID: h.system.mainDisplay.id, sourceID: h.system.windows[0].id, outcome: .restore))
        }
        try #require(await waitFor { idle(model) })
        #expect(try session(model, h.system.mainDisplay.id).followed == (action == "cancelled drag" ? before : nil))
        try await repeatSweep(model, h)
        if action == "cancelled drag" {
            let writes = h.system.frameWriteCounts
            #expect(model.completeBentoDrag(displayID: h.system.mainDisplay.id, sourceID: h.system.windows[0].id, outcome: .restore))
            #expect(h.system.frameWriteCounts == writes)
        }
    }

    @Test(arguments: ["fit", "write", "cancel", "refused before write"])
    func unsuccessfulApplyKeepsFollowing(reason: String) async throws {
        let h = ApplyHarness(); defer { h.close() }
        h.addWindow()
        let model = h.model(); defer { model.shutdown() }
        let applier = try #require(model.savedLayoutApplier); applier.observesKeyboard = false
        var document = twoPanes(mode: .bento)
        _ = await applier.apply(document, layoutFileID: "A.json")
        let before = try #require(try session(model, h.system.mainDisplay.id).followed)
        let frames = h.system.windows.map(\.frame)
        document.name = "B"; document.keepForNewWindows = false
        document.layout = .split(axis: .horizontal, ratios: [0.5, 0.5], children: [.slot("left"), .slot("right")])
        switch reason {
        case "fit": h.system.windows[0].constraints.minimumSize = .init(width: 2000, height: 2000)
        case "write": h.system.ignoredFrameWriteWindowIDs = [h.system.windows[0].id]
        case "cancel":
            h.system.onFrameWrite = { _, _ in
                h.system.onFrameWrite = nil
                applier.cancel()
            }
        default:
            let commit = applier.commit
            applier.commit = { plan, desktop, snapshot, valid in
                h.system.windows[0].frame.origin.x += 50
                return await commit(plan, desktop, snapshot, valid)
            }
        }
        let result = await applier.apply(document, layoutFileID: "B.json")
        #expect(result.placed == 0 && !result.issues.isEmpty)
        #expect(try session(model, h.system.mainDisplay.id).followed == before)
        if reason != "refused before write" { #expect(h.system.windows.map(\.frame) == frames) }
        let revision = try session(model, h.system.mainDisplay.id).revision
        if reason == "cancel" { h.system.onFrameWrite = { _, _ in applier.cancel() } }
        _ = await applier.apply(document, layoutFileID: "B.json")
        #expect(try session(model, h.system.mainDisplay.id).followed == before)
        #expect(try session(model, h.system.mainDisplay.id).revision == revision)
    }

    @Test func offDoesNotFollowAndNonemptyRepeatRebuildsAnchors() async throws {
        let h = ApplyHarness(); defer { h.close() }
        h.addWindow(id: "original")
        let model = h.model(); defer { model.shutdown() }
        let applier = try #require(model.savedLayoutApplier); applier.observesKeyboard = false
        var document = twoPanes(mode: .bento); document.keepForNewWindows = false
        _ = await applier.apply(document, layoutFileID: "Work.json")
        #expect(try session(model, h.system.mainDisplay.id).followed == nil)
        let writes = h.system.frameWriteCounts, revision = try session(model, h.system.mainDisplay.id).revision
        _ = await applier.apply(document, layoutFileID: "Work.json")
        #expect(h.system.frameWriteCounts == writes)
        #expect(try session(model, h.system.mainDisplay.id).revision == revision)
        document.keepForNewWindows = true
        _ = await applier.apply(document, layoutFileID: "Work.json")
        h.system.windows = []
        h.addWindow(id: "replacement", pid: 44)
        _ = await applier.apply(document, layoutFileID: "Work.json")
        let followed = try #require(try session(model, h.system.mainDisplay.id).followed)
        #expect(followed.slots.first?.anchor == .adaptive(.window(.init(rawValue: "replacement"))))
        #expect(!followed.shape.anchors.contains(.adaptive(.window(.init(rawValue: "original")))))
        let after = try session(model, h.system.mainDisplay.id), afterWrites = h.system.frameWriteCounts
        _ = await applier.apply(document, layoutFileID: "Work.json")
        #expect(try session(model, h.system.mainDisplay.id) == after && h.system.frameWriteCounts == afterWrites)
    }
}

extension SavedLayoutFollowingTests {
    @Test(arguments: [false, true]) func staleAndBusyMetadataOnlyApplyAreRefused(turnOff: Bool) async throws {
        let h = ApplyHarness(); defer { h.close() }
        h.addWindow()
        let model = h.model(); defer { model.shutdown() }
        let applier = try #require(model.savedLayoutApplier); applier.observesKeyboard = false
        var document = twoPanes(mode: .tabbed); document.keepForNewWindows = turnOff
        _ = await applier.apply(document, layoutFileID: "Work.json")
        model.handleApplicationActivation()
        try await sweep(model)
        let before = try session(model, h.system.mainDisplay.id)
        let writes = h.system.frameWriteCounts
        let commit = applier.commit
        var release: CheckedContinuation<Void, Never>?
        defer { release?.resume() }
        applier.commit = { plan, desktop, snapshot, valid in
            await withCheckedContinuation { release = $0 }
            return await commit(plan, desktop, snapshot, valid)
        }
        document.keepForNewWindows = !turnOff
        let changed = document
        let task = Task { await applier.apply(changed, layoutFileID: "Work.json") }
        try #require(await waitFor { release != nil })
        _ = await applier.apply(changed, layoutFileID: "Work.json")
        #expect(applier.message == SavedLayoutApplier.applyingBusy)
        // A successful pane activation changes the revision while preserving following.
        let pane = try #require(model.activeTabbedState?.panes.last?.id)
        model.performTabbed(.activate(pane))
        let newer = try session(model, h.system.mainDisplay.id)
        #expect(newer.revision > before.revision && newer.followed == before.followed)
        release?.resume(); release = nil
        let result = await task.value
        #expect(result.placed == 0 && !result.issues.isEmpty)
        #expect(try session(model, h.system.mainDisplay.id).followed == before.followed)
        #expect(h.system.frameWriteCounts == writes && applier.lastRun?.offersUndo == false)
        let revision = try session(model, h.system.mainDisplay.id).revision
        let firstPane = try #require(model.activeTabbedState?.panes.first?.id)
        applier.commit = { plan, desktop, snapshot, valid in
            model.performTabbed(.activate(firstPane))
            return await commit(plan, desktop, snapshot, valid)
        }
        _ = await applier.apply(changed, layoutFileID: "Work.json")
        #expect(try session(model, h.system.mainDisplay.id).followed == before.followed)
        #expect(h.system.frameWriteCounts == writes)
        #expect(try session(model, h.system.mainDisplay.id).revision == revision + 1)
    }

    @Test func followingIsScopedToTheCurrentDesktopAndFocusedDisplay() async throws {
        let h = ApplyHarness(); defer { h.close() }
        h.addWindow(id: "first")
        h.system.focusedID = h.system.windows[0].id
        let model = h.model(); defer { model.shutdown() }
        let applier = try #require(model.savedLayoutApplier); applier.observesKeyboard = false
        _ = await applier.apply(twoPanes(mode: .bento), layoutFileID: "Work.json")
        model.handleApplicationActivation()
        let followed = try #require(model.followedSavedLayout)
        let firstSessionID = try session(model, h.system.mainDisplay.id).id
        h.arrive(2)
        #expect(model.followedSavedLayout == nil) // The cached session still belongs to desktop 1.
        h.addWindow("com.example.Browser", id: "desktop-two", pid: 43)
        h.system.focusedID = h.system.windows.last!.id
        model.setActiveMode(.manual)
        model.handleApplicationActivation()
        #expect(model.followedSavedLayout == nil)
        #expect(try store(model).allSessions(for: h.system.mainDisplay.id).first { $0.id == firstSessionID }?.followed == followed)
        let writes = h.system.frameWriteCounts
        model.stopFollowingSavedLayout()
        try await repeatSweep(model, h)
        #expect(h.system.frameWriteCounts == writes)
        h.arrive(1); h.system.focusedID = h.system.windows[0].id
        try await sweep(model)
        model.handleApplicationActivation()
        #expect(model.followedSavedLayout == followed)
        let otherArea = BTRect(x: 1000, y: 0, width: 1000, height: 800)
        let other = DisplaySnapshot(id: .init(rawValue: "other"), frame: otherArea, visibleFrame: otherArea)
        h.system.availableDisplays.append(other)
        h.system.desktopObservation?.currentSpaceByDisplay[other.id] = h.space(3)
        h.system.desktopObservation?.knownSpacesByDisplay[other.id] = [h.space(3)]
        h.addWindow("com.example.Browser", id: "other-display", pid: 44)
        h.system.windows[h.system.windows.count - 1].displayID = other.id
        h.system.windows[h.system.windows.count - 1].frame.origin.x += 1000
        h.system.desktopObservation?.windowMembership[h.system.windows.last!.id] = [h.space(3)]
        h.system.focusedID = h.system.windows.last!.id
        try await sweep(model)
        model.handleApplicationActivation()
        #expect(model.followedSavedLayout == nil)
        model.stopFollowingSavedLayout()
        #expect(try session(model, h.system.mainDisplay.id).followed == followed)
        try await repeatSweep(model, h)
    }

    @Test func groupPreferencesAreExpandedOnceAndRemainAValueSnapshot() async throws {
        let h = ApplyHarness(); defer { h.close() }
        h.addWindow()
        let groups = AppGroupsStore(directory: h.directory, catalog: {
            [.init(bundleIdentifier: "com.example.Browser", name: "Browser", url: URL(fileURLWithPath: "/fixture/Browser.app"))]
        }, defaultBrowserURL: { nil })
        try FileManager.default.createDirectory(at: h.directory, withIntermediateDirectories: true)
        try AppGroupsDocument(groups: [.init(name: "Web", apps: [.init(name: "Browser")])]).encode().write(to: groups.fileURL)
        let model = makeOffscreenModel(store: .init(fileURL: h.directory.appendingPathComponent("configuration.json")),
            system: h.system, appGroupsStore: groups)
        defer { model.shutdown() }
        model.primaryButtonIsPressed = { false }
        let applier = try #require(model.savedLayoutApplier); applier.observesKeyboard = false
        var document = twoPanes(mode: .bento)
        document.slots[1].prefer = [.group("Web")]
        _ = await applier.apply(document, layoutFileID: "Work.json")
        let followed = try #require(try session(model, h.system.mainDisplay.id).followed)
        #expect(followed.slots[1].preferences == ["com.example.Browser"])
        try groups.save(.init(groups: [.init(name: "Web", apps: [.init(bundleID: "com.example.Changed")])]))
        #expect(try session(model, h.system.mainDisplay.id).followed == followed)
        h.addWindow("com.example.Browser", id: "late-browser", pid: 43)
        h.system.eventHandler?(.init(kind: .created, windowID: h.system.windows.last!.id, processIdentifier: 43))
        try await sweep(model)
        #expect(h.system.windows.last?.frame.minX ?? 0 > 500)
        #expect(try session(model, h.system.mainDisplay.id).followed?.slots[1].preferences == ["com.example.Browser"])
        try await repeatSweep(model, h)
    }

    @Test func automaticTriggerStartsFollowingWithTheLibraryFileIdentity() async throws {
        let h = ApplyHarness(); defer { h.close() }
        h.addWindow()
        let model = h.model(); defer { model.shutdown() }
        let applier = try #require(model.savedLayoutApplier); applier.observesKeyboard = false
        let display = h.system.mainDisplay.id
        let fingerprint = DisplayFingerprint(uuid: "MAIN", vendor: 1, model: 1, serial: 1,
            builtIn: true, name: "Fixture", frame: h.system.mainDisplay.frame)
        let runtime = DisplayTriggerRuntime(applier: applier, initial: [])
        defer { runtime.stop() }
        runtime.observesInput = false
        runtime.triggers = { [.init(layoutFile: "Work.json", enabled: true, alsoAfterWake: false, displays: [fingerprint], target: 0)] }
        runtime.liveDisplays = { [.init(id: display, fingerprint: fingerprint)] }
        let document = document(h)
        runtime.loadLayout = { _ in document }
        runtime.observeFrames = { _ in Dictionary(uniqueKeysWithValues: h.system.windows.map { ($0.id, $0.frame) }) }
        var uptime = 1000.0
        runtime.uptime = { uptime }
        runtime.sleep = { duration in
            uptime += Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
            await Task.yield()
        }
        runtime.displaysChanged()
        try #require(await waitFor { runtime.isIdle && runtime.runs["Work.json"] != nil })
        #expect(try session(model, display).followed?.layoutFileID == "Work.json")
        #expect(h.system.windows[0].frame == h.system.mainDisplay.visibleFrame)
        let writes = h.system.frameWriteCounts, revision = try session(model, display).revision
        runtime.displaysChanged()
        for _ in 0..<20 { await Task.yield() }
        #expect(h.system.frameWriteCounts == writes)
        #expect(try session(model, display).revision == revision)
    }
}

extension SavedLayoutFollowingTests {
    @Test func restartAfterCloseAndStopReplacesVacancyIdentityWithoutMovingWindows() async throws {
        let h = ApplyHarness(); defer { h.close() }
        h.addWindow(id: "editor"); h.addWindow("com.example.Browser", id: "browser", pid: 43)
        h.system.focusedID = h.system.windows[1].id
        let model = h.model(); defer { model.shutdown() }
        let applier = try #require(model.savedLayoutApplier); applier.observesKeyboard = false
        let document = twoPanes(mode: .bento)
        _ = await applier.apply(document, layoutFileID: "Work.json")
        let closed = h.system.windows.removeFirst()
        h.system.eventHandler?(.init(kind: .destroyed, windowID: closed.id, processIdentifier: closed.processIdentifier))
        try await sweep(model)
        model.handleApplicationActivation()
        let stillFollowing = try session(model, h.system.mainDisplay.id)
        let settledWrites = h.system.frameWriteCounts
        _ = await applier.apply(document, layoutFileID: "Work.json")
        #expect(try session(model, h.system.mainDisplay.id) == stillFollowing)
        #expect(h.system.frameWriteCounts == settledWrites)
        model.stopFollowingSavedLayout()
        let before = try session(model, h.system.mainDisplay.id)
        #expect(before.followed == nil)
        let writes = h.system.frameWriteCounts
        _ = await applier.apply(document, layoutFileID: "Work.json")
        #expect(applier.lastPlan?.isEmpty == true)
        let after = try session(model, h.system.mainDisplay.id)
        let followed = try #require(after.followed)
        #expect(applier.followingFailureCount == 0 && applier.followingIssue == nil)
        func vacancies(_ node: BentoNode?) -> [UUID] {
            switch node {
            case let .vacant(id): [id]
            case let .partition(partition): partition.children.flatMap { vacancies($0) }
            default: []
            }
        }
        #expect(followed.shape.anchors.contains { anchor in
            if case let .adaptive(.vacancy(id)) = anchor { return vacancies(after.bentoState.root).contains(id) }
            return false
        })
        #expect(h.system.frameWriteCounts == writes && applier.lastRun?.offersUndo == false)
        _ = await applier.apply(document, layoutFileID: "Work.json")
        #expect(try session(model, h.system.mainDisplay.id) == after)
        #expect(h.system.frameWriteCounts == writes)
    }

    @Test(arguments: [false, true]) func applyAcceptsBookkeepingSweepButRefusesChangedTree(changesTree: Bool) async throws {
        let h = ApplyHarness(); defer { h.close() }
        h.addWindow()
        let model = h.model(); defer { model.shutdown() }
        let applier = try #require(model.savedLayoutApplier); applier.observesKeyboard = false
        let document = twoPanes(mode: .bento)
        _ = await applier.apply(document, layoutFileID: "Work.json")
        let before = try session(model, h.system.mainDisplay.id)
        let snapshot = applier.snapshot
        var inventories = 0
        var changedSession: LayoutSession?
        var writesBeforeCommit: [WindowID: Int] = [:]
        applier.snapshot = {
            let result = try snapshot()
            inventories += 1
            if inventories == 2 {
                if changesTree { model.perform(.topHalf) }
                else { model.watchdog() }
                changedSession = try self.session(model, h.system.mainDisplay.id)
                writesBeforeCommit = h.system.frameWriteCounts
            }
            return result
        }
        var replacement = document; replacement.keepForNewWindows = false
        let result = await applier.apply(replacement, layoutFileID: "Work.json")
        let changed = try #require(changedSession)
        #expect(changed.revision > before.revision)
        if changesTree {
            #expect(changed.bentoState != before.bentoState)
            #expect(result.placed == 0 && !result.issues.isEmpty)
            #expect(try session(model, h.system.mainDisplay.id).bentoState == changed.bentoState)
        } else {
            #expect(changed.bentoState == before.bentoState && changed.followed == before.followed)
            #expect(result.issues.allSatisfy { $0.slotID != nil }, "\(result.issues)")
            #expect(result.placed == 1)
            #expect(try session(model, h.system.mainDisplay.id).followed == nil)
        }
        #expect(h.system.frameWriteCounts == writesBeforeCommit)
        try await sweep(model)
        try await repeatSweep(model, h)
    }
}

extension SavedLayoutFollowingTests {
    @Test func unexpectedFollowingFailureKeepsTheSuccessfulPlacementAndReportsIt() async throws {
        let h = ApplyHarness(); defer { h.close() }
        h.addWindow()
        let model = h.model(); defer { model.shutdown() }
        let applier = try #require(model.savedLayoutApplier); applier.observesKeyboard = false
        let commit = applier.commit
        var invalid = document(h); invalid.keepForNewWindows = false
        applier.commit = { plan, desktop, snapshot, valid in
            var snapshot = snapshot
            snapshot.followingIntent = .start(layoutFileID: "Work.json", document: invalid, expandedPreferences: [:])
            return await commit(plan, desktop, snapshot, valid)
        }
        let result = await applier.apply(document(h), layoutFileID: "Work.json")
        #expect(result.placed == 1)
        #expect(result.issues.map(\.message).contains("This layout could not keep following new windows."))
        #expect(h.system.windows[0].frame == h.system.mainDisplay.visibleFrame)
        #expect(try session(model, h.system.mainDisplay.id).followed == nil)
        #expect(model.activeMode(for: h.system.mainDisplay.id) == .bento)
        #expect(applier.followingFailureCount == 1 && applier.hasUndo)
        #expect(applier.lastRun?.planPresentation?.issues.map(\.message).contains("This layout could not keep following new windows.") == true)
        applier.commit = commit
        await applier.undoLastApply()
        #expect(model.activeMode(for: h.system.mainDisplay.id) == .manual)
        let writes = h.system.frameWriteCounts
        await applier.undoLastApply()
        #expect(h.system.frameWriteCounts == writes)
    }
}

extension SavedLayoutFollowingTests {
    @Test func refusedPresetAndInvalidFloatKeepFollowing() async throws {
        let h = ApplyHarness(); defer { h.close() }
        h.addWindow(id: "editor"); h.addWindow("com.example.Browser", id: "browser", pid: 43)
        h.system.focusedID = h.system.windows[0].id
        let model = h.model(); defer { model.shutdown() }
        let applier = try #require(model.savedLayoutApplier); applier.observesKeyboard = false
        _ = await applier.apply(twoPanes(mode: .tabbed), layoutFileID: "Work.json")
        model.handleApplicationActivation()
        try await sweep(model)
        let before = try session(model, h.system.mainDisplay.id)
        h.system.ignoredFrameWriteWindowIDs = Set(h.system.windows.map(\.id))
        for _ in 0..<2 {
            model.performTabbed(.preset(.rows, grouping: .keepTabGroups))
            try #require(await waitFor { idle(model) })
            #expect(try session(model, h.system.mainDisplay.id) == before)
        }
        let writes = h.system.frameWriteCounts
        for _ in 0..<2 {
            model.performTabbed(.float(.init(rawValue: "not-on-this-desktop")))
            #expect(try session(model, h.system.mainDisplay.id) == before)
            #expect(h.system.frameWriteCounts == writes)
        }
    }
}

extension SavedLayoutFollowingTests {
    @Test(arguments: [false, true]) func unsavedFollowingNoticeRequiresSave(keep: Bool) async throws {
        let h = ApplyHarness(); defer { h.close() }
        h.addWindow()
        let model = h.model(); defer { model.shutdown() }
        let applier = try #require(model.savedLayoutApplier); applier.observesKeyboard = false
        var document = document(h); document.keepForNewWindows = keep
        _ = await applier.apply(document)
        let notice = "Save this layout to keep following new windows."
        let run = try #require(applier.lastRun)
        #expect(run.presentation.issues.filter { $0.message == notice }.count == (keep ? 1 : 0))
        #expect(run.presentation.pillDetail.contains(notice) == keep)
        if keep {
            var emptyDetailRun = run
            var plan = try #require(run.planPresentation)
            plan.summary = ""; plan.alreadyArranged = false
            emptyDetailRun.planPresentation = plan
            #expect(emptyDetailRun.presentation.pillDetail == notice)
        }
        #expect(h.system.windows[0].frame == h.system.mainDisplay.visibleFrame)
        #expect(try session(model, h.system.mainDisplay.id).followed == nil)
        _ = await applier.apply(document, layoutFileID: "Saved.json")
        #expect(applier.lastRun?.presentation.issues.contains { $0.message == notice } == false)
        #expect(applier.lastRun?.presentation.pillDetail.contains(notice) == false)
    }

    @Test func unsavedDraftAppliesWithoutStartingFollowing() async throws {
        let h = ApplyHarness(); defer { h.close() }
        h.addWindow()
        let model = h.model(); defer { model.shutdown() }
        let applier = try #require(model.savedLayoutApplier); applier.observesKeyboard = false
        let document = document(h)
        _ = await applier.apply(document)
        #expect(h.system.windows[0].frame == h.system.mainDisplay.visibleFrame)
        #expect(try session(model, h.system.mainDisplay.id).followed == nil)
        #expect(applier.followingFailureCount == 0 && applier.followingIssue == nil)
        let current = try session(model, h.system.mainDisplay.id), writes = h.system.frameWriteCounts
        _ = await applier.apply(document)
        #expect(try session(model, h.system.mainDisplay.id) == current)
        #expect(h.system.frameWriteCounts == writes)
        _ = await applier.apply(document, layoutFileID: "Saved.json")
        model.handleApplicationActivation()
        #expect(model.followedSavedLayout != nil)
        let inventories = h.system.completeSweepCount, focusReads = h.system.focusedWindowReadCount
        for _ in 0..<20 { _ = SavedLayoutPanelSection(model: model).body }
        #expect(h.system.completeSweepCount == inventories && h.system.focusedWindowReadCount == focusReads)
        model.stopFollowingSavedLayout()
        #expect(model.followedSavedLayout == nil)
        for _ in 0..<20 { _ = SavedLayoutPanelSection(model: model).body }
        #expect(h.system.completeSweepCount == inventories && h.system.focusedWindowReadCount == focusReads)
    }
}

extension SavedLayoutFollowingTests {
    @Test(arguments: [false, true]) func treeChangingSweepPreservesOrdinaryApplyBehavior(keepForNewWindows: Bool) async throws {
        let h = ApplyHarness(); defer { h.close() }
        h.addWindow(id: "editor")
        let model = h.model(); defer { model.shutdown() }
        let applier = try #require(model.savedLayoutApplier); applier.observesKeyboard = false
        var document = twoPanes(mode: .bento); document.keepForNewWindows = false
        _ = await applier.apply(document, layoutFileID: "Work.json")
        let display = h.system.mainDisplay.id
        let before = try session(model, display)
        let editorFrame = h.system.windows[0].frame
        // Hold an inventory read while a real arrival sweep fills the empty pane.
        // Deliver it after settlement, so readiness and participant frames remain valid.
        let planningSnapshot = try applier.snapshot()
        h.addWindow("com.example.Browser", id: "arrival", pid: 43)
        h.system.eventHandler?(.init(kind: .created, windowID: h.system.windows.last!.id, processIdentifier: 43))
        try await sweep(model)
        let changed = try session(model, display)
        try #require(changed.bentoState != before.bentoState && changed.followed == nil)
        #expect(changed.bentoState.root?.windowIDs.count == 2)
        #expect(h.system.windows[0].frame == editorFrame)
        let writes = h.system.frameWriteCounts
        let liveSnapshot = applier.snapshot
        applier.snapshot = { planningSnapshot }
        document.keepForNewWindows = keepForNewWindows
        document.layout = .split(axis: .horizontal, ratios: [0.5, 0.5], children: [.slot("left"), .slot("right")])
        let result = await applier.apply(document, layoutFileID: "Work.json")
        let current = try session(model, display)
        if keepForNewWindows {
            #expect(result.placed == 0 && !result.issues.isEmpty)
            #expect(current == changed && h.system.frameWriteCounts == writes)
        } else {
            // The base layout accepts Apply and replaces the current tree after planning.
            #expect(result.placed == 1, "\(result.issues)")
            #expect(result.issues.allSatisfy { $0.slotID != nil }, "\(result.issues)")
            #expect(current.bentoState != changed.bentoState && current.followed == nil)
            #expect(h.system.windows[0].frame == BTRect(x: 0, y: 0, width: 1000, height: 400))
            #expect(h.system.requestedFrames[h.system.windows[0].id]?.last == h.system.windows[0].frame)
        }
        let committed = try session(model, display), committedWrites = h.system.frameWriteCounts
        _ = await applier.apply(document, layoutFileID: "Work.json")
        #expect(try session(model, display) == committed)
        #expect(h.system.frameWriteCounts == committedWrites)
        applier.snapshot = liveSnapshot
        try await sweep(model)
        try await repeatSweep(model, h)
    }
}
