import AppKit
import BetterTileCore
import Testing
@testable import BetterTileMacOS

@MainActor private final class AutoHideClock {
    var now = 0.0
}

@MainActor private final class AutoHidePanelLog {
    var panels: [AutoHideCountingPanel] = []
}

/// Counts writes to `ignoresMouseEvents`.
private final class AutoHideCountingPanel: NSPanel {
    var inputWrites = 0
    override var ignoresMouseEvents: Bool {
        get { super.ignoresMouseEvents }
        set { inputWrites += 1; super.ignoresMouseEvents = newValue }
    }
}

/// Gives every empty pane two tabs.
private func fillingEmptyPanes(_ state: TabbedLayoutState) -> TabbedLayoutState {
    var state = state
    for pane in state.panes where pane.tabs.isEmpty {
        for index in 0..<2 {
            let id = WindowID(rawValue: "\(pane.id)-\(index)")
            state.reconcile(windowIDs: state.windowIDs.sorted { $0.rawValue < $1.rawValue } + [id], removed: [], focused: nil)
            state.move(id, to: pane.id)
        }
    }
    return state
}

@MainActor private final class AutoHideFixture {
    let clock = AutoHideClock()
    let overlay: TabbedOverlayController
    let state: TabbedLayoutState
    let bounds: BTRect
    var views: [TabbedPaneView] = []
    let panelLog = AutoHidePanelLog()

    init(width: Double = 800, height: Double = 720, preset: TabbedPreset = .single, state: TabbedLayoutState? = nil, reduceMotion: Bool = true, pointerTicks: ResizeDisplayLink = ResizeDisplayLink(automatic: false)) {
        _ = NSApplication.shared
        bounds = BTRect(x: 40000, y: 0, width: width, height: height)
        let state = fillingEmptyPanes(state ?? TabbedLayoutState(preset: preset, presentation: .autoHide))
        self.state = state
        let clock = self.clock
        let panelLog = self.panelLog
        overlay = TabbedOverlayController(pointerTicks: pointerTicks, panelFactory: {
            let panel = AutoHideCountingPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panelLog.panels.append(panel)
            return panel
        }, addGlobalKeyMonitor: { _ in NSObject() }, addLocalKeyMonitor: { _ in NSObject() }, removeMonitor: { _ in },
        visibilityClock: { clock.now }, automaticallyAdvanceVisibility: false)
        overlay.refresh(state: state, bounds: bounds, windows: [])
        views = panelLog.panels.compactMap { $0.contentView as? TabbedPaneView }
        views.forEach {
            $0.reduceMotion = { reduceMotion }
            $0.displayOptions = { (false, false) }
            $0.refreshAppearance()
        }
    }

    func tick(to time: Double) {
        clock.now = time
        overlay.advanceBarVisibility()
    }

    /// Includes panels made after the first refresh.
    func view(for paneID: UUID) -> TabbedPaneView? {
        panelLog.panels.lazy.compactMap { $0.contentView as? TabbedPaneView }.first { $0.pane.id == paneID }
    }
}

/// Records ordering without showing a window or taking focus on the shared desktop.
@MainActor private final class AutoHideOrderingPanel: NSPanel {
    var shown = false
    var frontOrders = 0
    var keyRequests = 0
    override var isVisible: Bool { shown }
    override func order(_ place: NSWindow.OrderingMode, relativeTo otherWin: Int) { shown = place != .out }
    override func orderFrontRegardless() { frontOrders += 1; shown = true }
    override func orderOut(_ sender: Any?) { shown = false }
    override func makeKey() { keyRequests += 1 }
}

@MainActor private final class AutoHideOrderingFixture {
    struct Order {
        let panel: NSPanel
        let mode: NSWindow.OrderingMode
        let anchor: Int
        let wasCollapsed: Bool
    }

    var now = 0.0
    var panels: [AutoHideOrderingPanel] = []
    var orders: [Order] = []
    let state = fillingEmptyPanes(TabbedLayoutState(preset: .single, presentation: .autoHide))
    let bounds = BTRect(x: 40000, y: 0, width: 800, height: 720)
    var paneID: UUID { state.activePaneID }
    var strip: AutoHideOrderingPanel { panels.first { $0.contentView is TabbedPaneView }! }
    var view: TabbedPaneView { strip.contentView as! TabbedPaneView }
    lazy var overlay = TabbedOverlayController(panelFactory: { [unowned self] in
        let panel = AutoHideOrderingPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                          backing: .buffered, defer: false)
        panels.append(panel)
        return panel
    }, addGlobalKeyMonitor: { _ in NSObject() }, addLocalKeyMonitor: { _ in NSObject() }, removeMonitor: { _ in },
    orderPanel: { [unowned self] panel, mode, anchor in
        orders.append(Order(panel: panel, mode: mode, anchor: anchor,
                            wasCollapsed: (panel.contentView as? TabbedPaneView)?.collapsed == true))
        panel.order(mode, relativeTo: anchor)
    }, visibilityClock: { [unowned self] in now }, automaticallyAdvanceVisibility: false)

    init(anchor: Int? = 101, reduceMotion: Bool = true) {
        _ = NSApplication.shared
        refresh(anchor: anchor)
        view.reduceMotion = { reduceMotion }
        orders.removeAll()
    }

    func refresh(anchor: Int?, obscuringFrames: [BTRect] = []) {
        let numbers = anchor.map { [state.activeWindowID!: $0] } ?? [:]
        overlay.refresh(state: state, bounds: bounds, windows: [], obscuringFrames: obscuringFrames,
                        selectedWindowNumbers: numbers)
    }

    func tick(to time: Double) {
        now = time
        overlay.advanceBarVisibility()
    }

    func hover() { overlay.updateAutoHidePointer(at: BTPoint(x: bounds.minX + 100, y: 3)) }
    func leave() { overlay.updateAutoHidePointer(at: BTPoint(x: bounds.minX + 100, y: 100)) }
}

@Test(.macOSTestApplication, arguments: [false, true]) @MainActor
func autoHideRevealHoverOrdersAboveAnchorExactlyOnceBeforeExpansion(reduceMotion: Bool) throws {
    let f = AutoHideOrderingFixture(reduceMotion: reduceMotion)
    defer { f.overlay.hide() }
    #expect(f.strip.level == .normal && f.strip.isVisible && f.view.collapsed)
    f.hover()
    f.tick(to: 0.079)
    #expect(f.orders.isEmpty)
    f.tick(to: 0.081)
    #expect(!f.view.collapsed)
    #expect(f.orders.count == 1, "Revealing a visible anchored strip must order it above its window exactly once")
    let order = try #require(f.orders.first)
    #expect(order.panel === f.strip && order.mode == .above && order.anchor == 101)
    #expect(order.wasCollapsed, "Order the strip before its expand animation starts")
    f.hover()
    f.tick(to: 0.250)
    #expect(f.orders.count == 1, "A revealed strip must not be ordered again on pointer samples or animation ticks")
    #expect(f.strip.keyRequests == 0 && f.strip.frontOrders == 0)
}

@Test(.macOSTestApplication) @MainActor
func autoHideRevealCollapseOrdersNothing() {
    let f = AutoHideOrderingFixture(reduceMotion: false)
    defer { f.overlay.hide() }
    f.hover()
    f.tick(to: 0.081)
    f.tick(to: 0.250)
    f.orders.removeAll()
    f.leave()
    f.tick(to: 0.551)
    #expect(f.view.collapsed)
    f.tick(to: 0.672)
    #expect(f.view.autoHideAnimationDeadline == nil)
    #expect(f.orders.isEmpty, "Collapsing an Auto-hide strip must not order a panel")
}

/// Hovering while the strip is still collapsing reverses the animation. That
/// reveal starts from a collapsed view, so it restores the order once.
@Test(.macOSTestApplication) @MainActor
func autoHideRevealThatReversesACollapseOrdersOnce() throws {
    let f = AutoHideOrderingFixture(reduceMotion: false)
    defer { f.overlay.hide() }
    f.hover()
    f.tick(to: 0.081)
    f.tick(to: 0.250)
    f.leave()
    f.tick(to: 0.551)
    #expect(f.view.collapsed)
    f.now = 0.600
    #expect(f.view.isAutoHideCollapsing(at: f.now), "The hover must arrive during the collapse animation")
    f.orders.removeAll()
    f.hover()
    #expect(!f.view.collapsed, "A hover during the collapse animation reveals the strip again at once")
    #expect(f.orders.count == 1, "Reversing a collapse must restore the strip's order exactly once")
    let order = try #require(f.orders.first)
    #expect(order.panel === f.strip && order.mode == .above && order.anchor == 101 && order.wasCollapsed)
    f.hover()
    f.tick(to: 0.800)
    #expect(f.orders.count == 1, "Later samples and ticks must not order the revealed strip again")
}

@Test(.macOSTestApplication) @MainActor
func autoHideRevealWhileSpaceSuspendedOrdersNothing() {
    let f = AutoHideOrderingFixture()
    defer { f.overlay.hide() }
    f.hover()
    f.overlay.prepareForSpaceChange()
    f.hover()
    f.tick(to: 1)
    f.overlay.holdApplicationPicker(f.paneID, enabled: true)
    #expect(!f.overlay.showTabBar())
    #expect(f.view.collapsed)
    #expect(f.orders.isEmpty, "A Space-suspended overlay must not order a panel for reveal or collapse")
    #expect(f.strip.keyRequests == 0)
}

@Test(.macOSTestApplication) @MainActor
func autoHideRevealFloatingFallbackKeepsOcclusionPath() {
    let f = AutoHideOrderingFixture(anchor: nil)
    defer { f.overlay.hide() }
    let obscuring = BTRect(x: f.bounds.minX, y: 10, width: f.bounds.size.width, height: 24)
    f.refresh(anchor: nil, obscuringFrames: [obscuring])
    let frontOrders = f.strip.frontOrders
    #expect(f.strip.level == .floating && f.strip.isVisible)
    f.hover()
    f.tick(to: 0.081)
    #expect(!f.view.collapsed && !f.strip.isVisible)
    #expect(f.orders.isEmpty && f.strip.frontOrders == frontOrders)
    f.leave()
    f.tick(to: 0.382)
    #expect(f.view.collapsed && f.strip.isVisible)
    #expect(f.strip.frontOrders == frontOrders + 1)
    #expect(f.orders.isEmpty, "A floating strip must keep its occlusion path without an anchor order")
}

@Test(.macOSTestApplication, arguments: ["picker", "keyboard"]) @MainActor
func autoHideRevealHoldOrdersAboveAnchorExactlyOnce(source: String) throws {
    let f = AutoHideOrderingFixture()
    defer { f.overlay.hide() }
    if source == "keyboard" { #expect(f.overlay.showTabBar()) }
    else { f.overlay.holdApplicationPicker(f.paneID, enabled: true) }
    #expect(!f.view.collapsed)
    #expect(f.orders.count == 1, "A hold that reveals a visible anchored strip must restore its order")
    let order = try #require(f.orders.first)
    #expect(order.panel === f.strip && order.mode == .above && order.anchor == 101 && order.wasCollapsed)
    f.overlay.holdApplicationPicker(f.paneID, enabled: true)
    f.tick(to: 1)
    #expect(f.orders.count == 1, "Adding a hold to a revealed strip must not order it again")
}

@Test(.macOSTestApplication, arguments: [false, true]) @MainActor
func autoHideRevealUsesRefreshedAnchorAndDiscardsRemovedSelection(removesSelected: Bool) throws {
    let f = AutoHideOrderingFixture()
    defer { f.overlay.hide() }
    if removesSelected {
        f.overlay.removeUnavailableWindows([try #require(f.state.activeWindowID)])
        #expect(!f.view.pane.tabs.isEmpty)
    } else { f.refresh(anchor: 202) }
    f.orders.removeAll()
    f.hover()
    f.tick(to: 0.081)
    #expect(!f.view.collapsed)
    if removesSelected {
        #expect(f.orders.isEmpty, "A removed selected tab must not leave an anchor for reveal")
    } else {
        #expect(f.orders.count == 1, "Reveal must use the latest validated anchor")
        #expect(f.orders.first?.anchor == 202)
    }
}

@Test(.macOSTestApplication, arguments: [false, true]) @MainActor
func autoHideLastTabClosureRestoresEmptyPaneInputWithPointerObservation(retainedLifecycle: Bool) throws {
    _ = NSApplication.shared
    var pointer = BTPoint(x: 40700, y: 100)
    var panels: [NSPanel] = []
    let overlay = TabbedOverlayController(panelFactory: {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panels.append(panel)
        return panel
    }, addGlobalKeyMonitor: { _ in NSObject() }, addLocalKeyMonitor: { _ in NSObject() }, removeMonitor: { _ in },
    observesAutoHidePointer: true, automaticallyAdvanceVisibility: false, pointerLocation: { pointer })
    defer { overlay.hide() }
    var state = TabbedLayoutState(preset: .columns, presentation: .autoHide)
    let id = WindowID(rawValue: "last-tab-input")
    state.reconcile(windowIDs: [id], removed: [], focused: id)
    let paneID = try #require(state.panes.first { $0.tabs.contains(id) }?.id)
    let bounds = BTRect(x: 40000, y: 0, width: 800, height: 700)
    overlay.refresh(state: state, bounds: bounds, windows: [])
    let panel = try #require(panels.first { ($0.contentView as? TabbedPaneView)?.pane.id == paneID })
    #expect(panel.ignoresMouseEvents)
    state.removeClosedWindow(id)
    if retainedLifecycle { overlay.removeUnavailableWindows([id]) }
    else { overlay.refresh(state: state, bounds: bounds, windows: []) }
    #expect(!panel.ignoresMouseEvents)
    pointer = BTPoint(x: 40100, y: 100)
    overlay.updateAutoHidePointer(at: pointer)
    #expect(!panel.ignoresMouseEvents)
    let view = try #require(panel.contentView as? TabbedPaneView)
    view.layoutSubtreeIfNeeded()
    for button in [view.content.emptyAddButton, view.content.galleryButton] {
        #expect(!button.isHiddenOrHasHiddenAncestor)
        #expect(button.isEnabled)
        #expect(button.window === panel)
    }
}

@Test(.macOSTestApplication, arguments: [366.0, 726.0, 1446.0], [TabbedPreset.columns, .grid]) @MainActor
func autoHideLineAndBarMatchEveryPaneAndWindowEdge(width: Double, preset: TabbedPreset) throws {
    let fixture = AutoHideFixture(width: width, preset: preset)
    defer { fixture.overlay.hide() }
    let frames = fixture.state.frames(in: fixture.bounds)
    #expect(fixture.views.count == preset.paneCount)
    for view in fixture.views {
        let pane = try #require(frames[view.pane.id])
        let panel = try #require(view.window)
        let expected = CoordinateConverter.toAppKit(pane, mainScreenFrame: NSScreen.screens.first?.frame ?? .zero)
        #expect(view.collapsed)
        #expect(panel.frame.minX == expected.minX)
        #expect(panel.frame.maxX == expected.maxX)
        #expect(panel.frame.maxY == expected.maxY)
        #expect(panel.frame.height == 6)
        #expect(view.indicatorFrame.minX == 0)
        #expect(abs(view.indicatorFrame.width - pane.size.width) < 0.001)
        #expect(view.indicatorFrame.height == 3)
        #expect(view.showsGlass)
        // Enter the six-point band, then retain hover over the revealed bar.
        fixture.overlay.updateAutoHidePointer(at: BTPoint(x: pane.minX + 40, y: pane.minY + 3))
        fixture.tick(to: fixture.clock.now + 0.079)
        #expect(view.collapsed)
        fixture.tick(to: fixture.clock.now + 0.002)
        #expect(!view.collapsed)
        #expect(panel.frame.minX == expected.minX && panel.frame.maxX == expected.maxX)
        #expect(panel.frame.maxY == expected.maxY)
        #expect(abs(panel.frame.height - TabbedStripPresentation.alwaysVisible.barHeight) < 0.001)
        #expect(view.content.addButton.isHidden == false)
        let normal = TabbedStripLayout(width: pane.size.width, count: view.pane.tabs.count,
                                      selectedIndex: 0, presentation: .alwaysVisible)
        #expect(view.stripLayout.addFrame == normal.addFrame)
        #expect(view.stripLayout.height == normal.height)
        #expect(fixture.overlay.state == fixture.state) // Overlay reveal has no layout mutation.
    }
}

@Test(.macOSTestApplication) @MainActor func autoHidePointerDwellReentryAndPriorityUseInjectedClock() throws {
    let fixture = AutoHideFixture()
    defer { fixture.overlay.hide() }
    let view = try #require(fixture.views.first)
    let inside = BTPoint(x: fixture.bounds.minX + 100, y: 3)
    let outside = BTPoint(x: fixture.bounds.minX + 100, y: 100)
    fixture.overlay.updateAutoHidePointer(at: inside)
    fixture.tick(to: 0.079)
    #expect(view.collapsed)
    fixture.overlay.updateAutoHidePointer(at: outside)
    fixture.tick(to: 1)
    #expect(view.collapsed)
    fixture.overlay.updateAutoHidePointer(at: inside)
    fixture.tick(to: 1.081)
    #expect(!view.collapsed)
    fixture.overlay.updateAutoHidePointer(at: outside)
    fixture.tick(to: 1.380)
    #expect(!view.collapsed)
    fixture.overlay.updateAutoHidePointer(at: inside)
    fixture.tick(to: 2)
    #expect(!view.collapsed)
    fixture.overlay.updateAutoHidePointer(at: outside)
    fixture.tick(to: 2.301)
    #expect(view.collapsed)
    fixture.overlay.updateAutoHidePointer(at: BTPoint(x: fixture.bounds.minX + 2, y: 8))
    fixture.tick(to: 3)
    #expect(view.collapsed)
    #expect(view.window?.ignoresMouseEvents == true)
    fixture.overlay.updateAutoHidePointer(at: inside)
    #expect(view.window?.ignoresMouseEvents == false)
    fixture.overlay.dividerIsDragging = { true }
    fixture.tick(to: 4)
    #expect(view.collapsed)
    fixture.overlay.updateAutoHidePointer(at: inside)
    #expect(view.window?.ignoresMouseEvents == true)
    fixture.overlay.hide()
    fixture.tick(to: 5)
    #expect(view.window?.isVisible == false)
}

@Test(.macOSTestApplication, arguments: [false, true]) @MainActor
func autoHideQuickPassThroughBandDoesNotFlash(upward: Bool) throws {
    let fixture = AutoHideFixture(reduceMotion: false)
    defer { fixture.overlay.hide() }
    let view = try #require(fixture.views.first)
    // Downward ends on a traffic-light control; upward ends in the menu bar.
    let samples: [(Double, Double)] = upward
        ? [(0, 20), (0.010, 5), (0.040, 2), (0.060, -1), (0.200, -20)]
        : [(0, -10), (0.010, 2), (0.040, 5), (0.060, 20), (0.200, 20)]
    for (time, y) in samples {
        fixture.clock.now = time
        fixture.overlay.updateAutoHidePointer(at: BTPoint(x: fixture.bounds.minX + 20, y: y))
        fixture.tick(to: time)
        #expect(view.collapsed)
        #expect(view.layer?.mask?.animation(forKey: "autoHideReveal") == nil)
        #expect(view.window?.frame.height == 6)
    }
    fixture.tick(to: 1)
    #expect(view.collapsed)
}

@Test(.macOSTestApplication) @MainActor func autoHideRevealedBarKeepsHoverBelowTheBand() throws {
    let fixture = AutoHideFixture()
    defer { fixture.overlay.hide() }
    let view = try #require(fixture.views.first)
    fixture.overlay.updateAutoHidePointer(at: BTPoint(x: fixture.bounds.minX + 100, y: 3))
    fixture.tick(to: 0.081)
    #expect(!view.collapsed)
    fixture.overlay.updateAutoHidePointer(at: BTPoint(x: fixture.bounds.minX + 100, y: 25))
    fixture.tick(to: 1)
    #expect(!view.collapsed)
}

@Test(.macOSTestApplication, arguments: [false, true]) @MainActor
func autoHideRevealAnimationRespectsReduceMotion(_ reduceMotion: Bool) throws {
    let fixture = AutoHideFixture(reduceMotion: reduceMotion)
    defer { fixture.overlay.hide() }
    let view = try #require(fixture.views.first)
    fixture.overlay.updateAutoHidePointer(at: BTPoint(x: fixture.bounds.minX + 100, y: 3))
    fixture.tick(to: 0.081)
    #expect(!view.collapsed)
    #expect(view.revealAnimationDuration == (reduceMotion ? 0 : 0.160))
    #expect((view.layer?.mask?.animation(forKey: "autoHideReveal") != nil) == !reduceMotion)
    #expect((view.content.layer?.animation(forKey: "autoHideFade") != nil) == !reduceMotion)
    if !reduceMotion {
        let fade = try #require(view.content.layer?.animation(forKey: "autoHideFade"))
        #expect(abs(fade.duration - 0.096) < 0.001)
        #expect(fade.fillMode == .backwards)
    }
    #expect(abs(try #require(view.window).frame.width - fixture.bounds.size.width) < 0.001)
}

@Test(.macOSTestApplication) @MainActor func autoHideCollapseFadesThenShrinksWithInjectedClock() throws {
    let fixture = AutoHideFixture(reduceMotion: false)
    defer { fixture.overlay.hide() }
    let view = try #require(fixture.views.first)
    let inside = BTPoint(x: fixture.bounds.minX + 100, y: 3)
    let outside = BTPoint(x: fixture.bounds.minX + 100, y: 100)
    fixture.overlay.updateAutoHidePointer(at: inside)
    fixture.tick(to: 0.080)
    fixture.tick(to: 0.250) // Finish reveal.
    fixture.overlay.updateAutoHidePointer(at: outside)
    fixture.tick(to: 0.549)
    #expect(!view.collapsed)
    fixture.tick(to: 0.550)
    #expect(view.collapsed)
    #expect(!view.content.isHidden)
    #expect(view.window?.frame.height == 34)
    let collapse = try #require(view.layer?.mask?.animation(forKey: "autoHideCollapse") as? CAKeyframeAnimation)
    #expect(abs(collapse.duration - 0.120) < 0.0001)
    let fade = try #require(view.content.layer?.animation(forKey: "autoHideFade"))
    #expect(abs(fade.duration - 0.060) < 0.0001)
    fixture.tick(to: 0.580)
    #expect(abs(view.autoHidePresentation(at: fixture.clock.now).opacity - 0.5) < 0.0001)
    #expect(view.autoHidePresentation(at: fixture.clock.now).height == 34)
    fixture.tick(to: 0.610)
    #expect(view.autoHidePresentation(at: fixture.clock.now).opacity < 0.0001)
    #expect(abs(view.autoHidePresentation(at: fixture.clock.now).height - 34) < 0.0001)
    fixture.tick(to: 0.640)
    let halfway = view.autoHidePresentation(at: fixture.clock.now)
    #expect(halfway.opacity == 0)
    // Cubic ease-in has traversed one eighth of the height at its midpoint.
    #expect(abs(halfway.height - (34 - 31 * 0.125)) < 0.0001)
    // The actual compositor path uses the same clock samples.
    let path = try #require(collapse.values?[45]) as! CGPath
    #expect(abs(path.boundingBoxOfPath.height - halfway.height) < 0.0001)
    fixture.tick(to: 0.671)
    #expect(view.content.isHidden)
    #expect(view.autoHideAnimationDeadline == nil)
    #expect(view.layer?.mask == nil)
    #expect(view.window?.frame.height == 6)
    #expect(fixture.overlay.state == fixture.state)
}

@Test(.macOSTestApplication, arguments: [0.030, 0.090, 0.119]) @MainActor
func autoHideCollapseReentryReversesCurrentHeightWithoutDwell(elapsed: Double) throws {
    let fixture = AutoHideFixture(reduceMotion: false)
    defer { fixture.overlay.hide() }
    let view = try #require(fixture.views.first)
    let inside = BTPoint(x: fixture.bounds.minX + 100, y: 3)
    fixture.overlay.updateAutoHidePointer(at: inside)
    fixture.tick(to: 0.080)
    fixture.tick(to: 0.250)
    fixture.overlay.updateAutoHidePointer(at: BTPoint(x: inside.x, y: 100))
    fixture.tick(to: 0.550)
    fixture.tick(to: 0.550 + elapsed)
    let before = view.autoHidePresentation(at: fixture.clock.now)
    fixture.overlay.updateAutoHidePointer(at: inside)
    #expect(!view.collapsed) // No second 80 ms dwell.
    let after = view.autoHidePresentation(at: fixture.clock.now)
    #expect(abs(after.height - before.height) < 0.0001)
    #expect(abs(after.opacity - before.opacity) < 0.0001)
    #expect(view.layer?.mask?.animation(forKey: "autoHideCollapse") == nil)
    let reveal = try #require(view.layer?.mask?.animation(forKey: "autoHideReveal") as? CAKeyframeAnimation)
    let firstPath = try #require(reveal.values?.first) as! CGPath
    #expect(abs(firstPath.boundingBoxOfPath.height - before.height) < 0.0001)
    fixture.tick(to: fixture.clock.now + 0.010)
    #expect(view.autoHidePresentation(at: fixture.clock.now).height >= before.height)
    fixture.tick(to: fixture.clock.now + 0.160)
    #expect(view.autoHidePresentation(at: fixture.clock.now).height == 34)
    #expect(view.autoHideAnimationDeadline == nil)
    #expect(!view.content.isHidden)
    #expect(fixture.overlay.state == fixture.state)
}

@Test(.macOSTestApplication) @MainActor func autoHideCollapseSurvivesRefreshAndStopsForReducedMotionOrSpaceChange() throws {
    let fixture = AutoHideFixture(reduceMotion: false)
    defer { fixture.overlay.hide() }
    let view = try #require(fixture.views.first)
    fixture.overlay.updateAutoHidePointer(at: BTPoint(x: fixture.bounds.minX + 100, y: 3))
    fixture.tick(to: 0.080)
    fixture.tick(to: 0.250)
    fixture.overlay.updateAutoHidePointer(at: BTPoint(x: fixture.bounds.minX + 100, y: 100))
    fixture.tick(to: 0.550)
    fixture.tick(to: 0.640)
    let before = view.autoHidePresentation(at: fixture.clock.now)
    fixture.overlay.refresh(state: fixture.state, bounds: fixture.bounds, windows: [])
    #expect(view.isAutoHideCollapsing(at: fixture.clock.now))
    #expect(view.autoHidePresentation(at: fixture.clock.now).height == before.height)
    view.reduceMotion = { true }
    fixture.tick(to: 0.641)
    #expect(view.autoHideAnimationDeadline == nil)
    #expect(view.content.isHidden)
    #expect(view.window?.frame.height == 6)
    view.reduceMotion = { false }
    fixture.overlay.updateAutoHidePointer(at: BTPoint(x: fixture.bounds.minX + 100, y: 3))
    fixture.tick(to: 0.722)
    #expect(view.autoHideAnimationDeadline != nil)
    fixture.overlay.prepareForSpaceChange()
    #expect(view.autoHideAnimationDeadline == nil)
    #expect(view.content.isHidden)
    #expect(view.window?.frame.height == 6)
}

@Test(.macOSTestApplication) @MainActor func autoHideReducedMotionCollapseIsInstant() throws {
    let fixture = AutoHideFixture(reduceMotion: true)
    defer { fixture.overlay.hide() }
    let view = try #require(fixture.views.first)
    fixture.overlay.updateAutoHidePointer(at: BTPoint(x: fixture.bounds.minX + 100, y: 3))
    fixture.tick(to: 0.080)
    fixture.overlay.updateAutoHidePointer(at: BTPoint(x: fixture.bounds.minX + 100, y: 100))
    fixture.tick(to: 0.381)
    #expect(view.collapsed && view.content.isHidden)
    #expect(view.layer?.mask == nil)
    #expect(view.content.layer?.animation(forKey: "autoHideFade") == nil)
    #expect(view.autoHideAnimationDeadline == nil)
    #expect(view.window?.frame.height == 6)
}

@Test(.macOSTestApplication, arguments: [false, true], [false, true]) @MainActor
func autoHideHiddenLineIsBorderlessWithNeutralSolidFallback(dark: Bool, reduceTransparency: Bool) throws {
    let fixture = AutoHideFixture()
    defer { fixture.overlay.hide() }
    let view = try #require(fixture.views.first)
    view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    view.displayOptions = { (reduceTransparency, false) }
    view.overlayAppearance.useLiquidGlass = !reduceTransparency
    // Also cover the explicit glass-off setting separately from Reduce Transparency.
    for glassEnabled in [false, true] {
        view.overlayAppearance.useLiquidGlass = glassEnabled
        for active in [false, true] {
            view.active = active
            view.refreshAppearance()
            #expect(view.glass.showsBorder == false)
            #expect(view.glass.subviews.allSatisfy { ($0.layer?.borderWidth ?? 0) == 0 })
            #expect(view.glass.frame.height == 3)
            let solid = !glassEnabled || reduceTransparency
            #expect(view.showsGlass == !solid)
            let backing = try #require(view.glass.layer?.backgroundColor.flatMap { NSColor(cgColor: $0) }?.usingColorSpace(.deviceRGB))
            #expect(abs(backing.alphaComponent - (dark && !solid ? 0.15 : 0)) < 0.001)
            if dark && !solid {
                #expect(backing.redComponent == backing.greenComponent)
                #expect(backing.greenComponent == backing.blueComponent)
                #expect(backing.redComponent == 1)
            }
            if solid {
                #expect(view.glass.alphaValue == 1)
                let color = try #require(view.glass.solidColor?.usingColorSpace(.deviceRGB))
                #expect(color.alphaComponent == 1)
                var expected: NSColor?
                view.effectiveAppearance.performAsCurrentDrawingAppearance {
                    expected = NSColor.labelColor.withAlphaComponent(1).blended(withFraction: 1 - ((dark ? 0.35 : 0.25) + (active ? 0.05 : 0)),
                                                          of: NSColor.windowBackgroundColor.withAlphaComponent(1))?.usingColorSpace(.deviceRGB)
                }
                #expect(abs(color.redComponent - (try #require(expected)).redComponent) < 0.01)
                #expect(abs(color.greenComponent - (try #require(expected)).greenComponent) < 0.01)
                #expect(abs(color.blueComponent - (try #require(expected)).blueComponent) < 0.01)
            }
        }
    }
}

@Suite(.macOSTestApplication, .serialized) @MainActor struct TabbedAutoHideSnapshots {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["BETTERTILE_AUTOHIDE_SHOTS"] != nil,
                   "Requires an explicit offline snapshot directory."))
    func snapshots() throws {
        let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["BETTERTILE_AUTOHIDE_SHOTS"]))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for dark in [false, true] {
            let appearance = try #require(NSAppearance(named: dark ? .darkAqua : .aqua))
            for width in [760.0, 1440.0] {
                for preset in [TabbedPreset.columns, .grid] {
                    for variant in ["hidden", "revealed", "hidden-solid", "hidden-reduce-transparency"] {
                        let revealed = variant == "revealed"
                        let fixture = AutoHideFixture(width: width, preset: preset)
                        defer { fixture.overlay.hide() }
                        let frames = fixture.state.frames(in: fixture.bounds)
                        let image = NSImage(size: NSSize(width: width, height: 720))
                        if revealed {
                            for view in fixture.views { fixture.overlay.holdApplicationPicker(view.pane.id, enabled: true) }
                        }
                        appearance.performAsCurrentDrawingAppearance {
                            image.lockFocus()
                            defer { image.unlockFocus() }
                            NSColor.windowBackgroundColor.setFill()
                            NSRect(x: 0, y: 0, width: width, height: 720).fill()
                            for view in fixture.views {
                                guard let pane = frames[view.pane.id] else { continue }
                                let window = NSRect(x: pane.minX - fixture.bounds.minX, y: 720 - pane.maxY,
                                                    width: pane.size.width, height: pane.size.height - 6)
                                NSColor.textBackgroundColor.setFill()
                                NSBezierPath(roundedRect: window, xRadius: 7, yRadius: 7).fill()
                                ("Window \(view.number)" as NSString).draw(at: NSPoint(x: window.minX + 20, y: window.maxY - 52),
                                    withAttributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.secondaryLabelColor])
                                view.appearance = appearance
                                view.overlayAppearance.useLiquidGlass = variant != "hidden-solid"
                                view.displayOptions = { (variant == "hidden-reduce-transparency", false) }
                                view.refreshAppearance()
                                view.titles = ["Project notes", "Research"]
                                view.icons = [NSImage(systemSymbolName: "doc.text", accessibilityDescription: nil),
                                              NSImage(systemSymbolName: "globe", accessibilityDescription: nil)]
                                view.layoutSubtreeIfNeeded()
                                guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                                    Issue.record("Could not render Auto-hide strip")
                                    continue
                                }
                                view.cacheDisplay(in: view.bounds, to: bitmap)
                                let strip = NSImage(size: view.bounds.size)
                                strip.addRepresentation(bitmap)
                                strip.draw(in: NSRect(x: window.minX, y: 720 - (pane.minY - fixture.bounds.minY) - view.bounds.height,
                                                      width: pane.size.width, height: view.bounds.height),
                                           from: .zero, operation: .sourceOver, fraction: 1)
                            }
                        }
                        let bitmap = try #require(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
                        let name = "\(dark ? "dark" : "light")-\(Int(width))-\(preset.rawValue)-\(variant).png"
                        try #require(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent(name))
                    }
                }
            }
        }
    }
}

/// The uncached rule, from the current frames: the pane whose collapsed band takes a sample.
private func referenceBandPane(at point: BTPoint, state: TabbedLayoutState, bounds: BTRect) -> UUID? {
    guard state.presentation == .autoHide else { return nil }
    let frames = state.frames(in: bounds)
    return state.panes.first { pane in
        guard !pane.tabs.isEmpty, let frame = frames[pane.id] else { return false }
        return BTRect(x: frame.minX, y: frame.minY, width: frame.size.width, height: 6).contains(point)
            && point.x >= frame.minX + 7 && point.x < frame.maxX - 7
    }?.id
}

/// The uncached rule, from the current frames: the panes whose side lanes leave a sample to resize handles.
private func referenceLanePanes(at point: BTPoint, state: TabbedLayoutState, bounds: BTRect) -> Set<UUID> {
    guard state.presentation == .autoHide else { return [] }
    let frames = state.frames(in: bounds)
    return Set(state.panes.filter { pane in
        guard !pane.tabs.isEmpty, let frame = frames[pane.id] else { return false }
        return point.x < frame.minX + 7 || point.x >= frame.maxX - 7
    }.map(\.id))
}

/// The uncached rule, from the current frames: the pane whose full strip contains a sample.
private func referenceInputPane(at point: BTPoint, state: TabbedLayoutState, bounds: BTRect) -> UUID? {
    guard state.presentation == .autoHide else { return nil }
    let frames = state.frames(in: bounds)
    return state.panes.first { pane in
        guard !pane.tabs.isEmpty, let frame = frames[pane.id] else { return false }
        return BTRect(x: frame.minX, y: frame.minY, width: frame.size.width, height: state.presentation.barHeight).contains(point)
    }?.id
}

/// Pointer samples read the pane frames once per layout generation, however many arrive.
@Test(.macOSTestApplication) @MainActor func autoHidePointerReadsPaneFramesOncePerLayoutGeneration() throws {
    let fixture = AutoHideFixture(width: 1200, preset: .grid)
    defer { fixture.overlay.hide() }
    let overlay = fixture.overlay
    let frames = fixture.state.frames(in: fixture.bounds)
    let ordered = fixture.state.panes.compactMap { frames[$0.id] }
    func sweep() {
        for index in 0..<300 {
            let frame = ordered[index % ordered.count]
            overlay.updateAutoHidePointer(at: BTPoint(x: frame.minX + Double((index * 37) % Int(frame.size.width)),
                                                      y: frame.minY + Double(index % 60)))
        }
    }
    let builds = overlay.autoHidePointerCacheBuilds
    sweep()
    #expect(overlay.autoHidePointerCacheBuilds == builds + 1)
    // Dwell, reveal, collapse, and holds change no layout.
    for step in 1...10 {
        fixture.tick(to: Double(step) * 0.05)
        sweep()
    }
    overlay.holdApplicationPicker(fixture.state.panes[0].id, enabled: true)
    sweep()
    overlay.holdApplicationPicker(fixture.state.panes[0].id, enabled: false)
    sweep()
    #expect(overlay.autoHidePointerCacheBuilds == builds + 1)
    // Every refresh starts a new generation, even with the same layout.
    overlay.refresh(state: fixture.state, bounds: fixture.bounds, windows: [])
    sweep()
    overlay.refreshResize(state: fixture.state, bounds: fixture.bounds)
    sweep()
    #expect(overlay.autoHidePointerCacheBuilds == builds + 3)
}

/// After each kind of layout change, samples use the new frames and bands, never the cached ones.
@Test(.macOSTestApplication, arguments: ["refresh relayout", "resize relayout", "closed tabs", "display", "gap",
                  "Always visible", "Auto-hide on", "space change", "mode exit"])
@MainActor func autoHidePointerNeverUsesGeometryFromBeforeAChange(_ change: String) throws {
    let initial = fillingEmptyPanes(TabbedLayoutState(preset: .columns, presentation: change == "Auto-hide on" ? .alwaysVisible : .autoHide))
    let fixture = AutoHideFixture(width: 1200, state: initial)
    defer { fixture.overlay.hide() }
    let overlay = fixture.overlay
    let old = (state: fixture.state, bounds: fixture.bounds)
    // Fill the cache with the first layout, away from every band.
    for x in stride(from: old.bounds.minX, to: old.bounds.maxX, by: 5) {
        overlay.updateAutoHidePointer(at: BTPoint(x: x, y: old.bounds.minY + 200))
    }
    let builds = overlay.autoHidePointerCacheBuilds
    var state = old.state, bounds = old.bounds
    switch change {
    case "refresh relayout", "resize relayout":
        let divider = try #require(state.dividers(in: bounds).first?.branchID)
        let adjusted = state.adjustDivider(divider, by: 0.2, in: bounds)
        #expect(adjusted)
        if change == "refresh relayout" { overlay.refresh(state: state, bounds: bounds, windows: []) }
        else { overlay.refreshResize(state: state, bounds: bounds) }
    case "closed tabs":
        let closed = Set(state.panes[1].tabs)
        for id in closed { state.removeClosedWindow(id) }
        overlay.removeUnavailableWindows(closed)
    case "display":
        bounds = BTRect(x: bounds.minX + 300, y: bounds.minY + 40, width: bounds.size.width - 200, height: bounds.size.height - 40)
        overlay.refresh(state: state, bounds: bounds, windows: [])
    case "gap":
        var layout = state.layout
        layout.metrics.paneGap = 40
        state.synchronize(with: layout)
        overlay.refresh(state: state, bounds: bounds, windows: [])
    case "Always visible", "Auto-hide on":
        state.setPresentation(change == "Always visible" ? .alwaysVisible : .autoHide)
        overlay.refresh(state: state, bounds: bounds, windows: [])
    case "space change":
        overlay.prepareForSpaceChange()
        overlay.updateAutoHidePointer(at: BTPoint(x: bounds.minX + 100, y: bounds.minY + 3))
        #expect(overlay.autoHidePointerCacheBuilds == builds) // A suspended sample reads nothing.
        // The desktop returns after its display moved.
        bounds = BTRect(x: bounds.minX + 300, y: bounds.minY, width: bounds.size.width, height: bounds.size.height)
        overlay.refresh(state: state, bounds: bounds, windows: [])
    default:
        // Tabbed ends, then starts again with another layout.
        overlay.hide()
        state = fillingEmptyPanes(TabbedLayoutState(preset: .rows, presentation: .autoHide))
        overlay.refresh(state: state, bounds: bounds, windows: [])
    }
    #expect(overlay.state == state)
    let xs = stride(from: min(old.bounds.minX, bounds.minX) - 20, through: max(old.bounds.maxX, bounds.maxX) + 20, by: 1.0)
    let bandRows = Set([old.state.frames(in: old.bounds), state.frames(in: bounds)].flatMap(\.values).map { $0.minY + 3 })

    // A sample that the old and new bands answer differently reveals only what the new band says.
    let distinguishing = bandRows.sorted().lazy.flatMap { y in xs.lazy.map { BTPoint(x: $0, y: y) } }.first {
        referenceBandPane(at: $0, state: old.state, bounds: old.bounds) != referenceBandPane(at: $0, state: state, bounds: bounds)
    }
    let point = try #require(distinguishing, "No sample tells the old geometry from the new one.")
    let expected = referenceBandPane(at: point, state: state, bounds: bounds)
    overlay.updateAutoHidePointer(at: point)
    fixture.tick(to: fixture.clock.now + 0.081)
    if state.presentation == .autoHide {
        for pane in state.panes where !pane.tabs.isEmpty {
            #expect(fixture.view(for: pane.id)?.collapsed == (pane.id != expected), "\(point)")
        }
    }

    // Along the new strips, every pane's side lanes follow the new frames; empty panes and other
    // presentations keep input. Samples outside every strip return early and change no input.
    var mismatches: [String] = []
    var checked = 0
    for y in Set(state.frames(in: bounds).values.map { $0.minY + 3 }).sorted() {
        for x in xs {
            let sample = BTPoint(x: x, y: y)
            let inStrip = referenceInputPane(at: sample, state: state, bounds: bounds) != nil
            guard inStrip || state.presentation != .autoHide else { continue }
            overlay.updateAutoHidePointer(at: sample)
            checked += 1
            let lanes = referenceLanePanes(at: sample, state: state, bounds: bounds)
            for pane in state.panes {
                guard let panel = fixture.view(for: pane.id)?.window else { continue }
                if panel.ignoresMouseEvents != lanes.contains(pane.id) { mismatches.append("pane \(pane.id) at \(sample)") }
            }
        }
    }
    #expect(checked > 100)
    #expect(mismatches.isEmpty, "\(mismatches.prefix(5))")
    #expect(overlay.autoHidePointerCacheBuilds == builds + 1)
}

/// Moves over the windows return before any per-pane work, unless a hover must end. Moves along a
/// strip write `ignoresMouseEvents` only when it changes. The hover timing stays the same.
@Test(.macOSTestApplication) @MainActor func autoHidePointerReturnsEarlyOutsideEveryStrip() throws {
    let fixture = AutoHideFixture(width: 1200, preset: .grid)
    defer { fixture.overlay.hide() }
    let overlay = fixture.overlay
    let frames = fixture.state.frames(in: fixture.bounds)
    let ordered = fixture.state.panes.compactMap { frames[$0.id] }
    let first = try #require(frames[fixture.state.panes[0].id])
    let view = try #require(fixture.view(for: fixture.state.panes[0].id))
    let panels = fixture.panelLog.panels
    func overWindows(_ count: Int) {
        for index in 0..<count {
            let frame = ordered[index % ordered.count]
            overlay.updateAutoHidePointer(at: BTPoint(x: frame.minX + 10 + Double((index * 37) % Int(frame.size.width - 20)),
                                                      y: frame.minY + 40 + Double(index % 200)))
        }
    }
    // The first sample of a geometry is a full pass.
    overWindows(1)
    let passes = overlay.autoHidePointerPasses
    let firstWrites = panels.map(\.inputWrites)
    overWindows(500)
    #expect(overlay.autoHidePointerPasses == passes)
    #expect(panels.map(\.inputWrites) == firstWrites)

    // Inside a band: a full pass, and the same 80 ms dwell.
    overlay.updateAutoHidePointer(at: BTPoint(x: first.minX + 40, y: first.minY + 3))
    #expect(overlay.autoHidePointerPasses == passes + 1)
    fixture.tick(to: 0.079)
    #expect(view.collapsed)
    fixture.tick(to: 0.081)
    #expect(!view.collapsed)
    // Along the revealed strip, away from the side lanes, no panel's input changes.
    let writes = panels.map(\.inputWrites)
    for index in 0..<200 {
        overlay.updateAutoHidePointer(at: BTPoint(x: first.minX + 10 + Double(index % Int(first.size.width - 20)),
                                                  y: first.minY + Double(index % 34)))
    }
    #expect(overlay.autoHidePointerPasses == passes + 201)
    #expect(panels.map(\.inputWrites) == writes)
    #expect(!view.collapsed)

    // Leaving takes one full pass to end the hover; later moves return early. The same 300 ms delay applies.
    overWindows(1)
    #expect(overlay.autoHidePointerPasses == passes + 202)
    overWindows(300)
    #expect(overlay.autoHidePointerPasses == passes + 202)
    fixture.tick(to: 0.081 + 0.299)
    #expect(!view.collapsed)
    fixture.tick(to: 0.081 + 0.301)
    #expect(view.collapsed)
    overWindows(100)
    #expect(overlay.autoHidePointerPasses == passes + 202)
    #expect(overlay.autoHidePointerCacheBuilds == 1)
}

/// A divider drag that starts away from the strips still collapses a revealed strip on the next move.
@Test(.macOSTestApplication) @MainActor func autoHidePointerOutsideTheStripsStillAppliesADividerDrag() throws {
    let fixture = AutoHideFixture(width: 1200, preset: .columns)
    defer { fixture.overlay.hide() }
    let overlay = fixture.overlay
    let first = try #require(fixture.state.frames(in: fixture.bounds)[fixture.state.panes[0].id])
    let view = try #require(fixture.view(for: fixture.state.panes[0].id))
    let body = BTPoint(x: first.minX + 100, y: first.minY + 300)
    overlay.updateAutoHidePointer(at: BTPoint(x: first.minX + 40, y: first.minY + 3))
    fixture.tick(to: 0.081)
    #expect(!view.collapsed)
    overlay.updateAutoHidePointer(at: body)
    fixture.tick(to: 0.2)
    #expect(!view.collapsed) // The 300 ms delay is still running.
    var dragging = true
    overlay.dividerIsDragging = { dragging }
    let passes = overlay.autoHidePointerPasses
    overlay.updateAutoHidePointer(at: body)
    #expect(overlay.autoHidePointerPasses == passes + 1)
    #expect(view.collapsed)
    #expect(fixture.views.allSatisfy { $0.window?.ignoresMouseEvents == true })
    overlay.updateAutoHidePointer(at: BTPoint(x: body.x + 5, y: body.y))
    #expect(overlay.autoHidePointerPasses == passes + 1)
    // The drag ends: the next move outside the strips records that once.
    dragging = false
    overlay.updateAutoHidePointer(at: body)
    #expect(overlay.autoHidePointerPasses == passes + 2)
    overlay.updateAutoHidePointer(at: body)
    #expect(overlay.autoHidePointerPasses == passes + 2)
}

/// A request status fills its whole pane, so the pane's side lanes apply there until the status clears.
@Test(.macOSTestApplication) @MainActor func autoHidePointerTreatsARequestPaneAsOneInputArea() throws {
    let fixture = AutoHideFixture(width: 1200, preset: .columns)
    defer { fixture.overlay.hide() }
    let overlay = fixture.overlay
    let paneID = fixture.state.panes[0].id
    let frame = try #require(fixture.state.frames(in: fixture.bounds)[paneID])
    let panel = try #require(fixture.view(for: paneID)?.window)
    let lane = BTPoint(x: frame.maxX - 3, y: frame.minY + 300)
    let middle = BTPoint(x: frame.midX, y: frame.minY + 300)
    overlay.updateAutoHidePointer(at: middle)
    #expect(!panel.ignoresMouseEvents)
    overlay.updateAutoHidePointer(at: lane)
    #expect(!panel.ignoresMouseEvents) // Outside every strip: no pass.

    overlay.setPaneRequestStatus(PaneRequestStatus(requestID: UUID(), paneID: paneID, appName: "App",
                                                   appIconURL: nil, kind: .placing))
    #expect(abs(panel.frame.height - frame.size.height) < 0.001)
    overlay.updateAutoHidePointer(at: lane)
    #expect(panel.ignoresMouseEvents)
    overlay.updateAutoHidePointer(at: middle)
    #expect(!panel.ignoresMouseEvents)
    let builds = overlay.autoHidePointerCacheBuilds

    overlay.setPaneRequestStatus(nil)
    let passes = overlay.autoHidePointerPasses
    overlay.updateAutoHidePointer(at: middle) // A new geometry: one full pass.
    overlay.updateAutoHidePointer(at: lane)
    #expect(overlay.autoHidePointerCacheBuilds == builds + 1)
    #expect(overlay.autoHidePointerPasses == passes + 1)
    #expect(!panel.ignoresMouseEvents)
}

/// Auto-hide panes split in a spiral until there are `paneCount`, each with one tab.
private func spiralAutoHideState(paneCount: Int) -> TabbedLayoutState {
    var state = TabbedLayoutState(preset: .single, presentation: .autoHide)
    let ids = (0..<paneCount).map { WindowID(rawValue: "spiral-\($0)") }
    state.reconcile(windowIDs: ids, removed: [], focused: ids[0])
    for index in 1..<paneCount {
        guard let target = state.panes.first(where: { $0.tabs.contains(ids[index - 1]) }) else { break }
        state.split(paneID: target.id, moving: ids[index], edge: index.isMultiple(of: 2) ? .bottom : .right)
    }
    return state
}

// Opt-in synthetic main-thread benchmark of one auto-hide pointer sample. Run serially on one
// machine: BETTERTILE_AUTOHIDE_BENCH=1 swift test --filter "autoHidePointer(Location)?Benchmark"
// It measures BetterTile's own work per sample with offscreen panels. It does not measure event
// delivery, NSEvent.mouseLocation, or WindowServer compositing.
@Test(.macOSTestApplication, .enabled(if: ProcessInfo.processInfo.environment["BETTERTILE_AUTOHIDE_BENCH"] != nil
               && ProcessInfo.processInfo.environment["CI"] == nil,
               "Requires an explicit local auto-hide pointer benchmark run."))
@MainActor func autoHidePointerBenchmark() throws {
    let batches = 41, movesPerBatch = 2000
    func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) * 1e-18
    }
    for paneCount in [4, 12] {
        for scenario in ["over windows", "along a revealed strip"] {
            let fixture = AutoHideFixture(width: 2400, height: 1400, preset: .grid,
                                          state: paneCount == 4 ? nil : spiralAutoHideState(paneCount: paneCount))
            defer { fixture.overlay.hide() }
            #expect(fixture.state.panes.count == paneCount)
            let frames = fixture.state.frames(in: fixture.bounds)
            let ordered = fixture.state.panes.compactMap { frames[$0.id] }
            let points: [BTPoint]
            if scenario == "over windows" {
                // The pointer crosses every pane's window area and never enters a band.
                points = (0..<movesPerBatch).map { index in
                    let frame = ordered[index % ordered.count]
                    return BTPoint(x: frame.minX + 10 + Double((index * 37) % max(1, Int(frame.size.width) - 20)),
                                   y: frame.minY + 40 + Double((index * 11) % max(1, Int(frame.size.height) - 60)))
                }
            } else {
                // Reveal the first pane, then stay inside its strip without a state change.
                let frame = ordered[0]
                fixture.overlay.updateAutoHidePointer(at: BTPoint(x: frame.minX + 40, y: frame.minY + 3))
                fixture.tick(to: 0.081)
                #expect(fixture.views.first { $0.pane.id == fixture.state.panes[0].id }?.collapsed == false)
                points = (0..<movesPerBatch).map { index in
                    BTPoint(x: frame.minX + 10 + Double((index * 37) % max(1, Int(frame.size.width) - 20)),
                            y: frame.minY + 2 + Double(index % 28))
                }
            }
            var perMove: [Double] = []
            let clock = ContinuousClock() // real-time: opt-in local benchmark measures actual pointer-processing cost
            for batch in 0..<(batches + 5) {
                let elapsed = clock.measure {
                    for point in points { fixture.overlay.updateAutoHidePointer(at: point) }
                }
                if batch >= 5 { perMove.append(seconds(elapsed) / Double(movesPerBatch)) }
            }
            perMove.sort()
            let line = String(format: "auto-hide pointer, %2d panes, %@: median %.3f µs  p10 %.3f  p90 %.3f  (%d batches × %d moves)",
                              paneCount, scenario, perMove[perMove.count / 2] * 1e6, perMove[perMove.count / 10] * 1e6,
                              perMove[perMove.count * 9 / 10] * 1e6, batches, movesPerBatch)
            print(line)
            if let path = ProcessInfo.processInfo.environment["BETTERTILE_PERF_OUT"] {
                if !FileManager.default.fileExists(atPath: path) { try Data().write(to: URL(fileURLWithPath: path)) }
                let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: Data((line + "\n").utf8))
            }
        }
    }
}

// Opt-in synthetic benchmark of the two smaller per-sample costs: converting the pointer location,
// and writing `ignoresMouseEvents` with an unchanged value. Same run command as above.
@Test(.macOSTestApplication, .enabled(if: ProcessInfo.processInfo.environment["BETTERTILE_AUTOHIDE_BENCH"] != nil
               && ProcessInfo.processInfo.environment["CI"] == nil,
               "Requires an explicit local auto-hide pointer benchmark run."))
@MainActor func autoHidePointerLocationBenchmark() throws {
    _ = NSApplication.shared
    let iterations = 20000, batches = 21
    let panel = NSPanel(contentRect: NSRect(x: 40000, y: 0, width: 400, height: 34),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    let cases: [(String, @MainActor () -> Void)] = [
        ("location with NSScreen.screens", {
            _ = NSScreen.screens.first.map { CoordinateConverter.pointToTopLeft(NSEvent.mouseLocation, mainScreenFrame: $0.frame) }
        }),
        ("location with the cached frame", {
            _ = TabbedMainScreenFrame.current.map { CoordinateConverter.pointToTopLeft(NSEvent.mouseLocation, mainScreenFrame: $0) }
        }),
        ("unchanged ignoresMouseEvents write", { panel.ignoresMouseEvents = false }),
        ("ignoresMouseEvents compare only", { if panel.ignoresMouseEvents != false { panel.ignoresMouseEvents = false } }),
    ]
    let clock = ContinuousClock() // real-time: opt-in local benchmark measures actual pointer-processing cost
    for (name, body) in cases {
        var perCall: [Double] = []
        for batch in 0..<(batches + 3) {
            let elapsed = clock.measure { for _ in 0..<iterations { body() } }
            let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) * 1e-18
            if batch >= 3 { perCall.append(seconds / Double(iterations)) }
        }
        perCall.sort()
        let line = String(format: "auto-hide sample part, %@: median %.3f µs  p10 %.3f  p90 %.3f  (%d batches × %d calls)",
                          name, perCall[perCall.count / 2] * 1e6, perCall[perCall.count / 10] * 1e6,
                          perCall[perCall.count * 9 / 10] * 1e6, batches, iterations)
        print(line)
        if let path = ProcessInfo.processInfo.environment["BETTERTILE_PERF_OUT"] {
            if !FileManager.default.fileExists(atPath: path) { try Data().write(to: URL(fileURLWithPath: path)) }
            let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data((line + "\n").utf8))
        }
    }
}


@Test(.macOSTestApplication) @MainActor func autoHideCoalescesBandEntryExitAndFlushesAPress() throws {
    let ticks = ResizeDisplayLink(automatic: false)
    let fixture = AutoHideFixture(pointerTicks: ticks)
    let overlay = fixture.overlay
    defer { overlay.hide() }
    let frame = try #require(fixture.state.frames(in: fixture.bounds)[fixture.state.panes[0].id])
    let view = try #require(fixture.view(for: fixture.state.panes[0].id))
    let band = BTPoint(x: frame.minX + 50, y: frame.minY + 3)
    let body = BTPoint(x: frame.minX + 50, y: frame.minY + 100)
    let passes = overlay.autoHidePointerPasses
    for _ in 0..<1000 { overlay.queueAutoHidePointer(at: band) }
    #expect(overlay.autoHidePointerPasses == passes)
    ticks.fire()
    #expect(overlay.autoHidePointerPasses == passes + 1)
    fixture.tick(to: 0.079)
    #expect(view.collapsed)
    fixture.tick(to: 0.081)
    #expect(!view.collapsed)
    for _ in 0..<1000 { overlay.queueAutoHidePointer(at: band) }
    overlay.queueAutoHidePointer(at: body)
    ticks.fire()
    #expect(overlay.autoHidePointerPasses == passes + 2)
    fixture.tick(to: 0.380)
    #expect(!view.collapsed)
    fixture.tick(to: 0.382)
    #expect(view.collapsed)
    overlay.queueAutoHidePointer(at: band)
    overlay.flushAutoHidePointer()
    #expect(overlay.autoHidePointerPasses == passes + 3)
    ticks.fire()
    #expect(overlay.autoHidePointerPasses == passes + 3)
    overlay.queueAutoHidePointer(at: body)
    overlay.hide()
    ticks.fire()
    #expect(overlay.autoHidePointerPasses == passes + 3)
}
