import AppKit
import BetterTileCore
import Testing
@testable import BetterTileMacOS

// Opt-in synthetic main-thread benchmark. Run serially on one machine.
// It measures BetterTile's own work per sample, plus the Core Animation commit
// and pending AppKit drawing. It does not measure WindowServer compositing.

@MainActor private var phases: [String: [Double]] = [:]

@MainActor private func settle(_ began: Double) {
    let called = CACurrentMediaTime()
    CATransaction.flush()
    let committed = CACurrentMediaTime()
    for window in NSApp.windows where window.isVisible { window.displayIfNeeded() }
    CATransaction.flush()
    let drawn = CACurrentMediaTime()
    phases["call", default: []].append(called - began)
    phases["commit", default: []].append(committed - called)
    phases["draw", default: []].append(drawn - committed)
}

@MainActor private func reportPhases(_ name: String) throws {
    for key in ["call", "commit", "draw"] {
        try report(summary("   \(name) [\(key)]", Array((phases[key] ?? []).dropFirst(20))))
    }
    phases = [:]
}

private func summary(_ name: String, _ samples: [Double]) -> String {
    let sorted = samples.sorted()
    func pct(_ p: Double) -> Double { sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))] * 1000 }
    let mean = samples.reduce(0, +) / Double(samples.count) * 1000
    return String(format: "%@  mean %.3f ms  p50 %.3f  p95 %.3f  max %.3f  (n=%d)",
                  name, mean, pct(0.5), pct(0.95), (sorted.last ?? 0) * 1000, samples.count)
}

private func report(_ line: String) throws {
    print(line)
    guard let path = ProcessInfo.processInfo.environment["BETTERTILE_PERF_OUT"] else { return }
    if !FileManager.default.fileExists(atPath: path) {
        try Data().write(to: URL(fileURLWithPath: path))
    }
    let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: Data((line + "\n").utf8))
}

@MainActor private func dividerBench(junction: Bool, feedback: ResizeFeedbackMode) throws -> [Double] {
    let system = FakeWindowSystem()
    let display = DisplayID(rawValue: "main")
    let screen = try #require(NSScreen.screens.first)
    let visible = CoordinateConverter.toTopLeft(screen.visibleFrame, mainScreenFrame: screen.frame)
    let bounds = BTRect(x: visible.minX, y: visible.minY, width: visible.size.width, height: visible.size.height)
    system.availableDisplays = [DisplaySnapshot(id: display, frame: bounds, visibleFrame: bounds, isMain: true)]
    let ids = (0..<4).map { WindowID(rawValue: "w\($0)") }
    let state: BentoLayoutState = junction
        ? BentoLayoutState(root: .partition(BentoPartition(
            axis: .vertical,
            first: .partition(BentoPartition(axis: .horizontal, first: .leaf(ids[0]), second: .leaf(ids[1]))),
            second: .partition(BentoPartition(axis: .horizontal, first: .leaf(ids[2]), second: .leaf(ids[3]))))))
        : BentoLayoutState(root: .partition(BentoPartition(axis: .vertical, first: .leaf(ids[0]), second: .leaf(ids[1]))))
    system.windows = state.placements(in: bounds).map {
        WindowSnapshot(id: $0.windowID, processIdentifier: 1, frame: $0.frame, displayID: display)
    }
    var configuration = BetterTileConfiguration()
    configuration.resizeFeedbackMode = feedback
    let ticks = ResizeDisplayLink(automatic: false)
    let controller = DividerOverlayController(coordinator: WindowCoordinator(system: system),
                                              configuration: configuration, displayTicks: ticks)
    controller.bentoStateProvider = { _ in state }
    let start = BTPoint(x: bounds.midX, y: bounds.midY)
    let interaction = try #require(DividerInteractionResolver.resolve(
        at: start, in: state.boundaries(in: bounds, displayID: display), hitWidth: 30, adjacencyTolerance: 6
    ))
    controller.beginGesture(interaction: interaction, at: start)
    defer { controller.hideAndCancel() }
    settle(CACurrentMediaTime()); phases = [:]
    var samples: [Double] = []
    for index in 0..<400 {
        let offset = 120 * sin(Double(index) / 25)
        let point = CGPoint(x: start.x + offset, y: screen.frame.maxY - (start.y + (junction ? offset * 0.6 : 0)))
        let began = CACurrentMediaTime()
        controller.drag(to: point)
        ticks.fire()
        settle(began)
        samples.append(CACurrentMediaTime() - began)
    }
    return Array(samples.dropFirst(20))
}

@MainActor private func tabbedBench() throws -> [Double] {
    let screen = try #require(NSScreen.screens.first)
    let visible = CoordinateConverter.toTopLeft(screen.visibleFrame, mainScreenFrame: screen.frame)
    let bounds = BTRect(x: visible.minX, y: visible.minY, width: visible.size.width, height: visible.size.height)
    let ids = (0..<12).map { WindowID(rawValue: "tab-\($0)") }
    var state = TabbedLayoutState(preset: .grid)
    state.reconcile(windowIDs: ids, removed: [], focused: ids[0])
    let anchor = NSPanel(contentRect: screen.visibleFrame, styleMask: [.borderless, .nonactivatingPanel],
                         backing: .buffered, defer: false)
    anchor.orderFrontRegardless()
    defer { anchor.orderOut(nil) }
    let numbers = Dictionary(uniqueKeysWithValues: state.selectedWindowIDs.map { ($0, anchor.windowNumber) })
    let overlay = TabbedOverlayController(orderPanel: { panel, mode, number in panel.order(mode, relativeTo: number) })
    defer { overlay.hide() }
    overlay.refresh(state: state, bounds: bounds, windows: [], selectedWindowNumbers: numbers,
                    curtainAnchorWindowNumber: anchor.windowNumber)
    settle(CACurrentMediaTime()); phases = [:]
    let divider = try #require(state.dividers(in: bounds).first?.branchID)
    var samples: [Double] = []
    for index in 0..<400 {
        let delta = 0.004 * (index % 50 < 25 ? 1 : -1)
        _ = state.adjustDivider(divider, by: delta, in: bounds)
        let began = CACurrentMediaTime()
        overlay.refreshResize(state: state, bounds: bounds)
        settle(began)
        samples.append(CACurrentMediaTime() - began)
    }
    return Array(samples.dropFirst(20))
}

@MainActor private func tabDragBench() throws -> [Double] {
    let screen = try #require(NSScreen.screens.first)
    let visible = CoordinateConverter.toTopLeft(screen.visibleFrame, mainScreenFrame: screen.frame)
    let bounds = BTRect(x: visible.minX, y: visible.minY, width: visible.size.width, height: visible.size.height)
    let ids = (0..<16).map { WindowID(rawValue: "drag-\($0)") }
    var state = TabbedLayoutState(preset: .grid)
    state.reconcile(windowIDs: ids, removed: [], focused: ids[0])
    let anchor = NSPanel(contentRect: screen.visibleFrame, styleMask: [.borderless, .nonactivatingPanel],
                         backing: .buffered, defer: false)
    anchor.orderFrontRegardless()
    defer { anchor.orderOut(nil) }
    let numbers = Dictionary(uniqueKeysWithValues: state.selectedWindowIDs.map { ($0, anchor.windowNumber) })
    let ticks = ResizeDisplayLink(automatic: false)
    var strips: [NSPanel] = []
    let overlay = TabbedOverlayController(dragTicks: ticks, orderPanel: { panel, mode, number in
        panel.order(mode, relativeTo: number)
        if mode == .above { strips.append(panel) }
    })
    defer { overlay.hide() }
    overlay.refresh(state: state, bounds: bounds, windows: [], selectedWindowNumbers: numbers,
                    curtainAnchorWindowNumber: anchor.windowNumber)
    settle(CACurrentMediaTime()); phases = [:]
    // The strip of the first pane: the strip panel whose top-left origin matches it.
    let frames = state.frames(in: bounds)
    let first = try #require(state.panes.first)
    let paneFrame = try #require(frames[first.id])
    let panel = try #require(strips.first { window in
        let tl = CoordinateConverter.toTopLeft(window.frame, mainScreenFrame: screen.frame)
        return abs(tl.minX - paneFrame.minX) < 1 && abs(tl.minY - paneFrame.minY) < 1
            && abs(window.frame.height - TabbedLayoutState.headerHeight) < 1
    })
    let view = try #require(panel.contentView as? TabbedPaneView)
    func event(_ type: NSEvent.EventType, _ point: NSPoint) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }
    let startX = 60.0
    view.mouseDown(with: event(.leftMouseDown, NSPoint(x: startX, y: 17)))
    var samples: [Double] = []
    for index in 0..<400 {
        // Sweep along the strip (reorder), then down into the pane content
        // (move/split targets) and back.
        let phase = Double(index % 200) / 200
        let x = startX + 10 + (phase < 0.5 ? phase * 2 : (1 - phase) * 2) * (paneFrame.size.width - 120)
        let y = 17 - (index % 200 > 100 ? Double(index % 100) * 4 : 0)
        let began = CACurrentMediaTime()
        view.mouseDragged(with: event(.leftMouseDragged, NSPoint(x: x, y: y)))
        ticks.fire() // Includes the production callback, presentation, and edge scrolling.
        settle(began)
        samples.append(CACurrentMediaTime() - began)
        // Validate completed work outside the timed sample, so an enqueue-only
        // benchmark cannot appear to improve performance by skipping the frame.
        let proxy = try #require(NSApp.windows.first {
            overlay.windowNumbers.contains($0.windowNumber) && $0.hasShadow
        })
        #expect(proxy.isVisible)
        #expect(abs(proxy.frame.minX - (paneFrame.minX + x - (startX - 32))) <= 1)
        #expect(view.content.previewOrder?.contains(ids[0]) == (y > 0))
    }
    overlay.hide()
    return Array(samples.dropFirst(20))
}

/// The refresh that follows a drop: tabs move between panes and the
/// selection changes, then strips, curtain and divider controls refresh.
@MainActor private func swapRefreshBench() throws -> [Double] {
    let screen = try #require(NSScreen.screens.first)
    let visible = CoordinateConverter.toTopLeft(screen.visibleFrame, mainScreenFrame: screen.frame)
    let bounds = BTRect(x: visible.minX, y: visible.minY, width: visible.size.width, height: visible.size.height)
    let ids = (0..<16).map { WindowID(rawValue: "swap-\($0)") }
    var state = TabbedLayoutState(preset: .grid)
    state.reconcile(windowIDs: ids, removed: [], focused: ids[0])
    let anchor = NSPanel(contentRect: screen.visibleFrame, styleMask: [.borderless, .nonactivatingPanel],
                         backing: .buffered, defer: false)
    anchor.orderFrontRegardless()
    defer { anchor.orderOut(nil) }
    let overlay = TabbedOverlayController(orderPanel: { panel, mode, number in panel.order(mode, relativeTo: number) })
    defer { overlay.hide() }
    func refresh() {
        let numbers = Dictionary(uniqueKeysWithValues: state.selectedWindowIDs.map { ($0, anchor.windowNumber) })
        overlay.refresh(state: state, bounds: bounds, windows: [], selectedWindowNumbers: numbers,
                        curtainAnchorWindowNumber: anchor.windowNumber)
    }
    refresh()
    settle(CACurrentMediaTime()); phases = [:]
    var samples: [Double] = []
    for index in 0..<200 {
        let panes = state.panes
        let source = panes[index % panes.count]
        let target = panes[(index + 1) % panes.count]
        if let moving = source.tabs.last, source.tabs.count > 1 { state.move(moving, to: target.id, at: 0) }
        if let pick = state.panes[(index + 2) % panes.count].tabs.first { state.select(pick) }
        let began = CACurrentMediaTime()
        refresh()
        settle(began)
        samples.append(CACurrentMediaTime() - began)
    }
    return Array(samples.dropFirst(20))
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["BETTERTILE_PERF_BENCH"] != nil
               && ProcessInfo.processInfo.environment["CI"] == nil,
               "Requires an explicit local interaction benchmark run."))
@MainActor func interactionBenchmark() throws {
    _ = NSApplication.shared
    let scenario = ProcessInfo.processInfo.environment["BETTERTILE_PERF_BENCH"] ?? "all"
    try report("== \(scenario)")
    try report(summary("tab drag frame (4 panes, 16 tabs)", try tabDragBench()))
    try reportPhases("tab drag frame")
    guard scenario != "tab-drag" else { return }
    try report(summary("swap/move refresh (4 panes, 16 tabs)", try swapRefreshBench())); try reportPhases("swap refresh")
    try report(summary("tabbed refreshResize (4 panes, 12 tabs)", try tabbedBench())); try reportPhases("tabbed")
    try report(summary("divider straight live", try dividerBench(junction: false, feedback: .live))); try reportPhases("straight live")
    try report(summary("divider straight ghost", try dividerBench(junction: false, feedback: .ghost))); try reportPhases("straight ghost")
    try report(summary("divider junction live", try dividerBench(junction: true, feedback: .live))); try reportPhases("junction live")
    try report(summary("divider junction ghost", try dividerBench(junction: true, feedback: .ghost))); try reportPhases("junction ghost")
}
