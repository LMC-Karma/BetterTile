import AppKit
import BetterTileCore
import BetterTileTestSupport
import Testing
@testable import BetterTileMacOS

/// Samples native geometry after deferred layout, with a bounded number of attempts.
@MainActor private func waitForPanelGeometry(
    panels: () -> [NSWindow],
    nativeLayoutTurn: @MainActor () async -> Void = { await nextPanelLayoutTurn() },
    matches: () -> Bool
) async -> Bool {
    var matchingTurns = 0
    for _ in 0..<100 {
        // Always cross a native layout boundary, even if the synchronous frame already matches.
        await nativeLayoutTurn()
        if Task.isCancelled { return false }
        for panel in panels() {
            panel.layoutIfNeeded()
            panel.contentView?.layoutSubtreeIfNeeded()
        }
        matchingTurns = matches() ? matchingTurns + 1 : 0
        // Keep observing after the first match to catch a deferred minimum-size correction.
        if matchingTurns == 3 { return true }
    }
    return false
}

@MainActor private func nextPanelLayoutTurn() async {
    await withCheckedContinuation { continuation in
        let observer = CFRunLoopObserverCreateWithHandler(nil,
            CFRunLoopActivity.beforeWaiting.rawValue, false, CFIndex.max) { _, _ in
                continuation.resume()
            }!
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes) // real-time: AppKit must finish deferred window layout before sampling panel geometry
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }
}

@MainActor private func waitForOverlayPanelGeometry(
    _ overlay: TabbedOverlayController, state: TabbedLayoutState, bounds: BTRect
) async -> Bool {
    func views() -> [TabbedPaneView] {
        NSApp.windows.filter { overlay.windowNumbers.contains($0.windowNumber) }
            .compactMap { $0.contentView as? TabbedPaneView }
    }
    let frames = state.frames(in: bounds)
    return await waitForPanelGeometry(panels: { views().compactMap(\.window) }, matches: {
        let panes = views()
        guard panes.count == state.panes.count else { return false }
        return panes.allSatisfy { view in
            guard let panel = view.window, let pane = frames[view.pane.id] else { return false }
            let height = view.pane.tabs.isEmpty ? pane.size.height
                : view.collapsed ? TabbedStripPresentation.autoHide.reservedInset : state.presentation.barHeight
            let expected = CoordinateConverter.toAppKit(BTRect(x: pane.minX, y: pane.minY,
                width: pane.size.width, height: height), mainScreenFrame: NSScreen.screens.first?.frame ?? .zero)
            return panel.frame == expected && view.bounds.size == expected.size
                && view.content.bounds.size == expected.size
        }
    })
}

@Test(.macOSTestApplication, arguments: [false, true]) @MainActor
func panelGeometryWaitObservesDeferredChanges(invalidInitially: Bool) async {
    var nativeTurns = 0
    var height = invalidInitially ? 10 : 34
    let ready = await waitForPanelGeometry(panels: { [] }, nativeLayoutTurn: {
        nativeTurns += 1
        // A frame that is already correct can still change in deferred native layout.
        height = nativeTurns < 8 ? 10 : 34
    }, matches: { height == 34 })
    #expect(ready)
    #expect(nativeTurns >= 8, "Do not accept pre-deferral geometry or assume a fixed delay is enough")
}

@Test(.macOSTestApplication) @MainActor
func panelGeometryWaitRejectsUnsettledFrames() async {
    var nativeTurns = 0
    let ready = await waitForPanelGeometry(panels: { [] }, nativeLayoutTurn: {
        nativeTurns += 1
    }, matches: { false })
    #expect(!ready)
    #expect(nativeTurns > 0 && nativeTurns <= 100, "A persistent mismatch must exhaust a bounded observation budget")
}

@Test(.macOSTestApplication, .macOSUI, arguments: TabbedStripPresentation.allCases, [false, true]) @MainActor
func tabBarWindowDispatchHandlesNavigationAndUnhandledKeys(presentation: TabbedStripPresentation, empty: Bool) throws {
    _ = NSApplication.shared
    let ids = [WindowID(rawValue: "dispatch-a"), WindowID(rawValue: "dispatch-b")]
    var state = TabbedLayoutState(presentation: presentation)
    if !empty { state.reconcile(windowIDs: ids, removed: [], focused: ids[0]) }
    let overlay = TabbedOverlayController(addGlobalKeyMonitor: { _ in NSObject() },
        addLocalKeyMonitor: { _ in NSObject() }, removeMonitor: { _ in })
    defer { overlay.hide() }
    overlay.refresh(state: state, bounds: BTRect(x: 40000, y: 0, width: 800, height: 600), windows: [])
    let panel = try #require(NSApp.windows.first { overlay.windowNumbers.contains($0.windowNumber) && $0.contentView is TabbedPaneView })
    let view = try #require(panel.contentView as? TabbedPaneView)
    var selected: [WindowID] = []
    overlay.onIntent = { if case let .select(id) = $0 { selected.append(id) } }
    func key(_ code: UInt16, characters: String = "", repeatKey: Bool = false) throws {
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: panel.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: repeatKey, keyCode: code))
        panel.sendEvent(event)
    }
    func unhandledKeys() throws {
        try key(0, characters: "a")
        try key(0, characters: "a", repeatKey: true)
        try key(48, characters: "\t")
        try key(51, characters: "\u{7f}")
    }
    #expect(overlay.showTabBar())
    #expect(panel.firstResponder === view)
    // Use the real responder chain: direct calls to the key handler miss the forwarding loop.
    try unhandledKeys()
    #expect(selected.isEmpty)
    #expect(view.keyboardTab == (empty ? nil : ids[0]))
    try key(124)
    #expect(view.keyboardTab == (empty ? nil : ids[1]))
    try key(123)
    #expect(view.keyboardTab == (empty ? nil : ids[0]))
    try key(125)
    #expect(view.keyboardTab == (empty ? nil : ids[1]))
    try key(126)
    #expect(view.keyboardTab == (empty ? nil : ids[0]))
    try key(124)
    #expect(selected.isEmpty)
    try key(36, characters: "\r")
    #expect(selected == (empty ? [] : [ids[1]]))
    #expect(!panel.canBecomeKey)
    try unhandledKeys()
    #expect(overlay.showTabBar())
    try key(53, characters: "\u{1b}")
    #expect(selected == (empty ? [] : [ids[1], ids[0]]))
    #expect(!panel.canBecomeKey)
    try unhandledKeys()
    try key(53, characters: "\u{1b}")
    // Content can also start responder forwarding back through its parent pane.
    #expect(panel.makeFirstResponder(view.content))
    #expect(panel.firstResponder === view.content)
    try unhandledKeys()
    #expect(selected == (empty ? [] : [ids[1], ids[0]]))
    #expect(overlay.state == state)
    #expect(panel.isVisible)
}

@Test(.macOSTestApplication, .macOSUI, arguments: TabbedStripPresentation.allCases) @MainActor
func tabBarPresentationGeometryCurtainAndKeyboardRouting(_ presentation: TabbedStripPresentation) throws {
    _ = NSApplication.shared
    let ids = (0..<3).map { WindowID(rawValue: "bar-\($0)") }
    var state = TabbedLayoutState(preset: .rows, presentation: presentation)
    state.reconcile(windowIDs: ids, removed: [], focused: ids[0])
    state.move(ids[2], to: state.panes[1].id)
    state.select(ids[0])
    let bounds = BTRect(x: 12000, y: 0, width: 1000, height: 800)
    var curtain: TabbedCurtainView?
    var panels: [NSPanel] = []
    let overlay = TabbedOverlayController(panelFactory: {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panels.append(panel)
        return panel
    }, orderPanel: { panel, mode, _ in
        if mode == .below { curtain = panel.contentView as? TabbedCurtainView }
        panel.orderFrontForTesting()
    })
    defer { overlay.hide() }
    overlay.refresh(state: state, bounds: bounds, windows: [], selectedWindowNumbers: [ids[0]: 7, ids[2]: 8], curtainAnchorWindowNumber: 7)
    let views = panels.compactMap { $0.contentView as? TabbedPaneView }
    let view = try #require(views.first { $0.pane.id == state.activePaneID })
    let panel = try #require(view.window)
    #expect(abs(panel.frame.height - presentation.reservedInset) < 0.001)
    if presentation == .autoHide {
        #expect(view.collapsed)
        #expect((view.accessibilityChildren()?.first as? NSAccessibilityElement)?.isAccessibilityEnabled() == true)
        #expect(abs(panel.frame.minX - bounds.minX) < 0.001)
        #expect(abs(panel.frame.width - bounds.size.width) < 0.001)
        #expect(curtain?.excludedStrips.isEmpty == true)
        let lower = try #require(views.first { $0.pane.id != state.activePaneID }?.window)
        let lowerFrame = try #require(state.frames(in: bounds)[state.panes[1].id])
        let converted = CoordinateConverter.toAppKit(lowerFrame, mainScreenFrame: NSScreen.screens.first?.frame ?? .zero)
        #expect(abs(lower.frame.maxY - converted.maxY) < 0.001) // The band is inside its pane, below the gap.
        #expect(overlay.tabDropZone(at: BTPoint(x: bounds.minX + 2, y: 2), dragging: ids[2]) == nil)
        overlay.dividerIsDragging = { true }
        #expect(overlay.tabDropZone(at: BTPoint(x: bounds.minX + 200, y: 2), dragging: ids[2]) == nil)
        #expect(!overlay.showTabBar())
        overlay.dividerIsDragging = { false }
    } else {
        #expect(curtain?.excludedStrips.allSatisfy { abs($0.height - presentation.reservedInset) < 0.001 } == true)
    }
    var selected: [WindowID] = []
    overlay.onIntent = { if case let .select(id) = $0 { selected.append(id) } }
    #expect(overlay.showTabBar())
    #expect(!view.collapsed)
    #expect(panel.styleMask.contains(.nonactivatingPanel))
    #expect(abs(panel.frame.height - presentation.barHeight) < 0.001)
    view.layoutSubtreeIfNeeded()
    #expect(abs(view.stripLayout.tabFrame(0).height - presentation.barHeight) < 0.001)
    func key(_ code: UInt16) throws {
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                 windowNumber: panel.windowNumber, context: nil,
                                                 characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code))
        view.keyDown(with: event)
    }
    try key(124)
    #expect(selected.isEmpty)
    #expect(view.keyboardTab == ids[1])
    try key(36)
    #expect(selected == [ids[1]])
    #expect(overlay.state == state)
    #expect(overlay.showTabBar())
    try key(53)
    #expect(selected == [ids[1], ids[0]])
    #expect(view.collapsed == (presentation == .autoHide))
    #expect(abs(panel.frame.height - presentation.reservedInset) < 0.001)
}

@Test(.macOSTestApplication, .macOSUI) @MainActor func compactTabsKeepFullTitlesInAccessibilityAndMenus() throws {
    _ = NSApplication.shared
    let ids = [WindowID(rawValue: "first"), WindowID(rawValue: "second")]
    var pane = TabbedPane()
    pane.tabs = ids
    pane.selected = ids[0]
    let owner = TabbedOverlayController()
    defer { owner.hide() }
    var state = TabbedLayoutState(presentation: .compact)
    state.reconcile(windowIDs: ids, removed: [], focused: ids[0])
    let windows = ids.enumerated().map { index, id in
        WindowSnapshot(id: id, processIdentifier: 1, title: index == 0 ? "Selected full title" : "Hidden full title that must remain accessible",
                       frame: BTRect(x: 12000, y: 0, width: 600, height: 500), displayID: DisplayID(rawValue: "test"))
    }
    owner.refresh(state: state, bounds: BTRect(x: 12000, y: 0, width: 600, height: 500), windows: windows)
    let menu = owner.menu(pane: state.panes[0], windowID: nil)
    #expect(menu.items.contains { $0.title == windows[1].title })
    let view = TabbedPaneView(frame: NSRect(x: 0, y: 0, width: 600, height: 24))
    view.pane = pane
    view.presentation = .compact
    view.titles = ["Selected full title", "Hidden full title that must remain accessible"]
    view.layoutSubtreeIfNeeded()
    view.updateAccessibility()
    let labels = (view.accessibilityChildren()?.compactMap { $0 as? NSAccessibilityElement })?.compactMap { $0.accessibilityLabel() } ?? []
    #expect(labels.contains("Hidden full title that must remain accessible"))
    #expect(view.strip.tabFrame(1).width == 56)
    #expect(view.strip.tabFrame(0).width > view.strip.tabFrame(1).width)
    let panel = NSPanel(contentRect: NSRect(x: 12000, y: 0, width: 600, height: 24),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.contentView = view
    let point = NSPoint(x: view.strip.tabFrame(1).minX + 8, y: 12)
    let press = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
                                               windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    view.mouseDown(with: press)
    #expect(view.displayedSelection == ids[1])
    #expect(view.strip.tabFrame(0).width == 56)
    #expect(view.strip.tabFrame(1).width > 56)
    #expect(view.content.subviews.first?.subviews.first?.frame.width == 56)
    view.dropPressedSelection()
    #expect(view.strip.tabFrame(1).width == 56)
}

@Test(.macOSTestApplication, .macOSUI) @MainActor func autoHideReusesLocalEscapeMonitorWhenGlobalMonitoringIsUnavailable() throws {
    _ = NSApplication.shared
    let id = WindowID(rawValue: "monitor-failure")
    var state = TabbedLayoutState(presentation: .autoHide)
    state.reconcile(windowIDs: [id], removed: [], focused: id)
    var installs = 0
    var removals = 0
    let overlay = TabbedOverlayController(addGlobalKeyMonitor: { _ in nil }, addLocalKeyMonitor: { _ in
        installs += 1
        return NSObject()
    }, removeMonitor: { _ in removals += 1 })
    defer { overlay.hide() }
    let bounds = BTRect(x: 12000, y: 0, width: 800, height: 600)
    overlay.refresh(state: state, bounds: bounds, windows: [])
    #expect(overlay.showTabBar())
    #expect(overlay.showTabBar())
    #expect(installs == 1)
    state.setPresentation(.compact)
    overlay.refresh(state: state, bounds: bounds, windows: [])
    #expect(removals == 1)
    #expect(installs == 1)
}

@MainActor private final class PresentationFocus {
    weak var keyPanel: PresentationKeyPanel?
}

@MainActor private final class PresentationKeyPanel: NSPanel {
    var focus = PresentationFocus()
    override var canBecomeKey: Bool { true }
    override var isKeyWindow: Bool { focus.keyPanel === self }
    override func makeKey() {
        let previous = focus.keyPanel
        focus.keyPanel = self
        if let previous, previous !== self {
            NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: previous)
        }
    }
    override func orderOut(_ sender: Any?) {
        let wasKey = isKeyWindow
        if wasKey { focus.keyPanel = nil }
        withoutTestWindowAnimations(self) { super.orderOut(sender) }
        if wasKey { NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: self) }
    }
}


@MainActor private final class PresentationTiming {
    let manual = ManualClock()
    private lazy var origin = manual.now
    var now: TimeInterval {
        let elapsed = origin.duration(to: manual.now).components
        return Double(elapsed.seconds) + Double(elapsed.attoseconds) * 1e-18
    }
    func advance(_ overlay: TabbedOverlayController, by duration: Duration) {
        _ = now
        manual.advance(by: duration)
        overlay.advanceBarVisibility()
    }
}

@MainActor private func presentationOverlay(
    _ presentation: TabbedStripPresentation = .autoHide,
    primaryButtonIsPressed: @escaping () -> Bool = { false },
    focus: PresentationFocus = PresentationFocus(),
    addGlobalKeyMonitor: @escaping (@escaping @MainActor (UInt16) -> Void) -> Any? = { _ in NSObject() },
    removeMonitor: @escaping (Any) -> Void = { _ in }
) throws -> (TabbedOverlayController, TabbedLayoutState, TabbedPaneView, NSWindow, PresentationTiming) {
    _ = NSApplication.shared
    var state = TabbedLayoutState(presentation: presentation)
    let ids = [WindowID(rawValue: "presentation-a"), WindowID(rawValue: "presentation-b")]
    state.reconcile(windowIDs: ids, removed: [], focused: ids[0])
    let timing = PresentationTiming()
    let overlay = TabbedOverlayController(panelFactory: {
        let panel = PresentationKeyPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.focus = focus
        return panel
    }, addGlobalKeyMonitor: addGlobalKeyMonitor, addLocalKeyMonitor: { _ in NSObject() },
    removeMonitor: removeMonitor, primaryButtonIsPressed: primaryButtonIsPressed,
    visibilityClock: { timing.now }, timerClock: timing.manual.clock, automaticallyAdvanceVisibility: false)
    overlay.refresh(state: state, bounds: BTRect(x: 18000, y: 0, width: 800, height: 600), windows: [])
    let panel = try #require(NSApp.windows.first { overlay.windowNumbers.contains($0.windowNumber) && $0.contentView is TabbedPaneView })
    let view = try #require(panel.contentView as? TabbedPaneView)
    return (overlay, state, view, panel, timing)
}

@MainActor private func presentationEvent(_ window: NSWindow, type: NSEvent.EventType = .mouseMoved, point: NSPoint = .zero) throws -> NSEvent {
    try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                   context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
}

@Test(.macOSTestApplication, .macOSUI) @MainActor func autoHideRevealedBarSpansTheWindowWidth() async throws {
    let (overlay, _, view, panel, timing) = try presentationOverlay()
    defer { overlay.hide() }
    let paneLeft = 18000.0
    let top = panel.frame.maxY
    let event = try presentationEvent(panel)
    view.mouseEntered(with: event)
    timing.advance(overlay, by: .milliseconds(81))
    #expect(!view.collapsed)
    let trafficLightPoint = NSPoint(x: paneLeft + 20, y: top - 20)
    #expect(panel.frame.contains(trafficLightPoint))
    #expect(abs(panel.frame.minX - paneLeft) < 0.001)
    #expect(panel.frame.width == 800)
}



@Test(.macOSTestApplication, .macOSUI) @MainActor func autoHideLostSelectionReleaseDoesNotHoldBarForever() async throws {
    var held = true
    var removals = 0
    let (overlay, _, view, panel, timing) = try presentationOverlay(primaryButtonIsPressed: { held }, removeMonitor: { _ in removals += 1 })
    defer { overlay.hide() }
    let event = try presentationEvent(panel)
    view.mouseEntered(with: event)
    timing.advance(overlay, by: .milliseconds(81))
    #expect(!view.collapsed)
    let tab = view.strip.tabFrame(0)
    let point = view.convert(NSPoint(x: tab.minX + 10, y: 12), to: nil)
    view.mouseDown(with: try presentationEvent(panel, type: .leftMouseDown, point: point))
    view.mouseExited(with: event)
    timing.advance(overlay, by: .milliseconds(650))
    #expect(!view.collapsed) // A real held button must keep its selection hold.
    held = false // Mouse-up is lost; only the physical button state changes.
    timing.advance(overlay, by: .milliseconds(50))
    timing.advance(overlay, by: .milliseconds(301))
    #expect(view.collapsed)
    #expect(removals == 2)
}





@Test(.macOSTestApplication, .macOSUI) @MainActor func autoHideRevealedTabsMeasureFullUnselectedTitles() {
    let ids = [WindowID(rawValue: "title-a"), WindowID(rawValue: "title-b")]
    let view = TabbedPaneView(frame: NSRect(x: 0, y: 0, width: 800, height: 34))
    view.pane.tabs = ids
    view.pane.selected = ids[0]
    view.titles = ["Selected document", "An unselected document with a full title"]
    view.layoutSubtreeIfNeeded()
    let fullTitleFrame = view.strip.tabFrame(1)
    view.presentation = .autoHide
    view.layoutSubtreeIfNeeded()
    #expect(view.strip.tabFrame(1) == fullTitleFrame)
    view.presentation = .compact
    #expect(view.strip.tabFrame(1).width == 56)
}

@Test(.macOSTestApplication, .macOSUI) @MainActor func autoHideDropInsertionUsesTheFullWidthPanelOrigin() throws {
    let (overlay, state, view, _, _) = try presentationOverlay()
    defer { overlay.hide() }
    #expect(overlay.showTabBar())
    view.layoutSubtreeIfNeeded()
    let origin = 18000.0
    let dragged = WindowID(rawValue: "external")
    for index in 0...view.pane.tabs.count {
        let edge = index == view.pane.tabs.count ? view.strip.tabFrame(index - 1).maxX : view.strip.tabFrame(index).minX
        let zone = try #require(overlay.tabDropZone(at: BTPoint(x: origin + edge, y: 17), dragging: dragged))
        #expect(zone.paneID == state.activePaneID)
        #expect(zone.index == index)
        #expect(zone.indicator?.minX == origin + edge - 3)
    }
    #expect(overlay.tabDropZone(at: BTPoint(x: 18002, y: 2), dragging: dragged) == nil)
    #expect(overlay.tabDropZone(at: BTPoint(x: 18797, y: 17), dragging: dragged) == nil)
}

@Test(.macOSTestApplication, .macOSUI) @MainActor func autoHideTabDragUsesTheFullWidthPanelOrigin() throws {
    let (overlay, state, view, panel, _) = try presentationOverlay()
    defer { overlay.hide() }
    #expect(overlay.showTabBar())
    view.layoutSubtreeIfNeeded()
    var movedIndex: Int?
    overlay.onIntent = { if case let .move(_, _, index, _) = $0 { movedIndex = index } }
    let second = view.strip.tabFrame(1)
    let press = view.convert(NSPoint(x: second.minX + 10, y: 12), to: nil)
    view.mouseDown(with: try presentationEvent(panel, type: .leftMouseDown, point: press))
    // Just before the first tab's midpoint still inserts before that tab.
    let x = 18000 + view.strip.tabFrame(0).midX - 5
    let global = CoordinateConverter.toAppKit(BTRect(x: x, y: 17, width: 0, height: 0),
                                              mainScreenFrame: NSScreen.screens.first?.frame ?? .zero).origin
    let release = NSPoint(x: global.x - panel.frame.minX, y: global.y - panel.frame.minY)
    view.mouseDragged(with: try presentationEvent(panel, type: .leftMouseDragged, point: release))
    view.mouseUp(with: try presentationEvent(panel, type: .leftMouseUp, point: release))
    #expect(movedIndex == 0)
    #expect(overlay.state == state)
}

@Test(.macOSTestApplication, .macOSUI) @MainActor func autoHideSelectionWatchdogStopsAfterDismissalAndHide() async throws {
    var reads = 0
    var escape: (@MainActor (UInt16) -> Void)?
    let (overlay, _, view, panel, timing) = try presentationOverlay(primaryButtonIsPressed: { reads += 1; return true },
        addGlobalKeyMonitor: { escape = $0; return NSObject() })
    defer { overlay.hide() }
    #expect(overlay.showTabBar())
    let point = view.convert(NSPoint(x: view.strip.tabFrame(0).minX + 10, y: 12), to: nil)
    view.mouseDown(with: try presentationEvent(panel, type: .leftMouseDown, point: point))
    timing.advance(overlay, by: .milliseconds(50))
    #expect(reads > 0)
    escape?(53)
    let afterDismissal = reads
    timing.advance(overlay, by: .milliseconds(120))
    #expect(view.collapsed)
    #expect(reads == afterDismissal)
    #expect(overlay.showTabBar())
    view.mouseDown(with: try presentationEvent(panel, type: .leftMouseDown, point: point))
    overlay.hide()
    let afterHide = reads
    timing.advance(overlay, by: .milliseconds(120))
    #expect(reads == afterHide)
    #expect(!panel.isVisible)
}






@Suite(.macOSTestApplication, .serialized) @MainActor struct TabbedProductionPanelTests {


    @Test(.macOSUI, .timeLimit(.minutes(5)), arguments: TabbedStripPresentation.allCases, [false, true])
    func resizedContentKeepsDragHitTesting(presentation: TabbedStripPresentation, anchored: Bool) async throws {
        _ = NSApplication.shared
        for dropY in [17.0, 300.0] {
            let anchor = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            anchor.orderFrontForTesting()
            defer { anchor.orderOutForTesting() }
            let id = WindowID(rawValue: "sized-drag")
            var state = TabbedLayoutState(preset: .columns, presentation: presentation)
            state.reconcile(windowIDs: [id], removed: [], focused: id)
            let overlay = TabbedOverlayController(dragTicks: ResizeDisplayLink(automatic: false),
                addGlobalKeyMonitor: { _ in NSObject() }, addLocalKeyMonitor: { _ in NSObject() },
                removeMonitor: { _ in }, primaryButtonIsPressed: { true })
            defer { overlay.hide() }
            var bounds = BTRect(x: 32000, y: 0, width: 1600, height: 800)
            func refresh() {
                overlay.refresh(state: state, bounds: bounds, windows: [], selectedWindowNumbers: anchored ? [id: anchor.windowNumber] : [:])
            }
            refresh()
            try #require(await waitForOverlayPanelGeometry(overlay, state: state, bounds: bounds))
            bounds.size.width = 1400
            refresh()
            #expect(overlay.showTabBar())
            try #require(await waitForOverlayPanelGeometry(overlay, state: state, bounds: bounds))
            let views = NSApp.windows.filter { overlay.windowNumbers.contains($0.windowNumber) }
                .compactMap { $0.contentView as? TabbedPaneView }
            for view in views {
                #expect(view.bounds.size == view.window?.frame.size)
                #expect(view.content.bounds.size == view.bounds.size)
            }
            let view = try #require(views.first { $0.pane.id == state.activePaneID })
            let panel = try #require(view.window)
            let tabPoint = NSPoint(x: view.strip.tabFrame(0).minX + 10, y: 12)
            let hit = try #require(view.hitTest(tabPoint))
            #expect(hit === view.content || hit.isDescendant(of: view.content))
            let press = view.convert(tabPoint, to: nil)
            hit.mouseDown(with: try presentationEvent(panel, type: .leftMouseDown, point: press))
            let target = try #require(state.frames(in: bounds)[state.panes[1].id])
            let screen = CoordinateConverter.toAppKit(BTRect(x: target.midX, y: dropY, width: 0, height: 0),
                mainScreenFrame: NSScreen.screens.first?.frame ?? .zero).origin
            let point = panel.convertPoint(fromScreen: screen)
            var indexes: [Int?] = []
            overlay.onIntent = { if case let .move(_, _, index, _) = $0 { indexes.append(index) } }
            hit.mouseDragged(with: try presentationEvent(panel, type: .leftMouseDragged, point: point))
            hit.mouseUp(with: try presentationEvent(panel, type: .leftMouseUp, point: point))
            #expect(indexes.count == 1)
            if let first = indexes.first { #expect(first == (dropY < presentation.barHeight ? 0 : nil)) }
            #expect(overlay.isDropPending == (dropY < presentation.barHeight))
        }
    }

    // These tests inspect key state or share a real-key fixture; run only while the Mac is unattended.
    // Add only reviewed real-key or activation cases; keep all other tests in default suites and update NativeLaneMembership.
    @Suite(.enabled(if: NativeFocusTestLane.isEnabled, "Requires an unattended Mac; set BETTERTILE_NATIVE_FOCUS_TESTS=1"), .nativeFocus)
    @MainActor struct NativeFocus {
        @Test(.macOSUI, arguments: [false, true], [TabbedPreset.single, .rows])
        func autoHideBandSurvivesDeferredLayout(anchored: Bool, preset: TabbedPreset) async throws {
            _ = NSApplication.shared
            let bounds = BTRect(x: 30000, y: 0, width: 1200, height: 800)
            let anchor = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            anchor.orderFrontForTesting()
            defer { anchor.orderOutForTesting() }
            let ids = [WindowID(rawValue: "deferred-a"), WindowID(rawValue: "deferred-b")]
            var state = TabbedLayoutState(preset: preset, presentation: .autoHide)
            state.reconcile(windowIDs: ids, removed: [], focused: ids[0])
            if preset == .rows { state.move(ids[1], to: state.panes[1].id) }
            // Use the production panel and AppKit ordering; only event monitors are fakes.
            let timing = PresentationTiming()
            let overlay = TabbedOverlayController(addGlobalKeyMonitor: { _ in NSObject() },
                addLocalKeyMonitor: { _ in NSObject() }, removeMonitor: { _ in },
                visibilityClock: { timing.now }, timerClock: timing.manual.clock, automaticallyAdvanceVisibility: false)
            defer { overlay.hide() }
            func refresh() {
                overlay.refresh(state: state, bounds: bounds, windows: [],
                    selectedWindowNumbers: anchored ? Dictionary(uniqueKeysWithValues: ids.map { ($0, anchor.windowNumber) }) : [:])
            }
            func paneView(_ id: UUID) throws -> TabbedPaneView {
                try #require(NSApp.windows.filter { overlay.windowNumbers.contains($0.windowNumber) }
                    .compactMap { $0.contentView as? TabbedPaneView }.first { $0.pane.id == id })
            }
            func checkBands() throws {
                for pane in state.panes {
                    let view = try paneView(pane.id)
                    let panel = try #require(view.window)
                    let frame = try #require(state.frames(in: bounds)[pane.id])
                    let band = CoordinateConverter.toAppKit(BTRect(x: frame.minX, y: frame.minY,
                        width: frame.size.width, height: 6), mainScreenFrame: NSScreen.screens.first?.frame ?? .zero)
                    #expect(view.collapsed && panel.isVisible)
                    #expect(panel.frame == band)
                    #expect(view.bounds.size == band.size)
                    #expect(view.content.bounds.size == band.size)
                    #expect(panel.level == (anchored ? .normal : .floating))
                }
            }
            refresh()
            // A synchronous frame assertion misses AppKit's deferred 10-point minimum.
            try #require(await waitForOverlayPanelGeometry(overlay, state: state, bounds: bounds))
            try checkBands()
            let view = try paneView(state.activePaneID)
            let panel = try #require(view.window)
            let escape = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: panel.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 53))
            for _ in 0..<20 {
                #expect(overlay.showTabBar())
                // Native key ownership is shared across AppKit tests; check eligibility here.
                #expect(panel.canBecomeKey)
                try #require(await waitForOverlayPanelGeometry(overlay, state: state, bounds: bounds))
                #expect(panel.frame.height == 34 && view.bounds.size == panel.frame.size)
                view.keyDown(with: escape)
                #expect(!panel.canBecomeKey)
                try #require(await waitForOverlayPanelGeometry(overlay, state: state, bounds: bounds))
                try checkBands()
            }
            view.mouseEntered(with: try presentationEvent(panel))
            timing.advance(overlay, by: .milliseconds(81))
            #expect(!view.collapsed)
            try #require(await waitForOverlayPanelGeometry(overlay, state: state, bounds: bounds))
            #expect(panel.frame.height == 34 && view.content.bounds.size == panel.frame.size)
            view.mouseExited(with: try presentationEvent(panel))
            timing.advance(overlay, by: .milliseconds(301))
            timing.advance(overlay, by: .milliseconds(121))
            #expect(view.collapsed && view.autoHideAnimationDeadline == nil)
            try #require(await waitForOverlayPanelGeometry(overlay, state: state, bounds: bounds))
            try checkBands()
            #expect(overlay.showTabBar())
            overlay.hide()
            timing.advance(overlay, by: .milliseconds(500))
            #expect(!panel.isVisible && !panel.isKeyWindow, Comment(rawValue: keyWindowDiagnostics(panel)))
            refresh()
            try #require(await waitForOverlayPanelGeometry(overlay, state: state, bounds: bounds))
            try checkBands()
        }
    }
}

// These tests inspect key state or share a real-key fixture; run only while the Mac is unattended.
// Add only reviewed real-key or activation cases; keep all other tests in default suites and update NativeLaneMembership.
@Suite(.enabled(if: NativeFocusTestLane.isEnabled, "Requires an unattended Mac; set BETTERTILE_NATIVE_FOCUS_TESTS=1"), .nativeFocus)
@MainActor struct NativeFocusTabbedPresentationOverlayTests {
    @Test(.macOSTestApplication, .macOSUI) @MainActor func tabBarKeyFocusEndsAfterEscapeAndPresentationSwitch() throws {
        let (overlay, state, view, panel, _) = try presentationOverlay(.compact)
        defer { overlay.hide() }
        #expect(overlay.showTabBar())
        let escape = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: panel.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 53))
        view.keyDown(with: escape)
        #expect(!panel.isKeyWindow, Comment(rawValue: keyWindowDiagnostics(panel)))
        #expect(overlay.showTabBar())
        var changed = state
        changed.setPresentation(.autoHide)
        overlay.refresh(state: changed, bounds: BTRect(x: 18000, y: 0, width: 800, height: 600), windows: [])
        #expect(!panel.isKeyWindow, Comment(rawValue: keyWindowDiagnostics(panel)))
    }

    @Test(.macOSTestApplication, .macOSUI, arguments: [false, true]) @MainActor
    func autoHideFallbackOcclusionStillAppliesAfterReveal(keyboard: Bool) async throws {
        let (overlay, state, view, panel, timing) = try presentationOverlay()
        defer { overlay.hide() }
        // A focused floating window starts below the 6-point band, over the
        // title-bar area that the expanded strip would occupy.
        overlay.refresh(state: state, bounds: BTRect(x: 18000, y: 0, width: 800, height: 600), windows: [],
                        obscuringFrames: [BTRect(x: 18050, y: 10, width: 500, height: 300)])
        #expect(panel.isVisible)
        if keyboard {
            #expect(!overlay.showTabBar())
            #expect(!panel.isKeyWindow, Comment(rawValue: keyWindowDiagnostics(panel)))
        } else {
            view.mouseEntered(with: try presentationEvent(panel))
        }
        timing.advance(overlay, by: .milliseconds(81))
        #expect(!panel.isVisible)
        view.mouseExited(with: try presentationEvent(panel))
        timing.advance(overlay, by: .milliseconds(301))
        timing.advance(overlay, by: .milliseconds(121))
        #expect(view.collapsed && view.autoHideAnimationDeadline == nil)
        #expect(panel.isVisible)
    }

    @Test(.macOSTestApplication, .macOSUI) @MainActor func autoHideHoverCollapseAndHideCleanup() async throws {
        let (overlay, state, view, panel, timing) = try presentationOverlay()
        defer { overlay.hide() }
        let event = try presentationEvent(panel)
        view.mouseEntered(with: event)
        timing.advance(overlay, by: .milliseconds(81))
        #expect(!view.collapsed)
        view.mouseExited(with: event)
        timing.advance(overlay, by: .milliseconds(301))
        #expect(view.collapsed)
        #expect(overlay.showTabBar())
        overlay.hide()
        #expect(!panel.isKeyWindow, Comment(rawValue: keyWindowDiagnostics(panel)))
        timing.advance(overlay, by: .milliseconds(600))
        #expect(!panel.isVisible)
        overlay.refresh(state: state, bounds: BTRect(x: 18000, y: 0, width: 800, height: 600), windows: [])
        #expect(view.collapsed)
    }

    @Test(.macOSTestApplication, .macOSUI) @MainActor func autoHideKeyLossPreservesTheNewKeyWindow() async throws {
        let focus = PresentationFocus()
        let (overlay, _, view, panel, timing) = try presentationOverlay(focus: focus)
        let other = PresentationKeyPanel(contentRect: NSRect(x: 20000, y: 0, width: 300, height: 200), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        other.focus = focus
        defer { overlay.hide(); other.orderOutForTesting() }
        other.orderFrontForTesting()
        other.makeKey()
        try #require(other.isKeyWindow, Comment(rawValue: keyWindowDiagnostics(other)))
        #expect(overlay.showTabBar())
        #expect(panel.isKeyWindow, Comment(rawValue: keyWindowDiagnostics(panel)))
        other.orderFrontForTesting()
        other.makeKey()
        #expect(!panel.isKeyWindow, Comment(rawValue: keyWindowDiagnostics(panel)))
        #expect(other.isKeyWindow, Comment(rawValue: keyWindowDiagnostics(other)))
        #expect(focus.keyPanel === other)
        timing.advance(overlay, by: .milliseconds(301))
        #expect(view.collapsed)
    }

    @Test(.macOSTestApplication, .macOSUI) @MainActor func tabBarKeyFocusRestoresItsValidatedStackAnchor() throws {
        _ = NSApplication.shared
        var state = TabbedLayoutState(presentation: .compact)
        let id = WindowID(rawValue: "key-anchor")
        state.reconcile(windowIDs: [id], removed: [], focused: id)
        var anchors: [Int] = []
        let overlay = TabbedOverlayController(panelFactory: {
            PresentationKeyPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        }, orderPanel: { panel, mode, anchor in
            #expect(mode == .above)
            anchors.append(anchor)
            panel.orderFrontForTesting()
        })
        defer { overlay.hide() }
        overlay.refresh(state: state, bounds: BTRect(x: 18000, y: 0, width: 800, height: 600), windows: [],
                        selectedWindowNumbers: [id: 777])
        let panel = try #require(NSApp.windows.first { overlay.windowNumbers.contains($0.windowNumber) && $0.contentView is TabbedPaneView })
        let view = try #require(panel.contentView as? TabbedPaneView)
        #expect(overlay.showTabBar())
        #expect(panel.isKeyWindow, Comment(rawValue: keyWindowDiagnostics(panel)))
        let escape = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: panel.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 53))
        view.keyDown(with: escape)
        #expect(panel.isVisible)
        #expect(!panel.isKeyWindow, Comment(rawValue: keyWindowDiagnostics(panel)))
        #expect(anchors == [777, 777])
    }

    @Test(.macOSTestApplication, .macOSUI, arguments: [false, true]) @MainActor
    func autoHideEscapeRestoresSixPointInputFrame(anchored: Bool) async throws {
        _ = NSApplication.shared
        let bounds = BTRect(x: 24000, y: 0, width: 800, height: 600)
        let underlying = NSPanel(contentRect: NSRect(x: 24000, y: 0, width: 800, height: 600),
                                 styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        underlying.orderFrontForTesting()
        defer { underlying.orderOutForTesting() }
        let id = WindowID(rawValue: "escape-geometry")
        var state = TabbedLayoutState(presentation: .autoHide)
        state.reconcile(windowIDs: [id], removed: [], focused: id)
        var anchors: [Int] = []
        // Isolate key focus from other tests, but keep AppKit's real frame and ordering behavior.
        let overlay = TabbedOverlayController(panelFactory: {
            PresentationKeyPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        }, addGlobalKeyMonitor: { _ in NSObject() },
            addLocalKeyMonitor: { _ in NSObject() }, removeMonitor: { _ in },
            orderPanel: { panel, mode, anchor in
                anchors.append(anchor)
                panel.order(mode, relativeTo: anchor)
            })
        defer { overlay.hide() }
        overlay.refresh(state: state, bounds: bounds, windows: [],
                        selectedWindowNumbers: anchored ? [id: underlying.windowNumber] : [:])
        let panel = try #require(NSApp.windows.first { overlay.windowNumbers.contains($0.windowNumber) && $0.contentView is TabbedPaneView })
        let view = try #require(panel.contentView as? TabbedPaneView)
        let collapsedFrame = panel.frame
        #expect(abs(collapsedFrame.height - 6) < 0.001)
        let escape = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: panel.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 53))
        for _ in 0..<20 {
            #expect(overlay.showTabBar())
            #expect(panel.isKeyWindow, Comment(rawValue: keyWindowDiagnostics(panel)))
            #expect(abs(panel.frame.height - 34) < 0.001)
            view.keyDown(with: escape)
            #expect(panel.isVisible && !panel.isKeyWindow && view.collapsed, Comment(rawValue: keyWindowDiagnostics(panel)))
            try #require(await waitForOverlayPanelGeometry(overlay, state: state, bounds: bounds))
            #expect(panel.frame == collapsedFrame)
            #expect(view.bounds.size == collapsedFrame.size)
            #expect(panel.level == (anchored ? .normal : .floating))
            if anchored { #expect(anchors.last == underlying.windowNumber) }
        }
    }
}

@Test(.macOSTestApplication, .macOSUI, .timeLimit(.minutes(5)), arguments: [false, true]) @MainActor
func autoHideScheduledRevealUsesManualClockAndCancelsOnHide(cancelled: Bool) async throws {
    let timing = PresentationTiming()
    let focus = PresentationFocus()
    let overlay = TabbedOverlayController(panelFactory: {
        let panel = PresentationKeyPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.focus = focus
        return panel
    }, addGlobalKeyMonitor: { _ in NSObject() }, addLocalKeyMonitor: { _ in NSObject() }, removeMonitor: { _ in },
    visibilityClock: { timing.now }, timerClock: timing.manual.clock)
    defer { overlay.hide() }
    var state = TabbedLayoutState(presentation: .autoHide)
    let id = WindowID(rawValue: "scheduled-reveal")
    state.reconcile(windowIDs: [id], removed: [], focused: id)
    overlay.refresh(state: state, bounds: BTRect(x: 18000, y: 0, width: 800, height: 600), windows: [])
    let panel = try #require(NSApp.windows.first { overlay.windowNumbers.contains($0.windowNumber) && $0.contentView is TabbedPaneView })
    let view = try #require(panel.contentView as? TabbedPaneView)
    view.mouseEntered(with: try presentationEvent(panel))
    let reveal = try #require(overlay.visibilityTask)
    await timing.manual.waitForSleepers(count: 1)
    timing.manual.advance(by: .milliseconds(79))
    #expect(view.collapsed)
    if cancelled { overlay.hide() }
    timing.manual.advance(by: .milliseconds(1))
    await reveal.value
    #expect(view.collapsed == cancelled)
    #expect(panel.isVisible == !cancelled)
}
