// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 LMC-Karma

import AppKit
import BetterTileCore
import BetterTileMacOS
import SwiftUI

/// Every page of the Settings window. The case order is the order the search uses when it has to
/// pick a new page; the sidebar groups the pages differently (see `SettingsView`).
enum SettingsDestination: String, CaseIterable, Identifiable {
    case general = "General"
    case windowLayout = "Window Layout"
    case shortcuts = "Shortcuts"
    case snapZones = "Snap Zones"
    case menuBar = "Menu Bar"
    case layoutWheel = "Layout Wheel"
    case applicationRules = "Per-App Rules"
    case savedLayouts = "Saved Layouts"

    var id: Self { self }

    /// The Window Management sidebar section, top to bottom.
    static let windowManagementDestinations: [Self] = [
        .windowLayout, .savedLayouts, .shortcuts, .snapZones, .menuBar, .layoutWheel,
    ]

    var icon: SidebarTile.Icon {
        switch self {
        case .general: .symbol("gearshape")
        case .windowLayout: .layoutGlyph(.layouts)
        case .shortcuts: .symbol("keyboard")
        case .snapZones: .symbol("rectangle.split.3x3")
        case .menuBar: .symbol("menubar.rectangle")
        case .layoutWheel: .wheel
        case .applicationRules: .symbol("app.badge.checkmark")
        case .savedLayouts: .symbol("rectangle.stack")
        }
    }

    var tileColor: Color {
        switch self {
        case .general, .shortcuts: SettingsColor.gray
        case .windowLayout: SettingsColor.blue
        case .snapZones: SettingsColor.teal
        case .menuBar: SettingsColor.orange
        case .layoutWheel: SettingsColor.purple
        case .applicationRules: SettingsColor.green
        case .savedLayouts: SettingsColor.indigo
        }
    }

    var subtitle: String {
        switch self {
        case .general: "Check that BetterTile is ready, then adjust how it starts and looks."
        case .windowLayout: "Choose how windows are arranged on each desktop."
        case .shortcuts: "Set keyboard shortcuts for window actions."
        case .snapZones: "Drag a window to a screen edge or corner to place it."
        case .menuBar: "Choose the window actions in your menu, then drag them into order."
        case .layoutWheel: "A radial menu for placing the focused window."
        case .applicationRules: "Choose apps BetterTile leaves alone, in whole or in part."
        case .savedLayouts: "Arrange apps once, then apply them to this desktop in one click."
        }
    }

    /// True when the phrase is blank, or when its trimmed, lower-cased form occurs anywhere in the
    /// page title or in the page's search terms. Inner whitespace is compared as typed.
    func matchesSearch(_ phrase: String) -> Bool {
        let needle = phrase.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return true }
        return rawValue.lowercased().contains(needle) || searchCorpus.contains(needle)
    }

    /// Lower-case words a person might type to find this page, as one space-separated string.
    private var searchCorpus: String {
        switch self {
        case .general:
            "permission accessibility dock icon classic ice blue appearance light dark system drag snapping application update automatic check macos tiling move resize edge advanced enhanced user interface chromium electron voiceover request access open accessibility settings check again open setup assistant bettertile drag snapping automatically check for updates version view update check for updates update available show dock icon app icon license third-party notices legal restore after moving leave disabled enhanced accessibility start & personalize enable window controls keep bettertile ready about bettertile bettertile at a glance default mode adaptive compatibility development details macos window tiling launch at login startup login items menu bar icon status privacy what bettertile can see show menu bar icon bettertile appearance bettertile updates keyboard show overlays in screen recordings screenshots snap previews drop cues capture screen capture layout previews"
        case .windowLayout:
            "default mode manual native bento adaptive tabbed tabs pane preset linked divider ghost resize preview appearance liquid glass transparency opaque transparent new window side automatic dock space hide auto-hide compact always visible tab bar presentation pane gap balance thin standard wide balanced starting layout single pane columns rows main grid show settings for window mode when a desktop has one window balance on new window apply starting layout restore pane size when switching tabs leave space for dock resize adjacent windows together window feedback divider width use liquid glass swap delay instant short long keep desktop modes when displays change dock undock screen place windows all in one pane one per pane keep adaptive panes " + Self.tabbedPresetTerms
        case .shortcuts:
            "shortcut shortcuts keyboard hotkey hotkeys keybinding keybindings keys binding record recording duplicate conflict modified reset reset all shortcuts search actions command control option shift halves thirds quarters sixths position size move resize displays restore tabs left half right half top half bottom half left third center third right third left two thirds right two thirds top left quarter top right quarter bottom left quarter bottom right quarter top left sixth top center sixth top right sixth bottom left sixth bottom center sixth bottom right sixth maximize almost maximize center center resize move left move right move up move down grow width shrink width grow height shrink height previous display next display restore show tab bar next tab previous tab move tab left move tab right move tab to next pane move tab to previous pane halves thirds quarters sixths position & size move resize displays & restore tabs enable disable master toggle bettertile keyboard shortcuts"
        case .snapZones:
            "drag snap edge corner activation area width size reach extension title bar double click maximize bettertile drag snapping macos window tiling move resize native compatibility saved zones narrow standard wide custom window top double-click the top of a window to maximize or restore"
        case .menuBar:
            "menu bar actions order visibility reorder drag restore defaults"
        case .layoutWheel:
            "wheel layout radial pie ring sector hub gesture middle click mouse button control option shift command modifier trigger shortcut hold activation one level two levels repair layout repair bento empty cancel tab next tab previous tab move tab pane keyboard modifiers style rings sectors wheel size custom grouped reset sector assignments appearance liquid glass strength light dark quick flick child children all fans one fan ice ember mist clear fade zoom bounce ripple frosted smoked smoke calm fan child open the wheel modifier keys hold delay mouse trigger option + middle click option middle click right control edit wheel visible fans all fans one fan click an icon to assign swap inner and outer rings reset layout wheel reset slot group contents add child remove child content levels wheel appearance size small medium large fine-tuning fine tuning look motion feel sub-menus sub menus submenus highlight color names action tint translucency opaque transparent opening closing pointer lean arrangement keep sub-menu open play opening play closing reset to style defaults reset appearance"
        case .applicationRules:
            "app application rule exclude ignore bento adaptive manage per-app exception skip leave alone enabled participation matching live windows"
        case .savedLayouts:
            "saved layout canvas desktop display app slot geometry pane group tab import export json file reload rename delete"
        }
    }

    /// Window Layout is also found by the title of every Tabbed preset.
    private static let tabbedPresetTerms = TabbedPreset.allCases.map { $0.title.lowercased() }.joined(separator: " ")
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

/// The root view of the Settings window: an optional save warning above a sidebar and a page.
///
/// The current page and the search text live only in this view's state. The app creates the
/// window once per run and only hides it on close, so both survive a close and reopen.
struct SettingsView: View {
    @Bindable var model: BetterTileModel
#if !DEBUG
    @Bindable var updatePresentation: UpdatePresentationModel
    @Binding var automaticallyChecksForUpdates: Bool
    let checkForUpdates: () -> Void
#endif
    let openSetup: () -> Void

    @State private var page: SettingsDestination
    @State private var lookupPhrase: String
    /// One editor for the whole life of the window, so an unsaved draft survives page changes.
    @State private var layoutEditor = SavedLayoutEditor()
    @FocusState private var finderHasFocus: Bool

#if DEBUG
    init(
        model: BetterTileModel,
        openSetup: @escaping () -> Void,
        selection: SettingsDestination = .general,
        search: String = ""
    ) {
        self.model = model
        self.openSetup = openSetup
        _page = State(initialValue: selection)
        _lookupPhrase = State(initialValue: search)
    }
#else
    init(
        model: BetterTileModel,
        updatePresentation: UpdatePresentationModel,
        automaticallyChecksForUpdates: Binding<Bool>,
        checkForUpdates: @escaping () -> Void,
        openSetup: @escaping () -> Void,
        selection: SettingsDestination = .general,
        search: String = ""
    ) {
        self.model = model
        self.updatePresentation = updatePresentation
        _automaticallyChecksForUpdates = automaticallyChecksForUpdates
        self.checkForUpdates = checkForUpdates
        self.openSetup = openSetup
        _page = State(initialValue: selection)
        _lookupPhrase = State(initialValue: search)
    }
#endif

    var body: some View {
        VStack(spacing: 0) {
            if let reason = model.configurationSaveBlockedReason {
                SaveBlockedBanner(reason: reason)
            }
            NavigationSplitView {
                sidebarColumn
            } detail: {
                detailColumn
            }
            .navigationSplitViewStyle(.balanced)
        }
        .frame(minWidth: 980, maxWidth: .infinity, minHeight: 640, maxHeight: .infinity)
        .font(.system(size: 13))
        .controlSize(.regular)
        .background(FindShortcutCatcher { finderHasFocus = true })
        .onChange(of: lookupPhrase) { _, typed in
            keepAMatchingPageSelected(for: typed)
        }
        .onChange(of: model.requestedSettingsDestination, initial: true) { _, request in
            guard let request else { return }
            show(request)
            model.requestedSettingsDestination = nil
        }
    }

    // MARK: Search state

    private var matchingPages: [SettingsDestination] {
        SettingsDestination.allCases.filter { $0.matchesSearch(lookupPhrase) }
    }

    private var nothingMatches: Bool { matchingPages.isEmpty }

    /// Keeps the current page when it still matches; otherwise moves to the first match in
    /// catalogue order. With no match at all the page stays, ready for when the phrase clears.
    private func keepAMatchingPageSelected(for typed: String) {
        guard !page.matchesSearch(typed),
              let first = SettingsDestination.allCases.first(where: { $0.matchesSearch(typed) })
        else { return }
        page = first
    }

    /// Empties the search and selects `destination` in the same update.
    private func show(_ destination: SettingsDestination) {
        lookupPhrase = ""
        page = destination
    }

    // MARK: Sidebar

    /// The sidebar groups that still hold a page matching the phrase, each trimmed to its matches.
    private var shownGroups: [SidebarGroup] {
        SidebarGroup.all.compactMap { $0.narrowed(to: lookupPhrase) }
    }

    private var sidebarColumn: some View {
        VStack(spacing: 0) {
            Label("BetterTile", systemImage: "rectangle.split.2x1")
                .font(.system(size: 14, weight: .semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 18)
                .padding(.vertical, 20)
            SettingsFinderBox(focus: $finderHasFocus, phrase: $lookupPhrase)
            List(selection: $page) {
                ForEach(shownGroups) { group in
                    Section {
                        ForEach(group.members) { destination in
                            sidebarRow(destination).tag(destination)
                        }
                    } header: {
                        Text(group.heading)
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .overlay {
                if nothingMatches {
                    ContentUnavailableView.search(text: lookupPhrase)
                        .padding(.horizontal, 8)
                }
            }
        }
        .navigationSplitViewColumnWidth(min: 198, ideal: 210, max: 240)
    }

    private func sidebarRow(_ destination: SettingsDestination) -> some View {
        HStack {
            SettingsSidebarLabel(destination: destination)
            Spacer()
#if !DEBUG
            if destination == .general,
               let version = updatePresentation.state.availableUpdate?.displayVersion {
                UpdateVersionBadge(version: version)
            }
#endif
        }
    }

    // MARK: Detail

    @ViewBuilder private var detailColumn: some View {
        Group {
            if nothingMatches {
                ContentUnavailableView {
                    Label("No Matching Settings", systemImage: "magnifyingglass")
                } description: {
                    Text("No settings page matches “\(lookupPhrase)”.")
                } actions: {
                    Button("Clear Search") { lookupPhrase = "" }
                }
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    if page != .savedLayouts {
                        SettingsPageHeader(destination: page)
                            .padding(.horizontal, 24)
                            .padding(.top, 24)
                            .padding(.bottom, 16)
                    }
                    pageContent
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var generalLinks: GeneralLinkActions { GeneralLinkActions(show: show) }

    @ViewBuilder private var pageContent: some View {
        switch page {
        case .general:
#if DEBUG
            GeneralSettings(
                model: model,
                openSetup: openSetup,
                search: lookupPhrase,
                openShortcuts: generalLinks.openShortcuts,
                openSnapZones: generalLinks.openSnapZones
            )
#else
            GeneralSettings(
                model: model,
                updatePresentation: updatePresentation,
                automaticallyChecksForUpdates: $automaticallyChecksForUpdates,
                checkForUpdates: checkForUpdates,
                openSetup: openSetup,
                search: lookupPhrase,
                openShortcuts: generalLinks.openShortcuts,
                openSnapZones: generalLinks.openSnapZones
            )
#endif
        case .windowLayout: WindowLayoutSettings(model: model)
        case .shortcuts: ShortcutsSettings(model: model)
        case .snapZones: ZoneSettings(model: model)
        case .menuBar: MenuBarSettings(model: model)
        case .layoutWheel: LayoutWheelSettings(model: model)
        case .applicationRules: ApplicationRuleSettings(model: model)
        case .savedLayouts:
            SavedLayoutSettings(editor: layoutEditor, model: model, displayTriggers: model.displayTriggerStore)
        }
    }
}

/// A titled run of pages in the sidebar.
private struct SidebarGroup: Identifiable {
    let heading: String
    let members: [SettingsDestination]

    var id: String { heading }

    /// Top to bottom: Essentials, Window Management, Advanced.
    static let all: [SidebarGroup] = [
        SidebarGroup(heading: "Essentials", members: [.general]),
        SidebarGroup(heading: "Window Management", members: SettingsDestination.windowManagementDestinations),
        SidebarGroup(heading: "Advanced", members: [.applicationRules]),
    ]

    /// This group with only the pages that match `phrase`, or nil when none match, so the
    /// sidebar never shows a heading without rows.
    func narrowed(to phrase: String) -> SidebarGroup? {
        let kept = members.filter { $0.matchesSearch(phrase) }
        return kept.isEmpty ? nil : SidebarGroup(heading: heading, members: kept)
    }
}

/// The rounded find box at the top of the sidebar. It edits the phrase that filters the pages.
private struct SettingsFinderBox: View {
    var focus: FocusState<Bool>.Binding
    @Binding var phrase: String

    var body: some View {
        HStack(alignment: .center, spacing: 5) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search settings", text: $phrase)
                .focused(focus)
                .textFieldStyle(.plain)
                .onExitCommand(perform: erase)
                .accessibilityLabel("Search settings")
            PhraseEraser(isShown: !phrase.isEmpty, erase: erase)
        }
        .modifier(FinderBoxChrome())
    }

    private func erase() {
        phrase = ""
    }
}

/// The × at the trailing end of the find box. It takes no room while the box is empty.
private struct PhraseEraser: View {
    let isShown: Bool
    let erase: () -> Void

    var body: some View {
        if isShown {
            Button(action: erase) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Clear search")
        }
    }
}

/// The find box's rounded backing and the margins that seat it in the sidebar.
private struct FinderBoxChrome: ViewModifier {
    private static let inner = EdgeInsets(top: 5, leading: 7, bottom: 5, trailing: 7)
    private static let outer = EdgeInsets(top: 8, leading: 10, bottom: 4, trailing: 10)

    func body(content: Content) -> some View {
        content
            .padding(Self.inner)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(.background)
            }
            .padding(Self.outer)
    }
}

/// The warning shown above both columns while the configuration cannot be written to disk.
private struct SaveBlockedBanner: View {
    let reason: String

    var body: some View {
        HStack(alignment: .top) {
            Image(systemName: "exclamationmark.triangle")
                .accessibilityHidden(true)
            // An ideal width of zero keeps a long reason from widening the window; it wraps instead.
            Text(reason)
                .lineLimit(4)
                .frame(minWidth: 0, idealWidth: 0, maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .help(reason)
        }
        .font(.callout)
        .frame(maxWidth: .infinity)
        .padding()
        .background(Color.yellow.opacity(0.12))
    }
}

/// Moves focus to the Settings search field on ⌘F while its window is key.
///
/// A window offers every key equivalent to its views before the menus, so an invisible view can
/// answer ⌘F without a menu item, a button or a Tab stop.
struct FindShortcutCatcher: NSViewRepresentable {
    let focusSearch: () -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.onFind = focusSearch
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) {
        view.onFind = focusSearch
    }

    final class CatcherView: NSView {
        var onFind: (() -> Void)?

        override var acceptsFirstResponder: Bool { false }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard FindShortcutCatcher.isFindShortcut(event), let onFind else {
                return super.performKeyEquivalent(with: event)
            }
            onFind()
            return true
        }
    }

    /// True for the key press macOS matches to a ⌘F menu shortcut on the current layout.
    ///
    /// The match uses `characters`, which carries the layout's Command-key character: "f" for
    /// the F key on Russian or Greek, and for the QWERTY F key on "Dvorak – QWERTY ⌘".
    /// `charactersIgnoringModifiers` would give "а", "φ" or "u" there instead.
    static func isFindShortcut(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad, .function])
        return modifiers == .command && event.characters?.lowercased() == "f"
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

/// The pages that General's "Shortcuts" and "Snap Zones" links open.
struct GeneralLinkActions {
    let openShortcuts: () -> Void
    let openSnapZones: () -> Void

    init(show: @escaping (SettingsDestination) -> Void) {
        openShortcuts = { show(.shortcuts) }
        openSnapZones = { show(.snapZones) }
    }
}
