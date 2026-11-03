// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 LMC-Karma

import Foundation

/// One item of a pane's ordered app preferences: a single app or an App Group.
/// Encoded as `{"app": "<bundle ID>"}` or `{"group": "<group name>"}`.
public enum AppPreference: Codable, Hashable, Sendable {
    case app(String)
    case group(String)

    private enum CodingKeys: String, CodingKey { case app, group }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch (c.contains(.app), c.contains(.group)) {
        case (true, false): self = .app(try c.decode(String.self, forKey: .app))
        case (false, true): self = .group(try c.decode(String.self, forKey: .group))
        default:
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                debugDescription: "Choose exactly one of app or group for this preference."))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .app(bundleID): try c.encode(bundleID, forKey: .app)
        case let .group(name): try c.encode(name, forKey: .group)
        }
    }
}
