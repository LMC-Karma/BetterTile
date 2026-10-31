import Testing

@Test(.appTestApplication)
func nativeActivityGuardRecordsFailuresBeforeRecoveringOnce() {
    var guardState = NativeApplicationActivityGuard()
    var events: [String] = []
    var failures = 0
    func check(_ active: Bool) {
        guardState.check(processIsActive: active, recordCheck: {
            if active { failures += 1; events.append("failure") }
            else { events.append("pass") }
        }, deactivate: { events.append("deactivate") },
           recordRecovery: { events.append("recovery logged") })
    }

    check(false)
    #expect(events == ["pass"])
    #expect(failures == 0)
    events.removeAll()
    check(true)
    #expect(events == ["failure", "deactivate", "recovery logged"])
    #expect(failures == 1)
    events.removeAll()
    check(true)
    #expect(events == ["failure"])
    #expect(failures == 2, "An already requested recovery must not hide another failed check")
    events.removeAll()
    check(false)
    #expect(events == ["pass"])
    check(true)
    #expect(events == ["pass", "failure", "deactivate", "recovery logged"])
    #expect(failures == 3)
}
