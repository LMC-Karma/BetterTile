// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 LMC-Karma

import AppKit
import BetterTileCore
import Foundation

struct SavedLayoutUpdatePane {
    var id: String
    var rect: NormalizedRect
    var slots: [SavedLayoutSlot]
    var selected: String?
}

enum SavedLayoutUpdateMapping {
    static func panes(_ document: SavedLayoutDocument) -> [SavedLayoutUpdatePane] {
        let byID = Dictionary(uniqueKeysWithValues: document.slots.map { ($0.id, $0) })
        var result = SavedLayoutCanvasGeometry.panes(document).map { pane in
            let ids = SavedLayoutCanvasGeometry.slotIDs(in: pane.node, document: document)
            let selected: String?
            if case let .group(id) = pane.node { selected = document.groups.first { $0.id == id }?.selected }
            else { selected = ids.first }
            return SavedLayoutUpdatePane(id: "pane-" + pane.id, rect: pane.rect,
                slots: ids.compactMap { byID[$0] }, selected: selected)
        }
        result += (document.windows + document.floats).map {
            .init(id: "rectangle-" + $0.slot, rect: $0.rect, slots: byID[$0.slot].map { [$0] } ?? [], selected: $0.slot)
        }
        return result
    }

    /// Core's position matcher is internal. Identical explicit preferences route this synthetic
    /// Manual plan through its preferred-assignment stage, before free-pane/frontmost rules.
    /// It minimizes total squared centre distance, each old pane once. Ties use new-pane ID,
    /// then old-pane ID, in lexical order. No synthetic identity leaves this function.
    static func nearestOldPanes(old: [SavedLayoutUpdatePane], new: [SavedLayoutUpdatePane]) throws -> [String: String] {
        let bundle = "org.bettertile.update-mapping"
        let bounds = BTRect(x: 0, y: 0, width: 1200, height: 750)
        let target = SavedLayoutDocument(name: "Update mapping", mode: .manual,
            slots: new.map { .init(id: $0.id, prefer: [.app(bundle)]) },
            windows: new.map { .init(slot: $0.id, rect: $0.rect) })
        let windows = old.map { pane in
            SavedLayoutEligibleWindow(id: .init(rawValue: pane.id), bundleID: bundle,
                frame: pane.rect.frame(in: bounds), minimumSize: .init(width: 0, height: 0), matchingFrame: pane.rect)
        }
        return try SavedLayoutPlanner.plan(target, in: bounds, windows: windows).assignments.mapValues(\.rawValue)
    }

    static func combinedPreferences(_ preferences: [AppPreference]) -> [AppPreference] {
        var keys: Set<String> = []
        return Array(preferences.filter { preference in
            let key: String
            switch preference {
            case let .app(id): key = "app:" + id.lowercased()
            case let .group(name): key = "group:" + name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            }
            return keys.insert(key).inserted
        }.prefix(SavedLayoutValidator.maximumPreferences))
    }

    static func updating(_ original: SavedLayoutDocument, from captured: SavedLayoutDocument) throws -> SavedLayoutDocument {
        let old = panes(original), new = panes(captured)
        let matches = try nearestOldPanes(old: old, new: new)
        var result = captured
        result.name = original.name
        result.keepForNewWindows = original.keepForNewWindows
        result.extraWindows = captured.mode == .bento ? original.extraWindows : .float
        result.slots = []; result.groups = []; result.windows = []; result.floats = []
        var replacements: [String: SavedLayoutNode] = [:]
        var used: Set<String> = []
        for pane in new {
            let previous = matches[pane.id].flatMap { id in old.first { $0.id == id } }
            let source = previous?.slots ?? pane.slots
            var slots: [SavedLayoutSlot] = []
            for var slot in source {
                if used.contains(slot.id) { slot.id = "slot-" + UUID().uuidString.lowercased() }
                used.insert(slot.id); slots.append(slot)
            }
            // Adaptive has one slot per pane. Preserve the lists in order without
            // inventing floating windows when Update changes from Tabbed.
            if result.mode == .bento, slots.count > 1 {
                var first = slots[0]
                first.prefer = Self.combinedPreferences(slots.flatMap(\.prefer))
                slots = [first]
            }
            result.slots += slots
            if pane.id.hasPrefix("rectangle-") {
                for slot in slots {
                    let rect = SavedLayoutRectangle(slot: slot.id, rect: pane.rect)
                    if captured.windows.contains(where: { "rectangle-" + $0.slot == pane.id }) { result.windows.append(rect) }
                    else { result.floats.append(rect) }
                }
            } else if result.mode == .tabbed, !slots.isEmpty {
                let id = "group-" + pane.id
                let selected = previous?.selected.flatMap { selected in slots.first { $0.id == selected }?.id } ?? slots.first?.id
                result.groups.append(.init(id: id, slots: slots.map(\.id), selected: selected))
                replacements[pane.id] = .group(id)
            } else { replacements[pane.id] = slots.first.map { .slot($0.id) } ?? .empty }
        }
        for pane in SavedLayoutCanvasGeometry.panes(captured) {
            if let root = result.layout, let replacement = replacements["pane-" + pane.id] {
                result.layout = SavedLayoutCanvasGeometry.replacing(root, at: pane.path, with: replacement)
            }
        }
        try SavedLayoutValidator.requireValid(result)
        return result
    }
}

/// The optional export-only `appGroups` array sits beside the format version 2 layout fields.
/// Library bytes always pass through the strict layout encoder, without this field.
struct SavedLayoutTransfer {
    var document: SavedLayoutDocument
    var appGroups: [AppGroup]

    /// Mirrors Core's line-comment scanner because that helper is internal. Bound the
    /// envelope before Foundation parses it; the strict validators check both payloads.
    private static func removingLineComments(_ data: Data) throws -> Data {
        var bytes = Array(data)
        var inString = false, escaped = false, comment = false
        var depth = 0, index = 0
        while index < bytes.count {
            let byte = bytes[index]
            guard byte != 0 else { throw SavedLayoutFileError(message: "Use UTF-8 JSON without null bytes.") }
            if comment {
                if byte == 10 || byte == 13 { comment = false } else { bytes[index] = 32 }
            } else if inString {
                if escaped { escaped = false }
                else if byte == 92 { escaped = true }
                else if byte == 34 { inString = false }
            } else if byte == 47, index + 1 < bytes.count, bytes[index + 1] == 47 {
                bytes[index] = 32; bytes[index + 1] = 32; comment = true; index += 1
            } else if byte == 34 { inString = true }
            else if byte == 91 || byte == 123 {
                depth += 1
                guard depth <= 128 else { throw SavedLayoutFileError(message: "Reduce the JSON nesting depth.") }
            } else if byte == 93 || byte == 125 { depth -= 1 }
            index += 1
        }
        return Data(bytes)
    }

    static func decode(_ bytes: Data) throws -> Self {
        guard bytes.count <= SavedLayoutValidator.maximumBytes else {
            throw SavedLayoutFileError(message: "Keep exported layouts within 1 MiB.")
        }
        let json = try Self.removingLineComments(bytes)
        guard var object = try JSONSerialization.jsonObject(with: json) as? [String: Any] else {
            throw SavedLayoutFileError(message: "Use a Saved Layout JSON object.")
        }
        let embedded = object.removeValue(forKey: "appGroups")
        let layoutBytes = embedded == nil ? bytes : try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let document = try SavedLayoutValidator.decode(layoutBytes)
        let groups: [AppGroup]
        if let embedded {
            let data = try JSONSerialization.data(withJSONObject: ["version": 1, "groups": embedded])
            groups = try AppGroupsDocument.decode(data).groups
        } else { groups = [] }
        return .init(document: document, appGroups: groups)
    }

    static func usedGroups(in document: SavedLayoutDocument, from groups: AppGroupsDocument) -> [AppGroup] {
        let names = document.slots.flatMap(\.prefer).compactMap { preference -> String? in
            if case let .group(name) = preference { return name }; return nil
        }
        return groups.groups.filter { group in names.contains { sameGroupName($0, group.name) } }
    }

    static func encode(_ document: SavedLayoutDocument, groups: AppGroupsDocument) throws -> Data {
        let bytes = try SavedLayoutValidator.encode(document)
        let used = usedGroups(in: document, from: groups)
        guard !used.isEmpty else { return bytes }
        _ = try AppGroupsDocument(groups: used).encode()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let memberObject = String(decoding: try encoder.encode(["appGroups": used]), as: UTF8.self)
        let member = memberObject.dropFirst(2).dropLast(2)
        // Keep the layout encoder's numbers, whitespace and unescaped slashes verbatim.
        let layout = String(decoding: bytes, as: UTF8.self).dropLast().trimmingCharacters(in: .whitespacesAndNewlines)
        let result = Data((layout + ",\n" + member + "\n}").utf8)
        guard result.count <= SavedLayoutValidator.maximumBytes else { throw SavedLayoutFileError(message: "Keep exported layouts within 1 MiB.") }
        return result
    }
}

func sameGroupName(_ a: String, _ b: String) -> Bool {
    a.compare(b, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
}

enum SavedLayoutGroupImportChoice: Hashable { case add, existing(String) }

struct SavedLayoutImport: Identifiable {
    let id = UUID()
    let source: URL
    let transfer: SavedLayoutTransfer
    let missing: [String]
    var choices: [String: SavedLayoutGroupImportChoice]

    init(source: URL, transfer: SavedLayoutTransfer, groups: AppGroupsDocument) {
        self.source = source; self.transfer = transfer
        var names: [String] = []
        for preference in transfer.document.slots.flatMap(\.prefer) {
            if case let .group(name) = preference,
               !groups.groups.contains(where: { sameGroupName($0.name, name) }),
               !names.contains(where: { sameGroupName($0, name) }) { names.append(name) }
        }
        missing = names
        choices = Dictionary(uniqueKeysWithValues: names.map { ($0, .add) })
    }

    func resolved(using groups: AppGroupsDocument) throws -> (SavedLayoutDocument, AppGroupsDocument) {
        var document = transfer.document, updatedGroups = groups
        for name in missing {
            switch choices[name] ?? .add {
            case .add:
                guard !updatedGroups.groups.contains(where: { sameGroupName($0.name, name) }) else { continue }
                guard let group = transfer.appGroups.first(where: { sameGroupName($0.name, name) }) else {
                    throw SavedLayoutFileError(message: "\(name) has no group copy in this file. Choose an existing group.")
                }
                updatedGroups.groups.append(group)
            case let .existing(target):
                guard let group = groups.groups.first(where: { sameGroupName($0.name, target) }) else {
                    throw SavedLayoutFileError(message: "The chosen group no longer exists. Choose another group.")
                }
                for index in document.slots.indices {
                    document.slots[index].prefer = document.slots[index].prefer.map {
                        if case let .group(old) = $0, sameGroupName(old, name) { return .group(group.name) }; return $0
                    }
                    // Mapping two names to one group must not make an invalid duplicate preference.
                    document.slots[index].prefer = SavedLayoutUpdateMapping.combinedPreferences(document.slots[index].prefer)
                }
            }
        }
        _ = try SavedLayoutValidator.encode(document)
        _ = try updatedGroups.encode()
        return (document, updatedGroups)
    }
}

@MainActor struct SavedLayoutFileOpener {
    var edit: (URL) -> Void = { PlainTextFileEditor().edit($0) }
    var reveal: (URL) -> Void = { NSWorkspace.shared.activateFileViewerSelecting([$0]) }
}

/// JSON files use the user's text editor rather than their JSON file association.
@MainActor struct PlainTextFileEditor {
    var preferredApplication: () -> URL? = { NSWorkspace.shared.urlForApplication(toOpen: .plainText) }
    var fallbackApplication: () -> URL? = { NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.TextEdit") }
    var open: (URL, URL) -> Void = { file, application in
        NSWorkspace.shared.open([file], withApplicationAt: application, configuration: NSWorkspace.OpenConfiguration())
    }
    func edit(_ file: URL) {
        guard let application = preferredApplication() ?? fallbackApplication() else { return }
        open(file, application)
    }
}
