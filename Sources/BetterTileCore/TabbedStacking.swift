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
    func stackingRepair(order: [TabbedStackEntry]) -> [WindowID] {
        sharedCurtainStackingRepair(order: order) ?? []
    }

    /// A back-to-front raise plan that puts all selected tabs above all
    /// inactive tabs on this display. Nil means the order cannot be repaired
    /// safely; an empty plan means a shared curtain can already be inserted.
    func sharedCurtainStackingRepair(order: [TabbedStackEntry], curtainBounds: BTRect? = nil) -> [WindowID]? {
        var position: [WindowID: Int] = [:]
        for (index, entry) in order.enumerated() {
            if let id = entry.windowID, position[id] == nil { position[id] = index }
        }
        let selected = Set(selectedWindowIDs)
        guard !selected.isEmpty, selected.allSatisfy({ position[$0] != nil }) else { return nil }
        let hidden = Set(panes.flatMap(\.tabs)).subtracting(selected)
        let selectedIndices = selected.compactMap { position[$0] }
        guard let backmost = selectedIndices.max() else { return nil }
        let exposed = Set(order.indices.filter { index in
            index < backmost && order[index].windowID.map { hidden.contains($0) } == true
        })
        guard !exposed.isEmpty else { return [] }
        // Move the exposed inactive tabs behind the backmost selected tab.
        // All other windows retain their relative order.
        let target = order.indices.filter { !exposed.contains($0) }
            .flatMap { $0 == backmost ? [$0] + exposed.sorted() : [$0] }
        var rank: [Int: Int] = [:]
        for (targetRank, index) in target.enumerated() { rank[index] = targetRank }
        var raised = Set(selectedIndices.filter { index in exposed.contains { $0 < index } })
        if let curtainBounds {
            for index in order.indices where index < backmost {
                let id = order[index].windowID
                if id.map({ !hidden.contains($0) && !selected.contains($0) }) ?? true,
                   order[index].frame.intersection(curtainBounds) != nil { raised.insert(index) }
            }
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
        return plan.compactMap { $0 }
    }
}
