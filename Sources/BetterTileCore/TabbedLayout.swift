import Foundation

public enum TabbedPreset: String, Codable, CaseIterable, Sendable {
    case single, columns, rows, focus, grid
    public var title: String {
        switch self {
        case .single: "One Pane"
        case .columns: "Two Columns"
        case .rows: "Two Rows"
        case .focus: "Bento — Focus"
        case .grid: "Four Panes"
        }
    }
    public var paneCount: Int {
        switch self { case .single: 1; case .columns, .rows: 2; case .focus: 3; case .grid: 4 }
    }
}

public struct TabbedPane: Hashable, Sendable, Identifiable {
    public let id: UUID
    public var tabs: [WindowID] = []
    public var selected: WindowID?
    public init(id: UUID = UUID()) { self.id = id }

    /// The tab index a dragged window drops at, from the strip edge under
    /// the pointer. `order` is the strip as drawn; when it shows the dragged
    /// window, an edge after that slot counts it once.
    public func dropIndex(atEdge edge: Int, in order: [WindowID], dragging id: WindowID) -> Int {
        var index = edge
        if let slot = order.firstIndex(of: id), slot < index { index -= 1 }
        return min(tabs.count - (tabs.contains(id) ? 1 : 0), max(0, index))
    }
}

public enum TabbedEdge: String, CaseIterable, Sendable { case left, right, top, bottom }
public enum TabbedLayoutError: Error, LocalizedError {
    case panesTooSmall
    public var errorDescription: String? { "This layout is too small for one or more windows. Enlarge the pane or choose fewer panes." }
}
