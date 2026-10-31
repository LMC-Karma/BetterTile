// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 LMC-Karma
// Contains portions adapted from Vorssaint, Copyright (C) 2026 Vorssaint.

import AppKit
import BetterTileCore
import BetterTileMacOS
import SwiftUI

struct ShortcutsSettings: View {
    @Bindable var model: BetterTileModel
    @State private var recordingAction: WindowAction?
    @State private var shortcutError: (action: WindowAction, message: String)?
    @State private var shortcutSearch = ""
    @State private var expandedGroups: Set<WindowActionGroup> = [.halves, .thirds]

    init(model: BetterTileModel, shortcutError: (action: WindowAction, message: String)? = nil,
         expandedGroups: Set<WindowActionGroup> = [.halves, .thirds], search: String = "",
         recordingAction: WindowAction? = nil) {
        self.model = model
        _shortcutError = State(initialValue: shortcutError)
        _expandedGroups = State(initialValue: expandedGroups)
        _shortcutSearch = State(initialValue: search)
        _recordingAction = State(initialValue: recordingAction)
    }

    var keyboardShortcutsBinding: Binding<Bool> {
        Binding(get: { model.configuration.keyboardShortcutsEnabled },
                set: { value in model.updateConfiguration { $0.keyboardShortcutsEnabled = value } })
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: SettingsSpacing.s5) {
                    SettingsGroup("Keyboard") {
                        SettingsRow("BetterTile keyboard shortcuts", caption: "Turning this off keeps every shortcut you set. You can still edit shortcuts below.") {
                            Toggle("BetterTile keyboard shortcuts", isOn: keyboardShortcutsBinding)
                                .labelsHidden()
                                .toggleStyle(.switch)
                        }
                    }
                    if let error = shortcutError {
                        NoticeBanner(.problem, title: "Shortcut could not be changed", message: error.message,
                                     action: .init(title: "Show Conflict") {
                            shortcutSearch = ""
                            if let group = WindowActionGroup.allCases.first(where: { $0.actions.contains(error.action) }) {
                                expandedGroups.insert(group)
                            }
                            DispatchQueue.main.async { proxy.scrollTo(error.action, anchor: .center) }
                        })
                    }
                    shortcutsGroup
                    StatusMessage(model: model)
                }
                .padding(SettingsSpacing.s6)
            }
        }
        .font(SettingsFont.body)
        .background {
            InlineKeyCaptureView(
                isRecording: Binding(
                    get: { recordingAction != nil },
                    set: { if !$0 { recordingAction = nil } }
                ),
                capture: { captured in
                    guard let recordingAction else { return }
                    model.assign(shortcut: captured, to: recordingAction)
                    if model.configuration.shortcuts.first(where: { $0.action == recordingAction })?.shortcut != captured,
                       let message = model.statusMessage {
                        shortcutError = (recordingAction, message)
                    }
                    self.recordingAction = nil
                    model.setShortcutCaptureActive(false)
                },
                cancel: {
                    recordingAction = nil
                    model.setShortcutCaptureActive(false)
                }
            )
            .frame(width: 1, height: 1)
            .opacity(0.001)
        }
        .onDisappear {
            if recordingAction != nil {
                recordingAction = nil
                model.setShortcutCaptureActive(false)
            }
        }
    }

    private var shortcutsGroup: some View {
        SettingsGroup("Shortcuts", aside: "\(WindowActionGroup.flattenedActions.count) actions in \(WindowActionGroup.allCases.count) groups") {
            HStack(spacing: SettingsSpacing.s2) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search actions", text: $shortcutSearch)
                    .textFieldStyle(.plain)
            }
            .padding(SettingsSpacing.s3)
            if filteredGroups.isEmpty {
                HelpText("No actions match “\(shortcutSearch)”. Try another action name.")
                    .padding(.vertical, SettingsSpacing.s3)
            }
            ForEach(filteredGroups) { group in
                VStack(alignment: .leading, spacing: 0) {
                    Button {
                        if expandedGroups.contains(group) { expandedGroups.remove(group) }
                        else { expandedGroups.insert(group) }
                    } label: {
                        HStack(spacing: SettingsSpacing.s2) {
                            Image(systemName: isExpanded(group) ? "chevron.down" : "chevron.right")
                                .font(SettingsFont.caption).frame(width: 12)
                            Text(group.title).font(SettingsFont.headline)
                            Spacer()
                            Text(shortcutCount(group)).font(SettingsFont.caption).foregroundStyle(.secondary)
                        }
                        .padding(SettingsSpacing.s3)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if isExpanded(group) {
                        ForEach(filteredActions(group)) { action in
                            SettingsSeparator()
                            ShortcutActionRow(model: model, action: action, isRecording: recordingAction == action) {
                                shortcutError = nil
                                model.setShortcutCaptureActive(true)
                                recordingAction = action
                            }
                            .id(action)
                            if let error = shortcutError, error.action == action {
                                Label(error.message, systemImage: "exclamationmark.circle")
                                    .font(SettingsFont.caption)
                                    .foregroundStyle(SettingsColor.red)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .padding(.horizontal, SettingsSpacing.s3)
                                    .padding(.bottom, SettingsSpacing.s2)
                            }
                        }
                    }
                }
            }
        } footer: {
            HStack(alignment: .top, spacing: SettingsSpacing.s3) {
                HelpText("Click an action to try it. Select its shortcut to record a replacement; duplicate combinations are rejected. Changed shortcuts show Reset.")
                Button("Reset All Shortcuts") {
                    model.updateConfiguration { $0.shortcuts = BetterTileConfiguration.defaultShortcuts }
                    shortcutError = nil
                }
                .disabled(model.configuration.shortcuts == BetterTileConfiguration.defaultShortcuts)
                .fixedSize()
                .padding(.trailing, SettingsSpacing.s1)
            }
        }
    }

    var filteredGroups: [WindowActionGroup] {
        WindowActionGroup.allCases.filter { !filteredActions($0).isEmpty }
    }

    func filteredActions(_ group: WindowActionGroup) -> [WindowAction] {
        let query = shortcutSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        return group.actions.filter { query.isEmpty || $0.title.localizedStandardContains(query) || group.title.localizedStandardContains(query) }
    }

    func isExpanded(_ group: WindowActionGroup) -> Bool {
        !shortcutSearch.isEmpty || expandedGroups.contains(group)
    }

    private func shortcutCount(_ group: WindowActionGroup) -> String {
        let set = group.actions.filter { action in
            model.configuration.shortcuts.contains { $0.action == action && $0.shortcut != nil }
        }.count
        return "\(set) of \(group.actions.count) set"
    }

}

private struct ShortcutActionRow: View {
    @Bindable var model: BetterTileModel
    let action: WindowAction
    let isRecording: Bool
    let beginRecording: () -> Void

    private var shortcut: BetterTileCore.KeyboardShortcut? {
        model.configuration.shortcuts.first(where: { $0.action == action })?.shortcut
    }

    private var defaultShortcut: BetterTileCore.KeyboardShortcut? {
        BetterTileConfiguration.defaultShortcuts
            .first(where: { $0.action == action })?
            .shortcut
    }

    var body: some View {
        HStack(spacing: SettingsSpacing.s2) {
            Button {
                model.perform(action)
            } label: {
                HStack(spacing: SettingsSpacing.s2) {
                    WindowActionGlyph(action: action)
                    Text(action.title)
                        .lineLimit(1)
                }
                .frame(minWidth: 145, alignment: .leading)
            }
            .buttonStyle(.plain)
            .disabled(!model.hasAccessibilityPermission)

            if shortcut != defaultShortcut { SettingsPill("Modified") }
            Spacer()

            Button(action: beginRecording) {
                Group {
                    if isRecording {
                        Text("Press keys…").font(SettingsFont.body)
                    } else {
                        ShortcutLabel(shortcut: shortcut, emptyLabel: "None", size: 13)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 112, height: 26)
            }
            .accessibilityLabel("Shortcut for \(action.title)")

            Button {
                model.assign(shortcut: nil, to: action)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .disabled(shortcut == nil)
            .help("Clear shortcut")

            if shortcut != defaultShortcut {
                Button("Reset") { model.assign(shortcut: defaultShortcut, to: action) }
            }
        }
        .padding(.horizontal, SettingsSpacing.s3)
        .padding(.vertical, SettingsSpacing.s2)
    }
}

private struct InlineKeyCaptureView: NSViewRepresentable {
    @Binding var isRecording: Bool
    let capture: (BetterTileCore.KeyboardShortcut) -> Void
    let cancel: () -> Void

    func makeNSView(context: Context) -> InlineKeyCaptureNSView {
        let view = InlineKeyCaptureNSView()
        update(view)
        return view
    }

    func updateNSView(_ nsView: InlineKeyCaptureNSView, context: Context) {
        update(nsView)
        if isRecording {
            DispatchQueue.main.async {
                guard isRecording else { return }
                nsView.window?.makeFirstResponder(nsView)
            }
        } else if nsView.window?.firstResponder === nsView {
            nsView.window?.makeFirstResponder(nil)
        }
    }

    private func update(_ view: InlineKeyCaptureNSView) {
        view.capture = capture
        view.cancel = cancel
    }
}

final class InlineKeyCaptureNSView: NSView {
    var capture: ((BetterTileCore.KeyboardShortcut) -> Void)?
    var cancel: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            cancel?()
            return
        }
        var modifiers: ShortcutModifiers = []
        if event.modifierFlags.contains(.command) { modifiers.insert(.command) }
        if event.modifierFlags.contains(.option) { modifiers.insert(.option) }
        if event.modifierFlags.contains(.control) { modifiers.insert(.control) }
        if event.modifierFlags.contains(.shift) { modifiers.insert(.shift) }
        let labels: [UInt16: String] = [
            36: "↩",
            48: "⇥",
            49: "Space",
            51: "⌫",
            117: "⌦",
            123: "←",
            124: "→",
            125: "↓",
            126: "↑",
        ]
        capture?(
            BetterTileCore.KeyboardShortcut(
                keyCode: UInt32(event.keyCode),
                modifiers: modifiers,
                keyLabel: labels[event.keyCode] ?? event.charactersIgnoringModifiers ?? "?"
            )
        )
    }
}
