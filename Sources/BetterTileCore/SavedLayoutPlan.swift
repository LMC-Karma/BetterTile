import Foundation

/// The integration layer supplies only eligible windows from the chosen desktop/display.
public struct SavedLayoutEligibleWindow: Equatable, Sendable {
    public var id: WindowID
    public var bundleID: String
    public var frame: BTRect
    public var constraints: WindowConstraints
    /// A foreign display's position in its own work area, for matching before a verified transfer.
    public var matchingFrame: NormalizedRect?
    /// Zero is frontmost. Equal ranks use the window ID.
    public var frontRank: Int
    public var minimumSize: BTSize? {
        get { constraints.minimumSize }
        set { constraints.minimumSize = newValue ?? WindowConstraints().minimumSize }
    }
    public init(id: WindowID, bundleID: String, frame: BTRect, minimumSize: BTSize? = nil,
                constraints: WindowConstraints = .init(), matchingFrame: NormalizedRect? = nil, frontRank: Int = .max) {
        self.id = id; self.bundleID = bundleID; self.frame = frame; self.constraints = constraints
        self.matchingFrame = matchingFrame; self.frontRank = frontRank
        if let minimumSize { self.constraints.minimumSize = minimumSize }
    }
}

public enum SavedLayoutSlotReason: Equatable, Sendable {
    case chosen, preferred(rank: Int), largestFreeSlot, nearestPosition, empty
}
public enum SavedLayoutTabReason: Equatable, Sendable {
    case sameApp, listedApp, tabMates, nearestPane
}
public enum SavedLayoutExtraDestination: Equatable, Sendable {
    case tab(groupID: String, reason: SavedLayoutTabReason)
    case floating, addedAsPane, untouched
}

public struct SavedLayoutApplyPlan: Equatable, Sendable {
    public var assignments: [String: WindowID]
    /// Frame changes only; already matching windows have no placement.
    public var placements: [Placement]
    public var slotReasons: [String: SavedLayoutSlotReason]
    public var extras: [WindowID: SavedLayoutExtraDestination]
    public var emptySlots: [String]
    /// Windows left outside the managed target. Extra tabs and added panes are members.
    public var unmatchedWindowIDs: [WindowID]
    /// Complete fitted target, including vacancies for empty slots. No synthetic window IDs.
    public var targetSession: SavedLayoutSession
    /// Nil when the caller has not supplied current session metadata.
    public var needsSessionUpdate: Bool?

    public init(assignments: [String: WindowID], placements: [Placement],
                slotReasons: [String: SavedLayoutSlotReason] = [:],
                extras: [WindowID: SavedLayoutExtraDestination] = [:], emptySlots: [String] = [],
                unmatchedWindowIDs: [WindowID]? = nil,
                targetSession: SavedLayoutSession, needsSessionUpdate: Bool?) {
        self.assignments = assignments; self.placements = placements; self.slotReasons = slotReasons
        self.extras = extras; self.emptySlots = emptySlots
        self.unmatchedWindowIDs = unmatchedWindowIDs ?? extras.compactMap {
            $0.value == .floating || $0.value == .untouched ? $0.key : nil
        }.sorted()
        self.targetSession = targetSession; self.needsSessionUpdate = needsSessionUpdate
    }

    /// Target metadata is retained even when no frame or known session changes remain.
    public var isEmpty: Bool { placements.isEmpty && needsSessionUpdate != true }
}

public enum SavedLayoutPlanner {
    public static func plan(_ document: SavedLayoutDocument, in workArea: BTRect,
                            windows: [SavedLayoutEligibleWindow],
                            appGroups: AppGroupsDocument = .init(),
                            resolvedBundleIDs: [AppGroupEntry: String] = [:],
                            choices: [String: WindowID] = [:],
                            preferredFrames: [String: NormalizedRect] = [:],
                            currentSession: SavedLayoutSession? = nil,
                            tabbedPresentation: TabbedStripPresentation = .alwaysVisible,
                            steppedGrids: [WindowID: [SplitAxis: SteppedGrid]] = [:]) throws -> SavedLayoutApplyPlan {
        try SavedLayoutValidator.requireValid(document)
        guard validSavedLayoutBounds(workArea) else {
            throw savedLayoutError("$.workArea", "Use a finite work area with positive width and height.")
        }
        var byID: [WindowID: SavedLayoutEligibleWindow] = [:]
        for (i, window) in windows.enumerated() {
            guard byID.updateValue(window, forKey: window.id) == nil else {
                throw savedLayoutError("$.eligibleWindows[\(i)].id", "Supply each eligible window only once.")
            }
            guard validSavedLayoutBounds(window.frame) else {
                throw savedLayoutError("$.eligibleWindows[\(i)].frame", "Supply a finite, positive window frame.")
            }
            if let frame = window.matchingFrame,
               (![frame.x, frame.y, frame.width, frame.height].allSatisfy(\.isFinite) || frame.width <= 0 || frame.height <= 0) {
                throw savedLayoutError("$.eligibleWindows[\(i)].matchingFrame", "Supply a finite, positive matching frame.")
            }
            if let size = window.minimumSize,
               ![size.width, size.height].allSatisfy({ $0.isFinite && $0 >= 0 }) {
                throw savedLayoutError("$.eligibleWindows[\(i)].minimumSize", "Supply finite, nonnegative minimum dimensions.")
            }
        }
        let fill = try SavedLayoutFill(document: document, bounds: workArea, windows: windows,
            appGroups: appGroups, resolvedBundleIDs: resolvedBundleIDs, choices: choices,
            preferredFrames: preferredFrames, currentSession: currentSession)
        let assignments = fill.assignments
        var extras = fill.extras
        let steppedGrids = steppedGrids.filter { byID[$0.key]?.constraints.isResizable == true }
        let floatingIDs = Set(document.floats.compactMap { assignments[$0.slot] })
            .union(extras.compactMap { $0.value == .floating ? $0.key : nil })
        let constraints = Dictionary(uniqueKeysWithValues: windows.map { window in
            var constraints = window.constraints
            if constraints.isResizable, let axes = steppedGrids[window.id] {
                func gridMinimum(_ minimum: Double, axis: SplitAxis) -> Double {
                    guard let grid = axes[axis], let step = grid.step else { return minimum }
                    return max(minimum, grid.offset + ((minimum - grid.offset) / step).rounded(.up) * step)
                }
                constraints.minimumSize = BTSize(
                    width: gridMinimum(constraints.minimumSize.width, axis: .vertical),
                    height: gridMinimum(constraints.minimumSize.height, axis: .horizontal))
            }
            return (window.id, constraints)
        })
        var placements: [Placement] = []
        let target: SavedLayoutSession
        func steppedRequests(_ proposed: [Placement]) -> [Placement] {
            TabbedLayoutState.requestingSteppedGrids(proposed, steppedGrids).map { placement in
                let minimum = constraints[placement.windowID]!.minimumSize
                return Placement(windowID: placement.windowID,
                    frame: placement.frame.clamped(to: workArea, minimumSize: minimum))
            }
        }
        func rectangle(_ rectangle: SavedLayoutRectangle) throws {
            guard let id = assignments[rectangle.slot], let window = byID[id] else { return }
            let minimum = window.constraints.isResizable ? constraints[id]!.minimumSize : window.frame.size
            guard minimum.width <= workArea.size.width, minimum.height <= workArea.size.height else {
                throw savedLayoutError("$.slots", "A matched window's required size is larger than the work area. No plan was produced.")
            }
            var desired = rectangle.rect.frame(in: workArea)
            if !window.constraints.isResizable { desired.size = window.frame.size }
            let frame = desired.clamped(to: workArea, minimumSize: minimum)
            let proposed = [Placement(windowID: id, frame: frame)]
            placements += window.constraints.isResizable ? steppedRequests(proposed) : proposed
        }
        var paneIDs: [String: UUID] = [:]
        func tree(_ node: SavedLayoutNode, path: String) -> BentoNode {
            let id = stableUUID("saved-layout:" + path)
            switch node {
            case let .slot(slot): return assignments[slot].map(BentoNode.leaf) ?? .vacant(id)
            case let .group(group): paneIDs[group] = id; return .vacant(id)
            case .empty: return .vacant(id)
            case let .split(axis, ratios, children):
                return .partition(BentoPartition(id: id, axis: axis,
                    children: children.enumerated().map { tree($0.element, path: path + ".\($0.offset)") },
                    ratios: ratios, boundaryIDs: (0..<(children.count - 1)).map { stableUUID("saved-layout:\(path):boundary:\($0)") }))
            }
        }
        switch document.mode {
        case .manual:
            for value in document.windows { try rectangle(value) }
            target = .manual
        case .bento, .tabbed:
            // Semantic validation above guarantees a nonempty, well-formed tree.
            let root = tree(document.layout!, path: "root")
            var base = BentoLayoutState(root: root, floatingWindowIDs: floatingIDs,
                                       metrics: BentoLayoutMetrics(paneGap: document.paneGap))
            if document.mode == .bento {
                if document.extraWindows == .addAsPanes {
                    let snapshots = windows.map {
                        WindowSnapshot(id: $0.id, processIdentifier: 0, bundleIdentifier: $0.bundleID,
                            frame: $0.frame, displayID: DisplayID(rawValue: "saved-layout-plan"), constraints: constraints[$0.id]!)
                    }
                    for window in fill.orderedWindows where extras[window.id] == .floating && window.matchingFrame == nil {
                        guard (base.root?.windowIDs.count ?? 0) < 6 else { break }
                        // The normal insert can consume vacancies. Protect deliberate empty nodes
                        // by splitting a real pane instead. The smallest ID is the stable focus.
                        let focus = base.root?.windowIDs.sorted().first
                        var proposed: BentoLayoutState
                        if !base.vacantFrames(in: workArea).isEmpty, let focus {
                            proposed = base
                            proposed.setFloating(false, windowID: window.id)
                            proposed.split(focus, inserting: window.id, in: workArea)
                        } else if !base.vacantFrames(in: workArea).isEmpty {
                            continue
                        } else {
                            proposed = BentoPlanner().plan(state: .init(layout: base),
                                observation: .init(bounds: workArea, windows: snapshots, focusedWindowID: focus), intent: .insert(window.id)).state.layout
                        }
                        if proposed.root?.windowIDs.contains(window.id) == true,
                           let fitted = BentoConstraintSolver().solve(state: proposed, in: workArea, constraints: constraints) {
                            base = fitted; extras[window.id] = .addedAsPane
                        }
                    }
                }
                guard let fitted = BentoConstraintSolver().solve(state: base, in: workArea, constraints: constraints) else {
                    throw savedLayoutError("$.layout", "This layout cannot fit the matched windows' minimum sizes in the current work area.")
                }
                placements = steppedRequests(fitted.placements(in: workArea, constraints: constraints))
                target = .bento(fitted)
            } else {
                var base = base
                base.floatingWindowIDs.formUnion(assignments.values)
                base.floatingWindowIDs.formUnion(extras.keys)
                guard var state = TabbedLayoutState(adopting: base, presentation: tabbedPresentation) else {
                    throw savedLayoutError("$.layout", "The Tabbed pane tree could not be built.")
                }
                for group in document.groups {
                    guard let paneID = paneIDs[group.id] else { continue }
                    let tabs = fill.tabs[group.id] ?? []
                    for id in tabs { state.move(id, to: paneID) }
                    if let selected = fill.selectedTabs[group.id] { state.select(selected) }
                }
                let snapshots = windows.map {
                    WindowSnapshot(id: $0.id, processIdentifier: 0, bundleIdentifier: $0.bundleID,
                        frame: $0.frame, displayID: DisplayID(rawValue: "saved-layout-plan"), constraints: constraints[$0.id]!)
                }
                do {
                    state = try state.fittingMinimumWidths(in: workArea, windows: snapshots)
                    state = state.fittingSteppedGrids(steppedGrids, in: workArea, windows: snapshots)
                    placements = TabbedLayoutState.requestingSteppedGrids(
                        try state.placements(in: workArea, windows: snapshots), steppedGrids)
                    // Hidden tabs may keep a larger minimum without growing the selected pane.
                    placements = placements.map { placement in
                        guard !state.selectedWindowIDs.contains(placement.windowID),
                              let windowConstraints = constraints[placement.windowID], windowConstraints.isResizable else { return placement }
                        return Placement(windowID: placement.windowID,
                            frame: placement.frame.clamped(to: workArea, minimumSize: windowConstraints.minimumSize))
                    }
                } catch {
                    throw savedLayoutError("$.layout", "This Tabbed layout cannot fit the selected windows' minimum sizes in the current work area.")
                }
                target = .tabbed(state)
            }
        case .linked:
            throw savedLayoutError("$.mode", "Choose Manual, Adaptive, or Tabbed.")
        }
        for value in document.floats { try rectangle(value) }
        // AppKit windows round fractional logical-point targets during placement.
        let changed = placements.filter { placement in
            byID[placement.windowID]?.frame.approximatelyEquals(placement.frame, tolerance: 1) != true
        }.sorted { $0.windowID < $1.windowID }
        // Insertion can turn a provisional floating extra into a pane. Only final
        // floating members can be included as deliberate floats in capture signatures.
        let comparisonFloatingIDs = Set(document.floats.compactMap { assignments[$0.slot] })
            .union(extras.compactMap { $0.value == .floating ? $0.key : nil })
        let needsSessionUpdate = currentSession.map { current in
            if current.mode != target.mode { return true }
            if case .manual = current { return false }
            let bundleIDs = Dictionary(uniqueKeysWithValues: windows.map { ($0.id, $0.bundleID) })
            let frames = Dictionary(uniqueKeysWithValues: windows.map { ($0.id, $0.frame) })
            func signature(_ session: SavedLayoutSession) throws -> SavedLayoutDocument {
                try SavedLayoutCapture.capture(name: document.name, input: .init(session: session,
                    bundleIDs: bundleIDs, frames: frames, workArea: workArea,
                    deliberateFloatingWindowIDs: comparisonFloatingIDs))
            }
            // Slot names are assigned in traversal order. Compare window membership as well,
            // because two windows of one app can otherwise have identical signatures.
            guard let observed = try? signature(current), let desired = try? signature(target) else { return true }
            return observed != desired || membership(current) != membership(target)
        }
        return SavedLayoutApplyPlan(assignments: assignments, placements: changed,
            slotReasons: fill.reasons, extras: extras,
            emptySlots: document.slots.filter { assignments[$0.id] == nil }.map(\.id),
            unmatchedWindowIDs: (extras.compactMap { $0.value == .floating || $0.value == .untouched ? $0.key : nil }
                + fill.unassignedForeignWindowIDs).sorted(),
            targetSession: target, needsSessionUpdate: needsSessionUpdate)
    }

    private static func membership(_ session: SavedLayoutSession) -> [[WindowID]] {
        switch session {
        case .manual: return []
        case let .bento(state): return [state.root?.windowIDs ?? []]
        case let .tabbed(state):
            func walk(_ node: BentoNode) -> [[WindowID]] {
                switch node {
                case let .partition(partition): return partition.children.flatMap(walk)
                case let .leaf(id):
                    guard let pane = state.pane(containing: id) else { return [[id]] }
                    return [pane.tabs + (pane.selected.map { [$0] } ?? [])]
                case .vacant: return [[]]
                }
            }
            return state.layout.root.map(walk) ?? []
        }
    }
}
