import Foundation
import Testing
@testable import BetterTileCore

private let safari = "com.apple.Safari"
private let figma = "com.figma.Desktop"
private let notes = "com.apple.Notes"

@Test func anUnknownApplicationIsManagedNormally() {
    let rules = ApplicationRuleSet()
    #expect(rules.rule(for: safari) == .manageNormally)
    #expect(rules.rule(for: nil) == .manageNormally, "a window with no bundle identifier is not ruled")
}

@Test func rulesCapabilitiesMatchTheirNames() {
    #expect(ApplicationRule.manageNormally.allowsDirectPlacement)
    #expect(ApplicationRule.manageNormally.allowsBentoParticipation)

    #expect(ApplicationRule.excludeFromBento.allowsDirectPlacement,
            "a shortcut aimed at it still works")
    #expect(!ApplicationRule.excludeFromBento.allowsBentoParticipation)

    #expect(!ApplicationRule.ignoreEverywhere.allowsDirectPlacement)
    #expect(!ApplicationRule.ignoreEverywhere.allowsBentoParticipation)
}

/// Only decisions are stored. Setting an application back to the default
/// removes it rather than recording the default against it.
@Test func settingAnApplicationBackToTheDefaultForgetsIt() {
    var rules = ApplicationRuleSet()
    rules.set(.ignoreEverywhere, for: safari)
    #expect(rules.ruledBundleIdentifiers == [safari])
    rules.set(.manageNormally, for: safari)
    #expect(rules.isEmpty)
}

@Test func anEmptyBundleIdentifierIsRefused() {
    var rules = ApplicationRuleSet()
    rules.set(.ignoreEverywhere, for: "")
    #expect(rules.isEmpty)
}

@Test func entriesAreSortedForAStableList() {
    var rules = ApplicationRuleSet()
    rules.set(.excludeFromBento, for: notes)
    rules.set(.ignoreEverywhere, for: safari)
    rules.set(.excludeFromBento, for: figma)
    #expect(rules.entries.map(\.bundleIdentifier) == [safari, notes, figma].sorted())
}

// MARK: - Deterministic migration and storage

/// Dictionary key order is undefined, so storing rules as a dictionary would
/// reorder the file between writes. The entry sequence is what this type
/// controls, and it has to be stable regardless of the order rules were added.
@Test func theEntrySequenceDoesNotDependOnInsertionOrder() {
    let identifiers = [figma, safari, notes, "com.tinyspeck.slackmacgap", "com.google.Chrome"]
    var forwards = ApplicationRuleSet()
    for identifier in identifiers { forwards.set(.excludeFromBento, for: identifier) }
    var backwards = ApplicationRuleSet()
    for identifier in identifiers.reversed() { backwards.set(.excludeFromBento, for: identifier) }

    #expect(forwards.entries.map(\.bundleIdentifier) == backwards.entries.map(\.bundleIdentifier))
    #expect(forwards.entries.map(\.bundleIdentifier) == identifiers.sorted())
}

/// The written file has to be byte-identical between saves of the same
/// configuration, or an exported configuration is neither diffable nor
/// comparable. Uses the encoder settings the configuration store writes with;
/// a bare JSONEncoder does not order the keys inside an object.
@Test func theStoredConfigurationIsByteIdenticalAcrossRepeatedWrites() throws {
    var configuration = BetterTileConfiguration()
    for identifier in [figma, safari, notes, "com.google.Chrome"] {
        configuration.applicationRules.set(.excludeFromBento, for: identifier)
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let first = try encoder.encode(configuration)
    for _ in 0..<20 {
        #expect(try encoder.encode(configuration) == first)
    }
}

@Test func rulesSurviveARoundTrip() throws {
    var rules = ApplicationRuleSet()
    rules.set(.ignoreEverywhere, for: safari)
    rules.set(.excludeFromBento, for: figma)
    let decoded = try JSONDecoder().decode(
        ApplicationRuleSet.self,
        from: JSONEncoder().encode(rules)
    )
    #expect(decoded == rules)
    #expect(decoded.rule(for: safari) == .ignoreEverywhere)
    #expect(decoded.rule(for: figma) == .excludeFromBento)
}

/// A hand-edited file that repeats an identifier must resolve the same way
/// every time rather than depending on decode order.
@Test func aRepeatedIdentifierResolvesDeterministically() throws {
    let json = Data("""
    [
      {"bundleIdentifier":"com.apple.Safari","rule":"excludeFromBento"},
      {"bundleIdentifier":"com.apple.Safari","rule":"ignoreEverywhere"}
    ]
    """.utf8)
    for _ in 0..<20 {
        let decoded = try JSONDecoder().decode(ApplicationRuleSet.self, from: json)
        #expect(decoded.rule(for: safari) == .ignoreEverywhere, "the last entry wins, every time")
    }
}

@Test func explicitlyDefaultEntriesAreDroppedOnDecode() throws {
    let json = Data("""
    [{"bundleIdentifier":"com.apple.Safari","rule":"manageNormally"}]
    """.utf8)
    #expect(try JSONDecoder().decode(ApplicationRuleSet.self, from: json).isEmpty)
}

// MARK: - Picking an application to rule

private func candidate(_ bundleIdentifier: String, _ name: String) -> ApplicationRuleCandidate {
    ApplicationRuleCandidate(bundleIdentifier: bundleIdentifier, name: name)
}

private let betterTile = "com.lmc.BetterTile"

@Test func thePickerOffersRunningApplicationsSortedByName() {
    let offered = ApplicationRuleSet().addableCandidates(
        from: [candidate(figma, "Figma"), candidate(safari, "Safari"), candidate(notes, "Notes")],
        excluding: betterTile
    )
    #expect(offered.map(\.name) == ["Figma", "Notes", "Safari"])
}

@Test func thePickerHidesApplicationsThatAlreadyHaveARule() {
    var rules = ApplicationRuleSet()
    rules.set(.ignoreEverywhere, for: safari)
    let offered = rules.addableCandidates(
        from: [candidate(safari, "Safari"), candidate(figma, "Figma")],
        excluding: betterTile
    )
    #expect(offered.map(\.bundleIdentifier) == [figma], "a ruled app is edited in the list, not added again")
}

@Test func thePickerNeverOffersBetterTileItself() {
    let offered = ApplicationRuleSet().addableCandidates(
        from: [candidate(betterTile, "BetterTile"), candidate(notes, "Notes")],
        excluding: betterTile
    )
    #expect(offered.map(\.bundleIdentifier) == [notes])
}

@Test func repeatedIdentifiersCollapseToOneRow() {
    // The same application can be running as several processes.
    let offered = ApplicationRuleSet().addableCandidates(
        from: [candidate(safari, "Safari"), candidate(safari, "Safari"), candidate(notes, "Notes")],
        excluding: betterTile
    )
    #expect(offered.count == 2)
    #expect(offered.map(\.bundleIdentifier) == [notes, safari])
}

@Test func anApplicationWithoutAnIdentifierIsNotOffered() {
    let offered = ApplicationRuleSet().addableCandidates(
        from: [candidate("", "Nameless"), candidate(notes, "Notes")],
        excluding: betterTile
    )
    #expect(offered.map(\.bundleIdentifier) == [notes], "a rule keyed on an empty identifier could never match")
}

@Test func theOfferedOrderDoesNotDependOnHowApplicationsWereLaunched() {
    let rules = ApplicationRuleSet()
    let forward = rules.addableCandidates(
        from: [candidate(safari, "Safari"), candidate(figma, "Figma"), candidate(notes, "Notes")],
        excluding: betterTile
    )
    let reversed = rules.addableCandidates(
        from: [candidate(notes, "Notes"), candidate(figma, "Figma"), candidate(safari, "Safari")],
        excluding: betterTile
    )
    #expect(forward == reversed)
}

// MARK: - Configuration integration

@Test func aConfigurationWithoutRulesMigratesToTheDefaults() throws {
    let decoded = try JSONDecoder().decode(
        BetterTileConfiguration.self,
        from: Data(#"{"schemaVersion":8}"#.utf8)
    )
    #expect(decoded.applicationRules.isEmpty)
    #expect(decoded.keyboardShortcutsEnabled, "shortcuts stay on for existing installations")
}

@Test func rulesAndTheShortcutToggleSurviveAConfigurationRoundTrip() throws {
    var configuration = BetterTileConfiguration()
    configuration.applicationRules.set(.excludeFromBento, for: figma)
    configuration.keyboardShortcutsEnabled = false
    let decoded = try JSONDecoder().decode(
        BetterTileConfiguration.self,
        from: JSONEncoder().encode(configuration)
    )
    #expect(decoded.applicationRules.rule(for: figma) == .excludeFromBento)
    #expect(!decoded.keyboardShortcutsEnabled)
}

/// Turning the master switch off must not disturb the bindings, so turning it
/// back on restores exactly what was there.
@Test func theShortcutToggleLeavesBindingsUntouched() throws {
    var configuration = BetterTileConfiguration()
    let bindings = configuration.shortcuts
    configuration.keyboardShortcutsEnabled = false
    let decoded = try JSONDecoder().decode(
        BetterTileConfiguration.self,
        from: JSONEncoder().encode(configuration)
    )
    #expect(decoded.shortcuts == bindings)
}

@Test func changingRulesOrTheShortcutToggleIsARuntimeChange() {
    var withRule = BetterTileConfiguration()
    withRule.applicationRules.set(.ignoreEverywhere, for: safari)
    #expect(ConfigurationChangeSet.between(BetterTileConfiguration(), withRule).contains(.applicationRules))

    var withoutShortcuts = BetterTileConfiguration()
    withoutShortcuts.keyboardShortcutsEnabled = false
    #expect(ConfigurationChangeSet.between(BetterTileConfiguration(), withoutShortcuts).contains(.shortcuts))
}
