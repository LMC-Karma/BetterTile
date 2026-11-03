// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 LMC-Karma

import AppKit
import BetterTileCore
import BetterTileMacOS
import Observation

/// A pill that the runtime asks the model to show on one display: a cancelled wait, or an offer to apply.
struct DisplayTriggerNotice {
    var title: String
    var detail: String?
    var kind: ResultPillFeedback.Kind
    var displayID: DisplayID?
    var actions: [ResultPillAction]
}

/// Applies bound Saved Layouts when their display set connects.
///
/// The model sends display and wake events here, after its own display-refresh debounce. The pure
/// `DisplayTriggerReducer` decides. This class owns the waiting: it lets macOS and BetterTile's own
/// stabilization finish, then waits until the windows of the target displays stop moving, then runs one
/// automatic Apply for each bound display. A mouse press or key press cancels the wait or the Apply.
/// An automatic Apply never opens apps and never guesses between windows.
@Observable @MainActor final class DisplayTriggerRuntime {
    private let applier: SavedLayoutApplier
    private var reducer: DisplayTriggerReducer
    /// The newest automatic result for each layout file, kept in memory for the Last run row.
    var runs: [String: SavedLayoutRun] = [:]

    var triggers: () -> [DisplayTrigger] = { [] }
    var liveDisplays: () -> [LiveDisplay] = { [] }
    /// Preserve file-read errors so a deleted layout can be skipped without hiding invalid files.
    var loadLayout: (String) throws -> SavedLayoutDocument? = { _ in nil }
    /// True once Space stabilization and Adaptive or Tabbed settlement have finished for a display.
    var isReady: (DisplayID) -> Bool = { _ in true }
    /// True while a window, divider, or tab drag or the Layout Wheel is active, or a mouse button is held.
    var isInteracting: () -> Bool = { false }
    /// Frames of the eligible windows on these displays, or nil when they cannot be read now.
    var observeFrames: (Set<DisplayID>) -> [WindowID: BTRect]? = { _ in nil }
    var notice: (DisplayTriggerNotice) -> Void = { _ in }
    var sleep: (Duration) async -> Void
    var uptime: () -> TimeInterval
    /// Time between two window observations. Two quiet observations this far apart end the wait.
    var tick: Duration = .milliseconds(150)
    private var tickSeconds: TimeInterval {
        Double(tick.components.seconds) + Double(tick.components.attoseconds) / 1e18
    }
    /// After this long the Apply runs anyway, and skips the windows that still moved.
    var settleLimit: TimeInterval = 3
    var observesInput = true
    /// True while the lock screen is the frontmost app. Public API only: the frontmost app's bundle identifier.
    var isScreenLocked: () -> Bool = { false }
    /// How long an attempt waits for the lock screen to go away before it is dropped, without a pill.
    var lockLimit: Duration = .seconds(600)
    var lockWait: (Duration) async -> Void
    static let loginWindowBundleID = "com.apple.loginwindow"

    private var settleTask: Task<Void, Never>?
    private var watchTask: Task<Void, Never>?
    private var applyTask: Task<Void, Never>?
    private var lockTask: Task<Void, Never>?
    private var moving: Set<WindowID> = []
    private var started: Set<String> = []
    private var localMonitor: Any?
    private var globalMonitor: Any?
    /// A lock timeout or another session's activation must not release this session's hold.
    private var sessionIsActive = true

    init(applier: SavedLayoutApplier, initial: [DisplayFingerprint], clock: BetterTileClock = .live) {
        let origin = clock.now
        sleep = { try? await clock.sleep(for: $0) }
        lockWait = { try? await clock.sleep(for: $0) }
        uptime = {
            let elapsed = origin.duration(to: clock.now).components
            return Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
        }
        self.applier = applier
        reducer = DisplayTriggerReducer(initial: initial)
    }

    /// True when no wait and no Apply is pending.
    var isIdle: Bool { !reducer.isWaiting && !reducer.isApplying }

    // MARK: Events

    /// The display set may have changed. Call after the display-refresh debounce.
    func displaysChanged() {
        noteLockScreen()
        send(.displaysChanged(fingerprints()))
    }

    /// The Mac or its displays are going to sleep. Arms one wake Apply and holds display changes until wake.
    func sleeping() { send(.sleep) }

    /// The Mac or its displays woke up. Each sleep allows one wake Apply, however many notifications follow.
    func wake() {
        noteLockScreen()
        send(.wake(fingerprints()))
    }

    /// An app became active. When the lock screen was up, a different app means the Mac is unlocked.
    func applicationActivated(bundleID: String?) {
        guard sessionIsActive else { return }
        if bundleID == Self.loginWindowBundleID || isScreenLocked() { holdForLock(); return }
        if reducer.isLocked { send(.unlocked) }
        presentDeferredResults()
    }

    /// The user session became active again (for example after fast user switching).
    func sessionBecameActive() {
        sessionIsActive = true
        if isScreenLocked() { holdForLock(); return }
        if reducer.isLocked { send(.unlocked) }
        presentDeferredResults()
    }

    /// Another user's session took over (fast user switching). Hold attempts like the lock screen does, so no
    /// Apply runs, and no pill appears, in a session nobody is watching.
    func sessionResigned() { sessionIsActive = false; holdForLock() }

    /// Holds the attempt while the lock screen is up. It stays pending, unused, until unlock or `lockLimit`.
    private func noteLockScreen() {
        guard !sessionIsActive || isScreenLocked() else { return }
        holdForLock()
    }

    private func holdForLock() {
        settleTask?.cancel(); watchTask?.cancel()
        settleTask = nil; watchTask = nil
        send(.locked)
        guard lockTask == nil else { return }
        lockTask = Task { [weak self] in
            guard let self else { return }
            await self.lockWait(self.lockLimit)
            guard !Task.isCancelled else { return }
            self.lockTask = nil
            self.send(.lockExpired)
        }
    }

    /// A mouse button or key was pressed.
    func userInput() { send(.userInput) }

    func stop() {
        settleTask?.cancel(); watchTask?.cancel(); applyTask?.cancel(); lockTask?.cancel()
        settleTask = nil; watchTask = nil; applyTask = nil; lockTask = nil
        removeMonitors()
        applier.discardDeferredAutomaticResults()
    }

    private func fingerprints() -> [DisplayFingerprint] { liveDisplays().map(\.fingerprint) }

    private func send(_ event: DisplayTriggerEvent) {
        for action in reducer.handle(event, triggers: triggers()) { perform(action) }
        if !reducer.isLocked { lockTask?.cancel(); lockTask = nil }
        if !(reducer.isWaiting && !reducer.isAwaitingUnlock) && !reducer.isApplying { removeMonitors() }
    }

    private func perform(_ action: DisplayTriggerAction) {
        switch action {
        case let .settle(token):
            installMonitors()
            settleTask?.cancel(); watchTask?.cancel()
            moving = []
            settleTask = Task { [weak self] in await self?.wait(token) }
        case let .apply(fires, offers):
            settleTask = nil
            for offer in offers { offerApply(offer) }
            guard !fires.isEmpty else { return }
            started = []
            applyTask = Task { [weak self] in
                await self?.run(fires)
                self?.send(.applyFinished)
            }
        case let .cancel(fires, applying):
            settleTask?.cancel(); watchTask?.cancel()
            settleTask = nil; watchTask = nil
            if applying {
                // The applier shows its own pill, with Undo for what it already placed.
                applyTask?.cancel()
                applier.cancel()
            }
            for fire in fires where !applying || !started.contains(fire.layoutFile) {
                declined(fire, reason: "You were moving windows.")
            }
        case .suspendApply:
            applyTask?.cancel()
            applier.cancel()
        }
    }

    // MARK: Waiting

    private func targets() -> [DisplayID] {
        let live = liveDisplays()
        let fingerprints = live.map(\.fingerprint)
        return triggers().filter(\.enabled).compactMap { trigger in
            DisplaySetMatcher.match(stored: trigger.displays, live: fingerprints).pairs[trigger.target].map { live[$0].id }
        }
    }

    /// Waits for BetterTile's own stabilization, then for two quiet window observations. Postpones while the
    /// user is dragging. Ends with `.settled`, which lets the reducer judge the newest display set.
    private func wait(_ token: Int) async {
        var detector = DisplaySettleDetector(quietInterval: tickSeconds, limit: settleLimit)
        let begun = uptime()
        while !Task.isCancelled, reducer.currentToken == token {
            // The lock screen came up during the wait. Keep the attempt for the unlock.
            if !sessionIsActive || isScreenLocked() {
                noteLockScreen()
                return
            }
            if isInteracting() || applier.isRunning {
                send(.settled(token: token, live: fingerprints(), busy: true))
                watchForInteractionEnd()
                return
            }
            let displays = Set(targets())
            if displays.allSatisfy(isReady), let frames = observeFrames(displays) {
                switch detector.observe(frames, at: uptime()) {
                case .quiet: return finish(token, moving: [])
                case let .timedOut(still): return finish(token, moving: still)
                case .waiting: break
                }
            } else if uptime() - begun >= settleLimit {
                return finish(token, moving: [])
            }
            await sleep(tick)
        }
    }

    private func finish(_ token: Int, moving still: Set<WindowID>) {
        guard !Task.isCancelled, reducer.currentToken == token else { return }
        moving = still
        send(.settled(token: token, live: fingerprints(), busy: false))
    }

    /// Runs only while an Apply is postponed. It ends when the drag or the other Apply ends.
    private func watchForInteractionEnd() {
        watchTask?.cancel()
        watchTask = Task { [weak self] in
            while let self, !Task.isCancelled, self.isInteracting() || self.applier.isRunning {
                await self.sleep(.milliseconds(250))
            }
            guard let self, !Task.isCancelled else { return }
            self.send(.interactionEnded)
        }
    }

    // MARK: Applying

    private func run(_ fires: [DisplayTriggerFire]) async {
        for fire in fires {
            guard !Task.isCancelled, canApplyInSession else { return }
            started.insert(fire.layoutFile)
            let live = liveDisplays()
            guard let trigger = triggers().first(where: { $0.layoutFile == fire.layoutFile }), trigger.enabled else { continue }
            let match = DisplaySetMatcher.match(stored: trigger.displays, live: live.map(\.fingerprint))
            guard let index = match.pairs[trigger.target], live.indices.contains(index) else { continue }
            if match.kind == .uncertain {
                offerApply(.init(layoutFile: fire.layoutFile, liveIndex: index))
                continue
            }
            guard match.kind == .exact else { continue }
            let display = live[index].id
            let loaded: SavedLayoutDocument?
            do { loaded = try loadLayout(fire.layoutFile) }
            catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
                // Delete keeps the binding by default. Its card shows “Layout missing” until removal or restoration.
                continue
            } catch { loaded = nil }
            guard let document = loaded else {
                let issue = SavedLayoutApplyIssue(.other, "The layout file could not be read.")
                publishNotice(fire.layoutFile, run: .init(layoutName: fire.layoutFile, date: Date(), displayID: display,
                    result: .init(issues: [issue])), displayID: display, actions: [])
                continue
            }
            let begin = Date()
            // No slot may open an app, so a missing app is skipped and reported.
            let result = await applier.apply(document, displayID: display, excluding: moving, automatic: true,
                layoutFileID: fire.layoutFile, sessionIsAvailable: { [weak self] in
                    self?.canApplyInSession == true
                }, validating: { [weak self] in
                    self?.bindingIsCurrent(fire.layoutFile, on: display) == true
                })
            record(fire.layoutFile, document, display, since: begin, result: result)
            // The session can return after publication but before this task resumes.
            presentDeferredResults()
            guard canApplyInSession else { return }
            // An exact match can become uncertain while App Groups load or a commit awaits.
            let latest = liveDisplays()
            if let trigger = triggers().first(where: { $0.layoutFile == fire.layoutFile }), trigger.enabled {
                let match = DisplaySetMatcher.match(stored: trigger.displays, live: latest.map(\.fingerprint))
                if match.kind == .uncertain, let index = match.pairs[trigger.target], latest.indices.contains(index) {
                    offerApply(.init(layoutFile: fire.layoutFile, liveIndex: index))
                }
            }
        }
    }

    /// This predicate travels with the transaction, including its coordinator validation callback.
    private func bindingIsCurrent(_ file: String, on display: DisplayID) -> Bool {
        guard canApplyInSession else { return false }
        let live = liveDisplays()
        guard let trigger = triggers().first(where: { $0.layoutFile == file }), trigger.enabled else { return false }
        let match = DisplaySetMatcher.match(stored: trigger.displays, live: live.map(\.fingerprint))
        guard match.kind == .exact, let index = match.pairs[trigger.target], live.indices.contains(index) else { return false }
        return live[index].id == display
    }

    private var canApplyInSession: Bool {
        sessionIsActive && !reducer.isLocked && !isScreenLocked()
    }

    private func presentDeferredResults() {
        applier.presentDeferredAutomaticResults { [weak self] in self?.canApplyInSession == true }
    }

    private func record(_ file: String, _ document: SavedLayoutDocument, _ display: DisplayID, since begin: Date,
                        result: SavedLayoutApplyResult) {
        if let last = applier.lastRun, last.date >= begin, last.displayID == display {
            runs[file] = last
        } else {
            runs[file] = .init(layoutName: document.name, date: Date(), displayID: display, result: result)
        }
    }

    /// The Apply button of the Last run row and of the pills. It runs the same policy as the automatic Apply,
    /// but the user asked for it, so input does not cancel it and moving windows are not skipped.
    func applyNow(_ file: String) {
        guard !applier.isRunning, let document = try? loadLayout(file),
              let display = runs[file]?.displayID, liveDisplays().contains(where: { $0.id == display }) else { return }
        Task { [weak self] in
            let begin = Date()
            let result = await self?.applier.apply(document, displayID: display, layoutFileID: file)
            if let self, let result { self.record(file, document, display, since: begin, result: result) }
        }
    }

    // MARK: Pills

    private func declined(_ fire: DisplayTriggerFire, reason: String) {
        let live = liveDisplays()
        let display = live.indices.contains(fire.liveIndex) ? live[fire.liveIndex].id : nil
        guard let document = try? loadLayout(fire.layoutFile) else { return }
        let issue = SavedLayoutApplyIssue(.stopped, "Not applied. \(reason)")
        var result = SavedLayoutApplyResult(unplaced: document.slots.count, issues: [issue])
        result.recordSlots(document.slots.map(\.id))
        publishNotice(fire.layoutFile, run: .init(layoutName: document.name, date: Date(),
            displayID: display ?? DisplayID(rawValue: ""), result: result, declared: .cancelled),
            displayID: display, actions: [applyAction(fire.layoutFile)])
    }

    private func offerApply(_ fire: DisplayTriggerFire) {
        let live = liveDisplays()
        let display = live.indices.contains(fire.liveIndex) ? live[fire.liveIndex].id : nil
        guard let document = try? loadLayout(fire.layoutFile) else { return }
        let issue = SavedLayoutApplyIssue(.other, "These displays look like the saved set, but BetterTile can’t tell them apart. Not applied.")
        var result = SavedLayoutApplyResult(unplaced: document.slots.count, issues: [issue])
        result.recordSlots(document.slots.map(\.id))
        publishNotice(fire.layoutFile, run: .init(layoutName: document.name, date: Date(),
            displayID: display ?? DisplayID(rawValue: ""), result: result, declared: .offered),
            displayID: display, actions: [applyAction(fire.layoutFile)])
    }

    private func publishNotice(_ file: String, run: SavedLayoutRun, displayID: DisplayID?, actions: [ResultPillAction]) {
        runs[file] = run
        guard canApplyInSession else { return }
        let presentation = run.presentation
        notice(.init(title: presentation.title, detail: presentation.pillDetail,
                     kind: SavedLayoutApplier.pillKind(presentation.severity), displayID: displayID, actions: actions))
    }

    private func applyAction(_ file: String) -> ResultPillAction {
        ResultPillAction(title: "Apply", accessibilityLabel: "Apply the Saved Layout now") { [weak self] in self?.applyNow(file) }
    }

    // MARK: Input

    private func installMonitors() {
        guard observesInput, localMonitor == nil else { return }
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.userInput()
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
            Task { @MainActor in self?.userInput() }
        }
    }

    private func removeMonitors() {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        localMonitor = nil; globalMonitor = nil
    }
}
