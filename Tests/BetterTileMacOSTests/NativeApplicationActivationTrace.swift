import AppKit
import BetterTileTestSupport
import Testing

/// Opt-in evidence about this process only. Never records another app's identity.
@MainActor enum NativeApplicationActivationTrace {
    private static let path = ProcessInfo.processInfo.environment["BETTERTILE_TEST_ACTIVATION_TRACE"]
    private static var activityObserver: (any NSObjectProtocol)?
    private static var deactivationObserver: (any NSObjectProtocol)?
    private static var workspaceObserver: (any NSObjectProtocol)?
    private static var entries: [UUID: [String: String]] = [:]
    private static var previousCompletedTest: String?
    private static var frontmostWasCurrent: Bool?
    private static var priorFrontmostWasOther: Bool?
    private static var frontmostSampleTime: TimeInterval?

    static func install() {
        guard path != nil || NativeFocusTestLane.isEnabled, activityObserver == nil else { return }
        NativeActivationSummary.installExitSummary()
        sampleFrontmost()
        activityObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in MainActor.assumeIsolated { recordActivation() } }
        deactivationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { _ in MainActor.assumeIsolated {
            let active = NSRunningApplication.current.isActive
            NativeActivationSummary.sample(active: active, tests: currentTests(), notification: true)
            write(["kind": "did-resign-active", "actualProcessActive": active])
        } }
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { notification in
            guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let isCurrent = application.processIdentifier == ProcessInfo.processInfo.processIdentifier
            MainActor.assumeIsolated {
                if isCurrent { priorFrontmostWasOther = frontmostWasCurrent.map { !$0 } }
                frontmostWasCurrent = isCurrent
                frontmostSampleTime = NativeAuditClock.uptime // real-time: correlates real AppKit activation notifications with native test scopes
            }
        }
    }

    static func enter(test: String, scope: String) -> UUID? {
        guard path != nil || NativeFocusTestLane.isEnabled else { return nil }
        install()
        sampleFrontmost()
        let token = UUID()
        entries[token] = ["test": test, "scope": scope]
        write(["kind": "scope-enter", "token": token.uuidString, "test": test, "scope": scope])
        return token
    }

    static func leave(_ token: UUID?) {
        guard let token, let entry = entries.removeValue(forKey: token) else { return }
        if entry["scope"] == "test" { previousCompletedTest = entry["test"] }
        sampleFrontmost()
        write(["kind": "scope-leave", "token": token.uuidString,
               "test": entry["test"] ?? "unknown", "scope": entry["scope"] ?? "unknown"])
    }

    static func sampleFrontmost() {
        guard path != nil else { return }
        let isCurrent = NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier
        if isCurrent, frontmostWasCurrent == false { priorFrontmostWasOther = true }
        frontmostWasCurrent = isCurrent
        frontmostSampleTime = NativeAuditClock.uptime // real-time: correlates real AppKit activation notifications with native test scopes
    }

    private static func currentTests() -> [String] {
        let leases = entries.values.filter { $0["scope"] == "UI lease" }.compactMap { $0["test"] }
        return leases.isEmpty ? [Test.current?.name ?? "native callback"] : leases.sorted()
    }

    static func recordActivitySample(active: Bool, test: String) {
        guard path != nil || NativeFocusTestLane.isEnabled else { return }
        NativeActivationSummary.sample(active: active, tests: [test])
    }

    private static func recordActivation() {
        NativeActivationSummary.sample(active: NSRunningApplication.current.isActive, tests: currentTests(), notification: true)
        guard let app = NSApp else { return }
        let displays = NSScreen.screens.map(\.frame)
        let ordered = Set(app.orderedWindows.map(ObjectIdentifier.init))
        let windows: [[String: Any]] = app.windows.map { window in
            let offscreen = window.frame.isEmpty || !displays.contains { $0.intersects(window.frame) }
            var row: [String: Any] = ["class": NSStringFromClass(type(of: window)),
                "number": window.windowNumber, "visible": window.isVisible,
                "key": window.isKeyWindow, "main": window.isMainWindow,
                "canBecomeKey": window.canBecomeKey, "canBecomeMain": window.canBecomeMain,
                "ordered": ordered.contains(ObjectIdentifier(window)), "level": window.level.rawValue,
                "collectionBehavior": window.collectionBehavior.rawValue,
                "hidesOnDeactivate": window.hidesOnDeactivate, "canHide": window.canHide,
                "onActiveSpace": window.isOnActiveSpace,
                "nonactivating": window.styleMask.contains(.nonactivatingPanel),
                "titled": window.styleMask.contains(.titled), "offscreen": offscreen,
                "occlusion": window.occlusionState.rawValue]
            if offscreen { row["offscreenFrame"] = NSStringFromRect(window.frame) }
            return row
        }
        let event = app.currentEvent
        var row: [String: Any] = ["kind": "did-become-active", "test": Test.current?.name ?? "native callback",
            "liveScopes": entries.values.map { $0 }, "previousCompletedTest": previousCompletedTest ?? "none",
            "eventType": event.map { String(describing: $0.type) } ?? "none",
            "eventTypeRaw": event.map { Int($0.type.rawValue) } ?? -1,
            "windows": windows, "windowCount": windows.count,
            "visibleCount": app.windows.filter(\.isVisible).count,
            "nativeHostRunning": app.isRunning,
            "longLivedHostRunning": NativeEventLoopState.keepsApplicationRunning,
            "ownedLoopRunning": NativeEventLoopState.isRunning,
            "activationPolicy": app.activationPolicy().rawValue,
            "actualProcessActive": NSRunningApplication.current.isActive,
            "frontmostIsThisProcess": NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier,
            "publicActivationTraceEnabled": ProcessInfo.processInfo.environment["BETTERTILE_TEST_PUBLIC_ACTIVATION_TRACE"] == "1"]
        if let event, [.appKitDefined, .applicationDefined, .systemDefined].contains(event.type) {
            row["eventSubtype"] = event.subtype.rawValue
        }
        if let frontmostWasCurrent { row["lastFrontmostSampleWasAnotherProcess"] = !frontmostWasCurrent }
        if let priorFrontmostWasOther { row["priorFrontmostWasAnotherProcess"] = priorFrontmostWasOther }
        if let frontmostSampleTime { row["frontmostSampleAge"] = NativeAuditClock.uptime - frontmostSampleTime } // real-time: correlates real AppKit activation notifications with native test scopes
        write(row)
    }

    static func recordRecoveryRequest(after test: String) {
        write(["kind": "deactivation-request", "test": test,
               "actualProcessActiveAfterRequest": NSRunningApplication.current.isActive])
    }

    private static func write(_ values: [String: Any]) {
        guard let path else { return }
        do {
            var row = values
            row["utc"] = NativeAuditClock.utc // real-time: correlates real AppKit activation notifications with native test scopes
            row["uptime"] = NativeAuditClock.uptime // real-time: correlates real AppKit activation notifications with native test scopes
            if !FileManager.default.fileExists(atPath: path) { FileManager.default.createFile(atPath: path, contents: nil) }
            let handle = try FileHandle(forWritingTo: URL(filePath: path))
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: JSONSerialization.data(withJSONObject: row) + Data([10]))
        } catch { Issue.record(error) }
    }
}
