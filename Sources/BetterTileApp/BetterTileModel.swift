import AppKit
import BetterTileCore
import BetterTileMacOS
import Foundation
import Observation
import os

/// The macOS observations the app model coordinates. The Accessibility adapter
/// and the deterministic app-test adapter meet at this seam.
@MainActor
protocol BetterTileWindowSystem: TargetedWindowSystem, WindowEventSource, WindowHitTesting, ApplicationActivating, ApplicationWindowRequesting {
    var enhancedUserInterfacePolicy: EnhancedUserInterfacePolicy { get set }
    var leavesSpaceForDock: Bool { get set }
    var unresponsiveApplicationRecoveryDeadlines: [Int32: TimeInterval] { get }
    func visibleWindows(recoveringApplicationPIDs: inout Set<Int32>) throws -> [WindowSnapshot]
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
    func startDisplayReconfigurationMonitoring(onChange: @escaping @MainActor () -> Void)
    func stopDisplayReconfigurationMonitoring()
    func updateManagedWindowIDs(_ ids: Set<WindowID>)
    /// Puts back settings that BetterTile changed and could not restore yet.
    func restoreEnhancedUserInterfaceBeforeQuit()
}

extension AccessibilityWindowSystem: BetterTileWindowSystem {}

extension BetterTileWindowSystem {
    var unresponsiveApplicationRecoveryDeadlines: [Int32: TimeInterval] { [:] }
    func restoreEnhancedUserInterfaceBeforeQuit() {}
}

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
    /// Traces how Tabbed places a window that arrives, returns, or floats,
    /// and its focus corrections and stacking repairs. Window identifiers
    /// and frames only; never titles. Read with:
    ///   log stream --level debug --predicate 'subsystem == "com.lmckarma.BetterTile" AND category == "Tabbed"'
    static let tabbedLog = Logger(subsystem: "com.lmckarma.BetterTile", category: "Tabbed")
    private static let signposter = OSSignposter(
        subsystem: "com.lmckarma.BetterTile",
        category: "Model"
    )

    var configuration: BetterTileConfiguration
    var hasAccessibilityPermission = false
    private(set) var isWaitingForAccessibilityPermission = false
    var statusMessage: String?
    let configurationLoadError: (any Error)?
    var configurationSaveBlockedReason: String? {
        guard let configurationLoadError else { return nil }
        return "Settings could not be loaded: \(configurationLoadError.localizedDescription) "
            + "Changes apply only for this session. Saving is blocked to preserve the configuration file. "
            + "Restore a valid configuration at \(store.fileURL.path), then quit and reopen BetterTile."
    }
    private(set) var lastActionFeedback: ResultPillFeedback?
    private(set) var activeDisplayID: DisplayID?
    private(set) var layoutWheelMonitoringFailure: String?
    let savedLayoutTarget = SavedLayoutTarget()
    let appGroupsStore: AppGroupsStore
    private var appGroupsLoadTask: Task<Void, Never>?
    let savedLayoutActions: SavedLayoutActions
    private let runsActionRegistration: Bool
    var savedLayoutScreenNames: () -> [DisplayID: String] = {
        Dictionary(uniqueKeysWithValues: DisplayFingerprintReader.current().map { ($0.id, $0.fingerprint.name) })
    }
    private(set) var savedLayoutActionTargetName: String?
    private var userActionDisplayID: DisplayID?
    private(set) var savedLayoutShortcutFailures: Set<String> = []
    private(set) var savedLayoutActionFile: String?
    var showSavedLayoutChooser: ([SavedLayoutActionEntry]) -> Void = { _ in }

    /// Settings throttles read-only Apply plans after window-system events.
    private(set) var savedLayoutInventoryRevision = 0
    private(set) var savedLayoutApplier: SavedLayoutApplier?
    /// Fake-system callers can supply an input turn without starting the native runtime.
    var savedLayoutInputCheckpoint: @MainActor () async -> Bool = { true }
    private var savedLayoutFollowingDisplayID: DisplayID?
    /// The display bindings of Saved Layouts. Settings and the automatic Apply share this one store.
    let displayTriggerStore: DisplayTriggerStore
    private(set) var displayTriggerRuntime: DisplayTriggerRuntime?
    /// The Settings page that a Result pill button asks to show. Settings clears it.
    var requestedSettingsDestination: SettingsDestination?
    var openSettings: () -> Void = {}
    /// Shows or hides the BetterTile status items. The app delegate owns them.
    var setMenuBarIconVisible: (Bool) -> Void = { _ in }

    private let system: any BetterTileWindowSystem
    #if DEBUG
    var arrivalTrace: ArrivalTrace {
        get { coordinator.arrivalTrace }
        set { coordinator.arrivalTrace = newValue }
    }

    private func tracePendingArrivals(_ phase: String, reason: String) {
        guard arrivalTrace.isEnabled else { return }
        for arrival in pendingWindowArrivals {
            arrivalTrace.record(phase, pid: arrival.processIdentifier, windowID: arrival.windowID, reason: reason)
        }
    }
    #endif

    private let coordinator: WindowCoordinator
    private let store: ConfigurationStore
    private let shortcuts: GlobalShortcutMonitor
    private let dragSnap: DragSnapController
    private let titleBarDoubleClick: TitleBarDoubleClickController
    private let linkedResize: LinkedResizeController
    private let layoutWheel: LayoutWheelController
    private let sharedGestureEvents: SharedGestureEventMonitor
    var appKitWindowGestureFilter = AppKitWindowGestureFilter()
    let dividerResize: DividerOverlayController
    private var resultPill: ResultPillController?
    var resultPillFactory: () -> ResultPillController = { ResultPillController() }
    /// Automatic Apply shows one pill on each display, so two displays do not replace each other's.
    private var automaticResultPills: [DisplayID: ResultPillController] = [:]
    private var sessionStore = LayoutSessionStore() {
        didSet {
            if let applier = savedLayoutApplier, applier.tracksUndoSessions {
                applier.updateUndoSessions(savedLayoutSessions(), desktops: sessionStore.sessions.compactMapValues(\.nativeSpaceID))
            }
        }
    }
    private(set) var paneApplicationRequest: PaneApplicationRequest? { didSet { syncSharedGestureMonitoring() } }
    var paneApplicationLauncher: any PaneApplicationLaunching = WorkspacePaneApplicationLauncher()
    var paneApplicationTimeout: TimeInterval = 10
    var tabbedClock: BetterTileClock = .live
    var paneApplicationClock: BetterTileClock = .live
    /// Nil builds the production helper from the sources below.
    var paneApplicationRequestFocusFactory: (() -> ApplicationRequestFocus)?
    var applicationRequestFrontmost: () -> String? = { NSWorkspace.shared.frontmostApplication?.bundleIdentifier }
    var menuPanelIsShown: () -> Bool = { false }
    private struct MenuPanelDeferredFocus {
        let windowID: WindowID
        let displayID: DisplayID
        let sessionID: DesktopSessionID
        let spaceID: NativeSpaceID?
        let usesNativeObservation: Bool
        let generation: Int
        let focusEpoch: Int
    }
    private var menuPanelDeferredFocus: MenuPanelDeferredFocus?
    /// Counts panel presentations, commands, and other focus choices. A placement that started
    /// under an earlier count must not replay its focus.
    private var menuPanelFocusEpoch = 0
    /// The dismissal's focus rule. A placement that commits after the dismissal evaluates it when its wait ends.
    private var menuPanelDismissalAuthorization: () -> Bool = { true }
    var menuPanelClock: BetterTileClock = .live
    /// How long a placement that commits after the dismissal waits before it focuses. macOS reports a
    /// Space switch only when its animation ends, about half a second after the switch key.
    var menuPanelLateFocusDelay: Duration = .milliseconds(700)
    private(set) var menuPanelLateFocusTask: Task<Void, Never>?

    func menuPanelWillOpen() {
        invalidateMenuPanelFocusReplay()
        menuPanelDismissalAuthorization = { true }
    }

    /// Focus returns when the user dismisses the panel, before its fade. A Space switch that starts
    /// during the fade is not reported until it ends, so a replay at the fade's end could focus a window
    /// on the desktop the user is leaving.
    func menuPanelDidDismiss(authorization: @escaping () -> Bool = { true }) {
        menuPanelDismissalAuthorization = authorization
        // One dismissal focuses once. A placement that commits after this focus must not focus again.
        if replayMenuPanelFocus(authorized: authorization()) { menuPanelDismissalAuthorization = { false } }
    }

    /// A command or a newer focus choice replaces the focus that the menu panel deferred.
    func invalidateMenuPanelFocusReplay() {
        menuPanelFocusEpoch += 1
        menuPanelDeferredFocus = nil
        menuPanelLateFocusTask?.cancel()
        menuPanelLateFocusTask = nil
    }

    /// A placement that commits after the dismissal waits for a Space switch to be reported. A Space
    /// change, another app's activation, a command or a reopened panel cancels the wait.
    private func scheduleLateMenuPanelFocus() {
        menuPanelLateFocusTask?.cancel()
        let clock = menuPanelClock
        let delay = menuPanelLateFocusDelay
        menuPanelLateFocusTask = Task { @MainActor [weak self] in
            try? await clock.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            self.menuPanelLateFocusTask = nil
            self.replayMenuPanelFocus(authorized: self.menuPanelDismissalAuthorization())
        }
    }

    @discardableResult
    private func replayMenuPanelFocus(authorized: Bool) -> Bool {
        let target = menuPanelDeferredFocus
        menuPanelDeferredFocus = nil
        guard authorized, let target, target.focusEpoch == menuPanelFocusEpoch,
              !isShutDown, !isStabilizingSpace, hasAccessibilityPermission,
              target.generation == spaceStabilizationGeneration,
              !nativeFullscreenDisplayIDs.contains(target.displayID),
              system.displays().contains(where: { $0.id == target.displayID }),
              let session = sessionStore.session(for: target.displayID), session.id == target.sessionID,
              session.mode == .tabbed, !session.automaticWritesSuspended,
              session.tabbedState?.selectedWindowIDs.contains(target.windowID) == true else { return false }
        let observation = system.refreshNativeDesktopObservation()
        guard (observation != nil) == target.usesNativeObservation,
              observation?.allowsAutomaticLayout(on: target.displayID) != false,
              observation?.currentSpace(on: target.displayID) == target.spaceID else { return false }
        if let space = target.spaceID {
            guard session.nativeSpaceID == space,
                  observation?.windowMembership[target.windowID] == [space] else { return false }
        }
        guard let window = (try? system.windowSnapshots(ids: [target.windowID]))?.first,
              window.isEligible, !window.isFloating, window.displayID == target.displayID else { return false }
        return coordinator.focusTabbedWindow(target.windowID).isApplied
    }
    var applicationRequestKeyboard: any KeyboardEventCounting = SessionKeyDownCounter()
    var applicationRequestWindowAtPoint: ((BTPoint) -> WindowSnapshot?)?
    private let applicationRequestIntent = ApplicationRequestIntent()
    private var completedRequestFocus: [UUID: ApplicationRequestFocus] = [:]
    private var completedRequestFocusDeadline: [UUID: TimeInterval] = [:]
    private var completedRequestFocusExpiry: [UUID: Task<Void, Never>] = [:]
    var registeredApplicationRequestFocusCount: Int { applicationRequestIntent.registeredFocusCount }
    func makeApplicationRequestFocus() -> ApplicationRequestFocus {
        let focus = paneApplicationRequestFocusFactory?() ?? makeProductionRequestFocus()
        focus.shareIntent(applicationRequestIntent)
        return focus
    }
    func makeProductionRequestFocus() -> ApplicationRequestFocus {
        ApplicationRequestFocus(frontmost: applicationRequestFrontmost, keyboard: applicationRequestKeyboard,
                                activator: coordinator)
    }
    func requestApplicationActivated(_ bundleID: String?, processIdentifier: Int32? = nil) {
        if processIdentifier != ProcessInfo.processInfo.processIdentifier,
           bundleID == nil || bundleID != Bundle.main.bundleIdentifier {
            invalidateMenuPanelFocusReplay()
        }
        expireCompletedRequestFocus()
        applicationRequestIntent.activated(bundleID, processIdentifier: processIdentifier)
        guard let bundleID else { return }
        for (id, focus) in completedRequestFocus where focus.requested.contains(bundleID) {
            if focus.restoreUserFocusIfNeeded() { releaseCompletedRequestFocus(id) }
        }
    }
    private func observeCompletedRequestFocus(_ focus: ApplicationRequestFocus) {
        guard focus.needsObservation else { focus.finish(); return }
        let id = focus.id
        completedRequestFocus[id] = focus
        completedRequestFocusDeadline[id] = paneApplicationUptime() + 2
        syncSharedGestureMonitoring()
        ApplicationRequestIntent.log.debug("restore observation=start seconds=2")
        let clock = paneApplicationClock
        completedRequestFocusExpiry[id] = Task { @MainActor [weak self] in
            try? await clock.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.releaseCompletedRequestFocus(id)
        }
    }
    private func expireCompletedRequestFocus() {
        for (id, deadline) in completedRequestFocusDeadline where paneApplicationUptime() >= deadline {
            releaseCompletedRequestFocus(id)
        }
    }
    private func releaseCompletedRequestFocus(_ id: UUID) {
        guard let focus = completedRequestFocus.removeValue(forKey: id) else { return }
        completedRequestFocusDeadline[id] = nil
        completedRequestFocusExpiry.removeValue(forKey: id)?.cancel()
        ApplicationRequestIntent.log.debug("restore observation=end")
        focus.finish()
        syncSharedGestureMonitoring()
    }
    /// Delivers one AppKit fallback event as the drag-snap monitors do.
    func receiveFallbackRequestMouseEvent(_ event: GlobalGestureEvent) { dragSnap.forwardFallbackMouseEvent(event) }
    var observesApplicationRequestMouseDown: Bool { dragSnap.observesChooserMouseDown }
    var observesApplicationRequestMouseSequence: Bool { dragSnap.observesRequestMouseSequence }
    /// How long a pane waits for a click on a window that arrived before it gives up.
    var paneApplicationClickTimeout: TimeInterval = 60
    /// A pending click older than this lost its mouse-up and no longer delays the click timeout.
    var paneApplicationPendingClickLimit: TimeInterval = 5
    /// System uptime for pane application deadlines, click limits, and arrival guards. Tests replace it.
    var paneApplicationUptime: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    /// How long after the mouse-up of a click on an arrived window the model reads the focused window.
    var paneApplicationClickConfirmDelay: Duration = .milliseconds(250)
    private(set) var paneApplicationTask: Task<Void, Never>?
    private(set) var paneApplicationClickTask: Task<Void, Never>?
    var isPollingPaneApplicationRequest: Bool { paneApplicationTask != nil }
    private var paneApplicationPickerTask: Task<Void, Never>?
    private(set) var paneApplicationLaunchTask: Task<Void, Never>?
    var paneApplicationPopover: PaneApplicationPopover? {
        didSet { syncSharedGestureMonitoring() }
    }
    private var paneApplicationArrivalGuards: [PaneApplicationArrivalGuard] = []
    private var tabbedOverlays: [DisplayID: TabbedOverlayController] = [:]
    var tabbedOverlayFactory: () -> TabbedOverlayController = { TabbedOverlayController() }
    var paneApplicationPopoverFactory: (PaneApplicationRequest, OverlayAppearance) -> PaneApplicationPopover = {
        PaneApplicationPopover(request: $0, appearance: $1)
    }
    private var spacePanelOverlays: [DesktopSessionID: TabbedOverlayController] = [:]
    private var spacePanelCorrections: Set<DesktopSessionID> = []

    private var allTabbedOverlays: [TabbedOverlayController] {
        let active = Array(tabbedOverlays.values)
        return active + spacePanelOverlays.values.filter { retained in !active.contains { $0 === retained } }
    }
    private var tabbedTasks: [DisplayID: Task<Void, Never>] = [:]
    private var tabbedTaskIDs: [DisplayID: UUID] = [:]
    /// The mode and layout to keep if entry cannot place its selected tabs.
    private var tabbedEntryBaselines: [DesktopSessionID: LayoutSession] = [:]
    private var tabbedExiting: Set<DisplayID> = []
    private var tabbedQueuedIntents: [DisplayID: [PendingTabbedIntent]] = [:]
    private var tabbedUndo: [DesktopSessionID: [TabbedUndoStep]] = [:]
    private var tabbedNeedsRefresh: Set<DisplayID> = []
    /// New windows already adopted again after refusing their first pane.
    /// A second refusal is reported instead of adopting them forever.
    private var tabbedReadoptedArrivals: Set<WindowID> = []
    /// Automatic floats already checked again once after they floated.
    private var tabbedRetriedAutomaticFloats: Set<WindowID> = []
    /// The pane frames and selected tabs of each session's last committed
    /// Tabbed placement. A change means room may have appeared for an
    /// automatic float. Dropped when the session leaves Tabbed.
    private var tabbedCommittedLayouts: [DesktopSessionID: TabbedCommittedLayout] = [:]
    /// Windows seen settling up to one step off their pane, such as
    /// Terminal on whole character cells, with the lengths each settled at
    /// on each axis where it stepped. Their grids decide where pane dividers
    /// go and what each window is asked for, so it is never asked for a
    /// length it rounds away from.
    private(set) var tabbedSteppedWindows: [WindowID: [SplitAxis: [Double]]] = [:]
    /// How long after a placement settles an automatic float is checked
    /// again with a fresh snapshot. Settable for tests.
    var tabbedAutomaticFloatRetryDelay: Duration = .seconds(1)
    /// How long a check waits for a busy display before it asks again; it
    /// gives up after ten waits. Settable for tests.
    var tabbedAutomaticFloatRetryDeferral: Duration = .milliseconds(250)
    /// Checks that read the windows again, for tests.
    private(set) var tabbedAutomaticFloatChecksRun = 0
    /// Checks that gave up on a busy display, for tests.
    private(set) var tabbedAutomaticFloatChecksGivenUp = 0
    /// An apply arrived while another was running; re-apply the committed state after it.
    var tabbedNeedsReapply: Set<DisplayID> = []
    private let presentsTabbedChrome: Bool
    private(set) var tabbedFocusTask: Task<Void, Never>?
    /// Displays whose stacking repair left raises out to keep a popup's focus.
    private(set) var tabbedRepairDeferred: Set<DisplayID> = []
    private(set) var tabbedNeedsFocusRefresh = false
    private var tabbedFocusSuppressedUntil: BetterTileClock.Instant?
    private var lastBentoFocusMessage: String?
    private var tabbedCurtainRecheckTask: Task<Void, Never>?
    private var absenceConfirmationTask: Task<Void, Never>?
    private var arrivalSweepTask: Task<Void, Never>?
    private var lastTabbedNativeResizePreview: BetterTileClock.Instant?
    /// The Bento tree from before Focus mode, per desktop session, so ending
    /// Focus mode returns exactly the previous layout.
    private struct BentoFocusSnapshot {
        var layout: BentoLayoutState
        // Keep direct closure evidence after ordinary sweeps consume it.
        var closedWindowIDs: Set<WindowID> = []
    }
    private var bentoStateBeforeFocus: [DesktopSessionID: BentoFocusSnapshot] = [:]
    /// Finishes a layout command once Focus mode peers return, one per
    /// display. A newer layout action on the same display cancels it; an
    /// action on another display leaves it running.
    private struct FocusRestore {
        var task: Task<Void, Never>
        var session: LayoutSession
        var generation: Int
        var closedWindowIDs: Set<WindowID>
    }
    private var focusRestores: [DisplayID: FocusRestore] = [:]
    private var focusRestoreSessionIDs: Set<DesktopSessionID> { Set(focusRestores.values.map(\.session.id)) }

    private var focusRestoreGeneration = 0
    /// Nil cancels the restore on every display.
    private func cancelPendingFocusRestore(on displayID: DisplayID?) {
        if let displayID {
            focusRestores.removeValue(forKey: displayID)?.task.cancel()
        } else {
            focusRestores.values.forEach { $0.task.cancel() }
            focusRestores.removeAll()
        }
    }
    /// The display a keyboard or menu action acts on.
    private func actionDisplayID(requiringUserAction: Bool = false) -> DisplayID? {
        let connected = Set(system.displays().map(\.id))
        if let remembered = userActionDisplayID, !connected.contains(remembered) { userActionDisplayID = nil }
        if let focused = try? system.focusedWindow(), connected.contains(focused.displayID),
           !requiringUserAction || (focused.isEligible && rule(for: focused).allowsDirectPlacement) {
            return focused.displayID
        }
        if requiringUserAction { return userActionDisplayID.flatMap { connected.contains($0) ? $0 : nil } }
        return activeDisplayID
    }

    /// Only managed focus observations and explicit BetterTile actions grant session provenance.
    /// Initialization, topology refresh and reconciliation must never call this method.
    private func rememberUserActionDisplay(_ id: DisplayID) {
        guard system.displays().contains(where: { $0.id == id }) else { return }
        userActionDisplayID = id
        activeDisplayID = id
    }
    /// Ending Focus mode is still bringing the covered windows back. Repair
    /// runs after that restore, so it never lays the desktop out without
    /// them. A newer action that cancels the restore also wins over Repair.
    private func repairsAfterFocusRestore(on displayID: DisplayID?, _ repair: @escaping @MainActor () -> Void) -> Bool {
        guard let displayID, let pending = focusRestores[displayID]?.task else { return false }
        Task { @MainActor [weak self] in
            await pending.value
            guard let self, !self.isShutDown, !pending.isCancelled else { return }
            repair()
        }
        return true
    }
    /// The tab the user last selected. Activating its application can make
    /// that application's previous main window key instead; for a short
    /// time such a focus change is corrected rather than treated as a
    /// selection.
    private var tabbedIntendedFocus: (windowID: WindowID, until: BetterTileClock.Instant)?
    /// Tabbed reads a window-edge resize only after the user lets go, so it
    /// never fights the drag. Tests replace this.
    var primaryButtonIsPressed: () -> Bool = { NSEvent.pressedMouseButtons & 1 == 1 }
    /// How long a repeated half shortcut keeps cycling sizes. Tests replace this.
    var shortcutCycleInterval: TimeInterval {
        get { coordinator.shortcutCycleInterval }
        set { coordinator.shortcutCycleInterval = newValue }
    }
    private var tabbedResizeReleaseTask: Task<Void, Never>?

    private var watchdogTimer: Timer?
    private struct ApplicationRecovery {
        var attempts = 0
        var notBefore: TimeInterval = 0
    }
    private var applicationRecoveries: [Int32: ApplicationRecovery] = [:]
    var applicationRecoveryUptime: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    var applicationRecoveryClock: BetterTileClock = .live
    private(set) var applicationRecoveryTask: Task<Void, Never>?
    private(set) var applicationRecoveryDeadline: TimeInterval?
    // A readable returning window still needs a successful current reconciliation.
    private var applicationRecoveryPendingWindows: [WindowID: Int32] = [:]
    private var applicationRecoveryGeneration: Int?
    private var applicationRecoveryFallbackMatches: [DesktopSessionID: Bool] = [:]
    private var applicationRecoveryProbePIDs: Set<Int32>?
    private var applicationRecoveryFrameEventPIDs: [WindowID: Int32] = [:]
    private enum RecoveryFrameResult {
        case handled
        case mutation(BentoProposalCommitResult)
        case deferred

        var isHandled: Bool {
            switch self {
            case .handled, .mutation(.committed): true
            case .mutation(.rejected), .mutation(.stale), .mutation(.degraded), .deferred: false
            }
        }
    }
    private var permissionPollTask: Task<Void, Never>?
    private var notificationTokens: [NSObjectProtocol] = []
    private var notificationCenters: [NotificationCenter] = []
    private var lastVisibleSignature = ""
    private var lastDisplayWorkAreaSignature = ""
    private var pendingWindowEvents = WindowEventBuffer()
    /// Set when focus lands in a Bento layout. Later focus elsewhere does not
    /// clear it; only the event pass that runs the peer check does.
    private var pendingBentoFocusCheck = false
    /// Windows a destroyed event has accounted for. Direct evidence, so their
    /// panes are released without waiting for absence to be corroborated.
    private var confirmedGoneWindowIDs: Set<WindowID> = []
    /// Minimized panes are direct absences too, but retain a local reinsertion
    /// anchor when the membership transition commits.
    private var confirmedMinimizedWindowIDs: Set<WindowID> = []
    private var actionVerificationTask: Task<Void, Never>?
    private var pendingRestoredWindowDeadlines: [WindowID: Date] = [:]
    private struct PendingWindowArrival {
        let processIdentifier: Int32
        let windowID: WindowID?
        let observedIDs: Set<WindowID>
        let deadline: Date
        var hasMultipleUnknownCreations = false
        /// Names the element the creation callback delivered, until a targeted read decides it.
        var creationToken: UInt64?
    }
    private var pendingWindowArrivals: [PendingWindowArrival] = []
    /// Set while a window read from its own element is placed, so Tabbed starts its placement in the same turn.
    private var placesCreatedWindowsInThisTurn = false
    /// Keeps arrival elapsed time independent of main-actor scheduling in tests.
    var windowArrivalNow: () -> Date = { Date() }
    private(set) var windowEventTask: Task<Void, Never>?
    private var windowEventTaskIncludesTopology = false
    private var windowEventTaskIsImmediate = false
    private var windowEventRetryBackoff = WindowEventRetryBackoff()
    /// Scheduling seam for fake-system latency tests.
    var windowEventSleep: (Duration) async throws -> Void = { try await BetterTileClock.live.sleep(for: $0) }
    private(set) var settlementTasks: [DisplayID: Task<Void, Never>] = [:]
    private var settlementTaskGenerations: [DisplayID: UInt64] = [:]
    private var spaceStabilizationTask: Task<Void, Never>?
    var displayRefreshDebouncer = DisplayRefreshDebouncer()
    private var spaceStabilizationGeneration = 0
    private(set) var isStabilizingSpace = false
    private var nativeFullscreenDisplayIDs: Set<DisplayID> = []
    private var suppressSpaceFrameEventsUntil: BetterTileClock.Instant?
    private var activeBentoDrag: ActiveBentoDrag?
    private var bentoDragEventBuffer = WindowEventBuffer()
    private(set) var paneGapRelayoutTask: Task<Void, Never>?
    private var paneGapRelayoutPending = false
    private var paneGapBeforeRelayout: Double?
    private var paneGapEditChanged = false
    private var isEditingPaneGap = false
    /// Keep ordinary event sweeps on the last published gap until the coalesced pass.
    private var paneGapForLayout: Double { paneGapBeforeRelayout ?? configuration.bentoInnerGap }
    var paneGapRelayoutSleep: (Duration) async throws -> Void = { try await BetterTileClock.live.sleep(for: $0) }
    private var configurationSaveTask: Task<Void, Never>?
    private var configurationNeedsSave = false
    private var isShortcutCaptureActive = false
    private var isShutDown = false
    let clock: BetterTileClock

    init(
        store: ConfigurationStore = .defaultStore(),
        system suppliedSystem: (any BetterTileWindowSystem)? = nil,
        startRuntime: Bool = true,
        presentsTabbedChrome: Bool? = nil,
        displayTriggerStore: DisplayTriggerStore? = nil,
        savedLayoutFiles: SavedLayoutFiles? = nil,
        appGroupsStore: AppGroupsStore? = nil,
        shortcutMonitor: GlobalShortcutMonitor? = nil,
        gestureEvents: SharedGestureEventMonitor? = nil,
        clock: BetterTileClock = .live,
        uptime: (@MainActor () -> TimeInterval)? = nil
    ) {
        self.store = store
        self.clock = clock
        applicationRecoveryUptime = { uptime?() ?? ProcessInfo.processInfo.systemUptime }
        applicationRecoveryClock = clock
        displayRefreshDebouncer = DisplayRefreshDebouncer(clock: clock)
        windowEventSleep = { try await clock.sleep(for: $0) }
        paneGapRelayoutSleep = { try await clock.sleep(for: $0) }
        let arrivalOrigin = clock.now
        let arrivalDate = Date()
        windowArrivalNow = {
            let elapsed = arrivalOrigin.duration(to: clock.now).components
            return arrivalDate.addingTimeInterval(Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18)
        }
        if startRuntime { savedLayoutInputCheckpoint = { await SavedLayoutInputTurn(clock: clock).wait() } }
        runsActionRegistration = startRuntime || shortcutMonitor != nil
        savedLayoutActions = .init(files: savedLayoutFiles ?? (startRuntime ? .standard
            : .init(directory: store.fileURL.deletingLastPathComponent().appendingPathComponent("Saved Layouts"))))
        self.appGroupsStore = appGroupsStore ?? (startRuntime
            ? AppGroupsStore(directory: savedLayoutActions.files.directory.deletingLastPathComponent())
            : AppGroupsStore(directory: savedLayoutActions.files.directory.deletingLastPathComponent(), catalog: { [] }, defaultBrowserURL: { nil }))
        self.displayTriggerStore = displayTriggerStore ?? (startRuntime ? .standard()
            : DisplayTriggerStore(url: store.fileURL.deletingLastPathComponent().appendingPathComponent("Display Triggers.json")))
        self.presentsTabbedChrome = presentsTabbedChrome ?? startRuntime
        let loaded: BetterTileConfiguration
        do {
            loaded = try store.load()
            configurationLoadError = nil
        } catch {
            loaded = BetterTileConfiguration()
            configurationLoadError = error
        }
        let windowSystem: any BetterTileWindowSystem = suppliedSystem ?? AccessibilityWindowSystem()
        configuration = loaded
        windowSystem.enhancedUserInterfacePolicy = loaded.enhancedUserInterfacePolicy
        windowSystem.leavesSpaceForDock = loaded.leavesSpaceForDock
        system = windowSystem
        coordinator = WindowCoordinator(system: windowSystem, clock: clock)
        shortcuts = shortcutMonitor ?? GlobalShortcutMonitor { _ in }
        dragSnap = DragSnapController(coordinator: coordinator, configuration: loaded)
        titleBarDoubleClick = TitleBarDoubleClickController(
            coordinator: coordinator,
            isEnabled: loaded.doubleClickTitleBarToMaximize
        )
        titleBarDoubleClick.applicationRules = loaded.applicationRules
        linkedResize = LinkedResizeController(coordinator: coordinator, configuration: loaded)
        layoutWheel = LayoutWheelController(configuration: loaded)
        sharedGestureEvents = gestureEvents ?? SharedGestureEventMonitor()
        dividerResize = DividerOverlayController(coordinator: coordinator, configuration: loaded)
        layoutWheel.suspend()

        shortcuts.isEnabled = loaded.keyboardShortcutsEnabled
        shortcuts.setHandler { [weak self] action in
            // The wheel and this shortcut share held modifiers. Running the
            // shortcut means the user was never opening a wheel.
            self?.layoutWheel.cancel(reason: .shortcut)
            self?.perform(action)
        }
        titleBarDoubleClick.isTabbedMember = { [weak self] id in self?.isTabbedMember(id) == true }
        dragSnap.isTabbedMember = { [weak self] id in self?.isTabbedMember(id) == true }
        dragSnap.tabbedDropZoneProvider = { [weak self] displayID, point, windowID in
            self?.tabbedOverlays[displayID]?.tabDropZone(at: point, dragging: windowID)
        }
        dragSnap.primaryButtonIsPressed = { [weak self] in self?.primaryButtonIsPressed() == true }
        dragSnap.activeModeProvider = { [weak self] displayID in self?.activeMode(for: displayID) }
        dragSnap.bentoStateProvider = { [weak self] displayID in self?.sessionStore.session(for: displayID)?.bentoState }
        dragSnap.bentoDragBeganHandler = { [weak self] displayID, sourceID, sourceFrame in
            self?.cancelPendingFocusRestore(on: displayID)
            return self?.beginBentoDrag(displayID: displayID, sourceID: sourceID, sourceFrame: sourceFrame) ?? false
        }
        dragSnap.bentoPreviewHandler = { [weak self] displayID, sourceID, outcome in
            self?.previewBentoDrag(displayID: displayID, sourceID: sourceID, outcome: outcome)
        }
        dragSnap.bentoDragEndedHandler = { [weak self] displayID, sourceID, end in
            self?.finishBentoDrag(displayID: displayID, sourceID: sourceID, end: end)
        }
        dragSnap.gestureEndedHandler = { [weak self] in
            guard let self else { return }
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
            self?.allTabbedOverlays.reduce(into: Set<Int>()) { $0.formUnion($1.windowNumbers) } ?? []
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
                      let windows = try? self.observeVisibleWindows() else { return }
                self.applyTabbedState(tabbed, session: session, display: display,
                    windows: self.bentoEligible(windows.filter { $0.displayID == displayID && $0.isEligible && !$0.isFloating }),
                    focus: nil, rememberUndo: true,
                    rollbackFrames: baselineFrames.merging(session.lastObservedFrames) { _, verified in verified })
                return
            }
            session.resumeAutomaticWrites()
            session.bentoState = state
            session.forgetRememberedBentoLayouts()
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
            self?.schedulePendingWindowEvents()
        }
        linkedResize.isEnabledForDisplay = { [weak self] displayID in
            guard let self else { return false }
            return self.activeMode(for: displayID) == .manual && !self.dividerResize.isDragging
        }
        linkedResize.layoutChangedHandler = { [weak self] _, _ in
            self?.refreshDividerBoundaries()
        }
        layoutWheel.captureHandler = { [weak self] pointer in self?.captureLayoutWheelTarget(pointer: pointer) }
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
        layoutWheel.gestureBeganHandler = { [weak self] in self?.layoutWheelDidOpen() }
        layoutWheel.gestureEndedHandler = { [weak self] in
            guard let self, !self.isShortcutCaptureActive else { return }
            self.shortcuts.resume()
        }
        dragSnap.chooserMouseDownHandler = { [weak self] event in
            self?.receiveTabbedChooserMouseEvent(event)
            self?.receivePaneApplicationMouseEvent(event, feed: "fallback")
        }
        dragSnap.requestMouseSequenceHandler = { [weak self] event in
            self?.receivePaneApplicationMouseEvent(event, feed: "fallback")
        }
        sharedGestureEvents.eventHandler = { [weak self] event in
            guard let self else { return }
            self.receiveTabbedChooserMouseEvent(event)
            self.receivePaneApplicationMouseEvent(event, feed: "event-tap")
            guard self.appKitWindowGestureFilter.allows(event) else { return }
            self.dragSnap.handleSharedGestureEvent(event)
            self.linkedResize.handleSharedGestureEvent(event)
        }
        sharedGestureEvents.fallbackHandler = { [weak self] in
            self?.setUsesSharedGestureEvents(false)
        }
        system.setWindowEventHandler { [weak self] event in self?.receiveWindowSystemEvent(event) }
        shortcuts.update(bindings: loaded.shortcuts)
        configureSavedLayoutApply()
        savedLayoutActions.didChange = { [weak self] in self?.refreshSavedLayoutActions() }
        shortcuts.namedHandler = { [weak self] in self?.handleSavedLayoutShortcut($0) }
        shortcuts.namedRegistrationChanged = { [weak self] in self?.savedLayoutShortcutFailures = $0 }
        showSavedLayoutChooser = { [weak self] entries in
            SavedLayoutActionMenu.show(entries.map { entry in
                (entry.name, { [weak self] in _ = self?.applySavedLayoutAction(entry.file) })
            })
        }
        layoutWheel.savedLayoutNavigationHandler = { [weak self] command, target in
            self?.navigateSavedLayoutWheel(command, target: target)
        }
        refreshSavedLayoutActions()
        if startRuntime { savedLayoutActions.start() }
        if startRuntime {
            dragSnap.start()
            titleBarDoubleClick.start()
            linkedResize.start()
            layoutWheel.start()
            refreshPermission()
            installWorkspaceTriggers()
            system.startDisplayReconfigurationMonitoring { [weak self] in
                self?.scheduleDisplayRefresh()
            }
            refreshActiveWindows(force: true)

            Task { @MainActor [clock, weak self] in
                try? await clock.sleep(for: .milliseconds(500))
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
        cancelPaneApplicationRequest()
        cancelPendingFocusRestore(on: actionDisplayID())
        refreshActiveWindows(force: false)
        guard let displayID = activeDisplayID else {
            statusMessage = "No display is available."
            return
        }
        let focused = try? system.focusedWindow()
        setMode(mode, on: displayID, focusedWindowID: focused?.displayID == displayID ? focused?.id : nil)
    }

    /// Shared by the menu bar and the captured Layout Wheel desktop.
    private func setMode(_ mode: LayoutMode, on displayID: DisplayID, focusedWindowID: WindowID?) {
        rememberUserActionDisplay(displayID)
        cancelPaneApplicationRequest()
        cancelPendingFocusRestore(on: displayID)
        let mode = mode.availableMode
        sessionStore.ensure(displayID: displayID, defaultMode: configuration.defaultLayoutMode)
        if activeMode(for: displayID) == .tabbed, mode != .tabbed {
            leaveTabbed(displayID: displayID, destination: mode, focusedWindowID: focusedWindowID)
            return
        }
        if mode == .tabbed, let session = sessionStore.session(for: displayID), session.mode != .tabbed {
            tabbedEntryBaselines[session.id] = session
        }
        sessionStore.update(displayID) {
            if $0.mode != .tabbed, mode == .tabbed {
                $0.tabbedBaselineFrames = [:]
                $0.tabbedHasEntryBaseline = false
                $0.resumeAutomaticWrites()
                // From Bento, every pane stays put. Otherwise the tab groups
                // from the last Tabbed visit (if any) come back.
                if $0.mode == .bento, $0.isBentoInitialized, $0.bentoState.root != nil {
                    // Windows Bento floated on its own stay automatic
                    // floats; the entry sweep offers them a pane.
                    $0.tabbedState = TabbedLayoutState(
                        adopting: $0.bentoState, automaticallyFloating: $0.automaticallyFloatingWindowIDs, presentation: configuration.tabbedStripPresentation)
                }
            }
            $0.mode = mode
        }
        if mode == .bento {
            repairBento(displayID: displayID, focusedWindowID: focusedWindowID)
        } else if mode == .tabbed {
            refreshActiveWindows(force: true)
        } else {
            refreshDividerBoundaries()
        }
    }

    func perform(_ action: WindowAction) {
        invalidateMenuPanelFocusReplay()
        if action == .showTabBar { showTabBar(); return }
        let originalDisplayID = actionDisplayID()
        let restoringSession = originalDisplayID.flatMap { focusRestores[$0]?.session }
        cancelPendingFocusRestore(on: originalDisplayID)
        guard !isShutDown else { return }
        guard hasAccessibilityPermission || refreshPermission() else {
            statusMessage = "Accessibility permission is required. Open the Setup Assistant to grant access."
            presentActionResult(
                succeeded: false,
                error: "Accessibility permission is required.",
                displayID: originalDisplayID
            )
            return
        }
        let focusRead = Result { try system.focusedWindow() }
        let focused = (try? focusRead.get()) ?? nil
        let focusedRule = focused.map(rule(for:)) ?? .manageNormally
        if let focused, focused.isEligible, focusedRule.allowsDirectPlacement { rememberUserActionDisplay(focused.displayID) }
        if !focusedRule.allowsDirectPlacement {
            statusMessage = "BetterTile is set to ignore this app."
            presentActionResult(succeeded: false, error: statusMessage, displayID: originalDisplayID)
            return
        }
        if let focused, waitsForSpaceStabilization(focused) {
            statusMessage = Self.tabbedSpaceSwitchPending
            presentActionResult(succeeded: false, error: statusMessage, displayID: focused.displayID)
            return
        }
        if action.isTabCommand {
            if let displayID = focused?.displayID ?? originalDisplayID {
                performTabbedCommand(action, windowID: focused?.id, displayID: displayID)
            }
            return
        }
        if let focused, isTabbedMember(focused.id), !usesTabbedSnap(window: focused) {
            presentLayoutWheelUnavailable(Self.tabbedParticipationChanged, displayID: focused.displayID)
            return
        }
        if let focused, isTabbedMember(focused.id), !BentoDropPlanner.partitionActions.contains(action) {
            presentLayoutWheelUnavailable(tabbedSnapUnavailableReason(action), displayID: focused.displayID)
            return
        }
        if let focused, endBentoFocusForPartition(
            action, window: focused, restoringSession: restoringSession, cyclesShortcut: true
        ) {
            return
        }
        if let focused, let succeeded = performBentoFocusMode(action, window: focused) {
            presentActionResult(succeeded: succeeded, error: statusMessage,
                                successMessage: lastBentoFocusMessage, displayID: focused.displayID)
            return
        }
        let actionPlan: WindowActionPlan
        switch focused.map({ coordinator.plan(action, for: $0.id) }) ?? .unavailable {
        case let .ready(plan):
            actionPlan = plan
        case .unavailable:
            // A front application that stopped answering is named as the
            // reason, not reported as having no window.
            if case let .failure(error) = focusRead {
                statusMessage = error.localizedDescription
            } else {
                statusMessage = "No eligible focused window."
            }
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
        if let succeeded = performBentoDisplayTransfer(actionPlan) {
            presentActionResult(succeeded: succeeded && statusMessage == nil, error: statusMessage,
                                displayID: currentDisplayID(for: actionPlan.windowID) ?? originalDisplayID)
            return
        }
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
        switch command {
        case .savedLayouts, .moreSavedLayouts, .moreLayoutChoices: return .ready(placements: [])
        case let .savedLayout(file, _):
            guard target.windowID != nil || userActionDisplayID != nil else {
                return .unavailable(reason: "Focus an app window to apply a layout.")
            }
            guard savedLayoutActions.entries.contains(where: { $0.file == file }) else {
                return .unavailable(reason: "This Saved Layout could not be opened. Reload the library and try again.")
            }
            // Hover uses the captured focus and cached library. Release resolves focus and readiness again.
            return .ready(placements: [])
        default: break
        }
        switch planLayoutWheel(command, for: target) {
        case let .ready(.action(plan)):
            do {
                if let transfer = try planBentoDisplayTransfer(plan) {
                    return .ready(placements: transfer.destinationPlacements)
                }
            } catch {
                return .unavailable(reason: error.localizedDescription)
            }
            return .ready(placements: [Placement(windowID: plan.windowID, frame: plan.targetFrame)])
        case let .ready(.bento(proposal)):
            return .ready(placements: proposal.plan.placements)
        case let .ready(.tabbed(plan, _, _)):
            return .ready(placements: plan.placements)
        case .ready(.repairBento), .ready(.tabCommand), .ready(.desktop):
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
        switch command {
        case let .savedLayout(file, _): _ = applySavedLayoutAction(file); return
        case .savedLayouts, .moreSavedLayouts, .moreLayoutChoices: navigateSavedLayoutWheel(command, target: target); return
        default: rememberUserActionDisplay(target.displayID)
        }
        performLayoutWheel(command, for: target, cyclesShortcut: false)
    }

    private func performLayoutWheel(
        _ command: LayoutWheelCommand,
        for target: LayoutWheelTarget,
        cyclesShortcut: Bool
    ) {
        invalidateMenuPanelFocusReplay()
        if command == .repairBento,
           repairsAfterFocusRestore(on: target.displayID, { [weak self] in
               self?.performLayoutWheel(command, for: target)
           }) { return }
        let restoringSession = focusRestores[target.displayID]?.session
        cancelPendingFocusRestore(on: target.displayID)
        var outcome = planLayoutWheel(command, for: target, cyclesShortcut: cyclesShortcut)
        if case .ready(.bento(_)) = outcome,
           case let .windowAction(action) = command,
           BentoDropPlanner.partitionActions.contains(action),
           (sessionStore.session(for: target.displayID)?.excludedFocusWindowIDs.isEmpty == false
                || restoringSession?.excludedFocusWindowIDs.isEmpty == false),
           let windowID = target.windowID,
           let window = (try? system.windowSnapshots(ids: [windowID]))?.first {
            if endBentoFocusForPartition(action, window: window, target: target, restoringSession: restoringSession) {
                return
            }
            outcome = planLayoutWheel(command, for: target, cyclesShortcut: cyclesShortcut)
        }
        switch outcome {
        case let .unavailable(reason, displayID):
            statusMessage = reason
            presentActionResult(succeeded: false, error: reason, displayID: displayID)
        case let .ready(.desktop(command)):
            switch command {
            case let .setMode(mode): setMode(mode, on: target.displayID, focusedWindowID: target.windowID)
            case let .chooseLayout(preset): handleTabbed(.preset(preset, grouping: .keepTabGroups), on: target.displayID)
            default: break
            }
        case let .ready(.repairBento(displayID, focusedWindowID)):
            if activeMode(for: displayID) == .tabbed { handleTabbed(.repair, on: displayID) }
            else { repairBento(displayID: displayID, focusedWindowID: focusedWindowID) }
        case let .ready(.tabCommand(action, displayID)):
            performTabbedCommand(action, windowID: target.windowID, displayID: displayID)
        case let .ready(.tabbed(_, action, displayID)):
            guard let windowID = target.windowID else { return }
            performTabbedSnap(action, windowID: windowID, displayID: displayID, expectedSpaceID: target.nativeSpaceID)
        case let .ready(.action(plan)):
            if let window = (try? system.windowSnapshots(ids: [plan.windowID]))?.first,
               let succeeded = performBentoFocusMode(plan.resolvedAction, window: window) {
                presentActionResult(succeeded: succeeded, error: statusMessage,
                                    successMessage: lastBentoFocusMessage, displayID: window.displayID)
                return
            }
            if let succeeded = performBentoDisplayTransfer(plan) {
                presentActionResult(succeeded: succeeded && statusMessage == nil, error: statusMessage,
                                    displayID: currentDisplayID(for: plan.windowID) ?? plan.displayID)
                return
            }
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

    /// Capture once. Grouped also offers desktop commands without a window:
    /// it targets the display under `pointer`, a top-left point from the
    /// wheel controller, else the active display.
    func layoutWheelDidOpen() {
        invalidateMenuPanelFocusReplay()
        shortcuts.suspend()
    }

    func captureLayoutWheelTarget(pointer: BTPoint? = nil) -> LayoutWheelTarget? {
        guard !isShutDown, hasAccessibilityPermission else { return nil }
        do {
            let focused = try system.focusedWindow()
            if let window = focused, window.isEligible, !tabbedExiting.contains(window.displayID),
               !waitsForSpaceStabilization(window), rule(for: window).allowsDirectPlacement,
               let display = system.displays().first(where: { $0.id == window.displayID }) {
                return layoutWheelTarget(windowID: window.id, display: display)
            }
            guard configuration.layoutWheel.style == .grouped, !isStabilizingSpace else { return nil }
            let displays = system.displays()
            guard let display = displays.first(where: { display in pointer.map { display.frame.contains($0) } ?? false })
                ?? displays.first(where: { $0.id == activeDisplayID }) ?? displays.first,
                  !tabbedExiting.contains(display.id) else { return nil }
            sessionStore.ensure(displayID: display.id, defaultMode: configuration.defaultLayoutMode)
            return layoutWheelTarget(windowID: nil, display: display)
        } catch {
            return nil
        }
    }

    private func layoutWheelTarget(windowID: WindowID?, display: DisplaySnapshot) -> LayoutWheelTarget {
        LayoutWheelTarget(windowID: windowID, displayID: display.id, visibleFrame: display.visibleFrame,
            desktopSessionID: sessionStore.session(for: display.id)?.id,
            nativeSpaceID: sessionStore.session(for: display.id)?.nativeSpaceID
                ?? system.refreshNativeDesktopObservation()?.currentSpace(on: display.id),
            layoutMode: sessionStore.session(for: display.id)?.mode ?? configuration.defaultLayoutMode)
    }

    private func planLayoutWheel(
        _ command: LayoutWheelCommand,
        for target: LayoutWheelTarget,
        cyclesShortcut: Bool = false
    ) -> LayoutWheelPlanOutcome {
        guard !isShutDown, !tabbedExiting.contains(target.displayID) else {
            return .unavailable(reason: "The captured desktop is no longer available.", displayID: target.displayID)
        }
        guard hasAccessibilityPermission || refreshPermission(recoverWindows: false) else {
            return .unavailable(
                reason: "Accessibility permission is required.",
                displayID: activeDisplayID
            )
        }

        var capturedWindow: WindowSnapshot?
        if let windowID = target.windowID {
            do {
                guard let window = try system.windowSnapshots(ids: [windowID]).first,
                      window.isEligible, window.displayID == target.displayID else {
                    return .unavailable(reason: "The captured window or display is no longer available.", displayID: target.displayID)
                }
                guard !waitsForSpaceStabilization(window) else {
                    return .unavailable(reason: Self.tabbedSpaceSwitchPending, displayID: target.displayID)
                }
                guard rule(for: window).allowsDirectPlacement else {
                    return .unavailable(reason: "BetterTile is set to ignore this app.", displayID: target.displayID)
                }
                capturedWindow = window
            } catch {
                return .unavailable(reason: error.localizedDescription, displayID: target.displayID)
            }
        }
        guard system.displays().contains(where: { $0.id == target.displayID && $0.visibleFrame == target.visibleFrame }),
              target.desktopSessionID == nil || sessionStore.session(for: target.displayID)?.id == target.desktopSessionID,
              target.layoutMode == nil || (sessionStore.session(for: target.displayID)?.mode ?? configuration.defaultLayoutMode) == target.layoutMode,
              target.nativeSpaceID == nil || (system.refreshNativeDesktopObservation()?.currentSpace(on: target.displayID)
                ?? sessionStore.session(for: target.displayID)?.nativeSpaceID) == target.nativeSpaceID,
              target.windowID != nil || !isStabilizingSpace
        else {
            return .unavailable(reason: "The captured desktop is no longer available.", displayID: target.displayID)
        }
        switch command {
        case .setMode where isStabilizingSpace, .chooseLayout where isStabilizingSpace:
            return .unavailable(reason: Self.tabbedSpaceSwitchPending, displayID: target.displayID)
        case .setMode: return .ready(.desktop(command))
        case .chooseLayout:
            guard activeMode(for: target.displayID) == .tabbed else {
                return .unavailable(reason: "Choose Layout needs a Tabbed desktop.", displayID: target.displayID)
            }
            return .ready(.desktop(command))
        default: break
        }
        guard let window = capturedWindow, let windowID = target.windowID else {
            return .unavailable(reason: "No eligible focused window.", displayID: target.displayID)
        }
        let sourceRule = rule(for: window)
        switch command {
        case .setMode, .chooseLayout, .savedLayouts, .savedLayout, .moreSavedLayouts, .moreLayoutChoices:
            return .ready(.desktop(command))
        case let .windowAction(action):
            if action.isTabCommand {
                guard activeMode(for: window.displayID) == .tabbed else {
                    return .unavailable(reason: Self.tabCommandsUnavailable, displayID: window.displayID)
                }
                return .ready(.tabCommand(action, window.displayID))
            }
            if isTabbedMember(window.id) || (usesTabbedSnap(window: window) && BentoDropPlanner.partitionActions.contains(action)) {
                guard usesTabbedSnap(window: window) else {
                    return .unavailable(reason: Self.tabbedParticipationChanged, displayID: target.displayID)
                }
                guard BentoDropPlanner.partitionActions.contains(action) else {
                    return .unavailable(reason: tabbedSnapUnavailableReason(action), displayID: window.displayID)
                }
                guard let context = tabbedSnapContext(windowID: windowID, displayID: target.displayID),
                      let plan = TabbedSnapPlanner.plan(sourceWindowID: windowID, action: action, scope: .pane,
                          state: context.state, windows: context.windows, in: context.display.visibleFrame)
                else { return .unavailable(reason: Self.tabbedSnapFailure, displayID: target.displayID) }
                return .ready(.tabbed(plan, action, target.displayID))
            }
            let actionPlan: WindowActionPlan
            let planned = cyclesShortcut
                ? coordinator.plan(action, for: windowID)
                : coordinator.planExact(action, for: windowID)
            switch planned {
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
                intent: .snap(action: actionPlan.resolvedAction, frame: actionPlan.targetFrame),
                sourceWindowID: windowID,
                displayID: actionPlan.displayID
            ) else {
                return .unavailable(
                    reason: "That Layout Wheel command cannot satisfy the Adaptive windows' minimum sizes.",
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
            // Same command as the menu and shortcut: it repairs Adaptive and
            // Tabbed, and in Manual places one window or arranges several.
            return .ready(.repairBento(
                displayID: window.displayID,
                focusedWindowID: windowID
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
              let windows = try? observeVisibleWindows()
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
        if case let .snap(action, _) = intent, BentoDropPlanner.partitionActions.contains(action) {
            session.endFollowing()
        }
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
                statusMessage = "The Adaptive session changed before the Layout Wheel command could begin. Try again."
                return false
            }
            session = resumed
        }

        let requestedFrames = Dictionary(
            uniqueKeysWithValues: proposal.plan.placements.map { ($0.windowID, $0.frame) }
        )
        session.bentoState = proposal.plan.state
        // Focus mode keeps the previous tree, so its remembered layouts stay.
        if !proposal.plan.isFocusDrop { session.forgetRememberedBentoLayouts() }
        session.isBentoInitialized = true
        session.windowIDs = Set(proposal.displayWindows.map(\.id))
        session.recordProposedFrames(requestedFrames)
        session.lastWorkArea = proposal.display.visibleFrame

        if proposal.plan.isFocusDrop {
            guard let placement = proposal.plan.placements.first,
                  let sourceFrame = proposal.baselineFrames[proposal.sourceWindowID]
            else {
                statusMessage = "That Layout Wheel command could not form a valid Adaptive placement."
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
                        sessionID: session.id,
                        error: reason,
                        surfaceFailure: false
                    )
                }
                return false
            }
            session.excludedFocusWindowIDs.formUnion(proposal.plan.excludedWindowIDs)
            session.excludedFocusWindowIDs.remove(proposal.sourceWindowID)
            guard sessionStore.commit(session, replacing: session.revision) != nil else {
                statusMessage = "The Adaptive layout changed while the Layout Wheel command was finishing. Try again."
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
                    sessionID: session.id,
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

    /// Plans copies of both sessions so preview and commit use the same panes.
    private func planBentoDisplayTransfer(_ actionPlan: WindowActionPlan) throws -> BentoDisplayTransferProposal? {
        guard actionPlan.resolvedAction.isDisplayTransfer,
              var source = sessionStore.session(for: actionPlan.displayID), source.mode != .tabbed,
              let sourceDisplay = system.displays().first(where: { $0.id == source.displayID }),
              let destinationDisplay = system.displays().first(where: {
                  $0.id != source.displayID && PlacementBounds.isContained(actionPlan.targetFrame, in: $0.visibleFrame)
              }),
              var destination = sessionStore.session(for: destinationDisplay.id), destination.mode != .tabbed,
              source.mode == .bento || destination.mode == .bento,
              system.nativeDesktopObservation()?.allowsAutomaticLayout(on: destinationDisplay.id) != false
        else { return nil }
        let windows = try observeVisibleWindows()
        let eligible = bentoEligible(windows.filter { $0.isEligible && !$0.isFloating })
        guard var moved = eligible.first(where: { $0.id == actionPlan.windowID && $0.displayID == source.displayID })
        else { return nil }
        guard !waitsForSpaceStabilization(moved) else {
            throw WindowSystemError.operationFailed(Self.tabbedSpaceSwitchPending)
        }
        source.resumeAutomaticWrites()
        destination.resumeAutomaticWrites()
        let sourceWindows = eligible.filter { $0.displayID == source.displayID && $0.id != moved.id }
        var destinationWindows = eligible.filter { $0.displayID == destination.displayID }
        if source.mode == .bento {
            reconcileBentoSession(&source, windows: sourceWindows, display: sourceDisplay, confirmedGone: [moved.id])
        }
        if destination.mode == .bento {
            reconcileBentoSession(&destination, windows: destinationWindows, display: destinationDisplay)
        }
        moved.displayID = destination.displayID
        moved.frame = actionPlan.targetFrame
        destinationWindows.append(moved)
        var floatingMessage: String?
        var floats = false
        if destination.mode == .bento {
            let insertion = BentoPlanner(newWindowSide: configuration.bentoNewWindowSide,
                                         balancesNewWindows: configuration.bentoBalancesNewWindows).plan(
                state: BentoRuntimeState(layout: destination.bentoState, reinsertionAnchors: destination.bentoReinsertionAnchors),
                observation: BentoObservation(bounds: destinationDisplay.visibleFrame, windows: destinationWindows,
                                              focusedWindowID: destination.focusedWindowID),
                intent: .insert(moved.id), followed: destination.followed)
            switch insertion.pill {
            case let .overflow(message):
                destination.bentoState = insertion.state.layout
                floatingMessage = message
            case .failure:
                destination.bentoState.setFloating(true, windowID: moved.id)
                floatingMessage = "Some windows are floating because their minimum sizes do not fit this display."
            default:
                destination.bentoState = insertion.state.layout
                floatingMessage = nil
            }
            floats = destination.bentoState.floatingWindowIDs.contains(moved.id)
            if floats { destination.automaticallyFloatingWindowIDs.insert(moved.id) }
            else { destination.automaticallyFloatingWindowIDs.remove(moved.id) }
        }
        var sourcePlacements = source.mode == .bento
            ? BentoLayoutEngine(state: source.bentoState).placements(for: sourceWindows, in: sourceDisplay) : []
        if source.mode == .bento, source.shouldApplySingleWindowPlacement(eligibleWindowCount: sourceWindows.count),
           let lone = sourceWindows.first {
            let frame = configuration.singleWindowPlacement.flatMap {
                StandardActionEngine().targetFrame(for: $0, window: lone, display: sourceDisplay)
            } ?? lone.frame
            sourcePlacements = [Placement(windowID: lone.id, frame: frame)]
        }
        var destinationPlacements = destination.mode == .bento
            ? BentoLayoutEngine(state: destination.bentoState).placements(for: destinationWindows, in: destinationDisplay)
            : [Placement(windowID: moved.id, frame: moved.frame)]
        if floats {
            let frame = moved.frame.clamped(to: destinationDisplay.visibleFrame, minimumSize: moved.constraints.minimumSize)
            destinationPlacements.append(Placement(windowID: moved.id, frame: frame))
        } else if destination.mode == .bento, destination.shouldApplySingleWindowPlacement(eligibleWindowCount: destinationWindows.count) {
            let frame = configuration.singleWindowPlacement.flatMap {
                StandardActionEngine().targetFrame(for: $0, window: moved, display: destinationDisplay)
            } ?? moved.frame
            destinationPlacements = [Placement(windowID: moved.id, frame: frame)]
        }
        guard bentoProposalIsContained(sourcePlacements, in: sourceDisplay),
              bentoProposalIsContained(destinationPlacements, in: destinationDisplay) else {
            throw WindowSystemError.operationFailed("That layout would have placed a window outside the screen area.")
        }
        source.windowIDs = Set(sourceWindows.map(\.id))
        source.focusedWindowID = nil
        source.lastObservedFrames = Dictionary(uniqueKeysWithValues: sourceWindows.map { ($0.id, $0.frame) })
        destination.windowIDs = Set(destinationWindows.map(\.id))
        destination.focusedWindowID = moved.id
        if destination.mode == .bento, !destination.bentoInsertionOrder.contains(moved.id) { destination.bentoInsertionOrder.append(moved.id) }
        for (display, proposed, frames) in [(sourceDisplay, source, sourcePlacements),
                                           (destinationDisplay, destination, destinationPlacements)] {
            var session = proposed
            if session.mode == .bento {
                session.isBentoInitialized = true
                session.forgetRememberedBentoLayouts()
            }
            session.recordProposedFrames(Dictionary(uniqueKeysWithValues: frames.map { ($0.windowID, $0.frame) }))
            session.lastWorkArea = display.visibleFrame
            if display.id == source.displayID { source = session } else { destination = session }
        }
        return BentoDisplayTransferProposal(source: source, destination: destination,
            sourceDisplay: sourceDisplay, destinationDisplay: destinationDisplay,
            sourcePlacements: sourcePlacements, destinationPlacements: destinationPlacements,
            windows: windows, floats: floats, floatingMessage: floatingMessage)
    }

    /// The shortcut owns both layouts; AX callbacks must not discover the move
    /// after a normalized single-window frame has already covered a neighbour.
    private func performBentoDisplayTransfer(_ actionPlan: WindowActionPlan) -> Bool? {
        do {
            let generation = spaceStabilizationGeneration
            let nativeObservation = system.nativeDesktopObservation()
            guard let proposal = try planBentoDisplayTransfer(actionPlan) else { return nil }
            let source = proposal.source, destination = proposal.destination
            let sourceDisplay = proposal.sourceDisplay, destinationDisplay = proposal.destinationDisplay
            let sourcePlacements = proposal.sourcePlacements, destinationPlacements = proposal.destinationPlacements
            let placements = sourcePlacements + destinationPlacements
            let isTransferCurrent = { @MainActor in
                let observation = self.system.refreshNativeDesktopObservation()
                let displays = self.system.displays()
                return !self.isShutDown && self.hasAccessibilityPermission && !self.isStabilizingSpace
                    && self.spaceStabilizationGeneration == generation
                    && (observation == nil) == (nativeObservation == nil)
                    && [source, destination].allSatisfy { session in
                        self.sessionStore.isCurrent(session.id, revision: session.revision, on: session.displayID)
                            && observation?.allowsAutomaticLayout(on: session.displayID) != false
                            && observation?.currentSpace(on: session.displayID) == nativeObservation?.currentSpace(on: session.displayID)
                            && (session.nativeSpaceID == nil || observation?.currentSpace(on: session.displayID) == session.nativeSpaceID)
                    }
                    && [sourceDisplay, destinationDisplay].allSatisfy { planned in
                        displays.contains { $0.id == planned.id && $0.visibleFrame == planned.visibleFrame }
                    }
            }
            guard isTransferCurrent() else {
                statusMessage = "The Adaptive layout changed before this update could finish. Try again."
                return false
            }
            var transaction: WindowFrameTransaction
            switch coordinator.beginTransaction(windowIDs: Set(placements.map(\.windowID))) {
            case let .failed(reason): statusMessage = reason; return false
            case let .started(started): transaction = started
            }
            let outcome = coordinator.commit(transaction: &transaction, placements: placements, recordHistory: false,
                destination: DropDestination(displayID: destinationDisplay.id, sourceWindowID: actionPlan.windowID),
                isDisplayTransfer: true, revalidateBeforeEachWrite: true, validating: isTransferCurrent)
            guard outcome.isApplied else {
                statusMessage = outcome.failureReason
                if case let .degraded(reason) = outcome {
                    suspendDisplayTransferOwners(source, destination, error: reason)
                }
                return false
            }
            // Stage both compare-and-swap replacements before publishing either.
            var updatedStore = sessionStore
            guard updatedStore.commit(source, replacing: source.revision) != nil,
                  updatedStore.commit(destination, replacing: destination.revision) != nil else {
                let rollback = coordinator.restoreBaseline(of: transaction)
                statusMessage = "The Adaptive layout changed while macOS was applying it. Try again."
                if case let .degraded(reason) = rollback {
                    suspendDisplayTransferOwners(source, destination, error: reason)
                }
                return false
            }
            sessionStore = updatedStore
            coordinator.recordHistory(of: transaction)
            rememberUserActionDisplay(destination.displayID)
            var transferOwners = Dictionary(uniqueKeysWithValues: [source, destination].compactMap { owner in
                sessionStore.session(for: owner.displayID).map { (owner.displayID, $0) }
            })
            // Only a successful commit from these settlement tasks advances an
            // expected revision. A user action or unrelated sweep still invalidates it.
            let didSettleTransferOwner = { @MainActor (settled: LayoutSession) in
                guard let owner = transferOwners[settled.displayID], owner.id == settled.id,
                      owner.mode == settled.mode, owner.nativeSpaceID == settled.nativeSpaceID else { return }
                transferOwners[settled.displayID] = settled
            }
            let transferIsCurrent = { @MainActor [weak self] in
                guard let self else { return false }
                let observation = self.system.refreshNativeDesktopObservation()
                return transferOwners.values.allSatisfy { owner in
                    self.sessionStore.isCurrent(owner.id, revision: owner.revision, on: owner.displayID)
                        && self.sessionStore.session(for: owner.displayID)?.mode == owner.mode
                        && observation?.allowsAutomaticLayout(on: owner.displayID) != false
                        && observation?.currentSpace(on: owner.displayID) == nativeObservation?.currentSpace(on: owner.displayID)
                } && (observation == nil) == (nativeObservation == nil)
                    && [sourceDisplay, destinationDisplay].allSatisfy { planned in
                        self.system.displays().contains { $0.id == planned.id && $0.visibleFrame == planned.visibleFrame }
                    }
            }
            let didDegradeTransfer: @MainActor (String) -> Void = { [weak self] reason in
                self?.suspendDisplayTransferOwners(source, destination, error: reason, surfaceFailure: true)
            }
            for (display, frames) in [(sourceDisplay, sourcePlacements), (destinationDisplay, destinationPlacements)]
                where sessionStore.session(for: display.id)?.mode == .bento {
                scheduleBentoSettlement(displayID: display.id, changedWindowIDs: Set(frames.map(\.windowID)),
                    requestedFrames: Dictionary(uniqueKeysWithValues: frames.map { ($0.windowID, $0.frame) }),
                    baselineFrames: transaction.baselineFrames, isAuthoritative: true, revalidateBeforeEachWrite: true,
                    didCommitSettlement: didSettleTransferOwner, didDegradeSettlement: didDegradeTransfer, validating: transferIsCurrent)
            }
            statusMessage = proposal.floatingMessage
            refreshDividerBoundaries()
            return true
        } catch {
            statusMessage = error.localizedDescription
            return false
        }
    }

    private func suspendDisplayTransferOwners(
        _ source: LayoutSession, _ destination: LayoutSession, error: String, surfaceFailure: Bool = false
    ) {
        for session in [source, destination] {
            suspendAutomaticBentoWrites(displayID: session.displayID, sessionID: session.id,
                                        error: error, surfaceFailure: false)
        }
        statusMessage = error + " Use Repair Layout on both affected desktops to rebuild their layouts."
        if surfaceFailure {
            presentActionResult(succeeded: false, error: statusMessage, displayID: destination.displayID)
        }
    }

    private func performBentoAction(_ actionPlan: WindowActionPlan) -> Bool {
        guard var session = sessionStore.session(for: actionPlan.displayID),
              let display = system.displays().first(where: { $0.id == actionPlan.displayID }),
              let windows = try? observeVisibleWindows()
        else { return false }
        // An explicit shortcut is a new user-owned transaction and therefore
        // clears a scoped recovery stop for this desktop.
        if session.automaticWritesSuspended {
            session.resumeAutomaticWrites()
            guard let resumed = sessionStore.commit(session, replacing: session.revision) else {
                statusMessage = "The Adaptive session changed before the shortcut could begin. Try again."
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
            statusMessage = "That shortcut cannot satisfy the Adaptive windows’ minimum sizes."
            return false
        }
        let requestedFrames = Dictionary(uniqueKeysWithValues: plan.placements.map { ($0.windowID, $0.frame) })
        session.bentoState = plan.state
        if BentoDropPlanner.partitionActions.contains(actionPlan.resolvedAction) { session.endFollowing() }
        session.forgetRememberedBentoLayouts()
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
                    sessionID: session.id,
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
        let repairDisplayID = actionDisplayID()
        if repairsAfterFocusRestore(on: repairDisplayID, { [weak self] in self?.tileCurrentDisplay() }) { return }
        cancelPendingFocusRestore(on: repairDisplayID)
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

    private func repairBento(displayID: DisplayID, focusedWindowID: WindowID?) {
        // Repair during Focus mode ends it: the covered peers come back and the
        // previous layout returns, instead of forgetting the minimized peers.
        // Repair then verifies that layout and reports, so success is never
        // shown before the windows are read back.
        if let focusedWindowID,
           sessionStore.session(for: displayID)?.excludedFocusWindowIDs.isEmpty == false,
           let focused = (try? system.windowSnapshots(ids: [focusedWindowID]))?.first,
           let succeeded = performBentoFocusMode(.restore, window: focused, afterRestore: { [weak self] in
               self?.repairBento(displayID: displayID, focusedWindowID: focusedWindowID)
           }) {
            if !succeeded { presentActionResult(succeeded: false, error: statusMessage, displayID: displayID) }
            return
        }
        do {
            let observedWindows = try observeVisibleWindows()
            let nativeObservation = system.nativeDesktopObservation()
            let windows = (nativeObservation?.windowsOnCurrentSpaces(observedWindows) ?? observedWindows)
                .filter { $0.isEligible && !$0.isFloating }
            let focused = try focusedWindowID.flatMap { try system.windowSnapshots(ids: [$0]).first }
            guard let display = system.displays().first(where: { $0.id == displayID }),
                  focusedWindowID == nil || (focused?.isEligible == true && focused?.displayID == displayID) else {
                statusMessage = "The captured window or display is no longer available."
                presentActionResult(succeeded: false, error: statusMessage, displayID: displayID)
                return
            }
            let displayWindows = bentoEligible(windows.filter { $0.displayID == display.id })
            guard !displayWindows.isEmpty else {
                // A display-only Mode command is valid on an empty desktop.
                statusMessage = focusedWindowID == nil ? nil : "No eligible visible windows on the active display."
                refreshDividerBoundaries()
                presentActionResult(succeeded: statusMessage == nil, error: statusMessage, displayID: display.id)
                return
            }
            let repairWindowID = focusedWindowID ?? displayWindows.first?.id
            if var current = sessionStore.session(for: display.id),
               current.automaticWritesSuspended {
                current.resumeAutomaticWrites()
                _ = sessionStore.commit(current, replacing: current.revision)
            }
            var session = sessionStore.activate(
                displayID: display.id,
                windowIDs: Set(displayWindows.map(\.id)),
                focusedWindowID: repairWindowID,
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
            session.bentoState.metrics = BentoLayoutMetrics(paneGap: paneGapForLayout)
            var placements: [Placement]
            if displayWindows.count <= 6 {
                let result = BentoPlanner().plan(
                    state: BentoRuntimeState(
                        layout: session.bentoState,
                        reinsertionAnchors: session.bentoReinsertionAnchors
                    ),
                    observation: BentoObservation(
                        bounds: display.visibleFrame,
                        windows: displayWindows,
                        focusedWindowID: repairWindowID
                    ),
                    intent: .retile
                )
                guard result.writesFrames, !result.placements.isEmpty else {
                    statusMessage = "The visible windows cannot form a valid Adaptive layout."
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
            var applied = commitResult.result == .committed
            var failureReason = commitResult.failureReason
            var overlapping: Set<WindowID> = []
            var verified = true
            if applied {
                // Each write reads the real size back, so a refused size is
                // measured now. Verify the frames the windows took; if any
                // overlap, plan once more with the measured minimums.
                for pass in 0..<2 {
                    let ids = Set(placements.map(\.windowID))
                    // Success needs every placed window read back.
                    guard let actual = try? system.windowSnapshots(ids: ids), Set(actual.map(\.id)) == ids else {
                        verified = false
                        break
                    }
                    overlapping = BentoLayoutVerifier.overlappingWindowIDs(
                        Dictionary(uniqueKeysWithValues: actual.map { ($0.id, $0.frame) }))
                    guard !overlapping.isEmpty, pass == 0, displayWindows.count <= 6 else { break }
                    let replanned = BentoPlanner().plan(
                        state: BentoRuntimeState(layout: session.bentoState,
                                                 reinsertionAnchors: session.bentoReinsertionAnchors),
                        observation: BentoObservation(bounds: display.visibleFrame, windows: actual,
                                                      focusedWindowID: repairWindowID),
                        intent: .retile
                    )
                    guard replanned.writesFrames, !replanned.placements.isEmpty else { break }
                    session.bentoState = replanned.state.layout
                    session.lastObservedFrames = Dictionary(uniqueKeysWithValues: replanned.placements.map { ($0.windowID, $0.frame) })
                    placements = replanned.placements
                    let replan = commitBentoProposal(placements, session: &session, display: display,
                                                     recordHistory: false, surfaceFailure: false)
                    applied = replan.result == .committed
                    if !applied { failureReason = replan.failureReason; break }
                }
            }
            if applied {
                scheduleBentoSettlement(
                    displayID: display.id,
                    changedWindowIDs: Set(placements.map(\.windowID)),
                    requestedFrames: Dictionary(uniqueKeysWithValues: placements.map { ($0.windowID, $0.frame) }),
                    baselineFrames: Dictionary(uniqueKeysWithValues: displayWindows.map { ($0.id, $0.frame) }),
                    isAuthoritative: true
                )
            }
            let overlapNames = displayWindows.filter { overlapping.contains($0.id) }
                .map { $0.title.isEmpty ? ($0.bundleIdentifier ?? "A window") : $0.title }.sorted()
            statusMessage = if !applied {
                failureReason ?? "The Adaptive layout could not be repaired."
            } else if !verified {
                "BetterTile could not read the repaired windows back to confirm the layout."
            } else if displayWindows.count > 6 {
                "Adaptive manages up to six windows. The others stay floating."
            } else if !overlapNames.isEmpty {
                Self.overlapMessage(overlapNames)
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
        if session.mode == .bento {
            // A returning pane must rebuild after Repair placed the lone visible window.
            session.bentoState = BentoLayoutState(metrics: session.bentoState.metrics)
            session.isBentoInitialized = false
        }
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
        if commitResult.result == .degraded {
            suspendAutomaticBentoWrites(
                displayID: display.id, sessionID: session.id,
                error: commitResult.failureReason ?? "The window could not be restored.",
                surfaceFailure: false
            )
        } else {
            statusMessage = applied ? nil : (commitResult.failureReason ?? "The window could not be placed.")
        }
        presentActionResult(succeeded: applied, error: statusMessage, displayID: display.id)
        refreshDividerBoundaries()
    }

    func beginBentoDrag(displayID: DisplayID, sourceID: WindowID, sourceFrame: BTRect? = nil) -> Bool {
        invalidateMenuPanelFocusReplay()
        cancelPendingFocusRestore(on: displayID)
        guard activeBentoDrag == nil, !tabbedExiting.contains(displayID),
              var layoutSession = sessionStore.session(for: displayID),
              layoutSession.mode == .bento || layoutSession.mode == .tabbed,
              let display = system.displays().first(where: { $0.id == displayID }),
              let windows = try? observeVisibleWindows()
        else { return false }
        // Dragging one tab of a group moves only that window.
        cancelPaneApplicationRequest()
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
        tabbedQueuedIntents.removeValue(forKey: displayID)
        let droppedTabbedReapply = tabbedNeedsReapply.remove(displayID) != nil
        tabbedNeedsRefresh.remove(displayID)
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
            tabbedWindows: bentoEligible(windows.filter { $0.displayID == displayID && $0.isEligible && !$0.isFloating }),
            droppedTabbedReapply: droppedTabbedReapply
        )
        tabbedOverlays[displayID]?.acceptsTabDrags = false
        dividerResize.refresh(boundaries: [])
        return true
    }

    private static let bentoDropMinimumFailure = "That Adaptive drop cannot satisfy the windows’ minimum sizes."
    private static let dropLayoutChanged = "The layout changed during the drag. Try again."
    private static let minimumSizeDoesNotFitSnap = "The window’s minimum size does not fit in that snap area."

    /// Whether the desktop a drag froze is still the one its drop would
    /// change: the same layout session and revision, mode, Space, and work
    /// area. A drop on a changed desktop must write nothing.
    private func dragDesktopIsCurrent(_ active: ActiveBentoDrag, displayID: DisplayID) -> Bool {
        guard let session = sessionStore.session(for: displayID),
              session.id == active.layoutSession.id, session.revision == active.layoutSession.revision,
              session.mode == active.layoutSession.mode,
              system.displays().first(where: { $0.id == displayID })?.visibleFrame == active.session.workArea
        else { return false }
        // An unavailable observation cannot show a Space change.
        guard let space = active.tabbedSpaceID,
              let current = system.refreshNativeDesktopObservation()?.currentSpace(on: displayID) else { return true }
        return current == space
    }

    /// Plans a drop for the drag overlay. Release commits this plan as it is;
    /// it never plans the drop again. Nil means the drag is not current.
    func previewBentoDrag(
        displayID: DisplayID,
        sourceID: WindowID,
        outcome: BentoDragOutcome
    ) -> LayoutDropPreview? {
        guard let active = activeBentoDrag,
              active.session.displayID == displayID,
              active.session.sourceWindowID == sourceID
        else { return nil }
        let dragID = active.transaction.id
        // In Tabbed, a center, tab strip, or empty pane drop adds the window
        // to that pane as its selected tab. The panes are fitted now, so
        // release moves no divider the overlay did not show. A window the
        // pane cannot show is invalid feedback: it never joins as a hidden
        // tab, which its application could bring in front of other panes.
        if active.layoutSession.mode == .tabbed, outcome.addsTab {
            guard let session = sessionStore.session(for: displayID),
                  session.id == active.layoutSession.id, session.revision == active.layoutSession.revision,
                  var state = session.tabbedState, let drop = state.tabDrop(for: outcome)
            else { return .invalid(reason: Self.dropLayoutChanged) }
            state.move(sourceID, to: drop.paneID, at: drop.index)
            let workArea = active.session.workArea, windows = active.tabbedWindows
            do {
                let fitted = try fittedTabbedState(state, in: workArea, windows: windows, focus: sourceID)
                return .ready(PreparedLayoutDrop(outcome: outcome, placements: [], plan: .tabbed(fitted), dragID: dragID))
            } catch {
                guard let tooWide = state.fitFailure(showing: sourceID, in: workArea, windows: windows)?.tooWide,
                      let source = windows.first(where: { $0.id == sourceID })
                else { return .invalid(reason: error.localizedDescription) }
                return .invalid(reason: "\(Self.displayName(of: source)) is too \(tooWide ? "wide" : "tall") for this pane")
            }
        }
        if active.layoutSession.mode == .tabbed, case let .snap(action, frame) = outcome {
            guard let baseline = active.tabbedUndoBaseline,
                  sessionStore.isCurrent(active.layoutSession.id, revision: active.layoutSession.revision, on: displayID),
                  system.displays().first(where: { $0.id == displayID })?.visibleFrame == active.session.workArea,
                  active.tabbedSpaceID == nil || system.nativeDesktopObservation()?.currentSpace(on: displayID) == active.tabbedSpaceID
            else { return .invalid(reason: Self.dropLayoutChanged) }
            // A floating source takes the snap area's frame, which the drag
            // computed on the display under the pointer, if it can hold the
            // window's minimum size.
            if baseline.floatingWindowIDs.contains(sourceID), !BentoDropPlanner.partitionActions.contains(action) {
                if let constraints = active.session.constraints[sourceID], constraints.isResizable,
                   !SnapFrameFit.holds(frame, minimumSize: constraints.minimumSize) {
                    return .invalid(reason: Self.minimumSizeDoesNotFitSnap)
                }
                return .ready(PreparedLayoutDrop(outcome: outcome, placements: [Placement(windowID: sourceID, frame: frame)],
                                                 plan: .frame, dragID: dragID))
            }
            guard let plan = TabbedSnapPlanner.plan(sourceWindowID: sourceID, action: action, scope: .window, state: baseline,
                      windows: active.tabbedWindows, in: active.session.workArea),
                  plan.preservesTarget(in: plan.state, within: active.session.workArea)
            else {
                return .invalid(reason: BentoDropPlanner.partitionActions.contains(action)
                    ? Self.tabbedSnapFailure : tabbedSnapUnavailableReason(action))
            }
            return .ready(PreparedLayoutDrop(outcome: outcome, placements: plan.placements,
                                             plan: .tabbed(plan.state), dragID: dragID))
        }
        let intent: BentoDropIntent? = switch outcome {
        case let .swap(targetWindowID): .pane(targetWindowID)
        case let .insert(targetWindowID, edge): .insert(targetWindowID: targetWindowID, edge: edge)
        case let .snap(action, frame): .snap(action: action, frame: frame)
        case .tab, .restore: nil
        }
        guard let intent else { return nil }
        guard let plan = BentoDropPlanner().plan(
            intent: intent,
            sourceWindowID: sourceID,
            state: active.session.originalState,
            baselineFrames: active.session.baselineFrames,
            constraints: active.session.constraints,
            contextWindowIDs: active.session.contextWindowIDs,
            in: active.session.workArea
        ) else { return .invalid(reason: Self.bentoDropMinimumFailure) }
        return .ready(PreparedLayoutDrop(outcome: outcome, placements: plan.placements, plan: .bento(plan), dragID: dragID))
    }

    /// Ends a drag with a known outcome, planned as the overlay plans it.
    /// Tests use this seam; the live path ends with the overlay's plan.
    func finishBentoDrag(displayID: DisplayID, sourceID: WindowID, outcome: BentoDragOutcome) {
        let end: LayoutDragEnd
        if outcome == .restore {
            end = .restore
        } else {
            switch previewBentoDrag(displayID: displayID, sourceID: sourceID, outcome: outcome) {
            case let .ready(prepared): end = .commit(prepared)
            case let .invalid(reason): end = .failed(reason: reason)
            case nil: return
            }
        }
        finishBentoDrag(displayID: displayID, sourceID: sourceID, end: end)
    }

    /// Commits the plan the drag overlay showed, or restores the window.
    func finishBentoDrag(displayID: DisplayID, sourceID: WindowID, end: LayoutDragEnd) {
        guard var active = activeBentoDrag,
              active.session.displayID == displayID,
              active.session.sourceWindowID == sourceID
        else { return }
        defer {
            if activeBentoDrag == nil, !isTabbedBusy(on: displayID) {
                drainTabbedQueuedIntent(on: displayID, sessionID: active.layoutSession.id)
                if !isTabbedBusy(on: displayID), tabbedQueuedIntents[displayID] == nil {
                    tabbedOverlays[displayID]?.completeDrop()
                    tabbedOverlays[displayID]?.acceptsTabDrags = true
                }
            }
        }

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
                self.finishBentoDrag(displayID: displayID, sourceID: sourceID, end: end)
            }
            return
        }
        var end = end
        let desktopChanged = !dragDesktopIsCurrent(active, displayID: displayID)
        if case let .commit(prepared) = end, prepared.dragID != active.transaction.id || desktopChanged {
            // A plan from another drag, or for a desktop that changed since
            // the overlay showed it, is not this drop. Nothing is written but
            // the dragged window's return.
            end = .failed(reason: Self.dropLayoutChanged)
        }
        if desktopChanged {
            // The slot and checkpoint from before the drag are gone, whatever
            // the release showed: the window takes its slot in the current
            // layout, and one pill at most explains a failed drop.
            _ = coordinator.cancel(transaction: active.transaction)
            let failurePresented = returnDraggedWindowToCurrentLayout(active, sourceID: sourceID, displayID: displayID)
            if case let .failed(reason) = end, !failurePresented {
                statusMessage = reason
                presentActionResult(succeeded: false, error: reason, displayID: displayID)
            }
            activeBentoDrag = nil
            replayBufferedBentoDragEvents()
            refreshDividerBoundaries()
            return
        }
        if case let .failed(reason) = end, active.layoutSession.mode == .tabbed,
           let baseline = active.tabbedUndoBaseline, !baseline.floatingWindowIDs.contains(sourceID),
           let session = sessionStore.session(for: displayID),
           session.id == active.layoutSession.id, session.revision == active.layoutSession.revision,
           let display = system.displays().first(where: { $0.id == displayID && $0.visibleFrame == active.session.workArea }) {
            // Invalid feedback applies nothing. Tabbed restores its verified
            // checkpoint and original membership, and the pill says why. A
            // floating window has no slot and takes the path below.
            _ = coordinator.cancel(transaction: active.transaction)
            activeBentoDrag = nil
            applyTabbedState(baseline, session: session, display: display, windows: active.tabbedWindows,
                focus: nil, rollbackFrames: active.tabbedRollbackFrames, gestureBaseline: baseline,
                gestureSourceID: sourceID, expectedSpaceID: active.tabbedSpaceID, rejection: reason)
            replayBufferedBentoDragEvents()
            refreshDividerBoundaries()
            return
        }
        if case let .failed(reason) = end {
            // Invalid feedback applies nothing. A tiled window returns to its
            // slot, a floating one stays where it was dropped, and the pill
            // says why.
            statusMessage = reason
            if active.tabbedOrigin != nil {
                _ = finishTabbedDrop(active, sourceID: sourceID, end: .restore)
            }
            if !restoreBentoDragIfNeeded(active.session) {
                presentActionResult(succeeded: false, error: reason, displayID: displayID)
            }
            activeBentoDrag = nil
            replayBufferedBentoDragEvents()
            refreshDividerBoundaries()
            return
        }
        if active.layoutSession.mode == .tabbed, case let .commit(prepared) = end,
           case let .snap(action, _) = prepared.outcome {
            _ = coordinator.cancel(transaction: active.transaction)
            activeBentoDrag = nil
            if let baseline = active.tabbedUndoBaseline,
               let context = tabbedSnapContext(windowID: sourceID, displayID: displayID, draggedWindowID: sourceID),
               context.session.id == active.layoutSession.id,
               context.session.revision == active.layoutSession.revision,
               context.display.visibleFrame == active.session.workArea,
               active.tabbedSpaceID == nil || system.refreshNativeDesktopObservation()?.currentSpace(on: displayID) == active.tabbedSpaceID {
                // The frame the preview showed, from the display under the
                // pointer; never planned again on the window's own display.
                if case .frame = prepared.plan, let frame = prepared.placements.first?.frame,
                   let before = active.tabbedRollbackFrames[sourceID] {
                    let placement = WindowPlacementPlan(windowID: sourceID, displayID: displayID,
                        sourceFrame: before, targetFrame: frame)
                    let outcome = coordinator.perform(placement)
                    presentActionResult(succeeded: outcome.isApplied, error: outcome.failureReason, displayID: displayID)
                    if outcome.isApplied { verifyPlacementLanded(placement, displayID: displayID) }
                } else {
                    applyTabbedState(baseline, session: context.session, display: context.display,
                        windows: context.windows, focus: sourceID, rememberUndo: true,
                        rollbackFrames: active.tabbedRollbackFrames, snapAction: action, snapScope: .window,
                        preparedDrop: prepared.tabbedState.map { PreparedTabbedArrangement(state: $0, windows: active.tabbedWindows) },
                        gestureBaseline: baseline, gestureSourceID: sourceID, expectedSpaceID: active.tabbedSpaceID)
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
                    snapAction: action, snapScope: .window,
                    preparedDrop: prepared.tabbedState.map { PreparedTabbedArrangement(state: $0, windows: active.tabbedWindows) },
                    gestureBaseline: baseline, gestureSourceID: sourceID,
                    expectedSpaceID: active.tabbedSpaceID)
            }
            replayBufferedBentoDragEvents()
            refreshDividerBoundaries()
            return
        }
        if active.layoutSession.mode == .tabbed, finishTabbedDrop(active, sourceID: sourceID, end: end) {
            activeBentoDrag = nil
            replayBufferedBentoDragEvents()
            refreshDividerBoundaries()
            return
        }
        var committed = false
        var frameTransactionCommitted = false
        var recoveryFailurePresented = false
        let isDrop: Bool
        let plannedDrop: BentoDropPlan?
        switch end {
        case let .commit(prepared):
            isDrop = true
            plannedDrop = prepared.bentoPlan
        case .restore, .failed:
            // Only a drop the overlay showed changes the layout. A floating
            // window released or cancelled without one stays floating.
            isDrop = false
            plannedDrop = nil
        }
        // The drop lands on the display the overlay showed it on. The source's
        // center can be on the neighbouring display by now. Each window is
        // checked against the minimum size the overlay planned it with.
        let destination = DropDestination(displayID: displayID, sourceWindowID: sourceID,
                                          minimumSizes: active.session.constraints.mapValues(\.minimumSize))
        if isDrop {
            guard let plan = plannedDrop else {
                statusMessage = Self.bentoDropMinimumFailure
                if active.tabbedOrigin != nil {
                    _ = finishTabbedDrop(active, sourceID: sourceID, end: .restore)
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
                    sourceBaselineFrame: baseline,
                    destination: destination
                )
            } else {
                dropOutcome = coordinator.commit(
                    transaction: &active.transaction,
                    placements: plan.placements,
                    recordHistory: true,
                    destination: destination
                )
            }
            committed = dropOutcome.isApplied
            frameTransactionCommitted = committed
            if case let .degraded(reason) = dropOutcome {
                frameTransactionCommitted = true
                recoveryFailurePresented = true
                suspendAutomaticBentoWrites(
                    displayID: displayID,
                    sessionID: active.layoutSession.id,
                    error: reason
                )
            }
            if committed {
                var proposed = active.layoutSession
                proposed.bentoState = plan.state
                if case let .commit(prepared) = end, case let .snap(action, _) = prepared.outcome,
                   BentoDropPlanner.partitionActions.contains(action) { proposed.endFollowing() }
                if !plan.isFocusDrop { proposed.forgetRememberedBentoLayouts() }
                // A window that refused its new pane is measured by this
                // write; solve again now, so the correction lands with the
                // drop instead of half a second later from settlement.
                var placements = plan.placements
                var correctionDegraded = false
                if !plan.isFocusDrop, proposed.mode == .bento,
                   let display = system.displays().first(where: { $0.id == displayID }) {
                    // The drop recorded Undo history; a window only the
                    // correction moves gets its frame from before the drag.
                    let correction = resolvedAfterMeasuredClamps(
                        placements, session: &proposed, display: display, recordHistory: true
                    )
                    placements = correction.placements
                    if let reason = correction.degradedReason {
                        correctionDegraded = true
                        recoveryFailurePresented = true
                        suspendAutomaticBentoWrites(
                            displayID: displayID,
                            sessionID: active.layoutSession.id,
                            error: reason
                        )
                    }
                }
                let requestedFrames = Dictionary(uniqueKeysWithValues: placements.map { ($0.windowID, $0.frame) })
                proposed.recordProposedFrames(requestedFrames)
                proposed.windowIDs.insert(sourceID)
                if !proposed.bentoInsertionOrder.contains(sourceID) {
                    proposed.bentoInsertionOrder.append(sourceID)
                }
                proposed.excludedFocusWindowIDs.formUnion(plan.excludedWindowIDs)
                proposed.excludedFocusWindowIDs.remove(sourceID)
                proposed.automaticallyFloatingWindowIDs.remove(sourceID)
                if correctionDegraded {
                    // Automatic writes are suspended and the message names
                    // Repair; the drop's session is not committed.
                    committed = false
                } else if sessionStore.commit(
                    proposed,
                    replacing: active.layoutSession.revision
                ) != nil {
                    let changedWindowIDs: Set<WindowID> = Set(placements.compactMap { placement -> WindowID? in
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
                    statusMessage = "The Adaptive layout changed while the drop was finishing. Try again."
                    pendingWindowEvents.recordTopologyChange()
                    schedulePendingWindowEvents()
                    // Keep the physical result visible; the fresh event will
                    // reduce it against the current session instead of merging
                    // the stale drag snapshot.
                }
            } else if !recoveryFailurePresented {
                statusMessage = dropOutcome.failureReason ?? "macOS rejected the Adaptive window update."
            }
        }

        if !committed, !frameTransactionCommitted {
            recoveryFailurePresented = restoreBentoDragIfNeeded(active.session)
        }
        if !committed, active.tabbedOrigin != nil {
            _ = finishTabbedDrop(active, sourceID: sourceID, end: .restore)
        }
        if isDrop, !recoveryFailurePresented {
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

    /// True when every window is still at its verified frame.
    static func tabbedWindowsStayed(_ ids: Set<WindowID>, windows: [WindowSnapshot],
                                    checkpoint: [WindowID: BTRect]) -> Bool {
        let frames = Dictionary(windows.map { ($0.id, $0.frame) }) { first, _ in first }
        return ids.allSatisfy { id in
            guard let frame = frames[id], let verified = checkpoint[id] else { return false }
            return frame.approximatelyEquals(verified, tolerance: 1)
        }
    }

    /// Tabbed drops that are not Bento reflows. A center drop adds the window
    /// to that pane as a tab. A torn-off tab dropped nowhere returns to its
    /// group. Returns false to let Bento handle splits and snaps.
    private func finishTabbedDrop(_ active: ActiveBentoDrag, sourceID: WindowID, end: LayoutDragEnd) -> Bool {
        guard let display = system.displays().first(where: { $0.id == active.session.displayID }),
              sessionStore.session(for: active.session.displayID)?.tabbedState != nil
        else { return false }
        // The tab arrangement the overlay prepared for a center drop.
        let preparedState: TabbedLayoutState?
        switch end {
        case let .commit(prepared):
            guard prepared.outcome.addsTab, let state = prepared.tabbedState else { return false }
            preparedState = state
        case .restore:
            guard active.tabbedOrigin != nil else { return false }
            preparedState = nil
        case .failed:
            return false
        }
        _ = coordinator.cancel(transaction: active.transaction)
        if let session = sessionStore.session(for: active.session.displayID),
           session.id == active.layoutSession.id, session.revision == active.layoutSession.revision,
           display.visibleFrame == active.session.workArea,
           let baseline = active.tabbedUndoBaseline {
            var session = session
            let restoring = preparedState == nil
            let state = preparedState ?? baseline
            let windows = (try? observeVisibleWindows()) ?? active.tabbedWindows
            // The dragged window's center can be on the neighbouring display.
            let displayWindows = bentoEligible(windows.filter {
                ($0.displayID == display.id || $0.id == sourceID) && $0.isEligible && !$0.isFloating
            })
            // A press that moved no selected tab, such as a click in a title
            // bar or toolbar, puts the group back without a placement. A
            // placement would activate the selected tab and close a popup
            // the click opened.
            if restoring, Self.tabbedWindowsStayed(Set(baseline.selectedWindowIDs).union([sourceID]),
                                                   windows: displayWindows, checkpoint: active.tabbedRollbackFrames) {
                session.tabbedState = baseline
                session.windowIDs = baseline.windowIDs
                Self.tabbedLog.debug("torn tab restored without placement: no selected tab moved")
                if let committed = sessionStore.commit(session, replacing: session.revision) {
                    // Without a placement, a re-application the gesture took
                    // over still has to run.
                    if active.droppedTabbedReapply { tabbedNeedsReapply.insert(display.id) }
                    showTabbed(session: committed, display: display, windows: displayWindows)
                    return true
                }
            }
            // The tear-off is provisional. Publish membership and Undo only
            // after placement succeeds, restoring the original group on failure.
            let focus = restoring ? baseline.activeWindowID : sourceID
            // A floating window has no slot to return to. If the drop fails,
            // it stays where it was dropped; Undo still floats it where it
            // was before the drag.
            var rollbackFrames = active.tabbedRollbackFrames
            let floated = baseline.floatingWindowIDs.contains(sourceID)
            if floated, let dropped = windows.first(where: { $0.id == sourceID })?.frame {
                rollbackFrames[sourceID] = dropped
            }
            applyTabbedState(state, session: session, display: display, windows: displayWindows,
                focus: focus, rememberUndo: !restoring,
                rollbackFrames: rollbackFrames,
                preparedDrop: preparedState.map { PreparedTabbedArrangement(state: $0, windows: active.tabbedWindows) },
                gestureBaseline: baseline, floatingUndoFrame: floated ? active.tabbedRollbackFrames[sourceID] : nil,
                gestureSourceID: sourceID, expectedSpaceID: active.tabbedSpaceID)
            return true
        }
        statusMessage = "The desktop changed during the drop. Use Repair Layout to return the window to a pane."
        presentActionResult(succeeded: false, error: statusMessage, displayID: display.id)
        pendingWindowEvents.recordTopologyChange()
        schedulePendingWindowEvents()
        return true
    }

    /// Puts a dragged window in its slot of the current layout after the
    /// layout changed during the drag, for example by a shortcut. Only that
    /// window is written in Bento; Tabbed writes only the frames its current
    /// arrangement changes. Nothing is written on another Space, in another
    /// mode, or when the window is no longer in the layout. Returns true when
    /// a failure was already presented.
    private func returnDraggedWindowToCurrentLayout(
        _ active: ActiveBentoDrag, sourceID: WindowID, displayID: DisplayID
    ) -> Bool {
        guard let session = sessionStore.session(for: displayID), session.id == active.layoutSession.id,
              session.mode == active.layoutSession.mode,
              let display = system.displays().first(where: { $0.id == displayID }),
              active.tabbedSpaceID == nil
                || system.refreshNativeDesktopObservation()?.currentSpace(on: displayID) == active.tabbedSpaceID
        else { return false }
        if session.mode == .tabbed {
            // Tabbed queues its own intents during a drag, so its layout
            // changes under a drag only with the display, work area, or a
            // sweep. While the drag's revision stands, its tear-off is still
            // provisional and the arrangement from before the drag is current.
            let unchangedRevision = session.revision == active.layoutSession.revision
            guard var state = unchangedRevision ? active.tabbedUndoBaseline ?? session.tabbedState : session.tabbedState,
                  let windows = try? observeVisibleWindows() else { return false }
            if !state.windowIDs.contains(sourceID) {
                // A newer revision can still hold the drag's provisional
                // tear-off. The tab returns to its pane if that pane remains.
                guard let origin = active.tabbedOrigin, state.floatingWindowIDs.contains(sourceID) else { return false }
                guard state.panes.contains(where: { $0.id == origin }) else {
                    statusMessage = "The desktop changed during the drop. Use Repair Layout to return the window to a pane."
                    presentActionResult(succeeded: false, error: statusMessage, displayID: displayID)
                    return true
                }
                state.move(sourceID, to: origin)
            }
            applyTabbedState(state, session: session, display: display, windows: bentoEligible(windows.filter {
                ($0.displayID == displayID || $0.id == sourceID) && $0.isEligible && !$0.isFloating
            }), focus: nil, gestureBaseline: unchangedRevision ? active.tabbedUndoBaseline : nil,
                gestureSourceID: sourceID)
            return false
        }
        guard session.mode == .bento,
              let slot = session.bentoState.placements(in: display.visibleFrame).first(where: { $0.windowID == sourceID })?.frame,
              let source = try? system.windowSnapshots(ids: [sourceID]).first,
              !source.frame.approximatelyEquals(slot, tolerance: 1)
        else { return false }
        switch coordinator.applyPlacements([Placement(windowID: sourceID, frame: slot)], recordHistory: false,
                                           destination: DropDestination(displayID: displayID, sourceWindowID: sourceID)) {
        case .applied:
            // An application can ignore a write that lands while it finishes
            // its own window drag. Settlement checks the frame and retries.
            scheduleBentoSettlement(displayID: displayID, changedWindowIDs: [sourceID],
                                    requestedFrames: [sourceID: slot], baselineFrames: [sourceID: source.frame])
            return false
        case let .degraded(reason), let .failed(reason):
            suspendAutomaticBentoWrites(displayID: displayID, sessionID: session.id,
                error: "The dragged window could not return to its pane. \(reason)")
            return true
        }
    }

    /// Returns the dragged window to its frame from before the drag. Returns
    /// true when that failed and the failure was already presented.
    @discardableResult
    private func restoreBentoDragIfNeeded(_ session: BentoDragSession) -> Bool {
        // A floating window has no slot; it stays where the drag left it.
        guard session.originalState.root?.windowIDs.contains(session.sourceWindowID) == true else { return false }
        let restorePlacement = session.restorePlacement
        guard let source = try? observeVisibleWindows().first(where: { $0.id == session.sourceWindowID }),
              !source.frame.approximatelyEquals(restorePlacement.frame, tolerance: 1)
        else { return false }
        // The source returns to its start display, wherever its center is now.
        let outcome = coordinator.applyPlacements(
            [restorePlacement], recordHistory: false,
            destination: DropDestination(displayID: session.displayID, sourceWindowID: session.sourceWindowID)
        )
        let reason: String
        switch outcome {
        case .applied:
            return false
        case let .degraded(degradedReason):
            reason = degradedReason
        case let .failed(failureReason):
            // Nothing was written, so the window is still where the drag left
            // it, away from its pane: the drop did not undo cleanly.
            reason = "The dragged window could not return to its pane. \(failureReason)"
        }
        suspendAutomaticBentoWrites(
            displayID: session.displayID,
            sessionID: activeBentoDrag?.layoutSession.id,
            error: reason
        )
        return true
    }

    private func replayBufferedBentoDragEvents() {
        let buffered = bentoDragEventBuffer.drain()
        pendingWindowEvents.formUnion(buffered)
        // Drag startup discards callbacks, but an existing arrival still needs discovery.
        if !pendingWindowArrivals.isEmpty { pendingWindowEvents.recordTopologyChange() }
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
            cancelPaneApplicationRequest()
            tabbedTasks.values.forEach { $0.cancel() }
            allTabbedOverlays.forEach { $0.hide() }
            dragSnap.cancel()
            layoutWheel.cancel(reason: .permissionUnavailable)
        }
        applicationRecoveryPendingWindows.removeAll()
        applicationRecoveryFrameEventPIDs.removeAll()
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
        // macOS shows its prompt only once; General then offers Accessibility settings instead.
        updateConfiguration { $0.accessibilityPromptRequested = true }
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
            for (file, settings) in savedLayoutActions.store.values {
                if let key = settings.shortcut,
                   let problem = SavedLayoutShortcutPolicy.conflict(key, configuration: validated, layouts: [:]),
                   SavedLayoutShortcutPolicy.conflict(key, configuration: configuration, layouts: [:]) == nil {
                    let reason = "\(problem) Saved Layout: \(savedLayoutActions.names[file] ?? "Saved Layout")."
                    statusMessage = reason; savedLayoutActions.message = reason; return
                }
            }
            let previous = configuration
            let changes = ConfigurationChangeSet.between(previous, validated)
            let gapChanged = validated.bentoInnerGap != previous.bentoInnerGap
            let presentationChanged = validated.tabbedStripPresentation != previous.tabbedStripPresentation
            configuration = validated
            applyRuntimeConfiguration(changes)
            scheduleConfigurationSave()
            statusMessage = nil
            refreshSavedLayoutActions()
            if gapChanged {
                if paneGapBeforeRelayout == nil { paneGapBeforeRelayout = previous.bentoInnerGap }
                paneGapEditChanged = true
                paneGapRelayoutPending = true
                schedulePaneGapRelayout()
            }
            if presentationChanged { refreshActiveWindows(force: false) }
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func paneGapEditingChanged(_ editing: Bool) {
        guard !isShutDown else { return }
        isEditingPaneGap = editing
        if editing {
            paneGapEditChanged = false
        } else if paneGapEditChanged {
            paneGapEditChanged = false
            paneGapRelayoutPending = true
            paneGapRelayoutTask?.cancel()
            paneGapRelayoutTask = nil
            if !applyPendingPaneGap() { schedulePaneGapRelayout() }
        }
    }

    private func schedulePaneGapRelayout() {
        guard paneGapRelayoutTask == nil, !isShutDown else { return }
        let sleep = paneGapRelayoutSleep
        paneGapRelayoutTask = Task { @MainActor [weak self] in
            do { try await sleep(.milliseconds(75)) } catch { return }
            guard let self, !Task.isCancelled, !self.isShutDown else { return }
            self.paneGapRelayoutTask = nil
            if !self.applyPendingPaneGap() { self.schedulePaneGapRelayout() }
        }
    }

    private var canRelayoutPaneGap: Bool {
        !isShutDown && (isEditingPaneGap || !primaryButtonIsPressed())
            && !isStabilizingSpace && activeBentoDrag == nil && !dragSnap.isGestureActive
            && !dividerResize.isDragging && !linkedResize.isResizing
            && tabbedTasks.isEmpty && settlementTasks.isEmpty
            && windowEventTask == nil && pendingWindowEvents.isEmpty
    }

    /// One latest value, with no queued placements behind a gesture or a slow app.
    private func applyPendingPaneGap() -> Bool {
        guard paneGapRelayoutPending else { return true }
        guard canRelayoutPaneGap else { return false }
        paneGapBeforeRelayout = nil
        refreshActiveWindows(force: true, relayoutPaneGap: true)
        // An unsuccessful inventory or placement retains the request. Ordinary
        // refreshes retry it; do not poll an unavailable application every 75 ms.
        return true
    }

    private func completePendingPaneGapIfApplied() {
        guard paneGapRelayoutPending, paneGapBeforeRelayout == nil,
              tabbedTasks.isEmpty else { return }
        let gap = configuration.bentoInnerGap
        guard sessionStore.sessions.values.allSatisfy({ session in
            switch session.mode {
            case .manual, .linked, .tabbed: return true
            case .bento:
                return !session.automaticWritesSuspended && session.bentoState.metrics.paneGap == gap
            }
        }) else { return }
        paneGapRelayoutPending = false
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
            layoutWheel.suspend(reason: isShortcutCaptureActive ? .shortcutRecording : .permissionUnavailable)
        }
    }

    func flushConfiguration() {
        configurationSaveTask?.cancel()
        configurationSaveTask = nil
        persistConfiguration()
    }

    func shutdown() {
        savedLayoutActions.stop()
        displayTriggerRuntime?.stop()
        savedLayoutApplier?.stop()
        cancelPaneApplicationRequest()
        for id in Array(completedRequestFocus.keys) { releaseCompletedRequestFocus(id) }
        paneApplicationArrivalGuards.removeAll()
        cancelPendingFocusRestore(on: nil)
        guard !isShutDown else { return }
        paneGapRelayoutTask?.cancel()
        paneGapRelayoutTask = nil
        paneGapRelayoutPending = false
        absenceConfirmationTask?.cancel()
        arrivalSweepTask?.cancel()
        tabbedCurtainRecheckTask?.cancel()
        // A held divider can roll back to pane frames. Finish that rollback
        // before restoring the windows' Native entry frames.
        dividerResize.hideAndCancel()
        for (displayID, session) in sessionStore.sessions where session.mode == .tabbed {
            if let display = system.displays().first(where: { $0.id == displayID }),
               let windows = try? observeVisibleWindows() {
                _ = coordinator.applyPlacements(
                    tabbedRestorationPlacements(baselineFrames: session.tabbedBaselineFrames, on: display, windows: windows),
                    recordHistory: false
                )
            }
        }
        tabbedTasks.values.forEach { $0.cancel() }
        tabbedFocusTask?.cancel()
        tabbedResizeReleaseTask?.cancel()
        allTabbedOverlays.forEach {
            $0.hide()
            $0.acceptsTabDrags = true
        }
        isShutDown = true
        tabbedOverlays.removeAll()
        spacePanelOverlays.removeAll()
        spacePanelCorrections.removeAll()
        #if DEBUG
        tracePendingArrivals("arrival_dropped", reason: "shutdown")
        #endif
        pendingWindowArrivals.removeAll()
        applicationRecoveryPendingWindows.removeAll()
        applicationRecoveryFrameEventPIDs.removeAll()
        for token in notificationTokens {
            for center in notificationCenters { center.removeObserver(token) }
        }
        notificationTokens.removeAll()
        notificationCenters.removeAll()
        actionVerificationTask?.cancel()
        flushConfiguration()
        watchdogTimer?.invalidate()
        watchdogTimer = nil
        applicationRecoveryTask?.cancel()
        applicationRecoveryTask = nil
        applicationRecoveryDeadline = nil
        permissionPollTask?.cancel()
        windowEventTask?.cancel()
        pendingBentoFocusCheck = false
        spaceStabilizationTask?.cancel()
        displayRefreshDebouncer.cancel()
        settlementTasks.values.forEach { $0.cancel() }
        system.stopDisplayReconfigurationMonitoring()
        // After the last frame writes above, so none is left to restore.
        system.restoreEnhancedUserInterfaceBeforeQuit()
        system.stopWindowObservation()
        layoutWheel.stop()
        shortcuts.stop()
        sharedGestureEvents.stop()
        dragSnap.stop()
        titleBarDoubleClick.stop()
        linkedResize.stop()
        resultPill?.hide()
        resultPill = nil
        automaticResultPills.values.forEach { $0.hide() }
        automaticResultPills.removeAll()
    }

    private func scheduleConfigurationSave() {
        guard configurationLoadError == nil else { return }
        configurationNeedsSave = true
        configurationSaveTask?.cancel()
        configurationSaveTask = Task { @MainActor [clock, weak self] in
            try? await clock.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self?.configurationSaveTask = nil
            self?.persistConfiguration()
        }
    }

    private func persistConfiguration() {
        guard configurationLoadError == nil, configurationNeedsSave else { return }
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
            allTabbedOverlays.forEach { $0.overlayAppearance = configuration.overlayAppearance }
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
        if changes.contains(.workArea) {
            system.leavesSpaceForDock = configuration.leavesSpaceForDock
            scheduleDisplayRefresh()
        }
        if changes.contains(.activationPolicy) {
            applyDockPolicy()
        }
        if changes.contains(.menuBarIcon) {
            setMenuBarIconVisible(configuration.showMenuBarIcon)
        }
        if !changes.isDisjoint(with: [.divider, .bentoGeometry, .linkedResize]) {
            refreshDividerBoundaries()
        }
    }

    private func syncSharedGestureMonitoring() {
        let hasChooser = paneApplicationPopover != nil || tabbedOverlays.values.contains(where: \.hasLayoutGallery)
        let observesRequests = paneApplicationRequest != nil
            || !completedRequestFocus.isEmpty
        dragSnap.observesChooserMouseDown = hasChooser || observesRequests
        dragSnap.observesRequestMouseSequence = paneApplicationRequest != nil
        guard !isShutDown, hasAccessibilityPermission,
              configuration.snappingEnabled || configuration.linkedResizeEnabled || hasChooser || observesRequests
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
        if configuration.showDockIcon { AppIconStyle.apply() }
    }

    func installWorkspaceTriggers(center: NotificationCenter = .default,
                                  workspaceCenter: NotificationCenter = NSWorkspace.shared.notificationCenter) {
        guard !isShutDown else { return }
        for candidate in [center, workspaceCenter] where !notificationCenters.contains(where: { $0 === candidate }) {
            notificationCenters.append(candidate)
        }
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
            notificationTokens.append(workspaceCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                #if DEBUG
                if name == NSWorkspace.didLaunchApplicationNotification,
                   MainActor.assumeIsolated({ ArrivalTrace.shared.isEnabled }),
                   let pid = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier {
                    MainActor.assumeIsolated { ArrivalTrace.shared.record("app_launch_notification", pid: pid) }
                }
                #endif
                Task { @MainActor in
                    guard let self, !self.isShutDown else { return }
                    self.handleApplicationTopologyChange(waking: name == NSWorkspace.didWakeNotification)
                }
            })
        }
        // Each sleep allows one wake Apply, even though a wake sends two notifications. Display changes
        // during sleep are held until the wake.
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification] {
            notificationTokens.append(workspaceCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self, !self.isShutDown else { return }
                    self.displayTriggerRuntime?.sleeping()
                }
            })
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            notificationTokens.append(workspaceCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self, !self.isShutDown else { return }
                    self.displayTriggerRuntime?.wake()
                }
            })
        }
        // After a wake at the lock screen, a different app becoming active means the user unlocked.
        notificationTokens.append(workspaceCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] notification in
            let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let bundleID = application?.bundleIdentifier
            let processIdentifier = application?.processIdentifier
            // The observer runs on the main queue. Record intent before a queued
            // placement continuation can raise or finish the request.
            MainActor.assumeIsolated {
                guard let self, !self.isShutDown else { return }
                self.displayTriggerRuntime?.applicationActivated(bundleID: bundleID)
                self.requestApplicationActivated(bundleID, processIdentifier: processIdentifier)
            }
        })
        notificationTokens.append(workspaceCenter.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.isShutDown else { return }
                self.displayTriggerRuntime?.sessionResigned()
            }
        })
        notificationTokens.append(workspaceCenter.addObserver(forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.isShutDown else { return }
                self.displayTriggerRuntime?.sessionBecameActive()
            }
        })
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
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let managed = app.map { $0.processIdentifier != getpid() && $0.activationPolicy == .regular && !$0.isHidden } ?? false
            Task { @MainActor in
                guard let self, !self.isShutDown else { return }
                self.handleApplicationActivation(fromManagedApplication: managed)
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

    func handleApplicationTopologyChange(waking: Bool = false) {
        guard !isShutDown else { return }
        savedLayoutInventoryRevision &+= 1
        if waking {
            dragSnap.cancel()
            layoutWheel.cancel(reason: .waking)
        }
        #if DEBUG
        tracePendingArrivals("arrival_dropped", reason: "application_topology_refresh")
        #endif
        pendingWindowArrivals.removeAll()
        system.refreshApplicationObservers()
        dividerResize.hideAndCancel()
        refreshActiveWindows(force: true)
        refreshPaneApplicationWindowChoices()
    }

    /// Coalesces Core Graphics and AppKit display notifications into the same
    /// refresh. AppKit remains the fallback when callback registration fails.
    func scheduleDisplayRefresh() {
        layoutWheel.cancel(reason: .displayChanged)
        displayRefreshDebouncer.schedule { [weak self] in
            guard let self else { return }
            self.dragSnap.cancel()
            self.dividerResize.hideAndCancel()
            if let remembered = self.userActionDisplayID, !self.system.displays().contains(where: { $0.id == remembered }) {
                self.userActionDisplayID = nil
            }
            self.refreshActiveWindows(force: true)
            self.savedLayoutInventoryRevision &+= 1
            self.refreshSavedLayoutActionTarget()
            self.displayTriggerRuntime?.displaysChanged()
        }
    }

    func beginActiveSpaceStabilization() {
        invalidateMenuPanelFocusReplay()
        savedLayoutApplier?.cancel()
        cancelPaneApplicationRequest()
        #if DEBUG
        tracePendingArrivals("arrival_dropped", reason: "space_stabilization_restarts_discovery")
        #endif
        pendingWindowArrivals.removeAll()
        applicationRecoveryTask?.cancel()
        applicationRecoveryTask = nil
        applicationRecoveryDeadline = nil
        tabbedFocusTask?.cancel()
        tabbedResizeReleaseTask?.cancel()
        tabbedResizeReleaseTask = nil
        tabbedQueuedIntents.removeAll()
        tabbedNeedsRefresh.removeAll()
        tabbedNeedsReapply.removeAll()
        tabbedTasks.values.forEach { $0.cancel() }
        for overlay in allTabbedOverlays {
            if overlay.keepsPanelsOnSpace { overlay.prepareForSpaceChange() }
            else { overlay.hide() }
        }
        dragSnap.cancel()
        layoutWheel.cancel(reason: .spaceChanged)
        dividerResize.hideAndCancel()
        windowEventTask?.cancel()
        windowEventTask = nil
        settlementTasks.values.forEach { $0.cancel() }
        settlementTasks.removeAll()
        spaceStabilizationTask?.cancel()
        selectNativeDesktopSessions()
        selectSpacePanelOverlays()
        spaceStabilizationGeneration &+= 1
        let generation = spaceStabilizationGeneration
        isStabilizingSpace = true
        spaceStabilizationTask = Task { @MainActor [clock, weak self] in
            guard let self else { return }
            var stabilizer = DesktopObservationStabilizer()
            var latestWindows: [WindowSnapshot] = []
            for _ in 0..<4 {
                guard !Task.isCancelled, self.spaceStabilizationGeneration == generation else { return }
                guard let sampled = try? self.observeVisibleWindows() else {
                    self.isStabilizingSpace = false
                    self.allTabbedOverlays.forEach { $0.hide() }
                    self.schedulePendingWindowEvents()
                    return
                }
                latestWindows = sampled
                let eligible = sampled.filter { $0.isEligible && !$0.isFloating }
                let membership = Dictionary(grouping: eligible, by: \.displayID)
                    .mapValues { Set($0.map(\.id)) }
                if stabilizer.observe(membership) { break }
                try? await clock.sleep(for: .milliseconds(75))
            }
            guard !Task.isCancelled, self.spaceStabilizationGeneration == generation else { return }
            self.pendingWindowEvents.removeAll()
            self.coordinator.finishExpectedMutations(observing: latestWindows)
            self.suppressSpaceFrameEventsUntil = clock.now.advanced(by: .milliseconds(300))
            self.isStabilizingSpace = false
            self.refreshActiveWindows(force: true, windows: latestWindows, desktopTransition: true)
            self.savedLayoutInventoryRevision &+= 1
            let returned = Set(latestWindows.filter {
                self.applicationRecoveryFrameEventPIDs[$0.id] == $0.processIdentifier
            }.map(\.id))
            if !returned.isEmpty {
                self.pendingWindowEvents.recordFrameChanges(returned)
                self.pendingWindowEvents.recordTopologyChange()
            }
            self.schedulePendingWindowEvents()
        }
    }

    private func spacePanelOwnerIsCurrent(_ session: LayoutSession, overlay: TabbedOverlayController) -> Bool {
        guard tabbedOverlays[session.displayID] === overlay else { return false }
        let observation = system.refreshNativeDesktopObservation()
        guard observation?.allowsAutomaticLayout(on: session.displayID) != false else { return false }
        guard let space = session.nativeSpaceID, let observation else { return !overlay.keepsPanelsOnSpace }
        return overlay.keepsPanelsOnSpace && observation.currentSpace(on: session.displayID) == space
            && observation.allowsAutomaticLayout(on: session.displayID)
    }

    /// A sweep can select the incoming desktop before its Space notification.
    /// Detach the outgoing owner without hiding its retained surfaces.
    private func selectTabbedOverlay(for session: LayoutSession) {
        guard system.nativeDesktopObservation() != nil else {
            discardSpacePanelOverlays()
            return
        }
        guard session.nativeSpaceID != nil else { return }
        let incoming = spacePanelOverlays[session.id]
        if let previous = tabbedOverlays[session.displayID], previous !== incoming {
            if previous.keepsPanelsOnSpace { previous.prepareForSpaceChange() }
            else { previous.hide() }
        }
        tabbedOverlays[session.displayID] = incoming
    }

    private func discardSpacePanelOverlays() {
        spacePanelOverlays.values.forEach { $0.hide() }
        tabbedOverlays = tabbedOverlays.filter { !$0.value.keepsPanelsOnSpace }
        spacePanelOverlays.removeAll()
        spacePanelCorrections.removeAll()
    }

    private func selectSpacePanelOverlays() {
        guard let observation = system.nativeDesktopObservation() else {
            discardSpacePanelOverlays()
            return
        }
        spacePanelCorrections.formUnion(spacePanelOverlays.keys)
        for display in system.displays() {
            if let active = sessionStore.session(for: display.id),
               active.nativeSpaceID == observation.currentSpace(on: display.id),
               observation.allowsAutomaticLayout(on: display.id), active.mode == .tabbed {
                tabbedOverlays[display.id] = spacePanelOverlays[active.id]
            } else if tabbedOverlays[display.id]?.keepsPanelsOnSpace == true {
                tabbedOverlays.removeValue(forKey: display.id)
            }
        }
    }

    /// A native Space change selects an established exact runtime session immediately.
    /// Membership still stabilizes twice before the normal refresh may write.
    private func selectNativeDesktopSessions() {
        guard let observation = system.refreshNativeDesktopObservation() else {
            savedLayoutApplier?.updateUndoDesktops(nil, displays: [])
            nativeFullscreenDisplayIDs.removeAll()
            return
        }
        savedLayoutApplier?.updateUndoDesktops(observation, displays: system.displays())
        sessionStore.removeMissingNativeSpaces(observation.knownSpacesByDisplay)
        forgetEndedTabbedSessions(displayIDs: system.displays().map(\.id))
        for (displayID, nativeSpaceID) in observation.currentSpaceByDisplay {
            // Keep a recovering inferred owner until stable membership can establish overlap.
            if let inferred = sessionStore.session(for: displayID), inferred.nativeSpaceID == nil,
               !sessionStore.allSessions(for: displayID).contains(where: { $0.nativeSpaceID == nativeSpaceID }),
               !applicationRecoveryPendingWindows.isEmpty || !applicationRecoveryFrameEventPIDs.isEmpty
                   || !system.unresponsiveApplicationRecoveryDeadlines.isEmpty {
                continue
            }
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

    func handleApplicationActivation(fromManagedApplication: Bool = true) {
        layoutWheel.cancel(reason: .applicationActivated)
        refreshFocusedDisplayWithoutLayout(recordsUserAction: fromManagedApplication)
        handleTabbedFocus()
    }

    private func refreshFocusedDisplayWithoutLayout(recordsUserAction: Bool) {
        dividerResize.hideAndCancel()
        guard !isStabilizingSpace, let focused = try? system.focusedWindow() else { return }
        if recordsUserAction, focused.isEligible, rule(for: focused).allowsDirectPlacement {
            rememberUserActionDisplay(focused.displayID)
        } else { activeDisplayID = focused.displayID }
        refreshSavedLayoutActionTarget()
        refreshDividerBoundaries()
    }

    func watchdog() {
        guard refreshPermission() else { return }
        guard activeBentoDrag == nil, !isStabilizingSpace else { return }
        let priorRecoveryGeneration = applicationRecoveryGeneration
        if applicationRecoveryGeneration == nil,
           !applicationRecoveryPendingWindows.isEmpty || !applicationRecoveryFrameEventPIDs.isEmpty
               || !system.unresponsiveApplicationRecoveryDeadlines.isEmpty {
            applicationRecoveryGeneration = spaceStabilizationGeneration
        }
        defer { applicationRecoveryGeneration = priorRecoveryGeneration }
        retryDeferredTabbedRepair()
        guard let windows = try? observeVisibleWindows(reconcilesRecovery: true) else { return }
        recordObservedWindows(windows, observation: system.nativeDesktopObservation())
        if !Set(applicationRecoveryFrameEventPIDs.keys).isDisjoint(with: Set(windows.map(\.id))) {
            pendingWindowEvents.recordTopologyChange()
            processPendingWindowEvents(windows: windows)
            return
        }
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
        if (paneGapRelayoutPending && paneGapBeforeRelayout == nil && canRelayoutPaneGap)
            || signature != lastVisibleSignature
            || windows.contains(where: { applicationRecoveryPendingWindows[$0.id] == $0.processIdentifier }) {
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

    /// A recovery generation guards writes; it does not mean this read will
    /// reconcile arrivals. Frame-only and presentation reads still need to
    /// queue a topology pass when they release a hold.
    private func observeVisibleWindows(reconcilesRecovery: Bool = false) throws -> [WindowSnapshot] {
        let heldBeforeRead = Set(system.unresponsiveApplicationRecoveryDeadlines.keys)
        var observed: [WindowSnapshot] = []
        #if DEBUG
        var arrivalReadSucceeded = false
        tracePendingArrivals("readiness_attempt", reason: "visible_window_inventory")
        defer {
            if arrivalTrace.isEnabled {
                arrivalTrace.observe(observed)
                for window in observed {
                    arrivalTrace.disposition("inventory_finished", windowID: window.id, reason: "visible_window_inventory")
                }
                for arrival in pendingWindowArrivals {
                    let found = observed.filter { window in
                        window.processIdentifier == arrival.processIdentifier
                            && (arrival.windowID.map { $0 == window.id } ?? !arrival.observedIDs.contains(window.id))
                    }
                    if found.isEmpty {
                        arrivalTrace.record("readiness_outcome", pid: arrival.processIdentifier, windowID: arrival.windowID,
                            outcome: arrivalReadSucceeded ? "omitted" : "read_failed")
                    } else {
                        for window in found { arrivalTrace.record("readiness_outcome", pid: window.processIdentifier,
                            windowID: window.id, outcome: "readable") }
                    }
                }
            }
        }
        #endif
        defer {
            let released = heldBeforeRead.subtracting(system.unresponsiveApplicationRecoveryDeadlines.keys)
            let returning = observed.filter {
                released.contains($0.processIdentifier) && !confirmedGoneWindowIDs.contains($0.id)
            }
            for window in returning {
                applicationRecoveryPendingWindows[window.id] = window.processIdentifier
            }
            if !returning.isEmpty, !reconcilesRecovery {
                pendingWindowEvents.recordTopologyChange()
                schedulePendingWindowEvents()
            }
        }
        guard var eligible = applicationRecoveryProbePIDs else {
            defer { scheduleUnresponsiveApplicationRecovery() }
            observed = try system.visibleWindows()
            #if DEBUG
            arrivalReadSucceeded = true
            #endif
            return observed
        }
        let requested = eligible
        defer {
            applicationRecoveryProbePIDs = eligible
            let now = applicationRecoveryUptime()
            for pid in eligible {
                applicationRecoveries[pid]?.notBefore = now + 1
            }
            for pid in requested.subtracting(eligible) {
                applicationRecoveries[pid]?.attempts += 1
                let attempts = applicationRecoveries[pid]?.attempts ?? 0
                applicationRecoveries[pid]?.notBefore = now + pow(2, Double(attempts - 1))
            }
            scheduleUnresponsiveApplicationRecovery()
        }
        observed = try system.visibleWindows(recoveringApplicationPIDs: &eligible)
        #if DEBUG
        arrivalReadSucceeded = true
        #endif
        return observed
    }

    /// Select current bookkeeping before a retained event can defer arrival placement.
    private func prepareApplicationRecoverySessions(windows: [WindowSnapshot]) {
        guard applicationRecoveryGeneration != nil else { return }
        let observation = system.nativeDesktopObservation()
        let windows = observation?.windowsOnCurrentSpaces(windows) ?? windows
        let returningDisplays = Set(windows.filter {
            applicationRecoveryPendingWindows[$0.id] == $0.processIdentifier
                || applicationRecoveryFrameEventPIDs[$0.id] == $0.processIdentifier
        }.map(\.displayID))
        let firstNativeDisplays = Set(sessionStore.sessions.values.filter { session in
            guard session.nativeSpaceID == nil,
                  let space = observation?.currentSpace(on: session.displayID) else { return false }
            return !sessionStore.allSessions(for: session.displayID).contains { $0.nativeSpaceID == space }
                && bentoEligible(windows).contains { $0.displayID == session.displayID && $0.isEligible
                    && !$0.isFloating && session.windowIDs.contains($0.id) }
        }.map(\.displayID))
        for displayID in returningDisplays.union(firstNativeDisplays) {
            let observedIDs = Set(bentoEligible(windows).filter {
                $0.displayID == displayID && $0.isEligible && !$0.isFloating
            }.map(\.id))
            var selectedStore = sessionStore
            if let nativeSpaceID = observation?.currentSpace(on: displayID),
               let inferred = selectedStore.session(for: displayID), inferred.nativeSpaceID == nil,
               !inferred.windowIDs.isDisjoint(with: observedIDs),
               !selectedStore.allSessions(for: displayID).contains(where: { $0.nativeSpaceID == nativeSpaceID }) {
                // The overlap anchor identifies this inferred desktop without replacing its user's state.
                selectedStore.update(displayID) { $0.nativeSpaceID = nativeSpaceID }
            }
            let activation = selectedStore.activate(
                displayID: displayID,
                windowIDs: observedIDs,
                focusedWindowID: selectedStore.session(for: displayID)?.focusedWindowID.flatMap {
                    observedIDs.contains($0) ? $0 : nil
                },
                defaultMode: configuration.defaultLayoutMode,
                reuseActiveWhenUnmatched: false,
                commitObservation: false,
                nativeSpaceID: observation?.currentSpace(on: displayID)
            )
            if observation == nil {
                // Public fallback needs an existing overlap anchor, not an old desktop guess.
                guard !activation.previousWindowIDs.isDisjoint(with: observedIDs) else {
                    if let active = sessionStore.session(for: displayID) {
                        applicationRecoveryFallbackMatches[active.id] = false
                    }
                    continue
                }
                applicationRecoveryFallbackMatches[activation.session.id] = true
            } else {
                applicationRecoveryFallbackMatches.removeValue(forKey: activation.session.id)
            }
            sessionStore = selectedStore
        }
    }

    private func completeApplicationRecoveryReconciliation(windows: [WindowSnapshot], session: LayoutSession) {
        let reconciled = windows.filter {
            $0.displayID == session.displayID && applicationRecoveryPendingWindows[$0.id] == $0.processIdentifier
        }
        guard !reconciled.isEmpty else { return }
        let observation = system.refreshNativeDesktopObservation()
        guard !isStabilizingSpace,
              applicationRecoveryGeneration == nil || applicationRecoveryGeneration == spaceStabilizationGeneration,
              sessionStore.isCurrent(session.id, revision: session.revision, on: session.displayID),
              observation?.allowsAutomaticLayout(on: session.displayID) != false,
              recoveryObservationMatches(observation, session: session) else { return }
        let held = system.unresponsiveApplicationRecoveryDeadlines
        for window in reconciled where held[window.processIdentifier] == nil {
            applicationRecoveryPendingWindows.removeValue(forKey: window.id)
        }
    }

    /// Wake once after a held application's deadline, then back off. Recovery
    /// observes the current desktop; it never retains a placement proposal.
    private func scheduleUnresponsiveApplicationRecovery() {
        guard !isShutDown, !isStabilizingSpace,
              activeBentoDrag == nil, !dragSnap.isGestureActive, !dividerResize.isDragging else { return }
        let deadlines = system.unresponsiveApplicationRecoveryDeadlines
        applicationRecoveries = applicationRecoveries.filter { deadlines[$0.key] != nil }
        for pid in deadlines.keys where applicationRecoveries[pid] == nil {
            applicationRecoveries[pid] = ApplicationRecovery()
        }
        guard let next = deadlines.compactMap({ pid, deadline -> TimeInterval? in
            guard let recovery = applicationRecoveries[pid], recovery.attempts < 3 else { return nil }
            return max(deadline + 0.1, recovery.notBefore)
        }).min()
        else {
            applicationRecoveryTask?.cancel()
            applicationRecoveryTask = nil
            applicationRecoveryDeadline = nil
            return
        }
        if let scheduled = applicationRecoveryDeadline, scheduled <= next { return }
        applicationRecoveryTask?.cancel()
        applicationRecoveryDeadline = next
        let generation = spaceStabilizationGeneration
        let delay = max(0, next - applicationRecoveryUptime())
        let clock = applicationRecoveryClock
        applicationRecoveryTask = Task { @MainActor [weak self] in
            try? await clock.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            self.applicationRecoveryTask = nil
            self.applicationRecoveryDeadline = nil
            guard !self.isShutDown, !self.isStabilizingSpace,
                  self.spaceStabilizationGeneration == generation else { return }
            let now = self.applicationRecoveryUptime()
            let due = self.system.unresponsiveApplicationRecoveryDeadlines.filter { pid, deadline in
                guard let recovery = self.applicationRecoveries[pid], recovery.attempts < 3 else { return false }
                return max(deadline + 0.1, recovery.notBefore) <= now
            }
            if !due.isEmpty {
                self.pendingWindowEvents.recordTopologyChange()
                self.applicationRecoveryGeneration = generation
                self.applicationRecoveryProbePIDs = Set(due.keys)
                defer {
                    self.applicationRecoveryGeneration = nil
                    self.applicationRecoveryProbePIDs = nil
                }
                self.processPendingWindowEvents()
            }
            self.scheduleUnresponsiveApplicationRecovery()
        }
    }

    private func receiveWindowSystemEvent(_ event: WindowSystemEvent) {
        #if DEBUG
        if event.kind == .created {
            arrivalTrace.record("window_created_received", pid: event.processIdentifier, windowID: event.windowID)
            if isStabilizingSpace { arrivalTrace.record("arrival_deferred", pid: event.processIdentifier,
                windowID: event.windowID, reason: "space_stabilization") }
        }
        if event.kind == .destroyed { arrivalTrace.record("arrival_dropped", pid: event.processIdentifier,
            windowID: event.windowID, reason: "window_destroyed") }
        #endif
        guard !isShutDown else { return }
        switch event.kind {
        case .created, .destroyed, .minimized, .restored, .focused:
            savedLayoutInventoryRevision &+= 1
        case .moved, .resized: break
        }
        receiveApplicationRequestLifecycle(event)
        if event.kind == .focused { receivePaneApplicationFocus(event) }
        // Resolve the focus now, while it is still on that window. A later
        // focus change elsewhere must not erase a check this one needs.
        if event.kind == .focused, !pendingBentoFocusCheck, bentoFocusLandsInLayout(event) {
            pendingBentoFocusCheck = true
        }
        // Lifecycle evidence survives gesture buffering and Space stabilization.
        // A stale scan must not restore a pane before minimization is observed.
        if let windowID = event.windowID {
            if event.kind == .minimized {
                confirmedMinimizedWindowIDs.insert(windowID)
                sessionStore.removeMinimizedTabbedWindow(windowID)
            }
            if event.kind == .restored || event.kind == .destroyed {
                confirmedMinimizedWindowIDs.remove(windowID)
            }
            if event.kind == .destroyed {
                pendingWindowArrivals.removeAll {
                    $0.processIdentifier == event.processIdentifier
                        && $0.windowID == windowID
                }
                applicationRecoveryPendingWindows.removeValue(forKey: windowID)
                applicationRecoveryFrameEventPIDs.removeValue(forKey: windowID)
                coordinator.removeClosedWindow(windowID)
                confirmedGoneWindowIDs.insert(windowID)
                for id in bentoStateBeforeFocus.keys
                    where bentoStateBeforeFocus[id]?.layout.root?.windowIDs.contains(windowID) == true {
                    bentoStateBeforeFocus[id]?.closedWindowIDs.insert(windowID)
                }
                for displayID in focusRestores.keys
                    where focusRestores[displayID]?.session.windowIDs.contains(windowID) == true {
                    focusRestores[displayID]?.closedWindowIDs.insert(windowID)
                }
                sessionStore.removeClosedTabbedWindow(windowID)
                tabbedSteppedWindows.removeValue(forKey: windowID)
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
        if let windowID = event.windowID, event.kind == .destroyed || event.kind == .minimized {
            // Update cached content before stabilization or gesture buffering can defer a sweep.
            for overlay in spacePanelOverlays.values {
                overlay.removeUnavailableWindows([windowID])
            }
        }
        guard !isStabilizingSpace else { return }
        // A wheel aimed at a window that just went away must not fall through to
        // whatever replaces it.
        if let windowID = event.windowID, event.kind == .destroyed || event.kind == .minimized {
            layoutWheel.handleTargetLost(windowID: windowID)
        }
        if event.kind == .moved || event.kind == .resized,
           (suppressSpaceFrameEventsUntil.map { clock.now >= $0 } ?? true),
           let windowID = event.windowID,
           system.unresponsiveApplicationRecoveryDeadlines[event.processIdentifier] != nil {
            applicationRecoveryFrameEventPIDs[windowID] = event.processIdentifier
        }
        if event.kind == .created,
           sessionStore.sessions.values.contains(where: { $0.mode == .bento || $0.mode == .tabbed }) {
            if let index = pendingWindowArrivals.firstIndex(where: {
                $0.processIdentifier == event.processIdentifier && $0.windowID == event.windowID
            }) {
                #if DEBUG
                arrivalTrace.record("arrival_coalesced", pid: event.processIdentifier, windowID: event.windowID, reason: "duplicate_creation_identity")
                #endif
                // Several unmapped creations cannot be discharged by one readable window.
                // A repeated callback for one element is not another window.
                let repeatsElement = event.creationToken != nil
                    && pendingWindowArrivals[index].creationToken == event.creationToken
                if event.windowID == nil, !repeatsElement { pendingWindowArrivals[index].hasMultipleUnknownCreations = true }
            } else {
                pendingWindowArrivals.append(PendingWindowArrival(
                    processIdentifier: event.processIdentifier,
                    windowID: event.windowID,
                    observedIDs: Set(observedRuleWindows.filter {
                        $0.processIdentifier == event.processIdentifier
                    }.map(\.id)),
                    deadline: windowArrivalNow().addingTimeInterval(0.5),
                    creationToken: event.creationToken))
            }
        }
        if let activeBentoDrag {
            #if DEBUG
            if event.kind == .created { arrivalTrace.record("arrival_deferred", pid: event.processIdentifier,
                windowID: event.windowID, reason: "adaptive_drag") }
            #endif
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
            guard (suppressSpaceFrameEventsUntil.map { clock.now >= $0 } ?? true) else { return }
            pendingWindowEvents.record(event)
            if let windowID = event.windowID { previewTabbedNativeResize(windowID) }
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
                    if session.mode == .bento,
                       let display = system.displays().first(where: { $0.id == displayID }) {
                        scheduleBentoFocusRestore(session: session, display: display)
                    }
                }
                dragSnap.prepareForRestoredWindowDrag(windowID: windowID)
            }
            pendingWindowEvents.record(event)
        case .created, .destroyed, .minimized:
            pendingWindowEvents.record(event)
        case .focused:
            // AX focus events already have their own coalesced visibility checks below.
            // Record the target without the activation path's divider inventory.
            if !isStabilizingSpace, let focused = try? system.focusedWindow(), focused.isEligible,
               focused.processIdentifier == event.processIdentifier,
               event.windowID == nil || event.windowID == focused.id,
               rule(for: focused).allowsDirectPlacement {
                rememberUserActionDisplay(focused.displayID)
                refreshSavedLayoutActionTarget()
            }
            handleTabbedFocus()
            layoutWheel.handleFocusedWindowChanged()
        }
        schedulePendingWindowEvents(expeditesArrival: event.kind == .created && !pendingWindowArrivals.isEmpty)
    }

    /// Places a new window from a read of its own Accessibility element, before
    /// any complete inventory. Space membership and the WindowServer record are
    /// read for that one window; every other window comes from the last
    /// inventory, which any other window event invalidates. The topology flag
    /// stays set, so one complete inventory follows to validate the result.
    /// - Returns: Whether this event pass is finished.
    private func placeCreatedWindowsFromTargetedReads() -> Bool {
        guard let reader = system as? any CreatedWindowReading,
              !pendingWindowArrivals.isEmpty,
              pendingWindowArrivals.allSatisfy({ $0.creationToken != nil && !$0.hasMultipleUnknownCreations }),
              pendingWindowEvents.frameEventWindowIDs.isEmpty, !pendingBentoFocusCheck,
              pendingRestoredWindowDeadlines.isEmpty, applicationRecoveryPendingWindows.isEmpty,
              applicationRecoveryFrameEventPIDs.isEmpty, system.unresponsiveApplicationRecoveryDeadlines.isEmpty,
              windowEventRetryBackoff.delay == WindowEventRetryBackoff.initialDelay
        else { return false }
        let now = windowArrivalNow()
        var read: [(index: Int, window: WindowSnapshot)] = []
        var waiting = false
        for index in pendingWindowArrivals.indices {
            guard let token = pendingWindowArrivals[index].creationToken else { continue }
            let arrival = pendingWindowArrivals[index]
            // The deadline and an unreadable element hand the arrival to the complete inventory.
            guard arrival.deadline > now else { pendingWindowArrivals[index].creationToken = nil; return false }
            let result = reader.readCreatedWindow(token: token)
            if case let .window(window) = result {
                resolveApplicationRequestCreation(window, token: token)
            }
            #if DEBUG
            arrivalTrace.record("targeted_read", pid: arrival.processIdentifier, windowID: { if case let .window(w) = result { w.id } else { nil } }(),
                outcome: { switch result { case .window: "readable"; case .notReady: "not_ready"; case .unavailable: "unavailable" } }())
            #endif
            switch result {
            // An early floating verdict can be a standard window still being built. The arrival stays pending for a later read.
            case let .window(window) where window.isFloating: break
            case let .window(window): read.append((index, window))
            case .notReady: waiting = true
            case .unavailable: pendingWindowArrivals[index].creationToken = nil; return false
            }
        }
        var windows: [WindowSnapshot] = []
        if !read.isEmpty {
            guard let merged = reader.cachedVisibleWindows(adding: read.map(\.window)) else { return false }
            windows = merged
        }
        for index in read.map(\.index).sorted(by: >) { pendingWindowArrivals.remove(at: index) }
        if !read.isEmpty {
            recordObservedWindows(windows, observation: system.nativeDesktopObservation())
            // A floating window or one that cannot be tiled joins no layout; nothing is placed for it.
            if read.contains(where: { $0.window.isEligible }) {
                placesCreatedWindowsInThisTurn = true
                defer { placesCreatedWindowsInThisTurn = false }
                refreshActiveWindows(force: false, windows: windows)
            }
        }
        schedulePendingWindowEvents(after: waiting ? .milliseconds(8) : WindowEventRetryBackoff.initialDelay)
        return true
    }

    private func bentoFocusLandsInLayout(_ event: WindowSystemEvent) -> Bool {
        let sessions = sessionStore.sessions.values.filter { $0.mode == .bento }
        guard !sessions.isEmpty else { return false }
        let focusedID: WindowID
        if let windowID = event.windowID {
            focusedID = windowID
        } else {
            guard let focused = try? system.focusedWindow(),
                  focused.processIdentifier == event.processIdentifier else { return false }
            focusedID = focused.id
        }
        return sessions.contains { $0.windowIDs.contains(focusedID) }
    }

    private func bentoPeersNeedTopologyRefresh() -> Bool {
        let sessions = sessionStore.sessions.values.filter { $0.mode == .bento }
        let expectedPeers = sessions.flatMap { session in
            Set(session.bentoState.root?.windowIDs ?? [])
                .subtracting(session.excludedFocusWindowIDs)
                .subtracting(confirmedGoneWindowIDs)
                .subtracting(confirmedMinimizedWindowIDs)
                .map { (windowID: $0, displayID: session.displayID) }
        }
        let expectedIDs = Set(expectedPeers.map(\.windowID))
        guard !expectedIDs.isEmpty else { return false }
        guard let refreshed = try? system.cachedVisibleWindows(refreshing: expectedIDs) else { return true }
        let snapshots = Dictionary(uniqueKeysWithValues: refreshed.map { ($0.id, $0) })
        return expectedPeers.contains { peer in
            guard let snapshot = snapshots[peer.windowID] else { return true }
            return !snapshot.isEligible || snapshot.isFloating
                || !rule(for: snapshot).allowsBentoParticipation || snapshot.displayID != peer.displayID
        }
    }

    private func schedulePendingWindowEvents(after requestedDelay: Duration? = nil, expeditesArrival: Bool = false) {
        // A failed inventory owns the pending retry; a duplicate creation must not cancel its backoff.
        let expeditesArrival = expeditesArrival && windowEventRetryBackoff.delay == WindowEventRetryBackoff.initialDelay
        // A failed frame-only read leaves no topology flag, but its backoff still owns the next retry.
        let arrivalDelay = windowEventRetryBackoff.delay > WindowEventRetryBackoff.initialDelay
            ? windowEventRetryBackoff.delay : .milliseconds(8)
        let delay: Duration = expeditesArrival ? .zero
            : requestedDelay ?? (pendingWindowArrivals.isEmpty ? WindowEventRetryBackoff.initialDelay : arrivalDelay)
        guard !isShutDown else { return }
        let isGestureActive = activeBentoDrag != nil || dragSnap.isGestureActive || dividerResize.isDragging
        #if DEBUG
        if isGestureActive || isStabilizingSpace { tracePendingArrivals("arrival_deferred", reason: isGestureActive ? "drag" : "space_stabilization") }
        #endif
        guard !isGestureActive, !isStabilizingSpace,
              !pendingWindowEvents.isEmpty || pendingBentoFocusCheck else { return }
        // Frame traffic must not postpone an already queued window arrival.
        if windowEventTask != nil, windowEventTaskIncludesTopology,
           !expeditesArrival || windowEventTaskIsImmediate {
            #if DEBUG
            tracePendingArrivals("arrival_coalesced", reason: "topology_deadline_already_queued")
            #endif
            return
        }
        windowEventTask?.cancel()
        windowEventTaskIncludesTopology = pendingWindowEvents.topologyChanged
        windowEventTaskIsImmediate = delay == .zero
        #if DEBUG
        tracePendingArrivals("event_pass_queued", reason: "delay_\(delay)")
        #endif
        let sleep = windowEventSleep
        windowEventTask = Task { @MainActor [weak self] in
            // Defer one actor turn to keep AX delivery non-reentrant; readable arrivals need no timer.
            guard !Task.isCancelled else { return }
            if delay > .zero { try? await sleep(delay) }
            guard let self, !Task.isCancelled else { return }
            #if DEBUG
            self.tracePendingArrivals("event_pass_started", reason: "queued_task")
            #endif
            self.windowEventTask = nil
            self.windowEventTaskIncludesTopology = false
            self.windowEventTaskIsImmediate = false
            self.processPendingWindowEvents()
        }
    }

    func processPendingWindowEvents(windows suppliedWindows: [WindowSnapshot]? = nil, forceRefresh: Bool = false) {
        if savedLayoutApplier?.ownedDisplayID != nil { return }
        let isGestureActive = activeBentoDrag != nil || dragSnap.isGestureActive || dividerResize.isDragging
        guard !isGestureActive, !isStabilizingSpace,
              !pendingWindowEvents.isEmpty || pendingBentoFocusCheck else { return }
        if suppliedWindows == nil, !forceRefresh, placeCreatedWindowsFromTargetedReads() { return }
        let priorRecoveryGeneration = applicationRecoveryGeneration
        if applicationRecoveryGeneration == nil,
           !applicationRecoveryPendingWindows.isEmpty || !applicationRecoveryFrameEventPIDs.isEmpty
               || !system.unresponsiveApplicationRecoveryDeadlines.isEmpty {
            applicationRecoveryGeneration = spaceStabilizationGeneration
        }
        defer { applicationRecoveryGeneration = priorRecoveryGeneration }
        let pendingEvents = pendingWindowEvents
        var changedIDs = pendingEvents.frameEventWindowIDs
        let refreshTopology = pendingEvents.topologyChanged
            || (pendingBentoFocusCheck && bentoPeersNeedTopologyRefresh())
        if !refreshTopology, changedIDs.isEmpty {
            pendingBentoFocusCheck = false
            windowEventRetryBackoff.reset()
            return
        }
        let observationGeneration = spaceStabilizationGeneration
        let windows: [WindowSnapshot]
        if let suppliedWindows {
            windows = suppliedWindows
        } else if !refreshTopology,
           !changedIDs.isEmpty,
           let targeted = try? system.cachedVisibleWindows(refreshing: changedIDs) {
            windows = targeted
        } else {
            guard let completeSweep = try? observeVisibleWindows(reconcilesRecovery: refreshTopology) else {
                if refreshTopology { pendingWindowEvents.recordTopologyChange() }
                schedulePendingWindowEvents(after: windowEventRetryBackoff.nextDelayAfterFailure())
                return
            }
            windows = completeSweep
        }
        // The adapter caches this by generation; ordinary frame merges do not advance it.
        recordObservedWindows(windows, observation: system.nativeDesktopObservation())
        let recoveredFrameIDs = Set(windows.filter {
            applicationRecoveryFrameEventPIDs[$0.id] == $0.processIdentifier
                && !confirmedGoneWindowIDs.contains($0.id)
        }.map(\.id))
        var recoveryFrameResults = Dictionary(uniqueKeysWithValues: recoveredFrameIDs.map { ($0, RecoveryFrameResult.deferred) })
        func recordRecoveryFrameResult(_ result: RecoveryFrameResult, on displayID: DisplayID) {
            for window in windows where window.displayID == displayID && recoveredFrameIDs.contains(window.id) {
                recoveryFrameResults[window.id] = result
            }
        }
        changedIDs.formUnion(recoveredFrameIDs)
        // Any sweep can read a held app before its recovery timer fires.
        let previousRecoveryGeneration = applicationRecoveryGeneration
        if applicationRecoveryGeneration == nil, !recoveredFrameIDs.isEmpty {
            applicationRecoveryGeneration = observationGeneration
        }
        defer { applicationRecoveryGeneration = previousRecoveryGeneration }
        pendingWindowEvents.acknowledge(pendingEvents)
        // Hold release does not observe off-screen windows. A stale classification
        // must also leave their exact event identities for the current desktop.
        let previousFallbackMatches = applicationRecoveryFallbackMatches
        defer { applicationRecoveryFallbackMatches = previousFallbackMatches }
        prepareApplicationRecoverySessions(windows: windows)
        let recoverySessions = sessionStore.sessions
        defer {
            let recoveredDisplayIDs = Set(windows.filter { recoveredFrameIDs.contains($0.id) }.map(\.displayID))
            let currentDisplays = Set(recoverySessions.values.filter { session in
                recoveredDisplayIDs.contains(session.displayID)
                    && recoveryDesktopIsCurrent(for: session)
                    && sessionStore.session(for: session.displayID)?.id == session.id
            }.map(\.displayID))
            let classifiedIDs = Set(windows.filter {
                recoveredFrameIDs.contains($0.id) && currentDisplays.contains($0.displayID)
                    && recoveryFrameResults[$0.id]?.isHandled == true
            }.map(\.id))
            let heldPIDs = Set(system.unresponsiveApplicationRecoveryDeadlines.keys)
            applicationRecoveryFrameEventPIDs = applicationRecoveryFrameEventPIDs.filter {
                (heldPIDs.contains($0.value) || !classifiedIDs.contains($0.key))
                    && !confirmedGoneWindowIDs.contains($0.key)
            }
            pendingWindowEvents.recordFrameChanges(Set(windows.filter {
                applicationRecoveryFrameEventPIDs[$0.id] == $0.processIdentifier
            }.map(\.id)))
        }
        pendingBentoFocusCheck = false
        windowEventRetryBackoff.reset()
        let visibleIDs = Set(windows.map(\.id))
        let now = Date()
        pendingRestoredWindowDeadlines = pendingRestoredWindowDeadlines.filter { windowID, deadline in
            !visibleIDs.contains(windowID) && deadline > now
        }
        // A successful sweep can omit a window whose first AX snapshot is not ready.
        let arrivalNow = windowArrivalNow()
        pendingWindowArrivals.removeAll { arrival in
            #if DEBUG
            if arrivalTrace.isEnabled, (arrival.deadline <= arrivalNow
                || system.unresponsiveApplicationRecoveryDeadlines[arrival.processIdentifier] != nil),
                !windows.contains(where: { window in
                    window.processIdentifier == arrival.processIdentifier
                        && (arrival.windowID.map { $0 == window.id } ?? !arrival.observedIDs.contains(window.id))
                }) {
                arrivalTrace.record("arrival_dropped", pid: arrival.processIdentifier, windowID: arrival.windowID,
                    reason: arrival.deadline <= arrivalNow ? "readiness_deadline" : "unresponsive_application_recovery")
            }
            #endif
            return arrival.deadline <= arrivalNow
                || system.unresponsiveApplicationRecoveryDeadlines[arrival.processIdentifier] != nil
                // A floating or ineligible window may still become an ordinary window before the deadline.
                || (!arrival.hasMultipleUnknownCreations && windows.contains { window in
                    !window.isFloating && window.isEligible && window.processIdentifier == arrival.processIdentifier
                        && (arrival.windowID.map { $0 == window.id }
                            ?? !arrival.observedIDs.contains(window.id))
                })
        }
        let shouldRetryWindowReadiness = !pendingRestoredWindowDeadlines.isEmpty
            || !pendingWindowArrivals.isEmpty
        // A readable floating arrival rarely changes class; recheck it at the ordinary cadence.
        let arrivalsAreReadable = pendingRestoredWindowDeadlines.isEmpty && pendingWindowArrivals.allSatisfy { arrival in
            !arrival.hasMultipleUnknownCreations && windows.contains { window in
                window.processIdentifier == arrival.processIdentifier
                    && (arrival.windowID.map { $0 == window.id } ?? !arrival.observedIDs.contains(window.id))
            }
        }
        if shouldRetryWindowReadiness { pendingWindowEvents.recordTopologyChange() }
        defer {
            if shouldRetryWindowReadiness {
                schedulePendingWindowEvents(after: arrivalsAreReadable ? WindowEventRetryBackoff.initialDelay : nil)
            }
        }
        guard !changedIDs.isEmpty else {
            if refreshTopology {
                refreshActiveWindows(force: forceRefresh, windows: windows, recoveryFrameResults: recoveryFrameResults)
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
        for id in recoveredFrameIDs where !externalIDs.contains(id) {
            recoveryFrameResults[id] = .handled
        }
        guard !externalIDs.isEmpty else {
            if refreshTopology {
                refreshActiveWindows(force: forceRefresh, windows: windows, recoveryFrameResults: recoveryFrameResults)
            } else {
                refreshDividerBoundaries(windows: windows)
            }
            return
        }

        var classifiedFramesMayHaveChanged = false
        let displayIDs = Set(externalIDs.compactMap { windowsByID[$0]?.displayID })
        for displayID in displayIDs {
            // A BetterTile divider commit owns its read-back settlement. Do
            // not start a second adoption cycle from the same AX callbacks.
            if let session = sessionStore.session(for: displayID), session.mode == .tabbed {
                guard settlementTasks[displayID] == nil else { continue }
                // A new window's frame callback cannot resize an existing pane.
                if !externalIDs.isDisjoint(with: session.tabbedState?.selectedWindowIDs ?? []) {
                    classifiedFramesMayHaveChanged = true
                }
                adoptTabbedResize(of: externalIDs, session: session, windows: windows)
                recordRecoveryFrameResult(.handled, on: displayID)
                continue
            }
            if sessionStore.session(for: displayID)?.mode == .manual {
                recordRecoveryFrameResult(.handled, on: displayID)
            }
            guard var session = sessionStore.session(for: displayID),
                  session.mode == .bento,
                  !focusRestoreSessionIDs.contains(session.id),
                  !session.automaticWritesSuspended,
                  let display = system.displays().first(where: { $0.id == displayID })
            else { continue }
            let returningIDs = Set(bentoEligible(windows).filter {
                (previousRecoveryGeneration != nil || recoveredFrameIDs.contains($0.id))
                    && externalIDs.contains($0.id) && $0.displayID == displayID && $0.isEligible && !$0.isFloating
            }.map(\.id)).subtracting(Set(session.bentoState.root?.windowIDs ?? []).union(session.bentoState.floatingWindowIDs))
            let displayWindows = windows.filter {
                $0.displayID == displayID && (session.windowIDs.contains($0.id) || returningIDs.contains($0.id))
            }
            let frames = Dictionary(uniqueKeysWithValues: displayWindows.map { ($0.id, $0.frame) })
            let constraints = Dictionary(uniqueKeysWithValues: displayWindows.map { ($0.id, $0.constraints) })
            let displayChanges = Set(externalIDs.filter { id in
                guard windowsByID[id]?.displayID == displayID, let frame = frames[id] else { return false }
                return recoveredFrameIDs.contains(id)
                    || session.lastObservedFrames[id]?.approximatelyEquals(frame, tolerance: 1) != true
            })
            guard !displayChanges.isEmpty else {
                recordRecoveryFrameResult(.handled, on: displayID)
                continue
            }

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
                    guard let observed = frames[id] else { return nil }
                    if returningIDs.contains(id),
                       let action = ExternalWindowChangeClassifier.matchDestination(observed, in: display.visibleFrame) {
                        return (id, .snapDestination(action))
                    }
                    guard let expected = expectedFrames[id] else { return nil }
                    return (id, ExternalWindowChangeClassifier.classify(
                        expected: expected,
                        observed: observed,
                        in: display.visibleFrame,
                        edgeTolerance: configuration.adjacencyTolerance
                    ))
                }
            )

            let route = ExternalChangeRouter.route(classifications)
            if settlementTasks[displayID] != nil {
                // Only recovery's genuine native snap supersedes settlement.
                guard applicationRecoveryGeneration != nil, case .snap = route,
                      windows.contains(where: { window in
                          window.displayID == displayID && (recoveredFrameIDs.contains(window.id)
                              || applicationRecoveryPendingWindows[window.id] == window.processIdentifier)
                      }) else { continue }
                settlementTasks.removeValue(forKey: displayID)?.cancel()
            }
            let removedIDs = confirmedGoneWindowIDs.union(confirmedMinimizedWindowIDs)
            if !recoveredFrameIDs.isDisjoint(with: displayChanges),
               !removedIDs.isDisjoint(with: session.windowIDs
                   .union(session.bentoState.root?.windowIDs ?? [])
                   .union(session.bentoState.floatingWindowIDs)),
               case let .update(updated, _, _) = BentoSessionReducer().reconcile(
                   session: session,
                   observation: BentoObservation(bounds: display.visibleFrame,
                       windows: displayWindows, focusedWindowID: session.focusedWindowID),
                   paneGap: session.paneGap(configured: paneGapForLayout),
                   confirmedGone: confirmedGoneWindowIDs,
                   minimized: confirmedMinimizedWindowIDs,
                   knownSpaceWindowIDs: system.nativeDesktopObservation()?.exclusiveWindowIDs(on: displayID) ?? [],
                   newWindowSide: configuration.bentoNewWindowSide,
                   balancesNewWindows: configuration.bentoBalancesNewWindows
               ) {
                // Keep confirmed removals provisional with the recovery transaction.
                session = updated
                session.windowIDs.subtract(removedIDs)
            }
            let dividerChanges: Set<WindowID>
            switch route {
            case let .snap(windowID, action):
                classifiedFramesMayHaveChanged = true
                // A recognised destination runs through the same planner a
                // BetterTile shortcut uses, so macOS's commands and BetterTile's
                // own produce identical layouts rather than two rules.
                let sourceBaselineFrame = session.lastObservedFrames[windowID]
                    ?? (returningIDs.contains(windowID) ? frames[windowID] : nil)
                if !returningIDs.isEmpty {
                    session.windowIDs.formUnion(returningIDs)
                    session.isBentoInitialized = true
                }
                let result = applyExternalSnap(
                    windowID: windowID,
                    action: action,
                    session: &session,
                    sourceBaselineFrame: sourceBaselineFrame,
                    displayWindows: displayWindows,
                    display: display
                )
                recordRecoveryFrameResult(.mutation(result), on: displayID)
                continue
            case .restoreLayout:
                classifiedFramesMayHaveChanged = true
                // Unrecognised movement cannot be expressed as a weight change.
                // Put the layout back rather than let the tree drift out of
                // step with the windows; general adoption is handled separately.
                recordRecoveryFrameResult(.mutation(
                    restoreBentoLayout(session: session, displayWindows: displayWindows, display: display)
                ), on: displayID)
                continue
            case .none:
                recordRecoveryFrameResult(.handled, on: displayID)
                continue
            case let .fitDividers(ids):
                classifiedFramesMayHaveChanged = true
                dividerChanges = ids
            }

            guard let fitted = BentoLayoutFitter(tolerance: configuration.adjacencyTolerance).fit(
                state: session.bentoState,
                currentFrames: frames,
                changedWindowIDs: dividerChanges,
                in: display.visibleFrame,
                constraints: constraints
            ) else {
                recordRecoveryFrameResult(.mutation(
                    restoreBentoLayout(session: session, displayWindows: displayWindows, display: display)
                ), on: displayID)
                continue
            }
            session.bentoState = fitted.state
            // An adopted edge resize is a layout change like a divider drag:
            // restoring a tree remembered at an earlier minimize would undo it.
            session.forgetRememberedBentoLayouts()
            let placements = fitted.placements.filter { session.windowIDs.contains($0.windowID) }
            let commitResult = commitBentoProposal(
                placements,
                session: &session,
                display: display,
                surfaceFailure: false
            )
            recordRecoveryFrameResult(.mutation(commitResult.result), on: displayID)
            if commitResult.result == .committed {
                scheduleBentoSettlement(displayID: displayID, changedWindowIDs: dividerChanges)
            } else if commitResult.result.needsRepair {
                suspendAutomaticBentoWrites(
                    displayID: displayID,
                    sessionID: session.id,
                    error: commitResult.failureReason ?? "The divider change could not be adopted."
                )
            }
        }
        if refreshTopology {
            // Classification without a mutation leaves this inventory current.
            refreshActiveWindows(force: forceRefresh, windows: classifiedFramesMayHaveChanged ? nil : windows,
                                 revalidatesSuppliedWindows: true, recoveryFrameResults: recoveryFrameResults)
        } else {
            refreshDividerBoundaries()
        }
    }

    /// Routes an externally produced snap through the same planner
    /// `performBentoAction` uses, so a macOS Move & Resize command and the
    /// equivalent BetterTile shortcut resolve to the same layout, including its
    /// pane-swap behaviour.
    @discardableResult
    private func applyExternalSnap(
        windowID: WindowID,
        action: WindowAction,
        session: inout LayoutSession,
        sourceBaselineFrame: BTRect?,
        displayWindows: [WindowSnapshot],
        display: DisplaySnapshot
    ) -> BentoProposalCommitResult {
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
            if applicationRecoveryFrameEventPIDs[windowID] == nil {
                restoreBentoLayout(session: session, displayWindows: displayWindows, display: display)
            }
            return .rejected
        }
        // Apply before committing. A proposed tree that the coordinator could
        // not realise must not become the session's state, or the layout and
        // the windows disagree from then on.
        session.bentoState = plan.state
        if !plan.isFocusDrop { session.forgetRememberedBentoLayouts() }
        // macOS's Window > Fill resolves to the same focus plan a BetterTile
        // maximize does, and a focus plan covers its peers instead of tiling
        // beside them. Committing only its placement would leave those peers
        // visible under the filled window while the tree still called them
        // tiled.
        if plan.isFocusDrop {
            guard let sourceBaselineFrame else {
                restoreBentoLayout(session: session, displayWindows: displayWindows, display: display)
                return .rejected
            }
            return applyExternalFocusDrop(
                plan: plan,
                windowID: windowID,
                session: &session,
                sourceBaselineFrame: sourceBaselineFrame,
                displayWindows: displayWindows,
                display: display
            )
        }
        let commitResult = commitBentoProposal(
            plan.placements,
            session: &session,
            display: display,
            surfaceFailure: false
        )
        guard commitResult.result == .committed else {
            if commitResult.result.needsRepair {
                suspendAutomaticBentoWrites(
                    displayID: display.id,
                    sessionID: session.id,
                    error: commitResult.failureReason ?? "The external window change could not be adopted."
                )
            }
            return commitResult.result
        }
        scheduleBentoSettlement(displayID: display.id, changedWindowIDs: Set(plan.placements.map(\.windowID)))
        refreshDividerBoundaries()
        return .committed
    }

    /// Names the windows that cannot fit beside each other. A long window
    /// title is shortened by its rendered width, so the rest of the message
    /// stays within the result pill's two lines.
    nonisolated static func overlapMessage(_ names: [String]) -> String {
        ResultPillLayout.detail(naming: Array(names.prefix(2))) { titles in
            "\(titles.joined(separator: " and ")) cannot fit beside each other at their minimum sizes."
        }
    }

    /// A window beyond Bento's six panes floats where it opened. Say so at
    /// once, with what the user can do, instead of leaving it over the tiles
    /// silently.
    private func announceBentoOverflow(before: LayoutSession, on display: DisplaySnapshot, windows: [WindowSnapshot]) {
        guard let after = sessionStore.session(for: display.id), after.mode == .bento,
              (after.bentoState.root?.windowIDs.count ?? 0) >= 6 else { return }
        let newlyFloating = after.automaticallyFloatingWindowIDs.subtracting(before.automaticallyFloatingWindowIDs)
        guard let window = windows.first(where: { newlyFloating.contains($0.id) }) else { return }
        statusMessage = ResultPillLayout.detail(naming: window.title.isEmpty ? [] : [window.title]) { titles in
            let name = titles.first.map { "“\($0)”" } ?? "This window"
            return "Adaptive manages up to six windows. \(name) stays floating: drop it on a pane to swap, or switch this desktop to Tabbed."
        }
        presentActionResult(succeeded: false, error: statusMessage, displayID: display.id)
    }

    private func endBentoFocusForPartition(
        _ action: WindowAction,
        window: WindowSnapshot,
        target: LayoutWheelTarget? = nil,
        restoringSession: LayoutSession?,
        cyclesShortcut: Bool = false
    ) -> Bool {
        guard BentoDropPlanner.partitionActions.contains(action),
              var session = sessionStore.session(for: window.displayID), session.mode == .bento,
              let display = system.displays().first(where: { $0.id == window.displayID }) else { return false }
        if restoringSession?.id == session.id, let restoringSession {
            session.excludedFocusWindowIDs.formUnion(restoringSession.excludedFocusWindowIDs)
        }
        let peers = session.excludedFocusWindowIDs
        guard !peers.isEmpty else { return false }
        let target = target ?? LayoutWheelTarget(
            windowID: window.id,
            displayID: display.id,
            visibleFrame: display.visibleFrame,
            desktopSessionID: session.id,
            nativeSpaceID: session.nativeSpaceID
                ?? system.refreshNativeDesktopObservation()?.currentSpace(on: display.id),
            layoutMode: session.mode
        )
        if case let .failed(reason) = coordinator.restoreFocusDropPeers(peers) {
            Self.bentoLog.notice("focus-drop peer restore incomplete: \(reason, privacy: .private)")
        }
        sessionStore.update(display.id) { $0.excludedFocusWindowIDs.removeAll() }
        if let windows = try? observeVisibleWindows(),
           peers.allSatisfy({ id in windows.contains { $0.id == id && $0.displayID == display.id && $0.isEligible } }) {
            bentoStateBeforeFocus.removeValue(forKey: session.id)
            return false
        }
        scheduleBentoFocusRestore(session: session, display: display, onPeersReturned: { [weak self] in
            self?.performLayoutWheel(.windowAction(action), for: target, cyclesShortcut: cyclesShortcut)
        })
        return true
    }

    /// Maximize on a tiled Bento window enters Focus mode at once: the window
    /// covers the display and its peers are minimized in one transaction.
    /// Restore, Maximize again, or restoring any peer from the Dock ends it
    /// and returns the previous layout. Nil means the action is not a
    /// Focus mode action for this window.
    private func performBentoFocusMode(
        _ action: WindowAction,
        window: WindowSnapshot,
        afterRestore: (@MainActor () -> Void)? = nil
    ) -> Bool? {
        guard action == .maximize || action == .restore,
              var session = sessionStore.session(for: window.displayID), session.mode == .bento,
              !session.automaticWritesSuspended, session.windowIDs.contains(window.id),
              let display = system.displays().first(where: { $0.id == window.displayID }) else { return nil }
        lastBentoFocusMessage = nil
        if !session.excludedFocusWindowIDs.isEmpty {
            // Either action on the focused window ends Focus mode.
            let peers = session.excludedFocusWindowIDs
            let outcome = coordinator.restoreFocusDropPeers(peers)
            sessionStore.update(display.id) { $0.excludedFocusWindowIDs.removeAll() }
            scheduleBentoFocusRestore(session: session, display: display, afterRestore: afterRestore)
            if case let .failed(reason) = outcome { statusMessage = reason; return false }
            lastBentoFocusMessage = "Layout restored"
            return true
        }
        guard action == .maximize, let windows = try? observeVisibleWindows() else { return nil }
        let displayWindows = windows.filter {
            $0.displayID == display.id && session.windowIDs.contains($0.id) && $0.isEligible && !$0.isFloating
        }
        // A lone window has no peers to cover; it maximizes normally.
        guard displayWindows.count > 1 else { return nil }
        bentoStateBeforeFocus[session.id] = BentoFocusSnapshot(layout: session.bentoState)
        applyExternalSnap(
            windowID: window.id, action: .maximize, session: &session,
            sourceBaselineFrame: window.frame, displayWindows: displayWindows, display: display
        )
        let covered = sessionStore.session(for: display.id)?.excludedFocusWindowIDs.count ?? 0
        guard covered > 0 else {
            statusMessage = statusMessage ?? "Focus mode could not minimize the other windows."
            return false
        }
        lastBentoFocusMessage = "Focus mode · \(covered) minimized"
        return true
    }

    private func scheduleBentoFocusRestore(
        session: LayoutSession,
        display: DisplaySnapshot,
        afterRestore: (@MainActor () -> Void)? = nil,
        onPeersReturned: (@MainActor () -> Void)? = nil
    ) {
        // Applications restore minimized windows asynchronously. Lay the
        // display out only once every peer is back, or the focused window
        // keeps a frame that overlaps the returning peers.
        // Only this desktop's layout may be restored; after a Space
        // switch the display shows another session. The returning peers
        // change the revision, so it cannot guard this wait.
        let sessionID = session.id
        let peers = session.excludedFocusWindowIDs
        cancelPendingFocusRestore(on: display.id)
        focusRestoreGeneration &+= 1
        let generation = focusRestoreGeneration
        let task = Task { @MainActor [clock, weak self] in
            defer {
                if let self, self.focusRestores[display.id]?.generation == generation {
                    self.focusRestores.removeValue(forKey: display.id)
                }
            }
            let deadline = clock.now.advanced(by: .milliseconds(1500))
            while let self, !self.isShutDown, !Task.isCancelled,
                  self.focusRestores[display.id]?.generation == generation {
                guard let current = self.sessionStore.session(for: display.id), current.mode == .bento,
                      current.id == sessionID else {
                    self.cancelPendingFocusRestore(on: display.id)
                    return
                }
                let windows = (try? self.observeVisibleWindows()) ?? []
                // A missing AX snapshot can be a peer still returning. Only
                // direct closure evidence releases its place in this wait.
                let closed = self.focusRestores[display.id]?.closedWindowIDs ?? []
                let back = peers.allSatisfy { id in
                    windows.contains { $0.id == id && $0.displayID == display.id && $0.isEligible }
                        || closed.contains(id)
                }
                if back || clock.now >= deadline {
                    guard var restored = self.sessionStore.session(for: display.id), restored.mode == .bento,
                          restored.id == sessionID else {
                        self.cancelPendingFocusRestore(on: display.id)
                        return
                    }
                    // A peer seen back on screen is no longer minimized, even
                    // if its restored notification has not arrived yet.
                    // Otherwise the layout that follows leaves it out.
                    self.confirmedMinimizedWindowIDs.subtract(peers.filter { id in
                        windows.contains { $0.id == id && $0.displayID == display.id && $0.isEligible }
                    })
                    if !back { Self.bentoLog.notice("focus-drop peer return wait timed out") }
                    if let onPeersReturned {
                        self.bentoStateBeforeFocus.removeValue(forKey: sessionID)
                        self.focusRestores.removeValue(forKey: display.id)
                        onPeersReturned()
                        return
                    }
                    // A sweep while the peers were minimized can drop them from
                    // the session's members. They are members again on return.
                    let members = restored.windowIDs.union(peers)
                    if let snapshot = self.bentoStateBeforeFocus.removeValue(forKey: restored.id) {
                        var previous = snapshot.layout
                        // A closed pane leaves permanently. An unread peer at
                        // the deadline keeps an anchor, just like a minimized
                        // peer, so its later return can rebuild this tree.
                        for id in snapshot.closedWindowIDs.union(closed) { previous.remove(id) }
                        let present = Set(windows.filter { $0.displayID == display.id && $0.isEligible }.map(\.id))
                        let unavailable = Set(previous.root?.windowIDs ?? []).subtracting(present)
                        let stillMinimized = peers.filter { id in windows.contains { $0.id == id && $0.isMinimized } }
                        var runtime = BentoRuntimeState(layout: previous, reinsertionAnchors: restored.bentoReinsertionAnchors)
                        let observation = BentoObservation(bounds: display.visibleFrame, windows: windows.filter {
                            $0.displayID == display.id && members.contains($0.id) && $0.isEligible
                        })
                        for id in unavailable.sorted() where runtime.layout.root?.windowIDs.contains(id) == true {
                            runtime = BentoPlanner().plan(state: runtime, observation: observation,
                                                          intent: .remove(id, minimized: true)).state
                        }
                        self.confirmedMinimizedWindowIDs.formUnion(stillMinimized)
                        restored.bentoState = runtime.layout
                        restored.bentoReinsertionAnchors = runtime.reinsertionAnchors
                    }
                    let displayWindows = windows.filter {
                        $0.displayID == display.id && members.contains($0.id) && $0.isEligible
                    }
                    // Commit the returned peers as members too, so a divider drag
                    // or Maximize right after the restore includes them.
                    restored.windowIDs.formUnion(displayWindows.map(\.id))
                    self.restoreBentoLayout(
                        session: restored, displayWindows: displayWindows, display: display,
                        suspendOnRejection: true
                    )
                    if let afterRestore {
                        self.focusRestores.removeValue(forKey: display.id)
                        afterRestore()
                    }
                    return
                }
                try? await clock.sleep(for: .milliseconds(50))
            }
        }
        focusRestores[display.id] = FocusRestore(
            task: task, session: session, generation: generation,
            closedWindowIDs: confirmedGoneWindowIDs.union(bentoStateBeforeFocus[sessionID]?.closedWindowIDs ?? [])
        )
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
    ) -> BentoProposalCommitResult {
        guard let placement = plan.placements.first else { return .rejected }
        let expectedRevision = session.revision
        guard recoveryDesktopIsCurrent(for: session),
              sessionStore.isCurrent(session.id, revision: expectedRevision, on: display.id) else {
            Self.bentoLog.notice("discarded stale focus plan for revision \(expectedRevision, privacy: .public)")
            pendingWindowEvents.recordTopologyChange()
            if !sessionStore.isCurrent(session.id, revision: expectedRevision, on: display.id) {
                schedulePendingWindowEvents()
            }
            return .stale
        }
        let outcome = coordinator.applyFocusDrop(
            placement: placement,
            minimizing: plan.minimizedWindowIDs,
            sourceBaselineFrame: sourceBaselineFrame,
            validating: {
                self.recoveryDesktopIsCurrent(for: session)
                    && self.sessionStore.isCurrent(session.id, revision: expectedRevision, on: display.id)
            }
        )
        guard outcome.isApplied else {
            let stale = !recoveryDesktopIsCurrent(for: session)
                || !sessionStore.isCurrent(session.id, revision: expectedRevision, on: display.id)
            if stale {
                pendingWindowEvents.recordTopologyChange()
                if !sessionStore.isCurrent(session.id, revision: expectedRevision, on: display.id) {
                    schedulePendingWindowEvents()
                }
            }
            if case let .degraded(reason) = outcome {
                suspendAutomaticBentoWrites(displayID: display.id, sessionID: session.id, error: reason)
                return .degraded
            }
            return stale ? .stale : .rejected
        }
        session.excludedFocusWindowIDs.formUnion(plan.excludedWindowIDs)
        session.excludedFocusWindowIDs.remove(windowID)
        session.recordProposedFrames([placement.windowID: placement.frame])
        guard let committed = sessionStore.commit(session, replacing: expectedRevision) else {
            Self.bentoLog.error("CAS conflict after a focus plan on revision \(expectedRevision, privacy: .public)")
            pendingWindowEvents.recordTopologyChange()
            if !sessionStore.isCurrent(session.id, revision: expectedRevision, on: display.id) {
                schedulePendingWindowEvents()
            }
            return .stale
        }
        session = committed
        // A focus plan covers rather than tiles, so there are no sibling frames
        // to settle. Settling here would read the covered peers as drift.
        refreshDividerBoundaries()
        return .committed
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
        surfaceFailure: Bool = true,
        revalidateBeforeEachWrite: Bool = false,
        didCommitSettlement: @MainActor (LayoutSession) -> Void = { _ in },
        validating ownerIsCurrent: () -> Bool = { true }
    ) -> (result: BentoProposalCommitResult, failureReason: String?) {
        #if DEBUG
        arrivalTrace.decided(placements, mode: "Adaptive")
        #endif
        let expectedRevision = session.revision
        guard ownerIsCurrent(), recoveryDesktopIsCurrent(for: session),
              sessionStore.isCurrent(session.id, revision: expectedRevision, on: display.id) else {
            statusMessage = "The Adaptive layout changed before this update could finish. Try again."
            Self.bentoLog.notice("discarded stale proposal for revision \(expectedRevision, privacy: .public)")
            pendingWindowEvents.recordTopologyChange()
            if !sessionStore.isCurrent(session.id, revision: expectedRevision, on: display.id) {
                schedulePendingWindowEvents()
            }
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
        let applyOutcome = coordinator.applyPlacements(placements, recordHistory: recordHistory, revalidateBeforeEachWrite: revalidateBeforeEachWrite || applicationRecoveryGeneration != nil, validating: {
            ownerIsCurrent() && self.recoveryDesktopIsCurrent(for: session)
                && self.sessionStore.isCurrent(session.id, revision: expectedRevision, on: display.id)
        })
        guard applyOutcome.isApplied else {
            if case .failed = applyOutcome,
               !recoveryDesktopIsCurrent(for: session)
                || !sessionStore.isCurrent(session.id, revision: expectedRevision, on: display.id) {
                pendingWindowEvents.recordTopologyChange()
                if !sessionStore.isCurrent(session.id, revision: expectedRevision, on: display.id) {
                    schedulePendingWindowEvents()
                }
                return (.stale, applyOutcome.failureReason)
            }
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
        let correction = resolvedAfterMeasuredClamps(
            placements, session: &session, display: display, recordHistory: recordHistory,
            revalidateBeforeEachWrite: revalidateBeforeEachWrite, validating: ownerIsCurrent
        )
        if let reason = correction.degradedReason {
            // The correction failed and its rollback did too: the windows are
            // neither at the first placement nor at the correction.
            statusMessage = reason
            Self.bentoLog.error("measured-clamp correction left a mixed layout")
            if surfaceFailure {
                presentActionResult(succeeded: false, error: statusMessage, displayID: display.id)
            }
            return (.degraded, statusMessage)
        }
        guard recoveryDesktopIsCurrent(for: session),
              sessionStore.isCurrent(session.id, revision: expectedRevision, on: display.id) else {
            pendingWindowEvents.recordTopologyChange()
            if !sessionStore.isCurrent(session.id, revision: expectedRevision, on: display.id) {
                schedulePendingWindowEvents()
            }
            return (.stale, "The desktop changed during placement.")
        }
        let placements = correction.placements
        session.recordProposedFrames(
            Dictionary(uniqueKeysWithValues: placements.map { ($0.windowID, $0.frame) })
        )
        guard let committed = sessionStore.commit(session, replacing: expectedRevision) else {
            // Main-actor calls cannot normally race while the coordinator is
            // applying synchronously. If re-entrant platform work does mutate
            // the session, discard the stale value and reduce a fresh event.
            statusMessage = "The Adaptive layout changed while macOS was applying it. Try again."
            Self.bentoLog.error("CAS conflict after applying revision \(expectedRevision, privacy: .public)")
            pendingWindowEvents.recordTopologyChange()
            if !sessionStore.isCurrent(session.id, revision: expectedRevision, on: display.id) {
                schedulePendingWindowEvents()
            }
            if surfaceFailure {
                presentActionResult(succeeded: false, error: statusMessage, displayID: display.id)
            }
            return (.stale, statusMessage)
        }
        session = committed
        didCommitSettlement(committed)
        return (.committed, nil)
    }

    /// Recovery can spend time reading new minimums after its first Space check.
    private func recoveryDesktopIsCurrent(for session: LayoutSession) -> Bool {
        guard let generation = applicationRecoveryGeneration else { return true }
        let observation = system.refreshNativeDesktopObservation()
        return !isStabilizingSpace && generation == spaceStabilizationGeneration
            && observation?.allowsAutomaticLayout(on: session.displayID) != false
            && recoveryObservationMatches(observation, session: session)
    }

    private func recoveryObservationMatches(_ observation: NativeDesktopObservation?, session: LayoutSession) -> Bool {
        if let matched = applicationRecoveryFallbackMatches[session.id] { return matched && observation == nil }
        return observation?.currentSpace(on: session.displayID) == session.nativeSpaceID
    }

    /// A write reads each size back. When an application clamped a window
    /// larger than its pane, that minimum is now known: solve the same tree
    /// again and write once more in the same pass, so the correction lands
    /// with the placement instead of as a separate, later jump.
    private func resolvedAfterMeasuredClamps(
        _ placements: [Placement],
        session: inout LayoutSession,
        display: DisplaySnapshot,
        recordHistory: Bool, revalidateBeforeEachWrite: Bool = false,
        validating ownerIsCurrent: () -> Bool = { true }
    ) -> (placements: [Placement], degradedReason: String?) {
        let ids = Set(placements.map(\.windowID))
        guard session.mode == .bento, placements.count > 1,
              Set(session.bentoState.root?.windowIDs ?? []) == ids,
              let measured = try? system.windowSnapshots(ids: ids), measured.count == ids.count
        else { return (placements, nil) }
        let requested = Dictionary(uniqueKeysWithValues: placements.map { ($0.windowID, $0.frame) })
        let clamped = measured.contains { window in
            guard let frame = requested[window.id] else { return false }
            return window.frame.size.width > frame.size.width + 2 || window.frame.size.height > frame.size.height + 2
        }
        guard clamped,
              let solved = BentoConstraintSolver().solve(
                  state: session.bentoState, in: display.visibleFrame,
                  constraints: Dictionary(uniqueKeysWithValues: measured.map { ($0.id, $0.constraints) }))
        else { return (placements, nil) }
        let next = solved.placements(in: display.visibleFrame)
        let nextFrames = Dictionary(uniqueKeysWithValues: next.map { ($0.windowID, $0.frame) })
        guard nextFrames != requested, bentoProposalIsContained(next, in: display) else { return (placements, nil) }
        // The first write already recorded undo frames for the windows it
        // moved. A window only the correction moves gets its frame from
        // before the action; the others keep their single entry.
        let actionBaseline = coordinator.lastPlacementBaselineFrames
        // A cleanly rolled-back correction keeps the first placement.
        switch coordinator.applyPlacements(next, recordHistory: false, revalidateBeforeEachWrite: revalidateBeforeEachWrite || applicationRecoveryGeneration != nil, validating: {
            ownerIsCurrent() && self.recoveryDesktopIsCurrent(for: session)
                && self.sessionStore.isCurrent(session.id, revision: session.revision, on: display.id)
        }) {
        case .applied:
            session.bentoState = solved
            if recordHistory {
                coordinator.recordHistory(actionBaseline.filter { id, baseline in
                    guard let first = requested[id], let corrected = nextFrames[id] else { return false }
                    return baseline.approximatelyEquals(first, tolerance: 0.01)
                        && !corrected.approximatelyEquals(first, tolerance: 0.01)
                })
            }
            return (next, nil)
        case let .degraded(reason):
            return (placements, reason)
        case .failed:
            return (placements, nil)
        }
    }

    // MARK: - Application rules

    private struct SavedLayoutWindowLocation: Equatable {
        var display: DisplayID
        var spaces: Set<NativeSpaceID>?
    }
    private var savedLayoutWindowLocations: [WindowID: SavedLayoutWindowLocation]?

    /// Reuse reconciliation's snapshots and its native observation; compare each inventory once.
    private func recordObservedWindows(_ windows: [WindowSnapshot], observation: NativeDesktopObservation?) {
        let next = Dictionary(windows.filter(\.isEligible).map {
            ($0.id, SavedLayoutWindowLocation(display: $0.displayID, spaces: observation?.windowMembership[$0.id]))
        }, uniquingKeysWith: { _, new in new })
        if let previous = savedLayoutWindowLocations, previous != next { savedLayoutInventoryRevision &+= 1 }
        savedLayoutWindowLocations = next
        if observedRuleWindows != windows { observedRuleWindows = windows }
    }
    /// Snapshots already read by normal reconciliation. Settings never polls AX.
    private(set) var observedRuleWindows: [WindowSnapshot] = [] {
        didSet { refreshPaneApplicationWindowChoices() }
    }

    func matchingRuleWindows(for bundleIdentifier: String) -> [WindowSnapshot] {
        guard hasAccessibilityPermission else { return [] }
        return observedRuleWindows.filter { $0.bundleIdentifier == bundleIdentifier }
    }

    static func applicationIcon(for bundleIdentifier: String) -> NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    func setRule(_ rule: ApplicationRule, for bundleIdentifier: String) {
        updateConfiguration { $0.applicationRules.set(rule, for: bundleIdentifier) }
        statusMessage = rule == .manageNormally
            ? "\(Self.ruleApplicationName(for: bundleIdentifier)) is managed normally again."
            : "\(Self.ruleApplicationName(for: bundleIdentifier)): \(rule.title)."
    }

    func clearRule(for bundleIdentifier: String) {
        updateConfiguration { $0.applicationRules.clear(bundleIdentifier) }
    }

    /// Keeps the rule either way. A rule that is off leaves the app managed normally.
    func setRuleEnabled(_ isEnabled: Bool, for bundleIdentifier: String) {
        guard let rule = configuration.applicationRules.configuredRule(for: bundleIdentifier) else { return }
        updateConfiguration { $0.applicationRules.setEnabled(isEnabled, for: bundleIdentifier) }
        statusMessage = isEnabled
            ? "\(Self.ruleApplicationName(for: bundleIdentifier)): \(rule.title)."
            : "\(Self.ruleApplicationName(for: bundleIdentifier)) is managed normally while its rule is off."
    }

    /// Moves a rule, with its participation and Enabled state, to another app, for example to repair a rule
    /// whose app is missing. Does nothing when the other app already has a rule.
    func moveRule(from bundleIdentifier: String, to replacement: String) {
        let rules = configuration.applicationRules
        guard let rule = rules.configuredRule(for: bundleIdentifier), !replacement.isEmpty,
              replacement == bundleIdentifier || rules.configuredRule(for: replacement) == nil else { return }
        let isEnabled = rules.isEnabled(for: bundleIdentifier)
        updateConfiguration {
            $0.applicationRules.clear(bundleIdentifier)
            $0.applicationRules.set(rule, for: replacement)
            $0.applicationRules.setEnabled(isEnabled, for: replacement)
        }
    }

    private static func ruleApplicationName(for bundleIdentifier: String) -> String {
        let name = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
            .map { ApplicationCatalog.displayName(for: $0, metadata: nil) }
        return ApplicationRuleAppName.displayName(bundleIdentifier: bundleIdentifier, knownName: name)
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
    /// In Bento, a window that cannot be resized or moved, such as
    /// Calculator, floats: a pane would ask it for a frame it refuses, and
    /// every placement would be rejected. Tabbed keeps such a window as a
    /// tab; its backdrop covers the rest of the pane.
    private func bentoEligible(_ windows: [WindowSnapshot]) -> [WindowSnapshot] {
        windows.filter {
            guard !confirmedMinimizedWindowIDs.contains($0.id), rule(for: $0).allowsBentoParticipation else { return false }
            if sessionStore.session(for: $0.displayID)?.mode == .tabbed { return true }
            return $0.constraints.isResizable && $0.constraints.isMovable
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
    @discardableResult
    private func restoreBentoLayout(
        session: LayoutSession,
        displayWindows: [WindowSnapshot],
        display: DisplaySnapshot,
        suspendOnRejection: Bool = false
    ) -> BentoProposalCommitResult {
        guard !session.automaticWritesSuspended else { return .rejected }
        let placements = BentoLayoutEngine(state: session.bentoState)
            .placements(for: displayWindows, in: display)
        guard !placements.isEmpty else { return .rejected }
        var proposed = session
        let commitResult = commitBentoProposal(
            placements,
            session: &proposed,
            display: display,
            surfaceFailure: false
        )
        if commitResult.result.needsRepair || (suspendOnRejection && commitResult.result == .rejected) {
            suspendAutomaticBentoWrites(
                displayID: display.id,
                sessionID: session.id,
                error: commitResult.failureReason ?? "The previous layout could not be restored."
            )
        }
        refreshDividerBoundaries()
        return commitResult.result
    }

    /// Stop the damaged session without selecting it or replacing a newer layout.
    private func suspendAutomaticBentoWrites(
        displayID: DisplayID,
        sessionID: DesktopSessionID? = nil,
        error: String,
        surfaceFailure: Bool = true
    ) {
        guard let owner = sessionID ?? sessionStore.session(for: displayID)?.id else { return }
        Self.bentoLog.error("suspending automatic Bento placement after incomplete recovery")
        sessionStore.suspendAutomaticWrites(sessionID: owner, on: displayID)
        statusMessage = sessionStore.isActive(owner, on: displayID)
            ? error + repairLayoutRecoverySuffix
            : error + " Use Repair Layout on the other desktop to rebuild the layout."
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
        workArea: BTRect? = nil,
        revalidateBeforeEachWrite: Bool = false,
        didCommitSettlement: @escaping @MainActor (LayoutSession) -> Void = { _ in },
        didDegradeSettlement: (@MainActor (String) -> Void)? = nil,
        validating ownerIsCurrent: @escaping @MainActor () -> Bool = { true }
    ) {
        guard let scheduledSession = sessionStore.session(for: displayID) else { return }
        // A clamp correction can change frames after the caller planned
        // them; the session records the frames finally written.
        let requestedFrames = requestedFrames.map { requested in
            requested.merging(scheduledSession.lastObservedFrames.filter { requested[$0.key] != nil }) { _, written in written }
        }
        let sessionID = scheduledSession.id
        let revision = scheduledSession.revision
        let recoveryGeneration = applicationRecoveryGeneration
        let recoveryFallbackMatches = applicationRecoveryFallbackMatches
        let nativeObservation = system.nativeDesktopObservation()
        let stabilizationGeneration = spaceStabilizationGeneration
        let scheduledWorkArea = system.displays().first { $0.id == displayID }?.visibleFrame
        let settlementIsCurrent = { @MainActor [weak self] in
            guard let self else { return false }
            let observation = self.system.refreshNativeDesktopObservation()
            return !Task.isCancelled && !self.isShutDown && self.hasAccessibilityPermission
                && !self.isStabilizingSpace && self.spaceStabilizationGeneration == stabilizationGeneration
                && self.sessionStore.session(for: displayID)?.id == sessionID
                && self.sessionStore.session(for: displayID)?.mode == .bento
                && self.sessionStore.session(for: displayID)?.automaticWritesSuspended == false
                && self.system.displays().first(where: { $0.id == displayID })?.visibleFrame == scheduledWorkArea
                && (observation == nil) == (nativeObservation == nil)
                && observation?.allowsAutomaticLayout(on: displayID) != false
                && observation?.currentSpace(on: displayID) == nativeObservation?.currentSpace(on: displayID)
                && ownerIsCurrent()
        }
        let mutationGenerations = Dictionary(uniqueKeysWithValues: changedWindowIDs.map {
            ($0, coordinator.mutationGeneration(for: $0))
        })
        settlementTasks[displayID]?.cancel()
        let taskGeneration = (settlementTaskGenerations[displayID] ?? 0) &+ 1
        settlementTaskGenerations[displayID] = taskGeneration
        settlementTasks[displayID] = Task { @MainActor [clock, weak self] in
            guard let self else { return }
            defer {
                if self.settlementTaskGenerations[displayID] == taskGeneration {
                    self.settlementTasks.removeValue(forKey: displayID)
                    self.settlementTaskGenerations.removeValue(forKey: displayID)
                }
            }
            var previous: [WindowID: BTRect]?
            var latestWindows: [WindowSnapshot] = []
            let started = clock.now
            for _ in 0..<8 {
                try? await clock.sleep(for: .milliseconds(40))
                // Timed before the read, so a stall after it does not age the sample.
                let elapsed = clock.now - started
                guard settlementIsCurrent(),
                      self.sessionStore.isCurrent(sessionID, revision: revision, on: displayID),
                      let sampled = try? (self.system.cachedVisibleWindows(refreshing: scheduledSession.windowIDs)
                        ?? self.observeVisibleWindows())
                else { return }
                latestWindows = sampled
                #if DEBUG
                self.arrivalTrace.observe(sampled)
                #endif
                let frames = Dictionary(uniqueKeysWithValues: sampled.filter { changedWindowIDs.contains($0.id) }.map { ($0.id, $0.frame) })
                let hasResponded = baselineFrames == nil || frames.allSatisfy { id, frame in
                    guard let baseline = baselineFrames?[id] else { return false }
                    return requestedFrames?[id]?.approximatelyEquals(baseline, tolerance: 1) == true
                        || !frame.approximatelyEquals(baseline, tolerance: 1)
                }
                if let previous, frames.count == changedWindowIDs.count,
                   hasResponded,
                   frames.allSatisfy({ id, frame in previous[id]?.approximatelyEquals(frame, tolerance: 1) == true }),
                   !Self.awaitsClampConfirmation(
                       sampled, changed: changedWindowIDs, requested: requestedFrames, elapsed: elapsed
                   ) {
                    break
                }
                previous = frames
            }
            guard !Task.isCancelled else { return }
            self.coordinator.finishExpectedMutations(upTo: mutationGenerations)
            // Delayed recovery corrections keep the original desktop guard.
            let previousRecoveryGeneration = self.applicationRecoveryGeneration
            let previousFallbackMatches = self.applicationRecoveryFallbackMatches
            self.applicationRecoveryGeneration = recoveryGeneration
            self.applicationRecoveryFallbackMatches = recoveryFallbackMatches
            defer {
                self.applicationRecoveryGeneration = previousRecoveryGeneration
                self.applicationRecoveryFallbackMatches = previousFallbackMatches
            }
            self.correctBentoAfterSettlement(
                displayID: displayID,
                sessionID: sessionID,
                revision: revision,
                changedWindowIDs: changedWindowIDs,
                windows: latestWindows,
                requestedFrames: requestedFrames,
                baselineFrames: baselineFrames,
                isAuthoritative: isAuthoritative,
                workArea: workArea,
                revalidateBeforeEachWrite: revalidateBeforeEachWrite,
                didCommitSettlement: didCommitSettlement, didDegradeSettlement: didDegradeSettlement, validating: settlementIsCurrent
            )
        }
    }

    /// True while a changed window that settled larger than requested, and
    /// larger than its known minimum, can still be a pending clamp. The
    /// minimum-size learner confirms one only
    /// `WindowMinimumSizeLearner.clampConfirmationDelay` after the write, so
    /// settlement samples until then and the confirmed minimum reaches the
    /// correction below.
    nonisolated static func awaitsClampConfirmation(
        _ windows: [WindowSnapshot],
        changed: Set<WindowID>,
        requested: [WindowID: BTRect]?,
        elapsed: Duration
    ) -> Bool {
        guard let requested, elapsed < .seconds(WindowMinimumSizeLearner.clampConfirmationDelay) else { return false }
        return windows.contains { window in
            // A fixed-size window keeps its size; that is no pending clamp.
            guard changed.contains(window.id), window.constraints.isResizable,
                  let frame = requested[window.id] else { return false }
            let size = window.frame.size, minimum = window.constraints.minimumSize
            return (size.width > frame.size.width + 2 && minimum.width < size.width - 2)
                || (size.height > frame.size.height + 2 && minimum.height < size.height - 2)
        }
    }

    /// True when a window's constraints now require a larger minimum than
    /// they did in `earlier`.
    nonisolated static func gainedMinimumSize(_ windows: [WindowSnapshot], since earlier: [WindowSnapshot]) -> Bool {
        let before = Dictionary(earlier.map { ($0.id, $0.constraints.minimumSize) }, uniquingKeysWith: { first, _ in first })
        return windows.contains { window in
            guard let minimum = before[window.id] else { return false }
            return window.constraints.minimumSize.width > minimum.width + 0.5
                || window.constraints.minimumSize.height > minimum.height + 0.5
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
        workArea: BTRect?,
        revalidateBeforeEachWrite: Bool = false,
        didCommitSettlement: @escaping @MainActor (LayoutSession) -> Void = { _ in },
        didDegradeSettlement: (@MainActor (String) -> Void)? = nil,
        validating ownerIsCurrent: @escaping @MainActor () -> Bool
    ) {
        guard ownerIsCurrent(), sessionStore.isCurrent(sessionID, revision: revision, on: displayID),
              var session = sessionStore.session(for: displayID), session.mode == .bento,
              let display = system.displays().first(where: { $0.id == displayID })
        else { return }
        #if DEBUG
        defer { if arrivalTrace.isEnabled { arrivalTrace.settled(windows.filter { changedWindowIDs.contains($0.id) }) } }
        #endif
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
            if learnedMinimum, let refreshed = try? observeVisibleWindows() {
                settledWindows = refreshed
            }
        }
        // The write's readback may already have measured the minimum that
        // made a window settle larger than requested. That is the same
        // evidence; the layout must still be solved around it.
        if !learnedMinimum, let requestedFrames {
            learnedMinimum = windows.contains { window in
                guard changedWindowIDs.contains(window.id), let requested = requestedFrames[window.id] else { return false }
                let minimum = window.constraints.minimumSize
                return (window.frame.size.width > requested.size.width + 2 && minimum.width >= window.frame.size.width - 2)
                    || (window.frame.size.height > requested.size.height + 2 && minimum.height >= window.frame.size.height - 2)
            }
        }

        let displayWindows = settledWindows.filter { session.windowIDs.contains($0.id) && $0.displayID == displayID }
        // A lone window owns a native divider edit, but an authoritative
        // transfer or reflow must still verify its requested frame.
        guard isAuthoritative || displayWindows.count > 1 else {
            refreshDividerBoundaries()
            return
        }
        let frames = Dictionary(uniqueKeysWithValues: displayWindows.map { ($0.id, $0.frame) })
        let constraints = Dictionary(uniqueKeysWithValues: displayWindows.map { ($0.id, $0.constraints) })
        Self.bentoLog.debug("settlement branch: \(learnedMinimum ? "minimum-size resolve" : "layout fit", privacy: .public)")
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
                surfaceFailure: false, revalidateBeforeEachWrite: revalidateBeforeEachWrite,
                didCommitSettlement: didCommitSettlement, validating: ownerIsCurrent
            )
            if commitResult.result.needsRepair {
                let reason = commitResult.failureReason ?? "Adaptive could not fit this window's minimum size."
                if let didDegradeSettlement { didDegradeSettlement(reason) }
                else { suspendAutomaticBentoWrites(displayID: displayID, sessionID: session.id, error: reason) }
            } else if commitResult.result == .rejected, isAuthoritative,
                      let didDegradeSettlement, ownerIsCurrent() {
                // Undoing this correction can restore an already-overlapping
                // transfer baseline. Only its current owners may be stopped.
                didDegradeSettlement(commitResult.failureReason ?? "Adaptive could not fit this window's minimum size.")
            } else if commitResult.result == .committed, isAuthoritative || workArea != nil {
                // Transfers own their correction even without a work-area change.
                // A synchronous clamp solve may have changed the final requests.
                let committedPlacements = placements.map {
                    Placement(windowID: $0.windowID, frame: session.lastObservedFrames[$0.windowID] ?? $0.frame)
                }
                scheduleAuthoritativePlacementSettlement(
                    displayID: displayID,
                    sessionID: sessionID,
                    workArea: workArea ?? display.visibleFrame,
                    placements: committedPlacements,
                    revalidateBeforeEachWrite: revalidateBeforeEachWrite,
                    didCommitSettlement: didCommitSettlement, didDegradeSettlement: didDegradeSettlement, validating: ownerIsCurrent
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
            let tiledFrames = frames.filter { !session.bentoState.floatingWindowIDs.contains($0.key) }
            if !BentoLayoutVerifier.overlappingWindowIDs(tiledFrames).isEmpty
                || placements.contains(where: { frames[$0.windowID]?.approximatelyEquals($0.frame, tolerance: 2) != true }) {
                scheduleAuthoritativePlacementSettlement(
                    displayID: displayID,
                    sessionID: sessionID,
                    workArea: workArea ?? display.visibleFrame,
                    placements: placements,
                    revalidateBeforeEachWrite: revalidateBeforeEachWrite,
                    didCommitSettlement: didCommitSettlement, didDegradeSettlement: didDegradeSettlement, validating: ownerIsCurrent
                )
            } else if let workArea {
                session.lastWorkArea = workArea
                session.recordProposedFrames(requestedFrames)
                if let committed = sessionStore.commit(session, replacing: revision) { didCommitSettlement(committed) }
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
                surfaceFailure: false, revalidateBeforeEachWrite: revalidateBeforeEachWrite,
                didCommitSettlement: didCommitSettlement, validating: ownerIsCurrent
            )
            if commitResult.result.needsRepair {
                let reason = commitResult.failureReason ?? "Adaptive could not adopt the settled divider."
                if let didDegradeSettlement { didDegradeSettlement(reason) }
                else { suspendAutomaticBentoWrites(displayID: displayID, sessionID: session.id, error: reason) }
            }
        }
        refreshDividerBoundaries()
    }

    private func refreshActiveWindows(
        force: Bool,
        windows suppliedWindows: [WindowSnapshot]? = nil,
        revalidatesSuppliedWindows: Bool = false,
        desktopTransition: Bool = false,
        recoveryFrameResults: [WindowID: RecoveryFrameResult]? = nil,
        relayoutPaneGap: Bool = false
    ) {
        guard !isShutDown else { return }
        let isPaneGapOnlyRefresh = relayoutPaneGap
        let relayoutPaneGap = relayoutPaneGap
            || (paneGapRelayoutPending && paneGapBeforeRelayout == nil && canRelayoutPaneGap)
        guard !isStabilizingSpace || desktopTransition else { return }
        guard activeBentoDrag == nil else {
            pendingWindowEvents.recordTopologyChange()
            return
        }
        guard hasAccessibilityPermission || refreshPermission(recoverWindows: false) else {
            activeDisplayID = system.displays().first(where: \.isMain)?.id
            return
        }
        let priorRecoveryGeneration = applicationRecoveryGeneration
        if applicationRecoveryGeneration == nil,
           !applicationRecoveryPendingWindows.isEmpty || !applicationRecoveryFrameEventPIDs.isEmpty
               || !system.unresponsiveApplicationRecoveryDeadlines.isEmpty {
            applicationRecoveryGeneration = spaceStabilizationGeneration
        }
        defer { applicationRecoveryGeneration = priorRecoveryGeneration }
        if let request = paneApplicationRequest, !paneApplicationOwnerIsCurrent(request) {
            cancelPaneApplicationRequest(id: request.id)
        }
        guard var observedWindows = suppliedWindows ?? (try? observeVisibleWindows(reconcilesRecovery: true)) else { return }
        // Classification can outlast a Space change whose notification is still queued, so a reused
        // inventory needs fresh native membership for every window. Without it, observe again.
        let revalidates = revalidatesSuppliedWindows && suppliedWindows != nil
        let nativeObservation = revalidates ? system.refreshNativeDesktopObservation() : system.nativeDesktopObservation()
        if revalidates, nativeObservation.map({ observation in
            observedWindows.contains { $0.isEligible && observation.windowMembership[$0.id]?.isEmpty != false }
        }) ?? true {
            guard let reobserved = try? observeVisibleWindows(reconcilesRecovery: true) else { return }
            observedWindows = reobserved
        }
        #if DEBUG
        arrivalTrace.observe(observedWindows)
        if arrivalTrace.isEnabled { for window in observedWindows {
            arrivalTrace.disposition("reconciliation_started", windowID: window.id, reason: "active_windows")
        } }
        #endif
        defer { scheduleUnresponsiveApplicationRecovery() }
        recordObservedWindows(observedWindows, observation: nativeObservation)
        if nativeObservation == nil { discardSpacePanelOverlays() }
        let windows = nativeObservation?.windowsOnCurrentSpaces(observedWindows) ?? observedWindows
        let previousFallbackMatches = applicationRecoveryFallbackMatches
        defer { applicationRecoveryFallbackMatches = previousFallbackMatches }
        prepareApplicationRecoverySessions(windows: windows)
        // The event pass supplies its results to avoid re-entering classification.
        if !desktopTransition, recoveryFrameResults == nil,
           windows.contains(where: { applicationRecoveryFrameEventPIDs[$0.id] == $0.processIdentifier }) {
            pendingWindowEvents.recordTopologyChange()
            processPendingWindowEvents(windows: windows, forceRefresh: force)
            return
        }
        let unresolvedRecoveryWindows = windows.filter {
            recoveryFrameResults != nil
                && applicationRecoveryFrameEventPIDs[$0.id] == $0.processIdentifier
                && recoveryFrameResults?[$0.id]?.isHandled != true
        }
        let unmatchedRecoveryDisplays = sessionStore.sessions.values.filter {
            applicationRecoveryFallbackMatches[$0.id] == false
        }.map(\.displayID)
        let unresolvedRecoveryDisplays = Set(unresolvedRecoveryWindows.map(\.displayID)).union(unmatchedRecoveryDisplays)
        pendingWindowEvents.recordFrameChanges(Set(unresolvedRecoveryWindows.map(\.id)))
        // Destroyed-window identifiers are a batch consumed by exactly one
        // completed sweep. Capturing here means an early return above leaves
        // them pending for the next attempt, while identifiers belonging to
        // manual-mode desktops or sessions that were never initialised still
        // expire at the end of this sweep instead of accumulating forever.
        let consumedRecoveryWindows = applicationRecoveryPendingWindows.filter { id, pid in
            windows.contains { $0.id == id && $0.processIdentifier == pid }
        }
        let consumedDestroyedWindowIDs = confirmedGoneWindowIDs
        let consumedMinimizedWindowIDs = confirmedMinimizedWindowIDs
        #if DEBUG
        if arrivalTrace.isEnabled {
            for window in windows where !window.isEligible || window.isFloating {
                arrivalTrace.disposition("arrival_dropped", windowID: window.id, reason: "ineligible_or_floating")
            }
        }
        #endif
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
        for id in automaticResultPills.keys.filter({ !displayIDs.contains($0) }) {
            automaticResultPills.removeValue(forKey: id)?.hide()
        }
        for id in tabbedOverlays.keys.filter({ !displayIDs.contains($0) }) {
            tabbedOverlays[id]?.hide()
            tabbedOverlays.removeValue(forKey: id)
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
        forgetEndedTabbedSessions(displayIDs: displayIDs)
        var resolvedActiveDisplay: DisplayID?
        var sweepCommitted = true
        var sweepNeedsRetry = false
        var deferredWindowIDs: Set<WindowID> = []
        let ambientReconciler = AmbientLayoutReconciler(
            paneGap: paneGapForLayout,
            adjacencyTolerance: configuration.adjacencyTolerance,
            singleWindowPlacement: configuration.singleWindowPlacement,
            newWindowSide: configuration.bentoNewWindowSide,
            balancesNewWindows: configuration.bentoBalancesNewWindows
        )

        for display in displays {
            if isPaneGapOnlyRefresh {
                guard sessionStore.session(for: display.id)?.mode == .bento else { continue }
            }
            if savedLayoutApplier?.ownedDisplayID == display.id { continue }
            // A shared layout cannot admit arrivals over an unresolved native snap.
            if unresolvedRecoveryDisplays.contains(display.id),
               sessionStore.session(for: display.id)?.mode == .bento,
               sessionStore.session(for: display.id)?.automaticWritesSuspended == false {
                if let session = sessionStore.session(for: display.id) {
                    deferredWindowIDs.formUnion(session.windowIDs)
                    deferredWindowIDs.formUnion(session.bentoState.root?.windowIDs ?? [])
                    deferredWindowIDs.formUnion(session.bentoState.floatingWindowIDs)
                }
                continue
            }
            var displayWindows = bentoEligible(eligible.filter { $0.displayID == display.id })
            let activation = sessionStore.activate(
                displayID: display.id,
                windowIDs: Set(displayWindows.map(\.id)),
                focusedWindowID: focused?.displayID == display.id ? focused?.id : nil,
                defaultMode: configuration.defaultLayoutMode,
                reuseActiveWhenUnmatched: !desktopTransition,
                commitObservation: false,
                nativeSpaceID: nativeObservation?.currentSpace(on: display.id)
            )
            selectTabbedOverlay(for: activation.session)
            if focused?.displayID == display.id { resolvedActiveDisplay = display.id }
            #if DEBUG
            if arrivalTrace.isEnabled {
                let reason: String? = if activation.session.automaticWritesSuspended { "automatic_writes_suspended" }
                    else if focusRestoreSessionIDs.contains(activation.session.id) { "focus_restore" }
                    else if nativeObservation?.allowsAutomaticLayout(on: display.id) == false { "native_space_disallows_layout" }
                    else { nil }
                if let reason {
                    for window in displayWindows { arrivalTrace.disposition("arrival_deferred", windowID: window.id, reason: reason) }
                }
            }
            #endif
            if focusRestoreSessionIDs.contains(activation.session.id) {
                let committed = sessionStore.commit(
                    activation.session,
                    replacing: activation.session.revision
                ) != nil
                sweepCommitted = sweepCommitted && committed
                sweepNeedsRetry = sweepNeedsRetry || !committed
                continue
            }
            if nativeObservation?.allowsAutomaticLayout(on: display.id) == false {
                hideTabbedOverlay(on: display.id)
                let committed = sessionStore.commit(
                    activation.session,
                    replacing: activation.session.revision
                ) != nil
                sweepCommitted = sweepCommitted && committed
                sweepNeedsRetry = sweepNeedsRetry || !committed
                continue
            }
            // A window that just appeared on a managed desktop is measured
            // before it is placed, so its first placement and every later
            // preview use its real minimum. Entering a mode or returning to a
            // desktop measures nothing: those windows are already visible.
            if activation.session.mode != .manual, !activation.wasCreated, !desktopTransition,
               !activation.session.automaticWritesSuspended {
                let known = activation.previousWindowIDs
                let arrivals = Set(displayWindows.filter { !reservesPaneApplicationWindow($0) }.map(\.id)).subtracting(known)
                if !arrivals.isEmpty {
                    #if DEBUG
                    if arrivalTrace.isEnabled { for id in arrivals {
                        arrivalTrace.disposition("arrival_probe_preflight_started", windowID: id, reason: "current_desktop")
                    } }
                    #endif
                    let originalFrames = displayWindows.filter { arrivals.contains($0.id) }
                        .map { Placement(windowID: $0.id, frame: $0.frame) }
                    if case let .degraded(reason) = coordinator.probeMinimumSizes(for: arrivals, validating: {
                        self.recoveryDesktopIsCurrent(for: activation.session)
                            && self.sessionStore.isCurrent(activation.session.id,
                                revision: activation.session.revision, on: display.id)
                    }) {
                        // A window can float without another write, so put
                        // it back now instead of relying on its placement.
                        Self.bentoLog.error("\(reason, privacy: .private)")
                        if !coordinator.applyPlacements(originalFrames, recordHistory: false, revalidateBeforeEachWrite: applicationRecoveryGeneration != nil, validating: {
                            self.recoveryDesktopIsCurrent(for: activation.session)
                                && self.sessionStore.isCurrent(activation.session.id,
                                    revision: activation.session.revision, on: display.id)
                        }).isApplied {
                            suspendAutomaticBentoWrites(displayID: display.id, sessionID: activation.session.id, error: reason)
                            sweepCommitted = false
                            continue
                        }
                    }
                    if let measured = try? system.windowSnapshots(ids: arrivals) {
                        let byID = Dictionary(measured.map { ($0.id, $0) }) { first, _ in first }
                        displayWindows = displayWindows.map { byID[$0.id] ?? $0 }
                    }
                }
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
            hideTabbedOverlay(on: display.id)
            let shouldLogHeldAbsences = activation.session.mode == .bento
                && !activation.session.automaticWritesSuspended
                && !activation.wasCreated
                && !desktopTransition
                && activation.session.isBentoInitialized
            #if DEBUG
            if arrivalTrace.isEnabled { for window in displayWindows {
                arrivalTrace.disposition("adaptive_plan_started", windowID: window.id, reason: "ambient_reconcile")
            } }
            #endif
            let arrivalSession = activation.session
            let transition = ambientReconciler.transition(
                session: arrivalSession,
                observation: AmbientLayoutObservation(
                    display: display,
                    windows: displayWindows,
                    wasCreated: activation.wasCreated,
                    previousWindowIDs: activation.previousWindowIDs,
                    isDesktopTransition: desktopTransition,
                    requestsRelayout: relayoutPaneGap,
                    confirmedGone: consumedDestroyedWindowIDs,
                    confirmedMinimized: consumedMinimizedWindowIDs,
                    knownSpaceWindowIDs: (nativeObservation?.exclusiveWindowIDs(on: display.id) ?? [])
                        .subtracting(eligible.filter { $0.displayID != display.id }.map(\.id))
                )
            )
            if shouldLogHeldAbsences {
                logHeldAbsences(in: transition.session)
            }
            // A desktop-switch sweep keeps the stored tree. A window that
            // arrived with the switch, for example dragged here in Mission
            // Control, joins in a normal sweep once the switch settles.
            if desktopTransition, activation.session.mode == .bento, activation.session.isBentoInitialized {
                let layout = transition.session.bentoState
                let known = Set(layout.root?.windowIDs ?? []).union(layout.floatingWindowIDs)
                if !Set(displayWindows.map(\.id)).subtracting(known).isEmpty {
                    scheduleArrivalSweep()
                }
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
                sweepNeedsRetry = sweepNeedsRetry || (result.result != .committed
                    && (result.result != .stale
                        || !sessionStore.isCurrent(session.id, revision: session.revision, on: display.id)))
                if result.result.needsRepair {
                    suspendAutomaticBentoWrites(
                        displayID: display.id,
                        sessionID: session.id,
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
                sweepNeedsRetry = sweepNeedsRetry || (result.result != .committed
                    && (result.result != .stale
                        || !sessionStore.isCurrent(session.id, revision: session.revision, on: display.id)))
                if result.result.needsRepair {
                    suspendAutomaticBentoWrites(
                        displayID: display.id,
                        sessionID: session.id,
                        error: result.failureReason ?? "Adaptive could not follow the desktop update."
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
                #if DEBUG
                if arrivalTrace.isEnabled {
                    for id in session.bentoState.floatingWindowIDs {
                        arrivalTrace.disposition("arrival_dropped", windowID: id, reason: "adaptive_floating_policy")
                    }
                }
                #endif
                let committed = sessionStore.commit(session, replacing: session.revision) != nil
                sweepCommitted = sweepCommitted && committed
                sweepNeedsRetry = sweepNeedsRetry || !committed
            }
            announceBentoOverflow(before: activation.session, on: display, windows: displayWindows)
        }
        if sweepCommitted {
            if !desktopTransition {
                for display in displays where tabbedTasks[display.id] == nil
                    && !unresolvedRecoveryDisplays.contains(display.id) {
                    guard let session = sessionStore.session(for: display.id), session.mode != .tabbed,
                          !focusRestoreSessionIDs.contains(session.id) else { continue }
                    completeApplicationRecoveryReconciliation(
                        windows: windows.filter { consumedRecoveryWindows[$0.id] == $0.processIdentifier },
                        session: session
                    )
                }
            }
            confirmedGoneWindowIDs.subtract(consumedDestroyedWindowIDs.subtracting(deferredWindowIDs))
            // A desktop-transition sweep deliberately does not reconcile its
            // stored tree. Retain minimize evidence for the first normal sweep
            // so the reducer can still capture the pane's reinsertion anchor.
            if !desktopTransition {
                let stillReportedVisible = Set(windows.filter(\.isEligible).map(\.id))
                confirmedMinimizedWindowIDs.subtract(
                    consumedMinimizedWindowIDs.subtracting(stillReportedVisible).subtracting(deferredWindowIDs)
                )
            }
        } else {
            pendingWindowEvents.recordTopologyChange()
            if sweepNeedsRetry { schedulePendingWindowEvents() }
        }
        activeDisplayID = resolvedActiveDisplay
            ?? activeDisplayID.flatMap { current in displays.contains(where: { $0.id == current }) ? current : nil }
            ?? displays.first(where: { !(sessionStore.session(for: $0.id)?.windowIDs.isEmpty ?? true) })?.id
            ?? displays.first(where: \.isMain)?.id
        if desktopTransition, windows.contains(where: { applicationRecoveryPendingWindows[$0.id] == $0.processIdentifier }) {
            pendingWindowEvents.recordTopologyChange()
            schedulePendingWindowEvents()
        }
        system.updateManagedWindowIDs(Set(eligible.map(\.id)).union(sessionStore.sessions.values.flatMap { $0.tabbedState?.windowIDs ?? [] }))
        refreshDividerBoundaries(windows: eligible)
        if relayoutPaneGap, sweepCommitted { completePendingPaneGapIfApplied() }
    }

    private func scheduleAuthoritativePlacementSettlement(
        displayID: DisplayID,
        sessionID: DesktopSessionID,
        workArea: BTRect,
        placements: [Placement],
        revalidateBeforeEachWrite: Bool = false,
        didCommitSettlement: @escaping @MainActor (LayoutSession) -> Void = { _ in },
        didDegradeSettlement: (@MainActor (String) -> Void)? = nil,
        validating ownerIsCurrent: @escaping @MainActor () -> Bool = { true }
    ) {
        guard let scheduledSession = sessionStore.session(for: displayID),
              scheduledSession.id == sessionID
        else { return }
        let revision = scheduledSession.revision
        let recoveryGeneration = applicationRecoveryGeneration
        let recoveryFallbackMatches = applicationRecoveryFallbackMatches
        let nativeObservation = system.nativeDesktopObservation()
        let stabilizationGeneration = spaceStabilizationGeneration
        settlementTasks[displayID]?.cancel()
        let taskGeneration = (settlementTaskGenerations[displayID] ?? 0) &+ 1
        settlementTaskGenerations[displayID] = taskGeneration
        let ownedGenerations = Dictionary(uniqueKeysWithValues: placements.map {
            ($0.windowID, coordinator.mutationGeneration(for: $0.windowID))
        })
        settlementTasks[displayID] = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.settlementTaskGenerations[displayID] == taskGeneration {
                    self.settlementTasks.removeValue(forKey: displayID)
                    self.settlementTaskGenerations.removeValue(forKey: displayID)
                }
            }
            let settlementIsCurrent = { @MainActor in
                let observation = self.system.refreshNativeDesktopObservation()
                guard !Task.isCancelled, !self.isShutDown, self.hasAccessibilityPermission,
                      !self.isStabilizingSpace, self.spaceStabilizationGeneration == stabilizationGeneration,
                      self.sessionStore.isCurrent(sessionID, revision: revision, on: displayID),
                      let current = self.sessionStore.session(for: displayID), current.mode == .bento,
                      !current.automaticWritesSuspended,
                      self.system.displays().contains(where: { $0.id == displayID && $0.visibleFrame == workArea }),
                      (observation == nil) == (nativeObservation == nil),
                      observation?.allowsAutomaticLayout(on: displayID) != false,
                      observation?.currentSpace(on: displayID) == nativeObservation?.currentSpace(on: displayID),
                      ownerIsCurrent()
                else { return false }
                guard let recoveryGeneration else { return true }
                let previousRecoveryGeneration = self.applicationRecoveryGeneration
                let previousFallbackMatches = self.applicationRecoveryFallbackMatches
                self.applicationRecoveryGeneration = recoveryGeneration
                self.applicationRecoveryFallbackMatches = recoveryFallbackMatches
                defer {
                    self.applicationRecoveryGeneration = previousRecoveryGeneration
                    self.applicationRecoveryFallbackMatches = previousFallbackMatches
                }
                return self.recoveryDesktopIsCurrent(for: scheduledSession)
                    && self.sessionStore.isCurrent(sessionID, revision: revision, on: displayID)
            }
            let outcome = await self.coordinator.settleAuthoritativePlacements(placements, since: ownedGenerations,
                floatingWindowIDs: scheduledSession.bentoState.floatingWindowIDs,
                revalidateBeforeEachWrite: revalidateBeforeEachWrite || recoveryGeneration != nil, validating: settlementIsCurrent)
            let isDegraded = if case .degraded = outcome { true } else { false }
            guard isDegraded || settlementIsCurrent()
            else { return }

            switch outcome {
            case .applied:
                let frames = Dictionary(uniqueKeysWithValues: placements.map { ($0.windowID, $0.frame) })
                if var current = self.sessionStore.session(for: displayID) {
                    current.lastWorkArea = workArea
                    current.recordProposedFrames(frames)
                    if let committed = self.sessionStore.commit(current, replacing: revision) { didCommitSettlement(committed) }
                }
            case let .degraded(reason):
                if let didDegradeSettlement { didDegradeSettlement(reason) }
                else { self.suspendAutomaticBentoWrites(displayID: displayID, sessionID: sessionID, error: reason) }
            case let .failed(reason):
                // A transfer still owns both desktops when bounded verification
                // fails, even if every retry call returned without an AX error.
                if let didDegradeSettlement {
                    didDegradeSettlement(reason)
                    self.refreshDividerBoundaries()
                    return
                }
                if let windows = try? self.observeVisibleWindows() {
                    let placementIDs = Set(placements.map(\.windowID))
                    let actualFrames = Dictionary(uniqueKeysWithValues: windows.compactMap { window in
                        placementIDs.contains(window.id) ? (window.id, window.frame) : nil
                    })
                    if var current = self.sessionStore.session(for: displayID) {
                        current.recordProposedFrames(actualFrames)
                        if let committed = self.sessionStore.commit(current, replacing: revision) { didCommitSettlement(committed) }
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
            paneGap: session.paneGap(configured: paneGapForLayout),
            confirmedGone: confirmedGone,
            minimized: minimized.union(confirmedMinimizedWindowIDs),
            knownSpaceWindowIDs: system.nativeDesktopObservation()?.exclusiveWindowIDs(on: display.id) ?? [],
            newWindowSide: configuration.bentoNewWindowSide,
            balancesNewWindows: configuration.bentoBalancesNewWindows
        )
        guard case let .update(updated, _, _) = transition else { return }
        session = updated
        logHeldAbsences(in: session)
    }

    private func logHeldAbsences(in session: LayoutSession) {
        if !session.presence.pending.isEmpty {
            Self.bentoLog.debug("holding absent panes until closure is confirmed")
            scheduleAbsenceConfirmation()
        }
    }

    private func scheduleArrivalSweep() {
        guard arrivalSweepTask == nil, !isShutDown else { return }
        arrivalSweepTask = Task { @MainActor [clock, weak self] in
            try? await clock.sleep(for: .milliseconds(400))
            guard let self, !Task.isCancelled else { return }
            self.arrivalSweepTask = nil
            self.pendingWindowEvents.recordTopologyChange()
            self.schedulePendingWindowEvents()
        }
    }

    /// Some applications keep a closed document window alive off screen, so
    /// no destroyed event arrives and closure waited for the watchdog's
    /// sweeps. While a pane is missing, sweep again shortly so the required
    /// consecutive misses accumulate in under a second.
    private func scheduleAbsenceConfirmation() {
        guard absenceConfirmationTask == nil, !isShutDown else { return }
        absenceConfirmationTask = Task { @MainActor [clock, weak self] in
            try? await clock.sleep(for: .milliseconds(250))
            guard let self, !Task.isCancelled else { return }
            self.absenceConfirmationTask = nil
            self.pendingWindowEvents.recordTopologyChange()
            self.schedulePendingWindowEvents()
        }
    }

    private func displayWorkAreaSignature(_ displays: [DisplaySnapshot]) -> String {
        displays.sorted { $0.id < $1.id }.map { display in
            let frame = display.visibleFrame
            return "\(display.id.rawValue):\(frame.minX):\(frame.minY):\(frame.size.width):\(frame.size.height):\(display.scaleFactor)"
        }.joined(separator: "|")
    }

    /// Gestures keep measured minimums, so a drag preview stops where
    /// release stops. A minimum is not a permanent floor: every write reads
    /// the real size back, and any accepted smaller size, including the
    /// user's own edge resize, lowers it at once.
    /// Divider and linked-resize gestures do not name a display, so they
    /// cancel every pending Focus mode restore.
    func prepareWindowGesture() {
        invalidateMenuPanelFocusReplay()
        cancelPendingFocusRestore(on: nil)
    }

    private func refreshDividerBoundaries(windows suppliedWindows: [WindowSnapshot]? = nil) {
        let presentation = dividerPresentation(windows: suppliedWindows ?? ((try? observeVisibleWindows()) ?? []))
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
        let chrome = allTabbedOverlays.reduce(into: Set<Int>()) { $0.formUnion($1.windowNumbers) }
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

    /// - Parameter feedback: A pill that already says what went wrong,
    ///   used instead of one read from `error`.
    private func presentActionResult(
        succeeded: Bool,
        error: String? = nil,
        successMessage: String? = nil,
        feedback: ResultPillFeedback? = nil,
        displayID: DisplayID?
    ) {
        let feedback = feedback ?? (succeeded
            ? successMessage.map(ResultPillFeedback.success) ?? ResultPillFeedback.success()
            : ResultPillFeedback.failure(error))
        lastActionFeedback = feedback
        let displays = system.displays()
        if let displayID, !displays.contains(where: { $0.id == displayID }) { return }
        guard let display = displayID.flatMap({ id in displays.first { $0.id == id } })
                ?? displays.first(where: \.isMain)
                ?? displays.first
        else { return }
        let controller = resultPill ?? resultPillFactory()
        resultPill = controller
        controller.overlayAppearance = configuration.overlayAppearance
        controller.show(feedback, on: display)
    }

    private func startPermissionPolling() {
        permissionPollTask?.cancel()
        permissionPollTask = Task { @MainActor [clock, weak self] in
            for _ in 0..<120 {
                try? await clock.sleep(for: .milliseconds(500))
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
    case desktop(LayoutWheelCommand)
    case action(WindowActionPlan)
    case bento(BentoCommandProposal)
    case tabbed(TabbedSnapPlan, WindowAction, DisplayID)
    case tabCommand(WindowAction, DisplayID)
    case repairBento(displayID: DisplayID, focusedWindowID: WindowID)
}

private struct BentoDisplayTransferProposal {
    var source: LayoutSession
    var destination: LayoutSession
    var sourceDisplay: DisplaySnapshot
    var destinationDisplay: DisplaySnapshot
    var sourcePlacements: [Placement]
    var destinationPlacements: [Placement]
    var windows: [WindowSnapshot]
    var floats: Bool
    var floatingMessage: String?
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

/// The Tabbed arrangement a drag overlay showed, with the window snapshots it
/// was planned from. Release places exactly this.
private struct PreparedTabbedArrangement {
    var state: TabbedLayoutState
    var windows: [WindowSnapshot]
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
    /// A pending Tabbed re-application the gesture took over.
    var droppedTabbedReapply = false
}

private struct TabbedCommittedLayout: Equatable {
    var paneFrames: [UUID: BTRect]
    var selected: Set<WindowID>
}

private struct TabbedUndoStep {
    var state: TabbedLayoutState
    var floatingFrames: [WindowID: BTRect] = [:]
}

private enum PendingTabbedIntent {
    case ui(TabbedUIIntent)
    case snap(WindowID, WindowAction, NativeSpaceID?)
    case command(WindowAction, WindowID, NativeSpaceID?)
}

// MARK: - Experimental Tabbed sessions
extension BetterTileModel {
    private func refreshTabbedSession(
        _ original: LayoutSession, display: DisplaySnapshot, windows: [WindowSnapshot],
        removed: Set<WindowID>, focused: WindowID?, force: Bool
    ) {
        guard tabbedTasks[display.id] == nil else {
            #if DEBUG
            if arrivalTrace.isEnabled { for window in windows {
                arrivalTrace.disposition("arrival_deferred", windowID: window.id, reason: "tabbed_reconciliation_in_progress")
            } }
            #endif
            tabbedNeedsRefresh.insert(display.id)
            return
        }
        // A requested arrival goes directly to its final pane before ordinary
        // reconciliation can run an intermediate placement of the old selections.
        if let request = paneApplicationRequest, request.displayID == display.id,
           automaticallyPlacePaneApplicationArrival(request, windows: windows) { return }
        #if DEBUG
        if arrivalTrace.isEnabled { for window in windows {
            arrivalTrace.disposition("tabbed_plan_started", windowID: window.id, reason: "reconcile_membership")
        } }
        #endif
        // Plan with the same minimums the placement uses.
        let windows = ignoringOversizedSeeds(windows, in: display.visibleFrame)
        var session = original
        let wasUninitialized = session.tabbedState == nil
        var state = session.tabbedState ?? TabbedLayoutState(preset: configuration.defaultTabbedPreset, presentation: configuration.tabbedStripPresentation)
        let entering = !session.tabbedHasEntryBaseline
        if entering {
            if tabbedEntryBaselines[session.id] == nil {
                // A desktop that starts in Tabbed has no prior managed mode.
                var baseline = original
                baseline.mode = .manual
                tabbedEntryBaselines[session.id] = baseline
            }
            session.tabbedHasEntryBaseline = true
            session.tabbedBaselineFrames = Dictionary(uniqueKeysWithValues: windows.map { ($0.id, $0.frame) })
            // Stored now, so a failed or deferred entry placement does not run
            // the entry again on every later sweep.
            if let committed = sessionStore.commit(session, replacing: session.revision) { session = committed }
        }
        let before = state
        reservePaneApplicationArrivals(in: &state, session: session, windows: windows)
        state.setPresentation(configuration.tabbedStripPresentation)
        if wasUninitialized {
            state.reconcile(windowIDs: windows.map(\.id), removed: removed, focused: focused)
        } else {
            let arrivals = state.reconcile(windowIDs: windows.map(\.id), removed: removed,
                                           fittingIn: display.visibleFrame, windows: windows, followed: session.followed)
            logTabbedAdoptions(arrivals, transition: entering ? "entry arrival" : "arrival",
                               before: before, windows: windows, bounds: display.visibleFrame)
            // Entering Tabbed, from Bento or Native, offers the windows that
            // floated on their own a pane again: the panes changed since.
            if entering, !state.automaticallyFloatingWindowIDs.isEmpty {
                let returning = state
                let returned = state.returnAutomaticFloats(state.automaticallyFloatingWindowIDs,
                                                           fittingIn: display.visibleFrame, windows: windows,
                                                           selecting: true, keeping: focused ?? state.activeWindowID, followed: session.followed)
                logTabbedAdoptions(returned, transition: "entry return", before: returning,
                                   windows: windows, bounds: display.visibleFrame)
            }
        }
        session.tabbedState = state
        session.windowIDs = state.windowIDs
        // A new window that fits no pane floats. Move it fully onto the work
        // area at its own size when it can be, and say why it is not a tab.
        let floated = wasUninitialized ? [] : state.floatingWindowIDs
            .subtracting(before.floatingWindowIDs).subtracting(before.windowIDs)
            .intersection(state.automaticallyFloatingWindowIDs)
        var restorationFrames: [WindowID: BTRect] = [:]
        for window in windows where floated.contains(window.id) {
            let bounds = display.visibleFrame
            guard window.frame.size.width <= bounds.size.width, window.frame.size.height <= bounds.size.height,
                  !PlacementBounds.isContained(window.frame, in: bounds) else { continue }
            restorationFrames[window.id] = window.frame.clamped(to: bounds)
        }
        let floatedNames = windows.filter { floated.contains($0.id) }.map(Self.displayName(of:))
        var floatedFeedback: ResultPillFeedback?
        if floatedNames.count == 1 {
            floatedFeedback = .failure(title: ResultPillLayout.title(naming: floatedNames[0]) { "\($0) is floating" },
                                       detail: "It doesn’t fit in any pane.")
        } else if floatedNames.count > 1 {
            // One pill names them all; long names shorten, not the sentence.
            let named = floatedNames.count > 3 ? Array(floatedNames.prefix(2)) : floatedNames
            floatedFeedback = .failure(
                title: "\(floatedNames.count) windows are floating",
                detail: ResultPillLayout.detail(naming: named) { titles in
                    switch (titles.count, floatedNames.count) {
                    case (2, 2): "\(titles[0]) and \(titles[1]) don’t fit in any pane."
                    case (2, _): "\(titles[0]), \(titles[1]), and \(floatedNames.count - 2) more don’t fit in any pane."
                    default: "\(titles[0]), \(titles[1]), and \(titles[2]) don’t fit in any pane."
                    }
                }
            )
        }
        // Removals include windows on other displays. Reconciliation above
        // already records actual membership changes; unrelated IDs must not
        // trigger placement and a queued sweep on each display forever.
        let selectionNeedsPlacement = tabbedCommittedLayouts[session.id].map {
            $0.selected != Set(state.selectedWindowIDs)
        } ?? false
        let changed = wasUninitialized || before != state || selectionNeedsPlacement
            || session.lastWorkArea != display.visibleFrame
        if spacePanelCorrections.contains(session.id), changed {
            tabbedOverlays[display.id]?.hide()
        }
        if (changed || force || tabbedEntryBaselines[session.id] != nil), !session.automaticWritesSuspended {
            applyTabbedState(state, session: session, display: display, windows: windows,
                             focus: wasUninitialized || before.activeWindowID != state.activeWindowID ? state.activeWindowID : nil,
                             restorationFrames: restorationFrames,
                             arrivals: wasUninitialized ? [] : state.windowIDs.subtracting(before.windowIDs),
                             appliedFeedback: floatedFeedback, focusedBeforePlacement: focused)
        } else {
            if let committed = sessionStore.commit(session, replacing: session.revision), !force {
                completeApplicationRecoveryReconciliation(windows: windows, session: committed)
            }
            showTabbed(session: session, display: display, windows: windows)
        }
    }

    private func hideTabbedOverlay(on displayID: DisplayID) {
        tabbedOverlays[displayID]?.hide()
        if let session = sessionStore.session(for: displayID) { spacePanelCorrections.remove(session.id) }
    }

    private func showTabbed(session: LayoutSession, display: DisplaySnapshot, windows: [WindowSnapshot]) {
        if let request = paneApplicationRequest, request.displayID == display.id, !paneApplicationOwnerIsCurrent(request) {
            cancelPaneApplicationRequest(id: request.id)
        }
        guard presentsTabbedChrome, session.mode == .tabbed, let state = session.tabbedState, !isStabilizingSpace,
              tabbedEntryBaselines[session.id] == nil,
              !nativeFullscreenDisplayIDs.contains(display.id) else { return }
        let observation = system.nativeDesktopObservation()
        if let space = session.nativeSpaceID, let observation {
            guard sessionStore.session(for: display.id)?.id == session.id,
                  observation.currentSpace(on: display.id) == space,
                  observation.allowsAutomaticLayout(on: display.id) else { return }
        }
        selectTabbedOverlay(for: session)
        let overlay = tabbedOverlays[display.id] ?? tabbedOverlayFactory()
        if session.nativeSpaceID != nil, observation != nil {
            overlay.keepsPanelsOnSpace = true
            spacePanelOverlays[session.id] = overlay
        }
        overlay.acceptsTabDrags = !isTabbedBusy(on: display.id)
        overlay.dividerIsDragging = { [weak self] in self?.dividerResize.isDragging == true }
        overlay.overlayAppearance = configuration.overlayAppearance
        let sessionID = session.id
        overlay.onChooserVisibilityChange = { [weak self] in self?.syncSharedGestureMonitoring() }
        overlay.onAddApplication = { [weak self, weak overlay] paneID, view, rect in
            guard let self, let overlay, self.sessionStore.session(for: display.id)?.id == sessionID else { return }
            guard self.spacePanelOwnerIsCurrent(session, overlay: overlay) else { return }
            self.invalidateMenuPanelFocusReplay()
            if self.isTabbedBusy(on: display.id) {
                // App selection is independent of tab dragging. Keep one click
                // until the current placement releases the display.
                self.paneApplicationPickerTask?.cancel()
                let clock = self.paneApplicationClock
                self.paneApplicationPickerTask = Task { @MainActor [weak self, weak overlay] in
                    guard let self, let overlay else { return }
                    let deadline = self.paneApplicationUptime() + self.paneApplicationTimeout
                    while self.isTabbedBusy(on: display.id) {
                        guard !Task.isCancelled, self.paneApplicationUptime() < deadline,
                              self.spacePanelOwnerIsCurrent(session, overlay: overlay) else { return }
                        try? await clock.sleep(for: .milliseconds(10))
                    }
                    guard !Task.isCancelled, self.spacePanelOwnerIsCurrent(session, overlay: overlay),
                          self.sessionStore.session(for: display.id)?.id == sessionID else { return }
                    self.paneApplicationPickerTask = nil
                    overlay.showPaneApplicationPicker(paneID)
                }
                return
            }
            guard let request = self.beginPaneApplicationPicker(paneID: paneID, on: display.id) else { return }
            overlay.holdApplicationPicker(paneID, enabled: true)
            let picker = self.paneApplicationPopoverFactory(request, self.configuration.overlayAppearance)
            picker.onDismiss = { [weak self] in self?.dismissPaneApplicationPicker(requestID: request.id) }
            self.paneApplicationPopover = picker
            picker.show(relativeTo: rect, of: view, paneFrame: overlay.paneFrameInAppKit(paneID))
        }
        overlay.onPaneRequestAction = { [weak self] requestID, action in
            guard let self, let request = self.paneApplicationRequest, request.id == requestID,
                  request.displayID == display.id, request.sessionID == sessionID else { return }
            self.invalidateMenuPanelFocusReplay()
            self.handlePaneRequestAction(action, requestID: request.id)
        }
        overlay.onDismissApplicationPicker = { [weak self, weak overlay] in
            guard let self, let overlay, self.tabbedOverlays[display.id] === overlay,
                  let request = self.paneApplicationRequest,
                  request.displayID == display.id, request.sessionID == sessionID else { return }
            self.cancelPaneApplicationRequest(id: request.id)
        }
        overlay.onIntent = { [weak self, weak overlay] intent in
            guard let self, self.sessionStore.session(for: display.id)?.id == sessionID else {
                overlay?.completeDrop()
                return
            }
            guard let overlay, self.spacePanelOwnerIsCurrent(session, overlay: overlay) else {
                overlay?.completeDrop()
                return
            }
            // Tab-strip intents go to `handleTabbed` directly; they are user choices like `performTabbed`.
            self.invalidateMenuPanelFocusReplay()
            self.handleTabbed(intent, on: display.id)
            if !self.isTabbedBusy(on: display.id), self.tabbedQueuedIntents[display.id] == nil {
                self.tabbedOverlays[display.id]?.completeDrop()
            }
        }
        let focused = try? system.focusedWindow()
        let obscuring = focused.flatMap { window in
            window.displayID == display.id && !state.windowIDs.contains(window.id) ? window.frame : nil
        }
        let anchors = repairTabbedOrder(state: state, windows: windows, bounds: display.visibleFrame, displayID: display.id)
        let numbered = Set(state.selectedWindowIDs).union(anchors ?? [])
        let windowNumbers = (system as? any TabbedWindowSystem)?.windowNumbers(
            for: windows.filter { numbered.contains($0.id) }
        ) ?? [:]
        let latest = system.refreshNativeDesktopObservation()
        guard sessionStore.session(for: display.id)?.id == session.id,
              latest?.currentSpace(on: display.id) == observation?.currentSpace(on: display.id),
              latest?.allowsAutomaticLayout(on: display.id) != false else {
            overlay.prepareForSpaceChange()
            return
        }
        overlay.refresh(state: state, bounds: display.visibleFrame, windows: windows,
                        obscuringFrames: obscuring.map { [$0] } ?? [],
                        canUndo: !(tabbedUndo[session.id]?.isEmpty ?? true),
                        selectedWindowNumbers: windowNumbers,
                        // A window without a validated number falls back to the backmost selected tab.
                        curtainAnchorWindowNumber: anchors?.lazy.compactMap { windowNumbers[$0] }.first)
        tabbedOverlays[display.id] = overlay
        spacePanelCorrections.remove(session.id)
        // A kept curtain over an unverified order is checked again shortly.
        if overlay.needsCurtainVerification, tabbedCurtainRecheckTask == nil {
            let clock = tabbedClock
            tabbedCurtainRecheckTask = Task { @MainActor [weak self] in
                try? await clock.sleep(for: .milliseconds(80))
                guard let self, !Task.isCancelled else { return }
                self.tabbedCurtainRecheckTask = nil
                // Without a window inventory the order cannot be verified;
                // the curtain gives way instead of waiting for one.
                if !self.repairTabbedStacking() {
                    self.allTabbedOverlays.forEach { $0.releaseUnverifiedCurtain() }
                }
            }
        }
    }

    /// Frame rollback belongs to the coordinator. Entry also rolls back the
    /// mode and content reserve, so unchanged title bars never get tab strips.
    @discardableResult
    private func rejectTabbedEntry(on displayID: DisplayID, outcome: WindowMutationOutcome,
                                   selected: [WindowID], windows: [WindowSnapshot]) -> Bool {
        guard let current = sessionStore.session(for: displayID),
              let baseline = tabbedEntryBaselines.removeValue(forKey: current.id) else { return false }
        sessionStore.update(displayID) {
            $0.mode = baseline.mode
            $0.tabbedState = baseline.tabbedState
            $0.bentoState = baseline.bentoState
            $0.windowIDs = baseline.windowIDs
            $0.tabbedHasEntryBaseline = baseline.tabbedHasEntryBaseline
            $0.tabbedBaselineFrames = baseline.tabbedBaselineFrames
            $0.automaticWritesSuspended = baseline.automaticWritesSuspended
            if case .degraded = outcome { $0.suspendAutomaticWrites(observing: windows) }
        }
        let ids = (current.tabbedState?.windowIDs ?? []).union(current.tabbedState?.floatingWindowIDs ?? [])
            .union(selected)
        for id in ids { tabbedSteppedWindows.removeValue(forKey: id) }
        tabbedOverlays[displayID]?.hide()
        tabbedOverlays.removeValue(forKey: displayID)
        let needsRefresh = tabbedNeedsRefresh.remove(displayID) != nil
        tabbedNeedsReapply.remove(displayID)
        tabbedQueuedIntents.removeValue(forKey: displayID)
        let reason: String
        if case .degraded = outcome {
            reason = "The previous arrangement could not be fully restored. Choose a layout to continue."
        } else if let unresponsive = selected.first(where: system.isApplicationUnresponsive(for:)) {
            reason = unavailableTabbedWindowReason(unresponsive, windows: windows)
        } else {
            reason = outcome.failureReason ?? "The layout could not be applied."
        }
        statusMessage = reason
        presentActionResult(succeeded: false,
                            feedback: .failure(title: "Couldn’t enter Tabbed", detail: reason), displayID: displayID)
        refreshDividerBoundaries()
        if needsRefresh { refreshActiveWindows(force: false) }
        schedulePendingWindowEvents()
        return true
    }

    private func unavailableTabbedWindowReason(_ id: WindowID, windows: [WindowSnapshot]) -> String {
        let window = windows.first { $0.id == id } ?? (try? system.windowSnapshots(ids: [id]))?.first
        if let bundleIdentifier = window?.bundleIdentifier {
            let name = Self.applicationName(for: bundleIdentifier)
            if name != bundleIdentifier { return "\(name) is not responding." }
        }
        return "An application is not responding."
    }

    private static let tabbedSnapFailure = "That snap cannot fit every pane within its minimum size and the 12-pane limit."
    private static let tabbedParticipationChanged = "This window no longer participates in Tabbed. Float the window to use this action."
    private static let tabbedSpaceSwitchPending = "Desktop changed. Try again when the Space switch finishes."

    /// A Space switch can replace the session that owns a Tabbed window, so
    /// Tabbed actions wait for it to settle. Other modes act immediately.
    private func waitsForSpaceStabilization(_ window: WindowSnapshot) -> Bool {
        isStabilizingSpace
            && (sessionStore.session(for: window.displayID)?.mode == .tabbed || isTabbedMember(window.id))
    }

    private func tabbedSnapUnavailableReason(_ action: WindowAction) -> String {
        switch action {
        case .maximize: "Choose Single Pane in Layout Gallery to maximize the Tabbed layout."
        case .restore: "Use Tabbed Undo to restore the previous pane arrangement."
        default: "Tabbed supports fixed half, third, two-thirds, quarter, and sixth snaps. Float the window to use this action."
        }
    }

    /// - Parameter displayID: The Tabbed display, when a dragged window's
    ///   center may already be on another display.
    private func usesTabbedSnap(window: WindowSnapshot, on displayID: DisplayID? = nil) -> Bool {
        guard !window.isFloating, rule(for: window).allowsBentoParticipation,
              let session = sessionStore.session(for: displayID ?? window.displayID), session.mode == .tabbed,
              let state = session.tabbedState else { return false }
        return state.windowIDs.contains(window.id) || state.floatingWindowIDs.contains(window.id)
    }

    /// - Parameter draggedWindowID: A dragged window that belongs to this
    ///   display's layout even if its center crossed to another display.
    private func tabbedSnapContext(windowID: WindowID, displayID: DisplayID, draggedWindowID: WindowID? = nil)
        -> (session: LayoutSession, state: TabbedLayoutState, display: DisplaySnapshot, windows: [WindowSnapshot])? {
        guard !isShutDown, !isStabilizingSpace, hasAccessibilityPermission,
              !tabbedExiting.contains(displayID), !nativeFullscreenDisplayIDs.contains(displayID),
              let session = sessionStore.session(for: displayID), session.mode == .tabbed,
              let state = session.tabbedState,
              let display = system.displays().first(where: { $0.id == displayID }),
              let allWindows = try? observeVisibleWindows() else { return nil }
        let observation = system.refreshNativeDesktopObservation()
        guard observation?.allowsAutomaticLayout(on: displayID) != false else { return nil }
        if let space = session.nativeSpaceID,
           observation?.currentSpace(on: displayID) != space { return nil }
        let windows = bentoEligible((observation?.windowsOnCurrentSpaces(allWindows) ?? allWindows)
            .filter { ($0.displayID == displayID || $0.id == draggedWindowID) && $0.isEligible && !$0.isFloating })
        guard let source = windows.first(where: { $0.id == windowID }),
              usesTabbedSnap(window: source, on: displayID) else { return nil }
        return (session, state, display, windows)
    }

    private static let tabCommandsUnavailable = "Tab commands work on Tabbed desktops."

    private func performTabbedCommand(_ action: WindowAction, windowID: WindowID?, displayID: DisplayID,
                                      expectedSpaceID: NativeSpaceID? = nil) {
        guard activeMode(for: displayID) == .tabbed else {
            presentLayoutWheelUnavailable(Self.tabCommandsUnavailable, displayID: displayID)
            return
        }
        guard !isShutDown, !isStabilizingSpace, hasAccessibilityPermission,
              !tabbedExiting.contains(displayID), !nativeFullscreenDisplayIDs.contains(displayID),
              let session = sessionStore.session(for: displayID), session.mode == .tabbed,
              let state = session.tabbedState,
              expectedSpaceID == nil || session.nativeSpaceID == expectedSpaceID else { return }
        let observation = system.refreshNativeDesktopObservation()
        guard observation?.allowsAutomaticLayout(on: displayID) != false else { return }
        if let space = session.nativeSpaceID,
           observation?.currentSpace(on: displayID) != space { return }
        guard let windowID else { return }
        guard let sampled = try? system.windowSnapshots(ids: [windowID]),
              let source = (observation?.windowsOnCurrentSpaces(sampled) ?? sampled).first,
              source.displayID == displayID, source.isEligible, !source.isFloating,
              rule(for: source).allowsBentoParticipation,
              state.paneID(containing: windowID) != nil else {
            presentLayoutWheelUnavailable("Focus a tab to use tab commands.", displayID: displayID)
            return
        }
        if isTabbedBusy(on: displayID) {
            tabbedQueuedIntents[displayID, default: []].append(.command(action, windowID, session.nativeSpaceID))
            tabbedOverlays[displayID]?.yieldPressSelection()
            return
        }
        guard let pane = state.pane(containing: windowID), let selected = pane.selected,
              let index = pane.tabs.firstIndex(of: selected) else { return }
        statusMessage = nil
        let intent: TabbedUIIntent
        switch action {
        case .nextTab, .previousTab:
            guard pane.tabs.count > 1 else { return }
            let offset = action == .nextTab ? 1 : -1
            intent = .select(pane.tabs[(index + offset + pane.tabs.count) % pane.tabs.count])
        case .moveTabLeft, .moveTabRight:
            let destination = index + (action == .moveTabRight ? 1 : -1)
            guard pane.tabs.indices.contains(destination) else { return }
            intent = .move(selected, pane: pane.id, index: destination)
        case .moveTabToNextPane, .moveTabToPreviousPane:
            let panes = state.panes
            guard panes.count > 1, let paneIndex = panes.firstIndex(where: { $0.id == pane.id }) else { return }
            let offset = action == .moveTabToNextPane ? 1 : -1
            let destination = panes[(paneIndex + offset + panes.count) % panes.count]
            intent = .move(selected, pane: destination.id, index: nil)
        default: return
        }
        if case let .select(id) = intent {
            guard let sampled = try? system.windowSnapshots(ids: [id]),
                  let target = (observation?.windowsOnCurrentSpaces(sampled) ?? sampled).first,
                  target.displayID == displayID, target.isEligible, !target.isFloating,
                  rule(for: target).allowsBentoParticipation else {
                presentLayoutWheelUnavailable("That window is no longer available.", displayID: displayID)
                return
            }
        }
        handleTabbed(intent, on: displayID)
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
        if isTabbedBusy(on: displayID) {
            tabbedQueuedIntents[displayID, default: []].append(.snap(windowID, action, expectedSpaceID))
            tabbedOverlays[displayID]?.yieldPressSelection()
            return
        }
        applyTabbedState(context.state, session: context.session, display: context.display,
            windows: context.windows, focus: windowID, rememberUndo: true, snapAction: action, expectedSpaceID: expectedSpaceID)
    }

    /// The arrangement a Tabbed state takes on a display. Any placement
    /// starts from the sizes the user set, so a pane that grew for a tab that
    /// has since moved, closed, or floated returns to them. A tab that needs
    /// more room grows its pane again from there.
    private func fittedTabbedState(_ state: TabbedLayoutState, in bounds: BTRect,
                                   windows: [WindowSnapshot], focus: WindowID?) throws -> TabbedLayoutState {
        var base = state
        if configuration.tabbedRestoresPaneSizes,
           let preferred = state.withPreferredPaneSizes(),
           (try? preferred.fittingMinimumWidths(in: bounds, windows: windows)) != nil {
            base = preferred
        }
        do {
            let fitted = try base.fittingMinimumWidths(in: bounds, windows: windows)
            _ = try fitted.placements(in: bounds, windows: windows)
            return fitted
        } catch TabbedLayoutError.panesTooSmall {
            // Name the window that does not fit and what is in its way.
            if let focus, let failure = tabbedFitFailure(showing: focus, in: base, windows: windows, bounds: bounds) {
                throw failure
            }
            throw TabbedLayoutError.panesTooSmall
        }
    }

    private func applyTabbedState(
        _ state: TabbedLayoutState, session original: LayoutSession, display: DisplaySnapshot,
        windows: [WindowSnapshot], focus: WindowID?, rememberUndo: Bool = false, consumeUndo: Bool = false,
        selectionOnly: Bool = false, earlyRaise: TabbedEarlyRaise? = nil, rollbackFrames: [WindowID: BTRect]? = nil,
        snapAction: WindowAction? = nil, snapScope: TabbedSnapScope = .pane, preparedDrop: PreparedTabbedArrangement? = nil,
        gestureBaseline: TabbedLayoutState? = nil, floatingUndoFrame: BTRect? = nil,
        floatingUndoSourceID: WindowID? = nil, gestureSourceID: WindowID? = nil,
        expectedSpaceID: NativeSpaceID? = nil, restorationFrames: [WindowID: BTRect] = [:],
        arrivals: Set<WindowID> = [], appliedFeedback: ResultPillFeedback? = nil, rejection: String? = nil,
        reportsFailure: Bool = true, focusedBeforePlacement: WindowID? = nil,
        startsImmediately: Bool = false,
        allowingRequestRaise: @escaping @MainActor () -> Bool = { true },
        validating additionalValidation: @escaping @MainActor () -> Bool = { true }
    ) {
        let windows = ignoringOversizedSeeds(windows, in: display.visibleFrame)
        guard tabbedTasks[display.id] == nil else {
            #if DEBUG
            if arrivalTrace.isEnabled { for window in windows {
                arrivalTrace.disposition("arrival_deferred", windowID: window.id, reason: "tabbed_placement_in_progress")
            } }
            #endif
            tabbedNeedsReapply.insert(display.id)
            return
        }
        guard sessionStore.isCurrent(original.id, revision: original.revision, on: display.id) else { return }
        let revalidateRecoveryWrites = applicationRecoveryGeneration != nil
        let nativeObservation = system.refreshNativeDesktopObservation()
        let expectedSpace = expectedSpaceID ?? (nativeObservation == nil ? nil : original.nativeSpaceID)
            ?? (snapAction == nil ? nil : nativeObservation?.currentSpace(on: display.id))
        // The same desktop, even if its work area changed after planning.
        let isSameDesktopAnyWorkArea = { @MainActor [weak self] in
            guard let self, !self.isShutDown, !self.isStabilizingSpace, self.hasAccessibilityPermission,
                  !self.nativeFullscreenDisplayIDs.contains(display.id), !self.tabbedExiting.contains(display.id),
                  self.activeMode(for: display.id) == .tabbed, additionalValidation() else { return false }
            let observation = self.system.refreshNativeDesktopObservation()
            guard (observation != nil) == (nativeObservation != nil),
                  observation?.allowsAutomaticLayout(on: display.id) != false else { return false }
            if let space = expectedSpace, observation?.currentSpace(on: display.id) != space { return false }
            if snapAction != nil, windows.contains(where: {
                (state.windowIDs.contains($0.id) || $0.id == (gestureSourceID ?? focus)) && !self.rule(for: $0).allowsBentoParticipation
            }) { return false }
            return self.sessionStore.session(for: display.id)?.id == original.id
        }
        let isSameDesktop = { @MainActor [weak self] in
            isSameDesktopAnyWorkArea()
                && self?.system.displays().first(where: { $0.id == display.id })?.visibleFrame == display.visibleFrame
        }
        let isCurrent = { @MainActor [weak self] in
            isSameDesktop() && self?.sessionStore.isCurrent(original.id, revision: original.revision, on: display.id) == true
        }
        guard isCurrent() else { return }
        // Exact snaps must restore the actual checkpoint on both axes;
        // one held length can be a minimum rather than a resize step.
        func rollbackSteppedWindowIDs() -> Set<WindowID> {
            snapAction == nil ? Set(self.tabbedSteppedWindows.keys) : []
        }
        let previous = gestureBaseline ?? sessionStore.session(for: display.id)?.tabbedState
        func restoreGestureMembership() -> LayoutSession {
            guard let gestureBaseline, isCurrent() else { return original }
            var restored = original
            restored.tabbedState = gestureBaseline
            restored.windowIDs = gestureBaseline.windowIDs
            restored.lastObservedFrames = rollbackFrames ?? original.lastObservedFrames
            return sessionStore.commit(restored, replacing: original.revision) ?? original
        }
        // Windows that left the panes, and any new window the caller floated
        // with a frame to put it at.
        let detached = (previous?.windowIDs ?? []).subtracting(state.windowIDs)
            .union(restorationFrames.keys).intersection(state.floatingWindowIDs)
        var selectionOnly = selectionOnly
        // Set when a drag's placement retries after an application refused
        // the size its overlay planned.
        var refitsPreparedDrop = false
        func prepare(_ windows: [WindowSnapshot]) throws -> (state: TabbedLayoutState, placements: [Placement]) {
            // A drag released over invalid feedback places nothing and
            // restores its checkpoint below.
            if let rejection { throw WindowSystemError.operationFailed(rejection) }
            if selectionOnly {
                guard let focus, let window = windows.first(where: { $0.id == focus && $0.isEligible }),
                      let pane = state.panes.first(where: { $0.tabs.contains(focus) }),
                      let frame = state.frames(in: display.visibleFrame)[pane.id] else {
                    throw WindowSystemError.operationFailed("That window is no longer available.")
                }
                let content = state.windowArea(frame)
                // A fixed-size window keeps its size, centred by the planner;
                // its size is the minimum its pane must hold.
                let fixed = !window.constraints.isResizable
                let minimum = fixed ? window.frame.size : window.constraints.minimumSize
                // A pane that grew for a larger tab returns to the size the
                // user set when the newly selected tab fits it, so the full
                // placement below runs; a tab that needs more room grows the
                // pane from that size.
                // A window known to resize in steps keeps the pane that fits
                // the size it holds; the full placement below sets that up.
                let preferred = self.configuration.tabbedRestoresPaneSizes
                    ? state.withPreferredPaneSizes().flatMap {
                        try? $0.fittingMinimumWidths(in: display.visibleFrame, windows: windows)
                    } : nil
                let changesPaneSizes = (preferred ?? state).fittingSteppedGrids(
                    self.tabbedSteppedGrids, in: display.visibleFrame, windows: windows).layout != state.layout
                if !changesPaneSizes, content.size.width + 0.001 >= minimum.width,
                   content.size.height + 0.001 >= minimum.height {
                    if fixed {
                        return (state, try state.placements(in: display.visibleFrame, windows: windows).filter { $0.windowID == focus })
                    }
                    return (state, self.requestingSteppedLengths(
                        [Placement(windowID: focus, frame: content)]))
                }
                selectionOnly = false
            }
            let available = Set(windows.filter {
                $0.isEligible && ($0.displayID == display.id || $0.id == gestureSourceID)
            }.map(\.id))
            guard Set(state.selectedWindowIDs).isSubset(of: available) else {
                throw WindowSystemError.operationFailed("One or more selected tabs are no longer available.")
            }
            var fitted: TabbedLayoutState
            if let snapAction {
                let failure = WindowSystemError.operationFailed(BentoDropPlanner.partitionActions.contains(snapAction)
                    ? Self.tabbedSnapFailure : self.tabbedSnapUnavailableReason(snapAction))
                guard let focus, let source = windows.first(where: { $0.id == focus }),
                      self.usesTabbedSnap(window: source, on: display.id) else { throw failure }
                if let preparedDrop {
                    // A drag commits the arrangement its overlay showed.
                    fitted = preparedDrop.state
                } else {
                    guard let plan = TabbedSnapPlanner.plan(sourceWindowID: focus, action: snapAction, scope: snapScope,
                              state: state, windows: windows, in: display.visibleFrame),
                          plan.preservesTarget(in: plan.state, within: display.visibleFrame) else { throw failure }
                    fitted = plan.state
                }
            } else if let preparedDrop {
                // A drag commits the panes its overlay fitted. After an
                // application refused its size, the same tabs fit again with
                // the size it revealed, as any placement does.
                fitted = refitsPreparedDrop
                    ? try self.fittedTabbedState(preparedDrop.state, in: display.visibleFrame, windows: windows, focus: focus)
                    : preparedDrop.state
            } else {
                // A remembered grid fits the panes to its window's steps.
                fitted = try self.fittedTabbedState(state, in: display.visibleFrame, windows: windows, focus: focus)
                    .fittingSteppedGrids(self.tabbedSteppedGrids, in: display.visibleFrame, windows: windows)
            }
            // A drag places its windows with the constraints its overlay
            // planned with; a minimum read again cannot change the panes.
            var proposed = self.requestingSteppedLengths(try fitted.placements(
                in: display.visibleFrame, windows: refitsPreparedDrop ? windows : preparedDrop?.windows ?? windows))
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
        var rollbackFailed = false
        // Only known handoffs can leave an unfinished placement to newer work.
        func retainInvalidatedDegradation(_ outcome: WindowMutationOutcome) {
            if case let .degraded(reason) = outcome, !self.isShutDown,
               self.tabbedTaskIDs[display.id] != taskID || Task.isCancelled || !isCurrent() {
                let gestureOwnsRecovery = self.activeBentoDrag?.layoutSession.id == original.id
                    && self.sessionStore.isActive(original.id, on: display.id)
                let workArea = self.system.displays().first(where: { $0.id == display.id })?.visibleFrame
                let workAreaOwnsRecovery = !Task.isCancelled && workArea != nil
                    && workArea != display.visibleFrame && isSameDesktopAnyWorkArea()
                guard rollbackFailed || (!gestureOwnsRecovery && !workAreaOwnsRecovery) else { return }
                self.suspendAutomaticBentoWrites(displayID: display.id, sessionID: original.id, error: reason)
            }
        }
        let initial: (state: TabbedLayoutState, placements: [Placement])
        do { initial = try prepare(windows) }
        catch {
            let reason = error.localizedDescription
            guard let rollbackFrames else {
                if let earlyRaise { undoEarlyTabRaise(earlyRaise) }
                // No placement starts, so no placement end drops the
                // pressed tab's highlight.
                if let focus { tabbedOverlays[display.id]?.dropPressedSelection(of: focus) }
                Self.tabbedLog.debug("placement not started: \(reason, privacy: .private)")
                if rejectTabbedEntry(on: display.id, outcome: .failed(reason: reason), selected: state.selectedWindowIDs, windows: windows) { return }
                guard reportsFailure else { return }
                statusMessage = reason
                presentActionResult(succeeded: false, error: reason,
                                    feedback: (error as? TabbedFitFailure)?.feedback, displayID: display.id)
                return
            }
            tabbedTaskIDs[display.id] = taskID
            tabbedOverlays[display.id]?.acceptsTabDrags = false
            tabbedTasks[display.id] = Task { @MainActor [weak self] in
                guard let self else { return }
                defer {
                    self.resumeIdlePaneApplicationRequest(on: display.id)
                    if !self.isTabbedBusy(on: display.id), self.tabbedQueuedIntents[display.id] == nil {
                        self.tabbedOverlays[display.id]?.completeDrop()
                        self.tabbedOverlays[display.id]?.acceptsTabDrags = true
                    }
                }
                var restored = await self.coordinator.restoreTabbedFrames(rollbackFrames,
                    required: Set(previous?.selectedWindowIDs ?? []).union(gestureSourceID.map { [$0] } ?? []),
                    on: display.id, exempting: gestureSourceID, steppedWindowIDs: rollbackSteppedWindowIDs(),
                    onRollbackFailure: { rollbackFailed = true }, isCurrent: isCurrent)
                retainInvalidatedDegradation(restored)
                guard self.tabbedTaskIDs[display.id] == taskID else { return }
                self.tabbedTaskIDs.removeValue(forKey: display.id)
                self.tabbedTasks[display.id] = nil
                guard isSameDesktop(), !Task.isCancelled else {
                    if !isSameDesktop() || self.activeBentoDrag?.layoutSession.id != original.id {
                        self.tabbedQueuedIntents.removeValue(forKey: display.id)
                        self.tabbedNeedsReapply.remove(display.id)
                        self.tabbedNeedsRefresh.remove(display.id)
                    }
                    // A work area that changed during the placement, for
                    // example while the Dock settled, needs a placement too.
                    if !Task.isCancelled, isSameDesktopAnyWorkArea() { self.refreshActiveWindows(force: true) }
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
                    restored = .degraded(reason: "Tabbed could not restore window order. Use Repair Layout.")
                }
                if case let .degraded(reason) = restored {
                    self.suspendAutomaticBentoWrites(displayID: display.id, sessionID: original.id, error: reason)
                } else {
                    self.statusMessage = reason
                    self.showTabbed(session: restoredSession, display: display, windows: windows)
                }
                self.presentActionResult(succeeded: false, error: self.statusMessage, displayID: display.id)
                // The rollback may have reverted a selection the divider
                // pointed at mid-gesture; our restore writes do not refresh it.
                self.refreshDividerBoundaries()
                self.drainTabbedQueuedIntent(on: display.id, sessionID: original.id)
                self.schedulePendingWindowEvents()
            }
            return
        }
        tabbedTaskIDs[display.id] = taskID
        tabbedOverlays[display.id]?.acceptsTabDrags = false
        #if DEBUG
        if arrivalTrace.isEnabled { for window in windows {
            arrivalTrace.disposition("tabbed_placement_queued", windowID: window.id, reason: "main_actor_task")
        } }
        #endif
        // A new window is placed in this turn: its first write waits for no queued
        // task, and the focus the caller just read stands for the focus before it.
        let startsNow = startsImmediately || (placesCreatedWindowsInThisTurn && !arrivals.isEmpty)
        let focusBeforeHint = startsNow ? focusedBeforePlacement : nil
        // The menu panel's ownership of focus is decided for the whole request. A retry after
        // dismissal keeps the deferral, so only the authorized close path can replay focus.
        let requestDefersFocus = menuPanelIsShown()
        let requestFocusEpoch = menuPanelFocusEpoch
        let placement = Self.startTabbedPlacement(immediately: startsNow) { @MainActor [weak self] in
            guard let self else { return }
            #if DEBUG
            if self.arrivalTrace.isEnabled { for window in windows {
                self.arrivalTrace.disposition("tabbed_placement_started", windowID: window.id,
                                              reason: startsNow ? "same_turn" : "main_actor_task")
            } }
            #endif
            defer {
                self.resumeIdlePaneApplicationRequest(on: display.id)
                if !self.isTabbedBusy(on: display.id), self.tabbedQueuedIntents[display.id] == nil {
                    self.tabbedOverlays[display.id]?.completeDrop()
                    self.tabbedOverlays[display.id]?.acceptsTabDrags = true
                }
            }
            var proposal = initial
            var snapPane = snapAction == nil ? nil : focus.flatMap { initial.state.pane(containing: $0) }
            func preservesSnapTarget(_ state: TabbedLayoutState) -> Bool {
                guard let snapAction else { return true }
                guard let focus, let snapPane, let target = snapAction.partition?.frame(in: display.visibleFrame),
                      let pane = state.pane(containing: focus) else { return false }
                return pane.id == snapPane.id && pane.tabs == snapPane.tabs && pane.selected == focus
                    && state.logicalFrames(in: display.visibleFrame)[pane.id]?.approximatelyEquals(target, tolerance: 0.001) == true
            }
            var windows = windows
            // With a readable window order, the focus refresh after a
            // selection raises only panes that activation really exposed.
            let repairsStackingAfterSelection = selectionOnly
                && (self.system as? any TabbedWindowSystem)?.stackingOrder(for: windows, excluding: []) != nil
            var outcome: WindowMutationOutcome = .failed(reason: "The desktop changed.")
            var deferredFocus: WindowID?
            var defersFocus = requestDefersFocus
            var deferredFocusEpoch = requestFocusEpoch
            var fitFailure: TabbedFitFailure?
            // A stepped snap writes again after a placement; if that write
            // fails, focus returns to the window that had it before. Without
            // a focus change, the coordinator reads it at that write.
            let focusBefore = focus == nil ? nil
                : earlyRaise?.previousFocus ?? focusBeforeHint ?? ((try? self.system.focusedWindow()) ?? nil)?.id
            let dropDestination = gestureSourceID.map { DropDestination(displayID: display.id, sourceWindowID: $0,
                minimumSizes: Dictionary((preparedDrop?.windows ?? []).map { ($0.id, $0.constraints.minimumSize) },
                                         uniquingKeysWith: { first, _ in first })) }
            for attempt in 0..<2 {
                rollbackFailed = false
                self.tabbedFocusSuppressedUntil = self.tabbedClock.now.advanced(by: .milliseconds(300))
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
                // The frames the last write accepted, and the window areas
                // they must stay inside.
                var accepted: [WindowID: BTRect] = [:]
                let onSizeMismatch: @MainActor (WindowID, BTRect, BTRect, BTRect) -> Void = { id, requested, baseline, actual in
                    guard proposal.state.windowIDs.contains(id) || detached.contains(id) else { return }
                    // A size within one step of the request is the window's
                    // step, not its minimum. A window that grew by a step
                    // where no growth was accepted resizes in steps: the
                    // retry keeps its pane edges in place.
                    guard SteppedSizeAcceptance.evaluate(requested: requested, actual: actual, allowsGrowth: true) == .rejected else {
                        if actual.size.width > requested.size.width + 2 || actual.size.height > requested.size.height + 2,
                           self.recordSteppedSize(id, requested: requested.size, settled: actual.size, windows: windows) { learnedSize = true }
                        return
                    }
                    learnedSize = self.system.observeApplicationEnforcedMinimum(
                        windowID: id, requested: requested, baseline: baseline, actual: actual
                    ) || learnedSize
                }
                #if DEBUG
                self.arrivalTrace.decided(proposal.placements, mode: "Tabbed")
                #endif
                let requestedFocus = focus.flatMap { eligibleIDs.contains($0) ? $0 : nil }
                // A panel that opens during the placement starts a deferral. A deferral never ends
                // early and never takes a newer epoch.
                if !defersFocus, self.menuPanelIsShown() {
                    defersFocus = true
                    deferredFocusEpoch = self.menuPanelFocusEpoch
                }
                deferredFocus = defersFocus && allowingRequestRaise() ? requestedFocus : nil
                outcome = await self.coordinator.applyTabbed(
                    placements: proposal.placements,
                    rollbackFrames: rollbackFrames,
                    rollbackDisplayID: rollbackFrames == nil ? nil : display.id,
                    rollbackRequired: rollbackFrames == nil ? nil : Set(previous?.selectedWindowIDs ?? []),
                    // Selected tabs and newly floating windows must settle;
                    // hidden tabs stack behind their pane at best effort.
                    required: selectionOnly ? nil : Set(proposal.state.selectedWindowIDs).union(detached),
                    selected: selected,
                    previousSelected: previous?.selectedWindowIDs.filter(eligibleIDs.contains) ?? [],
                    // Keep the menu key; replay successful focus requests after it closes.
                    focus: defersFocus ? nil : requestedFocus,
                    allowingRaise: allowingRequestRaise,
                    focusAlreadyRequested: earlyRaise != nil && attempt == 0,
                    focusCheckpoint: earlyRaise?.previousFocus ?? focusBeforeHint,
                    // A drag drops on this display, whatever display the
                    // dragged window's center reached, with the minimums its
                    // overlay planned with.
                    destination: dropDestination,
                    onSizeMismatch: onSizeMismatch,
                    acceptsSteppedGrowth: true,
                    onApplied: { accepted = $0 },
                    steppedWindowIDs: rollbackSteppedWindowIDs(),
                    onRollbackFailure: { rollbackFailed = true }, revalidateBeforeEachWrite: revalidateRecoveryWrites, isCurrent: isCurrent
                )
                // A window that resizes in steps settled up to one step off
                // its pane. One more write fits the panes to it, or asks an
                // overflowing window for one step less. That write accepts
                // no growth, so two stepped windows never chase each other.
                let checkpoint = rollbackFrames
                    ?? Dictionary(windows.map { ($0.id, $0.frame) }, uniquingKeysWith: { first, _ in first })
                let requested = Dictionary(proposal.placements.map { ($0.windowID, $0.frame) }, uniquingKeysWith: { first, _ in first })
                // Window areas, not requests: a window asked for a length on
                // its grid may round up toward its area.
                var areas = proposal.state.layout.contentFrames(in: display.visibleFrame)
                let deviating = Set(accepted.filter { id, frame in
                    requested[id].map { abs($0.size.width - frame.size.width) > 2 || abs($0.size.height - frame.size.height) > 2 } == true
                }.keys)
                // A window with a grid on every axis it settled off was asked
                // for lengths on them; any other window snaps its pane to the
                // lengths it took. A window whose grid this write changed,
                // such as after a font change, snaps too.
                let grids = self.tabbedSteppedGrids
                var known = Set(accepted.keys.filter { id in
                    guard let axes = grids[id], let asked = requested[id]?.size, let size = accepted[id]?.size else { return false }
                    return (abs(size.width - asked.width) <= 2 || axes[.vertical] != nil)
                        && (abs(size.height - asked.height) <= 2 || axes[.horizontal] != nil)
                })
                if outcome.isApplied {
                    for id in proposal.state.selectedWindowIDs {
                        if let requested = requested[id]?.size, let settled = accepted[id]?.size,
                           self.recordSteppedSize(id, requested: requested, settled: settled, windows: windows) {
                            known.remove(id)
                            learnedSize = true
                        }
                    }
                }
                if outcome.isApplied, !Task.isCancelled, isCurrent(), let snap = proposal.state.snappingToSteppedSizes(
                       accepted.filter { !known.contains($0.key) }.mapValues(\.size),
                       // Every remembered window keeps its pane edges, even one
                       // length that is no grid yet, so neighbours never chase.
                       protecting: Set(self.tabbedSteppedWindows.keys).union(deviating),
                       fixedPaneIDs: Set(snapPane.map { [$0.id] } ?? []),
                       in: display.visibleFrame, windows: windows),
                   Set(snap.state.selectedWindowIDs).isSubset(of: Set(snap.placements.map(\.windowID))) {
                    for step in snap.snaps {
                        let axis = step.axis == .vertical ? "width" : "height"
                        let neighbors = step.neighbors.map(\.rawValue).joined(separator: ",")
                        Self.tabbedLog.debug("stepped snap: \(step.windowID.rawValue, privacy: .public) \(axis, privacy: .public) \(step.delta, privacy: .public) pt, neighbours \(neighbors, privacy: .public)")
                    }
                    if snap.snaps.isEmpty {
                        Self.tabbedLog.debug("stepped snap: no pane edge can follow; asking for one step less")
                    }
                    let floating = proposal.placements.filter { !snap.state.windowIDs.contains($0.windowID) }
                    // Windows with grids keep asking for lengths on them.
                    proposal = (snap.state, self.requestingSteppedLengths(snap.placements) + floating)
                    areas = snap.state.layout.contentFrames(in: display.visibleFrame)
                    // A window asked for less than its area can round up
                    // toward it; growth past the area fails below.
                    accepted = [:]
                    outcome = await self.coordinator.applyTabbed(
                        placements: proposal.placements,
                        rollbackFrames: checkpoint,
                        rollbackDisplayID: display.id,
                        rollbackRequired: Set(previous?.selectedWindowIDs ?? []).intersection(checkpoint.keys),
                        required: Set(proposal.state.selectedWindowIDs).union(detached.intersection(floating.map(\.windowID))),
                        selected: [],
                        previousSelected: previous?.selectedWindowIDs.filter(eligibleIDs.contains) ?? [],
                        focus: nil,
                        allowingRaise: allowingRequestRaise,
                        focusCheckpoint: focusBefore,
                        destination: dropDestination,
                        onSizeMismatch: onSizeMismatch,
                        acceptsSteppedGrowth: true,
                        onApplied: { accepted = $0 },
                        steppedWindowIDs: rollbackSteppedWindowIDs(),
                        onRollbackFailure: { rollbackFailed = true }, revalidateBeforeEachWrite: revalidateRecoveryWrites, isCurrent: isCurrent
                    )
                }
                // A selected window that grew past its window area would
                // overlap its neighbour: no snap followed, or a neighbour
                // rounded back up. Put the windows back. A window that grew
                // within one step resizes in steps, so the retry keeps its
                // pane edges in place.
                let overflowing = Set(proposal.state.selectedWindowIDs).filter { id in
                    guard let frame = accepted[id], let area = areas[id] else { return false }
                    return frame.size.width > area.size.width + 2 || frame.size.height > area.size.height + 2
                }
                if outcome.isApplied, !overflowing.isEmpty || !preservesSnapTarget(proposal.state) {
                    // A length that changes a grid gives the retry something new.
                    let asked = Dictionary(proposal.placements.map { ($0.windowID, $0.frame.size) }, uniquingKeysWith: { first, _ in first })
                    for id in overflowing {
                        if let request = asked[id], let settled = accepted[id]?.size,
                           self.recordSteppedSize(id, requested: request, settled: settled, windows: windows), attempt == 0 { learnedSize = true }
                    }
                    let restored = await self.coordinator.restoreTabbedFrames(
                        checkpoint, required: Set(proposal.state.selectedWindowIDs).intersection(checkpoint.keys),
                        on: display.id, exempting: gestureSourceID, steppedWindowIDs: rollbackSteppedWindowIDs(),
                        onRollbackFailure: { rollbackFailed = true }, isCurrent: isCurrent)
                    if allowingRequestRaise() {
                        _ = self.coordinator.raiseTabbedWindows(previous?.selectedWindowIDs.filter(eligibleIDs.contains) ?? [])
                    }
                    outcome = restored.isApplied
                        ? .failed(reason: "A window did not accept its Tabbed size. Choose a larger pane or try Repair Layout.")
                        : restored
                } else if outcome.isApplied {
                    // A length a stepped window settles at off its request
                    // refines its grid.
                    let asked = Dictionary(proposal.placements.map { ($0.windowID, $0.frame.size) }, uniquingKeysWith: { first, _ in first })
                    for (id, frame) in accepted where proposal.state.selectedWindowIDs.contains(id) {
                        if let request = asked[id] { self.recordSteppedSize(id, requested: request, settled: frame.size, windows: windows) }
                    }
                }
                // Retry once, only after a complete rollback and a new size
                // observation. Ignored writes and degraded outcomes never retry.
                // A tab drop keeps the tabs its overlay showed; only the panes
                // adapt to the size the application revealed. A snap drag
                // commits exactly the snap its overlay showed, or fails.
                guard case .failed = outcome, attempt == 0, preparedDrop == nil || snapAction == nil,
                      !Task.isCancelled, isCurrent() else { break }
                let ids = Set(windows.map(\.id))
                // A snapshot can confirm a kept size before the mismatch
                // report sees it, so a larger minimum in the refreshed
                // constraints is the same new observation.
                let reread = (try? self.system.windowSnapshots(ids: ids))
                    .map { self.ignoringOversizedSeeds($0, in: display.visibleFrame) }
                guard learnedSize || reread.map({ Self.gainedMinimumSize($0, since: windows) }) == true else { break }
                refitsPreparedDrop = true
                do {
                    let refreshed = try reread
                        ?? self.ignoringOversizedSeeds(self.system.windowSnapshots(ids: ids), in: display.visibleFrame)
                    guard Set(refreshed.map(\.id)) == ids,
                          refreshed.allSatisfy({ ($0.displayID == display.id || $0.id == gestureSourceID) && $0.isEligible })
                    else { break }
                    selectionOnly = false
                    proposal = try prepare(refreshed)
                    snapPane = snapAction == nil ? nil : focus.flatMap { proposal.state.pane(containing: $0) }
                    windows = refreshed
                } catch {
                    fitFailure = error as? TabbedFitFailure
                    outcome = .failed(reason: error.localizedDescription)
                    break
                }
            }
            let state = proposal.state
            let placements = proposal.placements
            retainInvalidatedDegradation(outcome)
            guard self.tabbedTaskIDs[display.id] == taskID else { return }
            self.tabbedTaskIDs.removeValue(forKey: display.id)
            self.tabbedTasks[display.id] = nil
            guard !Task.isCancelled, isSameDesktop() else {
                if !isSameDesktop() || self.activeBentoDrag?.layoutSession.id != original.id {
                    self.tabbedQueuedIntents.removeValue(forKey: display.id)
                    self.tabbedNeedsReapply.remove(display.id)
                    self.tabbedNeedsRefresh.remove(display.id)
                }
                // A work area that changed during the placement, for
                // example while the Dock settled, needs a placement too.
                if !Task.isCancelled, isSameDesktopAnyWorkArea() { self.refreshActiveWindows(force: true) }
                return
            }
            guard isCurrent() else {
                self.drainTabbedQueuedIntent(on: display.id, sessionID: original.id)
                self.schedulePendingWindowEvents()
                return
            }
            if outcome.isApplied {
                // Correct a later focus change only when the placement never
                // saw the selected tab focused; after that, it is the user's.
                if selectionOnly, let focus {
                    let confirmed = ((try? self.system.focusedWindow()) ?? nil)?.id == focus
                    self.tabbedIntendedFocus = confirmed ? nil : (focus, self.tabbedClock.now.advanced(by: .seconds(1)))
                }
                var proposed = original
                if let snapAction, BentoDropPlanner.partitionActions.contains(snapAction) { proposed.endFollowing() }
                proposed.tabbedState = state
                proposed.windowIDs = state.windowIDs
                proposed.lastWorkArea = display.visibleFrame
                var placedFrames = Dictionary(uniqueKeysWithValues: placements.map { ($0.windowID, $0.frame) })
                // An application that resizes in steps settled just short of
                // its pane. Its real frame is the verified one; comparing later
                // events with the request would read it as a user resize.
                for window in (try? self.system.windowSnapshots(ids: Set(placedFrames.keys))) ?? [] {
                    #if DEBUG
                    if self.arrivalTrace.isEnabled { self.arrivalTrace.settled([window], accepted: true) }
                    #endif
                    if let requested = placedFrames[window.id],
                       SteppedSizeAcceptance.evaluate(requested: requested, actual: window.frame, allowsGrowth: true) == .stepped {
                        placedFrames[window.id] = window.frame
                    }
                }
                proposed.lastObservedFrames = selectionOnly
                    ? original.lastObservedFrames.merging(placedFrames) { _, new in new }
                    : placedFrames
                proposed.resumeAutomaticWrites()
                if let committed = self.sessionStore.commit(proposed, replacing: original.revision) {
                    if let deferredFocus {
                        self.menuPanelDeferredFocus = MenuPanelDeferredFocus(windowID: deferredFocus,
                            displayID: display.id, sessionID: committed.id, spaceID: expectedSpace,
                            usesNativeObservation: nativeObservation != nil, generation: self.spaceStabilizationGeneration,
                            focusEpoch: deferredFocusEpoch)
                        // The panel was dismissed while this placement ran. It focuses only after the Space settles.
                        if !self.menuPanelIsShown() {
                            if deferredFocusEpoch == self.menuPanelFocusEpoch, self.menuPanelDismissalAuthorization() {
                                self.scheduleLateMenuPanelFocus()
                            } else {
                                self.menuPanelDeferredFocus = nil
                            }
                        }
                    }
                    self.tabbedEntryBaselines.removeValue(forKey: original.id)
                    self.completeApplicationRecoveryReconciliation(windows: windows, session: committed)
                    self.statusMessage = nil
                    if consumeUndo { self.tabbedUndo[original.id]?.removeLast() }
                    let movedPane = snapAction == nil || previous?.layout != state.layout
                        || focus.map { previous?.paneID(containing: $0) != state.paneID(containing: $0) } == true
                    if rememberUndo, movedPane, let previous, previous != state {
                        var floatingFrames: [WindowID: BTRect] = [:]
                        // Undo keeps a float's frame without granting picker choices
                        // the display-transfer exemption of a drag.
                        if let floated = floatingUndoSourceID ?? gestureSourceID ?? (snapAction != nil ? focus : nil),
                           previous.floatingWindowIDs.contains(floated),
                           let frame = floatingUndoFrame ?? rollbackFrames?[floated]
                            ?? windows.first(where: { $0.id == floated })?.frame {
                            floatingFrames[floated] = frame
                        }
                        self.rememberTabbedUndo(previous, sessionID: original.id, floatingFrames: floatingFrames)
                    }
                    self.showTabbed(session: committed, display: display, windows: windows)
                    if let committedState = committed.tabbedState {
                        let layout = TabbedCommittedLayout(paneFrames: committedState.frames(in: display.visibleFrame),
                                                           selected: Set(committedState.selectedWindowIDs))
                        let earlier = self.tabbedCommittedLayouts.updateValue(layout, forKey: original.id)
                        let floating = committedState.automaticallyFloatingWindowIDs
                        // A window this placement floated was just checked.
                        let waiting = floating.intersection(previous?.automaticallyFloatingWindowIDs ?? [])
                        if consumeUndo {
                            // Undo brought these floats back on purpose; a later
                            // check must not undo part of it.
                            self.tabbedRetriedAutomaticFloats.formUnion(floating)
                        } else {
                            self.scheduleAutomaticFloatRetry(on: display.id, state: committedState)
                            // A preset, pane, divider, work-area, or selection
                            // change may have made room for a window that
                            // floated on its own.
                            if let earlier, earlier != layout, !waiting.isEmpty {
                                Task { @MainActor [weak self] in
                                    self?.retryAutomaticFloats(waiting, on: display.id, deferrals: 0,
                                                               transition: "layout change")
                                }
                            }
                        }
                    }
                    // Said only once the placement that makes it true landed.
                    if let appliedFeedback {
                        self.presentActionResult(succeeded: false, feedback: appliedFeedback, displayID: display.id)
                    }
                    // Pane edges or the windows that show them changed. The
                    // divider must follow both: a selection changes which
                    // window a divider drag resizes. Window events from our
                    // own writes are suppressed and do not refresh it.
                    let dividerWindows = try? self.system.cachedVisibleWindows(refreshing: Set(windows.map(\.id)))
                    self.refreshDividerBoundaries(windows: dividerWindows)
                }
            } else {
                Self.tabbedLog.error("placement failed\(gestureSourceID == nil ? "" : " after a drag", privacy: .public): \(outcome.failureReason ?? "", privacy: .private)")
                if self.rejectTabbedEntry(on: display.id, outcome: outcome, selected: state.selectedWindowIDs, windows: windows) { return }
                _ = restoreGestureMembership()
                // Windows the placement would have returned stay automatic
                // floats; they get their one later check or a repair.
                if let stored = self.sessionStore.session(for: display.id)?.tabbedState {
                    self.scheduleAutomaticFloatRetry(on: display.id, state: stored)
                }
                // A new window refused the size its pane offered. Adopt it
                // again, once, with the minimum the write revealed: it joins
                // a pane that fits it or floats, and that result explains
                // itself.
                var readoptsArrivals = false
                let fresh = arrivals.subtracting(self.tabbedReadoptedArrivals)
                if case .failed = outcome, !fresh.isEmpty { readoptsArrivals = true }
                if readoptsArrivals {
                    self.tabbedReadoptedArrivals.formUnion(fresh)
                    self.tabbedNeedsRefresh.insert(display.id)
                }
                let reports = reportsFailure && !readoptsArrivals
                if reportsFailure { self.statusMessage = readoptsArrivals ? nil : outcome.failureReason }
                if case .degraded = outcome {
                    self.sessionStore.update(display.id) { $0.suspendAutomaticWrites(observing: windows) }
                } else if let restored = self.sessionStore.session(for: display.id) {
                    // A rejection before any write has nothing to roll back;
                    // the early raise is undone here. After a rollback focus
                    // is already back and is not activated again.
                    if let earlyRaise { self.undoEarlyTabRaise(earlyRaise, afterPlacement: true) }
                    // A complete rollback raised the previous selections.
                    // Put their curtains below them again as well.
                    self.showTabbed(session: restored, display: display, windows: windows)
                }
                if reports {
                    self.presentActionResult(succeeded: false, error: outcome.failureReason,
                                             feedback: fitFailure?.feedback, displayID: display.id)
                }
                // An earlier step of this gesture may have pointed the
                // divider at a selection the rollback just reverted.
                self.refreshDividerBoundaries()
            }
            self.drainTabbedQueuedIntent(on: display.id, sessionID: original.id)
            if self.tabbedNeedsFocusRefresh || repairsStackingAfterSelection { self.handleTabbedFocus() }
            // An edge resize released during this placement is read now.
            self.schedulePendingWindowEvents()
        }
        // A placement that finished in this turn has already cleared its own entry.
        if tabbedTaskIDs[display.id] == taskID { tabbedTasks[display.id] = placement }
    }

    /// `Task.immediate` runs the placement up to its first suspension before returning.
    private static func startTabbedPlacement(
        immediately: Bool, _ operation: sending @escaping @isolated(any) () async -> Void
    ) -> Task<Void, Never> {
        immediately ? Task.immediate(operation: operation) : Task(operation: operation)
    }

    /// Each known stepped window's grid per axis. One length is a grid that
    /// only grows a pane too small for it: a window held up by a minimum the
    /// model does not know settles at one length too.
    private var tabbedSteppedGrids: [WindowID: [SplitAxis: SteppedGrid]] {
        tabbedSteppedWindows.mapValues { $0.compactMapValues { SteppedGrid(observed: $0) } }.filter { !$0.value.isEmpty }
    }

    /// Asks each window with a grid for the length on it that fits its area.
    private func requestingSteppedLengths(_ placements: [Placement]) -> [Placement] {
        TabbedLayoutState.requestingSteppedGrids(placements, tabbedSteppedGrids)
    }

    /// Records each length a window settled at off its request, by more than
    /// the half point that rounding a fractional request explains. A length
    /// that takes its request proves no step: a window with a minimum near
    /// its pane takes any larger request. A window that settles off a request
    /// on its own grid has a new grid, such as after a font change, so its
    /// lengths start again from this one.
    /// - Returns: Whether the window's lengths changed.
    @discardableResult
    private func recordSteppedSize(_ id: WindowID, requested: BTSize, settled: BTSize, windows: [WindowSnapshot]) -> Bool {
        let before = tabbedSteppedWindows[id]
        var axes = tabbedSteppedWindows[id] ?? [:]
        // A window held up at its known minimum shows that minimum, not a step.
        let minimum = windows.first { $0.id == id }?.constraints.minimumSize
        for (axis, asked, length, floor) in [(SplitAxis.vertical, requested.width, settled.width, minimum?.width),
                                             (.horizontal, requested.height, settled.height, minimum?.height)]
        where abs(length - asked) > 0.5 && !(length > asked && floor.map { abs(length - $0) <= 2 } == true) {
            let lengths = axes[axis] ?? []
            if SteppedGrid(observed: lengths)?.contains(asked) == true {
                axes[axis] = [length]
            } else {
                axes[axis] = Array((lengths.filter { abs($0 - length) > 0.5 } + [length]).suffix(6))
            }
        }
        if !axes.isEmpty { tabbedSteppedWindows[id] = axes }
        return tabbedSteppedWindows[id] != before
    }

    /// Names the window a Tabbed placement cannot show and what is in its way.
    private func tabbedFitFailure(
        showing id: WindowID, in state: TabbedLayoutState, windows: [WindowSnapshot], bounds: BTRect
    ) -> TabbedFitFailure? {
        guard let problem = state.fitProblem(showing: id, in: bounds, windows: windows) else { return nil }
        let byID = Dictionary(windows.map { ($0.id, $0) }) { first, _ in first }
        func name(_ id: WindowID) -> String { byID[id].map(Self.displayName(of:)) ?? "This window" }
        let window = name(id)
        let doesNotFit = ResultPillLayout.title(naming: window) { "\($0) doesn’t fit here" }
        switch problem {
        case .largerThanDisplay:
            return TabbedFitFailure(title: ResultPillLayout.title(naming: window) { "\($0) is too large for this display" },
                                    detail: "Use a larger display or fewer panes.")
        case .lockedDivider:
            return TabbedFitFailure(title: doesNotFit,
                                    detail: "A locked divider keeps this pane from growing.")
        case let .neighbors(ids):
            var names: [String] = []
            for other in ids where !names.contains(name(other)) { names.append(name(other)) }
            guard !names.isEmpty else {
                return TabbedFitFailure(title: doesNotFit,
                                        detail: "The empty panes beside it can’t get any smaller.")
            }
            // Shorten long names rather than the sentence, so the pill's two
            // lines still say what is in the way.
            let named = names.count > 3 ? Array(names.prefix(2)) : names
            let detail = ResultPillLayout.detail(naming: named) { titles in
                switch (titles.count, names.count) {
                case (1, _): "It would overlap \(titles[0])."
                case (2, 2): "It would overlap \(titles[0]) and \(titles[1])."
                case (2, _): "It would overlap \(titles[0]), \(titles[1]), and \(names.count - 2) more."
                default: "It would overlap \(titles[0]), \(titles[1]), and \(titles[2])."
                }
            }
            return TabbedFitFailure(title: doesNotFit, detail: detail)
        }
    }

    /// The name a person sees for a window: its title, which tells two
    /// windows of one application apart, or else its application's name.
    private static func displayName(of window: WindowSnapshot) -> String {
        if !window.title.isEmpty { return window.title }
        if let name = NSRunningApplication(processIdentifier: window.processIdentifier)?.localizedName { return name }
        if let bundleIdentifier = window.bundleIdentifier { return applicationName(for: bundleIdentifier) }
        return "This window"
    }

    private func rememberTabbedUndo(_ state: TabbedLayoutState, sessionID: DesktopSessionID,
                                    floatingFrames: [WindowID: BTRect] = [:]) {
        tabbedUndo[sessionID, default: []].append(TabbedUndoStep(state: state, floatingFrames: floatingFrames))
        if tabbedUndo[sessionID, default: []].count > 20 { tabbedUndo[sessionID]?.removeFirst() }
    }

    /// True while a Tabbed placement runs or waits on any display. For tests.
    var hasPendingTabbedPlacement: Bool { !tabbedTasks.isEmpty || !tabbedNeedsReapply.isEmpty }

    private func isTabbedBusy(on displayID: DisplayID) -> Bool {
        tabbedTasks[displayID] != nil || (activeBentoDrag?.session.displayID == displayID
            && activeBentoDrag?.layoutSession.mode == .tabbed)
    }

    /// - Parameter raisesEarly: A press or command raises a selected tab
    ///   before the placement. A selection that follows a focus change the
    ///   user made does not: that window is already in front.
    private func handleTabbed(_ intent: TabbedUIIntent, on displayID: DisplayID, raisesEarly: Bool = true) {
        // A manual destination supersedes the request. Observing focus on another
        // pane only changes selection; the captured destination still owns the arrival.
        if raisesEarly { cancelPaneApplicationRequest() }
        guard !isStabilizingSpace, !isShutDown,
              var session = sessionStore.session(for: displayID), session.mode == .tabbed,
              let display = system.displays().first(where: { $0.id == displayID }),
              var state = session.tabbedState else { return }
        if isTabbedBusy(on: displayID) {
            tabbedQueuedIntents[displayID, default: []].append(.ui(intent))
            tabbedOverlays[displayID]?.yieldPressSelection()
            return
        }
        // A hidden tab that joined when the desktop entered Tabbed was never
        // measured. Measure it now, while it is still behind its pane's
        // selected tab, so its placement can grow the pane at once.
        if case let .select(id) = intent, state.hiddenWindowIDs.contains(id) {
            let original = (try? system.windowSnapshots(ids: [id]))?.first.map { Placement(windowID: id, frame: $0.frame) }
            if case let .degraded(reason) = coordinator.probeMinimumSizes(for: [id]) {
                // Put the window back now: a selection that does not fit
                // writes no frames, so it cannot be left to the placement.
                Self.bentoLog.error("\(reason, privacy: .private)")
                if let original, !coordinator.applyPlacements([original], recordHistory: false).isApplied {
                    statusMessage = reason
                    presentActionResult(succeeded: false, error: reason, displayID: displayID)
                }
            }
        }
        // A selected tab's frame is already in its pane, so it comes to the
        // front before anything is read. The placement below verifies it; a
        // selection rejected before that placement undoes the raise.
        var earlyRaise: TabbedEarlyRaise?
        if raisesEarly, case let .select(id) = intent,
           let pane = state.panes.first(where: { $0.tabs.contains(id) && $0.selected != id }) {
            tabbedFocusSuppressedUntil = tabbedClock.now.advanced(by: .milliseconds(300))
            tabbedIntendedFocus = (id, tabbedClock.now.advanced(by: .seconds(1)))
            if coordinator.focusTabbedWindow(id).isApplied {
                earlyRaise = TabbedEarlyRaise(raised: id, previousSelected: pane.selected, previousFocus: state.activeWindowID)
            }
        }
        var handedOff = false
        defer {
            if !handedOff {
                if let earlyRaise { undoEarlyTabRaise(earlyRaise) }
                if case let .select(id) = intent { tabbedOverlays[displayID]?.dropPressedSelection(of: id) }
            }
        }
        // Refresh only this layout's windows when the snapshot cache is valid;
        // a full scan of every application costs 10-40 ms per action.
        guard let allWindows = (try? system.cachedVisibleWindows(refreshing: Set(state.windowIDs)))
                ?? (try? observeVisibleWindows()) else { return }
        let observation = system.nativeDesktopObservation()
        guard observation?.allowsAutomaticLayout(on: displayID) != false else { return }
        var windows = ignoringOversizedSeeds(bentoEligible((observation?.windowsOnCurrentSpaces(allWindows) ?? allWindows)
            .filter { $0.displayID == displayID && $0.isEligible && !$0.isFloating }), in: display.visibleFrame)
        var focus: WindowID?
        var undo = true
        var consumeUndo = false
        var selectionOnly = false
        var restorationFrames: [WindowID: BTRect] = [:]
        var appliedFeedback: ResultPillFeedback?
        switch intent {
        case let .select(id):
            guard state.paneID(containing: id) != nil else { return }
            state.select(id); focus = id; undo = false; selectionOnly = true
        case let .activate(id):
            guard state.panes.contains(where: { $0.id == id }) else { return }
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
        // A tab drag whose press selected the dragged tab gives its source
        // pane back the tab shown before that press.
        case let .float(id, reselecting):
            guard windows.contains(where: { $0.id == id }) else { return }
            state.float(id, reselecting: reselecting); focus = id
            session.endFollowing()
        case let .move(id, pane, index, reselecting):
            guard state.panes.contains(where: { $0.id == pane }),
                  windows.contains(where: { $0.id == id }) else { return }
            state.move(id, to: pane, at: index, reselecting: reselecting); focus = id
        case let .split(id, pane, edge, reselecting):
            guard state.panes.contains(where: { $0.id == pane }),
                  windows.contains(where: { $0.id == id }) else { return }
            state.split(paneID: pane, moving: id, edge: edge, reselecting: reselecting); focus = id
        case let .preset(preset, grouping):
            session.endFollowing()
            state.applyPreset(preset, grouping: grouping)
            focus = state.activeWindowID
        case .undo:
            guard let step = tabbedUndo[session.id]?.last else { return }
            var previous = step.state
            previous.setPresentation(configuration.tabbedStripPresentation)
            restorationFrames = step.floatingFrames
            let visible = Set(windows.map(\.id))
            previous.reconcile(windowIDs: windows.map(\.id), removed: previous.windowIDs.subtracting(visible), focused: nil)
            state = previous
            consumeUndo = true
            focus = state.activeWindowID; undo = false
        case .repair:
            session.prepareForRepair()
            session.resumeAutomaticWrites()
            // Windows that floated on their own come back first, decided
            // without their application's seed; a window the user floated
            // stays floating.
            let returning = state.automaticallyFloatingWindowIDs.intersection(windows.map(\.id))
            if !returning.isEmpty {
                windows = remeasuredForRepair(returning, windows: windows, displayID: displayID)
                let before = state
                let focused = ((try? system.focusedWindow()) ?? nil)?.id ?? state.activeWindowID
                let returned = state.returnAutomaticFloats(returning, fittingIn: display.visibleFrame, windows: windows,
                                                           selecting: true, keeping: focused, followed: session.followed)
                logTabbedAdoptions(returned, transition: "repair", before: before,
                                   windows: windows, bounds: display.visibleFrame)
                let count = returned.filter { !$0.floated }.count
                if count > 0 {
                    appliedFeedback = .success(count == 1 ? "1 window returned to a pane" : "\(count) windows returned to panes")
                }
            }
            // Repair adopts every window outside the panes the same way a
            // late arrival joins, so none is left out of the layout.
            let before = state
            let arrivals = state.reconcile(windowIDs: windows.map(\.id), removed: state.windowIDs.subtracting(windows.map(\.id)),
                                           fittingIn: display.visibleFrame, windows: windows, followed: session.followed)
            logTabbedAdoptions(arrivals, transition: "repair arrival", before: before,
                               windows: windows, bounds: display.visibleFrame)
            focus = state.activeWindowID; undo = false
        case let .removePane(id): state.removeEmptyPane(id)
        case let .adjustDivider(id, delta):
            guard state.adjustDivider(id, by: delta, in: display.visibleFrame) else { return }
        }
        handedOff = true
        applyTabbedState(state, session: session, display: display, windows: windows, focus: focus,
                         rememberUndo: undo, consumeUndo: consumeUndo, selectionOnly: selectionOnly,
                         earlyRaise: earlyRaise,
                         restorationFrames: restorationFrames, appliedFeedback: appliedFeedback)
    }

    /// Prepares automatic floats for Repair Tabbed. A proven minimum stays.
    /// A window never measured is probed, and the snapshot is read again.
    /// An application's seed came from another window, so this decision
    /// does not use it.
    private func remeasuredForRepair(_ ids: Set<WindowID>, windows: [WindowSnapshot], displayID: DisplayID) -> [WindowSnapshot] {
        let originals = windows.filter { ids.contains($0.id) }.map { Placement(windowID: $0.id, frame: $0.frame) }
        if case let .degraded(reason) = coordinator.probeMinimumSizes(for: ids) {
            Self.tabbedLog.error("\(reason, privacy: .private)")
            if !coordinator.applyPlacements(originals, recordHistory: false).isApplied {
                statusMessage = reason
            }
        }
        let fresh = Dictionary(((try? system.windowSnapshots(ids: ids)) ?? []).map { ($0.id, $0) }) { first, _ in first }
        return windows.map { window in
            guard ids.contains(window.id) else { return window }
            let result = fresh[window.id].flatMap { $0.isEligible && $0.displayID == displayID ? $0 : nil } ?? window
            return Self.ignoringSeed(result)
        }
    }

    /// A seed larger than any pane would block every placement while its
    /// window is selected. Plan without it; the write shows the real minimum.
    private func ignoringOversizedSeeds(_ windows: [WindowSnapshot], in bounds: BTRect) -> [WindowSnapshot] {
        let largest = TabbedLayoutState.contentFrame(bounds, presentation: configuration.tabbedStripPresentation).size
        return windows.map { window in
            let minimum = window.constraints.minimumSize
            return minimum.width > largest.width || minimum.height > largest.height ? Self.ignoringSeed(window) : window
        }
    }

    /// The window planned with its own minimum instead of its application's
    /// seed. The write then shows its real minimum.
    private static func ignoringSeed(_ window: WindowSnapshot) -> WindowSnapshot {
        guard window.constraints.minimumSizeSource == .seed else { return window }
        var result = window
        result.constraints.minimumSize = window.constraints.unseededMinimumSize ?? WindowConstraints().minimumSize
        result.constraints.minimumSizeSource = window.constraints.unseededMinimumSizeSource ?? .default
        result.constraints.unseededMinimumSize = nil
        result.constraints.unseededMinimumSizeSource = nil
        return result
    }

    /// Checks automatic floats again once, a moment after the placement that
    /// floated them settles, with fresh snapshots: an application that was
    /// busy, or applied its size late, may fit by then.
    private func scheduleAutomaticFloatRetry(on displayID: DisplayID, state: TabbedLayoutState) {
        let floating = Set(sessionStore.sessions.values.flatMap { $0.tabbedState?.automaticallyFloatingWindowIDs ?? [] })
        tabbedRetriedAutomaticFloats.formIntersection(floating)
        let fresh = state.automaticallyFloatingWindowIDs.subtracting(tabbedRetriedAutomaticFloats)
        guard !fresh.isEmpty else { return }
        tabbedRetriedAutomaticFloats.formUnion(fresh)
        let delay = tabbedAutomaticFloatRetryDelay
        let clock = tabbedClock
        Task { @MainActor [weak self] in
            try? await clock.sleep(for: delay)
            self?.retryAutomaticFloats(fresh, on: displayID, deferrals: 0)
        }
    }

    /// A returned window is shown as its pane's selected tab, as it was
    /// visible while it floated.
    private func retryAutomaticFloats(
        _ ids: Set<WindowID>, on displayID: DisplayID, deferrals: Int, transition: String = "retry"
    ) {
        guard !isShutDown, !isStabilizingSpace,
              let session = sessionStore.session(for: displayID), session.mode == .tabbed,
              !session.automaticWritesSuspended,
              let display = system.displays().first(where: { $0.id == displayID }),
              let current = session.tabbedState,
              !ids.isDisjoint(with: current.automaticallyFloatingWindowIDs) else { return }
        // Another placement owns the display; check after it.
        if isTabbedBusy(on: displayID) || tabbedExiting.contains(displayID) {
            guard deferrals < 10 else {
                tabbedAutomaticFloatChecksGivenUp += 1
                Self.tabbedLog.debug("gave up checking automatic floats again: the display stayed busy")
                return
            }
            let deferral = tabbedAutomaticFloatRetryDeferral
            let clock = tabbedClock
            Task { @MainActor [weak self] in
                try? await clock.sleep(for: deferral)
                self?.retryAutomaticFloats(ids, on: displayID, deferrals: deferrals + 1, transition: transition)
            }
            return
        }
        tabbedAutomaticFloatChecksRun += 1
        guard let allWindows = try? observeVisibleWindows() else { return }
        let observation = system.nativeDesktopObservation()
        guard observation?.allowsAutomaticLayout(on: displayID) != false else { return }
        let windows = ignoringOversizedSeeds(bentoEligible((observation?.windowsOnCurrentSpaces(allWindows) ?? allWindows)
            .filter { $0.displayID == displayID && $0.isEligible && !$0.isFloating }), in: display.visibleFrame)
        var state = current
        // A silent check never takes the focused window's place. When focus
        // cannot be read, for example from a hung application, the active
        // pane's tab is treated as focused.
        let focused = ((try? system.focusedWindow()) ?? nil)?.id ?? current.activeWindowID
        let returned = state.returnAutomaticFloats(ids, fittingIn: display.visibleFrame, windows: windows,
                                                   selecting: true, keeping: focused, followed: session.followed)
        logTabbedAdoptions(returned, transition: transition, before: current, windows: windows, bounds: display.visibleFrame)
        guard state != current else { return }
        // The user did not ask for this check: a failure leaves the window an
        // automatic float for Repair Tabbed and only logs.
        applyTabbedState(state, session: session, display: display, windows: windows, focus: nil, reportsFailure: false)
    }

    /// Records how each window joined, or why it floats, with the inputs of
    /// the decision. Window identifiers and frames only; never titles.
    private func logTabbedAdoptions(
        _ adoptions: [TabbedAdoption], transition: String, before: TabbedLayoutState,
        windows: [WindowSnapshot], bounds: BTRect
    ) {
        guard !adoptions.isEmpty else { return }
        let byID = Dictionary(windows.map { ($0.id, $0) }) { first, _ in first }
        func text(_ frame: BTRect?) -> String {
            guard let frame else { return "none" }
            return String(format: "%.0f,%.0f %.0fx%.0f", frame.minX, frame.minY, frame.size.width, frame.size.height)
        }
        func pane(_ id: UUID) -> String { String(id.uuidString.prefix(8)) }
        for adoption in adoptions {
            let window = byID[adoption.windowID]
            let outcome: String = switch adoption.outcome {
            case let .selected(id): "selected tab of pane \(pane(id))"
            case let .hidden(id): "hidden tab of pane \(pane(id)), which can show it"
            case let .floated(reason): "floating (\(reason.rawValue))"
            }
            let trials = adoption.trials.map { "\(pane($0.paneID)) \(text($0.contentFrame)): \($0.result.rawValue)" }
                .joined(separator: "; ")
            let constraints = window?.constraints
            let minimum = constraints.map { String(format: "%.0fx%.0f", $0.minimumSize.width, $0.minimumSize.height) } ?? "none"
            Self.tabbedLog.debug("""
                \(transition, privacy: .public): window \(adoption.windowID.rawValue, privacy: .public) \
                (\(window?.bundleIdentifier ?? "unknown", privacy: .private)) -> \(outcome, privacy: .public). \
                frame \(text(window?.frame), privacy: .public), \
                resizable \(constraints.map { String($0.isResizable) } ?? "unknown", privacy: .public) \
                (\(constraints?.settabilitySource.rawValue ?? "unknown", privacy: .public)), \
                minimum \(minimum, privacy: .public) (\(constraints?.minimumSizeSource.rawValue ?? "unknown", privacy: .public)), \
                work area \(text(bounds), privacy: .public), active pane \(pane(before.activePaneID), privacy: .public), \
                trials: \(trials, privacy: .public)
                """)
        }
    }

    /// Puts back the tab order and focus from before a selection raised its
    /// tab early, when that selection is rejected before its placement.
    /// - Parameter afterPlacement: A failed placement's rollback may already
    ///   have restored focus, or the user moved it. Focus then returns only
    ///   from the early-raised tab itself.
    private func undoEarlyTabRaise(_ raise: TabbedEarlyRaise, afterPlacement: Bool = false) {
        tabbedIntendedFocus = nil
        if let previous = raise.previousSelected { _ = coordinator.raiseTabbedWindows([previous]) }
        guard let focus = raise.previousFocus else { return }
        if !afterPlacement || (try? system.focusedWindow())?.id == raise.raised {
            _ = coordinator.focusTabbedWindow(focus)
        }
    }

    /// Keeps a native edge resize's frame changes until the button is
    /// released, then processes them again.
    private func deferTabbedResizeUntilRelease(_ windowIDs: Set<WindowID>) {
        pendingWindowEvents.recordFrameChanges(windowIDs)
        guard tabbedResizeReleaseTask == nil else { return }
        let clock = tabbedClock
        tabbedResizeReleaseTask = Task { @MainActor [weak self] in
            while !Task.isCancelled, self?.primaryButtonIsPressed() == true {
                try? await clock.sleep(for: .milliseconds(50))
            }
            guard let self, !Task.isCancelled else { return }
            self.tabbedResizeReleaseTask = nil
            self.schedulePendingWindowEvents()
        }
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
        guard !changed.isEmpty else {
            // The edge came back to where it started. The 30 Hz preview can
            // have skipped that last step, so the strips return to the panes,
            // but only once the button is released: the edge may still move.
            // A pass can also come from another window's event while the edge
            // is held; the strips keep the preview until release either way.
            if primaryButtonIsPressed() {
                let paneEvents = externalIDs.intersection(paneWindows.map(\.id))
                if !paneEvents.isEmpty { deferTabbedResizeUntilRelease(paneEvents) }
                return
            }
            if tabbedTasks[display.id] == nil, let overlay = tabbedOverlays[display.id], overlay.state != state {
                overlay.refreshResize(state: state, bounds: display.visibleFrame)
            }
            return
        }
        // A placement in progress reschedules these changes when it finishes.
        if tabbedTasks[display.id] != nil {
            pendingWindowEvents.recordFrameChanges(changed)
            return
        }
        if primaryButtonIsPressed() {
            deferTabbedResizeUntilRelease(changed)
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

    /// The layout the tab strips currently show, for tests.
    func presentedTabbedState(on displayID: DisplayID) -> TabbedLayoutState? { tabbedOverlays[displayID]?.state }

    /// While the user drags a selected tab's own edge, the tab strips follow
    /// the shared boundary live, as they do for a divider drag. Hidden tabs
    /// and the committed layout still follow only at release.
    private func previewTabbedNativeResize(_ windowID: WindowID) {
        guard primaryButtonIsPressed(), !dividerResize.isDragging,
              (lastTabbedNativeResizePreview.map { $0.duration(to: tabbedClock.now) >= .seconds(1.0 / 30) } ?? true) else { return }
        guard let session = sessionStore.sessions.values.first(where: {
                  $0.mode == .tabbed && $0.tabbedState?.selectedWindowIDs.contains(windowID) == true
              }),
              // A suspended layout does not adopt the resize at release, so
              // the strips must not preview it either.
              !session.automaticWritesSuspended,
              tabbedTasks[session.displayID] == nil,
              let state = session.tabbedState,
              let overlay = tabbedOverlays[session.displayID],
              let display = system.displays().first(where: { $0.id == session.displayID }),
              let windows = try? system.windowSnapshots(ids: Set(state.selectedWindowIDs))
        else { return }
        lastTabbedNativeResizePreview = tabbedClock.now
        var frames = session.lastObservedFrames.filter { state.selectedWindowIDs.contains($0.key) }
        for window in windows where window.id == windowID { frames[window.id] = window.frame }
        guard let adopted = state.adoptingResize(
            of: [windowID], frames: frames,
            constraints: Dictionary(uniqueKeysWithValues: windows.map { ($0.id, $0.constraints) }),
            in: display.visibleFrame, tolerance: configuration.adjacencyTolerance
        ) else { return }
        overlay.refreshResize(state: adopted, bounds: display.visibleFrame)
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
              let windows = try? observeVisibleWindows()
        else { return }
        // The Bento change already committed, so the state from before it is
        // the Undo step.
        if let undoBaseline, undoBaseline != state { rememberTabbedUndo(undoBaseline, sessionID: session.id) }
        let displayWindows = bentoEligible(windows.filter { $0.displayID == displayID && $0.isEligible && !$0.isFloating })
        applyTabbedState(state, session: session, display: display, windows: displayWindows, focus: nil)
    }

    private func drainTabbedQueuedIntent(on displayID: DisplayID, sessionID: DesktopSessionID) {
        guard !Task.isCancelled, !isStabilizingSpace, !isShutDown,
              sessionStore.session(for: displayID)?.id == sessionID,
              activeMode(for: displayID) == .tabbed else {
            tabbedQueuedIntents.removeValue(forKey: displayID)
            tabbedNeedsRefresh.remove(displayID)
            tabbedNeedsReapply.remove(displayID)
            return
        }
        // Synchronous actions (empty-pane activation, close, unavailable
        // targets) do not start a task. Continue until a placement owns the
        // slot, keeping background work pending behind accepted user actions.
        while !isTabbedBusy(on: displayID),
              var queued = tabbedQueuedIntents[displayID], !queued.isEmpty {
            let intent = queued.removeFirst()
            tabbedQueuedIntents[displayID] = queued.isEmpty ? nil : queued
            if case let .ui(.select(id)) = intent,
               let state = sessionStore.session(for: displayID)?.tabbedState,
               let pane = state.paneID(containing: id) {
                // Resolve membership after the preceding placement settles.
                // Within this selection run, only each pane's latest click
                // matters. A structural action ends the run.
                let laterSelections = queued.prefix {
                    if case .ui(.select) = $0 { return true }
                    return false
                }
                if laterSelections.contains(where: {
                    if case let .ui(.select(other)) = $0 { return state.paneID(containing: other) == pane }
                    return false
                }) { continue }
            }
            switch intent {
            case let .ui(intent): handleTabbed(intent, on: displayID)
            case let .snap(id, action, space): performTabbedSnap(action, windowID: id, displayID: displayID, expectedSpaceID: space)
            case let .command(action, id, space): performTabbedCommand(action, windowID: id, displayID: displayID, expectedSpaceID: space)
            }
        }
        guard !isTabbedBusy(on: displayID) else { return }
        if tabbedNeedsReapply.remove(displayID) != nil {
            refreshTabbedAfterBentoChange(displayID: displayID)
        }
        if tabbedTasks[displayID] == nil, tabbedNeedsRefresh.remove(displayID) != nil {
            refreshActiveWindows(force: false)
        }
    }

    var activeTabbedState: TabbedLayoutState? {
        activeDisplayID.flatMap { sessionStore.session(for: $0)?.tabbedState }
    }

    func showTabBar() {
        guard !isShutDown, !isStabilizingSpace, let displayID = actionDisplayID(),
              sessionStore.session(for: displayID)?.mode == .tabbed else {
            statusMessage = "Show Tab Bar is available on a Tabbed desktop."
            return
        }
        guard let overlay = tabbedOverlays[displayID] else {
            statusMessage = "The tab bar is not available right now."
            return
        }
        guard overlay.showTabBar() else {
            statusMessage = overlay.showTabBarFailureReason
            return
        }
        statusMessage = nil
    }

    func performTabbed(_ intent: TabbedUIIntent) {
        invalidateMenuPanelFocusReplay()
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
        let clock = tabbedClock
        let delay = max(.milliseconds(80), tabbedFocusSuppressedUntil.map { tabbedClock.now.duration(to: $0) } ?? .zero)
        tabbedFocusTask = Task { @MainActor [weak self] in
            try? await clock.sleep(for: delay)
            guard let self, !Task.isCancelled, !self.isStabilizingSpace else { return }
            // An unreadable focus cannot become readable by retrying after each
            // placement, so only busy displays keep the refresh pending.
            let focused = (try? self.system.focusedWindow()) ?? nil
            if let focused, self.isTabbedBusy(on: focused.displayID) { return }
            self.tabbedNeedsFocusRefresh = false
            if let focused, self.correctStolenTabbedFocus(focused) { return }
            if let focused, self.isFrontmost(focused),
               let session = self.sessionStore.session(for: focused.displayID), session.mode == .tabbed,
               !session.automaticWritesSuspended, let state = session.tabbedState,
               state.windowIDs.contains(focused.id), state.activeWindowID != focused.id {
                // A main window reported in place of an unreadable popup is
                // not the user's choice. Selecting it would close the popup.
                guard self.isApplicationFocusedWindow(focused) else {
                    Self.tabbedLog.debug("selection skipped: \(focused.id.rawValue, privacy: .public) is not its application's focused window")
                    self.repairTabbedStacking()
                    return
                }
                self.handleTabbed(.select(focused.id), on: focused.displayID, raisesEarly: false)
                return
            }
            self.repairTabbedStacking()
        }
    }

    /// Activating an application makes its main window key. When that is
    /// another tab of the application the user just selected, focus returns
    /// to the selected tab once instead of changing the selection.
    private func correctStolenTabbedFocus(_ focused: WindowSnapshot) -> Bool {
        guard let intended = tabbedIntendedFocus else { return false }
        // Once the selected tab has had focus, a later focus change is the
        // user's own choice. Expiry ends the correction too.
        guard intended.until > tabbedClock.now, focused.id != intended.windowID else { tabbedIntendedFocus = nil; return false }
        guard isFrontmost(focused),
              let session = sessionStore.session(for: focused.displayID), session.mode == .tabbed,
              let state = session.tabbedState, state.selectedWindowIDs.contains(intended.windowID),
              state.windowIDs.contains(focused.id),
              let target = ((try? observeVisibleWindows()) ?? []).first(where: { $0.id == intended.windowID }),
              target.processIdentifier == focused.processIdentifier else { return false }
        // A main window reported in place of the application's real focused
        // window, such as a popup, did not take focus from the selected tab.
        guard isApplicationFocusedWindow(focused) else {
            Self.tabbedLog.debug("focus correction skipped: \(focused.id.rawValue, privacy: .public) is not its application's focused window")
            return false
        }
        tabbedIntendedFocus = nil
        Self.tabbedLog.debug("focus correction: \(focused.id.rawValue, privacy: .public) took focus from selected tab \(intended.windowID.rawValue, privacy: .public)")
        tabbedFocusSuppressedUntil = tabbedClock.now.advanced(by: .milliseconds(300))
        guard coordinator.focusTabbedWindow(intended.windowID).isApplied else {
            tabbedFocusSuppressedUntil = nil
            return false
        }
        repairTabbedStacking()
        return true
    }

    /// `focusedWindow()` skips BetterTile and applications it cannot read,
    /// then reports the last managed application's window. Selecting a tab
    /// activates its application, so only a window whose application is
    /// really in front may select one.
    private func isFrontmost(_ window: WindowSnapshot) -> Bool {
        guard let frontmost = (system as? any TabbedWindowSystem)?.frontmostProcessIdentifier else { return true }
        return frontmost == window.processIdentifier
    }

    /// `focusedWindow()` reports an application's main window when it cannot
    /// read the focused window, such as a small popup. Only a window its
    /// application confirms as focused may select a tab or correct focus.
    private func isApplicationFocusedWindow(_ window: WindowSnapshot) -> Bool {
        guard let tabbed = system as? any TabbedWindowSystem else { return true }
        return tabbed.applicationFocus(of: window) == .confirmed
    }

    /// The window with keyboard focus in the frontmost application. Nil
    /// while BetterTile or an application it cannot read is in front, and
    /// when no window has focus, such as on Finder's desktop. A popup that
    /// closes without focus, such as a browser bubble, or an unreadable
    /// focus, is transient. A standard window, including one the user
    /// floated, a dialog, and a floating panel are not: raising them last
    /// gives focus back.
    private func tabbedKeyWindow() -> TabbedKeyWindow? {
        guard let focused = (try? system.focusedWindow()) ?? nil, isFrontmost(focused),
              let tabbed = system as? any TabbedWindowSystem else { return nil }
        let transient = TabbedKeyWindow.transient(processIdentifier: focused.processIdentifier)
        switch tabbed.applicationFocus(of: focused) {
        case .confirmed:
            return !isTabbedMember(focused.id) && tabbed.isTransientPopup(focused) ? transient : .window(focused.id)
        case .otherWindow(isTransientPopup: true), .unknown: return transient
        case .otherWindow, .noWindow: return nil
        }
    }

    /// The watchdog retries a repair that waited for a popup, in case the
    /// popup closed without a focus notification.
    func retryDeferredTabbedRepair() {
        // A display that left Tabbed has nothing left to repair.
        tabbedRepairDeferred = tabbedRepairDeferred.filter { activeMode(for: $0) == .tabbed }
        guard !tabbedRepairDeferred.isEmpty, !isStabilizingSpace else { return }
        Self.tabbedLog.debug("retrying a deferred stacking repair")
        repairTabbedStacking(on: tabbedRepairDeferred)
    }

    /// Activation can bring an application's hidden tabs in front of their
    /// panes' selected tabs. This reads the real window order and raises only
    /// what must move. It never activates an application, changes a
    /// selection, or moves a window. Chrome then reorders around the
    /// selected tabs.
    /// Returns false when the window inventory could not be read.
    @discardableResult
    private func repairTabbedStacking(on displayIDs: Set<DisplayID>? = nil) -> Bool {
        guard let windows = try? observeVisibleWindows() else { return false }
        let displays = system.displays()
        for session in sessionStore.sessions.values where session.mode == .tabbed {
            if let displayIDs, !displayIDs.contains(session.displayID) { continue }
            guard !session.automaticWritesSuspended, tabbedTasks[session.displayID] == nil,
                  !nativeFullscreenDisplayIDs.contains(session.displayID),
                  let state = session.tabbedState,
                  let display = displays.first(where: { $0.id == session.displayID }) else { continue }
            if presentsTabbedChrome {
                showTabbed(session: session, display: display, windows: windows)
            } else {
                _ = repairTabbedOrder(state: state, windows: windows, bounds: display.visibleFrame, displayID: display.id)
            }
        }
        return true
    }

    /// A shared curtain needs every selected tab above every inactive tab.
    /// Verify the readback after raising; never expose a curtain on intent alone.
    /// Returns the windows the curtain may go directly behind, preferred
    /// first: the backmost kept window or selected tab, then the backmost
    /// selected tab. Nil while the order is not verified.
    /// - Parameter displayID: The display whose deferred repair this
    ///   records or clears.
    func repairTabbedOrder(state: TabbedLayoutState, windows: [WindowSnapshot], bounds: BTRect,
                           displayID: DisplayID? = nil) -> [WindowID]? {
        guard let system = system as? any TabbedWindowSystem else { return nil }
        let chrome = allTabbedOverlays.reduce(into: Set<Int>()) { $0.formUnion($1.windowNumbers) }
        // Floating windows and other windows outside the panes must stay
        // visible above the curtain.
        let aboveCurtain = Set(windows.filter { window in
            window.isEligible && !state.windowIDs.contains(window.id) && window.frame.intersection(bounds) != nil
        }.map(\.id)).union(state.floatingWindowIDs)
        // Floating windows keep their place in the order; the curtain goes
        // behind them. A window of a background application often ignores
        // AXRaise, so raising it never verified and every focus event
        // repeated the raise. Raising one of the front application takes
        // focus, and raising the key window again last would put it back.
        // The front application's floats keep the older raise rule when its
        // key window is transient (a popup, or a focus that cannot be read),
        // so those raises wait, and when no window has focus, such as on
        // Finder's desktop, so they run at once.
        // The focus read runs only when the front application has a
        // floating window. Ineligible windows have no validated number to
        // order the curtain against.
        let front = system.frontmostProcessIdentifier
        let floats = windows.filter {
            aboveCurtain.contains($0.id) && $0.isEligible && $0.frame.intersection(bounds) != nil
        }
        let key = floats.contains { $0.processIdentifier == front } ? tabbedKeyWindow() : nil
        let keepsFrontFloats = if case .window? = key { true } else { false }
        let keptInPlace = Set(floats.filter { keepsFrontFloats || $0.processIdentifier != front }.map(\.id))
        // With no readable front application no float is known to be in
        // the background, so none is left under the curtain unraised.
        let ignoresRaise = front == nil ? [] : Set(floats.filter { $0.processIdentifier != front }.map(\.id))
        guard var order = system.stackingOrder(for: windows, excluding: chrome),
              let repair = state.sharedCurtainStackingRepair(order: order, curtainBounds: bounds,
                                                             aboveCurtain: aboveCurtain, keptInPlace: keptInPlace,
                                                             ignoresRaise: ignoresRaise) else {
            // No raise can repair an order that cannot be read; nothing waits.
            if let displayID { tabbedRepairDeferred.remove(displayID) }
            return nil
        }
        if !repair.isEmpty {
            // Never reorder foreign windows during a held resize.
            guard !dividerResize.isDragging, tabbedResizeReleaseTask == nil else { return nil }
            // A raise of another window of the key window's application moves
            // keyboard focus to it. A key tab or standard window is raised
            // again last. A key popup would close, so raises of its
            // application, and raises that would cover it, wait until focus
            // returns; the curtain is held as for an unverified order.
            let keyPlan = state.keyPreservingRaisePlan(
                repair,
                key: key ?? tabbedKeyWindow(),
                processIdentifiers: Dictionary(windows.map { ($0.id, $0.processIdentifier) }) { first, _ in first },
                frames: Dictionary(windows.map { ($0.id, $0.frame) }) { first, _ in first }
            )
            if let displayID {
                if keyPlan.isDeferred { tabbedRepairDeferred.insert(displayID) } else { tabbedRepairDeferred.remove(displayID) }
            }
            if keyPlan.isDeferred {
                Self.tabbedLog.debug("stacking repair deferred: a popup has focus; \(repair.count - keyPlan.raises.count, privacy: .public) of \(repair.count, privacy: .public) raises wait")
            }
            let plan = keyPlan.raises
            guard !plan.isEmpty else { return nil }
            Self.tabbedLog.debug("stacking repair: raising \(plan.map(\.rawValue).joined(separator: ","), privacy: .public); floats kept in place: \(keptInPlace.map(\.rawValue).sorted().joined(separator: ","), privacy: .public)")
            // Focus changes caused by these raises are not user selections.
            tabbedFocusSuppressedUntil = max(tabbedFocusSuppressedUntil ?? tabbedClock.now, tabbedClock.now.advanced(by: .milliseconds(300)))
            let outcome = coordinator.raiseTabbedWindows(plan)
            guard outcome.isApplied else { statusMessage = outcome.failureReason; return nil }
            guard let readback = system.stackingOrder(for: windows, excluding: chrome) else { return nil }
            order = readback
        }
        guard state.sharedCurtainStackingRepair(order: order, curtainBounds: bounds, aboveCurtain: aboveCurtain,
                                                keptInPlace: keptInPlace, ignoresRaise: ignoresRaise)?.isEmpty == true
        else { return nil }
        if let displayID { tabbedRepairDeferred.remove(displayID) }
        return [state.curtainAnchor(order: order, keptInPlace: keptInPlace, ignoresRaise: ignoresRaise),
                state.curtainAnchor(order: order)].compactMap { $0 }
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

    /// Drops the committed layouts of sessions whose display or Space is gone.
    private func forgetEndedTabbedSessions<IDs: Sequence<DisplayID>>(displayIDs: IDs) {
        let sessions = displayIDs.flatMap { sessionStore.allSessions(for: $0) }
        let tabbed = Set(sessions.filter { $0.mode == .tabbed }.map(\.id))
        for id in spacePanelOverlays.keys.filter({ !tabbed.contains($0) }) {
            guard let overlay = spacePanelOverlays.removeValue(forKey: id) else { continue }
            overlay.hide()
            tabbedOverlays = tabbedOverlays.filter { $0.value !== overlay }
            spacePanelCorrections.remove(id)
        }
        let live = Set(sessions.map(\.id))
        tabbedCommittedLayouts = tabbedCommittedLayouts.filter { live.contains($0.key) }
        tabbedEntryBaselines = tabbedEntryBaselines.filter { live.contains($0.key) }
    }

    private func leaveTabbed(displayID: DisplayID, destination: LayoutMode, focusedWindowID: WindowID?) {
        guard tabbedExiting.insert(displayID).inserted else { return }
        if let session = sessionStore.session(for: displayID) {
            tabbedCommittedLayouts.removeValue(forKey: session.id)
            let ids = (session.tabbedState?.windowIDs ?? []).union(session.tabbedState?.floatingWindowIDs ?? [])
            for id in ids { tabbedSteppedWindows.removeValue(forKey: id) }
        }
        tabbedRepairDeferred.remove(displayID)
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
                  let windows = try? self.observeVisibleWindows() else { return }
            if destination == .manual {
                let placements = self.tabbedRestorationPlacements(baselineFrames: session.tabbedBaselineFrames, on: display, windows: windows)
                let outcome: WindowMutationOutcome = placements.isEmpty ? .applied : self.coordinator.applyPlacements(placements, recordHistory: false)
                if !outcome.isApplied { self.statusMessage = outcome.failureReason; return }
            }
            // Bento takes over the tree: every hidden tab gets a pane. Native
            // leaves the tree alone, so the tab groups return with Tabbed.
            if destination == .bento, let state = session.tabbedState {
                var bento = state.unstacked(in: display.visibleFrame)
                // A fixed-size window takes no Bento pane; it floats, as when
                // it arrives on a Bento desktop.
                for window in windows where !(window.constraints.isResizable && window.constraints.isMovable) {
                    bento.remove(window.id)
                }
                session.bentoState = bento
                session.isBentoInitialized = session.bentoState.root != nil
                // Bento offers a pane again only to windows it floated itself.
                session.automaticallyFloatingWindowIDs = state.automaticallyFloatingWindowIDs
                session.tabbedState = nil
            }
            session.mode = destination
            session.resumeAutomaticWrites()
            guard self.sessionStore.commit(session, replacing: session.revision) != nil else { return }
            self.tabbedEntryBaselines.removeValue(forKey: session.id)
            self.tabbedOverlays[displayID]?.hide()
            self.tabbedOverlays.removeValue(forKey: displayID)
            self.forgetEndedTabbedSessions(displayIDs: self.system.displays().map(\.id))
            if destination == .bento, var bento = self.sessionStore.session(for: displayID), bento.bentoState.root != nil {
                // Keep the arrangement the user built: apply the unstacked tree
                // instead of re-tiling from scratch.
                let displayWindows = self.bentoEligible(windows.filter {
                    $0.displayID == displayID && $0.isEligible && !$0.isFloating
                })
                let placements = BentoLayoutEngine(state: bento.bentoState).placements(for: displayWindows, in: display)
                let result = self.commitBentoProposal(placements, session: &bento, display: display, surfaceFailure: false)
                if result.result != .committed { self.repairBento(displayID: displayID, focusedWindowID: focusedWindowID) }
                self.refreshDividerBoundaries()
            } else if destination == .bento {
                self.repairBento(displayID: displayID, focusedWindowID: focusedWindowID)
            } else {
                self.refreshActiveWindows(force: true)
            }
        }
    }
}

/// The tab order and focus before a selection raised its tab early.
struct TabbedEarlyRaise {
    let raised: WindowID
    let previousSelected: WindowID?
    let previousFocus: WindowID?
}

/// A Tabbed placement that cannot show a window. The pill uses the title and
/// detail as written; other surfaces read the description.
private struct TabbedFitFailure: LocalizedError {
    var title: String
    var detail: String
    var errorDescription: String? { "\(title). \(detail)" }
    var feedback: ResultPillFeedback { .failure(title: title, detail: detail) }
}

// MARK: - User-requested application arrival in a captured pane
extension BetterTileModel {
    @discardableResult
    func beginPaneApplicationPicker(paneID: UUID, on displayID: DisplayID) -> PaneApplicationRequest? {
        cancelPaneApplicationRequest()
        guard hasAccessibilityPermission else {
            let reason = "Enable Accessibility for BetterTile in System Settings to add windows to a pane."
            statusMessage = reason
            presentActionResult(succeeded: false, error: reason, displayID: displayID)
            return nil
        }
        guard !isShutDown, !isStabilizingSpace,
              !isTabbedBusy(on: displayID),
              let session = sessionStore.session(for: displayID), session.mode == .tabbed,
              !session.automaticWritesSuspended, tabbedEntryBaselines[session.id] == nil,
              let state = session.tabbedState, let index = state.panes.firstIndex(where: { $0.id == paneID }),
              let display = system.displays().first(where: { $0.id == displayID }) else { return nil }
        let observation = system.refreshNativeDesktopObservation()
        guard observation?.allowsAutomaticLayout(on: displayID) != false,
              observation == nil || session.nativeSpaceID == observation?.currentSpace(on: displayID) else { return nil }
        let request = PaneApplicationRequest(paneID: paneID, paneNumber: index + 1, displayID: displayID,
            sessionID: session.id, spaceID: observation?.currentSpace(on: displayID), generation: spaceStabilizationGeneration,
            workArea: display.visibleFrame)
        paneApplicationRequest = request
        request.windowAtPoint = { [weak self] point in
            try? self?.system.window(at: point)
        }
        updatePaneApplicationPickerWindows(request)
        request.windows = { [weak request] application in
            request?.pickerWindowsByApplication[application.id]
        }
        request.onChooseWindow = { [weak self] application, window in
            self?.useChoosingPaneApplicationWindow(WindowID(rawValue: window.id), application: application, requestID: request.id)
        }
        request.onChoose = { [weak self] app in self?.choosePaneApplication(app, requestID: request.id) }
        request.onExisting = { [weak self] id in self?.useExistingPaneApplicationWindow(id, requestID: request.id) }
        request.onRetry = { [weak self] in
            guard let app = request.application else { return }
            self?.choosePaneApplication(app, requestID: request.id, retry: true)
        }
        request.onCancel = { [weak self] in self?.cancelPaneApplicationRequest(id: request.id) }
        tabbedOverlays[displayID]?.holdApplicationPicker(paneID, enabled: true)
        return request
    }

    private func resumeIdlePaneApplicationRequest(on displayID: DisplayID) {
        guard let request = paneApplicationRequest, request.displayID == displayID, !request.needsPolling else { return }
        advancePaneApplicationRequest()
    }

    private func syncPaneApplicationPolling() {
        guard let request = paneApplicationRequest, request.needsPolling else {
            paneApplicationTask?.cancel(); paneApplicationTask = nil
            return
        }
        guard paneApplicationTask == nil else { return }
        let clock = paneApplicationClock
        paneApplicationTask = Task { @MainActor [weak self, weak request] in
            while !Task.isCancelled {
                try? await clock.sleep(for: .milliseconds(200))
                guard !Task.isCancelled, let self, let request,
                      self.paneApplicationRequest?.id == request.id, request.needsPolling else { return }
                self.advancePaneApplicationRequest()
            }
        }
    }

    private func updatePaneApplicationPickerWindows(_ request: PaneApplicationRequest) {
        let grouped = Dictionary(grouping: observedRuleWindows, by: \.bundleIdentifier)
        let running = paneApplicationLauncher.runningApplicationBundleIdentifiers().union(grouped.keys.compactMap { $0 })
        let windows = running.reduce(into: [String: [ApplicationPickerWindow]]()) { result, app in
            result[app] = paneApplicationWindows(request, applicationID: app, from: grouped[app] ?? []).map {
                ApplicationPickerWindow(id: $0.id.rawValue, title: $0.title)
            }
        }
        if request.pickerWindowsByApplication != windows { request.pickerWindowsByApplication = windows }
    }

    /// Window and application events refresh choices once and validate an idle request's owner.
    private func refreshPaneApplicationWindowChoices() {
        guard let request = paneApplicationRequest else { return }
        guard paneApplicationOwnerIsCurrent(request) else { cancelPaneApplicationRequest(id: request.id); return }
        if request.phase == .choosing { updatePaneApplicationPickerWindows(request) }
        else if case .fallback = request.phase {
            request.existingWindows = paneApplicationWindows(request, from: observedRuleWindows)
            presentPaneApplicationRequest(request)
        }
    }

    private func receiveApplicationRequestLifecycle(_ event: WindowSystemEvent) {
        guard let request = paneApplicationRequest, acceptsPaneApplicationCreation(request),
              request.instance == nil || request.instance?.processIdentifier == event.processIdentifier else { return }
        if event.kind == .created {
            request.arrivalOrder.created(id: event.windowID, token: event.creationToken)
            if let id = event.windowID, !request.baseline.contains(id) {
                request.arrivals.insert(id)
                request.createdAfterRequest.insert(id)
            }
            if let token = event.creationToken { request.creationTokens.insert(token) }
        }
    }

    private func resolveApplicationRequestCreation(_ window: WindowSnapshot, token: UInt64) {
        guard let request = paneApplicationRequest, acceptsPaneApplicationCreation(request),
              request.creationTokens.contains(token), !request.baseline.contains(window.id),
              request.instance == nil || request.instance?.processIdentifier == window.processIdentifier else { return }
        request.arrivals.insert(window.id)
        request.createdAfterRequest.insert(window.id)
        request.arrivalOrder.resolve(window.id, token: token)
    }

    private func acceptsPaneApplicationCreation(_ request: PaneApplicationRequest) -> Bool {
        guard request.deadline.map({ paneApplicationUptime() < $0 }) == true else { return false }
        if request.phase == .waiting { return true }
        if case .fallback = request.phase { return request.fallbackReason == .arrived }
        return false
    }

    /// Creation tokens outlive ordinary arrival readiness. Resolve them even when a
    /// full inventory or a focus event bypassed the optimized creation-event path.
    @discardableResult
    private func automaticallyPlacePaneApplicationArrival(_ request: PaneApplicationRequest,
                                                          windows: [WindowSnapshot]) -> Bool {
        guard acceptsPaneApplicationCreation(request), paneApplicationOwnerIsCurrent(request),
              !isTabbedBusy(on: request.displayID), let app = request.application,
              let instance = request.instance, paneApplicationLauncher.contains(instance, of: app) else { return false }
        if let reader = system as? any CreatedWindowReading {
            for token in request.creationTokens.sorted().prefix(32) {
                switch reader.readCreatedWindow(token: token) {
                case let .window(window):
                    resolveApplicationRequestCreation(window, token: token)
                    // The adapter clears a provisional popup classification on
                    // each targeted read. Keep its element until that verdict settles.
                    if !window.isFloating { request.creationTokens.remove(token) }
                case .unavailable: request.creationTokens.remove(token)
                case .notReady: break
                }
            }
        }
        request.arrivalOrder.observe(windows.filter { !request.baseline.contains($0.id) })
        guard let window = PaneApplicationRequest.automaticArrival(in: paneApplicationWindows(request, from: windows),
            applicationID: app.id, processIdentifier: instance.processIdentifier, baseline: request.baseline,
            displayID: request.displayID, spaceID: request.spaceID, observation: system.nativeDesktopObservation(),
            arrivalOrder: request.arrivalOrder.ids,
            createdAfterRequest: request.launchedInstance == instance ? Set(request.arrivalOrder.ids) : request.createdAfterRequest) else { return false }
        request.automaticPlacement = true
        placePaneApplicationWindow(window.id, request: request, observedWindows: windows)
        return true
    }

    private func paneApplicationOwnerIsCurrent(_ request: PaneApplicationRequest) -> Bool {
        guard paneApplicationRequest?.id == request.id, !isShutDown, !isStabilizingSpace,
              hasAccessibilityPermission, spaceStabilizationGeneration == request.generation,
              let session = sessionStore.session(for: request.displayID), session.id == request.sessionID,
              session.mode == .tabbed, !session.automaticWritesSuspended,
              session.tabbedState?.panes.contains(where: { $0.id == request.paneID }) == true,
              system.displays().first(where: { $0.id == request.displayID })?.visibleFrame == request.workArea else { return false }
        let observation = system.refreshNativeDesktopObservation()
        return observation?.allowsAutomaticLayout(on: request.displayID) != false
            && observation?.currentSpace(on: request.displayID) == request.spaceID
    }

    func cancelPaneApplicationRequest(id: UUID? = nil) {
        if id == nil || paneApplicationRequest?.id == id {
            paneApplicationPickerTask?.cancel(); paneApplicationPickerTask = nil
        }
        guard let request = paneApplicationRequest, id == nil || id == request.id else { return }
        paneApplicationClickTask?.cancel(); paneApplicationClickTask = nil
        request.finishFocusIntent()
        if request.dispatched { retainPaneApplicationArrivalGuard(request) }
        paneApplicationRequest = nil
        request.clickDeadline = nil
        paneApplicationTask?.cancel(); paneApplicationTask = nil
        paneApplicationLaunchTask?.cancel(); paneApplicationLaunchTask = nil
        let picker = paneApplicationPopover
        paneApplicationPopover = nil
        picker?.close()
        request.onChoose = nil; request.onExisting = nil; request.onRetry = nil; request.onCancel = nil
        request.windows = nil; request.onChooseWindow = nil
        tabbedOverlays[request.displayID]?.revealRequestWindow(number: nil)
        tabbedOverlays[request.displayID]?.setPaneRequestStatus(nil)
        tabbedOverlays[request.displayID]?.holdApplicationPicker(request.paneID, enabled: false)
    }

    private func retainPaneApplicationArrivalGuard(_ request: PaneApplicationRequest) {
        guard let app = request.application else { return }
        let now = paneApplicationUptime()
        paneApplicationArrivalGuards.removeAll { $0.expiresAt <= now }
        paneApplicationArrivalGuards.append(PaneApplicationArrivalGuard(applicationID: app.id,
            instance: request.instance, baseline: request.baseline, expiresAt: now + 30))
        request.dispatched = false
    }

    func choosePaneApplication(_ application: ApplicationChoice, requestID: UUID, retry: Bool = false) {
        guard let request = paneApplicationRequest, request.id == requestID,
              request.phase != .waiting,
              ApplicationPickerModel.validationMessage(for: application, excluding: []) == nil else { return }
        if case .placing = request.phase { return }
        paneApplicationLaunchTask?.cancel()
        if request.dispatched { retainPaneApplicationArrivalGuard(request) }
        request.application = application
        request.instance = nil
        request.launchedInstance = nil
        request.clickCandidate = nil; request.clickDeadline = nil; request.revealedWindowID = nil
        request.fallbackReason = .other; request.showingWindows = false
        request.arrivals = []; request.createdAfterRequest = []; request.creationTokens = []; request.pendingExistingWindowID = nil
        request.arrivalOrder = ApplicationRequestArrivalOrder()
        request.stillOpening = false
        request.launching = paneApplicationLauncher.runningInstances(of: application).isEmpty
        request.openingStartedAt = paneApplicationUptime()
        request.automaticPlacement = false
        request.finishFocusIntent()
        request.focusIntent = makeApplicationRequestFocus()
        request.focusIntent?.requested.insert(application.id)
        request.focusIntent?.requestStarted(target: application.id)
        request.deadline = paneApplicationUptime() + (request.launching ? max(30, paneApplicationTimeout) : paneApplicationTimeout)
        request.phase = .waiting
        syncPaneApplicationPolling()
        // Publish before any AX inventory or menu discovery. Dispatch yields so AppKit can draw it.
        closeChosenPaneApplicationPicker(request)
        let coordinator = coordinator
        let clock = paneApplicationClock
        paneApplicationLaunchTask = Task { @MainActor [weak self, weak request] in
            await Task.yield()
            guard let self, let request else { return }
            while self.isTabbedBusy(on: request.displayID) {
                guard !Task.isCancelled, self.paneApplicationOwnerIsCurrent(request),
                      request.phase == .waiting else { return }
                try? await clock.sleep(for: .milliseconds(10))
            }
            guard !Task.isCancelled, self.paneApplicationOwnerIsCurrent(request), request.phase == .waiting,
                  let visible = try? self.observeVisibleWindows() else { return }
            request.baseline = Set(visible.map(\.id))
                .union((self.system as? AccessibilityWindowSystem)?.knownWindows().map(\.id) ?? [])
                .union(self.sessionStore.sessions.values.flatMap {
                    ($0.tabbedState?.windowIDs ?? []).union($0.tabbedState?.floatingWindowIDs ?? [])
                })
            let now = self.paneApplicationUptime()
            self.paneApplicationArrivalGuards.removeAll { $0.expiresAt <= now }
            guard retry || !self.paneApplicationArrivalGuards.contains(where: { $0.applicationID == application.id }) else {
                self.paneApplicationFallback(request, reason: "An earlier request may still open a window. Choose a window from this desktop, or try again.")
                return
            }
            let instances = self.paneApplicationLauncher.runningInstances(of: application)
            request.instances = instances
            let preferred = self.paneApplicationLauncher.preferredInstance(in: instances)
            guard instances.isEmpty || preferred != nil else {
                self.paneApplicationFallback(request, reason: "Choose a window from this desktop.", kind: .severalCopies)
                return
            }
            request.launching = instances.isEmpty
            request.deadline = self.paneApplicationUptime()
                + (request.launching ? max(30, self.paneApplicationTimeout) : self.paneApplicationTimeout)
            request.dispatched = true
            request.focusIntent?.expectActivation(of: application.id)
            let valid: @MainActor () -> Bool = { [weak self] in
                !Task.isCancelled && self?.paneApplicationOwnerIsCurrent(request) == true && request.phase == .waiting
            }
            if let instance = preferred {
                request.instance = instance
                let result = await coordinator.requestNewApplicationWindow(processIdentifier: instance.processIdentifier,
                    bundleIdentifier: application.id, validating: valid)
                guard valid() else { return }
                switch result {
                case .requested: break // Never reopen after a successfully dispatched command.
                case .unsupported:
                    do { try await self.paneApplicationLauncher.reopen(application, instance: instance,
                            activating: request.focusIntent?.prepareReopen(of: application.id) == true) }
                    catch {
                        request.focusIntent?.reopenFailed()
                        guard valid() else { return }
                        self.paneApplicationFallback(request, reason: "The application couldn’t be reopened. Use a window from this desktop.", kind: .failed)
                    }
                case let .failed(reason):
                    request.focusIntent?.reopenFailed()
                    self.paneApplicationFallback(request, reason: reason)
                }
            } else {
                do {
                    let instance = try await self.paneApplicationLauncher.launch(application)
                    guard valid() else { return }
                    request.instance = instance
                    request.launchedInstance = instance
                } catch {
                    guard valid() else { return }
                    request.focusIntent?.reopenFailed()
                    self.paneApplicationFallback(request, reason: "The application couldn’t be launched. Choose an existing window or try again.", kind: .failed)
                }
            }
        }
    }

    private func paneApplicationFallback(_ request: PaneApplicationRequest, reason: String,
                                         kind: PaneApplicationRequest.FallbackReason = .other) {
        guard paneApplicationRequest?.id == request.id else { return }
        if kind != .arrived { request.finishFocusIntent() }
        if request.dispatched { retainPaneApplicationArrivalGuard(request) }
        request.phase = .fallback(reason)
        request.fallbackReason = kind
        syncPaneApplicationPolling()
        if kind == .arrived, request.clickDeadline == nil {
            request.clickDeadline = paneApplicationUptime() + paneApplicationClickTimeout
        }
        request.existingWindows = paneApplicationWindows(request, from: observedRuleWindows)
        presentPaneApplicationRequest(request)
    }

    private func paneApplicationWindows(_ request: PaneApplicationRequest, applicationID: String? = nil,
                                        from windows: [WindowSnapshot]) -> [WindowSnapshot] {
        let observation = system.nativeDesktopObservation()
        let localWindows = windows.filter { $0.displayID == request.displayID }
        return PaneApplicationRequest.candidateWindows(applicationID: applicationID ?? request.application?.id ?? "",
            displayID: request.displayID,
            windows: bentoEligible(observation?.windowsOnCurrentSpaces(localWindows) ?? localWindows))
    }

    /// New windows wait outside the layout until the user chooses one explicitly.
    private func reservesPaneApplicationWindow(_ window: WindowSnapshot) -> Bool {
        reservesPaneOwnerWindow(window)
    }

    private func reservesPaneOwnerWindow(_ window: WindowSnapshot, excluding guards: Set<UUID> = []) -> Bool {
        let now = paneApplicationUptime()
        paneApplicationArrivalGuards.removeAll { $0.expiresAt <= now }
        if paneApplicationArrivalGuards.contains(where: { !guards.contains($0.id) && $0.reserves(window) }) { return true }
        guard let request = paneApplicationRequest, request.phase != .choosing,
              window.bundleIdentifier == request.application?.id, !request.baseline.contains(window.id) else { return false }
        return true
    }

    private func reservePaneApplicationArrivals(in state: inout TabbedLayoutState, session: LayoutSession, windows: [WindowSnapshot]) {
        var layout = state.layout
        for window in windows where reservesPaneApplicationWindow(window) {
            guard !state.windowIDs.contains(window.id), !state.floatingWindowIDs.contains(window.id) else { continue }
            layout.setFloating(true, windowID: window.id)

        }
        if state.layout != layout { state.synchronize(with: layout) }
    }

    func advancePaneApplicationRequest() {
        guard let request = paneApplicationRequest else { return }
        guard paneApplicationOwnerIsCurrent(request) else { cancelPaneApplicationRequest(); return }
        defer {
            syncPaneApplicationPolling()
            if paneApplicationRequest?.id == request.id { presentPaneApplicationRequest(request) }
        }
        if case .fallback = request.phase, request.fallbackReason == .arrived,
           automaticallyPlacePaneApplicationArrival(request, windows: observedRuleWindows) { return }
        switch request.phase {
        case .choosing: break
        case .fallback:
            request.existingWindows = paneApplicationWindows(request, from: observedRuleWindows)
            // A click in progress (mouse-down on the window, waiting for mouse-up or the focus read) is
            // not cut off by the timeout. A click pending longer than that lost its mouse-up, for example
            // because the event tap stopped mid-press; it no longer holds the request open.
            let now = paneApplicationUptime()
            let clickPending = request.clickCandidate.map { now - $0.downTime <= paneApplicationPendingClickLimit } ?? false
            if request.fallbackReason == .arrived,
               request.deadline.map({ paneApplicationUptime() >= $0 }) == true {
                // Use here can remain visible after automatic placement has expired.
                request.finishFocusIntent()
            }
            if request.fallbackReason == .arrived, !clickPending, let deadline = request.clickDeadline, now >= deadline {
                // Nobody clicked the new window. Stop waiting; the window stays where macOS put it,
                // and the arrival guard still keeps it out of the layout for a while.
                let name = request.application?.name ?? "app"
                cancelPaneApplicationRequest(id: request.id)
                presentActionResult(succeeded: false, feedback: .failure(title: "Stopped waiting for a click",
                    detail: "The new \(name) window stays where it is."), displayID: request.displayID)
                return
            }
            if request.fallbackReason == .arrived {
                request.arrivals.formUnion(request.existingWindows.filter {
                    !request.baseline.contains($0.id) && $0.processIdentifier == request.instance?.processIdentifier
                }.map(\.id))
            }
            if let id = request.pendingExistingWindowID, !isTabbedBusy(on: request.displayID) {
                request.pendingExistingWindowID = nil
                placePaneApplicationWindow(id, request: request)
            }
        case let .placing(id):
            guard !isTabbedBusy(on: request.displayID) else { return }
            if sessionStore.session(for: request.displayID)?.tabbedState?.pane(containing: id)?.id == request.paneID {
                ApplicationRequestIntent.log.info("placement done target=\(request.application?.id ?? "none", privacy: .private)")
                if let focus = request.focusIntent {
                    _ = focus.restoreUserFocusIfNeeded()
                    request.focusIntent = nil
                    observeCompletedRequestFocus(focus)
                }
                cancelPaneApplicationRequest()
            } else {
                paneApplicationFallback(request, reason: statusMessage ?? "The window couldn’t be added. Choose another window or try again.")
            }
        case .waiting:
            refreshActiveWindows(force: false)
            guard paneApplicationOwnerIsCurrent(request), request.phase == .waiting else { return }
            let now = paneApplicationUptime()
            request.stillOpening = request.launching && now - (request.openingStartedAt ?? now) >= 10
            if let deadline = request.deadline, now >= deadline {
                paneApplicationFallback(request, reason: "No new window arrived. Choose an existing window, or try again.", kind: .timedOut)
                return
            }
            guard let instance = request.instance, let app = request.application,
                  paneApplicationLauncher.contains(instance, of: app) else { return }
            guard !isTabbedBusy(on: request.displayID) else { return }
            if automaticallyPlacePaneApplicationArrival(request, windows: observedRuleWindows) { return }
            let candidates = paneApplicationWindows(request, from: observedRuleWindows)
            if request.creationTokens.isEmpty, candidates.contains(where: { !request.baseline.contains($0.id)
                && $0.processIdentifier == instance.processIdentifier && $0.constraints.isResizable }) {
                paneApplicationFallback(request, reason: "Use a window from this desktop.", kind: .arrived)
            }
        }
    }

    func useExistingPaneApplicationWindow(_ id: WindowID, requestID: UUID) {
        guard let request = paneApplicationRequest, request.id == requestID, case .fallback = request.phase else { return }
        request.automaticPlacement = false
        if isTabbedBusy(on: request.displayID) {
            request.pendingExistingWindowID = id
        } else {
            placePaneApplicationWindow(id, request: request)
        }
    }

    /// Shows the request in its pane. While BetterTile waits for a click on a window it asked the app to
    /// open, that one window is raised (without activating its app) and the pane's panel moves below it,
    /// so the user can see and click it.
    private func presentPaneApplicationRequest(_ request: PaneApplicationRequest) {
        let overlay = tabbedOverlays[request.displayID]
        overlay?.setPaneRequestStatus(request.status)
        guard case .fallback = request.phase, request.fallbackReason == .arrived,
              let window = request.existingWindows.first(where: { request.arrivals.contains($0.id) }),
              let number = (system as? any TabbedWindowSystem)?.windowNumbers(for: [window])[window.id], number > 0,
              request.focusIntent?.allowsRaising == true else {
            overlay?.revealRequestWindow(number: nil)
            return
        }
        if request.revealedWindowID != window.id {
            request.revealedWindowID = window.id
            _ = coordinator.raiseTabbedWindows([window.id])
        }
        overlay?.revealRequestWindow(number: number)
    }

    func dismissPaneApplicationPicker(requestID: UUID) {
        guard let request = paneApplicationRequest, request.id == requestID else { return }
        paneApplicationPopover = nil
        if request.phase == .choosing { cancelPaneApplicationRequest(id: requestID) }
    }

    private func closeChosenPaneApplicationPicker(_ request: PaneApplicationRequest) {
        guard paneApplicationRequest?.id == request.id, request.phase != .choosing else { return }
        let picker = paneApplicationPopover
        paneApplicationPopover = nil
        picker?.close()
        presentPaneApplicationRequest(request)
    }

    func useChoosingPaneApplicationWindow(_ id: WindowID, application: ApplicationChoice, requestID: UUID) {
        guard let request = paneApplicationRequest, request.id == requestID, request.phase == .choosing,
              paneApplicationOwnerIsCurrent(request),
              ApplicationPickerModel.validationMessage(for: application, excluding: []) == nil else { return }
        request.application = application
        request.automaticPlacement = false
        placePaneApplicationWindow(id, request: request)
        closeChosenPaneApplicationPicker(request)
    }

    func handlePaneRequestAction(_ action: PaneRequestAction, requestID: UUID) {
        guard let request = paneApplicationRequest, request.id == requestID,
              paneApplicationOwnerIsCurrent(request) else { return }
        switch action {
        case .cancel: cancelPaneApplicationRequest(id: requestID)
        case .tryAgain: request.onRetry?()
        case let .useWindow(id): useExistingPaneApplicationWindow(id, requestID: requestID)
        case .showWindows:
            request.showingWindows = true
            advancePaneApplicationRequest()
        case .showApp:
            guard let application = request.application else { return }
            let instances = paneApplicationLauncher.runningInstances(of: application)
            guard instances.count == 1, let instance = instances.first,
                  let running = NSRunningApplication(processIdentifier: instance.processIdentifier),
                  running.bundleIdentifier == application.id, running.launchDate == instance.launchDate else { return }
            running.activate()
        case .chooseAnotherApp:
            tabbedOverlays[request.displayID]?.showPaneApplicationPicker(request.paneID)
        }
    }

    private static func focusPhaseName(_ phase: PaneApplicationRequest.Phase) -> String {
        switch phase {
        case .choosing: "choosing"
        case .waiting: "waiting"
        case .placing: "placing"
        case .fallback: "fallback"
        }
    }

    /// Both chooser kinds use the same listen-only shared left-mouse feed.
    func receiveTabbedChooserMouseEvent(_ event: GlobalGestureEvent) {
        paneApplicationPopover?.presenter.handleMouseEvent(event)
        // Dismissal may update the dictionary through owner callbacks.
        for overlay in Array(tabbedOverlays.values) { overlay.handleChooserMouseEvent(event) }
    }

    /// A click on an arrived window places it: mouse-down on that window, mouse-up within the drag
    /// threshold, and then that window is the focused window. A drag of the new window is not a click.
    func receivePaneApplicationMouseEvent(_ event: GlobalGestureEvent, feed: String = "injected") {
        if event.kind == .leftMouseDown, event.button == 0 {
            let timestamp = Double(event.timestamp) / 1_000_000_000
            if paneApplicationRequest != nil || !completedRequestFocus.isEmpty {
                ApplicationRequestIntent.log.debug("mouse-down feed=\(feed, privacy: .public) request=\(self.paneApplicationRequest != nil) phase=\(self.paneApplicationRequest.map { Self.focusPhaseName($0.phase) } ?? "none", privacy: .public) helper=\(self.paneApplicationRequest?.focusIntent != nil) observation=\(!self.completedRequestFocus.isEmpty)")
            }
            expireCompletedRequestFocus()
            if !completedRequestFocus.isEmpty {
                let now = paneApplicationUptime()
                if timestamp <= now, now - timestamp <= 1,
                   let window = applicationRequestWindowAtPoint?(event.position)
                       ?? (try? system.window(at: event.position)),
                   window.frame.contains(event.position) {
                    applicationRequestIntent.userChose(window.bundleIdentifier, processIdentifier: window.processIdentifier,
                                                       click: event.timestamp)
                } else {
                    ApplicationRequestIntent.log.debug("mouse-down observation choice=skip reason=timestamp-or-hit")
                }
            }
            if let request = paneApplicationRequest, request.phase != .choosing,
               let started = request.openingStartedAt {
                let now = paneApplicationUptime()
                let reason: String?
                if timestamp < started || timestamp > now || now - timestamp > 1 { reason = "timestamp" }
                else if let window = request.windowAtPoint?(event.position) {
                    if !window.frame.contains(event.position) { reason = "outside-window" }
                    else if !paneApplicationOwnerIsCurrent(request) { reason = "owner-changed" }
                    else if let focus = request.focusIntent {
                        ApplicationRequestIntent.log.debug("mouse-down hit app=\(window.bundleIdentifier ?? "none", privacy: .private) pid=\(window.processIdentifier)")
                        focus.userChose(window.bundleIdentifier, processIdentifier: window.processIdentifier, click: event.timestamp)
                        reason = nil
                    } else { reason = "no-helper" }
                } else { reason = "hit-miss" }
                if let reason {
                    // Age from the click to now and from request start to the click separate a late or
                    // early click from a hit-test or owner failure.
                    ApplicationRequestIntent.log.debug("mouse-down choice=skip reason=\(reason, privacy: .public) age=\(now - timestamp) sinceStart=\(timestamp - started)")
                }
            }
        }
        guard event.button == 0, let request = paneApplicationRequest, request.fallbackReason == .arrived,
              case .fallback = request.phase else { return }
        switch event.kind {
        case .leftMouseDown:
            request.clickCandidate = nil
            let now = paneApplicationUptime()
            let timestamp = Double(event.timestamp) / 1_000_000_000
            guard timestamp > 0, now >= timestamp, now - timestamp <= 1,
                  paneApplicationOwnerIsCurrent(request),
                  let window = request.windowAtPoint?(event.position), request.arrivals.contains(window.id),
                  paneApplicationWindows(request, from: [window]).contains(where: { $0.id == window.id }),
                  window.frame.contains(event.position) else { return }
            request.clickCandidate = PaneApplicationClick(windowID: window.id, processIdentifier: window.processIdentifier,
                                                          downTime: timestamp, downPosition: event.position)
        case .leftMouseDragged:
            if let click = request.clickCandidate, !click.released, click.moved(to: event.position) {
                request.clickCandidate = nil
            }
        case .leftMouseUp:
            guard var click = request.clickCandidate, !click.released else { return }
            guard !click.moved(to: event.position) else { request.clickCandidate = nil; return }
            click.released = true
            request.clickCandidate = click
            // A window that was already focused sends no focus event when it is clicked, so read the
            // focused window once, shortly after the mouse-up.
            let delay = paneApplicationClickConfirmDelay
            let clock = paneApplicationClock
            paneApplicationClickTask?.cancel()
            paneApplicationClickTask = Task { @MainActor [weak self, weak request] in
                try? await clock.sleep(for: delay)
                guard !Task.isCancelled, let self, let request, request.clickCandidate == click else { return }
                self.confirmPaneApplicationClick(request)
            }
        }
    }

    /// A focus change to another window means the click did not land on the new window: drop it.
    private func receivePaneApplicationFocus(_ event: WindowSystemEvent) {
        guard let request = paneApplicationRequest, let click = request.clickCandidate else { return }
        if event.processIdentifier != click.processIdentifier || (event.windowID != nil && event.windowID != click.windowID) {
            request.clickCandidate = nil
        }
    }

    /// Places the clicked arrival only if it is now the focused window. Any other result drops the click:
    /// the user clicks the window again or uses Use here.
    private func confirmPaneApplicationClick(_ request: PaneApplicationRequest) {
        guard paneApplicationRequest?.id == request.id, case .fallback = request.phase,
              request.fallbackReason == .arrived, let click = request.clickCandidate, click.released else { return }
        request.clickCandidate = nil
        guard let window = try? system.focusedWindow(), window.id == click.windowID,
              window.processIdentifier == click.processIdentifier else { return }
        useExistingPaneApplicationWindow(click.windowID, requestID: request.id)
    }

    private func placePaneApplicationWindow(_ id: WindowID, request: PaneApplicationRequest,
                                            observedWindows: [WindowSnapshot]? = nil) {
        guard paneApplicationOwnerIsCurrent(request), !isTabbedBusy(on: request.displayID),
              let visible = observedWindows ?? (try? observeVisibleWindows()),
              let window = paneApplicationWindows(request, from: visible).first(where: { $0.id == id }),
              let applicationID = request.application?.id,
              let session = sessionStore.session(for: request.displayID), var state = session.tabbedState,
              let display = system.displays().first(where: { $0.id == request.displayID }) else { return }
        if !request.automaticPlacement {
            // A pane UI choice places the window; it does not choose its app for focus.
            // Keep intent only during this transaction so a newer choice can be restored once.
            if request.focusIntent == nil {
                request.focusIntent = makeApplicationRequestFocus()
                request.focusIntent?.requestStarted(target: applicationID)
            }
            request.focusIntent?.requested.insert(applicationID)
        }
        // Existing windows are revalidated from the current desktop immediately before the transaction.
        if !state.windowIDs.contains(id), !state.floatingWindowIDs.contains(id) {
            var layout = state.layout
            layout.setFloating(true, windowID: id)
            state.synchronize(with: layout)
        }
        let windows = ignoringOversizedSeeds(bentoEligible((system.nativeDesktopObservation()?.windowsOnCurrentSpaces(visible) ?? visible)
            .filter { $0.displayID == request.displayID && $0.isEligible && !$0.isFloating }), in: display.visibleFrame)
        if request.automaticPlacement {
            // Concurrent ordinary arrivals keep the pane that was active before
            // this request selects its destination. Plan them in the same write.
            state.reconcile(windowIDs: windows.filter { !reservesPaneApplicationWindow($0) }.map(\.id),
                removed: [], fittingIn: display.visibleFrame, windows: windows, followed: session.followed)
        }
        let undoSource = state
        state.move(id, to: request.paneID)
        request.phase = .placing(id)
        syncPaneApplicationPolling()
        applyTabbedState(state, session: session, display: display, windows: windows, focus: window.id,
            rememberUndo: true, gestureBaseline: undoSource, floatingUndoSourceID: id, expectedSpaceID: request.spaceID,
            startsImmediately: request.automaticPlacement,
            allowingRequestRaise: {
                request.automaticPlacement
                    ? request.focusIntent?.allowsRaising == true
                    : request.focusIntent?.frontmost() == applicationID
            },
            validating: { [weak self] in
                guard let self, self.paneApplicationOwnerIsCurrent(request),
                      let current = try? self.system.windowSnapshots(ids: [id]),
                      self.paneApplicationWindows(request, from: current).contains(where: { $0.id == id }),
                      self.paneApplicationOwnerIsCurrent(request) else { return false }
                if let memberships = self.system.nativeDesktopObservation()?.windowMembership[id], !memberships.isEmpty {
                    guard let space = request.spaceID, memberships == [space] else { return false }
                }
                return true
            })
    }
}

// MARK: - Saved Layouts: Apply and Undo on the current desktop

extension BetterTileModel {
    var availableDisplays: [DisplaySnapshot] { system.displays() }

    /// Badge rendering uses cached desktop state; Apply refreshes window and desktop observations.
    private func savedLayoutApplySnapshot(refresh: Bool, windows: [WindowSnapshot]? = nil) throws -> SavedLayoutApplySnapshot {
        guard !isShutDown, hasAccessibilityPermission else {
            throw SavedLayoutFileError(message: "Enable Accessibility to apply a Saved Layout.")
        }
        let visible = try windows ?? (refresh ? observeVisibleWindows() : observedRuleWindows)
        guard let observation = refresh ? system.refreshNativeDesktopObservation() : system.nativeDesktopObservation() else {
            throw SavedLayoutFileError(message: "Desktop observations are unavailable. Saved Layouts are paused.")
        }
        let displays = system.displays()
        let ready = Set(displays.filter { display in
            !isStabilizingSpace && !isTabbedBusy(on: display.id)
                && settlementTasks[display.id] == nil && activeBentoDrag == nil
                && !dragSnap.isGestureActive && !dividerResize.isDragging
                && observation.allowsAutomaticLayout(on: display.id)
        }.map(\.id))
        let allowed = visible.filter { rule(for: $0).allowsBentoParticipation && $0.constraints.isMovable }
        let known = (system as? AccessibilityWindowSystem)?.knownWindows() ?? visible
        let chrome = allTabbedOverlays.reduce(into: Set<Int>()) { $0.formUnion($1.windowNumbers) }
        let order = refresh ? (system as? any TabbedWindowSystem)?.stackingOrder(for: allowed, excluding: chrome) : nil
        return SavedLayoutApplySnapshot(observation: observation, displays: displays, windows: allowed,
            knownWindows: known, sessions: savedLayoutSessions(),
            generation: spaceStabilizationGeneration, isStable: !isStabilizingSpace, readyDisplays: ready,
            suspendedDisplays: Set(sessionStore.sessions.values.filter(\.automaticWritesSuspended).map(\.displayID)),
            tabbedPresentation: configuration.tabbedStripPresentation,
            followedLayouts: Dictionary(uniqueKeysWithValues: displays.compactMap { display in
                sessionStore.session(for: display.id)?.followed.map { (display.id, $0) }
            }), sessionOwners: Dictionary(uniqueKeysWithValues: displays.compactMap { display in
                sessionStore.session(for: display.id).map { (display.id, $0) }
            }), stackingOrder: order)
    }

    /// A menu/shortcut target is refreshed on events and on the click, never while rendering.
    func refreshSavedLayoutActionTarget() {
        savedLayoutApplier?.updateUndoDesktops(system.nativeDesktopObservation(), displays: system.displays())
        savedLayoutFollowingDisplayID = actionDisplayID(requiringUserAction: true)
        savedLayoutActionTargetName = savedLayoutFollowingDisplayID.flatMap { id in
            savedLayoutScreenNames()[id] ?? "Selected screen"
        }
    }

    var followedSavedLayout: FollowedLayout? {
        guard let display = savedLayoutFollowingDisplayID,
              let session = sessionStore.session(for: display),
              session.nativeSpaceID == system.nativeDesktopObservation()?.currentSpace(on: display) else { return nil }
        return session.followed
    }

    func stopFollowingSavedLayout() {
        guard let display = savedLayoutFollowingDisplayID, followedSavedLayout != nil else { return }
        sessionStore.update(display) { $0.endFollowing() }
    }

    @discardableResult func applySavedLayoutAction(_ file: String) -> Bool {
        invalidateMenuPanelFocusReplay()
        guard let applier = savedLayoutApplier, !applier.isBusy else {
            statusMessage = "Another layout is applying. Try again when it finishes."
            savedLayoutActions.message = statusMessage; return false
        }
        guard let display = actionDisplayID(requiringUserAction: true), system.displays().contains(where: { $0.id == display }) else {
            statusMessage = "Focus an app window to apply a layout."
            savedLayoutActions.message = statusMessage; return false
        }
        do {
            let document = try savedLayoutActions.load(file)
            savedLayoutActions.message = nil
            rememberUserActionDisplay(display)
            savedLayoutActionFile = file
            applier.start(document, displayID: display, positions: .init(file: file, store: .init(files: savedLayoutActions.files)))
            refreshSavedLayoutActionTarget()
            return true
        } catch {
            statusMessage = "This Saved Layout could not be opened. Reload the library and try again."
            savedLayoutActions.message = statusMessage; savedLayoutActions.refresh(); return false
        }
    }

    func handleSavedLayoutShortcut(_ file: String) {
        guard configuration.keyboardShortcutsEnabled,
              savedLayoutActions.store.settings(for: file).shortcut != nil,
              savedLayoutShortcutProblem(file) == nil else { return }
        layoutWheel.cancel(reason: .shortcut)
        _ = applySavedLayoutAction(file)
    }

    func savedLayoutShortcutProblem(_ file: String) -> String? {
        guard let key = savedLayoutActions.store.settings(for: file).shortcut else { return nil }
        return SavedLayoutShortcutPolicy.conflict(key, configuration: configuration,
            layouts: savedLayoutActions.store.values, excluding: file, names: savedLayoutActions.names)
            ?? (savedLayoutShortcutFailures.contains(file) ? "macOS could not register this shortcut. It may be in use. Choose another shortcut." : nil)
    }

    @discardableResult func setSavedLayoutActions(_ file: String, _ value: SavedLayoutActionSettings) -> Bool {
        if let key = value.shortcut, let conflict = SavedLayoutShortcutPolicy.conflict(key,
            configuration: configuration, layouts: savedLayoutActions.store.values, excluding: file, names: savedLayoutActions.names) {
            savedLayoutActions.message = conflict; return false
        }
        let saved = savedLayoutActions.store.set(file, value)
        savedLayoutActions.message = saved ? nil : savedLayoutActions.store.message
        return saved
    }

    func refreshSavedLayoutActions() {
        let values = savedLayoutActions.store.values
        let named = values.compactMapValues(\.shortcut).filter { file, key in
            savedLayoutActions.entries.contains { $0.file == file }
                && SavedLayoutShortcutPolicy.conflict(key, configuration: configuration,
                    layouts: values, excluding: file, names: savedLayoutActions.names) == nil
        }
        // Conflicts introduced by an external file are visible on both pages and dispatch neither action.
        let bindings = configuration.shortcuts.map { binding in
            var binding = binding
            if let key = binding.shortcut, values.values.contains(where: { $0.shortcut.map { SavedLayoutShortcutPolicy.same(key, $0) } == true }) {
                binding.shortcut = nil
            }
            return binding
        }
        shortcuts.isEnabled = configuration.keyboardShortcutsEnabled
        shortcuts.update(bindings: bindings, named: runsActionRegistration ? named : [:])
        savedLayoutShortcutFailures = shortcuts.failedNamedBindings
        layoutWheel.savedLayouts = savedLayoutActions.wheelEntries.map { .init(file: $0.file, name: $0.name) }
        if let conflict = values.keys.sorted().compactMap({ savedLayoutShortcutProblem($0) }).first {
            savedLayoutActions.message = conflict; statusMessage = conflict
        }
        refreshSavedLayoutActionTarget()
    }

    func settingsSavedLayoutApplyStarted() { savedLayoutActionFile = nil }

    func navigateSavedLayoutWheel(_ command: LayoutWheelCommand, target: LayoutWheelTarget) {
        switch command {
        case .moreSavedLayouts:
            savedLayoutActions.refresh()
            showSavedLayoutChooser(Array(savedLayoutActions.wheelEntries.dropFirst(5)))
        case .moreLayoutChoices:
            let options = configuration.layoutWheel.group(at: .bottomLeft).options.compactMap { $0 }
            SavedLayoutActionMenu.show(options.map { command in
                (LayoutWheelSlot(command: command).label, { [weak self] in self?.performLayoutWheel(command, for: target) })
            })
        default: break // A category is navigation only; release applies nothing.
        }
    }

    func configureSavedLayoutApply() {
        let applier = SavedLayoutApplier(snapshot: { [weak self] in
                guard let self else { throw CancellationError() }
                return try self.savedLayoutApplySnapshot(refresh: true)
            }, commit: { [weak self] plan, desktop, snapshot, isCurrent in
                guard let self else { return false }
                return await self.commitSavedLayout(plan, desktop: desktop, snapshot: snapshot, isCurrent: isCurrent)
            })
        applier.appGroupsStore = appGroupsStore
        let groups = appGroupsStore
        applier.isLoadingAppGroups = true
        let load = Task { @MainActor [weak applier] in
            await groups.load()
            applier?.appGroupsDidLoad()
        }
        appGroupsLoadTask = load
        applier.prepareAppGroups = { await load.value }
        applier.placementSnapshot = { [weak self] in
            guard let self else { throw CancellationError() }
            return try self.savedLayoutApplySnapshot(refresh: false)
        }
        applier.destinationSnapshot = { [weak self] in
            guard let self, let observation = self.system.refreshNativeDesktopObservation() else { throw CancellationError() }
            var state = try self.savedLayoutApplySnapshot(refresh: false)
            state.observation = observation
            return state
        }
        applier.feedback = { [weak self] in self?.presentSavedLayoutResult($0) }
        applier.currentDisplayID = { [weak self] in self?.actionDisplayID() }
        applier.displayName = { [weak self] id, displays in
            self?.savedLayoutScreenNames()[id] ?? savedLayoutDisplayName(id, among: displays)
        }
        applier.reservesOtherOwnerWindow = { [weak self] window in self?.reservesPaneOwnerWindow(window) ?? true }
        applier.didFinish = { [weak self] in self?.schedulePendingWindowEvents() }
        savedLayoutApplier = applier
        configureDisplayTriggers(applier)
    }

    private func configureDisplayTriggers(_ applier: SavedLayoutApplier) {
        let runtime = DisplayTriggerRuntime(applier: applier, initial: DisplayFingerprintReader.current().map(\.fingerprint))
        let files = SavedLayoutFiles.standard
        let triggerStore = displayTriggerStore
        runtime.triggers = { [weak self] in self?.hasAccessibilityPermission == true ? triggerStore.document.triggers : [] }
        runtime.liveDisplays = { DisplayFingerprintReader.current() }
        runtime.isScreenLocked = {
            NSWorkspace.shared.frontmostApplication?.bundleIdentifier == DisplayTriggerRuntime.loginWindowBundleID
        }
        runtime.loadLayout = { file in
            guard DisplayTriggerDocument.isValidLayoutFile(file) else { return nil }
            return try SavedLayoutValidator.decode(files.read(files.directory.appendingPathComponent(file)))
        }
        runtime.isReady = { [weak self] id in
            guard let self else { return false }
            return !self.isStabilizingSpace && !self.isTabbedBusy(on: id) && self.settlementTasks[id] == nil
        }
        runtime.isInteracting = { [weak self] in
            guard let self else { return false }
            return self.activeBentoDrag != nil || self.dragSnap.isGestureActive || self.dividerResize.isDragging
                || self.layoutWheel.isOpen || NSEvent.pressedMouseButtons != 0
        }
        runtime.observeFrames = { [weak self] displays in
            guard let self, let windows = try? self.observeVisibleWindows() else { return nil }
            return Dictionary(uniqueKeysWithValues: windows.filter { displays.contains($0.displayID) && $0.isEligible && !$0.isFloating }
                .map { ($0.id, $0.frame) })
        }
        runtime.notice = { [weak self] in self?.presentAutomaticNotice($0) }
        displayTriggerRuntime = runtime
    }

    private func presentAutomaticNotice(_ notice: DisplayTriggerNotice) {
        statusMessage = notice.detail
        showAutomaticPill(.layoutResult(title: notice.title, detail: notice.detail, kind: notice.kind, actions: notice.actions),
                          displayID: notice.displayID)
    }

    private func showAutomaticPill(_ feedback: ResultPillFeedback, displayID: DisplayID?) {
        lastActionFeedback = feedback
        let displays = system.displays()
        guard let display = displayID.flatMap({ id in displays.first { $0.id == id } })
                ?? displays.first(where: \.isMain) ?? displays.first else { return }
        let controller = automaticResultPills[display.id] ?? resultPillFactory()
        automaticResultPills[display.id] = controller
        controller.overlayAppearance = configuration.overlayAppearance
        controller.show(feedback, on: display)
    }

    /// The sessions as Saved Layouts reads them: process-local state, never saved.
    func savedLayoutSessions() -> [DisplayID: SavedLayoutSession] {
        sessionStore.sessions.mapValues { session in
            if let state = session.tabbedState, session.mode == .tabbed { return .tabbed(state) }
            if session.mode == .bento { return .bento(session.bentoState) }
            return .manual
        }
    }

    private func presentSavedLayoutResult(_ result: SavedLayoutFeedback) {
        statusMessage = result.detail
        var actions: [ResultPillAction] = []
        if result.isApply, savedLayoutApplier != nil {
            if result.offersUndo {
                let display = result.displayID
                actions.append(.init(title: "Undo", accessibilityLabel: "Undo the last Saved Layout") { [weak self] in
                    self?.savedLayoutApplier?.startUndo(displayID: display)
                })
            }
            actions.append(.init(title: "Details", accessibilityLabel: "Show Saved Layout details in Settings") { [weak self] in
                self?.requestedSettingsDestination = .savedLayouts
                self?.openSettings()
            })
        }
        let feedback = ResultPillFeedback.layoutResult(title: result.title, detail: result.detail, kind: result.kind, actions: actions)
        if result.automatic {
            showAutomaticPill(feedback, displayID: result.displayID)
        } else {
            presentActionResult(succeeded: result.kind == .success, feedback: feedback, displayID: result.displayID)
        }
    }

    private func commitSavedLayout(_ plan: SavedLayoutApplyPlan, desktop: SavedLayoutDesktop,
                                   snapshot: SavedLayoutApplySnapshot,
                                   isCurrent: @escaping () -> Bool) async -> Bool {
        guard isCurrent(), let display = snapshot.displays.first(where: { $0.id == desktop.displayID }) else { return false }
        let startsFollowing: Bool
        if case .start = snapshot.followingIntent { startsFollowing = true } else { startsFollowing = false }
        let current = sessionStore.session(for: desktop.displayID)
        if startsFollowing || current?.followed != nil, let owners = snapshot.sessionOwners {
            let previous = owners[desktop.displayID]
            // Bookkeeping sweeps may advance the revision without changing this proposal's policy.
            guard previous?.id == current?.id, previous?.mode == current?.mode,
                  previous?.bentoState == current?.bentoState, previous?.tabbedState == current?.tabbedState,
                  previous?.followed == current?.followed else { return false }
        }
        var session = current ?? sessionStore.activate(
            displayID: desktop.displayID, windowIDs: [], focusedWindowID: nil,
            defaultMode: configuration.defaultLayoutMode, reuseActiveWhenUnmatched: false, nativeSpaceID: desktop.spaceID).session
        let revision = session.revision
        let sessionID = session.id
        var placements = plan.placements
        var required: Set<WindowID>?
        if case let .tabbed(state) = plan.targetSession {
            let overrides = Dictionary(uniqueKeysWithValues: placements.map { ($0.windowID, $0.frame) })
            guard let proposed = try? state.placements(in: display.visibleFrame, windows: snapshot.windows) else { return false }
            let floats = placements.filter { !state.windowIDs.contains($0.windowID) }
            placements = proposed.map { Placement(windowID: $0.windowID, frame: overrides[$0.windowID] ?? $0.frame) } + floats
            required = Set(state.selectedWindowIDs).union(floats.map(\.windowID))
        }
        let ids = Set(placements.map(\.windowID)).union(plan.assignments.values)
        let participants = Dictionary(uniqueKeysWithValues: snapshot.windows.filter { ids.contains($0.id) }.map { ($0.id, $0) })
        var validatedParticipants: [WindowSnapshot] = []
        // Closures nested in `recover` read this through a main-actor closure. Swift 6.3
        // wrongly treats a direct capture of the variable there as task-isolated.
        let currentValidatedParticipants = { @MainActor in validatedParticipants }
        let readParticipants = { @MainActor in
            try self.system.cachedVisibleWindows(refreshing: ids) ?? self.observeVisibleWindows()
        }
        let ownerMatchesObservation = { @MainActor [weak self] (visible: [WindowSnapshot], observation: NativeDesktopObservation?) in
            guard snapshot.sessionIsAvailable(), let self, !self.isShutDown, self.hasAccessibilityPermission, !self.isStabilizingSpace,
                  self.sessionStore.isCurrent(sessionID, revision: revision, on: desktop.displayID),
                  self.system.displays().first(where: { $0.id == desktop.displayID })?.visibleFrame == display.visibleFrame,
                  let observation,
                  observation.currentSpace(on: desktop.displayID) == desktop.spaceID,
                  observation.allowsAutomaticLayout(on: desktop.displayID), participants.count == ids.count else { return false }
            // Participant snapshots may carry an older native classification.
            // Reclassify only these windows with the observation taken after their reads.
            let coherent = observation.windowsOnCurrentSpaces(visible.filter { ids.contains($0.id) })
            validatedParticipants = coherent
            // Fresh public visibility is required even if a cached AX handle still resolves.
            return ids.allSatisfy { id in
                guard let before = participants[id], let now = coherent.first(where: { $0.id == id }),
                      now.processIdentifier == before.processIdentifier, now.bundleIdentifier == before.bundleIdentifier,
                      now.isEligible, !now.isFloating,
                      now.constraints.isMovable, self.rule(for: now).allowsBentoParticipation else { return false }
                if let transfer = snapshot.requestedTransfers[id] {
                    guard !transfer.reusesExistingWindow
                        || !SavedLayoutRequestedTransfer.isPaneMember(id, in: self.savedLayoutSessions()[transfer.source.displayID]) else { return false }
                    return transfer.permits(now, observation: observation, displays: self.system.displays())
                }
                let membership = observation.windowMembership[id] ?? []
                return now.displayID == desktop.displayID && (membership.isEmpty || membership == [desktop.spaceID])
            }
        }
        let ownerIsCurrent = { @MainActor in
            guard !self.isShutDown, self.hasAccessibilityPermission, !self.isStabilizingSpace,
                  let visible = try? readParticipants(),
                  let observation = self.system.refreshNativeDesktopObservation() else { return false }
            return ownerMatchesObservation(visible, observation)
        }
        // Read participants before the forced refresh: a full-inventory fallback
        // can itself observe an endpoint Space change. isCurrent then refreshes
        // destination state; use the latest cached observation to authorize writes.
        let valid = { @MainActor in
            guard !self.isShutDown, self.hasAccessibilityPermission, !self.isStabilizingSpace,
                  let visible = try? readParticipants(),
                  isCurrent(), let observation = self.system.nativeDesktopObservation() else { return false }
            return ownerMatchesObservation(visible, observation)
        }
        guard session.nativeSpaceID == desktop.spaceID, valid() else { return false }
        let displayDestinations = snapshot.requestedTransfers.mapValues { $0.destination.displayID }
        let rollbackDisplays = snapshot.requestedTransfers.mapValues { $0.source.displayID }
        let baseline = Dictionary(uniqueKeysWithValues: snapshot.windows.map { ($0.id, $0.frame) })
        var ownedGenerations: [WindowID: UInt64] = [:]
        let ownsMutations = { @MainActor in
            ownedGenerations.allSatisfy {
                self.coordinator.mutationGeneration(for: $0.key) == $0.value
            }
        }
        let recover = { @MainActor in
            let requested = Dictionary(uniqueKeysWithValues: placements.map { ($0.windowID, $0.frame) })
            // This synchronous restoration allocates its own new generations.
            // Check the checkpoint once; revalidate the owner and physical
            // frames before every write, including restoration's own writes.
            let stillOwnsMutations = ownsMutations()
            let canRestore = {
                guard ownerIsCurrent(), self.activeBentoDrag == nil, !self.dragSnap.isGestureActive,
                      !self.dividerResize.isDragging, stillOwnsMutations else { return false }
                let current = currentValidatedParticipants()
                // A physical move does not allocate a coordinator generation. Keep that newer frame.
                return ids.allSatisfy { id in
                    guard let frame = current.first(where: { $0.id == id })?.frame else { return false }
                    return requested[id]?.approximatelyEquals(frame, tolerance: 2) == true
                        || baseline[id]?.approximatelyEquals(frame, tolerance: 2) == true
                }
            }
            let restore = placements.compactMap { placement in
                baseline[placement.windowID].map { Placement(windowID: placement.windowID, frame: $0) }
            }
            let rollback = self.coordinator.applyPlacements(restore, recordHistory: false, displayDestinations: rollbackDisplays, revalidateBeforeEachWrite: true, validating: canRestore)
            if !rollback.isApplied {
                self.suspendAutomaticBentoWrites(displayID: desktop.displayID, sessionID: sessionID,
                    error: "Saved Layout could not restore all previous frames.",
                    surfaceFailure: snapshot.sessionIsAvailable())
            }
        }
        // A window that keeps a larger size than its pane asked for names the cause of a rollback.
        coordinator.resetRefusedSizes()
        let noteRefusals = { @MainActor in
            // Sizes the coordinator read before its own rollback, then sizes still showing now.
            self.savedLayoutApplier?.refusedSizes.merge(self.coordinator.refusedSizes) { _, new in new }
            guard let current = try? self.observeVisibleWindows() else { return }
            for placement in placements {
                guard let frame = current.first(where: { $0.id == placement.windowID })?.frame else { continue }
                // A window back at its earlier frame was restored, not refused. Only the coordinator knows then.
                if baseline[placement.windowID]?.approximatelyEquals(frame, tolerance: 2) == true { continue }
                let size = frame.size
                if size.width > placement.frame.size.width + 2 || size.height > placement.frame.size.height + 2 {
                    self.savedLayoutApplier?.refusedSizes[placement.windowID] = size
                }
            }
        }
        // Compare only before this transaction's first write. Settlement must accept
        // the transaction's own new frames, and a refusal must preserve the older Undo.
        guard let beforeWrite = try? observeVisibleWindows() else { return false }
        if participants.values.contains(where: { participant in
            beforeWrite.first(where: { $0.id == participant.id })?.frame.approximatelyEquals(participant.frame, tolerance: 2) != true
        }) {
            savedLayoutApplier?.precommitRefusal = .beforeWrite("A window moved while applying. Try again.")
            return false
        }
        let outcome: WindowMutationOutcome
        switch plan.targetSession {
        case let .tabbed(state):
            outcome = placements.isEmpty ? .applied : await coordinator.applyTabbed(placements: placements,
                required: required, selected: state.selectedWindowIDs,
                previousSelected: session.tabbedState?.selectedWindowIDs ?? [], focus: nil,
                displayDestinations: displayDestinations, rollbackValidating: ownerIsCurrent, revalidateBeforeEachWrite: true,
                onFinalValidationFailure: { self.savedLayoutApplier?.recordFailure(.coordinatorFinalOwnership) }, isCurrent: valid)
        case .bento, .manual:
            outcome = placements.isEmpty ? .applied : coordinator.applyPlacements(placements, recordHistory: false, displayDestinations: displayDestinations,
                rollbackValidating: ownerIsCurrent, revalidateBeforeEachWrite: true,
                onFinalValidationFailure: { self.savedLayoutApplier?.recordFailure(.coordinatorFinalOwnership) }, validating: valid)
        }
        ownedGenerations = Dictionary(uniqueKeysWithValues: ids.map { ($0, coordinator.mutationGeneration(for: $0)) })
        guard outcome.isApplied else {
            savedLayoutApplier?.recordFailure(.modelPlacement)
            noteRefusals()
            if case .degraded = outcome {
                self.suspendAutomaticBentoWrites(displayID: desktop.displayID, sessionID: sessionID,
                    error: "Saved Layout left an incomplete layout.",
                    surfaceFailure: snapshot.sessionIsAvailable())
            }
            return false
        }
        guard valid() else {
            savedLayoutApplier?.recordFailure(.modelPostPlacement)
            noteRefusals(); recover(); return false
        }
        if case let .bento(state) = plan.targetSession, !placements.isEmpty {
            let changed = Dictionary(uniqueKeysWithValues: placements.map { ($0.windowID, $0.frame) })
            // Settle only validated participants: Undo restores a tree that can hold other windows.
            let tiled = snapshot.windows.filter { ids.contains($0.id) && state.root?.windowIDs.contains($0.id) == true }.map {
                Placement(windowID: $0.id, frame: changed[$0.id] ?? $0.frame)
            }
            let settled = await coordinator.settleAuthoritativePlacements(tiled,
                revalidateBeforeEachWrite: true, didRetry: { ownedGenerations.merge($0) { _, new in new } },
                onFailure: { cause in
                    self.savedLayoutApplier?.recordSettlementFailure(cause)
                }, validating: valid)
            guard settled.isApplied else { noteRefusals(); recover(); return false }
            guard valid() else {
                savedLayoutApplier?.recordFailure(.modelPostSettlement)
                noteRefusals(); recover(); return false
            }
        }
        // Capture signatures ignore vacancy UUIDs. A metadata-only restart may
        // need the planner's equivalent tree before its anchors can be installed.
        if !plan.isEmpty || (startsFollowing && snapshot.followingIntent.make(plan: plan, session: session) == nil) {
            let unmatched = Set(plan.unmatchedWindowIDs)
            session.mode = plan.targetSession.mode
            session.savedLayoutPaneGap = nil
            session.tabbedHasEntryBaseline = false
            session.automaticallyFloatingWindowIDs = []
            session.excludedFocusWindowIDs = []
            session.bentoReinsertionAnchors = [:]
            switch plan.targetSession {
            case .manual: session.tabbedState = nil; session.bentoState = BentoLayoutState(); session.windowIDs = []
            case var .bento(state):
                state.floatingWindowIDs.formUnion(unmatched)
                session.tabbedState = nil; session.bentoState = state
                session.savedLayoutPaneGap = state.metrics.paneGap
                session.windowIDs = Set(state.root?.windowIDs ?? [])
                session.isBentoInitialized = true
            case var .tabbed(state):
                var layout = state.layout
                layout.floatingWindowIDs.formUnion(unmatched); state.synchronize(with: layout)
                session.tabbedState = state; session.windowIDs = state.windowIDs
                session.savedLayoutPaneGap = state.layout.metrics.paneGap
                session.tabbedBaselineFrames.merge(baseline) { old, _ in old }
            }
            session.lastWorkArea = display.visibleFrame
            session.resumeAutomaticWrites()
            session.recordProposedFrames(Dictionary(uniqueKeysWithValues: ((try? observeVisibleWindows()) ?? []).map { ($0.id, $0.frame) }))
        }
        session.followed = snapshot.followingIntent.make(plan: plan, session: session)
        // Include placement, settlement and session-preparation reads in the input turn.
        // The proposal is still local; cancellation can restore the original session's frames.
        guard await savedLayoutInputCheckpoint() else { recover(); return false }
        guard valid() else {
            savedLayoutApplier?.recordFailure(.modelFinalValidation)
            recover(); return false
        }
        guard ownsMutations() else {
            savedLayoutApplier?.recordFailure(.modelFinalValidation)
            savedLayoutApplier?.precommitRefusal = .mutationChanged
            recover(); return false
        }
        guard sessionStore.commit(session, replacing: revision) != nil else {
            savedLayoutApplier?.recordFailure(.modelSessionCommit)
            recover(); return false
        }
        if startsFollowing, session.followed == nil { savedLayoutApplier?.recordFollowingFailure() }
        if !plan.placements.isEmpty {
            coordinator.recordHistory(baseline.filter { id, _ in plan.placements.contains { $0.windowID == id } })
        }
        if !plan.isEmpty { refreshDividerBoundaries(windows: (try? observeVisibleWindows()) ?? snapshot.windows) }
        return true
    }
}
