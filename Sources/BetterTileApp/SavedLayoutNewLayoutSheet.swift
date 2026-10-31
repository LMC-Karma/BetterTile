// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 LMC-Karma

import BetterTileCore
import BetterTileMacOS
import Observation
import SwiftUI

struct SavedLayoutNewSetup {
    var name = "Untitled Layout"
    var mode: LayoutMode = .bento
    var preset: TabbedPreset = .columns

    var showsPresets: Bool { mode != .manual }
    var nameIssue: String? {
        SavedLayoutValidator.validate(SavedLayoutDocument(name: name, mode: .manual))
            .first(where: { $0.path == "$.name" })?.message
    }
}

enum SavedLayoutEditorAction {
    case new(SavedLayoutNewSetup), open(URL), importFile(URL), reload(URL)
    case mode(LayoutMode), preset(TabbedPreset), capture, updateFromDesktop, updateFromFile(URL), cancelDraft

    var allowedDuringApply: Bool {
        if case .open = self { return true }
        return false
    }

    var changesGeometry: Bool {
        switch self { case .mode, .preset: true; default: false }
    }
}

/// Creation changes only the local editor. The page owns Apply separately.
@MainActor @Observable final class SavedLayoutCreation {
    var showingSetup = false
    var setupToContinue: SavedLayoutNewSetup?
    var pending: SavedLayoutEditorAction?
    var updateToConfirm: SavedLayoutEditorAction?
    private(set) var isDraft = false
    private var returnURL: URL?

    func openSetup() { setupToContinue = nil; showingSetup = true }
    func cancelSetup() { setupToContinue = nil; showingSetup = false }
    func continueSetup(_ setup: SavedLayoutNewSetup) { setupToContinue = setup; showingSetup = false }

    /// Sheet dismissal precedes any replacement alert. Cancel has no editor or Apply effects.
    func setupDismissed(editor: SavedLayoutEditor, isApplying: Bool) -> SavedLayoutEditorAction? {
        guard let setup = setupToContinue else { return nil }
        setupToContinue = nil
        return request(.new(setup), editor: editor, isApplying: isApplying)
    }

    func confirmationTitle(editor: SavedLayoutEditor) -> String {
        switch pending {
        case .cancelDraft?: "Discard this draft?"
        case .mode?, .preset?: "Continue with this change?"
        default: editor.url != nil && editor.isDirty ? "Discard unsaved changes?" : "Replace this draft?"
        }
    }

    func request(_ action: SavedLayoutEditorAction, editor: SavedLayoutEditor, isApplying: Bool) -> SavedLayoutEditorAction? {
        guard !isApplying || action.allowedDuringApply else { return nil }
        if action.changesGeometry || editor.hasInvalidSource || editor.isDirty || (editor.document != nil && editor.url == nil) {
            pending = action
            return nil
        }
        return action
    }

    func keepEditing() { pending = nil }
    func discardDraft() -> SavedLayoutEditorAction? {
        defer { pending = nil }
        return pending
    }

    func begin(_ setup: SavedLayoutNewSetup, editor: SavedLayoutEditor) {
        if !isDraft { returnURL = editor.url }
        editor.newLayout(mode: setup.mode)
        if setup.showsPresets { editor.setPreset(setup.preset) }
        editor.edit { $0.name = setup.name }
        editor.resetHistory()
        isDraft = true
    }

    @discardableResult func save(editor: SavedLayoutEditor) -> Bool {
        guard editor.save(as: editor.document?.name) else { return false }
        isDraft = false
        returnURL = nil
        return true
    }

    @discardableResult func cancel(editor: SavedLayoutEditor) -> Bool {
        // A failed reload must keep the draft, just like any other editor load.
        if let returnURL {
            guard editor.load(returnURL) else { return false }
        } else { editor.clearDraft() }
        finish()
        return true
    }

    func finish() { isDraft = false; returnURL = nil }
}

struct SavedLayoutNewLayoutSheet: View {
    @State var setup = SavedLayoutNewSetup()
    let onCancel: () -> Void
    let onContinue: (SavedLayoutNewSetup) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Layout").font(SettingsFont.title)
            Text("Start from an empty arrangement and choose the apps.")
            SettingsGroup {
                VStack(spacing: 0) {
                    SettingsRow("Layout name") {
                        TextField("Layout name", text: $setup.name).textFieldStyle(.roundedBorder).frame(width: 280)
                    }
                    SettingsSeparator()
                    SettingsRow("Mode") { LayoutModePicker("Mode", selection: $setup.mode).fixedSize() }
                }
            }
            if setup.showsPresets {
                SettingsGroup {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Starting arrangement").font(SettingsFont.body.weight(.semibold))
                        HStack(spacing: 8) {
                            ForEach(TabbedPreset.allCases, id: \.self) { preset in
                                Button { setup.preset = preset } label: {
                                    VStack(spacing: 6) {
                                        LayoutGlyphView(.layout(preset), size: 56).frame(height: 44)
                                        Text(SavedLayoutCanvas.shape(SavedLayoutCanvas.presetLayout(preset, panes: [])).name)
                                            .font(SettingsFont.caption).lineLimit(1)
                                    }
                                    .frame(maxWidth: .infinity).padding(8)
                                    .background(SettingsColor.fill, in: RoundedRectangle.settings(SettingsRadius.inner))
                                    .overlay(RoundedRectangle.settings(SettingsRadius.inner)
                                        .strokeBorder(setup.preset == preset ? Color.accentColor : Color.clear, lineWidth: 2))
                                }.buttonStyle(.plain)
                            }
                        }
                    }.padding(12)
                }
            } else {
                Text("Add apps on the canvas, then set each window’s position and size.")
                    .foregroundStyle(.secondary)
            }
            Text(setup.nameIssue ?? "Next: add apps on the canvas. This creates a draft. It does not save or apply a layout.")
                .font(SettingsFont.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Continue to Apps") { onContinue(setup) }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(setup.nameIssue != nil)
            }
        }.font(SettingsFont.body).padding(20).frame(width: 560).interactiveDismissDisabled()
    }
}
