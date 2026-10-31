// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 LMC-Karma

import BetterTileCore
import Foundation
import Observation

enum SavedLayoutSlotStatus: Equatable {
    case waiting, placed, moved, needsChoice, skipped, empty
    case failed(reason: String)
    var text: String {
        switch self {
        case .waiting: "Applying…"
        case .placed: "Placed"
        case .moved: "Moved from another display"
        case .needsChoice: "Choose a window"
        case .skipped: "Skipped"
        case .empty: "Empty"
        case let .failed(reason): reason
        }
    }
}

struct SavedLayoutApplyOwner: Equatable {
    var document: SavedLayoutDocument
    var desktop: SavedLayoutDesktop
    var fileURL: URL? = nil
}

struct SavedLayoutApplyRuntime {
    var isStarting = false
    var isRunning = false
    var lastRun: SavedLayoutRun?
    var canUndo = false
    var earlierUndoAvailable = false
    var undoUnavailableReason: String?
    var message: String?
    var slotStatuses: [String: SavedLayoutSlotStatus] = [:]
    var owner: SavedLayoutApplyOwner?
}

@Observable @MainActor final class SavedLayoutApplySession {
    enum Phase { case idle, reviewing(SavedLayoutPreview), applying, applied }
    nonisolated static let unavailableChoice = "The chosen window is no longer available. Choose a window again."
    private(set) var preview: SavedLayoutPreview?
    /// Nil delegates to a completed refusal; an edited selection overrides that run's choices.
    private var pendingChoices: [String: WindowID]? = [:]
    private(set) var choices: [String: WindowID] {
        get { pendingChoices ?? run?.retryChoices ?? [:] }
        set { pendingChoices = newValue }
    }
    private var previewProblem: String?
    private var reviewing = false
    private var hasPendingChoices: Bool { !choices.isEmpty }
    private var submitted = false
    private var refusedWhileApplying = false
    private var previousRunDate: Date?
    private var adoptedOwner: SavedLayoutApplyOwner?
    private let readRuntime: () -> SavedLayoutApplyRuntime
    private let makePreview: (SavedLayoutDocument, DisplayID?, [String: WindowID]) throws -> SavedLayoutPreview
    private let start: (SavedLayoutDocument, DisplayID?, [String: WindowID]) -> Void
    private let undoRun: () -> Void
    var isStarting: Bool { readRuntime().isStarting }

    convenience init(applier: SavedLayoutApplier, positions: @escaping () -> SavedLayoutPositionContext? = { nil }) {
        self.init(preview: { try applier.preview($0, displayID: $1, choices: $2, positions: positions()) },
                  start: { applier.start($0, displayID: $1, choices: $2, positions: positions()) },
                  runtime: { .init(isStarting: applier.isStarting, isRunning: applier.isBusy, lastRun: applier.lastRun,
                                   canUndo: applier.lastRun.map { applier.canUndo($0) } == true,
                                   earlierUndoAvailable: applier.lastRun.map { !$0.offersUndo && applier.canUndo($0) } == true,
                                   undoUnavailableReason: applier.lastRun.flatMap { applier.undoUnavailableReason($0) },
                                   message: applier.message, slotStatuses: applier.slotStatuses,
                                   owner: applier.lastDocument.flatMap { document in applier.lastDesktop.map { .init(document: document, desktop: $0, fileURL: applier.lastLayoutURL) } }) },
                  undo: { applier.startUndo() })
    }
    init(preview: @escaping (SavedLayoutDocument, DisplayID?, [String: WindowID]) throws -> SavedLayoutPreview,
         start: @escaping (SavedLayoutDocument, DisplayID?, [String: WindowID]) -> Void,
         runtime: @escaping () -> SavedLayoutApplyRuntime = { .init() }, undo: @escaping () -> Void = {}) {
        makePreview = preview; self.start = start; readRuntime = runtime; undoRun = undo
    }
    var problem: String? {
        if refusedWhileApplying, isStarting || readRuntime().isRunning { return SavedLayoutApplier.applyingBusy }
        if let previewProblem { return previewProblem }
        if !reviewing, run?.retryChoices != nil { return Self.unavailableChoice }
        let runtime = readRuntime()
        return submitted && !isStarting && !runtime.isRunning && run == nil ? runtime.message : nil
    }
    var phase: Phase {
        if isStarting || readRuntime().isRunning { return .applying }
        if reviewing, let preview { return .reviewing(preview) }
        return run != nil ? .applied : .idle
    }
    var run: SavedLayoutRun? {
        let runtime = readRuntime()
        guard !isStarting, submitted, let preview, let run = runtime.lastRun,
              adoptedOwner == nil || adoptedOwner == runtime.owner,
              run.date != previousRunDate, run.layoutName == preview.document.name, run.displayID == preview.displayID else { return nil }
        return run
    }
    var canUndo: Bool {
        let runtime = readRuntime()
        return run != nil && runtime.canUndo && (run?.offersUndo == true || runtime.earlierUndoAvailable)
    }
    var undoUnavailableReason: String? { run == nil ? nil : readRuntime().undoUnavailableReason }
    var owner: SavedLayoutApplyOwner? { readRuntime().owner }
    func refuseTarget(_ reason: String) { previewProblem = reason }
    func clearTargetRefusal(_ reason: String) { if previewProblem == reason { previewProblem = nil } }
    func refuseApplyingAction() { refusedWhileApplying = true }
    func apply(document: SavedLayoutDocument, displayID: DisplayID? = nil) {
        guard !readRuntime().isRunning, !isStarting else { refuseApplyingAction(); return }
        let pending = hasPendingChoices && preview?.document == document
            && (displayID == nil || preview?.displayID == displayID) ? choices : [:]
        refusedWhileApplying = false; choices = pending
        submitted = false; reviewing = false; previewProblem = nil
        do {
            let value = try makePreview(document, displayID, pending)
            preview = value; previewProblem = value.problem
            guard value.problem == nil else { reviewing = true; return }
            guard value.plan != nil || !value.rows.isEmpty || pending.isEmpty else {
                previewProblem = SavedLayoutApplier.desktopNotReady
                reviewing = true
                return
            }
            guard pending.allSatisfy({ slot, id in value.rows.first { $0.id == slot }?.choiceWindows.contains { $0.id == id } == true }) else {
                previewProblem = Self.unavailableChoice
                choices = pending.filter { slot, id in
                    value.rows.first { $0.id == slot }?.choiceWindows.contains { $0.id == id } == true
                }
                reviewing = true; return
            }
            choices = pending
            begin()
        } catch { preview = nil; previewProblem = SavedLayoutApplier.failureMessage(error) }
    }
    /// Reads fresh candidates without releasing a completed Apply on the same layout and display.
    func review(document: SavedLayoutDocument, displayID: DisplayID) {
        guard !readRuntime().isRunning, !isStarting else { refuseApplyingAction(); return }
        if preview?.document != document || preview?.displayID != displayID {
            choices = [:]; submitted = false
            previousRunDate = nil; adoptedOwner = nil
        }
        do {
            let value = try makePreview(document, displayID, choices)
            if value.problem == nil, value.plan != nil {
                choices = choices.filter { slot, id in
                    value.rows.first { $0.id == slot }?.choiceWindows.contains { $0.id == id } == true
                }
            }
            preview = value; previewProblem = value.problem; reviewing = true
        } catch { previewProblem = SavedLayoutApplier.failureMessage(error) }
    }
    @discardableResult func choose(window: WindowID, forSlot slot: String) -> Bool {
        guard reviewing, previewProblem == nil, let preview else { return false }
        guard preview.rows.first(where: { $0.id == slot })?.choiceWindows.contains(where: { $0.id == window }) == true else {
            previewProblem = Self.unavailableChoice
            return false
        }
        var pending = choices.filter { $0.value != window || $0.key == slot }
        pending[slot] = window
        do {
            let value = try makePreview(preview.document, preview.displayID, pending)
            guard value.problem == nil else { previewProblem = value.problem; return false }
            guard value.rows.first(where: { $0.id == slot })?.choiceWindows.contains(where: { $0.id == window }) == true else {
                previewProblem = Self.unavailableChoice
                return false
            }
            pending = pending.filter { slot, id in
                value.rows.first { $0.id == slot }?.choiceWindows.contains { $0.id == id } == true
            }
            self.preview = value; choices = pending
            return true
        } catch { previewProblem = SavedLayoutApplier.failureMessage(error); return false }
    }
    func confirm() { if reviewing, previewProblem == nil, preview?.problem == nil { begin() } }
    @discardableResult func adoptRun(document: SavedLayoutDocument) -> Bool {
        let runtime = readRuntime()
        guard let owner = runtime.owner, owner.document == document, runtime.isRunning || runtime.lastRun != nil else { return false }
        adoptedOwner = owner
        pendingChoices = nil
        preview = .init(document: document, displayID: owner.desktop.displayID, rows: [], problem: nil)
        submitted = true; reviewing = false; previousRunDate = nil; previewProblem = nil
        return true
    }
    func cancelReview() { refusedWhileApplying = false; reviewing = false; submitted = false; preview = nil; choices = [:]; previewProblem = nil; adoptedOwner = nil }
    func reset() {
        guard !readRuntime().isRunning, !isStarting else { refuseApplyingAction(); return }
        cancelReview()
    }
    func undo() { if canUndo { undoRun() } }
    func state(forSlot slot: String) -> SavedLayoutSlotStatus? { readRuntime().slotStatuses[slot] }
    private func begin() {
        guard let preview else { return }
        previousRunDate = readRuntime().lastRun?.date; submitted = true; reviewing = false; refusedWhileApplying = false
        adoptedOwner = nil
        start(preview.document, preview.displayID, choices)
        pendingChoices = nil
    }
}
#if BETTERTILE_TEST_HOOKS
extension SavedLayoutApplySession { var isStartingForTesting: Bool { isStarting } }
#endif
