import BetterTileCore
import Testing
@testable import BetterTileApp

@Test(.appTestApplication, arguments: [LayoutMode.bento, .tabbed]) @MainActor
func cancellingTheSavedLayoutTaskRestoresFramesOnItsOwnedDesktop(mode: LayoutMode) async throws {
    let h = ApplyHarness()
    defer { h.close() }
    h.addWindow()
    h.addWindow("com.apple.Safari", id: "safari", pid: 43)
    let before = h.system.windows.map(\.frame)
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
    if mode == .tabbed {
        h.system.frameReadbackTransform = { id, requested in
            guard h.system.frameWriteCounts[id] == 1 else { return requested }
            var pending = requested
            pending.size.height -= 3
            return pending
        }
    }
    h.system.onFrameWrite = { _, _ in
        h.system.onFrameWrite = nil
        // start() owns this real task; cancel() cancels it at the settle await.
        Task { @MainActor in applier.cancel() }
    }
    applier.start(document)
    try #require(await waitFor { applier.lastRun != nil && !applier.isBusy })
    #expect(h.system.windows.map(\.frame) == before)
    #expect(h.system.frameWriteCounts.values.reduce(0, +) == 4)
    #expect(model.statusMessage?.contains("Repair Layout") != true)
    #expect(applier.lastRun?.result.issues.contains { $0.kind == .stopped } == true)
}
