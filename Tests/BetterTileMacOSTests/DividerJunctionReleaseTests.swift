import AppKit
import BetterTileCore
import Testing
@testable import BetterTileMacOS

@Test(arguments: [SplitAxis.vertical, .horizontal], ["simultaneous", "staggered", "cascading", "late-mismatch", "failed-correction"]) @MainActor
func liveJunctionReleaseSettlesBothNewlyLearnedMinima(rootAxis: SplitAxis, scenario: String) throws {
    _ = NSApplication.shared
    let system = FakeWindowSystem()
    let bounds = BTRect(x: -10_000, y: -10_000, width: 800, height: 600)
    let display = DisplayID(rawValue: "junction-release")
    let ids = ["top-left", "bottom-left", "top-right", "bottom-right"].map { WindowID(rawValue: $0) }
    let root: BentoNode = rootAxis == .vertical
        ? .partition(BentoPartition(axis: .vertical,
            first: .partition(BentoPartition(axis: .horizontal, first: .leaf(ids[0]), second: .leaf(ids[1]))),
            second: .partition(BentoPartition(axis: .horizontal, first: .leaf(ids[2]), second: .leaf(ids[3])))))
        : .partition(BentoPartition(axis: .horizontal,
            first: .partition(BentoPartition(axis: .vertical, first: .leaf(ids[0]), second: .leaf(ids[2]))),
            second: .partition(BentoPartition(axis: .vertical, first: .leaf(ids[1]), second: .leaf(ids[3])))))
    let state = BentoLayoutState(root: root, metrics: BentoLayoutMetrics(paneGap: 0))
    system.availableDisplays = [DisplaySnapshot(id: display, frame: bounds, visibleFrame: bounds)]
    system.windows = state.placements(in: bounds).map {
        WindowSnapshot(id: $0.windowID, processIdentifier: 1, frame: $0.frame, displayID: display)
    }
    let baseline = system.windows.map(\.frame)
    let minimumHeight = scenario == "simultaneous" ? 240.0 : 205.0
    for id in [ids[2], ids[3]] { system.enforcedMinimumWidths[id] = 340 }
    for id in [ids[1], ids[3]] { system.enforcedMinimumHeights[id] = minimumHeight }
    var configuration = BetterTileConfiguration()
    configuration.resizeFeedbackMode = .live
    configuration.bentoInnerGap = 0
    let controller = DividerOverlayController(coordinator: WindowCoordinator(system: system), configuration: configuration)
    controller.bentoStateProvider = { _ in state }
    defer { controller.hideAndCancel() }
    let boundaries = BentoBoundaryResolver().boundaries(state: state, windows: system.windows, displayID: display, bounds: bounds)
    let start = BTPoint(x: bounds.midX, y: bounds.midY)
    let interaction = try #require(DividerInteractionResolver.resolve(
        at: start, in: boundaries, hitWidth: 18, adjacencyTolerance: 6, paneGap: 0
    ))
    guard case .junction = interaction.kind else { Issue.record("Expected a four-way junction"); return }
    let screen = try #require(NSScreen.screens.first)
    controller.beginGesture(interaction: interaction, at: start)
    try #require(controller.isDragging)
    var commits = 0
    controller.bentoStateChangedHandler = { _, _, _, _ in commits += 1 }
    if scenario == "cascading" || scenario == "late-mismatch" {
        system.targetedSnapshotHandler = { _ in
            let threshold = scenario == "cascading" ? 2 : 3
            if system.frameWriteCounts[ids[3], default: 0] >= threshold {
                // The app changes its width minimum after the release write.
                // Two corrections establish yet another constraint: stop.
                for id in [ids[2], ids[3]] { system.enforcedMinimumWidths[id] = 350 }
            }
        }
    } else if scenario == "failed-correction" {
        system.failedFrameWriteNumbers[ids[0]] = [3]
    }
    controller.drag(to: CGPoint(x: start.x + 90, y: screen.frame.maxY - start.y - 90))
    controller.displayTick()
    // Height 205 is first crossed on release. The width correction supplies
    // its second held sample, so that newly learned height needs a solve too.
    controller.end(at: CGPoint(x: start.x + 100, y: screen.frame.maxY - start.y - 100))
    if scenario == "cascading" || scenario == "late-mismatch" || scenario == "failed-correction" {
        #expect(system.windows.map(\.frame) == baseline)
        #expect(commits == 0)
        #expect(!controller.isDragging)
        return
    }
    let frames = try ids.map { id in try #require(system.windows.first { $0.id == id }?.frame) }
    #expect(frames[2].size.width == 340 && frames[3].size.width == 340)
    #expect(frames[1].size.height == minimumHeight && frames[3].size.height == minimumHeight)
    #expect(abs(frames[0].maxX - frames[2].minX) < 0.5)
    #expect(abs(frames[1].maxX - frames[3].minX) < 0.5)
    #expect(abs(frames[0].maxY - frames[1].minY) < 0.5)
    #expect(abs(frames[2].maxY - frames[3].minY) < 0.5)
    #expect(!controller.isDragging)
}
