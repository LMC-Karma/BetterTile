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
    await withKnownIssue("The condition never holds, so the wait reports its timeout") {
        let ready = await waitUntil(timeout: .milliseconds(200)) {
            polls += 1
            Thread.sleep(forTimeInterval: 0.05) // real-time: makes each poll slower than its step, as on a loaded runner
            return false
        }
        #expect(!ready)
    }
    // Counting steps alone runs all ten opportunities and a final poll.
    #expect(polls >= 5 && polls < 10, "polls: \(polls)")
}
