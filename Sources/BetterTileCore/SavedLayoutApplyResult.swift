import Foundation

/// The desktop that one Apply targets: the current desktop of one display.
/// Runtime IDs only. Nothing here is saved or exported.
public struct SavedLayoutDesktop: Hashable, Sendable {
    public var displayID: DisplayID
    public var spaceID: NativeSpaceID
    public init(displayID: DisplayID, spaceID: NativeSpaceID) {
        self.displayID = displayID; self.spaceID = spaceID
    }
}

public enum SavedLayoutIssueKind: Equatable, Sendable {
    case notInstalled, notRunning, severalWindows, onAnotherDesktop
    case couldNotFit, fixedSize, stopped, stillMoving, other
}

public struct SavedLayoutApplyIssue: Equatable, Sendable {
    public var kind: SavedLayoutIssueKind
    public var message: String
    public var slotID: String?
    public init(_ kind: SavedLayoutIssueKind, _ message: String, slotID: String? = nil) {
        self.kind = kind; self.message = message; self.slotID = slotID
    }
}

public struct SavedLayoutApplyResult: Equatable, Sendable {
    public var placed = 0
    /// A projection of committed existing-window transfers in the run's Undo record.
    public var movedSlots: Set<String> = []
    public var unplaced = 0
    public var issues: [SavedLayoutApplyIssue] = []
    /// Slot IDs that received a window in this run.
    public var placedSlots: Set<String> = []
    public init(placed: Int = 0, unplaced: Int = 0, issues: [SavedLayoutApplyIssue] = [],
                placedSlots: Set<String> = []) {
        self.placed = placed; self.unplaced = unplaced; self.issues = issues
        self.placedSlots = placedSlots
    }

    /// The run record. After planning, every document slot has exactly one outcome.
    public private(set) var slots: [String: SavedLayoutSlotOutcome] = [:]

    /// Convert the planner's counts and issues into a complete per-slot record once.
    public mutating func recordSlots(_ ids: [String]) {
        slots = Dictionary(uniqueKeysWithValues: ids.map { id in
            let outcome: SavedLayoutSlotOutcome
            if placedSlots.contains(id) { outcome = .placed }
            else {
                let issue = issues.first { $0.slotID == id } ?? issues.first { $0.slotID == nil }
                    ?? .init(.other, "No window was placed for this slot.")
                outcome = .skipped(issue)
            }
            return (id, outcome)
        })
        let runIssues = issues.filter { $0.slotID == nil }
        issues = runIssues + ids.compactMap { id in
            guard var issue = slots[id]?.issue else { return nil }
            issue.slotID = id
            return runIssues.contains(where: { $0.message == issue.message }) ? nil : issue
        }
        synchronizeCounts()
    }

    private mutating func synchronizeCounts() {
        placedSlots = Set(slots.compactMap { $0.value == .placed ? $0.key : nil })
        placed = placedSlots.count; unplaced = slots.count - placed
    }

    public var isClean: Bool { presentation(layout: "").severity == .success }
    public func title(layout name: String) -> String { presentation(layout: name).title }
    public var detail: String { presentation(layout: "").summary }
    public var message: String { presentation(layout: "").message }

    /// The only result policy. Pills, Settings, Details, Last run and pane badges read this projection.
    /// Counts are accepted for older callers without a document; production Apply records every slot.
    public func presentation(layout name: String) -> SavedLayoutResultPresentation {
        var outcomes = slots
        if slots.isEmpty {
            for id in placedSlots { outcomes[id] = .placed }
        }
        let placedCount = slots.isEmpty ? placed : outcomes.values.filter { $0 == .placed }.count
        let skippedCount = slots.isEmpty ? max(0, unplaced) : outcomes.count - placedCount
        let movedCount = movedSlots.intersection(placedSlots).count
        var parts: [String] = []
        if placedCount > movedCount || movedCount == 0 { parts.append("\(placedCount - movedCount) placed") }
        if movedCount > 0 { parts.append("\(movedCount) moved from another display") }
        if skippedCount > 0 { parts.append("\(skippedCount) skipped") }
        let summary = parts.joined(separator: " · ")
        var reasons = issues.filter { $0.slotID == nil }
        for id in outcomes.keys.sorted() {
            if let issue = outcomes[id]?.issue, !reasons.contains(where: { $0.message == issue.message }) { reasons.append(issue) }
        }
        if slots.isEmpty { reasons = issues }
        let status: SavedLayoutResultPresentation.Status
        let severity: SavedLayoutResultPresentation.Severity
        let title: String
        if placedCount == 0 {
            status = .notApplied; severity = .failure; title = "\(name) not applied"
        } else {
            status = .applied
            severity = reasons.isEmpty && skippedCount == 0 ? .success : .warning
            title = reasons.isEmpty ? "\(name) applied" : "\(name) applied with \(reasons.count) \(reasons.count == 1 ? "issue" : "issues")"
        }
        let message = summary + (reasons.isEmpty ? "" : ". " + reasons.map(\.message).joined(separator: " "))
        let pillDetail = placedCount == 0 ? reasons.first.map { summary + ". " + $0.message } ?? summary : summary
        let badges = outcomes.mapValues { outcome -> SavedLayoutResultPresentation.Slot in
            switch outcome {
            case .placed: .init(outcome: outcome, text: "Placed", detail: "Placed")
            case let .skipped(issue): .init(outcome: outcome, text: "Skipped", detail: "Skipped. " + issue.message)
            }
        }
        var displayedBadges = badges
        for id in movedSlots where outcomes[id] == .placed {
            displayedBadges[id] = .init(outcome: .placed, text: "Moved from another display", detail: "Moved from another display")
        }
        return .init(title: title, severity: severity, status: status, summary: summary,
                     pillDetail: pillDetail, message: message, issues: reasons, slots: displayedBadges)
    }
}

public enum SavedLayoutSlotOutcome: Equatable, Sendable {
    case placed
    case skipped(SavedLayoutApplyIssue)

    public var issue: SavedLayoutApplyIssue? {
        switch self {
        case let .skipped(issue): issue
        case .placed: nil
        }
    }
}

public struct SavedLayoutResultPresentation: Equatable, Sendable {
    public enum Status: String, Sendable { case applied = "Applied", notApplied = "Not applied" }
    public enum Severity: Sendable { case success, warning, failure }
    public struct Slot: Equatable, Sendable {
        public var outcome: SavedLayoutSlotOutcome
        public var text: String
        public var detail: String
    }
    public var title: String
    public var severity: Severity
    public var status: Status
    public var summary: String
    public var pillDetail: String
    public var message: String
    public var issues: [SavedLayoutApplyIssue]
    public var slots: [String: Slot]
}
