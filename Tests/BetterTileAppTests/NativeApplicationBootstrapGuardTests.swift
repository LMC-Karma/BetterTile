import AppKit
import Testing

@Suite(.appTestApplication) @MainActor
struct NativeApplicationBootstrapGuardTests {
    @Test func nativeLoopRejectsMissingBootstrapPolicy() throws {
        do {
            _ = try withoutNativeApplicationContextForTesting {
                try withNativeEventLoop { true }
            }
            Issue.record("An unscoped native loop must fail before entering AppKit")
        } catch let error as NativeApplicationBootstrapError {
            #expect(error.testName == Test.current?.name)
            #expect(error.description.contains("bootstrap policy"))
        }
    }

    @Test func nativeWindowRejectsMissingBootstrapPolicy() throws {
        do {
            try withoutNativeApplicationContextForTesting {
                try NativeApplicationBootstrap.requireContext(for: "create a native window")
            }
            Issue.record("An unscoped native window must fail its bootstrap policy")
        } catch let error as NativeApplicationBootstrapError {
            #expect(error.testName == Test.current?.name)
            #expect(error.operation == "create a native window")
        }
    }

    @Test func nativeLaunchRejectsMissingBootstrapPolicy() async throws {
        do {
            try await withoutNativeApplicationContextForTesting {
                try await NativeEventLoopState.startApplicationHost()
            }
            Issue.record("An unscoped native launch must fail before entering AppKit")
        } catch let error as NativeApplicationBootstrapError {
            #expect(error.testName == Test.current?.name)
            #expect(error.description.contains("bootstrap policy"))
        }
    }
}
