import Foundation

/// Process-local identity for one desktop layout. macOS does not expose a
/// public stable Space identifier, so this ID is deliberately never persisted.
public struct DesktopSessionID: Hashable, Sendable {
    public var rawValue: UUID

    public init(rawValue: UUID = UUID()) { self.rawValue = rawValue }
}

/// Result of attempting to make a proposed Bento session authoritative.
/// Only a degraded rollback leaves the display in an unknown state that must
/// stop ambient writes until the user begins a new transaction.
public enum BentoProposalCommitResult: Hashable, Sendable {
    case committed
    case stale
    case rejected
    case degraded

    public var needsRepair: Bool { self == .degraded }
}

/// Runtime layout state for the eligible windows currently visible on one display.
/// Window identifiers remain process-local, so these sessions are never persisted.
public struct LayoutSession: Hashable, Sendable {
    public var id: DesktopSessionID
    /// Monotonically identifies the exact value used to derive a proposal.
    /// Deferred work must commit against this revision, never merely the same
    /// process-local session identity.
    public private(set) var revision: UInt64
    public var displayID: DisplayID
    public var nativeSpaceID: NativeSpaceID?
    public var mode: LayoutMode
    public var followed: FollowedLayout? = nil
    /// Tab membership saved beside the Bento tree. See `tabbedState`.
    private var storedTabbedState: TabbedLayoutState?
    /// Tabbed runs on this session's Bento tree. Reading follows any change a
    /// Bento operation made to `bentoState`; writing also writes the tree.
    public var tabbedState: TabbedLayoutState? {
        get {
            guard var state = storedTabbedState else { return nil }
            if state.layout != bentoState { state.synchronize(with: bentoState) }
            return state
        }
        set {
            storedTabbedState = newValue
            if let newValue { bentoState = newValue.layout }
        }
    }
    public var tabbedHasEntryBaseline = false
    public var tabbedBaselineFrames: [WindowID: BTRect] = [:]
    public var bentoState: BentoLayoutState
    /// A Saved Layout keeps its gap until an explicit gap change or Repair Layout.
    public var savedLayoutPaneGap: Double? = nil
    public func paneGap(configured: Double) -> Double { savedLayoutPaneGap ?? configured }
    public var windowIDs: Set<WindowID>
    public var focusedWindowID: WindowID?
    public var bentoInsertionOrder: [WindowID]
    public var automaticallyFloatingWindowIDs: Set<WindowID>
    public var excludedFocusWindowIDs: Set<WindowID>
    public var bentoReinsertionAnchors: [WindowID: BentoReinsertionAnchor]
    public var lastObservedFrames: [WindowID: BTRect]
    /// The work area the layout was last confirmed for.
    public var lastWorkArea: BTRect? {
        didSet {
            pendingWorkArea = nil
            if lastWorkArea != nil { needsDisplayRestorationLayout = false }
        }
    }
    /// A restored desktop must fit its remembered tree to the new screen once.
    public var needsDisplayRestorationLayout = false
    /// The work area of a layout written but not yet confirmed. The windows
    /// already moved for it, so changing back to `lastWorkArea` is a change.
    public var pendingWorkArea: BTRect?
    public var isBentoInitialized: Bool
    public var hasAppliedSingleWindowPlacement: Bool
    /// Corroborates a window's disappearance before its pane is given up.
    public var presence: WindowPresenceTracker
    /// A failed bounded recovery stops ambient writes for this display until
    /// the user starts a new Bento transaction.
    public var automaticWritesSuspended: Bool

    public init(
        id: DesktopSessionID = DesktopSessionID(),
        revision: UInt64 = 0,
        displayID: DisplayID,
        nativeSpaceID: NativeSpaceID? = nil,
        mode: LayoutMode,
        bentoState: BentoLayoutState = BentoLayoutState(),
        windowIDs: Set<WindowID> = [],
        focusedWindowID: WindowID? = nil,
        bentoInsertionOrder: [WindowID] = [],
        automaticallyFloatingWindowIDs: Set<WindowID> = [],
        excludedFocusWindowIDs: Set<WindowID> = [],
        bentoReinsertionAnchors: [WindowID: BentoReinsertionAnchor] = [:],
        lastObservedFrames: [WindowID: BTRect] = [:],
        lastWorkArea: BTRect? = nil,
        isBentoInitialized: Bool = false,
        hasAppliedSingleWindowPlacement: Bool = false,
        presence: WindowPresenceTracker = WindowPresenceTracker(),
        automaticWritesSuspended: Bool = false
    ) {
        self.id = id
        self.revision = revision
        self.displayID = displayID
        self.nativeSpaceID = nativeSpaceID
        self.mode = mode
        self.bentoState = bentoState
        self.windowIDs = windowIDs
        self.focusedWindowID = focusedWindowID
        self.bentoInsertionOrder = bentoInsertionOrder
        self.automaticallyFloatingWindowIDs = automaticallyFloatingWindowIDs
        self.excludedFocusWindowIDs = excludedFocusWindowIDs
        self.bentoReinsertionAnchors = bentoReinsertionAnchors
        self.lastObservedFrames = lastObservedFrames
        self.lastWorkArea = lastWorkArea
        self.isBentoInitialized = isBentoInitialized || bentoState.root != nil
        self.hasAppliedSingleWindowPlacement = hasAppliedSingleWindowPlacement
        self.presence = presence
        self.automaticWritesSuspended = automaticWritesSuspended
    }

    /// Makes explicitly visible windows eligible for the next Bento
    /// reconciliation. Used when a focus-minimized window is restored and
    /// when the user explicitly requests tiling for the current display.
    public mutating func reincludeInBento(_ windowIDs: Set<WindowID>) {
        excludedFocusWindowIDs.subtract(windowIDs)
        automaticallyFloatingWindowIDs.formUnion(windowIDs)
        for windowID in windowIDs {
            bentoState.setFloating(false, windowID: windowID)
        }
    }

    /// Repair is the explicit escape hatch for a stuck desktop. It starts from
    /// visible membership instead of carrying exclusions and reinsertion
    /// guesses forward into the canonical planner.
    public mutating func prepareForRepair() {
        endFollowing()
        savedLayoutPaneGap = nil
        resumeAutomaticWrites()
        excludedFocusWindowIDs.removeAll()
        automaticallyFloatingWindowIDs.removeAll()
        bentoReinsertionAnchors.removeAll()
        bentoState.floatingWindowIDs.removeAll()
        presence = WindowPresenceTracker()
    }

    /// A user change to the Bento tree, such as a drop, a swap, a partition,
    /// or a divider move, makes every tree remembered at an earlier minimize
    /// out of date. Restoring from one would undo the change. Each minimized
    /// window keeps its neighbour and edge, so it still returns beside them.
    public mutating func forgetRememberedBentoLayouts() {
        for windowID in bentoReinsertionAnchors.keys {
            bentoReinsertionAnchors[windowID]?.layoutBefore = nil
        }
    }

    /// A user-owned transaction clears this display's recovery stop.
    public mutating func resumeAutomaticWrites() {
        automaticWritesSuspended = false
    }

    /// Captures the observed truth for this display and stops ambient writes
    /// after the one bounded recovery transaction has degraded.
    public mutating func suspendAutomaticWrites(observing windows: [WindowSnapshot]) {
        automaticWritesSuspended = true
        lastObservedFrames = Dictionary(uniqueKeysWithValues: windows.compactMap { window in
            window.displayID == displayID ? (window.id, window.frame) : nil
        })
    }

    public mutating func endFollowing() {
        followed = nil
    }

    /// All store writes that can change structure pass through this check.
    public mutating func reconcileFollowing() {
        followed = followed?.reconciled(with: self)
    }

    mutating func advanceRevision() {
        reconcileFollowing()
        revision &+= 1
    }

    public mutating func recordProposedFrames(_ frames: [WindowID: BTRect]) {
        lastObservedFrames.merge(frames) { _, proposed in proposed }
    }

    public func driftedManagedWindowIDs(
        in windows: [WindowSnapshot],
        tolerance: Double = 1
    ) -> Set<WindowID> {
        guard mode == .bento else { return [] }
        let managedWindowIDs = Set(bentoState.root?.windowIDs ?? [])
        let windowsByID = Dictionary(uniqueKeysWithValues: windows.map { ($0.id, $0) })
        return Set(lastObservedFrames.compactMap { windowID, expectedFrame in
            guard managedWindowIDs.contains(windowID),
                  let actualFrame = windowsByID[windowID]?.frame,
                  !actualFrame.approximatelyEquals(expectedFrame, tolerance: tolerance)
            else { return nil }
            return windowID
        })
    }

    /// True exactly once each time this desktop's eligible window count becomes
    /// one, so a desktop that drops back to a single window is placed again.
    ///
    /// Between those moments it stays false, which is what makes the configured
    /// placement a starting point rather than a rule: once the lone window has
    /// been placed, resizing it by hand sticks until another window arrives or
    /// the user asks for a repair.
    public mutating func shouldApplySingleWindowPlacement(eligibleWindowCount: Int) -> Bool {
        guard eligibleWindowCount == 1 else {
            hasAppliedSingleWindowPlacement = false
            return false
        }
        guard !hasAppliedSingleWindowPlacement else { return false }
        hasAppliedSingleWindowPlacement = true
        return true
    }
}

/// Accepts an active-desktop observation only after the same visible
/// membership is sampled twice. This filters the transient mixed window list
/// macOS can expose while switching Spaces.
public struct DesktopObservationStabilizer: Sendable {
    private var previous: [DisplayID: Set<WindowID>]?

    public init() {}

    public mutating func observe(_ windowIDsByDisplay: [DisplayID: Set<WindowID>]) -> Bool {
        defer { previous = windowIDsByDisplay }
        return previous == windowIDsByDisplay
    }
}

/// A removed desktop kept only for the lifetime of this process. No window or
/// native desktop identity in this value is encoded or written to disk.
public struct RetiredDesktop: Sendable {
    public var session: LayoutSession
    public var displayIdentifier: String?
    public var windowIDs: Set<WindowID>
    /// Elapsed monotonic seconds from the application clock.
    public var retiredAt: TimeInterval
}

/// Keeps multiple process-local desktop sessions per display while exposing
/// only the active session to window-writing controllers.
public struct LayoutSessionStore: Sendable {
    private var storedSessions: [DisplayID: [DesktopSessionID: LayoutSession]] = [:]
    private var activeSessionIDs: [DisplayID: DesktopSessionID] = [:]
    private var awaitingFirstObservation: Set<DesktopSessionID> = []
    private var restorationPending: Set<DesktopSessionID> = []
    private var restoredSessionsAwaitingNativeIdentity: Set<DesktopSessionID> = []
    private var displayIdentifiers: [DisplayID: String] = [:]
    /// Windows a restored desktop showed only because macOS merged another,
    /// still retired desktop onto it. While that desktop is remembered, they
    /// are not this desktop's evidence for matching or for pruning copies,
    /// also after this desktop is retired again. Process-local only.
    private var mergedWindowIDs: [DesktopSessionID: Set<WindowID>] = [:]
    public private(set) var retiredSessions: [RetiredDesktop] = []
    public struct Restoration: Sendable {
        public var overlap: Int
        public var observedCount: Int
        public var sameDisplay: Bool
        public var windowIDs: Set<WindowID>
        public var previousDisplayID: DisplayID
        public var previousSpaceID: NativeSpaceID?
    }
    public private(set) var lastRestoration: Restoration?

    /// Remember UUIDs before removing absent displays; keep only identifiers
    /// that still have a live session or occur in this observation.
    public mutating func observeDisplays(_ displays: [DisplaySnapshot]) {
        for display in displays {
            if let identifier = display.persistentIdentifier { displayIdentifiers[display.id] = identifier }
        }
        let retained = Set(displays.map(\.id)).union(storedSessions.keys)
        displayIdentifiers = displayIdentifiers.filter { retained.contains($0.key) }
    }

    public init() {}

    /// Active sessions only. Inactive desktops are intentionally unavailable
    /// to normal reconciliation and frame-writing paths.
    public var sessions: [DisplayID: LayoutSession] {
        Dictionary(uniqueKeysWithValues: activeSessionIDs.compactMap { displayID, sessionID in
            storedSessions[displayID]?[sessionID].map { (displayID, $0) }
        })
    }

    @discardableResult
    public mutating func refresh(
        displayID: DisplayID,
        windowIDs: Set<WindowID>,
        focusedWindowID: WindowID?,
        defaultMode: LayoutMode
    ) -> LayoutSession {
        activate(
            displayID: displayID,
            windowIDs: windowIDs,
            focusedWindowID: focusedWindowID,
            defaultMode: defaultMode,
            reuseActiveWhenUnmatched: true
        ).session
    }

    @discardableResult
    public mutating func activate(
        displayID: DisplayID,
        windowIDs: Set<WindowID>,
        focusedWindowID: WindowID?,
        defaultMode: LayoutMode,
        reuseActiveWhenUnmatched: Bool,
        commitObservation: Bool = true,
        nativeSpaceID: NativeSpaceID? = nil,
        displayIdentifier: String? = nil,
        carryOver: Bool = true
    ) -> (session: LayoutSession, wasCreated: Bool, previousWindowIDs: Set<WindowID>) {
        lastRestoration = nil
        if let displayIdentifier { displayIdentifiers[displayID] = displayIdentifier }
        let previousActiveID = activeSessionIDs[displayID]
        let candidates = storedSessions[displayID].map { Array($0.values) } ?? []
        let matched: LayoutSession?
        if let nativeSpaceID {
            matched = candidates.first { $0.nativeSpaceID == nativeSpaceID }
        } else {
            matched = bestMatch(
                candidates: candidates,
                windowIDs: windowIDs,
                focusedWindowID: focusedWindowID,
                preferredID: previousActiveID
            ) ?? (reuseActiveWhenUnmatched
                ? previousActiveID.flatMap { storedSessions[displayID]?[$0] }
                : nil)
        }

        let firstObservation = matched.map { awaitingFirstObservation.remove($0.id) != nil } ?? true
        let restorationOpportunity = firstObservation
            || (matched.map { restorationPending.contains($0.id) } ?? false)
        // Native metadata may arrive after the display has settled. Adopt only
        // a session restored during that gap, with the same membership evidence.
        let inferredRestoration = restorationOpportunity && nativeSpaceID != nil && !windowIDs.isEmpty
            ? candidates.filter {
                $0.nativeSpaceID == nil && restoredSessionsAwaitingNativeIdentity.contains($0.id)
                    && $0.windowIDs.intersection(windowIDs).count * 2 >= windowIDs.count
            }.max { lhs, rhs in
                let left = lhs.windowIDs.intersection(windowIDs).count
                let right = rhs.windowIDs.intersection(windowIDs).count
                if left != right { return left < right }
                return lhs.id.rawValue.uuidString < rhs.id.rawValue.uuidString
            } : nil
        let restored = restorationOpportunity
            ? inferredRestoration ?? restoreRetired(
                on: displayID, identifier: displayIdentifier ?? displayIdentifiers[displayID],
                windowIDs: windowIDs, carryOver: carryOver) : nil
        var session: LayoutSession
        let wasCreated: Bool
        let previousWindowIDs: Set<WindowID>
        if var restored {
            if let matched {
                storedSessions[displayID]?.removeValue(forKey: matched.id)
                restorationPending.remove(matched.id)
            }
            restored.nativeSpaceID = nativeSpaceID
            if nativeSpaceID == nil {
                restoredSessionsAwaitingNativeIdentity.insert(restored.id)
            } else {
                restoredSessionsAwaitingNativeIdentity.remove(restored.id)
            }
            restored.advanceRevision()
            session = restored
            wasCreated = false
            previousWindowIDs = restored.windowIDs
            storedSessions[displayID, default: [:]][session.id] = session
        } else if let matched {
            session = matched
            wasCreated = firstObservation
            previousWindowIDs = matched.windowIDs
        } else {
            session = LayoutSession(displayID: displayID, nativeSpaceID: nativeSpaceID, mode: defaultMode)
            wasCreated = true
            previousWindowIDs = []
        }
        if session.excludedFocusWindowIDs.isEmpty {
            session.windowIDs = windowIDs
        } else {
            session.windowIDs.formUnion(windowIDs)
        }
        session.focusedWindowID = focusedWindowID
        if wasCreated {
            // Establish a compare-and-swap base for callers that want to plan
            // the activation atomically with a frame transaction. A brand-new
            // desktop has no older state to preserve, so its observed
            // membership is the truthful base if the proposal is rejected.
            storedSessions[displayID, default: [:]][session.id] = session
        } else if commitObservation, session != matched {
            session.advanceRevision()
            storedSessions[displayID, default: [:]][session.id] = session
        }
        activeSessionIDs[displayID] = session.id
        if restorationOpportunity, windowIDs.isEmpty {
            // Keep the restoration chance without marking later arrivals as
            // a new desktop; those arrivals still need minimum-size probes.
            restorationPending.insert(session.id)
        } else {
            restorationPending.remove(session.id)
        }
        return (session, wasCreated, previousWindowIDs)
    }

    /// Selects a native Space before its window membership settles. This makes
    /// reads use the exact stored session immediately without permitting an
    /// automatic frame write.
    @discardableResult
    public mutating func select(
        displayID: DisplayID,
        nativeSpaceID: NativeSpaceID,
        defaultMode: LayoutMode
    ) -> LayoutSession {
        if let existing = storedSessions[displayID]?.values.first(where: {
            $0.nativeSpaceID == nativeSpaceID
        }) {
            activeSessionIDs[displayID] = existing.id
            return existing
        }
        let session = LayoutSession(
            displayID: displayID,
            nativeSpaceID: nativeSpaceID,
            mode: defaultMode
        )
        storedSessions[displayID, default: [:]][session.id] = session
        activeSessionIDs[displayID] = session.id
        awaitingFirstObservation.insert(session.id)
        return session
    }

    @discardableResult
    public mutating func ensure(displayID: DisplayID, defaultMode: LayoutMode) -> LayoutSession {
        if let session = session(for: displayID) { return session }
        let session = LayoutSession(displayID: displayID, mode: defaultMode)
        storedSessions[displayID, default: [:]][session.id] = session
        activeSessionIDs[displayID] = session.id
        return session
    }

    public func session(for displayID: DisplayID) -> LayoutSession? {
        guard let id = activeSessionIDs[displayID] else { return nil }
        return storedSessions[displayID]?[id]
    }

    public func isActive(_ sessionID: DesktopSessionID, on displayID: DisplayID) -> Bool {
        activeSessionIDs[displayID] == sessionID
    }

    public func isCurrent(
        _ sessionID: DesktopSessionID,
        revision: UInt64,
        on displayID: DisplayID
    ) -> Bool {
        guard activeSessionIDs[displayID] == sessionID else { return false }
        return storedSessions[displayID]?[sessionID]?.revision == revision
    }

    public func allSessions(for displayID: DisplayID) -> [LayoutSession] {
        storedSessions[displayID].map { Array($0.values) } ?? []
    }

    /// Metadata ownership includes dormant and retired desktops. This does not
    /// authorize a window write; those still require the active desktop.
    public func retainedSession(_ id: DesktopSessionID) -> LayoutSession? {
        for sessions in storedSessions.values {
            if let session = sessions[id] { return session }
        }
        return retiredSessions.first { $0.session.id == id }?.session
    }

    /// A cancelled transaction can finish bookkeeping after its display retires.
    /// It may change only the exact retired revision it originally owned.
    @discardableResult
    public mutating func commitRetiredBookkeeping(_ proposed: LayoutSession, replacing revision: UInt64) -> LayoutSession? {
        guard proposed.revision == revision,
              let index = retiredSessions.firstIndex(where: {
                  $0.session.id == proposed.id && $0.session.displayID == proposed.displayID && $0.session.revision == revision
              }) else { return nil }
        if proposed == retiredSessions[index].session { return proposed }
        var committed = proposed
        committed.advanceRevision()
        retiredSessions[index].session = committed
        return committed
    }

    /// Even choosing the existing default mode is an explicit user decision.
    public mutating func endRestorationOpportunity(on displayID: DisplayID) {
        if let id = activeSessionIDs[displayID] {
            awaitingFirstObservation.remove(id)
            restorationPending.remove(id)
        }
    }

    /// Incomplete rollback belongs to its original session, even after selection changes.
    public mutating func suspendAutomaticWrites(sessionID: DesktopSessionID, on displayID: DisplayID) {
        // A restoration may already have moved the same runtime owner to a
        // new display number. A real failure must still reach that owner.
        for display in storedSessions.keys.sorted() {
            guard var session = storedSessions[display]?[sessionID], !session.automaticWritesSuspended else { continue }
            session.automaticWritesSuspended = true
            session.advanceRevision()
            storedSessions[display]?[sessionID] = session
        }
        for index in retiredSessions.indices where retiredSessions[index].session.id == sessionID {
            guard !retiredSessions[index].session.automaticWritesSuspended else { continue }
            retiredSessions[index].session.automaticWritesSuspended = true
            retiredSessions[index].session.advanceRevision()
        }
    }

    public mutating func update(_ displayID: DisplayID, _ update: (inout LayoutSession) -> Void) {
        guard let id = activeSessionIDs[displayID], var session = storedSessions[displayID]?[id] else { return }
        let original = session
        update(&session)
        guard session != original else { return }
        if session.mode != original.mode || !session.windowIDs.isEmpty {
            awaitingFirstObservation.remove(id)
            restorationPending.remove(id)
        }
        session.advanceRevision()
        storedSessions[displayID]?[id] = session
    }

    /// Replaces the entire active session only when it was derived from the
    /// exact current revision. A stale proposal is discarded wholesale.
    @discardableResult
    public mutating func commit(
        _ proposed: LayoutSession,
        replacing expectedRevision: UInt64
    ) -> LayoutSession? {
        guard proposed.revision == expectedRevision,
              isCurrent(proposed.id, revision: expectedRevision, on: proposed.displayID)
        else { return nil }
        guard let current = storedSessions[proposed.displayID]?[proposed.id] else { return nil }
        if proposed == current { return current }
        if proposed.mode != current.mode || !proposed.windowIDs.isEmpty {
            awaitingFirstObservation.remove(proposed.id)
            restorationPending.remove(proposed.id)
        }
        var committed = proposed
        committed.advanceRevision()
        storedSessions[proposed.displayID]?[proposed.id] = committed
        return committed
    }

    /// Closure evidence updates retained Tabbed sessions without moving any
    /// inactive desktop's windows. Incomplete sweeps never use this operation.
    public mutating func removeClosedTabbedWindow(_ windowID: WindowID) {
        removeUnavailableTabbedWindow(windowID, closed: true)
    }

    /// Minimization removes a tab even while its desktop is inactive. Keep its
    /// entry frame so leaving Tabbed can still restore it after a later restore.
    public mutating func removeMinimizedTabbedWindow(_ windowID: WindowID) {
        removeUnavailableTabbedWindow(windowID, closed: false)
    }

    private mutating func removeUnavailableTabbedWindow(_ windowID: WindowID, closed: Bool) {
        func update(_ session: inout LayoutSession) {
            guard let state = session.tabbedState,
                  state.windowIDs.contains(windowID) || state.floatingWindowIDs.contains(windowID)
                    || (closed && session.tabbedBaselineFrames[windowID] != nil) else { return }
            session.tabbedState?.removeClosedWindow(windowID)
            if !closed { session.endFollowing() }
            if closed { session.tabbedBaselineFrames.removeValue(forKey: windowID) }
            session.windowIDs.remove(windowID)
            session.advanceRevision()
        }
        for displayID in Array(storedSessions.keys) {
            for id in Array(storedSessions[displayID]?.keys ?? Dictionary<DesktopSessionID, LayoutSession>().keys) {
                guard var session = storedSessions[displayID]?[id] else { continue }
                update(&session)
                storedSessions[displayID]?[id] = session
            }
        }
        if closed {
            for id in Array(mergedWindowIDs.keys) { mergedWindowIDs[id]?.remove(windowID) }
        }
        for index in retiredSessions.indices {
            let previous = retiredSessions[index].session
            update(&retiredSessions[index].session)
            if closed {
                retiredSessions[index].windowIDs.remove(windowID)
                if retiredSessions[index].session.tabbedState == nil {
                    retiredSessions[index].session.windowIDs.remove(windowID)
                    retiredSessions[index].session.bentoState.remove(windowID)
                }
                retiredSessions[index].session.bentoReinsertionAnchors.removeValue(forKey: windowID)
                retiredSessions[index].session.excludedFocusWindowIDs.remove(windowID)
                retiredSessions[index].session.bentoInsertionOrder.removeAll { $0 == windowID }
                if retiredSessions[index].session != previous, retiredSessions[index].session.revision == previous.revision {
                    retiredSessions[index].session.advanceRevision()
                }
            }
        }
        retiredSessions.removeAll { $0.windowIDs.isEmpty }
    }

    public mutating func removeMissingDisplays(_ displayIDs: Set<DisplayID>, at time: TimeInterval = 0) {
        for displayID in storedSessions.keys.sorted() where !displayIDs.contains(displayID) {
            for session in allSessions(for: displayID).sorted(by: { $0.id.rawValue.uuidString < $1.id.rawValue.uuidString }) { retire(session, at: time) }
            storedSessions.removeValue(forKey: displayID)
            displayIdentifiers.removeValue(forKey: displayID)
        }
        activeSessionIDs = activeSessionIDs.filter { displayIDs.contains($0.key) }
        removeOrphanedObservationMarkers()
    }

    /// Retires exact sessions only after a valid native observation confirms
    /// that their Spaces no longer exist. Inferred sessions remain available
    /// for the public-API fallback.
    public mutating func removeMissingNativeSpaces(
        _ knownSpacesByDisplay: [DisplayID: Set<NativeSpaceID>], at time: TimeInterval = 0
    ) {
        for displayID in knownSpacesByDisplay.keys.sorted() {
            let knownSpaceIDs = knownSpacesByDisplay[displayID] ?? []
            guard var sessions = storedSessions[displayID] else { continue }
            for id in sessions.keys.sorted(by: { $0.rawValue.uuidString < $1.rawValue.uuidString }) {
                guard let session = sessions[id], session.nativeSpaceID.map({ !knownSpaceIDs.contains($0) }) == true else { continue }
                retire(session, at: time)
                sessions.removeValue(forKey: id)
            }
            storedSessions[displayID] = sessions
            if let activeID = activeSessionIDs[displayID], sessions[activeID] == nil {
                activeSessionIDs.removeValue(forKey: displayID)
            }
        }
        removeOrphanedObservationMarkers()
    }

    private mutating func retire(_ session: LayoutSession, at time: TimeInterval) {
        let windows = session.windowIDs.union(session.bentoState.root?.windowIDs ?? [])
            .union(session.bentoState.floatingWindowIDs)
            .union(session.tabbedState?.windowIDs ?? [])
            .union(session.tabbedState?.floatingWindowIDs ?? [])
        guard !windows.isEmpty else { return }
        retiredSessions.append(RetiredDesktop(session: session,
            displayIdentifier: displayIdentifiers[session.displayID], windowIDs: windows, retiredAt: time))
        if retiredSessions.count > 32 { retiredSessions.removeFirst(retiredSessions.count - 32) }
    }

    /// Match only desktops with evidence: at least half of the destination's
    /// windows must belong to the retired desktop. A missing UUID is never a
    /// same-screen match. Equal overlaps prefer the most fully covered desktop.
    /// Carry-over prefers its newest copy; UUID then resolves an equal-time tie.
    public mutating func restoreRetired(on displayID: DisplayID, identifier: String?,
                                       windowIDs: Set<WindowID>, carryOver: Bool) -> LayoutSession? {
        lastRestoration = nil
        guard !windowIDs.isEmpty else { return nil }
        // Windows a desktop showed only through a merge are not its evidence
        // while the desktop they came from is still remembered.
        func evidence(_ retired: RetiredDesktop) -> Set<WindowID> {
            guard let merged = mergedWindowIDs[retired.session.id], !merged.isEmpty else { return retired.windowIDs }
            let owned = retiredSessions.reduce(into: Set<WindowID>()) {
                if $1.session.id != retired.session.id { $0.formUnion($1.windowIDs) }
            }
            return retired.windowIDs.subtracting(merged.intersection(owned))
        }
        let matches = retiredSessions.enumerated().compactMap { index, retired ->
            (index: Int, overlap: Int, coverage: Double, same: Bool, time: TimeInterval, id: String, evidence: Set<WindowID>)? in
            let same = identifier != nil && identifier == retired.displayIdentifier
            let own = evidence(retired)
            let overlap = windowIDs.intersection(own).count
            guard (carryOver || same), !own.isEmpty, overlap * 2 >= windowIDs.count else { return nil }
            return (index, overlap, Double(overlap) / Double(own.count), same,
                    retired.retiredAt, retired.session.id.rawValue.uuidString, own)
        }
        guard let match = matches.max(by: { lhs, rhs in
            if lhs.overlap != rhs.overlap { return lhs.overlap < rhs.overlap }
            if lhs.coverage != rhs.coverage { return lhs.coverage < rhs.coverage }
            if carryOver, lhs.time != rhs.time { return lhs.time < rhs.time }
            if lhs.same != rhs.same { return !lhs.same }
            if lhs.time != rhs.time { return lhs.time < rhs.time }
            return lhs.id > rhs.id
        }) else { return nil }
        let restored = retiredSessions.remove(at: match.index)
        // A superseded copy holds only windows that this desktop remembers
        // and still shows. The restored snapshot may hold windows that moved
        // away, and the current desktop may hold windows merged from another
        // desktop; neither alone proves a copy. Off keeps the other screen's
        // independent memory for its next return. Windows this desktop
        // learned from an earlier merge do not prove a copy either.
        let merged = mergedWindowIDs[restored.session.id, default: []]
        let copiedWindowIDs = match.evidence.intersection(windowIDs)
        retiredSessions.removeAll {
            $0.windowIDs.isSubset(of: copiedWindowIDs)
                && (carryOver || (identifier != nil && $0.displayIdentifier == identifier))
        }
        // Visible windows that a kept retired desktop owns and this desktop
        // never remembered arrived through a merge. With carry-over off, the
        // other screen's copy is kept on purpose; its windows are not merged.
        let mergedNow = retiredSessions
            .filter { carryOver || (identifier != nil && $0.displayIdentifier == identifier) }
            .reduce(into: Set<WindowID>()) { $0.formUnion($1.windowIDs) }
            .intersection(windowIDs).subtracting(restored.windowIDs)
        if !merged.union(mergedNow).isEmpty { mergedWindowIDs[restored.session.id] = merged.union(mergedNow) }
        var session = restored.session
        session.displayID = displayID
        session.nativeSpaceID = nil
        session.lastWorkArea = nil
        session.needsDisplayRestorationLayout = true
        session.lastObservedFrames = [:]
        session.endFollowing()
        session.tabbedBaselineFrames = [:]
        // This is a continuation of Tabbed, not a fresh entry. Do not capture
        // macOS's temporary relocated frames as a new Manual-mode baseline.
        if session.mode == .tabbed { session.tabbedHasEntryBaseline = true }
        lastRestoration = Restoration(overlap: match.overlap, observedCount: windowIDs.count, sameDisplay: match.same,
            windowIDs: restored.windowIDs, previousDisplayID: restored.session.displayID,
            previousSpaceID: restored.session.nativeSpaceID)
        return session
    }

    private mutating func removeOrphanedObservationMarkers() {
        let retainedSessionIDs = storedSessions.values.reduce(into: Set<DesktopSessionID>()) {
            $0.formUnion($1.keys)
        }
        awaitingFirstObservation.formIntersection(retainedSessionIDs)
        restorationPending.formIntersection(retainedSessionIDs)
        let rememberedSessionIDs = retainedSessionIDs.union(retiredSessions.map(\.session.id))
        mergedWindowIDs = mergedWindowIDs.filter { rememberedSessionIDs.contains($0.key) }
        restoredSessionsAwaitingNativeIdentity.formIntersection(retainedSessionIDs)
    }

    private func bestMatch(
        candidates: [LayoutSession],
        windowIDs: Set<WindowID>,
        focusedWindowID: WindowID?,
        preferredID: DesktopSessionID?
    ) -> LayoutSession? {
        let ordered = candidates.sorted { lhs, rhs in
            if lhs.id == preferredID { return true }
            if rhs.id == preferredID { return false }
            return lhs.id.rawValue.uuidString < rhs.id.rawValue.uuidString
        }
        if let exact = ordered.first(where: { $0.windowIDs == windowIDs }) { return exact }
        if let focusedWindowID,
           let focused = ordered
            .filter({ $0.windowIDs.contains(focusedWindowID) })
            .max(by: { overlapScore($0.windowIDs, windowIDs) < overlapScore($1.windowIDs, windowIDs) }) {
            return focused
        }
        return ordered
            .map { ($0, overlapScore($0.windowIDs, windowIDs)) }
            .filter { $0.1 >= 0.5 }
            .max { lhs, rhs in lhs.1 < rhs.1 }?.0
    }

    private func overlapScore(_ lhs: Set<WindowID>, _ rhs: Set<WindowID>) -> Double {
        let union = lhs.union(rhs).count
        guard union > 0 else { return 1 }
        return Double(lhs.intersection(rhs).count) / Double(union)
    }
}
