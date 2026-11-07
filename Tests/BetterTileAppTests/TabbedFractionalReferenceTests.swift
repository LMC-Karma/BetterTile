import BetterTileCore
import Testing
@testable import BetterTileApp

@Test(.appTestApplication, .timeLimit(.minutes(1))) @MainActor
func oddWidthTabbedColumnsCorrectSteppedGrowthPastTheirWholePointArea() async throws {
    let system = makeManualWindowSystem()
    let left = system.windows[0].id, right = WindowID(rawValue: "right")
    system.availableDisplays[0].visibleFrame = BTRect(x: 0, y: 0, width: 999, height: 800)
    system.windows.append(WindowSnapshot(id: right, processIdentifier: 43,
        frame: BTRect(x: 499.5, y: 0, width: 499.5, height: 800), displayID: system.mainDisplay.id))
    system.windows[0].frame = BTRect(x: 0, y: 0, width: 499.5, height: 800)
    let model = makeModel(system: system)
    defer { model.shutdown() }
    // This geometry regression requires the adopted Adaptive split and gap.
    model.configuration.tabbedEntryPlacement = .keepAdaptivePanes
    model.configuration.bentoInnerGap = 0
    // Entering from Adaptive preserves its zero-gap tree instead of the preset's 6-point gap.
    model.tileCurrentDisplay()
    try #require(await system.waitFor { model.settlementTasks.isEmpty })
    model.setActiveMode(.tabbed)
    try #require(await system.waitFor { !model.hasPendingTabbedPlacement })
    #expect(model.activeTabbedState?.layout.metrics.paneGap == 0)
    #expect(system.windows.first { $0.id == left }?.frame.size.width == 500)
    #expect(system.windows.first { $0.id == right }?.frame.minX == 500)
    system.requestedFrames = [:]
    // The left app rounds to character cells; the right rounds origin and size.
    system.sizeGrids[left] = (step: BTSize(width: 14, height: 0), offset: BTSize(width: 503, height: 0))
    system.frameReadbackTransform = { id, requested in
        guard id == right else { return requested }
        var actual = requested
        actual.origin.x = requested.minX.rounded(.down)
        actual.size.width = requested.size.width.rounded()
        return actual
    }
    // Move the fake frames off their areas so the placement must issue writes.
    system.windows[0].frame.size.width -= 20
    system.windows[1].frame.origin.x += 20
    model.performTabbed(.preset(.columns))
    try #require(await system.waitFor { !model.hasPendingTabbedPlacement })
    let actual = Dictionary(uniqueKeysWithValues: system.windows.map { ($0.id, $0.frame) })
    let leftFrame = try #require(actual[left]), rightFrame = try #require(actual[right])
    #expect(model.statusMessage == nil)
    #expect(leftFrame.maxX - rightFrame.minX <= 2)
    #expect(system.requestedFrames[left]?.first?.size.width == 500)
    #expect(leftFrame.size.width == 503)
    #expect(model.activeTabbedState?.layout.contentFrames(in: system.availableDisplays[0].visibleFrame)[left]?.size.width == 503)
    #expect(rightFrame.minX == 503)
}
