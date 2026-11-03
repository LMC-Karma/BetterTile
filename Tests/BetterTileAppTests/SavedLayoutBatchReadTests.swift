import BetterTileCore
import Testing
@testable import BetterTileApp

@Test(.appTestApplication) @MainActor
func savedLayoutBatchRevalidatesOnlyParticipantsWithOneDesktopReadPerWrite() async throws {
    let h = ApplyHarness()
    defer { h.close() }
    h.addWindow()
    h.addWindow("com.apple.Safari", id: "safari", pid: 43)
    h.addWindow("com.example.Other", id: "unrelated", pid: 44, desktop: 2)
    let model = h.model()
    defer { model.shutdown() }
    let applier = try #require(model.savedLayoutApplier)
    applier.observesKeyboard = false
    let document = SavedLayoutDocument(name: "Two panes", mode: .bento,
        layout: .split(axis: .vertical, ratios: [0.5, 0.5], children: [.slot("one"), .slot("two")]),
        slots: [.init(id: "one", bundleID: "com.example.Editor"), .init(id: "two", bundleID: "com.apple.Safari")])
    var observations: [(sweeps: Int, desktops: Int, targeted: Int)] = []
    h.system.onFrameWrite = { _, _ in
        observations.append((h.system.completeSweepCount, h.system.nativeDesktopRefreshCount, h.system.cachedRefreshCount))
    }
    let result = await applier.apply(document)
    #expect(result.placed == 2)
    try #require(observations.count == 2)
    #expect(observations[1].sweeps - observations[0].sweeps == 0)
    #expect(observations[1].desktops - observations[0].desktops == 1)
    #expect(observations[1].targeted - observations[0].targeted == 1)
    #expect(h.system.cachedRefreshRequests.contains([WindowID(rawValue: "window"), WindowID(rawValue: "safari")]))
}
