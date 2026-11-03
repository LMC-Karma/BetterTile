import AppKit
import BetterTileTestSupport
import Testing

enum NativeEventLoopLease {
    @TaskLocal static var isHeld = false
}

@MainActor private func prepareNativeTestApplication(_ app: NSApplication) throws {
    // Before the bootstrap finishes, `.prohibited` is the process's real starting policy, not a transient report.
    let result = NativeHostPolicyReading.prepareAccessory(
        settlesTransient: NativeApplicationBootstrap.isReady, read: { app.activationPolicy() },
        pause: NativeHostPolicyReading.pause, set: { app.setActivationPolicy($0) })
    NativeHostPolicyReading.report(rereads: result.rereads, policy: result.after)
    if let changed = result.setSucceeded {
        try #require(changed, "Could not prepare accessory test policy; previous policy: \(result.before.rawValue)")
    }
    try #require(result.after == .accessory, "Native test loops require accessory policy")
}

/// AppKit does not store the policy: `activationPolicy()` asks LaunchServices for this process's type each
/// time. Under load LaunchServices can briefly report the unbundled test host as background-only
/// (`.prohibited`) although nothing changed it. This is a bounded tolerance for that report, not a fix of its
/// cause, which is outside this process. Every policy read in the native test support goes through here: it
/// reads again a bounded number of times for `.prohibited` only. Callers still require an observed
/// `.accessory`; `.regular` and every other value return at once.
enum NativeHostPolicyReading {
    static func pause() {
        Thread.sleep(forTimeInterval: 0.01) // real-time: LaunchServices updates the reported process type outside this process
    }

    static func report(rereads: Int, policy: NSApplication.ActivationPolicy) {
        guard rereads > 0 else { return }
        print("Native test host policy read as prohibited; \(rereads) re-reads returned \(policy.rawValue)")
    }

    /// The test process's policy, with a transient background-only report settled.
    @MainActor static func current(of app: NSApplication) -> NSApplication.ActivationPolicy {
        let reading = settledPolicy(read: { app.activationPolicy() }, pause: pause)
        report(rereads: reading.rereads, policy: reading.policy)
        return reading.policy
    }

    /// Requests `.accessory` only when the policy read before differs, then reads the result. With
    /// `settlesTransient`, both reads settle a transient background-only report first, so such a report
    /// never leads to a request that would fail because the policy is already `.accessory`.
    static func prepareAccessory(
        settlesTransient: Bool, attempts: Int = 50, read: () -> NSApplication.ActivationPolicy,
        pause: () -> Void, set: (NSApplication.ActivationPolicy) -> Bool
    ) -> (before: NSApplication.ActivationPolicy, rereads: Int, setSucceeded: Bool?, after: NSApplication.ActivationPolicy) {
        func settled() -> (policy: NSApplication.ActivationPolicy, rereads: Int) {
            settlesTransient ? settledPolicy(attempts: attempts, read: read, pause: pause) : (read(), 0)
        }
        let before = settled()
        let setSucceeded = before.policy == .accessory ? nil : set(.accessory)
        let after = settled()
        return (before.policy, before.rereads + after.rereads, setSucceeded, after.policy)
    }

    static func settledPolicy(attempts: Int = 50, read: () -> NSApplication.ActivationPolicy,
                              pause: () -> Void) -> (policy: NSApplication.ActivationPolicy, rereads: Int) {
        var policy = read()
        var rereads = 0
        while policy == .prohibited, rereads < attempts {
            pause()
            policy = read()
            rereads += 1
        }
        return (policy, rereads)
    }
}

@MainActor private func verifyBackgroundNativeTestApplication(_ app: NSApplication, allowsActivation: Bool = false) throws {
    let policy = NativeHostPolicyReading.current(of: app)
    try #require(policy == .accessory, "Native test host started with a non-accessory policy (\(policy.rawValue))")
    if !allowsActivation {
        let processIsActive = NSRunningApplication.current.isActive
        try #require(!processIsActive, "Native test host activated the test process")
    }
}

/// A failed activity check remains a failure; deactivation is a recovery request.
struct NativeApplicationActivityGuard {
    private var recoveryRequested = false

    mutating func check(processIsActive: Bool, recordCheck: () -> Void,
                        deactivate: () -> Void, recordRecovery: () -> Void) {
        recordCheck()
        guard processIsActive else { recoveryRequested = false; return }
        guard !recoveryRequested else { return }
        recoveryRequested = true
        deactivate()
        recordRecovery()
    }
}

@MainActor private enum NativeApplicationActivityRecovery {
    static var guardState = NativeApplicationActivityGuard()
}

@MainActor
func verifyNativeTestApplicationState(after testName: String, boundary: String = "UI lease",
                                      allowsActivation: Bool = false,
                                      sourceLocation: SourceLocation = #_sourceLocation) {
    let policy = NSApp?.activationPolicy()
    let processIsActive = NSRunningApplication.current.isActive
    NativeApplicationActivationTrace.recordActivitySample(active: processIsActive, test: testName)
    if let path = ProcessInfo.processInfo.environment["BETTERTILE_TEST_APPLICATION_AUDIT"] {
        do {
            let data = try JSONSerialization.data(withJSONObject: ["test": testName, "boundary": boundary,
                "activationPolicy": policy?.rawValue ?? -1, "processIsActive": processIsActive,
                "allowsActivation": allowsActivation,
                "utc": NativeAuditClock.utc,
                "uptime": NativeAuditClock.uptime,
                "frontmostIsThisProcess": NSWorkspace.shared.frontmostApplication?.processIdentifier
                    == ProcessInfo.processInfo.processIdentifier])
            if !FileManager.default.fileExists(atPath: path) { FileManager.default.createFile(atPath: path, contents: nil) }
            let handle = try FileHandle(forWritingTo: URL(filePath: path))
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data + Data([10]))
        } catch { Issue.record(error, sourceLocation: sourceLocation) }
    }
    #expect(policy != .regular, "After test \(testName), native activation policy is regular",
            sourceLocation: sourceLocation)
    if !allowsActivation {
        NativeApplicationActivityRecovery.guardState.check(processIsActive: processIsActive, recordCheck: {
            #expect(!processIsActive, "After test \(testName), the test process is active",
                    sourceLocation: sourceLocation)
        }, deactivate: {
            NSApp.deactivate()
        }, recordRecovery: {
            NativeApplicationActivationTrace.recordRecoveryRequest(after: testName)
            print("Native test activation recovery after \(testName): requested deactivation; inactivity is not confirmed")
        })
    }
}

@MainActor enum NativeEventLoopState {
    static var isRunning = false
    static var keepsApplicationRunning = false

    // App-model tests need the native animation and layout driver between inputs.
    // Swift Testing exits the process after its final summary; this loop stays owned
    // until then. macOS integration tests retain their per-interaction fixture.
    private static var startupObserver: CFRunLoopObserver?
    private static var nestedLoops = 0

    static func startApplicationHost() async throws {
        try NativeApplicationBootstrap.requireContext(for: "start the native application host", allowsInitialization: true)
        guard !keepsApplicationRunning else { return }
        let startingTestName = Test.current?.name ?? "unknown"
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            // A common-mode block can run inside another fixture's synchronous
            // run loop. Start only after that activation returns to the outer loop.
            let activities = CFRunLoopActivity.entry.rawValue | CFRunLoopActivity.exit.rawValue
                | CFRunLoopActivity.beforeWaiting.rawValue
            startupObserver = CFRunLoopObserverCreateWithHandler(nil, activities, true, 0) { observer, activity in
                MainActor.assumeIsolated {
                    if activity == .entry { nestedLoops += 1 }
                    else if activity == .exit { nestedLoops -= 1 }
                    else if nestedLoops == 0 {
                        CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes)
                        startupObserver = nil
                        do {
                            try #require(NSApplication.shared.windows.isEmpty,
                                "Native host bootstrap must finish before creating windows; starting test: \(startingTestName)")
                            try prepareNativeTestApplication(NSApplication.shared)
                        }
                        catch { continuation.resume(throwing: error); return }
                        RunLoop.main.perform(inModes: [.common]) {
                            MainActor.assumeIsolated {
                                keepsApplicationRunning = true
                                continuation.resume(with: Result { try verifyBackgroundNativeTestApplication(NSApplication.shared) })
                            }
                        }
                        NSApplication.shared.run()
                    }
                }
            }
            CFRunLoopAddObserver(CFRunLoopGetMain(), startupObserver, .commonModes)
            CFRunLoopWakeUp(CFRunLoopGetMain())
        }
    }
}

// Native event tracking can stop SwiftPM's async main loop before tests finish.
// Keep each native interaction inside an AppKit-owned loop.
@MainActor
func withNativeEventLoop<Value: Sendable>(_ operation: @escaping @MainActor @Sendable () throws -> Value,
                                        sourceLocation: SourceLocation = #_sourceLocation) throws -> Value {
    try NativeApplicationBootstrap.requireContext(for: "start a native event loop", allowsInitialization: true)
    try #require(NativeEventLoopLease.isHeld,
                 "Native interactions require the macOSUI or settingsUI lease", sourceLocation: sourceLocation)
    let app = NSApplication.shared
    let allowsActivation = NativeApplicationBootstrap.isReady && NativeFocusTestLane.permitsActivation()
    if NativeEventLoopState.keepsApplicationRunning {
        try #require(app.isRunning, "The App test host must own the native loop", sourceLocation: sourceLocation)
        try verifyBackgroundNativeTestApplication(app, allowsActivation: allowsActivation)
        return try operation()
    }
    try #require(!app.isRunning && !NativeEventLoopState.isRunning,
                 "The native interaction fixture must own its AppKit loop", sourceLocation: sourceLocation)
    try prepareNativeTestApplication(app)
    // Only bootstrap enters NSApplication.run. Re-entering it with an ordered
    // panel can activate an accessory process before the first event callback.
    let pumpsEvents = NativeApplicationBootstrap.isReady
    if !pumpsEvents {
        try #require(app.windows.isEmpty, "Native bootstrap must enter its application loop before creating windows")
    }
    NativeEventLoopState.isRunning = true
    defer { NativeEventLoopState.isRunning = false }
    var finished = false
    let stop: @MainActor () -> Void = {
        finished = true
        if !pumpsEvents { app.stop(nil) }
        let wake = NSEvent.otherEvent(with: .applicationDefined, location: .zero,
            modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            subtype: 0, data1: 0, data2: 0)!
        app.postEvent(wake, atStart: true)
    }
    var started = false
    var result: Result<Value, any Error>?
    let watchdog = Timer(timeInterval: 10, repeats: false) { _ in
        MainActor.assumeIsolated { if !started { stop() } }
    }
    RunLoop.main.add(watchdog, forMode: .common)
    defer { watchdog.invalidate() }
    // Pointer sequences can remain in event-tracking mode between inputs.
    RunLoop.main.perform(inModes: [.common]) {
        MainActor.assumeIsolated {
            started = true
            result = Result {
                try verifyBackgroundNativeTestApplication(app, allowsActivation: allowsActivation)
                return try operation()
            }
            stop()
        }
    }
    if pumpsEvents {
        let deadline = Date(timeIntervalSinceNow: 10)
        while !finished && Date() < deadline { // real-time: bounds the owned AppKit event pump; nextEvent(until:) needs a wall-clock date
            if let event = app.nextEvent(matching: .any, until: deadline, inMode: .default, dequeue: true) {
                app.sendEvent(event)
            }
            app.updateWindows()
        }
    } else {
        app.run()
    }
    return try #require(result, "The owned AppKit loop stopped before the native interaction completed",
                        sourceLocation: sourceLocation).get()
}

@MainActor
func performNativeClick(_ button: NSButton, sourceLocation: SourceLocation = #_sourceLocation) throws {
    try withNativeEventLoop({ button.performClick(nil) }, sourceLocation: sourceLocation)
}

// Offscreen fixtures do not need WindowServer ordering animations. Preserve the
// configured behavior so tests can still inspect the product's animation policy.
@MainActor
func withoutTestWindowAnimations(_ window: NSWindow, performing operation: () -> Void) {
    guard NativeApplicationBootstrap.recordWindowAccess("order or animate a native window") else { return }
    let behavior = window.animationBehavior
    window.animationBehavior = .none
    defer { window.animationBehavior = behavior }
    operation()
}

@MainActor extension NSWindow {
    func orderFrontForTesting() {
        withoutTestWindowAnimations(self) { orderFrontRegardless() }
    }

    func orderOutForTesting() {
        withoutTestWindowAnimations(self) { orderOut(nil) }
    }

    func makeKeyAndOrderFrontForTesting() {
        // AppKit's combined call makes the window key before ordering finishes.
        // A deactivation during ordering must precede the fixture's key request.
        withoutTestWindowAnimations(self) {
            orderFrontRegardless()
            makeKey()
        }
    }
}

/// Captures process-local key state without recording another application's identity.
@MainActor
func keyWindowDiagnostics(_ panel: NSWindow?) -> String {
    let app = NSApplication.shared
    let frontmostIsCurrent = NSWorkspace.shared.frontmostApplication?.processIdentifier
        == ProcessInfo.processInfo.processIdentifier
    return "NSApp.isActive=\(app.isActive), NSApp.keyWindow === panel=\(app.keyWindow === panel), "
        + "panel.canBecomeKey=\(String(describing: panel?.canBecomeKey)), "
        + "panel.isVisible=\(String(describing: panel?.isVisible)), "
        + "panel.isKeyWindow=\(String(describing: panel?.isKeyWindow)), "
        + "panel.occlusionState=\(String(describing: panel?.occlusionState.rawValue)), "
        + "hostLoopRunning=\(app.isRunning), ownedLoopRunning=\(NativeEventLoopState.isRunning), "
        + "longLivedHostRunning=\(NativeEventLoopState.keepsApplicationRunning), "
        + "NSRunningApplication.current.isActive=\(NSRunningApplication.current.isActive), "
        + "frontmost is this process: \(frontmostIsCurrent ? "yes" : "no")"
}
