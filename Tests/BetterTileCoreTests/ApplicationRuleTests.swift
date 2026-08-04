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

/// Dictionary key order is undefined, so encoding rules as a dictionary would
/// reorder the file between writes. An exported configuration has to be
/// diffable and comparable.
@Test func encodingIsByteIdenticalAcrossRepeatedWrites() throws {
    var rules = ApplicationRuleSet()
    for identifier in [figma, safari, notes, "com.tinyspeck.slackmacgap", "com.google.Chrome"] {
        rules.set(.excludeFromBento, for: identifier)
    }
    let encoder = JSONEncoder()
    let first = try encoder.encode(rules)
    for _ in 0..<20 {
        #expect(try encoder.encode(rules) == first)
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
