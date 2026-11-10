#if DEBUG
import BetterTileCore
import Foundation
import Testing
@testable import BetterTileMacOS

@Suite(.macOSTestApplication, .serialized) @MainActor
struct ArrivalTraceWriterTests {
    @Test func aBlockedWriterBoundsPendingRecordsAndReportsItsOverflow() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ArrivalBacklog-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("trace.jsonl")
        let queue = DispatchQueue(label: "ArrivalBacklogTest")
        let trace = ArrivalTrace(isEnabled: true, url: url, writerQueue: queue, maximumPendingRecords: 8)
        queue.suspend()
        for _ in 0..<10_000 { trace.record("event", pid: 42) }
        queue.resume()
        trace.flush()
        let initial = try rows(url)
        #expect(initial.count == 9)
        #expect(initial.filter { $0["phase"] as? String == "event" }.count == 8)
        let overflow = try #require(initial.last)
        #expect(overflow["phase"] as? String == "trace_overflow")
        #expect(overflow["dropped_records"] as? Int == 9_992)
        let times = initial.compactMap { $0["timestamp_ns"] as? UInt64 }
        #expect(times == times.sorted())
        trace.record("after", pid: 42)
        trace.flush()
        #expect(try rows(url).last?["phase"] as? String == "after")
    }

    @Test func confirmedClosureReleasesTraceStateAndKeepsLiveWindowDeduplication() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ArrivalLifetime-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("trace.jsonl")
        let trace = ArrivalTrace(isEnabled: true, url: url)
        let coordinator = WindowCoordinator(system: FakeWindowSystem())
        coordinator.arrivalTrace = trace
        let live = WindowID(rawValue: "live")
        let frame = BTRect(x: 0, y: 0, width: 500, height: 800)
        trace.readable(pid: 42, windowID: live, frame: frame)
        for index in 0..<1_000 {
            let id = WindowID(rawValue: "closed-\(index)")
            trace.readable(pid: 43, windowID: id, frame: frame)
            coordinator.removeClosedWindow(id)
            trace.readable(pid: 42, windowID: live, frame: frame)
        }
        let windows = Mirror(reflecting: trace).children.first { $0.label == "windows" }?.value
        #expect((windows as? any Collection)?.count == 1)
        trace.flush()
        let liveRows = try rows(url).filter { $0["window_id"] as? String == live.rawValue }
        #expect(liveRows.count == 1)
        #expect(liveRows.first?["phase"] as? String == "first_readable_frame")
    }

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
