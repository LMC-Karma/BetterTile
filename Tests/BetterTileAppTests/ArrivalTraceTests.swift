#if DEBUG
import BetterTileCore
import BetterTileMacOS
import Foundation
import Testing
@testable import BetterTileApp

@Suite(.appTestApplication, .serialized) @MainActor
struct ArrivalTraceTests {
    @Test(arguments: [LayoutMode.bento, .tabbed], [false, true])
    func fakeArrivalTracesOnlyWhenEnabled(mode: LayoutMode, enabled: Bool) async throws {
        let suite = "ArrivalTraceTests-\(UUID())"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let url = directory.appendingPathComponent("trace.jsonl")
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let trace = ArrivalTrace(isEnabled: enabled, url: url)
        let system = makeManualWindowSystem()
        let model = makeModel(system: system)
        model.arrivalTrace = trace
        defer { model.shutdown() }
        model.configuration.singleWindowPlacement = .maximize
        model.setActiveMode(mode)
        try #require(await system.waitFor { model.settlementTasks.isEmpty && (mode != .tabbed || model.activeTabbedState != nil) })
        await system.advance(by: .milliseconds(300))
        let id = WindowID(rawValue: "traced-arrival")
        let initial = BTRect(x: 200, y: 200, width: 600, height: 400)
        system.windows.append(WindowSnapshot(id: id, processIdentifier: 81, frame: initial, displayID: system.mainDisplay.id))
        system.eventHandler?(WindowSystemEvent(kind: .created, windowID: id, processIdentifier: 81))
        system.eventHandler?(WindowSystemEvent(kind: .created, windowID: id, processIdentifier: 81))
        try #require(await system.waitFor { system.frameWriteCounts[id, default: 0] > 0 && model.settlementTasks.isEmpty })
        await system.advance(by: .milliseconds(350))
        trace.flush()
        #expect(system.windows.first { $0.id == id }?.frame != initial)
        if !enabled {
            #expect(!FileManager.default.fileExists(atPath: directory.path))
            return
        }
        let data = try Data(contentsOf: url)
        let rows = try data.split(separator: 0x0a).map {
            try #require(JSONSerialization.jsonObject(with: Data($0)) as? [String: Any])
        }
        let timestamps = try rows.map { try #require($0["timestamp_ns"] as? UInt64) }
        #expect(timestamps == timestamps.sorted())
        let arrival = rows.filter { $0["window_id"] as? String == id.rawValue }
        let phases = arrival.compactMap { $0["phase"] as? String }
        let expected = ["window_created_received", "arrival_coalesced", "readiness_attempt", "first_readable_frame",
                        "readiness_outcome", "minimum_probe_started", "minimum_probe_finished", "placement_decided",
                        "first_frame_write_issued", "write_readback_matching", "settled"]
        var cursor = phases.startIndex
        for phase in expected {
            let index = try #require(phases[cursor...].firstIndex(of: phase), "Missing ordered phase \(phase): \(phases)")
            cursor = index + 1
        }
        #expect(phases.filter { $0 == "first_readable_frame" }.count == 1)
        #expect(phases.filter { $0 == "first_frame_write_issued" }.count == 1)
        let decision = try #require(arrival.first { $0["phase"] as? String == "placement_decided" })
        #expect(decision["mode"] as? String == (mode == .bento ? "Adaptive" : "Tabbed"))
        #expect((decision["frame"] as? [Double])?.count == 4)
        #expect(arrival.allSatisfy { $0["pid"] as? Int == 81 })
        #expect(rows.allSatisfy { $0["title"] == nil && $0["bundleIdentifier"] == nil })
    }

    @Test(arguments: [LayoutMode.bento, .tabbed])
    func unreadableArrivalRetriesAndExpiredArrivalExplainsDrop(mode: LayoutMode) async throws {
        let suite = "ArrivalTraceTests-\(UUID())"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let url = directory.appendingPathComponent("trace.jsonl")
        defer { try? FileManager.default.removeItem(at: directory) }
        let trace = ArrivalTrace(isEnabled: true, url: url)
        let system = makeManualWindowSystem()
        let model = makeModel(system: system)
        model.arrivalTrace = trace
        defer { model.shutdown() }
        model.configuration.singleWindowPlacement = .maximize
        model.setActiveMode(mode)
        try #require(await system.waitFor { model.settlementTasks.isEmpty && (mode != .tabbed || model.activeTabbedState != nil) })
        await system.advance(by: .milliseconds(300))
        let clock = WindowArrivalTestClock(model)
        let id = WindowID(rawValue: "late-traced-arrival")
        system.windows.append(WindowSnapshot(id: id, processIdentifier: 81,
            frame: BTRect(x: 200, y: 200, width: 600, height: 400), displayID: system.mainDisplay.id))
        system.offscreenWindowIDs.insert(id)
        system.eventHandler?(WindowSystemEvent(kind: .created, windowID: id, processIdentifier: 81))
        await system.joinWindowEvent(on: model)
        #expect(system.frameWriteCounts[id, default: 0] == 0)
        system.offscreenWindowIDs.remove(id)
        try #require(await system.waitFor { system.frameWriteCounts[id, default: 0] > 0 && model.settlementTasks.isEmpty })
        await system.advance(by: .milliseconds(350))
        let expired = WindowID(rawValue: "expired-traced-arrival")
        system.eventHandler?(WindowSystemEvent(kind: .created, windowID: expired, processIdentifier: 82))
        clock.elapsed = 1
        model.processPendingWindowEvents()
        let departed = WindowID(rawValue: "departed-traced-arrival")
        system.eventHandler?(WindowSystemEvent(kind: .created, windowID: departed, processIdentifier: 83))
        model.beginActiveSpaceStabilization()
        try #require(await system.waitFor { !model.isStabilizingSpace })
        trace.flush()
        let rows = try Data(contentsOf: url).split(separator: 0x0a).map {
            try #require(JSONSerialization.jsonObject(with: Data($0)) as? [String: Any])
        }
        let late = rows.filter { $0["window_id"] as? String == id.rawValue }
        #expect(late.contains { $0["phase"] as? String == "readiness_outcome" && $0["outcome"] as? String == "omitted" })
        #expect(late.filter { $0["phase"] as? String == "readiness_attempt" }.count >= 2)
        #expect(late.contains { $0["phase"] as? String == "settled" })
        #expect(rows.contains { $0["window_id"] as? String == expired.rawValue && $0["reason"] as? String == "readiness_deadline" })
        #expect(rows.contains { $0["window_id"] as? String == departed.rawValue && $0["reason"] as? String == "space_stabilization_restarts_discovery" })
        #expect(system.frameWriteCounts[expired, default: 0] == 0)
        #expect(system.frameWriteCounts[departed, default: 0] == 0)
    }

}
#else
import BetterTileCore
import BetterTileMacOS
import Foundation
import Testing
@testable import BetterTileApp

/// Release counterparts. A Release build has no arrival trace; the same fake
/// arrivals must still be coalesced, retried, placed or dropped.
@Suite(.appTestApplication, .serialized) @MainActor
struct ArrivalTraceTests {
    @Test(arguments: [LayoutMode.bento, .tabbed])
    func releaseFakeArrivalIsPlacedWithoutTrace(mode: LayoutMode) async throws {
        let system = makeManualWindowSystem()
        let model = makeModel(system: system)
        defer { model.shutdown() }
        model.configuration.singleWindowPlacement = .maximize
        model.setActiveMode(mode)
        try #require(await system.waitFor { model.settlementTasks.isEmpty && (mode != .tabbed || model.activeTabbedState != nil) })
        await system.advance(by: .milliseconds(300))
        let id = WindowID(rawValue: "traced-arrival")
        let initial = BTRect(x: 200, y: 200, width: 600, height: 400)
        system.windows.append(WindowSnapshot(id: id, processIdentifier: 81, frame: initial, displayID: system.mainDisplay.id))
        system.eventHandler?(WindowSystemEvent(kind: .created, windowID: id, processIdentifier: 81))
        system.eventHandler?(WindowSystemEvent(kind: .created, windowID: id, processIdentifier: 81))
        try #require(await system.waitFor { system.frameWriteCounts[id, default: 0] > 0 && model.settlementTasks.isEmpty })
        await system.advance(by: .milliseconds(350))
        #expect(system.windows.first { $0.id == id }?.frame != initial)
    }

    @Test(arguments: [LayoutMode.bento, .tabbed])
    func releaseUnreadableArrivalRetriesAndExpiredArrivalIsDropped(mode: LayoutMode) async throws {
        let system = makeManualWindowSystem()
        let model = makeModel(system: system)
        defer { model.shutdown() }
        model.configuration.singleWindowPlacement = .maximize
        model.setActiveMode(mode)
        try #require(await system.waitFor { model.settlementTasks.isEmpty && (mode != .tabbed || model.activeTabbedState != nil) })
        await system.advance(by: .milliseconds(300))
        let clock = WindowArrivalTestClock(model)
        let id = WindowID(rawValue: "late-traced-arrival")
        system.windows.append(WindowSnapshot(id: id, processIdentifier: 81,
            frame: BTRect(x: 200, y: 200, width: 600, height: 400), displayID: system.mainDisplay.id))
        system.offscreenWindowIDs.insert(id)
        system.eventHandler?(WindowSystemEvent(kind: .created, windowID: id, processIdentifier: 81))
        await system.joinWindowEvent(on: model)
        #expect(system.frameWriteCounts[id, default: 0] == 0)
        system.offscreenWindowIDs.remove(id)
        try #require(await system.waitFor { system.frameWriteCounts[id, default: 0] > 0 && model.settlementTasks.isEmpty })
        await system.advance(by: .milliseconds(350))
        let expired = WindowID(rawValue: "expired-traced-arrival")
        system.eventHandler?(WindowSystemEvent(kind: .created, windowID: expired, processIdentifier: 82))
        clock.elapsed = 1
        model.processPendingWindowEvents()
        let departed = WindowID(rawValue: "departed-traced-arrival")
        system.eventHandler?(WindowSystemEvent(kind: .created, windowID: departed, processIdentifier: 83))
        model.beginActiveSpaceStabilization()
        try #require(await system.waitFor { !model.isStabilizingSpace })
        #expect(system.frameWriteCounts[expired, default: 0] == 0)
        #expect(system.frameWriteCounts[departed, default: 0] == 0)
    }
}
#endif
