// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 LMC-Karma
// Contains portions adapted from Vorssaint, Copyright (C) 2026 Vorssaint.

import AppKit
import BetterTileCore
import BetterTileMacOS
import SwiftUI

struct GeneralSettings: View {
    @Bindable var model: BetterTileModel
#if !DEBUG
    @Bindable var updatePresentation: UpdatePresentationModel
    @Binding var automaticallyChecksForUpdates: Bool
    let checkForUpdates: () -> Void
#endif
    let openSetup: () -> Void
    let search: String
    let openShortcuts: () -> Void
    let openSnapZones: () -> Void
    var launchAtLogin: any LaunchAtLoginService = SystemLaunchAtLogin.shared
    var applyAppIcon: (AppIconStyle) -> Bool = { AppIconStyle.apply($0) }
    @State private var launchAtLoginState: LaunchAtLoginState = .off
    @State private var privacyExpanded = false
    @State private var finderIconUpdateFailed = false
    @AppStorage(AppAppearance.defaultsKey) private var appearanceRawValue = AppAppearance.system.rawValue
    @AppStorage(AppIconStyle.defaultsKey) private var appIconRawValue = AppIconStyle.defaultStyle.rawValue
    @State private var shownLegalDocument: LegalDocument?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SettingsSpacing.s5) {
                if !model.hasAccessibilityPermission {
                    accessibilityNotice
                }
                statusCards
                startup
                appearance
                keyboard
                updates
                compatibility
                privacy
                about
                StatusMessage(model: model)
            }
            .padding(SettingsSpacing.s6)
        }
        .font(SettingsFont.body)
        .controlSize(.regular)
        .sheet(item: $shownLegalDocument) { LegalDocumentView(document: $0) }
        .onAppear {
            refreshLaunchAtLogin()
            revealSearchResults()
        }
        .onChange(of: search) { revealSearchResults() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // The user can change Login Items in System Settings while Settings is open.
            refreshLaunchAtLogin()
        }
    }

    // MARK: - Status

    /// One notice with one action. macOS shows its Accessibility prompt only once,
    /// so after the first request the action opens System Settings instead.
    @ViewBuilder
    private var accessibilityNotice: some View {
        if model.configuration.accessibilityPromptRequested {
            NoticeBanner(
                .problem,
                title: "Enable Accessibility in System Settings",
                message: "macOS shows its prompt only once. Enable BetterTile in Accessibility settings; "
                    + "it checks again when you return.",
                action: .init(title: "Open Accessibility Settings", isPrimary: true) {
                    model.openAccessibilitySettings()
                }
            )
        } else {
            NoticeBanner(
                .problem,
                title: "Accessibility access needed",
                message: "Allow BetterTile to inspect, move and resize windows. macOS shows its prompt only once.",
                action: .init(title: "Request Access…", isPrimary: true) {
                    model.requestAccessibilityPermission()
                }
            )
        }
    }

    private var statusCards: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 150), spacing: SettingsSpacing.s3, alignment: .top)],
            spacing: SettingsSpacing.s3
        ) {
            accessibilityCard
            StatusCard("Default mode", glyph: .mode(model.configuration.defaultLayoutMode), value: defaultModeTitle,
                       caption: "New desktops start here.", tint: .accentColor)
            updatesCard
            StatusCard("Shortcuts", systemImage: "keyboard",
                       value: model.configuration.keyboardShortcutsEnabled ? "On" : "Off",
                       caption: "\(assignedShortcutCount) shortcuts set.", tint: SettingsColor.purple)
        }
    }

    @ViewBuilder
    private var accessibilityCard: some View {
        if model.hasAccessibilityPermission {
            StatusCard("Accessibility", systemImage: "checkmark.circle.fill", value: "Granted",
                       caption: "Windows can move and resize.", tint: SettingsColor.green)
        } else if model.isWaitingForAccessibilityPermission {
            StatusCard("Accessibility", systemImage: "hourglass", value: "Checking…",
                       caption: "Waiting for System Settings.", tint: SettingsColor.orange)
        } else {
            StatusCard("Accessibility", systemImage: "exclamationmark.triangle.fill", value: "Required",
                       caption: "Windows cannot move yet.", tint: SettingsColor.red, valueTint: SettingsColor.red)
        }
    }

    @ViewBuilder
    private var updatesCard: some View {
#if DEBUG
        StatusCard("Updates", systemImage: "arrow.clockwise", value: "Unavailable",
                   caption: "Development build.", tint: SettingsColor.gray)
#else
        if let update = updatePresentation.state.availableUpdate {
            StatusCard("Updates", systemImage: "arrow.down.circle.fill", value: "\(update.displayVersion) available",
                       caption: "See Updates below.", tint: SettingsColor.orange, valueTint: SettingsColor.orange)
        } else {
            StatusCard("Updates", systemImage: "arrow.clockwise",
                       value: automaticallyChecksForUpdates ? "Automatic" : "Manual",
                       caption: automaticallyChecksForUpdates ? "Checks run automatically." : "Automatic checks are off.",
                       tint: SettingsColor.gray)
        }
#endif
    }

    // MARK: - Groups

    private var startup: some View {
        SettingsGroup("Startup") {
            SettingsRow("Launch at login", caption: launchAtLoginCaption) {
                HStack(spacing: SettingsSpacing.s2) {
                    if launchAtLoginState == .needsApproval {
                        Button("Open Login Items…") { launchAtLogin.openLoginItemsSettings() }
                    }
                    Toggle("Launch at login", isOn: launchAtLoginBinding)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .disabled(launchAtLoginState == .unavailable)
                }
            }
            SettingsRow(
                "Show menu bar icon",
                caption: model.configuration.showMenuBarIcon
                    ? nil
                    : "To open Settings, open BetterTile again from Finder or Spotlight."
            ) {
                Toggle("Show menu bar icon", isOn: configurationBinding(\.showMenuBarIcon))
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
            SettingsRow("Show Dock icon", caption: "Also lists BetterTile in Cmd-Tab.") {
                Toggle("Show Dock icon", isOn: configurationBinding(\.showDockIcon))
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
            SettingsRow(
                "App icon",
                caption: model.configuration.showDockIcon
                    ? "Changes BetterTile’s icon in the Dock and Finder."
                    : "Changes BetterTile’s icon in Finder. Turn on Show Dock icon above to display it in the Dock."
            ) {
                AppIconPicker(
                    selectedRawValue: $appIconRawValue,
                    finderIconUpdateFailed: $finderIconUpdateFailed,
                    applyAppIcon: applyAppIcon
                )
            }
        } footer: {
            GroupFooter(
                help: "Reset to Default leaves Launch at login as it is; macOS keeps that setting.",
                isAtDefault: startupIsAtDefault
            ) {
                finderIconUpdateFailed = !Self.resetStartup(
                    model: model, iconRawValue: $appIconRawValue, applyAppIcon: applyAppIcon
                )
            }
        }
    }

    private var appearance: some View {
        SettingsGroup("Appearance") {
            SettingsRow("BetterTile appearance", caption: "System follows the macOS appearance.") {
                Picker("BetterTile appearance", selection: appearanceBinding) {
                    ForEach(AppAppearance.allCases) { appearance in
                        Text(appearance.title).tag(appearance)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
        }
    }

    private var keyboard: some View {
        SettingsGroup("Keyboard") {
            SettingsRow("Setup Assistant", caption: "Review permissions and window controls.") {
                Button("Open Setup Assistant…", action: openSetup)
            }
        } footer: {
            HStack(spacing: 0) {
                Text("Change shortcuts in ")
                Button("Shortcuts", action: openShortcuts).buttonStyle(.link)
                Text(". Drag snapping is in ")
                Button("Snap Zones", action: openSnapZones).buttonStyle(.link)
                Text(".")
            }
            .font(SettingsFont.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, SettingsSpacing.s3)
        }
    }

    private var updates: some View {
        SettingsGroup("Updates") {
#if DEBUG
            SettingsRow("BetterTile updates", caption: "Version \(installedVersion). Updates are unavailable in development builds.") {
                EmptyView()
            }
            SettingsRow("Development details", caption: "Use an Apple Development Personal Team for permission persistence across rebuilds.") {
                Image(systemName: "hammer").foregroundStyle(.secondary)
            }
#else
            SettingsRow("Automatically check for updates") {
                Toggle("Automatically check for updates", isOn: $automaticallyChecksForUpdates)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
            if let update = updatePresentation.state.availableUpdate {
                SettingsRow("BetterTile updates", caption: "Version \(update.displayVersion) is available. You have \(installedVersion).") {
                    HStack(spacing: SettingsSpacing.s2) {
                        UpdateVersionBadge(version: update.displayVersion)
                        Button("View Update…", action: checkForUpdates)
                            .accessibilityLabel("View update, version \(update.displayVersion)")
                    }
                }
            } else {
                SettingsRow("BetterTile updates", caption: "Version \(installedVersion) is installed.") {
                    Button("Check for Updates…", action: checkForUpdates)
                }
            }
#endif
        }
    }

    private var compatibility: some View {
        SettingsGroup("Compatibility") {
            SettingsRow("Enhanced accessibility", caption: "How BetterTile treats apps that expose extra window detail.") {
                Picker("Enhanced accessibility", selection: configurationBinding(\.enhancedUserInterfacePolicy)) {
                    ForEach(EnhancedUserInterfacePolicy.allCases, id: \.self) { policy in
                        Text(policy.title).tag(policy)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
        } footer: {
            GroupFooter(
                help: "Some apps reinterpret window positions while enhanced accessibility is on, so BetterTile turns it "
                    + "off while it moves a window. " + model.configuration.enhancedUserInterfacePolicy.explanation,
                isAtDefault: model.configuration.enhancedUserInterfacePolicy == .disableAndRestore
            ) {
                model.updateConfiguration { $0.enhancedUserInterfacePolicy = .disableAndRestore }
            }
        }
    }

    private var privacy: some View {
        SettingsGroup("Privacy") {
            DisclosureGroup(isExpanded: $privacyExpanded) {
                Text(
                    "BetterTile uses public Accessibility APIs. It observes global left-button "
                        + "ordering for snapping and linked resizing. Layout Wheel observes its "
                        + "configured modifiers and limited gesture input. Its optional Middle "
                        + "Click trigger reserves the chosen plain or Option–middle click system-wide while "
                        + "enabled. BetterTile requests no Screen Recording, Input Monitoring, "
                        + "or private entitlement."
                )
                .font(SettingsFont.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, SettingsSpacing.s1)
            } label: {
                Text("What BetterTile can see")
            }
            .padding(.vertical, 6)
            .padding(.horizontal, SettingsSpacing.s3)
            .frame(minHeight: SettingsMetrics.rowMinHeight)
        }
    }

    private var about: some View {
        SettingsGroup("About") {
            SettingsRow("Version") {
                Text(installedVersion)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .textSelection(.enabled)
            }
            ForEach(LegalDocument.allCases) { document in
                SettingsRow(document.title, caption: caption(for: document)) {
                    Button("\(document.title)…") { shownLegalDocument = document }
                        .disabled(document.contents == nil)
                }
            }
        }
    }

    // MARK: - Helpers

    private func caption(for document: LegalDocument) -> String {
        switch document {
        case .license:
            "Copyright (C) 2026 LMC-Karma. GPL-3.0 or later, with no warranty. Free, with no ads and no tracking."
        case .notices:
            "Sparkle and its licenses."
        }
    }

    private var launchAtLoginCaption: String? {
        switch launchAtLoginState {
        case .on, .off: nil
        case .needsApproval: "Allow BetterTile in System Settings › General › Login Items."
        case .unavailable: "Available when BetterTile runs from the Applications folder."
        }
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { launchAtLoginState == .on || launchAtLoginState == .needsApproval },
            set: { enabled in
                do {
                    try launchAtLogin.setEnabled(enabled)
                } catch {
                    model.statusMessage = "Launch at login could not change: \(error.localizedDescription)"
                }
                refreshLaunchAtLogin()
            }
        )
    }

    private func refreshLaunchAtLogin() {
        launchAtLoginState = launchAtLogin.state
    }

    private var startupIsAtDefault: Bool {
        Self.startupIsAtDefault(configuration: model.configuration, iconRawValue: appIconRawValue)
    }

    static func startupIsAtDefault(configuration: BetterTileConfiguration, iconRawValue: String) -> Bool {
        configuration.showMenuBarIcon
            && !configuration.showDockIcon
            && (AppIconStyle(rawValue: iconRawValue) ?? .defaultStyle) == .defaultStyle
    }

    static func resetStartup(
        model: BetterTileModel, iconRawValue: Binding<String>, defaults: UserDefaults = .standard,
        applyAppIcon: (AppIconStyle) -> Bool
    ) -> Bool {
        model.updateConfiguration {
            $0.showMenuBarIcon = true
            $0.showDockIcon = false
        }
        // Without a saved choice the default icon already shows. Saving one would let this reset, or the
        // next launch, replace a Finder icon the user set outside BetterTile.
        guard defaults.string(forKey: AppIconStyle.defaultsKey) != nil else { return true }
        iconRawValue.wrappedValue = AppIconStyle.defaultStyle.rawValue
        return applyAppIcon(.defaultStyle)
    }

    private var assignedShortcutCount: Int {
        model.configuration.shortcuts.filter { $0.shortcut != nil }.count
    }

    private var defaultModeTitle: String {
        switch model.configuration.defaultLayoutMode.availableMode {
        case .manual, .linked: "Manual"
        case .bento: "Adaptive"
        case .tabbed: "Tabbed"
        }
    }

    private func revealSearchResults() {
        guard !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        privacyExpanded = true
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

/// The three app icon choices, shown as picture choices in the App icon row.
struct AppIconPicker: View {
    @Binding var selectedRawValue: String
    @Binding var finderIconUpdateFailed: Bool
    var applyAppIcon: (AppIconStyle) -> Bool = { AppIconStyle.apply($0) }

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsSpacing.s2) {
            HStack(alignment: .top, spacing: SettingsSpacing.s2) {
                ForEach(AppIconStyle.allCases) { style in
                    PictureChoice(style.title, isSelected: selected == style, action: { select(style) }) {
                        Group {
                            if let image = style.image {
                                Image(nsImage: image)
                                    .resizable()
                                    .interpolation(.high)
                                    .scaledToFit()
                            } else {
                                Image(systemName: "app")
                                    .font(.title)
                            }
                        }
                        .padding(SettingsSpacing.s1)
                    }
                    .frame(width: 84)
                    .help("Use the \(style.title) icon in the Dock and Finder")
                }
            }
            if finderIconUpdateFailed {
                Text("Finder’s icon couldn’t be updated. Make sure BetterTile is in a writable folder, then select the icon again.")
                    .font(SettingsFont.caption)
                    .foregroundStyle(SettingsColor.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    var selected: AppIconStyle {
        AppIconStyle(rawValue: selectedRawValue) ?? .defaultStyle
    }

    func select(_ style: AppIconStyle) {
        selectedRawValue = style.rawValue
        finderIconUpdateFailed = !applyAppIcon(style)
    }
}
