// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 LMC-Karma

import Foundation

/// What BetterTile remembers about one display. `name` and `frame` are for the picture in Settings only.
/// Resolution, scale, and arrangement are not identity, so a resolution change keeps the display identity.
public struct DisplayFingerprint: Hashable, Sendable {
    public var uuid: String
    public var vendor: UInt32
    public var model: UInt32
    /// Zero when the display reports no serial number.
    public var serial: UInt32
    public var builtIn: Bool
    public var name: String
    /// Top-left logical points in the global display space.
    public var frame: BTRect

    public init(uuid: String, vendor: UInt32, model: UInt32, serial: UInt32, builtIn: Bool, name: String, frame: BTRect) {
        self.uuid = uuid
        self.vendor = vendor
        self.model = model
        self.serial = serial
        self.builtIn = builtIn
        self.name = name
        self.frame = frame
    }

    var hasSerial: Bool { serial != 0 }
}

extension DisplayFingerprint: Codable {
    private enum CodingKeys: String, CodingKey { case uuid, vendor, model, serial, builtIn, name, frame }
    private struct Frame: Codable { var x, y, width, height: Double }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let frame = try values.decode(Frame.self, forKey: .frame)
        self.init(uuid: try values.decode(String.self, forKey: .uuid),
                  vendor: try values.decode(UInt32.self, forKey: .vendor),
                  model: try values.decode(UInt32.self, forKey: .model),
                  serial: try values.decode(UInt32.self, forKey: .serial),
                  builtIn: try values.decode(Bool.self, forKey: .builtIn),
                  name: try values.decode(String.self, forKey: .name),
                  frame: BTRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height))
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(uuid, forKey: .uuid)
        try values.encode(vendor, forKey: .vendor)
        try values.encode(model, forKey: .model)
        try values.encode(serial, forKey: .serial)
        try values.encode(builtIn, forKey: .builtIn)
        try values.encode(name, forKey: .name)
        try values.encode(Frame(x: frame.origin.x, y: frame.origin.y, width: frame.size.width, height: frame.size.height), forKey: .frame)
    }
}

public enum DisplaySetMatchKind: Sendable { case exact, uncertain, none }

/// How a live display set compares with a stored one. `pairs` maps a stored index to its live index.
public struct DisplaySetMatch: Equatable, Sendable {
    public var kind: DisplaySetMatchKind
    public var pairs: [Int: Int]

    public static let none = DisplaySetMatch(kind: .none, pairs: [:])
}

/// Exact matching only. Both sets must hold the same number of displays, and each stored display
/// needs its own live display. A missing or extra display gives no match.
public enum DisplaySetMatcher {
    /// - A display matches by UUID, or by vendor, model, and a nonzero serial.
    /// - Displays that report no serial, or share one serial (and share a model), are told apart by left-to-right position.
    ///   That is a guess, so the result is `.uncertain`.
    public static func match(stored: [DisplayFingerprint], live: [DisplayFingerprint]) -> DisplaySetMatch {
        guard !stored.isEmpty, stored.count == live.count else { return .none }
        var pairs: [Int: Int] = [:]
        var freeLive = Set(live.indices)

        func pair(_ qualifies: (DisplayFingerprint, DisplayFingerprint) -> Bool) {
            for index in stored.indices where pairs[index] == nil {
                if let match = freeLive.sorted().first(where: { qualifies(stored[index], live[$0]) }) {
                    pairs[index] = match
                    freeLive.remove(match)
                }
            }
        }
        pair { $0.uuid.caseInsensitiveCompare($1.uuid) == .orderedSame }
        // A serial identifies a display only when no other display in either set shares it. Some models
        // report one fixed serial (such as 0x01010101); two of them are told apart by position below.
        func key(_ display: DisplayFingerprint) -> [UInt32] { [display.vendor, display.model, display.serial] }
        func unique(_ display: DisplayFingerprint, in set: [DisplayFingerprint]) -> Bool {
            set.filter { key($0) == key(display) }.count == 1
        }
        pair { $0.hasSerial && key($0) == key($1) && unique($0, in: stored) && unique($1, in: live) }
        if pairs.count == stored.count { return .init(kind: .exact, pairs: pairs) }

        func leftToRight(_ indices: [Int], in set: [DisplayFingerprint]) -> [Int] {
            indices.sorted {
                let (a, b) = (set[$0], set[$1])
                if a.frame.origin.x != b.frame.origin.x { return a.frame.origin.x < b.frame.origin.x }
                if a.frame.origin.y != b.frame.origin.y { return a.frame.origin.y < b.frame.origin.y }
                return $0 < $1
            }
        }
        let storedLeft = leftToRight(stored.indices.filter { pairs[$0] == nil }, in: stored)
        let liveLeft = leftToRight(freeLive.sorted(), in: live)
        for (s, l) in zip(storedLeft, liveLeft) {
            let (old, new) = (stored[s], live[l])
            guard old.vendor == new.vendor, old.model == new.model, old.serial == new.serial else { return .none }
            pairs[s] = l
        }
        return .init(kind: .uncertain, pairs: pairs)
    }
}
