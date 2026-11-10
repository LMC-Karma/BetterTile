// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 LMC-Karma
// Contains portions adapted from Vorssaint, Copyright (C) 2026 Vorssaint.

import AppKit
import BetterTileCore
import BetterTileMacOS
import SwiftUI

// These choices describe legacy values without changing the stored configuration.
enum DividerWidthChoice: Double, CaseIterable {
    case thin = 4, standard = 8, wide = 12

    static func nearest(to value: Double) -> Self {
        guard !value.isNaN else { return .standard }
        if value < 6 { return .thin }
        return value < 10 ? .standard : .wide
    }

    var title: String {
        switch self {
        case .thin: "Thin"
        case .standard: "Standard"
        case .wide: "Wide"
        }
    }
}

enum SwapDelayChoice: Double, CaseIterable {
    case instant = 0, short = 0.12, long = 0.3

    static func nearest(to value: Double) -> Self {
        guard !value.isNaN else { return .short }
        if value < 0.06 { return .instant }
        return value < 0.21 ? .short : .long
    }

    var title: String {
        switch self {
        case .instant: "Instant"
        case .short: "Short"
        case .long: "Long"
        }
    }
}

struct WindowLayoutSettings: View {
    /// The Window mode picture is 88 pt tall, with the badges on the title line.
    static let modePictureHeight: CGFloat = 88

    @Bindable var model: BetterTileModel
    @Environment(\.displayScale) private var glyphDisplayScale
    @Environment(\.colorScheme) private var glyphColorScheme
    @State private var settingsMode: LayoutMode
    private let defaults = BetterTileConfiguration()

    init(
        model: BetterTileModel,
        settingsMode: LayoutMode? = nil
    ) {
        self.model = model
        _settingsMode = State(initialValue: settingsMode ?? model.activeLayoutMode)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: SettingsSpacing.s5) {
                    windowModeGroup
                    VStack(alignment: .leading, spacing: SettingsSpacing.s2) {
                        HStack {
                            Text("Show settings for:").font(SettingsFont.headline)
                            Spacer()
                            Picker("Show settings for", selection: $settingsMode) {
                                ForEach(LayoutMode.availableModes, id: \.self) { mode in
                                    Text(mode.title).tag(mode)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)
                            .frame(width: 280)
                        }
                        .padding(.horizontal, SettingsSpacing.s1)
                        modeSettings
                    }
                    resizeGroup
                    appearanceGroup
                    StatusMessage(model: model)
                }
                .padding(SettingsSpacing.s6)
            }
        }
        .font(SettingsFont.body)
    }

    private var windowModeGroup: some View {
        SettingsGroup("Window mode", aside: model.activeContextDescription) {
            HStack(alignment: .top, spacing: SettingsSpacing.s3) {
                ForEach(LayoutMode.availableModes, id: \.self) { mode in
                    PictureChoice(mode.title, detail: mode.explanation,
                                  isSelected: model.activeLayoutMode == mode,
                                  thumbnailHeight: Self.modePictureHeight,
                                  accessory: AnyView(ModeBadges(
                                      isThisDesktop: model.activeLayoutMode == mode,
                                      isDefault: model.configuration.defaultLayoutMode == mode)),
                                  action: { model.setActiveMode(mode) }) {
                        ModeThumbnail(mode: mode, isSelected: model.activeLayoutMode == mode)
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .help(mode.explanation)
                }
            }
            .padding(SettingsSpacing.s3)
            SettingsRow("Default mode", caption: "Used for desktops you have not set.") {
                Picker("Default mode", selection: configurationBinding(\.defaultLayoutMode)) {
                    ForEach(LayoutMode.availableModes, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .labelsHidden().fixedSize()
            }
            SettingsRow("Keep desktop modes when displays change", caption: "A desktop keeps its mode and layout when it moves to another screen, for example when you dock or undock. Off: from the next screen change, each screen remembers its own modes.") {
                Toggle("Keep desktop modes when displays change", isOn: configurationBinding(\.keepsDesktopLayoutsAcrossDisplays))
                    .labelsHidden().toggleStyle(.switch)
            }
            SettingsRow("When a desktop has one window", caption: "Applies in Adaptive. Keeps later size changes until another window opens or you repair the layout.") {
                Picker("When a desktop has one window", selection: configurationBinding(\.singleWindowPlacement)) {
                    Text("Leave Unchanged").tag(nil as WindowAction?)
                    ForEach(WindowAction.snapAssignableActions) { action in
                        Label { Text(action.title) } icon: { WindowActionGlyph.image(for: action, scale: glyphDisplayScale,
                                appearance: glyphColorScheme == .dark ? .dark : .light) }
                            .tag(Optional(action))
                    }
                }
                .labelsHidden().fixedSize()
            }
            SettingsRow("Leave space for Dock", caption: "Keeps the Dock's area free even when the Dock hides automatically, so windows stay put when it appears.") {
                Toggle("Leave space for Dock", isOn: configurationBinding(\.leavesSpaceForDock))
                    .labelsHidden().toggleStyle(.switch)
            }
        } footer: {
            GroupFooter(
                help: "Mode cards set this desktop only. Desktops you have not set use the default mode.",
                isAtDefault: model.configuration.defaultLayoutMode == defaults.defaultLayoutMode
                    && model.configuration.singleWindowPlacement == defaults.singleWindowPlacement
                    && model.configuration.leavesSpaceForDock == defaults.leavesSpaceForDock
                    && model.configuration.keepsDesktopLayoutsAcrossDisplays == defaults.keepsDesktopLayoutsAcrossDisplays
            ) {
                model.updateConfiguration {
                    $0.defaultLayoutMode = defaults.defaultLayoutMode
                    $0.singleWindowPlacement = defaults.singleWindowPlacement
                    $0.leavesSpaceForDock = defaults.leavesSpaceForDock
                    $0.keepsDesktopLayoutsAcrossDisplays = defaults.keepsDesktopLayoutsAcrossDisplays
                }
            }
        }
    }

    @ViewBuilder private var modeSettings: some View {
        switch settingsMode {
        case .bento: adaptiveGroup
        case .tabbed: tabbedGroup
        case .manual, .linked: manualGroup
        }
    }

    private func modeHeading(_ mode: LayoutMode) -> some View {
        HStack(spacing: SettingsSpacing.s2) {
            Text(mode.title).font(SettingsFont.headline)
            if model.activeLayoutMode == mode {
                SettingsPill("Active on this desktop", tint: .accentColor)
            }
        }
        .padding(.horizontal, SettingsSpacing.s1)
    }

    private var adaptiveGroup: some View {
        VStack(alignment: .leading, spacing: SettingsSpacing.s2) {
            modeHeading(.bento)
            SettingsGroup {
                SettingsRow("New window side", caption: "Where a new window prefers to join. Available space and window size limits may affect placement.") {
                    Picker("New window side", selection: configurationBinding(\.bentoNewWindowSide)) {
                        Text("Automatic").tag(BentoNewWindowSide.automatic)
                        Text("Left").tag(BentoNewWindowSide.left)
                        Text("Right").tag(BentoNewWindowSide.right)
                        Text("Top").tag(BentoNewWindowSide.top)
                        Text("Bottom").tag(BentoNewWindowSide.bottom)
                    }
                    .labelsHidden().fixedSize()
                }
                SettingsRow("Balance on new window", caption: "Resets pane sizes when a window joins, within its size limits. Replaces divider positions you set. Tabbed is not affected.") {
                    Toggle("Balance on new window", isOn: configurationBinding(\.bentoBalancesNewWindows))
                        .labelsHidden().toggleStyle(.switch)
                }
                paneGapRow
                SettingsRow("Swap delay", caption: "Wait before windows trade places while dragging a title bar.") {
                    Picker("Adaptive swap delay", selection: choiceBinding(\.bentoSwapHoverDelay, nearest: SwapDelayChoice.nearest)) {
                        ForEach(SwapDelayChoice.allCases, id: \.self) { choice in
                            Text(choice.title).tag(choice)
                        }
                    }
                    .labelsHidden().pickerStyle(.segmented).frame(width: 240)
                }
            } footer: {
                GroupFooter(
                    help: "Instant is 0 s, Short is 0.12 s, and Long is 0.3 s. Resizing from an edge does not activate a swap target.",
                    isAtDefault: model.configuration.bentoNewWindowSide == defaults.bentoNewWindowSide
                        && model.configuration.bentoBalancesNewWindows == defaults.bentoBalancesNewWindows
                        && model.configuration.bentoInnerGap == defaults.bentoInnerGap
                        && model.configuration.bentoSwapHoverDelay == defaults.bentoSwapHoverDelay
                ) {
                    model.updateConfiguration {
                        $0.bentoNewWindowSide = defaults.bentoNewWindowSide
                        $0.bentoBalancesNewWindows = defaults.bentoBalancesNewWindows
                        $0.bentoInnerGap = defaults.bentoInnerGap
                        $0.bentoSwapHoverDelay = defaults.bentoSwapHoverDelay
                    }
                }
            }
        }
    }

    var paneGapRow: some View {
        LayoutSliderRow("Pane gap", caption: "Space between panes, 0 to 12 pt.",
                        value: configurationBinding(\.bentoInnerGap), in: 0 ... 12, step: 1,
                        readout: "\(Int(model.configuration.bentoInnerGap)) pt",
                        paneGap: model.configuration.bentoInnerGap,
                        onEditingChanged: model.paneGapEditingChanged)
    }

    var glassTransparencyRow: some View {
        LayoutSliderRow("Glass transparency",
                        caption: "Transparent keeps the native glass effect. Popups and the menu bar panel keep a light frost so text stays readable. The Tabbed curtain always conceals hidden tabs. Accessibility display settings take priority.",
                        value: configurationBinding(\.overlayAppearance.transparency), in: 0 ... 1,
                        readout: "\(Int((model.configuration.overlayAppearance.transparency * 100).rounded()))%",
                        endpoints: ("Opaque", "Transparent"))
            .disabled(!model.configuration.overlayAppearance.useLiquidGlass)
            .opacity(model.configuration.overlayAppearance.useLiquidGlass ? 1 : 0.5)
    }

    private var tabbedGroup: some View {
        VStack(alignment: .leading, spacing: SettingsSpacing.s2) {
            modeHeading(.tabbed)
            SettingsGroup {
                VStack(alignment: .leading, spacing: SettingsSpacing.s2) {
                    Text("Starting layout")
                    Text("Used when a desktop enters Tabbed from Manual or Adaptive.")
                        .font(SettingsFont.caption).foregroundStyle(.secondary)
                    LazyVGrid(columns: PictureChoice<EmptyView>.gridColumns, alignment: .leading, spacing: SettingsSpacing.s3) {
                        ForEach(TabbedPreset.allCases, id: \.self) { preset in
                            PictureChoice(preset.title, isSelected: model.configuration.defaultTabbedPreset == preset,
                                          action: { model.updateConfiguration { $0.defaultTabbedPreset = preset } }) {
                                // Numbered pictures appear only here; the wheel, menus and gallery never number panes.
                                LayoutGlyphView(.layout(preset), size: 52, numbered: true)
                                    .foregroundStyle(model.configuration.defaultTabbedPreset == preset ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                            }
                        }
                    }
                    .frame(maxWidth: 600, alignment: .leading)
                }
                .padding(SettingsSpacing.s3)
                SettingsRow("Place windows", caption: "Keep Adaptive panes applies only when switching from Adaptive.") {
                    Picker("Place windows", selection: tabbedEntryPlacementBinding) {
                        ForEach(TabbedEntryPlacement.allCases, id: \.self) { placement in
                            Text(placement.title).tag(placement)
                        }
                    }
                    .labelsHidden().fixedSize()
                }
                if model.activeLayoutMode == .tabbed {
                    SettingsRow("Apply starting layout", caption: "Uses \(model.configuration.defaultTabbedPreset.title) and keeps the current tab groups.") {
                        Button("Apply to This Desktop") {
                            model.performTabbed(.preset(model.configuration.defaultTabbedPreset))
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                SettingsRow("Tab bar presentation", caption: "Auto-hide reveals the bar after a short hover. Show Tab Bar gives it keyboard focus. Revealing it keeps windows in place.") {
                    Picker("Tab bar presentation", selection: configurationBinding(\.tabbedStripPresentation)) {
                        ForEach(TabbedStripPresentation.allCases, id: \.self) { presentation in
                            Text(presentation.title).tag(presentation)
                        }
                    }
                    .labelsHidden().fixedSize()
                }
                SettingsRow("Restore pane size when switching tabs", caption: "A tab can grow its pane. Switching to a smaller tab restores the size you set.") {
                    Toggle("Restore pane size when switching tabs", isOn: configurationBinding(\.tabbedRestoresPaneSizes))
                        .labelsHidden().toggleStyle(.switch)
                }
            } footer: {
                GroupFooter(
                    help: "Select a tab to focus its window. Drag tabs between panes or onto an edge to split. Drag a divider to resize. Escape cancels the drag. Apply to This Desktop appears while Tabbed is active.",
                    isAtDefault: tabbedSettingsAreAtDefault,
                    reset: resetTabbedSettings
                )
            }
        }
    }

    var tabbedEntryPlacementBinding: Binding<TabbedEntryPlacement> {
        configurationBinding(\.tabbedEntryPlacement)
    }

    var tabbedSettingsAreAtDefault: Bool {
        model.configuration.defaultTabbedPreset == defaults.defaultTabbedPreset
            && model.configuration.tabbedEntryPlacement == defaults.tabbedEntryPlacement
            && model.configuration.tabbedStripPresentation == defaults.tabbedStripPresentation
            && model.configuration.tabbedRestoresPaneSizes == defaults.tabbedRestoresPaneSizes
    }

    func resetTabbedSettings() {
        model.updateConfiguration {
            $0.defaultTabbedPreset = defaults.defaultTabbedPreset
            $0.tabbedEntryPlacement = defaults.tabbedEntryPlacement
            $0.tabbedStripPresentation = defaults.tabbedStripPresentation
            $0.tabbedRestoresPaneSizes = defaults.tabbedRestoresPaneSizes
        }
    }

    private var manualGroup: some View {
        VStack(alignment: .leading, spacing: SettingsSpacing.s2) {
            modeHeading(.manual)
            SettingsGroup {
                SettingsRow("Resize adjacent windows together", caption: "When windows share an edge, resizing one adjusts its neighbor. Available in Manual mode only.") {
                    Toggle("Resize adjacent windows together", isOn: configurationBinding(\.linkedResizeEnabled))
                        .labelsHidden().toggleStyle(.switch)
                }
            } footer: {
                GroupFooter(help: "Manual keeps macOS windows with BetterTile snapping. Repair Layout stays available.",
                            isAtDefault: model.configuration.linkedResizeEnabled == defaults.linkedResizeEnabled) {
                    model.updateConfiguration { $0.linkedResizeEnabled = defaults.linkedResizeEnabled }
                }
            }
        }
    }

    var resizeGroup: some View {
        SettingsGroup("Resize", aside: "All modes") {
            SettingsRow("Window feedback", caption: "Resize Preview shows outlines until you release. Live Resize moves windows during the drag.") {
                Picker("Window feedback", selection: configurationBinding(\.resizeFeedbackMode)) {
                    Text("Resize Preview").tag(ResizeFeedbackMode.ghost)
                    Text("Live Resize").tag(ResizeFeedbackMode.live)
                }
                .labelsHidden().pickerStyle(.segmented).frame(width: 260)
            }
            SettingsRow("Divider width", caption: "A handle appears near a shared edge. Glass handles are 4 pt wider than this setting.") {
                LazyVGrid(columns: PictureChoice<EmptyView>.gridColumns, spacing: SettingsSpacing.s3) {
                    ForEach(DividerWidthChoice.allCases, id: \.self) { choice in
                        PictureChoice(choice.title, detail: "\(Int(choice.rawValue)) pt",
                                      isSelected: DividerWidthChoice.nearest(to: model.configuration.dividerThickness) == choice,
                                      action: { model.updateConfiguration { $0.dividerThickness = choice.rawValue } }) {
                            DividerChoiceThumbnail(thickness: choice.rawValue, overlayAppearance: model.configuration.overlayAppearance)
                        }
                    }
                }
                .frame(width: 396)
                .padding(.vertical, SettingsSpacing.s2)
            }
            DividerResizePreview(
                thickness: model.configuration.dividerThickness,
                feedback: model.configuration.resizeFeedbackMode,
                paneGap: model.configuration.bentoInnerGap,
                overlayAppearance: model.configuration.overlayAppearance
            )
            .padding(SettingsSpacing.s3)
        } footer: {
            GroupFooter(
                help: "Drag the grip to try the width. The preview is drawn at real size and never moves your windows. Earlier values between 2 and 12 pt round to the nearest choice.",
                isAtDefault: model.configuration.resizeFeedbackMode == defaults.resizeFeedbackMode
                    && model.configuration.dividerThickness == defaults.dividerThickness
            ) {
                model.updateConfiguration {
                    $0.resizeFeedbackMode = defaults.resizeFeedbackMode
                    $0.dividerThickness = defaults.dividerThickness
                }
            }
        }
    }

    private var appearanceGroup: some View {
        SettingsGroup("Appearance") {
            SettingsRow("Use Liquid Glass", caption: "Tab bars, dividers, the Layout Wheel, and the menu bar panel.") {
                Toggle("Use Liquid Glass", isOn: configurationBinding(\.overlayAppearance.useLiquidGlass))
                    .labelsHidden().toggleStyle(.switch)
            }
            glassTransparencyRow
        } footer: {
            GroupFooter(
                help: "Adjust from Opaque to Transparent. The default transparency is 50%.",
                isAtDefault: model.configuration.overlayAppearance == defaults.overlayAppearance
            ) {
                model.updateConfiguration { $0.overlayAppearance = defaults.overlayAppearance }
            }
        }
    }

    private func choiceBinding<Choice: RawRepresentable>(
        _ keyPath: WritableKeyPath<BetterTileConfiguration, Double>,
        nearest: @escaping (Double) -> Choice
    ) -> Binding<Choice> where Choice.RawValue == Double {
        Binding(get: { nearest(model.configuration[keyPath: keyPath]) },
                set: { choice in model.updateConfiguration { $0[keyPath: keyPath] = choice.rawValue } })
    }

    private func configurationBinding<Value>(
        _ keyPath: WritableKeyPath<BetterTileConfiguration, Value>
    ) -> Binding<Value> {
        Binding(get: { model.configuration[keyPath: keyPath] },
                set: { value in model.updateConfiguration { $0[keyPath: keyPath] = value } })
    }
}

/// The badges that follow a Window mode title: "This desktop" and "Default", 4 pt apart.
struct ModeBadges: View {
    let isThisDesktop: Bool
    let isDefault: Bool

    var body: some View {
        // Side by side when they fit. In a very narrow column they stack, so they never clip.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: SettingsSpacing.s1) { pills }
            VStack(alignment: .leading, spacing: SettingsSpacing.s1) { pills }
        }
    }

    @ViewBuilder private var pills: some View {
        if isThisDesktop { SettingsPill("This desktop", tint: .accentColor) }
        if isDefault { SettingsPill("Default") }
    }
}

private struct ModeThumbnail: View {
    let mode: LayoutMode
    let isSelected: Bool

    var body: some View {
        // 52 pt canvas, Regular: a 3.25 pt stroke. Accent when chosen, secondary label otherwise. Nothing else sits in the picture.
        LayoutGlyphView(.mode(mode), size: 52)
            .foregroundStyle(isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
    }
}

/// Continuous controls share the label/value alignment and padding of SettingsRow.
private struct LayoutSliderRow: View {
    let title: String
    let caption: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double?
    let readout: String
    let endpoints: (String, String)?
    let paneGap: Double?
    let onEditingChanged: (Bool) -> Void

    init(_ title: String, caption: String, value: Binding<Double>, in range: ClosedRange<Double>,
         step: Double? = nil, readout: String, endpoints: (String, String)? = nil,
         paneGap: Double? = nil, onEditingChanged: @escaping (Bool) -> Void = { _ in }) {
        self.title = title
        self.caption = caption
        _value = value
        self.range = range
        self.step = step
        self.readout = readout
        self.endpoints = endpoints
        self.paneGap = paneGap
        self.onEditingChanged = onEditingChanged
    }

    var body: some View {
        SettingsRow(title, caption: caption) {
            HStack(spacing: SettingsSpacing.s2) {
                if let paneGap {
                    HStack(spacing: paneGap) {
                        LayoutSampleWindow()
                        LayoutSampleWindow()
                    }
                    // Points are not scaled: a 12 pt setting draws a 12 pt gap.
                    .frame(width: 64, height: 40)
                    .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: SettingsSpacing.s2) {
                        Group {
                            if let step {
                                Slider(value: $value, in: range, step: step, onEditingChanged: onEditingChanged) { Text(title) }
                            } else {
                                Slider(value: $value, in: range, onEditingChanged: onEditingChanged) { Text(title) }
                            }
                        }
                        .labelsHidden()
                        .frame(width: 220)
                        Text(readout)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 44, alignment: .trailing)
                    }
                    if let endpoints {
                        HStack {
                            Text(endpoints.0)
                            Spacer()
                            Text(endpoints.1)
                        }
                        .font(SettingsFont.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 220)
                    }
                }
            }
            // Keep the control column intact at every Settings window width.
            .fixedSize(horizontal: true, vertical: false)
            .padding(.vertical, SettingsSpacing.s1)
        }
    }
}

private struct DividerChoiceThumbnail: View {
    let thickness: Double
    let overlayAppearance: OverlayAppearance

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                HStack(spacing: 20) {
                    LayoutSampleWindow()
                    LayoutSampleWindow()
                }
                .padding(6)
                DividerGrip(axis: .vertical, length: max(24, proxy.size.height - 12),
                            thickness: thickness, active: false, overlayAppearance: overlayAppearance)
            }
        }
    }
}

/// The same window drawing is used beside Pane gap and behind divider choices.
private struct LayoutSampleWindow: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 2) {
                ForEach(0 ..< 3) { index in
                    Circle()
                        .fill([SettingsColor.pink, SettingsColor.orange, SettingsColor.green][index].opacity(0.8))
                        .frame(width: 3, height: 3)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 4)
            .frame(height: 12)
            .background(SettingsColor.fill)
            VStack(alignment: .leading, spacing: 4) {
                RoundedRectangle.settings(SettingsRadius.mini)
                    .fill(.secondary.opacity(0.25)).frame(height: 3)
                RoundedRectangle.settings(SettingsRadius.mini)
                    .fill(.secondary.opacity(0.15)).frame(height: 3)
                    .padding(.trailing, 7)
            }
            .padding(.horizontal, 4)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(SettingsColor.controlBackground)
        .clipShape(.settings(SettingsRadius.mini))
        .overlay(RoundedRectangle.settings(SettingsRadius.mini).strokeBorder(SettingsColor.controlBorder, lineWidth: 0.5))
    }
}

private extension LayoutMode {
    var explanation: String {
        switch self {
        case .manual: "Use macOS windows with BetterTile snapping."
        case .linked: "Adjacent snapped windows share resize boundaries."
        case .bento: "Windows join a stable split layout that adapts as windows change."
        case .tabbed: "Group windows in resizable panes with tabs. Turn off Stage Manager."
        }
    }
}
