import Testing

@Suite(.macOSTestApplication, .macOSUI, .timeLimit(.minutes(1))) @MainActor
struct UILeaseScopeTests {
    private static var activeCases = 0

    @Test(arguments: [0, 1])
    func leaseAcquisitionPrecedesTheTimedCaseAndCasesRemainExclusive(_ index: Int) async throws {
        #expect(MacOSUIAcquisition.wasInsideTimedCase == false,
                "The UI lease must be acquired before Swift Testing starts a case's body budget")
        let test = try #require(Test.current)
        #expect(NativeApplicationTrait(keepsApplicationRunning: false).scopeProvider(for: test, testCase: nil) != nil,
                "Native application startup must also precede the timed case")
        Self.activeCases += 1
        defer { Self.activeCases -= 1 }
        #expect(Self.activeCases == 1)
        for _ in 0..<20 { await Task.yield() }
        #expect(Self.activeCases == 1, "Parameter cases must retain exclusive UI ownership")
    }
}
