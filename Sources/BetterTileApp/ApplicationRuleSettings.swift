// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 LMC-Karma

import AppKit
import BetterTileCore
import BetterTileMacOS
import SwiftUI

enum ApplicationRuleWarning {
    static func text(bundleIdentifier: String, isInstalled: Bool) -> String? {
        if bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Invalid app identifier. Remove this rule and choose an application again."
        }
        guard !isInstalled else { return nil }
        return "App not installed. This rule stays saved and applies when the app is available again."
    }
}

enum ApplicationRuleAppName {
    static func displayName(bundleIdentifier: String, knownName: String? = nil) -> String {
        if let knownName, !knownName.isEmpty { return knownName }
        return bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "No app identifier" : "App not installed"
    }

    static func missingAppNotice(knownName: String?) -> String {
        guard let knownName, !knownName.isEmpty else { return "App not installed" }
        return "\(knownName) is not installed"
    }
}

/// What the rule sheet does with the chosen app.
enum ApplicationRuleSheetPurpose: Identifiable, Hashable {
    /// Choose an app, then its participation.
    case add
    /// Move an existing rule to another app, for example when its app is missing.
    case replace(String)

    var id: String {
        switch self {
        case .add: "add"
        case let .replace(bundleIdentifier): "replace:" + bundleIdentifier
        }
    }
}

struct ApplicationRuleListState {
    var search = ""
    var selection: String?

    mutating func selectSheetResult(_ bundleIdentifier: String) {
        search = ""
        selection = bundleIdentifier
    }

    func includes(bundleIdentifier: String, name: String) -> Bool {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty || name.localizedStandardContains(query)
            || bundleIdentifier.localizedStandardContains(query)
    }
}

struct ApplicationRuleSettings: View {
    @Bindable var model: BetterTileModel
    var resolveApplication: (String) -> ApplicationChoice? = { id in
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return nil }
        return ApplicationChoice(bundleIdentifier: id, name: ApplicationCatalog.displayName(for: url, metadata: nil), url: url)
    }
    @State private var list = ApplicationRuleListState()
    @State private var sheet: ApplicationRuleSheetPurpose?
    @State private var applications: [String: ApplicationChoice] = [:]
    @State private var knownNames: [String: String] = [:]

    private typealias Entry = (bundleIdentifier: String, rule: ApplicationRule, isEnabled: Bool)

    private var entries: [Entry] {
        model.configuration.applicationRules.entries
    }

    private func name(for id: String) -> String {
        ApplicationRuleAppName.displayName(bundleIdentifier: id, knownName: knownNames[id])
    }

    private var filteredEntries: [Entry] {
        return entries.filter {
            list.includes(bundleIdentifier: $0.bundleIdentifier, name: name(for: $0.bundleIdentifier))
        }.sorted { name(for: $0.bundleIdentifier).localizedStandardCompare(name(for: $1.bundleIdentifier)) == .orderedAscending }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsSpacing.s4) {
            if !model.hasAccessibilityPermission {
                NoticeBanner(
                    .warning,
                    title: "Accessibility is off",
                    message: "Rules stay editable. Live matches and window controls are unavailable.",
                    action: .init(title: "Open Accessibility Settings", perform: model.openAccessibilitySettings)
                )
            }
            if !entries.isEmpty {
                HStack(spacing: SettingsSpacing.s2) {
                    SettingsPill("\(entries.count) \(entries.count == 1 ? "rule" : "rules")", tint: .accentColor)
                    Spacer()
                    addButton
                }
            }
            HStack(alignment: .top, spacing: SettingsSpacing.s4) {
                ruleList
                    .frame(width: 240)
                if entries.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        detail
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
            StatusMessage(model: model)
        }
        .padding(.horizontal, SettingsSpacing.s6)
        .padding(.bottom, SettingsSpacing.s6)
        .font(SettingsFont.body)
        .settingsPickerPanel(isPresented: Binding(get: { sheet != nil }, set: { if !$0 { sheet = nil } }),
                             size: NSSize(width: 420, height: 520), appearance: model.configuration.overlayAppearance) { dismiss in
            if let purpose = sheet {
                AddApplicationRuleSheet(model: model, purpose: purpose, onDismiss: dismiss) { list.selectSheetResult($0) }
            }
        }
        .task(id: entries.map(\.bundleIdentifier)) {
            var resolved: [String: ApplicationChoice] = [:]
            for entry in entries {
                if let application = resolveApplication(entry.bundleIdentifier) {
                    resolved[entry.bundleIdentifier] = application
                }
            }
            applications = resolved
            knownNames.merge(resolved.mapValues(\.name)) { _, new in new }
        }
        .onChange(of: filteredEntries.map(\.bundleIdentifier), initial: true) {
            if !filteredEntries.contains(where: { $0.bundleIdentifier == list.selection }) {
                list.selection = filteredEntries.first?.bundleIdentifier
            }
        }
    }

    private var addButton: some View {
        Button("Add Rule…", systemImage: "plus") { sheet = .add }
            .buttonStyle(.borderedProminent)
    }

    private var emptyState: some View {
        SettingsGroup {
            VStack(spacing: SettingsSpacing.s3) {
                SidebarTile(icon: SettingsDestination.applicationRules.icon,
                            color: SettingsDestination.applicationRules.tileColor)
                    .scaleEffect(1.6)
                    .frame(width: SettingsSpacing.s8, height: SettingsSpacing.s8)
                Text("Every app is managed normally.").font(SettingsFont.headline)
                // Keep this compressible during the Settings split view's minimum-width probe.
                Text("Add a rule to keep an app out of automatic tiling, or out of every BetterTile action. "
                    + "Good for a floating calculator or a call you place by hand.")
                    .font(SettingsFont.caption)
                    .foregroundStyle(.secondary)
                addButton
                    .padding(.top, SettingsSpacing.s1)
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(SettingsSpacing.s6)
        }
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - List

    private var ruleList: some View {
        VStack(spacing: 0) {
            HStack(spacing: SettingsSpacing.s2) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Find an app", text: $list.search)
                    .textFieldStyle(.plain)
                if !list.search.isEmpty {
                    Button { list.search = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear search")
                }
            }
            .padding(.horizontal, SettingsSpacing.s2)
            .frame(height: SettingsSpacing.s8)
            .background(SettingsColor.fill, in: .settings(SettingsRadius.control))
            .padding(.horizontal, SettingsSpacing.s3)
            .padding(.vertical, SettingsSpacing.s2)
            SettingsSeparator()
                .padding(.trailing, SettingsSpacing.s3)
            List(selection: $list.selection) {
                ForEach(filteredEntries, id: \.bundleIdentifier) { entry in
                    ruleRow(entry)
                        .tag(entry.bundleIdentifier)
                        .listRowBackground(
                            RoundedRectangle.settings(SettingsRadius.control)
                                .fill(list.selection == entry.bundleIdentifier ? SettingsColor.fillStrong : Color.clear)
                                .padding(.horizontal, SettingsSpacing.s2)
                        )
                        // Plain List adds 8 pt; 4 pt inside it aligns content to the 12 pt group inset.
                        .listRowInsets(EdgeInsets(top: 0, leading: SettingsSpacing.s1,
                                                  bottom: 0, trailing: SettingsSpacing.s1))
                        .alignmentGuide(.listRowSeparatorTrailing) { $0[.trailing] }
                }
            }
            .listStyle(.plain)
            .environment(\.defaultMinListRowHeight, SettingsSpacing.s8 + SettingsSpacing.s3)
            .contentMargins(.horizontal, 0, for: .scrollContent)
            .contentMargins(.vertical, SettingsSpacing.s1, for: .scrollContent)
            .scrollContentBackground(.hidden)
            .frame(minHeight: 240)
            .overlay {
                if !entries.isEmpty, filteredEntries.isEmpty {
                    VStack(spacing: SettingsSpacing.s2) {
                        Text("No rules match “\(list.search)”").fontWeight(.medium)
                        Text("Try another app name.")
                            .font(SettingsFont.caption).foregroundStyle(.secondary)
                        Button("Clear Search") { list.search = "" }
                    }
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(SettingsSpacing.s3)
                }
            }
            SettingsSeparator()
                .padding(.trailing, SettingsSpacing.s3)
            Text("One rule per app. Rules survive relaunch and missing apps.")
                .font(SettingsFont.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(SettingsSpacing.s3)
        }
        .background(SettingsColor.group, in: .settings(SettingsRadius.panel))
        .clipShape(.settings(SettingsRadius.panel))
        .overlay(RoundedRectangle.settings(SettingsRadius.panel).strokeBorder(SettingsColor.groupBorder, lineWidth: 0.5))
    }

    private func ruleRow(_ entry: Entry) -> some View {
        let id = entry.bundleIdentifier
        return HStack(spacing: SettingsSpacing.s2) {
            ApplicationChoiceIcon(url: applications[id]?.url, size: SettingsSpacing.s6)
            VStack(alignment: .leading, spacing: 2) {
                Text(name(for: id))
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(name(for: id))
                // A long participation title wraps to a second line instead of losing its end.
                summary(for: entry)
                    .font(SettingsFont.caption)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .opacity(entry.isEnabled ? 1 : 0.6)
            Spacer(minLength: 0)
            Toggle("Enabled", isOn: enabledBinding(for: id))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
        }
        .padding(.vertical, SettingsSpacing.s1)
        .frame(minHeight: SettingsSpacing.s8 + SettingsSpacing.s3)
        .background(RuleListSelectionAppearance())
        // Help on the whole row would replace the name's and the summary's own help, so the row has none.
    }

    @ViewBuilder
    private func summary(for entry: Entry) -> some View {
        let id = entry.bundleIdentifier
        if id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Label("No app identifier", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(SettingsColor.red)
        } else if applications[id] == nil {
            Label("Not installed", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(SettingsColor.orange)
        } else {
            let summary = entry.isEnabled ? entry.rule.title : "Off · \(entry.rule.title)"
            Text(summary)
                .foregroundStyle(.secondary)
                .help(summary)
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if let selection = list.selection, let entry = entries.first(where: { $0.bundleIdentifier == selection }),
           filteredEntries.contains(where: { $0.bundleIdentifier == selection }) {
            ruleDetail(entry)
        } else {
            SettingsGroup {
                VStack(alignment: .leading, spacing: SettingsSpacing.s1) {
                    Text("Select a rule").font(SettingsFont.headline)
                    Text("Its participation and matching windows appear here.")
                        .font(SettingsFont.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(SettingsSpacing.s4)
            }
        }
    }

    private func ruleDetail(_ entry: Entry) -> some View {
        let id = entry.bundleIdentifier
        let isInvalid = id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let isInstalled = applications[id] != nil
        return VStack(alignment: .leading, spacing: SettingsSpacing.s5) {
            if isInvalid {
                NoticeBanner(.problem, title: "This rule has no app identifier",
                             message: "BetterTile cannot match any window. Choose an app to repair the rule, or remove it.",
                             action: .init(title: "Choose App…") { sheet = .replace(id) })
                    .help(id)
            } else if !isInstalled {
                NoticeBanner(.warning, title: ApplicationRuleAppName.missingAppNotice(knownName: knownNames[id]),
                             message: "The rule is kept. It applies again when you install the app, or you can choose another app.",
                             action: .init(title: "Choose App…") { sheet = .replace(id) })
                    .help(id)
            }
            SettingsGroup {
                HStack(spacing: SettingsSpacing.s3) {
                    ApplicationChoiceIcon(url: applications[id]?.url, size: SettingsSpacing.s8)
                    Text(name(for: id))
                        .font(SettingsFont.statusValue)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                }
                .padding(SettingsSpacing.s3)
                // The bundle identifier appears only as a tooltip.
                .help(isInvalid ? "No app identifier" : id)
                SettingsRow("Enabled", caption: "Turn off to keep the rule without applying it.") {
                    Toggle("Enabled", isOn: enabledBinding(for: id))
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
                SettingsRow("Participation") {
                    Picker("Participation", selection: Binding(
                        get: { model.configuration.applicationRules.configuredRule(for: id) ?? entry.rule },
                        set: { model.setRule($0, for: id) }
                    )) {
                        ForEach(ApplicationRule.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                }
            } footer: {
                HelpText(entry.rule.explanation)
            }
            matchingWindows(entry)
            HStack {
                Spacer()
                Button("Remove Rule", role: .destructive) { model.clearRule(for: id) }
                    .buttonStyle(.plain)
                    .foregroundStyle(SettingsColor.red)
                    .help("Remove the rule and manage this app normally")
            }
            .frame(minHeight: SettingsSpacing.s8)
            .padding(.trailing, SettingsSpacing.s3)
        }
    }

    private func matchingWindows(_ entry: Entry) -> some View {
        let windows = model.matchingRuleWindows(for: entry.bundleIdentifier)
        let effect = !entry.isEnabled ? "Rule off · managed normally"
            : entry.rule == .ignoreEverywhere ? "Excluded from all placement" : "Excluded from automatic tiling"
        return SettingsGroup(
            "Matching live windows",
            aside: model.hasAccessibilityPermission ? "\(windows.count)" : "Unavailable"
        ) {
            if !model.hasAccessibilityPermission {
                HelpText("Live matches unavailable without Accessibility.")
                    .padding(.vertical, SettingsSpacing.s3)
            } else if windows.isEmpty {
                HelpText("No visible windows. The rule applies when this app next opens a window.")
                    .padding(.vertical, SettingsSpacing.s3)
            } else {
                ForEach(windows, id: \.id) { window in
                    SettingsRow(window.title.isEmpty ? "Untitled Window" : window.title,
                                caption: "Display \(window.displayID.rawValue) · \(effect)") {
                        EmptyView()
                    }
                    .help(window.title)
                }
            }
        }
    }

    private func enabledBinding(for id: String) -> Binding<Bool> {
        Binding(
            get: { model.configuration.applicationRules.isEnabled(for: id) },
            set: { model.setRuleEnabled($0, for: id) }
        )
    }
}

struct AddApplicationRuleSheet: View {
    var makePicker: (Set<String>, @escaping (ApplicationChoice) -> Void) -> ApplicationPicker = {
        ApplicationPicker(exclusions: $0, onChoose: $1)
    }
    @Bindable var model: BetterTileModel
    var purpose: ApplicationRuleSheetPurpose = .add
    /// Called with the app whose rule the list should select.
    let onAdd: (String) -> Void
    private let dismiss: () -> Void
    @State private var application: ApplicationChoice?
    @State private var rule: ApplicationRule = .excludeFromBento
    @State private var error: String?

    init(
        makePicker: @escaping (Set<String>, @escaping (ApplicationChoice) -> Void) -> ApplicationPicker = {
            ApplicationPicker(exclusions: $0, onChoose: $1)
        },
        model: BetterTileModel,
        purpose: ApplicationRuleSheetPurpose = .add,
        application: ApplicationChoice? = nil,
        onDismiss: @escaping () -> Void = {},
        onAdd: @escaping (String) -> Void
    ) {
        self.makePicker = makePicker
        self.model = model
        self.purpose = purpose
        self.onAdd = onAdd
        self.dismiss = onDismiss
        _application = State(initialValue: application)
    }

    /// Only BetterTile itself is hidden. Choosing an app that already has a rule opens that rule.
    private var exclusions: Set<String> {
        [Bundle.main.bundleIdentifier ?? ""]
    }

    private var rules: ApplicationRuleSet { model.configuration.applicationRules }

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsSpacing.s3) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(SettingsFont.headline)
                Text(subtitle).font(SettingsFont.caption).foregroundStyle(PopupGlass.secondaryText)
            }
            if let application {
                participation(for: application)
            } else {
                makePicker(exclusions) { choose($0) }
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(SettingsFont.caption)
                        .foregroundStyle(SettingsColor.red)
                }
                HStack {
                    Spacer()
                    OverlayButtonRow {
                        SettingsPickerCancelButton { dismiss() }.fixedSize()
                    }
                }
            }
        }
        .padding(SettingsSpacing.s5)
        .frame(width: 420, height: 520)
    }

    private var title: String {
        switch purpose {
        case .add: "Add Rule"
        case .replace: "Choose App"
        }
    }

    private var subtitle: String {
        switch purpose {
        case .add:
            application == nil ? "Recent and running apps come first." : "Choose how BetterTile treats this app."
        case .replace:
            "The rule keeps its participation and Enabled setting."
        }
    }

    private func choose(_ choice: ApplicationChoice) {
        switch purpose {
        case .add:
            if rules.configuredRule(for: choice.id) != nil {
                // An app that already has a rule opens that rule instead.
                onAdd(choice.id)
                dismiss()
            } else {
                application = choice
            }
        case let .replace(original):
            guard choice.id == original || rules.configuredRule(for: choice.id) == nil else {
                error = "\(choice.name) already has a rule. Choose another app."
                return
            }
            model.moveRule(from: original, to: choice.id)
            onAdd(choice.id)
            dismiss()
        }
    }

    private func participation(for application: ApplicationChoice) -> some View {
        VStack(alignment: .leading, spacing: SettingsSpacing.s3) {
            HStack(spacing: SettingsSpacing.s3) {
                ApplicationChoiceIcon(url: application.url, size: 40)
                Text(application.name)
                    .font(SettingsFont.statusValue)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            // The bundle identifier appears only as a tooltip.
            .help(application.bundleIdentifier)
            VStack(spacing: SettingsSpacing.s2) {
                ForEach([ApplicationRule.excludeFromBento, .ignoreEverywhere, .manageNormally]) { option in
                    participationOption(option)
                }
            }
            if rule == .manageNormally {
                HelpText("This is the default. No exception will be added.")
            }
            Spacer(minLength: 0)
            HStack {
                Button("Back") { self.application = nil }.fixedSize()
                Spacer(minLength: SettingsSpacing.s2)
                OverlayButtonRow {
                    SettingsPickerCancelButton { dismiss() }.fixedSize()
                    SettingsPickerConfirmButton(title: "Add Rule", isEnabled: rule != .manageNormally) {
                        model.setRule(rule, for: application.id)
                        onAdd(application.id)
                        dismiss()
                    }.fixedSize()
                }
            }
        }
    }

    private func participationOption(_ option: ApplicationRule) -> some View {
        Button { rule = option } label: {
            HStack(alignment: .top, spacing: SettingsSpacing.s2) {
                Image(systemName: rule == option ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(rule == option ? Color.accentColor : .secondary)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: SettingsSpacing.s1) {
                        Text(option.title)
                        if option == .excludeFromBento {
                            ApplicationRuleSuggestedBadge()
                        }
                    }
                    Text(option.explanation)
                        .font(SettingsFont.caption)
                        .foregroundStyle(PopupGlass.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, SettingsSpacing.s3)
            .frame(minHeight: SettingsSpacing.s8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(rule == option ? .isSelected : [])
    }
}

/// Opaque shaded accent keeps the recommendation's white text legible on popup glass.
struct ApplicationRuleSuggestedBadge: View {
    var body: some View {
        Text("Suggested")
            .font(SettingsFont.caption.weight(.medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 1)
            .background(Color(nsColor: PopupGlass.accentShadeColor), in: Capsule())
            .fixedSize()
    }
}

/// Keep native List selection and keyboard navigation, with the inset SwiftUI row background.
private struct RuleListSelectionAppearance: NSViewRepresentable {
    func makeNSView(context: Context) -> RuleListSelectionView { RuleListSelectionView() }
    func updateNSView(_ view: RuleListSelectionView, context: Context) { view.suppressNativeHighlight() }
}

final class RuleListSelectionView: NSView {
    private var selectionUpdateScheduled = false

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); suppressNativeHighlight() }
    override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); suppressNativeHighlight() }

    func suppressNativeHighlight() {
        guard !selectionUpdateScheduled else { return }
        selectionUpdateScheduled = true
        // Changing the table style reloads its rows. Attachment and representable updates can run
        // inside SwiftUI rendering, so wait until that pass finishes before touching the table.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.selectionUpdateScheduled = false
            var ancestor = self.superview
            while let view = ancestor {
                if let table = view as? NSTableView {
                    if table.selectionHighlightStyle != .none { table.selectionHighlightStyle = .none }
                    return
                }
                ancestor = view.superview
            }
        }
    }
}
