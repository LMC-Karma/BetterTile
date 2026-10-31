// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 LMC-Karma

import BetterTileCore
import Foundation

/// Optional matching hints, separate from layout files and configuration. The non-JSON extension keeps
/// the library listing from showing this cache as a layout. Failures never block Apply or file actions.
struct SavedLayoutPositions {
    static let maximumBytes = 262_144
    let url: URL
    init(files: SavedLayoutFiles) { url = files.directory.appendingPathComponent("Saved Layout Positions.cache") }
    private struct Contents: Codable {
        var version = 1
        var layouts: [String: [String: NormalizedRect]] = [:]
    }
    func frames(for file: String) -> [String: NormalizedRect] { (try? read().layouts[file]) ?? [:] }
    func set(_ frames: [String: NormalizedRect], for file: String) {
        change(preserving: file) { value in
            if frames.isEmpty { value.layouts[file] = nil } else { value.layouts[file] = frames }
        }
    }
    func remove(_ file: String) { set([:], for: file) }
    func retain(_ slots: Set<String>, for file: String) { set(frames(for: file).filter { slots.contains($0.key) }, for: file) }
    func restore(_ previous: [String: NormalizedRect], for file: String, ifCurrent expected: [String: NormalizedRect]) {
        change { value in
            guard (value.layouts[file] ?? [:]) == expected else { return }
            value.layouts[file] = previous.isEmpty ? nil : previous
        }
    }
    private func read() throws -> Contents {
        var source = url; source.removeAllCachedResourceValues()
        guard FileManager.default.fileExists(atPath: url.path)
                || (try? source.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true else { return Contents() }
        let attributes = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard attributes.isRegularFile == true, attributes.isSymbolicLink != true,
              (attributes.fileSize ?? 0) <= Self.maximumBytes else { throw CocoaError(.fileReadCorruptFile) }
        let handle = try FileHandle(forReadingFrom: source)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: Self.maximumBytes + 1) ?? Data()
        guard data.count <= Self.maximumBytes else { throw CocoaError(.fileReadCorruptFile) }
        let value = try JSONDecoder().decode(Contents.self, from: data)
        guard valid(value) else { throw CocoaError(.fileReadCorruptFile) }
        return value
    }
    private func valid(_ value: Contents) -> Bool {
        value.version == 1 && value.layouts.allSatisfy { file, slots in
            !file.isEmpty && file.count <= 255 && file == URL(fileURLWithPath: file).lastPathComponent
                && file.lowercased().hasSuffix(".json") && slots.count <= SavedLayoutValidator.maximumSlots
                && slots.allSatisfy { !$0.key.isEmpty && $0.key.count <= 256 && (try? $0.value.validated()) != nil }
        }
    }
    /// Keep the just-written layout and the most recently modified library files. File dates
    /// are transient eviction input, never stored. Missing files and links lose their hints.
    private func prune(_ value: inout Contents, preserving file: String?) -> [String] {
        var dates: [String: Date] = [:]
        for key in value.layouts.keys {
            let source = url.deletingLastPathComponent().appendingPathComponent(key)
            guard let attributes = try? source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey]),
                  attributes.isRegularFile == true, attributes.isSymbolicLink != true else {
                value.layouts[key] = nil; continue
            }
            dates[key] = attributes.contentModificationDate ?? .distantPast
        }
        var oldest = value.layouts.keys.filter { $0 != file }.sorted { lhs, rhs in
            dates[lhs] == dates[rhs] ? lhs < rhs : dates[lhs, default: .distantPast] < dates[rhs, default: .distantPast]
        }
        while value.layouts.count > 256, !oldest.isEmpty { value.layouts[oldest.removeFirst()] = nil }
        return oldest
    }
    private func change(preserving file: String? = nil, _ update: (inout Contents) -> Void) {
        // Preserve a corrupt/future cache. Reading it falls back to saved positions until it is removed.
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            var error: NSError?
            NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &error) { destination in
                guard var value = try? read() else { return }
                update(&value)
                var oldest = prune(&value, preserving: file)
                guard valid(value) else { return }
                while let data = try? JSONEncoder().encode(value) {
                    if data.count <= Self.maximumBytes {
                        try? data.write(to: destination, options: [.atomic, .completeFileProtectionUnlessOpen]); return
                    }
                    guard !oldest.isEmpty else { return }
                    value.layouts[oldest.removeFirst()] = nil
                }
            }
        } catch { /* Optional hints must not block an Apply. */ }
    }
}

struct SavedLayoutPositionContext {
    var file: String
    var store: SavedLayoutPositions
    var layoutURL: URL { store.url.deletingLastPathComponent().appendingPathComponent(file) }
}
