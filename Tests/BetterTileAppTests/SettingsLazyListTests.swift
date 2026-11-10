import AppKit
import BetterTileCore
import BetterTileMacOS
import SwiftUI
import Testing
@testable import BetterTileApp

@MainActor @Suite(.appTestApplication, .settingsUI, .serialized)
struct SettingsLazyListTests {
    @Test func menuCollectionPreservesScrolledSelectionAcrossAddRemoveAndShortcutEdits() async throws {
        let all = WindowActionGroup.flattenedActions
        #expect(all.count >= 40)
        var saved = Array(all.dropLast())
        let host = NSHostingView(rootView: AnyView(MenuActionCollection(actions: saved, shortcuts: [],
            commit: { order, _ in saved = order }).frame(width: 328, height: 200)))
        host.frame = NSRect(x: 0, y: 0, width: 328, height: 200)
        let window = OffscreenTestWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.close(); window.contentView = nil }
        try await settle(host)
        let collection = try #require(find(MenuReorderCollectionView.self, in: host))
        let coordinator = try #require(collection.delegate as? MenuActionCollection.Coordinator)
        let index = 20
        let action = saved[index]
        collection.selectionIndexPaths = [IndexPath(item: index, section: 0)]
        collection.scrollToItems(at: [IndexPath(item: index, section: 0)], scrollPosition: .centeredVertically)
        try await settle(host)
        let scroll = try #require(collection.enclosingScrollView)
        let origin = scroll.contentView.bounds.origin
        func update(_ actions: [WindowAction], shortcuts: [ShortcutBinding] = []) async throws {
            saved = actions
            host.rootView = AnyView(MenuActionCollection(actions: actions, shortcuts: shortcuts,
                commit: { order, _ in saved = order }).frame(width: 328, height: 200))
            try await settle(host)
        }
        try await update(all)
        #expect(scroll.contentView.bounds.origin == origin)
        #expect(coordinator.displayed[try #require(collection.selectionIndexPaths.first).item] == action)
        try await update(Array(all.dropFirst()))
        #expect(scroll.contentView.bounds.origin == origin)
        #expect(coordinator.displayed[try #require(collection.selectionIndexPaths.first).item] == action)
        // Updating item content must use the same native collection and keep its scroll/selection.
        try await update(saved, shortcuts: BetterTileConfiguration().shortcuts)
        #expect(find(MenuReorderCollectionView.self, in: host) === collection)
        #expect(scroll.contentView.bounds.origin == origin)
        #expect(coordinator.displayed[try #require(collection.selectionIndexPaths.first).item] == action)
        coordinator.move(action, by: 1, in: collection)
        #expect(saved == coordinator.displayed)
        #expect(coordinator.displayed[try #require(collection.selectionIndexPaths.first).item] == action)
        coordinator.beginDrag(at: 0, in: collection)
        let last = try #require(collection.layoutAttributesForItem(at: IndexPath(item: saved.count - 1, section: 0))).frame
        coordinator.previewDrop(at: CGPoint(x: last.midX, y: last.midY), in: collection, finishing: true)
        coordinator.endDrag(in: collection) // Cancel uses the already existing drag path.
        #expect(coordinator.displayed == saved)
    }

    /// The catalogue lists every group in its own order, whatever order the menu has, and a search
    /// filters the lower groups too, not only the groups a lazy stack has built.
    @Test func menuCatalogueKeepsGroupOrderAndSearchesEveryGroup() throws {
        let all = MenuActionCatalogue.groups(search: "")
        #expect(all.map(\.group) == WindowActionGroup.allCases)
        #expect(all.flatMap(\.actions) == WindowActionGroup.flattenedActions)

        let lastGroup = try #require(WindowActionGroup.allCases.last)
        let lastAction = try #require(lastGroup.actions.last)
        let found = MenuActionCatalogue.groups(search: "  \(lastAction.title)  ")
        #expect(found.contains { $0.group == lastGroup && $0.actions.contains(lastAction) })
        for query in [lastAction.title, "display", "third"] {
            let shown = MenuActionCatalogue.groups(search: query)
            let expected = WindowActionGroup.allCases.flatMap { group in
                group.actions.filter { $0.title.localizedStandardContains(query) || group.title.localizedStandardContains(query) }
            }
            #expect(shown.flatMap(\.actions) == expected, "query \(query)")
            #expect(shown.allSatisfy { !$0.actions.isEmpty })
        }
        let byGroup = MenuActionCatalogue.groups(search: lastGroup.title)
        #expect(byGroup.first { $0.group == lastGroup }?.actions == lastGroup.actions)
        #expect(MenuActionCatalogue.groups(search: "unmatched-action-query").isEmpty)
    }

    /// A checkbox adds its action at the end of the menu and removes it in place. Reordering the menu
    /// changes neither the catalogue order nor which actions are checked.
    @Test func menuCatalogueSelectionKeepsTheMenuOrder() throws {
        let reordered = Array(WindowAction.menuBarDefaultOrder.reversed())
        let lower = try #require(WindowActionGroup.allCases.last?.actions.first { !reordered.contains($0) })
        let added = try #require(MenuActionCatalogue.setting(lower, visible: true, in: reordered))
        #expect(added == reordered + [lower])
        #expect(MenuActionCatalogue.setting(lower, visible: true, in: added) == nil)
        let middle = reordered[reordered.count / 2]
        let removed = try #require(MenuActionCatalogue.setting(middle, visible: false, in: added))
        #expect(removed == added.filter { $0 != middle })
        #expect(MenuActionCatalogue.groups(search: "").flatMap(\.actions) == WindowActionGroup.flattenedActions)
    }

    /// The catalogue builds rows near the viewport only. Scrolling builds the lowest group, and menu
    /// reorder and selection edits keep the catalogue's scroll position and height.
    @Test func menuCatalogueBuildsLowerGroupsWhenTheyScrollIntoView() async throws {
        var built: [WindowAction] = []
        MenuActionCatalogueTestHooks.rowAppeared = { built.append($0) }
        defer { MenuActionCatalogueTestHooks.rowAppeared = nil }
        let model = makeModel(system: FakeAppWindowSystem())
        defer { model.shutdown() }
        let host = try SettingsSnapshotHost(MenuBarSettings(model: model), dark: false, width: 1000, height: 900, fitHeight: false)
        defer { host.close() }
        let all = WindowActionGroup.flattenedActions
        let lowest = try #require(WindowActionGroup.allCases.last?.actions)
        func scrollViews(_ view: NSView) -> [NSScrollView] {
            ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap(scrollViews)
        }
        // The catalogue is the scroll view with the tallest scrolling document.
        func catalogue() -> NSScrollView? {
            scrollViews(host.view).filter { ($0.documentView?.frame.height ?? 0) > $0.frame.height }
                .max { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) }
        }
        try await waitForSettingsUI("the first catalogue rows", in: host.view) { !built.isEmpty && catalogue() != nil }
        try await settle(host.view)
        let scroll = try #require(catalogue())
        let document = try #require(scroll.documentView)
        try #require(document.isFlipped)
        let initial = Set(built)
        #expect(initial.count < all.count)
        #expect(initial == Set(all.prefix(initial.count)), "rows are built from the top")
        #expect(initial.isDisjoint(with: lowest))

        document.scroll(NSPoint(x: 0, y: document.frame.height - scroll.frame.height))
        try await waitForSettingsUI("the lowest catalogue group", in: host.view) {
            Set(built).isSuperset(of: lowest) && document.visibleRect.maxY >= document.frame.height - 1
        }
        try await settle(host.view)
        let origin = document.visibleRect.origin
        let height = document.frame.height

        let lower = try #require(lowest.first { !model.configuration.menuBarActions.contains($0) })
        let reordered = Array(model.configuration.menuBarActions.reversed())
        model.updateConfiguration { $0.menuBarActions = reordered }
        try await settle(host.view)
        model.updateConfiguration { $0.menuBarActions = MenuActionCatalogue.setting(lower, visible: true, in: $0.menuBarActions)! }
        try await settle(host.view)
        #expect(model.configuration.menuBarActions == reordered + [lower])
        #expect(document.visibleRect.origin == origin)
        #expect(document.frame.height == height)
    }

    private func settle(_ view: NSView) async throws {
        var previous: NSRect?
        try await waitForSettingsUI("stable native list geometry", in: view) {
            let stable = previous == view.bounds && view.window != nil
            previous = view.bounds
            return stable
        }
    }

    private func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let result = view as? T { return result }
        for child in view.subviews { if let result = find(type, in: child) { return result } }
        return nil
    }
}
