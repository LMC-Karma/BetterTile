import AppKit
import Foundation
import BetterTileCore
import Testing
@testable import BetterTileApp
@testable import BetterTileMacOS

/// No hosted window or live Accessibility read is needed to inspect page ownership.
@Test(.appTestApplication) @MainActor func savedLayoutTargetKeepsRecoveryWhenInitialDisplayWasNil() async throws {
    let f = ApplySessionFixture()
    f.rows = [f.row("ready", .matched(f.window("one")))]
    f.session.apply(document: f.document)
    try await f.finish()
    let desktop = SavedLayoutDesktop(displayID: f.display, spaceID: .init(rawValue: 1))
    f.runtime.owner = .init(document: f.document, desktop: desktop)
    let system = FakeAppWindowSystem()
    system.availableDisplays.append(.init(id: f.display,
        frame: .init(x: 1000, y: 0, width: 1000, height: 800),
        visibleFrame: .init(x: 1000, y: 0, width: 1000, height: 800)))
    system.desktopObservation = .init(currentSpaceByDisplay: [f.display: desktop.spaceID],
        knownSpacesByDisplay: [f.display: [desktop.spaceID]])
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SavedLayoutTarget-" + UUID().uuidString)
    let model = BetterTileModel(store: .init(fileURL: directory.appendingPathComponent("configuration.json")),
        system: system, startRuntime: false)
    model.hasAccessibilityPermission = true
    defer { model.shutdown(); try? FileManager.default.removeItem(at: directory) }
    let editor = SavedLayoutEditor(files: .init(directory: directory.appendingPathComponent("layouts")))
    editor.newLayout()
    #expect(editor.edit { $0 = f.document })
    let page = SavedLayoutSettings(editor: editor, model: model, suppliedSession: f.session)
    #expect(page.ownsSelection(f.document))
    #expect(page.pageStatus(f.document, states: [:]) != "Ready to apply")
    #expect(f.session.canUndo)
}

@Suite(.appTestApplication) @MainActor struct SavedLayoutTargetTests {
    let a = DisplaySnapshot(id: .init(rawValue: "a"),
        frame: .init(x: 0, y: 0, width: 1000, height: 800),
        visibleFrame: .init(x: 0, y: 0, width: 1000, height: 800), isMain: true)
    let b = DisplaySnapshot(id: .init(rawValue: "b"),
        frame: .init(x: 1000, y: 0, width: 1000, height: 800),
        visibleFrame: .init(x: 1000, y: 0, width: 1000, height: 800))

    @Test func refreshReplacesCachedFocusAndRejectsDisconnectedIDs() {
        let target = SavedLayoutTarget()
        target.refresh(current: { a.id }, displays: [b, a])
        #expect(target.displayID == a.id)
        target.refresh(current: { b.id }, displays: [b, a])
        #expect(target.displayID == b.id)
        target.refresh(current: { b.id }, displays: [a])
        #expect(target.displayID == a.id)
        target.refresh(current: { nil }, displays: [b, a])
        #expect(target.displayID == a.id)
        target.refresh(current: { nil }, displays: [b])
        #expect(target.displayID == b.id)
        target.refresh(current: { b.id }, displays: [])
        #expect(target.displayID == nil)
    }

    @Test func applyPublishesFreshTargetAndBindingDoesNotLatchLaterApply() {
        let target = SavedLayoutTarget()
        target.refresh(current: { a.id }, displays: [a, b])
        #expect(target.prepareApply(current: { b.id }, displays: [a, b]) == b.id)
        #expect(target.displayID == b.id)
        #expect(target.prepareApply(current: { b.id }, displays: [a, b], explicit: a.id) == a.id)
        #expect(target.displayID == a.id)
        #expect(target.prepareApply(current: { b.id }, displays: [a, b]) == b.id)
        #expect(target.displayID == b.id)
        #expect(target.prepareApply(current: { b.id }, displays: [b], explicit: a.id) == nil)
        #expect(target.displayID == nil)
    }

    @Test func ownerPinKeepsRunDisplayWhileFollowingRefreshesWithoutRenderReads() {
        let target = SavedLayoutTarget()
        var reads = 0
        let current = { reads += 1; return b.id as DisplayID? }
        target.refresh(current: current, displays: [a, b], retaining: a.id)
        #expect(target.displayID == a.id)
        #expect(reads == 1)
        #expect(target.selectionID == b.id)
        // Repeated label reads do not call the window system.
        for _ in 0..<20 { #expect(target.displayID == a.id) }
        #expect(reads == 1)
        target.refresh(current: current, displays: [a, b])
        #expect(target.displayID == b.id)
        #expect(reads == 2)
        target.refresh(current: current, displays: [a, b], retaining: a.id)
        #expect(target.prepareApply(current: current, displays: [a, b]) == b.id)
        #expect(target.displayID == b.id)
        #expect(reads == 4)
    }

    @Test func modelUsesFocusedManagedDisplayAndApplierSharesFallback() throws {
        let system = FakeAppWindowSystem()
        system.availableDisplays = [b, a]
        system.windows[0].displayID = b.id
        system.windows[0].frame = b.frame
        system.desktopObservation = .init(currentSpaceByDisplay: [a.id: .init(rawValue: 1), b.id: .init(rawValue: 2)],
            knownSpacesByDisplay: [a.id: [.init(rawValue: 1)], b.id: [.init(rawValue: 2)]])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SavedLayoutTarget-" + UUID().uuidString)
        let model = BetterTileModel(store: .init(fileURL: directory.appendingPathComponent("configuration.json")),
            system: system, startRuntime: false)
        defer { model.shutdown(); try? FileManager.default.removeItem(at: directory) }
        model.hasAccessibilityPermission = true
        let applier = try #require(model.savedLayoutApplier)
        #expect(!AccessibilityWindowSystem.shouldManageApplication(processIdentifier: getpid(),
            ownProcessIdentifier: getpid(), activationPolicy: .regular, isHidden: false, includeHidden: false))
        #expect(AccessibilityWindowSystem.shouldManageApplication(processIdentifier: 42,
            ownProcessIdentifier: getpid(), activationPolicy: .regular, isHidden: false, includeHidden: false))
        #expect(applier.currentDisplayID() == b.id)
        let document = SavedLayoutDocument(name: "Target", mode: .bento, layout: .empty)
        #expect(try applier.preview(document).displayID == b.id)
        system.focusedWindowIsAbsent = true
        #expect(applier.currentDisplayID() == nil)
        #expect(try applier.preview(document).displayID == a.id)
        applier.currentDisplayID = { b.id }
        system.availableDisplays = [a]
        #expect(try applier.preview(document).displayID == a.id)
        // A stale native observation must not make an explicitly disconnected target usable.
        #expect(throws: SavedLayoutFileError.self) { try applier.preview(document, displayID: b.id) }
    }
}

@Test(.appTestApplication) @MainActor func savedLayoutTargetPagePinsRecoveryAndReleasesAfterUndoOrDocumentChange() async throws {
    let f = ApplySessionFixture()
    f.rows = [f.row("ready", .matched(f.window("one")))]
    f.session.apply(document: f.document)
    try await waitForSavedLayoutState("Apply did not finish starting.") {
        if case .idle = f.session.phase { true } else { false }
    }
    try await f.finish()
    let a = f.display
    let b = DisplayID(rawValue: "focused-b")
    let space = NativeSpaceID(rawValue: 1)
    f.runtime.owner = .init(document: f.document, desktop: .init(displayID: a, spaceID: space))
    let system = FakeAppWindowSystem()
    system.availableDisplays = [a, b].map { id in
        .init(id: id, frame: .init(x: id == a ? 0 : 1000, y: 0, width: 1000, height: 800),
            visibleFrame: .init(x: id == a ? 0 : 1000, y: 0, width: 1000, height: 800), isMain: id == a)
    }
    system.windows[0].displayID = b
    system.desktopObservation = .init(currentSpaceByDisplay: [a: space, b: .init(rawValue: 2)],
        knownSpacesByDisplay: [a: [space], b: [.init(rawValue: 2)]])
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SavedLayoutTargetPage-" + UUID().uuidString)
    let model = BetterTileModel(store: .init(fileURL: directory.appendingPathComponent("configuration.json")),
        system: system, startRuntime: false)
    model.hasAccessibilityPermission = true
    defer { model.shutdown(); try? FileManager.default.removeItem(at: directory) }
    let editor = SavedLayoutEditor(files: .init(directory: directory.appendingPathComponent("layouts")))
    editor.newLayout(); #expect(editor.edit { $0 = f.document })
    let page = SavedLayoutSettings(editor: editor, model: model, suppliedSession: f.session)
    var reads = 0
    model.savedLayoutApplier?.currentDisplayID = { reads += 1; return b }
    page.refreshTarget()
    #expect(page.displayID == a)
    #expect(page.ownsSelection(f.document))
    #expect(reads == 1)
    _ = page.body
    #expect(reads == 1)
    // Finished recovery remains pinned even after Undo is no longer available.
    f.runtime.canUndo = false
    f.runtime.slotStatuses = ["ready": .failed(reason: "Try again")]
    page.refreshTarget()
    #expect(page.displayID == a)
    #expect(page.ownsSelection(f.document))
    f.runtime.slotStatuses = ["ready": .placed]
    page.refreshTarget()
    #expect(page.displayID == b)
    #expect(!page.ownsSelection(f.document))
    f.runtime.canUndo = true
    #expect(editor.edit { $0.name = "Another layout" })
    page.refreshTarget()
    #expect(page.displayID == b)
    #expect(!page.ownsSelection(try #require(editor.document)))
    let document = try #require(editor.document)
    page.apply(document)
    #expect(f.starts.last?.1 == b)
    #expect(page.displayID == b)
    let previousReads = reads
    model.savedLayoutApplier?.currentDisplayID = { reads += 1; return a }
    page.refreshTarget()
    #expect(page.displayID == b)
    #expect(reads == previousReads + 1)
}

@Test(.appTestApplication) @MainActor func savedLayoutTargetDisconnectedBindingShowsInlineError() throws {
    let system = FakeAppWindowSystem()
    let a = system.mainDisplay.id
    let missing = DisplayID(rawValue: "disconnected")
    system.desktopObservation = .init(currentSpaceByDisplay: [a: .init(rawValue: 1), missing: .init(rawValue: 2)],
        knownSpacesByDisplay: [a: [.init(rawValue: 1)], missing: [.init(rawValue: 2)]])
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SavedLayoutTargetError-" + UUID().uuidString)
    let model = BetterTileModel(store: .init(fileURL: directory.appendingPathComponent("configuration.json")),
        system: system, startRuntime: false)
    model.hasAccessibilityPermission = true
    defer { model.shutdown(); try? FileManager.default.removeItem(at: directory) }
    let session = SavedLayoutApplySession(applier: try #require(model.savedLayoutApplier))
    let editor = SavedLayoutEditor(files: .init(directory: directory.appendingPathComponent("layouts")))
    editor.newLayout()
    let page = SavedLayoutSettings(editor: editor, model: model, suppliedSession: session)
    page.apply(try #require(editor.document), on: missing)
    #expect(session.problem == "The current desktop could not be identified.")
    #expect(system.frameWriteCounts.isEmpty)
}

@Test(.appTestApplication) @MainActor func savedLayoutTargetRefreshesOnlyForItsContainingWindow() {
    _ = NSApplication.shared
    let pageWindow = NSWindow(contentRect: .init(x: 12000, y: 0, width: 400, height: 300),
        styleMask: .borderless, backing: .buffered, defer: true)
    let otherWindows = (0..<3).map { _ in
        NSWindow(contentRect: .init(x: 13000, y: 0, width: 200, height: 100),
            styleMask: .borderless, backing: .buffered, defer: true)
    }
    for window in [pageWindow] + otherWindows { window.isReleasedWhenClosed = false }
    defer { ([pageWindow] + otherWindows).forEach { $0.close() } }
    let displays = FakeAppWindowSystem().availableDisplays
    let first = displays[0].id
    let second = DisplayID(rawValue: "other-focus")
    var connected = displays
    connected.append(.init(id: second, frame: .init(x: 1000, y: 0, width: 1000, height: 800),
        visibleFrame: .init(x: 1000, y: 0, width: 1000, height: 800)))
    let target = SavedLayoutTarget()
    target.refresh(current: { first }, displays: connected)
    var reads = 0
    let anchor = SavedLayoutTargetWindowObserver.Anchor()
    anchor.onBecameKey = {
        target.refresh(current: { reads += 1; return second }, displays: connected)
    }
    pageWindow.contentView = anchor
    // Sheets, the float picker, and Setup each have a separate NSWindow identity.
    for other in otherWindows {
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: other)
        #expect(reads == 0)
        #expect(target.displayID == first)
    }
    NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: pageWindow)
    #expect(reads == 1)
    #expect(target.displayID == second)
    // Detaching the page removes its old window subscription.
    anchor.removeFromSuperview()
    NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: pageWindow)
    #expect(reads == 1)
    // Reusing the page in another window observes only that new containing window.
    otherWindows[0].contentView = anchor
    NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: pageWindow)
    #expect(reads == 1)
    NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: otherWindows[0])
    #expect(reads == 2)
    anchor.stopObserving()
    NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: otherWindows[0])
    #expect(reads == 2)
    #expect(([pageWindow] + otherWindows).allSatisfy { !$0.isVisible })
}
