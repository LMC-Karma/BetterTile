// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 LMC-Karma

import BetterTileCore
import Foundation

enum AppGroupResolution: Equatable {
    case resolved(String)
    case ambiguous([ApplicationChoice])
    case notInstalled
}

struct AppGroupResolver {
    let applications: [ApplicationChoice]

    func resolve(_ entry: AppGroupEntry) -> AppGroupResolution {
        if let id = entry.bundleID {
            return applications.contains { $0.bundleIdentifier.caseInsensitiveCompare(id) == .orderedSame }
                ? .resolved(id) : .notInstalled
        }
        guard let name = entry.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return .notInstalled }
        let exact = applications.filter { $0.name.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
        if exact.count == 1 { return .resolved(exact[0].bundleIdentifier) }
        if exact.count > 1 { return .ambiguous(exact) }
        let matches = applications.filter { $0.name.localizedStandardContains(name) }
        if matches.count == 1 { return .resolved(matches[0].bundleIdentifier) }
        if let app = applications.first(where: { $0.bundleIdentifier.caseInsensitiveCompare(name) == .orderedSame }) {
            return .resolved(app.bundleIdentifier)
        }
        return matches.isEmpty ? .notInstalled : .ambiguous(matches)
    }

    func resolvedBundleIDs(in document: AppGroupsDocument) -> [AppGroupEntry: String] {
        var result: [AppGroupEntry: String] = [:]
        for entry in document.groups.flatMap(\.apps) {
            if case let .resolved(id) = resolve(entry) { result[entry] = id }
        }
        return result
    }
}
