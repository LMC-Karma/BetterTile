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
    public var rollbackFailureHandler: ((DisplayID, String?) -> Void)?
    public var layoutChangedHandler: ((DisplayID, [WindowID: BTRect]) -> Void)?
    /// Runs when a drag first resizes a window, not on every click. The
    /// gesture then re-reads its windows' minimums.
    public var gestureWillBeginHandler: (() -> Void)?
    private var hasStartedResizing = false
    public var isEnabledForDisplay: ((DisplayID) -> Bool)?

    private let coordinator: WindowCoordinator
    private let displayTicks: ResizeDisplayLink
    private var mouseDownMonitor: Any?
    private var dragMonitor: Any?
    private var mouseUpMonitor: Any?
    private var gestureEventSource = GestureEventSourceGate()
    private var eventTapHandoff = GestureEventSourceHandoff()
    private var baselineWindows: [WindowSnapshot] = []
    private var sourceID: WindowID?
    private var transaction: WindowFrameTransaction?
    private var isLeftButtonDown = false
    private var isStarted = false
    private var lifecycleGeneration: UInt64 = 0
    private var mouseDownMonitorGeneration: UInt64 = 0
    private var gestureMonitorGeneration: UInt64 = 0
    var addGlobalMonitor: (NSEvent.EventTypeMask, @escaping (NSEvent) -> Void) -> Any? = {
        NSEvent.addGlobalMonitorForEvents(matching: $0, handler: $1)
    }
    var removeEventMonitor: (Any) -> Void = { NSEvent.removeMonitor($0) }
    private var hasPendingDisplayUpdate = false

    public init(coordinator: WindowCoordinator, configuration: BetterTileConfiguration) {
        self.coordinator = coordinator
        self.configuration = configuration
        displayTicks = ResizeDisplayLink()
    }

    init(
        coordinator: WindowCoordinator,
        configuration: BetterTileConfiguration,
        displayTicks: ResizeDisplayLink
    ) {
        self.coordinator = coordinator
        self.configuration = configuration
        self.displayTicks = displayTicks
    }

    public func start() {
        isStarted = true
        syncMonitoring()
    }

    public func stop() {
        lifecycleGeneration &+= 1
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
        let generation = mouseDownMonitorGeneration
        guard !gestureEventSource.usesEventTap, mouseDownMonitor == nil else { return }
        mouseDownMonitor = addGlobalMonitor(.leftMouseDown) { [weak self] event in
            Task { @MainActor in
                guard let self, self.isStarted, self.mouseDownMonitorGeneration == generation else { return }
                self.receive(event, kind: .leftMouseDown)
            }
        }
    }

    private func installGestureMonitors() {
        let generation = gestureMonitorGeneration
        guard !gestureEventSource.usesEventTap, dragMonitor == nil else { return }
        dragMonitor = addGlobalMonitor(.leftMouseDragged) { [weak self] event in
            Task { @MainActor in
                guard let self, self.isStarted, self.gestureMonitorGeneration == generation else { return }
                self.receive(event, kind: .leftMouseDragged)
            }
        }
        mouseUpMonitor = addGlobalMonitor(.leftMouseUp) { [weak self] event in
            Task { @MainActor in
                guard let self, self.isStarted, self.gestureMonitorGeneration == generation else { return }
                self.receive(event, kind: .leftMouseUp)
            }
        }
    }

    private func removeMouseDownMonitor() {
        mouseDownMonitorGeneration &+= 1
        if let mouseDownMonitor { removeEventMonitor(mouseDownMonitor) }
        mouseDownMonitor = nil
    }

    private func removeGestureMonitors() {
        gestureMonitorGeneration &+= 1
        for monitor in [dragMonitor, mouseUpMonitor].compactMap({ $0 }) {
            removeEventMonitor(monitor)
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
            let generation = lifecycleGeneration
            Task { @MainActor [weak self] in
                await Task.yield()
                guard self?.lifecycleGeneration == generation, self?.isLeftButtonDown == true, self?.sourceID == nil else { return }
                self?.beginGesture()
            }
        case .leftMouseDragged:
            if sourceID == nil, isLeftButtonDown { beginGesture() }
            hasPendingDisplayUpdate = sourceID != nil
        case .leftMouseUp:
            isLeftButtonDown = false
            // A display tick has usually consumed the last sample already.
            // Release still validates and applies the final source frame.
            if sourceID != nil {
                hasPendingDisplayUpdate = false
                if !continueGesture(validateParticipants: true) { resendFinalPlacements() }
            }
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
                $0.displayID == focused.displayID && allowsLinkedResize(for: $0)
            }
            guard baselineWindows.contains(where: { $0.id == focused.id }) else {
                endGesture()
                return
            }
            sourceID = focused.id
            installGestureMonitors()
            displayTicks.start(screen: screen(for: focused.displayID), maximumFramesPerSecond: 60) { [weak self] in
                self?.displayTick()
            }
        } catch {
            endGesture()
        }
    }

    func displayTick() {
        guard hasPendingDisplayUpdate else { return }
        hasPendingDisplayUpdate = false
        continueGesture(validateParticipants: false)
    }

    /// Resends the last requested neighbor frames when release brings no new
    /// source change. An application may have ignored the earlier request.
    private func resendFinalPlacements() {
        guard var transaction, transaction.hasLiveChanges else { return }
        _ = coordinator.applyLive(
            transaction: &transaction,
            placements: transaction.proposedPlacements,
            validateParticipants: true
        )
        self.transaction = transaction
        if transaction.hasDegradedApply { endGesture() }
    }

    @discardableResult
    private func continueGesture(validateParticipants: Bool) -> Bool {
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
        else { return false }

        if !hasStartedResizing {
            // The first real edge movement starts a resize. Forget minimums
            // learned from old refusals, read fresh ones, and solve again.
            hasStartedResizing = true
            gestureWillBeginHandler?()
            if let targeted = coordinator.system as? any TargetedWindowSystem,
               let fresh = try? targeted.windowSnapshots(ids: Set(baselineWindows.map(\.id))) {
                let constraints = Dictionary(fresh.map { ($0.id, $0.constraints) }, uniquingKeysWith: { first, _ in first })
                for index in baselineWindows.indices {
                    if let value = constraints[baselineWindows[index].id] { baselineWindows[index].constraints = value }
                }
            }
            return continueGesture(validateParticipants: validateParticipants)
        }
        let peerPlacements = result.placements.filter { $0.windowID != sourceID }
        guard !peerPlacements.isEmpty else { return false }
        var transaction: WindowFrameTransaction
        if let active = self.transaction {
            transaction = active
        } else {
            guard case let .started(started) = coordinator.beginTransaction(
                windowIDs: Set(peerPlacements.map(\.windowID))
            ) else { return false }
            transaction = started
        }
        guard coordinator.applyLive(
            transaction: &transaction,
            placements: peerPlacements,
            validateParticipants: validateParticipants
        ).isApplied else {
            self.transaction = transaction
            if transaction.hasDegradedApply { endGesture() }
            return false
        }
        self.transaction = transaction
        let frames = Dictionary(uniqueKeysWithValues: result.placements.map { ($0.windowID, $0.frame) })
        for index in baselineWindows.indices {
            if let frame = frames[baselineWindows[index].id] { baselineWindows[index].frame = frame }
        }
        layoutChangedHandler?(display.id, frames)
        return true
    }

    private func endGesture() {
        hasStartedResizing = false
        var rollbackFailure: (DisplayID, String?)?
        if let transaction {
            if transaction.hasDegradedApply {
                let outcome = coordinator.cancel(transaction: transaction)
                if !outcome.isApplied, let displayID = baselineWindows.first?.displayID {
                    if case let .degraded(reason) = outcome { rollbackFailure = (displayID, reason) }
                    else if case let .failed(reason) = outcome { rollbackFailure = (displayID, reason) }
                }
            } else {
                coordinator.finishLive(transaction: transaction, recordHistory: false)
            }
        }
        isLeftButtonDown = false
        baselineWindows = []
        sourceID = nil
        transaction = nil
        hasPendingDisplayUpdate = false
        displayTicks.stop()
        removeGestureMonitors()
        applyPendingEventTapHandoff()
        if let (displayID, reason) = rollbackFailure { rollbackFailureHandler?(displayID, reason) }
    }

    private func screen(for displayID: DisplayID) -> NSScreen? {
        NSScreen.screens.first { screen in
            let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            return DisplayID(rawValue: number?.stringValue ?? String(screen.hash)) == displayID
        } ?? NSScreen.main
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
