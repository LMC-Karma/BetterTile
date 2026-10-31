import AppKit
import BetterTileCore
import BetterTileTestSupport
@testable import BetterTileMacOS
@testable import BetterTileApp
import Foundation
import Testing

@Suite(.appTestApplication) @MainActor struct SavedLayoutInputCancellationTests {
    @Test func queuedWindowCommandPreventsAStaleSessionCommit() async throws {
        let h = ApplyHarness(); defer { h.close() }
        h.addWindow()
        let store = ConfigurationStore(fileURL: h.directory.appendingPathComponent("configuration.json"))
        var configuration = BetterTileConfiguration(); configuration.defaultLayoutMode = .manual
        try store.save(configuration)
        let model = h.model(); defer { model.shutdown() }
        model.handleApplicationActivation()
        let applier = try #require(model.savedLayoutApplier)
        applier.application = h.applier.application; applier.observesKeyboard = false
        let before = h.system.windows[0].frame
        var appliedFrame: BTRect?
        var commandFrame: BTRect?
        var commandWrites = 0
        model.savedLayoutInputCheckpoint = { [weak model] in
            appliedFrame = h.system.windows[0].frame
            #expect(appliedFrame != before && !h.system.frameWriteCounts.isEmpty)
            model?.perform(.leftHalf)
            commandFrame = h.system.windows[0].frame
            commandWrites = h.system.frameWriteCounts.values.reduce(0, +)
            return true
        }
        let result = await applier.apply(h.document(mode: .tabbed), displayID: h.system.mainDisplay.id)
        let frame = try #require(commandFrame)
        #expect(frame != appliedFrame)
        #expect(result.placed == 0)
        #expect(result.issues.contains { $0.message.contains("changed while applying") && $0.message.contains("Repair Layout") })
        #expect(model.savedLayoutSessions()[h.system.mainDisplay.id] == .manual)
        #expect(h.system.windows[0].frame == frame)
        #expect(h.system.frameWriteCounts.values.reduce(0, +) == commandWrites,
            "Recovery must not overwrite the queued command's newer mutation.")
    }

    @Test(arguments: ["frame write", "session preparation"])
    func queuedEscapeRestoresTheManualFrames(stage: String) async throws {
        let h = ApplyHarness(); defer { h.close() }
        for index in 0..<4 { h.addWindow(index < 2 ? "com.example.Editor" : "com.example.Peer", id: "window-\(index)", pid: index < 2 ? 42 : 43) }
        let store = ConfigurationStore(fileURL: h.directory.appendingPathComponent("configuration.json"))
        var configuration = BetterTileConfiguration(); configuration.defaultLayoutMode = .manual
        try store.save(configuration)
        let model = h.model(); defer { model.shutdown() }
        model.handleApplicationActivation()
        let applier = try #require(model.savedLayoutApplier)
        applier.application = h.applier.application; applier.observesKeyboard = true
        var deliverKey: (@MainActor (UInt16) -> Void)?
        var events: [String] = []
        applier.observeKeyDown = { handler in
            events.append("monitor installed"); deliverKey = handler
            return { events.append("monitor removed") }
        }
        let snapshot = applier.snapshot
        applier.snapshot = { events.append("inventory"); return try snapshot() }
        let before = h.system.windows.map(\.frame)
        var escape: Task<Void, Never>?
        func queueEscape() {
            guard escape == nil else { return }
            events.append("Escape queued")
            escape = Task { @MainActor in
                events.append("Escape delivered"); deliverKey?(53)
            }
        }
        var firstWrite = false
        h.system.onFrameWrite = { _, _ in
            if !firstWrite { firstWrite = true; events.append("first frame written") }
        }
        h.system.onBeforeFrameWrite = { [weak h] id in
            guard let h, stage == "frame write", escape == nil,
                  h.system.frameWriteCounts.keys.count == 1, h.system.frameWriteCounts[id] == nil else { return }
            #expect(h.system.windows.map(\.frame) != before)
            queueEscape() // The first window has changed; the second write has not started.
        }
        h.system.onVisibleWindowSweep = { [weak h] _ in
            guard let h else { return }
            // Participant validation uses targeted cached reads. The first full
            // sweep after all four writes prepares the proposed session's frames.
            if stage == "session preparation", h.system.frameWriteCounts.keys.count == 4 { queueEscape() }
        }
        // The fake event turn delivers a queued key, rather than calling its monitor inline in a write.
        model.savedLayoutInputCheckpoint = { if let escape { await escape.value }; return true }
        let document = SavedLayoutDocument(name: "Two panes", mode: .tabbed,
            layout: .split(axis: .vertical, ratios: [0.5, 0.5], children: [.group("left"), .group("right")]),
            slots: [.init(id: "editor", bundleID: "com.example.Editor"), .init(id: "peer", bundleID: "com.example.Peer")],
            groups: [.init(id: "left", slots: ["editor"], selected: "editor"), .init(id: "right", slots: ["peer"], selected: "peer")])
        let result = await applier.apply(document, displayID: h.system.mainDisplay.id)
        await escape?.value
        try #require(escape != nil)
        #expect(events.first == "monitor installed")
        #expect(events.firstIndex(of: "first frame written")! < events.firstIndex(of: "Escape delivered")!)
        #expect(events.last == "monitor removed")
        #expect(result.placed == 0 && result.issues.first?.kind == .stopped)
        #expect(h.system.windows.map(\.frame) == before)
        #expect(model.savedLayoutSessions()[h.system.mainDisplay.id] == .manual)
    }
}


@Suite @MainActor struct SavedLayoutInputTurnTests {
    @Test(arguments: ["input turn", "deadline", "cancel"])
    func pendingInputHasABoundedLifetime(completion: String) async throws {
        let clock = ManualClock()
        var ready: (@MainActor () -> Void)?
        var removed = 0
        let turn = SavedLayoutInputTurn(clock: clock.clock, observe: { handler in
            ready = handler
            return { removed += 1 }
        })
        var result: Bool?
        let task = Task { result = await turn.wait() }
        defer { task.cancel() }
        try await waitForSavedLayoutState("The input checkpoint did not start.", timeout: .seconds(2)) {
            ready != nil && clock.pendingSleepCount == 1
        }
        switch completion {
        case "input turn": ready?()
        case "deadline": clock.advance(by: .seconds(1))
        default: task.cancel()
        }
        try await waitForSavedLayoutState("The input checkpoint did not finish.", timeout: .seconds(2)) {
            result != nil && clock.pendingSleepCount == 0
        }
        #expect(result == (completion == "input turn"))
        #expect(removed == 1)
        ready?() // A late callback cannot resume or remove the observer twice.
        #expect(removed == 1)
    }
}


@Suite(.appTestApplication, .settingsUI) @MainActor struct SavedLayoutNativeInputTurnTests {
    @Test func aPostedEscapeReachesTheLocalMonitorBeforeCommit() async throws {
        try #require(NSApp.isRunning && NativeEventLoopState.keepsApplicationRunning)
        let h = ApplyHarness(); defer { h.close() }
        h.addWindow(id: "first"); h.addWindow(id: "second")
        let store = ConfigurationStore(fileURL: h.directory.appendingPathComponent("configuration.json"))
        var configuration = BetterTileConfiguration(); configuration.defaultLayoutMode = .manual
        try store.save(configuration)
        let model = h.model(); defer { model.shutdown() }
        model.handleApplicationActivation()
        let applier = try #require(model.savedLayoutApplier)
        applier.application = h.applier.application; applier.observesKeyboard = true
        let before = h.system.windows.map(\.frame)
        let escape = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: 0, context: nil, characters: "\u{1b}",
            charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        var posted = false
        var checkpointActive = false
        var observed = false
        var monitorsRemoved = false
        let nativeMonitor = applier.observeKeyDown
        applier.observeKeyDown = { [weak applier] handler in
            let remove = nativeMonitor { [weak applier] code in
                if code == 53 {
                    #expect(checkpointActive && applier?.isBusy == true && !monitorsRemoved)
                    observed = true
                }
                handler(code)
            }
            return { monitorsRemoved = true; remove() }
        }
        h.system.onBeforeFrameWrite = { [weak h] id in
            guard let h, !posted, h.system.frameWriteCounts.keys.count == 1,
                  h.system.frameWriteCounts[id] == nil else { return }
            #expect(h.system.windows.map(\.frame) != before)
            posted = true
            NSApp.postEvent(escape, atStart: false)
        }
        model.savedLayoutInputCheckpoint = {
            #expect(posted && !observed)
            checkpointActive = true
            let ready = await SavedLayoutInputTurn(clock: h.system.clock).wait()
            #expect(observed, "The posted key must reach AppKit's local monitor before the checkpoint returns.")
            checkpointActive = false
            return ready
        }
        let result = await applier.apply(h.document(mode: .tabbed), displayID: h.system.mainDisplay.id)
        #expect(posted && observed && monitorsRemoved)
        #expect(result.placed == 0 && result.issues.first?.kind == .stopped)
        #expect(h.system.windows.map(\.frame) == before)
        #expect(model.savedLayoutSessions()[h.system.mainDisplay.id] == .manual)
    }

    @Test func anInputTurnServicesQueuedRunLoopWork() async throws {
        try #require(NSApp.isRunning && NativeEventLoopState.keepsApplicationRunning)
        let clock = ManualClock()
        let marker = try #require(NSEvent.otherEvent(with: .applicationDefined, location: .zero,
            modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0))
        var queue = [marker]
        var serviceTurn: (@MainActor () -> Void)?
        var removed = 0
        let turn = SavedLayoutInputTurn(clock: clock.clock, observe: { ready in
            serviceTurn = {
                if SavedLayoutInputTurn.serviceQueuedInput(nextEvent: { queue.isEmpty ? nil : queue.removeFirst() }) {
                    ready()
                }
            }
            return { removed += 1; serviceTurn = nil }
        })
        var processed = false
        var checkpointActive = false
        var result: Bool?
        let monitor = try #require(NSEvent.addLocalMonitorForEvents(matching: .applicationDefined) { event in
            if event === marker {
                MainActor.assumeIsolated {
                    #expect(checkpointActive && result == nil)
                    processed = true
                }
                return nil
            }
            return event
        })
        defer { NSEvent.removeMonitor(monitor) }
        let task = Task { result = await turn.wait() }
        defer { task.cancel() }
        try await waitForSavedLayoutState("The input checkpoint did not register.", timeout: .seconds(2)) {
            serviceTurn != nil && clock.pendingSleepCount == 1
        }
        #expect(!processed && result == nil && queue.count == 1)
        checkpointActive = true
        serviceTurn?()
        checkpointActive = false
        try await waitForSavedLayoutState("The serviced input turn did not finish.", timeout: .seconds(2)) {
            result != nil && clock.pendingSleepCount == 0
        }
        #expect(result == true && processed)
        #expect(queue.isEmpty && removed == 1)
    }

    @Test func aSaturatedInputTurnWaitsForItsInjectedDeadline() async throws {
        let clock = ManualClock()
        let marker = try #require(NSEvent.otherEvent(with: .applicationDefined, location: .zero,
            modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0))
        var serviceTurn: (@MainActor () -> Void)?
        var serviced = 0
        var remaining = 257
        var removed = 0
        let turn = SavedLayoutInputTurn(clock: clock.clock, observe: { ready in
            serviceTurn = {
                if SavedLayoutInputTurn.serviceQueuedInput(nextEvent: {
                    guard remaining > 0 else { return nil }
                    remaining -= 1
                    return marker
                }, sendEvent: { _ in serviced += 1 }) {
                    ready()
                }
            }
            return { removed += 1; serviceTurn = nil }
        })
        var result: Bool?
        let task = Task { result = await turn.wait() }
        defer { task.cancel() }
        try await waitForSavedLayoutState("The input deadline did not register.", timeout: .seconds(2)) {
            serviceTurn != nil && clock.pendingSleepCount == 1
        }
        serviceTurn?()
        #expect(serviced == 256 && remaining == 1 && result == nil && removed == 0 && clock.pendingSleepCount == 1)
        clock.advance(by: .seconds(1))
        try await waitForSavedLayoutState("The saturated input turn did not refuse at its deadline.", timeout: .seconds(2)) {
            result != nil && clock.pendingSleepCount == 0
        }
        #expect(result == false && removed == 1)
    }
}
