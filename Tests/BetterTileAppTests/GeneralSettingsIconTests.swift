import AppKit
import BetterTileCore
import SwiftUI
import Testing
@testable import BetterTileApp

@MainActor @Suite(.appTestApplication) struct GeneralSettingsIconTests {
    @Test(arguments: ["dark", "unknown-future-icon"])
    func defaultsAndUnknownChoicesSelectDark(rawValue: String) {
        let picker = AppIconPicker(selectedRawValue: .constant(rawValue), finderIconUpdateFailed: .constant(false))
        #expect(picker.selected == .dark)
        let configuration = BetterTileConfiguration()
        #expect(GeneralSettings.startupIsAtDefault(configuration: configuration, iconRawValue: rawValue))
        #expect(!GeneralSettings.startupIsAtDefault(configuration: configuration, iconRawValue: "classic"))
    }

    @Test(arguments: AppIconStyle.allCases)
    func selectionKeepsChoiceOnFinderFailureAndAllowsRetry(style: AppIconStyle) {
        var rawValue = "dark"
        var failed = false
        var succeeds = false
        var choices: [AppIconStyle] = []
        let picker = AppIconPicker(
            selectedRawValue: Binding(get: { rawValue }, set: { rawValue = $0 }),
            finderIconUpdateFailed: Binding(get: { failed }, set: { failed = $0 }),
            applyAppIcon: { choices.append($0); return succeeds }
        )
        picker.select(style)
        #expect(rawValue == style.rawValue)
        #expect(picker.selected == style)
        #expect(failed)
        succeeds = true
        picker.select(style)
        #expect(choices == [style, style])
        #expect(!failed)
    }

    @Test(arguments: [false, true])
    func startupResetSelectsDarkAndPropagatesFinderResult(succeeds: Bool) {
        let model = makeModel(system: FakeAppWindowSystem())
        defer { model.shutdown() }
        model.configuration.showMenuBarIcon = false
        model.configuration.showDockIcon = true
        let original = model.configuration
        var rawValue = "classic"
        let defaults = MemoryDefaults()
        defaults.set(rawValue, forKey: AppIconStyle.defaultsKey)
        var choices: [AppIconStyle] = []
        let result = GeneralSettings.resetStartup(
            model: model, iconRawValue: Binding(get: { rawValue }, set: { rawValue = $0 }), defaults: defaults,
            applyAppIcon: { choices.append($0); return succeeds }
        )
        #expect(result == succeeds)
        #expect(rawValue == "dark")
        #expect(choices == [.dark])
        var expected = original
        expected.showMenuBarIcon = true
        expected.showDockIcon = false
        #expect(model.configuration == expected)
        #expect(GeneralSettings.startupIsAtDefault(configuration: model.configuration, iconRawValue: rawValue))
    }

    /// Without a saved icon choice the app already shows the default icon. Reset must not replace a
    /// Finder icon the user set outside BetterTile, now or at the next launch.
    @Test func startupResetWithoutASavedIconChoiceLeavesTheFinderIconAlone() {
        let model = makeModel(system: FakeAppWindowSystem())
        defer { model.shutdown() }
        model.configuration.showDockIcon = true
        let defaults = MemoryDefaults()
        var written: [String] = []
        let result = GeneralSettings.resetStartup(
            model: model, iconRawValue: Binding(get: { AppIconStyle.defaultStyle.rawValue }, set: { written.append($0) }),
            defaults: defaults,
            applyAppIcon: { _ in Issue.record("Reset must not write the Finder icon without a saved choice"); return false }
        )
        #expect(result)
        #expect(written.isEmpty)
        #expect(defaults.string(forKey: AppIconStyle.defaultsKey) == nil)
        #expect(!model.configuration.showDockIcon)
        #expect(model.configuration.showMenuBarIcon)
    }
}
