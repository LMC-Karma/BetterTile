import Foundation
import Testing
@testable import BetterTileCore

@Test func layoutModeDisplayNamesKeepTheirPersistedRawValues() {
    #expect(LayoutMode.manual.title == "Manual")
    #expect(LayoutMode.manual.rawValue == "manual")
    #expect(LayoutMode.bento.title == "Adaptive")
    #expect(LayoutMode.bento.rawValue == "bento")
}

@Test func glassTransparencyPreservesSavedFrostingDirection() throws {
    var appearance = try JSONDecoder().decode(OverlayAppearance.self, from: Data(#"{"useLiquidGlass":true,"strength":0.8}"#.utf8))
    #expect(abs(appearance.transparency - 0.2) < 0.0001)
    appearance.transparency = 1
    #expect(appearance.strength == 0)
    appearance.transparency = 0
    #expect(appearance.strength == 1)
    #expect(try JSONDecoder().decode(OverlayAppearance.self, from: JSONEncoder().encode(appearance)) == appearance)
}

@Test func legacyConfigurationEnablesSharedLiquidGlass() throws {
    let config = try ConfigurationStore.decode(Data(#"{"schemaVersion":12}"#.utf8))
    let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(config)) as? [String: Any])
    let appearance = try #require(json["overlayAppearance"] as? [String: Any])
    #expect(appearance["useLiquidGlass"] as? Bool == true)
    #expect(appearance["strength"] as? Double == 0.5)
}

@Test func liquidGlassPreferencesRoundTripWithoutRestartingGestures() throws {
    let original = BetterTileConfiguration()
    var changed = original
    changed.overlayAppearance = .init(useLiquidGlass: false, strength: 0.8)
    let restored = try ConfigurationStore.decode(JSONEncoder().encode(changed))
    #expect(restored.overlayAppearance == changed.overlayAppearance)
    #expect(ConfigurationChangeSet.between(original, changed) == [.overlayAppearance])
}

@Test(arguments: [-0.1, 1.1, Double.infinity, Double.nan])
func invalidGlassStrengthIsRejected(strength: Double) {
    var config = BetterTileConfiguration()
    config.overlayAppearance.strength = strength
    #expect(throws: ConfigurationError.invalidGlassStrength) { try config.validated() }
}

@Test func defaultConfigurationStoreCanUseAVariantDirectory() {
    let store = ConfigurationStore.defaultStore(directoryName: "BetterTile Debug")

    #expect(store.fileURL.lastPathComponent == "configuration.json")
    #expect(store.fileURL.deletingLastPathComponent().lastPathComponent == "BetterTile Debug")
}

@Test func inaccessibleConfigurationIsNotTreatedAsMissing() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let store = ConfigurationStore(fileURL: directory.appending(path: "configuration.json"))
    try store.save(BetterTileConfiguration())
    defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try? FileManager.default.removeItem(at: directory)
    }
    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: directory.path)

    #expect(throws: CocoaError.self) { try store.load() }
}

@Test func confirmedMissingConfigurationAndParentAllowDefaultsAndSaving() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = ConfigurationStore(fileURL: directory.appending(path: "nested/configuration.json"))
    #expect(try store.load() == BetterTileConfiguration())
    var configuration = BetterTileConfiguration()
    configuration.showDockIcon = true
    try store.save(configuration)
    #expect(try store.load() == configuration)
}

@Test func configurationAtomicRoundTrip() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = ConfigurationStore(fileURL: directory.appending(path: "configuration.json"))
    var configuration = BetterTileConfiguration()
    configuration.showDockIcon = true
    configuration.setupCompletionVersion = 1
    configuration.macOSTilingRecommendationAcknowledged = true
    configuration.stageManagerRecommendationAcknowledged = true
    configuration.singleWindowPlacement = .almostMaximize
    try store.save(configuration)
    #expect(try store.load() == configuration)
    #expect(!(try Data(contentsOf: store.fileURL)).contains(0x0A))
    configuration.showDockIcon = false
    configuration.singleWindowPlacement = .center
    try store.save(configuration)
    #expect(try store.load() == configuration)
    #expect(!(try Data(contentsOf: store.fileURL)).contains(0x0A))
}

@Test func schemaEightAddsPersistentSetupProgressWithoutRuntimeSideEffects() throws {
    let migrated = try ConfigurationStore.decode(JSONSerialization.data(withJSONObject: [
        "schemaVersion": 7,
    ]))
    #expect(migrated.schemaVersion == BetterTileConfiguration.currentSchemaVersion)
    #expect(migrated.setupCompletionVersion == 0)
    #expect(!migrated.macOSTilingRecommendationAcknowledged)
    #expect(!migrated.stageManagerRecommendationAcknowledged)

    var completed = migrated
    completed.setupCompletionVersion = 1
    completed.macOSTilingRecommendationAcknowledged = true
    completed.stageManagerRecommendationAcknowledged = true

    let roundTrip = try ConfigurationStore.decode(JSONEncoder().encode(completed))
    #expect(roundTrip == completed)
    #expect(ConfigurationChangeSet.between(migrated, completed).isEmpty)
}

@Test func menuBarActionsUseTheNativeDefaultOrderAndPreserveAnEmptyChoice() throws {
    let defaults = BetterTileConfiguration()
    #expect(defaults.menuBarActions == WindowAction.menuBarDefaultOrder)
    #expect(defaults.menuBarActions.count == 35)

    var customized = defaults
    customized.menuBarActions = [.rightHalf, .rightHalf, .leftHalf]
    let decoded = try ConfigurationStore.decode(JSONEncoder().encode(customized))
    #expect(decoded.menuBarActions == [.rightHalf, .leftHalf])

    customized.menuBarActions = []
    let empty = try ConfigurationStore.decode(JSONEncoder().encode(customized))
    #expect(empty.menuBarActions.isEmpty)

    let unknown = try ConfigurationStore.decode(JSONSerialization.data(withJSONObject: [
        "schemaVersion": BetterTileConfiguration.currentSchemaVersion,
        "menuBarActions": ["rightHalf", "futureAction", "rightHalf", "leftHalf"],
    ]))
    #expect(unknown.menuBarActions == [.rightHalf, .leftHalf])
}

@Test func olderConfigurationMigratesMissingMenuBarActionsToDefaults() throws {
    let migrated = try ConfigurationStore.decode(JSONSerialization.data(withJSONObject: [
        "schemaVersion": 10,
    ]))
    let explicitNull = try ConfigurationStore.decode(JSONSerialization.data(withJSONObject: [
        "schemaVersion": 10,
        "menuBarActions": NSNull(),
    ]))
    #expect(migrated.schemaVersion == BetterTileConfiguration.currentSchemaVersion)
    #expect(migrated.menuBarActions == WindowAction.menuBarDefaultOrder)
    #expect(explicitNull.menuBarActions == WindowAction.menuBarDefaultOrder)
}

@Test func malformedMenuBarActionContainersFollowTheConfigurationErrorPath() throws {
    let objects: [[String: Any]] = [
        ["menuBarActions": ["leftHalf", 7]],
        ["menuBarActions": ["action": "leftHalf"]],
    ]
    for var object in objects {
        object["schemaVersion"] = BetterTileConfiguration.currentSchemaVersion
        do {
            _ = try ConfigurationStore.decode(JSONSerialization.data(withJSONObject: object))
            Issue.record("Malformed menu action data must not reset the rest of the configuration.")
        } catch ConfigurationError.invalidFile {
            // The normal decoding error path is the expected result.
        }
    }
}

@Test func configurationMutationsSelectOnlyTheirRuntimeDomains() {
    let original = BetterTileConfiguration()
    let mutations: [(ConfigurationChangeSet, (inout BetterTileConfiguration) -> Void)] = [
        ([.activationPolicy], { $0.showDockIcon.toggle() }),
        ([.snapping], { $0.snappingEnabled.toggle() }),
        ([.linkedResize], { $0.linkedResizeEnabled.toggle() }),
        ([.bentoGeometry], { $0.defaultLayoutMode = .bento }),
        ([.bentoGeometry], { $0.singleWindowPlacement = .almostMaximize }),
        ([.divider], { $0.resizeFeedbackMode = .live }),
        ([.divider], { $0.dividerVisibility = .dragOnly }),
        ([.divider], { $0.dividerThickness = 10 }),
        ([.overlayAppearance], { $0.overlayAppearance.useLiquidGlass = false }),
        ([.overlayAppearance], { $0.overlayAppearance.strength = 0.8 }),
        ([.bentoGeometry], { $0.bentoInnerGap = 4 }),
        ([.bentoGeometry], { $0.bentoSwapHoverDelay = 0.3 }),
        ([.snapping], { $0.snapSuppressionModifiers = .command }),
        ([.linkedResize, .divider, .bentoGeometry], { $0.adjacencyTolerance = 8 }),
        ([.snapping], { $0.snapAreaBindings[0].action = nil }),
        ([.snapping], { $0.snapEdgeActivationDistance = 40 }),
        ([.snapping], { $0.snapCornerActivationSize = 160 }),
        ([.titleBar], { $0.doubleClickTitleBarToMaximize.toggle() }),
        ([.shortcuts], { $0.shortcuts[0].shortcut = nil }),
        ([.shortcuts], { $0.keyboardShortcutsEnabled = false }),
        ([.applicationRules], { $0.applicationRules.set(.ignoreEverywhere, for: "test.application") }),
        ([.accessibilityWrites], { $0.enhancedUserInterfacePolicy = .disableOnly }),
        ([], { $0.defaultTabbedPreset = .columns }),
        ([], { $0.bentoNewWindowSide = .left }),
        ([], { $0.setupCompletionVersion = 1 }),
        ([], { $0.macOSTilingRecommendationAcknowledged = true }),
        ([], { $0.stageManagerRecommendationAcknowledged = true }),
        ([.layoutWheel], { $0.layoutWheel.levelCount = .two }),
        ([.menuBarIcon], { $0.showMenuBarIcon.toggle() }),
        ([], { $0.accessibilityPromptRequested = true }),
    ]

    for (expected, mutation) in mutations {
        var changed = original
        mutation(&changed)
        #expect(ConfigurationChangeSet.between(original, changed) == expected)
    }

    #expect(ConfigurationChangeSet.between(original, original).isEmpty)

    var menuOnly = original
    menuOnly.menuBarActions = [.rightHalf, .leftHalf]
    #expect(ConfigurationChangeSet.between(original, menuOnly).isEmpty)
}

@Test func futureConfigurationIsRejected() throws {
    let data = try JSONSerialization.data(withJSONObject: ["schemaVersion": 999])
    #expect(throws: ConfigurationError.unsupportedFutureVersion(999)) { try ConfigurationStore.decode(data) }
}

@Test func legacyCustomZonesAreIgnoredAndNotPersisted() throws {
    let legacy = try JSONSerialization.data(withJSONObject: [
        "schemaVersion": BetterTileConfiguration.currentSchemaVersion,
        "customZones": [[
            "id": UUID().uuidString,
            "name": "Legacy",
            "rect": ["x": 0, "y": 0, "width": 1, "height": 1],
        ]],
    ])
    let decoded = try ConfigurationStore.decode(legacy)
    let object = try #require(
        JSONSerialization.jsonObject(with: try JSONEncoder().encode(decoded)) as? [String: Any]
    )

    #expect(object["customZones"] == nil)
}

@Test func schemaTenAddsLayoutWheelDefaults() throws {
    let migrated = try ConfigurationStore.decode(JSONSerialization.data(withJSONObject: [
        "schemaVersion": 9,
    ]))

    #expect(migrated.schemaVersion == BetterTileConfiguration.currentSchemaVersion)
    #expect(migrated.layoutWheel == LayoutWheelConfiguration())
    #expect(migrated.layoutWheel.levelCount == .one)
    #expect(migrated.layoutWheel.innerSlots == LayoutWheelConfiguration.defaultInnerSlots)
    #expect(migrated.layoutWheel.outerSlots == LayoutWheelConfiguration.defaultOuterSlots)
    #expect(migrated.layoutWheel.keyboardModifiers == [.control, .option, .shift])
    #expect(migrated.layoutWheel.keyboardTriggerEnabled)
    #expect(!migrated.layoutWheel.middleClickTriggerEnabled)
}

@Test func layoutWheelConfigurationRoundTrips() throws {
    var configuration = BetterTileConfiguration()
    configuration.layoutWheel = LayoutWheelConfiguration(
        isEnabled: false,
        levelCount: .one,
        innerSlots: [
            .windowAction(.leftHalf),
            .windowAction(.rightHalf),
            nil, nil, nil, nil, nil, nil,
        ],
        outerSlots: LayoutWheelConfiguration.defaultOuterSlots,
        keyboardTriggerEnabled: false,
        keyboardModifiers: [.command, .shift],
        middleClickTriggerEnabled: true
    )

    let decoded = try ConfigurationStore.decode(JSONEncoder().encode(configuration))
    #expect(decoded == configuration)
}

@Test func layoutWheelConfigurationNormalizesUnsafeValues() throws {
    var configuration = BetterTileConfiguration()
    configuration.layoutWheel.innerSlots = [.repairBento]
    configuration.layoutWheel.outerSlots = []
    configuration.layoutWheel.keyboardModifiers = ShortcutModifiers(
        rawValue: ShortcutModifiers.control.rawValue | (1 << 20)
    )

    let normalized = try configuration.validated().layoutWheel
    #expect(normalized.innerSlots == LayoutWheelConfiguration.defaultInnerSlots)
    #expect(normalized.outerSlots == LayoutWheelConfiguration.defaultOuterSlots)
    #expect(normalized.keyboardModifiers == [.control, .option, .shift])
}

@Test func layoutWheelScaleDefaultsForOldConfigurationsAndClampsUnsafeValues() throws {
    let oldData = try JSONSerialization.data(withJSONObject: [
        "isEnabled": true,
        "levelCount": 2,
        "innerSlots": [],
        "outerSlots": [],
    ])
    let oldWheel = try JSONDecoder().decode(LayoutWheelConfiguration.self, from: oldData)
    #expect(oldWheel.scale == LayoutWheelConfiguration.defaultScale)

    var configuration = BetterTileConfiguration()
    configuration.layoutWheel.scale = 10
    #expect(try configuration.validated().layoutWheel.scale == LayoutWheelConfiguration.maximumScale)
    configuration.layoutWheel.scale = -10
    #expect(try configuration.validated().layoutWheel.scale == LayoutWheelConfiguration.minimumScale)
}

@Test func layoutWheelCanSwapInnerAndOuterAssignments() {
    var wheel = LayoutWheelConfiguration(
        innerSlots: LayoutWheelConfiguration.defaultOuterSlots,
        outerSlots: LayoutWheelConfiguration.defaultInnerSlots
    )
    let inner = wheel.innerSlots
    wheel.swapRings()
    #expect(wheel.innerSlots == LayoutWheelConfiguration.defaultInnerSlots)
    #expect(wheel.outerSlots == inner)
}

@Test func legacyCustomZoneAssignmentsAreRemovedDuringValidation() throws {
    var configuration = BetterTileConfiguration()
    configuration.layoutWheel.innerSlots = [
        .customZone(UUID()),
        .windowAction(.leftHalf),
        .customZone(UUID()),
        nil, nil, nil, nil, nil,
    ]

    let normalized = try configuration.validated()
    #expect(normalized.layoutWheel.innerSlots[0] == nil)
    #expect(normalized.layoutWheel.innerSlots[1] == .windowAction(.leftHalf))
    #expect(normalized.layoutWheel.innerSlots[2] == nil)
}

@Test func schemaNineWidensTheSingleWindowPlacementToTheActionList() throws {
    // The three cases stored by schemas 5 to 8 map onto the wider list.
    let almost = try ConfigurationStore.decode(JSONSerialization.data(withJSONObject: [
        "schemaVersion": 8,
        "singleWindowInitialPlacement": "almostMaximize",
    ]))
    #expect(almost.schemaVersion == BetterTileConfiguration.currentSchemaVersion)
    #expect(almost.singleWindowPlacement == .almostMaximize)

    let unchanged = try ConfigurationStore.decode(JSONSerialization.data(withJSONObject: [
        "schemaVersion": 8,
        "singleWindowInitialPlacement": "unchanged",
    ]))
    #expect(unchanged.singleWindowPlacement == nil)

    let absent = try ConfigurationStore.decode(JSONSerialization.data(withJSONObject: [
        "schemaVersion": 8,
    ]))
    #expect(absent.singleWindowPlacement == .maximize)

    // The legacy key is read once and never written again.
    let object = try #require(
        JSONSerialization.jsonObject(with: try JSONEncoder().encode(almost)) as? [String: Any]
    )
    #expect(object["singleWindowInitialPlacement"] == nil)
    #expect(object["singleWindowPlacement"] as? String == "almostMaximize")
}

@Test func aSingleWindowPlacementCanBeAnyPositioningAction() throws {
    let centered = try ConfigurationStore.decode(JSONSerialization.data(withJSONObject: [
        "schemaVersion": 9,
        "singleWindowPlacement": "centerResize",
    ]))
    #expect(centered.singleWindowPlacement == .centerResize)

    let unchanged = try ConfigurationStore.decode(JSONSerialization.data(withJSONObject: [
        "schemaVersion": 9,
    ]))
    #expect(unchanged.singleWindowPlacement == nil)
}

@Test func aRelativeActionIsNotAcceptedAsASingleWindowPlacement() throws {
    // Move, grow, shrink, display transfer and restore all describe a change to
    // an existing frame, so they cannot describe where a lone window belongs.
    for relative in WindowAction.allCases where !WindowAction.snapAssignableActions.contains(relative) {
        let decoded = try ConfigurationStore.decode(JSONSerialization.data(withJSONObject: [
            "schemaVersion": 9,
            "singleWindowPlacement": relative.rawValue,
        ]))
        #expect(decoded.singleWindowPlacement == .maximize)
    }

    var handEdited = BetterTileConfiguration()
    handEdited.singleWindowPlacement = .growWidth
    #expect(try handEdited.validated().singleWindowPlacement == .maximize)
}

@Test func versionOneConfigurationMigratesWithoutPersistingWindowIDs() throws {
    let legacy: [String: Any] = [
        "schemaVersion": 1,
        "showDockIcon": true,
        "layoutMode": "bento",
        "bentoEnabled": true,
        "bentoStates": ["main": ["floatingWindowIDs": []]],
    ]
    let migrated = try ConfigurationStore.decode(JSONSerialization.data(withJSONObject: legacy))
    #expect(migrated.schemaVersion == BetterTileConfiguration.currentSchemaVersion)
    #expect(migrated.showDockIcon)
    #expect(!migrated.linkedResizeEnabled)
    #expect(migrated.defaultLayoutMode == .bento)
    #expect(migrated.resizeFeedbackMode == .ghost)
    #expect(migrated.dividerVisibility == .hoverAndDrag)
    #expect(migrated.dividerThickness == 6)
    #expect(migrated.bentoSwapHoverDelay == 0.12)
    #expect(migrated.singleWindowPlacement == .maximize)
    #expect(migrated.snapAreaBindings.first(where: { $0.area == .top })?.action == .almostMaximize)
    #expect(migrated.doubleClickTitleBarToMaximize)

    let encoded = try JSONEncoder().encode(migrated)
    let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    #expect(object["layoutMode"] == nil)
    #expect(object["bentoEnabled"] == nil)
    #expect(object["bentoStates"] == nil)
}

@Test func versionTwoDefaultShortcutsMigrateToStandardDefaults() throws {
    let encodedBindings = try JSONEncoder().encode(BetterTileConfiguration.legacyDefaultShortcutsV2)
    let bindingsObject = try #require(JSONSerialization.jsonObject(with: encodedBindings) as? [[String: Any]])
    let data = try JSONSerialization.data(withJSONObject: [
        "schemaVersion": 2,
        "shortcuts": bindingsObject,
    ])

    let migrated = try ConfigurationStore.decode(data)
    #expect(migrated.shortcuts.first(where: { $0.action == .maximize })?.shortcut?.keyCode == 36)
    #expect(migrated.shortcuts.first(where: { $0.action == .topLeftQuarter })?.shortcut?.keyLabel == "U")
    #expect(migrated.shortcuts.first(where: { $0.action == .restore })?.shortcut?.keyCode == 51)
}

@Test func versionTwoCustomShortcutsArePreserved() throws {
    let custom = [ShortcutBinding(
        action: .maximize,
        shortcut: KeyboardShortcut(keyCode: 11, modifiers: [.control, .option], keyLabel: "B")
    )]
    let encodedBindings = try JSONEncoder().encode(custom)
    let bindingsObject = try #require(JSONSerialization.jsonObject(with: encodedBindings) as? [[String: Any]])
    let data = try JSONSerialization.data(withJSONObject: [
        "schemaVersion": 2,
        "shortcuts": bindingsObject,
    ])

    let migrated = try ConfigurationStore.decode(data)
    #expect(migrated.shortcuts == custom)
}

@Test func resizeInteractionConfigurationIsValidated() {
    var configuration = BetterTileConfiguration()
    configuration.dividerThickness = 20
    #expect(throws: ConfigurationError.invalidDividerThickness) { try configuration.validated() }
    configuration.dividerThickness = 6
    configuration.bentoSwapHoverDelay = 2
    #expect(throws: ConfigurationError.invalidBentoSwapHoverDelay) { try configuration.validated() }
    configuration.bentoSwapHoverDelay = 0.12
}

@Test func versionThreeConfigurationAdvancesWithoutChangingSwapDelay() throws {
    let oldDefault = try ConfigurationStore.decode(JSONSerialization.data(withJSONObject: [
        "schemaVersion": 3,
        "bentoSwapHoverDelay": 0.12,
    ]))
    #expect(oldDefault.schemaVersion == BetterTileConfiguration.currentSchemaVersion)
    #expect(oldDefault.bentoSwapHoverDelay == 0.12)

    let customized = try ConfigurationStore.decode(JSONSerialization.data(withJSONObject: [
        "schemaVersion": 3,
        "bentoSwapHoverDelay": 0.4,
    ]))
    #expect(customized.bentoSwapHoverDelay == 0.4)
}

@Test func shortLivedVersionFourGestureDefaultsRollBackCleanly() throws {
    let configuration = try ConfigurationStore.decode(JSONSerialization.data(withJSONObject: [
        "schemaVersion": 4,
        "bentoInnerGap": 8,
        "bentoSwapHoverDelay": 0.25,
        "dockReservationMode": "always",
        "singleWindowInitialPlacement": "unchanged",
    ]))
    #expect(configuration.bentoSwapHoverDelay == 0.12)
    #expect(configuration.bentoInnerGap == 0)
    #expect(configuration.singleWindowPlacement == .maximize)
    #expect(!configuration.leavesSpaceForDock)
}

@Test func leaveSpaceForDockIsOffByDefaultAndRoundTrips() throws {
    let missing = try ConfigurationStore.decode(Data(#"{"schemaVersion":12}"#.utf8))
    #expect(!missing.leavesSpaceForDock)
    var changed = missing
    changed.leavesSpaceForDock = true
    #expect(try ConfigurationStore.decode(JSONEncoder().encode(changed)).leavesSpaceForDock)
    #expect(ConfigurationChangeSet.between(missing, changed) == [.workArea])
}

@Test func menuBarIconIsOnForEarlierConfigurationsAndRoundTrips() throws {
    #expect(BetterTileConfiguration().showMenuBarIcon)
    // A schema 12 file written before the setting existed keeps the icon.
    let missing = try ConfigurationStore.decode(Data(#"{"schemaVersion":12,"showDockIcon":false}"#.utf8))
    #expect(missing.showMenuBarIcon)
    // Older schemas migrate with the icon on as well.
    let older = try ConfigurationStore.decode(JSONSerialization.data(withJSONObject: ["schemaVersion": 7]))
    #expect(older.showMenuBarIcon)
    var hidden = missing
    hidden.showMenuBarIcon = false
    let decoded = try ConfigurationStore.decode(JSONEncoder().encode(hidden))
    #expect(!decoded.showMenuBarIcon)
    #expect(decoded == hidden)
    #expect(ConfigurationChangeSet.between(missing, hidden) == [.menuBarIcon])
}

@Test func accessibilityPromptRequestIsOffForEarlierConfigurationsAndRoundTrips() throws {
    let missing = try ConfigurationStore.decode(Data(#"{"schemaVersion":12}"#.utf8))
    #expect(!missing.accessibilityPromptRequested)
    var requested = missing
    requested.accessibilityPromptRequested = true
    #expect(try ConfigurationStore.decode(JSONEncoder().encode(requested)).accessibilityPromptRequested)
}

@Test func schemaSixAddsGapAndKeepsExistingResizeFeedbackChoice() throws {
    let existing = try ConfigurationStore.decode(JSONSerialization.data(withJSONObject: [
        "schemaVersion": 5,
        "resizeFeedbackMode": "ghost",
    ]))
    #expect(existing.resizeFeedbackMode == .ghost)
    #expect(existing.bentoInnerGap == 0)

    let versionSix = try ConfigurationStore.decode(JSONSerialization.data(withJSONObject: [
        "schemaVersion": 6,
        "bentoInnerGap": 9,
        "resizeFeedbackMode": "live",
    ]))
    #expect(versionSix.bentoInnerGap == 9)
    #expect(versionSix.resizeFeedbackMode == .live)
}

@Test func linkedModeMigratesToNativeAndKeepsResizeOption() throws {
    let data = try JSONSerialization.data(withJSONObject: [
        "schemaVersion": 2,
        "defaultLayoutMode": "linked",
        "linkedResizeEnabled": true,
    ])

    let configuration = try ConfigurationStore.decode(data)
    #expect(configuration.defaultLayoutMode == .manual)
    #expect(configuration.linkedResizeEnabled)
    #expect(LayoutMode.availableModes == [.manual, .bento, .tabbed])

    let roundTrip = try ConfigurationStore.decode(JSONEncoder().encode(configuration))
    #expect(roundTrip.linkedResizeEnabled)
}

@Test func tabbedModeRemainsAvailableAfterConfigurationRoundTrip() throws {
    let data = try JSONSerialization.data(withJSONObject: [
        "schemaVersion": BetterTileConfiguration.currentSchemaVersion,
        "defaultLayoutMode": "tabbed-v1",
    ])
    let configuration = try ConfigurationStore.decode(data)
    #expect(LayoutMode.availableModes.contains(.tabbed))
    #expect(LayoutMode.tabbed.title == "Tabbed")
    #expect(configuration.defaultLayoutMode == .tabbed)

    let roundTrip = try ConfigurationStore.decode(JSONEncoder().encode(configuration))
    #expect(roundTrip.defaultLayoutMode == .tabbed)
}

@Test func freshInstallUsesRecommendedResizeDefaults() {
    let configuration = BetterTileConfiguration()
    #expect(configuration.linkedResizeEnabled)
    #expect(configuration.resizeFeedbackMode == .ghost)
    #expect(configuration.dividerThickness == 8)
    #expect(configuration.bentoInnerGap == 1)
    #expect(configuration.bentoSwapHoverDelay == 0.12)
}

@Test func removedTabbedModeMigratesToBento() throws {
    let data = try JSONSerialization.data(withJSONObject: [
        "schemaVersion": 7,
        "defaultLayoutMode": "tabbed",
        "tabbedArrangement": "focus",
    ])

    let configuration = try ConfigurationStore.decode(data)
    #expect(configuration.defaultLayoutMode == .bento)
    let encoded = try #require(
        JSONSerialization.jsonObject(with: JSONEncoder().encode(configuration)) as? [String: Any]
    )
    #expect(encoded["tabbedArrangement"] == nil)
}

@Test func removedSavedLayoutsAreIgnoredAndNotReencoded() throws {
    let data = try JSONSerialization.data(withJSONObject: [
        "schemaVersion": 7,
        "automaticProfilesEnabled": true,
        "appLayoutProfiles": [[
            "id": UUID().uuidString,
            "name": "Work",
            "appliesAutomatically": true,
            "entries": [],
        ]],
    ])

    let configuration = try ConfigurationStore.decode(data)
    let encoded = try #require(
        JSONSerialization.jsonObject(with: JSONEncoder().encode(configuration)) as? [String: Any]
    )
    #expect(encoded["automaticProfilesEnabled"] == nil)
    #expect(encoded["appLayoutProfiles"] == nil)
}

@Test func legacyDividerVisibilityNormalizesToHoverOnly() throws {
    let data = try JSONSerialization.data(withJSONObject: [
        "schemaVersion": 2,
        "dividerVisibility": "always",
    ])
    #expect(try ConfigurationStore.decode(data).dividerVisibility == .hoverAndDrag)

    var configuration = BetterTileConfiguration()
    configuration.dividerVisibility = .dragOnly
    #expect(try configuration.validated().dividerVisibility == .hoverAndDrag)
}

@Test func shortcutConflictIsRejected() {
    let shortcut = KeyboardShortcut(keyCode: 1, modifiers: [.control, .option], keyLabel: "S")
    var configuration = BetterTileConfiguration()
    configuration.shortcuts = [
        ShortcutBinding(action: .leftHalf, shortcut: shortcut),
        ShortcutBinding(action: .rightHalf, shortcut: shortcut),
    ]
    #expect(throws: ConfigurationError.shortcutConflict) { try configuration.validated() }
    #expect(ShortcutValidator.conflicts(in: configuration.shortcuts).first?.actions == [.leftHalf, .rightHalf])
}

@Test func newWindowSideDefaultsAndRoundTripsWithoutReconfiguringCurrentWindows() throws {
    let legacy = try ConfigurationStore.decode(JSONSerialization.data(withJSONObject: [
        "schemaVersion": BetterTileConfiguration.currentSchemaVersion,
    ]))
    #expect(legacy.bentoNewWindowSide == .automatic)
    for side in BentoNewWindowSide.allCases {
        var changed = legacy
        changed.bentoNewWindowSide = side
        #expect(try ConfigurationStore.decode(JSONEncoder().encode(changed)).bentoNewWindowSide == side)
        // Read at insertion time; changing it must not restart gestures or reflow.
        #expect(ConfigurationChangeSet.between(legacy, changed).isEmpty)
    }
}

@Test func balanceOnNewWindowDefaultsOffAndRoundTripsWithoutReconfiguringCurrentWindows() throws {
    let legacy = try ConfigurationStore.decode(JSONSerialization.data(withJSONObject: [
        "schemaVersion": BetterTileConfiguration.currentSchemaVersion,
    ]))
    #expect(!legacy.bentoBalancesNewWindows)
    var changed = legacy
    changed.bentoBalancesNewWindows = true
    #expect(try ConfigurationStore.decode(JSONEncoder().encode(changed)).bentoBalancesNewWindows)
    // Read at insertion time; changing it must not restart gestures or reflow.
    #expect(ConfigurationChangeSet.between(legacy, changed).isEmpty)
}

@Test func snapActivationSettingsRoundTripIndependently() throws {
    let original = BetterTileConfiguration()
    for (edge, corner) in [(40.0, 64.0), (5, 160), (1, 16)] {
        var configuration = original
        configuration.snapEdgeActivationDistance = edge
        configuration.snapCornerActivationSize = corner
        let decoded = try ConfigurationStore.decode(JSONEncoder().encode(configuration))
        #expect(decoded == configuration)
        #expect(decoded.snapAreaBindings == original.snapAreaBindings)
        #expect(ConfigurationChangeSet.between(original, decoded) == [.snapping])
    }
}

@Test(arguments: [1, 7, 12])
func oldConfigurationKeepsTheOriginalSnapActivationArea(version: Int) throws {
    let decoded = try ConfigurationStore.decode(JSONSerialization.data(withJSONObject: ["schemaVersion": version]))
    #expect(decoded.snapEdgeActivationDistance == 5)
    #expect(decoded.snapCornerActivationSize == 64)
    let detector = SnapZoneDetector(edgeActivationDistance: decoded.snapEdgeActivationDistance,
                                    cornerActivationSize: decoded.snapCornerActivationSize)
    #expect(detector.edgeActivationDistance == SnapZoneDetector().edgeActivationDistance)
    #expect(detector.cornerActivationSize == SnapZoneDetector().cornerActivationSize)
}

@Test(arguments: [-1.0, 0, 41, Double.infinity, Double.nan])
func invalidSnapEdgeWidthIsRejected(value: Double) {
    var configuration = BetterTileConfiguration()
    configuration.snapEdgeActivationDistance = value
    #expect(throws: ConfigurationError.invalidSnapEdgeActivationDistance) { try configuration.validated() }
}

@Test(arguments: [0.0, 15, 161, Double.infinity, Double.nan])
func invalidSnapCornerExtensionIsRejected(value: Double) {
    var configuration = BetterTileConfiguration()
    configuration.snapCornerActivationSize = value
    #expect(throws: ConfigurationError.invalidSnapCornerActivationSize) { try configuration.validated() }
}

@Test func invalidSnapActivationFileDoesNotSilentlyResetPreferences() throws {
    for (key, value) in [("snapEdgeActivationDistance", 41), ("snapCornerActivationSize", 15)] {
        #expect(throws: (any Error).self) {
            try ConfigurationStore.decode(JSONSerialization.data(withJSONObject: [key: value, "showDockIcon": true, "schemaVersion": 12]))
        }
    }
    #expect(throws: ConfigurationError.invalidFile) {
        try ConfigurationStore.decode(Data(#"{"schemaVersion":12,"snapEdgeActivationDistance":"wide"}"#.utf8))
    }
}

private let placementActionIDsBeforeTabCommands = [
    "leftHalf", "rightHalf", "topHalf", "bottomHalf",
    "leftThird", "centerThird", "rightThird", "leftTwoThirds", "rightTwoThirds",
    "topLeftQuarter", "topRightQuarter", "bottomLeftQuarter", "bottomRightQuarter",
    "topLeftSixth", "topCenterSixth", "topRightSixth",
    "bottomLeftSixth", "bottomCenterSixth", "bottomRightSixth",
    "maximize", "almostMaximize", "center", "centerResize", "previousDisplay", "nextDisplay",
    "moveLeft", "moveRight", "moveUp", "moveDown", "growWidth", "shrinkWidth", "growHeight", "shrinkHeight", "restore",
]

@Test func tabCommandsLeaveEveryExistingDefaultShortcutUnchanged() {
    let defaults = BetterTileConfiguration.defaultShortcuts
    #expect(defaults.prefix(34).map { $0.action.rawValue } == placementActionIDsBeforeTabCommands)
    let expected: [(String, UInt32, ShortcutModifiers, String)] = [
        ("leftHalf", 123, [.control, .option], "←"), ("rightHalf", 124, [.control, .option], "→"),
        ("topHalf", 126, [.control, .option], "↑"), ("bottomHalf", 125, [.control, .option], "↓"),
        ("topLeftQuarter", 32, [.control, .option], "U"), ("topRightQuarter", 34, [.control, .option], "I"),
        ("bottomLeftQuarter", 38, [.control, .option], "J"), ("bottomRightQuarter", 40, [.control, .option], "K"),
        ("maximize", 36, [.control, .option], "↩"), ("restore", 51, [.control, .option], "⌫"),
        ("center", 8, [.control, .option], "C"), ("leftThird", 2, [.control, .option], "D"),
        ("leftTwoThirds", 14, [.control, .option], "E"), ("centerThird", 3, [.control, .option], "F"),
        ("rightThird", 5, [.control, .option], "G"), ("rightTwoThirds", 17, [.control, .option], "T"),
        ("growWidth", 24, [.control, .option], "="), ("shrinkWidth", 27, [.control, .option], "-"),
        ("nextDisplay", 124, [.control, .option, .command], "→"),
        ("previousDisplay", 123, [.control, .option, .command], "←"),
    ]
    #expect(defaults.filter { $0.shortcut != nil }.count == expected.count)
    for (id, key, modifiers, label) in expected {
        #expect(defaults.first { $0.action.rawValue == id }?.shortcut
            == KeyboardShortcut(keyCode: key, modifiers: modifiers, keyLabel: label))
    }
    #expect(defaults.filter { $0.action.isTabCommand }.map(\.action) == WindowAction.tabCommands)
    #expect(defaults.filter { $0.action.isTabCommand }.allSatisfy { $0.shortcut == nil })
    #expect(BetterTileConfiguration.legacyDefaultShortcutsV2.count == 34)
    #expect(!LayoutWheelConfiguration.defaultInnerSlots.contains { command in
        if case let .windowAction(action) = command { return action.isTabCommand }
        return false
    })
    #expect(!LayoutWheelConfiguration.defaultOuterSlots.contains { command in
        if case let .windowAction(action) = command { return action.isTabCommand }
        return false
    })
}

@Test func oldShortcutOrderAndWheelAssignmentsSurviveAddingTabCommands() throws {
    var saved = BetterTileConfiguration()
    saved.shortcuts = placementActionIDsBeforeTabCommands.reversed().compactMap(WindowAction.init(rawValue:))
        .map { ShortcutBinding(action: $0, shortcut: nil) }
    saved.shortcuts[0].shortcut = .init(keyCode: 11, modifiers: [.control, .command], keyLabel: "B")
    saved.layoutWheel.levelCount = .two
    saved.layoutWheel.innerSlots = [.repairBento, nil, .windowAction(.center), nil, nil, nil, nil, .windowAction(.restore)]
    saved.layoutWheel.outerSlots = [nil, .windowAction(.nextDisplay), nil, nil, .windowAction(.moveLeft), nil, nil, nil]
    saved.menuBarActions = [.restore, .center, .leftHalf]
    let restored = try ConfigurationStore.decode(JSONEncoder().encode(saved))
    #expect(restored == saved)
    #expect(restored.shortcuts.map(\.action) == saved.shortcuts.map(\.action))
    #expect(restored.shortcuts.filter { $0.action.isTabCommand }.isEmpty)
    #expect(restored.layoutWheel == saved.layoutWheel)
    #expect(try ConfigurationStore.decode(JSONEncoder().encode(restored)) == saved)
}

@Test func assignedTabCommandsRoundTripWithoutAConfigurationSchemaChange() throws {
    var saved = BetterTileConfiguration()
    for (index, action) in WindowAction.tabCommands.enumerated() {
        let binding = try #require(saved.shortcuts.firstIndex { $0.action == action })
        saved.shortcuts[binding].shortcut = .init(keyCode: UInt32(index), modifiers: [.control, .shift], keyLabel: "\(index)")
        saved.layoutWheel.innerSlots[index] = .windowAction(action)
    }
    saved.menuBarActions = WindowAction.tabCommands
    #expect(try ConfigurationStore.decode(JSONEncoder().encode(saved)) == saved)
    #expect(saved.schemaVersion == 12)
}
