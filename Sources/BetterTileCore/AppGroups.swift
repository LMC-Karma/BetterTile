// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 LMC-Karma

import Foundation

/// An app whose bundle ID takes precedence; the App layer resolves name-only entries.
public struct AppGroupEntry: Codable, Hashable, Sendable {
    public var name: String?
    public var bundleID: String?
    public init(from decoder: any Decoder) throws {
        try rejectUnknownKeys(decoder, allowed: ["name", "bundleID"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        bundleID = try c.decodeIfPresent(String.self, forKey: .bundleID)
    }
    private enum CodingKeys: String, CodingKey { case name, bundleID }
    public init(name: String? = nil, bundleID: String? = nil) {
        self.name = name; self.bundleID = bundleID
    }
}

/// A flat list of apps in preference order.
public struct AppGroup: Codable, Hashable, Sendable {
    public var name: String
    public var apps: [AppGroupEntry]
    public init(from decoder: any Decoder) throws {
        try rejectUnknownKeys(decoder, allowed: ["name", "apps"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        apps = try c.decode([AppGroupEntry].self, forKey: .apps)
    }
    private enum CodingKeys: String, CodingKey { case name, apps }
    public init(name: String, apps: [AppGroupEntry]) { self.name = name; self.apps = apps }
}

public struct AppPreferenceExpansion: Equatable, Sendable {
    public var bundleIDs: [String]
    public var unknownGroups: [String]
    public var unresolvedEntries: [String]
    public init(bundleIDs: [String], unknownGroups: [String], unresolvedEntries: [String]) {
        self.bundleIDs = bundleIDs; self.unknownGroups = unknownGroups; self.unresolvedEntries = unresolvedEntries
    }
}

public struct AppGroupsDocument: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public static let fileHeader = """
    // BetterTile App Groups
    //
    // Each group is a named list of apps, in order of preference.
    // Layouts can prefer a group ("Browser") instead of one app.
    // When two apps of a group are open, the one listed first wins the pane.
    //
    // "name" is enough: BetterTile finds the installed app and adds its
    // "bundleID" the next time Settings saves this file.
    // "bundleID" alone also works. If both are present, bundleID wins.
    //
    // Edit here or in Settings → Saved Layouts → App Groups, then choose Reload.
    // BetterTile rewrites this header and removes other comments when it saves.

    """
    public var version: Int
    public var groups: [AppGroup]
    public init(version: Int = currentVersion, groups: [AppGroup] = []) {
        self.version = version; self.groups = groups
    }

    public init(from decoder: any Decoder) throws {
        try rejectUnknownKeys(decoder, allowed: ["version", "groups"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        groups = try c.decode([AppGroup].self, forKey: .groups)
    }
    private enum CodingKeys: String, CodingKey { case version, groups }

    public static func decode(_ data: Data) throws -> AppGroupsDocument {
        guard data.count <= SavedLayoutValidator.maximumBytes else {
            throw savedLayoutError("$", "Keep App Groups files within 1 MiB (1,048,576 bytes).")
        }
        do {
            struct Header: Decodable { var version: Int }
            let decoder = JSONDecoder()
            let data = try SavedLayoutValidator.removingLineComments(data)
            let version = try decoder.decode(Header.self, from: data).version
            guard version == currentVersion else {
                throw savedLayoutError("$.version", "This file uses version \(version). Only version 1 is supported.")
            }
            let document = try decoder.decode(Self.self, from: data)
            try document.requireValid()
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
                path = context.codingPath; message = "This is not valid App Groups JSON. Check commas, quotes, and brackets."
            @unknown default:
                path = []; message = "This App Groups file could not be decoded."
            }
            throw savedLayoutError(jsonPath(path), message)
        }
    }

    public func encode() throws -> Data {
        try requireValid()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return Data(Self.fileHeader.utf8) + (try encoder.encode(self))
    }

    private func requireValid() throws {
        let issues = validate()
        if !issues.isEmpty { throw SavedLayoutValidationError(issues: issues) }
    }

    public func validate() -> [SavedLayoutIssue] {
        var issues: [SavedLayoutIssue] = []
        if version != Self.currentVersion {
            issues.append(.init(path: "$.version", message: "This file uses version \(version). Only version 1 is supported."))
        }
        for (index, group) in groups.enumerated() {
            let path = "$.groups[\(index)]"
            if group.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                issues.append(.init(path: "\(path).name", message: "Give this group a name."))
            }
            if groups[..<index].contains(where: { sameName($0.name, group.name) }) {
                issues.append(.init(path: "\(path).name", message: "Group names must be unique."))
            }
            for (entryIndex, entry) in group.apps.enumerated() {
                let entryPath = "\(path).apps[\(entryIndex)]"
                let hasName = entry.name.map { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? false
                if !hasName && entry.bundleID == nil {
                    issues.append(.init(path: entryPath, message: "Give this app a name or bundle ID."))
                }
                if let id = entry.bundleID {
                    let parts = id.split(separator: ".", omittingEmptySubsequences: false)
                    if parts.count < 2 || parts.contains(where: { $0.isEmpty }) ||
                        !id.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || $0 == "." || $0 == "-" }) {
                        issues.append(.init(path: "\(entryPath).bundleID", message: "Use an app bundle ID such as com.apple.Safari."))
                    }
                }
                if group.apps[..<entryIndex].contains(where: { previous in
                    if let id = entry.bundleID { return previous.bundleID.map { sameBundleID($0, id) } ?? false }
                    guard let name = entry.name, previous.bundleID == nil, let previousName = previous.name else { return false }
                    return sameName(name, previousName)
                }) {
                    issues.append(.init(path: entryPath, message: "Apps in a group must be unique."))
                }
            }
        }
        return issues
    }

    /// Expands preferences in order; the first bundle ID wins and unresolved entries are reported.
    public func expand(_ preferences: [AppPreference], resolvedBundleIDs: [AppGroupEntry: String] = [:]) -> AppPreferenceExpansion {
        var result = AppPreferenceExpansion(bundleIDs: [], unknownGroups: [], unresolvedEntries: [])
        func add(_ id: String) {
            if !result.bundleIDs.contains(where: { sameBundleID($0, id) }) { result.bundleIDs.append(id) }
        }
        for preference in preferences {
            switch preference {
            case let .app(id): add(id)
            case let .group(name):
                guard let group = groups.first(where: { sameName($0.name, name) }) else {
                    result.unknownGroups.append(name); continue
                }
                for entry in group.apps {
                    if let id = entry.bundleID ?? resolvedBundleIDs[entry] { add(id) }
                    else { result.unresolvedEntries.append(entry.name ?? "") }
                }
            }
        }
        return result
    }

    public func renamingGroup(_ old: String, to new: String) throws -> AppGroupsDocument {
        guard let index = groups.firstIndex(where: { sameName($0.name, old) }) else {
            throw savedLayoutError("$.groups", "The group \(old) was not found.")
        }
        var copy = self
        copy.groups[index].name = new
        try copy.requireValid()
        return copy
    }
}

private func sameName(_ lhs: String, _ rhs: String) -> Bool {
    lhs.compare(rhs, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
}

private func sameBundleID(_ lhs: String, _ rhs: String) -> Bool {
    lhs.compare(rhs, options: [.caseInsensitive]) == .orderedSame
}

private struct AnyAppGroupsKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

private func jsonPath(_ keys: [any CodingKey]) -> String {
    keys.reduce("$") { result, key in
        result + (key.intValue.map { "[\($0)]" } ?? ".\(key.stringValue)")
    }
}

private func rejectUnknownKeys(_ decoder: any Decoder, allowed: Set<String>) throws {
    let container = try decoder.container(keyedBy: AnyAppGroupsKey.self)
    if let key = container.allKeys.sorted(by: { $0.stringValue < $1.stringValue }).first(where: { !allowed.contains($0.stringValue) }) {
        throw savedLayoutError(jsonPath(decoder.codingPath + [key]), "Unknown field \"\(key.stringValue)\".")
    }
}
