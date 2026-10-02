import AppKit
import BetterTileCore
import Testing
@testable import BetterTileMacOS

@Test @MainActor func tabbedCurtainCoversContentBelowItsSelectedWindow() throws {
    _ = NSApplication.shared
    let id = WindowID(rawValue: "curtain-selected")
    var state = TabbedLayoutState(preset: .columns)
    state.reconcile(windowIDs: [id], removed: [], focused: id)
    var ordered: [(NSPanel, NSWindow.OrderingMode, Int)] = []
    let overlay = TabbedOverlayController(orderPanel: { ordered.append(($0, $1, $2)) })
    defer { overlay.hide() }
    overlay.refresh(state: state, bounds: BTRect(x: 12000, y: 100, width: 1000, height: 800),
                    windows: [], selectedWindowNumbers: [id: 123], curtainAnchorWindowNumber: 123)

    let curtains = ordered.filter { $0.1 == .below }
    #expect(curtains.count == 1) // The other pane is empty.
    let (panel, _, number) = try #require(curtains.first)
    #expect(number == 123)
    #expect(panel.level == .normal)
    #expect(!panel.ignoresMouseEvents) // Clicks must not reach a hidden tab.
    #expect(!panel.canBecomeKey && !panel.canBecomeMain)
    #expect(!panel.isAccessibilityElement())
    #expect(panel.collectionBehavior.contains([.transient, .ignoresCycle]))
    #expect(!panel.collectionBehavior.contains(.canJoinAllSpaces))
    #expect(overlay.windowNumbers.contains(panel.windowNumber))
    let frame = CoordinateConverter.toTopLeft(panel.frame, mainScreenFrame: NSScreen.screens.first!.frame)
    #expect(frame == BTRect(x: 12000, y: 100, width: 1000, height: 800))
}

@Test @MainActor func tabbedChromeJoinsTheNormalStackAboveSelectedWindows() throws {
    _ = NSApplication.shared
    let id = WindowID(rawValue: "anchored-selected")
    var state = TabbedLayoutState(preset: .columns)
    state.reconcile(windowIDs: [id], removed: [], focused: id)
    var ordered: [(NSPanel, NSWindow.OrderingMode, Int)] = []
    let overlay = TabbedOverlayController(orderPanel: { ordered.append(($0, $1, $2)) })
    defer { overlay.hide() }
    let bounds = BTRect(x: 12000, y: 100, width: 1000, height: 800)
    overlay.refresh(state: state, bounds: bounds, windows: [], selectedWindowNumbers: [id: 123], curtainAnchorWindowNumber: 123)

    // The strip and the empty pane sit directly above the selected window,
    // so any window in front of it, such as Settings, also covers them.
    let chrome = ordered.filter { $0.1 == .above }
    #expect(chrome.count == 2)
    #expect(chrome.allSatisfy { $0.0.level == .normal && $0.2 == 123 })
    #expect(Set(chrome.map(\.0.windowNumber)).isSubset(of: overlay.windowNumbers))

    // Without an exact identity, chrome floats as before.
    ordered.removeAll()
    overlay.refresh(state: state, bounds: bounds, windows: [])
    #expect(ordered.isEmpty)
    let strips = NSApp.windows.compactMap { $0 as? NSPanel }.filter { panel in
        chrome.contains { $0.0 === panel }
    }
    #expect(strips.count == 2)
    #expect(strips.allSatisfy { $0.level == .floating && $0.isVisible })
}

@Test @MainActor func clickingATabbedCurtainSelectsItsPanesSelectedWindow() throws {
    _ = NSApplication.shared
    let first = WindowID(rawValue: "click-first"), second = WindowID(rawValue: "click-second")
    var state = TabbedLayoutState()
    state.reconcile(windowIDs: [first, second], removed: [], focused: first)
    var curtain: NSPanel?
    let overlay = TabbedOverlayController(orderPanel: { panel, mode, _ in if mode == .below { curtain = panel } })
    defer { overlay.hide() }
    overlay.refresh(state: state, bounds: BTRect(x: 12000, y: 0, width: 1000, height: 800),
                    windows: [], selectedWindowNumbers: [first: 7, second: 8], curtainAnchorWindowNumber: 7)
    let panel = try #require(curtain)
    let view = try #require(panel.contentView as? TabbedCurtainView)
    #expect(view.acceptsFirstMouse(for: nil))
    #expect(view.hitTest(NSPoint(x: 10, y: 10)) === view)
    var selected: [WindowID] = []
    overlay.onIntent = { if case let .select(id) = $0 { selected.append(id) } }
    let event = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 10, y: 10), modifierFlags: [],
                                                timestamp: 0, windowNumber: panel.windowNumber, context: nil,
                                                eventNumber: 0, clickCount: 1, pressure: 1))
    view.mouseDown(with: event)
    #expect(selected == [first])
}

@Test @MainActor func tabbedCurtainFollowsResizeAndSelectionAndHidesWithoutAnExactWindow() throws {
    _ = NSApplication.shared
    let bounds = BTRect(x: 12000, y: 0, width: 1000, height: 800)
    let first = WindowID(rawValue: "curtain-first"), second = WindowID(rawValue: "curtain-second")
    var state = TabbedLayoutState(preset: .columns)
    state.reconcile(windowIDs: [first, second], removed: [], focused: first)
    // Real AppKit ordering against our own off-screen windows. Cross-app
    // ordering still needs the maintainer's live experiment.
    let targets = (0..<2).map { _ in
        NSPanel(contentRect: CoordinateConverter.toAppKit(bounds, mainScreenFrame: NSScreen.screens.first!.frame),
                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    }
    defer { targets.forEach { $0.orderOut(nil) } }
    targets.forEach { $0.orderFrontRegardless() }
    let numbers = [first: targets[0].windowNumber, second: targets[1].windowNumber]
    var ordered: [(NSPanel, Int)] = []
    let overlay = TabbedOverlayController(orderPanel: { panel, mode, number in
        if mode == .below { ordered.append((panel, number)) }
        panel.order(mode, relativeTo: number)
    })
    defer { overlay.hide() }
    overlay.refresh(state: state, bounds: bounds, windows: [], selectedWindowNumbers: numbers, curtainAnchorWindowNumber: state.selectedWindowIDs.first.flatMap { numbers[$0] })
    let curtain = try #require(ordered.first?.0)
    #expect(curtain.isVisible)
    let divider = try #require(state.dividers(in: bounds).first?.branchID)
    let adjusted = state.adjustDivider(divider, by: 0.1, in: bounds)
    #expect(adjusted)
    overlay.refreshResize(state: state, bounds: bounds)
    let frame = CoordinateConverter.toTopLeft(curtain.frame, mainScreenFrame: NSScreen.screens.first!.frame)
    #expect(frame == bounds)
    #expect(ordered.count == 1) // Resizing does not raise or reorder tabs.

    state.select(second)
    overlay.refresh(state: state, bounds: bounds, windows: [], selectedWindowNumbers: numbers, curtainAnchorWindowNumber: state.selectedWindowIDs.first.flatMap { numbers[$0] })
    #expect(ordered.last?.0 === curtain)
    #expect(ordered.last?.1 == targets[1].windowNumber)
    overlay.refresh(state: state, bounds: bounds, windows: [], selectedWindowNumbers: [second: 0])
    #expect(!curtain.isVisible)
    #expect(ordered.count == 2)
    overlay.refresh(state: state, bounds: bounds, windows: [], selectedWindowNumbers: numbers, curtainAnchorWindowNumber: state.selectedWindowIDs.first.flatMap { numbers[$0] })
    let replacement = try #require(ordered.last?.0)
    state.reconcile(windowIDs: [], removed: [first, second], focused: nil)
    overlay.refresh(state: state, bounds: bounds, windows: [], selectedWindowNumbers: numbers, curtainAnchorWindowNumber: state.selectedWindowIDs.first.flatMap { numbers[$0] })
    #expect(!replacement.isVisible)

    state.reconcile(windowIDs: [first], removed: [], focused: first)
    overlay.refresh(state: state, bounds: bounds, windows: [], selectedWindowNumbers: numbers, curtainAnchorWindowNumber: state.selectedWindowIDs.first.flatMap { numbers[$0] })
    let final = try #require(ordered.last?.0)
    overlay.hide()
    overlay.refreshResize(state: state, bounds: bounds)
    #expect(!final.isVisible)
}

@Test(arguments: [(false, false), (true, false), (false, true)]) @MainActor
func tabbedCurtainUsesSolidAccessibilityFallback(options: (Bool, Bool)) {
    _ = NSApplication.shared
    let view = TabbedCurtainView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
    view.displayOptions = { (options.0, options.1) }
    view.refreshAppearance()
    #expect(view.showsGlass == !(options.0 || options.1))
    #expect(!view.isAccessibilityElement())
    let plate = view.subviews.last?.layer?.backgroundColor
    #expect(plate?.alpha == CGFloat(view.plateOpacity))
    #expect(view.plateOpacity >= 0.96)
    if options.0 || options.1 { #expect(view.plateOpacity == 1) }
}

@Test @MainActor func tabbedCurtainFrostFollowsLightAndDarkAppearance() throws {
    _ = NSApplication.shared
    let view = TabbedCurtainView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
    view.displayOptions = { (false, false) }
    var brightness: [CGFloat] = []
    for (name, appearanceName) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
        view.appearance = NSAppearance(named: appearanceName)
        view.refreshAppearance()
        let color = try #require(view.subviews.last?.layer?.backgroundColor)
        brightness.append(try #require(NSColor(cgColor: color)?.usingColorSpace(.sRGB)).redComponent)
        if let directory = ProcessInfo.processInfo.environment["BETTERTILE_TAB_PREVIEW_DIR"] {
            // Render only our own surface; no foreign-window content.
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("curtain-\(name).png"))
        }
    }
    #expect(brightness[0] > 0.5)
    #expect(brightness[1] < 0.5)
}

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
                       title: index < 2 ? "Shared document — a full title that can exceed the menu width" : "Document \(index)",
                       frame: bounds, displayID: DisplayID(rawValue: "preview"))
    }
    var state = TabbedLayoutState()
    state.reconcile(windowIDs: windows.map(\.id), removed: [], focused: windows.last?.id)
    let pane = try #require(state.panes.first)
    overlay.refresh(state: state, bounds: bounds, windows: windows)
    let menu = overlay.menu(pane: pane, windowID: nil)
    let tabItems = Array(menu.items.dropFirst().prefix(windows.count))
    #expect(tabItems.map(\.title) == pane.tabs.map { id in windows.first { $0.id == id }?.title })
    #expect(tabItems.allSatisfy { $0.toolTip == $0.title })
    // Identical labels still carry distinct window actions, including a tab
    // hidden by the strip's overflow range.
    #expect(tabItems.filter { $0.title == windows[0].title }.count == 2)
    #expect(menu.item(withTitle: "Document 8")?.state == .on)
    #expect(menu.item(withTitle: "Undo Layout Change")?.isEnabled == false)
    #expect(menu.item(withTitle: "Change Layout")?.submenu?.items.count == TabbedPreset.allCases.count)
    var selected: WindowID?
    overlay.onIntent = { if case let .select(id) = $0 { selected = id } }
    for (index, item) in tabItems.enumerated() {
        #expect(NSApp.sendAction(try #require(item.action), to: item.target, from: item))
        #expect(selected == pane.tabs[index])
    }
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

@Test(.enabled(if: ProcessInfo.processInfo.environment["BETTERTILE_TAB_PREVIEW_DIR"] != nil,
               "Requires an explicit Tabbed preview output directory."))
@MainActor func tabbedChromePreview() throws {
    // Render only our own views. No app launch, desktop capture, or input posting.
    let directory = try #require(ProcessInfo.processInfo.environment["BETTERTILE_TAB_PREVIEW_DIR"])
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

@Test(.enabled(if: ProcessInfo.processInfo.environment["BETTERTILE_TAB_PREVIEW_DIR"] != nil,
               "Requires an explicit Tabbed preview output directory."))
@MainActor func tabbedFloatTargetPreview() throws {
    let directory = try #require(ProcessInfo.processInfo.environment["BETTERTILE_TAB_PREVIEW_DIR"])
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
        func area(_ pane: TabbedPane) -> Double {
            guard let frame = frames[pane.id] else { return 0 }
            return frame.size.width * frame.size.height
        }
        let empty = state.panes.filter { $0.tabs.isEmpty }
        let target = empty.max { area($0) < area($1) } ?? state.panes[0]
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

@Test @MainActor func tabbedDividersStayAdjustableWithVoiceOver() throws {
    _ = NSApplication.shared
    let bounds = BTRect(x: 12000, y: 0, width: 1000, height: 800)
    var state = TabbedLayoutState(preset: .columns)
    let id = WindowID(rawValue: "voiceover-divider")
    state.reconcile(windowIDs: [id], removed: [], focused: id)
    let overlay = TabbedOverlayController()
    defer { overlay.hide() }
    var adjustments: [Double] = []
    overlay.onIntent = { if case let .adjustDivider(_, delta) = $0 { adjustments.append(delta) } }
    overlay.refresh(state: state, bounds: bounds, windows: [])
    let slider = try #require(NSApp.windows.compactMap { $0.contentView as? TabbedDividerAccessibilityView }.first)
    #expect(slider.accessibilityRole() == .slider)
    #expect(slider.window?.ignoresMouseEvents == true)
    #expect(slider.accessibilityPerformIncrement())
    #expect(slider.accessibilityPerformDecrement())
    #expect(adjustments == [0.05, -0.05])
}

@Test @MainActor func tabStripFollowsLiveAccessibilityDisplayChanges() {
    _ = NSApplication.shared
    let view = TabbedPaneView(frame: NSRect(x: 0, y: 0, width: 300, height: 34))
    var reduceTransparency = false
    var increaseContrast = false
    view.displayOptions = { (reduceTransparency, increaseContrast) }
    view.refreshAppearance()
    #expect(view.showsGlass)
    reduceTransparency = true
    NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    #expect(!view.showsGlass)
    reduceTransparency = false
    NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    #expect(view.showsGlass)
    // Increase Contrast alone also selects the solid surface.
    increaseContrast = true
    NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    #expect(!view.showsGlass)
    increaseContrast = false
    view.refreshAppearance()
    #expect(view.showsGlass)
}

@Test @MainActor func realClicksHitTheStripContentAboveTheGlass() throws {
    // Clicks are hit-tested, not forwarded: nothing may sit above the strip.
    _ = NSApplication.shared
    let panel = NSPanel(contentRect: NSRect(x: 12000, y: 0, width: 330, height: 34),
                        styleMask: [.borderless], backing: .buffered, defer: false)
    let view = TabbedPaneView()
    panel.contentView = view
    for x in stride(from: 4.0, to: 330.0, by: 40) {
        let point = view.convert(NSPoint(x: x, y: 17), to: view.superview)
        #expect(view.hitTest(point) is TabbedPaneContentView)
    }
}

@Test @MainActor func tabStripsFollowALiveDividerResize() throws {
    _ = NSApplication.shared
    let bounds = BTRect(x: 12000, y: 0, width: 1000, height: 800)
    var state = TabbedLayoutState(preset: .columns)
    let left = WindowID(rawValue: "live-left"), right = WindowID(rawValue: "live-right")
    state.reconcile(windowIDs: [left], removed: [], focused: left)
    state.activatePane(state.panes[1].id)
    state.reconcile(windowIDs: [left, right], removed: [], focused: nil)
    let overlay = TabbedOverlayController()
    defer { overlay.hide() }
    overlay.refresh(state: state, bounds: bounds, windows: [])
    func stripFrames() -> [NSRect] {
        NSApp.windows.filter { $0.isVisible && $0.contentView is TabbedPaneView }.map(\.frame).sorted { $0.minX < $1.minX }
    }
    let before = stripFrames()
    #expect(before.count == 2)
    var moved = state
    let divider = try #require(moved.dividers(in: bounds).first?.branchID)
    let adjusted = moved.adjustDivider(divider, by: 0.1, in: bounds)
    #expect(adjusted)
    overlay.refreshResize(state: moved, bounds: bounds)
    let after = stripFrames()
    #expect(after.count == 2)
    #expect(abs(after[0].width - (before[0].width + 100)) < 0.5)
    #expect(abs(after[1].minX - (before[1].minX + 100)) < 0.5)
}

@Test @MainActor func sharedCurtainRequiresAnExplicitValidatedSelectedAnchor() {
    _ = NSApplication.shared
    let first = WindowID(rawValue: "shared-first"), second = WindowID(rawValue: "shared-second")
    var state = TabbedLayoutState(preset: .columns)
    state.reconcile(windowIDs: [first], removed: [], focused: first)
    state.activatePane(state.panes[1].id)
    state.reconcile(windowIDs: [first, second], removed: [], focused: second)
    var curtains: [NSPanel] = []
    let overlay = TabbedOverlayController(orderPanel: { panel, mode, _ in
        if mode == .below { curtains.append(panel) }
    })
    defer { overlay.hide() }
    let bounds = BTRect(x: 12000, y: 0, width: 1000, height: 800)
    overlay.refresh(state: state, bounds: bounds, windows: [], selectedWindowNumbers: [first: 7, second: 8])
    #expect(curtains.isEmpty)
    overlay.refresh(state: state, bounds: bounds, windows: [], selectedWindowNumbers: [first: 7], curtainAnchorWindowNumber: 7)
    #expect(curtains.isEmpty)
    overlay.refresh(state: state, bounds: bounds, windows: [], selectedWindowNumbers: [first: 7, second: 8], curtainAnchorWindowNumber: 99)
    #expect(curtains.isEmpty)
    overlay.refresh(state: state, bounds: bounds, windows: [], selectedWindowNumbers: [first: 7, second: 8], curtainAnchorWindowNumber: 8)
    #expect(curtains.count == 1)
}
