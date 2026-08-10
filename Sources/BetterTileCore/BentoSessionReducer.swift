import Foundation

public struct BentoSessionTransition: Sendable {
    public var session: LayoutSession
    public var placements: [Placement]
    public var removedWindowIDs: Set<WindowID>

    public init(
        session: LayoutSession,
        placements: [Placement],
        removedWindowIDs: Set<WindowID> = []
    ) {
        self.session = session
        self.placements = placements
        self.removedWindowIDs = removedWindowIDs
    }
}

/// Pure membership transition for a live Bento desktop. This is the one place
/// that corroborates removals, orders additions, applies the pane cap, and asks
/// `BentoPlanner` to insert or restore panes.
public struct BentoSessionReducer: Sendable {
    public var maximumManagedWindows: Int

    public init(maximumManagedWindows: Int = 6) {
        self.maximumManagedWindows = max(1, maximumManagedWindows)
    }

    public func reconcile(
        session: LayoutSession,
        observation: BentoObservation,
        paneGap: Double,
        confirmedGone: Set<WindowID> = [],
        minimized: Set<WindowID> = []
    ) -> BentoSessionTransition {
        var next = session
        var runtime = BentoRuntimeState(
            layout: next.bentoState,
            reinsertionAnchors: next.bentoReinsertionAnchors
        )
        runtime.layout.metrics = BentoLayoutMetrics(paneGap: paneGap)
        let present = observation.eligibleWindowIDs
        let known = Set(runtime.layout.root?.windowIDs ?? []).union(runtime.layout.floatingWindowIDs)
        let exempt = next.excludedFocusWindowIDs.union(runtime.reinsertionAnchors.keys)
        let removals = next.presence.observe(
            known: known,
            present: present,
            confirmedGone: confirmedGone.union(minimized),
            exempt: exempt
        )

        for windowID in removals {
            if minimized.contains(windowID) {
                runtime = BentoPlanner(maximumManagedWindows: maximumManagedWindows).plan(
                    state: runtime,
                    observation: observation,
                    intent: .remove(windowID, minimized: true)
                ).state
            } else {
                runtime.layout.remove(windowID)
                runtime.reinsertionAnchors.removeValue(forKey: windowID)
            }
        }
        next.bentoInsertionOrder.removeAll { removals.contains($0) }
        next.automaticallyFloatingWindowIDs.formIntersection(present)
        for windowID in present.sorted() where !next.bentoInsertionOrder.contains(windowID) {
            next.bentoInsertionOrder.append(windowID)
        }

        while (runtime.layout.root?.windowIDs.count ?? 0) > maximumManagedWindows,
              let candidate = next.bentoInsertionOrder.reversed().first(where: {
                  runtime.layout.root?.windowIDs.contains($0) == true
              }) {
            runtime.layout.setFloating(true, windowID: candidate)
            next.automaticallyFloatingWindowIDs.insert(candidate)
        }

        let planner = BentoPlanner(maximumManagedWindows: maximumManagedWindows)
        for windowID in next.bentoInsertionOrder where present.contains(windowID) {
            if next.excludedFocusWindowIDs.contains(windowID) {
                runtime.layout.setFloating(true, windowID: windowID)
                continue
            }
            if runtime.layout.root?.windowIDs.contains(windowID) == true { continue }
            if runtime.layout.floatingWindowIDs.contains(windowID),
               !next.automaticallyFloatingWindowIDs.contains(windowID) {
                continue
            }

            let intent: BentoPlannerIntent = runtime.reinsertionAnchors[windowID] == nil
                ? .insert(windowID)
                : .restore(windowID)
            let result = planner.plan(state: runtime, observation: observation, intent: intent)
            if case .failure = result.pill {
                runtime.layout.setFloating(true, windowID: windowID)
                next.automaticallyFloatingWindowIDs.insert(windowID)
                continue
            }
            runtime = result.state
            if runtime.layout.root?.windowIDs.contains(windowID) == true {
                next.automaticallyFloatingWindowIDs.remove(windowID)
            } else if runtime.layout.floatingWindowIDs.contains(windowID) {
                next.automaticallyFloatingWindowIDs.insert(windowID)
            }
        }

        let solver = BentoConstraintSolver()
        while runtime.layout.root != nil,
              solver.solve(
                  state: runtime.layout,
                  in: observation.bounds,
                  constraints: observation.constraints
              ) == nil,
              let candidate = next.bentoInsertionOrder.reversed().first(where: {
                  runtime.layout.root?.windowIDs.contains($0) == true
              }) {
            runtime.layout.setFloating(true, windowID: candidate)
            next.automaticallyFloatingWindowIDs.insert(candidate)
        }
        if let solved = solver.solve(
            state: runtime.layout,
            in: observation.bounds,
            constraints: observation.constraints
        ) {
            runtime.layout = solved
        }

        next.bentoState = runtime.layout
        next.bentoReinsertionAnchors = runtime.reinsertionAnchors
        let placements = runtime.layout.placements(in: observation.bounds).filter {
            present.contains($0.windowID)
        }
        return BentoSessionTransition(
            session: next,
            placements: placements,
            removedWindowIDs: removals
        )
    }
}
