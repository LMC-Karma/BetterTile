// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 LMC-Karma

import AppKit
import BetterTileCore
import Foundation
import Observation

struct SavedLayoutActionSettings: Codable, Equatable {
    var shortcut: KeyboardShortcut? = nil
    var showInMenuBar = false
    var showInWheel = false
}

/// Mac-local actions, keyed by library filename. Never part of a layout export or configuration.
@MainActor @Observable final class SavedLayoutActionStore {
    static let maximumBytes = 256 * 1024
    let url: URL
    private(set) var values: [String: SavedLayoutActionSettings] = [:]
    private(set) var message: String?
    private(set) var loadError: String?
    @ObservationIgnored var didChange: () -> Void = {}
    private var baseline: Data?
    private struct Document: Codable { var version = 1; var layouts: [String: SavedLayoutActionSettings] = [:] }

    init(files: SavedLayoutFiles) {
        url = files.directory.deletingLastPathComponent().appendingPathComponent("Layout Actions.json")
        load()
    }

    func settings(for file: String) -> SavedLayoutActionSettings { values[file] ?? .init() }

    func load() {
        do {
            let (document, bytes) = try readDocument()
            values = document.layouts; baseline = bytes; loadError = nil; message = nil
        } catch {
            values = [:]; baseline = nil
            loadError = "Layout Actions.json could not be read. Its settings are ignored and the file was kept."
        }
    }

    private func readDocument() throws -> (Document, Data?) {
        let bytes = try read()
        let document = try bytes.map { try JSONDecoder().decode(Document.self, from: $0) } ?? Document()
        guard document.version == 1, document.layouts.count <= 1024,
              document.layouts.allSatisfy({ file, value in
                  DisplayTriggerDocument.isValidLayoutFile(file) && Self.valid(value.shortcut)
              }) else { throw SavedLayoutFileError(message: "Layout Actions.json contains unsupported settings.") }
        return (document, bytes)
    }
    var diskDocumentIsValid: Bool { (try? readDocument()) != nil }

    @discardableResult func set(_ file: String, _ value: SavedLayoutActionSettings) -> Bool {
        guard DisplayTriggerDocument.isValidLayoutFile(file), Self.valid(value.shortcut) else { return false }
        var next = values
        next[file] = value == .init() ? nil : value
        return save(next)
    }

    @discardableResult func remove(_ file: String) -> Bool {
        guard values[file] != nil else { return true }
        var next = values; next[file] = nil
        return save(next)
    }

    @discardableResult func retain(_ files: Set<String>) -> Bool {
        let next = values.filter { files.contains($0.key) }
        return next == values || save(next)
    }

    private static func valid(_ shortcut: KeyboardShortcut?) -> Bool {
        guard let shortcut else { return true }
        return shortcut.keyCode <= 127 && !shortcut.modifiers.isEmpty
            && shortcut.modifiers.subtracting([.control, .option, .shift, .command]).isEmpty
            && !shortcut.keyLabel.isEmpty && shortcut.keyLabel.utf8.count <= 32
    }

    private func read() throws -> Data? {
        var source = url; source.removeAllCachedResourceValues()
        guard FileManager.default.fileExists(atPath: source.path)
            || (try? source.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true else { return nil }
        let info = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard info.isRegularFile == true, info.isSymbolicLink != true,
              (info.fileSize ?? 0) <= Self.maximumBytes else {
            throw SavedLayoutFileError(message: "Layout Actions.json is not a bounded regular file.")
        }
        let handle = try FileHandle(forReadingFrom: source); defer { try? handle.close() }
        let data = try handle.read(upToCount: Self.maximumBytes + 1) ?? Data()
        guard data.count <= Self.maximumBytes else { throw SavedLayoutFileError(message: "Layout Actions.json is too large.") }
        return data
    }

    private func save(_ next: [String: SavedLayoutActionSettings]) -> Bool {
        guard loadError == nil else { message = loadError; return false }
        do {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let bytes = try encoder.encode(Document(layouts: next))
            guard next.count <= 1024, bytes.count <= Self.maximumBytes else {
                throw SavedLayoutFileError(message: "There are too many layout actions to save.")
            }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            var coordinationError: NSError?, operationError: (any Error)?
            NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { destination in
                do {
                    guard try read() == baseline else {
                        throw SavedLayoutFileError(message: "Layout Actions.json changed outside BetterTile. Reload before changing it. Nothing was overwritten.")
                    }
                    try bytes.write(to: destination, options: [.atomic, .completeFileProtectionUnlessOpen])
                } catch { operationError = error }
            }
            if let operationError { throw operationError }
            if let coordinationError { throw coordinationError }
            values = next; baseline = bytes; message = nil; didChange(); return true
        } catch { message = error.localizedDescription; return false }
    }
}

/// Stored shortcut comparisons use physical key + modifiers, never the presentation label.
enum SavedLayoutShortcutPolicy {
    static func same(_ lhs: KeyboardShortcut, _ rhs: KeyboardShortcut) -> Bool {
        lhs.keyCode == rhs.keyCode && lhs.modifiers == rhs.modifiers
    }

    static func conflict(_ key: KeyboardShortcut, configuration: BetterTileConfiguration,
                         layouts: [String: SavedLayoutActionSettings], excluding: String? = nil,
                         names: [String: String] = [:]) -> String? {
        if let binding = configuration.shortcuts.first(where: { $0.shortcut.map { same($0, key) } == true }) {
            return "Conflicts with \(binding.action.title). Choose another shortcut."
        }
        if configuration.layoutWheel.isEnabled && configuration.layoutWheel.triggers.keyboardEnabled {
            let trigger = configuration.layoutWheel.triggers
            if (trigger.keyboard == .modifiers && key.modifiers.isSuperset(of: trigger.modifiers))
                || (trigger.keyboard == .rightControl && key.modifiers.contains(.control)) {
                return "Conflicts with the Layout Wheel trigger. Choose another shortcut."
            }
        }
        if let file = layouts.keys.sorted().first(where: { $0 != excluding && layouts[$0]?.shortcut.map { same($0, key) } == true }) {
            return "Conflicts with \(names[file] ?? "another Saved Layout"). Choose another shortcut."
        }
        // Common system combinations. Carbon registration is the final public-API check;
        // macOS offers no complete public inventory of user-defined system shortcuts.
        if key.modifiers.isEmpty || (key.modifiers == .command && [12, 48, 49].contains(key.keyCode))
            || (key.modifiers == [.command, .shift] && [20, 21, 23].contains(key.keyCode))
            || (key.modifiers.contains(.control) && [123, 124, 125, 126].contains(key.keyCode)) {
            return "This shortcut is reserved by macOS. Choose another shortcut."
        }
        return nil
    }
}

struct SavedLayoutActionEntry: Identifiable, Equatable {
    let file: String
    let document: SavedLayoutDocument
    var id: String { file }
    var name: String { document.name }
}

@MainActor protocol SavedLayoutWatching: AnyObject {
    func start(directory: URL, actionsURL: URL, changed: @escaping @MainActor () -> Void) throws
    func synchronize() throws
    func stop()
    var hasUnwatchedFiles: Bool { get }
}
extension SavedLayoutWatching { var hasUnwatchedFiles: Bool { false } }

/// File observation belongs to the app, not the lifetime of Settings or the panel.
@MainActor @Observable final class SavedLayoutActions {
    let store: SavedLayoutActionStore
    let files: SavedLayoutFiles
    private(set) var entries: [SavedLayoutActionEntry] = []
    private(set) var applicationNames: [String: String] = [:]
    var message: String?
    @ObservationIgnored var didChange: () -> Void = {}
    @ObservationIgnored private let watcher: any SavedLayoutWatching
    @ObservationIgnored private let clock: BetterTileClock
    @ObservationIgnored private(set) var reloadTask: Task<Void, Never>?
    private var signature: [String: SavedLayoutFileStamp?] = [:]
    private var actionsModification: SavedLayoutFileStamp?
    private var libraryIdentity: SavedLayoutFileStamp.Identity?
    private var isObserving = false
    private var isRefreshing = false
    private var reloadGeneration = 0
    @ObservationIgnored private var firstChange: BetterTileClock.Instant?
    private static let partialWatchFailure = "Some Saved Layout changes could not be watched. File additions and removals are still watched. Reload the library to retry."
    private static let watchFailure = "Saved Layout changes could not be watched. Reload the library in Saved Layouts, or restart BetterTile to watch it again."

    init(files: SavedLayoutFiles, watcher: any SavedLayoutWatching = SavedLayoutFileWatcher(), clock: BetterTileClock = .live) {
        self.clock = clock
        self.watcher = watcher
        self.files = files; store = .init(files: files)
        store.didChange = { [weak self] in self?.refresh() }
        refresh()
    }
    isolated deinit {
        reloadTask?.cancel()
        if isObserving { watcher.stop() }
    }
    var names: [String: String] { Dictionary(uniqueKeysWithValues: entries.map { ($0.file, $0.name) }) }
    /// A readable listing includes invalid files. A temporarily missing folder
    /// does not prove that its layouts were deleted.
    var knownLibraryFiles: Set<String>? { libraryIdentity.map { _ in Set(signature.keys) } }
    var menuEntries: [SavedLayoutActionEntry] { entries.filter { store.settings(for: $0.file).showInMenuBar } }
    var wheelEntries: [SavedLayoutActionEntry] { entries.filter { store.settings(for: $0.file).showInWheel } }

    func start() {
        guard !isObserving else { return }
        isObserving = true
        do {
            try watcher.start(directory: files.directory, actionsURL: store.url) { [weak self] in
                self?.scheduleReload()
            }
            if message == Self.watchFailure { message = nil }
            checkForChanges()
        } catch { watchingFailed() }
    }
    func stop() {
        guard isObserving else { return }
        isObserving = false
        firstChange = nil
        reloadGeneration &+= 1
        reloadTask?.cancel(); reloadTask = nil
        watcher.stop()
    }
    private func scheduleReload() {
        guard isObserving else { return }
        let clock = clock, now = clock.now
        let began = firstChange ?? now
        let maximum = began.advanced(by: .seconds(1))
        // Once due, keep the runnable check even if another notification arrives first.
        if reloadTask != nil, now >= maximum { return }
        reloadTask?.cancel()
        reloadGeneration &+= 1
        firstChange = began
        let generation = reloadGeneration
        let trailing = min(now.advanced(by: .milliseconds(150)), maximum)
        let deadline = min(now.advanced(by: .milliseconds(500)), maximum)
        reloadTask = Task { [weak self] in
            do {
                try await clock.sleep(until: trailing)
                while !Task.isCancelled {
                    guard self?.isObserving == true, self?.reloadGeneration == generation else { return }
                    // Keep the last catalog through a chunked write. Invalid files become visible
                    // after the bounded window, so a permanently bad file cannot stall observation.
                    if clock.now < deadline, self?.hasIncompleteChanges() == true {
                        try await clock.sleep(until: min(clock.now.advanced(by: .milliseconds(50)), deadline))
                        continue
                    }
                    self?.checkForChanges()
                    if self?.reloadGeneration == generation {
                        self?.firstChange = nil
                        self?.reloadTask = nil
                    }
                    return
                }
            } catch { /* Cancellation is expected when a later event resets the trailing edge. */ }
        }
    }
    private func hasIncompleteChanges() -> Bool {
        for url in (try? files.entries()) ?? [] where signature[url.lastPathComponent] != SavedLayoutFileStamp(url) {
            if (try? SavedLayoutValidator.decode(files.read(url))) == nil { return true }
        }
        return SavedLayoutFileStamp(store.url) != actionsModification && !store.diskDocumentIsValid
    }
    private func synchronizeWatcher() {
        guard isObserving else { return }
        do {
            try watcher.synchronize()
            if watcher.hasUnwatchedFiles { message = Self.partialWatchFailure }
            else if message == Self.watchFailure || message == Self.partialWatchFailure { message = nil }
        } catch { watchingFailed() }
    }
    private func watchingFailed() {
        stop()
        message = Self.watchFailure
    }
    func reload() {
        start()
        checkForChanges()
    }
    func checkForChanges() {
        synchronizeWatcher()
        let urls = (try? files.entries()) ?? []
        let next = Dictionary(uniqueKeysWithValues: urls.map { ($0.lastPathComponent, SavedLayoutFileStamp($0)) })
        let actionStamp = SavedLayoutFileStamp(store.url)
        let directoryIdentity = SavedLayoutFileStamp(files.directory)?.identity
        guard next != signature || actionStamp != actionsModification || directoryIdentity != libraryIdentity else { return }
        if actionStamp != actionsModification { store.load() }
        refresh()
    }
    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        let editor = SavedLayoutEditor(files: files); editor.refreshLibrary()
        guard editor.libraryError == nil else { message = editor.libraryError; return }
        entries = editor.entries.compactMap { url in
            editor.entryDocuments[url].map { .init(file: url.lastPathComponent, document: $0) }
        }
        applicationNames = Dictionary(uniqueKeysWithValues: Set(entries.flatMap { $0.document.slots.flatMap { $0.prefer.compactMap { if case let .app(id) = $0 { id } else { nil } } } }).map { id in
            let name = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
                .flatMap { ApplicationCatalog.application(at: $0)?.name } ?? "This app"
            return (id, name)
        })
        signature = Dictionary(uniqueKeysWithValues: editor.entries.map { ($0.lastPathComponent, SavedLayoutFileStamp($0)) })
        actionsModification = SavedLayoutFileStamp(store.url)
        libraryIdentity = SavedLayoutFileStamp(files.directory)?.identity
        synchronizeWatcher()
        // A missing folder can be in the middle of replacement. Prune only after a readable listing.
        // Invalid layouts keep their settings; only confirmed removals or renames lose them.
        if libraryIdentity != nil, !store.retain(Set(editor.entries.map(\.lastPathComponent))) { message = store.message }
        actionsModification = SavedLayoutFileStamp(store.url)
        didChange()
    }
    func load(_ file: String) throws -> SavedLayoutDocument {
        guard DisplayTriggerDocument.isValidLayoutFile(file) else {
            throw SavedLayoutFileError(message: "This Saved Layout is no longer available. Reload the library.")
        }
        return try SavedLayoutValidator.decode(files.read(files.directory.appendingPathComponent(file)))
    }
}
