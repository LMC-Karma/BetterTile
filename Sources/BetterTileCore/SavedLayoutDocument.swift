import Foundation

/// A declarative layout for one desktop on one display. Runtime identities stay outside this type.
public struct SavedLayoutDocument: Codable, Equatable, Sendable {
    public static let currentVersion = 2
    public static let fileHeader = """
    // BetterTile Saved Layout
    // Each pane has an ordered prefer list of apps or App Groups.
    // The first app listed wins. An empty list means any window.
    // BetterTile rewrites this header and removes other comments when it saves.

    """
    public var version: Int
    public var name: String
    public var mode: LayoutMode
    public var layout: SavedLayoutNode?
    public var slots: [SavedLayoutSlot]
    public var groups: [SavedLayoutGroup]
    public var windows: [SavedLayoutRectangle]
    public var floats: [SavedLayoutRectangle]
    public var extraWindows: SavedLayoutExtraWindows
    public var keepForNewWindows: Bool
    public var paneGap: Double

    public init(version: Int = currentVersion, name: String, mode: LayoutMode,
                layout: SavedLayoutNode? = nil, slots: [SavedLayoutSlot] = [],
                groups: [SavedLayoutGroup] = [], windows: [SavedLayoutRectangle] = [],
                floats: [SavedLayoutRectangle] = [], paneGap: Double = 0,
                extraWindows: SavedLayoutExtraWindows = .float, keepForNewWindows: Bool = false) {
        self.version = version
        self.name = name
        self.mode = mode
        self.layout = layout
        self.slots = slots
        self.groups = groups
        self.windows = windows
        self.floats = floats
        self.paneGap = paneGap
        self.extraWindows = extraWindows
        self.keepForNewWindows = keepForNewWindows
    }

    private enum CodingKeys: String, CodingKey {
        case version, name, mode, layout, slots, groups, windows, floats, paneGap, extraWindows, keepForNewWindows
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let fileVersion = try c.decode(Int.self, forKey: .version)
        guard fileVersion == Self.currentVersion else {
            throw DecodingError.dataCorruptedError(forKey: .version, in: c,
                debugDescription: Self.unsupportedVersionReason(fileVersion))
        }
        version = Self.currentVersion
        name = try c.decode(String.self, forKey: .name)
        mode = try c.decode(LayoutMode.self, forKey: .mode)
        layout = try c.decodeIfPresent(SavedLayoutNode.self, forKey: .layout)
        slots = try c.decode([SavedLayoutSlot].self, forKey: .slots)
        groups = try c.decodeIfPresent([SavedLayoutGroup].self, forKey: .groups) ?? []
        windows = try c.decodeIfPresent([SavedLayoutRectangle].self, forKey: .windows) ?? []
        floats = try c.decodeIfPresent([SavedLayoutRectangle].self, forKey: .floats) ?? []
        paneGap = try c.decodeIfPresent(Double.self, forKey: .paneGap) ?? 0
        extraWindows = try c.decodeIfPresent(SavedLayoutExtraWindows.self, forKey: .extraWindows) ?? .float
        keepForNewWindows = try c.decodeIfPresent(Bool.self, forKey: .keepForNewWindows) ?? false
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(name, forKey: .name)
        try c.encode(mode, forKey: .mode)
        try c.encodeIfPresent(layout, forKey: .layout)
        try c.encode(slots, forKey: .slots)
        try c.encode(groups, forKey: .groups)
        try c.encode(windows, forKey: .windows)
        try c.encode(floats, forKey: .floats)
        try c.encode(paneGap, forKey: .paneGap)
        if mode == .bento { try c.encode(extraWindows, forKey: .extraWindows) }
        try c.encode(keepForNewWindows, forKey: .keepForNewWindows)
    }

    static func unsupportedVersionReason(_ version: Int) -> String {
        version == 1 ? "Made by a development build. Save the layout again."
            : "This file uses version \(version). Only version 2 is supported. The file was kept."
    }

}

public enum SavedLayoutExtraWindows: String, Codable, Equatable, Sendable {
    case float
    case addAsPanes
}

public struct SavedLayoutSlot: Codable, Equatable, Sendable {
    public var id: String
    public var prefer: [AppPreference]
    public init(id: String, prefer: [AppPreference] = []) { self.id = id; self.prefer = prefer }

    /// One direct app preference for a slot.
    public init(id: String, bundleID: String) { self.init(id: id, prefer: [.app(bundleID)]) }


}

public struct SavedLayoutGroup: Codable, Equatable, Sendable {
    public var id: String
    public var slots: [String]
    public var selected: String?
    public init(id: String, slots: [String], selected: String? = nil) {
        self.id = id; self.slots = slots; self.selected = selected
    }
}

public struct SavedLayoutRectangle: Codable, Equatable, Sendable {
    public var slot: String
    public var rect: NormalizedRect
    public init(slot: String, rect: NormalizedRect) { self.slot = slot; self.rect = rect }
}

/// Serialization only. All splitting and fitting uses the existing runtime trees.
public indirect enum SavedLayoutNode: Codable, Equatable, Sendable {
    case slot(String)
    case group(String)
    case empty
    case split(axis: SplitAxis, ratios: [Double], children: [SavedLayoutNode])

    private enum CodingKeys: String, CodingKey { case slot, group, empty, split, ratios, children }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kinds: [CodingKeys] = [.slot, .group, .empty, .split]
        guard kinds.filter({ c.contains($0) }).count == 1 else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                debugDescription: "Choose exactly one of slot, group, empty, or split for this node."))
        }
        if c.contains(.slot) { self = .slot(try c.decode(String.self, forKey: .slot)) }
        else if c.contains(.group) { self = .group(try c.decode(String.self, forKey: .group)) }
        else if c.contains(.empty) {
            guard try c.decode(Bool.self, forKey: .empty) else {
                throw DecodingError.dataCorruptedError(forKey: .empty, in: c, debugDescription: "Use true for an empty pane.")
            }
            self = .empty
        } else {
            let rawAxis = try c.decode(String.self, forKey: .split)
            guard let axis = SplitAxis(rawValue: rawAxis) else {
                throw DecodingError.dataCorruptedError(forKey: .split, in: c,
                    debugDescription: "Choose vertical (columns) or horizontal (rows).")
            }
            self = .split(axis: axis, ratios: try c.decode([Double].self, forKey: .ratios),
                          children: try c.decode([Self].self, forKey: .children))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .slot(id): try c.encode(id, forKey: .slot)
        case let .group(id): try c.encode(id, forKey: .group)
        case .empty: try c.encode(true, forKey: .empty)
        case let .split(axis, ratios, children):
            try c.encode(axis.rawValue, forKey: .split)
            try c.encode(ratios, forKey: .ratios)
            try c.encode(children, forKey: .children)
        }
    }
}
