import AppKit
import BetterTileCore
import CoreImage
import Testing
@testable import BetterTileMacOS

@MainActor
private struct GhostGestureFixture {
    let system = FakeWindowSystem()
    let ticks = ResizeDisplayLink(automatic: false)
    let controller: DividerOverlayController
    let state: BentoLayoutState
    let bounds: BTRect
    let display = DisplayID(rawValue: "ghost-overlay")
    let mainFrame: CGRect
    let start: BTPoint

    init(junction: Bool = false, live: Bool = false, onScreen: Bool = false) throws {
        _ = NSApplication.shared
        let screen = try #require(NSScreen.screens.first)
        mainFrame = screen.frame
        bounds = onScreen ? CoordinateConverter.toTopLeft(screen.visibleFrame, mainScreenFrame: mainFrame)
            : BTRect(x: -10000, y: -10000, width: 800, height: 600)
        start = BTPoint(x: bounds.midX, y: bounds.midY)
        let ids = (0..<4).map { WindowID(rawValue: "ghost-\($0)") }
        state = junction ? BentoLayoutState(root: .partition(BentoPartition(
            axis: .vertical,
            first: .partition(BentoPartition(axis: .horizontal, first: .leaf(ids[0]), second: .leaf(ids[1]))),
            second: .partition(BentoPartition(axis: .horizontal, first: .leaf(ids[2]), second: .leaf(ids[3]))))))
            : BentoLayoutState(root: .partition(BentoPartition(axis: .vertical, first: .leaf(ids[0]), second: .leaf(ids[1]))))
        system.availableDisplays = [DisplaySnapshot(id: display, frame: bounds, visibleFrame: bounds, isMain: true)]
        let display = display
        system.windows = state.placements(in: bounds).map {
            WindowSnapshot(id: $0.windowID, processIdentifier: 0, bundleIdentifier: "com.example.Sample", title: "Sample window",
                           frame: $0.frame, displayID: display)
        }
        var configuration = BetterTileConfiguration()
        configuration.resizeFeedbackMode = live ? .live : .ghost
        controller = DividerOverlayController(coordinator: WindowCoordinator(system: system), configuration: configuration, displayTicks: ticks)
        let state = state
        controller.bentoStateProvider = { _ in state }
        let interaction = try #require(DividerInteractionResolver.resolve(
            at: start, in: state.boundaries(in: bounds, displayID: display), hitWidth: 30, adjacencyTolerance: 6
        ))
        controller.beginGesture(interaction: interaction, at: start)
        let handle = try #require(controller.visibleHandleView)
        handle.displayOptions = { (false, false) }
        handle.setActive(false, animated: false)
        handle.setActive(true, animated: false)
    }

    func point(dx: Double, dy: Double = 0) -> CGPoint {
        CGPoint(x: start.x + dx, y: mainFrame.maxY - (start.y + dy))
    }
    func tick(dx: Double, dy: Double = 0) { controller.drag(to: point(dx: dx, dy: dy)); ticks.fire() }
}

@Test(arguments: [false, true]) @MainActor
func ghostOverlayKeepsOneWindowAndStationaryInputForEveryTick(junction: Bool) throws {
    let fixture = try GhostGestureFixture(junction: junction)
    defer { fixture.controller.hideAndCancel() }
    let controller = fixture.controller
    let overlay = controller.dragOverlay
    let panel = try #require(overlay.panel)
    let handle = try #require(controller.visibleHandleView)
    let input = try #require(handle.window as? DividerHandlePanel)
    let initialOverlayFrame = panel.frame
    let initialInputFrame = input.frame
    let calls = input.frameSetCallCount
    let orders = input.orderCallCount
    let overlayCalls = overlay.frameSetCallCount
    #expect(panel.isVisible && panel.ignoresMouseEvents && !panel.isOpaque && !panel.hasShadow)
    #expect(panel.level == .floating && panel.animationBehavior == .none)
    #expect(panel.collectionBehavior == input.collectionBehavior)
    #expect(overlay.orderedBelowWindowNumber == input.windowNumber)
    #expect(overlay.previewViews.count == (junction ? 4 : 2))
    #expect(overlay.previewViews.values.allSatisfy { $0.window === panel })
    #expect(!NSApp.windows.contains { $0.isVisible && $0.contentView is GhostPreviewView })
    #expect(input.isVisible && !input.ignoresMouseEvents && input.alphaValue == 1)
    #expect(!handle.drawsLens && !handle.showsGlass && !handle.showsSolid)
    #expect(!input.decorationWindow.isVisible)
    #expect(handle.drawingSink != nil)
    var accepted: BentoLayoutState?
    controller.bentoStateLiveHandler = { _, state, _ in accepted = state }
    for sample in 1...50 {
        let before = controller.ghostPresentationCount
        fixture.tick(dx: Double(sample), dy: junction ? Double(sample) / 2 : 0)
        #expect(controller.ghostPresentationCount == before + 1)
        #expect(panel.frame == initialOverlayFrame)
        #expect(input.frame == initialInputFrame)
        let state = try #require(accepted)
        for placement in state.placements(in: fixture.bounds) {
            let expected = CoordinateConverter.toAppKit(placement.frame, mainScreenFrame: fixture.mainFrame)
                .offsetBy(dx: -panel.frame.minX, dy: -panel.frame.minY).insetBy(dx: 3, dy: 3)
            #expect(overlay.previewViews[placement.windowID]?.frame == expected)
        }
        let vertical = try #require(state.boundaries(in: fixture.bounds, displayID: fixture.display).first { $0.axis == .vertical })
        let knob = try #require(overlay.knobRects.first)
        #expect(abs(knob.midX + panel.frame.minX - vertical.coordinate) < 0.000001)
    }
    #expect(overlay.orderCallCount == 1 && overlay.frameSetCallCount == overlayCalls)
    #expect(input.orderCallCount == orders && input.frameSetCallCount == calls)
    #expect(fixture.system.frameWriteCounts.isEmpty)
    let layers = dragLensLayerTree(overlay.lensLayers.handleLayer) + dragLensLayerTree(overlay.lensLayers.decorationLayer)
    #expect(layers.allSatisfy { $0.mask == nil && ($0.animationKeys() ?? []).isEmpty })
    #expect(layers.filter { $0.shadowOpacity > 0 }.allSatisfy { $0.shadowPath != nil })
    #expect(layers.allSatisfy { $0.contentsScale == panel.backingScaleFactor })
}

private enum GhostEnd: CaseIterable { case release, cancel, hide, participantLost, failedCommit }

@Test(arguments: GhostEnd.allCases) @MainActor
private func ghostOverlayCleansUpEveryGestureExit(ending: GhostEnd) throws {
    let fixture = try GhostGestureFixture()
    let controller = fixture.controller
    let handle = try #require(controller.visibleHandleView)
    let input = try #require(handle.window as? DividerHandlePanel)
    fixture.tick(dx: 50)
    let finalFrame = try #require(controller.dragOverlay.drawing?.frame)
    if ending == .failedCommit { fixture.system.failedFrameWriteNumbers[fixture.system.windows[0].id] = [1] }
    switch ending {
    case .release, .failedCommit: controller.end(at: fixture.point(dx: 50))
    case .cancel: controller.cancelActiveGesture()
    case .hide: controller.hideAndCancel()
    case .participantLost:
        fixture.system.windows.removeLast()
        controller.refresh(boundaries: fixture.state.boundaries(in: fixture.bounds, displayID: fixture.display))
    }
    #expect(!controller.isDragging)
    #expect(!controller.dragOverlay.isVisible)
    #expect(controller.dragOverlay.previewViews.isEmpty && controller.limitedGhostWindowIDs.isEmpty)
    #expect(handle.drawsLens && handle.drawingSink == nil && handle.drawingFrame == nil)
    #expect(input.frame == finalFrame)
    // Reduced Motion can finish retraction and hide both windows immediately
    // when the pointer is away. Drawing ownership must still be restored.
    #expect(input.decorationWindow.isVisible == input.isVisible)
    #expect(handle.showsGlass)
    controller.hideAndCancel()
}

@Test @MainActor func liveDividerKeepsItsOwnDrawingAndCreatesNoDragOverlay() throws {
    let fixture = try GhostGestureFixture(live: true)
    defer { fixture.controller.hideAndCancel() }
    let handle = try #require(fixture.controller.visibleHandleView)
    let before = handle.window?.frame
    fixture.tick(dx: 50)
    #expect(handle.drawsLens && handle.drawingSink == nil && handle.showsGlass)
    #expect(handle.window?.frame != before)
    #expect(fixture.controller.dragOverlay.panel == nil)
    #expect(!fixture.system.frameWriteCounts.isEmpty)
}

@Test @MainActor func ghostOverlaySettingsAndLimitsShareTheDrawingSample() throws {
    let fixture = try GhostGestureFixture(junction: true)
    defer { fixture.controller.hideAndCancel() }
    let controller = fixture.controller
    let overlay = controller.dragOverlay
    let handle = try #require(controller.visibleHandleView)
    fixture.tick(dx: 10000, dy: 10000)
    #expect(overlay.drawing?.limit.isLimited == true)
    #expect(!overlay.limitedWindowIDs.isEmpty)
    #expect(overlay.previewViews.allSatisfy { $0.value.isLimited == overlay.limitedWindowIDs.contains($0.key) })
    #expect(overlay.drawing?.tint == handle.lensTint)
    let counts = fixture.system.frameWriteCounts
    for glass in [false, true] {
        controller.configuration.overlayAppearance.useLiquidGlass = glass
        controller.configuration.overlayAppearance.strength = 1
        controller.configuration.dividerThickness = 12
        #expect(overlay.previewViews.values.allSatisfy { $0.overlayAppearance == controller.configuration.overlayAppearance })
        #expect(overlay.drawing?.frost == 1 && overlay.drawing?.useLiquidGlass == glass)
        #expect(overlay.lensLayers.handleLayer.isHidden == !glass)
        #expect(overlay.knobRects[0].height == (glass ? 16 : 12))
        #expect(fixture.system.frameWriteCounts == counts)
    }
    handle.displayOptions = { (true, false) }
    #expect(overlay.drawing?.solid == true && overlay.lensLayers.decorationLayer.isHidden)
    handle.displayOptions = { (false, true) }
    #expect(overlay.drawing?.increaseContrast == true)
    handle.displayOptions = { (false, false) }
    #expect(overlay.drawing?.solid == false)
}

@Test @MainActor func ghostOverlayReceivesStretchWithoutMovingAnyWindow() async throws {
    let fixture = try GhostGestureFixture()
    defer { fixture.controller.hideAndCancel() }
    let handle = try #require(fixture.controller.visibleHandleView)
    let overlay = fixture.controller.dragOverlay
    let initialFrame = handle.window?.frame
    handle.reduceMotion = { false }
    handle.setActive(false, animated: false)
    handle.setActive(true, animated: true)
    let deadline = ContinuousClock.now + .seconds(2)
    while overlay.drawing?.progress != 1 && ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
        #expect(overlay.drawing?.progress == handle.stretchProgress)
        #expect(handle.window?.frame == initialFrame)
    }
    #expect(overlay.drawing?.progress == 1 && overlay.knobRects[0].height == 166)
}

@MainActor private func dragLensLayerTree(_ root: CALayer) -> [CALayer] {
    [root] + (root.sublayers ?? []).flatMap(dragLensLayerTree)
}

@Test @MainActor func ghostOverlayReusesItsPanelWithoutStaleDrawingOrLimits() throws {
    let fixture = try GhostGestureFixture(junction: true)
    defer { fixture.controller.hideAndCancel() }
    let controller = fixture.controller
    let overlay = controller.dragOverlay
    let panel = try #require(overlay.panel)
    fixture.tick(dx: 10000, dy: 10000)
    #expect(!overlay.limitedWindowIDs.isEmpty)
    controller.cancelActiveGesture()
    controller.configuration.dividerThickness = 12
    controller.configuration.overlayAppearance.strength = 1
    let interaction = try #require(DividerInteractionResolver.resolve(
        at: fixture.start, in: fixture.state.boundaries(in: fixture.bounds, displayID: fixture.display),
        hitWidth: 30, adjacencyTolerance: 6))
    controller.beginGesture(interaction: interaction, at: fixture.start)
    let handle = try #require(controller.visibleHandleView)
    handle.setActive(false, animated: false)
    handle.setActive(true, animated: false)
    #expect(overlay.panel === panel && overlay.orderCallCount == 2)
    #expect(overlay.limitedWindowIDs.isEmpty && overlay.drawing?.limit.isLimited == false)
    #expect(overlay.drawing?.thickness == 12 && overlay.drawing?.frost == 1)
    #expect(handle.drawingSink != nil && !handle.drawsLens)
    #expect(overlay.previewViews.count == 4)
    #expect(dragLensLayerTree(overlay.lensLayers.handleLayer).allSatisfy { $0.contentsScale == panel.backingScaleFactor })
    fixture.tick(dx: -40, dy: -20)
    #expect(overlay.drawing?.frame == handle.drawingFrame)
}

@Test @MainActor func ghostOverlayUsesSolidFallbackWhenItsOwnFilterIsUnavailable() throws {
    let fixture = try GhostGestureFixture()
    defer { fixture.controller.hideAndCancel() }
    let handle = try #require(fixture.controller.visibleHandleView)
    let overlay = DividerDragOverlay(lensLayers: DividerLensLayers(makeFilter: { _ in nil }))
    defer { overlay.end() }
    overlay.begin(displayFrame: fixture.bounds, below: try #require(handle.window),
                  appearance: OverlayAppearance(), windows: fixture.system.windows)
    overlay.update(knob: try #require(handle.drawingState))
    #expect(overlay.drawing?.solid == true)
    #expect(overlay.lensLayers.handleLayer.isHidden && overlay.lensLayers.decorationLayer.isHidden)
    #expect(overlay.knobRects[0].width == 14)
}

/// Uses the production overlay with an opaque, synthetic canvas behind its
/// views. Captures only the test's own window; no foreign app content is read.
@Test(.enabled(if: ProcessInfo.processInfo.environment["BETTERTILE_NATIVE_DIVIDER_DRAG_DIR"] != nil,
               "Requires an explicit native divider drag preview output directory."))
@MainActor func nativeDividerDragOverlayPreviews() async throws {
    let directory = try #require(ProcessInfo.processInfo.environment["BETTERTILE_NATIVE_DIVIDER_DRAG_DIR"])
    try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    for junction in [false, true] {
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let fixture = try GhostGestureFixture(junction: junction, onScreen: true)
            defer { fixture.controller.hideAndCancel() }
            let handle = try #require(fixture.controller.visibleHandleView)
            let panel = try #require(fixture.controller.dragOverlay.panel)
            let content = try #require(panel.contentView)
            panel.appearance = NSAppearance(named: appearance)
            handle.appearance = NSAppearance(named: appearance)
            handle.displayOptions = { (false, false) }
            content.layer?.backgroundColor = NSColor(white: name == "dark" ? 0.09 : 0.94, alpha: 1).cgColor
            let scene = junction ? "junction" : "straight"
            for limited in [false, true] {
                fixture.tick(dx: limited ? 10000 : 100, dy: junction ? (limited ? 10000 : 60) : 0)
                panel.displayIfNeeded()
                try await Task.sleep(for: .milliseconds(250))
                let output = URL(fileURLWithPath: directory)
                    .appendingPathComponent("divider-drag-\(scene)-\(name)\(limited ? "-limit" : "").png")
                if FileManager.default.fileExists(atPath: output.path) { try FileManager.default.removeItem(at: output) }
                let capture = Process()
                capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                capture.arguments = ["-x", "-o", "-l", String(panel.windowNumber), output.path]
                try capture.run()
                capture.waitUntilExit()
                #expect(capture.terminationStatus == 0)
                let bitmap = try #require(NSBitmapImageRep(data: Data(contentsOf: output)))
                #expect(bitmap.pixelsWide == Int(panel.frame.width * panel.backingScaleFactor))
                #expect(bitmap.pixelsHigh == Int(panel.frame.height * panel.backingScaleFactor))
                #expect(fixture.controller.dragOverlay.drawing?.progress == 1)
                #expect(fixture.controller.dragOverlay.drawing?.limit.isLimited == limited)
            }
        }
    }
}
