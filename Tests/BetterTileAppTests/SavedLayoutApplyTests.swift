import AppKit
import BetterTileCore
import BetterTileTestSupport
@testable import BetterTileMacOS
import Foundation
import Testing
@testable import BetterTileApp

/// Three desktops on the main display. `current` is the one the user sees.
@MainActor final class ApplyHarness {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SavedLayoutApply-" + UUID().uuidString)
    let system: FakeAppWindowSystem
    let coordinator: WindowCoordinator
    var applier: SavedLayoutApplier!
    var sessions: [DisplayID: SavedLayoutSession] = [:]
    var plans: [SavedLayoutApplyPlan] = []
    var commits: [UInt64] = []
    var commitWindowIDs: [Set<WindowID>] = []
    var commitAssignments: [[String: WindowID]] = []
    var lastUnmatched: [WindowID] = []
    var usesAllDisplays = false
    var stable = true
    var ready = true
    var generation = 0
    var elapsed: TimeInterval = 1000
    var refusedCommit = false
    var suspended = false
    var onCommit: (() -> Void)?
    var afterCommit: (() -> Void)?
    var current = 1

    init(system: FakeAppWindowSystem = FakeAppWindowSystem()) {
        self.system = system
        coordinator = WindowCoordinator(system: system, clock: system.clock)
        system.windows = []
        updateObservation()
        applier = SavedLayoutApplier(snapshot: { [unowned self] in self.snapshot() },
            commit: { [unowned self] plan, desktop, state, valid in
                self.plans.append(plan)
                self.commitWindowIDs.append(Set(state.windows.map(\.id)))
                self.commitAssignments.append(plan.assignments)
                self.onCommit?()
                guard !self.refusedCommit, valid() else { return false }
                let outcome: WindowMutationOutcome = plan.placements.isEmpty ? .applied : self.coordinator.applyPlacements(plan.placements,
                    displayDestinations: state.requestedTransfers.mapValues { $0.destination.displayID }, validating: valid)
                guard outcome.isApplied else { return false }
                self.lastUnmatched = plan.unmatchedWindowIDs
                self.sessions[desktop.displayID] = plan.targetSession
                self.commits.append(desktop.spaceID.rawValue)
                self.afterCommit?()
                return true
            })
        applier.observesKeyboard = false

        applier.uptime = { [unowned self] in self.elapsed }
        applier.application = { id in .init(bundleIdentifier: id, name: id == "com.apple.Safari" ? "Safari" : id,
                                            url: URL(fileURLWithPath: "/fixture/\(id).app")) }


    }

    func space(_ number: Int) -> NativeSpaceID { .init(rawValue: UInt64(number)) }

    func updateObservation() {
        system.desktopObservation = NativeDesktopObservation(
            currentSpaceByDisplay: [system.mainDisplay.id: space(current)],
            knownSpacesByDisplay: [system.mainDisplay.id: Set([space(1), space(2), space(3)])],
            windowMembership: system.desktopObservation?.windowMembership ?? [:])
    }
    func arrive(_ number: Int) { current = number; generation += 1; updateObservation() }
    func addWindow(_ bundleID: String = "com.example.Editor", id: String = "window", pid: Int32 = 42, desktop: Int? = nil) {
        system.windows.append(WindowSnapshot(id: .init(rawValue: id), processIdentifier: pid, bundleIdentifier: bundleID,
            frame: .init(x: 100, y: 100, width: 400, height: 300), displayID: system.mainDisplay.id))
        system.desktopObservation?.windowMembership[.init(rawValue: id)] = [space(desktop ?? current)]
    }
    func snapshot() -> SavedLayoutApplySnapshot {
        let observation = system.desktopObservation!
        let visible = usesAllDisplays ? observation.windowsOnCurrentSpaces(system.windows)
            : system.windows.filter { observation.windowMembership[$0.id] == [observation.currentSpace(on: system.mainDisplay.id)!] }
        return .init(observation: observation, displays: usesAllDisplays ? system.availableDisplays : [system.mainDisplay], windows: visible,
            knownWindows: system.windows, sessions: sessions, generation: generation, isStable: stable,
            readyDisplays: ready ? Set((usesAllDisplays ? system.availableDisplays : [system.mainDisplay]).map(\.id)) : [],
            suspendedDisplays: suspended ? [system.mainDisplay.id] : [],
            stackingOrder: system.stackingOrder(for: visible, excluding: []))
    }
    func document(_ bundleID: String = "com.example.Editor", mode: LayoutMode = .bento) -> SavedLayoutDocument {
        if mode == .tabbed {
            return .init(name: "Test", mode: .tabbed, layout: .group("group"), slots: [.init(id: "slot", bundleID: bundleID)],
                         groups: [.init(id: "group", slots: ["slot"], selected: "slot")])
        }
        return .init(name: "Test", mode: .bento, layout: .slot("slot"), slots: [.init(id: "slot", bundleID: bundleID)])
    }
    func model() -> BetterTileModel {
        let model = makeOffscreenModel(store: .init(fileURL: directory.appendingPathComponent("configuration.json")),
                        system: system, startRuntime: false)
        // The fake window system owns input state, independent of the user's pointer.
        model.primaryButtonIsPressed = { false }
        return model
    }
    func close() { applier.stop(); try? FileManager.default.removeItem(at: directory) }
}

@Test(.appTestApplication) @MainActor func savedLayoutApplyReusesCurrentWindowAndUndoRestoresFrames() async {
    let h = ApplyHarness()
    defer { h.close() }
    h.addWindow()
    let baseline = h.system.windows[0].frame
    let result = await h.applier.apply(h.document())
    #expect(result.placed == 1)
    #expect(result.issues.isEmpty)
    #expect(h.system.windows[0].frame == h.system.mainDisplay.visibleFrame)
    await h.applier.undoLastApply()
    #expect(h.system.windows[0].frame == baseline)
    #expect(!h.applier.canUndo)
}

@Test(.appTestApplication, arguments: [LayoutMode.bento, .tabbed]) @MainActor
func savedLayoutModelCommitsAndUndoesThroughCoordinator(mode: LayoutMode) async throws {
    let h = ApplyHarness()
    defer { h.close() }
    h.addWindow()
    let model = makeOffscreenModel(store: .init(fileURL: h.directory.appendingPathComponent("configuration.json")),
                               system: h.system, startRuntime: false)
    defer { model.shutdown() }
    let applier = try #require(model.savedLayoutApplier)
    applier.observesKeyboard = false
    let baseline = h.system.windows[0].frame
    let result = await applier.apply(h.document(mode: mode))
    #expect(result.issues.isEmpty)
    #expect(result.placed == 1)
    #expect(h.system.windows[0].frame != baseline)
    await applier.undoLastApply()
    #expect(h.system.windows[0].frame == baseline)
}

@Test(.appTestApplication) @MainActor func savedLayoutFitFailureWritesNothing() async {
    let h = ApplyHarness()
    defer { h.close() }
    h.addWindow()
    h.system.windows[0].constraints.minimumSize = .init(width: 2000, height: 1000)
    let result = await h.applier.apply(h.document())
    #expect(result.placed == 0)
    #expect(result.issues.first?.message.contains("cannot fit") == true)
    #expect(h.system.requestedFrames.isEmpty)
}

@Test(.appTestApplication) @MainActor func savedLayoutUnknownMembershipUsesPublicVisibleWindowsAndRejectsStickyWindows() async {
    let h = ApplyHarness()
    defer { h.close() }
    h.addWindow()
    h.system.desktopObservation?.windowMembership = [:]
    h.applier.snapshot = {
        var snapshot = h.snapshot()
        snapshot.windows = h.system.windows
        return snapshot
    }
    let unknown = await h.applier.apply(h.document())
    #expect(unknown.placed == 1)
    h.system.desktopObservation?.windowMembership[h.system.windows[0].id] = Set([h.space(1), h.space(2)])
    h.applier.application = { _ in nil }
    let sticky = await h.applier.apply(h.document())
    #expect(sticky.placed == 0)
}

@Test(.appTestApplication) @MainActor func savedLayoutModelRollsBackRejectedPlacement() async throws {
    let h = ApplyHarness()
    defer { h.close() }
    h.addWindow()
    let baseline = h.system.windows[0].frame
    h.system.failedFrameWriteNumbers[h.system.windows[0].id] = [1]
    let model = makeOffscreenModel(store: .init(fileURL: h.directory.appendingPathComponent("configuration.json")),
                               system: h.system, startRuntime: false)
    defer { model.shutdown() }
    let applier = try #require(model.savedLayoutApplier)
    applier.observesKeyboard = false
    let result = await applier.apply(h.document())
    #expect(!result.issues.isEmpty)
    #expect(h.system.windows[0].frame == baseline)
    #expect(model.activeMode(for: h.system.mainDisplay.id) == .manual)
}

@Test(.appTestApplication) @MainActor func savedLayoutUndoKeepsNewWindowsOutsideTheRestoredLayout() async {
    let h = ApplyHarness()
    defer { h.close() }
    h.addWindow()
    h.system.windows[0].frame = h.system.mainDisplay.visibleFrame
    let originalID = h.system.windows[0].id
    let previous = BentoLayoutState(root: .leaf(originalID))
    h.sessions[h.system.mainDisplay.id] = .bento(previous)
    let document = SavedLayoutDocument(name: "Two apps", mode: .bento,
        layout: .split(axis: .vertical, ratios: [0.5, 0.5], children: [.slot("one"), .slot("two")]),
        slots: [.init(id: "one", bundleID: "com.example.Editor"), .init(id: "two", bundleID: "com.apple.Safari")])
    h.addWindow("com.apple.Safari", id: "additional-existing")
    let result = await h.applier.apply(document)
    #expect(result.placed == 2)
    await h.applier.undoLastApply()
    #expect(h.lastUnmatched == [WindowID(rawValue: "additional-existing")])
    #expect(h.system.windows.count == 2)
    #expect(h.system.windows[0].frame == h.system.mainDisplay.visibleFrame)
    #expect(h.sessions[h.system.mainDisplay.id] == .bento(previous))
}

@Test(.appTestApplication) @MainActor func savedLayoutCancelledSettlementRestoresOrProvidesUndo() async throws {
    let h = ApplyHarness()
    defer { h.close() }
    h.addWindow()
    let model = makeOffscreenModel(store: .init(fileURL: h.directory.appendingPathComponent("configuration.json")),
                               system: h.system, startRuntime: false)
    defer { model.shutdown() }
    let applier = try #require(model.savedLayoutApplier)
    applier.observesKeyboard = false
    let baseline = h.system.windows[0].frame
    h.system.onFrameWrite = { _, _ in
        h.system.onFrameWrite = nil
        Task { @MainActor in applier.cancel() }
    }
    let result = await applier.apply(h.document())
    #expect(!result.issues.isEmpty)
    #expect(h.system.windows[0].frame == baseline || applier.canUndo)
    #expect(model.activeMode(for: h.system.mainDisplay.id) == .manual)
}

@Test(.appTestApplication) @MainActor func savedLayoutWindowLeavingDesktopDuringPreflightMustNotMove() async throws {
    let h = ApplyHarness()
    defer { h.close() }
    h.addWindow()
    let model = makeOffscreenModel(store: .init(fileURL: h.directory.appendingPathComponent("configuration.json")),
                               system: h.system, startRuntime: false)
    defer { model.shutdown() }
    let applier = try #require(model.savedLayoutApplier)
    applier.observesKeyboard = false
    let id = h.system.windows[0].id
    let baseline = h.system.windows[0].frame
    h.system.onWindowSnapshots = {
        h.system.onWindowSnapshots = nil
        h.system.desktopObservation?.windowMembership[id] = [h.space(2)]
        h.system.offscreenWindowIDs.insert(id)
    }
    _ = await applier.apply(h.document())
    #expect(h.system.requestedFrames[id, default: []].isEmpty)
    #expect(h.system.windows[0].frame == baseline)
}

@Test(.appTestApplication, arguments: [false, true]) @MainActor func savedLayoutUndoFromTabbedRestoresNewWindowFrame(refuseRestore: Bool) async throws {
    let h = ApplyHarness()
    defer { h.close() }
    h.addWindow()
    let model = makeOffscreenModel(store: .init(fileURL: h.directory.appendingPathComponent("configuration.json")),
                               system: h.system, startRuntime: false)
    defer { model.shutdown() }
    model.primaryButtonIsPressed = { false }
    let applier = try #require(model.savedLayoutApplier)
    applier.observesKeyboard = false
    applier.application = h.applier.application

    let initial = await applier.apply(h.document(mode: .tabbed))
    try #require(initial.issues.isEmpty)
    let document = SavedLayoutDocument(name: "Two apps", mode: .bento,
        layout: .split(axis: .vertical, ratios: [0.5, 0.5], children: [.slot("one"), .slot("two")]),
        slots: [.init(id: "one", bundleID: "com.example.Editor"), .init(id: "two", bundleID: "com.apple.Safari")])
    h.addWindow("com.apple.Safari", id: "additional-existing")
    let result = await applier.apply(document)
    try #require(result.placed == 2)
    if refuseRestore {
        let id = h.system.windows[1].id
        let frames = h.system.windows.map(\.frame)
        h.system.failedFrameWriteNumbers[id] = [h.system.frameWriteCounts[id, default: 0] + 1]
        await applier.undoLastApply()
        #expect(applier.canUndo)
        #expect(h.system.windows.map(\.frame) == frames)
        #expect(model.activeMode(for: h.system.mainDisplay.id) == .bento)
        h.system.failedFrameWriteNumbers = [:]
    }
    await applier.undoLastApply()
    #expect(h.system.windows[1].frame == BTRect(x: 100, y: 100, width: 400, height: 300))
    #expect(model.activeMode(for: h.system.mainDisplay.id) == .tabbed)
}

@Test(.appTestApplication, arguments: ["membership", "sticky", "display", "process", "rule"], [false, true]) @MainActor
func savedLayoutParticipantChangesRejectApplyAndUndo(change: String, undo: Bool) async throws {
    let h = ApplyHarness()
    defer { h.close() }
    h.addWindow()
    let model = makeOffscreenModel(store: .init(fileURL: h.directory.appendingPathComponent("configuration.json")),
                               system: h.system, startRuntime: false)
    defer { model.shutdown() }
    let applier = try #require(model.savedLayoutApplier)
    applier.observesKeyboard = false
    if undo { _ = await applier.apply(h.document()) }
    let id = h.system.windows[0].id
    let writes = h.system.frameWriteCounts
    h.system.onWindowSnapshots = {
        h.system.onWindowSnapshots = nil
        switch change {
        case "membership": h.system.desktopObservation?.windowMembership[id] = [h.space(2)]
        case "sticky": h.system.desktopObservation?.windowMembership[id] = Set([h.space(1), h.space(2)])
        case "display":
            let other = DisplayID(rawValue: "other")
            h.system.windows[0].displayID = other
            // A completed display move changes native membership too. Keeping
            // the old membership would classify this window on its old display.
            h.system.desktopObservation?.currentSpaceByDisplay[other] = h.space(99)
            h.system.desktopObservation?.windowMembership[id] = [h.space(99)]
        case "process": h.system.windows[0].processIdentifier = 999
        default: model.configuration.applicationRules.set(.ignoreEverywhere, for: "com.example.Editor")
        }
    }
    if undo { await applier.undoLastApply() } else { _ = await applier.apply(h.document()) }
    #expect(h.system.frameWriteCounts == writes)
    if undo { #expect(applier.canUndo) }
}

@Test(.appTestApplication, arguments: [false, true]) @MainActor
func savedLayoutCancelledSettlementRetainsRecoveryWhenRestoreIsUnsafe(switchDesktop: Bool) async throws {
    let h = ApplyHarness()
    defer { h.close() }
    h.addWindow()
    let model = makeOffscreenModel(store: .init(fileURL: h.directory.appendingPathComponent("configuration.json")),
                               system: h.system, startRuntime: false)
    defer { model.shutdown() }
    model.primaryButtonIsPressed = { false }
    let applier = try #require(model.savedLayoutApplier)
    applier.observesKeyboard = false
    let id = h.system.windows[0].id
    let baseline = h.system.windows[0].frame
    h.system.onFrameWrite = { _, _ in
        h.system.onFrameWrite = nil
        Task { @MainActor in
            applier.cancel()
            if switchDesktop { h.arrive(2); h.system.offscreenWindowIDs.insert(id) }
            else { h.system.failedFrameWriteNumbers[id] = [2] }
        }
    }
    _ = await applier.apply(h.document())
    #expect(applier.canUndo)
    let store = try #require(Mirror(reflecting: model).children.first { $0.label?.hasSuffix("sessionStore") == true }?.value as? LayoutSessionStore)
    #expect(store.allSessions(for: h.system.mainDisplay.id).first { $0.nativeSpaceID == h.space(1) }?.automaticWritesSuspended == true)
    if switchDesktop { #expect(h.system.frameWriteCounts[id] == 1) }
    h.arrive(1); h.system.offscreenWindowIDs.remove(id)
    h.system.failedFrameWriteNumbers = [:]
    await applier.undoLastApply()
    #expect(h.system.windows[0].frame == baseline)
    #expect(!applier.canUndo)
}

@Test(.appTestApplication) @MainActor func savedLayoutSettlementDoesNotRetryAWindowThatLeavesDesktop() async throws {
    let h = ApplyHarness()
    defer { h.close() }
    h.addWindow()
    let model = makeOffscreenModel(store: .init(fileURL: h.directory.appendingPathComponent("configuration.json")),
                               system: h.system, startRuntime: false)
    defer { model.shutdown() }
    let applier = try #require(model.savedLayoutApplier)
    applier.observesKeyboard = false
    let id = h.system.windows[0].id
    h.system.onWindowSnapshots = {
        guard h.system.frameWriteCounts[id, default: 0] > 0 else { return }
        h.system.onWindowSnapshots = nil
        h.system.desktopObservation?.windowMembership[id] = [h.space(2)]
        h.system.offscreenWindowIDs.insert(id)
    }
    _ = await applier.apply(h.document())
    #expect(h.system.frameWriteCounts[id] == 1)
    #expect(applier.canUndo)
}

@Test(.appTestApplication) @MainActor func savedLayoutCancelledSettlementPreservesANewerManualMove() async throws {
    let h = ApplyHarness()
    defer { h.close() }
    h.addWindow()
    let model = makeOffscreenModel(store: .init(fileURL: h.directory.appendingPathComponent("configuration.json")),
                               system: h.system, startRuntime: false)
    defer { model.shutdown() }
    let applier = try #require(model.savedLayoutApplier)
    applier.observesKeyboard = false
    let manual = BTRect(x: 30, y: 30, width: 800, height: 600)
    let id = h.system.windows[0].id
    h.system.onFrameWrite = { _, _ in
        h.system.onFrameWrite = nil
        Task { @MainActor in
            applier.cancel()
            h.system.windows[0].frame = manual // A user write does not allocate a coordinator generation.
        }
    }
    _ = await applier.apply(h.document())
    #expect(h.system.windows[0].frame == manual)
    #expect(h.system.frameWriteCounts[id] == 1)
    #expect(applier.canUndo)
}

@Test(.appTestApplication) @MainActor func savedLayoutSettlementMustValidateAnInitiallyUnchangedParticipant() async throws {
    let h = ApplyHarness()
    defer { h.close() }
    h.addWindow(id: "already-fitted")
    h.addWindow("com.apple.Safari", id: "needs-placement", pid: 43)
    let id = h.system.windows[0].id
    h.system.windows[0].frame = BTRect(x: 0, y: 0, width: 500, height: 800)
    let model = makeOffscreenModel(store: .init(fileURL: h.directory.appendingPathComponent("configuration.json")),
                               system: h.system, startRuntime: false)
    defer { model.shutdown() }
    model.primaryButtonIsPressed = { false }
    let applier = try #require(model.savedLayoutApplier)
    applier.observesKeyboard = false
    let offDesktopFrame = BTRect(x: 100, y: 100, width: 400, height: 300)
    h.system.onFrameWrite = { written, _ in
        guard written != id else { return }
        h.system.onFrameWrite = nil
        h.system.desktopObservation?.windowMembership[id] = [h.space(2)]
        h.system.offscreenWindowIDs.insert(id)
        h.system.windows[0].frame = offDesktopFrame
    }
    let document = SavedLayoutDocument(name: "Two apps", mode: .bento,
        layout: .split(axis: .vertical, ratios: [0.5, 0.5], children: [.slot("one"), .slot("two")]),
        slots: [.init(id: "one", bundleID: "com.example.Editor"), .init(id: "two", bundleID: "com.apple.Safari")])
    _ = await applier.apply(document)
    #expect(h.system.frameWriteCounts[id, default: 0] == 0)
    #expect(h.system.windows[0].frame == offDesktopFrame)
}

@Test(.appTestApplication) @MainActor func savedLayoutUndoSettlementMustNotWriteAnUnvalidatedRestoredTile() async throws {
    let h = ApplyHarness()
    defer { h.close() }
    h.addWindow(id: "a"); h.addWindow("com.apple.Safari", id: "b", pid: 43); h.addWindow("com.example.Notes", id: "c", pid: 44)
    let model = makeOffscreenModel(store: .init(fileURL: h.directory.appendingPathComponent("configuration.json")),
                               system: h.system, startRuntime: false)
    defer { model.shutdown() }
    model.primaryButtonIsPressed = { false }
    let applier = try #require(model.savedLayoutApplier)
    applier.observesKeyboard = false
    func document(_ bundles: [String]) -> SavedLayoutDocument {
        let slots = bundles.enumerated().map { SavedLayoutSlot(id: "s\($0.offset)", bundleID: $0.element) }
        return .init(name: "Layout", mode: .bento,
            layout: .split(axis: .vertical, ratios: bundles.map { _ in 1 / Double(bundles.count) }, children: slots.map { .slot($0.id) }),
            slots: slots)
    }
    _ = await applier.apply(document(["com.example.Editor", "com.apple.Safari", "com.example.Notes"]))
    _ = await applier.apply(document(["com.example.Editor", "com.apple.Safari"]))
    try #require(applier.canUndo)
    let c = WindowID(rawValue: "c")
    let movedFrame = BTRect(x: 7, y: 7, width: 300, height: 200)
    let before = h.system.frameWriteCounts[c, default: 0]
    h.system.onFrameWrite = { _, _ in
        h.system.onFrameWrite = nil
        h.system.desktopObservation?.windowMembership[c] = [h.space(2)]
        h.system.offscreenWindowIDs.insert(c)
        h.system.windows.firstIndex { $0.id == c }.map { h.system.windows[$0].frame = movedFrame }
    }
    await applier.undoLastApply()
    #expect(h.system.frameWriteCounts[c, default: 0] == before)
    #expect(h.system.windows.first { $0.id == c }?.frame == movedFrame)
}

private func twoAppDocument(_ first: String = "com.example.Editor", _ second: String = "com.apple.Safari") -> SavedLayoutDocument {
    .init(name: "Two apps", mode: .bento,
        layout: .split(axis: .vertical, ratios: [0.5, 0.5], children: [.slot("one"), .slot("two")]),
        slots: [.init(id: "one", bundleID: first), .init(id: "two", bundleID: second)])
}

@Test(.appTestApplication) @MainActor func savedLayoutAllowingNoSlotOpensNothingAndWritesNothing() async {
    let h = ApplyHarness()
    defer { h.close() }
    let result = await h.applier.apply(twoAppDocument())
    #expect(h.system.newWindowRequests.isEmpty)
    #expect(h.system.requestedFrames.isEmpty)
    #expect(result.placed == 0)
    #expect(result.unplaced == 2)
}

@Test(.appTestApplication) @MainActor func savedLayoutPreviewNamesEachSlotStatusAndMovesNothing() throws {
    let h = ApplyHarness()
    defer { h.close() }
    h.addWindow("com.example.Editor", id: "editor")
    h.addWindow("com.apple.Safari", id: "safari-1", pid: 43)
    h.addWindow("com.apple.Safari", id: "safari-2", pid: 43)
    h.addWindow("com.example.Elsewhere", id: "elsewhere", pid: 44, desktop: 3)
    h.applier.application = { id in
        id == "com.example.Missing" ? nil : .init(bundleIdentifier: id, name: id, url: URL(fileURLWithPath: "/fixture/\(id).app"))
    }
    let slots = ["com.example.Editor", "com.apple.Safari", "com.example.Closed", "com.example.Idle",
                 "com.example.Missing", "com.example.Elsewhere"]
    let ids = slots.indices.map { "s\($0)" }
    let document = SavedLayoutDocument(name: "Six", mode: .bento,
        layout: .split(axis: .vertical, ratios: Array(repeating: 1.0 / 6, count: 6), children: ids.map { .slot($0) }),
        slots: zip(ids, slots).map { SavedLayoutSlot(id: $0, bundleID: $1) })
    let before = h.system.windows.map(\.frame)
    let preview = try h.applier.preview(document)
    func kind(_ row: SavedLayoutPreviewRow) -> String {
        switch row.status {
        case .matched: "matched"
        case let .severalWindows(windows): "several \(windows.count)"
        case .empty: "empty"
        case .onAnotherDesktop: "elsewhere"
        case .notInstalled: "notInstalled"
        }
    }
    #expect(preview.problem == nil)
    #expect(preview.rows.map(kind) == ["matched", "matched", "matched", "empty", "notInstalled", "elsewhere"])
    #expect(h.system.windows.map(\.frame) == before)
    #expect(h.system.requestedFrames.isEmpty)
}

@Test(.appTestApplication) @MainActor func savedLayoutPreviewReportsAFitProblemInsteadOfRows() throws {
    let h = ApplyHarness()
    defer { h.close() }
    h.addWindow()
    h.system.windows[0].constraints.minimumSize = .init(width: 2000, height: 1000)
    let preview = try h.applier.preview(h.document())
    #expect(preview.problem != nil)
    #expect(preview.rows.isEmpty)
}

@Test(.appTestApplication) @MainActor func savedLayoutAChosenWindowOfSeveralIsTheOnePlaced() async {
    let h = ApplyHarness()
    defer { h.close() }
    h.addWindow(id: "one"); h.addWindow(id: "two")
    let result = await h.applier.apply(h.document(), choices: ["slot": WindowID(rawValue: "two")])
    #expect(result.placed == 1)
    #expect(h.system.windows[1].frame == h.system.mainDisplay.visibleFrame)
    #expect(h.system.requestedFrames[WindowID(rawValue: "one"), default: []].isEmpty)
}

@Test(.appTestApplication) @MainActor func savedLayoutUndoOnAnotherDesktopMovesNothing() async {
    let h = ApplyHarness()
    defer { h.close() }
    h.addWindow()
    _ = await h.applier.apply(h.document())
    let writes = h.system.frameWriteCounts
    h.arrive(2)
    await h.applier.undoLastApply()
    #expect(h.system.frameWriteCounts == writes)
    #expect(h.applier.canUndo)
    #expect(h.applier.message == "Go to the desktop of the last Apply before choosing Undo.")
}

@Test(.appTestApplication) @MainActor func savedLayoutApplyReportsItsResultAndKeepsALastRun() async {
    let h = ApplyHarness()
    defer { h.close() }
    var received: [SavedLayoutFeedback] = []
    h.applier.feedback = { received.append($0) }
    h.addWindow()
    _ = await h.applier.apply(h.document())
    #expect(received.map(\.title) == ["Test · 1 arranged"])
    #expect(received.first?.detail == nil) // The title already contains the arranged count.
    #expect(received.first?.kind == .success)
    #expect(received.first?.isApply == true)
    #expect(h.applier.lastRun?.layoutName == "Test")
    #expect(h.applier.hasUndo)
    await h.applier.undoLastApply()
    #expect(received.last?.title == "Saved Layout undone")
    #expect(received.last?.isApply == false)
    #expect(!h.applier.hasUndo)
}

@Test(.appTestApplication) @MainActor func savedLayoutResultPillOffersUndoAndDetailsThroughTheModel() async throws {
    let h = ApplyHarness()
    defer { h.close() }
    h.addWindow()
    let model = h.model()
    defer { model.shutdown() }
    let applier = try #require(model.savedLayoutApplier)
    applier.observesKeyboard = false
    var opened = 0
    model.openSettings = { opened += 1 }
    _ = await applier.apply(h.document())
    let actions = try #require(model.lastActionFeedback?.actions)
    #expect(actions.map(\.title) == ["Undo", "Details"])
    #expect(model.lastActionFeedback?.message == "Test · 1 arranged")
    actions[1].handler()
    #expect(model.requestedSettingsDestination == .savedLayouts)
    #expect(opened == 1)
    actions[0].handler()
    for _ in 0..<200 where applier.hasUndo { await Task.yield() }
    #expect(!applier.hasUndo)
    #expect(model.lastActionFeedback?.message == "Saved Layout undone")
    #expect(model.lastActionFeedback?.actions.isEmpty == true)
}

@Test(.appTestApplication) @MainActor func savedLayoutCaptureSetupDefaultsFollowTheMode() throws {
    let h = ApplyHarness()
    defer { h.close() }
    h.addWindow(id: "a"); h.addWindow("com.apple.Safari", id: "b", pid: 43); h.addWindow("com.example.Notes", id: "c", pid: 44)
    let manual = try h.applier.captureSetup()
    #expect(manual.session == .manual)
    #expect(manual.checked == Set(["a", "b", "c"].map(WindowID.init(rawValue:))))
    #expect(manual.members.isEmpty)
    var state = BentoLayoutState(root: .partition(BentoPartition(axis: .vertical,
        children: [.leaf(WindowID(rawValue: "a")), .leaf(WindowID(rawValue: "b"))])))
    state.floatingWindowIDs = [WindowID(rawValue: "c")]
    h.sessions[h.system.mainDisplay.id] = .bento(state)
    let adaptive = try h.applier.captureSetup()
    #expect(adaptive.members == Set(["a", "b"].map(WindowID.init(rawValue:))))
    #expect(adaptive.checked == adaptive.members)
    #expect(adaptive.workArea == h.system.mainDisplay.visibleFrame)
}

@Test(.appTestApplication) @MainActor func savedLayoutCaptureSetupLeavesOutWindowsThatAreNotEligible() throws {
    let h = ApplyHarness()
    defer { h.close() }
    h.addWindow(id: "kept")
    h.addWindow(id: "other-desktop", desktop: 2)
    h.addWindow(id: "minimized")
    h.system.windows[2].isMinimized = true
    let setup = try h.applier.captureSetup()
    #expect(setup.windows.map(\.id) == [WindowID(rawValue: "kept")])
}

@Test(.appTestApplication) @MainActor func savedLayoutApplyAndUndoNeverWriteTheConfigurationFile() async throws {
    let h = ApplyHarness()
    defer { h.close() }
    try FileManager.default.createDirectory(at: h.directory, withIntermediateDirectories: true)
    let file = h.directory.appendingPathComponent("configuration.json")
    try ConfigurationStore(fileURL: file).save(BetterTileConfiguration())
    let original = try Data(contentsOf: file)
    h.addWindow()
    let model = h.model()
    defer { model.shutdown() }
    let applier = try #require(model.savedLayoutApplier)
    applier.observesKeyboard = false
    _ = await applier.apply(h.document())
    await applier.undoLastApply()
    #expect(try Data(contentsOf: file) == original)
}

@Test(.appTestApplication, arguments: [false, true]) @MainActor func savedLayoutSkipsADesktopThatIsNotReady(unstable: Bool) async {
    let h = ApplyHarness()
    defer { h.close() }
    h.addWindow()
    if unstable { h.stable = false } else { h.ready = false }
    let result = await h.applier.apply(h.document())
    #expect(result.placed == 0)
    #expect(result.issues.first?.message.contains("cannot be laid out now") == true)
    #expect(h.system.requestedFrames.isEmpty)
    #expect(!h.applier.hasUndo)
}

// MARK: - Rollback and repair

@Test(.appTestApplication) @MainActor func savedLayoutARolledBackApplyIsNotReportedAsApplied() async {
    let h = ApplyHarness()
    defer { h.close() }
    h.addWindow()
    var received: [SavedLayoutFeedback] = []
    h.applier.feedback = { received.append($0) }
    h.refusedCommit = true
    let result = await h.applier.apply(h.document())
    #expect(result.placed == 0)
    #expect(received.first?.title == "Test not applied")
    #expect(received.first?.kind == .failure)
    #expect(received.first?.detail?.contains("Nothing was moved.") == true)
}

@Test(.appTestApplication) @MainActor func savedLayoutApplyDoesNotClearASuspensionThatWaitsForRepairLayout() async {
    let h = ApplyHarness()
    defer { h.close() }
    h.addWindow()
    h.suspended = true
    var received: [SavedLayoutFeedback] = []
    h.applier.feedback = { received.append($0) }
    let result = await h.applier.apply(h.document())
    #expect(result.placed == 0)
    #expect(received.first?.detail?.contains("Repair Layout") == true)
    #expect(h.system.requestedFrames.isEmpty)
    #expect(h.commits.isEmpty)
}

/// The model must report a session that waits for Repair Layout, so a second Apply refuses to run.
@Test(.appTestApplication) @MainActor func savedLayoutModelRefusesAnApplyWhileTheSessionWaitsForRepairLayout() async throws {
    let h = ApplyHarness()
    defer { h.close() }
    h.addWindow()
    let model = h.model()
    defer { model.shutdown() }
    model.primaryButtonIsPressed = { false }
    let applier = try #require(model.savedLayoutApplier)
    applier.observesKeyboard = false
    let id = h.system.windows[0].id
    h.system.onFrameWrite = { _, _ in
        h.system.onFrameWrite = nil
        Task { @MainActor in applier.cancel(); h.system.failedFrameWriteNumbers[id] = [2] }
    }
    _ = await applier.apply(h.document())
    let store = try #require(Mirror(reflecting: model).children.first { $0.label?.hasSuffix("sessionStore") == true }?.value as? LayoutSessionStore)
    try #require(store.allSessions(for: h.system.mainDisplay.id).contains { $0.automaticWritesSuspended })
    h.system.failedFrameWriteNumbers = [:]
    let writes = h.system.frameWriteCounts
    let result = await applier.apply(h.document())
    #expect(result.placed == 0)
    #expect(result.issues.first?.message.contains("Repair Layout") == true)
    #expect(h.system.frameWriteCounts == writes)
}

// MARK: - Cancellation and capture

/// A rollback after Escape is Not applied, with cancellation retained as its reason.
@Test(.appTestApplication, .settingsUI) @MainActor func savedLayoutEscapeThroughTheKeyMonitorDuringTheCommitShowsCancelled() async throws {
    let h = ApplyHarness()
    defer { h.close() }
    h.addWindow()
    h.applier.observesKeyboard = true
    // AppKit calls the process's local monitors in an unspecified order, so another monitor that consumes
    // Escape can starve the real one. Deliver the key straight to the handler the applier installs.
    var deliverKey: (@MainActor (UInt16) -> Void)?
    var monitorsRemoved = false
    h.applier.observeKeyDown = { handler in
        deliverKey = handler
        return { monitorsRemoved = true }
    }
    var received: [SavedLayoutFeedback] = []
    h.applier.feedback = { received.append($0) }
    h.onCommit = { deliverKey?(53) }
    let result = await h.applier.apply(h.document())
    #expect(deliverKey != nil)
    #expect(monitorsRemoved)
    #expect(result.placed == 0)
    #expect(received.first?.title == "Test not applied")
    #expect(received.first?.detail?.contains("cancelled") == true)
    #expect(received.first?.kind == .failure)
    #expect(h.applier.lastRun?.result.issues.first?.kind == .stopped)
    #expect(h.system.requestedFrames.isEmpty)
}

@Test(.appTestApplication) @MainActor func savedLayoutARefusedPaneNamesTheWindowAndItsMinimum() async {
    let h = ApplyHarness()
    defer { h.close() }
    h.addWindow()
    var received: [SavedLayoutFeedback] = []
    h.applier.feedback = { received.append($0) }
    h.refusedCommit = true
    // The window's minimum is learned during the failed write, after planning.
    h.onCommit = { h.system.windows[0].constraints.minimumSize = BTSize(width: 300, height: 900) }
    let result = await h.applier.apply(h.document())
    let expected = "com.example.Editor needs 900 pt of height; pane is 800."
    #expect(result.issues.first?.message.contains(expected) == true)
    #expect(received.first?.title == "Test not applied")
    #expect(received.first?.detail?.contains(expected) == true)
    #expect(h.applier.lastRun?.result.issues.first?.message.contains(expected) == true)
}

/// Live: Calculator (fixed size) opened and offered nothing. An alert, About box or Open panel floats too.
/// Neither may be offered as a choice; the user is told why instead.

@Test(.appTestApplication) @MainActor func savedLayoutAutomaticMatchingNeverTakesAPopupClassifiedWindow() async {
    let h = ApplyHarness()
    defer { h.close() }
    h.addWindow()
    h.system.windows[0].isFloating = true
    h.applier.application = { _ in nil }
    let result = await h.applier.apply(h.document())
    #expect(result.placed == 0)
    #expect(h.system.requestedFrames.isEmpty)
}

@Test(.appTestApplication) @MainActor func savedLayoutCaptureSetupCountsMembersWithoutAnAppIdentifier() throws {
    let h = ApplyHarness()
    defer { h.close() }
    h.addWindow(id: "a")
    h.addWindow("com.example.Notes", id: "nobundle", pid: 44)
    h.system.windows[1].bundleIdentifier = nil
    let state = BentoLayoutState(root: .partition(BentoPartition(axis: .vertical,
        children: [.leaf(WindowID(rawValue: "a")), .leaf(WindowID(rawValue: "nobundle"))])))
    h.sessions[h.system.mainDisplay.id] = .bento(state)
    let setup = try h.applier.captureSetup()
    #expect(setup.omitted == 1)
    #expect(setup.members == [WindowID(rawValue: "a")])
    let document = try SavedLayoutCaptureSelection.capture(name: "Left out", session: setup.session, windows: setup.windows,
                                                           checked: setup.checked, workArea: setup.workArea)
    #expect(document.slots.count == 1)
}

// MARK: - Undo and rollback feedback

@Test(.appTestApplication) @MainActor func savedLayoutARolledBackApplyDoesNotOfferTheUndoOfAnEarlierApply() async {
    let h = ApplyHarness()
    defer { h.close() }
    h.addWindow()
    var received: [SavedLayoutFeedback] = []
    h.applier.feedback = { received.append($0) }
    _ = await h.applier.apply(h.document())
    #expect(received.last?.offersUndo == true)
    h.system.windows[0].frame = BTRect(x: 100, y: 100, width: 400, height: 300)
    h.refusedCommit = true
    _ = await h.applier.apply(h.document())
    #expect(h.applier.hasUndo) // the first Apply can still be undone from Settings
    #expect(received.last?.title == "Test not applied")
    #expect(received.last?.offersUndo == false)
}

@Test(.appTestApplication) @MainActor func savedLayoutAnApplyThatChangesNothingKeepsTheOriginalUndo() async {
    let h = ApplyHarness()
    defer { h.close() }
    h.addWindow()
    var received: [SavedLayoutFeedback] = []
    h.applier.feedback = { received.append($0) }
    _ = await h.applier.apply(h.document())
    let count = received.count
    _ = await h.applier.apply(h.document()) // no writes or replacement checkpoint
    #expect(received.count == count + 1)
    #expect(received.last?.title == "Test · already arranged")
    #expect(received.last?.detail == nil)
    #expect(h.applier.lastRun?.offersUndo == false)
    #expect(h.applier.hasUndo)
}

@Test(.appTestApplication) @MainActor func savedLayoutSaysNothingWasMovedOnlyWhenTheRollbackSucceeded() async {
    for restored in [true, false] {
        let h = ApplyHarness()
        defer { h.close() }
        h.addWindow()
        h.refusedCommit = true
        h.onCommit = {
            h.system.windows[0].constraints.minimumSize = BTSize(width: 300, height: 900)
            if !restored { h.system.windows[0].frame = BTRect(x: 5, y: 5, width: 500, height: 500) }
        }
        let result = await h.applier.apply(h.document())
        let message = result.issues.first?.message ?? ""
        #expect(message.contains("Nothing was moved.") == restored)
        #expect(message.contains("could not be restored. Use Undo or Repair Layout.") == !restored)
        #expect(h.applier.hasUndo == !restored)
    }
}

// MARK: - Minimum-size failures

/// Live: Font Book (minimum height 532 in a 484 pane) rolled back with the generic message. The window
/// accepts the write but keeps its larger size, so settlement fails and the rollback hides the refusal.
@Test(.appTestApplication) @MainActor func savedLayoutAWindowThatKeepsALargerSizeIsNamedAfterTheRollback() async throws {
    let h = ApplyHarness()
    defer { h.close() }
    h.addWindow()
    let id = h.system.windows[0].id
    h.system.enforcedMinimumHeights[id] = 900
    h.system.windows[0].frame = BTRect(x: 100, y: 0, width: 400, height: 900) // already at its minimum
    let model = h.model()
    defer { model.shutdown() }
    model.primaryButtonIsPressed = { false }
    let applier = try #require(model.savedLayoutApplier)
    applier.observesKeyboard = false
    applier.application = h.applier.application
    var received: [SavedLayoutFeedback] = []
    applier.feedback = { received.append($0) }
    let result = await applier.apply(h.document())
    let expected = "com.example.Editor needs 900 pt of height; pane is 800."
    #expect(result.placed == 0)
    #expect(result.issues.first?.message.contains(expected) == true)
    #expect(received.first?.detail?.contains(expected) == true)
}

@Test(.appTestApplication) @MainActor func savedLayoutLastRunOffersUndoOnlyWhenThatRunMadeACheckpoint() async {
    let h = ApplyHarness()
    defer { h.close() }
    h.addWindow()
    _ = await h.applier.apply(h.document())
    #expect(h.applier.lastRun?.offersUndo == true)
    h.system.windows[0].frame = BTRect(x: 100, y: 100, width: 400, height: 300)
    h.refusedCommit = true
    _ = await h.applier.apply(h.document())
    #expect(h.applier.hasUndo)
    #expect(h.applier.lastRun?.offersUndo == false) // rolled back
    h.refusedCommit = false
    h.onCommit = { h.applier.cancel() }
    _ = await h.applier.apply(h.document())
    #expect(h.applier.lastRun?.result.issues.first?.kind == .stopped)
    #expect(h.applier.lastRun?.offersUndo == false) // cancelled with nothing placed
}

/// The other live path: the coordinator rolls the batch back itself, so the refusal is gone by the time
/// the applier looks. The coordinator records it first.
@Test(.appTestApplication) @MainActor func savedLayoutARefusalIsNamedWhenTheCoordinatorRollsTheBatchBackItself() async throws {
    let h = ApplyHarness()
    defer { h.close() }
    h.addWindow(id: "a")
    h.addWindow("com.apple.Safari", id: "b", pid: 43)
    h.system.windows[0].frame = BTRect(x: 0, y: 0, width: 500, height: 900) // already at its minimum
    h.system.enforcedMinimumHeights[WindowID(rawValue: "a")] = 900
    h.system.failedFrameWriteNumbers[WindowID(rawValue: "b")] = [1]
    let before = h.system.windows.map(\.frame)
    let model = h.model()
    defer { model.shutdown() }
    model.primaryButtonIsPressed = { false }
    let applier = try #require(model.savedLayoutApplier)
    applier.observesKeyboard = false
    applier.application = h.applier.application
    let result = await applier.apply(twoAppDocument())
    let message = result.issues.first?.message ?? ""
    #expect(result.placed == 0)
    #expect(message.contains("com.example.Editor needs 900 pt of height; pane is 800."))
    #expect(message.contains("Nothing was moved."))
    #expect(h.system.windows.map(\.frame) == before)
    #expect(applier.lastRun?.offersUndo == false)
}

@Test(.appTestApplication) @MainActor func savedLayoutQuickCaptureIncludesAllEligibleWindows() throws {
    let h = ApplyHarness()
    defer { h.close() }
    h.addWindow(id: "member")
    h.addWindow("com.apple.Safari", id: "outside-tree")
    h.addWindow("com.apple.Notes", id: "other-desktop", desktop: 2)
    h.sessions[h.system.mainDisplay.id] = .bento(BentoLayoutState(root: .leaf(.init(rawValue: "member"))))
    let setup = try h.applier.captureSetup(displayID: nil)
    #expect(setup.checked == [WindowID(rawValue: "member")])
    let document = try SavedLayoutQuickCapture.document(from: setup, existingNames: [])
    #expect(Set(document.slots.flatMap(\.prefer)) == [.app("com.example.Editor"), .app("com.apple.Safari")])
    #expect(document.floats.count == 1)
    #expect(document.name == "This app")
    #expect(!String(decoding: try SavedLayoutValidator.encode(document), as: UTF8.self).contains("other-desktop"))
    let manual = SavedLayoutCaptureSetup(displayID: setup.displayID, session: .manual, windows: setup.windows,
        workArea: setup.workArea, members: [], omitted: 0, checked: [])
    let manualDocument = try SavedLayoutQuickCapture.document(from: manual, existingNames: [])
    #expect(manualDocument.slots.count == setup.windows.count)
    #expect(manualDocument.name == "This app")
}

@Test(.appTestApplication) @MainActor func savedLayoutQuickCaptureSavesLoadsAndKeepsDirtyDraft() throws {
    let h = ApplyHarness()
    defer { h.close() }
    h.addWindow()
    h.sessions[h.system.mainDisplay.id] = .bento(BentoLayoutState(root: .leaf(.init(rawValue: "window"))))
    let editor = SavedLayoutEditor(files: .init(directory: h.directory))
    let message = SavedLayoutQuickCapture.save(applier: h.applier, editor: editor, displayID: h.system.mainDisplay.id)
    #expect(message == "Saved “This app”. Its panes are shown below. Remove an app with × on its pane; Undo restores it.")
    #expect(editor.document?.name == "This app")
    #expect(!editor.isDirty)
    #expect(editor.edit { $0.name = "My draft" })
    let source = editor.draft.source
    let dirtyMessage = SavedLayoutQuickCapture.save(applier: h.applier, editor: editor, displayID: h.system.mainDisplay.id)
    #expect(dirtyMessage.contains("Saved “This app 2” to the library. Your open draft was kept."))
    #expect(editor.draft.source == source)
    #expect(editor.entries.count == 2)
    #expect(h.commits.isEmpty)
}

@Test(.appTestApplication, arguments: [false, true]) @MainActor func savedLayoutConfirmedCaptureReplacesDraftOnlyAfterSuccess(saved: Bool) throws {
    let h = ApplyHarness()
    defer { h.close() }
    h.addWindow()
    h.sessions[h.system.mainDisplay.id] = .bento(BentoLayoutState(root: .leaf(.init(rawValue: "window"))))
    let editor = SavedLayoutEditor(files: .init(directory: h.directory))
    let flow = SavedLayoutCreation()
    flow.begin(.init(name: "Draft"), editor: editor)
    if saved {
        #expect(flow.save(editor: editor))
        #expect(editor.edit { $0.paneGap = 6 })
    }
    let previousURL = editor.url
    let previousBytes = try previousURL.map { try editor.files.read($0) }
    let entryCount = editor.entries.count
    #expect(flow.request(.capture, editor: editor, isApplying: false) == nil)
    flow.keepEditing()
    #expect(editor.document?.name == "Draft")
    #expect(editor.entries.count == entryCount)
    #expect(flow.request(.capture, editor: editor, isApplying: false) == nil)
    guard case .capture? = flow.discardDraft() else { Issue.record("Expected confirmed capture"); return }
    SavedLayoutQuickCapture.save(applier: h.applier, editor: editor, displayID: h.system.mainDisplay.id, replacingDraft: true)
    #expect(editor.document?.name == "This app")
    #expect(editor.url != nil)
    #expect(!editor.isDirty)
    if let previousURL { #expect(try editor.files.read(previousURL) == previousBytes) }
    #expect(h.commits.isEmpty)
}

@Test(.appTestApplication) @MainActor func savedLayoutApplySessionReadyUsesRealApplierWithoutOpening() async throws {
    let h = ApplyHarness()
    defer { h.close() }
    h.addWindow()
    let session = SavedLayoutApplySession(applier: h.applier)
    session.apply(document: h.document())
    try await waitForSavedLayoutState("The Apply result did not become available after startup.") {
        if case .applied = session.phase { true } else { false }
    }
    #expect(h.applier.lastRun?.result.placed == 1)
    #expect(h.commits == [1])
    if case .applied = session.phase {} else { Issue.record("Expected applied") }
}

@Test(.appTestApplication) @MainActor func savedLayoutQuickCaptureFailureKeepsDraftAndWritesNoFile() {
    let h = ApplyHarness()
    defer { h.close() }
    h.addWindow()
    h.system.windows[0].frame = .init(x: 100_000, y: 100_000, width: 100, height: 100)
    let editor = SavedLayoutEditor(files: .init(directory: h.directory))
    editor.newLayout()
    let source = editor.draft.source
    let message = SavedLayoutQuickCapture.save(applier: h.applier, editor: editor, displayID: h.system.mainDisplay.id)
    #expect(message.hasPrefix("Couldn’t save:") && message.hasSuffix("Nothing was saved."))
    #expect(editor.draft.source == source)
    #expect(editor.entries.isEmpty)
}

/// A rolled-back three-pane run must not count a pending click as skipped.

/// A pending candidate survives temporary placement blocks; its badge explains each one.

/// Seeded random Apply runs against the fake window system. Every run must keep its counts
/// consistent, place each window at most once, and leave frames unchanged when it reports a rollback.
@Test(.appTestApplication) @MainActor func savedLayoutRandomApplyKeepsCountsAndRestoresFramesOnRollback() async {
    struct Generator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func int(_ range: ClosedRange<Int>) -> Int { range.lowerBound + Int(next() % UInt64(range.count)) }
        mutating func chance(_ p: Double) -> Bool { Double(next() >> 11) / Double(1 << 53) < p }
        mutating func pick<T>(_ values: [T]) -> T { values[int(0...(values.count - 1))] }
    }
    let bundles = ["com.example.Editor", "com.apple.Safari", "com.example.Notes", "com.example.Missing"]
    for seed in 0..<250 {
        var g = Generator(state: UInt64(seed) &+ 77)
        let h = ApplyHarness()
        defer { h.close() }
        let slotCount = g.int(1...4)
        let slots = (0..<slotCount).map { SavedLayoutSlot(id: "s\($0)", bundleID: g.pick(bundles)) }
        let layout: SavedLayoutNode = slotCount == 1 ? .slot("s0")
            : .split(axis: g.pick([.vertical, .horizontal]), ratios: Array(repeating: 1 / Double(slotCount), count: slotCount - 1)
                + [1 - Double(slotCount - 1) / Double(slotCount)], children: slots.map { .slot($0.id) })
        let document = SavedLayoutDocument(name: "Stress", mode: .bento, layout: layout, slots: slots)
        var serial = 0
        for bundle in bundles.dropLast() {
            for _ in 0..<g.int(0...2) {
                serial += 1
                h.addWindow(bundle, id: "w\(serial)", pid: Int32(40 + serial), desktop: g.chance(0.2) ? 3 : nil)
                h.system.windows[h.system.windows.count - 1].frame = .init(x: Double(20 * serial), y: Double(30 + 10 * serial),
                                                                          width: 500, height: 400)
            }
        }
        h.applier.application = { id in id == "com.example.Missing" ? nil
            : .init(bundleIdentifier: id, name: id, url: URL(fileURLWithPath: "/fixture/\(id).app")) }
        if g.chance(0.3) { h.system.newWindowRequestResult = .requested }
        // Events during Apply: a refused commit, a refused frame, a window that closes, or a desktop change.
        let event = g.int(0...5)
        switch event {
        case 1: h.refusedCommit = true
        case 2: if let id = h.system.windows.first?.id { h.system.ignoredFrameWriteWindowIDs = [id] }
        case 3: h.onCommit = { if !h.system.windows.isEmpty { h.system.windows.removeFirst() } }
        case 4: h.onCommit = { h.arrive(2) }
        case 5: h.onCommit = { h.generation += 1 }
        default: break
        }
        let before = Dictionary(uniqueKeysWithValues: h.system.windows.map { ($0.id, $0.frame) })
        let result = await h.applier.apply(document)
        let context = "seed \(seed) event \(event) slots \(slots.map(\.prefer)) issues \(result.issues.map(\.message))"
        let threw = result.placed == 0 && result.unplaced == 0 && !result.issues.isEmpty
        if !threw {
            #expect(result.placed + result.unplaced == slotCount, "\(context): \(result.placed) + \(result.unplaced)")
            #expect(result.placedSlots.count == result.placed, "\(context)")
            #expect(result.slots.count == slotCount, "\(context)")
        }
        if case let .bento(state)? = h.sessions[h.system.mainDisplay.id] {
            let ids = state.root?.windowIDs ?? []
            #expect(Set(ids).count == ids.count, "\(context): a window holds two panes")
        }
        if result.issues.contains(where: { $0.message.contains("Nothing was moved") }) || threw && h.commits.isEmpty {
            for window in h.system.windows {
                guard let frame = before[window.id] else { continue }
                #expect(window.frame.approximatelyEquals(frame, tolerance: 2), "\(context): \(window.id) moved")
            }
        }
    }
}

@Test(.appTestApplication, arguments: [LayoutMode.bento, .tabbed]) @MainActor
func savedLayoutFlowRepeatedAppsAndFloatStayIdempotent(mode: LayoutMode) async {
    let h = ApplyHarness()
    defer { h.close() }
    let app = "com.example.Editor"
    h.addWindow(app, id: "z-existing", pid: 99)
    h.addWindow(app, id: "other-existing", pid: 99)
    h.addWindow(app, id: "float-existing", pid: 99)
    h.system.newWindowRequestResult = .requested
    var number = 0
    h.system.onNewWindowPreflight = { number += 1; h.addWindow(app, id: "arrival-\(number)", pid: 99) }
    let doc = SavedLayoutDocument(name: "Repeated and floating", mode: mode,
        layout: .split(axis: .vertical, ratios: [0.5, 0.5],
            children: mode == .bento ? [.slot("a"), .slot("b")] : [.group("left"), .group("right")]),
        slots: ["a", "b", "float"].map { .init(id: $0, bundleID: app) },
        groups: mode == .tabbed ? [.init(id: "left", slots: ["a"], selected: "a"), .init(id: "right", slots: ["b"], selected: "b")] : [],
        floats: [.init(slot: "float", rect: .init(x: 0.6, y: 0.6, width: 0.3, height: 0.3))])
    let first = await h.applier.apply(doc)
    #expect(first.placed == 3)
    let commits = h.commits.count
    var feedback = 0
    h.applier.feedback = { _ in feedback += 1 }
    let second = await h.applier.apply(doc)
    #expect(second.placed == 3)
    #expect(h.system.newWindowRequests.isEmpty)
    #expect(h.commits.count == commits)
    #expect(feedback == 1)
    _ = await h.applier.apply(doc, automatic: true)
    #expect(feedback == 1)
}

@Test(.appTestApplication, arguments: [LayoutMode.bento, .tabbed]) @MainActor
func savedLayoutFlowKeepsRuntimeGeometryAcrossRefresh(mode: LayoutMode) async throws {
    let h = ApplyHarness()
    defer { h.close() }
    h.addWindow(id: "left")
    h.addWindow("com.example.Other", id: "right", pid: 43)
    let model = h.model()
    defer { model.shutdown() }
    model.configuration.tabbedStripPresentation = .autoHide
    model.configuration.bentoInnerGap = 0
    let applier = try #require(model.savedLayoutApplier)
    applier.feedback = { _ in }
    applier.observesKeyboard = false
    let doc = SavedLayoutDocument(name: "Runtime geometry", mode: mode,
        layout: .split(axis: .vertical, ratios: [0.5, 0.5],
            children: mode == .bento ? [.slot("a"), .slot("b")] : [.group("left"), .group("right")]),
        slots: [.init(id: "a", bundleID: "com.example.Editor"), .init(id: "b", bundleID: "com.example.Other")],
        groups: mode == .tabbed ? [.init(id: "left", slots: ["a"], selected: "a"), .init(id: "right", slots: ["b"], selected: "b")] : [],
        paneGap: 8)
    let result = await applier.apply(doc)
    #expect(result.placed == 2)
    if mode == .tabbed {
        #expect(h.system.windows[0].frame.minY == h.system.mainDisplay.visibleFrame.minY + 6)
    }
    let frames = h.system.windows.map(\.frame)
    model.watchdog()
    let eventHandler = try #require(h.system.eventHandler)
    eventHandler(.init(kind: .resized, windowID: h.system.windows[0].id, processIdentifier: 42))
    let eventTask = try #require(model.windowEventTask)
    await eventTask.value
    for task in Array(model.settlementTasks.values) { await task.value }
    try await waitForSavedLayoutState("The injected frame event did not finish settling.") {
        model.windowEventTask == nil && model.settlementTasks.isEmpty
    }
    #expect(model.windowEventTask == nil && model.settlementTasks.isEmpty)
    #expect(h.system.windows.map(\.frame) == frames)
    var feedback = 0
    applier.feedback = { _ in feedback += 1 }
    _ = await applier.apply(doc)
    #expect(h.system.windows.map(\.frame) == frames)
    #expect(feedback == 1)
    if mode == .bento {
        model.updateConfiguration { $0.bentoInnerGap = 4 }
        #expect(await waitFor {
            let frames = h.system.windows.map(\.frame).sorted { $0.minX < $1.minX }
            return abs(frames[1].minX - frames[0].maxX - 4) < 0.01
        })
    }
}

@Test(.appTestApplication, .timeLimit(.minutes(1)), arguments: ["success", "failure", "timeout", "cancel", "expired"]) @MainActor
func savedLayoutReopenCompletionHasOneBoundedResult(ending: String) async {
    var reply: (@MainActor (NSRunningApplication?, (any Error)?) -> Void)?
    var dispatched = false
    var waited: [TimeInterval] = []
    let clock = ManualClock()
    let (dispatches, dispatchedSignal) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    defer { dispatchedSignal.finish() }
    let request = Task { @MainActor in
        try await ApplicationReopenCompletion.open(timeout: ending == "expired" ? 0 : 0.04, wait: { seconds in
            waited.append(seconds)
            try await clock.sleep(for: .seconds(seconds))
        }) { callback in
            dispatched = true
            dispatchedSignal.yield()
            reply = callback
            if ending == "success" { callback(.current, nil) }
            if ending == "failure" { callback(nil, CocoaError(.executableNotLoadable)) }
        }
    }
    if ending != "expired" {
        var iterator = dispatches.makeAsyncIterator()
        _ = await iterator.next()
    }
    if ending == "timeout" {
        await clock.waitForSleepers(count: 1)
        clock.advance(by: .milliseconds(40))
    }
    if ending == "cancel" { request.cancel() }
    do {
        let application = try await request.value
        #expect(ending == "success")
        #expect(application.processIdentifier == NSRunningApplication.current.processIdentifier)
    } catch { #expect(ending != "success") }
    if ending == "timeout" { #expect(waited == [0.04]) }
    #expect(dispatched == (ending != "expired"))
    // A late workspace reply cannot resume a finished or timed-out request twice.
    reply?(.current, nil)
    reply?(nil, CocoaError(.executableNotLoadable))
}

@Test(.appTestApplication, arguments: [LayoutMode.manual, .bento, .tabbed]) @MainActor
func savedLayoutVisibleExistingWindowMovesAndUndoRestoresItsExactSource(mode: LayoutMode) async throws {
    let h = ApplyHarness()
    defer { h.close() }
    let source = DisplaySnapshot(id: .init(rawValue: "source"),
        frame: .init(x: 1000, y: 0, width: 1000, height: 800),
        visibleFrame: .init(x: 1000, y: 0, width: 1000, height: 800), isMain: false)
    h.system.availableDisplays.append(source)
    h.system.desktopObservation?.currentSpaceByDisplay[source.id] = h.space(2)
    let id = WindowID(rawValue: "existing-on-source")
    let original = BTRect(x: 1137, y: 123, width: 451, height: 327)
    h.system.windows = [.init(id: id, processIdentifier: 42, bundleIdentifier: "com.example.Editor", frame: original, displayID: source.id)]
    h.system.desktopObservation?.windowMembership[id] = [h.space(2)]
    h.system.onFrameWrite = { _, frame in
        h.system.desktopObservation?.windowMembership[id] = [frame.midX >= 1000 ? h.space(2) : h.space(1)]
    }
    let model = h.model()
    defer { model.shutdown() }
    let applier = try #require(model.savedLayoutApplier)
    applier.observesKeyboard = false; applier.application = h.applier.application

    let document = mode == .manual
        ? SavedLayoutDocument(name: "Test", mode: .manual, slots: [.init(id: "slot", bundleID: "com.example.Editor")],
            windows: [.init(slot: "slot", rect: .init(x: 0.1, y: 0.1, width: 0.7, height: 0.7))])
        : h.document(mode: mode)
    let result = await applier.apply(document, displayID: h.system.mainDisplay.id)
    #expect(result.placed == 1)
    guard result.placed == 1 else { return }
    #expect(h.system.windows[0].displayID == h.system.mainDisplay.id)
    #expect(h.system.newWindowRequests.isEmpty)
    let writes = h.system.frameWriteCounts[id]
    _ = await applier.apply(document, displayID: h.system.mainDisplay.id)
    #expect(h.system.frameWriteCounts[id] == writes)
    #expect(h.system.newWindowRequests.isEmpty)
    h.system.desktopObservation?.currentSpaceByDisplay[source.id] = h.space(3)
    await applier.undoLastApply()
    #expect(applier.canUndo)
    #expect(h.system.frameWriteCounts[id] == writes)
    h.system.desktopObservation?.currentSpaceByDisplay[source.id] = h.space(2)
    await applier.undoLastApply()
    #expect(h.system.windows[0].displayID == source.id)
    #expect(h.system.windows[0].frame == original)
    #expect(!applier.canUndo)
}

@Test(.appTestApplication, arguments: ["unknown", "multiple", "hidden", "minimized", "fullscreen", "reserved", "pane", "tabs", "automatic", "busy", "suspended"])
@MainActor func savedLayoutVisibleReuseExcludesUnsafeSources(reason: String) async {
    let h = ApplyHarness()
    defer { h.close() }
    let source = DisplaySnapshot(id: .init(rawValue: "source"), frame: .init(x: 1000, y: 0, width: 1000, height: 800),
        visibleFrame: .init(x: 1000, y: 0, width: 1000, height: 800), isMain: false)
    let id = WindowID(rawValue: "source-window")
    let original = BTRect(x: 1120, y: 80, width: 450, height: 330)
    h.system.availableDisplays.append(source)
    h.system.desktopObservation?.currentSpaceByDisplay[source.id] = h.space(2)
    h.system.windows = [.init(id: id, processIdentifier: 42, bundleIdentifier: "com.example.Editor", frame: original,
        displayID: source.id, isMinimized: reason == "minimized", isFullScreen: reason == "fullscreen")]
    h.system.desktopObservation?.windowMembership[id] = reason == "unknown" ? [] : reason == "multiple" ? [h.space(1), h.space(2)] : [h.space(reason == "hidden" ? 3 : 2)]
    h.applier.snapshot = {
        var state = h.snapshot()
        state.displays.append(source); state.windows = h.system.windows
        state.readyDisplays.insert(source.id)
        if reason == "busy" { state.readyDisplays.remove(source.id) }
        if reason == "suspended" { state.suspendedDisplays.insert(source.id) }
        if reason == "pane" { state.sessions[source.id] = .bento(.init(root: .leaf(id))) }
        if reason == "tabs" {
            state.sessions[source.id] = .tabbed(TabbedLayoutState(adopting: .init(root: .leaf(id)))!)
        }
        return state
    }
    h.applier.reservesOtherOwnerWindow = { _ in reason == "reserved" }
    let result = await h.applier.apply(h.document(), automatic: reason == "automatic")
    #expect(result.placed == 0)
    #expect(h.system.requestedFrames[id] == nil)
    #expect(h.system.windows[0].frame == original)
    #expect(h.system.newWindowRequests.isEmpty)
}

@Test(.appTestApplication) @MainActor func savedLayoutVisibleMoveAndLocalPlacementShareOneUndo() async throws {
    let h = ApplyHarness()
    defer { h.close() }
    let source = DisplaySnapshot(id: .init(rawValue: "source"), frame: .init(x: 1000, y: 0, width: 1000, height: 800),
        visibleFrame: .init(x: 1000, y: 0, width: 1000, height: 800), isMain: false)
    h.system.availableDisplays.append(source)
    h.system.desktopObservation?.currentSpaceByDisplay[source.id] = h.space(2)
    h.addWindow("com.example.Browser", id: "local", pid: 43)
    let localFrame = h.system.windows[0].frame
    let moved = WindowID(rawValue: "moved")
    let original = BTRect(x: 1123, y: 117, width: 450, height: 330)
    h.system.windows.append(.init(id: moved, processIdentifier: 42, bundleIdentifier: "com.example.Editor", frame: original, displayID: source.id))
    h.system.desktopObservation?.windowMembership[moved] = [h.space(2)]
    h.system.onFrameWrite = { id, frame in h.system.desktopObservation?.windowMembership[id] = [frame.midX >= 1000 ? h.space(2) : h.space(1)] }
    let model = h.model()
    defer { model.shutdown() }
    let applier = try #require(model.savedLayoutApplier)
    applier.observesKeyboard = false; applier.application = h.applier.application

    let doc = SavedLayoutDocument(name: "Mixed", mode: .manual,
        slots: [.init(id: "moved", bundleID: "com.example.Editor"), .init(id: "local", bundleID: "com.example.Browser"), .init(id: "later", bundleID: "com.example.Later")],
        windows: ["moved", "local", "later"].enumerated().map { .init(slot: $0.element,
            rect: .init(x: Double($0.offset) / 3, y: 0, width: 1.0 / 3, height: 1)) })
    let first = await applier.apply(doc, displayID: h.system.mainDisplay.id)
    #expect(first.placed == 2)
    #expect(applier.lastRun?.result.slots["moved"] == .placed)
    #expect(applier.canUndo)
    #expect(h.system.newWindowRequests.isEmpty)
    await applier.undoLastApply()
    #expect(h.system.windows.first { $0.id == moved }?.frame == original)
    #expect(h.system.windows.first { $0.id == moved }?.displayID == source.id)
    #expect(h.system.windows.first { $0.id.rawValue == "local" }?.frame == localFrame)
    #expect(!applier.canUndo)
}

@Test(.appTestApplication) @MainActor func savedLayoutTargetWindowsWinBeforeForeignRuntimeIDOrder() async {
    let h = ApplyHarness()
    defer { h.close() }
    h.addWindow(id: "z-local")
    let source = DisplaySnapshot(id: .init(rawValue: "source"), frame: .init(x: 1000, y: 0, width: 1000, height: 800),
        visibleFrame: .init(x: 1000, y: 0, width: 1000, height: 800), isMain: false)
    h.system.desktopObservation?.currentSpaceByDisplay[source.id] = h.space(2)
    let id = WindowID(rawValue: "a-foreign")
    h.system.windows.append(.init(id: id, processIdentifier: 43, bundleIdentifier: "com.example.Editor",
        frame: .init(x: 1100, y: 100, width: 450, height: 330), displayID: source.id))
    h.system.desktopObservation?.windowMembership[id] = [h.space(2)]
    h.applier.snapshot = { var state = h.snapshot();state.displays.append(source);state.windows = h.system.windows;state.readyDisplays.insert(source.id);return state }
    let result = await h.applier.apply(h.document())
    #expect(result.placed == 1)
    #expect(h.system.requestedFrames[WindowID(rawValue: "z-local")] != nil)
    #expect(h.system.requestedFrames[id] == nil)
}

/// The request ends before the user supplies a document; the same run must keep collecting.

@Test(.appTestApplication) @MainActor func savedLayoutMovedSummaryUsesCommittedTransfer() async {
    let h = ApplyHarness()
    defer { h.close() }
    let remote = DisplaySnapshot(id: .init(rawValue: "remote"), frame: .init(x: 2000, y: 0, width: 1200, height: 900),
        visibleFrame: .init(x: 2000, y: 0, width: 1200, height: 900), isMain: false)
    h.addWindow()
    h.system.windows[0].displayID = remote.id
    h.system.windows[0].frame = .init(x: 2100, y: 100, width: 400, height: 300)
    h.applier.snapshot = {
        var state = h.snapshot(); state.displays.append(remote)
        state.observation.currentSpaceByDisplay[remote.id] = h.space(1)
        state.readyDisplays.insert(remote.id)
        return state
    }
    h.applier.destinationSnapshot = h.applier.snapshot
    _ = await h.applier.apply(h.document())
    #expect(h.applier.lastRun?.presentation.summary == "1 arranged")
    #expect(h.applier.lastRun?.result.movedSlots == ["slot"])
}

@Test(.appTestApplication, arguments: [false, true]) @MainActor func savedLayoutMovedCountsExcludeRollbackAndNextApplyAddsMove(rollback: Bool) async {
    let h = ApplyHarness(); defer { h.close() }
    let remote = DisplaySnapshot(id: .init(rawValue: "remote"), frame: .init(x: 2000, y: 0, width: 1200, height: 900),
        visibleFrame: .init(x: 2000, y: 0, width: 1200, height: 900), isMain: false)
    h.system.availableDisplays.append(remote)
    h.addWindow("com.example.One", id: "one", pid: 41)
    h.addWindow("com.example.Two", id: "two", pid: 42)
    h.applier.snapshot = {
        var state = h.snapshot(); state.displays.append(remote)
        state.observation.currentSpaceByDisplay[remote.id] = h.space(1)
        state.readyDisplays.insert(remote.id)
        return state
    }
    h.applier.destinationSnapshot = h.applier.snapshot
    let doc = SavedLayoutDocument(name: "Counts", mode: .manual,
        slots: ["One", "Two", "Three"].map { .init(id: $0, bundleID: "com.example." + $0) },
        windows: ["One", "Two", "Three"].enumerated().map { .init(slot: $0.element,
            rect: .init(x: Double($0.offset) / 3, y: 0, width: 1.0 / 3, height: 1)) })
    _ = await h.applier.apply(doc)
    #expect(h.applier.lastRun?.result.movedSlots.isEmpty == true)
    h.addWindow("com.example.Three", id: "three", pid: 43)
    h.system.windows[2].displayID = remote.id
    h.system.windows[2].frame = .init(x: 2100, y: 100, width: 400, height: 300)
    h.refusedCommit = rollback
    _ = await h.applier.apply(doc)
    if rollback {
        #expect(h.applier.lastRun?.result.movedSlots.isEmpty == true)
        let summary = h.applier.lastRun?.presentation.summary ?? ""
        #expect(summary.contains("moved") == false)
        #expect(h.system.windows[2].displayID == remote.id)
    } else {
        #expect(h.applier.lastRun?.presentation.summary == "3 arranged")
        #expect(h.applier.lastRun?.result.movedSlots == ["Three"])
    }
}

@Test(.appTestApplication, arguments: ["local", "several", "foreign", "hidden", "notInstalled", "foreignPane"])
@MainActor func savedLayoutPreviewAndApplyHaveTheSameOutcome(kind: String) async throws {
    let h = ApplyHarness(); defer { h.close() }
    let app = "com.example.Editor"
    let doc = h.document(app)
    h.applier.application = { id in kind == "notInstalled" ? nil : .init(bundleIdentifier: id, name: "Editor", url: URL(filePath: "/fixture/Editor.app")) }
    if ["local", "several"].contains(kind) { h.addWindow(app, id: "one") }
    if kind == "several" { h.addWindow(app, id: "two") }
    if kind == "hidden" { h.addWindow(app, id: "hidden", desktop: 2) }
    if kind == "foreign" || kind == "foreignPane" {
        let remote = DisplaySnapshot(id: .init(rawValue: "remote"), frame: .init(x: 2000, y: 0, width: 1000, height: 800),
            visibleFrame: .init(x: 2000, y: 0, width: 1000, height: 800))
        h.system.availableDisplays.append(remote)
        h.addWindow(app, id: "foreign", pid: 42)
        h.system.windows[0].displayID = remote.id
        h.system.windows[0].frame.origin.x = 2100
        h.applier.snapshot = {
            var state = h.snapshot(); state.displays.append(remote)
            state.observation.currentSpaceByDisplay[remote.id] = h.space(1)
            state.readyDisplays.insert(remote.id)
            if kind == "foreignPane" { state.sessions[remote.id] = .bento(.init(root: .leaf(.init(rawValue: "foreign")))) }
            return state
        }
    }
    let original = h.system.windows.map(\.frame)
    let preview = try h.applier.preview(doc)
    #expect(preview.problem == nil)
    let row = try #require(preview.rows.first)
    let line = row.outcome(screenName: { _ in "Studio Display" })
    #expect(h.system.frameWriteCounts.isEmpty && h.system.newWindowRequests.isEmpty)
    let result = await h.applier.apply(doc)
    switch kind {
    case "local": #expect(line == "Uses its open window"); #expect(result.placed == 1)
    case "several": #expect(line == "2 windows · nearest is used"); #expect(result.placed == 1)
    case "foreign": #expect(line == "Moves from Studio Display"); #expect(result.movedSlots == ["slot"])
    case "hidden", "foreignPane":
        #expect(line == "Only on another desktop"); #expect(result.placed == 0)
        #expect(h.system.windows.map(\.frame) == original)
    default: #expect(line == "Not installed"); #expect(result.placed == 0)
    }
    if case let .matched(window) = row.status, result.placed > 0 {
        #expect(h.system.frameWriteCounts[window.id, default: 0] > 0)
    }
}

@Test(.appTestApplication) @MainActor func savedLayoutRecordsCommittedFramesAndUndoRestoresThePreviousHints() async throws {
    let h = ApplyHarness(); defer { h.close() }
    h.addWindow(id: "original")
    let editor = SavedLayoutEditor(files: .init(directory: h.directory))
    editor.newLayout(); editor.edit { $0 = h.document() }; #expect(editor.save())
    let context = try #require(editor.positionContext)
    let previous = ["slot": NormalizedRect(x: 0.2, y: 0.1, width: 0.4, height: 0.5)]
    context.store.set(previous, for: context.file)
    _ = await h.applier.apply(h.document(), positions: context)
    #expect(context.store.frames(for: context.file)["slot"] == .init(x: 0, y: 0, width: 1, height: 1))
    #expect(h.applier.canUndo)
    await h.applier.undoLastApply()
    #expect(context.store.frames(for: context.file) == previous)
    let payload = try String(contentsOf: context.store.url, encoding: .utf8)
    #expect(!payload.contains("original"))
}

@Test(.appTestApplication) @MainActor func savedLayoutFreshApplierUsesPersistedPostCommitSizeInsteadOfSavedSize() async throws {
    let h = ApplyHarness(); defer { h.close() }
    h.addWindow(id: "original"); h.system.windows[0].frame = .init(x: 50, y: 0, width: 500, height: 300)
    h.system.windows[0].constraints.isResizable = false
    let doc = SavedLayoutDocument(name: "Sized", mode: .manual,
        slots: [.init(id: "slot", bundleID: "com.example.Editor")],
        windows: [.init(slot: "slot", rect: .init(x: 0, y: 0, width: 0.3, height: 0.375))])
    let editor = SavedLayoutEditor(files: .init(directory: h.directory))
    editor.newLayout(); editor.edit { $0 = doc }; #expect(editor.save())
    let context = try #require(editor.positionContext)
    _ = await h.applier.apply(doc, positions: context)
    #expect(context.store.frames(for: context.file)["slot"]?.width == 0.5)
    let next = ApplyHarness(); defer { next.close() }
    next.addWindow(id: "near-saved"); next.addWindow(id: "near-history")
    next.system.windows[0].frame = .init(x: 100, y: 0, width: 100, height: 300)
    next.system.windows[1].frame = .init(x: 200, y: 0, width: 100, height: 300)
    let without = try next.applier.preview(doc)
    let with = try next.applier.preview(doc, positions: .init(file: context.file, store: .init(files: editor.files)))
    guard case let .matched(saved)? = without.rows.first?.status, case let .matched(history)? = with.rows.first?.status else {
        Issue.record("Expected matching windows"); return
    }
    #expect(saved.id.rawValue == "near-saved")
    #expect(history.id.rawValue == "near-history")
    _ = await next.applier.apply(doc, positions: context)
    #expect(next.system.frameWriteCounts[history.id, default: 0] > 0)
    let newer = context.store.frames(for: context.file)
    await h.applier.undoLastApply()
    #expect(context.store.frames(for: context.file) == newer)
}

@Test(.appTestApplication) @MainActor func savedLayoutIdenticalFilesDoNotShareRememberedWindowIDs() async throws {
    let h = ApplyHarness(); defer { h.close() }
    h.addWindow(id: "left"); h.addWindow(id: "right")
    h.system.windows[0].frame = .init(x: 0, y: 0, width: 300, height: 400)
    h.system.windows[1].frame = .init(x: 600, y: 0, width: 300, height: 400)
    let doc = SavedLayoutDocument(name: "Same name", mode: .manual, slots: [.init(id: "slot", bundleID: "com.example.Editor")],
        windows: [.init(slot: "slot", rect: .init(x: 0, y: 0, width: 0.3, height: 0.5))])
    let editor = SavedLayoutEditor(files: .init(directory: h.directory))
    editor.newLayout(); editor.edit { $0 = doc }; #expect(editor.save(as: doc.name))
    let first = try #require(editor.positionContext)
    #expect(editor.save(as: doc.name)); let second = try #require(editor.positionContext)
    second.store.set(["slot": .init(x: 0.6, y: 0, width: 0.3, height: 0.5)], for: second.file)
    _ = await h.applier.apply(doc, positions: first)
    guard case let .matched(window)? = try h.applier.preview(doc, positions: second).rows.first?.status else {
        Issue.record("Expected a matched window"); return
    }
    #expect(window.id.rawValue == "right")
}

@Test(.appTestApplication) @MainActor func savedLayoutSettlementKeepsCapturedFrameEventsForItsKnownWindow() async throws {
    let h = ApplyHarness()
    defer { h.close() }
    h.addWindow()
    let oldID = h.system.windows[0].id
    let delivery = CapturedFrameDelivery(system: h.system)
    let id = h.system.windows[0].id
    let membership = h.system.desktopObservation?.windowMembership.removeValue(forKey: oldID)
    h.system.desktopObservation?.windowMembership[id] = membership
    let model = makeOffscreenModel(store: .init(fileURL: h.directory.appendingPathComponent("configuration.json")),
                                  system: h.system, startRuntime: false)
    defer { h.system.onFrameWrite = nil; delivery.onDelivery = nil; model.shutdown() }
    let applier = try #require(model.savedLayoutApplier)
    applier.observesKeyboard = false
    var bufferedDuringApply = false
    delivery.onDelivery = { event in
        if applier.ownedDisplayID != nil { bufferedDuringApply = pendingCapturedFrameIDs(model).contains(id) }
    }
    h.system.onFrameWrite = { windowID, _ in delivery.send(.resized, for: windowID) }
    let result = await applier.apply(h.document())
    #expect(result.issues.isEmpty)
    #expect(result.placed == 1)
    #expect(delivery.delivered.contains(id))
    #expect(bufferedDuringApply)
}

@Test(.appTestApplication) @MainActor func savedLayoutPlannerErrorsReachApplySurfacesWithoutJSONPaths() async {
    let h = ApplyHarness(); defer { h.close() }
    let reason = "Choose a distinct eligible window of the assigned app for each slot."
    let error = SavedLayoutValidationError(issues: [.init(path: "$.choices", message: reason)])
    h.applier.snapshot = { throw error }
    let result = await h.applier.apply(h.document())
    #expect(result.issues.map(\.message).contains(reason))
    #expect(h.applier.message?.contains("$.choices") != true)
    let session = SavedLayoutApplySession(preview: { _, _, _ in throw error }, start: { _, _, _ in Issue.record("Must not start") })
    session.apply(document: h.document())
    #expect(session.problem == reason)
    let page = SavedLayoutPagePlan()
    page.refresh(document: h.document(), displayID: h.system.mainDisplay.id, identity: nil,
        displays: [h.system.mainDisplay], unavailable: nil) { _, _ in throw error }
    #expect(page.problem == reason)
}

@Test(.appTestApplication) @MainActor func savedLayoutStartingRefusesApplyAndResetAndKeepsExactUndo() async throws {
    let h = ApplyHarness()
    defer { h.close() }
    h.addWindow()
    let before = h.system.windows
    let document = h.document()
    let session = SavedLayoutApplySession(applier: h.applier)
    session.apply(document: document)
    // The production start callback reserves the run synchronously, before its task executes.
    #expect(h.applier.isApplying && h.applier.isBusy && !h.applier.isRunning)
    if case .applying = session.phase {} else { Issue.record("Expected Applying during the handoff") }
    #expect(session.run == nil)
    var other = document; other.name = "Other"
    session.apply(document: other)
    #expect(session.problem == "Applying… Wait before applying or resetting the layout.")
    session.reset()
    #expect(session.problem == "Applying… Wait before applying or resetting the layout.")
    #expect(session.preview?.document == document)
    try await waitForSavedLayoutState("The real Apply did not finish startup and publish its result.") {
        !h.applier.isBusy && session.run != nil
    }
    #expect(session.run?.layoutName == document.name)
    #expect(session.problem == nil)
    #expect(h.commits == [1])
    #expect(h.system.windows[0].frame != before[0].frame)
    #expect(session.canUndo)
    session.undo()
    try await waitForSavedLayoutState("Undo did not restore the starting frames.") {
        !h.applier.isBusy && !h.applier.canUndo
    }
    #expect(h.system.windows.map(\.id) == before.map(\.id))
    #expect(h.system.windows.map(\.frame) == before.map(\.frame))
    #expect(h.system.windows.map(\.displayID) == before.map(\.displayID))
    session.reset()
    if case .idle = session.phase {} else { Issue.record("Expected reset after startup") }
}

@Test(.appTestApplication, arguments: [LayoutMode.bento, .tabbed]) @MainActor
func savedLayoutV2ExtraMembershipSurvivesModelCommit(mode: LayoutMode) async throws {
    let h = ApplyHarness()
    defer { h.close() }
    h.addWindow("com.example.Editor", id: "primary")
    h.addWindow("com.example.Extra", id: "extra")
    let model = makeOffscreenModel(store: .init(fileURL: h.directory.appendingPathComponent("configuration.json")),
                                   system: h.system, startRuntime: false)
    defer { model.shutdown() }
    let applier = try #require(model.savedLayoutApplier)
    applier.observesKeyboard = false
    var document = h.document(mode: mode)
    if mode == .bento { document.extraWindows = .addAsPanes }
    let result = await applier.apply(document)
    #expect(result.issues.isEmpty)
    let store = try #require(Mirror(reflecting: model).children.first {
        $0.label?.hasSuffix("sessionStore") == true
    }?.value as? LayoutSessionStore)
    let session = try #require(store.sessions.values.first { $0.displayID == h.system.mainDisplay.id })
    let extra = WindowID(rawValue: "extra")
    if mode == .tabbed {
        let state = try #require(session.tabbedState)
        #expect(state.pane(containing: extra)?.tabs.contains(WindowID(rawValue: "primary")) == true)
        #expect(!state.floatingWindowIDs.contains(extra))
    } else {
        #expect(session.bentoState.root?.windowIDs.contains(extra) == true)
        #expect(!session.bentoState.floatingWindowIDs.contains(extra))
    }
}

// The old launch/wait tests also covered these existing-window invariants.
// Keep them active while their provisioning-only portions await removal in 2A.
@Test(.appTestApplication, arguments: [LayoutMode.bento, .tabbed]) @MainActor
func savedLayoutV2ReadyWindowsKeepUndoWithoutProvisioning(mode: LayoutMode) async {
    let h = ApplyHarness(); defer { h.close() }
    h.addWindow(id: "ready")
    let baseline = h.system.windows[0].frame
    let document = SavedLayoutDocument(name: "Ready", mode: mode,
        layout: .split(axis: .vertical, ratios: [0.5, 0.5],
            children: mode == .bento ? [.slot("one"), .slot("two")] : [.group("one"), .group("two")]),
        slots: [.init(id: "one", bundleID: "com.example.Editor"), .init(id: "two", bundleID: "com.example.Unavailable")],
        groups: mode == .tabbed ? [.init(id: "one", slots: ["one"], selected: "one"),
                                   .init(id: "two", slots: ["two"], selected: "two")] : [])
    let result = await h.applier.apply(document)
    #expect(result.placedSlots == ["one"])
    #expect(result.unplaced == 1)
    #expect(h.applier.lastRun?.offersUndo == true)
    #expect(h.applier.canUndo)
    #expect(h.commits.count == 1)
    #expect(h.system.windows[0].frame != baseline)
    #expect(h.system.newWindowRequests.isEmpty)
    await h.applier.undoLastApply()
    #expect(h.system.windows[0].frame == baseline)
    #expect(h.sessions[h.system.mainDisplay.id]?.mode == .manual)
    #expect(!h.applier.canUndo)
}

@Test(.appTestApplication) @MainActor
func savedLayoutV2MultipleExistingWindowsUseOneDistinctChoiceWithoutLaunch() async {
    let h = ApplyHarness(); defer { h.close() }
    h.addWindow(id: "one"); h.addWindow(id: "two")
    let untouched = h.system.windows[1].frame
    let result = await h.applier.apply(h.document())
    #expect(result.placed == 1)
    #expect(result.issues.isEmpty)
    #expect(h.system.windows[1].frame == untouched)
    #expect(h.system.requestedFrames[WindowID(rawValue: "two")] == nil)
    #expect(!h.applier.isRunning)
}

@Test(.appTestApplication) @MainActor
func savedLayoutV2EmptyApplyKeepsOtherDesktopsAndRequestStateUntouched() async {
    let h = ApplyHarness(); defer { h.close() }
    h.addWindow(id: "hidden", desktop: 3)
    let baseline = h.system.windows
    let result = await h.applier.apply(h.document())
    #expect(result.placed == 0)
    #expect(h.system.windows == baseline)
    #expect(h.system.frameWriteCounts.isEmpty)
    #expect(h.system.newWindowRequests.isEmpty)
    #expect(!h.applier.isRunning)
}

@Test(.appTestApplication) @MainActor func savedLayoutV2FrontmostFillThroughModel() async throws {
    let h = ApplyHarness()
    defer { h.close() }
    h.addWindow("com.example.Back", id: "a-back")
    h.addWindow("com.example.Front", id: "z-front", pid: 43)
    h.system.stack = h.system.windows.reversed().map { .init(windowID: $0.id, frame: $0.frame) }
    let before = h.system.windows.map(\.frame)
    let model = h.model()
    defer { model.shutdown() }
    let applier = try #require(model.savedLayoutApplier)
    applier.observesKeyboard = false

    let document = SavedLayoutDocument(name: "Shape", mode: .bento,
        layout: .split(axis: .vertical, ratios: [0.7, 0.3], children: [.slot("large"), .slot("small")]),
        slots: [.init(id: "large"), .init(id: "small")])
    await applier.prepareAppGroups()
    let preview = try applier.preview(document)
    let result = await applier.apply(document)
    #expect(preview.plan?.assignments == applier.lastPlan?.assignments)
    #expect(result.placed == 2)
    #expect(h.system.windows.first { $0.id.rawValue == "z-front" }?.frame.size.width == 700)
    let writes = h.system.frameWriteCounts
    _ = await applier.apply(document)
    #expect(h.system.frameWriteCounts == writes)
    await applier.undoLastApply()
    #expect(h.system.windows.map(\.frame) == before)
    #expect(h.system.newWindowRequests.isEmpty)
}
