import AppKit
import BetterTileCore
import Testing
@testable import BetterTileMacOS
@testable import BetterTileApp

private final class TabMoveGestureWorker: GestureEventTapWorking, @unchecked Sendable {
    let handler: @Sendable (GestureEventTapMessage) -> Void
    init(handler: @escaping @Sendable (GestureEventTapMessage) -> Void) { self.handler = handler }
    func start() -> Bool { true }
    func stop() {}
    func post(_ kind: GlobalGestureEventKind, at point: BTPoint) {
        handler(.event(GlobalGestureEvent(kind: kind, position: point, button: 0, modifiers: [], timestamp: 1)))
    }
}

@MainActor private func drainTabMoveEvents() async {
    for _ in 0..<3 {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
}

@Test(.appTestApplication) @MainActor func sharedTabStripPressDoesNotStartANativeWindowGestureUnderTheBar() async throws {
    _ = NSApplication.shared
    let system = FakeAppWindowSystem()
    var peer = system.windows[0]
    peer.id = WindowID(rawValue: "tab-move-peer")
    system.windows.append(peer)
    var worker: TabMoveGestureWorker?
    let monitor = SharedGestureEventMonitor(disabled: false, makeWorker: { handler in
        let result = TabMoveGestureWorker(handler: handler)
        worker = result
        return result
    })
    let model = makeModel(system: system, gestureEvents: monitor)
    defer { model.shutdown() }
    try #require(model.refreshPermission(recoverWindows: false))
    model.configuration.tabbedStripPresentation = .autoHide
    model.setActiveMode(.tabbed)
    try #require(await waitFor { model.activeTabbedState?.windowIDs.count == 2 })
    await model.tabbedFocusTask?.value
    try #require(monitor.isUsingEventTap)
    let tap = try #require(worker)
    let before = try #require(model.activeTabbedState)
    let source = system.windows[0]
    // The expanded bar overlaps the selected window's native title bar.
    let point = BTPoint(x: source.frame.minX + 100, y: source.frame.minY + 11)
    model.primaryButtonIsPressed = { true }
    model.appKitWindowGestureFilter = AppKitWindowGestureFilter(appKitWindowAtPoint: { _ in true })
    let sweeps = system.completeSweepCount
    let focusReads = system.focusedWindowReadCount
    tap.post(.leftMouseDown, at: point)
    tap.post(.leftMouseDragged, at: BTPoint(x: point.x + 100, y: point.y))
    await drainTabMoveEvents()
    #expect(model.activeTabbedState == before)
    #expect(system.completeSweepCount == sweeps)
    #expect(system.focusedWindowReadCount == focusReads)
    tap.post(.leftMouseUp, at: point)
    await drainTabMoveEvents()
    // A later press delivered to a native window still starts its drag.
    model.appKitWindowGestureFilter = AppKitWindowGestureFilter(appKitWindowAtPoint: { _ in false })
    tap.post(.leftMouseDown, at: point)
    tap.post(.leftMouseDragged, at: BTPoint(x: point.x + 100, y: point.y))
    await drainTabMoveEvents()
    #expect(model.activeTabbedState != before)
    tap.post(.leftMouseUp, at: point)
    await drainTabMoveEvents()
}
