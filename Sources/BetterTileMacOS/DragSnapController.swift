import AppKit
import BetterTileCore
import os

public enum BentoSwapDragRegion {
    private static let maximumToolbarDepth = 80.0

    public static func isTitleBarStart(_ point: BTPoint, in frame: BTRect) -> Bool {
        point.x >= frame.minX + 8
            && point.x <= frame.maxX - 8
            && point.y >= frame.minY + 8
            && point.y <= min(frame.maxY - 8, frame.minY + maximumToolbarDepth)
    }
}

/// Resolves the window whose title bar is actually under the pointer. The
/// Accessibility focused window can lag behind a global mouse-down when the
/// user starts dragging an inactive window.
public enum BentoDragWindowResolver {
    public static func window(
        at point: BTPoint,
        focusedWindow: WindowSnapshot?,
        visibleWindows: [WindowSnapshot]
    ) -> WindowSnapshot? {
        let candidates = visibleWindows.filter {
            $0.isEligible && BentoSwapDragRegion.isTitleBarStart(point, in: $0.frame)
        }
        if let focusedWindow,
           let focusedCandidate = candidates.first(where: { $0.id == focusedWindow.id }) {
            return focusedCandidate
        }
        return candidates.min {
            let leftArea = $0.frame.size.width * $0.frame.size.height
            let rightArea = $1.frame.size.width * $1.frame.size.height
            return leftArea == rightArea ? $0.id < $1.id : leftArea < rightArea
        }
    }
}

struct WindowDragGate {
    private var candidate: WindowSnapshot?
    private var activeWindowID: WindowID?

    var candidateWindowID: WindowID? { candidate?.id }
    var candidateWindow: WindowSnapshot? { candidate }
    var isTracking: Bool { candidate != nil }

    mutating func begin(with window: WindowSnapshot) {
        candidate = window
        activeWindowID = nil
    }

    mutating func activate(with window: WindowSnapshot?, movementTolerance: Double = 1) -> WindowID? {
        if let activeWindowID { return activeWindowID }
        guard let candidate, let window, window.id == candidate.id,
              abs(window.frame.minX - candidate.frame.minX) > movementTolerance
                || abs(window.frame.minY - candidate.frame.minY) > movementTolerance
        else { return nil }
        activeWindowID = candidate.id
        return candidate.id
    }

    mutating func reset() {
        candidate = nil
        activeWindowID = nil
    }
}

enum WindowExposureRetry {
    enum Attempt {
        case retry
        case resolved
        case stop
    }

    @MainActor
    static func run(
        maximumAttempts: Int = 20,
        delay: Duration = .milliseconds(20),
        attempt: @MainActor () -> Attempt
    ) async -> Bool {
        for index in 0..<maximumAttempts {
            switch attempt() {
            case .resolved: return true
            case .stop: return false
            case .retry where index + 1 < maximumAttempts:
                try? await Task.sleep(for: delay)
            case .retry:
                break
            }
        }
        return false
    }
}

@MainActor
public final class DragSnapController {
    public var configuration: BetterTileConfiguration {
        didSet {
            if !configuration.snappingEnabled {
                eventTapHandoff.clear()
                cancel()
            }
            syncMonitoring()
        }
    }
    public var bentoDragBeganHandler: ((DisplayID, WindowID, BTRect) -> Bool)?
    /// Plans a Bento or Tabbed drop for the overlay. Nil means the drag is no
    /// longer current, which the overlay shows as invalid.
    public var bentoPreviewHandler: ((DisplayID, WindowID, BentoDragOutcome) -> LayoutDropPreview?)?
    public var isTabbedMember: ((WindowID) -> Bool)?
    /// The Tabbed tab strip or empty pane under the pointer, where the
    /// dragged window joins a pane as a tab.
    public var tabbedDropZoneProvider: ((DisplayID, BTPoint, WindowID) -> TabbedDropZone?)?
    public var bentoDragEndedHandler: ((DisplayID, WindowID, LayoutDragEnd) -> Void)?
    public var activeModeProvider: ((DisplayID) -> LayoutMode?)?
    public var bentoStateProvider: ((DisplayID) -> BentoLayoutState?)?
    public var gestureEndedHandler: (() -> Void)?
    public var actionResultHandler: ((DisplayID, Bool, String?) -> Void)?
    /// Whether the left mouse button is down. Tests replace this so the
    /// physical button cannot start or hold a gesture.
    public var primaryButtonIsPressed: () -> Bool = { NSEvent.pressedMouseButtons & 1 == 1 }

    public var isGestureActive: Bool {
        dragGate.isTracking
            || draggedWindowID != nil
            || pendingRestoredWindowID != nil
            || pendingStageManagerWindowID != nil
    }

    private let coordinator: WindowCoordinator
    private var mouseDownMonitor: Any?
    private var dragMonitor: Any?
    private var mouseUpMonitor: Any?
    private var escapeMonitor: Any?
    private var gestureEventSource = GestureEventSourceGate()
    private var eventTapHandoff = GestureEventSourceHandoff()
    /// The drop the overlay shows: the only decision. Release commits it and
    /// does not evaluate the release point again.
    private(set) var dropTarget: WindowDropTarget? {
        didSet { if dropTarget != nil { showedDropTarget = true } }
    }
    /// Whether this gesture showed any drop. A fast flick shows none, so its
    /// release evaluates the release point once.
    private var showedDropTarget = false
    private var dragGate = WindowDragGate()
    private var draggedWindowID: WindowID?
    private var snapSourceWindow: WindowSnapshot?
    private var bentoDragDisplayID: DisplayID?
    private var bentoHover = BentoDropHoverState()
    private var bentoHoverPreviewTask: Task<Void, Never>?
    private var presentedBentoCandidate: BentoHoverCandidate?
    private var presentedTabbedZone: TabbedDropZone?
    private var preview: SnapPreviewPanel?
    private var bentoPreview: BentoDropPreviewController?
    private var restoredDragTask: Task<Void, Never>?
    private var pendingRestoredWindowID: WindowID?
    private var pendingStageManagerWindowID: CGWindowID?
    private var mouseDownPoint: BTPoint?
    private var resolvedDragTarget = false
    /// A drag sample arrived since the press, even one suppressed by the
    /// snap modifiers.
    private var sawDragSample = false
    private var isStarted = false
    private var mouseDownMonitorGeneration: UInt64 = 0
    private var fallbackMonitorGeneration: UInt64 = 0
    private var escapeMonitorGeneration: UInt64 = 0
    var addGlobalMonitor: (NSEvent.EventTypeMask, @escaping (NSEvent) -> Void) -> Any? = {
        NSEvent.addGlobalMonitorForEvents(matching: $0, handler: $1)
    }
    var removeEventMonitor: (Any) -> Void = { NSEvent.removeMonitor($0) }
    private let displayTicks: ResizeDisplayLink
    /// The newest drag sample not yet evaluated. A high-rate pointer sends
    /// events faster than the display can show a new preview.
    private var pendingDragEvent: GlobalGestureEvent?
    private(set) var pacingDisplayID: DisplayID?

    private static let bentoCueArmDelay = 0.12
    private static let bentoReflowPreviewDelay = 0.22
    private static let unavailableDropReason = "The layout changed during the drag. Try again."
    private static let minimumSizeDoesNotFitReason = "The window’s minimum size does not fit in that snap area."

    public convenience init(coordinator: WindowCoordinator, configuration: BetterTileConfiguration) {
        self.init(coordinator: coordinator, configuration: configuration, displayTicks: ResizeDisplayLink())
    }

    init(coordinator: WindowCoordinator, configuration: BetterTileConfiguration, displayTicks: ResizeDisplayLink) {
        self.coordinator = coordinator
        self.configuration = configuration
        self.displayTicks = displayTicks
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
        cancel()
    }

    /// Switching to the event tap waits for an active gesture to finish. The
    /// tap knows nothing about a gesture that began on the NSEvent monitors, so
    /// removing those monitors mid-gesture would strand it.
    public func setUsesSharedGestureEvents(_ enabled: Bool) {
        guard eventTapHandoff.request(
            usesEventTap: enabled,
            currentlyUsesEventTap: gestureEventSource.usesEventTap,
            isGestureActive: isGestureActive
        ) else { return }
        gestureEventSource.setUsesEventTap(enabled)
        syncMonitoring()
    }

    private func applyPendingEventTapHandoff() {
        guard eventTapHandoff.resolve() else { return }
        gestureEventSource.setUsesEventTap(true)
        syncMonitoring()
    }

    public func handleSharedGestureEvent(_ event: GlobalGestureEvent) {
        receive(event, from: .eventTap)
    }

    private func syncMonitoring() {
        if isStarted, configuration.snappingEnabled {
            if gestureEventSource.usesEventTap {
                removeMouseDownMonitor()
                removeFallbackGestureMonitors()
            } else {
                installMouseDownMonitor()
                if isGestureActive { installGestureMonitors() }
            }
        } else {
            removeMouseDownMonitor()
            removeGestureMonitors()
        }
    }

    private func installMouseDownMonitor() {
        let generation = mouseDownMonitorGeneration
        guard !gestureEventSource.usesEventTap, mouseDownMonitor == nil else { return }
        mouseDownMonitor = addGlobalMonitor([.leftMouseDown]) { [weak self] event in
            Task { @MainActor in
                guard let self, self.isStarted, self.mouseDownMonitorGeneration == generation else { return }
                self.receive(event, kind: .leftMouseDown)
            }
        }
    }

    private func installGestureMonitors() {
        let generation = fallbackMonitorGeneration
        if !gestureEventSource.usesEventTap, dragMonitor == nil {
            dragMonitor = addGlobalMonitor([.leftMouseDragged]) { [weak self] event in
                Task { @MainActor in
                    guard let self, self.isStarted, self.fallbackMonitorGeneration == generation else { return }
                    self.receive(event, kind: .leftMouseDragged)
                }
            }
            mouseUpMonitor = addGlobalMonitor([.leftMouseUp]) { [weak self] event in
                Task { @MainActor in
                    guard let self, self.isStarted, self.fallbackMonitorGeneration == generation else { return }
                    self.receive(event, kind: .leftMouseUp)
                }
            }
        }
        if escapeMonitor == nil {
            let generation = escapeMonitorGeneration
            escapeMonitor = addGlobalMonitor([.keyDown]) { [weak self] event in
                guard event.keyCode == 53 else { return }
                Task { @MainActor in
                    guard let self, self.isStarted, self.escapeMonitorGeneration == generation else { return }
                    self.cancel()
                }
            }
        }
    }

    private func removeMouseDownMonitor() {
        mouseDownMonitorGeneration &+= 1
        if let mouseDownMonitor { removeEventMonitor(mouseDownMonitor) }
        mouseDownMonitor = nil
    }

    private func removeGestureMonitors() {
        escapeMonitorGeneration &+= 1
        removeFallbackGestureMonitors()
        if let escapeMonitor { removeEventMonitor(escapeMonitor) }
        escapeMonitor = nil
    }

    private func removeFallbackGestureMonitors() {
        fallbackMonitorGeneration &+= 1
        if let dragMonitor { removeEventMonitor(dragMonitor) }
        if let mouseUpMonitor { removeEventMonitor(mouseUpMonitor) }
        dragMonitor = nil
        mouseUpMonitor = nil
    }

    public func cancel() {
        finishActiveBentoDrag(end: .restore)
        clear()
        gestureEndedHandler?()
    }

    /// A window dragged out of the Dock can appear after the global mouse-down
    /// event. Retry briefly from the Accessibility restore notification so the
    /// user does not need to generate extra drag events by shaking the mouse.
    public func prepareForRestoredWindowDrag(windowID: WindowID) {
        guard configuration.snappingEnabled, primaryButtonIsPressed() else { return }
        installGestureMonitors()
        pendingRestoredWindowID = windowID
        pendingStageManagerWindowID = nil
        restoredDragTask?.cancel()
        restoredDragTask = Task { @MainActor [weak self] in
            _ = await WindowExposureRetry.run {
                guard let self, !Task.isCancelled,
                      self.primaryButtonIsPressed()
                else { return .stop }
                return self.beginPendingRestoredWindowDrag(windowID: windowID)
                    ? .resolved
                    : .retry
            }
        }
    }

    /// Tabbed desktops run on Bento, so their windows use Bento drops.
    private func usesBentoDrops(_ displayID: DisplayID) -> Bool {
        let mode = activeModeProvider?(displayID)
        return mode == .bento || mode == .tabbed
    }

    func allowsBentoDrag(for window: WindowSnapshot) -> Bool {
        // A new one-window Bento desktop has no tree yet. Keep ordinary
        // drag snapping available until there is a layout to freeze.
        bentoStateProvider?(window.displayID)?.root != nil
            && !window.isFloating && configuration.applicationRules
                .rule(for: window.bundleIdentifier)
                .allowsBentoParticipation
    }

    private func receive(_ event: NSEvent, kind: GlobalGestureEventKind) {
        guard gestureEventSource.accepts(.nsEvent),
              let gestureEvent = GlobalGestureEvent(event, kind: kind)
        else { return }
        receive(gestureEvent, from: .nsEvent)
    }

    func receive(_ event: GlobalGestureEvent, from source: GestureEventSource) {
        guard gestureEventSource.accepts(source), event.button == 0 else { return }
        GestureEventLatency.record(event, from: source, consumer: "dragSnap")
        switch event.kind {
        case .leftMouseDown:
            guard Self.acceptsMouseDown(
                from: source,
                pressedMouseButtons: primaryButtonIsPressed() ? 1 : 0
            ) else { return }
            mousePressed(event)
        case .leftMouseDragged where isGestureActive:
            sawDragSample = true
            // The first sample resolves the dragged window at once. Later
            // samples keep only the newest and run once per display frame.
            if resolvedDragTarget {
                pendingDragEvent = event
            } else {
                mouseDragged(event)
            }
            if isGestureActive { startDisplayTicks(at: event.position) }
        case .leftMouseUp where isGestureActive:
            // A press and release with no drag sample is a click. It starts
            // no drag: in Tabbed, a drag tears the tab from its group and the
            // release places the group again, which activates the window and
            // closes any popup the click opened.
            mouseReleased(event, evaluatesRelease: sawDragSample || resolvedDragTarget)
        case .leftMouseDragged, .leftMouseUp: return
        }
    }

    static func acceptsMouseDown(
        from source: GestureEventSource,
        pressedMouseButtons: Int
    ) -> Bool {
        source == .eventTap || pressedMouseButtons & 1 == 1
    }

    var hasPendingDragSample: Bool { pendingDragEvent != nil }

    private func startDisplayTicks(at point: BTPoint) {
        guard let display = PointerDisplay.display(at: point, in: coordinator.system.displays()),
              pacingDisplayID != display.id else { return }
        pacingDisplayID = display.id
        let screen = NSScreen.screens.first { screen in
            let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            return DisplayID(rawValue: number?.stringValue ?? String(screen.hash)) == display.id
        } ?? NSScreen.main
        displayTicks.start(screen: screen) { [weak self] in self?.displayTick() }
    }

    func displayTick() {
        guard let event = pendingDragEvent else { return }
        pendingDragEvent = nil
        mouseDragged(event)
    }

    private func mousePressed(_ event: GlobalGestureEvent) {
        dragGate.reset()
        sawDragSample = false
        draggedWindowID = nil
        guard configuration.snappingEnabled,
              !event.modifiers.isSuperset(of: configuration.snapSuppressionModifiers)
        else { return }
        let point = event.position
        mouseDownPoint = point
        guard let window = windowUnderTitleBar(at: point) else {
            guard let system = coordinator.system as? AccessibilityWindowSystem,
                  let exactWindowID = system.stageManagerWindowID(at: point)
            else {
                mouseDownPoint = nil
                return
            }
            prepareForStageManagerDrag(exactWindowID: exactWindowID)
            return
        }
        // Ignore Everywhere means no BetterTile feature places this window,
        // drag snapping included.
        guard configuration.applicationRules
            .rule(for: window.bundleIdentifier)
            .allowsDirectPlacement
        else {
            mouseDownPoint = nil
            return
        }
        dragGate.begin(with: window)
        installGestureMonitors()
    }

    private func mouseDragged(_ event: GlobalGestureEvent) {
        guard configuration.snappingEnabled else { clearTargets(); return }
        let activeModifiers = event.modifiers
        guard !activeModifiers.isSuperset(of: configuration.snapSuppressionModifiers) else { clearTargets(); return }
        guard let mainFrame = NSScreen.screens.first?.frame else { return }
        let point = event.position
        guard pendingRestoredWindowID == nil, pendingStageManagerWindowID == nil else {
            clearTargets()
            return
        }
        if !resolvedDragTarget {
            resolvedDragTarget = true
            guard let window = resolvedWindowForFirstDrag(),
                  configuration.applicationRules
                    .rule(for: window.bundleIdentifier)
                    .allowsDirectPlacement
            else {
                clear()
                return
            }
            if window.id != dragGate.candidateWindowID {
                dragGate.begin(with: window)
            }
            if usesBentoDrops(window.displayID),
               allowsBentoDrag(for: window) {
                guard bentoDragBeganHandler?(window.displayID, window.id, dragGate.candidateWindow?.frame ?? window.frame) == true else {
                    clear()
                    return
                }
                bentoDragDisplayID = window.displayID
            }
        }
        if draggedWindowID == nil {
            guard let candidateWindowID = dragGate.candidateWindowID,
                  let snapshot = windowSnapshot(id: candidateWindowID),
                  let windowID = dragGate.activate(with: snapshot)
            else {
                clearTargets()
                return
            }
            draggedWindowID = windowID
            snapSourceWindow = snapshot
        }
        if bentoDragDisplayID == nil, let draggedWindowID, isTabbedMember?(draggedWindowID) == true {
            clearTargets()
            return
        }
        // The display under the pointer decides the drop. The dragged
        // window's center can already be on the neighbouring display.
        guard let display = PointerDisplay.display(at: point, in: coordinator.system.displays()) else {
            clearTargets()
            return
        }
        if let bentoDragDisplayID, display.id != bentoDragDisplayID {
            clearTargets()
            return
        }
        let snapTarget = bentoDragDisplayID == nil ? nil : SnapZoneDetector().target(
               at: point,
               display: display,
               snapAreas: configuration.snapAreaBindings,
               window: snapSourceWindow
           )
        // A tab strip under the pointer wins over a snap area, except at the
        // screen edge itself (the edge band): without a permanent menu bar,
        // the top strips reach the top edge, which must still snap. Farther
        // inside, a strip wins over a corner area. An empty pane wins only
        // outside a snap area, like a pane center.
        let edgeBand = SnapZoneDetector().edgeActivationDistance
        let insideEdgeBands = display.frame.insetBy(dx: edgeBand, dy: edgeBand).contains(point)
        if let draggedWindowID, bentoDragDisplayID != nil, activeModeProvider?(display.id) == .tabbed,
           let zone = tabbedDropZoneProvider?(display.id, point, draggedWindowID),
           snapTarget == nil || (zone.indicator != nil && insideEdgeBands) {
            showTabbedDropZone(zone, sourceWindowID: draggedWindowID, displayID: display.id, mainScreenFrame: mainFrame)
            return
        }
        presentedTabbedZone = nil
        let bentoPlacements = bentoDragDisplayID != nil && usesBentoDrops(display.id)
            ? bentoStateProvider?(display.id)?.placements(in: display.visibleFrame) ?? [] : []
        let hoveredPlacement = draggedWindowID.flatMap { source in
            bentoPlacements.first { $0.windowID != source && $0.frame.contains(point) }
        }
        let hoveredPosition = hoveredPlacement.map { placement in
            BentoPaneDropPosition.resolve(
                point,
                in: placement.frame,
                retaining: bentoHover.candidate?.targetWindowID == placement.windowID
                    ? bentoHover.candidate?.position
                    : nil,
                edgeFraction: activeModifiers.contains(.option) ? 0.2 : 0.15
            )
        }
        // A snap area that wins over the pane edge under it is the drop, so
        // the overlay shows the snap and not a pane cue.
        if let draggedWindowID, let placement = hoveredPlacement, let position = hoveredPosition,
           !BentoDropDecision.snapWins(snapTarget, over: position) {
            let baselineFrames = Dictionary(
                uniqueKeysWithValues: bentoPlacements.map {
                    ($0.windowID, $0.frame)
                }
            )
            let now = ProcessInfo.processInfo.systemUptime
            let candidate = BentoHoverCandidate(
                displayID: display.id,
                targetWindowID: placement.windowID,
                position: position
            )
            let changed = bentoHover.observe(
                candidate,
                competingSnapTarget: snapTarget,
                at: now
            )
            let hoverDelay = position == .center ? configuration.bentoSwapHoverDelay : 0
            let waitingSnapTarget = bentoHover.armedCandidate(at: now, delay: hoverDelay) == nil && hoverDelay > 0
                ? snapTarget : nil
            // A waiting snap preview shows the snap's plan; the pane cue appears
            // only when it arms.
            let retainsSnapWireframes = waitingSnapTarget != nil
            if changed {
                bentoHoverPreviewTask?.cancel()
                bentoHoverPreviewTask = nil
                presentedBentoCandidate = nil
                preview?.hide()
                dropTarget = nil
                if !retainsSnapWireframes {
                    activeBentoPreview.showCue(
                        targetFrame: placement.frame,
                        position: position,
                        phase: .tracking,
                        seam: nil,
                        mainScreenFrame: mainFrame
                    )
                }
                bentoHoverPreviewTask = Task { @MainActor [weak self] in
                    // The armed cue is the drop, so it never arms before the
                    // hover delay that makes the drop real.
                    let cueDelay = max(Self.bentoCueArmDelay, hoverDelay)
                    try? await Task.sleep(
                        for: .milliseconds(Int(cueDelay * 1_000))
                    )
                    guard let self, !Task.isCancelled,
                          self.bentoHover.candidate == candidate
                    else { return }
                    let placements = self.armBentoCue(
                        candidate: candidate,
                        sourceWindowID: draggedWindowID,
                        targetFrame: placement.frame,
                        sourceOriginalFrame: baselineFrames[draggedWindowID],
                        mainScreenFrame: mainFrame
                    )
                    guard let placements else { return }
                    try? await Task.sleep(
                        for: .milliseconds(Int(
                            max(0, Self.bentoReflowPreviewDelay - cueDelay) * 1_000
                        ))
                    )
                    guard !Task.isCancelled,
                          self.bentoHover.candidate == candidate
                    else { return }
                    self.showBentoReflow(
                        candidate: candidate,
                        sourceWindowID: draggedWindowID,
                        placements: placements,
                        baselineFrames: baselineFrames
                    )
                }
            } else if presentedBentoCandidate != candidate, !retainsSnapWireframes {
                activeBentoPreview.showCue(
                    targetFrame: placement.frame,
                    position: position,
                    phase: .tracking,
                    seam: nil,
                    mainScreenFrame: mainFrame
                )
            }
            if let snapTarget = waitingSnapTarget {
                showSnapPreview(snapTarget, displayID: display.id, mainScreenFrame: mainFrame)
            } else {
                preview?.hide()
                // A cue that has not armed yet shows no drop.
                if presentedBentoCandidate != candidate { dropTarget = nil }
            }
            return
        }
        bentoHoverPreviewTask?.cancel()
        bentoHoverPreviewTask = nil
        presentedBentoCandidate = nil
        bentoHover.clear()
        let target = snapTarget ?? SnapZoneDetector().target(
                at: point,
                display: display,
                snapAreas: configuration.snapAreaBindings,
                window: snapSourceWindow
        )
        if let target {
            showSnapPreview(target, displayID: display.id, mainScreenFrame: mainFrame)
        } else {
            preview?.hide()
            bentoPreview?.hide()
            dropTarget = nil
        }
    }

    /// Shows a snap area's preview and records it as the drop. An ordinary
    /// snap's target frame already includes the window's known minimum size,
    /// so the preview shows the frame the window will really take. A Bento or
    /// Tabbed snap shows the plan that release commits.
    private func showSnapPreview(_ target: SnapTarget, displayID: DisplayID, mainScreenFrame: CGRect) {
        guard bentoDragDisplayID != nil else {
            bentoPreview?.hide()
            // A minimum larger than the display leaves a clamped frame the
            // window cannot take. That is not a drop.
            if let window = snapSourceWindow, window.constraints.isResizable,
               !SnapFrameFit.holds(target.frame, minimumSize: window.constraints.minimumSize) {
                showPreview(frame: target.frame, invalid: true, mainScreenFrame: mainScreenFrame)
                dropTarget = WindowDropTarget(displayID: displayID, drop: .invalid(reason: Self.minimumSizeDoesNotFitReason))
                return
            }
            showPreview(frame: target.frame, mainScreenFrame: mainScreenFrame)
            dropTarget = WindowDropTarget(displayID: displayID, drop: .snap(target))
            return
        }
        guard let source = draggedWindowID, let action = target.action else {
            preview?.hide()
            bentoPreview?.hide()
            dropTarget = nil
            return
        }
        let prepared = recordLayoutPreview(
            bentoPreviewHandler?(displayID, source, .snap(action: action, frame: target.frame)),
            displayID: displayID
        )
        guard let prepared,
              let sourceFrame = prepared.placements.first(where: { $0.windowID == source })?.frame else {
            bentoPreview?.hide()
            if prepared != nil {
                dropTarget = WindowDropTarget(displayID: displayID, drop: .invalid(reason: Self.unavailableDropReason))
            }
            showPreview(frame: target.frame, invalid: true, mainScreenFrame: mainScreenFrame)
            return
        }
        showPreview(frame: sourceFrame, mainScreenFrame: mainScreenFrame)
        let baseline = Dictionary(uniqueKeysWithValues:
            (bentoStateProvider?(displayID)?.placements(in: coordinator.system.displays()
                .first(where: { $0.id == displayID })?.visibleFrame ?? target.frame) ?? []).map { ($0.windowID, $0.frame) })
        activeBentoPreview.showSnapWireframes(placements: BentoDragPreview.changedPlacements(
            prepared.placements, baselineFrames: baseline, excluding: source), baselineFrames: baseline)
    }

    /// Shows and records a Tabbed tab drop at once: a strip or empty pane is
    /// an exact target and needs no hover delay.
    private func showTabbedDropZone(
        _ zone: TabbedDropZone, sourceWindowID: WindowID, displayID: DisplayID, mainScreenFrame: CGRect
    ) {
        bentoHoverPreviewTask?.cancel()
        bentoHoverPreviewTask = nil
        presentedBentoCandidate = nil
        bentoHover.clear()
        preview?.hide()
        guard zone != presentedTabbedZone else { return }
        presentedTabbedZone = zone
        // A pane cue's landing and wireframes belong to another drop.
        bentoPreview?.hide()
        let prepared = recordLayoutPreview(
            bentoPreviewHandler?(displayID, sourceWindowID, .tab(paneID: zone.paneID, index: zone.index)),
            displayID: displayID
        )
        activeBentoPreview.showCue(
            targetFrame: zone.paneFrame,
            position: .center,
            phase: prepared == nil ? .invalid : .armed,
            seam: nil,
            label: prepared.flatMap(Self.tabCueLabel) ?? invalidReason,
            insertion: prepared == nil ? nil : zone.indicator,
            mainScreenFrame: mainScreenFrame
        )
    }

    /// What a Tabbed tab drop's cue says. Nil for any other drop.
    static func tabCueLabel(_ prepared: PreparedLayoutDrop) -> String? {
        prepared.outcome.addsTab && prepared.tabbedState != nil ? "Add as tab" : nil
    }

    /// The reason recorded for invalid feedback, such as a window too wide
    /// for the pane it is dragged to.
    private var invalidReason: String? {
        if case let .invalid(reason)? = dropTarget?.drop { reason } else { nil }
    }

    /// Records a planned Bento or Tabbed drop. A drop that cannot be planned
    /// is recorded as invalid feedback, which release never commits.
    private func recordLayoutPreview(_ preview: LayoutDropPreview?, displayID: DisplayID) -> PreparedLayoutDrop? {
        switch preview {
        case let .ready(prepared):
            dropTarget = WindowDropTarget(displayID: displayID, drop: .layout(prepared))
            return prepared
        case let .invalid(reason):
            dropTarget = WindowDropTarget(displayID: displayID, drop: .invalid(reason: reason))
            return nil
        case nil:
            dropTarget = WindowDropTarget(displayID: displayID, drop: .invalid(reason: Self.unavailableDropReason))
            return nil
        }
    }

    private func armBentoCue(
        candidate: BentoHoverCandidate,
        sourceWindowID: WindowID,
        targetFrame: BTRect,
        sourceOriginalFrame: BTRect?,
        mainScreenFrame: CGRect
    ) -> [Placement]? {
        // The armed cue replaces a competing snap preview as the drop.
        preview?.hide()
        let outcome = BentoDropDecision.outcome(candidate: candidate, isArmed: true, snapTarget: nil)
        // An invalid cue is recorded as invalid feedback: release applies
        // nothing and reports why.
        guard let prepared = recordLayoutPreview(
            bentoPreviewHandler?(candidate.displayID, sourceWindowID, outcome),
            displayID: candidate.displayID
        ) else {
            presentedBentoCandidate = candidate
            // A Tabbed center drop names why the window cannot join the pane.
            activeBentoPreview.showCue(
                targetFrame: targetFrame,
                position: candidate.position,
                phase: .invalid,
                seam: nil,
                label: outcome.addsTab && activeModeProvider?(candidate.displayID) == .tabbed ? invalidReason : nil,
                mainScreenFrame: mainScreenFrame
            )
            return nil
        }
        let placements = prepared.placements
        let sourceDestination = placements.first { $0.windowID == sourceWindowID }?.frame
        presentedBentoCandidate = candidate
        activeBentoPreview.showCue(
            targetFrame: targetFrame,
            position: candidate.position,
            phase: .armed,
            seam: sourceDestination,
            sourceOriginalFrame: sourceOriginalFrame,
            label: Self.tabCueLabel(prepared),
            mainScreenFrame: mainScreenFrame
        )
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        return placements
    }

    private func showBentoReflow(
        candidate: BentoHoverCandidate,
        sourceWindowID: WindowID,
        placements: [Placement],
        baselineFrames: [WindowID: BTRect]
    ) {
        guard bentoHover.candidate == candidate,
              bentoDragDisplayID == candidate.displayID
        else { return }
        activeBentoPreview.showWireframes(
            placements: BentoDragPreview.changedPlacements(
                placements,
                baselineFrames: baselineFrames,
                excluding: sourceWindowID
            ),
            baselineFrames: baselineFrames
        )
    }

    /// Commits the drop the overlay showed. The release position does not
    /// choose a new target: a drop decided at a shared display edge stays on
    /// its display even if the button comes up a point further along.
    private func mouseReleased(_ event: GlobalGestureEvent, evaluatesRelease: Bool) {
        defer {
            clear()
            gestureEndedHandler?()
        }
        pendingDragEvent = nil
        if !configuration.snappingEnabled || event.modifiers.isSuperset(of: configuration.snapSuppressionModifiers) {
            clearTargets()
        } else if evaluatesRelease, !showedDropTarget {
            // A flick can reach a snap area only with the release.
            mouseDragged(event)
        }
        let drop = dropTarget
        if bentoDragDisplayID != nil {
            finishActiveBentoDrag(end: drop?.layoutEnd ?? .restore)
            return
        }
        guard let windowID = draggedWindowID else { return }
        guard isTabbedMember?(windowID) != true else { return }
        guard let drop else { return }
        switch drop.drop {
        case let .snap(target):
            // The overlay planned the frame with this minimum size.
            let minimumSizes = snapSourceWindow.map { [windowID: $0.constraints.minimumSize] } ?? [:]
            let outcome = coordinator.applyPlacements(
                [Placement(windowID: windowID, frame: target.frame)],
                destination: DropDestination(displayID: drop.displayID, sourceWindowID: windowID,
                                             minimumSizes: minimumSizes)
            )
            actionResultHandler?(drop.displayID, outcome.isApplied, outcome.failureReason)
        case let .invalid(reason):
            // The overlay showed no valid drop. The window stays where the
            // user dropped it, as after any drag without a snap.
            actionResultHandler?(drop.displayID, false, reason)
        case .layout:
            return
        }
    }

    private func clear() {
        clearRestoredDragRetry()
        clearTargets()
        dragGate.reset()
        draggedWindowID = nil
        snapSourceWindow = nil
        bentoDragDisplayID = nil
        mouseDownPoint = nil
        resolvedDragTarget = false
        sawDragSample = false
        showedDropTarget = false
        pendingDragEvent = nil
        pacingDisplayID = nil
        displayTicks.stop()
        removeGestureMonitors()
        applyPendingEventTapHandoff()
    }

    private func clearTargets() {
        dropTarget = nil
        presentedTabbedZone = nil
        bentoHoverPreviewTask?.cancel()
        bentoHoverPreviewTask = nil
        presentedBentoCandidate = nil
        bentoHover.clear()
        preview?.hide()
        bentoPreview?.hide()
    }

    private var activeBentoPreview: BentoDropPreviewController {
        if let bentoPreview { return bentoPreview }
        let controller = BentoDropPreviewController()
        bentoPreview = controller
        return controller
    }

    private func finishActiveBentoDrag(end: LayoutDragEnd) {
        guard let displayID = bentoDragDisplayID,
              let sourceID = draggedWindowID ?? dragGate.candidateWindowID
        else { return }
        bentoDragEndedHandler?(displayID, sourceID, end)
        bentoDragDisplayID = nil
    }

    private func showPreview(frame: BTRect, invalid: Bool = false, mainScreenFrame: CGRect) {
        let panel = preview ?? SnapPreviewPanel()
        preview = panel
        panel.show(frame: frame, invalid: invalid, mainScreenFrame: mainScreenFrame)
    }

    private func windowUnderTitleBar(at point: BTPoint) -> WindowSnapshot? {
        let focusedWindow = try? coordinator.system.focusedWindow()
        var visibleWindows = (try? coordinator.system.visibleWindows()) ?? []
        if let focusedWindow, !visibleWindows.contains(where: { $0.id == focusedWindow.id }) {
            visibleWindows.append(focusedWindow)
        }
        return BentoDragWindowResolver.window(
            at: point,
            focusedWindow: focusedWindow,
            visibleWindows: visibleWindows
        )
    }

    private func resolvedWindowForFirstDrag() -> WindowSnapshot? {
        guard let mouseDownPoint,
              let system = coordinator.system as? AccessibilityWindowSystem
        else { return dragGate.candidateWindow }
        return (try? system.window(at: mouseDownPoint)) ?? dragGate.candidateWindow
    }

    private func windowSnapshot(id: WindowID) -> WindowSnapshot? {
        if let system = coordinator.system as? AccessibilityWindowSystem {
            return try? system.windowSnapshot(id: id)
        }
        if let system = coordinator.system as? any TargetedWindowSystem {
            return try? system.windowSnapshots(ids: [id]).first
        }
        return try? coordinator.system.visibleWindows().first(where: { $0.id == id })
    }

    private func beginPendingRestoredWindowDrag(windowID: WindowID) -> Bool {
        guard bentoDragDisplayID == nil,
              let mainFrame = NSScreen.screens.first?.frame,
              let window = try? coordinator.system.visibleWindows().first(where: { $0.id == windowID }),
              usesBentoDrops(window.displayID)
        else { return false }
        let point = CoordinateConverter.pointToTopLeft(NSEvent.mouseLocation, mainScreenFrame: mainFrame)
        guard BentoSwapDragRegion.isTitleBarStart(point, in: window.frame),
              allowsBentoDrag(for: window),
              bentoDragBeganHandler?(window.displayID, window.id, window.frame) == true
        else { return false }
        bentoDragDisplayID = window.displayID
        beginExposedWindowDrag(with: window)
        return true
    }

    private func prepareForStageManagerDrag(exactWindowID: CGWindowID) {
        installGestureMonitors()
        pendingRestoredWindowID = nil
        pendingStageManagerWindowID = exactWindowID
        restoredDragTask?.cancel()
        restoredDragTask = Task { @MainActor [weak self] in
            let resolved = await WindowExposureRetry.run {
                guard let self, !Task.isCancelled,
                      self.primaryButtonIsPressed()
                else { return .stop }
                return self.beginPendingStageManagerDrag(exactWindowID: exactWindowID)
                    ? .resolved
                    : .retry
            }
            guard !resolved,
                  let self,
                  self.pendingStageManagerWindowID == exactWindowID,
                  let system = self.coordinator.system as? AccessibilityWindowSystem
            else { return }
            system.recordStageManagerWindowExposureFailure()
        }
    }

    private func beginPendingStageManagerDrag(exactWindowID: CGWindowID) -> Bool {
        guard bentoDragDisplayID == nil,
              let system = coordinator.system as? AccessibilityWindowSystem,
              let window = try? system.windowSnapshot(exactWindowID: exactWindowID),
              configuration.applicationRules
                .rule(for: window.bundleIdentifier)
                .allowsDirectPlacement
        else { return false }

        if usesBentoDrops(window.displayID),
           allowsBentoDrag(for: window) {
            guard bentoDragBeganHandler?(window.displayID, window.id, window.frame) == true else { return false }
            bentoDragDisplayID = window.displayID
        }
        beginExposedWindowDrag(with: window)
        return true
    }

    /// Dock and Stage Manager exposure can resolve before the first drag sample.
    func beginExposedWindowDrag(with window: WindowSnapshot) {
        dragGate.begin(with: window)
        resolvedDragTarget = true
        clearRestoredDragRetry()
    }

    private func clearRestoredDragRetry() {
        restoredDragTask?.cancel()
        restoredDragTask = nil
        pendingRestoredWindowID = nil
        pendingStageManagerWindowID = nil
    }
}

@MainActor
private final class SnapPreviewPanel {
    private let panel: NSPanel

    init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .floating
        panel.ignoresMouseEvents = true
        panel.hasShadow = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.collectionBehavior = [.moveToActiveSpace, .transient, .ignoresCycle]
        panel.sharingType = .none
        panel.contentView = PlacementWireframeView()
    }

    func show(frame: BTRect, invalid: Bool, mainScreenFrame: CGRect) {
        (panel.contentView as? PlacementWireframeView)?.isInvalid = invalid
        let destination = CoordinateConverter.toAppKit(
            frame,
            mainScreenFrame: mainScreenFrame
        ).insetBy(
            dx: BentoPreviewMetrics.motionPanelInset,
            dy: BentoPreviewMetrics.motionPanelInset
        )
        panel.setFrame(
            destination,
            display: true,
            animate: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                && !panel.frame.equalTo(destination)
        )
        panel.orderFrontRegardless()
    }

    func hide() { panel.orderOut(nil) }
}

@MainActor
enum BentoPreviewMetrics {
    static let cornerRadius: CGFloat = 11
    static let screenInset: CGFloat = 8
    static let cuePanelInset: CGFloat = 2
    static let motionPanelInset: CGFloat = 5
}

@MainActor
private final class BentoDropPreviewController {
    private static let signposter = OSSignposter(
        subsystem: "com.lmckarma.BetterTile",
        category: "Overlay"
    )

    private let cuePanel: NSPanel
    private let cueView = BentoDropCueView()
    private let placementPreviews = PlacementWireframeController()
    private var landingPanel: NSPanel?
    private var swapOriginPanel: NSPanel?
    /// The tab insertion line, above the dragged window that covers the strip.
    private var insertionPanel: NSPanel?
    private(set) var showsSnapWireframes = false

    init() {
        cuePanel = Self.makePanel()
        cuePanel.contentView = cueView
    }

    func showCue(
        targetFrame: BTRect,
        position: BentoPaneDropPosition,
        phase: BentoDropCueView.Phase,
        seam: BTRect?,
        sourceOriginalFrame: BTRect? = nil,
        label: String? = nil,
        insertion: BTRect? = nil,
        mainScreenFrame: CGRect
    ) {
        let interval = Self.signposter.beginInterval("showBentoCue")
        defer { Self.signposter.endInterval("showBentoCue", interval) }
        if phase != .armed || showsSnapWireframes { hideMotionPreviews() }
        cueView.update(position: position, phase: phase, targetFrame: targetFrame, sourceFrame: seam, label: label)
        cuePanel.setFrame(
            CoordinateConverter.toAppKit(targetFrame, mainScreenFrame: mainScreenFrame).insetBy(
                dx: BentoPreviewMetrics.cuePanelInset,
                dy: BentoPreviewMetrics.cuePanelInset
            ),
            display: true
        )
        cuePanel.orderFrontRegardless()
        if let insertion {
            let panel = insertionPanel ?? Self.makePanel()
            if insertionPanel == nil { panel.contentView = TabInsertionIndicatorView() }
            insertionPanel = panel
            panel.setFrame(CoordinateConverter.toAppKit(insertion, mainScreenFrame: mainScreenFrame), display: true)
            panel.orderFrontRegardless()
        } else {
            insertionPanel?.orderOut(nil)
        }
        guard phase == .armed, let seam else { return }
        landingPanel = showLanding(
            frame: seam,
            panel: landingPanel,
            mainScreenFrame: mainScreenFrame
        )
        if position == .center, let sourceOriginalFrame {
            swapOriginPanel = showLanding(
                frame: sourceOriginalFrame,
                panel: swapOriginPanel,
                mainScreenFrame: mainScreenFrame
            )
        }
    }

    func showWireframes(
        placements: [Placement],
        baselineFrames: [WindowID: BTRect]
    ) {
        let interval = Self.signposter.beginInterval("showBentoWireframes")
        defer { Self.signposter.endInterval("showBentoWireframes", interval) }
        showsSnapWireframes = false
        placementPreviews.show(placements, baselineFrames: baselineFrames)
    }

    func showSnapWireframes(placements: [Placement], baselineFrames: [WindowID: BTRect]) {
        if cuePanel.isVisible { cuePanel.orderOut(nil) }
        insertionPanel?.orderOut(nil)
        hideLandingPreviews()
        showWireframes(placements: placements, baselineFrames: baselineFrames)
        showsSnapWireframes = true
    }

    func hide() {
        let interval = Self.signposter.beginInterval("hideBentoOverlay")
        defer { Self.signposter.endInterval("hideBentoOverlay", interval) }
        cuePanel.orderOut(nil)
        insertionPanel?.orderOut(nil)
        hideMotionPreviews()
    }

    private func hideMotionPreviews() {
        showsSnapWireframes = false
        hideLandingPreviews()
        placementPreviews.hide()
    }

    private func hideLandingPreviews() {
        (landingPanel?.contentView as? BentoLandingView)?.stopPulsing()
        landingPanel?.orderOut(nil)
        landingPanel = nil
        (swapOriginPanel?.contentView as? BentoLandingView)?.stopPulsing()
        swapOriginPanel?.orderOut(nil)
        swapOriginPanel = nil
    }

    private func showLanding(
        frame: BTRect,
        panel existingPanel: NSPanel?,
        mainScreenFrame: CGRect
    ) -> NSPanel {
        let panel: NSPanel
        if let existing = existingPanel {
            panel = existing
        } else {
            let created = Self.makePanel()
            created.contentView = BentoLandingView()
            panel = created
        }
        panel.setFrame(
            CoordinateConverter.toAppKit(frame, mainScreenFrame: mainScreenFrame).insetBy(
                dx: BentoPreviewMetrics.motionPanelInset,
                dy: BentoPreviewMetrics.motionPanelInset
            ),
            display: true
        )
        panel.orderFrontRegardless()
        (panel.contentView as? BentoLandingView)?.startPulsing()
        return panel
    }

    private static func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.level = .floating
        panel.ignoresMouseEvents = true
        panel.isOpaque = false
        panel.hasShadow = false
        panel.backgroundColor = .clear
        panel.collectionBehavior = [.moveToActiveSpace, .transient, .ignoresCycle]
        panel.sharingType = .none
        return panel
    }
}

@MainActor
private final class BentoDropCueView: NSView {
    enum Phase: Equatable {
        case tracking
        case armed
        case invalid
    }

    private var position = BentoPaneDropPosition.center
    private var phase = Phase.tracking
    private var seamFraction: CGFloat?
    /// Replaces the swap badge, for example with "Add as tab" or the reason
    /// a tab drop is invalid.
    private var label: String?

    override var isOpaque: Bool { false }

    func update(
        position: BentoPaneDropPosition,
        phase: Phase,
        targetFrame: BTRect,
        sourceFrame: BTRect?,
        label: String? = nil
    ) {
        self.position = position
        self.phase = phase
        self.label = label
        let rawSeamFraction: Double? = sourceFrame.flatMap { sourceFrame in
            switch position {
            case .left:
                (sourceFrame.maxX - targetFrame.minX) / max(1, targetFrame.size.width)
            case .right:
                (sourceFrame.minX - targetFrame.minX) / max(1, targetFrame.size.width)
            case .top:
                (targetFrame.maxY - sourceFrame.maxY) / max(1, targetFrame.size.height)
            case .bottom:
                (targetFrame.maxY - sourceFrame.minY) / max(1, targetFrame.size.height)
            case .center:
                nil
            }
        }
        seamFraction = rawSeamFraction.map { CGFloat(min(1, max(0, $0))) }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let color = phase == .invalid ? NSColor.systemRed : NSColor.controlAccentColor
        if position == .center {
            drawSwapCue(color: color)
        } else {
            drawEdgeRail(color: color)
            if phase == .armed, let seamFraction {
                drawSeam(color: color, fraction: seamFraction)
            }
        }
    }

    private func drawEdgeRail(color: NSColor) {
        let inset: CGFloat = 12
        let thickness: CGFloat = phase == .armed ? 8 : 6
        let rect: CGRect = switch position {
        case .left:
            CGRect(x: inset, y: inset, width: thickness, height: bounds.height - inset * 2)
        case .right:
            CGRect(x: bounds.maxX - inset - thickness, y: inset, width: thickness, height: bounds.height - inset * 2)
        case .top:
            CGRect(x: inset, y: bounds.maxY - inset - thickness, width: bounds.width - inset * 2, height: thickness)
        case .bottom:
            CGRect(x: inset, y: inset, width: bounds.width - inset * 2, height: thickness)
        case .center:
            .zero
        }
        color.withAlphaComponent(phase == .tracking ? 0.72 : 0.95).setFill()
        NSBezierPath(roundedRect: rect, xRadius: thickness / 2, yRadius: thickness / 2).fill()

        let ticks = NSBezierPath()
        let depth: CGFloat = phase == .armed ? 15 : 11
        switch position {
        case .left:
            ticks.move(to: CGPoint(x: rect.maxX, y: rect.minY))
            ticks.line(to: CGPoint(x: rect.maxX + depth, y: rect.minY))
            ticks.move(to: CGPoint(x: rect.maxX, y: rect.maxY))
            ticks.line(to: CGPoint(x: rect.maxX + depth, y: rect.maxY))
        case .right:
            ticks.move(to: CGPoint(x: rect.minX, y: rect.minY))
            ticks.line(to: CGPoint(x: rect.minX - depth, y: rect.minY))
            ticks.move(to: CGPoint(x: rect.minX, y: rect.maxY))
            ticks.line(to: CGPoint(x: rect.minX - depth, y: rect.maxY))
        case .top:
            ticks.move(to: CGPoint(x: rect.minX, y: rect.minY))
            ticks.line(to: CGPoint(x: rect.minX, y: rect.minY - depth))
            ticks.move(to: CGPoint(x: rect.maxX, y: rect.minY))
            ticks.line(to: CGPoint(x: rect.maxX, y: rect.minY - depth))
        case .bottom:
            ticks.move(to: CGPoint(x: rect.minX, y: rect.maxY))
            ticks.line(to: CGPoint(x: rect.minX, y: rect.maxY + depth))
            ticks.move(to: CGPoint(x: rect.maxX, y: rect.maxY))
            ticks.line(to: CGPoint(x: rect.maxX, y: rect.maxY + depth))
        case .center:
            break
        }
        ticks.lineWidth = phase == .armed ? 3 : 2
        ticks.lineCapStyle = .round
        color.withAlphaComponent(phase == .invalid ? 0.8 : 0.9).setStroke()
        ticks.stroke()
    }

    private func drawSeam(color: NSColor, fraction: CGFloat) {
        let path = NSBezierPath()
        switch position {
        case .left, .right:
            let x = bounds.width * fraction
            path.move(to: CGPoint(x: x, y: 18))
            path.line(to: CGPoint(x: x, y: bounds.maxY - 18))
        case .top, .bottom:
            let y = bounds.height * fraction
            path.move(to: CGPoint(x: 18, y: y))
            path.line(to: CGPoint(x: bounds.maxX - 18, y: y))
        case .center:
            return
        }
        path.lineWidth = 2
        let pattern: [CGFloat] = [7, 5]
        path.setLineDash(pattern, count: pattern.count, phase: 0)
        color.withAlphaComponent(0.88).setStroke()
        path.stroke()
    }

    private func drawSwapCue(color: NSColor) {
        let innerInset = BentoPreviewMetrics.screenInset - BentoPreviewMetrics.cuePanelInset
        let outline = bounds.insetBy(dx: innerInset, dy: innerInset)
        let radius = min(
            BentoPreviewMetrics.cornerRadius,
            min(outline.width, outline.height) / 2
        )
        let path = NSBezierPath(roundedRect: outline, xRadius: radius, yRadius: radius)
        path.lineWidth = phase == .armed ? 3 : 2
        if phase == .invalid {
            let pattern: [CGFloat] = [7, 5]
            path.setLineDash(pattern, count: pattern.count, phase: 0)
        }
        color.withAlphaComponent(phase == .tracking ? 0.68 : 0.92).setStroke()
        path.stroke()
        if let label {
            drawLabelBadge(label, color: color)
            return
        }

        let badgeWidth = min(116, max(88, bounds.width - 36))
        let badgeHeight = min(68, max(56, bounds.height - 36))
        let badge = CGRect(
            x: bounds.midX - badgeWidth / 2,
            y: max(18, bounds.maxY - badgeHeight - 22),
            width: badgeWidth,
            height: badgeHeight
        )
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.32)
        shadow.shadowBlurRadius = 8
        shadow.shadowOffset = CGSize(width: 0, height: -2)
        NSGraphicsContext.saveGraphicsState()
        shadow.set()
        color.withAlphaComponent(0.96).setFill()
        NSBezierPath(
            roundedRect: badge,
            xRadius: BentoPreviewMetrics.cornerRadius,
            yRadius: BentoPreviewMetrics.cornerRadius
        ).fill()
        NSGraphicsContext.restoreGraphicsState()

        let windowSize = CGSize(
            width: min(28, max(18, (badgeWidth - 52) / 2)),
            height: min(31, badgeHeight - 24)
        )
        let leftWindow = CGRect(
            x: badge.minX + 12,
            y: badge.midY - windowSize.height / 2,
            width: windowSize.width,
            height: windowSize.height
        )
        let rightWindow = CGRect(
            x: badge.maxX - 12 - windowSize.width,
            y: leftWindow.minY,
            width: windowSize.width,
            height: windowSize.height
        )
        NSColor.white.withAlphaComponent(0.18).setFill()
        NSColor.white.setStroke()
        for window in [leftWindow, rightWindow] {
            let windowPath = NSBezierPath(roundedRect: window, xRadius: 4, yRadius: 4)
            windowPath.lineWidth = 2
            windowPath.fill()
            windowPath.stroke()
            let titleBar = NSBezierPath()
            titleBar.move(to: CGPoint(x: window.minX + 4, y: window.maxY - 6))
            titleBar.line(to: CGPoint(x: window.maxX - 4, y: window.maxY - 6))
            titleBar.lineWidth = 1.5
            titleBar.stroke()
        }
        drawExchangeArrow(
            from: CGPoint(x: leftWindow.maxX + 4, y: badge.midY + 7),
            to: CGPoint(x: rightWindow.minX - 4, y: badge.midY + 7),
            pointingRight: true
        )
        drawExchangeArrow(
            from: CGPoint(x: rightWindow.minX - 4, y: badge.midY - 7),
            to: CGPoint(x: leftWindow.maxX + 4, y: badge.midY - 7),
            pointingRight: false
        )
    }

    private func drawLabelBadge(_ label: String, color: NSColor) {
        let text = NSAttributedString(string: label, attributes: [
            .font: NSFont.systemFont(ofSize: 15, weight: .semibold),
            .foregroundColor: NSColor.white,
        ])
        let size = text.size()
        let width = min(bounds.width - 16, size.width + 32)
        let badge = CGRect(x: bounds.midX - width / 2, y: bounds.midY - 22, width: width, height: 44)
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.32)
        shadow.shadowBlurRadius = 8
        shadow.shadowOffset = CGSize(width: 0, height: -2)
        NSGraphicsContext.saveGraphicsState()
        shadow.set()
        color.withAlphaComponent(0.96).setFill()
        NSBezierPath(roundedRect: badge, xRadius: BentoPreviewMetrics.cornerRadius,
                     yRadius: BentoPreviewMetrics.cornerRadius).fill()
        NSGraphicsContext.restoreGraphicsState()
        text.draw(with: CGRect(x: badge.minX + 16, y: badge.midY - size.height / 2, width: badge.width - 32,
                               height: size.height), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    private func drawExchangeArrow(from start: CGPoint, to end: CGPoint, pointingRight: Bool) {
        let path = NSBezierPath()
        path.move(to: start)
        path.line(to: end)
        let direction: CGFloat = pointingRight ? -1 : 1
        path.move(to: end)
        path.line(to: CGPoint(x: end.x + direction * 5, y: end.y + 4))
        path.move(to: end)
        path.line(to: CGPoint(x: end.x + direction * 5, y: end.y - 4))
        path.lineWidth = 2
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        NSColor.white.setStroke()
        path.stroke()
    }
}

/// The line where a dragged window joins a tab strip.
@MainActor
final class TabInsertionIndicatorView: NSView {
    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        // A light edge keeps the line visible over an accent-colored window.
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                xRadius: bounds.width / 2, yRadius: bounds.width / 2)
        NSColor.controlAccentColor.setFill()
        path.fill()
        path.lineWidth = 1
        NSColor.white.withAlphaComponent(0.85).setStroke()
        path.stroke()
    }
}

@MainActor
private final class BentoLandingView: NSView {
    override var isOpaque: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { nil }

    func startPulsing() {
        layer?.removeAnimation(forKey: "bentoLandingPulse")
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            layer?.opacity = 1
            return
        }
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = 0.25
        animation.toValue = 1
        animation.duration = 0.52
        animation.autoreverses = true
        animation.repeatCount = .infinity
        layer?.add(animation, forKey: "bentoLandingPulse")
    }

    func stopPulsing() {
        layer?.removeAnimation(forKey: "bentoLandingPulse")
        layer?.opacity = 1
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let innerInset = BentoPreviewMetrics.screenInset - BentoPreviewMetrics.motionPanelInset
        let rect = bounds.insetBy(dx: innerInset, dy: innerInset)
        let radius = min(
            BentoPreviewMetrics.cornerRadius,
            min(rect.width, rect.height) / 2
        )
        NSColor.controlAccentColor.withAlphaComponent(0.2).setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()

        let length = min(30, max(radius + 4, min(rect.width, rect.height) * 0.2))
        let control = radius * 0.552_284_75
        let corners = NSBezierPath()

        corners.move(to: CGPoint(x: rect.minX + length, y: rect.minY))
        corners.line(to: CGPoint(x: rect.minX + radius, y: rect.minY))
        corners.curve(
            to: CGPoint(x: rect.minX, y: rect.minY + radius),
            controlPoint1: CGPoint(x: rect.minX + radius - control, y: rect.minY),
            controlPoint2: CGPoint(x: rect.minX, y: rect.minY + radius - control)
        )
        corners.line(to: CGPoint(x: rect.minX, y: rect.minY + length))

        corners.move(to: CGPoint(x: rect.maxX - length, y: rect.minY))
        corners.line(to: CGPoint(x: rect.maxX - radius, y: rect.minY))
        corners.curve(
            to: CGPoint(x: rect.maxX, y: rect.minY + radius),
            controlPoint1: CGPoint(x: rect.maxX - radius + control, y: rect.minY),
            controlPoint2: CGPoint(x: rect.maxX, y: rect.minY + radius - control)
        )
        corners.line(to: CGPoint(x: rect.maxX, y: rect.minY + length))

        corners.move(to: CGPoint(x: rect.minX, y: rect.maxY - length))
        corners.line(to: CGPoint(x: rect.minX, y: rect.maxY - radius))
        corners.curve(
            to: CGPoint(x: rect.minX + radius, y: rect.maxY),
            controlPoint1: CGPoint(x: rect.minX, y: rect.maxY - radius + control),
            controlPoint2: CGPoint(x: rect.minX + radius - control, y: rect.maxY)
        )
        corners.line(to: CGPoint(x: rect.minX + length, y: rect.maxY))

        corners.move(to: CGPoint(x: rect.maxX - length, y: rect.maxY))
        corners.line(to: CGPoint(x: rect.maxX - radius, y: rect.maxY))
        corners.curve(
            to: CGPoint(x: rect.maxX, y: rect.maxY - radius),
            controlPoint1: CGPoint(x: rect.maxX - radius + control, y: rect.maxY),
            controlPoint2: CGPoint(x: rect.maxX, y: rect.maxY - radius + control)
        )
        corners.line(to: CGPoint(x: rect.maxX, y: rect.maxY - length))

        corners.lineWidth = 3.5
        corners.lineCapStyle = .round
        corners.lineJoinStyle = .round
        NSColor.controlAccentColor.withAlphaComponent(0.95).setStroke()
        corners.stroke()
    }
}

@MainActor
/// Shared by Bento drop previews and the Layout Wheel so both speak the same
/// visual language for "this window is going here".
final class PlacementWireframeController {
    private var panels: [WindowID: NSPanel] = [:]
    private var destinations: [WindowID: CGRect] = [:]
    private let panelFactory: () -> NSPanel
    private let reduceMotion: () -> Bool
    private var wasReducingMotion = false

    init(reduceMotion: @escaping () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion },
         panelFactory: @escaping () -> NSPanel = {
             NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
         }) {
        self.reduceMotion = reduceMotion
        self.panelFactory = panelFactory
    }

    func show(
        _ placements: [Placement],
        baselineFrames: [WindowID: BTRect] = [:]
    ) {
        guard let mainFrame = NSScreen.screens.first?.frame else { return }
        let reduceMotion = reduceMotion()
        let finishAnimations = reduceMotion && !wasReducingMotion
        wasReducingMotion = reduceMotion
        let ids = Set(placements.map(\.windowID))
        for id in panels.keys where !ids.contains(id) {
            panels.removeValue(forKey: id)?.orderOut(nil)
            destinations.removeValue(forKey: id)
        }
        for placement in placements {
            let panel = panels[placement.windowID] ?? makePanel(for: placement.windowID)
            let destination = CoordinateConverter.toAppKit(
                placement.frame,
                mainScreenFrame: mainFrame
            ).insetBy(
                dx: BentoPreviewMetrics.motionPanelInset,
                dy: BentoPreviewMetrics.motionPanelInset
            )
            if panel.isVisible, destinations[placement.windowID] == destination {
                if finishAnimations {
                    panel.alphaValue = 1
                    panel.setFrame(destination, display: true)
                }
                continue
            }
            destinations[placement.windowID] = destination
            let origin = baselineFrames[placement.windowID].map {
                CoordinateConverter.toAppKit($0, mainScreenFrame: mainFrame).insetBy(
                    dx: BentoPreviewMetrics.motionPanelInset,
                    dy: BentoPreviewMetrics.motionPanelInset
                )
            } ?? destination
            panel.alphaValue = reduceMotion ? 1 : 0.58
            panel.setFrame(origin, display: true)
            panel.orderFrontRegardless()
            if reduceMotion || origin.equalTo(destination) {
                panel.alphaValue = 1
                panel.setFrame(destination, display: true)
            } else {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.18
                    context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    panel.animator().alphaValue = 1
                    panel.animator().setFrame(destination, display: true)
                }
            }
        }
    }

    func hide() {
        for panel in panels.values { panel.orderOut(nil) }
        panels.removeAll()
        destinations.removeAll()
        wasReducingMotion = false
    }

    private func makePanel(for id: WindowID) -> NSPanel {
        let panel = panelFactory()
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.moveToActiveSpace, .transient, .ignoresCycle]
        panel.sharingType = .none
        panel.contentView = PlacementWireframeView()
        panels[id] = panel
        return panel
    }
}

@MainActor
final class PlacementWireframeView: NSView {
    /// Invalid feedback: a frame the drop cannot take.
    var isInvalid = false {
        didSet { if isInvalid != oldValue { needsDisplay = true } }
    }

    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let innerInset = BentoPreviewMetrics.screenInset - BentoPreviewMetrics.motionPanelInset
        let rect = bounds.insetBy(dx: innerInset, dy: innerInset)
        let radius = min(
            BentoPreviewMetrics.cornerRadius,
            min(rect.width, rect.height) / 2
        )
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        let increaseContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        let color = isInvalid ? NSColor.systemRed : NSColor.controlAccentColor
        color
            .withAlphaComponent(increaseContrast ? 0.16 : 0.10)
            .setFill()
        path.fill()

        path.lineWidth = increaseContrast ? 3 : 2
        let pattern: [CGFloat] = [8, 5]
        path.setLineDash(pattern, count: pattern.count, phase: 0)
        color
            .withAlphaComponent(increaseContrast ? 0.95 : 0.78)
            .setStroke()
        path.stroke()
    }
}
