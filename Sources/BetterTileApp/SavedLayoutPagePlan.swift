// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 LMC-Karma

import BetterTileCore
import Foundation
import Observation

/// Event-owned plan cache. Rendering reads values only. Inventory bursts get one read per 250 ms;
/// selection/target changes refresh immediately and do not wait for the inventory throttle.
@MainActor @Observable final class SavedLayoutPagePlan {
    private(set) var preview: SavedLayoutPreview?
    private(set) var workArea: BTRect?
    private(set) var problem: String?
    private var areas: [String: BTRect] = [:]
    @ObservationIgnored private var pending: Task<Void, Never>?
    @ObservationIgnored var delay: (Duration) async -> Void

    init(clock: BetterTileClock = .live) {
        delay = { try? await clock.sleep(for: $0) }
    }

    func refresh(document: SavedLayoutDocument?, displayID: DisplayID?, identity: String?,
                 displays: [DisplaySnapshot], unavailable: String?, disconnectedArea: BTRect? = nil,
                 read: (SavedLayoutDocument, DisplayID) throws -> SavedLayoutPreview) {
        preview = nil; problem = unavailable
        let key = identity ?? displayID?.rawValue
        if let displayID, let area = displays.first(where: { $0.id == displayID })?.visibleFrame {
            workArea = area
            if let key { areas[key] = area }
        } else { workArea = key.flatMap { areas[$0] } ?? disconnectedArea }
        guard unavailable == nil, let document, let displayID,
              displays.contains(where: { $0.id == displayID }) else { return }
        do {
            let result = try read(document, displayID)
            preview = result; problem = result.problem
            if let area = result.workArea { workArea = area; if let key { areas[key] = area } }
        } catch { problem = SavedLayoutApplier.failureMessage(error) }
    }
    /// A choice updates the displayed proposal immediately, without discarding the last Apply result.
    func updateChoices(from value: SavedLayoutPreview) {
        guard preview?.document == value.document, preview?.displayID == value.displayID else { return }
        preview = value; problem = value.problem; workArea = value.workArea ?? workArea
    }
    func inventoryChanged(_ refresh: @escaping @MainActor () -> Void) {
        guard pending == nil else { return }
        pending = Task { [weak self] in
            guard let self else { return }
            await delay(.milliseconds(250))
            guard !Task.isCancelled else { return }
            pending = nil
            refresh()
        }
    }
    func cancel() { pending?.cancel(); pending = nil }
}

extension SavedLayoutPreviewRow {
    func outcome(reason: SavedLayoutSlotReason? = nil, screenName: (DisplayID) -> String) -> String {
        switch status {
        case .matched:
            if let sourceDisplayID { return "Moves from " + screenName(sourceDisplayID) }
            if reason == .largestFreeSlot { return "Frontmost window · largest free pane" }
            if reason == .chosen { return "Uses the chosen window" }
            if eligibleWindowCount > 1 { return "\(eligibleWindowCount) windows · nearest is used" }
            return "Uses its open window"
        case let .severalWindows(windows):
            if reason == .largestFreeSlot { return "Frontmost window · largest free pane" }
            if reason == .chosen { return "Uses the chosen window" }
            return "\(windows.count) windows · nearest is used"
        case .empty: return "Leaves the pane empty"
        case .onAnotherDesktop: return "Only on another desktop"
        case .notInstalled: return "Not installed"
        }
    }
}


extension SavedLayoutPagePlan {
    /// Reuses the Details formatter with the exact cached preview plan. No inventory reads.
    func presentation(groups: AppGroupsDocument, resolvedBundleIDs: [AppGroupEntry: String],
                      name: (String) -> String, displayName: (DisplayID) -> String) -> SavedLayoutPlanPresentation? {
        guard let preview, let plan = preview.plan, let area = preview.workArea ?? workArea else { return nil }
        var windows: [WindowID: SavedLayoutEligibleWindow] = [:]
        var names = preview.windowNames
        for window in preview.windows {
            guard let bundle = window.bundleIdentifier else { continue }
            windows[window.id] = .init(id: window.id, bundleID: bundle, frame: window.frame, constraints: window.constraints)
        }
        var moved: [WindowID: String] = [:]
        for row in preview.rows {
            let snapshots: [WindowSnapshot]
            switch row.status {
            case let .matched(window): snapshots = [window]
            case let .severalWindows(list): snapshots = list
            default: snapshots = []
            }
            for window in snapshots {
                guard let bundle = window.bundleIdentifier else { continue }
                windows[window.id] = .init(id: window.id, bundleID: bundle, frame: window.frame, constraints: window.constraints)
                if names[window.id] == nil { names[window.id] = row.appName }
                if let source = row.sourceDisplayID { moved[window.id] = displayName(source) }
            }
        }
        var presentation = SavedLayoutPlanPresentation(document: preview.document, plan: plan, windows: Array(windows.values),
            workArea: area, groups: groups, resolvedBundleIDs: resolvedBundleIDs, name: name,
            windowName: { names[$0] ?? "An app that is not installed" },
            uninstalledBundleIDs: Set(groups.expand(preview.document.slots.flatMap(\.prefer), resolvedBundleIDs: resolvedBundleIDs).bundleIDs
                .filter { name($0) == "An app that is not installed" }), movedFrom: moved)
        presentation.issues = SavedLayoutPlanPresentation.preferenceIssues(document: preview.document,
            groups: groups, resolvedBundleIDs: resolvedBundleIDs)
        return presentation
    }
}
