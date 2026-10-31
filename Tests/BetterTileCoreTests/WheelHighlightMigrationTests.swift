import Foundation
import Testing
@testable import BetterTileCore

@Suite struct WheelHighlightMigrationTests {
    typealias Liquid = LayoutWheelLiquidSettings
    // Literal full-baseline and edited JSON from the encoding before the style marker.
    private let fixtures: [String: String] = [
        "ice": #"{"preset":"ice","appearance":"dark","translucency":{"light":0.3,"dark":0.3},"look":{"material":"automatic","highlightColour":"iceBlue","names":"centre","actionTint":false},"motion":{"opening":"calm","closing":"calm","pointerLean":false,"leanAmount":6},"feel":{"tension":2.6,"ringing":0.32,"bulge":7,"stretch":30,"splash":1,"magnetDamping":0.58,"dropletResponse":0.34},"submenus":{"arrangement":"fan","keepOpen":"keep"}}"#,
        "ice-edited": #"{"preset":"ice","appearance":"dark","translucency":{"light":0.3,"dark":0.3},"look":{"material":"automatic","highlightColour":"iceBlue","names":"centre","actionTint":false},"motion":{"opening":"calm","closing":"calm","pointerLean":false,"leanAmount":6},"feel":{"tension":4.9,"ringing":0.32,"bulge":7,"stretch":30,"splash":1,"magnetDamping":0.58,"dropletResponse":0.34},"submenus":{"arrangement":"fan","keepOpen":"keep"}}"#,
        "warm": #"{"preset":"warm","appearance":"dark","translucency":{"light":0.35,"dark":0.35},"look":{"material":"automatic","highlightColour":"champagne","names":"centre","actionTint":false},"motion":{"opening":"rise","closing":"calm","pointerLean":true,"leanAmount":6},"feel":{"tension":2.6,"ringing":0.6,"bulge":4,"stretch":12,"splash":0.5,"magnetDamping":0.58,"dropletResponse":0.34},"submenus":{"arrangement":"fan","keepOpen":"keep"}}"#,
        "warm-edited": #"{"preset":"warm","appearance":"dark","translucency":{"light":0.35,"dark":0.35},"look":{"material":"automatic","highlightColour":"champagne","names":"centre","actionTint":false},"motion":{"opening":"rise","closing":"calm","pointerLean":true,"leanAmount":6},"feel":{"tension":4.9,"ringing":0.6,"bulge":4,"stretch":12,"splash":0.5,"magnetDamping":0.58,"dropletResponse":0.34},"submenus":{"arrangement":"fan","keepOpen":"keep"}}"#,
        "mono": #"{"preset":"mono","appearance":"dark","translucency":{"light":0.2,"dark":0.2},"look":{"material":"smoked","highlightColour":"smokeGrey","names":"centre","actionTint":false},"motion":{"opening":"calm","closing":"calm","pointerLean":false,"leanAmount":6},"feel":{"tension":2.6,"ringing":0.32,"bulge":7,"stretch":30,"splash":1,"magnetDamping":0.58,"dropletResponse":0.34},"submenus":{"arrangement":"fan","keepOpen":"keep"}}"#,
        "mono-edited": #"{"preset":"mono","appearance":"dark","translucency":{"light":0.2,"dark":0.2},"look":{"material":"smoked","highlightColour":"smokeGrey","names":"centre","actionTint":false},"motion":{"opening":"calm","closing":"calm","pointerLean":false,"leanAmount":6},"feel":{"tension":4.9,"ringing":0.32,"bulge":7,"stretch":30,"splash":1,"magnetDamping":0.58,"dropletResponse":0.34},"submenus":{"arrangement":"fan","keepOpen":"keep"}}"#,
        "frosted": #"{"preset":"frosted","appearance":"dark","translucency":{"light":0.85,"dark":0.85},"look":{"material":"frosted","highlightColour":"iceBlue","names":"centre","actionTint":false},"motion":{"opening":"bloom","closing":"calm","pointerLean":false,"leanAmount":6},"feel":{"tension":2.6,"ringing":0.32,"bulge":7,"stretch":30,"splash":1,"magnetDamping":0.58,"dropletResponse":0.34},"submenus":{"arrangement":"fan","keepOpen":"keep"}}"#,
        "frosted-edited": #"{"preset":"frosted","appearance":"dark","translucency":{"light":0.85,"dark":0.85},"look":{"material":"frosted","highlightColour":"iceBlue","names":"centre","actionTint":false},"motion":{"opening":"bloom","closing":"calm","pointerLean":false,"leanAmount":6},"feel":{"tension":4.9,"ringing":0.32,"bulge":7,"stretch":30,"splash":1,"magnetDamping":0.58,"dropletResponse":0.34},"submenus":{"arrangement":"fan","keepOpen":"keep"}}"#,
    ]

    @Test(arguments: Liquid.Preset.allCases)
    func markerlessStylesResetTuningOnce(preset: Liquid.Preset) throws {
        for suffix in ["", "-edited"] {
            let json = try #require(fixtures[preset.rawValue + suffix])
            let old = try JSONDecoder().decode(FrozenMarkerlessLiquidSettings.self, from: Data(json.utf8))
            #expect(old.isModified == !suffix.isEmpty)
            var value = try JSONDecoder().decode(Liquid.self, from: Data(json.utf8))
            #expect(value == Liquid(preset: preset, appearance: .dark))
            #expect(!value.isModified)
            value.feel.tension = 4.9
            value.look.highlightColour = .violet
            let saved = try JSONEncoder().encode(value)
            #expect(try JSONDecoder().decode(Liquid.self, from: saved) == value)
            // A pre-marker build drops the marker on save: one more reset, then stable again.
            let downgraded = try JSONEncoder().encode(JSONDecoder().decode(FrozenMarkerlessLiquidSettings.self, from: saved))
            var restored = try JSONDecoder().decode(Liquid.self, from: downgraded)
            #expect(restored == Liquid(preset: preset, appearance: .dark))
            restored.feel.stretch = 17
            #expect(try JSONDecoder().decode(Liquid.self, from: JSONEncoder().encode(restored)) == restored)
        }
    }

    @Test(arguments: ["null", "1", "2.5", "-1", "\"future\"", "true", "{}", "[]"])
    func invalidOrOldStyleRevisionsUseTheSelectedDefaults(revision: String) throws {
        let json = "{\"styleRevision\":\(revision),\"preset\":\"warm\",\"appearance\":\"dark\",\"feel\":{\"tension\":4.9}}"
        #expect(try JSONDecoder().decode(Liquid.self, from: Data(json.utf8)) == Liquid(preset: .warm, appearance: .dark))
    }

    @Test(arguments: [2, 3, 999])
    func currentAndFutureRevisionsKeepEdits(revision: Int) throws {
        let json = "{\"styleRevision\":\(revision),\"preset\":\"mono\",\"appearance\":\"dark\",\"feel\":{\"tension\":4.9}}"
        let value = try JSONDecoder().decode(Liquid.self, from: Data(json.utf8))
        #expect(value.feel.tension == 4.9 && value.isModified)
        #expect(try JSONDecoder().decode(Liquid.self, from: JSONEncoder().encode(value)) == value)
    }

    @Test func resetLeavesEveryIndependentConfigurationFieldAlone() throws {
        var expected = BetterTileConfiguration()
        expected.layoutWheel.appearance.liquid = .init(preset: .mono, appearance: .dark)
        expected.layoutWheel.appearance.size = .large
        expected.layoutWheel.appearance.surfacePreset = .dark
        expected.layoutWheel.appearance.surfaceStrengths = .init(liquidGlass: 0.4, light: 0.6, dark: 0.2)
        expected.layoutWheel.innerSlots[0] = .repairBento
        expected.layoutWheel.triggers.mouse = .optionMiddleClick
        var edited = expected
        edited.layoutWheel.appearance.liquid.feel.tension = 4.9
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(edited)) as? [String: Any])
        var wheel = try #require(json["layoutWheel"] as? [String: Any])
        var appearance = try #require(wheel["appearance"] as? [String: Any])
        var liquid = try #require(appearance["liquid"] as? [String: Any])
        liquid.removeValue(forKey: "styleRevision")
        appearance["liquid"] = liquid; wheel["appearance"] = appearance; json["layoutWheel"] = wheel
        let loaded = try ConfigurationStore.decode(JSONSerialization.data(withJSONObject: json))
        #expect(loaded == expected)
        #expect(loaded.schemaVersion == 12)
    }

    @Test(arguments: ["automatic", "frosted", "smoked", "clear", "future"])
    func retiredMaterialDecodesAndDoesNotMarkModified(material: String) throws {
        let json = "{\"styleRevision\":2,\"look\":{\"material\":\"\(material)\"}}"
        let value = try JSONDecoder().decode(Liquid.self, from: Data(json.utf8))
        #expect(!value.isModified)
        #expect(value.look.material.rawValue == (material == "future" ? "automatic" : material))
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as! [String: Any]
        #expect((encoded["look"] as? [String: Any])?["material"] as? String == value.look.material.rawValue)
    }

    @Test(arguments: Liquid.Preset.allCases)
    func olderBuildReadsNewFilesAndNoneFallsBackWithoutThrowing(preset: Liquid.Preset) throws {
        let value = Liquid(preset: preset)
        let frozen = try JSONDecoder().decode(FrozenMarkerlessLiquidSettings.self, from: JSONEncoder().encode(value))
        #expect(frozen.preset.rawValue == preset.rawValue)
        #expect(frozen.translucency.light == value.translucency.light)
        #expect(frozen.motion.opening.rawValue == value.motion.opening.rawValue)
        #expect(frozen.look.highlightColour.rawValue == (preset == .mono ? "iceBlue" : value.look.highlightColour.rawValue))
        #expect(Liquid.HighlightColour.noHighlight.rawValue == "none")
        let savedNone = try JSONDecoder().decode(Liquid.HighlightColour.self, from: Data(#""none""#.utf8))
        #expect(savedNone == .noHighlight)
        var ice = Liquid()
        ice.look.highlightColour = .noHighlight
        #expect(ice.isModified)
        #expect(try JSONDecoder().decode(Liquid.self, from: JSONEncoder().encode(ice)) == ice)
    }
}
