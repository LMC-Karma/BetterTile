import Foundation

/// One already-filtered observation of the active desktop on a display.
/// `session` must be the value returned by `LayoutSessionStore.activate` for
/// the same sweep, so its membership and focus already match `windows`.
public struct AmbientLayoutObservation: Sendable {
    public var display: DisplaySnapshot
    public var windows: [WindowSnapshot]
    public var wasCreated: Bool
    public var previousWindowIDs: Set<WindowID>
    public var isDesktopTransition: Bool
    public var confirmedGone: Set<WindowID>
    public var confirmedMinimized: Set<WindowID>
    /// Windows whose native membership still belongs to this desktop, even
    /// when the current on-screen Accessibility sweep cannot see them.
    public var knownSpaceWindowIDs: Set<WindowID>

    public init(
        display: DisplaySnapshot,
        windows: [WindowSnapshot],
        wasCreated: Bool,
        previousWindowIDs: Set<WindowID>,
        isDesktopTransition: Bool,
        confirmedGone: Set<WindowID> = [],
        confirmedMinimized: Set<WindowID> = [],
        knownSpaceWindowIDs: Set<WindowID> = []
    ) {
        self.display = display
        self.windows = windows
        self.wasCreated = wasCreated
        self.previousWindowIDs = previousWindowIDs
        self.isDesktopTransition = isDesktopTransition
        self.confirmedGone = confirmedGone
        self.confirmedMinimized = confirmedMinimized
        self.knownSpaceWindowIDs = knownSpaceWindowIDs
    }
}

/// The complete pure result of reconciling one display observation.
public enum AmbientLayoutTransition: Sendable {
    /// Commit bookkeeping only; no window frames should be written.
    case observe(session: LayoutSession)
    /// The single-window latch fired in any layout mode.
    case placeSingleWindow(session: LayoutSession, placement: Placement)
    /// Apply the derived Bento placements. A work area requests authoritative
    /// settlement after a successful commit and deliberately remains absent
    /// from `session.lastWorkArea` until that settlement succeeds.
    case applyLayout(session: LayoutSession, placements: [Placement], settleWorkArea: BTRect?)

    public var session: LayoutSession {
        switch self {
        case let .observe(session),
             let .placeSingleWindow(session, _),
             let .applyLayout(session, _, _):
            session
        }
    }
}

/// Pure policy for ambient desktop sweeps. The App remains responsible for
/// compare-and-swap commits, window mutations, recovery, feedback, and retry
/// scheduling.
public struct AmbientLayoutReconciler: Sendable {
    public var paneGap: Double
    public var adjacencyTolerance: Double
    public var singleWindowPlacement: WindowAction?
    public var newWindowSide: BentoNewWindowSide

    public init(
        paneGap: Double,
        adjacencyTolerance: Double,
        singleWindowPlacement: WindowAction?,
        newWindowSide: BentoNewWindowSide = .automatic
    ) {
        self.paneGap = paneGap
        self.adjacencyTolerance = adjacencyTolerance
        self.singleWindowPlacement = singleWindowPlacement
        self.newWindowSide = newWindowSide
    }

    public func transition(
        session original: LayoutSession,
        observation: AmbientLayoutObservation
    ) -> AmbientLayoutTransition {
        var session = original
        let before = session.bentoState
        let frames = Dictionary(uniqueKeysWithValues: observation.windows.map { ($0.id, $0.frame) })
        let workAreaChanged = session.lastWorkArea.map {
            !$0.approximatelyEquals(observation.display.visibleFrame, tolerance: 0.5)
        } ?? false

        var shouldApply = false
        if session.mode == .bento, !session.automaticWritesSuspended {
            if observation.wasCreated {
                shouldApply = initializeBentoSession(
                    &session,
                    windows: observation.windows,
                    frames: frames,
                    display: observation.display,
                    previousWindowIDs: observation.previousWindowIDs
                )
            } else if observation.isDesktopTransition {
                // A known desktop keeps its stored Bento tree and ratios.
            } else if session.isBentoInitialized {
                let transition = BentoSessionReducer().reconcile(
                    session: session,
                    observation: BentoObservation(
                        bounds: observation.display.visibleFrame,
                        windows: observation.windows,
                        focusedWindowID: session.focusedWindowID
                    ),
                    paneGap: paneGap,
                    confirmedGone: observation.confirmedGone,
                    minimized: observation.confirmedMinimized,
                    knownSpaceWindowIDs: observation.knownSpaceWindowIDs,
                    newWindowSide: newWindowSide
                )
                if case let .update(updated, _, _) = transition {
                    session = updated
                }
                shouldApply = workAreaChanged
            } else {
                shouldApply = initializeBentoSession(
                    &session,
                    windows: observation.windows,
                    frames: frames,
                    display: observation.display,
                    previousWindowIDs: observation.previousWindowIDs
                )
            }
        }

        let stateChanged = before != session.bentoState
        if !observation.wasCreated, !observation.isDesktopTransition, stateChanged {
            shouldApply = true
        }

        // A temporarily missing Bento pane still belongs to the layout. Apply
        // the single-window policy only after the reducer confirms removals,
        // otherwise a Space transition maximizes a window and then tiles it again.
        let eligibleWindowCount = session.mode == .bento && observation.windows.count == 1
            ? max(observation.windows.count, session.bentoState.root?.windowIDs.count ?? 0)
            : observation.windows.count
        let becameSingleWindow = session.shouldApplySingleWindowPlacement(
            eligibleWindowCount: eligibleWindowCount
        )
        let singlePlacement: Placement? = if becameSingleWindow,
           !session.automaticWritesSuspended,
           let window = observation.windows.first,
           let singleWindowPlacement,
           let frame = StandardActionEngine().targetFrame(
               for: singleWindowPlacement,
               window: window,
               display: observation.display
           ) {
            Placement(windowID: window.id, frame: frame)
        } else {
            nil
        }
        let settleWorkArea = session.mode == .bento
            && session.isBentoInitialized
            && observation.windows.count > 1
            && shouldApply
            && workAreaChanged
            ? observation.display.visibleFrame
            : nil

        session.lastObservedFrames = frames
        if settleWorkArea == nil {
            session.lastWorkArea = observation.display.visibleFrame
        }

        if let singlePlacement {
            return .placeSingleWindow(session: session, placement: singlePlacement)
        }
        if session.mode == .bento,
           session.isBentoInitialized,
           observation.windows.count > 1,
           shouldApply {
            let placements = BentoLayoutEngine(state: session.bentoState).placements(
                for: observation.windows,
                in: observation.display
            )
            return .applyLayout(
                session: session,
                placements: placements,
                settleWorkArea: settleWorkArea
            )
        }
        return .observe(session: session)
    }

    private func initializeBentoSession(
        _ session: inout LayoutSession,
        windows: [WindowSnapshot],
        frames: [WindowID: BTRect],
        display: DisplaySnapshot,
        previousWindowIDs: Set<WindowID>
    ) -> Bool {
        guard windows.count > 1 else { return false }
        let metrics = BentoLayoutMetrics(paneGap: paneGap)
        // Initialization must return a complete runtime session. Deferring
        // this metadata to the next sweep breaks the fixed point and makes
        // planner-created overflow indistinguishable from a user's float.
        session.bentoInsertionOrder = windows.map(\.id).sorted()
        // A Bento desktop with one window has no tree yet. Preserve that
        // window as the existing pane when the first newcomer arrives.
        if newWindowSide != .automatic, previousWindowIDs.count == 1,
           let existingID = previousWindowIDs.first,
           windows.contains(where: { $0.id == existingID }) {
            session.bentoState = BentoLayoutState(root: .leaf(existingID), metrics: metrics)
            session.isBentoInitialized = true
            let transition = BentoSessionReducer().reconcile(
                session: session,
                observation: BentoObservation(bounds: display.visibleFrame, windows: windows),
                paneGap: paneGap,
                newWindowSide: newWindowSide
            )
            if case let .update(updated, _, _) = transition { session = updated }
            return true
        }
        if let adopted = BentoLayoutAdopter(tolerance: adjacencyTolerance).adopt(
            frames: frames,
            in: display.visibleFrame,
            metrics: metrics
        ) {
            session.bentoState = adopted
            session.automaticallyFloatingWindowIDs = adopted.floatingWindowIDs
            session.isBentoInitialized = true
            return false
        }

        let result = BentoPlanner().plan(
            state: BentoRuntimeState(layout: BentoLayoutState(metrics: metrics)),
            observation: BentoObservation(
                bounds: display.visibleFrame,
                windows: windows,
                focusedWindowID: session.focusedWindowID
            ),
            intent: .activate
        )
        session.bentoState = result.state.layout
        session.automaticallyFloatingWindowIDs = result.state.layout.floatingWindowIDs
        session.bentoReinsertionAnchors = result.state.reinsertionAnchors
        session.isBentoInitialized = true
        return result.writesFrames
    }
}
