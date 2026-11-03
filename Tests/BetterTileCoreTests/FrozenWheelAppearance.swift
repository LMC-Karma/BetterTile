// Frozen appearance decoder from before Fine-Tuning, for downgrade tests. Keep independent of production types.
import Foundation

/// Independent of the Settings window's appearance and the wheel's content style.
enum FrozenSurfacePreset: String, Codable, CaseIterable, Sendable {
    case liquidGlass, light, dark

    var defaultStrength: Double { self == .liquidGlass ? 0.30 : 0.55 }

    init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: value) ?? .liquidGlass
    }
}

/// Appearance resets independently of assignments and triggers.
struct FrozenAppearance: Codable, Hashable, Sendable {
    var surfacePreset: FrozenSurfacePreset
    var surfaceStrengths: FrozenStrengths

    // Kept only for the current renderer. Remove this continuous backing value
    // when the new renderer lands, and store size directly instead.
    var compatibilityScale: Double

    /// New Settings UI writes size, never a continuous scale.
    var size: FrozenSize {
        get { FrozenSize.nearest(to: compatibilityScale) }
        set { compatibilityScale = newValue.scale }
    }

    var surfaceStrength: Double {
        get { surfaceStrengths[surfacePreset] }
        set { surfaceStrengths[surfacePreset] = newValue }
    }

    init(
        surfacePreset: FrozenSurfacePreset = .liquidGlass,
        surfaceStrengths: FrozenStrengths = .init(),
        size: FrozenSize = .medium
    ) {
        self.surfacePreset = surfacePreset
        self.surfaceStrengths = surfaceStrengths
        compatibilityScale = size.scale
    }

    private enum CodingKeys: String, CodingKey {
        case surfacePreset, surfaceStrengths, size
    }

    init(from decoder: any Decoder) throws {
        try self.init(from: decoder, legacyScale: FrozenSize.medium.scale)
    }

    init(from decoder: any Decoder, legacyScale: Double) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawSize = try container.decodeIfPresent(String.self, forKey: .size)
        self.init(
            surfacePreset: try container.decodeIfPresent(FrozenSurfacePreset.self, forKey: .surfacePreset)
                ?? .liquidGlass,
            surfaceStrengths: try container.decodeIfPresent(FrozenStrengths.self, forKey: .surfaceStrengths)
                ?? .init(),
            size: rawSize.map { FrozenSize(rawValue: $0) ?? .medium } ?? .nearest(to: legacyScale)
        )
        // Keep the current renderer's exact scale only when it agrees with a
        // known size. Unknown sizes always use Medium's exact scale.
        if rawSize == nil || (rawSize.flatMap(FrozenSize.init(rawValue:)) != nil
            && FrozenSize.nearest(to: legacyScale) == size) {
            compatibilityScale = legacyScale
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(surfacePreset, forKey: .surfacePreset)
        try container.encode(surfaceStrengths, forKey: .surfaceStrengths)
        try container.encode(size, forKey: .size)
    }
}

/// Each surface retains its own strength in 5-percent steps, from 0 to 1.
struct FrozenStrengths: Codable, Hashable, Sendable {
    var liquidGlass: Double {
        didSet { liquidGlass = Self.normalized(liquidGlass, for: .liquidGlass) }
    }
    var light: Double {
        didSet { light = Self.normalized(light, for: .light) }
    }
    var dark: Double {
        didSet { dark = Self.normalized(dark, for: .dark) }
    }

    init(
        liquidGlass: Double = FrozenSurfacePreset.liquidGlass.defaultStrength,
        light: Double = FrozenSurfacePreset.light.defaultStrength,
        dark: Double = FrozenSurfacePreset.dark.defaultStrength
    ) {
        self.liquidGlass = Self.normalized(liquidGlass, for: .liquidGlass)
        self.light = Self.normalized(light, for: .light)
        self.dark = Self.normalized(dark, for: .dark)
    }

    subscript(preset: FrozenSurfacePreset) -> Double {
        get {
            switch preset {
            case .liquidGlass: liquidGlass
            case .light: light
            case .dark: dark
            }
        }
        set {
            switch preset {
            case .liquidGlass: liquidGlass = newValue
            case .light: light = newValue
            case .dark: dark = newValue
            }
        }
    }

    private enum CodingKeys: String, CodingKey {
        case liquidGlass, light, dark
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            liquidGlass: try container.decodeIfPresent(Double.self, forKey: .liquidGlass)
                ?? FrozenSurfacePreset.liquidGlass.defaultStrength,
            light: try container.decodeIfPresent(Double.self, forKey: .light)
                ?? FrozenSurfacePreset.light.defaultStrength,
            dark: try container.decodeIfPresent(Double.self, forKey: .dark)
                ?? FrozenSurfacePreset.dark.defaultStrength
        )
    }

    func normalized() -> Self {
        Self(liquidGlass: liquidGlass, light: light, dark: dark)
    }

    private static func normalized(_ value: Double, for preset: FrozenSurfacePreset) -> Double {
        guard value.isFinite else { return preset.defaultStrength }
        // Multiplication before rounding avoids division error at 5-percent midpoints.
        return (min(1, max(0, value)) * 20).rounded() / 20
    }
}

enum FrozenSize: String, Codable, CaseIterable, Sendable {
    case small, medium, large

    var scale: Double {
        switch self {
        case .small: 0.8
        case .medium: 1.0
        case .large: 1.2
        }
    }

    static func nearest(to scale: Double) -> Self {
        guard !scale.isNaN else { return .medium }
        // Midpoint comparisons give ties to the larger choice without distance rounding.
        if scale < 0.9 { return .small }
        if scale < 1.1 { return .medium }
        return .large
    }

    init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: value) ?? .medium
    }
}
