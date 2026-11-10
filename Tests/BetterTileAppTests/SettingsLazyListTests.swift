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
