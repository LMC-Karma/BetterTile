import AppKit
import BetterTileTestSupport
import Synchronization
import Testing

/// The environment flag opens the lane; the inherited suite marker limits its permission.
enum NativeFocusTestLane {
    static let isEnabled = ProcessInfo.processInfo.environment["BETTERTILE_NATIVE_FOCUS_TESTS"] == "1"

    static func permitsActivation(for test: Test? = Test.current) -> Bool {
        permitsActivation(isEnabled: isEnabled, hasFocusTrait: test?.traits.contains { $0 is NativeFocusTrait } == true)
    }

    static func permitsActivation(isEnabled: Bool, hasFocusTrait: Bool) -> Bool {
        isEnabled && hasFocusTrait
    }
}

struct NativeFocusTrait: TestTrait, SuiteTrait {
    var isRecursive: Bool { true }
}

extension Trait where Self == NativeFocusTrait {
    static var nativeFocus: Self { Self() }
}

/// Skips a test on CI when its result depends on a live desktop session that a hosted runner does not provide:
/// pixels of rendered native glass, GPU-dependent golden images, Vision text recognition, synthetic input into native
/// controls, or real key-window and activation state. GitHub Actions sets `CI`; local and pre-PR full runs keep the test.
/// Use it only for such an environmental limit, never for a timing, ordering or wrong-result failure. Each tagged suite
/// names the model or colour-maths test that still covers its logic on CI.
extension Trait where Self == ConditionTrait {
    static var liveDesktop: Self {
        .enabled(if: ProcessInfo.processInfo.environment["CI"] == nil,
                 "Needs a live desktop session (rendered native glass, GPU, Vision, real input or key state); skipped when CI is set")
    }
}

/// An episode starts at an actual active sample, not at a delayed notification.
struct NativeActivationEpisodes: Sendable {
    struct Episode: Sendable {
        let start: TimeInterval
        let utc: String
        let tests: [String]
        var lastActive: TimeInterval
        var end: TimeInterval?
        var notificationTests: Set<String> = []
    }
    private(set) var episodes: [Episode] = []
    private var openEpisode: Int?

    mutating func sample(active: Bool, uptime: TimeInterval, utc: String, tests: [String], notification: Bool = false) {
        if active {
            let index: Int
            if let openEpisode { index = openEpisode }
            else {
                index = episodes.count
                episodes.append(Episode(start: uptime, utc: utc, tests: tests, lastActive: uptime))
                openEpisode = index
            }
            episodes[index].lastActive = uptime
            if notification { episodes[index].notificationTests.formUnion(tests) }
        } else if let openEpisode {
            episodes[openEpisode].end = uptime
            self.openEpisode = nil
        }
    }
}

/// A thread-safe exit hook prints after Swift Testing's summary, even when an episode stays open.
enum NativeActivationSummary {
    private static let state = Mutex(NativeActivationEpisodes())

    static func installExitSummary() {
        // Register outside MainActor so exit on SwiftPM's executor is allowed.
        atexit { NativeActivationSummary.printAtExit() }
    }

    static func sample(active: Bool, tests: [String], notification: Bool = false) {
        let uptime = NativeAuditClock.uptime // real-time: timestamps actual native application activity for the process-exit audit
        let utc = NativeAuditClock.utc // real-time: timestamps actual native application activity for the process-exit audit
        state.withLock { $0.sample(active: active, uptime: uptime, utc: utc, tests: tests, notification: notification) }
    }

    static func printAtExit() {
        // NSRunningApplication is process-local and does not require an AppKit event turn.
        sample(active: NSRunningApplication.current.isActive, tests: ["process exit"])
        let episodes = state.withLock { $0.episodes }
        let label = NativeFocusTestLane.isEnabled ? "Native focus" : "Native test"
        var output = "\(label) activation summary: \(episodes.count) episode(s)\n"
        for (index, episode) in episodes.enumerated() {
            let row: [String: Any] = ["episode": index + 1, "firstActiveUTC": episode.utc,
                "firstObservedDuringTests": episode.tests,
                "notificationDeliveredDuringTests": episode.notificationTests.sorted(),
                "observedActiveSeconds": episode.lastActive - episode.start,
                "inactiveObservedAfterSeconds": episode.end.map { ($0 - episode.start) as Any } ?? NSNull(),
                "activeAtExit": episode.end == nil]
            if let data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]),
               let line = String(data: data, encoding: .utf8) { output += line + "\n" }
        }
        try? FileHandle.standardOutput.write(contentsOf: Data(output.utf8))
    }
}
