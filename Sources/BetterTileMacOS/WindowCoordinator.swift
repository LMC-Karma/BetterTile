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

public struct WindowFrameTransaction: Sendable {
    public let id: UUID
    public let baselineFrames: [WindowID: BTRect]
    public fileprivate(set) var proposedPlacements: [Placement]
    public fileprivate(set) var lastAppliedFrames: [WindowID: BTRect]
    public fileprivate(set) var hasLiveChanges: Bool

    fileprivate init(baselineFrames: [WindowID: BTRect]) {
        id = UUID()
        self.baselineFrames = baselineFrames
        proposedPlacements = baselineFrames.map { Placement(windowID: $0.key, frame: $0.value) }.sorted { $0.windowID < $1.windowID }
        lastAppliedFrames = baselineFrames
        hasLiveChanges = false
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
    public private(set) var lastError: String?
    /// True only when a failed multi-window apply could not return every
    /// already-written window to its baseline frame.
    public private(set) var lastApplyWasDegraded = false

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

    @discardableResult
    public func perform(_ requestedAction: WindowAction) -> Bool {
        guard let plan = plan(requestedAction) else { return false }
        return perform(plan)
    }

    public func plan(_ requestedAction: WindowAction) -> WindowActionPlan? {
        do {
            guard let window = try system.focusedWindow(), window.isEligible else { return nil }
            let displays = system.displays()
            guard let display = displays.first(where: { $0.id == window.displayID }) else { return nil }
            let action = cycledAction(for: requestedAction, windowID: window.id)
            let target: BTRect?
            if action.isRestore {
                target = history.restore(for: window.id)
            } else if action.isDisplayTransfer {
                target = transferTarget(for: action, window: window, displays: displays)
            } else {
                target = actionEngine.targetFrame(for: action, window: window, display: display)
            }
            guard let target else { return nil }
            lastError = nil
            return WindowActionPlan(
                requestedAction: requestedAction,
                resolvedAction: action,
                windowID: window.id,
                displayID: window.displayID,
                sourceFrame: window.frame,
                targetFrame: target
            )
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    @discardableResult
    public func perform(_ plan: WindowActionPlan) -> Bool {
        do {
            if !plan.resolvedAction.isRestore {
                history.record(plan.sourceFrame, for: plan.windowID)
            }
            try apply(plan.targetFrame, to: plan.windowID, knownCurrentFrame: plan.sourceFrame)
            lastError = nil
            return true
        } catch {
            lastError = error.localizedDescription
            return false
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

    @discardableResult
    public func applyCustomZone(
        _ zone: CustomZone,
        applicationRules: ApplicationRuleSet
    ) -> Bool {
        do {
            guard let window = try system.focusedWindow(), window.isEligible else { return false }
            guard applicationRules
                .rule(for: window.bundleIdentifier)
                .allowsDirectPlacement
            else {
                lastError = "BetterTile is set to ignore this app."
                return false
            }
            guard let display = system.displays().first(where: { $0.id == window.displayID }) else { return false }
            history.record(window.frame, for: window.id)
            try apply(
                zone.rect.frame(in: display.visibleFrame),
                to: window.id,
                knownCurrentFrame: window.frame
            )
            lastError = nil
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    @discardableResult
    public func applyPlacements(_ placements: [Placement], recordHistory: Bool = true) -> Bool {
        lastApplyWasDegraded = false
        guard var transaction = beginTransaction(windowIDs: Set(placements.map(\.windowID))) else { return false }
        return commit(transaction: &transaction, placements: placements, recordHistory: recordHistory)
    }

    /// Verifies a completed system-driven reflow and retries only windows
    /// whose Accessibility frames did not settle at the requested values.
    public func settleAuthoritativePlacements(
        _ placements: [Placement],
        maximumRetries: Int = 2,
        retryDelay: Duration = .milliseconds(100),
        tolerance: Double = 1
    ) async -> Bool {
        lastApplyWasDegraded = false
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
                return false
            }

            let actualFrames: [WindowID: BTRect]
            do {
                actualFrames = Dictionary(uniqueKeysWithValues: try snapshots(
                    ids: Set(placements.map(\.windowID))
                ).map { ($0.id, $0.frame) })
            } catch {
                finishExpectedMutations(upTo: terminalGenerations)
                lastError = error.localizedDescription
                return false
            }
            let pending = placements.filter {
                actualFrames[$0.windowID]?.approximatelyEquals($0.frame, tolerance: tolerance) != true
            }
            if pending.isEmpty {
                finishExpectedMutations(upTo: terminalGenerations)
                lastError = nil
                return true
            }
            guard attempt < retryLimit, applyPlacements(pending, recordHistory: false) else {
                finishExpectedMutations(upTo: terminalGenerations)
                lastError = "One or more windows did not settle at the requested frame."
                return false
            }
            for placement in pending {
                terminalGenerations[placement.windowID] = mutationGeneration(for: placement.windowID)
            }
        }
        return false
    }

    public func beginTransaction(windowIDs: Set<WindowID>) -> WindowFrameTransaction? {
        do {
            let snapshots = Dictionary(uniqueKeysWithValues: try snapshots(ids: windowIDs).map { ($0.id, $0) })
            guard !windowIDs.isEmpty, windowIDs.allSatisfy({ snapshots[$0]?.isEligible == true }) else {
                lastError = "One or more windows are no longer eligible."
                return nil
            }
            let baseline = Dictionary(uniqueKeysWithValues: windowIDs.compactMap { id in snapshots[id].map { (id, $0.frame) } })
            guard baseline.count == windowIDs.count else { return nil }
            lastError = nil
            return WindowFrameTransaction(baselineFrames: baseline)
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    @discardableResult
    public func preview(transaction: inout WindowFrameTransaction, placements: [Placement]) -> Bool {
        guard Set(placements.map(\.windowID)) == Set(transaction.baselineFrames.keys) else {
            lastError = "The preview no longer matches the active window transaction."
            return false
        }
        transaction.proposedPlacements = placements.sorted { $0.windowID < $1.windowID }
        return true
    }

    @discardableResult
    public func commit(
        transaction: inout WindowFrameTransaction,
        placements: [Placement]? = nil,
        recordHistory: Bool = true
    ) -> Bool {
        lastApplyWasDegraded = false
        if let placements, !preview(transaction: &transaction, placements: placements) { return false }
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
            lastError = nil
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    @discardableResult
    public func applyLive(transaction: inout WindowFrameTransaction, placements: [Placement]) -> Bool {
        lastApplyWasDegraded = false
        guard preview(transaction: &transaction, placements: placements) else { return false }
        do {
            try validate(transaction.proposedPlacements)
            try applyAtomically(transaction.proposedPlacements, rollbackFrames: transaction.lastAppliedFrames)
            transaction.lastAppliedFrames = Dictionary(uniqueKeysWithValues: placements.map { ($0.windowID, $0.frame) })
            transaction.hasLiveChanges = true
            lastError = nil
            return true
        } catch {
            lastError = error.localizedDescription
            return false
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

    @discardableResult
    public func cancel(transaction: WindowFrameTransaction) -> Bool {
        let recoveryRequired = transaction.hasLiveChanges || lastApplyWasDegraded
        lastApplyWasDegraded = false
        guard recoveryRequired else {
            lastError = nil
            return true
        }
        do {
            try applyAtomically(
                transaction.baselineFrames.map { Placement(windowID: $0.key, frame: $0.value) },
                rollbackFrames: transaction.lastAppliedFrames
            )
            lastError = nil
            return true
        } catch {
            lastApplyWasDegraded = true
            lastError = "The divider change failed and the previous layout could not be fully restored."
            return false
        }
    }

    /// Applies a focus drop as one best-effort atomic operation. If any
    /// minimize request fails, every already-minimized window is restored and
    /// the source returns to its mouse-down frame.
    @discardableResult
    public func applyFocusDrop(
        placement: Placement,
        minimizing windowIDs: Set<WindowID>,
        sourceBaselineFrame: BTRect
    ) -> Bool {
        lastApplyWasDegraded = false
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
            lastError = nil
            return true
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
            lastApplyWasDegraded = rollbackFailed
            lastError = rollbackFailed
                ? "The focus drop failed and the previous layout could not be fully restored."
                : error.localizedDescription
            return false
        }
    }

    @discardableResult
    public func applyBento(state: BentoLayoutState, displayID: DisplayID) -> Bool {
        do {
            let windows = try system.visibleWindows()
            guard let display = system.displays().first(where: { $0.id == displayID }) else { return false }
            return applyPlacements(BentoLayoutEngine(state: state).placements(for: windows, in: display))
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    @discardableResult
    public func applyLinkedResize(windowID: WindowID, edge: WindowEdge, delta: Double, tolerance: Double = 6, locked: Set<WindowID> = []) -> LinkedResizeResult? {
        do {
            let windows = try system.visibleWindows()
            guard let window = windows.first(where: { $0.id == windowID }),
                  let display = system.displays().first(where: { $0.id == window.displayID }),
                  let result = LinkedResizeEngine(tolerance: tolerance).resize(windowID: windowID, edge: edge, delta: delta, windows: windows, bounds: display.visibleFrame, lockedWindowIDs: locked)
            else { return nil }
            return applyPlacements(result.placements) ? result : nil
        } catch {
            lastError = error.localizedDescription
            return nil
        }
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
                lastApplyWasDegraded = true
                throw WindowSystemError.operationFailed(
                    "A window update failed and the previous layout could not be fully restored."
                )
            }
            throw error
        }
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
