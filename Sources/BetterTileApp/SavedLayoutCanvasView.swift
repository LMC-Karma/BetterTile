// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 LMC-Karma

import AppKit
import BetterTileCore
import BetterTileMacOS
import SwiftUI

/// Seeds the transient drag states so a snapshot can show them without a pointer.
struct SavedLayoutCanvasStaging {
    struct Drag {
        var bundleID: String
        /// The pointer as fractions of the canvas width and height.
        var point: CGPoint
        var plan: SavedLayoutDropPlan
    }
    var hoveredPane: String?
    var activeDivider: SavedLayoutDividerAddress?
    var snap: SavedLayoutSnap?
    var optionHeld = false
    var drag: Drag?
}

/// Escape ends a drag for good: the gesture keeps reporting movement until the pointer is released,
/// and none of it may restart the drag or commit it. The next mouse-down starts clean.
struct CanvasDragLatch {
    private(set) var cancelled = false
    mutating func cancel() { cancelled = true }
    /// False once the drag was cancelled: ignore every change until `finish`.
    var accepts: Bool { !cancelled }
    /// Call when the pointer is released. Returns true if the drag was cancelled, and resets for the next one.
    mutating func finish() -> Bool { defer { cancelled = false }; return cancelled }
}

/// ⌘Z, ⇧⌘Z and ⌃Y, read only from a focused canvas control so a text field keeps its own undo.
enum CanvasHistoryKey {
    enum Action { case undo, redo }
    static func action(modifiers: EventModifiers, characters: String) -> Action? {
        switch (modifiers, characters.lowercased()) {
        case (.command, "z"): .undo
        case ([.command, .shift], "z"), (.control, "y"): .redo
        default: nil
        }
    }
}

/// Saved Layouts names for the shared Settings tokens.
enum SavedLayoutMetrics {
    static let stageRadius = SettingsRadius.inner
    static let paneRadius = SettingsRadius.control
    static let chipRadius = SettingsRadius.mini
    static let panelRadius = SettingsRadius.panel
    static let rowHeight = SettingsSpacing.s8
    static let chipIcon = SettingsSpacing.s8 + SettingsSpacing.s2
    static let chipNameGap: CGFloat = 6
    static let rowIcon = SettingsSpacing.s6
    /// Pane size labels use the main display's work area, like the layout will.
    @MainActor static var displaySize: CGSize { NSScreen.main?.visibleFrame.size ?? CGSize(width: 1512, height: 950) }
}

/// A plan or result badge on one pane. The Apply group supplies it; the canvas only draws it.
struct SavedLayoutPaneBadge: Equatable {
    enum Tone { case ok, warning, info, neutral }
    var text: String
    var tone: Tone
    /// A short line under the app name, for example "3 windows" or "Skipped".
    var detail: String?
    /// The pane is skipped: its content is drawn faded.
    var dimmed = false
    /// The badge opens a window choice, for example "Choose window" or "Place window".
    var chooses = false
    /// Full reason for a blocked placement; the badge text names the short reason.
    var blockedReason: String? = nil
}

/// Where the palette finds apps. Tests pass fixed lists and an in-memory Recent store.
@MainActor struct SavedLayoutPaletteSource {
    var installed: @MainActor () async -> [ApplicationChoice] = { await InstalledApplicationCatalog.shared.applications() }
    var running: () -> [ApplicationChoice] = ApplicationPicker.runningApplicationChoices
    var recent: RecentApplications = .shared
    /// Eligible windows of an app on this desktop, when the app model knows them.
    var windowCount: (String) -> Int? = { _ in nil }
}

/// The interactive canvas for every Saved Layout mode: drag dividers, drag apps, split from an edge, and, in Manual,
/// select window rectangles. Below it sit the caller's accessory (the Apply group) and the app palette.
/// Every edit goes through `SavedLayoutEditor`, so it validates, records one history entry, and never touches a window.
struct SavedLayoutCanvasView: View {
    let editor: SavedLayoutEditor
    let document: SavedLayoutDocument
    var overlayAppearance = OverlayAppearance()
    var dividerThickness = 6.0
    var paletteSource = SavedLayoutPaletteSource()
    var appGroups = AppGroupsDocument()
    /// Above the stage, in its column: the title and mode rows.
    var header: AnyView?
    /// Beside the stage: proportions and pane actions.
    var side: AnyView?
    /// Placed between the canvas and the palette.
    var accessory: AnyView?
    var paneBadge: (SavedLayoutLeaf) -> SavedLayoutPaneBadge? = { _ in nil }
    /// The content of the popover a choosing badge opens.
    var badgeChooser: (SavedLayoutLeaf) -> AnyView? = { _ in nil }
    /// When set for a pane, its badge runs this on click instead of opening the chooser.
    var badgeAction: (SavedLayoutLeaf) -> (() -> Void)? = { _ in nil }
    var displaySize = CGSize(width: 1512, height: 950)
    private let interaction: CanvasInteractionSource
    private let stagedHoveredPane: String?

    private struct AppDrag {
        var item: SavedLayoutDragItem
        var bundleID: String
        var point: CGPoint
        /// Set only for staged drags: the pointer as fractions of the canvas, resolved once the canvas has a size.
        var fraction: CGPoint?
        var plan: SavedLayoutDropPlan?
        var overPalette = false
    }
    private struct ResizeDrag {
        var address: SavedLayoutDividerAddress
        var begin: SavedLayoutDivider
        var snap: SavedLayoutSnap?
        var optionHeld: Bool
        var moved: Bool
    }
    private enum Space {
        static let root = "saved-layout-canvas-root"
        static let stage = "saved-layout-canvas-stage"
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var applications: [String: ApplicationChoice] = [:]
    @State private var stageFrame = CGRect.zero
    @State private var availableWidth: CGFloat = 0
    @State private var paletteFrame = CGRect.zero
    @State private var drag: AppDrag?
    @State private var resizing: ResizeDrag?
    @State private var focusedDivider: SavedLayoutDividerAddress?
    @State private var hoveredDivider: SavedLayoutDividerAddress?
    @State private var lastTap: Date?
    @State private var lastTapAddress: SavedLayoutDividerAddress?
    @State private var showKeyboard = false
    @State private var preferenceRequest: SavedLayoutPreferenceRequest?
    @State private var session: CanvasDragSession
    @State private var ghostSize = CGSize(width: 200, height: 56)
    @State private var hoveredPane: String?
    /// False until the first lookup of the layout's apps has finished.
    @State private var resolved = false
    @State private var chooserPane: String?
    @State private var installed: [ApplicationChoice] = []
    @State private var running: [ApplicationChoice] = []
    @State private var recent: [ApplicationChoice] = []
    @State private var search = ""
    @FocusState private var focusedPane: String?
    @FocusState private var searchFocused: Bool

    init(editor: SavedLayoutEditor, document: SavedLayoutDocument, overlayAppearance: OverlayAppearance = .init(),
         dividerThickness: Double = 6, staging: SavedLayoutCanvasStaging? = nil,
         paletteSource: SavedLayoutPaletteSource = .init(), header: AnyView? = nil, side: AnyView? = nil,
         accessory: AnyView? = nil,
         paneBadge: @escaping (SavedLayoutLeaf) -> SavedLayoutPaneBadge? = { _ in nil },
         badgeChooser: @escaping (SavedLayoutLeaf) -> AnyView? = { _ in nil },
         badgeAction: @escaping (SavedLayoutLeaf) -> (() -> Void)? = { _ in nil },
         displaySize: CGSize = SavedLayoutMetrics.displaySize,
         interaction: CanvasInteractionSource = .init(), appGroups: AppGroupsDocument = .init()) {
        self.appGroups = appGroups
        self.editor = editor
        self.document = document
        self.overlayAppearance = overlayAppearance
        self.dividerThickness = dividerThickness
        self.paletteSource = paletteSource
        self.header = header
        self.side = side
        self.accessory = accessory
        self.paneBadge = paneBadge
        self.badgeChooser = badgeChooser
        self.badgeAction = badgeAction
        self.displaySize = displaySize
        self.interaction = interaction
        self.stagedHoveredPane = staging?.hoveredPane
        _session = State(initialValue: CanvasDragSession(keys: interaction.keys, now: interaction.now))
        if let staging {
            _hoveredPane = State(initialValue: staging.hoveredPane)
            if let address = staging.activeDivider, let divider = editor.divider(address) {
                _resizing = State(initialValue: .init(address: address, begin: divider, snap: staging.snap,
                                                      optionHeld: staging.optionHeld, moved: true))
            }
            if let staged = staging.drag {
                _drag = State(initialValue: .init(item: .app(bundleID: staged.bundleID), bundleID: staged.bundleID,
                                                  point: .zero, fraction: staged.point, plan: staged.plan))
            }
        }
    }

    // MARK: Derived values

    private var shown: SavedLayoutDocument { editor.displayDocument ?? document }
    private var leaves: [SavedLayoutLeaf] { shown.layout.map { SavedLayoutCanvas.leaves($0, paneGap: shown.paneGap) } ?? [] }
    private var dividers: [SavedLayoutDivider] { shown.layout.map { SavedLayoutCanvas.dividers($0, paneGap: shown.paneGap) } ?? [] }
    private var shape: SavedLayoutShape { SavedLayoutCanvas.shape(shown.layout ?? .empty) }
    private var isTabbed: Bool { shown.mode == .tabbed }
    private var selectedLeaf: SavedLayoutLeaf? {
        guard editor.selectedRectangle == nil, let id = editor.selectedPane else { return nil }
        return leaves.first { $0.id == id }
    }
    private var bundleIDs: [String] {
        var result = editor.paletteApps
        let preferredApps = shown.slots.flatMap { slot in
            slot.prefer.compactMap { preference -> String? in if case let .app(id) = preference { id } else { nil } }
        }
        for id in preferredApps where !result.contains(id) { result.append(id) }
        return result
    }

    /// Layouts store bundle IDs only. An app that does not resolve on this Mac reads "App not installed";
    /// its bundle ID stays in the tooltip.
    private func name(_ bundleID: String) -> String {
        Self.appName(bundleID, resolved: applications, palette: recent + running + installed, lookupFinished: resolved)
    }

    /// The layout's own lookup, then the palette (an app just added from it is listed there before the
    /// layout's lookup runs again), then "App not installed" once the lookup has finished.
    static func appName(_ bundleID: String, resolved: [String: ApplicationChoice], palette: [ApplicationChoice],
                        lookupFinished: Bool) -> String {
        if let app = resolved[bundleID] ?? palette.first(where: { $0.id == bundleID }) { return app.name }
        return lookupFinished ? "An app that is not installed" : ""
    }
    private func tooltip(_ bundleID: String) -> String {
        let app = applications[bundleID] ?? (recent + running + installed).first { $0.id == bundleID }
        return app?.name ?? "An app that is not installed"
    }

    private var knownApplications: [String: ApplicationChoice] {
        var result = applications
        for app in recent + running + installed { result[app.id] = app }
        return result
    }
    private func preferenceName(_ slot: SavedLayoutSlot) -> String {
        slot.prefer.first.map { SavedLayoutPreferencePresentation($0, applications: knownApplications, groups: appGroups).title } ?? "Any window"
    }
    private func openPreferences(_ id: String) { preferenceRequest = .init(slotID: id) }
    private func preferencePopover(for slots: [String]) -> some View {
        SavedLayoutPreferencePopover(request: preferenceRequest.flatMap { slots.contains($0.slotID) ? $0 : nil },
            appearance: overlayAppearance, onDismiss: { id in
                if preferenceRequest?.id == id { preferenceRequest = nil }
            }, content: { slot, dismiss in
                AnyView(SavedLayoutPanePreferences(editor: editor, slotID: slot,
                    title: shown.mode == .manual ? "Rectangle preferences" : "Pane preferences", groups: appGroups,
                    applications: knownApplications, paletteSource: paletteSource, onDone: dismiss))
            })
    }
    private func selectAndEdit(_ leaf: SavedLayoutLeaf, slot: String? = nil) {
        editor.select(path: leaf.path); focusedPane = leaf.id
        if let id = slot ?? SavedLayoutCanvas.slotIDs(in: leaf.node, document: shown).first { openPreferences(id) }
    }

    private func bundles(in leaf: SavedLayoutLeaf) -> [String] {
        SavedLayoutCanvas.slotIDs(in: leaf.node, document: shown).compactMap { id in
            guard let slot = shown.slots.first(where: { $0.id == id }), case let .app(bundle)? = slot.prefer.first else { return nil }
            return bundle
        }
    }
    private func label(for leaf: SavedLayoutLeaf) -> String {
        let ids = SavedLayoutCanvas.slotIDs(in: leaf.node, document: shown)
        guard let id = ids.first, let slot = shown.slots.first(where: { $0.id == id }) else { return "empty" }
        return preferenceName(slot) + (ids.count > 1 ? " and \(ids.count - 1) more tabs" : "")
    }
    private func pane(_ leaf: SavedLayoutLeaf) -> SavedLayoutPane { .init(path: leaf.path, node: leaf.node, rect: leaf.rect) }
    private func percent(_ value: Double) -> String { SavedLayoutEditor.percent(value) }
    /// Pane sizes include the gap, so whole percents read closer to the split shares.

    // MARK: Body

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Keep one canvas instance. Measuring duplicate ViewThatFits candidates lets the
            // unchosen candidate overwrite the visible canvas's gesture geometry.
            let columns = availableWidth >= (side == nil ? 420 : 636)
            let layout = columns ? AnyLayout(HStackLayout(alignment: .top, spacing: 16))
                : AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
            layout {
                stageColumn.frame(minWidth: columns ? 420 : nil, maxWidth: .infinity)
                if let side { side.frame(width: columns ? 200 : nil) }
            }
            if let accessory { accessory }
            palette
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { availableWidth = $0 }
        .coordinateSpace(.named(Space.root))
        // Undo and Redo reach the canvas only through the responder chain or a focused canvas control, so a text field keeps its own.
        .onCommand(Selector(("undo:"))) { editor.undo() }
        .onCommand(Selector(("redo:"))) { editor.redo() }
        .onKeyPress(characters: CharacterSet(charactersIn: "zZyY"), phases: [.down, .repeat]) { press in handleHistoryKey(press) }
        .overlay(alignment: .topLeading) { ghost }
        .task(id: bundleIDs) { await resolveApplications() }
        .task { await loadPalette() }
        .onChange(of: editor.canvasStatus) { _, status in
            if let status { AccessibilityNotification.Announcement(status.text).post() }
        }
        .onDisappear { session.finish() }
    }

    private func handleHistoryKey(_ press: KeyPress) -> KeyPress.Result {
        switch CanvasHistoryKey.action(modifiers: press.modifiers, characters: press.characters) {
        case .undo: editor.undo(); return .handled
        case .redo: editor.redo(); return .handled
        case nil: return .ignored
        }
    }

    private func resolveApplications() async {
        var resolved: [String: ApplicationChoice] = [:]
        for id in bundleIDs {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id),
               let choice = ApplicationCatalog.application(at: url) { resolved[id] = choice }
        }
        applications = resolved
        self.resolved = true
    }

    // MARK: Stage

    private var stageColumn: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let header { header }
            stage
            statusLine
        }
    }

    private var stage: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: SavedLayoutMetrics.stageRadius, style: .continuous).fill(Color.primary.opacity(0.06))
                RoundedRectangle(cornerRadius: SavedLayoutMetrics.stageRadius, style: .continuous).strokeBorder(Color(nsColor: .separatorColor))
                SavedLayoutStageAnchor(presentation: .init(
                    document: shown, selectedPane: editor.selectedPane, selectedRectangle: editor.selectedRectangle,
                    applicationsResolved: resolved, installedIDs: installed.map(\.bundleIdentifier),
                    stageFrame: stageFrame, dragPoint: drag?.point))
                    .allowsHitTesting(false)
                ForEach(Array(leaves.enumerated()), id: \.element.id) { index, leaf in
                    paneTile(leaf, index: index, size: size)
                }
                ForEach(Array(rectangles.enumerated()), id: \.element.slot) { index, rectangle in
                    rectangleTile(rectangle, index: index, size: size)
                }
                ForEach(dividers) { divider in dividerHandle(divider, size: size) }
                dropPreview(size: size)
                resizeOverlay(size: size)
            }
            .frame(width: size.width, height: size.height)
            .coordinateSpace(.named(Space.stage))
        }
        .aspectRatio(1.6, contentMode: .fit)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Space.root)) } action: { stageFrame = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Layout canvas. A relative preview of the work area.")
    }

    private var rectangles: [SavedLayoutRectangle] { shown.windows + shown.floats }

    // MARK: Panes

    private func paneTile(_ leaf: SavedLayoutLeaf, index: Int, size: CGSize) -> some View {
        let frame = CGRect(x: leaf.rect.x * size.width + 3, y: leaf.rect.y * size.height + 3,
                           width: max(1, leaf.rect.width * size.width - 6), height: max(1, leaf.rect.height * size.height - 6))
        let selected = selectedLeaf?.id == leaf.id
        let badge = paneBadge(leaf)
        let shape = RoundedRectangle(cornerRadius: SavedLayoutMetrics.paneRadius, style: .continuous)
        let spoken = "Pane \(index + 1) of \(leaves.count): \(label(for: leaf)), \(sizeLabel(leaf.rect))"
        let traits: AccessibilityTraits = selected ? [.isButton, .isSelected] : .isButton
        return paneSurface(leaf, frame: frame, selected: selected, badge: badge)
            .frame(width: frame.width, height: frame.height)
            .clipShape(shape)
            .contentShape(shape)
            .onTapGesture { selectAndEdit(leaf) }
            .background { preferencePopover(for: SavedLayoutCanvas.slotIDs(in: leaf.node, document: shown)) }
            .focusable()
            .focused($focusedPane, equals: leaf.id)
            .onKeyPress(phases: [.down, .repeat]) { press in handleKey(press, leaf: leaf) }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(badge.map { spoken + ", " + $0.text } ?? spoken)
            .accessibilityAddTraits(traits)
            .accessibilityAction { editor.select(path: selected ? nil : leaf.path) }
            .accessibilityAction(named: "Add App") { editor.select(path: leaf.path); focusPalette() }
            .accessibilityAction(named: "Split Columns") { split(leaf, .vertical) }
            .accessibilityAction(named: "Split Rows") { split(leaf, .horizontal) }
            .accessibilityAction(named: "Remove Pane") { remove(leaf) }
            .accessibilityAction(named: "Move app left") { move(leaf, .left) }
            .accessibilityAction(named: "Move app right") { move(leaf, .right) }
            .accessibilityAction(named: "Move app up") { move(leaf, .up) }
            .accessibilityAction(named: "Move app down") { move(leaf, .down) }
            .position(x: frame.midX, y: frame.midY)
    }

    @ViewBuilder private func paneSurface(_ leaf: SavedLayoutLeaf, frame: CGRect, selected: Bool,
                                          badge: SavedLayoutPaneBadge?) -> some View {
        let held = bundles(in: leaf)
        let empty = SavedLayoutCanvas.slotIDs(in: leaf.node, document: shown).isEmpty
        let tiny = frame.width < 100 || frame.height < 70, micro = frame.width < 56 || frame.height < 46
        let shape = RoundedRectangle(cornerRadius: SavedLayoutMetrics.paneRadius, style: .continuous)
        let fill: Color = empty ? .clear : Color(nsColor: .textBackgroundColor)
        let stroke: Color = selected ? .accentColor : Color(nsColor: .separatorColor)
        let style = StrokeStyle(lineWidth: selected ? 2 : 1, dash: empty ? [4, 3] : [])
        ZStack(alignment: .topLeading) {
            shape.fill(fill)
            if selected { shape.fill(Color.accentColor.opacity(empty ? 0.16 : 0.10)) }
            shape.strokeBorder(stroke, style: style)
            paneContent(leaf, held: held, selected: selected, tiny: tiny, micro: micro,
                        size: frame.size, detail: badge?.detail)
                .padding(SettingsSpacing.s2)
                .opacity(badge?.dimmed == true ? 0.45 : 1)
            if let badge, !micro {
                badgeView(badge, leaf: leaf)
                    .frame(maxWidth: .infinity, alignment: .topTrailing)
                    .padding(6)
                    // Reserve the Remove corner so a choosing badge stays clickable on hover.
                    .padding(.trailing, held.isEmpty ? 0 : SettingsSpacing.s8)
            }
            if dropHighlight(leaf) { shape.strokeBorder(Color.accentColor, lineWidth: 2) }
        }
        .overlay(alignment: .topTrailing) {
            if hoveredPane == leaf.id, let first = held.first, let slot = slot(of: first, in: leaf) {
                Button { removeFromLayout(slot, bundleID: first) } label: {
                    Image(systemName: "xmark").font(SettingsFont.caption)
                        .frame(width: SettingsSpacing.s6, height: SettingsSpacing.s6)
                        .background(SettingsColor.fillStrong, in: .settings(SettingsRadius.control))
                }
                .buttonStyle(.plain)
                .padding(SettingsSpacing.s1)
                .help("Remove from layout")
                .accessibilityLabel("Remove \(name(first)) from layout")
            }
        }
        .onHover { hovering in
            // A staged offscreen hover must not depend on the desktop pointer or tracking callbacks.
            guard stagedHoveredPane == nil else { return }
            if hovering { hoveredPane = leaf.id } else if hoveredPane == leaf.id { hoveredPane = nil }
        }
    }

    @ViewBuilder private func paneContent(_ leaf: SavedLayoutLeaf, held: [String], selected: Bool, tiny: Bool,
                                          micro: Bool, size: CGSize, detail: String?) -> some View {
        ZStack {
            let ids = SavedLayoutCanvas.slotIDs(in: leaf.node, document: shown)
            if !ids.isEmpty {
                HStack(spacing: 12) {
                    ForEach(Array(ids.prefix(isTabbed ? 3 : 1)), id: \.self) { id in
                        if let slot = shown.slots.first(where: { $0.id == id }) {
                            panePreferenceChip(leaf, slot: slot, compact: tiny || isTabbed)
                        }
                    }
                    if isTabbed, ids.count > 3 { Text("+\(ids.count - 3)").font(SettingsFont.caption) }
                }
            } else if selected, !micro {
                Button {
                    if let id = editor.preferenceSlot(in: pane(leaf)) { openPreferences(id) }
                } label: { Label("Add preference", systemImage: "plus") }
                .buttonStyle(.borderedProminent).controlSize(.small)
            } else if !micro {
                Text("Empty pane").font(SettingsFont.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottomLeading) {
            if !tiny, size.height >= 144 {
                Text(sizeLabel(leaf.rect)).font(SettingsFont.caption.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
                    .allowsHitTesting(false)
            }
        }
    }

    /// Select before presenting preferences; the transient popup never blocks another pane's click.
    private func panePreferenceChip(_ leaf: SavedLayoutLeaf, slot: SavedLayoutSlot, compact: Bool) -> some View {
        let dragIdentity: String
        if case let .app(id)? = slot.prefer.first { dragIdentity = id }
        else { dragIdentity = "org.bettertile.preference-pane" }
        return SavedLayoutPreferenceLabel(preferences: slot.prefer, applications: knownApplications,
            groups: appGroups, compact: compact)
            .contentShape(Rectangle())
            .onTapGesture { selectAndEdit(leaf, slot: slot.id) }
            .pointerStyle(.grabIdle)
            .gesture(appDragGesture(.pane(leaf.path), bundleID: dragIdentity))
    }

    @ViewBuilder private func badgeView(_ badge: SavedLayoutPaneBadge, leaf: SavedLayoutLeaf) -> some View {
        let content = SavedLayoutPaneBadgeLabel(badge: badge)
        if let action = badgeAction(leaf) {
            Button(action: action) { content }
                .buttonStyle(.plain)
                .help("Place this window in the pane")
                .accessibilityLabel("\(badge.text) for \(label(for: leaf))")
        } else if badge.chooses, let chooser = badgeChooser(leaf) {
            Button { chooserPane = leaf.id } label: { content }
                .buttonStyle(.plain)
                .popover(isPresented: Binding(get: { chooserPane == leaf.id }, set: { if !$0 { chooserPane = nil } }),
                         arrowEdge: .bottom) { chooser }
                .accessibilityLabel("\(badge.text) for \(label(for: leaf))")
        } else {
            content.help(badge.blockedReason ?? badge.text)
        }
    }

    private func slot(of bundleID: String, in leaf: SavedLayoutLeaf) -> String? {
        SavedLayoutCanvas.slotIDs(in: leaf.node, document: shown).first { id in
            shown.slots.first { $0.id == id }?.prefer.first == .app(bundleID)
        }
    }

    private func removeFromLayout(_ slot: String, bundleID: String) {
        let appName = name(bundleID)
        editor.removeSlot(slot)
        editor.say("Removed \(appName) from the layout. Undo restores it.", .good)
    }

    /// Pane size on the main display's work area, in points.
    private func sizeLabel(_ rect: NormalizedRect) -> String {
        "\(Int((rect.width * displaySize.width).rounded())) × \(Int((rect.height * displaySize.height).rounded()))"
    }

    // MARK: Manual rectangles and floats

    private func rectangleTile(_ rectangle: SavedLayoutRectangle, index: Int, size: CGSize) -> some View {
        let rect = rectangle.rect
        let frame = CGRect(x: rect.x * size.width + 1, y: rect.y * size.height + 1,
                           width: max(1, rect.width * size.width - 2), height: max(1, rect.height * size.height - 2))
        let floating = shown.floats.contains { $0.slot == rectangle.slot }
        let selected = editor.selectedRectangle == rectangle.slot
        let slot = shown.slots.first { $0.id == rectangle.slot }
        let tiny = frame.width < 100 || frame.height < 70
        let shape = RoundedRectangle(cornerRadius: SavedLayoutMetrics.paneRadius, style: .continuous)
        return Button {
            editor.selectedRectangle = rectangle.slot
            editor.selectedPane = nil
            openPreferences(rectangle.slot)
        } label: {
            ZStack(alignment: .topLeading) {
                shape.fill(selected ? Color.accentColor.opacity(0.14) : Color(nsColor: .textBackgroundColor))
                shape.strokeBorder(selected ? Color.accentColor : Color(nsColor: .separatorColor),
                                   style: StrokeStyle(lineWidth: selected ? 2 : 1, dash: floating ? [4, 3] : []))
                if let slot {
                    SavedLayoutPreferenceLabel(preferences: slot.prefer, applications: knownApplications,
                        groups: appGroups, compact: tiny)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .overlay(alignment: .topLeading) {
                            Text("Rectangle \(index + 1)").font(SettingsFont.caption).foregroundStyle(.secondary)
                        }
                        .padding(SettingsSpacing.s2)
                }

            }
            .foregroundStyle(Color.primary)
        }
        .buttonStyle(.plain)
        .frame(width: frame.width, height: frame.height)
        .background { preferencePopover(for: [rectangle.slot]) }
        // Keep the padded label from intercepting clicks outside this frame.
        .contentShape(Rectangle())
        .clipped()
        .position(x: frame.midX, y: frame.midY)
        .accessibilityLabel("\(floating ? "Floating window" : "Window") \(index + 1), \(slot.map { preferenceName($0) } ?? "Any window")")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .help(slot.map { preferenceName($0) } ?? "Any window")
    }

    private func dropHighlight(_ leaf: SavedLayoutLeaf) -> Bool {
        guard let plan = drag?.plan, plan.rejection == nil else { return false }
        return plan.target == .pane(leaf.path)
    }

    private func split(_ leaf: SavedLayoutLeaf, _ axis: SplitAxis) {
        editor.split(pane(leaf), axis: axis)
        focusedPane = editor.selectedPane
    }
    private func remove(_ leaf: SavedLayoutLeaf) {
        let index = leaves.firstIndex { $0.id == leaf.id } ?? 0
        editor.removePane(pane(leaf))
        let remaining = leaves
        if !remaining.isEmpty { focusedPane = remaining[min(index, remaining.count - 1)].id }
    }
    private func move(_ leaf: SavedLayoutLeaf, _ direction: SavedLayoutDirection) {
        guard !bundles(in: leaf).isEmpty else { editor.say("This pane has no app to move.", .bad); return }
        guard let neighbor = SavedLayoutCanvas.neighbor(of: leaf.path, direction, in: leaves) else {
            editor.say("No pane in that direction."); return
        }
        if editor.swap(leaf.path, neighbor, names: name) { focusedPane = editor.selectedPane }
    }

    private func handleKey(_ press: KeyPress, leaf: SavedLayoutLeaf) -> KeyPress.Result {
        guard !press.modifiers.contains(.command), !press.modifiers.contains(.control) else { return .ignored }
        let key = press.key
        let arrows: [KeyEquivalent: SavedLayoutDirection] = [.leftArrow: .left, .rightArrow: .right, .upArrow: .up, .downArrow: .down]
        if let direction = arrows[key] {
            if press.modifiers.contains(.option) { move(leaf, direction) }
            else if let neighbor = SavedLayoutCanvas.neighbor(of: leaf.path, direction, in: leaves) {
                focusedPane = SavedLayoutCanvas.identifier(neighbor)
            }
            return .handled
        }
        switch key {
        case .return: editor.select(path: leaf.path); focusPalette(); return .handled
        case .space: editor.select(path: selectedLeaf?.id == leaf.id ? nil : leaf.path); return .handled
        case .escape:
            guard selectedLeaf != nil else { return .ignored }
            editor.select(path: nil); return .handled
        case .delete, .deleteForward: remove(leaf); return .handled
        default: break
        }
        switch press.characters.lowercased() {
        case "c": split(leaf, .vertical); return .handled
        case "r": split(leaf, .horizontal); return .handled
        default: return .ignored
        }
    }

    // MARK: Dividers

    private func dividerHandle(_ divider: SavedLayoutDivider, size: CGSize) -> some View {
        let vertical = divider.axis == .vertical
        let address = SavedLayoutDividerAddress(path: divider.path, index: divider.index)
        let spanStart = vertical ? divider.span.y * size.height : divider.span.x * size.width
        let length = max(1, vertical ? divider.span.height * size.height : divider.span.width * size.width)
        let position = divider.position * (vertical ? size.width : size.height)
        let active = resizing?.address == address
        let lit = active || hoveredDivider == address || focusedDivider == address
        let strip = 18.0
        let first = nodeName(divider, offset: 0), second = nodeName(divider, offset: 1)
        return ZStack {
            Capsule().fill(lit ? Color.accentColor : Color.primary.opacity(0.26))
                .frame(width: vertical ? (active ? 3 : 2) : max(0, length - 8), height: vertical ? max(0, length - 8) : (active ? 3 : 2))
            DividerGrip(axis: divider.axis, length: length, thickness: dividerThickness, active: active, overlayAppearance: overlayAppearance)
        }
        .frame(width: vertical ? strip : length, height: vertical ? length : strip)
        .contentShape(Rectangle())
        .pointerStyle(vertical ? PointerStyle.columnResize : PointerStyle.rowResize)
        .onHover { hovering in
            if hovering { hoveredDivider = address } else if hoveredDivider == address { hoveredDivider = nil }
        }
        .gesture(dividerGesture(address, size: size))
        .overlay {
            CanvasDividerKeyboard(
                axis: divider.axis,
                label: "Divider between \(first) and \(second)",
                valueText: "\(first) \(percent(divider.firstShare)), \(second) \(percent(divider.secondShare))",
                minimum: divider.lower * 100, maximum: divider.upper * 100, current: divider.current * 100,
                onKey: { key in keyboardDivider(address, divider, key) },
                onStep: { step in _ = editor.nudge(address, by: Double(step) * 0.01) },
                onFocus: { focused in
                    if focused { focusedDivider = address } else if focusedDivider == address { focusedDivider = nil }
                })
            .allowsHitTesting(false)
        }
        .position(x: vertical ? position : spanStart + length / 2, y: vertical ? spanStart + length / 2 : position)
    }

    private func nodeName(_ divider: SavedLayoutDivider, offset: Int) -> String {
        guard let root = shown.layout, let split = SavedLayoutCanvas.node(at: divider.path, in: root),
              case let .split(_, _, children) = split, children.indices.contains(divider.index + offset) else { return "pane" }
        let child = children[divider.index + offset]
        let count = SavedLayoutCanvas.leaves(child).count
        if count == 1 {
            let ids = SavedLayoutCanvas.slotIDs(in: child, document: shown)
            if let id = ids.first, let slot = shown.slots.first(where: { $0.id == id }) { return preferenceName(slot) }
            return "empty pane"
        }
        return "\(count) panes"
    }

    private func keyboardDivider(_ address: SavedLayoutDividerAddress, _ divider: SavedLayoutDivider, _ key: CanvasDividerKey) -> Bool {
        switch key {
        case let .step(direction, large): _ = editor.nudge(address, by: Double(direction) * (large ? 0.05 : 0.01))
        case .minimum: _ = editor.nudge(address, by: 0, to: divider.lower)
        case .maximum: _ = editor.nudge(address, by: 0, to: divider.upper)
        case .equalize: _ = editor.equalize(address)
        }
        return true
    }

    private func dividerGesture(_ address: SavedLayoutDividerAddress, size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(Space.stage))
            .onChanged { value in
                if session.startGesture(at: value.startLocation) { resizing = nil; editor.cancelResize(announce: false) }
                guard session.accepts else { return }
                if resizing == nil {
                    guard editor.beginResize(address), let divider = editor.divider(address) else { return }
                    resizing = .init(address: address, begin: divider, snap: nil, optionHeld: false, moved: false)
                    session.begin { cancelResize() }
                    guard session.accepts else { return }
                }
                guard var state = resizing, state.address == address else { return }
                let vertical = state.begin.axis == .vertical
                let delta = vertical ? value.translation.width : value.translation.height
                if !state.moved && abs(delta) < 3 { return }
                state.moved = true
                let travel = state.begin.travel * (vertical ? size.width : size.height)
                var share = state.begin.current + delta / max(travel, 1)
                state.optionHeld = NSEvent.modifierFlags.contains(.option)
                state.snap = SavedLayoutCanvas.snap(share, for: state.begin, travelPoints: travel, enabled: !state.optionHeld)
                if let snap = state.snap { share = snap.fraction }
                editor.updateResize(share: share)
                resizing = state
            }
            .onEnded { _ in
                // An Escape seen by any source while the button was down wins over the release.
                if session.finish() { cancelResize(); return }
                guard let state = resizing, state.address == address else { return }
                resizing = nil
                if state.moved { editor.commitResize() } else {
                    editor.cancelResize(announce: false)
                    let now = interaction.now()
                    if let lastTap, lastTapAddress == address, now.timeIntervalSince(lastTap) < NSEvent.doubleClickInterval {
                        self.lastTap = nil; editor.equalize(address)
                    } else { lastTap = now; lastTapAddress = address }
                }
            }
    }

    private func cancelResize() {
        session.cancel()
        guard resizing != nil else { return }
        resizing = nil
        editor.cancelResize()
    }

    // MARK: Overlays

    @ViewBuilder private func resizeOverlay(size: CGSize) -> some View {
        if let state = resizing, state.moved, let divider = editor.divider(state.address) {
            let vertical = divider.axis == .vertical
            let spanX = divider.span.x * size.width, spanY = divider.span.y * size.height
            let spanW = divider.span.width * size.width, spanH = divider.span.height * size.height
            ZStack(alignment: .topLeading) {
                ForEach(SavedLayoutCanvas.snapPoints.filter { $0.fraction >= divider.lower - 1e-9 && $0.fraction <= divider.upper + 1e-9 }, id: \.fraction) { point in
                    tick(point, on: state.begin, active: state.snap?.fraction == point.fraction, size: size)
                }
                if state.snap != nil {
                    Rectangle().stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [5, 4]))
                        .frame(width: vertical ? 0 : spanW, height: vertical ? spanH : 0)
                        .position(x: vertical ? divider.position * size.width : spanX + spanW / 2,
                                  y: vertical ? spanY + spanH / 2 : divider.position * size.height)
                }
                resizeBubble(divider, state: state, size: size)
            }
            .allowsHitTesting(false)
        }
    }

    private func tick(_ point: SavedLayoutSnap, on divider: SavedLayoutDivider, active: Bool, size: CGSize) -> some View {
        let vertical = divider.axis == .vertical
        let along = divider.position(atShare: point.fraction) * (vertical ? size.width : size.height)
        let edgeX = divider.span.x * size.width, edgeBottom = (divider.span.y + divider.span.height) * size.height
        let long = active ? 18.0 : 12.0
        return ZStack {
            Rectangle().fill(active ? Color.accentColor : Color.secondary)
                .frame(width: vertical ? 2 : long, height: vertical ? long : 2)
            Text(point.label).font(.system(size: active ? 12 : 10, weight: .semibold))
                .foregroundStyle(active ? Color.accentColor : Color.secondary)
                .fixedSize()
                .offset(x: vertical ? 12 : long / 2 + 10, y: vertical ? -(long / 2 + 2) : -9)
        }
        .position(x: vertical ? along : edgeX + long / 2 + 3, y: vertical ? edgeBottom - long / 2 - 3 : along)
    }

    private func resizeBubble(_ divider: SavedLayoutDivider, state: ResizeDrag, size: CGSize) -> some View {
        let vertical = divider.axis == .vertical
        let along = divider.position * (vertical ? size.width : size.height)
        let x = vertical ? min(max(along, 70), size.width - 70) : divider.span.x * size.width + 78
        let y = vertical ? divider.span.y * size.height + 22 : min(max(along, 18), size.height - 18)
        return HStack(spacing: 6) {
            Text("\(percent(divider.firstShare)) | \(percent(divider.secondShare))").font(.system(size: 11, weight: .bold).monospacedDigit())
            if let snap = state.snap { Text("snapped \(snap.label)").font(SettingsFont.caption).opacity(0.85) }
            else if state.optionHeld { Text("snapping off").font(SettingsFont.caption).opacity(0.85) }
        }
        .foregroundStyle(Color(nsColor: .windowBackgroundColor))
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Color.primary, in: RoundedRectangle(cornerRadius: SettingsRadius.inner))
        .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
        .position(x: x, y: y)
    }

    @ViewBuilder private func dropPreview(size: CGSize) -> some View {
        if let drag, !drag.overPalette, let plan = drag.plan, let preview = plan.preview {
            let rejected = plan.rejection != nil
            let tint = rejected ? SettingsColor.red : Color.accentColor
            let frame = CGRect(x: preview.x * size.width, y: preview.y * size.height,
                               width: preview.width * size.width, height: preview.height * size.height)
            ZStack {
                RoundedRectangle(cornerRadius: SettingsRadius.inner).fill(tint.opacity(rejected ? 0.14 : 0.18))
                RoundedRectangle(cornerRadius: SettingsRadius.inner)
                    .strokeBorder(tint, style: StrokeStyle(lineWidth: 2, dash: plan.isCanvasEdge || rejected ? [6, 4] : []))
            }
            .frame(width: max(2, frame.width), height: max(2, frame.height))
            .position(x: frame.midX, y: frame.midY)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    /// The dragged chip and what dropping it would do. The text sits with the pointer, not over a pane,
    /// and the chip flips to the pointer's left near the canvas edge.
    @ViewBuilder private var ghost: some View {
        if let drag {
            let pointer = pointer(drag)
            let rejected = drag.plan?.rejection != nil
            let text = drag.plan?.rejection ?? drag.plan?.label
            let flips = stageFrame.minX + pointer.x + 10 + ghostSize.width > stageFrame.maxX
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    CanvasAppGlyph(url: applications[drag.bundleID]?.url, size: 22)
                    Text(name(drag.bundleID)).font(.system(size: 12))
                }
                .padding(.leading, 5).padding(.trailing, 9).padding(.vertical, 4)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: SettingsRadius.inner))
                .overlay(RoundedRectangle(cornerRadius: SavedLayoutMetrics.stageRadius).strokeBorder(rejected ? SettingsColor.red : Color.accentColor))
                if let text, !text.isEmpty {
                    Text(text)
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                        .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(rejected ? Color(nsColor: .systemRed) : Color(nsColor: .controlAccentColor), in: RoundedRectangle(cornerRadius: SettingsRadius.control))
                }
            }
            .frame(maxWidth: 220, alignment: .leading)
            .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
            .fixedSize()
            .onGeometryChange(for: CGSize.self) { $0.size } action: { ghostSize = $0 }
            .offset(x: stageFrame.minX + pointer.x + (flips ? -10 - ghostSize.width : 10), y: stageFrame.minY + pointer.y + 10)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    // MARK: App drags

    private func pointer(_ drag: AppDrag) -> CGPoint {
        drag.fraction.map { CGPoint(x: $0.x * stageFrame.width, y: $0.y * stageFrame.height) } ?? drag.point
    }

    private func appDragGesture(_ item: SavedLayoutDragItem, bundleID: String) -> some Gesture {
        DragGesture(minimumDistance: 5, coordinateSpace: .named(Space.root))
            .onChanged { value in
                if session.startGesture(at: value.startLocation) { drag = nil }
                guard session.accepts else { return }
                if drag == nil {
                    session.begin { cancelAppDrag() }
                    guard session.accepts else { return }
                }
                let rootPoint = value.location
                let point = CGPoint(x: rootPoint.x - stageFrame.minX, y: rootPoint.y - stageFrame.minY)
                var state = AppDrag(item: item, bundleID: bundleID, point: point)
                var target: SavedLayoutDropTarget?
                if case .pane = item, paletteFrame.contains(rootPoint) { target = .palette; state.overPalette = true }
                else { target = SavedLayoutCanvas.dropTarget(x: point.x, y: point.y, width: stageFrame.width, height: stageFrame.height, leaves: leaves) }
                if let target { state.plan = editor.plan(item, onto: target, names: name) }
                drag = state
            }
            .onEnded { _ in
                if session.finish() { cancelAppDrag(); return }
                guard let state = drag else { return }
                drag = nil
                guard let plan = state.plan else { editor.say("Drop on a pane, a pane edge, or the canvas edge."); return }
                if editor.apply(plan.outcome, label: plan.label) { focusedPane = editor.selectedPane }
            }
    }

    private func cancelAppDrag() {
        session.cancel()
        guard drag != nil else { return }
        drag = nil
        editor.say("Drag cancelled.")
    }

    // MARK: Status, hint, palette

    private var statusLine: some View {
        let status = editor.canvasStatus
        return HStack(alignment: .firstTextBaseline, spacing: 5) {
            if let status, status.kind != .info {
                Image(systemName: status.kind == .bad ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(status.kind == .bad ? SettingsColor.orange : SettingsColor.green).accessibilityHidden(true)
            }
            Text(status?.text ?? (shown.mode == .manual
                ? "Select a window to set its position and size. Click an app below to add one."
                : "Drag a divider to resize. Hold ⌥ for free, double-click for equal, Esc to cancel."))
                .foregroundStyle(status == nil || status?.kind == .info ? Color.secondary : Color.primary)
        }
        .font(SettingsFont.caption)
        .frame(maxWidth: .infinity, minHeight: 16, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
    }

    private var hint: some View {
        Text("Drag a divider to resize; it snaps to ½, ⅓, ⅔, ¼, ¾ (hold ⌥ to turn snapping off). Double-click a divider to equalize its two panes. "
             + "Limits: \(isTabbed ? "\(TabbedLayoutState.maximumPaneCount) panes" : "\(SavedLayoutCanvas.maximumAdaptiveApps) apps"), "
             + "\(SavedLayoutValidator.maximumNodes) panes and splits, \(SavedLayoutValidator.maximumTreeDepth) levels. "
             + "The smallest pane here is \(Int(SavedLayoutCanvas.minimumWidth * 100))% × \(Int(SavedLayoutCanvas.minimumHeight * 100))% of the work area; a real window can need more.")
            .font(SettingsFont.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private var palette: some View {
        let dropping = drag?.overPalette == true && drag?.plan?.rejection == nil
        let columns = paletteColumns
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                    TextField("Search apps", text: $search)
                        .textFieldStyle(.plain)
                        .focused($searchFocused)
                        .accessibilityLabel("Search apps")
                }
                .padding(.horizontal, 8).frame(height: 28)
                .background(Color.primary.opacity(0.06),
                            in: RoundedRectangle(cornerRadius: SavedLayoutMetrics.paneRadius, style: .continuous))
                .frame(maxWidth: 240)
                HStack(spacing: 6) {
                    Circle().fill(Color.accentColor).frame(width: 6, height: 6).accessibilityHidden(true)
                    Text(paletteHint).font(SettingsFont.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            if columns.allSatisfy({ $0.1.isEmpty }), !search.trimmingCharacters(in: .whitespaces).isEmpty {
                Text("No app named “\(search.trimmingCharacters(in: .whitespaces))”. Check the spelling.")
                    .font(SettingsFont.body).foregroundStyle(.secondary).padding(.vertical, 8)
            } else {
                HStack(alignment: .top, spacing: 16) {
                    ForEach(columns, id: \.0) { title, apps in paletteColumn(title, apps) }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SettingsColor.group,
                    in: RoundedRectangle(cornerRadius: SavedLayoutMetrics.panelRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: SavedLayoutMetrics.panelRadius, style: .continuous)
            .strokeBorder(dropping ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: dropping ? 2 : 1))
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Space.root)) } action: { paletteFrame = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Apps")
    }

    /// Recent, Running, then All Apps. All Apps leaves out the apps already in the first two columns.
    private var paletteColumns: [(String, [ApplicationChoice])] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        func matches(_ app: ApplicationChoice) -> Bool { query.isEmpty || app.name.localizedStandardContains(query) }
        func sorted(_ apps: [ApplicationChoice]) -> [ApplicationChoice] {
            apps.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
        var seen = Set<String>()
        let recentApps = recent.filter { seen.insert($0.id).inserted }.filter(matches)
        let runningApps = sorted(running.filter { seen.insert($0.id).inserted }).filter(matches)
        let allApps = sorted(installed.filter { seen.insert($0.id).inserted }).filter(matches)
        return [("Recent", recentApps), ("Running", runningApps), ("All Apps", allApps)]
    }

    private func paletteColumn(_ title: String, _ apps: [ApplicationChoice]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(title).fontWeight(.semibold)
                Text("\(apps.count)")
            }
            .font(SettingsFont.caption).foregroundStyle(.secondary).padding(.horizontal, 6).padding(.bottom, 2)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(apps) { paletteRow($0) }
                    if apps.isEmpty {
                        Text(title == "Running" ? "No running apps" : title == "Recent" ? "No recent apps" : "No matches")
                            .font(SettingsFont.caption).foregroundStyle(.secondary).padding(.horizontal, 6).padding(.vertical, 6)
                    }
                }
            }
            .frame(height: SavedLayoutMetrics.rowHeight * 5)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func paletteRow(_ app: ApplicationChoice) -> some View {
        let used = shown.slots.contains { $0.prefer.contains(.app(app.id)) }
        let count = paletteSource.windowCount(app.id)
        return HStack(spacing: 8) {
            CanvasAppGlyph(url: app.url, size: SavedLayoutMetrics.rowIcon)
            Text(app.name).font(SettingsFont.body).lineLimit(1).truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            if used {
                Image(systemName: "checkmark").font(SettingsFont.caption.weight(.semibold)).foregroundStyle(SettingsColor.green)
                    .accessibilityLabel("In this layout")
            } else if let count {
                Text(count == 0 ? "No window here" : "\(count) \(count == 1 ? "window" : "windows")")
                    .font(SettingsFont.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.horizontal, 6)
        .frame(height: SavedLayoutMetrics.rowHeight)
        .background(PaletteRowHover())
        .contentShape(Rectangle())
        .help(app.name)
        .pointerStyle(.grabIdle)
        .onTapGesture { assignFromPalette(app.id) }
        .gesture(appDragGesture(.app(bundleID: app.id), bundleID: app.id))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(app.name)
        .accessibilityHint("Adds this app to the selected pane, or to the first empty pane.")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { assignFromPalette(app.id) }
    }

    private var paletteHint: String {
        if shown.mode == .manual {
            if let id = editor.selectedRectangle, let slot = shown.slots.first(where: { $0.id == id }) {
                return "Click to replace \(preferenceName(slot)). Or drag."
            }
            return "Click an app to add a window."
        }
        guard let leaf = selectedLeaf else {
            return leaves.contains { bundles(in: $0).isEmpty } ? "Click to fill the first empty pane. Or drag." : "Select a pane, then click an app. Or drag."
        }
        let held = bundles(in: leaf)
        if shown.mode == .tabbed, !held.isEmpty { return "Click to add a tab to \(name(held[0]))’s pane. Or drag." }
        return held.isEmpty ? "Click to fill the empty pane. Or drag." : "Click to replace \(name(held[0])). Or drag."
    }

    private func focusPalette() { searchFocused = true }

    private func loadPalette() async {
        running = paletteSource.running()
        let identifiers = paletteSource.recent.bundleIdentifiers
        recent = ApplicationPickerModel.recentChoices(identifiers, known: running, lookup: { _ in nil })
        installed = await paletteSource.installed()
        recent = ApplicationPickerModel.recentChoices(identifiers, known: running + installed, lookup: { _ in nil })
    }

    private func assignFromPalette(_ bundleID: String) {
        paletteSource.recent.record(bundleID)
        if shown.mode == .manual {
            editor.assign(bundleID: bundleID, pane: nil, replacing: editor.selectedRectangle)
            return
        }
        guard let target = selectedLeaf ?? leaves.first(where: { bundles(in: $0).isEmpty }) else {
            editor.say("Every pane has an app. Select a pane to replace its app, or drag onto a pane edge.", .bad); return
        }
        editor.select(path: target.path)
        if editor.drop(.app(bundleID: bundleID), onto: .pane(target.path), names: name) { focusedPane = editor.selectedPane }
    }
}

// MARK: - Supporting views

/// An empty AppKit view that fills the stage. It draws nothing and takes no clicks; tests read its
/// frame to find the stage without depending on the Settings window's layout.
struct SavedLayoutStageAnchor: NSViewRepresentable {
    var presentation: SavedLayoutStageAnchorView.Presentation
    func makeNSView(context: Context) -> SavedLayoutStageAnchorView { SavedLayoutStageAnchorView() }
    func updateNSView(_ view: SavedLayoutStageAnchorView, context: Context) { view.presentation = presentation }
}

final class SavedLayoutStageAnchorView: NSView {
    /// The inputs applied to the hosted stage. Tests wait for this revision before using its frame.
    struct Presentation: Equatable {
        var document: SavedLayoutDocument
        var selectedPane: String?
        var selectedRectangle: String?
        var applicationsResolved: Bool
        var installedIDs: [String]
        var stageFrame: CGRect
        var dragPoint: CGPoint?
    }
    var presentation: Presentation?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }
}

/// A small picture of a layout: panes or window rectangles inside a radius-8 frame.
struct SavedLayoutThumbnail: View {
    let document: SavedLayoutDocument

    var body: some View {
        let icons = Dictionary(uniqueKeysWithValues: Set(document.slots.flatMap { $0.prefer.compactMap { preference -> String? in if case let .app(id) = preference { id } else { nil } } }).map { id in
            let icon = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
                .map { NSWorkspace.shared.icon(forFile: $0.path) }
            return (id, icon)
        })
        Canvas { context, size in
            let leaves = document.layout.map { SavedLayoutCanvas.leaves($0) } ?? []
            let panes = leaves.map { leaf in
                (leaf.rect, SavedLayoutCanvas.slotIDs(in: leaf.node, document: document).first)
            } + (document.windows + document.floats).map { ($0.rect, Optional($0.slot)) }
            for (rect, slot) in panes {
                let frame = CGRect(x: rect.x * size.width + 2, y: rect.y * size.height + 2,
                                   width: max(1, rect.width * size.width - 4), height: max(1, rect.height * size.height - 4))
                context.fill(Path(roundedRect: frame, cornerRadius: SavedLayoutMetrics.chipRadius), with: .color(.secondary.opacity(0.45)))
                if let slot, let first = document.slots.first(where: { $0.id == slot })?.prefer.first {
                    let icon: NSImage? = switch first {
                    case let .app(bundle): icons[bundle] ?? nil
                    case .group: NSImage(systemSymbolName: "square.stack.3d.up", accessibilityDescription: nil)
                    }
                    if let icon {
                    let edge = min(SettingsSpacing.s5, min(frame.width, frame.height) - SettingsSpacing.s1)
                    if edge >= SettingsSpacing.s2 {
                        context.draw(Image(nsImage: icon), in: CGRect(x: frame.midX - edge / 2, y: frame.midY - edge / 2,
                                                                     width: edge, height: edge))
                    }
                    }
                }
            }
        }
        .padding(4)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: SavedLayoutMetrics.stageRadius, style: .continuous))
        .accessibilityHidden(true)
    }
}

/// A plan or result badge: radius 4, tinted by kind.
struct SavedLayoutPaneBadgeLabel: View {
    let badge: SavedLayoutPaneBadge

    var body: some View {
        let tint: Color = switch badge.tone {
        case .ok: SettingsColor.green
        case .warning: SettingsColor.orange
        case .info: .accentColor
        case .neutral: .secondary
        }
        HStack(spacing: 3) {
            if badge.tone == .ok { Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)) }
            Text(badge.text).lineLimit(1)
            if badge.chooses { Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)) }
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(badge.tone == .neutral ? Color.secondary : tint)
        .padding(.horizontal, 6).frame(height: 20)
        .background(tint.opacity(badge.tone == .neutral ? 0.14 : 0.18),
                    in: RoundedRectangle(cornerRadius: SavedLayoutMetrics.chipRadius, style: .continuous))
        .fixedSize()
    }
}

/// The light hover fill of a palette row.
private struct PaletteRowHover: View {
    @State private var hovering = false
    var body: some View {
        RoundedRectangle(cornerRadius: SavedLayoutMetrics.paneRadius, style: .continuous)
            .fill(hovering ? AnyShapeStyle(.fill.tertiary) : AnyShapeStyle(.clear))
            .onHover { hovering = $0 }
    }
}

/// The canvas keyboard reference, shown from the Keyboard button.
struct SavedLayoutKeyboardHelp: View {
    var body: some View {
        let rows: [(String, String)] = [
            ("Tab", "Move between panes, toolbar, and dividers"),
            ("Space", "Select or deselect the focused pane"),
            ("Return", "On a pane: Add App. On a divider: equalize"),
            ("C  R", "On a pane: split into columns or rows"),
            ("Delete", "On a pane: remove it"),
            ("← ↑ → ↓", "On a pane: focus the neighbor"),
            ("⌥ + arrow", "On a pane: swap or move its app toward that neighbor"),
            ("← → or ↑ ↓", "On a divider: move 1% (columns use ←→, rows use ↑↓)"),
            ("⇧ + arrow", "On a divider: move 5%"),
            ("Home  End", "Move the divider to its limits"),
            ("⌥ drag", "Resize without snapping"),
            ("Esc", "Cancel a drag (any other key also cancels it), or deselect"),
            ("⌘Z  ⇧⌘Z", "Undo, redo"),
        ]
        VStack(alignment: .leading, spacing: 8) {
            Text("Keyboard").font(SettingsFont.headline)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 5) {
                ForEach(rows, id: \.0) { row in
                    GridRow {
                        Text(row.0).font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.primary.opacity(0.08),
                                        in: RoundedRectangle(cornerRadius: SavedLayoutMetrics.chipRadius, style: .continuous))
                        Text(row.1).font(SettingsFont.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(14).frame(width: 380)
    }
}

struct CanvasAppGlyph: View {
    let url: URL?
    let size: CGFloat

    var body: some View {
        Group {
            if let url { Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable() }
            else { Image(systemName: "app.dashed").resizable().foregroundStyle(.secondary) }
        }
        .aspectRatio(contentMode: .fit)
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Where a drag learns that a key went down while the mouse button was down.
struct CanvasKeySource {
    /// Seconds since the last key-down of any key, in any app, real or synthetic. Modifier keys
    /// (Option, Shift, Command) are flagsChanged events, not key-downs, so they never count.
    var secondsSinceKeyDown: () -> TimeInterval = { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown) }
}

/// Live defaults for canvas interaction. Offscreen pointer tests supply their own clock and key history.
struct CanvasInteractionSource {
    var keys = CanvasKeySource()
    var now: () -> Date = Date.init
}

/// One divider or app drag. A key-down after `begin` cancels it for good: the local monitor sees Escape at once
/// when this app receives it, and every pointer change and the release check the session's last key-down,
/// which no other monitor or app can hide. After a cancel, movement is ignored and the release commits nothing.
@MainActor final class CanvasDragSession {
    private var latch = CanvasDragLatch()
    private var token: Any?
    private var started: Date?
    private var gestureStart: CGPoint?
    private var onCancel: (@MainActor () -> Void)?
    private let keys: CanvasKeySource
    private let now: () -> Date

    init(keys: CanvasKeySource = .init(), now: @escaping () -> Date = Date.init) {
        self.keys = keys
        self.now = now
    }

    var accepts: Bool {
        if latch.accepts, sawKey() { cancelAndNotify() }
        return latch.accepts
    }

    func begin(onCancel: @escaping @MainActor () -> Void) {
        stop()
        started = now()
        self.onCancel = onCancel
        token = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }
            MainActor.assumeIsolated { self?.cancelAndNotify() }
            return nil
        }
    }

    /// Cancels the drag in progress. After `finish` there is none, so a late call (the view clearing its own state
    /// after a cancelled release) must not leave the latch set for the next drag.
    func cancel() { if started != nil { latch.cancel() } }

    /// Call first in every pointer change. A different start point means a new gesture: anything left by one whose
    /// release never arrived is discarded. Returns true then, so the caller can clear its own drag state too.
    func startGesture(at start: CGPoint) -> Bool {
        guard gestureStart != start else { return false }
        let stale = gestureStart != nil
        if stale { stop(); latch = CanvasDragLatch() }
        gestureStart = start
        return stale
    }

    /// Call on release. Returns true when the drag was cancelled; resets for the next drag.
    @discardableResult func finish() -> Bool {
        if latch.accepts, sawKey() { latch.cancel() }
        stop()
        gestureStart = nil
        return latch.finish()
    }

    private func sawKey() -> Bool {
        started.map { keys.secondsSinceKeyDown() < now().timeIntervalSince($0) } ?? false
    }

    private func cancelAndNotify() {
        guard latch.accepts else { return }
        latch.cancel()
        onCancel?()
    }

    private func stop() {
        if let token { NSEvent.removeMonitor(token) }
        token = nil; started = nil; onCancel = nil
    }
}

enum CanvasDividerKey: Equatable {
    case step(direction: Int, large: Bool)
    case minimum, maximum, equalize
}

/// Gives a divider the separator role (`NSAccessibility.Role.splitter`), a value, an adjustable action,
/// and keyboard control. It ignores the mouse; the SwiftUI gesture owns that.
private struct CanvasDividerKeyboard: NSViewRepresentable {
    var axis: SplitAxis
    var label: String
    var valueText: String
    var minimum: Double
    var maximum: Double
    var current: Double
    var onKey: (CanvasDividerKey) -> Bool
    var onStep: (Int) -> Void
    var onFocus: (Bool) -> Void

    func makeNSView(context: Context) -> CanvasDividerView { CanvasDividerView() }

    func updateNSView(_ view: CanvasDividerView, context: Context) {
        view.axis = axis
        view.label = label
        view.valueText = valueText
        view.minimum = minimum; view.maximum = maximum; view.current = current
        view.onKey = onKey; view.onStep = onStep; view.onFocus = onFocus
    }
}

@MainActor final class CanvasDividerView: NSView {
    var axis = SplitAxis.vertical
    var label = ""
    var valueText = ""
    var minimum = 0.0, maximum = 100.0, current = 50.0
    var onKey: (CanvasDividerKey) -> Bool = { _ in false }
    var onStep: (Int) -> Void = { _ in }
    var onFocus: (Bool) -> Void = { _ in }

    override var acceptsFirstResponder: Bool { true }
    override var focusRingMaskBounds: NSRect { bounds }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill() }

    override func becomeFirstResponder() -> Bool { onFocus(true); return super.becomeFirstResponder() }
    override func resignFirstResponder() -> Bool { onFocus(false); return super.resignFirstResponder() }

    override func keyDown(with event: NSEvent) {
        let large = event.modifierFlags.contains(.shift)
        let vertical = axis == .vertical
        let key: CanvasDividerKey? = switch event.keyCode {
        case 123 where vertical: .step(direction: -1, large: large)
        case 124 where vertical: .step(direction: 1, large: large)
        case 126 where !vertical: .step(direction: -1, large: large)
        case 125 where !vertical: .step(direction: 1, large: large)
        case 115: .minimum
        case 119: .maximum
        case 36, 76: .equalize
        default: nil
        }
        if let key, onKey(key) { return }
        super.keyDown(with: event)
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .splitter }
    override func accessibilityLabel() -> String? { label }
    override func accessibilityValue() -> Any? { current }
    override func accessibilityValueDescription() -> String? { valueText }
    override func accessibilityMinValue() -> Any? { minimum }
    override func accessibilityMaxValue() -> Any? { maximum }
    override func accessibilityOrientation() -> NSAccessibilityOrientation { axis == .vertical ? .vertical : .horizontal }
    override func accessibilityPerformIncrement() -> Bool { onStep(1); return true }
    override func accessibilityPerformDecrement() -> Bool { onStep(-1); return true }
}
