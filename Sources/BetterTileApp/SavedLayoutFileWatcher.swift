// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 LMC-Karma

import CoreServices
import Darwin
import Foundation

/// Metadata only. Inode identity catches atomic replacement even when an editor preserves dates.
/// Change time also catches same-size in-place edits with preserved dates. Attribute-only changes
/// can therefore trigger a decode too; accepting those checks avoids missing real content changes.
struct SavedLayoutFileStamp: Equatable {
    struct Identity: Equatable { var device: dev_t; var inode: ino_t }
    let identity: Identity
    let mode: mode_t
    let size: off_t
    let modifiedSeconds: Int
    let modifiedNanoseconds: Int
    let changedSeconds: Int
    let changedNanoseconds: Int
    var isDirectory: Bool { mode & mode_t(S_IFMT) == mode_t(S_IFDIR) }

    init?(_ url: URL) {
        var value = stat()
        guard lstat(url.path, &value) == 0 else { return nil }
        identity = .init(device: value.st_dev, inode: value.st_ino)
        mode = value.st_mode; size = value.st_size
        modifiedSeconds = value.st_mtimespec.tv_sec; modifiedNanoseconds = value.st_mtimespec.tv_nsec
        changedSeconds = value.st_ctimespec.tv_sec; changedNanoseconds = value.st_ctimespec.tv_nsec
    }
}

/// Dispatch sources are thread-safe. Their cancellation handler owns the descriptor's final close.
private final class SavedLayoutFileObservation: @unchecked Sendable {
    let token = UUID()
    let identity: SavedLayoutFileStamp.Identity
    let source: any DispatchSourceFileSystemObject
    init(descriptor: Int32, identity: SavedLayoutFileStamp.Identity) {
        self.identity = identity
        source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
            eventMask: [.write, .extend, .attrib, .link, .rename, .delete, .revoke], queue: .main)
        source.setCancelHandler { close(descriptor) }
    }
    func cancel() { source.cancel() }
    deinit { source.cancel() }
}

/// One recursive, event-driven stream covers data writes without opening each child file.
@MainActor protocol SavedLayoutFileEvents: AnyObject {
    func start(root: URL, changed: @escaping @MainActor ([URL], Bool) -> Void) throws
    func stop()
}

private final class SavedLayoutEventCallback: @unchecked Sendable {
    let changed: @MainActor ([URL], Bool) -> Void
    init(_ changed: @escaping @MainActor ([URL], Bool) -> Void) { self.changed = changed }
}

/// The stream owns its callback context. The last subscription reference releases it exactly once.
private final class SavedLayoutEventSubscription: @unchecked Sendable {
    let stream: FSEventStreamRef
    init(_ stream: FSEventStreamRef) { self.stream = stream }
    deinit {
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
}

@MainActor private final class SavedLayoutNativeFileEvents: SavedLayoutFileEvents {
    private var subscription: SavedLayoutEventSubscription?

    func start(root: URL, changed: @escaping @MainActor ([URL], Bool) -> Void) throws {
        stop()
        let callback = SavedLayoutEventCallback(changed)
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(callback).toOpaque(),
            retain: { pointer in
                guard let pointer else { return nil }
                _ = Unmanaged<SavedLayoutEventCallback>.fromOpaque(pointer).retain()
                return pointer
            }, release: { pointer in
                if let pointer { Unmanaged<SavedLayoutEventCallback>.fromOpaque(pointer).release() }
            }, copyDescription: nil)
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes
            | kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagNoDefer)
        let stream = withExtendedLifetime(callback) {
            FSEventStreamCreate(nil, { _, info, count, paths, eventFlags, _ in
                guard let info else { return }
                let callback = Unmanaged<SavedLayoutEventCallback>.fromOpaque(info).takeUnretainedValue()
                let strings = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
                let rescanFlags = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs
                    | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped
                    | kFSEventStreamEventFlagRootChanged | kFSEventStreamEventFlagMount | kFSEventStreamEventFlagUnmount)
                let rescan = (0..<count).contains { eventFlags[$0] & rescanFlags != 0 }
                let urls = strings.map { URL(fileURLWithPath: $0) }
                MainActor.assumeIsolated { callback.changed(urls, rescan) }
            }, &context, [root.path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.05, flags) // real-time: native FSEvents batching; product waits use BetterTileClock
        }
        guard let stream else { throw POSIXError(.ENOMEM) }
        let next = SavedLayoutEventSubscription(stream)
        FSEventStreamSetDispatchQueue(stream, .main)
        guard FSEventStreamStart(stream) else { throw POSIXError(.EIO) }
        subscription = next
    }
    func stop() { subscription = nil }
}

/// The watch set has at most two directory sources and one stream, independent of library size.
/// Vnode roots recover missing/recreated folders; FSEvents covers in-place child-file writes.
@MainActor final class SavedLayoutFileWatcher: SavedLayoutWatching {
    private let openFile: (URL) throws -> Int32
    private let events: any SavedLayoutFileEvents
    private(set) var hasUnwatchedFiles = false
    private var directory: URL?
    private var actionsURL: URL?
    private var changed: (@MainActor () -> Void)?
    private var observations: [URL: SavedLayoutFileObservation] = [:]
    private var anchorIdentities: [URL: SavedLayoutFileStamp.Identity?] = [:]
    private var eventRoot: (URL, SavedLayoutFileStamp.Identity)?
    private var eventToken = UUID()

    init(openFile: @escaping (URL) throws -> Int32 = { url in
        let descriptor = open(url.path, O_EVTONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return descriptor
    }, events: (any SavedLayoutFileEvents)? = nil) {
        self.openFile = openFile
        self.events = events ?? SavedLayoutNativeFileEvents()
    }

    private func survivingAncestor() -> URL? {
        guard let actionsURL else { return nil }
        var root = actionsURL.deletingLastPathComponent()
        while SavedLayoutFileStamp(root)?.isDirectory != true && root.path != "/" { root.deleteLastPathComponent() }
        return root
    }

    private func currentAnchorIdentities(_ ancestor: URL) -> [URL: SavedLayoutFileStamp.Identity?] {
        guard let directory, let actionsURL else { return [:] }
        return Dictionary(uniqueKeysWithValues: Set([directory, actionsURL,
            actionsURL.deletingLastPathComponent(), ancestor]).map { ($0, SavedLayoutFileStamp($0)?.identity) })
    }

    private func includesFileEvent(_ url: URL) -> Bool {
        guard let directory, let actionsURL, url.pathExtension.lowercased() == "json",
              let parent = SavedLayoutFileStamp(url.deletingLastPathComponent())?.identity else { return false }
        // Compare directory identities, so /var and /private/var aliases match even for deleted files.
        return parent == SavedLayoutFileStamp(directory)?.identity
            || (url.lastPathComponent.caseInsensitiveCompare(actionsURL.lastPathComponent) == .orderedSame
                && parent == SavedLayoutFileStamp(actionsURL.deletingLastPathComponent())?.identity)
    }

    func start(directory: URL, actionsURL: URL, changed: @escaping @MainActor () -> Void) throws {
        stop()
        self.directory = directory; self.actionsURL = actionsURL; self.changed = changed
        do { try synchronize() }
        catch { stop(); throw error }
    }

    func synchronize() throws {
        guard let directory, let actionsURL else { return }
        guard let root = survivingAncestor() else { return }
        anchorIdentities = currentAnchorIdentities(root)
        let desired = Dictionary(uniqueKeysWithValues: Set([root, directory]).compactMap { url -> (URL, SavedLayoutFileStamp)? in
            guard let stamp = SavedLayoutFileStamp(url), stamp.isDirectory else { return nil }
            return (url, stamp)
        })
        for (url, observation) in observations where desired[url]?.identity != observation.identity {
            observation.cancel(); observations[url] = nil
        }
        for (url, stamp) in desired.sorted(by: { $0.key.path < $1.key.path }) where observations[url] == nil {
            let descriptor: Int32
            do { descriptor = try openFile(url) }
            catch { if (error as? POSIXError)?.code == .ENOENT { continue }; throw error }
            let observation = SavedLayoutFileObservation(descriptor: descriptor, identity: stamp.identity)
            let token = observation.token
            let notify: @Sendable () -> Void = { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.observations[url]?.token == token else { return }
                    if url == root, self.survivingAncestor() == root,
                       self.currentAnchorIdentities(root) == self.anchorIdentities { return }
                    self.changed?()
                }
            }
            observation.source.setEventHandler(handler: notify)
            observation.source.setRegistrationHandler(handler: notify)
            observations[url] = observation
            observation.source.resume()
        }
        // Missing parents have no child-file edits to observe. Follow their creation with vnode
        // roots instead of starting a recursive stream over unrelated Application Support folders.
        guard SavedLayoutFileStamp(actionsURL.deletingLastPathComponent())?.isDirectory == true,
              let rootIdentity = SavedLayoutFileStamp(root)?.identity else {
            events.stop(); eventRoot = nil; eventToken = UUID(); hasUnwatchedFiles = false
            return
        }
        if eventRoot?.0 != root || eventRoot?.1 != rootIdentity {
            eventToken = UUID()
            let token = eventToken
            events.stop(); eventRoot = nil
            do {
                try events.start(root: root) { [weak self] paths, rescan in
                    guard let self, self.eventToken == token else { return }
                    if rescan { self.eventRoot = nil }
                    if rescan || self.currentAnchorIdentities(root) != self.anchorIdentities
                        || paths.contains(where: self.includesFileEvent) { self.changed?() }
                }
                eventRoot = (root, rootIdentity)
                hasUnwatchedFiles = false
                // A registration-time rescan closes the gap between the catalog baseline and stream start.
                changed?()
            } catch { events.stop(); hasUnwatchedFiles = true }
        }
    }

    func stop() {
        changed = nil; directory = nil; actionsURL = nil
        anchorIdentities = [:]; hasUnwatchedFiles = false
        eventRoot = nil; eventToken = UUID(); events.stop()
        for observation in observations.values { observation.cancel() }
        observations.removeAll()
    }

    isolated deinit {
        events.stop()
        for observation in observations.values { observation.cancel() }
    }
}
