import AppKit
import BetterTileCore
import BetterTileMacOS
import Foundation
import Observation
import os

/// The macOS observations the app model coordinates. The Accessibility adapter
/// and the deterministic app-test adapter meet at this seam.
@MainActor
protocol BetterTileWindowSystem: TargetedWindowSystem, WindowEventSource {
    var enhancedUserInterfacePolicy: EnhancedUserInterfacePolicy { get set }
    func cachedVisibleWindows(refreshing ids: Set<WindowID>) throws -> [WindowSnapshot]?
    func nativeDesktopObservation() -> NativeDesktopObservation?
    func refreshNativeDesktopObservation() -> NativeDesktopObservation?
    func observeApplicationEnforcedMinimum(
        windowID: WindowID,
        requested: BTRect,
        baseline: BTRect,
        actual: BTRect
    ) -> Bool
    /// Clears minimums learned from refused writes. Called when the user
    /// starts a new resize or drag, so an old refusal never becomes a floor.
    func forgetLearnedMinimums()
    func refreshApplicationObservers()
    func resetCachedWindows()
    func startDockFootprintMonitoring(onChange: @escaping () -> Void)
    func stopDockFootprintMonitoring()
    func triggerDockFootprintCheck()
    func startDisplayReconfigurationMonitoring(onChange: @escaping @MainActor () -> Void)
    func stopDisplayReconfigurationMonitoring()
    func updateManagedWindowIDs(_ ids: Set<WindowID>)
}

extension AccessibilityWindowSystem: BetterTileWindowSystem {}

@Observable
@MainActor
final class BetterTileModel {
    /// Traces the Bento decision path. Bento reacts to Accessibility events
    /// that carry no indication of who caused them, so when a layout ends up
    /// somewhere unexpected the only way to tell which branch made the choice
    /// is to have recorded it. Read with:
    ///   log stream --predicate 'subsystem == "com.lmckarma.BetterTile"'
    /// Window identifiers and frames only; never titles.
    static let bentoLog = Logger(subsystem: "com.lmckarma.BetterTile", category: "Bento")
    private static let signposter = OSSignposter(
        subsystem: "com.lmckarma.BetterTile",
        category: "Model"
    )

    var configuration: BetterTileConfiguration
    var hasAccessibilityPermission = false
    private(set) var isWaitingForAccessibilityPermission = false
    var statusMessage: String?
    private(set) var lastActionFeedback: ResultPillFeedback?
    private(set) var activeDisplayID: DisplayID?
    private(set) var layoutWheelMonitoringFailure: String?

    private let system: any BetterTileWindowSystem
    private let coordinator: WindowCoordinator
    private let store: ConfigurationStore
    private let shortcuts: GlobalShortcutMonitor
    private let dragSnap: DragSnapController
    private let titleBarDoubleClick: TitleBarDoubleClickController
    private let linkedResize: LinkedResizeController
    private let layoutWheel: LayoutWheelController
    private let sharedGestureEvents: SharedGestureEventMonitor
    let dividerResize: DividerOverlayController
    private var resultPill: ResultPillController?
    private var sessionStore = LayoutSessionStore()
    private var tabbedOverlays: [DisplayID: TabbedOverlayController] = [:]
    private var tabbedTasks: [DisplayID: Task<Void, Never>] = [:]
    private var tabbedTaskIDs: [DisplayID: UUID] = [:]
    private var tabbedExiting: Set<DisplayID> = []
    private var tabbedQueuedIntents: [DisplayID: PendingTabbedIntent] = [:]
    private var tabbedUndo: [DesktopSessionID: [TabbedUndoStep]] = [:]
    private var tabbedNeedsRefresh: Set<DisplayID> = []
    /// An apply arrived while another was running; re-apply the committed state after it.
    private var tabbedNeedsReapply: Set<DisplayID> = []
    private let presentsTabbedChrome: Bool
    private(set) var tabbedFocusTask: Task<Void, Never>?
    private(set) var tabbedNeedsFocusRefresh = false
    private var tabbedFocusSuppressedUntil = Date.distantPast
    /// Tabbed reads a window-edge resize only after the user lets go, so it
    /// never fights the drag. Tests replace this.
    var primaryButtonIsPressed: () -> Bool = { NSEvent.pressedMouseButtons & 1 == 1 }
    private var tabbedResizeReleaseTask: Task<Void, Never>?

    private var watchdogTimer: Timer?
    private var pendingDockReflow = false
    private var permissionPollTask: Task<Void, Never>?
    private var notificationTokens: [NSObjectProtocol] = []
    private var lastVisibleSignature = ""
    private var lastDisplayWorkAreaSignature = ""
    private var pendingWindowEvents = WindowEventBuffer()
    /// Windows a destroyed event has accounted for. Direct evidence, so their
    /// panes are released without waiting for absence to be corroborated.
    private var confirmedGoneWindowIDs: Set<WindowID> = []
    /// Minimized panes are direct absences too, but retain a local reinsertion
    /// anchor when the membership transition commits.
    private var confirmedMinimizedWindowIDs: Set<WindowID> = []
    private var actionVerificationTask: Task<Void, Never>?
    private var pendingRestoredWindowDeadlines: [WindowID: Date] = [:]
    private(set) var windowEventTask: Task<Void, Never>?
    private var windowEventRetryBackoff = WindowEventRetryBackoff()
    private(set) var settlementTasks: [DisplayID: Task<Void, Never>] = [:]
    private var settlementTaskGenerations: [DisplayID: UInt64] = [:]
    private var spaceStabilizationTask: Task<Void, Never>?
    private let displayRefreshDebouncer = DisplayRefreshDebouncer()
    private var spaceStabilizationGeneration = 0
    private var isStabilizingSpace = false
    private var nativeFullscreenDisplayIDs: Set<DisplayID> = []
    private var suppressSpaceFrameEventsUntil = Date.distantPast
    private var activeBentoDrag: ActiveBentoDrag?
    private var bentoDragEventBuffer = WindowEventBuffer()
    private var configurationSaveTask: Task<Void, Never>?
    private var configurationNeedsSave = false
    private var isShortcutCaptureActive = false
    private var isShutDown = false

    init(
        store: ConfigurationStore = .defaultStore(),
        system suppliedSystem: (any BetterTileWindowSystem)? = nil,
        startRuntime: Bool = true,
        presentsTabbedChrome: Bool? = nil
    ) {
        self.store = store
        self.presentsTabbedChrome = presentsTabbedChrome ?? startRuntime
        let loaded = (try? store.load()) ?? BetterTileConfiguration()
        let windowSystem: any BetterTileWindowSystem = suppliedSystem ?? AccessibilityWindowSystem()
        configuration = loaded
        windowSystem.enhancedUserInterfacePolicy = loaded.enhancedUserInterfacePolicy
        system = windowSystem
        coordinator = WindowCoordinator(system: windowSystem)
        shortcuts = GlobalShortcutMonitor { _ in }
        dragSnap = DragSnapController(coordinator: coordinator, configuration: loaded)
        titleBarDoubleClick = TitleBarDoubleClickController(
            coordinator: coordinator,
            isEnabled: loaded.doubleClickTitleBarToMaximize
        )
        titleBarDoubleClick.applicationRules = loaded.applicationRules
        linkedResize = LinkedResizeController(coordinator: coordinator, configuration: loaded)
        layoutWheel = LayoutWheelController(configuration: loaded)
        sharedGestureEvents = SharedGestureEventMonitor()
        dividerResize = DividerOverlayController(coordinator: coordinator, configuration: loaded)
        layoutWheel.suspend()

        shortcuts.isEnabled = loaded.keyboardShortcutsEnabled
        shortcuts.setHandler { [weak self] action in
            // The wheel and this shortcut share held modifiers. Running the
            // shortcut means the user was never opening a wheel.
            self?.layoutWheel.cancel()
            self?.perform(action)
        }
        titleBarDoubleClick.isTabbedMember = { [weak self] id in self?.isTabbedMember(id) == true }
        dragSnap.isTabbedMember = { [weak self] id in self?.isTabbedMember(id) == true }
        dragSnap.activeModeProvider = { [weak self] displayID in self?.activeMode(for: displayID) }
        dragSnap.bentoStateProvider = { [weak self] displayID in self?.sessionStore.session(for: displayID)?.bentoState }
        dragSnap.bentoDragBeganHandler = { [weak self] displayID, sourceID, sourceFrame in
            self?.prepareWindowGesture()
            return self?.beginBentoDrag(displayID: displayID, sourceID: sourceID, sourceFrame: sourceFrame) ?? false
        }
        dragSnap.bentoPreviewHandler = { [weak self] displayID, sourceID, outcome in
            self?.previewBentoDrag(displayID: displayID, sourceID: sourceID, outcome: outcome)
        }
        dragSnap.bentoDragEndedHandler = { [weak self] displayID, sourceID, outcome in
            self?.finishBentoDrag(displayID: displayID, sourceID: sourceID, outcome: outcome)
        }
        dragSnap.gestureEndedHandler = { [weak self] in
            guard let self else { return }
            self.performDeferredDockReflow()
            self.schedulePendingWindowEvents()
        }
        dragSnap.actionResultHandler = { [weak self] displayID, succeeded, error in
            self?.presentActionResult(succeeded: succeeded, error: error, displayID: displayID)
        }
        dividerResize.stackProvider = { [weak self] ids in
            (self?.system as? any WindowStackReading)?.onScreenStack(labeling: ids)
        }
        dividerResize.ownProcess = getpid()
        dividerResize.nonOccludingWindowNumbersProvider = { [weak self] in
            self?.tabbedOverlays.values.reduce(into: Set<Int>()) { $0.formUnion($1.windowNumbers) } ?? []
        }
        dividerResize.bentoStateProvider = { [weak self] displayID in
            self?.sessionStore.session(for: displayID)?.bentoState
        }
        dividerResize.bentoStateChangedHandler = { [weak self] displayID, state, frames, baselineFrames in
            guard let self, var session = self.sessionStore.session(for: displayID) else { return }
            if session.mode == .tabbed {
                var proposal = session
                proposal.bentoState = state
                guard let tabbed = proposal.tabbedState,
                      let display = self.system.displays().first(where: { $0.id == displayID }),
                      let windows = try? self.system.visibleWindows() else { return }
                self.applyTabbedState(tabbed, session: session, display: display,
                    windows: self.bentoEligible(windows.filter { $0.displayID == displayID && $0.isEligible && !$0.isFloating }),
                    focus: nil, rememberUndo: true,
                    rollbackFrames: baselineFrames.merging(session.lastObservedFrames) { _, verified in verified })
                return
            }
            session.resumeAutomaticWrites()
            session.bentoState = state
            session.recordProposedFrames(frames)
            guard self.sessionStore.commit(session, replacing: session.revision) != nil else {
                self.pendingWindowEvents.recordFrameChanges(Set(frames.keys))
                self.schedulePendingWindowEvents()
                return
            }
            self.scheduleBentoSettlement(
                displayID: displayID,
                changedWindowIDs: Set(frames.keys),
                requestedFrames: frames,
                baselineFrames: baselineFrames
            )
        }
        dividerResize.bentoStateLiveHandler = { [weak self] displayID, state, bounds in
            self?.followTabbedDividerDrag(displayID: displayID, layout: state, bounds: bounds)
        }
        dividerResize.layoutChangedHandler = { [weak self] displayID, _ in
            self?.refreshDividerBoundaries()
        }
        dividerResize.rollbackFailureHandler = { [weak self] displayID, error in
            guard let self else { return }
            let message = error ?? "The divider change could not be rolled back."
            if self.activeMode(for: displayID) == .bento || self.activeMode(for: displayID) == .tabbed {
                self.suspendAutomaticBentoWrites(
                    displayID: displayID,
                    windows: (try? self.system.visibleWindows()) ?? [],
                    error: message
                )
            } else {
                self.statusMessage = message
                self.presentActionResult(succeeded: false, error: message, displayID: displayID)
            }
        }
        linkedResize.rollbackFailureHandler = dividerResize.rollbackFailureHandler
        dividerResize.gestureWillBeginHandler = { [weak self] in self?.prepareWindowGesture() }
        linkedResize.gestureWillBeginHandler = { [weak self] in self?.prepareWindowGesture() }
        dividerResize.gestureEndedHandler = { [weak self] in
            self?.performDeferredDockReflow()
            self?.schedulePendingWindowEvents()
        }
        linkedResize.isEnabledForDisplay = { [weak self] displayID in
            guard let self else { return false }
            return self.activeMode(for: displayID) == .manual && !self.dividerResize.isDragging
        }
        linkedResize.layoutChangedHandler = { [weak self] _, _ in
            self?.refreshDividerBoundaries()
        }
        layoutWheel.captureHandler = { [weak self] in self?.captureLayoutWheelTarget() }
        layoutWheel.previewHandler = { [weak self] command, target in
            guard let self else { return .unavailable(reason: "BetterTile is not available.") }
            return previewLayoutWheel(command, for: target)
        }
        layoutWheel.commitHandler = { [weak self] command, target in
            self?.performLayoutWheel(command, for: target)
        }
        layoutWheel.unavailableHandler = { [weak self] reason, target in
            self?.presentLayoutWheelUnavailable(reason, displayID: target.displayID)
        }
        layoutWheel.monitoringFailureHandler = { [weak self] failure in
            self?.layoutWheelMonitoringFailure = failure
        }
        layoutWheel.gestureBeganHandler = { [weak self] in
            self?.shortcuts.suspend()
        }
        layoutWheel.gestureEndedHandler = { [weak self] in
            guard let self, !self.isShortcutCaptureActive else { return }
            self.shortcuts.resume()
        }
        sharedGestureEvents.eventHandler = { [weak self] event in
            self?.dragSnap.handleSharedGestureEvent(event)
            self?.linkedResize.handleSharedGestureEvent(event)
        }
        sharedGestureEvents.fallbackHandler = { [weak self] in
            self?.setUsesSharedGestureEvents(false)
        }
        system.setWindowEventHandler { [weak self] event in self?.receiveWindowSystemEvent(event) }
        shortcuts.update(bindings: loaded.shortcuts)
        if startRuntime {
            dragSnap.start()
            titleBarDoubleClick.start()
            linkedResize.start()
            layoutWheel.start()
            refreshPermission()
            installWorkspaceTriggers()
            system.startDockFootprintMonitoring { [weak self] in
                self?.dockFootprintChanged()
            }
            system.startDisplayReconfigurationMonitoring { [weak self] in
                self?.scheduleDisplayRefresh()
            }
            refreshActiveWindows(force: true)

            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }
                self?.applyDockPolicy()
            }
        } else {
            hasAccessibilityPermission = system.requestAccessibilityPermission(prompt: false)
        }
    }

    var activeLayoutMode: LayoutMode {
        guard let activeDisplayID else { return configuration.defaultLayoutMode }
        return activeMode(for: activeDisplayID) ?? configuration.defaultLayoutMode
    }

    var activeContextDescription: String {
        guard let activeDisplayID, let session = sessionStore.session(for: activeDisplayID) else {
            return "No eligible visible windows"
        }
        return "Active display · \(session.windowIDs.count) visible window\(session.windowIDs.count == 1 ? "" : "s")"
    }

    func activeMode(for displayID: DisplayID) -> LayoutMode? {
        sessionStore.session(for: displayID)?.mode
    }

    func setActiveMode(_ mode: LayoutMode) {
        let mode = mode.availableMode
        refreshActiveWindows(force: false)
        guard let displayID = activeDisplayID else {
            statusMessage = "No display is available."
            return
        }
        sessionStore.ensure(displayID: displayID, defaultMode: configuration.defaultLayoutMode)
        if activeMode(for: displayID) == .tabbed, mode != .tabbed {
            leaveTabbed(displayID: displayID, destination: mode)
            return
        }
        sessionStore.update(displayID) {
            if $0.mode != .tabbed, mode == .tabbed {
                $0.tabbedBaselineFrames = [:]
                $0.tabbedHasEntryBaseline = false
                $0.resumeAutomaticWrites()
                // From Bento, every pane stays put. Otherwise the tab groups
                // from the last Tabbed visit (if any) come back.
                if $0.mode == .bento, $0.isBentoInitialized, $0.bentoState.root != nil {
                    $0.tabbedState = TabbedLayoutState(adopting: $0.bentoState)
                }
            }
            $0.mode = mode
        }
        if mode == .bento {
            tileCurrentDisplay()
        } else if mode == .tabbed {
            refreshActiveWindows(force: true)
        } else {
            refreshDividerBoundaries()
        }
    }

    func perform(_ action: WindowAction) {
        guard !isShutDown else { return }
        guard !isStabilizingSpace else {
            statusMessage = "Desktop changed. Try again when the Space switch finishes."
            presentActionResult(succeeded: false, error: statusMessage, displayID: activeDisplayID)
            return
        }
        let originalDisplayID = (try? system.focusedWindow())?.displayID ?? activeDisplayID
        guard hasAccessibilityPermission || refreshPermission() else {
            statusMessage = "Accessibility permission is required. Open the Setup Assistant to grant access."
            presentActionResult(
                succeeded: false,
                error: "Accessibility permission is required.",
                displayID: originalDisplayID
            )
            return
        }
        let focused = try? system.focusedWindow()
        if let focused, isTabbedMember(focused.id), !BentoDropPlanner.partitionActions.contains(action) {
            presentLayoutWheelUnavailable(tabbedSnapUnavailableReason(action), displayID: focused.displayID)
            return
        }
        let focusedRule = focused.map(rule(for:)) ?? .manageNormally
        if !focusedRule.allowsDirectPlacement {
            statusMessage = "BetterTile is set to ignore this app."
            presentActionResult(succeeded: false, error: statusMessage, displayID: originalDisplayID)
            return
        }
        if let focused, isTabbedMember(focused.id), !usesTabbedSnap(window: focused) {
            presentLayoutWheelUnavailable(Self.tabbedParticipationChanged, displayID: focused.displayID)
            return
        }
        let actionPlan: WindowActionPlan
        switch focused.map({ coordinator.plan(action, for: $0.id) }) ?? .unavailable {
        case let .ready(plan):
            actionPlan = plan
        case .unavailable:
            statusMessage = "No eligible focused window."
            presentActionResult(
                succeeded: false,
                error: statusMessage,
                displayID: originalDisplayID
            )
            return
        case let .failed(reason):
            statusMessage = reason
            presentActionResult(
                succeeded: false,
                error: statusMessage,
                displayID: originalDisplayID
            )
            return
        }
        statusMessage = nil
        if let focused, usesTabbedSnap(window: focused), BentoDropPlanner.partitionActions.contains(actionPlan.resolvedAction) {
            performTabbedSnap(actionPlan.resolvedAction, windowID: actionPlan.windowID, displayID: actionPlan.displayID)
            return
        }
        let succeeded: Bool
        if BentoDropPlanner.handlesShortcut(
            actionPlan.resolvedAction,
            in: sessionStore.session(for: actionPlan.displayID)?.mode ?? .manual,
            sourceRule: focusedRule
        ) {
            succeeded = performBentoAction(actionPlan)
        } else {
            let outcome = coordinator.perform(actionPlan)
            succeeded = outcome.isApplied
            if !succeeded { statusMessage = outcome.failureReason }
        }
        statusMessage = succeeded
            ? nil
            : statusMessage ?? "No eligible focused window."
        let resultingDisplayID = (try? system.focusedWindow())?.displayID ?? originalDisplayID
        presentActionResult(succeeded: succeeded, error: statusMessage, displayID: resultingDisplayID)
        if succeeded {
            verifyPlacementLanded(
                WindowPlacementPlan(actionPlan),
                displayID: resultingDisplayID
            )
        }
    }

    func previewLayoutWheel(
        _ command: LayoutWheelCommand,
        for target: LayoutWheelTarget
    ) -> LayoutWheelPreviewOutcome {
        switch planLayoutWheel(command, for: target) {
        case let .ready(.action(plan)):
            return .ready(placements: [Placement(windowID: plan.windowID, frame: plan.targetFrame)])
        case let .ready(.bento(proposal)):
            return .ready(placements: proposal.plan.placements)
        case let .ready(.tabbed(plan, _, _)):
            return .ready(placements: plan.placements)
        case .ready(.repairBento):
            return .ready(placements: [])
        case let .unavailable(reason, _):
            return .unavailable(reason: reason)
        }
    }

    /// Replans immediately before committing so a captured target can never
    /// silently become the currently focused window.
    func performLayoutWheel(
        _ command: LayoutWheelCommand,
        for target: LayoutWheelTarget
    ) {
        switch planLayoutWheel(command, for: target) {
        case let .unavailable(reason, displayID):
            statusMessage = reason
            presentActionResult(succeeded: false, error: reason, displayID: displayID)
        case let .ready(.repairBento(displayID, focusedWindowID)):
            repairBento(displayID: displayID, focusedWindowID: focusedWindowID)
        case let .ready(.tabbed(_, action, displayID)):
            performTabbedSnap(action, windowID: target.windowID, displayID: displayID, expectedSpaceID: target.nativeSpaceID)
        case let .ready(.action(plan)):
            let outcome = coordinator.perform(plan)
            let displayID = currentDisplayID(for: plan.windowID) ?? plan.displayID
            finishLayoutWheelPlacement(outcome: outcome, displayID: displayID)
            if outcome.isApplied {
                verifyPlacementLanded(WindowPlacementPlan(plan), displayID: displayID)
            }
        case let .ready(.bento(proposal)):
            let succeeded = commitLayoutWheelBento(proposal)
            statusMessage = succeeded
                ? nil
                : statusMessage ?? "That Layout Wheel command could not be applied."
            presentActionResult(
                succeeded: succeeded,
                error: statusMessage,
                displayID: proposal.display.id
            )
        }
    }

    /// The focused eligible window and its display, taken once when the hold
    /// succeeds. Returns nil when there is nothing the wheel may act on, which
    /// leaves the wheel closed rather than opening over an ineligible window.
    func captureLayoutWheelTarget() -> LayoutWheelTarget? {
        guard !isShutDown, !isStabilizingSpace, hasAccessibilityPermission else { return nil }
        do {
            guard let window = try system.focusedWindow(),
                  window.isEligible, !tabbedExiting.contains(window.displayID),
                  rule(for: window).allowsDirectPlacement,
                  let display = system.displays().first(where: { $0.id == window.displayID })
            else { return nil }
            return LayoutWheelTarget(
                windowID: window.id,
                displayID: window.displayID,
                visibleFrame: display.visibleFrame,
                desktopSessionID: sessionStore.session(for: display.id)?.id,
                nativeSpaceID: sessionStore.session(for: display.id)?.nativeSpaceID
                    ?? system.refreshNativeDesktopObservation()?.currentSpace(on: display.id),
                layoutMode: sessionStore.session(for: display.id)?.mode
            )
        } catch {
            return nil
        }
    }

    private func planLayoutWheel(
        _ command: LayoutWheelCommand,
        for target: LayoutWheelTarget
    ) -> LayoutWheelPlanOutcome {
        guard !isShutDown, !isStabilizingSpace, !tabbedExiting.contains(target.displayID) else {
            return .unavailable(reason: "The captured desktop is no longer available.", displayID: target.displayID)
        }
        guard hasAccessibilityPermission || refreshPermission(recoverWindows: false) else {
            return .unavailable(
                reason: "Accessibility permission is required.",
                displayID: activeDisplayID
            )
        }

        let window: WindowSnapshot
        do {
            guard let captured = try system.windowSnapshots(ids: [target.windowID]).first,
                  captured.isEligible,
                  captured.displayID == target.displayID
            else {
                return .unavailable(
                    reason: "The captured window or display is no longer available.",
                    displayID: target.displayID
                )
            }
            window = captured
        } catch {
            return .unavailable(reason: error.localizedDescription, displayID: target.displayID)
        }

        guard system.displays().contains(where: { $0.id == target.displayID && $0.visibleFrame == target.visibleFrame }),
              target.desktopSessionID == nil || sessionStore.session(for: target.displayID)?.id == target.desktopSessionID,
              target.layoutMode == nil || sessionStore.session(for: target.displayID)?.mode == target.layoutMode,
              target.nativeSpaceID == nil || (system.refreshNativeDesktopObservation()?.currentSpace(on: target.displayID)
                ?? sessionStore.session(for: target.displayID)?.nativeSpaceID) == target.nativeSpaceID
        else {
            return .unavailable(
                reason: "The captured window's display is no longer available.",
                displayID: window.displayID
            )
        }
        let sourceRule = rule(for: window)
        guard sourceRule.allowsDirectPlacement else {
            return .unavailable(
                reason: "BetterTile is set to ignore this app.",
                displayID: window.displayID
            )
        }

        switch command {
        case let .windowAction(action):
            if isTabbedMember(window.id) || (usesTabbedSnap(window: window) && BentoDropPlanner.partitionActions.contains(action)) {
                guard BentoDropPlanner.partitionActions.contains(action) else {
                    return .unavailable(reason: tabbedSnapUnavailableReason(action), displayID: window.displayID)
                }
                guard usesTabbedSnap(window: window) else {
                    return .unavailable(reason: Self.tabbedParticipationChanged, displayID: target.displayID)
                }
                guard let context = tabbedSnapContext(windowID: target.windowID, displayID: target.displayID),
                      let plan = TabbedSnapPlanner.plan(sourceWindowID: target.windowID, action: action,
                          state: context.state, windows: context.windows, in: context.display.visibleFrame)
                else { return .unavailable(reason: Self.tabbedSnapFailure, displayID: target.displayID) }
                return .ready(.tabbed(plan, action, target.displayID))
            }
            let actionPlan: WindowActionPlan
            switch coordinator.planExact(action, for: target.windowID) {
            case let .ready(plan): actionPlan = plan
            case .unavailable:
                return .unavailable(
                    reason: "The captured window is no longer available.",
                    displayID: window.displayID
                )
            case let .failed(reason):
                return .unavailable(reason: reason, displayID: window.displayID)
            }
            let usesBento = BentoDropPlanner.handlesShortcut(
                actionPlan.resolvedAction,
                in: activeMode(for: actionPlan.displayID) ?? .manual,
                sourceRule: sourceRule
            )
            guard usesBento else { return .ready(.action(actionPlan)) }
            guard let proposal = layoutWheelBentoProposal(
                intent: .snap(action: action, frame: actionPlan.targetFrame),
                sourceWindowID: target.windowID,
                displayID: actionPlan.displayID
            ) else {
                return .unavailable(
                    reason: "That Layout Wheel command cannot satisfy the Bento windows' minimum sizes.",
                    displayID: actionPlan.displayID
                )
            }
            return .ready(.bento(proposal))

        case .customZone:
            return .unavailable(
                reason: "Custom Zones are no longer available.",
                displayID: window.displayID
            )

        case .repairBento:
            guard activeMode(for: window.displayID) == .bento else {
                return .unavailable(
                    reason: "Repair Bento is available only on a Bento desktop.",
                    displayID: window.displayID
                )
            }
            return .ready(.repairBento(
                displayID: window.displayID,
                focusedWindowID: target.windowID
            ))
        }
    }

    private func presentLayoutWheelUnavailable(_ reason: String, displayID: DisplayID) {
        statusMessage = reason
        presentActionResult(succeeded: false, error: reason, displayID: displayID)
    }

    private func layoutWheelBentoProposal(
        intent: BentoDropIntent,
        sourceWindowID: WindowID,
        displayID: DisplayID
    ) -> BentoCommandProposal? {
        guard var session = sessionStore.session(for: displayID),
              session.mode == .bento,
              let display = system.displays().first(where: { $0.id == displayID }),
              let windows = try? system.visibleWindows()
        else { return nil }
        let displayWindows = bentoEligible(windows.filter {
            $0.displayID == displayID && $0.isEligible && !$0.isFloating
        })
        guard displayWindows.contains(where: { $0.id == sourceWindowID }) else { return nil }
        let baselineFrames = Dictionary(uniqueKeysWithValues: displayWindows.map { ($0.id, $0.frame) })
        let constraints = Dictionary(uniqueKeysWithValues: displayWindows.map { ($0.id, $0.constraints) })
        reconcileBentoSession(&session, windows: displayWindows, display: display)
        guard let plan = BentoDropPlanner().plan(
            intent: intent,
            sourceWindowID: sourceWindowID,
            state: session.bentoState,
            baselineFrames: baselineFrames,
            constraints: constraints,
            contextWindowIDs: Set(displayWindows.map(\.id)),
            in: display.visibleFrame
        ) else { return nil }
        return BentoCommandProposal(
            sourceWindowID: sourceWindowID,
            session: session,
            plan: plan,
            display: display,
            windows: windows,
            displayWindows: displayWindows,
            baselineFrames: baselineFrames
        )
    }

    private func commitLayoutWheelBento(_ proposal: BentoCommandProposal) -> Bool {
        var session = proposal.session
        if session.automaticWritesSuspended {
            session.resumeAutomaticWrites()
            guard let resumed = sessionStore.commit(session, replacing: session.revision) else {
                statusMessage = "The Bento session changed before the Layout Wheel command could begin. Try again."
                return false
            }
            session = resumed
        }

        let requestedFrames = Dictionary(
            uniqueKeysWithValues: proposal.plan.placements.map { ($0.windowID, $0.frame) }
        )
        session.bentoState = proposal.plan.state
        session.isBentoInitialized = true
        session.windowIDs = Set(proposal.displayWindows.map(\.id))
        session.recordProposedFrames(requestedFrames)
        session.lastWorkArea = proposal.display.visibleFrame

        if proposal.plan.isFocusDrop {
            guard let placement = proposal.plan.placements.first,
                  let sourceFrame = proposal.baselineFrames[proposal.sourceWindowID]
            else {
                statusMessage = "That Layout Wheel command could not form a valid Bento placement."
                return false
            }
            let outcome = coordinator.applyFocusDrop(
                placement: placement,
                minimizing: proposal.plan.minimizedWindowIDs,
                sourceBaselineFrame: sourceFrame
            )
            guard outcome.isApplied else {
                statusMessage = outcome.failureReason ?? "That Layout Wheel command could not be applied."
                if case let .degraded(reason) = outcome {
                    suspendAutomaticBentoWrites(
                        displayID: proposal.display.id,
                        windows: proposal.windows,
                        error: reason,
                        surfaceFailure: false
                    )
                }
                return false
            }
            session.excludedFocusWindowIDs.formUnion(proposal.plan.excludedWindowIDs)
            session.excludedFocusWindowIDs.remove(proposal.sourceWindowID)
            guard sessionStore.commit(session, replacing: session.revision) != nil else {
                statusMessage = "The Bento layout changed while the Layout Wheel command was finishing. Try again."
                pendingWindowEvents.recordTopologyChange()
                schedulePendingWindowEvents()
                return false
            }
            refreshDividerBoundaries(windows: proposal.windows)
            return true
        }

        let commitResult = commitBentoProposal(
            proposal.plan.placements,
            session: &session,
            display: proposal.display,
            recordHistory: true,
            surfaceFailure: false
        )
        guard commitResult.result == .committed else {
            if commitResult.result.needsRepair {
                suspendAutomaticBentoWrites(
                    displayID: proposal.display.id,
                    windows: proposal.windows,
                    error: commitResult.failureReason
                        ?? "The Layout Wheel command could not be rolled back.",
                    surfaceFailure: false
                )
            }
            return false
        }

        let changedWindowIDs = Set(proposal.plan.placements.compactMap { placement -> WindowID? in
            guard let baseline = proposal.baselineFrames[placement.windowID],
                  !baseline.approximatelyEquals(placement.frame, tolerance: 0.01)
            else { return nil }
            return placement.windowID
        })
        if !changedWindowIDs.isEmpty {
            scheduleBentoSettlement(
                displayID: proposal.display.id,
                changedWindowIDs: changedWindowIDs,
                requestedFrames: requestedFrames,
                baselineFrames: proposal.baselineFrames
            )
        }
        refreshDividerBoundaries(windows: proposal.windows)
        return true
    }

    private func finishLayoutWheelPlacement(
        outcome: WindowMutationOutcome,
        displayID: DisplayID?
    ) {
        statusMessage = outcome.isApplied
            ? nil
            : outcome.failureReason ?? "That Layout Wheel command could not be applied."
        presentActionResult(succeeded: outcome.isApplied, error: statusMessage, displayID: displayID)
    }

    private func currentDisplayID(for windowID: WindowID) -> DisplayID? {
        try? system.windowSnapshots(ids: [windowID]).first?.displayID
    }

    /// Corrects the reported outcome if the window never actually reached the
    /// frame it was asked for. Deliberately after the fact: an application is
    /// free to apply an Accessibility geometry change on its own run loop, so a
    /// report made at write time cannot tell a refusal from a delay.
    private func verifyPlacementLanded(_ plan: WindowPlacementPlan, displayID: DisplayID?) {
        // Read now, not inside the task: a Bento reflow can land before the
        // task body begins, and a generation read there would not see it.
        let generation = coordinator.mutationGeneration(for: plan.windowID)
        actionVerificationTask?.cancel()
        actionVerificationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let verdict = await self.coordinator.verifyPlacement(plan, since: generation)
            guard !Task.isCancelled, verdict == .failed else { return }
            self.statusMessage = "The window did not move where it was asked to."
            Self.bentoLog.notice("window did not reach its requested placement")
            self.presentActionResult(succeeded: false, error: self.statusMessage, displayID: displayID)
        }
    }

    private func performBentoAction(_ actionPlan: WindowActionPlan) -> Bool {
        guard var session = sessionStore.session(for: actionPlan.displayID),
              let display = system.displays().first(where: { $0.id == actionPlan.displayID }),
              let windows = try? system.visibleWindows()
        else { return false }
        // An explicit shortcut is a new user-owned transaction and therefore
        // clears a scoped recovery stop for this desktop.
        if session.automaticWritesSuspended {
            session.resumeAutomaticWrites()
            guard let resumed = sessionStore.commit(session, replacing: session.revision) else {
                statusMessage = "The Bento session changed before the shortcut could begin. Try again."
                return false
            }
            session = resumed
        }
        let displayWindows = bentoEligible(windows.filter {
            $0.displayID == display.id && $0.isEligible && !$0.isFloating
        })
        let frames = Dictionary(uniqueKeysWithValues: displayWindows.map { ($0.id, $0.frame) })
        let constraints = Dictionary(uniqueKeysWithValues: displayWindows.map { ($0.id, $0.constraints) })
        reconcileBentoSession(&session, windows: displayWindows, display: display)
        guard let plan = BentoDropPlanner().plan(
            intent: .snap(action: actionPlan.resolvedAction, frame: actionPlan.targetFrame),
            sourceWindowID: actionPlan.windowID,
            state: session.bentoState,
            baselineFrames: frames,
            constraints: constraints,
            contextWindowIDs: Set(displayWindows.map(\.id)),
            in: display.visibleFrame
        ) else {
            statusMessage = "That shortcut cannot satisfy the Bento windows’ minimum sizes."
            return false
        }
        let requestedFrames = Dictionary(uniqueKeysWithValues: plan.placements.map { ($0.windowID, $0.frame) })
        session.bentoState = plan.state
        session.isBentoInitialized = true
        session.windowIDs = Set(displayWindows.map(\.id))
        session.recordProposedFrames(requestedFrames)
        session.lastWorkArea = display.visibleFrame
        let commitResult = commitBentoProposal(
            plan.placements,
            session: &session,
            display: display,
            recordHistory: true,
            surfaceFailure: false
        )
        guard commitResult.result == .committed else {
            if commitResult.result.needsRepair {
                suspendAutomaticBentoWrites(
                    displayID: display.id,
                    windows: windows,
                    error: commitResult.failureReason ?? "The shortcut layout could not be rolled back.",
                    surfaceFailure: false
                )
            }
            return false
        }

        let changedWindowIDs = Set(plan.placements.compactMap { placement -> WindowID? in
            guard let baseline = frames[placement.windowID],
                  !baseline.approximatelyEquals(placement.frame, tolerance: 0.01)
            else { return nil }
            return placement.windowID
        })
        if !changedWindowIDs.isEmpty {
            scheduleBentoSettlement(
                displayID: display.id,
                changedWindowIDs: changedWindowIDs,
                requestedFrames: requestedFrames,
                baselineFrames: frames
            )
        }
        refreshDividerBoundaries(windows: windows)
        return true
    }

    func repairCurrentLayout() {
        if activeLayoutMode == .tabbed { performTabbed(.repair) }
        else { tileCurrentDisplay() }
    }

    func tileCurrentDisplay() {
        do {
            guard let focused = try system.focusedWindow() else {
                statusMessage = "No eligible window or display."
                presentActionResult(succeeded: false, error: statusMessage, displayID: activeDisplayID)
                return
            }
            repairBento(displayID: focused.displayID, focusedWindowID: focused.id)
        } catch {
            statusMessage = error.localizedDescription
            presentActionResult(succeeded: false, error: statusMessage, displayID: activeDisplayID)
        }
    }

    private func repairBento(displayID: DisplayID, focusedWindowID: WindowID) {
        do {
            let observedWindows = try system.visibleWindows()
            let nativeObservation = system.nativeDesktopObservation()
            let windows = (nativeObservation?.windowsOnCurrentSpaces(observedWindows) ?? observedWindows)
                .filter { $0.isEligible && !$0.isFloating }
            guard let focused = try system.windowSnapshots(ids: [focusedWindowID]).first,
                  focused.isEligible,
                  focused.displayID == displayID,
                  let display = system.displays().first(where: { $0.id == displayID })
            else {
                statusMessage = "The captured window or display is no longer available."
                presentActionResult(succeeded: false, error: statusMessage, displayID: displayID)
                return
            }
            let displayWindows = bentoEligible(windows.filter { $0.displayID == display.id })
            guard !displayWindows.isEmpty else {
                statusMessage = "No eligible visible windows on the active display."
                presentActionResult(succeeded: false, error: statusMessage, displayID: display.id)
                return
            }
            if var current = sessionStore.session(for: display.id),
               current.automaticWritesSuspended {
                current.resumeAutomaticWrites()
                _ = sessionStore.commit(current, replacing: current.revision)
            }
            var session = sessionStore.activate(
                displayID: display.id,
                windowIDs: Set(displayWindows.map(\.id)),
                focusedWindowID: focused.id,
                defaultMode: configuration.defaultLayoutMode,
                reuseActiveWhenUnmatched: true,
                commitObservation: false,
                nativeSpaceID: nativeObservation?.currentSpace(on: display.id)
            ).session
            // One window has no layout to repair. Restoring its configured
            // placement is the useful thing to do, and it deliberately leaves
            // the desktop's mode alone: a manual desktop stays manual.
            if displayWindows.count == 1, let window = displayWindows.first {
                repairSingleWindow(window, session: session, display: display)
                return
            }
            session.mode = .bento
            session.prepareForRepair()
            session.bentoState.metrics = BentoLayoutMetrics(paneGap: configuration.bentoInnerGap)
            let placements: [Placement]
            if displayWindows.count <= 6 {
                let result = BentoPlanner().plan(
                    state: BentoRuntimeState(
                        layout: session.bentoState,
                        reinsertionAnchors: session.bentoReinsertionAnchors
                    ),
                    observation: BentoObservation(
                        bounds: display.visibleFrame,
                        windows: displayWindows,
                        focusedWindowID: focused.id
                    ),
                    intent: .retile
                )
                guard result.writesFrames, !result.placements.isEmpty else {
                    statusMessage = "The visible windows cannot form a valid Bento layout."
                    presentActionResult(
                        succeeded: false,
                        error: statusMessage,
                        displayID: display.id
                    )
                    return
                }
                session.bentoState = result.state.layout
                session.bentoReinsertionAnchors = result.state.reinsertionAnchors
                session.automaticallyFloatingWindowIDs.removeAll()
                placements = result.placements
            } else {
                reconcileBentoSession(&session, windows: displayWindows, display: display)
                placements = BentoLayoutEngine(state: session.bentoState)
                    .placements(for: displayWindows, in: display)
            }
            session.isBentoInitialized = true
            session.lastWorkArea = display.visibleFrame
            session.lastObservedFrames = Dictionary(uniqueKeysWithValues: placements.map { ($0.windowID, $0.frame) })
            activeDisplayID = display.id
            let commitResult = commitBentoProposal(
                placements,
                session: &session,
                display: display,
                recordHistory: true,
                surfaceFailure: false
            )
            let applied = commitResult.result == .committed
            if applied {
                scheduleBentoSettlement(
                    displayID: display.id,
                    changedWindowIDs: Set(placements.map(\.windowID)),
                    requestedFrames: Dictionary(uniqueKeysWithValues: placements.map { ($0.windowID, $0.frame) }),
                    baselineFrames: Dictionary(uniqueKeysWithValues: displayWindows.map { ($0.id, $0.frame) }),
                    isAuthoritative: true
                )
            }
            statusMessage = if !applied {
                commitResult.failureReason ?? "The Bento layout could not be repaired."
            } else if !session.automaticallyFloatingWindowIDs.isEmpty {
                "Some windows are floating because their minimum sizes do not fit this display."
            } else {
                nil
            }
            presentActionResult(
                succeeded: statusMessage == nil,
                error: statusMessage,
                displayID: display.id
            )
            refreshDividerBoundaries(windows: windows)
        } catch {
            statusMessage = error.localizedDescription
            presentActionResult(succeeded: false, error: statusMessage, displayID: displayID)
        }
    }

    /// Returns the only window on a display to its configured placement.
    ///
    /// The desktop's mode is left untouched, and no Bento tree is built: with
    /// one window there is nothing to tile, and a tree seeded here would fight
    /// the placement the moment the work area changed.
    private func repairSingleWindow(_ window: WindowSnapshot, session: LayoutSession, display: DisplaySnapshot) {
        var session = session
        session.hasAppliedSingleWindowPlacement = true
        // A window left floating or focus-excluded by an earlier, busier layout
        // is skipped by reconciliation for as long as those marks survive, so
        // without this the next window to open would not tile with it. Repair
        // is the button people press when something is stuck; it has to clear
        // that state even when there is only one window to place.
        session.prepareForRepair()
        activeDisplayID = display.id

        guard let action = configuration.singleWindowPlacement,
              let frame = StandardActionEngine().targetFrame(for: action, window: window, display: display)
        else {
            session.lastWorkArea = display.visibleFrame
            _ = sessionStore.commit(session, replacing: session.revision)
            statusMessage = nil
            presentActionResult(succeeded: true, successMessage: "Nothing to repair", displayID: display.id)
            return
        }

        let placement = Placement(windowID: window.id, frame: frame)
        session.recordProposedFrames([window.id: frame])
        session.lastWorkArea = display.visibleFrame
        let commitResult = commitBentoProposal(
            [placement],
            session: &session,
            display: display,
            recordHistory: true,
            surfaceFailure: false
        )
        let applied = commitResult.result == .committed
        statusMessage = applied ? nil : (commitResult.failureReason ?? "The window could not be placed.")
        presentActionResult(succeeded: applied, error: statusMessage, displayID: display.id)
        refreshDividerBoundaries()
    }

    func beginBentoDrag(displayID: DisplayID, sourceID: WindowID, sourceFrame: BTRect? = nil) -> Bool {
        guard activeBentoDrag == nil, !tabbedExiting.contains(displayID),
              var layoutSession = sessionStore.session(for: displayID),
              layoutSession.mode == .bento || layoutSession.mode == .tabbed,
              let display = system.displays().first(where: { $0.id == displayID }),
              let windows = try? system.visibleWindows()
        else { return false }
        // Dragging one tab of a group moves only that window.
        var tabbedOrigin: UUID?
        let tabbedUndoBaseline = layoutSession.mode == .tabbed ? layoutSession.tabbedState : nil
        let tabbedSpaceID = layoutSession.nativeSpaceID
            ?? system.refreshNativeDesktopObservation()?.currentSpace(on: displayID)
        var tabbedRollbackFrames = layoutSession.lastObservedFrames.filter {
            tabbedUndoBaseline?.windowIDs.contains($0.key) == true || $0.key == sourceID
        }
        if let sourceFrame, tabbedUndoBaseline?.floatingWindowIDs.contains(sourceID) == true {
            tabbedRollbackFrames[sourceID] = sourceFrame
        }
        if layoutSession.mode == .tabbed, var tabbed = layoutSession.tabbedState {
            tabbedOrigin = tabbed.tearOff(sourceID)
            if tabbedOrigin != nil { layoutSession.tabbedState = tabbed }
        }
        guard let dragSession = BentoDragSession(
                  displayID: displayID,
                  sourceWindowID: sourceID,
                  state: layoutSession.bentoState,
                  windows: windows,
                  workArea: display.visibleFrame
              ),
              case let .started(transaction) = coordinator.beginTransaction(windowIDs: dragSession.managedWindowIDs)
        else { return false }
        layoutSession.resumeAutomaticWrites()
        guard let resumedSession = sessionStore.commit(
            layoutSession,
            replacing: layoutSession.revision
        ) else { return false }

        // The gesture now owns this desktop revision. An older placement
        // must not drain queued work into the provisional tear-off state.
        tabbedTasks[displayID]?.cancel()
        windowEventTask?.cancel()
        windowEventTask = nil
        // These callbacks may already belong to the move that triggered the
        // drag monitor. Fitting them here would resize the tree before the
        // drag is frozen. The fresh visible-window snapshot above is the
        // authoritative baseline for this gesture.
        pendingWindowEvents.removeAll()
        settlementTasks[displayID]?.cancel()
        settlementTasks.removeValue(forKey: displayID)
        bentoDragEventBuffer = WindowEventBuffer()
        activeBentoDrag = ActiveBentoDrag(
            session: dragSession,
            layoutSession: resumedSession,
            transaction: transaction,
            tabbedOrigin: tabbedOrigin,
            tabbedUndoBaseline: tabbedUndoBaseline,
            tabbedSpaceID: tabbedSpaceID,
            tabbedRollbackFrames: tabbedRollbackFrames,
            tabbedWindows: bentoEligible(windows.filter { $0.displayID == displayID && $0.isEligible && !$0.isFloating })
        )
        dividerResize.refresh(boundaries: [])
        return true
    }

    private func previewBentoDrag(
        displayID: DisplayID,
        sourceID: WindowID,
        outcome: BentoDragOutcome
    ) -> [Placement]? {
        guard let active = activeBentoDrag,
              active.session.displayID == displayID,
              active.session.sourceWindowID == sourceID
        else { return nil }
        // In Tabbed, a center drop adds a tab; there is no reflow to preview.
        if active.layoutSession.mode == .tabbed, case .swap = outcome { return nil }
        if active.layoutSession.mode == .tabbed, case let .snap(action, _) = outcome {
            guard let baseline = active.tabbedUndoBaseline,
                  sessionStore.isCurrent(active.layoutSession.id, revision: active.layoutSession.revision, on: displayID),
                  system.displays().first(where: { $0.id == displayID })?.visibleFrame == active.session.workArea,
                  active.tabbedSpaceID == nil || system.nativeDesktopObservation()?.currentSpace(on: displayID) == active.tabbedSpaceID
            else { return nil }
            if baseline.floatingWindowIDs.contains(sourceID), !BentoDropPlanner.partitionActions.contains(action),
               let window = active.tabbedWindows.first(where: { $0.id == sourceID }),
               let display = system.displays().first(where: { $0.id == displayID }),
               let frame = StandardActionEngine().targetFrame(for: action, window: window, display: display) {
                return [Placement(windowID: sourceID, frame: frame)]
            }
            return TabbedSnapPlanner.plan(sourceWindowID: sourceID, action: action, state: baseline,
                windows: active.tabbedWindows, in: active.session.workArea)?.placements
        }
        let intent: BentoDropIntent? = switch outcome {
        case let .swap(targetWindowID): .pane(targetWindowID)
        case let .insert(targetWindowID, edge): .insert(targetWindowID: targetWindowID, edge: edge)
        case let .snap(action, frame): .snap(action: action, frame: frame)
        case .restore: nil
        }
        guard let intent else { return nil }
        return BentoDropPlanner().plan(
            intent: intent,
            sourceWindowID: sourceID,
            state: active.session.originalState,
            baselineFrames: active.session.baselineFrames,
            constraints: active.session.constraints,
            contextWindowIDs: active.session.contextWindowIDs,
            in: active.session.workArea
        )?.placements
    }

    func finishBentoDrag(displayID: DisplayID, sourceID: WindowID, outcome: BentoDragOutcome) {
        guard var active = activeBentoDrag,
              active.session.displayID == displayID,
              active.session.sourceWindowID == sourceID
        else { return }

        if active.layoutSession.mode == .tabbed, let pending = tabbedTasks[displayID] {
            // Beginning this gesture superseded the older placement revision.
            // Keep owning the gesture until its task releases the apply slot.
            pending.cancel()
            let sessionID = active.layoutSession.id
            let revision = active.layoutSession.revision
            Task { @MainActor [weak self] in
                await pending.value
                guard let self, self.activeBentoDrag?.layoutSession.id == sessionID,
                      self.activeBentoDrag?.layoutSession.revision == revision else { return }
                self.finishBentoDrag(displayID: displayID, sourceID: sourceID, outcome: outcome)
            }
            return
        }
        if active.layoutSession.mode == .tabbed, case let .snap(action, _) = outcome {
            _ = coordinator.cancel(transaction: active.transaction)
            activeBentoDrag = nil
            if let baseline = active.tabbedUndoBaseline,
               let context = tabbedSnapContext(windowID: sourceID, displayID: displayID),
               context.session.id == active.layoutSession.id,
               context.session.revision == active.layoutSession.revision,
               context.display.visibleFrame == active.session.workArea,
               active.tabbedSpaceID == nil || system.refreshNativeDesktopObservation()?.currentSpace(on: displayID) == active.tabbedSpaceID {
                if baseline.floatingWindowIDs.contains(sourceID), !BentoDropPlanner.partitionActions.contains(action),
                   case let .ready(plan) = coordinator.planExact(action, for: sourceID),
                   let before = active.tabbedRollbackFrames[sourceID] {
                    let placement = WindowPlacementPlan(windowID: sourceID, displayID: displayID,
                        sourceFrame: before, targetFrame: plan.targetFrame)
                    let outcome = coordinator.perform(placement)
                    presentActionResult(succeeded: outcome.isApplied, error: outcome.failureReason, displayID: displayID)
                    if outcome.isApplied { verifyPlacementLanded(placement, displayID: displayID) }
                } else {
                    applyTabbedState(baseline, session: context.session, display: context.display,
                        windows: context.windows, focus: sourceID, rememberUndo: true,
                        rollbackFrames: active.tabbedRollbackFrames, snapAction: action, gestureBaseline: baseline, gestureSourceID: sourceID, expectedSpaceID: active.tabbedSpaceID)
                }
            } else if let baseline = active.tabbedUndoBaseline,
                      let session = sessionStore.session(for: displayID),
                      session.id == active.layoutSession.id, session.revision == active.layoutSession.revision,
                      let display = system.displays().first(where: { $0.id == displayID && $0.visibleFrame == active.session.workArea }) {
                // A failed observation still owns the same-desktop checkpoint.
                // No focus makes preparation reject; its existing recovery path
                // verifies current participants before restoring any frame.
                applyTabbedState(baseline, session: session, display: display, windows: active.tabbedWindows,
                    focus: nil, rollbackFrames: active.tabbedRollbackFrames,
                    snapAction: action, gestureBaseline: baseline, gestureSourceID: sourceID, expectedSpaceID: active.tabbedSpaceID)
            }
            replayBufferedBentoDragEvents()
            refreshDividerBoundaries()
            return
        }
        if active.layoutSession.mode == .tabbed, finishTabbedDrop(active, sourceID: sourceID, outcome: outcome) {
            activeBentoDrag = nil
            replayBufferedBentoDragEvents()
            refreshDividerBoundaries()
            return
        }
        var committed = false
        var frameTransactionCommitted = false
        var recoveryFailurePresented = false
        let intent: BentoDropIntent? = switch outcome {
        case let .swap(targetWindowID): .pane(targetWindowID)
        case let .insert(targetWindowID, edge): .insert(targetWindowID: targetWindowID, edge: edge)
        case let .snap(action, frame): .snap(action: action, frame: frame)
        case .restore where active.session.originalState.root?.windowIDs.contains(sourceID) != true: .automatic
        case .restore: nil
        }
        if let intent {
            guard let plan = BentoDropPlanner().plan(
               intent: intent,
               sourceWindowID: sourceID,
               state: active.session.originalState,
               baselineFrames: active.session.baselineFrames,
               constraints: active.session.constraints,
               contextWindowIDs: active.session.contextWindowIDs,
               in: active.session.workArea
            ) else {
                statusMessage = "That Bento drop cannot satisfy the windows’ minimum sizes."
                if active.tabbedOrigin != nil {
                    _ = finishTabbedDrop(active, sourceID: sourceID, outcome: .restore)
                }
                let recoveryFailurePresented = restoreBentoDragIfNeeded(active.session)
                if !recoveryFailurePresented {
                    presentActionResult(succeeded: false, error: statusMessage, displayID: displayID)
                }
                activeBentoDrag = nil
                replayBufferedBentoDragEvents()
                refreshDividerBoundaries()
                return
            }
            let dropOutcome: WindowMutationOutcome
            if plan.isFocusDrop, let placement = plan.placements.first,
               let baseline = active.session.baselineFrames[sourceID] {
                dropOutcome = coordinator.applyFocusDrop(
                    placement: placement,
                    minimizing: plan.minimizedWindowIDs,
                    sourceBaselineFrame: baseline
                )
            } else {
                dropOutcome = coordinator.commit(
                    transaction: &active.transaction,
                    placements: plan.placements,
                    recordHistory: true
                )
            }
            committed = dropOutcome.isApplied
            frameTransactionCommitted = committed
            if case let .degraded(reason) = dropOutcome {
                frameTransactionCommitted = true
                recoveryFailurePresented = true
                suspendAutomaticBentoWrites(
                    displayID: displayID,
                    windows: (try? system.visibleWindows()) ?? [],
                    error: reason
                )
            }
            if committed {
                let requestedFrames = Dictionary(uniqueKeysWithValues: plan.placements.map { ($0.windowID, $0.frame) })
                var proposed = active.layoutSession
                proposed.bentoState = plan.state
                proposed.recordProposedFrames(requestedFrames)
                proposed.windowIDs.insert(sourceID)
                if !proposed.bentoInsertionOrder.contains(sourceID) {
                    proposed.bentoInsertionOrder.append(sourceID)
                }
                proposed.excludedFocusWindowIDs.formUnion(plan.excludedWindowIDs)
                proposed.excludedFocusWindowIDs.remove(sourceID)
                proposed.automaticallyFloatingWindowIDs.remove(sourceID)
                if sessionStore.commit(
                    proposed,
                    replacing: active.layoutSession.revision
                ) != nil {
                    let changedWindowIDs: Set<WindowID> = Set(plan.placements.compactMap { placement -> WindowID? in
                        guard let baseline = active.transaction.baselineFrames[placement.windowID],
                              !baseline.approximatelyEquals(placement.frame, tolerance: 0.01)
                        else { return nil }
                        return placement.windowID
                    })
                    if proposed.mode == .tabbed {
                        refreshTabbedAfterBentoChange(displayID: displayID, undoBaseline: active.tabbedUndoBaseline)
                    } else if !plan.isFocusDrop, !changedWindowIDs.isEmpty {
                        scheduleBentoSettlement(
                            displayID: displayID,
                            changedWindowIDs: changedWindowIDs,
                            requestedFrames: requestedFrames,
                            baselineFrames: active.transaction.baselineFrames
                        )
                    }
                    statusMessage = nil
                } else {
                    committed = false
                    statusMessage = "The Bento layout changed while the drop was finishing. Try again."
                    pendingWindowEvents.recordTopologyChange()
                    schedulePendingWindowEvents()
                    // Keep the physical result visible; the fresh event will
                    // reduce it against the current session instead of merging
                    // the stale drag snapshot.
                }
            } else if !recoveryFailurePresented {
                statusMessage = dropOutcome.failureReason ?? "macOS rejected the Bento window update."
            }
        }

        if !committed, !frameTransactionCommitted {
            recoveryFailurePresented = restoreBentoDragIfNeeded(active.session)
        }
        if !committed, active.tabbedOrigin != nil {
            _ = finishTabbedDrop(active, sourceID: sourceID, outcome: .restore)
        }
        if intent != nil, !recoveryFailurePresented {
            presentActionResult(
                succeeded: committed,
                error: committed ? nil : statusMessage,
                displayID: displayID
            )
        }

        activeBentoDrag = nil
        replayBufferedBentoDragEvents()
        refreshDividerBoundaries()
    }

    /// Runs one complete Bento window drag with a known drop outcome. The
    /// live path starts from the drag monitor; tests use this seam.
    @discardableResult
    func completeBentoDrag(displayID: DisplayID, sourceID: WindowID, outcome: BentoDragOutcome,
                           sourceFrame: BTRect? = nil) -> Bool {
        guard beginBentoDrag(displayID: displayID, sourceID: sourceID, sourceFrame: sourceFrame) else { return false }
        finishBentoDrag(displayID: displayID, sourceID: sourceID, outcome: outcome)
        return true
    }

    /// Tabbed drops that are not Bento reflows. A center drop adds the window
    /// to that pane as a tab. A torn-off tab dropped nowhere returns to its
    /// group. Returns false to let Bento handle splits and snaps.
    private func finishTabbedDrop(_ active: ActiveBentoDrag, sourceID: WindowID, outcome: BentoDragOutcome) -> Bool {
        guard let display = system.displays().first(where: { $0.id == active.session.displayID }),
              let initial = sessionStore.session(for: active.session.displayID)?.tabbedState
        else { return false }
        let destination: UUID?
        switch outcome {
        case let .swap(targetWindowID): destination = initial.paneID(containing: targetWindowID)
        case .restore: destination = active.tabbedOrigin
        case .insert, .snap: destination = nil
        }
        guard let destination else { return false }
        _ = coordinator.cancel(transaction: active.transaction)
        // A concurrent update can replace the session between reading and
        // committing. Retry once against the current session so the dragged
        // tab is never left floating.
        for _ in 0..<2 {
            guard var session = sessionStore.session(for: active.session.displayID),
                  var state = session.tabbedState else { break }
            state.move(sourceID, to: destination)
            session.tabbedState = state
            guard let committed = sessionStore.commit(session, replacing: session.revision) else { continue }
            if let baseline = active.tabbedUndoBaseline, baseline != state {
                rememberTabbedUndo(baseline, sessionID: committed.id)
            }
            if let windows = try? system.visibleWindows() {
                let displayWindows = bentoEligible(windows.filter {
                    $0.displayID == display.id && $0.isEligible && !$0.isFloating
                })
                applyTabbedState(state, session: committed, display: display, windows: displayWindows, focus: sourceID)
            }
            return true
        }
        statusMessage = "The desktop changed during the drop. Use Repair Tabbed to return the window to a pane."
        presentActionResult(succeeded: false, error: statusMessage, displayID: display.id)
        pendingWindowEvents.recordTopologyChange()
        schedulePendingWindowEvents()
        return true
    }

    @discardableResult
    private func restoreBentoDragIfNeeded(_ session: BentoDragSession) -> Bool {
        let restorePlacement = session.restorePlacement
        guard let source = try? system.visibleWindows().first(where: { $0.id == session.sourceWindowID }),
              !source.frame.approximatelyEquals(restorePlacement.frame, tolerance: 1)
        else { return false }
        guard case let .degraded(reason) = coordinator.applyPlacements([restorePlacement], recordHistory: false) else {
            return false
        }
        suspendAutomaticBentoWrites(
            displayID: session.displayID,
            windows: (try? system.visibleWindows()) ?? [],
            error: reason
        )
        return true
    }

    private func replayBufferedBentoDragEvents() {
        let buffered = bentoDragEventBuffer.drain()
        pendingWindowEvents.formUnion(buffered)
        schedulePendingWindowEvents()
    }

    @discardableResult
    func refreshPermission(recoverWindows: Bool = true) -> Bool {
        let trusted = system.requestAccessibilityPermission(prompt: false)
        let changed = trusted != hasAccessibilityPermission
        hasAccessibilityPermission = trusted
        syncSharedGestureMonitoring()
        syncLayoutWheelMonitoring()

        guard changed else { return trusted }
        if !trusted {
            tabbedTasks.values.forEach { $0.cancel() }
            tabbedOverlays.values.forEach { $0.hide() }
            dragSnap.cancel()
            layoutWheel.cancel()
        }
        system.resetCachedWindows()
        if trusted {
            isWaitingForAccessibilityPermission = false
            permissionPollTask?.cancel()
            system.startWindowObservation()
            statusMessage = "Accessibility access granted."
            if recoverWindows { refreshActiveWindows(force: true) }
        } else {
            system.stopWindowObservation()
            dividerResize.hideAndCancel()
            statusMessage = "Accessibility access was removed. Re-enable BetterTile in System Settings."
        }
        return trusted
    }

    func requestAccessibilityPermission() {
        guard !refreshPermission() else { return }
        _ = system.requestAccessibilityPermission(prompt: true)
        isWaitingForAccessibilityPermission = true
        statusMessage = "Enable BetterTile in System Settings › Privacy & Security › Accessibility. Access will be detected automatically."
        startPermissionPolling()
    }

    func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
        isWaitingForAccessibilityPermission = true
        statusMessage = "Enable BetterTile in Accessibility. You do not need to remove and re-add a correctly signed build."
        startPermissionPolling()
    }

    func recheckAccessibilityPermission() {
        if !refreshPermission() {
            statusMessage = "BetterTile is still disabled in System Settings › Privacy & Security › Accessibility."
        }
    }

    func updateConfiguration(_ update: (inout BetterTileConfiguration) -> Void) {
        var candidate = configuration
        update(&candidate)
        do {
            let validated = try candidate.validated()
            guard validated != configuration else { return }
            let previous = configuration
            let changes = ConfigurationChangeSet.between(previous, validated)
            let gapChanged = validated.bentoInnerGap != previous.bentoInnerGap
            configuration = validated
            applyRuntimeConfiguration(changes)
            scheduleConfigurationSave()
            if gapChanged {
                for displayID in sessionStore.sessions.keys {
                    sessionStore.update(displayID) {
                        $0.bentoState.metrics = BentoLayoutMetrics(paneGap: configuration.bentoInnerGap)
                    }
                }
                refreshActiveWindows(force: true)
            }
            statusMessage = nil
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func assign(shortcut: KeyboardShortcut?, to action: WindowAction) {
        updateConfiguration { configuration in
            if let index = configuration.shortcuts.firstIndex(where: { $0.action == action }) {
                configuration.shortcuts[index].shortcut = shortcut
            } else {
                configuration.shortcuts.append(.init(action: action, shortcut: shortcut))
            }
        }
    }

    func setShortcutCaptureActive(_ isActive: Bool) {
        isShortcutCaptureActive = isActive
        isActive ? shortcuts.suspend() : shortcuts.resume()
        syncLayoutWheelMonitoring()
    }

    private func syncLayoutWheelMonitoring() {
        if hasAccessibilityPermission, !isShortcutCaptureActive {
            layoutWheel.resume()
        } else {
            layoutWheel.suspend()
        }
    }

    func flushConfiguration() {
        configurationSaveTask?.cancel()
        configurationSaveTask = nil
        persistConfiguration()
    }

    func shutdown() {
        guard !isShutDown else { return }
        // A held divider can roll back to pane frames. Finish that rollback
        // before restoring the windows' Native entry frames.
        dividerResize.hideAndCancel()
        for (displayID, session) in sessionStore.sessions where session.mode == .tabbed {
            if let display = system.displays().first(where: { $0.id == displayID }),
               let windows = try? system.visibleWindows() {
                _ = coordinator.applyPlacements(
                    tabbedRestorationPlacements(baselineFrames: session.tabbedBaselineFrames, on: display, windows: windows),
                    recordHistory: false
                )
            }
        }
        tabbedTasks.values.forEach { $0.cancel() }
        tabbedFocusTask?.cancel()
        tabbedResizeReleaseTask?.cancel()
        tabbedOverlays.values.forEach { $0.hide() }
        isShutDown = true
        for token in notificationTokens {
            NotificationCenter.default.removeObserver(token)
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
        notificationTokens.removeAll()
        actionVerificationTask?.cancel()
        flushConfiguration()
        watchdogTimer?.invalidate()
        watchdogTimer = nil
        permissionPollTask?.cancel()
        windowEventTask?.cancel()
        spaceStabilizationTask?.cancel()
        displayRefreshDebouncer.cancel()
        settlementTasks.values.forEach { $0.cancel() }
        system.stopDockFootprintMonitoring()
        system.stopDisplayReconfigurationMonitoring()
        system.stopWindowObservation()
        layoutWheel.stop()
        shortcuts.stop()
        sharedGestureEvents.stop()
        dragSnap.stop()
        titleBarDoubleClick.stop()
        linkedResize.stop()
        resultPill?.hide()
        resultPill = nil
    }

    private func scheduleConfigurationSave() {
        configurationNeedsSave = true
        configurationSaveTask?.cancel()
        configurationSaveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self?.configurationSaveTask = nil
            self?.persistConfiguration()
        }
    }

    private func persistConfiguration() {
        guard configurationNeedsSave else { return }
        let interval = Self.signposter.beginInterval("saveConfiguration")
        defer { Self.signposter.endInterval("saveConfiguration", interval) }
        do {
            try store.save(configuration)
            configurationNeedsSave = false
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func applyRuntimeConfiguration(_ changes: ConfigurationChangeSet) {
        let interval = Self.signposter.beginInterval("applyConfiguration")
        defer { Self.signposter.endInterval("applyConfiguration", interval) }
        if !changes.isDisjoint(with: [.snapping, .bentoGeometry, .applicationRules, .overlayAppearance]) {
            dragSnap.configuration = configuration
        }
        if !changes.isDisjoint(with: [.layoutWheel, .overlayAppearance]) {
            layoutWheel.configuration = configuration
        }
        if !changes.isDisjoint(with: [.linkedResize, .applicationRules]) {
            linkedResize.configuration = configuration
        }
        if !changes.isDisjoint(with: [.snapping, .linkedResize]) {
            syncSharedGestureMonitoring()
        }
        if !changes.isDisjoint(with: [.divider, .bentoGeometry, .overlayAppearance]) {
            dividerResize.configuration = configuration
        }
        if changes.contains(.overlayAppearance) {
            tabbedOverlays.values.forEach { $0.overlayAppearance = configuration.overlayAppearance }
            resultPill?.overlayAppearance = configuration.overlayAppearance
        }
        if changes.contains(.shortcuts) {
            shortcuts.isEnabled = configuration.keyboardShortcutsEnabled
            shortcuts.update(bindings: configuration.shortcuts)
        }
        if changes.contains(.titleBar) {
            titleBarDoubleClick.isEnabled = configuration.doubleClickTitleBarToMaximize
        }
        if changes.contains(.applicationRules) {
            titleBarDoubleClick.applicationRules = configuration.applicationRules
            refreshActiveWindows(force: true)
        }
        if changes.contains(.accessibilityWrites) {
            system.enhancedUserInterfacePolicy = configuration.enhancedUserInterfacePolicy
        }
        if changes.contains(.activationPolicy) {
            applyDockPolicy()
        }
        if !changes.isDisjoint(with: [.divider, .bentoGeometry, .linkedResize]) {
            refreshDividerBoundaries()
        }
    }

    private func syncSharedGestureMonitoring() {
        guard hasAccessibilityPermission,
              configuration.snappingEnabled || configuration.linkedResizeEnabled
        else {
            sharedGestureEvents.stop()
            setUsesSharedGestureEvents(false)
            return
        }
        setUsesSharedGestureEvents(sharedGestureEvents.start())
    }

    private func setUsesSharedGestureEvents(_ enabled: Bool) {
        dragSnap.setUsesSharedGestureEvents(enabled)
        linkedResize.setUsesSharedGestureEvents(enabled)
    }

    private func applyDockPolicy() {
        guard !isShutDown else { return }
        NSApp.setActivationPolicy(configuration.showDockIcon ? .regular : .accessory)
        guard configuration.showDockIcon,
              let icon = NSImage(named: NSImage.applicationIconName)
        else { return }
        NSApp.applicationIconImage = icon
        NSApp.dockTile.display()
    }

    func installWorkspaceTriggers() {
        guard !isShutDown else { return }
        let center = NotificationCenter.default
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        notificationTokens.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.isShutDown else { return }
                self.scheduleDisplayRefresh()
            }
        })
        notificationTokens.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.isShutDown else { return }
                self.titleBarDoubleClick.refreshSystemPolicy()
                guard self.refreshPermission(recoverWindows: false) else { return }
                self.refreshActiveWindows(force: true)
            }
        })
        notificationTokens.append(center.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.isShutDown else { return }
                self.layoutWheel.handleApplicationDeactivated()
                self.flushConfiguration()
            }
        })
        let topologyNames: [Notification.Name] = [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.didWakeNotification,
        ]
        for name in topologyNames {
            notificationTokens.append(workspaceCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self, !self.isShutDown else { return }
                    if name == NSWorkspace.didWakeNotification {
                        self.dragSnap.cancel()
                        self.layoutWheel.cancel()
                    }
                    self.system.refreshApplicationObservers()
                    self.system.triggerDockFootprintCheck()
                    self.dividerResize.hideAndCancel()
                    self.refreshActiveWindows(force: true)
                }
            })
        }
        notificationTokens.append(workspaceCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.isShutDown else { return }
                self.beginActiveSpaceStabilization()
            }
        })
        notificationTokens.append(workspaceCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.isShutDown else { return }
                self.handleApplicationActivation()
            }
        })
        let timer = Timer(timeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.isShutDown else { return }
                self.watchdog()
            }
        }
        timer.tolerance = 2.5
        RunLoop.main.add(timer, forMode: .common)
        watchdogTimer = timer
    }

    private func dockFootprintChanged() {
        if dragSnap.isGestureActive || dividerResize.isDragging {
            pendingDockReflow = true
        } else {
            refreshActiveWindows(force: true)
        }
    }

    /// Coalesces Core Graphics and AppKit display notifications into the same
    /// refresh. AppKit remains the fallback when callback registration fails.
    private func scheduleDisplayRefresh() {
        layoutWheel.cancel()
        displayRefreshDebouncer.schedule { [weak self] in
            guard let self else { return }
            self.system.triggerDockFootprintCheck()
            self.dragSnap.cancel()
            self.dividerResize.hideAndCancel()
            self.refreshActiveWindows(force: true)
        }
    }

    private func performDeferredDockReflow() {
        schedulePendingWindowEvents()
        guard pendingDockReflow, !dragSnap.isGestureActive, !dividerResize.isDragging else { return }
        pendingDockReflow = false
        refreshActiveWindows(force: true)
    }

    func beginActiveSpaceStabilization() {
        tabbedFocusTask?.cancel()
        tabbedResizeReleaseTask?.cancel()
        tabbedResizeReleaseTask = nil
        tabbedQueuedIntents.removeAll()
        tabbedNeedsRefresh.removeAll()
        tabbedNeedsReapply.removeAll()
        tabbedTasks.values.forEach { $0.cancel() }
        tabbedOverlays.values.forEach { $0.hide() }
        dragSnap.cancel()
        layoutWheel.cancel()
        dividerResize.hideAndCancel()
        windowEventTask?.cancel()
        windowEventTask = nil
        settlementTasks.values.forEach { $0.cancel() }
        settlementTasks.removeAll()
        spaceStabilizationTask?.cancel()
        selectNativeDesktopSessions()
        spaceStabilizationGeneration &+= 1
        let generation = spaceStabilizationGeneration
        isStabilizingSpace = true
        spaceStabilizationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var stabilizer = DesktopObservationStabilizer()
            var latestWindows: [WindowSnapshot] = []
            for _ in 0..<4 {
                guard !Task.isCancelled, self.spaceStabilizationGeneration == generation else { return }
                guard let sampled = try? self.system.visibleWindows() else {
                    self.isStabilizingSpace = false
                    self.schedulePendingWindowEvents()
                    return
                }
                latestWindows = sampled
                let eligible = sampled.filter { $0.isEligible && !$0.isFloating }
                let membership = Dictionary(grouping: eligible, by: \.displayID)
                    .mapValues { Set($0.map(\.id)) }
                if stabilizer.observe(membership) { break }
                try? await Task.sleep(for: .milliseconds(75))
            }
            guard !Task.isCancelled, self.spaceStabilizationGeneration == generation else { return }
            self.pendingWindowEvents.removeAll()
            self.coordinator.finishExpectedMutations(observing: latestWindows)
            self.suppressSpaceFrameEventsUntil = Date().addingTimeInterval(0.3)
            self.isStabilizingSpace = false
            self.refreshActiveWindows(force: true, windows: latestWindows, desktopTransition: true)
            self.schedulePendingWindowEvents()
        }
    }

    /// A native Space change selects the exact runtime session immediately.
    /// Membership still stabilizes twice before the normal refresh may write.
    private func selectNativeDesktopSessions() {
        guard let observation = system.refreshNativeDesktopObservation() else {
            nativeFullscreenDisplayIDs.removeAll()
            return
        }
        sessionStore.removeMissingNativeSpaces(observation.knownSpacesByDisplay)
        for (displayID, nativeSpaceID) in observation.currentSpaceByDisplay {
            sessionStore.select(
                displayID: displayID,
                nativeSpaceID: nativeSpaceID,
                defaultMode: configuration.defaultLayoutMode
            )
        }
        nativeFullscreenDisplayIDs = Set(observation.currentSpaceByDisplay.compactMap {
            observation.fullscreenSpaceIDs.contains($0.value) ? $0.key : nil
        })
    }

    func handleApplicationActivation() {
        layoutWheel.handleApplicationDeactivated()
        refreshFocusedDisplayWithoutLayout()
        handleTabbedFocus()
    }

    private func refreshFocusedDisplayWithoutLayout() {
        dividerResize.hideAndCancel()
        guard !isStabilizingSpace, let focused = try? system.focusedWindow() else { return }
        activeDisplayID = focused.displayID
        refreshDividerBoundaries()
    }

    private func watchdog() {
        guard refreshPermission() else { return }
        guard activeBentoDrag == nil, !isStabilizingSpace else { return }
        guard let windows = try? system.visibleWindows() else { return }
        if !dividerResize.isDragging {
            coordinator.verifyExpectedMutations(observing: windows)
        }
        let workAreaSignature = displayWorkAreaSignature(system.displays())
        if workAreaSignature != lastDisplayWorkAreaSignature {
            lastDisplayWorkAreaSignature = workAreaSignature
            dividerResize.hideAndCancel()
            refreshActiveWindows(force: true, windows: windows)
            return
        }
        let signature = windowSignature(windows)
        if signature != lastVisibleSignature {
            refreshActiveWindows(force: false, windows: windows)
            return
        }
        let driftedWindowIDs = sessionStore.sessions.values.reduce(into: Set<WindowID>()) { result, session in
            result.formUnion(session.driftedManagedWindowIDs(in: windows))
        }
        if !driftedWindowIDs.isEmpty {
            pendingWindowEvents.recordFrameChanges(driftedWindowIDs)
            schedulePendingWindowEvents()
        }
    }

    private func receiveWindowSystemEvent(_ event: WindowSystemEvent) {
        guard !isShutDown else { return }
        // Lifecycle evidence survives gesture buffering and Space stabilization.
        // A stale scan must not restore a pane before minimization is observed.
        if let windowID = event.windowID {
            if event.kind == .minimized { confirmedMinimizedWindowIDs.insert(windowID) }
            if event.kind == .restored || event.kind == .destroyed {
                confirmedMinimizedWindowIDs.remove(windowID)
            }
            if event.kind == .destroyed {
                confirmedGoneWindowIDs.insert(windowID)
                sessionStore.removeClosedTabbedWindow(windowID)
                tabbedUndo = tabbedUndo.mapValues { histories in
                    histories.map { original in
                        var step = original
                        step.state.removeClosedWindow(windowID)
                        step.floatingFrames.removeValue(forKey: windowID)
                        return step
                    }
                }
            }
        }
        guard !isStabilizingSpace else { return }
        // A wheel aimed at a window that just went away must not fall through to
        // whatever replaces it.
        if let windowID = event.windowID, event.kind == .destroyed || event.kind == .minimized {
            layoutWheel.handleTargetLost(windowID: windowID)
        }
        if let activeBentoDrag {
            bentoDragEventBuffer.record(event)
            if let windowID = event.windowID,
               activeBentoDrag.session.managedWindowIDs.contains(windowID),
               event.kind == .destroyed || event.kind == .minimized {
                dragSnap.cancel()
            }
            return
        }
        switch event.kind {
        case .moved, .resized:
            guard Date() >= suppressSpaceFrameEventsUntil else { return }
            pendingWindowEvents.record(event)
            // Do not leave a handle at a coordinate macOS has invalidated.
            if !dividerResize.isDragging { dividerResize.refresh(boundaries: []) }
        case .restored:
            if let windowID = event.windowID {
                pendingRestoredWindowDeadlines[windowID] = Date().addingTimeInterval(0.5)
                for displayID in sessionStore.sessions.keys {
                    guard let session = sessionStore.session(for: displayID),
                          session.excludedFocusWindowIDs.contains(windowID)
                    else { continue }
                    // A peer left minimized self-heals on the next reconcile,
                    // so an incomplete restore is logged rather than surfaced.
                    let peers = session.excludedFocusWindowIDs.subtracting([windowID])
                    if case .failed = coordinator.restoreFocusDropPeers(peers) {
                        Self.bentoLog.notice("focus-drop peer restore incomplete")
                    }
                    sessionStore.update(displayID) {
                        $0.excludedFocusWindowIDs.removeAll()
                    }
                }
                dragSnap.prepareForRestoredWindowDrag(windowID: windowID)
            }
            pendingWindowEvents.record(event)
        case .created, .destroyed, .minimized:
            pendingWindowEvents.record(event)
        case .focused:
            handleTabbedFocus()
            layoutWheel.handleFocusedWindowChanged()
        }
        schedulePendingWindowEvents()
    }

    private func schedulePendingWindowEvents(after delay: Duration = WindowEventRetryBackoff.initialDelay) {
        guard !isShutDown else { return }
        let isGestureActive = activeBentoDrag != nil || dragSnap.isGestureActive || dividerResize.isDragging
        guard pendingWindowEvents.isReadyForProcessing(
            isGestureActive: isGestureActive,
            isStabilizingSpace: isStabilizingSpace
        ) else { return }
        windowEventTask?.cancel()
        windowEventTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.processPendingWindowEvents()
        }
    }

    private func processPendingWindowEvents() {
        let isGestureActive = activeBentoDrag != nil || dragSnap.isGestureActive || dividerResize.isDragging
        guard pendingWindowEvents.isReadyForProcessing(
            isGestureActive: isGestureActive,
            isStabilizingSpace: isStabilizingSpace
        ) else { return }
        let pendingEvents = pendingWindowEvents
        let changedIDs = pendingEvents.frameEventWindowIDs
        let refreshTopology = pendingEvents.topologyChanged
        let windows: [WindowSnapshot]
        if !refreshTopology,
           !changedIDs.isEmpty,
           let targeted = try? system.cachedVisibleWindows(refreshing: changedIDs) {
            windows = targeted
        } else {
            guard let completeSweep = try? system.visibleWindows() else {
                schedulePendingWindowEvents(after: windowEventRetryBackoff.nextDelayAfterFailure())
                return
            }
            windows = completeSweep
        }
        pendingWindowEvents.acknowledge(pendingEvents)
        windowEventRetryBackoff.reset()
        let visibleIDs = Set(windows.map(\.id))
        let now = Date()
        pendingRestoredWindowDeadlines = pendingRestoredWindowDeadlines.filter { windowID, deadline in
            !visibleIDs.contains(windowID) && deadline > now
        }
        let shouldRetryRestoredWindows = !pendingRestoredWindowDeadlines.isEmpty
        if shouldRetryRestoredWindows { pendingWindowEvents.recordTopologyChange() }
        defer {
            if shouldRetryRestoredWindows { schedulePendingWindowEvents() }
        }
        guard !changedIDs.isEmpty else {
            if refreshTopology {
                refreshActiveWindows(force: false, windows: windows)
            } else {
                refreshDividerBoundaries(windows: windows)
            }
            return
        }

        let windowsByID = Dictionary(uniqueKeysWithValues: windows.map { ($0.id, $0) })
        let externalIDs = Set(changedIDs.filter { id in
            guard let frame = windowsByID[id]?.frame else { return false }
            return !coordinator.matchesExpectedMutation(windowID: id, actualFrame: frame)
        })
        coordinator.finishExpectedMutations(observing: windows)
        guard !externalIDs.isEmpty else {
            if refreshTopology {
                refreshActiveWindows(force: false, windows: windows)
            } else {
                refreshDividerBoundaries(windows: windows)
            }
            return
        }

        let displayIDs = Set(externalIDs.compactMap { windowsByID[$0]?.displayID })
        for displayID in displayIDs {
            // A BetterTile divider commit owns its read-back settlement. Do
            // not start a second adoption cycle from the same AX callbacks.
            guard settlementTasks[displayID] == nil else { continue }
            if let session = sessionStore.session(for: displayID), session.mode == .tabbed {
                adoptTabbedResize(of: externalIDs, session: session, windows: windows)
                continue
            }
            guard var session = sessionStore.session(for: displayID),
                  session.mode == .bento,
                  !session.automaticWritesSuspended,
                  let display = system.displays().first(where: { $0.id == displayID })
            else { continue }
            let displayWindows = windows.filter { session.windowIDs.contains($0.id) && $0.displayID == displayID }
            let frames = Dictionary(uniqueKeysWithValues: displayWindows.map { ($0.id, $0.frame) })
            let constraints = Dictionary(uniqueKeysWithValues: displayWindows.map { ($0.id, $0.constraints) })
            let displayChanges = Set(externalIDs.filter { id in
                guard windowsByID[id]?.displayID == displayID, let frame = frames[id] else { return false }
                return session.lastObservedFrames[id]?.approximatelyEquals(frame, tolerance: 1) != true
            })
            guard !displayChanges.isEmpty else { continue }

            // Classify before fitting. The fitter can only read a moved edge as
            // a divider position, so a window relocated by macOS's own
            // Window > Move & Resize used to have its new far edge mistaken for
            // a dragged divider, collapsing its neighbour to a sliver.
            let expectedFrames = Dictionary(
                uniqueKeysWithValues: session.bentoState
                    .placements(in: display.visibleFrame)
                    .map { ($0.windowID, $0.frame) }
            )
            let classifications = Dictionary(
                uniqueKeysWithValues: displayChanges.compactMap { id -> (WindowID, ExternalWindowChange)? in
                    guard let expected = expectedFrames[id], let observed = frames[id] else { return nil }
                    return (id, ExternalWindowChangeClassifier.classify(
                        expected: expected,
                        observed: observed,
                        in: display.visibleFrame,
                        edgeTolerance: configuration.adjacencyTolerance
                    ))
                }
            )

            let route = ExternalChangeRouter.route(classifications)
            let dividerChanges: Set<WindowID>
            switch route {
            case let .snap(windowID, action):
                // A recognised destination runs through the same planner a
                // BetterTile shortcut uses, so macOS's commands and BetterTile's
                // own produce identical layouts rather than two rules.
                let sourceBaselineFrame = session.lastObservedFrames[windowID]
                applyExternalSnap(
                    windowID: windowID,
                    action: action,
                    session: &session,
                    sourceBaselineFrame: sourceBaselineFrame,
                    displayWindows: displayWindows,
                    display: display
                )
                continue
            case .restoreLayout:
                // Unrecognised movement cannot be expressed as a weight change.
                // Put the layout back rather than let the tree drift out of
                // step with the windows; general adoption is handled separately.
                restoreBentoLayout(session: session, displayWindows: displayWindows, display: display)
                continue
            case .none:
                continue
            case let .fitDividers(ids):
                dividerChanges = ids
            }

            guard let fitted = BentoLayoutFitter(tolerance: configuration.adjacencyTolerance).fit(
                state: session.bentoState,
                currentFrames: frames,
                changedWindowIDs: dividerChanges,
                in: display.visibleFrame,
                constraints: constraints
            ) else {
                restoreBentoLayout(session: session, displayWindows: displayWindows, display: display)
                continue
            }
            session.bentoState = fitted.state
            let placements = fitted.placements.filter { session.windowIDs.contains($0.windowID) }
            let commitResult = commitBentoProposal(
                placements,
                session: &session,
                display: display,
                surfaceFailure: false
            )
            if commitResult.result == .committed {
                scheduleBentoSettlement(displayID: displayID, changedWindowIDs: dividerChanges)
            } else if commitResult.result.needsRepair {
                suspendAutomaticBentoWrites(
                    displayID: displayID,
                    windows: displayWindows,
                    error: commitResult.failureReason ?? "The divider change could not be adopted."
                )
            }
        }
        if refreshTopology {
            refreshActiveWindows(force: false)
        } else {
            refreshDividerBoundaries()
        }
    }

    /// Routes an externally produced snap through the same planner
    /// `performBentoAction` uses, so a macOS Move & Resize command and the
    /// equivalent BetterTile shortcut resolve to the same layout, including its
    /// pane-swap behaviour.
    private func applyExternalSnap(
        windowID: WindowID,
        action: WindowAction,
        session: inout LayoutSession,
        sourceBaselineFrame: BTRect?,
        displayWindows: [WindowSnapshot],
        display: DisplaySnapshot
    ) {
        let baselineFrames = Dictionary(uniqueKeysWithValues: displayWindows.map { ($0.id, $0.frame) })
        let constraints = Dictionary(uniqueKeysWithValues: displayWindows.map { ($0.id, $0.constraints) })
        guard let partition = action.partition,
              let plan = BentoDropPlanner().plan(
                  intent: .snap(action: action, frame: partition.frame(in: display.visibleFrame)),
                  sourceWindowID: windowID,
                  state: session.bentoState,
                  baselineFrames: baselineFrames,
                  constraints: constraints,
                  contextWindowIDs: Set(displayWindows.map(\.id)),
                  in: display.visibleFrame
              )
        else {
            restoreBentoLayout(session: session, displayWindows: displayWindows, display: display)
            return
        }
        // Apply before committing. A proposed tree that the coordinator could
        // not realise must not become the session's state, or the layout and
        // the windows disagree from then on.
        session.bentoState = plan.state
        // macOS's Window > Fill resolves to the same focus plan a BetterTile
        // maximize does, and a focus plan covers its peers instead of tiling
        // beside them. Committing only its placement would leave those peers
        // visible under the filled window while the tree still called them
        // tiled.
        if plan.isFocusDrop {
            guard let sourceBaselineFrame else {
                restoreBentoLayout(session: session, displayWindows: displayWindows, display: display)
                return
            }
            applyExternalFocusDrop(
                plan: plan,
                windowID: windowID,
                session: &session,
                sourceBaselineFrame: sourceBaselineFrame,
                displayWindows: displayWindows,
                display: display
            )
            return
        }
        let commitResult = commitBentoProposal(
            plan.placements,
            session: &session,
            display: display,
            surfaceFailure: false
        )
        guard commitResult.result == .committed else {
            guard commitResult.result.needsRepair else { return }
            suspendAutomaticBentoWrites(
                displayID: display.id,
                windows: displayWindows,
                error: commitResult.failureReason ?? "The external window change could not be adopted."
            )
            return
        }
        scheduleBentoSettlement(displayID: display.id, changedWindowIDs: Set(plan.placements.map(\.windowID)))
        refreshDividerBoundaries()
    }

    /// Applies a focus plan that arrived from macOS rather than from a drag.
    ///
    /// Mirrors the focus-drop branch of `finishBentoDrag`: one placement and
    /// the peers it covers are minimized together so a rejected write rolls
    /// both back, and the covered peers are recorded so restoring one brings
    /// back the rest.
    private func applyExternalFocusDrop(
        plan: BentoDropPlan,
        windowID: WindowID,
        session: inout LayoutSession,
        sourceBaselineFrame: BTRect,
        displayWindows: [WindowSnapshot],
        display: DisplaySnapshot
    ) {
        guard let placement = plan.placements.first else { return }
        let expectedRevision = session.revision
        guard sessionStore.isCurrent(session.id, revision: expectedRevision, on: display.id) else {
            Self.bentoLog.notice("discarded stale focus plan for revision \(expectedRevision, privacy: .public)")
            pendingWindowEvents.recordTopologyChange()
            schedulePendingWindowEvents()
            return
        }
        let outcome = coordinator.applyFocusDrop(
            placement: placement,
            minimizing: plan.minimizedWindowIDs,
            sourceBaselineFrame: sourceBaselineFrame
        )
        guard outcome.isApplied else {
            if case let .degraded(reason) = outcome {
                suspendAutomaticBentoWrites(displayID: display.id, windows: displayWindows, error: reason)
            }
            return
        }
        session.excludedFocusWindowIDs.formUnion(plan.excludedWindowIDs)
        session.excludedFocusWindowIDs.remove(windowID)
        session.recordProposedFrames([placement.windowID: placement.frame])
        guard let committed = sessionStore.commit(session, replacing: expectedRevision) else {
            Self.bentoLog.error("CAS conflict after a focus plan on revision \(expectedRevision, privacy: .public)")
            pendingWindowEvents.recordTopologyChange()
            schedulePendingWindowEvents()
            return
        }
        session = committed
        // A focus plan covers rather than tiles, so there are no sibling frames
        // to settle. Settling here would read the covered peers as drift.
        refreshDividerBoundaries()
    }

    /// Validates, applies, and only then commits a proposed Bento layout.
    /// Distinguishes a rejected platform write from a stale proposal so ambient
    /// conflicts can be re-reduced without needlessly suspending the display.
    /// The failure reason accompanies the result so callers surface the cause
    /// of the exact operation they attempted.
    @discardableResult
    private func commitBentoProposal(
        _ placements: [Placement],
        session: inout LayoutSession,
        display: DisplaySnapshot,
        recordHistory: Bool = false,
        surfaceFailure: Bool = true
    ) -> (result: BentoProposalCommitResult, failureReason: String?) {
        let expectedRevision = session.revision
        guard sessionStore.isCurrent(session.id, revision: expectedRevision, on: display.id) else {
            statusMessage = "The Bento layout changed before this update could finish. Try again."
            Self.bentoLog.notice("discarded stale proposal for revision \(expectedRevision, privacy: .public)")
            pendingWindowEvents.recordTopologyChange()
            schedulePendingWindowEvents()
            if surfaceFailure {
                presentActionResult(succeeded: false, error: statusMessage, displayID: display.id)
            }
            return (.stale, statusMessage)
        }
        guard bentoProposalIsContained(placements, in: display) else {
            statusMessage = "That layout would have placed a window outside the screen area."
            Self.bentoLog.error("rejected proposal: a pane fell outside the work area")
            if surfaceFailure {
                presentActionResult(succeeded: false, error: statusMessage, displayID: display.id)
            }
            return (.rejected, statusMessage)
        }
        let applyOutcome = coordinator.applyPlacements(placements, recordHistory: recordHistory)
        guard applyOutcome.isApplied else {
            statusMessage = applyOutcome.failureReason ?? "That layout could not be applied."
            Self.bentoLog.error("proposal rejected by the window system")
            if surfaceFailure {
                presentActionResult(succeeded: false, error: statusMessage, displayID: display.id)
            }
            if case .degraded = applyOutcome {
                return (.degraded, statusMessage)
            }
            return (.rejected, statusMessage)
        }
        session.recordProposedFrames(
            Dictionary(uniqueKeysWithValues: placements.map { ($0.windowID, $0.frame) })
        )
        guard let committed = sessionStore.commit(session, replacing: expectedRevision) else {
            // Main-actor calls cannot normally race while the coordinator is
            // applying synchronously. If re-entrant platform work does mutate
            // the session, discard the stale value and reduce a fresh event.
            statusMessage = "The Bento layout changed while macOS was applying it. Try again."
            Self.bentoLog.error("CAS conflict after applying revision \(expectedRevision, privacy: .public)")
            pendingWindowEvents.recordTopologyChange()
            schedulePendingWindowEvents()
            if surfaceFailure {
                presentActionResult(succeeded: false, error: statusMessage, displayID: display.id)
            }
            return (.stale, statusMessage)
        }
        session = committed
        return (.committed, nil)
    }

    // MARK: - Application rules

    /// Applications with a rule, newest decisions included, resolved to names
    /// where macOS can still tell us one.
    var ruledApplications: [(bundleIdentifier: String, name: String, rule: ApplicationRule)] {
        configuration.applicationRules.entries.map { entry in
            (entry.bundleIdentifier, Self.applicationName(for: entry.bundleIdentifier), entry.rule)
        }
    }

    /// Running applications the user could give a rule to, minus the ones that
    /// already have one and minus BetterTile itself.
    var addableApplications: [ApplicationRuleCandidate] {
        let running = NSWorkspace.shared.runningApplications.compactMap { application -> ApplicationRuleCandidate? in
            guard application.activationPolicy == .regular,
                  let bundleIdentifier = application.bundleIdentifier
            else { return nil }
            return ApplicationRuleCandidate(
                bundleIdentifier: bundleIdentifier,
                name: application.localizedName ?? Self.applicationName(for: bundleIdentifier)
            )
        }
        return configuration.applicationRules.addableCandidates(
            from: running,
            excluding: Bundle.main.bundleIdentifier ?? ""
        )
    }

    /// Resolves an application bundle the user browsed to, so a rule can be set
    /// for something that is not currently running.
    func candidate(atApplicationURL url: URL) -> ApplicationRuleCandidate? {
        guard let bundleIdentifier = Bundle(url: url)?.bundleIdentifier else { return nil }
        return ApplicationRuleCandidate(
            bundleIdentifier: bundleIdentifier,
            name: FileManager.default.displayName(atPath: url.path)
        )
    }

    static func applicationIcon(for bundleIdentifier: String) -> NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    func setRule(_ rule: ApplicationRule, for bundleIdentifier: String) {
        updateConfiguration { $0.applicationRules.set(rule, for: bundleIdentifier) }
        statusMessage = rule == .manageNormally
            ? "\(Self.applicationName(for: bundleIdentifier)) is managed normally again."
            : "\(Self.applicationName(for: bundleIdentifier)): \(rule.title)."
    }

    func clearRule(for bundleIdentifier: String) {
        updateConfiguration { $0.applicationRules.clear(bundleIdentifier) }
    }

    static func applicationName(for bundleIdentifier: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            return FileManager.default.displayName(atPath: url.path)
        }
        // An application that is not installed keeps its rule and its
        // identifier, so a rule set carried between Macs is not silently lost.
        return bundleIdentifier
    }

    /// The rule the user has set for the application owning this window.
    private func rule(for window: WindowSnapshot) -> ApplicationRule {
        configuration.applicationRules.rule(for: window.bundleIdentifier)
    }

    /// Windows Bento may lay out. Excluded applications keep their own size and
    /// position instead of becoming panes.
    private func bentoEligible(_ windows: [WindowSnapshot]) -> [WindowSnapshot] {
        windows.filter {
            !confirmedMinimizedWindowIDs.contains($0.id) && rule(for: $0).allowsBentoParticipation
        }
    }

    /// Bento panes are derived from the whole work area, so a pane that leaves
    /// it is a bad proposal. Stricter than the coordinator's reachability rule,
    /// which only asks whether a deliberately placed window is still grabbable.
    private func bentoProposalIsContained(_ placements: [Placement], in display: DisplaySnapshot) -> Bool {
        placements.allSatisfy { PlacementBounds.isContained($0.frame, in: display.visibleFrame) }
    }

    /// Re-applies the tree the session already holds, returning the windows to
    /// the last arrangement BetterTile considered valid.
    private func restoreBentoLayout(
        session: LayoutSession,
        displayWindows: [WindowSnapshot],
        display: DisplaySnapshot
    ) {
        guard !session.automaticWritesSuspended else { return }
        let placements = BentoLayoutEngine(state: session.bentoState)
            .placements(for: displayWindows, in: display)
        guard !placements.isEmpty else { return }
        var proposed = session
        let commitResult = commitBentoProposal(
            placements,
            session: &proposed,
            display: display,
            surfaceFailure: false
        )
        if commitResult.result.needsRepair {
            suspendAutomaticBentoWrites(
                displayID: display.id,
                windows: (try? system.visibleWindows()) ?? displayWindows,
                error: commitResult.failureReason ?? "The previous layout could not be restored."
            )
        }
        refreshDividerBoundaries()
    }

    /// Recovery gets one frame transaction. If macOS rejects it, resnapshot
    /// reality and wait for an explicit shortcut or Repair instead of entering
    /// another corrective-write loop.
    private func suspendAutomaticBentoWrites(
        displayID: DisplayID,
        windows: [WindowSnapshot],
        error: String,
        surfaceFailure: Bool = true
    ) {
        guard var current = sessionStore.session(for: displayID) else { return }
        Self.bentoLog.error("suspending automatic Bento placement after incomplete recovery")
        current.suspendAutomaticWrites(observing: windows)
        _ = sessionStore.commit(current, replacing: current.revision)
        statusMessage = error + " Use Repair to rebuild Bento."
        if surfaceFailure {
            presentActionResult(succeeded: false, error: statusMessage, displayID: displayID)
        }
    }

    private func scheduleBentoSettlement(
        displayID: DisplayID,
        changedWindowIDs: Set<WindowID>,
        requestedFrames: [WindowID: BTRect]? = nil,
        baselineFrames: [WindowID: BTRect]? = nil,
        isAuthoritative: Bool = false,
        workArea: BTRect? = nil
    ) {
        guard let scheduledSession = sessionStore.session(for: displayID) else { return }
        let sessionID = scheduledSession.id
        let revision = scheduledSession.revision
        let mutationGenerations = Dictionary(uniqueKeysWithValues: changedWindowIDs.map {
            ($0, coordinator.mutationGeneration(for: $0))
        })
        settlementTasks[displayID]?.cancel()
        let taskGeneration = (settlementTaskGenerations[displayID] ?? 0) &+ 1
        settlementTaskGenerations[displayID] = taskGeneration
        settlementTasks[displayID] = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.settlementTaskGenerations[displayID] == taskGeneration {
                    self.settlementTasks.removeValue(forKey: displayID)
                    self.settlementTaskGenerations.removeValue(forKey: displayID)
                }
            }
            var previous: [WindowID: BTRect]?
            var latestWindows: [WindowSnapshot] = []
            for _ in 0..<8 {
                try? await Task.sleep(for: .milliseconds(40))
                guard !Task.isCancelled,
                      self.sessionStore.isCurrent(sessionID, revision: revision, on: displayID),
                      let sampled = try? (self.system.cachedVisibleWindows(refreshing: scheduledSession.windowIDs)
                        ?? self.system.visibleWindows())
                else { return }
                latestWindows = sampled
                let frames = Dictionary(uniqueKeysWithValues: sampled.filter { changedWindowIDs.contains($0.id) }.map { ($0.id, $0.frame) })
                let hasResponded = baselineFrames == nil || frames.allSatisfy { id, frame in
                    guard let baseline = baselineFrames?[id] else { return false }
                    return requestedFrames?[id]?.approximatelyEquals(baseline, tolerance: 1) == true
                        || !frame.approximatelyEquals(baseline, tolerance: 1)
                }
                if let previous, frames.count == changedWindowIDs.count,
                   hasResponded,
                   frames.allSatisfy({ id, frame in previous[id]?.approximatelyEquals(frame, tolerance: 1) == true }) {
                    break
                }
                previous = frames
            }
            guard !Task.isCancelled else { return }
            self.coordinator.finishExpectedMutations(upTo: mutationGenerations)
            self.correctBentoAfterSettlement(
                displayID: displayID,
                sessionID: sessionID,
                revision: revision,
                changedWindowIDs: changedWindowIDs,
                windows: latestWindows,
                requestedFrames: requestedFrames,
                baselineFrames: baselineFrames,
                isAuthoritative: isAuthoritative,
                workArea: workArea
            )
        }
    }

    private func correctBentoAfterSettlement(
        displayID: DisplayID,
        sessionID: DesktopSessionID,
        revision: UInt64,
        changedWindowIDs: Set<WindowID>,
        windows: [WindowSnapshot],
        requestedFrames: [WindowID: BTRect]?,
        baselineFrames: [WindowID: BTRect]?,
        isAuthoritative: Bool,
        workArea: BTRect?
    ) {
        guard sessionStore.isCurrent(sessionID, revision: revision, on: displayID),
              var session = sessionStore.session(for: displayID), session.mode == .bento,
              let display = system.displays().first(where: { $0.id == displayID })
        else { return }
        var settledWindows = windows
        var learnedMinimum = false
        if let requestedFrames {
            let actualFrames = Dictionary(uniqueKeysWithValues: windows.map { ($0.id, $0.frame) })
            for windowID in changedWindowIDs.sorted() {
                guard let requested = requestedFrames[windowID], let actual = actualFrames[windowID] else { continue }
                guard !actual.approximatelyEquals(requested, tolerance: 2) else { continue }
                Self.bentoLog.notice("window did not settle at its requested placement")
            }
        }
        if let requestedFrames, let baselineFrames {
            let actualFrames = Dictionary(uniqueKeysWithValues: windows.map { ($0.id, $0.frame) })
            for windowID in changedWindowIDs {
                guard let requested = requestedFrames[windowID],
                      let baseline = baselineFrames[windowID],
                      let actual = actualFrames[windowID]
                else { continue }
                learnedMinimum = system.observeApplicationEnforcedMinimum(
                    windowID: windowID,
                    requested: requested,
                    baseline: baseline,
                    actual: actual
                ) || learnedMinimum
            }
            if learnedMinimum, let refreshed = try? system.visibleWindows() {
                settledWindows = refreshed
            }
        }

        let displayWindows = settledWindows.filter { session.windowIDs.contains($0.id) && $0.displayID == displayID }
        // A lone window owns its own frame. Correcting it back towards a layout
        // would undo the resize the user just performed by hand.
        guard displayWindows.count > 1 else {
            refreshDividerBoundaries()
            return
        }
        let frames = Dictionary(uniqueKeysWithValues: displayWindows.map { ($0.id, $0.frame) })
        let constraints = Dictionary(uniqueKeysWithValues: displayWindows.map { ($0.id, $0.constraints) })
        Self.bentoLog.debug("settlement branch: \(learnedMinimum ? "learned-minimum resolve" : "divider fit", privacy: .public)")
        if learnedMinimum {
            if let solved = BentoConstraintSolver().solve(
                state: session.bentoState,
                in: display.visibleFrame,
                constraints: constraints
            ) {
                session.bentoState = solved
            } else {
                reconcileBentoSession(&session, windows: displayWindows, display: display)
            }
            let placements = BentoLayoutEngine(state: session.bentoState).placements(for: displayWindows, in: display)
            let commitResult = commitBentoProposal(
                placements,
                session: &session,
                display: display,
                surfaceFailure: false
            )
            if commitResult.result.needsRepair {
                suspendAutomaticBentoWrites(
                    displayID: displayID,
                    windows: settledWindows,
                    error: commitResult.failureReason ?? "Bento could not adapt to this window's minimum size."
                )
            } else if commitResult.result == .committed, let workArea {
                // The corrected layout must settle before acknowledging the
                // work-area change, just like a layout that needed no correction.
                scheduleAuthoritativePlacementSettlement(
                    displayID: displayID,
                    sessionID: sessionID,
                    workArea: workArea,
                    placements: placements
                )
            }
            refreshDividerBoundaries()
            return
        }
        // Repair and display reflows own their requested layout. Learn a real
        // minimum before retrying; a refused width will not improve on retry.
        // Never interpret a partially applied reflow as a native divider drag.
        if isAuthoritative, let requestedFrames {
            let placements = requestedFrames.map { Placement(windowID: $0.key, frame: $0.value) }
            if placements.contains(where: { frames[$0.windowID]?.approximatelyEquals($0.frame, tolerance: 1) != true }) {
                scheduleAuthoritativePlacementSettlement(
                    displayID: displayID,
                    sessionID: sessionID,
                    workArea: workArea ?? display.visibleFrame,
                    placements: placements
                )
            } else if let workArea {
                session.lastWorkArea = workArea
                session.recordProposedFrames(requestedFrames)
                _ = sessionStore.commit(session, replacing: revision)
            }
            refreshDividerBoundaries(windows: settledWindows)
            return
        }
        if let fitted = BentoLayoutFitter(tolerance: configuration.adjacencyTolerance).fit(
            state: session.bentoState,
            currentFrames: frames,
            changedWindowIDs: changedWindowIDs,
            in: display.visibleFrame,
            constraints: constraints
        ) {
            session.bentoState = fitted.state
            let placements = fitted.placements.filter { session.windowIDs.contains($0.windowID) }
            let commitResult = commitBentoProposal(
                placements,
                session: &session,
                display: display,
                surfaceFailure: false
            )
            if commitResult.result.needsRepair {
                suspendAutomaticBentoWrites(
                    displayID: displayID,
                    windows: settledWindows,
                    error: commitResult.failureReason ?? "Bento could not adopt the settled divider."
                )
            }
        }
        refreshDividerBoundaries()
    }

    private func refreshActiveWindows(
        force: Bool,
        windows suppliedWindows: [WindowSnapshot]? = nil,
        desktopTransition: Bool = false
    ) {
        guard !isStabilizingSpace || desktopTransition else { return }
        guard activeBentoDrag == nil else {
            pendingWindowEvents.recordTopologyChange()
            return
        }
        guard hasAccessibilityPermission || refreshPermission(recoverWindows: false) else {
            activeDisplayID = system.displays().first(where: \.isMain)?.id
            return
        }
        guard let observedWindows = suppliedWindows ?? (try? system.visibleWindows()) else { return }
        let nativeObservation = system.nativeDesktopObservation()
        let windows = nativeObservation?.windowsOnCurrentSpaces(observedWindows) ?? observedWindows
        // Destroyed-window identifiers are a batch consumed by exactly one
        // completed sweep. Capturing here means an early return above leaves
        // them pending for the next attempt, while identifiers belonging to
        // manual-mode desktops or sessions that were never initialised still
        // expire at the end of this sweep instead of accumulating forever.
        let consumedDestroyedWindowIDs = confirmedGoneWindowIDs
        let consumedMinimizedWindowIDs = confirmedMinimizedWindowIDs
        let eligible = windows.filter { $0.isEligible && !$0.isFloating }
        let signature = windowSignature(eligible)
        let windowSetChanged = signature != lastVisibleSignature
        lastVisibleSignature = signature
        if force || windowSetChanged {
            NSLog("BetterTile: detected %d eligible visible window%@.", eligible.count, eligible.count == 1 ? "" : "s")
        }
        let focused = try? system.focusedWindow()
        let displays = system.displays()
        lastDisplayWorkAreaSignature = displayWorkAreaSignature(displays)
        let displayIDs = Set(displays.map(\.id))
        for id in tabbedOverlays.keys.filter({ !displayIDs.contains($0) }) {
            tabbedOverlays.removeValue(forKey: id)?.hide()
            tabbedTasks.removeValue(forKey: id)?.cancel()
            tabbedTaskIDs.removeValue(forKey: id)
        }
        sessionStore.removeMissingDisplays(displayIDs)
        if let nativeObservation {
            sessionStore.removeMissingNativeSpaces(nativeObservation.knownSpacesByDisplay)
            nativeFullscreenDisplayIDs = Set(nativeObservation.currentSpaceByDisplay.compactMap {
                nativeObservation.fullscreenSpaceIDs.contains($0.value) ? $0.key : nil
            })
        } else {
            nativeFullscreenDisplayIDs.removeAll()
        }
        var resolvedActiveDisplay: DisplayID?
        var sweepCommitted = true
        let ambientReconciler = AmbientLayoutReconciler(
            paneGap: configuration.bentoInnerGap,
            adjacencyTolerance: configuration.adjacencyTolerance,
            singleWindowPlacement: configuration.singleWindowPlacement,
            newWindowSide: configuration.bentoNewWindowSide
        )

        for display in displays {
            let displayWindows = bentoEligible(eligible.filter { $0.displayID == display.id })
            let activation = sessionStore.activate(
                displayID: display.id,
                windowIDs: Set(displayWindows.map(\.id)),
                focusedWindowID: focused?.displayID == display.id ? focused?.id : nil,
                defaultMode: configuration.defaultLayoutMode,
                reuseActiveWhenUnmatched: !desktopTransition,
                commitObservation: false,
                nativeSpaceID: nativeObservation?.currentSpace(on: display.id)
            )
            if focused?.displayID == display.id { resolvedActiveDisplay = display.id }
            if nativeObservation?.allowsAutomaticLayout(on: display.id) == false {
                tabbedOverlays[display.id]?.hide()
                let committed = sessionStore.commit(
                    activation.session,
                    replacing: activation.session.revision
                ) != nil
                sweepCommitted = sweepCommitted && committed
                continue
            }
            if activation.session.mode == .tabbed {
                refreshTabbedSession(
                    activation.session, display: display, windows: displayWindows,
                    removed: consumedDestroyedWindowIDs.union(consumedMinimizedWindowIDs)
                        .union(windows.filter { $0.displayID != display.id || !$0.isEligible }.map(\.id))
                        .union(activation.session.tabbedState?.windowIDs.filter { id in
                            guard let memberships = nativeObservation?.windowMembership[id],
                                  let space = activation.session.nativeSpaceID else { return false }
                            return !memberships.isEmpty && memberships != [space]
                        } ?? []),
                    focused: focused?.id, force: force || desktopTransition
                )
                continue
            }
            tabbedOverlays[display.id]?.hide()
            let shouldLogHeldAbsences = activation.session.mode == .bento
                && !activation.session.automaticWritesSuspended
                && !activation.wasCreated
                && !desktopTransition
                && activation.session.isBentoInitialized
            let transition = ambientReconciler.transition(
                session: activation.session,
                observation: AmbientLayoutObservation(
                    display: display,
                    windows: displayWindows,
                    wasCreated: activation.wasCreated,
                    previousWindowIDs: activation.previousWindowIDs,
                    isDesktopTransition: desktopTransition,
                    confirmedGone: consumedDestroyedWindowIDs,
                    confirmedMinimized: consumedMinimizedWindowIDs,
                    knownSpaceWindowIDs: (nativeObservation?.exclusiveWindowIDs(on: display.id) ?? [])
                        .subtracting(eligible.filter { $0.displayID != display.id }.map(\.id))
                )
            )
            if shouldLogHeldAbsences {
                logHeldAbsences(in: transition.session)
            }

            switch transition {
            case let .placeSingleWindow(proposed, placement):
                var session = proposed
                let result = commitBentoProposal(
                    [placement],
                    session: &session,
                    display: display,
                    surfaceFailure: false
                )
                sweepCommitted = sweepCommitted && result.result == .committed
                if result.result.needsRepair {
                    suspendAutomaticBentoWrites(
                        displayID: display.id,
                        windows: windows,
                        error: result.failureReason ?? "The window could not follow the desktop update."
                    )
                }
            case let .applyLayout(proposed, placements, settleWorkArea):
                var session = proposed
                let result = commitBentoProposal(
                    placements,
                    session: &session,
                    display: display,
                    surfaceFailure: false
                )
                let applied = result.result == .committed
                sweepCommitted = sweepCommitted && applied
                if result.result.needsRepair {
                    suspendAutomaticBentoWrites(
                        displayID: display.id,
                        windows: windows,
                        error: result.failureReason ?? "Bento could not follow the desktop update."
                    )
                }
                if applied {
                    scheduleBentoSettlement(
                        displayID: display.id,
                        changedWindowIDs: Set(placements.map(\.windowID)),
                        requestedFrames: Dictionary(uniqueKeysWithValues: placements.map { ($0.windowID, $0.frame) }),
                        baselineFrames: Dictionary(uniqueKeysWithValues: displayWindows.map { ($0.id, $0.frame) }),
                        isAuthoritative: true,
                        workArea: settleWorkArea
                    )
                } else if settleWorkArea != nil, !result.result.needsRepair {
                    statusMessage = result.failureReason ?? "Some windows could not follow the updated screen area."
                    presentActionResult(succeeded: false, error: statusMessage, displayID: display.id)
                }
            case let .observe(session):
                let committed = sessionStore.commit(session, replacing: session.revision) != nil
                sweepCommitted = sweepCommitted && committed
            }
        }
        if sweepCommitted {
            confirmedGoneWindowIDs.subtract(consumedDestroyedWindowIDs)
            // A desktop-transition sweep deliberately does not reconcile its
            // stored tree. Retain minimize evidence for the first normal sweep
            // so the reducer can still capture the pane's reinsertion anchor.
            if !desktopTransition {
                let stillReportedVisible = Set(windows.filter(\.isEligible).map(\.id))
                confirmedMinimizedWindowIDs.subtract(consumedMinimizedWindowIDs.subtracting(stillReportedVisible))
            }
        } else {
            pendingWindowEvents.recordTopologyChange()
            schedulePendingWindowEvents()
        }
        activeDisplayID = resolvedActiveDisplay
            ?? activeDisplayID.flatMap { current in displays.contains(where: { $0.id == current }) ? current : nil }
            ?? displays.first(where: { !(sessionStore.session(for: $0.id)?.windowIDs.isEmpty ?? true) })?.id
            ?? displays.first(where: \.isMain)?.id
        system.updateManagedWindowIDs(Set(eligible.map(\.id)).union(sessionStore.sessions.values.flatMap { $0.tabbedState?.windowIDs ?? [] }))
        refreshDividerBoundaries(windows: eligible)
    }

    private func scheduleAuthoritativePlacementSettlement(
        displayID: DisplayID,
        sessionID: DesktopSessionID,
        workArea: BTRect,
        placements: [Placement]
    ) {
        guard let scheduledSession = sessionStore.session(for: displayID),
              scheduledSession.id == sessionID
        else { return }
        let revision = scheduledSession.revision
        settlementTasks[displayID]?.cancel()
        let taskGeneration = (settlementTaskGenerations[displayID] ?? 0) &+ 1
        settlementTaskGenerations[displayID] = taskGeneration
        settlementTasks[displayID] = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.settlementTaskGenerations[displayID] == taskGeneration {
                    self.settlementTasks.removeValue(forKey: displayID)
                    self.settlementTaskGenerations.removeValue(forKey: displayID)
                }
            }
            let outcome = await self.coordinator.settleAuthoritativePlacements(placements)
            guard !Task.isCancelled,
                  self.sessionStore.isCurrent(sessionID, revision: revision, on: displayID)
            else { return }

            switch outcome {
            case .applied:
                let frames = Dictionary(uniqueKeysWithValues: placements.map { ($0.windowID, $0.frame) })
                if var current = self.sessionStore.session(for: displayID) {
                    current.lastWorkArea = workArea
                    current.recordProposedFrames(frames)
                    _ = self.sessionStore.commit(current, replacing: revision)
                }
            case let .degraded(reason):
                self.suspendAutomaticBentoWrites(
                    displayID: displayID,
                    windows: (try? self.system.visibleWindows()) ?? [],
                    error: reason
                )
            case let .failed(reason):
                if let windows = try? self.system.visibleWindows() {
                    let placementIDs = Set(placements.map(\.windowID))
                    let actualFrames = Dictionary(uniqueKeysWithValues: windows.compactMap { window in
                        placementIDs.contains(window.id) ? (window.id, window.frame) : nil
                    })
                    if var current = self.sessionStore.session(for: displayID) {
                        current.recordProposedFrames(actualFrames)
                        _ = self.sessionStore.commit(current, replacing: revision)
                    }
                }
                self.statusMessage = reason
                self.presentActionResult(
                    succeeded: false,
                    error: self.statusMessage,
                    displayID: displayID
                )
            }
            self.refreshDividerBoundaries()
        }
    }

    private func reconcileBentoSession(
        _ session: inout LayoutSession,
        windows: [WindowSnapshot],
        display: DisplaySnapshot,
        confirmedGone: Set<WindowID> = [],
        minimized: Set<WindowID> = []
    ) {
        let transition = BentoSessionReducer().reconcile(
            session: session,
            observation: BentoObservation(
                bounds: display.visibleFrame,
                windows: windows,
                focusedWindowID: session.focusedWindowID
            ),
            paneGap: configuration.bentoInnerGap,
            confirmedGone: confirmedGone,
            minimized: minimized.union(confirmedMinimizedWindowIDs),
            knownSpaceWindowIDs: system.nativeDesktopObservation()?.exclusiveWindowIDs(on: display.id) ?? [],
            newWindowSide: configuration.bentoNewWindowSide
        )
        guard case let .update(updated, _, _) = transition else { return }
        session = updated
        logHeldAbsences(in: session)
    }

    private func logHeldAbsences(in session: LayoutSession) {
        if !session.presence.pending.isEmpty {
            Self.bentoLog.debug("holding absent panes until closure is confirmed")
        }
    }

    private func displayWorkAreaSignature(_ displays: [DisplaySnapshot]) -> String {
        displays.sorted { $0.id < $1.id }.map { display in
            let frame = display.visibleFrame
            return "\(display.id.rawValue):\(frame.minX):\(frame.minY):\(frame.size.width):\(frame.size.height):\(display.scaleFactor)"
        }.joined(separator: "|")
    }

    func prepareWindowGesture() {
        // The learner resets globally. Preserve evidence for retained Tabbed
        // groups on every display and Space, including after a Native visit.
        let retainsTabs = system.displays().contains { display in
            sessionStore.allSessions(for: display.id).contains { $0.tabbedState != nil }
        }
        if !retainsTabs { system.forgetLearnedMinimums() }
    }

    private func refreshDividerBoundaries(windows suppliedWindows: [WindowSnapshot]? = nil) {
        let presentation = dividerPresentation(windows: suppliedWindows ?? ((try? system.visibleWindows()) ?? []))
        dividerResize.refresh(
            boundaries: presentation.boundaries, obscuringFrames: presentation.obscuringFrames,
            managedWindowIDs: presentation.managedWindowIDs
        )
    }

    func dividerPresentation(windows: [WindowSnapshot]) -> (boundaries: [BoundaryDescriptor], obscuringFrames: [BTRect], managedWindowIDs: [DisplayID: Set<WindowID>]) {
        let displays = Dictionary(uniqueKeysWithValues: system.displays().map { ($0.id, $0) })
        var boundaries: [BoundaryDescriptor] = []
        var managedWindowIDs: [DisplayID: Set<WindowID>] = [:]
        var tabbedObscuringFrames: [BTRect] = []
        let chrome = tabbedOverlays.values.reduce(into: Set<Int>()) { $0.formUnion($1.windowNumbers) }
        let order = sessionStore.sessions.values.contains(where: { $0.mode == .tabbed })
            ? (system as? any TabbedWindowSystem)?.stackingOrder(for: windows, excluding: chrome) : nil
        var displaysWithVerifiedOrder: Set<DisplayID> = []
        for (displayID, session) in sessionStore.sessions {
            guard !nativeFullscreenDisplayIDs.contains(displayID) else { continue }
            guard let display = displays[displayID] else { continue }
            let contextWindows = windows.filter { session.windowIDs.contains($0.id) && $0.displayID == displayID }
            switch session.mode {
            case .manual where configuration.linkedResizeEnabled:
                let linkedBoundaries = LinkedResizeEngine(
                    tolerance: configuration.adjacencyTolerance
                ).boundaries(in: contextWindows, displayID: displayID)
                for boundary in linkedBoundaries {
                    managedWindowIDs[displayID, default: []].formUnion(boundary.beforeWindowIDs)
                    managedWindowIDs[displayID, default: []].formUnion(boundary.afterWindowIDs)
                }
                boundaries += linkedBoundaries
            case .tabbed:
                // Pane boundaries stay usable when an app clamps or displaces
                // its selected window. Inactive tabs are layout members too.
                managedWindowIDs[displayID, default: []].formUnion(session.tabbedState?.windowIDs ?? [])
                boundaries += session.bentoState.boundaries(in: display.visibleFrame, displayID: displayID)
                if let state = session.tabbedState, let order {
                    let selected = Set(state.selectedWindowIDs)
                    let selectedIndices = order.indices.filter { order[$0].windowID.map(selected.contains) == true }
                    if selectedIndices.count == selected.count, let backmost = selectedIndices.max() {
                        displaysWithVerifiedOrder.insert(displayID)
                        tabbedObscuringFrames += order.prefix(backmost).filter {
                            $0.windowID.map { !state.windowIDs.contains($0) } ?? true
                        }.map(\.frame).filter { $0.intersection(display.visibleFrame) != nil }
                    }
                }
            case .bento:
                managedWindowIDs[displayID, default: []].formUnion(session.bentoState.root?.windowIDs ?? [])
                boundaries += BentoBoundaryResolver(tolerance: configuration.adjacencyTolerance).boundaries(
                    state: session.bentoState,
                    windows: contextWindows,
                    displayID: displayID,
                    bounds: display.visibleFrame
                )
            case .manual, .linked:
                break
            }
        }
        let frontmostPID = (system as? any TabbedWindowSystem)?.frontmostProcessIdentifier
            ?? NSWorkspace.shared.frontmostApplication?.processIdentifier
        return (boundaries, tabbedObscuringFrames + DividerHandleOcclusion.obscuringFrames(
            in: windows.filter {
                $0.processIdentifier == frontmostPID && !displaysWithVerifiedOrder.contains($0.displayID)
            },
            excluding: managedWindowIDs.values.reduce(into: Set<WindowID>()) { $0.formUnion($1) }
        ), managedWindowIDs)
    }

    private func windowSignature(_ windows: [WindowSnapshot]) -> String {
        windows.filter(\.isEligible).map { "\($0.displayID.rawValue):\($0.id.rawValue)" }.sorted().joined(separator: "|")
    }

    private func presentActionResult(
        succeeded: Bool,
        error: String? = nil,
        successMessage: String? = nil,
        displayID: DisplayID?
    ) {
        let feedback = succeeded
            ? successMessage.map(ResultPillFeedback.success) ?? ResultPillFeedback.success()
            : ResultPillFeedback.failure(error)
        lastActionFeedback = feedback
        let displays = system.displays()
        guard let display = displayID.flatMap({ id in displays.first { $0.id == id } })
                ?? displays.first(where: \.isMain)
                ?? displays.first
        else { return }
        let controller = resultPill ?? ResultPillController()
        resultPill = controller
        controller.overlayAppearance = configuration.overlayAppearance
        controller.show(feedback, on: display)
    }

    private func startPermissionPolling() {
        permissionPollTask?.cancel()
        permissionPollTask = Task { @MainActor [weak self] in
            for _ in 0..<120 {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled, let self else { return }
                if self.refreshPermission() { return }
            }
            guard let self, !Task.isCancelled else { return }
            self.isWaitingForAccessibilityPermission = false
        }
    }
}

private enum LayoutWheelPlanOutcome {
    case ready(LayoutWheelModelPlan)
    case unavailable(reason: String, displayID: DisplayID?)
}

private enum LayoutWheelModelPlan {
    case action(WindowActionPlan)
    case bento(BentoCommandProposal)
    case tabbed(TabbedSnapPlan, WindowAction, DisplayID)
    case repairBento(displayID: DisplayID, focusedWindowID: WindowID)
}

private struct BentoCommandProposal {
    var sourceWindowID: WindowID
    var session: LayoutSession
    var plan: BentoDropPlan
    var display: DisplaySnapshot
    var windows: [WindowSnapshot]
    var displayWindows: [WindowSnapshot]
    var baselineFrames: [WindowID: BTRect]
}

private struct ActiveBentoDrag {
    var session: BentoDragSession
    var layoutSession: LayoutSession
    var transaction: WindowFrameTransaction
    /// The tab group a dragged Tabbed tab was torn from.
    var tabbedOrigin: UUID?
    /// The Tabbed state before the drag, for Undo.
    var tabbedUndoBaseline: TabbedLayoutState?
    var tabbedSpaceID: NativeSpaceID?
    var tabbedRollbackFrames: [WindowID: BTRect]
    var tabbedWindows: [WindowSnapshot]
}

private struct TabbedUndoStep {
    var state: TabbedLayoutState
    var floatingFrames: [WindowID: BTRect] = [:]
}

private enum PendingTabbedIntent {
    case ui(TabbedUIIntent)
    case snap(WindowID, WindowAction, NativeSpaceID?)
}

// MARK: - Experimental Tabbed sessions
extension BetterTileModel {
    private func refreshTabbedSession(
        _ original: LayoutSession, display: DisplaySnapshot, windows: [WindowSnapshot],
        removed: Set<WindowID>, focused: WindowID?, force: Bool
    ) {
        guard tabbedTasks[display.id] == nil else {
            tabbedNeedsRefresh.insert(display.id)
            return
        }
        var session = original
        let wasUninitialized = session.tabbedState == nil
        var state = session.tabbedState ?? TabbedLayoutState(preset: configuration.defaultTabbedPreset)
        if !session.tabbedHasEntryBaseline {
            session.tabbedHasEntryBaseline = true
            session.tabbedBaselineFrames = Dictionary(uniqueKeysWithValues: windows.map { ($0.id, $0.frame) })
        }
        let before = state
        state.reconcile(windowIDs: windows.map(\.id), removed: removed,
                        focused: wasUninitialized ? focused : nil)
        session.tabbedState = state
        session.windowIDs = state.windowIDs
        // Removals include windows on other displays. Reconciliation above
        // already records actual membership changes; unrelated IDs must not
        // trigger placement and a queued sweep on each display forever.
        let changed = wasUninitialized || before != state || session.lastWorkArea != display.visibleFrame
        if (changed || force), !session.automaticWritesSuspended {
            applyTabbedState(state, session: session, display: display, windows: windows,
                             focus: wasUninitialized || before.activeWindowID != state.activeWindowID ? state.activeWindowID : nil)
        } else {
            _ = sessionStore.commit(session, replacing: session.revision)
            showTabbed(session: session, display: display, windows: windows)
        }
    }

    private func showTabbed(session: LayoutSession, display: DisplaySnapshot, windows: [WindowSnapshot]) {
        guard presentsTabbedChrome, session.mode == .tabbed, let state = session.tabbedState, !isStabilizingSpace,
              !nativeFullscreenDisplayIDs.contains(display.id) else { return }
        let overlay = tabbedOverlays[display.id] ?? TabbedOverlayController()
        overlay.acceptsTabDrags = tabbedTasks[display.id] == nil
        overlay.overlayAppearance = configuration.overlayAppearance
        let sessionID = session.id
        overlay.onIntent = { [weak self, weak overlay] intent in
            guard let self, self.sessionStore.session(for: display.id)?.id == sessionID else {
                overlay?.completeDrop()
                return
            }
            self.handleTabbed(intent, on: display.id)
            if self.tabbedTasks[display.id] == nil { self.tabbedOverlays[display.id]?.completeDrop() }
        }
        let focused = try? system.focusedWindow()
        let obscuring = focused.flatMap { window in
            window.displayID == display.id && !state.windowIDs.contains(window.id) ? window.frame : nil
        }
        let selected = Set(state.selectedWindowIDs)
        let windowNumbers = (system as? any TabbedWindowSystem)?.windowNumbers(
            for: windows.filter { selected.contains($0.id) }
        ) ?? [:]
        overlay.refresh(state: state, bounds: display.visibleFrame, windows: windows,
                        obscuringFrames: obscuring.map { [$0] } ?? [],
                        canUndo: !(tabbedUndo[session.id]?.isEmpty ?? true),
                        selectedWindowNumbers: windowNumbers,
                        curtainAnchorWindowNumber: repairTabbedOrder(state: state, windows: windows, bounds: display.visibleFrame)
                            .flatMap { order in
                                order.last(where: { $0.windowID.map(selected.contains) == true })?.windowID
                            }.flatMap { windowNumbers[$0] })
        tabbedOverlays[display.id] = overlay
    }

    private static let tabbedSnapFailure = "That snap cannot fit every pane within its minimum size and the 12-pane limit."
    private static let tabbedParticipationChanged = "This window no longer participates in Tabbed. Float the window to use this action."

    private func tabbedSnapUnavailableReason(_ action: WindowAction) -> String {
        switch action {
        case .maximize: "Use Change Layout → One Pane to maximize the Tabbed layout."
        case .restore: "Use Tabbed Undo to restore the previous pane arrangement."
        default: "Tabbed supports fixed half, third, two-thirds, quarter, and sixth snaps. Float the window to use this action."
        }
    }

    private func usesTabbedSnap(window: WindowSnapshot) -> Bool {
        guard !window.isFloating, rule(for: window).allowsBentoParticipation,
              let session = sessionStore.session(for: window.displayID), session.mode == .tabbed,
              let state = session.tabbedState else { return false }
        return state.windowIDs.contains(window.id) || state.floatingWindowIDs.contains(window.id)
    }

    private func tabbedSnapContext(windowID: WindowID, displayID: DisplayID)
        -> (session: LayoutSession, state: TabbedLayoutState, display: DisplaySnapshot, windows: [WindowSnapshot])? {
        guard !isShutDown, !isStabilizingSpace, hasAccessibilityPermission,
              !tabbedExiting.contains(displayID), !nativeFullscreenDisplayIDs.contains(displayID),
              let session = sessionStore.session(for: displayID), session.mode == .tabbed,
              let state = session.tabbedState,
              let display = system.displays().first(where: { $0.id == displayID }),
              let allWindows = try? system.visibleWindows() else { return nil }
        let observation = system.refreshNativeDesktopObservation()
        guard observation?.allowsAutomaticLayout(on: displayID) != false else { return nil }
        if let space = session.nativeSpaceID,
           observation?.currentSpace(on: displayID) != space { return nil }
        let windows = bentoEligible((observation?.windowsOnCurrentSpaces(allWindows) ?? allWindows)
            .filter { $0.displayID == displayID && $0.isEligible && !$0.isFloating })
        guard let source = windows.first(where: { $0.id == windowID }), usesTabbedSnap(window: source) else { return nil }
        return (session, state, display, windows)
    }

    private func performTabbedSnap(_ action: WindowAction, windowID: WindowID, displayID: DisplayID,
                                   expectedSpaceID: NativeSpaceID? = nil) {
        guard let context = tabbedSnapContext(windowID: windowID, displayID: displayID) else {
            presentLayoutWheelUnavailable("The captured Tabbed window or desktop is no longer available.", displayID: displayID)
            return
        }
        guard BentoDropPlanner.partitionActions.contains(action) else {
            presentLayoutWheelUnavailable(tabbedSnapUnavailableReason(action), displayID: displayID)
            return
        }
        if tabbedTasks[displayID] != nil {
            tabbedQueuedIntents[displayID] = .snap(windowID, action, expectedSpaceID)
            return
        }
        applyTabbedState(context.state, session: context.session, display: context.display,
            windows: context.windows, focus: windowID, rememberUndo: true, snapAction: action, expectedSpaceID: expectedSpaceID)
    }

    private func applyTabbedState(
        _ state: TabbedLayoutState, session original: LayoutSession, display: DisplaySnapshot,
        windows: [WindowSnapshot], focus: WindowID?, rememberUndo: Bool = false, consumeUndo: Bool = false,
        selectionOnly: Bool = false, rollbackFrames: [WindowID: BTRect]? = nil,
        snapAction: WindowAction? = nil, gestureBaseline: TabbedLayoutState? = nil,
        gestureSourceID: WindowID? = nil, expectedSpaceID: NativeSpaceID? = nil, restorationFrames: [WindowID: BTRect] = [:]
    ) {
        guard tabbedTasks[display.id] == nil else {
            tabbedNeedsReapply.insert(display.id)
            return
        }
        guard sessionStore.isCurrent(original.id, revision: original.revision, on: display.id) else { return }
        let expectedSpace = expectedSpaceID ?? original.nativeSpaceID ?? (snapAction == nil ? nil
            : system.refreshNativeDesktopObservation()?.currentSpace(on: display.id))
        let isSameDesktop = { @MainActor [weak self] in
            guard let self, !self.isShutDown, !self.isStabilizingSpace, self.hasAccessibilityPermission,
                  !self.nativeFullscreenDisplayIDs.contains(display.id), !self.tabbedExiting.contains(display.id),
                  self.activeMode(for: display.id) == .tabbed,
                  self.system.displays().first(where: { $0.id == display.id })?.visibleFrame == display.visibleFrame else { return false }
            let observation = self.system.refreshNativeDesktopObservation()
            guard observation?.allowsAutomaticLayout(on: display.id) != false else { return false }
            if let space = expectedSpace, observation?.currentSpace(on: display.id) != space { return false }
            if snapAction != nil, windows.contains(where: {
                (state.windowIDs.contains($0.id) || $0.id == (gestureSourceID ?? focus)) && !self.rule(for: $0).allowsBentoParticipation
            }) { return false }
            return self.sessionStore.session(for: display.id)?.id == original.id
        }
        let isCurrent = { @MainActor [weak self] in
            isSameDesktop() && self?.sessionStore.isCurrent(original.id, revision: original.revision, on: display.id) == true
        }
        guard isCurrent() else { return }
        let previous = gestureBaseline ?? sessionStore.session(for: display.id)?.tabbedState
        func restoreGestureMembership() -> LayoutSession {
            guard let gestureBaseline, isCurrent() else { return original }
            var restored = original
            restored.tabbedState = gestureBaseline
            restored.windowIDs = gestureBaseline.windowIDs
            restored.lastObservedFrames = rollbackFrames ?? original.lastObservedFrames
            return sessionStore.commit(restored, replacing: original.revision) ?? original
        }
        let detached = (previous?.windowIDs ?? []).subtracting(state.windowIDs).intersection(state.floatingWindowIDs)
        var selectionOnly = selectionOnly
        func prepare(_ windows: [WindowSnapshot]) throws -> (state: TabbedLayoutState, placements: [Placement]) {
            if selectionOnly {
                guard let focus, let window = windows.first(where: { $0.id == focus && $0.isEligible }),
                      let pane = state.panes.first(where: { $0.tabs.contains(focus) }),
                      let frame = state.frames(in: display.visibleFrame)[pane.id] else {
                    throw WindowSystemError.operationFailed("That window is no longer available.")
                }
                let content = TabbedLayoutState.contentFrame(frame)
                let minimum = window.constraints.minimumSize
                if content.size.width + 0.001 >= minimum.width,
                   content.size.height + 0.001 >= minimum.height {
                    return (state, [Placement(windowID: focus, frame: content)])
                }
                selectionOnly = false
            }
            guard Set(state.selectedWindowIDs).isSubset(of: Set(windows.filter { $0.isEligible && $0.displayID == display.id }.map(\.id))) else {
                throw WindowSystemError.operationFailed("One or more selected tabs are no longer available.")
            }
            let fitted: TabbedLayoutState
            if let snapAction {
                guard let focus, let source = windows.first(where: { $0.id == focus }),
                      self.usesTabbedSnap(window: source),
                      let plan = TabbedSnapPlanner.plan(sourceWindowID: focus, action: snapAction,
                          state: state, windows: windows, in: display.visibleFrame),
                      plan.preservesTarget(in: plan.state, within: display.visibleFrame) else {
                    throw WindowSystemError.operationFailed(BentoDropPlanner.partitionActions.contains(snapAction)
                        ? Self.tabbedSnapFailure : self.tabbedSnapUnavailableReason(snapAction))
                }
                fitted = plan.state
            } else {
                fitted = try state.fittingMinimumWidths(in: display.visibleFrame, windows: windows)
            }
            var proposed = try fitted.placements(in: display.visibleFrame, windows: windows)
            let baselineFrames = Dictionary(uniqueKeysWithValues: windows.filter { detached.contains($0.id) }.map {
                ($0.id, restorationFrames[$0.id] ?? original.tabbedBaselineFrames[$0.id]
                    ?? $0.frame.offsetBy(dx: 35, dy: 35).clamped(to: display.visibleFrame))
            })
            proposed.append(contentsOf: self.tabbedRestorationPlacements(
                baselineFrames: baselineFrames, on: display, windows: windows
            ))
            return (fitted, proposed)
        }
        let taskID = UUID()
        let initial: (state: TabbedLayoutState, placements: [Placement])
        do { initial = try prepare(windows) }
        catch {
            let reason = error.localizedDescription
            guard let rollbackFrames else {
                statusMessage = reason
                presentActionResult(succeeded: false, error: reason, displayID: display.id)
                return
            }
            tabbedTaskIDs[display.id] = taskID
            tabbedOverlays[display.id]?.acceptsTabDrags = false
            tabbedTasks[display.id] = Task { @MainActor [weak self] in
                guard let self else { return }
                defer {
                    if self.tabbedTasks[display.id] == nil, self.tabbedQueuedIntents[display.id] == nil {
                        self.tabbedOverlays[display.id]?.completeDrop()
                        self.tabbedOverlays[display.id]?.acceptsTabDrags = true
                    }
                }
                var restored = await self.coordinator.restoreTabbedFrames(rollbackFrames,
                    required: Set(previous?.selectedWindowIDs ?? []).union(gestureSourceID.map { [$0] } ?? []),
                    on: display.id, isCurrent: isCurrent)
                guard self.tabbedTaskIDs[display.id] == taskID else { return }
                self.tabbedTaskIDs.removeValue(forKey: display.id)
                self.tabbedTasks[display.id] = nil
                guard isSameDesktop(), !Task.isCancelled else {
                    self.tabbedQueuedIntents.removeValue(forKey: display.id)
                    self.tabbedNeedsReapply.remove(display.id)
                    self.tabbedNeedsRefresh.remove(display.id)
                    return
                }
                guard isCurrent() else {
                    self.drainTabbedQueuedIntent(on: display.id, sessionID: original.id)
                    self.schedulePendingWindowEvents()
                    return
                }
                let restoredSession = restoreGestureMembership()
                if restored.isApplied, gestureBaseline != nil,
                   !self.coordinator.raiseTabbedWindows(previous?.selectedWindowIDs ?? []).isApplied {
                    restored = .degraded(reason: "Tabbed could not restore window order. Use Repair Tabbed.")
                }
                if case let .degraded(reason) = restored {
                    self.suspendAutomaticBentoWrites(displayID: display.id, windows: windows, error: reason)
                } else {
                    self.statusMessage = reason
                    self.showTabbed(session: restoredSession, display: display, windows: windows)
                }
                self.presentActionResult(succeeded: false, error: self.statusMessage, displayID: display.id)
                self.drainTabbedQueuedIntent(on: display.id, sessionID: original.id)
                self.schedulePendingWindowEvents()
            }
            return
        }
        tabbedTaskIDs[display.id] = taskID
        tabbedOverlays[display.id]?.acceptsTabDrags = false
        tabbedTasks[display.id] = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.tabbedTasks[display.id] == nil, self.tabbedQueuedIntents[display.id] == nil {
                    self.tabbedOverlays[display.id]?.completeDrop()
                    self.tabbedOverlays[display.id]?.acceptsTabDrags = true
                }
            }
            var proposal = initial
            var windows = windows
            // With a readable window order, the focus refresh after a
            // selection raises only panes that activation really exposed.
            let repairsStackingAfterSelection = selectionOnly
                && (self.system as? any TabbedWindowSystem)?.stackingOrder(for: windows, excluding: []) != nil
            var outcome: WindowMutationOutcome = .failed(reason: "The desktop changed.")
            for attempt in 0..<2 {
                self.tabbedFocusSuppressedUntil = Date().addingTimeInterval(0.3)
                let eligibleIDs = selectionOnly
                    ? Set(windows.filter(\.isEligible).map(\.id))
                    : Set(proposal.placements.map(\.windowID))
                var selected = proposal.state.selectedWindowIDs.filter(eligibleIDs.contains)
                if repairsStackingAfterSelection {
                    selected = []
                } else if selectionOnly, let process = windows.first(where: { $0.id == focus })?.processIdentifier {
                    let applicationWindows = Set(windows.filter { $0.processIdentifier == process }.map(\.id))
                    // Activating an app can expose its inactive tabs in other
                    // panes. Without the window order, restore those panes'
                    // selected windows.
                    selected = proposal.state.panes.filter { $0.tabs.contains(where: applicationWindows.contains) }
                        .compactMap(\.selected).filter(eligibleIDs.contains)
                }
                var learnedSize = false
                outcome = await self.coordinator.applyTabbed(
                    placements: proposal.placements,
                    rollbackFrames: rollbackFrames,
                    rollbackDisplayID: rollbackFrames == nil ? nil : display.id,
                    rollbackRequired: snapAction == nil ? nil : Set(previous?.selectedWindowIDs ?? []),
                    // Selected tabs and newly floating windows must settle;
                    // hidden tabs stack behind their pane at best effort.
                    required: selectionOnly ? nil : Set(proposal.state.selectedWindowIDs).union(detached),
                    selected: selected,
                    previousSelected: previous?.selectedWindowIDs.filter(eligibleIDs.contains) ?? [],
                    focus: focus.flatMap { eligibleIDs.contains($0) ? $0 : nil },
                    onSizeMismatch: { id, requested, baseline, actual in
                        guard proposal.state.windowIDs.contains(id) || detached.contains(id) else { return }
                        learnedSize = self.system.observeApplicationEnforcedMinimum(
                            windowID: id, requested: requested, baseline: baseline, actual: actual
                        ) || learnedSize
                    },
                    isCurrent: isCurrent
                )
                // Retry once, only after a complete rollback and a new size
                // observation. Ignored writes and degraded outcomes never retry.
                guard case .failed = outcome, attempt == 0, learnedSize,
                      !Task.isCancelled, isCurrent() else { break }
                do {
                    let ids = Set(windows.map(\.id))
                    let refreshed = try self.system.windowSnapshots(ids: ids)
                    guard Set(refreshed.map(\.id)) == ids,
                          refreshed.allSatisfy({ $0.displayID == display.id && $0.isEligible }) else { break }
                    selectionOnly = false
                    proposal = try prepare(refreshed)
                    windows = refreshed
                } catch {
                    outcome = .failed(reason: error.localizedDescription)
                    break
                }
            }
            let state = proposal.state
            let placements = proposal.placements
            guard self.tabbedTaskIDs[display.id] == taskID else { return }
            self.tabbedTaskIDs.removeValue(forKey: display.id)
            self.tabbedTasks[display.id] = nil
            guard !Task.isCancelled, isSameDesktop() else {
                self.tabbedQueuedIntents.removeValue(forKey: display.id)
                self.tabbedNeedsReapply.remove(display.id)
                self.tabbedNeedsRefresh.remove(display.id)
                return
            }
            guard isCurrent() else {
                self.drainTabbedQueuedIntent(on: display.id, sessionID: original.id)
                self.schedulePendingWindowEvents()
                return
            }
            if outcome.isApplied {
                var proposed = original
                proposed.tabbedState = state
                proposed.windowIDs = state.windowIDs
                proposed.lastWorkArea = display.visibleFrame
                let placedFrames = Dictionary(uniqueKeysWithValues: placements.map { ($0.windowID, $0.frame) })
                proposed.lastObservedFrames = selectionOnly
                    ? original.lastObservedFrames.merging(placedFrames) { _, new in new }
                    : placedFrames
                proposed.resumeAutomaticWrites()
                if let committed = self.sessionStore.commit(proposed, replacing: original.revision) {
                    self.statusMessage = nil
                    if consumeUndo { self.tabbedUndo[original.id]?.removeLast() }
                    let movedPane = snapAction == nil || focus.map { previous?.paneID(containing: $0) != state.paneID(containing: $0) } == true
                    if rememberUndo, movedPane, let previous, previous != state {
                        var floatingFrames: [WindowID: BTRect] = [:]
                        if snapAction != nil, let focus, previous.floatingWindowIDs.contains(focus),
                           let frame = rollbackFrames?[focus] ?? windows.first(where: { $0.id == focus })?.frame {
                            floatingFrames[focus] = frame
                        }
                        self.rememberTabbedUndo(previous, sessionID: original.id, floatingFrames: floatingFrames)
                    }
                    self.showTabbed(session: committed, display: display, windows: windows)
                }
            } else {
                _ = restoreGestureMembership()
                self.statusMessage = outcome.failureReason
                if case .degraded = outcome {
                    self.sessionStore.update(display.id) { $0.suspendAutomaticWrites(observing: windows) }
                } else if let restored = self.sessionStore.session(for: display.id) {
                    // A complete rollback raised the previous selections.
                    // Put their curtains below them again as well.
                    self.showTabbed(session: restored, display: display, windows: windows)
                }
                self.presentActionResult(succeeded: false, error: outcome.failureReason, displayID: display.id)
            }
            self.drainTabbedQueuedIntent(on: display.id, sessionID: original.id)
            if self.tabbedNeedsFocusRefresh || repairsStackingAfterSelection { self.handleTabbedFocus() }
            // An edge resize released during this placement is read now.
            self.schedulePendingWindowEvents()
        }
    }

    private func rememberTabbedUndo(_ state: TabbedLayoutState, sessionID: DesktopSessionID,
                                    floatingFrames: [WindowID: BTRect] = [:]) {
        tabbedUndo[sessionID, default: []].append(TabbedUndoStep(state: state, floatingFrames: floatingFrames))
        if tabbedUndo[sessionID, default: []].count > 20 { tabbedUndo[sessionID]?.removeFirst() }
    }

    private func handleTabbed(_ intent: TabbedUIIntent, on displayID: DisplayID) {
        guard !isStabilizingSpace, !isShutDown,
              var session = sessionStore.session(for: displayID), session.mode == .tabbed,
              let display = system.displays().first(where: { $0.id == displayID }),
              var state = session.tabbedState else { return }
        if tabbedTasks[displayID] != nil {
            tabbedQueuedIntents[displayID] = .ui(intent)
            return
        }
        guard let allWindows = try? system.visibleWindows() else { return }
        let observation = system.nativeDesktopObservation()
        guard observation?.allowsAutomaticLayout(on: displayID) != false else { return }
        let windows = bentoEligible((observation?.windowsOnCurrentSpaces(allWindows) ?? allWindows)
            .filter { $0.displayID == displayID && $0.isEligible && !$0.isFloating })
        var focus: WindowID?
        var undo = true
        var consumeUndo = false
        var selectionOnly = false
        var restorationFrames: [WindowID: BTRect] = [:]
        switch intent {
        case let .select(id): state.select(id); focus = id; undo = false; selectionOnly = true
        case let .activate(id):
            tabbedFocusTask?.cancel()
            tabbedNeedsFocusRefresh = false
            state.activatePane(id)
            session.tabbedState = state
            _ = sessionStore.commit(session, replacing: session.revision)
            showTabbed(session: session, display: display, windows: windows)
            return
        case let .close(id):
            let outcome = coordinator.closeTabbedWindow(id)
            if !outcome.isApplied { statusMessage = outcome.failureReason }
            return
        case let .float(id): state.float(id); focus = id
        case let .move(id, pane, index): state.move(id, to: pane, at: index); focus = id
        case let .split(id, pane, edge): state.split(paneID: pane, moving: id, edge: edge); focus = id
        case let .preset(preset): state.applyPreset(preset); focus = state.activeWindowID
        case .undo:
            guard let step = tabbedUndo[session.id]?.last else { return }
            var previous = step.state
            restorationFrames = step.floatingFrames
            let visible = Set(windows.map(\.id))
            previous.reconcile(windowIDs: windows.map(\.id), removed: previous.windowIDs.subtracting(visible), focused: nil)
            state = previous
            consumeUndo = true
            focus = state.activeWindowID; undo = false
        case .repair:
            session.resumeAutomaticWrites()
            state.reconcile(windowIDs: windows.map(\.id), removed: state.windowIDs.subtracting(windows.map(\.id)), focused: nil)
            focus = state.activeWindowID; undo = false
        case let .removePane(id): state.removeEmptyPane(id)
        case let .adjustDivider(id, delta):
            guard state.adjustDivider(id, by: delta, in: display.visibleFrame) else { return }
        }
        applyTabbedState(state, session: session, display: display, windows: windows, focus: focus,
                         rememberUndo: undo, consumeUndo: consumeUndo, selectionOnly: selectionOnly,
                         restorationFrames: restorationFrames)
    }

    /// The user resized a selected window by its edge. As in Bento, a shared
    /// pane edge moves that divider, stopping at each pane's minimum, and any
    /// other change snaps back. Hidden tabs and strips then follow the panes.
    private func adoptTabbedResize(of externalIDs: Set<WindowID>, session: LayoutSession, windows: [WindowSnapshot]) {
        guard !session.automaticWritesSuspended,
              let state = session.tabbedState,
              let display = system.displays().first(where: { $0.id == session.displayID })
        else { return }
        let selected = Set(state.selectedWindowIDs)
        let paneWindows = windows.filter { selected.contains($0.id) && $0.displayID == display.id }
        let changed = Set(paneWindows.filter { window in
            externalIDs.contains(window.id)
                && session.lastObservedFrames[window.id]?.approximatelyEquals(window.frame, tolerance: 1) != true
        }.map(\.id))
        guard !changed.isEmpty else { return }
        // A placement in progress reschedules these changes when it finishes.
        if tabbedTasks[display.id] != nil {
            pendingWindowEvents.recordFrameChanges(changed)
            return
        }
        if primaryButtonIsPressed() {
            pendingWindowEvents.recordFrameChanges(changed)
            guard tabbedResizeReleaseTask == nil else { return }
            tabbedResizeReleaseTask = Task { @MainActor [weak self] in
                while !Task.isCancelled, self?.primaryButtonIsPressed() == true {
                    try? await Task.sleep(for: .milliseconds(50))
                }
                guard let self, !Task.isCancelled else { return }
                self.tabbedResizeReleaseTask = nil
                self.schedulePendingWindowEvents()
            }
            return
        }
        guard let adopted = state.adoptingResize(
            of: changed,
            frames: Dictionary(uniqueKeysWithValues: paneWindows.map { ($0.id, $0.frame) }),
            constraints: Dictionary(uniqueKeysWithValues: paneWindows.map { ($0.id, $0.constraints) }),
            in: display.visibleFrame,
            tolerance: configuration.adjacencyTolerance
        ) else {
            applyTabbedState(state, session: session, display: display, windows: windows,
                             focus: nil, rollbackFrames: session.lastObservedFrames)
            return
        }
        // Native resizing changed one real window already. Publish the new
        // tree only after all selected tabs settle, and restore the verified
        // layout rather than that externally changed frame on failure.
        applyTabbedState(adopted, session: session, display: display, windows: windows,
                         focus: nil, rememberUndo: true, rollbackFrames: session.lastObservedFrames)
    }

    /// Tab strips and curtains follow a divider during its drag. Hidden tabs
    /// follow at release, behind the curtain.
    private func followTabbedDividerDrag(displayID: DisplayID, layout: BentoLayoutState, bounds: BTRect) {
        guard var session = sessionStore.session(for: displayID), session.mode == .tabbed,
              let overlay = tabbedOverlays[displayID] else { return }
        session.bentoState = layout
        guard let state = session.tabbedState else { return }
        overlay.refreshResize(state: state, bounds: bounds)
    }

    /// A Bento operation (divider drag, drop) changed a Tabbed tree. Hidden
    /// tabs follow their pane's new frame, stacked behind the selected tab,
    /// and the strips move.
    private func refreshTabbedAfterBentoChange(displayID: DisplayID, undoBaseline: TabbedLayoutState? = nil) {
        guard let session = sessionStore.session(for: displayID), session.mode == .tabbed,
              let state = session.tabbedState,
              let display = system.displays().first(where: { $0.id == displayID }),
              let windows = try? system.visibleWindows()
        else { return }
        // The Bento change already committed, so the state from before it is
        // the Undo step.
        if let undoBaseline, undoBaseline != state { rememberTabbedUndo(undoBaseline, sessionID: session.id) }
        let displayWindows = bentoEligible(windows.filter { $0.displayID == displayID && $0.isEligible && !$0.isFloating })
        applyTabbedState(state, session: session, display: display, windows: displayWindows, focus: nil)
    }

    private func drainTabbedQueuedIntent(on displayID: DisplayID, sessionID: DesktopSessionID) {
        let queuedIntent = tabbedQueuedIntents.removeValue(forKey: displayID)
        let needsRefresh = tabbedNeedsRefresh.remove(displayID) != nil
        let needsReapply = tabbedNeedsReapply.remove(displayID) != nil
        guard !Task.isCancelled, !isStabilizingSpace, !isShutDown,
              sessionStore.session(for: displayID)?.id == sessionID,
              activeMode(for: displayID) == .tabbed else { return }
        if let queuedIntent {
            switch queuedIntent {
            case let .ui(intent): handleTabbed(intent, on: displayID)
            case let .snap(id, action, space): performTabbedSnap(action, windowID: id, displayID: displayID, expectedSpaceID: space)
            }
        } else if needsReapply {
            refreshTabbedAfterBentoChange(displayID: displayID)
        } else if needsRefresh {
            refreshActiveWindows(force: false)
        }
    }

    var activeTabbedState: TabbedLayoutState? {
        activeDisplayID.flatMap { sessionStore.session(for: $0)?.tabbedState }
    }

    func performTabbed(_ intent: TabbedUIIntent) {
        guard let activeDisplayID else { return }
        handleTabbed(intent, on: activeDisplayID)
    }

    private func isTabbedMember(_ id: WindowID) -> Bool {
        sessionStore.sessions.values.contains { $0.mode == .tabbed && $0.tabbedState?.windowIDs.contains(id) == true }
    }

    /// Runs after focus changes and application activation. A focused tab
    /// whose application is really in front becomes selected. Otherwise the
    /// stacking repair puts hidden tabs back behind their selected tabs.
    private func handleTabbedFocus() {
        guard !isStabilizingSpace, sessionStore.sessions.values.contains(where: { $0.mode == .tabbed }) else { return }
        tabbedNeedsFocusRefresh = true
        tabbedFocusTask?.cancel()
        let delay = max(0.08, tabbedFocusSuppressedUntil.timeIntervalSinceNow)
        tabbedFocusTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled, !self.isStabilizingSpace else { return }
            // An unreadable focus cannot become readable by retrying after each
            // placement, so only busy displays keep the refresh pending.
            let focused = (try? self.system.focusedWindow()) ?? nil
            if let focused, self.tabbedTasks[focused.displayID] != nil { return }
            self.tabbedNeedsFocusRefresh = false
            if let focused, self.isFrontmost(focused),
               let session = self.sessionStore.session(for: focused.displayID), session.mode == .tabbed,
               !session.automaticWritesSuspended, let state = session.tabbedState,
               state.windowIDs.contains(focused.id), state.activeWindowID != focused.id {
                self.handleTabbed(.select(focused.id), on: focused.displayID)
                return
            }
            self.repairTabbedStacking()
        }
    }

    /// `focusedWindow()` skips BetterTile and applications it cannot read,
    /// then reports the last managed application's window. Selecting a tab
    /// activates its application, so only a window whose application is
    /// really in front may select one.
    private func isFrontmost(_ window: WindowSnapshot) -> Bool {
        guard let frontmost = (system as? any TabbedWindowSystem)?.frontmostProcessIdentifier else { return true }
        return frontmost == window.processIdentifier
    }

    /// Activation can bring an application's hidden tabs in front of their
    /// panes' selected tabs. This reads the real window order and raises only
    /// what must move. It never activates an application, changes a
    /// selection, or moves a window. Chrome then reorders around the
    /// selected tabs.
    private func repairTabbedStacking() {
        guard let windows = try? system.visibleWindows() else { return }
        let displays = system.displays()
        for session in sessionStore.sessions.values where session.mode == .tabbed {
            guard !session.automaticWritesSuspended, tabbedTasks[session.displayID] == nil,
                  !nativeFullscreenDisplayIDs.contains(session.displayID),
                  let state = session.tabbedState,
                  let display = displays.first(where: { $0.id == session.displayID }) else { continue }
            if presentsTabbedChrome {
                showTabbed(session: session, display: display, windows: windows)
            } else {
                _ = repairTabbedOrder(state: state, windows: windows, bounds: display.visibleFrame)
            }
        }
    }

    /// A shared curtain needs every selected tab above every inactive tab.
    /// Verify the readback after raising; never expose a curtain on intent alone.
    func repairTabbedOrder(state: TabbedLayoutState, windows: [WindowSnapshot], bounds: BTRect) -> [TabbedStackEntry]? {
        guard let system = system as? any TabbedWindowSystem else { return nil }
        let chrome = tabbedOverlays.values.reduce(into: Set<Int>()) { $0.formUnion($1.windowNumbers) }
        guard var order = system.stackingOrder(for: windows, excluding: chrome),
              let plan = state.sharedCurtainStackingRepair(order: order, curtainBounds: bounds) else { return nil }
        if !plan.isEmpty {
            // Never reorder foreign windows during a held resize.
            guard !dividerResize.isDragging, tabbedResizeReleaseTask == nil else { return nil }
            let outcome = coordinator.raiseTabbedWindows(plan)
            guard outcome.isApplied else { statusMessage = outcome.failureReason; return nil }
            guard let readback = system.stackingOrder(for: windows, excluding: chrome) else { return nil }
            order = readback
        }
        guard state.sharedCurtainStackingRepair(order: order, curtainBounds: bounds)?.isEmpty == true else { return nil }
        return order
    }

    private func tabbedRestorationPlacements(
        baselineFrames: [WindowID: BTRect],
        on display: DisplaySnapshot,
        windows: [WindowSnapshot]
    ) -> [Placement] {
        let visible = Dictionary(uniqueKeysWithValues: windows.filter {
            $0.displayID == display.id && $0.isEligible
        }.map { ($0.id, $0) })
        return baselineFrames.compactMap { id, frame -> Placement? in
            guard let window = visible[id] else { return nil }
            var restored = frame
            restored.size.width = max(frame.size.width, window.constraints.minimumSize.width)
            restored.size.height = max(frame.size.height, window.constraints.minimumSize.height)
            if restored != frame || !PlacementBounds.isReachable(frame, in: display.visibleFrame) {
                // Native windows may exceed the work area. Keep their minimum size
                // and move the origin into reach instead of shrinking the frame.
                let bounds = display.visibleFrame
                restored.origin.x = min(max(restored.minX, bounds.minX), max(bounds.minX, bounds.maxX - restored.size.width))
                restored.origin.y = min(max(restored.minY, bounds.minY), max(bounds.minY, bounds.maxY - restored.size.height))
            }
            return Placement(windowID: id, frame: restored)
        }
    }

    private func leaveTabbed(displayID: DisplayID, destination: LayoutMode) {
        guard tabbedExiting.insert(displayID).inserted else { return }
        tabbedQueuedIntents.removeValue(forKey: displayID)
        let pending = tabbedTasks[displayID]
        pending?.cancel()
        Task { @MainActor [weak self] in
            await pending?.value
            guard let self else { return }
            defer { self.tabbedExiting.remove(displayID) }
            guard !self.isShutDown,
                  var session = self.sessionStore.session(for: displayID),
                  session.mode == .tabbed, !self.isStabilizingSpace,
                  let display = self.system.displays().first(where: { $0.id == displayID }),
                  let windows = try? self.system.visibleWindows() else { return }
            if destination == .manual {
                let placements = self.tabbedRestorationPlacements(baselineFrames: session.tabbedBaselineFrames, on: display, windows: windows)
                let outcome: WindowMutationOutcome = placements.isEmpty ? .applied : self.coordinator.applyPlacements(placements, recordHistory: false)
                if !outcome.isApplied { self.statusMessage = outcome.failureReason; return }
            }
            // Bento takes over the tree: every hidden tab gets a pane. Native
            // leaves the tree alone, so the tab groups return with Tabbed.
            if destination == .bento, let state = session.tabbedState {
                session.bentoState = state.unstacked(in: display.visibleFrame)
                session.isBentoInitialized = session.bentoState.root != nil
                session.tabbedState = nil
            }
            session.mode = destination
            session.resumeAutomaticWrites()
            guard self.sessionStore.commit(session, replacing: session.revision) != nil else { return }
            self.tabbedOverlays[displayID]?.hide()
            if destination == .bento, var bento = self.sessionStore.session(for: displayID), bento.bentoState.root != nil {
                // Keep the arrangement the user built: apply the unstacked tree
                // instead of re-tiling from scratch.
                let displayWindows = self.bentoEligible(windows.filter {
                    $0.displayID == displayID && $0.isEligible && !$0.isFloating
                })
                let placements = BentoLayoutEngine(state: bento.bentoState).placements(for: displayWindows, in: display)
                let result = self.commitBentoProposal(placements, session: &bento, display: display, surfaceFailure: false)
                if result.result != .committed { self.tileCurrentDisplay() }
                self.refreshDividerBoundaries()
            } else if destination == .bento {
                self.tileCurrentDisplay()
            } else {
                self.refreshActiveWindows(force: true)
            }
        }
    }
}
