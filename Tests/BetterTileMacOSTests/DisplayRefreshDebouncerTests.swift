import Foundation
import Testing
@testable import BetterTileMacOS

@MainActor
@Test func displayRefreshDebouncerCoalescesCallbackAndAppKitNotifications() async {
    let debouncer = DisplayRefreshDebouncer(delay: .milliseconds(20))
    var refreshCount = 0

    await withCheckedContinuation { continuation in
        debouncer.schedule { refreshCount += 1 }
        debouncer.schedule { refreshCount += 1 }
        debouncer.schedule {
            refreshCount += 1
            continuation.resume()
        }
    }

    #expect(refreshCount == 1)
}

@MainActor
@Test func cancelledDisplayRefreshDoesNotRun() async {
    let debouncer = DisplayRefreshDebouncer(delay: .milliseconds(20))
    var refreshCount = 0

    debouncer.schedule { refreshCount += 1 }
    debouncer.cancel()
    try? await Task.sleep(for: .milliseconds(60))

    #expect(refreshCount == 0)
}
