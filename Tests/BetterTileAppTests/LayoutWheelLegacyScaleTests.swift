import Testing
@testable import BetterTileApp

@Suite(.appTestApplication) struct LayoutWheelLegacyScaleTests {
    @Test @MainActor func loadingSettingsPreservesLegacyScale() throws {
        let model = makeModel(system: FakeAppWindowSystem())
        defer { model.shutdown() }
        model.updateConfiguration { $0.layoutWheel.scale = 0.85 }
        let host = try SettingsSnapshotHost(LayoutWheelSettings(model: model), dark: false, width: 770)
        defer { host.close() }
        _ = try host.render()
        #expect(model.configuration.layoutWheel.scale == 0.85)
    }
}
