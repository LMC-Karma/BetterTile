import AppKit
import BetterTileCore
import BetterTileMacOS
import SwiftUI
import Testing
@testable import BetterTileApp

@Suite(.appTestApplication, .settingsUI) @MainActor struct SavedLayoutCompactPreviewTests {
    @Test func aCompactChoiceBelongsOnlyToItsPane() {
        let slots = (0..<4).map { SavedLayoutSlot(id: "slot-\($0)", bundleID: "com.example.Editor") }
        let document = SavedLayoutDocument(name: "Two compact panes", mode: .tabbed,
            layout: .split(axis: .vertical, ratios: [0.5, 0.5], children: [.group("left"), .group("right")]),
            slots: slots, groups: [.init(id: "left", slots: ["slot-0", "slot-1"], selected: "slot-0"),
                                  .init(id: "right", slots: ["slot-2", "slot-3"], selected: "slot-2")])
        var selected: String?
        let selection = Binding<String?>(get: { selected }, set: { selected = $0 })
        func tile(_ ids: [String]) -> SavedLayoutPreviewTileContent {
            .init(document: document, slots: ids, height: 43, applications: [:],
                choice: { _, _ in AnyView(Text("Fixture choices")) }, choosingSlot: selection)
        }
        let left = tile(["slot-0", "slot-1"]).compactChoicePresentation
        let right = tile(["slot-2", "slot-3"]).compactChoicePresentation
        for id in ["slot-0", "slot-1"] {
            selected = id
            #expect(left.wrappedValue && !right.wrappedValue)
            right.wrappedValue = false
            #expect(selected == id, "An unrelated pane's dismissal must preserve this choice.")
            left.wrappedValue = false
            #expect(selected == nil)
        }
        for id in ["slot-2", "slot-3"] {
            selected = id
            #expect(right.wrappedValue && !left.wrappedValue)
            left.wrappedValue = false
            #expect(selected == id)
            right.wrappedValue = false
            #expect(selected == nil)
        }
        #expect(!left.wrappedValue && !right.wrappedValue)
    }

    @Test(arguments: [1, 2])
    func chooseWindowFitsTheCompactPaneWithoutScrolling(slotCount: Int) throws {
        let slots = (0..<slotCount).map { SavedLayoutSlot(id: "slot-\($0)", bundleID: "com.example.Editor") }
        let document = SavedLayoutDocument(name: "Compact", mode: .tabbed, layout: .group("pane"), slots: slots,
            groups: [.init(id: "pane", slots: slots.map(\.id), selected: slots[0].id)])
        let app = ApplicationChoice(bundleIdentifier: "com.example.Editor", name: "Fixture Editor", url: URL(filePath: "/fixture/Editor.app"))
        let content = SavedLayoutPreviewTileContent(document: document, slots: slots.map(\.id), height: 43,
            applications: [app.id: app], choice: { _, _ in AnyView(Text("Fixture window choices")) }, choosingSlot: .constant(nil))
        let host = NSHostingView(rootView: content.frame(width: 138))
        let intrinsic = host.fittingSize
        #expect(intrinsic.width <= 138 && intrinsic.height <= 43,
            "The compact pane is 138 × 43 pt; its action must fit without depending on nested scrolling.")
        #expect(intrinsic.height >= 24)
    }
}


extension SavedLayoutCompactPreviewTests {
    @Test(arguments: [false, true])
    func compactGrid(dark: Bool) async throws {
        let slots = (0..<7).map { SavedLayoutSlot(id: "slot-\($0)", bundleID: "com.example.Editor") }
        let groups = (0..<6).map { index in
            SavedLayoutGroup(id: "pane-\(index)", slots: index == 0 ? [slots[0].id, slots[1].id] : [slots[index + 1].id],
                selected: index == 0 ? slots[0].id : slots[index + 1].id)
        }
        let columns: [SavedLayoutNode] = (0..<2).map { column in
            .split(axis: .horizontal, ratios: [1.0/3, 1.0/3, 1.0/3],
                children: (0..<3).map { .group(groups[column * 3 + $0].id) })
        }
        let document = SavedLayoutDocument(name: "Compact grid", mode: .tabbed,
            layout: .split(axis: .vertical, ratios: [0.5, 0.5], children: columns), slots: slots, groups: groups)
        let app = ApplicationChoice(bundleIdentifier: "com.example.Editor", name: "Fixture Editor", url: URL(filePath: "/fixture/Editor.app"))
        let size = CGSize(width: 300, height: 165)
        let appearance = try #require(NSAppearance(named: dark ? .darkAqua : .aqua))
        let previous = NSApp.appearance; NSApp.appearance = appearance
        defer { NSApp.appearance = previous }
        let content = SavedLayoutPagePreview(document: document, applications: [app.id: app],
            workArea: .init(x: 0, y: 0, width: size.width, height: size.height),
            choice: { id, _ in id == "slot-0" || id == "slot-1" || id == "slot-2" ? AnyView(Text("Fixture choices")) : nil })
        let host = NSHostingView(rootView: content.frame(width: size.width, height: size.height)
            .background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, dark ? .dark : .light))
        host.frame = NSRect(origin: .zero, size: size); host.appearance = appearance
        let window = OffscreenTestWindow(contentRect: NSRect(origin: .init(x: 12000, y: 0), size: size),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.appearance = appearance; window.contentView = host
        window.orderFrontForTesting(); defer { window.close() }
        try await waitForSavedLayoutSnapshot(in: host)
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        #expect(bitmap.pixelsWide > 0 && bitmap.pixelsHigh > 0)
        if let output = ProcessInfo.processInfo.environment["BT_SNAPSHOT_DIR"] {
            try #require(bitmap.representation(using: .png, properties: [:])).write(
                to: URL(filePath: output).appendingPathComponent("saved-layout-compact-\(dark ? "dark" : "light").png"))
        }
    }
}
