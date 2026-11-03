// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 LMC-Karma

import AppKit
import BetterTileCore
import BetterTileMacOS
import SwiftUI
import UniformTypeIdentifiers

/// Saved-layout headings and artwork are separate roles from status-card values.
private enum SavedLayoutFont {
    static let layoutTitle = Font.system(size: 15, weight: .semibold)
}

struct SavedLayoutSettings: View {
    @Bindable var editor: SavedLayoutEditor
    /// Nil only in previews and tests that edit layouts without a running model.
    var model: BetterTileModel? = nil
    /// Where the palette finds apps. Tests pass fixed lists.
    var paletteSource = SavedLayoutPaletteSource()
    var canvasInteraction = CanvasInteractionSource()
    var suppliedSession: SavedLayoutApplySession? = nil
    var targetOverride: SavedLayoutDesktop? = nil
    var targetNameOverride: String? = nil
    @State var groupsIntegration = SavedLayoutAppGroupsIntegration()
    @State private var search = ""
    @State var editing = false
    @State private var fallbackTarget = SavedLayoutTarget()
    @State var pagePlan = SavedLayoutPagePlan()
    var target: SavedLayoutTarget { model?.savedLayoutTarget ?? fallbackTarget }
    var readTargetDisplays: @MainActor () -> [LiveDisplay] = { DisplayFingerprintReader.current() }
    @State private var nameAction: NameAction?
    @State private var proposedName = ""
    var suppliedCreation: SavedLayoutCreation? = nil
    private var creation: SavedLayoutCreation { suppliedCreation ?? editor.creation }
    @State private var floatPicker = false
    @State var deleteConfirmation = false
    private var updateAction: SavedLayoutEditorAction? {
        get { creation.updateToConfirm }
        nonmutating set { creation.updateToConfirm = newValue }
    }
    @State private var preferenceRequest: SavedLayoutPreferenceRequest?
    @State private var showingExport = false
    private var appGroups: AppGroupsDocument { model?.appGroupsStore.document ?? .init() }
    private var preferenceAppIDs: [String] {
        editor.document?.slots.flatMap { $0.prefer.compactMap { preference -> String? in if case let .app(id) = preference { id } else { nil } } } ?? []
    }
    @State private var showKeyboard = false
    @State private var shapeMenuAnchor = AnchoredMenu()
    @FocusState private var nameFocused: Bool
    @State private var applications: [String: ApplicationChoice] = [:]
    @State private var applicationsResolved = false
    /// Apply state for this page. Created once the model's applier exists.
    @State private var ownedSession: SavedLayoutApplySession?
    private var session: SavedLayoutApplySession? { suppliedSession ?? ownedSession }

    private enum NameAction: String, Identifiable {
        case rename = "Rename", saveAs = "Save As"
        var id: Self { self }
    }

    var body: some View {
        @Bindable var creation = self.creation
        observedPage
        .sheet(item: $nameAction) { action in nameSheet(action) }
        .sheet(isPresented: $creation.showingSetup, onDismiss: {
            if let action = creation.setupDismissed(editor: editor, isApplying: isApplying) { perform(action) }
        }) {
            SavedLayoutNewLayoutSheet(onCancel: creation.cancelSetup, onContinue: creation.continueSetup)
        }
        .settingsPickerPanel(isPresented: $floatPicker, size: NSSize(width: 430, height: 480),
                             appearance: model?.configuration.overlayAppearance ?? OverlayAppearance()) { dismiss in
            SavedLayoutApplicationSheet(title: "Add Floating Window") { application in
                editor.assign(bundleID: application.bundleIdentifier, pane: nil, floating: true)
                dismiss()
            } onCancel: { dismiss() }
        }
        .alert(creation.confirmationTitle(editor: editor),
               isPresented: Binding(get: { creation.pending != nil }, set: { if !$0 { creation.keepEditing() } }),
               presenting: creation.pending) { action in
            if action.changesGeometry {
                Button("Cancel", role: .cancel) { creation.keepEditing() }
                Button("Continue") { creation.keepEditing(); perform(action) }
            } else {
                Button("Keep Editing", role: .cancel) { creation.keepEditing() }
                Button("Discard Draft", role: .destructive) { creation.keepEditing(); perform(action) }
            }
        } message: { action in
            Text(confirmationText(for: action))
        }
        .sheet(isPresented: $deleteConfirmation) { deleteSheet }
        .sheet(isPresented: $showingExport) {
            if let document = editor.document {
                SavedLayoutExportSheet(document: document, groups: appGroups, onCancel: { showingExport = false },
                    onExport: { showingExport = false; chooseExportDestination() })
            }
        }
        .sheet(isPresented: Binding(get: { updateAction != nil }, set: { if !$0 { updateAction = nil } })) {
            SavedLayoutUpdateConfirmation(name: updateLayoutName, turnsOffExtraWindows: updateTurnsOffExtraWindows,
                onCancel: { updateAction = nil }, onUpdate: confirmUpdate)
        }
        .sheet(isPresented: Binding(get: { editor.pendingImport != nil }, set: { if !$0 { editor.pendingImport = nil } })) {
            SavedLayoutImportSheet(editor: editor, groups: appGroups, onImport: {
                completeImport()
            }, onCancel: { editor.pendingImport = nil })
        }
        // A plan belongs to one layout. Opening another, or editing this one, drops it.
        .onChange(of: editor.url) { if !isApplying { resetApplyGroup(); refreshPagePlan() } }
        // A plan or result describes the layout as it was. Any edit or reload makes it stale, so the
        // group returns to Apply (a run in progress keeps going).
        .onChange(of: editor.document) { resetApplyGroup(); refreshTarget() }
        .onChange(of: editor.entries) { model?.savedLayoutActions.checkForChanges() }
        .task { initializePage() }
        .task(id: preferenceAppIDs) { resolvePageApplications() }
    }

    private var observedPage: some View {
        pageContents
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Saved layout editor")
        .onAppear { refreshTarget() }
        .onChange(of: model?.activeDisplayID) { refreshTarget() }
        .onChange(of: retainedDisplayID) { refreshTarget() }
        .onChange(of: target.selectionID) { refreshPagePlan() }
        .onChange(of: model?.savedLayoutApplier?.planRevision) {
            groupsIntegration.section?.refresh(notify: false)
            refreshPagePlan()
        }
        .onChange(of: model?.savedLayoutInventoryRevision) {
            pagePlan.inventoryChanged { refreshPagePlan() }
        }
        .onDisappear { pagePlan.cancel() }
        .background { SavedLayoutTargetWindowObserver(onBecameKey: refreshTarget).allowsHitTesting(false) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            refreshTarget()
        }
    }

    func initializePage() {
        if groupsIntegration.section == nil, let model {
            groupsIntegration.section = AppGroupsSectionModel(store: model.appGroupsStore,
                editor: appGroupsEditorBridge, didChange: { [weak model] in model?.savedLayoutApplier?.appGroupsDidLoad() })
        }
        if session == nil, let applier = model?.savedLayoutApplier {
            ownedSession = SavedLayoutApplySession(applier: applier, positions: { [editor] in editor.positionContext })
        }
        editor.refreshLibrary()
        if !editor.isDirty, let entry = editor.entries.first(where: { $0.lastPathComponent == model?.savedLayoutActionFile }),
           editor.url != entry {
            _ = editor.load(entry)
        } else if editor.document == nil {
            let entry = editor.entries.first
            if let entry { _ = editor.load(entry) }
        }
        _ = adoptOutsideRun()
    }
    var appGroupsEditorBridge: AppGroupsEditorBridge {
        AppGroupsEditorBridge(
            hasUnsavedChanges: { [editor] in editor.hasUnsavedChanges },
            save: { [editor] in
                guard editor.save() else {
                    throw SavedLayoutFileError(message: editor.message ?? "Couldn’t save the layout.")
                }
            },
            discard: { [editor] in _ = editor.discardChanges() },
            reload: { [editor] in _ = editor.reloadFromDisk(); editor.refreshLibrary() })
    }

    @discardableResult func completeImport() -> Bool {
        guard editor.completeImport(groups: model?.appGroupsStore) else { return false }
        groupsIntegration.section?.refresh(notify: false)
        model?.savedLayoutApplier?.appGroupsDidLoad()
        creation.finish(); resolvePageApplications()
        return true
    }

    private func resolvePageApplications() {
        var resolved: [String: ApplicationChoice] = [:]
        for id in Set(preferenceAppIDs) {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id),
               let choice = ApplicationCatalog.application(at: url) { resolved[id] = choice }
        }
        applications = resolved; applicationsResolved = true
    }

    private var pageContents: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                SettingsPageHeader(title: "Saved Layouts", subtitle: "Bring your apps back into place.")
                Spacer(minLength: 12)
                if !isEmptyLibrary {
                    VStack(alignment: .trailing, spacing: 6) {
                        HStack(spacing: 8) { newLayoutButton(prominent: false); saveCurrentButton(prominent: false) }
                        Text("New Layout starts empty. Save Current Layout copies the On: screen.")
                            .font(SettingsFont.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.horizontal, 24).padding(.top, 24).padding(.bottom, 16)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    notices
                    if let model, model.savedLayoutActionFile != nil,
                       model.savedLayoutApplier?.lastDocument != editor.document {
                        SettingsGroup("Last Apply") { SavedLayoutPanelRun(model: model).padding(SettingsSpacing.s3) }
                    }
                    if isEmptyLibrary {
                        firstUse
                    } else {
                        if !isEditing { layoutStrip }
                        if let document = editor.document {
                            if isEditing {
                                editorArea(document).disabled(editor.hasInvalidSource || isApplying)
                            } else {
                                selectedLayout(document)
                            }
                            if !creation.isDraft, let file = editor.url?.lastPathComponent, let model {
                                SavedLayoutAnywhereSettings(model: model, file: file)
                            }

                        }
                    }
                    if let section = groupsIntegration.section {
                        AppGroupsSection(model: section)
                    }
                    privacyDetails
                }
                .padding(.horizontal, 24).padding(.bottom, 20)
            }
        }
    }

    // MARK: Notices

    @ViewBuilder private var notices: some View {
        if model?.hasAccessibilityPermission != true {
            NoticeBanner(.warning, title: "Accessibility access is off",
                message: "New Layout and editing work without access. Save Current Layout and Apply need it.",
                action: .init(title: "Open Accessibility Settings…", perform: { model?.openAccessibilitySettings() }))
        }
        if let error = editor.libraryError { status(error, warning: true) }
        editorMessageNotice
        if editor.hasInvalidSource {
            HStack {
                if let rejected = editor.rejectedURL {
                    Button("Reload Rejected File") { request(.reload(rejected)) }
                }
                Button("Return to Last Valid Layout") { editor.returnToLastValid() }
            }
        }
    }

    /// Shared by the page and name sheet so feedback has the same severity in both places.
    @ViewBuilder var editorMessageNotice: some View {
        if let message = editor.message { status(message, warning: editor.messageStatus?.kind == .bad) }
    }

    // MARK: First use

    var isEmptyLibrary: Bool { editor.document == nil && editor.entries.isEmpty }

    private var firstUse: some View {
        SettingsGroup {
            VStack(alignment: .leading, spacing: 16) {
                Text("Create your first layout").font(SettingsFont.headline)
                HStack(alignment: .top, spacing: 24) {
                    VStack(alignment: .leading, spacing: 8) {
                        newLayoutButton(prominent: true)
                        Text("Build your own arrangement").font(SettingsFont.body.weight(.semibold))
                        Text("Start empty, choose a mode and shape, then add apps.")
                            .font(SettingsFont.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .leading, spacing: 8) {
                        saveCurrentButton(prominent: false)
                        Text("Keep what is on screen").font(SettingsFont.body.weight(.semibold))
                        Text("Copy the apps and positions on this desktop.")
                            .font(SettingsFont.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                Button("Import JSON…", action: importFile)
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
        }.font(SettingsFont.body)
    }

    var canCreate: Bool { !isApplying }

    @ViewBuilder private func newLayoutButton(prominent: Bool) -> some View {
        let button = Button(action: creation.openSetup) {
            Label("New Layout", systemImage: "rectangle.split.2x2")
        }.disabled(!canCreate).help(isApplying ? "Wait until Apply finishes." : "Start from an empty arrangement and choose the apps.")
        if prominent { button.buttonStyle(.borderedProminent) } else { button }
    }

    // MARK: Layout cards

    private var layoutStrip: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Layouts").font(SettingsFont.headline)
                Spacer()
                Text("\(editor.entries.count) \(editor.entries.count == 1 ? "layout" : "layouts") · A–Z").font(SettingsFont.caption).foregroundStyle(.secondary)
                TextField("Find a layout", text: $search)
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 190)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), alignment: .top)], alignment: .leading, spacing: 10) {
                    if editor.url == nil, let document = editor.document {
                        layoutCard(document: document, name: document.name, url: nil, selected: true)
                    }
                    ForEach(filteredEntries, id: \.self) { url in
                        // The open layout shows the draft, so the card follows unsaved edits.
                        let open = editor.selectedLibraryURL == url
                        layoutCard(document: open ? editor.document : editor.entryDocuments[url],
                                   name: open ? (editor.document?.name ?? editor.entryNames[url] ?? url.lastPathComponent) : editor.entryNames[url] ?? url.lastPathComponent,
                                   url: url, selected: open)
                    }
            }
            .padding(2)
            if filteredEntries.isEmpty, !search.isEmpty {
                Text("No layouts match “\(search)”.").font(SettingsFont.body).foregroundStyle(.secondary)
            }
        }
    }

    var filteredEntries: [URL] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return editor.entries.filter { query.isEmpty || (editor.entryNames[$0] ?? $0.lastPathComponent).localizedStandardContains(query) }
    }

    private func layoutCard(document: SavedLayoutDocument?, name: String, url: URL?, selected: Bool) -> some View {
        Button {
            guard let url, !selected else { return }
            request(.open(url))
        } label: {
            SettingsGroup {
                HStack(spacing: 10) {
                    Group {
                        if let document { SavedLayoutThumbnail(document: document) }
                        else { Image(systemName: "exclamationmark.triangle").foregroundStyle(.secondary) }
                    }.frame(width: 42, height: 30)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(name).font(SettingsFont.body.weight(.semibold)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 6) {
                            Text(cardSummary(document, unsaved: url == nil || (selected && editor.isDirty), problem: url.flatMap { editor.entryProblems[$0] }))
                                .font(SettingsFont.caption).foregroundStyle(.secondary).lineLimit(document == nil ? 3 : 1)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(12).frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
                .background(selected ? Color.accentColor.opacity(0.10) : Color.clear)
            }
            .overlay(RoundedRectangle.settings(SavedLayoutMetrics.panelRadius)
                .strokeBorder(selected ? Color.accentColor : Color.clear, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(name)
        .accessibilityLabel(name + (selected ? ", open" : ""))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .contextMenu {
            if selected { fileMenuItems }
            else if let url {
                Button("Open") { request(.open(url)) }
                Button("Update from Current Desktop") { request(.updateFromFile(url)) }
                    .disabled(!canCapture || document == nil)
            }
        }
    }

    var isEditing: Bool { editing || creation.isDraft }

    private func cardSummary(_ document: SavedLayoutDocument?, unsaved: Bool, problem: String? = nil) -> String {
        guard let document else { return problem ?? "Unreadable file" }
        let apps = SavedLayoutUpdateMapping.panes(document).count
        return unsaved && creation.isDraft ? "Draft · Not saved" : "\(document.mode.title) · \(apps) \(apps == 1 ? "pane" : "panes")" + (unsaved ? " · Unsaved" : "")
    }

    private var isApplying: Bool {
        if model?.savedLayoutApplier?.isApplying == true { return true }
        if case .applying = session?.phase { return true }
        return false
    }
    /// Keep progress and recovery on the run's desktop until a new Apply or document releases it.
    private var retainedDisplayID: DisplayID? {
        if isApplying { return session?.preview?.displayID ?? session?.owner?.desktop.displayID }
        guard let owner = session?.owner, owner.document == editor.document, session?.run != nil else { return nil }
        let hasRecovery = owner.document.slots.contains { slot in
            switch session?.state(forSlot: slot.id) {
            case .failed, .needsChoice: true
            default: false
            }
        }
        return session?.canUndo == true || hasRecovery ? owner.desktop.displayID : nil
    }
    var displayID: DisplayID? { targetOverride?.displayID ?? retainedDisplayID ?? target.displayID }
    func refreshTarget() {
        target.refresh(current: { model?.savedLayoutApplier?.currentDisplayID() },
            displays: model?.availableDisplays ?? [], retaining: targetOverride?.displayID ?? retainedDisplayID,
            live: readTargetDisplays())
        refreshPagePlan()
    }
    func refreshPagePlan() {
        guard !isApplying else { return }
        let id = targetOverride?.displayID ?? target.selectionID
        let identity = target.picked.map { "\($0.uuid)|\($0.vendor)|\($0.model)|\($0.serial)" }
        pagePlan.refresh(document: editor.document, displayID: id, identity: identity,
            displays: model?.availableDisplays ?? [], unavailable: target.unavailableReason, disconnectedArea: target.pickedWorkArea) { document, display in
                guard let applier = model?.savedLayoutApplier else { throw SavedLayoutFileError(message: "Preview unavailable.") }
                let choices = session?.preview?.document == document && session?.preview?.displayID == display ? session?.choices ?? [:] : [:]
                return try applier.preview(document, displayID: display, choices: choices, positions: editor.positionContext)
            }
    }
    func apply(_ document: SavedLayoutDocument, on explicit: DisplayID? = nil) {
        guard !isApplying else { session?.refuseApplyingAction(); return }
        guard let id = target.prepareApply(current: { model?.savedLayoutApplier?.currentDisplayID() },
            displays: model?.availableDisplays ?? [], explicit: explicit ?? targetOverride?.displayID,
            live: readTargetDisplays()) else {
            if explicit == nil, targetOverride == nil, let reason = target.unavailableReason {
                session?.refuseTarget(reason)
                return
            }
            // Keep the applier's inline error for a selected display that disappeared.
            session?.apply(document: document, displayID: explicit ?? targetOverride?.displayID)
            return
        }
        // Publish the click's fresh destination before the session starts its preview and run.
        model?.settingsSavedLayoutApplyStarted()
        session?.apply(document: document, displayID: id)
    }
    private var targetDesktop: SavedLayoutDesktop? {
        if let targetOverride { return targetOverride }
        guard let state = try? model?.savedLayoutApplier?.placementSnapshot(),
              let id = displayID, state.displays.contains(where: { $0.id == id }),
              let space = state.observation.currentSpace(on: id) else { return nil }
        return .init(displayID: id, spaceID: space)
    }
    private var targetName: String {
        if let targetNameOverride { return targetNameOverride }
        if let name = target.name(for: displayID) { return name }
        guard let id = displayID else { return "No display available" }
        guard let screen = NSScreen.screens.first(where: { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.stringValue == id.rawValue }) else { return "Display unavailable" }
        return screen.localizedName
    }
    func ownsSelection(_ document: SavedLayoutDocument) -> Bool {
        guard let owner = session?.owner, let targetDesktop, isApplying || session?.run != nil else { return false }
        return owner.document == document && owner.desktop == targetDesktop && (owner.fileURL == nil || owner.fileURL == editor.url)
    }
    func showsUndoApply(_ document: SavedLayoutDocument) -> Bool { ownsSelection(document) && session?.canUndo == true }
    func applyingStatus(_ document: SavedLayoutDocument) -> String {
        ownsSelection(document) ? "Applying…" : "Another layout is applying…"
    }
    func canApply(_ document: SavedLayoutDocument) -> Bool {
        session != nil && model?.hasAccessibilityPermission == true && !document.slots.isEmpty && !editor.hasInvalidSource && !isApplying && target.unavailableReason == nil
    }

    func targetContext(_ document: SavedLayoutDocument) -> String {
        guard ownsSelection(document) else { return "Current desktop" }
        return (isApplying ? "" : "Last apply: ") + targetName + " · Current desktop"
    }
    func pickDisplay(_ id: DisplayID) {
        guard !isApplying else { return }
        target.pick(id, retaining: retainedDisplayID)
        refreshPagePlan()
    }
    func followFocusedWindow() {
        guard !isApplying else { return }
        let refusal = target.unavailableReason
        target.followFocusedWindow(current: { model?.savedLayoutApplier?.currentDisplayID() },
            displays: model?.availableDisplays ?? [], retaining: retainedDisplayID, live: readTargetDisplays())
        if let refusal { session?.clearTargetRefusal(refusal) }
    }
    var showsDisplayPicker: Bool { target.liveDisplays.count > 1 || target.picked != nil }
    private var pickerDisplayID: DisplayID? { isApplying ? displayID : target.selectionID }
    var pickerName: String {
        if !isApplying, case let .disconnected(name) = target.selection {
            return name.isEmpty ? "Disconnected" : "Disconnected — " + name
        }
        let name = target.name(for: pickerDisplayID) ?? targetName
        return !isApplying && target.picked == nil ? name + " (follows focus)" : name
    }
    @ViewBuilder private var displayPicker: some View {
        if showsDisplayPicker {
            HStack(spacing: 6) {
                Text("On:")
                Menu {
                    Picker("Screen", selection: Binding(get: { target.selection }, set: { choice in
                        switch choice {
                        case .following: followFocusedWindow()
                        case let .picked(id): pickDisplay(id)
                        case .disconnected: break
                        }
                    })) {
                        ForEach(target.choices, id: \.self) { choice in
                            switch choice {
                            case .following:
                                Text("Follow Focused Window").tag(choice)
                            case let .picked(id):
                                Text(target.name(for: id) ?? "Display").tag(choice)
                            case .disconnected:
                                Text(pickerName).tag(choice).disabled(true)
                            }
                        }
                    }
                    .pickerStyle(.inline).labelsHidden()
                } label: { Text(pickerName) }
                .menuStyle(.borderedButton)
            }
            .fixedSize().disabled(isApplying)
            .help(target.unavailableReason ?? "Choose a screen or follow the focused window for the next Apply.")
        } else {
            Text("On: " + pickerName).font(SettingsFont.body).fixedSize()
        }
    }

    private func selectedLayout(_ document: SavedLayoutDocument) -> some View {
        let owns = ownsSelection(document)
        let states: [String: SavedLayoutSlotStatus] = owns ? Dictionary(uniqueKeysWithValues: document.slots.compactMap { slot in
            session?.state(forSlot: slot.id).map { state in
                return (slot.id, state)
            }
        }) : [:]
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(document.name).font(SettingsFont.headline).lineLimit(2).help(document.name)
                    Text("Fills the current desktop of one screen.")
                        .font(SettingsFont.caption).foregroundStyle(.secondary)
                    if owns { Text(targetContext(document)).font(SettingsFont.caption).foregroundStyle(.secondary) }
                }
                Spacer(minLength: 8)
                Menu { fileMenuItems } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .disabled(isApplying)
                if !creation.isDraft {
                    displayPicker
                    if isApplying {

                        Text(applyingStatus(document)).font(SettingsFont.body)
                    } else {
                        Button("Apply") { apply(document) }
                            .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                            .disabled(!canApply(document))
                            .help(target.unavailableReason ?? (model?.hasAccessibilityPermission != true ? "Apply needs Accessibility access." : "Arrange open windows on the current desktop."))
                    }
                }
            }
            if let reason = target.unavailableReason, !creation.isDraft, !isApplying {
                Text(reason).font(SettingsFont.caption).foregroundStyle(.secondary)
            }
            if creation.isDraft {
                Text("Add apps to the draft, then save. No windows change until you choose Apply.")
                    .font(SettingsFont.caption).foregroundStyle(.secondary)
            } else if editing {
                HStack {
                    Text("Changes stay in the draft until you save.").font(SettingsFont.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Done Editing") { editing = false }
                }
            } else {
                SettingsGroup {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Label("Layout preview", systemImage: "display")
                            Spacer()
                            Text("\(document.mode.title) · \(SavedLayoutUpdateMapping.panes(document).count) panes")
                        }.font(SettingsFont.caption).foregroundStyle(.secondary)
                        ViewThatFits(in: .horizontal) {
                            HStack(alignment: .top, spacing: 16) {
                                previewArtwork(document, states: states, owns: owns).frame(width: 300)
                                applyPlanLines.frame(minWidth: 220, maxWidth: .infinity, alignment: .leading)
                            }
                            VStack(alignment: .leading, spacing: 12) {
                                previewArtwork(document, states: states, owns: owns)
                                applyPlanLines
                            }
                        }
                        HStack {
                            Text("Apps and positions are saved. Documents and tabs inside apps are not.")
                                .font(SettingsFont.caption).foregroundStyle(.secondary)
                            Spacer(minLength: 8)
                            Button("Edit Layout") { editing = true }
                                .disabled(isApplying || editor.hasInvalidSource)
                        }
                    }.padding(12)
                }
            }
            layoutSwitches(document)
            if editor.isDirty, !creation.isDraft {
                HStack { Spacer(); Button("Save Changes") { _ = editor.save() }.disabled(editor.hasInvalidSource) }
            }
            if !creation.isDraft {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(pageStatus(document, states: states)).font(SettingsFont.body.weight(.semibold))
                        Text(pageDetail(document)).font(SettingsFont.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    if showsUndoApply(document) { Button("Undo Apply") { session?.undo() }.disabled(isApplying) }

                }
            }
            if let problem = session?.problem { NoticeBanner(.warning, title: problem) }
        }.font(SettingsFont.body)
    }
    private func previewArtwork(_ document: SavedLayoutDocument, states: [String: SavedLayoutSlotStatus], owns: Bool) -> some View {
        SavedLayoutPagePreview(document: document, applications: applications, workArea: isApplying ? (session?.preview?.workArea ?? pagePlan.workArea) : pagePlan.workArea, states: states,
                            choice: { slot, dismiss in slotChooser(slot, document: document, onChosen: dismiss) }, appGroups: appGroups)
    }

    private var planPresentation: SavedLayoutPlanPresentation? {
        if session?.choices.isEmpty != false, let document = editor.document, ownsSelection(document),
           let presentation = session?.run?.planPresentation { return presentation }
        return pagePlan.presentation(groups: appGroups, resolvedBundleIDs: model?.appGroupsStore.resolvedBundleIDs ?? [:],
            name: { applications[$0]?.name ?? "An app that is not installed" },
            displayName: { target.name(for: $0) ?? "Display" })
    }

    @ViewBuilder private var applyPlanLines: some View {
        if !isApplying, let presentation = planPresentation {
            VStack(alignment: .leading, spacing: 8) {
                Text("Now on " + (target.name(for: target.selectionID) ?? targetName))
                    .font(SettingsFont.caption).foregroundStyle(.secondary)
                ForEach(Array(presentation.lines.enumerated()), id: \.offset) { _, line in
                    Text(line).font(SettingsFont.body).fixedSize(horizontal: false, vertical: true)
                }
                ForEach(Array(presentation.issues.enumerated()), id: \.offset) { _, issue in
                    Text(issue.message).font(SettingsFont.caption).foregroundStyle(.secondary)
                }
            }
        }
        if let problem = pagePlan.problem, target.unavailableReason == nil {
            Text(problem).font(SettingsFont.caption).foregroundStyle(.secondary)
        }
    }

    private func layoutSwitches(_ document: SavedLayoutDocument) -> some View {
        SettingsGroup {
            if document.mode == .bento {
                SettingsRow("Add extra windows as panes") {
                    Toggle("", isOn: Binding(get: { document.extraWindows == .addAsPanes },
                        set: { on in editor.edit { $0.extraWindows = on ? .addAsPanes : .float } })).labelsHidden()
                }
                SettingsSeparator()
            }
            SettingsRow("Keep this layout for new windows") {
                Toggle("", isOn: Binding(get: { document.keepForNewWindows },
                    set: { on in editor.edit { $0.keepForNewWindows = on } })).labelsHidden()
            }
        }.toggleStyle(.switch).controlSize(.small)
    }

    func pageStatus(_ document: SavedLayoutDocument, states: [String: SavedLayoutSlotStatus]) -> String {
        if isApplying, session?.isStarting == true || model?.savedLayoutApplier?.isRunning == false { return "Applying…" }
        guard ownsSelection(document) else { return "Ready to apply" }
        if isApplying { return "Applying…" }
        if states.values.contains(where: { SavedLayoutPagePreview.needsRecovery($0) }) { return "Some windows need attention" }
        if let run = session?.run {
            if run.planPresentation?.alreadyArranged == true { return run.presentation.title }
            if run.status == .applied, !run.offersUndo { return "Already applied" }
            return run.status.rawValue
        }
        return "Ready to apply"
    }
    func pageDetail(_ document: SavedLayoutDocument) -> String {
        if ownsSelection(document), let reason = session?.undoUnavailableReason { return reason }
        if ownsSelection(document), let session, let run = session.run, !isApplying {
            if let presentation = run.planPresentation { return presentation.pageDetail(movedSlots: run.result.movedSlots) }
            let states = document.slots.compactMap { session.state(forSlot: $0.id) }
            let placed = run.result.placed
            let skipped = states.filter { $0 == .skipped }.count
            let attention = max(0, document.slots.count - placed - skipped)
            var parts = ["\(placed) placed"]
            if attention > 0 { parts.append("\(attention) \(attention == 1 ? "needs" : "need") attention") }
            if skipped > 0 { parts.append("\(skipped) skipped") }
            return parts.joined(separator: " · ")
        }
        if model?.hasAccessibilityPermission != true { return "Apply and Save Current Layout need Accessibility access. Editing and export do not." }
        return "Uses eligible open windows on this desktop."
    }
    func slotChooser(_ slot: String, document: SavedLayoutDocument, onChosen: @escaping () -> Void = {}) -> AnyView? {
        guard !isApplying, let preview = pagePlan.preview, preview.document == document, preview.problem == nil,
              let row = preview.rows.first(where: { $0.id == slot }), row.choiceWindows.count > 1 else { return nil }
        return AnyView(SavedLayoutWindowChoiceList(appName: row.appName, windows: row.choiceWindows,
            chosen: session?.choices[slot]) { window in chooseWindow(window, forSlot: slot, document: document, onChosen: onChosen) })
    }
    func chooseWindow(_ window: WindowID, forSlot slot: String, document: SavedLayoutDocument, onChosen: () -> Void = {}) {
        guard !isApplying, let preview = pagePlan.preview, preview.document == document else { return }
        session?.review(document: document, displayID: preview.displayID)
        if session?.choose(window: window, forSlot: slot) == true, let value = session?.preview {
            pagePlan.updateChoices(from: value)
            onChosen()
        }
    }

    // MARK: Editor

    private func editorArea(_ document: SavedLayoutDocument) -> some View {
        SavedLayoutCanvasView(
            editor: editor, document: document,
            overlayAppearance: model?.configuration.overlayAppearance ?? .init(),
            dividerThickness: model?.configuration.dividerThickness ?? 6,
            paletteSource: paletteSource,
            header: AnyView(VStack(alignment: .leading, spacing: 10) {
                titleRow(document)
                Text("Fills the current desktop of one screen.").font(SettingsFont.caption).foregroundStyle(.secondary)
                modeRow(document)
                layoutSwitches(document)
            }),
            side: AnyView(sideCard(document)),
            accessory: AnyView(applyPlanLines),
            interaction: canvasInteraction, appGroups: appGroups
        )
    }

    private func titleRow(_ document: SavedLayoutDocument) -> some View {
        HStack(spacing: 8) {
            Text(document.name).font(SavedLayoutFont.layoutTitle).lineLimit(1).truncationMode(.tail)
                .help(document.name).textSelection(.enabled)
            if document.mode != .manual, let layout = document.layout { shapeMenu(layout) }
            Spacer(minLength: 8)
            if editor.isDirty || editor.url == nil {
                SettingsPill(editor.url == nil ? "Not saved yet" : "Unsaved changes")
            }
            if creation.isDraft {
                Button("Cancel") { request(.cancelDraft) }
                Button("Save Layout") {
                    if creation.save(editor: editor) { editing = false }
                }
                .buttonStyle(.borderedProminent).keyboardShortcut("s", modifiers: .command)
                .disabled(editor.hasInvalidSource)
            } else {
                Button("Done Editing") { editing = false }
                Button("Save") {
                    if editor.url == nil { showName(.saveAs) } else { editor.save() }
                }
                .disabled(editor.hasInvalidSource || !(editor.isDirty || editor.url == nil))
                .keyboardShortcut("s", modifiers: .command)
            }
            Menu {
                fileMenuItems
            } label: { Image(systemName: "ellipsis.circle") }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel("Layout file actions")
        }
        .font(SettingsFont.body)
        .frame(minHeight: SettingsMetrics.rowMinHeight)
    }

    /// The five preset shapes, each with its layout icon as a template image (1.265 times the 14 pt menu size).
    static func shapeMenuItems(current: String? = nil, _ choose: @escaping (TabbedPreset) -> Void) -> [AnchoredMenuItem] {
        TabbedPreset.allCases.map { preset in
            let name = SavedLayoutCanvas.shape(SavedLayoutCanvas.presetLayout(preset, panes: [])).name
            return AnchoredMenuItem(
                title: name,
                image: LayoutGlyph.layout(preset).templateImage(canvasSize: CGFloat(LayoutGlyph.canvasSize(besideSymbolSize: 14))),
                isChecked: name == current
            ) { choose(preset) }
        }
    }

    /// The shape tag doubles as the preset chooser. The chip is drawn by the same borderless SwiftUI
    /// `Menu` as before, so it keeps its pill and system chevron. A SwiftUI `Menu` drops item images, so
    /// the chip ignores the pointer and a clear button above it pops an AppKit menu whose items carry
    /// the layout icons.
    func shapeMenu(_ layout: SavedLayoutNode) -> some View {
        let shape = SavedLayoutCanvas.shape(layout)
        return Menu {
            Button(shape.name) {}
        } label: {
            SettingsPill(shape.name)
        }
        .menuStyle(.button).buttonStyle(.borderless).controlSize(.small).fixedSize()
        .allowsHitTesting(false)
        .focusable(false)
        // Borderless Menu labels discard their background. Paint the chip on the control.
        .background(SettingsColor.fill, in: Capsule())
        .overlay {
            Button {
                shapeMenuAnchor.show(Self.shapeMenuItems(current: shape.name) { request(.preset($0)) })
            } label: { Color.clear.contentShape(Capsule()) }
            .buttonStyle(.plain)
        }
        .background { AnchoredMenuView(anchor: shapeMenuAnchor) }
        .help("Shape: \(shape.name). Choose a preset shape.")
        .accessibilityLabel("Shape: \(shape.name)")
    }

    @ViewBuilder var fileMenuItems: some View {
        Button("Update from Current Desktop") { request(.updateFromDesktop) }
            .disabled(!canUpdate).help(updateUnavailableReason ?? captureHelp)
        if !isEditing { Button("Edit Layout") { editing = true }.disabled(isApplying || editor.hasInvalidSource) }
        Divider()
        Button("Import JSON…", action: importFile)
        Divider()
        Button("Rename…") { showName(.rename) }.disabled(editor.document == nil || editor.hasInvalidSource)
        Button("Duplicate…") { showName(.saveAs) }.disabled(editor.document == nil || editor.hasInvalidSource)
        Button("Export JSON…", action: exportFile).disabled(editor.document == nil || editor.hasInvalidSource)
        if let url = editor.sourceURL {
            Button("Edit in Text Editor") { editor.editInTextEditor() }
            Button("Reveal in Finder") { editor.revealInFinder() }
            Button("Reload File") { request(.reload(url)) }
        }
        if let rejected = editor.rejectedURL { Button("Reload Rejected File") { request(.reload(rejected)) } }
        Button("Reload Library List", action: reloadLibrary)
        Divider()
        Button("Delete…", role: .destructive) { deleteConfirmation = true }
            .disabled(editor.url == nil || editor.hasInvalidSource || isApplying)
    }

    func reloadLibrary() {
        model?.savedLayoutActions.reload()
        editor.refreshLibrary()
    }

    private func modeRow(_ document: SavedLayoutDocument) -> some View {
        HStack(spacing: 8) {
            LayoutModePicker("Mode", selection: Binding(get: { document.mode }, set: { request(.mode($0)) }))
                .fixedSize()
            Spacer()
            Button { editor.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .disabled(!editor.canUndo)
                .help(editor.undoStack.last.map { "Undo: \($0.label)" } ?? "Nothing to undo")
                .accessibilityLabel("Undo")
            Button { editor.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                .disabled(!editor.canRedo)
                .help(editor.redoStack.last.map { "Redo: \($0.label)" } ?? "Nothing to redo")
                .accessibilityLabel("Redo")
            Button { showKeyboard.toggle() } label: { Image(systemName: "keyboard") }
                .popover(isPresented: $showKeyboard, arrowEdge: .bottom) { SavedLayoutKeyboardHelp() }
                .accessibilityLabel("Keyboard shortcuts")
        }
        .buttonStyle(.borderless)
        .font(SettingsFont.body)
        .frame(minHeight: SettingsMetrics.rowMinHeight)
    }

    private var sidePreferencePopover: some View {
        SavedLayoutPreferencePopover(request: preferenceRequest,
            appearance: model?.configuration.overlayAppearance ?? .init(), onDismiss: { id in
                if preferenceRequest?.id == id { preferenceRequest = nil }
            }, content: { slot, dismiss in
                AnyView(SavedLayoutPanePreferences(editor: editor, slotID: slot, groups: appGroups,
                    applications: applications, paletteSource: paletteSource, onDone: dismiss))
            })
    }

    // MARK: Side card

    @ViewBuilder private func sideCard(_ document: SavedLayoutDocument) -> some View {
        SettingsGroup {
            VStack(alignment: .leading, spacing: 10) {
                if document.mode == .manual {
                    manualCard(document)
                } else {
                    proportionsCard(document)
                    if let pane = selectedPane(document) {
                        Button("Edit preferences…") {
                            if let id = editor.preferenceSlot(in: pane) { preferenceRequest = .init(slotID: id) }
                        }.background { sidePreferencePopover }
                    }
                    if document.mode == .tabbed, let pane = selectedPane(document),
                       case let .group(groupID) = pane.node {
                        SettingsSeparator().padding(.horizontal, -SettingsSpacing.s3)
                        Text("Tabs").font(SettingsFont.body.weight(.medium))
                        ForEach(SavedLayoutCanvasGeometry.slotIDs(in: pane.node, document: document), id: \.self) {
                            slotRow($0, group: groupID)
                        }
                    }
                    if let pane = selectedPane(document) {
                        SettingsSeparator().padding(.horizontal, -SettingsSpacing.s3)
                        paneActions(pane, document: document)
                    }
                    SettingsSeparator().padding(.horizontal, -SettingsSpacing.s3)
                    SettingsRow("Pane gap") {
                        Stepper("\(document.paneGap.formatted(.number)) pt",
                                value: Binding(get: { document.paneGap }, set: { gap in editor.edit { $0.paneGap = gap } }), in: 0...12)
                            .fixedSize().accessibilityLabel("Pane gap in points")
                    }
                    .padding(.horizontal, -SettingsSpacing.s3)
                    if selectedPane(document) == nil {
                        Button("Add Floating Window…") { floatPicker = true }.controlSize(.small)
                            .frame(maxWidth: .infinity, minHeight: SettingsMetrics.rowMinHeight, alignment: .leading)
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        } footer: {
            if document.mode == .manual {
                if editor.selectedRectangle == nil || !(document.windows + document.floats).contains(where: { $0.slot == editor.selectedRectangle }) {
                    HelpText("Click an app in the palette to add a window, then select its rectangle to set its position and size.")
                }
            } else if !(selectedPane(document).map { pane in
                guard let root = document.layout, pane.path.last != nil else { return false }
                if case .split? = SavedLayoutCanvas.node(at: Array(pane.path.dropLast()), in: root) { return true }
                return false
            } ?? false) {
                HelpText("Select a pane in a split to change its share. Or drag a divider on the canvas.")
            }
        }
        .font(SettingsFont.body)
    }

    /// Split or remove the selected pane. A button that cannot run says why in its help.
    private func paneActions(_ pane: SavedLayoutPane, document: SavedLayoutDocument) -> some View {
        func reason(_ outcome: SavedLayoutOutcome) -> String? { if case let .rejected(text) = outcome { text } else { nil } }
        let columns = reason(SavedLayoutCanvas.splitting(pane.path, axis: .vertical, in: document))
        let rows = reason(SavedLayoutCanvas.splitting(pane.path, axis: .horizontal, in: document))
        let removal = reason(SavedLayoutCanvas.removingPane(pane.path, from: document))
        var removeButton: some View {
            Button(role: .destructive) { editor.removePane(pane) } label: { Label("Remove Pane", systemImage: "trash") }
                .fixedSize().controlSize(.small)
                .disabled(removal != nil).help(removal ?? "Remove this pane").accessibilityLabel("Remove Pane")
        }
        var addButton: some View {
            Button("Add Floating Window…") { floatPicker = true }.fixedSize().controlSize(.small)
        }

        var splitButtons: some View {
            HStack(spacing: 6) {
                Button { editor.split(pane, axis: .vertical) } label: { Text("Columns") }
                    .fixedSize()
                    .disabled(columns != nil).help(columns ?? "Split this pane into columns").accessibilityLabel("Split Columns")
                Button { editor.split(pane, axis: .horizontal) } label: { Text("Rows") }
                    .fixedSize()
                    .disabled(rows != nil).help(rows ?? "Split this pane into rows").accessibilityLabel("Split Rows")
            }.controlSize(.small)
        }
        return VStack(alignment: .leading, spacing: 6) {
            ViewThatFits(in: .horizontal) {
                SettingsRow("Pane") { splitButtons }
                    .padding(.horizontal, -SettingsSpacing.s3)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Pane").font(SettingsFont.body.weight(.medium))
                    splitButtons.frame(minHeight: SettingsMetrics.rowMinHeight)
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: SettingsSpacing.s2) { removeButton; addButton }
                VStack(alignment: .leading, spacing: SettingsSpacing.s2) { removeButton; addButton }
            }
            .frame(maxWidth: .infinity, minHeight: SettingsMetrics.rowMinHeight, alignment: .leading)
        }
    }

    private func selectedPane(_ document: SavedLayoutDocument) -> SavedLayoutPane? {
        SavedLayoutCanvasGeometry.panes(document).first { $0.id == editor.selectedPane }
    }

    /// The selected pane's share of its split: a percent stepper and, for two-part splits, three presets.
    @ViewBuilder private func proportionsCard(_ document: SavedLayoutDocument) -> some View {
        Text("Proportions").font(SettingsFont.body.weight(.medium))
        if let pane = selectedPane(document), let root = document.layout, let child = pane.path.last,
           case let .split(_, ratios, children)? = SavedLayoutCanvas.node(at: Array(pane.path.dropLast()), in: root) {
            let parent = Array(pane.path.dropLast())
            let share = ratios[child]
            SettingsRow("This pane", caption: children.indices.map { childName($0, in: children, document: document) }.joined(separator: "\n")) {
                Stepper("\(Int((share * 100).rounded())) %", value: Binding(
                    get: { (share * 100).rounded() },
                    set: { editor.setRatio(path: parent, child: child, ratio: $0 / 100) }), in: 1...99, step: 5)
                    .fixedSize()
                    .accessibilityLabel("Share of this pane in percent")
            }
            .padding(.horizontal, -SettingsSpacing.s3)
            if children.count == 2 {
                Picker("Presets", selection: Binding(get: { presetIndex(ratios) }, set: { index in
                    guard let index else { return }
                    editor.setRatio(path: parent, child: 0, ratio: [0.5, 1.0 / 3, 2.0 / 3][index])
                })) {
                    Text("Equal").tag(Optional(0))
                    Text("⅓ · ⅔").tag(Optional(1))
                    Text("⅔ · ⅓").tag(Optional(2))
                }
                .pickerStyle(.segmented).labelsHidden()
            } else {
                Button("Make Equal") {
                    if let root = editor.document?.layout, let equal = try? SavedLayoutCanvas.settingShare(
                        in: root, path: parent, child: child, to: 1 / Double(children.count)) {
                        editor.edit(label: "Make equal") { value in
                            value.layout = equal
                            if case let .split(axis, _, nodes)? = SavedLayoutCanvas.node(at: parent, in: equal) {
                                value.layout = SavedLayoutCanvas.replacing(equal, at: parent, with: .split(axis: axis,
                                    ratios: Array(repeating: 1 / Double(nodes.count), count: nodes.count), children: nodes))
                            }
                        }
                    }
                }.controlSize(.small)
            }
        }
    }

    private func presetIndex(_ ratios: [Double]) -> Int? {
        [0.5, 1.0 / 3, 2.0 / 3].firstIndex { abs($0 - ratios[0]) < 0.005 }
    }

    private func childName(_ index: Int, in children: [SavedLayoutNode], document: SavedLayoutDocument) -> String {
        let ids = SavedLayoutCanvasGeometry.slotIDs(in: children[index], document: document)
        let count = SavedLayoutCanvas.leaves(children[index]).count
        if count > 1 { return "\(count) panes" }
        return ids.first.map(appName) ?? "Empty pane"
    }

    @ViewBuilder private func manualCard(_ document: SavedLayoutDocument) -> some View {
        if let id = editor.selectedRectangle, let rectangle = (document.windows + document.floats).first(where: { $0.slot == id }) {
            Text("Position and size").font(SettingsFont.body.weight(.medium))
            Button("Edit preferences…") { preferenceRequest = .init(slotID: id) }.background { sidePreferencePopover }
            Text(appName(id)).font(SettingsFont.caption).foregroundStyle(.secondary).lineLimit(1)
            Text("Percent of work area").font(SettingsFont.caption).foregroundStyle(.secondary)
            rectangleControls(rectangle)
            let moveMenu = Menu("Move Slot To") {
                Button("Deliberate Float") { editor.moveSlot(id, to: nil) }
                if document.floats.contains(where: { $0.slot == id }) {
                    Button("Manual Window") { editor.returnToManualWindow(id) }
                }
            }
            .fixedSize().accessibilityLabel("Move app slot for \(appName(id))")
            let removeButton = Button("Remove from Layout", role: .destructive) { editor.removeSlot(id) }
                .fixedSize().controlSize(.small)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: SettingsSpacing.s2) { moveMenu; removeButton }
                VStack(alignment: .leading, spacing: SettingsSpacing.s2) { moveMenu; removeButton }
            }
            .frame(maxWidth: .infinity, minHeight: SettingsMetrics.rowMinHeight, alignment: .leading)
        } else {
            Text("Window").font(SettingsFont.body.weight(.medium))
        }
    }

    // MARK: Save Current Layout

    var canCapture: Bool {
        model?.hasAccessibilityPermission == true && !isApplying && target.unavailableReason == nil
    }
    var captureHelp: String {
        "Copy the windows on \(target.name(for: target.selectionID) ?? "the selected screen")’s current desktop."
    }
    private var captureUnavailableReason: String {
        target.unavailableReason ?? (model?.hasAccessibilityPermission == true ? "Wait until Apply finishes." : "Save Current Layout needs Accessibility access.")
    }
    @ViewBuilder private func saveCurrentButton(prominent: Bool) -> some View {
        let button = Button { request(.capture) } label: { Label("Save Current Layout", systemImage: "viewfinder") }
            .disabled(!canCapture).help(canCapture ? captureHelp : captureUnavailableReason)
        if prominent { button.buttonStyle(.borderedProminent) } else { button }
    }
    /// Captures the next picker destination, never the recovery owner's pinned display.
    private func captureDisplay() -> DisplayID? {
        refreshTarget()
        guard let id = targetOverride?.displayID ?? target.selectionID,
              model?.availableDisplays.contains(where: { $0.id == id }) == true,
              target.unavailableReason == nil else {
            editor.reportFailure(target.unavailableReason ?? "The current desktop could not be identified.")
            return nil
        }
        return id
    }
    private func saveCurrentLayout() {
        guard let model, let id = captureDisplay() else { return }
        session?.cancelReview()
        SavedLayoutQuickCapture.save(model: model, editor: editor, displayID: id, replacingDraft: true)
    }
    var updateUnavailableReason: String? {
        if isApplying { return "Wait until Apply finishes." }
        if hasRecoverableRun(editor.document) { return "Finish or undo this layout’s Apply before updating it." }
        if editor.url == nil || editor.hasInvalidSource || (editor.rejectedURL != nil && editor.rejectedURL == editor.url) { return "Open a readable saved layout before updating it." }
        return canCapture ? nil : captureUnavailableReason
    }
    private func hasRecoverableRun(_ document: SavedLayoutDocument?) -> Bool {
        guard let document, session?.owner?.document == document, session?.run != nil else { return false }
        return session?.canUndo == true || document.slots.contains {
            switch session?.state(forSlot: $0.id) {
            case .failed, .needsChoice: true
            default: false
            }
        }
    }
    private func updateFileRefusal(_ url: URL) -> String? {
        guard canCapture else { return captureUnavailableReason }
        guard let document = editor.entryDocuments[url] else { return "Open a readable saved layout before updating it." }
        return hasRecoverableRun(document) ? "Finish or undo this layout’s Apply before updating it." : nil
    }
    var canUpdate: Bool { updateUnavailableReason == nil }
    private func updateFromDesktop(libraryURL: URL? = nil) {
        guard let model, let applier = model.savedLayoutApplier, let id = captureDisplay() else { return }
        do {
            let setup = try applier.captureSetup(displayID: id)
            let captured = try SavedLayoutQuickCapture.document(from: setup, existingNames: [])
            if editor.updateFromCurrentDesktop(captured, libraryURL: libraryURL) { creation.finish(); editing = false }
        } catch { editor.reportFailure("Couldn’t update: \(error.localizedDescription) Your draft was kept.") }
    }
    var deleteSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Delete this saved layout?").font(SettingsFont.headline)
            Text("Only this library file will be deleted. Exported and imported originals will be kept.")

            HStack {
                Spacer()
                Button("Cancel") { deleteConfirmation = false }.keyboardShortcut(.cancelAction)
                Button("Delete Library File", role: .destructive) { deleteSelectedLayout() }
            }
        }.font(SettingsFont.body).padding(24).frame(width: 430)
    }
    func deleteSelectedLayout() {
        guard !isApplying, editor.url != nil, editor.delete() else { return }
        session?.reset(); creation.finish(); editing = false; deleteConfirmation = false

        refreshTarget()
    }

    private var privacyDetails: some View {
        DisclosureGroup("File and privacy details") {
            VStack(alignment: .leading, spacing: 5) {
                Text("Apply and Save Current Layout work on the current desktop and need Accessibility access. Editing and export work without Accessibility access.")
                Text("Window matching remembers each saved layout’s last placed positions in a separate local cache. It contains no window identities and is not exported. Delete a layout to remove its matching hints.")
                Text("Saved locally: layout name, app bundle IDs, slot and group IDs, geometry, tab order and selection, and deliberate floats. No window titles, document paths, or native desktop identities are saved.")
                Text("Files stay until you delete them. Import opens a draft and keeps the original. Export writes only to the destination you choose. Apply runs only when you choose it, and only on the current desktop.")
                Text(editor.url?.path ?? "Unsaved draft — save before quitting BetterTile.")
                    .textSelection(.enabled)
            }.font(SettingsFont.caption).foregroundStyle(.secondary)
        }
        .font(SettingsFont.body)
    }

    /// One tab of a Tabbed pane: which tab is selected, its order, and removal.
    private func slotRow(_ id: String, group: String) -> some View {
        HStack(spacing: 6) {
            if let value = editor.document?.groups.first(where: { $0.id == group }), let index = value.slots.firstIndex(of: id) {
                Toggle(appName(id), isOn: Binding(get: { value.selected == id }, set: { if $0 { editor.selectTab(id, group: group) } }))
                    .toggleStyle(.checkbox).lineLimit(1).help("Selected tab").accessibilityLabel("Selected tab: \(appName(id))")
                Spacer(minLength: 0)
                Button { editor.moveTab(id, group: group, offset: -1) } label: { Image(systemName: "arrow.up") }
                    .disabled(index == 0).accessibilityLabel("Move \(appName(id)) earlier")
                Button { editor.moveTab(id, group: group, offset: 1) } label: { Image(systemName: "arrow.down") }
                    .disabled(index == value.slots.count - 1).accessibilityLabel("Move \(appName(id)) later")
                Button { editor.removeSlot(id) } label: { Image(systemName: "xmark") }
                    .accessibilityLabel("Remove \(appName(id)) from layout")
            }
        }
        .buttonStyle(.borderless).controlSize(.small)
        .frame(minHeight: SettingsMetrics.rowMinHeight)
    }

    private func rectangleControls(_ rectangle: SavedLayoutRectangle) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            rectangleField("X", rectangle, \.x)
            rectangleField("Y", rectangle, \.y)
            rectangleField("Width", rectangle, \.width)
            rectangleField("Height", rectangle, \.height)
        }
    }
    private func rectangleField(_ label: String, _ rectangle: SavedLayoutRectangle, _ key: WritableKeyPath<NormalizedRect, Double>) -> some View {
        SettingsRow(label) {
            TextField(label, value: Binding(get: { rectangle.rect[keyPath: key] * 100 }, set: { percent in
                var rect = rectangle.rect; rect[keyPath: key] = percent / 100
                editor.setRectangle(rectangle.slot, rect: rect)
            }), format: .number.precision(.fractionLength(0...2)))
            .textFieldStyle(.roundedBorder).accessibilityLabel("\(label) percent of work area")
            .frame(width: 80)
        }
        .padding(.horizontal, -SettingsSpacing.s3)
    }

    private func appName(_ slot: String) -> String {
        guard let preference = editor.document?.slots.first(where: { $0.id == slot })?.prefer.first else { return "Any window" }
        return SavedLayoutPreferencePresentation(preference, applications: applications, groups: appGroups).title
    }
    private func status(_ message: String, warning: Bool) -> some View {
        NoticeBanner(warning ? .warning : .info, title: message).textSelection(.enabled)
    }

    private var updateTurnsOffExtraWindows: Bool {
        let original: SavedLayoutDocument?
        if case let .updateFromFile(url) = updateAction { original = editor.entryDocuments[url] }
        else { original = editor.document }
        guard let original, let display = targetOverride?.displayID ?? target.selectionID else { return false }
        return SavedLayoutUpdateConfirmation.extraWindowsNotice(original: original, capturedMode: model?.activeMode(for: display) ?? .manual) != nil
    }

    private var updateLayoutName: String {
        if case let .updateFromFile(url) = updateAction { return editor.entryDocuments[url]?.name ?? "layout" }
        return editor.document?.name ?? "layout"
    }

    func request(_ action: SavedLayoutEditorAction) {
        switch action {
        case .updateFromDesktop:
            if let reason = updateUnavailableReason { editor.reportFailure(reason); return }
            updateAction = action; return
        case let .updateFromFile(url):
            if let reason = updateFileRefusal(url) { editor.reportFailure(reason); return }
            updateAction = action; return
        default: break
        }
        requestConfirmedUpdate(action)
    }

    func confirmUpdate() {
        guard let action = updateAction else { return }
        updateAction = nil
        requestConfirmedUpdate(action)
    }

    private func requestConfirmedUpdate(_ action: SavedLayoutEditorAction) {
        if case .updateFromDesktop = action, let reason = updateUnavailableReason { editor.reportFailure(reason); return }
        if case let .updateFromFile(url) = action, let reason = updateFileRefusal(url) { editor.reportFailure(reason); return }
        if let approved = creation.request(action, editor: editor, isApplying: isApplying) { perform(approved) }
    }
    private func confirmationText(for action: SavedLayoutEditorAction) -> String {
        switch action {
        case .mode: "Changing mode rebuilds tiled geometry. App assignments and deliberate floats are kept. Tab groups become separate windows when leaving Tabbed. The saved file stays unchanged until Save."
        case .preset: "This changes pane geometry and keeps existing panes and app assignments in order. A preset with too few panes will be rejected. The saved file stays unchanged until Save."
        case .cancelDraft: "Discarding removes this unsaved draft. Save or export it first to keep it."
        case .capture where editor.url != nil: "Discarding drops your unsaved edits and selects the capture after it is saved. The earlier saved file stays unchanged. A failed capture keeps your edits."
        default: "Continuing replaces this draft. Save or export it first to keep it. A failed import or reload keeps the last valid layout and source file."
        }
    }
    @discardableResult func adoptOutsideRun() -> Bool {
        guard let file = model?.savedLayoutActionFile, editor.url?.lastPathComponent == file,
              let document = editor.document else { return false }
        return session?.adoptRun(document: document) == true
    }
    private func resetApplyGroup() {
        guard !adoptOutsideRun() else { return }
        if model?.savedLayoutActionFile != nil { session?.cancelReview() }
        else { session?.reset() }
    }

    func perform(_ action: SavedLayoutEditorAction) {
        guard !isApplying || action.allowedDuringApply else { return }
        if case .updateFromDesktop = action, let reason = updateUnavailableReason { editor.reportFailure(reason); return }
        if case let .updateFromFile(url) = action, let reason = updateFileRefusal(url) { editor.reportFailure(reason); return }
        resetApplyGroup()
        switch action {
        case let .new(setup): creation.begin(setup, editor: editor); editing = true
        case .capture:
            let before = editor.document
            saveCurrentLayout()
            if editor.document != before { creation.finish(); editing = false }
        case .updateFromDesktop: updateFromDesktop()
        case let .updateFromFile(url):
            updateFromDesktop(libraryURL: url)
        case .cancelDraft:
            if creation.cancel(editor: editor) { editing = false }
        case let .open(url): if editor.load(url) { creation.finish(); editing = false }
        case let .reload(url): editor.reload(url)
        case let .importFile(url): if editor.beginImport(url, groups: model?.appGroupsStore) { creation.finish() }
        case let .mode(mode): editor.setMode(mode)
        case let .preset(preset): editor.setPreset(preset)
        }
    }
    private func showName(_ action: NameAction) {
        proposedName = (editor.document?.name ?? "Untitled Layout") + (action == .saveAs && editor.url != nil ? " Copy" : "")
        nameAction = action
    }
    private func nameSheet(_ action: NameAction) -> some View {
        let title = action == .saveAs && editor.url != nil ? "Duplicate" : action.rawValue
        return VStack(alignment: .leading, spacing: 14) {
            Text(title + " Layout").font(SettingsFont.headline)
            TextField("Layout name", text: $proposedName).textFieldStyle(.roundedBorder)
                .accessibilityLabel("Layout name").focused($nameFocused).onAppear { nameFocused = true }
            Text(action == .saveAs ? "Create a new local file. Existing files stay unchanged." :
                (editor.url == nil ? "The new name stays in your draft until you Save." : "Save this layout with the new name."))
                .font(SettingsFont.body).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { nameAction = nil }.keyboardShortcut(.cancelAction)
                Button(title) {
                    let succeeded: Bool
                    if action == .saveAs {
                        succeeded = editor.save(as: proposedName)
                    } else {
                        succeeded = editor.edit { $0.name = proposedName } && (editor.url == nil || editor.save())
                    }
                    if succeeded {
                        nameAction = nil
                        if action == .saveAs, creation.isDraft { creation.finish(); editing = false }
                    }
                }.keyboardShortcut(.defaultAction).disabled(proposedName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            editorMessageNotice
        }.font(SettingsFont.body).padding(20).frame(width: 420).interactiveDismissDisabled()
    }
    private func importFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false; panel.message = "Import one desktop layout. The original file will not be changed."
        if panel.runModal() == .OK, let url = panel.url { request(.importFile(url)) }
    }
    private func exportFile() { showingExport = true }
    private func chooseExportDestination() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = "layout.json"
        panel.message = "The export includes this layout and copies of the App Groups it uses."
        if panel.runModal() == .OK, let url = panel.url { editor.export(to: url, groups: appGroups) }
    }
}

struct SavedLayoutApplicationSheet: View {
    var makePicker: (Set<String>, @escaping (ApplicationChoice) -> Void) -> ApplicationPicker = {
        ApplicationPicker(exclusions: $0, onChoose: $1)
    }
    let title: String
    let onChoose: (ApplicationChoice) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            Text("Choose an app for this layout. This does not launch or move it.").font(.callout).foregroundStyle(PopupGlass.secondaryText)
            makePicker([], onChoose)
            HStack { Spacer(); Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction) }
        }.padding(20).frame(width: 430, height: 480)
    }
}

/// Tracks the page's containing window without retaining it in SwiftUI state.
struct SavedLayoutTargetWindowObserver: NSViewRepresentable {
    var onBecameKey: () -> Void

    func makeNSView(context: Context) -> Anchor { Anchor() }
    func updateNSView(_ view: Anchor, context: Context) { view.onBecameKey = onBecameKey }
    static func dismantleNSView(_ view: Anchor, coordinator: ()) { view.stopObserving() }

    final class Anchor: NSView {
        var onBecameKey: (() -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: nil)
            guard let window else { return }
            NotificationCenter.default.addObserver(self, selector: #selector(becameKey),
                name: NSWindow.didBecomeKeyNotification, object: window)
        }
        @objc private func becameKey(_ notification: Notification) { onBecameKey?() }
        func stopObserving() {
            NotificationCenter.default.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: nil)
            onBecameKey = nil
        }
    }
}

/// Retains section selection and pending edits across page value refreshes.
@Observable @MainActor final class SavedLayoutAppGroupsIntegration {
    var section: AppGroupsSectionModel?
}
