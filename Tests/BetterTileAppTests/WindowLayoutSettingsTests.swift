import BetterTileCore
import Testing
@testable import BetterTileApp

@MainActor @Suite(.appTestApplication, .serialized)
struct WindowLayoutSettingsTests {
    @Test func entryPlacementBindingAndResetUseConfiguration() {
        let system = FakeAppWindowSystem()
        let model = makeModel(system: system)
        defer { model.shutdown() }
        let page = WindowLayoutSettings(model: model, settingsMode: .tabbed)
        #expect(page.tabbedSettingsAreAtDefault)
        let writes = system.frameWriteCounts
        for placement in TabbedEntryPlacement.allCases {
            page.tabbedEntryPlacementBinding.wrappedValue = placement
            #expect(model.configuration.tabbedEntryPlacement == placement)
            #expect(page.tabbedEntryPlacementBinding.wrappedValue == placement)
            #expect(page.tabbedSettingsAreAtDefault == (placement == .allInOnePane))
            page.resetTabbedSettings()
            #expect(model.configuration.tabbedEntryPlacement == .allInOnePane)
            #expect(page.tabbedSettingsAreAtDefault)
        }
        model.updateConfiguration {
            $0.defaultTabbedPreset = .columns
            $0.tabbedEntryPlacement = .onePerPane
            $0.tabbedStripPresentation = .autoHide
            $0.tabbedRestoresPaneSizes = false
            $0.bentoInnerGap = 9
        }
        #expect(!page.tabbedSettingsAreAtDefault)
        page.resetTabbedSettings()
        let defaults = BetterTileConfiguration()
        #expect(page.tabbedSettingsAreAtDefault)
        #expect(model.configuration.defaultTabbedPreset == defaults.defaultTabbedPreset)
        #expect(model.configuration.tabbedStripPresentation == defaults.tabbedStripPresentation)
        #expect(model.configuration.tabbedRestoresPaneSizes == defaults.tabbedRestoresPaneSizes)
        #expect(model.configuration.bentoInnerGap == 9)
        #expect(system.frameWriteCounts == writes)
    }
}
