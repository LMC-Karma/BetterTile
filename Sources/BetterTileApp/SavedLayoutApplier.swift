// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 LMC-Karma

import AppKit
import BetterTileCore
import BetterTileMacOS
import Observation
import OSLog

enum SavedLayoutCommitRefusal {
    case beforeWrite(String)
    case bindingChanged
    case mutationChanged
    case displayChanged

    var message: String {
        switch self {
        case let .beforeWrite(reason): reason
        case .displayChanged: "Displays changed while applying. Apply the layout again after they settle."
        case .bindingChanged: "The display binding changed. Automatic Apply stopped."
        case .mutationChanged: "A window changed while applying. Use Repair Layout or try again."
        }
    }
}

/// A submitted choice failed fresh admission before any coordinator transaction.
private struct SavedLayoutChoiceRefusal: LocalizedError {
    var retryChoices: [String: WindowID]
    var errorDescription: String? { SavedLayoutApplySession.unavailableChoice }
}

/// Session-only manual target. Window reads happen on events and actions, never while rendering.
@Observable @MainActor final class SavedLayoutTarget {
    enum Selection: Hashable { case following, picked(DisplayID), disconnected(String) }
    private(set) var displayID: DisplayID?
    private(set) var followingID: DisplayID?
    private(set) var liveDisplays: [LiveDisplay] = []
    private(set) var picked: DisplayFingerprint?
    /// Last connected work area for the explicit pick, retained while it is disconnected.
    private(set) var pickedWorkArea: BTRect?
    private var workAreas: [DisplayID: BTRect] = [:]
    private(set) var selection: Selection = .following
    private var pickedSerialWasUnique = false

    static func resolve(current: DisplayID?, displays: [DisplaySnapshot]) -> DisplayID? {
        current.flatMap { id in displays.contains(where: { $0.id == id }) ? id : nil }
            ?? displays.first(where: \.isMain)?.id ?? displays.first?.id
    }

    var selectionID: DisplayID? {
        switch selection {
        case .following: followingID
        case let .picked(id): id
        case .disconnected: nil
        }
    }
    var choices: [Selection] {
        var result: [Selection] = [.following]
        if case .disconnected = selection { result.append(selection) }
        return result + liveDisplays.map { .picked($0.id) }
    }
    func followFocusedWindow(current: () -> DisplayID?, displays: [DisplaySnapshot],
                             retaining owner: DisplayID? = nil, live: [LiveDisplay]? = nil) {
        picked = nil; pickedWorkArea = nil
        pickedSerialWasUnique = false
        refresh(current: current, displays: displays, retaining: owner, live: live)
    }
    var unavailableReason: String? {
        if case .disconnected = selection { return "The selected screen is disconnected. Choose a connected screen." }
        return nil
    }
    func name(for id: DisplayID?) -> String? {
        liveDisplays.first { $0.id == id }.map { $0.fingerprint.name.isEmpty ? "Display" : $0.fingerprint.name }
    }
    @discardableResult func pick(_ id: DisplayID, retaining owner: DisplayID? = nil) -> Bool {
        guard let display = liveDisplays.first(where: { $0.id == id }) else { return false }
        picked = display.fingerprint
        pickedWorkArea = workAreas[id]
        pickedSerialWasUnique = display.fingerprint.serial != 0
            && liveDisplays.filter { Self.sameSerial($0.fingerprint, display.fingerprint) }.count == 1
        selection = .picked(id)
        displayID = owner ?? id
        return true
    }
    private static func sameSerial(_ a: DisplayFingerprint, _ b: DisplayFingerprint) -> Bool {
        a.vendor == b.vendor && a.model == b.model && a.serial == b.serial
    }
    private func pickedDisplay() -> LiveDisplay? {
        guard let picked else { return nil }
        let uuidMatches = liveDisplays.filter { $0.fingerprint.uuid.caseInsensitiveCompare(picked.uuid) == .orderedSame }
        if !picked.uuid.isEmpty, !uuidMatches.isEmpty { return uuidMatches.count == 1 ? uuidMatches[0] : nil }
        guard pickedSerialWasUnique else { return nil }
        let serialMatches = liveDisplays.filter { Self.sameSerial($0.fingerprint, picked) }
        guard serialMatches.count == 1, let candidate = serialMatches.first,
              DisplaySetMatcher.match(stored: [picked], live: [candidate.fingerprint]).kind == .exact else { return nil }
        return candidate
    }
    private func updateLive(_ live: [LiveDisplay]?, displays: [DisplaySnapshot]) {
        workAreas = Dictionary(uniqueKeysWithValues: displays.map { ($0.id, $0.visibleFrame) })
        liveDisplays = (live ?? liveDisplays).filter { item in displays.contains { $0.id == item.id } }
        guard let picked else { selection = .following; return }
        let connected = pickedDisplay()
        selection = connected.map { .picked($0.id) } ?? .disconnected(picked.name)
        if let id = connected?.id { pickedWorkArea = workAreas[id] }
    }
    func refresh(current: () -> DisplayID?, displays: [DisplaySnapshot], retaining owner: DisplayID? = nil,
                 live: [LiveDisplay]? = nil) {
        updateLive(live, displays: displays)
        if picked == nil { followingID = Self.resolve(current: current(), displays: displays) }
        displayID = owner ?? selectionID
    }

    /// Binding targets bypass the manual pick without changing it. Each click revalidates live identities.
    func prepareApply(current: () -> DisplayID?, displays: [DisplaySnapshot], explicit: DisplayID? = nil,
                      live: [LiveDisplay]? = nil) -> DisplayID? {
        updateLive(live, displays: displays)
        if let explicit { displayID = displays.contains(where: { $0.id == explicit }) ? explicit : nil }
        else if picked != nil { displayID = selectionID }
        else {
            followingID = Self.resolve(current: current(), displays: displays)
            displayID = followingID
        }
        return displayID
    }
}

/// Authority for reusing a window between two visible desktops.
/// Both endpoints must remain visible. Undo reverses the same authority.
struct SavedLayoutRequestedTransfer {
    var source: SavedLayoutDesktop
    var destination: SavedLayoutDesktop
    var reusesExistingWindow = false

    static func isPaneMember(_ id: WindowID, in session: SavedLayoutSession?) -> Bool {
        switch session {
        case let .bento(state): return state.root?.windowIDs.contains(id) == true
        case let .tabbed(state): return state.windowIDs.contains(id)
        case .manual, nil: return false
        }
    }

    func permits(_ window: WindowSnapshot, observation: NativeDesktopObservation, displays: [DisplaySnapshot]) -> Bool {
        guard displays.contains(where: { $0.id == source.displayID }),
              displays.contains(where: { $0.id == destination.displayID }),
              observation.currentSpace(on: source.displayID) == source.spaceID,
              observation.currentSpace(on: destination.displayID) == destination.spaceID,
              observation.allowsAutomaticLayout(on: source.displayID),
              observation.allowsAutomaticLayout(on: destination.displayID) else { return false }
        let desktop = window.displayID == source.displayID ? source : destination
        return window.displayID == desktop.displayID && observation.windowMembership[window.id] == [desktop.spaceID]
    }
    var reversed: Self { .init(source: destination, destination: source) }
}

/// Apply and Undo carry their following policy into the same revision-checked commit.
enum SavedLayoutFollowingIntent {
    case start(layoutFileID: String, document: SavedLayoutDocument, expandedPreferences: [String: [String]])
    case end

    func make(plan: SavedLayoutApplyPlan, session: LayoutSession) -> FollowedLayout? {
        switch self {
        case let .start(file, document, preferences):
            FollowedLayout.make(layoutFileID: file, document: document, plan: plan,
                                expandedPreferences: preferences, session: session)
        case .end: nil
        }
    }
}

/// One reading of the live desktop. The model builds it; tests supply a fake.
struct SavedLayoutApplySnapshot {
    var observation: NativeDesktopObservation
    var displays: [DisplaySnapshot]
    var windows: [WindowSnapshot]
    var knownWindows: [WindowSnapshot]
    var sessions: [DisplayID: SavedLayoutSession]
    var generation: Int
    var isStable: Bool
    var readyDisplays: Set<DisplayID>
    /// Displays whose session waits for Repair Layout after an unsafe restore.
    var suspendedDisplays: Set<DisplayID> = []
    var tabbedPresentation: TabbedStripPresentation = .alwaysVisible
    var requestedTransfers: [WindowID: SavedLayoutRequestedTransfer] = [:]
    var followedLayouts: [DisplayID: FollowedLayout] = [:]
    var sessionOwners: [DisplayID: LayoutSession]? = nil
    var followingIntent: SavedLayoutFollowingIntent = .end
    /// One front-to-back public stack read for this inventory. Unknown ranks remain Int.max.
    var stackingOrder: [TabbedStackEntry]? = nil
    /// A transient session hold forbids forward and recovery writes alike.
    var sessionIsAvailable: @MainActor () -> Bool = { true }
    var isAutomatic = false

    var frontRanks: [WindowID: Int] {
        var ranks: [WindowID: Int] = [:]
        for (rank, id) in (stackingOrder ?? []).compactMap(\.windowID).enumerated() where ranks[id] == nil { ranks[id] = rank }
        return ranks
    }
}

/// What the plan sheet shows for one slot. Titles come from live observation and are never saved.
struct SavedLayoutPreviewRow: Identifiable {
    enum Status {
        case matched(WindowSnapshot)
        case severalWindows([WindowSnapshot])
        case empty, onAnotherDesktop, notInstalled

    }
    let slot: SavedLayoutSlot
    let appName: String
    let status: Status
    var sourceDisplayID: DisplayID? = nil
    var eligibleWindowCount = 0
    var candidates: [WindowSnapshot] = []
    var choiceWindows: [WindowSnapshot] {
        if !candidates.isEmpty { return candidates }
        if case let .severalWindows(windows) = status { return windows }
        return []
    }
    var id: String { slot.id }
}

struct SavedLayoutPreview {
    var document: SavedLayoutDocument
    var displayID: DisplayID
    var rows: [SavedLayoutPreviewRow]
    /// Set when the layout cannot fit the matched windows. Nothing would move.
    var problem: String?
    var workArea: BTRect? = nil
    var plan: SavedLayoutApplyPlan? = nil
    var windows: [WindowSnapshot] = []
    var windowNames: [WindowID: String] = [:]
}

/// The windows a Save Current Layout sheet offers for one display's current desktop.
struct SavedLayoutCaptureSetup {
    var displayID: DisplayID
    var session: SavedLayoutSession
    var windows: [SavedLayoutEligibleWindow]
    var workArea: BTRect
    var members: Set<WindowID>
    /// Layout members that have no app identifier or are not eligible. Capture leaves them out.
    var omitted: Int
    var checked: Set<WindowID>
}

struct SavedLayoutFeedback {
    var title: String
    var detail: String?
    var kind: ResultPillFeedback.Kind
    var displayID: DisplayID?
    /// True for an Apply result, which offers Undo and Details. False for the result of an Undo.
    var isApply: Bool
    /// True only when this run made an Undo checkpoint. A rolled-back or empty Apply never offers the
    /// Undo of an earlier Apply.
    var offersUndo = false
    /// True for an Apply that BetterTile started when displays connected. Its pill appears on its own display.
    var automatic = false
}

struct SavedLayoutRun {
    typealias Status = SavedLayoutResultPresentation.Status

    var layoutName: String
    /// True only if this run made an Undo checkpoint. Last run shows no Undo otherwise.
    var offersUndo = false
    var date: Date
    var displayID: DisplayID
    var result: SavedLayoutApplyResult
    /// Set when the run never started: the displays were uncertain, or input cancelled the wait.
    var declared: Status?
    var planPresentation: SavedLayoutPlanPresentation? = nil
    var needsSaveForFollowing = false
    /// Non-nil only for refused choice admission. Successful Applies consume their choices.
    var retryChoices: [String: WindowID]? = nil

    var presentation: SavedLayoutResultPresentation {
        var value = result.presentation(layout: layoutName, declared: declared)
        if let planPresentation {
            value.title = planPresentation.alreadyArranged ? SavedLayoutApplyPolicy.settledRepeat(layout: layoutName, arrangedSummary: planPresentation.summary).title : planPresentation.title
            value.summary = planPresentation.summary
            value.pillDetail = planPresentation.alreadyArranged ? "Already arranged." : planPresentation.summary
            value.message = planPresentation.title
            value.status = .applied
            value.severity = planPresentation.issues.isEmpty ? .success : .warning
            value.issues = planPresentation.issues
            for (id, detail) in planPresentation.slotDetails {
                if var slot = value.slots[id] {
                    slot.detail = detail
                    if planPresentation.emptySlots.contains(id) { slot.text = "Empty" }
                    value.slots[id] = slot
                }
            }
        }
        if needsSaveForFollowing {
            let notice = "Save this layout to keep following new windows."
            value.issues.append(.init(.other, notice))
            value.pillDetail = [value.pillDetail, notice].filter { !$0.isEmpty }.joined(separator: " ")
        }
        return value
    }
    var status: Status { presentation.status }

}

/// Runtime arrangement only. Focus, selected tabs, observed frames and bookkeeping revisions
/// do not replace an arrangement. Pane identity, topology, preset ratios and membership do.
private struct SavedLayoutUndoStructure: Equatable {
    private indirect enum Tree: Equatable {
        case window(WindowID), empty(UUID), pane(UUID)
        case split(UUID, SplitAxis, [Double], [Tree])
    }
    private let mode: LayoutMode
    private let root: Tree?
    private let members: [UUID: Set<WindowID>]

    init(_ session: SavedLayoutSession) {
        mode = session.mode
        let layout: BentoLayoutState?
        let tabbed: TabbedLayoutState?
        switch session {
        case .manual: layout = nil; tabbed = nil
        case let .bento(value): layout = value; tabbed = nil
        case let .tabbed(value): layout = value.layout; tabbed = value
        }
        func tree(_ node: BentoNode) -> Tree {
            switch node {
            case let .leaf(id):
                if let pane = tabbed?.pane(containing: id) { return .pane(pane.id) }
                return .window(id)
            case let .vacant(id): return tabbed == nil ? .empty(id) : .pane(id)
            case let .partition(partition):
                // A selected tab can temporarily grow its pane without changing the user's preset.
                return .split(partition.id, partition.axis, tabbed?.preferredPaneRatios[partition.id] ?? partition.ratios, partition.children.map(tree))
            }
        }
        root = layout?.root.map(tree)
        members = Dictionary(uniqueKeysWithValues: (tabbed?.panes ?? []).map { ($0.id, Set($0.tabs)) })
    }
}

/// Applies a Saved Layout to one visible desktop. Writes use the coordinator commit seam.
@Observable @MainActor final class SavedLayoutApplier {
    private static let timingLog = Logger(subsystem: "com.lmckarma.BetterTile", category: "SavedLayoutTiming")
    private var timingRun = 0
    enum TimingPhase: String {
        case total, inventory, plan, commit
        case coordinatorFinalOwnership = "failure.coordinator.finalOwnership"
        case modelPlacement = "failure.model.placement"
        case modelPostPlacement = "failure.model.postPlacement"
        case modelPostSettlement = "failure.model.postSettlement"
        case modelFinalValidation = "failure.model.finalValidation"
        case modelSessionCommit = "failure.model.sessionCommit"
        case applierBeforeCommit = "failure.applier.beforeCommit"
        case applierModelCommit = "failure.applier.modelCommit"
        case applierFinalCurrent = "failure.applier.finalCurrent"
        case currentOperation = "failure.current.operation"
        case currentCancelled = "failure.current.cancelled"
        case currentSnapshot = "failure.current.snapshot"
        case currentReadiness = "failure.current.readiness"
        case currentGeneration = "failure.current.generation"
        case currentSpace = "failure.current.space"
        case settlementInterrupted = "failure.settlement.interrupted"
        case settlementSuperseded = "failure.settlement.superseded"
        case settlementWindowRead = "failure.settlement.windowRead"
        case settlementOwnership = "failure.settlement.ownership"
        case settlementOverlap = "failure.settlement.overlap"
        case settlementFrames = "failure.settlement.frames"
        case settlementRetryFailed = "failure.settlement.retryFailed"
        case settlementRetryDegraded = "failure.settlement.retryDegraded"
    }
    /// Fixed codes only. Never pass window, application, or desktop content to this log.
    func recordFailure(_ phase: TimingPhase, run: Int? = nil) {
        timing(run ?? timingRun, 0, phase, 0)
    }
    func recordSettlementFailure(_ cause: WindowCoordinator.SettlementFailure) {
        let phase: TimingPhase = switch cause {
        case .interrupted: .settlementInterrupted
        case .superseded: .settlementSuperseded
        case .windowRead: .settlementWindowRead
        case .ownership: .settlementOwnership
        case .overlap: .settlementOverlap
        case .frames: .settlementFrames
        case .retryFailed: .settlementRetryFailed
        case .retryDegraded: .settlementRetryDegraded
        }
        recordFailure(phase)
    }
    var timing: (Int, Int, TimingPhase, TimeInterval) -> Void = { run, slot, phase, seconds in
        #if DEBUG
        timingLog.debug("run=\(run) slot=\(slot) phase=\(phase.rawValue, privacy: .public) ms=\(seconds * 1000)")
        #endif
    }
    private func record(_ phase: TimingPhase, since start: TimeInterval) {
        timing(timingRun, 0, phase, uptime() - start)
    }
    private func inventory() throws -> SavedLayoutApplySnapshot {
        let start = uptime()
        defer { record(.inventory, since: start) }
        let state = try snapshot()
        updateUndoDesktops(state.observation, displays: state.displays, sessions: state.sessions)
        return state
    }
    var appGroupsStore: AppGroupsStore?
    var prepareAppGroups: () async -> Void = {}
    var isLoadingAppGroups = false
    func appGroupsDidLoad() { isLoadingAppGroups = false; planRevision &+= 1 }
    private(set) var lastPlan: SavedLayoutApplyPlan?
    private var completedPlanPresentation: SavedLayoutPlanPresentation?
    var snapshot: () throws -> SavedLayoutApplySnapshot
    var placementSnapshot: () throws -> SavedLayoutApplySnapshot
    var destinationSnapshot: () throws -> SavedLayoutApplySnapshot
    var commit: @MainActor (SavedLayoutApplyPlan, SavedLayoutDesktop, SavedLayoutApplySnapshot, @escaping () -> Bool) async -> Bool
    var currentDisplayID: () -> DisplayID? = { nil }
    var didFinish: () -> Void = {}
    /// A display absence must not drop a desktop the model still owns,
    /// including a retired desktop that a reconnect can restore. The model
    /// releases this protection when its session store forgets that desktop.
    var isDesktopRetained: (SavedLayoutDesktop) -> Bool = { _ in false }
    var feedback: (SavedLayoutFeedback) -> Void = { _ in }
    var application: (String) -> ApplicationChoice? = { id in
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: id).flatMap(ApplicationCatalog.application(at:))
    }
    var runningApplicationName: (Int32) -> String? = { NSRunningApplication(processIdentifier: $0)?.localizedName }
    var displayName: (DisplayID, [DisplaySnapshot]) -> String = { savedLayoutDisplayName($0, among: $1) }
    /// Tabbed requests retain their own reservations; Saved Layouts creates none.
    var reservesOtherOwnerWindow: (WindowSnapshot) -> Bool = { _ in false }
    var uptime: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    var observesKeyboard = true
    private(set) var slotStatuses: [String: SavedLayoutSlotStatus] = [:]
    private(set) var lastDocument: SavedLayoutDocument?
    private(set) var lastDesktop: SavedLayoutDesktop?
    private(set) var lastRun: SavedLayoutRun?
    private(set) var message: String?
    private(set) var isRunning = false
    private(set) var ownedDisplayID: DisplayID?
    private(set) var planRevision = 0
    private var positionContext: SavedLayoutPositionContext?
    private var layoutFileID: String?
    private struct PositionUndo {
        var context: SavedLayoutPositionContext
        var previous: [String: NormalizedRect]
        var recorded: [String: NormalizedRect]
    }
    private var positionUndos: [UUID: PositionUndo] = [:]
    private var operation = 0
    private var runCheckpoint = false
    private var silentRun = false
    /// At most one completed result per display waits for this user's session to return.
    private var deferredAutomaticRuns: [DisplayID: SavedLayoutRun] = [:]
    private var rememberedAssignments: [SavedLayoutDesktop: (SavedLayoutDocument, [String: WindowID], URL?)] = [:]
    /// Desktops in Apply order, oldest first. A reconnect or a restored
    /// desktop can bring a desktop's key back after the model forgot it, so
    /// an absent desktop keeps its state while it is one of the newest
    /// `absentDesktopLimit` absent desktops. A newer absent desktop past that
    /// limit evicts the oldest one, which then returns without remembered
    /// slots or Undo. The limit matches the session store's retired list.
    private var appliedDesktops: [SavedLayoutDesktop] = []
    static let absentDesktopLimit = 32
    private func noteApplied(_ desktop: SavedLayoutDesktop) {
        appliedDesktops.removeAll { $0 == desktop }
        appliedDesktops.append(desktop)
    }
    private var lastRunAutomatic = false
    var refusedSizes: [WindowID: BTSize] = [:]
    /// A model refusal before any mutation keeps the preceding Undo checkpoint.
    var precommitRefusal: SavedLayoutCommitRefusal?
    private(set) var followingFailureCount = 0
    private(set) var followingIssue: String?
    func recordFollowingFailure() {
        followingFailureCount += 1
        followingIssue = "This layout could not keep following new windows."
    }
    private struct UndoRecord {
        let id: UUID
        let desktop: SavedLayoutDesktop
        let document: SavedLayoutDocument
        let fileID: String?
        let layoutURL: URL?
        let frames: [WindowID: BTRect]
        let session: SavedLayoutSession
        let processes: [WindowID: Int32]
        let transfers: [WindowID: SavedLayoutRequestedTransfer]
        var committedSessions: [SavedLayoutDesktop: SavedLayoutUndoStructure]
        let plannedSessions: [SavedLayoutDesktop: SavedLayoutUndoStructure]
        var pending = true
        var observedCommit: Set<SavedLayoutDesktop> = []
    }
    @ObservationIgnored private var undoSessionCache: [SavedLayoutDesktop: SavedLayoutUndoStructure] = [:]
    private var expiredUndoIDs: Set<UUID> = []
    @ObservationIgnored private var undoRestoration: (id: UUID, sessions: [SavedLayoutDesktop: SavedLayoutUndoStructure])?
    static let undoExpired = "The desktop changed after Apply. Undo Apply is no longer available."

    private var undos: [DisplayID: UndoRecord] = [:]
    private var undoDesktops: [DisplayID: NativeSpaceID] = [:]
    private var undoOrder: [DisplayID] = []
    private var lastUndoDisplay: DisplayID? { undoOrder.last { undos[$0] != nil } }
    private static let cancelled = "Saved Layout cancelled."
    static let desktopNotReady = "This desktop cannot be laid out now. It may be fullscreen, use Stage Manager, or still be settling. Try again in a moment."
    private static let needsRepair = "This display waits for Repair Layout. Use Repair Layout first, then try Apply again."
    private static let applyUndone = "Previous window frames restored."
    private var removeKeyMonitors: (() -> Void)?
    private var startPending = false
    private var handingOffStart = false
    private(set) var isStarting = false
    var isApplying: Bool { isRunning || startPending || isStarting }
    var isBusy: Bool { isApplying }
    private var task: Task<Void, Never>?

    init(snapshot: @escaping () throws -> SavedLayoutApplySnapshot,
         commit: @escaping @MainActor (SavedLayoutApplyPlan, SavedLayoutDesktop, SavedLayoutApplySnapshot, @escaping () -> Bool) async -> Bool) {
        self.snapshot = snapshot; placementSnapshot = snapshot; destinationSnapshot = snapshot; self.commit = commit
    }
    var canUndo: Bool { !isBusy && undos.values.contains { !undoSessionChanged($0) } }
    var hasUndo: Bool { !undos.isEmpty }
    var tracksUndoSessions: Bool { undos.values.contains { !expiredUndoIDs.contains($0.id) } }
    func canUndo(on displayID: DisplayID) -> Bool { !isBusy && undos[displayID].map { !undoSessionChanged($0) } == true }
    /// Retired desktops cannot reuse an Apply checkpoint from the old screen.
    func invalidateUndo(involving windowIDs: Set<WindowID>, desktop: SavedLayoutDesktop?) {
        for undo in undos.values where !windowIDs.isDisjoint(with: undo.frames.keys)
            || desktop.map({ undo.committedSessions[$0] != nil }) == true {
            expiredUndoIDs.insert(undo.id)
        }
    }

    var lastLayoutURL: URL? { positionContext?.layoutURL }
    /// Apply inventories and model events refresh this cache. Rendering performs no system reads.
    func updateUndoDesktops(_ observation: NativeDesktopObservation?, displays: [DisplaySnapshot], sessions: [DisplayID: SavedLayoutSession]? = nil) {
        let connected = Set(displays.map(\.id))
        undoDesktops = observation?.currentSpaceByDisplay.filter { connected.contains($0.key) } ?? [:]
        if let observation, !isBusy, undoRestoration == nil {
            // Missing observations are not proof that a desktop disappeared.
            // Keep inactive, existing Spaces, desktops the model still owns,
            // the newest absent desktops and every in-flight checkpoint.
            func owned(_ desktop: SavedLayoutDesktop) -> Bool {
                (connected.contains(desktop.displayID)
                    && observation.knownSpacesByDisplay[desktop.displayID]?.contains(desktop.spaceID) != false)
                    || isDesktopRetained(desktop)
            }
            let recentAbsent = Set(appliedDesktops.filter { !owned($0) }.suffix(Self.absentDesktopLimit))
            func retained(_ desktop: SavedLayoutDesktop) -> Bool { owned(desktop) || recentAbsent.contains(desktop) }
            appliedDesktops.removeAll { !retained($0) }
            for desktop in rememberedAssignments.keys.filter({ !retained($0) }) {
                rememberedAssignments.removeValue(forKey: desktop)
            }
            for display in undos.keys.filter({ undos[$0].map { !retained($0.desktop) } == true }) {
                undos.removeValue(forKey: display)
            }
            if undoOrder.contains(where: { undos[$0] == nil }) { undoOrder.removeAll { undos[$0] == nil } }
            let checkpoints = Set(undos.values.map(\.id))
            for id in expiredUndoIDs.subtracting(checkpoints) { expiredUndoIDs.remove(id) }
            for id in positionUndos.keys.filter({ !checkpoints.contains($0) }) { positionUndos.removeValue(forKey: id) }
            for desktop in undoSessionCache.keys.filter({ !retained($0) })
                where !undos.values.contains(where: { $0.committedSessions[desktop] != nil }) {
                undoSessionCache.removeValue(forKey: desktop)
            }
        }
        if let sessions { updateUndoSessions(sessions, desktops: undoDesktops) }
    }

    /// Model store changes call this with cached session values. Rendering never inventories windows.
    func updateUndoSessions(_ sessions: [DisplayID: SavedLayoutSession], desktops: [DisplayID: NativeSpaceID] = [:]) {
        let spaces = undoDesktops.merging(desktops) { _, new in new }
        for (display, space) in spaces {
            undoSessionCache[.init(displayID: display, spaceID: space)] = .init(sessions[display] ?? .manual)
        }
        checkUndoSessions()
        let retained = Set(undos.values.flatMap { $0.committedSessions.keys })
            .union(spaces.map { SavedLayoutDesktop(displayID: $0.key, spaceID: $0.value) })
        undoSessionCache = undoSessionCache.filter { retained.contains($0.key) }
    }

    private func checkUndoSessions() {
        for (display, var undo) in undos where !expiredUndoIDs.contains(undo.id) {
            let observed = undo.observedCommit
            for (desktop, committed) in undo.committedSessions {
                guard let latest = undoSessionCache[desktop] else { continue }
                if undoRestoration?.id == undo.id, latest == undoRestoration?.sessions[desktop] { continue }
                if undo.pending {
                    // Mode activation can publish an intermediate tree before Apply installs its target.
                    // Once the committed target has appeared, a later change must still expire Undo.
                    if latest == undo.plannedSessions[desktop] { undo.observedCommit.insert(desktop) }
                    else if undo.observedCommit.contains(desktop) { expiredUndoIDs.insert(undo.id) }
                } else if latest != committed { expiredUndoIDs.insert(undo.id) }
            }
            if undo.observedCommit != observed { undos[display] = undo }
        }
    }

    private func undoSessionChanged(_ undo: UndoRecord) -> Bool {
        expiredUndoIDs.contains(undo.id) || undo.committedSessions.contains { desktop, expected in
            undoSessionCache[desktop].map { $0 != expected } == true
        }
    }

    private func undoRefusal(_ undo: UndoRecord) -> String? {
        if expiredUndoIDs.contains(undo.id) { return Self.undoExpired }
        for (desktop, expected) in undo.committedSessions {
            guard undoDesktops[desktop.displayID] == desktop.spaceID else {
                return "Go to the desktop of the last Apply before choosing Undo."
            }
            if undoSessionCache[desktop] != expected { return Self.undoExpired }
        }
        return nil
    }

    private func finishUndoCheckpoint(_ id: UUID, on display: DisplayID, didCommit: Bool) {
        defer { expiredUndoIDs.formIntersection(Set(undos.values.map(\.id))) }
        guard var undo = undos[display], undo.id == id else { checkUndoSessions(); return }
        let latest = try? snapshot()
        if let latest {
            updateUndoDesktops(latest.observation, displays: latest.displays, sessions: latest.sessions)
            undo = undos[display] ?? undo
            for desktop in undo.committedSessions.keys where latest.observation.currentSpace(on: desktop.displayID) == desktop.spaceID {
                undo.committedSessions[desktop] = .init(latest.sessions[desktop.displayID] ?? .manual)
            }
        } else { undo.committedSessions = undo.plannedSessions }
        undo.pending = false
        undos[display] = undo
        if didCommit {
            let touched = Set(undo.committedSessions.keys)
            for other in undos.values where other.id != id && !touched.isDisjoint(with: other.committedSessions.keys) {
                expiredUndoIDs.insert(other.id)
            }
        }
        if latest != nil { checkUndoSessions() }
    }
    /// A settled repeat owns no new checkpoint, but can still expose its earlier Apply's Undo.
    func canUndo(_ run: SavedLayoutRun) -> Bool {
        guard !isBusy, run.date == lastRun?.date,
              let undo = undos[run.displayID], undo.document == lastDocument,
              undo.fileID == layoutFileID, undo.layoutURL == lastLayoutURL,
              undo.desktop == lastDesktop,
              undoDesktops[run.displayID] == undo.desktop.spaceID else { return false }
        return undoRefusal(undo) == nil
    }
    func undoUnavailableReason(_ run: SavedLayoutRun) -> String? {
        guard !isBusy, run.date == lastRun?.date, let undo = undos[run.displayID],
              undo.document == lastDocument, undo.fileID == layoutFileID, undo.layoutURL == lastLayoutURL else { return nil }
        return undoRefusal(undo)
    }
    func cancel() {
        operation &+= 1
        task?.cancel()
        message = Self.cancelled
    }
    func stop() { cancel(); removeMonitors(); discardDeferredAutomaticResults() }

    private func installMonitors() {
        guard observesKeyboard else { return }
        let token = operation
        removeKeyMonitors = observeKeyDown { [weak self] keyCode in
            if let self, self.operation == token, keyCode == 53 { self.cancel() }
        }
    }

    /// Watches key-downs while an Apply runs and returns the call that stops watching. It reads only the key code.
    /// AppKit calls a process's local monitors in an unspecified order, and any monitor that consumes Escape
    /// starves the others. Tests replace this to deliver Escape without depending on that order.
    var observeKeyDown: (@escaping @MainActor (UInt16) -> Void) -> () -> Void = { handler in
        let local = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let keyCode = event.keyCode
            MainActor.assumeIsolated { handler(keyCode) }
            return event
        }
        let global = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            let keyCode = event.keyCode
            // AppKit invokes both monitor kinds on the main thread. Do not queue
            // cancellation behind the transaction that the key is meant to stop.
            MainActor.assumeIsolated { handler(keyCode) }
        }
        return {
            if let local { NSEvent.removeMonitor(local) }
            if let global { NSEvent.removeMonitor(global) }
        }
    }

    private func removeMonitors() {
        removeKeyMonitors?()
        removeKeyMonitors = nil
    }

    static let applyingBusy = "Applying… Wait before applying or resetting the layout."

    private func begin() -> Int? {
        guard !isRunning else { message = Self.applyingBusy; return nil }
        isRunning = true; operation &+= 1
        installMonitors()
        return operation
    }
    private func end() {
        ownedDisplayID = nil; isRunning = false
        planRevision &+= 1
        removeMonitors(); didFinish()
    }

    private func current(_ token: Int, desktop: SavedLayoutDesktop, generation: Int? = nil, requiringReady: Bool = true) -> Bool {
        guard token == operation else { recordFailure(.currentOperation, run: token); return false }
        guard !Task.isCancelled else { recordFailure(.currentCancelled, run: token); return false }
        guard let state = try? destinationSnapshot() else { recordFailure(.currentSnapshot, run: token); return false }
        guard !requiringReady || (state.isStable && state.readyDisplays.contains(desktop.displayID)) else {
            recordFailure(.currentReadiness, run: token); return false
        }
        guard generation == nil || generation == state.generation else {
            recordFailure(.currentGeneration, run: token); return false
        }
        guard state.observation.currentSpace(on: desktop.displayID) == desktop.spaceID else {
            recordFailure(.currentSpace, run: token); return false
        }
        updateUndoDesktops(state.observation, displays: state.displays, sessions: state.sessions)
        return true
    }

    private func commitValidated(_ plan: SavedLayoutApplyPlan, _ desktop: SavedLayoutDesktop,
                                 _ state: SavedLayoutApplySnapshot, _ isCurrent: @escaping () -> Bool) async -> Bool {
        guard isCurrent() else { recordFailure(.applierBeforeCommit); return false }
        guard await commit(plan, desktop, state, isCurrent) else { recordFailure(.applierModelCommit); return false }
        guard isCurrent() else { recordFailure(.applierFinalCurrent); return false }
        return true
    }

    @discardableResult
    private func validateDestination(_ token: Int, desktop: SavedLayoutDesktop, generation: Int) throws -> SavedLayoutApplySnapshot {
        guard token == operation, !Task.isCancelled else { throw CancellationError() }
        let state = try destinationSnapshot()
        guard state.observation.currentSpace(on: desktop.displayID) == desktop.spaceID else {
            throw SavedLayoutFileError(message: "The current Space changed. Saved Layout stopped.")
        }
        guard state.generation == generation else {
            throw SavedLayoutFileError(message: "The desktop stabilization generation changed. Saved Layout stopped.")
        }
        return state
    }

    private func desktop(on displayID: DisplayID?, in state: SavedLayoutApplySnapshot) throws -> SavedLayoutDesktop {
        let target = displayID ?? SavedLayoutTarget.resolve(current: currentDisplayID(), displays: state.displays)
        guard let target, state.displays.contains(where: { $0.id == target }),
              let space = state.observation.currentSpace(on: target) else {
            throw SavedLayoutFileError(message: "The current desktop could not be identified.")
        }
        return SavedLayoutDesktop(displayID: target, spaceID: space)
    }

    private func eligible(_ state: SavedLayoutApplySnapshot, on desktop: SavedLayoutDesktop,
                          excluding: Set<WindowID> = []) -> [SavedLayoutEligibleWindow] {
        let ranks = state.frontRanks
        return state.windows.filter { window in
            (window.displayID == desktop.displayID || state.requestedTransfers[window.id]?.destination == desktop)
                && window.isEligible && !window.isFloating
                && !excluding.contains(window.id)
                && !reservesOtherOwnerWindow(window)
                && (state.requestedTransfers[window.id].map { $0.permits(window, observation: state.observation, displays: state.displays) }
                    ?? (state.observation.windowMembership[window.id].map { $0.isEmpty || $0 == [desktop.spaceID] } != false))
        }.compactMap { window in
            window.bundleIdentifier.map { SavedLayoutEligibleWindow(id: window.id, bundleID: $0,
                frame: window.frame, constraints: window.constraints, frontRank: ranks[window.id] ?? .max) }
        }
    }

    private struct ExistingPlan {
        var plan: SavedLayoutApplyPlan
        var windows: [SavedLayoutEligibleWindow]
        var localIDs: Set<WindowID>
        var transfers: [WindowID: SavedLayoutRequestedTransfer]
        var counts: [WindowID: Int]
    }

    /// Preview and Apply share this read-only planning path, including local-first reuse and all
    /// foreign-window exclusions. Proposed transfers here are values, never guards or reservations.
    private func existingPlan(_ document: SavedLayoutDocument, in state: SavedLayoutApplySnapshot,
                              on desktop: SavedLayoutDesktop, workArea: BTRect,
                              explicit: [String: WindowID] = [:], excluding: Set<WindowID> = [],
                              automatic: Bool = false, preferredFrames: [String: NormalizedRect] = [:],
                              layoutURL: URL? = nil, requiringExplicitChoices: Bool = false) throws -> ExistingPlan {
        let groups = appGroupsStore?.document ?? AppGroupsDocument()
        let resolved = appGroupsStore?.resolvedBundleIDs ?? [:]
        let started = uptime()
        defer { record(.plan, since: started) }
        var choices = (automatic ? [:] : explicit).filter { slot, _ in document.slots.contains { $0.id == slot } }
        let local = eligible(state, on: desktop, excluding: excluding)
        let foreignChoices = choices.filter { _, id in !local.contains { $0.id == id } }
        choices = choices.filter { _, id in local.contains { $0.id == id } }
        func foreignWindows(matching bundles: Set<String>) -> [SavedLayoutEligibleWindow] {
            return state.windows.compactMap { window in
                guard window.displayID != desktop.displayID, let bundle = window.bundleIdentifier, (bundles.contains { $0.caseInsensitiveCompare(bundle) == .orderedSame } || foreignChoices.values.contains(window.id)),
                      window.isEligible, !window.isFloating, !excluding.contains(window.id),
                      !reservesOtherOwnerWindow(window),
                      state.readyDisplays.contains(window.displayID), !state.suspendedDisplays.contains(window.displayID),
                      !SavedLayoutRequestedTransfer.isPaneMember(window.id, in: state.sessions[window.displayID]),
                      let space = state.observation.currentSpace(on: window.displayID),
                      state.observation.windowMembership[window.id] == [space],
                      state.observation.allowsAutomaticLayout(on: window.displayID),
                      let display = state.displays.first(where: { $0.id == window.displayID }) else { return nil }
                return .init(id: window.id, bundleID: bundle, frame: window.frame, constraints: window.constraints,
                    matchingFrame: .init(frame: window.frame, in: display.visibleFrame), frontRank: state.frontRanks[window.id] ?? .max)
            }
        }
        if requiringExplicitChoices, !automatic {
            let foreignIDs = foreignChoices.isEmpty ? Set<WindowID>() : Set(foreignWindows(matching: []).map(\.id))
            let admitted = explicit.filter { slot, id in
                document.slots.contains { $0.id == slot } && (local.contains { $0.id == id } || foreignIDs.contains(id))
            }
            guard admitted == explicit else { throw SavedLayoutChoiceRefusal(retryChoices: admitted) }
        }
        func plan(_ windows: [SavedLayoutEligibleWindow], choices: [String: WindowID]) throws -> SavedLayoutApplyPlan {
            try SavedLayoutPlanner.plan(document, in: workArea, windows: windows, appGroups: groups, resolvedBundleIDs: resolved, choices: choices, preferredFrames: preferredFrames,
                currentSession: state.sessions[desktop.displayID] ?? .manual, tabbedPresentation: state.tabbedPresentation)
        }
        // Always compute the current preferred-match/rank optimum before considering memory.
        // Remembered occupants can stabilize an equally good plan, but are not user choices.
        var result = try plan(local, choices: choices)
        if let remembered = rememberedAssignments[desktop], remembered.0 == document, remembered.2 == layoutURL,
           remembered.1 != result.assignments {
            let retained = remembered.1.filter { slot, id in
                choices[slot] == nil && !choices.values.contains(id) && local.contains { $0.id == id }
            }.merging(choices) { _, explicit in explicit }
            if var stable = try? plan(local, choices: retained) {
                func ranks(_ assignments: [String: WindowID]) -> [Int] {
                    var counts = Array(repeating: 0, count: document.slots.map { expandedPreferences($0).count }.max() ?? 0)
                    for slot in document.slots {
                        guard let id = assignments[slot.id], let window = local.first(where: { $0.id == id }),
                              let rank = expandedPreferences(slot).firstIndex(where: { $0.caseInsensitiveCompare(window.bundleID) == .orderedSame }) else { continue }
                        counts[rank] += 1
                    }
                    return counts
                }
                if ranks(stable.assignments) == ranks(result.assignments),
                   Set(stable.assignments.keys) == Set(result.assignments.keys) {
                    for (slot, id) in stable.assignments where choices[slot] == nil && retained[slot] == id {
                        if let pane = document.slots.first(where: { $0.id == slot }), let window = local.first(where: { $0.id == id }),
                           let rank = expandedPreferences(pane).firstIndex(where: { $0.caseInsensitiveCompare(window.bundleID) == .orderedSame }) {
                            stable.slotReasons[slot] = .preferred(rank: rank)
                        } else { stable.slotReasons[slot] = .nearestPosition }
                    }
                    result = stable
                }
            }
        }
        var transfers: [WindowID: SavedLayoutRequestedTransfer] = [:]
        var foreign: [SavedLayoutEligibleWindow] = []
        if !automatic, !result.emptySlots.isEmpty || !foreignChoices.isEmpty {
            let bundles = Set(document.slots.filter { result.emptySlots.contains($0.id) }.flatMap { expandedPreferences($0) })
            foreign = foreignWindows(matching: bundles)
            let admittedForeignChoices = foreignChoices.filter { _, id in foreign.contains { $0.id == id } }
            let locked = result.assignments.filter { admittedForeignChoices[$0.key] == nil && !admittedForeignChoices.values.contains($0.value) }
                .merging(admittedForeignChoices) { _, explicit in explicit }
            var proposed = try plan(local + foreign, choices: locked)
            for (slot, reason) in result.slotReasons where proposed.assignments[slot] == result.assignments[slot] {
                proposed.slotReasons[slot] = reason
            }
            for id in proposed.assignments.values {
                guard foreign.contains(where: { $0.id == id }), let window = state.windows.first(where: { $0.id == id }),
                      let space = state.observation.currentSpace(on: window.displayID) else { continue }
                transfers[id] = .init(source: .init(displayID: window.displayID, spaceID: space), destination: desktop, reusesExistingWindow: true)
            }
            // Only chosen foreign windows enter the transaction. Unchosen source windows must
            // never enter the target display's unmatched-window reconciliation.
            result = try plan(local + foreign.filter { transfers[$0.id] != nil }, choices: proposed.assignments)
            result.slotReasons = proposed.slotReasons
        }
        if let remembered = rememberedAssignments[desktop], remembered.0 == document, remembered.2 == layoutURL,
           remembered.1 == result.assignments, result.placements.isEmpty,
           let current = state.sessions[desktop.displayID],
           Self.settledExceptHiddenTabOrder(current, result.targetSession) {
            result.targetSession = current
            result.needsSessionUpdate = false
        }
        let selected = local + foreign.filter { transfers[$0.id] != nil }
        var counts: [WindowID: Int] = [:]
        for window in selected {
            let pool = transfers[window.id] == nil ? local : foreign
            counts[window.id] = pool.filter { $0.bundleID == window.bundleID }.count
        }
        return .init(plan: result, windows: selected, localIDs: Set(local.map(\.id)), transfers: transfers, counts: counts)
    }

    /// Core re-sorts hidden tabs from the stack. A settled repeat must not reorder the strip.
    /// A changed selection, membership, tree or metrics still needs its normal transaction.
    private static func settledExceptHiddenTabOrder(_ current: SavedLayoutSession, _ desired: SavedLayoutSession) -> Bool {
        guard case let .tabbed(current) = current, case let .tabbed(desired) = desired else { return false }
        return current.layout == desired.layout && current.activePaneID == desired.activePaneID
            && current.preferredPaneRatios == desired.preferredPaneRatios
            && current.automaticallyFloatingWindowIDs == desired.automaticallyFloatingWindowIDs
            && current.panes.count == desired.panes.count
            && zip(current.panes, desired.panes).allSatisfy {
                $0.id == $1.id && $0.selected == $1.selected && Set($0.tabs) == Set($1.tabs)
            }
    }

    /// Reads the same initial plan as a user Apply, without mutation, guards, requests or launches.
    func preview(_ document: SavedLayoutDocument, displayID: DisplayID? = nil,
                 choices: [String: WindowID] = [:], positions: SavedLayoutPositionContext? = nil) throws -> SavedLayoutPreview {
        let state = try snapshot()
        let target = try desktop(on: displayID, in: state)
        guard let display = state.displays.first(where: { $0.id == target.displayID }) else {
            throw SavedLayoutFileError(message: "The display is not available.")
        }
        if state.suspendedDisplays.contains(target.displayID) {
            return .init(document: document, displayID: target.displayID, rows: [], problem: Self.needsRepair, workArea: display.visibleFrame)
        }
        if !state.isStable || !state.readyDisplays.contains(target.displayID) {
            return .init(document: document, displayID: target.displayID, rows: [], problem: Self.desktopNotReady, workArea: display.visibleFrame)
        }
        // Startup previews wait for resolved inputs. Apply itself awaits the same load task.
        // Returning no proposal lets Settings start Apply without planning against empty groups.
        if isLoadingAppGroups {
            return .init(document: document, displayID: target.displayID, rows: [], problem: nil, workArea: display.visibleFrame)
        }
        let prepared: ExistingPlan
        do {
            prepared = try existingPlan(document, in: state, on: target, workArea: display.visibleFrame,
                explicit: choices, preferredFrames: positions.map { $0.store.frames(for: $0.file) } ?? [:], layoutURL: positions?.layoutURL)
        } catch {
            return .init(document: document, displayID: target.displayID, rows: [],
                problem: (error as? SavedLayoutValidationError)?.issues.first?.message ?? error.localizedDescription, workArea: display.visibleFrame)
        }
        let live = Dictionary(uniqueKeysWithValues: state.windows.map { ($0.id, $0) })
        let rows = document.slots.map { slot -> SavedLayoutPreviewRow in
            let preferred = expandedPreferences(slot)
            if let id = prepared.plan.assignments[slot.id], let window = live[id] {
                return .init(slot: slot, appName: windowApplicationName(window), status: .matched(window),
                    sourceDisplayID: prepared.transfers[id]?.source.displayID, eligibleWindowCount: prepared.counts[id] ?? 1,
                    candidates: prepared.windows.compactMap { candidate in
                        guard candidate.bundleID.caseInsensitiveCompare(window.bundleIdentifier ?? "") == .orderedSame,
                              (prepared.localIDs.contains(id) == prepared.localIDs.contains(candidate.id)) else { return nil }
                        return live[candidate.id]
                    })
            }
            let elsewhere = state.knownWindows.contains { window in
                window.bundleIdentifier.map { bundle in preferred.contains { $0.caseInsensitiveCompare(bundle) == .orderedSame } } == true
                    && !window.isMinimized && !window.isFullScreen && !window.isFloating
                    && (window.displayID != target.displayID || state.observation.windowMembership[window.id].map { !$0.isEmpty && $0 != [target.spaceID] } == true)
            }
            let status: SavedLayoutPreviewRow.Status = elsewhere ? .onAnotherDesktop
                : preferred.first.map { application($0) == nil ? .notInstalled : .empty } ?? .empty
            return .init(slot: slot, appName: preferred.first.map(applicationName) ?? "Any window", status: status)
        }
        let windows = prepared.windows.compactMap { live[$0.id] }
        return .init(document: document, displayID: target.displayID, rows: rows, problem: nil, workArea: display.visibleFrame,
            plan: prepared.plan, windows: windows, windowNames: Dictionary(uniqueKeysWithValues: windows.map { ($0.id, windowApplicationName($0)) }))
    }

    /// Reads the eligible windows for Save Current Layout. It does not change a window.
    func captureSetup(displayID: DisplayID? = nil) throws -> SavedLayoutCaptureSetup {
        let state = try snapshot()
        let target = try desktop(on: displayID, in: state)
        guard let display = state.displays.first(where: { $0.id == target.displayID }) else {
            throw SavedLayoutFileError(message: "The display is not available.")
        }
        let session = state.sessions[target.displayID] ?? .manual
        let windows = eligible(state, on: target).sorted { $0.id < $1.id }
        return .init(displayID: target.displayID, session: session, windows: windows, workArea: display.visibleFrame,
                     members: SavedLayoutCaptureSelection.members(of: session).intersection(windows.map(\.id)),
                     omitted: SavedLayoutCaptureSelection.members(of: session).subtracting(windows.map(\.id)).count,
                     checked: SavedLayoutCaptureSelection.defaultChecked(session: session, windows: windows))
    }

    func start(_ document: SavedLayoutDocument, displayID: DisplayID? = nil,
               choices: [String: WindowID] = [:],
               positions: SavedLayoutPositionContext? = nil) {
        guard !isApplying else { message = Self.applyingBusy; return }
        isStarting = true
        startPending = true
        task = Task { [weak self] in
            guard let self else { return }
            startPending = false
            guard !Task.isCancelled else { return }
            handingOffStart = true
            _ = await apply(document, displayID: displayID, choices: choices, positions: positions)
        }
        // A fast run can finish before this handoff clears. Every surface stays busy until then.
        Task { @MainActor [weak self] in
            await Task.yield()
            self?.isStarting = false
        }
    }

    @discardableResult
    func apply(_ document: SavedLayoutDocument, displayID: DisplayID? = nil, choices: [String: WindowID] = [:],
               excluding: Set<WindowID> = [], automatic: Bool = false,
               positions: SavedLayoutPositionContext? = nil, layoutFileID: String? = nil,
               sessionIsAvailable: @escaping @MainActor () -> Bool = { true },
               validating: @escaping @MainActor () -> Bool = { true }) async -> SavedLayoutApplyResult {
        let handoff = handingOffStart
        handingOffStart = false
        guard (!isStarting && !startPending) || handoff else { message = Self.applyingBusy; return .init() }
        guard let token = begin() else { return .init() }
        positionContext = automatic ? nil : positions
        self.layoutFileID = layoutFileID ?? positions?.file
        timingRun = token
        let started = uptime()
        completedPlanPresentation = nil
        lastPlan = nil
        defer { record(.total, since: started); end() }
        runCheckpoint = false
        silentRun = false
        refusedSizes = [:]
        precommitRefusal = nil
        followingIssue = nil
        do {
            await prepareAppGroups()
            guard token == operation, !Task.isCancelled else { throw CancellationError() }
            guard sessionIsAvailable() else { throw CancellationError() }
            guard validating() else { throw SavedLayoutFileError(message: SavedLayoutCommitRefusal.bindingChanged.message) }
            let target = try desktop(on: displayID, in: try inventory())
            lastDocument = document; lastDesktop = target
            slotStatuses = Dictionary(uniqueKeysWithValues: document.slots.map { ($0.id, .waiting) })
            var result = try await performPlan(document, on: target, token: token, explicitChoices: choices,
                                               excluding: excluding, automatic: automatic,
                                               sessionIsAvailable: sessionIsAvailable, validating: validating)
            // Cancellation or a session hold invalidates commit validation.
            // If nothing committed, report stopped rather than a generic placement failure.
            if token != operation || !sessionIsAvailable(), result.placed == 0 {
                let recovery = runCheckpoint ? " Some windows could not be restored. Use Undo or Repair Layout." : ""
                result.issues = [.init(.stopped, Self.cancelled + recovery)]
            }
            let sessionHeld = !sessionIsAvailable()
            if sessionHeld { silentRun = true }
            publish(result, document: document, displayID: target.displayID, automatic: automatic,
                    deferAutomaticFeedback: automatic && sessionHeld)
            return lastRun?.result ?? result
        } catch {
            // Escape bumps `operation`, which also fails the desktop check. Say what the user did.
            let reason: any Error = token == operation ? error : CancellationError()
            let issue = SavedLayoutApplyIssue(reason is CancellationError ? .stopped : .other,
                                              reason is CancellationError ? Self.cancelled : Self.failureMessage(reason))
            var result = SavedLayoutApplyResult()
            result.unplaced = document.slots.count - result.placed
            result.issues.append(issue)
            let target = displayID ?? SavedLayoutTarget.resolve(current: currentDisplayID(),
                displays: (try? snapshot())?.displays ?? []) ?? .init(rawValue: "")
            let sessionHeld = !sessionIsAvailable()
            if sessionHeld { silentRun = true }
            publish(result, document: document, displayID: target, automatic: automatic,
                retryChoices: (reason as? SavedLayoutChoiceRefusal)?.retryChoices,
                deferAutomaticFeedback: automatic && sessionHeld)
            return lastRun?.result ?? result
        }
    }

    private func hasFollowedPane(_ document: SavedLayoutDocument) -> Bool {
        func named(_ node: SavedLayoutNode) -> Bool {
            switch node {
            case .slot: true
            case let .group(id): document.groups.contains { $0.id == id && !$0.slots.isEmpty }
            case let .split(_, _, children): children.contains(where: named)
            case .empty: false
            }
        }
        return document.layout.map(named) ?? false
    }

    private func expandedPreferences(_ document: SavedLayoutDocument) -> [String: [String]] {
        Dictionary(uniqueKeysWithValues: document.slots.map { ($0.id, expandedPreferences($0)) })
    }

    private func expandedPreferences(_ slot: SavedLayoutSlot) -> [String] {
        (appGroupsStore?.document ?? .init()).expand(slot.prefer,
            resolvedBundleIDs: appGroupsStore?.resolvedBundleIDs ?? [:]).bundleIDs
    }

    private func applicationName(_ bundleID: String) -> String { application(bundleID)?.name ?? "an app that is not installed" }
    private func windowApplicationName(_ window: WindowSnapshot) -> String {
        window.bundleIdentifier.flatMap { application($0)?.name } ?? runningApplicationName(window.processIdentifier) ?? "An app"
    }

    /// Gather, plan, revalidate, then submit at most one coordinator transaction.
    private func performPlan(_ document: SavedLayoutDocument, on desktop: SavedLayoutDesktop, token: Int,
                             explicitChoices: [String: WindowID], excluding: Set<WindowID>,
                             automatic: Bool, sessionIsAvailable: @escaping @MainActor () -> Bool,
                             validating: @escaping @MainActor () -> Bool) async throws -> SavedLayoutApplyResult {
        let state = try inventory()
        guard current(token, desktop: desktop), let display = state.displays.first(where: { $0.id == desktop.displayID }) else {
            throw SavedLayoutFileError(message: Self.desktopNotReady)
        }
        guard !state.suspendedDisplays.contains(desktop.displayID) else { throw SavedLayoutFileError(message: Self.needsRepair) }
        ownedDisplayID = desktop.displayID
        let prepared = try existingPlan(document, in: state, on: desktop, workArea: display.visibleFrame,
            explicit: explicitChoices, excluding: excluding, automatic: automatic,
            preferredFrames: positionContext.map { $0.store.frames(for: $0.file) } ?? [:], layoutURL: positionContext?.layoutURL,
            requiringExplicitChoices: true)
        let plan = prepared.plan
        lastPlan = plan
        var transaction = state
        transaction.sessionIsAvailable = sessionIsAvailable
        transaction.isAutomatic = automatic
        transaction.requestedTransfers = prepared.transfers
        if document.keepForNewWindows, hasFollowedPane(document), let layoutFileID {
            transaction.followingIntent = .start(layoutFileID: layoutFileID, document: document,
                                                expandedPreferences: expandedPreferences(document))
        } else { transaction.followingIntent = .end }
        let isCurrent = { @MainActor [weak self] in
            guard sessionIsAvailable() else { return false }
            guard validating() else {
                self?.precommitRefusal = .bindingChanged
                return false
            }
            return self?.current(token, desktop: desktop, generation: state.generation) == true
        }
        _ = try validateDestination(token, desktop: desktop, generation: state.generation)
        var result = SavedLayoutApplyResult()
        result.issues = SavedLayoutPlanPresentation.preferenceIssues(document: document,
            groups: appGroupsStore?.document ?? .init(), resolvedBundleIDs: appGroupsStore?.resolvedBundleIDs ?? [:])
        let movingBundles = Set(state.windows.filter { excluding.contains($0.id) }.compactMap(\.bundleIdentifier))
        for slot in document.slots where plan.emptySlots.contains(slot.id) {
            let preferences = expandedPreferences(slot)
            if let bundle = preferences.first(where: { preference in movingBundles.contains { $0.caseInsensitiveCompare(preference) == .orderedSame } }) {
                let name = state.windows.first(where: { $0.bundleIdentifier == bundle }).map(windowApplicationName) ?? applicationName(bundle)
                result.issues.append(.init(.stillMoving, "\(name) was still moving. Try again when it is ready.", slotID: slot.id))
            }
        }
        silentRun = automatic && plan.isEmpty
        if SavedLayoutApplyPolicy.leavesAutomaticLayoutAlone(automatic: automatic, plan: plan) {
            silentRun = true
            return result
        }
        guard await commitProgress(plan, desktop: desktop, state: transaction, isCurrent: isCurrent, result: &result) else { return result }
        rememberedAssignments[desktop] = (document, plan.assignments, positionContext?.layoutURL)
        noteApplied(desktop)
        let windowNames = Dictionary(uniqueKeysWithValues: state.windows.map { ($0.id, windowApplicationName($0)) })
        completedPlanPresentation = SavedLayoutPlanPresentation(document: document, plan: plan, windows: prepared.windows,
            workArea: display.visibleFrame, groups: appGroupsStore?.document ?? .init(),
            resolvedBundleIDs: appGroupsStore?.resolvedBundleIDs ?? [:], name: { [self] in applicationName($0) },
            windowName: { windowNames[$0] ?? "An app" },
            uninstalledBundleIDs: Set(document.slots.flatMap { (appGroupsStore?.document ?? .init()).expand($0.prefer,
                resolvedBundleIDs: appGroupsStore?.resolvedBundleIDs ?? [:]).bundleIDs }.filter { application($0) == nil }),
            movedFrom: prepared.transfers.mapValues { displayName($0.source.displayID, state.displays) })
        completedPlanPresentation?.issues = result.issues
        return result
    }

    /// A repeat keeps the live vacancy IDs and Focus-return memory. Slot policy stays positional.
    private func sameFollowingPolicy(_ current: FollowedLayout?, _ proposed: FollowedLayout?) -> Bool {
        guard let current, let proposed else { return current == nil && proposed == nil }
        guard current.layoutFileID == proposed.layoutFileID, current.layoutName == proposed.layoutName,
              current.shape.mode == proposed.shape.mode, current.shape.topology == proposed.shape.topology,
              current.slots.count == proposed.slots.count else { return false }
        return zip(current.slots, proposed.slots).allSatisfy { old, new in
            old.slotID == new.slotID && old.preferences == new.preferences
                && current.shape.anchors.firstIndex(of: old.anchor) == proposed.shape.anchors.firstIndex(of: new.anchor)
        }
    }

    /// One transaction retains every participant's original frame and the original session.
    private func commitProgress(_ plan: SavedLayoutApplyPlan, desktop: SavedLayoutDesktop,
                                state: SavedLayoutApplySnapshot, isCurrent: @escaping @MainActor () -> Bool,
                                result: inout SavedLayoutApplyResult) async -> Bool {
        let started = uptime()
        defer { record(.commit, since: started) }
        let participantIDs = Set(plan.assignments.values).union(plan.placements.map(\.windowID)).union(plan.extras.compactMap {
            switch $0.value { case .tab, .addedAsPane: $0.key; case .floating, .untouched: nil }
        })
        let participants = state.windows.filter { participantIDs.contains($0.id) }
        let baseline = Dictionary(uniqueKeysWithValues: participants.map { ($0.id, $0.frame) })
        var checkpoint: UUID?
        var didCommit = false
        defer { if let checkpoint { finishUndoCheckpoint(checkpoint, on: desktop.displayID, didCommit: didCommit) } }
        if !plan.placements.isEmpty || plan.needsSessionUpdate == true {
            let previousUndo = undos[desktop.displayID]
            let previousOrder = undoOrder
            let previousCheckpoint = runCheckpoint
            guard let document = lastDocument else { return false }
            let touched = Set(state.requestedTransfers.values.map(\.source)).union([desktop])
            let before = Dictionary(uniqueKeysWithValues: touched.map { ($0, SavedLayoutUndoStructure(state.sessions[$0.displayID] ?? .manual)) })
            var planned = before; planned[desktop] = .init(plan.targetSession)
            let record = UndoRecord(id: UUID(), desktop: desktop, document: document, fileID: layoutFileID,
                layoutURL: lastLayoutURL, frames: baseline, session: state.sessions[desktop.displayID] ?? .manual,
                processes: Dictionary(uniqueKeysWithValues: participants.map { ($0.id, $0.processIdentifier) }),
                transfers: state.requestedTransfers, committedSessions: before, plannedSessions: planned)
            checkpoint = record.id
            undos[desktop.displayID] = record
            undoOrder.removeAll { $0 == desktop.displayID }; undoOrder.append(desktop.displayID)
            noteApplied(desktop)
            runCheckpoint = true
            // isCurrent already checks stability, readiness, generation and Space
            // in one destination snapshot. Do not read it twice for each write.
            guard await commitValidated(plan, desktop, state, isCurrent) else {
                // The model's preflight refusal happens before any write and keeps the older Undo.
                if case let .beforeWrite(reason) = precommitRefusal {
                    undos[desktop.displayID] = previousUndo; undoOrder = previousOrder; runCheckpoint = previousCheckpoint
                    result.issues.append(.init(.other, reason))
                    return false
                }
                let rolledBack = (try? snapshot()).map { after in baseline.allSatisfy { id, frame in
                    after.windows.first(where: { $0.id == id })?.frame.approximatelyEquals(frame, tolerance: 2) == true
                } } ?? false
                if rolledBack {
                    undos[desktop.displayID] = previousUndo; undoOrder = previousOrder; runCheckpoint = previousCheckpoint
                }
                if let reason = precommitRefusal {
                    switch reason {
                    case .mutationChanged, .displayChanged:
                        result.issues.append(.init(.other, reason.message))
                        return false
                    default: break
                    }
                    let detail = rolledBack ? " Nothing was moved." : " Use Undo to restore the previous layout."
                    result.issues.append(.init(.other, reason.message + detail))
                    return false
                }
                let note = rolledBack ? " Nothing was moved."
                    : " Some windows could not be restored. Use Undo or Repair Layout."
                let refusals = Self.refusals(of: plan, in: try? snapshot(), refused: refusedSizes,
                    names: { [self] in windowApplicationName($0) })
                result.issues.append(.init(.couldNotFit, (refusals.isEmpty ? "The layout could not be placed or did not settle." : refusals.joined(separator: " ")) + note))
                return false
            }
        } else {
            // A settled Apply can change following without moving a window or replacing Undo.
            var target = LayoutSession(displayID: desktop.displayID, mode: plan.targetSession.mode)
            switch plan.targetSession {
            case .manual: break
            case let .bento(state): target.bentoState = state
            case let .tabbed(state): target.tabbedState = state
            }
            let following = state.followingIntent.make(plan: plan, session: target)
            if !sameFollowingPolicy(state.followedLayouts[desktop.displayID], following) {
                guard await commitValidated(plan, desktop, state, isCurrent) else {
                    result.issues.append(.init(.other, precommitRefusal?.message ?? "The desktop changed while applying. No windows were moved."))
                    return false
                }
            }
        }
        didCommit = true
        if let followingIssue { result.issues.append(.init(.other, followingIssue)) }
        rememberPositions(plan, on: desktop)
        let moved = Set(plan.assignments.filter { _, id in undos[desktop.displayID]?.transfers[id]?.reusesExistingWindow == true }.keys)
        for slot in plan.assignments.keys { slotStatuses[slot] = moved.contains(slot) ? .moved : .placed }
        result.movedSlots = moved
        result.placedSlots = Set(plan.assignments.keys)
        result.placed = plan.assignments.count
        return true
    }

    private func rememberPositions(_ plan: SavedLayoutApplyPlan, on desktop: SavedLayoutDesktop) {
        guard let context = positionContext, runCheckpoint, let undo = undos[desktop.displayID],
              let latest = try? snapshot(), let area = latest.displays.first(where: { $0.id == desktop.displayID })?.visibleFrame else { return }
        let frames = plan.assignments.reduce(into: [String: NormalizedRect]()) { result, assignment in
            guard let window = latest.windows.first(where: { $0.id == assignment.value && $0.displayID == desktop.displayID }),
                  let frame = try? NormalizedRect(frame: window.frame, in: area).validated() else { return }
            result[assignment.key] = frame
        }
        guard !frames.isEmpty else { return }
        // An older display's Undo must not overwrite a newer run's hints for the same file.
        positionUndos = positionUndos.filter { id, value in
            id == undo.id || value.context.file != context.file || value.context.store.url != context.store.url
        }
        let previous = context.store.frames(for: context.file)
        let slots = Set(lastDocument?.slots.map(\.id) ?? [])
        var history = positionUndos[undo.id] ?? PositionUndo(context: context,
            previous: previous, recorded: previous.filter { slots.contains($0.key) })
        history.recorded.merge(frames) { _, latest in latest }
        context.store.set(history.recorded, for: context.file)
        positionUndos[undo.id] = history
        let live = Set(undos.values.map(\.id))
        positionUndos = positionUndos.filter { live.contains($0.key) }
    }

    /// "Font Book needs 532 pt of height; pane is 484." for each placed window whose minimum, as known
    /// after the failed attempt, exceeds the pane that the layout gave it.
    private static func refusals(of plan: SavedLayoutApplyPlan, in state: SavedLayoutApplySnapshot?,
                                 refused: [WindowID: BTSize], names: (WindowSnapshot) -> String) -> [String] {
        guard let state else { return [] }
        return plan.placements.sorted { $0.windowID < $1.windowID }.flatMap { placement -> [String] in
            guard let window = state.windows.first(where: { $0.id == placement.windowID }) else { return [] }
            let name = names(window)
            // The learned minimum, or the size the window kept when the pane asked for less.
            let kept = refused[window.id] ?? BTSize(width: 0, height: 0)
            let minimum = BTSize(width: max(window.constraints.minimumSize.width, kept.width),
                                 height: max(window.constraints.minimumSize.height, kept.height))
            var found: [String] = []
            if minimum.width > placement.frame.size.width + 0.5 {
                found.append("\(name) needs \(Int(minimum.width.rounded(.up))) pt of width; pane is \(Int(placement.frame.size.width.rounded(.down))).")
            }
            if minimum.height > placement.frame.size.height + 0.5 {
                found.append("\(name) needs \(Int(minimum.height.rounded(.up))) pt of height; pane is \(Int(placement.frame.size.height.rounded(.down))).")
            }
            return found
        }
    }

    private func publish(_ value: SavedLayoutApplyResult, document: SavedLayoutDocument, displayID: DisplayID,
                         automatic: Bool = false, retryChoices: [String: WindowID]? = nil,
                         deferAutomaticFeedback: Bool = false) {
        var result = value
        result.recordSlots(document.slots.map(\.id))
        for (id, outcome) in result.slots {
            switch outcome {
            case .placed: slotStatuses[id] = result.movedSlots.contains(id) ? .moved : .placed
            case let .skipped(issue): slotStatuses[id] = .failed(reason: issue.message)
            }
        }
        for id in completedPlanPresentation?.emptySlots ?? [] { slotStatuses[id] = .empty }
        let repeatPolicy = SavedLayoutApplyPolicy.settledRepeat(layout: document.name, arrangedSummary: completedPlanPresentation?.summary ?? "no windows to arrange")
        lastRun = .init(layoutName: document.name,
            offersUndo: completedPlanPresentation?.alreadyArranged == true ? repeatPolicy.offersUndo : runCheckpoint,
            date: Date(), displayID: displayID, result: result, planPresentation: completedPlanPresentation,
            needsSaveForFollowing: layoutFileID == nil && document.keepForNewWindows, retryChoices: retryChoices)
        lastRunAutomatic = automatic
        deferredAutomaticRuns[displayID] = deferAutomaticFeedback && lastRun?.offersUndo == true ? lastRun : nil
        if silentRun { planRevision &+= 1; message = lastRun?.presentation.message }
        else { publishCurrentRun() }
    }

    /// Refresh every surface from the one result projection, preserving run identity and Undo.
    private func publishCurrentRun() {
        planRevision &+= 1
        guard let run = lastRun else { return }
        message = run.presentation.message
        presentResult(run, automatic: lastRunAutomatic)
    }

    /// Replay only completed, changed runs, without applying again or replacing Last run.
    func presentDeferredAutomaticResults(whileAvailable sessionIsAvailable: () -> Bool) {
        for display in deferredAutomaticRuns.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            guard sessionIsAvailable() else { return }
            guard var run = deferredAutomaticRuns.removeValue(forKey: display) else { continue }
            run.offersUndo = run.offersUndo && canUndo(run)
            presentResult(run, automatic: true)
        }
    }

    func discardDeferredAutomaticResults() { deferredAutomaticRuns.removeAll() }

    private func presentResult(_ run: SavedLayoutRun, automatic: Bool) {
        let presentation = run.presentation
        var detail = presentation.pillDetail
        if !presentation.summary.isEmpty, presentation.title.contains(presentation.summary), detail.hasPrefix(presentation.summary) {
            detail = String(detail.dropFirst(presentation.summary.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        feedback(.init(title: presentation.title, detail: (run.planPresentation?.alreadyArranged == true && !run.needsSaveForFollowing) || detail.isEmpty ? nil : detail,
                       kind: Self.pillKind(presentation.severity), displayID: run.displayID, isApply: true,
                       offersUndo: run.offersUndo, automatic: automatic))
    }

    /// Apply describes recovery in plain words; JSON paths belong in the file editor.
    static func failureMessage(_ error: any Error) -> String {
        if let validation = error as? SavedLayoutValidationError {
            return validation.issues.map(\.message).joined(separator: "\n")
        }
        return error.localizedDescription
    }

    static func pillKind(_ severity: SavedLayoutResultPresentation.Severity) -> ResultPillFeedback.Kind {
        switch severity { case .success: .success; case .warning: .warning; case .failure: .failure }
    }

    /// Undo errors have no Apply slots. They still use the common result policy.
    private func publishError(_ error: any Error) {
        let stopped = error is CancellationError
        let reason = stopped ? Self.cancelled : Self.failureMessage(error)
        let presentation = SavedLayoutApplyResult(issues: [.init(stopped ? .stopped : .other, reason)])
            .presentation(layout: "Saved Layout")
        message = reason
        feedback(.init(title: presentation.title, detail: presentation.pillDetail,
                       kind: Self.pillKind(presentation.severity), displayID: nil, isApply: false))
    }

    func startUndo(displayID: DisplayID? = nil) {
        guard !isRunning else { return }
        task = Task { [weak self] in await self?.undoLastApply(displayID: displayID) }
    }

    /// Undoes the last Apply on `displayID`, or the most recent one when no display is named.
    func undoLastApply(displayID: DisplayID? = nil) async {
        guard !isRunning else { return }
        let key = displayID ?? lastUndoDisplay ?? lastDesktop?.displayID
        guard let key, let undo = undos[key], let token = begin() else { return }
        var restoration = undo.committedSessions
        restoration[undo.desktop] = .init(undo.session)
        undoRestoration = (undo.id, restoration)
        var committedUndoSession = false
        defer {
            // Exact hidden-tab frame verification can fail after our session restore succeeded.
            // Keep the original restore targets available for retry against that restored session.
            if committedUndoSession, var remaining = undos[key], remaining.id == undo.id, !expiredUndoIDs.contains(undo.id),
               let after = try? snapshot() {
                updateUndoDesktops(after.observation, displays: after.displays, sessions: after.sessions)
                for desktop in remaining.committedSessions.keys where after.observation.currentSpace(on: desktop.displayID) == desktop.spaceID {
                    remaining.committedSessions[desktop] = .init(after.sessions[desktop.displayID] ?? .manual)
                }
                undos[key] = remaining
            }
            undoRestoration = nil
            end()
        }
        precommitRefusal = nil
        followingIssue = nil
        do {
            var state = try snapshot()
            updateUndoDesktops(state.observation, displays: state.displays, sessions: state.sessions)
            if let reason = undoRefusal(undo) { throw SavedLayoutFileError(message: reason) }
            state.requestedTransfers = undo.transfers.mapValues(\.reversed)
            state.followingIntent = .end
            guard state.observation.currentSpace(on: undo.desktop.displayID) == undo.desktop.spaceID,
                  let display = state.displays.first(where: { $0.id == undo.desktop.displayID }),
                  current(token, desktop: undo.desktop) else {
                throw SavedLayoutFileError(message: "Go to the desktop of the last Apply before choosing Undo.")
            }
            let desktop = undo.desktop
            let ids = Set(state.windows.filter { window in
                window.displayID == desktop.displayID
                    && (undo.processes[window.id] == nil || undo.processes[window.id] == window.processIdentifier)
                    && state.observation.windowMembership[window.id].map { $0.isEmpty || $0 == [desktop.spaceID] } != false
            }.map(\.id))
            guard Set(undo.frames.keys).isSubset(of: ids) else { throw SavedLayoutFileError(message: "An Undo window is no longer on this desktop. No windows were moved.") }
            ownedDisplayID = desktop.displayID
            let placements = undo.frames.map { Placement(windowID: $0.key, frame: $0.value) }
            let restoredMembers: Set<WindowID>
            switch undo.session {
            case .manual: restoredMembers = []
            case let .bento(layout): restoredMembers = Set(layout.root?.windowIDs ?? []).union(layout.floatingWindowIDs)
            case let .tabbed(layout): restoredMembers = layout.windowIDs.union(layout.floatingWindowIDs)
            }
            let plan = SavedLayoutApplyPlan(assignments: [:], placements: placements,
                extras: Dictionary(uniqueKeysWithValues: ids.subtracting(restoredMembers).map { ($0, .untouched) }),
                targetSession: undo.session, needsSessionUpdate: true)
            guard display.visibleFrame.size.width > 0, await commit(plan, desktop, state, { [weak self] in
                guard let self, self.current(token, desktop: desktop, generation: state.generation) else { return false }
                return self.undoRefusal(undo) == nil
            }) else { throw SavedLayoutFileError(message: undoRefusal(undo) ?? precommitRefusal?.message ?? "Undo could not restore the previous frames.") }
            committedUndoSession = true
            // Hidden Tabbed windows are best effort in the shared transaction. Exact Undo
            // promises every recorded frame, so verify all of them with a fresh inventory.
            let restored = try snapshot()
            let unrestored = undo.frames.keys.sorted().filter { id in
                restored.windows.first(where: { $0.id == id })?.frame.approximatelyEquals(undo.frames[id]!, tolerance: 2) != true
            }
            if !unrestored.isEmpty {
                let names = unrestored.map { id in
                    (restored.windows.first(where: { $0.id == id }) ?? state.windows.first(where: { $0.id == id }))
                        .map(windowApplicationName) ?? "An app"
                }
                throw SavedLayoutFileError(message: names.joined(separator: ", ") + " could not be restored. Try Undo again.")
            }
            if let history = positionUndos.removeValue(forKey: undo.id) {
                history.context.store.restore(history.previous, for: history.context.file, ifCurrent: history.recorded)
            }
            undos[key] = nil
            expiredUndoIDs.remove(undo.id)
            undoOrder.removeAll { $0 == key }
            message = Self.applyUndone
            feedback(.init(title: "Saved Layout undone", detail: Self.applyUndone, kind: .success,
                           displayID: desktop.displayID, isApply: false))
        } catch { publishError(error) }
    }
}


/// Lets AppKit deliver queued keys after synchronous AX writes, before Apply publishes success.
/// Observe the next idle input turn; a busy or stopped run loop must not hold the transaction forever.
@MainActor final class SavedLayoutInputTurn {
    typealias Observe = (@escaping @MainActor () -> Void) -> () -> Void
    private let clock: BetterTileClock
    private let observe: Observe
    private var continuation: CheckedContinuation<Bool, Never>?
    private var removeObserver: (() -> Void)?
    private var deadline: Task<Void, Never>?

    init(clock: BetterTileClock = .live, observe: Observe? = nil) {
        self.clock = clock; self.observe = observe ?? Self.observeNativeTurn
    }

    func wait() async -> Bool {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                removeObserver = observe { self.finish(true) }
                let clock = clock
                deadline = Task { [weak self] in
                    do {
                        try await clock.sleep(for: .seconds(1))
                        self?.finish(false)
                    } catch { /* The input turn completed or the Apply was cancelled. */ }
                }
            }
        } onCancel: {
            Task { @MainActor in self.finish(false) }
        }
    }

    private func finish(_ observed: Bool) {
        guard let pending = continuation else { return }
        continuation = nil
        removeObserver?(); removeObserver = nil
        deadline?.cancel(); deadline = nil
        pending.resume(returning: observed)
    }

    private static func observeNativeTurn(_ ready: @escaping @MainActor () -> Void) -> () -> Void {
        let runLoop = CFRunLoopGetMain()
        guard let observer = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault,
            CFRunLoopActivity.beforeWaiting.rawValue, false, CFIndex.max, { _, _ in
                MainActor.assumeIsolated {
                    // The run loop can become idle inside nextEvent, before NSApplication
                    // dispatches its queued events. Dispatch that queue in order through
                    // the normal local monitors and responders before accepting the turn.
                    // nil does not wait for future input. A saturated queue instead hits
                    // the existing deadline; continuous input cannot hold Apply forever.
                    if Self.serviceQueuedInput() { ready() }
                }
            }) else { return {} }
        CFRunLoopAddObserver(runLoop, observer, .commonModes)
        CFRunLoopWakeUp(runLoop)
        return { CFRunLoopRemoveObserver(runLoop, observer, .commonModes) }
    }

    /// Scheduling the turn and servicing its queue are separate boundaries.
    /// Tests can supply an owned queue without waiting for global run-loop idleness.
    static func serviceQueuedInput(
        nextEvent: () -> NSEvent? = { NSApp.nextEvent(matching: .any, until: nil, inMode: .default, dequeue: true) },
        sendEvent: (NSEvent) -> Void = { NSApp.sendEvent($0) }
    ) -> Bool {
        for _ in 0..<256 {
            guard let event = nextEvent() else { return true }
            sendEvent(event)
        }
        return false
    }
}
