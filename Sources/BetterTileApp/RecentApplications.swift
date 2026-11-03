// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 LMC-Karma

import Foundation

/// Remembers the bundle identifiers of the apps most recently chosen in an app picker.
/// Stored locally in UserDefaults; nothing else is recorded.
@MainActor final class RecentApplications {
    static let shared = RecentApplications()
    static let defaultsKey = "recentApplicationBundleIdentifiers"
    static let limit = 8

    private let defaults: UserDefaults
    private let key: String
    private let limit: Int

    init(defaults: UserDefaults = .standard, key: String = RecentApplications.defaultsKey, limit: Int = RecentApplications.limit) {
        self.defaults = defaults
        self.key = key
        self.limit = max(0, limit)
    }

    var bundleIdentifiers: [String] {
        sanitize(defaults.object(forKey: key) as? [String] ?? [])
    }

    func record(_ bundleIdentifier: String) {
        let identifier = bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !identifier.isEmpty, identifier.count <= 255 else { return }
        defaults.set(sanitize([identifier] + bundleIdentifiers), forKey: key)
    }

    func clear() {
        defaults.removeObject(forKey: key)
    }

    private func sanitize(_ identifiers: [String]) -> [String] {
        var seen: Set<String> = []
        return Array(identifiers.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter {
            !$0.isEmpty && $0.count <= 255 && seen.insert($0).inserted
        }.prefix(limit))
    }
}
