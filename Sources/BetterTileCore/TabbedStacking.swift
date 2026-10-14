import Foundation

/// One on-screen normal-level window in WindowServer order. Tabbed reads the
/// real order to repair it; it never infers order from frames.
public struct TabbedStackEntry: Hashable, Sendable {
    /// The managed window, or nil when BetterTile cannot raise it.
    public var windowID: WindowID?
    public var frame: BTRect

    public init(windowID: WindowID?, frame: BTRect) {
        self.windowID = windowID
        self.frame = frame
    }
}

public extension TabbedLayoutState {
    /// A back-to-front raise plan that puts all selected tabs above all
    /// inactive tabs on this display. Nil means the order cannot be repaired
    /// safely; an empty plan means a shared curtain can already be inserted.
    /// `aboveCurtain` names windows outside the panes, such as floating
    /// windows, that must never end up behind the curtain where they would
    /// be invisible. `keptInPlace` names floating windows that keep their
    /// place among the selected tabs; the curtain goes behind the backmost of
    /// them (see `curtainAnchor`). `ignoresRaise` names those of background
    /// applications, whose raise macOS often ignores. Behind a hidden tab,
    /// such a window is left under the curtain, since a raise that cannot
    /// verify would repeat; its application's activation lifts it later.
    func sharedCurtainStackingRepair(
        order: [TabbedStackEntry],
        curtainBounds: BTRect,
        aboveCurtain: Set<WindowID> = [],
        keptInPlace: Set<WindowID> = [],
        ignoresRaise: Set<WindowID> = []
    ) -> [WindowID]? {
        var position: [WindowID: Int] = [:]
        for (index, entry) in order.enumerated() {
            if let id = entry.windowID, position[id] == nil { position[id] = index }
        }
        let selected = Set(selectedWindowIDs)
        // Missing inactive identities could conceal an exposed tab among
        // unreadable windows. A curtain needs verified order for every tab.
        guard !selected.isEmpty, windowIDs.allSatisfy({ position[$0] != nil }) else { return nil }
        let hidden = Set(panes.flatMap(\.tabs)).subtracting(selected)
        let (anchors, leftUnder) = curtainAnchors(position: position, keptInPlace: keptInPlace, ignoresRaise: ignoresRaise)
        let selectedIndices = anchors.compactMap { position[$0] }
        guard let backmost = selectedIndices.max() else { return nil }
        let exposed = Set(order.indices.filter { index in
            index < backmost && order[index].windowID.map { hidden.contains($0) } == true
        })
        // Floating windows behind the backmost selected tab would be covered
        // by the curtain. Raise them, back to front, above every pane.
        let buried = order.indices.filter { index in
            index > backmost && order[index].windowID.map { aboveCurtain.contains($0) && !anchors.contains($0) && !leftUnder.contains($0) } == true
                && order[index].frame.intersection(curtainBounds) != nil
        }
        guard !exposed.isEmpty || !buried.isEmpty else { return [] }
        guard !exposed.isEmpty else {
            return buried.sorted(by: >).compactMap { order[$0].windowID }
        }
        // Move the exposed inactive tabs behind the backmost selected tab.
        // All other windows retain their relative order.
        let target = order.indices.filter { !exposed.contains($0) }
            .flatMap { $0 == backmost ? [$0] + exposed.sorted() : [$0] }
        var rank: [Int: Int] = [:]
        for (targetRank, index) in target.enumerated() { rank[index] = targetRank }
        var raised = Set(selectedIndices.filter { index in exposed.contains { $0 < index } })
        for index in order.indices where index < backmost {
            let id = order[index].windowID
            if id.map({ !hidden.contains($0) && !anchors.contains($0) && !leftUnder.contains($0) }) ?? true,
               order[index].frame.intersection(curtainBounds) != nil { raised.insert(index) }
        }
        var grew = true
        while grew {
            grew = false
            for index in order.indices where !raised.contains(index) {
                let mustStayInFront = raised.contains { other in
                    rank[index, default: 0] < rank[other, default: 0]
                        && order[index].frame.intersection(order[other].frame) != nil
                }
                if mustStayInFront { raised.insert(index); grew = true }
            }
        }
        let plan = raised.sorted { rank[$0, default: 0] > rank[$1, default: 0] }.map { order[$0].windowID }
        guard plan.allSatisfy({ $0 != nil }) else { return nil }
        return plan.compactMap { $0 } + buried.sorted(by: >).compactMap { order[$0].windowID }
    }

    /// The window the curtain goes directly behind in a repaired order: the
    /// backmost selected tab or window kept in place.
    func curtainAnchor(order: [TabbedStackEntry], keptInPlace: Set<WindowID> = [],
                       ignoresRaise: Set<WindowID> = []) -> WindowID? {
        var position: [WindowID: Int] = [:]
        for (index, entry) in order.enumerated() {
            if let id = entry.windowID, position[id] == nil { position[id] = index }
        }
        let anchors = curtainAnchors(position: position, keptInPlace: keptInPlace, ignoresRaise: ignoresRaise).anchors
        return order.last(where: { $0.windowID.map(anchors.contains) == true })?.windowID
    }

    /// Selected tabs and kept windows, and the kept windows that ignore a
    /// raise and sit behind a hidden tab, which the curtain covers instead.
    private func curtainAnchors(position: [WindowID: Int], keptInPlace: Set<WindowID>,
                                ignoresRaise: Set<WindowID>) -> (anchors: Set<WindowID>, leftUnder: Set<WindowID>) {
        let selected = Set(selectedWindowIDs)
        let frontHidden = Set(panes.flatMap(\.tabs)).subtracting(selected).compactMap { position[$0] }.min() ?? .max
        let kept = keptInPlace.subtracting(windowIDs)
        let leftUnder = kept.intersection(ignoresRaise).filter { position[$0].map { $0 > frontHidden } ?? false }
        return (selected.union(kept.subtracting(leftUnder)), leftUnder)
    }
}

/// The window that has keyboard focus in the frontmost application, as a
/// Tabbed stacking repair must respect it.
public enum TabbedKeyWindow: Hashable, Sendable {
    /// A tab, a standard window including one the user floated, a dialog,
    /// or a floating panel. A raise of another window of its application
    /// takes focus from it, so the repair raises it again last.
    case window(WindowID)
    /// A transient window has focus: a popup that closes when it loses
    /// focus, such as a browser toolbar bubble, or a window whose focus
    /// cannot be confirmed. No raise gives focus back.
    case transient(processIdentifier: Int32)
}

/// A raise plan and whether some of its raises wait for focus to return.
public struct TabbedKeyPreservingPlan: Equatable, Sendable {
    public var raises: [WindowID]
    /// True when raises were left out to keep a transient window's focus.
    public var isDeferred: Bool

    public init(raises: [WindowID], isDeferred: Bool) {
        self.raises = raises
        self.isDeferred = isDeferred
    }
}

public extension TabbedLayoutState {
    /// AXRaise makes a window its application's main window. When a repair
    /// raises another window of the key window's application, that
    /// application would move keyboard focus to the raised window. Raising
    /// the key window last keeps focus where the user put it. A hidden tab is
    /// never raised: it must stay behind the curtain.
    ///
    /// A transient key window cannot get focus back that way. The plan then
    /// leaves out every window of its application, and every other raise
    /// that would cover one of that application's windows. Those raises wait
    /// until focus returns; the rest of the repair runs now.
    func keyPreservingRaisePlan(
        _ plan: [WindowID],
        key: TabbedKeyWindow?,
        processIdentifiers: [WindowID: Int32],
        frames: [WindowID: BTRect] = [:]
    ) -> TabbedKeyPreservingPlan {
        switch key {
        case nil:
            return TabbedKeyPreservingPlan(raises: plan, isDeferred: false)
        case let .transient(keyProcess):
            let protected = frames.filter { processIdentifiers[$0.key] == keyProcess }.map(\.value)
            let raises = plan.filter { id in
                guard processIdentifiers[id] != keyProcess else { return false }
                guard let frame = frames[id] else { return true }
                return !protected.contains { $0.intersection(frame) != nil }
            }
            return TabbedKeyPreservingPlan(raises: raises, isDeferred: raises.count != plan.count)
        case let .window(keyWindowID):
            guard let keyProcess = processIdentifiers[keyWindowID] else {
                return TabbedKeyPreservingPlan(raises: plan, isDeferred: false)
            }
            let hidden = Set(panes.flatMap(\.tabs)).subtracting(selectedWindowIDs)
            guard !hidden.contains(keyWindowID),
                  plan.contains(where: { $0 != keyWindowID && processIdentifiers[$0] == keyProcess })
            else { return TabbedKeyPreservingPlan(raises: plan, isDeferred: false) }
            return TabbedKeyPreservingPlan(raises: plan.filter { $0 != keyWindowID } + [keyWindowID], isDeferred: false)
        }
    }
}
