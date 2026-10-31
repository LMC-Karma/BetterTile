import Testing
import BetterTileTestSupport

/// Real panels, key-window notifications, and the pointer belong to the process, not one test.
/// MainActor alone lets another async test change them whenever the first test suspends.
/// A test that orders real windows or reads key-window or pointer state holds this lease.
/// Tests that only render offscreen stay parallel.
struct MacOSUITrait: TestTrait, SuiteTrait, TestScoping {
    var isRecursive: Bool { true }

    func scopeProvider(for test: Test, testCase: Test.Case?) -> Self? {
        // Swift Testing starts each case's time limit inside this outer function scope.
        // Queue for the UI resource here, before that budget starts.
        guard !test.isSuite, testCase == nil else { return nil }
        return self
    }

    func provideScope(for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void) async throws {
        let ownership = try await MacOSUILease.shared.acquire()
        let traceToken = await NativeApplicationActivationTrace.enter(test: test.name, scope: "UI lease")
        do {
            try await NativeApplicationBootstrap.start(keepsApplicationRunning: false)
            try await MacOSUIAcquisition.$wasInsideTimedCase.withValue(Test.Case.current != nil) {
                try await NativeEventLoopLease.$isHeld.withValue(true) {
                    // Parameter cases share this ownership and must not overlap each other.
                    try await ParallelizationTrait.serialized.provideScope(for: test, testCase: nil, performing: function)
                }
            }
        } catch {
            await verifyNativeTestApplicationState(after: test.name,
                allowsActivation: NativeFocusTestLane.permitsActivation(for: test))
            await NativeApplicationActivationTrace.leave(traceToken)
            await MacOSUILease.shared.release(ownership)
            throw error
        }
        await verifyNativeTestApplicationState(after: test.name,
                allowsActivation: NativeFocusTestLane.permitsActivation(for: test))
        await NativeApplicationActivationTrace.leave(traceToken)
        await MacOSUILease.shared.release(ownership)
    }
}

extension Trait where Self == MacOSUITrait {
    static var macOSUI: Self { Self() }
}

private enum MacOSUILease {
    static let shared = AsyncTestLease()
}

// Records which Swift Testing scope acquired the UI resource, not elapsed time.
enum MacOSUIAcquisition {
    @TaskLocal static var wasInsideTimedCase: Bool?
}
