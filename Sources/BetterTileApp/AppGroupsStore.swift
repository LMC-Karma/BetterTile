// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 LMC-Karma

import AppKit
import BetterTileCore
import Foundation

protocol AppGroupsPreferences {
    func strings(forKey key: String) -> [String]?
    func setStrings(_ value: [String], forKey key: String)
}

extension UserDefaults: AppGroupsPreferences {
    func strings(forKey key: String) -> [String]? { stringArray(forKey: key) }
    func setStrings(_ value: [String], forKey key: String) { set(value, forKey: key) }
}

final class InMemoryAppGroupsPreferences: AppGroupsPreferences {
    private var values: [String: [String]] = [:]
    func strings(forKey key: String) -> [String]? { values[key] }
    func setStrings(_ value: [String], forKey key: String) { values[key] = value }
}

@MainActor
final class AppGroupsStore {
    let directory: URL
    let layouts: SavedLayoutFiles
    private let catalog: () async -> [ApplicationChoice]
    private let defaultBrowserURL: () -> URL?
    private var baseline: Data?
    private(set) var canSave = false
    var beforeLayoutWrite: ((URL) -> Void)?
    private(set) var document = AppGroupsDocument()
    private(set) var error: (any Error)?
    private(set) var resolutions: [AppGroupEntry: AppGroupResolution] = [:]
    private(set) var resolvedBundleIDs: [AppGroupEntry: String] = [:]
    private(set) var applications: [ApplicationChoice] = []
    private(set) var suggestedNames: Set<String> = []
    private let preferences: any AppGroupsPreferences
    private let suggestionsKey: String
    var fileURL: URL { directory.appendingPathComponent("App Groups.json") }
    var fileExists: Bool { FileManager.default.fileExists(atPath: fileURL.path) }

    static var standard: AppGroupsStore {
        let layouts = SavedLayoutFiles.standard
        return AppGroupsStore(directory: layouts.directory.deletingLastPathComponent())
    }

    init(directory: URL, catalog: (@MainActor () async -> [ApplicationChoice])? = nil, preferences: (any AppGroupsPreferences)? = nil, defaultBrowserURL: @escaping @MainActor () -> URL? = {
        let url = URL(string: "https://example.com")!
        return NSWorkspace.shared.urlForApplication(toOpen: url)
    }) {
        self.directory = directory.resolvingSymlinksInPath()
        self.preferences = preferences ?? (catalog == nil ? UserDefaults.standard : InMemoryAppGroupsPreferences())
        suggestionsKey = "AppGroups.suggestions." + directory.resolvingSymlinksInPath().path
        layouts = SavedLayoutFiles(directory: directory.appendingPathComponent("Saved Layouts"))
        self.catalog = catalog ?? { await InstalledApplicationCatalog.shared.applications() }
        self.defaultBrowserURL = defaultBrowserURL
    }

    func load() async {
        applications = await catalog()
        do {
            let bytes = try readIfPresent()
            if let bytes, bytes.contains(0) {
                throw SavedLayoutValidationError(issues: [.init(path: "$", message: "Use a UTF-8 App Groups file without null bytes.")])
            }
            let loaded = try bytes.map { try AppGroupsDocument.decode($0) } ?? starterGroups()
            document = loaded
            if bytes == nil {
                let dismissed = Set(preferences.strings(forKey: suggestionsKey + ".removed") ?? [])
                document.groups.removeAll { dismissed.contains($0.name) }
                suggestedNames = Set(document.groups.map(\.name))
            } else { suggestedNames = [] }
            baseline = bytes
            canSave = true
            error = nil
            refreshResolution()
        } catch {
            canSave = false
            self.error = error
        }
    }

    func reload() async { await load() }

    func hasExternalChange() throws -> Bool { try readIfPresent() != baseline }

    func save(_ newDocument: AppGroupsDocument) throws {
        guard canSave else { throw SavedLayoutFileError(message: "Reload a valid App Groups file before saving. Nothing was overwritten.") }
        var copy = newDocument
        let resolver = AppGroupResolver(applications: applications)
        for groupIndex in copy.groups.indices {
            for entryIndex in copy.groups[groupIndex].apps.indices {
                let entry = copy.groups[groupIndex].apps[entryIndex]
                if entry.bundleID == nil, case let .resolved(id) = resolver.resolve(entry) {
                    copy.groups[groupIndex].apps[entryIndex].bundleID = id
                }
            }
        }
        let data = try copy.encode()
        guard data.count <= SavedLayoutValidator.maximumBytes else {
            throw SavedLayoutFileError(message: "App Groups exceeds 1 MiB. Reduce the file size. Nothing was overwritten.")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var coordinationError: NSError?
        var operationError: (any Error)?
        NSFileCoordinator().coordinate(writingItemAt: fileURL, options: .forReplacing, error: &coordinationError) { url in
            do {
                guard try readIfPresent(at: url) == baseline else {
                    throw SavedLayoutFileError(message: "This file changed outside BetterTile. Reload to inspect it. Nothing was overwritten.")
                }
                try data.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
            } catch { operationError = error }
        }
        if let operationError { throw operationError }
        if let coordinationError { throw coordinationError }
        document = copy
        baseline = data
        error = nil
        suggestedNames = []
        refreshResolution()
    }

    func saveResolvedApps() throws { try save(document) }

    func keepSuggestion(_ name: String) throws {
        try save(document)
    }

    func removeSuggestion(_ name: String) throws {
        var copy = document
        copy.groups.removeAll { $0.name == name }
        try save(copy)
        var removed = Set(preferences.strings(forKey: suggestionsKey + ".removed") ?? [])
        removed.insert(name)
        preferences.setStrings(Array(removed).sorted(), forKey: suggestionsKey + ".removed")
    }

    struct RenameFailure {
        let url: URL
        let reason: String
        var layoutName: String = "Unreadable layout"
    }

    /// Saves the group first. An unwritten layout will show an unknown group.
    func renameGroup(_ old: String, to new: String) throws -> [RenameFailure] {
        guard canSave else { throw SavedLayoutFileError(message: "Reload a valid App Groups file before saving. Nothing was overwritten.") }
        let renamed = try document.renamingGroup(old, to: new)
        var changes: [(URL, Data, Data)] = []
        var failures: [RenameFailure] = []
        for url in try layouts.entries() {
            let expected: Data
            do { expected = try layouts.read(url) }
            catch {
                failures.append(.init(url: url, reason: "This layout could not be read, so its group references were not checked: \(error.localizedDescription)"))
                continue
            }
            guard var layout = try? SavedLayoutValidator.decode(expected) else {
                if String(decoding: expected, as: UTF8.self).range(of: old, options: [.caseInsensitive, .diacriticInsensitive]) != nil {
                    let name = (try? JSONSerialization.jsonObject(with: expected) as? [String: Any])?["name"] as? String ?? "Invalid layout"
                    failures.append(.init(url: url, reason: "This invalid layout may reference the group; it was not checked or changed.", layoutName: name))
                }
                continue
            }
            var changed = false
            for index in layout.slots.indices {
                layout.slots[index].prefer = layout.slots[index].prefer.map { preference in
                    if case let .group(name) = preference,
                       name.compare(old, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame {
                        changed = true; return .group(new)
                    }
                    return preference
                }
            }
            if changed {
                do { changes.append((url, expected, try SavedLayoutValidator.encode(layout))) }
                catch { failures.append(.init(url: url, reason: error.localizedDescription, layoutName: layout.name)) }
            }
        }
        try save(renamed)
        for (url, expected, data) in changes {
            do { beforeLayoutWrite?(url); try layouts.save(data, to: url, expected: expected) }
            catch {
                let name = (try? SavedLayoutValidator.decode(expected).name) ?? "Unreadable layout"
                failures.append(.init(url: url, reason: error.localizedDescription, layoutName: name))
            }
        }
        return failures
    }

    private func readIfPresent(at url: URL? = nil) throws -> Data? {
        let url = url ?? fileURL
        do {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw SavedLayoutFileError(message: "Choose a regular App Groups file, not a folder or symbolic link. The source was kept.")
            }
            guard (values.fileSize ?? 0) <= SavedLayoutValidator.maximumBytes else {
                throw SavedLayoutFileError(message: "The App Groups file exceeds 1 MiB. Reduce the file size and reload. The source was kept.")
            }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let bytes = try handle.read(upToCount: SavedLayoutValidator.maximumBytes + 1) ?? Data()
            guard bytes.count <= SavedLayoutValidator.maximumBytes else {
                throw SavedLayoutFileError(message: "The App Groups file exceeds 1 MiB. Reduce the file size and reload. The source was kept.")
            }
            return bytes
        }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
        catch let error as POSIXError where error.code == .ENOENT { return nil }
    }

    private func refreshResolution() {
        let resolver = AppGroupResolver(applications: applications)
        resolutions = [:]
        for entry in document.groups.flatMap(\.apps) { resolutions[entry] = resolver.resolve(entry) }
        resolvedBundleIDs = resolver.resolvedBundleIDs(in: document)
    }

    private func starterGroups() -> AppGroupsDocument {
        let defaultID = defaultBrowserURL().flatMap { Bundle(url: $0)?.bundleIdentifier }
        var browsers = Self.browserIDs.compactMap { id in applications.first { $0.bundleIdentifier.caseInsensitiveCompare(id) == .orderedSame } }
        if let index = browsers.firstIndex(where: { $0.bundleIdentifier.caseInsensitiveCompare(defaultID ?? "") == .orderedSame }) {
            browsers.insert(browsers.remove(at: index), at: 0)
        }
        let coding = Self.codingIDs.compactMap { id in applications.first { $0.bundleIdentifier.caseInsensitiveCompare(id) == .orderedSame } }
        func group(_ name: String, _ apps: [ApplicationChoice]) -> AppGroup? {
            guard !apps.isEmpty else { return nil }
            return AppGroup(name: name, apps: apps.map { AppGroupEntry(name: $0.name, bundleID: $0.bundleIdentifier) })
        }
        return AppGroupsDocument(groups: [group("Browser", browsers), group("Coding", coding)].compactMap { $0 })
    }

    // Popular Mac browsers, October 2026; users edit the suggestion.
    private static let browserIDs = ["com.apple.Safari", "com.google.Chrome", "com.microsoft.edgemac", "org.mozilla.firefox", "com.brave.Browser", "company.thebrowser.Browser", "company.thebrowser.dia", "ai.perplexity.comet", "app.zen-browser.zen", "com.operasoftware.Opera", "com.vivaldi.Vivaldi", "com.kagi.kagimacOS", "com.duckduckgo.macos.browser", "com.operasoftware.OperaGX", "org.chromium.Chromium"]

    // Common coding apps, in the suggested preference order.
    private static let codingIDs = ["com.apple.dt.Xcode", "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "dev.zed.Zed", "com.panic.Nova", "com.barebones.bbedit", "com.sublimetext.4"]
}
