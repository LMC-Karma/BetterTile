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

/// A control that tracks a press and its drags in its own event loop until the button is released, as a slider can.
private final class DragTrackingControl: NSControl {
    private(set) var position: CGFloat?
    private(set) var tookRelease = false
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        let limit = Date(timeIntervalSinceNow: 2) // real-time: bounds this probe's tracking loop, so a missing release fails instead of hanging
        while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp], until: limit, inMode: .eventTracking, dequeue: true) {
            if next.type == .leftMouseUp { tookRelease = true; return }
            position = convert(next.locationInWindow, from: nil).x
        }
    }
}

@Test(.appTestApplication, .settingsUI) @MainActor func nativeDragChecksAControlThatTracksThePressBeforeItsRelease() throws {
    let window = OffscreenTestWindow(contentRect: NSRect(x: 12000, y: 0, width: 200, height: 40),
                                     styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let control = DragTrackingControl(frame: NSRect(x: 0, y: 0, width: 200, height: 40))
    window.contentView = control
    window.orderFront(nil) // Offscreen at x = 12000, like the Settings hosts these drags serve.
    var releasedDuringCheck = true
    let dragged = try performNativeDrag(from: CGPoint(x: 20, y: 20), to: CGPoint(x: 180, y: 20), in: window) {
        releasedDuringCheck = control.tookRelease
        return control.position == 180
    }
    #expect(dragged, "The check sees the drag while the control is still tracking the press")
    #expect(!releasedDuringCheck)
    #expect(control.tookRelease)
}

// Records which Swift Testing scope acquired the UI resource, not elapsed time.
enum SettingsUIAcquisition {
    @TaskLocal static var wasInsideTimedCase: Bool?
}
