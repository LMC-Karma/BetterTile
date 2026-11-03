import AppKit
import BetterTileCore
import SwiftUI
import Testing
@testable import BetterTileApp

@Suite(.appTestApplication) struct WindowLayoutChoiceTests {
    @Test(arguments: [
        (4.0, DividerWidthChoice.thin), (8, .standard), (12, .wide),
        (5, .thin), (7, .standard), (9, .standard), (11, .wide),
        (6, .standard), (10, .wide), (-10, .thin), (30, .wide),
        (-Double.infinity, .thin), (Double.infinity, .wide), (Double.nan, .standard),
    ])
    func dividerWidthUsesNearestChoice(_ value: Double, _ expected: DividerWidthChoice) {
        #expect(DividerWidthChoice.nearest(to: value) == expected)
    }

    @Test(arguments: [
        (0.0, SwapDelayChoice.instant), (0.12, .short), (0.3, .long),
        (0.02, .instant), (0.1, .short), (0.15, .short), (0.25, .long),
        (0.06, .short), (0.21, .long), (-1, .instant), (2, .long),
        (-Double.infinity, .instant), (Double.infinity, .long), (Double.nan, .short),
    ])
    func swapDelayUsesNearestChoice(_ value: Double, _ expected: SwapDelayChoice) {
        #expect(SwapDelayChoice.nearest(to: value) == expected)
    }

    @Test @MainActor func renderingLegacyValuesDoesNotRewriteConfiguration() throws {
        let model = makeModel(system: FakeAppWindowSystem())
        defer { model.shutdown() }
        model.updateConfiguration {
            $0.dividerThickness = 6
            $0.bentoSwapHoverDelay = 0.5
            $0.overlayAppearance.transparency = 0.4
        }
        let original = model.configuration
        for mode in LayoutMode.availableModes {
            let host = try SettingsSnapshotHost(WindowLayoutSettings(model: model, settingsMode: mode),
                                                dark: false, width: 770, height: 2400, fitHeight: false)
            defer { host.close() }
            let bitmap = try host.render()
            #expect(bitmap.pixelsWide > 0)
            #expect(model.configuration == original)
        }
    }
}
