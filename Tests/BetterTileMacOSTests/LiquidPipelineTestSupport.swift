import Testing
@testable import BetterTileMacOS

/// Marks a test that draws with the Metal liquid renderer.
///
/// Without the pipeline, the test fails once with the reason from
/// `LayoutWheelLiquidPipeline.failure` and does not run. Its later
/// expectations would only repeat that failure as unrelated errors.
struct LiquidPipelineTrait: TestTrait, TestScoping {
    func scopeProvider(for test: Test, testCase: Test.Case?) -> Self? {
        // Check once per test function, before any parameter case runs.
        guard !test.isSuite, testCase == nil else { return nil }
        return self
    }

    func provideScope(for test: Test, testCase: Test.Case?,
                      performing function: @Sendable () async throws -> Void) async throws {
        let failure = await MainActor.run { () -> String? in
            guard LayoutWheelLiquidPipeline.prepare() == nil else { return nil }
            return LayoutWheelLiquidPipeline.failure?.description ?? "unknown reason"
        }
        if let failure {
            Issue.record("""
                The Layout Wheel liquid pipeline is unavailable: \(failure). \
                SwiftPM must compile LayoutWheelLiquid.metal; Tools/test.sh selects the Swift Build backend for that.
                """)
            return
        }
        try await function()
    }
}

extension Trait where Self == LiquidPipelineTrait {
    /// The test needs the compiled Metal liquid pipeline.
    static var liquidPipeline: Self { Self() }
}
