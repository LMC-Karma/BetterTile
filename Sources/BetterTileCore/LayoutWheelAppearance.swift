import Foundation

/// Independent of the Settings window's appearance and the wheel's content style.
public enum LayoutWheelSurfacePreset: String, Codable, CaseIterable, Sendable {
    case liquidGlass, light, dark

    public var defaultStrength: Double { self == .liquidGlass ? 0.30 : 0.55 }

    public init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: value) ?? .liquidGlass
    }
}

/// Appearance resets independently of assignments and triggers.
public struct LayoutWheelAppearance: Codable, Hashable, Sendable {
    public var liquid: LayoutWheelLiquidSettings
    public var surfacePreset: LayoutWheelSurfacePreset
    public var surfaceStrengths: LayoutWheelSurfaceStrengths

    // Kept only for the current renderer. Remove this continuous backing value
    // when the new renderer lands, and store size directly instead.
    var compatibilityScale: Double

    /// New Settings UI writes size, never a continuous scale.
    public var size: LayoutWheelSize {
        get { LayoutWheelSize.nearest(to: compatibilityScale) }
        set { compatibilityScale = newValue.scale }
    }

    public var surfaceStrength: Double {
        get { surfaceStrengths[surfacePreset] }
        set { surfaceStrengths[surfacePreset] = newValue }
    }

    /// Keep the liquid renderer and the panel fallback aligned with an explicit Appearance choice.
    public mutating func selectAppearance(_ value: LayoutWheelLiquidSettings.Appearance) {
        liquid.appearance = value
        surfacePreset = switch value {
        case .system: .liquidGlass
        case .light: .light
        case .dark: .dark
        }
    }

    public init(
        surfacePreset: LayoutWheelSurfacePreset = .liquidGlass,
        surfaceStrengths: LayoutWheelSurfaceStrengths = .init(),
        size: LayoutWheelSize = .medium,
        liquid: LayoutWheelLiquidSettings = .init()
    ) {
        self.liquid = liquid
        self.surfacePreset = surfacePreset
        self.surfaceStrengths = surfaceStrengths
        compatibilityScale = size.scale
    }

    private enum CodingKeys: String, CodingKey {
        case surfacePreset, surfaceStrengths, size, liquid
    }

    public init(from decoder: any Decoder) throws {
        try self.init(from: decoder, legacyScale: LayoutWheelSize.medium.scale)
    }

    init(from decoder: any Decoder, legacyScale: Double) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawSize = try container.decodeIfPresent(String.self, forKey: .size)
        let legacyPreset = try container.decodeIfPresent(LayoutWheelSurfacePreset.self, forKey: .surfacePreset)
            ?? .liquidGlass
        let legacyAppearance: LayoutWheelLiquidSettings.Appearance = switch legacyPreset {
        case .liquidGlass: .system
        case .light: .light
        case .dark: .dark
        }
        // A future or malformed liquid shape does not make the legacy configuration unloadable.
        let liquid = (try? container.decodeIfPresent(LayoutWheelLiquidSettings.self, forKey: .liquid))
            ?? .init(appearance: legacyAppearance)
        self.init(
            surfacePreset: legacyPreset,
            surfaceStrengths: try container.decodeIfPresent(LayoutWheelSurfaceStrengths.self, forKey: .surfaceStrengths)
                ?? .init(),
            size: rawSize.map { LayoutWheelSize(rawValue: $0) ?? .medium } ?? .nearest(to: legacyScale),
            liquid: liquid
        )
        // Keep the current renderer's exact scale only when it agrees with a
        // known size. Unknown sizes always use Medium's exact scale.
        if rawSize == nil || (rawSize.flatMap(LayoutWheelSize.init(rawValue:)) != nil
            && LayoutWheelSize.nearest(to: legacyScale) == size) {
            compatibilityScale = legacyScale
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(liquid, forKey: .liquid)
        try container.encode(surfacePreset, forKey: .surfacePreset)
        try container.encode(surfaceStrengths, forKey: .surfaceStrengths)
        try container.encode(size, forKey: .size)
    }
}

/// Each surface retains its own strength in 5-percent steps, from 0 to 1.
public struct LayoutWheelSurfaceStrengths: Codable, Hashable, Sendable {
    public var liquidGlass: Double {
        didSet { liquidGlass = Self.normalized(liquidGlass, for: .liquidGlass) }
    }
    public var light: Double {
        didSet { light = Self.normalized(light, for: .light) }
    }
    public var dark: Double {
        didSet { dark = Self.normalized(dark, for: .dark) }
    }

    public init(
        liquidGlass: Double = LayoutWheelSurfacePreset.liquidGlass.defaultStrength,
        light: Double = LayoutWheelSurfacePreset.light.defaultStrength,
        dark: Double = LayoutWheelSurfacePreset.dark.defaultStrength
    ) {
        self.liquidGlass = Self.normalized(liquidGlass, for: .liquidGlass)
        self.light = Self.normalized(light, for: .light)
        self.dark = Self.normalized(dark, for: .dark)
    }

    public subscript(preset: LayoutWheelSurfacePreset) -> Double {
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

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            liquidGlass: try container.decodeIfPresent(Double.self, forKey: .liquidGlass)
                ?? LayoutWheelSurfacePreset.liquidGlass.defaultStrength,
            light: try container.decodeIfPresent(Double.self, forKey: .light)
                ?? LayoutWheelSurfacePreset.light.defaultStrength,
            dark: try container.decodeIfPresent(Double.self, forKey: .dark)
                ?? LayoutWheelSurfacePreset.dark.defaultStrength
        )
    }

    public func normalized() -> Self {
        Self(liquidGlass: liquidGlass, light: light, dark: dark)
    }

    private static func normalized(_ value: Double, for preset: LayoutWheelSurfacePreset) -> Double {
        guard value.isFinite else { return preset.defaultStrength }
        // Multiplication before rounding avoids division error at 5-percent midpoints.
        return (min(1, max(0, value)) * 20).rounded() / 20
    }
}

public enum LayoutWheelSize: String, Codable, CaseIterable, Sendable {
    case small, medium, large

    public var scale: Double {
        switch self {
        case .small: 0.8
        case .medium: 1.0
        case .large: 1.2
        }
    }

    public static func nearest(to scale: Double) -> Self {
        guard !scale.isNaN else { return .medium }
        // Midpoint comparisons give ties to the larger choice without distance rounding.
        if scale < 0.9 { return .small }
        if scale < 1.1 { return .medium }
        return .large
    }

    public init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: value) ?? .medium
    }
}
