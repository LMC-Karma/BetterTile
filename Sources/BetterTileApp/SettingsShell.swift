// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 LMC-Karma
// Contains portions adapted from Vorssaint, Copyright (C) 2026 Vorssaint.

import AppKit
import BetterTileCore
import BetterTileMacOS
import SwiftUI

enum SettingsDestination: String, CaseIterable, Identifiable {
    case general = "General"
    case windowLayout = "Window Layout"
    case shortcuts = "Shortcuts"
    case snapZones = "Snap Zones"
    case menuBar = "Menu Bar"
    case layoutWheel = "Layout Wheel"
    case applicationRules = "Per-App Rules"

    static let windowManagementDestinations: [Self] = [
        .windowLayout, .shortcuts, .snapZones, .menuBar, .layoutWheel,
    ]

    var id: Self { self }

    var icon: SidebarTile.Icon {
        switch self {
        case .general: .symbol("gearshape")
        case .windowLayout: .layoutGlyph(.layouts)
        case .shortcuts: .symbol("keyboard")
        case .snapZones: .symbol("rectangle.split.3x3")
        case .menuBar: .symbol("menubar.rectangle")
        case .layoutWheel: .wheel
        case .applicationRules: .symbol("app.badge.checkmark")
        }
    }

    /// The sidebar tile color for this page.
    var tileColor: Color {
        switch self {
        case .general, .shortcuts: SettingsColor.gray
        case .windowLayout: SettingsColor.blue
        case .snapZones: SettingsColor.teal
        case .menuBar: SettingsColor.orange
        case .layoutWheel: SettingsColor.purple
        case .applicationRules: SettingsColor.green
        }
    }

    var keywords: String {
        switch self {
        case .general:
            "permission accessibility dock icon classic ice blue appearance light dark system drag snapping application "
                + "update automatic check macos tiling move resize edge advanced enhanced user interface chromium electron "
                + "voiceover request access open accessibility settings check again open setup assistant bettertile drag "
                + "snapping automatically check for updates version view update check for updates update available show dock "
                + "icon app icon license third-party notices legal restore after moving leave disabled enhanced accessibility "
                + "start & personalize enable window controls keep bettertile ready about bettertile bettertile at a glance "
                + "default mode adaptive compatibility development details macos window tiling launch at login startup login "
                + "items menu bar icon status privacy what bettertile can see show menu bar icon bettertile appearance "
                + "bettertile updates keyboard"
        case .windowLayout:
            "default mode manual native bento adaptive tabbed tabs pane preset linked divider ghost resize preview "
                + "appearance liquid glass transparency opaque transparent new window side automatic dock space hide auto-hide "
                + "compact always visible tab bar presentation pane gap balance thin standard wide balanced starting layout "
                + "single pane columns rows main grid show settings for window mode when a desktop has one window balance on "
                + "new window apply starting layout restore pane size when switching tabs leave space for dock resize adjacent "
                + "windows together window feedback divider width use liquid glass swap delay instant short long"
                + " " + TabbedPreset.allCases.map(\.title).joined(separator: " ").lowercased()
        case .shortcuts:
            "shortcut shortcuts keyboard hotkey hotkeys keybinding keybindings keys binding record recording duplicate "
                + "conflict modified reset reset all shortcuts search actions command control option shift halves thirds "
                + "quarters sixths position size move resize displays restore tabs left half right half top half bottom half "
                + "left third center third right third left two thirds right two thirds top left quarter top right quarter "
                + "bottom left quarter bottom right quarter top left sixth top center sixth top right sixth bottom left sixth "
                + "bottom center sixth bottom right sixth maximize almost maximize center center resize move left move right "
                + "move up move down grow width shrink width grow height shrink height previous display next display restore "
                + "show tab bar next tab previous tab move tab left move tab right move tab to next pane move tab to previous "
                + "pane halves thirds quarters sixths position & size move resize displays & restore tabs enable disable master "
                + "toggle bettertile keyboard shortcuts"
        case .snapZones:
            "drag snap edge corner activation area width size reach extension title bar double click maximize bettertile drag snapping "
                + "macos window tiling move resize native compatibility saved zones narrow standard wide custom "
                + "window top double-click the top of a window to maximize or restore"
        case .menuBar:
            "menu bar actions order visibility reorder drag restore defaults"
        case .layoutWheel:
            "wheel layout radial pie ring sector hub gesture middle click mouse button "
                + "control option shift command modifier trigger shortcut hold activation "
                + "one level two levels rings sectors wheel size repair layout bento empty cancel"
        case .applicationRules:
            "app application rule exclude ignore bento adaptive manage per-app exception skip leave alone "
                + "enabled participation matching live windows"
        }
    }

    func matchesSearch(_ search: String) -> Bool {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return query.isEmpty || rawValue.lowercased().contains(query) || keywords.contains(query)
    }

    var subtitle: String {
        switch self {
        case .general: "Check that BetterTile is ready, then adjust how it starts and looks."
        case .windowLayout: "Choose how windows are arranged on each desktop."
        case .shortcuts: "Set keyboard shortcuts for window actions."
        case .snapZones: "Drag a window to a screen edge or corner to place it."
        case .menuBar: "Choose the window actions in your menu, then drag them into order."
        case .layoutWheel: "Put window actions around the pointer for quick access."
        case .applicationRules: "Choose apps BetterTile leaves alone, in whole or in part."
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
            .lineLimit(1)
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
    @State var selection: SettingsDestination = .general
    @State var search = ""
    @FocusState private var searchFocused: Bool

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                if let reason = model.configurationSaveBlockedReason {
                    HStack(alignment: .top) {
                        Image(systemName: "exclamationmark.triangle")
                            .accessibilityHidden(true)
                        Text(reason)
                            .lineLimit(4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .help(reason)
                    }
                    .font(.callout)
                    .frame(maxWidth: geometry.size.width, alignment: .leading)
                    .padding()
                    .background(.yellow.opacity(0.12))
                }
                settingsNavigation
            }
        }
        .font(.system(size: 13))
        .controlSize(.regular)
        .frame(minWidth: 980, minHeight: 640)
        .onChange(of: model.requestedSettingsDestination, initial: true) {
            if let destination = model.requestedSettingsDestination {
                open(destination)
                model.requestedSettingsDestination = nil
            }
        }
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

    private var settingsNavigation: some View {
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
                        destinations: SettingsDestination.windowManagementDestinations
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
                                .padding(.horizontal, 24)
                                .padding(.top, 24)
                                .padding(.bottom, 16)
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
        .navigationSplitViewStyle(.balanced)
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
                        SettingsSidebarLabel(destination: destination)
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

    /// An explicit request for a page clears the search, so the page and its sidebar row are both visible.
    private func open(_ destination: SettingsDestination) {
        search = ""
        selection = destination
    }

    private func matchesSearch(_ destination: SettingsDestination) -> Bool {
        destination.matchesSearch(search)
    }

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .general:
#if DEBUG
            GeneralSettings(
                model: model, openSetup: openSetup, search: search,
                openShortcuts: { open(.shortcuts) },
                openSnapZones: { open(.snapZones) }
            )
#else
            GeneralSettings(
                model: model,
                updatePresentation: updatePresentation,
                automaticallyChecksForUpdates: $automaticallyChecksForUpdates,
                checkForUpdates: checkForUpdates,
                openSetup: openSetup,
                search: search,
                openShortcuts: { open(.shortcuts) },
                openSnapZones: { open(.snapZones) }
            )
#endif
        case .windowLayout:
            WindowLayoutSettings(model: model)
        case .shortcuts:
            ShortcutsSettings(model: model)
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

/// The same native Label is used by every Settings sidebar row.
struct SettingsSidebarLabel: View {
    let destination: SettingsDestination

    var body: some View {
        Label {
            Text(destination.rawValue)
        } icon: {
            SidebarTile(icon: destination.icon, color: destination.tileColor)
        }
    }
}

/// A license file shipped in the application's resources.
enum LegalDocument: String, CaseIterable, Identifiable {
    case license = "LICENSE"
    case notices = "THIRD_PARTY_NOTICES.md"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .license: "License"
        case .notices: "Third-Party Notices"
        }
    }

    /// Nil when the file is missing, as in a SwiftPM build.
    var contents: String? {
        Bundle.main.url(forResource: rawValue, withExtension: nil)
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
    }
}

struct LegalDocumentView: View {
    let document: LegalDocument
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                Text(document.contents ?? "")
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
            Divider()
            HStack {
                Text(document.title).font(.headline)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 640, height: 520)
    }
}

struct StatusMessage: View {
    @Bindable var model: BetterTileModel

    var body: some View {
        if let message = model.statusMessage {
            Label(message, systemImage: "info.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
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
