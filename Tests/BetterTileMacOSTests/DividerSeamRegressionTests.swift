import AppKit
import Testing
@testable import BetterTileCore
@testable import BetterTileMacOS

@MainActor private final class SeamFixture {
    let system = FakeWindowSystem()
    let ticks = ResizeDisplayLink(automatic: false)
    let controller: DividerOverlayController
    let bounds = BTRect(x: -20_000, y: -20_000, width: 1000, height: 800)
    let state: BentoLayoutState
    let boundaries: [BoundaryDescriptor]
    let mainFrame: CGRect
    let display = DisplayID(rawValue: "main")
    var time = 0.0

    init(junction: Bool = false, axis: SplitAxis = .vertical) throws {
        _ = NSApplication.shared
        mainFrame = try #require(NSScreen.screens.first?.frame)
        let ids = ["a", "b", "c", "d"].map { WindowID(rawValue: $0) }
        state = BentoLayoutState(root: .partition(BentoPartition(
            axis: axis,
            first: junction ? .partition(BentoPartition(axis: .horizontal, first: .leaf(ids[0]), second: .leaf(ids[1]))) : .leaf(ids[0]),
            second: junction ? .partition(BentoPartition(axis: .horizontal, first: .leaf(ids[2]), second: .leaf(ids[3]))) : .leaf(ids[1])
        )))
        system.availableDisplays = [DisplaySnapshot(id: display, frame: bounds, visibleFrame: bounds, isMain: true)]
        system.windows = state.placements(in: bounds).map { [display] in
            WindowSnapshot(id: $0.windowID, processIdentifier: 42, frame: $0.frame, displayID: display)
        }
        var config = BetterTileConfiguration()
        config.resizeFeedbackMode = .ghost
        boundaries = state.boundaries(in: bounds, displayID: display)
        controller = DividerOverlayController(coordinator: WindowCoordinator(system: system), configuration: config, displayTicks: ticks)
        controller.bentoStateProvider = { [state] _ in state }
        controller.stackProvider = { [system] in system.onScreenStack(labeling: $0) }
        controller.coverageTime = { [weak self] in self?.time ?? 0 }
        setCovers([])
        refresh()
    }

    func setCovers(_ covers: [BTRect]) {
        system.onScreenStackEntries = covers.map {
            SeamStackEntry(windowID: nil, processIdentifier: 7, layer: 3, alpha: 1, frame: $0)
        } + system.windows.map {
            SeamStackEntry(windowID: $0.id, processIdentifier: $0.processIdentifier, layer: 0, alpha: 1, frame: $0.frame)
        }
    }
    func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> BTRect {
        BTRect(x: bounds.minX + x, y: bounds.minY + y, width: w, height: h)
    }
    func point(_ x: Double, _ y: Double) -> BTPoint { BTPoint(x: bounds.minX + x, y: bounds.minY + y) }
    func appKit(_ point: BTPoint) -> CGPoint { CGPoint(x: point.x, y: mainFrame.maxY - point.y) }
    func hover(_ x: Double, _ y: Double) { controller.updateHover(at: appKit(point(x, y))) }
    func refresh(obscuring: [BTRect] = []) {
        controller.refresh(boundaries: boundaries, obscuringFrames: obscuring,
                           managedWindowIDs: [display: Set(system.windows.map(\.id))])
    }
    func begin(_ x: Double, _ y: Double) throws {
        let start = point(x, y)
        let interaction = try #require(DividerInteractionResolver.resolve(
            at: start, in: boundaries, hitWidth: 30, adjacencyTolerance: 6
        ))
        controller.beginGesture(interaction: interaction, at: start)
        controller.visibleHandleView?.reduceMotion = { true }
        controller.visibleHandleView?.setActive(false, animated: false)
        controller.visibleHandleView?.setActive(true, animated: false)
    }
    func frame() throws -> BTRect {
        let frame = try #require(controller.visibleHandleView?.drawingState?.frame)
        return CoordinateConverter.toTopLeft(frame, mainScreenFrame: mainFrame)
    }
    var visible: Bool { controller.visibleHandleView?.window?.isVisible == true }
}

@Test @MainActor func exposedSeamKeepsActiveHandleAboveFloatingWindow() throws {
    let fixture = try SeamFixture()
    defer { fixture.controller.hideAndCancel() }
    let floating = fixture.rect(380, 300, 300, 200)
    fixture.setCovers([floating])
    fixture.hover(500, 295)
    #expect(fixture.visible)
    #expect((try fixture.frame().intersection(floating)?.area ?? 0) == 0)
    try fixture.begin(500, 295)
    #expect(fixture.controller.isDragging)
    #expect((try fixture.frame().intersection(floating)?.area ?? 0) == 0)
    let frame = try fixture.frame()
    let view = try #require(fixture.controller.visibleHandleView)
    #expect(frame.midY + (view.trackRoom[.down] ?? 0) == floating.minY)
    #expect(frame.midY - (view.trackRoom[.up] ?? 0) == fixture.bounds.minY + 8)
    #expect(fixture.system.frameWriteCounts.isEmpty)
}

@Test(arguments: [SplitAxis.vertical, .horizontal]) @MainActor
func exposedSeamHoverDoesNotOrderHandleOverCover(axis: SplitAxis) throws {
    let fixture = try SeamFixture(axis: axis)
    defer { fixture.controller.hideAndCancel() }
    fixture.setCovers([fixture.rect(380, 300, 300, 200)])
    fixture.hover(500, 400)
    #expect(!fixture.visible)
    if axis == .vertical { fixture.hover(500, 600) } else { fixture.hover(700, 400) }
    #expect(fixture.visible)
    #expect(fixture.system.onScreenStackReads == 1)
    #expect(fixture.system.onScreenStackLabels == Set(fixture.system.windows.map(\.id)))
}

@Test @MainActor func exposedSeamJunctionArmsAndTrackStopBeforeCover() throws {
    let fixture = try SeamFixture(junction: true)
    defer { fixture.controller.hideAndCancel() }
    let cover = fixture.rect(490, 100, 200, 275)
    fixture.setCovers([cover])
    fixture.hover(500, 400)
    #expect(fixture.visible)
    #expect((try fixture.frame().intersection(cover)?.area ?? 0) == 0)
    try fixture.begin(500, 400)
    #expect(fixture.controller.isDragging)
    #expect((try fixture.frame().intersection(cover)?.area ?? 0) == 0)
    #expect(fixture.controller.visibleHandleView?.trackRoom[.up] == 25)
    fixture.controller.cancelActiveGesture()
    fixture.setCovers([fixture.rect(495, 395, 100, 100)])
    fixture.refresh()
    fixture.hover(500, 400)
    #expect(!fixture.visible)
}

@Test @MainActor func exposedSeamCacheExpiresAndRefreshInvalidatesIt() throws {
    let fixture = try SeamFixture()
    defer { fixture.controller.hideAndCancel() }
    for sample in 0..<20 {
        fixture.time = Double(sample) * 0.005
        fixture.hover(500, 100 + Double(sample))
    }
    #expect(fixture.system.onScreenStackReads == 1)
    fixture.time = 0.151
    fixture.hover(500, 130)
    #expect(fixture.system.onScreenStackReads == 2)
    fixture.setCovers([fixture.rect(450, 0, 100, 800)])
    fixture.refresh()
    fixture.hover(500, 130)
    #expect(fixture.system.onScreenStackReads == 3)
    #expect(!fixture.visible)
}

@Test @MainActor func exposedSeamActivationInvalidatesVisibleHandle() async throws {
    let fixture = try SeamFixture()
    defer { fixture.controller.hideAndCancel() }
    fixture.controller.mouseLocation = { fixture.appKit(fixture.point(500, 200)) }
    // Start the async notification observer before posting an activation.
    await Task.yield()
    fixture.hover(500, 200)
    #expect(fixture.visible)
    fixture.setCovers([fixture.rect(450, 100, 100, 400)])
    NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didActivateApplicationNotification, object: nil)
    for _ in 0..<20 where fixture.visible { await Task.yield() }
    #expect(!fixture.visible)
    #expect(fixture.system.onScreenStackReads == 2)
    fixture.controller.mouseLocation = { NSEvent.mouseLocation }
}

@Test @MainActor func exposedSeamDragReadsOnceAndRecomputesMovingSeamWithoutHiding() throws {
    let fixture = try SeamFixture()
    defer { fixture.controller.hideAndCancel() }
    let cover = fixture.rect(540, 300, 200, 200)
    fixture.setCovers([cover])
    fixture.hover(500, 290)
    let reads = fixture.system.onScreenStackReads
    try fixture.begin(500, 290)
    #expect(fixture.system.onScreenStackReads == reads + 1)
    let inputFrame = try #require(fixture.controller.visibleHandleView?.window?.frame)
    for x in stride(from: 501.0, through: 650, by: 3) {
        fixture.time += 1
        fixture.controller.drag(to: fixture.appKit(fixture.point(x, 290)))
        fixture.ticks.fire()
        #expect(fixture.visible)
        #expect(fixture.controller.isDragging)
        #expect(fixture.controller.visibleHandleView?.window?.frame == inputFrame)
        let frame = try fixture.frame()
        #expect((frame.intersection(cover)?.area ?? 0) == 0)
        if frame.maxX > cover.minX {
            #expect(frame.midY + (fixture.controller.visibleHandleView?.trackRoom[.down] ?? 0) == cover.minY)
        }
    }
    #expect(fixture.system.onScreenStackReads == reads + 1)
    #expect(fixture.system.frameWriteCounts.isEmpty)
}

@Test @MainActor func exposedSeamDragRetainsMinimumKnobWhenNoRoomRemains() throws {
    let fixture = try SeamFixture()
    defer { fixture.controller.hideAndCancel() }
    fixture.setCovers([fixture.rect(540, 0, 300, 390), fixture.rect(540, 400, 300, 400)])
    try fixture.begin(500, 395)
    fixture.controller.drag(to: fixture.appKit(fixture.point(600, 395)))
    fixture.ticks.fire()
    #expect(fixture.visible)
    #expect(try fixture.frame().size.height == 24)
    #expect(fixture.controller.visibleHandleView?.trackRoom[.up] == 5)
    #expect(fixture.controller.visibleHandleView?.trackRoom[.down] == 5)
    #expect(fixture.system.onScreenStackReads == 1)
}

@Test(arguments: [false, true]) @MainActor func exposedSeamNilStackKeepsLegacyCoverage(noProvider: Bool) throws {
    let fixture = try SeamFixture()
    defer { fixture.controller.hideAndCancel() }
    if noProvider { fixture.controller.stackProvider = nil } else { fixture.system.onScreenStackEntries = nil }
    fixture.refresh(obscuring: [fixture.rect(380, 300, 300, 200)])
    fixture.hover(500, 295)
    #expect(!fixture.visible)
    fixture.hover(500, 200)
    #expect(fixture.visible)
}

@Test @MainActor func exposedSeamJunctionInputFrameAvoidsDiagonalCover() throws {
    let fixture = try SeamFixture(junction: true)
    defer { fixture.controller.hideAndCancel() }
    let cover = fixture.rect(520, 420, 100, 100)
    fixture.setCovers([cover])
    fixture.hover(500, 400)
    #expect(fixture.visible)
    #expect((try fixture.frame().intersection(cover)?.area ?? 0) == 0)
    try fixture.begin(500, 400)
    #expect(fixture.controller.isDragging)
    #expect((try fixture.frame().intersection(cover)?.area ?? 0) == 0)
    #expect(fixture.controller.visibleHandleView?.trackRoom[.down] == 20)
    #expect(fixture.controller.visibleHandleView?.trackRoom[.right] == 20)
}
