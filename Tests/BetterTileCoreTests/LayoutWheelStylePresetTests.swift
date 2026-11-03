import Foundation
import Testing
@testable import BetterTileCore

@Suite struct LayoutWheelStylePresetTests {
    typealias Liquid = LayoutWheelLiquidSettings

    @Test(arguments: LayoutWheelSurfacePreset.allCases, [false, true])
    func legacyStartsFreshWithoutChangingTheCompatibilitySnapshot(preset: LayoutWheelSurfacePreset, custom: Bool) throws {
        var original = LayoutWheelConfiguration(scale: 0.85)
        original.appearance.surfacePreset = preset
        if custom { original.appearance.surfaceStrengths = .init(liquidGlass: 0.4, light: 0.6, dark: 0.2) }
        original.innerSlots[0] = .repairBento
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        var appearance = try #require(json["appearance"] as? [String: Any])
        appearance.removeValue(forKey: "liquid")
        json["appearance"] = appearance
        let wheel = try JSONDecoder().decode(LayoutWheelConfiguration.self, from: JSONSerialization.data(withJSONObject: json))
        let expectedAppearance: Liquid.Appearance = switch preset {
        case .liquidGlass: .system
        case .light: .light
        case .dark: .dark
        }
        #expect(wheel.appearance.liquid == Liquid(appearance: expectedAppearance))
        #expect(!wheel.appearance.liquid.isModified)
        #expect(wheel.appearance.surfacePreset == preset)
        #expect(wheel.appearance.surfaceStrengths == original.appearance.surfaceStrengths)
        #expect(wheel.appearance.size == .small)
        #expect(wheel.scale == 0.85)
        #expect(wheel.innerSlots == original.innerSlots)
    }

    @Test(arguments: Liquid.Preset.allCases)
    func fullPresetBaselinesAndRoundTrip(preset: Liquid.Preset) throws {
        let value = Liquid(preset: preset)
        #expect(value.preset == preset)
        #expect(value.appearance == .system)
        #expect(value.look.names == .centre)
        #expect(!value.look.actionTint)
        #expect(value.motion.closing == .calm)
        #expect(value.motion.leanAmount == 6)
        #expect(value.feel.tension == 2.6)
        #expect(value.feel.magnetDamping == 0.58)
        #expect(value.feel.dropletResponse == 0.34)
        #expect(value.submenus == .init(arrangement: .fan, keepOpen: .always))
        let warm = preset == .warm
        #expect(value.feel.ringing == (warm ? 0.6 : 0.32))
        #expect(value.feel.bulge == (warm ? 4 : 7))
        #expect(value.feel.stretch == (warm ? 12 : 30))
        #expect(value.feel.splash == (warm ? 0.5 : 1))
        #expect(value.motion.pointerLean == warm)
        #expect(value.motion.opening == (warm ? .rise : .calm))
        #expect(value.look.material == .automatic)
        #expect(value.look.highlightColour == (warm ? .champagne : preset == .mono ? .noHighlight : preset == .frosted ? .smokeGrey : .iceBlue))
        let alpha = warm ? 0.35 : 0.3
        #expect(value.translucency == .init(light: alpha, dark: alpha))
        #expect(!value.isModified)
        #expect(try JSONDecoder().decode(Liquid.self, from: JSONEncoder().encode(value)) == value)
        let partial = try decode("{\"preset\":\"\(preset.rawValue)\",\"feel\":{},\"motion\":{},\"look\":{}}")
        #expect(partial == value)
        var config = BetterTileConfiguration()
        config.layoutWheel.appearance.liquid = value
        #expect(config.schemaVersion == 12)
        #expect(try ConfigurationStore.decode(JSONEncoder().encode(config)) == config)
    }

    @Test(arguments: Liquid.Preset.allCases)
    func everyExtraSettingMarksModifiedRoundTripsAndResets(preset: Liquid.Preset) throws {
        let changes: [(inout Liquid) -> Void] = [
            { $0.translucency.light = 0.5 }, { $0.translucency.dark = 0.7 },
            { $0.look.highlightColour = .systemAccent },
            { $0.look.names = .underIcons }, { $0.look.actionTint = true },
            { $0.motion.opening = .quick }, { $0.motion.closing = .sink },
            { $0.motion.pointerLean.toggle() }, { $0.motion.leanAmount = 12 },
            { $0.feel.tension = 4 }, { $0.feel.ringing = 0.9 }, { $0.feel.bulge = 15 },
            { $0.feel.stretch = 20 }, { $0.feel.splash = 2 },
            { $0.feel.magnetDamping = 0.9 }, { $0.feel.dropletResponse = 0.7 },
            { $0.submenus.arrangement = .cluster }, { $0.submenus.keepOpen = .withinGroupAngle },
        ]
        let baseline = Liquid(preset: preset, appearance: .dark)
        for change in changes {
            var settings = baseline
            change(&settings)
            #expect(settings.isModified)
            let data = try JSONEncoder().encode(settings)
            let saved = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(saved["modified"] == nil)
            let loaded = try JSONDecoder().decode(Liquid.self, from: data)
            #expect(loaded == settings)
            #expect(loaded.isModified)
            settings.resetToStyleDefaults()
            #expect(settings == baseline)
        }
    }

    @Test func unknownEnumsUseDefaultsForEveryFieldFamily() throws {
        let value = try decode(#"{"styleRevision":2,"preset":"future","appearance":"future","look":{"material":"future","highlightColour":"future","names":"future"},"motion":{"opening":"future","closing":"future"},"submenus":{"arrangement":"future","keepOpen":"future"}}"#)
        #expect(value == Liquid())
        #expect(try decode(#"{"styleRevision":2,"preset":"warm"}"#) == Liquid(preset: .warm))
    }

    @Test(arguments: Liquid.Preset.allCases)
    func clampsAndNonfiniteValuesUseSelectedPreset(preset: Liquid.Preset) throws {
        let baseline = Liquid(preset: preset)
        var value = baseline
        value.feel = .init(tension: .nan, ringing: .nan, bulge: .nan, stretch: .nan,
                           splash: .nan, magnetDamping: .nan, dropletResponse: .nan)
        value.motion.leanAmount = .nan
        value.translucency = .init(light: .nan, dark: .nan)
        #expect(value == baseline)
        value.feel.tension = .infinity
        value.feel.ringing = -.infinity
        #expect(value.feel.tension == 6)
        #expect(value.feel.ringing == 0.1)
        value.feel = .init(tension: -1, ringing: 3, bulge: 100, stretch: -1,
                           splash: 100, magnetDamping: 0, dropletResponse: 2)
        #expect(value.feel == .init(tension: 1, ringing: 1, bulge: 16, stretch: 0,
                                   splash: 3, magnetDamping: 0.3, dropletResponse: 0.8))
        value.translucency = .init(light: -1, dark: 2)
        value.motion.leanAmount = 100
        #expect(value.translucency == .init(light: 0, dark: 1))
        #expect(value.motion.leanAmount == 16)
        let decoded = try decode(#"{"styleRevision":2,"feel":{"tension":100,"ringing":-3},"translucency":{"light":4,"dark":-3},"motion":{"leanAmount":-1}}"#)
        #expect(decoded.feel.tension == 6)
        #expect(decoded.feel.ringing == 0.1)
        #expect(decoded.translucency == .init(light: 1, dark: 0))
        #expect(decoded.motion.leanAmount == 0)
    }

    @Test func modifiedIsDerivedAndResetKeepsIndependentPreferences() {
        var wheel = LayoutWheelConfiguration(scale: 0.85)
        wheel.isEnabled = false
        wheel.innerSlots[0] = .repairBento
        wheel.appearance.liquid = Liquid(preset: .warm, appearance: .dark)
        let before = wheel
        wheel.appearance.liquid.look.highlightColour = .systemAccent
        #expect(wheel.appearance.liquid.isModified)
        wheel.appearance.liquid.submenus.arrangement = .cluster
        wheel.appearance.liquid.motion.closing = .sink
        wheel.appearance.liquid.translucency.light = 0.8
        wheel.appearance.liquid.feel.tension = 4
        wheel.appearance.liquid.resetToStyleDefaults()
        #expect(wheel == before)
        wheel.appearance.size = .large
        #expect(!wheel.appearance.liquid.isModified)
        wheel.appearance.liquid.feel.ringing += 1e-15
        #expect(!wheel.appearance.liquid.isModified)
        wheel.appearance.liquid.selectPreset(.frosted)
        #expect(wheel.appearance.liquid == Liquid(preset: .frosted, appearance: .dark))
        #expect(wheel.appearance.size == .large)
        #expect(wheel.innerSlots == before.innerSlots)
        #expect(wheel.triggers == before.triggers)
    }

    @Test(arguments: Liquid.Appearance.allCases)
    func appearanceSelectionKeepsBothRenderersAndOlderBuildsConsistent(choice: Liquid.Appearance) throws {
        var value = LayoutWheelAppearance(surfacePreset: .dark,
            surfaceStrengths: .init(liquidGlass: 0.4, light: 0.6, dark: 0.2), size: .small,
            liquid: Liquid(preset: .warm))
        let strengths = value.surfaceStrengths
        value.selectAppearance(choice)
        let expected: LayoutWheelSurfacePreset = switch choice {
        case .system: .liquidGlass
        case .light: .light
        case .dark: .dark
        }
        #expect(value.liquid.appearance == choice)
        #expect(value.surfacePreset == expected)
        #expect(value.surfaceStrengths == strengths)
        #expect(value.liquid.preset == .warm)
        #expect(!value.liquid.isModified)
        let old = try JSONDecoder().decode(FrozenAppearance.self, from: JSONEncoder().encode(value))
        #expect(old.surfacePreset.rawValue == expected.rawValue)
        #expect(old.surfaceStrengths.liquidGlass == 0.4)
        #expect(old.surfaceStrengths.light == 0.6)
        #expect(old.surfaceStrengths.dark == 0.2)
        #expect(old.size == .small)
        // An older save omits liquid, then migration keeps Appearance and starts fresh on Ice.
        let restored = try JSONDecoder().decode(LayoutWheelAppearance.self, from: JSONEncoder().encode(old))
        #expect(restored.liquid == Liquid(appearance: choice))
        #expect(!restored.liquid.isModified)
        #expect(restored.surfaceStrengths == strengths)
        #expect(restored.size == .small)
    }

    @Test func olderAppearanceDecoderReadsNewFileAndLegacyValuesStayEncoded() throws {
        struct LegacyConfiguration: Decodable {
            var schemaVersion: Int
            var layoutWheel: LegacyWheel
        }
        struct LegacyWheel: Decodable { var scale: Double; var appearance: FrozenAppearance }
        var config = BetterTileConfiguration()
        config.layoutWheel.scale = 0.85
        config.layoutWheel.appearance.surfacePreset = .dark
        config.layoutWheel.appearance.surfaceStrengths = .init(liquidGlass: 0.4, light: 0.6, dark: 0.2)
        config.layoutWheel.appearance.liquid = Liquid(preset: .warm)
        let data = try JSONEncoder().encode(config)
        let old = try JSONDecoder().decode(LegacyConfiguration.self, from: data)
        #expect(old.schemaVersion == 12)
        #expect(old.layoutWheel.scale == 0.85)
        #expect(old.layoutWheel.appearance.surfacePreset == .dark)
        #expect(old.layoutWheel.appearance.size == .small)
        #expect(old.layoutWheel.appearance.surfaceStrengths.liquidGlass == 0.4)
        #expect(old.layoutWheel.appearance.surfaceStrengths.light == 0.6)
        #expect(old.layoutWheel.appearance.surfaceStrengths.dark == 0.2)
        // Required-key assertions catch accidental removal even when the old decoder has defaults.
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let wheel = try #require(object["layoutWheel"] as? [String: Any])
        let appearance = try #require(wheel["appearance"] as? [String: Any])
        #expect(appearance["surfacePreset"] as? String == "dark")
        #expect(appearance["size"] as? String == "small")
        #expect(appearance["surfaceStrengths"] as? [String: Double] == ["liquidGlass": 0.4, "light": 0.6, "dark": 0.2])
        #expect(try ConfigurationStore.decode(data) == config)
    }

    @Test func malformedNewShapeFallsBackWithoutDiscardingLegacyFields() throws {
        for liquid in ["[]", "42", #"{"look":{"names":false}}"#, #"{"feel":{"tension":"fast"}}"#] {
            let json = "{\"surfacePreset\":\"dark\",\"size\":\"large\",\"liquid\":\(liquid)}"
            let value = try JSONDecoder().decode(LayoutWheelAppearance.self, from: Data(json.utf8))
            #expect(value.liquid == Liquid(appearance: .dark))
            #expect(value.size == .large)
            #expect(value.surfacePreset == .dark)
        }
    }

    private func decode(_ string: String) throws -> Liquid {
        try JSONDecoder().decode(Liquid.self, from: Data(string.utf8))
    }
}
