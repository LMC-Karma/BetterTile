import AppKit
import BetterTileCore
import BetterTileMacOS
import Foundation
import Observation
import os

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
    private(set) var sessionRevision = 0

    let system: AccessibilityWindowSystem
    let coordinator: WindowCoordinator
    private let store: ConfigurationStore
    private let shortcuts: GlobalShortcutMonitor
    private let dragSnap: DragSnapController
    private let titleBarDoubleClick: TitleBarDoubleClickController
    private let linkedResize: LinkedResizeController
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
    private var actionVerificationTask: Task<Void, Never>?
    private var pendingRestoredWindowDeadlines: [WindowID: Date] = [:]
    private var windowEventTask: Task<Void, Never>?
    private var windowEventRetryBackoff = WindowEventRetryBackoff()
    private var settlementTasks: [DisplayID: Task<Void, Never>] = [:]
    private var spaceStabilizationTask: Task<Void, Never>?
    private var spaceStabilizationGeneration = 0
    private var isStabilizingSpace = false
    private var suppressSpaceFrameEventsUntil = Date.distantPast
    private var activeBentoDrag: ActiveBentoDrag?
    private var bentoDragEventBuffer = WindowEventBuffer()
    private var configurationSaveTask: Task<Void, Never>?
    private var configurationNeedsSave = false

    init(store: ConfigurationStore = .defaultStore()) {
        self.store = store
        let loaded = (try? store.load()) ?? BetterTileConfiguration()
        let windowSystem = AccessibilityWindowSystem()
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
        dividerResize = DividerOverlayController(coordinator: coordinator, configuration: loaded)

        shortcuts.isEnabled = loaded.keyboardShortcutsEnabled
        shortcuts.setHandler { [weak self] action in self?.perform(action) }
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
            guard let self else { return }
            self.sessionStore.update(displayID) {
                $0.bentoState = state
                $0.recordProposedFrames(frames)
            }
            self.sessionRevision &+= 1
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
        system.setWindowEventHandler { [weak self] event in self?.receiveWindowSystemEvent(event) }
        shortcuts.update(bindings: loaded.shortcuts)
        dragSnap.start()
        titleBarDoubleClick.start()
        linkedResize.start()
        refreshPermission()
        installWorkspaceTriggers()
        system.startDockFootprintMonitoring { [weak self] in
            self?.dockFootprintChanged()
        }
        refreshActiveWindows(force: true)

        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.applyDockPolicy()
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
        sessionRevision &+= 1
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
        guard let actionPlan = coordinator.plan(action) else {
            statusMessage = coordinator.lastError ?? "No eligible focused window."
            presentActionResult(
                succeeded: false,
                error: statusMessage,
                displayID: originalDisplayID
            )
            return
        }
        let succeeded = if BentoDropPlanner.handlesShortcut(
            actionPlan.resolvedAction,
            in: sessionStore.session(for: actionPlan.displayID)?.mode ?? .manual,
            sourceRule: focusedRule
        ) {
            performBentoAction(actionPlan)
        } else {
            coordinator.perform(actionPlan)
        }
        statusMessage = succeeded
            ? nil
            : coordinator.lastError ?? statusMessage ?? "No eligible focused window."
        let resultingDisplayID = (try? system.focusedWindow())?.displayID ?? originalDisplayID
        presentActionResult(succeeded: succeeded, error: statusMessage, displayID: resultingDisplayID)
        if succeeded {
            verifyActionLanded(actionPlan, displayID: resultingDisplayID)
        }
    }

    /// Corrects the reported outcome if the window never actually reached the
    /// frame it was asked for. Deliberately after the fact: an application is
    /// free to apply an Accessibility geometry change on its own run loop, so a
    /// report made at write time cannot tell a refusal from a delay.
    private func verifyActionLanded(_ plan: WindowActionPlan, displayID: DisplayID?) {
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
        guard bentoProposalIsContained(plan.placements, in: display) else {
            statusMessage = "That layout would have placed a window outside the screen area."
            Self.bentoLog.error("rejected shortcut proposal: a pane fell outside the work area")
            return false
        }
        guard coordinator.applyPlacements(plan.placements) else {
            Self.bentoLog.error("shortcut placements rejected: \(self.coordinator.lastError ?? "unknown", privacy: .public)")
            return false
        }

        let requestedFrames = Dictionary(uniqueKeysWithValues: plan.placements.map { ($0.windowID, $0.frame) })
        session.bentoState = plan.state
        session.isBentoInitialized = true
        session.windowIDs = Set(displayWindows.map(\.id))
        session.recordProposedFrames(requestedFrames)
        session.lastWorkArea = display.visibleFrame
        sessionStore.update(display.id) { $0 = session }
        sessionRevision &+= 1

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
        let succeeded = coordinator.applyCustomZone(
            zone,
            applicationRules: configuration.applicationRules
        )
        statusMessage = succeeded ? nil : coordinator.lastError ?? "Could not apply the zone."
        presentActionResult(succeeded: succeeded, error: statusMessage, displayID: displayID)
    }

    func tileCurrentDisplay() {
        do {
            let windows = try system.visibleWindows().filter { $0.isEligible && !$0.isFloating }
            guard let focused = try system.focusedWindow(),
                  let display = system.displays().first(where: { $0.id == focused.displayID })
            else {
                statusMessage = "No eligible window or display."
                presentActionResult(succeeded: false, error: statusMessage, displayID: activeDisplayID)
                return
            }
            let displayWindows = bentoEligible(windows.filter { $0.displayID == display.id })
            guard !displayWindows.isEmpty else {
                statusMessage = "No eligible visible windows on the active display."
                presentActionResult(succeeded: false, error: statusMessage, displayID: display.id)
                return
            }
            var session = sessionStore.refresh(
                displayID: display.id,
                windowIDs: Set(displayWindows.map(\.id)),
                focusedWindowID: focused.id,
                defaultMode: configuration.defaultLayoutMode
            )
            // One window has no layout to repair. Restoring its configured
            // placement is the useful thing to do, and it deliberately leaves
            // the desktop's mode alone: a manual desktop stays manual.
            if displayWindows.count == 1, let window = displayWindows.first {
                repairSingleWindow(window, session: session, display: display)
                return
            }
            session.mode = .bento
            session.reincludeInBento(Set(displayWindows.map(\.id)))
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
            sessionStore.update(display.id) { $0 = session }
            activeDisplayID = display.id
            sessionRevision &+= 1
            let applied = coordinator.applyPlacements(placements)
            if applied {
                scheduleAuthoritativePlacementSettlement(
                    displayID: display.id,
                    sessionID: session.id,
                    workArea: display.visibleFrame,
                    placements: placements
                )
            }
            statusMessage = if !applied {
                coordinator.lastError ?? "The Bento layout could not be repaired."
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
            presentActionResult(succeeded: false, error: statusMessage, displayID: activeDisplayID)
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
        session.reincludeInBento([window.id])
        activeDisplayID = display.id

        guard let action = configuration.singleWindowPlacement,
              let frame = StandardActionEngine().targetFrame(for: action, window: window, display: display)
        else {
            session.lastWorkArea = display.visibleFrame
            sessionStore.update(display.id) { $0 = session }
            sessionRevision &+= 1
            statusMessage = nil
            presentActionResult(succeeded: true, successMessage: "Nothing to repair", displayID: display.id)
            return
        }

        let placement = Placement(windowID: window.id, frame: frame)
        session.recordProposedFrames([window.id: frame])
        session.lastWorkArea = display.visibleFrame
        sessionStore.update(display.id) { $0 = session }
        sessionRevision &+= 1

        let applied = coordinator.applyPlacements([placement])
        statusMessage = applied ? nil : (coordinator.lastError ?? "The window could not be placed.")
        presentActionResult(succeeded: applied, error: statusMessage, displayID: display.id)
        refreshDividerBoundaries()
    }

    private func beginBentoDrag(displayID: DisplayID, sourceID: WindowID) -> Bool {
        guard activeBentoDrag == nil,
              let layoutSession = sessionStore.session(for: displayID),
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
              let transaction = coordinator.beginTransaction(windowIDs: dragSession.managedWindowIDs)
        else { return false }

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
        activeBentoDrag = ActiveBentoDrag(session: dragSession, transaction: transaction)
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
                presentActionResult(succeeded: false, error: statusMessage, displayID: displayID)
                restoreBentoDragIfNeeded(active.session)
                activeBentoDrag = nil
                replayBufferedBentoDragEvents()
                refreshDividerBoundaries()
                return
            }
            if plan.isFocusDrop, let placement = plan.placements.first,
               let baseline = active.session.baselineFrames[sourceID] {
                committed = coordinator.applyFocusDrop(
                    placement: placement,
                    minimizing: plan.minimizedWindowIDs,
                    sourceBaselineFrame: baseline
                )
            } else {
                committed = coordinator.commit(
                    transaction: &active.transaction,
                    placements: plan.placements,
                    recordHistory: true
                )
            }
            if committed {
                let requestedFrames = Dictionary(uniqueKeysWithValues: plan.placements.map { ($0.windowID, $0.frame) })
                sessionStore.update(displayID) { session in
                    session.bentoState = plan.state
                    session.recordProposedFrames(requestedFrames)
                    session.windowIDs.insert(sourceID)
                    if !session.bentoInsertionOrder.contains(sourceID) {
                        session.bentoInsertionOrder.append(sourceID)
                    }
                    session.excludedFocusWindowIDs.formUnion(plan.excludedWindowIDs)
                    session.excludedFocusWindowIDs.remove(sourceID)
                    session.automaticallyFloatingWindowIDs.remove(sourceID)
                }
                sessionRevision &+= 1
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
                statusMessage = coordinator.lastError ?? "macOS rejected the Bento window update."
            }
        }

        if !committed {
            restoreBentoDragIfNeeded(active.session)
        }
        if intent != nil {
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

    private func restoreBentoDragIfNeeded(_ session: BentoDragSession) {
        let restorePlacement = session.restorePlacement
        guard let source = try? system.visibleWindows().first(where: { $0.id == session.sourceWindowID }),
              !source.frame.approximatelyEquals(restorePlacement.frame, tolerance: 1)
        else { return }
        _ = coordinator.applyPlacements([restorePlacement], recordHistory: false)
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

        guard changed else { return trusted }
        if !trusted { dragSnap.cancel() }
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
        isActive ? shortcuts.suspend() : shortcuts.resume()
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
        settlementTasks.values.forEach { $0.cancel() }
        system.stopDockFootprintMonitoring()
        system.stopWindowObservation()
        shortcuts.stop()
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
        if !changes.isDisjoint(with: [.linkedResize, .applicationRules]) {
            linkedResize.configuration = configuration
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
            Task { @MainActor in
                self?.system.triggerDockFootprintCheck()
                self?.dragSnap.cancel()
                self?.dividerResize.hideAndCancel()
                self?.refreshActiveWindows(force: true)
            }
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
            Task { @MainActor in self?.flushConfiguration() }
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
        notificationTokens.append(workspaceCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refreshFocusedDisplayWithoutLayout() }
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

    private func performDeferredDockReflow() {
        schedulePendingWindowEvents()
        guard pendingDockReflow, !dragSnap.isGestureActive, !dividerResize.isDragging else { return }
        pendingDockReflow = false
        refreshActiveWindows(force: true)
    }

    private func beginActiveSpaceStabilization() {
        dragSnap.cancel()
        dividerResize.hideAndCancel()
        windowEventTask?.cancel()
        windowEventTask = nil
        settlementTasks.values.forEach { $0.cancel() }
        settlementTasks.removeAll()
        spaceStabilizationTask?.cancel()
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

    private func refreshFocusedDisplayWithoutLayout() {
        dividerResize.hideAndCancel()
        guard !isStabilizingSpace, let focused = try? system.focusedWindow() else { return }
        activeDisplayID = focused.displayID
        sessionRevision &+= 1
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
                    for peerID in session.excludedFocusWindowIDs where peerID != windowID {
                        try? system.setMinimized(false, for: peerID)
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
                if event.kind == .minimized { recordMinimizedBentoPane(windowID) }
                if event.kind == .destroyed { confirmedGoneWindowIDs.insert(windowID) }
            }
            pendingWindowEvents.record(event)
        case .focused:
            break
        }
        schedulePendingWindowEvents()
    }

    private func recordMinimizedBentoPane(_ windowID: WindowID) {
        let displays = Dictionary(uniqueKeysWithValues: system.displays().map { ($0.id, $0) })
        for displayID in sessionStore.sessions.keys {
            guard let session = sessionStore.session(for: displayID),
                  session.mode == .bento,
                  !session.excludedFocusWindowIDs.contains(windowID),
                  session.bentoState.root?.windowIDs.contains(windowID) == true,
                  let display = displays[displayID]
            else { continue }
            let snapshots = session.lastObservedFrames.map { id, frame in
                WindowSnapshot(
                    id: id,
                    processIdentifier: 0,
                    frame: frame,
                    displayID: displayID
                )
            }
            let result = BentoPlanner().plan(
                state: BentoRuntimeState(
                    layout: session.bentoState,
                    reinsertionAnchors: session.bentoReinsertionAnchors
                ),
                observation: BentoObservation(
                    bounds: display.visibleFrame,
                    windows: snapshots,
                    focusedWindowID: session.focusedWindowID
                ),
                intent: .remove(windowID, minimized: true)
            )
            sessionStore.update(displayID) {
                $0.bentoState = result.state.layout
                $0.bentoReinsertionAnchors = result.state.reinsertionAnchors
            }
        }
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
        guard let windows = try? system.visibleWindows() else {
            schedulePendingWindowEvents(after: windowEventRetryBackoff.nextDelayAfterFailure())
            return
        }
        let pendingEvents = pendingWindowEvents
        let changedIDs = pendingEvents.frameEventWindowIDs
        let refreshTopology = pendingEvents.topologyChanged
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
            guard var session = sessionStore.session(for: displayID), session.mode == .bento,
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
                applyExternalSnap(
                    windowID: windowID,
                    action: action,
                    session: &session,
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
            ) else { continue }
            session.bentoState = fitted.state
            session.recordProposedFrames(Dictionary(uniqueKeysWithValues: fitted.placements.map { ($0.windowID, $0.frame) }))
            sessionStore.update(displayID) { $0 = session }
            sessionRevision &+= 1
            _ = coordinator.applyPlacements(
                fitted.placements.filter { session.windowIDs.contains($0.windowID) },
                recordHistory: false
            )
            scheduleBentoSettlement(displayID: displayID, changedWindowIDs: dividerChanges)
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
        guard commitBentoProposal(plan.placements, state: plan.state, session: &session, display: display) else {
            restoreBentoLayout(session: session, displayWindows: displayWindows, display: display)
            return
        }
        scheduleBentoSettlement(displayID: display.id, changedWindowIDs: Set(plan.placements.map(\.windowID)))
        refreshDividerBoundaries()
    }

    /// Validates, applies, and only then commits a proposed Bento layout.
    /// Returns `false` with the coordinator's error surfaced when the proposal
    /// could not be realised, leaving the session's previous state untouched.
    @discardableResult
    private func commitBentoProposal(
        _ placements: [Placement],
        state: BentoLayoutState,
        session: inout LayoutSession,
        display: DisplaySnapshot
    ) -> Bool {
        guard bentoProposalIsContained(placements, in: display) else {
            statusMessage = "That layout would have placed a window outside the screen area."
            Self.bentoLog.error("rejected proposal: a pane fell outside the work area")
            presentActionResult(succeeded: false, error: statusMessage, displayID: display.id)
            return false
        }
        guard coordinator.applyPlacements(placements, recordHistory: false) else {
            statusMessage = coordinator.lastError ?? "That layout could not be applied."
            Self.bentoLog.error("proposal rejected: \(self.statusMessage ?? "unknown", privacy: .public)")
            presentActionResult(succeeded: false, error: statusMessage, displayID: display.id)
            return false
        }
        session.bentoState = state
        session.recordProposedFrames(
            Dictionary(uniqueKeysWithValues: placements.map { ($0.windowID, $0.frame) })
        )
        sessionStore.update(display.id) { $0 = session }
        sessionRevision &+= 1
        return true
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
        let placements = BentoLayoutEngine(state: session.bentoState)
            .placements(for: displayWindows, in: display)
        guard !placements.isEmpty else { return }
        if !coordinator.applyPlacements(placements, recordHistory: false) {
            // The windows are already back at their pre-attempt frames; what is
            // left is to say so rather than let the failure pass silently.
            statusMessage = coordinator.lastError ?? "The previous layout could not be restored."
            Self.bentoLog.error("restore failed: \(self.statusMessage ?? "unknown", privacy: .public)")
            presentActionResult(succeeded: false, error: statusMessage, displayID: display.id)
        }
        refreshDividerBoundaries()
    }

    private func scheduleBentoSettlement(
        displayID: DisplayID,
        changedWindowIDs: Set<WindowID>,
        requestedFrames: [WindowID: BTRect]? = nil,
        baselineFrames: [WindowID: BTRect]? = nil
    ) {
        guard let sessionID = sessionStore.session(for: displayID)?.id else { return }
        let mutationGenerations = Dictionary(uniqueKeysWithValues: changedWindowIDs.map {
            ($0, coordinator.mutationGeneration(for: $0))
        })
        settlementTasks[displayID]?.cancel()
        settlementTasks[displayID] = Task { @MainActor [weak self] in
            guard let self else { return }
            var previous: [WindowID: BTRect]?
            var latestWindows: [WindowSnapshot] = []
            for _ in 0..<8 {
                try? await Task.sleep(for: .milliseconds(40))
                guard !Task.isCancelled,
                      self.sessionStore.isActive(sessionID, on: displayID),
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
                changedWindowIDs: changedWindowIDs,
                windows: latestWindows,
                requestedFrames: requestedFrames,
                baselineFrames: baselineFrames
            )
            self.settlementTasks.removeValue(forKey: displayID)
        }
    }

    private func correctBentoAfterSettlement(
        displayID: DisplayID,
        sessionID: DesktopSessionID,
        changedWindowIDs: Set<WindowID>,
        windows: [WindowSnapshot],
        requestedFrames: [WindowID: BTRect]?,
        baselineFrames: [WindowID: BTRect]?
    ) {
        guard sessionStore.isActive(sessionID, on: displayID),
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
            session.recordProposedFrames(Dictionary(uniqueKeysWithValues: placements.map { ($0.windowID, $0.frame) }))
            sessionStore.update(displayID) { $0 = session }
            sessionRevision &+= 1
            _ = coordinator.applyPlacements(placements, recordHistory: false)
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
            session.recordProposedFrames(Dictionary(uniqueKeysWithValues: fitted.placements.map { ($0.windowID, $0.frame) }))
            sessionStore.update(displayID) { $0 = session }
            sessionRevision &+= 1
            _ = coordinator.applyPlacements(
                fitted.placements.filter { session.windowIDs.contains($0.windowID) },
                recordHistory: false
            )
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
        guard let windows = suppliedWindows ?? (try? system.visibleWindows()) else { return }
        // Destroyed-window identifiers are a batch consumed by exactly one
        // completed sweep. Capturing here means an early return above leaves
        // them pending for the next attempt, while identifiers belonging to
        // manual-mode desktops or sessions that were never initialised still
        // expire at the end of this sweep instead of accumulating forever.
        let consumedDestroyedWindowIDs = confirmedGoneWindowIDs
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
        var resolvedActiveDisplay: DisplayID?

        for display in displays {
            let displayWindows = bentoEligible(eligible.filter { $0.displayID == display.id })
            let activation = sessionStore.activate(
                displayID: display.id,
                windowIDs: Set(displayWindows.map(\.id)),
                focusedWindowID: focused?.displayID == display.id ? focused?.id : nil,
                defaultMode: configuration.defaultLayoutMode,
                reuseActiveWhenUnmatched: !desktopTransition
            )
            var session = activation.session
            if focused?.displayID == display.id { resolvedActiveDisplay = display.id }

            let before = session.bentoState
            let frames = Dictionary(uniqueKeysWithValues: displayWindows.map { ($0.id, $0.frame) })
            let workAreaChanged = session.lastWorkArea.map {
                !$0.approximatelyEquals(display.visibleFrame, tolerance: 0.5)
            } ?? false
            // Evaluated on every sweep, and deliberately first in the chain, so
            // the latch re-arms as soon as the desktop stops having exactly one
            // window.
            let becameSingleWindow = session.shouldApplySingleWindowPlacement(
                eligibleWindowCount: displayWindows.count
            )
            let singleWindowPlacement: Placement? = if becameSingleWindow,
               let window = displayWindows.first,
               let action = configuration.singleWindowPlacement,
               let frame = StandardActionEngine().targetFrame(for: action, window: window, display: display) {
                Placement(windowID: window.id, frame: frame)
            } else {
                nil
            }
            var shouldApply = false
            if session.mode == .bento {
                if activation.wasCreated {
                    // A lone window is left to the single-window placement
                    // above; no tree is built until a second window arrives.
                    if displayWindows.count > 1,
                       let adopted = BentoLayoutAdopter(tolerance: configuration.adjacencyTolerance)
                        .adopt(
                            frames: frames,
                            in: display.visibleFrame,
                            metrics: BentoLayoutMetrics(paneGap: configuration.bentoInnerGap)
                        ) {
                        session.bentoState = adopted
                        session.isBentoInitialized = true
                    } else if displayWindows.count > 1 {
                        let result = BentoPlanner().plan(
                            state: BentoRuntimeState(layout: BentoLayoutState(
                                metrics: BentoLayoutMetrics(paneGap: configuration.bentoInnerGap)
                            )),
                            observation: BentoObservation(
                                bounds: display.visibleFrame,
                                windows: displayWindows,
                                focusedWindowID: focused?.displayID == display.id ? focused?.id : nil
                            ),
                            intent: .activate
                        )
                        session.bentoState = result.state.layout
                        session.isBentoInitialized = true
                        shouldApply = result.writesFrames
                    }
                } else if desktopTransition {
                    // Returning to a known desktop is read-only. Its stored
                    // tree and ratios already describe how the user left it.
                } else if session.isBentoInitialized {
                    let membershipChanged = activation.previousWindowIDs != session.windowIDs
                    reconcileBentoSession(
                        &session,
                        windows: displayWindows,
                        display: display,
                        confirmedGone: consumedDestroyedWindowIDs
                    )
                    shouldApply = workAreaChanged || membershipChanged
                } else if displayWindows.count > 1,
                          let adopted = BentoLayoutAdopter(tolerance: configuration.adjacencyTolerance)
                            .adopt(
                                frames: frames,
                                in: display.visibleFrame,
                                metrics: BentoLayoutMetrics(paneGap: configuration.bentoInnerGap)
                            ) {
                    session.bentoState = adopted
                    session.isBentoInitialized = true
                } else if displayWindows.count > 1 {
                    let result = BentoPlanner().plan(
                        state: BentoRuntimeState(layout: BentoLayoutState(
                            metrics: BentoLayoutMetrics(paneGap: configuration.bentoInnerGap)
                        )),
                        observation: BentoObservation(
                            bounds: display.visibleFrame,
                            windows: displayWindows,
                            focusedWindowID: focused?.displayID == display.id ? focused?.id : nil
                        ),
                        intent: .activate
                    )
                    session.bentoState = result.state.layout
                    session.isBentoInitialized = true
                    shouldApply = result.writesFrames
                }
            }
            let stateChanged = before != session.bentoState
            if !activation.wasCreated, !desktopTransition, stateChanged { shouldApply = true }
            let needsWorkAreaSettlement = session.mode == .bento
                && session.isBentoInitialized
                && displayWindows.count > 1
                && shouldApply
                && workAreaChanged
            session.lastObservedFrames = frames
            if let singleWindowPlacement {
                session.recordProposedFrames([singleWindowPlacement.windowID: singleWindowPlacement.frame])
            }
            if !needsWorkAreaSettlement {
                session.lastWorkArea = display.visibleFrame
            }
            sessionStore.update(display.id) { $0 = session }
            if let singleWindowPlacement {
                _ = coordinator.applyPlacements([singleWindowPlacement], recordHistory: false)
            } else if session.mode == .bento, session.isBentoInitialized, displayWindows.count > 1, shouldApply {
                let placements = BentoLayoutEngine(state: session.bentoState).placements(for: displayWindows, in: display)
                let applied = coordinator.applyPlacements(placements, recordHistory: false)
                if needsWorkAreaSettlement {
                    if applied {
                        scheduleAuthoritativePlacementSettlement(
                            displayID: display.id,
                            sessionID: session.id,
                            workArea: display.visibleFrame,
                            placements: placements
                        )
                    } else {
                        statusMessage = coordinator.lastError ?? "Some windows could not follow the updated screen area."
                        presentActionResult(succeeded: false, error: statusMessage, displayID: display.id)
                    }
                }
            }
        }
        confirmedGoneWindowIDs.subtract(consumedDestroyedWindowIDs)
        activeDisplayID = resolvedActiveDisplay
            ?? activeDisplayID.flatMap { current in displays.contains(where: { $0.id == current }) ? current : nil }
            ?? displays.first(where: { !(sessionStore.session(for: $0.id)?.windowIDs.isEmpty ?? true) })?.id
            ?? displays.first(where: \.isMain)?.id
        sessionRevision &+= 1
        system.updateManagedWindowIDs(Set(eligible.map(\.id)))
        refreshDividerBoundaries(windows: eligible)
    }

    private func scheduleAuthoritativePlacementSettlement(
        displayID: DisplayID,
        sessionID: DesktopSessionID,
        workArea: BTRect,
        placements: [Placement]
    ) {
        settlementTasks[displayID]?.cancel()
        settlementTasks[displayID] = Task { @MainActor [weak self] in
            guard let self else { return }
            let succeeded = await self.coordinator.settleAuthoritativePlacements(placements)
            guard !Task.isCancelled,
                  self.sessionStore.isActive(sessionID, on: displayID)
            else { return }

            if succeeded {
                let frames = Dictionary(uniqueKeysWithValues: placements.map { ($0.windowID, $0.frame) })
                self.sessionStore.update(displayID) {
                    $0.lastWorkArea = workArea
                    $0.recordProposedFrames(frames)
                }
                self.sessionRevision &+= 1
            } else {
                if let windows = try? self.system.visibleWindows() {
                    let actualFrames = Dictionary(uniqueKeysWithValues: windows.compactMap { window in
                        placements.contains(where: { $0.windowID == window.id })
                            ? (window.id, window.frame)
                            : nil
                    })
                    self.sessionStore.update(displayID) {
                        $0.recordProposedFrames(actualFrames)
                    }
                }
                self.statusMessage = self.coordinator.lastError
                    ?? "Some windows could not follow the updated screen area."
                self.presentActionResult(
                    succeeded: false,
                    error: self.statusMessage,
                    displayID: displayID
                )
            }
            self.settlementTasks.removeValue(forKey: displayID)
            self.refreshDividerBoundaries()
        }
    }

    private func reconcileBentoSession(
        _ session: inout LayoutSession,
        windows: [WindowSnapshot],
        display: DisplaySnapshot,
        confirmedGone: Set<WindowID> = []
    ) {
        let frames = Dictionary(uniqueKeysWithValues: windows.map { ($0.id, $0.frame) })
        let present = Set(windows.map(\.id))
        let constraints = Dictionary(uniqueKeysWithValues: windows.map { ($0.id, $0.constraints) })
        var state = session.bentoState
        state.metrics = BentoLayoutMetrics(paneGap: configuration.bentoInnerGap)
        let knownIDs = Set(state.root?.windowIDs ?? []).union(state.floatingWindowIDs)
        let temporarilyHidden = session.excludedFocusWindowIDs
            .union(session.bentoReinsertionAnchors.keys)
        // A sweep can miss a window that is still on screen, and giving up its
        // pane on the first miss lets one unlucky observation dismantle a
        // layout with nothing on screen to explain it. Absence has to be
        // corroborated across sweeps; a destroyed event is direct evidence and
        // skips the wait.
        let removals = session.presence.observe(
            known: knownIDs,
            present: present,
            confirmedGone: confirmedGone,
            exempt: temporarilyHidden
        )
        for oldID in removals {
            state.remove(oldID)
        }
        let heldAbsences = session.presence.pending
            .map { "\($0.key.rawValue)x\($0.value)" }
            .sorted()
            .joined(separator: " ")
        if !heldAbsences.isEmpty {
            Self.bentoLog.debug("holding absent panes: \(heldAbsences, privacy: .public)")
        }
        session.bentoInsertionOrder.removeAll { removals.contains($0) }
        session.automaticallyFloatingWindowIDs.formIntersection(present)
        for id in windows.map(\.id).sorted() where !session.bentoInsertionOrder.contains(id) {
            session.bentoInsertionOrder.append(id)
        }

        while (state.root?.windowIDs.count ?? 0) > 6,
              let candidate = session.bentoInsertionOrder.reversed().first(where: {
                  state.root?.windowIDs.contains($0) == true
              }) {
            Self.bentoLog.debug("float \(candidate.rawValue, privacy: .public): over the six-pane cap")
            state.setFloating(true, windowID: candidate)
            session.automaticallyFloatingWindowIDs.insert(candidate)
        }

        let solver = BentoConstraintSolver()
        for id in session.bentoInsertionOrder where present.contains(id) {
            if session.excludedFocusWindowIDs.contains(id) {
                state.setFloating(true, windowID: id)
                continue
            }
            if state.root?.windowIDs.contains(id) == true { continue }
            if state.floatingWindowIDs.contains(id), !session.automaticallyFloatingWindowIDs.contains(id) { continue }
            if let anchor = session.bentoReinsertionAnchors[id],
               state.root?.windowIDs.contains(anchor.neighborWindowID) == true {
                var candidate = state
                if candidate.reinsert(id, beside: anchor.neighborWindowID, edge: anchor.edge),
                   let solved = solver.solve(
                       state: candidate,
                       in: display.visibleFrame,
                       constraints: constraints
                   ) {
                    state = solved
                    session.bentoReinsertionAnchors.removeValue(forKey: id)
                    session.automaticallyFloatingWindowIDs.remove(id)
                    continue
                }
            }
            if (state.root?.windowIDs.count ?? 0) >= 6 {
                Self.bentoLog.debug("float \(id.rawValue, privacy: .public): tree already holds six panes")
                state.setFloating(true, windowID: id)
                session.automaticallyFloatingWindowIDs.insert(id)
                continue
            }
            var candidate = state
            candidate.setFloating(false, windowID: id)
            if let focusedWindowID = session.focusedWindowID,
               candidate.root?.windowIDs.contains(focusedWindowID) == true {
                candidate.split(focusedWindowID, inserting: id, in: display.visibleFrame)
            } else {
                candidate.insert(id, in: display.visibleFrame, currentFrames: frames)
            }
            if let solved = solver.solve(state: candidate, in: display.visibleFrame, constraints: constraints) {
                state = solved
                session.automaticallyFloatingWindowIDs.remove(id)
            } else {
                Self.bentoLog.debug("float \(id.rawValue, privacy: .public): no insertion satisfied every minimum size")
                state.setFloating(true, windowID: id)
                session.automaticallyFloatingWindowIDs.insert(id)
            }
        }

        while state.root != nil,
              solver.solve(state: state, in: display.visibleFrame, constraints: constraints) == nil,
              let candidate = session.bentoInsertionOrder.reversed().first(where: { state.root?.windowIDs.contains($0) == true }) {
            Self.bentoLog.debug(
                "float \(candidate.rawValue, privacy: .public): tree unsolvable against current minimum sizes"
            )
            state.setFloating(true, windowID: candidate)
            session.automaticallyFloatingWindowIDs.insert(candidate)
        }
        if let solved = solver.solve(state: state, in: display.visibleFrame, constraints: constraints) {
            state = solved
        }
        session.bentoState = state
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

private struct ActiveBentoDrag {
    var session: BentoDragSession
    var transaction: WindowFrameTransaction
}
