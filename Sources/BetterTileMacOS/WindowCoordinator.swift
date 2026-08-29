import BetterTileCore
import Foundation

public struct WindowActionPlan: Sendable {
    public let requestedAction: WindowAction
    public let resolvedAction: WindowAction
    public let windowID: WindowID
    public let displayID: DisplayID
    public let sourceFrame: BTRect
    public let targetFrame: BTRect
}

public struct WindowPlacementPlan: Sendable {
    public let windowID: WindowID
    public let displayID: DisplayID
    public let sourceFrame: BTRect
    public let targetFrame: BTRect

    public init(
        windowID: WindowID,
        displayID: DisplayID,
        sourceFrame: BTRect,
        targetFrame: BTRect
    ) {
        self.windowID = windowID
        self.displayID = displayID
        self.sourceFrame = sourceFrame
        self.targetFrame = targetFrame
    }
}

/// The terminal meaning of one window mutation. Exactly one value describes
/// exactly one operation; nothing about it survives into the next call.
public enum WindowMutationOutcome: Hashable, Sendable {
    case applied
    /// The operation failed and every already-written window returned to its
    /// baseline frame.
    case failed(reason: String)
    /// The operation failed and rollback was incomplete: at least one window
    /// was left away from its baseline frame.
    case degraded(reason: String)

    public var isApplied: Bool { self == .applied }

    public var failureReason: String? {
        switch self {
        case .applied: nil
        case let .failed(reason), let .degraded(reason): reason
        }
    }
}

/// Result of planning a window action. `unavailable` is not a failure: no
/// eligible focused window, an unknown display, or an empty restore history
/// mean there is legitimately nothing to plan.
public enum WindowPlanOutcome: Sendable {
    case ready(WindowActionPlan)
    case unavailable
    case failed(reason: String)
}

public enum WindowPlacementPlanOutcome: Sendable {
    case ready(WindowPlacementPlan)
    case unavailable
    case failed(reason: String)
}

/// Result of starting a window frame transaction.
public enum TransactionStartOutcome: Sendable {
    case started(WindowFrameTransaction)
    case failed(reason: String)
}

/// Result of updating a transaction's proposed placements. Previewing never
/// touches a window, so it cannot degrade.
public enum PreviewOutcome: Hashable, Sendable {
    case accepted
    case failed(reason: String)
}

public struct WindowFrameTransaction: Sendable {
    public let id: UUID
    public let baselineFrames: [WindowID: BTRect]
    public fileprivate(set) var proposedPlacements: [Placement]
    public fileprivate(set) var lastAppliedFrames: [WindowID: BTRect]
    public fileprivate(set) var hasLiveChanges: Bool
    /// True while this transaction's windows are in an unknown arrangement: a
    /// commit or live apply failed without restoring every already-written
    /// window. `cancel` then restores the baseline even when no live change
    /// ever succeeded. A later fully successful apply clears it — every
    /// participant was just written, so no window remains in unknown state.
    public fileprivate(set) var hasDegradedApply: Bool

    fileprivate init(baselineFrames: [WindowID: BTRect]) {
        id = UUID()
        self.baselineFrames = baselineFrames
        proposedPlacements = baselineFrames.map { Placement(windowID: $0.key, frame: $0.value) }.sorted { $0.windowID < $1.windowID }
        lastAppliedFrames = baselineFrames
        hasLiveChanges = false
        hasDegradedApply = false
    }
}

@MainActor
public final class WindowCoordinator {
    private struct ExpectedMutation {
        let frame: BTRect
        let generation: UInt64
        var failedTerminalObservations = 0
    }

    public let system: any WindowSystem
    public var actionEngine: StandardActionEngine

    /// Marks an apply whose rollback also failed, so callers can distinguish a
    /// cleanly reverted failure from windows left in a mixed state.
    private struct DegradedApplyError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private var history: FrameHistory
    private var generations: [WindowID: UInt64] = [:]
    private var expectedMutations: [WindowID: [ExpectedMutation]] = [:]
    private var lastCycle: (windowID: WindowID, requestedAction: WindowAction, index: Int, date: Date)?

    public init(system: any WindowSystem, historyCapacity: Int = 10, actionEngine: StandardActionEngine = StandardActionEngine()) {
        self.system = system
        self.history = FrameHistory(capacity: historyCapacity)
        self.actionEngine = actionEngine
    }

    /// Returns whether an Accessibility event matches a BetterTile-owned frame.
    /// This query does not finish ownership; the caller ends matching
    /// generations after its successful terminal snapshot.
    public func matchesExpectedMutation(windowID: WindowID, actualFrame: BTRect, tolerance: Double = 2) -> Bool {
        expectedMutations[windowID]?.contains {
            actualFrame.approximatelyEquals($0.frame, tolerance: tolerance)
        } == true
    }

    /// Ends ownership after a caller has taken the terminal snapshot for a
    /// multi-window operation. A later frame change starts a new cause instead
    /// of being mistaken for another callback from the finished transaction.
    public func finishExpectedMutations(upTo generations: [WindowID: UInt64]) {
        for (windowID, generation) in generations {
            expectedMutations[windowID]?.removeAll { $0.generation <= generation }
            if expectedMutations[windowID]?.isEmpty == true {
                expectedMutations.removeValue(forKey: windowID)
            }
        }
    }

    /// Ends every generation through the newest frame a successful system
    /// snapshot has actually observed. This is the terminal fallback for
    /// write paths that do not own a dedicated settlement task.
    public func finishExpectedMutations(
        observing windows: [WindowSnapshot],
        tolerance: Double = 1
    ) {
        let terminalGenerations = Dictionary(uniqueKeysWithValues: windows.compactMap { window in
            let generation = expectedMutations[window.id]?
                .filter { window.frame.approximatelyEquals($0.frame, tolerance: tolerance) }
                .map(\.generation)
                .max()
            return generation.map { (window.id, $0) }
        })
        finishExpectedMutations(upTo: terminalGenerations)
    }

    /// Verifies pending generations from a periodic terminal sample. Matching
    /// frames finish immediately; ignored writes finish only after repeated
    /// nonmatching samples so a slow application keeps its ownership window.
    public func verifyExpectedMutations(
        observing windows: [WindowSnapshot],
        tolerance: Double = 1,
        failureLimit: Int = 3
    ) {
        let limit = max(1, failureLimit)
        let windowsByID = Dictionary(uniqueKeysWithValues: windows.map { ($0.id, $0) })
        var updated = expectedMutations
        var terminalGenerations: [WindowID: UInt64] = [:]

        for (windowID, var mutations) in expectedMutations {
            let matchedGeneration = windowsByID[windowID].flatMap { window in
                mutations
                    .filter { window.frame.approximatelyEquals($0.frame, tolerance: tolerance) }
                    .map(\.generation)
                    .max()
            }
            if let matchedGeneration {
                terminalGenerations[windowID] = matchedGeneration
            }
            for index in mutations.indices
                where mutations[index].generation > (matchedGeneration ?? 0) {
                mutations[index].failedTerminalObservations += 1
                if mutations[index].failedTerminalObservations >= limit {
                    terminalGenerations[windowID] = max(
                        terminalGenerations[windowID] ?? 0,
                        mutations[index].generation
                    )
                }
            }
            updated[windowID] = mutations
        }
        expectedMutations = updated
        finishExpectedMutations(upTo: terminalGenerations)
    }

    public func plan(_ requestedAction: WindowAction) -> WindowPlanOutcome {
        do {
            guard let window = try system.focusedWindow(), window.isEligible else { return .unavailable }
            let action = cycledAction(for: requestedAction, windowID: window.id)
            return plan(requestedAction: requestedAction, resolvedAction: action, window: window)
        } catch {
            return .failed(reason: error.localizedDescription)
        }
    }

    /// Plans one exact action for a captured window without advancing shortcut
    /// cycles or recording history.
    public func planExact(
        _ action: WindowAction,
        for windowID: WindowID
    ) -> WindowPlanOutcome {
        do {
            guard let window = try snapshots(ids: [windowID]).first,
                  window.isEligible
            else { return .unavailable }
            return plan(requestedAction: action, resolvedAction: action, window: window)
        } catch {
            return .failed(reason: error.localizedDescription)
        }
    }

    /// Plans a Custom Zone for a captured window without recording history or
    /// changing the window.
    public func plan(
        _ zone: CustomZone,
        for windowID: WindowID
    ) -> WindowPlacementPlanOutcome {
        do {
            guard let window = try snapshots(ids: [windowID]).first,
                  window.isEligible
            else { return .unavailable }
            guard let display = system.displays().first(where: { $0.id == window.displayID }) else {
                return .unavailable
            }
            return .ready(WindowPlacementPlan(
                windowID: window.id,
                displayID: window.displayID,
                sourceFrame: window.frame,
                targetFrame: zone.rect.frame(in: display.visibleFrame)
            ))
        } catch {
            return .failed(reason: error.localizedDescription)
        }
    }

    public func perform(_ plan: WindowActionPlan) -> WindowMutationOutcome {
        do {
            if !plan.resolvedAction.isRestore {
                history.record(plan.sourceFrame, for: plan.windowID)
            }
            try apply(plan.targetFrame, to: plan.windowID, knownCurrentFrame: plan.sourceFrame)
            return .applied
        } catch {
            return .failed(reason: error.localizedDescription)
        }
    }

    public func perform(_ plan: WindowPlacementPlan) -> WindowMutationOutcome {
        do {
            history.record(plan.sourceFrame, for: plan.windowID)
            try apply(plan.targetFrame, to: plan.windowID, knownCurrentFrame: plan.sourceFrame)
            return .applied
        } catch {
            return .failed(reason: error.localizedDescription)
        }
    }

    /// Confirms a window actually reached the frame it was asked for.
    ///
    /// An accepted Accessibility write is not the same as a window that moved,
    /// but the check cannot be made immediately: applications are not required
    /// to apply a geometry change before the write returns, and Chromium-based
    /// ones schedule it on their own run loop. Read straight back and "ignored
    /// the write" and "has not applied it yet" are the same observation, so
    /// verification waits, looks again, and only concludes failure once the
    /// window has had time to settle.
    ///
    /// Returns `nil` when nothing can be concluded - the window became
    /// unreadable, or the check was superseded - so callers leave their
    /// existing report alone rather than replacing it with a guess.
    /// - Parameter generation: The window's mutation generation at the moment
    ///   the check was scheduled. Taken by the caller rather than read here,
    ///   because a task body does not necessarily begin running before the next
    ///   mutation lands, and a generation read late would miss it.
    public func verifyPlacement(
        _ plan: WindowActionPlan,
        since generation: UInt64,
        delay: Duration = .milliseconds(120),
        attempts: Int = 3
    ) async -> DelayedPlacementVerdict {
        for attempt in 1...max(1, attempts) {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return .superseded }
            let actual = (try? snapshots(ids: [plan.windowID]).first)??.frame
            let generationChanged = mutationGeneration(for: plan.windowID) != generation
            let verdict = DelayedPlacementVerifier.verdict(
                source: plan.sourceFrame,
                target: plan.targetFrame,
                actual: actual,
                generationChanged: generationChanged
            )
            switch verdict {
            case .landed:
                finishExpectedMutations(upTo: [plan.windowID: generation])
                return verdict
            case .superseded:
                if !generationChanged {
                    finishExpectedMutations(upTo: [plan.windowID: generation])
                }
                return verdict
            case .inconclusive:
                return verdict
            case .failed:
                // Give a slow application the remaining attempts before
                // concluding it is never going to move.
                if attempt == max(1, attempts) {
                    finishExpectedMutations(upTo: [plan.windowID: generation])
                    return verdict
                }
            }
        }
        return .inconclusive
    }

    /// How many times BetterTile has written a frame for this window. Used to
    /// tell a delayed check that its action has been superseded.
    public func mutationGeneration(for windowID: WindowID) -> UInt64 {
        generations[windowID] ?? 0
    }

    public func applyCustomZone(
        _ zone: CustomZone,
        applicationRules: ApplicationRuleSet
    ) -> WindowMutationOutcome {
        do {
            guard let window = try system.focusedWindow(), window.isEligible else {
                return .failed(reason: "No eligible focused window.")
            }
            guard applicationRules
                .rule(for: window.bundleIdentifier)
                .allowsDirectPlacement
            else {
                return .failed(reason: "BetterTile is set to ignore this app.")
            }
            guard let display = system.displays().first(where: { $0.id == window.displayID }) else {
                return .failed(reason: "The window's display could not be found.")
            }
            history.record(window.frame, for: window.id)
            try apply(
                zone.rect.frame(in: display.visibleFrame),
                to: window.id,
                knownCurrentFrame: window.frame
            )
            return .applied
        } catch {
            return .failed(reason: error.localizedDescription)
        }
    }

    public func applyPlacements(_ placements: [Placement], recordHistory: Bool = true) -> WindowMutationOutcome {
        switch beginTransaction(windowIDs: Set(placements.map(\.windowID))) {
        case let .failed(reason):
            return .failed(reason: reason)
        case var .started(transaction):
            return commit(transaction: &transaction, placements: placements, recordHistory: recordHistory)
        }
    }

    /// Verifies a completed system-driven reflow and retries only windows
    /// whose Accessibility frames did not settle at the requested values.
    public func settleAuthoritativePlacements(
        _ placements: [Placement],
        maximumRetries: Int = 2,
        retryDelay: Duration = .milliseconds(100),
        tolerance: Double = 1
    ) async -> WindowMutationOutcome {
        let unsettled = "One or more windows did not settle at the requested frame."
        let retryLimit = max(0, maximumRetries)
        let windowIDs = Set(placements.map(\.windowID))
        var terminalGenerations = Dictionary(uniqueKeysWithValues: windowIDs.map {
            ($0, mutationGeneration(for: $0))
        })
        for attempt in 0...retryLimit {
            do {
                try await Task.sleep(for: retryDelay)
            } catch {
                finishExpectedMutations(upTo: terminalGenerations)
                return .failed(reason: "The settlement check was interrupted.")
            }

            let actualFrames: [WindowID: BTRect]
            do {
                actualFrames = Dictionary(uniqueKeysWithValues: try snapshots(
                    ids: Set(placements.map(\.windowID))
                ).map { ($0.id, $0.frame) })
            } catch {
                finishExpectedMutations(upTo: terminalGenerations)
                return .failed(reason: error.localizedDescription)
            }
            let pending = placements.filter {
                actualFrames[$0.windowID]?.approximatelyEquals($0.frame, tolerance: tolerance) != true
            }
            if pending.isEmpty {
                finishExpectedMutations(upTo: terminalGenerations)
                return .applied
            }
            guard attempt < retryLimit else {
                finishExpectedMutations(upTo: terminalGenerations)
                return .failed(reason: unsettled)
            }
            switch applyPlacements(pending, recordHistory: false) {
            case .applied:
                for placement in pending {
                    terminalGenerations[placement.windowID] = mutationGeneration(for: placement.windowID)
                }
            case .failed:
                finishExpectedMutations(upTo: terminalGenerations)
                return .failed(reason: unsettled)
            case let .degraded(reason):
                // The inner reason survives: windows were left in a mixed
                // arrangement, which is worse news than "not yet settled".
                finishExpectedMutations(upTo: terminalGenerations)
                return .degraded(reason: reason)
            }
        }
        return .failed(reason: unsettled)
    }

    public func beginTransaction(windowIDs: Set<WindowID>) -> TransactionStartOutcome {
        do {
            let snapshots = Dictionary(uniqueKeysWithValues: try snapshots(ids: windowIDs).map { ($0.id, $0) })
            // This guard also guarantees a complete baseline: every requested
            // ID resolved to an eligible snapshot in the same dictionary the
            // baseline is built from.
            guard !windowIDs.isEmpty, windowIDs.allSatisfy({ snapshots[$0]?.isEligible == true }) else {
                return .failed(reason: "One or more windows are no longer eligible.")
            }
            let baseline = Dictionary(uniqueKeysWithValues: windowIDs.compactMap { id in snapshots[id].map { (id, $0.frame) } })
            return .started(WindowFrameTransaction(baselineFrames: baseline))
        } catch {
            return .failed(reason: error.localizedDescription)
        }
    }

    public func preview(transaction: inout WindowFrameTransaction, placements: [Placement]) -> PreviewOutcome {
        guard Set(placements.map(\.windowID)) == Set(transaction.baselineFrames.keys) else {
            return .failed(reason: "The preview no longer matches the active window transaction.")
        }
        transaction.proposedPlacements = placements.sorted { $0.windowID < $1.windowID }
        return .accepted
    }

    public func commit(
        transaction: inout WindowFrameTransaction,
        placements: [Placement]? = nil,
        recordHistory: Bool = true
    ) -> WindowMutationOutcome {
        if let placements, case let .failed(reason) = preview(transaction: &transaction, placements: placements) {
            return .failed(reason: reason)
        }
        do {
            try validate(transaction.proposedPlacements)
            try applyAtomically(transaction.proposedPlacements, rollbackFrames: transaction.baselineFrames)
            if recordHistory {
                recordChangedHistoryFrames(
                    transaction.baselineFrames,
                    proposedPlacements: transaction.proposedPlacements
                )
            }
            transaction.lastAppliedFrames = Dictionary(uniqueKeysWithValues: transaction.proposedPlacements.map { ($0.windowID, $0.frame) })
            transaction.hasDegradedApply = false
            return .applied
        } catch {
            return applyFailureOutcome(for: error, transaction: &transaction)
        }
    }

    public func applyLive(transaction: inout WindowFrameTransaction, placements: [Placement]) -> WindowMutationOutcome {
        if case let .failed(reason) = preview(transaction: &transaction, placements: placements) {
            return .failed(reason: reason)
        }
        do {
            try validate(transaction.proposedPlacements)
            try applyAtomically(transaction.proposedPlacements, rollbackFrames: transaction.lastAppliedFrames)
            transaction.lastAppliedFrames = Dictionary(uniqueKeysWithValues: placements.map { ($0.windowID, $0.frame) })
            transaction.hasLiveChanges = true
            transaction.hasDegradedApply = false
            return .applied
        } catch {
            return applyFailureOutcome(for: error, transaction: &transaction)
        }
    }

    public func finishLive(transaction: WindowFrameTransaction, recordHistory: Bool = true) {
        if recordHistory, transaction.hasLiveChanges {
            recordChangedHistoryFrames(
                transaction.baselineFrames,
                proposedPlacements: transaction.proposedPlacements
            )
        }
    }

    public func cancel(transaction: WindowFrameTransaction) -> WindowMutationOutcome {
        guard transaction.hasLiveChanges || transaction.hasDegradedApply else { return .applied }
        do {
            try applyAtomically(
                transaction.baselineFrames.map { Placement(windowID: $0.key, frame: $0.value) },
                rollbackFrames: transaction.lastAppliedFrames
            )
            return .applied
        } catch {
            // A failed cancel is degraded by definition: the baseline was not
            // fully restored, regardless of why the restore write failed.
            return .degraded(reason: "The divider change failed and the previous layout could not be fully restored.")
        }
    }

    /// Applies a focus drop as one best-effort atomic operation. If any
    /// minimize request fails, every already-minimized window is restored and
    /// the source returns to its mouse-down frame.
    public func applyFocusDrop(
        placement: Placement,
        minimizing windowIDs: Set<WindowID>,
        sourceBaselineFrame: BTRect
    ) -> WindowMutationOutcome {
        var minimized: [WindowID] = []
        var sourceWriteCompleted = false
        do {
            try validate([placement])
            try apply(placement.frame, to: placement.windowID, knownCurrentFrame: sourceBaselineFrame)
            sourceWriteCompleted = true
            for windowID in windowIDs.sorted() {
                try system.setMinimized(true, for: windowID)
                minimized.append(windowID)
            }
            if !sourceBaselineFrame.approximatelyEquals(placement.frame, tolerance: 0.01) {
                history.record(sourceBaselineFrame, for: placement.windowID)
            }
            return .applied
        } catch {
            var rollbackFailed = false
            for windowID in minimized.reversed() {
                do {
                    try system.setMinimized(false, for: windowID)
                } catch {
                    rollbackFailed = true
                }
            }
            var sourceNeedsRestore = sourceWriteCompleted
                && !sourceBaselineFrame.approximatelyEquals(placement.frame, tolerance: 0.01)
            var observedSourceFrame: BTRect? = sourceWriteCompleted ? placement.frame : nil
            if !sourceWriteCompleted,
               let source = (try? snapshots(ids: [placement.windowID]))?.first {
                observedSourceFrame = source.frame
                sourceNeedsRestore = !source.frame.approximatelyEquals(sourceBaselineFrame, tolerance: 0.01)
            }
            if sourceNeedsRestore {
                do {
                    try apply(
                        sourceBaselineFrame,
                        to: placement.windowID,
                        knownCurrentFrame: observedSourceFrame
                    )
                } catch {
                    rollbackFailed = true
                }
            }
            return rollbackFailed
                ? .degraded(reason: "The focus drop failed and the previous layout could not be fully restored.")
                : .failed(reason: error.localizedDescription)
        }
    }

    /// Restores every focus-drop peer in deterministic order, best-effort: a
    /// failing peer does not stop the sweep, and successfully restored windows
    /// are deliberately never re-minimized. This is asymmetric with
    /// `applyFocusDrop`'s rollback on purpose — there the drop never became
    /// the user-visible arrangement, so re-minimizing undoes a mistake; here
    /// each restore is immediately user-visible, and undoing it to satisfy
    /// atomicity would trade a small inconsistency for a larger one.
    public func restoreFocusDropPeers(_ windowIDs: Set<WindowID>) -> WindowMutationOutcome {
        var failureReason: String?
        for windowID in windowIDs.sorted() {
            do {
                try system.setMinimized(false, for: windowID)
            } catch {
                failureReason = error.localizedDescription
            }
        }
        if let failureReason { return .failed(reason: failureReason) }
        return .applied
    }

    private func apply(
        _ frame: BTRect,
        to windowID: WindowID,
        knownCurrentFrame: BTRect? = nil
    ) throws {
        let generation = (generations[windowID] ?? 0) &+ 1
        generations[windowID] = generation
        guard generations[windowID] == generation else { return }
        expect(frame, for: windowID, generation: generation)
        do {
            try system.setFrame(frame, knownCurrentFrame: knownCurrentFrame, for: windowID)
        } catch {
            cancelExpectedMutation(for: windowID, generation: generation)
            throw error
        }
    }

    private func validate(_ placements: [Placement]) throws {
        let ids = Set(placements.map(\.windowID))
        let snapshots = Dictionary(uniqueKeysWithValues: try snapshots(ids: ids).map { ($0.id, $0) })
        let displays = Dictionary(uniqueKeysWithValues: system.displays().map { ($0.id, $0) })
        for placement in placements {
            guard let snapshot = snapshots[placement.windowID] else { throw WindowSystemError.windowNotFound(placement.windowID) }
            guard snapshot.isEligible, snapshot.constraints.isMovable, snapshot.constraints.isResizable else {
                throw WindowSystemError.unsupportedWindow(placement.windowID)
            }
            guard placement.frame.size.width >= snapshot.constraints.minimumSize.width,
                  placement.frame.size.height >= snapshot.constraints.minimumSize.height
            else { throw WindowSystemError.operationFailed("A window reached its minimum size.") }
            // A legal size is not enough: a stale display frame or a split
            // driven to an edge can produce a placement that leaves nothing on
            // screen to grab.
            if let display = displays[snapshot.displayID],
               !PlacementBounds.isReachable(placement.frame, in: display.visibleFrame) {
                throw WindowSystemError.operationFailed(
                    "A window would have been placed off screen."
                )
            }
        }
    }

    private func applyAtomically(_ placements: [Placement], rollbackFrames: [WindowID: BTRect]) throws {
        var applied: [WindowID] = []
        do {
            for placement in placements.sorted(by: { $0.windowID < $1.windowID }) {
                try apply(
                    placement.frame,
                    to: placement.windowID,
                    knownCurrentFrame: rollbackFrames[placement.windowID]
                )
                applied.append(placement.windowID)
            }
        } catch {
            var rollbackFailures: [WindowID] = []
            for id in applied.reversed() {
                guard let frame = rollbackFrames[id] else { continue }
                let appliedFrame = placements.first(where: { $0.windowID == id })?.frame
                do {
                    try apply(frame, to: id, knownCurrentFrame: appliedFrame)
                } catch {
                    rollbackFailures.append(id)
                }
            }
            if !rollbackFailures.isEmpty {
                throw DegradedApplyError(
                    message: "A window update failed and the previous layout could not be fully restored."
                )
            }
            throw error
        }
    }

    /// Translates an apply failure into its outcome and marks the transaction
    /// when the rollback was incomplete, so a later `cancel` still restores the
    /// baseline.
    private func applyFailureOutcome(
        for error: Error,
        transaction: inout WindowFrameTransaction
    ) -> WindowMutationOutcome {
        if let degraded = error as? DegradedApplyError {
            transaction.hasDegradedApply = true
            return .degraded(reason: degraded.message)
        }
        return .failed(reason: error.localizedDescription)
    }

    private func snapshots(ids: Set<WindowID>) throws -> [WindowSnapshot] {
        if let targeted = system as? any TargetedWindowSystem {
            return try targeted.windowSnapshots(ids: ids)
        }
        return try system.visibleWindows().filter { ids.contains($0.id) }
    }

    private func recordHistoryFrames(_ frames: [WindowID: BTRect]) {
        for (id, frame) in frames.sorted(by: { $0.key < $1.key }) { history.record(frame, for: id) }
    }

    private func recordChangedHistoryFrames(
        _ baselineFrames: [WindowID: BTRect],
        proposedPlacements: [Placement]
    ) {
        let proposedFrames = Dictionary(uniqueKeysWithValues: proposedPlacements.map { ($0.windowID, $0.frame) })
        let changed = baselineFrames.filter { id, baseline in
            guard let proposed = proposedFrames[id] else { return false }
            return !baseline.approximatelyEquals(proposed, tolerance: 0.01)
        }
        recordHistoryFrames(changed)
    }

    private func expect(_ frame: BTRect, for windowID: WindowID, generation: UInt64) {
        expectedMutations[windowID, default: []].append(ExpectedMutation(frame: frame, generation: generation))
    }

    private func cancelExpectedMutation(for windowID: WindowID, generation: UInt64) {
        expectedMutations[windowID]?.removeAll { $0.generation == generation }
        if expectedMutations[windowID]?.isEmpty == true {
            expectedMutations.removeValue(forKey: windowID)
        }
    }

    private func transferTarget(for action: WindowAction, window: WindowSnapshot, displays: [DisplaySnapshot]) -> BTRect? {
        let ordered = displays.sorted { lhs, rhs in
            lhs.frame.minX == rhs.frame.minX ? lhs.frame.minY < rhs.frame.minY : lhs.frame.minX < rhs.frame.minX
        }
        guard ordered.count > 1, let currentIndex = ordered.firstIndex(where: { $0.id == window.displayID }) else { return nil }
        let offset = action == .nextDisplay ? 1 : -1
        let destinationIndex = (currentIndex + offset + ordered.count) % ordered.count
        return actionEngine.transferFrame(window.frame, from: ordered[currentIndex], to: ordered[destinationIndex])
    }

    private func plan(
        requestedAction: WindowAction,
        resolvedAction: WindowAction,
        window: WindowSnapshot
    ) -> WindowPlanOutcome {
        let displays = system.displays()
        guard let display = displays.first(where: { $0.id == window.displayID }) else {
            return .unavailable
        }
        let target: BTRect?
        if resolvedAction.isRestore {
            target = history.restore(for: window.id)
        } else if resolvedAction.isDisplayTransfer {
            target = transferTarget(for: resolvedAction, window: window, displays: displays)
        } else {
            target = actionEngine.targetFrame(for: resolvedAction, window: window, display: display)
        }
        guard let target else { return .unavailable }
        return .ready(WindowActionPlan(
            requestedAction: requestedAction,
            resolvedAction: resolvedAction,
            windowID: window.id,
            displayID: window.displayID,
            sourceFrame: window.frame,
            targetFrame: target
        ))
    }

    private func cycledAction(for requested: WindowAction, windowID: WindowID) -> WindowAction {
        let sequence: [WindowAction]
        switch requested {
        case .leftHalf: sequence = [.leftHalf, .leftThird, .leftTwoThirds]
        case .rightHalf: sequence = [.rightHalf, .rightThird, .rightTwoThirds]
        default: return requested
        }
        let now = Date()
        let nextIndex: Int
        if let lastCycle, lastCycle.windowID == windowID, lastCycle.requestedAction == requested, now.timeIntervalSince(lastCycle.date) < 2 {
            nextIndex = (lastCycle.index + 1) % sequence.count
        } else {
            nextIndex = 0
        }
        lastCycle = (windowID, requested, nextIndex, now)
        return sequence[nextIndex]
    }
}
