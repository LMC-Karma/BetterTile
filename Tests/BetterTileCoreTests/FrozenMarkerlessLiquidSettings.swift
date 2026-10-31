// Frozen test-only copy of the liquid settings format before the style marker. Do not update with the product model.
// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 LMC-Karma

import Foundation

/// Persisted liquid-wheel controls. The nested enum raw values map to the renderer types.
struct FrozenMarkerlessLiquidSettings: Codable, Hashable, Sendable {
    var preset: Preset
    var appearance: Appearance
    var translucency: Translucency {
        didSet { translucency = translucency.normalized(fallback: Self(preset: preset).translucency) }
    }
    var look: Look
    var motion: Motion {
        didSet { motion = motion.normalized(fallback: Self(preset: preset).motion) }
    }
    var feel: Feel {
        didSet { feel = feel.normalized(fallback: Self(preset: preset).feel) }
    }
    var submenus: Submenus

    init(preset: Preset = .ice, appearance: Appearance = .system) {
        self.preset = preset
        self.appearance = appearance
        translucency = .init()
        look = .init()
        motion = .init()
        feel = .init()
        submenus = .init()
        switch preset {
        case .ice: break
        case .warm:
            translucency = .init(light: 0.35, dark: 0.35)
            look.highlightColour = .champagne
            motion.opening = .rise
            motion.pointerLean = true
            feel.bulge = 4
            feel.stretch = 12
            feel.splash = 0.5
            feel.ringing = 0.6
        case .mono:
            translucency = .init(light: 0.2, dark: 0.2)
            look.material = .smoked
            look.highlightColour = .smokeGrey
        case .frosted:
            translucency = .init(light: 0.85, dark: 0.85)
            look.material = .frosted
            motion.opening = .bloom
        }
    }

    /// Appearance is independent of Style, as are size, assignments and triggers.
    var isModified: Bool {
        self != Self(preset: preset, appearance: appearance)
    }

    mutating func selectPreset(_ next: Preset) {
        self = Self(preset: next, appearance: appearance)
    }

    mutating func resetToStyleDefaults() { selectPreset(preset) }

    private enum CodingKeys: String, CodingKey {
        case preset, appearance, translucency, look, motion, feel, submenus
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(preset: try container.decodeIfPresent(Preset.self, forKey: .preset) ?? .ice,
                  appearance: try container.decodeIfPresent(Appearance.self, forKey: .appearance) ?? .system)
        if container.contains(.translucency), try !container.decodeNil(forKey: .translucency) {
            translucency = try Translucency(from: container.superDecoder(forKey: .translucency), defaults: translucency)
        }
        if container.contains(.look), try !container.decodeNil(forKey: .look) {
            look = try Look(from: container.superDecoder(forKey: .look), defaults: look)
        }
        if container.contains(.motion), try !container.decodeNil(forKey: .motion) {
            motion = try Motion(from: container.superDecoder(forKey: .motion), defaults: motion)
        }
        if container.contains(.feel), try !container.decodeNil(forKey: .feel) {
            feel = try Feel(from: container.superDecoder(forKey: .feel), defaults: feel)
        }
        if container.contains(.submenus), try !container.decodeNil(forKey: .submenus) {
            submenus = try Submenus(from: container.superDecoder(forKey: .submenus), defaults: submenus)
        }
        let baseline = Self(preset: preset)
        translucency = translucency.normalized(fallback: baseline.translucency)
        motion = motion.normalized(fallback: baseline.motion)
        feel = feel.normalized(fallback: baseline.feel)
    }
}

extension FrozenMarkerlessLiquidSettings {
    enum Preset: String, Codable, CaseIterable, Sendable {
        case ice, warm, mono, frosted

        init(from decoder: any Decoder) throws {
            let value = try decoder.singleValueContainer().decode(String.self)
            self = Self(rawValue: value) ?? .ice
        }
    }

    enum Appearance: String, Codable, CaseIterable, Sendable {
        case system, light, dark

        init(from decoder: any Decoder) throws {
            let value = try decoder.singleValueContainer().decode(String.self)
            self = Self(rawValue: value) ?? .system
        }
    }

    enum Material: String, Codable, CaseIterable, Sendable {
        case automatic, frosted, smoked, clear

        init(from decoder: any Decoder) throws {
            let value = try decoder.singleValueContainer().decode(String.self)
            self = Self(rawValue: value) ?? .automatic
        }
    }

    enum HighlightColour: String, Codable, CaseIterable, Sendable {
        case iceBlue, champagne, violet, smokeGrey, systemAccent

        init(from decoder: any Decoder) throws {
            let value = try decoder.singleValueContainer().decode(String.self)
            self = Self(rawValue: value) ?? .iceBlue
        }
    }

    enum Names: String, Codable, CaseIterable, Sendable {
        case centre, underIcons, hidden

        init(from decoder: any Decoder) throws {
            let value = try decoder.singleValueContainer().decode(String.self)
            self = Self(rawValue: value) ?? .centre
        }
    }

    enum Opening: String, Codable, CaseIterable, Sendable {
        case calm, rise, bloom, quick

        init(from decoder: any Decoder) throws {
            let value = try decoder.singleValueContainer().decode(String.self)
            self = Self(rawValue: value) ?? .calm
        }
    }

    enum Closing: String, Codable, CaseIterable, Sendable {
        case calm, quick, sink

        init(from decoder: any Decoder) throws {
            let value = try decoder.singleValueContainer().decode(String.self)
            self = Self(rawValue: value) ?? .calm
        }
    }

    enum Arrangement: String, Codable, CaseIterable, Sendable {
        case fan, cluster, clusterAboveThree

        init(from decoder: any Decoder) throws {
            let value = try decoder.singleValueContainer().decode(String.self)
            self = Self(rawValue: value) ?? .fan
        }
    }

    enum KeepOpen: String, Codable, CaseIterable, Sendable {
        case always = "keep", withinGroupAngle

        init(from decoder: any Decoder) throws {
            let value = try decoder.singleValueContainer().decode(String.self)
            self = Self(rawValue: value) ?? .always
        }
    }

}

extension FrozenMarkerlessLiquidSettings {
    struct Translucency: Codable, Hashable, Sendable {
        var light: Double
        var dark: Double

        init(light: Double = 0.3, dark: Double = 0.3) {
            self.light = light
            self.dark = dark
        }

        private enum CodingKeys: String, CodingKey {
            case light, dark
        }

        init(from decoder: any Decoder) throws {
            try self.init(from: decoder, defaults: Self())
        }

        init(from decoder: any Decoder, defaults: Self) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.init(
                light: try container.decodeIfPresent(Double.self, forKey: .light) ?? defaults.light,
                dark: try container.decodeIfPresent(Double.self, forKey: .dark) ?? defaults.dark
            )
        }

        func normalized(fallback: Self) -> Self {
            var result = self
            result.light = frozen689Bounded(light, in: 0...1, fallback: fallback.light)
            result.dark = frozen689Bounded(dark, in: 0...1, fallback: fallback.dark)
            return result
        }
    }
}

extension FrozenMarkerlessLiquidSettings {
    struct Look: Codable, Hashable, Sendable {
        var material: Material
        var highlightColour: HighlightColour
        var names: Names
        var actionTint: Bool

        init(material: Material = .automatic, highlightColour: HighlightColour = .iceBlue, names: Names = .centre, actionTint: Bool = false) {
            self.material = material
            self.highlightColour = highlightColour
            self.names = names
            self.actionTint = actionTint
        }

        private enum CodingKeys: String, CodingKey {
            case material, highlightColour, names, actionTint
        }

        init(from decoder: any Decoder) throws {
            try self.init(from: decoder, defaults: Self())
        }

        init(from decoder: any Decoder, defaults: Self) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.init(
                material: try container.decodeIfPresent(Material.self, forKey: .material) ?? defaults.material,
                highlightColour: try container.decodeIfPresent(HighlightColour.self, forKey: .highlightColour) ?? defaults.highlightColour,
                names: try container.decodeIfPresent(Names.self, forKey: .names) ?? defaults.names,
                actionTint: try container.decodeIfPresent(Bool.self, forKey: .actionTint) ?? defaults.actionTint
            )
        }
    }
}

extension FrozenMarkerlessLiquidSettings {
    struct Motion: Codable, Hashable, Sendable {
        var opening: Opening
        var closing: Closing
        var pointerLean: Bool
        var leanAmount: Double

        init(opening: Opening = .calm, closing: Closing = .calm, pointerLean: Bool = false, leanAmount: Double = 6) {
            self.opening = opening
            self.closing = closing
            self.pointerLean = pointerLean
            self.leanAmount = leanAmount
        }

        private enum CodingKeys: String, CodingKey {
            case opening, closing, pointerLean, leanAmount
        }

        init(from decoder: any Decoder) throws {
            try self.init(from: decoder, defaults: Self())
        }

        init(from decoder: any Decoder, defaults: Self) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.init(
                opening: try container.decodeIfPresent(Opening.self, forKey: .opening) ?? defaults.opening,
                closing: try container.decodeIfPresent(Closing.self, forKey: .closing) ?? defaults.closing,
                pointerLean: try container.decodeIfPresent(Bool.self, forKey: .pointerLean) ?? defaults.pointerLean,
                leanAmount: try container.decodeIfPresent(Double.self, forKey: .leanAmount) ?? defaults.leanAmount
            )
        }

        func normalized(fallback: Self) -> Self {
            var result = self
            result.leanAmount = frozen689Bounded(leanAmount, in: 0...16, fallback: fallback.leanAmount)
            return result
        }
    }
}

extension FrozenMarkerlessLiquidSettings {
    struct Feel: Codable, Hashable, Sendable {
        var tension: Double
        var ringing: Double
        var bulge: Double
        var stretch: Double
        var splash: Double
        var magnetDamping: Double
        var dropletResponse: Double

        init(tension: Double = 2.6, ringing: Double = 0.32, bulge: Double = 7, stretch: Double = 30, splash: Double = 1, magnetDamping: Double = 0.58, dropletResponse: Double = 0.34) {
            self.tension = tension
            self.ringing = ringing
            self.bulge = bulge
            self.stretch = stretch
            self.splash = splash
            self.magnetDamping = magnetDamping
            self.dropletResponse = dropletResponse
        }

        private enum CodingKeys: String, CodingKey {
            case tension, ringing, bulge, stretch, splash, magnetDamping, dropletResponse
        }

        init(from decoder: any Decoder) throws {
            try self.init(from: decoder, defaults: Self())
        }

        init(from decoder: any Decoder, defaults: Self) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.init(
                tension: try container.decodeIfPresent(Double.self, forKey: .tension) ?? defaults.tension,
                ringing: try container.decodeIfPresent(Double.self, forKey: .ringing) ?? defaults.ringing,
                bulge: try container.decodeIfPresent(Double.self, forKey: .bulge) ?? defaults.bulge,
                stretch: try container.decodeIfPresent(Double.self, forKey: .stretch) ?? defaults.stretch,
                splash: try container.decodeIfPresent(Double.self, forKey: .splash) ?? defaults.splash,
                magnetDamping: try container.decodeIfPresent(Double.self, forKey: .magnetDamping) ?? defaults.magnetDamping,
                dropletResponse: try container.decodeIfPresent(Double.self, forKey: .dropletResponse) ?? defaults.dropletResponse
            )
        }

        func normalized(fallback: Self) -> Self {
            var result = self
            result.tension = frozen689Bounded(tension, in: 1...6, fallback: fallback.tension)
            result.ringing = frozen689Bounded(ringing, in: 0.1...1, fallback: fallback.ringing)
            result.bulge = frozen689Bounded(bulge, in: 0...16, fallback: fallback.bulge)
            result.stretch = frozen689Bounded(stretch, in: 0...60, fallback: fallback.stretch)
            result.splash = frozen689Bounded(splash, in: 0...3, fallback: fallback.splash)
            result.magnetDamping = frozen689Bounded(magnetDamping, in: 0.3...1, fallback: fallback.magnetDamping)
            result.dropletResponse = frozen689Bounded(dropletResponse, in: 0.15...0.8, fallback: fallback.dropletResponse)
            return result
        }
    }
}

extension FrozenMarkerlessLiquidSettings {
    struct Submenus: Codable, Hashable, Sendable {
        var arrangement: Arrangement
        var keepOpen: KeepOpen

        init(arrangement: Arrangement = .fan, keepOpen: KeepOpen = .always) {
            self.arrangement = arrangement
            self.keepOpen = keepOpen
        }

        private enum CodingKeys: String, CodingKey {
            case arrangement, keepOpen
        }

        init(from decoder: any Decoder) throws {
            try self.init(from: decoder, defaults: Self())
        }

        init(from decoder: any Decoder, defaults: Self) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.init(
                arrangement: try container.decodeIfPresent(Arrangement.self, forKey: .arrangement) ?? defaults.arrangement,
                keepOpen: try container.decodeIfPresent(KeepOpen.self, forKey: .keepOpen) ?? defaults.keepOpen
            )
        }
    }
}

private func frozen689Bounded(_ value: Double, in range: ClosedRange<Double>, fallback: Double) -> Double {
    guard !value.isNaN else { return fallback }
    // A stable precision prevents slider conversion noise from marking a style Modified.
    return (min(range.upperBound, max(range.lowerBound, value)) * 1e9).rounded() / 1e9
}
