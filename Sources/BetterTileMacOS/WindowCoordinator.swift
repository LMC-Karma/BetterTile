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

    #if DEBUG
    public var arrivalTrace = ArrivalTrace.shared
    #endif

    private let clock: BetterTileClock
    public let system: any WindowSystem & ApplicationActivating & ApplicationWindowRequesting
    /// Sizes that windows kept when a failed batch asked for less, read before the rollback hides them.
    /// Saved Layouts uses them to name the window that refused its pane.
    public private(set) var refusedSizes: [WindowID: BTSize] = [:]
    public func resetRefusedSizes() { refusedSizes = [:] }
    public var actionEngine: StandardActionEngine

    /// Marks an apply whose rollback also failed, so callers can distinguish a
    /// cleanly reverted failure from windows left in a mixed state.
    private struct DegradedApplyError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private var history: FrameHistory
    private var generations: [WindowID: UInt64] = [:]
    private var nextWriteGeneration: UInt64 = 0
    private var frameWriteFailureGenerations: [WindowID: UInt64] = [:]
    /// Advances only when a dispatched frame write fails, never on an owner refusal.
    public func frameWriteFailureGeneration(for windowID: WindowID) -> UInt64 {
        frameWriteFailureGenerations[windowID, default: 0]
    }
    private var rollbackWriteFailureGenerations: [WindowID: UInt64] = [:]
    /// Separates an actual failed rollback write from deferred recovery.
    public func rollbackWriteFailureGeneration(for windowID: WindowID) -> UInt64 {
        rollbackWriteFailureGenerations[windowID, default: 0]
    }
    private var expectedMutations: [WindowID: [ExpectedMutation]] = [:]
    private var lastCycle: (windowID: WindowID, requestedAction: WindowAction, index: Int, date: Date)?
    /// Repeating a half shortcut within this many seconds cycles to the next
    /// size. Tests on a loaded runner lengthen it.
    public var shortcutCycleInterval: TimeInterval = 2

    public init(system: any WindowSystem & ApplicationActivating & ApplicationWindowRequesting, historyCapacity: Int = 10, actionEngine: StandardActionEngine = StandardActionEngine(), clock: BetterTileClock = .live) {
        self.system = system
        self.clock = clock
        self.history = FrameHistory(capacity: historyCapacity)
        self.actionEngine = actionEngine
    }

    /// A restored desktop adopts a new screen's geometry. Old-screen Restore
    /// steps and shortcut cycles must not move its windows back there.
    public func discardHistory(for windowIDs: Set<WindowID>) {
        for id in windowIDs { history.remove(windowID: id) }
        if let lastCycle, windowIDs.contains(lastCycle.windowID) { self.lastCycle = nil }
    }

    /// Retires only a window whose closure the window system confirmed.
    public func removeClosedWindow(_ windowID: WindowID) {
        #if DEBUG
        arrivalTrace.removeClosedWindow(windowID)
        #endif
        history.remove(windowID: windowID)
        generations.removeValue(forKey: windowID)
        rollbackWriteFailureGenerations.removeValue(forKey: windowID)
        frameWriteFailureGenerations.removeValue(forKey: windowID)
        expectedMutations.removeValue(forKey: windowID)
        lastPlacementBaselineFrames.removeValue(forKey: windowID)
        if lastCycle?.windowID == windowID { lastCycle = nil }
    }

    struct RetainedWindowState: Equatable {
        var historyFrames: Int
        var hasGeneration: Bool
        var expectedMutations: Int
        var hasBaseline: Bool
        var hasShortcutCycle: Bool
    }

    var retainedWindowKeyCounts: (generations: Int, expectations: Int, baselines: Int) {
        (generations.count, expectedMutations.count, lastPlacementBaselineFrames.count)
    }

    func retainedState(for windowID: WindowID) -> RetainedWindowState {
        RetainedWindowState(
            historyFrames: history.count(for: windowID),
            hasGeneration: generations[windowID] != nil,
            expectedMutations: expectedMutations[windowID]?.count ?? 0,
            hasBaseline: lastPlacementBaselineFrames[windowID] != nil,
            hasShortcutCycle: lastCycle?.windowID == windowID
        )
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
        // History stores absolute frames. A disconnected or rearranged display
        // can make an earlier position unreachable even after planning succeeds.
        if restoringHistory, !PlacementBounds.isHistoryRestoreReachable(
            plan.targetFrame, in: system.displays().map(\.frame)
        ) {
            return .failed(reason: "The previous window position is off screen.")
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
            try? await clock.sleep(for: delay)
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

    /// The latest write token for this window. Used to tell a delayed check
    /// that its action has been superseded.
    public func mutationGeneration(for windowID: WindowID) -> UInt64 {
        generations[windowID] ?? 0
    }

    /// - Parameter destination: The display a window drag dropped on. Drag
    ///   releases pass it; other callers validate on each window's display.
    /// - Parameter displayDestinations: Explicit destinations for request-owned transfers.
    ///   The caller validates identity and visible desktop membership before every write.
    public func applyPlacements(
        _ placements: [Placement],
        recordHistory: Bool = true,
        destination: DropDestination? = nil,
        displayDestinations: [WindowID: DisplayID] = [:]
    ) -> WindowMutationOutcome {
        place(placements, recordHistory: recordHistory, destination: destination,
              displayDestinations: displayDestinations, validation: nil)
    }

    /// A guarded batch validates before and after dispatch. Opt into serial
    /// per-write validation when ownership can change inside a frame batch.
    /// - Parameter canRestore: Optional desktop ownership for restoration after
    ///   the forward request ends. Without it, rollback uses the forward guard.
    public func applyPlacements(
        _ placements: [Placement],
        recordHistory: Bool = true,
        destination: DropDestination? = nil,
        displayDestinations: [WindowID: DisplayID] = [:],
        rollbackValidating canRestore: (() -> Bool)? = nil,
        revalidateBeforeEachWrite: Bool = false,
        onFinalValidationFailure: (() -> Void)? = nil,
        validating isCurrent: () -> Bool
    ) -> WindowMutationOutcome {
        withoutActuallyEscaping(isCurrent) { validation in
            place(placements, recordHistory: recordHistory, destination: destination,
                  displayDestinations: displayDestinations, validation: validation, rollbackValidation: canRestore, revalidateBeforeEachWrite: revalidateBeforeEachWrite, onFinalValidationFailure: onFinalValidationFailure)
        }
    }

    private func place(
        _ placements: [Placement], recordHistory: Bool, destination: DropDestination?,
        displayDestinations: [WindowID: DisplayID], validation: (() -> Bool)?,
        rollbackValidation: (() -> Bool)? = nil, revalidateBeforeEachWrite: Bool = false,
        onFinalValidationFailure: (() -> Void)? = nil
    ) -> WindowMutationOutcome {
        switch beginTransaction(windowIDs: Set(placements.map(\.windowID))) {
        case let .failed(reason):
            return .failed(reason: reason)
        case var .started(transaction):
            return commitFrames(transaction: &transaction, placements: placements, recordHistory: recordHistory,
                                destination: destination, displayDestinations: displayDestinations,
                                isDisplayTransfer: false, validation: validation, rollbackValidation: rollbackValidation, revalidateBeforeEachWrite: revalidateBeforeEachWrite, onFinalValidationFailure: onFinalValidationFailure)
        }
    }

    /// The frames the most recent committed placement started from. A
    /// follow-up write in the same user action records undo history against
    /// these, not against the frames the first write left.
    public private(set) var lastPlacementBaselineFrames: [WindowID: BTRect] = [:]

    /// Records undo frames for windows a follow-up write moved.
    public func recordHistory(_ frames: [WindowID: BTRect]) {
        recordHistoryFrames(frames)
    }

    public enum SettlementFailure: String, Sendable {
        case interrupted, superseded, windowRead, ownership, overlap, frames, retryFailed, retryDegraded
    }

    /// Verifies a completed system-driven reflow and retries only windows
    /// whose Accessibility frames did not settle at the requested values.
    /// Two points allow observed fractional-frame readback differences.
    public func settleAuthoritativePlacements(
        _ placements: [Placement],
        since ownedGenerations: [WindowID: UInt64]? = nil,
        maximumRetries: Int = 2,
        retryDelay: Duration = .milliseconds(100),
        tolerance: Double = 2,
        floatingWindowIDs: Set<WindowID> = [],
        revalidateBeforeEachWrite: Bool = false,
        didRetry: ([WindowID: UInt64]) -> Void = { _ in },
        onFailure: ((SettlementFailure) -> Void)? = nil,
        validating isCurrent: () -> Bool = { true }
    ) async -> WindowMutationOutcome {
        let unsettled = "One or more windows did not settle at the requested frame."
        let retryLimit = max(0, maximumRetries)
        let windowIDs = Set(placements.map(\.windowID))
        var terminalGenerations = ownedGenerations ?? Dictionary(uniqueKeysWithValues: windowIDs.map {
            ($0, mutationGeneration(for: $0))
        })
        for attempt in 0...retryLimit {
            do {
                try await clock.sleep(for: retryDelay)
            } catch {
                finishExpectedMutations(upTo: terminalGenerations)
                onFailure?(.interrupted)
                return .failed(reason: "The settlement check was interrupted.")
            }

            guard terminalGenerations.allSatisfy({ mutationGeneration(for: $0.key) == $0.value }) else {
                finishExpectedMutations(upTo: terminalGenerations)
                onFailure?(.superseded)
                return .failed(reason: "The settlement check was superseded.")
            }
            let actualFrames: [WindowID: BTRect]
            do {
                actualFrames = Dictionary(uniqueKeysWithValues: try snapshots(
                    ids: Set(placements.map(\.windowID))
                ).map { ($0.id, $0.frame) })
            } catch {
                finishExpectedMutations(upTo: terminalGenerations)
                onFailure?(.windowRead)
                return .failed(reason: error.localizedDescription)
            }
            guard isCurrent() else {
                finishExpectedMutations(upTo: terminalGenerations)
                onFailure?(.ownership)
                return .failed(reason: "The desktop changed before settlement.")
            }
            let pending = placements.filter {
                actualFrames[$0.windowID]?.approximatelyEquals($0.frame, tolerance: tolerance) != true
            }
            if pending.isEmpty {
                let tiledFrames = actualFrames.filter { !floatingWindowIDs.contains($0.key) }
                #if DEBUG
                if arrivalTrace.isEnabled, BentoLayoutVerifier.overlappingWindowIDs(tiledFrames).isEmpty {
                    arrivalTrace.settled(frames: actualFrames)
                }
                #endif
                finishExpectedMutations(upTo: terminalGenerations)
                guard BentoLayoutVerifier.overlappingWindowIDs(tiledFrames).isEmpty else {
                    onFailure?(.overlap)
                    return .failed(reason: unsettled)
                }
                return .applied
            }
            guard attempt < retryLimit else {
                finishExpectedMutations(upTo: terminalGenerations)
                onFailure?(.frames)
                return .failed(reason: unsettled)
            }
            switch applyPlacements(pending, recordHistory: false, revalidateBeforeEachWrite: revalidateBeforeEachWrite, validating: isCurrent) {
            case .applied:
                for placement in pending {
                    terminalGenerations[placement.windowID] = mutationGeneration(for: placement.windowID)
                }
                didRetry(terminalGenerations)
            case .failed:
                finishExpectedMutations(upTo: terminalGenerations)
                onFailure?(.retryFailed)
                return .failed(reason: unsettled)
            case let .degraded(reason):
                // The inner reason survives: windows were left in a mixed
                // arrangement, which is worse news than "not yet settled".
                finishExpectedMutations(upTo: terminalGenerations)
                onFailure?(.retryDegraded)
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

    /// - Parameter isDisplayTransfer: Prepare destination panes before arrival,
    ///   then close the source gap, within the same rollback-capable mutation.
    public func commit(
        transaction: inout WindowFrameTransaction,
        placements: [Placement]? = nil,
        recordHistory: Bool = true,
        destination: DropDestination? = nil,
        displayDestinations: [WindowID: DisplayID] = [:],
        isDisplayTransfer: Bool = false
    ) -> WindowMutationOutcome {
        commitFrames(transaction: &transaction, placements: placements, recordHistory: recordHistory,
                     destination: destination, displayDestinations: displayDestinations,
                     isDisplayTransfer: isDisplayTransfer, validation: nil)
    }

    public func commit(
        transaction: inout WindowFrameTransaction,
        placements: [Placement]? = nil,
        recordHistory: Bool = true,
        destination: DropDestination? = nil,
        displayDestinations: [WindowID: DisplayID] = [:],
        isDisplayTransfer: Bool = false,
        revalidateBeforeEachWrite: Bool = false,
        validating isCurrent: () -> Bool
    ) -> WindowMutationOutcome {
        withoutActuallyEscaping(isCurrent) { validation in
            commitFrames(transaction: &transaction, placements: placements, recordHistory: recordHistory,
                         destination: destination, displayDestinations: displayDestinations,
                         isDisplayTransfer: isDisplayTransfer, validation: validation, revalidateBeforeEachWrite: revalidateBeforeEachWrite)
        }
    }

    private func commitFrames(
        transaction: inout WindowFrameTransaction, placements: [Placement]?, recordHistory: Bool,
        destination: DropDestination?, displayDestinations: [WindowID: DisplayID],
        isDisplayTransfer: Bool, validation: (() -> Bool)?, rollbackValidation: (() -> Bool)? = nil,
        revalidateBeforeEachWrite: Bool = false,
        onFinalValidationFailure: (() -> Void)? = nil
    ) -> WindowMutationOutcome {
        lastPlacementBaselineFrames = transaction.baselineFrames
        if let placements, case let .failed(reason) = preview(transaction: &transaction, placements: placements) {
            return .failed(reason: reason)
        }
        do {
            try validate(transaction.proposedPlacements, destination: destination, displayDestinations: displayDestinations)
            guard validation?() != false else { return .failed(reason: "The layout changed before placement.") }
            // A corrective commit starts from the frames an earlier commit
            // wrote, so shrink-before-grow compares against those.
            try applyAtomically(transaction.proposedPlacements, rollbackFrames: transaction.baselineFrames,
                                currentFrames: transaction.lastAppliedFrames,
                                transfer: isDisplayTransfer ? destination : nil, validating: validation,
                                rollbackValidating: rollbackValidation, revalidateBeforeEachWrite: revalidateBeforeEachWrite, onFinalValidationFailure: onFinalValidationFailure)
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
    /// Returns the frames it added, for `discardHistory(_:)`.
    @discardableResult
    public func recordHistory(of transaction: WindowFrameTransaction) -> [WindowID: BTRect] {
        recordChangedHistoryFrames(transaction.baselineFrames, proposedPlacements: transaction.proposedPlacements)
    }

    /// Removes Restore steps that `recordHistory(of:)` added, when the change
    /// they undo was rolled back without Restore. A step is removed only
    /// while it is still the newest one for its window.
    public func discardHistory(_ frames: [WindowID: BTRect]) {
        for (id, frame) in frames { history.removeLast(frame, for: id) }
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
            // A window held by a refusing neighbour waits for that
            // neighbour's next readback, which only a write refreshes.
            var held = false
            if !validateParticipants {
                // Within a drag tick, shrinking windows take the new sample
                // and growing windows take the previous one. All applications
                // are still written in one concurrent pass, but a growing
                // window only enters space its neighbour gave up a tick
                // earlier, so the two do not overlap while that neighbour
                // commits. A neighbour that refused its last size holds only
                // the growing windows that would overlap it.
                let previous = transaction.lastAppliedFrames
                let shrinkingIDs = Set(changed.filter { placement in
                    guard let old = previous[placement.windowID] else { return false }
                    return placement.frame.size.width < old.size.width - 0.5
                        || placement.frame.size.height < old.size.height - 0.5
                }.map(\.windowID))
                let growing = changed.filter { !shrinkingIDs.contains($0.windowID) }
                if !changed.isEmpty {
                    let refused = refusedFrames(transaction: transaction, excluding: Set(growing.map(\.windowID)))
                    func isHeld(_ frame: BTRect) -> Bool {
                        refused.contains { Self.overlaps(frame, $0) }
                    }
                    writes = changed.compactMap { placement in
                        if shrinkingIDs.contains(placement.windowID) {
                            // A window can shrink on one axis and grow on the
                            // other at a junction. Its growing axis trails
                            // like any growing window.
                            guard let old = previous[placement.windowID] else { return placement }
                            let held = isHeld(placement.frame) ? old : (previousProposal[placement.windowID] ?? old)
                            let frame = Self.trailingGrowth(placement.frame, from: old, held: held)
                            if !frame.approximatelyEquals(placement.frame, tolerance: 0.01) { trailing = true }
                            return Placement(windowID: placement.windowID, frame: frame)
                        }
                        if isHeld(placement.frame) { held = true; return nil }
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
            // A tick that wrote nothing leaves a held window's inputs
            // unchanged, so another tick without a new sample cannot
            // release it. It waits for the next sample or the release.
            transaction.hasTrailingWrites = trailing || (held && !writes.isEmpty)
            transaction.hasLiveChanges = true
            transaction.hasDegradedApply = false
            return .applied
        } catch {
            // The rejected tick rolled back. The next pointer sample retries
            // it; a still pointer must not resend it every display tick.
            transaction.hasTrailingWrites = false
            return applyFailureOutcome(for: error, transaction: &transaction)
        }
    }

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

    /// The read-back frames of windows other than `excluding` that have not
    /// given up their space: each read back larger than the size it was sent.
    private func refusedFrames(transaction: WindowFrameTransaction, excluding: Set<WindowID>) -> [BTRect] {
        let candidates = transaction.lastAppliedFrames.filter { !excluding.contains($0.key) && transaction.baselineFrames[$0.key] != $0.value }
        guard !candidates.isEmpty else { return [] }
        func refused(_ actual: BTRect, sent: BTRect) -> Bool {
            actual.size.width > sent.size.width + 2 || actual.size.height > sent.size.height + 2
        }
        var frames: [BTRect] = []
        var unread = Set<WindowID>()
        for (id, sent) in candidates {
            if let actual = system.measuredFrameAfterWrite(for: id) {
                if refused(actual, sent: sent) { frames.append(actual) }
            } else {
                unread.insert(id)
            }
        }
        if !unread.isEmpty, let read = try? snapshots(ids: unread) {
            for snapshot in read {
                if let sent = candidates[snapshot.id], refused(snapshot.frame, sent: sent) { frames.append(snapshot.frame) }
            }
        }
        return frames
    }

    /// True when the two frames share more than a 2 pt sliver on both axes.
    static func overlaps(_ a: BTRect, _ b: BTRect) -> Bool {
        min(a.maxX, b.maxX) - max(a.minX, b.minX) > 2 && min(a.maxY, b.maxY) - max(a.minY, b.minY) > 2
    }

    /// Returns the frames it added to the history, for `discardHistory(_:)`.
    @discardableResult
    public func finishLive(transaction: WindowFrameTransaction, recordHistory: Bool = true) -> [WindowID: BTRect] {
        guard recordHistory, transaction.hasLiveChanges else { return [:] }
        return recordChangedHistoryFrames(
            transaction.baselineFrames,
            proposedPlacements: transaction.proposedPlacements
        )
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
                transaction.baselineFrames.filter { generations[$0.key] != nil }
                    .map { Placement(windowID: $0.key, frame: $0.value) },
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
        sourceBaselineFrame: BTRect,
        destination: DropDestination? = nil,
        validating isCurrent: () -> Bool = { true }
    ) -> WindowMutationOutcome {
        var minimized: [WindowID] = []
        var sourceWriteAttempted = false
        var sourceWriteCompleted = false
        do {
            try validate([placement], destination: destination)
            try system.preflightFrameWrites(windowIDs)
            guard isCurrent() else { return .failed(reason: "The layout changed before the focus drop.") }
            sourceWriteAttempted = true
            try apply(placement.frame, to: placement.windowID, knownCurrentFrame: sourceBaselineFrame)
            sourceWriteCompleted = true
            for windowID in windowIDs.sorted() {
                guard isCurrent() else { throw WindowSystemError.operationFailed("The desktop changed during the focus drop.") }
                try system.setMinimized(true, for: windowID)
                minimized.append(windowID)
            }
            guard isCurrent() else { throw WindowSystemError.operationFailed("The desktop changed during the focus drop.") }
            if !sourceBaselineFrame.approximatelyEquals(placement.frame, tolerance: 0.01) {
                history.record(sourceBaselineFrame, for: placement.windowID)
            }
            return .applied
        } catch {
            guard sourceWriteAttempted else { return .failed(reason: error.localizedDescription) }
            let degraded = WindowMutationOutcome.degraded(reason: "The focus drop failed and the previous layout could not be fully restored.")
            var rollbackFailed = false
            for windowID in minimized.reversed() {
                guard isCurrent() else { return degraded }
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
                guard isCurrent() else { return degraded }
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
    public func probeMinimumSizes(
        for windowIDs: Set<WindowID>, validating isCurrent: () -> Bool = { true }
    ) -> WindowMutationOutcome {
        guard !windowIDs.isEmpty, let probing = system as? any MinimumSizeProbing else { return .applied }
        // The probe is BetterTile's own write. Its frame events end at each
        // window's current frame and must not read as an external change.
        let probeSnapshots = (try? snapshots(ids: windowIDs)) ?? []
        guard isCurrent() else {
            return .failed(reason: "The layout changed before minimum-size measurement.")
        }
        var probeGenerations: [WindowID: UInt64] = [:]
        for snapshot in probeSnapshots {
            let generation = allocateGeneration(for: snapshot.id)
            probeGenerations[snapshot.id] = generation
            expect(snapshot.frame, for: snapshot.id, generation: generation)
        }
        #if DEBUG
        if arrivalTrace.isEnabled {
            for window in probeSnapshots { arrivalTrace.record("minimum_probe_started", pid: window.processIdentifier, windowID: window.id) }
        }
        #endif
        let outcome = probing.probeMinimumSizes(for: windowIDs, validating: isCurrent)
        let unrestored = outcome.unrestoredWindowIDs
        #if DEBUG
        if arrivalTrace.isEnabled {
            for window in probeSnapshots { arrivalTrace.record("minimum_probe_finished", pid: window.processIdentifier,
                windowID: window.id, outcome: unrestored.contains(window.id) ? "restore_failed" : "restored") }
        }
        #endif
        // A window left at another size has not returned to that frame.
        for id in unrestored.union(Set(probeGenerations.keys).subtracting(outcome.startedWindowIDs)) {
            if let generation = probeGenerations[id] { cancelExpectedMutation(for: id, generation: generation) }
        }
        guard unrestored.isEmpty else {
            return .degraded(reason: "A new window did not return to its size after BetterTile measured it.")
        }
        return outcome.wasInterrupted
            ? .failed(reason: "The desktop changed during minimum-size measurement.") : .applied
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
        let generation = allocateGeneration(for: windowID)
        guard generations[windowID] == generation else { return }
        expect(frame, for: windowID, generation: generation)
        do {
            #if DEBUG
            if arrivalTrace.isEnabled { arrivalTrace.willWrite(Placement(windowID: windowID, frame: frame)) }
            #endif
            try system.setFrame(frame, knownCurrentFrame: knownCurrentFrame, for: windowID)
        } catch {
            frameWriteFailureGenerations[windowID, default: 0] &+= 1
            cancelExpectedMutation(for: windowID, generation: generation)
            throw error
        }
    }

    /// - Parameter destination: The dragged window of a drop is checked on
    ///   the display the overlay showed the drop on. Its own display is
    ///   wherever its center happens to be, often the neighbouring display at
    ///   a shared edge. Every other window keeps its own display, so a window
    ///   an application moved to another display is still rejected.
    private func validate(
        _ placements: [Placement],
        sizeTolerance: Double = 0,
        destination: DropDestination? = nil,
        displayDestinations: [WindowID: DisplayID] = [:]
    ) throws {
        let ids = Set(placements.map(\.windowID))
        let snapshots = Dictionary(uniqueKeysWithValues: try snapshots(ids: ids).map { ($0.id, $0) })
        let displays = Dictionary(uniqueKeysWithValues: system.displays().map { ($0.id, $0) })
        if let destination, displays[destination.displayID] == nil {
            throw WindowSystemError.operationFailed("The display of the drop is no longer available.")
        }
        guard displayDestinations.values.allSatisfy({ displays[$0] != nil }) else {
            throw WindowSystemError.operationFailed("A placement display is no longer available.")
        }
        for placement in placements {
            guard let snapshot = snapshots[placement.windowID] else { throw WindowSystemError.windowNotFound(placement.windowID) }
            // A fixed-size window can still be moved at its own size.
            let keepsSize = abs(placement.frame.size.width - snapshot.frame.size.width) <= 1
                && abs(placement.frame.size.height - snapshot.frame.size.height) <= 1
            guard snapshot.isEligible, snapshot.constraints.isMovable,
                  snapshot.constraints.isResizable || keepsSize else {
                throw WindowSystemError.unsupportedWindow(placement.windowID)
            }
            let isDropSource = destination?.sourceWindowID == placement.windowID
            // The overlay planned a drop with the minimums it knew. A minimum
            // read again at release must not veto that frame. A seed is
            // another window's minimum; the write shows this window's own.
            let minimumSize = destination?.minimumSizes[placement.windowID]
                ?? (snapshot.constraints.minimumSizeSource == .seed
                    ? snapshot.constraints.unseededMinimumSize ?? .zero : snapshot.constraints.minimumSize)
            if snapshot.constraints.isResizable {
                guard placement.frame.size.width + sizeTolerance >= minimumSize.width,
                      placement.frame.size.height + sizeTolerance >= minimumSize.height
                else { throw WindowSystemError.operationFailed("A window reached its minimum size.") }
            }
            // A legal size is not enough: a stale display frame or a split
            // driven to an edge can produce a placement that leaves nothing on
            // screen to grab.
            if let display = displays[displayDestinations[placement.windowID]
                ?? (isDropSource ? destination?.displayID ?? snapshot.displayID : snapshot.displayID)],
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
        intermediate: Bool = false,
        transfer: DropDestination? = nil,
        validating isCurrent: (() -> Bool)? = nil,
        rollbackValidating canRestore: (() -> Bool)? = nil,
        revalidateBeforeEachWrite: Bool = false,
        onFinalValidationFailure: (() -> Void)? = nil
    ) throws {
        guard !placements.isEmpty else { return }
        let known = currentFrames ?? rollbackFrames
        if intermediate {
            // Gesture samples go to every application at once; a rejected
            // sample restores the previous sample's frames.
            try system.withFrameWriteBatch {
                var generationsWritten: [WindowID: UInt64] = [:]
                for placement in placements {
                    let generation = allocateGeneration(for: placement.windowID)
                    generationsWritten[placement.windowID] = generation
                    expect(placement.frame, for: placement.windowID, generation: generation)
                }
                do {
                    try system.setIntermediateFrames(placements, knownCurrentFrames: known)
                } catch let notStarted as FrameWritesNotStarted {
                    // Nothing was written, so there is nothing to roll back.
                    // A held application must not turn a skipped sample into
                    // a failed rollback; the next sample tries again.
                    for (id, generation) in generationsWritten { cancelExpectedMutation(for: id, generation: generation) }
                    throw notStarted.underlying
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
                        do {
                            try apply(frame, to: placement.windowID, knownCurrentFrame: placement.frame)
                        } catch where system.isApplicationUnresponsive(for: placement.windowID) {
                            // A drag sample is rewritten by the next tick or
                            // the release once the application answers, so a
                            // held window is skipped, not a failed rollback.
                        } catch { rollbackFailed = true }
                    }
                    if rollbackFailed {
                        throw DegradedApplyError(message: "A window update failed and the previous layout could not be fully restored.")
                    }
                    throw error
                }
            }
            return
        }
        refusedSizes = [:] // Each batch reports only its own refusals.
        try system.withFrameWriteBatch {
            var attempted: [WindowID] = []
            var failedWindowID: WindowID?
            var generationsWritten: [WindowID: UInt64] = [:]
            do {
                // Shrink before growing, so a growing window never covers a
                // neighbour that has not yet made room.
                let before = currentFrames ?? rollbackFrames
                func shrinks(_ placement: Placement) -> Bool {
                    guard let old = before[placement.windowID] else { return false }
                    return placement.frame.size.width < old.size.width - 0.5
                        || placement.frame.size.height < old.size.height - 0.5
                }
                let ordered = placements.sorted(by: { lhs, rhs in
                    let left = shrinks(lhs), right = shrinks(rhs)
                    return left != right ? left : lhs.windowID < rhs.windowID
                })
                // Different applications are written at once, so the layout
                // lands together: the adapter writes every application's
                // shrinking windows, then the growing ones. One application's
                // windows keep this order.
                for placement in ordered {
                    let generation = allocateGeneration(for: placement.windowID)
                    generationsWritten[placement.windowID] = generation
                    expect(placement.frame, for: placement.windowID, generation: generation)
                }
                var passes = [ordered]
                if let transfer, let display = system.displays().first(where: { $0.id == transfer.displayID }) {
                    // Make room before crossing, then close the source gap.
                    // A transfer can shrink too, so shrink-first alone cannot
                    // order it safely against destination applications.
                    let peers = ordered.filter { $0.windowID != transfer.sourceWindowID }
                    passes = [
                        peers.filter { PlacementBounds.isContained($0.frame, in: display.visibleFrame) },
                        ordered.filter { $0.windowID == transfer.sourceWindowID },
                        peers.filter { !PlacementBounds.isContained($0.frame, in: display.visibleFrame) }
                    ]
                }
                // Only callers with changing ownership opt into serial dispatch.
                // Preflight the entire batch before its first write, including
                // responsiveness and current AX movability in the adapter.
                if revalidateBeforeEachWrite {
                    try system.preflightFrameWrites(Set(ordered.map(\.windowID)))
                    passes = passes.flatMap { $0.map { [$0] } }
                }
                for pass in passes where !pass.isEmpty {
                    guard isCurrent?() != false else {
                        throw WindowSystemError.operationFailed("The desktop changed during placement.")
                    }
                    #if DEBUG
                    if arrivalTrace.isEnabled { for placement in pass { arrivalTrace.willWrite(placement) } }
                    #endif
                    let result = system.setFrames(pass, knownCurrentFrames: known)
                    attempted.append(contentsOf: result.attempted)
                    if let failure = result.failure {
                        frameWriteFailureGenerations[failure.windowID, default: 0] &+= 1
                        failedWindowID = failure.windowID
                        if let generation = generationsWritten[failure.windowID] {
                            cancelExpectedMutation(for: failure.windowID, generation: generation)
                        }
                        // Read the failing window before rolling back earlier passes.
                        if attempted.contains(failure.windowID) {
                            attempted.removeAll { $0 == failure.windowID }
                            attempted.append(failure.windowID)
                        }
                        throw failure.error
                    }
                    if let transfer, pass.first?.windowID == transfer.sourceWindowID,
                       let target = pass.first?.frame {
                        // Size readback can lag or settle in cell steps. Only
                        // the origin must land before the source gives up room.
                        let moved = try snapshots(ids: [transfer.sourceWindowID]).first
                        guard let moved,
                              abs(moved.frame.minX - target.minX) <= 2,
                              abs(moved.frame.minY - target.minY) <= 2 else {
                            throw WindowSystemError.operationFailed("The window did not move where it was asked to.")
                        }
                    }
                }
                guard isCurrent?() != false else {
                    onFinalValidationFailure?()
                    throw WindowSystemError.operationFailed("The desktop changed during placement.")
                }
            } catch {
                for id in Set(placements.map(\.windowID)).subtracting(attempted) {
                    if let generation = generationsWritten[id] { cancelExpectedMutation(for: id, generation: generation) }
                }
                // A size write can succeed before a position write fails, and
                // a concurrent batch can fail in several applications. Read
                // every attempted window; an unread one gets the full
                // restoring write sequence.
                let actualFrames = Dictionary(
                    ((try? snapshots(ids: Set(attempted))) ?? []).map { ($0.id, $0.frame) },
                    uniquingKeysWith: { first, _ in first }
                )
                // Several applications can fail in one batch. A window that
                // did not reach its frame expects no event for it.
                let requested = Dictionary(placements.map { ($0.windowID, $0.frame) }, uniquingKeysWith: { _, last in last })
                for (id, actual) in actualFrames {
                    // A window whose own write failed was not resized, so it kept nothing.
                    guard let asked = requested[id], id != failedWindowID, attempted.contains(id) else { continue }
                    if actual.size.width > asked.size.width + 2 || actual.size.height > asked.size.height + 2 {
                        refusedSizes[id] = actual.size
                    }
                }
                for id in attempted where actualFrames[id].map({ frame in
                    requested[id].map { !frame.approximatelyEquals($0, tolerance: 2) } ?? false
                }) == true {
                    if let generation = generationsWritten[id] { cancelExpectedMutation(for: id, generation: generation) }
                }
                var rollbackFailures: [WindowID] = []
                for id in attempted.reversed() {
                    guard canRestore?() ?? isCurrent?() ?? true else {
                        throw DegradedApplyError(message: "The desktop changed before the previous layout could be fully restored. Use Repair Layout.")
                    }
                    guard let frame = rollbackFrames[id] else { continue }
                    if id == failedWindowID, actualFrames[id]?.approximatelyEquals(frame, tolerance: 0.01) == true { continue }
                    do {
                        try apply(frame, to: id, knownCurrentFrame: actualFrames[id])
                    } catch {
                        rollbackWriteFailureGenerations[id, default: 0] &+= 1
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
        let snapshots: [WindowSnapshot]
        if let targeted = system as? any TargetedWindowSystem {
            snapshots = try targeted.windowSnapshots(ids: ids)
        } else {
            snapshots = try system.visibleWindows().filter { ids.contains($0.id) }
        }
        #if DEBUG
        arrivalTrace.observe(snapshots)
        #endif
        return snapshots
    }

    @discardableResult
    private func recordHistoryFrames(_ frames: [WindowID: BTRect]) -> [WindowID: BTRect] {
        var recorded: [WindowID: BTRect] = [:]
        for (id, frame) in frames.sorted(by: { $0.key < $1.key }) where generations[id] != nil && history.record(frame, for: id) {
            recorded[id] = frame
        }
        return recorded
    }

    @discardableResult
    private func recordChangedHistoryFrames(
        _ baselineFrames: [WindowID: BTRect],
        proposedPlacements: [Placement]
    ) -> [WindowID: BTRect] {
        let proposedFrames = Dictionary(uniqueKeysWithValues: proposedPlacements.map { ($0.windowID, $0.frame) })
        let changed = baselineFrames.filter { id, baseline in
            guard let proposed = proposedFrames[id] else { return false }
            return !baseline.approximatelyEquals(proposed, tolerance: 0.01)
        }
        return recordHistoryFrames(changed)
    }

    private func allocateGeneration(for windowID: WindowID) -> UInt64 {
        nextWriteGeneration &+= 1
        generations[windowID] = nextWriteGeneration
        return nextWriteGeneration
    }

    private func expect(_ frame: BTRect, for windowID: WindowID, generation: UInt64) {
        expectedMutations[windowID, default: []].append(ExpectedMutation(frame: frame, generation: generation))
    }

    /// A stepped frame accepted for a Tabbed placement is this placement's
    /// result too. Its events are expected; other near frames are not.
    private func expectSteppedFrames(_ placements: [Placement], actual: [WindowID: BTRect], allowsGrowth: Bool) {
        for placement in placements {
            guard let frame = actual[placement.windowID],
                  SteppedSizeAcceptance.evaluate(requested: placement.frame, actual: frame, allowsGrowth: allowsGrowth) == .stepped,
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
        if let lastCycle, lastCycle.windowID == windowID, lastCycle.requestedAction == requested, now.timeIntervalSince(lastCycle.date) < shortcutCycleInterval {
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
    /// - Parameter draggedWindowID: A dragged window whose center may have
    ///   crossed to another display. It is restored to this display anyway.
    /// - Parameter steppedWindowIDs: Windows known to resize in steps. Each
    ///   counts as restored within one step of its frame.
    /// - Parameter ignoresRequestCancellation: A separate desktop-owner predicate
    ///   authorizes restoring a cancelled request. Every write still checks it.
    public func restoreTabbedFrames(
        _ frames: [WindowID: BTRect], required: Set<WindowID>, on displayID: DisplayID,
        exempting draggedWindowID: WindowID? = nil, displayDestinations: [WindowID: DisplayID] = [:],
        steppedWindowIDs: Set<WindowID> = [],
        onRollbackFailure: (@MainActor () -> Void)? = nil,
        ignoresRequestCancellation: Bool = false,
        isCurrent: @MainActor () -> Bool
    ) async -> WindowMutationOutcome {
        let degraded = WindowMutationOutcome.degraded(reason: "Tabbed could not fully restore the previous arrangement. Use Repair Layout or switch to Manual.")
        guard isCurrent(), (ignoresRequestCancellation || !Task.isCancelled) else { return degraded }
        let displays = Dictionary(uniqueKeysWithValues: system.displays().map { ($0.id, $0) })
        guard let display = displays[displayID],
              displayDestinations.values.allSatisfy({ displays[$0] != nil }),
              let snapshots = try? snapshots(ids: Set(frames.keys)) else { return degraded }
        // Size hints can change after a resize. Bypass only those hints;
        // never write an unreadable, ineligible, or relocated participant.
        // A fixed-size window can be restored when its saved frame keeps its size.
        let current = Dictionary(snapshots.filter { snapshot in
            snapshot.isEligible && (snapshot.displayID == displayID || snapshot.id == draggedWindowID || displayDestinations[snapshot.id] != nil)
                && (snapshot.constraints.isResizable || frames[snapshot.id].map {
                    abs($0.size.width - snapshot.frame.size.width) <= 1 && abs($0.size.height - snapshot.frame.size.height) <= 1
                } == true)
                && frames[snapshot.id].map { frame in
                    PlacementBounds.isReachable(frame,
                        in: (displayDestinations[snapshot.id].flatMap { displays[$0] } ?? display).visibleFrame)
                } == true
        }.map { ($0.id, $0.frame) }, uniquingKeysWith: { first, _ in first })
        guard isCurrent(), (ignoresRequestCancellation || !Task.isCancelled), !required.isEmpty,
              required.isSubset(of: Set(current.keys)) else { return degraded }
        var failedWrite = false
        var observedMismatch = false
        func incompleteRestoration() -> WindowMutationOutcome {
            // A mismatching sample can still settle. Cancellation hands it to
            // newer work; only a rejected write proves failure at that point.
            if failedWrite || (observedMismatch && (ignoresRequestCancellation || !Task.isCancelled)) {
                onRollbackFailure?()
            }
            return degraded
        }
        system.withFrameWriteBatch {
            for (id, frame) in frames.sorted(by: { $0.key < $1.key })
                where current[id] != nil && current[id]?.approximatelyEquals(frame, tolerance: 1) != true {
                guard isCurrent(), (ignoresRequestCancellation || !Task.isCancelled) else { break }
                do { try apply(frame, to: id, knownCurrentFrame: current[id]) }
                catch { rollbackWriteFailureGenerations[id, default: 0] &+= 1; failedWrite = true }
            }
        }
        for attempt in 0..<4 {
            guard isCurrent(), (ignoresRequestCancellation || !Task.isCancelled),
                  let restored = try? self.snapshots(ids: required),
                  isCurrent(), (ignoresRequestCancellation || !Task.isCancelled) else { return incompleteRestoration() }
            if required.allSatisfy({ id in
                guard let frame = frames[id] else { return false }
                return restored.contains { $0.id == id && $0.isEligible
                    && ($0.displayID == (displayDestinations[id] ?? displayID) || $0.id == draggedWindowID)
                    && Self.isRestored($0.frame, to: frame, stepped: steppedWindowIDs.contains(id)) }
            }) { return .applied }
            observedMismatch = true
            guard attempt < 3 else { break }
            do {
                if ignoresRequestCancellation {
                    // Desktop ownership authorizes rollback after the forward
                    // task is cancelled. Its bounded wait must still advance.
                    let clock = self.clock
                    try await Task { try await clock.sleep(for: .milliseconds(50)) }.value
                } else {
                    try await clock.sleep(for: .milliseconds(50))
                }
            } catch { return incompleteRestoration() }
        }
        return incompleteRestoration()
    }

    /// A bounded frame/order transaction. Windows remain on-screen and are
    /// never minimized. Session validity is checked again after each await.
    /// - Parameter rollbackRequired: Previous selections that become hidden in
    ///   this proposal but must be verified again if the old layout is restored.
    /// - Parameter required: Windows whose frames must fit and settle. Other
    ///   placements (hidden tabs stacked behind their pane's selected tab) are
    ///   best effort: a refusal never fails the layout. Nil requires all.
    /// - Parameter acceptsSteppedGrowth: Also accept a window that settles up
    ///   to one resize step larger than requested, once it held that size for
    ///   the refusal delay. The caller then fits the panes to it.
    /// - Parameter onApplied: Receives the required windows' accepted frames
    ///   when the placement applies.
    /// - Parameter steppedWindowIDs: Windows known to resize in steps. A
    ///   rollback counts each as restored within one step of its frame.
    /// - Parameter destination: The display a window drag dropped on. Its
    ///   source window is a participant even when its center crossed to
    ///   another display during the gesture.
    /// - Parameter onRollbackFailure: Reports incomplete recovery separately
    ///   from cancellation that hands placement to newer work.
    public func applyTabbed(
        placements allPlacements: [Placement],
        rollbackFrames: [WindowID: BTRect]? = nil,
        rollbackDisplayID: DisplayID? = nil,
        rollbackRequired: Set<WindowID>? = nil,
        required: Set<WindowID>? = nil,
        selected: [WindowID],
        previousSelected: [WindowID],
        focus: WindowID?,
        allowingRaise: @MainActor () -> Bool = { true },
        focusAlreadyRequested: Bool = false,
        focusCheckpoint: WindowID? = nil,
        destination: DropDestination? = nil,
        displayDestinations: [WindowID: DisplayID] = [:],
        onSizeMismatch: (@MainActor (WindowID, BTRect, BTRect, BTRect) -> Void)? = nil,
        acceptsSteppedGrowth: Bool = false,
        onApplied: (@MainActor ([WindowID: BTRect]) -> Void)? = nil,
        steppedWindowIDs: Set<WindowID> = [],
        onRollbackFailure: (@MainActor () -> Void)? = nil,
        rollbackValidating canRestore: (@MainActor () -> Bool)? = nil,
        revalidateBeforeEachWrite: Bool = false,
        onFinalValidationFailure: (() -> Void)? = nil,
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
        var participantProcesses: [WindowID: Int32] = [:]
        var baselineDisplays: [WindowID: DisplayID] = [:]
        // A selection that raised its tab early knows the focus before it.
        let oldFocus = focusCheckpoint ?? (try? system.focusedWindow()?.id)
        do {
            guard ids == Set(placements.map(\.windowID)) else {
                throw WindowSystemError.operationFailed("One or more selected tabs are no longer available.")
            }
            try validate(placements, sizeTolerance: 0.001, destination: destination, displayDestinations: displayDestinations)
            let participants = try snapshots(ids: ids)
            let requestedSizes = Dictionary(uniqueKeysWithValues: placements.map { ($0.windowID, $0.frame.size) })
            guard isCurrent(), !Task.isCancelled,
                  participants.count == ids.count,
                  participants.allSatisfy({ participant in
                      let keepsSize = requestedSizes[participant.id].map {
                          abs($0.width - participant.frame.size.width) <= 1 && abs($0.height - participant.frame.size.height) <= 1
                      } ?? false
                      return participant.isEligible && (participant.constraints.isResizable || keepsSize)
                          && (rollbackDisplayID == nil || participant.displayID == rollbackDisplayID
                              || participant.id == destination?.sourceWindowID)
                  }) else {
                throw WindowSystemError.operationFailed("The Tabbed participants changed.")
            }
            participantDisplayID = rollbackDisplayID ?? destination?.displayID
                ?? participants.first(where: { displayDestinations[$0.id] == nil })?.displayID
                ?? participants.first.map { displayDestinations[$0.id] ?? $0.displayID }
            participantProcesses = Dictionary(participants.map { ($0.id, $0.processIdentifier) }) { first, _ in first }
            currentFrames = Dictionary(uniqueKeysWithValues: participants.map { ($0.id, $0.frame) })
            baselineDisplays = Dictionary(uniqueKeysWithValues: participants.filter { displayDestinations[$0.id] != nil }.map { ($0.id, $0.displayID) })
            // A resize has already changed real frames. Keep its verified
            // checkpoint for refusal evidence and rollback, not that partial
            // arrangement. Writes still compare against the current frames.
            baseline = currentFrames.merging(rollbackFrames?.filter { ids.contains($0.key) } ?? [:]) { _, checkpoint in checkpoint }
        } catch {
            if let rollbackFrames, let rollbackDisplayID {
                let restored = await restoreTabbedFrames(rollbackFrames, required: ids.union(rollbackRequired ?? []), on: rollbackDisplayID,
                                                         exempting: destination?.sourceWindowID, steppedWindowIDs: steppedWindowIDs,
                                                         onRollbackFailure: onRollbackFailure, isCurrent: isCurrent)
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
        guard isCurrent(), !Task.isCancelled else {
            return rollbackFrames == nil ? .failed(reason: "The desktop changed.")
                : .degraded(reason: "The desktop changed before Tabbed could restore its windows.")
        }
        var touched = false
        do {
            let changed = placements.filter { !(currentFrames[$0.windowID]?.approximatelyEquals($0.frame, tolerance: 0.5) ?? false) }
            touched = !changed.isEmpty || !changedBestEffort.isEmpty
            // A window that resizes in steps settles within one step of its
            // request; that size is its step, not a minimum to learn.
            try system.withSteppedSizes { try system.withFrameWriteBatch {
                try withoutActuallyEscaping(isCurrent) { validation in
                    try applyAtomically(changed, rollbackFrames: baseline, currentFrames: currentFrames,
                                        validating: { validation() && !Task.isCancelled }, rollbackValidating: canRestore,
                                        revalidateBeforeEachWrite: revalidateBeforeEachWrite, onFinalValidationFailure: onFinalValidationFailure)
                }
                for placement in changedBestEffort {
                    guard isCurrent(), !Task.isCancelled else {
                        throw WindowSystemError.operationFailed("The desktop changed during Tabbed placement.")
                    }
                    try? apply(placement.frame, to: placement.windowID, knownCurrentFrame: bestEffortCurrent[placement.windowID])
                }
            } }
            // Focus is requested only when it can change something. A raise
            // of any window of the front application takes focus from its
            // popup, which then closes, so no pane raises a window of it.
            guard isCurrent(), !Task.isCancelled else {
                if canRestore?() == true {
                    throw WindowSystemError.operationFailed("The Tabbed request ended before placement finished.")
                }
                return touched ? .degraded(reason: "The desktop changed during Tabbed placement. Return to that desktop and use Repair Layout.")
                    : .failed(reason: "The desktop changed.")
            }
            let popupProcess = popupHoldingProcess(in: tabSystem)
            let heldByPopup = { (id: WindowID) in popupProcess != nil && participantProcesses[id] == popupProcess }
            let permitsRaise = allowingRaise()
            let focus = permitsRaise ? focus.flatMap { heldByPopup($0) ? nil : $0 } : nil
            if let focus {
                guard isCurrent(), !Task.isCancelled else { throw WindowSystemError.operationFailed("The desktop changed.") }
                touched = true
                // A selection may already have requested focus when it was
                // pressed. Ask again only for the window order, so a slow
                // application does not receive a second activation. When the
                // selection is unchanged, a window that already has focus is
                // only ordered.
                let keepsFocus = Set(selected) == Set(previousSelected)
                    && tabbedWindowHasFocus(focus, process: participantProcesses[focus], in: tabSystem)
                try tabSystem.raiseWindow(focus, activate: !focusAlreadyRequested && !keepsFocus)
            }
            for id in selected where permitsRaise && id != focus && !heldByPopup(id) {
                guard isCurrent(), !Task.isCancelled else { throw WindowSystemError.operationFailed("The desktop changed.") }
                touched = true
                try tabSystem.raiseWindow(id, activate: false)
            }
            // Activation already raised the focused tab. Raise it again only
            // when ordering another pane put a window in front of it.
            if let focus, selected.contains(where: { $0 != focus }) {
                guard isCurrent(), !Task.isCancelled else { throw WindowSystemError.operationFailed("The desktop changed.") }
                try tabSystem.raiseWindow(focus, activate: false)
            }
            var previousFrames: [WindowID: BTRect] = [:]
            var previousSamples: [WindowID: BTRect] = [:]
            var previousHiddenFrames: [WindowID: BTRect] = [:]
            // A size refusal is reported only once the minimum-size learner
            // can confirm a kept size, so an application that applies a size
            // late is not reported as refusing it.
            let written = clock.now
            // Timed at the sample read, so a stall after the read does not
            // age the sample.
            var sampledAt = written
            func refusalCanSettle(_ attempt: Int) -> Bool {
                attempt >= 3 && (attempt == 11
                    || sampledAt - written >= .seconds(WindowMinimumSizeLearner.clampConfirmationDelay))
            }
            // Frames settle within four samples. Activation can take longer,
            // so accepted frames keep waiting for focus instead of rolling back.
            for attempt in 0..<12 {
                guard isCurrent(), !Task.isCancelled else {
                    if canRestore?() == true {
                        throw WindowSystemError.operationFailed("The Tabbed request ended before placement finished.")
                    }
                    return touched ? .degraded(reason: "The desktop changed during Tabbed placement. Return to that desktop and use Repair Layout.") : .failed(reason: "The desktop changed.")
                }
                sampledAt = clock.now
                let actual = Dictionary(uniqueKeysWithValues: try snapshots(ids: ids).map { ($0.id, $0.frame) })
                // An application that resizes in steps settles just short of
                // the request. Once that frame is stable it is accepted; the
                // curtain covers the remainder of the pane. A larger frame
                // can also be a late size, so it waits for the refusal delay.
                let framesMatch = placements.allSatisfy { placement in
                    guard let frame = actual[placement.windowID] else { return false }
                    switch SteppedSizeAcceptance.evaluate(requested: placement.frame, actual: frame,
                                                          allowsGrowth: acceptsSteppedGrowth) {
                    case .exact: return true
                    case .stepped:
                        let grew = frame.size.width > placement.frame.size.width + 2
                            || frame.size.height > placement.frame.size.height + 2
                        return previousSamples[placement.windowID]?.approximatelyEquals(frame, tolerance: 0.5) == true
                            && (!grew || refusalCanSettle(attempt))
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
                        if refusalCanSettle(attempt), previousHiddenFrames[window.id]?.approximatelyEquals(window.frame, tolerance: 1) == true {
                            onSizeMismatch?(window.id, placement.frame, before, window.frame)
                        } else {
                            unsettledHidden = true
                        }
                    }
                    previousHiddenFrames = Dictionary(uniqueKeysWithValues: hiddenFrames.map { ($0.id, $0.frame) })
                    if unsettledHidden, !refusalCanSettle(attempt) {
                        try await clock.sleep(for: .milliseconds(50))
                        continue
                    }
                    expectSteppedFrames(placements, actual: actual, allowsGrowth: acceptsSteppedGrowth)
                    onApplied?(actual)
                    return .applied
                }
                if framesMatch {
                    // The window was raised and its frame accepted. A focus
                    // that never arrives is left to the focus observer.
                    if attempt == 11 {
                        expectSteppedFrames(placements, actual: actual, allowsGrowth: acceptsSteppedGrowth)
                        onApplied?(actual)
                        return .applied
                    }
                    try await clock.sleep(for: .milliseconds(50))
                    continue
                }
                // Stable size refusals in either axis can inform a retry.
                // Report before rollback loses the evidence.
                let settled = refusalCanSettle(attempt)
                if settled, focusMatches, placements.allSatisfy({ placement in
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
                if settled { break }
                try await clock.sleep(for: .milliseconds(50))
            }
            throw WindowSystemError.operationFailed("A window did not accept its Tabbed size. Choose a larger pane or try Repair Layout.")
        } catch {
            if error is DegradedApplyError { onRollbackFailure?() }
            guard canRestore?() ?? isCurrent() else {
                if !Task.isCancelled, !(error is CancellationError) { onRollbackFailure?() }
                return .degraded(reason: "The desktop changed before Tabbed could restore its windows.")
            }
            guard let participantDisplayID else { return .failed(reason: error.localizedDescription) }
            let restoration = await restoreTabbedFrames(
                baseline.merging(bestEffortBaseline) { before, _ in before }, required: ids.union(rollbackRequired ?? []),
                on: participantDisplayID, exempting: destination?.sourceWindowID, displayDestinations: baselineDisplays, steppedWindowIDs: steppedWindowIDs,
                onRollbackFailure: onRollbackFailure, ignoresRequestCancellation: canRestore != nil,
                isCurrent: { canRestore?() ?? isCurrent() })
            guard canRestore?() ?? isCurrent(), (canRestore != nil || !Task.isCancelled) else {
                if !restoration.isApplied, !Task.isCancelled, !(error is CancellationError) { onRollbackFailure?() }
                return .degraded(reason: "The desktop changed before Tabbed could restore its windows.")
            }
            var failed = !restoration.isApplied
            if touched {
                for id in previousSelected where allowingRaise() {
                    guard canRestore?() ?? isCurrent(), (canRestore != nil || !Task.isCancelled) else { failed = true; break }
                    do { try tabSystem.raiseWindow(id, activate: false) } catch { failed = true }
                }
                if (canRestore?() ?? isCurrent()), (canRestore != nil || !Task.isCancelled), allowingRaise(), let oldFocus, ids.contains(oldFocus) || previousSelected.contains(oldFocus) {
                    // Reactivate only if focus moved, so a rollback never takes
                    // focus from BetterTile or an app it cannot read.
                    let needsFocus = (try? system.focusedWindow()?.id) != oldFocus
                    do { try tabSystem.raiseWindow(oldFocus, activate: needsFocus) } catch { failed = true }
                }
            }
            let restored = (try? snapshots(ids: ids)) ?? []
            if baseline.contains(where: { id, frame in !restored.contains {
                $0.id == id && Self.isRestored($0.frame, to: frame, stepped: steppedWindowIDs.contains(id))
            } }) { failed = true }
            if failed { onRollbackFailure?() }
            return failed ? .degraded(reason: "Tabbed could not fully restore the previous arrangement. Use Repair Layout or switch to Manual.") : .failed(reason: error.localizedDescription)
        }
    }

    /// A window that resizes in steps lands within one step of its old frame.
    private static func isRestored(_ actual: BTRect, to frame: BTRect, stepped: Bool) -> Bool {
        stepped ? SteppedSizeAcceptance.evaluate(requested: frame, actual: actual, allowsGrowth: true) != .rejected
            : actual.approximatelyEquals(frame, tolerance: 2)
    }

    /// The frontmost application, when a transient popup has its focus.
    /// A standard window, a dialog, the desktop, or an unreadable focus can
    /// lose focus to a placement, as before. A popup that closes without
    /// focus keeps it, including one `focusedWindow()` could not read.
    func popupHoldingProcess(in tabSystem: any TabbedWindowSystem) -> Int32? {
        guard let process = tabSystem.frontmostProcessIdentifier,
              let reported = (try? system.focusedWindow()) ?? nil, reported.processIdentifier == process
        else { return nil }
        switch tabSystem.applicationFocus(of: reported) {
        case .confirmed: return tabSystem.isTransientPopup(reported) ? process : nil
        case .otherWindow(isTransientPopup: true): return process
        case .otherWindow, .noWindow, .unknown: return nil
        }
    }

    /// True when the window is its frontmost application's focused window.
    func tabbedWindowHasFocus(_ id: WindowID, process: Int32?, in tabSystem: any TabbedWindowSystem) -> Bool {
        guard let process, tabSystem.frontmostProcessIdentifier == process,
              let reported = (try? system.focusedWindow()) ?? nil, reported.id == id
        else { return false }
        return tabSystem.applicationFocus(of: reported) == .confirmed
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
        return failed ? .failed(reason: "Tabbed could not restore window order. Select the tab again or use Repair Layout.") : .applied
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
