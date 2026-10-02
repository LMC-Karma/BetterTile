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
    /// Windows to raise, back to front, so no hidden tab stays in front of its
    /// pane's selected tab. Every other overlapping pair keeps its order, so a
    /// floating window that was in front stays in front. Empty when the order
    /// is already right, or when a window that must stay in front cannot be
    /// raised: covering it would be worse than a visible hidden tab.
    func stackingRepair(order: [TabbedStackEntry]) -> [WindowID] {
        var position: [WindowID: Int] = [:]
        for (index, entry) in order.enumerated() {
            if let id = entry.windowID, position[id] == nil { position[id] = index }
        }
        // Each exposed hidden tab goes directly behind its selected tab.
        var behind: [Int: [Int]] = [:]
        var exposed: Set<Int> = []
        for pane in panes {
            guard let selected = pane.selected, let selectedIndex = position[selected] else { continue }
            for tab in pane.tabs where tab != selected {
                guard let index = position[tab], index < selectedIndex else { continue }
                behind[selectedIndex, default: []].append(index)
                exposed.insert(index)
            }
        }
        guard !exposed.isEmpty else { return [] }
        let target = order.indices.filter { !exposed.contains($0) }
            .flatMap { [$0] + (behind[$0]?.sorted() ?? []) }
        var rank: [Int: Int] = [:]
        for (targetRank, index) in target.enumerated() { rank[index] = targetRank }

        // Raising moves a window to the front. Anything that must stay in
        // front of a raised window it overlaps is raised again after it.
        var raised = Set(behind.keys)
        var grew = true
        while grew {
            grew = false
            for index in order.indices where !raised.contains(index) {
                let mustStayInFront = raised.contains { other in
                    rank[index, default: 0] < rank[other, default: 0]
                        && order[index].frame.intersection(order[other].frame) != nil
                }
                if mustStayInFront {
                    raised.insert(index)
                    grew = true
                }
            }
        }
        let plan = raised.sorted { rank[$0, default: 0] > rank[$1, default: 0] }.map { order[$0].windowID }
        guard plan.allSatisfy({ $0 != nil }) else { return [] }
        return plan.compactMap { $0 }
    }
}
