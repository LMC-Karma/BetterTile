import AppKit
import BetterTileCore
import Testing
@testable import BetterTileMacOS
@testable import BetterTileApp

/// Keep pane chrome out of the window system without replacing its controller or actions.
@MainActor private final class EscapePanePanel: NSPanel {
    var shown = false
    override var isVisible: Bool { shown }
    override var screen: NSScreen? { NSScreen.screens.first }
    override func orderFrontRegardless() { shown = true }
    override func orderOut(_ sender: Any?) { shown = false }
    override func order(_ place: NSWindow.OrderingMode, relativeTo otherWin: Int) { shown = place != .out }
    override func makeKey() {}
}

/// Use the production chooser panel, responder chain and event dispatch, only moving it offscreen.
@MainActor private final class EscapeChooserPanel: TabbedChooserPanel {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        var offscreen = frameRect
        if offscreen.minX < 40000 { offscreen.origin.x += 40000 }
        super.setFrame(offscreen, display: flag)
    }
}

// These tests require a real key window; run only while the Mac is unattended.
// Add only reviewed real-key or activation cases; keep all other tests in default suites and update NativeLaneMembership.
@Suite(.enabled(if: NativeFocusTestLane.isEnabled, "Requires an unattended Mac; set BETTERTILE_NATIVE_FOCUS_TESTS=1"), .nativeFocus, .appTestApplication, .serialized, .settingsUI) @MainActor struct NativeFocusTabbedPaneChooserEscapeTests {
    @Test func galleryEscapeClosesOnlyGalleryThenHidesAutoHideBars() throws {
        _ = NSApplication.shared
        var panes: [EscapePanePanel] = []
        let overlay = TabbedOverlayController(panelFactory: {
            let panel = EscapePanePanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                       backing: .buffered, defer: false)
            panes.append(panel)
            return panel
        }, addGlobalKeyMonitor: { _ in nil }, visibilityClock: { 0 }, automaticallyAdvanceVisibility: false)
        defer { overlay.hide() }
        let window = WindowID(rawValue: "gallery-escape")
        var state = TabbedLayoutState(presentation: .autoHide)
        state.reconcile(windowIDs: [window], removed: [], focused: window)
        overlay.refresh(state: state, bounds: BTRect(x: 40000, y: 0, width: 1000, height: 800), windows: [])
        let view = try #require(panes.compactMap { $0.contentView as? TabbedPaneView }.first)
        try #require(overlay.showTabBar())
        try #require(!view.collapsed)
        let gallery = overlay.makeLayoutGallery(paneID: view.pane.id) { content, size in
            let panel = EscapeChooserPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                          backing: .buffered, defer: false)
            return TabbedChooserPresenter(content: content, size: size, panel: panel)
        }
        let panel = gallery.presenter.panel
        defer { gallery.cancel(); panel.close() }
        gallery.show(relativeTo: view.strip.menuFrame, of: view, paneFrame: overlay.paneFrameInAppKit(view.pane.id))
        try #require(gallery.presenter.isPresented && overlay.hasLayoutGallery)
        try #require(!NSScreen.screens.contains { $0.frame.intersects(panel.frame) })
        panel.makeKey()
        try #require(NSApp.keyWindow === panel, Comment(rawValue: keyWindowDiagnostics(panel)))
        func escape(in window: NSWindow) throws {
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil,
                characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
            NSApp.sendEvent(event)
        }
        try escape(in: panel)
        #expect(!gallery.presenter.isPresented && !overlay.hasLayoutGallery)
        try #require(!view.collapsed, "First Escape must close only the innermost gallery")
        try #require(NSApp.keyWindow !== panel, Comment(rawValue: keyWindowDiagnostics(panel)))
        try escape(in: try #require(view.window))
        #expect(view.collapsed, "Second Escape must hide the revealed Auto-hide bars")
    }

    @Test(arguments: ["focused", "composition", "unfocused"], [TabbedStripPresentation.autoHide, .alwaysVisible])
    func paneAddAppEscapeUsesChooserResponderChain(focus: String, presentation: TabbedStripPresentation) async throws {
        _ = NSApplication.shared
        let system = FakeAppWindowSystem()
        system.availableDisplays[0].frame.origin.x = 40000
        system.availableDisplays[0].visibleFrame.origin.x = 40000
        system.windows[0].frame.origin.x += 40000
        let root = FileManager.default.temporaryDirectory.appending(path: "pane-escape-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = makeOffscreenModel(store: ConfigurationStore(fileURL: root.appending(path: "configuration.json")),
            system: system, startRuntime: false, presentsTabbedChrome: true)
        defer { model.shutdown() }
        model.primaryButtonIsPressed = { false }
        var panes: [EscapePanePanel] = []
        // Keep the real local NSEvent monitors. Global observation is unnecessary for in-process keys.
        let overlay = TabbedOverlayController(panelFactory: {
            let panel = EscapePanePanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                       backing: .buffered, defer: false)
            panes.append(panel)
            return panel
        }, addGlobalKeyMonitor: { _ in nil }, primaryButtonIsPressed: { false }, automaticallyAdvanceVisibility: false)
        model.tabbedOverlayFactory = { overlay }
        var dismissals = 0
        model.paneApplicationPopoverFactory = { request, appearance in
            let picker = PaneApplicationPopover(request: request, recentApplications: RecentApplications(defaults: MemoryDefaults()),
                appearance: appearance, presenterFactory: { content, size in
                    let panel = EscapeChooserPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                                  backing: .buffered, defer: false)
                    return TabbedChooserPresenter(content: content, size: size, appearance: appearance, panel: panel)
                })
            let dismiss = picker.presenter.onDismiss
            picker.presenter.onDismiss = { dismissals += 1; dismiss?() }
            return picker
        }
        model.configuration.tabbedStripPresentation = presentation
        model.setActiveMode(.tabbed)
        try #require(await waitFor { model.activeTabbedState?.windowIDs.count == 1 && !model.hasPendingTabbedPlacement })
        let view = try #require(panes.compactMap { $0.contentView as? TabbedPaneView }.first { !$0.pane.tabs.isEmpty })
        let add = view.content.addButton
        try #require(NSApp.sendAction(try #require(add.action), to: add.target, from: add))
        let picker = try #require(model.paneApplicationPopover)
        let panel = picker.presenter.panel
        defer { picker.close(); panel.close() }
        try #require(picker.presenter.isPresented)
        try #require(!NSScreen.screens.contains { $0.frame.intersects(panel.frame) })
        panel.makeKey()
        try await panelReady(picker.content) { panelViews(picker.content, NSSearchField.self).first?.currentEditor() != nil }
        let field = try #require(panelViews(picker.content, NSSearchField.self).first)
        let editor = try #require(field.currentEditor() as? NSTextView)
        func key(_ text: String, code: UInt16, flags: NSEvent.ModifierFlags = []) throws {
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                timestamp: 0, windowNumber: panel.windowNumber, context: nil,
                characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code))
            NSApp.sendEvent(event)
        }
        for (text, code) in [("D", UInt16(2)), ("i", 34), ("c", 8), ("t", 17)] {
            try key(text, code: code, flags: text == "D" ? .shift : [])
        }
        try await panelReady(picker.content) { field.stringValue == "Dict" }
        try #require(NSApp.keyWindow === panel && panel.firstResponder === editor, Comment(rawValue: keyWindowDiagnostics(panel)))
        if focus == "composition" {
            editor.setMarkedText("あ", selectedRange: NSRange(location: 1, length: 0),
                                 replacementRange: NSRange(location: NSNotFound, length: 0))
            try #require(editor.hasMarkedText())
            try key("\u{1b}", code: 53)
            #expect(!editor.hasMarkedText())
            #expect(field.stringValue == "Dict")
            try #require(picker.presenter.isPresented && dismissals == 0, "Auto-hide monitor intercepted composition Escape")
        }
        if focus == "unfocused" {
            try #require(panel.makeFirstResponder(panel.contentView))
            try #require(field.currentEditor() == nil)
            try key("\u{1b}", code: 53)
            #expect(!picker.presenter.isPresented && dismissals == 1)
            return
        }
        try key("\u{1b}", code: 53)
        #expect(field.stringValue.isEmpty && editor.string.isEmpty)
        try #require(picker.presenter.isPresented && dismissals == 0, "Auto-hide monitor closed the focused chooser before its field editor")
        #expect(panel.firstResponder === editor)
        try key("\u{1b}", code: 53)
        #expect(!picker.presenter.isPresented && model.paneApplicationPopover == nil && dismissals == 1)
        picker.close()
        #expect(dismissals == 1)
    }
}
