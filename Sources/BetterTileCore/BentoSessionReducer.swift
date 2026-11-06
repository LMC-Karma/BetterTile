import Foundation

public enum BentoSessionTransition: Sendable {
    case none
    case update(
        session: LayoutSession,
        placements: [Placement],
        removedWindowIDs: Set<WindowID>
    )
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
        minimized: Set<WindowID> = [],
        hiddenWindowIDs: Set<WindowID> = [],
        knownSpaceWindowIDs: Set<WindowID> = [],
        newWindowSide: BentoNewWindowSide = .automatic,
        balancesNewWindows: Bool = false
    ) -> BentoSessionTransition {
        var next = session
        for windowID in confirmedGone { next.followed?.forgetReturn(of: windowID) }
        var runtime = BentoRuntimeState(
            layout: next.bentoState,
            reinsertionAnchors: next.bentoReinsertionAnchors
        )
        runtime.layout.metrics = BentoLayoutMetrics(paneGap: paneGap)
        // Focus's own minimize notification preserves a followed pane. Ordinary
        // user minimizes still remove it, including one batched with an arrival.
        let focusMinimized = Set(minimized.filter { windowID in
            next.excludedFocusWindowIDs.contains(windowID)
                && (next.followed?.anchorsWindow(windowID, in: runtime.layout) == true
                    || next.followed?.hasReturnVacancy(for: windowID, in: runtime.layout) == true)
        })
        // App hiding is direct evidence that a pane stepped away, not that
        // its window closed. Floating windows retain their existing disposition.
        let hiddenPanes = Set(runtime.layout.root?.windowIDs ?? [])
            .intersection(hiddenWindowIDs).subtracting(confirmedGone)
        let present = observation.eligibleWindowIDs.subtracting(minimized)
            .subtracting(hiddenWindowIDs).subtracting(confirmedGone)
        let known = Set(runtime.layout.root?.windowIDs ?? []).union(runtime.layout.floatingWindowIDs)
        let exempt = next.excludedFocusWindowIDs.union(runtime.reinsertionAnchors.keys)
            .union(knownSpaceWindowIDs).union(hiddenWindowIDs.subtracting(hiddenPanes))
        let removals = next.presence.observe(
            known: known,
            present: present,
            confirmedGone: confirmedGone.union(minimized.subtracting(focusMinimized)).union(hiddenPanes),
            exempt: exempt
        )

        let insertionIndexes = Dictionary(uniqueKeysWithValues: next.bentoInsertionOrder.enumerated().map {
            ($0.element, $0.offset)
        })
        let orderedRemovals = removals.sorted { lhs, rhs in
            let lhsIndex = insertionIndexes[lhs] ?? Int.max
            let rhsIndex = insertionIndexes[rhs] ?? Int.max
            return lhsIndex == rhsIndex ? lhs < rhs : lhsIndex < rhsIndex
        }
        func reconcileRuntimeFollowing() {
            next.bentoState = runtime.layout
            next.reconcileFollowing()
        }

        for windowID in orderedRemovals {
            if minimized.contains(windowID) || hiddenPanes.contains(windowID), !focusMinimized.contains(windowID) {
                runtime = BentoPlanner(maximumManagedWindows: maximumManagedWindows).plan(
                    state: runtime,
                    observation: observation,
                    intent: .remove(windowID, minimized: true)
                ).state
            } else {
                if next.followed?.anchorsWindow(windowID, in: runtime.layout) == true {
                    runtime.layout.vacate(windowID)
                    runtime.layout.floatingWindowIDs.remove(windowID)
                } else {
                    runtime.layout.remove(windowID)
                }
                runtime.reinsertionAnchors.removeValue(forKey: windowID)
            }
            // Latch an end before an arrival can reconstruct the old topology.
            reconcileRuntimeFollowing()
        }
        next.bentoInsertionOrder.removeAll { removals.contains($0) }
        next.automaticallyFloatingWindowIDs.formIntersection(present.union(hiddenWindowIDs).subtracting(confirmedGone))
        for windowID in present.sorted() where !next.bentoInsertionOrder.contains(windowID) {
            next.bentoInsertionOrder.append(windowID)
        }

        func floatAutomatically(_ windowID: WindowID, runtime: inout BentoRuntimeState) {
            if next.followed?.anchorsWindow(windowID, in: runtime.layout) == true {
                if let vacancy = runtime.layout.vacate(windowID), next.excludedFocusWindowIDs.contains(windowID) {
                    next.followed?.rememberReturn(of: windowID, to: vacancy)
                }
                runtime.layout.floatingWindowIDs.insert(windowID)
            } else {
                runtime.layout.setFloating(true, windowID: windowID)
            }
            next.bentoState = runtime.layout
            next.reconcileFollowing()
        }

        // Focus-covered windows may already be absent from the observation.
        for windowID in next.excludedFocusWindowIDs.sorted()
            where next.followed?.anchorsWindow(windowID, in: runtime.layout) == true {
            floatAutomatically(windowID, runtime: &runtime)
        }

        while (runtime.layout.root?.windowIDs.count ?? 0) > maximumManagedWindows,
              let candidate = next.bentoInsertionOrder.reversed().first(where: {
                  runtime.layout.root?.windowIDs.contains($0) == true
              }) {
            floatAutomatically(candidate, runtime: &runtime)
            next.automaticallyFloatingWindowIDs.insert(candidate)
        }

        let planner = BentoPlanner(
            maximumManagedWindows: maximumManagedWindows,
            newWindowSide: newWindowSide,
            balancesNewWindows: balancesNewWindows
        )
        for windowID in next.bentoInsertionOrder where present.contains(windowID) {
            if next.excludedFocusWindowIDs.contains(windowID) {
                floatAutomatically(windowID, runtime: &runtime)
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
            let result = planner.plan(state: runtime, observation: observation, intent: intent, followed: next.followed)
            if case .failure = result.pill {
                floatAutomatically(windowID, runtime: &runtime)
                next.automaticallyFloatingWindowIDs.insert(windowID)
                continue
            }
            runtime = result.state
            reconcileRuntimeFollowing()
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
            floatAutomatically(candidate, runtime: &runtime)
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
        next.reconcileFollowing()
        next.bentoReinsertionAnchors = runtime.reinsertionAnchors
        let placements = runtime.layout.placements(in: observation.bounds).filter {
            present.contains($0.windowID)
        }
        guard next != session || !removals.isEmpty else { return .none }
        return .update(
            session: next,
            placements: placements,
            removedWindowIDs: removals
        )
    }
}
