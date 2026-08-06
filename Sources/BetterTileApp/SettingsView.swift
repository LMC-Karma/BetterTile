// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 LMC-Karma
// Contains portions adapted from Vorssaint, Copyright (C) 2026 Vorssaint.

import AppKit
import BetterTileCore
import SwiftUI

private enum SettingsDestination: String, CaseIterable, Identifiable {
    case general = "General"
    case windowLayout = "Window Layout"
    case snapZones = "Snap Zones"
    case applicationRules = "Per-App Rules"

    var id: Self { self }

    var icon: String {
        switch self {
        case .general: "gearshape"
        case .windowLayout: "rectangle.3.group"
        case .snapZones: "rectangle.split.3x3"
        case .applicationRules: "app.badge.checkmark"
        }
    }

    var keywords: String {
        switch self {
        case .general:
            "permission accessibility dock appearance light dark system drag snapping application update automatic check "
                + "keyboard shortcuts master toggle macos tiling move resize edge "
                + "advanced enhanced user interface chromium electron voiceover"
        case .windowLayout:
            "mode manual native bento resize linked divider shortcut keyboard hotkey halves thirds quarters sixths move display restore"
        case .snapZones:
            "drag snap custom zone edge corner title bar double click maximize"
        case .applicationRules:
            "app application rule exclude ignore bento manage per-app exception skip leave alone"
        }
    }
}

struct SettingsView: View {
    @Bindable var model: BetterTileModel
    @Binding var automaticallyChecksForUpdates: Bool
    let checkForUpdates: () -> Void
    let openSetup: () -> Void
    @State private var selection: SettingsDestination = .general
    @State private var search = ""

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                searchField
                List(selection: $selection) {
                    destinationSection("Essentials", destinations: [.general])
                    destinationSection(
                        "Window Management",
                        destinations: [.windowLayout, .snapZones]
                    )
                    destinationSection("Advanced", destinations: [.applicationRules])
                }
                .listStyle(.sidebar)
            }
            .navigationSplitViewColumnWidth(min: 198, ideal: 210, max: 240)
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .navigationTitle(selection.rawValue)
                .background(Color(nsColor: .windowBackgroundColor))
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 820, minHeight: 560)
    }

    private var searchField: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search settings", text: $search)
                .textFieldStyle(.plain)
                .onExitCommand { search = "" }
            if !search.isEmpty {
                Button {
                    search = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 7)
        .background(.quaternary.opacity(0.5), in: Capsule())
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private func destinationSection(
        _ title: String,
        destinations: [SettingsDestination]
    ) -> some View {
        let matches = destinations.filter(matchesSearch)
        if !matches.isEmpty {
            Section(title) {
                ForEach(matches) { destination in
                    Label(destination.rawValue, systemImage: destination.icon)
                        .tag(destination)
                }
            }
        }
    }

    private func matchesSearch(_ destination: SettingsDestination) -> Bool {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return query.isEmpty
            || destination.rawValue.lowercased().contains(query)
            || destination.keywords.contains(query)
    }

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .general:
            GeneralSettings(
                model: model,
                automaticallyChecksForUpdates: $automaticallyChecksForUpdates,
                checkForUpdates: checkForUpdates,
                openSetup: openSetup
            )
        case .windowLayout:
            WindowLayoutSettings(model: model)
        case .snapZones:
            ZoneSettings(model: model)
        case .applicationRules:
            ApplicationRuleSettings(model: model)
        }
    }
}

private struct GeneralSettings: View {
    @Bindable var model: BetterTileModel
    @Binding var automaticallyChecksForUpdates: Bool
    let checkForUpdates: () -> Void
    let openSetup: () -> Void
    @AppStorage(AppAppearance.defaultsKey) private var appearanceRawValue = AppAppearance.system.rawValue

    var body: some View {
        Form {
            Section("Permissions") {
                AccessibilityPermissionStatus(model: model)

                if !model.hasAccessibilityPermission {
                    Text(
                        "Grant access once to a consistently signed BetterTile build. "
                            + "The app checks automatically when you return from System Settings."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    HStack {
                        Button("Request Access…") { model.requestAccessibilityPermission() }
                        Button("Open Accessibility Settings") { model.openAccessibilitySettings() }
                        Button("Check Again") { model.recheckAccessibilityPermission() }
                    }
                }

                Text(
                    "BetterTile uses public Accessibility APIs and requests no Screen Recording "
                        + "or private entitlement."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                Button("Open Setup Assistant…", action: openSetup)
#if DEBUG
                Label(
                    "Use an Apple Development Personal Team for permission persistence across rebuilds.",
                    systemImage: "hammer"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
#endif
            }

            Section("BetterTile Features") {
                // Two independent switches. Either can be off without the other
                // being affected, and neither discards what it turns off.
                Toggle(
                    "BetterTile Keyboard Shortcuts",
                    isOn: configurationBinding(\.keyboardShortcutsEnabled)
                )
                Text("Turning these off keeps every shortcut you have set, ready for when you turn them back on.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("BetterTile Drag Snapping", isOn: configurationBinding(\.snappingEnabled))
                Text("Turning this off keeps your snap zones. Use it if you would rather drag windows with macOS's own edge tiling.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Application") {
                Toggle("Show Dock icon", isOn: configurationBinding(\.showDockIcon))
                Toggle("Automatically check for updates", isOn: $automaticallyChecksForUpdates)
                Button("Check for Updates…", action: checkForUpdates)
            }

            Section("BetterTile and macOS Window Tiling") {
                Text(
                    "macOS has its own window tiling, and BetterTile is built to sit alongside it rather than replace it."
                )
                .font(.callout)
                Text(
                    "Window ▸ Move & Resize and its keyboard equivalents keep working. "
                        + "Bento recognises where macOS put a window and adopts that arrangement, "
                        + "so you can tile with either and carry on with BetterTile's dividers."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                Text(
                    "Dragging is the one place they overlap. macOS and BetterTile both interpret a drag to a screen edge, "
                        + "so pick one: leave BetterTile Drag Snapping on, or turn it off and use macOS's edge tiling. "
                        + "Bento adopts the result either way."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("Appearance") {
                Picker("Appearance", selection: appearanceBinding) {
                    ForEach(AppAppearance.allCases) { appearance in
                        Text(appearance.title).tag(appearance)
                    }
                }
                .pickerStyle(.segmented)
                Text("System follows the current macOS appearance.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Advanced") {
                Picker(
                    "Enhanced accessibility",
                    selection: configurationBinding(\.enhancedUserInterfacePolicy)
                ) {
                    ForEach(EnhancedUserInterfacePolicy.allCases, id: \.self) { policy in
                        Text(policy.title).tag(policy)
                    }
                }
                Text(
                    "Some apps reinterpret window positions while enhanced accessibility is on, "
                        + "so BetterTile turns it off while it moves a window. "
                        + model.configuration.enhancedUserInterfacePolicy.explanation
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            StatusMessage(model: model)
        }
        .formStyle(.grouped)
    }

    private var appearanceBinding: Binding<AppAppearance> {
        Binding(
            get: { AppAppearance(rawValue: appearanceRawValue) ?? .system },
            set: { appearance in
                appearanceRawValue = appearance.rawValue
                AppAppearance.apply(appearance)
            }
        )
    }

    private func configurationBinding<Value>(
        _ keyPath: WritableKeyPath<BetterTileConfiguration, Value>
    ) -> Binding<Value> {
        Binding(
            get: { model.configuration[keyPath: keyPath] },
            set: { value in
                model.updateConfiguration { $0[keyPath: keyPath] = value }
            }
        )
    }
}

private struct WindowLayoutSettings: View {
    @Bindable var model: BetterTileModel
    @State private var recordingAction: WindowAction?

    var body: some View {
        Form {
            Section("Window Mode") {
                HStack(spacing: 12) {
                    ForEach(LayoutMode.availableModes, id: \.self) { mode in
                        modeCard(mode)
                    }
                }
                LabeledContent("Current context", value: model.activeContextDescription)
                Picker("Default mode", selection: configurationBinding(\.defaultLayoutMode)) {
                    ForEach(LayoutMode.availableModes, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                Picker(
                    "When a desktop has one window",
                    selection: configurationBinding(\.singleWindowPlacement)
                ) {
                    Text("Leave Unchanged").tag(nil as WindowAction?)
                    ForEach(WindowAction.snapAssignableActions) { action in
                        Text(action.title).tag(Optional(action))
                    }
                }
                Text(
                    "Applied each time a desktop is left with a single window. After that the window "
                        + "keeps whatever size you give it, until another window opens or you repair the layout."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("Resize Interaction") {
                Toggle(
                    "Resize adjacent windows together",
                    isOn: configurationBinding(\.linkedResizeEnabled)
                )
                Text(
                    "When windows share an edge, resizing one adjusts its neighbor. "
                        + "Available in Manual mode only."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                Picker("Window feedback", selection: configurationBinding(\.resizeFeedbackMode)) {
                    Text("Ghost Preview").tag(ResizeFeedbackMode.ghost)
                    Text("Live Resize").tag(ResizeFeedbackMode.live)
                }
                .pickerStyle(.segmented)
                HStack {
                    Text("Divider width")
                    Slider(
                        value: configurationBinding(\.dividerThickness),
                        in: 2...12,
                        step: 1
                    )
                    Text("\(Int(model.configuration.dividerThickness)) pt")
                        .monospacedDigit()
                        .frame(width: 42)
                }
                Text("A glass handle appears when the pointer approaches a valid shared edge.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Bento Behavior") {
                HStack {
                    Text("Pane gap")
                    Slider(value: configurationBinding(\.bentoInnerGap), in: 0...12, step: 1)
                    Text("\(Int(model.configuration.bentoInnerGap)) pt")
                        .monospacedDigit()
                        .frame(width: 42)
                }
                HStack {
                    Text("Bento swap delay")
                    Slider(
                        value: configurationBinding(\.bentoSwapHoverDelay),
                        in: 0...1,
                        step: 0.01
                    )
                    Text(
                        model.configuration.bentoSwapHoverDelay
                            .formatted(.number.precision(.fractionLength(2))) + "s"
                    )
                    .monospacedDigit()
                    .frame(width: 48)
                }
                Text(
                    "Bento swapping starts only when dragging from a window title bar. "
                        + "Resizing from an edge does not activate a swap target."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("Shortcuts") {
                Text(
                    "Click an action to try it. Select its shortcut to record a replacement; "
                        + "duplicate combinations are rejected."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            ForEach(WindowActionGroup.allCases) { group in
                Section(group.title) {
                    ForEach(group.actions) { action in
                        ShortcutActionRow(
                            model: model,
                            action: action,
                            isRecording: recordingAction == action
                        ) {
                            model.setShortcutCaptureActive(true)
                            recordingAction = action
                        }
                    }
                }
            }

            StatusMessage(model: model)
        }
        .formStyle(.grouped)
        .background {
            InlineKeyCaptureView(
                isRecording: Binding(
                    get: { recordingAction != nil },
                    set: { if !$0 { recordingAction = nil } }
                ),
                capture: { captured in
                    guard let recordingAction else { return }
                    model.assign(shortcut: captured, to: recordingAction)
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

    private func modeCard(_ mode: LayoutMode) -> some View {
        Button {
            model.setActiveMode(mode)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: mode.icon)
                    .font(.title2)
                    .foregroundStyle(
                        model.activeLayoutMode == mode ? Color.accentColor : Color.secondary
                    )
                Text(mode.title)
                    .font(.headline)
                Text(mode.explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: 102, alignment: .topLeading)
            .padding(14)
            .background(
                model.activeLayoutMode == mode
                    ? Color.accentColor.opacity(0.12)
                    : Color.secondary.opacity(0.06),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(
                        model.activeLayoutMode == mode
                            ? Color.accentColor
                            : Color.secondary.opacity(0.18)
                    )
            )
        }
        .buttonStyle(.plain)
    }

    private func configurationBinding<Value>(
        _ keyPath: WritableKeyPath<BetterTileConfiguration, Value>
    ) -> Binding<Value> {
        Binding(
            get: { model.configuration[keyPath: keyPath] },
            set: { value in
                model.updateConfiguration { $0[keyPath: keyPath] = value }
            }
        )
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
        HStack(spacing: 8) {
            Button {
                model.perform(action)
            } label: {
                HStack(spacing: 7) {
                    WindowActionGlyph(action: action)
                    Text(action.title)
                        .lineLimit(1)
                }
                .frame(minWidth: 145, alignment: .leading)
            }
            .disabled(!model.hasAccessibilityPermission)

            Spacer()

            Button(action: beginRecording) {
                Text(isRecording ? "Press keys…" : shortcut?.displayText ?? "None")
                    .font(.system(.body, design: .rounded))
                    .lineLimit(1)
                    .frame(width: 100)
            }

            Button {
                model.assign(shortcut: nil, to: action)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .disabled(shortcut == nil)
            .help("Clear shortcut")

            Button("Reset") {
                model.assign(shortcut: defaultShortcut, to: action)
            }
            .disabled(shortcut == defaultShortcut)
        }
        .padding(.vertical, 2)
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

private final class InlineKeyCaptureNSView: NSView {
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

private struct ZoneSettings: View {
    @Bindable var model: BetterTileModel

    var body: some View {
        Form {
            Section("Screen Edge Actions") {
                ForEach(SnapArea.allCases) { area in
                    HStack {
                        Text(area.title)
                        Spacer()
                        Picker("", selection: snapActionBinding(area)) {
                            Text("Disabled").tag(nil as WindowAction?)
                            ForEach(WindowAction.snapAssignableActions) { action in
                                Text(action.title).tag(Optional(action))
                            }
                        }
                        .labelsHidden()
                        .frame(width: 210)
                    }
                }
                HStack {
                    Text(
                        "Edges activate only when the pointer reaches the display edge. "
                            + "Hold the suppression modifier to bypass snapping."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    Spacer()
                    Button("Restore Defaults") {
                        model.updateConfiguration {
                            $0.snapAreaBindings = BetterTileConfiguration.defaultSnapAreaBindings
                        }
                    }
                }
            }

            Section("Window Top") {
                Toggle(
                    "Double-click the top of a window to maximize or restore",
                    isOn: configurationBinding(\.doubleClickTitleBarToMaximize)
                )
                Text(
                    "Choose Maximize in System Settings › Desktop & Dock for native handling, "
                        + "or Do Nothing to let BetterTile provide maximize and restore."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("Custom Zones") {
                HStack {
                    Text(
                        "Coordinates are normalized from 0 to 1 within a display’s visible frame."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    Spacer()
                    Button("Add Zone") {
                        model.updateConfiguration {
                            $0.customZones.append(
                                CustomZone(
                                    name: "New Zone",
                                    rect: NormalizedRect(
                                        x: 0.1,
                                        y: 0.1,
                                        width: 0.8,
                                        height: 0.8
                                    )
                                )
                            )
                        }
                    }
                }
                ForEach(model.configuration.customZones) { zone in
                    HStack {
                        TextField("Name", text: zoneBinding(zone, \.name))
                        normalizedField("X", zone, \.x)
                        normalizedField("Y", zone, \.y)
                        normalizedField("W", zone, \.width)
                        normalizedField("H", zone, \.height)
                        Button(role: .destructive) {
                            model.updateConfiguration { configuration in
                                configuration.customZones.removeAll { $0.id == zone.id }
                            }
                        } label: {
                            Image(systemName: "trash")
                        }
                    }
                    .padding(.vertical, 2)
                }
            }

            StatusMessage(model: model)
        }
        .formStyle(.grouped)
    }

    private func snapActionBinding(_ area: SnapArea) -> Binding<WindowAction?> {
        Binding(
            get: {
                model.configuration.snapAreaBindings
                    .first(where: { $0.area == area })?
                    .action
            },
            set: { action in
                model.updateConfiguration { configuration in
                    guard let index = configuration.snapAreaBindings
                        .firstIndex(where: { $0.area == area })
                    else { return }
                    configuration.snapAreaBindings[index].action = action
                }
            }
        )
    }

    private func configurationBinding<Value>(
        _ keyPath: WritableKeyPath<BetterTileConfiguration, Value>
    ) -> Binding<Value> {
        Binding(
            get: { model.configuration[keyPath: keyPath] },
            set: { value in
                model.updateConfiguration { $0[keyPath: keyPath] = value }
            }
        )
    }

    private func zoneBinding<Value>(
        _ zone: CustomZone,
        _ keyPath: WritableKeyPath<CustomZone, Value>
    ) -> Binding<Value> {
        Binding(
            get: {
                model.configuration.customZones
                    .first(where: { $0.id == zone.id })?[keyPath: keyPath]
                    ?? zone[keyPath: keyPath]
            },
            set: { value in
                model.updateConfiguration { configuration in
                    guard let index = configuration.customZones
                        .firstIndex(where: { $0.id == zone.id })
                    else { return }
                    configuration.customZones[index][keyPath: keyPath] = value
                }
            }
        )
    }

    private func normalizedField(
        _ label: String,
        _ zone: CustomZone,
        _ keyPath: WritableKeyPath<NormalizedRect, Double>
    ) -> some View {
        HStack(spacing: 3) {
            Text(label)
                .font(.caption)
            TextField(
                label,
                value: normalizedBinding(zone, keyPath),
                format: .number.precision(.fractionLength(2))
            )
            .frame(width: 48)
        }
    }

    private func normalizedBinding(
        _ zone: CustomZone,
        _ keyPath: WritableKeyPath<NormalizedRect, Double>
    ) -> Binding<Double> {
        Binding(
            get: {
                model.configuration.customZones
                    .first(where: { $0.id == zone.id })?
                    .rect[keyPath: keyPath]
                    ?? zone.rect[keyPath: keyPath]
            },
            set: { value in
                model.updateConfiguration { configuration in
                    guard let index = configuration.customZones
                        .firstIndex(where: { $0.id == zone.id })
                    else { return }
                    configuration.customZones[index].rect[keyPath: keyPath] = value
                }
            }
        )
    }
}

private struct StatusMessage: View {
    @Bindable var model: BetterTileModel

    var body: some View {
        if let message = model.statusMessage {
            Label(message, systemImage: "info.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

private extension LayoutMode {
    var icon: String {
        switch self {
        case .manual: "macwindow"
        case .linked: "arrow.left.and.right"
        case .bento: "rectangle.split.2x2"
        }
    }

    var explanation: String {
        switch self {
        case .manual: "Use macOS windows with BetterTile snapping."
        case .linked: "Adjacent snapped windows share resize boundaries."
        case .bento: "Windows join a stable adaptive split layout."
        }
    }
}

private struct ApplicationRuleSettings: View {
    @Bindable var model: BetterTileModel
    @State private var isPickingApplication = false

    var body: some View {
        Form {
            Section {
                if model.ruledApplications.isEmpty {
                    Text("Every app is managed normally. Add one to give it a rule.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.ruledApplications, id: \.bundleIdentifier) { entry in
                        HStack {
                            ApplicationIcon(bundleIdentifier: entry.bundleIdentifier)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.name)
                                Text(entry.bundleIdentifier)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Picker("", selection: ruleBinding(entry.bundleIdentifier)) {
                                ForEach(ApplicationRule.allCases) { rule in
                                    Text(rule.title).tag(rule)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 190)
                            Button {
                                model.clearRule(for: entry.bundleIdentifier)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("Manage this app normally again")
                        }
                        .padding(.vertical, 2)
                    }
                }
                Text("Choosing Manage Normally removes an app from this list, the same as the × button.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                HStack {
                    Text("Apps With Rules")
                    Spacer()
                    Button("Add App…") { isPickingApplication = true }
                }
            }

            Section("What The Rules Do") {
                ForEach(ApplicationRule.allCases) { rule in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(rule.title).font(.callout.weight(.medium))
                        Text(rule.explanation)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 1)
                }
                Text(
                    "Rules are remembered by app, so one stays in effect the next time you open it. "
                        + "An app that is not installed keeps its rule."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            StatusMessage(model: model)
        }
        .formStyle(.grouped)
        .sheet(isPresented: $isPickingApplication) {
            ApplicationPickerSheet(model: model)
        }
    }

    private func ruleBinding(_ bundleIdentifier: String) -> Binding<ApplicationRule> {
        Binding(
            get: { model.configuration.applicationRules.rule(for: bundleIdentifier) },
            set: { model.setRule($0, for: bundleIdentifier) }
        )
    }
}

/// An application's own icon, so a row is recognisable at a glance rather than
/// by reading a reverse-DNS identifier.
private struct ApplicationIcon: View {
    let bundleIdentifier: String

    var body: some View {
        Group {
            if let icon = BetterTileModel.applicationIcon(for: bundleIdentifier) {
                Image(nsImage: icon).resizable()
            } else {
                Image(systemName: "app.dashed")
                    .resizable()
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 24, height: 24)
    }
}

/// Picks the application a rule applies to.
///
/// Running applications cover almost every case and need no permission to
/// enumerate. Browsing exists for the rest: an app you want to exclude before
/// ever launching it cannot appear in a list of what is running.
private struct ApplicationPickerSheet: View {
    @Bindable var model: BetterTileModel
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var selection: String?

    private var candidates: [ApplicationRuleCandidate] {
        let all = model.addableApplications
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return all }
        return all.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || $0.bundleIdentifier.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add an App").font(.headline)

            TextField("Search", text: $searchText)
                .textFieldStyle(.roundedBorder)

            if candidates.isEmpty {
                VStack {
                    Spacer()
                    Text(
                        model.addableApplications.isEmpty
                            ? "Every running app already has a rule. Use Browse… for one that is not running."
                            : "No running app matches “\(searchText)”."
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                List(candidates, selection: $selection) { candidate in
                    HStack {
                        ApplicationIcon(bundleIdentifier: candidate.bundleIdentifier)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(candidate.name)
                            Text(candidate.bundleIdentifier)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .tag(candidate.bundleIdentifier)
                    .contentShape(.rect)
                }
                .listStyle(.inset)
                .alternatingRowBackgrounds()
            }

            HStack {
                Button("Browse…") { browseForApplication() }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Add") { addSelection() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selection == nil)
            }
        }
        .padding(20)
        .frame(width: 460, height: 420)
    }

    private func addSelection() {
        guard let selection else { return }
        add(bundleIdentifier: selection)
    }

    private func add(bundleIdentifier: String) {
        // Exclude from Bento rather than Manage Normally: the default rule is
        // stored as an absence, so adding an app with it would drop the row the
        // user just created.
        model.setRule(.excludeFromBento, for: bundleIdentifier)
        dismiss()
    }

    private func browseForApplication() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let candidate = model.candidate(atApplicationURL: url) else {
            model.statusMessage = "That bundle does not have an application identifier."
            return
        }
        add(bundleIdentifier: candidate.bundleIdentifier)
    }
}
