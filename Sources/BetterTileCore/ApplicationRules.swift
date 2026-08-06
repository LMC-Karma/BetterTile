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
    /// Stays out of Bento layouts and keeps its own size and position there,
    /// while shortcuts and drag snapping still work when aimed at it directly.
    case excludeFromBento
    /// BetterTile never moves or resizes it, from any feature.
    case ignoreEverywhere

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .manageNormally: "Manage Normally"
        case .excludeFromBento: "Exclude from Bento"
        case .ignoreEverywhere: "Ignore Everywhere"
        }
    }

    public var explanation: String {
        switch self {
        case .manageNormally:
            "BetterTile arranges this app like any other."
        case .excludeFromBento:
            "Keeps this app out of Bento layouts. Shortcuts and drag snapping still work when you use them on it."
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
public struct ApplicationRuleSet: Codable, Hashable, Sendable {
    private var rules: [String: ApplicationRule]

    public init(_ rules: [String: ApplicationRule] = [:]) {
        self.rules = rules.filter { $0.value != .manageNormally }
    }

    public func rule(for bundleIdentifier: String?) -> ApplicationRule {
        guard let bundleIdentifier else { return .manageNormally }
        return rules[bundleIdentifier] ?? .manageNormally
    }

    public mutating func set(_ rule: ApplicationRule, for bundleIdentifier: String) {
        guard !bundleIdentifier.isEmpty else { return }
        if rule == .manageNormally {
            rules.removeValue(forKey: bundleIdentifier)
        } else {
            rules[bundleIdentifier] = rule
        }
    }

    public mutating func clear(_ bundleIdentifier: String) {
        rules.removeValue(forKey: bundleIdentifier)
    }

    /// Sorted so the settings list and the written file are both stable.
    public var entries: [(bundleIdentifier: String, rule: ApplicationRule)] {
        rules.sorted { $0.key < $1.key }.map { (bundleIdentifier: $0.key, rule: $0.value) }
    }

    public var isEmpty: Bool { rules.isEmpty }

    public var ruledBundleIdentifiers: Set<String> { Set(rules.keys) }

    // Encoded as a sorted array rather than a dictionary: dictionary key order
    // is not defined, and an exported configuration that reorders itself
    // between writes is not diffable and not comparable.
    private struct Entry: Codable, Sendable {
        var bundleIdentifier: String
        var rule: ApplicationRule
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let entries = try container.decode([Entry].self)
        var decoded: [String: ApplicationRule] = [:]
        for entry in entries where entry.rule != .manageNormally && !entry.bundleIdentifier.isEmpty {
            // Last write wins, deterministically, if a hand-edited file repeats
            // an identifier.
            decoded[entry.bundleIdentifier] = entry.rule
        }
        rules = decoded
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(
            entries.map { Entry(bundleIdentifier: $0.bundleIdentifier, rule: $0.rule) }
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
