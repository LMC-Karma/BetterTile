import AppKit
import BetterTileCore
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
        let ownership = try await SettingsUILease.shared.acquire(holder: test.name)
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

/// How a Settings UI wait ended.
enum SettingsUIWaitOutcome: Equatable {
    case settled
    /// The condition never held. `polls` counts every poll, including the final one.
    case exhausted(polls: Int)
}

/// Drive layout until the observed UI condition holds, and return how the wait ended without recording anything.
/// The budget counts layout opportunities, one per 20 ms step: another main-actor test can stall this task without
/// giving SwiftUI a chance to update. Each poll lays out and draws `view`, though, and on a loaded machine a poll can
/// take far longer than its step. The wait therefore also ends once `timeout` has passed in wall time and it has had
/// at least `minimumSettingsUIPolls` opportunities, so a condition that never holds cannot keep the main actor busy,
/// and the tests queued behind it, for many times its timeout.
@MainActor func settleSettingsUI(in view: NSView, timeout: Duration = .seconds(30),
                                 until ready: () -> Bool) async -> SettingsUIWaitOutcome {
    func poll() -> Bool {
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        return ready()
    }
    let step = Duration.milliseconds(20)
    let wall = ContinuousClock() // real-time: bounds the wall time of a wait whose polls can be slow on a loaded machine
    let deadline = wall.now.advanced(by: timeout)
    var polls = 0
    for _ in 0..<Int((timeout / step).rounded(.up)) {
        polls += 1
        if poll() { return .settled }
        if polls >= minimumSettingsUIPolls, wall.now >= deadline { break }
        try? await BetterTileClock.live.sleep(for: step)
    }
    return poll() ? .settled : .exhausted(polls: polls + 1)
}

/// Waits as `settleSettingsUI` does, and fails the test, stopping the caller, when the condition never holds.
@MainActor func waitForSettingsUI(_ description: String, in view: NSView,
                                 timeout: Duration = .seconds(30), reporter: HelperFailureReporter = .issue,
                                 until ready: () -> Bool) async throws {
    guard case .exhausted = await settleSettingsUI(in: view, timeout: timeout, until: ready) else { return }
    try reporter.require(Comment(rawValue: "Exhausted layout opportunities waiting for \(description)"),
                         sourceLocation: #_sourceLocation)
}

/// Opportunities a Settings UI wait always gets, even after its wall-clock deadline: a main-actor stall in another
/// test must not use up a short wait before SwiftUI has had a chance to update.
let minimumSettingsUIPolls = 5

/// Settles `host`, then waits until `view`'s frame in the hosting view is the same over two layout passes, and
/// returns it. A click aimed before the page's last layout can land where the control used to be.
@MainActor func waitForStableFrame(of view: NSView, in host: SettingsSnapshotHost, _ description: String) async throws -> CGRect {
    host.settle()
    var previous: CGRect?
    var frame = CGRect.null
    try await waitForSettingsUI("a stable frame for \(description)", in: host.view) {
        frame = view.convert(view.bounds, to: host.view)
        defer { previous = frame }
        return !frame.isEmpty && frame == previous
    }
    return frame
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

@Test(.appTestApplication, .settingsUI) @MainActor func settingsUIWaitEndsAtItsWallClockDeadlineWhenPollsAreSlow() async {
    let view = NSView(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
    var polls = 0
    // Ten 20 ms opportunities, but each poll takes 50 ms and the condition never holds.
    let outcome = await settleSettingsUI(in: view, timeout: .milliseconds(200)) {
        polls += 1
        Thread.sleep(forTimeInterval: 0.05) // real-time: makes each poll slower than its step, as on a loaded machine
        return false
    }
    #expect(outcome == .exhausted(polls: polls), "The condition never holds, so the wait reports that it exhausted its opportunities")
    // Counting opportunities alone would use all ten. The wall-clock deadline ends the wait after the minimum.
    #expect(polls >= minimumSettingsUIPolls && polls < 10, "polls: \(polls)")
}

@Test(.appTestApplication, .settingsUI) @MainActor func settingsUIWaitFailsAndStopsItsCallerWhenTheConditionNeverHolds() async {
    let view = NSView(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
    let failures = HelperFailureLog()
    var continued = false
    await #expect(throws: HelperFailureLog.Stopped.self) {
        try await waitForSettingsUI("a condition that never holds", in: view, timeout: .milliseconds(40),
                                    reporter: .collecting(into: failures)) { false }
        continued = true
    }
    #expect(!continued)
    #expect(failures.messages == ["Exhausted layout opportunities waiting for a condition that never holds"])
    #expect(failures.reported.map(\.sourceLocation.fileID) == ["BetterTileAppTests/SettingsUITestSupport.swift"],
            "Like the #require it replaces, the failure points at the helper")
}

/// A control that tracks a press in its own event loop until the button is released, as a switch can.
private final class PressTrackingControl: NSControl {
    private(set) var presses = 0
    private(set) var tookRelease = false
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        presses += 1
        let limit = Date(timeIntervalSinceNow: 2) // real-time: bounds this probe's tracking loop, so a missing release fails instead of hanging
        tookRelease = window?.nextEvent(matching: .leftMouseUp, until: limit, inMode: .eventTracking, dequeue: true) != nil
    }
}

@Test(.appTestApplication, .settingsUI) @MainActor func nativeMouseClickReleasesAControlThatTracksThePress() throws {
    let window = OffscreenTestWindow(contentRect: NSRect(x: 12000, y: 0, width: 80, height: 40),
                                     styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let control = PressTrackingControl(frame: NSRect(x: 0, y: 0, width: 80, height: 40))
    window.contentView = control
    window.orderFront(nil) // Offscreen at x = 12000, like the Settings hosts these clicks serve.
    try performNativeMouseClick(at: CGPoint(x: 40, y: 20), in: window)
    #expect(control.presses == 1)
    #expect(control.tookRelease, "The press-tracking loop takes the queued release instead of waiting for a real one")
}

// Records which Swift Testing scope acquired the UI resource, not elapsed time.
enum SettingsUIAcquisition {
    @TaskLocal static var wasInsideTimedCase: Bool?
}
