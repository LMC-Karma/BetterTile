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
    public let system: any WindowSystem
    public var actionEngine: StandardActionEngine
    public private(set) var lastError: String?

    private var history: FrameHistory
    private var generations: [WindowID: UInt64] = [:]
    private var expectedMutations: [WindowID: (frame: BTRect, generation: UInt64, expiresAt: Date)] = [:]
    private var lastCycle: (windowID: WindowID, requestedAction: WindowAction, index: Int, date: Date)?

    public init(system: any WindowSystem, historyCapacity: Int = 10, actionEngine: StandardActionEngine = StandardActionEngine()) {
        self.system = system
        self.history = FrameHistory(capacity: historyCapacity)
        self.actionEngine = actionEngine
    }

    /// Consumes an Accessibility event caused by BetterTile itself. Events that
    /// do not match the latest expected frame remain available to the native
    /// resize adoption path.
    public func consumeExpectedMutation(windowID: WindowID, actualFrame: BTRect, tolerance: Double = 2) -> Bool {
        let now = Date()
        expectedMutations = expectedMutations.filter { $0.value.expiresAt > now }
        guard let expected = expectedMutations[windowID],
              actualFrame.approximatelyEquals(expected.frame, tolerance: tolerance)
        else { return false }
        expectedMutations.removeValue(forKey: windowID)
        return true
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
            try apply(plan.targetFrame, to: plan.windowID)
            lastError = nil
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    @discardableResult
    public func applyCustomZone(_ zone: CustomZone) -> Bool {
        do {
            guard let window = try system.focusedWindow(), window.isEligible,
                  let display = system.displays().first(where: { $0.id == window.displayID })
            else { return false }
            history.record(window.frame, for: window.id)
            try apply(zone.rect.frame(in: display.visibleFrame), to: window.id)
            lastError = nil
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    @discardableResult
    public func applyPlacements(_ placements: [Placement], recordHistory: Bool = true) -> Bool {
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
        let retryLimit = max(0, maximumRetries)
        for attempt in 0...retryLimit {
            do {
                try await Task.sleep(for: retryDelay)
            } catch {
                return false
            }

            let actualFrames: [WindowID: BTRect]
            do {
                actualFrames = Dictionary(uniqueKeysWithValues: try snapshots(
                    ids: Set(placements.map(\.windowID))
                ).map { ($0.id, $0.frame) })
            } catch {
                lastError = error.localizedDescription
                return false
            }
            let pending = placements.filter {
                actualFrames[$0.windowID]?.approximatelyEquals($0.frame, tolerance: tolerance) != true
            }
            if pending.isEmpty {
                lastError = nil
                return true
            }
            guard attempt < retryLimit,
                  applyPlacements(pending, recordHistory: false)
            else {
                lastError = "One or more windows did not settle at the requested frame."
                return false
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

    public func cancel(transaction: WindowFrameTransaction) {
        guard transaction.hasLiveChanges else { return }
        do {
            try applyAtomically(
                transaction.baselineFrames.map { Placement(windowID: $0.key, frame: $0.value) },
                rollbackFrames: transaction.lastAppliedFrames
            )
            lastError = nil
        } catch {
            lastError = error.localizedDescription
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
        var minimized: [WindowID] = []
        do {
            try validate([placement])
            try apply(placement.frame, to: placement.windowID)
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
            for windowID in minimized.reversed() {
                try? system.setMinimized(false, for: windowID)
            }
            try? apply(sourceBaselineFrame, to: placement.windowID)
            lastError = error.localizedDescription
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

    private func apply(_ frame: BTRect, to windowID: WindowID) throws {
        let generation = (generations[windowID] ?? 0) &+ 1
        generations[windowID] = generation
        guard generations[windowID] == generation else { return }
        expect(frame, for: windowID, generation: generation)
        try system.setFrame(frame, for: windowID)
    }

    private func validate(_ placements: [Placement]) throws {
        let ids = Set(placements.map(\.windowID))
        let snapshots = Dictionary(uniqueKeysWithValues: try snapshots(ids: ids).map { ($0.id, $0) })
        for placement in placements {
            guard let snapshot = snapshots[placement.windowID] else { throw WindowSystemError.windowNotFound(placement.windowID) }
            guard snapshot.isEligible, snapshot.constraints.isMovable, snapshot.constraints.isResizable else {
                throw WindowSystemError.unsupportedWindow(placement.windowID)
            }
            guard placement.frame.size.width >= snapshot.constraints.minimumSize.width,
                  placement.frame.size.height >= snapshot.constraints.minimumSize.height
            else { throw WindowSystemError.operationFailed("A window reached its minimum size.") }
        }
    }

    private func applyAtomically(_ placements: [Placement], rollbackFrames: [WindowID: BTRect]) throws {
        var applied: [WindowID] = []
        do {
            for placement in placements.sorted(by: { $0.windowID < $1.windowID }) {
                let generation = (generations[placement.windowID] ?? 0) &+ 1
                generations[placement.windowID] = generation
                expect(placement.frame, for: placement.windowID, generation: generation)
                try system.setFrame(placement.frame, for: placement.windowID)
                applied.append(placement.windowID)
            }
        } catch {
            for id in applied.reversed() {
                guard let frame = rollbackFrames[id] else { continue }
                let generation = (generations[id] ?? 0) &+ 1
                generations[id] = generation
                expect(frame, for: id, generation: generation)
                try? system.setFrame(frame, for: id)
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
        expectedMutations[windowID] = (frame, generation, Date().addingTimeInterval(0.5))
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
