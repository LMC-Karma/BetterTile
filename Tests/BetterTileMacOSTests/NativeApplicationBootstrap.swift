import AppKit
import Testing

private enum NativeApplicationContext {
    @TaskLocal static var entered = false
    @TaskLocal static var initializing = false
}

struct NativeApplicationBootstrapError: Error, Equatable, CustomStringConvertible {
    let testName: String
    let operation: String
    var description: String {
        "Test \(testName) requires the native application bootstrap policy before it can \(operation)"
    }
}

@MainActor enum NativeApplicationBootstrap {
    private static var startup: Task<Void, any Error>?
    private(set) static var isReady = false

    static func start(keepsApplicationRunning: Bool) async throws {
        NativeApplicationActivationTrace.install()
        if let startup { return try await startup.value }
        let task = Task { @MainActor in
            try await NativeApplicationContext.$initializing.withValue(true) {
                let app = NSApplication.shared
                try #require(app.activationPolicy() == .prohibited,
                    "Native application bootstrap must begin with prohibited policy and no windows")
                try #require(app.windows.isEmpty,
                    "Native application bootstrap must finish before any test creates a window; starting test: \(Test.current?.name ?? "unknown")")
                if keepsApplicationRunning {
                    try await NativeEventLoopState.startApplicationHost()
                } else {
                    try NativeEventLoopLease.$isHeld.withValue(true) {
                        try withNativeEventLoop { }
                    }
                }
                try #require(NativeHostPolicyReading.current(of: app) == .accessory,
                             "Native application bootstrap must use accessory policy")
                let processIsActive = NSRunningApplication.current.isActive
                try #require(!processIsActive, "Native application bootstrap must not activate the test process")
                isReady = true
            }
        }
        startup = task
        try await task.value
    }

    static func requireContext(for operation: String, allowsInitialization: Bool = false) throws {
        if allowsInitialization && NativeApplicationContext.initializing { return }
        if isReady && NativeApplicationContext.entered { return }
        // AppKit can complete an owned fixture's delayed work outside a Swift task.
        if isReady && Test.current == nil && !allowsInitialization { return }
        throw NativeApplicationBootstrapError(testName: Test.current?.name ?? "native callback", operation: operation)
    }

    @discardableResult
    static func recordWindowAccess(_ operation: String,
                                   sourceLocation: SourceLocation = #_sourceLocation) -> Bool {
        do { try requireContext(for: operation); return true }
        catch { Issue.record(error, sourceLocation: sourceLocation); return false }
    }
}

/// The task gates startup only. Test bodies retain their normal parallel execution.
struct NativeApplicationTrait: TestTrait, SuiteTrait, TestScoping {
    var keepsApplicationRunning: Bool
    var isRecursive: Bool { true }

    func scopeProvider(for test: Test, testCase: Test.Case?) -> Self? {
        guard !test.isSuite else { return nil }
        return self
    }

    func provideScope(for test: Test, testCase: Test.Case?,
                      performing function: @Sendable () async throws -> Void) async throws {
        if testCase == nil {
            // Startup can wait on the process's shared native host. Do it before case timers start.
            try await NativeApplicationBootstrap.start(keepsApplicationRunning: keepsApplicationRunning)
            try await NativeApplicationContext.$entered.withValue(true) { try await function() }
            return
        }
        let traceToken = await NativeApplicationActivationTrace.enter(test: test.name, scope: "test")
        do {
            try await NativeApplicationContext.$entered.withValue(true) { try await function() }
        } catch {
            await verifyNativeTestApplicationState(after: test.name, boundary: "test",
                allowsActivation: NativeFocusTestLane.permitsActivation(for: test))
            await NativeApplicationActivationTrace.leave(traceToken)
            throw error
        }
        await verifyNativeTestApplicationState(after: test.name, boundary: "test",
                allowsActivation: NativeFocusTestLane.permitsActivation(for: test))
        await NativeApplicationActivationTrace.leave(traceToken)
    }
}

extension Trait where Self == NativeApplicationTrait {
    static var appTestApplication: Self { Self(keepsApplicationRunning: true) }
    static var macOSTestApplication: Self { Self(keepsApplicationRunning: false) }
}

@MainActor
func withoutNativeApplicationContextForTesting<Value>(
    _ operation: () throws -> Value
) rethrows -> Value {
    try NativeApplicationContext.$entered.withValue(false, operation: operation)
}

@MainActor
func withoutNativeApplicationContextForTesting<Value: Sendable>(
    _ operation: @MainActor () async throws -> Value
) async rethrows -> Value {
    try await NativeApplicationContext.$entered.withValue(false, operation: operation)
}
