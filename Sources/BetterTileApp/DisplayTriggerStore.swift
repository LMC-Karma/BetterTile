// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 LMC-Karma

import BetterTileCore
import Foundation
import Observation

/// Reads and writes `Display Triggers.json`, which binds Saved Layouts to display sets on this Mac.
/// It holds only declarative data and never invokes the window system.
/// An unreadable file is reported and kept as it is. Saving stays blocked until it reads again.
@MainActor @Observable final class DisplayTriggerStore {
    let url: URL
    private(set) var document = DisplayTriggerDocument()
    /// Why the file cannot be used. While set, nothing is written.
    private(set) var loadError: String?
    private(set) var message: String?
    private var baseline: Data?

    init(url: URL) {
        self.url = url
        load()
    }

    /// Next to the Saved Layouts folder: `…/BetterTile/Display Triggers.json`.
    static func standard(files: SavedLayoutFiles = .standard) -> DisplayTriggerStore {
        DisplayTriggerStore(url: files.directory.deletingLastPathComponent().appendingPathComponent("Display Triggers.json"))
    }

    func trigger(for layoutFile: String) -> DisplayTrigger? { document.trigger(for: layoutFile) }

    func load() {
        message = nil
        do {
            baseline = try Self.read(url)
            document = try baseline.map(DisplayTriggerDocument.decode) ?? DisplayTriggerDocument()
            loadError = nil
        } catch {
            baseline = nil
            document = DisplayTriggerDocument()
            loadError = "\(error.localizedDescription) The file was kept and not changed. Fix or move it, then reload."
        }
    }

    @discardableResult func bind(_ trigger: DisplayTrigger, replacing other: String? = nil) -> Bool {
        var updated = document
        if let other { updated.remove(layoutFile: other) }
        updated.set(trigger)
        return save(updated)
    }

    enum BindResult: Equatable {
        case bound, failed
        /// Another layout owns this display in this set. Nothing changed. Bind `trigger` with `replacing` after the user agrees.
        case needsReplacement(trigger: DisplayTrigger, replacing: String)
    }

    /// Binds a layout to the displays connected now. A new binding starts with both switches off.
    /// An existing one keeps its switches and unknown keys.
    func bindCurrent(layoutFile: String, displays: [DisplayFingerprint], target: Int) -> BindResult {
        guard displays.indices.contains(target) else { return .failed }
        var value = document.trigger(for: layoutFile) ?? DisplayTrigger(layoutFile: layoutFile, displays: displays, target: target)
        value.displays = displays
        value.target = target
        if let other = document.conflict(displays: displays, target: target, excluding: layoutFile) {
            return .needsReplacement(trigger: value, replacing: other.layoutFile)
        }
        return bind(value) ? .bound : .failed
    }

    @discardableResult func update(_ layoutFile: String, _ change: (inout DisplayTrigger) -> Void) -> Bool {
        guard var trigger = document.trigger(for: layoutFile) else { return false }
        change(&trigger)
        return bind(trigger)
    }

    @discardableResult func remove(_ layoutFile: String) -> Bool {
        var updated = document
        updated.remove(layoutFile: layoutFile)
        return save(updated)
    }

    private func save(_ updated: DisplayTriggerDocument) -> Bool {
        guard loadError == nil else { message = "Display Triggers.json could not be read, so nothing was saved."; return false }
        do {
            let data = try updated.encoded()
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let expected = baseline
            var coordinationError: NSError?
            var operationError: (any Error)?
            NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { coordinated in
                do {
                    guard try Self.read(coordinated) == expected else {
                        throw DisplayTriggerError("Display Triggers.json changed outside BetterTile. Reload to read it. Nothing was overwritten.")
                    }
                    try data.write(to: coordinated, options: [.atomic, .completeFileProtectionUnlessOpen])
                } catch { operationError = error }
            }
            if let operationError { throw operationError }
            if let coordinationError { throw coordinationError }
            baseline = data
            document = updated
            message = nil
            return true
        } catch {
            message = "Couldn’t save display triggers: \(error.localizedDescription)"
            return false
        }
    }

    /// Nil when the file does not exist. Throws for a symbolic link, a folder, or a file over the limit.
    private static func read(_ source: URL) throws -> Data? {
        // resourceValues caches on the URL, so a replaced file could show an old size or link state.
        var url = source
        url.removeAllCachedResourceValues()
        guard FileManager.default.fileExists(atPath: url.path) || (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true else { return nil }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw DisplayTriggerError("Display Triggers.json is a folder or a symbolic link.")
        }
        // Check the size before opening, as the layout library does, so a huge file is never read.
        guard (values.fileSize ?? 0) <= DisplayTriggerDocument.maximumBytes else {
            throw DisplayTriggerError("Display Triggers.json is larger than 256 KiB.")
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: DisplayTriggerDocument.maximumBytes + 1) ?? Data()
        guard data.count <= DisplayTriggerDocument.maximumBytes else { throw DisplayTriggerError("Display Triggers.json is larger than 256 KiB.") }
        return data
    }
}
