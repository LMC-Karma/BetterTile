import AppKit
import BetterTileCore
import SwiftUI
import Testing
@testable import BetterTileApp

@MainActor private final class Released<T: AnyObject> {
    weak var value: T?
    init(_ value: T?) { self.value = value }
}

/// Settings opened and closed through the app delegate, as the app does, in an off-screen window.
@MainActor private final class SettingsWindowHarness {
    let model: BetterTileModel
    let delegate: BetterTileAppDelegate
    let layouts: URL

    init(frameAutosaveName: String? = nil) {
        model = makeModel(system: FakeAppWindowSystem())
        layouts = URL(filePath: NSTemporaryDirectory())
            .appending(path: "SettingsWindowLifetimeTests-\(UUID().uuidString)/Saved Layouts", directoryHint: .isDirectory)
        delegate = BetterTileAppDelegate(model: model, settingsPresentation: .init(
            makeWindow: { OffscreenTestWindow(contentViewController: $0) },
            savedLayoutEditor: SavedLayoutEditor(files: .init(directory: layouts)),
            frameAutosaveName: frameAutosaveName))
    }

    func shutdown() {
        delegate.settingsWindowForTesting?.close()
        model.shutdown()
        try? FileManager.default.removeItem(at: layouts.deletingLastPathComponent())
    }

    /// Opens Settings and waits until its sidebar is laid out.
    @discardableResult func open() async throws -> NSWindow {
        delegate.showSettingsForTesting()
        let window = try #require(delegate.settingsWindowForTesting)
        let view = try #require(window.contentView)
        try await waitForSettingsUI("the Settings sidebar", in: view) { sidebar(in: window) != nil }
        return window
    }

    func visit(_ destination: SettingsDestination, in window: NSWindow) async throws {
        model.requestedSettingsDestination = destination
        let view = try #require(window.contentView)
        try await waitForSettingsUI("the \(destination.rawValue) page", in: view) {
            model.requestedSettingsDestination == nil && selectedPage(in: window) == destination
        }
    }
}

@MainActor private func views<T: NSView>(_ view: NSView, _ type: T.Type) -> [T] {
    ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { views($0, type) }
}

/// Per-App Rules has its own list. The sidebar is the left-most one.
@MainActor private func sidebar(in window: NSWindow) -> NSOutlineView? {
    window.contentView.flatMap { views($0, NSOutlineView.self) }?
        .min { $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX }
}

/// The sidebar lists each section header, then its pages.
@MainActor private func selectedPage(in window: NSWindow) -> SettingsDestination? {
    let rows: [SettingsDestination?] = [nil, .general, nil] + SettingsDestination.windowManagementDestinations.map { $0 }
        + [nil, .applicationRules]
    guard let row = sidebar(in: window)?.selectedRow, rows.indices.contains(row) else { return nil }
    return rows[row]
}

/// Real awaits let AppKit and SwiftUI run the teardown they queue on the main queue.
@MainActor private func waitForRelease(_ description: String, timeout: Duration = .seconds(5),
                                       _ released: () -> Bool) async throws {
    let wall = ContinuousClock() // real-time: the release follows AppKit's own queued work
    let deadline = wall.now.advanced(by: timeout)
    while !released(), wall.now < deadline {
        try await BetterTileClock.live.sleep(for: .milliseconds(20))
    }
    #expect(released(), Comment(rawValue: "\(description) is still alive"))
}

@Suite(.appTestApplication, .serialized, .settingsUI) @MainActor
struct SettingsWindowLifetimeTests {
    /// AppKit and SwiftUI keep per-control bookkeeping until the window that showed the control is freed.
    /// A Settings window kept for the app's life therefore grew with every page visit.
    @Test func closingSettingsReleasesTheWindowAndItsViewTree() async throws {
        let harness = SettingsWindowHarness()
        defer { harness.shutdown() }
        let configuration = harness.model.configuration
        for cycle in 1...3 {
            let closed: Released<NSWindow>, host: Released<NSViewController>, content: Released<NSView>
            do {
                let window = try await harness.open()
                for page in [SettingsDestination.shortcuts, .menuBar, .applicationRules, .general] {
                    try await harness.visit(page, in: window)
                }
                closed = Released(window)
                host = Released(window.contentViewController)
                content = Released(window.contentViewController?.view)
                #expect(host.value != nil && content.value != nil)
                window.performClose(nil)
            }
            #expect(harness.delegate.settingsWindowForTesting == nil, "Cycle \(cycle): the delegate still holds Settings")
            try await waitForRelease("Cycle \(cycle) Settings window") { closed.value == nil }
            try await waitForRelease("Cycle \(cycle) hosting controller") { host.value == nil && content.value == nil }
        }
        #expect(harness.model.configuration == configuration, "Closing Settings keeps the configuration")
    }

    @Test func reopenedSettingsIsAFreshWorkingWindowOnGeneral() async throws {
        let harness = SettingsWindowHarness()
        defer { harness.shutdown() }
        let closed: Released<NSWindow>
        do {
            let first = try await harness.open()
            try await harness.visit(.shortcuts, in: first)
            closed = Released(first)
            first.performClose(nil)
        }
        try await waitForRelease("The closed Settings window") { closed.value == nil }

        let reopened = try await harness.open()
        #expect(reopened.isVisible)
        #expect(reopened.delegate === harness.delegate)
        #expect(selectedPage(in: reopened) == .general, "A fresh window opens on the first page")
        try await harness.visit(.snapZones, in: reopened)
    }

    /// The menu bar's Saved Layouts items and a result pill's Details ask for a page, then open Settings.
    @Test(arguments: [SettingsDestination.savedLayouts, .shortcuts])
    func requestedPageOpensAfterAPreviousClose(page: SettingsDestination) async throws {
        let harness = SettingsWindowHarness()
        defer { harness.shutdown() }
        do {
            let first = try await harness.open()
            try await harness.visit(.menuBar, in: first)
            first.performClose(nil)
        }
        #expect(harness.delegate.settingsWindowForTesting == nil)

        harness.model.requestedSettingsDestination = page
        let reopened = try await harness.open()
        let view = try #require(reopened.contentView)
        try await waitForSettingsUI("the requested \(page.rawValue) page", in: view) {
            harness.model.requestedSettingsDestination == nil && selectedPage(in: reopened) == page
        }
    }

    /// Sparkle closes Settings with `close()` before it shows an update, even while a sheet is open.
    /// SwiftUI moves its own sheet windows onto a real display, so this sheet is an off-screen AppKit panel.
    @Test func closingWithASheetOpenReleasesTheWindowAndTheSheet() async throws {
        let harness = SettingsWindowHarness()
        defer { harness.shutdown() }
        let closed: Released<NSWindow>, sheet: Released<NSWindow>
        do {
            let window = try await harness.open()
            try await harness.visit(.general, in: window)
            let panel = OffscreenTestPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
                                           styleMask: [.titled], backing: .buffered, defer: true)
            panel.isReleasedWhenClosed = false
            window.beginSheet(panel, completionHandler: nil)
            let view = try #require(window.contentView)
            try await waitForSettingsUI("the attached sheet", in: view) { window.attachedSheet === panel }
            closed = Released(window)
            sheet = Released(panel)
            window.close()
        }
        #expect(harness.delegate.settingsWindowForTesting == nil)
        try await waitForRelease("The Settings window closed with a sheet") { closed.value == nil }
        try await waitForRelease("The sheet of the closed window") { sheet.value == nil }

        let reopened = try await harness.open()
        #expect(reopened.attachedSheet == nil)
        try await harness.visit(.shortcuts, in: reopened)
    }

    /// Freeing a Settings window removes its pages, as a page change does. A recording must not leave the
    /// keyboard shortcuts and the Layout Wheel suspended after its page is gone. The recording starts
    /// from the page's own initial state because its record buttons are not AppKit controls.
    @Test func freeingTheShortcutsPageEndsARecording() async throws {
        let model = makeModel(system: FakeAppWindowSystem())
        defer { model.shutdown() }
        let closed: Released<NSWindow>
        do {
            let page = ShortcutsSettings(model: model, recordingAction: .leftHalf)
            let window = OffscreenTestWindow(contentViewController: NSHostingController(rootView: page))
            window.isReleasedWhenClosed = false
            window.orderFrontRegardless()
            let view = try #require(window.contentView)
            try await waitForSettingsUI("the Shortcuts page", in: view) {
                !views(view, NSTextField.self).isEmpty
            }
            model.setShortcutCaptureActive(true)
            closed = Released(window)
            window.close()
            window.contentViewController = nil
        }
        try await waitForRelease("The Shortcuts page window") { closed.value == nil }
        try await waitForRelease("The shortcut recording") { !model.isShortcutCaptureActive }
    }

    /// The next window opens where the closed one was and takes over the frame autosave name,
    /// so later moves are still saved for the next launch.
    @Test func reopenedSettingsKeepsTheClosedWindowsFrame() async throws {
        let name = "SettingsWindowLifetimeTests-\(UUID().uuidString)"
        defer { NSWindow.removeFrame(usingName: name) }
        let harness = SettingsWindowHarness(frameAutosaveName: name)
        defer { harness.shutdown() }
        let first = try await harness.open()
        #expect(first.frameAutosaveName == name)
        let moved = NSRect(x: first.frame.minX + 40, y: first.frame.minY + 30,
                           width: first.frame.width + 50, height: first.frame.height + 20)
        first.setFrame(moved, display: false)
        let frame = first.frame
        let descriptor = first.frameDescriptor
        first.performClose(nil)
        #expect(UserDefaults.standard.string(forKey: "NSWindow Frame \(name)") == descriptor)

        // `first` is still alive here. AppKit refuses an autosave name that a live window holds.
        let reopened = try await harness.open()
        #expect(reopened !== first)
        #expect(reopened.frameAutosaveName == name)
        #expect(reopened.frame == frame)
    }
}
