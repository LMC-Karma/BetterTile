import AppKit
import BetterTileCore
import Testing
@testable import BetterTileMacOS

@MainActor private final class DragTestPanel: NSPanel {
    var frameWrites = 0
    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        frameWrites += 1
        super.setFrame(frameRect, display: flag)
    }
}

@MainActor private final class TabDragFixture {
    let bounds: BTRect
    let ticks = ResizeDisplayLink(automatic: false)
    let ids: [WindowID]
    var state = TabbedLayoutState(preset: .columns)
    let overlay: TabbedOverlayController
    let view: TabbedPaneView

    init(count: Int = 3,
         bounds: BTRect = BTRect(x: 12000, y: 0, width: 1600, height: 800),
         appearance: NSAppearance? = nil) throws {
        _ = NSApplication.shared
        self.bounds = bounds
        ids = (0..<count).map { WindowID(rawValue: "drag-check-\($0)") }
        state.reconcile(windowIDs: ids, removed: [], focused: ids[0])
        var made: [DragTestPanel] = []
        overlay = TabbedOverlayController(dragTicks: ticks, panelFactory: {
            let panel = DragTestPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                      backing: .buffered, defer: false)
            panel.appearance = appearance
            made.append(panel)
            return panel
        })
        let windows = ids.enumerated().map { index, id in
            WindowSnapshot(id: id, processIdentifier: 1, title: "Document \(index + 1)", frame: bounds,
                           displayID: DisplayID(rawValue: "drag-check"))
        }
        overlay.refresh(state: state, bounds: bounds, windows: windows)
        let sourcePaneID = state.panes[0].id
        view = try #require(made.compactMap(\.contentView).compactMap { $0 as? TabbedPaneView }
            .first { $0.pane.id == sourcePaneID })
        view.content.reduceMotion = { true }
        view.layoutSubtreeIfNeeded()
        // Retain the factory's growing collection through a closure.
        createdPanels = { made }
    }

    var createdPanels: () -> [DragTestPanel] = { [] }
    var proxy: DragTestPanel? { createdPanels().first { $0.hasShadow } }
    var highlight: DragTestPanel? {
        createdPanels().first { panel in
            panel.contentView?.subviews.compactMap { $0 as? NSTextField }
                .contains { $0.stringValue.hasPrefix("Move to Pane") || $0.stringValue.hasPrefix("Split") } == true
        }
    }

    func event(_ type: NSEvent.EventType, x: Double, y: Double = 17) throws -> NSEvent {
        let panel = try #require(view.window)
        let screen = NSPoint(x: x, y: NSScreen.screens.first!.frame.maxY - y)
        return try #require(NSEvent.mouseEvent(with: type, location: panel.convertPoint(fromScreen: screen),
                                              modifierFlags: [], timestamp: 0, windowNumber: panel.windowNumber,
                                              context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }

    func start() throws {
        view.mouseDown(with: try event(.leftMouseDown, x: bounds.minX + 80, y: bounds.minY + 17))
    }
    func drag(x: Double, y: Double = 17) throws {
        view.mouseDragged(with: try event(.leftMouseDragged, x: x, y: y))
    }
    func release(x: Double, y: Double = 17) throws {
        view.mouseUp(with: try event(.leftMouseUp, x: x, y: y))
    }
}

@Test @MainActor func tabDragConsumesOnlyTheLatestPointPerTickAndReleasesExactly() throws {
    let f = try TabDragFixture()
    defer { f.overlay.hide() }
    var moves: [(UUID, Int?)] = []
    f.overlay.onIntent = { if case let .move(_, pane, index) = $0 { moves.append((pane, index)) } }
    try f.start()
    try f.drag(x: 12300)
    try f.drag(x: 12650)
    #expect(f.view.content.previewOrder == nil)
    #expect(f.proxy?.isVisible == false)
    f.ticks.fire()
    #expect(f.view.content.previewOrder == [f.ids[1], f.ids[2], f.ids[0]])
    let proxy = try #require(f.proxy)
    #expect(proxy.frame.minX == 12602) // Preserve the press offset within the tab.
    let frames = proxy.frameWrites
    f.ticks.fire()
    #expect(proxy.frameWrites == frames)
    try f.drag(x: 12080)
    // Release bypasses the pending sample and has no intervening display tick.
    try f.release(x: 13200, y: 400)
    #expect(moves.count == 1)
    #expect(moves.first?.0 == f.state.panes[1].id)
    #expect(moves.first?.1 == nil)
    #expect(!f.overlay.isInteracting)
    f.ticks.fire()
    #expect(moves.count == 1)
}

@Test @MainActor func unchangedTabDragDoesNotRedrawTabsOrResetTheHighlightFrame() throws {
    let f = try TabDragFixture()
    defer { f.overlay.hide() }
    try f.start()
    try f.drag(x: 12400, y: 400)
    f.ticks.fire()
    let highlight = try #require(f.highlight)
    highlight.frameWrites = 0
    f.view.layoutSubtreeIfNeeded()
    f.view.display()
    let tabViews = f.view.content.subviews.flatMap(\.subviews)
    tabViews.forEach { $0.needsDisplay = false }
    #expect(!tabViews.isEmpty && tabViews.allSatisfy { !$0.needsDisplay })
    try f.drag(x: 12400, y: 400)
    #expect(tabViews.allSatisfy { !$0.needsDisplay })
    f.ticks.fire()
    #expect(tabViews.allSatisfy { !$0.needsDisplay })
    #expect(highlight.frameWrites == 0)
    try f.drag(x: 12420, y: 400) // Same content target, different proxy position.
    f.ticks.fire()
    #expect(highlight.frameWrites == 0)
    #expect(highlight.isVisible)
}

@Test(arguments: [false, true]) @MainActor
func endingTabDragDiscardsQueuedSamplesAndCannotReviveThePreview(hide: Bool) throws {
    let f = try TabDragFixture()
    defer { f.overlay.hide() }
    var intents = 0
    f.overlay.onIntent = { _ in intents += 1 }
    try f.start()
    try f.drag(x: 12650)
    f.ticks.fire()
    let proxy = try #require(f.proxy)
    try f.drag(x: 13200, y: 400)
    if hide { f.overlay.hide() } else { f.overlay.cancelInteraction() }
    f.ticks.fire()
    try f.release(x: 13200, y: 400)
    f.ticks.fire()
    #expect(intents == 0)
    #expect(!f.overlay.isInteracting)
    #expect(f.view.content.previewOrder == nil)
    #expect(!proxy.isVisible)
    f.overlay.refresh(state: f.state, bounds: f.bounds, windows: [])
    try f.start()
    try f.drag(x: 12400)
    f.ticks.fire()
    #expect(f.view.content.previewOrder == [f.ids[1], f.ids[0], f.ids[2]])
}

@Test(arguments: [false, true]) @MainActor
func tabDragDefersAccessibilityUntilDropCompletes(success: Bool) throws {
    let f = try TabDragFixture()
    defer { f.overlay.hide() }
    f.overlay.onIntent = { _ in }
    let original = try #require(f.view.accessibilityChildren() as? [NSAccessibilityElement])
    try f.start()
    try f.drag(x: 12650)
    f.ticks.fire()
    let during = try #require(f.view.accessibilityChildren() as? [NSAccessibilityElement])
    #expect(original.count == during.count && zip(original, during).allSatisfy { $0 === $1 })
    try f.release(x: 12650)
    #expect(f.overlay.isDropPending)
    if success {
        f.state.move(f.ids[0], to: f.state.panes[0].id, at: 2)
        f.overlay.refresh(state: f.state, bounds: f.bounds, windows: [])
    }
    f.overlay.completeDrop()
    #expect(f.view.content.previewOrder == nil)
    let after = try #require(f.view.accessibilityChildren() as? [NSAccessibilityElement])
    #expect(after.count == original.count)
    #expect(after.first !== original.first)
    #expect(f.view.pane.tabs == (success ? [f.ids[1], f.ids[2], f.ids[0]] : f.ids))
}

@Test @MainActor func tabDragTickScrollsAHeldEdgeAndCancellationRestoresTheStrip() throws {
    let f = try TabDragFixture(count: 16)
    defer { f.overlay.hide() }
    let original = f.view.strip.visibleRange
    try f.start()
    try f.drag(x: 12750)
    f.ticks.fire()
    let beforeScroll = f.view.strip.visibleRange
    f.ticks.fire() // No new mouse event is needed to scroll a held edge.
    #expect(f.view.strip.visibleRange.lowerBound > beforeScroll.lowerBound)
    f.overlay.cancelInteraction()
    #expect(f.view.strip.visibleRange == original)
}

/// Native materials require the compositor. Host the already-laid-out
/// production views together so glass samples only this synthetic backdrop.
@Test(.enabled(if: ProcessInfo.processInfo.environment["BETTERTILE_NATIVE_GLASS_PREVIEW_DIR"] != nil,
               "Requires an explicit native glass preview output directory."))
@MainActor func nativeTabDragPreviews() async throws {
    _ = NSApplication.shared
    let directory = try #require(ProcessInfo.processInfo.environment["BETTERTILE_NATIVE_GLASS_PREVIEW_DIR"])
    let screen = try #require(NSScreen.screens.first)
    let frame = NSRect(x: 80, y: 100, width: 1120, height: 720)
    let bounds = CoordinateConverter.toTopLeft(frame, mainScreenFrame: screen.frame)
    let backdrop = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    backdrop.isReleasedWhenClosed = false
    defer { backdrop.close() }
    let root = NSView(frame: NSRect(origin: .zero, size: frame.size))
    root.wantsLayer = true
    let gradient = CAGradientLayer()
    gradient.frame = root.bounds
    gradient.colors = [NSColor.systemBlue.cgColor, NSColor.systemPurple.cgColor, NSColor.systemOrange.cgColor]
    gradient.startPoint = .zero
    gradient.endPoint = CGPoint(x: 1, y: 1)
    root.layer?.addSublayer(gradient)
    for y in stride(from: 70, to: 650, by: 70) {
        let label = NSTextField(labelWithString: "SYNTHETIC DOCUMENT CONTENT · TAB DRAG PREVIEW")
        label.font = .monospacedSystemFont(ofSize: 22, weight: .bold)
        label.textColor = .white
        label.frame = NSRect(x: 30, y: y, width: 1000, height: 30)
        root.addSubview(label)
    }
    backdrop.contentView = root
    for (mode, appearanceName) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
        let appearance = try #require(NSAppearance(named: appearanceName))
        backdrop.appearance = appearance
        backdrop.orderFrontRegardless()
        for (name, point) in [
            ("reorder", BTPoint(x: bounds.minX + 420, y: bounds.minY + 17)),
            ("empty-strip", BTPoint(x: bounds.minX + 850, y: bounds.minY + 17)),
            ("split", BTPoint(x: bounds.minX + 570, y: bounds.minY + 250)),
        ] {
            let f = try TabDragFixture(count: 16, bounds: bounds, appearance: appearance)
            defer { f.overlay.hide() }
            try f.start()
            try f.drag(x: point.x, y: point.y)
            f.ticks.fire()
            #expect(f.proxy?.isVisible == true)
            // Single-window captures cannot reproduce glass sampling across
            // windows. Reparent these exact production views for the preview.
            let panels = f.createdPanels().filter { $0.isVisible && $0 !== f.proxy && $0 !== f.highlight }
                + [f.highlight, f.proxy].compactMap { $0 }.filter(\.isVisible)
            var views: [NSView] = []
            for panel in panels {
                let view = try #require(panel.contentView)
                let rect = panel.frame.offsetBy(dx: -frame.minX, dy: -frame.minY)
                panel.contentView = nil
                panel.orderOut(nil)
                view.frame = rect
                root.addSubview(view)
                views.append(view)
            }
            defer { views.forEach { $0.removeFromSuperview() } }
            root.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(250))
            let capture = Process()
            capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            capture.arguments = ["-x", "-o", "-l", String(backdrop.windowNumber),
                                 "\(directory)/tab-drag-\(mode)-\(name).png"]
            try capture.run()
            capture.waitUntilExit()
            #expect(capture.terminationStatus == 0)
        }
    }
}
