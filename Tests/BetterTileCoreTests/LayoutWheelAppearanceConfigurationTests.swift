import Foundation
import Testing
@testable import BetterTileCore

// The pre-style literal from LayoutWheelGroupedTests, including an Empty slot,
// a hidden outer assignment, and a continuous size between the new presets.
private let legacyWheelFixture = #"{"innerSlots":[null,{"windowAction":{"_0":"rightHalf"}},null,null,null,null,null,null],"isEnabled":true,"keyboardModifiers":7,"keyboardTriggerEnabled":true,"levelCount":1,"middleClickTriggerEnabled":false,"outerSlots":[{"repairBento":{}},null,null,null,null,null,null,null],"scale":0.85}"#

@Suite struct LayoutWheelAppearanceConfigurationTests {
    @Test func migrationWritesAppearanceAndSizePresets() throws {
        let data = Data("{\"schemaVersion\":12,\"layoutWheel\":\(legacyWheelFixture)}".utf8)
        let migrated = try ConfigurationStore.decode(data)
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(migrated)) as? [String: Any])
        let wheel = try #require(object["layoutWheel"] as? [String: Any])
        let appearance = try #require(wheel["appearance"] as? [String: Any])
        #expect(object["schemaVersion"] as? Int == 12)
        #expect(appearance["size"] as? String == "small")
        #expect(appearance["surfacePreset"] as? String == "liquidGlass")
        let strengths = try #require(appearance["surfaceStrengths"] as? [String: Double])
        #expect(strengths == ["liquidGlass": 0.30, "light": 0.55, "dark": 0.55])
        #expect(wheel["scale"] as? Double == 0.85)
    }

    @Test(arguments: [10, 11, 12])
    func earlierWheelSchemasKeepEveryPreference(version: Int) throws {
        let original = try #require(JSONSerialization.jsonObject(with: Data(legacyWheelFixture.utf8)) as? [String: Any])
        for style in ["custom", "grouped"] {
            for levelCount in [1, 2] {
                var wheel = original
                wheel["style"] = style
                wheel["levelCount"] = levelCount
                wheel["isEnabled"] = false
                wheel["keyboardTriggerEnabled"] = false
                wheel["keyboardModifiers"] = ShortcutModifiers([.command, .shift]).rawValue
                wheel["middleClickTriggerEnabled"] = true
                let old: [String: Any] = [
                    "schemaVersion": version, "layoutWheel": wheel,
                    "showDockIcon": true, "linkedResizeEnabled": true,
                    "overlayAppearance": ["useLiquidGlass": false, "strength": 0.73],
                ]
                let migrated = try ConfigurationStore.decode(JSONSerialization.data(withJSONObject: old))
                #expect(migrated.schemaVersion == 12)
                #expect(migrated.showDockIcon)
                #expect(migrated.linkedResizeEnabled)
                #expect(migrated.overlayAppearance == OverlayAppearance(useLiquidGlass: false, strength: 0.73))
                let result = migrated.layoutWheel
                #expect(result.appearance.size == .small)
                #expect(result.scale == 0.85)
                #expect(result.appearance.surfacePreset == .liquidGlass)
                #expect(result.appearance.surfaceStrengths == LayoutWheelSurfaceStrengths())
                let encoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(result)) as? [String: Any])
                for (key, value) in wheel where key != "style" || style != "custom" {
                    // Grouped used two rings regardless of Custom's stored count.
                    let expected: Any = key == "levelCount" && style == "grouped" ? 2 : value
                    #expect(NSDictionary(dictionary: [key: expected]).isEqual(to: [key: try #require(encoded[key])]))
                }
                #expect(result.groupedInnerSlots == LayoutWheelConfiguration.defaultInnerSlots)
                #expect(try ConfigurationStore.decode(JSONEncoder().encode(migrated)) == migrated)
            }
        }
    }

    @Test func eachPresetRemembersItsStrengthAcrossSelectionAndSaving() throws {
        var config = BetterTileConfiguration()
        config.layoutWheel.appearance.surfaceStrengths = .init(liquidGlass: 0.21, light: 0.63, dark: 0.82)
        for preset in LayoutWheelSurfacePreset.allCases {
            config.layoutWheel.appearance.surfacePreset = preset
            config = try ConfigurationStore.decode(JSONEncoder().encode(config))
            #expect(config.layoutWheel.appearance.surfacePreset == preset)
            #expect(config.layoutWheel.appearance.surfaceStrength == config.layoutWheel.appearance.surfaceStrengths[preset])
            #expect(config.layoutWheel.appearance.surfaceStrengths == .init(liquidGlass: 0.21, light: 0.63, dark: 0.82))
        }
        config.layoutWheel.appearance.surfaceStrength = 0.94
        #expect(config.layoutWheel.appearance.surfaceStrengths == .init(liquidGlass: 0.21, light: 0.63, dark: 0.94))
        config.layoutWheel.appearance.surfacePreset = .liquidGlass
        #expect(config.layoutWheel.appearance.surfaceStrength == 0.20)
    }

    @Test func sizeSnappingIncludesMidpointsAndExtremeValues() throws {
        let cases: [(Double, LayoutWheelSize)] = [
            (-Double.infinity, .small), (-10, .small), (0.8, .small), (0.85, .small),
            (0.9.nextDown, .small), (0.9, .medium), (0.9.nextUp, .medium), (1, .medium),
            (1.1.nextDown, .medium), (1.1, .large), (1.1.nextUp, .large),
            (1.2, .large), (1.3, .large), (10, .large), (.infinity, .large), (.nan, .medium),
        ]
        #expect(LayoutWheelSize.allCases.map(\.scale) == [0.8, 1, 1.2])
        for (scale, expected) in cases {
            #expect(LayoutWheelSize.nearest(to: scale) == expected)
            #expect(LayoutWheelConfiguration(scale: scale).appearance.size == expected)
            if scale.isFinite {
                let data = try JSONSerialization.data(withJSONObject: [
                    "schemaVersion": 12, "layoutWheel": ["scale": scale],
                ])
                #expect(try ConfigurationStore.decode(data).layoutWheel.appearance.size == expected)
            }
        }
    }

    @Test func legacyScaleAndSizeRemainConsistentWithoutChangingTheCurrentRenderer() throws {
        for size in LayoutWheelSize.allCases {
            var wheel = LayoutWheelConfiguration(scale: 0.85)
            wheel.appearance.size = size
            #expect(wheel.scale == size.scale)
            #expect(try JSONDecoder().decode(LayoutWheelConfiguration.self, from: JSONEncoder().encode(wheel)) == wheel)
            #expect(LayoutWheelConfiguration(scale: 0.85, appearance: .init(size: size)).scale == size.scale)
        }
        let retained = try decodeWheel(#"{"scale":0.85,"appearance":{"size":"small"}}"#)
        #expect(retained.scale == 0.85)
        #expect(retained.appearance.size.scale == 0.8)
        var changed = retained
        changed.scale = 1.2 // The current Settings page still writes scale.
        #expect(changed.appearance.size == .large)
        #expect(try JSONDecoder().decode(LayoutWheelConfiguration.self, from: JSONEncoder().encode(changed)) == changed)
        #expect(try decodeWheel(#"{"scale":0.85,"appearance":{"size":"large"}}"#).scale == 1.2)
        #expect(try decodeWheel(#"{"appearance":{"size":"large"}}"#).scale == 1.2)
    }

    @Test func unknownPresetsFallBackWithoutDiscardingOtherChoices() throws {
        let wheel = try decodeWheel(#"{"scale":1.2,"levelCount":2,"isEnabled":false,"appearance":{"surfacePreset":"futureGlass","surfaceStrengths":{"liquidGlass":0.42,"dark":0.81,"futureGlass":0.9},"size":"huge"}}"#)
        #expect(wheel.appearance.surfacePreset == .liquidGlass)
        #expect(wheel.appearance.surfaceStrengths == .init(liquidGlass: 0.42, light: 0.55, dark: 0.81))
        #expect(wheel.appearance.size == .medium)
        #expect(wheel.scale == 1)
        let saved = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(wheel)) as? [String: Any])
        let appearance = try #require(saved["appearance"] as? [String: Any])
        #expect(appearance["surfacePreset"] as? String == "liquidGlass")
        #expect(appearance["size"] as? String == "medium")
        let strengths = try #require(appearance["surfaceStrengths"] as? [String: Double])
        #expect(strengths["futureGlass"] == nil)
        #expect(try decodeWheel(#"{"appearance":{"size":"huge"},"scale":0.98}"#).scale == 1)
        #expect(wheel.levelCount == .two)
        #expect(!wheel.isEnabled)
        #expect(try JSONDecoder().decode(LayoutWheelSurfacePreset.self, from: Data(#""futureGlass""#.utf8)) == .liquidGlass)
        #expect(try JSONDecoder().decode(LayoutWheelSize.self, from: Data(#""huge""#.utf8)) == .medium)
    }

    @Test func missingAndPartialAppearanceUsesPerPresetDefaults() throws {
        #expect(try decodeWheel("{}") == LayoutWheelConfiguration())
        #expect(try decodeWheel(#"{"appearance":null}"#) == LayoutWheelConfiguration())
        #expect(try decodeWheel(#"{"appearance":{}}"#) == LayoutWheelConfiguration())
        #expect(try decodeWheel(#"{"appearance":{},"scale":0.85}"#).appearance.size == .small)
        #expect(try decodeWheel(#"{"appearance":{"surfacePreset":null,"surfaceStrengths":null,"size":null}}"#) == LayoutWheelConfiguration())
        let wheel = try decodeWheel(#"{"appearance":{"surfacePreset":"light","surfaceStrengths":{"dark":0.9}}}"#)
        #expect(wheel.appearance.surfaceStrength == 0.55)
        #expect(wheel.appearance.surfaceStrengths == .init(liquidGlass: 0.30, light: 0.55, dark: 0.9))
    }

    @Test func strengthsClampIndependentlyAndNonfiniteValuesUseTheirOwnDefaults() throws {
        #expect(try decodeWheel(#"{"appearance":{"surfaceStrengths":{"liquidGlass":-1,"light":2,"dark":0.9}}}"#).appearance.surfaceStrengths
            == .init(liquidGlass: 0, light: 1, dark: 0.9))
        var config = BetterTileConfiguration()
        config.layoutWheel.appearance.surfaceStrengths = .init(liquidGlass: .nan, light: .infinity, dark: -.infinity)
        #expect(try config.validated().layoutWheel.appearance.surfaceStrengths == LayoutWheelSurfaceStrengths())
        for preset in LayoutWheelSurfacePreset.allCases {
            for value in [0.0, 1.0] {
                config.layoutWheel.appearance.surfacePreset = preset
                config.layoutWheel.appearance.surfaceStrength = value
                config = try config.validated()
                #expect(try ConfigurationStore.decode(JSONEncoder().encode(config)).layoutWheel.appearance.surfaceStrength == value)
            }
        }
    }

    @Test func strengthsRoundToFivePercentStepsOnEveryWrite() throws {
        let cases: [(Double, Double)] = [
            (-1, 0), (2, 1), (0.21, 0.20), (0.63, 0.65), (0.82, 0.80),
            (0.94, 0.95), (0.025, 0.05), (0.975, 1), (0.30000000000000004, 0.30),
        ]
        for preset in LayoutWheelSurfacePreset.allCases {
            for (input, expected) in cases {
                var strengths = LayoutWheelSurfaceStrengths(liquidGlass: input, light: input, dark: input)
                #expect(strengths[preset] == expected)
                strengths[preset] = input
                #expect(strengths[preset] == expected)
                strengths.liquidGlass = input
                strengths.light = input
                strengths.dark = input
                #expect(strengths[preset] == expected)
                #expect(strengths.normalized()[preset] == expected)
                let decoded = try JSONDecoder().decode(LayoutWheelSurfaceStrengths.self, from: JSONEncoder().encode(strengths))
                #expect(decoded[preset] == expected)
            }
        }
    }

    @Test func malformedTypesStillRejectTheFile() {
        for json in [#"{"appearance":[]}"#, #"{"appearance":{"surfacePreset":4}}"#, #"{"appearance":{"size":false}}"#,
                     #"{"appearance":{"surfaceStrengths":{"dark":"strong"}}}"#, #"{"appearance":{"surfaceStrengths":[]}}"#] {
            #expect(throws: (any Error).self) { try decodeWheel(json) }
        }
    }

    @Test func resetAppearancePreservesAssignmentsStyleAndTriggers() throws {
        var wheel = try decodeWheel(legacyWheelFixture)
        wheel.style = .grouped
        wheel.isEnabled = false
        wheel.levelCount = .two
        wheel.keyboardTriggerEnabled = false
        wheel.middleClickTriggerEnabled = true
        let original = wheel
        wheel.appearance.surfacePreset = .dark
        wheel.appearance.surfaceStrength = 0.82
        // Editing a surface does not snap today's renderer's legacy scale.
        #expect(wheel.scale == original.scale)
        wheel.appearance.size = .large
        wheel.appearance = .init()
        #expect(wheel.appearance == LayoutWheelAppearance())
        #expect(wheel.scale == 1)
        var expected = original
        expected.scale = 1
        #expect(wheel == expected)
        // Reset also clears a continuous scale already in the Medium bucket.
        wheel.scale = 1.05
        wheel.appearance = .init()
        #expect(wheel.scale == 1)
    }

    @Test func appearanceChangesHaveOnlyTheLayoutWheelImpact() {
        let original = BetterTileConfiguration()
        var changed = original
        changed.layoutWheel.appearance.surfacePreset = .dark
        #expect(ConfigurationChangeSet.between(original, changed) == [.layoutWheel])
    }

    private func decodeWheel(_ json: String) throws -> LayoutWheelConfiguration {
        try JSONDecoder().decode(LayoutWheelConfiguration.self, from: Data(json.utf8))
    }
}
