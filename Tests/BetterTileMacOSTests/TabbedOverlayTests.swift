import AppKit
import BetterTileCore
import Testing
@testable import BetterTileMacOS

@Test @MainActor func selectingVisibleTabKeepsCrowdedStripPositions() throws {
    _ = NSApplication.shared
    let overlay = TabbedOverlayController()
    defer { overlay.hide() }
    let bounds = BTRect(x: 12000, y: 0, width: 330, height: 500)
    let ids = (0..<9).map { WindowID(rawValue: "stable-tab-\($0)") }
    var state = TabbedLayoutState()
    state.reconcile(windowIDs: ids, removed: [], focused: ids[8])
    overlay.refresh(state: state, bounds: bounds, windows: [])
    let view = try #require(NSApp.windows.compactMap(\.contentView).compactMap { $0 as? TabbedPaneView }
        .first { $0.pane.id == state.panes[0].id })
    let before = view.strip.tabFrame(7)
    state.select(ids[7])
    overlay.refresh(state: state, bounds: bounds, windows: [])
    #expect(view.strip.tabFrame(7) == before)
    #expect(view.strip.visibleRange == 7..<9)
    state.select(ids[0])
    overlay.refresh(state: state, bounds: bounds, windows: [])
    #expect(view.strip.visibleRange.contains(0))
}

@Test(arguments: [false, true]) @MainActor
func tabbedDragUsesReleaseDestination(cancel: Bool) throws {
    _ = NSApplication.shared
    let bounds = BTRect(x: 12000, y: 0, width: 1000, height: 800)
    var state = TabbedLayoutState(preset: .columns)
    let id = WindowID(rawValue: "drag-release")
    state.reconcile(windowIDs: [id], removed: [], focused: id)
    let overlay = TabbedOverlayController()
    defer { overlay.hide() }
    overlay.refresh(state: state, bounds: bounds, windows: [])
    let view = try #require(NSApp.windows.compactMap(\.contentView).compactMap { $0 as? TabbedPaneView }.first { $0.pane.id == state.panes[0].id })
    let panel = try #require(view.window)
    #expect(view.acceptsFirstMouse(for: nil))
    func event(_ type: NSEvent.EventType, point: BTPoint) throws -> NSEvent {
        let screen = NSPoint(x: point.x, y: NSScreen.screens.first!.frame.maxY - point.y)
        return try #require(NSEvent.mouseEvent(with: type, location: panel.convertPoint(fromScreen: screen), modifierFlags: [],
                                             timestamp: 0, windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }
    var destination: UUID?
    overlay.onIntent = { if case let .move(_, pane, _) = $0 { destination = pane } }
    view.mouseDown(with: try event(.leftMouseDown, point: BTPoint(x: 12060, y: 17)))
    view.mouseDragged(with: try event(.leftMouseDragged, point: BTPoint(x: 12250, y: 400)))
    #expect(NSApp.windows.filter(\.isVisible).compactMap(\.contentView).flatMap(\.subviews)
        .compactMap { $0 as? NSTextField }.contains { $0.stringValue == "Move to Pane 1" })
    if cancel { overlay.cancelInteraction() }
    view.mouseUp(with: try event(.leftMouseUp, point: BTPoint(x: 12750, y: 400)))
    #expect(destination == (cancel ? nil : state.panes[1].id))
    #expect(!overlay.isInteracting)
}

@Test(arguments: [120.0, 240, 330, 1024], [0, 1, 9])
func tabbedStripFitsNarrowAndCrowdedPanes(width: Double, count: Int) {
    let strip = TabbedStripLayout(width: width, count: count, selectedIndex: count > 0 ? count - 1 : nil)
    if count > 0 { #expect(strip.visibleRange.contains(count - 1)) }
    for index in strip.visibleRange {
        let frame = strip.tabFrame(index)
        #expect(frame.minX >= 32 && frame.maxX <= strip.menuFrame.minX)
        #expect(strip.tabIndex(at: NSPoint(x: frame.midX, y: 17)) == index)
        #expect(frame.contains(strip.closeFrame(index)))
    }
    #expect(strip.tabIndex(at: NSPoint(x: strip.menuFrame.midX, y: 17)) == nil)
    #expect(strip.tabIndex(at: NSPoint(x: 40, y: -1)) == nil)
    #expect(strip.insertion(at: -20).index == strip.visibleRange.lowerBound)
    #expect(strip.insertion(at: width + 20).index == strip.visibleRange.upperBound)
}

@Test @MainActor func tabbedPaneMenuListsEveryTabAndReflectsUndoAvailability() throws {
    _ = NSApplication.shared
    let overlay = TabbedOverlayController()
    defer { overlay.hide() }
    let bounds = BTRect(x: 12000, y: 0, width: 330, height: 500)
    let windows = (0..<9).map { index in
        WindowSnapshot(id: WindowID(rawValue: "menu-\(index)"), processIdentifier: 1,
                       title: "Document \(index)", frame: bounds, displayID: DisplayID(rawValue: "preview"))
    }
    var state = TabbedLayoutState()
    state.reconcile(windowIDs: windows.map(\.id), removed: [], focused: windows.last?.id)
    let pane = try #require(state.panes.first)
    overlay.refresh(state: state, bounds: bounds, windows: windows)
    let menu = overlay.menu(pane: pane, windowID: nil)
    #expect(windows.allSatisfy { menu.item(withTitle: $0.title) != nil })
    #expect(menu.item(withTitle: "Document 8")?.state == .on)
    #expect(menu.item(withTitle: "Undo Layout Change")?.isEnabled == false)
    #expect(menu.item(withTitle: "Change Layout")?.submenu?.items.count == TabbedPreset.allCases.count)
    var selected: WindowID?
    overlay.onIntent = { if case let .select(id) = $0 { selected = id } }
    let item = try #require(menu.item(withTitle: "Document 0"))
    #expect(NSApp.sendAction(try #require(item.action), to: item.target, from: item))
    #expect(selected == windows.first?.id)
    overlay.refresh(state: state, bounds: bounds, windows: windows, canUndo: true)
    #expect(overlay.menu(pane: pane, windowID: nil).item(withTitle: "Undo Layout Change")?.isEnabled == true)
    #expect(overlay.menu(pane: pane, windowID: pane.selected).item(withTitle: "Move to Pane") == nil)
}

@Test @MainActor func tabbedGlobalEscapeCancelsDragWithoutReleaseCommit() throws {
    _ = NSApplication.shared
    let bounds = BTRect(x: 12000, y: 0, width: 1000, height: 800)
    var state = TabbedLayoutState(preset: .columns)
    let id = WindowID(rawValue: "escape-drag")
    state.reconcile(windowIDs: [id], removed: [], focused: id)
    var globalHandler: (@MainActor (UInt16) -> Void)?
    var localHandler: (@MainActor (UInt16) -> Bool)?
    var removedMonitors = 0
    let overlay = TabbedOverlayController(
        addGlobalKeyMonitor: { handler in
            globalHandler = handler
            return NSObject()
        },
        addLocalKeyMonitor: { handler in
            localHandler = handler
            return NSObject()
        },
        removeMonitor: { _ in removedMonitors += 1 }
    )
    defer { overlay.hide() }
    overlay.refresh(state: state, bounds: bounds, windows: [])
    let view = try #require(NSApp.windows.compactMap(\.contentView).compactMap { $0 as? TabbedPaneView }.first { $0.pane.id == state.panes[0].id })
    let panel = try #require(view.window)
    var moves = 0
    overlay.onIntent = { intent in if case .move = intent { moves += 1 } }
    func event(_ type: NSEvent.EventType, point: BTPoint) throws -> NSEvent {
        let screen = NSPoint(x: point.x, y: NSScreen.screens.first!.frame.maxY - point.y)
        return try #require(NSEvent.mouseEvent(with: type, location: panel.convertPoint(fromScreen: screen), modifierFlags: [],
                                             timestamp: 0, windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }

    view.mouseDown(with: try event(.leftMouseDown, point: BTPoint(x: 12060, y: 17)))
    view.mouseDragged(with: try event(.leftMouseDragged, point: BTPoint(x: 12250, y: 400)))
    #expect(overlay.isInteracting)
    #expect(localHandler?(42) == false)

    globalHandler?(53)
    view.mouseUp(with: try event(.leftMouseUp, point: BTPoint(x: 12750, y: 400)))

    #expect(!overlay.isInteracting)
    #expect(moves == 0)
    #expect(removedMonitors == 2)
}

@Test @MainActor func tabbedChromePreview() throws {
    // Render only our own views. No app launch, desktop capture, or input posting.
    guard let directory = ProcessInfo.processInfo.environment["BETTERTILE_TAB_PREVIEW_DIR"] else { return }
    _ = NSApplication.shared
    for (name, appearanceName) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
        let appearance = try #require(NSAppearance(named: appearanceName))
        let image = NSImage(size: NSSize(width: 760, height: 400))
        appearance.performAsCurrentDrawingAppearance {
            image.lockFocus()
            defer { image.unlockFocus() }
            NSColor.windowBackgroundColor.setFill()
            NSRect(x: 0, y: 0, width: 760, height: 400).fill()
            for (index, spec) in [(686.0, 3, 0), (330.0, 9, 8), (120.0, 9, 0), (330.0, 0, 0)].enumerated() {
                let (width, count, selected) = spec
                let height = count == 0 ? 170.0 : 34.0
                let view = TabbedPaneView(frame: NSRect(x: 0, y: 0, width: width, height: height))
                view.appearance = appearance
                view.active = true
                view.pane.tabs = (0..<count).map { WindowID(rawValue: "render-\($0)") }
                view.pane.selected = view.pane.tabs.isEmpty ? nil : view.pane.tabs[selected]
                view.titles = (0..<count).map { $0 == 0 ? "Project notes — Long document title" : "Document \($0 + 1)" }
                view.icons = (0..<count).map { NSImage(systemSymbolName: ["doc.text", "globe", "terminal"][$0 % 3], accessibilityDescription: nil) }
                guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                    Issue.record("Could not render Tabbed preview")
                    continue
                }
                view.cacheDisplay(in: view.bounds, to: bitmap)
                let rendered = NSImage(size: view.bounds.size)
                rendered.addRepresentation(bitmap)
                rendered.draw(in: NSRect(x: 24, y: 370 - Double(index) * 55 - height, width: width, height: height),
                              from: .zero, operation: .sourceOver, fraction: 1)
            }
        }
        let bitmap = try #require(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: directory).appendingPathComponent("tabbed-chrome-\(name).png"))
    }
}

@Test @MainActor func tabbedFloatTargetPreview() throws {
    guard let directory = ProcessInfo.processInfo.environment["BETTERTILE_TAB_PREVIEW_DIR"] else { return }
    _ = NSApplication.shared
    let bounds = BTRect(x: 12000, y: 0, width: 1000, height: 800)
    let display = DisplayID(rawValue: "float-preview")

    func containsFloatLabel(_ view: NSView) -> Bool {
        if let label = view as? NSTextField, label.stringValue == "Float window" { return true }
        return view.subviews.contains(where: containsFloatLabel)
    }

    for (name, appearanceName) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
        let appearance = try #require(NSAppearance(named: appearanceName))
        do {
            let id = WindowID(rawValue: "float-preview-\(name)")
            var state = TabbedLayoutState()
            state.reconcile(windowIDs: [id], removed: [], focused: id)
            let window = WindowSnapshot(id: id, processIdentifier: 1, title: "Float preview", frame: bounds, displayID: display)
            let overlay = TabbedOverlayController()
            defer { overlay.hide() }
            overlay.refresh(state: state, bounds: bounds, windows: [window])
            let paneView = try #require(NSApp.windows.compactMap(\.contentView).compactMap { $0 as? TabbedPaneView }.first { $0.pane.tabs.contains(id) })
            let panePanel = try #require(paneView.window)
            paneView.appearance = appearance

            func event(_ type: NSEvent.EventType, point: BTPoint) throws -> NSEvent {
                let screen = NSPoint(x: point.x, y: NSScreen.screens.first!.frame.maxY - point.y)
                return try #require(NSEvent.mouseEvent(with: type, location: panePanel.convertPoint(fromScreen: screen),
                                                      modifierFlags: [], timestamp: 0, windowNumber: panePanel.windowNumber,
                                                      context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            }

            paneView.mouseDown(with: try event(.leftMouseDown, point: BTPoint(x: 12060, y: 17)))
            paneView.mouseDragged(with: try event(.leftMouseDragged, point: BTPoint(x: 12250, y: 400)))
            let floatPanel = try #require(NSApp.windows.first { $0.isVisible && containsFloatLabel($0.contentView ?? NSView()) })
            let floatView = try #require(floatPanel.contentView)
            floatPanel.appearance = appearance
            floatView.appearance = appearance
            guard let bitmap = floatView.bitmapImageRepForCachingDisplay(in: floatView.bounds) else {
                Issue.record("Could not render Float window target")
                continue
            }
            let image = NSImage(size: NSSize(width: 500, height: 180))
            appearance.performAsCurrentDrawingAppearance {
                image.lockFocus()
                NSColor.windowBackgroundColor.setFill()
                NSRect(x: 0, y: 0, width: 500, height: 180).fill()
                floatView.cacheDisplay(in: floatView.bounds, to: bitmap)
                let rendered = NSImage(size: floatView.bounds.size)
                rendered.addRepresentation(bitmap)
                rendered.draw(in: NSRect(x: 155, y: 66, width: floatView.bounds.width, height: floatView.bounds.height),
                              from: .zero, operation: .sourceOver, fraction: 1)
                image.unlockFocus()
            }
            let output = try #require(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
            try output.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: directory).appendingPathComponent("tabbed-float-target-\(name).png"))
        }
    }
}

@Test @MainActor func tabbedCrowdedStripKeepsSelectedTabAccessibleInsidePane() throws {
    _ = NSApplication.shared
    let panel = NSPanel(contentRect: NSRect(x: 12000, y: 0, width: 330, height: 34),
                        styleMask: [.borderless], backing: .buffered, defer: false)
    let view = TabbedPaneView()
    view.pane.tabs = (0..<9).map { WindowID(rawValue: "crowded-\($0)") }
    view.pane.selected = view.pane.tabs.last
    view.titles = (0..<9).map { "Document \($0)" }
    panel.contentView = view
    view.updateAccessibility()
    let actions = try #require(view.accessibilityChildren() as? [NSAccessibilityElement])
    #expect(actions.contains { $0.accessibilityLabel() == "Document 8, selected" })
    #expect(actions.allSatisfy { panel.frame.contains($0.accessibilityFrame()) })
    let menu = try #require(actions.last)
    #expect(actions.dropLast().allSatisfy { !$0.accessibilityFrame().intersects(menu.accessibilityFrame()) })
}

@Test @MainActor func tabbedCloseWaitsForReleaseAndCanBeCancelled() throws {
    _ = NSApplication.shared
    let panel = NSPanel(contentRect: NSRect(x: 12000, y: 0, width: 330, height: 34),
                        styleMask: [.borderless], backing: .buffered, defer: false)
    let overlay = TabbedOverlayController()
    let view = TabbedPaneView()
    let id = WindowID(rawValue: "close-test")
    view.owner = overlay
    view.pane.tabs = [id]
    view.pane.selected = id
    view.titles = ["Document"]
    panel.contentView = view
    view.updateAccessibility()
    let actions = try #require(view.accessibilityChildren() as? [NSAccessibilityElement])
    let close = try #require(actions.first { $0.accessibilityLabel() == "Close Document" })
    let frame = panel.convertFromScreen(close.accessibilityFrame())
    let point = NSPoint(x: frame.midX, y: frame.midY)
    func event(_ type: NSEvent.EventType, at point: NSPoint) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                                       windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }
    var closed: [WindowID] = []
    overlay.onIntent = { if case let .close(id) = $0 { closed.append(id) } }
    view.mouseDown(with: try event(.leftMouseDown, at: point))
    #expect(closed.isEmpty)
    view.mouseUp(with: try event(.leftMouseUp, at: NSPoint(x: 5, y: 5)))
    #expect(closed.isEmpty)
    view.mouseDown(with: try event(.leftMouseDown, at: point))
    view.mouseUp(with: try event(.leftMouseUp, at: point))
    #expect(closed == [id])
}

@Test @MainActor func tabbedTabSelectionRequiresReleaseInsideOriginalTab() throws {
    _ = NSApplication.shared
    let panel = NSPanel(contentRect: NSRect(x: 12000, y: 0, width: 330, height: 34),
                        styleMask: [.borderless], backing: .buffered, defer: false)
    let overlay = TabbedOverlayController()
    let view = TabbedPaneView()
    let first = WindowID(rawValue: "selection-first")
    let second = WindowID(rawValue: "selection-second")
    view.owner = overlay
    view.pane.tabs = [first, second]
    view.pane.selected = second
    view.titles = ["First", "Second"]
    panel.contentView = view
    defer { panel.orderOut(nil) }

    func event(_ type: NSEvent.EventType, at point: NSPoint) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                                       windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }

    let firstTab = view.strip.tabFrame(0)
    let secondTab = view.strip.tabFrame(1)
    let firstClose = view.strip.closeFrame(0)
    let secondClose = view.strip.closeFrame(1)
    let press = NSPoint(x: firstTab.minX + 20, y: firstTab.midY)
    let releases = [
        NSPoint(x: 5, y: firstTab.midY),
        NSPoint(x: firstTab.midX, y: -1),
        NSPoint(x: firstClose.midX, y: firstClose.midY),
        NSPoint(x: secondTab.midX, y: secondTab.midY),
        NSPoint(x: secondClose.midX, y: secondClose.midY),
    ]
    var selections: [WindowID] = []
    overlay.onIntent = { intent in
        if case let .select(id) = intent { selections.append(id) }
    }

    for release in releases {
        view.mouseDown(with: try event(.leftMouseDown, at: press))
        view.mouseUp(with: try event(.leftMouseUp, at: release))
    }
    #expect(selections.isEmpty)

    view.mouseDown(with: try event(.leftMouseDown, at: press))
    view.mouseUp(with: try event(.leftMouseUp, at: press))
    #expect(selections == [first])
}

@Test @MainActor func tabbedDragAtPaneLimitDoesNotOfferSplitButKeepsCenterMove() throws {
    _ = NSApplication.shared
    let bounds = BTRect(x: 12000, y: 0, width: 2400, height: 1800)
    let id = WindowID(rawValue: "pane-limit-drag")
    var state = TabbedLayoutState()
    state.reconcile(windowIDs: [id], removed: [], focused: id)
    let sourcePaneID = state.panes[0].id
    while state.panes.count < 12 {
        let frames = state.frames(in: bounds)
        let target = state.panes
            .filter { $0.tabs.isEmpty }
            .max { (frames[$0.id]?.size.width ?? 0) * (frames[$0.id]?.size.height ?? 0) <
                  (frames[$1.id]?.size.width ?? 0) * (frames[$1.id]?.size.height ?? 0) }
            ?? state.panes[0]
        let targetFrame = try #require(frames[target.id])
        state.split(paneID: target.id, moving: id, edge: targetFrame.size.width >= targetFrame.size.height ? .right : .bottom)
        state.move(id, to: sourcePaneID)
    }
    #expect(state.panes.count == 12)

    let window = WindowSnapshot(id: id, processIdentifier: 1, title: "Pane limit", frame: bounds,
                               displayID: DisplayID(rawValue: "preview"))
    let overlay = TabbedOverlayController()
    defer { overlay.hide() }
    var intents: [TabbedUIIntent] = []
    overlay.onIntent = { intents.append($0) }
    overlay.refresh(state: state, bounds: bounds, windows: [window])
    let view = try #require(NSApp.windows.compactMap(\.contentView).compactMap { $0 as? TabbedPaneView }.first { $0.pane.tabs.contains(id) })
    let panel = try #require(view.window)
    let frames = state.frames(in: bounds)
    let sourceFrame = try #require(frames[sourcePaneID])

    func event(_ type: NSEvent.EventType, screenPoint point: BTPoint) throws -> NSEvent {
        let screen = NSPoint(x: point.x, y: NSScreen.screens.first!.frame.maxY - point.y)
        return try #require(NSEvent.mouseEvent(with: type, location: panel.convertPoint(fromScreen: screen),
                                              modifierFlags: [], timestamp: 0, windowNumber: panel.windowNumber,
                                              context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }
    func labels(in view: NSView) -> [String] {
        var values = (view as? NSTextField).map { [$0.stringValue] } ?? []
        for child in view.subviews { values += labels(in: child) }
        return values
    }

    let press = BTPoint(x: sourceFrame.minX + 60, y: sourceFrame.minY + 17)
    let intermediate = BTPoint(x: press.x + 20, y: press.y + 60)
    let edge = BTPoint(x: sourceFrame.maxX - 4, y: sourceFrame.minY + TabbedLayoutState.headerHeight + 120)
    view.mouseDown(with: try event(.leftMouseDown, screenPoint: press))
    view.mouseDragged(with: try event(.leftMouseDragged, screenPoint: intermediate))
    view.mouseDragged(with: try event(.leftMouseDragged, screenPoint: edge))
    #expect(!NSApp.windows.filter(\.isVisible).flatMap { labels(in: $0.contentView ?? NSView()) }.contains { $0.contains("Split") })
    view.mouseUp(with: try event(.leftMouseUp, screenPoint: edge))
    #expect(!intents.contains { if case .split = $0 { true } else { false } })

    intents.removeAll()
    let destination = try #require(state.panes.first { $0.id != sourcePaneID && (frames[$0.id]?.size.width ?? 0) > 100 })
    let destinationFrame = try #require(frames[destination.id])
    let center = BTPoint(x: destinationFrame.midX, y: destinationFrame.minY + TabbedLayoutState.headerHeight + 120)
    view.mouseDown(with: try event(.leftMouseDown, screenPoint: press))
    view.mouseDragged(with: try event(.leftMouseDragged, screenPoint: intermediate))
    view.mouseDragged(with: try event(.leftMouseDragged, screenPoint: center))
    view.mouseUp(with: try event(.leftMouseUp, screenPoint: center))
    guard case let .move(movedID, pane, index) = intents.last else {
        Issue.record("Center drag did not emit a move intent")
        return
    }
    #expect(movedID == id)
    #expect(pane == destination.id)
    #expect(index == nil)
}

@Test @MainActor func tabbedEmptyPaneHasAccessibleDestinationAndLayoutActions() throws {
    _ = NSApplication.shared
    var state = TabbedLayoutState(preset: .focus)
    let a = WindowID(rawValue: "preview-a"), b = WindowID(rawValue: "preview-b")
    state.reconcile(windowIDs: [a, b], removed: [], focused: a)
    let overlay = TabbedOverlayController()
    defer { overlay.hide() }
    let display = DisplayID(rawValue: "preview")
    let bounds = BTRect(x: 12000, y: 0, width: 1200, height: 800)
    let windows = [
        WindowSnapshot(id: a, processIdentifier: 1, title: "Safari — Project notes", frame: bounds, displayID: display),
        WindowSnapshot(id: b, processIdentifier: 2, title: "Terminal", frame: bounds, displayID: display),
    ]
    var activated: UUID?
    overlay.onIntent = { intent in if case let .activate(id) = intent { activated = id } }
    overlay.refresh(state: state, bounds: bounds, windows: windows)
    let paneView = try #require(NSApp.windows.compactMap(\.contentView).first { $0.accessibilityLabel() == "Pane 2, empty" })
    let actions = try #require(paneView.accessibilityChildren() as? [NSAccessibilityElement])
    #expect(actions.allSatisfy { $0.isAccessibilityEnabled() })
    let activate = try #require(actions.first { $0.accessibilityLabel() == "Use pane 2 for new windows" })
    #expect(activate.accessibilityPerformPress())
    #expect(activated == state.panes[1].id)
    #expect(actions.contains { $0.accessibilityLabel() == "Pane 2 layout and tab actions" })

    // Optional visual QA artifact, drawn from BetterTile views only. This does
    // not capture the screen or any foreign window content.
    if let directory = ProcessInfo.processInfo.environment["BETTERTILE_TAB_PREVIEW_DIR"] {
        let image = NSImage(size: NSSize(width: 1200, height: 800))
        image.lockFocus()
        NSColor.darkGray.setFill()
        NSRect(x: 0, y: 0, width: 1200, height: 800).fill()
        for window in NSApp.windows where window.frame.minX >= 12000 && window.frame.minX < 13200 {
            guard let view = window.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            bitmap.draw(in: NSRect(x: window.frame.minX - 12000, y: window.frame.minY - (NSScreen.screens.first?.frame.maxY ?? 0) + 800,
                                  width: window.frame.width, height: window.frame.height))
        }
        image.unlockFocus()
        let bitmap = try #require(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: directory).appendingPathComponent("tabbed-pane-preview.png"))
    }
}

@Test func tabStripKeepsItsVisibleRangeWhenSelectingAVisibleTab() {
    let first = TabbedStripLayout(width: 500, count: 9, selectedIndex: 6)
    let visible = first.visibleRange
    #expect(visible.contains(6))
    // Selecting another visible tab must not scroll the strip under the pointer.
    for index in visible {
        let next = TabbedStripLayout(width: 500, count: 9, selectedIndex: index, startIndex: visible.lowerBound)
        #expect(next.visibleRange == visible)
    }
    // Selecting a hidden tab scrolls just far enough to show it.
    let after = TabbedStripLayout(width: 500, count: 9, selectedIndex: visible.upperBound, startIndex: visible.lowerBound)
    #expect(after.visibleRange.upperBound == visible.upperBound + 1)
}

@Test(arguments: [180.0, 420.0, 900.0])
func tabStripInsertionPointsMatchRenderedTabEdges(width: Double) {
    let strip = TabbedStripLayout(width: width, count: 12, selectedIndex: 5, startIndex: 3)
    for index in strip.visibleRange {
        let frame = strip.tabFrame(index)
        // Just inside a tab's leading or trailing half inserts at the edge drawn there.
        #expect(abs(strip.insertion(at: frame.minX + frame.width * 0.25).x - frame.minX) < 0.001)
        #expect(strip.insertion(at: frame.minX + frame.width * 0.25).index == index)
        #expect(abs(strip.insertion(at: frame.maxX - frame.width * 0.25).x - frame.maxX) < 0.001)
        #expect(strip.insertion(at: frame.maxX - frame.width * 0.25).index == index + 1)
        #expect(strip.tabIndex(at: NSPoint(x: frame.midX, y: frame.midY)) == index)
        #expect(frame.maxX <= strip.menuFrame.minX + 0.001)
    }
}

@Test func tabStripStaysValidWhenNarrowerThanOneTab() {
    let strip = TabbedStripLayout(width: 60, count: 4, selectedIndex: 2)
    #expect(strip.visibleRange.count == 1)
    #expect(strip.visibleRange.contains(2))
    #expect(strip.hiddenCount == 3)
    #expect(strip.tabWidth >= 0)
    #expect(strip.insertion(at: 40).index >= strip.visibleRange.lowerBound)
}
