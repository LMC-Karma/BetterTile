// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 LMC-Karma

import AppKit
import BetterTileCore
import BetterTileMacOS
import SwiftUI

struct SavedLayoutPreferencePresentation {
    var title: String
    var detail: String?
    var iconURL: URL?
    var isGroup = false
    var unavailable = false

    init(_ preference: AppPreference, applications: [String: ApplicationChoice], groups: AppGroupsDocument) {
        switch preference {
        case let .app(id):
            let app = applications.values.first { $0.id.caseInsensitiveCompare(id) == .orderedSame }
            title = app?.name ?? "An app that is not installed"
            detail = app == nil ? "Not installed · skipped" : nil
            iconURL = app?.url
            unavailable = app == nil
        case let .group(name):
            let group = groups.groups.first { sameGroupName($0.name, name) }
            title = "@" + (group?.name ?? name)
            detail = group == nil ? "Group not found · skipped when you apply" : nil
            isGroup = true; unavailable = group == nil
        }
    }
}

struct SavedLayoutPreferenceIcon: View {
    let presentation: SavedLayoutPreferencePresentation
    var size: CGFloat = 24
    var body: some View {
        Group {
            if let url = presentation.iconURL {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable()
            } else {
                Image(systemName: presentation.isGroup ? "square.stack.3d.up" : "app.dashed")
                    .resizable().scaledToFit().padding(size / 6)
                    .foregroundStyle(presentation.unavailable ? Color.secondary : .accentColor)
                    .background(SettingsColor.fill, in: RoundedRectangle.settings(SettingsRadius.control))
            }
        }
        .frame(width: size, height: size)
        .help(presentation.title)
    }
}

/// The first preference names a pane. Two secondary icons fit; the count covers the rest.
struct SavedLayoutPreferenceLabel: View {
    let preferences: [AppPreference]
    var applications: [String: ApplicationChoice]
    var groups: AppGroupsDocument = .init()
    var compact = false

    var body: some View {
        VStack(spacing: compact ? 4 : 8) {
            if let first = preferences.first {
                let presentation = SavedLayoutPreferencePresentation(first, applications: applications, groups: groups)
                SavedLayoutPreferenceIcon(presentation: presentation, size: compact ? 24 : 40)
                Text(presentation.title).font((compact ? SettingsFont.caption : SettingsFont.body).weight(.semibold))
                    .lineLimit(2).foregroundStyle(presentation.unavailable ? Color.secondary : .primary)
                if preferences.count > 1 {
                    HStack(spacing: 6) {
                        ForEach(Array(preferences.dropFirst().prefix(2).enumerated()), id: \.offset) { _, preference in
                            SavedLayoutPreferenceIcon(presentation: .init(preference, applications: applications, groups: groups), size: 18)
                        }
                        if preferences.count > 3 { Text("+\(preferences.count - 3)").font(SettingsFont.caption).foregroundStyle(.secondary) }
                    }
                }
            } else {
                Image(systemName: "macwindow").font(.system(size: compact ? 20 : 28)).foregroundStyle(.secondary)
                Text("Any window").font(SettingsFont.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .multilineTextAlignment(.center)
    }
}

struct SavedLayoutPanePreferences: View {
    @Bindable var editor: SavedLayoutEditor
    let slotID: String
    var title = "Pane preferences"
    var groups: AppGroupsDocument = .init()
    var applications: [String: ApplicationChoice] = [:]
    var paletteSource = SavedLayoutPaletteSource()
    var onDone: () -> Void = {}
    @State private var adding = false
    private var preferences: [AppPreference] { editor.document?.slots.first { $0.id == slotID }?.prefer ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title).font(SettingsFont.headline)
                Spacer()
                Button("Done", action: onDone)
            }
            Text("Preferences, in order").font(SettingsFont.caption).foregroundStyle(.secondary)
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(preferences.enumerated()), id: \.offset) { index, preference in
                        preferenceRow(preference, index: index)
                    }
                    if preferences.isEmpty {
                        Text("Any window can fill this pane.").font(SettingsFont.body).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 72)
                    }
                }
            }.frame(height: min(252, max(72, CGFloat(preferences.count) * 48)))
            HStack {
                Button { adding.toggle() } label: { Label("Add preference", systemImage: "plus") }
                    .popover(isPresented: $adding, arrowEdge: .bottom) {
                        PanePreferenceApplicationPicker(groups: groups, selected: preferences,
                            installedApplications: paletteSource.installed, runningApplications: paletteSource.running, recentApplications: paletteSource.recent,
                            onAdd: { editor.addPreference($0, to: slotID) }, onDone: { adding = false })
                    }
                Spacer()
            }
            Text("The first available preference wins. Other preferences can still fill this pane.")
                .font(SettingsFont.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(16).frame(width: 340).font(SettingsFont.body)
    }

    private func preferenceRow(_ preference: AppPreference, index: Int) -> some View {
        let presentation = SavedLayoutPreferencePresentation(preference, applications: applications, groups: groups)
        return HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal").foregroundStyle(.secondary)
                .help("Drag to reorder")
                .draggable(slotID + ":" + String(index))
            Text("\(index + 1)").font(SettingsFont.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 14)
            SavedLayoutPreferenceIcon(presentation: presentation)
            VStack(alignment: .leading, spacing: 2) {
                Text(presentation.title).lineLimit(2).foregroundStyle(presentation.unavailable ? Color.secondary : .primary)
                if let detail = presentation.detail { Text(detail).font(SettingsFont.caption).foregroundStyle(.secondary) }
            }.frame(maxWidth: .infinity, alignment: .leading)
            Button { editor.removePreference(at: index, from: slotID) } label: { Image(systemName: "minus.circle") }
                .buttonStyle(.borderless).help("Remove " + presentation.title)
        }
        .frame(minHeight: 48).contentShape(Rectangle())
        .dropDestination(for: String.self) { values, _ in
            guard let value = values.first, value.hasPrefix(slotID + ":"),
                  let source = Int(value.dropFirst(slotID.count + 1)) else { return false }
            return editor.movePreference(in: slotID, from: source, to: index)
        }
    }
}

struct SavedLayoutUpdateConfirmation: View {
    var name: String
    var turnsOffExtraWindows = false
    static func extraWindowsNotice(original: SavedLayoutDocument, capturedMode: LayoutMode) -> String? {
        original.extraWindows == .addAsPanes && capturedMode != .bento
            ? "Add extra windows as panes works only in Adaptive and will be turned off." : nil
    }
    var onCancel: () -> Void
    var onUpdate: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Update \(name)?").font(SettingsFont.headline)
            Text("The shape and sizes will change to match your current desktop. Existing pane preferences will stay.")
            Text("A new pane will prefer the app currently in it.").font(SettingsFont.caption).foregroundStyle(.secondary)
            if turnsOffExtraWindows {
                Text("Add extra windows as panes works only in Adaptive and will be turned off.")
                    .font(SettingsFont.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Update", action: onUpdate).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }.font(SettingsFont.body).padding(20).frame(width: 420)
    }
}

struct SavedLayoutImportSheet: View {
    @Bindable var editor: SavedLayoutEditor
    var groups: AppGroupsDocument
    var onImport: () -> Void
    var onCancel: () -> Void
    var body: some View {
        if let request = editor.pendingImport {
            VStack(alignment: .leading, spacing: 16) {
                Text("Import " + request.transfer.document.name).font(SettingsFont.headline)
                Text("Choose how to use the missing App Groups.")
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(request.missing, id: \.self) { name in groupRow(name, request: request) }
                    }
                }.frame(maxHeight: 280)
                if let message = editor.messageStatus, message.kind == .bad {
                    Text(message.text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Spacer()
                    Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                    Button("Import", action: onImport).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                }
            }.font(SettingsFont.body).padding(20).frame(width: 440)
        }
    }
    private func groupRow(_ name: String, request: SavedLayoutImport) -> some View {
        let group = request.transfer.appGroups.first { sameGroupName($0.name, name) }
        return VStack(alignment: .leading, spacing: 8) {
            Label(name, systemImage: "square.stack.3d.up").font(SettingsFont.headline)
            if let group {
                Text(group.apps.map { $0.name ?? "An app that is not installed" }.joined(separator: ", ") + " · from this layout")
                    .font(SettingsFont.caption).foregroundStyle(.secondary)
            } else { Text("No copy of this group is included. Choose an existing group.").font(SettingsFont.caption).foregroundStyle(.secondary) }
            Picker("Use group", selection: Binding(get: { editor.pendingImport?.choices[name] ?? .add },
                set: { editor.pendingImport?.choices[name] = $0 })) {
                Text("Add group").tag(SavedLayoutGroupImportChoice.add).disabled(group == nil)
                ForEach(groups.groups, id: \.name) { group in
                    Text("Use existing group: " + group.name).tag(SavedLayoutGroupImportChoice.existing(group.name))
                }
            }.labelsHidden().pickerStyle(.menu)
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(SettingsColor.fill, in: RoundedRectangle.settings(SettingsRadius.inner))
    }
}

struct SavedLayoutExportSheet: View {
    var document: SavedLayoutDocument
    var groups: AppGroupsDocument
    var onCancel: () -> Void
    var onExport: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Export " + document.name).font(SettingsFont.headline)
            Text("The export includes this layout and copies of the groups it uses.")
            let included = SavedLayoutTransfer.usedGroups(in: document, from: groups)
            if !included.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Included groups").font(SettingsFont.headline)
                    ForEach(included, id: \.name) { group in
                        HStack {
                            Label(group.name, systemImage: "square.stack.3d.up")
                            Spacer()
                            Text("\(group.apps.count) \(group.apps.count == 1 ? "app" : "apps")").foregroundStyle(.secondary)
                        }
                    }
                }.padding(12).background(SettingsColor.fill, in: RoundedRectangle.settings(SettingsRadius.inner))
            }
            HStack {
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Export…", action: onExport).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }.font(SettingsFont.body).padding(20).frame(width: 420)
    }
}

struct SavedLayoutPreferenceRequest: Identifiable {
    let id = UUID()
    var slotID: String
}

/// Uses the same transient glass presenter as the Tabbed '+' chooser. Outside
/// mouse-down dismisses it and returns the event, so another pane still receives its click.
struct SavedLayoutPreferencePopover: NSViewRepresentable {
    var request: SavedLayoutPreferenceRequest?
    var appearance: OverlayAppearance
    var onDismiss: (UUID) -> Void
    var content: (String, @escaping () -> Void) -> AnyView
    var makePresenter: (NSView, NSSize, OverlayAppearance) -> TabbedChooserPresenter = {
        TabbedChooserPresenter(content: $0, size: $1, appearance: $2)
    }

    func makeNSView(context: Context) -> Anchor { Anchor() }
    func updateNSView(_ view: Anchor, context: Context) {
        view.update = { [weak view] in
            guard let view else { return }
            guard let request else { view.close(); view.dismissedID = nil; return }
            guard view.dismissedID != request.id, let window = view.window else { return }
            if view.currentID == request.id, let host = view.host {
                host.rootView = content(request.slotID, { [weak view] in view?.presenter?.dismiss() })
                return
            }
            view.close()
            let host = PreferenceHostingView(rootView: content(request.slotID, { [weak view] in view?.presenter?.dismiss() }))
            let presenter = makePresenter(host, NSSize(width: 340, height: 460), appearance)
            presenter.panel.appearance = window.effectiveAppearance
            view.host = host; view.presenter = presenter; view.currentID = request.id
            presenter.onDismiss = { [weak view, weak host] in
                host?.rootView = AnyView(EmptyView())
                if view?.currentID == request.id {
                    view?.presenter = nil; view?.host = nil; view?.currentID = nil
                    view?.dismissedID = request.id
                    view?.removeObserver()
                }
                Task { @MainActor in onDismiss(request.id) }
            }
            view.deactivation = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification,
                object: nil, queue: .main) { [weak presenter] _ in
                    MainActor.assumeIsolated { presenter?.dismiss() }
                }
            presenter.show(relativeTo: view.bounds, of: view, paneFrame: nil)
        }
        view.update?()
    }
    static func dismantleNSView(_ view: Anchor, coordinator: ()) { view.update = nil; view.close() }

    final class Anchor: NSView {
        var update: (() -> Void)?
        var presenter: TabbedChooserPresenter?
        var host: NSHostingView<AnyView>?
        var currentID: UUID?
        var dismissedID: UUID?
        var deactivation: NSObjectProtocol?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { close() } else { update?() }
        }
        func removeObserver() {
            if let deactivation { NotificationCenter.default.removeObserver(deactivation) }
            deactivation = nil
        }
        func close() {
            presenter?.dismiss(); presenter = nil; host = nil; currentID = nil
            removeObserver()
        }
    }
    private final class PreferenceHostingView: NSHostingView<AnyView> {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }
}
