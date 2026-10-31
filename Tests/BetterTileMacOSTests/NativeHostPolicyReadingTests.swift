import AppKit
import Testing

/// The native test host's policy check re-reads only a transient background-only report.
@Test func nativeHostPolicyReadingRereadsABackgroundOnlyReportUntilAccessory() {
    var reads: [NSApplication.ActivationPolicy] = [.prohibited, .prohibited, .accessory, .regular]
    var pauses = 0
    let reading = NativeHostPolicyReading.settledPolicy(read: { reads.removeFirst() }, pause: { pauses += 1 })
    #expect(reading.policy == .accessory)
    #expect(reading.rereads == 2)
    #expect(pauses == 2)
}

@Test(arguments: [NSApplication.ActivationPolicy.accessory, .regular])
func nativeHostPolicyReadingNeverRereadsAnotherPolicy(policy: NSApplication.ActivationPolicy) {
    var pauses = 0
    let reading = NativeHostPolicyReading.settledPolicy(read: { policy }, pause: { pauses += 1 })
    #expect(reading.policy == policy, "A regular host must still fail the accessory check at once")
    #expect(reading.rereads == 0)
    #expect(pauses == 0)
}

@Test func nativeHostPolicyReadingStopsAfterItsBudget() {
    var pauses = 0
    let reading = NativeHostPolicyReading.settledPolicy(attempts: 5, read: { .prohibited }, pause: { pauses += 1 })
    #expect(reading.policy == .prohibited, "A lasting background-only report still fails the accessory check")
    #expect(reading.rereads == 5)
    #expect(pauses == 5)
}

/// A transient background-only report after the bootstrap must not request `.accessory` again: that request
/// fails while the policy already is `.accessory`.
@Test func preparingSettlesATransientReportWithoutRequestingAccessory() {
    var reads: [NSApplication.ActivationPolicy] = [.prohibited, .accessory, .accessory]
    var requests: [NSApplication.ActivationPolicy] = []
    let result = NativeHostPolicyReading.prepareAccessory(settlesTransient: true, read: { reads.removeFirst() },
                                                          pause: {}, set: { requests.append($0); return false })
    #expect(requests.isEmpty)
    #expect(result.setSucceeded == nil)
    #expect(result.before == .accessory && result.after == .accessory)
    #expect(result.rereads == 1)
}

/// Before the bootstrap finishes, `.prohibited` is the real starting policy: request `.accessory` at once.
@Test func preparingTheStartingPolicyRequestsAccessoryWithoutRereading() {
    var reads: [NSApplication.ActivationPolicy] = [.prohibited, .accessory]
    var requests: [NSApplication.ActivationPolicy] = []
    var pauses = 0
    let result = NativeHostPolicyReading.prepareAccessory(settlesTransient: false, read: { reads.removeFirst() },
                                                          pause: { pauses += 1 }, set: { requests.append($0); return true })
    #expect(requests == [.accessory])
    #expect(result.setSucceeded == true)
    #expect(result.before == .prohibited && result.after == .accessory)
    #expect(pauses == 0 && result.rereads == 0)
}

@Test func preparingARegularPolicyRequestsAccessoryAndReportsTheResult() {
    var reads: [NSApplication.ActivationPolicy] = [.regular, .regular]
    let result = NativeHostPolicyReading.prepareAccessory(settlesTransient: true, read: { reads.removeFirst() },
                                                          pause: {}, set: { _ in false })
    #expect(result.before == .regular)
    #expect(result.setSucceeded == false, "A refused change still fails the caller's requirement")
    #expect(result.after == .regular)
    #expect(result.rereads == 0)
}
