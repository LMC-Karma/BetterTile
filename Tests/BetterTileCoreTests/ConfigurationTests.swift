import Foundation
import Testing
@testable import BetterTileCore

@Test func defaultConfigurationStoreCanUseAVariantDirectory() {
    let store = ConfigurationStore.defaultStore(directoryName: "BetterTile Debug")

    #expect(store.fileURL.lastPathComponent == "configuration.json")
    #expect(store.fileURL.deletingLastPathComponent().lastPathComponent == "BetterTile Debug")
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
    configuration.customZones = [CustomZone(name: "Focus", rect: NormalizedRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8))]
    try store.save(configuration)
    #expect(try store.load() == configuration)
}

@Test func schemaEightAddsPersistentSetupProgressWithoutRuntimeSideEffects() throws {
    let migrated = try ConfigurationStore.decode(JSONSerialization.data(withJSONObject: [
        "schemaVersion": 7,
    ]))
    #expect(migrated.schemaVersion == 10)
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

@Test func configurationChangesClassifyOnlyAffectedRuntimeDomains() {
    let original = BetterTileConfiguration()

    var changed = original
    changed.shortcuts[0].shortcut = nil
    #expect(ConfigurationChangeSet.between(original, changed) == [.shortcuts])

    changed = original
    changed.snappingEnabled.toggle()
    #expect(ConfigurationChangeSet.between(original, changed) == [.snapping])

    changed = original
    changed.linkedResizeEnabled.toggle()
    #expect(ConfigurationChangeSet.between(original, changed) == [.linkedResize])

    changed = original
    changed.dividerThickness = 8
    #expect(ConfigurationChangeSet.between(original, changed) == [.divider])

    changed = original
    changed.bentoInnerGap = 4
    #expect(ConfigurationChangeSet.between(original, changed) == [.bentoGeometry])

    changed = original
    changed.showDockIcon.toggle()
    #expect(ConfigurationChangeSet.between(original, changed) == [.activationPolicy])

    changed = original
    changed.doubleClickTitleBarToMaximize.toggle()
    #expect(ConfigurationChangeSet.between(original, changed) == [.titleBar])

    changed = original
    changed.layoutWheel.levelCount = .one
    #expect(ConfigurationChangeSet.between(original, changed) == [.layoutWheel])

    changed = original
    changed.adjacencyTolerance = 8
    #expect(
        ConfigurationChangeSet.between(original, changed)
            == [.linkedResize, .divider, .bentoGeometry]
    )

    #expect(ConfigurationChangeSet.between(original, original).isEmpty)
}

@Test func everyPersistedConfigurationFieldHasARuntimeChangeDomain() {
    let original = BetterTileConfiguration()
    let mutations: [(ConfigurationChangeSet, (inout BetterTileConfiguration) -> Void)] = [
        ([.activationPolicy], { $0.showDockIcon.toggle() }),
        ([.snapping], { $0.snappingEnabled.toggle() }),
        ([.linkedResize], { $0.linkedResizeEnabled.toggle() }),
        ([.bentoGeometry], { $0.defaultLayoutMode = .bento }),
        ([.bentoGeometry], { $0.singleWindowPlacement = .almostMaximize }),
        ([.divider], { $0.resizeFeedbackMode = .live }),
        ([.divider], { $0.dividerVisibility = .dragOnly }),
        ([.divider], { $0.dividerThickness = 8 }),
        ([.bentoGeometry], { $0.bentoInnerGap = 4 }),
        ([.bentoGeometry], { $0.bentoSwapHoverDelay = 0.3 }),
        ([.snapping], { $0.snapSuppressionModifiers = .command }),
        ([.linkedResize, .divider, .bentoGeometry], { $0.adjacencyTolerance = 8 }),
        ([.snapping], { $0.snapAreaBindings[0].action = nil }),
        ([.titleBar], { $0.doubleClickTitleBarToMaximize.toggle() }),
        ([.shortcuts], { $0.shortcuts[0].shortcut = nil }),
        ([.snapping, .layoutWheel], {
            $0.customZones = [
                CustomZone(
                    name: "Test",
                    rect: NormalizedRect(x: 0, y: 0, width: 0.5, height: 0.5)
                ),
            ]
        }),
        ([.layoutWheel], { $0.layoutWheel.levelCount = .one }),
    ]

    for (expected, mutation) in mutations {
        var changed = original
        mutation(&changed)
        #expect(ConfigurationChangeSet.between(original, changed) == expected)
    }
}

@Test func internalConfigurationStorageIsCompact() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let storeURL = directory.appending(path: "configuration.json")
    let store = ConfigurationStore(fileURL: storeURL)

    try store.save(BetterTileConfiguration())

    let internalData = try Data(contentsOf: storeURL)
    #expect(!internalData.contains(0x0A))
    #expect(try store.load() == BetterTileConfiguration())
}

@Test func futureConfigurationIsRejected() throws {
    let data = try JSONSerialization.data(withJSONObject: ["schemaVersion": 999])
    #expect(throws: ConfigurationError.unsupportedFutureVersion(999)) { try ConfigurationStore.decode(data) }
}

@Test func schemaTenAddsLayoutWheelDefaults() throws {
    let migrated = try ConfigurationStore.decode(JSONSerialization.data(withJSONObject: [
        "schemaVersion": 9,
    ]))

    #expect(migrated.schemaVersion == 10)
    #expect(migrated.layoutWheel == LayoutWheelConfiguration())
    #expect(migrated.layoutWheel.levelCount == .two)
    #expect(migrated.layoutWheel.innerSlots == LayoutWheelConfiguration.defaultInnerSlots)
    #expect(migrated.layoutWheel.outerSlots == LayoutWheelConfiguration.defaultOuterSlots)
    #expect(migrated.layoutWheel.keyboardModifiers == [.control, .option, .shift])
    #expect(migrated.layoutWheel.keyboardTriggerEnabled)
    #expect(!migrated.layoutWheel.middleClickTriggerEnabled)
}

@Test func layoutWheelConfigurationRoundTrips() throws {
    let zone = CustomZone(
        name: "Focus",
        rect: NormalizedRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
    )
    var configuration = BetterTileConfiguration(customZones: [zone])
    configuration.layoutWheel = LayoutWheelConfiguration(
        isEnabled: false,
        levelCount: .one,
        innerSlots: [
            .customZone(zone.id),
            .customZone(zone.id),
            nil, nil, nil, nil, nil, nil,
        ],
        outerSlots: LayoutWheelConfiguration.defaultOuterSlots,
        keyboardTriggerEnabled: false,
        keyboardModifiers: [.command, .shift],
        middleClickTriggerEnabled: true
    )

    let decoded = try ConfigurationStore.decode(JSONEncoder().encode(configuration))
    #expect(decoded == configuration)
    #expect(decoded.layoutWheel.innerSlots[0] == .customZone(zone.id))
    #expect(decoded.layoutWheel.innerSlots[1] == .customZone(zone.id))
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

@Test func removedCustomZonesLeaveLayoutWheelSlotsEmpty() throws {
    let kept = CustomZone(
        name: "Kept",
        rect: NormalizedRect(x: 0, y: 0, width: 0.5, height: 1)
    )
    let removed = CustomZone(
        name: "Removed",
        rect: NormalizedRect(x: 0.5, y: 0, width: 0.5, height: 1)
    )
    var configuration = BetterTileConfiguration(customZones: [kept])
    configuration.layoutWheel.innerSlots = [
        .customZone(removed.id),
        .customZone(kept.id),
        .customZone(removed.id),
        nil, nil, nil, nil, nil,
    ]

    let normalized = try configuration.validated()
    #expect(normalized.layoutWheel.innerSlots[0] == nil)
    #expect(normalized.layoutWheel.innerSlots[1] == .customZone(kept.id))
    #expect(normalized.layoutWheel.innerSlots[2] == nil)
}

@Test func schemaNineWidensTheSingleWindowPlacementToTheActionList() throws {
    // The three cases stored by schemas 5 to 8 map onto the wider list.
    let almost = try ConfigurationStore.decode(JSONSerialization.data(withJSONObject: [
        "schemaVersion": 8,
        "singleWindowInitialPlacement": "almostMaximize",
    ]))
    #expect(almost.schemaVersion == 10)
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
    #expect(migrated.schemaVersion == 10)
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
    #expect(oldDefault.schemaVersion == 10)
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
    #expect(LayoutMode.availableModes == [.manual, .bento])

    let roundTrip = try ConfigurationStore.decode(JSONEncoder().encode(configuration))
    #expect(roundTrip.linkedResizeEnabled)
}

@Test func freshInstallUsesRecommendedResizeDefaults() {
    let configuration = BetterTileConfiguration()
    #expect(configuration.linkedResizeEnabled)
    #expect(configuration.resizeFeedbackMode == .ghost)
    #expect(configuration.dividerThickness == 10)
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
