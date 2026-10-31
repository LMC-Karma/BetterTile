import BetterTileCore
import Testing
@testable import BetterTileApp

@Test(.appTestApplication, arguments: [false, true]) @MainActor
func savedLayoutCancellationRestoresEveryFrameWhileItsDesktopRemainsOwned(immediate: Bool) async throws {
    let h = ApplyHarness()
    defer { h.close() }
    h.addWindow()
    h.addWindow("com.apple.Safari", id: "safari", pid: 43)
    let before = h.system.windows.map(\.frame)
    let model = h.model()
    defer { model.shutdown() }
    let applier = try #require(model.savedLayoutApplier)
    applier.observesKeyboard = false
    let document = SavedLayoutDocument(name: "Two panes", mode: .bento,
        layout: .split(axis: .vertical, ratios: [0.5, 0.5], children: [.slot("one"), .slot("two")]),
        slots: [.init(id: "one", bundleID: "com.example.Editor"), .init(id: "two", bundleID: "com.apple.Safari")])
    h.system.onFrameWrite = { _, _ in
        h.system.onFrameWrite = nil
        if immediate { applier.cancel() }
        else { Task { @MainActor in applier.cancel() } }
    }
    _ = await applier.apply(document)
    #expect(h.system.windows.map(\.frame) == before)
    #expect(h.system.frameWriteCounts.values.reduce(0, +) == (immediate ? 2 : 4))
}

@Test(.appTestApplication, arguments: [LayoutMode.bento, .tabbed]) @MainActor
func savedLayoutApplyStopsItsBatchWhenNativeOwnershipChanges(mode: LayoutMode) async throws {
    let h = ApplyHarness()
    defer { h.close() }
    h.addWindow()
    h.addWindow("com.apple.Safari", id: "safari", pid: 43)
    let model = h.model()
    defer { model.shutdown() }
    let applier = try #require(model.savedLayoutApplier)
    applier.observesKeyboard = false
    let document = SavedLayoutDocument(name: "Two panes", mode: mode,
        layout: .split(axis: .vertical, ratios: [0.5, 0.5], children:
            mode == .tabbed ? [.group("left"), .group("right")] : [.slot("one"), .slot("two")]),
        slots: [.init(id: "one", bundleID: "com.example.Editor"), .init(id: "two", bundleID: "com.apple.Safari")],
        groups: mode == .tabbed ? [.init(id: "left", slots: ["one"], selected: "one"),
            .init(id: "right", slots: ["two"], selected: "two")] : [])
    h.system.onFrameWrite = { _, _ in h.arrive(2) }
    let result = await applier.apply(document)
    #expect(result.placed == 0)
    #expect(h.system.frameWriteCounts.values.reduce(0, +) == 1)
    #expect(h.system.raiseRequests.isEmpty)
    #expect(model.statusMessage?.contains("Repair Layout") == true)
}
