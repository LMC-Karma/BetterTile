// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 LMC-Karma
// Contains portions adapted from Vorssaint, Copyright (C) 2026 Vorssaint.

import AppKit
import BetterTileCore
import BetterTileMacOS
import SwiftUI
import UniformTypeIdentifiers

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

/// The Menu Bar page's action catalogue: which actions each group lists for a search, and how a
/// checkbox changes the menu. The catalogue keeps group order; the menu keeps its own order.
enum MenuActionCatalogue {
    static func matches(_ action: WindowAction, in group: WindowActionGroup, search: String) -> Bool {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty || action.title.localizedStandardContains(query) || group.title.localizedStandardContains(query)
    }

    static func actions(in group: WindowActionGroup, search: String) -> [WindowAction] {
        group.actions.filter { matches($0, in: group, search: search) }
    }

    /// The groups shown for a search, in catalogue order, with no empty group.
    static func groups(search: String) -> [(group: WindowActionGroup, actions: [WindowAction])] {
        WindowActionGroup.allCases.compactMap { group in
            let actions = actions(in: group, search: search)
            return actions.isEmpty ? nil : (group, actions)
        }
    }

    /// A checked action joins the end of the menu. An unchecked action leaves it; the others keep their order.
    static func setting(_ action: WindowAction, visible: Bool, in selected: [WindowAction]) -> [WindowAction]? {
        var actions = selected
        if visible {
            guard !actions.contains(action) else { return nil }
            actions.append(action)
        } else {
            actions.removeAll { $0 == action }
        }
        return actions
    }
}

#if BETTERTILE_TEST_HOOKS
/// Tests observe which catalogue rows the lazy stack builds.
@MainActor enum MenuActionCatalogueTestHooks {
    static var rowAppeared: ((WindowAction) -> Void)?
}
#endif

private extension View {
    func catalogueRowTestHook(_ action: WindowAction) -> some View {
#if BETTERTILE_TEST_HOOKS
        onAppear { MenuActionCatalogueTestHooks.rowAppeared?(action) }
#else
        self
#endif
    }
}

struct MenuBarSettings: View {
    @Bindable var model: BetterTileModel
    @State private var search = ""

    private var selectedActions: [WindowAction] { model.configuration.menuBarActions }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SettingsSpacing.s5) {
                HStack(alignment: .top, spacing: SettingsSpacing.s6) {
                    actionCatalog
                        .frame(maxWidth: .infinity, alignment: .top)
                    editablePreview
                        .frame(width: MenuPanelMetrics.width)
                }
            }
            .padding(SettingsSpacing.s6)
        }
        .font(SettingsFont.body)
    }

    private var actionCatalog: some View {
        VStack(alignment: .leading, spacing: SettingsSpacing.s2) {
            HStack {
                Text("Available actions").font(SettingsFont.headline)
                Spacer()
                Text("\(WindowActionGroup.flattenedActions.count) actions in \(WindowActionGroup.allCases.count) groups")
                    .font(SettingsFont.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, SettingsSpacing.s1)
            HStack(spacing: SettingsSpacing.s2) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search actions", text: $search)
                    .textFieldStyle(.plain)
                    .accessibilityLabel("Search actions")
            }
            .padding(SettingsSpacing.s2)
            .background(SettingsColor.fill, in: .settings(SettingsRadius.control))

            ScrollView {
                LazyVStack(alignment: .leading, spacing: SettingsSpacing.s4) {
                    ForEach(WindowActionGroup.allCases) { group in
                        let actions = MenuActionCatalogue.actions(in: group, search: search)
                        if !actions.isEmpty {
                            SettingsGroup(group.title, aside: "\(actions.filter { selectedActions.contains($0) }.count) of \(actions.count)") {
                                ForEach(actions) { action in
                                    Toggle(isOn: actionBinding(action)) {
                                        HStack(spacing: SettingsSpacing.s2) {
                                            WindowActionGlyph(action: action)
                                            Text(action.title)
                                            Spacer(minLength: 0)
                                            ShortcutLabel(shortcut: shortcut(for: action), emptyLabel: "")
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    .toggleStyle(.checkbox)
                                    .padding(.horizontal, SettingsSpacing.s3)
                                    .frame(minHeight: SettingsMetrics.rowMinHeight)
                                    .catalogueRowTestHook(action)
                                }
                            }
                        }
                    }
                    if MenuActionCatalogue.groups(search: search).isEmpty {
                        HelpText("No actions match “\(search)”. Try a shorter word, such as “third” or “display”.")
                            .padding(.vertical, SettingsSpacing.s4)
                    }
                }
            }
            .frame(height: 600)
            // The shared footer layout: help on the left, buttons on the right.
            HStack(alignment: .top, spacing: SettingsSpacing.s2) {
                HelpText("Hiding an action keeps its shortcut and Layout Wheel assignments unchanged.")
                Button("Deselect All") { setActions([]) }
                    .disabled(selectedActions.isEmpty)
                    .fixedSize()
                Button("Reset to Default") { setActions(WindowAction.menuBarDefaultOrder) }
                    .disabled(selectedActions == WindowAction.menuBarDefaultOrder)
                    .fixedSize()
            }
            .padding(.trailing, SettingsSpacing.s1)
        }
    }

    private var editablePreview: some View {
        VStack(alignment: .leading, spacing: SettingsSpacing.s2) {
            HStack {
                Text("Your menu").font(SettingsFont.headline)
                SettingsPill("\(selectedActions.count) of \(WindowActionGroup.flattenedActions.count) in menu", tint: .accentColor)
                Spacer()
                Text("Drag tiles to arrange").font(SettingsFont.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, SettingsSpacing.s1)

            MenuPanelContent(model: model, isEditing: true) {
                actionGrid
            } notice: {
                EmptyView()
            }
            .background { GlassBacking(model.configuration.overlayAppearance) }
            .clipShape(.settings(SettingsRadius.panel))
            .overlay(RoundedRectangle.settings(SettingsRadius.panel).strokeBorder(SettingsColor.groupBorder, lineWidth: 0.5))

            HelpText("Window mode, drag snapping, Repair Layout, Settings, and Quit always stay in your menu. Move onto a neighboring tile to reorder. Hold Option and press an arrow key to move the focused tile.")
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
                guard let actions = MenuActionCatalogue.setting(action, visible: isVisible, in: selectedActions) else { return }
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
            view.layer?.cornerRadius = SettingsRadius.inner
            view.layer?.cornerCurve = .continuous
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
