// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 LMC-Karma

import AppKit
import BetterTileCore
import SwiftUI

/// Names a display for the user. Falls back to its position when AppKit cannot match it.
@MainActor func savedLayoutDisplayName(_ id: DisplayID, among displays: [DisplaySnapshot]) -> String {
    if let number = UInt32(id.rawValue),
       let screen = NSScreen.screens.first(where: {
           ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == number
       }) { return screen.localizedName }
    let index = displays.firstIndex { $0.id == id }.map { $0 + 1 } ?? 1
    return "Display \(index)"
}

/// Shared policy for settled repeats and Automatic Apply.
enum SavedLayoutApplyPolicy {
    static func settledRepeat(layout: String, arrangedSummary: String) -> (title: String, offersUndo: Bool) { (layout + " · already arranged", false) }
    static func leavesAutomaticLayoutAlone(automatic: Bool, plan: SavedLayoutApplyPlan) -> Bool { automatic && plan.assignments.isEmpty }
}

/// Display-only explanation of the committed plan. No window titles or persisted runtime IDs.
struct SavedLayoutPlanPresentation {
    var title: String
    var summary: String
    var lines: [String]
    var slotDetails: [String: String]
    var alreadyArranged: Bool
    var emptySlots: Set<String>
    var emptyPaneCount: Int
    var issues: [SavedLayoutApplyIssue] = []

    func pageDetail(movedSlots: Set<String>) -> String {
        var parts = [summary]
        if !movedSlots.isEmpty { parts.append("\(movedSlots.count) moved from another display") }
        if emptyPaneCount > 0 { parts.append("\(emptyPaneCount) empty \(emptyPaneCount == 1 ? "pane" : "panes")") }
        return parts.joined(separator: " · ")
    }

    static func preferenceIssues(document: SavedLayoutDocument, groups: AppGroupsDocument,
                                 resolvedBundleIDs: [AppGroupEntry: String]) -> [SavedLayoutApplyIssue] {
        var seen = Set<String>(), issues: [SavedLayoutApplyIssue] = []
        for preference in document.slots.flatMap(\.prefer) {
            guard case let .group(group) = preference, seen.insert(group.lowercased()).inserted else { continue }
            let expansion = groups.expand([preference], resolvedBundleIDs: resolvedBundleIDs)
            if !expansion.unknownGroups.isEmpty {
                issues.append(.init(.other, "App Group “\(group)” was not found. Review this pane’s preferences in Saved Layouts."))
            } else if !expansion.unresolvedEntries.isEmpty {
                issues.append(.init(.other, "App Group “\(group)” has unresolved apps. Review them in App Groups; those preferences were skipped."))
            }
        }
        return issues
    }

    init(document: SavedLayoutDocument, plan: SavedLayoutApplyPlan, windows: [SavedLayoutEligibleWindow],
         workArea: BTRect, groups: AppGroupsDocument, resolvedBundleIDs: [AppGroupEntry: String],
         name: (String) -> String, windowName: (WindowID) -> String, uninstalledBundleIDs: Set<String> = [], movedFrom: [WindowID: String] = [:]) {
        alreadyArranged = plan.isEmpty
        emptySlots = Set(plan.emptySlots)
        emptyPaneCount = document.layout.map { tree in
            SavedLayoutCanvas.leaves(tree, paneGap: document.paneGap).filter { leaf in
                let slots = SavedLayoutCanvas.slotIDs(in: leaf.node, document: document)
                return slots.isEmpty || slots.allSatisfy { plan.emptySlots.contains($0) }
            }.count
        } ?? plan.emptySlots.count
        let byID = Dictionary(uniqueKeysWithValues: windows.map { ($0.id, $0) })
        let arranged = plan.assignments.count + plan.extras.values.filter {
            switch $0 { case .tab, .addedAsPane: true; case .floating, .untouched: false }
        }.count
        let floating = plan.extras.keys.filter { plan.extras[$0] == .floating }.sorted()
        summary = arranged == 0 ? "no windows to arrange" : "\(arranged) arranged"
        if floating.count == 1, let id = floating.first, let window = byID[id] {
            summary += " · \(windowName(window.id)) not in layout"
        } else if floating.count > 1 { summary += " · \(floating.count) windows not in layout" }
        title = document.name + " · " + summary
        slotDetails = [:]
        lines = []
        for slot in document.slots {
            guard !plan.emptySlots.contains(slot.id), let id = plan.assignments[slot.id], let window = byID[id] else {
                slotDetails[slot.id] = "empty"; continue
            }
            let reason: String
            switch plan.slotReasons[slot.id] ?? .empty {
            case .chosen: reason = "chosen window"
            case let .preferred(rank):
                let preferences = groups.expand(slot.prefer, resolvedBundleIDs: resolvedBundleIDs).bundleIDs
                let missing = preferences.prefix(rank).filter { bundle in !windows.contains { $0.bundleID.caseInsensitiveCompare(bundle) == .orderedSame } }
                    .map { uninstalledBundleIDs.contains($0) ? name($0) : name($0) + " not open" }
                let number = rank + 1
                let ordinal = number == 1 ? "1st" : number == 2 ? "2nd" : number == 3 ? "3rd" : "\(number)th"
                reason = ordinal + " choice" + (missing.isEmpty ? "" : "; " + missing.joined(separator: ", "))
            case .largestFreeSlot: reason = "frontmost window; largest free pane"
            case .nearestPosition: reason = "nearest position"
            case .empty: reason = "empty"
            }
            var detail = windowName(window.id) + " (" + reason
            if let source = movedFrom[id] { detail += "; moved from " + source }
            slotDetails[slot.id] = detail + ")"
        }
        var paneLines: [String] = []
        if let tree = document.layout {
            let leaves = SavedLayoutCanvas.leaves(tree, paneGap: document.paneGap)
            let labels = Self.paneNames(tree)
            for (index, leaf) in leaves.enumerated() {
                let label = labels[index]
                let slots = SavedLayoutCanvas.slotIDs(in: leaf.node, document: document)
                let details = slots.compactMap { slotDetails[$0] }
                paneLines.append(label + " — " + (details.isEmpty ? "empty" : details.joined(separator: "; ")))
            }
        }
        for (index, rectangle) in (document.windows + document.floats).enumerated() {
            paneLines.append("Rectangle \(index + 1) — " + (slotDetails[rectangle.slot] ?? "empty"))
        }
        lines = paneLines
        for id in plan.extras.keys.sorted() {
            guard let window = byID[id], let destination = plan.extras[id] else { continue }
            let detail: String
            switch destination {
            case .floating: detail = "floating, no pane left"
            case .untouched: detail = "left in place"
            case .addedAsPane: detail = "added as a pane"
            case let .tab(group, reason):
                let pane = document.layout.flatMap { tree in
                    let leaves = SavedLayoutCanvas.leaves(tree, paneGap: document.paneGap)
                    let labels = Self.paneNames(tree)
                    return leaves.firstIndex { if case let .group(id) = $0.node { id == group } else { false } }
                        .map { labels[$0].lowercased() }
                } ?? group
                let why: String
                switch reason {
                case .sameApp: why = "same app"
                case .listedApp: why = "preferred app"
                case .tabMates: why = "existing tab-mates"
                case .nearestPane: why = "nearest pane"
                }
                detail = "tab in \(pane), \(why)"
            }
            lines.append(windowName(window.id) + " — " + detail)
        }
    }

    private static func paneNames(_ tree: SavedLayoutNode) -> [String] {
        func word(_ index: Int, count: Int, axis: SplitAxis) -> String {
            if count > 3 { return (axis == .vertical ? "column" : "row") + " \(index + 1)" }
            if count == 3 && index == 1 { return "middle" }
            return index == 0 ? (axis == .vertical ? "left" : "top") : (axis == .vertical ? "right" : "bottom")
        }
        var names: [String] = []
        func visit(_ node: SavedLayoutNode, columns: [String], rows: [String]) {
            if case let .split(axis, _, children) = node {
                for (index, child) in children.enumerated() {
                    let label = children.count > 1 ? [word(index, count: children.count, axis: axis)] : []
                    visit(child, columns: columns + (axis == .vertical ? label : []),
                          rows: rows + (axis == .horizontal ? label : []))
                }
            } else {
                let words = rows + columns
                let name = words.isEmpty ? "pane" : words == ["middle", "middle"] ? "middle" : words.joined(separator: " ")
                names.append(name.prefix(1).uppercased() + name.dropFirst())
            }
        }
        visit(tree, columns: [], rows: [])
        let counts = Dictionary(grouping: names, by: { $0 }).mapValues(\.count)
        var seen: [String: Int] = [:]
        return names.map { name in
            seen[name, default: 0] += 1
            return counts[name, default: 0] > 1 ? name + " \(seen[name]!)" : name
        }
    }
}
