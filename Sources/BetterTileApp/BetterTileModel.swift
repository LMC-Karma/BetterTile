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
    private let dividerResize: DividerOverlayController
    private var resultPill: ResultPillController?
    private var sessionStore = LayoutSessionStore()
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
    private var windowEventTask: Task<Void, Never>?
    private var windowEventRetryBackoff = WindowEventRetryBackoff()
    private var settlementTasks: [DisplayID: Task<Void, Never>] = [:]
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

    init(
        store: ConfigurationStore = .defaultStore(),
        system suppliedSystem: (any BetterTileWindowSystem)? = nil,
        startRuntime: Bool = true
    ) {
        self.store = store
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
        dragSnap.activeModeProvider = { [weak self] displayID in self?.activeMode(for: displayID) }
        dragSnap.bentoStateProvider = { [weak self] displayID in self?.sessionStore.session(for: displayID)?.bentoState }
        dragSnap.bentoDragBeganHandler = { [weak self] displayID, sourceID in
            self?.beginBentoDrag(displayID: displayID, sourceID: sourceID) ?? false
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
        dividerResize.bentoStateProvider = { [weak self] displayID in
            self?.sessionStore.session(for: displayID)?.bentoState
        }
        dividerResize.bentoStateChangedHandler = { [weak self] displayID, state, frames, baselineFrames in
            guard let self, var session = self.sessionStore.session(for: displayID) else { return }
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
        dividerResize.layoutChangedHandler = { [weak self] displayID, _ in
            self?.refreshDividerBoundaries()
        }
        dividerResize.rollbackFailureHandler = { [weak self] displayID, error in
            guard let self else { return }
            let message = error ?? "The divider change could not be rolled back."
            if self.activeMode(for: displayID) == .bento {
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
        sessionStore.update(displayID) { $0.mode = mode }
        if mode == .bento {
            tileCurrentDisplay()
        } else {
            refreshDividerBoundaries()
        }
    }

    func perform(_ action: WindowAction) {
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
        let focusedRule = (try? system.focusedWindow()).map(rule(for:)) ?? .manageNormally
        if !focusedRule.allowsDirectPlacement {
            statusMessage = "BetterTile is set to ignore this app."
            presentActionResult(succeeded: false, error: statusMessage, displayID: originalDisplayID)
            return
        }
        let actionPlan: WindowActionPlan
        switch coordinator.plan(action) {
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
        case let .ready(.zone(plan)):
            return .ready(placements: [Placement(windowID: plan.windowID, frame: plan.targetFrame)])
        case let .ready(.bento(proposal)):
            return .ready(placements: proposal.plan.placements)
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
        case let .ready(.action(plan)):
            let outcome = coordinator.perform(plan)
            let displayID = currentDisplayID(for: plan.windowID) ?? plan.displayID
            finishLayoutWheelPlacement(outcome: outcome, displayID: displayID)
            if outcome.isApplied {
                verifyPlacementLanded(WindowPlacementPlan(plan), displayID: displayID)
            }
        case let .ready(.zone(plan)):
            let outcome = coordinator.perform(plan)
            let displayID = currentDisplayID(for: plan.windowID) ?? plan.displayID
            finishLayoutWheelPlacement(outcome: outcome, displayID: displayID)
            if outcome.isApplied {
                verifyPlacementLanded(plan, displayID: displayID)
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
    private func captureLayoutWheelTarget() -> LayoutWheelTarget? {
        guard hasAccessibilityPermission else { return nil }
        do {
            guard let window = try system.focusedWindow(),
                  window.isEligible,
                  rule(for: window).allowsDirectPlacement,
                  let display = system.displays().first(where: { $0.id == window.displayID })
            else { return nil }
            return LayoutWheelTarget(
                windowID: window.id,
                displayID: window.displayID,
                visibleFrame: display.visibleFrame
            )
        } catch {
            return nil
        }
    }

    private func planLayoutWheel(
        _ command: LayoutWheelCommand,
        for target: LayoutWheelTarget
    ) -> LayoutWheelPlanOutcome {
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

        guard system.displays().contains(where: { $0.id == target.displayID }) else {
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

        case let .customZone(zoneID):
            guard let zone = configuration.customZones.first(where: { $0.id == zoneID }) else {
                return .unavailable(
                    reason: "That Custom Zone is no longer available.",
                    displayID: window.displayID
                )
            }
            let zonePlan: WindowPlacementPlan
            switch coordinator.plan(zone, for: target.windowID) {
            case let .ready(plan): zonePlan = plan
            case .unavailable:
                return .unavailable(
                    reason: "The captured window is no longer available.",
                    displayID: window.displayID
                )
            case let .failed(reason):
                return .unavailable(reason: reason, displayID: window.displayID)
            }
            guard sourceRule.allowsBentoParticipation,
                  activeMode(for: zonePlan.displayID) == .bento
            else { return .ready(.zone(zonePlan)) }
            guard let proposal = layoutWheelBentoProposal(
                intent: .customZone(id: zoneID, frame: zonePlan.targetFrame),
                sourceWindowID: target.windowID,
                displayID: zonePlan.displayID
            ) else {
                return .unavailable(
                    reason: "That Custom Zone cannot satisfy the Bento windows' minimum sizes.",
                    displayID: zonePlan.displayID
                )
            }
            return .ready(.bento(proposal))

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
            Self.bentoLog.notice(
                """
                \(plan.windowID.rawValue, privacy: .public) never reached \
                \(plan.targetFrame.debugText, privacy: .public)
                """
            )
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
        Self.bentoLog.debug(
            """
            action input: visible=\(windows.map(\.id.rawValue).sorted().joined(separator: " "), privacy: .public)             eligibleOnDisplay=\(displayWindows.map(\.id.rawValue).sorted().joined(separator: " "), privacy: .public)             session=\(session.windowIDs.map(\.rawValue).sorted().joined(separator: " "), privacy: .public)             tree=\((session.bentoState.root?.windowIDs ?? []).map(\.rawValue).sorted().joined(separator: " "), privacy: .public)
            """
        )
        reconcileBentoSession(&session, windows: displayWindows, display: display)
        Self.bentoLog.debug(
            """
            after reconcile: tree=\((session.bentoState.root?.windowIDs ?? []).map(\.rawValue).sorted().joined(separator: " "), privacy: .public)             floating=\(session.bentoState.floatingWindowIDs.map(\.rawValue).sorted().joined(separator: " "), privacy: .public)
            """
        )
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
        Self.bentoLog.debug(
            """
            shortcut \(actionPlan.resolvedAction.rawValue, privacy: .public)             source=\(actionPlan.windowID.rawValue, privacy: .public)             placements=\(plan.placements.map { "\($0.windowID.rawValue)@\($0.frame.debugText)" }.joined(separator: " "), privacy: .public)
            """
        )
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

    func apply(zone: CustomZone) {
        let displayID = (try? system.focusedWindow())?.displayID ?? activeDisplayID
        let outcome = coordinator.applyCustomZone(
            zone,
            applicationRules: configuration.applicationRules
        )
        statusMessage = outcome.isApplied ? nil : outcome.failureReason ?? "Could not apply the zone."
        presentActionResult(succeeded: outcome.isApplied, error: statusMessage, displayID: displayID)
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
                scheduleAuthoritativePlacementSettlement(
                    displayID: display.id,
                    sessionID: session.id,
                    workArea: display.visibleFrame,
                    placements: placements
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

    private func beginBentoDrag(displayID: DisplayID, sourceID: WindowID) -> Bool {
        guard activeBentoDrag == nil,
              var layoutSession = sessionStore.session(for: displayID),
              layoutSession.mode == .bento,
              let display = system.displays().first(where: { $0.id == displayID }),
              let windows = try? system.visibleWindows(),
              let dragSession = BentoDragSession(
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
            transaction: transaction
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
        let intent: BentoDropIntent? = switch outcome {
        case let .swap(targetWindowID): .pane(targetWindowID)
        case let .insert(targetWindowID, edge): .insert(targetWindowID: targetWindowID, edge: edge)
        case let .snap(action, frame): .snap(action: action, frame: frame)
        case let .customZone(id, frame): .customZone(id: id, frame: frame)
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

    private func finishBentoDrag(displayID: DisplayID, sourceID: WindowID, outcome: BentoDragOutcome) {
        guard var active = activeBentoDrag,
              active.session.displayID == displayID,
              active.session.sourceWindowID == sourceID
        else { return }

        var committed = false
        var frameTransactionCommitted = false
        var recoveryFailurePresented = false
        let intent: BentoDropIntent? = switch outcome {
        case let .swap(targetWindowID): .pane(targetWindowID)
        case let .insert(targetWindowID, edge): .insert(targetWindowID: targetWindowID, edge: edge)
        case let .snap(action, frame): .snap(action: action, frame: frame)
        case let .customZone(id, frame): .customZone(id: id, frame: frame)
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
                    if !plan.isFocusDrop, !changedWindowIDs.isEmpty {
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
        dividerResize.hideAndCancel()
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
        if !changes.isDisjoint(with: [.snapping, .bentoGeometry, .applicationRules]) {
            dragSnap.configuration = configuration
        }
        if changes.contains(.layoutWheel) {
            layoutWheel.configuration = configuration
        }
        if !changes.isDisjoint(with: [.linkedResize, .applicationRules]) {
            linkedResize.configuration = configuration
        }
        if !changes.isDisjoint(with: [.snapping, .linkedResize]) {
            syncSharedGestureMonitoring()
        }
        if !changes.isDisjoint(with: [.divider, .bentoGeometry]) {
            dividerResize.configuration = configuration
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
        NSApp.setActivationPolicy(configuration.showDockIcon ? .regular : .accessory)
        guard configuration.showDockIcon,
              let icon = NSImage(named: NSImage.applicationIconName)
        else { return }
        NSApp.applicationIconImage = icon
        NSApp.dockTile.display()
    }

    private func installWorkspaceTriggers() {
        let center = NotificationCenter.default
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        notificationTokens.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.scheduleDisplayRefresh() }
        })
        notificationTokens.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
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
                self?.layoutWheel.handleApplicationDeactivated()
                self?.flushConfiguration()
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
                    if name == NSWorkspace.didWakeNotification {
                        self?.dragSnap.cancel()
                        self?.layoutWheel.cancel()
                    }
                    self?.system.refreshApplicationObservers()
                    self?.system.triggerDockFootprintCheck()
                    self?.dividerResize.hideAndCancel()
                    self?.refreshActiveWindows(force: true)
                }
            })
        }
        notificationTokens.append(workspaceCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.beginActiveSpaceStabilization() }
        })
        notificationTokens.append(workspaceCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.layoutWheel.handleApplicationDeactivated()
                self?.refreshFocusedDisplayWithoutLayout()
            }
        })
        let timer = Timer(timeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.watchdog() }
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

    private func beginActiveSpaceStabilization() {
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
                    if case let .failed(reason) = coordinator.restoreFocusDropPeers(peers) {
                        Self.bentoLog.notice("focus-drop peer restore incomplete: \(reason, privacy: .public)")
                    }
                    sessionStore.update(displayID) {
                        $0.excludedFocusWindowIDs.removeAll()
                    }
                }
                dragSnap.prepareForRestoredWindowDrag(windowID: windowID)
            }
            pendingWindowEvents.record(event)
        case .created, .destroyed, .minimized:
            if let windowID = event.windowID {
                if event.kind == .minimized { confirmedMinimizedWindowIDs.insert(windowID) }
                if event.kind == .destroyed { confirmedGoneWindowIDs.insert(windowID) }
            }
            pendingWindowEvents.record(event)
        case .focused:
            layoutWheel.handleFocusedWindowChanged()
        }
        schedulePendingWindowEvents()
    }

    private func schedulePendingWindowEvents(after delay: Duration = WindowEventRetryBackoff.initialDelay) {
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
            Self.bentoLog.debug(
                """
                external \(classifications.map { "\($0.key.rawValue)=\($0.value)" }.sorted().joined(separator: " "), privacy: .public)                 -> \(String(describing: route), privacy: .public)
                """
            )
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
            Self.bentoLog.error("proposal rejected: \(self.statusMessage ?? "unknown", privacy: .public)")
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
        windows.filter { rule(for: $0).allowsBentoParticipation }
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
        Self.bentoLog.error(
            "invalidating Bento revision \(current.revision, privacy: .public) tree=\(String(describing: current.bentoState.root), privacy: .public)"
        )
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
        baselineFrames: [WindowID: BTRect]? = nil
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
                      let sampled = try? self.system.visibleWindows()
                else { return }
                latestWindows = sampled
                let frames = Dictionary(uniqueKeysWithValues: sampled.filter { changedWindowIDs.contains($0.id) }.map { ($0.id, $0.frame) })
                let hasResponded = baselineFrames == nil || frames.contains { id, frame in
                    guard let baseline = baselineFrames?[id] else { return false }
                    return !frame.approximatelyEquals(baseline, tolerance: 1)
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
                baselineFrames: baselineFrames
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
        baselineFrames: [WindowID: BTRect]?
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
                Self.bentoLog.notice(
                    """
                    \(windowID.rawValue, privacy: .public) did not settle:                     requested \(requested.debugText, privacy: .public) got \(actual.debugText, privacy: .public)
                    """
                )
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
            }
            refreshDividerBoundaries()
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
            singleWindowPlacement: configuration.singleWindowPlacement
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
                let committed = sessionStore.commit(
                    activation.session,
                    replacing: activation.session.revision
                ) != nil
                sweepCommitted = sweepCommitted && committed
                continue
            }
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
                    confirmedMinimized: consumedMinimizedWindowIDs
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
                if let settleWorkArea {
                    if applied {
                        scheduleAuthoritativePlacementSettlement(
                            displayID: display.id,
                            sessionID: session.id,
                            workArea: settleWorkArea,
                            placements: placements
                        )
                    } else if !result.result.needsRepair {
                        statusMessage = result.failureReason ?? "Some windows could not follow the updated screen area."
                        presentActionResult(succeeded: false, error: statusMessage, displayID: display.id)
                    }
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
                confirmedMinimizedWindowIDs.subtract(consumedMinimizedWindowIDs)
            }
        } else {
            pendingWindowEvents.recordTopologyChange()
            schedulePendingWindowEvents()
        }
        activeDisplayID = resolvedActiveDisplay
            ?? activeDisplayID.flatMap { current in displays.contains(where: { $0.id == current }) ? current : nil }
            ?? displays.first(where: { !(sessionStore.session(for: $0.id)?.windowIDs.isEmpty ?? true) })?.id
            ?? displays.first(where: \.isMain)?.id
        system.updateManagedWindowIDs(Set(eligible.map(\.id)))
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
            minimized: minimized
        )
        guard case let .update(updated, _, _) = transition else { return }
        session = updated
        logHeldAbsences(in: session)
    }

    private func logHeldAbsences(in session: LayoutSession) {
        let heldAbsences = session.presence.pending
            .map { "\($0.key.rawValue)x\($0.value)" }
            .sorted()
            .joined(separator: " ")
        if !heldAbsences.isEmpty {
            Self.bentoLog.debug("holding absent panes: \(heldAbsences, privacy: .public)")
        }
    }

    private func displayWorkAreaSignature(_ displays: [DisplaySnapshot]) -> String {
        displays.sorted { $0.id < $1.id }.map { display in
            let frame = display.visibleFrame
            return "\(display.id.rawValue):\(frame.minX):\(frame.minY):\(frame.size.width):\(frame.size.height):\(display.scaleFactor)"
        }.joined(separator: "|")
    }

    private func refreshDividerBoundaries(windows suppliedWindows: [WindowSnapshot]? = nil) {
        let windows = suppliedWindows ?? ((try? system.visibleWindows()) ?? [])
        let displays = Dictionary(uniqueKeysWithValues: system.displays().map { ($0.id, $0) })
        var boundaries: [BoundaryDescriptor] = []
        var managedWindowIDs: Set<WindowID> = []
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
                    managedWindowIDs.formUnion(boundary.beforeWindowIDs)
                    managedWindowIDs.formUnion(boundary.afterWindowIDs)
                }
                boundaries += linkedBoundaries
            case .bento:
                managedWindowIDs.formUnion(session.bentoState.root?.windowIDs ?? [])
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
        dividerResize.refresh(
            boundaries: boundaries,
            obscuringFrames: DividerHandleOcclusion.obscuringFrames(
                in: NSWorkspace.shared.frontmostApplication.map { frontmost in
                    windows.filter { $0.processIdentifier == frontmost.processIdentifier }
                } ?? [],
                excluding: managedWindowIDs
            )
        )
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
    case zone(WindowPlacementPlan)
    case bento(BentoCommandProposal)
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
}
