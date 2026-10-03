// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 LMC-Karma
// Contains portions adapted from Vorssaint, Copyright (C) 2026 Vorssaint.

import AppKit
import BetterTileCore
import BetterTileMacOS
import SwiftUI
import UniformTypeIdentifiers

private enum SettingsDestination: String, CaseIterable, Identifiable {
    case general = "General"
    case windowLayout = "Window Layout"
    case snapZones = "Snap Zones"
    case menuBar = "Menu Bar"
    case layoutWheel = "Layout Wheel"
    case applicationRules = "Per-App Rules"

    var id: Self { self }

    var icon: String {
        switch self {
        case .general: "gearshape"
        case .windowLayout: "rectangle.3.group"
        case .snapZones: "rectangle.split.3x3"
        case .menuBar: "line.3.horizontal"
        case .layoutWheel: "circle.hexagonpath"
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
            "mode manual native bento tabbed tabs pane preset resize linked divider appearance liquid glass transparency clear frosted shortcut keyboard hotkey halves thirds quarters sixths move display restore new window side automatic left right top bottom"
        case .snapZones:
            "drag snap edge corner title bar double click maximize"
        case .menuBar:
            "menu bar actions order visibility reorder drag restore defaults"
        case .layoutWheel:
            "wheel layout radial pie ring sector hub gesture middle click mouse button "
                + "control option shift command modifier trigger shortcut hold activation "
                + "one level two levels repair bento empty cancel"
        case .applicationRules:
            "app application rule exclude ignore bento manage per-app exception skip leave alone"
        }
    }

    var subtitle: String {
        switch self {
        case .general: "A few essentials. Everything else, just where you need it."
        case .windowLayout: "Choose how windows arrange and how shared boundaries respond."
        case .snapZones: "Choose what happens when a window reaches an edge or corner."
        case .menuBar: "Keep the actions you reach for. Arrange them your way."
        case .layoutWheel: "Put window actions around the pointer for quick access."
        case .applicationRules: "Choose which applications participate in BetterTile behavior."
        }
    }
}

struct UpdateVersionBadge: View {
    let version: String

    var body: some View {
        Text(version)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Color(nsColor: .systemBlue), in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.35), lineWidth: 0.5))
            .fixedSize()
            .accessibilityLabel("Update available, version \(version)")
    }
}

struct SettingsView: View {
    @Bindable var model: BetterTileModel
#if !DEBUG
    @Bindable var updatePresentation: UpdatePresentationModel
    @Binding var automaticallyChecksForUpdates: Bool
    let checkForUpdates: () -> Void
#endif
    let openSetup: () -> Void
    @State private var selection: SettingsDestination = .general
    @State private var search = ""
    @FocusState private var searchFocused: Bool

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                Label("BetterTile", systemImage: "rectangle.split.2x1")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 20)
                searchField
                List(selection: $selection) {
                    destinationSection("Essentials", destinations: [.general])
                    destinationSection(
                        "Window Management",
                        destinations: [.windowLayout, .snapZones, .menuBar, .layoutWheel]
                    )
                    destinationSection("Advanced", destinations: [.applicationRules])
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
                .overlay {
                    if !SettingsDestination.allCases.contains(where: matchesSearch) {
                        ContentUnavailableView.search(text: search)
                            .padding(.horizontal, 8)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 198, ideal: 210, max: 240)
        } detail: {
            Group {
                if SettingsDestination.allCases.contains(where: matchesSearch) {
                    VStack(alignment: .leading, spacing: 0) {
                        SettingsPageHeader(destination: selection)
                        detail
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }
                } else {
                    // A zero-result search must not leave an unrelated page on screen.
                    ContentUnavailableView {
                        Label("No Matching Settings", systemImage: "magnifyingglass")
                    } description: {
                        Text("No settings page matches “\(search)”.")
                    } actions: {
                        Button("Clear Search") { search = "" }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .font(.system(size: 13))
        .controlSize(.regular)
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 980, minHeight: 640)
        .onChange(of: search) {
            if !matchesSearch(selection), let match = SettingsDestination.allCases.first(where: matchesSearch) {
                selection = match
            }
        }
        .background {
            Button("Search settings") { searchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .hidden()
        }
    }

    private var searchField: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search settings", text: $search)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .accessibilityLabel("Search settings")
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
        .background(.background, in: RoundedRectangle(cornerRadius: 7))
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
                    HStack {
                        Label(destination.rawValue, systemImage: destination.icon)
                        Spacer()
#if !DEBUG
                        if destination == .general,
                           let update = updatePresentation.state.availableUpdate {
                            UpdateVersionBadge(version: update.displayVersion)
                        }
#endif
                    }
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
#if DEBUG
            GeneralSettings(model: model, openSetup: openSetup)
#else
            GeneralSettings(
                model: model,
                updatePresentation: updatePresentation,
                automaticallyChecksForUpdates: $automaticallyChecksForUpdates,
                checkForUpdates: checkForUpdates,
                openSetup: openSetup
            )
#endif
        case .windowLayout:
            WindowLayoutSettings(model: model)
        case .snapZones:
            ZoneSettings(model: model)
        case .menuBar:
            MenuBarSettings(model: model)
        case .layoutWheel:
            LayoutWheelSettings(model: model)
        case .applicationRules:
            ApplicationRuleSettings(model: model)
        }
    }
}

private struct SettingsPageHeader: View {
    let destination: SettingsDestination

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(destination.rawValue)
                .font(.system(size: 25, weight: .bold))
            Text(destination.subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 24)
        .padding(.top, 24)
        .padding(.bottom, 16)
        .accessibilityElement(children: .combine)
    }
}

private struct GeneralSettings: View {
    @Bindable var model: BetterTileModel
#if !DEBUG
    @Bindable var updatePresentation: UpdatePresentationModel
    @Binding var automaticallyChecksForUpdates: Bool
    let checkForUpdates: () -> Void
#endif
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
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    HStack {
                        Button("Request Access…") { model.requestAccessibilityPermission() }
                        Button("Open Accessibility Settings") { model.openAccessibilitySettings() }
                        Button("Check Again") { model.recheckAccessibilityPermission() }
                    }
                }

                Text(
                    "BetterTile uses public Accessibility APIs. It observes global left-button "
                        + "ordering for snapping and linked resizing. Layout Wheel observes its "
                        + "configured modifiers and limited gesture input. Its optional Middle "
                        + "Click trigger reserves unmodified middle-click system-wide while "
                        + "enabled. BetterTile requests no Screen Recording, Input Monitoring, "
                        + "or private entitlement."
                )
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                Button("Open Setup Assistant…", action: openSetup)
#if DEBUG
                Label(
                    "Use an Apple Development Personal Team for permission persistence across rebuilds.",
                    systemImage: "hammer"
                )
                .font(.system(size: 12))
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
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Toggle("BetterTile Drag Snapping", isOn: configurationBinding(\.snappingEnabled))
                Text("Turning this off keeps your snap zones. Use it if you would rather drag windows with macOS's own edge tiling.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            Section("Application") {
                Toggle("Show Dock icon", isOn: configurationBinding(\.showDockIcon))
            }

            Section("Updates") {
                HStack {
                    Text("Version")
                    Spacer()
                    Text(installedVersion)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
#if !DEBUG
                Toggle("Automatically check for updates", isOn: $automaticallyChecksForUpdates)
                if let update = updatePresentation.state.availableUpdate {
                    HStack {
                        Label("Update available", systemImage: "arrow.down.circle.fill")
                        Spacer()
                        UpdateVersionBadge(version: update.displayVersion)
                    }
                    Button("View Update…", action: checkForUpdates)
                        .accessibilityLabel("View update, version \(update.displayVersion)")
                } else {
                    Button("Check for Updates…", action: checkForUpdates)
                }
#endif
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
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                Text(
                    "Dragging is the one place they overlap. macOS and BetterTile both interpret a drag to a screen edge, "
                        + "so pick one: leave BetterTile Drag Snapping on, or turn it off and use macOS's edge tiling. "
                        + "Bento adopts the result either way."
                )
                .font(.system(size: 12))
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
                    .font(.system(size: 12))
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
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            }

            StatusMessage(model: model)
        }
        .modifier(SettingsFormPresentation())
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

    private var installedVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        guard let build, !build.isEmpty, build != version else { return version }
        return "\(version) (\(build))"
    }
}

struct WindowLayoutSettings: View {
    @Bindable var model: BetterTileModel
    @State private var recordingAction: WindowAction?
    @State private var shortcutError: (action: WindowAction, message: String)?

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
                        Label {
                            Text(action.title)
                        } icon: {
                            WindowActionGlyph.image(for: action)
                        }
                        .tag(Optional(action))
                    }
                }
                Text(
                    "Applied each time a desktop is left with a single window. After that the window "
                        + "keeps whatever size you give it, until another window opens or you repair the layout."
                )
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            }

            if LayoutMode.availableModes.contains(.tabbed) {
                Section("Tabbed Layout") {
                    HStack(alignment: .center, spacing: 20) {
                        TabbedPresetPreview(preset: model.configuration.defaultTabbedPreset)
                            .frame(width: 184, height: 116)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 10) {
                            Picker("Starting layout", selection: configurationBinding(\.defaultTabbedPreset)) {
                                ForEach(TabbedPreset.allCases, id: \.self) { preset in
                                    Text(preset.title).tag(preset)
                                }
                            }
                            Text("Used when a desktop first enters Tabbed. Existing panes keep their layout.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            if model.activeLayoutMode == .tabbed {
                                Button("Apply to This Desktop") {
                                    model.performTabbed(.preset(model.configuration.defaultTabbedPreset))
                                }
                            }
                        }
                    }
                    Label("Select a tab to focus its window. Drag tabs between panes or onto an edge to split.", systemImage: "rectangle.on.rectangle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Label("Drag a divider to resize. Escape cancels the drag.", systemImage: "arrow.left.and.right")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Appearance") {
                Toggle("Use Liquid Glass", isOn: configurationBinding(\.overlayAppearance.useLiquidGlass))
                LabeledContent("Glass transparency") {
                    HStack(spacing: 8) {
                        Text("Frosted").foregroundStyle(.secondary)
                        Slider(value: configurationBinding(\.overlayAppearance.transparency), in: 0...1)
                            .accessibilityLabel("Glass transparency")
                            .accessibilityValue("\(Int((model.configuration.overlayAppearance.transparency * 100).rounded())) percent")
                        Text("Clear").foregroundStyle(.secondary)
                        Text("\(Int((model.configuration.overlayAppearance.transparency * 100).rounded()))%")
                            .monospacedDigit()
                            .frame(width: 42)
                    }
                    .frame(maxWidth: 380)
                }
                .disabled(!model.configuration.overlayAppearance.useLiquidGlass)
                Text("Applies to tab bars, dividers, the Layout Wheel, and the menu bar panel. Clear keeps the native glass effect. The Tabbed curtain always conceals inactive windows. Accessibility display settings take priority.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            Section("Resize Interaction") {
                Toggle(
                    "Resize adjacent windows together",
                    isOn: configurationBinding(\.linkedResizeEnabled)
                )
                Text(
                    "When windows share an edge, resizing one adjusts its neighbor. "
                        + "Available in Native mode only."
                )
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                Picker("Window feedback", selection: configurationBinding(\.resizeFeedbackMode)) {
                    Text("Ghost Preview").tag(ResizeFeedbackMode.ghost)
                    Text("Live Resize").tag(ResizeFeedbackMode.live)
                }
                .pickerStyle(.segmented)
                Text("Controls shared dividers in Native, Bento, and Tabbed.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                HStack {
                    Text("Divider width")
                    Slider(
                        value: configurationBinding(\.dividerThickness),
                        in: 2...12,
                        step: 1
                    )
                    .accessibilityLabel("Divider width")
                    .accessibilityValue("\(Int(model.configuration.dividerThickness)) points")
                    Text("\(Int(model.configuration.dividerThickness)) pt")
                        .monospacedDigit()
                        .frame(width: 42)
                }
                Text("A handle appears when the pointer approaches a valid shared edge. Glass handles are 4 points wider than this setting.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                DividerResizePreview(
                    thickness: model.configuration.dividerThickness,
                    feedback: model.configuration.resizeFeedbackMode,
                    paneGap: model.configuration.bentoInnerGap,
                    overlayAppearance: model.configuration.overlayAppearance
                )
                .padding(.vertical, 8)
            }

            Section("Bento Behavior") {
                Picker("New window side", selection: configurationBinding(\.bentoNewWindowSide)) {
                    Text("Automatic").tag(BentoNewWindowSide.automatic)
                    Text("Left").tag(BentoNewWindowSide.left)
                    Text("Right").tag(BentoNewWindowSide.right)
                    Text("Top").tag(BentoNewWindowSide.top)
                    Text("Bottom").tag(BentoNewWindowSide.bottom)
                }
                Text(
                    "Choose where new windows prefer to join a Bento layout. "
                        + "Available space and window size limits may affect placement."
                )
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

                HStack {
                    Text("Pane gap")
                    Slider(value: configurationBinding(\.bentoInnerGap), in: 0...12, step: 1)
                        .accessibilityLabel("Bento pane gap")
                        .accessibilityValue("\(Int(model.configuration.bentoInnerGap)) points")
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
                    .accessibilityLabel("Bento swap delay")
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
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            }

            Section("Shortcuts") {
                Text(
                    "Click an action to try it. Select its shortcut to record a replacement; "
                        + "duplicate combinations are rejected."
                )
                .font(.system(size: 12))
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
                            shortcutError = nil
                            model.setShortcutCaptureActive(true)
                            recordingAction = action
                        }
                        if let error = shortcutError, error.action == action {
                            Label(error.message, systemImage: "exclamationmark.circle")
                                .font(.callout)
                                .foregroundStyle(.red)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }

            StatusMessage(model: model)
        }
        .modifier(SettingsFormPresentation())
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

    private func modeCard(_ mode: LayoutMode) -> some View {
        Button {
            model.setActiveMode(mode)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: mode.icon)
                        .font(.title2)
                        .foregroundStyle(model.activeLayoutMode == mode ? Color.accentColor : Color.secondary)
                    Spacer()
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.accentColor)
                        .opacity(model.activeLayoutMode == mode ? 1 : 0)
                        .accessibilityHidden(true)
                }
                Text(mode.title)
                    .font(.headline)
                Text(mode.explanation)
                    .font(.system(size: 12))
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
        .accessibilityLabel(mode.title)
        .accessibilityValue(model.activeLayoutMode == mode ? "Selected" : "")
        .help(mode.explanation)
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

private struct TabbedPresetPreview: View {
    let preset: TabbedPreset

    var body: some View {
        Canvas { context, size in
            // Use the actual pane geometry so the preview matches the preset.
            let state = TabbedLayoutState(preset: preset)
            let frames = state.frames(in: BTRect(x: 4, y: 4, width: size.width - 8, height: size.height - 8))
            for (index, pane) in state.panes.enumerated() {
                guard let frame = frames[pane.id] else { continue }
                let rect = CGRect(x: frame.minX, y: frame.minY, width: frame.size.width, height: frame.size.height)
                let path = Path(roundedRect: rect, cornerRadius: 5)
                context.fill(path, with: .color(index == 0 ? .accentColor.opacity(0.12) : Color(nsColor: .controlBackgroundColor)))
                context.stroke(path, with: .color(index == 0 ? .accentColor.opacity(0.7) : .secondary.opacity(0.3)), lineWidth: 1)
                let header = CGRect(x: rect.minX + 5, y: rect.minY + 5, width: max(0, rect.width - 10), height: 8)
                context.fill(Path(roundedRect: header, cornerRadius: 2), with: .color(index == 0 ? .accentColor.opacity(0.3) : .secondary.opacity(0.15)))
                context.draw(Text("\(index + 1)").font(.system(size: 12, weight: .medium)).foregroundColor(.secondary),
                             at: CGPoint(x: rect.midX, y: rect.midY + 5))
            }
        }
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
                Group {
                    if isRecording {
                        Text("Press keys…").font(.system(size: 13))
                    } else {
                        ShortcutLabel(shortcut: shortcut, emptyLabel: "None", size: 13)
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

            Button("Reset") {
                model.assign(shortcut: defaultShortcut, to: action)
            }
            .disabled(shortcut == defaultShortcut)
        }
        .padding(.vertical, 4)
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

enum MenuActionOrder {
    static func moving(
        _ action: WindowAction,
        toInsertionIndex insertionIndex: Int,
        in actions: [WindowAction]
    ) -> [WindowAction]? {
        guard let sourceIndex = actions.firstIndex(of: action),
              (0 ... actions.count).contains(insertionIndex)
        else { return nil }
        var result = actions
        let item = result.remove(at: sourceIndex)
        let adjustedIndex = insertionIndex > sourceIndex ? insertionIndex - 1 : insertionIndex
        result.insert(item, at: min(adjustedIndex, result.count))
        return result == actions ? nil : result
    }

    static func moving(
        _ action: WindowAction,
        by offset: Int,
        in actions: [WindowAction]
    ) -> [WindowAction]? {
        guard let sourceIndex = actions.firstIndex(of: action) else { return nil }
        let destinationIndex = sourceIndex + offset
        guard actions.indices.contains(destinationIndex) else { return nil }
        var result = actions
        let item = result.remove(at: sourceIndex)
        result.insert(item, at: destinationIndex)
        return result
    }
}

private struct MenuBarSettings: View {
    @Bindable var model: BetterTileModel

    private var selectedActions: [WindowAction] { model.configuration.menuBarActions }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 12) {
                    Image(systemName: "line.3.horizontal").font(.title2).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Your menu, your order").font(.headline)
                        Text("Choose actions on the left. Drag tiles in the preview to arrange your menu.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("\(selectedActions.count) actions").font(.callout).foregroundStyle(.secondary)
                }
                .padding(16)
                .background(.background, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))

                HStack(alignment: .top, spacing: 22) {
                    actionCatalog
                        .frame(minWidth: 270, maxWidth: .infinity, alignment: .top)
                    editablePreview
                        .frame(width: MenuPanelMetrics.width)
                }

                HStack {
                    Button("Restore Defaults") { setActions(WindowAction.menuBarDefaultOrder) }
                    Spacer()
                    Button("Deselect All") { setActions([]) }
                        .disabled(selectedActions.isEmpty)
                }
                Text("Window mode, drag snapping, the Repair or Arrange action, Settings, and Quit stay in your menu.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
    }

    private var actionCatalog: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Available actions").font(.headline)
                Spacer()
                Text("\(WindowActionGroup.flattenedActions.count)")
                    .foregroundStyle(.secondary)
            }
            .padding(12)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(WindowActionGroup.allCases) { group in
                        VStack(alignment: .leading, spacing: 7) {
                            Text(group.title)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.secondary)
                            ForEach(group.actions) { action in
                                Toggle(isOn: actionBinding(action)) {
                                    HStack(spacing: 7) {
                                        WindowActionGlyph(action: action)
                                        Text(action.title)
                                        Spacer(minLength: 0)
                                        ShortcutLabel(shortcut: shortcut(for: action), emptyLabel: "")
                                    }
                                }
                                .toggleStyle(.checkbox)
                                .padding(.vertical, 3)
                            }
                        }
                    }
                }
                .padding(12)
            }
            .frame(height: 480)

            Divider()
            Text("Hiding an action here keeps its shortcut and Layout Wheel assignments unchanged.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(12)
        }
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.separator))
    }

    private var editablePreview: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Your menu").font(.headline)
                Spacer()
                Text("Drag tiles to arrange").font(.callout).foregroundStyle(.secondary)
            }

            MenuPanelContent(model: model, isEditing: true) {
                actionGrid
            } notice: {
                EmptyView()
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator))

            Text("Move onto a neighboring tile to reorder. Hold Option and press an arrow key to move the focused tile.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var actionGrid: some View {
        MenuActionCollection(
            actions: selectedActions,
            shortcuts: model.configuration.shortcuts,
            commit: { actions, moved in
                setActions(actions)
                announceMove(moved, actions: actions)
            }
        )
    }

    private func actionBinding(_ action: WindowAction) -> Binding<Bool> {
        Binding(
            get: { selectedActions.contains(action) },
            set: { isVisible in
                var actions = selectedActions
                if isVisible {
                    guard !actions.contains(action) else { return }
                    actions.append(action)
                } else {
                    actions.removeAll { $0 == action }
                }
                setActions(actions)
            }
        )
    }

    private func shortcut(for action: WindowAction) -> BetterTileCore.KeyboardShortcut? {
        model.configuration.shortcuts.first(where: { $0.action == action })?.shortcut
    }

    private func setActions(_ actions: [WindowAction]) {
        model.updateConfiguration { $0.menuBarActions = actions }
    }

    private func announceMove(_ action: WindowAction, actions: [WindowAction]) {
        guard let index = actions.firstIndex(of: action) else { return }
        AccessibilityNotification.Announcement(
            "\(action.title), position \(index + 1) of \(actions.count)"
        ).post()
    }
}

struct MenuActionDrag {
    let source: WindowAction
    let original: [WindowAction]
    var preview: [WindowAction]

    init(source: WindowAction, actions: [WindowAction]) {
        self.source = source
        original = actions
        preview = actions
    }

    mutating func move(to insertion: Int) -> (from: Int, to: Int)? {
        guard let from = preview.firstIndex(of: source),
              let reordered = MenuActionOrder.moving(source, toInsertionIndex: insertion, in: preview),
              let to = reordered.firstIndex(of: source) else { return nil }
        preview = reordered
        return (from, to)
    }

    var committedOrder: [WindowAction]? { preview == original ? nil : preview }
}

/// AppKit owns the full drag session, including cancellation and edge scrolling.
/// Hover ordering stays local; configuration is written only after a valid drop.
struct MenuActionCollection: NSViewRepresentable {
    var actions: [WindowAction]
    var shortcuts: [ShortcutBinding]
    var commit: ([WindowAction], WindowAction) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> MenuPanelNativeScrollView {
        let scroll = MenuPanelNativeScrollView(frame: .zero)
        let view = MenuReorderCollectionView(frame: NSRect(x: 0, y: 0, width: MenuPanelMetrics.width - MenuPanelMetrics.padding * 2 + MenuPanelMetrics.scrollContentInset * 2, height: 0))
        view.autoresizingMask = [.width]
        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = NSSize(width: MenuPanelMetrics.tileWidth, height: MenuPanelMetrics.tileHeight)
        layout.minimumInteritemSpacing = MenuPanelMetrics.gap
        layout.minimumLineSpacing = MenuPanelMetrics.gap
        layout.sectionInset = NSEdgeInsets(top: 0, left: MenuPanelMetrics.scrollContentInset,
                                          bottom: 22, right: MenuPanelMetrics.scrollContentInset)
        view.collectionViewLayout = layout
        view.backgroundColors = [.clear]
        view.isSelectable = true
        view.allowsMultipleSelection = false
        view.register(MenuActionCollectionItem.self, forItemWithIdentifier: Coordinator.itemID)
        view.registerForDraggedTypes([Coordinator.dragType])
        view.setDraggingSourceOperationMask(.move, forLocal: true)
        view.setDraggingSourceOperationMask([], forLocal: false)
        view.dataSource = context.coordinator
        view.delegate = context.coordinator
        view.reloadData()
        view.moveSelection = { [weak coordinator = context.coordinator, weak view] offset in
            guard let coordinator, let view,
                  let index = view.selectionIndexPaths.first?.item,
                  coordinator.displayed.indices.contains(index) else { return }
            coordinator.move(coordinator.displayed[index], by: offset, in: view)
        }
        scroll.documentView = view
        return scroll
    }

    func updateNSView(_ scroll: MenuPanelNativeScrollView, context: Context) {
        guard let view = scroll.documentView as? MenuReorderCollectionView else { return }
        let coordinator = context.coordinator
        let changed = coordinator.parent.actions != actions || coordinator.parent.shortcuts != shortcuts
        coordinator.parent = self
        if changed {
            coordinator.endDrag(in: view)
        }
    }

    static func dismantleNSView(_ scroll: MenuPanelNativeScrollView, coordinator: Coordinator) {
        (scroll.documentView as? MenuReorderCollectionView)?.stopDragFrames()
    }

    @MainActor final class Coordinator: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegate {
        static let itemID = NSUserInterfaceItemIdentifier("menu-action")
        static let dragType = NSPasteboard.PasteboardType("com.lmckarma.BetterTile.menu-action")
        var parent: MenuActionCollection
        var displayed: [WindowAction]
        var drag: MenuActionDrag?
        private var reorderAnimationEndsAt: TimeInterval = 0

        init(parent: MenuActionCollection) {
            self.parent = parent
            displayed = parent.actions
        }

        func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
            displayed.count
        }

        func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
            let item = collectionView.makeItem(withIdentifier: Self.itemID, for: indexPath) as! MenuActionCollectionItem
            let action = displayed[indexPath.item]
            let label = MenuPanelActionButton(action: action, shortcut: parent.shortcuts.first { $0.action == action }?.shortcut) {}
                .accessibilityHint("Drag to reorder. Option with arrow keys moves the selected action.")
                .accessibilityValue("Position \(indexPath.item + 1) of \(displayed.count)")
                .accessibilityAction(named: "Move Earlier") { [weak self, weak collectionView] in
                    guard let self, let collectionView else { return }
                    self.move(action, by: -1, in: collectionView)
                }
                .accessibilityAction(named: "Move Later") { [weak self, weak collectionView] in
                    guard let self, let collectionView else { return }
                    self.move(action, by: 1, in: collectionView)
                }
            item.host.rootView = AnyView(label)
            item.isDraggingPlaceholder = drag?.source == action
            return item
        }

        func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> NSPasteboardWriting? {
            guard displayed.indices.contains(indexPath.item) else { return nil }
            let writer = NSPasteboardItem()
            writer.setString(displayed[indexPath.item].rawValue, forType: Self.dragType)
            return writer
        }

        func collectionView(_ collectionView: NSCollectionView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint, forItemsAt indexPaths: Set<IndexPath>) {
            guard let index = indexPaths.first?.item else { return }
            beginDrag(at: index, in: collectionView)
            (collectionView as? MenuReorderCollectionView)?.startDragFrames(session: session)
        }

        func beginDrag(at index: Int, in collectionView: NSCollectionView) {
            guard displayed.indices.contains(index) else { return }
            let source = displayed[index]
            drag = MenuActionDrag(source: source, actions: parent.actions)
            reorderAnimationEndsAt = 0
            // Let AppKit capture the lifted tile before leaving an empty slot.
            DispatchQueue.main.async { [weak self, weak collectionView] in
                guard let self, let collectionView, self.drag?.source == source,
                      let index = self.displayed.firstIndex(of: source) else { return }
                (collectionView.item(at: IndexPath(item: index, section: 0)) as? MenuActionCollectionItem)?.isDraggingPlaceholder = true
            }
        }

        func collectionView(_ collectionView: NSCollectionView, validateDrop info: any NSDraggingInfo,
                            proposedIndexPath proposed: AutoreleasingUnsafeMutablePointer<NSIndexPath>,
                            dropOperation operation: UnsafeMutablePointer<NSCollectionView.DropOperation>) -> NSDragOperation {
            guard (info.draggingSource as? NSCollectionView) === collectionView, drag != nil else { return [] }
            previewDrop(at: collectionView.convert(info.draggingLocation, from: nil), in: collectionView)
            // Our preview already occupies the destination. Suppress AppKit's
            // separate insertion gap, which otherwise shifts the hover target.
            operation.pointee = .on
            if let source = drag?.source, let index = displayed.firstIndex(of: source) {
                proposed.pointee = NSIndexPath(forItem: index, inSection: 0)
            }
            return .move
        }

        func previewDrop(at point: NSPoint, in collectionView: NSCollectionView,
                         time: TimeInterval = CACurrentMediaTime(), finishing: Bool = false) {
            guard finishing || time >= reorderAnimationEndsAt else { return }
            guard var drag, let sourceIndex = displayed.firstIndex(of: drag.source) else { return }
            let target = displayed.indices.compactMap { index -> (Int, CGFloat)? in
                guard let frame = collectionView.layoutAttributesForItem(at: IndexPath(item: index, section: 0))?.frame else { return nil }
                let dx = point.x - frame.midX
                let dy = point.y - frame.midY
                return (index, dx * dx + dy * dy)
            }.min { $0.1 < $1.1 }?.0
            guard let target else { return }
            let insertion = target > sourceIndex ? target + 1 : target
            if let movement = drag.move(to: insertion) {
                self.drag = drag
                displayed = drag.preview
                let duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.16
                reorderAnimationEndsAt = time + duration
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = duration
                    collectionView.animator().moveItem(at: IndexPath(item: movement.from, section: 0), to: IndexPath(item: movement.to, section: 0))
                }
            }
        }

        func collectionView(_ collectionView: NSCollectionView, acceptDrop info: any NSDraggingInfo, indexPath: IndexPath, dropOperation: NSCollectionView.DropOperation) -> Bool {
            guard (info.draggingSource as? NSCollectionView) === collectionView, drag != nil else { return false }
            previewDrop(at: collectionView.convert(info.draggingLocation, from: nil), in: collectionView, finishing: true)
            guard let drag else { return false }
            (collectionView as? MenuReorderCollectionView)?.stopDragFrames()
            self.drag = nil
            if let order = drag.committedOrder {
                parent.actions = order
                parent.commit(order, drag.source)
            }
            return true
        }

        func collectionView(_ collectionView: NSCollectionView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint, dragOperation: NSDragOperation) {
            endDrag(in: collectionView)
        }

        func endDrag(in collectionView: NSCollectionView) {
            (collectionView as? MenuReorderCollectionView)?.stopDragFrames()
            reorderAnimationEndsAt = 0
            let selected = drag?.source ?? collectionView.selectionIndexPaths.first.flatMap {
                displayed.indices.contains($0.item) ? displayed[$0.item] : nil
            }
            drag = nil
            displayed = parent.actions
            for case let item as MenuActionCollectionItem in collectionView.visibleItems() {
                item.isDraggingPlaceholder = false
            }
            collectionView.reloadData()
            if let selected, let index = displayed.firstIndex(of: selected) {
                collectionView.selectionIndexPaths = [IndexPath(item: index, section: 0)]
            }
        }

        func move(_ action: WindowAction, by offset: Int, in view: NSCollectionView) {
            guard drag == nil, let order = MenuActionOrder.moving(action, by: offset, in: parent.actions),
                  let index = order.firstIndex(of: action) else { return }
            displayed = order
            parent.actions = order
            parent.commit(order, action)
            view.reloadData()
            view.selectionIndexPaths = [IndexPath(item: index, section: 0)]
            view.window?.makeFirstResponder(view)
            // Resolve pending collection layout before asking AppKit to reveal it.
            if let frame = view.layoutAttributesForItem(at: IndexPath(item: index, section: 0))?.frame {
                view.scrollToVisible(frame)
            }
        }
    }
}

private final class MenuDragLabelHost: NSHostingView<AnyView> {
    // The collection view, not the decorative SwiftUI Button, owns pointer input.
    override func hitTest(_ point: NSPoint) -> NSView? {
        isHidden || !frame.contains(point) ? nil : self
    }
    override func mouseDown(with event: NSEvent) { nextResponder?.mouseDown(with: event) }
    override func mouseDragged(with event: NSEvent) { nextResponder?.mouseDragged(with: event) }
    override func mouseUp(with event: NSEvent) { nextResponder?.mouseUp(with: event) }
}

private final class MenuActionCollectionItem: NSCollectionViewItem {
    let host = MenuDragLabelHost(rootView: AnyView(EmptyView()))

    override func loadView() { view = host }

    var isDraggingPlaceholder = false {
        didSet { view.alphaValue = isDraggingPlaceholder ? 0 : 1 }
    }

    override func apply(_ layoutAttributes: NSCollectionViewLayoutAttributes) {
        super.apply(layoutAttributes)
        view.alphaValue = isDraggingPlaceholder ? 0 : 1
    }

    override var isSelected: Bool {
        didSet {
            view.wantsLayer = true
            view.layer?.cornerRadius = 8
            view.layer?.borderColor = NSColor.controlAccentColor.cgColor
            view.layer?.borderWidth = isSelected ? 2 : 0
        }
    }
}

final class MenuReorderCollectionView: NSCollectionView {
    var lastDragScrollTime: TimeInterval?
    private(set) var dragDisplayLink: CADisplayLink?
    private var dragWindowPoint: NSPoint?
    private weak var dragSession: NSDraggingSession?

    override func wantsPeriodicDraggingUpdates() -> Bool { true }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        updateDragFrames(sender)
        return super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        updateDragFrames(sender)
        return super.draggingUpdated(sender)
    }

    private func updateDragFrames(_ sender: any NSDraggingInfo) {
        guard (sender.draggingSource as? NSCollectionView) === self,
              (delegate as? MenuActionCollection.Coordinator)?.drag != nil else { return }
        dragWindowPoint = sender.draggingLocation
        startDragFrames()
    }

    func startDragFrames(session: NSDraggingSession) {
        dragSession = session
        startDragFrames()
    }

    private func startDragFrames() {
        guard dragDisplayLink == nil else { return }
        let link = (window?.contentView ?? self).displayLink(target: self, selector: #selector(drawDragFrame(_:)))
        dragDisplayLink = link
        link.add(to: .main, forMode: .common)
        link.add(to: .main, forMode: .eventTracking)
    }

    @objc private func drawDragFrame(_ link: CADisplayLink) {
        advanceDragFrame(time: link.timestamp)
    }

    func advanceDragFrame(time: TimeInterval) {
        // The source session keeps reporting the cursor after it leaves the
        // destination, including above or below the Settings window.
        let point = dragSession.flatMap { session in
            window?.convertPoint(fromScreen: session.draggingLocation)
        } ?? dragWindowPoint
        guard let point else { return }
        scrollDuringDrag(at: point, time: time)
        let local = convert(point, from: nil)
        if visibleRect.contains(local) {
            (delegate as? MenuActionCollection.Coordinator)?.previewDrop(at: local, in: self, time: time)
        }
    }

    func stopDragFrames() {
        dragDisplayLink?.invalidate()
        dragDisplayLink = nil
        dragWindowPoint = nil
        dragSession = nil
        lastDragScrollTime = nil
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { stopDragFrames() }
        super.viewWillMove(toWindow: newWindow)
    }

    func scrollDuringDrag(at windowPoint: NSPoint, time: TimeInterval) {
        let point = convert(windowPoint, from: nil)
        let elapsed = min(0.1, max(0, time - (lastDragScrollTime ?? time)))
        var container = enclosingScrollView
        var edge: CGFloat = 0
        while let scroll = container {
            let clip = scroll.contentView
            let visible = convert(clip.visibleRect, from: clip)
            let band = min(32, visible.height / 3)
            // Each viewport owns its full width. Its vertical trigger extends
            // beyond the frame, with speed capped even far outside the window.
            if band > 0, point.x >= visible.minX, point.x <= visible.maxX {
                if point.y < visible.minY + band {
                    edge = -min(1, (visible.minY + band - point.y) / band)
                } else if point.y > visible.maxY - band {
                    edge = min(1, (point.y - visible.maxY + band) / band)
                }
            }
            if edge != 0 {
                let direction: CGFloat = scroll.documentView?.isFlipped == true ? 1 : -1
                let next = clip.constrainBoundsRect(clip.bounds.offsetBy(dx: 0, dy: edge * 480 * elapsed * direction))
                if next.origin != clip.bounds.origin {
                    clip.scroll(to: next.origin)
                    scroll.reflectScrolledClipView(clip)
                    break
                }
            }
            // At the list's limit, let the Settings page reveal more content.
            container = scroll.enclosingScrollView
        }
        lastDragScrollTime = edge == 0 ? nil : time
    }

    var moveSelection: ((Int) -> Void)?
    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.option), let delta = [123: -1, 124: 1, 125: 2, 126: -2][Int(event.keyCode)] {
            moveSelection?(delta)
        } else {
            super.keyDown(with: event)
        }
    }
}

private struct ZoneSettings: View {
    @Bindable var model: BetterTileModel
    @State private var selectedArea: SnapArea = .topLeft

    var body: some View {
        Form {
            if !model.configuration.snappingEnabled {
                Section {
                    HStack {
                        Label(
                            "Drag snapping is off. Edits here are saved but have no effect until you turn it on.",
                            systemImage: "info.circle"
                        )
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        Spacer()
                        Button("Turn On") { model.updateConfiguration { $0.snappingEnabled = true } }
                            .accessibilityLabel("Turn on drag snapping")
                    }
                }
            }
            Section {
                SnapZoneDiagram(
                    selectedArea: $selectedArea,
                    bindings: model.configuration.snapAreaBindings
                )
                .frame(minHeight: 360)

                HStack(alignment: .center, spacing: 16) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(selectedArea.title)
                            .font(.headline)
                        Text(
                            selectedAction.map { "Window placement: \($0.title)" }
                                ?? "No action"
                        )
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Picker("Action for \(selectedArea.title)", selection: snapActionBinding(selectedArea)) {
                        Label("Disabled", systemImage: "minus.rectangle").tag(nil as WindowAction?)
                        ForEach(WindowAction.snapAssignableActions) { action in
                            Label {
                                Text(action.title)
                            } icon: {
                                WindowActionGlyph.image(for: action)
                            }
                            .tag(Optional(action))
                        }
                    }
                    .labelsHidden()
                    .frame(width: 250)
                }
            } header: {
                HStack {
                    Text("Screen edge actions")
                    Spacer()
                    Button("Restore Defaults") {
                        model.updateConfiguration {
                            $0.snapAreaBindings = BetterTileConfiguration.defaultSnapAreaBindings
                        }
                    }
                }
            } footer: {
                Text(
                    "Assignments apply across displays. Hold the suppression modifier to bypass snapping. "
                        + "The accent marker shows where to drag. The window shows the resulting placement."
                )
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
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            }

            StatusMessage(model: model)
        }
        .modifier(SettingsFormPresentation())
    }

    private var selectedAction: WindowAction? {
        model.configuration.snapAreaBindings
            .first(where: { $0.area == selectedArea })?
            .action
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

}

enum SnapZonePreviewGeometry {
    static let display = DisplaySnapshot(
        id: DisplayID(rawValue: "snap-zone-preview"),
        frame: BTRect(x: 0, y: 0, width: 1600, height: 1000),
        visibleFrame: BTRect(x: 0, y: 0, width: 1600, height: 1000),
        isMain: true
    )
    static let window = WindowSnapshot(
        id: WindowID(rawValue: "snap-zone-preview"),
        processIdentifier: 0,
        frame: BTRect(x: 480, y: 300, width: 640, height: 400),
        displayID: display.id
    )

    static func placement(for action: WindowAction?) -> NormalizedRect? {
        guard let action,
              let frame = StandardActionEngine().targetFrame(
                  for: action,
                  window: window,
                  display: display
              )
        else { return nil }
        return NormalizedRect(frame: frame, in: display.visibleFrame)
    }

    static func marker(for area: SnapArea, in size: CGSize) -> CGRect {
        let corner: CGFloat = 22
        let edge: CGFloat = 7
        switch area {
        case .topLeft: return CGRect(x: 0, y: 0, width: corner, height: corner)
        case .topRight: return CGRect(x: size.width - corner, y: 0, width: corner, height: corner)
        case .bottomLeft: return CGRect(x: 0, y: size.height - corner, width: corner, height: corner)
        case .bottomRight: return CGRect(x: size.width - corner, y: size.height - corner, width: corner, height: corner)
        case .top: return CGRect(x: 20, y: 0, width: size.width - 40, height: edge)
        case .bottom: return CGRect(x: 20, y: size.height - edge, width: size.width - 40, height: edge)
        case .left: return CGRect(x: 0, y: 20, width: edge, height: size.height - 40)
        case .right: return CGRect(x: size.width - edge, y: 20, width: edge, height: size.height - 40)
        }
    }

    static func trigger(for area: SnapArea) -> NormalizedRect {
        switch area {
        case .topLeft: .init(x: 0, y: 0, width: 0.3, height: 0.36)
        case .top: .init(x: 0.3, y: 0, width: 0.4, height: 0.12)
        case .topRight: .init(x: 0.7, y: 0, width: 0.3, height: 0.36)
        case .left: .init(x: 0, y: 0.36, width: 0.12, height: 0.28)
        case .right: .init(x: 0.88, y: 0.36, width: 0.12, height: 0.28)
        case .bottomLeft: .init(x: 0, y: 0.64, width: 0.3, height: 0.36)
        case .bottom: .init(x: 0.3, y: 0.88, width: 0.4, height: 0.12)
        case .bottomRight: .init(x: 0.7, y: 0.64, width: 0.3, height: 0.36)
        }
    }
}

struct SnapZoneLayout {
    var width: CGFloat
    var isWide: Bool { width >= 620 }
    var columns: Int { width >= 300 ? 2 : 1 }
    var monitorWidth: CGFloat { max(1, min(480, isWide ? width - 280 : width)) }
    var height: CGFloat {
        monitorWidth / 1.6 + (isWide ? 156 : CGFloat(8 / columns) * 76 + 8) + 36
    }
}

private struct SnapZoneDiagram: View {
    @Binding var selectedArea: SnapArea
    let bindings: [SnapAreaBinding]

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var availableWidth: CGFloat = 640

    var body: some View {
        GeometryReader { proxy in
            let layout = SnapZoneLayout(width: proxy.size.width)
            VStack(spacing: 16) {
                if layout.isWide {
                    Grid(horizontalSpacing: 12, verticalSpacing: 10) {
                        GridRow {
                            zoneControl(.topLeft).frame(width: 128)
                            zoneControl(.top).frame(width: layout.monitorWidth)
                            zoneControl(.topRight).frame(width: 128)
                        }
                        GridRow {
                            zoneControl(.left).frame(width: 128)
                            screen.frame(width: layout.monitorWidth, height: layout.monitorWidth / 1.6)
                            zoneControl(.right).frame(width: 128)
                        }
                        GridRow {
                            zoneControl(.bottomLeft).frame(width: 128)
                            zoneControl(.bottom).frame(width: layout.monitorWidth)
                            zoneControl(.bottomRight).frame(width: 128)
                        }
                    }
                } else {
                    screen.frame(width: layout.monitorWidth, height: layout.monitorWidth / 1.6)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: layout.columns), spacing: 8) {
                        ForEach(SnapArea.allCases) { zoneControl($0) }
                    }
                }
                HStack(spacing: 16) {
                    Label("Drag here", systemImage: "arrow.up.left")
                        .foregroundStyle(Color.accentColor)
                    Label("Window placement", systemImage: "rectangle")
                }
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
        }
        .frame(height: SnapZoneLayout(width: availableWidth).height)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { availableWidth = $0 }
    }

    private func select(_ area: SnapArea) {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) { selectedArea = area }
    }

    private func zoneControl(_ area: SnapArea) -> some View {
        let assignedAction = assignment(for: area)
        return Button { select(area) } label: {
            HStack(spacing: 8) {
                if let assignedAction {
                    WindowActionGlyph(action: assignedAction)
                } else {
                    Image(systemName: "minus.rectangle")
                        .font(.system(size: 20))
                        .frame(width: 30, height: 26)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(area.shortTitle)
                        .font(.system(size: 12, weight: .medium))
                    Text(assignedAction?.title ?? "Disabled")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            }
            .multilineTextAlignment(.leading)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: 68, maxHeight: 68,
                   alignment: area == .top || area == .bottom ? .center : .leading)
            .background(
                selectedArea == area ? Color.accentColor.opacity(0.13) : Color.clear,
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(
                        selectedArea == area
                            ? Color.accentColor
                            : Color.clear
                    )
            )
        }
        .buttonStyle(MenuActionButtonStyle())
        .accessibilityLabel(area.title)
        .accessibilityValue(assignedAction?.title ?? "Disabled")
        .accessibilityAddTraits(selectedArea == area ? .isSelected : [])
    }

    private var screen: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let content = CGRect(origin: .zero, size: size).insetBy(dx: 14, dy: 14)
            let marker = SnapZonePreviewGeometry.marker(for: selectedArea, in: size)
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 10)
                    .fill(.background.opacity(0.5))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(.secondary.opacity(0.5), lineWidth: 1.5))

                if let action = assignment(for: selectedArea),
                   let placement = SnapZonePreviewGeometry.placement(for: action) {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.accentColor.opacity(0.1))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.secondary.opacity(0.7), lineWidth: 1))
                        .overlay { WindowActionGlyph(action: action) }
                        .frame(width: content.width * placement.width, height: content.height * placement.height)
                        .offset(x: content.minX + content.width * placement.x,
                                y: content.minY + content.height * placement.y)
                        .allowsHitTesting(false)
                }

                SnapTriggerMarker(area: selectedArea)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                    .frame(width: marker.width, height: marker.height)
                    .offset(x: marker.minX, y: marker.minY)
                    .allowsHitTesting(false)

                // Generous selection targets are separate from the small edge
                // markers. Neither changes the actual snap detector.
                ForEach(SnapArea.allCases) { area in
                    let trigger = SnapZonePreviewGeometry.trigger(for: area)
                    Button { select(area) } label: {
                        Color.clear.contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .frame(width: size.width * trigger.width, height: size.height * trigger.height)
                    .offset(x: size.width * trigger.x, y: size.height * trigger.y)
                    .accessibilityLabel("Select \(area.title)")
                    .accessibilityAddTraits(selectedArea == area ? .isSelected : [])
                }
            }
            .overlay(alignment: .bottom) {
                Capsule().fill(.secondary).frame(width: size.width * 0.4, height: 2).offset(y: 6)
            }
        }
    }

    private func assignment(for area: SnapArea) -> WindowAction? {
        bindings.first(where: { $0.area == area })?.action
    }
}

private struct SnapTriggerMarker: Shape {
    let area: SnapArea

    func path(in rect: CGRect) -> Path {
        let bounds = rect.insetBy(dx: 2, dy: 2)
        var path = Path()
        let corner: (x: CGFloat, y: CGFloat, dx: CGFloat, dy: CGFloat)
        switch area {
        case .topLeft: corner = (bounds.minX, bounds.minY, 1, 1)
        case .topRight: corner = (bounds.maxX, bounds.minY, -1, 1)
        case .bottomLeft: corner = (bounds.minX, bounds.maxY, 1, -1)
        case .bottomRight: corner = (bounds.maxX, bounds.maxY, -1, -1)
        case .top, .bottom:
            path.move(to: CGPoint(x: bounds.midX - bounds.width * 0.2, y: bounds.midY))
            path.addLine(to: CGPoint(x: bounds.midX + bounds.width * 0.2, y: bounds.midY))
            return path
        case .left, .right:
            path.move(to: CGPoint(x: bounds.midX, y: bounds.midY - bounds.height * 0.2))
            path.addLine(to: CGPoint(x: bounds.midX, y: bounds.midY + bounds.height * 0.2))
            return path
        }
        let radius: CGFloat = 6
        path.move(to: CGPoint(x: corner.x + corner.dx * bounds.width, y: corner.y))
        path.addLine(to: CGPoint(x: corner.x + corner.dx * radius, y: corner.y))
        path.addQuadCurve(to: CGPoint(x: corner.x, y: corner.y + corner.dy * radius),
                          control: CGPoint(x: corner.x, y: corner.y))
        path.addLine(to: CGPoint(x: corner.x, y: corner.y + corner.dy * bounds.height))
        return path
    }
}

private extension SnapArea {
    var shortTitle: String {
        switch self {
        case .topLeft: "Top left"
        case .top: "Top"
        case .topRight: "Top right"
        case .left: "Left"
        case .right: "Right"
        case .bottomLeft: "Bottom left"
        case .bottom: "Bottom"
        case .bottomRight: "Bottom right"
        }
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
        case .tabbed: "rectangle.stack"
        }
    }

    var explanation: String {
        switch self {
        case .manual: "Use macOS windows with BetterTile snapping."
        case .linked: "Adjacent snapped windows share resize boundaries."
        case .bento: "Windows join a stable adaptive split layout."
        case .tabbed: "Group windows in resizable panes with tabs. Experimental; turn off Stage Manager."
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
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Picker("Rule for \(entry.name)", selection: ruleBinding(entry.bundleIdentifier)) {
                                ForEach(ApplicationRule.allCases) { rule in
                                    Text(rule.title).tag(rule)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 190)
                            .help("How BetterTile manages \(entry.name)")
                            Button {
                                model.clearRule(for: entry.bundleIdentifier)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("Manage \(entry.name) normally again")
                            .accessibilityLabel("Remove rule for \(entry.name)")
                        }
                        .padding(.vertical, 2)
                    }
                }
                Text("Choosing Manage Normally removes an app from this list, the same as the × button.")
                    .font(.system(size: 12))
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
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 1)
                }
                Text(
                    "Rules are remembered by app, so one stays in effect the next time you open it. "
                        + "An app that is not installed keeps its rule."
                )
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            }

            StatusMessage(model: model)
        }
        .modifier(SettingsFormPresentation())
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
    /// Sampled once when the sheet opens rather than read from the model on
    /// every keystroke: enumerating running applications is not free, and a
    /// list that reorders itself because something launched mid-search would be
    /// harder to use, not fresher.
    @State private var allCandidates: [ApplicationRuleCandidate] = []

    private var candidates: [ApplicationRuleCandidate] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return allCandidates }
        return allCandidates.filter {
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
                        allCandidates.isEmpty
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
                                .font(.system(size: 12))
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
        .onAppear { allCandidates = model.addableApplications }
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

struct SettingsFormPresentation: ViewModifier {
    func body(content: Content) -> some View {
        content
            .formStyle(.grouped)
            .toggleStyle(SettingsSwitchStyle())
            .controlSize(.regular)
            .font(.system(size: 13))
    }
}

struct SettingsSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 16) {
            configuration.label
            Spacer(minLength: 8)
            Toggle("", isOn: configuration.$isOn)
                .labelsHidden()
                .toggleStyle(.switch)
        }
        .accessibilityElement(children: .combine)
    }
}
