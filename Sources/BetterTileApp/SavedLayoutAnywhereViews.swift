// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 LMC-Karma

import AppKit
import BetterTileCore
import BetterTileMacOS
import SwiftUI

struct SavedLayoutAnywhereSettings: View {
    @Bindable var model: BetterTileModel
    let file: String
    @State private var recording = false
    private var settings: SavedLayoutActionSettings { model.savedLayoutActions.store.settings(for: file) }
    private func update(_ change: (inout SavedLayoutActionSettings) -> Void) {
        var value = settings; change(&value); _ = model.setSavedLayoutActions(file, value)
    }
    var body: some View {
        SettingsGroup("Use from anywhere") {
            SettingsRow("Shortcut") {
                Button {
                    model.savedLayoutActions.message = nil
                    recording = true; model.setShortcutCaptureActive(true)
                } label: {
                    if recording { Text("Press keys…") }
                    else { ShortcutLabel(shortcut: settings.shortcut, emptyLabel: "Record shortcut", size: 13) }
                }
                Button { update { $0.shortcut = nil } } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).disabled(settings.shortcut == nil).help("Clear shortcut")
            }
            SettingsSeparator()
            SettingsRow("Show in the menu bar panel") {
                Toggle("Show in the menu bar panel", isOn: Binding(get: { settings.showInMenuBar }, set: { on in update { $0.showInMenuBar = on } }))
                    .labelsHidden().toggleStyle(.switch)
            }
            SettingsSeparator()
            SettingsRow("Show in the Layout Wheel") {
                Toggle("Show in the Layout Wheel", isOn: Binding(get: { settings.showInWheel }, set: { on in update { $0.showInWheel = on } }))
                    .labelsHidden().toggleStyle(.switch)
            }
            if let problem = model.savedLayoutShortcutProblem(file) ?? model.savedLayoutActions.message ?? model.savedLayoutActions.store.loadError {
                Text(problem).font(SettingsFont.caption).foregroundStyle(SettingsColor.red)
                    .padding(SettingsSpacing.s3).fixedSize(horizontal: false, vertical: true)
            }
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                HelpText("Saved on this Mac only. Export does not include shortcuts.")
                HelpText("Some system or other app shortcuts cannot be checked. If a shortcut does not respond, choose another.")
            }
        }
        .background {
            SavedLayoutKeyCapture(recording: recording, capture: { key in
                update { $0.shortcut = key }; finishRecording()
            }, cancel: finishRecording).frame(width: 1, height: 1).opacity(0.001)
        }
        .onDisappear { if recording { finishRecording() } }
    }
    private func finishRecording() { recording = false; model.setShortcutCaptureActive(false) }
}

private struct SavedLayoutKeyCapture: NSViewRepresentable {
    let recording: Bool
    let capture: (BetterTileCore.KeyboardShortcut) -> Void
    let cancel: () -> Void
    func makeNSView(context: Context) -> InlineKeyCaptureNSView { InlineKeyCaptureNSView() }
    func updateNSView(_ view: InlineKeyCaptureNSView, context: Context) {
        view.capture = capture; view.cancel = cancel
        if recording {
            DispatchQueue.main.async { if recording { view.window?.makeFirstResponder(view) } }
        } else if view.window?.firstResponder === view { view.window?.makeFirstResponder(nil) }
    }
}

/// Uses cached library/run state. No window inventory or target reads happen in body.
struct SavedLayoutPanelSection: View {
    @Bindable var model: BetterTileModel
    var openSettings: (() -> Void)?
    var body: some View {
        if !model.savedLayoutActions.menuEntries.isEmpty || model.savedLayoutActionFile != nil || model.followedSavedLayout != nil {
            VStack(alignment: .leading, spacing: 8) {
                Divider()
                if let followed = model.followedSavedLayout {
                    HStack(spacing: 8) {
                        Circle().fill(.tint).frame(width: 8, height: 8)
                            .background {
                                Circle().fill(Color.accentColor.opacity(0.25)).frame(width: 14, height: 14)
                            }
                        Text("Following \(followed.layoutName)").font(.system(size: 12, weight: .semibold)).lineLimit(1)
                        Spacer(minLength: 4)
                        Button("Stop") { model.stopFollowingSavedLayout() }
                            .controlSize(.small)
                    }
                    .padding(8)
                    .background(SettingsColor.accentSoft, in: .settings(SettingsRadius.inner))
                    .padding(.bottom, 6)
                }
                Text("Saved Layouts").font(.system(size: 12, weight: .semibold))
                if !model.savedLayoutActions.menuEntries.isEmpty {
                    Text(model.savedLayoutActionTargetName.map { "On: \($0) · Current desktop" } ?? "Focus an app window to apply a layout.")
                        .font(SettingsFont.caption).foregroundStyle(.secondary)
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(model.savedLayoutActions.menuEntries) { entry in
                                Button { _ = model.applySavedLayoutAction(entry.file) } label: {
                                    HStack(spacing: 9) {
                                        SavedLayoutThumbnail(document: entry.document, style: .menu)
                                            .frame(width: SavedLayoutMenuThumbnailMetrics.size.width, height: SavedLayoutMenuThumbnailMetrics.size.height)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(entry.name).lineLimit(1)
                                            Text(SavedLayoutQuickCapture.subtitle(for: entry.document, appNames: model.savedLayoutActions.applicationNames))
                                                .font(SettingsFont.caption).foregroundStyle(.secondary).lineLimit(1)
                                        }
                                        Spacer(minLength: 4)
                                        ShortcutLabel(shortcut: model.savedLayoutActions.store.settings(for: entry.file).shortcut, emptyLabel: "", size: 11)
                                            .foregroundStyle(.secondary)
                                    }.padding(.vertical, SavedLayoutMenuThumbnailMetrics.rowVerticalPadding)
                                    .frame(height: SavedLayoutMenuThumbnailMetrics.rowHeight).contentShape(Rectangle())
                                }
                                .buttonStyle(.plain).disabled(model.savedLayoutApplier?.isBusy == true || !model.hasAccessibilityPermission)
                                .help("Applies on the focused app window’s screen, even when this panel is on another screen.")
                            }
                        }
                    }.frame(height: CGFloat(min(4, model.savedLayoutActions.menuEntries.count)) * SavedLayoutMenuThumbnailMetrics.rowHeight)
                }
                SavedLayoutPanelRun(model: model)
                if let message = model.savedLayoutActions.message {
                    Text(message).font(SettingsFont.caption).fixedSize(horizontal: false, vertical: true)
                }
                Button("Open Saved Layouts…") { model.requestedSettingsDestination = .savedLayouts; openSettings?() }
                    .buttonStyle(.plain).foregroundStyle(.tint).font(SettingsFont.caption)
                Divider()
            }
        }
    }
}

/// Text shown inside the Saved Layouts result block, separate from global action feedback.
struct SavedLayoutPanelRunText {
    let title: String
    let summary: String?
    let details: [String]
    let message: String?

    init(run: SavedLayoutRun, message: String?) {
        let presentation = run.presentation
        title = presentation.title
        summary = presentation.title.contains(presentation.summary) ? nil : presentation.summary
        details = run.planPresentation?.lines ?? []
        self.message = message == presentation.title ? nil : message
    }
}

struct SavedLayoutPanelRun: View {
    @Bindable var model: BetterTileModel
    var body: some View {
        if let applier = model.savedLayoutApplier {
            if applier.isApplying {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Applying…").fontWeight(.semibold)

                }.font(SettingsFont.caption)
            } else if let run = applier.lastRun {
                let text = SavedLayoutPanelRunText(run: run, message: applier.undoUnavailableReason(run) ?? applier.message)
                VStack(alignment: .leading, spacing: 6) {
                    Text(text.title).fontWeight(.semibold)
                    if let summary = text.summary { Text(summary) }
                    ForEach(Array(text.details.enumerated()), id: \.offset) { _, line in Text(line) }
                    if applier.canUndo(run) {
                        Button("Undo Apply") { applier.startUndo(displayID: run.displayID) }
                    }
                    if let message = text.message { Text(message).foregroundStyle(.secondary) }
                }.font(SettingsFont.caption)
            }
        }
    }
}

/// A release on More opens a native menu. Its commands resolve files again when selected.
@MainActor enum SavedLayoutActionMenu {
    private final class Action: NSObject {
        let perform: () -> Void
        init(_ perform: @escaping () -> Void) { self.perform = perform }
        @objc func invoke(_ sender: NSMenuItem) { perform() }
    }
    static func show(_ choices: [(String, () -> Void)]) {
        let menu = NSMenu()
        let targets = choices.map { title, perform in
            let action = Action(perform)
            let item = NSMenuItem(title: title, action: #selector(Action.invoke(_:)), keyEquivalent: "")
            item.target = action; menu.addItem(item)
            return action
        }
        withExtendedLifetime(targets) { _ = menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil) }
    }
}
