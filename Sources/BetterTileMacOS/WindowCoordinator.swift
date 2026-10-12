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

    public init(_ actionPlan: WindowActionPlan) {
        self.init(
            windowID: actionPlan.windowID,
            displayID: actionPlan.displayID,
            sourceFrame: actionPlan.sourceFrame,
            targetFrame: actionPlan.targetFrame
        )
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
    /// True when a live tick left a growing window one sample behind. The next
    /// tick completes it, even without a new sample.
    public fileprivate(set) var hasTrailingWrites = false
    /// The proposal of the previous live tick, which growing windows trail.
    fileprivate var previousLiveProposal: [WindowID: BTRect] = [:]
    /// Frames read back after this transaction's live writes. A drag can move
    /// less than the write tolerance per tick, so the next write compares
    /// with what the window reported, not with the last request.
    fileprivate var measuredLiveFrames: [WindowID: BTRect] = [:]

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

    /// Resolves the ordinary shortcut cycle for one already captured window.
    public func plan(_ requestedAction: WindowAction, for windowID: WindowID) -> WindowPlanOutcome {
        do {
            guard let window = try snapshots(ids: [windowID]).first, window.isEligible else { return .unavailable }
            return plan(requestedAction: requestedAction,
                resolvedAction: cycledAction(for: requestedAction, windowID: windowID), window: window)
        } catch { return .failed(reason: error.localizedDescription) }
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

    public func perform(_ plan: WindowActionPlan) -> WindowMutationOutcome {
        perform(WindowPlacementPlan(plan), restoringHistory: plan.resolvedAction.isRestore)
    }

    public func perform(_ plan: WindowPlacementPlan) -> WindowMutationOutcome {
        perform(plan, restoringHistory: false)
    }

    private func perform(_ plan: WindowPlacementPlan, restoringHistory: Bool) -> WindowMutationOutcome {
        if restoringHistory, history.peek(for: plan.windowID) != plan.targetFrame {
            return .failed(reason: "The restore history changed before the action could be applied.")
        }
        do {
            try applyAtomically(
                [Placement(windowID: plan.windowID, frame: plan.targetFrame)],
                rollbackFrames: [plan.windowID: plan.sourceFrame]
            )
            if restoringHistory {
                _ = history.restore(for: plan.windowID)
            } else {
                history.record(plan.sourceFrame, for: plan.windowID)
            }
            return .applied
        } catch let error as DegradedApplyError {
            return .degraded(reason: error.message)
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
        await verifyPlacement(
            WindowPlacementPlan(plan),
            since: generation,
            delay: delay,
            attempts: attempts
        )
    }

    public func verifyPlacement(
        _ plan: WindowPlacementPlan,
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
            // A corrective commit starts from the frames an earlier commit
            // wrote, so shrink-before-grow compares against those.
            try applyAtomically(transaction.proposedPlacements, rollbackFrames: transaction.baselineFrames,
                                currentFrames: transaction.lastAppliedFrames)
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

    /// Records a committed transaction's changed frames for Restore, for a
    /// caller that committed with `recordHistory: false`.
    public func recordHistory(of transaction: WindowFrameTransaction) {
        recordChangedHistoryFrames(transaction.baselineFrames, proposedPlacements: transaction.proposedPlacements)
    }

    public func applyLive(
        transaction: inout WindowFrameTransaction,
        placements: [Placement],
        validateParticipants: Bool = true
    ) -> WindowMutationOutcome {
        let previousProposal = transaction.previousLiveProposal
        if case let .failed(reason) = preview(transaction: &transaction, placements: placements) {
            return .failed(reason: reason)
        }
        do {
            if validateParticipants { try validate(transaction.proposedPlacements) }
            // Intermediate ticks skip frames already requested. A validated
            // apply resends every frame: an application can accept a write
            // and ignore it, so the last request is not proof of its frame.
            let changed = validateParticipants || transaction.hasDegradedApply
                ? transaction.proposedPlacements
                : transaction.proposedPlacements.filter {
                    transaction.lastAppliedFrames[$0.windowID]?.approximatelyEquals($0.frame, tolerance: 0.01) != true
                }
            var writes = changed
            var trailing = false
            if !validateParticipants {
                // Within a drag tick, shrinking windows take the new sample
                // and growing windows take the previous one. All applications
                // are still written in one concurrent pass, but a growing
                // window only enters space its neighbour gave up a tick
                // earlier, so the two do not overlap while that neighbour
                // commits. A neighbour that refused its last size holds the
                // growing windows.
                let previous = transaction.lastAppliedFrames
                let shrinkingIDs = Set(changed.filter { placement in
                    guard let old = previous[placement.windowID] else { return false }
                    return placement.frame.size.width < old.size.width - 0.5
                        || placement.frame.size.height < old.size.height - 0.5
                }.map(\.windowID))
                let growing = changed.filter { !shrinkingIDs.contains($0.windowID) }
                if !changed.isEmpty {
                    let neighbourHoldsSpace = neighbourHoldsItsSpace(
                        transaction: transaction, excluding: Set(growing.map(\.windowID))
                    )
                    writes = changed.compactMap { placement in
                        if shrinkingIDs.contains(placement.windowID) {
                            // A window can shrink on one axis and grow on the
                            // other at a junction. Its growing axis trails
                            // like any growing window.
                            guard let old = previous[placement.windowID] else { return placement }
                            let held = neighbourHoldsSpace ? old : (previousProposal[placement.windowID] ?? old)
                            let frame = Self.trailingGrowth(placement.frame, from: old, held: held)
                            if !frame.approximatelyEquals(placement.frame, tolerance: 0.01) { trailing = true }
                            return Placement(windowID: placement.windowID, frame: frame)
                        }
                        if neighbourHoldsSpace { trailing = true; return nil }
                        guard let earlier = previousProposal[placement.windowID] ?? previous[placement.windowID],
                              earlier.size.width <= placement.frame.size.width + 0.5,
                              earlier.size.height <= placement.frame.size.height + 0.5,
                              !shrinkingIDs.isEmpty
                        else { return placement }
                        if !earlier.approximatelyEquals(placement.frame, tolerance: 0.01) { trailing = true }
                        guard previous[placement.windowID]?.approximatelyEquals(earlier, tolerance: 0.01) != true else { return nil }
                        return Placement(windowID: placement.windowID, frame: earlier)
                    }
                }
                try applyAtomically(
                    writes,
                    rollbackFrames: previous,
                    currentFrames: previous.merging(transaction.measuredLiveFrames) { _, measured in measured },
                    intermediate: true
                )
                for placement in writes {
                    transaction.measuredLiveFrames[placement.windowID] = system.measuredFrameAfterWrite(for: placement.windowID)
                }
            } else {
                try applyAtomically(
                    changed,
                    rollbackFrames: transaction.lastAppliedFrames,
                    intermediate: false
                )
            }
            // A window that trailed keeps the frame it was sent, so the next
            // tick sends the rest of its change.
            if validateParticipants {
                transaction.lastAppliedFrames = Dictionary(uniqueKeysWithValues: placements.map { ($0.windowID, $0.frame) })
            } else {
                for placement in writes { transaction.lastAppliedFrames[placement.windowID] = placement.frame }
            }
            transaction.previousLiveProposal = Dictionary(
                uniqueKeysWithValues: transaction.proposedPlacements.map { ($0.windowID, $0.frame) }
            )
            transaction.hasTrailingWrites = trailing
            transaction.hasLiveChanges = true
            transaction.hasDegradedApply = false
            return .applied
        } catch {
            return applyFailureOutcome(for: error, transaction: &transaction)
        }
    }

    /// True when a window other than `excluding` has not given up the space a
    /// neighbour would grow into: it read back larger than the size it was
    /// sent.
    /// Takes each shrinking axis of `frame` now and keeps each growing axis
    /// at `held`, so the window never grows into space a neighbour has not
    /// yet given up.
    static func trailingGrowth(_ frame: BTRect, from old: BTRect, held: BTRect) -> BTRect {
        func axis(_ new: (origin: Double, size: Double), _ old: Double, _ held: (origin: Double, size: Double))
            -> (origin: Double, size: Double) {
            guard new.size > old + 0.5, held.size <= new.size + 0.5 else { return new }
            return held
        }
        let x = axis((frame.minX, frame.size.width), old.size.width, (held.minX, held.size.width))
        let y = axis((frame.minY, frame.size.height), old.size.height, (held.minY, held.size.height))
        return BTRect(x: x.origin, y: y.origin, width: x.size, height: y.size)
    }

    private func neighbourHoldsItsSpace(transaction: WindowFrameTransaction, excluding: Set<WindowID>) -> Bool {
        let candidates = transaction.lastAppliedFrames.filter { !excluding.contains($0.key) && transaction.baselineFrames[$0.key] != $0.value }
        guard !candidates.isEmpty else { return false }
        var unread = Set<WindowID>()
        for (id, sent) in candidates {
            if let actual = system.measuredFrameAfterWrite(for: id) {
                if actual.size.width > sent.size.width + 2 || actual.size.height > sent.size.height + 2 { return true }
            } else {
                unread.insert(id)
            }
        }
        guard !unread.isEmpty, let read = try? snapshots(ids: unread) else { return false }
        return read.contains { snapshot in
            guard let sent = candidates[snapshot.id] else { return false }
            return snapshot.frame.size.width > sent.size.width + 2 || snapshot.frame.size.height > sent.size.height + 2
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
        return restoreBaseline(of: transaction)
    }

    /// Returns every participant to its baseline frame, also after a
    /// committed apply.
    public func restoreBaseline(of transaction: WindowFrameTransaction) -> WindowMutationOutcome {
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

    /// Measures the minimum sizes of new windows before their first
    /// placement. The probe changes each window's size and restores it, so
    /// it is a window mutation like any other.
    public func probeMinimumSizes(for windowIDs: Set<WindowID>) -> WindowMutationOutcome {
        guard !windowIDs.isEmpty, let probing = system as? any MinimumSizeProbing else { return .applied }
        // The probe is BetterTile's own write. Its frame events end at each
        // window's current frame and must not read as an external change.
        var probeGenerations: [WindowID: UInt64] = [:]
        for snapshot in (try? snapshots(ids: windowIDs)) ?? [] {
            let generation = (generations[snapshot.id] ?? 0) &+ 1
            generations[snapshot.id] = generation
            probeGenerations[snapshot.id] = generation
            expect(snapshot.frame, for: snapshot.id, generation: generation)
        }
        let unrestored = probing.probeMinimumSizes(for: windowIDs)
        // A window left at another size has not returned to that frame.
        for id in unrestored {
            if let generation = probeGenerations[id] { cancelExpectedMutation(for: id, generation: generation) }
        }
        return unrestored.isEmpty ? .applied
            : .degraded(reason: "A new window did not return to its size after BetterTile measured it.")
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
        knownCurrentFrame: BTRect? = nil,
        intermediate: Bool = false
    ) throws {
        let generation = (generations[windowID] ?? 0) &+ 1
        generations[windowID] = generation
        guard generations[windowID] == generation else { return }
        expect(frame, for: windowID, generation: generation)
        do {
            if intermediate {
                try system.setIntermediateFrame(frame, knownCurrentFrame: knownCurrentFrame, for: windowID)
            } else {
                try system.setFrame(frame, knownCurrentFrame: knownCurrentFrame, for: windowID)
            }
        } catch {
            cancelExpectedMutation(for: windowID, generation: generation)
            throw error
        }
    }

    private func validate(_ placements: [Placement], sizeTolerance: Double = 0) throws {
        let ids = Set(placements.map(\.windowID))
        let snapshots = Dictionary(uniqueKeysWithValues: try snapshots(ids: ids).map { ($0.id, $0) })
        let displays = Dictionary(uniqueKeysWithValues: system.displays().map { ($0.id, $0) })
        for placement in placements {
            guard let snapshot = snapshots[placement.windowID] else { throw WindowSystemError.windowNotFound(placement.windowID) }
            guard snapshot.isEligible, snapshot.constraints.isMovable, snapshot.constraints.isResizable else {
                throw WindowSystemError.unsupportedWindow(placement.windowID)
            }
            guard placement.frame.size.width + sizeTolerance >= snapshot.constraints.minimumSize.width,
                  placement.frame.size.height + sizeTolerance >= snapshot.constraints.minimumSize.height
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

    /// - Parameter intermediate: The placements are an unvalidated sample of
    ///   a continuous gesture. Rollback writes always use the full sequence.
    private func applyAtomically(
        _ placements: [Placement],
        rollbackFrames: [WindowID: BTRect],
        currentFrames: [WindowID: BTRect]? = nil,
        intermediate: Bool = false
    ) throws {
        guard !placements.isEmpty else { return }
        let known = currentFrames ?? rollbackFrames
        if intermediate {
            // Gesture samples go to every application at once; a rejected
            // sample restores the previous sample's frames.
            try system.withFrameWriteBatch {
                var generationsWritten: [WindowID: UInt64] = [:]
                for placement in placements {
                    let generation = (generations[placement.windowID] ?? 0) &+ 1
                    generations[placement.windowID] = generation
                    generationsWritten[placement.windowID] = generation
                    expect(placement.frame, for: placement.windowID, generation: generation)
                }
                do {
                    try system.setIntermediateFrames(placements, knownCurrentFrames: known)
                } catch {
                    for (id, generation) in generationsWritten { cancelExpectedMutation(for: id, generation: generation) }
                    var rollbackFailed = false
                    // Other applications may already hold this sample. Shrink
                    // windows back before regrowing their neighbours.
                    func shrinksBack(_ placement: Placement) -> Bool {
                        guard let frame = rollbackFrames[placement.windowID] else { return false }
                        return frame.size.width < placement.frame.size.width - 0.5
                            || frame.size.height < placement.frame.size.height - 0.5
                    }
                    for placement in placements.sorted(by: { shrinksBack($0) && !shrinksBack($1) }) {
                        guard let frame = rollbackFrames[placement.windowID] else { continue }
                        do { try apply(frame, to: placement.windowID, knownCurrentFrame: placement.frame) } catch { rollbackFailed = true }
                    }
                    if rollbackFailed {
                        throw DegradedApplyError(message: "A window update failed and the previous layout could not be fully restored.")
                    }
                    throw error
                }
            }
            return
        }
        try system.withFrameWriteBatch {
            var attempted: [WindowID] = []
            do {
                // Shrink before growing, so a growing window never covers a
                // neighbour that has not yet made room.
                let before = currentFrames ?? rollbackFrames
                func shrinks(_ placement: Placement) -> Bool {
                    guard let old = before[placement.windowID] else { return false }
                    return placement.frame.size.width < old.size.width - 0.5
                        || placement.frame.size.height < old.size.height - 0.5
                }
                for placement in placements.sorted(by: { lhs, rhs in
                    let left = shrinks(lhs), right = shrinks(rhs)
                    return left != right ? left : lhs.windowID < rhs.windowID
                }) {
                    attempted.append(placement.windowID)
                    try apply(
                        placement.frame,
                        to: placement.windowID,
                        knownCurrentFrame: known[placement.windowID],
                        intermediate: intermediate
                    )
                }
            } catch {
                // A size write can succeed before a position write fails. Read
                // the failing window before deciding whether it needs rollback.
                let failedID = attempted.last
                let failedFrame = failedID.flatMap { (try? snapshots(ids: [$0]))?.first?.frame }
                var rollbackFailures: [WindowID] = []
                for id in attempted.reversed() {
                    guard let frame = rollbackFrames[id] else { continue }
                    if id == failedID, failedFrame?.approximatelyEquals(frame, tolerance: 0.01) == true { continue }
                    let appliedFrame = id == failedID
                        ? failedFrame
                        : placements.first(where: { $0.windowID == id })?.frame
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

    /// A stepped frame accepted for a Tabbed placement is this placement's
    /// result too. Its events are expected; other near frames are not.
    private func expectSteppedFrames(_ placements: [Placement], actual: [WindowID: BTRect]) {
        for placement in placements {
            guard let frame = actual[placement.windowID],
                  SteppedSizeAcceptance.evaluate(requested: placement.frame, actual: frame) == .stepped,
                  let generation = generations[placement.windowID] else { continue }
            expect(frame, for: placement.windowID, generation: generation)
        }
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
            target = history.peek(for: window.id)
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

extension WindowCoordinator {
    /// Restores a previously verified Tabbed resize checkpoint. New size hints
    /// must not prevent attempting that restoration; actual readback decides
    /// whether it succeeded. Hidden tabs remain best effort.
    public func restoreTabbedFrames(
        _ frames: [WindowID: BTRect], required: Set<WindowID>, on displayID: DisplayID,
        isCurrent: @MainActor () -> Bool
    ) async -> WindowMutationOutcome {
        let degraded = WindowMutationOutcome.degraded(reason: "Tabbed could not fully restore the previous arrangement. Use Repair Tabbed or switch to Native.")
        guard isCurrent(), !Task.isCancelled,
              let display = system.displays().first(where: { $0.id == displayID }),
              let snapshots = try? snapshots(ids: Set(frames.keys)) else { return degraded }
        // Size hints can change after a resize. Bypass only those hints;
        // never write an unreadable, ineligible, or relocated participant.
        let current = Dictionary(snapshots.filter {
            $0.isEligible && $0.constraints.isResizable && $0.displayID == displayID
                && frames[$0.id].map { PlacementBounds.isReachable($0, in: display.visibleFrame) } == true
        }.map { ($0.id, $0.frame) }, uniquingKeysWith: { first, _ in first })
        guard isCurrent(), !Task.isCancelled, !required.isEmpty,
              required.isSubset(of: Set(current.keys)) else { return degraded }
        system.withFrameWriteBatch {
            for (id, frame) in frames.sorted(by: { $0.key < $1.key })
                where current[id] != nil && current[id]?.approximatelyEquals(frame, tolerance: 1) != true {
                guard isCurrent(), !Task.isCancelled else { break }
                try? apply(frame, to: id, knownCurrentFrame: current[id])
            }
        }
        for attempt in 0..<4 {
            guard isCurrent(), !Task.isCancelled,
                  let restored = try? self.snapshots(ids: required),
                  isCurrent(), !Task.isCancelled else { return degraded }
            if required.allSatisfy({ id in
                guard let frame = frames[id] else { return false }
                return restored.contains { $0.id == id && $0.isEligible && $0.displayID == displayID
                    && $0.frame.approximatelyEquals(frame, tolerance: 2) }
            }) { return .applied }
            guard attempt < 3 else { break }
            do { try await Task.sleep(for: .milliseconds(50)) }
            catch { return degraded }
        }
        return degraded
    }

    /// A bounded frame/order transaction. Windows remain on-screen and are
    /// never minimized. Session validity is checked again after each await.
    /// - Parameter rollbackRequired: Previous selections that become hidden in
    ///   this proposal but must be verified again if the old layout is restored.
    /// - Parameter required: Windows whose frames must fit and settle. Other
    ///   placements (hidden tabs stacked behind their pane's selected tab) are
    ///   best effort: a refusal never fails the layout. Nil requires all.
    public func applyTabbed(
        placements allPlacements: [Placement],
        rollbackFrames: [WindowID: BTRect]? = nil,
        rollbackDisplayID: DisplayID? = nil,
        rollbackRequired: Set<WindowID>? = nil,
        required: Set<WindowID>? = nil,
        selected: [WindowID],
        previousSelected: [WindowID],
        focus: WindowID?,
        onSizeMismatch: (@MainActor (WindowID, BTRect, BTRect, BTRect) -> Void)? = nil,
        isCurrent: @MainActor () -> Bool
    ) async -> WindowMutationOutcome {
        let placements = required.map { ids in allPlacements.filter { ids.contains($0.windowID) } } ?? allPlacements
        let bestEffort = required.map { ids in allPlacements.filter { !ids.contains($0.windowID) } } ?? []
        guard let tabSystem = system as? any TabbedWindowSystem else {
            return .failed(reason: "This window system does not support Tabbed actions.")
        }
        guard isCurrent(), !Task.isCancelled else { return .failed(reason: "The desktop changed.") }
        let ids = required ?? Set(placements.map(\.windowID))
        let baseline: [WindowID: BTRect]
        let currentFrames: [WindowID: BTRect]
        let participantDisplayID: DisplayID?
        let oldFocus = try? system.focusedWindow()?.id
        do {
            guard ids == Set(placements.map(\.windowID)) else {
                throw WindowSystemError.operationFailed("One or more selected tabs are no longer available.")
            }
            try validate(placements, sizeTolerance: 0.001)
            let participants = try snapshots(ids: ids)
            guard isCurrent(), !Task.isCancelled,
                  participants.count == ids.count,
                  participants.allSatisfy({ $0.isEligible && $0.constraints.isResizable
                      && (rollbackDisplayID == nil || $0.displayID == rollbackDisplayID) }) else {
                throw WindowSystemError.operationFailed("The Tabbed participants changed.")
            }
            participantDisplayID = rollbackDisplayID ?? participants.first?.displayID
            currentFrames = Dictionary(uniqueKeysWithValues: participants.map { ($0.id, $0.frame) })
            // A resize has already changed real frames. Keep its verified
            // checkpoint for refusal evidence and rollback, not that partial
            // arrangement. Writes still compare against the current frames.
            baseline = currentFrames.merging(rollbackFrames?.filter { ids.contains($0.key) } ?? [:]) { _, checkpoint in checkpoint }
        } catch {
            if let rollbackFrames, let rollbackDisplayID {
                let restored = await restoreTabbedFrames(rollbackFrames, required: ids.union(rollbackRequired ?? []), on: rollbackDisplayID, isCurrent: isCurrent)
                if case .degraded = restored { return restored }
            }
            return .failed(reason: error.localizedDescription)
        }
        // Hidden tabs are best effort: read what is readable, and write only
        // frames that change, in the same batch as the required writes.
        let bestEffortCurrent = Dictionary(
            ((try? snapshots(ids: Set(bestEffort.map(\.windowID)))) ?? []).map { ($0.id, $0.frame) },
            uniquingKeysWith: { first, _ in first }
        )
        let hiddenIDs = Set(bestEffort.map(\.windowID))
        let bestEffortBaseline = bestEffortCurrent.merging(rollbackFrames?.filter { hiddenIDs.contains($0.key) } ?? [:]) { _, checkpoint in checkpoint }
        let changedBestEffort = bestEffort.filter { placement in
            bestEffortCurrent[placement.windowID].map { !$0.approximatelyEquals(placement.frame, tolerance: 0.5) } ?? false
        }
        var touched = false
        do {
            let changed = placements.filter { !(currentFrames[$0.windowID]?.approximatelyEquals($0.frame, tolerance: 0.5) ?? false) }
            touched = !changed.isEmpty || !changedBestEffort.isEmpty
            try system.withFrameWriteBatch {
                try applyAtomically(changed, rollbackFrames: baseline, currentFrames: currentFrames)
                for placement in changedBestEffort {
                    try? apply(placement.frame, to: placement.windowID, knownCurrentFrame: bestEffortCurrent[placement.windowID])
                }
            }
            if let focus {
                touched = true
                try tabSystem.raiseWindow(focus, activate: true)
            }
            for id in selected where id != focus {
                touched = true
                try tabSystem.raiseWindow(id, activate: false)
            }
            // Activation already raised the focused tab. Raise it again only
            // when ordering another pane put a window in front of it.
            if let focus, selected.contains(where: { $0 != focus }) {
                try tabSystem.raiseWindow(focus, activate: false)
            }
            var previousFrames: [WindowID: BTRect] = [:]
            var previousSamples: [WindowID: BTRect] = [:]
            var previousHiddenFrames: [WindowID: BTRect] = [:]
            // Frames settle within four samples. Activation can take longer,
            // so accepted frames keep waiting for focus instead of rolling back.
            for attempt in 0..<12 {
                guard isCurrent(), !Task.isCancelled else {
                    return touched ? .degraded(reason: "The desktop changed during Tabbed placement. Return to that desktop and use Repair Tabbed.") : .failed(reason: "The desktop changed.")
                }
                let actual = Dictionary(uniqueKeysWithValues: try snapshots(ids: ids).map { ($0.id, $0.frame) })
                // An application that resizes in steps settles just short of
                // the request. Once that frame is stable it is accepted; the
                // curtain covers the remainder of the pane.
                let framesMatch = placements.allSatisfy { placement in
                    guard let frame = actual[placement.windowID] else { return false }
                    switch SteppedSizeAcceptance.evaluate(requested: placement.frame, actual: frame) {
                    case .exact: return true
                    case .stepped: return previousSamples[placement.windowID]?.approximatelyEquals(frame, tolerance: 0.5) == true
                    case .rejected: return false
                    }
                }
                previousSamples = actual
                let focusMatches = try focus == nil || system.focusedWindow()?.id == focus
                if framesMatch && focusMatches {
                    // Hidden writes are best effort, but a transient partial
                    // resize is not evidence of a minimum. Only mismatches
                    // need another sample; ordinary accepted frames return now.
                    let hiddenFrames = onSizeMismatch == nil ? []
                        : ((try? snapshots(ids: Set(changedBestEffort.map(\.windowID)))) ?? [])
                    var unsettledHidden = false
                    for window in hiddenFrames {
                        guard let placement = changedBestEffort.first(where: { $0.windowID == window.id }),
                              let before = bestEffortBaseline[window.id],
                              !window.frame.approximatelyEquals(placement.frame, tolerance: 2) else { continue }
                        if attempt >= 3, previousHiddenFrames[window.id]?.approximatelyEquals(window.frame, tolerance: 1) == true {
                            onSizeMismatch?(window.id, placement.frame, before, window.frame)
                        } else {
                            unsettledHidden = true
                        }
                    }
                    previousHiddenFrames = Dictionary(uniqueKeysWithValues: hiddenFrames.map { ($0.id, $0.frame) })
                    if unsettledHidden, attempt < 3 {
                        try await Task.sleep(for: .milliseconds(50))
                        continue
                    }
                    expectSteppedFrames(placements, actual: actual)
                    return .applied
                }
                if framesMatch {
                    // The window was raised and its frame accepted. A focus
                    // that never arrives is left to the focus observer.
                    if attempt == 11 {
                        expectSteppedFrames(placements, actual: actual)
                        return .applied
                    }
                    try await Task.sleep(for: .milliseconds(50))
                    continue
                }
                // Stable size refusals in either axis can inform a retry.
                // Report before rollback loses the evidence.
                if attempt == 3, focusMatches, placements.allSatisfy({ placement in
                    guard let frame = actual[placement.windowID] else { return false }
                    return previousFrames[placement.windowID]?.approximatelyEquals(frame, tolerance: 1) == true
                }) {
                    for placement in placements {
                        if let frame = actual[placement.windowID], let before = baseline[placement.windowID] {
                            onSizeMismatch?(placement.windowID, placement.frame, before, frame)
                        }
                    }
                }
                previousFrames = actual
                if attempt >= 3 { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            throw WindowSystemError.operationFailed("A window did not accept its Tabbed size. Choose a larger pane or try Repair Tabbed.")
        } catch {
            guard isCurrent() else { return .degraded(reason: "The desktop changed before Tabbed could restore its windows.") }
            guard let participantDisplayID else { return .failed(reason: error.localizedDescription) }
            let restoration = await restoreTabbedFrames(
                baseline.merging(bestEffortBaseline) { before, _ in before }, required: ids.union(rollbackRequired ?? []),
                on: participantDisplayID, isCurrent: isCurrent)
            guard isCurrent(), !Task.isCancelled else {
                return .degraded(reason: "The desktop changed before Tabbed could restore its windows.")
            }
            var failed = !restoration.isApplied
            if touched {
                for id in previousSelected { do { try tabSystem.raiseWindow(id, activate: false) } catch { failed = true } }
                if let oldFocus, ids.contains(oldFocus) || previousSelected.contains(oldFocus) {
                    // Reactivate only if focus moved, so a rollback never takes
                    // focus from BetterTile or an app it cannot read.
                    let needsFocus = (try? system.focusedWindow()?.id) != oldFocus
                    do { try tabSystem.raiseWindow(oldFocus, activate: needsFocus) } catch { failed = true }
                }
            }
            let restored = (try? snapshots(ids: ids)) ?? []
            if baseline.contains(where: { id, frame in !restored.contains { $0.id == id && $0.frame.approximatelyEquals(frame, tolerance: 2) } }) { failed = true }
            return failed ? .degraded(reason: "Tabbed could not fully restore the previous arrangement. Use Repair Tabbed or switch to Native.") : .failed(reason: error.localizedDescription)
        }
    }

    /// Restores Tabbed stacking without moving a window, activating an app,
    /// or changing keyboard focus. Raises in the given order, back to front.
    public func raiseTabbedWindows(_ ids: [WindowID]) -> WindowMutationOutcome {
        guard let tabSystem = system as? any TabbedWindowSystem else {
            return .failed(reason: "This window system does not support Tabbed actions.")
        }
        var failed = false
        for id in ids {
            do { try tabSystem.raiseWindow(id, activate: false) } catch { failed = true }
        }
        return failed ? .failed(reason: "Tabbed could not restore window order. Select the tab again or use Repair Tabbed.") : .applied
    }

    /// Raises a selected tab and gives it keyboard focus.
    public func focusTabbedWindow(_ id: WindowID) -> WindowMutationOutcome {
        guard let tabSystem = system as? any TabbedWindowSystem else {
            return .failed(reason: "This window system does not support Tabbed actions.")
        }
        do {
            try tabSystem.raiseWindow(id, activate: true)
            return .applied
        } catch {
            return .failed(reason: error.localizedDescription)
        }
    }

    public func closeTabbedWindow(_ id: WindowID) -> WindowMutationOutcome {
        guard let tabSystem = system as? any TabbedWindowSystem else { return .failed(reason: "Window closure is unavailable.") }
        do { try tabSystem.requestCloseWindow(id); return .applied }
        catch { return .failed(reason: error.localizedDescription) }
    }
}
