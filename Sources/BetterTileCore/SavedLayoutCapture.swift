import Foundation

/// Process-local state only. This enum is deliberately not Codable.
public enum SavedLayoutSession: Equatable, Sendable {
    case manual
    case bento(BentoLayoutState)
    case tabbed(TabbedLayoutState)

    public var mode: LayoutMode {
        switch self { case .manual: .manual; case .bento: .bento; case .tabbed: .tabbed }
    }
}

public struct SavedLayoutCaptureInput: Sendable {
    public var session: SavedLayoutSession
    public var bundleIDs: [WindowID: String]
    public var frames: [WindowID: BTRect]
    public var workArea: BTRect
    /// The caller distinguishes deliberate floats from automatic floats.
    public var deliberateFloatingWindowIDs: Set<WindowID>

    public init(session: SavedLayoutSession, bundleIDs: [WindowID: String], frames: [WindowID: BTRect],
                workArea: BTRect, deliberateFloatingWindowIDs: Set<WindowID> = []) {
        self.session = session; self.bundleIDs = bundleIDs; self.frames = frames
        self.workArea = workArea; self.deliberateFloatingWindowIDs = deliberateFloatingWindowIDs
    }
}

public enum SavedLayoutCapture {
    public static func capture(name: String, input: SavedLayoutCaptureInput) throws -> SavedLayoutDocument {
        guard validSavedLayoutBounds(input.workArea) else {
            throw savedLayoutError("$.workArea", "Use a finite work area with positive width and height.")
        }
        var document = SavedLayoutDocument(name: name, mode: input.session.mode)
        var slotIDs: [WindowID: String] = [:]
        func slot(_ id: WindowID) throws -> String {
            if let existing = slotIDs[id] { return existing }
            guard let bundleID = input.bundleIDs[id] else {
                throw savedLayoutError("$.bundleIDs", "An included window has no app bundle ID. Capture was not saved.")
            }
            let value = "slot-\(slotIDs.count + 1)"
            slotIDs[id] = value
            document.slots.append(.init(id: value, prefer: [.app(bundleID)]))
            return value
        }
        func rectangle(_ id: WindowID) throws -> SavedLayoutRectangle {
            guard let frame = input.frames[id], validSavedLayoutBounds(frame) else {
                throw savedLayoutError("$.frames", "An included window has no finite, positive frame. Capture was not saved.")
            }
            return try .init(slot: slot(id), rect: NormalizedRect(frame: frame, in: input.workArea))
        }
        var panes: [BentoTabbedPane] = []
        var floating: Set<WindowID> = []
        let root: BentoNode?
        switch input.session {
        case .manual:
            root = nil
            floating = input.deliberateFloatingWindowIDs
            for id in input.frames.keys.sorted() where !floating.contains(id) {
                document.windows.append(try rectangle(id))
            }
        case let .bento(state):
            root = state.root; floating = state.floatingWindowIDs; document.paneGap = state.metrics.paneGap
        case let .tabbed(state):
            root = state.layout.root; floating = state.floatingWindowIDs
            document.paneGap = state.layout.metrics.paneGap; panes = state.groups.panes
        }
        guard input.deliberateFloatingWindowIDs.isSubset(of: floating) else {
            throw savedLayoutError("$.floats", "A deliberate floating window still belongs to the layout tree.")
        }
        var capturedPanes = Set<UUID>()
        func node(_ runtime: BentoNode) throws -> SavedLayoutNode {
            if input.session.mode == .tabbed {
                let pane: BentoTabbedPane?
                switch runtime {
                case let .leaf(id): pane = panes.first { $0.selected == id }
                case let .vacant(id): pane = panes.first { $0.id == id }
                case .partition: pane = nil
                }
                if let pane {
                    guard capturedPanes.insert(pane.id).inserted else {
                        throw savedLayoutError("$.layout", "A pane appears more than once in the current layout.")
                    }
                    let id = "group-\(document.groups.count + 1)"
                    let members = try pane.tabs.map(slot)
                    let selected = try pane.selected.map(slot)
                    document.groups.append(.init(id: id, slots: members, selected: selected))
                    return .group(id)
                }
            }
            switch runtime {
            case let .leaf(id): return .slot(try slot(id))
            case .vacant: return .empty
            case let .partition(partition):
                return try .split(axis: partition.axis, ratios: partition.ratios, children: partition.children.map(node))
            }
        }
        document.layout = try root.map { try node(BentoLayoutState.normalized($0)) }
        for id in input.deliberateFloatingWindowIDs.sorted() { document.floats.append(try rectangle(id)) }
        try SavedLayoutValidator.requireValid(document)
        return document
    }
}

func validSavedLayoutBounds(_ rect: BTRect) -> Bool {
    [rect.minX, rect.minY, rect.maxX, rect.maxY, rect.size.width, rect.size.height].allSatisfy(\.isFinite) && !rect.isEmpty
}

func savedLayoutError(_ path: String, _ message: String) -> SavedLayoutValidationError {
    .init(issues: [.init(path: path, message: message)])
}
