import Foundation

public enum TabbedPresetGrouping: CaseIterable, Sendable {
    case keepTabGroups, distributeWindows
}

/// The reserve is independent of whether an auto-hidden bar is revealed.
public enum TabbedStripPresentation: String, Codable, CaseIterable, Sendable {
    case alwaysVisible, compact, autoHide

    public var title: String {
        switch self {
        case .alwaysVisible: "Always visible"
        case .compact: "Compact"
        case .autoHide: "Auto-hide"
        }
    }
    public var reservedInset: Double {
        switch self { case .alwaysVisible: 34; case .compact: 24; case .autoHide: 6 }
    }
    public var barHeight: Double { self == .compact ? 24 : 34 }
}

public enum TabbedPreset: String, Codable, CaseIterable, Sendable {
    case single, columns, rows, focus, grid
    public var title: String {
        switch self {
        case .single: "Single Pane"
        case .columns: "2 Columns"
        case .rows: "2 Rows"
        case .focus: "Main + 2"
        case .grid: "2×2 Grid"
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
