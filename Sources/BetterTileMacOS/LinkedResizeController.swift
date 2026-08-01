import AppKit
import BetterTileCore

/// Observes a user-driven resize gesture and keeps every window on the shared boundary connected.
@MainActor
public final class LinkedResizeController {
    public var configuration: BetterTileConfiguration {
        didSet {
            if !configuration.linkedResizeEnabled { endGesture() }
            syncMonitoring()
        }
    }
    public var layoutChangedHandler: ((DisplayID, [WindowID: BTRect]) -> Void)?
    public var isEnabledForDisplay: ((DisplayID) -> Bool)?

    private let coordinator: WindowCoordinator
    private var mouseDownMonitor: Any?
    private var dragMonitor: Any?
    private var mouseUpMonitor: Any?
    private var baselineWindows: [WindowSnapshot] = []
    private var sourceID: WindowID?
    private var isStarted = false

    public init(coordinator: WindowCoordinator, configuration: BetterTileConfiguration) {
        self.coordinator = coordinator
        self.configuration = configuration
    }

    public func start() {
        isStarted = true
        syncMonitoring()
    }

    public func stop() {
        isStarted = false
        removeMouseDownMonitor()
        removeGestureMonitors()
        endGesture()
    }

    private func syncMonitoring() {
        if isStarted, configuration.linkedResizeEnabled {
            installMouseDownMonitor()
        } else {
            removeMouseDownMonitor()
            removeGestureMonitors()
        }
    }

    private func installMouseDownMonitor() {
        guard mouseDownMonitor == nil else { return }
        mouseDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            Task { @MainActor in
                await Task.yield()
                self?.beginGesture()
            }
        }
    }

    private func installGestureMonitors() {
        guard dragMonitor == nil else { return }
        dragMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged) { [weak self] _ in
            Task { @MainActor in self?.continueGesture() }
        }
        mouseUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] _ in
            Task { @MainActor in self?.endGesture() }
        }
    }

    private func removeMouseDownMonitor() {
        if let mouseDownMonitor { NSEvent.removeMonitor(mouseDownMonitor) }
        mouseDownMonitor = nil
    }

    private func removeGestureMonitors() {
        for monitor in [dragMonitor, mouseUpMonitor].compactMap({ $0 }) {
            NSEvent.removeMonitor(monitor)
        }
        dragMonitor = nil
        mouseUpMonitor = nil
    }

    private func beginGesture() {
        guard configuration.linkedResizeEnabled else {
            endGesture()
            return
        }
        do {
            guard let focused = try coordinator.system.focusedWindow(),
                  focused.isEligible, !focused.isFloating,
                  isEnabledForDisplay?(focused.displayID) == true
            else {
                endGesture()
                return
            }
            baselineWindows = try coordinator.system.visibleWindows().filter {
                $0.displayID == focused.displayID && $0.isEligible && !$0.isFloating
            }
            guard baselineWindows.contains(where: { $0.id == focused.id }) else {
                endGesture()
                return
            }
            guard NSEvent.pressedMouseButtons & 1 == 1 else {
                endGesture()
                return
            }
            sourceID = focused.id
            installGestureMonitors()
        } catch {
            endGesture()
        }
    }

    private func continueGesture() {
        guard configuration.linkedResizeEnabled, let sourceID,
              let baseline = baselineWindows.first(where: { $0.id == sourceID }),
              isEnabledForDisplay?(baseline.displayID) == true,
              let current = try? coordinator.system.focusedWindow(), current.id == sourceID,
              let change = dominantResizeChange(from: baseline.frame, to: current.frame), abs(change.delta) >= 1,
              let display = coordinator.system.displays().first(where: { $0.id == baseline.displayID }),
              let result = LinkedResizeEngine(tolerance: configuration.adjacencyTolerance).resize(
                windowID: sourceID,
                edge: change.edge,
                delta: change.delta,
                windows: baselineWindows,
                bounds: display.visibleFrame
              )
        else { return }

        guard coordinator.applyPlacements(result.placements, recordHistory: false) else { return }
        let frames = Dictionary(uniqueKeysWithValues: result.placements.map { ($0.windowID, $0.frame) })
        for index in baselineWindows.indices {
            if let frame = frames[baselineWindows[index].id] { baselineWindows[index].frame = frame }
        }
        layoutChangedHandler?(display.id, frames)
    }

    private func endGesture() {
        baselineWindows = []
        sourceID = nil
        removeGestureMonitors()
    }

    private func dominantResizeChange(from before: BTRect, to after: BTRect) -> (edge: WindowEdge, delta: Double)? {
        let widthChange = after.size.width - before.size.width
        let heightChange = after.size.height - before.size.height
        guard abs(widthChange) >= 1 || abs(heightChange) >= 1 else { return nil }
        let candidates: [(WindowEdge, Double)] = [
            (.left, after.minX - before.minX),
            (.right, after.maxX - before.maxX),
            (.top, after.minY - before.minY),
            (.bottom, after.maxY - before.maxY),
        ]
        return candidates.max(by: { abs($0.1) < abs($1.1) })
    }
}
