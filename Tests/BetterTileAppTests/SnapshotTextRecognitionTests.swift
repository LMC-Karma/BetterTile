import CoreML
import BetterTileTestSupport
import Foundation
import Synchronization
import Testing

@Suite @MainActor struct SnapshotTextRecognitionTests {
    @Test func recognitionDoesNotOccupyTheMainActor() async throws {
        let ranOnMain = try await performSnapshotRecognition { Thread.isMainThread }
        #expect(!ranOnMain, "Native text recognition must not prevent other tests' main-actor work.")
    }

    @Test func recognitionSelectsCPUForEveryComputeStage() async throws {
        let configured = try await performSnapshotRecognition {
            let request = try snapshotTextRequest()
            let stages = try request.supportedComputeStageDevices.keys
            return !stages.isEmpty && stages.allSatisfy {
                if case .cpu = request.computeDevice(for: $0) { return true }
                return false
            }
        }
        #expect(configured, "Every exposed Vision compute stage must request CPU execution.")
    }

    @Test(arguments: [false, true])
    func stalledNativeWorkDoesNotHoldItsCaller(cancel: Bool) async throws {
        let clock = ManualClock()
        let release = DispatchSemaphore(value: 0)
        let state = Mutex((started: false, finished: false))
        var outcome: String?
        let task = Task {
            do {
                _ = try await performSnapshotRecognition(clock: clock.clock, timeout: .seconds(1)) {
                    state.withLock { $0.started = true }
                    defer { state.withLock { $0.finished = true } }
                    release.wait() // real-time: models uncooperative native work; the bounded owning test releases it on every exit
                    return "late success"
                }
                outcome = "success"
            } catch is CancellationError { outcome = "cancelled" }
            catch SnapshotRecognitionError.timedOut { outcome = "timed out" }
            catch { outcome = "unexpected error: \(error)" }
        }
        defer { release.signal(); task.cancel() }
        try await waitForSavedLayoutState("Native work and its deadline must start", timeout: .seconds(2)) {
            state.withLock { $0.started } && clock.pendingSleepCount == 1
        }
        if cancel { task.cancel() } else { clock.advance(by: .seconds(1)) }
        try await waitForSavedLayoutState("The caller must finish while native work remains blocked", timeout: .seconds(2)) {
            outcome != nil && clock.pendingSleepCount == 0
        }
        #expect(outcome == (cancel ? "cancelled" : "timed out"))
        #expect(!state.withLock { $0.finished })
        release.signal()
        try await waitForSavedLayoutState("Late native work must release its resources", timeout: .seconds(2)) {
            state.withLock { $0.finished }
        }
        #expect(outcome == (cancel ? "cancelled" : "timed out"))
    }
}
