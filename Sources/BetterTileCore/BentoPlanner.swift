import Foundation

public struct BentoReinsertionAnchor: Hashable, Sendable {
    public var neighborWindowID: WindowID
    public var edge: BentoPaneDropPosition

    public init(neighborWindowID: WindowID, edge: BentoPaneDropPosition) {
        self.neighborWindowID = neighborWindowID
        self.edge = edge
    }
}

/// Process-lifetime state that is deliberately separate from the partition
/// tree. Focus and overflow therefore never destroy the six-pane layout.
public struct BentoRuntimeState: Hashable, Sendable {
    public var layout: BentoLayoutState
    public var focusHistory: [WindowID]
    public var reinsertionAnchors: [WindowID: BentoReinsertionAnchor]

    public init(
        layout: BentoLayoutState = BentoLayoutState(),
        focusHistory: [WindowID] = [],
        reinsertionAnchors: [WindowID: BentoReinsertionAnchor] = [:]
    ) {
        self.layout = layout
        self.focusHistory = focusHistory
        self.reinsertionAnchors = reinsertionAnchors
    }
}

public struct BentoObservation: Sendable {
    public var bounds: BTRect
    public var windows: [WindowID: WindowSnapshot]
    public var focusedWindowID: WindowID?

    public init(bounds: BTRect, windows: [WindowSnapshot], focusedWindowID: WindowID? = nil) {
        self.bounds = bounds
        self.windows = Dictionary(uniqueKeysWithValues: windows.map { ($0.id, $0) })
        self.focusedWindowID = focusedWindowID
    }

    public var eligibleWindowIDs: Set<WindowID> {
        Set(windows.values.filter(\.isEligible).map(\.id))
    }

    public var frames: [WindowID: BTRect] {
        windows.mapValues(\.frame)
    }

    public var constraints: [WindowID: WindowConstraints] {
        windows.mapValues(\.constraints)
    }
}

public enum BentoPlannerIntent: Sendable {
    case activate
    case retile
    case insert(WindowID)
    case remove(WindowID, minimized: Bool)
    case restore(WindowID)
    case paneDrop(source: WindowID, target: WindowID, position: BentoPaneDropPosition)
    case rootDrop(source: WindowID, edge: BentoPaneDropPosition)
    case snap(source: WindowID, action: WindowAction, frame: BTRect)
    case nativeResize(changedWindowIDs: Set<WindowID>)
    case focus(WindowID, frame: BTRect)
    case unwindFocus(WindowID)
}

public enum BentoPillResult: Equatable, Sendable {
    case success(String)
    case constraint(String)
    case overflow(String)
    case adapted(String)
    case failure(String)
}

public struct BentoPlannerResult: Sendable {
    public var state: BentoRuntimeState
    public var placements: [Placement]
    public var minimizeWindowIDs: Set<WindowID>
    public var restoreWindowIDs: Set<WindowID>
    public var pill: BentoPillResult?
    public var writesFrames: Bool

    public init(
        state: BentoRuntimeState,
        placements: [Placement] = [],
        minimizeWindowIDs: Set<WindowID> = [],
        restoreWindowIDs: Set<WindowID> = [],
        pill: BentoPillResult? = nil,
        writesFrames: Bool = true
    ) {
        self.state = state
        self.placements = placements
        self.minimizeWindowIDs = minimizeWindowIDs
        self.restoreWindowIDs = restoreWindowIDs
        self.pill = pill
        self.writesFrames = writesFrames
    }
}

public struct BentoCrossDisplayResult: Sendable {
    public var sourceState: BentoRuntimeState
    public var destinationState: BentoRuntimeState
    public var placements: [Placement]
    public var transferredBackWindowID: WindowID?

    public init(
        sourceState: BentoRuntimeState,
        destinationState: BentoRuntimeState,
        placements: [Placement],
        transferredBackWindowID: WindowID? = nil
    ) {
        self.sourceState = sourceState
        self.destinationState = destinationState
        self.placements = placements
        self.transferredBackWindowID = transferredBackWindowID
    }
}

/// Pure Bento state transition module. It observes windows once and returns
/// every frame and minimize/restore operation required for the next state.
public struct BentoPlanner: Sendable {
    public var maximumManagedWindows: Int

    public init(maximumManagedWindows: Int = 6) {
        self.maximumManagedWindows = max(1, maximumManagedWindows)
    }

    public func plan(
        state: BentoRuntimeState,
        observation: BentoObservation,
        intent: BentoPlannerIntent
    ) -> BentoPlannerResult {
        switch intent {
        case .activate:
            return activate(state: state, observation: observation)
        case .retile:
            return retile(state: state, observation: observation)
        case let .insert(windowID):
            return insert(windowID, state: state, observation: observation)
        case let .remove(windowID, minimized):
            return remove(windowID, minimized: minimized, state: state, observation: observation)
        case let .restore(windowID):
            return restore(windowID, state: state, observation: observation)
        case let .paneDrop(source, target, position):
            return paneDrop(
                source: source, target: target, position: position,
                state: state, observation: observation
            )
        case let .rootDrop(source, edge):
            return rootDrop(source: source, edge: edge, state: state, observation: observation)
        case let .snap(source, action, frame):
            return snap(
                source: source, action: action, frame: frame,
                state: state, observation: observation
            )
        case let .nativeResize(changedWindowIDs):
            return nativeResize(
                changedWindowIDs: changedWindowIDs,
                state: state, observation: observation
            )
        case let .focus(windowID, frame):
            return focus(windowID, frame: frame, state: state, observation: observation)
        case let .unwindFocus(windowID):
            return unwindFocus(windowID, state: state, observation: observation)
        }
    }

    /// Atomically plans both sides of a cross-display pane drop. The caller
    /// commits the returned placement batch as one window transaction.
    public func transfer(
        sourceWindowID: WindowID,
        targetWindowID: WindowID,
        position: BentoPaneDropPosition,
        sourceState: BentoRuntimeState,
        destinationState: BentoRuntimeState,
        sourceObservation: BentoObservation,
        destinationObservation: BentoObservation
    ) -> BentoCrossDisplayResult? {
        var source = sourceState
        var destination = destinationState
        let destinationCount = destination.layout.root?.windowIDs.count ?? 0
        guard source.layout.root?.windowIDs.contains(sourceWindowID) == true,
              destination.layout.root?.windowIDs.contains(targetWindowID) == true,
              position == .center || destinationCount < maximumManagedWindows
        else { return nil }

        var transferredBack: WindowID?
        if position == .center {
            guard source.layout.replace(sourceWindowID, with: targetWindowID),
                  destination.layout.replace(targetWindowID, with: sourceWindowID)
            else { return nil }
            transferredBack = targetWindowID
        } else {
            source.layout.remove(sourceWindowID)
            guard destination.layout.reinsert(
                sourceWindowID,
                beside: targetWindowID,
                edge: position
            ) else { return nil }
        }

        let allConstraints = sourceObservation.constraints
            .merging(destinationObservation.constraints) { current, _ in current }
        guard let solvedSource = BentoConstraintSolver().solve(
            state: source.layout,
            in: sourceObservation.bounds,
            constraints: allConstraints
        ), let solvedDestination = BentoConstraintSolver().solve(
            state: destination.layout,
            in: destinationObservation.bounds,
            constraints: allConstraints
        ) else { return nil }
        source.layout = solvedSource
        destination.layout = solvedDestination
        return BentoCrossDisplayResult(
            sourceState: source,
            destinationState: destination,
            placements: solvedSource.placements(in: sourceObservation.bounds)
                + solvedDestination.placements(in: destinationObservation.bounds),
            transferredBackWindowID: transferredBack
        )
    }

    private func activate(
        state: BentoRuntimeState,
        observation: BentoObservation
    ) -> BentoPlannerResult {
        var next = state
        let ids = observation.eligibleWindowIDs.sorted()
        guard !ids.isEmpty else {
            next.layout.root = nil
            return BentoPlannerResult(state: next, writesFrames: false)
        }
        let managed = Array(ids.prefix(maximumManagedWindows))
        let frames = Dictionary(uniqueKeysWithValues: managed.compactMap { id in
            observation.frames[id].map { (id, $0) }
        })
        if let adopted = BentoLayoutAdopter().adopt(
            frames: frames,
            in: observation.bounds,
            metrics: next.layout.metrics
        ) {
            next.layout = adopted
            return BentoPlannerResult(
                state: next,
                pill: .success("Existing panes adopted"),
                writesFrames: false
            )
        }
        // Standard shortcut zones are gapless. Preserve their topology and
        // ratios when Bento itself is configured to add an inner pane gap.
        if next.layout.metrics.paneGap > 0,
           var adopted = BentoLayoutAdopter().adopt(
               frames: frames,
               in: observation.bounds,
               metrics: .gapless
           ) {
            adopted.metrics = next.layout.metrics
            next.layout = adopted
            return solved(next, observation: observation, pill: .adapted("Existing panes adopted"))
        }

        next.layout = automaticLayout(
            windowIDs: managed,
            focusedWindowID: observation.focusedWindowID,
            metrics: next.layout.metrics,
            bounds: observation.bounds
        )
        let overflow = ids.filter { !managed.contains($0) }
        if let newest = overflow.last, let frame = focusFrame(in: observation.bounds) {
            next.focusHistory = overflow
            return BentoPlannerResult(
                state: next,
                placements: [Placement(windowID: newest, frame: frame)],
                minimizeWindowIDs: Set(managed).union(overflow.dropLast()),
                pill: .overflow("Six panes preserved; overflow focus")
            )
        }
        return solved(next, observation: observation, pill: .success("Bento arranged"))
    }

    private func retile(
        state: BentoRuntimeState,
        observation: BentoObservation
    ) -> BentoPlannerResult {
        let ids = observation.eligibleWindowIDs.sorted()
        guard !ids.isEmpty else {
            var next = state
            next.layout.root = nil
            return BentoPlannerResult(state: next, writesFrames: false)
        }
        let managed = Array(ids.prefix(maximumManagedWindows))
        guard managed.count == ids.count else {
            return activate(state: state, observation: observation)
        }
        let frames = Dictionary(uniqueKeysWithValues: managed.compactMap { id in
            observation.frames[id].map { (id, $0) }
        })

        var candidates: [BentoPlannerResult] = []
        if var adopted = BentoLayoutAdopter().adopt(
            frames: frames,
            in: observation.bounds,
            metrics: state.layout.metrics
        ) {
            adopted.floatingWindowIDs = state.layout.floatingWindowIDs.subtracting(managed)
            var next = state
            next.layout = canonicalized(adopted)
            let result = solved(next, observation: observation, pill: .success("Bento panes repaired"))
            if result.writesFrames { candidates.append(result) }
        }
        if state.layout.metrics.paneGap > 0,
           var adopted = BentoLayoutAdopter().adopt(
               frames: frames,
               in: observation.bounds,
               metrics: .gapless
           ) {
            adopted.metrics = state.layout.metrics
            adopted.floatingWindowIDs = state.layout.floatingWindowIDs.subtracting(managed)
            var next = state
            next.layout = canonicalized(adopted)
            let result = solved(next, observation: observation, pill: .adapted("Shortcut layout repaired"))
            if result.writesFrames { candidates.append(result) }
        }

        if Set(state.layout.root?.windowIDs ?? []) == Set(managed) {
            var stored = state
            stored.layout = canonicalized(stored.layout)
            let result = solved(stored, observation: observation, pill: .adapted("Stored Bento layout repaired"))
            if result.writesFrames { candidates.append(result) }
        }

        var automatic = state
        automatic.layout = automaticLayout(
            windowIDs: managed,
            focusedWindowID: observation.focusedWindowID,
            metrics: state.layout.metrics,
            bounds: observation.bounds
        )
        let automaticResult = solved(
            automatic,
            observation: observation,
            pill: .success("Bento panes retiled")
        )
        if automaticResult.writesFrames { candidates.append(automaticResult) }

        return candidates.min {
            frameDistance($0.placements, from: observation.frames, in: observation.bounds)
                < frameDistance($1.placements, from: observation.frames, in: observation.bounds)
        } ?? failure(state, "The pane tree cannot satisfy minimum sizes")
    }

    private func canonicalized(_ layout: BentoLayoutState) -> BentoLayoutState {
        func reset(_ node: BentoNode) -> BentoNode {
            switch node {
            case .leaf, .vacant:
                return node
            case var .branch(branch):
                branch.weight = 0.5
                branch.first = reset(branch.first)
                branch.second = reset(branch.second)
                return .branch(branch)
            case var .partition(partition):
                partition.children = partition.children.map(reset)
                partition.ratios = Array(repeating: 1 / Double(partition.children.count), count: partition.children.count)
                return .partition(partition)
            }
        }

        var result = layout
        result.root = result.root.map { BentoLayoutState.normalized(reset($0)) }
        return result
    }

    private func frameDistance(
        _ placements: [Placement],
        from currentFrames: [WindowID: BTRect],
        in bounds: BTRect
    ) -> Double {
        let scale = max(1, bounds.size.width + bounds.size.height)
        return placements.reduce(0) { total, placement in
            guard let current = currentFrames[placement.windowID] else {
                return total + 1_000
            }
            let frame = placement.frame
            return total + (
                abs(frame.minX - current.minX)
                    + abs(frame.maxX - current.maxX)
                    + abs(frame.minY - current.minY)
                    + abs(frame.maxY - current.maxY)
            ) / scale
        }
    }

    private func insert(
        _ windowID: WindowID,
        state: BentoRuntimeState,
        observation: BentoObservation
    ) -> BentoPlannerResult {
        guard observation.windows[windowID]?.isEligible == true else {
            return failure(state, "Window is not eligible for Bento")
        }
        var next = state
        let treeIDs = Set(next.layout.root?.windowIDs ?? [])
        guard !treeIDs.contains(windowID) else {
            return BentoPlannerResult(state: next, writesFrames: false)
        }
        if treeIDs.count >= maximumManagedWindows {
            next.focusHistory.removeAll { $0 == windowID }
            next.focusHistory.append(windowID)
            let hidden = treeIDs.union(next.focusHistory.dropLast())
            return BentoPlannerResult(
                state: next,
                placements: [Placement(windowID: windowID, frame: focusFrame(in: observation.bounds)!)],
                minimizeWindowIDs: hidden,
                restoreWindowIDs: [windowID],
                pill: .overflow("Six panes preserved; overflow focus")
            )
        }
        next.layout = automaticLayout(
            windowIDs: (next.layout.root?.windowIDs ?? []) + [windowID],
            focusedWindowID: observation.focusedWindowID,
            metrics: next.layout.metrics,
            bounds: observation.bounds
        )
        return solved(next, observation: observation, pill: .success("Pane added"))
    }

    private func remove(
        _ windowID: WindowID,
        minimized: Bool,
        state: BentoRuntimeState,
        observation: BentoObservation
    ) -> BentoPlannerResult {
        if state.focusHistory.contains(windowID) {
            return unwindFocus(windowID, state: state, observation: observation)
        }
        var next = state
        if minimized, let anchor = reinsertionAnchor(
            for: windowID,
            state: state.layout,
            bounds: observation.bounds
        ) {
            next.reinsertionAnchors[windowID] = anchor
        }
        next.layout.remove(windowID)
        return solved(next, observation: observation, pill: .success("Pane removed"))
    }

    private func restore(
        _ windowID: WindowID,
        state: BentoRuntimeState,
        observation: BentoObservation
    ) -> BentoPlannerResult {
        var next = state
        if let anchor = next.reinsertionAnchors.removeValue(forKey: windowID),
           next.layout.root?.windowIDs.contains(anchor.neighborWindowID) == true {
            _ = next.layout.reinsert(windowID, beside: anchor.neighborWindowID, edge: anchor.edge)
        } else {
            let target = observation.focusedWindowID
                .flatMap { next.layout.root?.windowIDs.contains($0) == true ? $0 : nil }
            if let target {
                next.layout.split(target, inserting: windowID, in: observation.bounds)
            } else {
                next.layout.insert(windowID, in: observation.bounds, currentFrames: observation.frames)
            }
        }
        var result = solved(next, observation: observation, pill: .success("Pane restored"))
        result.restoreWindowIDs.insert(windowID)
        return result
    }

    private func paneDrop(
        source: WindowID,
        target: WindowID,
        position: BentoPaneDropPosition,
        state: BentoRuntimeState,
        observation: BentoObservation
    ) -> BentoPlannerResult {
        var next = state
        if position == .center {
            next.layout.swap(source, target)
        } else if !next.layout.reinsert(source, beside: target, edge: position) {
            return failure(state, "Pane insertion is no longer valid")
        }
        return solved(next, observation: observation, pill: .success(position == .center ? "Panes swapped" : "Pane inserted"))
    }

    private func rootDrop(
        source: WindowID,
        edge: BentoPaneDropPosition,
        state: BentoRuntimeState,
        observation: BentoObservation
    ) -> BentoPlannerResult {
        guard edge != .center else { return failure(state, "A display edge is required") }
        var next = state
        next.layout.remove(source)
        if next.layout.root == nil {
            next.layout.root = .leaf(source)
        } else if !next.layout.insertAtRoot(source, edge: edge) {
            return failure(state, "Display-edge insertion failed")
        }
        return solved(next, observation: observation, pill: .success("Pane inserted at display edge"))
    }

    private func snap(
        source: WindowID,
        action: WindowAction,
        frame: BTRect,
        state: BentoRuntimeState,
        observation: BentoObservation
    ) -> BentoPlannerResult {
        if BentoDropPlanner.focusActions.contains(action) {
            return focus(source, frame: frame, state: state, observation: observation)
        }
        guard let plan = BentoDropPlanner(maximumManagedWindows: maximumManagedWindows).plan(
            intent: .snap(action: action, frame: frame),
            sourceWindowID: source,
            state: state.layout,
            baselineFrames: observation.frames,
            constraints: observation.constraints,
            contextWindowIDs: observation.eligibleWindowIDs,
            in: observation.bounds
        ) else { return failure(state, "The requested panes do not satisfy window constraints") }
        var next = state
        next.layout = plan.state
        return BentoPlannerResult(state: next, placements: plan.placements, pill: .success("Bento snap applied"))
    }

    private func nativeResize(
        changedWindowIDs: Set<WindowID>,
        state: BentoRuntimeState,
        observation: BentoObservation
    ) -> BentoPlannerResult {
        guard let fitted = BentoLayoutFitter().fit(
            state: state.layout,
            currentFrames: observation.frames,
            changedWindowIDs: changedWindowIDs,
            in: observation.bounds,
            constraints: observation.constraints
        ) else { return failure(state, "Window resize could not be adopted") }
        var next = state
        next.layout = fitted.state
        return BentoPlannerResult(
            state: next,
            placements: fitted.placements,
            pill: .adapted("Pane ratios adapted")
        )
    }

    private func focus(
        _ windowID: WindowID,
        frame: BTRect,
        state: BentoRuntimeState,
        observation: BentoObservation
    ) -> BentoPlannerResult {
        guard observation.windows[windowID] != nil else {
            return failure(state, "Focus window is unavailable")
        }
        var next = state
        next.focusHistory.removeAll { $0 == windowID }
        next.focusHistory.append(windowID)
        let peers = Set(next.layout.root?.windowIDs ?? [])
            .union(next.focusHistory.dropLast())
            .subtracting([windowID])
        return BentoPlannerResult(
            state: next,
            placements: [Placement(windowID: windowID, frame: frame)],
            minimizeWindowIDs: peers,
            restoreWindowIDs: [windowID],
            pill: .success("Focus view")
        )
    }

    private func unwindFocus(
        _ windowID: WindowID,
        state: BentoRuntimeState,
        observation: BentoObservation
    ) -> BentoPlannerResult {
        var next = state
        next.focusHistory.removeAll { $0 == windowID }
        if let previous = next.focusHistory.last {
            return BentoPlannerResult(
                state: next,
                placements: [Placement(windowID: previous, frame: focusFrame(in: observation.bounds)!)],
                minimizeWindowIDs: Set(next.layout.root?.windowIDs ?? [])
                    .union(next.focusHistory.dropLast()),
                restoreWindowIDs: [previous],
                pill: .overflow("Previous overflow window restored")
            )
        }
        var result = solved(next, observation: observation, pill: .success("Bento panes restored"))
        result.restoreWindowIDs = Set(next.layout.root?.windowIDs ?? [])
        return result
    }

    private func solved(
        _ state: BentoRuntimeState,
        observation: BentoObservation,
        pill: BentoPillResult?
    ) -> BentoPlannerResult {
        guard let layout = BentoConstraintSolver().solve(
            state: state.layout,
            in: observation.bounds,
            constraints: observation.constraints
        ) else {
            return failure(state, "The pane tree cannot satisfy minimum sizes")
        }
        var next = state
        next.layout = layout
        return BentoPlannerResult(
            state: next,
            placements: layout.placements(in: observation.bounds),
            pill: pill
        )
    }

    private func failure(_ state: BentoRuntimeState, _ message: String) -> BentoPlannerResult {
        BentoPlannerResult(state: state, pill: .failure(message), writesFrames: false)
    }

    /// Builds the default automatic grid: an odd window count gets one lead
    /// pane plus two balanced cross-axis tracks, an even count gets two
    /// balanced tracks alone. Window order stays stable except that the focused
    /// window is promoted to the lead pane.
    private func automaticLayout(
        windowIDs: [WindowID],
        focusedWindowID: WindowID?,
        metrics: BentoLayoutMetrics,
        bounds: BTRect
    ) -> BentoLayoutState {
        var ordered: [WindowID] = []
        if let focusedWindowID, windowIDs.contains(focusedWindowID) {
            ordered.append(focusedWindowID)
        }
        for windowID in windowIDs where !ordered.contains(windowID) {
            ordered.append(windowID)
        }
        let primaryAxis: SplitAxis = bounds.size.width >= bounds.size.height
            ? .vertical
            : .horizontal
        return BentoLayoutState(
            root: BentoAutomaticTopology.node(for: ordered, primaryAxis: primaryAxis),
            metrics: metrics
        )
    }

    private func focusFrame(in bounds: BTRect) -> BTRect? {
        guard !bounds.isEmpty else { return nil }
        return bounds.insetBy(dx: min(24, bounds.size.width * 0.02), dy: min(24, bounds.size.height * 0.02))
    }

    private func reinsertionAnchor(
        for windowID: WindowID,
        state: BentoLayoutState,
        bounds: BTRect
    ) -> BentoReinsertionAnchor? {
        let frames = Dictionary(uniqueKeysWithValues: state.placements(in: bounds).map { ($0.windowID, $0.frame) })
        guard let source = frames[windowID] else { return nil }
        var bestDistance = Double.greatestFiniteMagnitude
        var best: BentoReinsertionAnchor?
        for (id, frame) in frames where id != windowID {
            let dx = frame.midX - source.midX
            let dy = frame.midY - source.midY
            let edge: BentoPaneDropPosition
            if abs(dx) >= abs(dy) {
                edge = dx > 0 ? .left : .right
            } else {
                edge = dy > 0 ? .top : .bottom
            }
            let distance = dx * dx + dy * dy
            if distance < bestDistance
                || (distance == bestDistance && (best?.neighborWindowID ?? id) > id) {
                bestDistance = distance
                best = BentoReinsertionAnchor(neighborWindowID: id, edge: edge)
            }
        }
        return best
    }
}

private enum BentoAutomaticTopology {
    static func node(for windowIDs: [WindowID], primaryAxis: SplitAxis) -> BentoNode? {
        guard !windowIDs.isEmpty else { return nil }
        if windowIDs.count == 1 {
            return .leaf(windowIDs[0])
        }
        if windowIDs.count == 2 {
            return partition(
                axis: primaryAxis,
                children: windowIDs.map(BentoNode.leaf)
            )
        }
        if windowIDs.count.isMultiple(of: 2) {
            return grid(windowIDs, primaryAxis: primaryAxis)
        }

        let leadShare = 2 / Double(windowIDs.count + 1)
        guard let grid = grid(Array(windowIDs.dropFirst()), primaryAxis: primaryAxis) else {
            return .leaf(windowIDs[0])
        }
        return partition(
            axis: primaryAxis,
            children: [.leaf(windowIDs[0]), grid],
            ratios: [leadShare, 1 - leadShare]
        )
    }

    private static func grid(
        _ windowIDs: [WindowID],
        primaryAxis: SplitAxis
    ) -> BentoNode? {
        guard !windowIDs.isEmpty else { return nil }
        let crossAxis: SplitAxis = primaryAxis == .vertical ? .horizontal : .vertical
        let tracks = stride(from: 0, to: windowIDs.count, by: 2).map { start -> BentoNode in
            let end = min(start + 2, windowIDs.count)
            let children = windowIDs[start..<end].map(BentoNode.leaf)
            return children.count == 1
                ? children[0]
                : partition(axis: crossAxis, children: children)
        }
        return tracks.count == 1
            ? tracks[0]
            : partition(axis: primaryAxis, children: tracks)
    }

    private static func partition(
        axis: SplitAxis,
        children: [BentoNode],
        ratios: [Double] = []
    ) -> BentoNode {
        let boundaries = children.indices.dropLast().map { index in
            stableID(
                "\(axis.rawValue)|\(children[index].windowIDs.map(\.rawValue).joined(separator: ","))"
                    + "|\(children[index + 1].windowIDs.map(\.rawValue).joined(separator: ","))"
            )
        }
        return .partition(BentoPartition(
            id: stableID(
                "\(axis.rawValue)|"
                    + children.flatMap(\.windowIDs).map(\.rawValue).joined(separator: ",")
            ),
            axis: axis,
            children: children,
            ratios: ratios,
            boundaryIDs: boundaries
        ))
    }

    private static func stableID(_ source: String) -> UUID {
        func fnv1a(_ string: String, seed: UInt64) -> UInt64 {
            string.utf8.reduce(seed) { hash, byte in
                (hash ^ UInt64(byte)) &* 1_099_511_628_211
            }
        }
        let high = String(
            format: "%016llx",
            fnv1a(source, seed: 14_695_981_039_346_656_037)
        )
        let low = String(
            format: "%016llx",
            fnv1a(String(source.reversed()), seed: 7_807_828_912_877_952_651)
        )
        let hex = high + low
        return UUID(uuidString:
            "\(hex.prefix(8))-\(hex.dropFirst(8).prefix(4))"
                + "-\(hex.dropFirst(12).prefix(4))-\(hex.dropFirst(16).prefix(4))"
                + "-\(hex.dropFirst(20).prefix(12))"
        )!
    }
}
