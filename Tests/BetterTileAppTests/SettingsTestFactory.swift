import BetterTileCore
import SwiftUI
@testable import BetterTileApp

@MainActor enum SettingsTestFactory {
    static func makeGeneralSettingsPage(
        model: BetterTileModel,
        openSetup: @escaping () -> Void,
        search: String,
        openShortcuts: @escaping () -> Void,
        openSnapZones: @escaping () -> Void,
        launchAtLogin: any LaunchAtLoginService = SystemLaunchAtLogin.shared
    ) -> GeneralSettings {
#if !DEBUG
        GeneralSettings(
            model: model,
            updatePresentation: makeUpdatePresentation(),
            automaticallyChecksForUpdates: .constant(false),
            checkForUpdates: {},
            openSetup: openSetup,
            search: search,
            openShortcuts: openShortcuts,
            openSnapZones: openSnapZones,
            launchAtLogin: launchAtLogin
        )
#else
        GeneralSettings(
            model: model,
            openSetup: openSetup,
            search: search,
            openShortcuts: openShortcuts,
            openSnapZones: openSnapZones,
            launchAtLogin: launchAtLogin
        )
#endif
    }

    static func makeSettingsView(
        model: BetterTileModel,
        openSetup: @escaping () -> Void,
        selection: SettingsDestination = .general,
        search: String = ""
    ) -> SettingsView {
#if !DEBUG
        SettingsView(
            model: model,
            updatePresentation: makeUpdatePresentation(),
            automaticallyChecksForUpdates: .constant(false),
            checkForUpdates: {},
            openSetup: openSetup,
            selection: selection,
            search: search
        )
#else
        SettingsView(model: model, openSetup: openSetup, selection: selection, search: search)
#endif
    }

#if !DEBUG
    private static func makeUpdatePresentation() -> UpdatePresentationModel {
        UpdatePresentationModel(
            defaults: MemoryDefaults(),
            runningBuildVersion: "0"
        )
    }
#endif
}
