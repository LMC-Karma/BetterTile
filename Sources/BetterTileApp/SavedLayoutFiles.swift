// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 LMC-Karma

import BetterTileCore
import Foundation

struct SavedLayoutFileError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Owns only declarative files. Reads and writes never invoke the window system.
struct SavedLayoutFiles {
    let directory: URL

    init(directory: URL) { self.directory = directory.resolvingSymlinksInPath() }

    func owns(_ url: URL) -> Bool {
        url.deletingLastPathComponent().resolvingSymlinksInPath() == directory.resolvingSymlinksInPath()
    }

    static var standard: Self {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let name = Bundle.main.bundleIdentifier == "com.lmckarma.BetterTile.debug" ? "BetterTile Debug" : "BetterTile"
        return Self(directory: support.appending(path: "\(name)/Saved Layouts", directoryHint: .isDirectory))
    }

    func entries() throws -> [URL] {
        do {
            return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension.lowercased() == "json" }
                .map { $0.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent($0.lastPathComponent) }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile { return [] }
    }

    func read(_ url: URL) throws -> Data {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw SavedLayoutFileError(message: "Choose a regular JSON file, not a folder or symbolic link. The source was kept.")
        }
        guard (values.fileSize ?? 0) <= SavedLayoutValidator.maximumBytes else {
            throw SavedLayoutFileError(message: "This layout exceeds 1 MiB. Reduce the file size and reload. The source was kept.")
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: SavedLayoutValidator.maximumBytes + 1) ?? Data()
        guard data.count <= SavedLayoutValidator.maximumBytes else {
            throw SavedLayoutFileError(message: "This layout exceeds 1 MiB. Reduce the file size and reload. The source was kept.")
        }
        return data
    }

    func create(_ data: Data) throws -> URL {
        _ = try SavedLayoutValidator.decode(data)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(UUID().uuidString + ".json")
        let staging = directory.appendingPathComponent("." + UUID().uuidString + ".tmp")
        defer { try? FileManager.default.removeItem(at: staging) }
        try data.write(to: staging, options: [.atomic, .completeFileProtectionUnlessOpen])
        // A same-directory link publishes a complete new file without replacing a collision.
        try FileManager.default.linkItem(at: staging, to: url)
        return url.resolvingSymlinksInPath()
    }

    func save(_ data: Data, to url: URL, expected: Data) throws {
        try requireOwned(url)
        _ = try SavedLayoutValidator.decode(data)
        try coordinatedChange(url, options: .forReplacing) { coordinatedURL in
            try requireUnchanged(coordinatedURL, expected: expected)
            try data.write(to: coordinatedURL, options: [.atomic, .completeFileProtectionUnlessOpen])
        }
    }

    func delete(_ url: URL, expected: Data) throws {
        try requireOwned(url)
        try coordinatedChange(url, options: .forDeleting) { coordinatedURL in
            try requireUnchanged(coordinatedURL, expected: expected)
            try FileManager.default.removeItem(at: coordinatedURL)
        }
    }

    private func coordinatedChange(_ url: URL, options: NSFileCoordinator.WritingOptions,
                                   operation: (URL) throws -> Void) throws {
        var coordinationError: NSError?
        var operationError: (any Error)?
        NSFileCoordinator().coordinate(writingItemAt: url, options: options, error: &coordinationError) { coordinatedURL in
            do { try operation(coordinatedURL) } catch { operationError = error }
        }
        if let operationError { throw operationError }
        if let coordinationError { throw coordinationError }
    }

    private func requireOwned(_ url: URL) throws {
        guard owns(url) else {
            throw SavedLayoutFileError(message: "Only files in the Saved Layouts library can be changed here. Import a copy first.")
        }
    }

    private func requireUnchanged(_ url: URL, expected: Data) throws {
        guard try read(url) == expected else {
            throw SavedLayoutFileError(message: "This file changed outside BetterTile. Reload to inspect it, or Save As to keep your draft in a new file. Nothing was overwritten.")
        }
    }
}
