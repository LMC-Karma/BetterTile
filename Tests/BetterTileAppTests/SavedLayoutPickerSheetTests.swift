import AppKit
import SwiftUI
import Testing
@testable import BetterTileApp

@MainActor private func sheetSubviews<T: NSView>(_ view: NSView, of type: T.Type) -> [T] {
    ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { sheetSubviews($0, of: type) }
}

@MainActor @Observable private final class SavedLayoutSheetState {
    var presented = false
    var chosen: ApplicationChoice?
    var picker: ApplicationPickerReadiness?
}

/// Present the production sheet content via SwiftUI. Only its parent receives a test size.
/// In particular, never set the attached sheet's content size or fitting size.
/// SwiftUI constrains its framework-owned native sheet onto a real
/// screen even when its parent is offscreen. The suite requires
/// BETTERTILE_LOCAL_WINDOW_TESTS=1. CI enables that flag; local runs omit this
/// suite unless the flag is explicitly set.
@Suite(.appTestApplication, .serialized, .settingsUI, .enabled(if: OffscreenTestWindows.localWindowTestsEnabled))
@MainActor struct SavedLayoutPickerSheetTests {
    @Test(arguments: [NSSize(width: 980, height: 640), NSSize(width: 1300, height: 1257)])
    func assignSheetKeepsUsefulResultsViewport(hostSize: NSSize) async throws {
        _ = NSApplication.shared
        let state = SavedLayoutSheetState()
        let recent = RecentApplications(defaults: MemoryDefaults())
        let applications = (0..<90).map { index in
            ApplicationChoice(bundleIdentifier: "test.app.\(index)", name: String(format: "Test App %02d", index),
                              url: URL(filePath: "/nonexistent/Test App \(index).app"))
        }
        let page = Color.clear.sheet(isPresented: Binding(get: { state.presented }, set: { state.presented = $0 })) {
            SavedLayoutApplicationSheet(makePicker: { exclusions, choose in
                var picker = ApplicationPicker(exclusions: exclusions, installedApplications: { applications },
                                  runningApplications: { [] }, recentApplications: recent,
                                  resolveApplication: { _ in nil }, onChoose: choose)
                picker.onPresentationChange = { state.picker = $0 }
                return picker
            }, title: "Assign App", onChoose: {
                state.chosen = $0
                state.presented = false
            }, onCancel: { state.presented = false })
            .environment(\.accessibilityEnabled, true)
        }
        let host = NSHostingView(rootView: page.environment(\.accessibilityEnabled, true))
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: 12000, y: 0), size: hostSize),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        window.setContentSize(hostSize)
        defer {
            if let sheet = window.attachedSheet { window.endSheet(sheet); sheet.orderOutForTesting() }
            window.close()
        }
        window.orderFront(nil)
        try await waitForSavedLayoutSnapshot(in: host) { window.isVisible }
        state.presented = true
        try await waitForSettingsUI("the loaded sheet and its initial search focus", in: host) {
            guard let sheet = window.attachedSheet, let content = sheet.contentView,
                  let search = sheetSubviews(content, of: NSSearchField.self).first,
                  let editor = search.currentEditor() else { return false }
            content.layoutSubtreeIfNeeded()
            return state.picker?.isLoading == false && sheet.firstResponder === editor
                && (sheetSubviews(content, of: NSScrollView.self).first?.documentView?.frame.height ?? 0) >= 2_000
        }
        let sheet = try #require(window.attachedSheet)
        let content = try #require(sheet.contentView)
        content.layoutSubtreeIfNeeded()
        let list = try #require(sheetSubviews(content, of: NSScrollView.self).first)
        let viewport = list.contentView
        print("ASSIGN SHEET host=\(hostSize) sheet=\(content.bounds.size) viewport=\(viewport.bounds.size) document=\(list.documentView?.frame.size ?? .zero)")
        #expect(viewport.bounds.height >= 200)
        // The lazy list estimates its height; 90 rows of 32 pt must still scroll well past the viewport.
        #expect((list.documentView?.frame.height ?? 0) >= 2_000)
        let search = try #require(sheetSubviews(content, of: NSSearchField.self).first)
        #expect(search.accessibilityLabel() == "Search apps")
        let fieldEditor = try #require(search.currentEditor() as? NSTextView)
        #expect(sheet.firstResponder === fieldEditor)
        try captureSheet(content, hostSize: hostSize, state: "loaded")

        fieldEditor.insertText("Test App 04", replacementRange: fieldEditor.selectedRange())
        try await waitForSettingsUI("the filtered picker highlight", in: content) {
            state.picker?.isLoading == false && state.picker?.highlight == "Results:test.app.4"
                && search.stringValue == "Test App 04"
        }
        #expect(search.stringValue == "Test App 04")
        #expect(viewport.bounds.height >= 200)
        #expect(sheet.firstResponder === fieldEditor)
        try captureSheet(content, hostSize: hostSize, state: "selected")
        try sheetKey(sheet, "\r", code: 36)
        try await waitForSettingsUI("the chosen app and dismissed sheet", in: host) {
            state.chosen?.bundleIdentifier == "test.app.4" && !state.presented && window.attachedSheet == nil
        }
        #expect(state.chosen?.bundleIdentifier == "test.app.4")
        #expect(!state.presented)
        #expect(window.attachedSheet == nil)

        state.picker = nil
        state.presented = true
        try await waitForSettingsUI("the reopened sheet and search focus", in: host) {
            guard let sheet = window.attachedSheet, let content = sheet.contentView,
                  let editor = sheetSubviews(content, of: NSSearchField.self).first?.currentEditor() else { return false }
            content.layoutSubtreeIfNeeded()
            return state.picker?.isLoading == false && sheet.firstResponder === editor
        }
        let reopened = try #require(window.attachedSheet)
        try sheetKey(reopened, "\u{1b}", code: 53)
        try await waitForSettingsUI("the cancelled sheet to dismiss", in: host) {
            !state.presented && window.attachedSheet == nil
        }
        #expect(!state.presented)
        #expect(window.attachedSheet == nil)
        #expect(state.chosen?.bundleIdentifier == "test.app.4")
    }
}

@MainActor private func sheetKey(_ sheet: NSWindow, _ characters: String, code: UInt16) throws {
    let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
        timestamp: 1000, windowNumber: sheet.windowNumber, context: nil,
        characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
    try withNativeEventLoop { sheet.sendEvent(event) }
}

@MainActor private func captureSheet(_ content: NSView, hostSize: NSSize, state: String) throws {
    if let output = ProcessInfo.processInfo.environment["BETTERTILE_SAVED_PICKER_PREVIEW_DIR"] {
        let bitmap = try #require(content.bitmapImageRepForCachingDisplay(in: content.bounds))
        content.needsDisplay = true
        content.displayIfNeeded()
        content.effectiveAppearance.performAsCurrentDrawingAppearance {
            content.cacheDisplay(in: content.bounds, to: bitmap)
        }
        try #require(bitmap.representation(using: .png, properties: [:])).write(
            to: URL(filePath: output).appendingPathComponent("assign-sheet-\(Int(hostSize.width))-\(state).png"))
    }
}
