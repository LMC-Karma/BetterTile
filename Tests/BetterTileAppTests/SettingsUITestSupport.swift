import AppKit
import Testing
import BetterTileTestSupport

/// AppKit's event monitors, popovers, and tracking state belong to the process, not one window.
/// MainActor alone allows another async test to use them whenever the first test suspends.
struct SettingsUITrait: TestTrait, SuiteTrait, TestScoping {
    var isRecursive: Bool { true }

    func scopeProvider(for test: Test, testCase: Test.Case?) -> Self? {
        // Swift Testing starts each case's time limit inside this outer function scope.
        // Queue for the UI resource here, before that budget starts.
        guard !test.isSuite, testCase == nil else { return nil }
        return self
    }

    func provideScope(for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void) async throws {
        let ownership = try await SettingsUILease.shared.acquire()
        let traceToken = await NativeApplicationActivationTrace.enter(test: test.name, scope: "UI lease")
        do {
            try await NativeApplicationBootstrap.start(keepsApplicationRunning: true)
            try await SettingsUIAcquisition.$wasInsideTimedCase.withValue(Test.Case.current != nil) {
                try await NativeEventLoopLease.$isHeld.withValue(true) {
                    // Parameter cases share this ownership and must not overlap each other.
                    try await ParallelizationTrait.serialized.provideScope(for: test, testCase: nil, performing: function)
                }
            }
        } catch {
            await verifyNativeTestApplicationState(after: test.name,
                allowsActivation: NativeFocusTestLane.permitsActivation(for: test))
            await NativeApplicationActivationTrace.leave(traceToken)
            await SettingsUILease.shared.release(ownership)
            throw error
        }
        await verifyNativeTestApplicationState(after: test.name,
                allowsActivation: NativeFocusTestLane.permitsActivation(for: test))
        await NativeApplicationActivationTrace.leave(traceToken)
        await SettingsUILease.shared.release(ownership)
    }
}

extension Trait where Self == SettingsUITrait {
    static var settingsUI: Self { Self() }
}

private enum SettingsUILease {
    static let shared = AsyncTestLease()
}

/// Drive layout until the observed UI condition holds. Count layout opportunities, not elapsed time:
/// another main-actor test can stall this task without giving SwiftUI a chance to update.
@MainActor func waitForSettingsUI(_ description: String, in view: NSView,
                                 timeout: Duration = .seconds(30),
                                 until ready: () -> Bool) async throws {
    let settled = await waitFor(timeout: timeout) {
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        return ready()
    }
    try #require(settled, Comment(rawValue: "Exhausted layout opportunities waiting for \(description)"))
}

/// Turns the main run loop for a fixed time, for SwiftUI and AppKit work that has no observable completion,
/// such as layout and drawing before a snapshot or the release of a view graph. This is still a fixed-time
/// wait, not a readiness check: use `waitForSettingsUI` when a condition exists.
@MainActor func turnNativeRunLoop(_ passes: Int = 5, each interval: TimeInterval = 0.03, layout view: NSView? = nil,
                                  display: Bool = false, while pending: () -> Bool = { true }) {
    for _ in 0 ..< passes where pending() {
        view?.layoutSubtreeIfNeeded()
        if display { view?.displayIfNeeded() }
        RunLoop.main.run(until: Date().addingTimeInterval(interval)) // real-time: AppKit and SwiftUI schedule this work on the main run loop
    }
}

@Test(.appTestApplication, .settingsUI) @MainActor func settingsUIWaitKeepsLayoutOpportunitiesAfterMainActorStall() async throws {
    let view = NSView(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
    var passes = 0
    try await waitForSettingsUI("the second layout opportunity", in: view, timeout: .milliseconds(20)) {
        passes += 1
        if passes == 1 { Thread.sleep(forTimeInterval: 0.1) } // real-time: the check needs a real main-actor stall
        return passes == 2
    }
    #expect(passes == 2)
}

// Records which Swift Testing scope acquired the UI resource, not elapsed time.
enum SettingsUIAcquisition {
    @TaskLocal static var wasInsideTimedCase: Bool?
}
