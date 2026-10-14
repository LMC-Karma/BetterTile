import Foundation

public struct BentoResizeResult: Sendable {
    public var state: BentoLayoutState
    public var placements: [Placement]
    public var appliedCoordinates: [UUID: Double]

    public init(state: BentoLayoutState, placements: [Placement], appliedCoordinates: [UUID: Double]) {
        self.state = state
        self.placements = placements
        self.appliedCoordinates = appliedCoordinates
    }
}

/// Projects a Bento tree onto the nearest set of split weights that satisfies
/// every descendant minimum size. It never adjusts leaf frames independently,
/// so a successful result preserves the configured pane gaps by construction.
public struct BentoConstraintSolver: Sendable {
    public var tolerance: Double

    public init(tolerance: Double = 0.001) {
        self.tolerance = max(0, tolerance)
    }

    public func solve(
        state: BentoLayoutState,
        in bounds: BTRect,
        constraints: [WindowID: WindowConstraints] = [:]
    ) -> BentoLayoutState? {
        guard let root = state.root else { return state }
        let workingRoot = BentoLayoutState.normalized(root)
        let gap = state.metrics.paneGap
        let constraints = state.metrics.paneConstraints(constraints, for: workingRoot.windowIDs)

        func childRects(_ partition: BentoPartition, in rect: BTRect) -> [BTRect] {
            let extent = partition.axis == .vertical ? rect.size.width : rect.size.height
            let usable = max(0, extent - gap * Double(partition.children.count - 1))
            var cursor = partition.axis == .vertical ? rect.minX : rect.minY
            return partition.children.indices.map { index in
                let childExtent = index == partition.children.count - 1
                    ? (partition.axis == .vertical ? rect.maxX : rect.maxY) - cursor
                    : usable * partition.ratios[index]
                let child = partition.axis == .vertical
                    ? BTRect(x: cursor, y: rect.minY, width: max(0, childExtent), height: rect.size.height)
                    : BTRect(x: rect.minX, y: cursor, width: rect.size.width, height: max(0, childExtent))
                cursor += childExtent + gap
                return child
            }
        }

        let vacantMinimum = state.metrics.vacantMinimumSize
        func solveNode(_ node: BentoNode, rect: BTRect) -> BentoNode? {
            switch node {
            case .vacant:
                guard rect.size.width + tolerance >= vacantMinimum.width,
                      rect.size.height + tolerance >= vacantMinimum.height
                else { return nil }
                return node
            case let .leaf(id):
                let minimum = constraints[id]?.minimumSize ?? WindowConstraints().minimumSize
                guard rect.size.width + tolerance >= minimum.width,
                      rect.size.height + tolerance >= minimum.height
                else { return nil }
                return node
            case var .partition(partition):
                let extent = partition.axis == .vertical ? rect.size.width : rect.size.height
                let available = extent - gap * Double(partition.children.count - 1)
                let minimumExtents = partition.children.map {
                    BentoTreeGeometry.minimumExtent($0, axis: partition.axis, constraints: constraints, gap: gap,
                                                    vacantMinimum: vacantMinimum)
                }
                guard available > 0,
                      minimumExtents.reduce(0, +) <= available + tolerance
                else { return nil }

                let lowerBounds = minimumExtents.map { max(0, $0 / available) }
                let currentExtents = partition.ratios.map { $0 * available }
                if !zip(currentExtents, minimumExtents).allSatisfy({ $0 + tolerance >= $1 }) {
                    var ratios = partition.ratios
                    for index in ratios.indices where ratios[index] + tolerance / available < lowerBounds[index] {
                        // A locked boundary fixes the total extent on each side.
                        // Borrow only from children in the same unlocked run.
                        let start = partition.boundaryIDs.indices.last {
                            $0 < index && partition.lockedBoundaryIDs.contains(partition.boundaryIDs[$0])
                        }.map { $0 + 1 } ?? 0
                        let end = partition.boundaryIDs.indices.first {
                            $0 >= index && partition.lockedBoundaryIDs.contains(partition.boundaryIDs[$0])
                        }.map { $0 + 1 } ?? ratios.count
                        var deficit = lowerBounds[index] - ratios[index]
                        ratios[index] = lowerBounds[index]
                        for distance in 1..<ratios.count where deficit > tolerance / available {
                            for donor in [index - distance, index + distance]
                            where (start..<end).contains(donor) && deficit > tolerance / available {
                                let availableExcess = max(0, ratios[donor] - lowerBounds[donor])
                                let transfer = min(deficit, availableExcess)
                                ratios[donor] -= transfer
                                deficit -= transfer
                            }
                        }
                        guard deficit <= tolerance / available else { return nil }
                    }
                    partition.ratios = ratios
                }

                let rects = childRects(partition, in: rect)
                for index in partition.children.indices {
                    guard let child = solveNode(partition.children[index], rect: rects[index]) else { return nil }
                    partition.children[index] = child
                }
                return .partition(partition)
            }
        }

        guard let solvedRoot = solveNode(workingRoot, rect: bounds) else { return nil }
        var result = state
        result.root = BentoLayoutState.normalized(solvedRoot)
        return result
    }
}

/// Learns minimum sizes only from evidence: a requested shrink that stopped
/// at a larger size, or a kept size that is still there at least
/// `clampConfirmationDelay` after the write. Ordinary moves and expansions
/// are not application constraints, and neither is a size an application
/// applies within that delay.
public struct WindowMinimumSizeLearner: Sendable {
    /// How long a kept size must stay before any observation confirms it as
    /// a clamp. Chromium-style applications apply a new position at once and
    /// the new size later, usually within a few display frames, and a move to
    /// a display with another backing scale can report the old size for a
    /// moment. A size applied later than this is still learned; two smaller
    /// stable snapshots then lower it again.
    public static let clampConfirmationDelay = 0.25

    /// The axes of `actual` that prove a minimum at once: each shrank from
    /// `previous` toward `requested` and stopped short of it. Any other size
    /// larger than requested can be a size the application applies later.
    public static func provenMinimum(
        requested: BTSize,
        previous: BTSize,
        actual: BTSize,
        tolerance: Double = 2
    ) -> (width: Double?, height: Double?) {
        func axis(_ requested: Double, _ previous: Double, _ actual: Double) -> Double? {
            actual > requested + tolerance && actual < previous - tolerance ? actual : nil
        }
        return (axis(requested.width, previous.width, actual.width),
                axis(requested.height, previous.height, actual.height))
    }

    /// A window stayed larger than requested on an axis, and the readback
    /// could not tell a clamp from a size still to come. Each axis holds its
    /// kept length, or nil, and is confirmed or dropped on its own: the other
    /// axis can still take a late size.
    private struct ClampCandidate: Sendable {
        var requested: BTSize
        var width: Double?
        var height: Double?
        var observedAt: Double
    }

    public private(set) var learnedSizes: [WindowID: BTSize]
    private var smallerSizeCandidates: [WindowID: BTSize] = [:]
    private var clampCandidates: [WindowID: ClampCandidate] = [:]
    private var probedWindowIDs: Set<WindowID> = []
    /// Windows whose current measurement came from a size probe.
    private var probeMeasuredWindowIDs: Set<WindowID> = []
    /// The latest measurement for each application, by bundle identifier.
    /// Applications rarely report a minimum, so a new window starts from its
    /// application's measured size instead of the default floor. Its own
    /// measurement replaces the seed as soon as one exists. A seed lasts
    /// until its application quits. Only proven measurements become seeds.
    /// Process memory only; nothing is saved.
    public private(set) var applicationSizes: [String: BTSize] = [:]

    public init(learnedSizes: [WindowID: BTSize] = [:]) {
        self.learnedSizes = learnedSizes
    }

    /// Reads a settled frame after a write. A pending clamp that the settled
    /// frame still shows is confirmed, but only `clampConfirmationDelay`
    /// after its write; an earlier settled frame leaves it pending for a
    /// later observation. A measurement becomes the application's seed.
    @discardableResult
    public mutating func observe(
        windowID: WindowID,
        application: String? = nil,
        requested: BTRect,
        baseline: BTRect,
        actual: BTRect,
        now: Double,
        tolerance: Double = 2
    ) -> Bool {
        var changed = false
        if let candidate = clampCandidates[windowID],
           Self.sizesMatch(candidate.requested, requested.size, tolerance: tolerance) {
            changed = confirm(candidate, windowID: windowID, size: actual.size, now: now, tolerance: tolerance)
        }
        defer { if changed { rememberApplication(application, from: windowID) } }
        // An unchanged frame can be an ignored or queued write, not a minimum.
        guard !actual.approximatelyEquals(baseline, tolerance: tolerance) else { return changed }
        var learned = learnedSizes[windowID] ?? .zero
        let previous = learned
        var observedMinimum = false
        if requested.size.width + tolerance < baseline.size.width,
           actual.size.width > requested.size.width + tolerance,
           actual.size.width < baseline.size.width - tolerance {
            learned.width = max(learned.width, actual.size.width)
            observedMinimum = true
        }
        if requested.size.height + tolerance < baseline.size.height,
           actual.size.height > requested.size.height + tolerance,
           actual.size.height < baseline.size.height - tolerance {
            learned.height = max(learned.height, actual.size.height)
            observedMinimum = true
        }
        if observedMinimum { smallerSizeCandidates.removeValue(forKey: windowID) }
        guard learned != previous else { return changed }
        learnedSizes[windowID] = learned
        probeMeasuredWindowIDs.remove(windowID)
        changed = true
        return true
    }

    /// Two consecutive stable smaller sizes disprove an old learned bound.
    /// Reported application minimums are still merged by the caller.
    @discardableResult
    public mutating func observeAcceptedSize(windowID: WindowID, application: String?, size: BTSize) -> Bool {
        let lowered = observeAcceptedSize(windowID: windowID, size: size)
        if lowered { rememberApplication(application, from: windowID) }
        return lowered
    }

    @discardableResult
    public mutating func observeAcceptedSize(windowID: WindowID, size: BTSize) -> Bool {
        guard size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0,
              let previous = learnedSizes[windowID],
              size.width < previous.width || size.height < previous.height else {
            smallerSizeCandidates.removeValue(forKey: windowID)
            return false
        }
        let candidate = smallerSizeCandidates.updateValue(size, forKey: windowID)
        guard let candidate,
              abs(candidate.width - size.width) <= 1,
              abs(candidate.height - size.height) <= 1 else { return false }
        learnedSizes[windowID] = BTSize(
            width: min(previous.width, max(candidate.width, size.width)),
            height: min(previous.height, max(candidate.height, size.height))
        )
        smallerSizeCandidates.removeValue(forKey: windowID)
        probeMeasuredWindowIDs.remove(windowID)
        return true
    }

    /// Reads a frame straight after a write. The request must have been
    /// processed: either the window moved to the requested origin, or its
    /// size changed. A frame that ignored the write entirely proves nothing.
    ///
    /// An axis that shrank toward the request and stopped short of it is the
    /// minimum, measured now. Any other axis larger than requested proves
    /// nothing yet: the application can apply the size later, as Chromium
    /// does, or the window can still report its size from another display.
    /// That axis becomes a pending clamp; see `confirmClampCandidate`. A
    /// requested size that was accepted lowers an older, larger bound.
    ///
    /// `previousRequest` is the size the window's previous write asked for,
    /// when that write may still be applied late, as during a live gesture.
    /// A shrink is then measured from the smaller of the two on each axis: a
    /// readback that lags behind the requests and still lies above the
    /// previous request proves nothing.
    @discardableResult
    public mutating func observeWriteReadback(
        windowID: WindowID,
        application: String? = nil,
        requested: BTRect,
        previous: BTRect?,
        previousRequest: BTSize? = nil,
        actual: BTRect,
        now: Double,
        tolerance: Double = 2
    ) -> Bool {
        defer { rememberApplication(application, from: windowID) }
        clampCandidates.removeValue(forKey: windowID)
        guard WriteReadbackPolicy.readbackProvesWrite(
            requested: requested, previous: previous, actual: actual, tolerance: tolerance
        ), let previous else { return false }
        var before = previous.size
        if let previousRequest {
            before.width = min(before.width, previousRequest.width)
            before.height = min(before.height, previousRequest.height)
        }
        let kept = measure(windowID: windowID, requested: requested.size, previous: before,
                           actual: actual.size, tolerance: tolerance)
        if kept.learned { probeMeasuredWindowIDs.remove(windowID) }
        if kept.width || kept.height {
            clampCandidates[windowID] = ClampCandidate(
                requested: requested.size,
                width: kept.width ? actual.size.width : nil,
                height: kept.height ? actual.size.height : nil,
                observedAt: now
            )
        }
        return kept.learned
    }

    /// Reads a window straight after a probe wrote a 1×1 size at its origin.
    /// Only an axis that shrank and stopped short of the request is the
    /// minimum. A kept size is no evidence: the window can be at its minimum
    /// already, or its application can apply sizes late. The probe restores
    /// the size at once, so no later observation can confirm it either, and
    /// the window stays without a measurement.
    @discardableResult
    public mutating func observeProbe(
        windowID: WindowID,
        application: String? = nil,
        original: BTSize,
        clamped: BTSize,
        tolerance: Double = 2
    ) -> Bool {
        defer { rememberApplication(application, from: windowID) }
        clampCandidates.removeValue(forKey: windowID)
        let learned = measure(windowID: windowID, requested: BTSize(width: 1, height: 1), previous: original,
                              actual: clamped, tolerance: tolerance).learned
        if learned { probeMeasuredWindowIDs.insert(windowID) }
        return learned
    }

    /// Learns each axis that shrank toward the request and stopped short of
    /// it, and lowers a bound that an accepted size disproves. Returns
    /// whether a bound changed, and the axes that stayed larger than
    /// requested without that proof: they kept their size, or grew, which a
    /// late size from an earlier write can also do.
    private mutating func measure(
        windowID: WindowID,
        requested: BTSize,
        previous: BTSize,
        actual: BTSize,
        tolerance: Double
    ) -> (learned: Bool, width: Bool, height: Bool) {
        let before = learnedSizes[windowID]
        var learned = before ?? .zero
        let proven = Self.provenMinimum(requested: requested, previous: previous, actual: actual, tolerance: tolerance)
        func axis(_ requestedLength: Double, _ actualLength: Double, _ proven: Double?,
                  _ bound: inout Double) -> Bool {
            if let proven {
                bound = proven
                return false
            }
            if actualLength > requestedLength + tolerance { return true }
            if abs(actualLength - requestedLength) <= tolerance, bound > actualLength {
                bound = actualLength
            }
            return false
        }
        let keptWidth = axis(requested.width, actual.width, proven.width, &learned.width)
        let keptHeight = axis(requested.height, actual.height, proven.height, &learned.height)
        guard learned != (before ?? .zero) else { return (false, keptWidth, keptHeight) }
        if learned == .zero { learnedSizes.removeValue(forKey: windowID) } else { learnedSizes[windowID] = learned }
        smallerSizeCandidates.removeValue(forKey: windowID)
        return (true, keptWidth, keptHeight)
    }

    /// Records a kept size after a position nudge proved that the application
    /// handles writes, for a write that left the window where it was. The
    /// nudge proves the position, not the size: an application can follow a
    /// move at once and apply a size later. Each axis that stayed larger than
    /// requested becomes a pending clamp; see `confirmClampCandidate`.
    public mutating func recordClampCandidate(
        windowID: WindowID,
        requested: BTSize,
        actual: BTSize,
        now: Double,
        tolerance: Double = 2
    ) {
        let width = actual.width > requested.width + tolerance
        let height = actual.height > requested.height + tolerance
        guard width || height else { return }
        clampCandidates[windowID] = ClampCandidate(
            requested: requested,
            width: width ? actual.width : nil,
            height: height ? actual.height : nil,
            observedAt: now
        )
    }

    /// Checks a pending clamp against a later snapshot, axis by axis. A kept
    /// axis that the snapshot still shows at least `clampConfirmationDelay`
    /// after the write is the minimum, and the measurement becomes the
    /// application's seed. A kept axis with another length is dropped. An
    /// earlier snapshot leaves the axis pending.
    @discardableResult
    public mutating func confirmClampCandidate(
        windowID: WindowID,
        application: String? = nil,
        size: BTSize,
        now: Double,
        tolerance: Double = 2
    ) -> Bool {
        guard let candidate = clampCandidates[windowID] else { return false }
        let learned = confirm(candidate, windowID: windowID, size: size, now: now, tolerance: tolerance)
        if learned { rememberApplication(application, from: windowID) }
        return learned
    }

    /// Discards a pending clamp, for example because a newer write replaced
    /// the request it belonged to.
    public mutating func discardClampCandidate(for windowID: WindowID) {
        clampCandidates.removeValue(forKey: windowID)
    }

    /// Learns each kept axis that `size` still shows at least
    /// `clampConfirmationDelay` after the write, and drops each kept axis
    /// with another length. An axis seen earlier at its kept length stays
    /// pending. The candidate ends when no axis is pending.
    private mutating func confirm(
        _ candidate: ClampCandidate, windowID: WindowID, size: BTSize, now: Double, tolerance: Double
    ) -> Bool {
        let due = now - candidate.observedAt >= Self.clampConfirmationDelay
        var pending = candidate
        let before = learnedSizes[windowID] ?? .zero
        var learned = before
        func check(_ kept: inout Double?, _ observed: Double, _ bound: inout Double) {
            guard let length = kept else { return }
            if abs(length - observed) > tolerance {
                kept = nil
            } else if due {
                bound = length
                kept = nil
            }
        }
        check(&pending.width, size.width, &learned.width)
        check(&pending.height, size.height, &learned.height)
        if pending.width == nil, pending.height == nil {
            clampCandidates.removeValue(forKey: windowID)
        } else {
            clampCandidates[windowID] = pending
        }
        guard learned != before else { return false }
        learnedSizes[windowID] = learned
        smallerSizeCandidates.removeValue(forKey: windowID)
        probeMeasuredWindowIDs.remove(windowID)
        return true
    }

    private static func sizesMatch(_ lhs: BTSize, _ rhs: BTSize, tolerance: Double) -> Bool {
        abs(lhs.width - rhs.width) <= tolerance && abs(lhs.height - rhs.height) <= tolerance
    }

    private mutating func rememberApplication(_ application: String?, from windowID: WindowID) {
        guard let application, !application.isEmpty else { return }
        if let learned = learnedSizes[windowID] { applicationSizes[application] = learned }
    }

    /// The window's own measurement, or its application's seed when the
    /// window has none yet. The result names the source when the
    /// measurement or seed raised the minimum.
    public func merging(_ constraints: WindowConstraints, for windowID: WindowID, application: String?) -> WindowConstraints {
        guard learnedSizes[windowID] == nil, let application, let seed = applicationSizes[application] else {
            return merging(constraints, for: windowID)
        }
        var result = Self.raising(constraints, to: seed, source: .seed)
        if result.minimumSizeSource == .seed {
            result.unseededMinimumSize = constraints.minimumSize
            result.unseededMinimumSizeSource = constraints.minimumSizeSource
        }
        return result
    }

    public func merging(_ constraints: WindowConstraints, for windowID: WindowID) -> WindowConstraints {
        guard let learned = learnedSizes[windowID] else { return constraints }
        return Self.raising(constraints, to: learned,
                            source: probeMeasuredWindowIDs.contains(windowID) ? .probe : .learned)
    }

    private static func raising(_ constraints: WindowConstraints, to size: BTSize, source: MinimumSizeSource) -> WindowConstraints {
        var result = constraints
        if size.width > result.minimumSize.width || size.height > result.minimumSize.height {
            result.minimumSizeSource = source
        }
        result.minimumSize.width = max(result.minimumSize.width, size.width)
        result.minimumSize.height = max(result.minimumSize.height, size.height)
        return result
    }

    /// Forgets everything about a window that closed. A window ID that comes
    /// back is a new window and can be probed again.
    public mutating func remove(_ windowID: WindowID) {
        forget(windowID: windowID)
        probedWindowIDs.remove(windowID)
    }

    /// Forgets one window's measurement and its pending evidence, for example
    /// when a repair distrusts it. The window plans with its application's
    /// seed, if any, until a later write measures it again. It is not probed
    /// again, because a probe resizes a visible window.
    public mutating func forget(windowID: WindowID) {
        learnedSizes.removeValue(forKey: windowID)
        smallerSizeCandidates.removeValue(forKey: windowID)
        clampCandidates.removeValue(forKey: windowID)
        probeMeasuredWindowIDs.remove(windowID)
    }

    /// Drops one application's seed, for example when it quits. A relaunch,
    /// perhaps of an updated version, then measures its windows again.
    /// Measurements of individual windows stay.
    public mutating func forgetApplication(_ bundleIdentifier: String) {
        applicationSizes.removeValue(forKey: bundleIdentifier)
    }

    public func hasMeasurement(for windowID: WindowID) -> Bool { learnedSizes[windowID] != nil }

    /// Records that a probe wrote a tiny size to a window. A window is probed
    /// once: a window that kept its size gives no measurement, and probing it
    /// again would only resize it again.
    public mutating func recordProbe(of windowID: WindowID) {
        probedWindowIDs.insert(windowID)
    }

    /// The windows that still need their own measurement, in ID order. An
    /// application seed does not count: it came from another window of the
    /// same application, which can have a larger minimum. A window already
    /// probed is not probed again.
    public func windowsNeedingMeasurement(_ windowIDs: Set<WindowID>) -> [WindowID] {
        windowIDs.sorted().filter { !hasMeasurement(for: $0) && !probedWindowIDs.contains($0) }
    }

    /// Records the window's current measurement as its application's seed.
    public mutating func rememberApplication(_ application: String?, for windowID: WindowID) {
        rememberApplication(application, from: windowID)
    }
}

/// Resizes Bento split branches by changing tree weights, then deriving every
/// affected frame from the tree. This keeps nested layouts coherent.
public struct BentoResizeEngine: Sendable {
    public init() {}

    public func resize(
        state: BentoLayoutState,
        branchCoordinates: [UUID: Double],
        in bounds: BTRect,
        constraints: [WindowID: WindowConstraints] = [:]
    ) -> BentoResizeResult? {
        guard state.root != nil, !branchCoordinates.isEmpty,
              var next = BentoConstraintSolver().solve(state: state, in: bounds, constraints: constraints)
        else { return nil }

        // Junctions always contain orthogonal branches. Stable ordering makes
        // the operation deterministic while each coordinate remains absolute.
        for branchID in branchCoordinates.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard let requested = branchCoordinates[branchID], requested.isFinite,
                  next.setBoundaryCoordinate(requested, branchID: branchID, in: bounds)
            else { return nil }
            guard let solved = BentoConstraintSolver().solve(state: next, in: bounds, constraints: constraints) else { return nil }
            next = solved
        }

        let applied = Dictionary(uniqueKeysWithValues: branchCoordinates.keys.compactMap { id -> (UUID, Double)? in
            guard let geometry = BentoTreeGeometry.boundary(id, in: next, bounds: bounds) else { return nil }
            return (id, geometry.resolvedCoordinate)
        })

        return BentoResizeResult(
            state: next,
            placements: next.placements(in: bounds),
            appliedCoordinates: applied
        )
    }
}

/// Fits externally changed native window frames back into the Bento tree.
/// Changed windows are preferred so a single native edge drag is adopted even
/// before its neighbor has been reflowed.
public struct BentoLayoutFitter: Sendable {
    public var tolerance: Double

    public init(tolerance: Double = 6) {
        self.tolerance = max(0, tolerance)
    }

    public func fit(
        state: BentoLayoutState,
        currentFrames: [WindowID: BTRect],
        changedWindowIDs: Set<WindowID>,
        in bounds: BTRect,
        constraints: [WindowID: WindowConstraints] = [:]
    ) -> BentoResizeResult? {
        guard state.root != nil, !changedWindowIDs.isEmpty else { return nil }
        var next = state
        var allApplied: [UUID: Double] = [:]
        let originalFrames = Dictionary(uniqueKeysWithValues: state.placements(in: bounds).map { ($0.windowID, $0.frame) })

        // Parents first. Orthogonal descendants remain valid when an ancestor
        // changes; their own parent geometry is recalculated before fitting.
        for descriptor in state.branches.sorted(by: { $0.depth < $1.depth }) {
            guard let geometry = BentoTreeGeometry.boundary(descriptor.id, in: next, bounds: bounds),
                  !geometry.isLocked
            else { continue }
            let expectedCoordinate = geometry.resolvedCoordinate
            let halfGap = state.metrics.paneGap / 2
            // A lower window starts below its pane's content reserve.
            let reserve = state.metrics.contentTopInset
            var changedCandidates: [Double] = []

            for id in changedWindowIDs {
                guard let expected = originalFrames[id], let actual = currentFrames[id] else { continue }
                switch geometry.axis {
                case .vertical:
                    if geometry.before.windowIDs.contains(id), abs(expected.maxX + halfGap - expectedCoordinate) <= tolerance {
                        changedCandidates.append(actual.maxX + halfGap)
                    }
                    if geometry.after.windowIDs.contains(id), abs(expected.minX - halfGap - expectedCoordinate) <= tolerance {
                        changedCandidates.append(actual.minX - halfGap)
                    }
                case .horizontal:
                    if geometry.before.windowIDs.contains(id), abs(expected.maxY + halfGap - expectedCoordinate) <= tolerance {
                        changedCandidates.append(actual.maxY + halfGap)
                    }
                    if geometry.after.windowIDs.contains(id), abs(expected.minY - reserve - halfGap - expectedCoordinate) <= tolerance {
                        changedCandidates.append(actual.minY - reserve - halfGap)
                    }
                }
            }

            let coordinate: Double?
            if let furthest = changedCandidates.max(by: {
                abs($0 - expectedCoordinate) < abs($1 - expectedCoordinate)
            }) {
                // A corner resize can contribute two close candidates. If they
                // disagree, the edge that moved furthest from the old split is
                // the user-controlled edge.
                // Equally strong edges on opposite sides give no evidence for
                // either direction. Leave this boundary alone instead of letting
                // Set iteration order decide which windows move.
                let contradicts = changedCandidates.contains {
                    abs(abs($0 - expectedCoordinate) - abs(furthest - expectedCoordinate)) <= 0.5
                        && ($0 - expectedCoordinate) * (furthest - expectedCoordinate) < 0
                }
                coordinate = contradicts ? nil : furthest
            } else {
                coordinate = stableSharedCoordinate(for: geometry, frames: currentFrames, gap: state.metrics.paneGap, reserve: reserve)
            }

            guard let coordinate, abs(coordinate - expectedCoordinate) > 0.5,
                  let result = BentoResizeEngine().resize(
                    state: next,
                    branchCoordinates: [descriptor.id: coordinate],
                    in: bounds,
                    constraints: constraints
                  )
            else { continue }
            next = result.state
            allApplied.merge(result.appliedCoordinates) { _, latest in latest }
        }

        guard !allApplied.isEmpty else { return nil }
        return BentoResizeResult(
            state: next,
            placements: next.placements(in: bounds),
            appliedCoordinates: allApplied
        )
    }

    private func stableSharedCoordinate(
        for boundary: BentoTreeGeometry.BoundaryGeometry,
        frames: [WindowID: BTRect],
        gap: Double,
        reserve: Double
    ) -> Double? {
        let first = boundary.before.windowIDs.compactMap { frames[$0] }
        let second = boundary.after.windowIDs.compactMap { frames[$0] }
        guard !first.isEmpty, !second.isEmpty else { return nil }
        let firstEdge: Double
        let secondEdge: Double
        switch boundary.axis {
        case .vertical:
            firstEdge = first.map(\.maxX).max()!
            secondEdge = second.map(\.minX).min()!
        case .horizontal:
            firstEdge = first.map(\.maxY).max()!
            secondEdge = second.map(\.minY).min()! - reserve
        }
        guard abs(secondEdge - firstEdge - gap) <= tolerance else { return nil }
        return (firstEdge + secondEdge) / 2
    }
}

/// Resolves only shared edges that really exist in the current Accessibility
/// frames. The overlay therefore cannot drift into a window's interior when an
/// application clamps or delays a frame update.
public struct BentoBoundaryResolver: Sendable {
    public var tolerance: Double
    public var minimumSegmentLength: Double

    public init(tolerance: Double = 6, minimumSegmentLength: Double = 24) {
        self.tolerance = max(0, tolerance)
        self.minimumSegmentLength = max(1, minimumSegmentLength)
    }

    public func boundaries(
        state: BentoLayoutState,
        windows: [WindowSnapshot],
        displayID: DisplayID,
        bounds: BTRect
    ) -> [BoundaryDescriptor] {
        guard let root = state.root else { return [] }
        let normalizedRoot = BentoLayoutState.normalized(root)
        let frames = Dictionary(uniqueKeysWithValues: windows.map { ($0.id, $0.frame) })
        var output: [BoundaryDescriptor] = []

        func collect(_ node: BentoNode) {
            switch node {
            case .leaf, .vacant:
                return
            case let .partition(partition):
                for index in partition.boundaryIDs.indices {
                    let beforeNode = partition.children[index]
                    let afterNode = partition.children[index + 1]
                    let firstFrames = beforeNode.windowIDs.compactMap { id in frames[id].map { (id, $0) } }
                    let secondFrames = afterNode.windowIDs.compactMap { id in frames[id].map { (id, $0) } }
                    let parent = boundingRect((firstFrames + secondFrames).map(\.1)) ?? bounds
                    let boundaryID = partition.boundaryIDs[index]
                    var segments: [BoundaryDescriptor] = []

                    for (firstID, firstFrame) in firstFrames {
                        for (secondID, secondFrame) in secondFrames {
                            let coordinate: Double
                            let start: Double
                            let end: Double
                            switch partition.axis {
                            case .vertical:
                                guard abs((secondFrame.minX - firstFrame.maxX) - state.metrics.paneGap) <= tolerance else { continue }
                                coordinate = (firstFrame.maxX + secondFrame.minX) / 2
                                start = max(firstFrame.minY, secondFrame.minY)
                                end = min(firstFrame.maxY, secondFrame.maxY)
                            case .horizontal:
                                // The lower window starts below its pane's content reserve.
                                let reserve = state.metrics.contentTopInset
                                guard abs((secondFrame.minY - firstFrame.maxY) - state.metrics.paneGap - reserve) <= tolerance else { continue }
                                // Average the observed edges, as before; with a reserve,
                                // the lower pane starts above its window.
                                coordinate = (firstFrame.maxY + secondFrame.minY - reserve) / 2
                                start = max(firstFrame.minX, secondFrame.minX)
                                end = min(firstFrame.maxX, secondFrame.maxX)
                            }
                            guard end - start >= minimumSegmentLength else { continue }
                            segments.append(BoundaryDescriptor(
                                id: "", displayID: displayID, axis: partition.axis,
                                coordinate: coordinate, spanStart: start, spanEnd: end,
                                beforeWindowIDs: [firstID], afterWindowIDs: [secondID],
                                isLocked: partition.lockedBoundaryIDs.contains(boundaryID),
                                branchID: boundaryID, parentBounds: parent
                            ))
                        }
                    }

                    output += merge(segments, branchID: boundaryID).map { descriptor in
                        var descriptor = descriptor
                        descriptor.beforeWindowIDs = Set(beforeNode.windowIDs)
                        descriptor.afterWindowIDs = Set(afterNode.windowIDs)
                        return descriptor
                    }
                }
                partition.children.forEach(collect)
            }
        }

        collect(normalizedRoot)
        return output.sorted { ($0.axis.rawValue, $0.coordinate, $0.spanStart, $0.id) < ($1.axis.rawValue, $1.coordinate, $1.spanStart, $1.id) }
    }

    private func merge(_ segments: [BoundaryDescriptor], branchID: UUID) -> [BoundaryDescriptor] {
        var merged: [BoundaryDescriptor] = []
        for segment in segments.sorted(by: { $0.spanStart < $1.spanStart }) {
            if let index = merged.indices.last(where: {
                merged[$0].axis == segment.axis
                    && abs(merged[$0].coordinate - segment.coordinate) <= tolerance
                    && segment.spanStart <= merged[$0].spanEnd + tolerance
            }) {
                let existingLength = merged[index].spanEnd - merged[index].spanStart
                let newLength = segment.spanEnd - segment.spanStart
                merged[index].coordinate = (merged[index].coordinate * existingLength + segment.coordinate * newLength) / max(1, existingLength + newLength)
                merged[index].spanStart = min(merged[index].spanStart, segment.spanStart)
                merged[index].spanEnd = max(merged[index].spanEnd, segment.spanEnd)
                merged[index].beforeWindowIDs.formUnion(segment.beforeWindowIDs)
                merged[index].afterWindowIDs.formUnion(segment.afterWindowIDs)
            } else {
                merged.append(segment)
            }
        }
        return merged.enumerated().map { index, descriptor in
            var descriptor = descriptor
            descriptor.id = "bento:\(branchID.uuidString):\(index)"
            return descriptor
        }
    }

    private func boundingRect(_ frames: [BTRect]) -> BTRect? {
        guard let first = frames.first else { return nil }
        let minX = frames.dropFirst().reduce(first.minX) { min($0, $1.minX) }
        let minY = frames.dropFirst().reduce(first.minY) { min($0, $1.minY) }
        let maxX = frames.dropFirst().reduce(first.maxX) { max($0, $1.maxX) }
        let maxY = frames.dropFirst().reduce(first.maxY) { max($0, $1.maxY) }
        return BTRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

enum BentoTreeGeometry {
    struct BoundaryGeometry {
        var axis: SplitAxis
        var before: BentoNode
        var after: BentoNode
        var isLocked: Bool
        var resolvedCoordinate: Double
    }

    static func boundary(
        _ id: UUID,
        in state: BentoLayoutState,
        bounds: BTRect
    ) -> BoundaryGeometry? {
        guard let root = state.root else { return nil }
        let normalizedRoot = BentoLayoutState.normalized(root)
        func find(_ node: BentoNode, rect: BTRect) -> BoundaryGeometry? {
            switch node {
            case .leaf, .vacant:
                return nil
            case let .partition(partition):
                let children = partitionRects(partition, in: rect, gap: state.metrics.paneGap)
                if let index = partition.boundaryIDs.firstIndex(of: id) {
                    let first = children[index]
                    let second = children[index + 1]
                    return BoundaryGeometry(
                        axis: partition.axis,
                        before: partition.children[index],
                        after: partition.children[index + 1],
                        isLocked: partition.lockedBoundaryIDs.contains(id),
                        resolvedCoordinate: partition.axis == .vertical
                            ? (first.maxX + second.minX) / 2
                            : (first.maxY + second.minY) / 2
                    )
                }
                for index in partition.children.indices {
                    if let match = find(partition.children[index], rect: children[index]) { return match }
                }
                return nil
            }
        }
        return find(normalizedRoot, rect: bounds)
    }

    static func minimumExtent(
        _ node: BentoNode,
        axis: SplitAxis,
        constraints: [WindowID: WindowConstraints],
        gap: Double = 0,
        vacantMinimum: BTSize = BTSize(width: 0, height: 0)
    ) -> Double {
        switch node {
        case .vacant:
            return axis == .vertical ? vacantMinimum.width : vacantMinimum.height
        case let .leaf(id):
            let minimum = constraints[id]?.minimumSize ?? WindowConstraints().minimumSize
            return axis == .vertical ? minimum.width : minimum.height
        case let .partition(partition):
            let values = partition.children.map {
                minimumExtent($0, axis: axis, constraints: constraints, gap: gap, vacantMinimum: vacantMinimum)
            }
            return partition.axis == axis
                ? values.reduce(0, +) + gap * Double(max(0, values.count - 1))
                : values.max() ?? 0
        }
    }

    static func partitionRects(_ partition: BentoPartition, in rect: BTRect, gap: Double) -> [BTRect] {
        let extent = partition.axis == .vertical ? rect.size.width : rect.size.height
        let usable = max(0, extent - gap * Double(partition.children.count - 1))
        var cursor = partition.axis == .vertical ? rect.minX : rect.minY
        return partition.children.indices.map { index in
            let childExtent = index == partition.children.count - 1
                ? (partition.axis == .vertical ? rect.maxX : rect.maxY) - cursor
                : usable * partition.ratios[index]
            let child = partition.axis == .vertical
                ? BTRect(x: cursor, y: rect.minY, width: max(0, childExtent), height: rect.size.height)
                : BTRect(x: rect.minX, y: cursor, width: rect.size.width, height: max(0, childExtent))
            cursor += childExtent + gap
            return child
        }
    }
}
