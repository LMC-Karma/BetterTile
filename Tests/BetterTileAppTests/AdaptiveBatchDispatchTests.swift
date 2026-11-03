import BetterTileCore
import Testing
@testable import BetterTileApp

@Test(.appTestApplication) @MainActor
func ordinaryAdaptiveCommitDispatchesAllApplicationsInOnePreparedBatch() throws {
    let system = makeManualWindowSystem()
    for index in 1...2 {
        var window = system.windows[0]
        window.id = WindowID(rawValue: "batch-\(index)")
        window.processIdentifier += Int32(index)
        system.windows.append(window)
    }
    let ids = Set(system.windows.map(\.id))
    let model = makeModel(system: system)
    defer { model.shutdown() }
    system.onFrameWrite = { _, _ in
        #expect(system.windowSnapshotRequests.contains(ids), "Every participant must validate before the first write")
    }
    model.tileCurrentDisplay()
    #expect(model.statusMessage == nil)
    #expect(system.frameWriteBatches.count == 1)
    let batch = try #require(system.frameWriteBatches.first)
    #expect(Set(batch.map(\.windowID)) == ids)
    #expect(Set(system.windows.map(\.processIdentifier)).count == 3)
}
