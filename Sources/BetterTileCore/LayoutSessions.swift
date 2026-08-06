import Foundation

/// Process-local identity for one desktop layout. macOS does not expose a
/// public stable Space identifier, so this ID is deliberately never persisted.
public struct DesktopSessionID: Hashable, Sendable {
    public var rawValue: UUID

    public init(rawValue: UUID = UUID()) { self.rawValue = rawValue }
}

/// Runtime layout state for the eligible windows currently visible on one display.
/// Window identifiers remain process-local, so these sessions are never persisted.
public struct LayoutSession: Hashable, Sendable {
    public var id: DesktopSessionID
    public var displayID: DisplayID
    public var mode: LayoutMode
    public var bentoState: BentoLayoutState
    public var windowIDs: Set<WindowID>
    public var focusedWindowID: WindowID?
    public var bentoInsertionOrder: [WindowID]
    public var automaticallyFloatingWindowIDs: Set<WindowID>
    public var excludedFocusWindowIDs: Set<WindowID>
    public var bentoReinsertionAnchors: [WindowID: BentoReinsertionAnchor]
    public var lastObservedFrames: [WindowID: BTRect]
    public var lastWorkArea: BTRect?
    public var isBentoInitialized: Bool
    public var hasAppliedSingleWindowPlacement: Bool
    /// Corroborates a window's disappearance before its pane is given up.
    public var presence: WindowPresenceTracker

    public init(
        id: DesktopSessionID = DesktopSessionID(),
        displayID: DisplayID,
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
        presence: WindowPresenceTracker = WindowPresenceTracker()
    ) {
        self.id = id
        self.displayID = displayID
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

    public mutating func recordProposedFrames(_ frames: [WindowID: BTRect]) {
        lastObservedFrames.merge(frames) { _, proposed in proposed }
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

/// Keeps multiple process-local desktop sessions per display while exposing
/// only the active session to window-writing controllers.
public struct LayoutSessionStore: Sendable {
    private var storedSessions: [DisplayID: [DesktopSessionID: LayoutSession]] = [:]
    private var activeSessionIDs: [DisplayID: DesktopSessionID] = [:]

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
        reuseActiveWhenUnmatched: Bool
    ) -> (session: LayoutSession, wasCreated: Bool, previousWindowIDs: Set<WindowID>) {
        let previousActiveID = activeSessionIDs[displayID]
        let candidates = storedSessions[displayID].map { Array($0.values) } ?? []
        let matched = bestMatch(
            candidates: candidates,
            windowIDs: windowIDs,
            focusedWindowID: focusedWindowID,
            preferredID: previousActiveID
        ) ?? (reuseActiveWhenUnmatched ? previousActiveID.flatMap { storedSessions[displayID]?[$0] } : nil)

        var session: LayoutSession
        let wasCreated: Bool
        let previousWindowIDs: Set<WindowID>
        if let matched {
            session = matched
            wasCreated = false
            previousWindowIDs = matched.windowIDs
        } else {
            session = LayoutSession(displayID: displayID, mode: defaultMode)
            wasCreated = true
            previousWindowIDs = []
        }
        if session.excludedFocusWindowIDs.isEmpty {
            session.windowIDs = windowIDs
        } else {
            session.windowIDs.formUnion(windowIDs)
        }
        session.focusedWindowID = focusedWindowID
        storedSessions[displayID, default: [:]][session.id] = session
        activeSessionIDs[displayID] = session.id
        return (session, wasCreated, previousWindowIDs)
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

    public func allSessions(for displayID: DisplayID) -> [LayoutSession] {
        storedSessions[displayID].map { Array($0.values) } ?? []
    }

    public mutating func update(_ displayID: DisplayID, _ update: (inout LayoutSession) -> Void) {
        guard let id = activeSessionIDs[displayID], var session = storedSessions[displayID]?[id] else { return }
        update(&session)
        storedSessions[displayID]?[id] = session
    }

    public mutating func removeMissingDisplays(_ displayIDs: Set<DisplayID>) {
        storedSessions = storedSessions.filter { displayIDs.contains($0.key) }
        activeSessionIDs = activeSessionIDs.filter { displayIDs.contains($0.key) }
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
