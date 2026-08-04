import AppKit
import BetterTileCore
import BetterTileMacOS
import Foundation
import Observation
import os

@Observable
@MainActor
final class BetterTileModel {
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
    private var pendingFrameEventIDs: Set<WindowID> = []
    private var pendingTopologyRefresh = false
    private var pendingRestoredWindowDeadlines: [WindowID: Date] = [:]
    private var windowEventTask: Task<Void, Never>?
    private var settlementTasks: [DisplayID: Task<Void, Never>] = [:]
    private var spaceStabilizationTask: Task<Void, Never>?
    private var spaceStabilizationGeneration = 0
    private var isStabilizingSpace = false
    private var suppressSpaceFrameEventsUntil = Date.distantPast
    private var activeBentoDrag: ActiveBentoDrag?
    private var bentoDragEventBuffer = BentoDragEventBuffer()
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
        linkedResize = LinkedResizeController(coordinator: coordinator, configuration: loaded)
        dividerResize = DividerOverlayController(coordinator: coordinator, configuration: loaded)

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
        guard let actionPlan = coordinator.plan(action) else {
            statusMessage = coordinator.lastError ?? "No eligible focused window."
            presentActionResult(
                succeeded: false,
                error: statusMessage,
                displayID: originalDisplayID
            )
            return
        }
        let succeeded = if BentoDropPlanner.partitionActions.contains(actionPlan.resolvedAction),
                           sessionStore.session(for: actionPlan.displayID)?.mode == .bento {
            performBentoAction(actionPlan)
        } else {
            coordinator.perform(actionPlan)
        }
        statusMessage = succeeded
            ? nil
            : coordinator.lastError ?? statusMessage ?? "No eligible focused window."
        let resultingDisplayID = (try? system.focusedWindow())?.displayID ?? originalDisplayID
        presentActionResult(succeeded: succeeded, error: statusMessage, displayID: resultingDisplayID)
    }

    private func performBentoAction(_ actionPlan: WindowActionPlan) -> Bool {
        guard var session = sessionStore.session(for: actionPlan.displayID),
              let display = system.displays().first(where: { $0.id == actionPlan.displayID }),
              let windows = try? system.visibleWindows()
        else { return false }
        let displayWindows = windows.filter {
            $0.displayID == display.id && $0.isEligible && !$0.isFloating
        }
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
        guard coordinator.applyPlacements(plan.placements) else { return false }

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
        let succeeded = coordinator.applyCustomZone(zone)
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
            let displayWindows = windows.filter { $0.displayID == display.id }
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
            session.mode = .bento
            session.hasEvaluatedInitialPlacement = true
            session.reincludeInBento(Set(displayWindows.map(\.id)))
            session.bentoState.metrics = BentoLayoutMetrics(paneGap: configuration.bentoInnerGap)
            let placements: [Placement]
            if displayWindows.count <= 6 {
                let result = BentoPlanner().plan(
                    state: BentoRuntimeState(
                        layout: session.bentoState,
                        focusHistory: session.bentoFocusHistory,
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
                session.bentoFocusHistory = result.state.focusHistory
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
        pendingFrameEventIDs.removeAll()
        settlementTasks[displayID]?.cancel()
        settlementTasks.removeValue(forKey: displayID)
        bentoDragEventBuffer = BentoDragEventBuffer()
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
        pendingFrameEventIDs.formUnion(buffered.frameEventWindowIDs)
        pendingTopologyRefresh = pendingTopologyRefresh || buffered.topologyChanged
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
        if !changes.isDisjoint(with: [.snapping, .bentoGeometry]) {
            dragSnap.configuration = configuration
        }
        if changes.contains(.linkedResize) {
            linkedResize.configuration = configuration
        }
        if !changes.isDisjoint(with: [.divider, .bentoGeometry]) {
            dividerResize.configuration = configuration
        }
        if changes.contains(.shortcuts) {
            shortcuts.update(bindings: configuration.shortcuts)
        }
        if changes.contains(.titleBar) {
            titleBarDoubleClick.isEnabled = configuration.doubleClickTitleBarToMaximize
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
        pendingFrameEventIDs.removeAll()
        pendingTopologyRefresh = false
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
        let workAreaSignature = displayWorkAreaSignature(system.displays())
        if workAreaSignature != lastDisplayWorkAreaSignature {
            lastDisplayWorkAreaSignature = workAreaSignature
            dividerResize.hideAndCancel()
            refreshActiveWindows(force: true, windows: windows)
            return
        }
        let signature = windowSignature(windows)
        if signature != lastVisibleSignature { refreshActiveWindows(force: false, windows: windows) }
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
            if let id = event.windowID { pendingFrameEventIDs.insert(id) }
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
                        $0.bentoFocusHistory.removeAll()
                        $0.activeBentoFocusWindowID = nil
                    }
                }
                dragSnap.prepareForRestoredWindowDrag(windowID: windowID)
            }
            pendingTopologyRefresh = true
        case .created, .destroyed, .minimized:
            if let windowID = event.windowID {
                if event.kind == .minimized { recordMinimizedBentoPane(windowID) }
                unwindBentoFocusIfNeeded(windowID)
            }
            pendingTopologyRefresh = true
        case .focused:
            break
        }
        schedulePendingWindowEvents()
    }

    private func unwindBentoFocusIfNeeded(_ windowID: WindowID) {
        for displayID in sessionStore.sessions.keys {
            guard var session = sessionStore.session(for: displayID),
                  session.activeBentoFocusWindowID == windowID
            else { continue }
            session.bentoFocusHistory.removeAll { $0 == windowID }
            if let previous = session.bentoFocusHistory.last {
                session.activeBentoFocusWindowID = nil
                session.excludedFocusWindowIDs.remove(previous)
                try? system.setMinimized(false, for: previous)
                statusMessage = "Restoring previous overflow window."
            } else {
                let peers = session.excludedFocusWindowIDs
                session.activeBentoFocusWindowID = nil
                session.excludedFocusWindowIDs.removeAll()
                for peerID in peers {
                    try? system.setMinimized(false, for: peerID)
                }
                statusMessage = "Restoring Bento panes."
            }
            sessionStore.update(displayID) { $0 = session }
        }
    }

    private func recordMinimizedBentoPane(_ windowID: WindowID) {
        let displays = Dictionary(uniqueKeysWithValues: system.displays().map { ($0.id, $0) })
        for displayID in sessionStore.sessions.keys {
            guard let session = sessionStore.session(for: displayID),
                  session.mode == .bento,
                  session.activeBentoFocusWindowID != windowID,
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
                    focusHistory: session.bentoFocusHistory,
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

    private func schedulePendingWindowEvents() {
        guard activeBentoDrag == nil, !dragSnap.isGestureActive, !isStabilizingSpace else { return }
        guard !pendingFrameEventIDs.isEmpty || pendingTopologyRefresh else { return }
        windowEventTask?.cancel()
        windowEventTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            self?.processPendingWindowEvents()
        }
    }

    private func processPendingWindowEvents() {
        guard activeBentoDrag == nil, !dragSnap.isGestureActive, !isStabilizingSpace else { return }
        let changedIDs = pendingFrameEventIDs
        let refreshTopology = pendingTopologyRefresh
        pendingFrameEventIDs.removeAll()
        pendingTopologyRefresh = false

        guard let windows = try? system.visibleWindows() else { return }
        let visibleIDs = Set(windows.map(\.id))
        let now = Date()
        pendingRestoredWindowDeadlines = pendingRestoredWindowDeadlines.filter { windowID, deadline in
            !visibleIDs.contains(windowID) && deadline > now
        }
        let shouldRetryRestoredWindows = !pendingRestoredWindowDeadlines.isEmpty
        if shouldRetryRestoredWindows { pendingTopologyRefresh = true }
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

        let indexed = Dictionary(uniqueKeysWithValues: windows.map { ($0.id, $0) })
        let externalIDs = Set(changedIDs.filter { id in
            guard let frame = indexed[id]?.frame else { return false }
            return !coordinator.consumeExpectedMutation(windowID: id, actualFrame: frame)
        })
        guard !externalIDs.isEmpty else {
            if refreshTopology {
                refreshActiveWindows(force: false, windows: windows)
            } else {
                refreshDividerBoundaries(windows: windows)
            }
            return
        }

        let displayIDs = Set(externalIDs.compactMap { indexed[$0]?.displayID })
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
                guard indexed[id]?.displayID == displayID, let frame = frames[id] else { return false }
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

            let dividerChanges: Set<WindowID>
            switch ExternalChangeRouter.route(classifications) {
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
        session.bentoState = plan.state
        session.recordProposedFrames(
            Dictionary(uniqueKeysWithValues: plan.placements.map { ($0.windowID, $0.frame) })
        )
        sessionStore.update(display.id) { $0 = session }
        sessionRevision &+= 1
        _ = coordinator.applyPlacements(plan.placements, recordHistory: false)
        scheduleBentoSettlement(displayID: display.id, changedWindowIDs: Set(plan.placements.map(\.windowID)))
        refreshDividerBoundaries()
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
        _ = coordinator.applyPlacements(placements, recordHistory: false)
        refreshDividerBoundaries()
    }

    private func scheduleBentoSettlement(
        displayID: DisplayID,
        changedWindowIDs: Set<WindowID>,
        requestedFrames: [WindowID: BTRect]? = nil,
        baselineFrames: [WindowID: BTRect]? = nil
    ) {
        guard let sessionID = sessionStore.session(for: displayID)?.id else { return }
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
        let frames = Dictionary(uniqueKeysWithValues: displayWindows.map { ($0.id, $0.frame) })
        let constraints = Dictionary(uniqueKeysWithValues: displayWindows.map { ($0.id, $0.constraints) })
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
            pendingTopologyRefresh = true
            return
        }
        guard hasAccessibilityPermission || refreshPermission(recoverWindows: false) else {
            activeDisplayID = system.displays().first(where: \.isMain)?.id
            return
        }
        guard let windows = suppliedWindows ?? (try? system.visibleWindows()) else { return }
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
            let displayWindows = eligible.filter { $0.displayID == display.id }
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
            let initialPlacement: Placement? = if session.shouldApplyInitialPlacement(
                eligibleWindowCount: displayWindows.count
            ), let window = displayWindows.first,
               let action = configuration.singleWindowInitialPlacement.action,
               let frame = StandardActionEngine().targetFrame(for: action, window: window, display: display) {
                Placement(windowID: window.id, frame: frame)
            } else {
                nil
            }
            var shouldApply = false
            if session.mode == .bento {
                if activation.wasCreated {
                    if displayWindows.count == 1, let id = displayWindows.first?.id {
                        session.bentoState = BentoLayoutState(
                            root: .leaf(id),
                            metrics: BentoLayoutMetrics(paneGap: configuration.bentoInnerGap)
                        )
                        session.isBentoInitialized = true
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
                } else if desktopTransition {
                    // Returning to a known desktop is read-only. Its stored
                    // tree and ratios already describe how the user left it.
                } else if session.isBentoInitialized {
                    let membershipChanged = activation.previousWindowIDs != session.windowIDs
                    reconcileBentoSession(&session, windows: displayWindows, display: display)
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
                } else if displayWindows.count == 1, let id = displayWindows.first?.id {
                    session.bentoState = BentoLayoutState(
                        root: .leaf(id),
                        metrics: BentoLayoutMetrics(paneGap: configuration.bentoInnerGap)
                    )
                    session.isBentoInitialized = true
                }
            }
            let stateChanged = before != session.bentoState
            if !activation.wasCreated, !desktopTransition, stateChanged { shouldApply = true }
            if session.activeBentoFocusWindowID != nil {
                shouldApply = false
            }
            let needsWorkAreaSettlement = session.mode == .bento
                && session.isBentoInitialized
                && !displayWindows.isEmpty
                && shouldApply
                && workAreaChanged
            session.lastObservedFrames = frames
            if let initialPlacement { session.recordProposedFrames([initialPlacement.windowID: initialPlacement.frame]) }
            if !needsWorkAreaSettlement {
                session.lastWorkArea = display.visibleFrame
            }
            sessionStore.update(display.id) { $0 = session }
            if session.mode == .bento,
               let focusWindowID = session.bentoFocusHistory.last,
               session.activeBentoFocusWindowID != focusWindowID,
               let focusWindow = displayWindows.first(where: { $0.id == focusWindowID }),
               let focusFrame = StandardActionEngine().targetFrame(
                   for: .almostMaximize,
                   window: focusWindow,
                   display: display
               ) {
                let peers = Set(session.bentoState.root?.windowIDs ?? [])
                    .union(session.bentoFocusHistory.dropLast())
                    .intersection(Set(displayWindows.map(\.id)))
                    .subtracting([focusWindowID])
                if coordinator.applyFocusDrop(
                    placement: Placement(windowID: focusWindowID, frame: focusFrame),
                    minimizing: peers,
                    sourceBaselineFrame: focusWindow.frame
                ) {
                    sessionStore.update(display.id) {
                        $0.activeBentoFocusWindowID = focusWindowID
                        $0.excludedFocusWindowIDs.formUnion(
                            Set($0.bentoState.root?.windowIDs ?? [])
                                .union($0.bentoFocusHistory.dropLast())
                                .subtracting([focusWindowID])
                        )
                    }
                    statusMessage = "Six panes preserved; overflow focus."
                }
            } else if let initialPlacement {
                _ = coordinator.applyPlacements([initialPlacement], recordHistory: false)
            } else if session.mode == .bento, session.isBentoInitialized, !displayWindows.isEmpty, shouldApply {
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

    private func reconcileBentoSession(_ session: inout LayoutSession, windows: [WindowSnapshot], display: DisplaySnapshot) {
        let frames = Dictionary(uniqueKeysWithValues: windows.map { ($0.id, $0.frame) })
        let present = Set(windows.map(\.id))
        let constraints = Dictionary(uniqueKeysWithValues: windows.map { ($0.id, $0.constraints) })
        var state = session.bentoState
        state.metrics = BentoLayoutMetrics(paneGap: configuration.bentoInnerGap)
        let knownIDs = Set(state.root?.windowIDs ?? []).union(state.floatingWindowIDs)
        let temporarilyHidden = session.excludedFocusWindowIDs
            .union(session.bentoFocusHistory)
            .union(session.bentoReinsertionAnchors.keys)
        for oldID in knownIDs where !present.contains(oldID) && !temporarilyHidden.contains(oldID) {
            state.remove(oldID)
        }
        session.bentoInsertionOrder.removeAll {
            !present.contains($0) && !temporarilyHidden.contains($0)
        }
        session.automaticallyFloatingWindowIDs.formIntersection(present)
        for id in windows.map(\.id).sorted() where !session.bentoInsertionOrder.contains(id) {
            session.bentoInsertionOrder.append(id)
        }

        while (state.root?.windowIDs.count ?? 0) > 6,
              let candidate = session.bentoInsertionOrder.reversed().first(where: {
                  state.root?.windowIDs.contains($0) == true
              }) {
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
                state.setFloating(true, windowID: id)
                session.automaticallyFloatingWindowIDs.insert(id)
                session.bentoFocusHistory.removeAll { $0 == id }
                session.bentoFocusHistory.append(id)
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
                state.setFloating(true, windowID: id)
                session.automaticallyFloatingWindowIDs.insert(id)
            }
        }

        while state.root != nil,
              solver.solve(state: state, in: display.visibleFrame, constraints: constraints) == nil,
              let candidate = session.bentoInsertionOrder.reversed().first(where: { state.root?.windowIDs.contains($0) == true }) {
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

    private func presentActionResult(succeeded: Bool, error: String? = nil, displayID: DisplayID?) {
        let feedback = succeeded ? ResultPillFeedback.success() : ResultPillFeedback.failure(error)
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
