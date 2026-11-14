import AppKit
import BetterTileCore
import BetterTileTestSupport
import Testing
@testable import BetterTileApp
@testable import BetterTileMacOS

@MainActor private final class SimulatedVisibleTestPanel: OffscreenTestPanel {
    override var isVisible: Bool { true }
}

@Test(.appTestApplication) @MainActor func offscreenTranslationPreservesRelativeGeometryAndOcclusion() {
    let first = NSRect(x: 100, y: 200, width: 600, height: 500)
    let second = NSRect(x: 600, y: 250, width: 300, height: 400)
    let translatedFirst = OffscreenTestWindows.frame(first)
    let translatedSecond = OffscreenTestWindows.frame(second)
    #expect(translatedSecond.minX - translatedFirst.minX == second.minX - first.minX)
    #expect(translatedFirst.intersection(translatedSecond) == OffscreenTestWindows.frame(first.intersection(second)))
    let outside = second.offsetBy(dx: 2_000, dy: 0)
    #expect(!translatedFirst.intersects(OffscreenTestWindows.frame(outside)))

    let cover = SimulatedVisibleTestPanel(contentRect: second, styleMask: [.borderless], backing: .buffered, defer: true)
    cover.isReleasedWhenClosed = false
    defer { cover.close() }
    cover.setFrame(second, display: false)
    #expect(DividerOverlayController.ownWindowCoversHandle(translatedFirst, windows: [cover], excluding: []))
    cover.setFrame(outside, display: false)
    #expect(!DividerOverlayController.ownWindowCoversHandle(translatedFirst, windows: [cover], excluding: []))
}

@Test(.appTestApplication) @MainActor func translatedDividerOverlayKeepsPreviewLocalFrames() throws {
    _ = NSApplication.shared
    let handle = NSPanel(contentRect: NSRect(x: 2_000_000, y: 0, width: 30, height: 168),
                         styleMask: [.borderless], backing: .buffered, defer: true)
    handle.isReleasedWhenClosed = false
    defer { handle.close() }
    let bounds = BTRect(x: 2_000_000, y: 0, width: 1000, height: 800)
    let placements = [Placement(windowID: WindowID(rawValue: "left"), frame: BTRect(x: 2_000_100, y: 50, width: 300, height: 600)),
                      Placement(windowID: WindowID(rawValue: "right"), frame: BTRect(x: 2_000_600, y: 50, width: 300, height: 600))]
    let identity = DividerDragOverlay()
    let translated = DividerDragOverlay()
    translated.panelFrameTransform = OffscreenTestWindows.frame
    defer { identity.end(); translated.end() }
    for overlay in [identity, translated] {
        overlay.begin(displayFrame: bounds, below: handle, appearance: OverlayAppearance(), windows: [])
        overlay.update(previews: placements)
    }
    func previews(_ view: NSView) -> [NSRect] {
        if view is GhostPreviewView { return [view.frame] }
        return view.subviews.flatMap(previews)
    }
    let originalFrames = previews(try #require(identity.panel?.contentView)).sorted { $0.minX < $1.minX }
    let translatedFrames = previews(try #require(translated.panel?.contentView)).sorted { $0.minX < $1.minX }
    #expect(originalFrames.count == 2)
    #expect(originalFrames[1].minX - originalFrames[0].minX == 500)
    #expect(translatedFrames == originalFrames)
}

@Test(.appTestApplication) @MainActor func windowSamplerRejectsAnOrderedPanelOnAnInjectedDisplay() {
    _ = NSApplication.shared
    let panel = NSPanel(contentRect: NSRect(x: 5_000_000, y: 0, width: 300, height: 200),
                        styleMask: [.borderless], backing: .buffered, defer: true)
    panel.isReleasedWhenClosed = false
    defer { panel.close() }
    panel.orderFrontForTesting()
    #expect(panel.isVisible)
    #expect(!NSScreen.screens.contains { $0.frame.intersects(panel.frame) })
    let message = "Visible test window NSPanel intersects a display: \(panel.frame)"
    #expect(TestWindowAudit.displayViolations(on: [panel.frame]).contains { $0.window === panel && $0.message == message },
            "The suite sampler must reject a panel intersecting its injected display")
    let failures = HelperFailureLog()
    TestWindowAudit.sample(displays: [panel.frame], enforceOffscreen: true, reporter: .collecting(into: failures))
    #expect(failures.messages.contains(message), "The sampler must report the panel it rejects")
}

@Test(.appTestApplication) @MainActor func simulatedVisiblePanelsAlsoKeepTheirFramesOffscreen() throws {
    _ = NSApplication.shared
    let screen = try #require(NSScreen.screens.first)
    let panel = SimulatedVisibleTestPanel(contentRect: screen.visibleFrame.insetBy(dx: 100, dy: 100),
                                         styleMask: [.borderless], backing: .buffered, defer: true)
    panel.isReleasedWhenClosed = false
    defer { panel.close() }
    panel.setFrame(screen.visibleFrame.insetBy(dx: 100, dy: 100), display: false)
    #expect(panel.isVisible)
    OffscreenTestWindows.check(panel)
    TestWindowAudit.sample()
}



@Test(.appTestApplication) @MainActor func offscreenGuardRejectsDisplayIntersection() throws {
    _ = NSApplication.shared
    let screen = try #require(NSScreen.screens.first)
    // Leave this negative-control window unordered. The guard still reads its
    // actual AppKit frame, and must report the deliberately unsafe placement.
    let window = NSWindow(contentRect: screen.visibleFrame.insetBy(dx: 100, dy: 100),
                          styleMask: [.borderless], backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let message = "Test window NSWindow intersects a display: \(window.frame)"
    #expect(OffscreenTestWindows.displayViolation(of: window) == message,
            "The guard must reject the deliberately intersecting frame")
    let failures = HelperFailureLog()
    let location = SourceLocation(fileID: "Fixture/Caller.swift", filePath: "/Fixture/Caller.swift", line: 7, column: 3)
    OffscreenTestWindows.check(window, sourceLocation: location, reporter: .collecting(into: failures))
    #expect(failures.reported == [HelperFailureLog.Entry(message: message, sourceLocation: location)],
            "The guard reports the rejection at its caller's location")
}

@Test(.appTestApplication) @MainActor func productionModelPanelFactoriesKeepTheirDefaults() throws {
    _ = NSApplication.shared
    let system = FakeAppWindowSystem()
    let store = ConfigurationStore(fileURL: URL(filePath: "/tmp/BetterTileDefaultPanels-\(UUID().uuidString)/configuration.json"))
    let model = BetterTileModel(store: store, system: system, startRuntime: false)
    defer { model.shutdown() }
    let requested = NSRect(x: 100, y: 200, width: 60, height: 300)
    #expect(model.dividerResize.panelFrameTransform(requested) == requested)
    #expect(model.dividerResize.dragOverlay.panelFrameTransform(requested) == requested)
    let pill = model.resultPillFactory()
    let panel = try #require(Mirror(reflecting: pill).children.first { $0.label == "panel" }?.value as? NSPanel)
    #expect(type(of: panel) == NSPanel.self)
    #expect(panel.level == .statusBar)
    let overlay = model.tabbedOverlayFactory()
    defer { overlay.hide() }
    #expect(overlay.chooserPresenterFactory == nil)
    let state = TabbedLayoutState(preset: .single)
    overlay.refresh(state: state, bounds: BTRect(x: 100_000, y: 0, width: 1000, height: 800), windows: [])
    let strip = try #require(NSApp.windows.first { ($0.contentView as? TabbedPaneView)?.pane.id == state.panes[0].id })
    #expect(type(of: strip) == TabbedStripPanel.self)
    #expect(!strip.canBecomeKey)
}

@Test(.appTestApplication) @MainActor func offscreenStripStillRunsTheScreenDependentChooserPresentation() throws {
    _ = NSApplication.shared
    let screen = try #require(NSScreen.screens.first)
    let strip = OffscreenTestWindows.tabbedPanel()
    strip.isReleasedWhenClosed = false
    defer { strip.close() }
    let anchor = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 34))
    strip.contentView = anchor
    strip.setFrame(NSRect(x: screen.frame.midX, y: screen.frame.midY, width: 600, height: 34), display: false)
    strip.orderFrontForTesting()
    #expect(strip.isVisible)
    #expect(strip.screen != nil)
    let content = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 420))
    let presenter = OffscreenTestWindows.chooserPresenter(content, content.frame.size)
    defer { presenter.dismiss() }
    presenter.show(relativeTo: NSRect(x: 10, y: 0, width: 24, height: 24), of: anchor, paneFrame: nil)
    #expect(presenter.isPresented)
    #expect(presenter.panel.isVisible)
    OffscreenTestWindows.check(presenter.panel)
}

// These tests require a real key window; run only while the Mac is unattended.
// Add only reviewed real-key or activation cases; keep all other tests in default suites and update NativeLaneMembership.
@Suite(.enabled(if: NativeFocusTestLane.isEnabled, "Requires an unattended Mac; set BETTERTILE_NATIVE_FOCUS_TESTS=1"), .nativeFocus)
@MainActor struct NativeFocusOffscreenTestWindowTests {
    @Test(.appTestApplication, .settingsUI) @MainActor func offscreenTestWindowsKeepRealOrderingAndKeyStatus() throws {
        _ = NSApplication.shared
        let screen = try #require(NSScreen.screens.first)
        for mask: NSWindow.StyleMask in [[.borderless], [.titled, .closable]] {
            let window = OffscreenTestWindow(contentRect: screen.visibleFrame.insetBy(dx: 100, dy: 100),
                                             styleMask: mask, backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            window.orderFrontForTesting()
            #expect(window.isVisible)
            OffscreenTestWindows.check(window)
            window.setFrame(screen.visibleFrame, display: true)
            OffscreenTestWindows.check(window)
        }
        let strip = OffscreenTestWindows.tabbedPanel()
        strip.isReleasedWhenClosed = false
        defer { strip.close() }
        let productionStrip = try #require(strip as? TabbedStripPanel)
        #expect(!strip.canBecomeKey)
        productionStrip.allowsKeyboardFocus = true
        #expect(strip.canBecomeKey)
        strip.setFrame(screen.visibleFrame.insetBy(dx: 100, dy: 100), display: false)
        strip.makeKeyAndOrderFrontForTesting()
        #expect(strip.isVisible)
        #expect(strip.isKeyWindow, Comment(rawValue: keyWindowDiagnostics(strip)))
        strip.orderOutForTesting()
        OffscreenTestWindows.check(strip)
    }
}
