// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 LMC-Karma

import Foundation

/// Assignment policy only. SavedLayoutPlanner fits the resulting session afterward.
struct SavedLayoutFill {
    var assignments: [String: WindowID] = [:]
    var reasons: [String: SavedLayoutSlotReason] = [:]
    var extras: [WindowID: SavedLayoutExtraDestination] = [:]
    var tabs: [String: [WindowID]] = [:]
    var unassignedForeignWindowIDs: [WindowID] = []
    var selectedTabs: [String: WindowID] = [:]
    let orderedWindows: [SavedLayoutEligibleWindow]

    init(document: SavedLayoutDocument, bounds: BTRect, windows: [SavedLayoutEligibleWindow],
         appGroups: AppGroupsDocument, resolvedBundleIDs: [AppGroupEntry: String],
         choices: [String: WindowID], preferredFrames: [String: NormalizedRect],
         currentSession: SavedLayoutSession?) throws {
        orderedWindows = windows.sorted { $0.frontRank != $1.frontRank ? $0.frontRank < $1.frontRank : $0.id < $1.id }
        let byID = Dictionary(uniqueKeysWithValues: windows.map { ($0.id, $0) })
        let preferences = Dictionary(uniqueKeysWithValues: document.slots.map {
            ($0.id, appGroups.expand($0.prefer, resolvedBundleIDs: resolvedBundleIDs).bundleIDs)
        })
        var targets = Dictionary(uniqueKeysWithValues: (document.windows + document.floats).map { ($0.slot, $0.rect) })
        if let root = document.layout {
            // Canvas subtracts gaps on its editor reference size. Fill uses full pane
            // frames from the runtime layout in the actual work area instead.
            var slotPanes: [String: UUID] = [:]
            func vacantTree(_ node: SavedLayoutNode, path: String) -> BentoNode {
                let id = stableUUID("saved-layout-fill:" + path)
                switch node {
                case let .slot(slot): slotPanes[slot] = id; return .vacant(id)
                case let .group(group):
                    for slot in document.groups.first(where: { $0.id == group })!.slots { slotPanes[slot] = id }
                    return .vacant(id)
                case .empty: return .vacant(id)
                case let .split(axis, ratios, children):
                    return .partition(.init(id: id, axis: axis,
                        children: children.enumerated().map { vacantTree($0.element, path: path + ".\($0.offset)") },
                        ratios: ratios, boundaryIDs: (0..<(children.count - 1)).map {
                            stableUUID("saved-layout-fill:\(path):boundary:\($0)")
                        }))
                }
            }
            let geometry = BentoLayoutState(root: vacantTree(root, path: "root"),
                metrics: BentoLayoutMetrics(paneGap: document.paneGap)).vacantFrames(in: bounds)
            for (slot, pane) in slotPanes { targets[slot] = NormalizedRect(frame: geometry[pane]!, in: bounds) }
        }
        let paneFrames = targets
        for (slot, frame) in preferredFrames where (try? frame.validated()) != nil { targets[slot] = frame }
        var claimed: Set<WindowID> = []
        for slot in choices.keys.sorted() {
            let id = choices[slot]!
            guard preferences[slot] != nil, byID[id] != nil, claimed.insert(id).inserted else {
                throw savedLayoutError("$.choices", "Choose a distinct eligible window for each slot.")
            }
            assignments[slot] = id; reasons[slot] = .chosen
        }

        // Keep the general slot-ID tie vector, but permute a captured group's own
        // positions into captured order. This changes only ties after ranks and distance.
        var preferredSlotOrder = document.slots.map(\.id).sorted()
        for group in document.groups {
            let positions = preferredSlotOrder.indices.filter { group.slots.contains(preferredSlotOrder[$0]) }
            for (position, slot) in zip(positions, group.slots) { preferredSlotOrder[position] = slot }
        }
        // Step 1 is one global preferred-only assignment. Current membership cannot
        // reserve a lower-ranked match ahead of a better preference elsewhere.
        let preferred = SavedLayoutPositionMatching.assign(
            slots: document.slots.filter { assignments[$0.id] == nil },
            windows: windows.filter { !claimed.contains($0.id) }, targets: targets, in: bounds,
            preferences: preferences, slotOrder: preferredSlotOrder)
        for (slot, id) in preferred {
            assignments[slot] = id; claimed.insert(id)
            reasons[slot] = .preferred(rank: preferences[slot]!.firstIndex {
                $0.caseInsensitiveCompare(byID[id]!.bundleID) == .orderedSame
            }!)
        }

        // Steps 2–3 never import an unpreferred window from a foreign display.
        var remaining = orderedWindows.filter { !claimed.contains($0.id) && $0.matchingFrame == nil }
        var free = document.slots.filter { assignments[$0.id] == nil }
        func area(_ slot: SavedLayoutSlot) -> Double {
            let rect = paneFrames[slot.id]!
            return rect.width * rect.height
        }
        // Normalized areas within 1e-9 relative (at least 1e-12 absolute) are equal.
        func equalArea(_ a: Double, _ b: Double) -> Bool { abs(a - b) <= max(1e-12, max(abs(a), abs(b)) * 1e-9) }
        func spatiallyBefore(_ a: SavedLayoutSlot, _ b: SavedLayoutSlot) -> Bool {
            let x = paneFrames[a.id]!, y = paneFrames[b.id]!
            if abs(x.x - y.x) > 1e-12 { return x.x < y.x }
            if abs(x.y - y.y) > 1e-12 { return x.y < y.y }
            // A captured Tabbed pane fills its first slot before its additional slots.
            if let group = document.groups.first(where: { $0.slots.contains(a.id) && $0.slots.contains(b.id) }) {
                return group.slots.firstIndex(of: a.id)! < group.slots.firstIndex(of: b.id)!
            }
            return a.id < b.id
        }
        free.sort { area($0) != area($1) ? area($0) > area($1) : spatiallyBefore($0, $1) }
        var chosen: [SavedLayoutSlot] = []
        while !free.isEmpty && chosen.count < remaining.count {
            let largest = area(free[0])
            let tier = free.prefix { equalArea(area($0), largest) }.sorted(by: spatiallyBefore)
            free.removeFirst(tier.count)
            let count = min(tier.count, remaining.count - chosen.count)
            if count == tier.count { chosen += tier; continue }
            // At the equal-area cut, solve distance over the mandatory larger slots
            // and this tier together. Larger slots have leading priority -1, so all
            // are filled; exactly k tied slots take the remaining windows. Exact ties
            // choose left-to-right, then top-to-bottom, then captured slot order.
            let candidates = chosen + tier
            let priorities = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, [chosen.contains($0) ? -1 : 0]) })
            let matched = SavedLayoutPositionMatching.assign(slots: candidates, windows: remaining,
                targets: paneFrames, in: bounds, fillPriorities: priorities,
                slotOrder: candidates.sorted(by: spatiallyBefore).map(\.id))
            chosen += tier.filter { matched[$0.id] != nil }
        }
        if let front = remaining.first, !chosen.isEmpty {
            let largest = chosen.map(area).max()!
            let equal = chosen.filter { equalArea(area($0), largest) }.sorted(by: spatiallyBefore)
            let slot = equal.min {
                let a = SavedLayoutPositionMatching.distance(front, to: paneFrames[$0.id]!, in: bounds)
                let b = SavedLayoutPositionMatching.distance(front, to: paneFrames[$1.id]!, in: bounds)
                return abs(a - b) > 1e-12 ? a < b : spatiallyBefore($0, $1)
            }!
            assignments[slot.id] = front.id; reasons[slot.id] = .largestFreeSlot; claimed.insert(front.id)
            chosen.removeAll { $0.id == slot.id }; remaining.removeFirst()
        }
        let nearest = SavedLayoutPositionMatching.assign(slots: chosen, windows: remaining, targets: targets, in: bounds)
        for (slot, id) in nearest {
            assignments[slot] = id; reasons[slot] = .nearestPosition; claimed.insert(id)
        }
        for slot in document.slots where assignments[slot.id] == nil { reasons[slot.id] = .empty }

        // Step 4 includes already-added extras when looking for the same app or tab-mates.
        for group in document.groups {
            tabs[group.id] = group.slots.compactMap { assignments[$0] }
            selectedTabs[group.id] = group.selected.flatMap { assignments[$0] } ?? tabs[group.id]?.first
        }
        for window in orderedWindows where !claimed.contains(window.id) {
            if window.matchingFrame != nil { unassignedForeignWindowIDs.append(window.id); continue }
            guard document.mode == .tabbed else {
                extras[window.id] = document.mode == .manual ? .untouched : .floating
                continue
            }
            // A captured group without slots is a saved empty pane. Like `.empty`,
            // it stays empty and cannot receive an extra tab, even when it is nearest.
            let groups = document.groups.filter { !$0.slots.isEmpty }
            func nearestGroup(_ candidates: [SavedLayoutGroup]) -> SavedLayoutGroup? {
                candidates.min {
                    let a = SavedLayoutPositionMatching.distance(window, to: paneFrames[$0.slots[0]]!, in: bounds)
                    let b = SavedLayoutPositionMatching.distance(window, to: paneFrames[$1.slots[0]]!, in: bounds)
                    if abs(a - b) > 1e-12 { return a < b }
                    return document.groups.firstIndex(of: $0)! < document.groups.firstIndex(of: $1)!
                }
            }
            let sameApp = groups.filter { group in
                (tabs[group.id] ?? []).contains { byID[$0]?.bundleID.caseInsensitiveCompare(window.bundleID) == .orderedSame }
            }
            let listed = groups.filter { group in group.slots.contains { slot in
                preferences[slot]!.contains { $0.caseInsensitiveCompare(window.bundleID) == .orderedSame }
            } }
            var mates: [WindowID] = []
            if case let .tabbed(previous) = currentSession { mates = previous.pane(containing: window.id)?.tabs ?? [] }
            let counts = groups.map { group in (tabs[group.id] ?? []).filter { mates.contains($0) }.count }
            let most = counts.max() ?? 0
            let tabMates = zip(groups, counts).filter { $0.1 == most && most > 0 }.map(\.0)
            let candidates: [SavedLayoutGroup]
            let reason: SavedLayoutTabReason
            if !sameApp.isEmpty { candidates = sameApp; reason = .sameApp }
            else if !listed.isEmpty { candidates = listed; reason = .listedApp }
            else if !tabMates.isEmpty { candidates = tabMates; reason = .tabMates }
            else { candidates = groups; reason = .nearestPane }
            guard let group = nearestGroup(candidates) else {
                extras[window.id] = .floating; continue
            }
            tabs[group.id, default: []].append(window.id)
            let isKnownFrontmost = window.id == orderedWindows.first?.id && window.frontRank != .max
            if isKnownFrontmost || selectedTabs[group.id] == nil { selectedTabs[group.id] = window.id }
            extras[window.id] = .tab(groupID: group.id, reason: reason)
        }
        for group in document.groups {
            let slotOrder = Dictionary(uniqueKeysWithValues: group.slots.enumerated().compactMap { index, slot in
                assignments[slot].map { ($0, index) }
            })
            tabs[group.id]?.sort {
                let a = byID[$0]!.frontRank, b = byID[$1]!.frontRank
                if a != b { return a < b }
                let x = slotOrder[$0] ?? .max, y = slotOrder[$1] ?? .max
                return x != y ? x < y : $0 < $1
            }
        }
    }
}
