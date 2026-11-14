import Foundation
import Testing
import BetterTileTestSupport

@Test @MainActor func appKitConditionWaitKeepsOpportunitiesAfterMainActorStall() async {
    var polls = 0
    let ready = await waitUntil(timeout: .milliseconds(20)) {
        polls += 1
        if polls == 1 { Thread.sleep(forTimeInterval: 0.1) } // real-time: reproduces a main-actor stall during a native UI poll
        return polls == 2
    }
    #expect(ready)
    #expect(polls == 2)
}

@Test @MainActor func appKitConditionWaitEndsAtItsWallClockDeadlineWhenPollsAreSlow() async {
    var polls = 0
    let outcome = await pollUntil(timeout: .milliseconds(200)) {
        polls += 1
        Thread.sleep(forTimeInterval: 0.05) // real-time: makes each poll slower than its step, as on a loaded runner
        return false
    }
    #expect(outcome == .timedOut(polls: polls), "The condition never holds, so the wait reports its timeout")
    // Counting steps alone runs all ten opportunities and a final poll.
    #expect(polls >= 5 && polls < 10, "polls: \(polls)")
}

@Test @MainActor func appKitConditionWaitReportsItsTimeoutAtTheCallersLocation() async {
    let failures = HelperFailureLog()
    let location = SourceLocation(fileID: "Fixture/Caller.swift", filePath: "/Fixture/Caller.swift", line: 7, column: 3)
    let ready = await waitUntil(timeout: .milliseconds(40), sourceLocation: location,
                                reporter: .collecting(into: failures)) { false }
    #expect(!ready)
    #expect(failures.reported == [HelperFailureLog.Entry(
        message: "Timed out waiting for a native UI condition after 3 polls (timeout: \(Duration.milliseconds(40)))",
        sourceLocation: location)])
}
