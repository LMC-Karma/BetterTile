import Foundation

/// How much of BetterTile an application takes part in.
///
/// Some applications do not belong in a tiled grid — session-restore prompts,
/// colour pickers, palettes, small utility windows — and some misbehave under
/// any automated placement at all. Without a way to say so the only remedy is
/// quitting BetterTile, so the escape hatch is a first-class part of the
/// product rather than a workaround.
public enum ApplicationRule: String, Codable, CaseIterable, Sendable, Identifiable {
    /// The default. Shortcuts, drag snapping, Bento and everything else apply.
    case manageNormally
    /// Stays out of Bento layouts and new Tabbed panes and keeps its own size and position there.
    /// Shortcuts and drag snapping still work on its floating windows. A window that already
    /// belongs to a Tabbed pane must be floated first.
    case excludeFromBento
    /// BetterTile never moves or resizes it, from any feature.
    case ignoreEverywhere

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .manageNormally: "Manage Normally"
        case .excludeFromBento: "Exclude from Adaptive and Tabbed"
        case .ignoreEverywhere: "Ignore Everywhere"
        }
    }

    public var explanation: String {
        switch self {
        case .manageNormally:
            "BetterTile arranges this app like any other."
        case .excludeFromBento:
            "Keeps this app out of Adaptive layouts and new Tabbed panes. Shortcuts and drag snapping work on its "
                + "floating windows. If a window already belongs to a Tabbed pane, float it first."
        case .ignoreEverywhere:
            "BetterTile never moves or resizes this app."
        }
    }

    /// Whether this rule permits a directly requested action: a shortcut, a
    /// drag snap, a title-bar double click, a linked resize.
    public var allowsDirectPlacement: Bool { self != .ignoreEverywhere }

    /// Whether windows under this rule may become Bento panes.
    public var allowsBentoParticipation: Bool { self == .manageNormally }
}

/// The set of applications with a rule other than the default.
///
/// Only non-default rules are stored, so the file records decisions the user
/// made rather than an enumeration of every application they have ever run.
/// Each rule can be turned off without deleting it: a disabled rule is kept,
/// and its application is managed normally until the rule is enabled again.
public struct ApplicationRuleSet: Codable, Hashable, Sendable {
    private struct StoredRule: Hashable, Sendable {
        var rule: ApplicationRule
        var isEnabled = true
    }

    private var rules: [String: StoredRule]

    /// Every given rule starts enabled.
    public init(_ rules: [String: ApplicationRule] = [:]) {
        self.rules = rules.filter { $0.value != .manageNormally }.mapValues { StoredRule(rule: $0) }
    }

    /// The rule BetterTile applies: Manage Normally for an application without a rule or with a disabled one.
    public func rule(for bundleIdentifier: String?) -> ApplicationRule {
        guard let bundleIdentifier, let stored = rules[bundleIdentifier], stored.isEnabled else { return .manageNormally }
        return stored.rule
    }

    /// The rule the user chose, whether or not it is enabled. Nil when the application has no rule.
    public func configuredRule(for bundleIdentifier: String) -> ApplicationRule? {
        rules[bundleIdentifier]?.rule
    }

    /// Whether the application's rule applies. An application without a rule reports true.
    public func isEnabled(for bundleIdentifier: String) -> Bool {
        rules[bundleIdentifier]?.isEnabled ?? true
    }

    /// Sets the rule and keeps its Enabled state. A new rule starts enabled. Manage Normally removes the rule.
    public mutating func set(_ rule: ApplicationRule, for bundleIdentifier: String) {
        guard !bundleIdentifier.isEmpty else { return }
        if rule == .manageNormally {
            rules.removeValue(forKey: bundleIdentifier)
        } else {
            rules[bundleIdentifier, default: StoredRule(rule: rule)].rule = rule
        }
    }

    /// Turns an existing rule on or off. Does nothing for an application without a rule.
    public mutating func setEnabled(_ isEnabled: Bool, for bundleIdentifier: String) {
        rules[bundleIdentifier]?.isEnabled = isEnabled
    }

    public mutating func clear(_ bundleIdentifier: String) {
        rules.removeValue(forKey: bundleIdentifier)
    }

    /// Sorted so the settings list and the written file are both stable.
    public var entries: [(bundleIdentifier: String, rule: ApplicationRule, isEnabled: Bool)] {
        rules.sorted { $0.key < $1.key }.map {
            (bundleIdentifier: $0.key, rule: $0.value.rule, isEnabled: $0.value.isEnabled)
        }
    }

    public var isEmpty: Bool { rules.isEmpty }

    /// Every application with a rule, enabled or not.
    public var ruledBundleIdentifiers: Set<String> { Set(rules.keys) }

    // Encoded as a sorted array rather than a dictionary: dictionary key order
    // is not defined, and an exported configuration that reorders itself
    // between writes is not diffable and not comparable.
    // `isEnabled` is written only when false, so files without disabled rules
    // stay byte-identical to the format before the Enabled switch, and a
    // missing value decodes as enabled.
    private struct Entry: Codable, Sendable {
        var bundleIdentifier: String
        var rule: ApplicationRule
        var isEnabled: Bool?
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let entries = try container.decode([Entry].self)
        var decoded: [String: StoredRule] = [:]
        for entry in entries where entry.rule != .manageNormally && !entry.bundleIdentifier.isEmpty {
            // Last write wins, deterministically, if a hand-edited file repeats
            // an identifier.
            decoded[entry.bundleIdentifier] = StoredRule(rule: entry.rule, isEnabled: entry.isEnabled ?? true)
        }
        rules = decoded
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(
            entries.map {
                Entry(bundleIdentifier: $0.bundleIdentifier, rule: $0.rule, isEnabled: $0.isEnabled ? nil : false)
            }
        )
    }
}

/// One application offered by the rule picker.
///
/// Deliberately framework-free: the application layer maps whatever it can see —
/// running applications, or a bundle the user browsed to — into this shape, and
/// the filtering that decides what is worth offering stays testable.
public struct ApplicationRuleCandidate: Hashable, Sendable, Identifiable {
    public var bundleIdentifier: String
    public var name: String

    public var id: String { bundleIdentifier }

    public init(bundleIdentifier: String, name: String) {
        self.bundleIdentifier = bundleIdentifier
        self.name = name
    }
}

public extension ApplicationRuleSet {
    /// The applications worth offering in the picker: everything except
    /// BetterTile itself and the applications that already have a rule, since
    /// those are edited in the list rather than added again.
    ///
    /// Repeated bundle identifiers collapse to their first occurrence — the
    /// same application can be running as several processes — and the result is
    /// sorted by display name so the picker does not reorder itself between
    /// openings.
    func addableCandidates(
        from running: [ApplicationRuleCandidate],
        excluding ownBundleIdentifier: String
    ) -> [ApplicationRuleCandidate] {
        var seen: Set<String> = ruledBundleIdentifiers
        seen.insert(ownBundleIdentifier)
        var candidates: [ApplicationRuleCandidate] = []
        for candidate in running where !candidate.bundleIdentifier.isEmpty {
            guard seen.insert(candidate.bundleIdentifier).inserted else { continue }
            candidates.append(candidate)
        }
        return candidates.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.bundleIdentifier < $1.bundleIdentifier : order == .orderedAscending
        }
    }
}
