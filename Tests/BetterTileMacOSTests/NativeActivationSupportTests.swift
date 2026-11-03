import Testing

@Suite(.macOSTestApplication)
struct NativeActivationSupportTests {
    @Test
    func nativeFocusPermissionRequiresBothTheLaneAndItsSuiteMarker() {
        #expect(!NativeFocusTestLane.permitsActivation(isEnabled: false, hasFocusTrait: false))
        #expect(!NativeFocusTestLane.permitsActivation(isEnabled: false, hasFocusTrait: true))
        #expect(!NativeFocusTestLane.permitsActivation(isEnabled: true, hasFocusTrait: false))
        #expect(NativeFocusTestLane.permitsActivation(isEnabled: true, hasFocusTrait: true))
    }

    @Test
    func delayedActivationNotificationDoesNotCreateAnotherEpisodeOrChangeItsFirstTest() {
        var state = NativeActivationEpisodes()
        state.sample(active: false, uptime: 0, utc: "initial", tests: ["initial"])
        state.sample(active: true, uptime: 1, utc: "first", tests: ["first test"])
        state.sample(active: true, uptime: 2, utc: "delayed", tests: ["later test"], notification: true)
        state.sample(active: false, uptime: 4, utc: "inactive", tests: ["last test"])
        #expect(state.episodes.count == 1)
        #expect(state.episodes[0].tests == ["first test"])
        #expect(state.episodes[0].notificationTests == ["later test"])
        #expect(state.episodes[0].lastActive - state.episodes[0].start == 1)
        #expect(state.episodes[0].end == 4)
        state.sample(active: true, uptime: 5, utc: "second", tests: ["second episode"])
        #expect(state.episodes.count == 2)
        #expect(state.episodes[1].end == nil)
    }
}
