import AppKit
import Darwin
@testable import BetterTileMacOS
import BetterTileCore
import BetterTileTestSupport
import SwiftUI
import Testing
@testable import BetterTileApp

@MainActor private final class SavedLayoutWatchSpy: SavedLayoutWatching {
    var starts = 0
    var stops = 0
    var failStart = false
    var changed: (@MainActor () -> Void)?
    func start(directory: URL, actionsURL: URL, changed: @escaping @MainActor () -> Void) throws {
        starts += 1
        if failStart { throw CocoaError(.fileReadNoPermission) }
        self.changed = changed
    }
    func synchronize() throws {}
    func stop() { stops += 1; changed = nil }
}

@MainActor private final class SavedLayoutEventSpy: SavedLayoutFileEvents {
    var failure: POSIXErrorCode?
    var starts = 0
    var root: URL?
    var changed: (@MainActor ([URL], Bool) -> Void)?
    func start(root: URL, changed: @escaping @MainActor ([URL], Bool) -> Void) throws {
        starts += 1
        if let failure { throw POSIXError(failure) }
        self.root = root; self.changed = changed
    }
    func stop() { root = nil; changed = nil }
}

@Suite(.appTestApplication, .timeLimit(.minutes(1))) @MainActor struct SavedLayoutObservationTests {
    @Test func catalogUsesOnlyInjectedChangesAndStopsItsWatcher() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let files = SavedLayoutFiles(directory: root.appendingPathComponent("Saved Layouts"))
        let url = try files.create(SavedLayoutValidator.encode(.init(name: "Before", mode: .manual)))
        let watcher = SavedLayoutWatchSpy()
        let actions = SavedLayoutActions(files: files, watcher: watcher)
        defer { actions.stop() }
        var reloads = 0
        actions.didChange = { reloads += 1 }
        actions.start(); actions.start()
        #expect(watcher.starts == 1)
        #expect(actions.reloadTask == nil && reloads == 0)
        try SavedLayoutValidator.encode(.init(name: "After change", mode: .manual)).write(to: url, options: .atomic)
        watcher.changed?(); watcher.changed?()
        await actions.reloadTask?.value
        #expect(actions.entries.first?.name == "After change")
        #expect(reloads == 1 && actions.reloadTask == nil)
        watcher.changed?() // Duplicate OS notifications must not decode an unchanged catalog.
        await actions.reloadTask?.value
        #expect(reloads == 1 && actions.reloadTask == nil)
        let lateChange = watcher.changed
        actions.stop()
        #expect(watcher.changed == nil && watcher.stops == 1)
        lateChange?()
        #expect(actions.reloadTask == nil)
    }

    @Test func movedAndResizedEventsDoNotInvalidateSavedLayoutInventory() {
        let system = FakeAppWindowSystem()
        let model = makeOffscreenModel(system: system, startRuntime: false)
        defer { model.shutdown() }
        let revision = model.savedLayoutInventoryRevision
        for _ in 0..<50 {
            for kind in [WindowSystemEvent.Kind.moved, .resized] {
                system.eventHandler?(.init(kind: kind, windowID: system.windows.first?.id, processIdentifier: 42))
            }
        }
        #expect(model.savedLayoutInventoryRevision == revision)
    }

    @Test(arguments: [WindowSystemEvent.Kind.created, .destroyed, .minimized, .restored, .focused])
    func eligibleInventoryEventsStillInvalidateThePreview(kind: WindowSystemEvent.Kind) {
        let system = FakeAppWindowSystem()
        let model = makeOffscreenModel(system: system, startRuntime: false)
        defer { model.shutdown() }
        let revision = model.savedLayoutInventoryRevision
        system.eventHandler?(.init(kind: kind, windowID: system.windows.first?.id, processIdentifier: 42))
        #expect(model.savedLayoutInventoryRevision == revision + 1)
    }

    @Test func desktopChangesInvalidateThePreviewAfterStabilization() async throws {
        let system = FakeAppWindowSystem()
        let model = makeOffscreenModel(system: system, startRuntime: false)
        defer { model.shutdown() }
        let revision = model.savedLayoutInventoryRevision
        model.beginActiveSpaceStabilization()
        try await waitForSavedLayoutState("The desktop did not finish stabilizing.") { !model.isStabilizingSpace }
        #expect(model.savedLayoutInventoryRevision > revision)
    }
}

extension SavedLayoutObservationTests {
    @Test func folderRecreationKeepsSettingsUntilTheLibraryCanBeListedAgain() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let files = SavedLayoutFiles(directory: root.appendingPathComponent("Saved Layouts"))
        let document = SavedLayoutDocument(name: "Desk", mode: .manual)
        let data = try SavedLayoutValidator.encode(document)
        let url = try files.create(data)
        let watcher = SavedLayoutWatchSpy()
        let actions = SavedLayoutActions(files: files, watcher: watcher)
        defer { actions.stop() }
        #expect(actions.store.set(url.lastPathComponent, .init(showInMenuBar: true)))
        actions.start()
        try FileManager.default.removeItem(at: files.directory)
        watcher.changed?(); await actions.reloadTask?.value
        #expect(actions.entries.isEmpty)
        #expect(actions.store.settings(for: url.lastPathComponent).showInMenuBar)
        try FileManager.default.createDirectory(at: files.directory, withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        watcher.changed?(); await actions.reloadTask?.value
        #expect(actions.menuEntries.first?.file == url.lastPathComponent)
        // A confirmed file deletion in a present, readable library still removes its settings.
        var reloads = 0
        actions.didChange = { reloads += 1 }
        try FileManager.default.removeItem(at: url)
        watcher.changed?(); await actions.reloadTask?.value
        #expect(actions.store.settings(for: url.lastPathComponent) == .init())
        #expect(reloads == 1)
    }

    @Test func stoppingCancelsQueuedReloadAndWatchFailureCanBeRetried() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let files = SavedLayoutFiles(directory: root.appendingPathComponent("Saved Layouts"))
        _ = try files.create(SavedLayoutValidator.encode(.init(name: "Before", mode: .manual)))
        let watcher = SavedLayoutWatchSpy()
        watcher.failStart = true
        let actions = SavedLayoutActions(files: files, watcher: watcher)
        actions.start()
        #expect(actions.message?.contains("could not be watched") == true)
        #expect(watcher.stops == 1 && watcher.changed == nil)
        #expect(actions.entries.first?.name == "Before")
        watcher.failStart = false
        actions.start()
        #expect(actions.message == nil && watcher.starts == 2)
        var reloads = 0
        actions.didChange = { reloads += 1 }
        watcher.changed?()
        let queued = actions.reloadTask
        actions.stop()
        await queued?.value
        #expect(actions.reloadTask == nil && reloads == 0)
        #expect(watcher.stops == 2)
    }

    @Test(.settingsUI, arguments: ["created", "display", "desktop", "removed-display"])
    func anInventoryChangeReplansTheHostedPageOnce(change: String) async throws {
        let f = SavedLayoutDisplayPickerFixture(); defer { f.close() }
        let display = SavedLayoutDisplayPickerFixture.a.id
        let first = WindowID(rawValue: "safari-one"), second = WindowID(rawValue: "safari-two")
        f.system.windows = [.init(id: first, processIdentifier: 42, bundleIdentifier: "com.apple.Safari",
            frame: .init(x: 50, y: 50, width: 300, height: 300), displayID: display)]
        f.system.desktopObservation?.windowMembership[first] = [.init(rawValue: 1)]
        f.model.watchdog()
        #expect(f.editor.save())
        let applier = try #require(f.model.savedLayoutApplier)
        applier.application = { .init(bundleIdentifier: $0, name: "Safari", url: URL(filePath: "/fixture/Safari.app")) }
        var previews = 0
        let snapshot = applier.snapshot
        applier.snapshot = { previews += 1; return try snapshot() }
        let page = f.page
        page.initializePage(); page.refreshTarget()
        let clock = ManualClock()
        page.pagePlan.delay = { try? await clock.sleep(for: $0) }
        let host = NSHostingView(rootView: page.frame(width: 860, height: 1500))
        let window = OffscreenTestWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 1500),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.close(); page.pagePlan.cancel() }
        try await waitForSavedLayoutSnapshot(in: host) {
            page.groupsIntegration.section != nil && !applier.isLoadingAppGroups && page.pagePlan.preview?.windows.count == 1
        }
        previews = 0
        let revision = f.model.savedLayoutInventoryRevision
        let originalFrame = f.system.windows[0].frame
        let desktopReads = f.system.nativeDesktopReadCount
        let desktopRefreshes = f.system.nativeDesktopRefreshCount
        for index in 0..<50 {
            f.system.windows[0].frame.origin.x = originalFrame.minX + Double(index + 1)
            f.system.eventHandler?(.init(kind: .moved, windowID: first, processIdentifier: 42))
            f.system.windows[0].frame.size.width = originalFrame.size.width + Double(index + 1)
            f.system.eventHandler?(.init(kind: .resized, windowID: first, processIdentifier: 42))
        }
        let sameDisplayTask = try #require(f.model.windowEventTask)
        await sameDisplayTask.value
        #expect(f.system.windows[0].frame != originalFrame)
        #expect(f.system.windows[0].displayID == display)
        #expect(f.model.observedRuleWindows.first?.frame == f.system.windows[0].frame)
        #expect(f.system.nativeDesktopReadCount - desktopReads == 1)
        #expect(f.system.nativeDesktopRefreshCount == desktopRefreshes)
        try #require(f.model.savedLayoutInventoryRevision == revision)
        #expect(previews == 0 && clock.pendingSleepCount == 0)
        if change == "created" {
            f.system.windows.append(.init(id: second, processIdentifier: 42, bundleIdentifier: "com.apple.Safari",
                frame: .init(x: 400, y: 50, width: 300, height: 300), displayID: display))
            f.system.desktopObservation?.windowMembership[second] = [.init(rawValue: 1)]
            f.system.eventHandler?(.init(kind: .created, windowID: second, processIdentifier: 42))
        } else if change == "removed-display" {
            f.model.displayRefreshDebouncer = .init(clock: clock.clock)
            f.system.availableDisplays.removeAll { $0.id == SavedLayoutDisplayPickerFixture.b.id }
            f.live.removeAll { $0.id == SavedLayoutDisplayPickerFixture.b.id }
            f.model.scheduleDisplayRefresh()
            await clock.waitForSleepers(count: 1)
            let refresh = try #require(f.model.displayRefreshDebouncer.task)
            clock.advance(by: .milliseconds(120))
            await refresh.value
        } else {
            if change == "display" {
                f.system.windows[0].displayID = SavedLayoutDisplayPickerFixture.b.id
                f.system.windows[0].frame.origin.x += 1000
                f.system.desktopObservation?.windowMembership[first] = [.init(rawValue: 2)]
            } else {
                f.system.desktopObservation?.windowMembership[first] = [.init(rawValue: 99)]
            }
            for _ in 0..<50 {
                f.system.eventHandler?(.init(kind: .moved, windowID: first, processIdentifier: 42))
                f.system.eventHandler?(.init(kind: .resized, windowID: first, processIdentifier: 42))
            }
            let eventTask = try #require(f.model.windowEventTask)
            await eventTask.value
        }
        // Check the revision before waiting for a clock sleeper, so the old code fails promptly.
        try await waitForSettingsUI("the changed inventory revision", in: host) {
            f.model.savedLayoutInventoryRevision > revision || (change != "created" && f.model.windowEventTask == nil)
        }
        try #require(f.model.savedLayoutInventoryRevision > revision)
        await clock.waitForSleepers(count: 1)
        clock.advance(by: .milliseconds(250))
        try await waitForSettingsUI("the updated inventory proposal", in: host) { previews > 0 }
        #expect(previews == 1)
        if change == "created" { #expect(page.pagePlan.preview?.windows.contains { $0.id == second } == true) }
        if change == "display" { #expect(f.model.savedLayoutInventoryRevision == revision + 1) }
    }
}

@MainActor private func waitForCatalog(_ events: AsyncStream<Void>, until ready: () -> Bool) async throws {
    if ready() { return }
    for await _ in events { if ready() { return } }
    try #require(ready(), "The file-system change did not reach the Saved Layout catalog.")
}

extension SavedLayoutObservationTests {
    @Test func nativeWatcherFindsCreationInPlaceEditsReplacementAndRecreatedFolders() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let files = SavedLayoutFiles(directory: root.appendingPathComponent("Saved Layouts"))
        let actions = SavedLayoutActions(files: files)
        defer { actions.stop() }
        let (events, changed) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        defer { changed.finish() }
        actions.didChange = { changed.yield() }
        actions.start()
        let url = try files.create(SavedLayoutValidator.encode(.init(name: "Original", mode: .manual)))
        try await waitForCatalog(events) { actions.entries.first?.name == "Original" }
        let fixedDate = Date(timeIntervalSince1970: 1000)
        var dateObserved = false
        actions.didChange = { dateObserved = true; changed.yield() }
        try FileManager.default.setAttributes([.modificationDate: fixedDate], ofItemAtPath: url.path)
        try await waitForCatalog(events) { dateObserved }
        let before = try #require(SavedLayoutFileStamp(url))
        let bytes = try SavedLayoutValidator.encode(SavedLayoutDocument(name: "In place", mode: .manual))
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: 0); try handle.write(contentsOf: bytes); try handle.close()
        try FileManager.default.setAttributes([.modificationDate: fixedDate], ofItemAtPath: url.path)
        let after = try #require(SavedLayoutFileStamp(url))
        #expect(before.identity == after.identity && before.size == after.size)
        #expect(before.modifiedSeconds == after.modifiedSeconds && before.modifiedNanoseconds == after.modifiedNanoseconds)
        try await waitForCatalog(events) { actions.entries.first?.name == "In place" }
        try SavedLayoutValidator.encode(.init(name: "Replaced", mode: .manual)).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.modificationDate: fixedDate], ofItemAtPath: url.path)
        try await waitForCatalog(events) { actions.entries.first?.name == "Replaced" }
        try FileManager.default.removeItem(at: files.directory)
        try await waitForCatalog(events) { actions.entries.isEmpty }
        _ = try files.create(SavedLayoutValidator.encode(.init(name: "Folder recreated", mode: .manual)))
        try await waitForCatalog(events) { actions.entries.first?.name == "Folder recreated" }
        try FileManager.default.removeItem(at: root)
        try await waitForCatalog(events) { actions.entries.isEmpty }
        _ = try files.create(SavedLayoutValidator.encode(.init(name: "Parent recreated", mode: .manual)))
        try await waitForCatalog(events) { actions.entries.first?.name == "Parent recreated" }
        try FileManager.default.removeItem(at: files.directory)
        _ = try files.create(SavedLayoutValidator.encode(.init(name: "Recreated without a gap", mode: .manual)))
        try await waitForCatalog(events) { actions.entries.first?.name == "Recreated without a gap" }
    }

    @Test func nativeWatcherReloadsAnExternallyReplacedActionsFile() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let files = SavedLayoutFiles(directory: root.appendingPathComponent("Saved Layouts"))
        let url = try files.create(SavedLayoutValidator.encode(.init(name: "Desk", mode: .manual)))
        let actions = SavedLayoutActions(files: files)
        defer { actions.stop() }
        let (events, changed) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        defer { changed.finish() }
        actions.didChange = { changed.yield() }
        actions.start()
        let external = SavedLayoutActionStore(files: files)
        #expect(external.set(url.lastPathComponent, .init(showInWheel: true)))
        try await waitForCatalog(events) { actions.wheelEntries.first?.file == url.lastPathComponent }
        #expect(external.set(url.lastPathComponent, .init(showInMenuBar: true)))
        try await waitForCatalog(events) { actions.menuEntries.first?.file == url.lastPathComponent && actions.wheelEntries.isEmpty }
        try FileManager.default.removeItem(at: actions.store.url)
        try await waitForCatalog(events) { actions.menuEntries.isEmpty }
    }

    @Test func aReleasedCatalogDoesNotRetainItsNativeWatcher() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var watcher: SavedLayoutFileWatcher? = SavedLayoutFileWatcher()
        weak var released = watcher
        var actions: SavedLayoutActions? = SavedLayoutActions(
            files: .init(directory: root.appendingPathComponent("Saved Layouts")), watcher: watcher!)
        actions?.start()
        actions = nil; watcher = nil
        #expect(released == nil)
    }
}

extension SavedLayoutObservationTests {
    @Test func partialWritesWaitForTheTrailingEdgeAndRetryWithoutPublishingAnEmptyCatalog() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let files = SavedLayoutFiles(directory: root.appendingPathComponent("Saved Layouts"))
        let url = try files.create(SavedLayoutValidator.encode(.init(name: "Before", mode: .manual)))
        let watcher = SavedLayoutWatchSpy(), clock = ManualClock()
        let actions = SavedLayoutActions(files: files, watcher: watcher, clock: clock.clock)
        defer { actions.stop() }
        var reloads = 0
        actions.didChange = { reloads += 1 }
        actions.start()
        let data = try SavedLayoutValidator.encode(SavedLayoutDocument(name: "After", mode: .manual))
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: 0); try handle.write(contentsOf: data.prefix(data.count / 2))
        watcher.changed?()
        var finished = false
        let first = try #require(actions.reloadTask)
        let completion = Task { await first.value; finished = true }
        defer { completion.cancel() }
        try await waitForSavedLayoutState("The reload neither waited nor completed.") { clock.pendingSleepCount == 1 || finished }
        try #require(clock.pendingSleepCount == 1)
        clock.advance(by: .milliseconds(100))
        watcher.changed?() // A second write notification resets the trailing delay.
        await clock.waitForSleepers(count: 1)
        let trailing = try #require(actions.reloadTask)
        clock.advance(by: .milliseconds(149))
        #expect(reloads == 0 && actions.entries.first?.name == "Before")
        clock.advance(by: .milliseconds(1))
        await clock.waitForSleepers(count: 1) // Invalid data gets a bounded retry, not a publication.
        #expect(reloads == 0 && actions.entries.first?.name == "Before")
        try handle.write(contentsOf: data.suffix(data.count - data.count / 2)); try handle.close()
        // No additional notification: the retry itself must find the completed file.
        clock.advance(by: .milliseconds(50))
        await trailing.value
        #expect(actions.entries.first?.name == "After" && reloads == 1)
        #expect(actions.reloadTask == nil && clock.pendingSleepCount == 0)
    }

    @Test(arguments: [POSIXErrorCode.EACCES, .EMFILE])
    func fileEventFailureKeepsDirectoryEventsAndRetriesOnReload(error: POSIXErrorCode) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let files = SavedLayoutFiles(directory: root.appendingPathComponent("Saved Layouts"))
        let url = try files.create(SavedLayoutValidator.encode(.init(name: "Before", mode: .manual)))
        let backend = SavedLayoutEventSpy(); backend.failure = error
        let watcher = SavedLayoutFileWatcher(events: backend)
        let actions = SavedLayoutActions(files: files, watcher: watcher)
        defer { actions.stop() }
        let (events, changed) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        defer { changed.finish() }
        actions.didChange = { changed.yield() }
        actions.start()
        #expect(watcher.hasUnwatchedFiles && backend.root == nil)
        #expect(actions.message?.contains("additions and removals are still watched") == true)
        try SavedLayoutValidator.encode(.init(name: "Replaced", mode: .manual)).write(to: url, options: .atomic)
        try await waitForCatalog(events) { actions.entries.first?.name == "Replaced" }
        let before = backend.starts
        backend.failure = nil
        actions.reload()
        #expect(backend.starts > before && backend.root != nil && !watcher.hasUnwatchedFiles && actions.message == nil)
        try SavedLayoutValidator.encode(.init(name: "In place", mode: .manual)).write(to: url)
        backend.changed?([url], false)
        try await waitForCatalog(events) { actions.entries.first?.name == "In place" }
    }

    @Test func unreadableLayoutNeedsNoHandleAndDoesNotStopOtherFileEvents() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let files = SavedLayoutFiles(directory: root.appendingPathComponent("Saved Layouts"))
        let bad = try files.create(SavedLayoutValidator.encode(.init(name: "Unavailable", mode: .manual)))
        let good = try files.create(SavedLayoutValidator.encode(.init(name: "Other", mode: .manual)))
        var openedFiles = 0
        let watcher = SavedLayoutFileWatcher(openFile: { url in
            if SavedLayoutFileStamp(url)?.isDirectory != true { openedFiles += 1; throw POSIXError(.EMFILE) }
            let descriptor = open(url.path, O_EVTONLY | O_CLOEXEC | O_NOFOLLOW)
            guard descriptor >= 0 else { throw POSIXError(.EIO) }
            return descriptor
        })
        let actions = SavedLayoutActions(files: files, watcher: watcher)
        defer { actions.stop() }
        let (events, changed) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        defer { changed.finish() }
        actions.didChange = { changed.yield() }
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: bad.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: bad.path) }
        actions.start()
        try SavedLayoutValidator.encode(.init(name: "Other edited", mode: .manual)).write(to: good, options: .atomic)
        try await waitForCatalog(events) { actions.entries.contains { $0.name == "Other edited" } }
        #expect(openedFiles == 0 && !watcher.hasUnwatchedFiles)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: bad.path)
        actions.reload()
        try SavedLayoutValidator.encode(.init(name: "Readable edited", mode: .manual)).write(to: bad)
        try await waitForCatalog(events) { actions.entries.contains { $0.name == "Readable edited" } }
        #expect(openedFiles == 0)
    }

    @Test func libraryReloadRestartsAFailedWatch() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let watcher = SavedLayoutWatchSpy(); watcher.failStart = true
        let actions = SavedLayoutActions(files: .init(directory: root.appendingPathComponent("Saved Layouts")), watcher: watcher)
        defer { actions.stop() }
        actions.start()
        #expect(watcher.starts == 1 && actions.message != nil)
        watcher.failStart = false
        actions.reload()
        #expect(watcher.starts == 2 && watcher.changed != nil && actions.message == nil)
    }
}

extension SavedLayoutObservationTests {
    @Test func sameSizeInPlaceEditWithAnAlreadyObservedDateUsesChangeTime() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let files = SavedLayoutFiles(directory: root.appendingPathComponent("Saved Layouts"))
        let url = try files.create(SavedLayoutValidator.encode(.init(name: "Before", mode: .manual)))
        let date = Date(timeIntervalSince1970: 1000)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        let watcher = SavedLayoutWatchSpy(), clock = ManualClock()
        let actions = SavedLayoutActions(files: files, watcher: watcher, clock: clock.clock)
        defer { actions.stop() }
        actions.start() // The catalog's baseline already includes the preserved date.
        let before = try #require(SavedLayoutFileStamp(url))
        let data = try SavedLayoutValidator.encode(SavedLayoutDocument(name: "After!", mode: .manual))
        let handle = try FileHandle(forWritingTo: url)
        try handle.write(contentsOf: data); try handle.close()
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        let after = try #require(SavedLayoutFileStamp(url))
        #expect(before.identity == after.identity && before.size == after.size && before.mode == after.mode)
        #expect(before.modifiedSeconds == after.modifiedSeconds && before.modifiedNanoseconds == after.modifiedNanoseconds)
        try #require(before.changedSeconds != after.changedSeconds || before.changedNanoseconds != after.changedNanoseconds)
        watcher.changed?()
        await clock.waitForSleepers(count: 1)
        let reload = try #require(actions.reloadTask)
        clock.advance(by: .milliseconds(150)); await reload.value
        #expect(actions.entries.first?.name == "After!")
    }

    @Test func stoppingCancelsAnActuallySuspendedReload() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let watcher = SavedLayoutWatchSpy(), clock = ManualClock()
        let actions = SavedLayoutActions(files: .init(directory: root.appendingPathComponent("Saved Layouts")), watcher: watcher, clock: clock.clock)
        actions.start(); watcher.changed?()
        await clock.waitForSleepers(count: 1)
        let queued = try #require(actions.reloadTask)
        defer { queued.cancel() }
        actions.stop()
        try #require(clock.pendingSleepCount == 0)
        await queued.value
        #expect(actions.reloadTask == nil)
    }
}

extension SavedLayoutObservationTests {
    @Test func aPermanentlyInvalidWritePublishesOnceAtTheRetryLimitAndStopsWaiting() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let files = SavedLayoutFiles(directory: root.appendingPathComponent("Saved Layouts"))
        let url = try files.create(SavedLayoutValidator.encode(.init(name: "Before", mode: .manual)))
        let watcher = SavedLayoutWatchSpy(), clock = ManualClock()
        let actions = SavedLayoutActions(files: files, watcher: watcher, clock: clock.clock)
        defer { actions.stop() }
        #expect(actions.store.set(url.lastPathComponent, .init(showInMenuBar: true)))
        var reloads = 0
        actions.didChange = { reloads += 1 }
        actions.start()
        try Data("{".utf8).write(to: url)
        watcher.changed?()
        await clock.waitForSleepers(count: 1)
        let queued = try #require(actions.reloadTask)
        clock.advance(by: .milliseconds(150))
        await clock.waitForSleepers(count: 1)
        #expect(actions.entries.first?.name == "Before" && reloads == 0)
        clock.advance(by: .milliseconds(350))
        await queued.value
        #expect(actions.entries.isEmpty && reloads == 1)
        #expect(actions.store.settings(for: url.lastPathComponent).showInMenuBar)
        #expect(actions.reloadTask == nil && clock.pendingSleepCount == 0)
    }
}

extension SavedLayoutObservationTests {
    @Test(arguments: [false, true])
    func continuousWritesPublishByTheMaximumWaitAndStartANewBurst(incomplete: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let files = SavedLayoutFiles(directory: root.appendingPathComponent("Saved Layouts"))
        let url = try files.create(SavedLayoutValidator.encode(.init(name: "Before", mode: .manual)))
        let watcher = SavedLayoutWatchSpy(), clock = ManualClock()
        let actions = SavedLayoutActions(files: files, watcher: watcher, clock: clock.clock)
        defer { actions.stop() }
        var reloads = 0
        actions.didChange = { reloads += 1 }
        actions.start()
        for index in 0..<10 {
            let data = incomplete ? Data("{".utf8)
                : try SavedLayoutValidator.encode(.init(name: "Write \(index)", mode: .manual))
            try data.write(to: url)
            watcher.changed?()
            await clock.waitForSleepers(count: 1)
            clock.advance(by: .milliseconds(100)) // Every gap is shorter than the 150 ms trailing wait.
            if index < 9 { #expect(reloads == 0) }
        }
        // A notification arriving at the cap must not cancel the check that is already due.
        let finalData = incomplete ? Data("{{".utf8)
            : try SavedLayoutValidator.encode(.init(name: "Write 10", mode: .manual))
        try finalData.write(to: url)
        watcher.changed?()
        // Join either completion or the next pending wait. The old debounce fails promptly here.
        let last = try #require(actions.reloadTask)
        var finished = false
        let completion = Task { await last.value; finished = true }
        defer { last.cancel(); completion.cancel() }
        try await waitForSavedLayoutState("The continuous-write reload did not resume.") {
            finished || clock.pendingSleepCount == 1
        }
        try #require(finished)
        #expect(incomplete ? actions.entries.isEmpty : actions.entries.first?.name == "Write 10")
        #expect(reloads == 1)
        #expect(actions.reloadTask == nil && clock.pendingSleepCount == 0)
        try SavedLayoutValidator.encode(.init(name: "Next burst", mode: .manual)).write(to: url)
        watcher.changed?()
        await clock.waitForSleepers(count: 1)
        let next = try #require(actions.reloadTask)
        clock.advance(by: .milliseconds(150)); await next.value
        #expect(actions.entries.first?.name == "Next burst" && reloads == 2)
        #expect(actions.reloadTask == nil && clock.pendingSleepCount == 0)
    }
}


extension SavedLayoutObservationTests {
    @Test func aLargeLibraryUsesOnlyDirectoryHandles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let files = SavedLayoutFiles(directory: root.appendingPathComponent("Saved Layouts"))
        let data = try SavedLayoutValidator.encode(SavedLayoutDocument(name: "Desk", mode: .manual))
        _ = try files.create(data)
        var attempts = 0
        let backend = SavedLayoutEventSpy()
        let watcher = SavedLayoutFileWatcher(openFile: { url in
            attempts += 1
            // Model a process that has no descriptor budget for individual layout files.
            guard SavedLayoutFileStamp(url)?.isDirectory == true else { throw POSIXError(.EMFILE) }
            let descriptor = open(url.path, O_EVTONLY | O_CLOEXEC | O_NOFOLLOW)
            guard descriptor >= 0 else { throw POSIXError(.EIO) }
            return descriptor
        }, events: backend)
        defer { watcher.stop() }
        try watcher.start(directory: files.directory, actionsURL: root.appendingPathComponent("Layout Actions.json"), changed: {})
        let smallLibraryAttempts = attempts
        for _ in 0..<511 { _ = try files.create(data) }
        try watcher.synchronize()
        #expect(attempts == smallLibraryAttempts)
        #expect(attempts <= 2)
        #expect(backend.starts == 1 && backend.root != nil)
        #expect(!watcher.hasUnwatchedFiles)
        watcher.stop()
        #expect(backend.root == nil && backend.changed == nil)
    }
}


extension SavedLayoutObservationTests {
    @Test func fileEventsIgnoreSiblingsRecoverDroppedEventsAndStopOnRelease() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let files = SavedLayoutFiles(directory: root.appendingPathComponent("Saved Layouts"))
        let url = try files.create(SavedLayoutValidator.encode(.init(name: "Desk", mode: .manual)))
        let backend = SavedLayoutEventSpy()
        var watcher: SavedLayoutFileWatcher? = .init(events: backend)
        var changes = 0
        try watcher?.start(directory: files.directory, actionsURL: root.appendingPathComponent("Layout Actions.json"), changed: { changes += 1 })
        changes = 0
        backend.changed?([root.appendingPathComponent("configuration.json")], false)
        #expect(changes == 0)
        backend.changed?([url], false)
        #expect(changes == 1)
        backend.changed?([], true)
        #expect(changes == 2)
        try watcher?.synchronize()
        #expect(backend.starts == 2 && backend.root != nil)
        let late = backend.changed
        watcher = nil
        #expect(backend.root == nil && backend.changed == nil)
        let before = changes
        late?([url], true)
        #expect(changes == before)
    }
}


extension SavedLayoutObservationTests {
    @Test func releasingACatalogCancelsItsPendingWaitAndStopsObservation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let watcher = SavedLayoutWatchSpy(), clock = ManualClock()
        var actions: SavedLayoutActions? = .init(files: .init(directory: root.appendingPathComponent("Saved Layouts")),
            watcher: watcher, clock: clock.clock)
        actions?.start(); watcher.changed?()
        await clock.waitForSleepers(count: 1)
        let queued = try #require(actions?.reloadTask)
        defer { queued.cancel() }
        actions = nil
        try #require(clock.pendingSleepCount == 0)
        await queued.value
        #expect(watcher.changed == nil)
    }
}
