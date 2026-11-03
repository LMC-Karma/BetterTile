import Foundation

/// One Saved Layout slot. Preferences stay at the slot's position when occupants swap.
public struct FollowedSlot: Hashable, Sendable {
    public enum AdaptiveAnchor: Hashable, Sendable {
        case window(WindowID)
        case vacancy(UUID)
    }

    public enum Anchor: Hashable, Sendable {
        case adaptive(AdaptiveAnchor)
        case tabbedPane(UUID)
    }

    public let slotID: String
    public let preferences: [String]
    public internal(set) var anchor: Anchor
}

/// Process-local following state. It is deliberately not persisted.
public struct FollowedLayout: Hashable, Sendable {
    public indirect enum Topology: Hashable, Sendable {
        case leaf
        case split(SplitAxis, [Topology])
    }

    public struct Shape: Hashable, Sendable {
        public let mode: LayoutMode
        public let topology: Topology
        public let anchors: [FollowedSlot.Anchor]

        fileprivate init?(session: LayoutSession) {
            guard session.mode == .bento || session.mode == .tabbed,
                  let root = session.bentoState.root else { return nil }
            let tabbed = session.tabbedState
            var anchors: [FollowedSlot.Anchor] = []
            func walk(_ node: BentoNode) -> Topology? {
                switch node {
                case let .partition(partition):
                    let children = partition.children.compactMap(walk)
                    guard children.count == partition.children.count else { return nil }
                    return .split(partition.axis, children)
                case let .leaf(id):
                    if session.mode == .tabbed {
                        guard let pane = tabbed?.pane(containing: id) else { return nil }
                        anchors.append(.tabbedPane(pane.id))
                    } else {
                        anchors.append(.adaptive(.window(id)))
                    }
                case let .vacant(id):
                    if session.mode == .tabbed {
                        guard tabbed?.panes.contains(where: { $0.id == id && $0.tabs.isEmpty }) == true else { return nil }
                        anchors.append(.tabbedPane(id))
                    } else {
                        anchors.append(.adaptive(.vacancy(id)))
                    }
                }
                return .leaf
            }
            guard let topology = walk(root), Set(anchors).count == anchors.count else { return nil }
            self.mode = session.mode
            self.topology = topology
            self.anchors = anchors
        }
    }

    public let layoutFileID: String
    public let layoutName: String
    public private(set) var slots: [FollowedSlot]
    public private(set) var shape: Shape
    /// Focus-covered peers return to their own pane even for Any-window slots.
    private(set) var returnVacancies: [WindowID: UUID] = [:]

    /// Call only with the target session of a successfully applied plan.
    /// File identity belongs to the library, not to the portable document.
    public static func make(
        layoutFileID: String,
        document: SavedLayoutDocument,
        plan: SavedLayoutApplyPlan,
        expandedPreferences: [String: [String]],
        session: LayoutSession
    ) -> Self? {
        guard document.keepForNewWindows, session.mode == document.mode,
              let shape = Shape(session: session), let root = document.layout else { return nil }
        switch plan.targetSession {
        case let .bento(layout): guard session.bentoState.root == layout.root else { return nil }
        case let .tabbed(state):
            guard let committed = session.tabbedState, committed.layout.root == state.layout.root,
                  committed.panes == state.panes else { return nil }
        case .manual: return nil
        }
        var anchors: [String: FollowedSlot.Anchor] = [:]
        func walk(_ node: SavedLayoutNode, path: String) {
            switch node {
            case let .slot(slot):
                if let window = plan.assignments[slot] {
                    anchors[slot] = .adaptive(.window(window))
                } else if plan.emptySlots.contains(slot) {
                    anchors[slot] = .adaptive(.vacancy(stableUUID("saved-layout:" + path)))
                }
            case let .group(groupID):
                let paneID = stableUUID("saved-layout:" + path)
                for slot in document.groups.first(where: { $0.id == groupID })?.slots ?? [] {
                    anchors[slot] = .tabbedPane(paneID)
                }
            case let .split(_, _, children):
                for (index, child) in children.enumerated() { walk(child, path: path + ".\(index)") }
            case .empty: break
            }
        }
        walk(root, path: "root")
        var slots: [FollowedSlot] = []
        for slot in document.slots {
            guard let anchor = anchors[slot.id] else { continue } // Deliberate floats have no pane.
            guard shape.anchors.contains(anchor) else { return nil }
            slots.append(.init(slotID: slot.id, preferences: expandedPreferences[slot.id] ?? [], anchor: anchor))
        }
        // A layout without named slots has no pane that following can hold.
        guard !slots.isEmpty else { return nil }
        return Self(layoutFileID: layoutFileID, layoutName: document.name, slots: slots, shape: shape)
    }

    /// Returns nil when structure or mode changed. Ratios and occupants may change.
    /// A drop that keeps the shape counts as a swap.
    func reconciled(with session: LayoutSession) -> Self? {
        guard let current = Shape(session: session), current.mode == shape.mode,
              current.topology == shape.topology else { return nil }
        if current.mode == .tabbed, Set(current.anchors) != Set(shape.anchors) { return nil }
        var next = self
        for index in next.slots.indices {
            guard let position = shape.anchors.firstIndex(of: slots[index].anchor) else { return nil }
            next.slots[index].anchor = current.anchors[position]
        }
        next.shape = current
        next.returnVacancies = returnVacancies.filter { current.anchors.contains(.adaptive(.vacancy($0.value))) }
        return next
    }

    func anchorsWindow(_ id: WindowID, in layout: BentoLayoutState) -> Bool {
        adaptiveSlots(in: layout)?.contains { $0.anchor == .adaptive(.window(id)) } == true
    }

    /// Validate the whole shape before consulting positions, even between reducer steps.
    private func adaptiveSlots(in layout: BentoLayoutState) -> [FollowedSlot]? {
        let session = LayoutSession(displayID: .init(rawValue: "following"), mode: .bento, bentoState: layout)
        return reconciled(with: session)?.slots
    }

    mutating func rememberReturn(of windowID: WindowID, to vacancy: UUID) {
        returnVacancies[windowID] = vacancy
    }

    mutating func forgetReturn(of windowID: WindowID) {
        returnVacancies.removeValue(forKey: windowID)
    }

    func hasReturnVacancy(for windowID: WindowID, in layout: BentoLayoutState) -> Bool {
        guard let vacancy = returnVacancies[windowID] else { return false }
        return adaptiveSlots(in: layout)?.contains { $0.anchor == .adaptive(.vacancy(vacancy)) } == true
    }

    func preferredVacancy(for windowID: WindowID, bundleID: String?, in layout: BentoLayoutState) -> UUID? {
        guard let slots = adaptiveSlots(in: layout) else { return nil }
        if let vacancy = returnVacancies[windowID], slots.contains(where: { $0.anchor == .adaptive(.vacancy(vacancy)) }) {
            return vacancy
        }
        return preferredAnchor(for: bundleID, slots: slots) {
            if case .adaptive(.vacancy) = $0 { return true }; return false
        }.flatMap { if case let .adaptive(.vacancy(id)) = $0 { return id }; return nil }
    }

    func preferredPane(for bundleID: String?, in state: TabbedLayoutState) -> UUID? {
        var session = LayoutSession(displayID: .init(rawValue: "following"), mode: .tabbed)
        session.tabbedState = state
        guard let slots = reconciled(with: session)?.slots else { return nil }
        return preferredAnchor(for: bundleID, slots: slots) { anchor in
            guard case let .tabbedPane(id) = anchor else { return false }
            return state.panes.contains { $0.id == id && $0.tabs.isEmpty }
        }.flatMap { if case let .tabbedPane(id) = $0 { return id }; return nil }
    }

    private func preferredAnchor(
        for bundleID: String?, slots: [FollowedSlot], isEmpty: (FollowedSlot.Anchor) -> Bool
    ) -> FollowedSlot.Anchor? {
        guard let bundleID else { return nil }
        // Every empty matching pane can fill, even for another window of an
        // already represented app. Keep this policy decision at this seam.
        var best: (rank: Int, anchor: FollowedSlot.Anchor)?
        for slot in slots where isEmpty(slot.anchor) {
            guard let rank = slot.preferences.firstIndex(where: {
                $0.caseInsensitiveCompare(bundleID) == .orderedSame
            }) else { continue }
            if best == nil || rank < best!.rank { best = (rank, slot.anchor) }
        }
        return best?.anchor
    }
}
