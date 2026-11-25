// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 LMC-Karma

import AppKit
import BetterTileCore
import BetterTileMacOS
import SwiftUI

enum SetupPage: Int, CaseIterable, Identifiable {
    case welcome
    case accessibility
    case mode
    case compatibility
    case features

    var id: Self { self }

    var title: String {
        switch self {
        case .welcome: "Welcome"
        case .accessibility: "Accessibility"
        case .mode: "Starting Mode"
        case .compatibility: "macOS Compatibility"
        case .features: "Things to Try"
        }
    }

    init?(diagnosticName: String) {
        switch diagnosticName.lowercased() {
        case "welcome": self = .welcome
        case "accessibility": self = .accessibility
        case "mode": self = .mode
        case "compatibility": self = .compatibility
        case "features": self = .features
        default: return nil
        }
    }
}

struct SetupAssistantView: View {
    static let currentVersion = 1

    @Bindable var model: BetterTileModel
    @State private var page: SetupPage
    /// Applied at Finish, so Adaptive never rearranges windows while setup is open.
    @State private var startingMode: LayoutMode
    @State private var feature: SetupFeature = .snap
    let close: () -> Void

    init(model: BetterTileModel, initialPage: SetupPage, close: @escaping () -> Void) {
        self.model = model
        _page = State(initialValue: initialPage)
        _startingMode = State(initialValue: model.configuration.defaultLayoutMode.availableMode)
        self.close = close
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                pageContent
                    .frame(maxWidth: 610, alignment: .topLeading)
                    .padding(.horizontal, 34)
                    .padding(.vertical, 28)
                    .frame(maxWidth: .infinity, minHeight: 400, alignment: .top)
            }
            Divider()
            navigation
        }
        .frame(minWidth: 680, minHeight: 560)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("BetterTile Setup")
                        .font(.headline)
                    Text(page.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("Step \(page.rawValue + 1) of \(SetupPage.allCases.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            ProgressView(
                value: Double(page.rawValue + 1),
                total: Double(SetupPage.allCases.count)
            )
            .accessibilityLabel("Setup progress")
            .accessibilityValue("Step \(page.rawValue + 1) of \(SetupPage.allCases.count)")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    @ViewBuilder
    private var pageContent: some View {
        switch page {
        case .welcome:
            welcomePage
        case .accessibility:
            accessibilityPage
        case .mode:
            modePage
        case .compatibility:
            compatibilityPage
        case .features:
            featuresPage
        }
    }

    private var welcomePage: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text("Welcome to BetterTile")
                        .font(.largeTitle.weight(.semibold))
                    Text("BETA")
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(.orange.opacity(0.16), in: Capsule())
                        .foregroundStyle(.orange)
                }
                Text("Put windows side by side and keep them there, without hunting for gaps or overlaps.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            GroupBox {
                HStack(alignment: .top, spacing: SettingsSpacing.s4) {
                    SetupClipView(clip: .hero, caption: "Repair Layout arranges three windows")
                        .frame(maxWidth: .infinity)
                    VStack(alignment: .leading, spacing: 14) {
                        welcomePoint(
                            "Pick how windows behave",
                            detail: "Arrange windows yourself, or let BetterTile lay them out. You choose in step 3.",
                            symbol: "rectangle.split.2x1"
                        )
                        welcomePoint(
                            "One permission",
                            detail: "Accessibility lets BetterTile move and resize windows. Nothing else is requested.",
                            symbol: "hand.raised.fill"
                        )
                        welcomePoint(
                            "Stays on this Mac",
                            detail: "Your settings and window information never leave this computer.",
                            symbol: "lock.shield.fill"
                        )
                    }
                    .frame(width: 230, alignment: .leading)
                }
                .padding(6)
            }

            Text("Setup takes about two minutes. Close it any time; it reopens from the menu bar.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var accessibilityPage: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Allow BetterTile to manage windows")
                .font(.largeTitle.weight(.semibold))
            Text(
                "BetterTile uses the public macOS Accessibility API to read, move, and resize "
                    + "eligible windows. It observes global left-button ordering for snapping "
                    + "and linked resizing. Layout Wheel observes its configured modifiers and, "
                    + "only during a gesture, limited keys and pointer movement. Its optional "
                    + "Middle Click trigger reserves the chosen plain or Option–middle click system-wide while "
                    + "enabled. BetterTile does not request Screen Recording or Input Monitoring."
            )
            .font(.body)
            .foregroundStyle(.secondary)

            GroupBox {
                VStack(alignment: .leading, spacing: 16) {
                    AccessibilityPermissionStatus(model: model)

                    if !model.hasAccessibilityPermission {
                        Text("1. Request access or open Accessibility settings.")
                        Text("2. Turn on BetterTile in the application list.")
                        Text("3. Return here; the status updates automatically.")

                        HStack(spacing: 10) {
                            Button("Request Access…") { model.requestAccessibilityPermission() }
                                .buttonStyle(.borderedProminent)
                            Button("Open Accessibility Settings") {
                                model.openAccessibilitySettings()
                            }
                            Button("Check Again") { model.recheckAccessibilityPermission() }
                        }

                    } else {
                        Text("BetterTile is ready to manage windows. You can continue setup.")
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(6)
            }

            Label(
                "Accessibility is the only required setup item. You may view the remaining pages now, but Finish stays disabled until access is granted.",
                systemImage: "info.circle"
            )
            .font(.callout)
            .foregroundStyle(.secondary)
        }
    }

    private var modePage: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("How should BetterTile handle your windows?")
                    .font(.largeTitle.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text("Choose a starting mode. Snapping and linked resizing work in every mode.")
                    .foregroundStyle(.secondary)
            }

            HStack(alignment: .top, spacing: SettingsSpacing.s3) {
                ForEach(LayoutMode.availableModes, id: \.self) { mode in
                    PictureChoice(
                        mode.title,
                        detail: mode.setupSummary,
                        badge: mode == .manual ? "New to tiling" : nil,
                        isSelected: startingMode == mode,
                        thumbnailHeight: WindowLayoutSettings.modePictureHeight,
                        action: { startingMode = mode }
                    ) {
                        LayoutGlyphView(.mode(mode), size: 52)
                            .foregroundStyle(startingMode == mode
                                ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }

            GroupBox {
                HStack(alignment: .top, spacing: SettingsSpacing.s4) {
                    SetupClipView(clip: startingMode.setupClip)
                        .frame(maxWidth: .infinity)
                    VStack(alignment: .leading, spacing: 10) {
                        Text(startingMode.title)
                            .font(.title3.weight(.semibold))
                        Text(startingMode.setupDescription)
                            .fixedSize(horizontal: false, vertical: true)
                        setupFact("Good for", startingMode.setupGoodFor)
                        setupFact("When you select Finish", startingMode.setupFinishEffect)
                    }
                    .frame(width: 210, alignment: .leading)
                }
                .padding(6)
            }

            Text("This mode applies to all desktops. Later, give any desktop its own mode from the menu bar, or change it in Settings ▸ Window Layout.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func setupFact(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var compatibilityPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("BetterTile and macOS window tiling")
                .font(.largeTitle.weight(.semibold))
            Text(
                "macOS has its own window tiling. BetterTile is built to sit alongside it, "
                    + "so you do not have to give either one up."
            )
            .foregroundStyle(.secondary)

            RecommendationCard(
                title: "Move & Resize keeps working",
                symbol: "rectangle.split.2x1",
                explanation:
                    "Window ▸ Move & Resize and its keyboard equivalents work as they always did. "
                        + "Adaptive recognises where macOS put a window and adopts that arrangement, "
                        + "so you can tile with either and carry on resizing with BetterTile's dividers.",
                directions: [
                    "Nothing to change. Use whichever you reach for.",
                ],
                isAcknowledged: nil
            )

            RecommendationCard(
                title: "Pick one way to drag",
                symbol: "hand.draw",
                explanation:
                    "Dragging to a screen edge is the one place the two overlap: macOS and BetterTile "
                        + "would both try to interpret the same drag. Adaptive adopts the result either way, "
                        + "so this is about which one you want to feel.",
                directions: [
                    "Keep BetterTile Drag Snapping on for BetterTile's zones and previews, or",
                    "Turn it off in Settings ▸ General and use macOS's edge tiling instead.",
                    "Your snap zones are kept either way.",
                ],
                isAcknowledged: configurationBinding(
                    \.macOSTilingRecommendationAcknowledged
                )
            )

            RecommendationCard(
                title: "Choose Stage Manager behavior",
                symbol: "uiwindow.split.2x1",
                explanation:
                    "BetterTile resolves a Stage Manager thumbnail to one real window and leaves "
                        + "the rest of its group alone. Adaptive behavior is still most predictable "
                        + "when Stage Manager is off.",
                directions: [
                    "Leave Stage Manager on for single-window thumbnail drags, or",
                    "Turn it off in Desktop & Dock or Control Center for ordinary Adaptive desktops.",
                ],
                isAcknowledged: configurationBinding(
                    \.stageManagerRecommendationAcknowledged
                )
            )

            Button("Open Desktop & Dock Settings") { openDesktopAndDockSettings() }
            Text("If the button does not reach the section directly, choose Desktop & Dock in the System Settings sidebar.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var featuresPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Things to try first")
                    .font(.largeTitle.weight(.semibold))
                Text("Select a feature to watch it. Each one works right after setup.")
                    .foregroundStyle(.secondary)
            }

            HStack(alignment: .top, spacing: SettingsSpacing.s4) {
                GroupBox {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(SetupFeature.allCases) { item in
                            featureRow(item)
                        }
                    }
                }
                .frame(width: 236)

                VStack(alignment: .leading, spacing: 10) {
                    SetupClipView(clip: feature.clip)
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "sparkle")
                            .foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("TRY IT NOW")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.tint)
                            Text(feature.tryIt)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(SettingsColor.fill, in: .settings(SettingsRadius.inner))
                }
                .frame(maxWidth: .infinity)
            }

            HStack(spacing: 10) {
                Link(destination: URL(string: "https://lmc-karma.github.io/BetterTile/")!) {
                    Label("Full Guide on the Website", systemImage: "arrow.up.forward.square")
                }
                Link(
                    "Report a Bug",
                    destination: URL(
                        string: "https://github.com/LMC-Karma/BetterTile/issues/new?template=bug.yml"
                    )!
                )
                Link(
                    "Suggest an Improvement",
                    destination: URL(
                        string: "https://github.com/LMC-Karma/BetterTile/issues/new?template=feature.yml"
                    )!
                )
            }
            .buttonStyle(.bordered)
        }
    }

    private func featureRow(_ item: SetupFeature) -> some View {
        Button {
            feature = item
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: item.symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(item.tint, in: .settings(SettingsRadius.mini))
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title)
                        .font(.headline)
                    Text(item.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .background(
                feature == item ? AnyShapeStyle(Color.accentColor.opacity(0.14)) : AnyShapeStyle(.clear),
                in: .settings(SettingsRadius.control)
            )
        }
        .buttonStyle(.plain)
    }

    private var navigation: some View {
        HStack(spacing: 10) {
            Button("Set Up Later", action: close)
                .keyboardShortcut(.cancelAction)

            Spacer()

            if page != .welcome {
                Button("Back") {
                    page = SetupPage(rawValue: page.rawValue - 1) ?? .welcome
                }
            }

            if page != .features {
                Button("Continue") {
                    page = SetupPage(rawValue: page.rawValue + 1) ?? .features
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            } else {
                Label("Starting mode: \(startingMode.title)", systemImage: "rectangle.split.2x1")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !model.hasAccessibilityPermission {
                    Label("Accessibility is still required", systemImage: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                Button("Finish") { finishSetup() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.hasAccessibilityPermission)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    private func welcomePoint(_ title: String, detail: String, symbol: String) -> some View {
        featurePoint(title, detail: detail, symbol: symbol)
    }

    private func featurePoint(_ title: String, detail: String, symbol: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func configurationBinding(
        _ keyPath: WritableKeyPath<BetterTileConfiguration, Bool>
    ) -> Binding<Bool> {
        Binding(
            get: { model.configuration[keyPath: keyPath] },
            set: { value in
                model.updateConfiguration { $0[keyPath: keyPath] = value }
            }
        )
    }

    private func openDesktopAndDockSettings() {
        let paneURL = URL(
            string: "x-apple.systempreferences:com.apple.Desktop-Settings.extension"
        )!
        guard !NSWorkspace.shared.open(paneURL),
              let settingsURL = NSWorkspace.shared.urlForApplication(
                  withBundleIdentifier: "com.apple.systempreferences"
              )
        else { return }
        NSWorkspace.shared.open(settingsURL)
    }

    private func finishSetup() {
        guard model.hasAccessibilityPermission else { return }
        model.updateConfiguration {
            $0.setupCompletionVersion = Self.currentVersion
        }
        close()
        model.applyStartingMode(startingMode)
        model.flushConfiguration()
    }
}

struct AccessibilityPermissionStatus: View {
    @Bindable var model: BetterTileModel

    var body: some View {
        HStack(spacing: 8) {
            Label(
                model.hasAccessibilityPermission
                    ? "Accessibility Granted"
                    : "Accessibility Required",
                systemImage: model.hasAccessibilityPermission
                    ? "checkmark.circle.fill"
                    : "xmark.circle.fill"
            )
            .font(.headline)
            .foregroundStyle(model.hasAccessibilityPermission ? .green : .red)
            Spacer()
            if model.isWaitingForAccessibilityPermission {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Checking…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            model.isWaitingForAccessibilityPermission
                ? "Accessibility status: checking for access"
                : model.hasAccessibilityPermission
                ? "Accessibility status: granted"
                : "Accessibility status: required"
        )
    }
}

private struct RecommendationCard: View {
    let title: String
    let symbol: String
    let explanation: String
    let directions: [String]
    /// Nil for a card that only explains something, with nothing for the user
    /// to confirm.
    var isAcknowledged: Binding<Bool>?

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: symbol)
                        .font(.title2)
                        .foregroundStyle(.secondary)
                        .frame(width: 28)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title)
                            .font(.headline)
                        if let isAcknowledged {
                            Label(
                                isAcknowledged.wrappedValue
                                    ? "Confirmed by you"
                                    : "Your choice — either works",
                                systemImage: isAcknowledged.wrappedValue
                                    ? "checkmark.circle.fill"
                                    : "questionmark.circle.fill"
                            )
                            .font(.callout.weight(.medium))
                            .foregroundStyle(isAcknowledged.wrappedValue ? .green : .secondary)
                        } else {
                            Label("Nothing to change", systemImage: "checkmark.circle.fill")
                                .font(.callout.weight(.medium))
                                .foregroundStyle(.green)
                        }
                    }
                }

                Text(explanation)
                    .font(.callout)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(directions.enumerated()), id: \.offset) { index, direction in
                        Text("\(index + 1). \(direction)")
                            .font(.caption)
                    }
                }

                if let isAcknowledged {
                    Toggle("Done — I have chosen", isOn: isAcknowledged)
                }
            }
            .padding(6)
        }
    }
}

/// A feature on the Setup Assistant's last page, with the clip that shows it.
private enum SetupFeature: CaseIterable, Identifiable {
    case snap, resize, wheel, keys, saved, repair

    var id: Self { self }

    var title: String {
        switch self {
        case .snap: "Snap to edges"
        case .resize: "Resize together"
        case .wheel: "Layout Wheel"
        case .keys: "Keyboard shortcuts"
        case .saved: "Saved Layouts"
        case .repair: "Repair Layout"
        }
    }

    var summary: String {
        switch self {
        case .snap: "Drag a window to an edge or corner"
        case .resize: "Neighbors follow a shared border"
        case .wheel: "Pick a position at the pointer"
        case .keys: "Halves, thirds, quarters, displays"
        case .saved: "Bring back a whole arrangement"
        case .repair: "Tidy a messy desktop in one step"
        }
    }

    var tryIt: String {
        switch self {
        case .snap: "Drag any window to the left edge of the screen. Release when the preview appears."
        case .resize: "Snap two windows side by side, then drag the border between them."
        case .wheel: "Hold Control, Option and Shift. The wheel opens at the pointer. Move toward a position and release."
        case .keys: "Press Control-Option-Left Arrow to move the front window to the left half. Control-Option-Return fills the screen."
        case .saved: "Arrange a few windows, then choose Save Current Layout in Settings ▸ Saved Layouts. Apply it later from the menu bar."
        case .repair: "Open the BetterTile menu bar icon and choose Repair Layout."
        }
    }

    var symbol: String {
        switch self {
        case .snap: "rectangle.lefthalf.filled"
        case .resize: "arrow.left.and.right"
        case .wheel: "circle.circle"
        case .keys: "keyboard"
        case .saved: "bookmark"
        case .repair: "wrench.adjustable"
        }
    }

    var tint: Color {
        switch self {
        case .snap: .blue
        case .resize: .teal
        case .wheel: .purple
        case .keys: .gray
        case .saved: .indigo
        case .repair: .green
        }
    }

    var clip: SetupClip {
        switch self {
        case .snap: .snap
        case .resize: .resize
        case .wheel: .wheel
        case .keys: .keys
        case .saved: .saved
        case .repair: .repair
        }
    }
}

/// The Setup Assistant's words for each starting mode.
private extension LayoutMode {
    var setupSummary: String {
        switch self {
        case .manual, .linked: "You place windows. BetterTile helps when asked."
        case .bento: "BetterTile arranges windows side by side."
        case .tabbed: "Panes that hold windows as tabs."
        }
    }

    var setupDescription: String {
        switch self {
        case .manual, .linked:
            "Windows stay where you put them. When you want order, drag a window to a screen edge to snap it, "
                + "or drag the border between two windows to resize both."
        case .bento:
            "BetterTile arranges up to six windows side by side. A new window takes room from the others, "
                + "and a closed window gives its room back."
        case .tabbed:
            "The screen splits into panes. Each pane holds several windows as tabs, so you switch with one "
                + "click instead of searching for a window."
        }
    }

    var setupGoodFor: String {
        switch self {
        case .manual, .linked: "Trying BetterTile without changing how you work."
        case .bento: "Keeping every window visible without arranging them yourself."
        case .tabbed: "Many windows of a few kinds, such as documents. Works best with Stage Manager off."
        }
    }

    var setupFinishEffect: String {
        switch self {
        case .manual, .linked: "Nothing moves. Your windows stay where they are."
        case .bento: "BetterTile arranges the visible windows on each desktop."
        case .tabbed: "BetterTile puts the visible windows on each desktop into panes as tabs."
        }
    }

    var setupClip: SetupClip {
        switch self {
        case .manual, .linked: .snap
        case .bento: .adaptive
        case .tabbed: .tabbed
        }
    }
}
