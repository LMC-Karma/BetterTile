// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 LMC-Karma

import BetterTileCore
import Foundation
import Observation

struct SavedLayoutPane: Identifiable {
    let path: [Int]
    let node: SavedLayoutNode
    let rect: NormalizedRect
    var id: String { path.map(String.init).joined(separator: ".") }
}

/// Canvas projection only; sizes are relative to a 1200 × 750 preview work area.
enum SavedLayoutCanvasGeometry {
    static func panes(_ document: SavedLayoutDocument) -> [SavedLayoutPane] {
        guard let root = document.layout else { return [] }
        return SavedLayoutCanvas.leaves(root, paneGap: document.paneGap).map { .init(path: $0.path, node: $0.node, rect: $0.rect) }
    }

    static func replacing(_ node: SavedLayoutNode, at path: [Int], with replacement: SavedLayoutNode) -> SavedLayoutNode {
        SavedLayoutCanvas.replacing(node, at: path, with: replacement)
    }

    static func normalized(_ node: SavedLayoutNode) -> SavedLayoutNode { SavedLayoutCanvas.normalized(node) }

    static func slotIDs(in node: SavedLayoutNode, document: SavedLayoutDocument) -> [String] {
        SavedLayoutCanvas.slotIDs(in: node, document: document)
    }
}

struct SavedLayoutStatus: Equatable {
    enum Kind { case info, good, bad }
    var text: String
    var kind: Kind
}

struct SavedLayoutHistoryEntry {
    var document: SavedLayoutDocument
    var label: String
}

struct SavedLayoutDividerAddress: Hashable {
    var path: [Int]
    var index: Int
}

/// One divider drag. The document stays untouched until `commitResize`.
struct SavedLayoutResize {
    var address: SavedLayoutDividerAddress
    var base: SavedLayoutDocument
    var working: SavedLayoutDocument
}

@MainActor @Observable final class SavedLayoutEditor {
    let files: SavedLayoutFiles
    var positions: SavedLayoutPositions { .init(files: files) }
    var positionContext: SavedLayoutPositionContext? {
        url.map { .init(file: $0.lastPathComponent, store: positions) }
    }
    let creation = SavedLayoutCreation()
    private(set) var draft = SavedLayoutDraft()
    private(set) var url: URL?
    private(set) var sourceURL: URL?
    private(set) var baseline: Data?
    private(set) var entries: [URL] = []
    private(set) var entryNames: [URL: String] = [:]
    /// The decoded library files, for the layout cards. Unreadable files are missing here.
    private(set) var entryDocuments: [URL: SavedLayoutDocument] = [:]
    private(set) var entryProblems: [URL: String] = [:]
    private var entryBytes: [URL: Data] = [:]
    private(set) var libraryError: String?
    private(set) var rejectedSource: Data?
    private(set) var rejectedURL: URL?
    private var rejectedWasImported = false
    private var protectedSourceURLs: Set<URL> = []
    /// Page and name-sheet feedback. The kind affects presentation only.
    private(set) var messageStatus: SavedLayoutStatus?
    var message: String? {
        get { messageStatus?.text }
        set { messageStatus = newValue.map { .init(text: $0, kind: .info) } }
    }
    func reportFailure(_ text: String) { messageStatus = .init(text: text, kind: .bad) }
    var selectedPane: String?
    var selectedRectangle: String?
    /// Feedback for the canvas status line, including individual canvas edits.
    private(set) var canvasStatus: SavedLayoutStatus?
    private(set) var undoStack: [SavedLayoutHistoryEntry] = []
    private(set) var redoStack: [SavedLayoutHistoryEntry] = []
    /// Bundle IDs offered in the canvas app palette. An app stays here after its pane is cleared.
    private(set) var paletteApps: [String] = []
    private(set) var resize: SavedLayoutResize?
    /// A new, unnamed layout is named after its shape until the first rename.
    private var nameFollowsShape = false
    private var lastNudge: (key: String, time: TimeInterval)?
    @ObservationIgnored var clock: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    var document: SavedLayoutDocument? { draft.lastKnownGood }
    var selectedLibraryURL: URL? {
        url ?? (document == nil ? rejectedURL.flatMap { files.owns($0) ? $0 : nil } : nil)
    }
    /// The document with a divider drag applied, for drawing only.
    var displayDocument: SavedLayoutDocument? { resize?.working ?? document }
    var canUndo: Bool { !undoStack.isEmpty && !hasInvalidSource && resize == nil }
    var canRedo: Bool { !redoStack.isEmpty && !hasInvalidSource && resize == nil }
    var selectedPath: [Int]? {
        selectedPane.map { $0.isEmpty ? [] : $0.split(separator: ".").compactMap { Int($0) } }
    }
    var hasInvalidSource: Bool { !draft.issues.isEmpty }
    var isDirty: Bool { document != nil && draft.source != baseline }
    var hasUnsavedChanges: Bool { isDirty || hasInvalidSource }
    var pendingImport: SavedLayoutImport?
    @ObservationIgnored var fileOpener = SavedLayoutFileOpener()

    /// Ends the sheets and alerts this editor drives, as their Cancel buttons do.
    /// The draft and its history stay.
    func cancelPresentations() {
        creation.cancelSetup()
        creation.keepEditing()
        creation.updateToConfirm = nil
        pendingImport = nil
    }

    @discardableResult func reloadFromDisk() -> Bool {
        guard let source = url ?? sourceURL else { return false }
        return reload(source)
    }

    @discardableResult func discardChanges() -> Bool {
        if let url { return load(url) }
        clearDraft(); return true
    }

    func editInTextEditor() { if let source = url ?? sourceURL { fileOpener.edit(source) } }
    func revealInFinder() { if let source = url ?? sourceURL { fileOpener.reveal(source) } }

    @discardableResult func beginImport(_ source: URL, groups: AppGroupsStore?) -> Bool {
        do {
            let transfer = try SavedLayoutTransfer.decode(files.read(source))
            let request = SavedLayoutImport(source: source, transfer: transfer, groups: groups?.document ?? .init())
            if request.missing.isEmpty {
                if transfer.document.slots.flatMap(\.prefer).contains(where: { if case .group = $0 { true } else { false } }), let groups {
                    guard groups.error == nil, try !groups.hasExternalChange() else {
                        throw SavedLayoutFileError(message: "Reload a valid App Groups file before importing. Nothing was changed.")
                    }
                }
                acceptImport(transfer.document, source: source); return true
            }
            pendingImport = request
            return false
        } catch { reportFailure("Couldn’t import: \(error.localizedDescription) Your draft and source were kept."); return false }
    }

    @discardableResult func completeImport(groups: AppGroupsStore?) -> Bool {
        guard let request = pendingImport, let groups else { return false }
        do {
            guard groups.error == nil else { throw SavedLayoutFileError(message: "Reload a valid App Groups file before importing. Nothing was changed.") }
            let (document, updatedGroups) = try request.resolved(using: groups.document)
            // Validate every byte before the store writes. A refusal keeps the draft and library.
            let bytes = try SavedLayoutValidator.encode(document)
            if updatedGroups != groups.document { try groups.save(updatedGroups) }
            else if try groups.hasExternalChange() {
                throw SavedLayoutFileError(message: "App Groups changed outside BetterTile. Reload and try importing again.")
            }
            acceptImport(document, source: request.source, bytes: bytes)
            pendingImport = nil
            return true
        } catch { reportFailure("Couldn’t import: \(error.localizedDescription) Your draft and library were kept."); return false }
    }

    private func acceptImport(_ document: SavedLayoutDocument, source: URL, bytes: Data? = nil) {
        let bytes = bytes ?? (try! SavedLayoutValidator.encode(document))
        protectedSourceURLs.insert(source.resolvingSymlinksInPath())
        draft = SavedLayoutDraft(); draft.update(bytes)
        url = nil; sourceURL = source; baseline = nil
        selectedPane = nil; selectedRectangle = nil; rejectedURL = nil; rejectedSource = nil
        resetHistory()
        message = "Imported a draft. Save As to add a copy to your library; the original stays unchanged."
    }


    init(files: SavedLayoutFiles = .standard) { self.files = files }

    func refreshLibrary() {
        do {
            entries = try files.entries()
            var names: [URL: String] = [:], documents: [URL: SavedLayoutDocument] = [:], bytes: [URL: Data] = [:]
            var problems: [URL: String] = [:]
            for url in entries {
                do {
                    let data = try files.read(url)
                    bytes[url] = data
                    let decoded = try SavedLayoutValidator.decode(data)
                    names[url] = decoded.name; documents[url] = decoded
                } catch {
                    names[url] = url.lastPathComponent + " · unreadable"
                    problems[url] = (error as? SavedLayoutValidationError)?.issues.first?.message ?? error.localizedDescription
                }
            }
            // Valid layouts sort by their displayed names. Unreadable files follow, ordered by path.
            entries.sort { lhs, rhs in
                let left = documents[lhs], right = documents[rhs]
                if (left == nil) != (right == nil) { return left != nil }
                let order = (left?.name ?? lhs.lastPathComponent).localizedStandardCompare(right?.name ?? rhs.lastPathComponent)
                return order == .orderedSame ? lhs.path < rhs.path : order == .orderedAscending
            }
            entryNames = names
            entryDocuments = documents
            entryProblems = problems
            entryBytes = bytes
            libraryError = nil
        }
        catch { libraryError = "Couldn’t list Saved Layouts: \(error.localizedDescription) Check folder access, then reload the library." }
    }

    func returnToLastValid() {
        guard let document else { return }
        draft.update(try! SavedLayoutValidator.encode(document))
        message = "Showing the last valid layout. The rejected source file is unchanged."
        resize = nil
    }

    func newLayout(mode: LayoutMode = .bento) {
        let slot = SavedLayoutCanvas.defaultID("slot")
        let group = SavedLayoutCanvas.defaultID("group")
        let value = SavedLayoutDocument(name: "Untitled Layout", mode: mode,
            layout: mode == .manual ? nil : mode == .tabbed ? .group(group) : .slot(slot),
            slots: [.init(id: slot)],
            groups: mode == .tabbed ? [.init(id: group, slots: [slot], selected: slot)] : [],
            windows: mode == .manual ? [.init(slot: slot, rect: .init(x: 0.1, y: 0.1, width: 0.6, height: 0.65))] : [])
        draft = SavedLayoutDraft()
        draft.update(try! SavedLayoutValidator.encode(value))
        url = nil; sourceURL = nil; baseline = nil; selectedPane = nil; selectedRectangle = nil; message = nil
        resetHistory(); nameFollowsShape = true
    }

    /// Discard an unsaved creation when there was no library selection to return to.
    func clearDraft() {
        draft = SavedLayoutDraft()
        url = nil; sourceURL = nil; baseline = nil; selectedPane = nil; selectedRectangle = nil
        rejectedSource = nil; rejectedURL = nil; message = nil
        resetHistory()
    }

    func resetHistory() {
        undoStack = []; redoStack = []; lastNudge = nil; resize = nil; canvasStatus = nil; nameFollowsShape = false
        paletteApps = []
        noteApps(in: document)
    }

    private func noteApps(in document: SavedLayoutDocument?) {
        let apps: [String] = document?.slots.flatMap { slot in
            slot.prefer.compactMap { preference in if case let .app(id) = preference { id } else { nil } }
        } ?? []
        for id in apps where !paletteApps.contains(id) { paletteApps.append(id) }
    }

    @discardableResult func reload(_ source: URL) -> Bool {
        load(source, importing: source == rejectedURL ? rejectedWasImported : url == nil)
    }

    /// A failed import/reload retains both the exact submitted bytes and the last valid model.
    @discardableResult func load(_ source: URL, importing: Bool = false) -> Bool {
        let isImport = importing || !files.owns(source)
        do {
            if isImport {
                protectedSourceURLs.insert(source.resolvingSymlinksInPath())
            }
            let bytes = try files.read(source)
            guard draft.update(bytes) else {
                rejectedSource = bytes; rejectedURL = source; rejectedWasImported = isImport
                protectedSourceURLs.insert(source.resolvingSymlinksInPath())
                reportFailure("Couldn’t read \(source.lastPathComponent). \(draft.issues.map { "\($0.path): \($0.message)" }.joined(separator: " ")) The file and last valid layout were kept. Fix the source and reload, or open another file.")
                return false
            }
            if rejectedURL == source { rejectedURL = nil }
            url = isImport ? nil : source
            sourceURL = source
            baseline = isImport ? nil : bytes
            selectedPane = nil; selectedRectangle = nil
            resetHistory()
            message = isImport ? "Imported a draft. Save As to add a copy to your library; the original stays unchanged." : nil
            return true
        } catch {
            rejectedURL = source; rejectedWasImported = isImport
            reportFailure("Couldn’t read \(source.lastPathComponent): \(error.localizedDescription) The draft and source were kept. Check the file and retry.")
            return false
        }
    }

    @discardableResult func edit(label: String = "Edit layout", coalescing key: String? = nil,
                                 _ change: (inout SavedLayoutDocument) throws -> Void) -> Bool {
        guard !hasInvalidSource, let original = document else { return false }
        var value = original
        do {
            try change(&value)
            if value.name != original.name { nameFollowsShape = false }
            else if nameFollowsShape, value.layout != original.layout, let layout = value.layout {
                value.name = SavedLayoutCanvas.shape(layout).name
            }
            let bytes = try SavedLayoutValidator.encode(value)
            if bytes != draft.source { record(original, label: label, key: key) }
            draft.update(bytes)
            noteApps(in: value)
            message = nil
            return true
        } catch {
            reportFailure("Couldn’t change the layout: \(error.localizedDescription) The last valid layout was kept.")
            canvasStatus = .init(text: error.localizedDescription, kind: .bad)
            return false
        }
    }

    /// One history entry per edit. Edits that share a key within 1.2 s (keyboard nudges) share an entry.
    private func record(_ original: SavedLayoutDocument, label: String, key: String?) {
        let now = clock()
        if let key, let last = lastNudge, last.key == key, now - last.time < SavedLayoutCanvas.nudgeCoalescingInterval {
            lastNudge = (key, now); return
        }
        undoStack.append(.init(document: original, label: label))
        if undoStack.count > SavedLayoutCanvas.history { undoStack.removeFirst() }
        redoStack = []
        lastNudge = key.map { ($0, now) }
    }

    private func restore(_ snapshot: SavedLayoutDocument) -> Bool {
        guard let bytes = try? SavedLayoutValidator.encode(snapshot), draft.update(bytes) else { return false }
        if let path = selectedPath, snapshot.layout.map({ SavedLayoutCanvas.leaves($0).contains { $0.path == path } }) != true {
            selectedPane = nil
        }
        lastNudge = nil
        noteApps(in: snapshot)
        return true
    }

    func undo() {
        guard canUndo, let current = document, let entry = undoStack.popLast() else {
            canvasStatus = .init(text: "Nothing to undo.", kind: .info); return
        }
        guard restore(entry.document) else { undoStack.append(entry); return }
        redoStack.append(.init(document: current, label: entry.label))
        canvasStatus = .init(text: "Undid: \(entry.label.lowercased()).", kind: .info)
    }

    func redo() {
        guard canRedo, let current = document, let entry = redoStack.popLast() else {
            canvasStatus = .init(text: "Nothing to redo.", kind: .info); return
        }
        guard restore(entry.document) else { redoStack.append(entry); return }
        undoStack.append(.init(document: current, label: entry.label))
        canvasStatus = .init(text: "Redid: \(entry.label.lowercased()).", kind: .info)
    }

    func say(_ text: String, _ kind: SavedLayoutStatus.Kind = .info) { canvasStatus = .init(text: text, kind: kind) }

    func select(path: [Int]?) {
        selectedPane = path.map(SavedLayoutCanvas.identifier); selectedRectangle = nil
    }

    /// Commits one canvas edit as one history entry and reports the result.
    @discardableResult func apply(_ outcome: SavedLayoutOutcome, label: String) -> Bool {
        switch outcome {
        case let .change(change):
            guard edit(label: label, { $0 = change.document }) else { return false }
            select(path: change.selection)
            say(change.summary, .good)
            return true
        case let .unchanged(text):
            say(text); return false
        case let .rejected(reason):
            reportFailure(reason); say(reason, .bad); return false
        }
    }

    @discardableResult func save(as name: String? = nil) -> Bool {
        guard !hasInvalidSource, var value = document else { return false }
        do {
            if let name { value.name = name }
            let bytes = try SavedLayoutValidator.encode(value)
            let destination: URL
            if name == nil, let url, let baseline { try files.save(bytes, to: url, expected: baseline); destination = url }
            else { destination = try files.create(bytes) }
            // Commit the saved name and baseline only after the write succeeds.
            draft.update(bytes); url = destination; sourceURL = destination; baseline = bytes
            if name != nil { nameFollowsShape = false }
            message = "Saved locally. No windows were changed."
            refreshLibrary()
            return true
        } catch {
            reportFailure("Couldn’t save: \(error.localizedDescription) Your draft was kept. Check folder access, retry, or Save As.")
            return false
        }
    }

    /// Replaces the arrangement after validation and a coordinated byte check; failures keep the draft.
    @discardableResult func updateFromCurrentDesktop(_ captured: SavedLayoutDocument, libraryURL: URL? = nil) -> Bool {
        let destination = libraryURL ?? url
        let expected = libraryURL.flatMap { entryBytes[$0] } ?? (libraryURL == nil ? baseline : nil)
        guard let url = destination, let baseline = expected, libraryURL != nil || !hasInvalidSource else { return false }
        do {
            let original = try SavedLayoutValidator.decode(baseline)
            let current = try files.read(url)
            guard current == baseline else {
                throw SavedLayoutFileError(message: "This file changed outside BetterTile. Reload to inspect it, or Save As to keep your draft in a new file. Nothing was overwritten.")
            }
            _ = try SavedLayoutValidator.decode(current)
            let replacement = try SavedLayoutUpdateMapping.updating(original, from: captured)
            let bytes = try SavedLayoutValidator.encode(replacement)
            try files.save(bytes, to: url, expected: baseline)
            let retained = Set(original.slots.filter { replacement.slots.contains($0) }.map(\.id))
            positions.retain(retained, for: url.lastPathComponent)
            draft.update(bytes); self.url = url; self.baseline = bytes; sourceURL = url
            selectedPane = nil; selectedRectangle = nil
            resetHistory(); refreshLibrary()
            message = "Updated from the current desktop. No windows were changed."
            return true
        } catch {
            reportFailure("Couldn’t update: \(error.localizedDescription) Your draft was kept.")
            return false
        }
    }

    @discardableResult func delete() -> Bool {
        guard !hasInvalidSource, let url, let baseline else { return false }
        do {
            let index = entries.firstIndex(of: url) ?? 0
            try files.delete(url, expected: baseline)
            positions.remove(url.lastPathComponent)
            clearDraft()
            refreshLibrary()
            if !entries.isEmpty { load(entries[min(index, entries.count - 1)]) }
            message = "Deleted the library file. Exported and imported originals were kept."
            return true
        } catch { reportFailure("Couldn’t delete: \(error.localizedDescription) The draft was kept."); return false }
    }

    func export(to destination: URL, groups: AppGroupsDocument = .init()) {
        guard !hasInvalidSource, let document else { return }
        do {
            guard !files.owns(destination), !protectedSourceURLs.contains(destination.resolvingSymlinksInPath()),
                  destination.resolvingSymlinksInPath() != sourceURL?.resolvingSymlinksInPath(),
                  destination.resolvingSymlinksInPath() != rejectedURL?.resolvingSymlinksInPath(),
                  destination.resolvingSymlinksInPath() != url?.resolvingSymlinksInPath() else {
                throw SavedLayoutFileError(message: "Use Save for the library file. Choose another export destination to preserve the source.")
            }
            let bytes = try SavedLayoutTransfer.encode(document, groups: groups)
            if FileManager.default.fileExists(atPath: destination.path) { _ = try files.read(destination) }
            try bytes.write(to: destination, options: [.atomic, .completeFileProtectionUnlessOpen])
            message = "Exported the draft. The library and imported original were kept."
        } catch { reportFailure("Couldn’t export: \(error.localizedDescription) Choose another destination and retry. The draft was kept.") }
    }

    func assign(bundleID: String, pane: SavedLayoutPane?, replacing slotID: String? = nil, floating: Bool = false) {
        edit { value in
            var target = slotID
            if target == nil, value.mode == .bento, case let .slot(existing)? = pane?.node { target = existing }
            if target == nil, !floating {
                let candidates = value.mode == .manual ? value.windows.map(\.slot)
                    : pane.map { SavedLayoutCanvas.slotIDs(in: $0.node, document: value) } ?? []
                if value.mode == .manual || candidates.count == 1 {
                    target = candidates.first { id in value.slots.contains { $0.id == id && $0.prefer.isEmpty } }
                }
            }
            if let target, let index = value.slots.firstIndex(where: { $0.id == target }) {
                value.slots[index].prefer = [.app(bundleID)]; return
            }
            let slotID = "slot-" + UUID().uuidString.lowercased()
            value.slots.append(.init(id: slotID, prefer: [.app(bundleID)]))
            if floating || value.mode == .manual {
                let rectangle = SavedLayoutRectangle(slot: slotID, rect: .init(x: 0.1, y: 0.1, width: 0.6, height: 0.65))
                if floating { value.floats.append(rectangle) } else { value.windows.append(rectangle) }
            } else if let pane, let root = value.layout {
                if case let .group(groupID) = pane.node, let index = value.groups.firstIndex(where: { $0.id == groupID }) {
                    value.groups[index].slots.append(slotID)
                    value.groups[index].selected = slotID
                } else if value.mode == .tabbed {
                    let groupID = "group-" + UUID().uuidString.lowercased()
                    value.groups.append(.init(id: groupID, slots: [slotID], selected: slotID))
                    value.layout = SavedLayoutCanvasGeometry.replacing(root, at: pane.path, with: .group(groupID))
                } else {
                    guard case .empty = pane.node else { throw SavedLayoutFileError(message: "Replace the app in this pane, or split it before adding another app.") }
                    value.layout = SavedLayoutCanvasGeometry.replacing(root, at: pane.path, with: .slot(slotID))
                }
            } else { throw SavedLayoutFileError(message: "Select a pane before assigning an app.") }
        }
    }

    func removeSlot(_ id: String) {
        removeApps([id])
    }

    /// Shared by slot removal, pane clearing and pane-to-palette drops.
    @discardableResult private func removeApps(_ ids: [String]) -> Bool {
        guard let document else { return false }
        return apply(SavedLayoutCanvas.removingApps(ids, from: document), label: "Remove app preferences")
    }

    func split(_ pane: SavedLayoutPane, axis: SplitAxis) {
        guard let document else { return }
        apply(SavedLayoutCanvas.splitting(pane.path, axis: axis, in: document), label: axis == .vertical ? "Split columns" : "Split rows")
    }

    /// Removes the pane with its app or tabs. Undo restores both.
    func removePane(_ pane: SavedLayoutPane) {
        guard let document else { return }
        apply(SavedLayoutCanvas.removingPane(pane.path, from: document), label: "Remove pane")
    }
}

extension SavedLayoutEditor {
    func setMode(_ mode: LayoutMode) {
        edit { value in
            guard value.mode != mode else { return }
            let old = value
            let tiled = old.mode == .manual ? old.windows.map(\.slot)
                : old.layout.map { SavedLayoutCanvasGeometry.slotIDs(in: $0, document: old) } ?? []
            if mode == .manual {
                value.windows = SavedLayoutCanvasGeometry.panes(old).flatMap { pane in
                    SavedLayoutCanvasGeometry.slotIDs(in: pane.node, document: old).map { .init(slot: $0, rect: pane.rect) }
                }
                value.layout = nil; value.groups = []
            } else {
                value.windows = []; value.groups = []
                var leaves: [SavedLayoutNode] = []
                for id in tiled {
                    if mode == .tabbed {
                        let group = SavedLayoutGroup(id: "group-" + id, slots: [id], selected: id)
                        value.groups.append(group); leaves.append(.group(group.id))
                    } else { leaves.append(.slot(id)) }
                }
                value.layout = leaves.isEmpty ? .empty : leaves.count == 1 ? leaves[0]
                    : .split(axis: .vertical, ratios: Array(repeating: 1 / Double(leaves.count), count: leaves.count), children: leaves)
            }
            value.mode = mode
            if mode != .bento { value.extraWindows = .float }
        }
        selectedPane = nil; selectedRectangle = nil
    }

    func setPreset(_ preset: TabbedPreset) {
        guard let document else { return }
        apply(SavedLayoutCanvas.applyingPreset(preset, to: document), label: "Preset \(preset.title)")
    }

    /// Sets one child's share of a split. Core clamps it so every pane keeps the minimum size and
    /// the other children keep their relative proportions. A non-finite share changes nothing.
    func setRatio(path: [Int], child: Int, ratio: Double) {
        guard ratio.isFinite, let root = document?.layout else { return }
        edit(label: "Change proportions", coalescing: "ratio-\(SavedLayoutCanvas.identifier(path))-\(child)") { value in
            value.layout = try SavedLayoutCanvas.settingShare(in: root, path: path, child: child, to: ratio,
                                                               paneGap: value.paneGap)
        }
    }

    func selectTab(_ slot: String, group: String) {
        edit { value in
            guard let index = value.groups.firstIndex(where: { $0.id == group }) else { return }
            value.groups[index].selected = slot
        }
    }

    func moveTab(_ slot: String, group: String, offset: Int) {
        edit { value in
            guard let groupIndex = value.groups.firstIndex(where: { $0.id == group }),
                  let index = value.groups[groupIndex].slots.firstIndex(of: slot),
                  value.groups[groupIndex].slots.indices.contains(index + offset) else { return }
            value.groups[groupIndex].slots.swapAt(index, index + offset)
        }
    }

    func setRectangle(_ id: String, rect: NormalizedRect) {
        edit { value in
            if let index = value.windows.firstIndex(where: { $0.slot == id }) { value.windows[index].rect = rect }
            if let index = value.floats.firstIndex(where: { $0.slot == id }) { value.floats[index].rect = rect }
        }
    }
}

extension SavedLayoutEditor {
    func moveSlot(_ id: String, to target: SavedLayoutPane?) {
        edit { value in
            guard value.slots.contains(where: { $0.id == id }) else { return }
            if let target, SavedLayoutCanvasGeometry.slotIDs(in: target.node, document: value).contains(id) { return }
            if let target, case let .slot(slot) = target.node,
               value.slots.first(where: { $0.id == slot })?.prefer.isEmpty != true {
                throw SavedLayoutFileError(message: "Choose an empty pane. Adaptive keeps one app slot per pane.")
            }
            let oldRectangle = (value.windows + value.floats).first { $0.slot == id }?.rect
                ?? SavedLayoutCanvasGeometry.panes(value).first { SavedLayoutCanvasGeometry.slotIDs(in: $0.node, document: value).contains(id) }?.rect
                ?? .init(x: 0.1, y: 0.1, width: 0.6, height: 0.65)
            Self.detachSlot(id, from: &value)
            if let target, let root = value.layout {
                if case let .group(groupID) = target.node, let index = value.groups.firstIndex(where: { $0.id == groupID }) {
                    if value.groups[index].slots.count == 1, let placeholder = value.groups[index].slots.first,
                       value.slots.first(where: { $0.id == placeholder })?.prefer.isEmpty == true {
                        value.slots.removeAll { $0.id == placeholder }
                        value.groups[index].slots = []
                    }
                    value.groups[index].slots.append(id); value.groups[index].selected = id
                } else if value.mode == .tabbed {
                    let groupID = "group-" + UUID().uuidString.lowercased()
                    value.groups.append(.init(id: groupID, slots: [id], selected: id))
                    value.layout = SavedLayoutCanvasGeometry.replacing(root, at: target.path, with: .group(groupID))
                } else {
                    if case let .slot(placeholder) = target.node { value.slots.removeAll { $0.id == placeholder } }
                    value.layout = SavedLayoutCanvasGeometry.replacing(root, at: target.path, with: .slot(id))
                }
            } else { value.floats.append(.init(slot: id, rect: oldRectangle)) }
        }
    }
}


extension SavedLayoutEditor {
    private static func detachSlot(_ id: String, from value: inout SavedLayoutDocument) {
        func clear(_ node: SavedLayoutNode) -> SavedLayoutNode {
            if case let .slot(slot) = node, slot == id {
                let placeholder = SavedLayoutCanvas.defaultID("slot")
                value.slots.append(.init(id: placeholder))
                return .slot(placeholder)
            }
            if case let .split(axis, ratios, children) = node { return .split(axis: axis, ratios: ratios, children: children.map(clear)) }
            return node
        }
        value.layout = value.layout.map(clear)
        value.windows.removeAll { $0.slot == id }; value.floats.removeAll { $0.slot == id }
        for index in value.groups.indices {
            guard value.groups[index].slots.contains(id) else { continue }
            value.groups[index].slots.removeAll { $0 == id }
            if value.groups[index].slots.isEmpty {
                let placeholder = SavedLayoutCanvas.defaultID("slot")
                value.slots.append(.init(id: placeholder))
                value.groups[index].slots = [placeholder]
            }
            if value.groups[index].selected == id { value.groups[index].selected = value.groups[index].slots.first }
        }
    }

    func returnToManualWindow(_ id: String) {
        edit { value in
            guard value.mode == .manual, let rectangle = value.floats.first(where: { $0.slot == id }) else { return }
            value.floats.removeAll { $0.slot == id }
            value.windows.append(rectangle)
        }
    }
}

// MARK: Canvas transactions

extension SavedLayoutEditor {
    func divider(_ address: SavedLayoutDividerAddress, in document: SavedLayoutDocument? = nil) -> SavedLayoutDivider? {
        guard let document = document ?? displayDocument, let root = document.layout else { return nil }
        return SavedLayoutCanvas.dividers(root, paneGap: document.paneGap).first { $0.path == address.path && $0.index == address.index }
    }

    /// "63% | 37%": the two neighbors' shares of their split.
    static func sharesText(_ divider: SavedLayoutDivider) -> String {
        "\(percent(divider.firstShare)) | \(percent(divider.secondShare))"
    }

    static func percent(_ fraction: Double) -> String {
        let value = (fraction * 1000).rounded() / 10
        return (value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)) + "%"
    }

    /// Starts a divider drag. Nothing is encoded or recorded until `commitResize`.
    @discardableResult func beginResize(_ address: SavedLayoutDividerAddress) -> Bool {
        guard resize == nil, !hasInvalidSource, let document, document.mode != .manual, divider(address, in: document) != nil else { return false }
        resize = .init(address: address, base: document, working: document)
        return true
    }

    /// Moves the working copy to `share`. It always starts from the layout at the drag's start, so no error builds up.
    @discardableResult func updateResize(share: Double) -> SavedLayoutDivider? {
        guard var session = resize, let root = session.base.layout else { return nil }
        if let moved = try? SavedLayoutCanvas.movingDivider(in: root, path: session.address.path, index: session.address.index,
                                                           to: share, paneGap: session.base.paneGap) {
            session.working.layout = moved
            resize = session
        }
        return divider(session.address, in: session.working)
    }

    /// Ends the drag with one edit, or none when the divider did not move.
    @discardableResult func commitResize() -> Bool {
        guard let session = resize else { return false }
        resize = nil
        guard session.working.layout != session.base.layout, let layout = session.working.layout else { return false }
        let committed = edit(label: "Resize divider") { $0.layout = layout }
        if committed, let divider = divider(session.address) { say(Self.sharesText(divider), .good) }
        return committed
    }

    func cancelResize(announce: Bool = true) {
        guard resize != nil else { return }
        resize = nil
        if announce { say("Resize cancelled.") }
    }

    @discardableResult func equalize(_ address: SavedLayoutDividerAddress) -> Bool {
        guard let document, let root = document.layout, let divider = divider(address, in: document) else { return false }
        guard let layout = try? SavedLayoutCanvas.equalizingDivider(in: root, path: address.path, index: address.index, paneGap: document.paneGap) else { return false }
        if layout == root { say("These two panes are already equal."); return false }
        guard edit(label: "Equalize panes", { $0.layout = layout }) else { return false }
        say("Equalized: \(Self.percent(divider.pair / 2)) each.", .good)
        return true
    }

    /// A keyboard step on one divider. Steps on the same divider within 1.2 s share one history entry.
    @discardableResult func nudge(_ address: SavedLayoutDividerAddress, by delta: Double, to limit: Double? = nil) -> Bool {
        guard let document, let root = document.layout, let divider = divider(address, in: document) else { return false }
        let target = limit ?? divider.current + delta
        guard let layout = try? SavedLayoutCanvas.movingDivider(in: root, path: address.path, index: address.index,
                                                               to: target, paneGap: document.paneGap) else { return false }
        if layout == root { say("Minimum pane size reached."); return false }
        guard edit(label: "Resize divider", coalescing: "nudge:\(divider.id)", { $0.layout = layout }) else { return false }
        if let moved = self.divider(address) { say(Self.sharesText(moved), .good) }
        return true
    }

    /// Names for the plan and status text, taken from the app names the view resolved.
    func plan(_ item: SavedLayoutDragItem, onto target: SavedLayoutDropTarget, names: (String) -> String) -> SavedLayoutDropPlan? {
        guard let document = displayDocument else { return nil }
        return SavedLayoutCanvas.plan(item, onto: target, in: document, names: names)
    }

    @discardableResult func drop(_ item: SavedLayoutDragItem, onto target: SavedLayoutDropTarget, names: (String) -> String) -> Bool {
        guard let plan = plan(item, onto: target, names: names) else { return false }
        if case .palette = target, case let .pane(path) = item, case .change = plan.outcome,
           let document, let root = document.layout, let node = SavedLayoutCanvas.node(at: path, in: root) {
            return removeApps(SavedLayoutCanvas.slotIDs(in: node, document: document))
        }
        return apply(plan.outcome, label: plan.label)
    }

    /// Exchanges two panes' apps, or moves one into an empty pane.
    @discardableResult func swap(_ source: [Int], _ destination: [Int], names: (String) -> String) -> Bool {
        drop(.pane(source), onto: .pane(destination), names: names)
    }
}


extension SavedLayoutEditor {
    @discardableResult func addPreference(_ preference: AppPreference, to slotID: String) -> Bool {
        edit(label: "Add preference") { value in
            guard let index = value.slots.firstIndex(where: { $0.id == slotID }),
                  !value.slots[index].prefer.contains(preference) else { return }
            value.slots[index].prefer.append(preference)
        }
    }

    @discardableResult func removePreference(at index: Int, from slotID: String) -> Bool {
        edit(label: "Remove preference") { value in
            guard let slot = value.slots.firstIndex(where: { $0.id == slotID }),
                  value.slots[slot].prefer.indices.contains(index) else { return }
            value.slots[slot].prefer.remove(at: index)
        }
    }

    @discardableResult func movePreference(in slotID: String, from source: Int, to destination: Int) -> Bool {
        edit(label: "Reorder preferences") { value in
            guard let slot = value.slots.firstIndex(where: { $0.id == slotID }),
                  value.slots[slot].prefer.indices.contains(source),
                  value.slots[slot].prefer.indices.contains(destination), source != destination else { return }
            let preference = value.slots[slot].prefer.remove(at: source)
            value.slots[slot].prefer.insert(preference, at: destination)
        }
    }

    /// An empty pane becomes an any-window slot before its first preference is added.
    @discardableResult func preferenceSlot(in pane: SavedLayoutPane) -> String? {
        guard let document else { return nil }
        if let id = SavedLayoutCanvasGeometry.slotIDs(in: pane.node, document: document).first { return id }
        let id = "slot-" + UUID().uuidString.lowercased()
        guard edit(label: "Edit pane preferences", { value in
            guard let root = value.layout else { return }
            value.slots.append(.init(id: id))
            if value.mode == .tabbed {
                let group = "group-" + id
                value.groups.append(.init(id: group, slots: [id], selected: id))
                value.layout = SavedLayoutCanvasGeometry.replacing(root, at: pane.path, with: .group(group))
            } else { value.layout = SavedLayoutCanvasGeometry.replacing(root, at: pane.path, with: .slot(id)) }
        }) else { return nil }
        return id
    }
}
