// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 LMC-Karma

import AppKit
import BetterTileMacOS
import SwiftUI
import UniformTypeIdentifiers

/// Picker names for the shared Settings tokens.
private enum PickerMetrics {
    static let rowHeight = SettingsSpacing.s8
    static let iconSize = SettingsSpacing.s6
    static let controlRadius = SettingsRadius.control
    static let searchHeight = SettingsSpacing.s6 + SettingsSpacing.s1
}

/// The picker sits on popup glass or a sheet's material, where the system's secondary and
/// tertiary label colours are too faint. Secondary text and headers use `PopupGlass`'s
/// text colour; size and weight carry the hierarchy.
enum PickerText {
    static let secondary = AnyShapeStyle(PopupGlass.secondaryText)
    static var selectedLabelColor: NSColor { .alternateSelectedControlTextColor }
    static var selectedSecondaryLabelColor: NSColor { selectedLabelColor }
    static var selectionBackgroundColor: NSColor {
        NSColor(name: nil) { appearance in
            var color: NSColor!
            appearance.performAsCurrentDrawingAppearance { color = selectionBackground(for: .controlAccentColor) }
            return color
        }
    }
    static var browseLabelColor: NSColor {
        NSColor(name: nil) { appearance in
            var color: NSColor!
            appearance.performAsCurrentDrawingAppearance { color = NSColor.labelColor.withAlphaComponent(1) }
            return color
        }
    }

    // Opacity multipliers of the normal label colour, measured on textBackgroundColor.
    static let lightSearchPlaceholderOpacity = 0.64
    static let darkSearchPlaceholderOpacity = 0.54

    static func searchLabelColor(in appearance: NSAppearance) -> NSColor {
        var label = NSColor.labelColor
        appearance.performAsCurrentDrawingAppearance {
            label = NSColor.labelColor.usingColorSpace(.sRGB) ?? .labelColor
        }
        return label
    }

    static func searchPlaceholderColor(in appearance: NSAppearance) -> NSColor {
        let label = searchLabelColor(in: appearance)
        let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let opacity = dark ? darkSearchPlaceholderOpacity : lightSearchPlaceholderOpacity
        return label.withAlphaComponent(label.alphaComponent * opacity)
    }

    /// Keep the accent hue, with enough shade for opaque selected text (including captions).
    static func selectionBackground(for accent: NSColor) -> NSColor { PopupGlass.accentShade(for: accent) }
}

struct ApplicationPickerWindow: Hashable, Identifiable, Sendable {
    let id: String
    let title: String
}

/// Reusable application selection. The caller owns the meaning of the choice.
/// One click or Return on a row chooses it.
struct ApplicationPicker: View {
    let exclusions: Set<String>
    let onChoose: (ApplicationChoice) -> Void
    let installedApplications: @MainActor () async -> [ApplicationChoice]
    let runningApplications: () -> [ApplicationChoice]
    let makeOpenPanel: () -> NSOpenPanel
    let recentApplications: RecentApplications
    let resolveApplication: @Sendable (String) -> ApplicationChoice?
    let returnHint: String
    let windows: ((ApplicationChoice) -> [ApplicationPickerWindow]?)?
    let onChooseWindow: ((ApplicationChoice, ApplicationPickerWindow) -> Void)?
    /// Internal observation seam for offscreen readiness checks; no input or selection policy.
    var onPresentationChange: ((ApplicationPickerReadiness) -> Void)? = nil

    init(exclusions: Set<String>,
         installedApplications: @escaping @MainActor () async -> [ApplicationChoice] = {
             await InstalledApplicationCatalog.shared.applications()
         },
         runningApplications: @escaping () -> [ApplicationChoice] = ApplicationPicker.runningApplicationChoices,
         recentApplications: RecentApplications = .shared,
         resolveApplication: @escaping @Sendable (String) -> ApplicationChoice? = ApplicationPicker.installedApplication,
         makeOpenPanel: @escaping () -> NSOpenPanel = { NSOpenPanel() },
         returnHint: String = "Choose",
         windows: ((ApplicationChoice) -> [ApplicationPickerWindow]?)? = nil,
         onChooseWindow: ((ApplicationChoice, ApplicationPickerWindow) -> Void)? = nil,
         onChoose: @escaping (ApplicationChoice) -> Void) {
        self.exclusions = exclusions
        self.installedApplications = installedApplications
        self.runningApplications = runningApplications
        self.recentApplications = recentApplications
        self.resolveApplication = resolveApplication
        self.makeOpenPanel = makeOpenPanel
        self.returnHint = returnHint
        self.windows = windows
        self.onChooseWindow = onChooseWindow
        self.onChoose = onChoose
    }

    /// Regular (Dock) apps only, named like the installed list so both sections agree.
    nonisolated static func runningApplicationChoices() -> [ApplicationChoice] {
        NSWorkspace.shared.runningApplications.compactMap { application in
            guard application.activationPolicy == .regular,
                  let id = application.bundleIdentifier, let url = application.bundleURL else { return nil }
            return ApplicationChoice(bundleIdentifier: id,
                                     name: ApplicationCatalog.displayName(for: url, metadata: nil), url: url)
        }
    }

    /// Resolves a Recent bundle identifier that is neither running nor in a scanned folder.
    /// It reads LaunchServices and the bundle, so the picker calls it off the main actor.
    nonisolated static func installedApplication(_ bundleIdentifier: String) -> ApplicationChoice? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
            .flatMap(ApplicationCatalog.application(at:))
            .flatMap { $0.id == bundleIdentifier ? $0 : nil }
    }

    @State private var expansion = ApplicationPickerModel.Expansion()
    @State private var search = ""
    @State private var highlight: String?
    @State private var installed: [ApplicationChoice] = []
    @State private var running: [ApplicationChoice] = []
    @State private var recent: [ApplicationChoice] = []
    @State private var captions: [String: String] = [:]
    @State private var isLoading = true
    @State private var error: String?
    @State private var presentation = ApplicationPickerPresentation()

    private var query: String { search.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var sections: [ApplicationPickerModel.Section] {
        ApplicationPickerModel.windowSections(
            ApplicationPickerModel.sections(installed: installed, running: running, recent: recent,
                                            excluding: exclusions, search: search, captions: captions),
            expansion: expansion, windows: windows)
    }

    var body: some View {
        let sections = sections
        let rows = sections.flatMap(\.rows)
        VStack(alignment: .leading, spacing: 8) {
            ApplicationPickerSearchField(text: $search, presentation: presentation) { command in
                switch command {
                case .down, .up:
                    guard !rows.isEmpty else { return false }
                    highlight = ApplicationPickerModel.move(highlight, by: command == .down ? 1 : -1, in: rows)
                    if rows.contains(where: { $0.id == highlight && ($0.window != nil || $0.showsAllAction) }) { return true }
                    // Focus stays in the search field, so VoiceOver hears the highlighted row.
                    if let row = rows.first(where: { $0.id == highlight }) { announce(ApplicationPickerModel.announcement(for: row)) }
                    return true
                case .right:
                    guard let row = rows.first(where: { $0.id == highlight }) else { return false }
                    return expansion.expand(row)
                case .left:
                    guard let parent = expansion.collapse() else { return false }
                    highlight = parent
                    return true
                case .choose:
                    guard let row = rows.first(where: { $0.id == highlight }) else { return false }
                    choose(row)
                    return true
                }
            }
            .padding(.horizontal, windows == nil ? 0 : 6)
            if rows.isEmpty && !query.isEmpty && !isLoading {
                ApplicationPickerNoResults(query: query, browse: browse)
            } else {
                ApplicationPickerList(sections: sections, highlight: highlight, isLoading: isLoading,
                                      desktopScope: windows != nil,
                                      expandedRowID: expansion.rowID, choose: choose,
                                      toggleWindows: { row in
                                          if expansion.rowID == row.id { highlight = expansion.collapse() }
                                          else { _ = expansion.expand(row) }
                                      })
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            if !(rows.isEmpty && !query.isEmpty && !isLoading) {
                Divider()
                HStack(spacing: 8) {
                    Button(action: browse) { Text("Browse…") }
                        .buttonStyle(PopupLinkStyle(color: Color(nsColor: PickerText.browseLabelColor)))
                    Spacer()
                    let hints = ApplicationPickerModel.hints(for: rows.first { $0.id == highlight }, returnHint: returnHint)
                    ApplicationPickerKeyHint(key: "↩", label: hints.primary)
                    if let secondary = hints.secondary {
                        ApplicationPickerKeyHint(key: secondary == "Windows" ? "→" : "←", label: secondary)
                    }
                }
                .font(.caption)
                .padding(.horizontal, windows == nil ? 0 : 6)
            }
        }
        .onChange(of: ApplicationPickerReadiness(rowIDs: rows.map(\.id), highlight: highlight, isLoading: isLoading), initial: true) {
            onPresentationChange?(ApplicationPickerReadiness(rowIDs: rows.map(\.id), highlight: highlight, isLoading: isLoading))
        }
        .onDisappear { presentation.cancelBrowse() }
        .onChange(of: rows) {
            highlight = ApplicationPickerModel.highlight(highlight, in: rows, searching: !query.isEmpty)
        }
        .onChange(of: search) {
            expansion = ApplicationPickerModel.Expansion()
            highlight = ApplicationPickerModel.highlight(nil, in: rows, searching: !query.isEmpty)
            if let row = rows.first(where: { $0.id == highlight }) { announce(ApplicationPickerModel.announcement(for: row)) }
        }
        .task {
            running = runningApplications()
            let identifiers = recentApplications.bundleIdentifiers
            // Running apps resolve from memory; the rest wait for the scan and one lookup off the main actor.
            recent = ApplicationPickerModel.recentChoices(identifiers, known: running, lookup: { _ in nil })
            captions = ApplicationPickerModel.folderCaptions(for: recent + running)
            installed = await installedApplications()
            let known = running + installed
            let missing = identifiers.filter { id in !known.contains { $0.id == id } }
            let resolve = resolveApplication
            let found = missing.isEmpty ? [] : await Task.detached(priority: .utility) { missing.compactMap(resolve) }.value
            recent = ApplicationPickerModel.recentChoices(identifiers, known: known + found, lookup: { _ in nil })
            captions = ApplicationPickerModel.folderCaptions(for: recent + running + installed)
            isLoading = false
        }
    }

    private func announce(_ text: String) {
        guard let field = presentation.searchField else { return }
        NSAccessibility.post(element: field, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    private func choose(_ row: ApplicationPickerModel.Row) {
        if row.showsAllAction { expansion.showingAll = true; return }
        if let window = row.window {
            recentApplications.record(row.application.id)
            onChooseWindow?(row.application, window)
        } else { choose(row.application) }
    }

    private func choose(_ application: ApplicationChoice?) {
        error = ApplicationPickerModel.validationMessage(for: application, excluding: exclusions)
        guard error == nil, let application else { return }
        recentApplications.record(application.id)
        onChoose(application)
    }

    private func browse() {
        guard let owner = presentation.searchField?.window, presentation.panel == nil else { return }
        let panel = makeOpenPanel()
        presentation.panel = panel
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.treatsFilePackagesAsDirectories = false
        panel.directoryURL = URL(filePath: "/Applications")
        panel.prompt = "Choose"
        panel.beginSheetModal(for: owner) { [weak panel] response in
            guard let panel, presentation.panel === panel else { return }
            presentation.panel = nil
            guard response == .OK, let url = panel.url else { return }
            choose(ApplicationCatalog.application(at: url))
        }
    }
}

struct ApplicationPickerReadiness: Equatable {
    var rowIDs: [String]
    var highlight: String?
    var isLoading: Bool
}

/// Sections with sticky headers. Rows fill on hover; only the keyboard highlight uses the accent.
/// Headers have no fill, so the popup glass shows through; rows fade out under a pinned header.
private struct ApplicationPickerList: View {
    let sections: [ApplicationPickerModel.Section]
    let highlight: String?
    let isLoading: Bool
    /// Window counts are for this desktop, so the Running header says so.
    var desktopScope = false
    let expandedRowID: String?
    let choose: (ApplicationPickerModel.Row) -> Void
    let toggleWindows: (ApplicationPickerModel.Row) -> Void
    @State private var headerHeight: CGFloat = 0

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    ForEach(sections) { section in
                        Section {
                            ForEach(section.rows) { row in
                                if let window = row.window {
                                    if section.rows.first(where: { $0.window != nil })?.id == row.id {
                                        Text("Windows on this desktop · live titles")
                                            .font(.system(size: 10)).foregroundStyle(PickerText.secondary)
                                            .padding(.horizontal, 8).padding(.vertical, 4)
                                            .pickerHeaderFade(headerHeight)
                                    }
                                    ApplicationPickerWindowRow(row: row, title: window.title.isEmpty ? row.application.name : window.title,
                                                               highlighted: row.id == highlight) { choose(row) }.id(row.id)
                                        .pickerHeaderFade(headerHeight)
                                } else if row.showsAllAction {
                                    ApplicationPickerWindowRow(row: row, title: "Show all \(row.windows?.count ?? 0) windows",
                                                               highlighted: row.id == highlight) { choose(row) }.id(row.id)
                                        .pickerHeaderFade(headerHeight)
                                } else {
                                    ApplicationPickerRow(row: row, highlighted: row.id == highlight,
                                                         expanded: row.id == expandedRowID,
                                                         toggleWindows: { toggleWindows(row) }) { choose(row) }.id(row.id)
                                        .pickerHeaderFade(headerHeight)
                                }
                            }
                            if let note = note(for: section) {
                                Text(note).font(.caption).foregroundStyle(PickerText.secondary)
                                    .padding(.horizontal, 8).padding(.top, 2).padding(.bottom, 6)
                                    .pickerHeaderFade(headerHeight)
                            }
                        } header: {
                            ApplicationPickerSectionHeader(section: section, isLoading: isLoading, desktopScope: desktopScope)
                                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headerHeight = $0 }
                        }
                    }
                }
                .padding(.bottom, 6)
            }
            .accessibilityLabel("Apps")
            .onChange(of: highlight) {
                guard let highlight else { return }
                proxy.scrollTo(highlight)
            }
        }
    }

    private func note(for section: ApplicationPickerModel.Section) -> String? {
        guard section.rows.isEmpty else { return nil }
        switch section.kind {
        case .running: return "No other apps are running."
        case .allApps, .results: return isLoading ? "Loading apps…" : "No apps found. Use Browse… to choose one."
        case .recent: return nil
        }
    }
}

private struct ApplicationPickerSectionHeader: View {
    let section: ApplicationPickerModel.Section
    let isLoading: Bool
    var desktopScope = false

    var body: some View {
        HStack {
            Text(section.kind.rawValue).fontWeight(.semibold)
            Spacer()
            if desktopScope, section.kind == .running, !section.rows.isEmpty { Text("This desktop") }
            if (section.kind == .allApps || section.kind == .results) && !(isLoading && section.rows.isEmpty) {
                Text("\(section.rows.filter { $0.window == nil && !$0.showsAllAction }.count)")
            }
        }
        .font(.caption)
        .foregroundStyle(PickerText.secondary)
        .padding(.horizontal, 8)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

extension View {
    /// Fades a list row out as it slides under the pinned section header above it.
    /// The header then needs no fill of its own.
    fileprivate func pickerHeaderFade(_ headerHeight: CGFloat) -> some View {
        visualEffect { content, proxy in
            content.opacity(PickerHeaderFade.opacity(rowTop: proxy.frame(in: .scrollView).minY, headerHeight: headerHeight))
        }
    }
}

enum PickerHeaderFade {
    /// A quarter row. The header's title ends 4 pt above its lower edge and a row's icon
    /// starts 4 pt below its top, so a row is gone before its icon reaches the title.
    static let distance = PickerMetrics.rowHeight / 4

    /// Fully visible at the header's lower edge, invisible once `distance` of the row is under it.
    static func opacity(rowTop: CGFloat, headerHeight: CGFloat) -> Double {
        guard headerHeight > 0 else { return 1 }
        return min(1, max(0, (rowTop - headerHeight + distance) / distance))
    }
}

private struct ApplicationPickerRow: View {
    let row: ApplicationPickerModel.Row
    let highlighted: Bool
    var expanded = false
    let toggleWindows: () -> Void
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let application = row.application
        Button(action: action) {
            HStack(spacing: 8) {
                ApplicationChoiceIcon(url: application.url, size: PickerMetrics.iconSize)
                Text(application.name)
                    .lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let available = row.windows {
                    if !available.isEmpty && (highlighted || expanded) {
                        Text("Use a window from this desktop ›")
                            .font(.system(size: 10)).hidden()
                    } else {
                        Text(ApplicationPickerModel.windowCount(available.count)).font(.caption)
                            .foregroundStyle(highlighted ? AnyShapeStyle(Color(nsColor: PickerText.selectedSecondaryLabelColor)) : PickerText.secondary)
                    }
                }
                if let caption = row.caption {
                    Text(caption)
                        .font(.caption).lineLimit(1).truncationMode(.head)
                        .foregroundStyle(highlighted ? AnyShapeStyle(Color(nsColor: PickerText.selectedSecondaryLabelColor)) : PickerText.secondary)
                        .frame(maxWidth: 150, alignment: .trailing)
                        .layoutPriority(1)
                }
            }
            .foregroundStyle(highlighted ? AnyShapeStyle(Color(nsColor: PickerText.selectedLabelColor)) : AnyShapeStyle(.primary))
            .padding(.horizontal, 8)
            .frame(height: PickerMetrics.rowHeight)
            .background {
                RoundedRectangle(cornerRadius: PickerMetrics.controlRadius, style: .continuous)
                    .fill(highlighted ? AnyShapeStyle(Color(nsColor: PickerText.selectionBackgroundColor))
                          : hovering ? AnyShapeStyle(.fill.tertiary) : AnyShapeStyle(.clear))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .overlay(alignment: .trailing) {
            if row.windows?.isEmpty == false && (highlighted || expanded) {
                Button("Use a window from this desktop ›", action: toggleWindows)
                    .font(.system(size: 10))
                    .buttonStyle(PopupLinkStyle(color: Color(nsColor: highlighted ? PickerText.selectedLabelColor : PickerText.browseLabelColor)))
                    .padding(.horizontal, 8).frame(height: PickerMetrics.rowHeight)
            }
        }
        .help("\(application.name)\n\(application.bundleIdentifier)")
        .accessibilityLabel(row.caption.map { "\(application.name), \($0)" } ?? application.name)
        .accessibilityAddTraits(highlighted ? .isSelected : [])
    }
}

private struct ApplicationPickerWindowRow: View {
    let row: ApplicationPickerModel.Row
    let title: String
    let highlighted: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: row.showsAllAction ? "chevron.down" : "macwindow").frame(width: 24)
                Text(title).lineLimit(1).truncationMode(.tail).frame(maxWidth: .infinity, alignment: .leading)
                if highlighted && !row.showsAllAction { Text("Use here").font(.caption) }
            }
            .font(.system(size: 11))
            .foregroundStyle(highlighted ? AnyShapeStyle(Color(nsColor: PickerText.selectedLabelColor)) : AnyShapeStyle(.primary))
            .padding(.horizontal, 8).frame(height: PickerMetrics.rowHeight)
            .background {
                RoundedRectangle(cornerRadius: PickerMetrics.controlRadius, style: .continuous)
                    .fill(highlighted ? AnyShapeStyle(Color(nsColor: PickerText.selectionBackgroundColor))
                          : hovering ? AnyShapeStyle(.fill.tertiary) : AnyShapeStyle(.clear))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).padding(.leading, 12)
        .onHover { hovering = $0 }.help(title)
        .accessibilityLabel(title)
        .accessibilityAddTraits(highlighted ? .isSelected : [])
    }
}

private struct ApplicationPickerNoResults: View {
    let query: String
    let browse: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 24)).foregroundStyle(.primary)
                .accessibilityHidden(true)
            Text("No apps match “\(query)”").font(.headline).multilineTextAlignment(.center)
                .lineLimit(2).truncationMode(.middle)
            Text("Search looks in the Applications folders. Browse… can find other apps.")
                .font(.caption).foregroundStyle(PickerText.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: browse) { Text("Browse…") }
                .buttonStyle(PopupLinkStyle(color: Color(nsColor: PickerText.browseLabelColor))).padding(.top, 8)
        }
        .frame(maxWidth: 240)
        .padding(.top, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

private struct ApplicationPickerKeyHint: View {
    let key: String
    let label: String

    var body: some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.system(size: 12, weight: .medium))
                .frame(minWidth: 18, minHeight: 20)
                .padding(.horizontal, 3)
                .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: SettingsRadius.mini, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: SettingsRadius.mini, style: .continuous).strokeBorder(.separator, lineWidth: 0.5))
            Text(label).foregroundStyle(PickerText.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Return: \(label)")
    }
}

@MainActor private final class ApplicationPickerPresentation {
    weak var searchField: NSSearchField?
    var panel: NSOpenPanel?

    func cancelBrowse() {
        let pending = panel
        panel = nil
        pending?.cancel(nil)
    }
}

/// The shared native field draws an opaque semantic text-field surface inside the glass.
/// Its entire capsule remains clickable, with the existing border and keyboard focus ring.
private struct ApplicationPickerSearchField: View {
    @Binding var text: String
    let presentation: ApplicationPickerPresentation
    let perform: (ApplicationPickerSearch.Command) -> Bool
    @State private var focused = false
    @Environment(\.controlActiveState) private var activeState

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: PickerMetrics.controlRadius, style: .continuous)
        ApplicationPickerSearch(text: $text, focused: $focused, presentation: presentation, perform: perform)
            .frame(maxWidth: .infinity, minHeight: PickerMetrics.searchHeight, maxHeight: PickerMetrics.searchHeight)
            .overlay(shape.strokeBorder(SettingsColor.controlBorder, lineWidth: 1).allowsHitTesting(false))
            .overlay {
                // The keyboard focus ring the native bezel drew.
                if focused && activeState == .key {
                    RoundedRectangle(cornerRadius: PickerMetrics.controlRadius + 3, style: .continuous)
                        .strokeBorder(Color(nsColor: .keyboardFocusIndicatorColor), lineWidth: 3)
                        .padding(-3)
                        .allowsHitTesting(false)
                }
            }
    }
}

/// The field keeps focus. Arrow keys and Return reach the list through the field
/// editor's commands, before SwiftUI sees them, and never while text is being composed.
private struct ApplicationPickerSearch: NSViewRepresentable {
    enum Command { case down, up, left, right, choose }

    @Binding var text: String
    @Binding var focused: Bool
    let presentation: ApplicationPickerPresentation
    let perform: (Command) -> Bool

    func makeNSView(context: Context) -> NSSearchField {
        let field = ApplicationPickerInitialFocusField(string: text)
        field.isBezeled = false
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.placeholderString = "Search apps"
        field.sendsSearchStringImmediately = true
        field.setAccessibilityLabel("Search apps")
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.delegate = context.coordinator
        let coordinator = context.coordinator
        // The focus change can arrive during a SwiftUI update, so publish it afterward.
        field.onFocusChange = { value in DispatchQueue.main.async { coordinator.parent.focused = value } }
        presentation.searchField = field
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.parent = self
        guard (field.currentEditor() as? NSTextView)?.hasMarkedText() != true else { return }
        if field.stringValue != text { field.stringValue = text }
    }

    /// The field fills the capsule; its cell centres the magnifier, text and cancel button.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView field: NSSearchField, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? field.fittingSize.width, height: proposal.height ?? PickerMetrics.searchHeight)
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: ApplicationPickerSearch
        init(parent: ApplicationPickerSearch) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.cancelOperation(_:)), textView.hasMarkedText() {
                // The input manager gets first refusal. If cancellation reaches the responder
                // chain with marked text still present, discard only that composition.
                let markedRange = textView.markedRange()
                textView.inputContext?.discardMarkedText()
                textView.insertText("", replacementRange: markedRange)
                return true
            }
            guard !textView.hasMarkedText() else { return false }
            if selector == #selector(NSResponder.cancelOperation(_:)), control.stringValue.isEmpty {
                // NSSearchField can consume cancellation even after its query is empty.
                // Finish the search command here so it reaches the panel's cancel responder.
                control.window?.cancelOperation(textView)
                return true
            }
            switch selector {
            case #selector(NSResponder.moveDown(_:)): return parent.perform(.down)
            case #selector(NSResponder.moveUp(_:)): return parent.perform(.up)
            case #selector(NSResponder.moveRight(_:)): return parent.perform(.right)
            case #selector(NSResponder.moveLeft(_:)): return parent.perform(.left)
            case #selector(NSResponder.insertNewline(_:)): return parent.perform(.choose)
            default: return false
            }
        }
    }
}

struct ApplicationChoiceIcon: View {
    let url: URL?
    var size: CGFloat = 28

    var body: some View {
        Group {
            if let url {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable()
            } else {
                Image(systemName: "app.dashed").resizable().foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

@MainActor private final class ApplicationPickerInitialFocusField: NSSearchField {
    // Keep the field surface and its primary ink out of glass foreground compositing.
    override var allowsVibrancy: Bool { false }
    private var didRequestInitialFocus = false
    var onFocusChange: ((Bool) -> Void)?

    override class var cellClass: AnyClass? {
        get { ApplicationPickerSearchCell.self }
        set {}
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if window !== newWindow {
            if let window, let editor = currentEditor() as? NSTextView,
               window.firstResponder === editor, editor.delegate === self {
                window.endEditing(for: self)
                window.makeFirstResponder(nil)
            }
            if window?.initialFirstResponder === self { window?.initialFirstResponder = nil }
            didRequestInitialFocus = false
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refreshColors()
        guard let window, !didRequestInitialFocus else { return }
        didRequestInitialFocus = true
        // A reused picker can join a window that is already editing another control.
        if let editor = window.firstResponder as? NSTextView, editor.isFieldEditor,
           editor.delegate !== self { return }
        window.initialFirstResponder = self
        window.makeFirstResponder(self)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshColors()
    }

    override func draw(_ dirtyRect: NSRect) {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            NSColor.textBackgroundColor.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: PickerMetrics.controlRadius,
                         yRadius: PickerMetrics.controlRadius).fill()
            super.draw(dirtyRect)
        }
    }

    private func refreshColors() {
        // Glass gives descendants a vibrant appearance. The opaque field needs the
        // popup window's normal label colour, resolved before the editor draws it.
        let appearance = window?.effectiveAppearance ?? effectiveAppearance
        let label = PickerText.searchLabelColor(in: appearance)
        textColor = label
        if let editor = currentEditor() as? NSTextView {
            editor.textColor = label
            editor.insertionPointColor = label
        }
        placeholderAttributedString = NSAttributedString(string: "Search apps", attributes: [
            .font: font ?? .systemFont(ofSize: NSFont.systemFontSize),
            .foregroundColor: PickerText.searchPlaceholderColor(in: appearance),
        ])
        needsDisplay = true
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted {
            refreshColors()
            onFocusChange?(true)
        }
        return accepted
    }

    override func textDidEndEditing(_ notification: Notification) {
        super.textDidEndEditing(notification)
        onFocusChange?(false)
    }
}

/// The field fills its capsule, so the cell lays out its magnifier, text and cancel button
/// in a band of its natural height, centred and inset from the capsule's edges. Without a
/// bezel, AppKit also places the field editor over the magnifier; edit in the search text
/// rectangle instead, as the placeholder already does.
final class ApplicationPickerSearchCell: NSSearchFieldCell {
    override init(textCell string: String) {
        super.init(textCell: string)
        let original = searchButtonCell
        let button = ApplicationPickerSearchButtonCell(imageCell: original?.image)
        button.target = original?.target
        button.action = original?.action
        button.isBordered = false
        button.imagePosition = .imageOnly
        searchButtonCell = button
    }

    required init(coder: NSCoder) { super.init(coder: coder) }

    static let horizontalInset = SettingsSpacing.s1

    /// Only the control's full bounds are banded, so rectangles AppKit derives from a band pass through.
    func band(_ rect: NSRect) -> NSRect {
        guard let view = controlView, rect == view.bounds else { return rect }
        let height = min(rect.height, cellSize.height)
        let inset = rect.insetBy(dx: Self.horizontalInset, dy: 0)
        return NSRect(x: inset.minX, y: (rect.midY - height / 2).rounded(), width: inset.width, height: height)
    }

    override func searchTextRect(forBounds rect: NSRect) -> NSRect { super.searchTextRect(forBounds: band(rect)) }
    override func searchButtonRect(forBounds rect: NSRect) -> NSRect { super.searchButtonRect(forBounds: band(rect)) }
    override func cancelButtonRect(forBounds rect: NSRect) -> NSRect { super.cancelButtonRect(forBounds: band(rect)) }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        super.draw(withFrame: band(cellFrame), in: controlView)
    }

    override func select(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText,
                         delegate: Any?, start selStart: Int, length selLength: Int) {
        super.select(withFrame: searchTextRect(forBounds: rect), in: controlView, editor: textObj,
                     delegate: delegate, start: selStart, length: selLength)
    }

    override func edit(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText,
                       delegate: Any?, event: NSEvent?) {
        super.edit(withFrame: searchTextRect(forBounds: rect), in: controlView, editor: textObj,
                   delegate: delegate, event: event)
    }
}

/// Keep the search action and native hit rectangle, but draw its meaningful glyph at primary opacity.
private final class ApplicationPickerSearchButtonCell: NSButtonCell {
    override func draw(withFrame frame: NSRect, in controlView: NSView) {
        controlView.effectiveAppearance.performAsCurrentDrawingAppearance {
            let side = min(13, frame.width, frame.height)
            let origin = NSPoint(x: frame.midX - side / 2, y: frame.midY - side / 2)
            let scale = side / 13
            let path = NSBezierPath(ovalIn: NSRect(x: origin.x + scale, y: origin.y + scale,
                                                 width: 8.5 * scale, height: 8.5 * scale))
            path.move(to: NSPoint(x: origin.x + 8.5 * scale, y: origin.y + 8.5 * scale))
            path.line(to: NSPoint(x: origin.x + 12 * scale, y: origin.y + 12 * scale))
            path.lineWidth = 1.5 * scale
            path.lineCapStyle = .round
            NSColor.labelColor.setStroke()
            path.stroke()
        }
    }
}
