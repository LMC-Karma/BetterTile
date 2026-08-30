import Foundation

public struct ShortcutModifiers: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: UInt

    public init(rawValue: UInt) { self.rawValue = rawValue }

    public static let command = ShortcutModifiers(rawValue: 1 << 0)
    public static let option = ShortcutModifiers(rawValue: 1 << 1)
    public static let control = ShortcutModifiers(rawValue: 1 << 2)
    public static let shift = ShortcutModifiers(rawValue: 1 << 3)

    public var displayText: String {
        var value = ""
        if contains(.control) { value += "⌃" }
        if contains(.option) { value += "⌥" }
        if contains(.shift) { value += "⇧" }
        if contains(.command) { value += "⌘" }
        return value
    }
}

public struct KeyboardShortcut: Codable, Hashable, Sendable {
    /// Hardware-independent macOS virtual key code used by Carbon hot keys.
    public var keyCode: UInt32
    public var modifiers: ShortcutModifiers
    public var keyLabel: String

    public init(keyCode: UInt32, modifiers: ShortcutModifiers, keyLabel: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.keyLabel = keyLabel
    }

    public var displayText: String { modifiers.displayText + keyLabel.uppercased() }
}

public struct ShortcutBinding: Codable, Hashable, Identifiable, Sendable {
    public var action: WindowAction
    public var shortcut: KeyboardShortcut?
    public var id: WindowAction { action }

    public init(action: WindowAction, shortcut: KeyboardShortcut?) {
        self.action = action
        self.shortcut = shortcut
    }
}

public struct ShortcutConflict: Equatable, Sendable {
    public var shortcut: KeyboardShortcut
    public var actions: [WindowAction]
}

public enum ShortcutValidator {
    public static func conflicts(in bindings: [ShortcutBinding]) -> [ShortcutConflict] {
        Dictionary(
            grouping: bindings.compactMap { binding in binding.shortcut.map { ($0, binding.action) } },
            by: { "\($0.0.keyCode):\($0.0.modifiers.rawValue)" }
        )
            .compactMap { _, values in
                let actions = values.map(\.1).sorted { $0.rawValue < $1.rawValue }
                return actions.count > 1 ? ShortcutConflict(shortcut: values[0].0, actions: actions) : nil
            }
            .sorted { $0.shortcut.displayText < $1.shortcut.displayText }
    }
}

public enum ResizeFeedbackMode: String, Codable, CaseIterable, Sendable {
    case ghost
    case live
}

public enum DividerVisibility: String, Codable, CaseIterable, Sendable {
    case hoverAndDrag
    case always
    case dragOnly
}

public struct BetterTileConfiguration: Codable, Hashable, Sendable {
    public static let currentSchemaVersion = 10

    /// The placement a lone window receives, restricted to the actions that
    /// describe a position on the display. `nil` means "leave it unchanged".
    ///
    /// The relative actions — move, grow, shrink, display transfer, restore —
    /// are meaningless here: a window that just became the only one on its
    /// desktop has no prior placement to move relative to.
    static func normalizedSingleWindowPlacement(_ action: WindowAction?) -> WindowAction? {
        guard let action else { return nil }
        return WindowAction.snapAssignableActions.contains(action) ? action : .maximize
    }

    public var schemaVersion: Int
    public var setupCompletionVersion: Int
    public var macOSTilingRecommendationAcknowledged: Bool
    public var stageManagerRecommendationAcknowledged: Bool
    public var showDockIcon: Bool
    public var snappingEnabled: Bool
    public var linkedResizeEnabled: Bool
    public var defaultLayoutMode: LayoutMode
    public var singleWindowPlacement: WindowAction?
    public var resizeFeedbackMode: ResizeFeedbackMode
    public var dividerVisibility: DividerVisibility
    public var dividerThickness: Double
    public var bentoInnerGap: Double
    public var bentoSwapHoverDelay: Double
    public var snapSuppressionModifiers: ShortcutModifiers
    public var adjacencyTolerance: Double
    public var snapAreaBindings: [SnapAreaBinding]
    public var doubleClickTitleBarToMaximize: Bool
    public var enhancedUserInterfacePolicy: EnhancedUserInterfacePolicy
    public var applicationRules: ApplicationRuleSet
    /// Master switch for every BetterTile global shortcut. Bindings are kept so
    /// turning it back on restores them untouched.
    public var keyboardShortcutsEnabled: Bool
    public var shortcuts: [ShortcutBinding]
    public var layoutWheel: LayoutWheelConfiguration

    public init(
        schemaVersion: Int = BetterTileConfiguration.currentSchemaVersion,
        setupCompletionVersion: Int = 0,
        macOSTilingRecommendationAcknowledged: Bool = false,
        stageManagerRecommendationAcknowledged: Bool = false,
        showDockIcon: Bool = false,
        snappingEnabled: Bool = true,
        linkedResizeEnabled: Bool = true,
        defaultLayoutMode: LayoutMode = .manual,
        singleWindowPlacement: WindowAction? = .maximize,
        resizeFeedbackMode: ResizeFeedbackMode = .ghost,
        dividerVisibility: DividerVisibility = .hoverAndDrag,
        dividerThickness: Double = 10,
        bentoInnerGap: Double = 1,
        bentoSwapHoverDelay: Double = 0.12,
        snapSuppressionModifiers: ShortcutModifiers = .option,
        adjacencyTolerance: Double = 6,
        snapAreaBindings: [SnapAreaBinding] = BetterTileConfiguration.defaultSnapAreaBindings,
        doubleClickTitleBarToMaximize: Bool = true,
        enhancedUserInterfacePolicy: EnhancedUserInterfacePolicy = .disableAndRestore,
        applicationRules: ApplicationRuleSet = ApplicationRuleSet(),
        keyboardShortcutsEnabled: Bool = true,
        shortcuts: [ShortcutBinding] = BetterTileConfiguration.defaultShortcuts,
        layoutWheel: LayoutWheelConfiguration = LayoutWheelConfiguration()
    ) {
        self.schemaVersion = schemaVersion
        self.setupCompletionVersion = max(0, setupCompletionVersion)
        self.macOSTilingRecommendationAcknowledged = macOSTilingRecommendationAcknowledged
        self.stageManagerRecommendationAcknowledged = stageManagerRecommendationAcknowledged
        self.showDockIcon = showDockIcon
        self.snappingEnabled = snappingEnabled
        self.linkedResizeEnabled = linkedResizeEnabled
        self.defaultLayoutMode = defaultLayoutMode
        self.singleWindowPlacement = Self.normalizedSingleWindowPlacement(singleWindowPlacement)
        self.resizeFeedbackMode = resizeFeedbackMode
        self.dividerVisibility = dividerVisibility
        self.dividerThickness = dividerThickness
        self.bentoInnerGap = min(12, max(0, bentoInnerGap))
        self.bentoSwapHoverDelay = bentoSwapHoverDelay
        self.snapSuppressionModifiers = snapSuppressionModifiers
        self.adjacencyTolerance = adjacencyTolerance
        self.snapAreaBindings = snapAreaBindings
        self.doubleClickTitleBarToMaximize = doubleClickTitleBarToMaximize
        self.enhancedUserInterfacePolicy = enhancedUserInterfacePolicy
        self.applicationRules = applicationRules
        self.keyboardShortcutsEnabled = keyboardShortcutsEnabled
        self.shortcuts = shortcuts
        self.layoutWheel = layoutWheel.normalized()
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, setupCompletionVersion
        case macOSTilingRecommendationAcknowledged, stageManagerRecommendationAcknowledged
        case showDockIcon, snappingEnabled, linkedResizeEnabled
        case defaultLayoutMode, resizeFeedbackMode, dividerVisibility, dividerThickness, bentoInnerGap, bentoSwapHoverDelay
        case singleWindowPlacement
        case singleWindowInitialPlacement
        case dockReservationMode
        case snapSuppressionModifiers, adjacencyTolerance, snapAreaBindings, doubleClickTitleBarToMaximize
        case enhancedUserInterfacePolicy
        case applicationRules, keyboardShortcutsEnabled
        case shortcuts, layoutWheel
        case layoutMode, bentoEnabled, bentoStates
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        guard version <= Self.currentSchemaVersion else { throw ConfigurationError.unsupportedFutureVersion(version) }

        schemaVersion = Self.currentSchemaVersion
        setupCompletionVersion = max(
            0,
            try container.decodeIfPresent(Int.self, forKey: .setupCompletionVersion) ?? 0
        )
        macOSTilingRecommendationAcknowledged = try container.decodeIfPresent(
            Bool.self,
            forKey: .macOSTilingRecommendationAcknowledged
        ) ?? false
        stageManagerRecommendationAcknowledged = try container.decodeIfPresent(
            Bool.self,
            forKey: .stageManagerRecommendationAcknowledged
        ) ?? false
        showDockIcon = try container.decodeIfPresent(Bool.self, forKey: .showDockIcon) ?? false
        snappingEnabled = try container.decodeIfPresent(Bool.self, forKey: .snappingEnabled) ?? true
        // Keep pre-existing installs off when their saved configuration
        // predates this key; only a configuration created from scratch defaults on.
        linkedResizeEnabled = try container.decodeIfPresent(Bool.self, forKey: .linkedResizeEnabled) ?? false
        if let rawMode = try container.decodeIfPresent(String.self, forKey: .defaultLayoutMode) {
            defaultLayoutMode = try Self.migrateLayoutMode(rawMode, codingPath: container.codingPath)
        } else {
            let rawLegacyMode = try container.decodeIfPresent(String.self, forKey: .layoutMode)
            let legacyMode = try rawLegacyMode.map {
                try Self.migrateLayoutMode($0, codingPath: container.codingPath)
            } ?? .manual
            let legacyBentoEnabled = try container.decodeIfPresent(Bool.self, forKey: .bentoEnabled) ?? false
            let migratedMode = legacyMode == .bento && !legacyBentoEnabled ? .manual : legacyMode
            defaultLayoutMode = migratedMode
        }
        if version < 5 {
            singleWindowPlacement = .maximize
        } else if version < 9 {
            // Versions 5 to 8 stored a three-value enum. Its cases map onto the
            // full action list the setting now offers.
            let legacy = try container.decodeIfPresent(String.self, forKey: .singleWindowInitialPlacement)
            singleWindowPlacement = switch legacy {
            case "almostMaximize": .almostMaximize
            case "unchanged": nil
            default: .maximize
            }
        } else {
            singleWindowPlacement = Self.normalizedSingleWindowPlacement(
                try container.decodeIfPresent(WindowAction.self, forKey: .singleWindowPlacement)
            )
        }
        resizeFeedbackMode = try container.decodeIfPresent(ResizeFeedbackMode.self, forKey: .resizeFeedbackMode) ?? .ghost
        // Legacy values remain decodable, but handles are now deliberately
        // hover-only so invisible panels never cover window content.
        _ = try container.decodeIfPresent(DividerVisibility.self, forKey: .dividerVisibility)
        dividerVisibility = .hoverAndDrag
        dividerThickness = try container.decodeIfPresent(Double.self, forKey: .dividerThickness) ?? 6
        if version >= 6 {
            bentoInnerGap = min(
                12,
                max(0, try container.decodeIfPresent(Double.self, forKey: .bentoInnerGap) ?? 0)
            )
        } else {
            // Version 4 briefly wrote this key for a rolled-back experiment.
            // Do not revive that value during the version 6 migration.
            _ = try container.decodeIfPresent(Double.self, forKey: .bentoInnerGap)
            bentoInnerGap = 0
        }
        _ = try container.decodeIfPresent(String.self, forKey: .dockReservationMode)
        let decodedSwapDelay = try container.decodeIfPresent(Double.self, forKey: .bentoSwapHoverDelay)
        bentoSwapHoverDelay = decodedSwapDelay == 0.25 ? 0.12 : decodedSwapDelay ?? 0.12
        snapSuppressionModifiers = try container.decodeIfPresent(ShortcutModifiers.self, forKey: .snapSuppressionModifiers) ?? .option
        adjacencyTolerance = try container.decodeIfPresent(Double.self, forKey: .adjacencyTolerance) ?? 6
        snapAreaBindings = try container.decodeIfPresent([SnapAreaBinding].self, forKey: .snapAreaBindings) ?? Self.defaultSnapAreaBindings
        doubleClickTitleBarToMaximize = try container.decodeIfPresent(Bool.self, forKey: .doubleClickTitleBarToMaximize) ?? true
        enhancedUserInterfacePolicy = try container.decodeIfPresent(
            EnhancedUserInterfacePolicy.self,
            forKey: .enhancedUserInterfacePolicy
        ) ?? .disableAndRestore
        applicationRules = try container.decodeIfPresent(
            ApplicationRuleSet.self,
            forKey: .applicationRules
        ) ?? ApplicationRuleSet()
        keyboardShortcutsEnabled = try container.decodeIfPresent(
            Bool.self,
            forKey: .keyboardShortcutsEnabled
        ) ?? true
        let decodedShortcuts = try container.decodeIfPresent([ShortcutBinding].self, forKey: .shortcuts)
        if version < 3, decodedShortcuts == Self.legacyDefaultShortcutsV2 {
            shortcuts = Self.defaultShortcuts
        } else {
            shortcuts = decodedShortcuts ?? Self.defaultShortcuts
        }
        layoutWheel = try container.decodeIfPresent(
            LayoutWheelConfiguration.self,
            forKey: .layoutWheel
        )?.normalized() ?? LayoutWheelConfiguration()
    }

    private static func migrateLayoutMode(_ rawValue: String, codingPath: [any CodingKey]) throws -> LayoutMode {
        if rawValue == "tabbed" { return .bento }
        guard let mode = LayoutMode(rawValue: rawValue) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: codingPath,
                debugDescription: "Unknown window layout mode: \(rawValue)"
            ))
        }
        return mode.availableMode
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentSchemaVersion, forKey: .schemaVersion)
        try container.encode(setupCompletionVersion, forKey: .setupCompletionVersion)
        try container.encode(
            macOSTilingRecommendationAcknowledged,
            forKey: .macOSTilingRecommendationAcknowledged
        )
        try container.encode(
            stageManagerRecommendationAcknowledged,
            forKey: .stageManagerRecommendationAcknowledged
        )
        try container.encode(showDockIcon, forKey: .showDockIcon)
        try container.encode(snappingEnabled, forKey: .snappingEnabled)
        try container.encode(linkedResizeEnabled, forKey: .linkedResizeEnabled)
        try container.encode(defaultLayoutMode, forKey: .defaultLayoutMode)
        try container.encodeIfPresent(singleWindowPlacement, forKey: .singleWindowPlacement)
        try container.encode(resizeFeedbackMode, forKey: .resizeFeedbackMode)
        try container.encode(dividerVisibility, forKey: .dividerVisibility)
        try container.encode(dividerThickness, forKey: .dividerThickness)
        try container.encode(bentoInnerGap, forKey: .bentoInnerGap)
        try container.encode(bentoSwapHoverDelay, forKey: .bentoSwapHoverDelay)
        try container.encode(snapSuppressionModifiers, forKey: .snapSuppressionModifiers)
        try container.encode(adjacencyTolerance, forKey: .adjacencyTolerance)
        try container.encode(snapAreaBindings, forKey: .snapAreaBindings)
        try container.encode(doubleClickTitleBarToMaximize, forKey: .doubleClickTitleBarToMaximize)
        try container.encode(enhancedUserInterfacePolicy, forKey: .enhancedUserInterfacePolicy)
        try container.encode(applicationRules, forKey: .applicationRules)
        try container.encode(keyboardShortcutsEnabled, forKey: .keyboardShortcutsEnabled)
        try container.encode(shortcuts, forKey: .shortcuts)
        try container.encode(layoutWheel, forKey: .layoutWheel)
    }

    public static let defaultSnapAreaBindings: [SnapAreaBinding] = [
        .init(area: .topLeft, action: .topLeftQuarter),
        .init(area: .top, action: .almostMaximize),
        .init(area: .topRight, action: .topRightQuarter),
        .init(area: .left, action: .leftHalf),
        .init(area: .right, action: .rightHalf),
        .init(area: .bottomLeft, action: .bottomLeftQuarter),
        .init(area: .bottom, action: nil),
        .init(area: .bottomRight, action: .bottomRightQuarter),
    ]

    public static let defaultShortcuts: [ShortcutBinding] = {
        let assigned: [WindowAction: KeyboardShortcut] = [
            .leftHalf: .init(keyCode: 123, modifiers: [.control, .option], keyLabel: "←"),
            .rightHalf: .init(keyCode: 124, modifiers: [.control, .option], keyLabel: "→"),
            .topHalf: .init(keyCode: 126, modifiers: [.control, .option], keyLabel: "↑"),
            .bottomHalf: .init(keyCode: 125, modifiers: [.control, .option], keyLabel: "↓"),
            .topLeftQuarter: .init(keyCode: 32, modifiers: [.control, .option], keyLabel: "U"),
            .topRightQuarter: .init(keyCode: 34, modifiers: [.control, .option], keyLabel: "I"),
            .bottomLeftQuarter: .init(keyCode: 38, modifiers: [.control, .option], keyLabel: "J"),
            .bottomRightQuarter: .init(keyCode: 40, modifiers: [.control, .option], keyLabel: "K"),
            .maximize: .init(keyCode: 36, modifiers: [.control, .option], keyLabel: "↩"),
            .restore: .init(keyCode: 51, modifiers: [.control, .option], keyLabel: "⌫"),
            .center: .init(keyCode: 8, modifiers: [.control, .option], keyLabel: "C"),
            .leftThird: .init(keyCode: 2, modifiers: [.control, .option], keyLabel: "D"),
            .leftTwoThirds: .init(keyCode: 14, modifiers: [.control, .option], keyLabel: "E"),
            .centerThird: .init(keyCode: 3, modifiers: [.control, .option], keyLabel: "F"),
            .rightThird: .init(keyCode: 5, modifiers: [.control, .option], keyLabel: "G"),
            .rightTwoThirds: .init(keyCode: 17, modifiers: [.control, .option], keyLabel: "T"),
            .growWidth: .init(keyCode: 24, modifiers: [.control, .option], keyLabel: "="),
            .shrinkWidth: .init(keyCode: 27, modifiers: [.control, .option], keyLabel: "-"),
            .nextDisplay: .init(keyCode: 124, modifiers: [.control, .option, .command], keyLabel: "→"),
            .previousDisplay: .init(keyCode: 123, modifiers: [.control, .option, .command], keyLabel: "←"),
        ]
        return WindowAction.allCases.map { ShortcutBinding(action: $0, shortcut: assigned[$0]) }
    }()

    static let legacyDefaultShortcutsV2: [ShortcutBinding] = [
        .init(action: .leftHalf, shortcut: .init(keyCode: 123, modifiers: [.control, .option], keyLabel: "←")),
        .init(action: .rightHalf, shortcut: .init(keyCode: 124, modifiers: [.control, .option], keyLabel: "→")),
        .init(action: .topHalf, shortcut: .init(keyCode: 126, modifiers: [.control, .option], keyLabel: "↑")),
        .init(action: .bottomHalf, shortcut: .init(keyCode: 125, modifiers: [.control, .option], keyLabel: "↓")),
        .init(action: .maximize, shortcut: .init(keyCode: 126, modifiers: [.control, .option, .command], keyLabel: "↑")),
        .init(action: .restore, shortcut: .init(keyCode: 125, modifiers: [.control, .option, .command], keyLabel: "↓")),
        .init(action: .nextDisplay, shortcut: .init(keyCode: 124, modifiers: [.control, .option, .command], keyLabel: "→")),
        .init(action: .previousDisplay, shortcut: .init(keyCode: 123, modifiers: [.control, .option, .command], keyLabel: "←")),
    ] + WindowAction.allCases.filter { action in
        ![.leftHalf, .rightHalf, .topHalf, .bottomHalf, .maximize, .restore, .nextDisplay, .previousDisplay].contains(action)
    }.map { ShortcutBinding(action: $0, shortcut: nil) }

    public func validated() throws -> BetterTileConfiguration {
        guard schemaVersion <= Self.currentSchemaVersion else { throw ConfigurationError.unsupportedFutureVersion(schemaVersion) }
        guard adjacencyTolerance >= 0, adjacencyTolerance <= 40 else { throw ConfigurationError.invalidAdjacencyTolerance }
        guard dividerThickness.isFinite, (2...12).contains(dividerThickness) else { throw ConfigurationError.invalidDividerThickness }
        guard bentoInnerGap.isFinite, (0...12).contains(bentoInnerGap) else { throw ConfigurationError.invalidBentoInnerGap }
        guard bentoSwapHoverDelay.isFinite, (0...1).contains(bentoSwapHoverDelay) else { throw ConfigurationError.invalidBentoSwapHoverDelay }
        guard ShortcutValidator.conflicts(in: shortcuts).isEmpty else { throw ConfigurationError.shortcutConflict }
        guard Set(snapAreaBindings.map(\.area)).count == SnapArea.allCases.count,
              snapAreaBindings.count == SnapArea.allCases.count,
              snapAreaBindings.allSatisfy({ binding in
                  binding.action.map { WindowAction.snapAssignableActions.contains($0) } ?? true
              })
        else { throw ConfigurationError.invalidSnapAreaBindings }
        var result = self
        result.schemaVersion = Self.currentSchemaVersion
        result.defaultLayoutMode = result.defaultLayoutMode.availableMode
        result.dividerVisibility = .hoverAndDrag
        result.singleWindowPlacement = Self.normalizedSingleWindowPlacement(result.singleWindowPlacement)
        result.layoutWheel = result.layoutWheel.normalized()
        return result
    }
}

public struct ConfigurationChangeSet: OptionSet, Hashable, Sendable {
    public let rawValue: UInt

    public init(rawValue: UInt) { self.rawValue = rawValue }

    public static let shortcuts = Self(rawValue: 1 << 0)
    public static let snapping = Self(rawValue: 1 << 1)
    public static let linkedResize = Self(rawValue: 1 << 2)
    public static let divider = Self(rawValue: 1 << 3)
    public static let bentoGeometry = Self(rawValue: 1 << 4)
    public static let activationPolicy = Self(rawValue: 1 << 5)
    public static let titleBar = Self(rawValue: 1 << 6)
    public static let accessibilityWrites = Self(rawValue: 1 << 7)
    public static let applicationRules = Self(rawValue: 1 << 8)
    public static let layoutWheel = Self(rawValue: 1 << 9)
    public static let all: Self = [
        .shortcuts, .snapping, .linkedResize, .divider,
        .bentoGeometry, .activationPolicy, .titleBar, .accessibilityWrites,
        .applicationRules, .layoutWheel,
    ]

    public static func between(
        _ old: BetterTileConfiguration,
        _ new: BetterTileConfiguration
    ) -> Self {
        var changes: Self = []
        if old.shortcuts != new.shortcuts
            || old.keyboardShortcutsEnabled != new.keyboardShortcutsEnabled {
            changes.insert(.shortcuts)
        }
        if old.applicationRules != new.applicationRules {
            changes.insert(.applicationRules)
        }
        if old.snappingEnabled != new.snappingEnabled
            || old.snapSuppressionModifiers != new.snapSuppressionModifiers
            || old.snapAreaBindings != new.snapAreaBindings {
            changes.insert(.snapping)
        }
        if old.linkedResizeEnabled != new.linkedResizeEnabled
            || old.adjacencyTolerance != new.adjacencyTolerance {
            changes.insert(.linkedResize)
        }
        if old.resizeFeedbackMode != new.resizeFeedbackMode
            || old.dividerVisibility != new.dividerVisibility
            || old.dividerThickness != new.dividerThickness
            || old.adjacencyTolerance != new.adjacencyTolerance {
            changes.insert(.divider)
        }
        if old.defaultLayoutMode != new.defaultLayoutMode
            || old.singleWindowPlacement != new.singleWindowPlacement
            || old.bentoInnerGap != new.bentoInnerGap
            || old.bentoSwapHoverDelay != new.bentoSwapHoverDelay
            || old.adjacencyTolerance != new.adjacencyTolerance {
            changes.insert(.bentoGeometry)
        }
        if old.enhancedUserInterfacePolicy != new.enhancedUserInterfacePolicy {
            changes.insert(.accessibilityWrites)
        }
        if old.showDockIcon != new.showDockIcon {
            changes.insert(.activationPolicy)
        }
        if old.doubleClickTitleBarToMaximize != new.doubleClickTitleBarToMaximize {
            changes.insert(.titleBar)
        }
        if old.layoutWheel != new.layoutWheel {
            changes.insert(.layoutWheel)
        }
        return changes
    }
}

public enum ConfigurationError: Error, LocalizedError, Equatable {
    case unsupportedFutureVersion(Int)
    case invalidAdjacencyTolerance
    case invalidDividerThickness
    case invalidBentoInnerGap
    case invalidBentoSwapHoverDelay
    case invalidSnapAreaBindings
    case shortcutConflict
    case invalidFile

    public var errorDescription: String? {
        switch self {
        case let .unsupportedFutureVersion(version): "This file uses unsupported configuration version \(version)."
        case .invalidAdjacencyTolerance: "Adjacency tolerance must be between 0 and 40 points."
        case .invalidDividerThickness: "Divider thickness must be between 2 and 12 points."
        case .invalidBentoInnerGap: "Bento inner gap must be between 0 and 12 points."
        case .invalidBentoSwapHoverDelay: "Bento swap delay must be between 0 and 1 second."
        case .invalidSnapAreaBindings: "Snap areas must contain one valid action or Disabled setting for every screen edge and corner."
        case .shortcutConflict: "Two actions use the same keyboard shortcut."
        case .invalidFile: "The selected file is not a BetterTile configuration."
        }
    }
}

public struct ConfigurationStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL) { self.fileURL = fileURL }

    public static func defaultStore(
        fileManager: FileManager = .default,
        directoryName: String = "BetterTile"
    ) -> ConfigurationStore {
        let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return ConfigurationStore(fileURL: applicationSupport.appending(path: "\(directoryName)/configuration.json"))
    }

    public func load(fileManager: FileManager = .default) throws -> BetterTileConfiguration {
        guard fileManager.fileExists(atPath: fileURL.path) else { return BetterTileConfiguration() }
        return try Self.decode(Data(contentsOf: fileURL))
    }

    public func save(_ configuration: BetterTileConfiguration, fileManager: FileManager = .default) throws {
        let validated = try configuration.validated()
        try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(validated).write(to: fileURL, options: [.atomic, .completeFileProtectionUnlessOpen])
    }

    public static func decode(_ data: Data) throws -> BetterTileConfiguration {
        struct VersionProbe: Decodable { let schemaVersion: Int? }
        let decoder = JSONDecoder()
        guard let version = try? decoder.decode(VersionProbe.self, from: data).schemaVersion else { throw ConfigurationError.invalidFile }
        guard version <= BetterTileConfiguration.currentSchemaVersion else { throw ConfigurationError.unsupportedFutureVersion(version) }
        do {
            return try decoder.decode(BetterTileConfiguration.self, from: data).validated()
        } catch let error as ConfigurationError {
            throw error
        } catch {
            throw ConfigurationError.invalidFile
        }
    }
}
