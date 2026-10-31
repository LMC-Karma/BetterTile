import BetterTileCore
import Testing
@testable import BetterTileApp

@Test(.appTestApplication, arguments: [false, true]) @MainActor
func interruptedTabbedRollbackSuspendsItsSessionOnlyAfterARealWriteFailure(failsWrite: Bool) async throws {
    let system = makeManualWindowSystem()
    let model = makeModel(system: system)
    defer { model.shutdown() }
    let display = system.mainDisplay.id, source = system.windows[0].id
    model.setActiveMode(.tabbed)
    try #require(await system.waitFor { !model.hasPendingTabbedPlacement })
    try #require(model.beginBentoDrag(displayID: display, sourceID: source))
    system.windows[0].frame.origin.x += 140
    let displaced = system.windows[0].frame
    let writes = system.frameWriteCounts[source, default: 0]
    if failsWrite { system.failedFrameWriteNumbers[source] = [writes + 1] }
    else { system.ignoredFrameWriteWindowIDs = [source] }
    var readAfterRestore = false
    system.onWindowSnapshots = {
        if system.frameWriteCounts[source, default: 0] > writes { readAfterRestore = true }
    }
    model.finishBentoDrag(displayID: display, sourceID: source, end: .failed(reason: "That pane cannot hold it."))
    try #require(await system.waitFor { readAfterRestore })
    let tasks = try #require(Mirror(reflecting: model).children.first {
        $0.label?.hasSuffix("tabbedTasks") == true
    }?.value as? [DisplayID: Task<Void, Never>])
    let rollback = try #require(tasks[display])
    // The new gesture owns recovery of the unfinished frame. It cancels the old rollback.
    try #require(model.beginBentoDrag(displayID: display, sourceID: source))
    await system.join(rollback)
    let store = try #require(Mirror(reflecting: model).children.first {
        $0.label?.hasSuffix("sessionStore") == true
    }?.value as? LayoutSessionStore)
    let session = try #require(store.session(for: display))
    #expect(session.automaticWritesSuspended == failsWrite)
    #expect((model.statusMessage?.contains("Repair Layout") == true) == failsWrite)
    #expect(system.windows[0].frame == displaced)
    #expect(system.frameWriteCounts[source] == writes + 1)
}
