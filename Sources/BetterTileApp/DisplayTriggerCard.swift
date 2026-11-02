// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 LMC-Karma

import AppKit
import BetterTileCore
import BetterTileMacOS
import SwiftUI

/// Names the displays of a set, one name each. Equal names get "left" and "right", or numbers.
func displayTriggerNames(_ displays: [DisplayFingerprint]) -> [String] {
    let order = displays.indices.sorted { displays[$0].frame.origin.x < displays[$1].frame.origin.x }
    var names = displays.map(\.name)
    for name in Set(names) where names.filter({ $0 == name }).count > 1 {
        let same = order.filter { displays[$0].name == name }
        for (position, index) in same.enumerated() {
            names[index] = "\(name) (\(same.count == 2 ? (position == 0 ? "left" : "right") : String(position + 1)))"
        }
    }
    return names.map { $0.isEmpty ? "Display" : $0 }
}

/// Binds the open Saved Layout to one display in an exact display set. It stores the choice, shows whether
/// the set is connected now, and holds the two switches for automatic Apply.
struct DisplayTriggerCard: View {
    @Bindable var editor: SavedLayoutEditor
    let store: DisplayTriggerStore
    /// Nil in previews and tests without a running model. Apply Now then stays hidden.
    var model: BetterTileModel? = nil
    var readDisplays: @MainActor () -> [LiveDisplay] = { DisplayFingerprintReader.current() }
    /// Apply on the bound display through the page's Apply group. Without it, Apply is unavailable.
    var onApply: ((DisplayID) -> Void)? = nil
    @State private var live: [LiveDisplay] = []
    @State private var replacement: Replacement?

    private func apply(_ display: DisplayID) {
        onApply?(display)
    }
    @State private var removal = false
    @State private var currentTarget: Int?

    private struct Replacement: Identifiable {
        let id = UUID()
        var trigger: DisplayTrigger
        var otherFile: String
        var otherName: String
    }

    private var layoutFile: String? { editor.url?.lastPathComponent }
    private var trigger: DisplayTrigger? { layoutFile.flatMap(store.trigger(for:)) }
    private var liveSet: [DisplayFingerprint] { live.map(\.fingerprint) }
    private var liveNames: [String] { displayTriggerNames(liveSet) }

    private func layoutName(_ file: String) -> String {
        editor.entries.first { $0.lastPathComponent == file }.flatMap { editor.entryNames[$0] } ?? file
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            card
            missingLayouts
        }
        .font(SettingsFont.body)
        .onAppear { live = readDisplays() }
        .onChange(of: layoutFile) { currentTarget = nil }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            live = readDisplays()
            currentTarget = nil
        }
        .alert("Replace the other layout?", isPresented: Binding(get: { replacement != nil }, set: { if !$0 { replacement = nil } }),
               presenting: replacement) { value in
            Button("Cancel", role: .cancel) { replacement = nil }
            Button("Replace") { store.bind(value.trigger, replacing: value.otherFile); replacement = nil }
        } message: { value in
            Text("“\(value.otherName)” is already bound to this display in these displays. A display has one layout. Replacing it removes only that binding. Both layout files stay.")
        }
        .alert("Remove this display binding?", isPresented: $removal) {
            Button("Cancel", role: .cancel) { }
            Button("Remove", role: .destructive) { if let layoutFile { store.remove(layoutFile) } }
        } message: {
            Text("The layout file stays. The saved display identities for this binding are deleted from this Mac.")
        }
    }


    // MARK: Card

    private var card: some View {
        SettingsGroup("Displays") {
            VStack(alignment: .leading, spacing: 12) {
                if let error = store.loadError {
                    header(subtitle: "Display Triggers.json can’t be used.")
                    notice("Saved display bindings are unavailable", error, warning: true)
                    HStack {
                        Button("Reload") { store.load() }
                        Button("Reveal File") { NSWorkspace.shared.activateFileViewerSelecting([store.url]) }
                    }
                } else if layoutFile == nil {
                    header(subtitle: "Save this layout to a file before binding it to displays.")
                } else if let trigger {
                    bound(trigger)
                } else {
                    unbound
                }
                if let message = store.message, store.loadError == nil { notice("Couldn’t update display bindings", message, warning: true) }
            }
            .padding(SettingsSpacing.s3).frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Display set for this layout")
        } footer: {
            VStack(alignment: .leading, spacing: SettingsSpacing.s2) {
                HelpText("Exact set: these displays and no others.")
                if layoutFile != nil, trigger == nil, store.loadError == nil, !live.isEmpty {
                    HelpText("Bind this layout to one display in the displays that are connected now: \(liveNames.joined(separator: " + ")).")
                }
                if model?.hasAccessibilityPermission == false, trigger?.enabled == true {
                    HelpText("Automatic Apply needs Accessibility access. It stays idle until you allow it.")
                }
                GroupFooter(help: "BetterTile saves each bound display’s identity (UUID, vendor, model, serial, and name) in Display Triggers.json on this Mac only. Export never includes it.")
            }
        }
    }

    private func header(subtitle: String, status: (String, Color)? = nil) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Use current displays").font(SettingsFont.body.weight(.semibold))
                Text(subtitle).font(SettingsFont.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if let status {
                SettingsPill(status.0, tint: status.1)
            }
        }
    }

    private func notice(_ title: String, _ text: String, warning: Bool) -> some View {
        NoticeBanner(warning ? .warning : .info, title: title, message: text)
    }

    private var unbound: some View {
        VStack(alignment: .leading, spacing: 12) {
            header(subtitle: "Not bound to a display set. Choose a display below to bind this layout. Apply still works.")
            if live.isEmpty {
                Text("No connected display could be identified.").font(SettingsFont.body).foregroundStyle(.secondary)
            } else {
                DisplaySetPicture(displays: liveSet, names: liveNames, target: currentTarget,
                                  layoutName: editor.document?.name ?? "This layout", others: [:], connected: true,
                                  selectTarget: { currentTarget = $0 })
                HStack { Spacer(); useCurrentDisplays() }.frame(minHeight: SettingsMetrics.rowMinHeight)
            }
        }
    }

    private var currentTargetIndex: Int? {
        if let trigger, let index = DisplaySetMatcher.match(stored: trigger.displays, live: liveSet).pairs[trigger.target] { return index }
        return currentTarget.flatMap { live.indices.contains($0) ? $0 : nil }
    }

    private func useCurrentDisplays() -> some View {
        Button("Use Current Displays") { if let target = currentTargetIndex { bindToCurrent(target: target) } }
            .disabled(currentTargetIndex == nil || editor.hasInvalidSource)
            .help("Bind this layout to the connected displays. Click a display to choose where it applies.")
    }

    private func bound(_ trigger: DisplayTrigger) -> some View {
        let match = DisplaySetMatcher.match(stored: trigger.displays, live: liveSet)
        let names = displayTriggerNames(trigger.displays)
        let setName = trigger.displays.indices.sorted { trigger.displays[$0].frame.origin.x < trigger.displays[$1].frame.origin.x }
            .map { names[$0] }.joined(separator: " + ")
        let status: (String, Color) = switch match.kind {
        case .exact: ("Connected now", SettingsColor.green)
        case .uncertain: ("Can’t tell the two displays apart", SettingsColor.orange)
        case .none: ("Not connected", .secondary)
        }
        return VStack(alignment: .leading, spacing: 12) {
            if match.kind != .exact {
                SettingsPill(status.0, tint: status.1)
            }
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 16) {
                    left(trigger, match, names).frame(width: 200)
                    right(trigger, match, setName).frame(width: 320)
                }
                VStack(alignment: .leading, spacing: 16) { left(trigger, match, names); right(trigger, match, setName) }
            }
        }
    }

    private func left(_ trigger: DisplayTrigger, _ match: DisplaySetMatch, _ names: [String]) -> some View {
        DisplaySetPicture(displays: trigger.displays, names: names, target: trigger.target,
                          layoutName: editor.document?.name ?? "This layout",
                          others: others(of: trigger), connected: match.kind != .none,
                          selectTarget: { index in selectTarget(index, in: trigger) })
            .disabled(editor.hasInvalidSource)
    }

    private func right(_ trigger: DisplayTrigger, _ match: DisplaySetMatch, _ setName: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsRow("Use current displays", caption: "Binds “\(editor.document?.name ?? "This layout")” to \(liveNames.joined(separator: " + ")). Click a display to choose where it applies.") {
                useCurrentDisplays()
            }
            .padding(.horizontal, -SettingsSpacing.s3)
            SettingsSeparator()
            automaticSwitch("Apply when these displays connect",
                            "BetterTile applies it, or offers it, when this exact set connects.",
                            isOn: Binding(get: { trigger.enabled }, set: { value in update { $0.enabled = value } }))
            SettingsSeparator()
            automaticSwitch("Also after wake", "Runs again when the Mac wakes with these displays.",
                            isOn: Binding(get: { trigger.alsoAfterWake }, set: { value in update { $0.alsoAfterWake = value } }),
                            disabled: !trigger.enabled)
            if match.kind == .uncertain {
                notice("Will ask before applying", "These displays report no serial number, or the same one. BetterTile tells them apart by position only, so it will show an Apply button instead of applying on its own.", warning: true)
            } else if match.kind == .none {
                notice("Waiting for these displays", "This layout is bound to \(displayTriggerNames(trigger.displays)[trigger.target]). The binding matches only when \(setName) are all connected and nothing else is.", warning: false)
            }
            SettingsSeparator()
            if let model, let run = lastRun(trigger, match: match) {
                let automatic = model.displayTriggerRuntime?.runs[trigger.layoutFile]?.date == run.date
                DisplayTriggerLastRun(run: run, applier: model.savedLayoutApplier,
                                      canApply: model.hasAccessibilityPermission && !editor.hasInvalidSource && match.kind != .none
                                          && (automatic || onApply != nil)) {
                    if automatic { model.displayTriggerRuntime?.applyNow(trigger.layoutFile) }
                    else if let index = match.pairs[trigger.target] { apply(live[index].id) }
                }
            } else {
                SettingsRow("Last run", caption: "\(editor.document?.name ?? "This layout") · Not applied yet") {
                    Button("Apply") {
                        if let index = match.pairs[trigger.target] { apply(live[index].id) }
                    }
                    .disabled(match.kind == .none || model?.hasAccessibilityPermission != true || editor.hasInvalidSource || onApply == nil)
                }
                .padding(.horizontal, -SettingsSpacing.s3)
            }
            HStack {
                Spacer()
                Button("Remove", role: .destructive) { removal = true }.accessibilityLabel("Remove display binding")
            }
            .frame(minHeight: SettingsMetrics.rowMinHeight)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The newer of the automatic run for this binding and an Apply of this layout on its target display
    /// (from this card or the page). Both are kept in memory only.
    private func lastRun(_ trigger: DisplayTrigger, match: DisplaySetMatch) -> SavedLayoutRun? {
        let automatic = model?.displayTriggerRuntime?.runs[trigger.layoutFile]
        var manual: SavedLayoutRun?
        if let run = model?.savedLayoutApplier?.lastRun, run.layoutName == editor.document?.name,
           let index = match.pairs[trigger.target], live.indices.contains(index), live[index].id == run.displayID {
            manual = run
        }
        return [automatic, manual].compactMap { $0 }.max { $0.date < $1.date }
    }

    private func automaticSwitch(_ title: String, _ caption: String, isOn: Binding<Bool>, disabled: Bool = false) -> some View {
        SettingsRow(title, caption: caption) {
            Toggle(title, isOn: isOn).labelsHidden()
                .toggleStyle(.switch).disabled(disabled || editor.hasInvalidSource)
                .accessibilityLabel(title)
        }
        .padding(.horizontal, -SettingsSpacing.s3)
    }

    /// The layout names bound to the other displays of the same set.
    private func others(of trigger: DisplayTrigger) -> [Int: String] {
        var result: [Int: String] = [:]
        for other in store.document.triggers where other.layoutFile != trigger.layoutFile {
            let match = DisplaySetMatcher.match(stored: other.displays, live: trigger.displays)
            if match.kind != .none, let index = match.pairs[other.target], index != trigger.target {
                result[index] = layoutName(other.layoutFile)
            }
        }
        return result
    }

    private func update(_ change: (inout DisplayTrigger) -> Void) {
        guard let layoutFile else { return }
        store.update(layoutFile, change)
    }

    private func selectTarget(_ index: Int, in trigger: DisplayTrigger) {
        guard trigger.displays.indices.contains(index) else { return }
        if let other = store.document.conflict(displays: trigger.displays, target: index, excluding: trigger.layoutFile) {
            var value = trigger
            value.target = index
            replacement = Replacement(trigger: value, otherFile: other.layoutFile, otherName: layoutName(other.layoutFile))
        } else { update { $0.target = index } }
        if let liveIndex = DisplaySetMatcher.match(stored: trigger.displays, live: liveSet).pairs[index] {
            currentTarget = liveIndex
        }
    }

    private func bindToCurrent(target: Int) {
        guard let layoutFile else { return }
        if case let .needsReplacement(value, other) = store.bindCurrent(layoutFile: layoutFile, displays: liveSet, target: target) {
            replacement = Replacement(trigger: value, otherFile: other, otherName: layoutName(other))
        }
    }

    // MARK: Triggers whose layout file is gone

    @ViewBuilder private var missingLayouts: some View {
        let missing = store.document.triggers.filter {
            !FileManager.default.fileExists(atPath: editor.files.directory.appendingPathComponent($0.layoutFile).path)
        }
        if !missing.isEmpty {
            SettingsGroup("Display bindings without a layout") {
                ForEach(missing, id: \.layoutFile) { trigger in
                    HStack {
                        Label("Layout missing · \(displayTriggerNames(trigger.displays).joined(separator: " + "))", systemImage: "exclamationmark.triangle")
                            .font(SettingsFont.body).lineLimit(2)
                        Spacer()
                        Button("Remove") { store.remove(trigger.layoutFile) }
                            .accessibilityLabel("Remove binding for missing layout file \(trigger.layoutFile)")
                    }
                    .padding(.horizontal, SettingsSpacing.s3)
                    .padding(.vertical, 6)
                    .frame(minHeight: SettingsMetrics.rowMinHeight)
                }
            }
        }
    }
}

/// A to-scale picture of the stored display set. The target display is highlighted.
struct DisplaySetPicture: View {
    let displays: [DisplayFingerprint]
    let names: [String]
    let target: Int?
    let layoutName: String
    let others: [Int: String]
    let connected: Bool
    var selectTarget: ((Int) -> Void)? = nil

    private var bounds: CGRect {
        displays.map { CGRect(x: $0.frame.origin.x, y: $0.frame.origin.y, width: $0.frame.size.width, height: $0.frame.size.height) }
            .reduce(CGRect.null) { $0.union($1) }
    }

    private func caption(_ index: Int) -> String {
        connected ? "Connected" : "Not connected"
    }

    var body: some View {
        let box = bounds
        let aspect = box.isNull || box.height <= 0 ? 2.6 : min(4, max(1.2, box.width / box.height))
        GeometryReader { proxy in
            let scale = min(proxy.size.width / max(1, box.width), proxy.size.height / max(1, box.height))
            let inset = CGSize(width: (proxy.size.width - box.width * scale) / 2, height: (proxy.size.height - box.height * scale) / 2)
            ZStack(alignment: .topLeading) {
                ForEach(displays.indices, id: \.self) { index in
                    let frame = displays[index].frame
                    let isTarget = index == target
                    // Typed parts keep this expression within Swift 6.3's type-check limit.
                    let detail: String = isTarget ? "This layout · \(layoutName)" : others[index] ?? ""
                    let width: CGFloat = CGFloat(frame.size.width) * scale
                    let height: CGFloat = CGFloat(frame.size.height) * scale
                    let x: CGFloat = inset.width + (CGFloat(frame.origin.x) - box.minX) * scale
                    let top: CGFloat = inset.height + (CGFloat(frame.origin.y) - box.minY) * scale
                    let y: CGFloat = max(0, min(proxy.size.height - max(80, height), top))
                    Button { selectTarget?(index) } label: {
                        DisplaySetTile(name: names[index], caption: caption(index), isTarget: isTarget, connected: connected,
                                       detail: detail, width: width, height: height)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Choose \(names[index]) for \(layoutName)")
                    .opacity(connected ? 1 : 0.7)
                    .offset(x: x, y: y)
                }
            }
        }
        .aspectRatio(aspect, contentMode: .fit)
        .frame(minHeight: 112)
        .frame(maxWidth: 360, maxHeight: 150)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Display set picture")
        .accessibilityValue(displays.indices.map { index in
            "\(names[index])\(index == target ? ", this layout" : "")\(connected ? "" : ", not connected")"
        }.joined(separator: "; "))
    }
}

/// The display picture's label, hosted independently by rendered regression tests.
struct DisplaySetTile: View {
    let name: String
    let caption: String
    let isTarget: Bool
    let connected: Bool
    let detail: String
    let width: CGFloat
    let height: CGFloat
    private let tileRadius = SettingsRadius.inner

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Spacer(minLength: 0)
            // Two name lines plus two status lines fit within the 80 pt tile. The tooltip carries the full name.
            Text(name).font(SettingsFont.caption.weight(.semibold)).lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            let text = caption
            if !text.isEmpty {
                Text(text).font(SettingsFont.caption).foregroundStyle(isTarget ? Color.accentColor : .secondary)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
        }
        .help([name, caption, detail].filter { !$0.isEmpty }.joined(separator: " · "))
        .padding(8)
        .frame(width: width, height: max(80, height), alignment: .bottomLeading)
        .background(isTarget ? Color.accentColor.opacity(0.14) : Color(nsColor: .quaternarySystemFill), in: RoundedRectangle.settings(tileRadius))
        .overlay(RoundedRectangle.settings(tileRadius)
            .strokeBorder(isTarget ? Color.accentColor : Color(nsColor: .separatorColor),
                          style: StrokeStyle(lineWidth: 1.5, dash: connected ? [] : [4, 3])))
    }
}

/// The newest automatic result for one layout: when it ran, what it placed, what it skipped, and Undo.
/// It lives in memory only, like the Last run row on the Apply bar.
struct DisplayTriggerLastRun: View {
    let run: SavedLayoutRun
    let applier: SavedLayoutApplier?
    var canApply = true
    var apply: () -> Void = {}

    private var statusColor: Color {
        switch run.status {
        case .applied: SettingsColor.green
        case .cancelled: .secondary
        case .offered: .accentColor
        case .notApplied: SettingsColor.orange
        }
    }

    var statusPill: some View { SettingsPill(run.status.rawValue, tint: statusColor) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Last run").font(SettingsFont.body.weight(.medium))
                    Text("\(run.layoutName) · \(run.presentation.summary)").font(SettingsFont.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }.frame(maxWidth: .infinity, alignment: .leading)
                statusPill
                Button("Apply", action: apply).disabled(!canApply || applier?.isRunning == true)
                    .accessibilityLabel("Apply \(run.layoutName) now")
                    .help("Place the apps of this layout now. It does not open apps.")
            }
            .frame(minHeight: SettingsMetrics.rowMinHeight)
            // The reason is the point of a run that did not start, so it is not left in the collapsed Details.
            if run.status == .notApplied || run.status == .cancelled || run.status == .offered, let reason = run.presentation.issues.first?.message {
                Text(reason).font(SettingsFont.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if !run.presentation.issues.isEmpty {
                DisclosureGroup("Details") {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(run.presentation.issues.enumerated()), id: \.offset) { _, issue in
                            Label(issue.message, systemImage: "exclamationmark.triangle")
                                .font(SettingsFont.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .font(SettingsFont.caption)
            }
            if run.offersUndo, let applier, applier.hasUndo {
                Button("Undo") { applier.startUndo(displayID: run.displayID) }
                    .disabled(!applier.canUndo(on: run.displayID))
                    .accessibilityLabel("Undo the last automatic Apply of \(run.layoutName)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .font(SettingsFont.body)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Last automatic run, \(run.status.rawValue)")
    }
}
