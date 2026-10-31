import AppKit
import BetterTileCore
import BetterTileMacOS
import SwiftUI
import Testing
@testable import BetterTileApp

@MainActor @Suite(.appTestApplication, .settingsUI) struct LayoutWheelFineTuningTests {
    @Test func inversionsMatchBothEndsAndMidpoints() {
        let cases: [(LayoutWheelFeelControl, [Double])] = [
            (.wobbleLength, [1, 0.55, 0.1]),
            (.snapBounce, [1, 0.65, 0.3]),
            (.submenuSpeed, [0.8, 0.475, 0.15]),
            (.wobbleSpeed, [1, 3.5, 6]),
        ]
        for (control, expected) in cases {
            for (position, value) in zip([0.0, 0.5, 1], expected) {
                #expect(abs(control.physicalValue(at: position) - value) < 1e-12)
                #expect(abs(control.position(for: value) - position) < 1e-12)
            }
        }
    }

    @Test func sliderRoundTripsNeverMarkUntouchedPresetsModified() {
        for preset in LayoutWheelLiquidSettings.Preset.allCases {
            var settings = LayoutWheelLiquidSettings(preset: preset)
            let original = settings
            for control in LayoutWheelFeelControl.allCases {
                let position = control.position(for: settings[keyPath: control.keyPath])
                settings[keyPath: control.keyPath] = control.physicalValue(at: position)
                #expect(settings == original)
                #expect(!settings.isModified)
            }
        }
    }

    @Test func resetAppearanceKeepsLegacyStrengthsAndOtherWheelPreferences() {
        var wheel = LayoutWheelConfiguration(scale: 0.85)
        wheel.innerSlots[0] = .repairBento
        wheel.appearance.surfacePreset = .dark
        wheel.appearance.surfaceStrengths = .init(liquidGlass: 0.4, light: 0.6, dark: 0.2)
        let original = wheel
        wheel.appearance.liquid = .init(preset: .warm, appearance: .dark)
        wheel.appearance.size = .large
        wheel.appearance.resetLiquidAppearance()
        #expect(wheel.appearance.liquid == .init())
        #expect(wheel.appearance.size == .medium)
        #expect(wheel.appearance.surfacePreset == .liquidGlass)
        #expect(wheel.appearance.surfaceStrengths == original.appearance.surfaceStrengths)
        #expect(wheel.innerSlots == original.innerSlots)
        #expect(wheel.triggers == original.triggers)
    }

    @Test func rowAndEverySheetTabRenderAtMinimumAndWideSizesWithoutMutations() async throws {
        for dark in [false, true] {
            for (width, height) in [(980.0, 640.0), (1280.0, 800.0)] {
                let model = makeModel(system: FakeAppWindowSystem())
                defer { model.shutdown() }
                let before = model.configuration
                let appearance = Binding(get: { model.configuration.layoutWheel.appearance },
                    set: { value in model.updateConfiguration { $0.layoutWheel.appearance = value } })
                let page = try SettingsSnapshotHost(SettingsTestFactory.makeSettingsView(
                    model: model, openSetup: {}, selection: .layoutWheel), dark: dark,
                    width: width, height: height, fitHeight: false)
                defer { page.close() }
                try capture(page, name: "page-top-\(dark ? "dark" : "light")-\(Int(width))")
                if ProcessInfo.processInfo.environment["BT_WHEEL_FINE_TUNING_SNAPSHOTS"] != nil {
                    let fullPage = try SettingsSnapshotHost(SettingsTestFactory.makeSettingsView(
                    model: model, openSetup: {}, selection: .layoutWheel), dark: dark,
                        width: width, height: 2400, fitHeight: false)
                    defer { fullPage.close() }
                    try capture(fullPage, name: "page-full-\(dark ? "dark" : "light")-\(Int(width))")
                }
                let snapshots = LayoutWheelStyleSnapshots()
                let row = try SettingsSnapshotHost(
                    VStack(alignment: .leading, spacing: SettingsSpacing.s6) {
                        SettingsPageHeader(destination: .layoutWheel)
                        LayoutWheelAppearanceControls(appearance: appearance, snapshots: snapshots, openFineTuning: {})
                        Spacer(minLength: 0)
                    }.padding(SettingsSpacing.s6).frame(width: width - 210)
                        .frame(maxWidth: .infinity, alignment: .trailing),
                    dark: dark, width: width, height: height, fitHeight: false)
                defer { row.close() }
                await snapshots.load(dark: dark, size: .medium)
                await Task.yield()
                row.settle()
                try capture(row, name: "appearance-\(dark ? "dark" : "light")-\(Int(width))")
                for tab in LayoutWheelFineTuningTab.allCases {
                    let host = try SettingsSnapshotHost(
                        LayoutWheelFineTuningSheet(appearance: appearance, initialTab: tab)
                            .clipShape(.settings(SettingsRadius.panel))
                            .frame(maxWidth: .infinity, maxHeight: .infinity),
                        dark: dark, width: width, height: height, fitHeight: false)
                    defer { host.close() }
                    try capture(host, name: "sheet-\(tab.rawValue)-\(dark ? "dark" : "light")-\(Int(width))")
                    #expect(host.view.fittingSize.width <= width)
                }
                #expect(model.configuration == before)
            }
        }
    }

    @Test(arguments: [760.0, 920.0])
    func appearanceControlsRespondToOffscreenPointerInput(width: Double) async throws {
        let model = makeModel(system: FakeAppWindowSystem())
        defer { model.shutdown() }
        model.updateConfiguration {
            $0.layoutWheel.appearance.surfaceStrengths = .init(liquidGlass: 0.4, light: 0.6, dark: 0.2)
        }
        let original = model.configuration.layoutWheel
        var opened = false
        let appearance = Binding(get: { model.configuration.layoutWheel.appearance },
            set: { value in model.updateConfiguration { $0.layoutWheel.appearance = value } })
        let frames = WheelControlFrames()
        let host = try SettingsSnapshotHost(trackControls(
            LayoutWheelAppearanceControls(appearance: appearance) { opened = true }
                .padding(24).frame(maxHeight: .infinity, alignment: .top), frames: frames),
            dark: false, width: width, height: 576, fitHeight: false)
        defer { host.close() }
        // This ordered test window remains far beyond every display; no live app or input is used.
        let rightEdge = NSScreen.screens.map { $0.frame.maxX }.max() ?? 0
        host.window.setFrameOrigin(CGPoint(x: rightEdge + 10000, y: 10000))
        host.window.orderFront(nil)
        try await click(.style(.warm), frames: frames, host: host)
        try await waitForSettingsUI("Ember selection", in: host.view) {
            model.configuration.layoutWheel.appearance.liquid.preset == .warm
        }
        #expect(!model.configuration.layoutWheel.appearance.liquid.isModified)
        #expect(model.configuration.layoutWheel.appearance.surfaceStrengths == original.appearance.surfaceStrengths)
        try capture(host, name: "row-input-ember-\(Int(width))")
        for (choice, fraction) in [(LayoutWheelLiquidSettings.Appearance.light, 0.5), (.dark, 5.0 / 6),
                                   (.system, 1.0 / 6), (.dark, 5.0 / 6)] {
            let frame = try #require(frames.values[.appearance])
            try click(CGPoint(x: frame.minX + frame.width * fraction, y: frame.midY), host: host)
            try await waitForSettingsUI("Appearance \(choice.title)", in: host.view) {
                model.configuration.layoutWheel.appearance.liquid.appearance == choice
            }
            let expected: LayoutWheelSurfacePreset = switch choice {
            case .system: .liquidGlass
            case .light: .light
            case .dark: .dark
            }
            #expect(model.configuration.layoutWheel.appearance.surfacePreset == expected)
            #expect(model.configuration.layoutWheel.appearance.surfaceStrengths == original.appearance.surfaceStrengths)
            #expect(!model.configuration.layoutWheel.appearance.liquid.isModified)
        }
        try await click(.fineTuning, frames: frames, host: host)
        try await waitForSettingsUI("Fine-Tuning action", in: host.view) { opened }
        try await click(.resetAppearance, frames: frames, host: host)
        try await waitForSettingsUI("appearance reset", in: host.view) {
            model.configuration.layoutWheel.appearance.liquid.preset == .ice
        }
        #expect(model.configuration.layoutWheel.appearance.size == .medium)
        #expect(model.configuration.layoutWheel.appearance.surfacePreset == .liquidGlass)
        #expect(model.configuration.layoutWheel.appearance.liquid.appearance == .system)
        #expect(model.configuration.layoutWheel.appearance.surfaceStrengths == original.appearance.surfaceStrengths)
        #expect(model.configuration.layoutWheel.innerSlots == original.innerSlots)
        #expect(model.configuration.layoutWheel.triggers == original.triggers)
    }

    @Test func sheetMotionSwitchAndFooterResetUseTheLiveBinding() async throws {
        let model = makeModel(system: FakeAppWindowSystem())
        defer { model.shutdown() }
        model.updateConfiguration { $0.layoutWheel.appearance.liquid.appearance = .dark }
        let before = model.configuration.layoutWheel
        let appearance = Binding(get: { model.configuration.layoutWheel.appearance },
            set: { value in model.updateConfiguration { $0.layoutWheel.appearance = value } })
        let frames = WheelControlFrames()
        let host = try SettingsSnapshotHost(
            trackControls(LayoutWheelFineTuningSheet(appearance: appearance, initialTab: .motion), frames: frames),
            dark: false, width: 760, height: 576, fitHeight: false)
        defer { host.close() }
        let rightEdge = NSScreen.screens.map { $0.frame.maxX }.max() ?? 0
        host.window.setFrameOrigin(CGPoint(x: rightEdge + 10000, y: 10000))
        host.window.orderFront(nil)
        func switches(_ view: NSView) -> [NSView] {
            (String(describing: type(of: view)) == "PlatformSwitch" ? [view] : []) + view.subviews.flatMap(switches)
        }
        try await waitForSettingsUI("Pointer lean switch", in: host.view) { !switches(host.view).isEmpty }
        let toggle = try #require(switches(host.view).first)
        let frame = toggle.convert(toggle.bounds, to: host.view)
        try click(CGPoint(x: frame.midX, y: frame.midY), host: host)
        try await waitForSettingsUI("Pointer lean", in: host.view) {
            model.configuration.layoutWheel.appearance.liquid.motion.pointerLean
        }
        #expect(model.configuration.layoutWheel.appearance.liquid.isModified)
        try await click(.resetStyleDefaults, frames: frames, host: host)
        try await waitForSettingsUI("style defaults", in: host.view) {
            !model.configuration.layoutWheel.appearance.liquid.isModified
        }
        #expect(model.configuration.layoutWheel == before)
    }

    @Test(arguments: LayoutWheelFineTuningTab.allCases)
    func everyTabHasAPlayablePreviewWithoutChangingConfiguration(tab: LayoutWheelFineTuningTab) async throws {
        let model = makeModel(system: FakeAppWindowSystem())
        defer { model.shutdown() }
        let before = model.configuration
        let appearance = Binding(get: { model.configuration.layoutWheel.appearance },
            set: { value in model.updateConfiguration { $0.layoutWheel.appearance = value } })
        let frames = WheelControlFrames()
        let host = try SettingsSnapshotHost(trackControls(
            LayoutWheelFineTuningSheet(appearance: appearance, initialTab: tab), frames: frames),
            dark: false, width: 760, height: 576, fitHeight: false)
        defer { host.close() }
        host.window.setFrameOrigin(CGPoint(x: (NSScreen.screens.map { $0.frame.maxX }.max() ?? 0) + 10000, y: 10000))
        host.window.orderFront(nil)
        try await click(.playPreview, frames: frames, host: host)
        host.settle()
        #expect(model.configuration == before)
    }

    @Test func newDisplayStringsUseAmericanEnglish() {
        #expect(LayoutWheelLiquidSettings.HighlightColour.smokeGrey.title == "Mist")
        #expect(LayoutWheelLiquidSettings.Names.centre.title == "In center")
    }

    @Test func styleAndMotionTitlesAreExplicitWithoutChangingRawValues() {
        typealias Liquid = LayoutWheelLiquidSettings
        #expect(Liquid.Preset.allCases.map(\.title) == ["Ice", "Ember", "Mist", "Clear"])
        #expect(Liquid.Preset.allCases.map(\.rawValue) == ["ice", "warm", "frosted", "mono"])
        #expect(Liquid.HighlightColour.allCases.map(\.title) == ["Ice", "Ember", "Mist", "None", "Violet", "System accent"])
        #expect(Liquid.Opening.allCases.map(\.title) == ["Zoom In", "Bounce In", "Ripple In", "Fade In"])
        #expect(Liquid.Opening.allCases.map(\.rawValue) == ["calm", "rise", "bloom", "quick"])
        #expect(Liquid.Closing.allCases.map(\.title) == ["Fade Out", "Quick Fade Out", "Zoom Out"])
        #expect(Liquid.Closing.allCases.map(\.rawValue) == ["calm", "quick", "sink"])
        #expect(LayoutWheelSize.allCases.map(\.title) == ["Small", "Medium", "Large"])
        #expect(Liquid.Appearance.allCases.map(\.title) == ["System", "Light", "Dark"])
        #expect(LayoutWheelFineTuningTab.allCases.map(\.title) == ["Look", "Motion", "Feel", "Sub-menus"])
        #expect(Liquid.Preset.allCases.allSatisfy { !$0.detail.contains("\n") && $0.detail != "Preview" && $0.detail != "Approximation" })
        for term in ["Mist", "Fade", "Zoom", "Bounce", "frosted", "smoked", "calm", "child"] {
            #expect(SettingsDestination.layoutWheel.matchesSearch(term))
        }
    }

    private func trackControls(_ content: some View, frames: WheelControlFrames) -> some View {
        content.overlayPreferenceValue(LayoutWheelSettingsControlBounds.self) { anchors in
            GeometryReader { geometry in
                let resolved = anchors.mapValues { geometry[$0] }
                Color.clear.onChange(of: resolved, initial: true) { frames.values = resolved }
            }.allowsHitTesting(false)
        }
    }

    private func click(_ control: LayoutWheelSettingsControl, frames: WheelControlFrames,
                       host: SettingsSnapshotHost) async throws {
        try await waitForSettingsUI("frame for \(control)", in: host.view) {
            frames.values[control].map { !$0.isEmpty } ?? false
        }
        let frame = try #require(frames.values[control])
        try click(CGPoint(x: frame.midX, y: frame.midY), host: host)
    }

    private func click(_ point: CGPoint, host: SettingsSnapshotHost) throws {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(NSEvent.mouseEvent(with: type,
                location: host.view.convert(point, to: nil), modifierFlags: [],
                timestamp: 0, windowNumber: host.window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
            try withNativeEventLoop { host.window.sendEvent(event) }
        }
    }

    private func capture(_ host: SettingsSnapshotHost, name: String) throws {
        let bitmap = try host.render()
        #expect(bitmap.pixelsWide >= Int(host.view.frame.width))
        guard let directory = ProcessInfo.processInfo.environment["BT_WHEEL_FINE_TUNING_SNAPSHOTS"] else { return }
        let folder = URL(filePath: directory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: folder.appending(path: name + ".png"))
    }
}

@MainActor private final class WheelControlFrames {
    var values: [LayoutWheelSettingsControl: CGRect] = [:]
}
