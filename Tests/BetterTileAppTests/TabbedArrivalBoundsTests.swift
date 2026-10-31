import BetterTileCore
import Testing
@testable import BetterTileMacOS
@testable import BetterTileApp

@Test(.appTestApplication, .timeLimit(.minutes(1))) @MainActor
func tabbedArrivalKeepsRoundedBottomInsideThe1440PointDisplay() async throws {
    let system = makeManualWindowSystem()
    let display = system.mainDisplay.id
    let bounds = BTRect(x: 1210, y: 34, width: 2560, height: 1406)
    system.availableDisplays = [DisplaySnapshot(id: display,
        frame: BTRect(x: 1210, y: 0, width: 2560, height: 1440), visibleFrame: bounds, isMain: true)]
    let top = system.windows[0].id, bottom = WindowID(rawValue: "bottom")
    system.windows[0].frame = BTRect(x: 1210, y: 34, width: 2560, height: 702.5)
    system.windows.append(WindowSnapshot(id: bottom, processIdentifier: 43,
        frame: BTRect(x: 1210, y: 737.5, width: 2560, height: 702.5), displayID: display))
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.configuration.bentoInnerGap = 1
    model.tileCurrentDisplay()
    try #require(await system.waitFor { model.settlementTasks.isEmpty })
    model.setActiveMode(.tabbed)
    try #require(await system.waitFor { !model.hasPendingTabbedPlacement })
    let before = try #require(model.activeTabbedState)
    let pane = try #require(before.paneID(containing: bottom))
    model.performTabbed(.activate(pane))
    try #require(await system.waitFor { !model.hasPendingTabbedPlacement })
    // Prove the logical split is fractional even though the requested window edges must be whole.
    #expect(before.frames(in: bounds)[pane]?.minY == 737.5)
    system.requestedFrames = [:]
    system.frameReadbackTransform = { _, requested in
        BTRect(x: requested.minX.rounded(), y: requested.minY.rounded(),
               width: requested.size.width.rounded(), height: requested.size.height.rounded())
    }
    let arrival = WindowID(rawValue: "arrival")
    system.windows.append(WindowSnapshot(id: arrival, processIdentifier: 44,
        frame: BTRect(x: 2800, y: 800, width: 600, height: 400), displayID: display))
    system.eventHandler?(WindowSystemEvent(kind: .created, windowID: arrival, processIdentifier: 44))
    try #require(await system.waitFor {
        model.activeTabbedState?.selectedWindowIDs.contains(arrival) == true && !model.hasPendingTabbedPlacement
    })
    let requested = try #require(system.requestedFrames[arrival]?.last)
    let actual = try #require(system.windows.first { $0.id == arrival }?.frame)
    #expect(system.frameWriteCounts[arrival, default: 0] > 0)
    #expect(model.activeTabbedState?.paneID(containing: arrival) == pane)
    #expect(model.statusMessage == nil)
    #expect(requested == requested.snappedToWholePoints())
    #expect(actual.maxY <= 1440)
    #expect(actual.maxX <= 3770)
    #expect(actual == requested)
}
