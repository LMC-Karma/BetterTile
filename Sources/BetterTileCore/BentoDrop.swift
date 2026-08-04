import Foundation

public enum BentoDropIntent: Equatable, Sendable {
    case automatic
    case pane(WindowID)
    case insert(targetWindowID: WindowID, edge: BentoPaneDropPosition)
    case snap(action: WindowAction, frame: BTRect)
    case customZone(id: UUID, frame: BTRect)
}

public struct BentoDropPlan: Sendable {
    public var state: BentoLayoutState
    public var placements: [Placement]
    public var minimizedWindowIDs: Set<WindowID>
    public var excludedWindowIDs: Set<WindowID>

    public init(
        state: BentoLayoutState,
        placements: [Placement],
        minimizedWindowIDs: Set<WindowID> = [],
        excludedWindowIDs: Set<WindowID> = []
    ) {
        self.state = state
        self.placements = placements
        self.minimizedWindowIDs = minimizedWindowIDs
        self.excludedWindowIDs = excludedWindowIDs
    }

    public var isFocusDrop: Bool { !minimizedWindowIDs.isEmpty }
}

/// Produces an atomic Bento result for a title-bar drop. Standard partition
/// actions reserve their exact requested rectangle and represent unused space
/// as vacant tree leaves. Focus actions keep the tree intact and only return
/// minimize operations, so unwinding focus restores the exact prior panes.
public struct BentoDropPlanner: Sendable {
    public var maximumManagedWindows: Int
    public var tolerance: Double

    public init(maximumManagedWindows: Int = 6, tolerance: Double = 0.5) {
        self.maximumManagedWindows = max(1, maximumManagedWindows)
        self.tolerance = max(0, tolerance)
    }

    public func plan(
        intent: BentoDropIntent,
        sourceWindowID: WindowID,
        state: BentoLayoutState,
        baselineFrames: [WindowID: BTRect],
        constraints: [WindowID: WindowConstraints],
        contextWindowIDs: Set<WindowID>,
        in bounds: BTRect
    ) -> BentoDropPlan? {
        guard let sourceFrame = baselineFrames[sourceWindowID] else { return nil }
        switch intent {
        case .automatic:
            return automaticPlan(
                sourceWindowID: sourceWindowID,
                state: state,
                baselineFrames: baselineFrames,
                constraints: constraints,
                bounds: bounds
            )
        case let .pane(targetWindowID):
            return panePlan(
                sourceWindowID: sourceWindowID,
                targetWindowID: targetWindowID,
                state: state,
                baselineFrames: baselineFrames,
                constraints: constraints,
                bounds: bounds
            )
        case let .insert(targetWindowID, edge):
            guard edge != .center else {
                return panePlan(
                    sourceWindowID: sourceWindowID,
                    targetWindowID: targetWindowID,
                    state: state,
                    baselineFrames: baselineFrames,
                    constraints: constraints,
                    bounds: bounds
                )
            }
            let managedIDs = Set(state.root?.windowIDs ?? [])
            if managedIDs.count >= maximumManagedWindows,
               state.floatingWindowIDs.contains(sourceWindowID) {
                return panePlan(
                    sourceWindowID: sourceWindowID,
                    targetWindowID: targetWindowID,
                    state: state,
                    baselineFrames: baselineFrames,
                    constraints: constraints,
                    bounds: bounds
                )
            }
            guard managedIDs.contains(sourceWindowID) || managedIDs.count < maximumManagedWindows else {
                return nil
            }
            var next = state
            guard next.reinsert(sourceWindowID, beside: targetWindowID, edge: edge),
                  let solved = BentoConstraintSolver().solve(state: next, in: bounds, constraints: constraints)
            else { return nil }
            next = solved
            let placements = next.placements(in: bounds)
            guard valid(
                placements,
                expected: Set(next.root?.windowIDs ?? []),
                constraints: constraints,
                bounds: bounds
            ) else { return nil }
            return BentoDropPlan(state: next, placements: placements)
        case let .snap(action, frame):
            if Self.partitionActions.contains(action) {
                if let edge = rootEdge(for: action) {
                    return rootPlan(
                        sourceWindowID: sourceWindowID,
                        edge: edge,
                        targetFrame: frame,
                        state: state,
                        constraints: constraints,
                        bounds: bounds
                    )
                }
                return partitionPlan(
                    sourceWindowID: sourceWindowID,
                    targetFrame: frame,
                    state: state,
                    baselineFrames: baselineFrames,
                    constraints: constraints,
                    bounds: bounds
                )
            }
            guard Self.focusActions.contains(action) else { return nil }
            let source = WindowSnapshot(
                id: sourceWindowID,
                processIdentifier: 0,
                frame: sourceFrame,
                displayID: DisplayID(rawValue: "drop-planner"),
                constraints: constraints[sourceWindowID] ?? WindowConstraints()
            )
            let display = DisplaySnapshot(id: source.displayID, frame: bounds, visibleFrame: bounds)
            let focusFrame = StandardActionEngine().targetFrame(for: action, window: source, display: display) ?? frame
            return focusPlan(
                sourceWindowID: sourceWindowID,
                targetFrame: focusFrame,
                state: state,
                contextWindowIDs: contextWindowIDs,
                constraints: constraints,
                bounds: bounds
            )
        case let .customZone(_, frame):
            if let partition = partitionPlan(
                sourceWindowID: sourceWindowID,
                targetFrame: frame,
                state: state,
                baselineFrames: baselineFrames,
                constraints: constraints,
                bounds: bounds
            ) {
                return partition
            }
            return focusPlan(
                sourceWindowID: sourceWindowID,
                targetFrame: frame,
                state: state,
                contextWindowIDs: contextWindowIDs,
                constraints: constraints,
                bounds: bounds
            )
        }
    }

    public static let partitionActions: Set<WindowAction> = [
        .leftHalf, .rightHalf, .topHalf, .bottomHalf,
        .leftThird, .centerThird, .rightThird, .leftTwoThirds, .rightTwoThirds,
        .topLeftQuarter, .topRightQuarter, .bottomLeftQuarter, .bottomRightQuarter,
        .topLeftSixth, .topCenterSixth, .topRightSixth,
        .bottomLeftSixth, .bottomCenterSixth, .bottomRightSixth,
    ]

    public static func handlesShortcut(
        _ action: WindowAction,
        in mode: LayoutMode,
        sourceRule: ApplicationRule
    ) -> Bool {
        mode == .bento
            && sourceRule.allowsBentoParticipation
            && partitionActions.contains(action)
    }

    public static let focusActions: Set<WindowAction> = [
        .maximize, .almostMaximize, .center, .centerResize,
    ]

    private func automaticPlan(
        sourceWindowID: WindowID,
        state: BentoLayoutState,
        baselineFrames: [WindowID: BTRect],
        constraints: [WindowID: WindowConstraints],
        bounds: BTRect
    ) -> BentoDropPlan? {
        let treeIDs = Set(state.root?.windowIDs ?? [])
        guard !treeIDs.contains(sourceWindowID), treeIDs.count < maximumManagedWindows else { return nil }
        var next = state
        next.setFloating(false, windowID: sourceWindowID)
        next.insert(sourceWindowID, in: bounds, currentFrames: baselineFrames)
        guard let solved = BentoConstraintSolver().solve(state: next, in: bounds, constraints: constraints) else { return nil }
        next = solved
        let placements = next.placements(in: bounds)
        guard valid(placements, expected: Set(next.root?.windowIDs ?? []), constraints: constraints, bounds: bounds) else { return nil }
        return BentoDropPlan(state: next, placements: placements)
    }

    private func panePlan(
        sourceWindowID: WindowID,
        targetWindowID: WindowID,
        state: BentoLayoutState,
        baselineFrames: [WindowID: BTRect],
        constraints: [WindowID: WindowConstraints],
        bounds: BTRect
    ) -> BentoDropPlan? {
        guard sourceWindowID != targetWindowID,
              state.root?.windowIDs.contains(targetWindowID) == true
        else { return nil }
        var next = state
        let treeIDs = Set(state.root?.windowIDs ?? [])
        var placements: [Placement]
        var displacedPlacement: Placement?
        if treeIDs.contains(sourceWindowID) {
            guard let sourceFrame = baselineFrames[sourceWindowID],
                  let targetFrame = baselineFrames[targetWindowID]
            else { return nil }
            next.swap(sourceWindowID, targetWindowID)
            placements = treeIDs.compactMap { id in
                let frame: BTRect? = switch id {
                case sourceWindowID: targetFrame
                case targetWindowID: sourceFrame
                default: baselineFrames[id]
                }
                return frame.map { Placement(windowID: id, frame: $0) }
            }
            if !valid(placements, expected: treeIDs, constraints: constraints, bounds: bounds) {
                guard let solved = BentoConstraintSolver().solve(
                    state: next,
                    in: bounds,
                    constraints: constraints
                ) else { return nil }
                next = solved
                placements = solved.placements(in: bounds)
            }
        } else if treeIDs.count >= maximumManagedWindows {
            guard let sourceFrame = baselineFrames[sourceWindowID],
                  next.exchangeFloating(sourceWindowID, withPaneOf: targetWindowID)
            else { return nil }
            displacedPlacement = Placement(windowID: targetWindowID, frame: sourceFrame)
            placements = next.placements(in: bounds)
            if !valid(
                placements,
                expected: Set(next.root?.windowIDs ?? []),
                constraints: constraints,
                bounds: bounds
            ) {
                guard let solved = BentoConstraintSolver().solve(
                    state: next,
                    in: bounds,
                    constraints: constraints
                ) else { return nil }
                next = solved
                placements = solved.placements(in: bounds)
            }
        } else {
            next.split(targetWindowID, inserting: sourceWindowID, in: bounds)
            guard let solved = BentoConstraintSolver().solve(state: next, in: bounds, constraints: constraints) else { return nil }
            next = solved
            placements = next.placements(in: bounds)
        }
        var expected = Set(next.root?.windowIDs ?? [])
        if let displacedPlacement {
            placements.append(displacedPlacement)
            expected.insert(displacedPlacement.windowID)
        }
        guard valid(placements, expected: expected, constraints: constraints, bounds: bounds) else { return nil }
        return BentoDropPlan(state: next, placements: placements)
    }

    private func partitionPlan(
        sourceWindowID: WindowID,
        targetFrame: BTRect,
        state: BentoLayoutState,
        baselineFrames: [WindowID: BTRect],
        constraints: [WindowID: WindowConstraints],
        bounds: BTRect
    ) -> BentoDropPlan? {
        let otherIDs = (state.root?.windowIDs ?? []).filter { $0 != sourceWindowID }
        guard otherIDs.count + 1 <= maximumManagedWindows,
              contains(targetFrame, in: bounds), !targetFrame.isEmpty
        else { return nil }

        var residual = residualRegions(around: targetFrame, in: bounds)
        while residual.count < otherIDs.count {
            guard let index = residual.indices.max(by: { residual[$0].area < residual[$1].area }) else { return nil }
            let region = residual.remove(at: index)
            residual.append(contentsOf: split(region))
        }
        residual.sort { ($0.area, -$0.minY, -$0.minX) > ($1.area, -$1.minY, -$1.minX) }

        guard let allocation = allocate(
            regions: residual,
            windowIDs: otherIDs,
            frames: baselineFrames,
            constraints: constraints,
            bounds: bounds
        ) else { return nil }
        let items = [RegionNode(frame: targetFrame, node: .leaf(sourceWindowID))] + allocation
        guard let root = buildTree(items: items, bounds: bounds) else { return nil }
        var next = BentoLayoutState(
            root: root,
            floatingWindowIDs: state.floatingWindowIDs,
            metrics: .gapless
        )
        let gaplessPlacements = next.placements(in: bounds)
        guard gaplessPlacements.first(where: { $0.windowID == sourceWindowID })?.frame
            .approximatelyEquals(targetFrame, tolerance: tolerance) == true
        else { return nil }
        // Shortcut rectangles describe gapless macOS zones. Once their
        // topology is proven, render that same topology with Bento's gap.
        next.metrics = state.metrics
        next.floatingWindowIDs.remove(sourceWindowID)
        let placements = next.placements(in: bounds)
        guard valid(
            placements,
            expected: Set(next.root?.windowIDs ?? []),
            constraints: constraints,
            bounds: bounds
        ) else { return nil }
        return BentoDropPlan(state: next, placements: placements)
    }

    private func rootPlan(
        sourceWindowID: WindowID,
        edge: BentoPaneDropPosition,
        targetFrame: BTRect,
        state: BentoLayoutState,
        constraints: [WindowID: WindowConstraints],
        bounds: BTRect
    ) -> BentoDropPlan? {
        var next = state
        next.remove(sourceWindowID)
        if next.root == nil {
            next.root = .leaf(sourceWindowID)
        } else {
            let ratio = edge.axis == .vertical
                ? targetFrame.size.width / max(1, bounds.size.width)
                : targetFrame.size.height / max(1, bounds.size.height)
            guard next.insertAtRoot(sourceWindowID, edge: edge, ratio: ratio) else { return nil }
        }
        guard let solved = BentoConstraintSolver().solve(
            state: next,
            in: bounds,
            constraints: constraints
        ) else { return nil }
        let placements = solved.placements(in: bounds)
        guard valid(
            placements,
            expected: Set(solved.root?.windowIDs ?? []),
            constraints: constraints,
            bounds: bounds
        ) else { return nil }
        return BentoDropPlan(state: solved, placements: placements)
    }

    private func rootEdge(for action: WindowAction) -> BentoPaneDropPosition? {
        switch action {
        case .leftHalf, .leftThird, .leftTwoThirds: .left
        case .rightHalf, .rightThird, .rightTwoThirds: .right
        case .topHalf: .top
        case .bottomHalf: .bottom
        default: nil
        }
    }

    private func focusPlan(
        sourceWindowID: WindowID,
        targetFrame: BTRect,
        state: BentoLayoutState,
        contextWindowIDs: Set<WindowID>,
        constraints: [WindowID: WindowConstraints],
        bounds: BTRect
    ) -> BentoDropPlan? {
        let placement = Placement(windowID: sourceWindowID, frame: targetFrame)
        guard valid([placement], expected: [sourceWindowID], constraints: constraints, bounds: bounds) else { return nil }
        let others = contextWindowIDs.subtracting([sourceWindowID])
        return BentoDropPlan(
            state: state,
            placements: [placement],
            minimizedWindowIDs: others,
            excludedWindowIDs: others
        )
    }

    private func residualRegions(around target: BTRect, in bounds: BTRect) -> [BTRect] {
        var regions: [BTRect] = []
        if target.minX > bounds.minX + tolerance {
            regions.append(BTRect(x: bounds.minX, y: bounds.minY, width: target.minX - bounds.minX, height: bounds.size.height))
        }
        if target.maxX < bounds.maxX - tolerance {
            regions.append(BTRect(x: target.maxX, y: bounds.minY, width: bounds.maxX - target.maxX, height: bounds.size.height))
        }
        if target.minY > bounds.minY + tolerance {
            regions.append(BTRect(x: target.minX, y: bounds.minY, width: target.size.width, height: target.minY - bounds.minY))
        }
        if target.maxY < bounds.maxY - tolerance {
            regions.append(BTRect(x: target.minX, y: target.maxY, width: target.size.width, height: bounds.maxY - target.maxY))
        }
        return regions
    }

    private func split(_ frame: BTRect) -> [BTRect] {
        if frame.size.width >= frame.size.height {
            let width = frame.size.width / 2
            return [
                BTRect(x: frame.minX, y: frame.minY, width: width, height: frame.size.height),
                BTRect(x: frame.minX + width, y: frame.minY, width: frame.size.width - width, height: frame.size.height),
            ]
        }
        let height = frame.size.height / 2
        return [
            BTRect(x: frame.minX, y: frame.minY, width: frame.size.width, height: height),
            BTRect(x: frame.minX, y: frame.minY + height, width: frame.size.width, height: frame.size.height - height),
        ]
    }

    private func buildTree(items: [RegionNode], bounds: BTRect) -> BentoNode? {
        guard !items.isEmpty else { return nil }
        if items.count == 1 {
            return items[0].frame.approximatelyEquals(bounds, tolerance: tolerance) ? items[0].node : nil
        }
        let verticalCuts = Set(items.flatMap { [$0.frame.minX, $0.frame.maxX] })
            .filter { $0 > bounds.minX + tolerance && $0 < bounds.maxX - tolerance }.sorted()
        for cut in verticalCuts {
            let first = items.filter { $0.frame.maxX <= cut + tolerance }
            let second = items.filter { $0.frame.minX >= cut - tolerance }
            guard !first.isEmpty, !second.isEmpty, first.count + second.count == items.count else { continue }
            let firstBounds = BTRect(x: bounds.minX, y: bounds.minY, width: cut - bounds.minX, height: bounds.size.height)
            let secondBounds = BTRect(x: cut, y: bounds.minY, width: bounds.maxX - cut, height: bounds.size.height)
            if let firstNode = buildTree(items: first, bounds: firstBounds),
               let secondNode = buildTree(items: second, bounds: secondBounds) {
                return .branch(BentoBranch(axis: .vertical, weight: firstBounds.size.width / bounds.size.width, first: firstNode, second: secondNode))
            }
        }
        let horizontalCuts = Set(items.flatMap { [$0.frame.minY, $0.frame.maxY] })
            .filter { $0 > bounds.minY + tolerance && $0 < bounds.maxY - tolerance }.sorted()
        for cut in horizontalCuts {
            let first = items.filter { $0.frame.maxY <= cut + tolerance }
            let second = items.filter { $0.frame.minY >= cut - tolerance }
            guard !first.isEmpty, !second.isEmpty, first.count + second.count == items.count else { continue }
            let firstBounds = BTRect(x: bounds.minX, y: bounds.minY, width: bounds.size.width, height: cut - bounds.minY)
            let secondBounds = BTRect(x: bounds.minX, y: cut, width: bounds.size.width, height: bounds.maxY - cut)
            if let firstNode = buildTree(items: first, bounds: firstBounds),
               let secondNode = buildTree(items: second, bounds: secondBounds) {
                return .branch(BentoBranch(axis: .horizontal, weight: firstBounds.size.height / bounds.size.height, first: firstNode, second: secondNode))
            }
        }
        return nil
    }

    private func placementScore(windowID: WindowID, region: BTRect, frames: [WindowID: BTRect], bounds: BTRect) -> Double {
        guard let frame = frames[windowID] else { return .greatestFiniteMagnitude }
        let movement = pow(frame.midX - region.midX, 2) + pow(frame.midY - region.midY, 2)
        return movement / max(1, bounds.area) + abs(frame.area - region.area) / max(1, bounds.area)
    }

    private func allocate(
        regions: [BTRect],
        windowIDs: [WindowID],
        frames: [WindowID: BTRect],
        constraints: [WindowID: WindowConstraints],
        bounds: BTRect
    ) -> [RegionNode]? {
        guard regions.count >= windowIDs.count else { return nil }
        if windowIDs.isEmpty {
            return regions.map { RegionNode(frame: $0, node: .vacant(UUID())) }
        }
        let region = regions[0]
        var best: (score: Double, nodes: [RegionNode])?
        for (index, windowID) in windowIDs.enumerated() {
            let minimum = constraints[windowID]?.minimumSize ?? WindowConstraints().minimumSize
            guard region.size.width + tolerance >= minimum.width,
                  region.size.height + tolerance >= minimum.height
            else { continue }
            var remaining = windowIDs
            remaining.remove(at: index)
            guard let tail = allocate(
                regions: Array(regions.dropFirst()),
                windowIDs: remaining,
                frames: frames,
                constraints: constraints,
                bounds: bounds
            ) else { continue }
            let score = placementScore(windowID: windowID, region: region, frames: frames, bounds: bounds)
                + tail.reduce(0) { partial, node in
                    guard case let .leaf(id) = node.node else { return partial }
                    return partial + placementScore(windowID: id, region: node.frame, frames: frames, bounds: bounds)
                }
            if best == nil || score < best!.score {
                best = (score, [RegionNode(frame: region, node: .leaf(windowID))] + tail)
            }
        }
        return best?.nodes
    }

    private func valid(
        _ placements: [Placement],
        expected: Set<WindowID>,
        constraints: [WindowID: WindowConstraints],
        bounds: BTRect
    ) -> Bool {
        Set(placements.map(\.windowID)) == expected && placements.allSatisfy { placement in
            let minimum = constraints[placement.windowID]?.minimumSize ?? WindowConstraints().minimumSize
            return contains(placement.frame, in: bounds)
                && placement.frame.size.width + tolerance >= minimum.width
                && placement.frame.size.height + tolerance >= minimum.height
        }
    }

    private func contains(_ frame: BTRect, in bounds: BTRect) -> Bool {
        frame.minX >= bounds.minX - tolerance && frame.minY >= bounds.minY - tolerance
            && frame.maxX <= bounds.maxX + tolerance && frame.maxY <= bounds.maxY + tolerance
    }
}

private struct RegionNode {
    var frame: BTRect
    var node: BentoNode
}
