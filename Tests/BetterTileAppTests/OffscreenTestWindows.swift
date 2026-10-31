import AppKit
import BetterTileCore
import Testing
@testable import BetterTileApp
@testable import BetterTileMacOS

@MainActor enum OffscreenTestWindows {
    /// Opt-in native window-server checks run separately from the default suite.
    nonisolated static let localWindowTestsEnabled = ProcessInfo.processInfo.environment["BETTERTILE_LOCAL_WINDOW_TESTS"] == "1"
    /// One translation for source geometry, including already off-display fixtures.
    static func frame(_ proposed: NSRect) -> NSRect {
        proposed.offsetBy(dx: 1_000_000, dy: 0)
    }

    /// AppKit also sends physical frame readbacks through window setters. The
    /// test fixtures use source coordinates below 500,000; the reserved range
    /// above that boundary identifies an already translated AppKit frame.
    static func windowFrame(_ proposed: NSRect) -> NSRect {
        NativeApplicationBootstrap.recordWindowAccess("create or move an offscreen test window")
        return proposed.minX >= 500_000 ? proposed : frame(proposed)
    }

    static func check(_ window: NSWindow, sourceLocation: SourceLocation = #_sourceLocation) {
        // Read back after AppKit ordering: titled windows can otherwise be
        // constrained back onto a display even with an offscreen input frame.
        #expect(window.frame.isEmpty || !NSScreen.screens.contains { $0.frame.intersects(window.frame) },
                "Test window \(type(of: window)) intersects a display: \(window.frame)",
                sourceLocation: sourceLocation)
        TestWindowAudit.sample()
    }

    static func panel() -> NSPanel {
        OffscreenTestPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                           backing: .buffered, defer: true)
    }

    static func tabbedPanel() -> NSPanel {
        OffscreenTabbedTestPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered, defer: true)
    }

    static func chooserPresenter(_ content: NSView, _ size: NSSize) -> TabbedChooserPresenter {
        chooserPresenter(content, size, appearance: OverlayAppearance())
    }

    static func chooserPresenter(_ content: NSView, _ size: NSSize, appearance: OverlayAppearance) -> TabbedChooserPresenter {
        TabbedChooserPresenter(content: content, size: size, appearance: appearance,
            panel: OffscreenChooserTestPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                            backing: .buffered, defer: true))
    }
}

@MainActor class OffscreenChooserTestPanel: TabbedChooserPanel {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        OffscreenTestWindows.windowFrame(frameRect)
    }
    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        super.setFrame(OffscreenTestWindows.windowFrame(frameRect), display: flag)
    }
    override func order(_ place: NSWindow.OrderingMode, relativeTo otherWin: Int) {
        if place != .out { setFrame(frame, display: false) }
        withoutTestWindowAnimations(self) { super.order(place, relativeTo: otherWin) }
        if place != .out { OffscreenTestWindows.check(self) }
    }
    override func orderFrontRegardless() {
        setFrame(frame, display: false)
        withoutTestWindowAnimations(self) { super.orderFrontRegardless() }
        OffscreenTestWindows.check(self)
    }
}

/// A real AppKit window with normal ordering, focus and view rendering.
/// Only placement and AppKit's titled-window screen constraint are replaced.
@MainActor class OffscreenTestWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        OffscreenTestWindows.windowFrame(frameRect)
    }
    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        TestWindowAudit.start()
        super.setFrame(OffscreenTestWindows.windowFrame(frameRect), display: flag)
    }
    override func order(_ place: NSWindow.OrderingMode, relativeTo otherWin: Int) {
        if place != .out { setFrame(frame, display: false) }
        withoutTestWindowAnimations(self) { super.order(place, relativeTo: otherWin) }
        if place != .out { OffscreenTestWindows.check(self) }
    }
    override func orderFrontRegardless() {
        setFrame(frame, display: false)
        withoutTestWindowAnimations(self) { super.orderFrontRegardless() }
        OffscreenTestWindows.check(self)
    }
}

@MainActor class OffscreenTestPanel: NSPanel {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        OffscreenTestWindows.windowFrame(frameRect)
    }
    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        TestWindowAudit.start()
        super.setFrame(OffscreenTestWindows.windowFrame(frameRect), display: flag)
    }
    override func order(_ place: NSWindow.OrderingMode, relativeTo otherWin: Int) {
        if place != .out { setFrame(frame, display: false) }
        withoutTestWindowAnimations(self) { super.order(place, relativeTo: otherWin) }
        if place != .out { OffscreenTestWindows.check(self) }
    }
    override func orderFrontRegardless() {
        setFrame(frame, display: false)
        withoutTestWindowAnimations(self) { super.orderFrontRegardless() }
        OffscreenTestWindows.check(self)
    }
}

/// Retains the production strip's conditional keyboard-focus behavior.
@MainActor final class OffscreenTabbedTestPanel: TabbedStripPanel {
    // Keep the screen-dependent chooser path active. The actual frame remains
    // offscreen; this supplies the same screen geometry as an on-screen strip.
    override var screen: NSScreen? { super.screen ?? NSScreen.screens.first }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        OffscreenTestWindows.windowFrame(frameRect)
    }
    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        super.setFrame(OffscreenTestWindows.windowFrame(frameRect), display: flag)
    }
    override func order(_ place: NSWindow.OrderingMode, relativeTo otherWin: Int) {
        if place != .out { setFrame(frame, display: false) }
        withoutTestWindowAnimations(self) { super.order(place, relativeTo: otherWin) }
        if place != .out { OffscreenTestWindows.check(self) }
    }
    override func orderFrontRegardless() {
        setFrame(frame, display: false)
        withoutTestWindowAnimations(self) { super.orderFrontRegardless() }
        OffscreenTestWindows.check(self)
    }
}

/// Keep the model's fake window geometry unchanged. Its real AppKit presenters
/// receive offscreen panels through their existing per-instance factories.
/// Translated panels make Tabbed's source-target frame comparisons always take the "changed" branch.
@MainActor func makeOffscreenModel(
    store: ConfigurationStore = .init(fileURL: FileManager.default.temporaryDirectory
        .appendingPathComponent("OffscreenModel-" + UUID().uuidString).appendingPathComponent("configuration.json")),
    system: (any BetterTileWindowSystem)? = nil,
    startRuntime: Bool = false,
    presentsTabbedChrome: Bool? = nil,
    gestureEvents: SharedGestureEventMonitor? = nil
) -> BetterTileModel {
    NativeApplicationBootstrap.recordWindowAccess("create a model with native window fixtures")
    let fakeSystem = system as? FakeAppWindowSystem
    let modelUptime: (@MainActor () -> TimeInterval)?
    if let fakeSystem { modelUptime = { fakeSystem.applicationHoldUptime() } }
    else { modelUptime = nil }
    let model = BetterTileModel(store: store, system: system, startRuntime: startRuntime,
                               presentsTabbedChrome: presentsTabbedChrome,
                               gestureEvents: gestureEvents,
                               clock: fakeSystem?.clock ?? .live, uptime: modelUptime)
    model.resultPillFactory = { ResultPillController(panel: OffscreenTestWindows.panel()) }
    model.tabbedOverlayFactory = {
        let overlay = TabbedOverlayController(panelFactory: OffscreenTestWindows.tabbedPanel)
        overlay.chooserPresenterFactory = { [weak overlay] content, size in
            OffscreenTestWindows.chooserPresenter(content, size, appearance: overlay?.overlayAppearance ?? OverlayAppearance())
        }
        return overlay
    }
    model.paneApplicationPopoverFactory = { request, appearance in
        PaneApplicationPopover(request: request, appearance: appearance,
                               presenterFactory: { content, size in
            OffscreenTestWindows.chooserPresenter(content, size, appearance: appearance)
        })
    }
    model.dividerResize.panelFrameTransform = OffscreenTestWindows.frame
    return model
}
