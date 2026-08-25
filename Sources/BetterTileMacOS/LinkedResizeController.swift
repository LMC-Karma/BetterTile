import AppKit
import BetterTileCore

/// Observes a user-driven resize gesture and keeps every window on the shared boundary connected.
@MainActor
public final class LinkedResizeController {
    public var configuration: BetterTileConfiguration {
        didSet {
            if !configuration.linkedResizeEnabled {
                eventTapHandoff.clear()
                endGesture()
            }
            syncMonitoring()
        }
    }
    public var layoutChangedHandler: ((DisplayID, [WindowID: BTRect]) -> Void)?
    public var isEnabledForDisplay: ((DisplayID) -> Bool)?

    private let coordinator: WindowCoordinator
    private var mouseDownMonitor: Any?
    private var dragMonitor: Any?
    private var mouseUpMonitor: Any?
    private var gestureEventSource = GestureEventSourceGate()
    private var eventTapHandoff = GestureEventSourceHandoff()
    private var baselineWindows: [WindowSnapshot] = []
    private var sourceID: WindowID?
    private var isLeftButtonDown = false
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
        eventTapHandoff.clear()
        removeMouseDownMonitor()
        removeGestureMonitors()
        endGesture()
    }

    /// Switching to the event tap waits for an active gesture to finish. The
    /// tap knows nothing about a gesture that began on the NSEvent monitors, so
    /// removing those monitors mid-gesture would strand it.
    public func setUsesSharedGestureEvents(_ enabled: Bool) {
        let wasUsingEventTap = gestureEventSource.usesEventTap
        guard eventTapHandoff.request(
            usesEventTap: enabled,
            currentlyUsesEventTap: wasUsingEventTap,
            isGestureActive: isGestureActive
        ) else { return }
        gestureEventSource.setUsesEventTap(enabled)
        if wasUsingEventTap, !enabled, isLeftButtonDown, sourceID == nil {
            beginGesture()
        }
        syncMonitoring()
    }

    private var isGestureActive: Bool {
        isLeftButtonDown || sourceID != nil
    }

    private func applyPendingEventTapHandoff() {
        guard eventTapHandoff.resolve() else { return }
        gestureEventSource.setUsesEventTap(true)
        syncMonitoring()
    }

    public func handleSharedGestureEvent(_ event: GlobalGestureEvent) {
        receive(event, from: .eventTap)
    }

    func allowsLinkedResize(for window: WindowSnapshot) -> Bool {
        configuration.linkedResizeEnabled
            && window.isEligible
            && !window.isFloating
            && configuration.applicationRules
                .rule(for: window.bundleIdentifier)
                .allowsDirectPlacement
            && isEnabledForDisplay?(window.displayID) == true
    }

    private func syncMonitoring() {
        if isStarted, configuration.linkedResizeEnabled {
            if gestureEventSource.usesEventTap {
                removeMouseDownMonitor()
                removeGestureMonitors()
            } else {
                installMouseDownMonitor()
                if sourceID != nil { installGestureMonitors() }
            }
        } else {
            removeMouseDownMonitor()
            removeGestureMonitors()
        }
    }

    private func installMouseDownMonitor() {
        guard !gestureEventSource.usesEventTap, mouseDownMonitor == nil else { return }
        mouseDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            Task { @MainActor in self?.receive(event, kind: .leftMouseDown) }
        }
    }

    private func installGestureMonitors() {
        guard !gestureEventSource.usesEventTap, dragMonitor == nil else { return }
        dragMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged) { [weak self] event in
            Task { @MainActor in self?.receive(event, kind: .leftMouseDragged) }
        }
        mouseUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
            Task { @MainActor in self?.receive(event, kind: .leftMouseUp) }
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

    private func receive(_ event: NSEvent, kind: GlobalGestureEventKind) {
        guard gestureEventSource.accepts(.nsEvent),
              let gestureEvent = GlobalGestureEvent(event, kind: kind)
        else { return }
        receive(gestureEvent, from: .nsEvent)
    }

    func receive(_ event: GlobalGestureEvent, from source: GestureEventSource) {
        guard gestureEventSource.accepts(source), event.button == 0 else { return }
        GestureEventLatency.record(event, from: source, consumer: "linkedResize")
        switch event.kind {
        case .leftMouseDown:
            isLeftButtonDown = true
            Task { @MainActor [weak self] in
                await Task.yield()
                guard self?.isLeftButtonDown == true, self?.sourceID == nil else { return }
                self?.beginGesture()
            }
        case .leftMouseDragged:
            if sourceID == nil, isLeftButtonDown { beginGesture() }
            continueGesture()
        case .leftMouseUp:
            isLeftButtonDown = false
            endGesture()
        }
    }

    private func beginGesture() {
        guard configuration.linkedResizeEnabled else {
            endGesture()
            return
        }
        do {
            guard let focused = try coordinator.system.focusedWindow(),
                  allowsLinkedResize(for: focused)
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

        guard coordinator.applyPlacements(result.placements, recordHistory: false).isApplied else { return }
        let frames = Dictionary(uniqueKeysWithValues: result.placements.map { ($0.windowID, $0.frame) })
        for index in baselineWindows.indices {
            if let frame = frames[baselineWindows[index].id] { baselineWindows[index].frame = frame }
        }
        layoutChangedHandler?(display.id, frames)
    }

    private func endGesture() {
        isLeftButtonDown = false
        baselineWindows = []
        sourceID = nil
        removeGestureMonitors()
        applyPendingEventTapHandoff()
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
