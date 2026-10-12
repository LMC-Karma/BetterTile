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
    /// be invisible.
    func sharedCurtainStackingRepair(
        order: [TabbedStackEntry],
        curtainBounds: BTRect,
        aboveCurtain: Set<WindowID> = []
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
        let selectedIndices = selected.compactMap { position[$0] }
        guard let backmost = selectedIndices.max() else { return nil }
        let exposed = Set(order.indices.filter { index in
            index < backmost && order[index].windowID.map { hidden.contains($0) } == true
        })
        // Floating windows behind the backmost selected tab would be covered
        // by the curtain. Raise them, back to front, above every pane.
        let buried = order.indices.filter { index in
            index > backmost && order[index].windowID.map { aboveCurtain.contains($0) } == true
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
            if id.map({ !hidden.contains($0) && !selected.contains($0) }) ?? true,
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
}

public extension TabbedLayoutState {
    /// AXRaise makes a window its application's main window. When a repair
    /// raises another window of the key window's application, that
    /// application would move keyboard focus to the raised window. Raising
    /// the key window last keeps focus where the user put it. A hidden tab is
    /// never raised: it must stay behind the curtain.
    func keyPreservingRaisePlan(
        _ plan: [WindowID],
        keyWindowID: WindowID?,
        processIdentifiers: [WindowID: Int32]
    ) -> [WindowID] {
        guard let keyWindowID, let keyProcess = processIdentifiers[keyWindowID] else { return plan }
        let hidden = Set(panes.flatMap(\.tabs)).subtracting(selectedWindowIDs)
        guard !hidden.contains(keyWindowID),
              plan.contains(where: { $0 != keyWindowID && processIdentifiers[$0] == keyProcess })
        else { return plan }
        return plan.filter { $0 != keyWindowID } + [keyWindowID]
    }
}
