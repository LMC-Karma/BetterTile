import Foundation
import Carbon.HIToolbox
@testable import BetterTileMacOS
import Testing
import BetterTileCore
@testable import BetterTileApp

@MainActor @Suite(.appTestApplication) struct SavedLayoutActionsTests {
    @Test func noFocusAfterReconciliationMustNotUseMainDisplay() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let system = FakeAppWindowSystem()
        system.windows = []; system.focusedWindowIsAbsent = true
        let files = SavedLayoutFiles(directory: root.appendingPathComponent("Saved Layouts"))
        let document = SavedLayoutDocument(name: "Writing", mode: .manual)
        let url = try files.create(SavedLayoutValidator.encode(document))
        let model = makeOffscreenModel(store: .init(fileURL: root.appendingPathComponent("config.json")),
            system: system, startRuntime: false)
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        model.watchdog()
        #expect(model.activeDisplayID == system.mainDisplay.id)
        #expect(!model.applySavedLayoutAction(url.lastPathComponent))
        #expect(model.statusMessage == "Focus an app window to apply a layout.")
        #expect(system.frameWriteCounts.isEmpty)
    }

    @Test(arguments: [1, 0, 3])
    func unsupportedLayoutCannotApplyOrChangeItsFile(version: Int) async throws {
        let f = try SavedLayoutActionFixture(); defer { f.close() }
        let bytes = Data("{\"version\":\(version),\"name\":\"Unsupported\",\"mode\":\"bento\",\"layout\":{\"slot\":\"one\"},\"slots\":[{\"id\":\"one\",\"bundleID\":\"com.example.Test\"}]}".utf8)
        try bytes.write(to: f.url)
        f.model.savedLayoutActions.refresh()
        #expect(!f.model.applySavedLayoutAction(f.url.lastPathComponent))
        await f.finish()
        #expect(f.model.savedLayoutApplier?.lastRun == nil)
        #expect(f.system.requestedFrames.isEmpty)
        #expect(f.model.statusMessage == "This Saved Layout could not be opened. Reload the library and try again.")
        #expect(try f.files.read(f.url) == bytes && f.files.entries() == [f.url])
    }

    @Test func localActionsRoundTripWithoutChangingLayoutOrExport() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let files = SavedLayoutFiles(directory: root.appendingPathComponent("Saved Layouts"))
        let store = SavedLayoutActionStore(files: files)
        let shortcut = KeyboardShortcut(keyCode: 18, modifiers: [.control, .option], keyLabel: "1")
        #expect(store.set("one.json", .init(shortcut: shortcut, showInMenuBar: true, showInWheel: true)))
        let reopened = SavedLayoutActionStore(files: files)
        #expect(reopened.settings(for: "one.json").shortcut == shortcut)
        #expect(reopened.settings(for: "one.json").showInWheel)
        #expect(try files.entries().isEmpty)
        #expect(store.remove("one.json"))
        #expect(SavedLayoutActionStore(files: files).settings(for: "one.json") == .init())
    }
}

@MainActor final class SavedLayoutActionFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let system = FakeAppWindowSystem()
    let hotKeys = FakeSavedLayoutHotKeys()
    let model: BetterTileModel
    let files: SavedLayoutFiles
    let url: URL
    let document: SavedLayoutDocument
    let other = DisplaySnapshot(id: .init(rawValue: "other"), frame: .init(x: 1000, y: 0, width: 1000, height: 800),
        visibleFrame: .init(x: 1000, y: 0, width: 1000, height: 800))
    init() throws {
        files = .init(directory: root.appendingPathComponent("Saved Layouts"))
        document = .init(name: "Writing", mode: .manual, slots: [.init(id: "one", bundleID: "com.example.Test")],
            windows: [.init(slot: "one", rect: .init(x: 0.1, y: 0.1, width: 0.5, height: 0.6))])
        url = try files.create(SavedLayoutValidator.encode(document))
        system.availableDisplays.append(other)
        system.windows[0].displayID = other.id
        system.windows[0].frame = .init(x: 1200, y: 200, width: 600, height: 400)
        system.desktopObservation = .init(currentSpaceByDisplay: [system.mainDisplay.id: .init(rawValue: 1), other.id: .init(rawValue: 2)],
            knownSpacesByDisplay: [system.mainDisplay.id: [.init(rawValue: 1)], other.id: [.init(rawValue: 2)]],
            windowMembership: [system.windows[0].id: [.init(rawValue: 2)]])
        model = makeOffscreenModel(store: .init(fileURL: root.appendingPathComponent("config.json")), system: system,
            startRuntime: false, shortcutMonitor: hotKeys.monitor)
        model.savedLayoutScreenNames = { [other] in [other.id: "Studio", .init(rawValue: "main"): "Built-in"] }
    }
    func finish() async {
        for _ in 0..<2000 {
            await Task.yield()
            if model.savedLayoutApplier?.isBusy == false { break }
        }
    }
    func close() { model.shutdown(); try? FileManager.default.removeItem(at: root) }
}

extension SavedLayoutActionsTests {
    @Test func wheelHoverReadsNoFullInventoryAndReleaseUsesTheNormalOne() async throws {
        let f = try SavedLayoutActionFixture(); defer { f.close() }
        let applier = try #require(f.model.savedLayoutApplier)
        var snapshots = 0
        let snapshot = applier.snapshot
        applier.snapshot = { snapshots += 1; return try snapshot() }
        let target = try #require(f.model.captureLayoutWheelTarget())
        let focusReads = f.system.focusedWindowReadCount
        for _ in 0..<6 { _ = f.model.previewLayoutWheel(.savedLayout(file: f.url.lastPathComponent, name: "Writing"), for: target) }
        #expect(snapshots == 0)
        #expect(f.system.focusedWindowReadCount == focusReads)
        #expect(f.system.frameWriteCounts.isEmpty)
        f.model.performLayoutWheel(.savedLayout(file: f.url.lastPathComponent, name: "Writing"), for: target)
        await f.finish()
        #expect(snapshots > 0)
        let normal = try SavedLayoutActionFixture(); defer { normal.close() }
        let normalApplier = try #require(normal.model.savedLayoutApplier)
        let normalSnapshot = normalApplier.snapshot; var normalReads = 0
        normalApplier.snapshot = { normalReads += 1; return try normalSnapshot() }
        normalApplier.start(normal.document, displayID: normal.other.id,
            positions: .init(file: normal.url.lastPathComponent, store: .init(files: normal.files)))
        await normal.finish()
        #expect(snapshots == normalReads) // Release adds no inventory to the ordinary Apply path.
        print("SAVED_LAYOUT_ACTION_READS hover=0 release=\(snapshots) normal=\(normalReads)")
        #expect(applier.lastRun?.result.placed == 1)
    }
    @Test func realFocusPathRemembersScreenAndDisconnectInvalidatesIt() async throws {
        let f = try SavedLayoutActionFixture(); defer { f.close() }
        f.system.focusedWindowIsAbsent = true
        #expect(!f.model.applySavedLayoutAction(f.url.lastPathComponent))
        #expect(f.model.statusMessage == "Focus an app window to apply a layout.")
        f.system.focusedWindowIsAbsent = false
        f.system.eventHandler?(.init(kind: .focused, windowID: f.system.windows[0].id, processIdentifier: 42))
        #expect(f.model.savedLayoutApplier?.currentDisplayID() == f.other.id) // Real model closure, never replaced.
        f.system.focusedWindowIsAbsent = true
        #expect(f.model.applySavedLayoutAction(f.url.lastPathComponent))
        await f.finish()
        #expect(f.model.savedLayoutApplier?.lastDesktop?.displayID == f.other.id)
        #expect(f.model.savedLayoutApplier?.lastRun?.result.placed == 1)
        f.system.availableDisplays = [f.system.mainDisplay]
        f.model.refreshSavedLayoutActionTarget()
        #expect(!f.model.applySavedLayoutAction(f.url.lastPathComponent))
        #expect(f.model.statusMessage == "Focus an app window to apply a layout.")
        f.system.availableDisplays.append(f.other)
        #expect(!f.model.applySavedLayoutAction(f.url.lastPathComponent)) // Reconnect does not resurrect provenance.
    }
    @Test func releasedHotKeyMonitorsDoNotBlockLaterRegistrations() throws {
        let key = KeyboardShortcut(keyCode: 18, modifiers: [.control, .option], keyLabel: "1")
        for iteration in 0..<100 {
            let keys = FakeSavedLayoutHotKeys()
            keys.monitor.update(bindings: [], named: ["writing.json": key])
            try #require(keys.namedIDs.count == 1, "Missing registration in monitor \(iteration).")
            // Releasing an owner must retire its native handler, even without explicit stop().
        }
    }

    @Test(arguments: ["ignored", "ineligible"], [true, false])
    func unmanagedFocusUsesRememberedDisplayOrRefuses(focus: String, remembered: Bool) async throws {
        for shortcut in [false, true] {
            let f = try SavedLayoutActionFixture(); defer { f.close() }
            let applier = try #require(f.model.savedLayoutApplier)
            if remembered { f.model.handleApplicationActivation() } // Real managed focus on B.
            var focused = WindowSnapshot(id: .init(rawValue: "unmanaged-focus"), processIdentifier: 43,
                bundleIdentifier: "com.example.Unmanaged", frame: .init(x: 40, y: 40, width: 300, height: 200),
                displayID: f.system.mainDisplay.id)
            if focus == "ignored" {
                f.model.configuration.applicationRules.set(.ignoreEverywhere, for: "com.example.Unmanaged")
            } else { focused.constraints.isMovable = false }
            // A also has an eligible window, so the old target rule causes a real wrong-display write.
            let peer = WindowSnapshot(id: .init(rawValue: "main-editor"), processIdentifier: 44,
                bundleIdentifier: "com.example.Test", frame: .init(x: 80, y: 80, width: 300, height: 200),
                displayID: f.system.mainDisplay.id)
            f.system.windows += [focused, peer]
            f.system.desktopObservation?.windowMembership[focused.id] = [.init(rawValue: 1)]
            f.system.desktopObservation?.windowMembership[peer.id] = [.init(rawValue: 1)]
            f.system.focusedID = focused.id
            let mainFrames = f.system.windows.filter { $0.displayID == f.system.mainDisplay.id }.map(\.frame)
            f.model.refreshSavedLayoutActionTarget()
            #expect(f.model.savedLayoutActionTargetName == (remembered ? "Studio" : nil))
            if shortcut {
                let key = KeyboardShortcut(keyCode: 18, modifiers: [.control, .option], keyLabel: "1")
                #expect(f.model.setSavedLayoutActions(f.url.lastPathComponent, .init(shortcut: key)))
                f.hotKeys.monitor.handleHotKey(id: try #require(f.hotKeys.namedIDs.first))
            } else {
                #expect(f.model.applySavedLayoutAction(f.url.lastPathComponent) == remembered)
            }
            await f.finish()
            #expect(!applier.isBusy)
            #expect(f.system.windows.filter { $0.displayID == f.system.mainDisplay.id }.map(\.frame) == mainFrames)
            #expect(f.system.frameWriteCounts[peer.id] == nil && f.system.frameWriteCounts[focused.id] == nil)
            if remembered {
                #expect(applier.lastRun?.displayID == f.other.id && applier.lastRun?.result.placed == 1)
                #expect(f.system.frameWriteCounts[f.system.windows[0].id, default: 0] > 0)
            } else {
                #expect(applier.lastRun == nil && f.system.frameWriteCounts.isEmpty)
                #expect(f.model.statusMessage == "Focus an app window to apply a layout.")
            }
        }
    }

    @Test func panelAndShortcutShareTheRealApplierAndSettingsAdoptsItsUndo() async throws {
        let f = try SavedLayoutActionFixture(); defer { f.close() }
        let original = f.system.windows[0].frame
        let key = KeyboardShortcut(keyCode: 18, modifiers: [.control, .option], keyLabel: "1")
        #expect(f.model.setSavedLayoutActions(f.url.lastPathComponent, .init(shortcut: key, showInMenuBar: true)))
        f.model.handleSavedLayoutShortcut(f.url.lastPathComponent)
        #expect(!f.model.applySavedLayoutAction(f.url.lastPathComponent)) // Includes the queued start, before isRunning.
        await f.finish()
        let applier = try #require(f.model.savedLayoutApplier)
        #expect(applier.lastRun?.result.placed == 1)
        #expect(f.model.savedLayoutActionTargetName == "Studio")
        let session = SavedLayoutApplySession(applier: applier)
        let editor = SavedLayoutEditor(files: f.files)
        var other = f.document; other.name = "Previously selected"
        let otherURL = try f.files.create(SavedLayoutValidator.encode(other))
        #expect(editor.load(otherURL)) // Settings retains its editor while closed.
        let runDate = applier.lastRun?.date
        let page = SavedLayoutSettings(editor: editor, model: f.model, suppliedSession: session)
        page.initializePage()
        #expect(editor.url == f.url)
        #expect(session.run?.displayID == f.other.id)
        #expect(session.canUndo)
        #expect(session.run?.result.placedSlots.contains("one") == true)
        #expect(session.owner?.document == f.document)
        #expect(applier.lastRun?.date == runDate)
        applier.startUndo(displayID: f.other.id)
        await f.finish()
        #expect(f.system.windows[0].frame == original)
    }
    @Test func fullScreenRefusesAndStaleFileNeverApplies() async throws {
        let f = try SavedLayoutActionFixture(); defer { f.close() }
        f.system.desktopObservation?.fullscreenSpaceIDs = [.init(rawValue: 2)]
        #expect(f.model.applySavedLayoutAction(f.url.lastPathComponent))
        await f.finish()
        #expect(f.model.savedLayoutApplier?.message?.contains("fullscreen, use Stage Manager") == true)
        #expect(f.system.frameWriteCounts.isEmpty)
        try FileManager.default.removeItem(at: f.url)
        #expect(!f.model.applySavedLayoutAction(f.url.lastPathComponent))
        #expect(f.model.savedLayoutActions.entries.isEmpty)
        #expect(f.system.frameWriteCounts.isEmpty)
    }
    @Test func corruptExternalActionsAreIgnoredAndNeverOverwritten() throws {
        let f = try SavedLayoutActionFixture(); defer { f.close() }
        let store = f.model.savedLayoutActions.store
        let corrupt = Data("not json".utf8)
        try corrupt.write(to: store.url)
        store.load()
        #expect(store.values.isEmpty)
        #expect(!store.set(f.url.lastPathComponent, .init(showInWheel: true)))
        #expect(try Data(contentsOf: store.url) == corrupt)
        try Data(repeating: 32, count: SavedLayoutActionStore.maximumBytes + 1).write(to: store.url)
        store.load(); #expect(store.values.isEmpty && store.loadError != nil)
    }
    @Test func outsideByteChangeIsRefusedAndExportIsUnchanged() throws {
        let f = try SavedLayoutActionFixture(); defer { f.close() }
        let store = f.model.savedLayoutActions.store
        #expect(store.set(f.url.lastPathComponent, .init(shortcut: .init(keyCode: 18, modifiers: [.control, .option], keyLabel: "1"), showInMenuBar: true, showInWheel: true)))
        let bytes = try Data(contentsOf: f.url)
        let editor = SavedLayoutEditor(files: f.files); #expect(editor.load(f.url))
        let exported = f.root.appendingPathComponent("export.json"); editor.export(to: exported)
        #expect(try Data(contentsOf: exported) == bytes)
        let replacement = Data(#"{"version":1,"layouts":{}}"#.utf8)
        try replacement.write(to: store.url)
        #expect(!store.set(f.url.lastPathComponent, .init(showInWheel: true)))
        #expect(store.message?.contains("changed outside") == true)
        #expect(try Data(contentsOf: store.url) == replacement)
    }
    @Test func libraryTracksNameUpdateDeletionAndFileRenameWithoutSettings() throws {
        let f = try SavedLayoutActionFixture(); defer { f.close() }
        let actions = f.model.savedLayoutActions
        #expect(f.model.setSavedLayoutActions(f.url.lastPathComponent, .init(showInMenuBar: true, showInWheel: true)))
        var renamed = f.document; renamed.name = "A new name"
        let old = try f.files.read(f.url)
        try f.files.save(SavedLayoutValidator.encode(renamed), to: f.url, expected: old)
        actions.checkForChanges()
        #expect(actions.menuEntries.first?.name == "A new name")
        #expect(actions.store.settings(for: f.url.lastPathComponent).showInWheel)
        let moved = f.files.directory.appendingPathComponent("renamed.json")
        try FileManager.default.moveItem(at: f.url, to: moved)
        actions.checkForChanges()
        #expect(actions.store.settings(for: f.url.lastPathComponent) == .init())
        #expect(actions.menuEntries.isEmpty)
        #expect(!f.model.applySavedLayoutAction(f.url.lastPathComponent))
    }
    @Test func conflictsAreRefusedOnBothSidesAndComparePhysicalKeys() throws {
        let f = try SavedLayoutActionFixture(); defer { f.close() }
        let key = KeyboardShortcut(keyCode: 18, modifiers: [.control, .option], keyLabel: "1")
        #expect(f.model.setSavedLayoutActions(f.url.lastPathComponent, .init(shortcut: key)))
        let config = ConfigurationStore(fileURL: f.root.appendingPathComponent("config.json"))
        try config.save(f.model.configuration)
        let configBytes = try Data(contentsOf: config.fileURL)
        f.model.assign(shortcut: key, to: .maximize)
        f.model.flushConfiguration()
        #expect(try Data(contentsOf: config.fileURL) == configBytes)
        #expect(f.model.configuration.schemaVersion == 12)
        #expect(f.model.configuration.shortcuts.first { $0.action == .maximize }?.shortcut != key)
        #expect(f.model.statusMessage?.contains("Writing") == true)
        #expect(f.model.savedLayoutActions.message == f.model.statusMessage)
        var other = f.document; other.name = "Another"
        let url = try f.files.create(SavedLayoutValidator.encode(other)); f.model.savedLayoutActions.refresh()
        var alternateLabel = key; alternateLabel.keyLabel = "!"
        #expect(!f.model.setSavedLayoutActions(url.lastPathComponent, .init(shortcut: alternateLabel)))
        #expect(f.model.savedLayoutActions.message?.contains("Writing") == true)
        let wheelKey = KeyboardShortcut(keyCode: 18, modifiers: [.control, .option, .shift], keyLabel: "1")
        #expect(!f.model.setSavedLayoutActions(url.lastPathComponent, .init(shortcut: wheelKey)))
        #expect(f.model.savedLayoutActions.message?.contains("Layout Wheel") == true)
        let reserved = KeyboardShortcut(keyCode: 49, modifiers: .command, keyLabel: "Space")
        #expect(SavedLayoutShortcutPolicy.conflict(reserved, configuration: f.model.configuration, layouts: [:]) != nil)
        let accepted = f.model.setSavedLayoutActions(url.lastPathComponent, .init(shortcut: reserved))
        #expect(accepted == false)
        #expect(f.model.savedLayoutActions.message?.contains("macOS") == true)
    }
}

/// Only the Carbon boundary is fake. Registration, suspension, IDs and model dispatch are production code.
@MainActor final class FakeSavedLayoutHotKeys {
    let monitor = GlobalShortcutMonitor { _ in }
    var registered: [UInt32: UInt32] = [:]
    var failNamed = false
    init() {
        monitor.registerHotKey = { [weak self] key, _, id, ref in
            guard let self else { return OSStatus(eventHotKeyExistsErr) }
            if failNamed && id.id > WindowAction.allCases.count { return OSStatus(eventHotKeyExistsErr) }
            registered[id.id] = key
            ref = EventHotKeyRef(bitPattern: Int(id.id))
            return noErr
        }
        monitor.unregisterHotKey = { [weak self] ref in self?.registered[UInt32(Int(bitPattern: ref))] = nil }
    }
    var namedIDs: [UInt32] { registered.keys.filter { $0 > WindowAction.allCases.count }.sorted() }
}

extension SavedLayoutActionsTests {
    @Test func registrationFailureAfterRecorderResumesIsShownAndRecoveryDispatches() async throws {
        let f = try SavedLayoutActionFixture(); defer { f.close() }
        let key = KeyboardShortcut(keyCode: 18, modifiers: [.control, .option], keyLabel: "1")
        f.model.setShortcutCaptureActive(true)
        f.hotKeys.failNamed = true
        #expect(f.model.setSavedLayoutActions(f.url.lastPathComponent, .init(shortcut: key)))
        f.model.setShortcutCaptureActive(false)
        #expect(f.model.savedLayoutShortcutProblem(f.url.lastPathComponent)?.contains("macOS could not register") == true)
        #expect(f.hotKeys.namedIDs.isEmpty)
        f.model.setShortcutCaptureActive(true)
        f.hotKeys.failNamed = false
        f.model.setShortcutCaptureActive(false)
        #expect(f.model.savedLayoutShortcutProblem(f.url.lastPathComponent) == nil)
        let id = try #require(f.hotKeys.namedIDs.first)
        f.hotKeys.monitor.handleHotKey(id: id)
        await f.finish()
        #expect(f.model.savedLayoutApplier?.lastRun?.result.placed == 1)
    }

    @Test func persistedShortcutRegistersOnRelaunchAndFileRenameAndDeletionRetireIt() async throws {
        let f = try SavedLayoutActionFixture(); defer { f.close() }
        let key = KeyboardShortcut(keyCode: 18, modifiers: [.control, .option], keyLabel: "1")
        #expect(f.model.setSavedLayoutActions(f.url.lastPathComponent, .init(shortcut: key)))
        f.model.shutdown()
        let keys = FakeSavedLayoutHotKeys()
        let relaunched = makeOffscreenModel(store: .init(fileURL: f.root.appendingPathComponent("config.json")),
            system: f.system, shortcutMonitor: keys.monitor)
        defer { relaunched.shutdown() }
        let firstID = try #require(keys.namedIDs.first)
        keys.monitor.handleHotKey(id: firstID)
        for _ in 0..<2000 { await Task.yield(); if relaunched.savedLayoutApplier?.isBusy == false { break } }
        #expect(relaunched.savedLayoutApplier?.lastRun?.result.placed == 1)
        let moved = f.files.directory.appendingPathComponent("renamed.json")
        try FileManager.default.moveItem(at: f.url, to: moved)
        relaunched.savedLayoutActions.checkForChanges()
        #expect(keys.namedIDs.isEmpty)
        #expect(relaunched.savedLayoutActions.store.settings(for: f.url.lastPathComponent).shortcut == nil)
        let run = relaunched.savedLayoutApplier?.lastRun?.date
        keys.monitor.handleHotKey(id: firstID)
        #expect(relaunched.savedLayoutApplier?.isBusy == false && relaunched.savedLayoutApplier?.lastRun?.date == run)
        #expect(relaunched.setSavedLayoutActions(moved.lastPathComponent, .init(shortcut: key)))
        let renamedID = try #require(keys.namedIDs.first)
        #expect(renamedID > firstID)
        try FileManager.default.removeItem(at: moved)
        relaunched.savedLayoutActions.checkForChanges()
        #expect(keys.namedIDs.isEmpty)
        keys.monitor.handleHotKey(id: renamedID)
        #expect(relaunched.savedLayoutApplier?.isBusy == false)
    }
}


extension SavedLayoutActionsTests {
    @Test func modeAndWindowActionsRememberTheirScreenButLaunchDoesNot() async throws {
        for modeChange in [true, false] {
            let f = try SavedLayoutActionFixture(); defer { f.close() }
            if modeChange { f.model.setActiveMode(.manual) }
            else { f.model.perform(.center) }
            f.system.focusedWindowIsAbsent = true
            #expect(f.model.applySavedLayoutAction(f.url.lastPathComponent))
            await f.finish()
            #expect(f.model.savedLayoutApplier?.lastRun?.displayID == f.other.id)
            f.model.shutdown()
            let keys = FakeSavedLayoutHotKeys()
            let reopened = makeOffscreenModel(store: .init(fileURL: f.root.appendingPathComponent("config.json")),
                system: f.system, shortcutMonitor: keys.monitor)
            defer { reopened.shutdown() }
            #expect(!reopened.applySavedLayoutAction(f.url.lastPathComponent))
            #expect(reopened.statusMessage == "Focus an app window to apply a layout.")
        }
    }

    @Test func outsideRunKeepsDirtySettingsDraftAndItsUndo() async throws {
        let f = try SavedLayoutActionFixture(); defer { f.close() }
        let editor = SavedLayoutEditor(files: f.files)
        #expect(editor.load(f.url))
        editor.assign(bundleID: "com.example.Other", pane: nil, floating: true)
        #expect(editor.isDirty)
        let draft = editor.document
        #expect(f.model.applySavedLayoutAction(f.url.lastPathComponent))
        await f.finish()
        let applier = try #require(f.model.savedLayoutApplier)
        let date = applier.lastRun?.date
        let page = SavedLayoutSettings(editor: editor, model: f.model, suppliedSession: .init(applier: applier))
        page.initializePage()
        #expect(editor.isDirty && editor.document == draft)
        #expect(applier.lastRun?.date == date && applier.canUndo)
    }
}
