import Foundation

public struct SavedLayoutIssue: Equatable, Sendable {
    public var path: String
    public var message: String
    public init(path: String, message: String) { self.path = path; self.message = message }
}

public struct SavedLayoutValidationError: Error, LocalizedError, Equatable, Sendable {
    public var issues: [SavedLayoutIssue]
    public var errorDescription: String? { issues.map { "\($0.path): \($0.message)" }.joined(separator: "\n") }
    public init(issues: [SavedLayoutIssue]) { self.issues = issues }
}

public enum SavedLayoutValidator {
    public static let maximumBytes = 1_048_576
    public static let maximumTreeDepth = 16
    public static let maximumNodes = 64
    public static let maximumSlots = 64

    public static let maximumPreferences = 16

    /// Replace line comments with spaces. Keep newlines and string bytes unchanged.
    /// Keep Foundation's existing trailing-comma support; do not enable its JSON5 parser.
    static func removingLineComments(_ data: Data) throws -> Data {
        guard data.count <= maximumBytes else {
            throw savedLayoutError("$", "Keep Saved Layout files within 1 MiB (1,048,576 bytes).")
        }
        var bytes = Array(data)
        var inString = false
        var escaped = false
        var inComment = false
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            guard byte != 0 else { throw savedLayoutError("$", "Use UTF-8 layout JSON without null bytes.") }
            if inComment {
                if byte == 10 || byte == 13 { inComment = false }
                else { bytes[index] = 32 }
            } else if inString {
                if escaped { escaped = false }
                else if byte == 92 { escaped = true }
                else if byte == 34 { inString = false }
            } else if byte == 47, index + 1 < bytes.count, bytes[index + 1] == 47 {
                bytes[index] = 32; bytes[index + 1] = 32
                inComment = true
                index += 1
            } else if byte == 34 { inString = true }
            index += 1
        }
        return Data(bytes)
    }

    /// Bounds JSON containers before Foundation or Codable can recurse. Strings do not add depth.
    private static func preflightBytes(_ data: Data) throws {
        guard data.count <= maximumBytes else {
            throw savedLayoutError("$", "Keep Saved Layout files within 1 MiB (1,048,576 bytes).")
        }
        var depth = 0
        var inString = false
        var escaped = false
        var tokenStart: Data.Index?
        func checkNumber(endingAt end: Data.Index) throws {
            guard let start = tokenStart else { return }
            if Double(String(decoding: data[start..<end], as: UTF8.self))?.isInfinite == true {
                throw savedLayoutError("$", "A number is outside the supported numeric range. Use finite numbers that fit in a 64-bit floating-point value.")
            }
        }
        for index in data.indices {
            let byte = data[index]
            guard byte != 0 else { throw savedLayoutError("$", "Use UTF-8 layout JSON without null bytes.") }
            if !inString {
                // Check unquoted tokens without relying on Foundation's parser error text.
                switch byte {
                case 9, 10, 13, 32, 34, 44, 58, 91, 93, 123, 125:
                    try checkNumber(endingAt: index)
                    tokenStart = nil
                default:
                    if tokenStart == nil { tokenStart = index }
                }
            }
            if inString {
                if escaped { escaped = false }
                else if byte == 92 { escaped = true }
                else if byte == 34 { inString = false }
            } else if byte == 34 { inString = true }
            else if byte == 123 || byte == 91 {
                depth += 1
                // Root object, then a node object and children array for each tree level.
                if depth > 2 * maximumTreeDepth + 2 {
                    throw savedLayoutError("$.layout", "Use at most 16 tree levels; the JSON containers are too deeply nested.")
                }
            } else if byte == 125 || byte == 93 { depth -= 1 }
        }
        try checkNumber(endingAt: data.endIndex)
    }

    private enum JSONShape {
        case document, node, slot, preference, group, rectangle, rect
        var keys: Set<String> {
            switch self {
            case .document: ["version", "name", "mode", "layout", "slots", "groups", "windows", "floats", "paneGap", "extraWindows", "keepForNewWindows"]
            case .node: ["slot", "group", "empty", "split", "ratios", "children"]
            case .slot: ["id", "prefer"]
            case .preference: ["app", "group"]
            case .group: ["id", "slots", "selected"]
            case .rectangle: ["slot", "rect"]
            case .rect: ["x", "y", "width", "height"]
            }
        }
    }

    /// Reject unknown keys and oversized trees before recursive SavedLayoutNode decoding.
    private static func preflightStructure(_ data: Data) throws {
        let json: Any
        do { json = try JSONSerialization.jsonObject(with: data) }
        catch { throw savedLayoutError("$", "This is not valid layout JSON. Check commas, quotes, and brackets.") }
        var pending: [(Any, JSONShape, String, Int)] = [(json, .document, "$", 0)]
        var nodes = 0
        while let (value, shape, path, depth) = pending.popLast() {
            if shape == .node {
                nodes += 1
                guard nodes <= maximumNodes, depth <= maximumTreeDepth else {
                    throw savedLayoutError(path, "Use at most 64 tree nodes and 16 tree levels, including empty panes.")
                }
            }
            guard let object = value as? [String: Any] else { continue } // Codable reports type errors.
            var allowed = shape.keys
            if shape == .node {
                let kinds = ["slot", "group", "empty", "split"].filter { object[$0] != nil }
                if kinds.count == 1, let kind = kinds.first, kind != "split" { allowed = [kind] }
            }
            if let key = Set(object.keys).subtracting(allowed).sorted().first {
                if shape == .slot, key == "bundleID" {
                    throw savedLayoutError(path + ".bundleID", "Version 2 uses prefer instead of bundleID.")
                }
                throw savedLayoutError(path + "." + key, "Unknown field \"\(key)\". Version 2 does not allow extra fields.")
            }
            func array(_ key: String, _ childShape: JSONShape?) throws {
                guard let values = object[key] as? [Any] else { return }
                if shape == .slot, key == "prefer", values.count > maximumPreferences {
                    throw savedLayoutError(path + ".prefer", "Use at most 16 preferences per slot.")
                }
                guard values.count <= maximumSlots else {
                    throw savedLayoutError(path + "." + key, "Use at most 64 entries in a Saved Layout array.")
                }
                if let childShape {
                    for (index, child) in values.enumerated().reversed() {
                        pending.append((child, childShape, path + ".\(key)[\(index)]", depth + 1))
                    }
                }
            }
            switch shape {
            case .document:
                if let layout = object["layout"] { pending.append((layout, .node, "$.layout", 1)) }
                try array("slots", .slot); try array("groups", .group)
                try array("windows", .rectangle); try array("floats", .rectangle)
            case .node:
                try array("children", .node); try array("ratios", nil)
            case .group: try array("slots", nil)
            case .rectangle:
                if let rect = object["rect"] { pending.append((rect, .rect, path + ".rect", depth)) }
            case .slot: try array("prefer", .preference)
            case .preference, .rect: break
            }
        }
    }

    private static func encoded(_ document: SavedLayoutDocument) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try Data(SavedLayoutDocument.fileHeader.utf8) + encoder.encode(document)
    }

    /// Bounds editor-built values before semantic validation or encoding can recurse.
    private static func structureIssues(_ d: SavedLayoutDocument) -> [SavedLayoutIssue] {
        if d.slots.count > maximumSlots || d.groups.count > maximumSlots ||
            d.windows.count > maximumSlots || d.floats.count > maximumSlots ||
            d.groups.contains(where: { $0.slots.count > maximumSlots }) {
            return [.init(path: "$", message: "Use at most 64 slots and at most 64 entries per array.")]
        }
        var pending = d.layout.map { [($0, "$.layout", 1)] } ?? []
        var count = 0
        while let (node, path, depth) = pending.popLast() {
            count += 1
            if count > maximumNodes || depth > maximumTreeDepth {
                return [.init(path: path, message: "Use at most 64 tree nodes and 16 tree levels, including empty panes.")]
            }
            if case let .split(_, ratios, children) = node {
                if children.count > maximumNodes || ratios.count > maximumNodes {
                    return [.init(path: path, message: "Use at most 64 tree nodes, including empty panes.")]
                }
                for (index, child) in children.enumerated().reversed() {
                    pending.append((child, path + ".children[\(index)]", depth + 1))
                }
            }
        }
        return []
    }

    /// Refuse unsupported versions before decoding the layout body.
    public static func decode(_ data: Data) throws -> SavedLayoutDocument {
        let data = try removingLineComments(data)
        try preflightBytes(data)
        struct Header: Decodable { var version: Int }
        do {
            let decoder = JSONDecoder()
            let version = try decoder.decode(Header.self, from: data).version
            guard version == SavedLayoutDocument.currentVersion else {
                throw SavedLayoutValidationError(issues: [.init(path: "$.version", message:
                    SavedLayoutDocument.unsupportedVersionReason(version))])
            }
            try preflightStructure(data)
            let document = try decoder.decode(SavedLayoutDocument.self, from: data)
            try requireValid(document)
            return document
        } catch let error as DecodingError {
            let path: [any CodingKey]
            let message: String
            switch error {
            case let .keyNotFound(key, context):
                path = context.codingPath + [key]; message = "Add the required \(key.stringValue) field."
            case let .typeMismatch(_, context):
                path = context.codingPath; message = "This value has the wrong JSON type."
            case let .valueNotFound(_, context):
                path = context.codingPath; message = "This value cannot be null."
            case let .dataCorrupted(context):
                path = context.codingPath
                if path.last?.stringValue == "mode" {
                    message = "Choose manual, bento (Adaptive), or tabbed-v1 (Tabbed)."
                } else if path.isEmpty {
                    message = "This is not valid layout JSON. Check commas, quotes, and brackets."
                } else { message = context.debugDescription }
            @unknown default:
                path = []; message = "This layout could not be decoded."
            }
            let jsonPath = path.reduce("$") { result, key in
                result + (key.intValue.map { "[\($0)]" } ?? ".\(key.stringValue)")
            }
            throw SavedLayoutValidationError(issues: [.init(path: jsonPath, message: message)])
        }
    }

    public static func encode(_ document: SavedLayoutDocument) throws -> Data {
        try requireValid(document)
        return try encoded(document)
    }

    public static func requireValid(_ document: SavedLayoutDocument) throws {
        let issues = validate(document)
        if !issues.isEmpty { throw SavedLayoutValidationError(issues: issues) }
    }

    /// The same semantic checks serve documents built by an editor and documents decoded from files.
    public static func validate(_ d: SavedLayoutDocument) -> [SavedLayoutIssue] {
        let structural = structureIssues(d)
        guard structural.isEmpty else { return structural }
        var issues: [SavedLayoutIssue] = []
        func issue(_ path: String, _ message: String) { issues.append(.init(path: path, message: message)) }
        func nonempty(_ value: String) -> Bool { !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if d.version != SavedLayoutDocument.currentVersion { issue("$.version", SavedLayoutDocument.unsupportedVersionReason(d.version)) }
        if !nonempty(d.name) { issue("$.name", "Give this layout a name.") }
        if ![LayoutMode.manual, .bento, .tabbed].contains(d.mode) {
            issue("$.mode", "Choose manual, bento (Adaptive), or tabbed-v1 (Tabbed).")
        }
        if !d.paneGap.isFinite || !(0...12).contains(d.paneGap) { issue("$.paneGap", "Use a pane gap from 0 to 12 points.") }
        if d.mode != .bento && d.extraWindows != .float {
            issue("$.extraWindows", "Only Adaptive layouts can add extra windows as panes.")
        }
        var slotIDs = Set<String>()
        for (i, slot) in d.slots.enumerated() {
            if !nonempty(slot.id) { issue("$.slots[\(i)].id", "Give this slot a nonempty ID.") }
            if !slotIDs.insert(slot.id).inserted { issue("$.slots[\(i)].id", "Slot IDs must be unique.") }
            if slot.prefer.count > maximumPreferences {
                issue("$.slots[\(i)].prefer", "Use at most 16 preferences per slot.")
                continue
            }
            var seen = Set<AppPreference>()
            for (j, item) in slot.prefer.enumerated() {
                let path = "$.slots[\(i)].prefer[\(j)]"
                let identity: AppPreference
                switch item {
                case let .app(id): identity = .app(id.lowercased())
                case let .group(name):
                    identity = .group(name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX")))
                }
                if !seen.insert(identity).inserted { issue(path, "Use each preference only once in a slot.") }
                switch item {
                case let .app(bundleID):
                    let parts = bundleID.split(separator: ".", omittingEmptySubsequences: false)
                    if parts.count < 2 || parts.contains(where: { $0.isEmpty }) ||
                        !bundleID.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || $0 == "." || $0 == "-" }) {
                        issue(path + ".app",
                              "Use an app bundle ID such as com.apple.Safari.")
                    }
                case let .group(name):
                    if !nonempty(name) { issue(path + ".group", "Give this App Group a nonempty name.") }
                }
            }
        }
        var usedSlots = Set<String>()
        func useSlot(_ id: String, _ path: String) {
            if !slotIDs.contains(id) { issue(path, "The layout refers to \"\(id)\", but no slot has that ID.") }
            if !usedSlots.insert(id).inserted { issue(path, "A slot can appear in only one place in the layout.") }
        }
        var groups: [String: SavedLayoutGroup] = [:]
        for (i, group) in d.groups.enumerated() {
            if !nonempty(group.id) { issue("$.groups[\(i)].id", "Give this group a nonempty ID.") }
            if groups.updateValue(group, forKey: group.id) != nil { issue("$.groups[\(i)].id", "Group IDs must be unique.") }
            for (j, id) in group.slots.enumerated() { useSlot(id, "$.groups[\(i)].slots[\(j)]") }
            if group.slots.isEmpty ? group.selected != nil : !group.slots.contains(group.selected ?? "") {
                issue("$.groups[\(i)].selected", "Select a slot in this group, or omit selected for an empty group.")
            }
        }
        var usedGroups = Set<String>()
        var leafCount = 0
        var tiledSlotCount = 0
        func walk(_ node: SavedLayoutNode, _ path: String, parentAxis: SplitAxis? = nil) {
            switch node {
            case let .slot(id):
                leafCount += 1
                tiledSlotCount += 1
                if d.mode != .bento { issue(path + ".slot", "Use a group leaf in Tabbed, or a rectangle in Manual.") }
                useSlot(id, path + ".slot")
            case let .group(id):
                leafCount += 1
                if d.mode != .tabbed { issue(path + ".group", "Groups belong to Tabbed layouts.") }
                if groups[id] == nil { issue(path + ".group", "Add the group entry for \"\(id)\".") }
                if !usedGroups.insert(id).inserted { issue(path + ".group", "A group can appear in only one pane.") }
            case .empty: leafCount += 1
            case let .split(axis, ratios, children):
                if axis == parentAxis { issue(path + ".split", "Combine nested splits on the same axis into one split.") }
                if children.count < 2 { issue(path + ".children", "Each split needs at least two children.") }
                if ratios.count != children.count || ratios.contains(where: { !$0.isFinite || $0 <= 0 || $0 >= 1 }) ||
                    abs(ratios.reduce(0, +) - 1) > 0.000_001 {
                    issue(path + ".ratios", "Give each child a ratio greater than 0 and less than 1. The ratios must add up to 1.")
                }
                for (i, child) in children.enumerated() { walk(child, path + ".children[\(i)]", parentAxis: axis) }
            }
        }
        if d.mode == .manual {
            if d.layout != nil { issue("$.layout", "Manual layouts use windows with relative rectangles instead of a tree.") }
        } else if let layout = d.layout { walk(layout, "$.layout") }
        else { issue("$.layout", "Add a layout tree with at least one pane.") }
        if d.mode == .bento && tiledSlotCount > 6 { issue("$.layout", "Adaptive layouts support at most six window slots.") }
        if d.mode == .tabbed && leafCount > TabbedLayoutState.maximumPaneCount { issue("$.layout", "Tabbed layouts support at most twelve panes.") }
        if d.mode != .tabbed && !d.groups.isEmpty { issue("$.groups", "Groups belong to Tabbed layouts.") }
        for (i, group) in d.groups.enumerated() where !usedGroups.contains(group.id) {
            issue("$.groups[\(i)].id", "Place this group in the layout tree.")
        }
        if d.mode != .manual && !d.windows.isEmpty { issue("$.windows", "Window rectangles belong to Manual layouts.") }
        for (key, rectangles) in [("windows", d.windows), ("floats", d.floats)] {
            for (i, rectangle) in rectangles.enumerated() {
                let path = "$.\(key)[\(i)]"
                useSlot(rectangle.slot, path + ".slot")
                if (try? rectangle.rect.validated()) == nil {
                    issue(path + ".rect", "Use a positive relative rectangle inside the work area, with values from 0 to 1.")
                }
            }
        }
        for (i, slot) in d.slots.enumerated() where !usedSlots.contains(slot.id) {
            issue("$.slots[\(i)].id", "Place this slot in the tree, a group, or a rectangle.")
        }
        if issues.isEmpty, let data = try? encoded(d), data.count > maximumBytes {
            issue("$", "The formatted file must stay within 1 MiB (1,048,576 bytes); this layout is too large.")
        }
        return issues
    }
}

/// An editor/import buffer. Failed edits retain their exact bytes and never replace the valid model.
/// It performs no disk I/O; callers must never overwrite a source file after a failed validation.
public struct SavedLayoutDraft: Sendable {
    public private(set) var source = Data()
    public private(set) var lastKnownGood: SavedLayoutDocument?
    public private(set) var issues: [SavedLayoutIssue] = []

    public init() {}

    @discardableResult
    public mutating func update(_ data: Data) -> Bool {
        source = data
        do {
            let document = try SavedLayoutValidator.decode(data)
            lastKnownGood = document
            issues = []
            return true
        } catch let error as SavedLayoutValidationError { issues = error.issues }
        catch { issues = [.init(path: "$", message: "This layout could not be read.")] }
        return false
    }
}
