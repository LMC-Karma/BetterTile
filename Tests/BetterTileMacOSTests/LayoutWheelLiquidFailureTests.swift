import AppKit
import Metal
import Testing
#if !BETTERTILE_TEST_HOOKS
#error("Tests require BETTERTILE_TEST_HOOKS. Use Tools/test.sh LOG --release for Release tests.")
#endif
@_spi(LiquidWheelPrototype) @testable import BetterTileCore
@_spi(LiquidWheelPrototype) @testable import BetterTileMacOS

/// Failure paths of the liquid renderer: each one either keeps a complete
/// wheel or hands the gesture to the panel fallback.
@MainActor @Suite(.macOSTestApplication, .serialized) struct LayoutWheelLiquidFailureTests {
    private let content = LayoutWheelLiquidContent(configuration: .init(style: .grouped), levelCount: .two)

    @Test(.liquidPipeline) func failedEncodingKeepsTheSharedBufferSlot() throws {
        try #require(MTLCreateSystemDefaultDevice() != nil)
        let pipeline = try #require(LayoutWheelLiquidPipeline.prepare())
        let encoder = try #require(LayoutWheelLiquidEncoder(pipeline: pipeline))
        var model = LayoutWheelLiquid(layout: content.layout, tuning: .standard)
        model.open()
        let size = CGSize(width: 64, height: 64)
        #expect(encoder.image(model, style: .make(dark: true, opaque: false), size: size, scale: 1) != nil)
        let submitted = encoder.nextSlotForTesting
        #expect(submitted == 1)
        // No command buffer is submitted for this slot, so the semaphore
        // permit returns. The slot must stay with that permit.
        encoder.failsNextEncodingForTesting = true
        #expect(encoder.image(model, style: .make(dark: true, opaque: false), size: size, scale: 1) == nil)
        #expect(encoder.nextSlotForTesting == submitted)
        #expect(encoder.image(model, style: .make(dark: true, opaque: false), size: size, scale: 1) != nil)
        #expect(encoder.nextSlotForTesting == (submitted + 1) % LayoutWheelLiquidEncoder.framesInFlight)
    }

    @Test func atlasAllocationFailureRefusesToPrepareOrOpen() throws {
        try #require(MTLCreateSystemDefaultDevice() != nil)
        let clock = WheelTestClock()
        let presenter = LayoutWheelLiquidPresenter(clock: clock)
        presenter.dark = true
        presenter.makeAtlas = { _, _, _ in nil }
        // Without an atlas the wheel would draw no icon, yet every command
        // would stay selectable.
        #expect(!presenter.prepareToOpen(content))
        #expect(presenter.atlasForTesting == nil)
        #expect(!presenter.holdsDrawables && !presenter.isVisible)
        #expect(!presenter.open(content, center: .init(x: -20_000, y: -20_000)))
        #expect(!presenter.isOpen && !presenter.isVisible && !clock.isRunning)
        #expect(!presenter.holdsDrawables)
    }

    @Test func atlasAllocationFailureUsesThePanelFallbackWithItsGeometry() throws {
        try #require(MTLCreateSystemDefaultDevice() != nil)
        let renderer = LayoutWheelLiquidPresenter(clock: WheelTestClock())
        renderer.makeAtlas = { _, _, _ in nil }
        let adapter = LayoutWheelLiquidAdapter(renderer: renderer)
        let configuration = LayoutWheelConfiguration(style: .grouped, levelCount: .two)
        adapter.prepareToOpen(configuration: configuration, appearance: .init())
        // The controller places and hit-tests with the panel metrics from here on.
        #expect(!adapter.usesLiquidGeometry)
        let center = BTPoint(x: -20_000, y: -20_000)
        adapter.open(.init(configuration: configuration,
                           placement: .init(anchor: center, center: center,
                                            diameter: LayoutWheelMetrics.grouped.groupedPresentationDiameter),
                           selection: nil, unavailableCommands: []))
        #expect(!renderer.isOpen && !renderer.isVisible)
        adapter.close()
    }

    // MARK: An open wheel whose atlas cannot be rebuilt



    /// An open wheel with a complete atlas, and a counter of how often it was lost.
    private func openWheel(_ content: LayoutWheelLiquidContent) throws
        -> (presenter: LayoutWheelLiquidPresenter, lost: Counter) {
        try #require(MTLCreateSystemDefaultDevice() != nil)
        let presenter = LayoutWheelLiquidPresenter(clock: WheelTestClock())
        presenter.dark = true
        let lost = Counter()
        presenter.onOpenWheelLost = { lost.value += 1 }
        #expect(presenter.open(content, center: .init(x: -20_000, y: -20_000)))
        #expect(presenter.isOpen && presenter.atlasForTesting != nil)
        return (presenter, lost)
    }

    private final class Counter { var value = 0 }



    @Test(.liquidPipeline) func failedModeGlyphRebuildClosesTheOpenWheel() throws {
        let configuration = LayoutWheelConfiguration(style: .grouped, levelCount: .two)
        let (presenter, lost) = try openWheel(LayoutWheelLiquidDefaults.content(configuration: configuration, currentMode: .bento))
        defer { presenter.close() }
        presenter.makeAtlas = { _, _, _ in nil }
        presenter.update(LayoutWheelLiquidDefaults.content(configuration: configuration, currentMode: .tabbed), state: .init())
        #expect(lost.value == 1)
        #expect(!presenter.isOpen)
    }





    // MARK: A single icon that cannot be drawn

    @Test func oneMissingIconRefusesANewGesture() throws {
        try #require(MTLCreateSystemDefaultDevice() != nil)
        let presenter = LayoutWheelLiquidPresenter(clock: WheelTestClock())
        presenter.dark = true
        presenter.imageFailure = { $0 == .ring(0, 2) }
        #expect(!presenter.prepareToOpen(content))
        #expect(presenter.atlasForTesting == nil && !presenter.holdsDrawables)
        #expect(!presenter.open(content, center: .init(x: -20_000, y: -20_000)))
        #expect(!presenter.isOpen)
    }

    private func isCaption(_ key: LayoutWheelLiquidAtlas.Key) -> Bool {
        switch key {
        case .ringName, .optionName: true
        default: false
        }
    }

    @Test func oneMissingCaptionRefusesAGestureThatDrawsCaptions() throws {
        try #require(MTLCreateSystemDefaultDevice() != nil)
        let presenter = LayoutWheelLiquidPresenter(clock: WheelTestClock())
        presenter.dark = true
        presenter.names = .underIcons
        presenter.imageFailure = { $0 == .optionName(0, 0) }
        #expect(!presenter.prepareToOpen(content))
        #expect(presenter.atlasForTesting == nil)
    }

    @Test(.liquidPipeline, arguments: [LayoutWheelLiquidPresenter.Names.centre, .hidden])
    func missingCaptionsDoNotBlockAWheelThatDrawsNone(names: LayoutWheelLiquidPresenter.Names) throws {
        try #require(MTLCreateSystemDefaultDevice() != nil)
        let presenter = LayoutWheelLiquidPresenter(clock: WheelTestClock())
        presenter.dark = true
        presenter.names = names
        presenter.imageFailure = isCaption
        defer { presenter.close() }
        #expect(presenter.prepareToOpen(content))
        #expect(presenter.open(content, center: .init(x: -20_000, y: -20_000)))
        #expect(presenter.atlasForTesting?.entries[.ring(0, 0)] != nil)
    }

    @Test(.liquidPipeline) func switchingToUnderIconNamesNeverReusesAnAtlasWithoutThem() throws {
        try #require(MTLCreateSystemDefaultDevice() != nil)
        let presenter = LayoutWheelLiquidPresenter(clock: WheelTestClock())
        presenter.dark = true
        presenter.names = .centre
        presenter.imageFailure = isCaption
        defer { presenter.close() }
        #expect(presenter.prepareToOpen(content))
        // The prepared wheel has no captions. Under-icon names need them.
        presenter.names = .underIcons
        #expect(!presenter.open(content, center: .init(x: -20_000, y: -20_000)))
        #expect(!presenter.isOpen)
        presenter.imageFailure = { _ in false }
        #expect(presenter.open(content, center: .init(x: -20_000, y: -20_000)))
        #expect(presenter.atlasForTesting?.entries[.ringName(0, 0)] != nil)
    }





    @Test func oneMissingIconUsesThePanelFallback() throws {
        try #require(MTLCreateSystemDefaultDevice() != nil)
        let renderer = LayoutWheelLiquidPresenter(clock: WheelTestClock())
        renderer.imageFailure = { $0 == .option(0, 0) }
        let adapter = LayoutWheelLiquidAdapter(renderer: renderer)
        adapter.prepareToOpen(configuration: .init(style: .grouped, levelCount: .two), appearance: .init())
        #expect(!adapter.usesLiquidGeometry)
    }

    @Test(.liquidPipeline) func openWheelCannotCommitAnIncompleteReplacement() throws {
        let configuration = LayoutWheelConfiguration(style: .grouped, levelCount: .two)
        let (presenter, lost) = try openWheel(LayoutWheelLiquidDefaults.content(configuration: configuration, currentMode: .bento))
        defer { presenter.close() }
        presenter.imageFailure = { $0 == .ring(1, 0) }
        presenter.update(LayoutWheelLiquidDefaults.content(configuration: configuration, currentMode: .tabbed), state: .init())
        #expect(lost.value == 1)
        #expect(!presenter.isOpen)
    }

    // MARK: The controller ends the gesture

    @Test(.liquidPipeline, .timeLimit(.minutes(1))) func embeddedPreviewFallsBackWhenItsOpenRendererIsLost() async throws {
        try #require(MTLCreateSystemDefaultDevice() != nil)
        let coordinator = LayoutWheelLiquidPreview.Coordinator()
        let host = NSView()
        defer { LayoutWheelLiquidPreview.dismantleNSView(host, coordinator: coordinator) }
        let (modes, report) = AsyncStream.makeStream(of: LayoutWheelPreviewMode.self)
        var configuration = LayoutWheelConfiguration(style: .grouped, levelCount: .two)
        configuration.appearance.liquid.appearance = .light
        func show(_ configuration: LayoutWheelConfiguration) {
            coordinator.update(host, configuration: configuration, appearance: .init(), state: .init(),
                               currentMode: nil, playback: nil, modeChanged: { report.yield($0) })
        }
        show(configuration)
        #expect(coordinator.renderer.isOpen && coordinator.fallback == nil)

        // The Appearance changes while the atlas cannot be rebuilt.
        coordinator.renderer.makeAtlas = { _, _, _ in nil }
        configuration.appearance.liquid.appearance = .dark
        show(configuration)

        // The preview is not left blank or stale: it uses the panel presentation.
        #expect(!coordinator.renderer.isOpen)
        #expect(coordinator.fallback != nil && coordinator.fallback?.superview === host)
        #expect(coordinator.renderer.previewView.superview == nil)
        // Hit testing switches to the panel geometry, reported after the view update.
        if coordinator.fallback != nil {
            var iterator = modes.makeAsyncIterator()
            #expect(await iterator.next() == .panel)
        }
        // Later updates keep the fallback current instead of feeding the closed renderer.
        configuration.appearance.liquid.appearance = .light
        show(configuration)
        #expect(!coordinator.renderer.isOpen && coordinator.fallback != nil)
    }

    @Test(.liquidPipeline) func groupedAvailabilityChangeNeedsNoNewAtlas() throws {
        let configuration = LayoutWheelConfiguration(style: .grouped, levelCount: .two)
        let (presenter, lost) = try openWheel(LayoutWheelLiquidDefaults.content(configuration: configuration))
        defer { presenter.close() }
        presenter.makeAtlas = { _, _, _ in nil }
        // Availability changes only alpha, so the same icons stay correct.
        presenter.update(LayoutWheelLiquidDefaults.content(configuration: configuration,
                                                           unavailableCommands: [.windowAction(.leftHalf)]), state: .init())
        #expect(lost.value == 0 && presenter.isOpen)
    }

    @Test(.liquidPipeline) func groupedDensityRebuildFailureKeepsTheOldAtlasUsable() throws {
        let configuration = LayoutWheelConfiguration(style: .grouped, levelCount: .two)
        let (presenter, lost) = try openWheel(LayoutWheelLiquidDefaults.content(configuration: configuration))
        defer { presenter.close() }
        presenter.close()
        // The wheel opens on a display with another density, and the rebuild fails.
        let content = LayoutWheelLiquidDefaults.content(configuration: configuration)
        let old = try #require(presenter.atlasForTesting)
        presenter.destinationScaleForTesting = (presenter.metalLayerForTesting?.contentsScale ?? 2) + 1
        presenter.makeAtlas = { _, _, _ in nil }
        #expect(presenter.open(content, center: .init(x: -20_000, y: -20_000)))
        #expect(presenter.atlasForTesting === old)
        // Availability changes only alpha. The old icons still stand for every command.
        presenter.update(LayoutWheelLiquidDefaults.content(configuration: configuration,
                                                           unavailableCommands: [.windowAction(.leftHalf)]), state: .init())
        #expect(lost.value == 0 && presenter.isOpen)
        #expect(presenter.atlasForTesting === old)
    }

    @Test(.liquidPipeline) func lostGroupedWheelEndsTheGestureWithoutACommand() throws {
        try #require(MTLCreateSystemDefaultDevice() != nil)
        let renderer = LayoutWheelLiquidPresenter(clock: WheelTestClock())
        renderer.dark = true
        // The default appearance follows the host. Pin it to Dark, so the switch to Light below is a change.
        renderer.systemDarkProvider = { true }
        let adapter = LayoutWheelLiquidAdapter(renderer: renderer)
        adapter.systemDarkProvider = { true }
        let configuration = LayoutWheelConfiguration(style: .grouped, levelCount: .two)
        let content = LayoutWheelLiquidDefaults.content(configuration: configuration)
        let target = LayoutWheelTarget(windowID: .init(rawValue: "fixture"), displayID: .init(rawValue: "display"),
                                      visibleFrame: .init(x: -30_000, y: -30_000, width: 1600, height: 1000))
        var pointer = BTPoint(x: -29_200, y: -29_500)
        var time = 0.0
        let controller = LayoutWheelController(
            configuration: .init(layoutWheel: .init(style: .grouped, levelCount: .two)), presenter: adapter,
            now: { time }, pointerProvider: { pointer }, addGlobalMonitor: { _, _ in NSObject() },
            addLocalMonitor: { _, _ in NSObject() }, removeMonitor: { _ in })
        controller.captureHandler = { _ in target }
        controller.previewHandler = { _, _ in .ready(placements: []) }
        var commits: [LayoutWheelCommand] = []
        controller.commitHandler = { command, _ in commits.append(command) }
        controller.start()
        defer { controller.stop() }
        controller.handleModifiers([.control, .option, .shift])
        controller.handleActivationDeadline(generation: 1)
        #expect(renderer.isOpen)
        // The visible frame leaves room, so the wheel opens centred on the pointer.
        let center = pointer
        let sector = LayoutWheelSector.bottomLeft
        _ = try #require(content.submenuLayout)
        let angle = content.layout.slotAngle(sector.rawValue)
        let radius = content.layout.iconRadii.last!
        func move(_ vector: BTPoint) {
            pointer = .init(x: center.x + vector.x, y: center.y + vector.y)
            controller.handlePointer(pointer)
        }
        move(.init(x: cos(angle) * radius, y: sin(angle) * radius))
        time += 0.21
        controller.handleFanDeadline()
        var attempts = 0
        renderer.makeAtlas = { _, _, _ in attempts += 1; return nil }
        // An appearance change needs a new atlas for the plain Grouped configuration.
        renderer.dark = false
        renderer.refreshAppearance()
        #expect(attempts == 1)
        #expect(!controller.isOpen && !renderer.isOpen)
        controller.handleModifiers([])
        #expect(commits.isEmpty)
    }
}
