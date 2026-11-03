// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 LMC-Karma

import Foundation

/// Persisted wheel controls. Raw values remain compatible with earlier builds.
public struct LayoutWheelLiquidSettings: Codable, Hashable, Sendable {
    public var preset: Preset
    public var appearance: Appearance
    public var translucency: Translucency {
        didSet { translucency = translucency.normalized(fallback: Self(preset: preset).translucency) }
    }
    public var look: Look
    public var motion: Motion {
        didSet { motion = motion.normalized(fallback: Self(preset: preset).motion) }
    }
    public var feel: Feel {
        didSet { feel = feel.normalized(fallback: Self(preset: preset).feel) }
    }
    public var submenus: Submenus

    public init(preset: Preset = .ice, appearance: Appearance = .system) {
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
        case .mono: look.highlightColour = .noHighlight
        case .frosted: look.highlightColour = .smokeGrey
        }
    }

    /// Appearance is independent of Style, as are size, assignments and triggers.
    public var isModified: Bool {
        !matchesIgnoringMaterial(Self(preset: preset, appearance: appearance))
    }

    private func matchesIgnoringMaterial(_ other: Self) -> Bool {
        var lhs = self, rhs = other
        lhs.look.material = .automatic; rhs.look.material = .automatic
        return lhs == rhs
    }

    public mutating func selectPreset(_ next: Preset) {
        self = Self(preset: next, appearance: appearance)
    }

    public mutating func resetToStyleDefaults() { selectPreset(preset) }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(2, forKey: .styleRevision)
        try values.encode(preset, forKey: .preset)
        try values.encode(appearance, forKey: .appearance)
        try values.encode(translucency, forKey: .translucency)
        try values.encode(look, forKey: .look)
        try values.encode(motion, forKey: .motion)
        try values.encode(feel, forKey: .feel)
        try values.encode(submenus, forKey: .submenus)
    }

    private enum CodingKeys: String, CodingKey {
        case preset, appearance, translucency, look, motion, feel, submenus, styleRevision
    }

    public init(from decoder: any Decoder) throws {
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
        // Unshipped style tuning resets once; current saves retain every user edit.
        if ((try? container.decode(Int.self, forKey: .styleRevision)) ?? 0) < 2 {
            self = Self(preset: preset, appearance: appearance)
        }
    }
}

public extension LayoutWheelLiquidSettings {
    enum Preset: String, Codable, CaseIterable, Sendable {
        case ice, warm, frosted, mono

        public init(from decoder: any Decoder) throws {
            let value = try decoder.singleValueContainer().decode(String.self)
            self = Self(rawValue: value) ?? .ice
        }
    }

    enum Appearance: String, Codable, CaseIterable, Sendable {
        case system, light, dark

        public init(from decoder: any Decoder) throws {
            let value = try decoder.singleValueContainer().decode(String.self)
            self = Self(rawValue: value) ?? .system
        }
    }

    enum Material: String, Codable, CaseIterable, Sendable {
        case automatic, frosted, smoked, clear

        public init(from decoder: any Decoder) throws {
            let value = try decoder.singleValueContainer().decode(String.self)
            self = Self(rawValue: value) ?? .automatic
        }
    }

    enum HighlightColour: String, Codable, CaseIterable, Sendable {
        case iceBlue, champagne, smokeGrey, violet, systemAccent
        case noHighlight = "none"
        public static let allCases: [Self] = [.iceBlue, .champagne, .smokeGrey, .noHighlight, .violet, .systemAccent]

        public init(from decoder: any Decoder) throws {
            let value = try decoder.singleValueContainer().decode(String.self)
            self = Self(rawValue: value) ?? .iceBlue
        }
    }

    enum Names: String, Codable, CaseIterable, Sendable {
        case centre, underIcons, hidden

        public init(from decoder: any Decoder) throws {
            let value = try decoder.singleValueContainer().decode(String.self)
            self = Self(rawValue: value) ?? .centre
        }
    }

    enum Opening: String, Codable, CaseIterable, Sendable {
        case calm, rise, bloom, quick

        public init(from decoder: any Decoder) throws {
            let value = try decoder.singleValueContainer().decode(String.self)
            self = Self(rawValue: value) ?? .calm
        }
    }

    enum Closing: String, Codable, CaseIterable, Sendable {
        case calm, quick, sink

        public init(from decoder: any Decoder) throws {
            let value = try decoder.singleValueContainer().decode(String.self)
            self = Self(rawValue: value) ?? .calm
        }
    }

    enum Arrangement: String, Codable, CaseIterable, Sendable {
        case fan, cluster, clusterAboveThree

        public init(from decoder: any Decoder) throws {
            let value = try decoder.singleValueContainer().decode(String.self)
            self = Self(rawValue: value) ?? .fan
        }
    }

    enum KeepOpen: String, Codable, CaseIterable, Sendable {
        case always = "keep", withinGroupAngle

        public init(from decoder: any Decoder) throws {
            let value = try decoder.singleValueContainer().decode(String.self)
            self = Self(rawValue: value) ?? .always
        }
    }

}

public extension LayoutWheelLiquidSettings {
    struct Translucency: Codable, Hashable, Sendable {
        public var light: Double
        public var dark: Double

        public init(light: Double = 0.3, dark: Double = 0.3) {
            self.light = light
            self.dark = dark
        }

        private enum CodingKeys: String, CodingKey {
            case light, dark
        }

        public init(from decoder: any Decoder) throws {
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
            result.light = bounded(light, in: 0...1, fallback: fallback.light)
            result.dark = bounded(dark, in: 0...1, fallback: fallback.dark)
            return result
        }
    }
}

public extension LayoutWheelLiquidSettings {
    struct Look: Codable, Hashable, Sendable {
        public var material: Material
        public var highlightColour: HighlightColour
        public var names: Names
        public var actionTint: Bool

        public init(material: Material = .automatic, highlightColour: HighlightColour = .iceBlue, names: Names = .centre, actionTint: Bool = false) {
            self.material = material
            self.highlightColour = highlightColour
            self.names = names
            self.actionTint = actionTint
        }

        private enum CodingKeys: String, CodingKey {
            case material, highlightColour, names, actionTint
        }

        public init(from decoder: any Decoder) throws {
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

public extension LayoutWheelLiquidSettings {
    struct Motion: Codable, Hashable, Sendable {
        public var opening: Opening
        public var closing: Closing
        public var pointerLean: Bool
        public var leanAmount: Double

        public init(opening: Opening = .calm, closing: Closing = .calm, pointerLean: Bool = false, leanAmount: Double = 6) {
            self.opening = opening
            self.closing = closing
            self.pointerLean = pointerLean
            self.leanAmount = leanAmount
        }

        private enum CodingKeys: String, CodingKey {
            case opening, closing, pointerLean, leanAmount
        }

        public init(from decoder: any Decoder) throws {
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
            result.leanAmount = bounded(leanAmount, in: 0...16, fallback: fallback.leanAmount)
            return result
        }
    }
}

public extension LayoutWheelLiquidSettings {
    struct Feel: Codable, Hashable, Sendable {
        public var tension: Double
        public var ringing: Double
        public var bulge: Double
        public var stretch: Double
        public var splash: Double
        public var magnetDamping: Double
        public var dropletResponse: Double

        public init(tension: Double = 2.6, ringing: Double = 0.32, bulge: Double = 7, stretch: Double = 30, splash: Double = 1, magnetDamping: Double = 0.58, dropletResponse: Double = 0.34) {
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

        public init(from decoder: any Decoder) throws {
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
            result.tension = bounded(tension, in: 1...6, fallback: fallback.tension)
            result.ringing = bounded(ringing, in: 0.1...1, fallback: fallback.ringing)
            result.bulge = bounded(bulge, in: 0...16, fallback: fallback.bulge)
            result.stretch = bounded(stretch, in: 0...60, fallback: fallback.stretch)
            result.splash = bounded(splash, in: 0...3, fallback: fallback.splash)
            result.magnetDamping = bounded(magnetDamping, in: 0.3...1, fallback: fallback.magnetDamping)
            result.dropletResponse = bounded(dropletResponse, in: 0.15...0.8, fallback: fallback.dropletResponse)
            return result
        }
    }
}

public extension LayoutWheelLiquidSettings {
    struct Submenus: Codable, Hashable, Sendable {
        public var arrangement: Arrangement
        public var keepOpen: KeepOpen

        public init(arrangement: Arrangement = .fan, keepOpen: KeepOpen = .always) {
            self.arrangement = arrangement
            self.keepOpen = keepOpen
        }

        private enum CodingKeys: String, CodingKey {
            case arrangement, keepOpen
        }

        public init(from decoder: any Decoder) throws {
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

private func bounded(_ value: Double, in range: ClosedRange<Double>, fallback: Double) -> Double {
    guard !value.isNaN else { return fallback }
    // A stable precision prevents slider conversion noise from marking a style Modified.
    return (min(range.upperBound, max(range.lowerBound, value)) * 1e9).rounded() / 1e9
}
