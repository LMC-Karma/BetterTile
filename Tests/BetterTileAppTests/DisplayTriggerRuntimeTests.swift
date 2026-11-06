import BetterTileCore
import BetterTileMacOS
import BetterTileTestSupport
import Foundation
import Testing
@testable import BetterTileApp

/// Two displays, `main` and `second`, one desktop each, and the real applier and runtime on top of the fake system.
@MainActor private final class RuntimeHarness {
    let system = FakeAppWindowSystem()
    let clock = ManualClock()
    let second = DisplaySnapshot(id: DisplayID(rawValue: "second"), frame: BTRect(x: 1000, y: 0, width: 1200, height: 800),
                                 visibleFrame: BTRect(x: 1000, y: 0, width: 1200, height: 800), isMain: false)
    let coordinator: WindowCoordinator
    var applier: SavedLayoutApplier!
    var runtime: DisplayTriggerRuntime!
    var sessions: [DisplayID: SavedLayoutSession] = [:]
    var commits: [DisplayID] = []
    var now: TimeInterval = 1000
    var notices: [DisplayTriggerNotice] = []
    var feedback: [SavedLayoutFeedback] = []
    var triggers: [DisplayTrigger] = []
    var layouts: [String: SavedLayoutDocument] = [:]
    var connected = [true, false]
    var interacting = false
    var locked = false
    var refuseCommit = false
    var beforeCommit: (() async -> Void)?
    var movingWindows: Set<WindowID> = []
    var frameReads = 0
    var onSleep: (() -> Void)?
    private var drift = 0.0

    let mainFingerprint = DisplayFingerprint(uuid: "MAIN", vendor: 1, model: 10, serial: 1, builtIn: true, name: "Laptop",
                                             frame: BTRect(x: 0, y: 0, width: 1000, height: 800))
    let secondFingerprint = DisplayFingerprint(uuid: "SECOND", vendor: 2, model: 20, serial: 2, builtIn: false, name: "Studio",
                                               frame: BTRect(x: 1000, y: 0, width: 1200, height: 800))

    var main: DisplayID { system.mainDisplay.id }
    var live: [LiveDisplay] {
        [connected[0] ? LiveDisplay(id: main, fingerprint: mainFingerprint) : nil,
         connected[1] ? LiveDisplay(id: second.id, fingerprint: secondFingerprint) : nil].compactMap { $0 }
    }

    init() {
        coordinator = WindowCoordinator(system: system)
        system.windows = []
        system.availableDisplays = [system.mainDisplay, second]
        system.desktopObservation = NativeDesktopObservation(
            currentSpaceByDisplay: [main: .init(rawValue: 1), second.id: .init(rawValue: 2)],
            knownSpacesByDisplay: [main: [.init(rawValue: 1)], second.id: [.init(rawValue: 2)]])
        applier = SavedLayoutApplier(snapshot: { [unowned self] in self.snapshot() },
            commit: { [unowned self] plan, desktop, _, valid in
                await self.beforeCommit?()
                guard !self.refuseCommit, valid() else { return false }
                let outcome: WindowMutationOutcome = plan.placements.isEmpty ? .applied : self.coordinator.applyPlacements(plan.placements, validating: valid)
                guard outcome.isApplied else { return false }
                self.sessions[desktop.displayID] = plan.targetSession
                self.commits.append(desktop.displayID)
                return true
            })
        applier.observesKeyboard = false
        applier.application = { id in .init(bundleIdentifier: id, name: id, url: URL(fileURLWithPath: "/fixture/\(id).app")) }


        applier.feedback = { [unowned self] in self.feedback.append($0) }
        runtime = makeRuntime(initial: [mainFingerprint])
    }

    var liveOverride: [LiveDisplay]?

    func makeRuntime(initial: [DisplayFingerprint], autoSettle: Bool = true) -> DisplayTriggerRuntime {
        let runtime = DisplayTriggerRuntime(applier: applier, initial: initial, clock: clock.clock)
        runtime.observesInput = false
        runtime.triggers = { [unowned self] in self.triggers }
        runtime.liveDisplays = { [unowned self] in self.liveOverride ?? self.live }
        runtime.loadLayout = { [unowned self] in self.layouts[$0] }
        runtime.isInteracting = { [unowned self] in self.interacting }
        runtime.isScreenLocked = { [unowned self] in self.locked }
        if autoSettle {
            runtime.sleep = { [unowned self] duration in
                self.now += Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
                self.onSleep?()
                await Task.yield()
            }
            runtime.uptime = { [unowned self] in self.now }
        }
        runtime.observeFrames = { [unowned self] displays in
            self.frameReads += 1
            self.drift += 17
            return Dictionary(uniqueKeysWithValues: self.system.windows.filter { displays.contains($0.displayID) }.map {
                var frame = $0.frame
                if self.movingWindows.contains($0.id) { frame.origin.x += self.drift }
                return ($0.id, frame)
            })
        }
        runtime.notice = { [unowned self] in self.notices.append($0) }
        runtime.isReady = { _ in true }
        return runtime
    }

    func addWindow(_ id: String, on display: DisplayID, bundle: String = "com.example.Editor") {
        system.windows.append(WindowSnapshot(id: .init(rawValue: id), processIdentifier: 42, bundleIdentifier: bundle,
            frame: .init(x: display == main ? 50 : 1050, y: 50, width: 300, height: 200), displayID: display))
        let space = system.desktopObservation!.currentSpace(on: display)!
        system.desktopObservation?.windowMembership[.init(rawValue: id)] = [space]
    }

    func snapshot() -> SavedLayoutApplySnapshot {
        let observation = system.desktopObservation!
        let displays = [system.mainDisplay, second].filter { display in live.contains { $0.id == display.id } }
        let visible = system.windows.filter { window in displays.contains { $0.id == window.displayID } }
        return .init(observation: observation, displays: displays, windows: visible, knownWindows: visible, sessions: sessions,
                     generation: 0, isStable: true, readyDisplays: Set(displays.map(\.id)))
    }

    func document(_ name: String = "Studio layout", bundle: String = "com.example.Editor") -> SavedLayoutDocument {
        .init(name: name, mode: .bento, layout: .slot("slot"), slots: [.init(id: "slot", bundleID: bundle)])
    }

    /// Binds `layouts[file]` to the second display of the pair, with the switches given.
    func bind(_ file: String = "studio.json", enabled: Bool = true, wake: Bool = false, target: Int = 1,
              displays: [DisplayFingerprint]? = nil) {
        layouts[file] = layouts[file] ?? document()
        triggers.append(DisplayTrigger(layoutFile: file, enabled: enabled, alsoAfterWake: wake,
                                       displays: displays ?? [mainFingerprint, secondFingerprint], target: target))
    }

    func connectSecond() { connected[1] = true; runtime.displaysChanged() }

    /// Join forward work, or observe a registered lock hold, without spinning
    /// toward a state that intentionally cannot become idle until an unlock.
    func finish(until expected: () -> Bool = { true }) async {
        let executor = ContinuousClock() // real-time: bounds native executor completion while synthetic policy time stays fixed
        let deadline = executor.now.advanced(by: .seconds(45)) // real-time: one total executor watchdog below the existing one-minute test limit
        var joined: Set<Task<Void, Never>> = []
        func remaining() -> Duration {
            max(.zero, deadline - executor.now) // real-time: remaining executor watchdog budget, not a product delay
        }
        func ready() -> Bool {
            let fields = Mirror(reflecting: runtime!).children
            let reducer = fields.first { $0.label == "reducer" || $0.label == "_reducer" }?.value as? DisplayTriggerReducer
            let held = reducer?.isAwaitingUnlock == true && clock.pendingSleepCount > 0
            return (runtime.isIdle || held) && !applier.isRunning && expected()
        }
        while true {
            if let task = forwardTasks().first(where: { !joined.contains($0) }) {
                var completed = false
                let observer = Task { @MainActor [self] in
                    await task.value
                    completed = true
                    withExtendedLifetime(self) {}
                }
                do {
                    try await waitForSavedLayoutState("The runtime's scheduled work did not finish.", timeout: remaining()) { completed } // real-time: observes actual task completion without advancing the fixture clock
                } catch {
                    observer.cancel(); task.cancel(); runtime.stop(); applier.stop()
                    Issue.record(error)
                    return
                }
                await observer.value
                joined.insert(task)
                continue
            }
            if ready() { return }
            do {
                try await waitForSavedLayoutState("The runtime did not become idle or register its unlock hold.", timeout: remaining()) { // real-time: observes task registration or a terminal fixture state
                    ready() || forwardTasks().contains { !joined.contains($0) }
                }
            } catch {
                runtime.stop(); applier.stop()
                Issue.record(error)
                return
            }
        }
    }

    private func forwardTasks() -> [Task<Void, Never>] {
        Mirror(reflecting: runtime!).children.compactMap { field in
            guard let label = field.label else { return nil }
            let name = label.hasPrefix("_") ? String(label.dropFirst()) : label
            guard ["settleTask", "applyTask", "watchTask"].contains(name) else { return nil }
            return field.value as? Task<Void, Never>
        }
    }

    func frame(_ id: String) -> BTRect { system.windows.first { $0.id.rawValue == id }!.frame }
}

/// Inspect owned resource handles without widening the product API for tests.
@MainActor private func inputMonitorState(_ runtime: DisplayTriggerRuntime) throws -> (local: Bool, global: Bool) {
    let fields = Array(Mirror(reflecting: runtime).children)
    func installed(_ name: String) throws -> Bool {
        let field = try #require(fields.first { $0.label == name || $0.label == "_" + name })
        let value = Mirror(reflecting: field.value)
        return value.displayStyle != .optional || !value.children.isEmpty
    }
    return (try installed("localMonitor"), try installed("globalMonitor"))
}

@MainActor @Suite(.appTestApplication, .timeLimit(.minutes(1))) struct DisplayTriggerRuntimeTests {
    // Coverage-only: register actual AppKit handles, without delivering user input.
    @Test(.settingsUI, arguments: [false, true])
    func inputMonitorsAreRemovedWhenAWaitEnds(stopping: Bool) throws {
        let h = RuntimeHarness()
        h.bind()
        h.runtime = h.makeRuntime(initial: [h.mainFingerprint], autoSettle: false)
        h.runtime.observesInput = true
        defer { h.runtime.stop() }
        h.connectSecond()
        let installed = try inputMonitorState(h.runtime)
        #expect(installed.local && installed.global)
        if stopping { h.runtime.stop() } else { h.runtime.userInput() }
        let removed = try inputMonitorState(h.runtime)
        #expect(!removed.local && !removed.global)
    }

    @Test(.settingsUI, arguments: ["completion", "cancel", "stop"])
    func inputMonitorsCoverApplyAndAreRemovedAfterItEnds(ending: String) async throws {
        let h = RuntimeHarness()
        h.addWindow("editor", on: h.second.id)
        h.bind()
        h.runtime.observesInput = true
        var resume: CheckedContinuation<Void, Never>?
        h.beforeCommit = { await withCheckedContinuation { resume = $0 } }
        defer { resume?.resume(); h.applier.stop(); h.runtime.stop() }
        h.connectSecond()
        try #require(await waitFor { resume != nil })
        let installed = try inputMonitorState(h.runtime)
        #expect(installed.local && installed.global)
        if ending == "cancel" { h.runtime.userInput() }
        if ending == "stop" { h.runtime.stop(); h.applier.cancel() }
        let continuation = resume
        resume = nil
        continuation?.resume()
        try #require(await waitFor { !h.applier.isRunning })
        if ending == "completion" {
            try #require(await waitFor { h.runtime.isIdle })
            #expect(h.commits == [h.second.id])
        }
        let removed = try inputMonitorState(h.runtime)
        #expect(!removed.local && !removed.global)
    }

    @Test func settlingUsesTheInjectedClockAndStopsAfterCancellation() async {
        let h = RuntimeHarness()
        h.addWindow("desk-editor", on: h.second.id)
        h.bind()
        h.runtime = h.makeRuntime(initial: [h.mainFingerprint], autoSettle: false)
        defer { h.runtime.stop() }
        h.connectSecond()
        await h.clock.waitForSleepers(count: 1)
        #expect(h.frameReads == 1 && h.commits.isEmpty)
        h.clock.advance(by: .milliseconds(149))
        #expect(h.frameReads == 1 && h.clock.pendingSleepCount == 1)
        h.clock.advance(by: .milliseconds(1))
        await h.finish()
        #expect(h.frameReads == 2 && h.commits == [h.second.id])
        // A fresh connection owns a new wait. Cancelling it prevents any later Apply.
        h.connected = [true, false]
        h.runtime.displaysChanged()
        h.connectSecond()
        await h.clock.waitForSleepers(count: 1)
        h.runtime.userInput()
        h.clock.advance(by: .seconds(10))
        await h.finish()
        #expect(h.commits == [h.second.id])
        #expect(h.clock.pendingSleepCount == 0 && h.runtime.isIdle)
    }

    @Test func aDeletedLayoutKeepsItsBindingWithoutRepeatingAConnectPill() async throws {
        let h = RuntimeHarness()
        defer { h.runtime.stop() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let files = SavedLayoutFiles(directory: root)
        let data = try SavedLayoutValidator.encode(h.document())
        let url = try files.create(data)
        let file = url.lastPathComponent
        h.bind(file)
        h.addWindow("desk-editor", on: h.second.id)
        var reads = 0
        h.runtime.loadLayout = { file in
            reads += 1
            return try SavedLayoutValidator.decode(files.read(root.appendingPathComponent(file)))
        }
        // The delete sheet leaves the binding unless its remove-binding checkbox is selected.
        try files.delete(url, expected: data)
        for attempt in 1...2 {
            h.connectSecond()
            await h.finish()
            #expect(h.runtime.isIdle && reads == attempt)
            #expect(h.notices.isEmpty && h.feedback.isEmpty)
            #expect(h.runtime.runs[file] == nil)
            #expect(h.commits.isEmpty && h.system.requestedFrames.isEmpty)
            #expect(h.triggers.first?.layoutFile == file && h.triggers.first?.enabled == true)
            h.connected[1] = false
            h.runtime.displaysChanged()
        }
        // Keeping the binding permits a restored file to apply on a later connection.
        try data.write(to: url)
        h.connectSecond()
        await h.finish()
        #expect(reads == 3 && h.commits == [h.second.id])
        #expect(h.runtime.runs[file]?.result.placed == 1)
    }

    @Test(arguments: [1, 0, 3])
    func unsupportedLayoutNeverAutomaticallyAppliesOrChangesItsFile(version: Int) async throws {
        let h = RuntimeHarness(); defer { h.runtime.stop() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let files = SavedLayoutFiles(directory: root)
        let url = try files.create(SavedLayoutValidator.encode(h.document()))
        let bytes = Data("{\"version\":\(version),\"name\":\"Unsupported\",\"mode\":\"bento\",\"layout\":{\"slot\":\"one\"},\"slots\":[{\"id\":\"one\",\"bundleID\":\"com.example.Editor\"}]}".utf8)
        try bytes.write(to: url)
        h.bind(url.lastPathComponent); h.addWindow("editor", on: h.second.id)
        h.runtime.loadLayout = { file in try SavedLayoutValidator.decode(files.read(root.appendingPathComponent(file))) }
        h.connectSecond(); await h.finish()
        #expect(h.runtime.isIdle && h.notices.count == 1)
        #expect(h.notices.first?.detail?.contains("The layout file could not be read.") == true)
        #expect(h.commits.isEmpty && h.system.requestedFrames.isEmpty)
        #expect(try files.read(url) == bytes && files.entries() == [url])
    }

    @Test func anExistingInvalidLayoutStillReportsItsReadFailure() async throws {
        let h = RuntimeHarness()
        defer { h.runtime.stop() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let files = SavedLayoutFiles(directory: root)
        let url = try files.create(SavedLayoutValidator.encode(h.document()))
        let file = url.lastPathComponent
        h.bind(file)
        h.addWindow("desk-editor", on: h.second.id)
        try Data("invalid layout".utf8).write(to: url)
        h.runtime.loadLayout = { file in
            try SavedLayoutValidator.decode(files.read(root.appendingPathComponent(file)))
        }
        h.connectSecond()
        await h.finish()
        #expect(h.runtime.isIdle && h.notices.count == 1)
        #expect(h.notices.first?.detail?.contains("The layout file could not be read.") == true)
        #expect(h.runtime.runs[file]?.result.issues.first?.message == "The layout file could not be read.")
        #expect(h.commits.isEmpty && h.system.requestedFrames.isEmpty && h.feedback.isEmpty)
    }

    @Test func connectingTheSetAppliesOnceOnTheBoundDisplayOnly() async {
        let h = RuntimeHarness()
        h.addWindow("desk-editor", on: h.second.id)
        h.addWindow("laptop-editor", on: h.main)
        h.bind()
        let laptopBefore = h.frame("laptop-editor")
        h.connectSecond()
        await h.finish()
        #expect(h.commits == [h.second.id])
        #expect(h.frame("desk-editor") == h.second.visibleFrame)
        #expect(h.frame("laptop-editor") == laptopBefore)
        #expect(h.feedback.count == 1 && h.feedback[0].automatic && h.feedback[0].displayID == h.second.id)
        #expect(h.feedback[0].offersUndo)
        #expect(h.runtime.runs["studio.json"]?.result.placed == 1)
    }

    @Test func undoFromTheResultRestoresTheFrames() async {
        let h = RuntimeHarness()
        h.addWindow("desk-editor", on: h.second.id)
        h.bind()
        let before = h.frame("desk-editor")
        h.connectSecond()
        await h.finish()
        #expect(h.applier.canUndo(on: h.second.id))
        await h.applier.undoLastApply(displayID: h.second.id)
        #expect(h.frame("desk-editor") == before)
        #expect(!h.applier.hasUndo)
    }

    @Test func aSetThatDoesNotMatchAppliesNothing() async {
        let h = RuntimeHarness()
        h.addWindow("desk-editor", on: h.second.id)
        h.bind(displays: [h.mainFingerprint, DisplayFingerprint(uuid: "OTHER", vendor: 9, model: 9, serial: 9, builtIn: false,
                                                                name: "Other", frame: BTRect(x: 1000, y: 0, width: 1200, height: 800))])
        let before = h.frame("desk-editor")
        h.connectSecond()
        await h.finish()
        #expect(h.commits.isEmpty && h.feedback.isEmpty && h.notices.isEmpty)
        #expect(h.frame("desk-editor") == before)
    }

    @Test func aSwitchThatIsOffAppliesNothing() async {
        let h = RuntimeHarness()
        h.addWindow("desk-editor", on: h.second.id)
        h.bind(enabled: false)
        h.connectSecond()
        await h.finish()
        #expect(h.commits.isEmpty && h.runtime.runs.isEmpty)
    }

    @Test func repeatedReconfigurationAppliesOnce() async {
        let h = RuntimeHarness()
        h.addWindow("desk-editor", on: h.second.id)
        h.bind()
        h.connected[1] = true
        for _ in 0..<5 { h.runtime.displaysChanged() }
        await h.finish()
        h.runtime.displaysChanged()
        h.runtime.displaysChanged()
        await h.finish()
        #expect(h.commits.count == 1)
    }

    @Test func theSettleWaitTakesTwoQuietObservations() async {
        let h = RuntimeHarness()
        h.addWindow("desk-editor", on: h.second.id)
        h.bind()
        let start = h.now
        h.connectSecond()
        await h.finish()
        #expect(h.frameReads == 2)
        #expect(abs((h.now - start) - 0.15) < 0.001)
        #expect(h.commits.count == 1)
    }

    @Test func aWindowThatKeepsMovingIsSkippedAfterTheLimit() async {
        let h = RuntimeHarness()
        h.addWindow("moving", on: h.second.id)
        h.movingWindows = [.init(rawValue: "moving")]
        h.bind()
        let before = h.frame("moving")
        h.connectSecond()
        await h.finish()
        #expect(h.now - 1000 >= 3)
        #expect(h.commits.isEmpty)
        #expect(h.frame("moving") == before)
        let run = h.runtime.runs["studio.json"]
        #expect(run?.result.issues.contains { $0.kind == .stillMoving } == true)
        #expect(run?.result.placed == 0)
    }

    @Test func inputDuringTheWaitCancelsAndOffersAnApplyButton() async {
        let h = RuntimeHarness()
        h.addWindow("desk-editor", on: h.second.id)
        h.bind()
        let before = h.frame("desk-editor")
        h.onSleep = { [unowned h] in h.runtime.userInput() }
        h.connectSecond()
        await h.finish()
        #expect(h.commits.isEmpty && h.frame("desk-editor") == before)
        #expect(h.notices.count == 1)
        #expect(h.notices[0].title == "Studio layout not applied" && h.notices[0].actions.map(\.title) == ["Apply"])
        #expect(h.notices[0].displayID == h.second.id)
        // The set is used up: more noise does not retry.
        h.runtime.displaysChanged()
        await h.finish()
        #expect(h.commits.isEmpty && h.notices.count == 1)
        // The Apply button applies it on request.
        h.notices[0].actions[0].handler()
        await h.finish { h.commits == [h.second.id] }
        #expect(h.commits == [h.second.id])
    }

    @Test func inputDuringTheApplyStopsIt() async {
        let h = RuntimeHarness()
        h.addWindow("desk-editor", on: h.second.id)
        h.bind()
        let before = h.frame("desk-editor")
        h.connected[1] = true
        h.runtime.displaysChanged()
        // Run the wait to its end, then press a key in the middle of the Apply's first read.

        h.onSleep = nil
        var pressed = false
        let original = h.applier.snapshot
        h.applier.snapshot = { [unowned h] in
            if !pressed, h.runtime.isIdle == false, h.applier.isRunning { pressed = true; h.runtime.userInput() }
            return try original()
        }
        await h.finish()
        #expect(pressed)
        #expect(h.commits.isEmpty)
        #expect(h.frame("desk-editor") == before)
        #expect(h.feedback.last.map { $0.automatic } == true)
    }

    @Test func inputCancelsTheHeldApplyAndItsReconnectedWait() async throws {
        let h = RuntimeHarness()
        h.addWindow("desk-editor", on: h.second.id); h.bind()
        var release: CheckedContinuation<Void, Never>?
        var preparations = 0
        var cancelledTask = false
        h.applier.prepareAppGroups = {
            preparations += 1
            await withCheckedContinuation { release = $0 }
            cancelledTask = Task.isCancelled
        }
        defer { release?.resume(); h.applier.stop(); h.runtime.stop() }
        h.connectSecond()
        try await waitForSavedLayoutState("The old automatic Apply did not reach preparation.", timeout: .seconds(2)) { release != nil }
        try #require(h.applier.isRunning && h.system.requestedFrames.isEmpty)
        // Observe registration of the new postponed wait's owned sleeper.
        h.runtime.sleep = { duration in try? await h.clock.clock.sleep(for: duration) }
        h.connected[1] = false; h.runtime.displaysChanged()
        h.connectSecond()
        try await waitForSavedLayoutState("The reconnect did not postpone behind the old Apply.", timeout: .seconds(2)) {
            h.clock.pendingSleepCount == 1
        }
        h.runtime.userInput()
        #expect(h.runtime.isIdle)
        // The same bound set is current again before the old Apply can resume.
        h.runtime.displaysChanged()
        let continuation = release; release = nil; continuation?.resume()
        try await waitForSavedLayoutState("The cancelled Apply or postponed task did not stop.", timeout: .seconds(2)) {
            !h.applier.isRunning && h.clock.pendingSleepCount == 0
        }
        #expect(cancelledTask && preparations == 1)
        #expect(h.commits.isEmpty && h.system.requestedFrames.isEmpty)
        #expect(h.runtime.isIdle)
        #expect(h.notices.isEmpty && h.feedback.count == 1,
            "The old Apply supplies one cancellation result; its duplicate pending fire supplies none.")
        #expect(h.feedback.first?.detail?.contains("cancelled") == true)
        h.clock.advance(by: .seconds(10))
        h.runtime.displaysChanged()
        #expect(h.runtime.isIdle && preparations == 1)
    }

    @Test func anInteractionPostponesTheApplyUntilItEnds() async {
        let h = RuntimeHarness()
        h.addWindow("desk-editor", on: h.second.id)
        h.bind()
        h.interacting = true
        h.connectSecond()
        for _ in 0..<40 { await Task.yield() }
        #expect(h.commits.isEmpty)
        h.interacting = false
        await h.finish()
        #expect(h.commits == [h.second.id])
    }

    @Test func anUncertainMatchOnlyOffersAndNeverApplies() async {
        let h = RuntimeHarness()
        h.addWindow("desk-editor", on: h.second.id)
        // The stored second display has another UUID and no serial. The live one has the same model and no serial.
        var stored = h.secondFingerprint
        stored.uuid = "OLD-UUID"; stored.serial = 0
        var changed = h.secondFingerprint
        changed.serial = 0
        h.bind(displays: [h.mainFingerprint, stored])
        h.liveOverride = [LiveDisplay(id: h.main, fingerprint: h.mainFingerprint), LiveDisplay(id: h.second.id, fingerprint: changed)]
        let before = h.frame("desk-editor")
        h.runtime.displaysChanged()
        await h.finish()
        #expect(h.commits.isEmpty && h.frame("desk-editor") == before)
        #expect(h.notices.count == 1)
        #expect(h.notices.first?.title.hasPrefix("Displays look like") == true)
        #expect(h.notices.first?.actions.map(\.title) == ["Apply"])
    }

    @Test(arguments: [false, true]) func wakeWithTheSameSetAppliesOnlyWhenTheSwitchIsOn(switchOn: Bool) async {
        let h = RuntimeHarness()
        h.connected = [true, true]
        h.addWindow("desk-editor", on: h.second.id)
        h.bind(wake: switchOn)
        h.runtime = h.makeRuntime(initial: [h.mainFingerprint, h.secondFingerprint])
        h.runtime.sleeping()
        h.runtime.wake()
        await h.finish()
        #expect(h.commits == (switchOn ? [h.second.id] : []))
    }

    /// A wake sends two notifications. The second one, even long after the Apply, must not move windows again.
    @Test func twoWakeNotificationsForOneSleepApplyOnce() async {
        let h = RuntimeHarness()
        h.connected = [true, true]
        h.addWindow("desk-editor", on: h.second.id)
        h.bind(wake: true)
        h.runtime = h.makeRuntime(initial: [h.mainFingerprint, h.secondFingerprint])
        h.runtime.sleeping()
        h.runtime.wake()
        await h.finish()
        #expect(h.commits.count == 1)
        // The user rearranges the window, then the display-wake notification arrives.
        let moved = BTRect(x: 1100, y: 100, width: 333, height: 222)
        h.system.windows[0].frame = moved
        h.runtime.wake()
        await h.finish()
        h.runtime.wake()
        await h.finish()
        #expect(h.commits.count == 1)
        #expect(h.frame("desk-editor") == moved)
    }

    @Test func aDisplayChangeDuringSleepWaitsForTheWakeAndAppliesOnce() async {
        let h = RuntimeHarness()
        h.addWindow("desk-editor", on: h.second.id)
        h.bind()
        h.runtime.sleeping()
        h.connectSecond()
        await h.finish()
        #expect(h.commits.isEmpty && h.frameReads == 0)
        h.runtime.wake()
        await h.finish()
        h.runtime.wake()
        await h.finish()
        #expect(h.commits == [h.second.id])
    }

    // MARK: Lock screen

    @Test func aWakeAtTheLockScreenStaysPendingUntilAnotherAppIsActive() async {
        let h = RuntimeHarness()
        h.connected = [true, true]
        h.addWindow("desk-editor", on: h.second.id)
        h.bind(wake: true)
        h.runtime = h.makeRuntime(initial: [h.mainFingerprint, h.secondFingerprint])
        h.locked = true
        h.runtime.sleeping()
        h.runtime.wake()
        await h.finish()
        #expect(h.commits.isEmpty && h.frameReads == 0 && h.notices.isEmpty && h.feedback.isEmpty)
        #expect(!h.runtime.isIdle)
        // The login window staying active, or a second wake notification, releases nothing.
        h.runtime.applicationActivated(bundleID: "com.apple.loginwindow")
        h.runtime.wake()
        await h.finish()
        #expect(h.commits.isEmpty && !h.runtime.isIdle)
        // The user unlocks: Finder becomes active. The settle wait and the Apply run now.
        h.locked = false
        h.runtime.applicationActivated(bundleID: "com.apple.finder")
        await h.finish()
        #expect(h.commits == [h.second.id])
        #expect(h.frameReads >= 2)
        #expect(h.feedback.count == 1)
    }

    @Test func theSessionBecomingActiveAlsoReleasesTheLockedAttempt() async {
        let h = RuntimeHarness()
        h.connected = [true, true]
        h.addWindow("desk-editor", on: h.second.id)
        h.bind(wake: true)
        h.runtime = h.makeRuntime(initial: [h.mainFingerprint, h.secondFingerprint])
        h.locked = true
        h.runtime.sleeping()
        h.runtime.wake()
        await h.finish()
        h.locked = false
        h.runtime.sessionBecameActive()
        await h.finish()
        #expect(h.commits == [h.second.id])
    }

    @Test func anAttemptThatWaitedTooLongForTheUnlockIsGivenUpWithoutAPill() async {
        let h = RuntimeHarness()
        h.connected = [true, true]
        h.addWindow("desk-editor", on: h.second.id)
        h.bind(wake: true)
        h.runtime = h.makeRuntime(initial: [h.mainFingerprint, h.secondFingerprint])
        h.locked = true
        h.runtime.sleeping()
        h.runtime.wake()
        await h.clock.waitForSleepers(count: 1)
        h.clock.advance(by: .seconds(599))
        #expect(!h.runtime.isIdle && h.clock.pendingSleepCount == 1)
        h.clock.advance(by: .seconds(1))
        await h.finish()
        #expect(h.runtime.isIdle)
        h.locked = false
        h.runtime.applicationActivated(bundleID: "com.apple.finder")
        await h.finish()
        #expect(h.commits.isEmpty && h.notices.isEmpty && h.feedback.isEmpty && h.runtime.runs.isEmpty)
    }

    @Test func aDifferentDisplaySetAtTheLockScreenGivesUpTheOldAttempt() async {
        let h = RuntimeHarness()
        h.connected = [true, true]
        h.addWindow("desk-editor", on: h.second.id)
        h.bind(wake: true)
        h.runtime = h.makeRuntime(initial: [h.mainFingerprint, h.secondFingerprint])
        h.locked = true
        h.runtime.sleeping()
        h.runtime.wake()
        await h.finish()
        #expect(!h.runtime.isIdle)
        // The studio display is unplugged. No binding matches the laptop alone.
        h.connected = [true, false]
        h.runtime.displaysChanged()
        await h.finish()
        #expect(h.runtime.isIdle)
        h.locked = false
        h.runtime.applicationActivated(bundleID: "com.apple.finder")
        await h.finish()
        #expect(h.commits.isEmpty && h.feedback.isEmpty && h.notices.isEmpty)
    }

    @Test func aLockThatStartsDuringTheSettleWaitKeepsTheAttemptForTheUnlock() async {
        let h = RuntimeHarness()
        h.addWindow("desk-editor", on: h.second.id)
        h.bind()
        h.onSleep = { [unowned h] in h.locked = true }
        h.connectSecond()
        for _ in 0..<60 { await Task.yield() }
        #expect(h.commits.isEmpty && !h.runtime.isIdle)
        h.onSleep = nil
        h.locked = false
        h.runtime.applicationActivated(bundleID: "com.apple.finder")
        await h.finish()
        #expect(h.commits == [h.second.id])
    }

    @Test func aConnectInterruptedBySleepStillAppliesAfterWake() async {
        let h = RuntimeHarness()
        h.addWindow("desk-editor", on: h.second.id)
        h.bind(wake: false)
        h.onSleep = { [unowned h] in h.runtime.sleeping() }
        h.connectSecond()
        for _ in 0..<40 { await Task.yield() }
        #expect(h.commits.isEmpty)
        h.onSleep = nil
        h.runtime.wake()
        await h.finish()
        h.runtime.wake()
        await h.finish()
        #expect(h.commits == [h.second.id])
    }

    // MARK: Fast user switching

    @Test(arguments: ["session", "lock"], ["preparation", "commit"])
    func aStartedAutomaticApplyStopsSilentlyDuringAHold(hold: String, stage: String) async throws {
        let h = RuntimeHarness()
        h.addWindow("desk-editor", on: h.second.id); h.bind()
        var release: CheckedContinuation<Void, Never>?
        var taskWasCancelled = false
        let pause = {
            await withCheckedContinuation { release = $0 }
            taskWasCancelled = Task.isCancelled
        }
        if stage == "preparation" { h.applier.prepareAppGroups = pause }
        else { h.beforeCommit = pause }
        defer { release?.resume(); h.applier.stop(); h.runtime.stop() }
        h.connectSecond()
        try await waitForSavedLayoutState("The automatic Apply did not reach its hold point.", timeout: .seconds(2)) { release != nil }
        try #require(h.applier.isRunning && h.system.requestedFrames.isEmpty)
        if hold == "session" {
            h.runtime.sessionResigned()
            // Activation elsewhere does not make this user's session active.
            h.runtime.applicationActivated(bundleID: "com.example.OtherSession")
        } else {
            h.locked = true
            h.runtime.applicationActivated(bundleID: DisplayTriggerRuntime.loginWindowBundleID)
        }
        let continuation = release; release = nil; continuation?.resume()
        try await waitForSavedLayoutState("The held automatic Apply did not end.", timeout: .seconds(2)) {
            !h.applier.isRunning && h.runtime.runs["studio.json"] != nil
        }
        #expect(taskWasCancelled)
        #expect(h.commits.isEmpty && h.system.requestedFrames.isEmpty)
        #expect(h.feedback.isEmpty && h.notices.isEmpty)
        // A started attempt was consumed, rather than automatically retried.
        h.locked = false; h.runtime.sessionBecameActive()
        h.runtime.displaysChanged()
        #expect(h.runtime.isIdle && h.commits.isEmpty)
        #expect(h.feedback.isEmpty && h.notices.isEmpty)
    }

    @Test func aLockObservedByTheWritePredicateRefusesWithoutFeedback() async throws {
        let h = RuntimeHarness()
        h.addWindow("desk-editor", on: h.second.id); h.bind()
        defer { h.applier.stop(); h.runtime.stop() }
        var reachedCommit = false
        h.beforeCommit = { reachedCommit = true; h.locked = true }
        h.connectSecond()
        try await waitForSavedLayoutState("The automatic commit did not finish.", timeout: .seconds(2)) {
            reachedCommit && !h.applier.isRunning
        }
        #expect(h.commits.isEmpty && h.system.requestedFrames.isEmpty)
        #expect(h.feedback.isEmpty && h.notices.isEmpty)
    }

    @Test func sessionResignationStopsTheModelsRecoveryWritesToo() async throws {
        let h = RuntimeHarness()
        h.addWindow("editor", on: h.second.id)
        h.addWindow("peer", on: h.second.id, bundle: "com.example.Peer")
        h.bind()
        h.layouts["studio.json"] = .init(name: "Two panes", mode: .bento,
            layout: .split(axis: .vertical, ratios: [0.5, 0.5], children: [.slot("editor"), .slot("peer")]),
            slots: [.init(id: "editor", bundleID: "com.example.Editor"), .init(id: "peer", bundleID: "com.example.Peer")])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = ConfigurationStore(fileURL: root.appendingPathComponent("configuration.json"))
        var configuration = BetterTileConfiguration(); configuration.defaultLayoutMode = .manual
        try store.save(configuration)
        let model = makeOffscreenModel(store: store, system: h.system, startRuntime: false)
        h.runtime.stop()
        h.applier = try #require(model.savedLayoutApplier)
        h.applier.observesKeyboard = false; h.applier.prepareAppGroups = {}
        h.applier.application = { id in .init(bundleIdentifier: id, name: id, url: URL(filePath: "/fixture/\(id).app")) }
        h.applier.feedback = { [unowned h] in h.feedback.append($0) }
        h.runtime = h.makeRuntime(initial: [h.mainFingerprint])
        defer {
            h.system.onFrameWrite = nil; h.runtime.stop(); model.shutdown()
            try? FileManager.default.removeItem(at: root)
        }
        var held = false
        h.system.onFrameWrite = { [unowned h] _, _ in
            if !held { held = true; h.runtime.sessionResigned() }
        }
        h.connectSecond()
        try await waitForSavedLayoutState("The model did not finish its interrupted automatic Apply.", timeout: .seconds(2)) {
            held && !h.applier.isRunning
        }
        #expect(h.system.frameWriteCounts.values.reduce(0, +) == 1,
            "After session resignation neither a forward write nor recovery may mutate another frame.")
        #expect(model.savedLayoutSessions()[h.second.id] == .manual)
        #expect(h.feedback.isEmpty && h.notices.isEmpty)
        #expect(model.lastActionFeedback == nil)
    }

    @Test(arguments: ["session", "lock", "expired", "completion", "stopped"])
    func anIncompleteHeldApplyReportsRepairOnceAfterReturn(hold: String) async throws {
        let h = RuntimeHarness()
        h.addWindow("editor", on: h.second.id)
        h.addWindow("peer", on: h.second.id, bundle: "com.example.Peer")
        h.bind()
        h.layouts["studio.json"] = .init(name: "Two panes", mode: .bento,
            layout: .split(axis: .vertical, ratios: [0.5, 0.5], children: [.slot("editor"), .slot("peer")]),
            slots: [.init(id: "editor", bundleID: "com.example.Editor"), .init(id: "peer", bundleID: "com.example.Peer")])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = ConfigurationStore(fileURL: root.appendingPathComponent("configuration.json"))
        var configuration = BetterTileConfiguration(); configuration.defaultLayoutMode = .manual
        try store.save(configuration)
        let model = makeOffscreenModel(store: store, system: h.system, startRuntime: false)
        h.runtime.stop()
        h.applier = try #require(model.savedLayoutApplier)
        h.applier.observesKeyboard = false; h.applier.prepareAppGroups = {}
        h.applier.application = { id in .init(bundleIdentifier: id, name: id, url: URL(filePath: "/fixture/\(id).app")) }
        h.applier.feedback = { [unowned h] in h.feedback.append($0) }
        h.runtime = h.makeRuntime(initial: [h.mainFingerprint])
        var returnedBeforeRecord = false
        if hold == "completion" {
            let finished = h.applier.didFinish
            h.applier.didFinish = { [unowned h] in
                finished()
                returnedBeforeRecord = h.runtime.runs["studio.json"] == nil
                h.runtime.sessionBecameActive()
            }
        }
        defer {
            h.system.onFrameWrite = nil; h.runtime.stop(); model.shutdown()
            try? FileManager.default.removeItem(at: root)
        }
        let baseline = Dictionary(uniqueKeysWithValues: h.system.windows.map { ($0.id, $0.frame) })
        var held = false
        h.system.onFrameWrite = { [unowned h] _, _ in
            guard !held else { return }
            held = true
            if hold == "lock" {
                h.locked = true
                h.runtime.applicationActivated(bundleID: DisplayTriggerRuntime.loginWindowBundleID)
            } else { h.runtime.sessionResigned() }
        }
        h.connectSecond()
        try await waitForSavedLayoutState("The incomplete held Apply was not recorded.", timeout: .seconds(2)) {
            held && !h.applier.isRunning && h.runtime.runs["studio.json"] != nil
        }
        let run = try #require(h.runtime.runs["studio.json"])
        #expect(run.offersUndo)
        #expect(h.system.windows.contains { baseline[$0.id] != $0.frame })
        #expect(try h.applier.snapshot().suspendedDisplays.contains(h.second.id))
        #expect(h.system.frameWriteCounts.values.reduce(0, +) == 1)
        #expect(model.lastActionFeedback == nil && h.notices.isEmpty)
        if hold == "completion" { #expect(returnedBeforeRecord && h.feedback.count == 1) }
        else { #expect(h.feedback.isEmpty) }

        if hold == "stopped" {
            h.runtime.stop()
            h.runtime.sessionBecameActive()
            #expect(h.feedback.isEmpty && h.notices.isEmpty)
            #expect(h.system.frameWriteCounts.values.reduce(0, +) == 1)
            return
        }

        if hold == "expired" {
            h.connected[1] = false; h.runtime.displaysChanged()
            h.connectSecond()
            #expect(!h.runtime.isIdle, "A new pending attempt must exist before testing its expiry.")
            try await waitForSavedLayoutState("The lock deadline was not registered.", timeout: .seconds(2)) {
                h.clock.pendingSleepCount == 1
            }
            h.clock.advance(by: .seconds(600))
            try await waitForSavedLayoutState("The inactive lock wait did not expire.", timeout: .seconds(2)) {
                h.runtime.isIdle && h.clock.pendingSleepCount == 0
            }
            #expect(h.feedback.isEmpty && h.notices.isEmpty)
            h.runtime.sessionBecameActive()
        } else if hold == "session" {
            // Returning to this session does not release a lock screen that is still up.
            h.locked = true; h.runtime.sessionBecameActive()
            #expect(h.feedback.isEmpty && h.notices.isEmpty)
            h.locked = false
            h.runtime.applicationActivated(bundleID: "com.example.Editor")
        } else {
            h.locked = false
            h.runtime.applicationActivated(bundleID: "com.example.Editor")
        }
        try await waitForSavedLayoutState("The returning session did not receive its repair result.", timeout: .seconds(2)) {
            h.feedback.count == 1
        }
        let feedback = try #require(h.feedback.first)
        #expect(feedback.detail?.contains("Some windows could not be restored") == true)
        #expect(feedback.detail?.contains("Repair Layout") == true)
        #expect(feedback.displayID == h.second.id && feedback.automatic && feedback.isApply && feedback.offersUndo)
        #expect(h.runtime.runs["studio.json"]?.date == run.date)
        h.runtime.sessionBecameActive()
        h.runtime.applicationActivated(bundleID: "com.example.Editor")
        #expect(h.feedback.count == 1 && h.notices.isEmpty)
        #expect(h.runtime.isIdle)
        #expect(h.system.frameWriteCounts.values.reduce(0, +) == 1)
        #expect(try h.applier.snapshot().suspendedDisplays.contains(h.second.id))
    }

    @Test func aReconnectHeldDuringApplySettlesFreshAfterTheSessionReturns() async throws {
        let h = RuntimeHarness()
        h.addWindow("desk-editor", on: h.second.id); h.bind()
        var release: CheckedContinuation<Void, Never>?
        var preparations = 0
        h.applier.prepareAppGroups = {
            preparations += 1
            if preparations == 1 { await withCheckedContinuation { release = $0 } }
        }
        defer { release?.resume(); h.applier.stop(); h.runtime.stop() }
        h.connectSecond()
        try await waitForSavedLayoutState("The first Apply did not start.", timeout: .seconds(2)) { release != nil }
        let origin = h.clock.now
        h.runtime.uptime = {
            let elapsed = origin.duration(to: h.clock.now).components
            return Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
        }
        h.runtime.sleep = { duration in try? await h.clock.clock.sleep(for: duration) }
        h.connected[1] = false; h.runtime.displaysChanged(); h.connectSecond()
        try await waitForSavedLayoutState("The reconnect did not postpone.", timeout: .seconds(2)) { h.clock.pendingSleepCount == 1 }
        h.runtime.sessionResigned()
        let continuation = release; release = nil; continuation?.resume()
        try await waitForSavedLayoutState("The first Apply did not stop while inactive.", timeout: .seconds(2)) { !h.applier.isRunning }
        #expect(h.commits.isEmpty && h.feedback.isEmpty && h.notices.isEmpty)
        let reads = h.frameReads
        h.runtime.sessionBecameActive()
        try await waitForSavedLayoutState("The returning session did not start a fresh settle observation.", timeout: .seconds(2)) {
            h.frameReads == reads + 1 && h.clock.pendingSleepCount == 1
        }
        #expect(h.commits.isEmpty)
        h.clock.advance(by: .milliseconds(149))
        #expect(h.commits.isEmpty)
        h.clock.advance(by: .milliseconds(1))
        try await waitForSavedLayoutState("The freshly settled reconnect did not apply.", timeout: .seconds(2)) { h.runtime.isIdle && preparations == 2 }
        #expect(h.commits == [h.second.id] && h.feedback.count == 1)
    }

    @Test func anAttemptIsHeldWhileTheSessionIsSwitchedOutAndReleasedWhenItReturns() async {
        let h = RuntimeHarness()
        h.addWindow("desk-editor", on: h.second.id)
        h.bind()
        h.runtime.sessionResigned()
        h.connectSecond()
        await h.finish()
        #expect(h.commits.isEmpty && h.frameReads == 0 && h.feedback.isEmpty && h.notices.isEmpty)
        #expect(!h.runtime.isIdle)
        // Another app becoming active in the other session is not this session's unlock... the return is.
        h.runtime.sessionBecameActive()
        await h.finish()
        #expect(h.commits == [h.second.id])
        #expect(h.feedback.count == 1)
    }

    @Test func aSessionThatResignsDuringTheWaitKeepsTheAttemptForTheReturn() async {
        let h = RuntimeHarness()
        h.addWindow("desk-editor", on: h.second.id)
        h.bind()
        h.connectSecond()
        h.runtime.sessionResigned()
        await h.finish()
        #expect(h.commits.isEmpty)
        h.runtime.sessionBecameActive()
        await h.finish()
        #expect(h.commits == [h.second.id])
    }

    // MARK: Last run

    @Test func theApplyButtonOfACancelledRunAppliesAndUpdatesTheRow() async {
        let h = RuntimeHarness()
        h.addWindow("desk-editor", on: h.second.id)
        h.bind()
        h.onSleep = { [unowned h] in h.runtime.userInput() }
        h.connectSecond()
        await h.finish()
        #expect(h.runtime.runs["studio.json"]?.status == .notApplied)
        #expect(h.commits.isEmpty)
        h.onSleep = nil
        h.runtime.applyNow("studio.json")
        await h.finish { h.commits == [h.second.id] && h.runtime.runs["studio.json"]?.status == .applied }
        #expect(h.commits == [h.second.id])
        #expect(h.runtime.runs["studio.json"]?.status == .applied)
    }

    @Test func theLastRunStatusNamesWhatHappened() {
        let id = DisplayID(rawValue: "x")
        func run(_ result: SavedLayoutApplyResult, declared: SavedLayoutRun.Status? = nil) -> SavedLayoutRun {
            .init(layoutName: "L", date: Date(timeIntervalSince1970: 1000), displayID: id, result: result, declared: declared)
        }
        #expect(run(.init(placed: 2)).status == .applied)
        #expect(run(.init(placed: 1, unplaced: 1, issues: [.init(.notRunning, "x")])).status == .applied)
        #expect(run(.init(unplaced: 2, issues: [.init(.notRunning, "x")])).status == .notApplied)
        #expect(run(.init(issues: [.init(.stopped, "x")])).status == .notApplied)
        #expect(run(.init(), declared: .offered).status == .offered)
    }

    // MARK: Undo target

    @Test func undoLastApplyTargetsTheMostRecentDisplayThatCanStillUndo() async {
        let h = RuntimeHarness()
        h.connected = [true, true]
        h.addWindow("desk-editor", on: h.second.id)
        h.addWindow("laptop-editor", on: h.main)
        let deskBefore = h.frame("desk-editor"), laptopBefore = h.frame("laptop-editor")
        _ = await h.applier.apply(h.document(), displayID: h.second.id)
        // A later Apply on the other display rolls back and leaves no step of its own.
        h.refuseCommit = true
        _ = await h.applier.apply(h.document(), displayID: h.main)
        h.refuseCommit = false
        #expect(h.applier.canUndo)
        await h.applier.undoLastApply()
        #expect(h.frame("desk-editor") == deskBefore)
        #expect(!h.applier.hasUndo)
        // Two Applies: the newest display is undone first, whatever the dictionary order.
        _ = await h.applier.apply(h.document(), displayID: h.main)
        _ = await h.applier.apply(h.document(), displayID: h.second.id)
        await h.applier.undoLastApply()
        #expect(h.frame("desk-editor") == deskBefore && h.frame("laptop-editor") != laptopBefore)
        await h.applier.undoLastApply()
        #expect(h.frame("laptop-editor") == laptopBefore)
    }

    @Test func anAppThatIsNotRunningIsSkippedAndNeverLaunched() async {
        let h = RuntimeHarness()
        h.layouts["studio.json"] = h.document(bundle: "com.example.Missing")
        h.bind()
        h.connectSecond()
        await h.finish()
        #expect(h.commits.isEmpty)
        let run = h.runtime.runs["studio.json"]
        #expect(run?.result.unplaced == 1)
        #expect(run?.result.placed == 0)
    }

    @Test func severalWindowsOfOneAppUseTheNearestPreferredMatch() async {
        let h = RuntimeHarness()
        h.addWindow("one", on: h.second.id)
        h.addWindow("two", on: h.second.id)
        h.bind()
        let before = (h.frame("one"), h.frame("two"))
        h.connectSecond()
        await h.finish()
        #expect(h.commits.count == 1)
        #expect(h.frame("one") != before.0)
        #expect(h.frame("two") == before.1)
        #expect(h.runtime.runs["studio.json"]?.result.placed == 1)
        #expect(h.runtime.runs["studio.json"]?.result.issues.isEmpty == true)
    }

    @Test func twoBoundDisplaysAreUndoneOneAtATime() async {
        let h = RuntimeHarness()
        h.connected = [true, false]
        h.addWindow("desk-editor", on: h.second.id)
        h.addWindow("laptop-editor", on: h.main)
        h.bind("studio.json", target: 1)
        h.layouts["laptop.json"] = h.document("Laptop layout")
        h.bind("laptop.json", target: 0)
        let laptopBefore = h.frame("laptop-editor"), deskBefore = h.frame("desk-editor")
        h.connectSecond()
        await h.finish()
        #expect(Set(h.commits) == [h.main, h.second.id] && h.commits.count == 2)
        #expect(h.feedback.map(\.displayID).count == 2 && Set(h.feedback.compactMap(\.displayID)) == [h.main, h.second.id])
        await h.applier.undoLastApply(displayID: h.second.id)
        #expect(h.frame("desk-editor") == deskBefore)
        #expect(h.frame("laptop-editor") != laptopBefore)
        await h.applier.undoLastApply(displayID: h.main)
        #expect(h.frame("laptop-editor") == laptopBefore)
    }
}

@MainActor @Suite(.appTestApplication) struct DisplayTriggerFilesTests {
    private let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DisplayTriggerFiles-" + UUID().uuidString)
    private var url: URL { directory.appendingPathComponent("Display Triggers.json") }

    @Test func aLegacyBindingWithoutSwitchKeysLoadsWithBothOff() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let json = """
        {"version":1,"triggers":[{"layoutFile":"a.json","target":0,"displays":[
        {"uuid":"A","vendor":1,"model":2,"serial":3,"builtIn":false,"name":"Studio","frame":{"x":0,"y":0,"width":100,"height":60}}]}]}
        """
        try Data(json.utf8).write(to: url)
        let store = DisplayTriggerStore(url: url)
        let loaded = try #require(store.trigger(for: "a.json"))
        #expect(store.loadError == nil && !loaded.enabled && !loaded.alsoAfterWake)
        #expect(store.update("a.json") { $0.enabled = true; $0.alsoAfterWake = true })
        let reopened = try #require(DisplayTriggerStore(url: url).trigger(for: "a.json"))
        #expect(reopened.enabled && reopened.alsoAfterWake)
    }

    @Test func reloadingPicksUpAFixedOrBrokenFileWithoutARelaunch() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DisplayTriggerStore(url: url)
        #expect(store.loadError == nil)
        try Data("{ not json".utf8).write(to: url)
        store.load()
        #expect(store.loadError != nil)
        #expect(!store.bind(.init(layoutFile: "a.json", displays: [.init(uuid: "A", vendor: 1, model: 2, serial: 3, builtIn: false,
            name: "S", frame: BTRect(x: 0, y: 0, width: 1, height: 1))], target: 0)))
        #expect(String(data: try Data(contentsOf: url), encoding: .utf8) == "{ not json")
        try Data(#"{"version":1,"triggers":[]}"#.utf8).write(to: url)
        store.load()
        #expect(store.loadError == nil)
    }
}


extension DisplayTriggerRuntimeTests {
    @Test(arguments: [false, true]) func queuedFireRechecksEnabledAndExactMatch(disable: Bool) async throws {
        let h = RuntimeHarness()
        h.addWindow("editor", on: h.second.id)
        h.addWindow("laptop", on: h.main)
        var stored = h.secondFingerprint; stored.serial = 0
        h.bind("first.json", target: 0, displays: [h.mainFingerprint, stored])
        h.bind("second.json", displays: [h.mainFingerprint, stored])
        h.liveOverride = [.init(id: h.main, fingerprint: h.mainFingerprint), .init(id: h.second.id, fingerprint: stored)]
        let (entered, signal) = AsyncStream<Void>.makeStream()
        defer { signal.finish(); h.runtime.stop() }
        var release: CheckedContinuation<Void, Never>?
        h.beforeCommit = {
            h.beforeCommit = nil
            await withCheckedContinuation { release = $0; signal.yield() }
        }
        h.connected = [true, true]
        h.runtime.displaysChanged()
        var iterator = entered.makeAsyncIterator()
        _ = await iterator.next()
        let continuation = try #require(release)
        if disable { h.triggers[1].enabled = false }
        else {
            var uncertain = stored; uncertain.uuid = "CHANGED"
            h.liveOverride = [.init(id: h.main, fingerprint: h.mainFingerprint), .init(id: h.second.id, fingerprint: uncertain)]
            #expect(DisplaySetMatcher.match(stored: h.triggers[1].displays, live: h.liveOverride!.map(\.fingerprint)).kind == .uncertain)
        }
        continuation.resume()
        await h.finish()
        #expect(h.runtime.runs["first.json"] != nil)
        if disable { #expect(h.runtime.runs["second.json"] == nil) }
        else {
            #expect(h.runtime.runs["second.json"]?.status == .offered)
            #expect(h.notices.last?.actions.count == 1)
        }
    }
}


extension DisplayTriggerRuntimeTests {
    @Test(arguments: ["disabled", "uncertain", "retargeted"])
    func automaticFireRechecksBindingAfterGroupLoad(change: String) async throws {
        let h = RuntimeHarness()
        h.addWindow("editor", on: h.second.id)
        var stored = h.secondFingerprint; stored.serial = 0
        h.bind(displays: [h.mainFingerprint, stored])
        h.liveOverride = [.init(id: h.main, fingerprint: h.mainFingerprint), .init(id: h.second.id, fingerprint: stored)]
        let (entered, signal) = AsyncStream<Void>.makeStream()
        defer { signal.finish(); h.runtime.stop() }
        var release: CheckedContinuation<Void, Never>?
        h.applier.prepareAppGroups = { await withCheckedContinuation { release = $0; signal.yield() } }
        h.connected = [true, true]
        h.runtime.displaysChanged()
        var iterator = entered.makeAsyncIterator()
        _ = await iterator.next()
        if change == "disabled" { h.triggers[0].enabled = false }
        else if change == "retargeted" { h.triggers[0].target = 0 }
        else {
            var uncertain = stored; uncertain.uuid = "CHANGED"
            h.liveOverride = [.init(id: h.main, fingerprint: h.mainFingerprint), .init(id: h.second.id, fingerprint: uncertain)]
        }
        try #require(release).resume()
        await h.finish()
        #expect(h.commits.isEmpty && h.system.frameWriteCounts.isEmpty)
        if change == "uncertain" {
            #expect(h.runtime.runs["studio.json"]?.status == .offered)
            #expect(h.notices.last?.actions.count == 1)
        } else { #expect(h.runtime.runs["studio.json"]?.result.placed == 0) }
    }

    @Test func automaticFireRechecksBindingInsideTheCommitValidator() async throws {
        let h = RuntimeHarness()
        h.addWindow("editor", on: h.second.id)
        h.bind()
        let (entered, signal) = AsyncStream<Void>.makeStream()
        defer { signal.finish(); h.runtime.stop() }
        var release: CheckedContinuation<Void, Never>?
        h.beforeCommit = { await withCheckedContinuation { release = $0; signal.yield() } }
        h.connectSecond()
        var iterator = entered.makeAsyncIterator()
        _ = await iterator.next()
        h.triggers[0].enabled = false
        try #require(release).resume()
        await h.finish()
        #expect(h.commits.isEmpty && h.system.frameWriteCounts.isEmpty)
        #expect(h.runtime.runs["studio.json"]?.result.placed == 0)
    }
}

@Test(.appTestApplication) @MainActor
func automaticApplyWaitsForDisplayHoldPastItsFrameReadLimit() async throws {
    let h = RuntimeHarness()
    defer { h.runtime.stop(); h.applier.stop() }
    h.addWindow("editor", on: h.second.id)
    h.bind()
    h.runtime.isReady = { _ in h.now >= 1006 }
    h.runtime.isDisplayChangeHeld = { _ in h.now < 1006 }
    h.connectSecond()
    await h.finish()
    #expect(h.now >= 1006, "Automatic Apply must not bypass the model hold when its own settle limit expires")
    #expect(h.frameReads >= 2)
    #expect(h.commits == [h.second.id])
}

@Test(.appTestApplication) @MainActor
func automaticApplyReadinessWithoutADisplayHoldRemainsBounded() async throws {
    let h = RuntimeHarness()
    defer { h.runtime.stop(); h.applier.stop() }
    h.bind()
    h.runtime.isReady = { _ in h.now >= 1008 }
    h.connectSecond()
    await h.finish()
    #expect(h.now < 1004)
    #expect(h.commits.isEmpty)
}
