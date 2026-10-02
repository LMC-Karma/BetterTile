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

// MARK: - Deterministic migration and storage

/// Rule order stays stable regardless of insertion order, with each rule
/// still attached to its application.
@Test func theEntrySequenceDoesNotDependOnInsertionOrder() {
    let identifiers = [figma, safari, notes, "com.tinyspeck.slackmacgap", "com.google.Chrome"]
    var forwards = ApplicationRuleSet()
    for identifier in identifiers { forwards.set(identifier == safari ? .ignoreEverywhere : .excludeFromBento, for: identifier) }
    var backwards = ApplicationRuleSet()
    for identifier in identifiers.reversed() { backwards.set(identifier == safari ? .ignoreEverywhere : .excludeFromBento, for: identifier) }

    #expect(forwards.entries.map(\.bundleIdentifier) == backwards.entries.map(\.bundleIdentifier))
    #expect(forwards.entries.map(\.rule) == backwards.entries.map(\.rule))
    #expect(forwards.entries.map(\.bundleIdentifier) == identifiers.sorted())
}

/// Store output is stable across opposite rule insertion orders.
@Test func storedConfigurationDoesNotDependOnRuleInsertionOrder() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = ConfigurationStore(fileURL: directory.appending(path: "configuration.json"))
    let identifiers = [figma, safari, notes, "com.google.Chrome"]
    var first: Data?
    for order in [identifiers, Array(identifiers.reversed())] {
        var configuration = BetterTileConfiguration()
        for identifier in order {
            configuration.applicationRules.set(identifier == safari ? .ignoreEverywhere : .excludeFromBento, for: identifier)
        }
        try store.save(configuration)
        let data = try Data(contentsOf: store.fileURL)
        if let first { #expect(data == first) } else { first = data }
        #expect(try store.load() == configuration)
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

/// Repeated identifiers use the last entry in either source order.
@Test func aRepeatedIdentifierUsesTheLastEntry() throws {
    let rules: [ApplicationRule] = [.excludeFromBento, .ignoreEverywhere]
    for order in [rules, Array(rules.reversed())] {
        let json = try JSONSerialization.data(withJSONObject: order.map {
            ["bundleIdentifier": safari, "rule": $0.rawValue]
        })
        let decoded = try JSONDecoder().decode(ApplicationRuleSet.self, from: json)
        #expect(decoded.rule(for: safari) == order.last)
        #expect(decoded.entries.count == 1)
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
