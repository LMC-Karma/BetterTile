// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 LMC-Karma

import AppKit
import BetterTileCore
import SwiftUI
import UniformTypeIdentifiers

/// The Saved Layout editor supplies these operations when the page connects both sections.
struct AppGroupsEditorBridge {
    var hasUnsavedChanges: () -> Bool = { false }
    var save: () throws -> Void = {}
    var discard: () -> Void = {}
    var reload: () -> Void = {}
}

@MainActor struct AppGroupsFileActions {
    var edit: (URL) -> Void = { PlainTextFileEditor().edit($0) }
    var reveal: (URL) -> Void = { NSWorkspace.shared.activateFileViewerSelecting([$0]) }
}

@Observable @MainActor
final class AppGroupsSectionModel {
    let store: AppGroupsStore
    let editor: AppGroupsEditorBridge
    let didChange: () -> Void
    let fileActions: AppGroupsFileActions
    var selectedName: String?
    var message: String?
    var pendingRename: String?
    var renameFailures: [AppGroupsStore.RenameFailure] = []
    var lastRename: (String, String)?
    var revision = 0
    var pendingRemoval: String?
    private var layoutCounts: [String: Int] = [:]

    init(store: AppGroupsStore, editor: AppGroupsEditorBridge = .init(), fileActions: AppGroupsFileActions = .init(), didChange: @escaping () -> Void) {
        self.store = store; self.editor = editor; self.fileActions = fileActions; self.didChange = didChange
        selectedName = store.document.groups.first?.name
        updateLayoutCounts()
    }

    var selected: AppGroup? { store.document.groups.first { $0.name == selectedName } }
    func refresh(notify: Bool = true) {
        updateLayoutCounts()
        if !store.document.groups.contains(where: { $0.name == selectedName }) { selectedName = store.document.groups.first?.name }
        revision += 1
        if notify { didChange() }
    }
    func editFile() { if store.fileExists { fileActions.edit(store.fileURL) } }
    func revealFile() { if store.fileExists { fileActions.reveal(store.fileURL) } }
    func reload() async {
        await store.reload()
        if !store.document.groups.contains(where: { $0.name == selectedName }) { selectedName = store.document.groups.first?.name }
        refresh()
    }
    func perform(_ action: () throws -> Void) {
        do { try action(); message = nil; refresh() }
        catch {
            message = error.localizedDescription
            Task { await reload() }
        }
    }
    func save(_ document: AppGroupsDocument) { perform { try store.save(document) } }
    func keep(_ name: String) { perform { try store.keepSuggestion(name) } }
    func remove(_ name: String) {
        perform {
            if store.suggestedNames.contains(name) { try store.removeSuggestion(name) }
            else { var doc = store.document; doc.groups.removeAll { $0.name == name }; try store.save(doc) }
            selectedName = store.document.groups.first?.name
        }
    }
    func requestRemoval(_ name: String) {
        if layoutCount(for: name) > 0 { pendingRemoval = name } else { remove(name) }
    }
    func newGroup() {
        var doc = store.document; var name = "New Group"; var suffix = 2
        while doc.groups.contains(where: { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) {
            name = "New Group \(suffix)"; suffix += 1
        }
        doc.groups.append(AppGroup(name: name, apps: []))
        perform { try store.save(doc); selectedName = name }
    }
    func updateApps(_ change: (inout [AppGroupEntry]) -> Void) {
        guard let index = store.document.groups.firstIndex(where: { $0.name == selectedName }) else { return }
        var doc = store.document; change(&doc.groups[index].apps); save(doc)
    }
    func move(from: Int, to: Int) {
        updateApps { apps in
            guard apps.indices.contains(from), (0...apps.count).contains(to) else { return }
            let entry = apps.remove(at: from); apps.insert(entry, at: min(to > from ? to - 1 : to, apps.count))
        }
    }
    func choose(_ app: ApplicationChoice, at index: Int) {
        updateApps { apps in guard apps.indices.contains(index) else { return }; apps[index].bundleID = app.bundleIdentifier }
    }
    func displayName(_ entry: AppGroupEntry) -> String {
        let id = store.resolvedBundleIDs[entry] ?? entry.bundleID
        return store.applications.first { id != nil && $0.bundleIdentifier.caseInsensitiveCompare(id!) == .orderedSame }?.name
            ?? entry.name ?? "An app that is not installed"
    }
    func requestRename(_ name: String) {
        guard let old = selectedName, old != name else { return }
        if editor.hasUnsavedChanges() { pendingRename = name } else { rename(name) }
    }
    func resolvePendingRename(saveChanges: Bool) {
        guard let name = pendingRename else { return }; pendingRename = nil
        do {
            if saveChanges { try editor.save() } else { editor.discard() }
            rename(name)
        } catch { message = error.localizedDescription }
    }
    func rename(_ name: String) {
        guard let old = selectedName else { return }
        perform {
            renameFailures = try store.renameGroup(old, to: name)
            selectedName = name; lastRename = (old, name); editor.reload()
        }
    }
    func layoutCount(for name: String) -> Int { layoutCounts[name] ?? 0 }
    private func updateLayoutCounts() {
        var counts: [String: Int] = [:]
        for url in (try? store.layouts.entries()) ?? [] {
            guard let data = try? store.layouts.read(url), let layout = try? SavedLayoutValidator.decode(data) else { continue }
            for group in store.document.groups where layout.slots.contains(where: { slot in
                slot.prefer.contains { if case let .group(name) = $0 { return name.compare(group.name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }; return false }
            }) { counts[group.name, default: 0] += 1 }
        }
        layoutCounts = counts
    }
}

struct AppGroupsSection: View {
    @State private var model: AppGroupsSectionModel
    @State private var title = ""
    @State private var picker = false
    @State private var draggedIndex: Int?

    init(store: AppGroupsStore, editor: AppGroupsEditorBridge = .init(), fileActions: AppGroupsFileActions = .init(), didChange: @escaping () -> Void) {
        _model = State(initialValue: AppGroupsSectionModel(store: store, editor: editor, fileActions: fileActions, didChange: didChange))
    }

    init(model: AppGroupsSectionModel) {
        _model = State(initialValue: model)
    }

    var body: some View {
        let _ = model.revision
        VStack(alignment: .leading, spacing: SettingsSpacing.s2) {
            HStack {
                Text("App Groups").font(SettingsFont.headline)
                Text("A layout pane can prefer a whole group").font(SettingsFont.caption).foregroundStyle(.secondary)
                Spacer()
                Menu {
                    Button("Edit in Text Editor") { model.editFile() }.disabled(!model.store.fileExists)
                    Button("Reveal in Finder") { model.revealFile() }.disabled(!model.store.fileExists)
                    Button("Reload") { Task { await model.reload() } }
                } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).fixedSize()
            }
            if let error = model.store.error {
                Text("\(model.store.fileURL.path)\n\(error.localizedDescription)").font(SettingsFont.caption).foregroundStyle(SettingsColor.orange).textSelection(.enabled)
            }
            if let message = model.message { Text(message).font(SettingsFont.caption).foregroundStyle(SettingsColor.red).textSelection(.enabled) }
            if model.store.document.groups.isEmpty {
                VStack(spacing: 8) {
                    Text(model.store.fileExists ? "No App Groups" : "No suggested groups").font(SettingsFont.headline)
                    Text("Add a group and choose apps to use in your layouts.").font(SettingsFont.caption).foregroundStyle(.secondary)
                    Button("New Group", systemImage: "plus") { model.newGroup() }
                }.frame(maxWidth: .infinity).padding(24).disabled(!model.store.canSave)
                    .background(SettingsColor.group, in: .settings(SettingsRadius.panel))
            } else {
                HStack(spacing: 0) {
                    groupList.frame(width: 210)
                    Divider()
                    detail.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }.frame(height: 320).disabled(!model.store.canSave).background(SettingsColor.group, in: .settings(SettingsRadius.panel))
                    .overlay(RoundedRectangle.settings(SettingsRadius.panel).stroke(SettingsColor.groupBorder))
            }
        }
        .font(SettingsFont.body)
        .onAppear { title = model.selectedName ?? "" }
        .onChange(of: model.selectedName) { _, value in title = value ?? "" }
        .onChange(of: model.revision) { _, _ in if model.pendingRename == nil { title = model.selectedName ?? "" } }
        .sheet(isPresented: $picker) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Add App").font(.headline)
                ApplicationPicker(exclusions: Set(model.selected?.apps.compactMap(\.bundleID) ?? [])) { app in
                    model.updateApps { $0.append(AppGroupEntry(name: app.name, bundleID: app.bundleIdentifier)) }; picker = false
                }
                HStack { Spacer(); Button("Cancel") { picker = false }.keyboardShortcut(.cancelAction) }
            }.padding(20).frame(width: 430, height: 480)
        }
        .sheet(isPresented: Binding(get: { model.pendingRename != nil }, set: { if !$0 { model.pendingRename = nil } })) {
            AppGroupsRenameSheet(group: model.selectedName ?? "the group", save: { model.resolvePendingRename(saveChanges: true) }, discard: { model.resolvePendingRename(saveChanges: false) }, cancel: { model.pendingRename = nil; title = model.selectedName ?? "" })
        }
        .sheet(isPresented: Binding(get: { !model.renameFailures.isEmpty }, set: { if !$0 { model.renameFailures = [] } })) {
            AppGroupsFailureSheet(old: model.lastRename?.0 ?? "The group", new: model.lastRename?.1 ?? "the new name", failures: model.renameFailures, done: { model.renameFailures = [] })
        }
        .confirmationDialog("Remove this group?", isPresented: Binding(get: { model.pendingRemoval != nil }, set: { if !$0 { model.pendingRemoval = nil } })) {
            Button("Remove", role: .destructive) { if let name = model.pendingRemoval { model.pendingRemoval = nil; model.remove(name) } }
            Button("Cancel", role: .cancel) { model.pendingRemoval = nil }
        } message: {
            let count = model.layoutCount(for: model.pendingRemoval ?? "")
            Text("Used by \(count) \(count == 1 ? "layout" : "layouts"). Remove anyway?")
        }
    }

    private var groupList: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(model.store.document.groups, id: \.name) { group in
                        Button { model.selectedName = group.name } label: {
                            HStack(spacing: 8) {
                                HStack(spacing: -8) { ForEach(Array(group.apps.prefix(3).enumerated()), id: \.offset) { _, entry in
                                    ApplicationChoiceIcon(url: app(for: entry)?.url, size: 24)
                                } }.frame(minWidth: 28)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(group.name).lineLimit(1)
                                    let count = model.layoutCount(for: group.name)
                                    Text("\(group.apps.count) \(group.apps.count == 1 ? "app" : "apps") · \(count) \(count == 1 ? "layout" : "layouts")").font(SettingsFont.caption).foregroundStyle(.secondary)
                                    if model.store.suggestedNames.contains(group.name) { Text("Suggested").font(SettingsFont.caption).foregroundStyle(.secondary) }
                                }
                                Spacer(minLength: 0)
                                let problems = group.apps.filter { entry in
                                    guard let resolution = model.store.resolutions[entry] else { return false }
                                    if case .resolved = resolution { return false }; return true
                                }.count
                                if problems > 0 { Text("\(problems)").font(SettingsFont.caption).foregroundStyle(SettingsColor.orange) }
                            }.padding(8).contentShape(Rectangle())
                                .background(model.selectedName == group.name ? SettingsColor.accentSoft : .clear, in: .settings(SettingsRadius.control))
                        }.buttonStyle(.plain)
                    }
                }.padding(6)
            }
            Spacer(minLength: 0)
            Divider()
            HStack {
                Button { model.newGroup() } label: { Image(systemName: "plus") }
                Button { if let name = model.selectedName { model.requestRemoval(name) } } label: { Image(systemName: "minus") }.disabled(model.selectedName == nil)
                Spacer()
            }.buttonStyle(.borderless).padding(8)
        }
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let group = model.selected {
                TextField("Group name", text: $title).font(SettingsFont.statusValue).textFieldStyle(.plain)
                    .onSubmit { model.requestRename(title) }
                Text("The first app open on the desktop wins the pane.").font(SettingsFont.caption).foregroundStyle(.secondary)
                if model.store.suggestedNames.contains(group.name) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack { Text("Suggested").foregroundStyle(.secondary); Spacer(); Button("Remove") { model.requestRemoval(group.name) }; Button("Keep") { model.keep(group.name) } }
                        Text("Keep or Remove saves your App Groups. Other suggestions are kept.").foregroundStyle(.secondary)
                    }.font(SettingsFont.caption)
                }
                Divider()
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(group.apps.enumerated()), id: \.offset) { index, entry in
                            appRow(entry, index: index)
                                .onDrag { draggedIndex = index; return NSItemProvider(object: String(index) as NSString) }
                                .onDrop(of: [.text], isTargeted: nil) { _ in
                                    guard let from = draggedIndex else { return false }; draggedIndex = nil; model.move(from: from, to: index > from ? index + 1 : index); return true
                                }
                        }
                    }
                }
                HStack {
                    Button("Add App", systemImage: "plus") { picker = true }
                    Spacer()
                    if group.apps.contains(where: { $0.bundleID == nil && model.store.resolvedBundleIDs[$0] != nil }) {
                        Button("Save Resolved Apps") { model.perform { try model.store.saveResolvedApps() } }
                    }
                }
            } else { Text("Select a group").foregroundStyle(.secondary) }
        }.padding(12)
    }

    private func app(for entry: AppGroupEntry) -> ApplicationChoice? {
        guard let id = model.store.resolvedBundleIDs[entry] ?? entry.bundleID else { return nil }
        return model.store.applications.first { $0.bundleIdentifier.caseInsensitiveCompare(id) == .orderedSame }
    }
    private func appRow(_ entry: AppGroupEntry, index: Int) -> some View {
        let resolution = model.store.resolutions[entry] ?? .notInstalled
        return HStack(spacing: 8) {
            Text("\(index + 1)").font(SettingsFont.caption).foregroundStyle(.secondary).frame(width: 14)
            Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary)
            ApplicationChoiceIcon(url: app(for: entry)?.url, size: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.displayName(entry))
                switch resolution {
                case .resolved:
                    if entry.bundleID == nil, let name = entry.name { Text("Found from “\(name)” in the file").font(SettingsFont.caption).foregroundStyle(.secondary) }
                case .ambiguous: Text("More than one match · skipped until chosen").font(SettingsFont.caption).foregroundStyle(SettingsColor.orange)
                case .notInstalled: Text("Not installed · skipped").font(SettingsFont.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if case let .ambiguous(candidates) = resolution {
                Menu("Choose") { ForEach(candidates) { candidate in Button(candidate.name) { model.choose(candidate, at: index) } } }
            }
            Button { model.updateApps { if $0.indices.contains(index) { $0.remove(at: index) } } } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
        }.padding(.vertical, 3)
    }
}

struct AppGroupsRenameSheet: View {
    let group: String
    let save: () -> Void
    let discard: () -> Void
    let cancel: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Save changes before renaming?").font(.headline)
            Text("Save or discard the layout's changes before renaming \(group).")
            HStack { Spacer(); Button("Cancel", action: cancel).keyboardShortcut(.cancelAction); Button("Discard", action: discard); Button("Save and Rename", action: save).keyboardShortcut(.defaultAction) }
        }.padding(20).frame(width: 420).font(SettingsFont.body)
    }
}

struct AppGroupsFailureSheet: View {
    let old: String
    let new: String
    let failures: [AppGroupsStore.RenameFailure]
    let done: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(failures.count == 1 ? "One layout could not be updated" : "Some layouts could not be updated").font(.headline)
            Text("\(old) was renamed to \(new). Update the group preference in each affected layout.")
            ForEach(Array(failures.enumerated()), id: \.offset) { _, failure in
                Text("\(failure.layoutName): \(failure.reason)").font(SettingsFont.caption).textSelection(.enabled)
            }
            HStack { Spacer(); Button("Done", action: done).keyboardShortcut(.defaultAction) }
        }.padding(20).frame(width: 420).font(SettingsFont.body)
    }
}
