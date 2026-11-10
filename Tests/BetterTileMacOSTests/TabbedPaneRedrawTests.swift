import AppKit
import BetterTileCore
import Testing
@testable import BetterTileMacOS

/// Never ordered on screen. Display only dirty AppKit backing layers, rather
/// than cacheDisplay(), which forces a draw even when the view is clean.
@MainActor private final class PaneRedrawFixture {
    let window: NSWindow
    let view: TabbedPaneView
    var content: TabbedPaneContentView { view.content }
    let ids = (0..<3).map { WindowID(rawValue: "redraw-\($0)") }

    init(empty: Bool = true, presentation: TabbedStripPresentation = .autoHide, glass: Bool = true) {
        _ = NSApplication.shared
        let size = NSSize(width: 800, height: empty ? 600 : presentation.barHeight)
        window = NSWindow(contentRect: NSRect(origin: NSPoint(x: 40000, y: 40000), size: size),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        view = TabbedPaneView(frame: NSRect(origin: .zero, size: size))
        view.presentation = presentation
        view.displayOptions = { (false, false) }
        view.overlayAppearance.useLiquidGlass = glass
        view.reduceMotion = { false }
        if !empty {
            var pane = TabbedPane()
            pane.tabs = ids
            pane.selected = ids[0]
            view.pane = pane
            view.titles = ["Alpha", "Gamma", "Notes"]
        }
        // An assignment that keeps a value does not refresh the view. Apply the
        // injected options here, so the host's accessibility settings never decide.
        view.refreshAppearance()
        window.contentView = view
        flush()
    }

    func flush() {
        view.layoutSubtreeIfNeeded()
        func display(_ node: NSView) {
            node.layer?.displayIfNeeded()
            for child in node.subviews { display(child) }
        }
        display(view)
        CATransaction.flush()
    }

    func move(_ point: NSPoint, type: NSEvent.EventType = .mouseMoved) throws {
        let location = content.convert(point, to: nil)
        let event = try #require(type == .mouseExited
            ? NSEvent.enterExitEvent(with: type, location: location, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)
            : NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
        if type == .mouseExited { content.mouseExited(with: event) }
        else { content.mouseMoved(with: event) }
        flush()
    }
}

@Test(.macOSTestApplication, arguments: TabbedStripPresentation.allCases, [(false, false), (false, true), (true, false), (true, true)]) @MainActor
func tabbedPaneRedrawUnchangedBodyMoves(presentation: TabbedStripPresentation, configuration: (Bool, Bool)) async throws {
    let (empty, glass) = configuration
    let fixture = PaneRedrawFixture(empty: empty, presentation: presentation, glass: glass)
    defer { fixture.window.close() }
    let content = fixture.content
    #expect(content.drawCount > 0)
    var bodyDraws = 0
    for i in 0..<100 {
        // Other AppKit work can invalidate the layers while this test yields. Flush it before measuring
        // each move, and keep the move and its redraw checks in the same main-actor turn.
        fixture.flush()
        let initial = content.drawCount
        let tabs = content.tabDrawCounts
        try fixture.move(NSPoint(x: 100 + i, y: 200))
        bodyDraws += content.drawCount - initial
        #expect(content.drawCount == initial)
        #expect(content.tabDrawCounts == tabs)
        await Task.yield()
    }
    print("PANE-REDRAW body moves=100 empty=\(empty) glass=\(glass) presentation=\(presentation) pane=\(bodyDraws)")
}

@Test(.macOSTestApplication, .enabled(if: ProcessInfo.processInfo.environment["BETTERTILE_PANE_REDRAW_BENCH"] == "1")) @MainActor
func tabbedPaneRedrawBenchmark() throws {
    for empty in [true, false] {
        let fixture = PaneRedrawFixture(empty: empty)
        defer { fixture.window.close() }
        let point = empty ? NSPoint(x: 200, y: 200) : NSPoint(x: 50, y: 16)
        try fixture.move(point)
        for batch in 0..<5 {
            let initial = fixture.content.drawCount
            let tabs = fixture.content.tabDrawCounts.values.reduce(0, +)
            let began = CACurrentMediaTime()
            for i in 0..<800 { try fixture.move(NSPoint(x: point.x + Double(i % 20), y: point.y)) }
            let elapsed = CACurrentMediaTime() - began
            print("PANE-BENCH empty=\(empty) batch=\(batch) moves=800 pane=\(fixture.content.drawCount - initial) tabs=\(fixture.content.tabDrawCounts.values.reduce(0, +) - tabs) ms=\(elapsed * 1000)")
        }
    }
}

@MainActor private extension PaneRedrawFixture {
    /// Reads cached layer pixels without asking AppKit to draw the view again.
    func pixels(_ node: NSView? = nil) throws -> Data {
        let node = node ?? content
        let width = Int(node.bounds.width), height = Int(node.bounds.height)
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        try #require(node.layer).render(in: context)
        return Data(bytes: try #require(context.data), count: height * context.bytesPerRow)
    }

    func expectFreshCache(sourceLocation: SourceLocation = #_sourceLocation) throws {
        let cached = try pixels()
        content.needsDisplay = true
        flush()
        #expect(try pixels() == cached, "Cached contents must match a full redraw", sourceLocation: sourceLocation)
    }
}

@Test(.macOSTestApplication, arguments: TabbedStripPresentation.allCases) @MainActor
func tabbedPaneRedrawOnlyChangedHoverTargets(presentation: TabbedStripPresentation) throws {
    let fixture = PaneRedrawFixture(empty: false, presentation: presentation)
    defer { fixture.window.close() }
    let content = fixture.content
    let strip = content.strip
    let a = fixture.ids[1], b = fixture.ids[2]
    let tab = NSPoint(x: strip.tabFrame(1).minX + 10, y: strip.height / 2)
    let close = NSPoint(x: strip.closeFrame(1).midX, y: strip.height / 2)
    let other = NSPoint(x: strip.tabFrame(2).minX + 10, y: strip.height / 2)
    let menu = NSPoint(x: strip.menuFrame.midX, y: strip.height / 2)
    let badge = NSPoint(x: 15, y: strip.height / 2)

    func change(_ point: NSPoint, pane: Int = 0, tabs: Set<WindowID> = [], exit: Bool = false) throws {
        let before = content.drawCount
        let tabBefore = content.tabDrawCounts
        try fixture.move(point, type: exit ? .mouseExited : .mouseMoved)
        #expect(content.drawCount - before == pane)
        for id in fixture.ids {
            #expect(content.tabDrawCounts[id, default: 0] - tabBefore[id, default: 0] == (tabs.contains(id) ? 1 : 0))
        }
        try fixture.expectFreshCache()
    }

    try change(tab, tabs: [a])
    for i in 0..<100 { try change(NSPoint(x: tab.x + Double(i % 4), y: tab.y)) }
    try change(close, tabs: [a])
    try change(close)
    try change(other, tabs: [a, b])
    try change(badge, tabs: [b])
    try change(menu, pane: 1)
    try change(NSPoint(x: menu.x + 1, y: menu.y))
    try change(badge, pane: 1)
    try change(badge, exit: true)
    try change(tab, tabs: [a])
    try change(tab, tabs: [a], exit: true)
    try change(tab, exit: true)
}


@Test(.macOSTestApplication, arguments: TabbedStripPresentation.allCases) @MainActor
func tabbedPaneRedrawSelectedTabOnlyChangesAtCloseButton(presentation: TabbedStripPresentation) throws {
    let fixture = PaneRedrawFixture(empty: false, presentation: presentation)
    defer { fixture.window.close() }
    let content = fixture.content
    let initial = content.drawCount
    let tabs = content.tabDrawCounts
    for i in 0..<100 { try fixture.move(NSPoint(x: Double(50 + i % 10), y: presentation.barHeight / 2)) }
    #expect(content.drawCount == initial)
    #expect(content.tabDrawCounts == tabs)
    let close = content.strip.closeFrame(0)
    try fixture.move(NSPoint(x: close.midX, y: close.midY))
    #expect(content.tabDrawCounts[fixture.ids[0], default: 0] == tabs[fixture.ids[0], default: 0] + 1)
    try fixture.expectFreshCache()
}

@Test(.macOSTestApplication, arguments: TabbedStripPresentation.allCases) @MainActor
func tabbedPaneRedrawRelayoutKeepsStationaryHoverFresh(presentation: TabbedStripPresentation) throws {
    let fixture = PaneRedrawFixture(empty: false, presentation: presentation)
    defer { fixture.window.close() }
    let content = fixture.content
    let menu = content.strip.menuFrame
    try fixture.move(NSPoint(x: menu.midX, y: menu.midY))
    let before = content.drawCount
    fixture.view.setChromeSize(NSSize(width: 200, height: presentation.barHeight))
    fixture.flush()
    #expect(content.drawCount > before)
    #expect(content.strip.hiddenCount > 0)
    try fixture.expectFreshCache()
    let settled = content.drawCount
    try fixture.move(NSPoint(x: menu.midX, y: menu.midY))
    #expect(content.drawCount == settled)

    // A tab is now beneath this stationary point after the titles change width.
    let point = NSPoint(x: content.strip.closeFrame(0).midX, y: presentation.barHeight / 2)
    try fixture.move(point)
    fixture.view.titles = [String(repeating: "Long title ", count: 4), "G", "N"]
    fixture.flush()
    let tabs = content.tabDrawCounts
    try fixture.move(point)
    #expect(content.tabDrawCounts == tabs)
    try fixture.expectFreshCache()
}

@Test(.macOSTestApplication) @MainActor func tabbedPaneRedrawAppearanceAndContentChangesStayFresh() throws {
    let fixture = PaneRedrawFixture(empty: false)
    defer { fixture.window.close() }
    let content = fixture.content
    fixture.view.appearance = NSAppearance(named: .aqua)
    fixture.flush()
    let light = try fixture.pixels()
    let before = content.drawCount
    let tabs = content.tabDrawCounts
    fixture.view.appearance = NSAppearance(named: .darkAqua)
    fixture.flush()
    #expect(content.drawCount > before)
    #expect(fixture.ids.allSatisfy { content.tabDrawCounts[$0, default: 0] > tabs[$0, default: 0] })
    #expect(try fixture.pixels() != light)
    try fixture.expectFreshCache()

    let numbered = content.drawCount
    content.number = 7
    fixture.flush()
    #expect(content.drawCount == numbered + 1)
    try fixture.expectFreshCache()
    content.pane = TabbedPane()
    fixture.view.setChromeSize(NSSize(width: 800, height: 600))
    fixture.flush()
    try fixture.expectFreshCache()
}

@Test(.macOSTestApplication, arguments: ["preference", "reduceTransparency", "increaseContrast"]) @MainActor
func tabbedPaneRedrawGlassTransparencyStaysFresh(change: String) throws {
    let fixture = PaneRedrawFixture()
    defer { fixture.window.close() }
    let content = fixture.content
    let before = content.drawCount
    #expect(fixture.view.showsGlass)
    if change == "preference" { fixture.view.overlayAppearance.useLiquidGlass = false }
    else {
        fixture.view.displayOptions = { (change == "reduceTransparency", change == "increaseContrast") }
        fixture.view.refreshAppearance()
    }
    fixture.flush()
    #expect(!fixture.view.showsGlass)
    #expect(fixture.view.glass.plateOpacity == 1)
    #expect(content.drawCount > before)
    try fixture.expectFreshCache()
    fixture.view.overlayAppearance.useLiquidGlass = true
    fixture.view.displayOptions = { (false, false) }
    fixture.view.refreshAppearance()
    fixture.flush()
    #expect(fixture.view.showsGlass)
    #expect(fixture.view.glass.plateOpacity < 1)
    try fixture.expectFreshCache()
}

@Test(.macOSTestApplication) @MainActor func tabbedPaneRedrawAutoHideRevealCollapseStayFresh() throws {
    let fixture = PaneRedrawFixture(empty: false)
    defer { fixture.window.close() }
    let view = fixture.view
    view.setAutoHideCollapsed(true, at: 0, animated: false)
    view.setChromeSize(NSSize(width: 800, height: 6))
    fixture.flush()
    #expect(view.content.isHidden)
    #expect(view.glass.frame == view.indicatorFrame)
    view.setChromeSize(NSSize(width: 800, height: 34))
    view.setAutoHideCollapsed(false, at: 1, animated: true)
    fixture.flush()
    #expect(!view.content.isHidden)
    #expect(view.layer?.mask != nil)
    view.setAutoHideCollapsed(false, at: 1.2, animated: true)
    fixture.flush()
    #expect(view.layer?.mask == nil)
    #expect(view.glass.frame == view.bounds)
    try fixture.expectFreshCache()
    view.setAutoHideCollapsed(true, at: 2, animated: true)
    fixture.flush()
    view.setAutoHideCollapsed(true, at: 2.2, animated: true)
    view.setChromeSize(NSSize(width: 800, height: 6))
    fixture.flush()
    #expect(view.content.isHidden)
    #expect(view.layer?.mask == nil)
    #expect(view.glass.frame == view.indicatorFrame)
}


/// Optional before/after pixel comparison of our cached content and glass plate.
/// Native backdrop blur still needs a live composited check.
@Test(.macOSTestApplication, .enabled(if: ProcessInfo.processInfo.environment["BETTERTILE_PANE_REDRAW_PIXELS"] != nil)) @MainActor
func tabbedPaneRedrawVisualReference() throws {
    let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["BETTERTILE_PANE_REDRAW_PIXELS"]))
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    for presentation in TabbedStripPresentation.allCases {
        for empty in [true, false] {
            for dark in [true, false] {
                for glass in [true, false] {
                    let fixture = PaneRedrawFixture(empty: empty, presentation: presentation, glass: glass)
                    defer { fixture.window.close() }
                    fixture.view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    fixture.flush()
                    let strip = fixture.content.strip
                    let points = [NSPoint(x: 200, y: 200), NSPoint(x: strip.menuFrame.midX, y: strip.height / 2),
                                  NSPoint(x: strip.tabFrame(1).minX + 8, y: strip.height / 2),
                                  NSPoint(x: strip.closeFrame(1).midX, y: strip.height / 2)]
                    for (index, point) in points.enumerated() {
                        try fixture.move(point)
                        let name = "\(presentation)-empty-\(empty)-dark-\(dark)-glass-\(glass)-hover-\(index).rgba"
                        try fixture.pixels(fixture.view).write(to: directory.appendingPathComponent(name))
                    }
                }
            }
        }
    }
}
