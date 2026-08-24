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
    public var bentoDragBeganHandler: ((DisplayID, WindowID) -> Bool)?
    public var bentoPreviewHandler: ((DisplayID, WindowID, BentoDragOutcome) -> [Placement]?)?
    public var bentoDragEndedHandler: ((DisplayID, WindowID, BentoDragOutcome) -> Void)?
    public var activeModeProvider: ((DisplayID) -> LayoutMode?)?
    public var bentoStateProvider: ((DisplayID) -> BentoLayoutState?)?
    public var gestureEndedHandler: (() -> Void)?
    public var actionResultHandler: ((DisplayID, Bool, String?) -> Void)?
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
    private var target: SnapTarget?
    private var dragGate = WindowDragGate()
    private var draggedWindowID: WindowID?
    private var bentoDragDisplayID: DisplayID?
    private var bentoSnapTarget: SnapTarget?
    private var bentoHover = BentoDropHoverState()
    private var bentoHoverPreviewTask: Task<Void, Never>?
    private var presentedBentoCandidate: BentoHoverCandidate?
    private var preview: SnapPreviewPanel?
    private var bentoPreview: BentoDropPreviewController?
    private var restoredDragTask: Task<Void, Never>?
    private var pendingRestoredWindowID: WindowID?
    private var pendingStageManagerWindowID: CGWindowID?
    private var mouseDownPoint: BTPoint?
    private var resolvedDragTarget = false
    private var isStarted = false

    private static let bentoCueArmDelay = 0.12
    private static let bentoReflowPreviewDelay = 0.22

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
        guard !gestureEventSource.usesEventTap, mouseDownMonitor == nil else { return }
        mouseDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            Task { @MainActor in self?.receive(event, kind: .leftMouseDown) }
        }
    }

    private func installGestureMonitors() {
        if !gestureEventSource.usesEventTap, dragMonitor == nil {
            dragMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDragged]) { [weak self] event in
                Task { @MainActor in self?.receive(event, kind: .leftMouseDragged) }
            }
            mouseUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] event in
                Task { @MainActor in self?.receive(event, kind: .leftMouseUp) }
            }
        }
        if escapeMonitor == nil {
            escapeMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
                guard event.keyCode == 53 else { return }
                Task { @MainActor in self?.cancel() }
            }
        }
    }

    private func removeMouseDownMonitor() {
        if let mouseDownMonitor { NSEvent.removeMonitor(mouseDownMonitor) }
        mouseDownMonitor = nil
    }

    private func removeGestureMonitors() {
        removeFallbackGestureMonitors()
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        escapeMonitor = nil
    }

    private func removeFallbackGestureMonitors() {
        if let dragMonitor { NSEvent.removeMonitor(dragMonitor) }
        if let mouseUpMonitor { NSEvent.removeMonitor(mouseUpMonitor) }
        dragMonitor = nil
        mouseUpMonitor = nil
    }

    public func cancel() {
        finishActiveBentoDrag(outcome: .restore)
        clear()
        gestureEndedHandler?()
    }

    /// A window dragged out of the Dock can appear after the global mouse-down
    /// event. Retry briefly from the Accessibility restore notification so the
    /// user does not need to generate extra drag events by shaking the mouse.
    public func prepareForRestoredWindowDrag(windowID: WindowID) {
        guard configuration.snappingEnabled, NSEvent.pressedMouseButtons & 1 == 1 else { return }
        installGestureMonitors()
        pendingRestoredWindowID = windowID
        pendingStageManagerWindowID = nil
        restoredDragTask?.cancel()
        restoredDragTask = Task { @MainActor [weak self] in
            _ = await WindowExposureRetry.run {
                guard let self, !Task.isCancelled,
                      NSEvent.pressedMouseButtons & 1 == 1
                else { return .stop }
                return self.beginPendingRestoredWindowDrag(windowID: windowID)
                    ? .resolved
                    : .retry
            }
        }
    }

    func allowsBentoDrag(for window: WindowSnapshot) -> Bool {
        !window.isFloating && configuration.applicationRules
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
        switch event.kind {
        case .leftMouseDown:
            guard Self.acceptsMouseDown(
                from: source,
                pressedMouseButtons: NSEvent.pressedMouseButtons
            ) else { return }
            mousePressed(event)
        case .leftMouseDragged where isGestureActive: mouseDragged(event)
        case .leftMouseUp where isGestureActive: mouseReleased()
        case .leftMouseDragged, .leftMouseUp: return
        }
    }

    static func acceptsMouseDown(
        from source: GestureEventSource,
        pressedMouseButtons: Int
    ) -> Bool {
        source == .eventTap || pressedMouseButtons & 1 == 1
    }

    private func mousePressed(_ event: GlobalGestureEvent) {
        dragGate.reset()
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
            if activeModeProvider?(window.displayID) == .bento,
               allowsBentoDrag(for: window) {
                guard bentoDragBeganHandler?(window.displayID, window.id) == true else {
                    clear()
                    return
                }
                bentoDragDisplayID = window.displayID
            }
        }
        if draggedWindowID == nil {
            guard let candidateWindowID = dragGate.candidateWindowID,
                  let windowID = dragGate.activate(with: windowSnapshot(id: candidateWindowID))
            else {
                clearTargets()
                return
            }
            draggedWindowID = windowID
        }
        let displays = coordinator.system.displays()
        guard let display = displays.first(where: { $0.frame.contains(point) }) else { clearTargets(); return }
        if let bentoDragDisplayID, display.id != bentoDragDisplayID {
            clearTargets()
            return
        }
        let snapTarget = bentoDragDisplayID == nil ? nil : SnapZoneDetector().target(
               at: point,
               display: display,
               snapAreas: configuration.snapAreaBindings,
               customZones: configuration.customZones
           )
        bentoSnapTarget = snapTarget
        if bentoDragDisplayID != nil,
           activeModeProvider?(display.id) == .bento,
           let draggedWindowID,
           let state = bentoStateProvider?(display.id),
           let placement = state.placements(in: display.visibleFrame).first(where: { $0.windowID != draggedWindowID && $0.frame.contains(point) }) {
            let baselineFrames = Dictionary(
                uniqueKeysWithValues: state.placements(in: display.visibleFrame).map {
                    ($0.windowID, $0.frame)
                }
            )
            let now = ProcessInfo.processInfo.systemUptime
            let previousPosition = bentoHover.candidate?.targetWindowID == placement.windowID
                ? bentoHover.candidate?.position
                : nil
            let position = BentoPaneDropPosition.resolve(
                point,
                in: placement.frame,
                retaining: previousPosition,
                edgeFraction: activeModifiers.contains(.option) ? 0.2 : 0.15
            )
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
            if changed {
                bentoHoverPreviewTask?.cancel()
                bentoHoverPreviewTask = nil
                presentedBentoCandidate = nil
                preview?.hide()
                target = nil
                activeBentoPreview.showCue(
                    targetFrame: placement.frame,
                    position: position,
                    phase: .tracking,
                    seam: nil,
                    mainScreenFrame: mainFrame
                )
                bentoHoverPreviewTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(
                        for: .milliseconds(Int(Self.bentoCueArmDelay * 1_000))
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
                            (Self.bentoReflowPreviewDelay - Self.bentoCueArmDelay) * 1_000
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
            } else if presentedBentoCandidate != candidate {
                activeBentoPreview.showCue(
                    targetFrame: placement.frame,
                    position: position,
                    phase: .tracking,
                    seam: nil,
                    mainScreenFrame: mainFrame
                )
            }
            if bentoHover.armedCandidate(
                at: now,
                delay: hoverDelay
            ) == nil, hoverDelay > 0, let snapTarget {
                bentoPreview?.hide()
                target = snapTarget
                showPreview(frame: snapTarget.frame, mainScreenFrame: mainFrame)
            } else {
                preview?.hide()
                target = nil
            }
            return
        }
        bentoHoverPreviewTask?.cancel()
        bentoHoverPreviewTask = nil
        presentedBentoCandidate = nil
        bentoHover.clear()
        bentoPreview?.hide()
        target = snapTarget ?? SnapZoneDetector().target(
                at: point,
                display: display,
                snapAreas: configuration.snapAreaBindings,
                customZones: configuration.customZones
        )
        if let target {
            showPreview(frame: target.frame, mainScreenFrame: mainFrame)
        } else {
            preview?.hide()
        }
    }

    private func armBentoCue(
        candidate: BentoHoverCandidate,
        sourceWindowID: WindowID,
        targetFrame: BTRect,
        sourceOriginalFrame: BTRect?,
        mainScreenFrame: CGRect
    ) -> [Placement]? {
        let outcome: BentoDragOutcome = candidate.position == .center
            ? .swap(targetWindowID: candidate.targetWindowID)
            : .insert(targetWindowID: candidate.targetWindowID, edge: candidate.position)
        guard let placements = bentoPreviewHandler?(
            candidate.displayID,
            sourceWindowID,
            outcome
        ) else {
            presentedBentoCandidate = candidate
            activeBentoPreview.showCue(
                targetFrame: targetFrame,
                position: candidate.position,
                phase: .invalid,
                seam: nil,
                mainScreenFrame: mainScreenFrame
            )
            return nil
        }
        let sourceDestination = placements.first { $0.windowID == sourceWindowID }?.frame
        presentedBentoCandidate = candidate
        activeBentoPreview.showCue(
            targetFrame: targetFrame,
            position: candidate.position,
            phase: .armed,
            seam: sourceDestination,
            sourceOriginalFrame: sourceOriginalFrame,
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

    private func mouseReleased() {
        defer {
            clear()
            gestureEndedHandler?()
        }
        if bentoDragDisplayID != nil {
            let hoverDelay = bentoHover.candidate?.position == .center
                ? configuration.bentoSwapHoverDelay
                : 0
            let outcome = bentoHover.outcome(
                at: ProcessInfo.processInfo.systemUptime,
                delay: hoverDelay,
                snapTarget: bentoSnapTarget
            )
            finishActiveBentoDrag(outcome: outcome)
            return
        }
        guard let target, let windowID = draggedWindowID else { return }
        let displayID = (try? coordinator.system.visibleWindows().first(where: { $0.id == windowID }))?.displayID
        let outcome = coordinator.applyPlacements([Placement(windowID: windowID, frame: target.frame)])
        if let displayID {
            actionResultHandler?(displayID, outcome.isApplied, outcome.failureReason)
        }
    }

    private func clear() {
        clearRestoredDragRetry()
        clearTargets()
        dragGate.reset()
        draggedWindowID = nil
        bentoDragDisplayID = nil
        mouseDownPoint = nil
        resolvedDragTarget = false
        removeGestureMonitors()
        applyPendingEventTapHandoff()
    }

    private func clearTargets() {
        target = nil
        bentoSnapTarget = nil
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

    private func finishActiveBentoDrag(outcome: BentoDragOutcome) {
        guard let displayID = bentoDragDisplayID,
              let sourceID = draggedWindowID ?? dragGate.candidateWindowID
        else { return }
        bentoDragEndedHandler?(displayID, sourceID, outcome)
        bentoDragDisplayID = nil
    }

    private func showPreview(frame: BTRect, mainScreenFrame: CGRect) {
        let panel = preview ?? SnapPreviewPanel()
        preview = panel
        panel.show(frame: frame, mainScreenFrame: mainScreenFrame)
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
        return try? coordinator.system.visibleWindows().first(where: { $0.id == id })
    }

    private func beginPendingRestoredWindowDrag(windowID: WindowID) -> Bool {
        guard bentoDragDisplayID == nil,
              let mainFrame = NSScreen.screens.first?.frame,
              let window = try? coordinator.system.visibleWindows().first(where: { $0.id == windowID }),
              activeModeProvider?(window.displayID) == .bento
        else { return false }
        let point = CoordinateConverter.pointToTopLeft(NSEvent.mouseLocation, mainScreenFrame: mainFrame)
        guard BentoSwapDragRegion.isTitleBarStart(point, in: window.frame),
              allowsBentoDrag(for: window),
              bentoDragBeganHandler?(window.displayID, window.id) == true
        else { return false }
        dragGate.begin(with: window)
        resolvedDragTarget = true
        bentoDragDisplayID = window.displayID
        clearRestoredDragRetry()
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
                      NSEvent.pressedMouseButtons & 1 == 1
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

        if activeModeProvider?(window.displayID) == .bento,
           allowsBentoDrag(for: window) {
            guard bentoDragBeganHandler?(window.displayID, window.id) == true else { return false }
            bentoDragDisplayID = window.displayID
        }
        dragGate.begin(with: window)
        resolvedDragTarget = true
        clearRestoredDragRetry()
        return true
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
        panel.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.18)
        panel.collectionBehavior = [.moveToActiveSpace, .transient, .ignoresCycle]
        panel.contentView?.wantsLayer = true
        panel.contentView?.layer?.borderWidth = 2
        panel.contentView?.layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.8).cgColor
        panel.contentView?.layer?.cornerRadius = 12
    }

    func show(frame: BTRect, mainScreenFrame: CGRect) {
        let destination = CoordinateConverter.toAppKit(
            frame,
            mainScreenFrame: mainScreenFrame
        ).insetBy(dx: 6, dy: 6)
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
private enum BentoPreviewMetrics {
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
    private var landingPanel: NSPanel?
    private var swapOriginPanel: NSPanel?
    private var wireframePanels: [WindowID: NSPanel] = [:]

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
        mainScreenFrame: CGRect
    ) {
        let interval = Self.signposter.beginInterval("showBentoCue")
        defer { Self.signposter.endInterval("showBentoCue", interval) }
        if phase != .armed { hideMotionPreviews() }
        cueView.update(position: position, phase: phase, targetFrame: targetFrame, sourceFrame: seam)
        cuePanel.setFrame(
            CoordinateConverter.toAppKit(targetFrame, mainScreenFrame: mainScreenFrame).insetBy(
                dx: BentoPreviewMetrics.cuePanelInset,
                dy: BentoPreviewMetrics.cuePanelInset
            ),
            display: true
        )
        cuePanel.orderFrontRegardless()
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
        guard let mainFrame = NSScreen.screens.first?.frame else { return }
        let ids = Set(placements.map(\.windowID))
        for id in wireframePanels.keys.filter({ !ids.contains($0) }) {
            wireframePanels.removeValue(forKey: id)?.orderOut(nil)
        }
        for placement in placements {
            let panel = wireframePanels[placement.windowID] ?? {
                let panel = Self.makePanel()
                panel.contentView = BentoWireframeView()
                wireframePanels[placement.windowID] = panel
                return panel
            }()
            let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            let destination = CoordinateConverter.toAppKit(
                placement.frame,
                mainScreenFrame: mainFrame
            ).insetBy(
                dx: BentoPreviewMetrics.motionPanelInset,
                dy: BentoPreviewMetrics.motionPanelInset
            )
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
        let interval = Self.signposter.beginInterval("hideBentoOverlay")
        defer { Self.signposter.endInterval("hideBentoOverlay", interval) }
        cuePanel.orderOut(nil)
        hideMotionPreviews()
    }

    private func hideMotionPreviews() {
        (landingPanel?.contentView as? BentoLandingView)?.stopPulsing()
        landingPanel?.orderOut(nil)
        landingPanel = nil
        (swapOriginPanel?.contentView as? BentoLandingView)?.stopPulsing()
        swapOriginPanel?.orderOut(nil)
        swapOriginPanel = nil
        for panel in wireframePanels.values { panel.orderOut(nil) }
        wireframePanels.removeAll()
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

    override var isOpaque: Bool { false }

    func update(
        position: BentoPaneDropPosition,
        phase: Phase,
        targetFrame: BTRect,
        sourceFrame: BTRect?
    ) {
        self.position = position
        self.phase = phase
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
private final class BentoWireframeView: NSView {
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
        path.lineWidth = 2
        let pattern: [CGFloat] = [8, 5]
        path.setLineDash(pattern, count: pattern.count, phase: 0)
        NSColor.controlAccentColor.withAlphaComponent(0.72).setStroke()
        path.stroke()
    }
}
