#if DEBUG
import BetterTileCore
import Foundation
import Testing
@testable import BetterTileMacOS

@Suite(.macOSTestApplication, .serialized) @MainActor
struct ArrivalTraceWriterTests {
    private func rows(_ url: URL) throws -> [[String: Any]] {
        try Data(contentsOf: url).split(separator: 0x0a).map {
            try #require(JSONSerialization.jsonObject(with: Data($0)) as? [String: Any])
        }
    }

    @Test func rejectedFakeWriteDoesNotClaimMatchingOrSettlement() throws {
        let suite = "ArrivalTraceWriterTests-\(UUID())"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let url = directory.appendingPathComponent("trace.jsonl")
        defer { try? FileManager.default.removeItem(at: directory) }
        let trace = ArrivalTrace(isEnabled: true, url: url)
        let system = FakeWindowSystem()
        let window = system.windows[0]
        trace.observe([window])
        let placement = Placement(windowID: window.id, frame: BTRect(x: 0, y: 0, width: 500, height: 800))
        trace.decided([placement], mode: "Adaptive")
        system.failingWindowID = window.id
        let coordinator = WindowCoordinator(system: system)
        coordinator.arrivalTrace = trace
        #expect(!coordinator.applyPlacements([placement]).isApplied)
        trace.settled(system.windows)
        trace.flush()
        let phases = try rows(url).compactMap { $0["phase"] as? String }
        #expect(phases.contains("first_frame_write_issued"))
        #expect(!phases.contains("write_readback_matching"))
        #expect(!phases.contains("settled"))
        #expect(system.windows[0].frame == window.frame)
    }

    @Test func appendedRunsHaveDistinctIDsAndSteppedSettlementIsExplicit() throws {
        // The Release counterpart looks the trace up by this runtime name.
        #expect(NSClassFromString(arrivalTraceClassName) === ArrivalTrace.self)
        let suite = "ArrivalTraceWriterTests-\(UUID())"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let url = directory.appendingPathComponent("trace.jsonl")
        defer { try? FileManager.default.removeItem(at: directory) }
        for _ in 0..<2 {
            let trace = ArrivalTrace(isEnabled: true, url: url)
            let system = FakeWindowSystem()
            let window = system.windows[0]
            trace.observe([window])
            let target = BTRect(x: window.frame.minX, y: window.frame.minY,
                width: window.frame.size.width + 10, height: window.frame.size.height)
            let placement = Placement(windowID: window.id, frame: target)
            trace.decided([placement], mode: "Tabbed")
            trace.willWrite(placement)
            var moved = window
            moved.frame = BTRect(x: window.frame.minX + 100, y: window.frame.minY,
                width: window.frame.size.width, height: window.frame.size.height)
            trace.settled([moved], accepted: true)
            trace.settled([window], accepted: true)
            trace.flush()
        }
        let records = try rows(url)
        #expect(Set(records.compactMap { $0["run_id"] as? String }).count == 2)
        #expect(records.filter { $0["phase"] as? String == "settled" }.count == 2)
        #expect(records.filter { $0["phase"] as? String == "settled" }.allSatisfy { $0["outcome"] as? String == "accepted_stepped" })
        #expect(!records.contains { $0["phase"] as? String == "write_readback_matching" })
    }

    @Test func traceFileFailureDoesNotChangeFakePlacement() throws {
        let suite = "ArrivalTraceWriterTests-\(UUID())"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let blocked = directory.appendingPathComponent("blocked")
        try Data().write(to: blocked)
        let url = blocked.appendingPathComponent("trace.jsonl")
        defer { try? FileManager.default.removeItem(at: directory) }
        let trace = ArrivalTrace(isEnabled: true, url: url)
        let system = FakeWindowSystem()
        trace.observe(system.windows)
        let placement = Placement(windowID: system.windows[0].id, frame: BTRect(x: 0, y: 0, width: 500, height: 800))
        trace.decided([placement], mode: "Adaptive")
        let coordinator = WindowCoordinator(system: system)
        coordinator.arrivalTrace = trace
        #expect(coordinator.applyPlacements([placement]).isApplied)
        trace.flush()
        #expect(system.windows[0].frame == placement.frame)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

}
#else
import BetterTileCore
import Foundation
import Testing
@testable import BetterTileMacOS

/// Release counterparts. The arrival trace is a Debug-only diagnostic, so a
/// Release build has no trace type; the same fake placements must still behave.
@Suite(.macOSTestApplication, .serialized) @MainActor
struct ArrivalTraceWriterTests {
    @Test func releaseRejectedFakeWriteLeavesFrame() {
        let system = FakeWindowSystem()
        let window = system.windows[0]
        let placement = Placement(windowID: window.id, frame: BTRect(x: 0, y: 0, width: 500, height: 800))
        system.failingWindowID = window.id
        let coordinator = WindowCoordinator(system: system)
        #expect(!coordinator.applyPlacements([placement]).isApplied)
        #expect(system.windows[0].frame == window.frame)
    }

    @Test func releaseBuildHasNoArrivalTrace() {
        #expect(NSClassFromString(arrivalTraceClassName) == nil)
    }

    @Test func releaseFakePlacementAppliesWithoutTrace() {
        let system = FakeWindowSystem()
        let placement = Placement(windowID: system.windows[0].id, frame: BTRect(x: 0, y: 0, width: 500, height: 800))
        let coordinator = WindowCoordinator(system: system)
        #expect(coordinator.applyPlacements([placement]).isApplied)
        #expect(system.windows[0].frame == placement.frame)
    }
}
#endif

private let arrivalTraceClassName = "BetterTileMacOS.ArrivalTrace"
