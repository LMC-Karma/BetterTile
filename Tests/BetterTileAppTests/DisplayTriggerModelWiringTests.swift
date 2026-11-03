import AppKit
import BetterTileCore
import BetterTileMacOS
import BetterTileTestSupport
import Foundation
import Testing
@testable import BetterTileApp

/// Coverage-only: model registration and permission policy with fake windows.
@MainActor private final class TriggerModelHarness {
    let root = FileManager.default.temporaryDirectory.appending(path: "DisplayTriggerWiring-" + UUID().uuidString)
    let system = makeManualWindowSystem()
    let clock = ManualClock()
    let workspaceCenter = NotificationCenter()
    let model: BetterTileModel
    let runtime: DisplayTriggerRuntime
    let second = DisplayID(rawValue: "second")
    var connected = false
    var loads = 0
    var frameReads = 0
    var lockWaitStarted = false
    let mainFingerprint = DisplayFingerprint(uuid: "main", vendor: 1, model: 1, serial: 1, builtIn: true,
        name: "Main", frame: .init(x: 0, y: 0, width: 1000, height: 800))
    let secondFingerprint = DisplayFingerprint(uuid: "second", vendor: 2, model: 2, serial: 2, builtIn: false,
        name: "Second", frame: .init(x: 1000, y: 0, width: 1000, height: 800))

    init(permission: Bool = true, target: Int = 1) throws {
        let store = DisplayTriggerStore(url: root.appending(path: "Display Triggers.json"))
        try #require(store.bind(.init(layoutFile: "studio.json", enabled: true, alsoAfterWake: true,
            displays: [mainFingerprint, secondFingerprint], target: target)))
        system.permission = permission
        model = makeOffscreenModel(store: .init(fileURL: root.appending(path: "configuration.json")),
                                   system: system, displayTriggerStore: store)
        runtime = try #require(model.displayTriggerRuntime)
        model.hasAccessibilityPermission = permission
        runtime.observesInput = false
        let origin = clock.now
        runtime.uptime = { [clock] in
            let duration = origin.duration(to: clock.now).components
            return Double(duration.seconds) + Double(duration.attoseconds) / 1e18
        }
        runtime.sleep = { [clock] duration in try? await clock.sleep(until: clock.now.advanced(by: duration)) }
        runtime.lockWait = { [weak self, clock] duration in
            self?.lockWaitStarted = true
            try? await clock.sleep(until: clock.now.advanced(by: duration))
        }
        runtime.liveDisplays = { [weak self] in
            guard let self else { return [] }
            let main = LiveDisplay(id: self.system.mainDisplay.id, fingerprint: self.mainFingerprint)
            return self.connected ? [main, .init(id: self.second, fingerprint: self.secondFingerprint)] : [main]
        }
        runtime.loadLayout = { [weak self] _ in self?.loads += 1; return nil }
        runtime.observeFrames = { [weak self] _ in self?.frameReads += 1; return [:] }
        runtime.isReady = { _ in true }
        runtime.isInteracting = { false }
        runtime.isScreenLocked = { false }
        runtime.notice = { _ in }
        model.installWorkspaceTriggers(center: NotificationCenter(), workspaceCenter: workspaceCenter)
    }

    func connect() { connected = true; runtime.displaysChanged() }
    func post(_ name: Notification.Name, userInfo: [AnyHashable: Any]? = nil) {
        workspaceCenter.post(name: name, object: nil, userInfo: userInfo)
    }
    func finish() {
        model.shutdown()
        try? FileManager.default.removeItem(at: root)
    }
}

@MainActor @Suite(.appTestApplication, .serialized, .timeLimit(.minutes(1)))
struct DisplayTriggerModelWiringTests {
    @Test func sessionResignationInvalidatesApplyBeforeTheNotificationReturns() async throws {
        let h = try TriggerModelHarness(target: 0)
        let applier = try #require(h.model.savedLayoutApplier)
        applier.observesKeyboard = false
        let main = h.system.mainDisplay.id
        let space = NativeSpaceID(rawValue: 1)
        h.system.desktopObservation = .init(currentSpaceByDisplay: [main: space],
            knownSpacesByDisplay: [main: [space]], windowMembership: [h.system.windows[0].id: [space]])
        let document = SavedLayoutDocument(name: "Held layout", mode: .manual,
            slots: [.init(id: "editor", bundleID: "com.example.Test")],
            windows: [.init(slot: "editor", rect: .init(x: 0, y: 0, width: 0.5, height: 1))])
        var release: CheckedContinuation<Void, Never>?
        var feedback: [SavedLayoutFeedback] = []
        applier.prepareAppGroups = { await withCheckedContinuation { release = $0 } }
        applier.feedback = { feedback.append($0) }
        h.runtime.loadLayout = { _ in document }
        defer { release?.resume(); applier.stop(); h.finish() }
        // Only Adaptive applies the single-window placement. Set it without a sweep, so the
        // refresh below is the desktop's first and its ordinary placement happens during preparation.
        h.model.configuration.defaultLayoutMode = .bento
        h.connect()
        try await waitForSavedLayoutState("The automatic wait did not start.", timeout: .seconds(2)) { h.clock.pendingSleepCount == 1 }
        h.clock.advance(by: .milliseconds(150))
        try await waitForSavedLayoutState("The automatic Apply did not start.", timeout: .seconds(2)) { release != nil }
        try #require(applier.isRunning && !h.runtime.isIdle)
        // A workspace refresh can apply the ordinary single-window placement
        // while this unrelated Saved Layout is still held in preparation.
        h.model.handleApplicationTopologyChange()
        try #require(!h.system.requestedFrames.isEmpty)
        let writesAtResignation = h.system.requestedFrames
        var writesAfterResignation = 0
        h.system.onBeforeFrameWrite = { _ in writesAfterResignation += 1 }
        h.post(NSWorkspace.sessionDidResignActiveNotification)
        #expect(h.runtime.isIdle,
            "The main-queue notification must invalidate Apply before an already queued continuation can resume.")
        let continuation = release; release = nil; continuation?.resume()
        try await waitForSavedLayoutState("The resigned Apply did not finish.", timeout: .seconds(2)) { !applier.isRunning }
        #expect(feedback.isEmpty)
        try #require(writesAfterResignation == 0 && h.system.requestedFrames == writesAtResignation,
            "Resignation must block every later write, without counting the earlier ordinary placement.")

        // The same fixture must actually be capable of placing the window once the session returns.
        h.system.onBeforeFrameWrite = nil
        applier.prepareAppGroups = {}
        h.post(NSWorkspace.sessionDidBecomeActiveNotification)
        let reads = h.frameReads
        h.connected = false; h.runtime.displaysChanged(); h.connect()
        try await waitForSavedLayoutState("The returning session did not begin fresh settling.", timeout: .seconds(2)) {
            h.frameReads > reads && h.clock.pendingSleepCount == 1
        }
        h.clock.advance(by: .milliseconds(150))
        try await waitForSavedLayoutState("The healthy control Apply did not finish.", timeout: .seconds(2)) {
            h.runtime.isIdle && h.runtime.runs["studio.json"]?.result.placed == 1
        }
        #expect(h.system.windows[0].frame == BTRect(x: 0, y: 0, width: 500, height: 800))
        #expect(h.system.requestedFrames != writesAtResignation && feedback.count == 1)
    }

    @Test func accessibilityPermissionGatesTheModelsActualTriggerClosure() async throws {
        let h = try TriggerModelHarness(permission: false)
        defer { h.finish() }
        #expect(h.runtime.triggers().isEmpty)
        h.connect()
        #expect(h.runtime.isIdle && h.loads == 0)
        h.system.permission = true
        h.model.hasAccessibilityPermission = true
        #expect(h.runtime.triggers().count == 1)
        h.connected = false; h.runtime.displaysChanged()
        h.connect()
        try #require(await waitFor { h.clock.pendingSleepCount > 0 })
        h.clock.advance(by: .seconds(1))
        try #require(await waitFor { h.loads == 1 && h.runtime.isIdle })
    }

    @Test(arguments: [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification],
          [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification])
    func workspaceSleepAndWakeNotificationsReachTheRuntime(sleep: Notification.Name, wake: Notification.Name) async throws {
        let h = try TriggerModelHarness()
        defer { h.finish() }
        h.connect()
        try #require(await waitFor { h.clock.pendingSleepCount > 0 && !h.runtime.isIdle })
        h.post(sleep)
        try #require(await waitFor { h.runtime.isIdle })
        #expect(h.loads == 0)
        let reads = h.frameReads
        h.post(wake)
        try #require(await waitFor { h.frameReads > reads && !h.runtime.isIdle })
        #expect(h.loads == 0)
    }

    @Test(arguments: [NSWorkspace.sessionDidBecomeActiveNotification, NSWorkspace.didActivateApplicationNotification])
    func workspaceReturnAndScreenUnlockNotificationsReleaseTheirOwnHold(unlock: Notification.Name) async throws {
        let h = try TriggerModelHarness()
        defer { h.finish() }
        h.connect()
        try #require(await waitFor { h.clock.pendingSleepCount > 0 })
        var locked = false
        h.runtime.isScreenLocked = { locked }
        if unlock == NSWorkspace.sessionDidBecomeActiveNotification {
            h.post(NSWorkspace.sessionDidResignActiveNotification)
        } else {
            // App activation releases the lock-screen hold, not a resigned user session.
            locked = true
            h.post(NSWorkspace.screensDidWakeNotification)
        }
        try #require(await waitFor { h.lockWaitStarted })
        #expect(h.loads == 0)
        let reads = h.frameReads
        let info: [AnyHashable: Any]? = unlock == NSWorkspace.didActivateApplicationNotification
            ? [NSWorkspace.applicationUserInfoKey: NSRunningApplication.current] : nil
        locked = false
        h.post(unlock, userInfo: info)
        try #require(await waitFor { h.frameReads > reads })
        #expect(h.loads == 0)
    }
}
