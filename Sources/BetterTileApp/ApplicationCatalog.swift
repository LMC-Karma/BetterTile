// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 LMC-Karma

import Foundation

struct ApplicationChoice: Hashable, Identifiable, Sendable {
    let bundleIdentifier: String
    let name: String
    let url: URL
    var id: String { bundleIdentifier }
}

/// Reads bundle metadata without launching applications or requesting access.
enum ApplicationCatalog {
    static var standardDirectories: [URL] {
        [URL(filePath: "/Applications"), URL(filePath: "/System/Applications"),
         FileManager.default.homeDirectoryForCurrentUser.appending(path: "Applications")]
    }

    static func application(at url: URL) -> ApplicationChoice? {
        guard url.pathExtension.lowercased() == "app",
              let bundle = Bundle(url: url),
              let metadata = bundle.infoDictionary,
              let identifier = metadata["CFBundleIdentifier"] as? String,
              !identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        guard let executable = bundle.executableURL?.resolvingSymlinksInPath(),
              (try? executable.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
              FileManager.default.isExecutableFile(atPath: executable.path) else { return nil }
        return ApplicationChoice(bundleIdentifier: identifier, name: displayName(for: url, metadata: metadata), url: url)
    }

    static func displayName(for url: URL, metadata: [String: Any]?) -> String {
        var name = FileManager.default.displayName(atPath: url.path)
        if name.lowercased().hasSuffix(".app") { name.removeLast(4) }
        if !name.isEmpty { return name }
        return (metadata?["CFBundleDisplayName"] as? String)
            ?? (metadata?["CFBundleName"] as? String)
            ?? url.deletingPathExtension().lastPathComponent
    }

    /// Only the installed scan uses these rules. Browse… and saved bundle IDs still accept
    /// agents and helpers, so anything left out here can still be chosen. The package type
    /// is not checked: macOS 26 ships Passwords as an `XPC!` bundle that opens windows.
    static func isListed(_ metadata: [String: Any]) -> Bool {
        if let identifier = metadata["CFBundleIdentifier"] as? String, alwaysListed.contains(identifier) { return true }
        return !isTrue(metadata["LSBackgroundOnly"]) && !isTrue(metadata["LSUIElement"])
    }

    /// Windowed apps that macOS marks as agents. On macOS 26 System Information sets
    /// `LSUIElement` but still opens a normal window.
    private static let alwaysListed: Set<String> = ["com.apple.SystemProfiler"]

    private static func isTrue(_ value: Any?) -> Bool {
        if let number = value as? NSNumber { return number.boolValue }
        guard let string = value as? String else { return false }
        return ["1", "yes", "true"].contains(string.lowercased())
    }

    /// Skips apps nested in another app or kept in a helper folder below the scan root.
    private static func isListed(_ url: URL, relativeTo directory: URL) -> Bool {
        let components = url.standardizedFileURL.deletingLastPathComponent().pathComponents
            .dropFirst(directory.standardizedFileURL.pathComponents.count)
        let helperFolders = ["contents", "library", "helpers", "frameworks", "plugins", "xpcservices", "loginitems"]
        return !components.contains {
            let component = $0.lowercased()
            return component.hasSuffix(".app") || helperFolders.contains(component)
        }
    }

    static func enumerate(directories: [URL]) -> [ApplicationChoice] {
        var applications: [ApplicationChoice] = []
        for directory in directories {
            guard let enumerator = FileManager.default.enumerator(
                at: directory, includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }
            for case let url as URL in enumerator where url.pathExtension.lowercased() == "app" {
                enumerator.skipDescendants()
                guard isListed(url, relativeTo: directory),
                      let metadata = Bundle(url: url)?.infoDictionary, isListed(metadata),
                      let application = application(at: url) else { continue }
                applications.append(application)
            }
        }
        var seen: Set<String> = []
        return applications.filter {
            !$0.bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && seen.insert($0.bundleIdentifier).inserted
        }.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.bundleIdentifier < $1.bundleIdentifier : order == .orderedAscending
        }
    }
}

/// Shares one off-main-thread scan between picker openings. A later opening
/// refreshes the cache after five minutes, so installs do not require a relaunch.
actor InstalledApplicationCatalog {
    static let shared = InstalledApplicationCatalog()
    private let now: @Sendable () -> Date
    private let load: @Sendable () async -> [ApplicationChoice]
    private var scan: Task<[ApplicationChoice], Never>?
    private var cached: [ApplicationChoice]?
    private var scannedAt: Date?

    init(
        now: @escaping @Sendable () -> Date = { Date() },
        load: @escaping @Sendable () async -> [ApplicationChoice] = {
            ApplicationCatalog.enumerate(directories: ApplicationCatalog.standardDirectories)
        }
    ) {
        self.now = now
        self.load = load
    }

    func applications() async -> [ApplicationChoice] {
        if let scan { return await scan.value }
        if let cached, let scannedAt, now().timeIntervalSince(scannedAt) < 300 { return cached }
        let scan = Task.detached(priority: .utility, operation: load)
        self.scan = scan
        let applications = await scan.value
        cached = applications
        scannedAt = now()
        self.scan = nil
        return applications
    }
}

/// Picker policy is independent of window management and stored rules.
enum ApplicationPickerModel {
    enum SectionKind: String, Hashable, Sendable {
        case recent = "Recent"
        case running = "Running"
        case allApps = "All Apps"
        case results = "Results"
    }

    struct Row: Hashable, Identifiable, Sendable {
        let section: SectionKind
        let application: ApplicationChoice
        /// The containing folder. Set only when another listed app has the same name.
        let caption: String?
        var window: ApplicationPickerWindow? = nil
        var windows: [ApplicationPickerWindow]? = nil
        var showsAllAction = false
        var appRowID: String { "\(section.rawValue):\(application.id)" }
        var id: String {
            if let window { return appRowID + ":window:" + window.id }
            return showsAllAction ? appRowID + ":more" : appRowID
        }
    }

    struct Section: Hashable, Identifiable, Sendable {
        let kind: SectionKind
        let rows: [Row]
        var id: SectionKind { kind }
    }

    struct Expansion: Equatable {
        var rowID: String?
        var showingAll = false

        mutating func expand(_ row: Row) -> Bool {
            guard row.window == nil, !row.showsAllAction, row.windows?.isEmpty == false else { return false }
            rowID = row.appRowID
            showingAll = false
            return true
        }

        mutating func collapse() -> String? {
            let parent = rowID
            rowID = nil
            showingAll = false
            return parent
        }
    }

    static func windowSections(_ sections: [Section], expansion: Expansion,
                               windows: ((ApplicationChoice) -> [ApplicationPickerWindow]?)?) -> [Section] {
        guard let windows else { return sections }
        var availableByApp: [String: [ApplicationPickerWindow]] = [:]
        var stoppedApps: Set<String> = []
        return sections.map { section in
            Section(kind: section.kind, rows: section.rows.flatMap { row -> [Row] in
                var app = row
                if availableByApp[app.application.id] == nil && !stoppedApps.contains(app.application.id) {
                    if let available = windows(app.application) { availableByApp[app.application.id] = available }
                    else { stoppedApps.insert(app.application.id) }
                }
                app.windows = availableByApp[app.application.id]
                guard expansion.rowID == app.id, let available = app.windows, !available.isEmpty else { return [app] }
                let visible = expansion.showingAll ? available : Array(available.prefix(5))
                var rows = [app] + visible.map { window in
                    var child = app
                    child.window = window
                    return child
                }
                if !expansion.showingAll && available.count > 5 {
                    var more = app
                    more.showsAllAction = true
                    rows.append(more)
                }
                return rows
            })
        }
    }

    static func windowCount(_ count: Int) -> String {
        count == 0 ? "No window here" : "\(count) " + (count == 1 ? "window" : "windows")
    }

    static func hints(for row: Row?, returnHint: String) -> (primary: String, secondary: String?) {
        if row?.window != nil { return ("Use this window", "Back") }
        if row?.showsAllAction == true { return ("Show all windows", "Back") }
        return (returnHint, row?.windows?.isEmpty == false ? "Windows" : nil)
    }

    /// Without a search: Recent (when not empty), Running, and All Apps. An app can
    /// appear in more than one section. With a search: one Results section, by name.
    static func sections(
        installed: [ApplicationChoice], running: [ApplicationChoice], recent: [ApplicationChoice] = [],
        excluding exclusions: Set<String> = [], search: String = "",
        captions precomputed: [String: String]? = nil,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [Section] {
        func usable(_ applications: [ApplicationChoice]) -> [ApplicationChoice] {
            var seen = exclusions
            return applications.filter {
                !$0.bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && seen.insert($0.bundleIdentifier).inserted
            }
        }
        let recent = usable(recent)
        let running = sorted(usable(running))
        // A running app outside the scanned folders still belongs in All Apps.
        let all = sorted(usable(running + installed))
        let captions = precomputed ?? folderCaptions(for: usable(recent + running + installed), home: home)
        func rows(_ kind: SectionKind, _ applications: [ApplicationChoice]) -> Section {
            Section(kind: kind, rows: applications.map { Row(section: kind, application: $0, caption: captions[$0.id]) })
        }
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.isEmpty else {
            return [rows(.results, sorted(usable(recent + running + installed)).filter {
                $0.name.localizedStandardContains(query)
            })]
        }
        return (recent.isEmpty ? [] : [rows(.recent, recent)]) + [rows(.running, running), rows(.allApps, all)]
    }

    /// Recent bundle identifiers become choices from the lists already loaded, then
    /// from `lookup`. Identifiers that no longer resolve are left out.
    static func recentChoices(
        _ identifiers: [String], known: [ApplicationChoice], lookup: (String) -> ApplicationChoice?
    ) -> [ApplicationChoice] {
        var byIdentifier: [String: ApplicationChoice] = [:]
        for application in known where byIdentifier[application.id] == nil { byIdentifier[application.id] = application }
        return identifiers.compactMap { byIdentifier[$0] ?? lookup($0) }
    }

    /// What VoiceOver reads when the keyboard highlight reaches a row, e.g. "Safari, Recent".
    static func announcement(for row: Row) -> String {
        ([row.application.name] + [row.caption].compactMap { $0 } + [row.section.rawValue]).joined(separator: ", ")
    }

    /// Keyboard highlight after an arrow key. Down from no highlight starts at the first row.
    static func move(_ highlight: String?, by offset: Int, in rows: [Row]) -> String? {
        guard !rows.isEmpty else { return nil }
        guard let highlight, let index = rows.firstIndex(where: { $0.id == highlight }) else {
            return offset > 0 ? rows[0].id : nil
        }
        return rows[min(max(index + offset, 0), rows.count - 1)].id
    }

    /// Keeps the highlight while its row is listed. A search highlights its first result
    /// so Return opens it; the unfiltered list starts without a highlight.
    static func highlight(_ highlight: String?, in rows: [Row], searching: Bool) -> String? {
        if let highlight, rows.contains(where: { $0.id == highlight }) { return highlight }
        return searching ? rows.first?.id : nil
    }

    static func validationMessage(for application: ApplicationChoice?, excluding exclusions: Set<String>) -> String? {
        guard let application, !application.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "This application has no bundle identifier. Choose another application."
        }
        guard !exclusions.contains(application.id) else { return "This application is already included. Choose another application." }
        return nil
    }

    /// The containing folder as Finder names it: "~/Applications/Chrome Apps" for
    /// `~/Applications/Chrome Apps.localized`, otherwise the full folder path.
    static func folderCaption(for url: URL, home: URL) -> String {
        let folder = url.deletingLastPathComponent().standardizedFileURL
        let homeComponents = home.standardizedFileURL.pathComponents
        let components = folder.pathComponents
        let inHome = components.starts(with: homeComponents)
        let start = inHome ? homeComponents.count : 1
        var path = inHome ? home.standardizedFileURL : URL(filePath: "/")
        var names: [String] = []
        for component in components.dropFirst(start) {
            path.append(path: component)
            var name = FileManager.default.displayName(atPath: path.path)
            if name.lowercased().hasSuffix(".localized") { name.removeLast(".localized".count) }
            names.append(name.isEmpty ? component : name)
        }
        return (inHome ? "~" : "") + (names.isEmpty && !inHome ? "/" : names.map { "/" + $0 }.joined())
    }

    /// Folder captions by bundle ID, only for apps whose name another app shares. It reads
    /// Finder names from disk, so the picker computes it once per load, not per redraw.
    static func folderCaptions(
        for applications: [ApplicationChoice], home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [String: String] {
        // One app can be listed in several sections; count each bundle ID once.
        var seen = Set<String>()
        let distinct = applications.filter { seen.insert($0.id).inserted }
        let byName = Dictionary(grouping: distinct) { $0.name.localizedLowercase }
        var captions: [String: String] = [:]
        for group in byName.values where group.count > 1 {
            for application in group { captions[application.id] = folderCaption(for: application.url, home: home) }
        }
        return captions
    }

    private static func sorted(_ applications: [ApplicationChoice]) -> [ApplicationChoice] {
        applications.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }
}
