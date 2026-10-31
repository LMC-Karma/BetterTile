// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 LMC-Karma

import Foundation

/// Any JSON value. It keeps the keys of `Display Triggers.json` that this version does not know.
public enum DisplayTriggerJSON: Codable, Equatable, Sendable {
    case null, bool(Bool), int(Int), double(Double), string(String)
    case array([DisplayTriggerJSON]), object([String: DisplayTriggerJSON])

    public init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let bool = try? value.decode(Bool.self) { self = .bool(bool) }
        else if let int = try? value.decode(Int.self) { self = .int(int) }
        else if let double = try? value.decode(Double.self) { self = .double(double) }
        else if let string = try? value.decode(String.self) { self = .string(string) }
        else if let array = try? value.decode([DisplayTriggerJSON].self) { self = .array(array) }
        else { self = .object(try value.decode([String: DisplayTriggerJSON].self)) }
    }

    public func encode(to encoder: any Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .null: try value.encodeNil()
        case let .bool(bool): try value.encode(bool)
        case let .int(int): try value.encode(int)
        case let .double(double): try value.encode(double)
        case let .string(string): try value.encode(string)
        case let .array(array): try value.encode(array)
        case let .object(object): try value.encode(object)
        }
    }
}

public struct DisplayTriggerError: Error, Equatable, Sendable, LocalizedError {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

private struct DynamicKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(_ string: String) { stringValue = string }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

/// Binds one Saved Layout file to one display in an exact display set. The layout file does not change.
public struct DisplayTrigger: Equatable, Sendable {
    public var layoutFile: String
    /// Off by default. Enables Automatic Apply when the exact display set connects.
    public var enabled: Bool
    public var alsoAfterWake: Bool
    public var displays: [DisplayFingerprint]
    /// Index into `displays` of the display that receives the layout.
    public var target: Int
    /// Keys this version does not know, kept so a newer file survives a save.
    public var unknownKeys: [String: DisplayTriggerJSON]

    public init(layoutFile: String, enabled: Bool = false, alsoAfterWake: Bool = false,
                displays: [DisplayFingerprint], target: Int, unknownKeys: [String: DisplayTriggerJSON] = [:]) {
        self.layoutFile = layoutFile
        self.enabled = enabled
        self.alsoAfterWake = alsoAfterWake
        self.displays = displays
        self.target = target
        self.unknownKeys = unknownKeys
    }

    public var targetDisplay: DisplayFingerprint { displays[target] }
    fileprivate static let known: Set<String> = ["layoutFile", "enabled", "alsoAfterWake", "displays", "target"]
}

/// The whole `Display Triggers.json` file. Version 1.
public struct DisplayTriggerDocument: Equatable, Sendable {
    public static let version = 1
    public static let maximumBytes = 256 * 1024
    public static let maximumTriggers = 256
    public static let maximumDisplays = 16

    public var triggers: [DisplayTrigger]
    public var unknownKeys: [String: DisplayTriggerJSON]

    public init(triggers: [DisplayTrigger] = [], unknownKeys: [String: DisplayTriggerJSON] = [:]) {
        self.triggers = triggers
        self.unknownKeys = unknownKeys
    }

    public func trigger(for layoutFile: String) -> DisplayTrigger? { triggers.first { $0.layoutFile == layoutFile } }

    /// One trigger for each layout file. A second `set` for the same file replaces the first.
    public mutating func set(_ trigger: DisplayTrigger) {
        if let index = triggers.firstIndex(where: { $0.layoutFile == trigger.layoutFile }) { triggers[index] = trigger }
        else { triggers.append(trigger) }
    }

    public mutating func remove(layoutFile: String) { triggers.removeAll { $0.layoutFile == layoutFile } }

    /// Another layout's trigger for the same display of an equal display set. At most one layout may own it.
    public func conflict(displays: [DisplayFingerprint], target: Int, excluding layoutFile: String) -> DisplayTrigger? {
        triggers.first { other in
            guard other.layoutFile != layoutFile else { return false }
            let match = DisplaySetMatcher.match(stored: other.displays, live: displays)
            return match.kind != .none && match.pairs[other.target] == target
        }
    }

    public static func isValidLayoutFile(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.count <= 255 && !name.hasPrefix(".") && name.lowercased().hasSuffix(".json")
            && !name.contains("/") && !name.contains(":") && !name.unicodeScalars.contains { $0.value < 32 }
    }

    public static func decode(_ data: Data) throws -> DisplayTriggerDocument {
        guard data.count <= maximumBytes else { throw DisplayTriggerError("Display Triggers.json is larger than 256 KiB.") }
        do { return try JSONDecoder().decode(Self.self, from: data) }
        catch let error as DisplayTriggerError { throw error }
        catch { throw DisplayTriggerError("Display Triggers.json is not valid: \(Self.describe(error))") }
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(self)
        guard data.count <= Self.maximumBytes else { throw DisplayTriggerError("Display Triggers.json would be larger than 256 KiB.") }
        return data
    }

    private static func describe(_ error: any Error) -> String {
        guard let error = error as? DecodingError else { return error.localizedDescription }
        switch error {
        case let .keyNotFound(key, _): return "the key “\(key.stringValue)” is missing."
        case let .typeMismatch(_, context), let .valueNotFound(_, context), let .dataCorrupted(context):
            let path = context.codingPath.map(\.stringValue).joined(separator: ".")
            return path.isEmpty ? "the file is not readable JSON." : "check “\(path)”."
        @unknown default: return "unreadable."
        }
    }
}

extension DisplayTrigger: Codable {
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: DynamicKey.self)
        let displays = try values.decode([DisplayFingerprint].self, forKey: .init("displays"))
        let target = try values.decode(Int.self, forKey: .init("target"))
        let file = try values.decode(String.self, forKey: .init("layoutFile"))
        guard DisplayTriggerDocument.isValidLayoutFile(file) else {
            throw DisplayTriggerError("A trigger names a layout file that is not a plain .json file name.")
        }
        guard (1...DisplayTriggerDocument.maximumDisplays).contains(displays.count), displays.indices.contains(target) else {
            throw DisplayTriggerError("The trigger for “\(file)” has no valid target display.")
        }
        for display in displays {
            guard !display.uuid.isEmpty, display.uuid.count <= 64, display.name.count <= 256,
                  [display.frame.origin.x, display.frame.origin.y, display.frame.size.width, display.frame.size.height].allSatisfy(\.isFinite)
            else { throw DisplayTriggerError("The trigger for “\(file)” has an invalid display.") }
        }
        var unknown: [String: DisplayTriggerJSON] = [:]
        for key in values.allKeys where !Self.known.contains(key.stringValue) {
            unknown[key.stringValue] = try values.decode(DisplayTriggerJSON.self, forKey: key)
        }
        self.init(layoutFile: file,
                  enabled: try values.decodeIfPresent(Bool.self, forKey: .init("enabled")) ?? false,
                  alsoAfterWake: try values.decodeIfPresent(Bool.self, forKey: .init("alsoAfterWake")) ?? false,
                  displays: displays, target: target, unknownKeys: unknown)
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: DynamicKey.self)
        for (key, value) in unknownKeys where !Self.known.contains(key) { try values.encode(value, forKey: .init(key)) }
        try values.encode(layoutFile, forKey: .init("layoutFile"))
        try values.encode(enabled, forKey: .init("enabled"))
        try values.encode(alsoAfterWake, forKey: .init("alsoAfterWake"))
        try values.encode(displays, forKey: .init("displays"))
        try values.encode(target, forKey: .init("target"))
    }
}

extension DisplayTriggerDocument: Codable {
    private static let known: Set<String> = ["version", "triggers"]

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: DynamicKey.self)
        let version = try values.decode(Int.self, forKey: .init("version"))
        guard version == Self.version else {
            throw DisplayTriggerError("Display Triggers.json is version \(version). This version of BetterTile reads version \(Self.version).")
        }
        let triggers = try values.decode([DisplayTrigger].self, forKey: .init("triggers"))
        guard triggers.count <= Self.maximumTriggers else { throw DisplayTriggerError("Display Triggers.json has too many triggers.") }
        guard Set(triggers.map(\.layoutFile)).count == triggers.count else {
            throw DisplayTriggerError("Display Triggers.json has two triggers for one layout file.")
        }
        var unknown: [String: DisplayTriggerJSON] = [:]
        for key in values.allKeys where !Self.known.contains(key.stringValue) {
            unknown[key.stringValue] = try values.decode(DisplayTriggerJSON.self, forKey: key)
        }
        self.init(triggers: triggers, unknownKeys: unknown)
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: DynamicKey.self)
        for (key, value) in unknownKeys where !Self.known.contains(key) { try values.encode(value, forKey: .init(key)) }
        try values.encode(Self.version, forKey: .init("version"))
        try values.encode(triggers, forKey: .init("triggers"))
    }
}
